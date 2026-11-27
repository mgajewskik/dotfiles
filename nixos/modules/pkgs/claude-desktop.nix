{ inputs, ... }:
{
  perSystem =
    { pkgs, ... }:
    {
      packages.claude-desktop = pkgs.callPackage (
        {
          stdenvNoCC,
          dpkg,
          runCommand,
          buildFHSEnv,
          appimageTools,
          OVMF,
        }:
        let
          inherit (inputs._meta.claude-desktop) version;

          unpacked = stdenvNoCC.mkDerivation {
            pname = "claude-desktop-unpacked";
            inherit version;
            src = inputs.claude-desktop;
            nativeBuildInputs = [ dpkg ];
            dontUnpack = true;
            dontFixup = true;
            # The .deb ships chrome-sandbox setuid root. dpkg-deb -x keeps that mode and the build sandbox refuses it,
            # so tar extracts without it; Chromium then uses its user-namespace sandbox, which NixOS allows.
            installPhase = ''
              mkdir -p $out
              dpkg-deb --fsys-tarfile $src | tar -x --no-same-owner --no-same-permissions -C $out
            '';
          };

          ovmfWithDebianNames = runCommand "ovmf-with-debian-names" { } ''
            mkdir -p $out/share/OVMF
            ln -s ${OVMF.fd}/FV/OVMF_CODE.fd $out/share/OVMF/OVMF_CODE_4M.fd
            ln -s ${OVMF.fd}/FV/OVMF_VARS.fd $out/share/OVMF/OVMF_VARS_4M.fd
          '';
        in
        buildFHSEnv (
          appimageTools.defaultFhsEnvArgs
          // {
            pname = "claude-desktop";
            inherit version;
            targetPkgs =
              pkgs:
              appimageTools.defaultFhsEnvArgs.targetPkgs pkgs
              ++ [
                pkgs.libnotify
                pkgs.libayatana-appindicator
                pkgs.bubblewrap
                pkgs.socat
                pkgs.openssh
                pkgs.qemu_kvm
                pkgs.virtiofsd
                ovmfWithDebianNames
              ];
            runScript = "${unpacked}/usr/lib/claude-desktop/claude-desktop --ozone-platform-hint=auto";
            extraInstallCommands = ''
              mkdir -p $out/share
              cp -r ${unpacked}/usr/share/applications ${unpacked}/usr/share/icons $out/share/
            '';
          }
        )
      ) { };
    };
}
