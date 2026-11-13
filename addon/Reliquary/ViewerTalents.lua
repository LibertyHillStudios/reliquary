-- Reliquary's window: a character's Talents page (docs/DESIGN.md, section 5): the class's three trees
-- as three cards side by side, each on the painting the game's talent window gives that tree, and
-- your own characters' Legacy a fourth, short card under them.
local ADDON, ns = ...

local V = ns.V
local Skin, Motion = ns.Skin, ns.Motion

local num, str = ns.num, ns.str
local ipairs, type, tostring = ipairs, type, tostring
local floor, ceil, min, max, format = math.floor, math.ceil, math.min, math.max, string.format
local PAGE_WIDTH, PAGE_HEIGHT, hideTip, big = V.PAGE_WIDTH, V.PAGE_HEIGHT, V.hideTip, V.big

local TREES = {
    DRUID = { "Balance", "Feral Combat", "Restoration" }, WARRIOR = { "Arms", "Fury", "Protection" },
    PALADIN = { "Holy", "Protection", "Retribution" }, HUNTER = { "Beast Mastery", "Marksmanship", "Survival" },
    ROGUE = { "Assassination", "Combat", "Subtlety" }, PRIEST = { "Discipline", "Holy", "Shadow" },
    SHAMAN = { "Elemental", "Enhancement", "Restoration" }, MAGE = { "Arcane", "Fire", "Frost" },
    WARLOCK = { "Affliction", "Demonology", "Destruction" },
}
-- The painting the game's talent window shows behind each tree (Interface\TalentFrame), in the
-- order the trees run.
local TREE_ART = {
    DRUID = { "DruidBalance", "DruidFeralCombat", "DruidRestoration" }, WARRIOR = { "WarriorArms", "WarriorFury", "WarriorProtection" },
    PALADIN = { "PaladinHoly", "PaladinProtection", "PaladinCombat" }, HUNTER = { "HunterBeastMastery", "HunterMarksmanship", "HunterSurvival" },
    ROGUE = { "RogueAssassination", "RogueCombat", "RogueSubtlety" }, PRIEST = { "PriestDiscipline", "PriestHoly", "PriestShadow" },
    SHAMAN = { "ShamanElementalCombat", "ShamanEnhancement", "ShamanRestoration" }, MAGE = { "MageArcane", "MageFire", "MageFrost" },
    WARLOCK = { "WarlockCurses", "WarlockSummoning", "WarlockDestruction" },
}

---------------------------------------------------------------------------
-- Talents, as the game's own talent frame lays them out. Forever runs a class's three trees side by
-- side on one trait tree: a tree is a run of columns with a wide gap before the next (as Share.lua's
-- talentSummary splits them). Your own characters show every talent, what isn't learned grey and dim,
-- with the arrows between them, and their Legacy below; another player's, the talents they learned.
---------------------------------------------------------------------------
-- The page, in units: three tree cards side by side, a gap between; in each, under its header (the
-- tree's name and points), the painting, inset; in the painting, the talents in four columns, the room
-- between rows, the least between columns, and the room round them. A talent's square is the largest
-- of SIZES that lets the trees, the unspent points and the Legacy fit the page (the arrows and the
-- rank's plate follow it; the game's own talents are 40). Under the cursor a talent grows to grow
-- (DESIGN, section 2). The line of unspent points, and the Legacy's card with nothing learned yet.
local TAL = { gap = Skin.SPACE.l, inset = Skin.SPACE.s, pad = Skin.SPACE.s, rowGap = Skin.SPACE.s, colGap = Skin.SPACE.xs, around = Skin.SPACE.m,
    cols = 4, sizes = { 40, 36, 32, 28, 24 }, grow = 1.06, note = Skin.SPACE.m, legacyBare = Skin.CARD_HEAD + Skin.SPACE.s }
TAL.card = (PAGE_WIDTH - 2 * TAL.gap) / 3
TAL.paint = TAL.card - 2 * TAL.inset
local GAME_SIZE = 40

-- A talent as the window draws it, from your own character's tree or another player's card.
local function talentOf(n, tree)
    if type(n) ~= "table" then return nil end
    return { id = n.id, spell = num(n.spell) or num(n.sp), name = str(n.name) or str(n.nm), icon = num(n.icon) or num(n.ic),
        rank = num(n.rank) or num(n.r) or 0, max = num(n.max) or num(n.m) or 0, x = num(n.x), y = num(n.y), to = n.to, tree = tree or num(n.t) }
end

-- How far a talent is learned: in full, in part, or not at all; its line and the colour of its rank
-- (the game's talent frame: gold in full, green in part).
local STATE = { full = { line = "gold400", rank = "gold200" }, part = { line = "verdant", rank = "verdant" }, none = { line = "ink600" } }
local function stateOf(t)
    if t.rank <= 0 then return "none" end
    if t.max > 0 and t.rank >= t.max then return "full" end
    return "part"
end

local function talentTip(self)
    local t = self.talent
    if not t then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    if t.spell then GameTooltip:SetSpellByID(t.spell) else GameTooltip:SetText(t.name or "") end
    GameTooltip:AddLine(format("Rank %d/%d", t.rank, t.max), 1, 1, 1)
    GameTooltip:Show()
end

-- A talent: its icon on a tile, the rank on a plate at its lower right once learned; it grows a little
-- from its middle under the cursor.
local function talentButton(parent)
    local b = CreateFrame("Button", nil, parent)
    b.tile = Skin.tile(b, GAME_SIZE)
    b.tile:SetPoint("CENTER")
    b.plate = Skin.plate(b.tile)
    b.plate:SetPoint("BOTTOMRIGHT", 0, -Skin.SPACE.xs)
    b:SetScript("OnEnter", function(self)
        Motion.scale(self.tile, TAL.grow, { dur = "fast" })
        talentTip(self)
    end)
    b:SetScript("OnLeave", function(self)
        Motion.scale(self.tile, 1, { dur = "fast" })
        hideTip()
    end)
    return b
end

-- Puts a talent on its button at a size.
local function showTalent(b, t, size)
    b.talent = t
    b:SetSize(size, size)
    local tile = b.tile
    if tile.size ~= size then
        tile.size = size
        tile:SetTileSize(size)
    end
    Motion.stop(tile, "scale")
    tile:SetScale(1)
    tile:SetIcon(t.icon or 134400)
    local state = stateOf(t)
    b.state = state
    tile:SetDimmed(state == "none")
    tile:SetLine(STATE[state].line, true)
    b.plate:SetShown(state ~= "none")
    if state ~= "none" then b.plate:Set(t.max > 0 and format("%d/%d", t.rank, t.max) or tostring(t.rank), STATE[state].rank) end
    b:Show()
end

-- Where each talent of your own tree goes: its tree, column and row.
local function talentGrid(talents)
    local xs, ys, seenX, seenY = {}, {}, {}, {}
    for _, t in ipairs(talents) do
        if t.x and t.y then
            if not seenX[t.x] then seenX[t.x], xs[#xs + 1] = true, t.x end
            if not seenY[t.y] then seenY[t.y], ys[#ys + 1] = true, t.y end
        end
    end
    table.sort(xs)
    table.sort(ys)
    local tree, first, colOf, treeOf, rowOf = 1, 1, {}, {}, {}
    for i, x in ipairs(xs) do
        if i > 1 and x - xs[i - 1] > 1500 then tree, first = min(tree + 1, 3), i end
        treeOf[x], colOf[x] = tree, i - first
    end
    for i, y in ipairs(ys) do rowOf[y] = i - 1 end
    for _, t in ipairs(talents) do
        if t.x and t.y then t.tree, t.col, t.row = treeOf[t.x], colOf[t.x], rowOf[t.y] end
    end
    return #ys
end

-- A tree's painting fills its place in the card without being stretched. The game's picture is 256
-- wide, in a top piece (256 tall) and a bottom one (128 tall, its art in its top 75: the talent window
-- shows 331 of the 384), so the painting is the top 85% of the two, its last dark rows left off; what
-- else doesn't fit the place's shape is cut evenly from both sides, or from the top and bottom.
local TREE_ART_BOTTOM = 0.85
local function showTreeArt(card, name, w, h)
    local a = card.art
    local shape = 256 / (384 * TREE_ART_BOTTOM)
    local u0, u1, v0, v1 = 0, 1, 0, TREE_ART_BOTTOM
    if w / h < shape then
        local cut = (1 - (w / h) / shape) / 2
        u0, u1 = cut, 1 - cut
    else
        local cut = TREE_ART_BOTTOM * (1 - shape / (w / h)) / 2
        v0, v1 = cut, TREE_ART_BOTTOM - cut
    end
    local split = 2 / 3 -- where the top piece ends in the whole picture
    local topH = h * max(0, min(v1, split) - v0) / (v1 - v0)
    a.top:SetShown(name ~= nil and topH > 0)
    a.bottom:SetShown(name ~= nil and topH < h)
    a.frame:SetSize(w, h)
    if not name then return end
    local base = "Interface\\TalentFrame\\" .. name
    a.top:SetSize(w, max(topH, 1))
    a.top:SetTexture(base .. "-TopLeft")
    a.top:SetTexCoord(u0, u1, v0 / split, min(v1, split) / split)
    a.bottom:ClearAllPoints()
    a.bottom:SetPoint("TOPLEFT", 0, -topH)
    a.bottom:SetSize(w, max(h - topH, 1))
    a.bottom:SetTexture(base .. "-BottomLeft")
    a.bottom:SetTexCoord(u0, u1, (max(v0, split) - split) / (1 - split), (v1 - split) / (1 - split))
end

-- The trees' layout for a talent's size: a column's and a row's pitch, the grid's place in the
-- painting, the painting's height (at least the whole picture at the card's width, to the 4-unit grid,
-- so a tree of a few talents still shows its painting, as the game's talent window does), and a tree
-- card's.
local PAINT_LEAST = floor(TAL.paint * 384 * TREE_ART_BOTTOM / 256 / 4) * 4
local function treeLayout(size, rows)
    local colPitch = size + max(TAL.colGap, floor((TAL.paint - 2 * TAL.around - TAL.cols * size) / (TAL.cols - 1)))
    local gridW = (TAL.cols - 1) * colPitch + size
    local rowPitch = size + TAL.rowGap
    local paintH = max(PAINT_LEAST, rows * size + max(rows - 1, 0) * TAL.rowGap + 2 * TAL.pad)
    return { size = size, colPitch = colPitch, rowPitch = rowPitch, left = floor((TAL.paint - gridW) / 2), paintH = paintH,
        cardH = Skin.CARD_HEAD + paintH + TAL.inset }
end

-- Legacy's card for a talent's size: how many talents a row, and its height.
local function legacyLayout(size, count)
    if count == 0 then return { perRow = 0, h = TAL.legacyBare } end
    local pitch = size + TAL.rowGap
    local perRow = max(1, floor((PAGE_WIDTH - 2 * TAL.around + TAL.rowGap) / pitch))
    local lines = ceil(count / perRow)
    return { perRow = perRow, pitch = pitch, h = Skin.CARD_HEAD + lines * size + (lines - 1) * TAL.rowGap + TAL.around }
end

local function showTalents(d, card, c)
    local names = TREES[card.classFile or ""] or { "Tree 1", "Tree 2", "Tree 3" }
    local art = TREE_ART[card.classFile or ""]
    local talents, rows, own = {}, 0, c and type(c.talents) == "table" and type(c.talents.nodes) == "table"
    if own then
        for _, n in ipairs(c.talents.nodes) do
            if type(n) == "table" and not n.hidden then talents[#talents + 1] = talentOf(n) end
        end
        rows = talentGrid(talents)
    else
        -- Another player's learned talents, in the order their tree runs, four to a row.
        for _, n in ipairs(card.tal and card.tal.n or {}) do talents[#talents + 1] = talentOf(n) end
        table.sort(talents, function(a, b) return (a.tree or 0) * 1e9 + (a.y or 0) * 1e4 + (a.x or 0) < (b.tree or 0) * 1e9 + (b.y or 0) * 1e4 + (b.x or 0) end)
        local inTree = { 0, 0, 0 }
        for _, t in ipairs(talents) do
            local k = min(max(t.tree or 1, 1), 3)
            t.tree, t.col, t.row = k, inTree[k] % TAL.cols, floor(inTree[k] / TAL.cols)
            inTree[k] = inTree[k] + 1
            rows = max(rows, t.row + 1)
        end
    end
    -- Points still to spend, and your own character's Legacy: what it has spent and what it learned.
    local left = own and num(c.talents.unspent) or num(card.tal and card.tal.left)
    local unspent = left and left > 0
    local lg = own and type(c.legacy) == "table" and type(c.legacy.trees) == "table" and c.legacy
    local learned = {}
    for _, t in ipairs(lg and lg.trees or {}) do
        for _, n in ipairs(type(t) == "table" and type(t.nodes) == "table" and t.nodes or {}) do
            local x = type(n) == "table" and not n.hidden and talentOf(n)
            if x and x.rank > 0 then learned[#learned + 1] = x end
        end
    end
    local legacyShown = lg and (#learned > 0 or (num(lg.left) or 0) > 0) and true or false
    -- The largest talents that let it all fit the page.
    local room = d.pageHeight or PAGE_HEIGHT
    local lay, leg
    for _, size in ipairs(TAL.sizes) do
        lay, leg = treeLayout(size, rows), legacyLayout(size, #learned)
        local tall = lay.cardH + (unspent and TAL.inset + TAL.note or 0) + (legacyShown and TAL.around + leg.h or 0)
        if tall <= room then break end
    end
    local size = lay.size
    -- A new player's talents, or the page coming into view: the cards fade in, then the talents arrive
    -- row by row, the arrows with the row they point to, then the Legacy.
    local fresh = d.arriving or d.talentsShown ~= d.who
    d.talentsShown = d.who
    local base = d.arriving and Motion.PAGE_AFTER or 0
    local function arrive(region, i) if fresh then Motion.arrive(region, i, { delay = base }) end end
    local points = { 0, 0, 0 }
    for i, tc in ipairs(d.treeCards) do
        tc:SetHeight(lay.cardH)
        Skin.label(tc.label, names[i])
        showTreeArt(tc, art and art[i], TAL.paint, lay.paintH)
        if fresh then Motion.fade(tc, 1, { from = 0, dur = "base", ease = "enter", delay = base + Motion.delay(i) }) end
    end
    local byId, used = {}, 0
    for _, t in ipairs(talents) do
        if t.tree and t.col and t.row then
            used = used + 1
            local tc = d.treeCards[t.tree]
            local b = d.talentButtons[used] or talentButton(tc.grid)
            d.talentButtons[used] = b
            b:SetParent(tc.grid)
            b:ClearAllPoints()
            b:SetPoint("TOPLEFT", lay.left + t.col * lay.colPitch, -(TAL.pad + t.row * lay.rowPitch))
            showTalent(b, t, size)
            arrive(b, t.row + 2)
            if t.id then byId[t.id] = b end
            points[t.tree] = points[t.tree] + t.rank
        end
    end
    for i = used + 1, #d.talentButtons do d.talentButtons[i]:Hide() end
    for i, tc in ipairs(d.treeCards) do
        tc.points:SetText(tostring(points[i]))
        tc.points:SetTextColor(Skin.rgb(points[i] > 0 and "parchment" or "dim"))
    end
    -- The arrows from a talent to those it leads to, gold once it is learned in full, sized to the
    -- talents: each tree draws its own, under its talents.
    local k = size / GAME_SIZE
    local drawn = { 0, 0, 0 }
    for i = 1, used do
        local from = d.talentButtons[i]
        local t = from.talent
        for _, id in ipairs(own and type(t.to) == "table" and t.to or {}) do
            local to = byId[id]
            if to then
                local tc = d.treeCards[t.tree]
                local grid = tc.grid
                drawn[t.tree] = drawn[t.tree] + 1
                local e = tc.edges[drawn[t.tree]]
                if not e then
                    e = { line = grid:CreateLine(nil, "ARTWORK"), head = grid:CreateTexture(nil, "ARTWORK", nil, 1) }
                    tc.edges[#tc.edges + 1] = e
                    d.talentLines[#d.talentLines + 1] = e
                end
                local active = t.max > 0 and t.rank >= t.max
                local tt = to.talent
                local ax, ay = (t.col - tt.col) * lay.colPitch, (tt.row - t.row) * lay.rowPitch
                local angle = math.atan2(ay, ax)
                local reach = (size / 2) / max(math.abs(math.cos(angle)), math.abs(math.sin(angle)))
                local ox, oy = math.cos(angle) * reach, math.sin(angle) * reach
                e.line:SetThickness(max(2, floor(6 * k + 0.5)))
                e.line:SetAtlas(active and "talents-arrow-line-yellow" or "talents-arrow-line-gray")
                e.line:SetStartPoint("CENTER", from)
                e.line:SetEndPoint("CENTER", to, ox, oy)
                e.head:SetAtlas(active and "talents-arrow-head-yellow" or "talents-arrow-head-gray", true)
                e.head:SetScale(k)
                e.head:ClearAllPoints()
                e.head:SetPoint("CENTER", to, "CENTER", ox / k, oy / k)
                e.head:SetRotation(angle - math.pi / 2)
                e.line:Show()
                e.head:Show()
                if fresh then
                    local at = base + Motion.delay(tt.row + 2)
                    Motion.fade(e.line, 1, { from = 0, dur = "base", ease = "enter", delay = at, owner = grid })
                    Motion.fade(e.head, 1, { from = 0, dur = "base", ease = "enter", delay = at, owner = grid })
                end
            end
        end
    end
    for i, tc in ipairs(d.treeCards) do
        for j = drawn[i] + 1, #tc.edges do tc.edges[j].line:Hide() tc.edges[j].head:Hide() end
    end
    -- Under the trees, the points still to spend, then the Legacy's card.
    local below = lay.cardH
    local muted, bright = Skin.code("muted"), Skin.code("parchment")
    d.talentNote:SetShown(unspent and true or false)
    if unspent then
        d.talentNote:ClearAllPoints()
        d.talentNote:SetPoint("TOPLEFT", 0, -(below + TAL.inset))
        d.talentNote:SetText(muted .. "Unspent talent points:|r  " .. bright .. left .. "|r")
        arrive(d.talentNote, rows + 2)
        below = below + TAL.inset + TAL.note
    end
    local lc = d.legacyCard
    lc:SetShown(legacyShown)
    for _, b in ipairs(d.legacyButtons) do b:Hide() end
    if legacyShown then
        lc:ClearAllPoints()
        lc:SetPoint("TOPLEFT", 0, -(below + TAL.around))
        lc:SetPoint("RIGHT")
        lc:SetHeight(leg.h)
        local bits = {}
        if num(lg.spent) then bits[#bits + 1] = bright .. big(lg.spent) .. "|r" .. muted .. " spent|r" end
        if (num(lg.left) or 0) > 0 then bits[#bits + 1] = bright .. big(lg.left) .. "|r" .. muted .. " to spend|r" end
        lc.spent:SetText(table.concat(bits, "   "))
        for i, t in ipairs(learned) do
            local b = d.legacyButtons[i] or talentButton(lc.grid)
            d.legacyButtons[i] = b
            b:ClearAllPoints()
            b:SetPoint("TOPLEFT", ((i - 1) % leg.perRow) * leg.pitch, -floor((i - 1) / leg.perRow) * leg.pitch)
            showTalent(b, t, size)
            arrive(b, rows + 3 + floor((i - 1) / leg.perRow))
        end
        if fresh then Motion.fade(lc, 1, { from = 0, dur = "base", ease = "enter", delay = base + Motion.delay(rows + 2) }) end
        below = below + TAL.around + leg.h
    end
    -- Whatever is left over after the smallest talents shrinks to fit: a tree taller than any the game has.
    local tr = d.trees
    tr:SetHeight(below)
    tr:SetScale(min(1, room / below))
end

-- The page: makeDetail makes it, showDetail fills it (showTalents).
function V.makeTalents(d)
    local page = d.pages.tal
    d.trees = CreateFrame("Frame", nil, page)
    d.trees:SetPoint("TOPLEFT")
    d.trees:SetWidth(PAGE_WIDTH)
    -- A tree's card: its name and points in the header, its painting (the one the game's talent window
    -- gives that tree, in its top and bottom pieces) inset under it, its talents and their arrows over
    -- the painting.
    d.treeCards = {}
    for i = 1, 3 do
        local tc = Skin.card(d.trees, "Tree")
        tc.rule:Hide()
        tc:SetPoint("TOPLEFT", (i - 1) * (TAL.card + TAL.gap), 0)
        tc:SetWidth(TAL.card)
        tc.label:SetPoint("RIGHT", -(Skin.SPACE.m + Skin.SPACE.xl + Skin.SPACE.s), 0)
        tc.points = Skin.text(tc, "numeral", "RIGHT")
        tc.points:SetPoint("BOTTOMRIGHT", tc, "TOPRIGHT", -Skin.SPACE.m, -(Skin.CARD_HEAD - 6))
        local frame = CreateFrame("Frame", nil, tc)
        frame:SetPoint("TOPLEFT", TAL.inset, -Skin.CARD_HEAD)
        local top = frame:CreateTexture(nil, "BACKGROUND")
        top:SetPoint("TOPLEFT")
        local bottom = frame:CreateTexture(nil, "BACKGROUND")
        -- Behind glass: a little dimmer than the game shows it, so the talents read over it.
        for _, t in ipairs({ top, bottom }) do t:SetVertexColor(0.78, 0.78, 0.78) t:Hide() end
        tc.art = { frame = frame, top = top, bottom = bottom }
        tc.grid = CreateFrame("Frame", nil, tc)
        tc.grid:SetAllPoints(frame)
        tc.grid:SetFrameLevel(frame:GetFrameLevel() + 1)
        tc.edges = {}
        d.treeCards[i] = tc
    end
    d.talentButtons, d.talentLines, d.legacyButtons = {}, {}, {}
    d.talentNote = Skin.text(d.trees, "small")
    d.talentNote:Hide()
    -- Legacy's card: what it has spent and has to spend in its header, the talents learned under it.
    d.legacyCard = Skin.card(d.trees, "Legacy")
    d.legacyCard.rule:Hide()
    d.legacyCard.spent = Skin.text(d.legacyCard, "small", "RIGHT")
    d.legacyCard.spent:SetPoint("BOTTOMRIGHT", d.legacyCard, "TOPRIGHT", -Skin.SPACE.m, -(Skin.CARD_HEAD - 7))
    d.legacyCard.label:SetPoint("RIGHT", d.legacyCard.spent, "LEFT", -Skin.SPACE.s, 0)
    d.legacyCard.grid = CreateFrame("Frame", nil, d.legacyCard)
    d.legacyCard.grid:SetPoint("TOPLEFT", TAL.around, -Skin.CARD_HEAD)
    d.legacyCard.grid:SetPoint("BOTTOMRIGHT", -TAL.around, TAL.around)
    d.legacyCard:Hide()
    -- The page coming into view again: its talents arrive again.
    page:HookScript("OnHide", function() d.talentsShown = nil end)
end

V.showTalents = showTalents
