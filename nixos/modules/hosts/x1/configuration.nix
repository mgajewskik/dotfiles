{ inputs, self, ... }:
{
  flake.nixosConfigurations.x1 = inputs.nixpkgs.lib.nixosSystem {
    modules = [ self.modules.nixos.x1 ];
  };

  flake.modules.nixos.x1 = {
    imports = [
      inputs.disko.nixosModules.disko
      inputs.nixos-hardware.nixosModules.lenovo-thinkpad-x1-extreme
    ]
    ++ (with self.modules.nixos; [
      nix
      boot
      networking
      openssh
      locale
      user
      laptop
      audio
      printing
      keys
      podman
      agentbox
      syncthing
      cli
      desktop
      apps
      tools
    ]);

    networking.hostName = "x1";

    boot.resumeDevice = "/dev/mapper/root";
    boot.kernelParams = [ "resume_offset=533760" ];

    hardware.intelgpu.computeRuntime = "legacy";

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

    # fileSystems."/mnt/backups" = {
    #   device = "192.168.1.123:/mnt/ssd/backups";
    #   fsType = "nfs";
    #   options = [
    #     "soft"
    #     "nofail"
    #     "x-systemd.automount"
    #   ];
    # };

    system.stateVersion = "26.05";
  };
}
