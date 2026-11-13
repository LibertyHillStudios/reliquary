#!/usr/bin/env bash
# Rebuilds data/sample/Reliquary.lua, the sample character the page shows at ?demo=1: Joan's own
# recorded session from the simulated client (tests/harness.lua, full) with her guild, its bank and
# what other players share with her from the simulated world (tests/share.lua).
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)
trap 'rm -rf "${out:?}"' EXIT
lua5.1 tests/harness.lua addon/Reliquary/Reliquary.toc "$out/own.lua" full 2>/dev/null
lua5.1 tests/share.lua addon/Reliquary/Reliquary.toc "$out/shared.lua" >/dev/null
python3 - "$out/own.lua" "$out/shared.lua" data/sample/Reliquary.lua <<'PY'
import os
import sys
sys.path.insert(0, "server")
import luasv
own, shared, dest = sys.argv[1:]
db = luasv.load(own)["ReliquaryDB"]
extra = luasv.load(shared)["ReliquaryShared"]
db["guilds"], db["peers"] = extra["guilds"], extra["peers"]
# The tooltips of the guild bank's items and of what others share, kept beside Joan's own.
for iid, rec in (extra.get("items") or {}).items():
    db["items"].setdefault(iid, rec)
# Her auction scans (the house's real items, not the simulated rest of it) and her notes of where
# items come from; and the days of prices the dashboard's history on the PC would have kept.
import json
real = lambda items: {k: v for k, v in (items or {}).items() if int(k) < 300000}
db["prices"] = {key: dict(h, items=real(h.get("items"))) for key, h in (extra.get("prices") or {}).items()}
db["sources"] = extra.get("sources") or {}
with open(os.path.join(os.path.dirname(dest), "prices-history.json"), "w") as f:
    json.dump(extra.get("history") or {"houses": {}}, f, separators=(",", ":"), sort_keys=True)
    f.write("\n")
joan = db["chars"]["Joan Ofârc-CAMWOWUS2Realm11RP"]
(gk, guild), = db["guilds"].items()
# The two sessions are one character: her guild and roster line agree with her own record.
joan["guild"], joan["guildRank"] = guild["name"], "Officer"
# Everything to the guild but her bank; to everyone her gear, talents, crafts, sheet, time played
# and reputation.
joan["share"] = {"guild": True, "friends": False, "public": True, "at": joan["updated"], "parts": {
    "gear": "gfp", "talents": "gfp", "profs": "gfp", "stats": "gfp", "gold": "g", "place": "g", "played": "gp",
    "reps": "gp", "quests": "g", "bags": "g", "bank": ""}}
guild["mine"] = {joan["key"]: {"rank": "Officer", "ro": 2, "at": joan["updated"]}}
guild["bank"]["limits"] = {joan["key"]: next(iter(guild["bank"]["limits"].values()))} if guild["bank"].get("limits") else {}
guild["view"] = {joan["key"]: next(iter(guild["view"].values()))}
for m in guild["members"]:
    if m.get("me"):
        m["lv"] = joan["level"]
with open(dest, "w") as f:
    f.write("\n" + luasv.dumps({"ReliquaryDB": db}))

# What Total RP 3 holds of the players around her (totalRP3_Data.lua): those who share, two
# guildmates and two players she has met. Made-up sample players; Joan's own profile is hers to
# write in the game, so the sample has none.
seen = joan["updated"] - 3600
def tp(fn, ln, ti, ra, cl, rp, extra=None, about=None, info=None):
    prof = {"characteristics": {"FN": fn, "LN": ln, "TI": ti, "RA": ra, "CL": cl, "v": 1},
            "character": {"RP": rp, "XP": 2, "v": 1}, "misc": {"v": 1}, "about": about or {"TE": 1, "v": 1}, "time": seen, "zone": "Darkshore"}
    for part, fields in (extra or {}).items():
        prof[part].update(fields)
    return prof, dict({"profileID": f"{fn}{ln}", "client": "Total RP 3", "clientVersion": "3.5.4"}, **(info or {}))
profiles = {
    "Thalia Moonwhisper": tp("Thalia", "Moonwhisper", "Keeper of the Moonwell", "Kaldorei", "Priestess", 1, {
        "characteristics": {"FT": "Priestess of the Moonwell Circle", "AG": "About four hundred", "EC": "Silver", "EH": "c8d6ff",
                            "HE": "Tall", "WE": "Slender", "BP": "Darnassus", "RE": "Auberdine", "RS": 1, "IC": "achievement_character_nightelf_female",
                            "CH": "e6f0ff", "MI": [{"ID": 3, "VA": "Thal"}, {"ID": 4, "VA": "Still water keeps the moon."}],
                            "PS": [{"ID": 6, "V2": 16}, {"ID": 5, "V2": 15}, {"ID": 9, "V2": 13}]},
        "character": {"CU": "At the moonwell in Auberdine most evenings, cleaning the stones.", "CO": "Happy to roleplay. Whisper me first if it's a long scene.", "WU": 2},
        "misc": {"PE": {"1": {"AC": True, "TI": "Moonsilver circlet", "TX": "A thin circlet of moonsilver, polished smooth.", "IC": "inv_jewelry_necklace_07"},
                        "2": {"AC": True, "TI": "Wet hems", "TX": "The bottom of her robe is always damp from the moonwell.", "IC": "inv_potion_01"}},
                 "ST": {"2": 1, "3": 3, "4": 2, "6": 1}},
    }, {"TE": 3, "T3": {"PH": {"TX": "Tall even for a kaldorei, with silver hair in a long braid.", "IC": "ability_druid_catform"},
                         "PS": {"TX": "Patient and quiet. Slow to judge, quick to help."},
                         "HI": {"TX": "Raised in Darnassus. She has tended the moonwell in Auberdine since the town was rebuilt."}}, "v": 1},
        {"guild": "The Moonwell Circle", "race": "Night Elf", "class": "Priest"}),
    "Eluned Dawnstride": tp("Eluned", "Dawnstride", "Ranger", "Kaldorei", "Hunter", 1, {
        "characteristics": {"IC": "inv_weapon_bow_07", "AG": "Young", "HE": "Average", "PS": [{"ID": 11, "V2": 17}, {"ID": 9, "V2": 7}]},
        "character": {"CU": "Tracking the shore for the Sentinels.", "XP": 4},
        "misc": {"PE": {"1": {"AC": True, "TI": "Bone bow", "TX": "Her bow is carved from a single antler.", "IC": "inv_misc_bone_01"}}},
    }, {"TE": 1, "T1": {"TX": "{h2}Eluned{/h2}\nShe joined the Sentinels young and has walked the Darkshore coast ever since.\n\n"
                                "Ask her about the {col:8fd3ff}Twilight's Run{/col} and she will talk for an hour."}, "v": 1}),
    "Brannoc Stonebrow": tp("Brannoc", "Stonebrow", "Shieldbreaker", "Dwarf", "Warrior", 2, {
        "characteristics": {"IC": "achievement_character_dwarf_male", "AG": "Middle-aged, for a dwarf", "WE": "Barrel-chested"},
        "character": {"CO": "Mostly questing, but always up for a pint in character."},
    }, {"TE": 1, "T1": {"TX": "A mountain dwarf from Ironforge with a broken shield he refuses to replace."}, "v": 1}),
    "Faelwen Duskleaf": tp("Faelwen", "Duskleaf", "Warden of the Glade", "Kaldorei", "Druid", 1, {
        "characteristics": {"IC": "achievement_character_nightelf_male", "RE": "Darkshore"},
        "character": {"CU": "Keeping watch over Auberdine's shore."},
    }, None, {"guild": "The Moonwell Circle"}),
    "Corvane Blackthorn": tp("Corvane", "Blackthorn", "Quartermaster", "Human", "Warrior", 2, {
        "characteristics": {"IC": "inv_misc_key_03"}, "character": {"CO": "Ask me for anything in the guild bank."},
    }, None, {"guild": "The Moonwell Circle"}),
    "Vessa Thornbrook": tp("Vessa", "Thornbrook", "Sister of the Silver Hand", "Human", "Paladin", 1, {
        "characteristics": {"IC": "spell_holy_holybolt", "BP": "Lakeshire"}, "character": {"CU": "Escorting pilgrims to Auberdine."},
    }),
    "Garrick Holloway": tp("Garrick", "Holloway", "Fence", "Human", "Rogue", 2, {"characteristics": {"IC": "inv_misc_coin_01"}}),
}
register = {"character": {k: v[1] for k, v in profiles.items()}, "profiles": {v[1]["profileID"]: v[0] for v in profiles.values()}}
with open(os.path.join(os.path.dirname(dest), "totalRP3_Data.lua"), "w") as f:
    f.write("\n" + luasv.dumps({"TRP3_Register": register}))
print(f"sample written: {len(db['chars'])} character, guild of {len(guild['members'])}, {len(db['peers'])} shared reliquaries, {len(profiles)} roleplay profiles")
PY
