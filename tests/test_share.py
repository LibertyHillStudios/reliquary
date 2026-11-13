"""Sharing on the server side: your own copy shows your guild, its bank and what others share with
you; the public copy shows only your characters that share publicly, and nothing of anyone else,
whether it is asked for the page, the state, a photo or a tooltip; and the files the publisher
sends to the public copy hold nothing more.

    python3 tests/test_share.py
"""
import fcntl
import json
import os
import shutil
import struct
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "server"))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import luasv  # noqa: E402
import reliquary  # noqa: E402
import publish  # noqa: E402

GK = "The Moonwell Circle@CAMWOW US2 Realm 10 RP PvP"
NOW = int(time.time())
SHOT = "WoWScrnShot_110926_201500.png"  # Joan's photo of Auberdine, and the addon's note of it
SHOT_T = int(time.mktime(time.strptime("110926_201500", "%m%d%y_%H%M%S")))
SECRETS = ["Moonwell at dusk", "The Moonwell Circle", "Thalia", "Brannoc", "Eluned", "Gloves of the Dawnwatch",
           "Officers", "Herbalist, ask for silverleaf", "Mira", "Mira's own hat", "Small Lustrous Pearl",
           "Saeli", "Herbs for crafters", "Faelwen", "Raid rewards only", "Orlan", "Crescent Staff", "Priest's Mace",
           "Innkeeper Shaussiy", "Blackwood Pathfinder", "The Absent Minded Prospector", "Mutanus", "125000", "4511", "4422",
           # The guild's chat and Joan's whispers (Chat.lua): kept on this PC for the game's window only.
           "Raid at eight in Ashenvale", "Your bracers are ready", "moonsong",
           # Officer chat, and a Battle.net friend's whispers under their BattleTag.
           "Bank tabs at nine, officers", "Brannoc#1504", "Bring the mats"]


def char(name, share, gear_id, gear_name, **more):
    c = {"key": f"{name}-CAMWOW US2 Realm 10 RP PvP", "name": name, "realm": "CAMWOW US2 Realm 10 RP PvP", "level": 20,
         "class": "Druid", "classFile": "DRUID", "updated": 1794000000 + len(name),
         "gear": {1: {"id": gear_id, "name": gear_name, "q": 2, "icon": 133071}}}
    if share is not None:
        c["share"] = share
    c.update(more)
    return c


def png(path, w, h):
    """A real (blank) PNG of this size: enough for the server to read its size."""
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)
    rows = b"".join(b"\0" + b"\0\0\0" * w for _ in range(h))
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


def saved():
    return {"ReliquaryDB": {
        "schema": 2,
        "meta": {"addon": "1.3.0"},
        "chars": {
            # Joan shows her gold and character sheet to the guild only, her bags to the guild and
            # everyone, where she is to nobody, and her quests to everyone; gear and the rest as a new
            # character does. Where she is covers her photo's place and her timeline.
            "Joan-CAMWOW US2 Realm 10 RP PvP": char("Joan", {"guild": True, "friends": False, "public": True,
                                                             "parts": {"gold": "g", "stats": "g", "bags": "gp", "place": "", "quests": "p", "profs": "g"}},
                                                    264120, "Windshaper's Circlet", guild="The Moonwell Circle", guildRank="Officer", faction="Alliance",
                                                    # Her circlet scales with her level, as heirlooms do: 13 on her, 10 as an item.
                                                    gear={1: {"id": 264120, "name": "Windshaper's Circlet", "q": 2, "icon": 133071, "ilvl": 13}},
                                                    stats={"ilvl": 13.6, "armor": 731, "str": {"total": 48, "base": 40}}, healthMax=1210,
                                                    photos=[{"t": SHOT_T, "stamp": "110926_201500", "kind": "place", "zone": "Darkshore",
                                                             "sub": "Auberdine", "spot": "Auberdine Inn", "level": 20}],
                                                    places={"Auberdine": 1794000000, "Thendal Village": 1793000000},
                                                    timeline={"entries": [{"zone": "Darkshore", "from": 1793996400, "to": 1794000000, "active": 3000,
                                                                           "level": 19, "levelTo": 20, "quests": [{"title": "The Moonwell Sickness", "xp": 900}]}]},
                                                    before={"done": True, "at": 1793990000, "level": 18, "explored": [{"zone": "Darkshore", "areas": ["Auberdine"]}],
                                                            "quests": {"count": 1, "ids": [7], "titles": {7: "A Quest From Before"}}},
                                                    money=9876543, zone="Darkshore", subzone="Auberdine", x=37.2, y=44.1, hearth="Auberdine",
                                                    played=86400 * 3, quests=[{"title": "The Moonwell Sickness", "level": 18}],
                                                    bags=[{"bag": 0, "size": 16, "free": 15, "slots": {1: {"id": 4306, "name": "Silk Cloth", "n": 20}}}],
                                                    bank=[{"bag": -1, "size": 24, "free": 23, "slots": {1: {"id": 5498, "name": "Small Lustrous Pearl", "n": 3}}}],
                                                    reps=[{"name": "Darnassus", "reaction": 6, "value": 13450}],
                                                    # Her recipes (Crafting.lua): Alchemy, which she practises, and Tailoring, given up.
                                                    profs=[{"name": "Alchemy", "skill": 61, "max": 75, "line": 171}],
                                                    recipes={"Alchemy": {"line": 171, "at": 1794000000, "sk": 60, "mx": 75, "cats": {1001: "Potions"}, "list": {
                                                        2330: {"n": "Minor Healing Potion", "ic": 134831, "o": 118, "c": 1001, "d": 2,
                                                               "u": [{"id": 2447, "n": 1}, {"id": 765, "n": 1}]},
                                                        2337: {"n": "Lesser Healing Potion", "o": 858, "k": 2, "u": [{"id": 118, "n": 1}]}}},
                                                             "Tailoring": {"line": 197, "at": 1793000000, "list": {2963: {"n": "Bolt of Linen Cloth", "o": 2996,
                                                                                                                         "u": [{"id": 2589, "n": 2}]}}}}),
            "Mira-CAMWOW US2 Realm 10 RP PvP": char("Mira", {"guild": False, "friends": False, "public": False}, 99001, "Mira's own hat"),
            # Saved before sharing existed: it was public then, and stays so.
            # Old's cloak was worn since before Reliquary kept item details: only its slot has them.
            "Old-CAMWOW US2 Realm 10 RP PvP": char("Old", None, 2591, "Patched Wanderer's Cloak", money=4242, zone="Teldrassil",
                                                   gear={1: {"id": 2591, "name": "Patched Wanderer's Cloak", "q": 2, "icon": 133071, "ilvl": 9, "req": 4,
                                                             "kind": "Armor", "sub": "Cloth", "loc": "INVTYPE_CLOAK", "sell": 7, "bind": 1}},
                                                   profs=[{"name": "Cooking", "skill": 30, "max": 75}],
                                                   recipes={"Cooking": {"line": 185, "at": 1793900000, "list": {2538: {"n": "Charred Wolf Meat", "o": 2679,
                                                                                                                         "u": [{"id": 2672, "n": 1}]}}}},
                                                   timeline={"entries": [{"zone": "Teldrassil", "from": 1793900000, "to": 1793901200, "active": 1200}]},
                                                   before={"done": True, "at": 1793800000, "level": 9}),
        },
        "items": {
            99001: {"tip": [{"l": "Mira's own hat"}]}, 2589: {"tip": [{"l": "Linen Cloth"}]},
            2591: {"tip": [{"l": "Patched Wanderer's Cloak"}]}, 14146: {"tip": [{"l": "Gloves of the Dawnwatch"}]},
            4306: {"tip": [{"l": "Silk Cloth"}]},
            # What recipes make and use: Joan's (kept from the public copy with her professions) and Old's.
            118: {"tip": [{"l": "Minor Healing Potion"}], "info": {"name": "Minor Healing Potion", "q": 1, "icon": 134831}},
            858: {"tip": [{"l": "Lesser Healing Potion"}]}, 2447: {"tip": [{"l": "Peacebloom"}]}, 765: {"tip": [{"l": "Silverleaf"}]},
            2996: {"tip": [{"l": "Bolt of Linen Cloth"}]},
            2679: {"tip": [{"l": "Charred Wolf Meat"}], "info": {"name": "Charred Wolf Meat", "q": 1, "icon": 133951}}, 2672: {"tip": [{"l": "Stringy Wolf Meat"}, {"l": "Crafting Reagent", "lc": "66bbff"}],
                   "info": {"name": "Stringy Wolf Meat", "q": 1, "icon": 133972, "kind": "Trade Goods", "sub": "Cooking", "cls": 7, "scls": 8, "reagent": True}},
            5498: {"tip": [{"l": "Small Lustrous Pearl"}]},
            # A guild bank item's tooltip with what its page shows; never on the public copy.
            6505: {"tip": [{"l": "Crescent Staff"}], "info": {"name": "Crescent Staff", "q": 3, "icon": 135146, "ilvl": 21, "req": 16,
                                                             "loc": "INVTYPE_2HWEAPON", "sub": "Staff", "sell": 10, "bind": 2}},
            264120: {"tip": [{"l": "Windshaper's Circlet"}], "info": {"name": "Windshaper's Circlet", "q": 2, "loc": "INVTYPE_HEAD", "ilvl": 10}},
        },
        # Auction prices (Prices.lua): Joan's scan of the Alliance house, with a check made since and an
        # item none was listed of; a guildmate's scan of the neutral house; and a key that isn't a house.
        "prices": {
            "CAMWOW US2 Realm 10 RP PvP|Alliance": {"at": NOW - 3600, "by": "Joan", "own": True, "n": 120, "items": {
                14146: {"p": 125000, "q": 2}, 6505: {"p": 98000, "q": 1, "at": NOW - 60}, 2589: {"q": 0, "at": NOW - 30}, 777777: {"p": 5, "q": 1},
                2591: {"p": 4511, "q": 1}}},
            "CAMWOW US2 Realm 10 RP PvP|Neutral": {"at": NOW - 7200, "by": "Orlan", "n": 40, "items": {14146: {"p": 140000, "q": 1}, 2591: {"p": 4422, "q": 1}}},
            "no house": {"at": NOW, "items": {14146: {"p": 1}}},
        },
        # Where the gloves come from (Sources.lua), with a kind of note the addon never writes.
        "sources": {14146: {
            "v": {6737: {"id": 6737, "n": "Innkeeper Shaussiy", "z": "Darkshore", "s": "Auberdine", "x": 37.2, "y": 44.1, "p": 1000, "k": 1, "at": NOW - 100}},
            "d": {"c2167": {"k": "c", "id": 2167, "n": "Blackwood Pathfinder", "z": "Darkshore", "c": 3, "at": NOW},
                  "i4632": {"k": "i", "id": 4632, "z": "Darkshore", "c": 1, "at": NOW}, "x1": {"k": "zz", "at": NOW}},
            "q": {26: {"t": "The Absent Minded Prospector", "ch": True, "at": NOW}},
            "j": {"Mutanus the Devourer|Wailing Caverns": {"e": "Mutanus the Devourer", "i": "Wailing Caverns", "df": "Normal", "at": NOW, "g": "Orlan"}},
            "m": {2330: {"p": "Tailoring", "u": [{"id": 2589, "n": 2}], "at": NOW}},
            "r": {2331: {"p": "Tailoring", "o": 2591, "at": NOW}}}},
        "guilds": {GK: {
            "name": "The Moonwell Circle", "realm": "CAMWOW US2 Realm 10 RP PvP", "motd": "Moonwell at dusk", "at": 1794000000,
            "mine": {"Joan-CAMWOW US2 Realm 10 RP PvP": {"rank": "Officer", "ro": 2}},
            # The guild master's settings: Gear opened to everyone, the records shared, kept by officers.
            "policy": {"by": "Faelwen-CAMWOWUS2Realm10RPPvP", "at": 1794000500, "tb": {1: "g", 2: "a", 3: "g"}, "rc": True, "kp": 2,
                       "nm": {1: "Guild Master", 2: "Officer", 4: "Member"}, "lm": {2: {"g": 100, "w": {1: 10, 2: 10}}, 4: {"g": 5, "w": {1: 2}}}},
            # What the addon judged at the last save: Reagents as the game shows it, Gear by the settings.
            "see": {1: "g", 2: "p"},
            # Who can use each item the guild could hand out, as the addon last weighed it.
            "fits": {6505: [{"who": "Thalia-CAMWOWUS2Realm10RPPvP", "name": "Thalia", "cls": "PRIEST", "level": 19, "own": False, "v": "up", "sl": 16,
                             "il": 21, "ci": 20, "cn": "Priest's Mace", "d": [{"k": "Spirit", "n": 7}, {"k": "Intellect", "n": 3}]},
                            {"who": "Joan-CAMWOWUS2Realm10RPPvP", "name": "Joan", "cls": "DRUID", "level": 13, "me": True, "own": True, "v": "lvl", "lv": 16, "sl": 16},
                            {"who": "x", "v": "maybe"}],
                     # Mira doesn't show the guild her gear: her verdict on the gloves came with her ask.
                     14146: [{"who": "Mira-CAMWOWUS2Realm10RPPvP", "name": "Mira", "cls": "MAGE", "level": 17, "own": True, "asked": True, "v": "lvl", "lv": 19}]},
            "view": {"Joan-CAMWOW US2 Realm 10 RP PvP": {"tabs": [True, True, False], "at": NOW},
                     "Someone-Else": {"tabs": [True, True, True], "at": NOW}},
            "members": [
                {"n": "Faelwen", "rank": "Guild Master", "ro": 1, "lv": 18, "cls": "DRUID"},
                {"n": "Joan", "rank": "Officer", "ro": 2, "lv": 20, "cls": "DRUID", "on": True, "me": True},
                {"n": "Thalia", "rank": "Member", "ro": 4, "lv": 19, "cls": "PRIEST", "on": True, "note": "Herbalist, ask for silverleaf", "p1": "Tailoring", "p1r": 102},
                {"n": "Mira", "rank": "Member", "ro": 4, "lv": 17, "cls": "MAGE", "seen": 1793900000},
            ],
            "bank": {"money": 1287344, "moneyAt": 1794000000, "count": 3, "tabs": {
                1: {"name": "Reagents", "icon": 134190, "at": 1794000000, "by": "Joan", "slots": {1: {"id": 765, "n": 20, "q": 1, "icon": 134190, "name": "Silverleaf"}}},
                2: {"name": "Gear", "icon": 132719, "at": 1794000000, "by": "Thalia", "slots": {4: {"id": 14146, "n": 1, "q": 3, "icon": 132955, "name": "Gloves of the Dawnwatch"}}},
                # A tab none of your characters may view must never show, even if it was saved.
                3: {"name": "Officers", "icon": 133784, "at": 1794000000, "by": "Someone", "slots": {1: {"id": 5498, "n": 3, "q": 2, "name": "Small Lustrous Pearl"}}},
            },
                # Each tab's log and note and the gold log, read at the bank; never shown for a tab you may not see.
                "logs": {1: {"at": 1794000000, "by": "Joan", "list": [{"k": "withdraw", "w": "Saeli", "id": 765, "nm": "Silverleaf", "q": 1, "ic": 134190, "n": 5, "at": 1793990000},
                                                                     {"k": "move", "w": "Orlan", "id": 765, "nm": "Silverleaf", "n": 2, "t1": 1, "t2": 2, "at": 1793995000}]},
                         3: {"at": 1794000000, "by": "Joan", "list": [{"k": "deposit", "w": "Raid rewards only", "id": 5498, "n": 3, "at": 1793990000}]},
                         9: {"at": 1794000000, "by": "Joan", "list": [{"k": "repair", "w": "Orlan", "m": 12345, "at": 1793999000}]}},
                "notes": {1: {"at": 1794000000, "by": "Joan", "text": "Herbs for crafters"}, 3: {"at": 1794000000, "by": "Joan", "text": "Raid rewards only"}},
                "limits": {"Joan-CAMWOW US2 Realm 10 RP PvP": {"at": 1794000000, "tabs": {1: {"w": 10}, 2: {"w": 10}}, "gold": 1000000}},
                # Who each item is set aside for and who asked (Upgrades.lua): Mira asked for the gloves and
                # Joan set them aside for her; Thalia took her ask back; an ask three weeks old; a set-aside
                # for a mace the tab no longer holds; and the board of a tab Joan may not see.
                "board": {
                    2: {"at": NOW - 100, "items": {
                        14146: {"aside": {"Mira-CAMWOWUS2Realm10RPPvP": {"by": "Joan-CAMWOWUS2Realm10RPPvP", "at": NOW - 200}},
                                "asks": {"Mira-CAMWOWUS2Realm10RPPvP": {"at": NOW - 300, "f": NOW - 900, "v": "lvl", "lv": 19},
                                         "Thalia-CAMWOWUS2Realm10RPPvP": {"at": NOW - 250, "off": True},
                                         "Faelwen-CAMWOWUS2Realm10RPPvP": {"at": NOW - 21 * 86400}}},
                        2075: {"aside": {"Thalia-CAMWOWUS2Realm10RPPvP": {"by": "Joan-CAMWOWUS2Realm10RPPvP", "at": NOW - 200}}},
                    }},
                    3: {"at": NOW - 100, "items": {5498: {"asks": {"Thalia-CAMWOWUS2Realm10RPPvP": {"at": NOW - 100}}}}},
                },
            },
        }},
        # The guild's chat, from Discord too, and whispers, as Chat.lua keeps them.
        "chat": {GK: {"list": [{"t": 1794000100, "n": "Thalia", "c": "PRIEST", "m": "Raid at eight in Ashenvale"},
                               {"t": 1794000200, "k": "d", "d": "moonsong", "n": "Mira", "m": "On my way"}],
                      "officer": [{"t": 1794000150, "n": "Faelwen", "c": "DRUID", "m": "Bank tabs at nine, officers"}]}},
        "whispers": {"Faelwen": {"at": 1794000300, "c": "DRUID", "list": [{"t": 1794000300, "m": "Your bracers are ready", "c": "DRUID"}]},
                     "bn:Brannoc#1504": {"at": 1794000400, "c": "WARRIOR", "list": [{"t": 1794000400, "m": "Bring the mats", "c": "WARRIOR"}]}},
        "peers": {
            "Thalia-CAMWOWUS2Realm10RPPvP": {"scopes": {"g": 1794000000}, "got": 1794000000, "hash": "aa", "card": {
                "name": "Thalia", "realm": "CAMWOW US2 Realm 10 RP PvP", "level": 19, "class": "Priest", "classFile": "PRIEST",
                "gear": {10: {"id": 14146, "n": "Gloves of the Dawnwatch", "q": 3, "il": 24, "ic": 132955, "s": "item:14146::::::::19:::::"}},
                "profs": [{"n": "Tailoring", "sk": 102, "mx": 150}], "tal": {"pts": [0, 12, 3], "n": [{"nm": "Inner Focus", "r": 1, "m": 1, "t": 1}]},
                "stats": {"int": 61}},
                "gotAt": {"core": 1794000000, "live": 1794000100},
                "more": {"live": {"zone": "Darnassus", "sub": "Craftsmen's Terrace"},
                         "bags": {"list": [{"z": 16, "b": 0, "s": {2: {"id": 2589, "n": "Linen Cloth", "q": 1, "ic": 132889, "c": 12}}}]},
                         "quests": {"list": [{"t": "Lost in the Glades", "l": 19, "d": True, "o": [{"t": "Find the lost scout", "d": True}]}]},
                         "reps": {"list": [{"n": "Darnassus", "r": 6, "v": 13450, "lo": 9000, "hi": 21000}]},
                         # Her recipes as Joan's game named them; a row that isn't one is left out.
                         "craft": {"list": [{"n": "Tailoring", "l": 197, "at": 1794000000, "c": ["Cloth", ""], "r": [
                             {"id": 2963, "o": 2996, "c": 1, "u": [{"id": 2589, "n": 2}], "nm": "Bolt of Linen Cloth"},
                             {"id": 7418, "c": 2, "u": [{"id": 10940, "n": 1}], "nm": "Enchant Bracer - Minor Health", "ic": 136244}, {"id": "bad"}]}]}}},
            "Faelwen-CAMWOWUS2Realm10RPPvP": {"scopes": {"g": 1794000000}, "card": {"name": "Faelwen", "level": 18, "classFile": "DRUID",
                                                                                   "profs": [{"n": "Leatherworking", "sk": 96, "mx": 150}]},
                                             "more": {"craft": {"list": [{"n": "Leatherworking", "l": 165, "r": [{"id": 2881, "o": 2304, "u": [{"id": 2318, "n": 1}],
                                                                                                                  "nm": "Light Armor Kit"}]}]}}},
            "Brannoc-CAMWOWUS2Realm10RPPvP": {"scopes": {"f": 1794000000}, "card": {"name": "Brannoc", "level": 24, "class": "Warrior", "classFile": "WARRIOR"}},
            "Eluned-CAMWOWUS2Realm10RPPvP": {"scopes": {"p": 1794000000}, "card": {"name": "Eluned", "level": 23}},
        },
        "settings": {"discover": True},
    }}


def trp3():
    return {
        "TRP3_Characters": {"Joan-CAMWOW US2 Realm 10 RP PvP": {"profileID": "P1"}, "Mira-CAMWOW US2 Realm 10 RP PvP": {"profileID": "P2"}},
        "TRP3_Profiles": {"P1": {"player": {"characteristics": {"FN": "Joan", "LN": "Ofârc"}}},
                          "P2": {"player": {"characteristics": {"FN": "Mira", "LN": "Hidden"}}},
                          "P3": {"player": {"characteristics": {"FN": "Brannoc", "LN": "Someone else's profile"}}}},
        "TRP3_Register": {"Brannoc": {"about": "another player's profile, cached"}},
    }


def main():
    work = tempfile.mkdtemp()
    try:
        # Never the real price files: Joan's realm here is the real one, and so would be its prices.
        reliquary.BLIZZARD = os.path.join(work, "blizzard.json")
        reliquary.PRICES = os.path.join(work, "state", "prices.json")
        reliquary.CHOICES = os.path.join(work, "choices.json")
        reliquary.CAPTURES = os.path.join(work, "captures")
        shots = os.path.join(work, "Screenshots")
        os.makedirs(shots)
        png(os.path.join(shots, SHOT), 64, 36)
        wtf = os.path.join(work, "WTF", "Account")
        sv = os.path.join(wtf, "123456789#1", "SavedVariables")
        os.makedirs(sv)
        with open(os.path.join(sv, "Reliquary.lua"), "w") as f:
            f.write(luasv.dumps(saved()))
        with open(os.path.join(sv, "totalRP3.lua"), "w") as f:
            f.write(luasv.dumps(trp3()))

        # Your own copy: all three characters, the guild, its bank (only the tabs you may view) and others' reliquaries.
        own = reliquary.build_state(wtf, shots_dir=shots)
        assert [c["name"] for c in own["chars"]] == ["Joan", "Mira", "Old"], [c["name"] for c in own["chars"]]
        joan_share = own["chars"][0]["share"]
        assert {k: joan_share[k] for k in ("guild", "friends", "public")} == {"guild": True, "friends": False, "public": True}
        assert joan_share["parts"] == {"gear": "gfp", "talents": "gfp", "profs": "g", "stats": "g", "gold": "g", "place": "",
                                       "played": "", "reps": "", "quests": "p", "bags": "gp", "bank": ""}, joan_share["parts"]
        oj = own["chars"][0]
        assert oj["money"] == 9876543 and oj["zone"] == "Darkshore" and oj["stats"]["armor"] == 731, "your own copy shows everything"
        assert oj["photos"][0]["file"] == SHOT and oj["photos"][0]["sub"] == "Auberdine", oj["photos"]
        assert [(e["zone"], e["quests"][0]["title"]) for e in oj["journey"]["entries"]] == [("Darkshore", "The Moonwell Sickness")], oj["journey"]
        assert "places" not in oj, "the page never needed the list of every place she has stood in"
        # Her recipes: the profession she practises, by name, with what each makes and uses; not the one she gave up.
        assert oj["recipes"] == [{"name": "Alchemy", "line": 171, "at": 1794000000, "skill": 60, "max": 75, "recipes": [
            {"rid": 2337, "name": "Lesser Healing Potion", "uses": [{"id": 118, "n": 1}], "makes": {"id": 858, "n": 2}},
            {"rid": 2330, "name": "Minor Healing Potion", "icon": 134831, "cat": "Potions", "diff": "easy", "uses": [{"id": 2447, "n": 1}, {"id": 765, "n": 1}],
             "makes": {"id": 118, "n": 1}}]}], oj["recipes"]
        assert own["chars"][2]["share"] is None
        # An item worn since before Reliquary kept item details has them from its slot: its page's
        # header, sell price and auction line need them. Details kept with the tooltip come first.
        assert own["itemInfo"]["2591"] == {"q": 2, "icon": 133071, "ilvl": 9, "req": 4, "kind": "Armor", "sub": "Cloth", "loc": "INVTYPE_CLOAK",
                                           "sell": 7, "bind": 1, "name": "Patched Wanderer's Cloak"}, own["itemInfo"]["2591"]
        assert own["itemInfo"]["264120"] == {"name": "Windshaper's Circlet", "q": 2, "loc": "INVTYPE_HEAD", "ilvl": 10, "icon": 133071}, own["itemInfo"]["264120"]
        # A cooking ingredient keeps the game's mark that it's a crafting reagent: the page names the
        # cooks from it, as the game's tooltips do.
        meat = own["itemInfo"]["2672"]
        assert meat.get("reagent") is True and meat.get("cls") == 7 and meat.get("scls") == 8, meat
        (g,) = own["guilds"]
        assert g["name"] == "The Moonwell Circle" and g["motd"] == "Moonwell at dusk" and len(g["members"]) == 4
        thalia = next(m for m in g["members"] if m["name"] == "Thalia")
        assert thalia["shares"] and thalia["key"] == "Thalia-CAMWOWUS2Realm10RPPvP" and thalia["profs"] == [{"name": "Tailoring", "skill": 102}]
        assert not next(m for m in g["members"] if m["name"] == "Mira")["shares"]
        assert next(m for m in g["members"] if m["name"] == "Faelwen")["shares"], "a guildmate who shows the guild only their professions shares"
        assert [t["name"] for t in g["bank"]["tabs"]] == ["Reagents", "Gear"], "a tab none of your characters may view"
        assert g["bank"]["tabs"][1]["slots"]["4"]["name"] == "Gloves of the Dawnwatch" and g["bank"]["money"] == 1287344
        # Each tab's log (newest first, a move naming the tab it went to) and note, the gold log, what
        # Joan's rank may take under the guild master's settings, and the settings themselves.
        bank = g["bank"]
        reag, gear = bank["tabs"]
        assert reag["note"] == "Herbs for crafters" and [e["kind"] for e in reag["log"]["entries"]] == ["move", "withdraw"], reag
        assert reag["log"]["entries"][0]["to"] == "Gear" and reag["log"]["entries"][1] == {"kind": "withdraw", "who": "Saeli", "at": 1793990000,
                                                                                          "id": 765, "name": "Silverleaf", "q": 1, "icon": 134190, "n": 5}
        assert gear["shared"] == "Everyone in the guild" and "shared" not in reag and "log" not in gear
        assert bank["goldLog"]["entries"] == [{"kind": "repair", "who": "Orlan", "at": 1793999000, "money": 12345}], bank["goldLog"]
        assert bank["limits"] == {"rank": "Officer", "tabs": {1: 10, 2: 10}, "gold": 100}, bank["limits"]
        assert bank["policy"] == {"by": "Faelwen", "at": 1794000500, "records": True, "keepers": "Officer and up"}, bank["policy"]
        # The gloves: set aside for Mira by Joan, and Mira's ask; nothing taken back, too old, gone from
        # the tab, or from a tab Joan may not see.
        assert gear["board"] == {"14146": {"aside": [{"who": "Mira-CAMWOWUS2Realm10RPPvP", "name": "Mira", "at": NOW - 200, "by": "Joan"}],
                                           "asks": [{"who": "Mira-CAMWOWUS2Realm10RPPvP", "name": "Mira", "at": NOW - 900}]}}, gear["board"]
        assert "board" not in reag
        # Who can use the staff, best help first, as the addon weighed it (a row it can't read is left out),
        # and the details an item's page shows.
        assert g["fits"] == {"6505": [
            {"who": "Thalia-CAMWOWUS2Realm10RPPvP", "name": "Thalia", "classFile": "PRIEST", "level": 19, "me": False, "own": False, "v": "up", "slot": 16,
             "ilvl": 21, "cur": 20, "curName": "Priest's Mace", "changes": [{"stat": "Spirit", "n": 7}, {"stat": "Intellect", "n": 3}]},
            {"who": "Joan-CAMWOWUS2Realm10RPPvP", "name": "Joan", "classFile": "DRUID", "level": 13, "me": True, "own": True, "v": "lvl", "slot": 16,
             "at": 16, "changes": []}],
            "14146": [{"who": "Mira-CAMWOWUS2Realm10RPPvP", "name": "Mira", "classFile": "MAGE", "level": 17, "me": False, "own": True, "v": "lvl", "at": 19,
                       "changes": [], "asked": True}]}, g["fits"]
        assert own["itemInfo"]["6505"] == {"q": 3, "icon": 135146, "ilvl": 21, "req": 16, "sub": "Staff", "loc": "INVTYPE_2HWEAPON", "sell": 10, "bind": 2,
                                           "name": "Crescent Staff"}, own["itemInfo"]["6505"]
        # Prices: the houses (not a key that isn't one), and each house's word on the items the page
        # shows, newest first: a check at the house beats the scan; "none listed" has no price.
        pr = own["prices"]
        assert set(pr["houses"]) == {"CAMWOW US2 Realm 10 RP PvP|Alliance", "CAMWOW US2 Realm 10 RP PvP|Neutral"}, pr["houses"]
        assert pr["houses"]["CAMWOW US2 Realm 10 RP PvP|Alliance"] == {"realm": "CAMWOW US2 Realm 10 RP PvP", "side": "Alliance", "at": NOW - 3600, "by": "Joan",
                                                                       "own": True, "n": 120}, pr["houses"]
        assert pr["items"]["14146"] == [
            {"p": 125000, "q": 2, "at": NOW - 3600, "live": False, "more": False, "house": "CAMWOW US2 Realm 10 RP PvP|Alliance"},
            {"p": 140000, "q": 1, "at": NOW - 7200, "live": False, "more": False, "house": "CAMWOW US2 Realm 10 RP PvP|Neutral"}], pr["items"]["14146"]
        assert pr["items"]["6505"][0]["p"] == 98000 and pr["items"]["6505"][0]["live"] is True
        assert pr["items"]["2589"] == [{"q": 0, "at": NOW - 30, "live": True, "more": False, "house": "CAMWOW US2 Realm 10 RP PvP|Alliance"}], pr["items"]["2589"]
        assert "777777" not in pr["items"], "a price for an item the page never shows"
        # Blizzard's hourly data, once a house of its is matched to Joan's: newer than her scan, it
        # is the gloves' newest word; a house not matched to hers never shows.
        reliquary.BLIZZARD = os.path.join(work, "blizzard.json")
        with open(reliquary.BLIZZARD, "w") as f:
            json.dump({"map": {"CAMWOW US2 Realm 10 RP PvP|Alliance": 113}, "houses": {
                "113": {"name": "Alliance Auction House", "side": "Alliance", "snaps": [{"at": NOW - 600, "n": 9, "items": {"14146": [119000, 3], "x": [1, 1]}}]},
                "114": {"name": "Alliance Auction House", "side": "Alliance", "snaps": [{"at": NOW - 60, "n": 4, "items": {"14146": [5, 1]}}]}}}, f)
        withapi = reliquary.build_state(wtf, shots_dir=shots)
        first = withapi["prices"]["items"]["14146"][0]
        assert first == {"p": 119000, "q": 3, "at": NOW - 600, "live": False, "more": False, "house": "CAMWOW US2 Realm 10 RP PvP|Alliance"}, first
        assert withapi["prices"]["houses"]["CAMWOW US2 Realm 10 RP PvP|Alliance"]["by"] == "Blizzard" and not any(w["p"] == 5 for w in withapi["prices"]["items"]["14146"])
        assert "prices" not in reliquary.build_state(wtf, public=True, shots_dir=shots)
        # Never a snapshot more than thirty days old (Blizzard's terms): the silk in Joan's bags, which
        # her own scan didn't list, has no word at all.
        with open(reliquary.BLIZZARD, "w") as f:
            json.dump({"map": {"CAMWOW US2 Realm 10 RP PvP|Alliance": 113}, "houses": {
                "113": {"name": "Alliance Auction House", "side": "Alliance", "snaps": [{"at": NOW - 31 * 86400, "n": 9, "items": {"4306": [900, 20]}}]}}}, f)
        assert "4306" not in reliquary.build_state(wtf, shots_dir=shots)["prices"]["items"], "a Blizzard snapshot more than thirty days old was used"
        with open(reliquary.BLIZZARD, "w") as f:
            json.dump({"map": {"CAMWOW US2 Realm 10 RP PvP|Alliance": 113}, "houses": {
                "113": {"name": "Alliance Auction House", "side": "Alliance", "snaps": [{"at": NOW - 29 * 86400, "n": 9, "items": {"4306": [900, 20]}}]}}}, f)
        assert reliquary.build_state(wtf, shots_dir=shots)["prices"]["items"]["4306"][0]["p"] == 900, "a Blizzard snapshot within thirty days went unused"
        os.remove(reliquary.BLIZZARD)
        # A tooltip saved before the game had loaded part of it (a recipe's dish, by Reliquary 1.2.2)
        # never shows that part's "Retrieving item information".
        recipe = [{"l": "Recipe: Cooked Crab Claw", "lc": "ffffff"}, {"l": "Retrieving item information", "lc": "ff2020"},
                  {"l": "Use: Teaches you how to cook a Crab Claw.", "lc": "ffffff"}, {"l": "Requires Cooking (85)", "lc": "ff2020"}]
        assert [x["l"] for x in reliquary.tip(recipe)] == ["Recipe: Cooked Crab Claw", "Use: Teaches you how to cook a Crab Claw.", "Requires Cooking (85)"]
        # The game's singular-or-plural codes read as the game shows them (Forever's real tooltips have these).
        timed = [{"l": "Use: Increase sharp weapon damage by 3 for 30 minutes. (1 |4Sec:Sec; Cooldown)"}, {"l": "Lasts 2 |4hour:hrs;, or 1 |4hour:hrs;"},
                 {"l": "Charges: |4Charge:Charges;"}]
        assert [x["l"] for x in reliquary.tip(timed)] == ["Use: Increase sharp weapon damage by 3 for 30 minutes. (1 Sec Cooldown)",
                                                          "Lasts 2 hrs, or 1 hour", "Charges: Charges"], reliquary.tip(timed)
        # Where the gloves come from, in plain words: cheapest vendor first, the drops most seen first,
        # a container named when it can be, a note a guildmate gave says whose.
        notes = reliquary.notes_view(reliquary.notes_of([saved()["ReliquaryDB"]])[14146], {2589: "Linen Cloth", 2591: "Patched Wanderer's Cloak"}.get)
        assert notes == {
            "vendors": [{"npc": 6737, "name": "Innkeeper Shaussiy", "zone": "Darkshore", "sub": "Auberdine", "x": 37.2, "y": 44.1, "price": 1000, "stack": 1}],
            "quests": [{"id": 26, "title": "The Absent Minded Prospector", "choice": True}],
            "journal": [{"encounter": "Mutanus the Devourer", "instance": "Wailing Caverns", "modes": "Normal", "from": "Orlan"}],
            "drops": [{"kind": "creature", "id": 2167, "name": "Blackwood Pathfinder", "zone": "Darkshore", "count": 3},
                      {"kind": "container", "id": 4632, "zone": "Darkshore", "count": 1}],
            "made": [{"recipe": 2330, "profession": "Tailoring", "uses": [{"id": 2589, "n": 2, "name": "Linen Cloth"}]}],
            "uses": [{"recipe": 2331, "profession": "Tailoring", "makes": 2591, "name": "Patched Wanderer's Cloak"}]}, notes
        assert "Raid rewards only" not in json.dumps(own, ensure_ascii=False), "the records of a tab you may not see are on your own page"
        # Gear shows Joan because the settings open it to everyone. Were her own rank unable to view
        # it, it would still show while Faelwen leads, and go once someone else does. Then the limits
        # are what the bank itself told Joan.
        moved = saved()
        mg = moved["ReliquaryDB"]["guilds"][GK]
        mg["view"]["Joan-CAMWOW US2 Realm 10 RP PvP"]["tabs"] = [True, False, False]
        assert [t["name"] for t in reliquary.guild(GK, mg, {})["bank"]["tabs"]] == ["Reagents", "Gear"]
        mg["members"][0]["ro"], mg["members"][1]["ro"] = 2, 1
        mg["mine"]["Joan-CAMWOW US2 Realm 10 RP PvP"]["ro"] = 1
        later = reliquary.guild(GK, mg, {})["bank"]
        assert [t["name"] for t in later["tabs"]] == ["Reagents"] and "policy" not in later, later
        assert later["limits"] == {"rank": "Officer", "tabs": {1: 10, 2: 10}, "gold": None}, later["limits"]
        # A month after Joan was last at the bank, which tabs she may view is no longer known: only the tab
        # the guild master's settings open to everyone still shows.
        stale = saved()
        stale["ReliquaryDB"]["guilds"][GK]["view"]["Joan-CAMWOW US2 Realm 10 RP PvP"]["at"] = NOW - 31 * 86400
        assert [t["name"] for t in reliquary.guild(GK, stale["ReliquaryDB"]["guilds"][GK], {})["bank"]["tabs"]] == ["Gear"]
        peers = {p["name"]: p for p in own["peers"]}
        assert peers["Thalia"]["scopes"] == ["guild"] and peers["Brannoc"]["scopes"] == ["friends"] and peers["Eluned"]["scopes"] == ["public"]
        assert peers["Thalia"]["gear"]["10"] == {"id": 14146, "name": "Gloves of the Dawnwatch", "q": 3, "icon": 132955, "ilvl": 24}
        assert peers["Thalia"]["talents"]["pts"] == [0, 12, 3] and peers["Thalia"]["profs"][0]["name"] == "Tailoring"
        # What Thalia shows beyond her gear: where she is (not her gold), bags, quests, reputation.
        th = peers["Thalia"]
        assert th["live"] == {"zone": "Darnassus", "subzone": "Craftsmen's Terrace", "at": 1794000100}, th["live"]
        assert th["bags"][0]["slots"]["2"] == {"id": 2589, "name": "Linen Cloth", "q": 1, "icon": 132889, "n": 12} and th["bags"][0]["free"] == 15
        assert th["quests"][0]["title"] == "Lost in the Glades" and th["quests"][0]["obj"][0]["done"]
        assert th["reps"][0]["name"] == "Darnassus" and th["reps"][0]["reaction"] == 6
        assert "bank" not in th and "live" not in peers["Brannoc"]
        assert th["recipes"] == [{"name": "Tailoring", "line": 197, "at": 1794000000, "skill": 102, "max": 150, "recipes": [
            {"rid": 2963, "name": "Bolt of Linen Cloth", "cat": "Cloth", "uses": [{"id": 2589, "n": 2}], "makes": {"id": 2996, "n": 1}},
            {"rid": 7418, "name": "Enchant Bracer - Minor Health", "icon": 136244, "uses": [{"id": 10940, "n": 1}]}]}], th["recipes"]
        assert peers["Faelwen"]["recipes"][0]["recipes"][0]["makes"] == {"id": 2304, "n": 1} and "recipes" not in peers["Brannoc"]

        # The public copy: Joan and Old only, and nothing of anyone else.
        pub = reliquary.build_state(wtf, public=True, shots_dir=shots)
        assert [c["name"] for c in pub["chars"]] == ["Joan", "Old"], [c["name"] for c in pub["chars"]]
        assert "guilds" not in pub and "peers" not in pub and "prices" not in pub
        assert set(pub["items"]) == {"264120", "2591", "4306", "2679", "2672"}, sorted(pub["items"])
        assert set(pub["itemInfo"]) == {"264120", "2679", "2591", "2672"}, "an item's details on the public copy are only for what it shows"
        assert pub["itemInfo"]["2591"]["sell"] == 7 and pub["itemInfo"]["2591"]["loc"] == "INVTYPE_CLOAK", pub["itemInfo"]["2591"]
        # Joan's public sheet: what she shows everyone, and nothing she keeps for her guild or herself.
        pj, po = pub["chars"]
        assert pj["hidden"] == ["profs", "stats", "gold", "place", "played", "reps", "bank"], pj["hidden"]
        assert pj["recipes"] == [] and pj["profs"] == [], "Joan keeps her professions, and their recipes, to her guild"
        assert "money" not in pj and "zone" not in pj and "x" not in pj and "hearth" not in pj and "played" not in pj, sorted(pj)
        assert pj["stats"] == {"ilvl": 13.6} and "healthMax" not in pj, "her sheet kept to the guild, her item level going with her gear"
        assert pj["photos"] and pj["photos"][0]["file"] == SHOT and not {"zone", "sub", "spot"} & set(pj["photos"][0]), pj["photos"]
        assert not pj["journey"], "the timeline says where she has been"
        assert po["journey"]["entries"][0]["zone"] == "Teldrassil", "a character showing where it is keeps its timeline"
        assert po["journey"]["before"]["level"] == 9, "and what came before it"
        assert pj["bank"] == [] and pj["reps"] == [] and pj["bags"][0]["slots"]["1"]["name"] == "Silk Cloth" and pj["quests"][0]["title"] == "The Moonwell Sickness"
        assert "share" not in pj, "the public copy doesn't say what a character keeps from it"
        assert po["hidden"] == [] and po["money"] == 4242 and po["zone"] == "Teldrassil", "a character from before sharing shows everything, as it did"
        assert po["recipes"][0]["recipes"][0]["makes"] == {"id": 2679, "n": 1}, "and its recipes"
        raw = json.dumps(pub, ensure_ascii=False)
        for kept in ("9876543", "Darkshore", "Auberdine", "Small Lustrous Pearl", "Minor Healing Potion", "Peacebloom", "Bolt of Linen Cloth"):
            assert kept not in raw, f"Joan's {kept!r} is on the public copy"
        for secret in SECRETS:
            if secret == "The Moonwell Circle":
                continue  # Joan's own guild name is on her own public sheet, as before
            assert secret not in raw, f"{secret!r} is on the public copy"
        assert "Moonwell at dusk" not in raw

        # Over HTTP, as friends reach it.
        srv = reliquary.Server(("127.0.0.1", 0), reliquary.Handler)
        srv.wtf, srv.shots, srv.public = wtf, shots, True
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        base = f"http://127.0.0.1:{srv.server_address[1]}"

        def get(path):
            try:
                with urllib.request.urlopen(base + path, timeout=30) as r:
                    return r.status, r.read().decode("utf-8", "replace")
            except urllib.error.HTTPError as e:
                return e.code, e.read().decode("utf-8", "replace")
        status, body = get("/api/state")
        assert status == 200 and "Mira" not in body and "Thalia" not in body and "Gloves of the Dawnwatch" not in body
        status, body = get("/")
        assert status == 200 and "Mira" not in body and "Thalia" not in body
        status, body = get("/api/item?id=14146")
        assert status == 200 and json.loads(body) == {"id": 14146, "prices": [], "history": {}} and "Innkeeper" not in body, \
            "an item the public copy doesn't show has a price or notes there"

        # Its auction prices: Blizzard's hourly prices alone (they name no player), for the houses
        # Joan and Old can use (their realm's Alliance and neutral ones), for the items they show, and
        # their thirty days. Never a scan made in the game (Joan's 4511 or Orlan's 4422 for the
        # cloak), never a house of another realm, never an item the public copy doesn't show.
        realm = "CAMWOW US2 Realm 10 RP PvP"
        api_path, hist_path = os.path.join(work, "api.json"), os.path.join(work, "api-history.json")
        with open(api_path, "w") as f:
            json.dump({"map": {f"{realm}|Alliance": 113, f"{realm}|Neutral": 119, "Elsewhere|Horde": 114}, "houses": {
                "113": {"side": "Alliance", "snaps": [{"at": NOW - 600, "n": 9, "items": {"4306": [900, 20], "2591": [4800, 2], "14146": [119000, 3]}}]},
                "119": {"side": "Neutral", "snaps": [{"at": NOW - 600, "n": 3, "items": {"4306": [950, 5]}}]},
                "114": {"side": "Horde", "snaps": [{"at": NOW - 600, "n": 2, "items": {"4306": [12, 1]}}]}}}, f)
        today, last_week = (time.strftime("%Y-%m-%d", time.localtime(t)) for t in (NOW, NOW - 7 * 86400))
        long_ago = time.strftime("%Y-%m-%d", time.localtime(NOW - 40 * 86400))
        with open(hist_path, "w") as f:
            json.dump({"houses": {f"{realm}|Alliance": {"items": {"4306": {last_week: [880, 30], today: [900, 20], long_ago: [5, 1]}, "14146": {today: [119000, 3]}}},
                                  "Elsewhere|Horde": {"items": {"4306": {today: [12, 1]}}}}}, f)
        shown = reliquary.public_prices(pub["chars"], api_path, hist_path, NOW)
        assert set(shown["houses"]) == {f"{realm}|Alliance", f"{realm}|Neutral"}, shown["houses"]
        assert shown["houses"][f"{realm}|Alliance"] == {"realm": realm, "side": "Alliance", "at": NOW - 600, "by": "Blizzard", "api": True, "n": 9}, shown["houses"]
        assert shown["items"] == {"4306": [{"p": 900, "q": 20, "at": NOW - 600, "live": False, "more": False, "house": f"{realm}|Alliance"},
                                           {"p": 950, "q": 5, "at": NOW - 600, "live": False, "more": False, "house": f"{realm}|Neutral"}],
                                  "2591": [{"p": 4800, "q": 2, "at": NOW - 600, "live": False, "more": False, "house": f"{realm}|Alliance"}]}, shown["items"]
        assert shown["history"] == {"4306": {f"{realm}|Alliance": [[last_week, 880, 30], [today, 900, 20]]}}, shown["history"]
        said = json.dumps(shown)
        assert not any(x in said for x in ("Joan", "Orlan", "Elsewhere", "119000", "4511", "4422")), said
        # The public copy cuts what it is sent again: what it doesn't show, or has kept past thirty days, never shows.
        sent = json.loads(said)
        sent["items"]["14146"] = [{"p": 119000, "q": 3, "at": NOW - 600, "house": f"{realm}|Alliance"}]
        sent["items"]["4306"].append({"p": 1, "q": 1, "at": NOW - 31 * 86400, "house": f"{realm}|Alliance"})
        sent["houses"]["Elsewhere|Horde"] = {"realm": "Elsewhere", "side": "Horde", "at": NOW - 600}
        sent["history"]["4306"][f"{realm}|Alliance"].insert(0, [long_ago, 5, 1])
        sent["history"]["14146"] = {f"{realm}|Alliance": [[today, 119000, 3]]}
        prices_path = os.path.join(work, "public-prices.json")
        with open(prices_path, "w") as f:
            json.dump(sent, f)
        again = reliquary.cut_prices(sent, pub["chars"], NOW)
        assert again == shown, again
        stale_house = json.loads(said)
        stale_house["houses"][f"{realm}|Neutral"]["at"] = NOW - 31 * 86400
        gone = reliquary.cut_prices(stale_house, pub["chars"], NOW)
        assert f"{realm}|Neutral" not in gone["houses"] and [w["p"] for w in gone["items"]["4306"]] == [900], gone
        # Over HTTP: the item's page and its thirty days, never its notes; the page follows a new file.
        srv.shutdown()
        srv = reliquary.Server(("127.0.0.1", 0), reliquary.Handler)
        srv.wtf, srv.shots, srv.public, srv.prices = wtf, shots, True, prices_path
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        base = f"http://127.0.0.1:{srv.server_address[1]}"
        state = json.loads(get("/api/state")[1])
        assert state["prices"] == {"houses": shown["houses"], "items": shown["items"]}, state["prices"]
        detail = json.loads(get("/api/item?id=4306")[1])
        assert detail == {"id": 4306, "prices": shown["items"]["4306"], "history": shown["history"]["4306"]}, detail
        assert json.loads(get("/api/item?id=14146")[1])["prices"] == [], "an item the public copy doesn't show has a price there"
        time.sleep(0.05)
        del sent["items"]["2591"]
        with open(prices_path, "w") as f:
            json.dump(sent, f)
        os.utime(prices_path, (time.time() + 5, time.time() + 5))
        assert "2591" not in json.loads(get("/api/state")[1])["prices"]["items"], "the public copy kept showing prices it was sent before"
        srv.shutdown()
        # Sent prices whose newest is more than thirty days old go from the public copy's disk too (a PC
        # left off that long); fresh ones, and a file with none in it yet, stay.
        assert not reliquary.expire_prices(prices_path, NOW) and os.path.exists(prices_path)
        assert not reliquary.expire_prices(prices_path, NOW + 29 * 86400) and os.path.exists(prices_path)
        assert reliquary.expire_prices(prices_path, NOW + 31 * 86400) and not os.path.exists(prices_path)
        with open(prices_path, "w") as f:
            json.dump({"houses": {}, "items": {}, "history": {}}, f)
        assert not reliquary.expire_prices(prices_path, NOW + 99 * 86400) and os.path.exists(prices_path)

        # Your own copy: an item's page asks for its prices, its thirty days, and where it comes from.
        reliquary.PRICES = os.path.join(work, "state", "prices.json")
        own_srv = reliquary.Server(("127.0.0.1", 0), reliquary.Handler)
        own_srv.wtf, own_srv.shots, own_srv.public = wtf, shots, False
        threading.Thread(target=own_srv.serve_forever, daemon=True).start()
        base = f"http://127.0.0.1:{own_srv.server_address[1]}"
        status, body = get("/api/item?id=14146")
        detail = json.loads(body)
        assert status == 200 and [w["house"].split("|")[1] for w in detail["prices"]] == ["Alliance", "Neutral"], body[:300]
        assert detail["sources"]["vendors"][0]["name"] == "Innkeeper Shaussiy" and detail["sources"]["made"][0]["uses"][0]["name"] == "Linen Cloth", detail["sources"]
        today = time.strftime("%Y-%m-%d", time.localtime(NOW - 3600))
        assert detail["history"]["CAMWOW US2 Realm 10 RP PvP|Alliance"] == [[today, 125000, 2]], detail["history"]
        assert get("/api/item?id=x")[0] == 404 and json.loads(get("/api/item?id=999")[1])["prices"] == []
        own_srv.shutdown()

        # The history keeps the day's lowest price for each item, a point a day, for thirty days.
        path = os.path.join(work, "hist.json")
        day1, day2 = NOW - 3 * 86400, NOW - 2 * 86400
        h = {"H|Alliance": {"items": {1: {"p": 500, "q": 3, "at": day1}}}}
        reliquary.record_history(path, h, NOW)
        h["H|Alliance"]["items"][1] = {"p": 450, "q": 5, "at": day1 + 60}
        reliquary.record_history(path, h, NOW)
        h["H|Alliance"]["items"][1] = {"p": 600, "q": 1, "at": day1 + 120}
        reliquary.record_history(path, h, NOW)
        h["H|Alliance"]["items"][1] = {"p": 520, "q": 2, "at": day2}
        hist = reliquary.record_history(path, h, NOW)
        d1, d2 = (time.strftime("%Y-%m-%d", time.localtime(t)) for t in (day1, day2))
        assert reliquary.history_of(hist, 1) == {"H|Alliance": [[d1, 450, 5], [d2, 520, 2]]}, reliquary.history_of(hist, 1)
        h["H|Alliance"]["items"][1] = {"p": None, "q": 0, "at": day2 + 60}
        assert reliquary.history_of(reliquary.record_history(path, h, NOW), 1)["H|Alliance"][-1] == [d2, 520, 2], "a check with none listed made a point"
        assert reliquary.history_of(reliquary.record_history(path, h, NOW + 40 * 86400), 1) == {}, "points older than thirty days were kept"
        # Not even by a day: a point of the day thirty days back may be older than thirty days, so
        # that whole day goes (at noon, its morning is), and the day after stays.
        noon = time.mktime((2026, 11, 9, 12, 0, 0, 0, 0, -1))
        edge = {"T|Alliance": {"items": {1: {"p": 100, "q": 1, "at": noon - 30 * 86400 - 60}, 2: {"p": 200, "q": 1, "at": noon - 29 * 86400}}}}
        kept = reliquary.record_history(os.path.join(work, "edge.json"), edge, noon)
        assert reliquary.history_of(kept, 1) == {} and len(reliquary.history_of(kept, 2)["T|Alliance"]) == 1, kept
        # Read with the time, a history that hasn't let an old point go yet never shows it; the
        # sample's, made on fixed days, is read without it and keeps them.
        late = {"houses": {"T|Alliance": {"items": {"1": {time.strftime("%Y-%m-%d", time.localtime(noon - 30 * 86400)): [100, 1]}}}}}
        assert reliquary.history_of(late, 1, noon) == {} and reliquary.history_of(late, 1)["T|Alliance"], "a point older than thirty days shown"
        # The hourly price run lets old points go too: while it holds the history, the server waits.
        with open(path + ".lock", "a") as held:
            fcntl.flock(held, fcntl.LOCK_EX)
            writer = threading.Thread(target=reliquary.record_history, args=(path, h, NOW), daemon=True)
            writer.start()
            writer.join(0.5)
            assert writer.is_alive(), "the history was written while the price run held it"
        writer.join(10)
        assert not writer.is_alive()

        # What the publisher sends the public copy: the same cut, before it leaves this PC.
        dest = os.path.join(work, "cut")
        publish.cut_saved_files(wtf, dest)
        cut_dir = os.path.join(dest, "123456789#1", "SavedVariables")
        cut = luasv.load(os.path.join(cut_dir, "Reliquary.lua"))["ReliquaryDB"]
        assert sorted(cut) == ["chars", "items", "meta", "schema"], sorted(cut)
        assert sorted(cut["chars"]) == ["Joan-CAMWOW US2 Realm 10 RP PvP", "Old-CAMWOW US2 Realm 10 RP PvP"]
        assert sorted(cut["items"]) == [2591, 2672, 2679, 4306, 264120]
        assert not cut["chars"]["Joan-CAMWOW US2 Realm 10 RP PvP"].get("recipes") and cut["chars"]["Old-CAMWOW US2 Realm 10 RP PvP"]["recipes"]["Cooking"]
        cj = cut["chars"]["Joan-CAMWOW US2 Realm 10 RP PvP"]
        assert not any(cj.get(k) for k in ("money", "zone", "subzone", "x", "y", "hearth", "played", "places", "timeline", "before", "healthMax")), sorted(cj)
        assert cj["stats"] == {"ilvl": 13.6} and not {"zone", "sub", "spot"} & set(cj["photos"][0]), (cj["stats"], cj["photos"])
        assert not cj.get("reps") and not cj.get("bank") and cj["bags"] and cj["quests"], sorted(cj)
        text = open(os.path.join(cut_dir, "Reliquary.lua")).read() + open(os.path.join(cut_dir, "totalRP3.lua")).read()
        for secret in SECRETS + ["Hidden", "another player's profile", "9876543", "Darkshore", "Auberdine", "A Quest From Before", "Minor Healing Potion",
                                 "Light Armor Kit"]:
            if secret == "The Moonwell Circle":
                assert "guilds" not in cut
                continue
            assert secret not in text, f"{secret!r} would leave this PC for the public copy"
        cut_trp = luasv.load(os.path.join(cut_dir, "totalRP3.lua"))
        assert list(cut_trp) == ["TRP3_Characters", "TRP3_Profiles"] and list(cut_trp["TRP3_Profiles"]) == ["P1"]
        # And the prices it sends are worked out from that cut alone, from Blizzard's data alone.
        reliquary.BLIZZARD, reliquary.API_PRICES = api_path, hist_path
        publish.cut_prices_file(dest, os.path.join(work, "sent-prices.json"))
        with open(os.path.join(work, "sent-prices.json")) as f:
            sent_prices = json.load(f)
        assert set(sent_prices["houses"]) == set(shown["houses"]) and set(sent_prices["items"]) == set(shown["items"]), sent_prices
        assert "4511" not in json.dumps(sent_prices) and "4422" not in json.dumps(sent_prices)
        # It sends them again when Blizzard's data changes.
        before = publish.data_sig()
        os.utime(api_path, (time.time() + 9, time.time() + 9))
        assert publish.data_sig() != before, "new Blizzard prices would wait for the next game save"
        reliquary.BLIZZARD = os.path.join(work, "blizzard.json")
        # The public copy reading the cut shows what it showed from the full files.
        cut_state = reliquary.build_state(dest, public=True, shots_dir=shots)
        assert [c["name"] for c in cut_state["chars"]] == ["Joan", "Old"] and cut_state["chars"][0]["profile"]["last"] == "Ofârc"
        assert cut_state["items"] == pub["items"]
        assert cut_state["chars"][0]["photos"] == pub["chars"][0]["photos"] and cut_state["chars"][0]["stats"] == {"ilvl": 13.6}
        # Gear kept back takes its item level with it.
        bare = reliquary.hide_parts({"gear": {"1": {"id": 1}}, "stats": {"ilvl": 13.6, "armor": 731}}, ["gear"])
        assert bare == {"gear": {}, "stats": {"armor": 731}}, bare
        # A file the game is half-way through writing: the last good cut stays.
        with open(os.path.join(sv, "Reliquary.lua"), "a") as f:
            f.write("\nReliquaryDB = { [\"chars\"] = {")
        publish.cut_saved_files(wtf, dest)
        assert luasv.load(os.path.join(cut_dir, "Reliquary.lua"))["ReliquaryDB"]["chars"] == cut["chars"]
        # An account that has gone: its cut goes too.
        shutil.rmtree(os.path.join(wtf, "123456789#1"))
        publish.cut_saved_files(wtf, dest)
        assert os.listdir(dest) == []
        print("sharing ok: own copy has the guild, bank and 3 reliquaries; the public copy and its files hold none of it")
    finally:
        shutil.rmtree(work)


if __name__ == "__main__":
    main()
