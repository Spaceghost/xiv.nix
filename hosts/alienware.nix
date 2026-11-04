# Alienware (Bazzite, RTX 3070). Everything machine-specific lives here;
# modules/xiv.nix has nothing Bazzite-only in it.
{ ... }:

{
  home.username = "jack";
  home.homeDirectory = "/home/jack";
  home.stateVersion = "25.11";
  targets.genericLinux.enable = true;
  programs.home-manager.enable = true;

  programs.xiv = {
    enable = true;
    dataDir = "/home/jack/.xlcore"; # symlink to ~/Games/.xlcore

    launcher = {
      kind = "flatpak";
      flatpak.install = false; # Bazzite ships it as a system flatpak
      settings = {
        GamePath = "/home/jack/Games/SteamLibrary/steamapps/common/FINAL FANTASY XIV Online/";
        ClientLanguage = "English";
        DalamudEnabled = true;
        DalamudLoadMethod = "EntryPoint";
        WineStartupType = "Managed";
        WineManagedVersion = "Stable";
        WineSyncType = "FSync";
        DxvkVersion = "Stable";
        DxvkAsyncEnabled = true;
        DxvkHudType = "Fps";
        GameModeEnabled = false;
      };
    };

    # Two NVIDIA cards: RTX 3070 (02:00.0, drives the monitor) and RTX 4060
    # (03:00.0, reserved for ollama). The game only ever runs on the 3070;
    # strict = refuse to launch rather than fall back to the 4060.
    gpu.prefer = [ "RTX 3070" ];
    gpu.strict = true;

    gamescope.output = "HDMI-A-2,*"; # connector on the 3070 with the monitor

    # "FFXIV" at the login screen (once: xiv install-session) + ffxiv-session.target.
    session.enable = true;
    session.wants = [ "ghostty-agent.service" ];

    # xiv switch / xiv update work on this checkout; a daily timer runs
    # xiv update --auto (pins + flake.lock -> switch -> commit -> push).
    flake.attr = "jack@alienware";
    flake.autoUpdate.enable = true;

    # Steam's shortcut goes through Dalamud and the GPU/CPU policy too.
    desktopFiles."FINAL FANTASY XIV Online" = { name = "FINAL FANTASY XIV Online"; icon = "steam_icon_39210"; };

    # i7-11700F, 8 cores / 16 threads: game gets cores 0-3 + siblings
    # (CPUs 0-3,8-11), leaving the other half for builds and local models.
    cpu.cores = "half";

    # Your plugins. "release" = pinned in pins.json, bumped with `xiv-nix update`.
    # To test a dev build instead: source = "local"; path = "/home/jack/<name>-build/devplugin";
    plugins = {
      GhosttyDalamud = { };
      Almanac = { };
      XivMcp = { };
      XivDesktop = { };
      XivArcade = { };
      XivWayfinder = { };
      XivLantern = { };
      XivPiano = { };
      # No source repo or release yet: keep loading the local builds.
      XivLinkpearl = { source = "local"; path = "/home/jack/linkpearl-build/devplugin"; };
      XivWorkshop = { source = "local"; path = "/home/jack/dalamud-plugins/XivWorkshop"; };
    };

    thirdPartyRepos = [ { url = "https://spacegho.st/mods/ffxiv/plugins.json"; enable = true; } ];

    thirdPartyPlugins = [
      "AdaptiveHud" "BetterFriendList" "Browsingway" "CharacterPanelRefined" "ChatProximity"
      "ChatTwo" "Compass" "Congratulations" "CrossUp" "DamageInfoPlugin" "DeviceChangeFix"
      "Distance" "FastJobSwitcher" "FlashOnReadyCheck" "FlashOnTell" "GatherBuddy"
      "Globetrotter" "HarpHero" "HighFpsPhysicsPlugin" "Hunty" "InventorySearchBar" "Mappy"
      "Mini" "MiniMappingway" "NoSoliciting" "OofPlugin" "orchestrion" "PeepingTom"
      "PennyPincher" "PixelPerfect" "PositionalGuide" "PvPAnnouncer" "SimpleTweaksPlugin"
      "SortaKinda" "StanleyParableXiv" "StatusTimers" "TargetLines" "TeleporterPlugin"
      "TriadBuddy" "Umbra" "Visibility" "XIVChat"
    ];
  };
}
