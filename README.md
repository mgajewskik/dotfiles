# dotfiles

My shell, editor and terminal setup, managed with [chezmoi](https://www.chezmoi.io/). One command sets up any
machine I land on, desktop, server or container, without asking me anything; the mise tools come at the versions
pinned in a lockfile.

## New machine

```sh
sh -c "$(curl -fsLS get.chezmoi.io)" -- -b ~/.local/bin init --apply mgajewskik
```

`mgajewskik` expands to `https://github.com/mgajewskik/dotfiles.git`. HTTPS is all I need, even to push:
`~/.gitconfig` sends my pushes to GitHub over SSH (`pushInsteadOf`).

If the machine already has dotfiles, I drop `--apply`, read `chezmoi diff`, then `chezmoi apply`.

If I'll plug the YubiKey in there, I install gnupg and pcscd first ([YubiKey](#yubikey-and-gpg)), so the first apply
imports my public key.

What `chezmoi apply` does:

- writes my dotfiles, minus the ones this kind of machine has no use for (next section);
- installs my [mise](https://mise.jdx.dev/) tools at the versions in `~/.config/mise/mise.lock`, downloading mise
  first if missing. The lockfile holds URLs and checksums, so no GitHub token needed;
- clones my [nvim config](https://github.com/mgajewskik/nvim) to `~/.config/nvim` and downloads the zsh plugins
  (fzf-tab, zsh-syntax-highlighting) to `~/.zsh`;
- installs my yazi and herdr plugins;
- imports my gpg public key with ultimate trust.

Each install step re-runs only when its input changes. tmux plugins install themselves the first time I start tmux.

### What each machine gets

`chezmoi init` sets two flags:

| Flag        | True when                  | Skips                                                |
| ----------- | -------------------------- | ---------------------------------------------------- |
| `container` | inside a container         | crib, devsy, crib's config                           |
| `remote`    | in a container or over SSH | terminals, fonts, herdr's GPUI config, uwsm session  |

- `container` comes from `/run/.containerenv` (podman) or `/.dockerenv` (docker), or from `container`, `CODESPACES`,
  `REMOTE_CONTAINERS` or `KUBERNETES_SERVICE_HOST` in the environment.
- The terminals are alacritty, kitty and ghostty. The uwsm Wayland session is `~/.profile`, `~/.zprofile` and
  `~/.config/uwsm`, also skipped outside Linux.
- Everything else goes everywhere.

To check: `chezmoi data | grep -E '"(remote|container)"'`. Setting up a desktop over SSH, I run
`env -u SSH_CONNECTION chezmoi init` there, or it counts as a server.

## Day to day

| I want to                          | I run                                         |
| ---------------------------------- | --------------------------------------------- |
| edit a dotfile                     | `chezmoi edit ~/.zshrc`, then `chezmoi apply` |
| keep a change I made in place      | `chezmoi re-add ~/.zshrc`                     |
| see what apply would change        | `chezmoi diff`                                |
| commit and push                    | `chezmoi cd`, then git as usual               |
| pull and apply on another machine  | `chezmoi update`                              |
| update nvim config and zsh plugins | `chezmoi apply --refresh-externals`           |

`c` is my alias for `chezmoi`. The zsh plugins also refresh weekly on their own. The nvim config is its own repo:
I commit and push it from `~/.config/nvim`.

What I set up, in short:

- **zsh**: vi mode; Up/Down search history by prefix; Tab completes in fzf; `Ctrl-R` history, `Ctrl-T` files,
  `Alt-C` directories; `cd` is zoxide (`cdi` picks with fzf); `y` opens yazi and follows its last directory;
  `ls`, `cat`, `man`, `rg` are eza, bat, batman and batgrep; `k` is kubectl.
- **tmux**: prefix `C-b` or `C-a`; my cheat sheet heads `~/.tmux.conf`. Sessions survive restarts
  (resurrect + continuum); `prefix q`, or `t` from the shell, opens the session wizard.
- **herdr**: prefix `ctrl+a`; my keys are in `~/.config/herdr/config.toml`. When `prefix e` (nvim sidebar) hangs,
  `~/.config/herdr/herdr-nvim-unstick` frees it.
- **git**: diffs go through difftastic; `git diff --no-ext-diff` gives me a plain patch.

## Changing the setup

### mise tools

My tools in `dot_config/mise/config.toml.tmpl` say `latest`; `mise.lock` pins what that means on every machine
(linux x64/arm64, macOS arm64). I change it outside a container only: containers lack crib and devsy, so locking
there would drop them.

- Add: add the tool to the config and `chezmoi apply`; installing it also locks it.
- Upgrade all: `mise lock -g --bump`, then `mise install`. mise skips releases younger than 7 days and gets
  GitHub access from `gh auth token`.
- Remove: delete it from the config, then `mise lock -g`.

Then `chezmoi add ~/.config/mise/mise.lock`.

### Plugins

- **yazi**: pinned in `~/.config/yazi/package.toml`. After `ya pkg add` or `ya pkg upgrade`, I run
  `chezmoi re-add ~/.config/yazi/package.toml`.
- **herdr**: herdr keeps no lockfile, so my list lives in `.chezmoiscripts/run_onchange_after_plugins_herdr.sh.tmpl`;
  I add plugins there. To update all of them, I change its `refreshed:` date.
- **tmux**: listed in `~/.tmux.conf`, managed by tpm: `prefix I` installs, `prefix U` updates. Before pointing a
  plugin at another repo, I delete `~/.tmux/plugins/<name>`.

### Another git identity on one machine

On a work server, say, I put the other identity in `~/.gitconfig.local`. chezmoi leaves it alone and git reads it
last:

```ini
[user]
	name = My Name
	email = me@work.example
```

### Machine detection

Detection lives in `.chezmoi.toml.tmpl` and runs only at `chezmoi init`. After changing it, I run `chezmoi init` on
each machine before the next apply; a config missing a key the templates read fails with `map has no entry for key`.

## YubiKey and gpg

My gpg secret keys live only on the YubiKey. Every machine gets my `~/.gnupg/gpg.conf`, `scdaemon.conf` and public
key. gpg reaches the card through pcscd (`disable-ccid`), so each machine I plug it into needs:

```sh
sudo pacman -S --needed gnupg pcsclite ccid                         # Arch
sudo apt install gnupg scdaemon pcscd                               # Debian/Ubuntu
sudo dnf install gnupg2 pcsc-lite pcsc-lite-ccid                    # RHEL/Rocky
sudo dnf install gnupg2 gnupg2-scdaemon pcsc-lite pcsc-lite-ccid    # Fedora (43+ splits out scdaemon)
sudo systemctl enable --now pcscd.socket
gpg --card-status                                                   # key plugged in: links my secret keys to the card
```

- Installed gnupg after the first apply? The import was skipped; I redo it with
  `chezmoi state delete-bucket --bucket=scriptState && chezmoi apply` (re-runs every install script, harmlessly).
- `ykman` cannot reach the key while gpg holds it: `gpgconf --kill scdaemon`.

## Containers

In a container my dotfiles install through `setup.sh`: unattended, no arguments, and it makes zsh the login shell
where sudo needs no password. [devsy](https://github.com/devsy-org/devsy) and [crib](https://github.com/fgrehm/crib)
both clone this repo and run it.

### My dotfiles in any project's container

**devsy**, once per machine:

```sh
devsy provider add podman
devsy context set -o DOTFILES_URL=https://github.com/mgajewskik/dotfiles
```

then in a project: `devsy workspace up . --ide none`.

**crib**: my `~/.config/crib/config.toml` already names the dotfiles.

```sh
crib up        # build and start; the first time, clones my dotfiles and runs setup.sh
crib shell     # zsh inside
crib down      # remove the container; the next `up` restores it, dotfiles included
crib rebuild   # from scratch: new image, setup.sh again
crib remove    # container, images and crib's state
```

A `.cribrc` in a project root overrides my global config for that project. In someone else's project I keep it out of
their git with `echo .cribrc >> .git/info/exclude`. One setting per line:

- `dotfiles.repository = https://github.com/mgajewskik/dotfiles`: my dotfiles on a machine without my crib config
- `dotfiles = false`: no dotfiles in this project
- `plugins.disable = ssh`: untrusted code, so no access to my SSH agent

crib passes my host's `$GITHUB_READONLY` into the container as `GITHUB_TOKEN` (the `crib` wrapper in `.zshrc`);
without it the container gets no token.

### Flags only, no saved config

devsy takes everything as flags; only the provider must be added once (`--provider` picks among added ones):

```sh
devsy provider add podman    # once per machine
devsy workspace up . --ide none --dotfiles https://github.com/mgajewskik/dotfiles
```

`--ssh-gpg-forwarding` adds gpg through the host's YubiKey, for projects I trust.

crib (0.10) has no dotfiles flag: only its global config or a `.cribrc` names them. Without either, I install my
dotfiles into the running container by hand; they live in that container only.

```sh
crib up --disable-plugin ssh    # optional, the flag form of plugins.disable = ssh
crib exec -- sh -c 'git clone https://github.com/mgajewskik/dotfiles ~/.local/share/chezmoi && cd ~/.local/share/chezmoi && ./setup.sh'
```

### Sandboxes per Linux family

Generic images, not tied to a project: a `dev` user with zsh and passwordless sudo, so I can install packages as I go.

| Definition              | Base                       | Platforms    |
| ----------------------- | -------------------------- | ------------ |
| `.devcontainer/arch/`   | `archlinux:latest`         | amd64        |
| `.devcontainer/rocky/`  | `rockylinux/rockylinux:10` | amd64, arm64 |
| `.devcontainer/fedora/` | `fedora:43`                | amd64, arm64 |

With devsy (after `devsy provider add podman`), straight from GitHub; `arch` swaps for `rocky` or `fedora`:

```sh
devsy workspace up github.com/mgajewskik/dotfiles \
  --devcontainer id:arch --id arch --ide none --dotfiles github.com/mgajewskik/dotfiles
devsy workspace ssh arch       # zsh as dev
devsy workspace stop arch      # `devsy workspace up arch` starts it again
devsy workspace delete arch
```

`--recreate` on the `up` command rebuilds from scratch.

crib cannot use these definitions in place (it would treat `.devcontainer/` as one project for all three). For crib,
or on a server, I copy one into a folder as its `.devcontainer/`:

```sh
mkdir -p ~/sandbox/.devcontainer && cp ~/.local/share/chezmoi/.devcontainer/fedora/* ~/sandbox/.devcontainer/
crib -d ~/sandbox up && crib -d ~/sandbox shell     # crib's other commands take the same -d
devsy workspace up ~/sandbox --id sandbox --ide none --dotfiles github.com/mgajewskik/dotfiles   # or devsy
```

### gpg inside a container

My secret keys stay on the YubiKey in the host; the container borrows the host's gpg-agent, and the PIN prompt shows
on the host.

- devsy: `--ssh-gpg-forwarding` on `workspace up`, only for projects I trust
  (`devsy context set -o GPG_AGENT_FORWARDING=true` makes it the default).
- The test container below mounts the agent's restricted socket, which decrypts and signs but refuses card commands
  such as `gpg --card-status`. The socket must exist before `crib up` (`gpg-connect-agent /bye`); after restarting
  the host agent, `crib restart`.

### Testing changes to this repo

`.devcontainer/devcontainer.json` (Debian) runs `setup.sh` from this checkout, so I can try uncommitted changes
without pushing. `.cribrc` here turns off my global dotfiles install so it does not run twice.

```sh
crib up && crib shell     # look around: chezmoi data, mise ls
crib rebuild              # after changing setup.sh
crib remove
```

With devsy I use a context without `DOTFILES_URL`, or it applies the pushed dotfiles over the checkout:

```sh
devsy context create dotfiles-test && devsy provider add podman --context dotfiles-test   # once
devsy workspace up . --ide none --context dotfiles-test
```

## Where things live

| Path                     | What it is                                                            |
| ------------------------ | --------------------------------------------------------------------- |
| `.chezmoi.toml.tmpl`     | machine detection (`container`, `remote`)                             |
| `.chezmoiignore`         | which files each kind of machine skips                                |
| `.chezmoiexternals/`     | downloads: mise binary, nvim config, zsh plugins, fonts               |
| `.chezmoiscripts/`       | run-on-change installers: mise tools, yazi and herdr plugins, gpg key |
| `dot_*`, `private_dot_*` | the dotfiles (`dot_zshrc` becomes `~/.zshrc`)                         |
| `dot_config/mise/`       | tool list and lockfile                                                |
| `setup.sh`               | container entry point                                                 |
| `.devcontainer/`         | test container and the per-family sandboxes                           |
| `.pgp-public.asc`        | my gpg public key                                                     |
