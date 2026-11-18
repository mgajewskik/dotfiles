# The project's dependencies and services. Inside its agent container (.agentbox/flake.nix) every shell and herdr pane
# in the project is in this devenv shell; `devenv up` in one of them starts the services below. Their data lives in
# .devenv/state, in the project: it survives deleting the container.
# The agent can edit this file, devenv.local.nix and devenv.lock, so I don't run devenv on my host in this project.
{ pkgs, ... }:
{
  languages.python.enable = true;
  packages = [ pkgs.jq ];

  services.postgres = {
    enable = true;
    initialDatabases = [ { name = "app"; } ];
  };

  # reachable from my host at the container's IP, port 8080 (the container's firewall opens it)
  processes.app.exec = "python -m http.server 8080";
}
