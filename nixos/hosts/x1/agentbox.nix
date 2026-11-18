{
  boot.enableContainers = true;

  networking.nat = {
    enable = true;
    # nftables matches interface wildcards with *; the + in the NixOS manual is iptables syntax
    internalInterfaces = [ "ve-*" ];
  };

  # nixos-container addresses each container's veth itself; networkd's built-in 80-container-ve.network would
  # also claim it (DHCP server, link-local addresses, its own route handling)
  systemd.network.networks."05-agentbox-veth" = {
    matchConfig.Name = "ve-*";
    linkConfig.Unmanaged = true;
  };

  # agentbox containers reach the internet only: not this host, not each other, not my LAN
  networking.nftables.tables.agentbox = {
    family = "inet";
    content = ''
      chain input {
        type filter hook input priority filter - 1; policy accept;
        iifname "ve-*" ct state established,related accept
        iifname "ve-*" drop
      }

      chain forward {
        type filter hook forward priority filter - 1; policy accept;
        iifname "ve-*" ip daddr { 10.0.0.0/8, 100.64.0.0/10, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16 } drop
        # NAT turns on forwarding, so a LAN peer routing 10.233.0.0/16 through this host could open the desktops
        oifname "ve-*" ct state established,related accept
        oifname "ve-*" drop
      }
    '';
  };

  # containers are untrusted users of this host's nix daemon, so only caches configured here apply to them
  nix.settings = {
    extra-substituters = [ "https://devenv.cachix.org" ];
    extra-trusted-public-keys = [ "devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw=" ];
  };
}
