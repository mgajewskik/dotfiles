{
  flake.modules.nixos.audio = {
    security.rtkit.enable = true;
    services.pipewire = {
      enable = true;
      alsa.enable = true;
      pulse.enable = true;
      jack.enable = true;
      # pipewire 1.6.6 segfaults in its x11-bell module whenever Xwayland exits, taking easyeffects down with it.
      # Drop this once a pipewire release survives Xwayland exiting. Disabling the module only loses the X11 bell sound.
      extraConfig.pipewire."99-disable-x11-bell"."context.properties"."module.x11.bell" = false;
    };
  };
}
