# Nix tools, devenv and agent containers on NixOS

Three pieces that let a NixOS host run without mise's global tools, and run a project's agents in a NixOS container
instead of a devcontainer:

- **Nix tools.** On NixOS, my global tools come from one Nix package built from nixos-unstable
  ([`../modules/tools.nix`](../modules/tools.nix)) instead of mise. x1 installs it system-wide; the containers below use
  the same build.
- **devenv on the host.** devenv itself (from the same package), its zsh hook, and a short prompt inside its shells.
- **The agent container ("box").** This folder is the example: a project's `devenv.nix` for its dependencies and
  services, and `.box/flake.nix` for a NixOS container that runs its agents, isolated from the rest of the
  machine. Its commands keep the secrets they pass in next to `.box/`: env values in `.box.env`, AWS credentials in
  `.aws/`. x1 runs these containers through [`../modules/agentbox.nix`](../modules/agentbox.nix).

mise and my devcontainers stay: on NixOS, mise only loses its global tools, and keeps working for projects' own
`mise.toml` and in devcontainers. devenv only activates in projects I `devenv allow`, and a box exists only in
projects I copy this folder into.

**Status:** carried over from the `devenv` branch, where a first live run on x1 on 2026-11-18 passed for create and
start, the conf lines, dotfiles via chezmoi, the env file, the devenv shell via the zshrc hook, postgres and the app,
file ownership through idmap, and network isolation. The zsh-by-default entry, herdr as a user service, the desktop
window manager and resize, the container without setuid programs, the per-container caps, `.box.env`, `#aws`, the
GitHub token and `.box/setup.sh` came after that run and were never tested live. Here the x1 system and the box's
system evaluate, but nothing has been built or run from `main` yet; see [Before trusting it](#before-trusting-it).

- [Nix tools](#nix-tools)
- [devenv on the host](#devenv-on-the-host)
- [The box: set up the host, once](#the-box-set-up-the-host-once)
- [Set up a project](#set-up-a-project)
- [A day with it](#a-day-with-it)
- [Recipes](#recipes)
- [How it works](#how-it-works)
- [What survives](#what-survives)
- [Security](#security)
- [Before trusting it](#before-trusting-it)
- [Undo](#undo)

## Nix tools

[`../flake.nix`](../flake.nix) has two nixpkgs inputs:

| Input              | Branch          | What uses it                                                                               |
| ------------------ | --------------- | ------------------------------------------------------------------------------------------ |
| `nixpkgs`          | nixos-26.05     | the whole x1 system: `pkgs` in every module under `../modules`, every `with pkgs; [ ... ]` entry |
| `nixpkgs-unstable` | nixos-unstable  | `pkgsUnstable` in `../modules/tools.nix`, so everything in the `tools` package                   |

So the file says where a package comes from:

- `git`, `pkgs.git` or a bare name in `environment.systemPackages = with pkgs; [ ... ]`: stable.
- Anything in the `tools` list in `modules/tools.nix`: unstable, because its `perSystem` builds the package from
  `pkgsUnstable`.
- To take one more package from unstable on x1 only, take it from the input in that feature's module:

  ```nix
  { inputs, ... }:
  {
    flake.modules.nixos.cli =
      { pkgs, ... }:
      let
        unstable = inputs.nixpkgs-unstable.legacyPackages.${pkgs.stdenv.hostPlatform.system};
      in
      {
        environment.systemPackages = [
          pkgs.git            # nixos-26.05
          unstable.opentofu   # nixos-unstable
        ];
      };
  }
  ```

  `legacyPackages` has no `allowUnfree`; an unfree package needs `import inputs.nixpkgs-unstable { ... }` as in
  `tools.nix`. A tool I want in the boxes too goes in the `tools` list instead.

Don't list one program from both branches: NixOS merges `systemPackages` with collisions ignored, so one copy wins
silently. That is why `neovim` left the stable list when `tools.nix` took it over.

To see what runs:

```sh
which -a claude                     # every claude on PATH, in order
readlink -f "$(command -v claude)"  # the store path, with its version
nix eval --json ~/.local/share/chezmoi/nixos#packages.x86_64-linux.tools \
  --apply 't: map (p: p.name) t.paths'   # every tool in the package, with its version
```

`tools.nix` mirrors the `[tools]` of `dot_config/mise/config.toml.tmpl`, plus mise itself and devenv, except jq,
which comes from the stable list (a box gets it from nixos-26.05 in its own flake). chezmoi and mise from Nix don't
update themselves (`chezmoi upgrade`, `mise self-update`): they move with the flake like every other tool. crib is
not in nixpkgs, so [`../modules/pkgs/crib.nix`](../modules/pkgs/crib.nix) installs its release binary on x1 only; containers skip
it, as the mise config does. When I add a tool to one list, I add it to the other. crib's version is pinned in `crib.nix`:
for a new release, change `version`, set `hash = "";`, rebuild, and copy the hash from the error.

**Updating.** `nix flake update nixpkgs-unstable --flake ~/.local/share/chezmoi/nixos` bumps only the unstable tools,
then `nh os switch` (or `sudo nixos-rebuild switch --flake ~/.local/share/chezmoi/nixos#x1`). nixos-unstable trails
upstream releases; for a release from this morning, a project's `mise.toml` still works.

### mise on NixOS

My dotfiles decide by host: where `nixos = true` (x1, and every box), they don't install global tools with mise.
There:

- `~/.config/mise/config.toml` keeps its `[settings]` (and on x1 the `aws-devcontainer` task, which containers never
  get), without `[tools]`, so mise still serves projects' own `mise.toml` and my devcontainers.
- mise itself comes from `tools.nix`, not from chezmoi's download to `~/.local/bin/mise`, and `mise bootstrap`
  doesn't run.
- chezmoi stops managing `~/.config/mise/mise.lock`; `mise lock -g` there would only write an empty lock.
- chezmoi's scripts (claude, herdr, nvim and yazi plugins) call the tools by name instead of through `mise exec`.

Elsewhere (other distros, macOS, non-NixOS containers) nothing changes: mise installs the global tools.

**Moving x1 over, once.** Rebuild first, so the nix tools exist when chezmoi's scripts run:

```sh
nh os switch
rm ~/.local/bin/mise ~/.local/bin/chezmoi ~/.config/mise/mise.lock
```

The old downloads in `~/.local/bin` come first on `PATH` and would shadow the nix copies; the lock is stale. Then, in
a new shell (the old one's mise hook still calls the deleted binary):

```sh
chezmoi apply           # rewrites the mise config without [tools]
mise prune --dry-run    # old global installs; mise prune removes them
which -a claude nvim mise chezmoi crib   # /run/current-system/sw/bin first
```

To go back to self-updating chezmoi and mise: drop them from `tools.nix`, make `.chezmoiexternals/mise.toml.tmpl`
download mise on NixOS again, and reinstall chezmoi with `sh -c "$(curl -fsLS get.chezmoi.io)" -- -b ~/.local/bin`.

## devenv on the host

devenv comes from `tools.nix`, so it is on x1 once the system is rebuilt. Two dotfile pieces wire it into zsh:

- `dot_zshrc` evaluates `devenv hook zsh` wherever devenv is installed. A `cd` into a project trusted with
  `devenv allow` enters its devenv shell on the next prompt, and a `cd` out leaves it. `devenv revoke` undoes the
  trust.
- devenv prefixes the prompt with `(devenv) `, and starship's `nix_shell` module would add
  `impure (devenv-shell-env)`. The zshrc strips the prefix, and `dot_config/starship.toml.tmpl` shows only the Nix
  logo for `nix_shell`, so the prompt says it once.

`agentbox.nix` also adds the `devenv.cachix.org` binary cache, so devenv's own builds download instead of compiling,
on x1 and in the boxes.

## The box: set up the host, once

1. **Rebuild x1.** `configuration.nix` imports `agentbox.nix`, which turns on containers, NAT for `ve-*`
   interfaces, the firewall tables for containers and download builds, memory, CPU and process caps for each
   container, and the devenv cache:

   ```sh
   nh os switch
   ```

2. **Push my dotfiles.** A box fetches two things from GitHub `main`: my tools (the `tools` output of `nixos/`) and
   my dotfiles, whose `.chezmoi.toml.tmpl` recognises an nspawn container (`/run/systemd/container`). Without that,
   chezmoi inside takes it for a desktop (`container = false`) and applies the desktop setup.

## Set up a project

1. Copy the example into the project, for instance `~/code/myproj`, and add its ignores:

   ```sh
   cp -r ~/.local/share/chezmoi/nixos/devenv/{.box,devenv.nix,devenv.yaml} ~/code/myproj/
   cat ~/.local/share/chezmoi/nixos/devenv/.gitignore >> ~/code/myproj/.gitignore
   ```

2. Edit the top of `.box/flake.nix`:

   ```nix
   name = "myproj";                           # unique on the host, at most 11 characters
   user = "mgajewskik";
   project = "/home/mgajewskik/code/myproj";  # the folder holding devenv.nix and .box
   ```

3. Edit `devenv.nix` for the project. The example has python, jq, postgres with an `app` database, and a web server
   on port 8080.

4. Create and start the container. The first `create` builds the container's system, so it takes a while:

   ```sh
   cd ~/code/myproj
   nix run path:.box#create
   nix run path:.box#start
   ```

   `path:` makes Nix copy only `.box/` to the store, not the whole repository. It copies every file in that folder,
   ignored or not, and the store is readable by every user and every box, so the commands write secrets beside it,
   never into it: `.box.env` and `.aws/`. The first run writes `.box/flake.lock`, which pins my tools and nixpkgs;
   commit it with the project. `.box.env` and `.aws/` stay out of git (the example's `.gitignore` and my global
   one). The box's nixpkgs follows the one in my NixOS flake, so the container shares x1's store paths.

## A day with it

```sh
cd ~/code/myproj
nix run path:.box#start      # after a reboot; the container does not start on its own
nix run path:.box            # zsh in the project
nix run path:.box#herdr      # herdr in the project
```

The first entry applies my dotfiles with chezmoi, trusts the project for devenv (`devenv allow`), and reloads herdr's
config. Every zsh inside, in herdr or not, is then in the project's devenv shell, so `python`, `jq` and `psql -d app`
just work. The services start when I run `devenv up` in a shell or a herdr pane. I start Claude or pi in a pane and
log in once; the login stays in the container's home. When I detach from herdr, the agents keep running.

| Command                     | What it does                                                                        |
| --------------------------- | ----------------------------------------------------------------------------------- |
| `nix run path:.box#create`  | build the system and create the container                                           |
| `nix run path:.box#start`   | check the guards, start it; herdr's server and `.box/setup.sh` run with it          |
| `nix run path:.box`         | pass my env vars, open a zsh in the project; dotfiles on the first entry            |
| `nix run path:.box#herdr`   | the same, but attach herdr in the project                                           |
| `nix run path:.box#aws`     | assume `awsRole` on the host; the container's AWS CLI and SDKs use it               |
| `nix run path:.box#desktop` | view the desktop where the agent's browser runs, or print the SSH tunnel to it      |
| `nix run path:.box#update`  | after editing the system part: switch the running container to the new build        |
| `nix run path:.box#mounts`  | after editing `mounts`, or when `create` stopped halfway: rewrite them, restart     |
| `nix run path:.box#stop`    | stop it                                                                             |
| `nix run path:.box#destroy` | delete it; its home goes (dotfiles, Claude login), the project and its secrets stay |

While `devenv up` runs, the app is reachable from the host at `http://$(nixos-container show-ip myproj):8080`.

I don't run devenv on the host in a boxed project: the agent can edit `devenv.nix`, `devenv.local.nix` and
`devenv.lock`, and devenv on the host evaluates them as me.

## Recipes

**Give the agent a GitHub token, or skip Claude's login.** Name the variable inside and the host variable
it comes from in `env`, then enter again:

```nix
env = {
  GITHUB_TOKEN = "GITHUB_READONLY";
  CLAUDE_CODE_OAUTH_TOKEN = "CLAUDE_CODE_OAUTH_TOKEN";  # from claude setup-token on the host
};
```

Each `nix run path:.box` (or `#herdr`) writes my shell's current values to `.box.env` (mode 600), which
every new zsh inside reads through the project mount. Host variables that aren't set are skipped. Panes already open
keep their old values; new ones get the new values. The values never enter the Nix store. The agent can read them
all, so I pass only what I would hand it.

gh inside uses `GITHUB_TOKEN`. git doesn't on its own: my gitconfig pushes to GitHub over SSH, and the box has no
keys. A `~/.gitconfig.local` inside, which the example `.box/setup.sh` writes, sends git over https with the token:

```ini
[url "https://github.com/"]
	insteadOf = git@github.com:
[credential "https://github.com"]
	helper = !gh auth git-credential
```

That covers remotes in the `git@github.com:` form. An `https://github.com/` remote still pushes over SSH, because my
gitconfig's `pushInsteadOf` wins, so the project's origin uses the `git@` form. A read-only token lets the agent clone
and read; for `git push` and `gh pr create` it needs a fine-grained token that may write to this repo.

**Give the agent AWS access through a role.** Set the role in `.box/flake.nix`:

```nix
awsRole = "arn:aws:iam::<account>:role/devcontainer";
awsProfile = "default";   # the host profile that assumes it
awsSeconds = 43200;       # at most the role's maximum session duration
```

Then, on the host, `nix run path:.box#aws` assumes the role and writes its temporary credentials to
`.aws/credentials` in the project (mode 600). Inside, `AWS_SHARED_CREDENTIALS_FILE` points the CLI and SDKs at that
file, so when they expire I run `#aws` again and the next `aws` command picks up the new ones; a long-running SDK
client keeps the old ones until it restarts. The region comes through `env` (`AWS_REGION = "AWS_REGION";`). Any
role my profile may assume works; the `devcontainer` role from
[`../../.devcontainer/devcontainer-role.cfn.yaml`](../../.devcontainer/devcontainer-role.cfn.yaml) keeps its
guardrails. The agent never sees my profile's own keys.

**Run my own setup on every start.** A bash script at `.box/setup.sh` (no executable bit needed) runs on every container
start, after a reboot or `stop` and `start` too, for setup the NixOS definition can't hold. It runs as my user in the
project, with the system's tools on `PATH`, never as root: the agent can edit it. The very first start runs it before
my dotfiles exist (the first entry applies them), and every start runs it again, so it has to be safe to rerun. Its
output: `journalctl --user -u setup` inside. No `update` needed after editing it. It doesn't see `.box.env` or the
system's environment variables (no `GITHUB_TOKEN`, no `DISPLAY`), and it has to exit. The example writes the
`~/.gitconfig.local` above; I delete or replace it when the project pushes from the host.

**Share a host folder or file.** Add it to `mounts`, then `nix run path:.box#mounts`, which restarts the
container. The host path must exist and must not lie inside another rw mount. A mount under my home needs its
parent folders in `systemd.tmpfiles.rules`, as `~/.claude` and `~/.config` already have.

**Add a system package or service.** Any NixOS option goes in `nixosConfigurations.container`, then
`nix run path:.box#update`. A project-only tool belongs in `devenv.nix`, which needs no update.

**Open another port to the host.** Add the process to `devenv.nix` and the port to
`networking.firewall.allowedTCPPorts`, then `update`.

**Keep the agent from editing the box while it works.** Uncomment the read-only mount of `.box`, then `mounts`. That
covers `.box/setup.sh` too. `.box.env` and `.aws/` stay writable, but only the box reads them. The agent can still
turn `.aws` into a symlink, e.g. to my `~/.aws`, and the next `#aws` then writes there.

**Change the memory or CPU cap.** `agentbox.nix` gives every container 12G, 6 CPUs and 4096 processes. For one
container: `sudo systemctl set-property container@myproj MemoryMax=8G`.

**View the desktop and the app over SSH.** From the machine I sit at:

```sh
ssh -N -L 5901:<container ip>:5901 -L 8080:<container ip>:8080 x1
vncviewer -RemoteResize=1 localhost:5901
```

`nix run path:.box#desktop` on x1 prints the line with the ip filled in.

**Pick up changes to my tools or dotfiles.** Tools: push, then `nix flake update tools` in `.box/`, then
`update`. herdr's server keeps the old version until the next `stop` and `start`, so running agents survive.
Dotfiles: `chezmoi update` inside.

**A second project.** Copy the files again with another `name`. Containers share the store, so it costs almost no
disk.

## How it works

```text
nix run path:.box#start
  on the host, as me      check the conf has PRIVATE_USERS=pick and no mount point is a symlink
  sudo                    nixos-container start myproj -> container@myproj.service -> systemd-nspawn
  inside, at boot         herdr server and .box/setup.sh (my user's services), Xvnc on :1 and its window manager,
                          firewall for 5901, 8080

nix run path:.box       (#herdr is the same, with herdr as the program)
  on the host, as me      write env vars to .box.env
  sudo                    machinectl shell mgajewskik@myproj ... agentbox-enter zsh -l
  inside, as mgajewskik   first time: chezmoi init --apply, devenv allow, herdr server reload-config
                          every time: exec zsh -l (or herdr)
```

- **The system** is `nixosConfigurations.container`, built by Nix as me; root only gets the finished result.
- **Mounts** go into `/etc/nixos-containers/myproj.conf` as `EXTRA_NSPAWN_FLAGS` with `:idmap`, so my uid inside
  writes as my uid on the host. nspawn reads them only at start.
- **Secrets** live in `.box.env` and `.aws/` in the project on the host, and the container reads them through the
  project mount: the env file in every new zsh, the AWS credentials through `AWS_SHARED_CREDENTIALS_FILE`. The host
  writes each file under a new name and renames it over the old one with `mv -T`, so a symlink the agent leaves at
  that name is replaced, not followed. Anything that copies the project tree without git's filter (tar, rsync, a
  docker build context, a `path:` flake of the project root) carries them along.
- **`PRIVATE_USERS=pick`** gives the container its own uid range: root inside is an unused uid on the host.
- **The network** is a veth pair (host 10.233.x.1, container 10.233.x.2) with NAT. The host drops everything from
  the container to itself and to private ranges, and new connections into it from anywhere but the host.
- **Tools** are the `tools` package from `nixos/modules/tools.nix`, the same store path x1 installs, in the container's system.

## What survives

| Data                                                                                            | Restart, host reboot | `destroy`                            |
| ----------------------------------------------------------------------------------------------- | -------------------- | ------------------------------------ |
| the container's home: dotfiles, Claude login, shell history, herdr layout                       | kept                 | gone; the next entry redoes dotfiles |
| the project, `.devenv` (services' data), `.browser-profile`, `.box.env`, `.aws`, Claude sessions | kept                 | kept                                 |
| the system it runs                                                                              | kept                 | gone; rebuilt on `create`            |
| `/tmp`, running processes, agents mid-task                                                      | gone                 | gone                                 |

## Security

| The agent can                                                    | The agent cannot                                                         |
| ---------------------------------------------------------------- | ------------------------------------------------------------------------ |
| read and write the project and its Claude sessions, as my uid    | read my home, `~/.ssh`, other projects, beyond what I mount              |
| read the env vars, AWS role credentials and mounts I pass in     | use any credential I did not pass, or my AWS profile's own keys          |
| reach the internet                                               | reach the host, other containers, or my home network                     |
| read the whole Nix store, and build through the host's daemon    | change the store, or become root: no sudo, setuid programs turned off    |
| read my clipboard and set what I paste, while the viewer is open | see the host's processes                                                 |
| edit `.box/flake.nix` and `.box/setup.sh`                        | apply that edit: only my next `nix run` or `start` does                  |

Ways out, most likely first:

- **What I run on the host from the project:** `.git` hooks and config, scripts, `devenv.nix` (any devenv command),
  `.box/flake.nix` (every `nix run` evaluates it and runs its scripts with my sudo), Claude sessions I resume.
- **The GitHub token** in `env`: the agent can do whatever it allows, from inside or after copying it out.
- **Builds** run through the host's Nix daemon. `agentbox.nix` keeps download builds off the host's addresses, the
  containers and private ranges, but not off abstract unix sockets or LAN devices' global IPv6 addresses.
- **Bugs** in the kernel, systemd-nspawn or the Nix daemon, which run as root. A VM avoids those.
- **The VNC viewer**, which runs as me against a server the agent can replace.
- **Disk:** nothing caps it.

No sudo inside on purpose: root in a NixOS container can write to the host as root through the files its start
script copies, the Nix profile folders it mounts, and the idmapped mounts. A task that needs root needs a microVM.
The header of [`.box/flake.nix`](.box/flake.nix) has the full reasoning.

## Before trusting it

On a box created from `main`, in order:

1. `create` and `start` succeed; `/etc/nixos-containers/myproj.conf` ends with the `PRIVATE_USERS` and
   `EXTRA_NSPAWN_FLAGS` lines.
2. The first `nix run path:.box` applies the dotfiles (`chezmoi data` inside shows `container` and `nixos`
   true, no `~/.local/bin/mise` appears, and `~/.config/mise/config.toml` has no `[tools]`), then opens a zsh in the
   devenv shell.
3. `devenv up` starts postgres and the app; `psql -d app` works in another pane.
4. Detach and re-attach herdr: same session, agents running. After `stop` and `start` the layout is back.
5. `#desktop` opens the viewer; `agent-browser open https://example.com` shows on it.
6. Inside: `curl https://example.com` works; `curl http://10.233.x.1` and anything on `192.168.0.0/16` time out.
7. nvim's first start installs plugins and tree-sitter parsers.
8. On x1: `ls /run/wrappers/bin` inside shows only `unix_chkpwd`, and
   `systemctl show container@myproj -p MemoryMax,TasksMax,CPUQuotaPerSecUSec` shows the caps.
9. With a token in `env`: `echo ${GITHUB_TOKEN:+set}` in a new pane says `set`; `ls -l .box.env` on the host shows
   `-rw-------`; `gh auth status` inside shows the token; with the `~/.gitconfig.local` above and a token that may
   write, `git push` works.
10. With `awsRole` set: `#aws` on the host, then `aws sts get-caller-identity` inside shows the role's assumed-role
    ARN.
11. With a `.box/setup.sh`: after `stop` and `start`, `journalctl --user -u setup` inside shows its run.

## Undo

- **A box:** `nix run path:.box#destroy` in the project, then delete `.box/`, `.box.env` and `.aws/`; the last two
  may hold tokens and AWS credentials.
- **Containers on x1:** remove `agentbox` from the feature list in `modules/hosts/x1/configuration.nix`, then
  `nh os switch`.
- **Nix tools on x1:** the dotfiles no longer install global tools with mise on NixOS, so removing `tools` from the
  feature list in `modules/hosts/x1/configuration.nix` leaves x1 without them, and without crib, which the same
  module installs. Going back to mise means
  dropping the `.nixos` checks in `dot_config/mise/config.toml.tmpl`, `.chezmoiignore`,
  `.chezmoiexternals/mise.toml.tmpl`, `.chezmoitemplates/tool-exec` and the install-packages and claude-plugins
  scripts, then `chezmoi apply`, and putting `neovim` back on the stable list.
