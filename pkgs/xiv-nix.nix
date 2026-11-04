{ writeShellApplication, symlinkJoin, python3, pciutils }:

let
  xiv = writeShellApplication {
    name = "xiv";
    runtimeInputs = [ python3 pciutils ];
    text = ''
      exec python3 -I ${../scripts/xiv-nix.py} "$@"
    '';
  };
in
# `xiv` is the everyday command; `xiv-nix` stays as an alias.
symlinkJoin {
  name = "xiv-nix";
  paths = [ xiv ];
  postBuild = "ln -s xiv $out/bin/xiv-nix";
}
