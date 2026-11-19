#!/usr/bin/env bash
set -euo pipefail

git config --file ~/.gitconfig.local url."https://github.com/".insteadOf git@github.com:
git config --file ~/.gitconfig.local credential."https://github.com".helper '!gh auth git-credential'
