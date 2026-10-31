*ThinkPad X1 Extreme Gen 1 · NixOS 26.05 · flake at ~/.local/share/chezmoi/nixos*

# x1 NixOS Handbook

How the system you just installed works, how to run it day to day, how to fix it when it breaks, and how Nix fits next to your chezmoi, mise and devcontainer setup. Every example uses your own flake.

- **NixOS:** 26.05 "Yarara"
- **nixpkgs pin:** nixos-26.05 @ 6f06d204
- **Nix on the x1:** 2.34.9
- **Flake:** ~/.local/share/chezmoi/nixos (chezmoi source dir, not deployed)
- **Apply:** sudo nixos-rebuild switch --flake ~/.local/share/chezmoi/nixos#x1
- **mise on the x1:** 2026.10.24, all_compile = false

> **How this page was built.** The facts come from your flake files, the exact nixpkgs revision your `flake.lock` pins, the Nix 2.34 manual and the upstream docs linked in chapter 10. The research ran on the Arch laptop, not on the x1, so anything that depends on the live x1 state is marked *check on the x1* with the command that checks it.
>
> The flake lives in the chezmoi source dir, `~/.local/share/chezmoi/nixos/`, on every machine. `.chezmoiignore` keeps chezmoi from deploying it; `nixos-rebuild` reads it in place. On the x1, the `nrs` zsh alias runs `sudo nixos-rebuild switch` against it.

### Chapters

- 01 What NixOS is
- 02 From flake.nix to a running system
- 03 Your files, explained
- 04 Where things live
- 05 The Nix language
- 06 The module system
- 07 Packages and derivations
- 08 Daily operations
- 09 Debugging
- 10 Docs in the terminal, and sources
- 11 Development environments
- 12 Learning path
- 13 Noticed in your config
- 14 Cheat sheet

### The five commands you will use most

``` sh
# apply a change to ~/.local/share/chezmoi/nixos and make it the boot default
$ sudo nixos-rebuild switch --flake ~/.local/share/chezmoi/nixos#x1
# go back to the previous generation (until reboot; chapter 8 makes it stick)
$ sudo nixos-rebuild switch --rollback
# update all pinned inputs (nixpkgs, nixos-hardware, disko), then switch
$ nix flake update --flake ~/.local/share/chezmoi/nixos
# run a tool once without installing it
$ nix shell nixpkgs#ripgrep
# look up any option, offline
$ man configuration.nix
```

## 01 · What NixOS is

NixOS is a Linux distribution where the whole operating system is the output of a build. You describe the system in Nix files. Nix builds every package, config file and systemd unit into a read-only directory called the Nix store, and then points the running system at the result. Changing the system means changing the files and building again. Nothing is edited in place.

On the x1 the description is the flake in `~/.local/share/chezmoi/nixos`. Every `nixos-rebuild switch` produces one new, complete system, called a generation, and keeps the old ones so you can boot or switch back to any of them.

### How Arch and NixOS install a package

On Arch, pacman unpacks a package into shared directories. Every package writes into the same `/usr`, so there is one version of each file and an upgrade overwrites the old one.

**Arch: one shared tree**

```
  pacman -S ripgrep
        |
        v
  /usr/bin/rg          <- overwritten on every upgrade
  /usr/lib/libpcre2.so <- shared by every program that links it
  /etc/...             <- edited by you and by packages
```

State accumulates in one place. Undoing an upgrade means a downgrade or a filesystem snapshot.

Nix puts every package in its own directory under `/nix/store`. The directory name starts with a hash of everything used to build it: sources, dependencies, build script, flags. Two different builds of ripgrep get two different directories, so they never collide.

**NixOS, step 1: the store**

```
  /nix/store/
    a1b2...-ripgrep-15.1.0/bin/rg
    c3d4...-pcre2-10.44/lib/libpcre2-8.so
    e5f6...-ripgrep-15.2.0/bin/rg       <- another version, side by side
    ...                                    read-only, never modified
```

A store path is immutable. A new version is a new path. The binary records the exact store paths of its libraries, so there is no shared /usr/lib.

The system itself is also a store path. NixOS builds one directory, the toplevel, that links together the kernel, the initrd, the generated `/etc`, all systemd units and a merged `bin/` of every installed package. That directory is a generation.

**NixOS, step 2: a generation is one store path**

```
  /nix/store/
    a1b2...-ripgrep-15.1.0/
    c3d4...-pcre2-10.44/
    9z8y...-nixos-system-x1-26.05.20261029.6f06d20/   <- generation 12
        kernel  initrd  etc/  sw/bin/rg -> a1b2...  systemd/  activate
```

Everything the running system needs is reachable from that one directory.

Generations are numbered symlinks. Switching means pointing `/run/current-system` at a different generation and running its activation script, which re-links `/etc`, reloads systemd and restarts changed services. The bootloader gets one menu entry per generation.

**NixOS, step 3: generations and switching**

```
  /nix/var/nix/profiles/
    system-11-link -> /nix/store/7k...-nixos-system-x1-...   (yesterday)
    system-12-link -> /nix/store/9z...-nixos-system-x1-...   (today)
    system         -> system-12-link

  /run/current-system -> generation 12   (what is running now)
  /run/booted-system  -> generation 12   (what the kernel booted)

  Limine menu:  Generation 12 (default)
                Generation 11
                ...up to 10 entries (maxGenerations = 10)

  rollback = point "system" back at 11 and activate it
             (Limine still lists 12 first and boots it by default)
```

An old generation still exists until garbage collection deletes it. Your config runs that collection weekly and keeps 14 days.

### The differences that matter coming from Arch

| On Arch you… | On this NixOS you… | Why |
|----|----|----|
| `pacman -S foo` | add `foo` to `environment.systemPackages`, rebuild. Or `nix shell nixpkgs#foo` for a one-off. | The package list is part of the build. |
| `pacman -Syu` | `nix flake update --flake ~/.local/share/chezmoi/nixos`, then `nixos-rebuild switch`. Two steps. | The update only changes `flake.lock`. Nothing on the system changes until you switch. |
| edit `/etc/foo.conf` | set the module option (`services.foo.settings`) or `environment.etc."foo.conf".text` | Most of `/etc` is symlinks into the read-only store. A hand edit fails or is replaced at the next switch. |
| `systemctl enable foo` | `services.foo.enable = true;` | `/etc/systemd/system` is generated. `systemctl enable` of a system unit fails. User units, including those from `systemd.packages`, can still be enabled by hand. |
| roll back with snap-pac snapshots | pick an older generation in the Limine menu, or `--rollback` | Old generations are complete systems. Root is not snapshotted, only `/home`. |
| run any downloaded binary | works for most through nix-ld and envfs, which this config enables | Generic Linux binaries expect `/lib64/ld-linux-x86-64.so.2` and `/usr/lib`, which NixOS does not have. Chapter 4 explains the workaround. |
| AUR | nixpkgs has over 120,000 packages. For the rest, write a small package file like `pkgs/helium.nix`. | A package is a Nix function. Chapter 7 walks through yours. |
| `/usr/bin/foo` | `/run/current-system/sw/bin/foo` | Binaries are symlinks into the store. `readlink -f $(which foo)` shows the real path. |
| edit `/etc/fstab` | edit `hosts/x1/disko.nix` or `fileSystems.*` | disko generates the `fileSystems` entries from the disk layout. |
| a broken update can leave a half-upgraded system | a broken config fails at evaluation, before anything changes | Nix evaluates and builds the whole new system first. Activation happens only after a successful build. |
| disk space freed by removing packages | space is freed only by garbage collection | Old generations keep their packages alive. `nix-collect-garbage` deletes them. |
| rolling release | stable branch `nixos-26.05`, with security and bug fixes until shortly after the next release | A major upgrade is a one-word edit in `flake.nix`. Never change `system.stateVersion`. |

> **Rollback does not cover data.** A generation contains software and generated config. It does not contain `/home`, `/var/lib` (Bluetooth pairings, CUPS printers, iwd Wi-Fi networks, service databases) or `/etc/shadow`. Snapper covers `/home`. Nothing covers `/var/lib` unless you back it up.

## 02 · From flake.nix to a running system

`sudo nixos-rebuild switch --flake ~/.local/share/chezmoi/nixos#x1` does four things in order: it reads the flake and its lock, evaluates the configuration, builds or downloads everything, and activates the result. Seeing those as separate stages tells you where an error came from.

**Stage 1: inputs**

```
  ~/.local/share/chezmoi/nixos/flake.nix  --- asks for --->  nixpkgs        github:NixOS/nixpkgs/nixos-26.05
                                      nixos-hardware github:NixOS/nixos-hardware
                                      disko          github:nix-community/disko/latest
  ~/.local/share/chezmoi/nixos/flake.lock --- pins each to an exact git commit + content hash
                                      nixpkgs        6f06d204...
                                      nixos-hardware 04c6b94f...
                                      disko          de570873...
```

The lock decides which nixpkgs you get. Until you run `nix flake update`, every rebuild uses the same versions, on any machine.

**Stage 2: evaluation**

```
  inputs ──> nixpkgs.lib.nixosSystem { modules = [
               disko.nixosModules.disko
               nixos-hardware.nixosModules.lenovo-thinkpad-x1-extreme
               ./hosts/x1/configuration.nix   (imports hardware-configuration.nix, disko.nix)
             ] }
                    │  merged with ~2000 NixOS modules from nixpkgs
                    v
             config   (one big attribute set: every option's final value)
                    │
                    v
             config.system.build.toplevel   (a derivation: the recipe for the whole system)
```

Evaluation only computes. Typos, unknown options, conflicting values and missing files fail here, and nothing on the system has changed yet.

**Stage 3: build**

```
  toplevel derivation
     │  needs thousands of store paths
     ├── already in /nix/store?           -> skip
     ├── on cache.nixos.org (same hash)?  -> download        (almost everything)
     └── neither                          -> build locally   (your pkgs/*.nix wrappers,
                                                               generated config files)
     v
  /nix/store/...-nixos-system-x1-26.05.20261029.6f06d20
```

Because the store path hash comes from the inputs, the binary cache can say "I already built exactly this". Build errors such as a hash mismatch or a failed compile happen here. The running system is still untouched.

**Stage 4: activation**

```
  new toplevel
     ├── profile:   /nix/var/nix/profiles/system-13-link -> new toplevel   (switch, boot)
     ├── bootloader: limine-install copies kernel+initrd to /boot/limine,
     │              rewrites /boot/limine/limine.conf                       (switch, boot)
     └── activate:  /run/current-system -> new toplevel                     (switch, test)
                    /etc/static -> new etc, users and groups updated,
                    systemd reloaded, changed units restarted
```

`switch` does all three. `boot` skips activation until the next reboot. `test` activates without changing the boot default, so a reboot returns to the old one.

### Where each kind of error comes from

| You see | Stage | System changed? |
|----|----|----|
| `` error: The option `foo' does not exist ``, `undefined variable`, `syntax error`, `infinite recursion` | 2 evaluation | No |
| `path '…/new.nix' does not exist` right after creating a file | 1 or 2: the flake only sees git-tracked files | No |
| `hash mismatch in fixed-output derivation`, `builder for '…drv' failed` | 3 build | No |
| `warning: the following units failed: foo.service` | 4 activation | Yes, the new generation is active. Fix forward or roll back. |
| black screen or no boot after a kernel change | after reboot | Yes. Pick the previous generation in Limine. |

> **Build before you switch.** `nixos-rebuild build --flake ~/.local/share/chezmoi/nixos#x1` runs stages 1 to 3 as your user and leaves a `./result` link. `nix store diff-closures /run/current-system ./result` then lists every package version that would change.

## 03 · Your files, explained

The flake has four files that describe the machine and three that package vendor apps. Each one is a Nix expression. Chapter 5 covers the syntax. Here the point is what each block does on the running x1.

```
~/.local/share/chezmoi/nixos/
├── flake.nix                       inputs and the one output: nixosConfigurations.x1
├── flake.lock                      exact commits of nixpkgs, nixos-hardware, disko
├── hosts/x1/
│   ├── configuration.nix           the system: boot, network, users, services, desktop, packages
│   ├── hardware-configuration.nix  kernel modules found by nixos-generate-config
│   └── disko.nix                   partitions, LUKS, btrfs subvolumes, swapfile
├── pkgs/
│   ├── helium.nix                  Helium browser from its release tarball
│   ├── claude-desktop.nix          Claude Desktop from its .deb
│   └── grok-bot.nix                Grok Bot from its .deb
└── docs/
    └── x1-nixos-handbook.md        this handbook
```

### flake.nix

*flake.nix*

``` nix
{
  description = "NixOS machines";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixos-hardware = {
      url = "github:NixOS/nixos-hardware";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    disko = {
      url = "github:nix-community/disko/latest";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, nixos-hardware, disko, ... }: {
    nixosConfigurations.x1 = nixpkgs.lib.nixosSystem {
      modules = [
        disko.nixosModules.disko
        nixos-hardware.nixosModules.lenovo-thinkpad-x1-extreme
        ./hosts/x1/configuration.nix
      ];
    };
  };
}
```

- `inputs` names three other flakes. `nixos-26.05` is the stable branch. The lock freezes the exact commit.
- `inputs.nixpkgs.follows = "nixpkgs"` tells nixos-hardware and disko to use your nixpkgs instead of locking their own. Without it you would download and evaluate a second nixpkgs.
- `outputs` is a function. Nix calls it with the fetched inputs and gets back an attribute set. The only output is `nixosConfigurations.x1`, which is what `--flake ~/.local/share/chezmoi/nixos#x1` refers to. If you leave out `#x1`, nixos-rebuild uses the hostname, which is also `x1`.
- `nixosSystem` evaluates your three modules together with all NixOS modules. There is no `system = "x86_64-linux"` here. The platform comes from `nixpkgs.hostPlatform` in `hardware-configuration.nix`.
- A side effect of `nixosSystem`: the x1's flake registry and `NIX_PATH` point `nixpkgs` at this exact locked nixpkgs. So `nix shell nixpkgs#foo` on the x1 uses the same revision as the system, mostly from the binary cache, with no extra download of nixpkgs.

### hardware-configuration.nix

Normally written by `nixos-generate-config`. Yours was generated with `--no-filesystems`, because disko provides the mounts.

| Line | What it does |
|----|----|
| `imports = [ (modulesPath + "/installer/scan/not-detected.nix") ]` | Enables redistributable firmware by default (`mkDefault true`). |
| `boot.initrd.availableKernelModules = [ "xhci_pci" "thunderbolt" "nvme" "usb_storage" "sd_mod" "rtsx_pci_sdmmc" ]` | Modules copied into the initrd so udev can load them before the root disk is open: NVMe for the disk, USB for a keyboard at the LUKS prompt, the SD card reader. |
| `boot.kernelModules = [ "kvm-intel" ]` | Loaded after boot. Enables KVM for QEMU, including Claude Desktop's Cowork VM. |
| `nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux"` | Which architecture to build for. |
| `hardware.cpu.intel.updateMicrocode = …` | Loads Intel microcode updates when firmware is enabled. |

### disko.nix

disko reads this file twice. During the install, the disko command partitioned and formatted the disk from it. On every rebuild, the disko module turns the same description into `fileSystems`, `boot.initrd.luks.devices` and `swapDevices`. Editing it later changes mount options. It never reformats a running system.

```
/dev/nvme0n1 (GPT)
├── ESP   1 GiB  vfat     -> /boot        partlabel disk-main-ESP
└── root  rest   LUKS2 "root" (allowDiscards: TRIM passes through)
                 partlabel disk-main-root, opened as /dev/mapper/root
    └── btrfs
        ├── @                -> /                 compress=zstd:1,noatime
        ├── @home            -> /home             compress=zstd:1,noatime
        ├── @nix             -> /nix              compress=zstd:1,noatime
        ├── @home_snapshots  -> /home/.snapshots  (snapper)
        └── @swap            -> /swap             /swap/swapfile 35G, no compression
```

The 35G swapfile is bigger than the 32 GB of RAM, so hibernation would fit, but hibernation is not configured. It would need `boot.resumeDevice` and a `resume_offset` kernel parameter.

### configuration.nix, block by block

The file starts with `{ pkgs, ... }:`. That makes it a function the module system calls, passing `pkgs`, the package set. Everything inside is option assignments.

| Block | What it does on the x1 |
|----|----|
| `imports` | Pulls in `hardware-configuration.nix` and `disko.nix` as more modules. Paths are relative to this file. |
| `nix.settings` | Writes `/etc/nix/nix.conf`. Turns on the `nix` command and flakes. `auto-optimise-store` hard-links identical files when new store paths are written. |
| `nix.gc` | Creates `nix-gc.timer`, weekly: `nix-collect-garbage --delete-older-than 14d`. Deletes system generations older than 14 days, except the current one, then unreferenced store paths. |
| `nixpkgs.config.allowUnfree` | Lets unfree packages evaluate: Chrome, Obsidian, Insync and the Intel OpenCL runtime. |
| `boot.loader.limine` | Limine as bootloader. On every `switch` or `boot`, the installer copies each generation's kernel and initrd to `/boot/limine/` and rewrites `limine.conf`. Keeps the newest 10 entries. The menu waits 5 seconds. The kernel command line editor is off. |
| `boot.initrd.systemd.enable` | systemd runs the initrd and asks for the LUKS passphrase. In 26.05 this is already the default. |
| `hardware.intelgpu.computeRuntime = "legacy"` | This option comes from nixos-hardware, not nixpkgs. It picks the OpenCL runtime for older Intel GPUs. Without the nixos-hardware module the build would fail with "option does not exist". |
| NVIDIA block (commented) | The proprietary driver with PRIME offload, off. The GTX 1050 Ti runs on nouveau. |
| `networking.*`, `systemd.network.*` | systemd-networkd instead of NetworkManager, iwd for Wi-Fi, nftables firewall. Wired gets route metric 100 and Wi-Fi 600, so wired wins. `wait-online.anyInterface` means boot does not wait for both. These become `/etc/systemd/network/20-wired.network` and `25-wireless.network`. |
| `networking.firewall.extraInputRules` | Appends `ip saddr 192.168.0.0/16 accept` to the `input-allow` chain of the `nixos-fw` nftables table. Every port is open to the 192.168.x.x LAN. SSH (22) and mDNS (5353) are open to everyone by their modules' defaults. |
| `services.resolved` | systemd-resolved for DNS. Its own mDNS is off because Avahi handles `.local`. |
| `time`, `i18n`, `console` | Warsaw time, English locale plus Polish, Polish console keymap. `earlySetup` applies the keymap and font in the initrd, so the LUKS prompt already uses the Polish layout. |
| `users.users.mgajewskik` | UID 1000 or above, `wheel` (sudo), zsh. No password or SSH key in the flake: the password lives only in `/etc/shadow`, and the key in `~/.ssh/authorized_keys`. |
| `services.logind` | Writes `/etc/systemd/logind.conf`: lid suspends on battery and is ignored on AC or docked. The power key is ignored; a long press powers off. |
| `services.tlp` | Battery charge thresholds 55/60%, no USB autosuspend for Bluetooth. Chapter 6 traces this option to `/etc/tlp.conf`. |
| `services.snapper.configs.home` | Manual snapshots of `/home` only, at most 10. |
| `services.openssh` | sshd with keys only and no root login. The firewall port opens automatically. |
| pipewire, blueman, printing, avahi | Audio, Bluetooth applet, CUPS with the Brother DCP-T720DW driver, and mDNS so the printer is found. |
| fwupd, udisks2, gvfs, pcscd, gnome-keyring | Firmware updates, removable media, smartcards, the secret store. `gcr-ssh-agent` is off because `programs.ssh.startAgent` runs the SSH agent. |
| `services.envfs`, `programs.nix-ld` | Make generic Linux binaries and `#!/bin/bash` scripts work. Chapter 4 explains both. |
| `virtualisation.podman` | Rootless Podman. `dockerCompat` installs a `docker` command that runs Podman. |
| `fileSystems."/mnt/backups"` | NFS share from 192.168.1.123, mounted on first access (`x-systemd.automount`). Boot continues without it (`nofail`). |
| `programs.sway`, `uwsm`, `soteria` | Sway with its helper tools, the UWSM session manager, and a polkit agent. Also enables graphics, XWayland, polkit and the xdg portals. There is no display manager: you log in on tty1 and `.zprofile` starts UWSM. |
| `systemd.packages`, `systemd.user.services` | Installs the user units that ship with Syncthing and mako, and starts them through `wantedBy`: Syncthing at login, mako with the graphical session. vicinae's unit is written out in full because its package puts the file where `systemd.packages` does not look. The rest of your desktop units come from chezmoi in `~/.config/systemd/user`. |
| `environment.systemPackages` | Every installed program, merged into `/run/current-system/sw`. Includes three local packages (`callPackage ../../pkgs/helium.nix { }`) and voxtype rebuilt with ONNX support. |
| `system.stateVersion = "26.05"` | Records which defaults the first install had, for stateful services. It is not the NixOS version. Never change it when upgrading. |

### The three packages in pkgs/

All three take a vendor binary (a tarball or a .deb) and wrap it with `buildFHSEnv`. That wrapper starts the app inside a bubblewrap sandbox with a normal `/usr` and `/lib` built from nixpkgs, so the prebuilt Electron or Chromium binary finds its libraries. Chapter 7 walks through `pkgs/helium.nix` line by line.

## 04 · Where things live

### The filesystem map

```
/
├── nix/                     @nix subvolume
│   ├── store/               every package and generation, read-only
│   └── var/nix/
│       ├── profiles/        system, system-N-link, per-user profiles
│       ├── gcroots/         what garbage collection must keep
│       └── db/              the store database (never touch)
├── run/
│   ├── current-system  ->   the active generation
│   ├── booted-system   ->   the generation the kernel was booted from
│   └── wrappers/bin/        setuid wrappers: sudo, ping, fusermount
├── etc/                     mostly symlinks into /etc/static (the store)
│   ├── static          ->   /nix/store/...-etc/etc
│   ├── passwd shadow group  real files, generated from users.* plus passwd
│   ├── machine-id, ssh/ssh_host_*_key   real files, made on first boot
│   └── NIXOS                marker file
├── var/lib/                 service state, NOT managed by the flake
├── home/                    @home, snapshotted by snapper into /home/.snapshots
├── boot/                    vfat ESP: limine/limine.conf, limine/kernels/
├── swap/swapfile            35G
├── bin/sh, usr/bin/env      the only fixed FHS paths, here provided by envfs
└── lib64/ld-linux-x86-64.so.2 -> nix-ld (stock NixOS puts an error stub here)
```

There is no `/etc/nixos`. That is where a classic install keeps `configuration.nix`. Your flake lives in `~/.local/share/chezmoi/nixos`, and you always pass `--flake ~/.local/share/chezmoi/nixos#x1`.

### How a command resolves

Your `PATH` has no `/usr/bin`. NixOS merges every installed package into one symlink tree and puts its `bin` on the path.

```
  $ rg
    │  PATH = ~/.local/bin : ... : /run/wrappers/bin : /run/current-system/sw/bin
    v
  /run/current-system/sw/bin/rg
    │  /run/current-system -> /nix/store/9z...-nixos-system-x1-.../
    │  sw -> /nix/store/...-system-path       (environment.systemPackages merged)
    v
  /nix/store/a1b2...-ripgrep-15.1.0/bin/rg   (the real file)
```

`readlink -f "$(command -v rg)"` prints the last line. mise tools come earlier on PATH from `~/.local/share/mise`, so a mise `rg` wins over the system one. `which -a rg` shows all of them.

### How a file in /etc resolves

```
  /etc/tlp.conf
    -> /etc/static/tlp.conf
    -> /nix/store/...-etc/etc/tlp.conf
    -> /nix/store/...-etc-tlp.conf          (text generated from services.tlp.settings)
```

A switch only re-points `/etc/static`. Files with an explicit mode are copied instead of linked, for programs that reject symlinks. Their content is still in the world-readable store. `ls -l /etc | grep -v static` shows the real, mutable files.

### Why generic binaries work here: nix-ld and envfs

A binary downloaded from GitHub (a mise tool, a Mason language server, a node prebuilt) asks the kernel for the loader `/lib64/ld-linux-x86-64.so.2` and looks for libraries in `/usr/lib`. Stock NixOS has no `/usr/lib`, and its `/lib64` loader is a stub that only prints *Could not start dynamically linked executable*.

```
  ~/.local/share/mise/installs/node/26.12.0/bin/node
     │ ELF interpreter: /lib64/ld-linux-x86-64.so.2
     v
  /lib64/ld-linux-x86-64.so.2 -> nix-ld            (programs.nix-ld.enable)
     │ reads NIX_LD              = real glibc loader
     │ reads NIX_LD_LIBRARY_PATH = /run/current-system/sw/share/nix-ld/lib
     v                             zlib zstd libstdc++ curl openssl attr libssh
  node runs                        bzip2 libxml2 acl libsodium util-linux xz systemd
```

The default library list is small. When a binary needs more (libGL, X11, GTK, ALSA), add packages to `programs.nix-ld.libraries`, and switch. The two variables point at a fixed path under `/run/current-system`, so a switch is enough. Only the first enable of nix-ld needs a new login.

envfs is a FUSE filesystem on `/usr/bin` and `/bin`. When something opens `/usr/bin/python3` or `/bin/bash`, envfs answers with whatever `python3` or `bash` is on the calling process's PATH. That is why `#!/bin/bash` scripts and Makefiles that hard-code `/usr/bin/git` keep working. envfs provides executables only. `/usr/lib` and `/usr/share` stay absent.

The third mechanism is `buildFHSEnv`, used by your three apps in `pkgs/`. It gives one app a private, complete `/usr` inside a sandbox. nix-ld is global and light, and you list the libraries yourself. An FHS env is per app and complete.

### State NixOS does not manage

| Path | Contents | Covered by |
|----|----|----|
| `/home` | your files, dotfiles, mise installs, Podman containers and images (`~/.local/share/containers`), Syncthing data | snapper (manual), chezmoi for dotfiles |
| `/var/lib/bluetooth`, `/var/lib/cups`, `/var/lib/iwd` | pairings, printers added by hand, saved Wi-Fi networks | nothing; back up if it matters |
| `/var/lib/nixos` | UID and GID allocations | never delete it |
| `/etc/shadow` | your password | not in the flake; set by `passwd` |
| `/etc/ssh/ssh_host_*` | the x1's SSH identity | generated on first start |
| `/var/log/journal` | logs | `journalctl --vacuum-size=…` |

## 05 · The Nix language

Nix is a small, pure, lazy, functional language. A Nix file is one expression. There are no statements, loops or variables you can reassign. You write values, mostly attribute sets (key-value maps), and functions that return them. The whole NixOS configuration is one large attribute set computed from your files.

Open a REPL and type along. Every result below was checked with the Nix evaluator.

``` sh
$ nix repl
nix-repl> 1 + 2
3
nix-repl> :l <nixpkgs>        # puts lib and every package in scope
nix-repl> :q
```

Offline alternative that needs no daemon: `nix-instantiate --eval --strict -E '{ a = 1; }.a'`.

### Values

| Kind | Example | Result and notes |
|----|----|----|
| number, bool, null | `1 + 2`, `true`, `null` | `3` |
| string | `"a${toString 1}b"` | `"a1b"`. Only strings, paths and packages interpolate. `"${5}"` is an error: use `toString 5`. |
| multi-line string | `''` … `''` | Common indentation is stripped. Used for scripts and config text. A literal `${` is written `''${`. |
| path | `./foo.nix` | Not a string. Resolved relative to the file it is written in. Interpolating it (`"${./foo.nix}"`) copies the file into the store. |
| list | `[ 1 2 "x" ]` | Separated by spaces. No commas. |
| attribute set | `{ a = 1; b.c = 2; }` | `{ a = 1; b = { c = 2; }; }`. A `;` after every binding. Dotted names nest. |
| quoted name | `{ "20-wired" = 1; }` | Needed when the name has `/`, `.` or starts with a digit. Your config uses `fileSystems."/mnt/backups"` and `systemd.network.networks."20-wired"`. |

### Naming things: let, inherit, with, rec

``` nix
let x = 1; y = x + 1; in y                    # 2      let bindings see each other
let x = 1; in { inherit x; }                  # { x = 1; }   inherit x  means  x = x;
let a = { x = 1; }; in { inherit (a) x; }     # { x = 1; }   take x from a
rec { a = 1; b = a + 1; }                     # { a = 1; b = 2; }
{ a = 1; b = a; }                             # error: undefined variable 'a'  (needs rec or let)
let s = { x = 1; y = 2; }; in with s; x + y   # 3      with brings s's names into scope
```

In your files: `pkgs/helium.nix` uses `let version = "0.20.2.1"; unpacked = …; in …` and `inherit version;`. `disko.nix` uses `let btrfsOptions = [ … ]; in`. `configuration.nix` uses `with pkgs; [ git vim … ]` so you can write `git` instead of `pkgs.git`.

> **with has the lowest priority.** `let x = 1; in with { x = 2; }; x` is `1`. A local name always beats a name from `with`. It also hides where a name came from, so a typo in `systemPackages` shows up only at evaluation as `undefined variable 'foo'`.

### Functions

A function has exactly one argument, written `arg: body`. Multiple arguments are functions returning functions. Most Nix functions take one attribute set and destructure it.

``` nix
(x: x + 1) 2                                    # 3
(a: b: a + b) 1 2                               # 3   curried
({ a, b ? 5, ... }: a + b) { a = 1; c = 9; }    # 6   b defaults to 5, ... ignores c
({ a, b ? 5 }: a + b) { a = 1; c = 9; }         # error: unexpected argument 'c'
(args@{ a, ... }: args.c) { a = 1; c = 9; }     # 9   args is the whole set
({ a, b }: a + b) { a = 1; }                    # error: called without required argument 'b'
```

Your files are functions of this kind:

- `configuration.nix` starts with `{ pkgs, ... }:`. The module system calls it with `config`, `lib`, `pkgs`, `options`, `modulesPath` and more. You list what you use. The `...` is required, or the extra arguments are rejected.
- `flake.nix`: `outputs = { nixpkgs, nixos-hardware, disko, ... }:`. The `...` hides `self`.
- `pkgs/helium.nix` starts with `{ stdenvNoCC, fetchurl, buildFHSEnv, appimageTools, }:`. `callPackage` fills those in from `pkgs` by name.

### The list gotcha: calls inside lists need parentheses

Function application is just a space, and list elements are separated by spaces. So inside `[ ]` every call must be wrapped in parentheses.

```
[ builtins.add 1 2 ]       # [ <PRIMOP> 1 2 ]   three elements
[ (builtins.add 1 2) ]     # [ 3 ]
```

That is why your package list says `(callPackage ../../pkgs/helium.nix { })` and `(voxtype.override { onnxSupport = true; })`. Without the parentheses each would be three separate list elements and the build would fail with a type error.

Two smaller traps: `1/2` without spaces is a path, so write `1 / 2`. A hyphen is legal in names, so `x-1` is a variable called `x-1`. Write `x - 1`.

### Operators

``` nix
{ a = 1; } // { a = 2; b = 3; }               # { a = 2; b = 3; }   right side wins
{ a = { x = 1; }; } // { a = { y = 2; }; }    # { a = { y = 2; }; } shallow: x is lost
lib.recursiveUpdate { a.x = 1; } { a.y = 2; } # { a = { x = 1; y = 2; }; }
{ a = 1; }.b or 42                            # 42   default for a missing attribute
{ a = 1; } ? a                                # true has-attribute test
[ "a" ] ++ [ "b" ]                            # [ "a" "b" ]
if 1 < 2 then "yes" else "no"                 # "yes"  else is required
assert 1 == 2; 3                              # error: assertion '(1 == 2)' failed
```

`pkgs/claude-desktop.nix` builds its arguments as `appimageTools.defaultFhsEnvArgs // { pname = …; … }`: take nixpkgs' default set and override a few keys. Because `//` is shallow, the file rebuilds `targetPkgs` as `defaultFhsEnvArgs.targetPkgs pkgs ++ [ extras ]` instead of merging it.

### import and laziness

`import ./file.nix` evaluates a file and returns its value. `imports = [ ./a.nix ]` in a NixOS module is different: it hands the file to the module system to merge. Chapter 6 covers that.

Nix computes a value only when something needs it.

``` nix
let a = { x = throw "boom"; y = 2; }; in a.y   # 2: x is never evaluated
let x = x + 1; in x                            # error: infinite recursion encountered
builtins.trace "hi" 1                          # prints "trace: hi", returns 1
```

Laziness is why `nix eval ~/.local/share/chezmoi/nixos#nixosConfigurations.x1.config.services.tlp.settings` is fast: it forces only what that one option needs. It is also why errors point at the place a value was used, not where it was defined. `--show-trace` prints the whole chain.

### String context: how dependencies are tracked

When you interpolate a package into a string, the string remembers that package. Anything built from that string depends on it. In `pkgs/claude-desktop.nix`, `runScript = "${unpacked}/usr/lib/claude-desktop/claude-desktop …"` both produces a path and records that the launcher needs `unpacked`. Nix builds `unpacked` first and keeps it alive as long as the launcher exists. A store path pasted as a plain literal (`"/nix/store/abc…-foo"`) has no context, so Nix does not know about the dependency and may garbage-collect it.

### builtins, lib and pkgs

| Name | What it is | Examples |
|----|----|----|
| `builtins` | Functions built into the evaluator. Always in scope. | `builtins.map`, `filter`, `attrNames`, `readFile`, `toJSON`, `fromJSON`, `trace`. Some are top-level: `import`, `map`, `toString`, `throw`. |
| `lib` | The nixpkgs library, written in Nix. A module argument, or `nixpkgs.lib`, or `pkgs.lib`. | `lib.mkIf`, `mkDefault`, `mkForce`, `optionals`, `mapAttrs`, `genAttrs`, `recursiveUpdate`. |
| `pkgs` | The package set: over 120,000 packages plus builders. In a module it is already configured with `allowUnfree`. | `pkgs.ripgrep`, `pkgs.fetchurl`, `pkgs.stdenv`, `pkgs.callPackage`, `pkgs.writeShellScriptBin`. |

Read the docs of any of them in the REPL: `:doc builtins.map`, `:doc lib.optionals` (after `:l <nixpkgs>`). Online, [noogle.dev](https://noogle.dev/) searches every function with its type and examples.

### callPackage in six lines

`callPackage` reads a function's argument names and passes the matching attributes from `pkgs`. Explicit arguments override them. The result gets an `.override` method.

``` nix
lib.callPackageWith { x = 1; y = 2; z = 3; } ({ x, y ? 10, ... }: x + y) { }   # 3
lib.callPackageWith { x = 1; y = 2; } ({ x, y }: x + y) { y = 100; }           # 101
lib.callPackageWith { x = 1; } ({ x, wget }: x) { }
# error: Function called without required argument "wget"
```

`pkgs.callPackage` is exactly `lib.callPackageWith pkgs`. That is how `pkgs/helium.nix` receives `stdenvNoCC`, `fetchurl`, `buildFHSEnv` and `appimageTools` without you passing them.

### Syntax checklist

- `;` after every binding in an attribute set and a `let`.
- Function argument patterns use commas: `{ a, b }:`. Lists use spaces.
- Calls inside lists need parentheses.
- `//` is shallow. In modules, the module system merges deeply for you.
- Paths must be inside the flake, and in a git repo they must be tracked.
- Comments start with `#` or are `/* … */`.
- Format with `nix run nixpkgs#nixfmt -- file.nix`. Your files are already in nixfmt style.

## 06 · The module system

A NixOS module is a file that declares options, sets options, or both. The module system collects all modules (yours, nixos-hardware's, disko's and about 2000 from nixpkgs), merges every value set for each option, and produces `config`: one attribute set with the final value of every option. Modules then read `config` to generate files and units.

### Declaring versus setting

*nixpkgs: services/hardware/tlp.nix (shortened)*

``` nix
{ config, lib, pkgs, ... }:
let cfg = config.services.tlp; in
{
  options.services.tlp = {
    enable = lib.mkEnableOption "TLP";
    settings = lib.mkOption {
      type = with lib.types;
        attrsOf (oneOf [ bool int float str (listOf str) ]);
      default = { };
    };
  };
  config = lib.mkIf cfg.enable {
    environment.etc."tlp.conf".text =
      mkTlpConfig cfg.settings;
    # plus the package, units, restart triggers
  };
}
```

*yours: configuration.nix*

``` nix
{ pkgs, ... }:
{
  services.tlp = {
    enable = true;
    settings = {
      START_CHARGE_THRESH_BAT0 = 55;
      STOP_CHARGE_THRESH_BAT0 = 60;
      USB_EXCLUDE_BTUSB = 1;
    };
  };
}
```

Your file has no `options` or `config` key, so everything in it counts as `config`. The `config` argument a module receives is the merged result of all modules. Laziness lets one module read a value another module sets.

### One option, followed to the file on disk

**1: you set the option**

```
  configuration.nix   services.tlp.settings = { START_CHARGE_THRESH_BAT0 = 55; ... }
```

**2: the type merges every definition**

```
  configuration.nix   services.tlp.settings = { START_...=55; STOP_...=60; USB_...=1 }
  tlp.nix             services.tlp.settings = { CPU_SCALING_GOVERNOR_ON_AC = mkIf (null != null) ... }
  nixos-hardware      services.tlp.enable   = mkDefault true
                              │ attrsOf merges key by key; the mkIf false entries vanish
                              v
  config.services.tlp.settings = { START_CHARGE_THRESH_BAT0 = 55; STOP_CHARGE_THRESH_BAT0 = 60;
                                   USB_EXCLUDE_BTUSB = 1; }
```

**3: the module renders a file into the store**

```
  config.services.tlp.settings
     │ tlp.nix: environment.etc."tlp.conf".text = mkTlpConfig cfg.settings
     v
  /nix/store/...-etc-tlp.conf        START_CHARGE_THRESH_BAT0=55
                                     STOP_CHARGE_THRESH_BAT0=60
                                     USB_EXCLUDE_BTUSB=1
```

**4: activation links it and restarts the service**

```
  /nix/store/...-etc-tlp.conf
     -> linked into /etc/static/tlp.conf -> /etc/tlp.conf
     -> tlp.service has restartTriggers = [ that file ], so switch restarts it
```

Every service in your config works this way. Check the result with `readlink -f /etc/tlp.conf` and `sudo tlp-stat -c`, or without building: `nix eval --raw ~/.local/share/chezmoi/nixos#nixosConfigurations.x1.config.environment.etc.'"tlp.conf"'.text`.

### How values merge

The option's type decides what happens when several modules set it.

| Type | Several definitions | In your config |
|----|----|----|
| `listOf` | concatenated | `environment.systemPackages`, `boot.initrd.availableKernelModules`, `boot.blacklistedKernelModules` |
| `attrsOf`, submodules | merged per key, then per value type | `services.tlp.settings`, `systemd.network.networks`, `environment.etc` |
| `lines` | joined with newlines | `networking.firewall.extraInputRules`. A second assignment adds rules, it does not replace them. |
| `bool`, `str`, `int`, `enum` | equal values are fine; different values at the same priority are an error | `hardware.cpu.intel.updateMicrocode` is set by two modules to the same value |

### Priorities: who wins

Each definition has a priority. The lowest number wins, and definitions with a higher number are dropped.

| Written as | Priority | Used for |
|----|----|----|
| `lib.mkForce v` | 50 | Override something a module set. |
| `v` (plain) | 100 | Everything you write in configuration.nix. |
| `lib.mkDefault v` | 1000 | Defaults that profiles like nixos-hardware set and you can override with a plain value. |
| option's `default` | 1500 | Used when nobody sets it. |

Real examples: `not-detected.nix` sets `hardware.enableRedistributableFirmware = mkDefault true`, and your plain `true` wins. A desktop module sets the gnupg pinentry with `mkOverride 1100`, and your plain `pkgs.pinentry-gnome3` wins. If two modules set `networking.hostName` to different strings at 100, the build fails with *The option \`networking.hostName' has conflicting definition values* and lists both files. Fix it by removing one or using `mkForce`.

Two more helpers you will meet. `lib.mkIf cond { … }` contributes its definitions only when `cond` is true; most modules wrap their whole `config` in `mkIf cfg.enable`. `lib.mkMerge [ a b ]` puts several definition sets in one place.

### What nixos-hardware adds

`nixos-hardware.nixosModules.lenovo-thinkpad-x1-extreme` is the Gen 1 profile. Gen 2 to 4 are separate modules. It is a tree of small modules, almost all `mkDefault`, so your own values always win.

```
lenovo/thinkpad/x1-extreme/default.nix
├── lenovo/thinkpad         trackpoint on, wheel emulation
│   └── common/pc/laptop    services.tlp.enable = mkDefault true (unless power-profiles-daemon)
│       └── common/pc       blacklist ath3k only without firmware (empty here)
├── common/cpu/intel        microcode updates
│   └── common/gpu/intel    declares hardware.intelgpu.* options
│                           i915 in the initrd (correct resolution at the LUKS prompt)
│                           VA-API, OpenCL and media runtimes in hardware.graphics
└── common/pc/ssd           services.fstrim.enable = mkDefault true (weekly TRIM)
```

Nothing in this profile touches the GTX 1050 Ti, the fingerprint reader or Thunderbolt.

### Reading options from the terminal

``` sh
# final value
$ nix eval ~/.local/share/chezmoi/nixos#nixosConfigurations.x1.config.services.tlp.settings
# which files set it, and with what value
$ nix eval --json ~/.local/share/chezmoi/nixos#nixosConfigurations.x1.options.services.tlp.settings.definitionsWithLocations
# which file declares it
$ nix eval ~/.local/share/chezmoi/nixos#nixosConfigurations.x1.options.services.tlp.settings.declarations
# interactive, with tab completion; config, options, pkgs and lib are in scope
$ nixos-rebuild repl --flake ~/.local/share/chezmoi/nixos#x1
nix-repl> config.services.tlp.settings
nix-repl> options.services.tlp.settings.description
nix-repl> :r                 # reload after editing a file
```

## 07 · Packages and derivations

A derivation is a build recipe: which builder to run, with which arguments, environment variables and inputs. Building it produces one or more store paths. `stdenv.mkDerivation` is the usual way to write one. It runs a shell script in phases: unpack, patch, configure, build, check, install, fixup.

### Why the hash is in the path

The hash in `/nix/store/<hash>-name` is computed from the whole recipe, recursively: every input's store path, the build script and the environment. Change one character of a build script and the output path changes. That gives three properties you rely on:

- The binary cache can answer "do you have exactly this build?" by path. That is why almost nothing on the x1 compiles.
- Old generations still have their exact paths, so rollback costs nothing.
- Several versions of anything can coexist.

The cost: changing a deep dependency like glibc changes the hash of everything above it, and all of it is downloaded again.

Downloads are the exception. A fetcher like `fetchurl` is a fixed-output derivation: you declare the content hash, the build may use the network, and the result must match. When upstream changes a file, you get:

``` sh
error: hash mismatch in fixed-output derivation '/nix/store/...-claude-desktop_2.42304.0_amd64.deb.drv':
         specified: sha256-dM0szCnSQWUUTkVcvIcsbMKiSiY7g+c0IOlfiRZtSqQ=
            got:    sha256-...
```

If you trust the new file, copy the `got:` value into the `hash`.

### pkgs/helium.nix, line by line

*pkgs/helium.nix*

``` nix
{ stdenvNoCC, fetchurl, buildFHSEnv, appimageTools, }:   # filled in by callPackage

let
  version = "0.20.2.1";

  unpacked = stdenvNoCC.mkDerivation {                    # derivation 1: the unpacked tarball
    pname = "helium-unpacked";
    inherit version;                                      # name: helium-unpacked-0.20.2.1
    src = fetchurl {                                      # derivation 2: the download
      url = "https://github.com/imputnet/helium-linux/releases/download/${version}/helium-${version}-x86_64_linux.tar.xz";
      hash = "sha256-upKssn7GzaNqi5SOIVQAmq7g1jMiKtJEviXnNqFD5vo=";
    };
    dontFixup = true;                                     # leave the vendor binaries unpatched
    installPhase = "cp -a . $out";                        # unpackPhase already extracted it
  };
in
buildFHSEnv (appimageTools.defaultFhsEnvArgs // {         # derivation 3: the launcher
  pname = "helium";
  inherit version;
  executableName = "helium-browser";
  runScript = "${unpacked}/helium-wrapper";
  extraInstallCommands = ''
    mkdir -p $out/share/applications $out/share/icons/hicolor/256x256/apps
    sed 's/^Exec=helium/Exec=helium-browser/' ${unpacked}/helium.desktop > $out/share/applications/helium.desktop
    cp ${unpacked}/product_logo_256.png $out/share/icons/hicolor/256x256/apps/helium.png
  '';
})
```

Comments added; the file itself has none. The `sed` renames the launcher in the desktop entry to match `executableName`.

- `stdenvNoCC` is stdenv without a C compiler, enough for copying files.
- The default `unpackPhase` recognizes the `.tar.xz` and changes into the extracted directory. `$out` is the output path, set by Nix.
- `dontFixup` skips the phase that would patchelf, strip and rewrite shebangs. The binaries run inside an FHS sandbox, so they need no patching.
- `buildFHSEnv` creates `bin/helium-browser`, a script that starts `runScript` in a bubblewrap namespace with a normal `/usr` and `/lib`, populated from `targetPkgs`.
- `grok-bot.nix` is the same with a .deb: `dontUnpack = true`, `nativeBuildInputs = [ dpkg ]`, `installPhase = "dpkg-deb -x $src $out"`. `claude-desktop.nix` extracts with `tar --no-same-permissions` because the build sandbox refuses the setuid `chrome-sandbox` file, and adds QEMU, virtiofsd and OVMF firmware for Cowork.

### Updating one of your vendor apps

1.  Change `version` (and `commit` for grok-bot).
2.  Get the new hash: `nix store prefetch-file --json "<url>" | jq -r .hash`. Or set `hash = "";`, build, and copy the `got:` value from the error.
3.  Build just that package before switching: `nixos-rebuild build --flake ~/.local/share/chezmoi/nixos#x1`.

### override and overrideAttrs

|  | Changes | Example |
|----|----|----|
| `pkg.override { … }` | the function arguments of the package file: dependencies and feature flags | `(voxtype.override { onnxSupport = true; })`. The voxtype package file has `onnxSupport ? false` in its arguments. nixpkgs also has a prebuilt attribute for it, `voxtype-onnx`. |
| `pkg.overrideAttrs (old: { … })` | the attributes passed to `mkDerivation`: `src`, `version`, `patches`, phases | `hello.overrideAttrs (old: { patches = (old.patches or [ ]) ++ [ ./fix.patch ]; })` |

Arguments go to `override`, and build steps go to `overrideAttrs`. To apply a change everywhere a package is used, wrap it in an overlay: `nixpkgs.overlays = [ (final: prev: { foo = prev.foo.override { … }; }) ];`.

### Closures: what a path needs

After a build, Nix scans the output for the hashes of its inputs. Every hash it finds is a runtime reference. The closure of a path is the path plus everything it references, transitively. A closure is what gets copied, kept alive and counted as size.

``` sh
$ nix path-info -Sh /run/current-system                     # closure size of the system
$ nix path-info -rsSh /run/current-system | sort -h -k3 | tail
$ nix why-depends /run/current-system nixpkgs#glibc         # one chain from A to B
$ nix-store -q --references /run/current-system/sw          # direct references
$ nix-store -q --roots /nix/store/...-foo                   # what keeps it from GC
$ nix run nixpkgs#nix-tree -- /run/current-system           # interactive browser
```

### Packaging something that is not in nixpkgs

| You have | Use |
|----|----|
| a shell script | `pkgs.writeShellScriptBin "name" ''…''` or `pkgs.writeShellApplication { name; runtimeInputs; text; }`, which also runs shellcheck |
| a prebuilt CLI binary | `stdenv.mkDerivation` with `nativeBuildInputs = [ autoPatchelfHook ]` and the libraries in `buildInputs` |
| a prebuilt GUI app (Electron, Chromium) | copy the pattern of `pkgs/helium.nix`: unpack, then `buildFHSEnv` |
| an AppImage | `appimageTools.wrapType2 { pname; version; src; }`, or `programs.appimage.enable = true; programs.appimage.binfmt = true;` to run any AppImage directly |
| a Go, Rust or Python project from source | `buildGoModule`, `rustPlatform.buildRustPackage`, `python3Packages.buildPythonApplication`. Copy a similar package from `pkgs/by-name`. |

Then add `(callPackage ../../pkgs/foo.nix { })` to `environment.systemPackages`, and `git add pkgs/foo.nix`, because the flake is in the chezmoi git repo.

## 08 · Daily operations

> **git add new files first.** The flake is in the chezmoi git repo, and a flake in a git repo only sees files git knows about. Edits to tracked files are picked up, with a "Git tree is dirty" warning. A new file that is not added is invisible, and the error says it does not exist.

### Apply, test, preview

| Goal | Command | Effect |
|----|----|----|
| apply now and on every boot | `sudo nixos-rebuild switch --flake ~/.local/share/chezmoi/nixos#x1` | build, new generation, Limine entry, activate |
| apply now, old default on reboot | `sudo nixos-rebuild test --flake ~/.local/share/chezmoi/nixos#x1` | activate without a boot entry; reboot undoes it |
| apply at next boot only | `sudo nixos-rebuild boot --flake ~/.local/share/chezmoi/nixos#x1` | for kernel, initrd, display or network changes you do not want live |
| see what would restart | `sudo nixos-rebuild dry-activate --flake ~/.local/share/chezmoi/nixos#x1` | builds, lists unit changes, changes nothing |
| see what would download or build | `nixos-rebuild dry-build --flake ~/.local/share/chezmoi/nixos#x1` | evaluation plus a plan |
| build only, no root | `nixos-rebuild build --flake ~/.local/share/chezmoi/nixos#x1` | leaves `./result` |
| what changed | `sudo nixos-rebuild switch --flake ~/.local/share/chezmoi/nixos#x1 --diff` | prints the package diff |
| try the config in a VM | `nixos-rebuild build-vm --flake ~/.local/share/chezmoi/nixos#x1 && ./result/bin/run-x1-vm` | QEMU VM of the config; *not checked with the LUKS and btrfs disko layout* |

In 26.05, `nixos-rebuild` is the Python rewrite (nixos-rebuild-ng). Useful flags: `-L` prints build logs, `--show-trace` gives the full evaluation trace, `--keep-going`, `--offline`. Do not use `--upgrade`; it is for channels, and you have a flake.

> **switch does not restart user services.** After changing a `systemd.user` unit: `systemctl --user daemon-reload && systemctl --user restart foo`, or log out and in. Kernel changes need a reboot. To check whether one is needed: `readlink /run/booted-system/kernel /run/current-system/kernel`.

### Roll back

``` sh
# previous generation, now. Limine still boots the newest one by default
$ sudo nixos-rebuild switch --rollback
# list generations (sudo if it complains)
$ nixos-rebuild list-generations
# jump to a specific generation
$ sudo /nix/var/nix/profiles/system-41-link/bin/switch-to-configuration switch
```

From the boot menu: at the Limine menu, press an arrow key within 5 seconds and pick an older `Generation N` under "NixOS default profile". That boots it once.

> **Limine always boots the newest generation by default.** `--rollback` changes what runs now, but the broken generation stays first in the menu. To make it stick, record the generation you are running as a new, newest generation. This is the same `nix-env --set` call a normal switch makes. Nothing is deleted, and the broken generation stays in the menu for later:

``` sh
$ sudo nix-env -p /nix/var/nix/profiles/system --set "$(readlink -f /run/current-system)"
$ sudo /run/current-system/bin/switch-to-configuration boot
$ grep -A2 'default profile' /boot/limine/limine.conf   # check which entry is first
```

This works after `switch --rollback` and after booting an older entry from the menu, because `/run/current-system` is the good generation in both cases. Then fix `~/.local/share/chezmoi/nixos`, for example with `git -C ~/.local/share/chezmoi revert <commit>`, or `git -C ~/.local/share/chezmoi checkout <good-commit> -- nixos/` to reset only the flake. The flake is the source of truth, so the next `switch` from an unfixed flake brings the broken system back.

The rollback window is the smaller of the 10 Limine entries and the 14 days that `nix.gc` keeps.

### Update

``` sh
$ cd ~/.local/share/chezmoi/nixos
$ nix flake update                       # all inputs
$ nix flake update nixpkgs               # just one
$ git diff flake.lock                    # see the new revisions
$ sudo nixos-rebuild switch --flake ~/.local/share/chezmoi/nixos#x1 --diff
# undo the update before switching
$ git checkout flake.lock
```

nixos-26.05 is a stable branch, so an update brings security and bug fixes, not new major versions. To move to the next release, change `nixos-26.05` to `nixos-26.11` in `flake.nix`, run `nix flake update`, read the release notes, and rebuild. Keep `system.stateVersion = "26.05"`.

For one package newer than 26.05 has, add a second input and take only that package from it:

``` nix
# flake.nix
inputs.nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
outputs = { nixpkgs, nixpkgs-unstable, ... }: {
  nixosConfigurations.x1 = nixpkgs.lib.nixosSystem {
    specialArgs = { unstable = nixpkgs-unstable.legacyPackages.x86_64-linux; };
    modules = [ … ];
  };
};
# configuration.nix
{ pkgs, unstable, ... }: { environment.systemPackages = [ unstable.uv ]; }
```

### Generations and disk space

``` sh
$ sudo nix-env -p /nix/var/nix/profiles/system --delete-generations +5   # keep the last 5
$ sudo nix-collect-garbage --delete-older-than 7d
$ sudo nix-collect-garbage -d               # delete every old generation, then GC
$ sudo nixos-rebuild boot --flake ~/.local/share/chezmoi/nixos#x1   # afterwards, so Limine drops dead entries
$ systemctl list-timers nix-gc.timer         # the weekly automatic run
$ sudo nix-store --optimise                  # dedupe files written before auto-optimise
```

`nix store gc` only removes unreferenced paths. It does not delete generations. `nix-collect-garbage` deletes generations first, and is what `nix.gc` runs. As your user (without sudo) it cleans only your own profiles. `result` links from `nix build` and `.direnv` directories are GC roots too. `nix-store --gc --print-roots` lists everything that keeps paths alive.

### Find and add software

``` sh
$ nix search nixpkgs ripgrep                 # first run builds a cache, then fast
$ nix eval --raw nixpkgs#ripgrep.version
$ nix shell nixpkgs#ripgrep nixpkgs#jq       # try it: a subshell with both on PATH
$ nix run nixpkgs#cowsay -- hello            # run the main program once
$ nix shell nixpkgs#nix-index -c nix-index   # once: build the file index (slow)
$ nix shell nixpkgs#nix-index -c nix-locate --top-level bin/convert   # which package has it
```

Typing a missing command does not suggest a package on this system: the classic command-not-found database is not shipped with flake-based nixpkgs. Use `nix-locate` as above, or [search.nixos.org](https://search.nixos.org/packages?channel=26.05) with channel 26.05.

To install permanently, add the attribute name to `environment.systemPackages` in `configuration.nix` and switch. Avoid `nix profile add` and `nix-env -i`. They install imperatively into `~/.nix-profile`, outside the flake, and pin whatever nixpkgs revision was current at install time.

### Common edits

*enable a service*

```
services.tailscale.enable = true;           # find options: man configuration.nix, /services.tailscale
```

*your own system unit with a timer*

``` nix
systemd.services.backup-docs = {
  description = "Copy documents to the NFS backup";
  after = [ "network-online.target" ];
  wants = [ "network-online.target" ];
  path = [ pkgs.rsync ];                           # unit PATH is almost empty
  serviceConfig = { Type = "oneshot"; User = "mgajewskik"; };
  script = "rsync -a /home/mgajewskik/docs/ /mnt/backups/docs/";
  startAt = "daily";                               # creates backup-docs.timer
};
```

*a user service, started with the graphical session*

``` nix
systemd.user.services.my-thing = {
  wantedBy = [ "graphical-session.target" ];
  serviceConfig.ExecStart = "${pkgs.foo}/bin/foo";
};
```

chezmoi can also manage user units in `~/.config/systemd/user`. Both work. Units in chezmoi also apply on the Arch laptop and in containers. Units in the flake reference store paths and exist only on the x1.

*firewall*

```
networking.firewall.allowedTCPPorts = [ 8080 ];
networking.firewall.allowedUDPPorts = [ 51820 ];
networking.firewall.interfaces."wlan0".allowedTCPPorts = [ 3000 ];
# check: sudo nft list table inet nixos-fw
```

*a raw /etc file*

``` nix
environment.etc."foo/foo.conf".text = ''
  key = value
'';
environment.etc."foo/foo.ini" = { text = "…"; mode = "0644"; };  # copied, not linked: for programs that reject symlinks
```

*kernel, parameters, env vars, extra libraries for downloaded binaries*

```
boot.kernelPackages = pkgs.linuxPackages_latest;   # reboot after
boot.kernelParams = [ "mem_sleep_default=deep" ];
environment.sessionVariables.EDITOR = "nvim";
programs.nix-ld.libraries = with pkgs; [ libGL libx11 alsa-lib ];
```

> **No secrets in the flake.** Everything in the store is readable by every user, and the flake is in a public repo. Because it sits inside the chezmoi repo, every evaluation copies all of the repo's tracked files into the store, not just `nixos/`. Keep secrets in files outside the store and reference them by string path, for example `passwordFile = "/var/lib/secrets/foo";`. Tools like sops-nix and agenix exist for this when you need them.

### System versus dotfiles: who owns what

```
  nixos/ (nixos-rebuild)                    chezmoi  (chezmoi apply)
  ──────────────────────                    ─────────────────────────
  kernel, boot, disks, users                ~/.zshrc, ~/.config/sway, nvim, git ...
  system services, firewall                 ~/.config/systemd/user units
  system packages: sway, podman, apps       mise config + lock -> CLI tools in ~/.local/share/mise
  nix-ld, envfs (make mise binaries run)    runs `mise bootstrap` on change
  /etc/*                                    same files on Arch and in containers
```

The two do not overlap. No home-manager means NixOS never writes into your home directory. That split is what lets the same dotfiles run on the x1, the Arch laptop and inside devcontainers.

## 09 · Debugging

First decide which stage failed (chapter 2): evaluation, build, activation, or boot. Each stage has its own tools.

```
  something is wrong
   │
   ├─ nixos-rebuild printed "error:" ......... evaluation or build: system unchanged
   │     ├─ "option ... does not exist" / "undefined variable" / "syntax error"
   │     │     -> read the file:line in the message; --show-trace for the chain
   │     ├─ "builder for '/nix/store/...drv' failed"
   │     │     -> nix log /nix/store/...drv
   │     └─ "hash mismatch"  -> update hash in pkgs/*.nix
   │
   ├─ rebuild finished, "the following units failed" ... activation: new system is live
   │     -> systemctl status / journalctl -u ; fix forward or --rollback
   │
   ├─ a program fails to start .................. runtime
   │     ├─ "Could not start dynamically linked executable" / "libfoo.so: cannot open"
   │     │     -> nix-ld libraries (below)
   │     └─ config not applied -> readlink -f /etc/foo ; nix eval the option
   │
   └─ no boot / black screen ..................... boot
         -> Limine: older generation ; TTY with Ctrl+Alt+F2 ; live USB rescue
```

### Evaluation errors

Read from the bottom up. The last `error:` line is the cause. The lines above it say where it was forced. Add `--show-trace` for the full chain.

| Message | Usual cause | Fix |
|----|----|----|
| `` The option `foo.bar' does not exist `` | typo, an option from another release, or a missing module import | check `man configuration.nix`; options from nixos-hardware or disko need their module in `flake.nix` |
| `` The option `x' has conflicting definition values `` | two modules set a single-value option differently | remove one, or `lib.mkForce` yours. The message lists both files. |
| `undefined variable 'foo'` | a package name that is not in `pkgs`, often inside `with pkgs; [ … ]` | `nix search nixpkgs foo` for the real attribute name |
| `attribute 'foo' missing` | same, written as `pkgs.foo` | same |
| `path '…/hosts/x1/new.nix' does not exist` right after you created it | the file is not tracked by git | `git add hosts/x1/new.nix` |
| `syntax error, unexpected '}', expecting ';'` | missing `;` | add it on the line before |
| `infinite recursion encountered` | an option defined in terms of itself, or `config` used to decide `imports` | `--show-trace`, look for the cycle |
| `Package 'x' has an unfree license` | unfree outside the system `pkgs` (for example `legacyPackages` in a devShell) | `config.allowUnfree = true` on that import, or `NIXPKGS_ALLOW_UNFREE=1 … --impure` |
| `Package 'x' is marked as insecure` or `broken` | nixpkgs gates it | `nixpkgs.config.permittedInsecurePackages = [ "x-1.2" ];` |
| `assertion '…' failed` | a module checks a requirement | read the message; it names the option to change |

### Build errors

``` sh
$ nix log /nix/store/<hash>-foo.drv          # full log of the failed build
$ sudo nixos-rebuild switch --flake ~/.local/share/chezmoi/nixos#x1 -L   # stream build logs
$ nixos-rebuild build --flake ~/.local/share/chezmoi/nixos#x1 --keep-failed   # keep the build dir in /tmp
$ nix develop nixpkgs#foo                  # enter foo's build environment, run phases by hand
nix-shell$ unpackPhase; cd "$sourceRoot"; configurePhase; buildPhase
```

Network trouble during a build: interrupted downloads are safe to retry. `--offline` uses only what is already in the store.

### Service problems

``` sh
$ systemctl --failed
$ systemctl status foo.service
$ journalctl -u foo.service -b             # this boot; -f to follow; -p err for errors only
$ systemctl cat foo.service                # the unit NixOS generated, with its store paths
$ systemctl show -p ExecStart,Environment foo.service
$ readlink -f /etc/foo/foo.conf           # the generated config, in the store
$ systemctl --user status syncthing; journalctl --user -u syncthing
$ journalctl -b -1 -p err                  # errors from the previous boot
$ systemd-analyze blame
```

`systemctl cat` is the most useful one. It shows exactly what the module generated, including the near-empty `PATH`. A command missing inside a unit means it needs `path = [ pkgs.x ];`. Hardening options like `ProtectHome` explain "cannot see /home" problems.

### Checking what the config says, without building

``` sh
$ nix eval ~/.local/share/chezmoi/nixos#nixosConfigurations.x1.config.boot.loader.limine.maxGenerations
10
$ nix eval --json ~/.local/share/chezmoi/nixos#nixosConfigurations.x1.config.services.tlp.settings | jq
$ nix eval --raw ~/.local/share/chezmoi/nixos#nixosConfigurations.x1.config.environment.etc.'"tlp.conf"'.text
$ nixos-option --flake ~/.local/share/chezmoi/nixos#x1 services.tlp.settings
$ nixos-rebuild repl --flake ~/.local/share/chezmoi/nixos#x1
nix-repl> config.systemd.services.tlp.serviceConfig
nix-repl> options.hardware.intelgpu.computeRuntime.definitionsWithLocations
```

Always pass `--flake` to `nixos-option`. Without `/etc/nixos/flake.nix` it cannot find your config.

### Downloaded binaries

| Symptom | Check | Fix |
|----|----|----|
| `Could not start dynamically linked executable` | `ls -l /lib64/ld-linux-x86-64.so.2` should point at nix-ld | This message comes from the stock stub loader, so nix-ld is not in place. Check that `programs.nix-ld.enable` is set, switch, and on the first enable log in again. `echo $NIX_LD` should print a path. |
| `error while loading shared libraries: libfoo.so.1` | `ldd ./bin | grep "not found"` | find the package with `nix-locate libfoo.so.1`, add it to `programs.nix-ld.libraries`, switch |
| script fails on `/usr/share/…` or `/usr/lib/…` | `mount | grep envfs` | envfs only provides executables. Package the tool, or run it in a `buildFHSEnv` or `steam-run`. |
| GUI app missing GL, GTK or X11 libraries | `LD_DEBUG=libs ./app 2>&1 | grep -i fail` | wrap it like `pkgs/helium.nix`, or `appimage-run` for AppImages |
| mise wants to compile node or python | `mise settings get all_compile` | must be `false` (your chezmoi config sets it). Python with `compile = true` would need headers NixOS does not expose; use `uv python install` instead. |
| nvim-treesitter cannot find `cc` | `command -v cc` | `gcc` is in `systemPackages` after the last change; switch to pick it up |

### Boot problems

- **Boots, but no graphics:** Ctrl+Alt+F2 for a TTY, then `journalctl -b -p err` and `dmesg | grep -i -e nouveau -e i915`. Fix the config and `nixos-rebuild boot`, or roll back.
- **Bad kernel or initrd:** pick the previous generation in Limine. The kernel command line editor is off. To edit parameters at boot, set `boot.loader.limine.enableEditor = true;` first, and keep in mind that anyone at the keyboard can then change them.
- **LUKS prompt rejects the passphrase:** the keymap is Polish from the start (`console.earlySetup`). Test a passphrase from a live USB with `cryptsetup open --test-passphrase /dev/disk/by-partlabel/disk-main-root`.
- **Nothing boots:** rescue from the NixOS USB:

``` sh
$ sudo cryptsetup open /dev/disk/by-partlabel/disk-main-root root
$ sudo mount -o subvol=@,compress=zstd:1,noatime /dev/mapper/root /mnt
$ sudo mount -o subvol=@nix,compress=zstd:1,noatime /dev/mapper/root /mnt/nix
$ sudo mount -o subvol=@home,compress=zstd:1,noatime /dev/mapper/root /mnt/home
$ sudo mount /dev/disk/by-partlabel/disk-main-ESP /mnt/boot
$ sudo nixos-enter --root /mnt
# inside the installed system
$ nixos-rebuild boot --flake /home/mgajewskik/.local/share/chezmoi/nixos#x1 --install-bootloader
$ passwd mgajewskik                        # if you need to reset it
```

`--install-bootloader` rewrites the Limine files and the EFI entry even when the config is unchanged. An Arch ISO cannot `arch-chroot` into NixOS, because there is no `/bin` and `/usr` to run. Use the NixOS ISO.

### Disk full

``` sh
$ df -h / /boot; sudo btrfs filesystem usage /
$ sudo btrfs filesystem du -s /nix /home /var
$ find ~ -maxdepth 3 -name result -type l   # old nix build links are GC roots
$ sudo nix-collect-garbage --delete-older-than 7d
$ sudo journalctl --vacuum-size=500M
$ sudo snapper -c home list                # snapshots keep deleted /home data
```

If `/boot` (1 GiB) fills up during a switch: each Limine entry has its own copy of the kernel and initrd. Lower `boot.loader.limine.maxGenerations`, delete old generations, and run `nixos-rebuild boot` so the installer prunes `/boot/limine`.

## 10 · Docs in the terminal, and sources

Your config sets no `documentation.*` options, so the NixOS defaults apply: man pages, info pages and the NixOS manual are installed. Developer man pages for libraries are not, and the `apropos` index is not built.

### Offline, on the x1

| Command | What you get |
|----|----|
| `man configuration.nix` | Every NixOS option of exactly this nixpkgs, with type, default and description. Search with /, for example `/services\.tlp`. Options from nixos-hardware and disko are not in it. |
| `man nixos-rebuild` | Every verb and flag of nixos-rebuild-ng. |
| `nixos-help` | The NixOS manual as HTML in your browser. Terminal version: `BROWSER=w3m nixos-help` after `nix shell nixpkgs#w3m`. |
| `man nix.conf`, `nix config show` | Every Nix setting, and its current effective value. |
| `nix --help`, `nix flake update --help` | The Nix 2.34 manual page for any command, with examples. Pages are named `nix3-*`: `man nix3-flake`, `man nix3-env-shell` (that is `nix shell`), `man nix3-store-gc`. |
| `man nix-store`, `man nix-collect-garbage`, `man nix-shell` | The older commands, still used and still documented. |
| `nix repl`, then `:l <nixpkgs>`, then `:doc builtins.map`, `:doc lib.mkIf` | Documentation for any builtin or `lib` function. |
| `nix repl`, then `:l <nixpkgs>`, then `:e tlp` | Opens the package's source file in `$EDITOR`. Same as `EDITOR=nvim nix edit nixpkgs#tlp`. |
| `nixos-rebuild repl --flake ~/.local/share/chezmoi/nixos#x1` | Your config, options, pkgs and lib in a REPL. `options.<path>.declarations` gives the module file that defines an option. |
| `tldr nix` | Not installed. `nix shell nixpkgs#tldr` if you like it. |

### Reading the pinned nixpkgs source

The fastest way to answer "what does this option really do" is to read the module, at the exact revision you run.

``` sh
$ NIXPKGS=$(nix eval --raw ~/.local/share/chezmoi/nixos#nixosConfigurations.x1.pkgs.path)
$ echo $NIXPKGS                            # /nix/store/...-source, revision 6f06d204
$ rg -l 'services.tlp' $NIXPKGS/nixos/modules
$ nvim $NIXPKGS/nixos/modules/services/hardware/tlp.nix
$ ls $NIXPKGS/pkgs/by-name/vo/voxtype/       # packages live under pkgs/by-name/<2 letters>/<name>
$ rg -n 'mkDefault' $NIXPKGS/lib/modules.nix
```

### Make the offline docs better (optional)

```
documentation.man.cache.enable = true;            # build the index: apropos and man -k work
documentation.dev.enable = true;                  # section 3 pages for installed libraries
documentation.nixos.includeAllModules = true;     # include disko and nixos-hardware options; try with nixos-rebuild build first
```

Each one makes rebuilds slower when documentation changes. None of them is applied.

### Online references

All links were checked on 2026-10-30. The NixOS and Nixpkgs manuals have no working `/26.05/` URL; `/stable/` is 26.05 until 26.11 ships.

| Source | Use it for |
|----|----|
| [NixOS manual](https://nixos.org/manual/nixos/stable/) · [options](https://nixos.org/manual/nixos/stable/options) · [release notes](https://nixos.org/manual/nixos/stable/release-notes) | configuring, administering, troubleshooting, writing modules |
| [Nix 2.34 reference manual](https://nix.dev/manual/nix/2.34/) | the language, the store, every command. [Language](https://nix.dev/manual/nix/2.34/language/), [builtins](https://nix.dev/manual/nix/2.34/language/builtins.html), [new CLI](https://nix.dev/manual/nix/2.34/command-ref/new-cli/nix.html), [nix.conf](https://nix.dev/manual/nix/2.34/command-ref/conf-file.html) |
| [Nixpkgs manual](https://nixos.org/manual/nixpkgs/stable/) | stdenv phases, fetchers, trivial builders, language builders, `override` |
| [nix.dev](https://nix.dev/) | tutorials: [Nix language basics](https://nix.dev/tutorials/nix-language), [module system](https://nix.dev/tutorials/module-system/), [flakes](https://nix.dev/concepts/flakes), [declarative shells](https://nix.dev/tutorials/first-steps/declarative-shell.html), [best practices](https://nix.dev/guides/best-practices), [troubleshooting](https://nix.dev/guides/troubleshooting) |
| [search.nixos.org packages](https://search.nixos.org/packages?channel=26.05) · [options](https://search.nixos.org/options?channel=26.05) | find attribute names and options. Set the channel to 26.05. Each option links to its source. |
| [noogle.dev](https://noogle.dev/) | search `lib` and builtins functions with types and examples |
| [mynixos.com](https://mynixos.com/) | third-party browser that also covers options from flakes such as disko |
| [NixOS wiki](https://wiki.nixos.org/wiki/NixOS): [Flakes](https://wiki.nixos.org/wiki/Flakes), [Btrfs](https://wiki.nixos.org/wiki/Btrfs), [Limine](https://wiki.nixos.org/wiki/Limine), [Podman](https://wiki.nixos.org/wiki/Podman), [Nix-ld](https://wiki.nixos.org/wiki/Nix-ld), [Sway](https://wiki.nixos.org/wiki/Sway) | practical recipes. Content can lag a release; confirm against the options. |
| [Nix Pills](https://nixos.org/guides/nix-pills/) | how derivations and the store work underneath. Older style, deep model. |
| [Zero to Nix](https://zero-to-nix.com/) | a flake-first beginner path |
| [nixpkgs nixos/modules](https://github.com/NixOS/nixpkgs/tree/nixos-26.05/nixos/modules) · [pkgs/by-name](https://github.com/NixOS/nixpkgs/tree/nixos-26.05/pkgs/by-name) | the source, on your branch |
| [nixos-hardware x1-extreme](https://github.com/NixOS/nixos-hardware/tree/master/lenovo/thinkpad/x1-extreme) · [disko docs](https://github.com/nix-community/disko/blob/master/docs/INDEX.md) | your two other inputs |
| [NixOS Discourse](https://discourse.nixos.org/) | search before asking; announcements |

## 11 · Development environments

A development environment is the set of tools, libraries and variables a project needs, active only while you work on it. You have three ways to get one on the x1. mise downloads upstream binaries per directory. Nix builds the environment from nixpkgs. A devcontainer runs the whole thing in an isolated container. They can be combined, and your plan (NixOS host, develop inside devcontainers with mise, learn Nix on the side) is a sound order.

### How your setup works today

**Step 1: chezmoi installs mise and its tools**

```
  chezmoi apply
    ├─ .chezmoiexternals/mise.toml.tmpl     download mise to ~/.local/bin if missing
    ├─ dot_config/mise/config.toml.tmpl  -> ~/.config/mise/config.toml   (tools + settings)
    ├─ dot_config/mise/private_mise.lock -> ~/.config/mise/mise.lock     (exact versions, checksums)
    └─ run_onchange_after_install_packages.sh
          runs `mise bootstrap` whenever the config or the lock changes
```

**Step 2: zsh activates mise on every prompt**

```
  ~/.zshrc: eval "$(mise activate zsh)"
    every prompt -> mise hook-env
      ├─ reads ~/.config/mise/config.toml, then mise.toml files from / down to $PWD
      ├─ prepends the tool dirs to PATH  (~/.local/share/mise/installs/<tool>/<ver>/bin)
      └─ exports [env] variables; unsets them when you leave the directory
```

**Step 3: on NixOS, nix-ld makes those binaries run**

```
  mise tool (generic Linux binary)
    ├─ static (most aqua/github tools: ripgrep, fd, ...)  -> runs anywhere
    └─ dynamic (node, neovim, claude, Mason LSPs, uv's python)
          -> /lib64/ld-linux-x86-64.so.2 = nix-ld -> runs
  settings: all_compile = false  (otherwise mise compiles node on NixOS and fails without python)
```

**Step 4: devcontainers repeat the same chain inside the container**

```
  crib / devcontainer CLI  ->  podman (rootless)  ->  Debian base image
    post-create.sh: apt-get build-essential, jq, gnupg, openssh ...
                    ./setup.sh -> chezmoi init --apply  (.container = true, no crib)
                                    -> mise bootstrap -> same tools, same lock
  host x1 only provides: podman, the gpg-agent socket, SSH via `podman exec ... sshd -i`
```

Inside the container nothing is NixOS. It is Debian with your dotfiles, so everything you know from Arch applies there, and the mise lock gives the same versions as on the host.

> **crib is discontinued.** Its README now says "crib is discontinued and no longer actively maintained" and asks for a new maintainer. The last release is v0.10.0 (2026-08-12), which is what your mise lock pins. The author's post ["I'm done with dev containers"](https://fabiorehm.com/blog/2026/10/09/im-done-with-dev-containers/) explains why. v0.10.0 keeps working, but plan a successor: the official `devcontainer` CLI with podman, or plain podman.

### The Nix options, from smallest to largest

**1: nix shell, a temporary PATH**

```
  $ nix shell nixpkgs#go nixpkgs#jq
      new shell: PATH += /nix/store/...-go-1.26.10/bin : /nix/store/...-jq-1.8.2/bin
      exit -> gone (store paths stay until GC)
```

**2: plus a flake devShell, the environment written down per project**

```
  $ nix shell nixpkgs#go ...                  ad hoc, nothing saved
  project/flake.nix  devShells.default        tools + libraries + env vars + shellHook
  project/flake.lock                          pins nixpkgs for this project
  $ nix develop                               enters it (a bash shell; -c zsh for zsh)
```

**3: plus direnv, automatic like mise**

```
  $ nix shell nixpkgs#go ...                  ad hoc
  project/flake.nix + flake.lock              the environment
  project/.envrc: "use flake"                 direnv hook in zsh: cd in -> loaded, cd out -> unloaded
                                              nix-direnv caches it in .direnv/ (fast, GC-safe)
```

**4: plus devenv, batteries on top**

```
  $ nix shell nixpkgs#go ...                  ad hoc
  project/flake.nix + .envrc                  plain Nix environment
  project/devenv.nix + devenv.yaml            same idea, higher level:
                                                languages.go.enable, languages.python.uv.enable
                                                services.postgres, processes (devenv up),
                                                tasks, git hooks, containers
```

Each step adds one thing. Most people stop at step 3. devenv earns its extra layer when a project needs services like Postgres.

### Using nix shell well

``` sh
$ nix shell nixpkgs#httpie nixpkgs#jq          # several tools, one subshell
$ nix shell nixpkgs#go_1_27 -c go version      # run one command and exit
$ nix run nixpkgs#nmap -- -sn 192.168.1.0/24   # run a package's main program
$ nix shell nixpkgs/nixos-unstable#uv          # from another branch, when 26.05 is too old
$ nix shell --impure --expr '(import <nixpkgs> { }).python3.withPackages (ps: [ ps.requests ])'   # python with a library
```

- `nixpkgs` on the x1 resolves to your locked revision, so these are mostly cache hits with no evaluation of a new nixpkgs.

- Versioned attributes at this revision: `go` is 1.26.10, `go_1_27` is 1.27.3. `nodejs` is 24.22.1, `nodejs_26` is 26.13.0. `python3` is 3.13.17, `python314` is 3.14.8.

- A script that brings its own tools:

      #!/usr/bin/env nix
      #! nix shell nixpkgs#curl nixpkgs#jq --command bash
      curl -s https://api.github.com/repos/NixOS/nixpkgs | jq .stargazers_count

### A project flake you can copy

*flake.nix (Go + Node + uv). Syntax-checked, not built.*

``` nix
{
  description = "Go + Node project shell";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs = { nixpkgs, ... }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = with pkgs; [ go_1_26 gopls nodejs_24 pnpm uv jq ];
          env = {
            APP_ENV = "dev";
            CGO_ENABLED = "0";
          };
          shellHook = ''
            export GOPATH="$PWD/.go"
            export PATH="$GOPATH/bin:$PWD/node_modules/.bin:$PATH"
          '';
        };
      });
    };
}
```

``` sh
$ git add flake.nix          # required inside a git repo
$ nix develop -c zsh         # enter; first run downloads, later runs are instant
$ nix flake update           # bump this project's nixpkgs
$ nix flake init -t templates#devshell   # or start from a template
```

Tips that keep flakes pleasant:

- Commit `flake.lock`. It is what makes the shell the same next month and on another machine.
- `nixpkgs.legacyPackages.${system}` does not allow unfree packages. For those, use `import nixpkgs { inherit system; config.allowUnfree = true; }`.
- Libraries and headers go in `packages` too (`openssl`, `pkg-config`, `postgresql`). mise cannot provide those. This is where Nix pays off.
- Keep one shared template. You could add `templates.go-node = { path = ./templates/go-node; description = "…"; };` to `~/.local/share/chezmoi/nixos/flake.nix` and start projects with `nix flake init -t ~/.local/share/chezmoi/nixos#go-node`.

### Per-directory variables: mise \[env\] versus direnv

*mise.toml (what you use now)*

```
[tools]
node = "24"
go = "1.26"

[env]
APP_ENV = "dev"
AWS_PROFILE = "dev"
_.file = ".env"
_.path = ["./bin"]
```

*.envrc (direnv + nix-direnv)*

``` nix
use flake          # tools from flake.nix

export APP_ENV=dev
export AWS_PROFILE=dev
dotenv             # load .env
PATH_add bin
```

Both load on `cd` into the directory and undo on `cd` out. direnv asks you to run `direnv allow` once per `.envrc` and after each edit, so a cloned repo cannot run code in your shell without consent. Your `~/.zshrc` swaps `HISTFILE` and starship shows `AWS_PROFILE` based on mise `[env]`. With direnv the same `export` lines in `.envrc` do the job.

To turn on direnv the NixOS way, add this to `configuration.nix`:

``` nix
programs.direnv = {
  enable = true;     # direnv 2.37.1 + nix-direnv 3.1.2 + the zsh hook in /etc/zshrc
  silent = true;     # hide the "direnv: loading" lines
};
```

- The hook lands in `/etc/zshrc`, which runs before `~/.zshrc`. Do not also add `direnv hook zsh` to your dotfiles, or it runs twice. If you prefer the hook in chezmoi (so it also works on Arch and in containers), skip this module and install direnv through mise instead.
- The module sets `DIRENV_CONFIG=/etc/direnv`, so `~/.config/direnv/direnv.toml` is ignored. `~/.config/direnv/direnvrc` is still sourced.
- Add `.direnv/` to your global git ignore. Your chezmoi `dot_config/git/ignore` lists `.mise.toml` but nothing for direnv.
- Log in again after enabling it.

> **mise and a devShell can fight over PATH.** Your global mise config installs `go` and `node`. mise prepends its directories on every prompt, so inside a flake shell `go` may still be mise's. Check with `which -a go`. Fix it by giving that project a `mise.toml` without go, or by dropping go and node from the global mise list once your projects have flakes.

### devenv

[devenv](https://devenv.sh/) is a layer on Nix with its own module system for developer environments. nixpkgs 26.05 has devenv 2.1.2, built against its own Nix fork at version 2.34. It still uses your system's Nix daemon and store.

*devenv.nix mirroring what mise does for you. Syntax-checked, not built.*

``` nix
{ pkgs, ... }:
{
  languages.javascript = {
    enable = true;
    package = pkgs.nodejs_24;
    pnpm.enable = true;
  };
  languages.go.enable = true;           # languages.go.version needs the go-overlay input in devenv.yaml
  languages.python = {
    enable = true;                      # languages.python.version needs nixpkgs-python in devenv.yaml
    uv.enable = true;
    uv.sync.enable = true;              # runs uv sync on entry
  };

  packages = [ pkgs.jq pkgs.gh ];
  env = { APP_ENV = "dev"; AWS_PROFILE = "dev"; };

  services.postgres = {                 # the reason to pick devenv
    enable = true;
    initialDatabases = [ { name = "app"; } ];
  };
  processes.web.exec = "go run ./cmd/web";

  tasks."app:deps" = {
    exec = "pnpm install";
    execIfModified = [ "pnpm-lock.yaml" ];
  };
  enterShell = "go version; node --version";
}
```

``` sh
$ nix shell nixpkgs#devenv -c devenv init   # writes devenv.nix, devenv.yaml, .gitignore
$ devenv shell                            # enter
$ devenv up -d                            # start postgres and processes
$ devenv tasks run app:deps
$ devenv update                           # bump devenv.lock
```

For direnv integration, put `eval "$(devenv direnvrc)"` and `use devenv` in `.envrc`.

| devenv compared with | Better at | Worse at |
|----|----|----|
| mise | services and processes, native libraries and compilers, tasks and git hooks in one file, exact language versions through go-overlay and nixpkgs-python | needs Nix on every machine; nixpkgs tool versions lag; more concepts; the first run downloads a lot |
| plain flake + direnv | less boilerplate, Postgres in three lines, `devenv up` | an extra layer with its own errors; anyone can run `nix develop`, but devenv must be installed |
| devcontainers | no container overhead, runs natively on the host | no isolation: processes run as you, on the host, with access to `~` and your SSH agent. Not for untrusted code. |

### Nix and devcontainers

Your containers are Debian with mise. Putting Nix inside them is possible, but for now it adds a second toolchain manager and a large download to every container, for little gain.

| Option | How | Verdict for you |
|----|----|----|
| Official Nix feature | `"ghcr.io/devcontainers/features/nix:1": { "multiUser": true, "extraNixConfig": "experimental-features = nix-command flakes" }` in `devcontainer.json` | The one to use when you need it. Flakes are enabled only through `extraNixConfig` (or when `flakeUri` is set). The daemon is started by the feature's entrypoint; whether crib runs feature entrypoints is *not verified*. The store is per container: rebuilt containers download everything again. A named volume on `/nix` may avoid that, *not verified* with crib or podman. |
| Determinate installer | `curl … https://install.determinate.systems/nix | sh -s -- install linux --init none` in post-create | With `--init none` only root can use Nix. Awkward with `remoteUser: vscode`. |
| `nixos/nix` base image | `"image": "nixos/nix"` | Not Debian: your `post-create.sh` uses `apt-get`, and the common-utils feature expects a Debian-family image. Skip. |
| Share the host's /nix | bind-mount `/nix` read-only plus the daemon socket | Not recommended. Code in the container gets to talk to the host's Nix daemon, which breaks the isolation you use containers for. The same `devcontainer.json` would also stop working on the Arch laptop. |
| Build images with Nix | `dockerTools.streamLayeredImage`, nix2container, `devenv container build`, then `podman load` | Good for shipping an app image. The result is a minimal closure with no apt, no users, no dotfiles, so it is a poor dev container. |

When there is no other option (a project only documents `nix develop`, and you want it in a container), add the feature in a separate variant such as `.devcontainer/nix/devcontainer.json`, then inside the container:

``` sh
$ nix --version                               # confirms the feature installed it
$ nix config show experimental-features      # must include nix-command flakes
$ nix develop -c zsh                         # the project's devShell, inside the container
# if the daemon is not running (entrypoint skipped):
$ sudo /usr/local/share/nix-entrypoint.sh
```

### Which tool for which job

| Situation | Use | Why |
|----|----|----|
| try a tool once | `nix shell nixpkgs#foo` on the x1, `mise exec foo@1.2 -- foo` elsewhere | nothing to install or clean up |
| the newest upstream release now | mise | upstream binaries the week they ship; nixpkgs stable lags |
| team project with a devcontainer | devcontainer + mise inside | isolation; teammates do not need Nix |
| untrusted code | devcontainer without the SSH agent | direnv and devenv run on the host with no isolation |
| personal project, only CLI tools | `mise.toml` now, a flake later | works on the x1, Arch and in containers today |
| project needs native libraries, headers, pkg-config | flake devShell + direnv | libraries are ordinary packages in Nix; mise cannot provide them |
| project needs Postgres or Redis and several processes | devenv, or compose inside a devcontainer | devenv has services and `devenv up` |
| reproducible CI | `mise install --locked` or `nix develop` with `flake.lock` | mise pins binaries with checksums; Nix pins the whole toolchain including libraries |
| a system tool or service on the x1 | `~/.local/share/chezmoi/nixos/hosts/x1/configuration.nix` | part of the OS, rolled back with it |

### Can Nix replace mise for you?

Technically yes, at a real cost, so not yet. What you would gain: native libraries in environments, no dependence on nix-ld for tools, one lock for tools and system, and none of mise's compile traps on NixOS. What you would lose:

- **Freshness.** Most of your mise tools are newer than nixpkgs 26.05 has them.
- **Portability.** Without home-manager, mise is the only thing that installs the same tools on the x1, the Arch laptop and in containers from one file.
- **Packaging work.** herdr and crib are not in nixpkgs at all, so you would maintain packages for them like `pkgs/helium.nix`.
- **Upgrade speed.** Bumping one user tool would mean a system rebuild, or the imperative `nix profile`.

| Tool | mise lock | nixpkgs 26.05 |
|----|----|----|
| bat, jq, k9s, lazyssh | same | same |
| gh | 2.102.0 | 2.103.3 (newer) |
| go / node | 1.27.2 / 26.12.0 | `go_1_27` 1.27.3 / `nodejs_26` 26.13.0 (pick the attribute) |
| neovim, ripgrep, fd, fzf, starship, tmux | 0.12.5, 15.2.0, 10.5.0, 0.74.4, 1.26.0, 3.7c | 0.12.4, 15.1.0, 10.4.2, 0.72.0, 1.25.1, 3.7b |
| lazygit, difftastic, yazi | 0.66.1, 0.71.0, 26.9.1 | 0.61.1, 0.69.0, 26.5.6 |
| uv, ty, usage | 0.13.1, 0.0.88, 6.12.0 | 0.11.21, 0.0.38, 3.2.1 (far behind) |
| claude, rtk, agent-browser | 2.1.301, 1.0.1, 0.38.2 | 2.1.223, 0.41.0, 0.27.0 |
| herdr, crib | 0.9.5, 0.10.0 | not packaged |

Versions from your `private_mise.lock` and nixpkgs at 6f06d204.

### A staged path that matches your plan

1.  **Now.** Keep NixOS on the host and develop in devcontainers with mise. Learn Nix on the host itself: this flake, `nix shell`, `nix repl`.
2.  **Plan for crib.** Decide on a successor while v0.10.0 still works.
3.  **Turn on direnv** with `programs.direnv`. Add `.direnv/` to the global git ignore. Check `which -a go` behaviour.
4.  **Try one personal project with a flake.** Use the flake above plus `.envrc`. Keep its `mise.toml` until the flake has earned your trust.
5.  **Try devenv** only on a project that needs a database.
6.  **Try Nix in a container** only for a project that already has a flake, as an opt-in `.devcontainer/nix/` variant.
7.  **Move slow-moving tools** that nixpkgs has at the same version into `systemPackages` if you want, and keep fast-moving ones (claude, uv, ty, rtk, herdr) in mise.
8.  **Drop mise last,** and only on the x1, if a review shows you no longer need upstream-latest tools. Keep it for containers and other machines.

## 12 · Learning path

About seven hours of reading in total, spread over a week. Every step ends with something you run on the x1, so the reading turns into a skill you will need anyway. This page covers enough to operate the machine. The steps below go deeper on the same topics.

| \# | Time | Read | Then do on the x1 |
|----|----|----|----|
| 1 | 30 min | NixOS manual: "Changing the Configuration" and "Upgrading NixOS". Skip the installation chapters. | Add one package, `switch`, roll back, switch again. Watch `nixos-rebuild list-generations`. |
| 2 | 90 min | [nix.dev: Nix language basics](https://nix.dev/tutorials/nix-language), the whole page. | Type every example into `nix repl`. Then read `pkgs/helium.nix` and `flake.nix` again without this page. |
| 3 | 60 min | [nix.dev: module system](https://nix.dev/tutorials/module-system/) and the NixOS manual chapter "Writing NixOS Modules". | In `nixos-rebuild repl --flake ~/.local/share/chezmoi/nixos#x1`, trace `services.tlp.settings` and `boot.loader.limine` with `definitionsWithLocations`. |
| 4 | 45 min | Man pages only: `man nixos-rebuild`, `man configuration.nix`, `nix flake --help`, `man nix3-why-depends`, `man nix3-store-diff-closures`, `man nix.conf`. | `nixos-rebuild build --flake ~/.local/share/chezmoi/nixos#x1` then `nix store diff-closures /run/current-system ./result`, and `sudo nixos-rebuild dry-activate --flake ~/.local/share/chezmoi/nixos#x1`. |
| 5 | 30 min | [nix.dev: flakes](https://nix.dev/concepts/flakes) and [wiki: Flakes](https://wiki.nixos.org/wiki/Flakes). | `nix flake metadata ~/.local/share/chezmoi/nixos`, `nix flake show ~/.local/share/chezmoi/nixos`, then an update and a rollback of `flake.lock` with git. |
| 6 | 30 min | NixOS manual: "Administration" and "Troubleshooting". The 26.05 release notes, only for options you use. | Boot an older generation once from the Limine menu, on purpose. |
| 7 | 15 min each | Wiki pages for Btrfs, Limine, Podman, Nix-ld, Sway. disko docs. The nixos-hardware x1-extreme directory. | Confirm one wiki claim against `man configuration.nix` or the module source. |
| 8 | when needed | [nix-direnv README](https://github.com/nix-community/nix-direnv) (10 min), then [devenv getting started](https://devenv.sh/getting-started/). | Stage 3 and 4 of the migration path in chapter 11. |

Skip for now: most of the Nixpkgs manual (use it for lookups only), cross-compilation, NixOS tests, and Nix Pills. If the store and derivation model still feels unclear after chapter 7, read [Nix Pills](https://nixos.org/guides/nix-pills/) 1 to 6, about an hour.

### What to unlearn from Arch

| Arch habit | On the x1 |
|----|----|
| `sudo pacman -S foo` | add `foo` to `environment.systemPackages`, switch. To try it: `nix shell nixpkgs#foo`. |
| `sudo nvim /etc/foo.conf` | find the `services.foo` option. `/etc` is regenerated on every switch, and links into the store are read-only. |
| `systemctl enable foo` | `services.foo.enable = true;`. `systemctl enable` of a system unit fails, because `/etc/systemd/system` is generated. User units in `~/.config/systemd/user` work as usual. |
| `pacman -Syu` | `nix flake update`, then switch. Nothing changes until you switch. |
| timeshift or a snapshot of `/` before updates | generations. Root does not need snapshots: the config and lock are the system. Back up `/home`, the flake, and the `/var/lib` paths from chapter 4. |
| AUR | nixpkgs has most of it. For the rest, write a package in `pkgs/` like Helium. |
| `./configure && make install` | in a `nix shell` or devShell with the libraries, or in a devcontainer |
| wiki first | options first: `man configuration.nix`, search.nixos.org, then the wiki |

## 13 · Noticed in your config

I found these while reading your flake against nixpkgs 26.05. None of them is applied. None blocks the install. Each one ends with a way to check it on the x1.

| What | Why it matters | Option or check |
|----|----|----|
| Every port is open to 192.168.0.0/16 | Anything that listens is reachable from any device on a 192.168.x.x network, including hotel and café Wi-Fi with that range. It is broader than your home LAN. | Narrow it to your LAN's /24, or delete the rule and open specific ports. Check: `sudo nft list chain inet nixos-fw input-allow`. |
| `mediaRuntime` keeps its default `vpl-gpu-rt` | The option description says Media SDK for Gen 8 to 11 and OneVPL for Gen 12+. The UHD 630 is Gen 9.5. This only affects Quick Sync through VPL. VA-API video decoding uses another driver. | Leave it. The alternative, `intel-media-sdk`, is marked end-of-life and insecure in nixpkgs, so selecting it would also need `permittedInsecurePackages`. Check video decoding: `nix shell nixpkgs#libva-utils -c vainfo`. |
| No package suggestion for unknown commands | command-not-found needs a database that flake-based nixpkgs does not include. | `programs.nix-index.enable = true;` plus a one-time `nix-index` run, or use `nix-locate` by hand (chapter 8). |
| `apropos` and `man -k` return nothing | `documentation.man.cache.enable` defaults to false. | Set it to true (chapter 10). Check: `apropos limine`. |
| Limine can list a generation that GC already deleted | `nix.gc` removes generations older than 14 days, but `limine.conf` is only rewritten on the next switch or boot. This is an inference from how the two work, not observed. | Run `sudo nixos-rebuild boot --flake ~/.local/share/chezmoi/nixos#x1` after a manual GC. Check: compare the Limine menu with `nixos-rebuild list-generations`. |
| `auto-optimise-store` without `nix.optimise` | Only new store paths are deduplicated. Paths written before the setting stay as they are. | One-off: `sudo nix-store --optimise`. Periodic: `nix.optimise.automatic = true;`. |
| `boot.initrd.systemd.enable = true` | Already the default in 26.05. Harmless, just redundant. | Delete the line if you like. |
| `voxtype.override { onnxSupport = true; }` | nixpkgs has the same thing as an alias, `voxtype-onnx`. | Either works. |
| No `openssh.authorizedKeys` | SSH accepts keys only. The key lives in `~/.ssh/authorized_keys`, which is fine but not declared anywhere. | Optional: `users.users.mgajewskik.openssh.authorizedKeys.keys = [ "ssh-ed25519 …" ];`. Public keys are not secrets. |
| The global git ignore has no direnv entries | Matters once you use direnv. | Add `.direnv/` to `dot_config/git/ignore` in chezmoi. Whether to also ignore `.envrc` depends on whether projects commit it. |
| mise's go and node may shadow a devShell's | The global mise config installs both, and mise prepends its PATH on every prompt. | Check inside a devShell: `which -a go node`. |
| mise python with `compile = true` | Compiling Python on NixOS needs headers that are not in standard locations. | Keep prebuilt Pythons: `uv python install` or mise with `compile = false`. |
| The local copy of this page has personal details | It names your user and the NFS server's address. `nix/` moves to the homelab repo later. | Decide whether that repo is public before committing `nix/docs/`. |

## 14 · Cheat sheet

``` sh
# change the system
sudo nixos-rebuild switch --flake ~/.local/share/chezmoi/nixos#x1
sudo nixos-rebuild test   --flake ~/.local/share/chezmoi/nixos#x1
sudo nixos-rebuild boot   --flake ~/.local/share/chezmoi/nixos#x1
sudo nixos-rebuild switch --rollback
nixos-rebuild list-generations
# update
nix flake update --flake ~/.local/share/chezmoi/nixos
git -C ~/.local/share/chezmoi/nixos diff flake.lock
# preview
nixos-rebuild build --flake ~/.local/share/chezmoi/nixos#x1
nix store diff-closures /run/current-system ./result
sudo nixos-rebuild dry-activate --flake ~/.local/share/chezmoi/nixos#x1
```

``` sh
# inspect the config
nixos-rebuild repl --flake ~/.local/share/chezmoi/nixos#x1
nix eval ~/.local/share/chezmoi/nixos#nixosConfigurations.x1.config.<option>
nixos-option --flake ~/.local/share/chezmoi/nixos#x1 <option>
man configuration.nix
# packages
nix search nixpkgs <name>
nix shell nixpkgs#<pkg>
nix run nixpkgs#<pkg> -- <args>
nix why-depends /run/current-system nixpkgs#<pkg>
nix path-info -Sh /run/current-system
```

``` sh
# debug
nixos-rebuild build --flake ~/.local/share/chezmoi/nixos#x1 --show-trace -L
nix log /nix/store/<hash>-<name>.drv
systemctl --failed
journalctl -u <unit> -b
systemctl cat <unit>
readlink -f /etc/<file>
readlink -f "$(command -v <cmd>)"
# space
sudo nix-collect-garbage --delete-older-than 14d
nix-store --gc --print-roots | grep -v proc
```

``` sh
# projects
nix flake init -t templates#devshell
nix develop -c zsh
echo "use flake" > .envrc && direnv allow
nix shell nixpkgs#devenv -c devenv init
# language, in nix repl
:l <nixpkgs>
:doc lib.mkIf
:e tlp
:p { a = { b = 1; }; }
:r
:q
```

| Path | What |
|----|----|
| `~/.local/share/chezmoi/nixos` | the flake: the only place you edit the system |
| `/run/current-system`, `/run/booted-system` | active and booted generation |
| `/nix/var/nix/profiles/system-*-link` | all generations |
| `/run/current-system/sw/bin` | every system program |
| `/etc/static` | generated `/etc` files |
| `/boot/limine/limine.conf` | boot menu, rewritten on switch |
| `/var/lib`, `/home`, `/etc/shadow` | state the flake does not manage |

Grounded in `~/.local/share/chezmoi/nixos` (nixpkgs nixos-26.05 at 6f06d204, nixos-hardware 04c6b94f, disko de570873), Nix 2.34 on the x1, and the chezmoi dotfiles as of 2026-10-30. Language examples were checked with the Nix evaluator. Snippets marked "not built" were only parsed. Commands that read live system state were not run on the x1. Check them there before you rely on their exact output.
