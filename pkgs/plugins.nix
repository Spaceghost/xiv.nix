# One derivation per pinned plugin release: the release's latest.zip (or the
# pin's versioned `asset`, for testing-only releases), unpacked flat.
{ lib, stdenvNoCC, fetchurl, unzip, pins }:

lib.mapAttrs (name: pin:
  stdenvNoCC.mkDerivation {
    pname = "dalamud-${lib.toLower name}";
    version = if pin ? asset then lib.removeSuffix ".zip" (lib.removePrefix "${name}-" pin.asset) else lib.removePrefix "v" pin.tag;
    src = fetchurl {
      url = "https://github.com/${pin.repo}/releases/download/${pin.tag}/${pin.asset or "latest.zip"}";
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
