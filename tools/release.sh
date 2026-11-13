#!/usr/bin/env bash
# Releases the addon: checks everything, then tags this version and pushes the tag, which makes
# the release workflow build the zip and upload it to CurseForge (.github/workflows/release.yml). Run it from
# an up-to-date main, after raising the TOC's version and writing its CHANGELOG.md entry.
#
#   tools/release.sh 1.3.0
set -euo pipefail
cd "$(dirname "$0")/.."
version="${1:?usage: tools/release.sh <version>, as the TOC has it}"
toc=addon/Reliquary/Reliquary.toc
fail() { echo "Not released: $*" >&2; exit 1; }

[ "$(git rev-parse --abbrev-ref HEAD)" = main ] || fail "release from main."
[ -z "$(git status --porcelain)" ] || fail "commit or put away the changes first."
git fetch -q origin main
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || fail "main isn't the same as origin/main."
[ "$(sed -n 's/^## Version: //p' "$toc" | tr -d '\r')" = "$version" ] || fail "the TOC's version isn't $version."
grep -q "^## $version " CHANGELOG.md || fail "CHANGELOG.md has no entry for $version."
! git rev-parse -q --verify "refs/tags/v$version" >/dev/null || fail "v$version is already tagged."
grep -q '^## X-Curse-Project-ID: [0-9]' "$toc" || echo "Note: no X-Curse-Project-ID in the TOC yet, so the release is built and attached to GitHub but not uploaded to CurseForge."

tools/test.sh
tools/package.sh
# The source published for everyone holds nothing private (in the studio's own checkout).
if [ -x tools/export-public.sh ]; then
  check=$(mktemp -d)
  tools/export-public.sh "$check" >/dev/null
  rm -rf "${check:?}"
fi
git tag -a "v$version" -m "Reliquary $version"
git push origin "v$version"
echo "Tagged and pushed v$version. The release workflow builds and uploads it: gh run watch"
