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

Live files are merged, never symlinked, because XIVLauncher and Dalamud rewrite them. Each write first saves a copy to `<dataDir>/xivnix/backups/`. If `ffxiv_dx11.exe` or the launcher is running, activation does nothing, because Dalamud saves its config on exit and would overwrite the change.

## Use

```sh
# one-time: Nix itself (see "Installing Nix" below)
nix run home-manager -- switch --flake ~/Projects/xiv.nix#jack@alienware   # first switch
home-manager switch --flake ~/Projects/xiv.nix#jack@alienware              # after that

xiv-nix doctor                                  # what's deployed, conflicts, missing plugins
xiv-nix update --flake ~/Projects/xiv.nix       # bump pins.json to each repo's latest release
xiv-nix update --flake ~/Projects/xiv.nix --testing XivPiano   # newest release incl. prereleases
```

After `update`, commit `pins.json` and run `switch` again. `nix flake update` bumps nixpkgs and home-manager.

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

- **Verified:** `nix flake check` builds every pinned plugin and the alienware activation package. `scripts/xiv-nix.py apply` ran against a copy of the real config, with idempotence and backups checked.
- **Not yet verified:** an actual `home-manager switch` on the alienware box, and a game launch with the plugins loaded from `xivnix/plugins`. Treat both as unproven until they have been run there.
