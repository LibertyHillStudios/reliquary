#!/usr/bin/env bash
# Every file the released addon holds, one per line, as its path inside the Reliquary folder: its
# table of contents, every file the TOC lists, its pictures (Media), and the changelog, licence and
# notice from the top of the repository. tools/package.sh checks the CurseForge zip against this
# list and tools/playtest.sh lays a test build out from it, so the two never disagree.
set -euo pipefail
cd "$(dirname "$0")/.."
{
  printf '%s\n' CHANGELOG.md LICENSE NOTICE Reliquary.toc
  (cd addon/Reliquary && find Media -type f)
  sed -n 's/^\([A-Za-z_]*\.lua\)$/\1/p' addon/Reliquary/Reliquary.toc
} | sort
