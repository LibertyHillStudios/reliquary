-- Reliquary's look: the colours, type, spacing and art of the /rq window (docs/DESIGN.md, sections 1
-- and 4), and the pieces every page is made of. Each piece is one function returning a frame with a
-- few documented fields; a page that needs something new adds it here, for every page.
--
-- Tokens
--   Skin.C[name]                 a colour {r, g, b} (DESIGN section 1; names below)
--   Skin.rgb(name)               r, g, b of a colour;  Skin.code(name): "|cffRRGGBB" for text
--   Skin.SPACE                   the 4-unit grid: xs 4, s 8, m 12, l 16, xl 24
--   Skin.RADIUS                  corners: window 8, card 6, control 4
--   Skin.font(role, over)        a font object: display, title, heading, body, small, dim, faint,
--                                label, numeral, numeralBig, wordmark (over = true: over a painting,
--                                with the one shadow style)
--   Skin.text(parent, role, justify, over, layer)   a font string in a role, on one line until the
--                                page turns wrapping on (SetWordWrap)
--   Skin.setRole(fs, role, justify, over)   put a font string in a role (its alignment set again after)
--   Skin.label(fs, text)         a section label's words (Cinzel, upper case)
--   Skin.pixel(region)           one physical pixel in region's units (PixelUtil)
--   Skin.refresh()               pixel lines and corner art follow a change of scale
-- Art
--   Skin.nine(parent, art, opts) nine textures as one surface: art "disc" (any rounded rectangle),
--                                "ring" (its one-pixel outline), "shadow", "inset" (a well's inner
--                                shadow), "glow" (a slot's glow);
--                                opts: radius, layer, sub, color, alpha, blend, rect, inset, px,
--                                square = { tl, tr, bl, br }. Returns n with n:SetColor(r, g, b, a),
--                                n:SetAlpha(a), n:SetShown(v), n:Layout(), n.tex
--   Skin.surface(parent, opts)   a filled rounded rectangle with a one-pixel line round it:
--                                opts.fill, opts.line, opts.radius, opts.layer, opts.sub (the line
--                                takes sub + 1), opts.square (unlined only)
--   Skin.line(parent, color, opts)   a line one physical pixel thick (opts.vertical, layer, sub)
--   Skin.glyph(parent, name, size, color, layer)   a small glyph: close, chevronRight, chevronLeft,
--                                chevronDown, chevronUp, magnifier, plus, minus, clear, grip, tick,
--                                arch, dot
--   Skin.band(parent, inner, opts)   a round band from a hole `inner` units across out to the
--                                parent's edge (opts.color, layer, sub): a ring thicker than a line
--   Skin.tint(obj, key, color, dur) a colour moved over fast time from where it last was (key "text":
--                                a text's colour; a nine or a texture otherwise)
--   Skin.qualityColor(q)         r, g, b of an item quality
-- Pieces (DESIGN section 4): each returns a frame (or, for row and sectionRow, dresses the list's own)
--   card(parent, label, band)    .body (padded 12, under the label), :SetLabel(text); S.CARD_HEAD 28
--   well(parent, opts)           a recessed floor (opts.flat: no inner shadow; opts.square, radius)
--   tabs(parent, kind)           kind "window" or "page": :Add(key, label, name, right), :Layout(x, y,
--                                rightX), :Select(key, instant), :SetEnabled(key, on), .onSelect(key)
--   row(button)                  a list row, S.ROW 40 tall: .avatar, .class (its icon), .dot, .name,
--                                .info, .level, .gem, .fill, .bar, :SetChosen(v), .inert (a heading)
--   glide(button, fromTop)       the chosen row's bar glides from where the last one was
--   sectionRow(button)           a list heading, S.ROW_HEAD 28: .title (Skin.label it), .rule
--   slot(parent, size)           an item's button in a rounded frame: :SetQuality(q, filled); V.itemButton
--                                (parent, size) gives it the item clicks and tips
--   bar(parent, height)          :Set(value, most, { from, delay, instant }), :SetColor(color)
--   chip(parent)                 :Set(text, icon, isAtlas, color); .width
--   button(parent, kind)         "primary", "quiet" or "icon": :SetText(t), :SetGlyph(name, size)
--   switch(parent), check(parent)   CheckButtons: :SetChecked(v) moves them, a click switches them
--   search(parent, hint)         an EditBox: .onChange(text), .clear, .hint, .glass, .focus
--   dropdown(parent)             the game's DropdownButton: :SetupMenu(generator), :SetText(t)
--   scroll(parent, opts)         list, bar: opts.frameType, init, extent(line), left, top, right, bottom,
--                                fade (units its rows fade over at an edge with more beyond it)
--   thinBar(bar)                 the game's MinimalScrollBar drawn thin, no arrows
--   avatar(parent, size)         :SetClass(classFile), :SetIcon(icon, isAtlas), :SetRing(color),
--                                :SetDimmed(v), :SetPresence(nil | true | false); .icon, .dot
--   divider(parent, ornament)    a pixel line, the shrine's arch at its middle with ornament
--   tip(owner, title, lines)     the game's tooltip, a white title and gold lines
local ADDON, ns = ...

local S = {}
ns.Skin = S
local Motion = ns.Motion

local type, pairs, ipairs, tostring = type, pairs, ipairs, tostring
local floor, min, max, format = math.floor, math.min, math.max, string.format

local MEDIA = "Interface\\AddOns\\Reliquary\\Media\\"

---------------------------------------------------------------------------
-- Tokens
---------------------------------------------------------------------------
local function hex(h) return { tonumber(h:sub(1, 2), 16) / 255, tonumber(h:sub(3, 4), 16) / 255, tonumber(h:sub(5, 6), 16) / 255 } end
local C = {
    ink950 = hex("0A0807"), ink900 = hex("0F0C0A"), ink850 = hex("15110E"), ink800 = hex("1B1612"), ink700 = hex("2B231C"),
    ink600 = hex("3A2F25"), ink500 = hex("4A3D30"),
    gold100 = hex("FAECC9"), gold200 = hex("F3D693"), gold300 = hex("ECBE5B"), gold400 = hex("E8A13A"), gold500 = hex("D4842A"),
    gold600 = hex("B3661F"),
    parchment = hex("F5ECD9"), muted = hex("CDBFA6"), dim = hex("A4977E"), faint = hex("8B7E6D"),
    moon = hex("BACCEC"), verdant = hex("5FB87A"), ember = hex("D4542B"),
    black = { 0, 0, 0 }, white = { 1, 1, 1 },
}
S.C = C
S.SPACE = { xs = 4, s = 8, m = 12, l = 16, xl = 24 }
S.RADIUS = { window = 8, card = 6, control = 4 }

local function color(c)
    if type(c) == "string" then c = C[c] end
    return c or C.white
end
function S.rgb(name) local c = color(name) return c[1], c[2], c[3] end
function S.code(name)
    local c = color(name)
    return format("|cff%02x%02x%02x", floor(c[1] * 255 + 0.5), floor(c[2] * 255 + 0.5), floor(c[3] * 255 + 0.5))
end

-- Type: the client's own font (the file GameFontNormal uses, so every script it shows still shows) in
-- Reliquary's sizes, and Cinzel for Reliquary's own fixed labels; a Cinzel file that doesn't load
-- leaves the labels in the client's font.
local FRIZ = (GameFontNormal and GameFontNormal.GetFont and GameFontNormal:GetFont()) or "Fonts\\FRIZQT__.TTF"
local function loads(file)
    local probe = CreateFrame("Frame"):CreateFontString()
    local ok, loaded = pcall(probe.SetFont, probe, file, 10, "")
    return ok and loaded and true or false
end
-- Cinzel has Latin letters only, and a label can carry a word of the game's (a profession's name): a
-- client in a language written otherwise keeps its own font for the labels too.
local LATIN = { enUS = true, enGB = true, deDE = true, esES = true, esMX = true, frFR = true, itIT = true, ptBR = true, ptPT = true }
local function labelFace(file, locale)
    return LATIN[locale or "enUS"] and loads(MEDIA .. file) and MEDIA .. file or FRIZ
end
S.labelFace = labelFace
local locale = GetLocale and GetLocale() or "enUS"
local CINZEL = labelFace("Cinzel-Bold.ttf", locale)
local CINZEL_REGULAR = labelFace("Cinzel-Regular.ttf", locale)
S.CINZEL, S.CINZEL_REGULAR, S.FRIZ = CINZEL, CINZEL_REGULAR, FRIZ

local ROLES = {
    display = { FRIZ, 24, "gold100" }, title = { FRIZ, 16, "gold200" }, heading = { FRIZ, 13, "parchment" },
    body = { FRIZ, 12, "parchment" }, small = { FRIZ, 10.5, "muted" }, dim = { FRIZ, 10.5, "dim" }, faint = { FRIZ, 12, "faint" },
    label = { CINZEL, 10, "gold400" }, wordmark = { CINZEL, 13, "gold200" },
    numeral = { FRIZ, 12, "parchment" }, numeralBig = { FRIZ, 20, "parchment" }, plate = { FRIZ, 9, "parchment" },
}
local fonts = {}
function S.font(role, over)
    local key = role .. (over and "Over" or "")
    if fonts[key] then return fonts[key] end
    local r = ROLES[role] or ROLES.body
    local f = CreateFont("ReliquaryFont_" .. key)
    f:SetFont(r[1], r[2], "")
    f:SetTextColor(S.rgb(r[3]))
    -- One shadow style, on text over a painting only (and always on the hero's name).
    if over or role == "display" then
        f:SetShadowOffset(1, -1)
        f:SetShadowColor(0, 0, 0, 0.8)
    else
        f:SetShadowOffset(0, 0)
    end
    fonts[key] = f
    return f
end

-- A font object brings its own alignment (centred): the alignment wanted is set again after it.
function S.setRole(fs, role, justify, over)
    fs:SetFontObject(S.font(role, over))
    fs:SetJustifyH(justify or "LEFT")
end

function S.text(parent, role, justify, over, layer)
    local fs = parent:CreateFontString(nil, layer or "ARTWORK")
    S.setRole(fs, role or "body", justify, over)
    fs:SetWordWrap(false)
    return fs
end

function S.label(fs, text) fs:SetText(text and text:upper() or "") end

-- One physical pixel, in a region's own units: the game's own reckoning (PixelUtil).
function S.pixel(region)
    local factor = PixelUtil and PixelUtil.GetPixelToUIUnitFactor and PixelUtil.GetPixelToUIUnitFactor() or 1
    local scale = region and region.GetEffectiveScale and region:GetEffectiveScale() or 1
    return factor / max(scale, 0.01)
end

-- What follows a change of scale: pixel lines and the corner art chosen for the screen.
local refreshers = setmetatable({}, { __mode = "k" })
function S.refresh()
    for obj in pairs(refreshers) do obj:Layout() end
end

---------------------------------------------------------------------------
-- Art
---------------------------------------------------------------------------
-- Each nine-sliced art: its file, its size in pixels, its corner in pixels and in units, and how far
-- it reaches past the rectangle it surrounds (a shadow, a glow). The disc is every rounded corner, in
-- the smallest size that is never grown on the screen (16 to 256 pixels across), so corners are never
-- blurred by being grown or shrunk far. The ring is the disc's outline, one pixel on the screen: its
-- line is RING_WIDTHS[i] pixels of art wide, the one nearest what the art is shrunk by.
local ART = {
    shadow = { file = "ui-shadow", px = 256, corner = 64, units = 32, out = 24 },
    inset = { file = "ui-inset", px = 128, corner = 32, units = 8, out = 0 },
    glow = { file = "ui-glow-slot", px = 128, corner = 48, units = 12, out = 8 },
}
local DISCS = { 16, 32, 64, 128, 256 }
local RING_WIDTHS = { 1, 1.25, 1.5, 1.75 }

-- Where each glyph sits in ui-glyphs (64-pixel cells, four a row), and how it turns.
local GLYPH = {
    close = { 0, 0 }, chevronRight = { 1, 0 }, chevronLeft = { 1, 0, "h" }, chevronDown = { 2, 0 }, chevronUp = { 2, 0, "v" },
    magnifier = { 3, 0 }, plus = { 0, 1 }, minus = { 1, 1 }, clear = { 2, 1 }, grip = { 3, 1 }, tick = { 0, 2 }, arch = { 1, 2 },
    dot = { 2, 2 },
}

local Nine = {}
Nine.__index = Nine
local PIECES = { "tl", "t", "tr", "l", "c", "r", "bl", "b", "br" }

function Nine:SetColor(r, g, b, a)
    if type(r) ~= "number" then r, g, b = S.rgb(r) end
    self.color = { r, g, b }
    for _, t in pairs(self.tex) do t:SetVertexColor(r, g, b) end
    if a then self:SetAlpha(a) end
end
function Nine:GetColor() return self.color[1], self.color[2], self.color[3] end
function Nine:SetAlpha(a)
    self.alpha = a
    for _, t in pairs(self.tex) do t:SetAlpha(a) end
end
function Nine:SetShown(v)
    for key, t in pairs(self.tex) do t:SetShown(v and not (key == "c" and self.art == "ring")) end
end
function Nine:Show() self:SetShown(true) end
function Nine:Hide() self:SetShown(false) end

-- Places the nine pieces over the rectangle (opts.rect, else the parent), less its insets (units,
-- and opts.px physical pixels), past it by the art's reach; picks the disc for the screen.
function Nine:Layout()
    local o = self.opts
    local rect = o.rect or self.parent
    local art = self.art
    local px = (o.px or 0) * S.pixel(self.parent)
    local i = o.inset or 0
    local l, t, r, b
    if type(i) == "table" then l, t, r, b = i[1], i[2], i[3], i[4] else l, t, r, b = i, i, i, i end
    l, t, r, b = l + px, t + px, r + px, b + px
    local out, cs, file, size, corner
    if art == "disc" or art == "ring" then
        cs = max(0.01, (o.radius or S.RADIUS.control) - px)
        local onScreen = cs / S.pixel(self.parent)
        size = DISCS[#DISCS]
        for _, n in ipairs(DISCS) do if n / 2 >= onScreen then size = n break end end
        file, corner, out = "ui-disc-" .. size, size / 2, 0
        if art == "ring" then
            -- The art is shrunk by (size / 2) / onScreen: a line that many pixels of art wide is one
            -- pixel on the screen.
            local want, width = (size / 2) / max(onScreen, 0.01), RING_WIDTHS[1]
            for _, w in ipairs(RING_WIDTHS) do if math.abs(w - want) < math.abs(width - want) then width = w end end
            file = "ui-ring-" .. size .. "-" .. floor(width * 100 + 0.5)
        end
    else
        local a = ART[art]
        file, size, corner, cs, out = a.file, a.px, a.corner, a.units, a.out
    end
    local L, T, R, B = -out + l, out - t, out - r, -out + b
    local p = self.tex
    for _, key in ipairs(PIECES) do p[key]:ClearAllPoints() end
    p.tl:SetPoint("TOPLEFT", rect, "TOPLEFT", L, T)
    p.tr:SetPoint("TOPRIGHT", rect, "TOPRIGHT", R, T)
    p.bl:SetPoint("BOTTOMLEFT", rect, "BOTTOMLEFT", L, B)
    p.br:SetPoint("BOTTOMRIGHT", rect, "BOTTOMRIGHT", R, B)
    for _, key in ipairs({ "tl", "tr", "bl", "br" }) do p[key]:SetSize(cs, cs) end
    p.t:SetPoint("TOPLEFT", p.tl, "TOPRIGHT")
    p.t:SetPoint("BOTTOMRIGHT", p.tr, "BOTTOMLEFT")
    p.b:SetPoint("TOPLEFT", p.bl, "TOPRIGHT")
    p.b:SetPoint("BOTTOMRIGHT", p.br, "BOTTOMLEFT")
    p.l:SetPoint("TOPLEFT", p.tl, "BOTTOMLEFT")
    p.l:SetPoint("BOTTOMRIGHT", p.bl, "TOPRIGHT")
    p.r:SetPoint("TOPLEFT", p.tr, "BOTTOMLEFT")
    p.r:SetPoint("BOTTOMRIGHT", p.br, "TOPRIGHT")
    p.c:SetPoint("TOPLEFT", p.tl, "BOTTOMRIGHT")
    p.c:SetPoint("BOTTOMRIGHT", p.br, "TOPLEFT")
    if self.file ~= file then
        self.file = file
        local a, m0, m1 = corner / size, 0.5 - 0.5 / size, 0.5 + 0.5 / size
        local sq = o.square or {}
        local coords = {
            tl = sq.tl and { m0, m1, m0, m1 } or { 0, a, 0, a }, tr = sq.tr and { m0, m1, m0, m1 } or { 1 - a, 1, 0, a },
            bl = sq.bl and { m0, m1, m0, m1 } or { 0, a, 1 - a, 1 }, br = sq.br and { m0, m1, m0, m1 } or { 1 - a, 1, 1 - a, 1 },
            t = { m0, m1, 0, a }, b = { m0, m1, 1 - a, 1 }, l = { 0, a, m0, m1 }, r = { 1 - a, 1, m0, m1 }, c = { m0, m1, m0, m1 },
        }
        for key, tex in pairs(p) do
            tex:SetTexture(MEDIA .. file)
            tex:SetTexCoord(coords[key][1], coords[key][2], coords[key][3], coords[key][4])
        end
    end
end

function S.nine(parent, art, opts)
    opts = opts or {}
    local n = setmetatable({ parent = parent, art = art, opts = opts, tex = {} }, Nine)
    for _, key in ipairs(PIECES) do
        local t = parent:CreateTexture(nil, opts.layer or "BACKGROUND", nil, opts.sub or 0)
        if opts.blend then t:SetBlendMode(opts.blend) end
        n.tex[key] = t
    end
    n:Layout()
    if art == "ring" then n.tex.c:Hide() end
    n:SetColor(opts.color or "white")
    if opts.alpha then n:SetAlpha(opts.alpha) end
    refreshers[n] = true
    return n
end

-- A filled rounded rectangle with a line one physical pixel wide round it: the fill is the disc, the
-- line the ring over its edge. The game fades each texture of a fading frame by itself, so nothing is
-- drawn under the fill that its colour could show through. A lined surface keeps its corners round
-- (opts.square is for one without a line).
function S.surface(parent, opts)
    opts = opts or {}
    local layer, sub = opts.layer or "BACKGROUND", opts.sub or 0
    local s = { parent = parent }
    local radius = opts.radius or S.RADIUS.control
    local square = not opts.line and opts.square or nil
    s.fill = S.nine(parent, "disc", { radius = radius, layer = layer, sub = sub, color = opts.fill or "ink850", rect = opts.rect,
        inset = opts.inset, square = square })
    if opts.line then
        s.line = S.nine(parent, "ring", { radius = radius, layer = layer, sub = sub + 1, color = opts.line, rect = opts.rect, inset = opts.inset })
    end
    function s:SetFill(c, a) self.fill:SetColor(c) if a then self.fill:SetAlpha(a) end end
    function s:SetLine(c, a) if self.line then self.line:SetColor(c) if a then self.line:SetAlpha(a) end end end
    function s:SetShown(v) self.fill:SetShown(v) if self.line then self.line:SetShown(v) end end
    return s
end

-- A line one physical pixel thick, anchored by its caller along its length.
local Line = {}
Line.__index = Line
function Line:Layout()
    local px = S.pixel(self.tex)
    if self.vertical then self.tex:SetWidth(px) else self.tex:SetHeight(px) end
end
function S.line(parent, c, opts)
    opts = opts or {}
    local t = parent:CreateTexture(nil, opts.layer or "BORDER", nil, opts.sub or 0)
    t:SetTexture(MEDIA .. "ui-disc-16")
    t:SetTexCoord(0.47, 0.53, 0.47, 0.53)
    t:SetVertexColor(S.rgb(c or "ink600"))
    local l = setmetatable({ tex = t, vertical = opts.vertical }, Line)
    t.rqLine = l
    l:Layout()
    refreshers[l] = true
    return t
end

function S.glyph(parent, name, size, c, layer)
    local g = GLYPH[name] or GLYPH.dot
    local t = parent:CreateTexture(nil, layer or "ARTWORK")
    t:SetTexture(MEDIA .. "ui-glyphs")
    local u0, u1, v0, v1 = g[1] / 4, (g[1] + 1) / 4, g[2] / 4, (g[2] + 1) / 4
    if g[3] == "h" then u0, u1 = u1, u0 elseif g[3] == "v" then v0, v1 = v1, v0 end
    t:SetTexCoord(u0, u1, v0, v1)
    t:SetSize(size or 16, size or 16)
    t:SetVertexColor(S.rgb(c or "muted"))
    return t
end

-- A colour moved over time (hover, press), from where it last was: a surface's (a nine), a text's (key
-- "text") or a texture's.
local function tint(obj, key, to, dur)
    local c = color(to)
    local from = obj["rq" .. key] or c
    obj["rq" .. key] = c
    local nine = getmetatable(obj) == Nine
    Motion.to(obj, key, c, { from = from, dur = dur or "fast", set = function(o, v)
        if nine then o:SetColor(v[1], v[2], v[3]) elseif key == "text" then o:SetTextColor(v[1], v[2], v[3])
        else o:SetVertexColor(v[1], v[2], v[3]) end
    end, owner = nine and obj.parent or obj })
end
S.tint = tint

---------------------------------------------------------------------------
-- Pieces
---------------------------------------------------------------------------
-- A card: an ink.850 surface with a one-pixel ink.600 line round it, corner 6. With a label, the label
-- (Cinzel, upper case) over a pixel line; with band = true an ink.800 header band behind the label.
-- card.body is where its content goes, padded 12; card:SetLabel(text) changes or removes the label.
S.CARD_HEAD = 28
function S.card(parent, label, band)
    local f = CreateFrame("Frame", nil, parent)
    f.surface = S.surface(f, { fill = "ink850", line = "ink600", radius = S.RADIUS.card })
    if band then
        f.head = CreateFrame("Frame", nil, f)
        f.head:SetPoint("TOPLEFT")
        f.head:SetPoint("TOPRIGHT")
        f.head:SetHeight(S.CARD_HEAD)
        f.band = S.nine(f, "disc", { radius = S.RADIUS.card, layer = "BACKGROUND", sub = 2, color = "ink800", px = 1, rect = f.head,
            square = { bl = true, br = true } })
    end
    f.label = S.text(f, "label", "LEFT")
    f.label:SetPoint("TOPLEFT", 12, -10)
    f.label:SetPoint("RIGHT", -12, 0)
    f.rule = S.line(f, "ink600")
    f.rule:SetPoint("TOPLEFT", band and 0 or 12, -S.CARD_HEAD)
    f.rule:SetPoint("TOPRIGHT", band and 0 or -12, -S.CARD_HEAD)
    f.body = CreateFrame("Frame", nil, f)
    function f:SetLabel(text)
        S.label(self.label, text)
        self.label:SetShown(text ~= nil)
        self.rule:SetShown(text ~= nil)
        if self.band then self.band:SetShown(text ~= nil) end
        self.body:ClearAllPoints()
        self.body:SetPoint("TOPLEFT", 12, text and -(S.CARD_HEAD + 8) or -12)
        self.body:SetPoint("BOTTOMRIGHT", -12, 12)
    end
    f:SetLabel(label)
    return f
end

-- A well: a recessed ink.950 floor with an inner shadow, for slot grids and an entry box; flat (no
-- shadow), the rail. opts.radius (4), opts.square (which corners are square), opts.color, opts.flat.
function S.well(parent, opts)
    opts = opts or {}
    local f = CreateFrame("Frame", nil, parent)
    local radius = opts.radius or S.RADIUS.control
    f.floor = S.nine(f, "disc", { radius = radius, layer = "BACKGROUND", sub = 0, color = opts.color or "ink950", square = opts.square })
    if not opts.flat then f.shade = S.nine(f, "inset", { layer = "BACKGROUND", sub = 1, alpha = 0.9 }) end
    return f
end

-- An avatar: an icon (a class icon, or any) masked round in a thin ring; a presence dot on its lower
-- right when asked. av:SetClass(classFile), av:SetIcon(file or atlas, isAtlas), av:SetRing(color),
-- av:SetDimmed(v), av:SetPresence(nil | true | false).
function S.avatar(parent, size)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(size, size)
    f.floor = S.nine(f, "disc", { radius = size / 2, layer = "ARTWORK", sub = 0, color = "ink950" })
    f.ring = S.nine(f, "ring", { radius = size / 2, layer = "ARTWORK", sub = 1, color = "ink500" })
    -- The icon reaches past its round mask, so the square icon's own frame art is cut away.
    f.icon = f:CreateTexture(nil, "ARTWORK", nil, 2)
    local over = size * 0.1
    f.icon:SetPoint("TOPLEFT", -over, over)
    f.icon:SetPoint("BOTTOMRIGHT", over, -over)
    f.mask = f:CreateMaskTexture()
    f.mask:SetTexture(MEDIA .. "ui-mask-round", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    f.maskLine = { Layout = function()
        local px = S.pixel(f)
        f.mask:ClearAllPoints()
        f.mask:SetPoint("TOPLEFT", px, -px)
        f.mask:SetPoint("BOTTOMRIGHT", -px, px)
    end }
    f.maskLine.Layout()
    refreshers[f.maskLine] = true
    f.icon:AddMaskTexture(f.mask)
    function f:SetIcon(icon, atlas)
        if atlas then self.icon:SetAtlas(icon) else self.icon:SetTexture(icon) self.icon:SetTexCoord(0, 1, 0, 1) end
    end
    function f:SetClass(classFile)
        if classFile then self:SetIcon("classicon-" .. classFile:lower(), true) else self:SetIcon(nil) end
    end
    function f:SetRing(c) self.ring:SetColor(c) end
    function f:SetDimmed(v)
        self.icon:SetDesaturated(v and true or false)
        self.icon:SetAlpha(v and 0.6 or 1)
    end
    -- The presence dot on its lower right: verdant when online, faint when not, hidden when it doesn't
    -- apply; a ring of the floor's ink round it.
    local d = max(8, floor(size * 0.3 + 0.5))
    f.dotRing = f:CreateTexture(nil, "OVERLAY", nil, 0)
    f.dotRing:SetTexture(MEDIA .. "ui-disc-16")
    f.dotRing:SetSize(d + 2, d + 2)
    f.dotRing:SetPoint("CENTER", f, "BOTTOMRIGHT", -size * 0.15, size * 0.15)
    f.dotRing:SetVertexColor(S.rgb("ink950"))
    f.dot = f:CreateTexture(nil, "OVERLAY", nil, 1)
    f.dot:SetTexture(MEDIA .. "ui-disc-16")
    f.dot:SetSize(d - 1, d - 1)
    f.dot:SetPoint("CENTER", f.dotRing)
    function f:SetPresence(state)
        self.dot:SetShown(state ~= nil)
        self.dotRing:SetShown(state ~= nil)
        if state ~= nil then self.dot:SetVertexColor(S.rgb(state and "verdant" or "faint")) end
    end
    f:SetPresence(nil)
    return f
end

-- A niche: a tall recess under a round arch, the shape of Reliquary's own mark: an ink.950 floor, a
-- line round its arch, down its sides and along its foot, and moonlight from its head. With a plinth
-- (units), a line that far above its foot: niche.figure is the room over it, where a crest or a model
-- stands, niche.plinth the room under it, for a few words.
function S.niche(parent, width, height, plinth)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(width, height)
    -- The arch is the head of a rounded shape that runs on past the niche's foot and is cut off there.
    f.art = CreateFrame("Frame", nil, f)
    f.art:SetAllPoints()
    f.art:SetClipsChildren(true)
    f.run = CreateFrame("Frame", nil, f.art)
    f.run:SetPoint("TOPLEFT")
    f.run:SetPoint("BOTTOMRIGHT", 0, -width)
    f.floor = S.nine(f.run, "disc", { radius = width / 2, layer = "BACKGROUND", sub = 0, color = "ink950" })
    f.line = S.nine(f.run, "ring", { radius = width / 2, layer = "BACKGROUND", sub = 1, color = "ink500" })
    f.moon = f.run:CreateTexture(nil, "BACKGROUND", nil, 2)
    f.moon:SetTexture(MEDIA .. "ui-glow")
    f.moon:SetBlendMode("ADD")
    f.moon:SetVertexColor(S.rgb("moon"))
    f.moon:SetAlpha(0.16)
    f.moon:SetSize(width - 8, width - 8)
    f.moon:SetPoint("CENTER", f, "TOP", 0, -width / 2)
    f.sill = S.line(f.run, "ink500", { layer = "BORDER" })
    f.sill:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT")
    f.sill:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT")
    f.figure = CreateFrame("Frame", nil, f)
    f.figure:SetPoint("TOPLEFT")
    f.figure:SetPoint("BOTTOMRIGHT", 0, plinth or 0)
    if plinth then
        f.step = S.line(f.run, "ink600", { layer = "BORDER" })
        f.step:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 0, plinth)
        f.step:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, plinth)
        f.plinth = CreateFrame("Frame", nil, f)
        f.plinth:SetPoint("TOPLEFT", f, "BOTTOMLEFT", 0, plinth)
        f.plinth:SetPoint("BOTTOMRIGHT")
    end
    return f
end

-- A band round a circle: the disc over the parent, less a round hole of `inner` units across at its
-- middle (ui-mask-hole: its hole is 112 of its 128 pixels), so the band never lies under what fills
-- the hole and nothing shows through as it fades. opts: color, layer, sub. Returns the nine.
local HOLE = 112 / 128
function S.band(parent, inner, opts)
    opts = opts or {}
    local w = parent:GetWidth() or 0
    local n = S.nine(parent, "disc", { radius = w / 2, layer = opts.layer or "ARTWORK", sub = opts.sub or 0, color = opts.color or "gold600" })
    n.hole = parent:CreateMaskTexture()
    n.hole:SetTexture(MEDIA .. "ui-mask-hole", "CLAMP", "CLAMP")
    n.hole:SetSize(inner / HOLE, inner / HOLE)
    n.hole:SetPoint("CENTER")
    for _, t in pairs(n.tex) do t:AddMaskTexture(n.hole) end
    return n
end

-- A list row, 40 tall: an avatar (a presence dot on it), the name (heading, its class colour), a second
-- line (small), the level at the right, Reliquary's mark for a player who shares; its background fills
-- on hover, the chosen row keeps the fill and the gold bar at its left edge, which glides to it from the
-- row chosen before (Skin.glide).
S.ROW, S.ROW_HEAD = 40, 28
function S.row(button)
    if button.rqRow then return button end
    button.rqRow = true
    button:SetHeight(S.ROW)
    button:RegisterForClicks("LeftButtonUp")
    button.fill = S.nine(button, "disc", { radius = S.RADIUS.control, layer = "BACKGROUND", sub = 0, color = "ink800", inset = { 4, 1, 4, 1 } })
    button.fill:SetAlpha(0)
    button.bar = button:CreateTexture(nil, "ARTWORK", nil, 3)
    button.bar:SetTexture(MEDIA .. "ui-disc-16")
    button.bar:SetSize(3, 22)
    button.bar:SetPoint("LEFT", 4, 0)
    button.bar:SetVertexColor(S.rgb("gold300"))
    button.bar:Hide()
    button.inner = CreateFrame("Frame", nil, button)
    button.inner:SetAllPoints()
    local inner = button.inner
    button.avatar = S.avatar(inner, 28)
    button.avatar:SetPoint("LEFT", 14, 0)
    -- The friends list's own word for a field kept under the old name: the avatar is its class icon.
    button.class = button.avatar.icon
    button.name = S.text(inner, "heading")
    button.info = S.text(inner, "small")
    button.level = S.text(inner, "numeral", "RIGHT")
    button.level:SetTextColor(S.rgb("muted"))
    button.level:SetPoint("RIGHT", -14, 0)
    button.gem = S.glyph(inner, "arch", 12, "gold400")
    button.gem:SetPoint("RIGHT", button.level, "LEFT", -6, 0)
    button.dot = button.avatar.dot -- presence, drawn on the avatar
    -- Hover fills it (a heading, inert, is nothing to point at).
    local function fill(self, a)
        if self.chosen or self.inert then return end
        Motion.fade(self.fill, a, { dur = "fast", set = function(n, v) n:SetAlpha(v) end, from = self.fill.alpha or 0, owner = self })
    end
    button:HookScript("OnEnter", function(self) fill(self, 1) end)
    button:HookScript("OnLeave", function(self) fill(self, 0) end)
    -- Chosen or not: the fill and the bar, at once (the bar's glide is Skin.glide's).
    function button:SetChosen(v)
        self.chosen = v and true or false
        Motion.stop(self.fill, "alpha")
        self.fill:SetAlpha(v and 1 or 0)
        self.bar:SetShown(self.chosen)
    end
    return button
end

-- The chosen row's gold bar glides to it from where it was: fromTop is the top (GetTop) of the row
-- chosen before, in the same list.
function S.glide(button, fromTop)
    local top = fromTop and button:GetTop()
    if not top or top == fromTop then return end
    Motion.slide(button.bar, 0, fromTop - top, { dur = "base", ease = "out" })
end

-- A list's heading: the label face, and a pixel line running from it to the right edge.
function S.sectionRow(button)
    if button.rqSection then return button end
    button.rqSection = true
    button.title = S.text(button, "label")
    button.title:SetPoint("LEFT", 14, -2)
    button.rule = S.line(button, "ink600")
    button.rule:SetPoint("LEFT", button.title, "RIGHT", 8, 0)
    button.rule:SetPoint("RIGHT", -14, 0)
    return button
end

-- An item slot: the game's own item button (its clicks, its tooltip and modified clicks are the
-- game's), drawn as an icon in a rounded frame whose line and soft outer glow take the item's quality
-- colour; an empty one is a quiet well with the slot's own silhouette. slot:SetQuality(q) colours it
-- (Skin.slotQuality does it for any item button made here); the glow brightens on hover.
local QUALITY_FALLBACK = { [0] = { 0.62, 0.62, 0.62 }, { 1, 1, 1 }, { 0.12, 1, 0 }, { 0, 0.44, 0.87 }, { 0.64, 0.21, 0.93 }, { 1, 0.5, 0 },
    { 0.9, 0.8, 0.5 }, { 0, 0.8, 1 } }
function S.qualityColor(q)
    local c = q and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q]
    if c and c.r then return c.r, c.g, c.b end
    local f = q and QUALITY_FALLBACK[q]
    if f then return f[1], f[2], f[3] end
    return S.rgb("ink600")
end
local ICON_CUT = 0.08
local SLOT_GLOW = { rest = 0.14, hover = 0.4 }
local PLATE = { height = 11, least = 12, pad = 2.5, radius = 3, alpha = 0.8 }
function S.slot(parent, size)
    size = size or 40
    local b = CreateFrame("ItemButton", nil, parent)
    b:SetSize(size, size)
    b.rqSlot = true
    -- The game's own frame art, border and highlight give way to Reliquary's.
    b:ClearNormalTexture()
    b:ClearPushedTexture()
    b:ClearHighlightTexture()
    -- The game's SetItemButtonQuality puts its own frame round an item's icon in the quality's colour,
    -- asking the button first when it has a way of its own: the slot's is to show none (its line is its
    -- own frame).
    function b:SetItemButtonBorder()
        if self.IconBorder then self.IconBorder:Hide() end
    end
    b:SetItemButtonBorder()
    b.rqGlow = S.nine(b, "glow", { layer = "BACKGROUND", sub = -2, alpha = 0 })
    -- The well, the ring of the line over its edge, and the icon one pixel in, so the line keeps one
    -- pixel round the icon's rounded square.
    b.rqWell = S.nine(b, "disc", { radius = S.RADIUS.control, layer = "BACKGROUND", sub = 0, color = "ink950" })
    b.rqLine = S.nine(b, "ring", { radius = S.RADIUS.control, layer = "BACKGROUND", sub = 1, color = "ink600" })
    b.rqHole = S.nine(b, "inset", { layer = "BACKGROUND", sub = 2, alpha = 0.9, px = 1 })
    local icon = b.icon
    if icon then
        local fit = { Layout = function()
            local px = S.pixel(b)
            icon:ClearAllPoints()
            icon:SetPoint("TOPLEFT", px, -px)
            icon:SetPoint("BOTTOMRIGHT", -px, px)
        end }
        fit.Layout()
        refreshers[fit] = true
        b.rqFit = fit -- kept by the slot: the list of what follows the screen's scale holds nothing alive by itself
        -- The game bakes a bevelled border into every icon, and its SetItemButtonTexture puts the whole
        -- picture back each time, asking the button first when it has a way of its own. This is the
        -- slot's: the same, with the icon cut in past that border so the slot's line is its only frame.
        function b:SetItemButtonTexture(texture)
            local atlas = false
            if not texture then
                texture = self.emptyBackgroundTexture
                if not texture then texture, atlas = self.emptyBackgroundAtlas, true end
            end
            icon:SetShown(texture ~= nil)
            if not texture then return end
            if atlas then
                icon:SetAtlas(texture, false, nil, true)
            else
                icon:SetTexture(texture)
                icon:SetTexCoord(ICON_CUT, 1 - ICON_CUT, ICON_CUT, 1 - ICON_CUT)
            end
        end
        if b.Mask then
            b.Mask:SetTexture(MEDIA .. "ui-mask-slot", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
            b.Mask:ClearAllPoints()
            b.Mask:SetAllPoints(icon)
        end
    end
    local function glow(self, a) Motion.fade(self.rqGlow, a, { dur = "fast", from = self.rqGlow.alpha or 0, set = function(n, v) n:SetAlpha(v) end, owner = self }) end
    b:HookScript("OnEnter", function(self) if self.rqFilled then glow(self, self.rqLit and SLOT_GLOW.hover or SLOT_GLOW.rest) end end)
    b:HookScript("OnLeave", function(self) glow(self, self.rqLit and SLOT_GLOW.rest or 0) end)
    -- An uncommon or better item's quality colour on the line (a little darker than its text) and the
    -- glow; a quiet line for any other item; the quiet well of an empty slot.
    function b:SetQuality(q, filled)
        self.rqFilled = filled and true or false
        self.rqLit = filled and q ~= nil and q >= 2
        Motion.stop(self.rqGlow, "alpha")
        if self.rqLit then
            local r, g, bl = S.qualityColor(q)
            self.rqLine:SetColor(r * 0.8, g * 0.8, bl * 0.8)
            self.rqGlow:SetColor(r, g, bl)
        elseif filled then
            -- A poor or common item's grey or white would read as a stock silver frame: a quiet line.
            self.rqLine:SetColor("ink500")
            self.rqGlow:SetColor("gold300")
        else
            self.rqLine:SetColor("ink600")
            self.rqGlow:SetColor("gold300")
        end
        self.rqGlow:SetAlpha(self.rqLit and SLOT_GLOW.rest or 0)
        self.rqHole:SetShown(not filled)
    end
    b:SetQuality(nil, false)
    -- A small dark plate on the slot's lower right for a number that is the item's own (its level);
    -- nil takes it away.
    function b:SetPlate(text)
        if not text then
            if self.rqPlate then self.rqPlate:Hide() end
            return
        end
        local p = self.rqPlate
        if not p then
            p = CreateFrame("Frame", nil, self)
            p:SetHeight(PLATE.height)
            p.fill = S.nine(p, "disc", { radius = PLATE.radius, layer = "OVERLAY", sub = 1, color = "ink950", alpha = PLATE.alpha })
            p.text = S.text(p, "plate", "CENTER", nil, "OVERLAY")
            p.text:SetDrawLayer("OVERLAY", 2)
            p.text:SetPoint("CENTER")
            local place = { Layout = function()
                local px = 2 * S.pixel(self)
                p:ClearAllPoints()
                p:SetPoint("BOTTOMRIGHT", -px, px)
            end }
            place.Layout()
            refreshers[place] = true
            p.place = place
            self.rqPlate = p
        end
        p.text:SetText(text)
        p:SetWidth(max(PLATE.least, (p.text:GetStringWidth() or 0) + 2 * PLATE.pad))
        p:Show()
    end
    return b
end

-- A progress bar, 6 or 10 tall: an ink.700 track and a filled part with a soft bright leading edge,
-- gold unless told (bar:SetColor). bar:Set(value, most, opts) moves it there over long time from where
-- it was (opts.from: from that fraction, 0 when its page arrives; opts.delay; opts.instant).
function S.bar(parent, height)
    height = height or 6
    local f = CreateFrame("Frame", nil, parent)
    f:SetHeight(height)
    f.track = S.nine(f, "disc", { radius = height / 2, layer = "ARTWORK", sub = 0, color = "ink700" })
    f.fillArea = CreateFrame("Frame", nil, f)
    f.fillArea:SetPoint("TOPLEFT")
    f.fillArea:SetPoint("BOTTOMLEFT")
    f.fillArea:SetWidth(height)
    f.fill = S.nine(f.fillArea, "disc", { radius = height / 2, layer = "ARTWORK", sub = 1, color = "gold300" })
    f.edge = f.fillArea:CreateTexture(nil, "ARTWORK", nil, 2)
    f.edge:SetTexture(MEDIA .. "ui-glow")
    f.edge:SetBlendMode("ADD")
    f.edge:SetSize(height * 2.5, height * 2.5)
    f.edge:SetPoint("CENTER", f.fillArea, "RIGHT", -height / 2, 0)
    f.frac = 0
    local function show(self, frac)
        self.frac = frac
        local w = self:GetWidth() or 0
        local on = frac > 0 and w > 0
        self.fillArea:SetShown(on)
        if on then self.fillArea:SetWidth(max(height, w * min(1, frac))) end
    end
    f.ShowFraction = show
    function f:SetColor(r, g, b)
        if type(r) ~= "number" then r, g, b = S.rgb(r or "gold300") end
        self.fill:SetColor(r, g, b)
        self.edge:SetVertexColor(min(1, r * 0.6 + 0.4), min(1, g * 0.6 + 0.4), min(1, b * 0.6 + 0.4))
        self.edge:SetAlpha(0.55)
    end
    f:SetColor("gold300")
    function f:Set(value, most, opts)
        opts = opts or {}
        local frac = (most and most > 0) and max(0, min(1, (value or 0) / most)) or 0
        self.target = frac
        if opts.instant then Motion.stop(self, "fill") show(self, frac) return end
        Motion.to(self, "fill", frac, { from = opts.from or self.frac, dur = "long", delay = opts.delay, ease = "out", set = show })
    end
    f:SetScript("OnSizeChanged", function(self) show(self, Motion.running(self, "fill") and self.frac or (self.target or self.frac)) end)
    return f
end

-- A chip: a small pill holding an icon and a short value. chip:Set(text, icon, isAtlas, color); it
-- takes the width it needs (chip.width).
function S.chip(parent)
    local f = CreateFrame("Frame", nil, parent)
    f:SetHeight(20)
    f.surface = S.surface(f, { fill = "ink800", line = "ink600", radius = 10, layer = "ARTWORK" })
    f.icon = f:CreateTexture(nil, "OVERLAY")
    f.icon:SetSize(12, 12)
    f.icon:SetPoint("LEFT", 8, 0)
    f.text = S.text(f, "small", "LEFT", false, "OVERLAY")
    function f:Set(text, icon, atlas, c)
        self.text:SetText(text or "")
        local hasIcon = icon ~= nil
        self.icon:SetShown(hasIcon)
        if hasIcon then
            if atlas then self.icon:SetAtlas(icon) else self.icon:SetTexture(icon) self.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92) end
        end
        self.text:SetTextColor(S.rgb(c or "muted"))
        self.text:ClearAllPoints()
        self.text:SetPoint("LEFT", hasIcon and 24 or 10, 0)
        self.width = (hasIcon and 24 or 10) + (self.text:GetStringWidth() or 0) + 10
        self:SetWidth(self.width)
    end
    return f
end

-- A button: kind "primary" (a gold line and gold words), "quiet" (an ink.500 line) or "icon" (a glyph,
-- no line). Hover warms it, a press sinks its face one unit, disabled it goes faint. btn:SetText(t),
-- btn:SetGlyph(name, size).
local BUTTON = {
    primary = { line = "gold600", lineHover = "gold400", fill = "ink850", fillHover = "ink800", text = "gold200", textHover = "gold100" },
    quiet = { line = "ink500", lineHover = "gold600", fill = "ink850", fillHover = "ink800", text = "parchment", textHover = "gold100" },
    icon = { text = "muted", textHover = "gold200" },
}
function S.button(parent, kind)
    kind = BUTTON[kind] and kind or "quiet"
    local look = BUTTON[kind]
    local b = CreateFrame("Button", nil, parent)
    b:SetHeight(24)
    b.kind = kind
    if look.line then b.surface = S.surface(b, { fill = look.fill, line = look.line, radius = S.RADIUS.control }) end
    b.face = CreateFrame("Frame", nil, b)
    b.face:SetAllPoints()
    b.label = S.text(b.face, "body", "CENTER", false, "OVERLAY")
    b.label:SetPoint("CENTER")
    b.label:SetTextColor(S.rgb(look.text))
    function b:SetText(t)
        self.label:SetText(t or "")
        if self.surface then self:SetWidth(max(64, (self.label:GetStringWidth() or 0) + 24 + (self.glyph and 16 or 0))) end
    end
    function b:GetText() return self.label:GetText() end
    function b:SetGlyph(name, size)
        if not self.glyph then self.glyph = S.glyph(self.face, name, size or 12, look.text, "OVERLAY") end
        self.glyph:ClearAllPoints()
        if self.surface and (self.label:GetText() or "") ~= "" then
            self.glyph:SetPoint("LEFT", 8, 0)
            self.label:ClearAllPoints()
            self.label:SetPoint("CENTER", 8, 0)
        else
            self.glyph:SetPoint("CENTER")
        end
    end
    local function paint(self, hot)
        local disabled = not self:IsEnabled()
        local t = disabled and "faint" or hot and look.textHover or look.text
        tint(self.label, "text", t)
        if self.glyph then tint(self.glyph, "glyph", t) end
        if self.surface then
            tint(self.surface.line, "line", disabled and "ink600" or hot and look.lineHover or look.line)
            tint(self.surface.fill, "fill", hot and not disabled and look.fillHover or look.fill)
        end
    end
    b:SetScript("OnEnter", function(self) paint(self, true) end)
    b:SetScript("OnLeave", function(self) paint(self, false) end)
    b:SetScript("OnMouseDown", function(self) if self:IsEnabled() then self.face:SetPoint("TOPLEFT", 0, -1) self.face:SetPoint("BOTTOMRIGHT", 0, -1) end end)
    b:SetScript("OnMouseUp", function(self) self.face:SetAllPoints() end)
    b:HookScript("OnEnable", function(self) paint(self, false) end)
    b:HookScript("OnDisable", function(self) paint(self, false) end)
    return b
end

-- A switch: a pill whose knob slides (ease.pop) and whose track warms to gold when on. A CheckButton:
-- sw:SetChecked(v) moves it, a click switches it.
function S.switch(parent)
    local b = CreateFrame("CheckButton", nil, parent)
    b:SetSize(32, 16)
    b.track = S.surface(b, { fill = "ink700", line = "ink500", radius = 8, layer = "ARTWORK" })
    b.knob = b:CreateTexture(nil, "OVERLAY")
    b.knob:SetTexture(MEDIA .. "ui-disc-32")
    b.knob:SetSize(12, 12)
    b.knob:SetPoint("LEFT", 2, 0)
    local set = b.SetChecked
    local function paint(self, instant)
        local on = self:GetChecked() and true or false
        local x = on and 18 or 2
        local dur = instant and 0 or "base"
        Motion.to(self.knob, "x", x, { from = self.knobX or x, dur = dur, ease = "pop", set = function(k, v) k:SetPoint("LEFT", v, 0) end, owner = self })
        self.knobX = x
        tint(self.track.fill, "fill", on and "gold300" or "ink700", dur ~= 0 and "base" or 0)
        tint(self.track.line, "line", on and "gold400" or "ink500", dur ~= 0 and "base" or 0)
        tint(self.knob, "knob", on and "ink900" or "muted", dur ~= 0 and "base" or 0)
    end
    function b:SetChecked(v)
        set(self, v)
        paint(self, true)
    end
    b:HookScript("OnClick", function(self) paint(self, false) end)
    paint(b, true)
    return b
end

-- A small box with a gold tick that pops in (ease.pop), for the sharing grid and filters. A
-- CheckButton: box:SetChecked(v), a click ticks it.
function S.check(parent)
    local b = CreateFrame("CheckButton", nil, parent)
    b:SetSize(16, 16)
    b.box = S.surface(b, { fill = "ink850", line = "ink500", radius = 3, layer = "ARTWORK" })
    b.tick = S.glyph(b, "tick", 14, "gold300", "OVERLAY")
    b.tick:SetPoint("CENTER")
    local set = b.SetChecked
    local function paint(self, instant)
        local on = self:GetChecked() and true or false
        self.tick:SetShown(on)
        if on and not instant then
            Motion.to(self.tick, "pop", 1, { from = 0.4, dur = "base", ease = "pop", set = function(t, v) t:SetScale(max(0.01, v)) end, owner = self })
        else
            Motion.stop(self.tick, "pop")
            self.tick:SetScale(1)
        end
        tint(self.box.line, "line", on and "gold600" or "ink500", instant and 0 or "fast")
    end
    function b:SetChecked(v)
        set(self, v)
        paint(self, true)
    end
    b:HookScript("OnClick", function(self) paint(self, false) end)
    b:HookScript("OnEnter", function(self) if not self:GetChecked() then tint(self.box.line, "line", "gold600") end end)
    b:HookScript("OnLeave", function(self) if not self:GetChecked() then tint(self.box.line, "line", "ink500") end end)
    paint(b, true)
    return b
end

-- The search field: a magnifier, the hint in parchment.dim, a moon-coloured line while focused, and a
-- clear button once it has text. An EditBox; box.onChange(text) runs as it changes.
function S.search(parent, hint)
    local e = CreateFrame("EditBox", nil, parent)
    e:SetHeight(26)
    e:SetAutoFocus(false)
    e:SetFontObject(S.font("body"))
    e:SetTextInsets(28, 24, 0, 0)
    e.well = S.surface(e, { fill = "ink950", line = "ink600", radius = S.RADIUS.control })
    e.glass = S.glyph(e, "magnifier", 12, "dim", "OVERLAY")
    e.glass:SetPoint("LEFT", 9, 0)
    e.hint = S.text(e, "body", "LEFT", false, "OVERLAY")
    e.hint:SetTextColor(S.rgb("dim"))
    e.hint:SetPoint("LEFT", 28, 0)
    e.hint:SetPoint("RIGHT", -24, 0)
    e.hint:SetText(hint or SEARCH or "Search")
    e.focus = S.line(e, "moon", { layer = "OVERLAY" })
    e.focus:SetPoint("BOTTOMLEFT", 4, 1)
    e.focus:SetPoint("BOTTOMRIGHT", -4, 1)
    e.focus:SetAlpha(0)
    e.clear = CreateFrame("Button", nil, e)
    e.clear:SetSize(16, 16)
    e.clear:SetPoint("RIGHT", -5, 0)
    e.clear.glyph = S.glyph(e.clear, "clear", 12, "dim", "OVERLAY")
    e.clear.glyph:SetPoint("CENTER")
    e.clear:Hide()
    e.clear:SetScript("OnEnter", function(self) tint(self.glyph, "glyph", "parchment") end)
    e.clear:SetScript("OnLeave", function(self) tint(self.glyph, "glyph", "dim") end)
    e.clear:SetScript("OnClick", function()
        e:SetText("")
        e:ClearFocus()
        local fn = e:GetScript("OnTextChanged")
        if fn then fn(e, true) end
    end)
    e:SetScript("OnTextChanged", function(self)
        local t = self:GetText() or ""
        self.hint:SetShown(t == "")
        self.clear:SetShown(t ~= "")
        if self.onChange then self.onChange(t) end
    end)
    e:SetScript("OnEditFocusGained", function(self)
        Motion.fade(self.focus, 1, { dur = "fast", from = self.focus:GetAlpha() })
        tint(self.glass, "glyph", "moon")
    end)
    e:SetScript("OnEditFocusLost", function(self)
        Motion.fade(self.focus, 0, { dur = "fast", from = self.focus:GetAlpha() })
        tint(self.glass, "glyph", "dim")
    end)
    e:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    e:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    return e
end

-- A dropdown: a quiet button that opens the game's own menu (Blizzard_Menu's DropdownButton:
-- dd:SetupMenu(generator) as the game's), its choice's words on it (dd:SetText).
function S.dropdown(parent)
    local d = CreateFrame("DropdownButton", nil, parent)
    d:SetHeight(24)
    d.surface = S.surface(d, { fill = "ink850", line = "ink500", radius = S.RADIUS.control })
    d.label = S.text(d, "body", "LEFT", false, "OVERLAY")
    d.label:SetPoint("LEFT", 10, 0)
    d.label:SetPoint("RIGHT", -26, 0)
    d.chevron = S.glyph(d, "chevronDown", 12, "muted", "OVERLAY")
    d.chevron:SetPoint("RIGHT", -9, 0)
    function d:SetText(t) self.label:SetText(t or "") end
    d:HookScript("OnEnter", function(self) tint(self.surface.line, "line", "gold600") tint(self.chevron, "glyph", "parchment") end)
    d:HookScript("OnLeave", function(self) tint(self.surface.line, "line", "ink500") tint(self.chevron, "glyph", "muted") end)
    return d
end

-- A scrolling list: the game's ScrollBox underneath, with eased scrolling and a thin thumb (4 units,
-- ink.500, gold.600 on hover) with no arrows, shown only when the list is longer than its space.
-- opts: frameType and init (each row, as ScrollBox's initializer), extent(line) (each row's height),
-- top, bottom, right, fade (its rows fade out over this many units at an edge with more beyond it, as
-- the game's own lists can). Returns the list and its bar.
function S.scroll(parent, opts)
    opts = opts or {}
    local list = CreateFrame("Frame", nil, parent, "WowScrollBoxList")
    list:SetPoint("TOPLEFT", opts.left or 0, opts.top or 0)
    list:SetPoint("BOTTOMRIGHT", -(opts.right or 10), opts.bottom or 0)
    local bar = CreateFrame("EventFrame", nil, parent, "MinimalScrollBar")
    bar:SetPoint("TOPLEFT", list, "TOPRIGHT", 3, -2)
    bar:SetPoint("BOTTOMLEFT", list, "BOTTOMRIGHT", 3, 2)
    bar:SetHideIfUnscrollable(true)
    S.thinBar(bar)
    list:SetInterpolateScroll(true)
    bar:SetInterpolateScroll(true)
    if opts.fade then
        list:SetEdgeFadeLength(opts.fade)
        -- The game's fade takes a list that fits as one scrolled to its top and fades its foot all the
        -- same: here only an edge with more beyond it fades.
        local fade = list.CalculateEdgeFade
        function list:CalculateEdgeFade()
            if not self:HasScrollableExtent() then return 0, 0 end
            return fade(self)
        end
    end
    local view = CreateScrollBoxListLinearView()
    view:SetElementExtentCalculator(function(_, line) return opts.extent(line) end)
    view:SetElementInitializer(opts.frameType or "Frame", opts.init)
    ScrollUtil.InitScrollBoxListWithScrollBar(list, bar, view)
    return list, bar
end

-- The game's minimal scroll bar, drawn as Reliquary's: no arrows, no track, a thin thumb.
function S.thinBar(bar)
    for _, key in ipairs({ "Back", "Forward" }) do
        local b = bar[key]
        if b then b:SetAlpha(0) b:EnableMouse(false) b:SetSize(1, 1) end
    end
    local track = bar.Track
    if track then
        track:ClearAllPoints()
        track:SetPoint("TOP")
        track:SetPoint("BOTTOM")
        for _, key in ipairs({ "Begin", "Middle", "End" }) do if track[key] then track[key]:SetAlpha(0) end end
        local thumb = track.Thumb
        if thumb then
            for _, key in ipairs({ "Begin", "Middle", "End" }) do if thumb[key] then thumb[key]:SetAlpha(0) end end
            local holder = CreateFrame("Frame", nil, thumb)
            holder:SetPoint("TOPLEFT", 2, 0)
            holder:SetPoint("BOTTOMRIGHT", -2, 0)
            thumb.rqThumb = S.nine(holder, "disc", { radius = 2, layer = "OVERLAY", color = "ink500" })
            thumb:HookScript("OnEnter", function(self) tint(self.rqThumb, "thumb", "gold600") end)
            thumb:HookScript("OnLeave", function(self) tint(self.rqThumb, "thumb", "ink500") end)
        end
    end
    return bar
end

-- A divider: a pixel line, with ornament = true the shrine's small arch at its middle (one a page).
function S.divider(parent, ornament)
    local f = CreateFrame("Frame", nil, parent)
    f:SetHeight(ornament and 12 or 1)
    if ornament then
        f.mark = S.glyph(f, "arch", 12, "gold500")
        f.mark:SetPoint("CENTER")
        f.left = S.line(f, "ink600")
        f.left:SetPoint("LEFT")
        f.left:SetPoint("RIGHT", f.mark, "LEFT", -8, 0)
        f.right = S.line(f, "ink600")
        f.right:SetPoint("LEFT", f.mark, "RIGHT", 8, 0)
        f.right:SetPoint("RIGHT")
    else
        f.line = S.line(f, "ink600")
        f.line:SetPoint("LEFT")
        f.line:SetPoint("RIGHT")
    end
    return f
end

-- Reliquary's own hover text keeps the game's tooltip: a white title, then gold lines, wrapped.
function S.tip(owner, title, lines)
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    if type(GameTooltip_SetTitle) == "function" then GameTooltip_SetTitle(GameTooltip, title, nil, true)
    else GameTooltip:SetText(title, 1, 1, 1, 1, true) end
    for _, line in ipairs(lines or {}) do
        if type(GameTooltip_AddNormalLine) == "function" then GameTooltip_AddNormalLine(GameTooltip, line, true)
        else GameTooltip:AddLine(line, 1, 0.82, 0, true) end
    end
    GameTooltip:Show()
end

-- Text tabs with a sliding gold marker under the chosen one, for the window's tabs ("window") and a
-- player's pages ("page"). tabs:Add(key, label, name, right) makes a button (right: it stands apart at
-- the right); tabs:Layout(x, y, rightX) lays the shown ones out from x (and the right ones in from
-- rightX), hidden tabs taking no room; tabs:Select(key, instant) marks one; tabs:SetEnabled(key, on)
-- greys one (what its hover says is its caller's). tabs.onSelect(key, button) runs on a click;
-- button:IsSelected() says whether it is the chosen one.
local TABS = { window = { height = 46, pad = 12, role = "heading", lift = 5 }, page = { height = 32, pad = 10, role = "body", lift = 3 } }
local MARKER = 2
function S.tabs(parent, kind)
    local look = TABS[kind] or TABS.page
    local t = { buttons = {}, order = {}, look = look, parent = parent }
    t.marker = CreateFrame("Frame", nil, parent)
    t.marker:SetHeight(MARKER)
    t.marker.bar = S.nine(t.marker, "disc", { radius = MARKER / 2, layer = "OVERLAY", sub = 2, color = "gold300" })
    t.marker.glow = t.marker:CreateTexture(nil, "OVERLAY", nil, 1)
    t.marker.glow:SetTexture(MEDIA .. "ui-glow")
    t.marker.glow:SetBlendMode("ADD")
    t.marker.glow:SetPoint("BOTTOMLEFT", -4, -4)
    t.marker.glow:SetPoint("TOPRIGHT", 4, 5)
    t.marker.glow:SetVertexColor(S.rgb("gold300"))
    t.marker.glow:SetAlpha(0.3)
    t.marker:Hide()
    local function paint(b, hot)
        local c = not b:IsEnabled() and "faint" or b.key == t.chosen and "gold200" or hot and "parchment" or "muted"
        tint(b.label, "text", c)
    end
    local function selected(b) return b.key == t.chosen end
    function t:Add(key, label, name, right)
        local b = CreateFrame("Button", name, parent)
        b.key, b.right = key, right
        b:SetHeight(look.height)
        b.label = S.text(b, look.role, "CENTER", false, "OVERLAY")
        b.label:SetPoint("CENTER", 0, 1)
        b.label:SetText(label)
        b.IsSelected = selected
        b:SetScript("OnEnter", function(self) paint(self, true) end)
        b:SetScript("OnLeave", function(self) paint(self, false) end)
        b:SetScript("OnClick", function(self) if t.onSelect then t.onSelect(self.key, self) end end)
        b:SetMotionScriptsWhileDisabled(true)
        self.buttons[key] = b
        self.order[#self.order + 1] = b
        paint(b, false)
        return b
    end
    function t:SetEnabled(key, on)
        local b = self.buttons[key]
        b:SetEnabled(on)
        paint(b, false)
    end
    function t:Layout(x, y, rightX)
        local at, back = x or 0, rightX or 0
        for _, b in ipairs(self.order) do
            if b:IsShown() and not b.right then
                b:SetWidth(floor((b.label:GetStringWidth() or 0) + 2 * look.pad + 0.5))
                b:ClearAllPoints()
                b:SetPoint("TOPLEFT", parent, "TOPLEFT", at, y or 0)
                at = at + b:GetWidth()
            end
        end
        for i = #self.order, 1, -1 do
            local b = self.order[i]
            if b:IsShown() and b.right then
                b:SetWidth(floor((b.label:GetStringWidth() or 0) + 2 * look.pad + 0.5))
                b:ClearAllPoints()
                b:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -back, y or 0)
                back = back + b:GetWidth()
            end
        end
        self.width = at - (x or 0)
        if self.chosen then self:Select(self.chosen, true) end
    end
    -- The marker under the chosen tab's words, a little above the tab's foot, sliding from where it
    -- was and taking the new width.
    function t:Select(key, instant)
        local was = self.chosen
        self.chosen = key
        for _, b in ipairs(self.order) do paint(b, false) end
        local b = self.buttons[key]
        local m = self.marker
        if not (b and b:IsShown()) then m:Hide() return end
        local w = max(12, floor((b.label:GetStringWidth() or 0) + 0.5))
        local function place(_, v)
            m:ClearAllPoints()
            m:SetPoint("BOTTOMLEFT", b, "BOTTOM", v[1] - v[2] / 2, look.lift)
            m:SetWidth(v[2])
        end
        m:Show()
        local old = was and was ~= key and self.buttons[was]
        local target = { 0, w }
        if old and not instant and self.markerAt and old:GetCenter() and b:GetCenter() then
            -- From the old tab's middle, measured against the new one's.
            local dx = (old:GetCenter()) - (b:GetCenter())
            Motion.to(m, "place", target, { from = { dx, self.markerAt[2] }, dur = "base", ease = "out", set = place })
        else
            Motion.stop(m, "place")
            place(m, target)
        end
        self.markerAt = target
    end
    return t
end

---------------------------------------------------------------------------
-- Bags, Bank and the Guild Bank (ViewerBags.lua, ViewerBank.lua)
---------------------------------------------------------------------------
-- An icon cut in from its edge (the game bakes a bevelled border into every icon): a file, or an
-- atlas (its own part of its file, cut in the same way).
local function cutIcon(tex, icon, atlas)
    local l, r, t, b = 0, 1, 0, 1
    if atlas then
        local info = ns.call(ns.api("C_Texture.GetAtlasInfo"), icon)
        local file = type(info) == "table" and (info.file or info.filename)
        if not file then tex:SetTexture(nil) return end
        tex:SetTexture(file)
        l, r, t, b = info.leftTexCoord or 0, info.rightTexCoord or 1, info.topTexCoord or 0, info.bottomTexCoord or 1
    else
        tex:SetTexture(icon)
    end
    local w, h = r - l, b - t
    tex:SetTexCoord(l + w * 0.08, r - w * 0.08, t + h * 0.08, b - h * 0.08)
end

-- Skin.framedIcon(parent, size, layer): an icon in a slot's frame, not an item's button: a quiet well,
-- the icon one pixel in (cut in, masked to a slot's rounded square, whose corner is a tenth of its side)
-- and a one-pixel line over its edge. f:SetIcon(file or atlas, isAtlas), f.icon, f.line (a nine:
-- f.line:SetColor).
local function framedIcon(parent, size, layer)
    layer = layer or "ARTWORK"
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(size, size)
    local radius = size / 10
    f.well = S.nine(f, "disc", { radius = radius, layer = layer, sub = 0, color = "ink950" })
    f.icon = f:CreateTexture(nil, layer, nil, 1)
    f.mask = f:CreateMaskTexture()
    f.mask:SetTexture(MEDIA .. "ui-mask-slot", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    f.mask:SetAllPoints(f.icon)
    f.icon:AddMaskTexture(f.mask)
    f.line = S.nine(f, "ring", { radius = radius, layer = layer, sub = 2, color = "ink600" })
    local fit = { Layout = function()
        local px = S.pixel(f)
        f.icon:ClearAllPoints()
        f.icon:SetPoint("TOPLEFT", px, -px)
        f.icon:SetPoint("BOTTOMRIGHT", -px, px)
    end }
    fit.Layout()
    refreshers[fit] = true
    f.fit = fit
    function f:SetIcon(icon, atlas)
        cutIcon(self.icon, icon, atlas)
        self.icon:SetShown(icon ~= nil)
    end
    return f
end
S.framedIcon = framedIcon

-- A card headed by an item: on its band, the item's icon in a small slot's frame, its name (heading)
-- and a value under it (small): a bag, its name and "12 / 16". The head is a button, so the page can
-- give it the item's tooltip and click; hovering it warms the name. card.head (the button), .icon (a
-- framed icon: :SetIcon), .title, .value; card.body under the band, padded 12. card:SetHead(title,
-- value, icon, isAtlas, quality) (the icon's line in the quality's colour, as a slot's; with no icon the
-- words start where it would). S.ITEM_HEAD: the band's height.
S.ITEM_HEAD = 40
function S.itemCard(parent)
    local f = CreateFrame("Frame", nil, parent)
    f.surface = S.surface(f, { fill = "ink850", line = "ink600", radius = S.RADIUS.card })
    f.head = CreateFrame("Button", nil, f)
    f.head:SetPoint("TOPLEFT")
    f.head:SetPoint("TOPRIGHT")
    f.head:SetHeight(S.ITEM_HEAD)
    f.band = S.nine(f, "disc", { radius = S.RADIUS.card, layer = "BACKGROUND", sub = 2, color = "ink800", px = 1, rect = f.head,
        square = { bl = true, br = true } })
    f.rule = S.line(f, "ink600")
    f.rule:SetPoint("TOPLEFT", 0, -S.ITEM_HEAD)
    f.rule:SetPoint("TOPRIGHT", 0, -S.ITEM_HEAD)
    -- The icon centred on the band; the name and the value under it as one block centred beside it.
    f.icon = framedIcon(f.head, 24, "ARTWORK")
    f.icon:SetPoint("LEFT", 12, 0)
    f.title = S.text(f.head, "heading")
    f.title:SetPoint("RIGHT", -12, 0)
    f.title.rqtext = C.parchment
    f.value = S.text(f.head, "small")
    f.value:SetPoint("RIGHT", -12, 0)
    f.body = CreateFrame("Frame", nil, f)
    f.body:SetPoint("TOPLEFT", 12, -(S.ITEM_HEAD + S.SPACE.m))
    f.body:SetPoint("BOTTOMRIGHT", -12, 12)
    f.head:HookScript("OnEnter", function() tint(f.title, "text", "gold100") end)
    f.head:HookScript("OnLeave", function() tint(f.title, "text", "parchment") end)
    function f:SetHead(title, value, icon, atlas, q)
        self.title:SetText(title or "")
        self.value:SetText(value or "")
        self.icon:SetShown(icon ~= nil)
        self.icon:SetIcon(icon, atlas)
        local x = icon and 46 or 12
        self.title:SetPoint("TOPLEFT", x, -7)
        self.value:SetPoint("TOPLEFT", x, -23)
        if q then
            local r, g, b = S.qualityColor(q)
            self.icon.line:SetColor(r * 0.8, g * 0.8, b * 0.8)
        else
            self.icon.line:SetColor("ink600")
        end
    end
    return f
end

-- An icon tab: a CheckButton holding an icon in a slot's frame. Hover warms its line, a press sinks the
-- icon one unit, and the chosen one (SetChecked) is ringed in gold and shown at full strength while
-- the others rest a little dimmer. The guild bank's tabs. tab:SetIcon(file or atlas, isAtlas).
local ICON_TAB = { rest = 0.72, hover = 1 }
function S.iconTab(parent, size)
    local b = CreateFrame("CheckButton", nil, parent)
    b:SetSize(size, size)
    b.face = framedIcon(b, size, "ARTWORK")
    b.face:SetPoint("TOPLEFT")
    function b:SetIcon(icon, atlas) self.face:SetIcon(icon, atlas) end
    local set = b.SetChecked
    local function paint(self, hot, instant)
        local on = self:GetChecked() and true or false
        local dur = instant and 0 or "fast"
        tint(self.face.line, "line", on and "gold300" or hot and "gold600" or "ink600", dur)
        Motion.fade(self.face.icon, (on or hot) and ICON_TAB.hover or ICON_TAB.rest, { dur = dur, owner = self })
        self.face.icon:SetDesaturated(not self:IsEnabled())
    end
    function b:SetChecked(v)
        set(self, v)
        paint(self, self:IsMouseOver(), true)
    end
    b:HookScript("OnEnter", function(self) paint(self, true) end)
    b:HookScript("OnLeave", function(self) paint(self, false) end)
    b:HookScript("OnClick", function(self) paint(self, true) end)
    b:HookScript("OnMouseDown", function(self) if self:IsEnabled() then self.face:SetPoint("TOPLEFT", 0, -1) end end)
    b:HookScript("OnMouseUp", function(self) self.face:SetPoint("TOPLEFT") end)
    paint(b, false, true)
    return b
end

---------------------------------------------------------------------------
-- Pieces for a player's Talents, Recipes and Roleplay pages
---------------------------------------------------------------------------
-- A tile: a picture that isn't an item (a talent, a recipe's icon) on an ink.950 well in a one-pixel
-- line, as Skin.slot draws an item: the icon cut in from its edge, one pixel in from the line, masked
-- to the slot's rounded square (its corner a tenth of its side, as the line's). tile:SetIcon(file),
-- tile:SetLine(color, instant) (the line's colour, moved there over fast time), tile:SetDimmed(v)
-- (grey and dim), tile:SetTileSize(size) (drawn again at that size).
function S.tile(parent, size)
    local f = CreateFrame("Frame", nil, parent)
    f.well = S.nine(f, "disc", { layer = "BACKGROUND", sub = 0, color = "ink950" })
    f.line = S.nine(f, "ring", { layer = "BACKGROUND", sub = 1, color = "ink600" })
    f.icon = f:CreateTexture(nil, "ARTWORK")
    f.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    f.mask = f:CreateMaskTexture()
    f.mask:SetTexture(MEDIA .. "ui-mask-slot", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    f.mask:SetAllPoints(f.icon)
    f.icon:AddMaskTexture(f.mask)
    f.fit = { Layout = function()
        local px = S.pixel(f)
        f.icon:ClearAllPoints()
        f.icon:SetPoint("TOPLEFT", px, -px)
        f.icon:SetPoint("BOTTOMRIGHT", -px, px)
    end }
    refreshers[f.fit] = true
    function f:SetTileSize(n)
        self:SetSize(n, n)
        self.well.opts.radius, self.line.opts.radius = n / 10, n / 10
        self.well:Layout()
        self.line:Layout()
        self.fit.Layout()
    end
    f:SetTileSize(size)
    function f:SetIcon(icon) self.icon:SetTexture(icon) end
    function f:SetLine(c, instant) tint(self.line, "line", c, instant and 0 or nil) end
    function f:SetDimmed(v)
        self.icon:SetDesaturated(v and true or false)
        self.icon:SetAlpha(v and 0.4 or 1)
    end
    return f
end

-- A plate: a small pill holding a short number (a talent's rank), the width its words need.
-- plate:Set(text, color) (the words' colour).
function S.plate(parent)
    local f = CreateFrame("Frame", nil, parent)
    f:SetHeight(14)
    f.surface = S.surface(f, { fill = "ink950", line = "ink600", radius = 7, layer = "ARTWORK" })
    f.text = S.text(f, "small", "CENTER", false, "OVERLAY")
    f.text:SetPoint("CENTER", 0, 0)
    function f:Set(text, c)
        self.text:SetText(text or "")
        self.text:SetTextColor(S.rgb(c or "parchment"))
        self:SetWidth(max(14, floor((self.text:GetStringWidth() or 0) + 8 + 0.5)))
    end
    return f
end

-- A card that runs down a scrolling list, a row at a time: each row draws its own slice of it, so the
-- slices meet edge to edge and never lie over one another (a card fading in is one card, not layers).
-- The card is drawn whole on a frame reaching past the row, clipped to the row by a frame of its own
-- (so the row's content, a gold bar gliding in from another row, isn't cut): "top" (the card's
-- rounded top and its sides), "middle" (its sides) or "bottom" (its sides and rounded foot).
-- slice:SetPart(part, below) draws it; below: units of the row under a bottom left empty, the gap
-- before the next card. The row's own content goes on a frame a level above the slice.
function S.slice(row)
    local clip = CreateFrame("Frame", nil, row)
    clip:SetAllPoints()
    clip:SetClipsChildren(true)
    local f = CreateFrame("Frame", nil, clip)
    f.surface = S.surface(f, { fill = "ink850", line = "ink600", radius = S.RADIUS.card })
    local reach = 2 * S.RADIUS.card + S.SPACE.xs -- past the row, so the corners it cuts off are out of view
    function f:SetPart(part, below)
        self.part = part
        self:ClearAllPoints()
        self:SetPoint("TOPLEFT", row, "TOPLEFT", 0, part == "top" and 0 or reach)
        self:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", 0, part == "bottom" and (below or 0) or -reach)
        self:Show()
    end
    return f
end

---------------------------------------------------------------------------
-- For an item's page (ViewerItem.lua)
---------------------------------------------------------------------------
-- A field: words to read or copy (an item's addresses), in the search field's well, in a role's face
-- (body unless told); its line warms on hover, and a moon-coloured line shows while it has the
-- keyboard. An EditBox.
function S.field(parent, role)
    local e = CreateFrame("EditBox", nil, parent)
    e:SetHeight(24)
    e:SetAutoFocus(false)
    e:SetFontObject(S.font(role or "body"))
    e:SetJustifyH("LEFT")
    e:SetTextInsets(8, 8, 0, 0)
    e.well = S.surface(e, { fill = "ink950", line = "ink600", radius = S.RADIUS.control })
    e.focus = S.line(e, "moon", { layer = "OVERLAY" })
    e.focus:SetPoint("BOTTOMLEFT", 4, 1)
    e.focus:SetPoint("BOTTOMRIGHT", -4, 1)
    e.focus:SetAlpha(0)
    e:HookScript("OnEnter", function(self) tint(self.well.line, "line", "gold600") end)
    e:HookScript("OnLeave", function(self) tint(self.well.line, "line", "ink600") end)
    e:HookScript("OnEditFocusGained", function(self) Motion.fade(self.focus, 1, { dur = "fast", from = self.focus:GetAlpha() }) end)
    e:HookScript("OnEditFocusLost", function(self) Motion.fade(self.focus, 0, { dur = "fast", from = self.focus:GetAlpha() }) end)
    e:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    return e
end

-- How tall a wrapped text is as the game laid it out: its lines (GetNumLines) at one line's height
-- each in its face, for the pages that size themselves to text they measured once it shows (an item's
-- page, the Sharing tab).
local oneLine = setmetatable({}, { __mode = "k" })
function S.textHeight(fs)
    local h = fs:GetStringHeight() or 0
    local n = fs:GetNumLines() or 0
    local font = fs:GetFontObject()
    if n <= 1 or not font then return h end
    if not oneLine[font] then
        local probe = fs:GetParent():CreateFontString(nil, "ARTWORK")
        probe:SetFontObject(font)
        probe:SetText("Ag")
        oneLine[font] = probe:GetStringHeight() or 0
        probe:Hide()
    end
    return n * oneLine[font]
end
