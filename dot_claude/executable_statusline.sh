#!/usr/bin/env bash
# Codex-style status line for Claude Code. Reads session JSON on stdin and prints one line:
# Opus high · Context 8% used · 5h 23% used · weekly 49% left · ~/.claude · main · No changes · PR #12 · my-session
# Segments without data (rate limits before the first response, git outside a repo, no PR) are left out.

export LC_ALL=C # printf '%.0f' must parse "49.5" even under a comma-decimal locale

# 24-bit foreground color from a hex code, e.g. fg 7E9CD8
fg() { printf '\e[38;2;%d;%d;%dm' "0x${1:0:2}" "0x${1:2:2}" "0x${1:4:2}"; }

# Kanagawa Wave palette (rebelot/kanagawa.nvim)
RESET=$'\e[0m' BOLD=$'\e[1m'
FUJI_GRAY=$(fg 727169)       # labels and separators
OLD_WHITE=$(fg C8C093)       # session name
CRYSTAL_BLUE=$(fg 7E9CD8)    # model
SPRING_VIOLET2=$(fg 9CABCA)  # effort
SPRING_BLUE=$(fg 7FB4CA)     # directory
ONI_VIOLET=$(fg 957FB8)      # branch
SURIMI_ORANGE=$(fg FFA066)   # uncommitted changes
WAVE_AQUA2=$(fg 7AA89F)      # PR / MR
SPRING_GREEN=$(fg 98BB6C)    # usage below 50%
CARP_YELLOW=$(fg E6C384)     # usage 50-79%
PEACH_RED=$(fg FF5D62)       # usage 80% and up

# Bold, bright color for a used percentage so it stands out from the gray labels.
usage_color() {
  if (($1 >= 80)); then
    printf '%s' "$BOLD$PEACH_RED"
  elif (($1 >= 50)); then
    printf '%s' "$BOLD$CARP_YELLOW"
  else
    printf '%s' "$BOLD$SPRING_GREEN"
  fi
}

# Gray label text, e.g. label "used"
label() { printf '%s' "$FUJI_GRAY$1$RESET"; }

eval "$(jq -r '@sh "
  model=\(.model.display_name // "")
  effort=\(.effort.level // "")
  context=\(.context_window.used_percentage // 0)
  five_hour=\(.rate_limits.five_hour.used_percentage // "")
  weekly=\(.rate_limits.seven_day.used_percentage // "")
  dir=\(.workspace.current_dir // .cwd // "")
  pr_number=\(.pr.number // "")
  pr_kind=\(.pr.kind // "")
  session=\(.session_name // "")
"')"

parts=("$BOLD$CRYSTAL_BLUE$model$RESET${effort:+ $SPRING_VIOLET2$effort$RESET}")

context=$(printf '%.0f' "$context")
parts+=("$(label Context) $(usage_color "$context")$context%$RESET $(label used)")

if [[ -n $five_hour ]]; then
  five_hour=$(printf '%.0f' "$five_hour")
  parts+=("$(label 5h) $(usage_color "$five_hour")$five_hour%$RESET $(label used)")
fi

if [[ -n $weekly ]]; then
  weekly=$(printf '%.0f' "$weekly")
  parts+=("$(label weekly) $(usage_color "$weekly")$((100 - weekly))%$RESET $(label left)")
fi

display_dir=$dir
[[ $dir == "$HOME"* ]] && display_dir="~${dir#"$HOME"}"
parts+=("$SPRING_BLUE$display_dir$RESET")

if git -C "$dir" rev-parse --is-inside-work-tree &>/dev/null; then
  branch=$(git -C "$dir" branch --show-current)
  [[ -z $branch ]] && branch=$(git -C "$dir" rev-parse --short HEAD)
  parts+=("$ONI_VIOLET$branch$RESET")

  changed=$(git -C "$dir" --no-optional-locks status --porcelain | wc -l)
  if ((changed == 0)); then
    parts+=("$(label 'No changes')")
  else
    parts+=("$SURIMI_ORANGE$changed changed$RESET")
  fi
fi

if [[ -n $pr_number ]]; then
  if [[ $pr_kind == mr ]]; then
    parts+=("${WAVE_AQUA2}MR !$pr_number$RESET")
  else
    parts+=("${WAVE_AQUA2}PR #$pr_number$RESET")
  fi
fi

[[ -n $session ]] && parts+=("$OLD_WHITE$session$RESET")

line=${parts[0]}
for part in "${parts[@]:1}"; do
  line+="$(label ' · ')$part"
done
echo "$line"
