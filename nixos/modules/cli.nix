{ inputs, ... }:
{
  flake.modules.nixos.cli =
    { pkgs, ... }:
    {
      services.envfs.enable = true;
      programs.nix-ld.enable = true;

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
        inputs.vortix.packages.${pkgs.stdenv.hostPlatform.system}.vortix
        trash-cli
        tree
        impala
        efibootmgr
        man-pages
        yubikey-manager
        jq
        bubblewrap
        socat
        syncthing
      ];
    };
}
