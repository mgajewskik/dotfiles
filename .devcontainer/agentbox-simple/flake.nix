# One project's agent container in one file: the NixOS system it runs, the host folders it sees, and the commands that
# run it. Set name and project, and keep this folder outside the project, e.g. ~/boxes/myproj/ or in my dotfiles:
# every command evaluates this file as me, runs its scripts with my sudo, and hands its system to root in the
# container, so the agent must not be able to edit it.
#
# My host needs, once: nixos/hosts/x1/agentbox.nix in my dotfiles (containers, NAT, and the firewall table that keeps
# containers off my host and LAN).
#
# From this folder:
#   nix run .#create     create the container (builds its system first)
#   nix run .#start      start it
#   nix run .            a shell in the project, inside its devenv shell when the project has a devenv.nix
#   nix run .#desktop    view its desktop, where the agent's browser runs
#   nix run .#update     after editing the system: switch the running container to it
#   nix run .#mounts     after editing the mounts, or when create stopped halfway: write them to the conf, start
#   nix run .#stop       stop it
#   nix run .#destroy    delete it: its home goes (Claude login), the project stays
# In a git repository, nix sees only files git knows (git add this folder first) and copies all of them into the
# Nix store, which the container can read: keep the folder out of repositories that hold secrets.
{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs =
    { self, nixpkgs }:
    let
      lib = nixpkgs.lib;
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
      name = "myproj"; # the container's name: unique on my host, at most 11 characters
      user = "mgajewskik";
      project = "/home/mgajewskik/code/myproj";
      # Claude keeps a project's sessions under its path, with each character that is not a letter or digit as -
      claudeSessions = "/home/${user}/.claude/projects/${
        lib.stringAsChars (c: if builtins.match "[A-Za-z0-9]" c == null then "-" else c) (lib.removeSuffix "/" project)
      }";

      # host folders the container sees, at the same paths, so Claude sessions are shared with my host. The host
      # folder must exist, and not lie inside another rw mount, where the agent could swap it for a symlink. With
      # :idmap each uid inside writes as the same uid on my host: my uid 1000 owns my files, and root inside would
      # write as root.
      mounts = {
        ${project} = "rw";
        ${claudeSessions} = "rw";
        # "/home/${user}/notes" = "ro";
        # when this folder sits in the project: keep the agent from editing it while it runs (the one exception to
        # the rule above; the agent can still change it through .git, which my git checkout would apply)
        # "${project}/.agentbox" = "ro";
      };

      # lines for the container's conf; PRIVATE_USERS=pick makes root in the container an unprivileged uid on my
      # host, outside the mounts
      conf = "/etc/nixos-containers/${name}.conf";
      confLines = ''
        PRIVATE_USERS=pick
        EXTRA_NSPAWN_FLAGS="${
          lib.concatMapAttrsStringSep " " (
            path: mode: "--bind${lib.optionalString (mode == "ro") "-ro"}=${path}:${path}:idmap"
          ) mounts
        }"
      '';
      writeConf = "printf %s ${lib.escapeShellArg confLines} | sudo tee -a ${conf} >/dev/null";

      # Without PRIVATE_USERS the container would run with my host's uids, its root as my host's root. And nspawn
      # follows symlinks on the way to a mount point inside the container, where the agent owns its home: a symlink
      # it left would put an rw mount wherever it points, e.g. over files container root reads. So the container
      # starts only through here, never with nixos-container restart.
      start = ''
        if ! grep -qx PRIVATE_USERS=pick ${conf}; then
          echo "${conf} lacks PRIVATE_USERS=pick; run: nix run .#create, or .#mounts if it exists" >&2
          exit 1
        fi
        # nspawn refuses to start without it, and Claude only makes it on first use
        mkdir -p ${lib.escapeShellArg claudeSessions}
        for path in ${lib.escapeShellArgs (builtins.attrNames mounts)}; do
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
        sudo nixos-container start ${name}
      '';

      # nix builds the system as me; root gets the result
      system = self.nixosConfigurations.container.config.system.build.toplevel;
      inShell = "cd ${project} && if [ -e devenv.nix ]; then exec devenv shell; else exec bash -l; fi";

      commands = {
        create = ''
          sudo nixos-container create ${name} --system-path ${system}
          ${writeConf}
        '';
        inherit start;
        shell = "sudo machinectl shell ${user}@${name} /run/current-system/sw/bin/bash -lc ${lib.escapeShellArg inShell}";
        # the viewer needs a display, so over SSH it runs on the machine I sit at, through a tunnel to the container
        desktop = ''
          ip=$(nixos-container show-ip ${name})
          echo "From the machine I sit at: ssh -N -L 5901:$ip:5901 $(uname -n), then vncviewer localhost:5901"
          if [ -z "''${DISPLAY-}" ] && [ -z "''${WAYLAND_DISPLAY-}" ]; then
            exit 0
          fi
          exec ${pkgs.tigervnc}/bin/vncviewer "$ip:5901"
        '';
        # the two steps nixos-container update takes after building
        update = ''
          sudo nix-env -p /nix/var/nix/profiles/per-container/${name}/system --set ${system}
          sudo systemctl reload container@${name}
        '';
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
      apps.x86_64-linux = lib.mapAttrs (command: text: {
        type = "app";
        program = lib.getExe (pkgs.writeShellApplication {
          name = "${name}-${command}";
          inherit text;
        });
      }) (commands // { default = commands.shell; });

      nixosConfigurations.container = nixpkgs.lib.nixosSystem {
        modules = [
          (
            { pkgs, ... }:
            {
              boot.isNspawnContainer = true;
              nixpkgs.hostPlatform = "x86_64-linux";
              nixpkgs.config.allowUnfree = true; # claude-code
              system.stateVersion = "26.05";

              networking.hostName = name;
              networking.useDHCP = false;
              # my host's resolv.conf points at its own resolver, which the container cannot reach
              networking.useHostResolvConf = false;
              networking.nameservers = [ "9.9.9.9" ];
              networking.firewall.allowedTCPPorts = [ 5901 ];

              users.users.${user} = {
                isNormalUser = true;
                uid = 1000;
              };
              # nspawn creates the folders above a mount as root; Claude needs to write in these
              systemd.tmpfiles.rules = [
                "d /home/${user}/.claude 0700 ${user} users -"
                "d /home/${user}/.claude/projects 0700 ${user} users -"
              ];
              # Never give the agent root here: root in a NixOS container can write to my host as root, through the
              # files the container's start script copies, the Nix profile folders it mounts, and the mounts above.
              security.sudo.enable = false;

              nix.settings.experimental-features = [
                "nix-command"
                "flakes"
              ];
              fonts.enableDefaultPackages = true;
              environment.systemPackages = with pkgs; [
                git
                neovim
                claude-code
                devenv
                chromium
                agent-browser
              ];

              # a desktop for the agent's browser, without a password: my host's firewall table lets only my host in
              systemd.services.desktop = {
                wantedBy = [ "multi-user.target" ];
                serviceConfig.User = user;
                serviceConfig.ExecStart = "${pkgs.tigervnc}/bin/Xvnc :1 -geometry 1920x1080 -rfbport 5901 -SecurityTypes None -ac";
              };
              environment.variables = {
                DISPLAY = ":1";
                AGENT_BROWSER_HEADED = "true";
                AGENT_BROWSER_EXECUTABLE_PATH = lib.getExe pkgs.chromium;
                # in the project, so logins survive deleting the container; gitignore it
                AGENT_BROWSER_PROFILE = "${project}/.browser-profile";
              };
            }
          )
        ];
      };
    };
}
