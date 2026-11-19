pkgs:
let
  # nixpkgs' claude-code wrapper puts its alsa-lib on LD_LIBRARY_PATH, and every command Claude runs inherits it.
  # agent-browser then starts a Chrome linked against an older glibc than that alsa-lib wants, and Chrome exits at once
  # with "GLIBC_x.yy not found". agent-browser itself needs no LD_LIBRARY_PATH, so its wrapper drops it.
  agent-browser = pkgs.symlinkJoin {
    name = "agent-browser";
    paths = [ pkgs.agent-browser ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = "wrapProgram $out/bin/agent-browser --unset LD_LIBRARY_PATH";
  };
in
pkgs.buildEnv {
  name = "dotfiles-tools";
  paths = with pkgs; [
    mise
    chezmoi
    tmux
    usage
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
    agent-browser
    rtk
    devenv
  ];
}
