#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Configuration
# ==============================================================================

OUTPUT_DIR="$HOME/videos/screencasts"

# Video
VIDEO_SOURCE="portal"     # portal | screen
FRAME_RATE="60"           # 5 | 10 | 15 | 20 | 30 | 60 | 100 | 120 | 144 | 165 | 240
VIDEO_CODEC="h264"        # h264 | hevc | av1 | vp8 | vp9 | hevc_hdr | av1_hdr
VIDEO_QUALITY="very_high" # medium | high | very_high | ultra
COLOR_RANGE="limited"     # limited | full
RESOLUTION="original"     # original | 1920x1080 | 2560x1440 | 3840x2160 | 1280x720
SHOW_CURSOR="yes"         # yes | no

# Audio
AUDIO_SOURCE="default_input" # none | default_output | default_input | both
AUDIO_CODEC="opus"           # opus | aac

# ==============================================================================
# State files
# ==============================================================================

STATE_DIR="${XDG_RUNTIME_DIR:-/tmp}"
PIDFILE="$STATE_DIR/screen-record.pid"
PATHFILE="$STATE_DIR/screen-record.path"
LOGFILE="$STATE_DIR/screen-record.log"
LOCKFILE="$STATE_DIR/screen-record.lock"

# ==============================================================================
# Helpers
# ==============================================================================

notify() {
	notify-send -a "Screen Recorder" "$@" 2>/dev/null || true
}

die() {
	notify "Error" "$1"
	echo "ERROR: $1" >&2
	exit 1
}

RECORDER_CMD=()

resolve_recorder_cmd() {
	if command -v gpu-screen-recorder >/dev/null 2>&1; then
		RECORDER_CMD=(gpu-screen-recorder)
	elif command -v flatpak >/dev/null 2>&1 &&
		flatpak list --app 2>/dev/null | grep -q 'com.dec05eba.gpu_screen_recorder'; then
		RECORDER_CMD=(flatpak run --command=gpu-screen-recorder com.dec05eba.gpu_screen_recorder)
	else
		die "gpu-screen-recorder not found. Install it or the flatpak variant."
	fi
}

restart_portal() {
	echo "$1"
	systemctl --user restart xdg-desktop-portal.service 2>/dev/null || true
	sleep 2
}

portal_dbus_ping() {
	timeout 3 dbus-send --session \
		--dest=org.freedesktop.portal.Desktop \
		--type=method_call --print-reply \
		/org/freedesktop/portal/desktop \
		org.freedesktop.DBus.Peer.Ping >/dev/null 2>&1
}

check_portals() {
	if ! pidof xdg-desktop-portal >/dev/null 2>&1 ||
		! pgrep -f 'xdg-desktop-portal-' >/dev/null 2>&1; then
		restart_portal "Portal not running, attempting restart..."
		pidof xdg-desktop-portal >/dev/null 2>&1 || return 1
		pgrep -f 'xdg-desktop-portal-' >/dev/null 2>&1 || return 1
		echo "Portal restarted successfully."
	fi

	if ! portal_dbus_ping; then
		restart_portal "Portal dbus unresponsive, restarting..."
		portal_dbus_ping || return 1
		echo "Portal dbus recovered."
	fi
}

is_recorder_process() {
	local pid="$1"
	[[ "$(cat /proc/"$pid"/comm 2>/dev/null)" == "gpu-screen-reco" ]]
}

get_recorder_pid() {
	if [[ -f "$PIDFILE" ]]; then
		local pid
		pid="$(<"$PIDFILE")"
		if kill -0 "$pid" 2>/dev/null && is_recorder_process "$pid"; then
			echo "$pid"
			return 0
		fi
		rm -f "$PIDFILE"
	fi
	# Fallback: kernel truncates process name to 15 chars
	local fallback
	fallback="$(pgrep -x gpu-screen-reco 2>/dev/null || true)"
	if [[ -n "$fallback" ]]; then
		echo "$fallback" | head -1
	fi
	return 0
}

is_recording() {
	[[ -n "$(get_recorder_pid)" ]]
}

cleanup_state() {
	rm -f "$PIDFILE" "$PATHFILE"
}

graceful_kill() {
	local pid="$1" wait_ticks="${2:-10}"
	kill -INT "$pid" 2>/dev/null || true
	local i=0
	while kill -0 "$pid" 2>/dev/null && ((i < wait_ticks)); do
		sleep 0.1
		i=$((i + 1))
	done
	if kill -0 "$pid" 2>/dev/null; then
		kill -9 "$pid" 2>/dev/null || true
		return 1
	fi
}

kill_stale() {
	local pids
	pids="$(pgrep -x gpu-screen-reco 2>/dev/null || true)"
	[[ -z "$pids" ]] && return

	echo "Killing stale gpu-screen-recorder instance(s)..."
	local pid
	for pid in $pids; do
		graceful_kill "$pid" 10 || true
	done

	cleanup_state
	echo "Stale instance(s) cleaned up."
}

# ==============================================================================
# Stop recording
# ==============================================================================

stop_recording() {
	local pid
	pid="$(get_recorder_pid)"

	if [[ -z "$pid" ]]; then
		echo "No recording process found."
		return 0
	fi

	local saved_path=""
	if [[ -f "$PATHFILE" ]]; then
		saved_path="$(<"$PATHFILE")"
	fi

	echo "Stopping recording (PID $pid)..."

	if ! graceful_kill "$pid" 30; then
		notify "Recording killed" "Force-stopped (file may be incomplete). Log: $LOGFILE"
	elif [[ -n "$saved_path" && -f "$saved_path" ]]; then
		local size
		size="$(du -h "$saved_path" | cut -f1)"
		notify "Recording saved" "$saved_path ($size)"
		echo "Saved: $saved_path ($size)"
	else
		notify "Recording stopped" "No output file found"
		echo "Recording stopped (no output file)."
	fi

	cleanup_state
}

# ==============================================================================
# Start recording
# ==============================================================================

select_region() {
	if ! command -v slurp >/dev/null 2>&1; then
		die "slurp is required for region recording."
	fi

	slurp -f '%wx%h+%x+%y' || true
}

start_recording() {
	local region="${1:-}"

	resolve_recorder_cmd

	if [[ -z "$region" ]] && ! check_portals; then
		die "xdg-desktop-portal (+ compositor backend) not running and could not be restarted."
	fi

	# Kill any stale instances before starting
	if is_recording; then
		echo "Existing recording detected."
		kill_stale
	fi

	mkdir -p "$OUTPUT_DIR"

	local timestamp
	timestamp="$(date '+%Y%m%d_%H%M%S')"
	local output_file="${OUTPUT_DIR}/${timestamp}${region:+-region}.mp4"

	# Build flags
	local flags=()
	if [[ -n "$region" ]]; then
		flags+=(-w region -region "$region")
	else
		flags+=(-w "$VIDEO_SOURCE")
	fi
	flags+=(-f "$FRAME_RATE")
	flags+=(-k "$VIDEO_CODEC")
	flags+=(-q "$VIDEO_QUALITY")
	flags+=(-cr "$COLOR_RANGE")
	flags+=(-cursor "$SHOW_CURSOR")

	if [[ "$RESOLUTION" != "original" ]]; then
		flags+=(-s "$RESOLUTION")
	fi

	if [[ "$AUDIO_SOURCE" != "none" ]]; then
		flags+=(-ac "$AUDIO_CODEC")
		if [[ "$AUDIO_SOURCE" == "both" ]]; then
			flags+=(-a "default_output|default_input")
		else
			flags+=(-a "$AUDIO_SOURCE")
		fi
	fi

	flags+=(-o "$output_file")

	echo "Launching recorder..."

	# Close fd 9 (flock) so the child doesn't inherit the lock
	"${RECORDER_CMD[@]}" "${flags[@]}" 2>"$LOGFILE" 9>&- &

	local rec_pid=$!
	echo "$rec_pid" >"$PIDFILE"
	echo "$output_file" >"$PATHFILE"
	disown

	# Verify the process is still alive after 2s (catches cancelled portal, startup errors)
	sleep 2

	if ! kill -0 "$rec_pid" 2>/dev/null; then
		cleanup_state
		local log_tail=""
		if [[ -f "$LOGFILE" ]]; then
			log_tail="$(tail -5 "$LOGFILE" 2>/dev/null || true)"
		fi
		if [[ -n "$log_tail" ]]; then
			die "Recording failed to start:\n$log_tail"
		else
			die "Recording failed to start (portal cancelled or unknown error)."
		fi
	fi

	echo "Recording started → $output_file"
	notify "Recording started"
}

# ==============================================================================
# Status
# ==============================================================================

show_status() {
	local pid
	pid="$(get_recorder_pid)"

	if [[ -z "$pid" ]]; then
		echo "Not recording."
		return
	fi

	echo "Recording in progress (PID $pid)"

	if [[ -f "$PATHFILE" ]]; then
		echo "Output: $(<"$PATHFILE")"
	fi

	if [[ -f "$PIDFILE" ]]; then
		local started
		started="$(stat -c %Y "$PIDFILE" 2>/dev/null || echo "")"
		if [[ -n "$started" ]]; then
			local now elapsed mins secs
			now="$(date +%s)"
			elapsed=$((now - started))
			mins=$((elapsed / 60))
			secs=$((elapsed % 60))
			printf "Duration: %dm%02ds\n" "$mins" "$secs"
		fi
	fi
}

# ==============================================================================
# Main
# ==============================================================================

usage() {
	echo "Usage: $(basename "$0") [start|stop|toggle|region|status]"
	echo ""
	echo "  start   Start a new recording"
	echo "  stop    Stop the current recording"
	echo "  toggle  Toggle recording on/off (default)"
	echo "  region  Start recording a region selected with slurp"
	echo "  status  Show current recording status"
}

action="${1:-toggle}"

exec 9>"$LOCKFILE"
if ! flock -n 9; then
	die "Another instance of this script is already running."
fi

case "$action" in
start)
	if is_recording; then
		die "Already recording (PID $(get_recorder_pid)). Stop first."
	fi
	start_recording
	;;
stop)
	if ! is_recording; then
		die "Not recording."
	fi
	stop_recording
	;;
toggle)
	if is_recording; then
		stop_recording
	else
		start_recording
	fi
	;;
region)
	if is_recording; then
		die "Already recording (PID $(get_recorder_pid)). Stop first."
	fi
	region="$(select_region)"
	if [[ -z "$region" ]]; then
		notify "Recording cancelled" "No region selected."
		exit 0
	fi
	start_recording "$region"
	;;
status)
	show_status
	;;
-h | --help | help)
	usage
	;;
*)
	echo "Unknown action: $action"
	usage
	exit 1
	;;
esac
