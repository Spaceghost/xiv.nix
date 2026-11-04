"""xiv-nix: apply a programs.xiv manifest, check a machine, refresh release pins.

  xiv-nix apply MANIFEST [--wait] [--dry-run] [--verbose]
  xiv-nix doctor [MANIFEST]
  xiv-nix dev NAME DIR      load your own build of NAME from DIR (kept across switches)
  xiv-nix release NAME      drop that override, back to the managed copy
  xiv-nix update [--flake DIR] [--testing] [NAME ...]
"""
import base64, datetime, hashlib, json, os, shutil, subprocess, sys, tempfile, time, urllib.request

DEV_TYPE = "System.Collections.Generic.List`1[[Dalamud.Configuration.DevPluginLocationSettings, Dalamud]], System.Private.CoreLib"
DEV_ITEM = "Dalamud.Configuration.DevPluginLocationSettings, Dalamud"
REPO_TYPE = "System.Collections.Generic.List`1[[Dalamud.Configuration.ThirdPartyRepoSettings, Dalamud]], System.Private.CoreLib"
REPO_ITEM = "Dalamud.Configuration.ThirdPartyRepoSettings, Dalamud"
TAG = "xiv.nix:"
GAME_PROCS = ("ffxiv_dx11.exe", "XIVLauncher.Core")

DRY = False
VERBOSE = False


def log(msg):
    print(f"xiv-nix: {msg}", file=sys.stderr)


def vlog(msg):
    if VERBOSE:
        log(msg)


def game_running():
    # Match /proc/*/comm exactly (kernel truncates to 15 chars), never command
    # lines: an editor or shell mentioning ffxiv_dx11.exe must not count.
    want = {p[:15] for p in GAME_PROCS}
    for pid in filter(str.isdigit, os.listdir("/proc")):
        try:
            comm = open(f"/proc/{pid}/comm").read().strip()
        except OSError:
            continue
        if comm in want:
            return comm
    return None


def wine_path(path):
    return "Z:" + os.path.abspath(path).replace("/", "\\")


def backup(path, data_dir):
    if not os.path.exists(path):
        return
    dest = os.path.join(data_dir, "xivnix", "backups")
    os.makedirs(dest, exist_ok=True)
    stamp = datetime.datetime.now().strftime("%Y%m%dT%H%M%S")
    shutil.copy2(path, os.path.join(dest, f"{os.path.basename(path)}.{stamp}"))


def write_atomic(path, text):
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".xiv-nix.")
    with os.fdopen(fd, "w", encoding="utf-8", newline="") as f:
        f.write(text)
    if os.path.exists(path):
        shutil.copymode(path, tmp)
    os.replace(tmp, path)


# ---- ini (launcher.ini, flatpak overrides) --------------------------------

def ini_value(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    return str(v)


def merge_ini(path, section, want):
    """Set keys in `section` ("" = before any header); keep everything else verbatim."""
    lines = open(path, encoding="utf-8").read().splitlines() if os.path.exists(path) else []
    want = {k: ini_value(v) for k, v in want.items()}
    out, current, seen, changed = [], "", set(), []
    sec_end = None

    def flush_missing():
        for k, v in want.items():
            if k not in seen:
                out.append(f"{k}={v}")
                seen.add(k)
                changed.append(k)

    for line in lines:
        stripped = line.strip()
        if stripped.startswith("[") and stripped.endswith("]"):
            if current == section:
                flush_missing()
            current = stripped[1:-1]
            out.append(line)
            continue
        if current == section and "=" in line and not stripped.startswith(("#", ";")):
            k = line.split("=", 1)[0].strip()
            if k in want:
                seen.add(k)
                if line != f"{k}={want[k]}":
                    changed.append(k)
                out.append(f"{k}={want[k]}")
                continue
        out.append(line)
    if current == section or (section and f"[{section}]" not in (l.strip() for l in lines)):
        if section and current != section:
            out.append(f"[{section}]")
        flush_missing()
    return out, changed


def apply_ini(path, section, want, data_dir):
    if not want:
        return
    out, changed = merge_ini(path, section, want)
    if not changed:
        vlog(f"{path}: up to date")
        return
    log(f"{path}: set {', '.join(sorted(set(changed)))}")
    if DRY:
        return
    os.makedirs(os.path.dirname(path), exist_ok=True)
    backup(path, data_dir)
    write_atomic(path, "\n".join(out) + "\n")


# ---- plugins ---------------------------------------------------------------

def sync_release(name, store_path, tag, data_dir):
    dest = os.path.join(data_dir, "xivnix", "plugins", name)
    stamp = os.path.join(dest, ".xiv-nix-source")
    if os.path.exists(stamp) and open(stamp).read() == store_path:
        vlog(f"{name}: {tag} already in place")
        return dest
    log(f"{name}: install {tag} -> {dest}")
    if DRY:
        return dest
    tmp = dest + ".new"
    shutil.rmtree(tmp, ignore_errors=True)
    shutil.copytree(store_path, tmp)
    for root, dirs, files in os.walk(tmp):  # store copies are read-only
        for n in dirs + files:
            os.chmod(os.path.join(root, n), 0o755 if n in dirs else 0o644)
    os.chmod(tmp, 0o755)
    with open(os.path.join(tmp, ".xiv-nix-source"), "w") as f:
        f.write(store_path)
    old = dest + ".old"
    shutil.rmtree(old, ignore_errors=True)
    if os.path.exists(dest):
        os.replace(dest, old)
    os.replace(tmp, dest)
    shutil.rmtree(old, ignore_errors=True)
    return dest


def dll_name(entry):
    return os.path.basename(str(entry.get("Path", "")).replace("\\", "/")).lower()


def unwine(path):
    return path[2:].replace("\\", "/") if path[:2].upper() == "Z:" else path


def load_config(data_dir):
    path = os.path.join(data_dir, "dalamudConfig.json")
    if not os.path.exists(path):
        return path, None, None
    raw = open(path, encoding="utf-8-sig").read()
    return path, raw, json.loads(raw)


def save_config(path, raw, cfg, data_dir, what):
    if json.loads(raw) == cfg:
        vlog("dalamudConfig.json: up to date")
        return
    log(f"dalamudConfig.json: {what}")
    if DRY:
        return
    backup(path, data_dir)
    write_atomic(path, json.dumps(cfg, indent=2, ensure_ascii=False))


def apply_dalamud(m, plugin_dirs):
    """Managed entries are Nickname "xiv.nix:<Name>". Any other entry for a
    declared plugin's DLL is your dev override and wins, so working on a
    plugin never needs a switch. The one exception is the first apply after a
    plugin is declared ("adoption"): entries that predate xiv.nix are dropped
    once so the managed copy takes over."""
    data_dir = m["dataDir"]
    path, raw, cfg = load_config(data_dir)
    if cfg is None:
        log(f"{path} missing; start XIVLauncher once with Dalamud enabled, then re-run switch")
        return
    adopted_path = os.path.join(data_dir, "xivnix", "adopted.json")
    adopted = set(json.load(open(adopted_path))) if os.path.exists(adopted_path) else set()
    by_dll = {f"{n}.dll".lower(): n for n in m["plugins"]}

    dev = cfg.setdefault("DevPluginLoadLocations", {"$type": DEV_TYPE, "$values": []})
    prev, out, overrides = {}, [], {}
    for e in dev["$values"]:
        nick = str(e.get("Nickname") or "")
        if nick.startswith(TAG):
            prev[nick[len(TAG):]] = e
            continue
        owner = by_dll.get(dll_name(e))
        if owner and owner not in adopted:
            log(f"{owner}: adopting; dropped pre-xiv.nix location {unwine(e.get('Path', ''))}")
            continue
        if owner:
            overrides[owner] = e
        out.append(e)
    for name, d in sorted(plugin_dirs.items()):
        if name in overrides:
            log(f"{name}: dev override wins ({unwine(overrides[name].get('Path', ''))}); `xiv-nix release {name}` to go back")
            continue
        enabled = prev[name].get("IsEnabled", True) if name in prev else True  # keep your in-game toggle
        out.append({"$type": DEV_ITEM, "IsEnabled": enabled, "Nickname": TAG + name,
                    "Path": wine_path(os.path.join(d, f"{name}.dll"))})
    dev["$values"] = out

    repos = cfg.setdefault("ThirdRepoList", {"$type": REPO_TYPE, "$values": []})
    by_url = {r["url"]: r["enable"] for r in m["thirdPartyRepos"]}
    vals = [r for r in repos["$values"] if r.get("Url") not in by_url]
    for url, en in by_url.items():
        vals.append({"$type": REPO_ITEM, "Url": url, "IsEnabled": en})
    repos["$values"] = vals

    save_config(path, raw, cfg, data_dir, f"{len(plugin_dirs) - len(overrides)} managed dev plugins, {len(overrides)} dev overrides, {len(by_url)} managed repos")
    if not DRY and not adopted >= set(m["plugins"]):
        os.makedirs(os.path.dirname(adopted_path), exist_ok=True)
        write_atomic(adopted_path, json.dumps(sorted(adopted | set(m["plugins"]))) + "\n")


# ---- launcher --------------------------------------------------------------

def flatpak_installed(app):
    if not shutil.which("flatpak"):
        return None
    return subprocess.run(["flatpak", "info", app], capture_output=True).returncode == 0


def apply_launcher(m):
    l = m["launcher"]
    if l["kind"] == "flatpak":
        fp = l["flatpak"]
        state = flatpak_installed(fp["appId"])
        if state is None:
            log("flatpak not found on PATH; install it from your distro, then re-run switch")
        elif not state and fp["install"]:
            log(f"flatpak install --user {fp['remote']} {fp['appId']}")
            if not DRY:
                subprocess.run(["flatpak", "install", "--user", "--noninteractive", fp["remote"], fp["appId"]], check=True)
        override = os.path.expanduser(f"~/.local/share/flatpak/overrides/{fp['appId']}")
        apply_ini(override, "Environment", fp["env"], m["dataDir"])
    if l["kind"] != "none":
        apply_ini(os.path.join(m["dataDir"], "launcher.ini"), "", l["settings"], m["dataDir"])


def defer_apply(manifest_path, running):
    """Game is up: Dalamud would overwrite our edit on exit, so queue the apply
    as a transient user unit that waits for the game to close."""
    unit = "xiv-nix-pending"
    if DRY or not shutil.which("systemd-run"):
        log(f"{running} is running; skipped. Close the game and run switch again.")
        return 0
    subprocess.run(["systemctl", "--user", "stop", unit], capture_output=True)
    r = subprocess.run(["systemd-run", "--user", "--quiet", "--collect", f"--unit={unit}",
                        sys.executable, "-I", os.path.abspath(__file__), "apply", os.path.realpath(manifest_path), "--wait"],
                       capture_output=True, text=True)
    if r.returncode:
        log(f"{running} is running and queueing failed ({r.stderr.strip()}); run switch again after closing the game.")
    else:
        log(f"{running} is running; queued, applies after the game closes (journalctl --user -u {unit}).")
    return 0


def cmd_apply(manifest_path, wait=False):
    m = json.load(open(manifest_path))
    running = game_running()
    if running and not wait:
        return defer_apply(manifest_path, running)
    if wait:
        while game_running():
            time.sleep(20)
        time.sleep(15)  # let Dalamud finish its exit-time config save
    os.makedirs(m["dataDir"], exist_ok=True)
    apply_launcher(m)
    plugin_dirs = {}
    for name, p in sorted(m["plugins"].items()):
        if not p["enable"]:
            continue
        if p["source"] == "release":
            plugin_dirs[name] = sync_release(name, p["path"], p["tag"], m["dataDir"])
        else:
            if not os.path.exists(os.path.join(p["path"], f"{name}.dll")):
                log(f"{name}: WARNING {p['path']}/{name}.dll not found (registered anyway)")
            plugin_dirs[name] = p["path"]
    apply_dalamud(m, plugin_dirs)
    return 0


# ---- doctor ----------------------------------------------------------------

def cmd_doctor(manifest_path):
    m = json.load(open(manifest_path))
    data_dir, bad = m["dataDir"], 0
    print(f"data dir      {os.path.realpath(data_dir)}")
    print(f"game running  {game_running() or 'no'}")
    if m["launcher"]["kind"] == "flatpak":
        state = flatpak_installed(m["launcher"]["flatpak"]["appId"])
        print(f"launcher      flatpak {m['launcher']['flatpak']['appId']}: {'installed' if state else 'MISSING'}")
        bad += not state
    installed_dir = os.path.join(data_dir, "installedPlugins")
    installed = set(os.listdir(installed_dir)) if os.path.isdir(installed_dir) else set()
    _, _, cfg = load_config(data_dir)
    entries = (cfg or {}).get("DevPluginLoadLocations", {}).get("$values", [])
    for name, p in sorted(m["plugins"].items()):
        if not p["enable"]:
            continue
        mine = [e for e in entries if dll_name(e) == f"{name}.dll".lower()]
        user = [e for e in mine if not str(e.get("Nickname") or "").startswith(TAG)]
        e = (user or mine or [None])[0]
        where = "dev" if user else p["source"]
        d = os.path.dirname(unwine(e["Path"])) if e else None
        meta = os.path.join(d, f"{name}.json") if d else ""
        ver = json.load(open(meta, encoding="utf-8-sig")).get("AssemblyVersion", "?") if os.path.exists(meta) else "NOT DEPLOYED"
        notes = []
        if e is not None and not e.get("IsEnabled", True):
            notes.append("location off in Dalamud settings")
        if user:
            notes.append(d)
        if name in installed:
            notes.append("! repo copy also installed; disable one in /xlplugins")
        print(f"plugin        {name:16} {where:7} {ver:12} {'; '.join(notes)}".rstrip())
        bad += ver == "NOT DEPLOYED"
    missing = [n for n in m["thirdPartyPlugins"] if n not in installed]
    print(f"third-party   {len(m['thirdPartyPlugins']) - len(missing)}/{len(m['thirdPartyPlugins'])} installed")
    if missing:
        print("  install via /xlplugins: " + ", ".join(missing))
    return 1 if bad else 0


# ---- dev / release ---------------------------------------------------------

def cmd_dev(manifest_path, name, directory):
    """Point Dalamud at your own build of NAME; survives every future switch."""
    m = json.load(open(manifest_path))
    running = game_running()
    if running:
        log(f"{running} is running and Dalamud would overwrite this on exit; add the location in /xlsettings > Experimental instead (xiv.nix will keep it).")
        return 1
    if name not in m["plugins"]:
        log(f"{name} is not declared in programs.xiv.plugins; it is yours to manage in Dalamud directly")
        return 1
    dll = os.path.join(os.path.abspath(os.path.expanduser(directory)), f"{name}.dll")
    if not os.path.exists(dll):
        log(f"WARNING {dll} does not exist yet (registered anyway; Dalamud picks it up once built)")
    path, raw, cfg = load_config(m["dataDir"])
    if cfg is None:
        log(f"{path} missing")
        return 1
    dev = cfg.setdefault("DevPluginLoadLocations", {"$type": DEV_TYPE, "$values": []})
    dev["$values"] = [e for e in dev["$values"]
                      if dll_name(e) != f"{name}.dll".lower()]
    dev["$values"].append({"$type": DEV_ITEM, "IsEnabled": True, "Nickname": f"dev:{name}", "Path": wine_path(dll)})
    save_config(path, raw, cfg, m["dataDir"], f"{name}: dev build at {dll}")
    return 0


def cmd_release(manifest_path, name):
    """Drop your dev override of NAME and go back to the managed copy."""
    m = json.load(open(manifest_path))
    running = game_running()
    if running:
        log(f"{running} is running; close the game first")
        return 1
    path, raw, cfg = load_config(m["dataDir"])
    if cfg is None:
        log(f"{path} missing")
        return 1
    dev = cfg.setdefault("DevPluginLoadLocations", {"$type": DEV_TYPE, "$values": []})
    dev["$values"] = [e for e in dev["$values"]
                      if dll_name(e) != f"{name}.dll".lower() or str(e.get("Nickname") or "").startswith(TAG)]
    save_config(path, raw, cfg, m["dataDir"], f"{name}: dev override removed")
    return cmd_apply(manifest_path)


# ---- update ----------------------------------------------------------------

def gh_json(url):
    req = urllib.request.Request(url, headers={"Accept": "application/vnd.github+json"})
    tok = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if tok:
        req.add_header("Authorization", f"Bearer {tok}")
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


def cmd_update(flake, testing, names):
    pins_path = os.path.join(flake, "pins.json")
    pins = json.load(open(pins_path))
    for name in names or sorted(pins):
        pin = pins[name]
        if testing:
            rels = [r for r in gh_json(f"https://api.github.com/repos/{pin['repo']}/releases?per_page=20")
                    if not r["draft"] and any(a["name"] == "latest.zip" for a in r["assets"])]
            rel = max(rels, key=lambda r: r["published_at"])
        else:
            rel = gh_json(f"https://api.github.com/repos/{pin['repo']}/releases/latest")
        tag = rel["tag_name"]
        if tag == pin["tag"]:
            print(f"{name:16} {tag} (current)")
            continue
        url = f"https://github.com/{pin['repo']}/releases/download/{tag}/latest.zip"
        with urllib.request.urlopen(url, timeout=120) as r:
            digest = hashlib.sha256(r.read()).digest()
        pins[name] = {"repo": pin["repo"], "tag": tag, "hash": "sha256-" + base64.b64encode(digest).decode()}
        print(f"{name:16} {pin['tag']} -> {tag}")
    write_atomic(pins_path, json.dumps(pins, indent=2) + "\n")
    return 0


def main(argv):
    global DRY, VERBOSE
    DRY = "--dry-run" in argv
    VERBOSE = "--verbose" in argv
    args = [a for a in argv if a not in ("--dry-run", "--verbose")]
    default_manifest = os.path.expanduser("~/.config/xiv-nix/manifest.json")
    if not args or args[0] in ("-h", "--help"):
        print(__doc__)
        return 0
    if args[0] == "apply" and len(args) in (2, 3) and args[2:] in ([], ["--wait"]):
        return cmd_apply(args[1], wait=args[2:] == ["--wait"])
    if args[0] == "dev" and len(args) == 3:
        return cmd_dev(default_manifest, args[1], args[2])
    if args[0] == "release" and len(args) == 2:
        return cmd_release(default_manifest, args[1])
    if args[0] == "doctor":
        return cmd_doctor(args[1] if len(args) > 1 else default_manifest)
    if args[0] == "update":
        rest, flake, testing = args[1:], os.getcwd(), False
        if "--testing" in rest:
            rest.remove("--testing")
            testing = True
        if "--flake" in rest:
            i = rest.index("--flake")
            flake = rest[i + 1]
            del rest[i:i + 2]
        return cmd_update(flake, testing, rest)
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
