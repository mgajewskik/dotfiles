# The NixOS system inside every agentbox container (see ../agentbox.md).
#
# flake.nix next to this file builds it as nixosConfigurations.agentbox, on the nixpkgs pinned in flake.lock, and
# passes my tools package in as `tools`. `agentbox up` creates a container from it on the first run, and
# `agentbox update` rebuilds a container after this file, the tools list or flake.lock change: a running container
# switches in place, like nixos-rebuild switch: services whose definition changed restart, the rest keeps running.
# herdr-server runs from the tools package, so a change to the tools restarts it and the herdr panes in it.
# Every container shares this file; a project's own tools come from its devenv.nix instead.
#
# This file cannot add mounts: nixos-container takes them from /etc/nixos-containers/<name>.conf, which the agentbox
# launcher writes from the project's agentbox.mounts, once I approve it (see ../agentbox.md).
#
# Changes I might make here, each followed by `agentbox update` in the projects that should get it:
#   - a tool for every container: add it to environment.systemPackages below, or to the tools list in flake.nix
#   - a service for one project, such as postgres: services in that project's devenv.nix, not here
#   - a service for every container: its NixOS options, e.g. services.postgresql.enable = true; its data lives in
#     the container's /var/lib and survives restarts
#   - a port my host should reach: add it to networking.firewall.allowedTCPPorts; my host reaches the container's IP
#     (agentbox desktop prints it), other machines cannot
#   - no desktop: delete the agentbox-vnc, agentbox-desktop and agentbox-novnc services, tigervnc and the fonts
#   - sudo for the agent: possible (security.sudo.enable, extraGroups = [ "wheel" ]), but it makes the agent root
#     here, and container root can reach my host, see the comment at security.sudo below
#   - memory or CPU limits: not here; on my host,
#     sudo systemctl set-property container@<name> MemoryMax=8G CPUQuota=400%

{
  lib,
  pkgs,
  tools,
  ...
}:

let
  # the agent's account; matches my host user, so paths like ~/.claude/projects/<key> are the same on both sides
  user = "mgajewskik";
  home = "/home/${user}";
  display = ":1";
  vncPort = 5901;
  noVncPort = 6080;
  vncPasswordFile = "/run/agentbox/vncpasswd";
in
{
  # nixos-container refuses systems without it on 25.11 and newer
  boot.isNspawnContainer = true;
  nixpkgs.hostPlatform = "x86_64-linux";
  system.stateVersion = "26.05";

  # empty: keeps the machine name nixos-container gives the container (its agentbox name)
  networking.hostName = "";
  # nixos-container gives the container a fixed address on its own veth link; there is no DHCP server
  networking.useDHCP = false;
  # the host resolves through systemd-resolved on 127.0.0.53, which the container's own network cannot reach
  networking.useHostResolvConf = false;
  networking.nameservers = [
    "9.9.9.9"
    "1.1.1.1"
  ];
  # what my host may reach inside; my host's firewall already keeps the container away from my host, other
  # containers and private networks (nixos/hosts/x1/agentbox.nix)
  networking.firewall.allowedTCPPorts = [
    vncPort
    noVncPort
  ];

  # how agentbox shell and herdr get in: the launcher puts ~/.ssh/agentbox_ed25519.pub into authorized_keys
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  users.users.${user} = {
    isNormalUser = true;
    uid = 1000;
    shell = pkgs.zsh;
  };
  # nspawn creates the home folder as root on first boot, as the parent of agentbox's project mount
  systemd.tmpfiles.rules = [ "d ${home} 0700 ${user} users -" ];
  # The agent must never be root here. The NixOS manual (containers chapter) warns that container root can affect the
  # host: on every start my host's container script works as root on paths inside this container's root, where a
  # symlink root planted would redirect it, and the per-container profile and gcroots folders under /nix/var/nix are
  # mounted read-write as host root. Tools come from nix, so nothing needs sudo.
  security.sudo.enable = false;

  programs.zsh.enable = true;
  # Mason's language servers and other prebuilt Linux binaries expect /lib64/ld-linux-x86-64.so.2
  programs.nix-ld.enable = true;
  # nix inside talks to my host's nix daemon (NIX_REMOTE=daemon, set by nixos-container) as an untrusted user:
  # builds and downloads land in my host's store, with my host's substituters
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];
  # nix-shell -p and <nixpkgs> resolve to the nixpkgs this system was built from
  nix.nixPath = [ "nixpkgs=${pkgs.path}" ];

  # the container's global tools, linked into /run/current-system/sw/bin; part of this system, so my host's garbage
  # collection keeps them for as long as the container exists
  environment.systemPackages = with pkgs; [
    tools
    devenv
    chromium
    git
    curl
    wget
    unzip
    gnutar
    gzip
    gcc
    gnumake
    file
    gnupg
    dnsutils
    iputils
    netcat-openbsd
    traceroute
    tcpdump
    mtr
    nmap
    iperf3
    whois
    tigervnc
  ];

  fonts.packages = with pkgs; [
    dejavu_fonts
    noto-fonts
    noto-fonts-color-emoji
  ];

  # agent-browser drives this Chromium as a window on the desktop below
  environment.variables = {
    DISPLAY = display;
    COLORTERM = "truecolor";
    AGENT_BROWSER_HEADED = "true";
    AGENT_BROWSER_EXECUTABLE_PATH = lib.getExe pkgs.chromium;
  };
  # the browser profile lives in the project's root, as in my dev containers, so logins survive agentbox destroy; every
  # container shares this file, so the project path comes from the file agentbox up writes
  environment.extraInit = ''
    if [ -r /var/lib/agentbox/project ]; then
      export AGENT_BROWSER_PROFILE="$(cat /var/lib/agentbox/project)/.browser-profile"
    fi
  '';

  # the desktop, as in the dev containers' desktop-lite: an X server I watch over VNC (password vscode)
  systemd.services.agentbox-vnc = {
    description = "TigerVNC desktop on ${display}";
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      User = user;
      RuntimeDirectory = "agentbox";
      ExecStartPre = pkgs.writeShellScript "agentbox-vnc-password" ''
        umask 077
        echo vscode | ${pkgs.tigervnc}/bin/vncpasswd -f > ${vncPasswordFile}
      '';
      ExecStart = "${pkgs.tigervnc}/bin/Xvnc ${display} -geometry 1920x1080 -depth 24 -rfbport ${toString vncPort} -SecurityTypes VncAuth -PasswordFile ${vncPasswordFile} -ac";
      Restart = "on-failure";
    };
  };

  # a window manager, so browser windows can be moved and resized
  systemd.services.agentbox-desktop = {
    description = "Fluxbox on ${display}";
    wantedBy = [ "multi-user.target" ];
    after = [ "agentbox-vnc.service" ];
    requires = [ "agentbox-vnc.service" ];
    environment.DISPLAY = display;
    serviceConfig = {
      User = user;
      ExecStart = lib.getExe' pkgs.fluxbox "fluxbox";
      Restart = "always";
      RestartSec = 1;
    };
  };

  # the same desktop in a web browser: http://<container ip>:6080/vnc.html
  systemd.services.agentbox-novnc = {
    description = "noVNC for the ${display} desktop";
    wantedBy = [ "multi-user.target" ];
    after = [ "agentbox-vnc.service" ];
    serviceConfig = {
      User = user;
      ExecStart = "${lib.getExe pkgs.novnc} --listen ${toString noVncPort} --vnc localhost:${toString vncPort}";
      Restart = "on-failure";
    };
  };

  # lets my host's herdr use the container as a machine over ssh
  systemd.services.herdr-server = {
    description = "herdr server for my host's herdr";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    path = [ "/run/current-system/sw" ];
    environment.DISPLAY = display;
    serviceConfig = {
      User = user;
      WorkingDirectory = home;
      ExecStart = "${tools}/bin/herdr server";
      Restart = "on-failure";
    };
  };
}
