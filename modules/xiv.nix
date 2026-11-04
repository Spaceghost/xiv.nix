# Home Manager module: programs.xiv
#
# XIVLauncher and Dalamud rewrite their own config files, so nothing here is a
# read-only symlink. Activation merges only the declared keys into the live
# files (with a timestamped backup) and refuses to touch anything while the
# game is running.
{ pins }:
{ config, lib, pkgs, ... }:

let
  cfg = config.programs.xiv;
  inherit (lib) mkOption mkEnableOption mkIf types;

  releasePkgs = import ../pkgs/plugins.nix { inherit (pkgs) lib stdenvNoCC fetchurl unzip; inherit pins; };
  xiv-nix = pkgs.callPackage ../pkgs/xiv-nix.nix { };

  pluginType = types.submodule ({ name, ... }: {
    options = {
      enable = mkOption { type = types.bool; default = true; };
      source = mkOption {
        type = types.enum [ "release" "local" ];
        default = if pins ? ${name} then "release" else "local";
        description = ''
          release: the GitHub release pinned in pins.json, copied into
          ''${dataDir}/xivnix/plugins/<name>. local: load ''${path}/<name>.dll
          as-is (your own dev build).
        '';
      };
      path = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Directory holding <name>.dll, for source = local.";
      };
    };
  });

  manifest = {
    inherit (cfg) dataDir thirdPartyPlugins gpu cpu;
    launcher = {
      inherit (cfg.launcher) kind settings;
      flatpak = { inherit (cfg.launcher.flatpak) appId install remote env; };
    };
    thirdPartyRepos = cfg.thirdPartyRepos;
    plugins = lib.mapAttrs (name: p: {
      inherit (p) enable source;
      path =
        if p.source == "release" then
          (if pins ? ${name} then "${releasePkgs.${name}}" else throw "programs.xiv.plugins.${name}: no pin in pins.json")
        else if p.path == null then throw "programs.xiv.plugins.${name}: source = local needs path"
        else p.path;
      tag = if p.source == "release" then pins.${name}.tag else null;
    }) cfg.plugins;
  };
  manifestFile = pkgs.writeText "xiv-nix-manifest.json" (builtins.toJSON manifest);
in
{
  options.programs.xiv = {
    enable = mkEnableOption "declarative FFXIV (XIVLauncher + Dalamud)";

    dataDir = mkOption {
      type = types.str;
      default = "${config.home.homeDirectory}/.xlcore";
      description = "XIVLauncher data dir (holds launcher.ini, dalamudConfig.json).";
    };

    launcher = {
      kind = mkOption {
        type = types.enum [ "flatpak" "nix" "none" ];
        default = "flatpak";
        description = ''
          flatpak works on every distro and is the default. nix installs
          pkgs.xivlauncher (best on NixOS; on other distros it needs a working
          host GL/Vulkan, which is untested here). none leaves the launcher alone.
        '';
      };
      flatpak = {
        appId = mkOption { type = types.str; default = "dev.goats.xivlauncher"; };
        remote = mkOption { type = types.str; default = "flathub"; };
        install = mkOption {
          type = types.bool;
          default = true;
          description = "flatpak install --user when the app is missing at every scope.";
        };
        env = mkOption {
          type = types.attrsOf types.str;
          default = { };
          description = "Merged into the user flatpak override [Environment].";
        };
      };
      settings = mkOption {
        type = types.attrsOf (types.oneOf [ types.str types.bool types.int ]);
        default = { };
        example = { DalamudEnabled = true; WineSyncType = "FSync"; };
        description = "launcher.ini keys to enforce; every other key is left alone.";
      };
    };

    gpu = {
      prefer = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [ "RTX 4060" "RTX 3070" ];
        description = ''
          Cards to run the game on, best first, matched as substrings of the
          PCI name. Checked at every launch, so a card that is only sometimes
          present (eGPU, Graphics Amplifier) is used when it is there and
          skipped when it is not. Sets DXVK_FILTER_DEVICE_NAME.
        '';
      };
      offload = mkOption {
        type = types.enum [ "none" "nvidia" "mesa" ];
        default = "none";
        description = ''
          Hybrid laptops: nvidia = PRIME render offload env vars; mesa =
          DRI_PRIME pointing at the chosen card. Leave none when every
          display-capable GPU is a discrete card.
        '';
      };
    };

    cpu = {
      cores = mkOption {
        type = types.nullOr (types.either (types.enum [ "half" ]) (types.listOf types.int));
        default = null;
        example = "half";
        description = ''
          Pin XIVLauncher, Wine and the game to these logical CPUs. "half" =
          half the physical cores (P-cores first on hybrid CPUs) plus their
          SMT siblings, worked out on the machine at launch time.
        '';
      };
      wineTopology = mkOption {
        type = types.bool;
        default = true;
        description = "Also set WINE_CPU_TOPOLOGY so the game sizes its thread pools to the pinned set.";
      };
    };

    plugins = mkOption {
      type = types.attrsOf pluginType;
      default = { };
      description = "Dalamud plugins loaded as dev plugins, keyed by InternalName.";
    };

    thirdPartyRepos = mkOption {
      type = types.listOf (types.submodule {
        options = {
          url = mkOption { type = types.str; };
          enable = mkOption { type = types.bool; default = true; };
        };
      });
      default = [ ];
    };

    thirdPartyPlugins = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = ''
        InternalNames you expect Dalamud to have installed from its repos.
        Dalamud installs and auto-updates these itself; `xiv-nix doctor` lists
        the missing ones so a new machine can be brought up to match.
      '';
    };
  };

  config = mkIf cfg.enable {
    home.packages = [ xiv-nix ] ++ lib.optional (cfg.launcher.kind == "nix") pkgs.xivlauncher;

    home.activation.xivNix = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      run ${xiv-nix}/bin/xiv-nix apply ${manifestFile} ''${DRY_RUN:+--dry-run} ''${VERBOSE:+--verbose}
    '';

    home.file.".config/xiv-nix/manifest.json".source = manifestFile;

    # Same desktop-file id as the flatpak's export, written to
    # ~/.local/share/applications (XDG_DATA_HOME beats every XDG_DATA_DIRS
    # entry on any distro), so the menu and anything launching by id goes
    # through xiv-nix launch.
    xdg.dataFile = mkIf (cfg.launcher.kind != "none" && (cfg.gpu.prefer != [ ] || cfg.cpu.cores != null)) (
      let id = if cfg.launcher.kind == "flatpak" then cfg.launcher.flatpak.appId else "xivlauncher";
      in {
        "applications/${id}.desktop".text = ''
          [Desktop Entry]
          Type=Application
          Name=XIVLauncher
          Comment=FINAL FANTASY XIV launcher (xiv.nix: GPU choice + CPU pinning)
          Exec=${xiv-nix}/bin/xiv-nix launch
          Icon=${id}
          Categories=Game;
          Terminal=false
        '';
      });
  };
}
