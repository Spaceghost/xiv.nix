{ writeShellApplication, python3, pciutils }:

writeShellApplication {
  name = "xiv-nix";
  runtimeInputs = [ python3 pciutils ];
  text = ''
    exec python3 -I ${../scripts/xiv-nix.py} "$@"
  '';
}
