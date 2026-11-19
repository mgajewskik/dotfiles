{
  flake.modules.nixos.user =
    { pkgs, ... }:
    {
      users.users.mgajewskik = {
        isNormalUser = true;
        extraGroups = [ "wheel" ];
        shell = pkgs.zsh;
        linger = true;
      };
      programs.zsh.enable = true;
    };
}
