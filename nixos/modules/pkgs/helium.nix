{ inputs, ... }:
{
  perSystem =
    { pkgs, ... }:
    {
      packages.helium = pkgs.callPackage (
        {
          stdenvNoCC,
          buildFHSEnv,
          appimageTools,
        }:
        let
          inherit (inputs._meta.helium) version;

          unpacked = stdenvNoCC.mkDerivation {
            pname = "helium-unpacked";
            inherit version;
            src = inputs.helium;
            dontFixup = true;
            installPhase = "cp -a . $out";
          };
        in
        buildFHSEnv (
          appimageTools.defaultFhsEnvArgs
          // {
            pname = "helium";
            inherit version;
            executableName = "helium-browser";
            runScript = "${unpacked}/helium-wrapper";
            extraInstallCommands = ''
              mkdir -p $out/share/applications $out/share/icons/hicolor/256x256/apps
              sed 's/^Exec=helium/Exec=helium-browser/' ${unpacked}/helium.desktop > $out/share/applications/helium.desktop
              cp ${unpacked}/product_logo_256.png $out/share/icons/hicolor/256x256/apps/helium.png
            '';
          }
        )
      ) { };
    };
}
