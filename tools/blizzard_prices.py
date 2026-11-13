#!/usr/bin/env python3
"""Auction prices from Blizzard's web API for WoW: Forever, a second source beside the addon's
own scans at the auction house.

Forever's web API lists auction houses by ruleset (namespace dynamic-forever-<region>), not by
realm: every region has fifteen houses, five each of Alliance, Horde and neutral (Blackwater),
and none says which realm it serves. Every ruleset (PvP, Roleplay PvP, Roleplay, Normal) lists the
same fifteen, with the same listings (checked 2026-11-09), so any ruleset reaches them. So which house is yours is found by comparing each house's
prices with a scan Reliquary made in the game: the house whose cheapest prices match yours is
yours. Until then nothing from the API is shown.

    blizzard_prices.py test    reads "CLIENT_ID CLIENT_SECRET" on stdin (secret-drop pipes it):
                               signs in, lists the rulesets and houses, reads one neutral house
                               to prove the listings answer, and prints one line, pass or fail
    blizzard_prices.py fetch   the hourly run: lists the houses again, reads only yours, those
                               matched to the realm and faction of a character of yours (while one
                               isn't matched yet, every house of its faction, to find which is
                               yours), matches them to your scans, and keeps nothing of any other
                               house

The key file (~/.config/agent-secrets/blizzard-api-client, written by secret-drop) holds the
client ID and secret. What this writes (~/.local/state/reliquary/blizzard.json) holds prices
only: Blizzard's data names no sellers.

The game gets Blizzard's newest prices for your houses too: ReliquaryBlizzard.lua beside each
account's Reliquary.lua (the addon's second saved variable), written only while the game is closed.
Reliquary takes it at login and passes it to your guild, so a guildmate on your realm and faction
has those prices without visiting the auction house.

Blizzard's API terms say data from the API is kept no longer than thirty days and refreshed at
least that often. Every run, with a key or without one, first deletes what came from the API more
than thirty days ago: here, and in the price histories (prices.json, which the server keeps, and
blizzard-history.json, Blizzard's prices alone, which the public copy's thirty days come from); the
houses are listed again every run, so what stays is never older than an hour.
"""
import base64
import glob
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "server"))

KEY = os.path.expanduser("~/.config/agent-secrets/blizzard-api-client")
STATE = os.path.join(os.environ.get("XDG_STATE_HOME", os.path.expanduser("~/.local/state")), "reliquary", "blizzard.json")
WTF = os.path.join(os.environ.get("WOW_FOREVER", "/mnt/games/wow-forever"), "_forever_", "WTF", "Account")
REGION = "us"
NAMESPACE = f"dynamic-forever-{REGION}"
TOKEN_URL = "https://oauth.battle.net/token"
API = f"https://{REGION}.api.blizzard.com"
SIDES = {"alliance": "Alliance", "horde": "Horde", "blackwater": "Neutral", "neutral": "Neutral"}
MATCH_WINDOW = 90 * 60  # a house's snapshot and your scan are compared when this close in time
MATCH_SHARE = 0.5       # at least this share of the items both list must have the same cheapest price
MATCH_LEAD = 0.2        # and the best house must lead the next by this much
KEEP = 12               # hourly snapshots kept of each house that might be yours: a scan saved this many hours later still matches
READ_EVERY = 55 * 60    # Blizzard refreshes its auction data about hourly: the houses are read that often
TTL = 30 * 86400        # Blizzard's API terms: nothing from the API is kept longer than this


class Failed(Exception):
    pass


def read_key(text):
    parts = text.split()
    if len(parts) != 2 or not all(p.isascii() and 16 <= len(p) <= 128 for p in parts):
        raise Failed("the form takes the client ID, a space, then the client secret")
    return parts


def token(client_id, secret):
    auth = base64.b64encode(f"{client_id}:{secret}".encode()).decode()
    req = urllib.request.Request(TOKEN_URL, data=urllib.parse.urlencode({"grant_type": "client_credentials"}).encode(),
                                 headers={"Authorization": f"Basic {auth}", "User-Agent": "reliquary"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.load(r)["access_token"]
    except urllib.error.HTTPError as e:
        raise Failed(f"Battle.net refused the client ID and secret ({e.code})") from None
    except (urllib.error.URLError, KeyError, ValueError) as e:
        raise Failed(f"Battle.net's sign-in didn't answer ({e})") from None


def get(path, tok, timeout=120):
    sep = "&" if "?" in path else "?"
    req = urllib.request.Request(f"{API}{path}{sep}namespace={NAMESPACE}&locale=en_US",
                                 headers={"Authorization": f"Bearer {tok}", "User-Agent": "reliquary"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None
        raise Failed(f"{path} answered {e.code}") from None
    except (urllib.error.URLError, ValueError) as e:
        raise Failed(f"{path} didn't answer ({e})") from None


def rulesets(tok):
    """The ids of the region's rulesets (the index names none; each ruleset's own page does)."""
    data = get("/data/wow/ruleset/index", tok) or {}
    return [r["id"] for r in data.get("rulesets") or [] if isinstance(r, dict) and isinstance(r.get("id"), int)]


def name_of(v):
    if isinstance(v, dict):
        v = v.get("en_US") or next(iter(v.values()), None)
    return v if isinstance(v, str) else None


def side_of(name):
    low = (name or "").lower()
    return next((side for word, side in SIDES.items() if word in low), None)


def houses(tok, rid):
    """[(id, name, side)] of a ruleset's auction houses (the index needs its trailing slash)."""
    data = get(f"/data/wow/ruleset/{rid}/auctions/", tok) or {}
    out = []
    for h in data.get("auctions") or []:
        if isinstance(h, dict) and isinstance(h.get("id"), int):
            out.append((h["id"], name_of(h.get("name")), side_of(name_of(h.get("name")))))
    return out


def cheapest(auctions, unit_key):
    """{item: [cheapest for one, how many listed]} from a list of auctions; bids alone don't count."""
    out = {}
    for a in auctions or []:
        if not isinstance(a, dict):
            continue
        item = a.get("item") if isinstance(a.get("item"), dict) else {}
        iid, qty = item.get("id"), a.get("quantity") or 1
        if not isinstance(iid, int) or not isinstance(qty, int) or qty <= 0:
            continue
        if unit_key == "unit_price":
            unit = a.get("unit_price")
        else:
            unit = a["buyout"] // qty if isinstance(a.get("buyout"), int) and a["buyout"] > 0 else None
        if not isinstance(unit, int) or unit <= 0:
            continue
        cur = out.get(iid)
        if cur is None:
            out[iid] = [unit, qty]
        else:
            cur[0], cur[1] = min(cur[0], unit), cur[1] + qty
    return out


def listings(auctions):
    """How many listings there are: each an item for sale, bids alone included."""
    return sum(1 for a in auctions or [] if isinstance(a, dict) and isinstance((a.get("item") or {}).get("id"), int))


def house_prices(tok, rid, hid):
    """One house's cheapest price for one of each item, and how many are listed: its auctions and
    its commodities together. A house with nothing listed has no auctions field at all."""
    data = get(f"/data/wow/ruleset/{rid}/auctions/{hid}", tok) or {}
    items = cheapest(data.get("auctions") if isinstance(data.get("auctions"), list) else [], "buyout")
    goods = get(f"/data/wow/ruleset/{rid}/auctions/{hid}/commodities", tok) or {}
    for iid, (p, q) in cheapest(goods.get("auctions"), "unit_price").items():
        cur = items.get(iid)
        items[iid] = [min(p, cur[0]), q + cur[1]] if cur else [p, q]
    return items, listings(data.get("auctions") if isinstance(data.get("auctions"), list) else []) + listings(goods.get("auctions"))


def load_state():
    try:
        with open(STATE, encoding="utf-8") as f:
            s = json.load(f)
        return s if isinstance(s, dict) else {}
    except (OSError, ValueError):
        return {}


def save_state(s):
    os.makedirs(os.path.dirname(STATE), exist_ok=True)
    tmp = STATE + ".part"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(s, f, separators=(",", ":"))
    os.replace(tmp, STATE)


_saves = {}  # path -> (mtime, ReliquaryDB): each saved file read once a run


def saves(wtf=None):
    """Each account's ReliquaryDB from the addon's saved files."""
    import luasv
    out = []
    for path in glob.glob(os.path.join(wtf or WTF, "*", "SavedVariables", "Reliquary.lua")):
        try:
            mtime = os.path.getmtime(path)
            if path not in _saves or _saves[path][0] != mtime:
                _saves[path] = (mtime, luasv.load(path).get("ReliquaryDB") or {})
        except (OSError, luasv.ParseError):
            continue
        out.append(_saves[path][1])
    return out


def your_scans(wtf=None):
    """Your own newest scan of each house, from the addon's saved files: {realm|side: (at, items)}."""
    out = {}
    for db in saves(wtf):
        for key, h in (db.get("prices") or {}).items() if isinstance(db.get("prices"), dict) else []:
            if isinstance(h, dict) and h.get("own") is True and isinstance(h.get("at"), int) and "|" in str(key):
                items = {int(i): e["p"] for i, e in (h.get("items") or {}).items() if isinstance(e, dict) and isinstance(e.get("p"), int)}
                if key not in out or h["at"] > out[key][0]:
                    out[key] = (h["at"], items)
    return out


def your_houses(wtf=None):
    """The houses your characters can use, realm|side: on each one's realm, its own faction's and
    the neutral one."""
    out = set()
    for db in saves(wtf):
        for c in (db.get("chars") or {}).values() if isinstance(db.get("chars"), dict) else []:
            if isinstance(c, dict) and isinstance(c.get("realm"), str) and c["realm"] and c.get("faction") in ("Alliance", "Horde"):
                out |= {f"{c['realm']}|{c['faction']}", f"{c['realm']}|Neutral"}
    return out


def score(scan, snap):
    """The share of the items both list whose cheapest price is the same, and how many they share."""
    both = [i for i in scan if str(i) in snap]
    if not both:
        return 0.0, 0
    same = sum(1 for i in both if snap[str(i)][0] == scan[i])
    return same / len(both), len(both)


def match(state, scans, now=None):
    """Matches each of your houses (realm|side) to Blizzard's house whose snapshot, taken within
    an hour and a half of your scan, has the same cheapest prices; changes state["map"]."""
    found = {}
    for key, (at, items) in scans.items():
        if key in state.get("map", {}) or not items:
            continue
        side = key.rpartition("|")[2]
        best = []
        for hid, h in (state.get("houses") or {}).items():
            if h.get("side") != side:
                continue
            snaps = [s for s in h.get("snaps") or [] if abs(s["at"] - at) <= MATCH_WINDOW]
            if snaps:
                s = min(snaps, key=lambda s: abs(s["at"] - at))
                share, n = score(items, s["items"])
                if n >= 20:
                    best.append((share, hid))
        best.sort(reverse=True)
        if best and best[0][0] >= MATCH_SHARE and (len(best) == 1 or best[0][0] - best[1][0] >= MATCH_LEAD):
            found[key] = best[0][1]
    state.setdefault("map", {}).update(found)
    return found


def sweep(state, now=None):
    """Deletes whatever came from Blizzard's API more than thirty days ago: a house's snapshots, a
    house Blizzard hasn't listed since (and which of yours it was), and the key test's record.
    Returns whether anything went."""
    oldest = int(now or time.time()) - TTL
    test = state.get("test") if isinstance(state.get("test"), dict) else {}
    tested = test.get("at") if isinstance(test.get("at"), int) else 0
    changed = False
    houses = state.get("houses") if isinstance(state.get("houses"), dict) else {}
    for hid in list(houses):
        h = houses[hid] if isinstance(houses[hid], dict) else {}
        listed = h.get("listed") if isinstance(h.get("listed"), int) else tested  # listed before houses kept the time
        if listed <= oldest:
            del houses[hid]
            changed = True
            continue
        snaps = [x for x in h.get("snaps") or [] if isinstance(x, dict) and isinstance(x.get("at"), int) and x["at"] > oldest]
        if snaps != (h.get("snaps") or []):
            h["snaps"] = snaps
            changed = True
        if not snaps and "snaps" in h:
            del h["snaps"]
    mapping = state.get("map") if isinstance(state.get("map"), dict) else {}
    for key in [k for k, hid in mapping.items() if str(hid) not in houses]:
        del mapping[key]
        changed = True
    if "test" in state and tested <= oldest:
        del state["test"]
        changed = True
    return changed


def prune_history():
    """Lets the price histories go of points older than thirty days: the dashboard's (which the
    server also prunes whenever it writes it; this covers the days no page asks) and Blizzard's own."""
    import reliquary  # the server's own code, so the two never disagree on what is too old
    for path in (reliquary.PRICES, reliquary.API_PRICES):
        reliquary.record_history(path, {})


def record_api_history():
    """Thirty days of Blizzard's prices alone, a point a day for each item at each of your houses:
    what the public copy's thirty days are drawn from (the dashboard's history mixes in your scans)."""
    import reliquary
    api = reliquary.api_scans(STATE)
    reliquary.record_history(reliquary.API_PRICES, reliquary.price_houses([api] if api else []))


FEED = "ReliquaryBlizzard.lua"  # beside Reliquary.lua: the addon's second saved variable


def game_running():
    """Whether WoW is running: nothing is written into the game's folder while it is."""
    return subprocess.run(["pgrep", "-x", "Wow.exe"], capture_output=True).returncode == 0


def feed(state, now=None):
    """Blizzard's newest read of each of your matched houses, as the addon takes it at login:
    {realm|side: {at, n, items: {item: {p, q}}}}. Nothing older than thirty days."""
    now = int(now or time.time())
    out = {}
    for key, hid in (state.get("map") or {}).items() if isinstance(state.get("map"), dict) else []:
        snaps = ((state.get("houses") or {}).get(str(hid)) or {}).get("snaps") or []
        s = snaps[0] if snaps and isinstance(snaps[0], dict) else None
        if not (s and isinstance(s.get("at"), int) and now - s["at"] <= TTL and isinstance(s.get("items"), dict)):
            continue
        items = {int(i): {"p": v[0], "q": v[1]} for i, v in s["items"].items()
                 if str(i).isdigit() and isinstance(v, list) and len(v) == 2 and isinstance(v[0], int) and v[0] > 0 and isinstance(v[1], int)}
        if items:
            out[key] = {"at": s["at"], "items": items}
            if isinstance(s.get("n"), int):
                out[key]["n"] = s["n"]
    return out


def feed_game(state, wtf=None, now=None):
    """Hands the game Blizzard's newest prices for your houses: ReliquaryBlizzard.lua beside each
    account's Reliquary.lua, which the addon takes at login and passes to your guild. Written only
    while the game is closed and when it changed; with nothing to hand over, the file goes (so no
    price older than thirty days stays there). Returns how many files it wrote or removed."""
    import luasv
    data = feed(state, now)
    text = "\n" + luasv.dumps({"ReliquaryBlizzard": data}) if data else None
    done = 0
    for saved in sorted(glob.glob(os.path.join(wtf or WTF, "*", "SavedVariables", "Reliquary.lua"))):
        path = os.path.join(os.path.dirname(saved), FEED)
        try:
            with open(path, encoding="utf-8") as f:
                old = f.read()
        except OSError:
            old = None
        if old == text or game_running():
            continue
        if text is None:
            os.remove(path)
        else:
            with open(path + ".part", "w", encoding="utf-8") as f:
                f.write(text)
            if game_running():  # it started meanwhile: leave its folder alone
                os.remove(path + ".part")
                continue
            os.replace(path + ".part", path)
        done += 1
    return done


def snapshot(state, tok, rid, hid, name, side, now=None):
    items, n = house_prices(tok, rid, hid)
    h = state.setdefault("houses", {}).setdefault(str(hid), {"name": name, "side": side})
    h.update({"name": name, "side": side, "ruleset": rid})
    h["snaps"] = ([{"at": int(now or time.time()), "n": n, "items": {str(i): v for i, v in items.items()}}] + (h.get("snaps") or []))[:KEEP]
    return n, len(items)


def cmd_test(text):
    client_id, secret = read_key(text)
    tok = token(client_id, secret)
    rs = rulesets(tok)
    if not rs:
        raise Failed("no rulesets: Forever's auction data isn't in the web API for this key")
    rid = rs[0]  # every ruleset lists the same houses
    hs = houses(tok, rid)
    if not hs:
        raise Failed(f"ruleset {rid} lists no auction houses")
    # One house read in full proves the listings answer (a neutral one: they are the smallest).
    # Nothing else is read: only your own houses are, by fetch.
    probe = next((h for h in hs if h[2] == "Neutral"), hs[0])
    items, n = house_prices(tok, rid, probe[0])
    state = load_state()
    old = state.get("houses") or {}
    now = int(time.time())
    state["houses"] = {str(hid): dict(old.get(str(hid)) or {}, name=name, side=side, ruleset=rid, listed=now) for hid, name, side in hs}
    state["test"] = {"at": now, "namespace": NAMESPACE, "rulesets": rs, "ruleset": rid,
                     "houses": [{"id": hid, "name": name, "side": side} for hid, name, side in hs],
                     "probe": {"id": probe[0], "listings": n, "items": len(items)}}
    save_state(state)
    print(f"Works: Blizzard's API reaches Forever's {len(hs)} auction houses. Each of your characters' houses is matched "
          "after its next visit to the auction house.")


def cmd_fetch(now=None):
    """The run every ten minutes. Blizzard is asked at most about hourly: it lists the houses again
    and reads yours, and, while a house of yours isn't matched yet, every house of its side, keeping
    the last twelve hours of them. Between those reads a new scan of yours, whenever the game saved
    it, is matched against the hours kept, so its prices show minutes after the save."""
    now = int(now or time.time())
    state = load_state()
    changed = sweep(state, now)
    prune_history()
    try:
        with open(KEY, encoding="utf-8") as f:
            client_id, secret = read_key(f.read())
    except OSError:
        if changed:
            save_state(state)
        feed_game(state, now=now)
        return 0  # no key: nothing more to do
    scans = your_scans()
    needed = your_houses() | set(scans)

    def yours():
        # The houses matched to a realm and side of yours, and the sides with a house of yours not
        # matched yet.
        mapping = state.get("map") or {}
        return {str(h) for h in mapping.values()}, {k.rpartition("|")[2] for k in needed if k not in mapping}

    mapped, finding = yours()
    if now - (state.get("read") or 0) >= READ_EVERY:
        tok = token(client_id, secret)
        rs = rulesets(tok)
        if rs:
            rid = rs[0]  # every ruleset lists the same houses
            # The houses, listed again: what is kept of them is never older than this read. A house
            # missing from one listing stays until thirty days have passed without it.
            reg = state.setdefault("houses", {})
            for hid, name, side in houses(tok, rid):
                reg[str(hid)] = dict(reg.get(str(hid)) or {}, name=name, side=side, ruleset=rid, listed=now)
            for hid, h in list(reg.items()):
                if hid in mapped or h.get("side") in finding:
                    snapshot(state, tok, rid, int(hid), h.get("name"), h.get("side"), now)
            state["read"] = now
            changed = True
    if match(state, scans):
        changed = True
    # Kept: while a house of yours on a side isn't matched, the hours kept of every house of that
    # side; your matched houses' newest read; nothing of any other house.
    mapped, finding = yours()
    for hid, h in (state.get("houses") or {}).items():
        snaps = h.get("snaps") or []
        keep = snaps if h.get("side") in finding else snaps[:1] if hid in mapped else []
        if keep != snaps:
            changed = True
        if keep:
            h["snaps"] = keep
        else:
            h.pop("snaps", None)
    if changed:
        save_state(state)
        record_api_history()
    feed_game(state, now=now)
    return 0


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    try:
        if cmd == "test":
            cmd_test(sys.stdin.read())
            return 0
        if cmd == "fetch":
            return cmd_fetch()
    except Failed as e:
        print(f"Didn't work: {e}")
        return 1
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main())
