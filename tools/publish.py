#!/usr/bin/env python3
"""Keeps the public copy of Reliquary (https://reliquary.libertyhillstudio.com/) up to date.

The public copy runs on another machine, reached over SSH (reliquary-public.service, tools/public-copy/),
in read-only mode:
no folder names, only photos taken with the interface hidden, no portrait choosing. This sends
it what it reads, only when something changed (checked every few seconds, a few file times):

- the saved files Reliquary reads, cut first to what the public copy may show
  (server/reliquary.py public_cut): of Reliquary.lua only the characters that share publicly,
  never the guild, the guild bank or what other players share with you; of Total RP 3's
  totalRP3.lua only those characters' own profiles. Nothing else from WTF;
- auction prices (server/reliquary.py public_prices): Blizzard's hourly prices alone, never a scan
  made in the game, for the houses those characters can use and the items they show, with their
  thirty days;
- the game's screenshots, the character-screen captures and the chosen portraits;
- the program itself (server, page, data), restarting the public copy when the server changed;
- the link preview: when what it shows changes (her name, level, place, portrait, a new photo, or
  the card's own design), headless Chromium photographs the public copy's /card.html through an
  SSH tunnel and the picture goes to that machine as data/card.jpg (served as /card.jpg).

RELIQUARY_PUBLIC_HOST names that machine as ssh knows it (a host name or an entry in ~/.ssh/config).

    python3 tools/publish.py            # the service (reliquary-publish.service)
    python3 tools/publish.py --once     # send everything now
    python3 tools/publish.py --install  # put the public copy's unit on that machine and start it
"""
import argparse
import glob
import importlib
import json
import shutil
import sys
import socket
import tempfile
import urllib.parse
import urllib.request
import os
import subprocess
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "server"))
import luasv  # noqa: E402
import reliquary  # noqa: E402
GAME = os.path.join(os.environ.get("WOW_FOREVER", "/mnt/games/wow-forever"), "_forever_")
CAPTURES = os.path.join(os.environ.get("XDG_DATA_HOME", os.path.expanduser("~/.local/share")), "reliquary", "captures")
CHOICES = os.path.join(os.environ.get("XDG_STATE_HOME", os.path.expanduser("~/.local/state")), "reliquary", "choices.json")
CUT = os.path.join(os.environ.get("XDG_CACHE_HOME", os.path.expanduser("~/.cache")), "reliquary", "public-cut")  # what goes to the public copy
CUT_PRICES = os.path.join(os.path.dirname(CUT), "public-prices.json")  # and its prices
REMOTE = os.environ.get("RELIQUARY_PUBLIC_HOST", "")
REMOTE_DIR = "hosting/reliquary"   # in the home folder there
UNIT = "reliquary-public.service"
POLL = 4        # seconds between looks
SETTLE = 2      # the game writes several files in a row on a save: let it finish
CODE = ("server", "web", "data")
RESTART_ON = ("server", "data")  # read once at start; page files are read on each request
CARD_FILES = ("web/card.html", "web/card.css", "web/card.js", "web/app.css", "web/art/lhs-mark.svg", "web/fonts")
CHROMIUM = shutil.which("chromium") or shutil.which("chromium-browser")
RSYNC = ["rsync", "-a", "--delete", "--prune-empty-dirs", "--exclude", "__pycache__", "--exclude", ".*",
         "-e", "ssh -o BatchMode=yes -o ConnectTimeout=15"]


def log(msg):
    print(time.strftime("%H:%M:%S"), msg, flush=True)


def ssh(*cmd):
    return subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", REMOTE, *cmd],
                          capture_output=True, text=True, timeout=120)


def rsync(args):
    r = subprocess.run(RSYNC + args, capture_output=True, text=True, timeout=600)
    if r.returncode != 0:
        raise RuntimeError(f"rsync {' '.join(args[-2:])}: {r.stderr.strip()[-300:]}")


def times(paths):
    """A signature of these files and folders: their names and modification times."""
    out = []
    for top in paths:
        if os.path.isfile(top):
            out.append((top, os.path.getmtime(top)))
            continue
        for d, dirs, files in os.walk(top):
            dirs[:] = sorted(x for x in dirs if not x.startswith(".") and x != "__pycache__")
            out.append((d, os.path.getmtime(d)))
            for f in sorted(files):
                if not f.startswith("."):
                    p = os.path.join(d, f)
                    try:
                        out.append((p, os.path.getmtime(p)))
                    except OSError:
                        pass
    return tuple(out)


def saved_files():
    return sorted(glob.glob(os.path.join(GAME, "WTF", "Account", "*", "SavedVariables", n))
                  for n in ("Reliquary.lua", "totalRP3.lua"))


def data_sig():
    files = [p for group in saved_files() for p in group]
    return times(files + [p for p in (os.path.join(GAME, "Screenshots"), CAPTURES, CHOICES, reliquary.BLIZZARD, reliquary.API_PRICES)
                          if os.path.exists(p)])


def code_sig(parts=CODE):
    return times([os.path.join(ROOT, p) for p in parts])


def write_if_changed(path, text):
    try:
        with open(path, encoding="utf-8") as f:
            if f.read() == text:
                return
    except OSError:
        pass
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path + ".part", "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(path + ".part", path)


def cut_saved_files(wtf, dest):
    """Writes each account's saved files, cut to what the public copy may show, under dest
    (same layout as WTF/Account). A file the game is still writing is left as last cut."""
    keep = set()
    for path in sorted(glob.glob(os.path.join(wtf, "*", "SavedVariables", "Reliquary.lua"))):
        account = os.path.basename(os.path.dirname(os.path.dirname(path)))
        try:
            cut = reliquary.public_cut(luasv.load(path))
        except (OSError, luasv.ParseError):
            keep.add(account)
            continue
        out = os.path.join(dest, account, "SavedVariables")
        write_if_changed(os.path.join(out, "Reliquary.lua"), "\n" + luasv.dumps(cut))
        keep.add(account)
        names = [c.get("name") for c in cut["ReliquaryDB"]["chars"].values() if c.get("name")]
        trp = os.path.join(os.path.dirname(path), "totalRP3.lua")
        try:
            write_if_changed(os.path.join(out, "totalRP3.lua"), "\n" + luasv.dumps(reliquary.public_cut_trp3(luasv.load(trp), names)))
        except FileNotFoundError:
            try:
                os.remove(os.path.join(out, "totalRP3.lua"))
            except OSError:
                pass
        except (OSError, luasv.ParseError):
            pass
    for old in glob.glob(os.path.join(dest, "*")):
        if os.path.basename(old) not in keep:
            shutil.rmtree(old)


def cut_prices_file(cut, dest):
    """Writes the public copy's auction prices, for the characters in the cut saved files (cut)."""
    chars = reliquary.build_state(cut, public=True)["chars"]
    write_if_changed(dest, json.dumps(reliquary.public_prices(chars), separators=(",", ":"), sort_keys=True))


def send_data():
    ssh("mkdir", "-p", f"{REMOTE_DIR}/data/Account", f"{REMOTE_DIR}/data/Screenshots", f"{REMOTE_DIR}/data/captures")
    # The saved files cut to what the public copy may show; the full ones never leave this PC.
    cut_saved_files(os.path.join(GAME, "WTF", "Account"), CUT)
    rsync([f"{CUT}/", f"{REMOTE}:{REMOTE_DIR}/data/Account/"])
    cut_prices_file(CUT, CUT_PRICES)
    rsync([CUT_PRICES, f"{REMOTE}:{REMOTE_DIR}/data/prices.json"])
    if os.path.isdir(os.path.join(GAME, "Screenshots")):
        rsync(["--exclude", "*/", f"{GAME}/Screenshots/", f"{REMOTE}:{REMOTE_DIR}/data/Screenshots/"])
    if os.path.isdir(CAPTURES):
        rsync([f"{CAPTURES}/", f"{REMOTE}:{REMOTE_DIR}/data/captures/"])
    if os.path.isfile(CHOICES):
        rsync([CHOICES, f"{REMOTE}:{REMOTE_DIR}/data/choices.json"])
    else:
        ssh("rm", "-f", f"{REMOTE_DIR}/data/choices.json")


def send_code(restart):
    ssh("mkdir", "-p", f"{REMOTE_DIR}/app")
    for part in CODE:
        rsync([os.path.join(ROOT, part) + "/", f"{REMOTE}:{REMOTE_DIR}/app/{part}/"])
    if restart:
        # The unit's command line may have changed with the program.
        rsync([os.path.join(ROOT, "tools", "public-copy", UNIT), f"{REMOTE}:.config/systemd/user/{UNIT}"])
        r = ssh("systemctl", "--user", "daemon-reload", "&&", "systemctl", "--user", "restart", UNIT)
        if r.returncode != 0:
            raise RuntimeError(f"restart {UNIT}: {r.stderr.strip()}")


class Tunnel:
    """A local port reaching the public copy over SSH, so the card is photographed
    from exactly what friends see, without going through Cloudflare (or counting as a visit)."""

    def __enter__(self):
        with socket.socket() as s:
            s.bind(("127.0.0.1", 0))
            self.port = s.getsockname()[1]
        self.proc = subprocess.Popen(["ssh", "-N", "-o", "BatchMode=yes", "-o", "ExitOnForwardFailure=yes",
                                      "-L", f"127.0.0.1:{self.port}:127.0.0.1:27635", REMOTE],
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.base = f"http://127.0.0.1:{self.port}"
        for _ in range(60):
            try:
                with urllib.request.urlopen(self.base + "/healthz", timeout=2):
                    return self
            except OSError:
                if self.proc.poll() is not None:
                    break
                time.sleep(0.25)
        self.__exit__()
        raise RuntimeError("could not reach the public copy through SSH")

    def get(self, path, timeout=60):
        with urllib.request.urlopen(self.base + path, timeout=timeout) as r:
            return r.read()

    def __exit__(self, *exc):
        self.proc.terminate()
        try:
            self.proc.wait(5)
        except subprocess.TimeoutExpired:
            self.proc.kill()


def card_inputs(state):
    """What the card shows (web/card.js), so it is rendered again only when that changes."""
    c = (state.get("chars") or [None])[0]
    if not c:
        return None
    keep = ("name", "level", "race", "class", "classFile", "subzone", "zone", "faction", "rulesetLabel")
    return json.dumps({"c": {k: c.get(k) for k in keep},
                       "profile": {k: (c.get("profile") or {}).get(k) for k in ("first", "last", "fullTitle")},
                       "portrait": c.get("portrait"), "photos": [[p["file"], p.get("kind")] for p in c.get("photos") or []]},
                      sort_keys=True)


def render_card(t, state):
    """Photographs /card.html at twice the size and keeps a sharp 1200x630 JPEG of it."""
    c = state["chars"][0]
    # Make the web copies the card shows first, so the photograph never catches one still loading.
    for p in c.get("photos") or []:
        for v in ("tall", "full"):
            t.get(f"/shot/{urllib.parse.quote(p['file'])}?v={v}", timeout=120)
    with tempfile.TemporaryDirectory(prefix="reliquary-card-") as work:
        big, out = os.path.join(work, "card@2x.png"), os.path.join(work, "card.jpg")
        r = subprocess.run(["nice", "-n", "19", CHROMIUM, "--headless=new", "--no-first-run", "--mute-audio",
                            "--disable-extensions", f"--user-data-dir={work}/profile", "--hide-scrollbars",
                            "--force-device-scale-factor=2", "--window-size=1200,630", "--virtual-time-budget=15000",
                            f"--screenshot={big}", t.base + "/card.html"], capture_output=True, text=True, timeout=120)
        if r.returncode != 0 or not os.path.exists(big):
            raise RuntimeError(f"chromium could not photograph the card: {r.stderr.strip()[-300:]}")
        r = subprocess.run(["nice", "-n", "19", "magick", big, "-filter", "Lanczos", "-resize", "1200x630!",
                            "-strip", "-quality", "90", "-sampling-factor", "4:2:0", out], capture_output=True, text=True, timeout=60)
        if r.returncode != 0:
            raise RuntimeError(f"magick: {r.stderr.strip()[-300:]}")
        rsync([out, f"{REMOTE}:{REMOTE_DIR}/data/card.jpg"])


def update_card(last):
    """Renders the card again if what it shows changed since `last`; returns the new signature."""
    if not CHROMIUM:
        return last
    with Tunnel() as t:
        state = json.loads(t.get("/api/state"))
        sig = (card_inputs(state), code_sig(CARD_FILES))
        if sig[0] is None or sig == last:
            return sig
        render_card(t, state)
        log("link preview card made")
        return sig


def compiles():
    """Whether the server's Python parses: a file saved mid-edit never reaches the public copy."""
    files = glob.glob(os.path.join(ROOT, "server", "*.py"))
    r = subprocess.run([sys.executable, "-c", "import ast,sys\nfor f in sys.argv[1:]: ast.parse(open(f).read(), f)", *files],
                       capture_output=True, text=True, timeout=60)
    return r.returncode == 0


def install():
    send_code(False)
    send_data()
    # (the card follows once the unit runs: the service's first pass makes it)
    unit = os.path.join(ROOT, "tools", "public-copy", UNIT)
    subprocess.run(["scp", "-q", "-o", "BatchMode=yes", unit, f"{REMOTE}:.config/systemd/user/{UNIT}"], check=True)
    r = ssh("systemctl", "--user", "daemon-reload", "&&", "systemctl", "--user", "enable", "--now", UNIT,
            "&&", "systemctl", "--user", "restart", UNIT)
    if r.returncode != 0:
        sys.exit(f"could not start {UNIT} on {REMOTE}: {r.stderr.strip()}")
    log(f"{UNIT} running on {REMOTE}")


def watch():
    log(f"sending changes to {REMOTE}:{REMOTE_DIR} every {POLL} s")
    last_data, last_code, last_restart, last_card = None, None, None, None
    card_due = True
    failures = 0
    while True:
        try:
            data, code, restart = data_sig(), code_sig(), code_sig(RESTART_ON)
            if code != last_code:
                time.sleep(SETTLE)
                code, restart = code_sig(), code_sig(RESTART_ON)
                if not compiles():
                    time.sleep(POLL)  # mid-edit: the public copy keeps running what it has
                    continue
                # The cut follows the server's rules: use the new ones from now on.
                importlib.reload(luasv)
                importlib.reload(reliquary)
                # At start the public copy may be running an older program: restart it then too.
                again = last_restart is None or restart != last_restart
                send_code(again)
                log("program sent" + (" and the public copy restarted" if again else ""))
                last_code, last_restart = code, restart
                card_due = True
            if data != last_data:
                time.sleep(SETTLE)
                data = data_sig()
                send_data()
                log("saved data and photos sent")
                last_data = data
                card_due = True
            if card_due:
                last_card = update_card(last_card)
                card_due = False
            failures = 0
        except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as e:
            failures += 1
            log(f"could not send ({e}); trying again")
            time.sleep(min(300, POLL * 2 ** min(failures, 6)))
            continue
        time.sleep(POLL)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--once", action="store_true", help="send everything now")
    ap.add_argument("--install", action="store_true", help="install and start the public copy on RELIQUARY_PUBLIC_HOST")
    args = ap.parse_args()
    if not REMOTE:
        sys.exit("Set RELIQUARY_PUBLIC_HOST to the machine that serves the public copy (as ssh knows it).")
    if args.install:
        install()
    elif args.once:
        send_code(True)
        send_data()
        update_card(None)
        log("sent")
    else:
        watch()


if __name__ == "__main__":
    main()
