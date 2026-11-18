# agentbox example project

A project with its own agentbox container, defined next to its code the way a `devcontainer.json` would be. Copy
`.agentbox/` and `devenv.nix` into a project to give it one. [`../agentbox.md`](../agentbox.md) explains the setup.

```text
devenv.nix, devenv.yaml        the project's dev tools, used inside the container (and on my host)
.agentbox/
  container/flake.nix          the container: my base module plus this project's packages, services, ports, mounts
  devenv.nix, devenv.yaml      the commands that build and run it: box-approve, box-up, box-shell, ...
```

The agent can edit everything in the project, `.agentbox/` included, and the container's system runs as root. So the
commands only ever run from my approved copy of `.agentbox/`, in `~/.local/state/agentbox/<name>/`, which only
`box-approve` writes after showing me the diff.

## First time

1. Lock the container's inputs: `cd .agentbox/container && nix flake lock`.
2. Read `.agentbox/` (this is the one time I run it from the project), then approve it:
   `cd .agentbox && devenv shell box-approve`.
3. From the approved copy, start the container: `cd ~/.local/state/agentbox/<name> && devenv shell box-up`.

`<name>` is the project folder's name, lowercased, at most 11 characters: `agentbox-ex` for this one.

## Day to day

All from `~/.local/state/agentbox/<name>`, as `devenv shell <command>`, or `devenv shell` once and then the commands:

| I want to                                        | I run          |
| ------------------------------------------------ | -------------- |
| start the container, or apply changed mounts     | `box-up`       |
| get a shell in the project                       | `box-shell`    |
| see its desktop and the agent's browser          | `box-desktop`  |
| review a change to `.agentbox/`                  | `box-approve`  |
| switch the container to the approved definition  | `box-update`   |
| re-apply my dotfiles                             | `box-apply`    |
| stop it                                          | `box-stop`     |
| delete it and its home                           | `box-destroy`  |

After changing `.agentbox/container/flake.nix`: `box-approve`, then `box-update`. After changing my dotfiles' base
module (`.devcontainer/tools`): `nix flake update agentbox` in `.agentbox/container`, then the same.
