#!/usr/bin/env python3
"""Builds data/icons.json: the game's icon file IDs mapped to icon names.

The addon records icons as file IDs (the only thing the game hands an addon); the
dashboard needs names to fetch the pictures. The names come from the community
listfile (github.com/wowdev/wow-listfile). Run again to pick up new icons.
"""
import json, os, re, sys, tempfile, urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "data", "icons.json")
RELEASE = "https://api.github.com/repos/wowdev/wow-listfile/releases/latest"


def main():
    rel = json.load(urllib.request.urlopen(RELEASE))
    url = next(a["browser_download_url"] for a in rel["assets"] if a["name"] == "community-listfile.csv")
    icons = {}
    with tempfile.TemporaryDirectory(dir=os.environ.get("TMPDIR")) as tmp:
        path = os.path.join(tmp, "listfile.csv")
        urllib.request.urlretrieve(url, path)
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.strip()
                fid, _, name = line.partition(";")
                low = name.lower()
                if not low.startswith("interface/icons/"):
                    continue
                m = re.fullmatch(r"interface/icons/([^/]+)\.(blp|tga|png)", low)
                if m and fid.isdigit():
                    icons[fid] = m.group(1)
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w") as f:
        json.dump(icons, f, separators=(",", ":"), sort_keys=True)
    print(f"{len(icons)} icons from {rel['tag_name']} -> {OUT}")


if __name__ == "__main__":
    sys.exit(main())
