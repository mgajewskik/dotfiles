let
  btrfsOptions = [
    "compress=zstd:1"
    "noatime"
  ];
in
{
  flake.modules.nixos.x1 = {
    disko.devices.disk.main = {
      type = "disk";
      device = "/dev/nvme0n1";
      content = {
        type = "gpt";
        partitions = {
          ESP = {
            size = "1G";
            type = "EF00";
            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = "/boot";
              mountOptions = [ "umask=0077" ];
            };
          };
          root = {
            size = "100%";
            content = {
              type = "luks";
              name = "root";
              settings.allowDiscards = true;
              content = {
                type = "btrfs";
                extraArgs = [ "-f" ];
                subvolumes = {
                  "@" = {
                    mountpoint = "/";
                    mountOptions = btrfsOptions;
                  };
                  "@home" = {
                    mountpoint = "/home";
                    mountOptions = btrfsOptions;
                  };
                  "@nix" = {
                    mountpoint = "/nix";
                    mountOptions = btrfsOptions;
                  };
                  "@home_snapshots" = {
                    mountpoint = "/home/.snapshots";
                    mountOptions = btrfsOptions;
                  };
                  "@swap" = {
                    mountpoint = "/swap";
                    swap.swapfile.size = "35G";
                  };
                };
              };
            };
          };
        };
      };
    };

    services.snapper.configs.home = {
      SUBVOLUME = "/home";
      TIMELINE_CREATE = false;
      NUMBER_CLEANUP = true;
      NUMBER_LIMIT = 10;
      NUMBER_LIMIT_IMPORTANT = 10;
    };
  };
}
