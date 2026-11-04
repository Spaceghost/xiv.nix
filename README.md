# xiv.nix

FFXIV on Linux as a Home Manager module: XIVLauncher, the Dalamud config, and your own Dalamud plugins pinned to GitHub releases. It works on any distro that can run Nix. Nothing in `modules/` is specific to Bazzite. Machine details go in `hosts/<name>.nix`.

## What it manages

| Thing | How |
| --- | --- |
| XIVLauncher | Flatpak by default (`launcher.kind = "flatpak"`): installs `dev.goats.xivlauncher` if it is missing and merges `[Environment]` into the user flatpak override. `kind = "nix"` uses `pkgs.xivlauncher` instead. |
| `launcher.ini` | Only the keys in `launcher.settings` are enforced. Everything else is left as XIVLauncher wrote it. |
| Your plugins | `source = "release"`: the `latest.zip` from the GitHub release pinned in `pins.json`. It is fetched into the Nix store and copied to `<dataDir>/xivnix/plugins/<Name>`. `source = "local"`: load your own dev build from `path`. Both are registered as Dalamud dev-plugin locations named `xiv.nix:<Name>`. |
| Third-party repos | `ThirdRepoList` entries by URL. |
| Third-party plugins | Dalamud installs and auto-updates these itself. `thirdPartyPlugins` is the expected list, and `xiv-nix doctor` names the missing ones. |

Live files are merged, never symlinked, because XIVLauncher and Dalamud rewrite them. Each write first saves a copy to `<dataDir>/xivnix/backups/`. If `ffxiv_dx11.exe` or the launcher is running, the apply is queued and runs after the game closes, because Dalamud saves its config on exit and would overwrite the change.

## Use

```sh
# one-time: Nix itself (see "Installing Nix" below)
nix run home-manager -- switch --flake ~/Projects/xiv.nix#jack@alienware   # first switch
home-manager switch --flake ~/Projects/xiv.nix#jack@alienware              # after that

xiv-nix doctor                                  # what loads (release/local/dev), versions, conflicts
xiv-nix dev XivPiano ~/xiv-piano-build/devplugin   # load your build; survives switches
xiv-nix release XivPiano                        # back to the pinned release
xiv-nix update --flake ~/Projects/xiv.nix       # bump pins.json to each repo's latest release
xiv-nix update --flake ~/Projects/xiv.nix --testing XivPiano   # newest release incl. prereleases
```

After `update`, commit `pins.json` and run `switch` again. `nix flake update` bumps nixpkgs and home-manager.

## Working on a plugin

xiv.nix never fights your dev loop:

- **Use your own build:** `xiv-nix dev XivPiano ~/xiv-piano-build/devplugin` registers it. A location you add yourself in `/xlsettings` → Experimental works the same way. That entry wins over the pinned release on every later switch, and Dalamud hot-reloads it each time you rebuild.
- **Go back to the release:** `xiv-nix release XivPiano` drops the override and restores the pinned release.
- **Toggles stick:** turning a managed location on or off in game is kept across switches.
- **Repo copies are untouched:** Dalamud keeps auto-updating anything installed from a repo (`installedPlugins/`). xiv.nix doesn't touch those.
- **Switching during play:** a switch while the game or launcher is running queues itself as the transient user unit `xiv-nix-pending`. It applies 15 s after the game closes, once Dalamud's exit-time save is done. See `journalctl --user -u xiv-nix-pending`.
- **First switch only:** the first switch after a plugin is declared "adopts" it. Dev locations from before xiv.nix are dropped once, so the managed copy takes over. After that, any location you add for the plugin counts as your override.

`xiv-nix doctor` shows, for each plugin, which copy Dalamud will load (`release`, `local`, or `dev`) and its version.

## New machine

1. Copy `hosts/alienware.nix` to `hosts/<name>.nix` and fix `home.*`, `dataDir`, `GamePath`, and the GPU name.
2. Add a `homeConfigurations."<user>@<name>"` entry to `flake.nix`.
3. Start XIVLauncher once so it creates `dalamudConfig.json`, then run `switch`.
4. Run `xiv-nix doctor` and install the plugins it lists from `/xlplugins`.

## Installing Nix

- **Bazzite / Fedora Atomic / other ostree systems:** `/` is read-only, so use the Determinate installer's ostree planner. It persists the store under `/var` and bind-mounts it at `/nix`:
  ```sh
  curl -fsSL https://install.determinate.systems/nix | sh -s -- install ostree
  ```
- **Other distros:** use the same installer without `ostree`.
- **NixOS:** use the flake's `homeModules.default` from your own config.

## Status

- **Verified:** `nix flake check` builds every pinned plugin and the alienware activation package. `scripts/xiv-nix.py` ran against a copy of the real config: adoption, idempotence, backups, a toggle kept, a dev override winning, `dev`/`release`, and the deferred apply through a real `systemd-run` unit waiting on a process named `ffxiv_dx11.exe`.
- **Not yet verified:** an actual `home-manager switch` on the alienware box, and a game launch with the plugins loaded from `xivnix/plugins`. Treat both as unproven until they have been run there.
