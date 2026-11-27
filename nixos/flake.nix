{
  description = "NixOS machines";

  outputs =
    { self, ... }:
    let
      pins = import ./.tack;
      # flake-parts builds inputs' and the default perSystem pkgs from self.inputs, which nix fills from flake.lock;
      # under tack that lock is empty, so self.inputs must be the pins too.
      inputs = pins // {
        self = self // {
          inputs = pins;
        };
      };
    in
    inputs.flake-parts.lib.mkFlake { inherit inputs; } (inputs.import-tree ./modules);
}
