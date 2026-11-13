"""Icons on the server: a page's new icons are fetched together and none twice, and every icon a
state shows is fetched as soon as that state is built, so the first visitor after a save never
waits on one. Blizzard's icon server is a slow stand-in here; nothing goes on the network.

    python3 tests/test_icons.py
"""
import contextlib
import io
import os
import shutil
import sys
import tempfile
import threading
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "server"))
import reliquary  # noqa: E402

JPEG = b"\xff\xd8\xff\xe0" + bytes(60)
FETCH = 0.2  # seconds Blizzard's stand-in takes for each icon


class Answer:
    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False

    def read(self):
        return JPEG


class IconServer:
    """Blizzard's icon server, slow on purpose, counting what each icon was asked for."""

    def __init__(self):
        self.calls = {}
        self.lock = threading.Lock()

    def __call__(self, req, timeout=None):
        name = req.full_url.rsplit("/", 1)[1][: -len(".jpg")]
        with self.lock:
            self.calls[name] = self.calls.get(name, 0) + 1
        time.sleep(FETCH)
        return Answer()


def main():
    tmp = tempfile.mkdtemp(dir=os.environ.get("TMPDIR"))
    saved = (reliquary.ICON_CACHE, reliquary.ICONS, reliquary.PRICES, reliquary.WATCH_EVERY, reliquary.build_state,
             reliquary.warm_icons, reliquary.urllib.request.urlopen)
    try:
        reliquary.ICON_CACHE = os.path.join(tmp, "icons")
        reliquary.PRICES = os.path.join(tmp, "prices.json")
        reliquary.ICONS = {str(1000 + i): f"inv_test_{i}" for i in range(12)}
        fake = IconServer()
        reliquary.urllib.request.urlopen = fake

        # What a state shows: every whole number under "icon" or "ic", at any depth; never a name or
        # a yes/no.
        state = {"chars": [{"icon": 1000, "name": "Joan", "profs": [{"icon": 1001}], "talents": {"nodes": [{"ic": 1002}]}}],
                 "itemInfo": {"118": {"icon": 1003, "q": 1}}, "roleplay": {"icon": "inv_misc_book_09"}, "odd": {"icon": True}}
        assert reliquary.icon_ids(state) == {1000, 1001, 1002, 1003}, reliquary.icon_ids(state)

        # A page's new icons come together, and none twice.
        t = time.monotonic()
        got = reliquary.warm_icons(range(1000, 1012))
        took = time.monotonic() - t
        assert got == 12, got
        assert took < FETCH * 12 / 3, f"12 new icons took {took:.2f} s: one at a time"
        assert sorted(fake.calls.values()) == [1] * 12, fake.calls
        assert reliquary.warm_icons(range(1000, 1012)) == 0, "icons on disk were fetched again"
        assert reliquary.icon_bytes(1000) == JPEG and fake.calls["inv_test_0"] == 1
        # Five visitors asking for the same new icon at once: it is fetched once.
        reliquary.ICONS["2000"] = "inv_test_shared"
        asks = [threading.Thread(target=reliquary.icon_bytes, args=(2000,)) for _ in range(5)]
        for a in asks:
            a.start()
        for a in asks:
            a.join()
        assert fake.calls["inv_test_shared"] == 1, fake.calls["inv_test_shared"]

        # The server builds each state as its files change and fetches the icons it shows then,
        # before any page asks; with nothing changed it does neither.
        srv = reliquary.Server(("127.0.0.1", 0), reliquary.Handler)
        srv.public, srv.wtf, srv.shots = False, os.path.join(tmp, "wtf"), os.path.join(tmp, "shots")
        os.makedirs(srv.shots)
        builds, warmed = [], []

        def build(wtf, demo=False, **kw):
            builds.append(demo)
            time.sleep(0.3)
            return {"chars": [{"icon": 1100 + len(builds)}], "demo": demo}

        reliquary.build_state = build
        reliquary.warm_icons = lambda ids: warmed.append(set(ids)) or 0
        srv.warm_pass()
        assert builds == [False, True] and warmed == [{1101}, {1102}], (builds, warmed)
        srv.warm_pass()
        assert builds == [False, True] and len(warmed) == 2, "a state was built or warmed again with nothing changed"
        now = time.time()
        os.utime(srv.shots, (now + 10, now + 10))  # a save
        srv.warm_pass()
        assert builds == [False, True, False, True] and warmed[2:] == [{1103}, {1104}], (builds, warmed)

        # One build at a time: visitors who come during a build wait for it and use it.
        builds.clear()
        os.utime(srv.shots, (now + 20, now + 20))
        visitors = [threading.Thread(target=srv.state) for _ in range(4)]
        for v in visitors:
            v.start()
        for v in visitors:
            v.join()
        assert builds == [False], f"four visitors during one save built {len(builds)} times"

        # A save still being written (its build fails): the watcher says so once, keeps looking,
        # and warms the state when it can be built.
        fails = [2]

        def flaky(wtf, demo=False, **kw):
            if not demo and fails[0] > 0:
                fails[0] -= 1
                raise ValueError("a file is still being written")
            return {"chars": [{"icon": 1108 if demo else 1109}]}

        reliquary.build_state = flaky
        reliquary.WATCH_EVERY = 0.05
        warmed.clear()
        os.utime(srv.shots, (now + 30, now + 30))
        said, stop = io.StringIO(), threading.Event()
        with contextlib.redirect_stdout(said):
            watcher = threading.Thread(target=srv.watch, args=(stop,), daemon=True)
            watcher.start()
            until = time.monotonic() + 5
            while time.monotonic() < until and {1109} not in warmed:
                time.sleep(0.05)
            alive = watcher.is_alive()
            stop.set()
            watcher.join(2)
        assert alive and {1109} in warmed, (alive, warmed)
        assert said.getvalue().count("could not look yet") == 1, said.getvalue()
        assert not watcher.is_alive(), "the watcher didn't stop"
        srv.server_close()
    finally:
        (reliquary.ICON_CACHE, reliquary.ICONS, reliquary.PRICES, reliquary.WATCH_EVERY, reliquary.build_state,
         reliquary.warm_icons, reliquary.urllib.request.urlopen) = saved
        shutil.rmtree(tmp)
    print(f"icons ok: what a state shows, 12 new icons in {took:.2f} s and none twice, built and fetched on each save "
          "before a page asks, one build at a time, a half-written save waited out")


if __name__ == "__main__":
    main()
