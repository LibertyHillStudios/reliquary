"""Blizzard's web API prices (tools/blizzard_prices.py), offline: the key's form, each house's
side, the cheapest price for one of each item from auctions and commodities alike, a house with
nothing listed, which of Blizzard's houses is yours, and the one line the secure form shows.
Responses are shaped as Forever's API answers (dynamic-forever-us, rulesets and their houses).

    python3 tests/test_blizzard.py
"""
import io
import json
import os
import shutil
import sys
import tempfile
import time
from contextlib import redirect_stdout

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
# Never the real files: the tool and the server's history it prunes keep theirs in here.
os.environ["XDG_STATE_HOME"] = STATE_HOME = tempfile.mkdtemp()
import blizzard_prices as bp  # noqa: E402
bp.WTF = os.path.join(STATE_HOME, "WTF")  # never the game's own folder
bp.game_running = lambda: False

ID, SECRET = "a" * 32, "B" * 32

# The key: the client ID, a space, the client secret.
assert bp.read_key(f"  {ID} {SECRET}\n") == [ID, SECRET]
for bad in ("", ID, f"{ID} {SECRET} extra", f"{ID} short", f"{ID} {'é' * 20}"):
    try:
        bp.read_key(bad)
    except bp.Failed:
        continue
    raise AssertionError(f"a key of the wrong form was taken: {bad!r}")

# Each house's side, from its name.
assert [bp.side_of(n) for n in ("Alliance Auction House", "Horde Auction House", "Blackwater Auction House", "Auction House", None)] == \
    ["Alliance", "Horde", "Neutral", None, None]

# The cheapest for one of each item, and how many are listed; bids alone and broken entries don't count.
auctions = [{"id": 1, "item": {"id": 858}, "buyout": 9250, "quantity": 5}, {"id": 2, "item": {"id": 858}, "buyout": 19000, "quantity": 10},
            {"id": 3, "item": {"id": 6505}, "bid": 100, "quantity": 1}, {"id": 4, "item": {"id": 2075}, "buyout": 45000, "quantity": 1},
            {"id": 5, "item": {}, "buyout": 1, "quantity": 1}, "junk"]
assert bp.cheapest(auctions, "buyout") == {858: [1850, 15], 2075: [45000, 1]}
assert bp.cheapest([{"item": {"id": 2589}, "unit_price": 120, "quantity": 20}, {"item": {"id": 2589}, "unit_price": 110, "quantity": 5}], "unit_price") == {2589: [110, 25]}

# A house: its auctions and its commodities together. A house with nothing listed has no auctions field.
answers = {
    # As Forever's index answers: ids and links, no names.
    "/data/wow/ruleset/index": {"rulesets": [{"key": {"href": "https://us.api.blizzard.com/data/wow/ruleset/15"}, "id": 15},
                                             {"key": {"href": "https://us.api.blizzard.com/data/wow/ruleset/1"}, "id": 1}]},
    "/data/wow/ruleset/15/auctions/": {"auctions": [{"id": 113, "name": "Alliance Auction House"}, {"id": 112, "name": "Alliance Auction House"},
                                                    {"id": 116, "name": "Horde Auction House"}, {"id": 119, "name": "Blackwater Auction House"}]},
    "/data/wow/ruleset/15/auctions/113": {"id": 113, "auctions": auctions},
    "/data/wow/ruleset/15/auctions/113/commodities": {"auctions": [{"item": {"id": 858}, "unit_price": 1700, "quantity": 3}]},
    "/data/wow/ruleset/15/auctions/112": {"id": 112},
    "/data/wow/ruleset/15/auctions/116": {"id": 116, "auctions": [{"item": {"id": 858}, "buyout": 2600, "quantity": 1}]},
    "/data/wow/ruleset/15/auctions/119": {"id": 119, "auctions": []},
}
asked = []


def fake_get(path, tok, timeout=120):
    assert tok == "tok"
    asked.append(path)
    return answers.get(path)


bp.get, bp.token = fake_get, lambda i, s: "tok"
items, n = bp.house_prices("tok", 15, 113)
assert items == {858: [1700, 18], 2075: [45000, 1]} and n == 5, (items, n)
assert bp.house_prices("tok", 15, 112) == ({}, 0)

# Which house is yours: the one whose snapshot, taken near your scan, has your cheapest prices.
yours = {i: 1000 + i for i in range(30)}
same = {str(i): [1000 + i, 1] for i in range(30)}
half = {str(i): [1000 + i if i % 2 else 7, 1] for i in range(30)}
state = {"houses": {"113": {"side": "Alliance", "snaps": [{"at": 5000, "items": same}]},
                    "114": {"side": "Alliance", "snaps": [{"at": 5000, "items": half}]},
                    "116": {"side": "Horde", "snaps": [{"at": 5000, "items": same}]}}}
assert bp.match(state, {"R|Alliance": (5100, yours)}) == {"R|Alliance": "113"} and state["map"] == {"R|Alliance": "113"}
# Not when two houses match about as well, too long apart, or on too few items.
for houses, scans in (({"113": same, "114": same}, {"R|Alliance": (5100, yours)}),
                      ({"113": same}, {"R|Alliance": (5000 + 2 * 3600, yours)}),
                      ({"113": {k: v for k, v in same.items() if int(k) < 10}}, {"R|Alliance": (5100, yours)})):
    s = {"houses": {hid: {"side": "Alliance", "snaps": [{"at": 5000, "items": snap}]} for hid, snap in houses.items()}}
    assert bp.match(s, scans) == {} and not s["map"], (houses.keys(), scans)

# Which houses your characters can use, and your own scans, from the saved files themselves: a
# character's realm with its own faction's house and the neutral one; a guildmate's scan isn't yours.
sys.path.insert(0, os.path.join(ROOT, "server"))
import luasv  # noqa: E402
with tempfile.TemporaryDirectory() as tmp:
    sv = os.path.join(tmp, "123#1", "SavedVariables")
    os.makedirs(sv)
    with open(os.path.join(sv, "Reliquary.lua"), "w") as f:
        f.write(luasv.dumps({"ReliquaryDB": {
            "chars": {"Joan-R": {"realm": "R", "faction": "Alliance"}, "Grim-S": {"realm": "S", "faction": "Horde"}, "Odd": {"realm": "R"}},
            "prices": {"R|Alliance": {"at": 5000, "own": True, "items": {858: {"p": 1700, "q": 3}}},
                       "R|Neutral": {"at": 6000, "by": "Orlan", "items": {858: {"p": 1800, "q": 1}}}}}}))
    assert bp.your_houses(tmp) == {"R|Alliance", "R|Neutral", "S|Horde", "S|Neutral"}, bp.your_houses(tmp)
    assert bp.your_scans(tmp) == {"R|Alliance": (5000, {858: 1700})}, bp.your_scans(tmp)

# The test from the secure form: one line, pass or fail. It reads one neutral house, to prove the
# listings answer, and keeps nothing of any house.
with tempfile.TemporaryDirectory() as tmp:
    bp.STATE = os.path.join(tmp, "blizzard.json")
    bp.your_scans = lambda wtf=None: {}
    asked.clear()
    out = io.StringIO()
    with redirect_stdout(out):
        bp.cmd_test(f"{ID} {SECRET}")
    assert out.getvalue().strip() == ("Works: Blizzard's API reaches Forever's 4 auction houses. Each of your characters' houses is matched "
                                      "after its next visit to the auction house."), out.getvalue()
    saved = json.load(open(bp.STATE))
    assert saved["test"]["ruleset"] == 15 and saved["test"]["rulesets"] == [15, 1] and [h["side"] for h in saved["test"]["houses"]] == ["Alliance", "Alliance", "Horde", "Neutral"]
    assert [a for a in asked if "/auctions/1" in a] == ["/data/wow/ruleset/15/auctions/119", "/data/wow/ruleset/15/auctions/119/commodities"], asked
    assert saved["test"]["probe"]["id"] == 119 and saved["houses"]["116"]["side"] == "Horde" and not any(h.get("snaps") for h in saved["houses"].values())

    # The run every ten minutes asks Blizzard at most about hourly, and only for houses that might be
    # yours. With no character of yours known: none at all.
    T = int(time.time())

    def fetch(at):
        asked.clear()
        assert bp.cmd_fetch(now=at) == 0
        return json.load(open(bp.STATE)), sorted(a for a in asked if "/auctions/1" in a and not a.endswith("commodities"))
    bp.KEY = os.path.join(tmp, "key")
    with open(bp.KEY, "w") as f:
        f.write(f"{ID} {SECRET}")
    account = os.path.join(bp.WTF, "123#1", "SavedVariables")
    os.makedirs(account)
    with open(os.path.join(account, "Reliquary.lua"), "w") as f:
        f.write("\nReliquaryDB = {}\n")
    fed = os.path.join(account, bp.FEED)
    ours = {i: 2000 + i for i in range(30)}
    answers["/data/wow/ruleset/15/auctions/113"] = {"auctions": [{"item": {"id": i}, "buyout": p, "quantity": 1} for i, p in ours.items()]}
    answers["/data/wow/ruleset/15/auctions/112"] = {"auctions": [{"item": {"id": i}, "buyout": p + 7, "quantity": 1} for i, p in ours.items()]}
    bp.your_houses = lambda wtf=None: set()
    saved, read = fetch(T)
    assert read == [] and not any(h.get("snaps") for h in saved["houses"].values()), read
    # Joan, Alliance on realm R: before she has scanned anything, every Alliance and neutral house is
    # read each hour (never the Horde's), and the hours are kept to match her scan when it comes.
    A, N = "/data/wow/ruleset/15/auctions/", "/data/wow/ruleset/15/auctions/"
    bp.your_houses = lambda wtf=None: {"R|Alliance", "R|Neutral"}
    assert fetch(T + 600)[1] == [], "Blizzard was asked again within the hour"
    saved, read = fetch(T + 3600)
    assert read == [A + "112", A + "113", N + "119"], read
    saved, read = fetch(T + 7200)
    assert read == [A + "112", A + "113", N + "119"] and len(saved["houses"]["113"]["snaps"]) == 2, read
    # Her scan, made five minutes after one read and saved two hours later: ten minutes after the
    # last read, with nothing asked of Blizzard, it matches the read kept from its own time. Then her
    # house keeps its newest read, the other Alliance house nothing, and the neutral houses their
    # hours (hers there isn't found yet).
    bp.your_scans = lambda wtf=None: {"R|Alliance": (T + 3600 + 300, ours)}
    saved, read = fetch(T + 7200 + 600)
    assert read == [] and asked == [] and saved["map"] == {"R|Alliance": "113"}, (read, asked, saved.get("map"))
    assert [x["at"] for x in saved["houses"]["113"]["snaps"]] == [T + 7200] and not saved["houses"]["112"].get("snaps"), saved["houses"]
    assert len(saved["houses"]["119"]["snaps"]) == 2 and not saved["houses"]["116"].get("snaps")
    # The game gets her house's newest read, beside her saved data, for the addon to take at login
    # and pass to her guild; it reads as Lua.
    sys.path.insert(0, os.path.join(ROOT, "server"))
    import luasv
    sent = luasv.load(fed)["ReliquaryBlizzard"]
    assert list(sent) == ["R|Alliance"] and sent["R|Alliance"]["at"] == T + 7200 and sent["R|Alliance"]["items"][7] == {"p": 2007, "q": 1}, sent
    import subprocess
    lua = subprocess.run(["lua5.1", "-e", f"dofile({json.dumps(fed)}) assert(ReliquaryBlizzard['R|Alliance'].items[7].p == 2007) print('ok')"],
                         capture_output=True, text=True)
    assert lua.stdout.strip() == "ok", lua.stdout + lua.stderr
    # Nothing is written while the game runs, nor when nothing changed; with nothing to hand over
    # the file goes.
    stamp = os.path.getmtime(fed)
    assert bp.feed_game(saved, now=T + 7200 + 600) == 0 and os.path.getmtime(fed) == stamp
    bp.game_running = lambda: True
    assert bp.feed_game({}, now=T + 7200 + 600) == 0 and os.path.exists(fed), "the game's folder was written while it ran"
    bp.game_running = lambda: False
    assert bp.feed_game({}, now=T + 7200 + 600) == 1 and not os.path.exists(fed), "an old feed stayed with nothing to hand over"
    assert bp.feed_game(saved, now=T + 7200 + 31 * 86400) == 0 and not os.path.exists(fed), "a month-old read was handed to the game"
    assert bp.feed_game(saved, now=T + 7200 + 600) == 1 and os.path.exists(fed)
    # Blizzard's prices alone go into their own thirty days (the public copy's), under her house.
    import reliquary
    api_hist = json.load(open(reliquary.API_PRICES))
    day = time.strftime("%Y-%m-%d", time.localtime(T + 7200))
    assert list(api_hist["houses"]) == ["R|Alliance"] and api_hist["houses"]["R|Alliance"]["items"]["7"] == {day: [2007, 1]}, api_hist
    # From then on only her house and the neutral ones are read, and of a house still being found,
    # twelve hours at most are kept.
    saved, read = fetch(T + 3 * 3600)
    assert read == [A + "113", N + "119"], read
    for k in range(4, 18):
        saved, read = fetch(T + k * 3600)
    assert len(saved["houses"]["119"]["snaps"]) == bp.KEEP and len(saved["houses"]["113"]["snaps"]) == 1, saved["houses"]["119"]
    assert "Seller" not in json.dumps(saved)
    # Blizzard's terms: nothing from the API is kept longer than thirty days, and it is refreshed at
    # least that often. Every read lists the houses again.
    assert all(h["listed"] == T + 17 * 3600 for h in saved["houses"].values()), saved["houses"]
    now = int(time.time())

    # What came from the API more than thirty days ago goes: an old snapshot, a house not listed
    # since (and which of yours it was), the key test's record. A house kept from before houses
    # kept the time counts from the test.
    old = now - bp.TTL - 60
    state = {"test": {"at": old, "ruleset": 15}, "map": {"R|Alliance": "113", "S|Alliance": "114"},
             "houses": {"113": {"side": "Alliance", "listed": now, "snaps": [{"at": now - 600, "items": {}}, {"at": old, "items": {}}]},
                        "114": {"side": "Alliance", "listed": old, "snaps": [{"at": now - 600, "items": {}}]},
                        "116": {"side": "Horde"}}}
    assert bp.sweep(state, now)
    assert sorted(state["houses"]) == ["113"] and [x["at"] for x in state["houses"]["113"]["snaps"]] == [now - 600], state
    assert state["map"] == {"R|Alliance": "113"} and "test" not in state, state
    assert not bp.sweep(state, now), "a second sweep found more to delete"
    recent = {"test": {"at": now - 3600}, "houses": {"119": {"side": "Neutral"}}}
    assert not bp.sweep(recent, now) and "119" in recent["houses"] and "test" in recent, recent

    # Without a key the hourly run still lets old data go, here and in both price histories (the
    # dashboard's, which the server keeps, and Blizzard's own), and asks Blizzard nothing.
    day = lambda t: time.strftime("%Y-%m-%d", time.localtime(t))  # noqa: E731
    with open(bp.STATE, "w") as f:
        json.dump({"houses": {"113": {"side": "Alliance", "listed": old, "snaps": [{"at": old, "items": {"858": [1700, 3]}}]}},
                   "map": {"R|Alliance": "113"}}, f)
    os.makedirs(os.path.dirname(reliquary.PRICES), exist_ok=True)
    for path in (reliquary.PRICES, reliquary.API_PRICES):
        with open(path, "w") as f:
            json.dump({"houses": {"R|Alliance": {"seen": now, "items": {"858": {day(old): [1700, 3], day(now): [1800, 2]}}}}}, f)
    os.remove(bp.KEY)
    asked.clear()
    assert bp.cmd_fetch() == 0 and asked == [], asked
    assert json.load(open(bp.STATE)) == {"houses": {}, "map": {}}, json.load(open(bp.STATE))
    for path in (reliquary.PRICES, reliquary.API_PRICES):
        assert list(json.load(open(path))["houses"]["R|Alliance"]["items"]["858"]) == [day(now)], f"{path} kept a point older than thirty days"

    # With the key, a house missing from one listing stays until its thirty days are up.
    with open(bp.KEY, "w") as f:
        f.write(f"{ID} {SECRET}")
    with open(bp.STATE, "w") as f:
        json.dump({"houses": {"999": {"side": "Alliance", "listed": now - 86400}, "113": {"side": "Alliance", "listed": now - 86400}}}, f)
    bp.your_scans = lambda wtf=None: {}
    saved, read = fetch(now)
    assert saved["houses"]["113"]["listed"] >= now and saved["houses"]["999"]["listed"] == now - 86400, saved["houses"]

    def refused(i, s):
        raise bp.Failed("Battle.net refused the client ID and secret (401)")
    bp.token = refused
    sys.argv = ["blizzard_prices.py", "test"]
    sys.stdin = io.StringIO(f"{ID} {SECRET}")
    out = io.StringIO()
    with redirect_stdout(out):
        assert bp.main() == 1
    assert out.getvalue().strip() == "Didn't work: Battle.net refused the client ID and secret (401)", out.getvalue()

    # No rulesets: the key works but Forever's data isn't there.
    bp.token = lambda i, s: "tok"
    answers["/data/wow/ruleset/index"] = {"rulesets": []}
    sys.stdin = io.StringIO(f"{ID} {SECRET}")
    out = io.StringIO()
    with redirect_stdout(out):
        assert bp.main() == 1
    assert "no rulesets" in out.getvalue(), out.getvalue()

shutil.rmtree(STATE_HOME)
print("blizzard ok: the key's form, sides, cheapest prices, empty houses, matching your house, the form's one line, only your houses read and kept, "
      "nothing from the API kept past thirty days")
