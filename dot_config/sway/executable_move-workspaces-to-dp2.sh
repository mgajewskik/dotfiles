#!/usr/bin/env bash
set -euo pipefail

TARGET_OUTPUT="DP-2"
PARKING_OUTPUT="eDP-1"
PARKING_WORKSPACE_NUM="19"

notify() {
	notify-send -a "Sway" "$@" 2>/dev/null || true
}

die() {
	notify "Move workspaces failed" "$1"
	echo "ERROR: $1" >&2
	exit 1
}

require_cmd() {
	if ! command -v "$1" >/dev/null 2>&1; then
		die "$1 is required."
	fi
}

sway_quote() {
	local value="$1"
	value="${value//\\/\\\\}"
	value="${value//\"/\\\"}"
	printf '"%s"' "$value"
}

workspace_selector() {
	local num="$1"
	local name="$2"

	if [[ "$num" =~ ^[0-9]+$ ]]; then
		printf 'number %s' "$num"
	else
		sway_quote "$name"
	fi
}

require_cmd swaymsg
require_cmd jq

outputs_json="$(swaymsg -t get_outputs)" || die "Could not query Sway outputs."
if ! jq -e --arg output "$TARGET_OUTPUT" '.[] | select(.name == $output and .active == true)' >/dev/null <<<"$outputs_json"; then
	die "$TARGET_OUTPUT is not active."
fi

workspaces_json="$(swaymsg -t get_workspaces)" || die "Could not query Sway workspaces."
original_workspace="$(jq -c '.[] | select(.focused) | {num, name}' <<<"$workspaces_json")"
if [[ -z "$original_workspace" ]]; then
	die "Could not determine the focused workspace."
fi

readarray -t workspaces < <(jq -c 'sort_by(if .num >= 0 then .num else 1000000 end, .name)[] | {num, name}' <<<"$workspaces_json")
if [[ "${#workspaces[@]}" -eq 0 ]]; then
	die "No workspaces found."
fi

target_arg="$(sway_quote "$TARGET_OUTPUT")"
parking_output_arg="$(sway_quote "$PARKING_OUTPUT")"
parking_workspace_selector="$(workspace_selector "$PARKING_WORKSPACE_NUM" "$PARKING_WORKSPACE_NUM")"
moved=0
parked=false

for workspace in "${workspaces[@]}"; do
	num="$(jq -r '.num' <<<"$workspace")"
	name="$(jq -r '.name' <<<"$workspace")"
	selector="$(workspace_selector "$num" "$name")"

	if ! swaymsg -q -- "workspace $selector, move workspace to output $target_arg"; then
		die "Failed to move workspace $name to $TARGET_OUTPUT."
	fi

	((moved += 1))
done

if jq -e --arg output "$PARKING_OUTPUT" '.[] | select(.name == $output and .active == true)' >/dev/null <<<"$outputs_json"; then
	if ! swaymsg -q -- "workspace $parking_workspace_selector, move workspace to output $parking_output_arg"; then
		die "Failed to move workspace $PARKING_WORKSPACE_NUM to $PARKING_OUTPUT."
	fi
	parked=true
fi

original_num="$(jq -r '.num' <<<"$original_workspace")"
original_name="$(jq -r '.name' <<<"$original_workspace")"
original_selector="$(workspace_selector "$original_num" "$original_name")"
swaymsg -q -- "workspace $original_selector" || true

if [[ "$parked" == true ]]; then
	message="Moved $moved workspace(s) to $TARGET_OUTPUT and parked workspace $PARKING_WORKSPACE_NUM on $PARKING_OUTPUT."
else
	message="Moved $moved workspace(s) to $TARGET_OUTPUT. $PARKING_OUTPUT is not active, so workspace $PARKING_WORKSPACE_NUM was not parked."
fi

notify "Workspaces moved" "$message"
echo "$message"
