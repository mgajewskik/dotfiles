#!/bin/bash
set -euo pipefail

mkdir -p ~/.gnupg && chmod 700 ~/.gnupg
gpgconf --kill gpg-agent
ln -sf /run/host-gpg/S.gpg-agent "$(gpgconf --list-dirs agent-socket)"
