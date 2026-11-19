{
  flake.modules.nixos.locale =
    { pkgs, ... }:
    {
      time.timeZone = "Europe/Warsaw";
      i18n.defaultLocale = "en_US.UTF-8";
      i18n.extraLocales = [ "pl_PL.UTF-8/UTF-8" ];
      console = {
        keyMap = "pl";
        font = "ter-v24b";
        packages = [ pkgs.terminus_font ];
        earlySetup = true;
      };
    };
}
