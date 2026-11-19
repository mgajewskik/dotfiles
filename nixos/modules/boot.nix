{
  flake.modules.nixos.boot = {
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

    hardware.enableRedistributableFirmware = true;
  };
}
