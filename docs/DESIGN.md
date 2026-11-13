# The /rq window's design

How Reliquary's window looks, moves and is built. The window is meant to show the best a WoW
addon can be: its own look and sleek motion on every page, finished to a high grade. This replaces
the earlier direction (Blizzard's stock panel templates, restyled as little as possible). A new page or
control is designed from this file, and judged by its render beside the pages already built.

What stays from before: every feature, every word a player reads (plain words, the game's own),
every privacy rule, simple and clutter free (no setup, no new tabs, no placeholders), and the
game's own art wherever the game has it (item icons, class icons, class and talent paintings,
coin icons). The game's tooltip and the minimap button keep the game's look: they sit among
other addons' and must match them.

## 1. The look: a moonlit shrine

Reliquary's mark is a gold shrine arch around a moon on a night sky, and its website is warm
ink, gold and parchment. The window is that place: dark warm ink surfaces, thin gold lines,
parchment text, one cool moonlight accent. Depth comes from layers (a shadow under the window,
cards above the page, paintings behind glass), never from heavy bevels. Nothing glows that
isn't being touched or isn't new.

### Colour (sRGB, the website's own values)

| Token | Hex | Used for |
|---|---|---|
| ink.950 | 0A0807 | the list rail, recessed wells, empty slots |
| ink.900 | 0F0C0A | the window's body |
| ink.850 | 15110E | the top bar, cards |
| ink.800 | 1B1612 | a card's header band, a hovered row |
| ink.700 | 2B231C | a pressed control, a bar's track |
| ink.600 | 3A2F25 | a card's border, dividers |
| ink.500 | 4A3D30 | a control's border |
| gold.100 | FAECC9 | the hero's name, the brightest highlight |
| gold.200 | F3D693 | titles, the chosen tab's text |
| gold.300 | ECBE5B | the selection marker, a bar's fill, a ticked box |
| gold.400 | E8A13A | section labels |
| gold.500 | D4842A | the window's border line |
| gold.600 | B3661F | a border in its resting state |
| parchment | F5ECD9 | body text |
| parchment.muted | CDBFA6 | second lines, values' labels |
| parchment.dim | A4977E | third lines, times, hints |
| parchment.faint | 8B7E6D | disabled text |
| moon | BACCEC | keyboard focus, the moon's glow, "new" |
| verdant | 5FB87A | done, online, ready |
| ember | D4542B | danger, hated, can't |

The game's own colours keep their meaning and are never replaced: item quality, class, quest
difficulty, reputation standing, chat channels, money. Text on a game surface (the game's
tooltip, chat) keeps the game's colours (`ns.GOLD` and the rest).

### Type

The client's own font files, so every script the game can show still shows: sizes are made from
the file `GameFontNormal` uses (Friz Quadrata on Latin clients) and chat bodies stay
`ChatFontNormal`. Section labels and the wordmark are Cinzel (the website's display face, OFL,
shipped in `Media/`), used only for Reliquary's own fixed English labels, never for a player's
name or anything a player typed.

| Role | Size | Colour | Notes |
|---|---|---|---|
| display | 24 | gold.100 | the hero's name; shadow 1,-1 black 80% |
| title | 16 | gold.200 | a tab's header, an item's name |
| heading | 13 | parchment | a card's own title, a list row's name |
| body | 12 | parchment | |
| small | 10.5 | parchment.muted or .dim | second lines |
| label | 10 | gold.400 | Cinzel, upper case; a card's section label |
| numeral | 12 or 20 | parchment | right-aligned in a fixed width so columns line up |
| plate | 9 | parchment | a number on a slot's plate |

No outlines. One shadow style (1,-1, black 80%) on text over paintings only. A font object brings
its own alignment: set it again after `SetFontObject` (`setFont`).

### Space and shape

A 4-unit grid: gaps are 4, 8, 12, 16 or 24. Corners: window 8, card 6, control 4, pills and
avatars round. Lines are one physical pixel (`PixelUtil`), never one unit. Every surface is
drawn from Reliquary's own art in `Media/` (built from `brand/ui/*.svg` by
`tools/build-art.sh`, at four pixels a unit so it is sharp at 4K), nine-sliced so corners never
stretch. Big surfaces are opaque art, not see-through colour: the page must look the same in
the game and in a render (the simulator blends see-through colour brighter than the game does).

Nothing coloured is drawn under an opaque fill. The game fades each texture of a fading frame
by itself, so whatever lies under a fill shows through it while the window opens, a page
arrives or a row fades in. A line round a surface is the ring over its fill (`Skin.surface`),
never a larger disc under it. A dark layer under a fill (a bar's track) is the one exception:
it only darkens the fill a little mid-fade.

An item's icon is cut in from its edge (the game bakes a bevelled border into every icon) and
masked to the slot's rounded square, so the slot's own line is the only frame it has.

## 2. Motion

Motion says where things came from and what changed; it never makes the player wait. Nothing
blocks a click: a tween that is still running is finished or retargeted by the next action.

All of it runs on Reliquary's own clock (`Motion.lua`): one ticker frame's `OnUpdate`, tweens
with easing over plain numbers (alpha, offset, scale, size, colour, a bar's value, a counted
number). The ticker runs only while something is moving or an ambient effect is on screen, and
never while the window is hidden. The clock can be stepped by hand (`ns.Motion.step(dt)`), which
is how the tests check end states and how `tools/film.sh` films the window frame by frame.
With "Animations" off (Sharing tab), and in the tests unless a test asks, every tween lands on
its end state at once: the layout a test measures is always the finished one.

| Token | Value | For |
|---|---|---|
| fast | 0.10 s | hover, press |
| base | 0.18 s | tabs, selection, a page arriving |
| slow | 0.28 s | the window opening, an accordion |
| long | 0.45 s | bars filling, numbers counting, the hero's painting |
| stagger | 0.025 s an item, 10 items at most | lists and cards arriving |
| ease.out | cubic out | the default |
| ease.enter | quart out | things arriving |
| ease.ambient | sine in-out | anything that loops |
| ease.pop | back out, overshoot 1.4 | only the tick in a box and a switch's knob |

The moments, all of them:

1. **Opening**: the window fades in, rises 12 units and grows from 0.96, 0.28 s, with its shadow.
   A line of light crosses the top border once. Then the list's rows, the hero's lines and the
   page's cards arrive in order (fade and rise 8, staggered).
2. **Closing** (the X, `/rq`, Escape): fades and sinks to 0.98 in 0.12 s, then hides. Escape works
   through a hidden stand-in in `UISpecialFrames`, so the game's own close-on-Escape still runs.
3. **Changing tab**: the gold marker under the tabs slides to the new one and changes width
   (0.18 s). The old page fades out (0.08 s); the new one fades in and slides 16 units from the
   side it lies on.
4. **Choosing a row**: the gold bar at the row's left edge glides to it. The hero's painting
   cross-fades (0.45 s); its lines and the page arrive as in 1.
5. **Hover**: a row's background, a button's border and a slot's glow fade in 0.10 s; an item
   slot and a talent grow to 1.06. Pressing sinks a control one unit.
6. **Bars and numbers**: a bar fills from empty and a headline number counts up from zero when
   its page arrives (0.45 s, staggered). A value that changes while showing moves from the old
   one, never from zero.
7. **Opening and folding** (timeline stops, recipe groups): height eases (0.28 s), the content
   fades.
8. **An item's page**: slides in from the right over the tab; Back and Escape slide it away to
   the right.
9. **A new chat line**: fades in and rises 8 units; the list follows it down only if it was
   already at the bottom.
10. **Ticks and switches**: a tick pops in (ease.pop); a switch's knob slides and its track
    warms to gold.
11. **Ambient**, all slow and small: the hero's painting drifts (scale 1.00 to 1.04 over 24 s and
    back) and leans up to 6 units toward the cursor; the moon in the crest breathes (alpha,
    4 s). Nothing else moves by itself.

## 3. The window

960 by 640 units, movable by its top bar, kept on screen, remembered where it was left. A grip
in the bottom right corner scales the whole window between 0.75 and 1.25 (remembered;
double-click sets it back to 1). Named `ReliquaryFrame`, at the game's panels' level.

```
+----------------------------------------------------------------------------------+
| (crest) RELIQUARY   Characters  Guild  Guild Bank  Friends  Public     Sharing  X |  top bar, 46
|                     =========                                                    |  gold marker under the chosen tab
+--------------------+-------------------------------------------------------------+
| header: title,     |  hero: the class's painting edge to edge, 124 tall           |
| counts, a filter   |  (class crest) Name                               chips       |
| [ search         ] |  level race class . <guild> rank . saved when                |
| rows ...           +-------------------------------------------------------------+
|                    |  Gear  Talents  Bags  Bank  Reputation  Quests  Timeline ...  |  page tabs, 32
|                    +-------------------------------------------------------------+
|  rail, 248         |  the page: cards on the body                                 |
+--------------------+-------------------------------------------------------------+
```

- **Body**: ink.900, a faint field of stars (the logo's sky, 4% at most) and a soft dark vignette
  at the edges, one gold.500 pixel line all round with slightly brighter corners, a wide soft
  shadow under it.
- **Top bar**: ink.850, a gold.600 pixel line under it. The crest is the portrait art, 32 units,
  left; then the wordmark RELIQUARY (label face, 13, gold.200). The tabs are text (heading size):
  parchment.muted, parchment on hover, gold.200 when chosen, parchment.faint when they have
  nothing to show (the reason on hover, as now). Sharing sits apart at the right, before the
  close button: it is the settings. The close button is a thin X that warms to gold on hover.
  The buttons keep the names `ReliquaryFrameTab1` to `6`.
- **Tab header**: what was in the old top band (a tab's title, its counts, its switch) heads the
  rail: title size, one small line of counts under it, the filter switch as a small pill.
- **Rail**: ink.950 well, 248 wide, a pixel line on its right. The search field, then the list.
- **Scroll bars**: a thin thumb (4 units, ink.500, gold.600 on hover) with no arrows; it shows only
  when the list is longer than its space. Scrolling eases.

## 4. The pieces (`Skin.lua`)

Each is one function that returns a frame with a small, documented set of fields. Pages are made
of these and nothing else: a page that needs something new adds it here, for every page.

| Piece | What it is |
|---|---|
| `card(parent, label)` | ink.850 surface, ink.600 pixel border, corner 6, an optional label (label face) with a pixel line under it; `card.body` is where content goes, padded 12 |
| `well(parent)` | a recessed ink.950 surface with an inner shadow: the rail, slot grids, the chat's entry |
| `tabs(parent, size)` | text tabs with the sliding gold marker; used for the window's tabs and a character's pages; hidden tabs take no room |
| `row(button)` | a list row, 40 tall: avatar (class icon in a thin ring, a presence dot on its lower right), name (heading, class colour), second line (small), level at the right, Reliquary's mark for a player who shares; hover fill; the chosen row keeps a fill and the gliding gold bar |
| `sectionRow` | a list's heading: label face, a pixel line running to the right edge |
| `slot(parent, size)` | an item's icon, cut in from its baked border and without the game's own quality frame, in a rounded frame whose line and quiet outer glow take the quality colour of an uncommon or better item (a quiet line for any other); count at the lower right, or a small dark plate there for a number that is the item's own (`slot:SetPlate`); the upgrade arrow; an empty slot is a quiet well with the slot's own silhouette where the game has one |
| `niche(parent, width, height, plinth)` | a tall recess under a round arch with moonlight in it and a plinth at its foot: where a crest or a model stands |
| `bar(parent)` | a progress bar, 6 or 10 tall: ink.700 track, a filled part with a soft bright leading edge, any colour (gold by default, the game's standing colours for reputation); `bar:set(value, max)` animates |
| `chip(parent)` | a small pill: an icon and a short value (a place, gold, time played, "Ready to turn in") |
| `button(parent, kind)` | `primary` (gold line, gold text), `quiet` (ink.500 line), `icon`; hover and press states |
| `switch(parent)` | a pill switch for the big choices on Sharing |
| `check(parent)` | a small box with a gold tick, for the sharing grid and filters |
| `search(parent)` | the search field: a magnifier, the hint in parchment.dim, a moon-coloured line while focused, a clear button once it has text |
| `dropdown(parent)` | the chat filter: a quiet button that opens the game's own menu |
| `scroll(parent)` | a scrolling list (the game's ScrollBox underneath) with the thin bar and eased scrolling |
| `avatar(parent, size)` | a class icon (or any icon) masked round in a thin ring |
| `divider(parent)` | a pixel line; `ornament = true` puts the small arch mark at its middle (one per page at most) |
| `tip(owner, title, lines)` | Reliquary's own hover text keeps using the game's tooltip |

States every control has: resting, hover, pressed, chosen, disabled, and keyboard focus for fields.

## 5. The pages

Each list page is rail + hero + page tabs + page. The hero and page tabs are the same on
Characters, Guild, Friends and Public.

**Hero** (124 tall): the class's dressing-room painting edge to edge (as now), darkened toward
the left so the text reads and faded into the body at its bottom edge. Left: the class crest in
a 56-unit ring. Name in display; under it level, race and class in body; guild and rank in the
game's guild colour; then how it reached you ("Saved 21 h ago", "Shared with your guild")
in small. Right, bottom-aligned: chips for where they are, gold and time played, each only
when it is shared. A player who doesn't share has the same hero with what the roster says.
Someone whose class isn't known (whispered, never seen sharing) has the hero without a painting
or crest: the name starts where the crest would.

**Gear**: the paper doll, read at a glance.
```
| slot  name          |   .-''-.    |          name  slot |  +-- card: sheet --------+
| slot  name          |  /  crest \  |          name  slot |  | PROFESSIONS (bars)     |
|  ... 8 rows,        |  | or the |  |                ...  |  | GENERAL                |
|      46 apart       |  | model  |  |                     |  | ATTRIBUTES ...         |
|                     |  |--------|  |                     |  | scrolls inside itself  |
|                     |  | ITEM   |  |                     |  |                        |
|                     |  | LEVEL  |  |                     |  |                        |
|  [main] name   [off] name   [ranged] name                |  +------------------------+
```
Each slot carries its item's level on a small dark plate at its lower right, and beside it the
item's name in its quality colour (two lines at most, centred on the slot; the right column's
names are right-aligned toward their slots); an empty slot shows only its silhouette. Between
the columns stands a niche (`Skin.niche`): a tall recess under a round arch, the shape of
Reliquary's own mark, with a soft moonlight in it. In it stands the class's crest in a gold
ring; for the character being played right now the game's own model of them stands there
instead (`PlayerModel`, `SetUnit("player")`), turned by dragging, and the crest comes back if
the game gives no model. On the niche's plinth: the item level (label, then a 20 numeral that
counts up). The sheet is one card at the right: professions first, each with a bar and
"64 / 75", then the stat groups as label and value rows with a pixel line between groups.

**Talents**: three cards side by side, each a tree on its classic painting (cropped, never
stretched) with the tree's name and points in the card's header. A learned talent is in full
colour with its rank ("3/5") on a small plate; one not learned is grey and dim. Arrows as now.
Legacy talents are a fourth, short card under them. Talents arrive row by row.

**Bags, Bank**: each bag is a card: its icon, its name and "12 / 16" in the header, its slots in a
grid of wells (40 units). Cards flow left to right and wrap. The line of totals is a chip row at
the foot of the page. As built: a bag's header is two lines (its name over its count), so a long name isn't cut; an empty slot is a plain well; a stack's count sits on the slot's plate.

**Reputation**: a card for each group (Alliance, and so on), two columns of cards when there are
enough. Each faction is one row: name, a bar in the game's colour for that standing, the standing
at the right. Bars fill as the page arrives. As built: a faction's name and standing share a line over its bar (side by side, a half-width card cut long names), and each card goes to the column that is shorter so far.

**Quests**: a card for each zone. Each quest: its level on a small plate in the game's difficulty
colour, its title, then its objectives in small with a thin bar beside any that counts ("6/8");
"Ready to turn in" is a verdant chip at the right. As built: one column of full-width cards; the difficulty colour is on the level's plate, the title in parchment.

**Timeline**: a pixel line runs down the left with a small gold ring at each stop. Each stop is
a card: the zone (title), the day and hours at the right, its facts as chips. Opening a stop eases
its height open to show its lines. "Before Reliquary" is the last card, with its groups folding
the same way.

**Recipes**: left, the professions as cards with a bar each and their recipes as rows (icon,
name in quality colour); right, the chosen recipe's schematic card: big icon, name, reagents as
slots with "have / need". As built: a click on a profession's header folds its card away and opens it again.

**Roleplay**: one reading card, generous line spacing, the fields' names as section labels.

**Whispers, Guild Chat, Officer Chat**: a conversation: day dividers as centred small pills; each
speaker's lines grouped under their avatar, name (class colour) and time (parchment.dim); bodies
in the chat's own font and colours; the entry field is a well with a quiet send hint. The search
field and the filter sit above it. As built: a conversation shorter than the page sits on its entry box, as a chat does; a speaker's avatar is 32 units; the search and filter hide until something has been said; someone on the guild's Discord with no character the game knows gets the game's Discord mark.

**Guild Bank**: the bank's tabs as icon buttons down the right, the chosen one ringed in gold. The
slots are one card of wells. Items, Log and Gold log are text tabs with the marker. Under the
slots: the latest moves as a card, and a foot row with the bank's gold as a chip and what your
rank may take in small.

**Sharing**: left, the three big choices as switches with a title and one line each, then the
smaller switches. Right, a card "What each sees": the grid of ticks (Guild, Friends, Public
across; parts down), then Items. One new switch, with the others: "Animations".

**An item's page**: a header band with the item in a 56-unit slot, its name in title size and
quality colour, and Back as a quiet button with a chevron. Under it two columns of cards, as now:
what it is (the tooltip's lines, Auction, Sell Price, Made with, Used to make) and who (Who can
use it, Made by, Used by, Can be learned by, Where it comes from). As built: the cards are sized to what they hold, the two addresses on a card of their own under the left column; the page slides in from the right over its tab, which hides once covered.

**Public**: its look-up field and button head the rail. As built: the look-up field's hint is the game's own word for a name's field (`NAME`).

## 6. How it is built

| File | Holds |
|---|---|
| `Motion.lua` | the clock, tweens, easing; `ns.Motion` |
| `Skin.lua` | colours, fonts, art, the pieces; `ns.Skin` |
| `Media/` | `ui-*.tga` (built by `tools/build-art.sh` from `brand/ui/`), Cinzel and its licence |
| `Viewer.lua` | the window: frame, top bar, tabs, panels, opening and closing, the item page's place |
| `ViewerParts.lua` | words (ago, money), item buttons and tips, what pages share |
| `ViewerDetail.lua` | a player's page: hero, page tabs, Gear, Roleplay |
| `ViewerTalents.lua`, `ViewerBags.lua`, `ViewerJournal.lua` (Reputation, Quests), `ViewerTimeline.lua`, `ViewerRecipes.lua` | one page each |
| `ViewerChat.lua` | conversations |
| `ViewerLists.lua` | the rail, and the Characters, Guild, Friends and Public tabs |
| `ViewerBank.lua`, `ViewerSharing.lua`, `ViewerItem.lua` | those tabs and the item's page |

Shared values travel on `ns.V` (a file-level local in each file), never as globals.

Rules for the code:
- Check every game call against Blizzard's own code for this build before using it
  (`~/.cache/reliquary/wow-ui-source`, branch `forever`), and add the widget types it uses to
  `tests/widget_api.lua` with `tools/build_widget_api.py`.
- No colour, size or duration is typed into a page: they come from `Skin` and `Motion`.
- Nothing in the addon knows it is being rendered or tested. What the simulator lacks is filled
  in `tools/render/shims.lua` (it reads colours set from code as linear light: the shim converts
  them, so a render shows the game's colours).
- The window costs nothing while hidden: no `OnUpdate`, no timers.
- Opening the window in combat works as before; nothing here is a protected frame.

## 7. Looking at it

- `tools/render.sh` draws every page (on the CPU while WoW runs). `SAMPLE=1` uses the made-up
  players. Judge a change by its render at the player's window size, zoomed in on the part that changed.
- `tools/film.sh` films the motion: it steps the clock a frame at a time and renders each, then
  joins them (60 fps). Shots: opening, changing tab, choosing a row, a page's bars, an item's
  page, a switch.
- `/rq tour` in the game walks every page and takes the game's own screenshot of each
  (`Screenshot()`), for what the simulator can't draw: the model, coin icons.
- The game is the last word on feel.
