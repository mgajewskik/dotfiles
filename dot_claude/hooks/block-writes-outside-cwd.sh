#!/usr/bin/env bash
# The Bash sandbox doesn't cover the Edit/Write/NotebookEdit tools; this hook
# applies the same write boundary to them.
set -u

deny() {
    jq -cn --arg reason "$1" \
        '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$reason}}'
    exit 0
}

payload="$(cat)"
file="$(jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' <<<"$payload")" ||
    deny "Blocked: write-boundary hook could not parse its input."
[[ -z "$file" ]] && exit 0

cwd="$(jq -r '.cwd // empty' <<<"$payload")"
project="${CLAUDE_PROJECT_DIR:-$cwd}"
[[ -z "$project" ]] && deny "Blocked: write-boundary hook could not determine the working directory."
[[ "$file" != /* ]] && file="$cwd/$file"
target="$(realpath -m -- "$file")"

allowed_roots=(
    "$project"
    /tmp
    "$HOME/.agents/skills"
    "$HOME/.claude/plans"
)

for root in "${allowed_roots[@]}"; do
    root="$(realpath -m -- "$root")"
    [[ "$target" == "$root" || "$target" == "$root"/* ]] && exit 0
done

[[ "$target" == "$HOME"/.claude/projects/*/memory/* ]] && exit 0

deny "Blocked: $target is outside the working directory ($project). Writes are limited to the project, /tmp, ~/.agents/skills, and Claude plans/memory."
