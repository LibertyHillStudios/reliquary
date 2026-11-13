"""The timeline the addon keeps (addon/Reliquary/Timeline.lua), as plain data for the page.

Each entry is a stretch of play named after its zone: when it began and ended, its active time,
the level at its start and end, the quests handed in, the character's killing blows and the zones
passed through on the way. Days are entries older than 30 days, which the addon folds into one
line per zone per day. Photos are laid on the entry whose time holds them.

Before the first entry comes "Before Reliquary" (addon/Reliquary/History.lua): what the game
still knew about the character when Reliquary first ran, read once. Only its Legacy challenges
carry dates; photos taken before the first entry go there too.

Nothing here writes about the character. It passes on the game's own names and numbers, and
drops anything that is not one, so a damaged or edited saved file cannot put text on the page.
"""

import re

DATE = re.compile(r"\d{4}-\d{2}-\d{2}")
LATE = 45   # seconds a photo may come after an entry's last look (the addon looks every 30)
FIRST_SLACK = 120  # the addon notes a new place a moment after the zone changes


def _num(v):
    if isinstance(v, bool) or not isinstance(v, (int, float)) or v != v or abs(v) > 1e12:
        return None
    return v


def _count(v):
    v = _num(v)
    return int(v) if v is not None and v > 0 else None


def _text(v, limit=120):
    return v.strip()[:limit] if isinstance(v, str) and v.strip() else None


def _list(v):
    """A Lua array as the saved-file reader gives it: a list, or a dict keyed 1..n."""
    if isinstance(v, list):
        return v
    if isinstance(v, dict):
        return [v[k] for k in sorted(v, key=lambda k: (not isinstance(k, int), str(k) if not isinstance(k, int) else k))]
    return []


def _span(e):
    """zone, from, to of a saved entry or day, or None when any is missing or out of order."""
    zone, start, end = _text(e.get("zone")), _num(e.get("from")), _num(e.get("to"))
    if not zone or start is None or end is None or end < start:
        return None
    return zone, start, end


def _levels(e, out):
    for key in ("level", "levelTo"):
        v = _count(e.get(key))
        if v:
            out[key] = v
    if out.get("levelTo") and out.get("level") and out["levelTo"] < out["level"]:
        del out["levelTo"]


def entry(e):
    if not isinstance(e, dict) or not (span := _span(e)):
        return None
    zone, start, end = span
    # Active time never exceeds the entry's own span (give or take one look).
    out = {"zone": zone, "from": start, "to": end, "active": max(int(min(_num(e.get("active")) or 0, end - start + 60)), 0)}
    _levels(e, out)
    if kills := _count(e.get("kills")):
        out["kills"] = kills
    quests = []
    for q in _list(e.get("quests")):
        if not isinstance(q, dict):
            continue
        item = {}
        if title := _text(q.get("title")):
            item["title"] = title
        if xp := _count(q.get("xp")):
            item["xp"] = xp
        if qid := _count(q.get("id")):
            item["id"] = qid
        quests.append(item)
    if quests:
        out["quests"] = quests
    challenges = [{"name": t} for c in _list(e.get("challenges")) if isinstance(c, dict) and (t := _text(c.get("name")))]
    if challenges:
        out["challenges"] = challenges
    passed = []
    for z in _list(e.get("passed")):
        z = _text(z)
        if z and z != zone and z not in passed:
            passed.append(z)
    if passed:
        out["passed"] = passed
    return out


def day(d):
    if not isinstance(d, dict) or not (span := _span(d)):
        return None
    zone, start, end = span
    out = {"zone": zone, "from": start, "to": end, "active": max(int(_num(d.get("active")) or 0), 0)}
    _levels(d, out)
    for key in ("kills", "quests", "challenges", "xp"):
        if v := _count(d.get(key)):
            out[key] = v
    return out


def _texts(v, limit=120):
    out = []
    for x in _list(v):
        x = _text(x, limit)
        if x and x not in out:
            out.append(x)
    return out


def before(b):
    """What the game remembered when Reliquary first ran, as plain data; None until it was read."""
    if not isinstance(b, dict) or b.get("done") is not True or _num(b.get("at")) is None:
        return None
    out = {"at": b["at"]}
    for key in ("level", "played"):
        if v := _count(b.get(key)):
            out[key] = v
    challenges = []
    for c in _list(b.get("challenges")):
        if isinstance(c, dict) and (name := _text(c.get("name"))):
            item = {"name": name}
            if isinstance(c.get("date"), str) and DATE.fullmatch(c["date"]):
                item["date"] = c["date"]
            for key, limit in (("group", 80), ("description", 300)):
                if t := _text(c.get(key), limit):
                    item[key] = t
            if points := _count(c.get("points")):
                item["points"] = points
            challenges.append(item)
    if challenges:
        out["challenges"] = sorted(challenges, key=lambda c: c.get("date") or "")
    q = b.get("quests")
    if isinstance(q, dict) and (count := _count(q.get("count"))):
        titles = q.get("titles")
        # The reader gives a Lua table keyed 1..n as a list: titles stay keyed by quest id.
        titles = titles if isinstance(titles, dict) else {i + 1: t for i, t in enumerate(titles)} if isinstance(titles, list) else {}
        named = []
        for qid in _list(q.get("ids")):
            t = _text(titles.get(qid) if qid in titles else titles.get(str(qid)))
            if t:
                named.append(t)
        out["quests"] = {"count": count, "titles": named}
    explored = []
    for z in _list(b.get("explored")):
        if isinstance(z, dict) and (zone := _text(z.get("zone"))):
            explored.append({"zone": zone, "areas": sorted(_texts(z.get("areas")))})
    if explored:
        out["explored"] = sorted(explored, key=lambda z: z["zone"])
    # Flight paths are left out: Forever's world map marks every one found (History.lua).
    stats = []
    for st in _list(b.get("stats")):
        if isinstance(st, dict) and (name := _text(st.get("name"))) and (value := _count(st.get("value"))):
            item = {"name": name, "value": value, "group": _text(st.get("group"), 80) or "Statistics"}
            if sub := _text(st.get("sub"), 80):
                item["sub"] = sub
            stats.append(item)
    if stats:
        out["stats"] = stats
    pvp = b.get("pvp") if isinstance(b.get("pvp"), dict) else {}
    if kills := _count(pvp.get("kills")):
        out["honorKills"] = kills
    if titles := _texts(b.get("titles"), 80):
        out["titles"] = titles
    missing = b.get("missing") if isinstance(b.get("missing"), dict) else {}
    if gaps := sorted(k for k, v in missing.items() if isinstance(k, str) and k.isidentifier() and _text(v)):
        out["missing"] = gaps
    return out


def build(raw, places=None, history=None):
    """The page's timeline from a character's saved timeline: entries and days, newest first, and
    what came before them. None when there is nothing to show yet."""
    raw = raw if isinstance(raw, dict) else {}
    entries = [x for x in map(entry, _list(raw.get("entries"))) if x]
    days = [x for x in map(day, _list(raw.get("days"))) if x]
    past = before(history)
    if not entries and not days and not past:
        return None
    # The first time the character stood in an entry's zone, by the addon's record of places.
    for e in entries:
        first = _num((places or {}).get(e["zone"])) if isinstance(places, dict) else None
        if first is not None and e["from"] - FIRST_SLACK <= first <= e["to"] + LATE:
            e["first"] = True
    entries.sort(key=lambda x: -x["from"])
    days.sort(key=lambda x: -x["from"])
    out = {"entries": entries, "days": days}
    if past:
        out["before"] = past
    if hidden := _count(raw.get("hiddenKills")):
        out["hiddenKills"] = hidden
    return out


def lay_photos(tl, photos):
    """Puts each photo on the entry whose time holds it, and on a folded day the photos from its
    zone within its hours; photos from before the first entry go on "Before Reliquary".
    Character-screen captures (taken away from the world) and photos only guessed to be this
    character's stay in the album alone. photos: newest first."""
    if not tl:
        return
    past = tl.get("before")
    first = min((x["from"] for x in tl["entries"] + tl["days"]), default=None)
    for x in tl["entries"] + tl["days"] + ([past] if past else []):
        x["photos"] = []
    for p in photos:
        t = _num(p.get("t"))
        if t is None or p.get("kind") == "select" or p.get("guess"):
            continue
        # The entry whose time holds it; else one it came just after (entries run back to back,
        # so a photo inside one never goes to its neighbour).
        home = next((e for e in tl["entries"] if e["from"] <= t <= e["to"]), None) \
            or next((e for e in tl["entries"] if e["to"] < t <= e["to"] + LATE), None)
        if home is None:
            home = next((d for d in tl["days"] if d["zone"] == p.get("zone") and d["from"] <= t <= d["to"] + LATE), None)
        if home is None and past and (first is None or t < first) and t <= past["at"] + LATE:
            home = past
        if home is not None:
            home["photos"].append(p["file"])
    for x in tl["entries"] + tl["days"] + ([past] if past else []):
        if not x["photos"]:
            del x["photos"]
