{
  description = "My tools for dev containers with nix; setup.sh installs them into the user profile";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { nixpkgs, ... }:
    let
      forEachSystem = nixpkgs.lib.genAttrs [
        "x86_64-linux"
        "aarch64-linux"
      ];
    in
    {
      packages = forEachSystem (
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
            config.allowUnfreePredicate = pkg: nixpkgs.lib.getName pkg == "claude-code";
          };
          # nixpkgs' claude-code wrapper puts its alsa-lib on LD_LIBRARY_PATH, and every command Claude runs inherits it.
          # agent-browser starts Chrome for Testing, an FHS binary linked against the image's glibc: that alsa-lib wants
          # nix's newer glibc, so Chrome exits at once with "GLIBC_2.38 not found". agent-browser itself is a nix binary
          # and needs no LD_LIBRARY_PATH, so its wrapper drops it, which fixes Chrome for any caller and leaves claude's alone.
          agent-browser = pkgs.symlinkJoin {
            name = "agent-browser";
            paths = [ pkgs.agent-browser ];
            nativeBuildInputs = [ pkgs.makeWrapper ];
            postBuild = "wrapProgram $out/bin/agent-browser --unset LD_LIBRARY_PATH";
          };
        in
        {
          default = pkgs.buildEnv {
            name = "dotfiles-tools";
            paths = with pkgs; [
              chezmoi
              tmux
              starship
              fzf
              zoxide
              eza
              bat
              bat-extras.batman
              bat-extras.batdiff
              bat-extras.batgrep
              bat-extras.batpipe
              bat-extras.batwatch
              ripgrep
              fd
              dust
              yazi-unwrapped
              jq
              difftastic
              neovim
              tree-sitter
              k9s
              kubectl
              awscli2
              uv
              ty
              procs
              gh
              go
              python3
              nodejs
              lazyssh
              lazygit
              lazyjournal
              herdr
              claude-code
              pi-coding-agent
              agent-browser # the wrapped one from the let above, not pkgs.agent-browser
              rtk
            ];
          };
        }
      );
    };
}
