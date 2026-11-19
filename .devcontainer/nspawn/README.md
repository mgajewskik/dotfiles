# nspawn dev container (reference example)

A per-project dev container built on `systemd-nspawn` instead of crib and podman, kept for future reference.
It is untested: nothing here has run on a real host. Written on 2026-11-19 against systemd 260.5.

**Decision:** my dev containers stay on podman and the devcontainer spec.
nspawn is simpler at runtime, but it replaces open standards (OCI images, Dockerfiles, devcontainer.json) with tooling I would have to maintain myself.
This folder records what the nspawn version looks like and why it lost.

- [How container tools relate](#how-container-tools-relate)
- [What Docker and podman give you that nspawn does not](#what-docker-and-podman-give-you-that-nspawn-does-not)
- [How this example works](#how-this-example-works)
- [devcontainer.json to nspawn](#devcontainerjson-to-nspawn)
- [Using it](#using-it)
- [Tools around nspawn](#tools-around-nspawn)
- [When to pick which](#when-to-pick-which)
- [Sources](#sources)

## How container tools relate

Docker and podman are not wrappers around nspawn.
All three are built on the same kernel features, side by side:

```
 user-facing tool        manager / monitor          runtime (sets up the container)
 ────────────────        ─────────────────          ───────────────────────────────
 docker CLI ───────────▶ dockerd ─▶ containerd ───▶ runc ──┐
 podman CLI ───────────▶ conmon ──────────────────▶ crun ──┤
 machinectl ───────────▶ systemd (a unit per machine) ─▶ systemd-nspawn ──┤
                                                                          ▼
                     Linux kernel: namespaces, cgroups, seccomp, capabilities
```

- A **container** is an ordinary process that the kernel isolates: its own view of mounts, PIDs, network, users and hostname (namespaces), with resource limits (cgroups) and a filter on system calls (seccomp).
- A **runtime** (runc, crun, systemd-nspawn) sets those up and starts the first process.
- Everything above the runtime is what makes containers usable: images, builds, networking, storage, a CLI.

systemd-nspawn sits at the runtime level.
Docker and podman are the whole stack.

## What Docker and podman give you that nspawn does not

The common CLI is the least of it. The value is the **OCI standards** (Open Container Initiative) and the ecosystem built on them:

| Layer        | Docker / podman                                                          | systemd-nspawn                                                    |
| ------------ | ------------------------------------------------------------------------ | ----------------------------------------------------------------- |
| Image format | OCI images: layered, content-addressed, run by any compliant runtime     | a directory tree or a disk image                                  |
| Distribution | registries (Docker Hub, GHCR, ECR), tags, signing, caching                | `importctl pull-tar`, `pull-raw`, `pull-oci`                      |
| Build        | Dockerfile / Containerfile (BuildKit, buildah)                           | none; bring your own (`pacstrap`, `debootstrap`, mkosi)           |
| Runtime spec | OCI runtime spec                                                         | its own options; can also run an OCI bundle (`--oci-bundle=`)     |
| Networking   | rootless networking, port mapping, named networks                       | host network, veth, bridges, zones; `Port=` needs a private network |
| Storage      | volumes, bind mounts, overlay layers                                     | bind mounts, overlays, ephemeral snapshots                        |
| Multi-container | Compose                                                               | none                                                              |
| Ecosystem    | devcontainers, CI runners, Kubernetes, VS Code expect OCI images          | systemd tooling only                                              |
| Privilege    | podman runs rootless when started by a normal user                       | runs as root; settings that touch the host are privileged         |
| Inside       | usually a single process tree, no init                                   | usually boots a full systemd                                      |
| Platforms    | Linux natively; macOS and Windows through a VM the tool manages          | Linux with systemd only                                           |

nspawn can pull and run OCI images, but most images are built for a single process and do not include systemd.
`mcr.microsoft.com/devcontainers/base:debian`, for example, could run a command under nspawn but could not boot, so the units and start hooks that make nspawn attractive would not work.

## How this example works

### Files

```
.devcontainer/nspawn/
├── devbox                 the CLI: bootstrap | up | shell | down | render
├── devbox.nspawn          container settings: mounts, user namespace, network
├── limits.conf            host-side drop-in for the container's systemd unit
├── devbox-start.service   unit installed inside the container, runs on every boot
└── on-start.sh            the start hook itself (runs from the mounted project)
```

Placeholders (`@WORKSPACE@`, `@CLAUDE_PROJECT@`, `@USER@`) are filled in by `devbox`, because `.nspawn` files have no variables.
`devbox render` prints the result without touching the host.

### Where configuration lives

nspawn reads privileged settings (like `Bind=`) only from trusted locations: `/etc/systemd/nspawn/` and `/run/systemd/nspawn/`.
A `.nspawn` file next to the image in `/var/lib/machines/` loses those settings.
Writing to `/etc` would mean host configuration that is not declared per project, so `devbox up` renders the files from this folder into `/run`:

```
 repository (source of truth)          host (rendered by `devbox up`)
 ────────────────────────────          ──────────────────────────────────────────────────────
 devbox.nspawn         ───render──▶   /run/systemd/nspawn/<project>.nspawn
 limits.conf           ───copy────▶   /run/systemd/system/systemd-nspawn@<project>.service.d/
 devbox-start.service  ───render──▶   /var/lib/machines/<project>/etc/systemd/system/
 on-start.sh           (not copied: runs from the mounted project folder)
```

`/run` is cleared on reboot, so the host keeps no permanent configuration. The cost: run `devbox up` again after every reboot.

| Path                           | Lifetime                     | Holds                                 |
| ------------------------------ | ---------------------------- | ------------------------------------- |
| `.devcontainer/nspawn/`        | in git                       | all settings                          |
| `/run/systemd/...`             | until `down` or reboot       | rendered settings                     |
| `/var/lib/machines/devbox-base`| until removed                | shared base system, built once per host |
| `/var/lib/machines/<project>`  | until `machinectl remove`    | the project's container system        |

### What `devbox up` does

```
devbox up
 ├─ refuse if the container is already running
 ├─ clone devbox-base → /var/lib/machines/<project>            (first run only)
 ├─ create the mount points inside the container, owned by you
 ├─ install devbox-start.service into the container and enable it
 ├─ render devbox.nspawn → /run/systemd/nspawn/<project>.nspawn
 ├─ copy limits.conf  → /run/systemd/system/systemd-nspawn@<project>.service.d/
 ├─ systemctl daemon-reload
 └─ machinectl start <project>
     └─ systemd-nspawn@<project>.service              (stock unit, plus limits.conf)
         └─ systemd-nspawn --boot --network-veth -U --settings=override --machine=<project>
             │    --settings=override: the .nspawn file wins over these flags,
             │    so Private=no and VirtualEthernet=no switch the veth off
             └─ systemd (PID 1 inside the container)
                 └─ multi-user.target
                     └─ devbox-start.service → on-start.sh   (as you, in the project folder)
```

Creating the mount points first matters: nspawn creates missing mount-point folders as root.
For this repo that would make `~/.local/share` inside the container root-owned and break every tool that writes there.

### Paths and users

The project and its Claude project folder are mounted at the paths they have on the host, and you exist inside as the same user (name, UID, home):

```
 host                                               container
 ────                                               ─────────
 /home/me/src/app              ══ Bind (idmap) ══▶  /home/me/src/app
 /home/me/.claude/projects/                         /home/me/.claude/projects/
   -home-me-src-app            ══ Bind (idmap) ══▶    -home-me-src-app
 /var/lib/machines/app         ══ root filesystem ═▶ /
```

Claude names a project's folder after its working directory, with every non-alphanumeric character replaced by `-`.
Same path, same folder name, so Claude inside and outside the container uses the same project folder and no `claude-path` mapping is needed.
Consequence: memory and `/resume` history are shared between host and container sessions.

This is possible with devcontainers too: the spec has `workspaceMount` and `workspaceFolder`, and crib 0.10.0 parses both (seen in its binary; not tried):

```jsonc
"workspaceMount": "type=bind,source=${localWorkspaceFolder},target=${localWorkspaceFolder}",
"workspaceFolder": "${localWorkspaceFolder}"
```

UIDs are mapped in three places:

```
 PrivateUsers=pick         processes: container UID z runs as host UID N+z
                           (N = a free 65536-UID range picked at start, never 0)
                           so root inside the container is an unprivileged host user

 PrivateUsersOwnership=map root filesystem: a file owned by z on disk appears owned by z inside,
                           through an ID-mapped mount; nothing is chowned

 Bind=...:idmap            project folders: container UID z reads and writes as host UID z,
                           so files you create in the project are owned by you on the host
```

Without `idmap`, host files on a bind mount would appear owned by `nobody` inside the container.

### Network

`devbox.nspawn` sets `Private=no` and `VirtualEthernet=no`: the container shares the host's network.

```
 Private=no (this example)               VirtualEthernet=yes (stock default)
 ─────────────────────────               ───────────────────────────────────
 host network namespace                  host                  container
 ┌──────────────────────────┐            ┌──────────┐  veth  ┌──────────┐
 │ host processes           │            │ ve-app   │◀──────▶│ host0    │
 │ container processes      │            └──────────┘        └──────────┘
 │ :8080 inside = :8080     │            DHCP needs systemd-networkd on host and inside;
 └──────────────────────────┘            ports reach the host only through Port=
 no forwarding, no isolation             isolated
```

## devcontainer.json to nspawn

| devcontainer.json                | nspawn equivalent                                                        |
| -------------------------------- | ------------------------------------------------------------------------ |
| `image`, `build`                 | a root filesystem: `pacstrap` (here), `debootstrap`, mkosi, `importctl pull-oci` |
| `features`                       | packages and steps in `devbox bootstrap`                                 |
| `remoteUser`                     | user created in `bootstrap` with your name, UID and home                 |
| `mounts`                         | `Bind=` / `BindReadOnly=` in `devbox.nspawn`                             |
| workspace mount                  | `Bind=@WORKSPACE@:@WORKSPACE@:idmap`                                     |
| `runArgs: --memory, --cpus`      | `MemoryMax=`, `CPUQuota=` in `limits.conf`                               |
| `runArgs: --pids-limit`          | nothing to do: the stock unit sets `TasksMax=16384`                      |
| `runArgs: --cap-add`             | `Capability=` in `[Exec]`                                                |
| `forwardPorts`                   | nothing with `Private=no`; `Port=` with a private network                |
| `containerEnv`, `remoteEnv`      | `Environment=` reaches only PID 1 (systemd), not your shell: use dotfiles |
| `initializeCommand`              | `ExecStartPre=` in `limits.conf` (runs as root on the host)              |
| `postCreateCommand`              | `devbox bootstrap`                                                       |
| `postStartCommand`               | `devbox-start.service`                                                   |
| `crib up` / `shell` / `down`     | `devbox up` / `shell` / `down`                                           |
| dotfiles                         | not handled: clone them inside, or add a step to `bootstrap`             |

## Using it

### Requirements

- Arch Linux with `arch-install-scripts` (for `pacstrap`) and sudo.
- The project lives under your home directory, in a folder whose name is a valid hostname (`my-app`, not `my_app`).
  The folder name is the machine name, so two projects with the same folder name share one container.
- `/var/lib/machines` and your home directory on filesystems with ID-mapped mount support (ext4, btrfs, xfs).

### Commands

Copy this folder to `<project>/.devcontainer/nspawn/` and run the script from anywhere:

```bash
.devcontainer/nspawn/devbox bootstrap   # once per host: builds /var/lib/machines/devbox-base
.devcontainer/nspawn/devbox render      # prints the .nspawn file `up` will install
.devcontainer/nspawn/devbox up          # clones the base for this project and boots it
.devcontainer/nspawn/devbox shell       # zsh as you, in the project folder
journalctl -M <project> -u devbox-start # did the start hook run?
.devcontainer/nspawn/devbox down        # stops it and removes the /run files
```

```
 bootstrap ──▶ up ──▶ shell ──▶ down ──▶ up …        (edit a file here: down, then up)
 (once)         │                  │
                └─ first run clones └─ sudo machinectl remove <project>
                   the base            deletes the container system; the project
                                       and Claude folders are bind mounts and stay
```

`up` refuses to run while the container is running.

### Caveats

- The script and the `.nspawn` file run as root. A `Bind=` line can mount any host path, so review them like any script you run with sudo.
  Rootless podman could only reach what your user can.
- The container shares the host network: ports inside are ports on the host, with no forwarding and no isolation.
- Host and container Claude sessions share one project folder.
- Running `up` in the few seconds while the container is still booting fails with nspawn's "directory busy" error. Run it again once it has started.
- macOS is not supported: nspawn needs a Linux kernel and systemd on the host.

## Tools around nspawn

| Tool                      | What it is                                                                      | For per-project dev boxes                    |
| ------------------------- | ------------------------------------------------------------------------------- | -------------------------------------------- |
| `machinectl`, `importctl` | part of systemd: pull, clone, start, stop, shell into machines                  | manages machines per host, not per project   |
| mkosi                     | systemd's image builder: a `mkosi.conf` per project; `mkosi shell` and `mkosi boot` run the image with nspawn | the closest to "a Dockerfile for nspawn"     |
| rkt                       | CoreOS container runtime that used nspawn internally                            | dead, archived in 2020                       |

mkosi is a maintained, declarative format kept in the repo, with Arch, Debian and Fedora support.
Its job is building OS images, not dev environments: `RuntimeTrees=` mounts a host folder into the container, but maps your user to root inside, so you lose the "same user" part.
Checked against mkosi's upstream docs, not an installed version.

Related, but not nspawn:

- **Podman Quadlet:** systemd unit files (`.container`) that run OCI containers. systemd-style declaration with standard images, aimed at long-running services rather than dev shells.
- **distrobox, toolbox:** run on podman. They mount your whole home directory at the same path as the same user, so matching paths come for free.
  The cost is almost no isolation: the container sees all of your home, including `~/.ssh`.

## When to pick which

```
 Need macOS, other people, CI or editor integration?
   └─ yes ─▶ OCI (podman) + devcontainer.json
   └─ no
       Need a full systemd inside (units, journal, timers), and fine with root?
         └─ no  ─▶ OCI (podman) + devcontainer.json
         └─ yes
             Want the image declared in a standard format?
               └─ yes ─▶ mkosi
               └─ no  ─▶ plain nspawn, like this folder
```

## Sources

Checked on 2026-11-19:

- `man 1 systemd-nspawn`, `man 5 systemd.nspawn`, `man 1 machinectl`, `man 1 importctl` for systemd 260.5.
- The stock `systemd-nspawn@.service` shipped with systemd 260.5: `--network-veth -U --settings=override`, `TasksMax=16384`.
- `strings` on the crib 0.10.0 binary for `workspaceMount` and `workspaceFolder`.
- mkosi's upstream man page (`mkosi.1.md`) for `shell`, `boot` and `RuntimeTrees=`.
- Upstream `pacstrap` (arch-install-scripts): the target folder must already exist.
