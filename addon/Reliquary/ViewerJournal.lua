-- Reliquary's window: a character's Reputation and Quests pages (docs/DESIGN.md, section 5).
-- Reputation: a card for each of the game's groups (Alliance, and so on), in two columns once there
-- are two, each faction a row with its standing at the right and a bar in the game's colour for it.
-- Quests: a card for each zone, each quest with its level on a plate in the quest log's colour for
-- how hard it is, its objectives under it with a bar beside any that counts.
local ADDON, ns = ...

local V = ns.V
local Skin, Motion = ns.Skin, ns.Motion

local call, num, str = ns.call, ns.num, ns.str
local ipairs, type, tostring = ipairs, type, tostring
local floor, min, max = math.floor, math.min, math.max
local RED = ns.RED
local hideTip, showTip, big, PAGE_WIDTH = V.hideTip, V.showTip, V.big, V.PAGE_WIDTH

local STANDING = { "Hated", "Hostile", "Unfriendly", "Neutral", "Friendly", "Honored", "Revered", "Exalted" }

-- A standing's name as the game words it for the character (FACTION_STANDING_LABEL, by sex), and the
-- colour of its bar in the game's reputation list.
local STANDING_BAR = { { 0.8, 0.3, 0.22 }, { 0.8, 0.3, 0.22 }, { 0.75, 0.27, 0 }, { 0.9, 0.7, 0 }, { 0, 0.6, 0.1 }, { 0, 0.6, 0.1 },
    { 0, 0.6, 0.1 }, { 0, 0.6, 0.1 } }
local function standingName(r, sex)
    local ok, s = pcall(GetText, "FACTION_STANDING_LABEL" .. r, sex)
    return ok and str(s) or STANDING[r] or ""
end
local function standingBar(r)
    local c = FACTION_BAR_COLORS and FACTION_BAR_COLORS[r]
    if type(c) == "table" and type(c.GetRGB) == "function" then return { c:GetRGB() } end
    return STANDING_BAR[r]
end

-- How hard a quest is for the character whose log it is, in the quest log's own colours ({ r, g, b }).
local function questColor(level, questLevel)
    level, questLevel = num(level), num(questLevel)
    if not (level and questLevel) then return nil end
    local c
    if type(GetRelativeDifficultyColor) == "function" then
        local ok, got = pcall(GetRelativeDifficultyColor, level, questLevel)
        c = ok and got or nil
    end
    local colors = QuestDifficultyColors
    if type(c) ~= "table" and type(colors) == "table" then
        local diff = questLevel - level
        local range = num(call(UnitQuestTrivialLevelRange, "player")) or 5
        c = diff >= 5 and colors.impossible or diff >= 3 and colors.verydifficult or diff >= -4 and colors.difficult
            or -diff <= range and colors.standard or colors.trivial
    end
    if type(c) ~= "table" or not num(c.r) then return nil end
    return { c.r, c.g, c.b }
end

-- The pages' measures, in units. A card's title (the game's name for a group or a zone, so never the
-- label face) sits over a pixel line at Skin.CARD_HEAD, its rows from head on; an untitled card's rows
-- start at top. A faction is rep tall: its name and standing over its bar. A quest is quest tall, its
-- objectives obj each, its title past the plate; the bars beside a card's objectives are objBar wide,
-- in one column a gap past the longest objective that counts.
local CARD = { pad = Skin.SPACE.m, gap = Skin.SPACE.m, titleTop = 8, head = Skin.CARD_HEAD + Skin.SPACE.s, top = 9, foot = Skin.SPACE.s }
local REP = { row = 30, sub = 24, indent = Skin.SPACE.m, barFoot = 7, bar = 6, foot = Skin.SPACE.xs }
-- A faction's name (body) and its standing (small) stand on one line over the bar, their feet level. A
-- card ends foot under its last row: its last bar as far from the card's edge as its first name is from
-- the line under the title.
REP.textFoot = REP.barFoot + REP.bar + Skin.SPACE.xs
local QUEST = { row = 24, obj = 18, between = Skin.SPACE.xs, plate = { 24, 16 }, text = 32, objBar = 80, bar = 6 }

---------------------------------------------------------------------------
-- What the pages show
---------------------------------------------------------------------------
-- Reputation as the game's list has it: a card for each of its groups (a header at the top level),
-- each faction a row with its standing on a bar of its colour (how far into it on hover), a faction at
-- war in red; a group's own sub-groups are rows too, and the factions under one stand in a little.
local function repRow(r, sex, indent)
    local capped = r.r == #STANDING
    local into, span = (r.v or 0) - (r.lo or 0), (r.hi or 0) - (r.lo or 0)
    return { kind = "rep", name = r.n, war = r.w, indent = indent, standing = r.r and standingName(r.r, sex) or "",
        color = r.r and standingBar(r.r) or nil, fill = capped and 1 or span > 0 and into / span or 0,
        progress = not capped and span > 0 and (big(max(0, into)) .. " / " .. big(span)) or nil }
end

local function repCards(section, sex)
    local cards, card = {}, nil
    for _, r in ipairs(section and section.list or {}) do
        if r.h and not r.c then
            card = { title = r.n, rows = {} }
            cards[#cards + 1] = card
            if r.v then card.rows[1] = repRow(r, sex, 0) end
        else
            if not card then
                card = { rows = {} }
                cards[#cards + 1] = card
            end
            if r.h then card.sub = true end
            if r.h and not r.v then card.rows[#card.rows + 1] = { kind = "sub", name = r.n }
            else card.rows[#card.rows + 1] = repRow(r, sex, (r.c and not r.h and card.sub) and REP.indent or 0) end
        end
    end
    -- A group the game listed closed has nothing to show.
    local out = {}
    for _, c in ipairs(cards) do if #c.rows > 0 then out[#out + 1] = c end end
    return out
end

-- A card's height from what it holds.
local function repHeight(c)
    local h = c.title and CARD.head or CARD.top
    for _, row in ipairs(c.rows) do h = h + (row.kind == "sub" and REP.sub or REP.row) end
    return h + REP.foot
end

-- The cards laid out as a masonry in two columns, each card going to the column that is shorter so
-- far (the left one when they are level): a single group's card sits in the left one, at its own size.
-- Returns the height they take.
local function masonry(cards, width)
    local w = floor((width - CARD.gap) / 2)
    local heights = { 0, 0 }
    for _, c in ipairs(cards) do
        local col = heights[2] < heights[1] and 2 or 1
        c.x, c.y, c.w, c.h = (col - 1) * (w + CARD.gap), heights[col], w, repHeight(c)
        heights[col] = heights[col] + c.h + CARD.gap
    end
    return max(heights[1], heights[2]) - CARD.gap
end

-- The quest log: a card for each zone in the log's order, each quest with its level and how hard it is
-- for the character whose log it is, whether it's ready to turn in, and its objectives (one that counts,
-- "6/8", with how far along).
local function questCards(section, level)
    local cards, card, group = {}, nil, false
    for _, q in ipairs(section and section.list or {}) do
        if not card or q.g ~= group then
            group = q.g
            card = { kind = "zone", title = q.g, quests = {} }
            cards[#cards + 1] = card
        end
        local quest = { title = q.t, level = num(q.l), color = questColor(level, q.l), done = q.d, objs = {} }
        for _, o in ipairs(q.o or {}) do
            local have, need = o.t:match("(%d+)%s*/%s*(%d+)")
            have, need = tonumber(have), tonumber(need)
            quest.objs[#quest.objs + 1] = { text = o.t, done = o.d, have = need and need > 0 and have or nil, need = need and need > 0 and need or nil }
        end
        card.quests[#card.quests + 1] = quest
    end
    for _, c in ipairs(cards) do
        local h = c.title and CARD.head or CARD.top
        for i, quest in ipairs(c.quests) do h = h + (i > 1 and QUEST.between or 0) + QUEST.row + #quest.objs * QUEST.obj end
        c.h = h + CARD.foot
    end
    return cards
end

---------------------------------------------------------------------------
-- How they're drawn
---------------------------------------------------------------------------
-- A card with the game's name for what it holds as its title (the heading face: a name the game gives
-- is never put in the label face) over the card's pixel line.
local function titledCard(parent)
    local c = Skin.card(parent)
    c.title = Skin.text(c, "heading")
    c.title:SetTextColor(Skin.rgb("gold200"))
    c.title:SetPoint("TOPLEFT", CARD.pad, -CARD.titleTop)
    c.title:SetPoint("RIGHT", -CARD.pad, 0)
    c.rows = CreateFrame("Frame", nil, c)
    c.rows:SetPoint("TOPLEFT", CARD.pad, 0)
    c.rows:SetPoint("BOTTOMRIGHT", -CARD.pad, 0)
    c.repRows, c.questRows, c.objRows = {}, {}, {}
    function c:SetTitle(t)
        self.title:SetText(t or "")
        self.title:SetShown(t ~= nil)
        self.rule:SetShown(t ~= nil)
        return t and CARD.head or CARD.top
    end
    return c
end

-- A row's hover fill, under its words, faded in and out.
local function hoverFill(row)
    row.hl = Skin.nine(row, "disc", { radius = Skin.RADIUS.control, layer = "BACKGROUND", color = "ink800", inset = { -6, 0, -6, 0 } })
    row.hl:SetAlpha(0)
end
local function lit(row, on)
    Motion.fade(row.hl, on and 1 or 0, { from = row.hl.alpha or 0, dur = "fast", set = function(n, a) n:SetAlpha(a) end, owner = row })
end

-- A faction: its name, its standing at the right, its bar under them; how far into the standing on
-- hover. A sub-group's name alone.
local function repRowFrame(c)
    local row = CreateFrame("Frame", nil, c.rows)
    row:SetHeight(REP.row)
    hoverFill(row)
    row.name = Skin.text(row, "body")
    row.standing = Skin.text(row, "small", "RIGHT")
    row.standing:SetPoint("BOTTOMRIGHT", 0, REP.textFoot)
    row.bar = Skin.bar(row, REP.bar)
    row.bar:SetPoint("BOTTOMRIGHT", 0, REP.barFoot)
    row:EnableMouse(true)
    row:SetScript("OnEnter", function(self)
        local l = self.line
        if not l then return end
        lit(self, true)
        if l.progress then self.standing:SetText(l.progress) end
        if self.name:IsTruncated() then showTip(self, l.name) end
    end)
    row:SetScript("OnLeave", function(self)
        local l = self.line
        lit(self, false)
        if l then self.standing:SetText(l.standing or "") end
        hideTip()
    end)
    return row
end

-- A quest: its level on a plate in the colour of how hard it is, its title, and "Ready to turn in" at
-- the right once it is; an objective: its words, done in verdant, a thin bar beside one that counts.
local function questRowFrame(c)
    local row = CreateFrame("Frame", nil, c.rows)
    row:SetHeight(QUEST.row)
    row.plate = CreateFrame("Frame", nil, row)
    row.plate:SetSize(QUEST.plate[1], QUEST.plate[2])
    row.plate:SetPoint("LEFT")
    row.plate.surface = Skin.surface(row.plate, { fill = "ink800", line = "ink600", radius = Skin.RADIUS.control })
    row.plate.level = Skin.text(row.plate, "small", "CENTER", false, "OVERLAY")
    row.plate.level:SetPoint("CENTER", 0, 0)
    row.title = Skin.text(row, "heading")
    row.title:SetPoint("LEFT", QUEST.text, 0)
    row.ready = Skin.chip(row)
    row.ready:SetPoint("RIGHT")
    row.ready:Set("Ready to turn in", nil, nil, "verdant")
    row:EnableMouse(true)
    row:SetScript("OnEnter", function(self) if self.title:IsTruncated() then showTip(self, self.title:GetText() or "") end end)
    row:SetScript("OnLeave", hideTip)
    return row
end

local function objRowFrame(c)
    local row = CreateFrame("Frame", nil, c.rows)
    row:SetHeight(QUEST.obj)
    row.text = Skin.text(row, "small")
    row.text:SetPoint("LEFT", QUEST.text, 0)
    row.bar = Skin.bar(row, QUEST.bar)
    row.bar:SetWidth(QUEST.objBar)
    row:EnableMouse(true)
    row:SetScript("OnEnter", function(self) if self.text:IsTruncated() then showTip(self, self.text:GetText() or "") end end)
    row:SetScript("OnLeave", hideTip)
    return row
end

-- A bar arriving fills from nothing after the bars before it; drawn again it moves from what it showed;
-- seen for the first time otherwise (scrolled to), it is simply there.
local function fill(d, bar, key, value, most)
    local was = d.barShown[key]
    if d.journalArriving then
        d.barsArriving = d.barsArriving + 1
        bar:Set(value, most, { from = 0, delay = d.journalArriving + Motion.delay(d.barsArriving) })
    elseif was then bar:Set(value, most, { from = was })
    else bar:Set(value, most, { instant = true }) end
    d.barShown[key] = bar.target
end

local function hideFrom(list, n) for i = n, #list do list[i]:Hide() end end

local function drawReps(d, c, card)
    local y = c:SetTitle(card.title)
    local n = 0
    for _, line in ipairs(card.rows) do
        n = n + 1
        local row = c.repRows[n] or repRowFrame(c)
        c.repRows[n] = row
        row.line = line
        row:Show() -- shown before its bar is set, so the bar moves rather than lands
        Motion.stop(row.hl, "alpha")
        row.hl:SetAlpha(0)
        local sub = line.kind == "sub"
        local h = sub and REP.sub or REP.row
        row:SetHeight(h)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", 0, -y)
        row:SetPoint("TOPRIGHT", 0, -y)
        row:EnableMouse(not sub)
        row.name:ClearAllPoints()
        Skin.setRole(row.name, sub and "small" or "body")
        row.name:SetTextColor(Skin.rgb(sub and "gold400" or "parchment"))
        row.name:SetText(line.war and (RED .. line.name .. "|r") or line.name)
        row.standing:SetShown(not sub)
        row.bar:SetShown(not sub)
        if sub then
            row.name:SetPoint("BOTTOMLEFT", 0, REP.barFoot)
            row.name:SetPoint("RIGHT")
        else
            row.name:SetPoint("BOTTOMLEFT", line.indent, REP.textFoot)
            row.name:SetPoint("RIGHT", row.standing, "LEFT", -Skin.SPACE.s, 0)
            row.standing:SetText(line.standing)
            row.bar:SetPoint("BOTTOMLEFT", line.indent, REP.barFoot)
            if line.color then row.bar:SetColor(line.color[1], line.color[2], line.color[3]) else row.bar:SetColor("gold300") end
            fill(d, row.bar, "rep:" .. line.name, line.fill, 1)
        end
        y = y + h
    end
    hideFrom(c.repRows, n + 1)
end

local function drawZone(d, c, card)
    local y = c:SetTitle(card.title)
    local nq, no = 0, 0
    -- Where the card's bars stand: past the longest objective that counts, the bar never past the edge.
    if not c.measure then
        c.measure = Skin.text(c, "small")
        c.measure:SetPoint("TOPLEFT")
        c.measure:SetAlpha(0) -- shown, so the game measures it as it lays out text it draws, and never seen
    end
    local longest = 0
    for _, q in ipairs(card.quests) do
        for _, o in ipairs(q.objs) do
            if o.need then
                c.measure:SetText(o.text)
                longest = max(longest, c.measure:GetStringWidth() or 0)
            end
        end
    end
    c.measure:SetText("")
    local barAt = min(QUEST.text + floor(longest + 0.5) + Skin.SPACE.m, (card.w or PAGE_WIDTH) - 2 * CARD.pad - QUEST.objBar)
    for qi, q in ipairs(card.quests) do
        if qi > 1 then y = y + QUEST.between end
        nq = nq + 1
        local row = c.questRows[nq] or questRowFrame(c)
        c.questRows[nq] = row
        row.line = q
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", 0, -y)
        row:SetPoint("TOPRIGHT", 0, -y)
        row.plate:SetShown(q.level ~= nil)
        if q.level then
            local col = q.color or Skin.C.muted
            row.plate.level:SetText(tostring(q.level))
            row.plate.level:SetTextColor(col[1], col[2], col[3])
            row.plate.surface:SetLine({ col[1] * 0.8, col[2] * 0.8, col[3] * 0.8 })
        end
        row.ready:SetShown(q.done and true or false)
        row.title:SetText(q.title)
        row.title:SetPoint("RIGHT", q.done and row.ready or row, q.done and "LEFT" or "RIGHT", q.done and -Skin.SPACE.s or 0, 0)
        row:Show()
        y = y + QUEST.row
        for oi, o in ipairs(q.objs) do
            no = no + 1
            local obj = c.objRows[no] or objRowFrame(c)
            c.objRows[no] = obj
            obj.line = o
            obj:Show()
            obj:ClearAllPoints()
            obj:SetPoint("TOPLEFT", 0, -y)
            obj:SetPoint("TOPRIGHT", 0, -y)
            obj.text:SetText(o.text)
            obj.text:SetTextColor(Skin.rgb(o.done and "verdant" or "muted"))
            local counts = o.need ~= nil
            obj.bar:SetShown(counts)
            obj.bar:ClearAllPoints()
            obj.bar:SetPoint("LEFT", barAt, 0)
            obj.text:SetPoint("RIGHT", counts and obj.bar or obj, counts and "LEFT" or "RIGHT", counts and -Skin.SPACE.m or 0, 0)
            if counts then
                obj.bar:SetColor(o.done and "verdant" or "gold300")
                fill(d, obj.bar, "obj:" .. q.title .. ":" .. oi, o.have or 0, o.need)
            end
            y = y + QUEST.obj
        end
    end
    hideFrom(c.questRows, nq + 1)
    hideFrom(c.objRows, no + 1)
end

-- Each element of the list: the reputation's whole masonry, or one zone's card.
local function drawElement(d, f, element)
    f.element = element
    f.cards = f.cards or {}
    local list = element.kind == "reps" and element.cards or { element }
    for i, card in ipairs(list) do
        local c = f.cards[i] or titledCard(f)
        f.cards[i] = c
        Motion.stop(c)
        c:SetAlpha(1)
        c:ClearAllPoints()
        c:SetPoint("TOPLEFT", card.x or 0, -(card.y or 0))
        c:SetSize(card.w or PAGE_WIDTH, card.h)
        c.card = card
        if element.kind == "reps" then
            drawReps(d, c, card)
            hideFrom(c.questRows, 1)
            hideFrom(c.objRows, 1)
        else
            drawZone(d, c, card)
            hideFrom(c.repRows, 1)
        end
        c:Show()
    end
    hideFrom(f.cards, #list + 1)
end

-- The page: makeDetail makes it, showDetail fills it.
function V.makeJournal(d)
    d.barShown = {}
    d.list, d.listBar = Skin.scroll(d.pages.list, { frameType = "Frame", right = 0, fade = Skin.SPACE.xl,
        init = function(f, element) drawElement(d, f, element) end,
        extent = function(element) return element.extent end })
    -- The page arrives again each time it is shown anew.
    d.pages.list:HookScript("OnHide", function() d.journalOn = nil end)
end

function V.showJournal(d, page, card, more, keep)
    local elements
    if page == "reps" then
        local cards = repCards(more.reps, card.sex)
        elements = { { kind = "reps", cards = cards, extent = max(1, masonry(cards, PAGE_WIDTH) + CARD.gap) } }
    else
        elements = questCards(more.quests, card.level)
        for _, c in ipairs(elements) do c.extent = c.h + CARD.gap end
    end
    for i, e in ipairs(elements) do e.order = i end
    -- A new player, or the page newly shown: its cards arrive one after another and its bars fill.
    local on = (d.who or "") .. "|" .. page
    local arriving = d.arriving or d.journalOn ~= on
    d.journalOn = on
    if arriving then d.barShown = {} end
    d.journalArriving, d.barsArriving = arriving and (d.arriving and Motion.PAGE_AFTER or 0) or nil, 0
    d.list:SetDataProvider(CreateDataProvider(elements), keep)
    if arriving then
        local frames, n = {}, 0
        for _, f in ipairs(d.list:GetFrames()) do if f.element then frames[#frames + 1] = f end end
        table.sort(frames, function(a, b) return a.element.order < b.element.order end)
        for _, f in ipairs(frames) do
            for _, c in ipairs(f.cards) do
                if c:IsShown() then
                    n = n + 1
                    Motion.arrive(c, n, { delay = d.journalArriving })
                end
            end
        end
    end
    d.journalArriving = nil
end
