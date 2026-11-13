# Contributing to Reliquary

Thanks for helping. Reliquary is made by [Liberty Hill Studios](https://libertyhillstudio.com),
and bug reports, ideas and pull requests from players are welcome.

## Reporting a bug

Open an issue with the bug form. Say which version of Reliquary you have (the CurseForge app shows
it, as does the `## Version:` line of `Reliquary.toc`), what you did and what happened. If the game
showed a Lua error, paste it; the game also writes every Lua error to `_forever_/Logs/General.log`.

Rather email? Send bug reports and suggestions to
[support@libertyhillstudio.com](mailto:support@libertyhillstudio.com).

## Pull requests

- Run `tools/test.sh` before you send one. A new test should fail with the change taken out.
- Before calling a game function, check that it exists and isn't protected on WoW: Forever, in
  Blizzard's own code for the build (the `forever` branch of
  [Gethe/wow-ui-source](https://github.com/Gethe/wow-ui-source)).
- Reliquary never presses a key or acts in the game: no synthetic input and no protected calls.
- Sharing is the player's choice. Nothing new is shared unless the player turns it on, and chat
  and whispers are never sent.
- Words a player reads say it the way the game would: plain, short, no invented phrases.
- The window's look and motion are in [docs/DESIGN.md](docs/DESIGN.md): build new pages from
  `Skin.lua`'s pieces and `Motion.lua`'s clock.

This repository is published from the studio's working copy with each release, so an accepted pull
request is applied there and arrives here with the next version, credited in `CHANGELOG.md`.

By sending a pull request you agree that your contribution is licensed under the Apache License
2.0, as section 5 of the [License](LICENSE) says.
