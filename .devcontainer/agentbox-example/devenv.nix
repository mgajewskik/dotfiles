# This project's development tools. My zshrc's devenv hook activates them in every shell in the project, inside its
# agentbox container (box-up runs devenv allow there) and on my host alike. The container itself is in .agentbox/.
{ pkgs, ... }:
{
  languages.go.enable = true;

  packages = with pkgs; [
    just
  ];
}
