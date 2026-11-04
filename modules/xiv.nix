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
  xiv = "${xiv-nix}/bin/xiv";

  # The GDM session entry lives outside the store (root installs it once with
  # `xiv install-session`), so it points at the profile path, which every
  # switch updates in place.
  sessionExec = "${config.home.profileDirectory}/bin/ffxiv-session";
  ffxiv-session = pkgs.writeShellScriptBin "ffxiv-session"
    (builtins.replaceStrings [ "@xiv@" "@output@" "@extra@" ]
      [ xiv (if cfg.gamescope.output == null then "" else cfg.gamescope.output) (lib.concatStringsSep " " cfg.gamescope.args) ]
      (builtins.readFile ../scripts/ffxiv-session));

  desktopEntry = { name, exec, comment ? "", icon ? appIcon, terminal ? false, extra ? "" }: ''
    [Desktop Entry]
    Type=Application
    Name=${name}
    Comment=${comment}
    Exec=${exec}
    Icon=${icon}
    Categories=Game;
    Terminal=${lib.boolToString terminal}
    ${extra}'';
  appId = if cfg.launcher.kind == "flatpak" then cfg.launcher.flatpak.appId else "xivlauncher";
  appIcon = appId;
  # Terminal entries wait for Enter so the output stays readable. (Exec only
  # honours double quotes.)
  inTerminal = cmd: ''sh -c "${cmd}; echo; echo Press Enter to close; read -r _"'';

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
    inherit (cfg) dataDir thirdPartyPlugins gpu cpu gamescope;
    self = xiv;
    flake = { inherit (cfg.flake) dir attr push; autoUpdate = cfg.flake.autoUpdate.enable; };
    session = { inherit (cfg.session) enable; exec = sessionExec; };
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
      strict = mkOption {
        type = types.bool;
        default = false;
        description = "Refuse to launch when no card in `prefer` is present, instead of letting DXVK pick (use it to keep a card reserved for something else).";
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

    gamescope = {
      output = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "HDMI-A-2,*";
        description = "gamescope --prefer-output for `xiv gamescope` and the login session.";
      };
      args = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [ "--adaptive-sync" ];
      };
    };

    session = {
      enable = mkEnableOption ''
        the "FFXIV" login-screen session (gamescope on the bare display, only
        XIVLauncher and the game, back to the login screen on exit) and
        ffxiv-session.target. Root installs the login entry once:
        `xiv install-session`
      '';
      wants = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [ "ghostty-agent.service" ];
        description = "User units ffxiv-session.target pulls in (Wants= + After=).";
      };
    };

    flake = {
      dir = mkOption {
        type = types.str;
        default = "${config.home.homeDirectory}/Projects/xiv.nix";
        description = "Checkout of this flake; `xiv switch` / `xiv update` work there.";
      };
      attr = mkOption {
        type = types.str;
        description = "homeConfigurations attribute for this machine, e.g. jack@alienware.";
      };
      push = mkOption {
        type = types.bool;
        default = true;
        description = "`xiv update` pushes its pins/lock commit.";
      };
      autoUpdate = {
        enable = mkEnableOption "a user timer that runs `xiv update --auto`";
        onCalendar = mkOption { type = types.str; default = "daily"; };
      };
    };

    ghosttyAgent = {
      enable = mkEnableOption "the ghostty-agent user service the GhosttyDalamud plugin connects to";
      binary = mkOption {
        type = types.str;
        default = "%h/.local/bin/ghostty-agent";
        description = ''
          The agent executable. The release tarball's build has no Wayland
          compositor; a source build (tools/build-agent.sh) or the distro
          package has it.
        '';
      };
      listen = mkOption {
        type = types.coercedTo types.str lib.toList (types.nonEmptyListOf types.str);
        default = [ "127.0.0.1:7777" ];
        example = [ "127.0.0.1:7777" "100.83.231.2:7777" ];
        description = ''
          HOST:PORT addresses (agent 0.3.2+ takes several). The first must match
          agent.host/port in pluginConfigs/GhosttyDalamud/lua/init.lua; later
          ones (a tailnet address) are retried until they can be opened.
        '';
      };
      windows = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "wayland";
        description = "--windows backend for remote desktop windows.";
      };
      renderNode = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "/dev/dri/by-path/pci-0000:02:00.0-render";
        description = "GHOSTTY_WAYLAND_RENDER_NODE: the GPU the compositor renders on (by-path names survive reboots).";
      };
      extraArgs = mkOption { type = types.listOf types.str; default = [ ]; };
    };

    desktopFiles = mkOption {
      type = types.attrsOf (types.submodule {
        options = {
          name = mkOption { type = types.str; };
          icon = mkOption { type = types.nullOr types.str; default = null; };
        };
      });
      default = { };
      example = { "FINAL FANTASY XIV Online" = { name = "FINAL FANTASY XIV Online"; icon = "steam_icon_39210"; }; };
      description = ''
        Extra launcher entries (file basename -> name/icon) that run `xiv
        launch`, typically to take over a Steam shortcut so it goes through
        Dalamud and the GPU/CPU policy. Existing files are moved to
        *.xivnix-bak by `xiv switch`.
      '';
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
    home.packages = [ xiv-nix ]
      ++ lib.optional (cfg.launcher.kind == "nix") pkgs.xivlauncher
      ++ lib.optional cfg.session.enable ffxiv-session;

    home.activation.xivNix = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      run ${xiv-nix}/bin/xiv-nix apply ${manifestFile} ''${DRY_RUN:+--dry-run} ''${VERBOSE:+--verbose}
    '';

    home.file.".config/xiv-nix/manifest.json".source = manifestFile;

    xdg.dataFile = mkIf (cfg.launcher.kind != "none") ({
      # Same id as the flatpak's own entry; XDG_DATA_HOME beats every
      # XDG_DATA_DIRS entry on any distro, so this one is what menus run.
      "applications/${appId}.desktop".text = desktopEntry {
        name = "XIVLauncher";
        comment = "FINAL FANTASY XIV (Dalamud, preferred GPU, pinned CPUs)";
        exec = "${xiv} launch";
      };
      "applications/xiv-gamescope.desktop".text = desktopEntry {
        name = "FFXIV (gamescope)";
        comment = "XIVLauncher full screen in gamescope";
        exec = "${xiv} gamescope";
      };
      "applications/xiv-doctor.desktop".text = desktopEntry {
        name = "FFXIV: check setup";
        comment = "xiv doctor";
        exec = inTerminal "${xiv} doctor";
        terminal = true;
      };
      "applications/xiv-update.desktop".text = desktopEntry {
        name = "FFXIV: update everything";
        comment = "Bump plugin pins and flake.lock, rebuild, commit";
        exec = inTerminal "${xiv} update";
        terminal = true;
      };
      "applications/xiv-switch.desktop".text = desktopEntry {
        name = "FFXIV: apply config";
        comment = "xiv switch";
        exec = inTerminal "${xiv} switch";
        terminal = true;
      };
    } // lib.mapAttrs' (file: d: lib.nameValuePair "applications/${file}.desktop" {
      text = desktopEntry { inherit (d) name; exec = "${xiv} launch"; icon = if d.icon == null then appIcon else d.icon; };
    }) cfg.desktopFiles);

    systemd.user.targets.ffxiv-session = mkIf cfg.session.enable {
      Unit = {
        Description = "FFXIV session (gamescope + XIVLauncher via xiv launch)";
        Wants = cfg.session.wants;
        After = cfg.session.wants;
      };
    };

    systemd.user.services.ghostty-agent = mkIf cfg.ghosttyAgent.enable {
      Unit = {
        Description = "ghostty-agent, the PTY server the GhosttyDalamud plugin talks to";
        Documentation = "https://github.com/Spaceghost/ghostty-dalamud#linux";
        After = [ "graphical-session.target" ];
      };
      Service = {
        ExecStart = lib.concatStringsSep " " (([ cfg.ghosttyAgent.binary ] ++ lib.concatMap (l: [ "--listen" l ]) cfg.ghosttyAgent.listen)
          ++ lib.optionals (cfg.ghosttyAgent.windows != null) [ "--windows" cfg.ghosttyAgent.windows ]
          ++ cfg.ghosttyAgent.extraArgs);
        Environment = [ "PATH=%h/.local/bin:%h/bin:${config.home.profileDirectory}/bin:/usr/local/bin:/usr/bin:/bin" ]
          ++ lib.optional (cfg.ghosttyAgent.renderNode != null) "GHOSTTY_WAYLAND_RENDER_NODE=${cfg.ghosttyAgent.renderNode}";
        Restart = "on-failure";
        RestartSec = 5;
        TimeoutStopSec = 10;
      };
      Install.WantedBy = [ "default.target" ];
    };

    systemd.user.services.xiv-update = mkIf cfg.flake.autoUpdate.enable {
      Unit.Description = "xiv update: bump FFXIV plugin pins + flake.lock, switch, commit, push";
      Service = {
        Type = "oneshot";
        ExecStart = "${xiv} update --auto";
        Environment = [ "PATH=${config.home.profileDirectory}/bin:/nix/var/nix/profiles/default/bin:/run/current-system/sw/bin:/usr/local/bin:/usr/bin:/bin" ];
      };
    };
    systemd.user.timers.xiv-update = mkIf cfg.flake.autoUpdate.enable {
      Unit.Description = "Daily FFXIV plugin/flake update";
      Timer = { OnCalendar = cfg.flake.autoUpdate.onCalendar; Persistent = true; RandomizedDelaySec = "1h"; };
      Install.WantedBy = [ "timers.target" ];
    };
  };
}
