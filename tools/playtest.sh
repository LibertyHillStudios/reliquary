#!/usr/bin/env bash
# Lays out a test build of the addon: <dir>/Reliquary, holding exactly the files a release's zip
# holds (tools/addon-files.sh), copied from this tree as it stands, uncommitted edits included.
# Liberty Hill Studios' launcher builds each change's playtest with it and puts the folder into the
# tester's own game for the playtest.
#
#   tools/playtest.sh <dir>     # <dir>/Reliquary; <dir> must not hold a Reliquary folder yet
set -euo pipefail
[ $# -eq 1 ] || { echo "usage: tools/playtest.sh <dir>" >&2; exit 2; }
mkdir -p "$1"
out="$(cd "$1" && pwd)/Reliquary"
cd "$(dirname "$0")/.."
[ ! -e "$out" ] || { echo "$out is already there." >&2; exit 1; }
files=$(tools/addon-files.sh)
while IFS= read -r f; do
  case "$f" in
    CHANGELOG.md | LICENSE | NOTICE) src=$f ;;
    *) src=addon/Reliquary/$f ;;
  esac
  [ -f "$src" ] || { echo "The addon holds $f, which this tree does not have ($src)." >&2; rm -rf "${out:?}"; exit 1; }
  mkdir -p "$(dirname "$out/$f")"
  cp "$src" "$out/$f"
done <<<"$files"
version=$(sed -n 's/^## Version: //p' "$out/Reliquary.toc" | tr -d '\r')
echo "$out: Reliquary $version, $(printf '%s\n' "$files" | wc -l) files"
