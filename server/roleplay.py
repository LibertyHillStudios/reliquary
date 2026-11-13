"""Total RP 3 profiles for the dashboard: everything a roleplay profile holds, as plain data.

Total RP 3 keeps your own profiles in totalRP3.lua (TRP3_Profiles, with TRP3_Characters saying
whose each one is) and every other player's it has fetched in totalRP3_Data.lua (TRP3_Register:
`character` by Total RP 3's name for them, `profiles` by profile id). Each profile has four parts:
characteristics, about, character and misc. What the codes mean, and the English words, come from
Total RP 3 3.5.4 itself (Core/Enums.lua, RegisterCharacteristics.lua, RegisterMisc.lua, ProfileUtil.lua,
Locales/enUS.lua).

Profile text is other players' writing. Total RP 3's markup ({h1}, {p:c}, {col:..}, {icon:..},
{link*..*..}, # headings, [text](url)) and the game's own codes (|c..|r, |T..|t, |H..|h) become
blocks of runs: text, a colour, a game icon by its file id, a line break, a link's text and address.
Nothing here is HTML; the page escapes every character it shows.
"""
import re

ICON_IDS = {}  # icon file name (lower case) -> file id; filled by reliquary.py from data/icons.json

# Total RP 3's eleven personality trait pairs (PSYCHO_PRESETS), with their icons (TRP3_InterfaceIconIDs;
# each lists its first choice and its fallback).
TRAITS = [
    ("Chaotic", "Lawful", ("ability_rogue_wrongfullyaccused", "spell_fire_masterofelements"), ("ability_paladin_sanctifiedwrath", "inv_shield_35")),
    ("Chaste", "Lustful", ("inv_belt_27",), ("spell_shadow_summonsuccubus",)),
    ("Forgiving", "Vindictive", ("inv_rosebouquet01",), ("ability_hunter_snipershot",)),
    ("Altruistic", "Selfish", ("inv_misc_gift_02",), ("inv_misc_coin_02",)),
    ("Truthful", "Deceitful", ("inv_misc_toy_07",), ("ability_rogue_disguise",)),
    ("Gentle", "Brutal", ("inv_valentinescandysack",), ("ability_warrior_trauma", "ability_warrior_bloodfrenzy")),
    ("Superstitious", "Rational", ("spell_holy_holyguidance",), ("inv_gizmo_02",)),
    ("Renegade", "Paragon", ("ability_rogue_honoramongstthieves", "ability_warrior_improveddisciplines"), ("inv_misc_groupneedmore",)),
    ("Cautious", "Impulsive", ("spell_shadow_brainwash",), ("achievement_bg_captureflag_eos", "spell_fire_burningspeed")),
    ("Ascetic", "Bon vivant", ("inv_misc_food_pinenut", "inv_misc_food_02"), ("inv_misc_food_99",)),
    ("Valorous", "Spineless", ("ability_paladin_beaconoflight", "spell_holy_auraoflight"), ("ability_druid_cower",)),
]
TRAIT_MAX = 20                                   # PSYCHO_MAX_VALUE_V2: the value is the left trait's share
TRAIT_DEFAULT = 10                               # PSYCHO_DEFAULT_VALUE_V2
TRAIT_COLORS = ("ffc26b", "6ba6ff")              # PersonalityTraitColorLeft / Right
MISC_NAMES = {2: "House name", 3: "Nickname", 4: "Motto", 5: "Facial features", 6: "Piercings", 7: "Pronouns",
              8: "Guild name", 9: "Guild rank", 10: "Tattoos", 11: "Voice reference"}
RELATIONSHIP = {1: "Single", 2: "Taken", 3: "Married", 4: "Divorced", 5: "Widowed"}
EXPERIENCE = {1: "Newcomer", 2: "Veteran", 3: "Newcomer Guide", 4: "Casual"}
STYLE_FIELDS = [  # RegisterMisc.lua STYLE_FIELDS, in its order
    ("2", "Accept character injury"), ("3", "Accept character death"), ("4", "Accept character romance"),
    ("7", "Accept criminal activity"), ("8", "Accept loss of control"), ("6", "Guild membership"),
]
STYLE_VALUES = {1: "Yes", 2: "No", 3: "With player permission"}
GUILD_STYLE = {1: "IC membership", 2: "OOC membership"}
ABOUT_SECTIONS = [("PH", "Physical description"), ("PS", "Personality"), ("HI", "History")]  # template 3
SHORT_COLORS = {"r": "ff0000", "g": "00ff00", "b": "0000ff", "y": "ffff00", "p": "ff00ff", "c": "00ffff",
                "w": "ffffff", "0": "000000", "o": "ffaa00"}
LINK_COLOR = "00ff00"  # Total RP 3 shows links green unless a colour tag comes first

MAX_TEXT = 40000  # characters of one text taken from a profile


def text(v, limit=400):
    """A short field: the game's codes and Total RP 3's tags out, one line."""
    if not isinstance(v, str):
        return None
    v = runs_text(parse_runs(v))
    v = re.sub(r"\s+", " ", v).strip()
    return v[:limit] or None


def icon_id(name):
    """A game icon's file id from its name, or a file id itself."""
    if isinstance(name, (int, float)) and name > 0:
        return int(name)
    if isinstance(name, str):
        name = name.strip()
        if name.isdigit():
            return int(name)
        return ICON_IDS.get(name.lower().replace("interface\\icons\\", "").replace("interface/icons/", ""))
    return None


def first_icon(names):
    return next((i for i in (icon_id(n) for n in names) if i), None)


def hex_color(v):
    if isinstance(v, str) and re.fullmatch(r"#?[0-9a-fA-F]{6}", v.strip()):
        return v.strip().lstrip("#").lower()
    if isinstance(v, dict) and all(isinstance(v.get(k), (int, float)) for k in "rgb"):
        return "".join(f"{max(0, min(255, round(v[k] * 255))):02x}" for k in "rgb")
    return None


def whole(v):
    """A whole number from the saved file (it may come back as 3.0), else None."""
    if isinstance(v, bool):
        return None
    if isinstance(v, int):
        return v
    if isinstance(v, float) and v.is_integer():
        return int(v)
    return None


def as_list(v):
    if isinstance(v, list):
        return v
    if isinstance(v, dict):
        return [v[k] for k in sorted(v, key=lambda k: (not str(k).isdigit(), int(k) if str(k).isdigit() else 0, str(k)))]
    return []


# ---------------------------------------------------------------------------
# Markup: text with Total RP 3's tags and the game's codes, as blocks of runs
# ---------------------------------------------------------------------------
# Inline tokens, in the order they are looked for.
_INLINE = re.compile(
    r"\|c([0-9a-fA-F]{8})"                       # game colour
    r"|\|cn[A-Za-z_]+:"                           # a named game colour: its colour is the game's own
    r"|\|r"                                       # end of a game colour
    r"|\|T[^|]*\|t|\|A[^|]*\|a"                   # textures and atlases: nothing a page can show
    r"|\|H[^|]*\|h(.*?)\|h"                       # a game link: its text
    r"|\|n"                                       # a game line break
    r"|\|\|"                                      # a literal |
    r"|\{col:([0-9a-fA-F]{6}|[rgbypcw0o])\}"      # Total RP 3 colour
    r"|\{/col\}"
    r"|\{icon:([^:}]+):(\d+)\}"                   # Total RP 3 icon
    r"|\{img:[^}]*\}"                             # Total RP 3 image: a game texture, nothing a page can show
    r"|\{link\*([^*}]*)\*([^}]*)\}"               # Total RP 3 link: address, then text
    r"|\{twitter\*([^*}]*)\*([^}]*)\}"
    r"|!\[([^\]\\]+)\]\((\d+)\)"                  # markdown icon: ![name](size)
    r"|\[([^\]]+)\]\(([^)\s]+)\)"                 # markdown link: [text](address)
    r"|\n",
    re.S,
)


def _link(url):
    url = (url or "").strip()
    return url if re.match(r"^https?://[^\s<>\"]+$", url) else None


def parse_runs(s):
    """One stretch of text as runs: {"t": text, "c": colour}, {"i": icon id, "s": size}, {"br": 1},
    {"t": text, "u": address}."""
    out, color, pos = [], None, 0
    stack = []

    def add_text(t):
        if t:
            if out and "t" in out[-1] and "u" not in out[-1] and out[-1].get("c") == color:
                out[-1]["t"] += t
            else:
                out.append({"t": t, "c": color} if color else {"t": t})

    s = s.replace("\r\n", "\n").replace("\r", "\n")
    for m in _INLINE.finditer(s):
        add_text(s[pos:m.start()])
        pos = m.end()
        tok = m.group(0)
        if tok.startswith("|cn"):
            stack.append(color)
        elif tok.startswith("|c") and m.group(1):
            stack.append(color)
            color = m.group(1)[2:].lower()
        elif tok == "|r" or tok == "{/col}":
            color = stack.pop() if stack else None
        elif tok.startswith("|H"):
            add_text(m.group(2))
        elif tok in ("|n", "\n"):
            out.append({"br": 1})
        elif tok == "||":
            add_text("|")
        elif tok.startswith("{col:"):
            stack.append(color)
            c = m.group(3)
            color = SHORT_COLORS.get(c) or c.lower()
        elif tok.startswith("{icon:"):
            i = icon_id(m.group(4))
            if i:
                out.append({"i": i, "s": max(8, min(48, int(m.group(5))))})
        elif tok.startswith("{link*") or tok.startswith("{twitter*"):
            url, label = (m.group(6), m.group(7)) if tok.startswith("{link*") else ("https://twitter.com/" + (m.group(8) or "").lstrip("@"), m.group(9))
            label = (label or url or "").strip()
            out.append({"t": label, "u": _link(url), "c": color or LINK_COLOR} if _link(url) else {"t": label})
        elif tok.startswith("!["):
            i = icon_id(m.group(10))
            if i:
                out.append({"i": i, "s": max(8, min(48, int(m.group(11))))})
        elif tok.startswith("["):
            label, url = m.group(12), m.group(13)
            out.append({"t": label, "u": _link(url), "c": color or LINK_COLOR} if _link(url) else {"t": label})
        # images, textures and atlases: nothing
    add_text(s[pos:])
    for r in out:
        if "c" in r and r["c"] is None:
            del r["c"]
        if "u" in r and r["u"] is None:
            del r["u"]
    return out


def runs_text(runs):
    return "".join(r.get("t", "") if "br" not in r else "\n" for r in runs)


_BLOCK = re.compile(r"\{(h[1-3])(?::([cr]))?\}(.*?)\{/h[1-3]\}|\{p(?::([cr]))?\}(.*?)\{/p\}", re.S)


def markup(s):
    """Text as blocks: {"k": "h1".."h3" or "p", "a": "c" or "r" when centred or right, "r": runs}."""
    if not isinstance(s, str) or not s.strip():
        return []
    s = s[:MAX_TEXT].replace("\r\n", "\n").replace("\r", "\n")
    blocks = []

    def free(t):
        # Text outside tags: "#" lines are headings, blank lines end a paragraph.
        para = []

        def end():
            while para and para[-1] == "":
                para.pop()
            if para:
                runs = parse_runs("\n".join(para))
                if any(r.get("t", "").strip() or "i" in r for r in runs):
                    blocks.append({"k": "p", "r": _trim(runs)})
            para.clear()
        for line in t.split("\n"):
            h = re.match(r"^(#{1,3})\s*(.+?)\s*#*$", line)
            if h:
                end()
                blocks.append({"k": f"h{len(h.group(1))}", "r": parse_runs(h.group(2))})
            elif not line.strip():
                end()
            else:
                para.append(line)
        end()

    pos = 0
    for m in _BLOCK.finditer(s):
        free(s[pos:m.start()])
        pos = m.end()
        if m.group(1):
            kind, align, body = m.group(1), m.group(2), m.group(3)
        else:
            kind, align, body = "p", m.group(4), m.group(5)
        runs = _trim(parse_runs(body.strip("\n")))
        if any(r.get("t", "").strip() or "i" in r for r in runs):
            block = {"k": kind, "r": runs}
            if align:
                block["a"] = align
            blocks.append(block)
    free(s[pos:])
    return blocks


def _trim(runs):
    while runs and "br" in runs[0]:
        runs = runs[1:]
    while runs and "br" in runs[-1]:
        runs = runs[:-1]
    return runs


# ---------------------------------------------------------------------------
# A profile
# ---------------------------------------------------------------------------
def card(profile, character=None):
    """Everything in one Total RP 3 profile ({characteristics, about, character, misc}), and what
    Total RP 3 noted about the character it came from (client, guild, race), as plain data."""
    if not isinstance(profile, dict):
        return None
    ch = profile.get("characteristics") if isinstance(profile.get("characteristics"), dict) else {}
    cr = profile.get("character") if isinstance(profile.get("character"), dict) else {}
    ab = profile.get("about") if isinstance(profile.get("about"), dict) else {}
    misc = profile.get("misc") if isinstance(profile.get("misc"), dict) else {}
    info = character if isinstance(character, dict) else {}
    out = {
        "first": text(ch.get("FN"), 80), "last": text(ch.get("LN"), 80), "title": text(ch.get("TI"), 120),
        "fullTitle": text(ch.get("FT"), 240), "icon": icon_id(ch.get("IC")), "color": hex_color(ch.get("CH")),
        "race": text(ch.get("RA"), 80) or text(info.get("race"), 80), "class": text(ch.get("CL"), 80) or text(info.get("class"), 80),
        "age": text(ch.get("AG"), 80), "eyes": text(ch.get("EC"), 80), "eyeColor": hex_color(ch.get("EH")),
        "height": text(ch.get("HE"), 80), "build": text(ch.get("WE"), 80), "birthplace": text(ch.get("BP"), 120),
        "residence": text(ch.get("RE"), 120), "relationship": RELATIONSHIP.get(whole(ch.get("RS"))),
        "guild": text(info.get("guild"), 80), "faction": text(info.get("faction"), 20),
        "currently": parse_runs(cr["CU"][:MAX_TEXT]) if isinstance(cr.get("CU"), str) and cr["CU"].strip() else None,
        "ooc": parse_runs(cr["CO"][:MAX_TEXT]) if isinstance(cr.get("CO"), str) and cr["CO"].strip() else None,
        "status": {1: "ic", 2: "ooc"}.get(whole(cr.get("RP"))),
        "experience": EXPERIENCE.get(whole(cr.get("XP")) if cr.get("XP") is not None else whole(info.get("roleplayExperience"))),
        "walkup": True if whole(cr.get("WU")) == 2 else None,
        "client": " ".join(x for x in (text(info.get("client"), 40), text(info.get("clientVersion"), 20)) if x) or None,
        "msp": True if info.get("msp") or profile.get("msp") else None,
        "seen": profile.get("time") if isinstance(profile.get("time"), (int, float)) else None,
        "seenIn": text(profile.get("zone"), 80),
    }
    name = " ".join(x for x in (out["first"], out["last"]) if x)
    out["name"] = name or None
    misc_info = []
    for m in as_list(ch.get("MI")):
        if not isinstance(m, dict):
            continue
        label = text(m.get("NA"), 60) or MISC_NAMES.get(whole(m.get("ID")))
        value = text(m.get("VA"), 400)
        if label and value:
            misc_info.append({k: v for k, v in {"name": label, "value": value, "icon": icon_id(m.get("IC"))}.items() if v})
    out["misc"] = misc_info or None
    traits = []
    for t in as_list(ch.get("PS")):
        if not isinstance(t, dict):
            continue
        pid = whole(t.get("ID"))
        preset = TRAITS[pid - 1] if pid and 1 <= pid <= len(TRAITS) else None
        left = (preset[0] if preset else None) or text(t.get("LT"), 60)
        right = (preset[1] if preset else None) or text(t.get("RT"), 60)
        if not left or not right:
            continue
        value = t.get("V2")
        if not isinstance(value, (int, float)):
            value = round(t["VA"] * TRAIT_MAX / 6) if isinstance(t.get("VA"), (int, float)) else TRAIT_DEFAULT  # profiles from before V2
        traits.append({
            "left": left, "right": right, "value": max(0, min(TRAIT_MAX, int(value))),
            "leftIcon": first_icon(preset[2]) if preset else icon_id(t.get("LI")),
            "rightIcon": first_icon(preset[3]) if preset else icon_id(t.get("RI")),
            "leftColor": hex_color(t.get("LC")) or TRAIT_COLORS[0], "rightColor": hex_color(t.get("RC")) or TRAIT_COLORS[1],
        })
    out["traits"] = traits or None
    glances = []
    pe = misc.get("PE") if isinstance(misc.get("PE"), dict) else {}
    for i in range(1, 6):
        g = pe.get(str(i)) or pe.get(i)
        if isinstance(g, dict) and g.get("AC") and (text(g.get("TI")) or text(g.get("TX"))):
            glances.append({k: v for k, v in {"title": text(g.get("TI"), 120), "icon": icon_id(g.get("IC")), "text": markup(g.get("TX"))}.items() if v})
    out["glances"] = glances or None
    style = []
    st = misc.get("ST") if isinstance(misc.get("ST"), dict) else {}
    for key, label in STYLE_FIELDS:
        v = whole(st.get(key, st.get(int(key))))
        value = (GUILD_STYLE if key == "6" else STYLE_VALUES).get(v)
        if value:
            style.append({"name": label, "value": value})
    out["style"] = style or None
    template = whole(ab.get("TE"))
    about = None
    if template == 2:
        frames = []
        for f in as_list(ab.get("T2")):
            if isinstance(f, dict) and markup(f.get("TX")):
                frames.append({k: v for k, v in {"icon": icon_id(f.get("IC")), "text": markup(f.get("TX"))}.items() if v})
        about = {"frames": frames} if frames else None
    elif template == 3:
        t3 = ab.get("T3") if isinstance(ab.get("T3"), dict) else {}
        sections = []
        for key, label in ABOUT_SECTIONS:
            part = t3.get(key) if isinstance(t3.get(key), dict) else {}
            if markup(part.get("TX")):
                sections.append({k: v for k, v in {"name": label, "icon": icon_id(part.get("IC")), "text": markup(part.get("TX"))}.items() if v})
        about = {"sections": sections} if sections else None
    else:
        t1 = ab.get("T1") if isinstance(ab.get("T1"), dict) else {}
        blocks = markup(t1.get("TX"))
        about = {"text": blocks} if blocks else None
    out["about"] = about
    out = {k: v for k, v in out.items() if v is not None}
    return out if len(out) > 0 else None


def register_cards(register):
    """Every profile in a TRP3_Register, by Total RP 3's name for its character."""
    if not isinstance(register, dict):
        return {}
    chars = register.get("character") if isinstance(register.get("character"), dict) else {}
    profiles = register.get("profiles") if isinstance(register.get("profiles"), dict) else {}
    out = {}
    for unit, info in chars.items():
        if not isinstance(unit, str) or not isinstance(info, dict):
            continue
        prof = profiles.get(info.get("profileID"))
        c = card(prof, info) if isinstance(prof, dict) else None
        if c and (c.get("name") or c.get("about") or c.get("currently")):
            c["unit"] = unit
            out[unit] = c
    return out
