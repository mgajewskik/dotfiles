{
  flake.modules.nixos.syncthing =
    { pkgs, ... }:
    {
      systemd.packages = [ pkgs.syncthing ];
      systemd.user.services.syncthing.wantedBy = [ "default.target" ];
    };
}
