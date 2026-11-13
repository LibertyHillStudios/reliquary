#!/usr/bin/env bash
# Runs the Reliquary addon against the simulated client in every scenario and in a simulated
# world of players sharing with each other, then the server's tests, then parses the results
# and every real SavedVariables file with the dashboard's reader.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)
trap 'rm -rf "${out:?}"' EXIT
luac5.1 -p addon/Reliquary/*.lua
# The renders' and films' director (tools/render.sh): its scripts parse.
luac5.1 -p tools/render/*.lua
# Every shell script parses (each on its own: bash -n checks only the first file it is given).
for f in tools/*.sh; do bash -n "$f"; done
# Prints each run's first line; a failing run prints everything it said.
run() {
  local log
  if ! log=$("$@" 2>&1); then printf '%s\n' "$log" >&2; exit 1; fi
  printf '%s\n' "${log%%$'\n'*}"
}
for s in full secrets bare combat; do
  run lua5.1 tests/harness.lua addon/Reliquary/Reliquary.toc "$out/$s.lua" "$s"
done
run luajit tests/harness.lua addon/Reliquary/Reliquary.toc "$out/jit.lua" full
# The timeline over several sessions: thresholds, stops, detours, AFK, quests, kills, relogs, folding.
run lua5.1 tests/timeline.lua addon/Reliquary/Timeline.lua
run luajit tests/timeline.lua addon/Reliquary/Timeline.lua
# Eight players sharing through a simulated server: guild, friends, public, the guild bank. With
# Forever's "Given Family" names, and once with "Name-Realm" names as other clients have.
run lua5.1 tests/share.lua addon/Reliquary/Reliquary.toc
run luajit tests/share.lua addon/Reliquary/Reliquary.toc
RQ_NAMES=realm run lua5.1 tests/share.lua addon/Reliquary/Reliquary.toc
# What the game remembers from before Reliquary: challenges, quests, the map, statistics.
run lua5.1 tests/history.lua addon/Reliquary/History.lua
run luajit tests/history.lua addon/Reliquary/History.lua
# The installer copies everything the addon has, into a folder of its own here (never the game's).
if ! pgrep -x Wow.exe >/dev/null; then
  RELIQUARY_ADDONS="$out/AddOns" tools/install-addon.sh >/dev/null
  diff <(cd addon/Reliquary && find . -type f | sort) <(cd "$out/AddOns/Reliquary" && find . -type f | sort)
  echo "install ok: $(find "$out/AddOns/Reliquary" -type f | wc -l) files"
fi
# The server's tests keep their price files here, never beside the real ones.
export XDG_STATE_HOME="$out/state"
nice python3 tests/test_photos.py "$out/full.lua"
# Every other server and tool test (the copy published for everyone leaves out the tools that are
# one player's own, and their tests with them).
for t in tests/test_*.py; do
  [ "$t" = tests/test_photos.py ] || nice python3 "$t"
done
node tests/test_rp.mjs
python3 - "$out" <<'PY'
import glob, sys
sys.path.insert(0, "server")
import luasv
for p in sorted(glob.glob(sys.argv[1] + "/*.lua")):
    luasv.load(p)
import os
real = glob.glob(os.path.join(os.environ.get("WOW_FOREVER", "/mnt/games/wow-forever"), "_forever_", "WTF", "Account", "*", "SavedVariables", "*.lua"))
for p in real:
    luasv.load(p)
print(f"reader ok: {len(glob.glob(sys.argv[1] + '/*.lua'))} test files, {len(real)} real saved files")
PY
