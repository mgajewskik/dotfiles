{ inputs, ... }:
{
  imports = [ inputs.flake-parts.flakeModules.modules ];

  systems = [ "x86_64-linux" ];

  flake.nixpkgs = inputs.nixpkgs;
}
