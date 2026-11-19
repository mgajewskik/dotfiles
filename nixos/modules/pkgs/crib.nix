{
  perSystem =
    { pkgs, ... }:
    {
      packages.crib = pkgs.callPackage (
        { stdenvNoCC, fetchurl }:
        stdenvNoCC.mkDerivation rec {
          pname = "crib";
          version = "0.10.0";
          src = fetchurl {
            url = "https://github.com/fgrehm/crib/releases/download/v${version}/crib_linux_amd64.tar.gz";
            hash = "sha256-mmZV/X8BWP+wiFdfJOZlKlbTMSbRfQm0/UTpxP9CAOw=";
          };
          sourceRoot = ".";
          installPhase = "install -Dm755 crib $out/bin/crib";
        }
      ) { };
    };
}
