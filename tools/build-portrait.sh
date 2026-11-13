#!/usr/bin/env bash
# Builds the /rq window's portrait (addon/Reliquary/Media/portrait-<size>.tga) from brand/portrait.svg,
# in the three sizes the window chooses between by how large the screen draws it (Viewer.lua), as
# the game reads a TGA and as Media/icon.tga is: 32-bit, uncompressed, rows from the bottom. The
# header is written here and the rows come from ImageMagick raw, so no writer can flip the picture.
# Run it after changing the SVG.
set -euo pipefail
cd "$(dirname "$0")/.."
for tool in rsvg-convert magick python3; do command -v "$tool" >/dev/null || { echo "build-portrait: $tool is needed" >&2; exit 1; }; done
work=$(mktemp -d)
trap 'rm -rf "${work:?}"' EXIT
for size in 64 128 256; do
  rsvg-convert -w "$size" -h "$size" brand/portrait.svg -o "$work/portrait.png"
  magick "$work/portrait.png" -flip -depth 8 "BGRA:$work/rows" # the bottom row first, each pixel blue, green, red, alpha
  python3 - "$work/rows" "addon/Reliquary/Media/portrait-$size.tga" "$size" <<'PY'
import struct, sys
rows, out, size = sys.argv[1], sys.argv[2], int(sys.argv[3])
data = open(rows, "rb").read()
assert len(data) == size * size * 4, (len(data), size)
# Type 2 (true colour, uncompressed), no colour map, origin bottom left, 32 bits with 8 of alpha.
header = struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, size, size, 32, 8)
open(out, "wb").write(header + data)
PY
  echo "addon/Reliquary/Media/portrait-$size.tga"
done
