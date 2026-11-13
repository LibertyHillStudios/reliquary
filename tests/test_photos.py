"""Photos end to end on the server side: screenshots on disk, the addon's notes, the match
between them, the portrait, the timeline and the web copies.

    python3 tests/test_photos.py <harness output for the "full" scenario>
"""
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "server"))
import luasv  # noqa: E402
import reliquary  # noqa: E402
import timeline  # noqa: E402


def stamp(t):
    return time.strftime("%m%d%y_%H%M%S", time.localtime(t))


def picture(path, w, h):
    subprocess.run(["magick", "-size", f"{w}x{h}", "gradient:#203040-#c0a060", path], check=True)


def main(saved):
    work = tempfile.mkdtemp()
    try:
        reliquary.SHOT_CACHE = os.path.join(work, "cache")
        reliquary.CHOICES = os.path.join(work, "state", "choices.json")
        reliquary.CAPTURES = os.path.join(work, "captures")
        wtf = os.path.join(work, "WTF", "Account")
        os.makedirs(os.path.join(wtf, "TEST", "SavedVariables"))
        shutil.copy(saved, os.path.join(wtf, "TEST", "SavedVariables", "Reliquary.lua"))
        shots = os.path.join(work, "Screenshots")
        os.makedirs(shots)

        notes = luasv.load(saved)["ReliquaryDB"]["chars"]["Joan Ofârc-CAMWOWUS2Realm11RP"]["photos"]
        kinds = [n["kind"] for n in notes]
        assert kinds == ["photo", "screenshot", "levelup", "place", "portrait", "place", "place", "place", "portrait", "portrait", "photo"], kinds
        newest_portrait = max(i for i, k in enumerate(kinds) if k == "portrait")
        # The game names a file a moment before the addon's note: one second earlier here.
        files = []
        for i, n in enumerate(notes):
            t = reliquary.stamp_time(n["stamp"]) - 1
            name = f"WoWScrnShot_{stamp(t)}.{'png' if i == 1 else 'jpg'}"
            picture(os.path.join(shots, name), 3810, 1001)
            files.append(name)
        stray = f"WoWScrnShot_{stamp(time.time())}.jpg"  # taken after the last save: no note yet
        picture(os.path.join(shots, stray), 1920, 1080)
        open(os.path.join(shots, "notes.txt"), "w").close()
        # A client that names screenshots differently: matched by when the file was written.
        odd = "Joan at the shrine 2.png"
        picture(os.path.join(shots, odd), 1600, 900)
        t_odd = reliquary.stamp_time(notes[-1]["stamp"]) + 1
        os.utime(os.path.join(shots, odd), (t_odd, t_odd))
        os.remove(os.path.join(shots, files[-1]))
        files[-1] = odd

        assert reliquary.image_size(os.path.join(shots, files[0])) == (3810, 1001)
        assert reliquary.image_size(os.path.join(shots, files[1])) == (3810, 1001)

        state = reliquary.build_state(wtf, shots_dir=shots)
        joan = state["chars"][0]
        photos = {p["file"]: p for p in joan["photos"]}
        assert len(photos) == len(notes) + 1, list(photos)
        assert [p["file"] for p in joan["photos"]][0] == stray, "newest first"
        assert photos[stray].get("guess") and "kind" not in photos[stray]
        assert photos[files[0]]["kind"] == "photo" and photos[files[0]]["sub"] == "Thendal Grove"
        assert photos[files[1]]["form"] == "Bear Form"
        assert photos[files[2]]["kind"] == "levelup" and photos[files[3]]["kind"] == "place"
        assert "_photos" not in joan
        # Portrait: her newest framed portrait, never a Print Screen or a guessed stray.
        assert joan["portrait"] == {"file": files[newest_portrait], "chosen": False}, joan["portrait"]
        # Without portraits, a level-up; never one taken in a shapeshift form.
        no_portraits = [p for p in joan["photos"] if p.get("kind") != "portrait"]
        assert reliquary.pick_portrait(no_portraits, None)["file"] == files[2]
        bear = [dict(photos[files[2]], form="Bear Form")]
        assert reliquary.pick_portrait(bear, None)["file"] == files[2]  # only a bear: better than nothing
        assert reliquary.pick_portrait([photos[files[1]], photos[stray]], None) is None
        # The timeline (addon/Reliquary/Timeline.lua, server/timeline.py), newest entry first. Every
        # photo of the session was taken on Zephras Isle, so they lie on that entry, newest first;
        # the stray is only guessed to be hers and stays in the album alone.
        tl = joan["journey"]
        assert [e["zone"] for e in tl["entries"]] == ["Darkshore", "Zephras Isle"] and tl["days"] == [], tl
        shore, isle = tl["entries"]
        assert isle["photos"] == [f for f in files[::-1]], isle.get("photos")
        assert "photos" not in shore and shore["passed"] == ["The Great Sea"] and shore["kills"] == 2, shore
        assert shore["quests"] == [{"title": "The Lighthouse Keeper", "xp": 1100, "id": 98201}], shore["quests"]
        assert isle["quests"] == [{"title": "The Calmbreeze Crystal", "xp": 850, "id": 98103}] and isle["kills"] == 3
        assert isle["first"] and shore["first"] and isle["level"] == 12, isle
        assert shore["from"] >= isle["to"] and shore["active"] >= 600

        # What the page gets is only the game's names and numbers: anything else in a saved
        # timeline is dropped, never shown.
        t0 = 1_790_000_000
        junk = timeline.build({
            "entries": {1: {"zone": "Duskwood", "from": t0, "to": t0 + 900, "active": 99999, "level": 20, "levelTo": 19,
                            "kills": "12", "quests": [{"title": "  ", "xp": -5, "id": 7}, "x", {"title": "Worgen in the Woods", "xp": 650}],
                            "passed": ["Duskwood", "Elwynn Forest", "Elwynn Forest", 5, ""]},
                        2: {"zone": "Westfall", "from": t0, "to": t0 - 1},          # ends before it begins
                        3: {"zone": "", "from": t0, "to": t0 + 5},                  # no zone
                        4: {"zone": "Redridge Mountains", "from": "noon", "to": t0}},  # not a time
            "days": [{"date": "2026-10-01", "zone": "Elwynn Forest", "from": t0 - 86400, "to": t0 - 80000, "active": 3600,
                      "quests": 4, "xp": 2400, "kills": 31, "level": 10, "levelTo": 12}, {"zone": "Nowhere"}],
            "hiddenKills": 3,
        }, {"Duskwood": t0 - 30 * 86400})
        assert [e["zone"] for e in junk["entries"]] == ["Duskwood"], junk
        dusk = junk["entries"][0]
        assert dusk == {"zone": "Duskwood", "from": t0, "to": t0 + 900, "active": 960, "level": 20,
                        "quests": [{"id": 7}, {"title": "Worgen in the Woods", "xp": 650}], "passed": ["Elwynn Forest"]}, dusk
        assert junk["days"] == [{"zone": "Elwynn Forest", "from": t0 - 86400, "to": t0 - 80000, "active": 3600,
                                 "level": 10, "levelTo": 12, "kills": 31, "quests": 4, "xp": 2400}], junk["days"]
        assert junk["hiddenKills"] == 3 and "first" not in dusk  # first stood in Duskwood a month earlier
        assert timeline.build({"entries": [], "days": []}) is None and timeline.build(None) is None and timeline.build("x") is None
        # Photos: by time on entries; on a folded day only from its own zone; never a
        # character-screen capture or a guess.
        timeline.lay_photos(junk, [
            {"file": "late.jpg", "t": t0 + 940, "zone": "Duskwood"},              # within a look after the end
            {"file": "after.jpg", "t": t0 + 1000, "zone": "Duskwood"},            # well after
            {"file": "select-1.png", "t": t0 + 100, "kind": "select"},
            {"file": "guess.jpg", "t": t0 + 200, "guess": True},
            {"file": "dusk.jpg", "t": t0 + 300, "zone": "Duskwood"},
            {"file": "elwynn.jpg", "t": t0 - 85000, "zone": "Elwynn Forest"},
            {"file": "before.jpg", "t": t0 - 3, "zone": "Duskwood"},             # just before it began
            {"file": "westfall.jpg", "t": t0 - 84000, "zone": "Westfall"},       # that day, another zone
        ])
        assert dusk["photos"] == ["late.jpg", "dusk.jpg"] and junk["days"][0]["photos"] == ["elwynn.jpg"], junk

        # Before Reliquary (addon/Reliquary/History.lua): what the harness's game remembered.
        past = tl["before"]
        assert past["level"] == 12 and past["played"] >= 41820 and "photos" not in past, past
        assert past["challenges"] == [{"name": "A New Beginning", "date": "2026-11-06", "group": "Adventure",
                                       "description": "Finish the journey on Zephras Isle.", "points": 5}], past["challenges"]
        assert past["quests"] == {"count": 4, "titles": ["Into the Grove", "The Moonwell", "Shadowgale's Edge"]}, past["quests"]
        assert past["explored"] == [{"zone": "Zephras Isle", "areas": ["Thendal Grove", "Thendal Village", "Valanaar"]}]
        assert "flights" not in past and "honorKills" not in past and "titles" not in past
        assert past["stats"] == [{"name": "Creatures killed", "value": 214, "group": "Combat"}] and "missing" not in past
        # Only the game's names, numbers and dates reach the page.
        messy = timeline.before({
            "done": True, "at": t0, "level": "12", "played": 3600,
            "challenges": [{"name": "Fine", "date": "Nov 7", "points": -3}, {"name": " "}, "x"],
            "quests": {"count": 3, "ids": [7, 8, 9], "titles": {"7": "Seven", 9: "  "}},
            "explored": [{"zone": "Elwynn Forest", "areas": ["Goldshire", "Goldshire", 4, "Northshire"]}, {"areas": ["Nowhere"]}],
            "flights": [{"name": "Goldshire", "zone": "Elwynn Forest"}],             # saved by the first version: never shown
            "stats": [{"name": "Deaths", "value": 0}, {"name": "Creatures killed", "value": 12.0}],
            "pvp": {"kills": 5, "rank": 0}, "titles": ["Private", "Private", ""], "missing": {"stats": "no", "bad key": "x", "pvp": ""},
        })
        assert messy == {"at": t0, "played": 3600, "challenges": [{"name": "Fine"}], "quests": {"count": 3, "titles": ["Seven"]},
                       "explored": [{"zone": "Elwynn Forest", "areas": ["Goldshire", "Northshire"]}],
                       "stats": [{"name": "Creatures killed", "value": 12, "group": "Statistics"}], "honorKills": 5,
                       "titles": ["Private"], "missing": ["stats"]}, messy
        assert timeline.before({"at": t0}) is None and timeline.before({"done": True}) is None and timeline.before(None) is None
        assert timeline.before({"done": True, "at": t0, "quests": {"count": 2, "ids": [1, 2], "titles": ["One", "Two"]}})["quests"]["titles"] == ["One", "Two"]
        # A character with only what came before still has a timeline; its photos are the ones
        # taken before the first entry, never after the record was read.
        only = timeline.build(None, None, {"done": True, "at": t0, "level": 30})
        assert only == {"entries": [], "days": [], "before": {"at": t0, "level": 30}}, only
        timeline.lay_photos(only, [{"file": "late.jpg", "t": t0 + 600}, {"file": "old.jpg", "t": t0 - 600}, {"file": "cap.png", "t": t0 - 10, "kind": "select"}])
        assert only["before"]["photos"] == ["old.jpg"], only
        both = timeline.build({"entries": [{"zone": "Duskwood", "from": t0 + 100, "to": t0 + 900, "active": 700,
                                            "challenges": [{"id": 1, "name": "Night Watch"}, {"id": 2}]}]},
                              None, {"done": True, "at": t0})
        timeline.lay_photos(both, [{"file": "in.jpg", "t": t0 + 200}, {"file": "gap.jpg", "t": t0 + 50}, {"file": "old.jpg", "t": t0 - 50}])
        assert both["entries"][0]["photos"] == ["in.jpg"] and both["before"]["photos"] == ["old.jpg"], both
        assert both["entries"][0]["challenges"] == [{"name": "Night Watch"}], both
        # Read after the timeline had begun (an older Reliquary): a photo between its entries is not "before".
        late = timeline.build({"entries": [{"zone": "Duskwood", "from": t0 + 100, "to": t0 + 900, "active": 700}]},
                              None, {"done": True, "at": t0 + 2000})
        timeline.lay_photos(late, [{"file": "between.jpg", "t": t0 + 1000}, {"file": "old.jpg", "t": t0 + 50}])
        assert late["before"]["photos"] == ["old.jpg"] and "photos" not in late["entries"][0], late

        # A chosen portrait wins, and survives a rebuild; clearing it goes back to automatic.
        reliquary.save_choices({"portrait": {joan["key"]: files[2]}})
        assert reliquary.build_state(wtf, shots_dir=shots)["chars"][0]["portrait"] == {"file": files[2], "chosen": True}
        reliquary.save_choices({"portrait": {joan["key"]: "WoWScrnShot_010101_000000.jpg"}})  # file deleted since
        assert reliquary.build_state(wtf, shots_dir=shots)["chars"][0]["portrait"]["file"] == files[newest_portrait]

        # Web copies: WebP at the right size, cached, and nothing outside the folder.
        thumb = reliquary.shot_bytes(shots, files[0], "thumb")
        assert thumb and thumb[:4] == b"RIFF" and thumb[8:12] == b"WEBP"
        out = os.path.join(work, "t.webp")
        open(out, "wb").write(thumb)
        size = subprocess.run(["magick", "identify", "-format", "%wx%h", out], capture_output=True, text=True).stdout
        assert size == "1599x420", size
        assert len(os.listdir(reliquary.SHOT_CACHE)) == 1
        assert reliquary.shot_bytes(shots, files[0], "thumb") == thumb
        assert reliquary.shot_bytes(shots, "../" + files[0], "thumb") is None
        assert reliquary.shot_bytes(shots, files[0], "huge") is None
        assert reliquary.shot_bytes(shots, "notes.txt", "thumb") is None
        assert reliquary.shot_bytes(shots, ".hidden.jpg", "thumb") is None
        assert reliquary.shot_bytes(shots, "a/b.jpg", "thumb") is None
        assert reliquary.shot_bytes(shots, odd, "thumb")[8:12] == b"WEBP"
        assert photos[odd]["kind"] == "photo" and not photos[odd].get("guess"), photos[odd]

        # A character-screen capture: tagged with its character, and her portrait unless one was chosen.
        reliquary.save_choices({})
        os.makedirs(reliquary.CAPTURES)
        picture(os.path.join(reliquary.CAPTURES, "select-20261107-130000.png"), 700, 1000)
        picture(os.path.join(reliquary.CAPTURES, "select-stray.png"), 700, 1000)
        with open(os.path.join(reliquary.CAPTURES, "captures.json"), "w") as f:
            json.dump({"select-20261107-130000.png": {"key": joan["key"], "t": time.time(), "level": 17},
                       "select-stray.png": {"key": "Someone-Else"}, "../escape.png": {"key": joan["key"]}}, f)
        withcap = reliquary.build_state(wtf, shots_dir=shots)["chars"][0]
        caps = [p for p in withcap["photos"] if p.get("kind") == "select"]
        assert [p["file"] for p in caps] == ["select-20261107-130000.png"], caps
        assert withcap["portrait"] == {"file": "select-20261107-130000.png", "chosen": False}, withcap["portrait"]
        assert reliquary.shot_bytes(shots, "select-20261107-130000.png", "tall")[8:12] == b"WEBP"
        # The round portrait: her head and shoulders, square, from the capture and from a screenshot.
        assert reliquary.face_crop(500, 800, True) == (240, 170, 40)
        assert reliquary.face_crop(3840, 1080, False) == (594, 1623, 157)
        face = os.path.join(work, "face.webp")
        open(face, "wb").write(reliquary.shot_bytes(shots, "select-20261107-130000.png", "face"))
        assert subprocess.run(["magick", "identify", "-format", "%wx%h", face], capture_output=True, text=True).stdout == "640x640"

        # The public copy: no folder names (the account folder is the Battle.net account number),
        # no Print Screens (they can show chat) and no guesses, no prepared profile text, read-only.
        pub = reliquary.build_state(wtf, shots_dir=shots, public=True)
        raw = json.dumps(pub)
        assert pub["public"] and "wtf" not in pub and "TEST" not in raw and work not in raw, raw[:300]
        assert all(set(s) <= {"mtime", "error"} for s in pub["sources"]), pub["sources"]
        pj = pub["chars"][0]
        pub_files = {p["file"] for p in pj["photos"]}
        assert pub_files == {p["file"] for p in withcap["photos"] if p.get("kind") in reliquary.PUBLIC_KINDS}, pub_files
        assert files[1] not in pub_files and stray not in pub_files and files[0] in pub_files
        assert "profileDraft" not in pj
        assert pj["portrait"] == withcap["portrait"]
        # Where she has been is hers to show: her timeline stays off the public copy until she shows
        # where she is there. Shown, it carries only the photos the public copy shows: no Print Screen.
        assert not pj["journey"], pj["journey"]
        placed = os.path.join(work, "placed", "Account")
        os.makedirs(os.path.join(placed, "TEST", "SavedVariables"))
        data = luasv.load(saved)
        share = data["ReliquaryDB"]["chars"][joan["key"]]["share"]
        share["parts"] = dict(share.get("parts") or {}, place="p")
        with open(os.path.join(placed, "TEST", "SavedVariables", "Reliquary.lua"), "w", encoding="utf-8") as f:
            f.write(luasv.dumps(data))
        shown = reliquary.build_state(placed, shots_dir=shots, public=True)["chars"][0]["journey"]
        assert files[1] not in shown["entries"][1]["photos"] and files[0] in shown["entries"][1]["photos"], shown
        srv = reliquary.Server(("127.0.0.1", 0), reliquary.Handler)
        srv.wtf, srv.shots, srv.public = wtf, shots, True
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        base = f"http://127.0.0.1:{srv.server_address[1]}"

        def get(path, **kw):
            try:
                with urllib.request.urlopen(urllib.request.Request(base + path, **kw), timeout=30) as r:
                    return r.status, r.headers, r.read()
            except urllib.error.HTTPError as e:
                return e.code, e.headers, e.read()
        status, headers, body = get("/api/state")
        assert status == 200 and json.loads(body)["public"] and "default-src 'self'" in headers["Content-Security-Policy"]
        assert headers["X-Robots-Tag"].startswith("noindex")
        assert get(f"/shot/{files[0]}?v=thumb")[0] == 200
        assert get(f"/shot/{files[1]}?v=thumb")[0] == 404, "a Print Screen, found by its name"
        assert get(f"/shot/{stray}?v=thumb")[0] == 404, "a guess, found by its name"
        status, headers, body = get(f"/shot/{withcap['portrait']['file']}?v=card")
        assert status == 200 and headers["Content-Type"] == "image/jpeg" and body[:3] == b"\xff\xd8\xff"
        assert get("/api/portrait", method="POST", data=b'{"key":"x","file":null}',
                   headers={"X-Reliquary": "1", "Content-Type": "application/json"})[0] == 404
        page = get("/", headers={"Host": "reliquary.example.com"})[2].decode()
        assert f'content="https://reliquary.example.com/shot/{withcap["portrait"]["file"]}?v=card"' in page, page[:900]
        # The wide card, once tools/publish.py has made one: it replaces the face as the preview.
        cardfile = os.path.join(work, "card.jpg")
        subprocess.run(["magick", "-size", "1200x630", "xc:#201810", cardfile], check=True)
        srv.card = cardfile
        page = get("/", headers={"Host": "reliquary.example.com"})[2].decode()
        assert f'content="https://reliquary.example.com/card.jpg?v={int(os.path.getmtime(cardfile))}"' in page, page[:900]
        assert 'content="summary_large_image"' in page and "v=card" not in page
        status, headers, body = get("/card.jpg?v=1")
        assert status == 200 and headers["Content-Type"] == "image/jpeg" and body == open(cardfile, "rb").read()
        srv.card = os.path.join(work, "no-card.jpg")
        assert get("/card.jpg")[0] == 404 and "v=card" in get("/", headers={"Host": "reliquary.example.com"})[2].decode()
        # Each page names its own scripts and styles by their contents, so a cache in front of the
        # public copy (Cloudflare keeps .js and .css 4 hours) can never hand out old page code.
        for name, assets in (("/", ("app.js", "app.css")), ("/card.html", ("app.css", "card.css", "card.js"))):
            page = get(name)[2].decode()
            for a in assets:
                v = hashlib.sha256(open(os.path.join(reliquary.WEB, a), "rb").read()).hexdigest()[:12]
                assert f'"{a}?v={v}"' in page, (name, a, page)
                status, headers, body = get(f"/{a}?v={v}")
                assert status == 200 and body == open(os.path.join(reliquary.WEB, a), "rb").read(), (a, status)
        srv.public = False  # the owner's copy: every photo, and no preview address made from a Host header
        assert get(f"/shot/{files[1]}?v=thumb")[0] == 200 and "og:image" not in get("/")[2].decode()
        srv.shutdown()

        # Captures and a chosen portrait filed under the key her record had before the addon moved
        # it to her full name (name and realm, before 1.4.0) are still hers; a choice made under her
        # key since wins.
        old = "Joan-CAMWOWUS2Realm11RP"
        moved = os.path.join(work, "moved", "Account")
        os.makedirs(os.path.join(moved, "TEST", "SavedVariables"))
        data = luasv.load(saved)
        data["ReliquaryDB"]["chars"][joan["key"]]["was"] = [old]
        with open(os.path.join(moved, "TEST", "SavedVariables", "Reliquary.lua"), "w", encoding="utf-8") as f:
            f.write(luasv.dumps(data))
        with open(os.path.join(reliquary.CAPTURES, "captures.json"), "w") as f:
            json.dump({"select-20261107-130000.png": {"key": old, "t": time.time(), "level": 17}}, f)
        assert not [p for p in reliquary.build_state(wtf, shots_dir=shots)["chars"][0]["photos"] if p.get("kind") == "select"]
        was = reliquary.build_state(moved, shots_dir=shots)["chars"][0]
        assert [p["file"] for p in was["photos"] if p.get("kind") == "select"] == ["select-20261107-130000.png"], was["photos"]
        assert was["portrait"] == {"file": "select-20261107-130000.png", "chosen": False} and "_was" not in was, was["portrait"]
        reliquary.save_choices({"portrait": {old: files[2]}})
        assert reliquary.build_state(moved, shots_dir=shots)["chars"][0]["portrait"] == {"file": files[2], "chosen": True}
        reliquary.save_choices({"portrait": {old: files[2], joan["key"]: files[newest_portrait]}})
        assert reliquary.build_state(moved, shots_dir=shots)["chars"][0]["portrait"] == {"file": files[newest_portrait], "chosen": True}
        reliquary.save_choices({})
        shutil.rmtree(reliquary.CAPTURES)

        # No Screenshots folder at all: no photos, no portrait, no error.
        empty = reliquary.build_state(wtf, shots_dir=os.path.join(work, "nowhere"))["chars"][0]
        assert empty["photos"] == [] and empty["portrait"] is None
        demo = reliquary.build_state(wtf, demo=True, shots_dir=shots)["chars"][0]
        assert demo["photos"] == []
        print(f"photos ok: {len(photos)} matched or placed, portrait, timeline, web copies")
    finally:
        shutil.rmtree(work)


if __name__ == "__main__":
    main(sys.argv[1])
