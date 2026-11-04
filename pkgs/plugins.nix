# One derivation per pinned plugin release: the release's latest.zip, unpacked flat.
{ lib, stdenvNoCC, fetchurl, unzip, pins }:

lib.mapAttrs (name: pin:
  stdenvNoCC.mkDerivation {
    pname = "dalamud-${lib.toLower name}";
    version = lib.removePrefix "v" pin.tag;
    src = fetchurl {
      url = "https://github.com/${pin.repo}/releases/download/${pin.tag}/latest.zip";
      inherit (pin) hash;
    };
    nativeBuildInputs = [ unzip ];
    unpackPhase = "unzip -q $src -d src";
    installPhase = ''
      test -f src/${name}.dll || { echo "release zip has no ${name}.dll"; exit 1; }
      mkdir -p $out && cp -r src/. $out/
    '';
    meta.description = "${name} Dalamud plugin (${pin.repo} ${pin.tag})";
  }) pins
