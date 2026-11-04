{
  description = "xiv.nix — declarative FFXIV: XIVLauncher, Dalamud config, and pinned plugins, on any distro";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, home-manager }:
    let
      systems = [ "x86_64-linux" ];
      forAll = f: nixpkgs.lib.genAttrs systems (s: f nixpkgs.legacyPackages.${s});
      pins = builtins.fromJSON (builtins.readFile ./pins.json);
    in
    {
      homeManagerModules.default = import ./modules/xiv.nix { inherit pins; };
      homeManagerModules.xiv = self.homeManagerModules.default;

      packages = forAll (pkgs:
        let plugins = pkgs.callPackage ./pkgs/plugins.nix { inherit pins; };
        in plugins // {
          xiv-nix = pkgs.callPackage ./pkgs/xiv-nix.nix { };
          default = self.packages.${pkgs.system}.xiv-nix;
        });

      apps = forAll (pkgs: {
        default = { type = "app"; program = "${self.packages.${pkgs.system}.xiv-nix}/bin/xiv-nix"; };
      });

      # Bazzite alienware box. Rebuild: nix run .#switch  (or home-manager switch --flake .#jack@alienware)
      homeConfigurations."jack@alienware" = home-manager.lib.homeManagerConfiguration {
        pkgs = nixpkgs.legacyPackages.x86_64-linux;
        modules = [ self.homeManagerModules.default ./hosts/alienware.nix ];
      };

      checks = forAll (pkgs: {
        alienware = self.homeConfigurations."jack@alienware".activationPackage;
        plugins = pkgs.linkFarm "xiv-plugins"
          (nixpkgs.lib.mapAttrsToList (name: path: { inherit name path; })
            (pkgs.callPackage ./pkgs/plugins.nix { inherit pins; }));
      });
    };
}
