{
  flake.modules.nixos.agentbox =
    { config, ... }:
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

      # A download build (fixed-output derivation) runs in this host's network namespace as a nixbld build user, and a
      # container can start one through the daemon socket, so the table above never sees it. Builds keep the internet
      # and DNS; they lose this host's addresses, the containers and my LAN. This host's own builds lose them too; the
      # daemon's binary-cache downloads run as root and are unaffected. Not covered: abstract unix sockets, and LAN
      # devices with global IPv6 addresses.
      networking.nftables.tables.nixbld = {
        family = "inet";
        content = ''
          chain output {
            type filter hook output priority filter; policy accept;
            # only a positive match jumps: packets without an owning socket (resets, ICMP errors, TIME_WAIT replies) never
            # match. With auto-allocate-uids on, builds run under another gid range and this stops matching.
            meta skgid ${toString config.ids.gids.nixbld} jump build
          }

          chain build {
            # systemd-resolved's stub, which /etc/resolv.conf names and download builds get a copy of
            ip daddr 127.0.0.53 meta l4proto { tcp, udp } th dport 53 accept
            # every address of this host (loopback, veths, LAN and global IPv6), plus broadcast and multicast
            fib daddr type { local, broadcast, multicast } reject
            ip daddr { 10.0.0.0/8, 100.64.0.0/10, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16 } reject
            ip6 daddr { fc00::/7, fe80::/10 } reject
          }
        '';
      };

      # caps for each agentbox container (the template unit nixos-container starts them with), so a runaway agent can't
      # freeze this host; builds run in the daemon and don't count
      systemd.services."container@".serviceConfig = {
        MemoryMax = "12G";
        TasksMax = 4096;
        CPUQuota = "600%";
      };

      # containers are untrusted users of this host's nix daemon, so only caches configured here apply to them
      nix.settings = {
        extra-substituters = [ "https://devenv.cachix.org" ];
        extra-trusted-public-keys = [ "devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw=" ];
      };
    };
}
