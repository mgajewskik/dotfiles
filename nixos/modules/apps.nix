{ inputs, self, ... }:
{
  flake.modules.nixos.apps =
    { pkgs, ... }:
    let
      packages = self.packages.${pkgs.stdenv.hostPlatform.system};
    in
    {
      environment.systemPackages = with pkgs; [
        ghostty
        kitty
        alacritty
        firefox
        brave
        google-chrome
        packages.helium
        packages.claude-desktop
        packages.grok-bot
        nemo-with-extensions
        evince
        ristretto
        vlc
        pavucontrol
        easyeffects
        udiskie
        inputs.voxtype.packages.${pkgs.stdenv.hostPlatform.system}.onnx
        insync
        obsidian
        bitwarden-desktop
      ];
    };
}
