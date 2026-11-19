{
  flake.modules.nixos.desktop =
    { lib, pkgs, ... }:
    {
      programs.sway = {
        enable = true;
        wrapperFeatures.gtk = true;
        extraPackages = with pkgs; [
          swaybg
          swayidle
          swaylock
          grim
          slurp
          satty
          wl-clipboard
          brightnessctl
          playerctl
          libnotify
        ];
      };
      programs.uwsm.enable = true;
      security.soteria.enable = true;
      # soteria needs XDG_SESSION_ID, which uwsm deliberately keeps out of the systemd user environment. Take the session
      # logind elected as the user's display instead.
      systemd.user.services.polkit-soteria.serviceConfig.ExecStart = lib.mkForce (
        pkgs.writeShellScript "soteria-in-display-session" ''
          XDG_SESSION_ID=$(loginctl show-user "$UID" --property=Display --value) exec ${lib.getExe pkgs.soteria}
        ''
      );
      programs.gpu-screen-recorder.enable = true;
      xdg.portal.wlr.settings.screencast = {
        chooser_type = "simple";
        chooser_cmd = "${pkgs.slurp}/bin/slurp -f 'Monitor: %o' -or";
      };

      programs.dconf.profiles.user.databases = [
        {
          settings."org/gnome/desktop/interface" = {
            color-scheme = "prefer-dark";
            gtk-theme = "Arc-Dark";
            icon-theme = "Papirus-Dark";
            cursor-theme = "phinger-cursors-light";
            cursor-size = lib.gvariant.mkInt32 24;
            font-name = "JetBrainsMono Nerd Font 10";
            monospace-font-name = "JetBrainsMono Nerd Font 10";
          };
        }
      ];

      services.udisks2.enable = true;
      services.gvfs.enable = true;

      systemd.packages = [ pkgs.mako ];
      systemd.user.services.mako.wantedBy = [ "graphical-session.target" ];
      # vicinae installs its unit in share/systemd/user, which systemd.packages does not read (nixos/lib/systemd-lib.nix).
      # Switch to systemd.packages once the vicinae package installs it under lib/systemd/user.
      systemd.user.services.vicinae = {
        description = "Vicinae Launcher Daemon";
        requires = [ "dbus.socket" ];
        after = [ "graphical-session.target" ];
        partOf = [ "graphical-session.target" ];
        wantedBy = [ "graphical-session.target" ];
        # NixOS pins every generated unit's PATH to coreutils and friends. vicinae starts apps by the bare names in their
        # desktop entries (firefox, bitwarden, claude-desktop), so it needs the session PATH from environment.d instead.
        environment.PATH = lib.mkForce null;
        serviceConfig = {
          ExecStart = "${pkgs.vicinae}/bin/vicinae server --replace";
          ExecReload = "${pkgs.coreutils}/bin/kill -HUP $MAINPID";
          Restart = "always";
          RestartSec = 60;
          KillMode = "process";
        };
      };

      fonts.packages = with pkgs; [
        noto-fonts
        noto-fonts-cjk-sans
        noto-fonts-color-emoji
        jetbrains-mono
        nerd-fonts.jetbrains-mono
        nerd-fonts.symbols-only
      ];
      fonts.fontconfig.defaultFonts.monospace = [ "JetBrainsMono Nerd Font" ];

      environment.systemPackages = with pkgs; [
        waybar
        mako
        vicinae
        wl-clip-persist
        wlsunset
        wlr-randr
        wtype
        wev
        wlogout
        nwg-displays
        nwg-look
        papirus-icon-theme
        phinger-cursors
        arc-theme
        xdg-utils
      ];
    };
}
