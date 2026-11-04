# xiv.nix

FFXIV on Linux as a Home Manager module: XIVLauncher, the Dalamud config, and your own Dalamud plugins pinned to GitHub releases. It works on any distro that can run Nix. Nothing in `modules/` is specific to Bazzite. Machine details go in `hosts/<name>.nix`.

## What it manages

| Thing | How |
| --- | --- |
| XIVLauncher | Flatpak by default (`launcher.kind = "flatpak"`): installs `dev.goats.xivlauncher` if it is missing and merges `[Environment]` into the user flatpak override. `kind = "nix"` uses `pkgs.xivlauncher` instead. |
| `launcher.ini` | Only the keys in `launcher.settings` are enforced. Everything else is left as XIVLauncher wrote it. |
| Your plugins | `source = "release"`: the `latest.zip` from the GitHub release pinned in `pins.json`. It is fetched into the Nix store and copied to `<dataDir>/xivnix/plugins/<Name>`. `source = "local"`: load your own dev build from `path`. Both are registered as Dalamud dev-plugin locations named `xiv.nix:<Name>`. |
| Third-party repos | `ThirdRepoList` entries by URL. |
| Third-party plugins | Dalamud installs and auto-updates these itself. `thirdPartyPlugins` is the expected list, and `xiv doctor` names the missing ones. |

Live files are merged, never symlinked, because XIVLauncher and Dalamud rewrite them. Each write first saves a copy to `<dataDir>/xivnix/backups/`. If `ffxiv_dx11.exe` or the launcher is running, the apply is queued and runs after the game closes, because Dalamud saves its config on exit and would overwrite the change.

## Use

First time on a machine (after Nix is installed):

```sh
nix run home-manager -- switch -b xivnix-bak --flake ~/Projects/xiv.nix#jack@alienware
xiv install-session        # optional, sudo once: "FFXIV" on the login screen
```

`-b xivnix-bak` moves aside any file xiv.nix now owns, such as an existing `ffxiv-session.target` or the Steam shortcut, as `*.xivnix-bak`. After that, everything is `xiv`:

| | |
| --- | --- |
| `xiv` | play: XIVLauncher with Dalamud, the preferred GPU, and pinned CPUs |
| `xiv gamescope` | the same, full screen in a nested gamescope |
| `xiv update` | pull, bump plugin pins and `flake.lock`, switch, then commit and push. A failed switch reverts both files. |
| `xiv switch` | rebuild this machine from the checkout |
| `xiv doctor` | what loads (release/local/dev), versions, conflicts, GPUs, CPUs, session, timer |
| `xiv dev NAME DIR` / `xiv release NAME` | load your own build of a plugin / go back to the release |

Each of these is also in the app menu: **XIVLauncher**, **FFXIV (gamescope)**, **FFXIV: update everything**, **FFXIV: apply config**, and **FFXIV: check setup**.

With `flake.autoUpdate.enable`, a daily user timer runs `xiv update --auto`. It skips if the checkout has uncommitted work, and if the game is running, the config part waits until you quit.

### Everything launches through `xiv launch`

- **Menu and Steam:** the XIVLauncher menu entry, plus any `desktopFiles` you take over, like Steam's "FINAL FANTASY XIV Online".
- **`xiv gamescope`:** passes the chosen card to gamescope as `--prefer-vk-device`.
- **The login session:** `ffxiv-session` (gamescope on the bare display, the game only, back to the login screen when it closes). It picks its card with `xiv gpu-id` and its launcher with `xiv launch`.
- **`ffxiv-session.target`:** declared by `session.wants`.
- **ghostty-dalamud:** its `tools/ffxiv-session.sh` uses `xiv launch` when installed.

## GPU choice and CPU pinning

```nix
programs.xiv.gpu.prefer = [ "RTX 3070" "RTX 4060" ];  # first card present at launch wins
programs.xiv.gpu.offload = "none";                     # "nvidia" / "mesa" for hybrid laptops
programs.xiv.cpu.cores = "half";                       # or [ 0 1 2 3 8 9 10 11 ]
```

These are decided at every launch, not at switch time, so a card that's only sometimes connected is handled. `xiv launch` does the following:
- Picks the first preferred card in `lspci` and sets `DXVK_FILTER_DEVICE_NAME` to it. If none is present, it clears the filter and lets DXVK choose.
- Pins itself with `sched_setaffinity`. Flatpak, Wine, Dalamud and the game inherit that pinning.
- Sets `WINE_CPU_TOPOLOGY` so the game sees only the pinned CPUs.

`"half"` takes half the physical cores, P-cores first on hybrid Intel, along with their SMT siblings.

The module writes an XIVLauncher menu entry with the flatpak's own id to `~/.local/share/applications`, so it replaces the flatpak's entry. Anything that runs `flatpak run dev.goats.xivlauncher` directly bypasses this, so point scripts at `xiv launch` instead. `xiv doctor` shows the cards present, which one the game will use, and the pinned CPUs.

## Working on a plugin

xiv.nix never fights your dev loop:

- **Use your own build:** `xiv dev XivPiano ~/xiv-piano-build/devplugin` registers it. A location you add yourself in `/xlsettings` → Experimental works the same way. That entry wins over the pinned release on every later switch, and Dalamud hot-reloads it each time you rebuild.
- **Go back to the release:** `xiv release XivPiano` drops the override and restores the pinned release.
- **Toggles stick:** turning a managed location on or off in game is kept across switches.
- **Repo copies are untouched:** Dalamud keeps auto-updating anything installed from a repo (`installedPlugins/`). xiv.nix doesn't touch those.
- **Switching during play:** a switch while the game or launcher is running queues itself as the transient user unit `xiv-nix-pending`. It applies 15 s after the game closes, once Dalamud's exit-time save is done. See `journalctl --user -u xiv-nix-pending`.
- **First switch only:** the first switch after a plugin is declared "adopts" it. Dev locations from before xiv.nix are dropped once, so the managed copy takes over. After that, any location you add for the plugin counts as your override.

`xiv doctor` shows, for each plugin, which copy Dalamud will load (`release`, `local`, or `dev`) and its version.

## New machine

1. Copy `hosts/alienware.nix` to `hosts/<name>.nix` and fix `home.*`, `dataDir`, `GamePath`, and the GPU name.
2. Add a `homeConfigurations."<user>@<name>"` entry to `flake.nix`.
3. Start XIVLauncher once so it creates `dalamudConfig.json`, then run `switch`.
4. Run `xiv doctor` and install the plugins it lists from `/xlplugins`.

## Installing Nix

- **Bazzite / Fedora Atomic / other ostree systems:** `/` is read-only, so use the Determinate installer's ostree planner. It persists the store under `/var` and bind-mounts it at `/nix`. On composefs roots (Bazzite, Fedora Atomic 42+), the installer fails at `nix.mount`, because `chattr` isn't supported and `/nix` can't be created. Prepare first:
  ```sh
  sudo scripts/ostree-nix-prep.sh   # root.transient=true + chattr drop-in; reboot if it says so
  curl -fsSL https://install.determinate.systems/nix | sh -s -- install ostree --no-confirm
  ```
  Run it in a real terminal: the installer needs a TTY for sudo.
- **Other distros:** use the same installer without `ostree`.
- **NixOS:** use the flake's `homeModules.default` from your own config.

## Status

- **Verified:** `nix flake check` builds every pinned plugin and the alienware activation package. `scripts/xiv-nix.py` ran against a copy of the real config: adoption, idempotence, backups, a toggle kept, a dev override winning, `dev`/`release`, and the deferred apply through a real `systemd-run` unit waiting on a process named `ffxiv_dx11.exe`.
- **`xiv launch`:** checked with a stub `flatpak`. It passed the chosen card and `WINE_CPU_TOPOLOGY`, with affinity `0-3,8-11` on the i7-11700F.
- **`xiv update`, `xiv gamescope`:** checked with stubbed `nix`, `home-manager` and `gamescope` against a scratch clone. The success path commits and pushes, a failed switch reverts and leaves the tree clean, an unattended run on a dirty tree skips, and gamescope gets `--prefer-vk-device 10de:2484`.
- **Not yet verified:** whether the XIV Wine build honours `WINE_CPU_TOPOLOGY` (wine-staging and Proton do).
- **Not yet verified:** an actual `home-manager switch` on the alienware box, the `ffxiv-session` login session (never logged into, before or after xiv.nix), the daily timer under real systemd, and a game launch with the plugins loaded from `xivnix/plugins`. Treat both as unproven until they have been run there.
