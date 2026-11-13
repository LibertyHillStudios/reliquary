"""Total RP 3 on the dashboard: every part of a profile read as Total RP 3 means it, its markup made
plain data (hostile text included), other players' profiles matched to the reliquaries they share and
to guildmates, with Forever's "Given Family" names and with Name-Realm names, and none of it on the
public copy or in what the publisher sends there.

    python3 tests/test_roleplay.py
"""
import json
import os
import shutil
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "server"))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import luasv  # noqa: E402
import reliquary  # noqa: E402
import roleplay  # noqa: E402
import publish  # noqa: E402

GIFT = roleplay.icon_id("inv_misc_gift_02")
COIN = roleplay.icon_id("inv_misc_coin_02")


def thalia_profile():
    return {
        "characteristics": {
            "FN": "Thalia", "LN": "Moonwhisper", "TI": "Keeper", "FT": "Thalia, |cffff0000Keeper|r of the Moonwell", "RA": "Night Elf",
            "CL": "Priestess", "AG": "Young", "EC": "Silver", "EH": "c0c0ff", "HE": "Tall", "WE": "Slender", "BP": "Darnassus",
            "RE": "Auberdine", "RS": 2, "CH": "8fd3ff", "IC": "inv_misc_gift_02",
            "MI": [{"ID": 3, "VA": "Thal"}, {"NA": "Favourite tea", "VA": "Moonleaf", "IC": "inv_misc_coin_02"}, {"NA": "", "VA": "no label"}],
            "PS": [{"ID": 4, "V2": 15}, {"LT": "Patient", "RT": "Restless", "V2": 3, "LC": {"r": 1, "g": 0, "b": 0}, "LI": "inv_misc_coin_02"},
                   {"ID": 99, "V2": 10}],
        },
        "character": {"RP": 1, "XP": 2, "WU": 2, "CU": "Tending the {col:ff0000}moonwell{/col}", "CO": "Whisper me |Hitem:1|h[anytime]|h"},
        "misc": {"PE": {"1": {"AC": True, "TI": "Circlet", "TX": "Silver, {col:g}old{/col}", "IC": "inv_misc_coin_02"},
                        "2": {"AC": False, "TI": "Hidden glance"}},
                 "ST": {"2": 1, "3": 2, "4": 3, "6": 1, "7": 0}},
        "about": {"TE": 1, "T1": {"TX": "{h1:c}The Keeper{/h1}\n{p:r}Right aligned{/p}\n# A heading\nFirst line\nsecond line\n\n"
                                          "Next paragraph {icon:inv_misc_gift_02:20} and [the site](https://example.com/thalia) "
                                          "and {link*javascript:alert(1)*a trap} <script>alert('x')</script> |TInterface\\Icons\\X:16|t"}},
        "time": 1794000000, "zone": "Darkshore",
    }


def mira_profile():
    return {"characteristics": {"FN": "Mira", "LN": "Ashgrove", "TI": "Apprentice"},
            "character": {"RP": 2, "CU": "Reading in the library"},
            "about": {"TE": 3, "T3": {"PH": {"TX": "Short, ink on her fingers."}, "HI": {"TX": "Raised in Lakeshire."}, "PS": {"TX": ""}}}}


def zoe_profile():
    return {"characteristics": {"FN": "Zoe", "LN": "Farstrider", "TI": "Ranger"}, "character": {"CU": "Only Total RP 3 knows her"},
            "about": {"TE": 2, "T2": [{"TX": "Frame one", "IC": "inv_misc_gift_02"}, {"TX": ""}]}}


def own_trp3(name_key):
    return {"TRP3_Characters": {name_key: {"profileID": "P1"}},
            "TRP3_Profiles": {"P1": {"profileName": "Joan", "player": {
                "characteristics": {"FN": "Joan", "LN": "Ofârc", "PS": [{"ID": 1, "V2": 4}]},
                "character": {"RP": 1}, "misc": {"PE": {"1": {"AC": True, "TI": "Antlers"}}}}}}}


def saved(regional):
    def k(given, family):
        return f"{given} {family}" if regional else f"{given}-CAMWOWUS2Realm10RPPvP"
    gk = "The Moonwell Circle@CAMWOW US2 Realm 10 RP PvP"
    return {"ReliquaryDB": {
        "schema": 2, "meta": {"addon": "1.3.0", "names": "regional" if regional else None},
        "chars": {"Joan-CAMWOW US2 Realm 10 RP PvP": {
            "name": "Joan", "surname": "Ofârc" if regional else None, "realm": "CAMWOW US2 Realm 10 RP PvP", "level": 20,
            "class": "Druid", "classFile": "DRUID", "updated": 1794000100, "guild": "The Moonwell Circle",
            "share": {"guild": True, "friends": False, "public": True}}},
        "guilds": {gk: {"name": "The Moonwell Circle", "realm": "CAMWOW US2 Realm 10 RP PvP", "at": 1794000000,
                        "mine": {"Joan-CAMWOW US2 Realm 10 RP PvP": {"rank": "Officer"}},
                        "members": [{"n": "Joan Ofârc" if regional else "Joan", "me": True},
                                    {"n": "Thalia Moonwhisper" if regional else "Thalia", "on": True},
                                    {"n": "Mira Ashgrove" if regional else "Mira"}]}},
        "peers": {k("Thalia", "Moonwhisper"): {"scopes": {"g": 1794000000}, "got": 1794000000,
                                               "card": {"name": "Thalia Moonwhisper" if regional else "Thalia", "level": 19, "class": "Priest",
                                                        "classFile": "PRIEST", "gear": {}}}},
    }}


def register(regional):
    def k(given, family):
        return f"{given} {family}" if regional else f"{given}-CAMWOWUS2Realm10RPPvP"
    return {"TRP3_Register": {
        "character": {k("Thalia", "Moonwhisper"): {"profileID": "T", "client": "Total RP 3", "clientVersion": "3.5.4", "guild": "The Moonwell Circle"},
                      k("Mira", "Ashgrove"): {"profileID": "M", "client": "Total RP 3", "msp": True},
                      k("Zoe", "Farstrider"): {"profileID": "Z"},
                      k("Empty", "Profile"): {"profileID": "E"}},
        "profiles": {"T": thalia_profile(), "M": mira_profile(), "Z": zoe_profile(), "E": {"characteristics": {}}},
    }}


def write_wtf(root, regional):
    sv = os.path.join(root, "WTF", "Account", "123456789#1", "SavedVariables")
    os.makedirs(sv)
    with open(os.path.join(sv, "Reliquary.lua"), "w") as f:
        f.write(luasv.dumps(saved(regional)))
    with open(os.path.join(sv, "totalRP3_Data.lua"), "w") as f:
        f.write(luasv.dumps(register(regional)))
    with open(os.path.join(sv, "totalRP3.lua"), "w") as f:
        f.write(luasv.dumps(own_trp3("Joan Ofârc" if regional else "Joan-CAMWOWUS2Realm10RPPvP")))
    return os.path.join(root, "WTF", "Account")


def check_markup():
    blocks = roleplay.markup(thalia_profile()["about"]["T1"]["TX"])
    kinds = [(b["k"], b.get("a")) for b in blocks]
    assert kinds == [("h1", "c"), ("p", "r"), ("h1", None), ("p", None), ("p", None)], kinds
    first, second = blocks[3]["r"], blocks[4]["r"]
    assert [r for r in first if "br" in r] and roleplay.runs_text(first) == "First line\nsecond line", first
    icon = next(r for r in second if "i" in r)
    assert icon == {"i": GIFT, "s": 20}, icon
    site = next(r for r in second if r.get("u"))
    assert site == {"t": "the site", "u": "https://example.com/thalia", "c": roleplay.LINK_COLOR}, site
    trap = next(r for r in second if "a trap" in r.get("t", ""))
    assert "u" not in trap and all(r["u"].startswith(("https://", "http://")) for b in blocks for r in b["r"] if "u" in r), \
        "a javascript: address must never become a link"
    plain = roleplay.runs_text(second)
    assert "<script>alert('x')</script>" in plain and "|T" not in plain, plain  # plain text: the page escapes it
    assert not any(isinstance(v, str) and "<" in v for b in blocks for r in b["r"] for k, v in r.items() if k != "t")
    colored = roleplay.parse_runs("a |cff00ff00green|r {col:ff0000}red {col:g}inner{/col} back{/col} |cnGREEN_FONT_COLOR:named|r end ||pipe")
    assert colored == [{"t": "a "}, {"t": "green", "c": "00ff00"}, {"t": " "}, {"t": "red ", "c": "ff0000"}, {"t": "inner", "c": "00ff00"},
                       {"t": " back", "c": "ff0000"}, {"t": " named end |pipe"}], colored


def check_card():
    c = roleplay.card(thalia_profile(), {"client": "Total RP 3", "clientVersion": "3.5.4", "guild": "The Moonwell Circle"})
    assert c["name"] == "Thalia Moonwhisper" and c["title"] == "Keeper" and c["fullTitle"] == "Thalia, Keeper of the Moonwell", c
    assert c["icon"] == GIFT and c["color"] == "8fd3ff" and c["eyeColor"] == "c0c0ff" and c["relationship"] == "Taken"
    assert (c["status"], c["experience"], c["walkup"], c["client"], c["guild"]) == ("ic", "Veteran", True, "Total RP 3 3.5.4", "The Moonwell Circle")
    assert c["misc"] == [{"name": "Nickname", "value": "Thal"}, {"name": "Favourite tea", "value": "Moonleaf", "icon": COIN}], c["misc"]
    assert c["traits"][0] == {"left": "Altruistic", "right": "Selfish", "value": 15, "leftIcon": GIFT, "rightIcon": COIN,
                              "leftColor": roleplay.TRAIT_COLORS[0], "rightColor": roleplay.TRAIT_COLORS[1]}, c["traits"][0]
    assert c["traits"][1]["left"] == "Patient" and c["traits"][1]["leftColor"] == "ff0000" and c["traits"][1]["leftIcon"] == COIN
    assert len(c["traits"]) == 2, "a trait whose preset doesn't exist and has no words of its own"
    assert c["glances"] == [{"title": "Circlet", "icon": COIN, "text": [{"k": "p", "r": [{"t": "Silver, "}, {"t": "old", "c": "00ff00"}]}]}], c["glances"]
    assert c["style"] == [{"name": "Accept character injury", "value": "Yes"}, {"name": "Accept character death", "value": "No"},
                          {"name": "Accept character romance", "value": "With player permission"},
                          {"name": "Guild membership", "value": "IC membership"}], c["style"]
    assert roleplay.runs_text(c["currently"]) == "Tending the moonwell" and roleplay.runs_text(c["ooc"]) == "Whisper me [anytime]"
    assert c["seen"] == 1794000000 and c["seenIn"] == "Darkshore"
    m = roleplay.card(mira_profile())
    assert [s["name"] for s in m["about"]["sections"]] == ["Physical description", "History"] and m["status"] == "ooc"
    z = roleplay.card(zoe_profile())
    assert len(z["about"]["frames"]) == 1 and z["about"]["frames"][0]["icon"] == GIFT
    assert roleplay.card({"characteristics": {"PS": [{"ID": 3.0, "V2": 7.0}]}})["traits"][0]["left"] == "Forgiving"  # numbers read back as 3.0


def check_state(regional):
    work = tempfile.mkdtemp()
    try:
        reliquary.CHOICES = os.path.join(work, "choices.json")
        reliquary.CAPTURES = os.path.join(work, "captures")
        wtf = write_wtf(work, regional)
        own = reliquary.build_state(wtf)
        names = [c["name"] for c in own["roleplay"]]
        assert names == ["Mira Ashgrove", "Thalia Moonwhisper", "Zoe Farstrider"], names  # the empty one left out
        thalia_unit = "Thalia Moonwhisper" if regional else "Thalia-CAMWOWUS2Realm10RPPvP"
        (peer,) = own["peers"]
        assert peer["rp"] == thalia_unit, peer
        members = {m["name"]: m for m in own["guilds"][0]["members"]}
        thalia_row = members["Thalia Moonwhisper" if regional else "Thalia"]
        mira_row = members["Mira Ashgrove" if regional else "Mira"]
        assert thalia_row["shares"] and thalia_row["rp"] == thalia_unit, thalia_row
        assert mira_row["rp"] == ("Mira Ashgrove" if regional else "Mira-CAMWOWUS2Realm10RPPvP") and not mira_row["shares"], mira_row
        joan = own["chars"][0]
        assert joan["rp"]["traits"][0]["left"] == "Chaotic" and joan["rp"]["glances"][0]["title"] == "Antlers", joan.get("rp")
        assert joan.get("surname") == ("Ofârc" if regional else None)
        # The public copy: Joan's own profile, nothing of anyone else's.
        pub = reliquary.build_state(wtf, public=True)
        assert "roleplay" not in pub and "peers" not in pub and "guilds" not in pub
        assert pub["chars"][0]["rp"]["glances"][0]["title"] == "Antlers"
        raw = json.dumps(pub, ensure_ascii=False)
        for secret in ("Keeper", "Moonwhisper", "Ashgrove", "Zoe", "Farstrider", "Moonleaf", "javascript", "Reading in the library"):
            assert secret not in raw, f"{secret!r} from another player's Total RP 3 profile is on the public copy"
        # What the publisher sends: Total RP 3's register never leaves this PC.
        dest = os.path.join(work, "cut")
        publish.cut_saved_files(wtf, dest)
        sent = []
        for base, _, files in os.walk(dest):
            for f in files:
                sent.append(f)
                body = open(os.path.join(base, f), encoding="utf-8").read()
                for secret in ("TRP3_Register", "Moonwhisper", "Ashgrove", "Farstrider", "Moonleaf"):
                    assert secret not in body, f"{secret!r} would leave this PC in {f}"
        assert sorted(sent) == ["Reliquary.lua", "totalRP3.lua"], sent
    finally:
        shutil.rmtree(work)


def main():
    check_markup()
    check_card()
    check_state(regional=True)
    check_state(regional=False)
    print("roleplay ok: every part of a Total RP 3 profile, its markup made safe, matched by full name and by Name-Realm; none on the public copy")


if __name__ == "__main__":
    main()
