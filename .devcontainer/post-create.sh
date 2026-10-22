#!/bin/bash
# Runs once as vscode when the test container is created: system packages, my dotfiles from this checkout
# (they install the browser agent-browser drives), then gpg through the host.
set -euo pipefail

sudo apt-get update -qq
# file: yazi previews; gnupg: setup-gpg.sh; build-essential: nvim-treesitter compiles its parsers with cc;
# jq: dot_claude/modify_settings.json.tmpl runs before mise installs its jq; socat: vnc-relay in devcontainer.json;
# openssh-server: sshd for my host's herdr to connect to this container as a machine; my ssh config starts it
# per connection through podman exec, so no daemon runs;
# the rest: network debugging (dig, ping, nc, traceroute, tcpdump, mtr, nmap, iperf3, whois)
# noninteractive: iperf3 would otherwise ask whether to start its daemon
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
    file gnupg build-essential jq socat openssh-server \
    bind9-dnsutils iputils-ping netcat-openbsd traceroute tcpdump mtr-tiny nmap iperf3 whois

./setup.sh
.devcontainer/setup-gpg.sh
# the base image ships oh-my-zsh; my .zshrc, now in place, does not use it
rm -rf "$HOME/.oh-my-zsh"
# sshd lets in only my crib key (~/.ssh/config.d/crib uses it for crib-* hosts); crib's ssh plugin
# copies the .pub files from my ~/.ssh here before this script runs, and none with the plugin off
if [ -f "$HOME/.ssh/crib_ed25519.pub" ]; then
    cp "$HOME/.ssh/crib_ed25519.pub" "$HOME/.ssh/authorized_keys"
fi
