#!/usr/bin/env bash
# Ralph loop: run headless Claude once per iteration with a fresh context until
# the plan is done. State lives in the repo: the plan file, code, and commits.
#
# Usage (from the repository root): ~/.claude/loop.sh <plan-file> <max-iterations>
# Exit: 0 plan complete, 1 out of iterations, 2 blocked, 3 no commit in 3 iterations.
#
# The plan file is any Markdown task list, for example:
#
#   # Goal
#   One paragraph: what done looks like, constraints, how to verify.
#
#   ## Tasks
#   - [ ] Highest-priority task first
#   - [ ] Next task
#
#   ## Notes
#   (Claude appends short learnings here for later iterations.)
set -euo pipefail

usage() {
    printf 'Usage: %s <plan-file> <max-iterations>\n' "$0" >&2
}

if [[ $# -ne 2 ]]; then
    usage
    exit 64
fi

plan_file=$1
max_iterations=$2

if [[ ! -f $plan_file ]]; then
    printf 'Plan file not found: %s\n' "$plan_file" >&2
    exit 66
fi

if [[ ! $max_iterations =~ ^[1-9][0-9]*$ ]]; then
    printf 'Max iterations must be a positive integer.\n' >&2
    exit 64
fi

# Commits need .git inside the sandbox's writable cwd, so no worktrees or subdirectories.
if [[ ! -d .git || -L .git ]]; then
    printf 'Run this loop from the root of a normal Git checkout (.git must be a real directory).\n' >&2
    exit 65
fi

instructions=$(printf '%s\n' \
    "You are one iteration of an unattended loop. The plan is in $plan_file; read it first." \
    'Pick exactly one highest-priority incomplete task. Do only that task.' \
    'Inspect the repository before changing it; do not assume something is unimplemented.' \
    'Implement the task and run the relevant tests and checks.' \
    'Mark the task done in the plan and add any learning the next iteration needs under its Notes section. Keep notes short.' \
    'Before committing, run the PASS-gate reviewer subagent and fix blockers until it returns PASS.' \
    'Only after PASS, commit the task. You are authorized to commit; do not push.' \
    'Stage only the files you changed, by path; never git add -A or git add . (the sandbox puts placeholder dotfiles in the repo).' \
    'IMPORTANT: every iteration must end with a new commit of PASS-reviewed work, or with <promise>BLOCKED</promise>. The loop counts commits and stops after 3 consecutive iterations without a new commit.' \
    'Do not ask questions. Make safe, scoped assumptions.' \
    'If you cannot make progress without a human, record why in the plan and end your response with <promise>BLOCKED</promise>.' \
    'Only if every task in the plan is done, end your response with <promise>COMPLETE</promise>.')

max_without_commit=3
retry_delay_seconds=60
iterations_without_commit=0

for ((i = 1; i <= max_iterations; i++)); do
    printf '\n=== Iteration %d of %d, started %(%F %T)T ===\n' "$i" "$max_iterations" -1 >&2
    SECONDS=0
    head_before=$(git rev-parse -q --verify HEAD || true)

    claude_status=0
    result=$(claude -p "$instructions") || claude_status=$?

    printf '%s\n' "$result"
    printf '=== Iteration %d took %dm%02ds ===\n' "$i" $((SECONDS / 60)) $((SECONDS % 60)) >&2

    if ((claude_status != 0)); then
        printf 'claude exited with status %d.\n' "$claude_status" >&2
    fi

    if [[ $result == *'<promise>COMPLETE</promise>' ]]; then
        printf 'Plan complete after %d iteration(s).\n' "$i" >&2
        exit 0
    fi

    if [[ $result == *'<promise>BLOCKED</promise>' ]]; then
        printf 'Blocked after %d iteration(s); see %s.\n' "$i" "$plan_file" >&2
        exit 2
    fi

    if [[ $(git rev-parse -q --verify HEAD || true) == "$head_before" ]]; then
        iterations_without_commit=$((iterations_without_commit + 1))
        if ((iterations_without_commit >= max_without_commit)); then
            printf 'No new commit in %d consecutive iterations; stopping. See %s.\n' "$max_without_commit" "$plan_file" >&2
            exit 3
        fi
    else
        iterations_without_commit=0
    fi

    if ((claude_status != 0 && i < max_iterations)); then
        printf 'Retrying in %ds.\n' "$retry_delay_seconds" >&2
        sleep "$retry_delay_seconds"
    fi
done

printf 'Stopped after %d iteration(s) without a completion signal.\n' "$max_iterations" >&2
exit 1
