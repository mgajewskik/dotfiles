# Managing the x1 flake's inputs with tack

*tack 2.0.0 · flake at `~/.local/share/chezmoi/nixos` · upstream docs: <https://docs.manic.systems/tack>*

The x1 flake no longer declares `inputs` or keeps them in `flake.lock`. [tack](https://github.com/manic-systems/tack) pins them instead: you declare the inputs in a TOML file, `tack update` locks them, and `flake.nix` reads the lock through a small Nix resolver that tack writes. Building and switching work exactly as before.

- **Check for updates:** `cd ~/.local/share/chezmoi/nixos && tack look`
- **Update everything:** `tack update`, then `nh os switch` (or `sudo nixos-rebuild switch --flake ~/.local/share/chezmoi/nixos#x1`)
- **Undo the last tack change:** `tack undo`

## What tack changes

| | before | with tack |
|---|---|---|
| declare an input | `inputs.<name>.url` in `flake.nix` | `[inputs.<name>]` in `.tack/pins.toml` |
| lock file | `flake.lock` | `.tack/pins.lock.json` (`flake.lock` stays, with no inputs in it) |
| update all | `nix flake update` | `tack update` |
| update one | `nix flake update nixpkgs` | `tack update nixpkgs` |
| see what's new before updating | nothing built in | `tack look`, `tack look -v` |
| hold an input back | remember not to update it | `tack freeze <name>` |
| undo an update | `git checkout flake.lock` | `tack undo` (or git) |
| `inputs.<name>.follows` | in `flake.nix` | `follows = { … }` in `pins.toml` |
| follow release tags | edit the tag in the URL by hand | `tag = "v{version}"` |

What stays the same: `flake.nix` is still the entry point, every module still reads `inputs.<name>` and `self` from flake-parts, and `nixos-rebuild`/`nh` commands are unchanged.

The migration kept every input at the commit it had in `flake.lock`: the x1 system derivation evaluated to the identical store path before and after the switch to tack. After that, tack was added to the system packages, and voxtype (v1.1.1 → v1.3.1) and vortix (v0.5.5 → v0.6.0) moved to their newest releases when they were switched to follow release tags. helium (0.20.2.1 → 0.22.5.1), claude-desktop (2.42304.0 → 6.28899.6) and grok-bot (0.77.0 → 1.3.0) did the same when they became fixed pins.

## The files

```text
nixos/
├── flake.nix              outputs only: imports ./.tack and hands the pins to flake-parts
├── flake.lock             no inputs; nix keeps it, tack does not use it
└── .tack/
    ├── pins.toml          what you want: one [inputs.<name>] table per input. Edit by hand or with tack commands
    ├── pins.lock.json     what you have: the exact commit and content hash of each pin. Written by tack update
    ├── default.nix        the resolver: `import ./.tack` gives the pins as flake-like inputs. Written by tack
    └── .gitignore         ignores the patched/ trees tack builds when a pin has patches
```

Commit `pins.toml`, `pins.lock.json` and `default.nix`. The flake lives in a git repo, so Nix only sees files git tracks: a new file under `.tack/` that is not `git add`ed is invisible to `nixos-rebuild`. Changes to files that are already tracked are seen without committing.

Leave `default.nix` alone. Its second line marks it as tack-managed. When it falls behind the installed tack, tack prints `resolver at … is out of date. run tack init --resolver to update`, and that command rewrites it.

### How flake.nix reads the pins

```nix
outputs =
  { self, ... }:
  let
    pins = import ./.tack;
    inputs = pins // {
      self = self // {
        inputs = pins;
      };
    };
  in
  inputs.flake-parts.lib.mkFlake { inherit inputs; } (inputs.import-tree ./modules);
```

`import ./.tack` returns one attribute per pin, shaped like a flake input (`outPath`, `rev`, `narHash`, `lastModified`, and the flake's outputs). flake-parts builds `inputs'` and the default `pkgs` of `perSystem` from `self.inputs`, which Nix fills from `flake.lock`. That lock is empty now, so `flake.nix` puts the pins there as well. Without it, evaluation fails with `flake-parts: The flake does not have a nixpkgs input`.

The flake also exports `nixpkgs` (the pinned one) as an output, in `modules/flake-parts.nix`. The agent box template in `devenv/.box/flake.nix` takes its nixpkgs from there, because other flakes can no longer write `nixpkgs.follows = "tools/nixpkgs"`. This flake has no flake inputs left to follow.

## The pins

| pin | url | follows | notes |
|---|---|---|---|
| `nixpkgs` | `github:NixOS/nixpkgs/nixos-26.05` | | the system's nixpkgs |
| `nixpkgs-unstable` | `github:NixOS/nixpkgs/nixos-unstable` | | `modules/tools.nix` and the tack package |
| `flake-parts` | `github:hercules-ci/flake-parts` | `nixpkgs-lib = "nixpkgs"` | |
| `import-tree` | `github:vic/import-tree` | | `tag = "v{version}"` |
| `nixos-hardware` | `github:NixOS/nixos-hardware` | `nixpkgs = "nixpkgs"` | |
| `disko` | `github:nix-community/disko` | `nixpkgs = "nixpkgs"` | `tag = "v{version}"` |
| `voxtype` | `github:peteonrails/voxtype` | `nixpkgs = "nixpkgs"` | `tag = "v{version}"` |
| `vortix` | `github:Harry-kp/vortix` | `nixpkgs = "nixpkgs"` | `tag = "v{version}"` |
| `tack` | `github:manic-systems/tack` | `nixpkgs = "nixpkgs-unstable"` | `tag = "v{version}"` |
| `helium` | the GitHub release tarball | | `fixed`, versions read from GitHub's latest-release API, used by `modules/pkgs/helium.nix` |
| `claude-desktop` | the .deb in Anthropic's apt pool | | `fixed`, versions read from the apt index, used by `modules/pkgs/claude-desktop.nix` |
| `grok-bot` | the .deb on downloads.cursor.com | | `fixed`, versions read from Cursor's release feed, used by `modules/pkgs/grok-bot.nix` |

A pin's `follows` points one of that input's own inputs at one of your pins, like `inputs.<name>.inputs.nixpkgs.follows` did. Without it, the input would bring its own nixpkgs from its own lock, and you would download and evaluate a second copy.

## Day to day

Run tack from `~/.local/share/chezmoi/nixos` or a folder below it. tack looks for the nearest `.tack` folder above the current directory, so it can't find this project from the chezmoi repo root. Setting `TACK_DIR=~/.local/share/chezmoi/nixos/.tack` works from anywhere.

### Give tack a GitHub token

tack asks the GitHub API to compare commits. Without credentials it hits GitHub's anonymous rate limit fast, and `look` reports pins it could not compare as `unverified` or prints `auth: github.com: no usable credentials`. It looks for a token in this order: `GITHUB_TOKEN` or `GH_TOKEN`, then `~/.netrc`, then git's credential helper. With `gh` logged in, this is enough:

```console
$ export GITHUB_TOKEN=$(gh auth token)
```

### See what an update would bring

```console
$ tack look
disko: unchanged
flake-parts: unchanged
import-tree: unchanged
nixos-hardware: 04c6b94 -> ec39df5 (diverged)
nixpkgs: 6f06d20 -> 0dc498b (unverified)
nixpkgs-unstable: 0490633 -> 2786a2a (ahead)
...
```

`look` never writes anything. `ahead` means upstream has new commits on top of yours. `diverged` means the branch head and your commit each have commits the other lacks, for example after upstream rewrote history. `unverified` means tack could not compare the two commits, usually for lack of a token. `tack look -v nixpkgs` lists the commits between the two.

### Update and switch

```console
$ tack update                          # every pin that isn't frozen
$ tack update nixpkgs                  # just one (frozen or not)
$ tack update --exclude nixpkgs-unstable
$ git diff .tack/pins.lock.json        # the new revisions
$ nh os switch                         # or: sudo nixos-rebuild switch --flake ~/.local/share/chezmoi/nixos#x1
$ git -C ~/.local/share/chezmoi commit -m "chore(nixos): update inputs" -- nixos/.tack
```

As before, the update only changes files. Nothing on the system changes until you switch.

### Roll back

- **Before switching:** `tack undo` puts `pins.toml` and `pins.lock.json` back to before the last tack command, and `tack redo` reapplies it. `tack undo --list` shows the history. That history lives on this machine, in `~/.local/state/tack/`, not in git.
- **From git:** `git checkout -- .tack/pins.lock.json` (or any older commit of it) works on any machine.
- **After switching:** `sudo nixos-rebuild switch --rollback`, or pick an older generation at boot. This rolls back the running system, not the lock, so undo the lock too, or the next switch rebuilds the same thing.

### Hold an input back

```console
$ tack freeze nixpkgs-unstable         # update skips it from now on
froze nixpkgs-unstable at 0490633
$ tack update nixpkgs-unstable         # naming it still moves it, and it stays frozen at the new commit
$ tack unfreeze nixpkgs-unstable
```

`freeze` writes `frozen = "<commit>"` into the pin's table in `pins.toml`, so the hold is in git and survives on other machines.

### Add an input

```console
$ tack add nix-index-database github:nix-community/nix-index-database --follows nixpkgs
```

`--follows nixpkgs` is short for `--follows nixpkgs=nixpkgs`: the new input's `nixpkgs` follows your `nixpkgs` pin. Use `--fetch` for a source tree that isn't a flake (what `flake = false` was). Then use it in a module as usual, `inputs.nix-index-database.nixosModules.nix-index`. `pins.lock.json` is tracked, so Nix sees the new pin without committing; still commit it.

To remove one, take it out of the modules first, then `tack rm <name>`.

### Follow releases instead of a branch

`disko`, `import-tree`, `voxtype`, `vortix` and `tack` follow releases: no ref in the URL, and a `tag` template. `tack update` locks the newest tag that matches.

```toml
[inputs.voxtype]
url = "github:peteonrails/voxtype"
tag = "v{version}"
```

A template like `v{version}` skips pre-releases such as `v1.3.2-rc4`. To keep one release for good, put it in the URL instead (`github:peteonrails/voxtype/v1.3.1`) and drop `tag`, or `tack freeze` the pin.

The other pins track branches on purpose. `nixos-26.05` and `nixos-unstable` are nixpkgs' release channels, which get fixes continuously. flake-parts and nixos-hardware publish no release tags.

### Vendor apps: fixed pins

helium, claude-desktop and grok-bot are not flakes but single downloads. A `fixed` pin locks such a file by its sha256, and with a `tag` template it follows the vendor's releases. `tack update` reads the release list, picks the highest `{version}` that matches, downloads it and locks the hash.

```toml
[inputs.helium]
url = "https://github.com/imputnet/helium-linux/releases/download/{version}/helium-{version}-x86_64_linux.tar.xz"
type = "fixed"
unpack = "tarball"
tag = "helium-{version}-x86_64_linux.tar.xz"
tags_from = "https://api.github.com/repos/imputnet/helium-linux/releases/latest"

[inputs.claude-desktop]
url = "https://downloads.claude.ai/claude-desktop/apt/stable/pool/main/c/claude-desktop/{tag}"
type = "fixed"
unpack = "file"
tag = "claude-desktop_{version}_amd64.deb"
tags_from = "https://downloads.claude.ai/claude-desktop/apt/stable/dists/stable/main/binary-amd64/Packages"

[inputs.grok-bot]
url = "https://downloads.cursor.com/grokbot/stable/{commit}/linux/x64/grok-bot_{version}_amd64.deb"
type = "fixed"
unpack = "file"
tag = "stable/{commit}/linux/x64/grok-bot_{version}_amd64.deb"
tags_from = "https://api2.cursor.sh/updates/api/download/stable/linux-x64/sand"
```

- helium tags its releases (`0.22.5.1`), but some of those tags are GitHub pre-releases with the same tarball attached, and tack ranks git tags by version alone. `tags_from` therefore points at GitHub's latest-release API, which skips pre-releases and drafts, and the template matches the x86_64 tarball named there.
- claude-desktop has no tags. `tags_from` points at the apt `Packages` index, which lists every `.deb` filename. tack matches the template against that text and takes the highest version.
- grok-bot's download path contains a commit. `tags_from` is Cursor's JSON release feed, whose `debUrl` holds that path. `{commit}` is a named placeholder: tack captures it from the feed and fills it into `url`.
- `unpack = "tarball"` gives the package an extracted folder (helium). `unpack = "file"` gives the file itself (the debs, which `dpkg-deb` unpacks).

In Nix, the pin is the downloaded store path and `inputs._meta.<name>.version` is the version tack picked:

```nix
inherit (inputs._meta.helium) version;
src = inputs.helium;
```

`tack look` does not download fixed pins. It reports a newer release from the tag alone, and `tack update` fetches it. While the tag stays the same, `tack update` does not download the file again, so it would not notice a vendor replacing the file behind the same URL. That shows up only when Nix fetches it: the build fails with a hash mismatch on the derivation named after the pin. If the old file is still in your store, it doesn't show up at all.

crib is deliberately not a pin: it is discontinued upstream, and `modules/pkgs/crib.nix` keeps its fixed `version` and `hash`.

### Move to the next NixOS release

Change the URL in `pins.toml`:

```toml
[inputs.nixpkgs]
url = "github:NixOS/nixpkgs/nixos-26.11"
```

Then run `tack update nixpkgs`, which relocks the pin on the new branch. Read the release notes, and switch.

### Look inside

```console
$ tack tree                 # each pin, and the inputs its own flake.lock brings, marking the ones that follow
$ tack dedup                # inputs fetched more than once across pins, with [all_follow] rules to share them
```

## Updating tack itself

tack is installed in the system config, in `modules/cli.nix`:

```nix
programs.tack = {
  enable = true;
  package = inputs.tack.packages.${pkgs.stdenv.hostPlatform.system}.tack;
};
```

`programs.tack` is the NixOS module from nixpkgs. Only its package comes from the `tack` pin, because nixpkgs ships 1.0.0 (26.05) and 1.0.1 (unstable). `tack update tack` moves to the newest release tag, and the next switch installs it. After an update, run `tack init --resolver` if tack says the resolver is out of date, and commit the new `.tack/default.nix`.

The pin builds tack against your `nixpkgs-unstable`. At the current lock that is the same derivation upstream builds and caches at `cache.manic.systems`. That cache is not enabled here, so the first switch compiles tack locally, which takes a few minutes. To use the cache, add it to `nix.settings`:

```nix
nix.settings = {
  extra-substituters = [ "https://cache.manic.systems" ];
  extra-trusted-public-keys = [ "cache.manic.systems-1:s6OZanN8Us8vRi0jVivP3qlMn0cYHBjBALKrNe5nH8s=" ];
};
```

This trusts a third-party cache to serve any store path it signs, so it is left as your choice.

## When something breaks

| symptom | cause and fix |
|---|---|
| a rebuild says a path under `.tack/` does not exist or is not tracked by Git | a new file under `.tack/` isn't tracked by git. `git add nixos/.tack` |
| `flake-parts: The flake does not have a nixpkgs input` | `self.inputs` lost the pins. See "How flake.nix reads the pins" |
| `look` shows `unverified`, or rate-limit errors | no GitHub token. See "Give tack a GitHub token" |
| `tack: no pins.toml at <folder>/.tack/pins.toml (run `tack init`)` | you ran tack outside `nixos/`. `cd` there or set `TACK_DIR`; don't run `tack init` |
| a box flake fails with `follows a non-existent input 'tools/nixpkgs'` | it predates tack. Replace `nixpkgs.follows = "tools/nixpkgs"` with `nixpkgs = tools.nixpkgs;` in its `outputs`, as in `devenv/.box/flake.nix` |
| `nix flake update` does nothing | expected: the flake has no flake inputs. Use `tack update` |
