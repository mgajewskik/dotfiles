{ inputs, ... }:
{
  perSystem =
    { pkgs, ... }:
    {
      packages.grok-bot = pkgs.callPackage (
        {
          stdenvNoCC,
          dpkg,
          buildFHSEnv,
          appimageTools,
        }:
        let
          inherit (inputs._meta.grok-bot) version;

          unpacked = stdenvNoCC.mkDerivation {
            pname = "grok-bot-unpacked";
            inherit version;
            src = inputs.grok-bot;
            nativeBuildInputs = [ dpkg ];
            dontUnpack = true;
            dontFixup = true;
            installPhase = "dpkg-deb -x $src $out";
          };
        in
        buildFHSEnv (
          appimageTools.defaultFhsEnvArgs
          // {
            pname = "grok-bot";
            inherit version;
            targetPkgs =
              pkgs:
              appimageTools.defaultFhsEnvArgs.targetPkgs pkgs
              ++ [
                pkgs.libnotify
                pkgs.libayatana-appindicator
              ];
            runScript = ''"${unpacked}/opt/Grok Bot/grok-bot" --ozone-platform-hint=auto'';
            extraInstallCommands = ''
              mkdir -p $out/share
              cp -r ${unpacked}/usr/share/applications ${unpacked}/usr/share/icons $out/share/
            '';
          }
        )
      ) { };
    };
}
