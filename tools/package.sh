#!/usr/bin/env bash
# Builds the addon's CurseForge zip exactly as a release does (BigWigs' packager, pinned, with this
# repository's .pkgmeta), uploads nothing, and checks the zip holds the addon and nothing else.
# It packages the commit checked out here, never uncommitted edits: from a clone of its own at that
# commit, which the packager needs anyway when this is a git worktree (whose .git is a file).
#
#   tools/package.sh            # .release/Reliquary-<version>.zip
set -euo pipefail
cd "$(dirname "$0")/.."
REF=01e8631a69c69d7654c788d152630d5fed9e3812 # github.com/BigWigsMods/packager, 2026-11-04 (release.yml pins the same)
cache="${XDG_CACHE_HOME:-$HOME/.cache}/reliquary/packager"
if [ "$(git -C "$cache" rev-parse HEAD 2>/dev/null)" != "$REF" ]; then
  rm -rf "${cache:?}"
  git clone -q https://github.com/BigWigsMods/packager "$cache"
  git -C "$cache" checkout -q "$REF"
fi
commit=$(git rev-parse HEAD)
if [ -n "$(git status --porcelain)" ]; then echo "Packaging ${commit:0:7}: uncommitted changes are left out." >&2; fi
work=$(mktemp -d)
trap 'rm -rf "${work:?}"' EXIT
git clone -q --no-checkout "$PWD" "$work/Reliquary"
git -C "$work/Reliquary" checkout -q "$commit"
rm -rf .release
# -d: never upload, whatever tokens are set.
env -u CF_API_KEY -u GITHUB_OAUTH -u WOWI_API_TOKEN -u WAGO_API_TOKEN \
  bash "$cache/release.sh" -d -t "$work/Reliquary" -r "$PWD/.release" >.release.log 2>&1 || { cat .release.log >&2; rm -f .release.log; exit 1; }
rm -f .release.log
zip=$(ls .release/*.zip)
files=$(unzip -Z1 "$zip" | grep -v '/$' | sort)
expected=$(tools/addon-files.sh | sed 's|^|Reliquary/|' | sort)
if [ "$files" != "$expected" ]; then
  echo "The zip doesn't hold exactly the addon:" >&2
  diff <(echo "$expected") <(echo "$files") >&2 || true
  exit 1
fi
version=$(unzip -p "$zip" Reliquary/Reliquary.toc | sed -n 's/^## Version: //p' | tr -d '\r')
echo "$zip: Reliquary $version, $(echo "$files" | wc -l) files, $(du -h "$zip" | cut -f1)"
