# agentbox: isolated agent workspaces on NixOS

> **Start with [agentbox-guide.md](agentbox-guide.md)**: the setup I use, a project's `devenv.nix` plus
> `.agentbox/flake.nix`, explained from ELI5 up and compared with mise and my devcontainers. This file records the
> proof of concept that led there, including the generic launcher and its design notes.

A proof of concept: one NixOS container per project, for running Claude Code, pi and other agents on a NixOS host
without crib, podman, images or mise. It runs on the x1 only, and nothing below has run on it yet: the files evaluate
and the launcher's logic is tested, but the first `agentbox up` is the real test.

| From the default dev container   | In agentbox                                                                   |
| -------------------------------- | ----------------------------------------------------------------------------- |
| crib                             | `agentbox`, a script around `nixos-container` (systemd-nspawn)                |
| image (Debian or devenv)         | none: the container's NixOS system comes from the host's Nix store            |
| mise                             | my tools flake in the container's system; project tools from `devenv.nix`     |
| apt in `postCreateCommand`       | the container's NixOS config                                                  |
| `mounts` in `devcontainer.json`  | `agentbox.mounts` in the project, used once I approve it                      |
| dotfiles through `setup.sh`      | `chezmoi init --apply` inside, on the first `agentbox up`                     |
| desktop-lite, Chrome for Testing | TigerVNC, Fluxbox and noVNC as services; Chromium from nixpkgs                |

## How it fits together

```text
agentbox up, in the project
  |
  |-- first time only: sudo nixos-container create, from .devcontainer/tools#agentbox
  |-- agentbox.mounts changed: show the mounts, ask me to approve them
  |
  v
container conf: own user namespace, the project, my dotfiles and the approved mounts
  |
  v
sudo nixos-container start
  |
  v
NixOS boots: sshd, desktop, noVNC, herdr server
  |
  |-- first time only: chezmoi init --apply, devenv allow
  |
  v
agentbox shell: ssh in, zsh in the project, devenv shell starts on its own
```

- **One definition, a container per project.** Every container runs the same NixOS system,
  `.devcontainer/tools/agentbox.nix`, so agentbox works in any project: `agentbox up` in its root. Each project gets
  its own container, named after its folder, with its own home and logins. What differs between projects is their
  `devenv.nix` and `agentbox.mounts`. The definition plays the part of an image, and each container is one instance
  of it:

  ```text
                       .devcontainer/tools/agentbox.nix   (one definition, built once into the host's /nix/store)
                          |                |                 |
            agentbox up in ~/code/api   in ~/code/web   in ~/.local/share/chezmoi
                          v                v                 v
  container:             api              web              chezmoi
  own root:   /var/lib/nixos-containers/api  .../web         .../chezmoi   (home, logins)
  mounts:          ~/code/api           ~/code/web       ~/.local/share/chezmoi
  project tools:   api's devenv.nix     web's devenv.nix   this repo's devenv.nix
  ```

  The containers run side by side, each with its own address, and share only the host's store: a package two of
  them use is on disk once.
- **The system** is built from the tools flake (`nixosConfigurations.agentbox`) on the nixpkgs its `flake.lock` pins.
  `nixos-container` builds it with the host's Nix daemon, so whatever the host store already has is not downloaded
  again. The file's comments explain each part and list the changes I might make.
- **Same paths as the host.** The project is mounted at its real path, and the user and home are the same as on the
  host (`mgajewskik`, `/home/mgajewskik`). A path in the project means the same inside and outside, and so does
  Claude's folder for the project, `~/.claude/projects/<key>`, where the key is the project path with every
  non-alphanumeric character turned into `-`.
- **The mounts.** The project is mounted read-write, ignored files included. My dotfiles go in read-only, at their
  usual path, as an export of what git would commit (`~/.cache/agentbox/dotfiles`): files my gitignores exclude,
  such as `.browser-profile/` and `.work/`, stay out. When the project is this repo, its own mount is used instead.
  Mounts use nspawn's `idmap`, so the agent (uid 1000 inside) reads and writes them as me.
- **Nix inside.** The host's store, database and daemon socket are mounted read-only. Builds and downloads run in the
  host's daemon; the container's users count as untrusted users of it.
- **Configuration.** chezmoi detects the container through `/run/systemd/container`, so `container`, `remote` and
  `nixTools` are true: no mise, no Chrome for Testing install, tools called directly.

## Standalone: one file per project

[`agentbox-simple/flake.nix`](agentbox-simple/flake.nix) is a whole container in one file: the NixOS system, the
host folders it mounts, and the commands that run it, as flake apps. It uses nothing from this setup beyond the
host's one-time configuration (`nixos/hosts/x1/agentbox.nix`): no launcher, no devenv, no shared module. Copy the
folder, set `name` and `project`, and from it:

```sh
nix run .#create     # builds the system as me, creates the container, writes its conf
nix run .#start
nix run .            # a shell in the project, inside its devenv shell when it has a devenv.nix
nix run .#desktop    # the agent's browser
nix run .#update     # after editing the system
nix run .#mounts     # after editing the mounts
nix run .#stop
nix run .#destroy
```

- **How a command runs.** `nix run .#start` evaluates the flake as me, builds that command's script into the store
  (`writeShellApplication`, which shellchecks it), and runs it as me; the script calls sudo where it needs root.
  `create` and `update` carry the built system's store path, so nix builds the system as me first and root receives
  the result: `nixos-container create --system-path`, and for a change, `nix-env --set` on the container's profile
  plus `systemctl reload`, the two steps `nixos-container update` takes after building.
- **The folder lives outside the project**, e.g. `~/boxes/myproj/` or in my dotfiles. The agent cannot apply a change
  itself: it has no root in the container and no access to `nixos-container` on my host. It would edit the file and
  wait for me: my next `nix run` here evaluates its Nix as me (reading my files, fetching URLs), runs its scripts
  with my sudo, and `update` hands its system to root in the container. Inside the project, no check of mine would
  hold: it can rewrite the file after I read it, or `.git/config` so that my `git diff` runs its code.
- **Mounts** are the `mounts` set in the flake, written to the container's conf as `PRIVATE_USERS=pick` and
  `EXTRA_NSPAWN_FLAGS` with the binds.
- **Start only through `nix run .#start`**, never `nixos-container restart`. It refuses when the conf lacks
  `PRIVATE_USERS=pick`, which would run the container with my host's uids, or when a mount point inside the container
  goes through a symlink. The agent owns its home there and could leave one, e.g. replacing `~/code` with a link;
  nspawn would then mount the project wherever it points, over files container root reads.
- **devenv**: `nix run .` opens `devenv shell` in the project when it has a `devenv.nix`, so its tools are on PATH
  for me and for an agent started there. That evaluates the agent-editable `devenv.nix` inside the container. On my
  host I don't `devenv allow` the project, so my zshrc's hook does not evaluate it when I cd in.
- **Left out**, compared with the launcher: my dotfiles (chezmoi), herdr, zsh, noVNC and a window manager.

### With devenv: the container in the project

[`agentbox-devenv/`](agentbox-devenv/) splits the work in two, both inside the project:

```text
devenv.nix            the project's dependencies and services (here python, jq, postgres, an app on 8080)
.agentbox/flake.nix   the container and its commands, as in agentbox-simple
```

From the project's folder: `nix run path:.agentbox#create`, then `#start`, then `nix run path:.agentbox`, which
opens a zsh in the project and applies my dotfiles on the first entry; `nix run path:.agentbox#herdr` attaches to
herdr in the project instead. `path:` makes nix copy only `.agentbox/` to the store, not the whole repository. Unlike
the standalone example, it has my tools flake, my dotfiles, herdr and host env vars: see
[agentbox-guide.md](agentbox-guide.md).

- **Dependencies:** every shell and herdr pane in the project is in the project's devenv shell, so its tools are on
  PATH for me and for an agent started there.
- **Services:** nothing starts them at boot. I run `devenv up` in a shell or a dedicated herdr pane inside the
  container, and the project's processes and services run until I stop it. Their data is in `.devenv/state`, in the
  project: it survives deleting the container. Running devenv on my host evaluates the agent's edits to
  `devenv.nix` as me, and running the services there too would share that state, so I run them in the container.
- **The agent can edit `.agentbox/`**, which I want: I can ask it to change the container. It cannot apply a change
  itself (no root inside, no way to my host's `nixos-container`), but my next `nix run` evaluates its version as me and
  runs its scripts with my sudo. A look first only holds while the file cannot change underneath: with the
  container stopped, or with the commented read-only mount in the flake turned on, and without git, whose repo config
  the agent can set.
- **No devenv on my host:** the agent can edit `devenv.nix`, `devenv.local.nix` and `devenv.lock`, and devenv on my
  host evaluates them as me, so the container's commands are only `nix run path:.agentbox#<command>`.

### Restarts and what persists

| Data                                                                                   | Restart, host reboot | `destroy`               |
| -------------------------------------------------------------------------------------- | -------------------- | ----------------------- |
| the container's home: Claude login, shell history, caches                              | kept                 | gone                    |
| the container's `/var`: services' data                                                 | kept                 | gone                    |
| the project, its `.devenv`, `.browser-profile`, Claude sessions (mounted from my host) | kept                 | kept                    |
| the system it runs (the container's Nix profile)                                       | kept                 | gone; rebuilt on create |
| `/tmp` (a tmpfs), running processes, agents mid-task                                   | gone                 | gone                    |

The container lives in `/var/lib/nixos-containers/<name>`. It does not start with my host (`AUTO_START=0`), so
after a reboot I start it again.

## Per-project containers

The `agentbox` launcher gives every project the same container. A project can instead carry its own definition,
next to its code like a `devcontainer.json`: [`agentbox-example/`](agentbox-example/) is a working example.

```text
<project>/
  devenv.nix                    the project's dev tools, inside the container and on my host
  .agentbox/
    container/flake.nix         nixosConfigurations.container: my base module (nixosModules.agentbox from
                                .devcontainer/tools) plus this project's packages, services and ports, and
                                agentbox.mounts, its host folders as data
    devenv.nix                  the commands: box-approve, box-up, box-update, box-shell, box-desktop, box-apply,
                                box-stop, box-destroy

~/.local/state/agentbox/<name>/ my approved copy of .agentbox/: every build and every command runs from here
```

- **Why an approved copy.** The agent can edit `.agentbox/`, the system it describes runs as root in the container,
  and container root reaches my host (see [No sudo](#no-sudo)). The commands in `.agentbox/devenv.nix` run on my host
  with sudo. So nothing runs from the project: `box-approve` takes a snapshot of `.agentbox/`, shows me the diff
  against the copy with escape sequences printed as text, and installs the snapshot only after I say yes. Links and
  special files are refused. Until I approve, `box-up` keeps using the old copy and says the project's differs.
- **First time** I read `.agentbox/` and run `devenv shell box-approve` in it, the one time the project's own copy
  runs. From then on: `cd ~/.local/state/agentbox/<name> && devenv shell box-up`, and so on.
- **Mounts** are `agentbox.mounts` in the flake, approved with the rest of the definition, under the same rules as
  the launcher's: allowed characters, `..` resolved, and no host path inside the project or inside another rw host
  path, where the agent could swap it for a symlink after I approved it.
- **Mount points** inside the container are checked for symlinks from the host while the container is stopped, just
  before it starts, so the agent cannot redirect an rw mount onto files container root reads.
- **The base** stays shared: my user, tools, desktop, browser, sshd and herdr come from `nixosModules.agentbox`. A
  project's flake pins it in its `flake.lock` by content, so after changing the base: `nix flake update agentbox` in
  `.agentbox/container`, then `box-approve` and `box-update`.

**Does the per-project way have fewer holes?** No, not by itself. The holes came from three things, and none of them
is about being generic: NixOS containers let container root reach the host; the host acts on files the agent can
edit (a mount list, now a whole definition and its commands); and the agent controls symlinks in paths the host
follows. A per-project definition is the biggest agent-editable input yet, so it is safe only through the approved
copy. What it buys is a container that fits each project, reviewed as one diff. Keeping definitions in my dotfiles
instead, out of the agent's reach, would need no approval at all.

The project's root `devenv.nix` is a different matter: my zshrc's hook evaluates it on my host whenever I `cd` into
a trusted project, approved or not. For a project an agent works on, I either leave it untrusted on my host
(`devenv revoke`) or read its changes before I `cd` in.

## Tools and devenv

**Global tools.** The package list in `.devcontainer/tools/flake.nix` (the same one my crib Nix containers install
into `~/.nix-profile`) is part of the container's system here, with devenv, Chromium, git, compilers and network
tools from `agentbox.nix`. They are linked into `/run/current-system/sw/bin` inside and live in the host's
`/nix/store`, where the host's garbage collection keeps them as long as the container exists. Nothing is installed
on the host itself.

**Project tools.** devenv comes from nixpkgs in the container's system. My zshrc's devenv hook starts the project's
devenv shell in every shell opened there, once the project is trusted: `agentbox up` runs `devenv allow` when the
project has a `devenv.nix`. devenv evaluates that project's `devenv.nix`, `devenv.yaml` and `devenv.lock`, builds
through the host daemon, and keeps its state and garbage-collection roots in the project's `.devenv/`. `devenv up`
runs the project's services inside the container. A project without devenv gets the global tools only.

**Installing more from inside.** Everything goes through Nix, and the agent may do all of it:

| How                                                                      | Lasts                                     | Notes                                                                  |
| ------------------------------------------------------------------------ | ----------------------------------------- | ---------------------------------------------------------------------- |
| `nix shell nixpkgs#foo`, `nix run nixpkgs#foo`, `nix-shell -p foo`       | that command or shell                     | any nixpkgs package, nothing to set up                                 |
| a package in the project's `devenv.nix`                                  | the project, safe from garbage collection | shows up in `git diff`, so I review what the agent added               |
| `npm i -g`, `uv tool install`, `go install`, binaries in `~/.local/bin`  | the container's home                      | prebuilt Linux binaries run through nix-ld                             |
| `nix profile install nixpkgs#foo`                                        | probably until the host's weekly GC       | untested: the profile's GC root names a home path the host cannot see  |
| a package in `agentbox.nix` or the tools flake, then `agentbox update`   | every container, permanently              | changed from the host                                                  |

There is no sudo and no apt: system packages and services come from `agentbox.nix` (see [No sudo](#no-sudo)).

The container's devenv comes from the tools flake's nixpkgs (2.4 when I checked), the host's from the host's (2.1).
Both use the project's `.devenv/`, so a shell on the host and one in the container may rebuild over each other's
state.

## One-time host setup

1. **Rebuild x1 with `nixos/hosts/x1/agentbox.nix`.** It turns containers on and sets up NAT, firewall tables for
   the containers and for download builds, memory, CPU and process caps for every container, and the devenv cache:

   ```sh
   sudo nixos-rebuild switch --flake ~/.local/share/chezmoi/nixos#x1
   ```

2. **Install the launcher.** `chezmoi init && chezmoi apply` writes `~/.local/bin/agentbox`, on NixOS hosts only.
3. **For herdr:** `Include ~/.ssh/config.d/*` as the first line of `~/.ssh/config`, as for crib.

## Day to day

| I want to                                     | I run                                                    |
| --------------------------------------------- | -------------------------------------------------------- |
| start the project's container                 | `agentbox up` in the project root                        |
| get a shell in the project                    | `agentbox shell`, or `ssh agentbox-<name>`               |
| see its desktop and the agent's browser       | `agentbox desktop`, then open the noVNC address          |
| use it as a herdr machine                     | `herdr machine add agentbox-<name> --label <name>`       |
| change its mounts                             | edit `agentbox.mounts`, then `agentbox up`               |
| re-apply my dotfiles after changing them      | `agentbox apply` (also after a failed first apply)       |
| pick up a change to `agentbox.nix` or tools   | `agentbox update`                                        |
| stop it                                       | `agentbox stop`                                          |
| delete it and its home                        | `agentbox destroy`                                       |
| see all containers                            | `agentbox list`                                          |

`<name>` is the project folder's name, lowercased, at most 11 characters (a limit of `nixos-container`). Two
projects with the same name cannot both have a container: the second `agentbox up`, or any other command there, stops
with "belongs to". Every command except `shell`, `desktop` and `list` runs `nixos-container` through `sudo`. If the
first `agentbox up` fails while building, `sudo nixos-container destroy <name>` clears what it left.

Inside:

- **Claude Code and pi:** log in once with `/login`; the login stays in the container's home and survives restarts.
  Claude runs in auto mode without its own sandbox, as in my dev containers.
- **Git:** commits work inside; the same checkout is on the host. For pushing, see [GitHub](#github).

## Mounts: agentbox.mounts

A project declares extra mounts in `agentbox.mounts` in its root, one per line:

```text
# mode  host path                    path inside (optional, default: the same path)
rw      ~/.claude/projects/{key}
ro      ~/notes
ro      ~/.config/some-tool/api.token  ~/.config/some-tool/api.token
```

- `rw` or `ro`; `~` is my home; `{key}` is this project's Claude key. Paths hold only letters, digits and
  `._/~{}+@=,-`, so the list I approve prints as it is mounted: no escape sequences, no backslashes. `..` is resolved
  before I see it. A path inside cannot be in the project, which is mounted already.
- A missing host path is created as a folder. A single existing file should work too (untested).
- `agentbox up` shows the expanded list and asks me to approve it, and keeps the approved list on the host, in
  `~/.local/state/agentbox/<name>.mounts`. The agent can edit `agentbox.mounts`, since it is in the project, so a
  changed file stops `agentbox up` until I approve the new list in a terminal or undo the change: the container
  does not start with mounts I have not seen. Deleting the file drops the extra mounts. A change in mounts restarts
  the container.
- **From `devenv.nix`.** agentbox never evaluates `devenv.nix` itself: that would run agent-written Nix on my host
  before I approve anything, and Nix evaluation can read any file I can and fetch URLs. devenv can write the file
  instead, on every `devenv shell`:

  ```nix
  files."agentbox.mounts".text = ''
    rw ~/.claude/projects/{key}
    ro ~/notes
  '';
  ```

  The file appears after the first devenv shell, on the host or inside, and goes through the same approval.
- **Sharing Claude's sessions.** `rw ~/.claude/projects/{key}` mounts this project's Claude folder at the same path,
  so the same key works inside and outside: `claude --resume` in the container sees my host sessions for the
  project, and my host sees the container's, memory included. The agent then reads every past session of the
  project, with whatever those printed.
- **Credentials:** mount the one file a tool needs, read-only, rather than its folder. **Never mount** `~/.ssh`,
  `~/.aws`, `~/.config/gh`, all of `~/.claude`, `/run/user/<uid>` (SSH agent, podman, the session bus) or my whole
  home: each hands the agent a host credential or control of the host.

## GitHub

Nothing of mine for GitHub goes in: no SSH agent, no token. Since a container keeps its home until
`agentbox destroy`, setting up access once per project inside is cheap and keeps each agent to its own repository:

- **A deploy key:** `ssh-keygen -t ed25519` inside, then add the public key to that repository as a deploy key, with
  write access if the agent should push. It reaches that one repository only.
- **Or a fine-grained token** for that repository, with `gh auth login` inside.

Or keep pushing from the host, where the same checkout lives.

## Changing the container

| I change                                          | Then                                                                                        |
| ------------------------------------------------- | ------------------------------------------------------------------------------------------- |
| `agentbox.nix`, the tools list, or `flake.lock`   | `agentbox update` in each project that should get it; nothing changes until then            |
| `agentbox.mounts`                                 | `agentbox up`: it asks me to approve the new list, then restarts the container              |
| my dotfiles                                       | `agentbox apply`                                                                            |

`agentbox update` builds the new system and, in a running container, switches to it in place, as `nixos-rebuild
switch` does on a host: services whose definition changed restart, the rest keeps running, my ssh shells included.
herdr's server runs from the tools package, so a change to the tools restarts it, with the herdr panes and agents
running in it. A stopped container boots the new system on its next start. The container's files are not touched:
home, logins and `/var/lib` stay as they were.

## Restarts and what persists

Everything in the container's root, `/var/lib/nixos-containers/<name>` on the host, survives stopping the container
and rebooting the host. Only memory is lost.

| Data                                                      | Where                                     | Survives a restart | Survives `agentbox destroy` |
| --------------------------------------------------------- | ----------------------------------------- | ------------------ | --------------------------- |
| Claude and pi logins, shell history, nvim plugins         | the container's home                      | yes                | no                          |
| service data, e.g. postgres from `agentbox.nix`           | the container's `/var/lib`                | yes                | no                          |
| the agent's browser profile                               | `.browser-profile/` in the project        | yes                | yes                         |
| the project, its `.devenv/` and devenv service state      | my host, mounted in                       | yes                | yes                         |
| whatever `agentbox.mounts` mounts                         | my host, mounted in                       | yes                | yes                         |
| `/tmp` (a tmpfs of 10% of RAM) and `/run` inside          | memory                                    | no                 | no                          |
| running processes, agents included                        | -                                         | no                 | no                          |

- **After a host reboot** containers stay stopped (`nixos-container create` writes `AUTO_START=0`); `agentbox up`
  starts one again with everything above. The IP address is fixed in its conf, so ssh and herdr keep working.
- **To keep a login through `agentbox destroy`,** mount its folder from the host, e.g.
  `rw ~/.local/share/agentbox/<name>/claude ~/.claude` in `agentbox.mounts`.
- **Backups.** The containers live under `/var/lib`, on the root subvolume, so my `/home` snapshots do not cover
  them. What must not be lost belongs in the project or in a mount.

## The browser

agent-browser opens Chromium from nixpkgs (`AGENT_BROWSER_EXECUTABLE_PATH`) as a window on the container's desktop
(`AGENT_BROWSER_HEADED`, `DISPLAY=:1`). Its persistent profile is `.browser-profile/` in the project's root, as in my
dev containers: logins survive restarts and `agentbox destroy`, and stay apart from my host browser and other
projects. `agentbox up` records the project's path in the container (`/var/lib/agentbox/project`), and the
container's shell setup points `AGENT_BROWSER_PROFILE` there. My global gitignore keeps `.browser-profile/` out of
commits.

The desktop is TigerVNC on `:1` with Fluxbox, at `http://<container ip>:6080` through noVNC or `vncviewer <ip>:5901`,
password `vscode`, as in desktop-lite. Only this host can reach those ports.

## Isolation

| The agent can                                            | The agent cannot                                                                                                      |
| -------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------- |
| read and write the project, as me                        | read my home, `~/.ssh`, `~/.claude`, other projects, beyond the mounts I approved                                     |
| read my dotfiles as git would commit them                | read their ignored files, or write them, unless the dotfiles are the project                                          |
| reach the internet                                       | reach this host, other containers, or private networks (`10/8`, `172.16/12`, `192.168/16`, `100.64/10`, `169.254/16`) |
| read every path in the host's Nix store                  | change the store's contents (untrusted daemon user, read-only mounts)                                                 |
| run builds through the host daemon                       | become root: there is no sudo                                                                                         |
| add mounts to `agentbox.mounts`                          | get them mounted without my approval                                                                                  |
| use whatever I log into inside                           | use my SSH agent, GitHub token or host Claude credentials                                                             |

### No sudo

The NixOS manual (containers chapter) warns that "a user with root access to the container can do things that affect
the host", and the container code in nixpkgs 26.05 shows how:

- **On every start, my host works as root inside the container's root.** The start script creates and chmods
  `etc`, `var/lib` and `root` there and copies `/etc/resolv.conf` into `etc`. Root inside could replace `etc` with a
  symlink to a host path, and the next start would chmod or write through it.
- **Two host folders are writable as host root.** The container's Nix profile and GC-root folders,
  `/nix/var/nix/{profiles,gcroots}/per-container/<name>`, are mounted read-write with `idmap`, so root inside writes
  there as host root. It could leave a setuid-root program there, and `/nix` is not mounted `nosuid`.
- **With `idmap`, root inside also writes the project as host root,** for example a setuid-root binary in my
  checkout.

So the agent must never be root here. Container root is an unused host uid (from 524288 up, `PRIVATE_USERS=pick`),
but those paths do not depend on that. The agent stays uid 1000, which tools from Nix allow. If I ever add sudo
(`agentbox.nix` says how), I accept all of the above; a microVM is the safe way to give an agent root.

### Can the agent escape?

- **Through what it is handed:** much less than in crib. A crib container gets my SSH agent, `GITHUB_TOKEN` and
  Claude mounts, and an open network, LAN included. agentbox gets none of these, and only the mounts I approve.
- **Through a kernel bug,** as in any container: the kernel is shared. A breakout as uid 1000 inside lands in the
  container's own host uid range, which owns nothing of mine outside the container. In rootless podman, the container's users map into my host
  user's range and container root is my host user, so a breakout there gets my whole home.
- **Through a root bug inside,** a privilege escalation in the container, which would give it container root and the
  paths above. With no sudo there is little to escalate through: agentbox-devenv also turns off every setuid
  program but `unix_chkpwd`, which PAM needs to start my user's systemd; the launcher's containers still have
  NixOS's own wrappers.
- **Through root-run host code,** where agentbox exposes more than crib. The host's Nix daemon runs as root and the
  container talks to it, so a daemon bug would mean host root; the 2025 Nix daemon advisories were bugs of that
  kind. systemd-nspawn, which runs the container, also runs as root. Rootless podman has no root process.
- **Through the project, in every setup:** whatever I run on the host from the project is code the agent could have
  written: `.git/hooks`, `Makefile` and `package.json` scripts, tests, nvim's per-project config, and `devenv.nix`,
  which my zshrc's hook evaluates on `cd` in a trusted project. I check those after an agent session.

Also keep in mind:

- **Builds run in the host daemon,** outside the container, so they are not limited like its processes. A download
  build runs on the host's network; `agentbox.nix` blocks build users from the host's addresses, the containers and
  private ranges, but not from the host's abstract unix sockets or LAN devices with global IPv6 addresses.
- **The host store is readable.** Nothing secret belongs in it: the rule on my NixOS hosts is to keep secrets out of
  the store, and nothing enforces it.
- **Everything in the project is readable,** ignored files included: a `.env` in it is the agent's too.
- **Never garbage-collect inside.** It would collect the host's store, and the host cannot see roots that live only
  in the container. On the host, the weekly `nix.gc` keeps the container's system (its profile is on the host) and
  should keep devenv environments, whose roots point at the project's real path.

## Files

| File                                     | What it does                                                                     |
| ---------------------------------------- | -------------------------------------------------------------------------------- |
| `.devcontainer/tools/agentbox.nix`       | the container's NixOS system, commented, with the changes I might make           |
| `.devcontainer/tools/flake.nix`          | `nixosConfigurations.agentbox`, next to the tools package it reuses              |
| `nixos/hosts/x1/agentbox.nix`            | host side: containers on, NAT, firewall tables, caps, networkd, devenv cache     |
| `dot_local/bin/executable_agentbox.tmpl` | the launcher                                                                     |
| `.chezmoi.toml.tmpl`                     | detects the container through `/run/systemd/container`                           |
| `agentbox.mounts`, in a project          | that project's extra mounts, for the launcher                                    |
| `agentbox-simple/flake.nix`              | a standalone container for one project in one file                               |
| `agentbox-devenv/`                       | the container in the project: devenv.nix and .agentbox/flake.nix                 |
| `agentbox-example/`                      | a project with its own container definition and devenv commands                  |

The firewall table drops container traffic to the host, between containers, and to private ranges, and new
connections into containers from anywhere but the host. networkd is told
to leave the `ve-*` interfaces alone: `nixos-container` addresses them itself, and networkd's built-in
`80-container-ve.network` would also claim them.

## Compared with the other setups

|                         | crib + mise (`default/`, `mini/`)                      | crib + devenv image (this repo's container)       | devenv on the host         | agentbox                                                |
| ----------------------- | ------------------------------------------------------ | ------------------------------------------------- | -------------------------- | ------------------------------------------------------- |
| Isolation               | rootless podman                                        | rootless podman                                   | Claude's Bash sandbox only | nspawn with its own user namespace and network, no sudo |
| Runs on                 | any host with podman                                   | any host with podman                              | any host with Nix          | NixOS hosts                                             |
| Start                   | `crib up`                                              | `crib up`                                         | `cd` into the project      | `agentbox up` (sudo)                                    |
| Global tools            | mise, in each container                                | my tools flake, in the shared `devenv-nix` volume | the host's                 | my tools flake, in the container's system               |
| Project tools           | mise, apt                                              | devenv                                            | devenv                     | devenv                                                  |
| Extra mounts            | `devcontainer.json`, applied as written                | the same                                          | -                          | `agentbox.mounts`, applied after my approval            |
| Shares packages with    | nothing                                                | other crib Nix containers                         | the host's store           | the host and every agentbox                             |
| Image                   | `base:debian`, 972 MB                                  | devenv image, 3.12 GB                             | none                       | none                                                    |
| Browser                 | Chrome for Testing, desktop-lite                       | the same                                          | my host browser            | nixpkgs Chromium, TigerVNC and noVNC                    |
| sudo inside             | passwordless                                           | passwordless                                      | -                          | none                                                    |
| Host credentials inside | SSH agent, `GITHUB_TOKEN`, Claude login (crib plugins) | the same                                          | all of them                | none, beyond the project and approved mounts            |
| Network                 | open                                                   | open                                              | the host's                 | internet only                                           |
| A breakout lands as     | my host user                                           | my host user                                      | -                          | an unused uid; but the root Nix daemon is reachable     |
| Cost                    | tools downloaded per container                         | big image, crib workarounds                       | weakest isolation          | root to manage, x1 only, not run yet                    |

My reading: on a NixOS host, agentbox gives the strongest isolation of the four as configured here, with the least
machinery: no image, no mise, one store, and the agent gets none of my credentials. crib stays the answer for
machines without NixOS and for projects whose `devcontainer.json` is shared with other people.

## Not verified yet

- The standalone example: its `nix run` apps, `create --system-path`, the appended conf lines, `machinectl shell`
  into the container, `devenv shell` inside it, `devenv up` as a systemd unit without a terminal, and the shell
  reaching its services (`echo $PGHOST`, `psql -d app`, `devenv processes list`); the browser in the container:
  chromium's own sandbox, agent-browser on the VNC display.
- The first container build on the tools flake's nixpkgs (the modules were evaluated against x1's 26.05).
- `idmap` mounts from x1's btrfs `/home`, and writing the project from inside; a single-file mount from
  `agentbox.mounts`.
- That the agent owns the folders nspawn creates under its home for mounts (`agentbox up` fixes them after the start).
- `AGENT_BROWSER_PROFILE` from `/var/lib/agentbox/project` in ssh shells, herdr panes and Claude's commands.
- chezmoi's first apply inside: plugins, nvim's lazy restore, Mason binaries through nix-ld.
- Chromium's own sandbox inside the user namespace. If it refuses to start, `AGENT_BROWSER_ARGS=--no-sandbox` is
  the fallback.
- herdr's server as a system service, and `herdr machine add` over the generated ssh config.
- That the host's `nix.gc` keeps devenv environments built inside.
- `nix-shell -p` through the container's `nix.nixPath`.
- The per-project commands as devenv scripts: `devenv shell box-up` in the approved copy, sudo from inside a devenv
  shell, `nix eval` of `agentbox.mounts`, and a `path:` input to my dotfiles in a project's `flake.lock`. The scripts
  pass shellcheck and their own tests with stubs; nothing has run against a real container.

## Undo

`agentbox destroy` in each project, remove `./agentbox.nix` from the x1 imports, then
`sudo nixos-rebuild switch --flake ~/.local/share/chezmoi/nixos#x1`.
