"""The character-screen capture tool, on synthetic pictures: recognising the screen, the crop,
covering windows, which window counts, and filing each look once.

    python3 tests/test_select.py
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import importlib.util  # noqa: E402

spec = importlib.util.spec_from_file_location("select_capture", os.path.join(ROOT, "tools", "select-capture.py"))
sc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sc)


def magick(*args):
    subprocess.run(["magick", *args], check=True)


def main():
    work = tempfile.mkdtemp()
    try:
        # A quarter-size window picture (952x250) with the Enter World button where the game puts it.
        W, H = 952, 250
        aw, ah = round(sc.ANCHOR["w"] * H), round(sc.ANCHOR["h"] * H)
        ax, ay = round(sc.ANCHOR["cx"] * W - aw / 2), round(sc.ANCHOR["top"] * H)
        screen = os.path.join(work, "select.png")
        magick("-size", f"{W}x{H}", "gradient:#304050-#708060", "(", sc.ANCHOR_REF, "-resize", f"{aw}x{ah}!", ")",
               "-geometry", f"+{ax}+{ay}", "-composite", screen)
        # A near miss: the same picture with something else in the button's place (it mirrored),
        # scoring about like the real in-world frames did (0.16 and up).
        world = os.path.join(work, "world.png")
        magick("-size", f"{W}x{H}", "gradient:#304050-#708060", "(", sc.ANCHOR_REF, "-flop", "-flip", "-resize", f"{aw}x{ah}!", ")",
               "-geometry", f"+{ax}+{ay}", "-composite", world)
        s_screen, s_world = sc.anchor_score(screen, work), sc.anchor_score(world, work)
        assert s_screen < sc.ANCHOR_MAX < s_world, (s_screen, s_world)
        assert s_world < 0.4, s_world  # a near miss, not an easy one

        # Her crop on the capture it was measured on.
        assert sc.crop_rect(3810, 1001) == (500, 800, 1705, 60), sc.crop_rect(3810, 1001)

        # Which window counts, and whether something is over her.
        game = {"title": "World of Warcraft", "address": "0x1", "at": [12, 51], "size": [3048, 801],
                "workspace": {"id": 23}, "floating": False, "hidden": False}
        bnet = dict(game, title="Battle.net", address="0x2")  # tiled under the game: never "over" her
        files = {"title": "Recent", "address": "0x3", "at": [0, 0], "size": [700, 900], "workspace": {"id": 23}, "floating": True}
        over = dict(files, title="Notes", address="0x4", at=[1400, 300], size=[400, 300])
        elsewhere = dict(over, workspace={"id": 5})
        monitors = [{"activeWorkspace": {"id": 23}}, {"activeWorkspace": {"id": 5}}]
        assert sc.game_window([bnet, game], monitors) is game
        assert sc.game_window([dict(game, workspace={"id": 9})], monitors) is None  # not on screen
        assert sc.covered(game, [game, bnet, files]) is None  # beside her, like the file manager on 2026-11-07
        assert sc.covered(game, [game, over]) == "Notes"
        assert sc.covered(game, [game, elsewhere]) is None

        # Who she is and filing each look once.
        gamedir = os.path.join(work, "game")
        sv = os.path.join(gamedir, "WTF", "Account", "A", "SavedVariables")
        os.makedirs(sv)
        shutil.copy(os.path.join(ROOT, "data", "sample", "Reliquary.lua"), sv)
        who = sc.last_played(gamedir)
        assert who["key"] == "Joan Ofârc-CAMWOWUS2Realm11RP" and who["was"] == [] and who["level"] == 12 and who["look"].startswith("12:"), who
        full = os.path.join(work, "full.png")
        magick("-size", "3810x1001", "gradient:#203040-#c0a060", full)
        folder = os.path.join(work, "captures")
        now = time.time()
        assert sc.is_new_look(sc.load_index(folder), who, now)
        name = sc.file_capture(full, who, folder, now)
        out = subprocess.run(["magick", "identify", "-format", "%wx%h", os.path.join(folder, name)], capture_output=True, text=True).stdout
        assert out == "500x800", out
        index = sc.load_index(folder)
        assert index[name]["key"] == who["key"] and index[name]["look"] == who["look"]
        assert not sc.is_new_look(index, who, now + 60), "same look filed twice"
        assert sc.is_new_look(index, dict(who, look="13:1,2"), now + 60), "a level or gear change not filed"
        assert sc.is_new_look(index, who, now + sc.REFRESH + 1), "weekly capture not filed"
        # A look filed under the key her record had before the addon moved it to her full name is
        # hers: the saved record names that key, and the same look isn't filed again.
        old = "Joan-CAMWOWUS2Realm11RP"
        data = sc.luasv.load(os.path.join(sv, "Reliquary.lua"))
        data["ReliquaryDB"]["chars"][who["key"]]["was"] = [old]
        with open(os.path.join(sv, "Reliquary.lua"), "w", encoding="utf-8") as f:
            f.write(sc.luasv.dumps(data))
        moved = sc.last_played(gamedir)
        assert moved == dict(who, was=[old]), moved
        filed_before = {"select-old.png": dict(index[name], key=old)}
        assert sc.is_new_look(filed_before, who, now + 60), "a look under another character's key counted as hers"
        assert not sc.is_new_look(filed_before, moved, now + 60), "a look filed under her old key filed again"
        print("select capture ok: screen recognised, crop, windows, one capture per look")
    finally:
        shutil.rmtree(work)


if __name__ == "__main__":
    main()
