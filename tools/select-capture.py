#!/usr/bin/env python3
"""Captures the character screen of WoW: Forever for the Reliquary dashboard.

Addons cannot run on the character screen, where the game shows the character full length,
lit and facing the camera, so this reads the game window from outside, like a screenshot:
it never sends the game a key, a click or anything else.

It looks only for five minutes after the game starts or saves Reliquary's data (a logout to
the character screen saves it), twice in a row finds the screen's "Enter World" button where
it always is, waits for her to settle, checks no other window is over her, and keeps a crop
of her for the character played last. A new capture is kept when her level or gear has
changed since the last one, or once a week; otherwise the same picture is not filed again.

    python3 tools/select-capture.py            # the service (reliquary-select.service)
    python3 tools/select-capture.py --once F   # crop and file an existing full-size still
"""
import argparse
import glob
import json
import os
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "server"))
import luasv  # noqa: E402

GAME = os.path.join(os.environ.get("WOW_FOREVER", "/mnt/games/wow-forever"), "_forever_")
CAPTURES = os.path.join(os.environ.get("XDG_DATA_HOME", os.path.expanduser("~/.local/share")), "reliquary", "captures")
ANCHOR_REF = os.path.join(ROOT, "data", "select-anchor.png")

POLL = 3            # seconds between looks while watching
WATCH_FOR = 300     # seconds of watching after the game starts or saves
SETTLE = 2.5        # seconds for her to finish turning in before the picture
ANCHOR_MAX = 0.05   # measured 2026-11-07: character screen 0.002-0.011, anything else 0.159 or more
REFRESH = 7 * 86400 # file the same look again after a week

# Where things are on the character screen, as fractions of the window (W wide, H high),
# measured on a 3810x1001 capture: the Enter World button, and her from head to hem.
ANCHOR = {"cx": 0.5, "w": 0.25, "top": 0.892, "h": 0.06}       # widths in H
CROP = {"cx": 0.5131, "w": 0.4995, "top": 0.06, "h": 0.799}    # cx in W, the rest in H


def log(msg):
    print(time.strftime("%H:%M:%S"), msg, flush=True)


def run(args, **kw):
    return subprocess.run(args, capture_output=True, text=True, timeout=30, **kw)


# ---------------------------------------------------------------------------
# The game and its window
# ---------------------------------------------------------------------------
def game_running():
    return run(["pgrep", "-x", "Wow.exe"]).returncode == 0


def hypr(what):
    r = run(["hyprctl", what, "-j"])
    return json.loads(r.stdout) if r.returncode == 0 and r.stdout.strip() else []


def game_window(clients=None, monitors=None):
    """The game's window if it is on a workspace someone can see right now."""
    clients = hypr("clients") if clients is None else clients
    monitors = hypr("monitors") if monitors is None else monitors
    shown = {m.get("activeWorkspace", {}).get("id") for m in monitors}
    for c in clients:
        if c.get("title") == "World of Warcraft" and not c.get("hidden") and c.get("workspace", {}).get("id") in shown:
            return c
    return None


def crop_rect(width, height):
    """Her crop in a picture of the window: (w, h, x, y) in that picture's pixels."""
    w, h = round(CROP["w"] * height), round(CROP["h"] * height)
    return w, h, round(CROP["cx"] * width - w / 2), round(CROP["top"] * height)


def covered(win, clients):
    """Whether another floating window is over the part of the game window where she stands."""
    x, y = win["at"]
    ww, wh = win["size"]
    cw, ch, cx, cy = crop_rect(ww, wh)
    left, top, right, bottom = x + cx, y + cy, x + cx + cw, y + cy + ch
    for c in clients:
        if c is win or c.get("address") == win.get("address") or not c.get("floating") or c.get("hidden"):
            continue
        if c.get("workspace", {}).get("id") != win.get("workspace", {}).get("id"):
            continue
        ox, oy = c["at"]
        ow, oh = c["size"]
        if ox < right and ox + ow > left and oy < bottom and oy + oh > top:
            return c.get("title") or c.get("class") or "a window"
    return None


def grab(win, path, scale=None):
    x, y = win["at"]
    w, h = win["size"]
    args = ["grim", "-g", f"{x},{y} {w}x{h}"] + (["-s", str(scale)] if scale else []) + [path]
    return run(args).returncode == 0


# ---------------------------------------------------------------------------
# Pictures
# ---------------------------------------------------------------------------
def size_of(path):
    r = run(["magick", "identify", "-format", "%w %h", path])
    w, h = r.stdout.split()
    return int(w), int(h)


def anchor_score(path, workdir):
    """How far the Enter World button's spot in this picture is from the reference (0 = same)."""
    w, h = size_of(path)
    aw, ah = round(ANCHOR["w"] * h), round(ANCHOR["h"] * h)
    ax, ay = round(ANCHOR["cx"] * w - aw / 2), round(ANCHOR["top"] * h)
    probe = os.path.join(workdir, "anchor.png")
    run(["magick", path, "-crop", f"{aw}x{ah}+{ax}+{ay}", "+repage", "-resize", "160x38!", "-colorspace", "sRGB", probe])
    r = run(["magick", "compare", "-metric", "RMSE", ANCHOR_REF, probe, "null:"])
    try:
        return float(r.stderr.split("(")[1].split(")")[0])
    except (IndexError, ValueError):
        return 1.0


def crop_her(full, out):
    w, h = size_of(full)
    cw, ch, cx, cy = crop_rect(w, h)
    return run(["magick", full, "-crop", f"{cw}x{ch}+{cx}+{cy}", "+repage", "-strip", out]).returncode == 0


# ---------------------------------------------------------------------------
# Who she is, and whether this look is new
# ---------------------------------------------------------------------------
def last_played(game=GAME):
    """The character saved most recently: key, level, and a fingerprint of level and gear."""
    best = None
    for path in glob.glob(os.path.join(game, "WTF", "Account", "*", "SavedVariables", "Reliquary.lua")):
        try:
            chars = (luasv.load(path).get("ReliquaryDB") or {}).get("chars") or {}
        except (OSError, luasv.ParseError):
            continue
        for key, c in chars.items():
            if isinstance(c, dict) and (best is None or (c.get("updated") or 0) > (best[1].get("updated") or 0)):
                best = (key, c)
    if not best:
        return None
    key, c = best
    gear = c.get("gear") or {}
    items = gear.values() if isinstance(gear, dict) else gear
    ids = sorted(str(i.get("id")) for i in items if isinstance(i, dict) and i.get("id"))
    was = [k for k in (c.get("was") or []) if isinstance(k, str)] if isinstance(c.get("was"), list) else []
    return {"key": key, "was": was, "level": c.get("level"), "look": f"{c.get('level')}:{','.join(ids)}"}


def load_index(folder=CAPTURES):
    try:
        with open(os.path.join(folder, "captures.json")) as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def is_new_look(index, who, now):
    # The same character, under its key now or one it was kept under before.
    keys = {who["key"], *who.get("was", [])}
    mine = [m for m in index.values() if isinstance(m, dict) and m.get("key") in keys]
    if not mine:
        return True
    latest = max(mine, key=lambda m: m.get("t") or 0)
    return latest.get("look") != who["look"] or now - (latest.get("t") or 0) >= REFRESH


def file_capture(full, who, folder=CAPTURES, now=None):
    now = now or time.time()
    os.makedirs(folder, exist_ok=True)
    name = time.strftime("select-%Y%m%d-%H%M%S.png", time.localtime(now))
    if not crop_her(full, os.path.join(folder, name)):
        return None
    index = load_index(folder)
    index[name] = {"key": who["key"], "t": now, "level": who["level"], "look": who["look"]}
    tmp = os.path.join(folder, "captures.json.part")
    with open(tmp, "w") as f:
        json.dump(index, f, indent=1)
    os.replace(tmp, os.path.join(folder, "captures.json"))
    return name


# ---------------------------------------------------------------------------
# The service
# ---------------------------------------------------------------------------
def save_mtime(game=GAME):
    return max((os.path.getmtime(p) for p in glob.glob(os.path.join(game, "WTF", "Account", "*", "SavedVariables", "Reliquary.lua"))), default=None)


def watch():
    log(f"watching for the character screen (captures in {CAPTURES})")
    was_running, last_save, until, hits = False, save_mtime(), 0.0, 0
    with tempfile.TemporaryDirectory(prefix="reliquary-select-") as work:
        while True:
            now = time.time()
            running = game_running()
            saved = save_mtime()
            if running and not was_running:
                until = now + WATCH_FOR
                log("game started: watching")
            elif running and saved != last_save:
                until = now + WATCH_FOR
                log("game saved (a logout or /reload): watching")
            was_running, last_save = running, saved
            if not running or now > until:
                hits = 0
                time.sleep(POLL)
                continue
            win = game_window()
            small = os.path.join(work, "small.png")
            if not win or not grab(win, small, 0.25):
                hits = 0
                time.sleep(POLL)
                continue
            hits = hits + 1 if anchor_score(small, work) < ANCHOR_MAX else 0
            if hits >= 2:
                time.sleep(SETTLE)
                clients = hypr("clients")
                win = game_window(clients)
                full = os.path.join(work, "full.png")
                blocker = win and covered(win, clients)
                if blocker:
                    log(f"character screen, but {blocker} is over her; trying again")
                elif win and grab(win, full) and grab(win, small, 0.25) and anchor_score(small, work) < ANCHOR_MAX:
                    who = last_played()
                    if not who:
                        log("character screen, but no character recorded yet")
                    elif is_new_look(load_index(), who, now):
                        log(f"captured {who['key']}: {file_capture(full, who)}")
                    else:
                        log(f"character screen, same look as the last capture of {who['key']}: not filed again")
                    until, hits = 0.0, 0
            time.sleep(POLL)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--once", metavar="STILL", help="crop and file an existing full-size still of the character screen")
    args = ap.parse_args()
    if args.once:
        who = last_played()
        if not who:
            sys.exit("no character recorded yet")
        print(file_capture(args.once, who))
        return
    watch()


if __name__ == "__main__":
    main()
