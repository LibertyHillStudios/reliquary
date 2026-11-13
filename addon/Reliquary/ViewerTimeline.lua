-- Reliquary's window: a character's Timeline page (Timeline.lua and History.lua keep it).
local ADDON, ns = ...

local V = ns.V
local Skin, Motion = ns.Skin, ns.Motion

local num, str = ns.num, ns.str
local pairs, ipairs, type = pairs, ipairs, type
local floor, min, max, format = math.floor, math.min, math.max, string.format
local sound, hideTip, showTip, played, big = V.sound, V.hideTip, V.showTip, V.played, V.big
local plural, dayText, clockText = V.plural, V.dayText, V.clockText

---------------------------------------------------------------------------
-- A character's timeline (Timeline.lua and History.lua keep it): its stops, newest first, then what
-- the game remembered from before Reliquary. Only the game's own names and numbers: nothing here is
-- written about the character, and anything in the saved data that isn't one is left out.
---------------------------------------------------------------------------
local LATE, FIRST_SLACK = 45, 120 -- the timeline looks every 30 s, and notes a new place a moment after
local BEFORE_PARTS = { challenges = "Legacy challenges", quests = "completed quests", explored = "the explored map",
    stats = "statistics", pvp = "PvP", titles = "titles" }

local function count(v)
    v = num(v)
    return v and v >= 1 and floor(v) or nil
end


-- A name or title as the game gave it, shown as plain text (a "|" can't start one of the game's codes).
local function says(v, limit)
    v = str(v)
    v = v and v:match("^%s*(.-)%s*$")
    if not v or v == "" then return nil end
    limit = limit or 120
    if #v > limit then v = v:sub(1, limit):gsub("[\192-\255][\128-\191]*$", "") end
    return (v:gsub("|", "||"))
end


local function hoursText(from, to)
    local a, b = clockText(from, true), clockText(to, true)
    if a == b then return a end
    local bare = clockText(from, false)
    -- One AM or PM for a stretch within one half of one day: 5:22-5:56 PM.
    local function half(t) return date("%Y%m%d", t) .. (tonumber(date("%H", t)) < 12 and "a" or "p") end
    if bare ~= a and half(from) == half(to) then return bare .. "-" .. b end
    return a .. "-" .. b
end

local function activeText(sec)
    sec = max(0, floor(num(sec) or 0))
    local h, m = floor(sec / 3600), floor(sec % 3600 / 60 + 0.5)
    if m == 60 then h, m = h + 1, 0 end
    if h > 0 then return m > 0 and format("%d h %d min", h, m) or format("%d h", h) end
    return format("%d min", max(1, m))
end

local function isoDay(v)
    if type(v) ~= "string" then return nil end
    local y, m, d = v:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
    if not y then return nil end
    y, m, d = tonumber(y), tonumber(m), tonumber(d)
    if not V.MONTHS[m] or d < 1 or d > 31 then return nil end
    return format("%s %d", V.MONTHS[m], d) .. (y ~= tonumber(date("%Y", time())) and (", " .. y) or "")
end

-- A stop as the timeline kept it (an entry, or a day folded after 30 days), or nil when its zone or
-- times are missing or out of order.
local function stopOf(e, folded, places)
    if type(e) ~= "table" then return nil end
    local zone, from, to = says(e.zone), num(e.from), num(e.to)
    if not (zone and from and to and to >= from) then return nil end
    local x = { zone = zone, from = from, to = to, folded = folded, key = (folded and "d" or "e") .. floor(from) .. zone }
    -- An entry's active time never exceeds its own span (give or take one look).
    x.active = max(0, folded and (num(e.active) or 0) or min(num(e.active) or 0, to - from + 60))
    x.level, x.levelTo = count(e.level), count(e.levelTo)
    if x.levelTo and x.level and x.levelTo < x.level then x.levelTo = nil end
    x.kills = count(e.kills)
    if folded then
        x.quests, x.challenges, x.xp = count(e.quests), count(e.challenges), count(e.xp)
        x.opens = x.xp ~= nil
        return x
    end
    x.questList, x.xp = {}, 0
    for _, q in ipairs(type(e.quests) == "table" and e.quests or {}) do
        if type(q) == "table" then
            local xp = count(q.xp)
            x.questList[#x.questList + 1] = { title = says(q.title) or ("Quest " .. (count(q.id) or "")), xp = xp }
            x.xp = x.xp + (xp or 0)
        end
    end
    x.quests = #x.questList > 0 and #x.questList or nil
    x.challengeList = {}
    for _, ch in ipairs(type(e.challenges) == "table" and e.challenges or {}) do
        local name = type(ch) == "table" and says(ch.name)
        if name then x.challengeList[#x.challengeList + 1] = name end
    end
    x.challenges = #x.challengeList > 0 and #x.challengeList or nil
    x.passed = {}
    local seen = { [zone] = true }
    for _, z in ipairs(type(e.passed) == "table" and e.passed or {}) do
        z = says(z)
        if z and not seen[z] then seen[z], x.passed[#x.passed + 1] = true, z end
    end
    -- The first time the character stood in this zone, by the record of places.
    local first = type(places) == "table" and num(places[e.zone])
    x.first = first and from - FIRST_SLACK <= first and first <= to + LATE or nil
    x.opens = #x.questList > 0 or #x.challengeList > 0 or #x.passed > 0
    return x
end

-- What the game remembered when Reliquary first ran (History.lua), or nil until it was read.
local function beforeOf(b)
    if type(b) ~= "table" or b.done ~= true or not num(b.at) then return nil end
    local x = { at = num(b.at), level = count(b.level), played = count(b.played), challenges = {}, explored = {}, stats = {}, titles = {} }
    for _, ch in ipairs(type(b.challenges) == "table" and b.challenges or {}) do
        local name = type(ch) == "table" and says(ch.name)
        if name then
            x.challenges[#x.challenges + 1] = { name = name, iso = type(ch.date) == "string" and isoDay(ch.date) and ch.date or nil,
                description = says(ch.description, 300), points = count(ch.points) }
        end
    end
    table.sort(x.challenges, function(p, q) return (p.iso or "") > (q.iso or "") end) -- newest first, as the stops run
    local q = type(b.quests) == "table" and b.quests
    local done = q and count(q.count)
    if done then
        local titles = type(q.titles) == "table" and q.titles or {}
        x.quests = { count = done, titles = {} }
        for _, id in ipairs(type(q.ids) == "table" and q.ids or {}) do
            local t = says(titles[id])
            if t then x.quests.titles[#x.quests.titles + 1] = t end
        end
        table.sort(x.quests.titles) -- in an order a player can find one in
    end
    for _, z in ipairs(type(b.explored) == "table" and b.explored or {}) do
        local zone = type(z) == "table" and says(z.zone)
        if zone then
            local areas, seen = {}, {}
            for _, a in ipairs(type(z.areas) == "table" and z.areas or {}) do
                a = says(a)
                if a and not seen[a] then seen[a], areas[#areas + 1] = true, a end
            end
            table.sort(areas)
            x.explored[#x.explored + 1] = { zone = zone, areas = areas }
        end
    end
    table.sort(x.explored, function(p, r) return p.zone < r.zone end)
    -- Flight paths are left out: Forever's world map marks every one found (History.lua).
    for _, st in ipairs(type(b.stats) == "table" and b.stats or {}) do
        local name, value = type(st) == "table" and says(st.name), type(st) == "table" and count(st.value)
        if name and value then x.stats[#x.stats + 1] = { name = name, value = value, group = says(st.group, 80) or "Statistics", sub = says(st.sub, 80) } end
    end
    x.honorKills = type(b.pvp) == "table" and count(b.pvp.kills) or nil
    local seen = {}
    for _, t in ipairs(type(b.titles) == "table" and b.titles or {}) do
        t = says(t, 80)
        if t and not seen[t] then seen[t], x.titles[#x.titles + 1] = true, t end
    end
    x.missing = {}
    for part, why in pairs(type(b.missing) == "table" and b.missing or {}) do
        if BEFORE_PARTS[part] and str(why) then x.missing[#x.missing + 1] = BEFORE_PARTS[part] end
    end
    table.sort(x.missing)
    return x
end

-- Every stop, newest first, and what came before them; nil when there is nothing yet.
local function roadOf(c)
    local t = type(c.timeline) == "table" and c.timeline or {}
    local entries, days = {}, {}
    for _, e in ipairs(type(t.entries) == "table" and t.entries or {}) do entries[#entries + 1] = stopOf(e, false, c.places) end
    for _, e in ipairs(type(t.days) == "table" and t.days or {}) do days[#days + 1] = stopOf(e, true) end
    table.sort(entries, function(p, q) return p.from > q.from end)
    table.sort(days, function(p, q) return p.from > q.from end)
    local stops = entries
    for _, x in ipairs(days) do stops[#stops + 1] = x end
    local before = beforeOf(c.before)
    -- What the game remembered, when it remembered anything: a fresh character's is left out.
    if before and not (before.quests or before.honorKills or #before.challenges > 0 or #before.explored > 0 or #before.stats > 0
        or #before.titles > 0) then before = nil end
    if #stops == 0 and not before then return nil end
    return { stops = stops, before = before, hiddenKills = count(t.hiddenKills) }
end


-- What a stop shows as chips: its active time, then what happened there.
local function stopFacts(x)
    local facts = { activeText(x.active) }
    if x.quests then facts[#facts + 1] = plural(x.quests, "quest", "quests") end
    if x.challenges then facts[#facts + 1] = plural(x.challenges, "challenge", "challenges") end
    if x.kills then facts[#facts + 1] = plural(x.kills, "killing blow", "killing blows") end
    return facts
end

local function levelText(x)
    if not x.level then return "" end
    return (x.levelTo and x.levelTo > x.level) and format("Level %d to %d", x.level, x.levelTo) or ("Level " .. x.level)
end

-- When a stop was: its day and hours, both days when it ran past midnight, its day when folded.
local function whenText(x)
    if x.folded then return dayText(x.from) end
    if date("%Y%m%d", x.from) ~= date("%Y%m%d", x.to) then
        return dayText(x.from) .. ", " .. clockText(x.from, true) .. " - " .. dayText(x.to) .. ", " .. clockText(x.to, true)
    end
    return dayText(x.from) .. "  ·  " .. hoursText(x.from, x.to)
end

---------------------------------------------------------------------------
-- The page (docs/DESIGN.md, section 5): a pixel line down the left with a small gold ring at each
-- stop, and each stop a card: its zone, its day and hours at the right, its facts as chips and its
-- level. A stop with details opens on a click, its card easing open to show its lines; Before
-- Reliquary is the last card, its groups opening the same way.
---------------------------------------------------------------------------
-- In units. A card's head is pad, its zone's line (title), gap, its chips' row, pad; opened, a pixel
-- line at the head's foot and its lines under it, from linesTop below the line to foot above the card's
-- edge. The gutter left of the cards holds the line (axis) and the rings, each level with the middle of
-- its zone's capitals (ringDrop under the middle of the zone's line). First visit and the day and hours
-- stand on the zone's line: at one foot with it the small face's letters stand footDrop lower than the
-- title face's (a shorter descent, measured in the renders), so they are raised by that.
local ROAD = { gutter = 24, axis = 8, ring = 10, pad = Skin.SPACE.m, title = 16, gap = Skin.SPACE.s, chips = 20, chipGap = Skin.SPACE.s,
    chevron = 12, linesTop = Skin.SPACE.xs, foot = Skin.SPACE.s, between = Skin.SPACE.s, indent = Skin.SPACE.m, note = 24, labelFoot = 6,
    ringDrop = 2, footDrop = 1.5 }
ROAD.head = 2 * ROAD.pad + ROAD.title + ROAD.gap + ROAD.chips -- with chips or a level
ROAD.bare = 2 * ROAD.pad + ROAD.title                        -- with neither
ROAD.card = V.PAGE_WIDTH - ROAD.gutter
-- Its lines: a heading (the label face, Reliquary's own words), a line, a group that folds, a note.
local LINE = { sub = 24, line = 18, group = 24, note = 18 }

-- The lines an open stop shows: the quests handed in there (each with the experience it gave), the
-- Legacy challenges earned there, and the zones passed through on the way.
local function stopLines(x)
    local out = {}
    local function line(left, right, tip) out[#out + 1] = { kind = "line", left = left, right = right, tip = tip } end
    if x.questList and #x.questList > 0 then
        out[#out + 1] = { kind = "sub", left = "Quests handed in" }
        for _, q in ipairs(x.questList) do
            line(q.title, q.xp and ("+" .. big(q.xp) .. " XP") or nil)
            out[#out].gain = q.xp ~= nil
        end
    elseif x.folded and x.xp then
        line("Experience from quests", "+" .. big(x.xp) .. " XP")
        out[#out].gain = true
    end
    if x.challengeList and #x.challengeList > 0 then
        out[#out + 1] = { kind = "sub", left = "Legacy challenges" }
        for _, name in ipairs(x.challengeList) do line(name) end
    end
    if x.passed and #x.passed > 0 then
        out[#out + 1] = { kind = "sub", left = "Passed through" }
        line(table.concat(x.passed, ", "))
    end
    return out
end

-- What Before Reliquary shows opened: the honorable kills, then each group, folded as the game's own
-- Statistics categories are: closed, how many lines it holds; a click opens it (open["before:<group>"]).
local function beforeLines(b, open)
    local out = {}
    local function line(left, right, tip, indent) out[#out + 1] = { kind = "line", left = left, right = right, tip = tip, indent = indent } end
    local function group(label, count, fill)
        local key = "before:" .. label
        out[#out + 1] = { kind = "group", key = key, open = open[key], left = label, right = big(count) }
        if open[key] then fill() end
    end
    local inner = ROAD.indent
    if b.honorKills then line("Honorable kills", big(b.honorKills)) end
    if #b.challenges > 0 then
        group("Legacy challenges", #b.challenges, function()
            for _, ch in ipairs(b.challenges) do
                local when = {}
                if ch.iso then when[#when + 1] = isoDay(ch.iso) end
                if ch.points then when[#when + 1] = big(ch.points) .. " pts" end
                line(ch.name, table.concat(when, "  ·  "), ch.description and { ch.description } or nil, inner)
            end
        end)
    end
    if #b.explored > 0 then
        group("Zones explored", #b.explored, function()
            for _, z in ipairs(b.explored) do line(z.zone, plural(#z.areas, "area", "areas"), #z.areas > 0 and { table.concat(z.areas, ", ") } or nil, inner) end
        end)
    end
    local groups, order = {}, {}
    for _, st in ipairs(b.stats) do
        if not groups[st.group] then groups[st.group], order[#order + 1] = {}, st.group end
        table.insert(groups[st.group], st)
    end
    for _, name in ipairs(order) do
        group(name, #groups[name], function()
            for _, st in ipairs(groups[name]) do line((st.sub and (st.sub .. ": ") or "") .. st.name, big(st.value), nil, inner) end
        end)
    end
    if b.quests and #b.quests.titles > 0 then
        group("Quests completed", b.quests.count, function()
            for _, title in ipairs(b.quests.titles) do line(title, nil, nil, inner) end
            local unnamed = b.quests.count - #b.quests.titles
            if unnamed > 0 then out[#out + 1] = { kind = "note", left = plural(unnamed, "more quest", "more quests") .. " the game hasn't given a title for yet.", indent = inner } end
        end)
    end
    if #b.titles > 0 then
        group("Titles", #b.titles, function() line(table.concat(b.titles, ", "), nil, nil, inner) end)
    end
    if #b.missing > 0 then out[#out + 1] = { kind = "note", left = "The game gave nothing for " .. table.concat(b.missing, ", ") .. "." } end
    return out
end

-- A card's height: its head (shorter with no chips and no level), and opened, its lines under it.
local function cardHeight(e)
    local head = (#e.chips > 0 or e.level ~= "") and ROAD.head or ROAD.bare
    e.headH = head
    if not e.lines then return head end
    local h = head + ROAD.linesTop
    for _, l in ipairs(e.lines) do h = h + LINE[l.kind] end
    return h + ROAD.foot
end

-- The page's cards, newest first, then Before Reliquary, then a note on the kills the game kept from
-- Reliquary; a card opened (open[key]) holds its lines. Each knows its place (order) and its height.
local function roadCards(road, open)
    local out = {}
    for _, x in ipairs(road.stops) do
        local chips = stopFacts(x)
        local e = { kind = "stop", key = x.opens and x.key or nil, zone = x.zone, first = x.first, when = whenText(x), chips = chips,
            facts = table.concat(chips, "  ·  "), level = levelText(x),
            tip = x.folded and { "Every stretch in " .. x.zone .. " that day, kept as one line after 30 days." } or nil }
        e.open = e.key and open[e.key] or nil
        if e.open then e.lines = stopLines(x) end
        out[#out + 1] = e
    end
    local b = road.before
    if b then
        local chips = {}
        if b.quests then chips[#chips + 1] = plural(b.quests.count, "quest", "quests") end
        if #b.explored > 0 then chips[#chips + 1] = plural(#b.explored, "zone explored", "zones explored") end
        if #b.challenges > 0 then chips[#chips + 1] = plural(#b.challenges, "challenge", "challenges") end
        local lv = {}
        if b.level then lv[#lv + 1] = "Level " .. b.level end
        if b.played then lv[#lv + 1] = played(b.played) end
        local e = { kind = "stop", key = "before", open = open.before, zone = "Before Reliquary", when = "Up to " .. dayText(b.at), chips = chips,
            facts = table.concat(chips, "  ·  "), level = table.concat(lv, "  ·  "),
            tip = { "What the game remembered on " .. dayText(b.at) .. ", the first time Reliquary ran. The game keeps dates only for challenges." } }
        if open.before then e.lines = beforeLines(b, open) end
        out[#out + 1] = e
    end
    for i, e in ipairs(out) do
        e.order, e.h = i, cardHeight(e)
        e.extent = e.h + ROAD.between
    end
    if out[1] then out[1].firstCard, out[#out].lastCard = true, true end
    if road.hiddenKills then
        out[#out + 1] = { kind = "note", order = #out + 1, extent = ROAD.note,
            left = "Kills whose killer the game kept hidden from Reliquary: " .. big(road.hiddenKills) .. ", not counted as killing blows." }
    end
    return out
end

---------------------------------------------------------------------------
-- How it's drawn
---------------------------------------------------------------------------
local fold -- below: opens or closes a card, easing

-- A card's height while it eases: the card, and what holds it with the gap under it.
local function setHeight(f, h)
    f.card:SetHeight(h)
    f.content:SetHeight(h + ROAD.between)
end

-- The chevron a card or a group shows: down while closed, up while open.
local function chevrons(parent)
    local c = { down = Skin.glyph(parent, "chevronDown", ROAD.chevron, "dim", "OVERLAY"), up = Skin.glyph(parent, "chevronUp", ROAD.chevron, "dim", "OVERLAY") }
    function c:Set(shown, open)
        self.down:SetShown(shown and not open)
        self.up:SetShown(shown and open and true or false)
    end
    function c:Tint(color, dur)
        Skin.tint(self.down, "glyph", color, dur)
        Skin.tint(self.up, "glyph", color, dur)
    end
    return c
end

-- A line in an open card: a heading, a line (its value at the right, cut short with the whole of it on
-- hover), a group that folds (how many it holds, a chevron), or a note.
local function lineRow(d, card)
    local row = CreateFrame("Button", nil, card.lines)
    row.hl = Skin.nine(row, "disc", { radius = Skin.RADIUS.control, layer = "BACKGROUND", color = "ink800", inset = { ROAD.pad - 6, 1, ROAD.pad - 6, 1 } })
    row.hl:SetAlpha(0)
    row.left = Skin.text(row, "body")
    row.right = Skin.text(row, "small", "RIGHT")
    row.chev = chevrons(row)
    row.chev.down:SetPoint("RIGHT", -ROAD.pad, 0)
    row.chev.up:SetPoint("RIGHT", -ROAD.pad, 0)
    local function lit(self, on)
        Motion.fade(self.hl, on and 1 or 0, { from = self.hl.alpha or 0, dur = "fast", set = function(n, a) n:SetAlpha(a) end, owner = self })
        self.chev:Tint(on and "parchment" or "dim")
    end
    row:SetScript("OnEnter", function(self)
        local l = self.line
        if not l then return end
        if l.kind == "group" then lit(self, true) end
        if l.tip or self.left:IsTruncated() then showTip(self, l.left or "", l.tip) end
    end)
    row:SetScript("OnLeave", function(self)
        if self.line and self.line.kind == "group" then lit(self, false) end
        hideTip()
    end)
    row:SetScript("OnClick", function(self)
        local l = self.line
        if l and l.kind == "group" then fold(d, l.key) end
    end)
    return row
end

local function drawLines(d, card, lines)
    local y = ROAD.linesTop
    local rows = card.rows
    for i, l in ipairs(lines or {}) do
        local row = rows[i] or lineRow(d, card)
        rows[i] = row
        row.line = l
        local h = LINE[l.kind]
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", 0, -y)
        row:SetPoint("TOPRIGHT", 0, -y)
        row:SetHeight(h)
        Motion.stop(row.hl, "alpha")
        row.hl:SetAlpha(0)
        local group, sub, note = l.kind == "group", l.kind == "sub", l.kind == "note"
        local x = ROAD.pad + (l.indent or 0)
        row.left:ClearAllPoints()
        row.right:ClearAllPoints()
        Skin.setRole(row.left, sub and "label" or note and "dim" or "body")
        row.chev:Set(group, l.open)
        row.chev:Tint("dim", 0)
        local value = not (sub or note) and l.right ~= nil and l.right ~= ""
        row.right:SetShown(value)
        if group then
            Skin.setRole(row.right, "numeral", "RIGHT")
            row.right:SetTextColor(Skin.rgb("muted"))
            row.right:SetPoint("RIGHT", row.chev.down, "LEFT", -ROAD.gap, 0)
        else
            Skin.setRole(row.right, "small", "RIGHT")
            row.right:SetTextColor(Skin.rgb(l.gain and "verdant" or "muted"))
            row.right:SetPoint("RIGHT", -(ROAD.pad + ROAD.chevron + ROAD.gap), 0) -- in one column with the head's day and level
        end
        row.right:SetText(l.right or "")
        if sub then
            Skin.label(row.left, l.left)
            row.left:SetPoint("BOTTOMLEFT", x, ROAD.labelFoot)
            row.left:SetPoint("RIGHT", -ROAD.pad, 0)
        else
            row.left:SetText(l.left or "")
            row.left:SetPoint("LEFT", x, 0)
            if value then row.left:SetPoint("RIGHT", row.right, "LEFT", -ROAD.gap, 0)
            else row.left:SetPoint("RIGHT", -ROAD.pad, 0) end
        end
        row:EnableMouse(not sub)
        row:Show()
        y = y + h
    end
    for i = #(lines or {}) + 1, #rows do rows[i]:Hide() end
end

-- The stop's head: its zone and First visit, its day and hours at the right, its chips and its level.
-- The chips that don't fit before the level are left to its hover.
local function drawHead(card, e)
    local head = card.head
    local right = ROAD.pad + ROAD.chevron + ROAD.gap
    head.when:SetText(e.when or "")
    head.first:SetShown(e.first and true or false)
    head.zone:SetText(e.zone)
    local room = ROAD.card - ROAD.pad - right - (head.when:GetStringWidth() or 0) - ROAD.gap
        - (e.first and ((head.first:GetStringWidth() or 0) + ROAD.gap) or 0)
    head.zone:SetWidth(max(1, min(head.zone:GetStringWidth() or 0, room)))
    head.level:SetText(e.level or "")
    local x, most = 0, ROAD.card - right - ROAD.pad - (e.level ~= "" and (head.level:GetStringWidth() or 0) + ROAD.gap or 0)
    head.dropped = false
    for i, fact in ipairs(e.chips) do
        local chip = head.chips[i] or Skin.chip(head)
        head.chips[i] = chip
        chip:Set(fact)
        local fits = not head.dropped and x + chip.width <= most
        head.dropped = head.dropped or not fits
        chip:SetShown(fits)
        if fits then
            chip:ClearAllPoints()
            chip:SetPoint("TOPLEFT", ROAD.pad + x, -(ROAD.pad + ROAD.title + ROAD.gap))
            x = x + chip.width + ROAD.chipGap
        end
    end
    for i = #e.chips + 1, #head.chips do head.chips[i]:Hide() end
    head.chev:Set(e.key ~= nil, e.open)
    head:SetHeight(e.headH)
    Skin.tint(card.surface.line, "line", "ink600", 0)
    head.chev:Tint("dim", 0)
    Skin.tint(card.ring, "ring", "gold500", 0)
end

-- One element of the list drawn: a stop's card, or the note.
local function drawStop(d, f, e)
    f.element = e
    Motion.stop(f.content)
    Motion.stop(f.card, "height")
    Motion.stop(f.card.lines, "alpha")
    f.content:ClearAllPoints()
    f.content:SetPoint("TOPLEFT")
    f.content:SetPoint("TOPRIGHT")
    f.content:SetAlpha(1)
    local stop = e.kind == "stop"
    f.card:SetShown(stop)
    f.ring:SetShown(stop)
    f.above:SetShown(stop and not e.firstCard)
    f.below:SetShown(stop and not e.lastCard)
    f.note:SetShown(not stop)
    if not stop then
        f.note:SetText(e.left or "")
        f.content:SetHeight(e.extent)
        return
    end
    drawHead(f.card, e)
    f.card.lines:SetPoint("TOPLEFT", 0, -e.headH)
    f.card.lines:SetShown(e.lines ~= nil)
    f.card.lines:SetAlpha(1)
    drawLines(d, f.card, e.lines)
    setHeight(f, e.h)
end

local function makeStopFrame(d, f)
    f.content = CreateFrame("Frame", nil, f)
    local content = f.content
    f.ring = CreateFrame("Frame", nil, content)
    f.ring:SetSize(ROAD.ring, ROAD.ring)
    f.ring:SetPoint("CENTER", content, "TOPLEFT", ROAD.axis, -(ROAD.pad + ROAD.title / 2 + ROAD.ringDrop))
    f.ring.art = Skin.nine(f.ring, "ring", { radius = ROAD.ring / 2, layer = "ARTWORK", color = "gold500" })
    -- The line between the rings: a control's line (ink.500), a step brighter than the cards' own edges,
    -- so the page reads as one line of stops.
    f.above = Skin.line(content, "ink500", { vertical = true })
    f.above:SetPoint("TOP", content, "TOPLEFT", ROAD.axis, 0)
    f.above:SetPoint("BOTTOM", f.ring, "TOP")
    f.below = Skin.line(content, "ink500", { vertical = true })
    f.below:SetPoint("TOP", f.ring, "BOTTOM")
    f.below:SetPoint("BOTTOM", content, "BOTTOMLEFT", ROAD.axis, 0)
    f.note = Skin.text(content, "dim")
    f.note:SetPoint("LEFT", content, "TOPLEFT", ROAD.gutter, -ROAD.note / 2)
    f.note:SetPoint("RIGHT", content, "TOPRIGHT", 0, -ROAD.note / 2)

    local card = Skin.card(content)
    f.card = card
    card:SetPoint("TOPLEFT", ROAD.gutter, 0)
    card:SetPoint("TOPRIGHT")
    card.ring = f.ring.art
    -- The head: a click on it opens or closes the card; it warms on hover when it opens.
    local head = CreateFrame("Button", nil, card)
    card.head = head
    head:SetPoint("TOPLEFT")
    head:SetPoint("TOPRIGHT")
    head.zone = Skin.text(head, "title")
    head.zone:SetPoint("TOPLEFT", ROAD.pad, -ROAD.pad)
    head.first = Skin.text(head, "small")
    head.first:SetTextColor(Skin.rgb("moon"))
    head.first:SetText("First visit")
    head.first:SetPoint("BOTTOMLEFT", head.zone, "BOTTOMRIGHT", ROAD.gap, ROAD.footDrop)
    head.chev = chevrons(head)
    for _, g in ipairs({ head.chev.down, head.chev.up }) do g:SetPoint("CENTER", head, "TOPRIGHT", -(ROAD.pad + ROAD.chevron / 2), -(ROAD.pad + ROAD.title / 2)) end
    -- The zone's line, carried to the right edge of the head's text, for the day and hours to stand on.
    head.line = CreateFrame("Frame", nil, head)
    head.line:SetPoint("BOTTOMLEFT", head.zone, "BOTTOMLEFT")
    head.line:SetPoint("RIGHT", -(ROAD.pad + ROAD.chevron + ROAD.gap), 0)
    head.line:SetHeight(1)
    head.when = Skin.text(head, "dim", "RIGHT")
    head.when:SetPoint("BOTTOMRIGHT", head.line, "BOTTOMRIGHT", 0, ROAD.footDrop)
    head.level = Skin.text(head, "small", "RIGHT")
    head.level:SetPoint("RIGHT", head, "TOPRIGHT", -(ROAD.pad + ROAD.chevron + ROAD.gap), -(ROAD.pad + ROAD.title + ROAD.gap + ROAD.chips / 2))
    head.chips = {}
    head:SetScript("OnClick", function()
        local e = f.element
        if e and e.key then fold(d, e.key) end
    end)
    head:SetScript("OnEnter", function(self)
        local e = f.element
        if not e then return end
        if e.key then
            Skin.tint(card.surface.line, "line", "gold600")
            self.chev:Tint("parchment")
            Skin.tint(card.ring, "ring", "gold300")
        end
        local cut = self.zone:IsTruncated() or self.dropped
        if not (cut or e.tip) then return end
        local lines = cut and { e.when, e.facts, e.level } or {}
        for _, t in ipairs(e.tip or {}) do lines[#lines + 1] = t end
        showTip(self, e.zone, lines)
    end)
    head:SetScript("OnLeave", function(self)
        local e = f.element
        if e and e.key then
            Skin.tint(card.surface.line, "line", "ink600")
            self.chev:Tint("dim")
            Skin.tint(card.ring, "ring", "gold500")
        end
        hideTip()
    end)
    -- Its lines, under a pixel line at the head's foot; cut at the card's edge while it eases.
    card.lines = CreateFrame("Frame", nil, card)
    card.lines:SetPoint("BOTTOMRIGHT")
    card.lines:SetClipsChildren(true)
    card.rule = Skin.line(card.lines, "ink600")
    card.rule:SetPoint("TOPLEFT", ROAD.pad, 0)
    card.rule:SetPoint("TOPRIGHT", -ROAD.pad, 0)
    card.rows = {}
end

-- The frames showing the list's elements now, by their place in it.
local function frameAt(d, order)
    for _, f in ipairs(d.road:GetFrames()) do if f.element and f.element.order == order then return f end end
end

local function commit(d, elements)
    d.roadElements = elements
    d.road:SetDataProvider(CreateDataProvider(elements), ScrollBoxConstants.RetainScrollPosition)
end

-- A card opened or closed by a click (a stop, Before Reliquary, or one of its groups). Its height eases
-- to its new one and its lines fade in or out, while the cards under it move with its foot. Opening,
-- the list takes the card's new height once it has grown into it (so nothing under it vanishes while it
-- grows); closing, at once (so what comes into view under it is there to rise into place).
function fold(d, key)
    local old = d.roadElements or {}
    local k
    for i, e in ipairs(old) do if e.key and (e.key == key or (e.key == "before" and key:find("^before:"))) then k = i end end
    if not k then return end
    d.roadTouched = true
    d.roadOpen[key] = not d.roadOpen[key] or nil
    sound(d.roadOpen[key] and "IG_MAINMENU_OPTION_CHECKBOX_ON" or "IG_MAINMENU_OPTION_CHECKBOX_OFF")
    local new = roadCards(d.roadShown, d.roadOpen)
    local was, now = old[k], new[k]
    local f = Motion.enabled() and frameAt(d, k)
    if not f then
        commit(d, new)
        return
    end
    local h0, h1 = was.h, now.h
    local function ease(frame, done)
        Motion.to(frame.card, "height", h1, { from = h0, dur = "slow", ease = "out", set = function(_, h) setHeight(frame, h) end, done = done })
    end
    local function under(dy, to)
        for _, g in ipairs(d.road:GetFrames()) do
            if g.element and g.element.order > k then Motion.slide(g.content, 0, dy, { to = to, dur = "slow", ease = "out" }) end
        end
    end
    if h1 >= h0 then
        drawStop(d, f, now)
        if now.lines then Motion.fade(f.card.lines, 1, { from = 0, dur = "slow", ease = "out" }) end
        ease(f, function() commit(d, new) end)
        under(0, { 0, -(h1 - h0) })
    else
        commit(d, new)
        f = frameAt(d, k)
        if not f then return end
        drawStop(d, f, was)
        drawHead(f.card, now)
        f.card.lines:SetPoint("TOPLEFT", 0, -now.headH)
        Motion.fade(f.card.lines, 0, { from = 1, dur = "slow", ease = "out" })
        ease(f, function() drawStop(d, f, now) end)
        f.element = now
        under(-(h0 - h1))
    end
end

-- The page: your character's timeline (makeDetail makes it, showDetail fills it).
function V.makeTimeline(d)
    d.roadOpen = {}
    d.road, d.roadBar = Skin.scroll(d.pages.road, { frameType = "Frame", right = 0, fade = Skin.SPACE.xl,
        init = function(f, e)
            if not f.content then makeStopFrame(d, f) end
            drawStop(d, f, e)
        end,
        extent = function(e) return e.extent end })
    -- The page arrives again each time it is shown anew.
    d.pages.road:HookScript("OnHide", function() d.roadOn = nil end)
end

function V.showTimeline(d, road, keep)
    d.roadShown = road
    -- Until a card is opened or closed by hand, the newest stops (then Before Reliquary) open
    -- themselves, one after another, while the page has room for what they hold.
    if not d.roadTouched then
        local open, room = {}, d.pageHeight or V.PAGE_HEIGHT
        local function tall(elements)
            local h = 0
            for _, e in ipairs(elements) do h = h + e.extent end
            return h
        end
        for _, e in ipairs(roadCards(road, {})) do
            if e.key then
                open[e.key] = true
                if tall(roadCards(road, open)) > room then open[e.key] = nil break end
            end
        end
        d.roadOpen = open
    end
    -- A new character, or the page newly shown: its cards arrive one after another.
    local arriving = d.arriving or d.roadOn ~= d.who
    d.roadOn = d.who
    d.roadElements = roadCards(road, d.roadOpen)
    d.road:SetDataProvider(CreateDataProvider(d.roadElements), keep)
    if arriving then
        local delay = d.arriving and Motion.PAGE_AFTER or 0
        for _, f in ipairs(d.road:GetFrames()) do
            if f.element then Motion.arrive(f.content, f.element.order, { delay = delay }) end
        end
    end
end

V.roadOf = roadOf
