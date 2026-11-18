# This project's agent container: the NixOS system it runs, the host folders it sees, and the commands that run it.
# The project's dependencies and services are in ../devenv.nix; shells in the project enter its devenv shell.
#
# WHAT A CONTAINER IS HERE
#   A NixOS system started by systemd-nspawn on my host (nixos-container is NixOS's tool around it). It shares my
#   host's kernel but has its own processes, users, network and root filesystem. On my host it consists of:
#     /var/lib/nixos-containers/<name>             its root filesystem: its home, /var, /etc (survives restarts)
#     /etc/nixos-containers/<name>.conf            its addresses and nspawn flags (create writes it; so do my commands)
#     /nix/var/nix/profiles/per-container/<name>   which build of the system below it runs
#     container@<name>.service                     the host unit that runs systemd-nspawn for it
#   It reads my host's /nix/store and talks to my host's Nix daemon, so nothing is installed twice and builds run on my
#   host, as an untrusted user of the daemon.
#
# WHAT I GET INSIDE, as in my devcontainers
#   - my tools: the package my devenv devcontainer installs (.devcontainer/tools in my dotfiles: chezmoi, neovim,
#     herdr, claude, pi, agent-browser, gh, ...), part of the system, so nothing downloads per container
#   - my dotfiles: the first entry runs chezmoi init --apply from my dotfiles repo, as crib does
#   - herdr: its server runs as a service, so agents keep running after I detach; `nix run path:.agentbox#herdr`
#     attaches, while `nix run path:.agentbox` opens a plain zsh
#   - the project's devenv: shells and herdr panes in the project are in its devenv shell (my zshrc's devenv hook; the
#     first entry runs devenv allow); `devenv up` in one of them starts its services
#   - the host environment variables I pick (env below) and the host files or folders I mount (mounts below)
#   - a desktop with chromium for the agent's browser, which I watch over VNC, clipboard shared
#
# WHAT THE AGENT INSIDE CAN AND CANNOT DO (with my host's nixos/hosts/x1/agentbox.nix applied)
#   It runs as my uid 1000 inside, without sudo. It can:
#     - read and write the project and its Claude sessions (the mounts below), and read my whole Nix store
#     - read the env variables and any other mounts I pass in
#     - reach the internet, and build or download anything through my host's Nix daemon
#     - read my host's clipboard and set what I paste, while the desktop viewer is open (shared on purpose)
#   It cannot see my host's files, processes, or other containers, open connections to my host or my LAN, or change
#   its own system. Its ways out are:
#     - things I later run or read on my host from the project: .git hooks and config (git runs them), scripts,
#       devenv.nix on any devenv command (and on cd if I `devenv allow` it), this file on my next `nix run`,
#       Claude sessions I resume
#     - builds: a download build runs on my host's network; agentbox.nix keeps it off my host's addresses, the
#       containers and private ranges, but not off my host's abstract unix sockets or LAN devices' global IPv6
#     - bugs in the kernel, systemd-nspawn or the Nix daemon (all run as root on my host); a VM avoids those
#     - bugs in the VNC viewer, which runs as me against a server the agent can replace
#     - using up disk: nothing limits it (agentbox.nix caps each container's memory, CPU and processes)
#
# WHAT SURVIVES
#   A restart or host reboot keeps everything on disk: its home (my applied dotfiles, Claude login), /var, the project.
#   The project, its .devenv/state (the services' data), .browser-profile and Claude sessions are on my host, so they
#   also survive destroy; after destroy, the next entry applies my dotfiles again. herdr saves its layout in its home
#   (~/.config/herdr). /tmp, running processes and the agents in herdr are lost on every stop. It does not start with
#   my host: after a reboot, start.
#
# WHO CAN CHANGE THIS FILE
#   It sits in the project, so the agent can edit it, e.g. when I ask it to. It cannot apply a change itself: it has no
#   root in the container and no way to my host's nixos-container. But my next `nix run` here evaluates its version as
#   me and runs its scripts with my sudo. A look first only holds while the file cannot change underneath: with the
#   container stopped or the read-only mount below on, and without git, whose repo config the agent can set.
#
# COMMANDS, from the project's folder (each is a script below, run as me; it calls sudo where it needs root):
#   nix run path:.agentbox#create     create the container (builds its system first)
#   nix run path:.agentbox#start      start it; herdr's server starts with it
#   nix run path:.agentbox            zsh in the project, inside the container; my dotfiles on the first entry
#   nix run path:.agentbox#herdr      herdr in the project, the same way
#   nix run path:.agentbox#desktop    view its desktop, where the agent's browser runs, or print the SSH tunnel to it
#   nix run path:.agentbox#update     after editing the system: switch the running container to it
#   nix run path:.agentbox#mounts     after editing the mounts, or when create stopped halfway: write them, start
#   nix run path:.agentbox#stop       stop it
#   nix run path:.agentbox#destroy    delete it: its home goes (dotfiles, Claude login); the project and .devenv stay
# path: makes nix copy only this folder to the store, not the whole repository. My tools and dotfiles come from my
# dotfiles repo on GitHub, so a change there reaches the container once pushed: for the tools, `nix flake update tools`
# here, then update; for the dotfiles, `chezmoi update` inside.
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    # nixos-26.05 has no herdr; my tools package (on nixos-unstable) has it. The devenv branch until it is merged.
    tools.url = "github:mgajewskik/dotfiles/devenv?dir=.devcontainer/tools";
  };

  outputs =
    {
      self,
      nixpkgs,
      tools,
    }:
    let
      lib = nixpkgs.lib;
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
      name = "myproj"; # the container's name: unique on my host, at most 11 characters
      user = "mgajewskik";
      project = "/home/mgajewskik/code/myproj"; # the folder holding devenv.nix and .agentbox
      dotfiles = "https://github.com/mgajewskik/dotfiles";
      dotfilesBranch = "devenv"; # main once the devenv branch is merged
      myTools = tools.packages.x86_64-linux.default;
      # Claude keeps a project's sessions under its path, with each character that is not a letter or digit as -
      claudeSessions = "/home/${user}/.claude/projects/${
        lib.stringAsChars (c: if builtins.match "[A-Za-z0-9]" c == null then "-" else c) (lib.removeSuffix "/" project)
      }";

      # Host environment variables passed in, as name inside = name on my host. Each `nix run path:.agentbox` writes
      # my shell's current values to envFile (mode 600, on my host), mounted read-only at /etc/agentbox.env, which
      # every zsh inside reads, herdr panes included. The values never enter the Nix store. The agent can read them:
      # pass only what it may use, e.g. a read-only token, as crib gets.
      env = {
        # GITHUB_TOKEN = "GITHUB_READONLY";
        # CLAUDE_CODE_OAUTH_TOKEN = "CLAUDE_CODE_OAUTH_TOKEN"; # from claude setup-token; else log in inside once
      };
      envFile = "/home/${user}/.local/state/agentbox/${name}.env";

      # Host folders or files the container sees, at the same paths, so Claude sessions are shared with my host and
      # tools see the same paths inside and out. The host path must exist, and not lie inside another rw mount, where
      # the agent could swap it for a symlink. With :idmap each uid inside writes as the same uid on my host: my uid
      # 1000 owns my files, and root inside would write as root. A credential mounted here is the agent's too.
      mounts = {
        ${project} = "rw";
        ${claudeSessions} = "rw";
        # "/home/${user}/notes" = "ro";
        # "/home/${user}/.config/gh" = "ro";
        # keep the agent from editing this folder while it runs (the one exception to the rule above; the agent can
        # still change it through .git, which my git checkout would apply)
        # "${project}/.agentbox" = "ro";
      };

      # Lines appended to the container's conf, which the host unit reads before starting nspawn. PRIVATE_USERS=pick
      # gives the container its own range of host uids, so root inside is an unused uid on my host, outside the
      # mounts. EXTRA_NSPAWN_FLAGS adds the mounts and the env file.
      conf = "/etc/nixos-containers/${name}.conf";
      confLines = ''
        PRIVATE_USERS=pick
        EXTRA_NSPAWN_FLAGS="${
          lib.concatMapAttrsStringSep " " (
            path: mode: "--bind${lib.optionalString (mode == "ro") "-ro"}=${path}:${path}:idmap"
          ) mounts
        } --bind-ro=${envFile}:/etc/agentbox.env:idmap"
      '';
      writeConf = "printf %s ${lib.escapeShellArg confLines} | sudo tee -a ${conf} >/dev/null";

      # Without PRIVATE_USERS the container would run with my host's uids, its root as my host's root. And nspawn
      # follows symlinks on the way to a mount point inside the container, where the agent owns its home: a symlink
      # it left would put an rw mount wherever it points, e.g. over files container root reads. So the container
      # starts only through here, never with nixos-container restart.
      start = ''
        if ! grep -qx PRIVATE_USERS=pick ${conf}; then
          echo "${conf} lacks PRIVATE_USERS=pick; run: nix run path:.agentbox#create, or #mounts if it exists" >&2
          exit 1
        fi
        # nspawn refuses to start without it, and Claude only makes it on first use
        mkdir -p ${lib.escapeShellArg claudeSessions}
        for path in ${lib.escapeShellArgs (builtins.attrNames mounts ++ [ "/etc/agentbox.env" ])}; do
          inside=/var/lib/nixos-containers/${name}
          IFS=/ read -ra parts <<<"''${path#/}"
          for part in "''${parts[@]}"; do
            inside+="/$part"
            if sudo test -L "$inside"; then
              echo "$inside is a symlink; remove it, then start again" >&2
              exit 1
            fi
          done
        done
        # nspawn fails to start without the file it mounts
        if [ ! -e ${envFile} ]; then
          install -D -m 600 /dev/null ${envFile}
        fi
        sudo nixos-container start ${name}
      '';

      # What every entry runs inside, in the project: the first time, my dotfiles, devenv's trust in the project, and
      # herdr's server reloading the config the dotfiles just wrote; then the program it is given (zsh or herdr).
      enter = pkgs.writeShellApplication {
        name = "agentbox-enter";
        text = ''
          cd ${project}
          if [ ! -e ~/.local/state/agentbox/ready ]; then
            chezmoi init --apply --branch ${dotfilesBranch} ${dotfiles}
            devenv allow
            # fails when the herdr service is down; herdr then starts its own server, which reads the config anyway
            herdr server reload-config || true
            mkdir -p ~/.local/state/agentbox
            touch ~/.local/state/agentbox/ready
          fi
          exec "$@"
        '';
      };

      # Writes the env file, then opens a login through the container's own systemd (machinectl: no sshd, no keys)
      # that runs agentbox-enter with the given program.
      login = program: ''
        umask 077
        pairs=(${lib.escapeShellArgs (lib.mapAttrsToList (inside: host: "${inside}=${host}") env)})
        for pair in "''${pairs[@]}"; do
          host=''${pair#*=}
          if [ -n "''${!host-}" ]; then
            printf 'export %s=%q\n' "''${pair%%=*}" "''${!host}"
          fi
        done >${envFile}
        chmod 600 ${envFile}
        sudo machinectl shell ${user}@${name} /run/current-system/sw/bin/bash -lc ${lib.escapeShellArg "agentbox-enter ${program}"}
      '';

      # The system below, built by nix as me when a command that names it runs; root gets the finished result.
      system = self.nixosConfigurations.container.config.system.build.toplevel;

      commands = {
        # nixos-container create makes the root filesystem, picks free addresses (10.233.x.1 for my host, .2 for the
        # container), writes the conf, and points the container's profile at the system
        create = ''
          sudo nixos-container create ${name} --system-path ${system}
          ${writeConf}
        '';
        inherit start;
        # zsh in the project, which my zshrc's devenv hook puts in the devenv shell
        shell = login "zsh -l";
        # herdr in the project; detaching leaves its agents running
        herdr = login "herdr";
        # The viewer needs a display, so over SSH it runs on the machine I sit at, through a tunnel to the container.
        # RemoteResize makes the container's screen follow the viewer's window, and its window manager keeps the
        # browser filling the screen. The clipboard is shared both ways while the viewer runs: what I copy reaches the
        # container, and what the container copies can land in what I paste. -SendClipboard=0 -SendPrimary=0 keeps
        # mine to myself.
        desktop = ''
          ip=$(nixos-container show-ip ${name})
          echo "From the machine I sit at: ssh -N -L 5901:$ip:5901 $(uname -n), then vncviewer -RemoteResize=1 localhost:5901"
          if [ -z "''${DISPLAY-}" ] && [ -z "''${WAYLAND_DISPLAY-}" ]; then
            exit 0
          fi
          exec ${pkgs.tigervnc}/bin/vncviewer -RemoteResize=1 "$ip:5901"
        '';
        # the two steps nixos-container update takes after building: point the profile at the new system, then have
        # the container switch to it in place (services restart as needed; the container keeps running)
        update = ''
          sudo nix-env -p /nix/var/nix/profiles/per-container/${name}/system --set ${system}
          sudo systemctl reload container@${name}
        '';
        # nspawn reads mounts only when it starts, so changing them takes a stop and a start
        mounts = ''
          sudo nixos-container stop ${name}
          sudo sed -i '/^PRIVATE_USERS=/,$d' ${conf}
          ${writeConf}
          ${start}
        '';
        stop = "sudo nixos-container stop ${name}";
        destroy = "sudo nixos-container destroy ${name}";
      };
    in
    {
      # each command becomes a script in the store (writeShellApplication: shellchecked when built, stops at the first
      # failing line) that `nix run path:.agentbox#<command>` runs; the default is the shell
      apps.x86_64-linux = lib.mapAttrs (command: text: {
        type = "app";
        program = lib.getExe (pkgs.writeShellApplication {
          name = "${name}-${command}";
          inherit text;
        });
      }) (commands // { default = commands.shell; });

      # the container's system: a plain NixOS configuration; every NixOS option works here
      nixosConfigurations.container = nixpkgs.lib.nixosSystem {
        modules = [
          (
            { pkgs, ... }:
            {
              boot.isNspawnContainer = true; # no bootloader or kernel: nspawn starts systemd directly
              nixpkgs.hostPlatform = "x86_64-linux";
              system.stateVersion = "26.05";

              # The host side of the network is set up by the container's start script: a veth pair, my host at
              # 10.233.x.1 and the container at 10.233.x.2, NAT to the internet.
              networking.hostName = name;
              networking.useDHCP = false;
              # my host's resolv.conf points at its own resolver, which the container cannot reach
              networking.useHostResolvConf = false;
              networking.nameservers = [ "9.9.9.9" ];
              # what my host may open at the container's IP: the desktop, and the app from ../devenv.nix
              networking.firewall.allowedTCPPorts = [
                5901
                8080
              ];

              # my user with my uid, so files in the mounts keep my ownership on both sides; zsh, which my dotfiles
              # configure
              users.users.${user} = {
                isNormalUser = true;
                uid = 1000;
                shell = pkgs.zsh;
                # my user's systemd runs from boot, for the herdr service below
                linger = true;
              };
              programs.zsh.enable = true;
              # in every interactive zsh, herdr panes included, so a pane opened later sees the values from my latest
              # entry
              programs.zsh.interactiveShellInit = ''
                if [ -r /etc/agentbox.env ]; then
                  . /etc/agentbox.env
                fi
              '';
              # nspawn creates the folders above a mount as root, and my user must write in them: Claude in these, herdr
              # and chezmoi in ~/.config. A new mount under my home needs its parent folders here too.
              systemd.tmpfiles.rules = [
                "d /home/${user}/.claude 0700 ${user} users -"
                "d /home/${user}/.claude/projects 0700 ${user} users -"
                "d /home/${user}/.config 0755 ${user} users -"
              ];
              # Never give the agent root here: root in a NixOS container can write to my host as root, through the
              # files the container's start script copies, the Nix profile folders it mounts, and the mounts above.
              security.sudo.enable = false;
              # no setuid programs (su, passwd, mount, fusermount, newuidmap, ...): a bug in one would be a way to root.
              # Except unix_chkpwd, which pam_unix runs to check my account when my user's systemd starts; without it
              # user@1000 fails with "cannot retrieve authentication info", and herdr's service with it. These are
              # nixos-26.05's defaults; a wrapper a later nixpkgs adds comes back on.
              security.wrappers = lib.genAttrs [
                "chsh"
                "fusermount"
                "fusermount3"
                "mount"
                "newgidmap"
                "newgrp"
                "newuidmap"
                "passwd"
                "sg"
                "su"
                "umount"
              ] (_: { enable = false; });

              # nix inside uses my host's daemon; devenv needs flakes
              nix.settings.experimental-features = [
                "nix-command"
                "flakes"
              ];
              # binaries that tools download (nvim's language servers, npm or pip packages) find a loader, and nvim
              # compiles its tree-sitter parsers
              programs.nix-ld.enable = true;
              fonts.enableDefaultPackages = true;
              environment.systemPackages = [
                myTools
                enter
                pkgs.devenv
                pkgs.git
                pkgs.chromium
                pkgs.gcc
                pkgs.gnumake
                pkgs.curl
                pkgs.unzip
              ];

              # herdr's server whenever the container runs, so agents in its panes keep running when I detach, as a
              # service of my user's systemd, which linger starts at boot. Its panes then get the XDG_RUNTIME_DIR my
              # logins get, so `devenv up` in a pane and psql in a login find the same sockets. update does not restart
              # user services, so a tools change does not kill the agents; the new herdr takes over at the next stop and
              # start. Logs: journalctl --user -u herdr, inside.
              systemd.user.services.herdr = {
                wantedBy = [ "default.target" ];
                unitConfig.ConditionUser = user;
                path = [ "/run/current-system/sw" ];
                serviceConfig = {
                  WorkingDirectory = project;
                  ExecStart = "${myTools}/bin/herdr server";
                  Restart = "on-failure";
                };
              };

              # A virtual X display :1 that I watch over VNC, where the agent's browser opens its windows. No password:
              # my host's firewall table lets only my host open it.
              systemd.services.desktop = {
                wantedBy = [ "multi-user.target" ];
                serviceConfig.User = user;
                serviceConfig.ExecStart = "${pkgs.tigervnc}/bin/Xvnc :1 -geometry 1920x1080 -rfbport 5901 -SecurityTypes None -ac";
              };
              # a window manager that keeps every window filling the screen, as the screen follows the viewer's size
              systemd.services.desktop-wm = {
                wantedBy = [ "multi-user.target" ];
                bindsTo = [ "desktop.service" ];
                after = [ "desktop.service" ];
                environment.DISPLAY = ":1";
                serviceConfig = {
                  User = user;
                  ExecStart = "${pkgs.matchbox}/bin/matchbox-window-manager -use_titlebar no";
                  Restart = "on-failure";
                  RestartSec = 1;
                };
              };
              # agent-browser (from my tools) drives chromium visibly on that display, with its profile (logins,
              # cookies) in the project, so they survive deleting the container; gitignored
              environment.variables = {
                DISPLAY = ":1";
                AGENT_BROWSER_HEADED = "true";
                AGENT_BROWSER_EXECUTABLE_PATH = lib.getExe pkgs.chromium;
                AGENT_BROWSER_PROFILE = "${project}/.browser-profile";
              };
            }
          )
        ];
      };
    };
}
