{
  flake.modules.nixos.networking = {
    networking.useNetworkd = true;
    networking.useDHCP = false;
    networking.wireless.iwd.enable = true;
    networking.nftables.enable = true;
    networking.firewall.extraInputRules = "ip saddr 192.168.0.0/16 accept";
    # Wired and wifi can both be up on the same LAN subnet. With the kernel defaults
    # (arp_ignore=0, arp_announce=0) each NIC answers ARP for the other NIC's address, so the
    # router maps x1's addresses to the wrong MAC and connections stall, time out, or get reset.
    # arp_ignore=1 answers only for addresses on the receiving NIC; arp_announce=2 sends ARP
    # requests with the sending NIC's own address. Drop these only if the two NICs can never
    # share a subnet.
    boot.kernel.sysctl = {
      "net.ipv4.conf.all.arp_ignore" = 1;
      "net.ipv4.conf.all.arp_announce" = 2;
    };
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
  };
}
