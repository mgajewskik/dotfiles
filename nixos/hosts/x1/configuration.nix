{ inputs, lib, pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ./disko.nix
  ];

  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    auto-optimise-store = true;
  };
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };
  nixpkgs.config.allowUnfree = true;

  boot.loader.limine = {
    enable = true;
    maxGenerations = 10;
  };
  boot.loader.efi.canTouchEfiVariables = true;
  boot.initrd.systemd.enable = true;
  boot.blacklistedKernelModules = [
    "pcspkr"
    "snd_pcsp"
  ];
  boot.resumeDevice = "/dev/mapper/root";
  boot.kernelParams = [ "resume_offset=533760" ];

  hardware.enableRedistributableFirmware = true;
  hardware.intelgpu.computeRuntime = "legacy";
  hardware.bluetooth.enable = true;

  # Proprietary NVIDIA driver, off: the GTX 1050 Ti runs on nouveau.
  # services.xserver.videoDrivers = [ "nvidia" ];
  # hardware.nvidia = {
  #   branch = "legacy_580";
  #   open = false;
  #   modesetting.enable = true;
  #   prime = {
  #     offload.enable = true;
  #     offload.enableOffloadCmd = true;
  #     intelBusId = "PCI:0:2:0";
  #     nvidiaBusId = "PCI:1:0:0";
  #   };
  # };
  # programs.sway.extraOptions = [ "--unsupported-gpu" ];

  networking.hostName = "x1";
  networking.useNetworkd = true;
  networking.useDHCP = false;
  networking.wireless.iwd.enable = true;
  networking.nftables.enable = true;
  networking.firewall.extraInputRules = "ip saddr 192.168.0.0/16 accept";
  systemd.network.wait-online.anyInterface = true;
  systemd.network.networks = {
    "20-wired" = {
      matchConfig = {
        Type = "ether";
        Kind = "!*";
      };
      linkConfig.RequiredForOnline = "routable";
      networkConfig.DHCP = "yes";
      dhcpV4Config.RouteMetric = 100;
      ipv6AcceptRAConfig.RouteMetric = 100;
    };
    "25-wireless" = {
      matchConfig.Type = "wlan";
      linkConfig.RequiredForOnline = "routable";
      networkConfig = {
        DHCP = "yes";
        IgnoreCarrierLoss = "3s";
      };
      dhcpV4Config.RouteMetric = 600;
      ipv6AcceptRAConfig.RouteMetric = 600;
    };
  };
  services.resolved = {
    enable = true;
    settings.Resolve.MulticastDNS = "no";
  };

  time.timeZone = "Europe/Warsaw";
  i18n.defaultLocale = "en_US.UTF-8";
  i18n.extraLocales = [ "pl_PL.UTF-8/UTF-8" ];
  console = {
    keyMap = "pl";
    font = "ter-v24b";
    packages = [ pkgs.terminus_font ];
    earlySetup = true;
  };

  users.users.mgajewskik = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    shell = pkgs.zsh;
  };
  programs.zsh.enable = true;

  services.logind.settings.Login = {
    HandlePowerKey = "ignore";
    HandlePowerKeyLongPress = "poweroff";
    HandleLidSwitch = "suspend";
    HandleLidSwitchExternalPower = "ignore";
    HandleLidSwitchDocked = "ignore";
  };

  services.tlp = {
    enable = true;
    settings = {
      START_CHARGE_THRESH_BAT0 = 55;
      STOP_CHARGE_THRESH_BAT0 = 60;
      USB_EXCLUDE_BTUSB = 1;
    };
  };

  services.snapper.configs.home = {
    SUBVOLUME = "/home";
    TIMELINE_CREATE = false;
    NUMBER_CLEANUP = true;
    NUMBER_LIMIT = 10;
    NUMBER_LIMIT_IMPORTANT = 10;
  };

  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "no";
      PasswordAuthentication = false;
    };
  };

  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    pulse.enable = true;
    jack.enable = true;
  };
  services.blueman.enable = true;
  services.printing = {
    enable = true;
    drivers = [ pkgs.cups-brother-dcpt720dw ];
  };
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    openFirewall = true;
  };
  services.fwupd.enable = true;
  services.udisks2.enable = true;
  services.gvfs.enable = true;
  services.pcscd.enable = true;
  # pcscd is built with polkit here, and polkit only grants card access inside a login session. scdaemon runs under
  # gpg-agent in the systemd user manager, outside any session, so gpg --card-status is refused without this rule.
  security.polkit.extraConfig = ''
    polkit.addRule(function (action, subject) {
      if ((action.id == "org.debian.pcsc-lite.access_pcsc" || action.id == "org.debian.pcsc-lite.access_card")
          && subject.user == "mgajewskik") {
        return polkit.Result.YES;
      }
    });
  '';
  services.gnome.gnome-keyring.enable = true;
  services.gnome.gcr-ssh-agent.enable = false;
  services.envfs.enable = true;
  programs.nix-ld.enable = true;
  programs.ssh.startAgent = true;
  programs.gnupg.agent = {
    enable = true;
    pinentryPackage = pkgs.pinentry-gnome3;
  };

  virtualisation.podman = {
    enable = true;
    dockerCompat = true;
  };

  # fileSystems."/mnt/backups" = {
  #   device = "192.168.1.123:/mnt/ssd/backups";
  #   fsType = "nfs";
  #   options = [
  #     "soft"
  #     "nofail"
  #     "x-systemd.automount"
  #   ];
  # };

  programs.sway = {
    enable = true;
    wrapperFeatures.gtk = true;
    extraPackages = with pkgs; [
      swaybg
      swayidle
      swaylock
      grim
      slurp
      satty
      wl-clipboard
      brightnessctl
      playerctl
      libnotify
    ];
  };
  programs.uwsm.enable = true;
  security.soteria.enable = true;
  # soteria needs XDG_SESSION_ID, which uwsm deliberately keeps out of the systemd user environment. Take the session
  # logind elected as the user's display instead.
  systemd.user.services.polkit-soteria.serviceConfig.ExecStart = lib.mkForce (
    pkgs.writeShellScript "soteria-in-display-session" ''
      XDG_SESSION_ID=$(loginctl show-user "$UID" --property=Display --value) exec ${lib.getExe pkgs.soteria}
    ''
  );
  programs.gpu-screen-recorder.enable = true;
  xdg.portal.wlr.settings.screencast = {
    chooser_type = "simple";
    chooser_cmd = "${pkgs.slurp}/bin/slurp -f 'Monitor: %o' -or";
  };

  programs.dconf.profiles.user.databases = [
    {
      settings."org/gnome/desktop/interface" = {
        color-scheme = "prefer-dark";
        gtk-theme = "Arc-Dark";
        icon-theme = "Papirus-Dark";
        cursor-theme = "phinger-cursors-light";
        cursor-size = lib.gvariant.mkInt32 24;
        font-name = "JetBrainsMono Nerd Font 10";
        monospace-font-name = "JetBrainsMono Nerd Font 10";
      };
    }
  ];

  systemd.packages = [
    pkgs.syncthing
    pkgs.mako
  ];
  systemd.user.services.syncthing.wantedBy = [ "default.target" ];
  systemd.user.services.mako.wantedBy = [ "graphical-session.target" ];
  # vicinae installs its unit in share/systemd/user, which systemd.packages does not read (nixos/lib/systemd-lib.nix).
  # Switch to systemd.packages once the vicinae package installs it under lib/systemd/user.
  systemd.user.services.vicinae = {
    description = "Vicinae Launcher Daemon";
    requires = [ "dbus.socket" ];
    after = [ "graphical-session.target" ];
    partOf = [ "graphical-session.target" ];
    wantedBy = [ "graphical-session.target" ];
    # NixOS pins every generated unit's PATH to coreutils and friends. vicinae starts apps by the bare names in their
    # desktop entries (firefox, bitwarden, claude-desktop), so it needs the session PATH from environment.d instead.
    environment.PATH = lib.mkForce null;
    serviceConfig = {
      ExecStart = "${pkgs.vicinae}/bin/vicinae server --replace";
      ExecReload = "${pkgs.coreutils}/bin/kill -HUP $MAINPID";
      Restart = "always";
      RestartSec = 60;
      KillMode = "process";
    };
  };

  fonts.packages = with pkgs; [
    noto-fonts
    noto-fonts-cjk-sans
    noto-fonts-color-emoji
    jetbrains-mono
    nerd-fonts.jetbrains-mono
    nerd-fonts.symbols-only
  ];
  fonts.fontconfig.defaultFonts.monospace = [ "JetBrainsMono Nerd Font" ];

  environment.systemPackages = with pkgs; [
    gcc
    git
    vim
    wget
    curl
    file
    htop
    btop
    lsof
    strace
    tcpdump
    traceroute
    nmap
    dnsutils
    inetutils
    ethtool
    iotop
    sysstat
    lshw
    pciutils
    usbutils
    smartmontools
    powertop
    acpi
    zip
    unzip
    _7zz
    rsync
    restic
    rclone
    wireguard-tools
    trash-cli
    tree
    impala
    efibootmgr
    man-pages
    yubikey-manager
    jq
    syncthing

    waybar
    mako
    vicinae
    wl-clip-persist
    wlsunset
    wlr-randr
    wtype
    wev
    wlogout
    hypridle
    nwg-displays
    nwg-look
    papirus-icon-theme
    phinger-cursors
    arc-theme
    xdg-utils

    ghostty
    kitty
    alacritty
    firefox
    brave
    google-chrome
    (callPackage ../../pkgs/helium.nix { })
    (callPackage ../../pkgs/claude-desktop.nix { })
    (callPackage ../../pkgs/grok-bot.nix { })
    nemo-with-extensions
    evince
    ristretto
    vlc
    pavucontrol
    easyeffects
    udiskie
    inputs.voxtype.packages.${pkgs.stdenv.hostPlatform.system}.onnx
    insync
    obsidian
    bitwarden-desktop
  ];

  system.stateVersion = "26.05";
}
