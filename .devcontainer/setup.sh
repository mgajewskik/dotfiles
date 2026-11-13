#!/usr/bin/env bash
# Runs as vscode on every container start, from the project root, after my dotfiles: this project's dependencies.
set -euo pipefail

"$HOME/.local/bin/mise" install
