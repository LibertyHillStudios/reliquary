#!/usr/bin/env bash
# Builds the /rq window's art (addon/Reliquary/Media/ui-<name>.tga) from brand/ui/ui-<name>.svg, each
# at its SVG's own size, as the game reads a TGA and as build-portrait.sh writes the portrait: 32-bit,
# uncompressed, rows from the bottom. The header is written here and the rows come from ImageMagick
# raw, so no writer can flip the picture. The game needs each side to be a power of two; a file that
# isn't stops the build. Run it after changing an SVG; Skin.lua names the files and where each piece
# of an atlas or a nine-slice sits in it.
set -euo pipefail
cd "$(dirname "$0")/.."
for tool in rsvg-convert magick python3; do command -v "$tool" >/dev/null || { echo "build-art: $tool is needed" >&2; exit 1; }; done
work=$(mktemp -d)
trap 'rm -rf "${work:?}"' EXIT
shopt -s nullglob
svgs=(brand/ui/ui-*.svg)
[ ${#svgs[@]} -gt 0 ] || { echo "build-art: no brand/ui/ui-*.svg" >&2; exit 1; }
for svg in "${svgs[@]}"; do
  name=$(basename "$svg" .svg)
  rsvg-convert "$svg" -o "$work/$name.png"
  size=$(magick identify -format '%w %h' "$work/$name.png")
  w=${size% *} h=${size#* }
  for side in "$w" "$h"; do
    (( side > 0 && (side & (side - 1)) == 0 )) || { echo "build-art: $svg is ${w}x$h; each side must be a power of two" >&2; exit 1; }
  done
  magick "$work/$name.png" -flip -depth 8 "BGRA:$work/rows" # the bottom row first, each pixel blue, green, red, alpha
  python3 - "$work/rows" "addon/Reliquary/Media/$name.tga" "$w" "$h" <<'PY'
import struct, sys
rows, out, w, h = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
data = open(rows, "rb").read()
assert len(data) == w * h * 4, (len(data), w, h)
# Type 2 (true colour, uncompressed), no colour map, origin bottom left, 32 bits with 8 of alpha.
header = struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, w, h, 32, 8)
open(out, "wb").write(header + data)
PY
  echo "addon/Reliquary/Media/$name.tga (${w}x$h)"
done
