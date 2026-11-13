#!/usr/bin/env bash
# Renders the /rq window and the minimap button as WoW: Forever draws them, from the game's own
# interface files and art, at the size this machine's game window has (its newest screenshot) and
# the game's UI scale, with your saved characters. For looking at a change before anyone opens the
# game; the game is the final word on feel.
#
# wow-ui-sim (github.com/Osso/wow-ui-sim, GPL-3.0, pinned below) does the drawing, sandboxed with
# bubblewrap: no network, the game folder read-only, nothing written but its own cache and the
# output folder. Each page is a step in tools/render/tour.lua; tools/render/shims.lua fills the few
# things the simulator lacks with what the game has. It cannot draw the game's progress bars
# (reputation, professions), icons inside text (coins) or the newest icons: look at those in game.
#
#   tools/render.sh                  # every page, into ~/.cache/reliquary/renders/<time>/
#   tools/render.sh gear quests      # just those
#   OUT=dir SIZE=1920x1080 SCALE=0.9 tools/render.sh
#   TOUR=try.lua FULL=1 tools/render.sh gear   # another script in place of the tour; keep the whole screen
#   SAMPLE=1 tools/render.sh friends public     # the made-up players of data/sample in place of your own
#   ITEM=2318 tools/render.sh item              # an item's page (Handstitched Leather Boots without ITEM)
#   FRAMES="0 6 12" tools/render.sh open        # a shot's frames, 60 a second, as tools/film.sh asks: open-0000.png...
#   NOW=1794383658 tools/render.sh guild-chat   # drawn as at that moment (date +%s), whatever the clock says
#
# It never draws on the GPU while WoW runs: the game hung on that card while a batch of renders was
# drawing (2026-11-10). Beside the game, or with WOW_SIM_SOFTWARE_RENDER=1, it draws on the CPU with
# Mesa's lavapipe: the system's if it has one, else the distribution's own package (vulkan-swrast, the
# version and checksum pacman's database names), unpacked once beside the simulator. Slower, the same
# picture.
set -euo pipefail
cd "$(dirname "$0")/.."
here=$PWD
soft=${WOW_SIM_SOFTWARE_RENDER:-}
pgrep -x Wow.exe >/dev/null && soft=1

VERSION=v0.1.40
ASSET=wow-ui-sim-$VERSION-forever-linux-x86_64
SHA256=aecd2c593124a5363daa3d273090b3de589c1b7a61344debe5e360d40235c326
SIM=${XDG_CACHE_HOME:-$HOME/.cache}/wow-ui-sim
GAME=${WOW_FOREVER:-/mnt/games/wow-forever}
WTF=$GAME/_forever_/WTF
X=60 Y=40 # where the tour puts the window, in UI units from the screen's top left
PAGES=(gear talents talents-shared bags bank reputation quests timeline timeline-open recipes roleplay roleplay-waiting guild guild-chat chat-long chat-empty officer-chat whispers guild-bank guild-bank-log guild-bank-sharing friends public sharing item minimap)
[ $# -gt 0 ] && PAGES=("$@")
case ${ITEM:-} in *[!0-9]*) echo "render: ITEM is an item's number" >&2; exit 1 ;; esac
case ${NOW:-} in *[!0-9]*) echo "render: NOW is a time in seconds, as date +%s gives it" >&2; exit 1 ;; esac

for tool in bwrap ffmpeg ffprobe; do command -v "$tool" >/dev/null || { echo "render: $tool is needed" >&2; exit 1; }; done
[ -d "$GAME/Data" ] || { echo "render: no WoW: Forever install at $GAME (set WOW_FOREVER)" >&2; exit 1; }

# The simulator, downloaded once and checked.
if [ ! -x "$SIM/$ASSET/wow-sim" ]; then
  mkdir -p "$SIM/dl"
  tarball=$SIM/dl/$ASSET.tar.gz
  [ -f "$tarball" ] || curl -fL --retry 3 -o "$tarball" "https://github.com/Osso/wow-ui-sim/releases/download/$VERSION/$ASSET.tar.gz"
  echo "$SHA256  $tarball" | sha256sum -c --quiet - || { echo "render: $tarball isn't the pinned release" >&2; exit 1; }
  tar -xzf "$tarball" -C "$SIM"
fi
mkdir -p "$SIM/home"
bin=$SIM/$ASSET

work=$(mktemp -d)
sample=nil
[ -n "${SAMPLE:-}" ] && sample=true
trap 'rm -rf "${work:?}"' EXIT
# The made-up players of data/sample, saved as the game saves them, in place of yours.
if [ -n "${SAMPLE:-}" ]; then
  WTF=$work/sample-wtf
  mkdir -p "$WTF/Account/SAMPLE/SavedVariables" "$WTF/Account/SAMPLE/CAMWOWUS2Realm11RP/Joan"
  cp data/sample/Reliquary.lua data/sample/totalRP3_Data.lua "$WTF/Account/SAMPLE/SavedVariables/"
  # The simulator's player is always in its own guild: the sample guild goes by that name here.
  sed -i 's/The Moonwell Circle/Heroes of Azeroth/g' "$WTF/Account/SAMPLE/SavedVariables/Reliquary.lua"
fi
# The account, and the character played last (its WTF folder names the simulator's player).
account=$(ls "$WTF/Account" | grep -v '^SavedVariables$' | head -1)
charDir=$(ls -td "$WTF/Account/$account"/*/*/ 2>/dev/null | grep -v '/SavedVariables/$' | head -1)
[ -n "$charDir" ] || { echo "render: no character in $WTF" >&2; exit 1; }
realm=$(basename "$(dirname "$charDir")")
char=$(basename "$charDir")

# The game window's size (its newest screenshot), and its UI scale: the one set in its options,
# else 1 (the client's own default may be smaller on a tall screen; the layout is the same).
if [ -z "${SIZE:-}" ]; then
  shot=$(ls -t "$GAME/_forever_/Screenshots"/*.jpg 2>/dev/null | head -1 || true)
  SIZE=$([ -n "$shot" ] && ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0:s=x "$shot" || echo 1920x1080)
fi
W=${SIZE%x*} H=${SIZE#*x}
if [ -z "${SCALE:-}" ]; then
  SCALE=1
  if grep -qs '^SET useUiScale "1"' "$GAME/_forever_/WTF/Config.wtf"; then
    SCALE=$(sed -n 's/^SET uiScale "\(.*\)"/\1/p' "$GAME/_forever_/WTF/Config.wtf" | head -1)
  fi
fi
uiScale=$(awk -v h="$H" -v s="$SCALE" 'BEGIN { printf "%.6f", h / 768 * s }')

OUT=${OUT:-${XDG_CACHE_HOME:-$HOME/.cache}/reliquary/renders/$(date +%Y%m%d-%H%M%S)}
mkdir -p "$OUT"
mkdir -p "$work/AddOns" "$work/wtf"
cp -r addon/Reliquary "$work/AddOns/Reliquary"
# The fills for what the simulator lacks, as an addon loaded before Reliquary (its name sorts first),
# so Reliquary logs in with them in place.
mkdir -p "$work/AddOns/!ReliquaryRender"
printf '## Interface: 16001\n## Title: Reliquary render fills\nnow.lua\nshims.lua\n' >"$work/AddOns/!ReliquaryRender/!ReliquaryRender.toc"
printf 'RQ_NOW = %s\n' "${NOW:-nil}" >"$work/AddOns/!ReliquaryRender/now.lua"
cp tools/render/shims.lua "$work/AddOns/!ReliquaryRender/shims.lua"

gpu=()
[ -z "$soft" ] && [ -e /dev/nvidia0 ] && for d in /dev/nvidia0 /dev/nvidiactl /dev/nvidia-modeset /dev/nvidia-uvm /dev/dri; do [ -e "$d" ] && gpu+=(--dev-bind "$d" "$d"); done
if [ ${#gpu[@]} -eq 0 ]; then
  export WOW_SIM_SOFTWARE_RENDER=1 # Mesa's software Vulkan (lavapipe)
  if [ ! -e /usr/lib/libvulkan_lvp.so ]; then
    command -v pacman >/dev/null || { echo "render: no CPU Vulkan driver (Mesa's lavapipe) is installed" >&2; exit 1; }
    ver=$(pacman -Si vulkan-swrast | awk '/^Version/ { print $3 }')
    lvp=$SIM/lavapipe/$ver
    if [ ! -e "$lvp/usr/lib/libvulkan_lvp.so" ]; then
      url=$(pacman -Sp vulkan-swrast | grep '/vulkan-swrast-' | head -1)
      sum=$(bsdtar -xOf /var/lib/pacman/sync/extra.db "vulkan-swrast-$ver/desc" | awk '/%SHA256SUM%/ { getline; print }')
      [ -n "$url" ] && [ -n "$sum" ] || { echo "render: pacman doesn't name a vulkan-swrast package to fetch" >&2; exit 1; }
      mkdir -p "$SIM/dl" "$lvp"
      curl -fsSL --retry 3 -o "$SIM/dl/vulkan-swrast-$ver.pkg.tar.zst" "$url"
      echo "$sum  $SIM/dl/vulkan-swrast-$ver.pkg.tar.zst" | sha256sum -c --quiet - || { echo "render: the lavapipe package isn't the one pacman names" >&2; exit 1; }
      bsdtar -xf "$SIM/dl/vulkan-swrast-$ver.pkg.tar.zst" -C "$lvp" usr/lib/libvulkan_lvp.so
    fi
    printf '{"ICD":{"api_version":"1.4.0","library_path":"%s/usr/lib/libvulkan_lvp.so"},"file_format_version":"1.0.1"}\n' "$lvp" >"$lvp/icd.json"
    gpu=(--ro-bind "$lvp" "$lvp" --setenv VK_DRIVER_FILES "$lvp/icd.json")
  fi
fi

# Blizzard's interface files for the installed build, from the game's own storage, once.
sim() {
  nice -n 19 bwrap --ro-bind /usr /usr --ro-bind /etc /etc --symlink usr/lib /lib --symlink usr/lib64 /lib64 --symlink usr/bin /bin \
    --proc /proc --dev /dev --ro-bind /sys /sys "${gpu[@]}" --tmpfs /tmp \
    --bind "$SIM/home" "$HOME" --ro-bind "$bin" "$bin" --ro-bind "$GAME" "$GAME" --bind "$work" "$work" --bind "$OUT" "$OUT" \
    --unshare-net --die-with-parent --chdir "$bin" \
    --setenv WOW_INSTALL_PATH "$GAME" --setenv WOW_SIM_PROFILE wowforever --setenv WOW_SIM_ADDONS_PATH_EXCLUSIVE 1 \
    --setenv WOW_SIM_WTF_PATH "$WTF" --setenv WOW_SIM_WTF_ACCOUNT "$account" --setenv WOW_SIM_WTF_REALM "$realm" \
    --setenv WOW_SIM_WTF_CHARACTER "$char" "$@"
}
[ -d "$SIM/home/.cache/wow-ui-sim/blizzard-ui/wowforever/AddOns" ] || sim "$bin/wow-cli" casc sync-blizzard-ui --allow-ui-version-mismatch >"$work/sync.log" 2>&1 \
  || { tail -5 "$work/sync.log" >&2; exit 1; }

crop=$(awk -v u="$uiScale" -v x="$X" -v y="$Y" 'BEGIN {
  printf "%d:%d:%d:%d", (960 + 56) * u, (640 + 60) * u, (x - 28) * u, (y - 24) * u }') # the window (960 by 640) and its shadow
: >"$OUT/errors.txt"
for page in "${PAGES[@]}"; do
  case $page in *[!a-z-]*) echo "render: no page called $page" >&2; exit 1 ;; esac
  for frame in ${FRAMES:-still}; do
    case $frame in still) name=$page tick=nil ;; *[!0-9]*) echo "render: a frame is a number" >&2; exit 1 ;; *) name=$(printf '%s-%04d' "$page" "$frame") tick=$frame ;; esac
    rm -rf "${work:?}/wtf" && mkdir "$work/wtf"
    { printf 'RQ_STEP, RQ_X, RQ_Y, RQ_ITEM, RQ_FRAME, RQ_SAMPLE = "%s", %d, %d, %s, %s, %s\n' "$page" "$X" "$Y" "${ITEM:-nil}" "$tick" "$sample"; cat tools/render/shims.lua "${TOUR:-tools/render/tour.lua}"; } >"$work/$page.lua"
    # A page takes about a minute on the CPU at 4K, four at a time; one the simulator hasn't finished in
    # five has hung, and is stopped so it can't hold a film up.
    status=0
    sim timeout --kill-after=10 300 "$bin/wow-sim" --allow-ui-version-mismatch --addons-path "$work/AddOns" --session-wtf-path "$work/wtf" \
      --exec-lua "@$work/$page.lua" screenshot --png -o "$work/full.png" --width "$W" --height "$H" --ui-scale "$uiScale" \
      >"$work/$page.log" 2>&1 || status=$?
    if [ "$status" -ne 0 ]; then
      if [ "$status" -eq 124 ] || [ "$status" -eq 137 ]; then echo "$name: the simulator hung, stopped after 5 minutes" >>"$OUT/errors.txt"
      else echo "$name: the simulator failed" >>"$OUT/errors.txt"; tail -3 "$work/$page.log" >>"$OUT/errors.txt"; fi
      continue
    fi
    area=$crop
    [ "$page" = minimap ] && area=$(awk -v u="$uiScale" -v w="$W" 'BEGIN { printf "%d:%d:%d:0", 330 * u, 290 * u, w - 330 * u }') # the top right corner
    ffmpeg -v error -y -i "$work/full.png" -vf "crop=$area" "$OUT/$name.png"
    [ -n "${FULL:-}" ] && cp "$work/full.png" "$OUT/$name-full.png"
    # Lua errors, less Blizzard's own that the simulator always raises (its social toasts).
    grep -hE '^(Lua error:|\[exec-lua\] error:)' "$work/$page.log" | grep -v 'SocialToast\|Blizzard_ScriptErrors' | sort -u | sed "s/^/$name: /" >>"$OUT/errors.txt" || true
  done
done
cd "$here"
echo "Rendered ${#PAGES[@]} pages at ${W}x${H}, UI scale $SCALE: $OUT"
if [ -s "$OUT/errors.txt" ]; then echo "Lua errors:" >&2; cat "$OUT/errors.txt" >&2; exit 1; fi
