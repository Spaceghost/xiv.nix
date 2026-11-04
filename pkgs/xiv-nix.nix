{ writeShellApplication, python3 }:

writeShellApplication {
  name = "xiv-nix";
  runtimeInputs = [ python3 ];
  text = ''
    exec python3 -I ${../scripts/xiv-nix.py} "$@"
  '';
}
