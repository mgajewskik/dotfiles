#!/usr/bin/env bash
# A Bash command that combines `cd` with a heredoc hangs in the sandbox until the
# tool timeout; either one alone works. Deny that combination up front.
set -u

command="$(jq -r '.tool_input.command // empty' 2>/dev/null)" || exit 0

heredoc='(^|[^<])<<-?[[:space:]]*[\\"'\'']?[A-Za-z_]'
cd_word='(^|[;&|({]|then|do|else)[[:space:]]*(builtin[[:space:]]+)?cd([[:space:];&|)]|$)'

grep -qE "$heredoc" <<<"$command" || exit 0
# Only the lines up to the heredoc operator; a `cd` inside the body is harmless.
# ENVIRON, not -v: awk -v would unescape the backslash in the regex.
before_body="$(re="$heredoc" awk '{ print } $0 ~ ENVIRON["re"] { exit }' <<<"$command")"
grep -qE "$cd_word" <<<"$before_body" || exit 0

jq -cn '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:"Blocked: cd combined with a heredoc hangs in the Bash sandbox. Drop the cd (use absolute paths or git -C), or write the content with the Write tool and run it as a file."}}'
