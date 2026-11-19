{
  flake.modules.nixos.printing =
    { pkgs, ... }:
    {
      services.printing = {
        enable = true;
        drivers = [ pkgs.cups-brother-dcpt720dw ];
      };
      hardware.printers = {
        ensurePrinters = [
          {
            name = "brother";
            deviceUri = "dnssd://Brother%20DCP-T720DW._ipp._tcp.local/?uuid=e3248000-80ce-11db-8000-c8a3e8b6459e";
            model = "brother_dcpt720dw_printer_en.ppd";
          }
        ];
        ensureDefaultPrinter = "brother";
      };
      services.avahi = {
        enable = true;
        nssmdns4 = true;
        openFirewall = true;
      };
    };
}
