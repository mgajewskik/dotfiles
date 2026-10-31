{
  stdenvNoCC,
  fetchurl,
  buildFHSEnv,
  appimageTools,
}:

let
  version = "0.20.2.1";

  unpacked = stdenvNoCC.mkDerivation {
    pname = "helium-unpacked";
    inherit version;
    src = fetchurl {
      url = "https://github.com/imputnet/helium-linux/releases/download/${version}/helium-${version}-x86_64_linux.tar.xz";
      hash = "sha256-upKssn7GzaNqi5SOIVQAmq7g1jMiKtJEviXnNqFD5vo=";
    };
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
