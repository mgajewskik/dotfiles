{
  stdenvNoCC,
  fetchurl,
  dpkg,
  buildFHSEnv,
  appimageTools,
}:

let
  version = "0.77.0";
  commit = "fe85646036572e2b9a531b337a0dcb56a32f9369";

  unpacked = stdenvNoCC.mkDerivation {
    pname = "grok-bot-unpacked";
    inherit version;
    src = fetchurl {
      url = "https://downloads.cursor.com/grokbot/stable/${commit}/linux/x64/grok-bot_${version}_amd64.deb";
      hash = "sha256-t08SXmrfOiXSlu+ZpKAEerSxevv8jp/dqg5XHc7+Qzw=";
    };
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
