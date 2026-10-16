#!/bin/bash
# Runs once as vscode when the test container is created: system packages, my dotfiles from this checkout
# (they install the browser agent-browser drives), then gpg through the host.
set -euo pipefail

sudo apt-get update -qq
# file: yazi previews; gnupg: setup-gpg.sh; build-essential: nvim-treesitter compiles its parsers with cc;
# jq: dot_claude/modify_settings.json.tmpl runs before mise installs its jq; socat: vnc-relay in devcontainer.json;
# the rest: network debugging (dig, ping, nc, traceroute, tcpdump, mtr, nmap, iperf3, whois)
# noninteractive: iperf3 would otherwise ask whether to start its daemon
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
    file gnupg build-essential jq socat \
    bind9-dnsutils iputils-ping netcat-openbsd traceroute tcpdump mtr-tiny nmap iperf3 whois

./setup.sh
.devcontainer/setup-gpg.sh
# the base image ships oh-my-zsh; my .zshrc, now in place, does not use it
rm -rf "$HOME/.oh-my-zsh"
