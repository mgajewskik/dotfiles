{
  flake.modules.nixos.keys =
    { pkgs, ... }:
    {
      services.pcscd.enable = true;
      # pcscd is built with polkit here, and polkit only grants card access inside a login session. scdaemon runs under
      # gpg-agent in the systemd user manager, outside any session, so gpg --card-status is refused without this rule.
      security.polkit.extraConfig = ''
        polkit.addRule(function (action, subject) {
          if ((action.id == "org.debian.pcsc-lite.access_pcsc" || action.id == "org.debian.pcsc-lite.access_card")
              && subject.user == "mgajewskik") {
            return polkit.Result.YES;
          }
        });
      '';
      services.gnome.gnome-keyring.enable = true;
      services.gnome.gcr-ssh-agent.enable = false;
      programs.ssh.startAgent = true;
      programs.gnupg.agent = {
        enable = true;
        pinentryPackage = pkgs.pinentry-gnome3;
      };
    };
}
