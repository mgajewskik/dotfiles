# This project's agentbox container: the NixOS system it runs and the host folders it mounts, like a
# devcontainer.json. ../devenv.nix holds the commands that build and run it, and ../../../agentbox.md explains the setup.
#
# The agent can edit this file, since it is in the project, and the system it describes runs as root in the container.
# So nothing here takes effect until I review the change with box-approve: every build uses my approved copy, in
# ~/.local/state/agentbox/<name>/.
#
# After changing it: nix flake lock (once, and after my dotfiles' base changes: nix flake update agentbox), then
# box-approve and box-update from the approved copy.
{
  description = "agentbox container for this project";

  inputs = {
    # the base every agentbox container shares: my user, my tools, the desktop and browser, sshd, herdr
    # (.devcontainer/tools in my dotfiles); a path input is pinned in flake.lock by its content
    agentbox.url = "path:/home/mgajewskik/.local/share/chezmoi/.devcontainer/tools";
    nixpkgs.follows = "agentbox/nixpkgs";
  };

  outputs =
    { agentbox, nixpkgs, ... }:
    {
      # nixos-container builds nixosConfigurations.container unless told otherwise
      nixosConfigurations.container = nixpkgs.lib.nixosSystem {
        modules = [
          agentbox.nixosModules.agentbox
          (
            { pkgs, ... }:
            {
              # tools this project's container needs beyond the base, for every shell in it; tools for the
              # project's code belong in its devenv.nix, which works on my host too
              environment.systemPackages = with pkgs; [
                sqlite
                httpie
              ];

              # the project's app, reachable from my host at the container's IP (box-desktop prints it)
              networking.firewall.allowedTCPPorts = [ 8080 ];

              # a service that should run whenever the container does; its data lives in the container's /var/lib:
              # services.postgresql = {
              #   enable = true;
              #   ensureDatabases = [ "mgajewskik" ];
              #   ensureUsers = [ { name = "mgajewskik"; ensureDBOwnership = true; } ];
              # };

              # every other NixOS option works here too; the agent never gets root to change the system itself
            }
          )
        ];
      };

      # host folders mounted into the container besides the project, which is always mounted at its own path:
      #   mode    rw or ro
      #   host    a path on my host; ~ is my home, {key} is this project's folder name in ~/.claude/projects
      #   inside  where it appears in the container; defaults to the same path
      # Paths hold only letters, digits and ._/~{}+@=,-. A host path cannot be inside the project or inside another
      # rw host path here, since the agent could swap those for a symlink. Never mount ~/.ssh, ~/.aws, ~/.config/gh,
      # all of ~/.claude, /run/user/<uid> or my whole home: each hands the agent a credential or control of my host.
      agentbox.mounts = [
        # this project's Claude sessions and memory, shared with my host's Claude: same key inside and outside
        {
          mode = "rw";
          host = "~/.claude/projects/{key}";
        }
        # a folder the agent may read
        {
          mode = "ro";
          host = "~/notes";
        }
      ];
    };
}
