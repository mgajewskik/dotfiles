# The commands that build and run this project's agentbox container, defined in container/flake.nix. They run from
# my approved copy of this folder, ~/.local/state/agentbox/<name>/, never from the project, where the agent could edit
# them:
#
#   first time, after reading this folder:   cd .agentbox && devenv shell box-approve
#   from then on:                            cd ~/.local/state/agentbox/<name> && devenv shell <command>
#
#   box-approve   review changes to the project's .agentbox and copy them to the approved copy
#   box-up        create the container if needed, start it, apply my dotfiles on its first start
#   box-update    rebuild it from the approved definition; a running container switches in place
#   box-shell     ssh into it, in the project
#   box-desktop   print the addresses of its desktop and the agent's browser
#   box-apply     apply my dotfiles inside again
#   box-stop      stop it
#   box-destroy   delete it and its home (logins); the project and the approved copy stay
#
# Each command is the shared part below plus its own lines. Generated from bash files and checked with shellcheck;
# see ../../agentbox.md.
{ pkgs, ... }:

let
  common = ''
    # shellcheck disable=SC2034
    set -euo pipefail

    die() {
      echo "agentbox: $*" >&2
      exit 1
    }

    user=$(id -un)
    state_dir="$HOME/.local/state/agentbox"
    dotfiles="''${AGENTBOX_DOTFILES:-$HOME/.local/share/chezmoi}"
    dotfiles_export="$HOME/.cache/agentbox/dotfiles"
    key="$HOME/.ssh/agentbox_ed25519"
    known_hosts="$HOME/.ssh/agentbox_known_hosts"
    container_path=/run/current-system/sw/bin
    # what devenv itself writes next to this file, and the copy's own record of its project
    not_definition=(--exclude=.devenv --exclude='.devenv.*' --exclude=devenv.lock --exclude=.project)

    # This folder is either the project's .agentbox, which the agent can edit, or my approved copy of it, which only
    # box-approve writes. Every command but a first box-approve runs from the copy.
    if [[ -f "$DEVENV_ROOT/.project" ]]; then
      project=$(cat "$DEVENV_ROOT/.project")
      from_copy=1
    else
      project=$(dirname "$DEVENV_ROOT")
      from_copy=""
    fi
    [[ "$project" != *[[:space:]:]* ]] || die "$project: nspawn's --bind cannot take spaces or colons"
    name=''${project##*/}
    name=''${name,,}
    name=''${name//[^a-z0-9]/-}
    name=''${name:0:11}
    while [[ "$name" == -* ]]; do name=''${name#-}; done
    while [[ "$name" == *- ]]; do name=''${name%-}; done
    [[ -n "$name" ]] || die "cannot make a container name from $project"
    copy="$state_dir/$name"
    conf="/etc/nixos-containers/$name.conf"
    root="/var/lib/nixos-containers/$name"
    flake="path:$copy/container"

    require_copy() {
      [[ -n "$from_copy" ]] || die "run this from my approved copy: cd $copy && devenv shell $1"
    }

    running() { [[ "$(nixos-container status "$name")" == up ]]; }

    in_container() { sudo nixos-container run "$name" -- "$container_path/env" "PATH=$container_path" "$@"; }

    as_user() { in_container runuser -l "$user" -c "$1"; }

    recorded_project() { sed -n 's/^AGENTBOX_PROJECT=//p' "$conf"; }

    require_container() {
      [[ -e "$conf" ]] || die "no container $name; run: box-up"
      [[ "$(recorded_project)" == "$project" ]] || die "container $name belongs to $(recorded_project)"
    }

    # nixos-container builds into "$systemPath.tmp" with $systemPath unset, so as root it would leave a .tmp link in the
    # current directory (nixpkgs 26.05 nixos-container.pl)
    container_build() { (cd / && sudo nixos-container "$@"); }

    export_dotfiles() {
      mkdir -p "$dotfiles_export"
      find "$dotfiles_export" -mindepth 1 -delete
      git -C "$dotfiles" ls-files -z --cached --others --exclude-standard |
        tar -C "$dotfiles" --null -T - --ignore-failed-read -cf - 2>/dev/null |
        tar -C "$dotfiles_export" -xf -
      # chezmoi init runs git init in a source directory without a repository, which fails on the read-only mount
      git -C "$dotfiles_export" init -q
    }

    expand_path() {
      local path=$1
      path=''${path/#\~/$HOME}
      path=''${path//\{key\}/''${project//[^A-Za-z0-9]/-}}
      printf '%s\n' "$path"
    }

    # agentbox.mounts from the approved flake, checked and expanded to "mode host-path path-inside" lines
    declared_mounts() {
      local LC_ALL=C json mode source target i j
      local -a modes=() sources=() targets=()
      json=$(nix eval --json "$flake#agentbox.mounts")
      while IFS=$'\t' read -r mode source target; do
        [[ "$mode" == rw || "$mode" == ro ]] || die "agentbox.mounts: the mode is rw or ro, not $mode"
        # nspawn interprets backslashes in --bind, and these paths end up in my terminal
        [[ "$source" =~ ^[A-Za-z0-9._/~{}+@=,-]+$ && "$target" =~ ^[A-Za-z0-9._/~{}+@=,-]+$ ]] ||
          die "agentbox.mounts: paths may hold only letters, digits and ._/~{}+@=,-"
        source=$(expand_path "$source")
        target=$(expand_path "$target")
        [[ "$source" == /* && "$target" == /* ]] || die "agentbox.mounts: paths start with / or ~"
        source=$(realpath -m -- "$source")
        target=$(realpath -m -s -- "$target")
        # the agent can write the project, so a host path there could become a symlink to anything after I approved it
        [[ "$source" != "$project" && "$source" != "$project"/* ]] || die "agentbox.mounts: $source is inside the project"
        [[ "$target" != "$project" && "$target" != "$project"/* ]] || die "agentbox.mounts: $target is inside the project"
        modes+=("$mode")
        sources+=("$source")
        targets+=("$target")
      done < <(jq -r '.[] | [.mode, .host, (.inside // .host)] | @tsv' <<<"$json")
      for i in "''${!sources[@]}"; do
        for j in "''${!sources[@]}"; do
          if [[ "$i" != "$j" && "''${modes[j]}" == rw && "''${sources[i]}" == "''${sources[j]}"/* ]]; then
            die "agentbox.mounts: ''${sources[i]} is inside ''${sources[j]}, which the agent can write"
          fi
        done
      done
      for i in "''${!sources[@]}"; do
        printf '%s %s %s\n' "''${modes[i]}" "''${sources[i]}" "''${targets[i]}"
      done
    }

    all_mounts() {
      echo "rw $project $project"
      [[ "$project" == "$dotfiles" ]] || echo "ro $dotfiles_export $dotfiles"
      declared_mounts
    }

    conf_changed=""

    write_conf() {
      local binds="" mode source target wanted
      while read -r mode source target; do
        [[ -e "$source" ]] || mkdir -p "$source"
        if [[ "$mode" == rw ]]; then binds+=" --bind=$source:$target:idmap"; else binds+=" --bind-ro=$source:$target:idmap"; fi
      done <<<"$1"
      binds=''${binds# }
      wanted=$(
        grep -vE '^(AGENTBOX_PROJECT|PRIVATE_USERS|EXTRA_NSPAWN_FLAGS)=' "$conf" || true
        printf 'AGENTBOX_PROJECT=%s\nPRIVATE_USERS=pick\nEXTRA_NSPAWN_FLAGS="%s"\n' "$project" "$binds"
      )
      conf_changed=""
      [[ "$wanted" != "$(cat "$conf")" ]] || return 0
      printf '%s\n' "$wanted" | sudo tee "$conf" >/dev/null
      conf_changed=1
    }

    # nspawn resolves a mount point inside the container's root and follows symlinks there, so a symlink the agent planted
    # on the way could land an rw mount where container root reads, e.g. among systemd units. Checked while the container
    # is stopped, so nothing inside can change it before the start.
    check_mount_points() {
      local target path part
      local -a parts
      for target; do
        path=""
        IFS=/ read -ra parts <<<"''${target#/}"
        for part in "''${parts[@]}"; do
          path+="/$part"
          if sudo test -L "$root$path"; then die "$path in the container is a symlink; remove it before box-up mounts over it"; fi
        done
      done
    }

    # nspawn creates missing mount points as root, so their folders under my home would block the agent user. This runs as
    # root over the agent's home: a folder the agent replaced with a symlink is skipped, not followed.
    own_mount_parents() {
      # shellcheck disable=SC2016
      in_container sh -c '
        user=$1
        shift
        home=$(getent passwd "$user" | cut -d: -f6)
        for target; do
          dir=$(dirname "$target")
          parents=""
          while [ "''${dir#"$home"}" != "$dir" ]; do
            parents="$dir $parents"
            [ "$dir" = "$home" ] && break
            dir=$(dirname "$dir")
          done
          for dir in $parents; do
            [ -L "$dir" ] && break
            [ "$(stat -c %u "$dir")" = 0 ] && chown -h "$user:users" "$dir"
          done
        done
      ' sh "$user" "$@"
    }

    record_project() {
      # shellcheck disable=SC2016
      in_container sh -c 'mkdir -p /var/lib/agentbox && printf "%s\n" "$1" > /var/lib/agentbox/project' sh "$project"
    }

    authorize_key() {
      [[ -f "$key" ]] || ssh-keygen -q -t ed25519 -N ''' -C agentbox -f "$key"
      as_user 'umask 077 && mkdir -p ~/.ssh && cat > ~/.ssh/authorized_keys' <"$key.pub"
    }

    write_ssh_config() {
      local ip
      ip=$(nixos-container show-ip "$name")
      mkdir -p "$HOME/.ssh/config.d"
      cat >"$HOME/.ssh/config.d/agentbox-$name" <<EOF
    Host agentbox-$name
      HostName $ip
      User $user
      IdentityFile $key
      IdentitiesOnly yes
      ForwardAgent no
      UserKnownHostsFile $known_hosts
      StrictHostKeyChecking accept-new
    EOF
    }

    apply_dotfiles() {
      [[ "$project" == "$dotfiles" ]] || export_dotfiles
      as_user "chezmoi init --apply --source $(printf %q "$dotfiles")"
      if [[ -e "$project/devenv.nix" || -e "$project/devenv.yaml" ]]; then
        as_user "cd $(printf %q "$project") && devenv allow"
      fi
      in_container systemctl restart herdr-server
    }
  '';
in
{
  packages = with pkgs; [
    jq
    rsync
    diffutils
  ];

  scripts.box-approve = {
    description = "review changes to the project's .agentbox and copy them to my approved copy";
    exec = common + ''
      source_dir="$project/.agentbox"
      if [[ -z "$from_copy" && -d "$copy" ]]; then die "$name has an approved copy; review from it: cd $copy && devenv shell box-approve"; fi
      [[ -d "$source_dir" ]] || die "$source_dir does not exist"
      odd=$(find "$source_dir" \( -name .devenv -o -name '.devenv.*' \) -prune -o ! -type f ! -type d -print)
      [[ -z "$odd" ]] || die "$source_dir holds links or special files, which box-approve does not copy: $(cat -v <<<"$odd")"
      # the agent can keep editing .agentbox, so I review and install one snapshot of it, taken first
      staging=$(mktemp -d)
      trap 'rm -rf "$staging"' EXIT
      rsync -a "''${not_definition[@]}" "$source_dir/" "$staging/"
      base="$copy"
      [[ -d "$base" ]] || base=$(mktemp -d)
      changes=$(diff -ruN "''${not_definition[@]}" "$base" "$staging" || true)
      if [[ -z "$changes" ]]; then
        echo "agentbox: the approved copy of $name is up to date"
        exit 0
      fi
      # cat -v shows escape sequences as text, so the agent cannot redraw what I am reading
      cat -v <<<"$changes"
      [[ -t 0 ]] || die "approve in a terminal"
      read -rp "approve these changes to $name's container? [y/N] " answer
      [[ "$answer" == [yY] ]] || die "not approved; nothing changed"
      mkdir -p "$copy"
      rsync -a --delete "''${not_definition[@]}" "$staging/" "$copy/"
      printf '%s\n' "$project" >"$copy/.project"
      echo "agentbox: approved; from now on run the commands from the copy: cd $copy && devenv shell box-up"
    '';
  };

  scripts.box-up = {
    description = "create the container if needed, start it, apply my dotfiles on its first start";
    exec = common + ''
      require_copy box-up
      if ! diff -rq "''${not_definition[@]}" "$copy" "$project/.agentbox" >/dev/null 2>&1; then
        echo "agentbox: $project/.agentbox differs from the approved copy, which box-up uses; box-approve reviews it" >&2
      fi
      created=""
      if [[ ! -e "$conf" ]]; then
        container_build create "$name" --flake "$flake"
        created=1
      fi
      recorded=$(recorded_project)
      if [[ -z "$recorded" && -z "$created" ]]; then die "$name is not an agentbox container"; fi
      if [[ -n "$recorded" && "$recorded" != "$project" ]]; then die "container $name belongs to $recorded"; fi
      mounts=$(all_mounts)
      [[ "$project" == "$dotfiles" ]] || export_dotfiles
      write_conf "$mounts"
      mapfile -t targets < <(cut -d' ' -f3 <<<"$mounts")
      if [[ -n "$conf_changed" ]] && running; then sudo nixos-container stop "$name"; fi
      if ! running; then
        check_mount_points "''${targets[@]}"
        sudo nixos-container start "$name"
      fi
      own_mount_parents "''${targets[@]}"
      record_project
      authorize_key
      write_ssh_config
      if ! as_user 'test -f ~/.config/chezmoi/chezmoi.toml'; then apply_dotfiles; fi
      echo "agentbox: $name is up; box-shell, or ssh agentbox-$name"
    '';
  };

  scripts.box-update = {
    description = "rebuild the container from the approved definition; a running one switches to it in place";
    exec = common + ''
      require_copy box-update
      require_container
      container_build update "$name" --flake "$flake"
    '';
  };

  scripts.box-shell = {
    description = "ssh into the container, in the project";
    exec = common + ''
      require_copy box-shell
      require_container
      running || die "$name is stopped; run: box-up"
      ssh -t -i "$key" -o IdentitiesOnly=yes -o ForwardAgent=no -o UserKnownHostsFile="$known_hosts" \
        -o StrictHostKeyChecking=accept-new "$user@$(nixos-container show-ip "$name")" \
        "cd $(printf %q "$project") && exec \$SHELL -l"
    '';
  };

  scripts.box-desktop = {
    description = "print the addresses of the container's desktop";
    exec = common + ''
      require_copy box-desktop
      require_container
      ip=$(nixos-container show-ip "$name")
      echo "noVNC:    http://$ip:6080/vnc.html?autoconnect=1&resize=remote (password: vscode)"
      echo "TigerVNC: vncviewer $ip:5901 (password: vscode)"
    '';
  };

  scripts.box-apply = {
    description = "apply my dotfiles inside again";
    exec = common + ''
      require_copy box-apply
      require_container
      apply_dotfiles
    '';
  };

  scripts.box-stop = {
    description = "stop the container";
    exec = common + ''
      require_copy box-stop
      require_container
      sudo nixos-container stop "$name"
    '';
  };

  scripts.box-destroy = {
    description = "delete the container and its home (logins); the project and the approved copy stay";
    exec = common + ''
      require_copy box-destroy
      require_container
      ip=$(nixos-container show-ip "$name")
      read -rp "delete container $name and its home (logins)? [y/N] " answer
      [[ "$answer" == [yY] ]] || exit 0
      sudo nixos-container destroy "$name"
      rm -f "$HOME/.ssh/config.d/agentbox-$name"
      [[ ! -f "$known_hosts" ]] || ssh-keygen -q -R "$ip" -f "$known_hosts" >/dev/null
    '';
  };
}
