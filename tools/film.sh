#!/usr/bin/env bash
# Films a shot of the /rq window's motion: each frame is a render (tools/render.sh) drawn so many
# sixtieths of a second into the movement, Reliquary's clock stepped a frame at a time as the game
# steps it (tools/render/tour.lua: the simulator never moves time on by itself), and the frames are
# joined into an H.264 film at 60 frames a second (yuv420p, faststart: it plays in any browser).
# Renders run four at a time, each at the lowest priority (render.sh's own nice -n 19), and on the CPU
# while WoW runs, as render.sh does; a frame whose render hung is drawn once more.
#
#   tools/film.sh open                 # the window opening on Characters: <out>/open.mp4
#   tools/film.sh tab                  # Characters giving way to Guild
#   SAMPLE=1 tools/film.sh chat        # a new line arriving in the guild's chat
#   tools/film.sh fold                 # a Timeline stop opening, the cards under it moving down
#   tools/film.sh bars                 # Reputation arriving from Gear, its bars filling
#   tools/film.sh bags-open            # the window opening on a character's Bags page
#   tools/film.sh bank-open            # the window opening on the Guild Bank
#   tools/film.sh bank-tab             # another of the guild bank's tabs
#   tools/film.sh bank-view            # the guild bank's Log
#   tools/film.sh talents-in           # the Talents page arriving, row by row
#   tools/film.sh recipes-fold         # a profession's card folding away
#   tools/film.sh recipes-pick         # another recipe chosen, the gold bar gliding to it
#   SAMPLE=1 tools/film.sh roleplay-in # a Total RP 3 profile arriving
#   tools/film.sh item-page            # an item's page sliding in over the Gear page, then Back
#   tools/film.sh switch               # a switch on the Sharing tab turned on, then a box ticked
#   ITEM=6505 SAMPLE=1 tools/film.sh bank-item  # the guild bank tab that holds an item chosen, then its page
#   LENGTH=1.5 OUT=dir SAMPLE=1 SIZE=1920x1080 tools/film.sh open
#
# The frames stay beside the film (<out>/<shot>-frames/) for stepping through.
set -euo pipefail
cd "$(dirname "$0")/.."
shot=${1:-}
case $shot in open|tab|chat|fold|bars|bags-open|bank-open|bank-tab|bank-view|talents-in|recipes-fold|recipes-pick|roleplay-in|item-page|switch|bank-item) ;;
  *) echo "film: name a shot: open, tab, chat, fold, bars, bags-open, bank-open, bank-tab, bank-view, talents-in, recipes-fold, recipes-pick, roleplay-in, item-page, switch or bank-item" >&2; exit 1 ;;
esac
length=${LENGTH:-1.2}
case $length in *[!0-9.]*|"") echo "film: LENGTH is seconds" >&2; exit 1 ;; esac
frames=$(awk -v s="$length" 'BEGIN { printf "%d", s * 60 + 0.5 }')
[ "$frames" -gt 0 ] || { echo "film: LENGTH is too short for a frame" >&2; exit 1; }
command -v ffmpeg >/dev/null || { echo "film: ffmpeg is needed" >&2; exit 1; }
OUT=${OUT:-${XDG_CACHE_HOME:-$HOME/.cache}/reliquary/films/$(date +%Y%m%d-%H%M%S)}
mkdir -p "$OUT"
# Every frame is drawn at one moment, so the times a page shows don't change through the film.
export NOW=${NOW:-$(date +%s)}
work=$(mktemp -d)
pids=()
trap 'for p in "${pids[@]}"; do kill "$p" 2>/dev/null || true; done; rm -rf "${work:?}"' EXIT
# Four renderers, each every fourth frame.
for w in 0 1 2 3; do
  list=$(seq "$w" 4 $((frames - 1)) | tr '\n' ' ')
  [ -n "${list// /}" ] || continue
  FRAMES="$list" OUT="$work/$w" tools/render.sh "$shot" >"$work/$w.log" 2>&1 &
  pids+=($!)
done
for p in "${pids[@]}"; do wait "$p" || true; done
pids=()
# A frame whose render hung (render.sh stops one after five minutes) is drawn once more; any other
# error, or a frame still missing, stops the film.
missing=$(for i in $(seq 0 $((frames - 1))); do
  n=$(printf '%s-%04d.png' "$shot" "$i")
  compgen -G "$work/[0-3]/$n" >/dev/null || echo "$i"
done | tr '\n' ' ')
if [ -n "${missing// /}" ]; then
  echo "film: drawing frames $missing again" >&2
  FRAMES="$missing" OUT="$work/4" tools/render.sh "$shot" >"$work/4.log" 2>&1 || true
fi
cat "$work"/[0-4]/errors.txt 2>/dev/null | grep -v ': the simulator hung' | sort -u >"$OUT/errors.txt" || true
if [ -s "$OUT/errors.txt" ]; then
  echo "film: a render failed:" >&2
  cat "$OUT/errors.txt" >&2
  exit 1
fi
rm -rf "${OUT:?}/$shot-frames"
mkdir -p "$OUT/$shot-frames"
for f in "$work"/[0-4]/"$shot"-[0-9][0-9][0-9][0-9].png; do if [ -e "$f" ]; then mv "$f" "$OUT/$shot-frames/"; fi; done
got=$(ls "$OUT/$shot-frames" | wc -l)
[ "$got" -eq "$frames" ] || { echo "film: $got of $frames frames came out" >&2; tail -3 "$work"/[0-4].log >&2; exit 1; }
# H.264 wants even sides: the crop is trimmed by a pixel when it isn't.
ffmpeg -v error -y -framerate 60 -i "$OUT/$shot-frames/$shot-%04d.png" -vf "crop=trunc(iw/2)*2:trunc(ih/2)*2:0:0" \
  -c:v libx264 -preset slow -crf 16 -pix_fmt yuv420p -movflags +faststart "$OUT/$shot.mp4"
echo "Filmed $shot: $frames frames, $(awk -v f="$frames" 'BEGIN { printf "%.2f", f / 60 }') s: $OUT/$shot.mp4"
