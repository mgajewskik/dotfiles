# agentbox guide: a devcontainer-like workspace on NixOS, without the devcontainer

One project, two files, and a NixOS container that feels like my devcontainers: I run one command, land in a zsh
with my tools and dotfiles, the project's devenv shell around me, and an agent that cannot touch the rest of my
machine. It replaces crib, podman, container images and mise on NixOS hosts.

The example lives in [`agentbox-devenv/`](agentbox-devenv/). **Status:** the first live run on x1 on 2026-11-18 passed
for create and start, the conf lines, dotfiles via chezmoi, the env file, the devenv shell via the zshrc hook, postgres
and the app, file ownership through idmap, and network isolation (the internet works; my host and the LAN time out).
The zsh-by-default entry, herdr as a user service, dropping `devenv up` at boot, the desktop window manager and
resize, the container without setuid programs and the per-container caps came after that run and are not yet tested
live; see [Before trusting it](#before-trusting-it).

- [ELI5](#eli5)
- [ELI12](#eli12)
- [What I get, compared with a devcontainer](#what-i-get-compared-with-a-devcontainer)
- [Set up the host, once](#set-up-the-host-once)
- [Set up a project](#set-up-a-project)
- [A day with it](#a-day-with-it)
- [Recipes](#recipes)
- [How it works](#how-it-works)
- [What survives](#what-survives)
- [Security: what the agent can and cannot do](#security-what-the-agent-can-and-cannot-do)
- [Compared with mise and my devcontainers](#compared-with-mise-and-my-devcontainers)
- [The smaller variant: agentbox-simple](#the-smaller-variant-agentbox-simple)
- [Before trusting it](#before-trusting-it)
- [Undo](#undo)

## ELI5

My computer is a big house. When an AI helper works in it, it can open every drawer: my keys, my letters, my other
projects. So I build it a playroom inside the house. The playroom has its own door, its own toys (my tools), and a
window onto just one table (the project). The helper can play there all day; it cannot walk into the rest of the house,
and it cannot open the front door to the neighbours (my home network). It can still go outside to the internet,
because it needs that to work.

The playroom is described on one sheet of paper (`flake.nix`). If I lose the playroom, I build the same one again
from the sheet. The project on the table stays, because the table belongs to the house, not to the playroom.

## ELI12

A **container** is a second, smaller Linux system that runs on the same kernel as my laptop but sees only what it is
given: its own processes, its own users, its own network card, its own files. Here the container runs **NixOS**, and
**systemd-nspawn** (driven by NixOS's `nixos-container`) starts it. That is the same idea as a devcontainer, minus
three things:

- **No image.** A devcontainer starts from a downloaded image (Debian, or the 3 GB devenv image) and installs things
  on top. This container's whole system is a Nix build, kept in my laptop's `/nix/store`, so it is built once and
  every container on the laptop shares it.
- **No mise.** My tools come from my tools flake (`.devcontainer/tools` in my dotfiles), which Nix builds once.
  The project's own tools and services come from its `devenv.nix`, as in any devenv project.
- **No crib or podman.** Two small Nix files declare everything, and `nix run` turns their commands into scripts.

Three files and one host module do all the work:

```text
myproj/
  devenv.nix            what the project needs: languages, packages, services (postgres), processes (the app)
  devenv.yaml           which nixpkgs devenv uses
  .agentbox/flake.nix   the container: its NixOS system, what it mounts, which env vars it gets, and its commands

my dotfiles: nixos/hosts/x1/agentbox.nix
                        lets my laptop run containers: NAT to the internet, and a firewall that keeps containers
                        away from my laptop and my home network
```

When I type `nix run path:.agentbox`, Nix reads `.agentbox/flake.nix`, builds a small shell script from it, and runs
that script as me. The script writes the env vars I chose to a file, then asks the container's systemd for a login
(`machinectl shell`, no ssh needed), which runs `agentbox-enter` inside. On the first entry that script clones my
dotfiles with chezmoi; every time, it opens a zsh in the project, or herdr with `#herdr`. herdr's server already runs
inside as a service of my user, so when I detach, the agents keep working.

The agent runs as my user (uid 1000) inside the container, without sudo. It sees the project folder (mounted from my
laptop), its Claude sessions, the Nix store, and the internet. It does not see my home folder, my ssh keys, my other
projects, my laptop's services, or anything on my home network.

## What I get, compared with a devcontainer

| In my devcontainers (crib)                                    | In agentbox                                                                                                    |
| ------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| `devcontainer.json`                                           | `.agentbox/flake.nix`                                                                                          |
| image (`base:debian`, 972 MB, or the devenv image, 3.12 GB)   | none: the system is built from my laptop's Nix store                                                           |
| `crib up` / `crib shell`                                      | `nix run path:.agentbox#start` / `nix run path:.agentbox`                                                      |
| mise, inside each container                                   | my tools flake, in the container's system, shared with my laptop's store                                       |
| dotfiles through crib's `setup.sh`                            | `chezmoi init --apply` on the first entry                                                                      |
| herdr on my laptop, the container as an ssh machine           | herdr inside, its server a service; `nix run path:.agentbox#herdr` attaches                                    |
| `mounts`                                                      | `mounts` in the flake                                                                                          |
| `containerEnv`, `GITHUB_TOKEN` forwarded by crib              | `env` in the flake: host variables I name, passed on each entry                                                |
| SSH agent, forwarded by default                               | not passed                                                                                                     |
| `postCreateCommand` with apt                                  | NixOS options in the flake                                                                                     |
| project tools from mise or apt                                | the project's `devenv.nix`, its services started with `devenv up`                                              |
| desktop-lite, Chrome for Testing, noVNC                       | Xvnc and nixpkgs Chromium, viewed with `nix run path:.agentbox#desktop`; clipboard shared                      |
| passwordless sudo                                             | no sudo (see [why](#no-sudo))                                                                                  |
| open network, home network included                           | the internet only                                                                                              |

## Set up the host, once

1. **Rebuild x1 with `nixos/hosts/x1/agentbox.nix`**, which `configuration.nix` imports. It turns on containers,
   NAT for `ve-*` interfaces, the firewall tables for containers and download builds, memory, CPU and process caps for
   each container, and the devenv binary cache:

   ```sh
   sudo nixos-rebuild switch --flake ~/.local/share/chezmoi/nixos#x1
   ```

2. **Push my dotfiles.** The container clones them from GitHub (the `devenv` branch for now), and it needs the
   `.chezmoi.toml.tmpl` that recognises an nspawn container (`/run/systemd/container`). Without it, chezmoi inside
   thinks it is on a laptop and runs the mise bootstrap. The tools flake comes from the same branch.

## Set up a project

1. Copy the example into the project, for instance `~/code/myproj`:

   ```sh
   cp -r ~/.local/share/chezmoi/.devcontainer/agentbox-devenv/{.agentbox,devenv.nix,devenv.yaml} ~/code/myproj/
   ```

   Add `.devenv*`, `devenv.local.*` and `.browser-profile` to the project's `.gitignore`.

2. Edit the top of `.agentbox/flake.nix`:

   ```nix
   name = "myproj";                         # unique on the laptop, at most 11 characters
   user = "mgajewskik";
   project = "/home/mgajewskik/code/myproj";  # the folder holding devenv.nix and .agentbox
   ```

3. Edit `devenv.nix` for the project's own needs. The example has python, jq, postgres with an `app` database, and a
   web server on port 8080.

4. Create and start the container. The first `create` builds the container's system, so it takes a while:

   ```sh
   cd ~/code/myproj
   nix run path:.agentbox#create
   nix run path:.agentbox#start
   ```

   `path:` makes Nix copy only `.agentbox/` to the store, not the whole repository. The first run writes
   `.agentbox/flake.lock`, which pins nixpkgs and my tools; commit it with the project.

## A day with it

```sh
cd ~/code/myproj
nix run path:.agentbox#start      # after a reboot; the container does not start on its own
nix run path:.agentbox            # zsh in the project
nix run path:.agentbox#herdr      # herdr in the project
```

Whichever I run first prints chezmoi's output while it clones and applies my dotfiles, trusts the project for devenv
(`devenv allow`), and reloads herdr's config. Then the zsh or herdr opens. Every zsh, in herdr or not, has my config,
and in the project my zshrc's devenv hook puts it inside the devenv shell on the first prompt, so `python`, `jq` and
`psql -d app` just work. The services (postgres, the app on 8080) do not run yet: I run `devenv up` in a shell or in a
dedicated herdr pane. I start Claude or pi in a pane, log in once (the login stays in the container's home), and give
it work.

When I detach from herdr, the agents keep running. `nix run path:.agentbox#herdr` again attaches to the same session.

To watch the agent's browser:

```sh
nix run path:.agentbox#desktop    # TigerVNC on the container's display; copy and paste work both ways
```

It always prints the SSH tunnel line for when I sit at another machine, and starts the viewer only when my session has
a display; see the SSH recipe under [Recipes](#recipes).

While `devenv up` runs, the app from `devenv.nix` is reachable from my laptop at the container's address:

```sh
curl "http://$(nixos-container show-ip myproj):8080"
```

All commands, run from the project folder:

| Command                            | What it does                                                                                     |
| ---------------------------------- | ------------------------------------------------------------------------------------------------ |
| `nix run path:.agentbox#create`    | build the system and create the container                                                        |
| `nix run path:.agentbox#start`     | check the guards, start it; herdr's server starts with it                                        |
| `nix run path:.agentbox`           | pass my env vars, open a zsh in the project; dotfiles on the first entry                         |
| `nix run path:.agentbox#herdr`     | the same, but attach herdr in the project                                                        |
| `nix run path:.agentbox#desktop`   | view the desktop where the agent's browser runs, or print the SSH tunnel to it                   |
| `nix run path:.agentbox#update`    | after editing the system part: switch the running container to the new build                     |
| `nix run path:.agentbox#mounts`    | after editing `mounts`, or when `create` stopped halfway: rewrite them, restart                  |
| `nix run path:.agentbox#stop`      | stop it                                                                                          |
| `nix run path:.agentbox#destroy`   | delete it; its home (dotfiles, Claude login) goes, the project stays                             |

I don't run devenv on my laptop in the project: the agent can edit `devenv.nix`, `devenv.local.nix` and
`devenv.lock`, and devenv on my laptop evaluates them as me.

## Recipes

**Give the agent a read-only GitHub token.** In `.agentbox/flake.nix`, name the variable inside and the host
variable it comes from, then enter again:

```nix
env = {
  GITHUB_TOKEN = "GITHUB_READONLY";
};
```

Each `nix run path:.agentbox` writes my shell's current values to `~/.local/state/agentbox/myproj.env` (mode 600),
which the container sees read-only at `/etc/agentbox.env`. Every new zsh inside reads it, so a herdr pane opened after
the entry gets the new value; an already running pane keeps the old one. The values never go into the Nix store or a
command line. The agent can read every one of them, so I pass only what I would hand it.

**Skip Claude's login.** `claude setup-token` on my laptop gives a long-lived token:

```nix
env = {
  CLAUDE_CODE_OAUTH_TOKEN = "CLAUDE_CODE_OAUTH_TOKEN";
};
```

**Share a host folder or file.** Add it to `mounts` at the same path, then `nix run path:.agentbox#mounts`, which
restarts the container:

```nix
mounts = {
  ${project} = "rw";
  ${claudeSessions} = "rw";
  "/home/${user}/notes" = "ro";
  "/home/${user}/.config/gh" = "ro";   # gh's login: a credential the agent then holds
};
```

The host path must exist and must not lie inside another rw mount. nspawn creates the folders above a mount point as
root, so a mount under my home needs its parent folders in `systemd.tmpfiles.rules`, as `~/.claude` and `~/.config`
already are.

**Add a system package or service.** Anything NixOS offers goes in `nixosConfigurations.container`, then
`nix run path:.agentbox#update` switches the running container to it. A project-only tool belongs in `devenv.nix`
instead, which needs no update: the next pane picks it up.

```nix
environment.systemPackages = [
  myTools
  # ... the rest of the existing list
  pkgs.ffmpeg
];
```

**Open another port to my laptop.** Add a process to `devenv.nix`, then the port to
`networking.firewall.allowedTCPPorts` and run `update`.

**Keep the agent from editing the container while it works.** Uncomment the read-only mount of `.agentbox`, then
`mounts`.

**Change its memory or CPU cap.** x1's `agentbox.nix` gives every container 12G of memory, 6 CPUs and 4096
processes; edit `systemd.services."container@".serviceConfig` there and rebuild. For one container only:
`sudo systemctl set-property container@myproj MemoryMax=8G` on my laptop.

**View the desktop and the app over SSH.** When I reach x1 over SSH from another machine (the one I sit at, which this
recipe calls the client), the viewer has no display to open on, so `nix run path:.agentbox#desktop` only prints the
tunnel line. On the client, I run the tunnel and the viewer; `RemoteResize` makes the container's screen follow the
viewer window's size, and its window manager keeps the agent's browser filling it:

```sh
ssh -N -L 5901:<container ip>:5901 <host name>
vncviewer -RemoteResize=1 localhost:5901
```

The app on 8080 works the same way, once `devenv up` runs:

```sh
ssh -N -L 8080:<container ip>:8080 <host name>
```

Then I open http://localhost:8080 on the client. The tunnel's traffic comes from x1 itself, so the firewall table
allows it, and the forwarded port listens only on the client's localhost. `<container ip>` is what
`nixos-container show-ip myproj` prints on x1, and `desktop` prints the line with the ip and x1's name filled in.

**Pick up changes to my tools or dotfiles.** For the tools: push my dotfiles, then `nix flake update tools` in
`.agentbox/`, then `nix run path:.agentbox#update`. herdr's server keeps running the old version, so its agents
survive the update; the new one takes over at the next `stop` and `start`. For the dotfiles: `chezmoi update` in a
pane.

**A second project.** Copy the files again and pick a different `name`. Every container shares the store, so the
second one costs almost no disk.

## How it works

```text
nix run path:.agentbox#start
  on my laptop, as me     check the conf has PRIVATE_USERS=pick, no mount point is a symlink, the env file exists
  sudo                    nixos-container start myproj -> container@myproj.service -> systemd-nspawn
  inside, at boot         NixOS starts: herdr server (my user's service), Xvnc on :1 and its window manager, firewall
                          allowing 5901 and 8080

nix run path:.agentbox            (#herdr is the same, with herdr as the program)
  on my laptop, as me     write env vars to ~/.local/state/agentbox/myproj.env
  sudo                    machinectl shell mgajewskik@myproj ... agentbox-enter zsh -l
  inside, as mgajewskik   first time: chezmoi init --apply, devenv allow, herdr server reload-config
                          every time: exec zsh -l (or herdr)
```

- **The system** is `nixosConfigurations.container`. Nix builds it as me, and `create` or `update` points the
  container's profile at the build. Root on my laptop never evaluates the flake; it only gets the finished result.
- **The mounts and env file** go into `/etc/nixos-containers/myproj.conf` as `EXTRA_NSPAWN_FLAGS`, with `:idmap`, so
  my uid 1000 inside reads and writes my files as my uid on the laptop. nspawn reads them only at start.
- **`PRIVATE_USERS=pick`** gives the container its own range of host uids: root inside is an unused uid on my laptop.
- **The network** is a veth pair: my laptop at 10.233.x.1, the container at 10.233.x.2, NAT to the internet. The
  host firewall drops everything from the container to my laptop and to private ranges (`10/8`, `172.16/12`,
  `192.168/16`, `100.64/10`, `169.254/16`), and drops new connections into it from anywhere but my laptop.
- **devenv inside** runs from the project folder. My zshrc's devenv hook enters the devenv shell in any shell or herdr
  pane in the project (it fires on the first prompt, so a shell that starts there is already inside). Nothing runs
  `devenv up` at boot: the services (postgres, the app on 8080) run only after I run it in a shell or pane.
- **herdr's server** is a systemd user service of my user (`systemd.user.services.herdr`), started at boot because
  `linger = true` runs my user's systemd from boot. Its panes get the same `XDG_RUNTIME_DIR` as my logins, so
  `devenv up` in a pane and `psql` in a login find the same sockets. `update` does not restart user services, so a
  tools change does not kill running agents; the new herdr takes over at the next `stop` and `start`. Its logs are
  `journalctl --user -u herdr`, inside. herdr keeps its socket in `~/.config/herdr`, so the client from
  `nix run path:.agentbox#herdr` finds the server the service started.

## What survives

| Data                                                                                    | Restart, host reboot | `destroy`                            |
| --------------------------------------------------------------------------------------- | -------------------- | ------------------------------------ |
| the container's home: applied dotfiles, Claude login, shell history, caches             | kept                 | gone; the next entry redoes dotfiles |
| the container's `/var`                                                                  | kept                 | gone                                 |
| the project, its `.devenv` (services' data), `.browser-profile`, Claude sessions        | kept                 | kept                                 |
| the system it runs                                                                      | kept                 | gone; rebuilt on `create`            |
| herdr's layout (`~/.config/herdr/session.json`, in the container's home)                | kept                 | gone                                 |
| `/tmp`, running processes, herdr's agents mid-task                                      | gone                 | gone                                 |

The container lives in `/var/lib/nixos-containers/myproj` and does not start with my laptop: after a host reboot, I run
`start`. herdr saves its layout continuously to `~/.config/herdr/session.json` in the container's home, so the layout
survives a stop and start and a host reboot, and is lost on `destroy`. Running processes, agents in panes included, are
lost on every stop.

## Security: what the agent can and cannot do

| The agent can                                                    | The agent cannot                                                                    |
| ---------------------------------------------------------------- | ----------------------------------------------------------------------------------- |
| read and write the project and its Claude sessions, as my uid    | read my home, `~/.ssh`, `~/.claude`, other projects, beyond what I mount            |
| read the env vars and mounts I pass in                           | use my SSH agent or any credential I did not pass                                   |
| reach the internet                                               | reach my laptop, other containers, or my home network                               |
| read the whole Nix store, and build through my laptop's daemon   | change the store, or become root: there is no sudo                                  |
| read my clipboard and set what I paste, while the viewer is open | see my laptop's processes or other containers'                                      |
| edit `.agentbox/flake.nix`                                       | apply that edit: only my next `nix run` does, as me                                 |

### Ways out

These are the paths from the container back to my laptop, roughly from most to least likely:

- **What I run on my laptop from the project.** `.git` hooks and config (git runs them), scripts, `devenv.nix` (any
  devenv command evaluates it), `.agentbox/flake.nix` (every `nix run` evaluates it and runs its scripts with my
  sudo), Claude sessions I resume. A look before running only holds while the files cannot change underneath: the
  container stopped, or the read-only mount on.
- **Builds.** They run through my laptop's Nix daemon, so a fixed-output build (a download) runs on my laptop's
  network. x1's `agentbox.nix` blocks build users from my laptop's addresses, the containers and private ranges; my
  laptop's abstract unix sockets and LAN devices with global IPv6 addresses stay reachable.
- **Bugs** in the kernel, systemd-nspawn or the Nix daemon, which all run as root on my laptop. A VM avoids those.
- **The VNC viewer**, which runs as me and talks to a server the agent can replace.
- **Resources:** x1's `agentbox.nix` caps memory, CPU and processes; nothing caps disk.

### No sudo

Root in a NixOS container is not safe to hand out, even with `PRIVATE_USERS`: the container's start script writes into
its root folder as host root, the container's Nix profile folders are mounted into it, and an `idmap` mount lets
container root write the project as host root (a setuid binary there would run as host root on my laptop). So the
flake sets `security.sudo.enable = false` and turns off the other setuid programs (`su`, `passwd`, `mount` and the
like), so a bug in one of them is no way to root either. It keeps one, `unix_chkpwd`: `pam_unix` runs it to check my
account when my user's systemd starts, and without it `user@1000` fails ("cannot retrieve authentication info") and
takes herdr's service with it. It only checks the calling user's own password entry. The agent doesn't need
root: Nix and devenv install everything without it, and the system part changes through `update`, from my laptop.
When a task truly needs root, the answer is a microVM, not sudo here.

## Compared with mise and my devcontainers

|                     | mise on my laptop                    | crib + `default/` (mise inside)                 | crib + devenv image                       | agentbox                                                  |
| ------------------- | ------------------------------------ | ----------------------------------------------- | ----------------------------------------- | --------------------------------------------------------- |
| Isolation           | Claude's Bash sandbox only           | rootless podman                                 | rootless podman                           | nspawn with its own users and network, no sudo            |
| Runs on             | anything                             | any host with podman                            | any host with podman                      | NixOS hosts                                               |
| Start               | `cd`                                 | `crib up`, `crib shell`                         | `crib up`, `crib shell`                   | `nix run path:.agentbox#start`, `nix run path:.agentbox`  |
| My tools            | mise, from `config.toml`             | mise, downloaded per container                  | my tools flake, in a shared Nix volume    | my tools flake, from my laptop's store                    |
| Project tools       | mise or devenv                       | mise, apt                                       | devenv                                    | devenv, its services started with `devenv up`             |
| Dotfiles            | chezmoi                              | crib's dotfiles step                            | crib's dotfiles step                      | chezmoi on the first entry                                |
| herdr               | on my laptop                         | on my laptop, container over ssh                | on my laptop, container over ssh          | inside, server as a service                               |
| Image               | none                                 | `base:debian`, 972 MB                           | devenv image, 3.12 GB                     | none                                                      |
| Credentials inside  | all of mine                          | SSH agent, `GITHUB_TOKEN`, more by plugins      | the same                                  | only the env vars and mounts I name                       |
| Network             | mine                                 | open, home network included                     | open, home network included               | internet only                                             |
| sudo inside         | mine                                 | passwordless                                    | passwordless                              | none                                                      |
| A breakout lands as | -                                    | my host user (rootless podman maps root to me)  | my host user                              | an unused uid; root-run daemon and nspawn are the risk    |
| Definition          | `config.toml`, `mise.lock`           | `devcontainer.json`, `.cribrc`                  | `devcontainer.json`, generated            | `flake.nix`, `devenv.nix`                                 |

**Benefits**

- **Isolation that matches the threat.** The agent gets no credentials I didn't name, no sudo, and no home network.
  In a crib container it gets my SSH agent and an open network, and a breakout lands as my host user.
- **Nothing to download per container.** No image, no mise install, no apt: the first container builds the system and
  my tools once into my laptop's store, and a second container reuses almost everything it built.
- **One description, readable in one sitting.** `flake.nix` is the container, its mounts, env vars and commands;
  `devenv.nix` is the project. Every NixOS option and every devenv option works.
- **The project environment travels with the project.** `devenv.nix` and `devenv.lock` sit next to its code, so
  every container built from them gets the same tools.
- **herdr where the agents are.** Agents run in the container's herdr and survive detaching, without the ssh machine
  setup crib needs.

**Costs**

- **NixOS only, and x1 only for now.** crib stays the answer for other machines and for projects whose
  `devcontainer.json` other people use.
- **sudo on my laptop** for every lifecycle command (the scripts call it), and root-run code (nspawn, the Nix daemon)
  between the agent and my laptop, where rootless podman has none.
- **No sudo inside.** Something that insists on `apt install` or root needs a Nix package instead, or a microVM.
- **Two tool lists.** My laptop gets its tools from mise, the container from my tools flake on nixpkgs. Versions can
  differ (nixpkgs lags mise, e.g. node), and a tool added to one list has to be added to the other, as with my devenv
  devcontainer (see [devenv.md](devenv.md)).
- **Partly run.** One live run on x1 passed the core; the newest parts are not tested yet (see the status at the top).

## The smaller variant: agentbox-simple

[`agentbox-simple/flake.nix`](agentbox-simple/flake.nix) is the same container in one file without my tools,
dotfiles, herdr, env vars or devenv services: git, neovim, claude-code, devenv, chromium and agent-browser from
nixpkgs, and `nix run .` opens a shell (the project's devenv shell when it has a `devenv.nix`). It is meant to live
outside the project (`~/boxes/myproj/`), where the agent cannot edit it. It is the reference for the mechanism; the
devenv example is the one to use.

## Before trusting it

The checks, in order (the status at the top says which have passed on a live container):

1. `nix run path:.agentbox#create` and `#start` succeed, and `cat /etc/nixos-containers/myproj.conf` ends with the
   `PRIVATE_USERS` and `EXTRA_NSPAWN_FLAGS` lines.
2. The first `nix run path:.agentbox` applies the dotfiles (chezmoi sees `container = true`, `nixTools = true`), then
   a zsh opens with my config, already in the devenv shell. `nix run path:.agentbox#herdr` attaches herdr with my
   config. The env file mount works (`cat /etc/agentbox.env` inside, as a single-file `idmap` bind).
3. `devenv up` in a shell or a herdr pane starts postgres and the app; `echo $PGHOST`, `psql -d app` and
   `devenv processes list` work in another shell and in a login, which find the same sockets. The output of
   `journalctl --user -u herdr` inside is clean.
4. Detach from herdr, run `#herdr` again: the same session, agents still running. After `stop` and `start`, the layout
   is back (`~/.config/herdr/session.json`).
5. `nix run path:.agentbox#desktop`: on a machine with a display it opens the viewer, over plain SSH it prints the
   tunnel line, and the tunnel and `vncviewer -RemoteResize=1 localhost:5901` work. The screen follows the viewer
   window, and matchbox keeps every window filling it. Then `agent-browser open https://example.com` in a pane: the
   window shows on the desktop. If Chromium's sandbox refuses to start inside the user namespace, `--no-sandbox` is
   the fallback.
6. From inside: `curl https://example.com` works; `curl http://10.233.x.1` and anything on `192.168.0.0/16` time out.
7. nvim's first start: plugins, tree-sitter parsers (gcc), Mason binaries (nix-ld).
8. After a tools bump and `update`, `#herdr` attaches the new herdr client to the old server. If that fails, `stop`
   and `start`.
9. After a `stop` and `start` on the rebuilt host: `nix run path:.agentbox` still logs in, `ls /run/wrappers/bin`
   inside shows only `unix_chkpwd`, `systemctl status user@1000` is active, chromium still opens, and on my laptop
   `systemctl show container@myproj -p MemoryMax,TasksMax,CPUQuotaPerSecUSec` shows the caps.

## Undo

`nix run path:.agentbox#destroy` in each project, remove `./agentbox.nix` from the x1 imports, then
`sudo nixos-rebuild switch --flake ~/.local/share/chezmoi/nixos#x1`. Delete `~/.local/state/agentbox/`, which holds
the env files and may hold tokens. The project folders and their Claude sessions stay on my laptop.
