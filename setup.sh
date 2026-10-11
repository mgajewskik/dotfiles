#!/bin/bash
set -euo pipefail

if command -v zsh >/dev/null && sudo -n true 2>/dev/null; then
    sudo chsh -s "$(command -v zsh)" "$(id -un)" || echo "setup.sh: could not make zsh the login shell" >&2
fi

if command -v chezmoi >/dev/null; then
    chezmoi init --apply --source "$PWD"
    exit 0
fi

if command -v mise >/dev/null; then
    mise exec chezmoi -- chezmoi init --apply --source "$PWD"
    exit 0
fi

sh -c "$(curl -fsLS get.chezmoi.io)" -- -b "$HOME/.local/bin" init --apply --source "$PWD"
exit 0
