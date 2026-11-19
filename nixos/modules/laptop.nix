{
  flake.modules.nixos.laptop = {
    hardware.bluetooth.enable = true;
    services.blueman.enable = true;

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

    services.fwupd.enable = true;
  };
}
