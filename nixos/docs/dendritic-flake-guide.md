# How this flake works

This flake describes my NixOS machines. It is built with **flake-parts** and organised in the **dendritic pattern**: every `.nix` file under `modules/` is one feature, and each machine is a short list of the features it wants. Today the only machine is `x1`. Adding another one means adding a directory, not touching `flake.nix`.

The x1 handbook (`x1-nixos-handbook.md`) explains NixOS itself: the store, generations, debugging. This guide covers how the files in this directory turn into a system, and how to change them.

- [The short version (ELI5)](#the-short-version-eli5)
- [The longer version (ELI12)](#the-longer-version-eli12)
- [Words this guide uses](#words-this-guide-uses)
- [How it fits together, one piece at a time](#how-it-fits-together-one-piece-at-a-time)
- [What happens when you rebuild](#what-happens-when-you-rebuild)
- [The files](#the-files)
- [Reading the three kinds of file](#reading-the-three-kinds-of-file)
- [How to do things](#how-to-do-things)
- [Rules that bite](#rules-that-bite)
- [Why it is built this way](#why-it-is-built-this-way)
- [What this refactor changed](#what-this-refactor-changed)
- [Sources](#sources)

## The short version (ELI5)

Think of a box of LEGO sets.

Each file in `modules/` is one small bag of bricks with a label on it: "sound", "printer", "desktop", "my user". A bag never builds anything by itself. It only says "if you use me, you get these bricks".

All the bags go on one shelf. Nobody has to carry them there. A helper called import-tree walks through the `modules/` folder and puts every bag it finds on the shelf.

Each computer has a recipe card. The card for `x1` says "use the bags called sound, printer, desktop, my user, and so on, plus these few bricks that only x1 has". A new computer gets a new card that picks different bags from the same shelf.

When you run the rebuild command, it looks at the name of the computer it is running on, finds the card with that name, and builds exactly what the card asks for.

```
   modules/ folder                 the shelf                    recipe card "x1"
  +---------------+          +-------------------+         +-----------------------+
  | audio.nix     |  import  | audio             |  picks  | audio, printing,      |
  | printing.nix  | -------> | printing          | ------> | desktop, user, ...    |
  | desktop.nix   |   tree   | desktop           |         | + x1's own bricks     |
  | user.nix  ... |          | user  ...         |         +-----------+-----------+
  +---------------+          +-------------------+                     |
                                                                       v
                                                            the running x1 system
```

## The longer version (ELI12)

A NixOS system is one big set of settings, like `services.pipewire.enable = true` or `time.timeZone = "Europe/Warsaw"`. NixOS collects these settings from many small files called modules, merges them into one answer, and builds the system from that answer.

The old setup had one 400-line `configuration.nix` with every setting for x1 in it. That works for one machine. With two machines you either copy the file and let the copies drift apart, or you start splitting it into files and importing them by path, and each machine ends up with its own tangle of `imports = [ ../../common/foo.nix ]`.

This flake does three things differently.

1. **Every file is the same kind of thing.** Each `.nix` file under `modules/` is a flake-parts module. flake-parts is a small library that lets a flake be written as modules, the same way NixOS is. So one rule covers every file: it is a module, and it can add things to the flake.
2. **Nobody imports files by path.** import-tree finds every `.nix` file under `modules/` and hands all of them to flake-parts. Moving or renaming a file changes nothing, because nothing points at it by path.
3. **Features are published by name, and machines pick names.** A feature file writes its NixOS settings into `flake.modules.nixos.<name>`, for example `flake.modules.nixos.audio`. That stores the settings without applying them anywhere. The machine file for x1 then lists the names it wants: `audio`, `printing`, `desktop`, and so on.

When you run `nixos-rebuild switch`, Nix reads `flake.nix`, flake-parts evaluates all the module files together, and the result contains `nixosConfigurations.x1`. That is a complete NixOS system made from the features x1 picked. nixos-rebuild picks `x1` because that is the machine's hostname, builds it, and switches to it.

## Words this guide uses

| Word | Meaning here |
|----|----|
| flake | A directory with a `flake.nix`. It declares inputs (other flakes it uses) and outputs (things it produces, like `nixosConfigurations.x1`). `flake.lock` pins every input to an exact commit. |
| input | Another flake this one uses: `nixpkgs`, `nixpkgs-unstable`, `flake-parts`, `import-tree`, `nixos-hardware`, `disko`, `voxtype`, `vortix`. |
| NixOS module | A set of NixOS settings, optionally written as a function of `{ config, pkgs, lib, ... }`. What `configuration.nix` used to be. |
| flake-parts module | The same idea one level up. Instead of NixOS settings, it sets flake-level things: `flake.nixosConfigurations.x1`, `flake.modules.nixos.audio`, `perSystem.packages.tools`. Every file in `modules/` is one. |
| feature | A flake-parts module that publishes one NixOS module under a name, like `audio` or `desktop`. |
| host | One machine. Its directory `modules/hosts/<name>/` publishes a NixOS module called `<name>` and declares `nixosConfigurations.<name>`. |
| deferred module | The type of `flake.modules.nixos.<name>`. The settings are stored as a module and only take effect when some host imports it. Several files may define the same name. Their contents are merged into one module. |
| import-tree | A small function that returns every `.nix` file under a directory as a list of modules to import. Paths containing `/_` are skipped. |
| perSystem | The flake-parts section for things that exist once per CPU architecture, like packages. `perSystem.packages.helium` becomes the output `packages.x86_64-linux.helium`. |
| `self` | This flake's own outputs. A module reads `self.modules.nixos.audio` or `self.packages.x86_64-linux.tools` through it. |

## How it fits together, one piece at a time

**Step 1.** `flake.nix` hands the whole `modules/` directory to import-tree, and import-tree returns every file in it.

```
  flake.nix
     |
     |  inputs.import-tree ./modules
     v
  [ modules/audio.nix, modules/boot.nix, ..., modules/hosts/x1/configuration.nix,
    modules/hosts/x1/disko.nix, modules/hosts/x1/hardware.nix, modules/pkgs/helium.nix, ... ]
```

**Step 2.** flake-parts' `mkFlake` evaluates that list as one module system. Each file contributes options to one shared flake configuration, the same way NixOS modules contribute to one system configuration.

```
  flake.nix
     |
     |  inputs.import-tree ./modules
     v
  [ every modules/**/*.nix ]
     |
     |  inputs.flake-parts.lib.mkFlake { inherit inputs; }
     v
  one flake configuration  ---->  flake outputs (nixosConfigurations, packages, modules)
```

**Step 3.** Feature files put their NixOS settings on the shelf, `flake.modules.nixos`. Nothing is applied yet.

```
  modules/audio.nix     --defines-->  flake.modules.nixos.audio     = { services.pipewire... }
  modules/printing.nix  --defines-->  flake.modules.nixos.printing  = { services.printing... }
  modules/desktop.nix   --defines-->  flake.modules.nixos.desktop   = { programs.sway... }
  ...                                 (the shelf: named NixOS modules, not yet used)
```

**Step 4.** The host files for x1 do two things. All three of them add to one shelf entry named `x1`, and `configuration.nix` also declares the machine itself. The `x1` entry imports the features it wants by name.

```
  modules/hosts/x1/configuration.nix --+
  modules/hosts/x1/disko.nix --------- +--> flake.modules.nixos.x1 = { imports = [ audio printing desktop ... ];
  modules/hosts/x1/hardware.nix ------ +                               networking.hostName = "x1"; disks; kernel modules; ... }
                                       |
  modules/hosts/x1/configuration.nix   +--> flake.nixosConfigurations.x1 =
                                              nixpkgs.lib.nixosSystem { modules = [ self.modules.nixos.x1 ]; }
```

**Step 5.** nixos-rebuild (or nh) reads `nixosConfigurations.<hostname>`, evaluates it with the roughly 2000 modules that ship with nixpkgs, builds the result and activates it.

```
  flake.nixosConfigurations.x1
     |   nixos-rebuild / nh: no "#name" given, so use the hostname "x1"
     v
  config  (every option's final value: x1's own settings + every feature it imported + nixpkgs defaults)
     |
     v
  config.system.build.toplevel  --build-->  /nix/store/...-nixos-system-x1-...  --switch-->  /run/current-system
```

**Step 6.** Packages I build myself live in `perSystem`. They become flake outputs, and feature modules install them through `self.packages`. The `tools` package is also read by another flake, the agent container in `devenv/.box/flake.nix`.

```
  modules/pkgs/helium.nix  --perSystem-->  packages.x86_64-linux.helium  <--self.packages--  modules/apps.nix
  modules/tools.nix        --perSystem-->  packages.x86_64-linux.tools   <--self.packages--  modules/tools.nix (NixOS part)
                                                     ^
                                                     +-- devenv/.box/flake.nix  (input "tools", github:mgajewskik/dotfiles?dir=nixos)
```

## What happens when you rebuild

`nh os switch` (or `sudo nixos-rebuild switch --flake ~/.local/share/chezmoi/nixos`) runs these steps:

1. Nix copies the flake's git-tracked files to the store. The flake declares no inputs; `import ./.tack` fetches the inputs pinned in `.tack/pins.lock.json` (see [tack-guide.md](tack-guide.md)).
2. It calls `outputs`, which is `inputs.flake-parts.lib.mkFlake { inherit inputs; } (inputs.import-tree ./modules)`, with `inputs` built from those pins.
3. import-tree lists every `.nix` file under `modules/`, skipping any path that contains `/_`.
4. flake-parts evaluates those files as one module system. `modules/flake-parts.nix` enables `flake.modules` and sets `systems = [ "x86_64-linux" ]`.
5. The tool picks a configuration name: the `#name` you passed, otherwise the machine's hostname. On x1 that is `x1`.
6. `nixosConfigurations.x1` is evaluated. Its only module is `self.modules.nixos.x1`, which imports nixos-hardware, disko and the features in its list. NixOS merges all of it into `config`.
7. `config.system.build.toplevel` is built, mostly by downloading from cache.nixos.org, and then activated.

Errors in steps 2 to 4 point at a module file (a syntax error, a typo in an option name at the flake level). Errors in step 6 are ordinary NixOS errors, like an unknown option, and show the feature file in the trace.

## The files

```
nixos/
├── flake.nix                     outputs = flake-parts + import-tree over ./modules, inputs from .tack
├── flake.lock                    no inputs; tack pins them
├── .tack/                        pins.toml (the inputs), pins.lock.json (exact commit of each), default.nix (resolver)
├── modules/                      every .nix file here is imported automatically
│   ├── flake-parts.nix           enables flake.modules, sets systems = [ "x86_64-linux" ]
│   ├── nix.nix                   nix settings, flakes, weekly gc, allowUnfree, nh
│   ├── boot.nix                  limine, EFI, systemd initrd, no PC speaker, firmware
│   ├── networking.nix            networkd, iwd, nftables, LAN firewall rule, ARP fix, resolved
│   ├── openssh.nix               sshd, keys only, no root login
│   ├── locale.nix                Warsaw time, English and Polish locales, Polish console
│   ├── user.nix                  the mgajewskik user, zsh
│   ├── laptop.nix                bluetooth, lid and power key, tlp charge thresholds, fwupd
│   ├── audio.nix                 pipewire with ALSA, Pulse and JACK
│   ├── printing.nix              CUPS, the Brother printer, avahi
│   ├── keys.nix                  smartcard (pcscd + polkit rule), gpg agent, ssh agent, keyring
│   ├── podman.nix                rootless podman with a docker command
│   ├── agentbox.nix              host side of the agent containers (NAT, firewall, caps)
│   ├── syncthing.nix             syncthing user service
│   ├── desktop.nix               sway, uwsm, soteria, portals, theme, fonts, mako, vicinae
│   ├── cli.nix                   command-line system packages, nix-ld, envfs
│   ├── apps.nix                  GUI apps
│   ├── tools.nix                 my dotfiles tools from nixos-unstable: package + install
│   ├── pkgs/                     apps not in nixpkgs, as flake packages
│   │   ├── helium.nix
│   │   ├── claude-desktop.nix
│   │   ├── grok-bot.nix
│   │   └── crib.nix
│   └── hosts/
│       └── x1/
│           ├── configuration.nix nixosConfigurations.x1, the feature list, x1-only settings
│           ├── hardware.nix      kernel modules from nixos-generate-config
│           └── disko.nix         partitions, LUKS, btrfs subvolumes, swapfile, snapper
├── devenv/                       agent container example (reads packages.x86_64-linux.tools)
└── docs/
```

A file's path says what it is about, and nothing else depends on the path. `modules/pkgs/` and `modules/hosts/` are folders for people, not for Nix. import-tree treats them like any other folder.

## Reading the three kinds of file

### A feature file

`modules/audio.nix`:

```nix
{
  flake.modules.nixos.audio = {
    security.rtkit.enable = true;
    services.pipewire = {
      enable = true;
      alsa.enable = true;
      pulse.enable = true;
      jack.enable = true;
      ...
    };
  };
}
```

- The outer `{ ... }` is the flake-parts module.
- `flake.modules.nixos.audio = ...` publishes a NixOS module named `audio`. The `nixos` part is the module's class. flake-parts tags it so that NixOS refuses it if someone imports it into, say, a home-manager configuration.
- The inner `{ ... }` is a plain NixOS module, exactly what you would have written in `configuration.nix`.

When the NixOS part needs `pkgs` or `lib`, it becomes a function, as in `modules/printing.nix`:

```nix
{
  flake.modules.nixos.printing =
    { pkgs, ... }:
    {
      services.printing.drivers = [ pkgs.cups-brother-dcpt720dw ];
      ...
    };
}
```

When the file needs another flake, the outer module becomes a function too. `modules/cli.nix` takes `inputs`, which flake-parts passes to every module:

```nix
{ inputs, ... }:
{
  flake.modules.nixos.cli =
    { pkgs, ... }:
    {
      environment.systemPackages = with pkgs; [
        ...
        inputs.vortix.packages.${pkgs.stdenv.hostPlatform.system}.vortix
      ];
    };
}
```

There are two function layers, and each one has its own arguments. The outer one gets flake-level arguments (`inputs`, `self`, `lib`). The inner one gets NixOS arguments (`pkgs`, `config`, `lib`). The inner function can use the outer function's variables, because it is written inside it. That is how `inputs` reaches NixOS code without `specialArgs`.

### A host file

`modules/hosts/x1/configuration.nix`, shortened:

```nix
{ inputs, self, ... }:
{
  flake.nixosConfigurations.x1 = inputs.nixpkgs.lib.nixosSystem {
    modules = [ self.modules.nixos.x1 ];
  };

  flake.modules.nixos.x1 = {
    imports = [
      inputs.disko.nixosModules.disko
      inputs.nixos-hardware.nixosModules.lenovo-thinkpad-x1-extreme
    ]
    ++ (with self.modules.nixos; [
      nix
      boot
      networking
      ...
      tools
    ]);

    networking.hostName = "x1";
    boot.resumeDevice = "/dev/mapper/root";
    ...
    system.stateVersion = "26.05";
  };
}
```

- `flake.nixosConfigurations.x1` is the output nixos-rebuild looks for. The name must equal `networking.hostName`, so that rebuilding without `#x1` finds it.
- `flake.modules.nixos.x1` is the machine's own module. `hardware.nix` and `disko.nix` in the same folder also define `flake.modules.nixos.x1`. All three merge into one module, so the host is split into files by topic but still has a single name.
- `with self.modules.nixos; [ nix boot ... ]` turns names into modules. A typo here fails with `undefined variable 'netwroking'`, which names the bad entry.
- Settings that are true only for this machine stay here: the hostname, the swapfile's resume offset, the Intel GPU runtime, the commented-out NVIDIA and NFS blocks, `stateVersion`.

### A package file

`modules/pkgs/crib.nix`:

```nix
{
  perSystem =
    { pkgs, ... }:
    {
      packages.crib = pkgs.callPackage (
        { stdenvNoCC, fetchurl }:
        stdenvNoCC.mkDerivation rec {
          pname = "crib";
          version = "0.10.0";
          ...
        }
      ) { };
    };
}
```

- `perSystem` runs once per entry in `systems`, which here is only `x86_64-linux`. `pkgs` is nixpkgs for that system.
- `packages.crib` becomes the flake output `packages.x86_64-linux.crib`, so `nix build ~/.local/share/chezmoi/nixos#crib` builds it on its own.
- The function inside `callPackage ( ... )` is the same package recipe that used to live in `pkgs/crib.nix`. `callPackage` fills in `stdenvNoCC` and `fetchurl` from `pkgs` by name.
- A NixOS module installs it with `self.packages.${pkgs.stdenv.hostPlatform.system}.crib`. `apps.nix` and `tools.nix` bind that set to a local name, `packages`, and write `packages.crib`.

`modules/tools.nix` is a feature and a package in one file. Its `perSystem` builds `packages.tools`, a single `buildEnv` of my CLI tools from nixos-unstable. Its `flake.modules.nixos.tools` installs that package and crib. The list has to be a package and not just a NixOS module, because the agent container flake in `devenv/.box/` installs the same package into its containers.

## How to do things

Every recipe ends with a check. When a recipe creates a file, it includes `git add`. The section [Rules that bite](#rules-that-bite) explains why that step matters.

### Try a change without switching

```sh
cd ~/.local/share/chezmoi
git add -A nixos                                      # the flake only sees git-tracked files
nix eval ./nixos#nixosConfigurations.x1.config.services.tlp.settings   # read one value
nixos-rebuild build --flake ./nixos#x1                # build, no sudo, leaves ./result
nix store diff-closures /run/current-system ./result  # which package versions would change
```

`git add` only stages the files. It does not commit them.

### Change a setting

1. Find the file. Options are grouped by topic, so tlp is in `modules/laptop.nix` and the firewall is in `modules/networking.nix`. If you do not know where an option is set, search for it with `rg 'services.tlp' ~/.local/share/chezmoi/nixos/modules`, or ask Nix: `nix eval --json ~/.local/share/chezmoi/nixos#nixosConfigurations.x1.options.services.tlp.settings.definitionsWithLocations`.
2. Edit the value.
3. `nh os switch`.

### Install a program

1. Pick the feature it belongs to: a command-line tool goes in the list in `modules/cli.nix`, a GUI app in `modules/apps.nix`, and a sway helper in `modules/desktop.nix`.
2. Add its nixpkgs attribute name to that file's `environment.systemPackages`.
3. If it should also exist in the agent containers, add it to the `tools` list in `modules/tools.nix` instead. That list comes from nixos-unstable.
4. `nh os switch`.

### Add a feature

Say you want Steam.

1. Create `modules/gaming.nix`:

   ```nix
   {
     flake.modules.nixos.gaming = {
       programs.steam.enable = true;
     };
   }
   ```

2. Add `gaming` to the list in `modules/hosts/x1/configuration.nix`.
3. `git add nixos/modules/gaming.nix`, then `nh os switch`.

Creating the file alone changes nothing. It puts `gaming` on the shelf, and no host uses it until one lists it.

### Remove a feature from a machine

Delete its name from the host's list. The file stays on the shelf for other machines. Delete the file too once no host uses it.

### Add a new machine

Say the new machine is a desktop called `tower`.

1. Install NixOS on it the usual way, or with disko, and set its hostname to `tower`.
2. On the new machine, generate its hardware module:

   ```sh
   nixos-generate-config --show-hardware-config --no-filesystems
   ```

   `--no-filesystems` is for a machine whose mounts come from a disko file. Leave it out if you mount filesystems the classic way.
3. Create `modules/hosts/tower/hardware.nix`. Put the generated settings inside the inner braces, and keep the function header the generated file had:

   ```nix
   {
     flake.modules.nixos.tower =
       { config, lib, modulesPath, ... }:
       {
         imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];
         boot.initrd.availableKernelModules = [ ... ];
         nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
         ...
       };
   }
   ```

4. Create `modules/hosts/tower/configuration.nix`:

   ```nix
   { inputs, self, ... }:
   {
     flake.nixosConfigurations.tower = inputs.nixpkgs.lib.nixosSystem {
       modules = [ self.modules.nixos.tower ];
     };

     flake.modules.nixos.tower = {
       imports = with self.modules.nixos; [
         nix
         boot
         networking
         openssh
         locale
         user
         audio
         desktop
         cli
         apps
         tools
       ];

       networking.hostName = "tower";
       system.stateVersion = "26.05";
     };
   }
   ```

   `stateVersion` is the NixOS release you install with, and it stays that value forever after.
5. If the disks are managed by disko, add `modules/hosts/tower/disko.nix` with `flake.modules.nixos.tower = { disko.devices = ...; };`, and add `inputs.disko.nixosModules.disko` to the imports.
6. `git add nixos/modules/hosts/tower`, commit, push, and pull on the new machine.
7. On the new machine, run `nh os switch`. It picks `tower` from the hostname. From any other machine, `nixos-rebuild build --flake ~/.local/share/chezmoi/nixos#tower` checks that it evaluates and builds.

`flake.nix` does not change. That was checked while building this refactor: a throwaway `modules/hosts/demo/configuration.nix` in a copy of this flake produced `nixosConfigurations.demo` with an untouched `flake.nix`, and x1 stayed identical.

### Give one machine a different value

Features hold the values that are true wherever the feature is used. When one machine needs something else, say a different battery threshold, you have two options.

- Override it in that host's module with `lib.mkForce`, for example `services.tlp.settings.STOP_CHARGE_THRESH_BAT0 = lib.mkForce 80;`. The host module then needs `{ lib, ... }:` as its arguments.
- If most machines would override it, move the value out of the feature and into each host file.

Add your own `options` to a feature only when several hosts really vary in the same way. A plain value in the host file is easier to read than a new option.

### Package an app that is not in nixpkgs

1. Create `modules/pkgs/foo.nix` in the same shape as `modules/pkgs/helium.nix`: `perSystem = { pkgs, ... }: { packages.foo = pkgs.callPackage ( <recipe> ) { }; };`.
2. Build it alone: `git add nixos/modules/pkgs/foo.nix && nix build ~/.local/share/chezmoi/nixos#foo`.
3. Install it from a feature: add `packages.foo` to the list in `modules/apps.nix`. That file already binds `packages = self.packages.${pkgs.stdenv.hostPlatform.system}`.
4. To bump a version, change `version`, set `hash = "";`, build, and copy the correct hash from the error.

The `pkgs` that `perSystem` passes is plain nixpkgs without `allowUnfree`, unlike the `pkgs` inside NixOS modules. The four current recipes are free. An unfree recipe here would fail to evaluate, so give it its own package set the way `modules/tools.nix` does with `import inputs.nixpkgs-unstable { inherit system; config.allowUnfree = true; }`, using `inputs.nixpkgs` for the stable branch.

### Use a newer package from nixos-unstable

For one package on the host, read it from the input inside the feature that installs it:

```nix
{ inputs, ... }:
{
  flake.modules.nixos.cli =
    { pkgs, ... }:
    let
      unstable = inputs.nixpkgs-unstable.legacyPackages.${pkgs.stdenv.hostPlatform.system};
    in
    {
      environment.systemPackages = [ unstable.opentofu ];
    };
}
```

`legacyPackages` does not allow unfree packages. For an unfree one, build the set the way `modules/tools.nix` does, with `import inputs.nixpkgs-unstable { inherit system; config.allowUnfree = true; }`. For a tool that the agent containers need too, add it to the `tools` list.

### Update inputs

```sh
cd ~/.local/share/chezmoi/nixos
tack look                # what an update would bring
tack update              # everything
tack update nixpkgs      # one input
```

[tack-guide.md](tack-guide.md) covers holding inputs back, adding them and rolling back.

After a push, the agent container flake picks up the new tools with `nix flake update tools` in its `.box/`.

### Look around

```sh
nix flake show ~/.local/share/chezmoi/nixos              # outputs: nixosConfigurations, packages, modules
nix repl
nix-repl> :lf /home/mgajewskik/.local/share/chezmoi/nixos
nix-repl> builtins.attrNames modules.nixos               # every feature on the shelf
nix-repl> nixosConfigurations.x1.config.networking.hostName
```

`nix flake check` prints `warning: unknown flake output 'modules'`. That warning is expected. `modules` is the flake-parts shelf, and Nix has no built-in name for it.

## Rules that bite

**New files must be tracked by git.** The flake lives in a git repo, so Nix only copies tracked files. A new module that you have not `git add`ed is invisible to Nix. If no host lists it, nothing fails and the feature is simply absent. If a host lists it, evaluation fails with `undefined variable 'gaming'`. Staging is enough; you do not have to commit first.

**Every `.nix` file under `modules/` must be a flake-parts module.** import-tree imports all of them. A plain NixOS module placed there fails with an error like `The option 'services' does not exist`, because flake-parts has no such option. A bare package recipe fails because nothing passes it arguments such as `stdenvNoCC`. Wrap it in `flake.modules.nixos.<name> = ...;` or `perSystem.packages.<name> = ...;`. If you really need a helper file that is not a module, start its name with `_` (for example `modules/hosts/x1/_notes.nix`). import-tree skips any path containing `/_`.

**Each `nixosConfigurations.<name>` is defined once.** It is a single value, not a mergeable module. The shelf entries `flake.modules.nixos.<name>` do merge, so several files may define the same feature or host.

**Order inside merged lists can change.** When two features add to the same list, like `environment.systemPackages` from `cli.nix` and `apps.nix`, NixOS concatenates the parts. For sibling imports, the order comes out reversed: with `cli` listed before `apps`, the apps come first in the final list. This only matters when two packages ship the same file, for example two `bin/vim`. NixOS then keeps the first one, and the build only prints `colliding subpath (ignored)` in its log. Don't install one program from two features or two nixpkgs branches.

**No `specialArgs`.** Code that needs another flake takes `inputs` in the outer module function and uses it from inside. That keeps every dependency visible in the file that uses it. `specialArgs` would make `inputs` appear inside NixOS modules with no visible source.

**A feature imports nothing conditionally.** `imports` cannot depend on `config`, because NixOS needs the module list before it can compute any config. To turn something off on one host, leave its name out of that host's list.

## Why it is built this way

The old layout had `flake.nix` call `nixosSystem` with three modules and `specialArgs = { inherit inputs pkgsUnstable; }`, and one `configuration.nix` held almost everything. It had three problems once more machines come into play:

- **Sharing meant paths.** A second host would `imports = [ ../x1/configuration.nix ]` and then undo the parts it does not want, or the shared parts would move into `common/*.nix` files that each host imports by relative path. Every move breaks those paths.
- **Arguments came from nowhere.** `inputs` and `pkgsUnstable` appeared inside `configuration.nix` through `specialArgs`. To learn where they came from you had to read `flake.nix`.
- **Two kinds of file.** Some `.nix` files were NixOS modules, some were package recipes for `callPackage`, and `flake.nix` was a third shape. Each kind is read differently.

The dendritic pattern, named by Shahar "Dawn" Or (mightyiam), answers all three with one rule: every file is a module of the top-level configuration, here flake-parts, and it implements one feature across whatever configurations need it. In this flake:

- **Sharing is by name.** Hosts list `audio`, not `../../audio.nix`. Files can move freely.
- **Every file reads the same way.** Each one is a flake-parts module that may publish NixOS modules, packages, or a host.
- **Arguments are visible.** A file that needs `inputs` or `self` says so in its first line.
- **A new host is a new folder.** Nothing central needs editing, because import-tree finds the folder.

The pattern has costs.

- Finding which file sets an option takes a search instead of scrolling one file. `rg` and `definitionsWithLocations` (above) make that quick.
- There are two module layers, flake-parts and NixOS, and each has its own arguments. The nested function in each feature file is the price of not using `specialArgs`.
- `flake.modules` is a flake-parts convention, not a standard flake output, hence the `nix flake check` warning.
- A file you forgot to `git add` is invisible to Nix, as described above.

Some choices here differ from other dendritic configs:

- **Shelf name.** This flake uses `flake.modules.nixos.<name>`, the flake-parts option that Doc-Steve's guide also uses. vimjoyer's own config uses `flake.nixosModules.<name>`, which works the same but does not tag the module's class. The class tag starts to pay off when home-manager or nix-darwin configurations join, which is likely with more machines.
- **No helper function.** There is no `mkNixos` helper for declaring hosts. With one host, three lines of `nixosSystem` are clearer than a function. Add one when hosts start repeating the same boilerplate.
- **Hardware file.** The generated hardware module is wrapped as `hardware.nix`, as vimjoyer's and Doc-Steve's configs do. It is no longer byte-for-byte what `nixos-generate-config` printed, so regenerating means pasting the new settings in by hand.

## What this refactor changed

| Before | After |
|----|----|
| `flake.nix` with a hand-written `outputs` and `specialArgs` | `flake.nix` = flake-parts + import-tree; `modules/flake-parts.nix` |
| `hosts/x1/configuration.nix` (394 lines) | 16 feature files + `modules/hosts/x1/configuration.nix` (the feature list and x1-only settings) |
| `hosts/x1/hardware-configuration.nix` | `modules/hosts/x1/hardware.nix` |
| `hosts/x1/disko.nix` | `modules/hosts/x1/disko.nix` (snapper moved in, since it depends on the `@home_snapshots` subvolume) |
| `hosts/x1/agentbox.nix` | `modules/agentbox.nix` |
| `pkgs/tools.nix` + `packages.x86_64-linux.tools` in `flake.nix` | `modules/tools.nix` (package and install in one file) |
| `pkgs/{helium,claude-desktop,grok-bot,crib}.nix` | `modules/pkgs/*.nix`, now also flake outputs |
| inputs | added `flake-parts` (its `nixpkgs-lib` follows `nixpkgs`) and `import-tree`; every existing pin unchanged |

Every comment that explained a workaround moved with its code, unchanged.

How it was checked, without building or switching:

- With the feature imports in one particular order, the new flake evaluates to the exact derivation of the running system, `/run/current-system`. That proves every setting, file and package carried over.
- The committed order is the readable one shown in the host file. It changes the order of two merged lists, `environment.systemPackages` and `systemd.packages`, so the system's store path differs from the running one. A script compared every file the two package lists link into `/run/current-system/sw`, about 1.08 million of them, and found no file whose provider changes. A reversed list, by contrast, changes 11 files, which shows the check can catch a difference. Switching to this flake therefore creates a new generation with the same contents.
- `packages.x86_64-linux.tools` has the same derivation as before, and the agent container flake evaluates to the same system against the old and the new flake.
- A second host added as one new folder evaluated without editing `flake.nix`.

## Sources

- flake-parts: <https://flake.parts/>, and the `flake.modules` option in its `extras/modules.nix`
- import-tree: <https://github.com/vic/import-tree> (the `/_` rule is in its `default.nix`)
- The dendritic pattern: <https://github.com/mightyiam/dendritic>
- vimjoyer's template: <https://github.com/vimjoyer/flake-parts-wrapped-template>, and his config <https://github.com/vimjoyer/nixconf>
- vimjoyer's videos: <https://www.youtube.com/watch?v=kvprcW6QMIE>, <https://www.youtube.com/watch?v=-TRbzkw6Hjs> (their transcripts could not be fetched for this guide; the template and his config were used instead)
- Doc-Steve's dendritic guide: <https://github.com/Doc-Steve/dendritic-design-with-flake-parts>
