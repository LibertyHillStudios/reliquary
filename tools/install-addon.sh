#!/usr/bin/env bash
# Copies the Reliquary addon into WoW: Forever's AddOns folder. The game must be closed: its
# addons are never changed under it. With --wait, waits for the game to close first.
set -euo pipefail
src="$(cd "$(dirname "$0")/.." && pwd)/addon/Reliquary"
dest="${RELIQUARY_ADDONS:-${WOW_FOREVER:-/mnt/games/wow-forever}/_forever_/Interface/AddOns}/Reliquary"

running() { pgrep -x Wow.exe >/dev/null; }

if [[ "${1:-}" == "--wait" ]]; then
  echo "Waiting for WoW to close..."
  while running; do sleep 5; done
  sleep 2
elif running; then
  echo "WoW is running. Close it first, or run: $0 --wait" >&2
  exit 1
fi
if running; then
  echo "WoW started again before the copy; nothing changed." >&2
  exit 1
fi
mkdir -p "$dest/Media"
# The TOC, every file it lists and its pictures (Media: the icon in the AddOns list and the
# window), so a new file is never left behind.
mapfile -t files < <(sed -n 's/\r$//; /^[A-Za-z0-9_]*\.lua$/p' "$src/Reliquary.toc")
mapfile -t media < <(cd "$src" && find Media -type f | sort)
for f in Reliquary.toc "${files[@]}" "${media[@]}"; do
  cp "$src/$f" "$dest/$f.part"
  mv "$dest/$f.part" "$dest/$f"
  cmp "$src/$f" "$dest/$f"
done
echo "Installed Reliquary $(sed -n 's/^## Version: //p' "$dest/Reliquary.toc") in $dest"
