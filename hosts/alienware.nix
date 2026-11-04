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

    # Two NVIDIA cards (RTX 3070 at 02:00.0, RTX 4060 at 03:00.0, not always
    # both present): the first one found at launch runs the game.
    gpu.prefer = [ "RTX 3070" "RTX 4060" ];

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

    # Off on purpose: enabling it offers repo copies of the plugins above,
    # which collide with the dev-loaded ones (same InternalName).
    thirdPartyRepos = [ { url = "https://spacegho.st/mods/ffxiv/plugins.json"; enable = false; } ];

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
