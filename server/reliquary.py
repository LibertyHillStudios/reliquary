#!/usr/bin/env python3
"""Reliquary: serves the character dashboard from WoW: Forever's saved addon data.

Reads WTF/Account/*/SavedVariables/Reliquary.lua (written by the Reliquary addon when
you log out or /reload), Total RP 3's profile and the game's Screenshots folder, and
serves the page, a JSON state, a live "something changed" stream, the item and spell
icons and web-sized copies of the screenshots. Read-only: it never writes into the game
folder. The one thing it stores is which photo you chose as a character's portrait.

The saved data also holds what other players share with you in game (their reliquaries,
your guild's roster and bank). Only your own copy shows those: the public copy (--public)
shows nothing of anyone else's, and only your characters that share publicly.

    python3 server/reliquary.py [--port 8741] [--wtf <WTF/Account folder>] [--shots <Screenshots folder>]
"""
import argparse
import fcntl
import glob
import gzip
import hashlib
import html
import json
import os
import re
import struct
import subprocess
import threading
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, quote, unquote, urlparse

import luasv
import roleplay
import timeline

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WEB = os.path.join(ROOT, "web")
DATA = os.path.join(ROOT, "data")
SAMPLE = os.path.join(DATA, "sample", "Reliquary.lua")
PROFILE_TEXT = os.path.expanduser("~/Games/wow-workspace/lore/joan-ofarc/trp3-profile.txt")
ICON_CACHE = os.path.join(os.environ.get("XDG_CACHE_HOME", os.path.expanduser("~/.cache")), "reliquary", "icons")
ICON_SOURCES = (
    "https://render.worldofwarcraft.com/us/icons/56/{}.jpg",
    "https://wow.zamimg.com/images/wow/icons/large/{}.jpg",
)
MISSING_RETRY = 7 * 86400
ICON_FETCHES = 6  # icons fetched at once ahead of a page (warm_icons)
WATCH_EVERY = 3   # seconds between looks for a new save, to build its state and fetch its icons
SHOT_CACHE = os.path.join(os.environ.get("XDG_CACHE_HOME", os.path.expanduser("~/.cache")), "reliquary", "shots")
# Pictures of the character screen, taken by tools/select-capture.py (addons cannot run there).
CAPTURES = os.path.join(os.environ.get("XDG_DATA_HOME", os.path.expanduser("~/.local/share")), "reliquary", "captures")
CHOICES = os.path.join(os.environ.get("XDG_STATE_HOME", os.path.expanduser("~/.local/state")), "reliquary", "choices.json")
# Thirty days of auction prices, a point a day for each item, as this PC saw the addon's scans.
PRICES = os.path.join(os.environ.get("XDG_STATE_HOME", os.path.expanduser("~/.local/state")), "reliquary", "prices.json")
# Blizzard's web API prices for the houses matched to yours (tools/blizzard_prices.py).
BLIZZARD = os.path.join(os.environ.get("XDG_STATE_HOME", os.path.expanduser("~/.local/state")), "reliquary", "blizzard.json")
# Thirty days of Blizzard's prices alone (kept by tools/blizzard_prices.py): what the public copy's
# thirty days are drawn from.
API_PRICES = os.path.join(os.environ.get("XDG_STATE_HOME", os.path.expanduser("~/.local/state")), "reliquary", "blizzard-history.json")
# Any picture in the Screenshots folder (no folders, nothing hidden). The game's usual name,
# WoWScrnShot_MMDDYY_HHMMSS, carries the time it was taken; any other name falls back to the
# time the file was written, which is within a second of it.
SHOT_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9_\-. ]{0,120}\.(jpe?g|png|tga)", re.I)
SHOT_STAMP = re.compile(r"WoWScrnShot_(\d{6})_(\d{6})", re.I)
# Web copies: thumb for the album grid, tall for the portrait (full height), full for the viewer.
SHOT_VARIANTS = {"thumb": "x420>", "tall": "x1200>", "full": "2560x1600>", "face": "640x640", "card": "600x600"}
FACE_VARIANTS = ("face", "card")  # "card" is the link preview chat apps show: a JPEG, which every one of them reads
# Her head and shoulders for the round portrait, as fractions: on a character-screen capture
# (her head sits a little left of centre at the top), and on a game screenshot (the camera
# keeps her in the middle). Square sides are fractions of the width and the height respectively.
FACE_CAPTURE = {"x": 0.34, "y": 0.05, "side": 0.48}
FACE_SCREENSHOT = {"cx": 0.5, "cy": 0.42, "side": 0.55}


def face_crop(width, height, from_capture):
    """The square (side, x, y) holding her head and shoulders."""
    if from_capture:
        side = round(FACE_CAPTURE["side"] * width)
        return side, round(FACE_CAPTURE["x"] * width), round(FACE_CAPTURE["y"] * height)
    side = round(FACE_SCREENSHOT["side"] * height)
    return side, round(FACE_SCREENSHOT["cx"] * width - side / 2), round(FACE_SCREENSHOT["cy"] * height - side / 2)
STAMP_SLACK = 4  # seconds between the game naming or writing the file and the addon's note
PORTRAIT_KINDS = ("select", "portrait", "levelup", "photo", "place")  # best first; never a plain Print Screen
# The public copy (--public) shows only pictures taken with the interface hidden: a Print Screen
# can show chat, other players' names and whispers. Guesses (no note yet) wait for the next save.
PUBLIC_KINDS = PORTRAIT_KINDS
PUBLIC_STREAMS = 64  # live "something changed" streams the public copy holds open at once
# The public copy's pages may only load what this server sends (inline style attributes are the
# page's own layout values; no inline script), plus the visit counter Cloudflare adds to every
# libertyhillstudio.com page (Web Analytics).
PUBLIC_HEADERS = {
    "Content-Security-Policy": "default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; "
                               "script-src 'self' https://static.cloudflareinsights.com; "
                               "connect-src 'self' https://cloudflareinsights.com; font-src 'self'; object-src 'none'; "
                               "base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
    "Referrer-Policy": "same-origin",
    "X-Robots-Tag": "noindex, nofollow",
}

with open(os.path.join(DATA, "icons.json")) as f:
    ICONS = json.load(f)
roleplay.ICON_IDS.update({name: int(fid) for fid, name in ICONS.items()})

RULESETS = {"rppvp": "RP-PvP", "rp": "Roleplaying", "pvp": "PvP", "normal": "Normal", "hardcore": "Hardcore"}
SCOPES = {"g": "guild", "f": "friends", "p": "public"}  # how another player shares with you, by the addon's letter
# The parts of a character its player chooses to show, to whom (as the addon's letters), and the
# fields each part covers: as the page gets them, and the extra ones the saved file holds. On the
# public copy "where you are" also covers the timeline of where it has been (with what the game
# remembered from before Reliquary, char.before) and where each photo
# was taken: a photo of a new place is taken the moment she arrives, so its caption would say where
# she is now.
PARTS = ("gear", "talents", "profs", "stats", "gold", "place", "played", "reps", "quests", "bags", "bank")
# A part nobody chose for, in a file saved by 1.7.0 or earlier (the rest: nobody). Since then the addon
# writes every part of every character down, a new one's to its guild and friends.
PART_DEFAULT = {"gear": "gfp", "talents": "gfp", "profs": "gfp", "stats": "gfp"}
PART_FIELDS = {
    "gear": ("gear", "durability"), "talents": ("talents", "legacy"), "profs": ("profs", "skills", "recipes"),
    "stats": ("stats", "health", "healthMax", "power", "powerMax", "powerToken", "mana", "manaMax"),
    "gold": ("money",), "place": ("zone", "subzone", "mapName", "x", "y", "hearth", "journey"), "played": ("played", "playedLevel"),
    "reps": ("reps",), "quests": ("quests",), "bags": ("bags",), "bank": ("bank", "bankAt"),
}
RAW_PART_FIELDS = dict(PART_FIELDS, stats=PART_FIELDS["stats"] + ("powerType",), place=PART_FIELDS["place"] + ("mapID", "places", "timeline", "before"),
                       played=PART_FIELDS["played"] + ("playedAt",))
PHOTO_PLACE = ("zone", "sub", "spot")  # where a photo was taken, in the addon's note and on the page
VIEW_KEEP = 30 * 86400  # the addon's own limit (Share.lua): bank tab permissions count this long after a visit


# ---------------------------------------------------------------------------
# Text from the game: colour codes, textures and line breaks
# ---------------------------------------------------------------------------
_CODES = re.compile(r"\|c[0-9a-fA-F]{8}|\|r|\|T[^|]*\|t|\|A[^|]*\|a|\|H[^|]*\|h|\|h")
# The game's "|4singular:plural;": the word agreeing with the number before it ("1 |4Sec:Sec;").
_PLURAL = re.compile(r"(\d[\d,]*(?:\.\d+)?)?(\s*)\|4([^:;|]*):([^;|]*);")


def _agree(m):
    num, gap, one, many = m.groups()
    if num is None:
        return gap + many
    return num + gap + (one if float(num.replace(",", "")) == 1 else many)


def clean(s):
    if not isinstance(s, str):
        return s
    return _CODES.sub("", _PLURAL.sub(_agree, s)).replace("|n", "\n").replace("||", "|").strip()


def as_slots(v):
    """Gear and bag slots arrive as a list when every slot is filled, else a dict."""
    if isinstance(v, list):
        return {str(i + 1): x for i, x in enumerate(v)}
    if isinstance(v, dict):
        return {str(k): x for k, x in v.items()}
    return {}


def as_list(v):
    if isinstance(v, list):
        return v
    if isinstance(v, dict):
        return [v[k] for k in sorted(v, key=lambda k: (not isinstance(k, int), k))]
    return []


# The game's line for a part of a tooltip it hadn't loaded when the addon read it (RETRIEVING_ITEM_INFO,
# English as Forever's client is). Never shown: the addon reads such a tooltip again (Reliquary.lua),
# and an older save keeps it until the item is seen again.
LOADING_LINE = "Retrieving item information"


def tip(lines):
    out = []
    for line in as_list(lines):
        if not isinstance(line, dict):
            continue
        row = {"l": clean(line.get("l")), "lc": line.get("lc"), "r": clean(line.get("r")), "rc": line.get("rc")}
        if row["l"] == LOADING_LINE:
            continue
        out.append({k: v for k, v in row.items() if v})
    return out


ITEM_FACTS = ("q", "icon", "ilvl", "req", "kind", "sub", "loc", "sell", "bind", "stack", "cls", "scls", "reagent")


def item_facts(rec):
    """An item's details as the game gives them (GetItemInfo): quality, icon, levels, kind, slot,
    sell price and how it binds, with its name."""
    out = {k: rec.get(k) for k in ITEM_FACTS}
    out["name"] = clean(rec.get("name"))
    return {k: v for k, v in out.items() if v is not None}


def item(rec):
    if not isinstance(rec, dict):
        return None
    out = {k: rec[k] for k in ("id", "q", "icon", "ilvl", "req", "kind", "sub", "loc", "n", "sell") if k in rec}
    out["name"] = clean(rec.get("name")) or (f"Item {rec['id']}" if rec.get("id") else "Unknown item")
    if rec.get("dur"):
        out["dur"] = as_list(rec["dur"])
    if rec.get("tip"):
        out["tip"] = tip(rec["tip"])
    return out


# ---------------------------------------------------------------------------
# Recipes (Crafting.lua): your characters' own, and those others share with their professions
# ---------------------------------------------------------------------------
DIFFICULTY = {0: "optimal", 1: "medium", 2: "easy", 3: "trivial"}  # how a recipe would skill up, as the game colours it


def practised(c, name, line):
    """Whether a character still practises a profession (by name or skill line); before its
    professions were read, every profession its windows were read for counts."""
    profs = [p for p in as_list(c.get("profs")) if isinstance(p, dict)]
    if not profs:
        return True
    return any(p.get("name") == name or (line is not None and p.get("line") == line) for p in profs)


def recipe_uses(lst):
    return [{"id": u["id"], "n": u.get("n") or 1} for u in as_list(lst) if isinstance(u, dict) and isinstance(u.get("id"), int)]


def recipe_order(rows):
    rows.sort(key=lambda r: ((r.get("name") or "").casefold(), r["rid"]))
    return rows


def own_recipes(c):
    """A character's recipes for its page: each profession whose window has been read and that it
    still practises, with its skill when read, and its recipes by name: what each makes (and how
    many), what goes into it, its group in the window and how it would skill up."""
    out = []
    raw = c.get("recipes") if isinstance(c.get("recipes"), dict) else {}
    for name, p in sorted(raw.items()):
        if not isinstance(p, dict) or not isinstance(name, str) or not practised(c, name, p.get("line")):
            continue
        cats = as_map(p.get("cats"))
        rows = []
        for rid, r in as_map(p.get("list")).items():
            if not isinstance(r, dict) or not isinstance(rid, int):
                continue
            row = {"rid": rid, "name": clean(r.get("n")), "icon": r.get("ic"), "cat": clean(cats.get(r.get("c"))) if r.get("c") is not None else None,
                   "diff": DIFFICULTY.get(r.get("d")), "uses": recipe_uses(r.get("u"))}
            if isinstance(r.get("o"), int):
                row["makes"] = {"id": r["o"], "n": r.get("k") or 1}
            rows.append({k: v for k, v in row.items() if v not in (None, [], "")})
        out.append({"name": clean(name), "line": p.get("line"), "at": p.get("at"), "skill": p.get("sk"), "max": p.get("mx"), "recipes": recipe_order(rows)})
    return out


def peer_recipes(craft, card):
    """Another player's recipes as they share them (the "craft" section of their card): each
    profession with its recipes, named by your own game."""
    skills = {x.get("n"): x for x in as_list((card or {}).get("profs")) if isinstance(x, dict)}
    out = []
    for p in as_list(craft.get("list")):
        if not isinstance(p, dict) or not clean(p.get("n")):
            continue
        cats = as_list(p.get("c"))
        rows = []
        for r in as_list(p.get("r")):
            if not isinstance(r, dict) or not isinstance(r.get("id"), int):
                continue
            ci = r.get("c")
            row = {"rid": r["id"], "name": clean(r.get("nm")), "icon": r.get("ic") if isinstance(r.get("ic"), int) else None,
                   "cat": clean(cats[ci - 1]) if isinstance(ci, int) and 0 < ci <= len(cats) else None, "uses": recipe_uses(r.get("u"))}
            if isinstance(r.get("o"), int):
                row["makes"] = {"id": r["o"], "n": 1}
            rows.append({k: v for k, v in row.items() if v not in (None, [], "")})
        sk = skills.get(p.get("n")) or {}
        out.append({"name": clean(p["n"]), "line": p.get("l"), "at": p.get("at"), "skill": sk.get("sk"), "max": sk.get("mx"), "recipes": recipe_order(rows)})
    return out


def recipe_items(recipes):
    """Every item a list of professions' recipes makes or uses, as {"id": n} records."""
    for p in recipes or []:
        for r in p.get("recipes", []):
            if r.get("makes"):
                yield r["makes"]
            yield from r.get("uses", [])


# ---------------------------------------------------------------------------
# Total RP 3 profile, and the prepared profile text for what isn't pasted in yet
# ---------------------------------------------------------------------------
def trp3_names(key, name):
    """Whether Total RP 3's character key (name-realm, or its full name) is this character."""
    return key == name or key.split("-")[0] == name or key.split(" ")[0] == name


def trp3_player(trp, name, surname=None):
    """One of your characters' own Total RP 3 profile (its characteristics, about, character and
    misc), found by its full name where the game has family names, else by name."""
    if not trp or not name:
        return None
    chars = trp.get("TRP3_Characters") or {}
    profiles = trp.get("TRP3_Profiles") or {}
    full = f"{name} {surname}" if surname else None
    key = (full if full in chars else None) or next((k for k in chars if trp3_names(k, name)), None)
    pid = key and (chars[key] or {}).get("profileID")
    prof = profiles.get(pid) if pid else None
    player = prof.get("player") if isinstance(prof, dict) else None
    return player if isinstance(player, dict) else None


def trp3_profile(trp, name, surname=None):
    player = trp3_player(trp, name, surname)
    if not player:
        return None
    ch = player.get("characteristics") or {}
    cr = player.get("character") or {}
    ab = player.get("about") or {}
    misc = {}
    for m in as_list(ch.get("MI")):
        if isinstance(m, dict) and m.get("NA") and m.get("VA"):
            misc[clean(m["NA"])] = clean(m["VA"])
    t3 = ab.get("T3") or {}
    about = {
        "physical": clean((t3.get("PH") or {}).get("TX")),
        "personality": clean((t3.get("PS") or {}).get("TX")),
        "history": clean((t3.get("HI") or {}).get("TX")),
        "text": clean((ab.get("T1") or {}).get("TX")),
    }
    fields = {
        "first": clean(ch.get("FN")), "last": clean(ch.get("LN")), "title": clean(ch.get("TI")),
        "fullTitle": clean(ch.get("FT")), "race": clean(ch.get("RA")), "class": clean(ch.get("CL")),
        "age": clean(ch.get("AG")), "eyes": clean(ch.get("EC")), "eyeColor": ch.get("EH"),
        "birthplace": clean(ch.get("BP")), "residence": clean(ch.get("RE")), "height": clean(ch.get("HE")),
        "build": clean(ch.get("WE")), "currently": clean(cr.get("CU")), "ooc": clean(cr.get("CO")),
        "misc": misc, "about": {k: v for k, v in about.items() if v},
    }
    return {k: v for k, v in fields.items() if v}


_DRAFT_KEYS = {
    "first name": "first", "last name": "last", "title": "title", "full title": "fullTitle", "race": "race",
    "class": "class", "age": "age", "eye colour": "eyes", "birthplace": "birthplace", "residence": "residence",
}


def draft_profile():
    """The paste-ready profile text from the lore folder, as fields."""
    try:
        with open(PROFILE_TEXT, encoding="utf-8") as f:
            text = f.read()
    except OSError:
        return None
    out, misc, about, glances, house = {}, {}, {}, [], {}
    section = None
    para = []

    def end_para():
        if para and section:
            body = " ".join(para).strip()
            if section.startswith("ABOUT: PHYSICAL"):
                about["physical"] = body
            elif section.startswith("ABOUT: PERSONALITY"):
                about["personality"] = body
            elif section.startswith("ABOUT: HISTORY"):
                about["history"] = (about.get("history", "") + "\n\n" + body).strip()
            elif section == "CURRENTLY":
                out["currently"] = body
            elif section == "OOC INFO":
                out["ooc"] = body
        para.clear()

    for raw in text.splitlines():
        line = raw.strip()
        m = re.fullmatch(r"--- (.+?) ---", line)
        if m:
            end_para()
            section = m.group(1)
            continue
        if not line:
            end_para()
            continue
        if section in ("NAMES AND TITLES", "CHARACTERISTICS") and ":" in line:
            k, v = [x.strip() for x in line.split(":", 1)]
            key = _DRAFT_KEYS.get(k.lower())
            if key:
                out[key] = v
            elif k.lower() in ("nickname", "house name", "motto"):
                misc[k.title() if k.lower() != "house name" else "House name"] = v
        elif section == "AT FIRST GLANCE" and ":" in line:
            title, text = [x.strip() for x in line.split(":", 1)]
            glances.append({"title": title, "text": text})
        elif section and section.startswith("HOUSE") and ":" in line:
            k, v = [x.strip() for x in line.split(":", 1)]
            key = {"house motto": "motto", "house history": "history", "kinship glance": "glance"}.get(k.lower())
            if key:
                house[key] = v
        elif section and (section.startswith("ABOUT") or section in ("CURRENTLY", "OOC INFO")):
            para.append(line)
    end_para()
    if glances:
        out["glances"] = glances
    if house:
        out["house"] = house
    if misc:
        out["misc"] = misc
    if about:
        out["about"] = about
    return out


# ---------------------------------------------------------------------------
# Photos: the game's screenshots, matched to the addon's notes by their time stamp
# ---------------------------------------------------------------------------
def image_size(path):
    """Width and height from a JPEG, PNG or TGA header, without decoding the picture."""
    try:
        with open(path, "rb") as f:
            head = f.read(32)
            if head[:8] == b"\x89PNG\r\n\x1a\n":
                return struct.unpack(">II", head[16:24])
            if path.lower().endswith(".tga") and len(head) >= 16:
                return struct.unpack("<HH", head[12:16])
            if head[:2] == b"\xff\xd8":
                f.seek(2)
                while True:
                    marker = f.read(2)
                    if len(marker) < 2 or marker[0] != 0xFF:
                        return None
                    if marker[1] in (0xD8, 0x01) or 0xD0 <= marker[1] <= 0xD7:
                        continue
                    length = struct.unpack(">H", f.read(2))[0]
                    if 0xC0 <= marker[1] <= 0xCF and marker[1] not in (0xC4, 0xC8, 0xCC):
                        h, w = struct.unpack(">xHH", f.read(5))
                        return w, h
                    f.seek(length - 2, 1)
    except (OSError, struct.error):
        return None
    return None


_sizes = {}


def stamp_time(stamp):
    try:
        return time.mktime(time.strptime(stamp, "%m%d%y_%H%M%S"))
    except (TypeError, ValueError):
        return None


def screenshot_files(shots_dir):
    out = []
    try:
        names = os.listdir(shots_dir)
    except OSError:
        return out
    for name in names:
        m = SHOT_NAME.fullmatch(name)
        if not m:
            continue
        path = os.path.join(shots_dir, name)
        try:
            mtime = os.path.getmtime(path)
        except OSError:
            continue
        key = (name, mtime)
        if key not in _sizes:
            _sizes[key] = image_size(path)
        size = _sizes[key]
        if not size:
            continue  # still being written, or not a picture
        stamp = SHOT_STAMP.match(name)
        t = stamp_time(f"{stamp.group(1)}_{stamp.group(2)}") if stamp else None
        out.append({"file": name, "t": t or mtime, "w": size[0], "h": size[1]})
    return out


def load_captures():
    try:
        with open(os.path.join(CAPTURES, "captures.json")) as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def capture_files():
    """Character-screen pictures, each already tagged with its character by the capture tool."""
    out = []
    for name, meta in load_captures().items():
        if not (isinstance(meta, dict) and SHOT_NAME.fullmatch(name) and isinstance(meta.get("key"), str)):
            continue
        path = os.path.join(CAPTURES, name)
        size = image_size(path)
        if not size:
            continue
        out.append({"file": name, "t": meta.get("t") or os.path.getmtime(path), "w": size[0], "h": size[1],
                    "kind": "select", "key": meta["key"], "level": meta.get("level")})
    return out


def load_choices():
    try:
        with open(CHOICES) as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def save_choices(data):
    os.makedirs(os.path.dirname(CHOICES), exist_ok=True)
    tmp = CHOICES + ".part"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=1)
    os.replace(tmp, CHOICES)


def attach_photos(chars, shots_dir, public=False):
    """Gives each character its photos (newest first), picks its portrait and lays the photos on
    its timeline.

    A file is matched to the addon note whose stamp is within a few seconds of the file's
    name. A file with no note yet (taken before the next save, or before the addon noted
    photos) goes to the character saved most recently, marked as a guess. The public copy keeps
    only PUBLIC_KINDS."""
    notes = []
    for c in chars:
        for n in as_list(c.pop("_photos", None)):
            if isinstance(n, dict):
                t = stamp_time(n.get("stamp")) or n.get("t")
                if t:
                    notes.append((t, c, n))
    files = screenshot_files(shots_dir) if shots_dir else []
    used = set()
    for c in chars:
        c["photos"] = []
    for f in sorted(files, key=lambda f: f["t"]):
        best = None
        for i, (t, c, n) in enumerate(notes):
            if i in used or abs(t - f["t"]) > STAMP_SLACK:
                continue
            if best is None or abs(t - f["t"]) < abs(notes[best][0] - f["t"]):
                best = i
        rec = dict(f)
        if best is not None:
            used.add(best)
            _, owner, n = notes[best]
            for k in ("kind", "zone", "sub", "spot", "level", "form"):
                if n.get(k) is not None:
                    rec[k] = clean(n[k]) if isinstance(n[k], str) else n[k]
        elif chars:
            owner = chars[0]
            rec["guess"] = True
        else:
            continue
        if public and rec.get("kind") not in PUBLIC_KINDS:
            continue
        owner["photos"].append(rec)
    by_key = {}
    for c in chars:
        for k in c.get("_was", []):
            by_key.setdefault(k, c)
    by_key.update({c["key"]: c for c in chars})
    for rec in capture_files():
        owner = by_key.get(rec.pop("key"))
        if owner:
            owner["photos"].append(rec)
    choices = load_choices().get("portrait", {})
    for c in chars:
        c["photos"].sort(key=lambda p: -p["t"])
        chosen = choices.get(c["key"]) or next((choices[k] for k in reversed(c.get("_was", [])) if k in choices), None)
        c["portrait"] = pick_portrait(c["photos"], chosen)
        c.pop("_was", None)
        timeline.lay_photos(c.get("journey"), c["photos"])
    return chars


def pick_portrait(photos, chosen):
    if chosen and any(p["file"] == chosen for p in photos):
        return {"file": chosen, "chosen": True}
    # Otherwise the best kind of photo for a portrait, newest first, in her own shape if there
    # is one: a framed portrait (close, facing her), a level-up, one the player framed, a place.
    for own_shape in (True, False):
        for kind in PORTRAIT_KINDS:
            for p in photos:
                if p.get("kind") == kind and (not own_shape or not p.get("form")):
                    return {"file": p["file"], "chosen": False}
    return None


_shot_lock = threading.Lock()


def shot_bytes(shots_dir, name, variant):
    """A web copy of one screenshot (WebP; JPEG for "card"), made once with ImageMagick and cached on disk."""
    if not SHOT_NAME.fullmatch(name) or variant not in SHOT_VARIANTS:
        return None
    src = None
    for folder in (shots_dir, CAPTURES):
        if folder and os.path.isfile(os.path.join(folder, name)):
            src = os.path.join(folder, name)
            break
    if not src:
        return None
    mtime = int(os.path.getmtime(src))
    stem = os.path.splitext(name)[0]
    os.makedirs(SHOT_CACHE, exist_ok=True)
    ext = "jpg" if variant == "card" else "webp"
    out = os.path.join(SHOT_CACHE, f"{stem}-{variant}-{mtime}.{ext}")
    with _shot_lock:  # one conversion at a time keeps the PC quiet
        if not os.path.exists(out):
            tmp = f"{out}.part.{ext}"
            crop = []
            if variant in FACE_VARIANTS:
                size = image_size(src)
                if not size:
                    return None
                side, x, y = face_crop(size[0], size[1], os.path.dirname(src) == CAPTURES)
                # A plain Lanczos resize of the game's own pixels: nothing is drawn in.
                crop = ["-crop", f"{side}x{side}+{x}+{y}", "+repage", "-filter", "Lanczos"]
            r = subprocess.run(
                ["nice", "-n", "15", "magick", src, "-auto-orient", *crop, "-resize", SHOT_VARIANTS[variant],
                 "-quality", "88", "-define", "webp:method=5", tmp],
                capture_output=True, timeout=60)
            if r.returncode != 0 or not os.path.exists(tmp):
                return None
            os.replace(tmp, out)
            for old in glob.glob(os.path.join(SHOT_CACHE, f"{stem}-{variant}-*.{ext}")):
                if old != out:
                    os.remove(old)
    with open(out, "rb") as f:
        return f.read()


# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
def character(key, c, trp, draft):
    c = dict(c)
    out = {k: c.get(k) for k in (
        "name", "realm", "race", "raceFile", "class", "classFile", "sex", "faction", "level", "maxLevel",
        "guild", "guildRank", "title", "hearth", "xp", "xpMax", "rested", "resting", "money", "played",
        "playedLevel", "zone", "subzone", "mapName", "x", "y", "health", "healthMax", "power", "powerMax",
        "powerToken", "mana", "manaMax", "durability", "updated", "bankAt", "errors",
    )}
    out = {k: v for k, v in out.items() if v is not None}
    out["key"] = key
    # The keys it was kept under before (the addon moved it to its full name): its character-screen
    # captures and chosen portrait may still be filed under them.
    out["_was"] = [k for k in as_list(c.get("was")) if isinstance(k, str)]
    out["share"] = shared_with(c)
    out["ruleset"] = c.get("ruleset")
    out["rulesetLabel"] = RULESETS.get(c.get("ruleset"), None)
    out["stats"] = c.get("stats") or {}
    out["gear"] = {slot: item(rec) for slot, rec in as_slots(c.get("gear")).items() if isinstance(rec, dict)}

    def bags(lst):
        res = []
        for b in as_list(lst):
            if not isinstance(b, dict):
                continue
            res.append({
                "bag": b.get("bag"), "size": b.get("size", 0), "free": b.get("free", 0),
                "item": item(b.get("item")),
                "slots": {s: item(x) for s, x in as_slots(b.get("slots")).items() if isinstance(x, dict)},
            })
        return res

    out["bags"] = bags(c.get("bags"))
    out["bank"] = bags(c.get("bank"))
    t = c.get("talents")
    if isinstance(t, dict):
        out["talents"] = {
            "unspent": t.get("unspent"), "spent": t.get("spent"), "at": t.get("at"),
            "nodes": [dict(n, desc=clean(n.get("desc")), name=clean(n.get("name")), to=as_list(n.get("to"))) for n in as_list(t.get("nodes")) if isinstance(n, dict)],
        }
    lg = c.get("legacy")
    if isinstance(lg, dict):
        out["legacy"] = {
            "left": lg.get("left"), "spent": lg.get("spent"),
            "trees": [{"id": tr.get("id"), "nodes": [dict(n, desc=clean(n.get("desc")), to=as_list(n.get("to"))) for n in as_list(tr.get("nodes")) if isinstance(n, dict)]} for tr in as_list(lg.get("trees")) if isinstance(tr, dict)],
        }
    out["profs"] = as_list(c.get("profs"))
    out["skills"] = as_list(c.get("skills"))
    out["recipes"] = own_recipes(c)
    out["reps"] = as_list(c.get("reps"))
    out["quests"] = [dict(q, title=clean(q.get("title")), obj=[dict(o, text=clean(o.get("text"))) for o in as_list(q.get("obj"))]) for q in as_list(c.get("quests")) if isinstance(q, dict)]
    out["journey"] = timeline.build(c.get("timeline"), c.get("places") or {}, c.get("before"))  # server/timeline.py
    out["_photos"] = c.get("photos")
    profile = trp3_profile(trp, c.get("name"), c.get("surname"))
    out["profile"] = profile
    out["surname"] = clean(c.get("surname"))
    # Everything in her Total RP 3 profile (roleplay.py): traits, glances, roleplay style, status.
    out["rp"] = roleplay.card(trp3_player(trp, c.get("name"), c.get("surname")))
    is_joan = (c.get("name") or "").split(" ")[0] == "Joan" and (c.get("classFile") == "DRUID")
    if draft and is_joan:
        missing = {k: v for k, v in draft.items() if k not in (profile or {})}
        if isinstance(draft.get("about"), dict):
            have = (profile or {}).get("about", {})
            ab = {k: v for k, v in draft["about"].items() if k not in have}
            if ab:
                missing["about"] = ab
            else:
                missing.pop("about", None)
        if missing:
            out["profileDraft"] = missing
    return out


# ---------------------------------------------------------------------------
# Sharing: who sees each of your characters, and what others share with you
# ---------------------------------------------------------------------------
def part_letters(raw):
    """Who sees each part of a character, as the addon's letters (g, f, p); every part to everyone
    for data saved before sharing existed, which was all on the public page."""
    s = raw.get("share") if isinstance(raw, dict) else None
    if not isinstance(s, dict):
        return {p: "gfp" for p in PARTS}
    chosen = s.get("parts") if isinstance(s.get("parts"), dict) else {}
    return {p: chosen[p] if isinstance(chosen.get(p), str) else PART_DEFAULT.get(p, "") for p in PARTS}


def shared_with(raw):
    """A character's three switches and what each sees, or None for data saved before sharing existed."""
    s = raw.get("share") if isinstance(raw, dict) else None
    if not isinstance(s, dict):
        return None
    out = {k: s.get(k) is True for k in ("guild", "friends", "public")}
    out["parts"] = part_letters(raw)
    return out


def is_public(raw):
    """Whether the public copy shows a character: it shares publicly, or it was saved before
    sharing existed (every character was public then, and the addon keeps them so)."""
    s = shared_with(raw)
    return s is None or s["public"]


def hidden_parts(raw):
    """The parts of a public character the public copy leaves out."""
    letters = part_letters(raw)
    return [p for p in PARTS if "p" not in letters[p]]


def hide_parts(c, parts, fields=PART_FIELDS):
    """A character without these parts: lists and tables emptied (the page draws nothing for them), the rest removed."""
    out = dict(c)
    for part in parts:
        for k in fields[part]:
            if isinstance(out.get(k), list):
                out[k] = []
            elif isinstance(out.get(k), dict):
                out[k] = {}
            else:
                out.pop(k, None)
    if "place" in parts and isinstance(out.get("photos"), list):
        out["photos"] = [{k: v for k, v in p.items() if k not in PHOTO_PLACE} if isinstance(p, dict) else p for p in out["photos"]]
    # The average item level goes with the gear, as it does in game.
    ilvl = c["stats"].get("ilvl") if isinstance(c.get("stats"), dict) else None
    if "gear" in parts and isinstance(out.get("stats"), dict):
        out["stats"] = {k: v for k, v in out["stats"].items() if k != "ilvl"}
    elif "stats" in parts and ilvl is not None:
        out["stats"] = {"ilvl": ilvl}
    return out


def rp_norm(name):
    """A player's name as Total RP 3 and Reliquary may both write it: "Given Family", or
    Name-Realm with the realm's spaces, dots and hyphens left out (Total RP 3 drops dots too)."""
    name = (name or "").strip()
    head, _, realm = name.partition("-")
    if realm and " " not in head:
        return (head + "-" + re.sub(r"[\s.\-]", "", realm)).casefold()
    return head.casefold()


def norm_realm(realm):
    return re.sub(r"[\s\-]", "", realm or "")


def full_name(name, realm, regional=False):
    """A player's name as the addon keys players (Share.lua fullName): on WoW: Forever, whose names
    are "Given Family" and unique in the region, the full name alone; elsewhere Name-Realm, with
    the realm without spaces."""
    name = clean(name) or ""
    if regional:
        m = re.match(r"^([^-]+ [^-]+)-", name)
        full = m.group(1) if m else name
        return full if " " in full else full.replace("-", " ", 1)
    if "-" in name:
        n, r = name.split("-", 1)
        return f"{n}-{norm_realm(r)}"
    return f"{name}-{norm_realm(realm)}"


def peer_item(rec):
    if not isinstance(rec, dict) or not isinstance(rec.get("id"), int):
        return None
    out = {"id": rec["id"], "name": clean(rec.get("n")) or f"Item {rec['id']}", "q": rec.get("q"), "icon": rec.get("ic"), "ilvl": rec.get("il")}
    return {k: v for k, v in out.items() if v is not None}


def peer(key, p):
    """Another player's reliquary as they shared it with you."""
    card = p.get("card") if isinstance(p.get("card"), dict) else None
    scopes = p.get("scopes") if isinstance(p.get("scopes"), dict) else {}
    out = {"key": key, "scopes": [SCOPES[x] for x in "gfp" if x in scopes], "seen": p.get("seen"), "got": p.get("got"), "addon": clean(p.get("ver"))}
    if card:
        for k in ("realm", "race", "raceFile", "class", "classFile", "level", "faction", "guild", "guildRank", "title", "ilvl", "sex"):
            out[k] = clean(card.get(k)) if isinstance(card.get(k), str) else card.get(k)
        out["name"] = clean(card.get("name")) or key.split("-")[0]
        out["gear"] = {slot: peer_item(rec) for slot, rec in as_slots(card.get("gear")).items() if peer_item(rec)}
        out["profs"] = [{"name": clean(x.get("n")), "icon": x.get("ic"), "skill": x.get("sk"), "max": x.get("mx")}
                        for x in as_list(card.get("profs")) if isinstance(x, dict) and x.get("n")]
        tal = card.get("tal")
        if isinstance(tal, dict):
            out["talents"] = {
                "pts": [x if isinstance(x, (int, float)) else 0 for x in as_list(tal.get("pts"))][:3],
                "spent": tal.get("spent"), "left": tal.get("left"),
                "nodes": [{"spell": n.get("sp"), "name": clean(n.get("nm")), "icon": n.get("ic"), "rank": n.get("r"), "max": n.get("m"), "tree": n.get("t")}
                          for n in as_list(tal.get("n")) if isinstance(n, dict)],
            }
        out["stats"] = card.get("stats") if isinstance(card.get("stats"), dict) else None
        out["shows"] = [part for part, k in (("gear", "gear"), ("talents", "tal"), ("profs", "profs"), ("stats", "stats")) if isinstance(card.get(k), (dict, list))]
        if "gear" not in out["shows"]:
            out.pop("gear", None)
        if "profs" not in out["shows"]:
            out.pop("profs", None)
    else:
        out["name"] = key.split("-")[0]
    more = p.get("more") if isinstance(p.get("more"), dict) else {}
    got = p.get("gotAt") if isinstance(p.get("gotAt"), dict) else {}
    live = more.get("live")
    if isinstance(live, dict):
        out["live"] = {k: v for k, v in {
            "gold": live.get("gold"), "zone": clean(live.get("zone")), "subzone": clean(live.get("sub")), "mapName": clean(live.get("map")),
            "x": live.get("x"), "y": live.get("y"), "hearth": clean(live.get("hearth")), "played": live.get("played"),
            "playedLevel": live.get("playedLevel"), "at": got.get("live"),
        }.items() if v is not None}
    if isinstance(more.get("reps"), dict):
        out["reps"] = [{k: v for k, v in {"name": clean(r.get("n")), "reaction": r.get("r"), "value": r.get("v"), "lo": r.get("lo"), "hi": r.get("hi"),
                                           "header": r.get("h"), "war": r.get("w"), "child": r.get("c")}.items() if v is not None}
                       for r in as_list(more["reps"].get("list")) if isinstance(r, dict) and r.get("n")]
    if isinstance(more.get("quests"), dict):
        out["quests"] = [{"title": clean(q.get("t")), "level": q.get("l"), "done": q.get("d") is True, "group": clean(q.get("g")),
                          "obj": [{"text": clean(o.get("t")), "done": o.get("d") is True} for o in as_list(q.get("o")) if isinstance(o, dict) and o.get("t")]}
                         for q in as_list(more["quests"].get("list")) if isinstance(q, dict) and q.get("t")]
    if isinstance(more.get("craft"), dict):
        out["recipes"] = peer_recipes(more["craft"], card)
    for name in ("bags", "bank"):
        if isinstance(more.get(name), dict):
            bags = []
            for b in as_list(more[name].get("list")):
                if not isinstance(b, dict) or not isinstance(b.get("z"), int):
                    continue
                slots = {}
                for slot, it in as_slots(b.get("s")).items():
                    rec = peer_item(it)
                    if rec:
                        rec["n"] = it.get("c") or 1
                        slots[slot] = rec
                bags.append({"bag": b.get("b"), "size": b["z"], "free": b["z"] - len(slots), "item": peer_item(b.get("it")), "slots": slots})
            out[name] = bags
            if name == "bank" and more[name].get("at"):
                out["bankAt"] = more[name]["at"]
    return {k: v for k, v in out.items() if v is not None}


GOLD_LOG = 9  # the addon keeps the gold log beside the tabs' logs (Reliquary.lua)
LOG_KINDS = {"deposit", "withdraw", "move", "repair", "withdrawForTab", "buyTab", "depositSummary"}


def as_map(v):
    """A Lua table keyed by small numbers, as luasv gives it: a list when it has no gaps."""
    if isinstance(v, list):
        return {i + 1: x for i, x in enumerate(v)}
    if isinstance(v, dict):
        out = {}
        for k, x in v.items():
            try:
                out[int(k)] = x
            except (TypeError, ValueError):
                pass
        return out
    return {}


def log_entries(log, tab_names, gold=False):
    """A tab's log (or the gold log) as the addon keeps it, newest first."""
    out = []
    if not isinstance(log, dict):
        return out
    for e in reversed(as_list(log.get("list"))):
        if not isinstance(e, dict) or e.get("k") not in LOG_KINDS or not isinstance(e.get("at"), (int, float)):
            continue
        row = {"kind": e["k"], "who": clean(e.get("w")), "at": e["at"]}
        if gold:
            row["money"] = e.get("m")
        else:
            row.update({"id": e.get("id"), "name": clean(e.get("nm")) or (f"Item {e['id']}" if e.get("id") else None), "q": e.get("q"),
                        "icon": e.get("ic"), "n": e.get("n")})
            if e["k"] == "move" and e.get("t2"):
                row["to"] = tab_names.get(e["t2"]) or f"Tab {e['t2']}"
        out.append({k: v for k, v in row.items() if v is not None})
    return out


def bank_policy(g, members, regional):
    """The guild master's bank settings, while whoever made them is still guild master in the
    roster (as the addon judges them), in words for the page."""
    pol = g.get("policy")
    if not isinstance(pol, dict) or not pol.get("by"):
        return None
    leader = next((m for m in members if m.get("rankOrder") == 1), None)
    if not leader or leader["key"] != pol["by"]:
        return None
    names = {i: clean(n) for i, n in as_map(pol.get("nm")).items() if isinstance(n, str)}
    for m in members:
        if isinstance(m.get("rankOrder"), int) and m.get("rank"):
            names.setdefault(m["rankOrder"], m["rank"])

    def words(a):
        if a == "a":
            return "Everyone in the guild"
        if a == "n":
            return "Game only"
        if isinstance(a, int):
            return f"{names.get(a) or f'Rank {a}'} and up"
        return "As in game"
    keep = pol.get("kp") if isinstance(pol.get("kp"), int) else None
    return {
        "by": leader["name"], "at": pol.get("at"), "records": pol.get("rc") is True,
        "keepers": (None if not keep else "the guild master" if keep == 1 else f"{names.get(keep) or f'Rank {keep}'} and up"),
        "tabs": {i: words(a) for i, a in as_map(pol.get("tb")).items()},
        "names": names, "limits": as_map(pol.get("lm")) if pol.get("rc") is True else {},
    }


VERDICTS = {"up", "lvl", "trade", "no"}


def fits_of(g):
    """Everyone in the guild who can equip each item the guild could hand out, best help first, as
    the addon's last weighing listed them (Upgrades.lua): their verdict, and whether their own game
    gave it."""
    out = {}
    for iid, lst in as_map(g.get("fits")).items():
        rows = []
        for x in as_list(lst):
            if not isinstance(x, dict) or x.get("v") not in VERDICTS or not x.get("who"):
                continue
            row = {"who": clean(x["who"]), "name": clean(x.get("name")) or clean(x["who"]).split("-")[0], "classFile": x.get("cls"),
                   "level": x.get("level"), "me": x.get("me") is True, "own": x.get("own") is True, "v": x["v"], "slot": x.get("sl"),
                   "ilvl": x.get("il"), "cur": x.get("ci"), "curName": clean(x.get("cn")), "at": x.get("lv"),
                   "changes": [{"stat": clean(c.get("k")), "n": c.get("n")} for c in as_list(x.get("d")) if isinstance(c, dict) and c.get("k")],
                   # A guildmate's own verdict that came with their ask for the item (Upgrades.lua).
                   "asked": True if x.get("asked") is True else None}
            rows.append({k: v for k, v in row.items() if v is not None})
        if rows:
            out[str(iid)] = rows
    return out


BOARD_KEEP = 14 * 86400  # the addon forgets a set-aside or an ask after two weeks (Upgrades.lua)


def board_of(raw, held, now, names):
    """Who each item in a bank tab is set aside for and who asked for it, from the addon's board
    for that tab (Upgrades.lua): only items the tab still holds, only words still standing (not
    taken back, none older than two weeks), oldest first, each with the name the guild list gives."""
    out = {}
    items = raw.get("items") if isinstance(raw, dict) else None
    for iid, e in as_map(items).items():
        if iid not in held or not isinstance(e, dict):
            continue
        row = {}
        for kind in ("aside", "asks"):
            words = []
            for who, x in (e[kind].items() if isinstance(e.get(kind), dict) else []):
                who = clean(who)
                at = x.get("at") if isinstance(x, dict) else None
                if not who or not isinstance(at, (int, float)) or x.get("off") or now - at > BOARD_KEEP:
                    continue
                # An ask shows when it was first made; the newest word on it (a verdict kept current) only keeps it alive.
                first = x.get("f") if kind == "asks" and isinstance(x.get("f"), (int, float)) and x["f"] <= at else at
                w = {"who": who, "name": names.get(who) or who.split("-")[0], "at": first}
                by = clean(x.get("by")) if kind == "aside" else None
                if by:
                    w["by"] = names.get(by) or by.split("-")[0]
                words.append(w)
            if words:
                row[kind] = sorted(words, key=lambda w: (w["at"], w["who"]))
        if row:
            out[str(iid)] = row
    return out


def guild(gk, g, peers, now=None, regional=False):
    """A guild one of your characters is in: its roster, which guildmates share their reliquary
    with it, and the guild bank tabs your characters may see, as last seen, with each tab's log and
    note, the gold log, what your rank may take, and the guild master's settings. `now` is the time
    the data is judged at (the sample's own time, for the sample)."""
    now = now or time.time()
    realm = g.get("realm")
    mine_raw = g.get("mine") if isinstance(g.get("mine"), dict) else {}
    mine = set(mine_raw.keys())
    members = []
    for m in as_list(g.get("members")):
        if not isinstance(m, dict) or not m.get("n"):
            continue
        key = full_name(m["n"], realm, regional)
        p = peers.get(key)
        row = {
            "key": key, "name": clean(m["n"]).split("-")[0], "rank": clean(m.get("rank")), "rankOrder": m.get("ro"),
            "level": m.get("lv"), "classFile": m.get("cls"), "zone": clean(m.get("z")), "note": clean(m.get("note")),
            "online": m.get("on") is True, "mobile": m.get("mobile") is True, "seen": m.get("seen"), "me": m.get("me") is True,
            "profs": [{"name": clean(m[n]), "skill": m.get(n + "r")} for n in ("p1", "p2") if m.get(n)],
            # Sharing anything with the guild (their professions alone, say) shows their reliquary.
            "shares": bool(p and "guild" in p.get("scopes", []) and p.get("shows") is not None),
        }
        members.append({k: v for k, v in row.items() if v is not None})
    fresh = set()
    for ck, v in (g.get("view") or {}).items() if isinstance(g.get("view"), dict) else []:
        # As in game: which tabs a character may view is known for a month after it was last at the bank.
        if ck in mine and isinstance(v, dict) and now - (v.get("at") or 0) <= VIEW_KEEP:
            tabs = v.get("tabs")
            for i, ok in (tabs.items() if isinstance(tabs, dict) else enumerate(as_list(tabs), 1)):
                if ok is True:
                    fresh.add(int(i))
    # The addon's own judgement at the last save: tabs the guild master's settings show ("p"), which
    # count while whoever made them is still guild master, and tabs the game showed ("g"), which count
    # while that visit is recent.
    policy = bank_policy(g, members, regional)
    see = as_map(g.get("see")) if g.get("see") is not None else None
    viewable = fresh if see is None else {i for i, how in see.items() if (how == "p" and policy) or i in fresh}
    bank = g.get("bank") if isinstance(g.get("bank"), dict) else {}
    logs, notes = as_map(bank.get("logs")), as_map(bank.get("notes"))
    raw_tabs = as_map(bank.get("tabs"))
    tab_names = {i: clean(t.get("name")) for i, t in raw_tabs.items() if isinstance(t, dict) and t.get("name")}
    boards = as_map(bank.get("board"))
    names = {m["key"]: m["name"] for m in members}
    tabs = []
    for i, t in sorted(raw_tabs.items()):
        if i not in viewable or not isinstance(t, dict):
            continue
        slots = {}
        for slot, it in as_slots(t.get("slots")).items():
            if isinstance(it, dict) and isinstance(it.get("id"), int):
                rec = {"id": it["id"], "name": clean(it.get("name")) or f"Item {it['id']}", "q": it.get("q"), "icon": it.get("icon"), "n": it.get("n") or 1}
                slots[slot] = {k: v for k, v in rec.items() if v is not None}
        tab = {"index": i, "name": clean(t.get("name")) or f"Tab {i}", "icon": t.get("icon"), "at": t.get("at"),
               "by": clean(t.get("by")), "slots": slots}
        note = notes.get(i)
        if isinstance(note, dict) and clean(note.get("text")):
            tab["note"] = clean(note["text"])
        log = logs.get(i)
        if isinstance(log, dict) and as_list(log.get("list")):
            tab["log"] = {"at": log.get("at"), "by": clean(log.get("by")), "entries": log_entries(log, tab_names)}
        if policy and policy["tabs"].get(i) not in (None, "As in game"):
            tab["shared"] = policy["tabs"][i]
        board = board_of(boards.get(i), {it["id"] for it in slots.values()}, now, names)
        if board:
            tab["board"] = board
        tabs.append({k: v for k, v in tab.items() if v is not None})
    out_bank = {"money": bank.get("money"), "moneyAt": bank.get("moneyAt"), "count": bank.get("count"), "tabs": tabs}
    gold = logs.get(GOLD_LOG)
    if isinstance(gold, dict) and as_list(gold.get("list")) and tabs:
        out_bank["goldLog"] = {"at": gold.get("at"), "by": clean(gold.get("by")), "entries": log_entries(gold, tab_names, gold=True)}
    # What your rank may take: the guild master's settings for your highest-ranked character here,
    # or what the bank itself told that character.
    ranks = [(v.get("ro"), ck) for ck, v in mine_raw.items() if isinstance(v, dict) and isinstance(v.get("ro"), int)]
    if ranks:
        ro, ck = min(ranks)
        lim = (policy or {}).get("limits", {}).get(ro)
        own = bank["limits"].get(ck) if isinstance(bank.get("limits"), dict) else None
        per_tab = {}
        gold_day = None
        if isinstance(lim, dict):
            per_tab = {i: w for i, w in as_map(lim.get("w")).items() if isinstance(w, (int, float))}
            gold_day = lim.get("g")
        elif isinstance(own, dict):
            per_tab = {i: t.get("w") for i, t in as_map(own.get("tabs")).items() if isinstance(t, dict) and isinstance(t.get("w"), (int, float))}
        if per_tab or isinstance(gold_day, (int, float)):
            out_bank["limits"] = {"rank": (policy or {}).get("names", {}).get(ro) or next((m.get("rank") for m in members if m.get("rankOrder") == ro), None),
                                  "tabs": per_tab, "gold": gold_day}
    if policy:
        out_bank["policy"] = {k: policy[k] for k in ("by", "at", "records", "keepers")}
    return {
        "key": gk, "name": clean(g.get("name")), "realm": realm, "faction": g.get("faction"), "motd": clean(g.get("motd")),
        "at": g.get("at"), "mine": sorted(mine), "members": members,
        "bank": out_bank, "fits": fits_of(g), "fitsAt": g.get("fitsAt"),
    }


def raw_item_ids(c):
    """Item ids on a character as the addon saves it: gear, bags and bank with their bags, and what
    its recipes make and use."""
    for rec in as_slots(c.get("gear")).values():
        if isinstance(rec, dict):
            yield rec.get("id")
    for b in as_list(c.get("bags")) + as_list(c.get("bank")):
        if isinstance(b, dict):
            if isinstance(b.get("item"), dict):
                yield b["item"].get("id")
            for rec in as_slots(b.get("slots")).values():
                if isinstance(rec, dict):
                    yield rec.get("id")
    for rec in recipe_items(own_recipes(c)):
        yield rec["id"]


def public_cut(saved):
    """What of a Reliquary.lua may leave this PC for the public copy (tools/publish.py): the
    characters that share publicly, only the parts they show publicly, the tooltips of the items
    left and the addon's version. Never the guilds, guild banks or what other players share, and
    none of your other characters."""
    db = saved.get("ReliquaryDB") if isinstance(saved.get("ReliquaryDB"), dict) else {}
    chars = {k: hide_parts(c, hidden_parts(c), RAW_PART_FIELDS) for k, c in (db.get("chars") or {}).items() if isinstance(c, dict) and is_public(c)}
    used = {i for c in chars.values() for i in raw_item_ids(c) if i is not None}
    items = {k: v for k, v in (db.get("items") or {}).items() if k in used}
    return {"ReliquaryDB": {"schema": db.get("schema"), "meta": db.get("meta"), "chars": chars, "items": items}}


def public_cut_trp3(saved, names):
    """Total RP 3's saved file cut to the profiles of these characters (by name) and nothing else:
    not the profiles it keeps of other players."""
    chars = {k: v for k, v in (saved.get("TRP3_Characters") or {}).items() if any(trp3_names(k, n) for n in names)}
    ids = {v.get("profileID") for v in chars.values() if isinstance(v, dict)}
    profiles = {k: v for k, v in (saved.get("TRP3_Profiles") or {}).items() if k in ids}
    return {"TRP3_Characters": chars, "TRP3_Profiles": profiles}


def wtf_files(wtf):
    return sorted(glob.glob(os.path.join(wtf, "*", "SavedVariables", "Reliquary.lua")))


# ---------------------------------------------------------------------------
# Auction prices and where items come from (Prices.lua, Sources.lua): your own copy only
# ---------------------------------------------------------------------------
SAMPLE_PRICES = os.path.join(DATA, "sample", "prices-history.json")
# Blizzard's API terms: nothing from their API is kept longer than thirty days. Its snapshots go
# into the history beside your own scans, so the history keeps no point older than that either.
PRICE_DAYS = 30
SOURCE_KINDS = ("v", "d", "q", "m", "r", "j")
DROP_KINDS = {"c": "creature", "o": "gathered", "f": "fishing", "i": "container"}
_prices_lock = threading.Lock()


def too_old(now=None):
    """The newest day the history no longer keeps: a point of that day may be more than thirty
    days old, so only later days stay (thirty of them, today's included)."""
    return time.strftime("%Y-%m-%d", time.localtime((now or time.time()) - PRICE_DAYS * 86400))


def price_houses(dbs):
    """Each auction house's newest scan across the saved files, and every item's newest word (a check
    made at the house is newer than the scan): {house: {realm, side, at, by, own, n, items}}. A
    price of None means the house had none listed when it was checked. Sellers are never kept."""
    out = {}
    for db in dbs:
        raw = db.get("prices")
        for key, h in (raw.items() if isinstance(raw, dict) else []):
            key = clean(key)
            if not key or "|" not in key or not isinstance(h, dict):
                continue
            realm, _, side = key.rpartition("|")
            at = h.get("at") if isinstance(h.get("at"), (int, float)) else 0
            cur = out.setdefault(key, {"realm": realm, "side": side, "at": 0, "items": {}})
            if at > cur["at"]:
                cur.update({"at": at, "by": clean(h.get("by")), "own": h.get("own") is True, "api": True if h.get("api") is True else None,
                            "n": h.get("n") if isinstance(h.get("n"), int) else None})
            for iid, e in as_map(h.get("items")).items():
                if not isinstance(e, dict):
                    continue
                p, q = e.get("p"), e.get("q")
                word = e.get("at") if isinstance(e.get("at"), (int, float)) else at
                if not word or (p is not None and not (isinstance(p, (int, float)) and p > 0)):
                    continue
                old = cur["items"].get(iid)
                if old is None or word > old["at"]:
                    cur["items"][iid] = {"p": p, "q": q if isinstance(q, (int, float)) else 0, "at": word, "live": isinstance(e.get("at"), (int, float)),
                                         "more": e.get("more") is True}
    return out


def api_scans(path, now=None):
    """Blizzard's newest snapshot of each of your houses it has been matched to, shaped like the
    addon's own scans ({"prices": {realm|side: scan}}), or None. A snapshot more than thirty days
    old is never used (tools/blizzard_prices.py deletes it within the hour)."""
    try:
        with open(path, encoding="utf-8") as f:
            s = json.load(f)
    except (OSError, ValueError):
        return None
    out = {}
    oldest = (now or time.time()) - PRICE_DAYS * 86400
    for key, hid in ((s.get("map") or {}) if isinstance(s, dict) else {}).items():
        h = (s.get("houses") or {}).get(str(hid)) or {}
        snaps = h.get("snaps") if isinstance(h.get("snaps"), list) else []
        snap = snaps[0] if snaps and isinstance(snaps[0], dict) else None
        if snap and "|" in str(key) and isinstance(snap.get("at"), int) and snap["at"] > oldest and isinstance(snap.get("items"), dict):
            items = {int(i): {"p": v[0], "q": v[1]} for i, v in snap["items"].items()
                     if str(i).isdigit() and isinstance(v, list) and len(v) == 2 and isinstance(v[0], int) and v[0] > 0}
            out[key] = {"at": snap["at"], "by": "Blizzard", "api": True, "n": snap.get("n") if isinstance(snap.get("n"), int) else None, "items": items}
    return {"prices": out} if out else None


def prices_view(houses, ids):
    """The houses, and each house's word on the items the page shows, newest first."""
    items = {}
    for key, h in houses.items():
        for iid, e in h["items"].items():
            if iid in ids:
                items.setdefault(str(iid), []).append(dict({k: v for k, v in e.items() if v is not None}, house=key))
    for lst in items.values():
        lst.sort(key=lambda e: -e["at"])
    meta = {k: {f: h[f] for f in ("realm", "side", "at", "by", "own", "api", "n") if h.get(f) is not None} for k, h in houses.items()}
    return {"houses": meta, "items": items}


def record_history(path, houses, now=None):
    """Adds the newest word on each item to the history on this PC: for each house and item a point
    a day (the day's lowest price, and how many were listed then), none older than thirty days.
    Returns the history. The hourly price run (tools/blizzard_prices.py) calls it with no houses to
    let old points go even while no page asks; a lock beside the file keeps the two apart."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with _prices_lock, open(path + ".lock", "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            with open(path, encoding="utf-8") as f:
                hist = json.load(f)
        except (OSError, ValueError):
            hist = {}
        if not isinstance(hist.get("houses"), dict):
            hist = {"houses": {}}
        changed = False
        for key, h in houses.items():
            rec = hist["houses"].setdefault(key, {"seen": 0, "items": {}})
            seen = rec.get("seen") or 0
            newest = seen
            for iid, e in h["items"].items():
                if e["at"] <= seen or e["p"] is None:
                    continue
                day = time.strftime("%Y-%m-%d", time.localtime(e["at"]))
                points = rec["items"].setdefault(str(iid), {})
                if day not in points or e["p"] < points[day][0]:
                    points[day] = [e["p"], e["q"]]
                    changed = True
                newest = max(newest, e["at"])
            if newest > seen:
                rec["seen"], changed = newest, True
        cutoff = too_old(now)
        for rec in hist["houses"].values():
            for iid in list(rec["items"]):
                points = rec["items"][iid]
                for day in [d for d in points if d <= cutoff]:
                    del points[day]
                    changed = True
                if not points:
                    del rec["items"][iid]
        if changed:
            tmp = path + ".part"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(hist, f, separators=(",", ":"))
            os.replace(tmp, path)
        return hist


def history_of(hist, iid, now=None):
    """An item's points in the history, by house: [[day, price, listed], ...] oldest first. Given
    `now`, none older than thirty days, even if the history hasn't let them go yet (the sample's,
    made on fixed days, is read without it)."""
    cutoff = too_old(now) if now else ""
    out = {}
    for key, rec in ((hist or {}).get("houses") or {}).items():
        points = (rec.get("items") or {}).get(str(iid))
        if isinstance(points, dict) and points:
            rows = [[d, v[0], v[1]] for d, v in sorted(points.items()) if d > cutoff and isinstance(v, list) and len(v) == 2]
            if rows:
                out[key] = rows
    return out


def usable_houses(chars):
    """The auction houses the characters can use: on each one's realm, its own faction's and the
    neutral one."""
    return {f"{c['realm']}|{side}" for c in chars if isinstance(c, dict) and c.get("realm")
            for side in (c.get("faction"), "Neutral") if side in ("Alliance", "Horde", "Neutral")}


def cut_prices(view, chars, now=None):
    """Of a price view ({houses, items, history}), only what the public copy may show for these
    characters: the houses they can use, the items they show, nothing older than thirty days."""
    def dict_of(v):
        return v if isinstance(v, dict) else {}
    now = now or time.time()
    oldest, cutoff = now - PRICE_DAYS * 86400, too_old(now)
    usable, ids = usable_houses(chars), {str(i) for i in shown_ids(chars)}
    houses = {k: dict(h) for k, h in dict_of(view.get("houses")).items()
              if k in usable and isinstance(h, dict) and isinstance(h.get("at"), (int, float)) and h["at"] > oldest}
    items, history = {}, {}
    for iid, words in dict_of(view.get("items")).items():
        keep = [dict(w) for w in as_list(words) if isinstance(w, dict) and w.get("house") in houses
                and isinstance(w.get("at"), (int, float)) and w["at"] > oldest]
        if str(iid) in ids and keep:
            items[str(iid)] = keep
    for iid, by_house in dict_of(view.get("history")).items():
        rows = {k: [p for p in as_list(pts) if isinstance(p, list) and len(p) == 3 and isinstance(p[0], str) and p[0] > cutoff]
                for k, pts in dict_of(by_house).items() if k in houses}
        rows = {k: v for k, v in rows.items() if v}
        if str(iid) in ids and rows:
            history[str(iid)] = rows
    return {"houses": houses, "items": items, "history": history}


def public_prices(chars, api_path=None, hist_path=None, now=None):
    """What the public copy shows of auction prices (tools/publish.py sends it): Blizzard's hourly
    prices alone, which name no player, for the houses its characters can use and the items they
    show, with their thirty days. Never a scan made in the game: a scan says which character stood
    at an auction house and when, and a guildmate's is theirs to share."""
    now = now or time.time()
    api = api_scans(api_path or BLIZZARD, now)
    houses = price_houses([api] if api else [])
    view = prices_view(houses, shown_ids(chars))
    try:
        with open(hist_path or API_PRICES, encoding="utf-8") as f:
            hist = json.load(f)
    except (OSError, ValueError):
        hist = {}
    view["history"] = {iid: history_of(hist, int(iid), now) for iid in view["items"]}
    for h in view["houses"].values():
        h.pop("own", None)
    return cut_prices(view, chars, now)


def expire_prices(path, now=None):
    """Deletes the public copy's prices once even the newest of them is more than thirty days old
    (Blizzard's terms). While the PC sends them, hourly, they never get that old; this covers a PC
    that stays off. Returns whether it deleted them."""
    try:
        with open(path, encoding="utf-8") as f:
            sent = json.load(f)
    except (OSError, ValueError):
        return False
    houses = sent.get("houses") if isinstance(sent, dict) and isinstance(sent.get("houses"), dict) else {}
    times = [h["at"] for h in houses.values() if isinstance(h, dict) and isinstance(h.get("at"), (int, float))]
    if not times or max(times) > (now or time.time()) - PRICE_DAYS * 86400:
        return False
    try:
        os.remove(path)
    except OSError:
        return False
    return True


def notes_of(dbs):
    """Every note of where items come from across the saved files, the newest of each:
    {item: {kind: {key: note}}}."""
    out = {}
    for db in dbs:
        for iid, rec in as_map(db.get("sources")).items():
            if not isinstance(rec, dict):
                continue
            cur = out.setdefault(iid, {})
            for kind in SOURCE_KINDS:
                lst = rec.get(kind)
                for key, x in (lst.items() if isinstance(lst, dict) else enumerate(as_list(lst), 1)):
                    if isinstance(x, dict):
                        old = cur.setdefault(kind, {}).get(str(key))
                        if old is None or (x.get("at") or 0) > (old.get("at") or 0):
                            cur[kind][str(key)] = x
    return out


def coord(v):
    return round(v, 1) if isinstance(v, (int, float)) and 0 <= v <= 100 else None


def notes_view(rec, name_of):
    """An item's notes for its page: who sells it (cheapest first), quests that give it, the bosses
    the game's journal names, what drops it (most often first), the recipes that make it and those
    it goes into. A note a guildmate gave says whose it was ("from")."""
    def by(x):
        return clean(x.get("g"))
    def drop(key, x):
        kind = DROP_KINDS.get(x.get("k"))
        if not kind:
            return None
        row = {"kind": kind, "id": x.get("id") if isinstance(x.get("id"), int) else None, "name": clean(x.get("n")), "zone": clean(x.get("z")),
               "sub": clean(x.get("s")), "count": x.get("c") if isinstance(x.get("c"), int) else None, "from": by(x)}
        if kind == "container" and row["id"]:
            row["container"] = name_of(row["id"])
        return row
    vendors = [{"npc": x.get("id") if isinstance(x.get("id"), int) else None, "name": clean(x.get("n")) or "A vendor", "zone": clean(x.get("z")),
                "sub": clean(x.get("s")), "x": coord(x.get("x")), "y": coord(x.get("y")),
                "price": x.get("p") if isinstance(x.get("p"), (int, float)) else None, "stack": x.get("k") if isinstance(x.get("k"), int) else None,
                "currency": x.get("c") is True, "limited": x.get("l") is True, "from": by(x)} for x in (rec.get("v") or {}).values()]
    vendors.sort(key=lambda v: (v["price"] is None, v["price"] or 0))
    quests = [{"id": int(k) if str(k).isdigit() else None, "title": clean(x.get("t")), "choice": x.get("ch") is True, "from": by(x)}
              for k, x in (rec.get("q") or {}).items() if clean(x.get("t"))]
    journal = [{"encounter": clean(x.get("e")), "instance": clean(x.get("i")), "modes": clean(x.get("df")), "from": by(x)}
               for x in (rec.get("j") or {}).values() if clean(x.get("e")) and clean(x.get("i"))]
    drops = [d for d in (drop(k, x) for k, x in (rec.get("d") or {}).items()) if d]
    drops.sort(key=lambda d: -(d["count"] or 0))
    made = [{"recipe": int(k) if str(k).isdigit() else None, "profession": clean(x.get("p")), "from": by(x),
             "uses": [{"id": u["id"], "n": u.get("n") or 1, "name": name_of(u["id"])} for u in as_list(x.get("u")) if isinstance(u, dict) and isinstance(u.get("id"), int)]}
            for k, x in (rec.get("m") or {}).items() if clean(x.get("p"))]
    goes = [{"recipe": int(k) if str(k).isdigit() else None, "profession": clean(x.get("p")), "makes": x["o"], "name": name_of(x["o"]), "from": by(x)}
            for k, x in (rec.get("r") or {}).items() if isinstance(x.get("o"), int)]
    goes.sort(key=lambda g: (g["name"] or "", g["makes"]))
    out = {"vendors": vendors, "quests": quests, "journal": journal, "drops": drops, "made": made, "uses": goes}
    return {k: [{f: v for f, v in row.items() if v is not None and v is not False} for row in rows] for k, rows in out.items() if rows}


def shown_ids(*parts):
    """The item numbers the page shows anywhere (every {"id": n} in it)."""
    found = set()
    def walk(v):
        if isinstance(v, dict):
            if isinstance(v.get("id"), int):
                found.add(v["id"])
            for x in v.values():
                walk(x)
        elif isinstance(v, list):
            for x in v:
                walk(x)
    for p in parts:
        walk(p)
    return found


def build_state(wtf, demo=False, shots_dir=None, public=False, extra=None, prices=None):
    """Everything the page draws. `extra`, when given, is filled with what an item's own page asks
    for later (/api/item): the auction houses and the notes of where items come from (on the public
    copy, only the thirty days of the prices it shows). `prices` is the public copy's prices
    (public_prices, sent by tools/publish.py)."""
    files = [SAMPLE] if demo else wtf_files(wtf)
    chars, items, item_info, meta, sources = {}, {}, {}, {}, []
    raw_chars, raw_guilds, raw_peers = {}, {}, {}
    dbs = []  # every saved file read, for prices and notes (your own copy only)
    register = {}  # other players' Total RP 3 profiles, by Total RP 3's name for them: your own copy only
    for path in files:
        try:
            db = luasv.load(path).get("ReliquaryDB") or {}
        except (OSError, luasv.ParseError) as e:
            sources.append({"path": path, "error": str(e)})
            continue
        sources.append({"path": path, "mtime": os.path.getmtime(path)})
        if not public:
            dbs.append(db)
        trp = None
        trp_path = os.path.join(os.path.dirname(path), "totalRP3.lua")
        if os.path.exists(trp_path):
            try:
                trp = luasv.load(trp_path)
            except (OSError, luasv.ParseError):
                trp = None
        draft = None if public else draft_profile()  # the prepared text is private until it is in Total RP 3
        data_path = os.path.join(os.path.dirname(path), "totalRP3_Data.lua")
        if not public and os.path.exists(data_path):
            try:
                register.update(roleplay.register_cards(luasv.load(data_path).get("TRP3_Register")))
            except (OSError, luasv.ParseError):
                pass
        for key, c in (db.get("chars") or {}).items():
            if isinstance(c, dict):
                chars[key] = character(key, c, trp, draft)
                raw_chars[key] = c
        for gk, g in (db.get("guilds") or {}).items() if isinstance(db.get("guilds"), dict) else []:
            if isinstance(g, dict):
                raw_guilds[gk] = g
        for pk, p in (db.get("peers") or {}).items() if isinstance(db.get("peers"), dict) else []:
            if isinstance(p, dict) and isinstance(pk, str):
                raw_peers[pk] = p
        for iid, rec in (db.get("items") or {}).items():
            if isinstance(rec, dict) and rec.get("tip"):
                items[str(iid)] = tip(rec["tip"])
            if isinstance(rec, dict) and isinstance(rec.get("info"), dict):
                item_info[str(iid)] = item_facts(rec["info"])
        meta = db.get("meta") or meta
    # Equipped gear keeps its details with its slot (scanGear in Reliquary.lua). An item worn since
    # before Reliquary kept item details, and not back in the bags since, has only those.
    for c in raw_chars.values():
        for rec in as_slots(c.get("gear")).values():
            if isinstance(rec, dict) and isinstance(rec.get("id"), int):
                item_info[str(rec["id"])] = {**item_facts(rec), **item_info.get(str(rec["id"]), {})}
    ordered = sorted(chars.values(), key=lambda c: -(c.get("updated") or 0))
    attach_photos(ordered, None if demo else shots_dir, public)
    if public:
        # Only characters that share publicly, with their own photos; nothing about anyone else.
        # No folder names: the account folder is the player's Battle.net account number.
        shown = []
        for c in ordered:
            raw = raw_chars.get(c["key"])
            if is_public(raw):
                hidden = hidden_parts(raw)
                c = hide_parts(c, hidden)
                c["hidden"] = hidden
                c.pop("share", None)
                shown.append(c)
        # Tooltips too: only for items on those characters, never the guild bank's or another player's.
        used = {rec.get("id") for c in shown for rec in item_records(c) if isinstance(rec, dict)}
        out = {
            "demo": demo, "public": True, "generatedAt": time.time(), "meta": meta,
            "sources": [{"mtime": s["mtime"]} if "mtime" in s else {"error": "unreadable"} for s in sources],
            "chars": shown, "items": {k: v for k, v in items.items() if int(k) in used},
            "itemInfo": {k: v for k, v in item_info.items() if int(k) in used},
        }
        # Auction prices: Blizzard's alone, cut again here to what this copy shows.
        cut = None
        if prices:
            try:
                with open(prices, encoding="utf-8") as f:
                    sent = json.load(f)
                cut = cut_prices(sent if isinstance(sent, dict) else {}, shown)
            except (OSError, ValueError):
                cut = None
        if cut is not None:
            out["prices"] = {"houses": cut["houses"], "items": cut["items"]}
            if extra is not None:
                extra["history"] = cut["history"]
        return out
    peers = {pk: peer(pk, p) for pk, p in raw_peers.items()}
    regional = isinstance(meta, dict) and meta.get("names") == "regional"  # how the game names players (Reliquary.lua)
    # The sample is judged as of when it was made, so it never ages.
    now = max([c.get("updated") or 0 for c in ordered] + [0]) if demo else None
    guilds = [guild(gk, g, peers, now, regional) for gk, g in sorted(raw_guilds.items())]
    # Who among those who share with you, and your guildmates, Total RP 3 has a profile for.
    units = {rp_norm(u): u for u in register}
    for p in peers.values():
        if units.get(rp_norm(p["key"])):
            p["rp"] = units[rp_norm(p["key"])]
    for g in guilds:
        for m in g["members"]:
            if units.get(rp_norm(m["key"])):
                m["rp"] = units[rp_norm(m["key"])]
    peer_list = sorted(peers.values(), key=lambda p: (p.get("name") or "").lower())
    api = None if demo else api_scans(BLIZZARD)
    houses = price_houses(dbs + ([api] if api else []))
    ids = shown_ids(ordered, guilds, peer_list) | {int(k) for k in items} | {int(k) for k in item_info}
    if extra is not None:
        extra["houses"], extra["notes"] = houses, notes_of(dbs)
        extra["names"] = {int(k): v["name"] for k, v in item_info.items() if v.get("name")}
        extra["names"].update({int(k): t[0]["l"] for k, t in items.items() if t and t[0].get("l") and int(k) not in extra["names"]})
    return {
        "demo": demo, "generatedAt": time.time(), "meta": meta, "sources": sources,
        "wtf": wtf, "chars": ordered, "items": items, "itemInfo": item_info, "guilds": guilds,
        "peers": peer_list,
        "roleplay": sorted(register.values(), key=lambda c: (c.get("name") or c.get("unit") or "").casefold()),
        "prices": prices_view(houses, ids),
    }


def item_records(c):
    """Every item a character shows: gear, bags and bank, the bags themselves, and what its recipes
    make and use."""
    yield from c.get("gear", {}).values()
    for b in c.get("bags", []) + c.get("bank", []):
        if b.get("item"):
            yield b["item"]
        yield from b.get("slots", {}).values()
    yield from recipe_items(c.get("recipes"))


def fingerprint(wtf, shots_dir=None, prices=None):
    parts = []
    for p in (shots_dir, CHOICES, os.path.join(CAPTURES, "captures.json"), BLIZZARD, prices):
        try:
            if p:
                parts.append(f"{p}:{os.path.getmtime(p)}")
        except OSError:
            pass
    for path in wtf_files(wtf):
        for p in (path, os.path.join(os.path.dirname(path), "totalRP3.lua"), os.path.join(os.path.dirname(path), "totalRP3_Data.lua")):
            try:
                parts.append(f"{p}:{os.path.getmtime(p)}")
            except OSError:
                pass
    return "|".join(parts)


# ---------------------------------------------------------------------------
# Icons: file ID -> name -> Blizzard's icon server, cached on disk. Each icon has its own lock, so
# a page's new icons are fetched together and none twice; and every icon a state shows is fetched
# as soon as that state is built (Server.watch), before anyone opens the page.
# ---------------------------------------------------------------------------
_icon_locks = {}
_icon_locks_lock = threading.Lock()


def _icon_lock(name):
    with _icon_locks_lock:
        lock = _icon_locks.get(name)
        if lock is None:
            lock = _icon_locks[name] = threading.Lock()
        return lock


def icon_bytes(file_id):
    name = ICONS.get(str(file_id))
    if not name or not re.fullmatch(r"[a-z0-9_\-]+", name):
        return None
    os.makedirs(ICON_CACHE, exist_ok=True)
    path = os.path.join(ICON_CACHE, name + ".jpg")
    miss = path + ".missing"
    with _icon_lock(name):
        if os.path.exists(path):
            with open(path, "rb") as f:
                return f.read()
        if os.path.exists(miss) and time.time() - os.path.getmtime(miss) < MISSING_RETRY:
            return None
        for url in ICON_SOURCES:
            try:
                req = urllib.request.Request(url.format(name), headers={"User-Agent": "Mozilla/5.0 (Reliquary dashboard)"})
                with urllib.request.urlopen(req, timeout=8) as r:
                    body = r.read()
                if body[:3] == b"\xff\xd8\xff":
                    tmp = path + ".part"
                    with open(tmp, "wb") as f:
                        f.write(body)
                    os.replace(tmp, path)
                    return body
            except OSError:
                continue
        open(miss, "w").close()
        return None


def icon_ids(state):
    """Every icon a state's page can show: each whole number under an "icon" or "ic" key, at any
    depth (items, gear, bags, professions, talents, recipes, bank tabs)."""
    out = set()

    def walk(v):
        if isinstance(v, dict):
            for k, x in v.items():
                if k in ("icon", "ic") and isinstance(x, int) and not isinstance(x, bool):
                    out.add(x)
                else:
                    walk(x)
        elif isinstance(v, list):
            for x in v:
                walk(x)

    walk(state)
    return out


def warm_icons(ids):
    """Fetches every icon of `ids` not on disk yet, ICON_FETCHES at a time; how many came."""
    todo = []
    for i in sorted(ids):
        name = ICONS.get(str(i))
        if name and re.fullmatch(r"[a-z0-9_\-]+", name) and not os.path.exists(os.path.join(ICON_CACHE, name + ".jpg")):
            todo.append(i)
    if not todo:
        return 0
    with ThreadPoolExecutor(ICON_FETCHES) as pool:
        return sum(1 for body in pool.map(icon_bytes, todo) if body)


# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------
TYPES = {
    ".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8", ".css": "text/css; charset=utf-8",
    ".webp": "image/webp", ".png": "image/png", ".jpg": "image/jpeg", ".svg": "image/svg+xml",
    ".woff2": "font/woff2", ".json": "application/json", ".webmanifest": "application/manifest+json", ".ico": "image/x-icon",
}

# A page names its scripts and styles with a version made from their contents (app.js?v=...).
# Cloudflare, in front of the public copy, has browsers keep .js and .css for 4 hours whatever
# the server says, so without it a phone keeps the old page code after an update.
ASSET_REF = re.compile(rb'(src|href)="([\w./-]+\.(?:js|css))"')
_asset_versions = {}  # path: (mtime, size, version)


def asset_version(full):
    st = os.stat(full)
    known = _asset_versions.get(full)
    if known and known[:2] == (st.st_mtime_ns, st.st_size):
        return known[2]
    with open(full, "rb") as f:
        version = hashlib.sha256(f.read()).hexdigest()[:12]
    _asset_versions[full] = (st.st_mtime_ns, st.st_size, version)
    return version


def versioned(body, folder):
    """The page with each of its own scripts and styles named by its version."""
    web = os.path.realpath(WEB) + os.sep

    def stamp(m):
        full = os.path.realpath(os.path.join(folder, m.group(2).decode()))
        if not full.startswith(web) or not os.path.isfile(full):
            return m.group(0)
        return m.group(1) + b'="' + m.group(2) + b"?v=" + asset_version(full).encode() + b'"'
    return ASSET_REF.sub(stamp, body)


class Handler(BaseHTTPRequestHandler):
    server_version = "Reliquary/1.0"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass

    def send_body(self, code, body, ctype, cache="no-cache", gz=True):
        if gz and len(body) > 1024 and "gzip" in (self.headers.get("Accept-Encoding") or ""):
            body = gzip.compress(body, 6)
            self.send_response(code)
            self.send_header("Content-Encoding", "gzip")
        else:
            self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", cache)
        self.send_header("X-Content-Type-Options", "nosniff")
        if self.server.public:
            for k, v in PUBLIC_HEADERS.items():
                self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        url = urlparse(self.path)
        path = url.path
        q = parse_qs(url.query)
        try:
            if path == "/api/state":
                state = self.server.state(demo=q.get("demo") == ["1"])
                self.send_body(200, json.dumps(state, separators=(",", ":"), ensure_ascii=False).encode(), "application/json; charset=utf-8", "no-store")
            elif path == "/api/item":
                m = re.fullmatch(r"\d{1,9}", (q.get("id") or [""])[0])
                if m:
                    body = self.server.item(int(m.group(0)), demo=q.get("demo") == ["1"])
                    self.send_body(200, json.dumps(body, separators=(",", ":"), ensure_ascii=False).encode(), "application/json; charset=utf-8", "no-store")
                else:
                    self.send_body(404, b"no such item", "text/plain; charset=utf-8", "no-store")
            elif path == "/api/events":
                self.events()
            elif path.startswith("/icon/"):
                m = re.fullmatch(r"/icon/(\d+)\.jpg", path)
                body = icon_bytes(int(m.group(1))) if m else None
                if body:
                    self.send_body(200, body, "image/jpeg", "public, max-age=2592000, immutable", gz=False)
                else:
                    self.send_body(404, b"no icon", "text/plain; charset=utf-8", "public, max-age=3600")
            elif path.startswith("/shot/"):
                name = unquote(path[len("/shot/"):])
                # The public copy serves only the photos its page lists, never a file found by guessing its name.
                allowed = not self.server.public or name in self.server.photo_files()
                variant = (q.get("v") or ["thumb"])[0]
                body = shot_bytes(self.server.shots, name, variant) if allowed else None
                if body:
                    self.send_body(200, body, "image/jpeg" if variant == "card" else "image/webp", "public, max-age=2592000, immutable", gz=False)
                else:
                    self.send_body(404, b"no such photo", "text/plain; charset=utf-8", "no-store")
            elif path == "/card.jpg":
                body = self.server.card_bytes()
                if body:
                    self.send_body(200, body, "image/jpeg", "public, max-age=2592000, immutable" if q.get("v") else "no-cache", gz=False)
                else:
                    self.send_body(404, b"no card yet", "text/plain; charset=utf-8", "no-store")
            elif path == "/healthz":
                self.send_body(200, b"ok", "text/plain; charset=utf-8", "no-store")
            else:
                self.static(path)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_POST(self):
        path = urlparse(self.path).path
        try:
            # A custom header makes a browser on another site ask first, which this server never allows.
            # The public copy is read-only: the portrait is chosen on the player's own copy.
            if self.server.public or path != "/api/portrait" or self.headers.get("X-Reliquary") != "1":
                self.send_body(404, b"not found", "text/plain; charset=utf-8")
                return
            length = int(self.headers.get("Content-Length") or 0)
            if not 0 < length <= 4096:
                self.send_body(400, b"bad request", "text/plain; charset=utf-8")
                return
            try:
                body = json.loads(self.rfile.read(length))
            except ValueError:
                self.send_body(400, b"bad json", "text/plain; charset=utf-8")
                return
            key, name = body.get("key"), body.get("file")
            if not isinstance(key, str) or not (name is None or (isinstance(name, str) and SHOT_NAME.fullmatch(name))):
                self.send_body(400, b"bad request", "text/plain; charset=utf-8")
                return
            with _shot_lock:
                data = load_choices()
                portraits = data.setdefault("portrait", {})
                if name:
                    portraits[key] = name
                else:
                    portraits.pop(key, None)
                save_choices(data)
            self.send_body(200, b'{"ok":true}', "application/json", "no-store")
        except (BrokenPipeError, ConnectionResetError):
            pass

    def static(self, path):
        if path == "/":
            path = "/index.html"
        full = os.path.realpath(os.path.join(WEB, path.lstrip("/")))
        if not full.startswith(os.path.realpath(WEB) + os.sep) or not os.path.isfile(full):
            self.send_body(404, b"not found", "text/plain; charset=utf-8")
            return
        ext = os.path.splitext(full)[1].lower()
        with open(full, "rb") as f:
            body = f.read()
        if full == os.path.join(os.path.realpath(WEB), "index.html"):
            body = self.page_meta(body)
        if ext == ".html":
            body = versioned(body, os.path.dirname(full))
        cache = "public, max-age=86400" if ext in (".webp", ".png", ".jpg", ".woff2") else "no-cache"
        self.send_body(200, body, TYPES.get(ext, "application/octet-stream"), cache, gz=ext in (".html", ".js", ".css", ".json", ".svg"))

    def page_meta(self, body):
        """The page's title and link preview (what a chat app shows for a pasted link): her name,
        what she is, and her portrait."""
        try:
            state = self.server.state()
        except Exception:  # the page still loads and says what went wrong itself
            return body
        c = (state.get("chars") or [None])[0]
        if not c:
            return body
        p = c.get("profile") or {}
        name = " ".join(x for x in (p.get("first"), p.get("last")) if x) if p.get("first") else c.get("name") or "A character"
        what = " ".join(str(x) for x in (f"level {c['level']}" if c.get("level") else None, c.get("race"), c.get("class")) if x)
        desc = f"{name}{', ' + what if what else ''}. Gear, travels and photos from WoW: Forever, kept up to date by Reliquary."
        tags = [f"<title>{html.escape(name)} · Reliquary</title>",
                f'<meta name="description" content="{html.escape(desc)}">',
                '<meta property="og:type" content="profile">',
                '<meta property="og:site_name" content="Liberty Hill Studios">',
                f'<meta property="og:title" content="{html.escape(name)} · Reliquary">',
                f'<meta property="og:description" content="{html.escape(desc)}">']
        portrait = (c.get("portrait") or {}).get("file")
        host = self.headers.get("Host") or ""
        card = self.server.card_version()
        if self.server.public and re.fullmatch(r"[a-z0-9.\-]+", host):
            if card:  # the wide card (web/card.html, rendered by tools/publish.py)
                tags += [f'<meta property="og:image" content="https://{host}/card.jpg?v={card}">',
                         '<meta property="og:image:width" content="1200">', '<meta property="og:image:height" content="630">',
                         f'<meta property="og:image:alt" content="{html.escape(name)}, from the game">',
                         '<meta name="twitter:card" content="summary_large_image">']
            elif portrait:  # until the first card: her face
                tags += [f'<meta property="og:image" content="https://{host}/shot/{quote(portrait)}?v=card">',
                         '<meta property="og:image:width" content="600">', '<meta property="og:image:height" content="600">',
                         '<meta name="twitter:card" content="summary">']
        return body.replace(b"<title>Reliquary</title>", "\n".join(tags).encode(), 1)

    def events(self):
        if not self.server.open_stream():
            self.send_body(503, b"busy", "text/plain; charset=utf-8", "no-store")
            return
        try:
            self.stream()
        finally:
            self.server.close_stream()

    def stream(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Accel-Buffering", "no")
        if self.server.public:
            for k, v in PUBLIC_HEADERS.items():
                self.send_header(k, v)
        self.end_headers()
        last = fingerprint(self.server.wtf, self.server.shots, self.server.prices)
        self.wfile.write(f"event: hello\ndata: {json.dumps({'at': time.time()})}\n\n".encode())
        self.wfile.flush()
        quiet = 0
        while True:
            time.sleep(1.5)
            now = fingerprint(self.server.wtf, self.server.shots, self.server.prices)
            if now != last:
                last = now
                # The game writes several files in a row: let it finish.
                time.sleep(0.8)
                self.wfile.write(f"event: update\ndata: {json.dumps({'at': time.time()})}\n\n".encode())
                self.wfile.flush()
                quiet = 0
            else:
                quiet += 1
                if quiet >= 14:
                    self.wfile.write(b": keepalive\n\n")
                    self.wfile.flush()
                    quiet = 0


class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True
    public = False
    prices = None  # the public copy's prices (--prices)
    streams = 0

    def __init__(self, *a, **kw):
        super().__init__(*a, **kw)
        self._lock = threading.Lock()
        self._build = threading.Lock()  # one build at a time: whoever comes during it waits and uses it
        self._extra = {}
        self._cache = {}
        self._warmed = {}

    def _key(self, demo):
        sample = tuple(os.path.getmtime(p) for p in (SAMPLE, os.path.join(os.path.dirname(SAMPLE), "totalRP3_Data.lua")) if os.path.exists(p)) if demo else ()
        return (demo, fingerprint(self.wtf, self.shots, self.prices), sample)

    def _cached(self, demo, key):
        with self._lock:
            hit = self._cache.get(demo)
            return hit[1] if hit and hit[0] == key else None

    def state(self, demo=False):
        """The state, rebuilt only when a file it is read from has changed."""
        hit = self._cached(demo, self._key(demo))
        if hit is not None:
            return hit
        with self._build:
            key = self._key(demo)
            hit = self._cached(demo, key)
            if hit is not None:
                return hit
            extra = {}
            state = build_state(self.wtf, demo=demo, shots_dir=self.shots, public=self.public, extra=extra, prices=self.prices)
            if not self.public and not demo:
                try:
                    record_history(PRICES, extra.get("houses") or {})
                except OSError:
                    pass
            with self._lock:
                self._cache[demo] = (key, state)
                self._extra[demo] = extra
            return state

    def warm_pass(self):
        """Builds each state whose files changed (the saved data and the sample) and fetches every
        icon it shows that isn't on disk yet; how many icons came."""
        got = 0
        for demo in (False, True):
            state = self.state(demo=demo)
            if self._warmed.get(demo) is not state:
                got += warm_icons(icon_ids(state))
                self._warmed[demo] = state
        return got

    def watch(self, stop=None):
        """Looks for a new save every WATCH_EVERY seconds, so the first visitor after it finds its
        state built and its icons on disk. Runs until `stop` is set (never, for the server)."""
        stop = stop or threading.Event()
        said = None
        while not stop.is_set():
            try:
                n = self.warm_pass()
                if n:
                    print(f"icons: fetched {n} ahead of the page", flush=True)
                said = None
            except Exception as e:  # a save still being written: the next look tries again
                if str(e) != said:
                    said = str(e)
                    print(f"icons: could not look yet ({e})", flush=True)
            stop.wait(WATCH_EVERY)

    def item(self, iid, demo=False):
        """One item's details for its page: each house's word on it, its thirty days of prices, and
        where it comes from. On the public copy, only the prices it shows and their thirty days."""
        state = self.state(demo=demo)
        if self.public:
            with self._lock:
                history = (self._extra.get(demo) or {}).get("history") or {}
            return {"id": iid, "prices": ((state.get("prices") or {}).get("items") or {}).get(str(iid)) or [],
                    "history": history.get(str(iid)) or {}}
        with self._lock:
            extra = self._extra.get(demo) or {}
        houses, notes, names = extra.get("houses") or {}, extra.get("notes") or {}, extra.get("names") or {}
        try:
            with open(SAMPLE_PRICES if demo else PRICES, encoding="utf-8") as f:
                hist = json.load(f)
        except (OSError, ValueError):
            hist = {}
        words = [dict({k: v for k, v in h["items"][iid].items() if v is not None}, house=key) for key, h in houses.items() if iid in h["items"]]
        words.sort(key=lambda e: -e["at"])
        return {"id": iid, "prices": words, "history": history_of(hist, iid, None if demo else time.time()), "sources": notes_view(notes.get(iid) or {}, names.get)}

    card = None  # the link preview picture, if there is one (--card)

    def card_version(self):
        try:
            return int(os.path.getmtime(self.card)) if self.card else None
        except OSError:
            return None

    def card_bytes(self):
        try:
            with open(self.card, "rb") as f:
                body = f.read()
            return body if body[:3] == b"\xff\xd8\xff" else None
        except (OSError, TypeError):
            return None

    def photo_files(self):
        return {p["file"] for c in self.state()["chars"] for p in c.get("photos", [])}

    def open_stream(self):
        with self._lock:
            if self.public and self.streams >= PUBLIC_STREAMS:
                return False
            self.streams += 1
            return True

    def close_stream(self):
        with self._lock:
            self.streams -= 1


def main():
    global CAPTURES, CHOICES
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--port", type=int, default=8741)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--wtf", default=os.path.join(os.environ.get("WOW_FOREVER", "/mnt/games/wow-forever"), "_forever_", "WTF", "Account"),
                    help="the game's WTF/Account folder (default: $WOW_FOREVER/_forever_/WTF/Account, WOW_FOREVER=/mnt/games/wow-forever)")
    ap.add_argument("--shots", help="the game's Screenshots folder (default: next to WTF)")
    ap.add_argument("--captures", help=f"character-screen captures (default: {CAPTURES})")
    ap.add_argument("--choices", help=f"the chosen portraits (default: {CHOICES})")
    ap.add_argument("--card", help="the link preview picture (JPEG, 1200x630) made by tools/publish.py")
    ap.add_argument("--prices", help="the public copy's auction prices (public_prices), sent by tools/publish.py")
    ap.add_argument("--public", action="store_true",
                    help="the public copy: read-only, no folder names, only photos taken with the interface hidden")
    args = ap.parse_args()
    CAPTURES = os.path.abspath(args.captures) if args.captures else CAPTURES
    CHOICES = os.path.abspath(args.choices) if args.choices else CHOICES
    srv = Server((args.host, args.port), Handler)
    srv.public = args.public
    srv.card = args.card
    srv.prices = args.prices if args.public else None
    if srv.prices:
        def expire():
            while True:
                try:
                    expire_prices(srv.prices)
                except Exception as e:  # never let a bad file stop the check
                    print(f"prices: {e}", flush=True)
                time.sleep(3600)
        threading.Thread(target=expire, daemon=True).start()
    srv.wtf = args.wtf
    srv.shots = args.shots or os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(args.wtf))), "Screenshots")
    print(f"Reliquary{' (public copy)' if srv.public else ''} on http://{args.host}:{args.port}/ reading {args.wtf} and {srv.shots}", flush=True)
    threading.Thread(target=srv.watch, name="watch", daemon=True).start()
    srv.serve_forever()


if __name__ == "__main__":
    main()
