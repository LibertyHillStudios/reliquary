#!/usr/bin/env python3
"""Rebuilds tests/widget_api.lua: every method each kind of game widget has on WoW: Forever, read
from Blizzard's own API documentation for the build (the `forever` branch of
github.com/Gethe/wow-ui-source, folder Blizzard_APIDocumentationGenerated). The test client
(tests/wowui.lua) refuses any other method, so a misspelled or missing one fails the tests
instead of the game.

    python3 tools/build_widget_api.py <wow-ui-source checkout>
"""
import glob
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "tests", "widget_api.lua")

# Each widget type and the documented groups of methods it has, as the game builds them up:
# objects, then regions that can be placed, then frames, buttons and so on.
TYPES = {
    "Texture": ["Object", "FrameScriptObject", "ScriptRegion", "ScriptRegionResizing", "Region", "TextureBase", "Texture"],
    "FontString": ["Object", "FrameScriptObject", "ScriptRegion", "ScriptRegionResizing", "Region", "FontString"],
    "Frame": ["Object", "FrameScriptObject", "ScriptRegion", "ScriptRegionResizing", "Frame"],
    "Button": ["Object", "FrameScriptObject", "ScriptRegion", "ScriptRegionResizing", "Frame", "Button"],
    "CheckButton": ["Object", "FrameScriptObject", "ScriptRegion", "ScriptRegionResizing", "Frame", "Button", "Checkbox"],
    "EditBox": ["Object", "FrameScriptObject", "ScriptRegion", "ScriptRegionResizing", "Frame", "EditBox"],
    "StatusBar": ["Object", "FrameScriptObject", "ScriptRegion", "ScriptRegionResizing", "Frame", "StatusBar"],
    "Line": ["Object", "FrameScriptObject", "ScriptRegion", "Region", "TextureBase", "Line"],
    "MaskTexture": ["Object", "FrameScriptObject", "ScriptRegion", "ScriptRegionResizing", "Region", "TextureBase", "MaskTexture"],
    "Font": ["Object", "Font"],
    "PlayerModel": ["Object", "FrameScriptObject", "ScriptRegion", "ScriptRegionResizing", "Frame", "Model", "CharacterModelBase"],
}


def main(source):
    docs = os.path.join(source, "Interface", "AddOns", "Blizzard_APIDocumentationGenerated")
    groups = {}
    # SimpleXAPI documents the base kinds; FrameAPIX the frame kinds built on them (a player model).
    for path in glob.glob(os.path.join(docs, "Simple*APIDocumentation.lua")) + glob.glob(os.path.join(docs, "FrameAPI*Documentation.lua")):
        text = open(path, encoding="utf-8").read()
        m = re.search(r'Name = "(?:Simple(\w+)API|FrameAPI(\w+))",\s*\n\s*Type = "ScriptObject"', text)
        if m:
            groups[m.group(1) or m.group(2)] = set(re.findall(r'Name = "(\w+)",\s*\n\s*Type = "Function"', text))
    version = open(os.path.join(source, "version.txt")).read().strip() if os.path.exists(os.path.join(source, "version.txt")) else "?"
    lines = [f"-- Widget methods on WoW: Forever {version}, from Blizzard_APIDocumentationGenerated.",
             "-- Made by tools/build_widget_api.py; do not edit by hand.", "return {"]
    for kind, parts in TYPES.items():
        missing = [p for p in parts if p not in groups]
        if missing:
            sys.exit(f"no documentation for {', '.join(missing)}")
        names = sorted(set().union(*(groups[p] for p in parts)))
        lines.append(f"    {kind} = {{")
        for i in range(0, len(names), 6):
            lines.append("        " + " ".join(f'"{n}",' for n in names[i:i + 6]))
        lines.append("    },")
    lines.append("}")
    with open(OUT, "w") as f:
        f.write("\n".join(lines) + "\n")
    print(f"wrote {OUT}: " + ", ".join(f"{k} {len(set().union(*(groups[p] for p in v)))}" for k, v in TYPES.items()))


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
