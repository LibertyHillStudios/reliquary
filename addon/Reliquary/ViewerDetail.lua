-- Reliquary's window: one player's page, or what the guild roster or the friends list says of them:
-- the hero (their class's painting with their crest, name and what is known of them), the page tabs,
-- and the Gear and Roleplay pages (docs/DESIGN.md, section 5). The other pages are each in a file of
-- their own.
local ADDON, ns = ...

local V = ns.V
local Skin, Motion = ns.Skin, ns.Motion

local call, num, str, api = ns.call, ns.num, ns.str, ns.api
local pairs, ipairs, type, tostring, unpack = pairs, ipairs, type, tostring, unpack or table.unpack
local floor, ceil, min, max, abs, format = math.floor, math.ceil, math.min, math.max, math.abs, string.format
local GREY, GREEN, RED = ns.GREY, ns.GREEN, ns.RED
local HERO, PAGE_TABS, PAGE_PAD, PAGE_TOP, PAGE_WIDTH = V.HERO, V.PAGE_TABS, V.PAGE_PAD, V.PAGE_TOP, V.PAGE_WIDTH
local PANE_WIDTH, sound, ago, classColored, money, joined, words = V.PANE_WIDTH, V.sound, V.ago, V.classColored, V.money, V.joined, V.words
local text, hideTip, showTip, itemButton, showItem, duration, played = V.text, V.hideTip, V.showTip, V.itemButton, V.showItem, V.duration, V.played
local big, plural, makeList, CHAT, makeConversation, showTalents, showItems = V.big, V.plural, V.makeList, V.CHAT, V.makeConversation, V.showTalents, V.showItems

---------------------------------------------------------------------------
-- One player's reliquary, or what the guild roster says about them
---------------------------------------------------------------------------
local PAGES = { { "gear", "Gear" }, { "tal", "Talents" }, { "bags", "Bags" }, { "bank", "Bank" }, { "reps", "Reputation" }, { "quests", "Quests" },
    { "road", "Timeline" }, { "craft", "Recipes" }, { "rp", "Roleplay" }, { "whisper", "Whispers" } }
local function pageIndex(key)
    for i, p in ipairs(PAGES) do if p[1] == key then return i end end
    return 0
end
local LEFT_SLOTS = { 1, 2, 3, 15, 5, 4, 19, 9 }
local RIGHT_SLOTS = { 10, 6, 7, 8, 11, 12, 13, 14 }
local WEAPON_SLOTS = { 16, 17, 18 }

local details = {} -- every player page made, so a profile Total RP 3 just stored can show at once

-- When Total RP 3 stores a profile, a page showing that player draws again (Roleplay.lua).
ns.onRoleplayUpdated = function(unitID)
    for _, d in ipairs(details) do
        if d.who and d.redraw and d:IsVisible() and ns.rpID(d.who) == unitID then d.redraw() end
    end
end

-- The Roleplay page (DESIGN, section 5): one reading card. In units: the room round its words, its
-- header (their name, the button for Total RP 3's own page), the room between a paragraph's lines and
-- after it, and a section label's room above and under it.
local RP = { pad = 20, head = 48, spacing = 6, para = 12, labelAbove = 8, labelBelow = 8, label = 10 }

-- Roleplay.lua writes its lines in the game's own colours; on the page they are the window's.
local RP_COLORS = { { ns.GOLD, "gold200" }, { GREY, "dim" }, { GREEN, "verdant" }, { RED, "ember" } }
local function ourColors(s)
    for _, c in ipairs(RP_COLORS) do
        local at = 1
        while true do
            local i, j = s:find(c[1], at, true)
            if not i then break end
            local code = Skin.code(c[2])
            s = s:sub(1, i - 1) .. code .. s:sub(j + 1)
            at = i + #code
        end
    end
    return s
end

-- What Total RP 3 holds for a player, as the page reads it: their name (and title) for the card's
-- header, what it says of them, then each part it names under that name; or why there is nothing yet.
local function roleplayLines(who, name)
    local lines = ns.rpLines(who)
    if not lines then
        return { head = format("Total RP 3 has no profile for %s yet. It appears here as soon as Total RP 3 hears from them.", name), waiting = true, body = {} }
    end
    local out, parts = { head = ourColors(lines[1] or ""):gsub("^" .. Skin.code("gold200"), ""), body = {} }, {}
    for i = 2, #lines do
        local label, text = lines[i]:match("^" .. ns.GOLD .. "(.-): |r(.*)$")
        if label then parts[#parts + 1] = { kind = "label", left = label } parts[#parts + 1] = { kind = "para", left = ourColors(text) }
        else out.body[#out.body + 1] = { kind = "para", left = ourColors(lines[i]) } end
    end
    for _, part in ipairs(parts) do out.body[#out.body + 1] = part end
    return out
end

-- The paper doll's own art for each slot, empty: the silhouette its slot shows (C_PaperDollInfo).
local SLOT_NAMES = { [1] = "HeadSlot", [2] = "NeckSlot", [3] = "ShoulderSlot", [15] = "BackSlot", [5] = "ChestSlot", [4] = "ShirtSlot",
    [19] = "TabardSlot", [9] = "WristSlot", [10] = "HandsSlot", [6] = "WaistSlot", [7] = "LegsSlot", [8] = "FeetSlot", [11] = "Finger0Slot",
    [12] = "Finger1Slot", [13] = "Trinket0Slot", [14] = "Trinket1Slot", [16] = "MainHandSlot", [17] = "SecondaryHandSlot", [18] = "RangedSlot" }

-- The Gear page (DESIGN, section 5): slots 40 square, 46 apart, each with its item's name (two lines
-- at most, name wide) and level beside it; the weapons along the foot; the item level and the crest
-- (or the live model) between the columns; the sheet a card at the right. In units.
-- leading: the room between a name's two lines, so the second line's tails are never cut.
local GEAR = { slot = 40, pitch = 46, name = 104, gap = 8, leading = 4, tail = 4, hair = 2, sheet = 204, between = 16, niche = 120, plinth = 52, crest = 64 }
GEAR.doll = PAGE_WIDTH - GEAR.sheet - GEAR.between
GEAR.side = GEAR.slot + GEAR.gap + GEAR.name + GEAR.gap
-- The sheet's rows: a group's label (a pixel line over it, but the first), a profession with its bar,
-- a value.
local SHEET = { shead = 28, prof = 34, stat = 19 }
-- The model's own turn: as Blizzard's paper doll starts it, and how far a dragged pixel turns it
-- (MODELFRAME_DEFAULT_ROTATION and MODELFRAME_DRAG_ROTATION_CONSTANT in Blizzard_SharedXML).
local MODEL = { rotation = 0.61, perPixel = 0.010 }

-- The character sheet as the game's own draws it on this build (Camelot's PaperDollFrameConstants and
-- CharacterFrame): General, Attributes, Weapons, Modifiers, Defense and Resistance, each a group of label
-- and value rows. Your own characters show all the game recorded; another player what their card
-- carries. A number the game's sheet leaves out at zero is left out at zero; the others show then too. A
-- group with nothing in it is left out.
local POWER_WORDS = { MANA = "Mana", RAGE = "Rage", ENERGY = "Energy", FOCUS = "Focus" }
local ATTRIBUTES = { { "str", "Strength" }, { "agi", "Agility" }, { "sta", "Stamina" }, { "int", "Intellect" }, { "spi", "Spirit" } }
local RESISTANCES = { { "arcane", "Arcane" }, { "fire", "Fire" }, { "frost", "Frost" }, { "nature", "Nature" }, { "shadow", "Shadow" } }

local function percent(v) v = num(v) return v and (format("%.2f", v) .. "%") or nil end
local function whole(v) v = num(v) return v and big(floor(v + 0.5)) or nil end
local function nonzero(v) v = num(v) return v and v ~= 0 and v or nil end

local function sheetOf(card, c, live)
    local rows = {}
    local function row(label, value, tip, atlas)
        if value == nil then return end
        rows[#rows + 1] = { kind = "stat", left = label, right = value, tip = tip, atlas = atlas }
    end
    local function group(title, fill)
        local at = #rows + 1
        rows[at] = { kind = "shead", left = title }
        fill()
        if #rows == at then rows[at] = nil end
    end
    live = type(live) == "table" and live or {}
    local st = type(card.stats) == "table" and card.stats or {}
    local s = c and type(c.stats) == "table" and c.stats or nil
    group("General", function()
        row("Health", whole(c and c.healthMax or st.hp))
        local word
        if c then word = num(c.manaMax) and "Mana" or POWER_WORDS[str(c.powerToken) or ""]
        else word = card.classFile == "WARRIOR" and "Rage" or card.classFile == "ROGUE" and "Energy" or "Mana" end
        row(word or "Power", whole(c and (num(c.manaMax) or num(c.powerMax)) or st.mp))
        if c and num(c.xp) and nonzero(c.xpMax) and not (num(c.maxLevel) and num(c.level) and c.level >= c.maxLevel) then
            row("Experience", big(c.xp) .. " / " .. big(c.xpMax))
            row("Rested", nonzero(c.rested) and big(c.rested))
        end
        row("Played", duration(c and c.played or live.played))
        row("This level", duration(c and c.playedLevel or live.playedLevel))
        row("Hearthstone", c and str(c.hearth) or str(live.hearth))
    end)
    group("Attributes", function()
        for _, a in ipairs(ATTRIBUTES) do
            local rec = s and type(s[a[1]]) == "table" and s[a[1]]
            local total = rec and num(rec.total) or (not s and num(st[a[1]]))
            local base = rec and num(rec.base)
            if total then
                local value, tip = big(total), nil
                if base then
                    tip = { "Base " .. big(base) .. (total ~= base and format(", %+d from gear and effects", total - base) or "") }
                    value = total > base and (GREEN .. value .. "|r") or total < base and (RED .. value .. "|r") or value
                end
                row(a[2], value, tip)
            end
        end
    end)
    group("Weapons", function()
        if s then
            local dmg = type(s.dmg) == "table" and num(s.dmg[1]) and num(s.dmg[2])
            row("Damage", dmg and (big(s.dmg[1]) .. " - " .. big(s.dmg[2])) or nil)
            row("Speed", num(s.speed) and (format("%.2f", s.speed) .. (nonzero(s.offSpeed) and format(" / %.2f", s.offSpeed) or "")) or nil)
        end
        row("Attack Power", whole(nonzero(s and s.ap or st.ap)))
        row("Ranged Attack Power", whole(nonzero(s and s.rap)))
    end)
    group("Modifiers", function()
        row("Hit", percent(nonzero(s and s.hit)))
        row("Crit", percent(nonzero(s and s.crit or st.crit)))
        row("Spell Hit", percent(nonzero(s and s.spellHit)))
        row("Spell Crit", percent(nonzero(s and s.spellCrit or st.scrit)))
        row("Spell Power", whole(nonzero(s and s.spellPower or st.sp)))
        row("Healing", whole(nonzero(s and s.healing or st.heal)))
        if s and nonzero(s.mp5) then
            row("Mana Regen", big(s.mp5) .. " / 5 sec", nonzero(s.mp5Casting) and { big(s.mp5Casting) .. " / 5 sec while casting" } or nil)
        end
    end)
    group("Defense", function()
        row("Armor", whole(s and s.armor or st.armor))
        row("Dodge", percent(nonzero(s and s.dodge or st.dodge)))
        row("Parry", percent(nonzero(s and s.parry)))
        row("Block", percent(nonzero(s and s.block)))
    end)
    if s and type(s.resist) == "table" then
        group("Resistance", function()
            for _, r in ipairs(RESISTANCES) do row(r[2], whole(s.resist[r[1]]), nil, "UI-Character-Info-Resistance-" .. r[2]) end
        end)
    end
    return rows
end

---------------------------------------------------------------------------
-- The hero: the class's dressing-room painting edge to edge across the page's top, darkened toward the
-- left so the words read and faded into the body at its foot; it drifts slowly and leans toward the
-- cursor, and a new player's painting cross-fades over the last.
---------------------------------------------------------------------------
local HERO_FOCUS = 0.38 -- where the scene's subject stands, down the painting
-- Room for the lean: the painting is drawn this much larger than the band, so leaning never shows an edge.
local LEAN_ROOM = 1 + 2 * Motion.LEAN / PANE_WIDTH

-- A painting's texture coordinates: its band, zoomed about its middle and leaned (in units), kept within
-- the painting.
local function paint(t, band, zoom, lx, ly)
    local z = LEAN_ROOM * (zoom or 1)
    local w, h = (band.r - band.l) / z, (band.b - band.t) / z
    local cu = (band.l + band.r) / 2 - (lx or 0) / PANE_WIDTH * w
    local cv = (band.t + band.b) / 2 + (ly or 0) / HERO * h
    cu = max(band.l + w / 2, min(band.r - w / 2, cu))
    cv = max(band.top + h / 2, min(band.bottom - h / 2, cv))
    t:SetTexCoord(cu - w / 2, cu + w / 2, cv - h / 2, cv + h / 2)
end

local function repaint(d)
    local front = d.paintings[d.front]
    if front.band then paint(front, front.band, d.zoom, d.lean[1], d.lean[2]) end
end

-- The band of a class's painting the hero shows, at the hero's proportions, or nil when the game has no
-- painting for it.
local function bandOf(classFile)
    local info = str(classFile) and call(api("C_Texture.GetAtlasInfo"), "dressingroom-background-" .. classFile:lower())
    local file = type(info) == "table" and (info.file or info.filename)
    local w, h = type(info) == "table" and num(info.width), type(info) == "table" and num(info.height)
    if not (file and w and h and w > 0 and h > 0) then return nil end
    local band = min(1, (w / h) / (PANE_WIDTH / HERO))
    local from = max(0, min(1 - band, HERO_FOCUS - band / 2))
    local top, bottom = info.topTexCoord, info.bottomTexCoord
    return { file = file, l = info.leftTexCoord, r = info.rightTexCoord, t = top + (bottom - top) * from, b = top + (bottom - top) * (from + band),
        top = top, bottom = bottom }
end

-- The painting for a class: the same class keeps its painting; another cross-fades in over the last.
local function showHero(d, classFile)
    local band = bandOf(classFile)
    local front = d.paintings[d.front]
    local same = band and front.band and front.band.file == band.file and front.band.t == band.t
    if not band then
        for _, t in ipairs(d.paintings) do t:Hide() t.band = nil end
        return
    end
    if not same then
        local back = d.paintings[3 - d.front]
        back:SetTexture(band.file)
        back.band = band
        paint(back, band, d.zoom, d.lean[1], d.lean[2])
        back:SetDrawLayer("BACKGROUND", 2)
        front:SetDrawLayer("BACKGROUND", 1)
        back:Show()
        d.front = 3 - d.front
        Motion.fade(back, 1, { from = front.band and 0 or 1, dur = "long", ease = "out",
            done = function() if d.paintings[d.front] ~= front then front:Hide() end end })
    end
    -- Ambient: the drift (scale 1 to 1.04 and back over 24 s each way) and the lean toward the cursor.
    if not Motion.running(d.hero, "drift") then
        Motion.loop(d.hero, "drift", 1, Motion.DRIFT_SCALE, Motion.drift, function(_, z) d.zoom = z repaint(d) end)
    end
    if not Motion.running(d.hero, "lean") then
        Motion.every(d.hero, "lean", function(hero, dt)
            local tx, ty = 0, 0
            if hero:IsMouseOver() then
                local x, y = GetCursorPosition()
                local s = hero:GetEffectiveScale()
                local cx, cy = hero:GetCenter()
                if x and cx then
                    tx = max(-1, min(1, (x / s - cx) / (hero:GetWidth() / 2))) * Motion.LEAN
                    ty = max(-1, min(1, (y / s - cy) / (hero:GetHeight() / 2))) * Motion.LEAN / 2
                end
            end
            local k = min(1, dt * 3)
            local lx, ly = d.lean[1] + (tx - d.lean[1]) * k, d.lean[2] + (ty - d.lean[2]) * k
            if abs(lx - d.lean[1]) > 0.001 or abs(ly - d.lean[2]) > 0.001 then
                d.lean[1], d.lean[2] = lx, ly
                repaint(d)
            end
        end)
    end
end

-- A chip for each of where they are, their gold and their time played that they share: right to left
-- along the hero's foot. Returns how wide the row of them is.
local function showChips(d, live)
    local list = {}
    if live.zone then list[#list + 1] = { "In " .. (live.sub and live.sub ~= live.zone and (live.sub .. ", ") or "") .. live.zone, "place" } end
    if live.gold then list[#list + 1] = { money(live.gold), "gold" } end
    if live.played then list[#list + 1] = { played(live.played), "played" } end
    local x = 0
    for _, key in ipairs({ "played", "gold", "place" }) do d.chips[key]:Hide() end
    for i = #list, 1, -1 do
        local chip = d.chips[list[i][2]]
        chip:Set(list[i][1])
        chip:ClearAllPoints()
        chip:SetPoint("BOTTOMRIGHT", d.hero, "BOTTOMRIGHT", -(PAGE_PAD + x), 14)
        chip:Show()
        x = x + chip.width + 6
    end
    return x > 0 and x - 6 or 0
end


local function makeDetail(parent)
    local d = CreateFrame("Frame", nil, parent)
    details[#details + 1] = d
    d:SetClipsChildren(true)

    -- The hero.
    d.hero = CreateFrame("Frame", nil, d)
    d.hero:SetPoint("TOPLEFT")
    d.hero:SetPoint("TOPRIGHT")
    d.hero:SetHeight(HERO)
    d.paintings, d.front, d.zoom, d.lean = {}, 1, 1, { 0, 0 }
    for i = 1, 2 do
        local t = d.hero:CreateTexture(nil, "BACKGROUND", nil, i)
        t:SetAllPoints()
        -- Darker toward the left, where the words are.
        t:SetGradient("HORIZONTAL", CreateColor(0.34, 0.34, 0.36, 1), CreateColor(0.86, 0.86, 0.86, 1))
        t:Hide()
        d.paintings[i] = t
    end
    d.heroFoot = d.hero:CreateTexture(nil, "BORDER")
    d.heroFoot:SetTexture("Interface\\AddOns\\Reliquary\\Media\\ui-fade")
    d.heroFoot:SetTexCoord(0, 1, 1, 0)
    d.heroFoot:SetVertexColor(Skin.rgb("ink900"))
    d.heroFoot:SetPoint("BOTTOMLEFT")
    d.heroFoot:SetPoint("BOTTOMRIGHT")
    d.heroFoot:SetHeight(44)
    d.crest = Skin.avatar(d.hero, 56)
    d.crest:SetRing("gold600")
    d.crest:SetPoint("LEFT", 20, 0)
    d.lines = CreateFrame("Frame", nil, d.hero)
    d.lines:SetPoint("TOPLEFT", 20 + 56 + 16, 0)
    d.lines:SetPoint("BOTTOMRIGHT")
    d.name = Skin.text(d.lines, "display", "LEFT", true)
    d.name:SetPoint("TOPLEFT", 0, -24)
    d.what = Skin.text(d.lines, "body", "LEFT", true)
    d.what:SetPoint("TOPLEFT", d.name, "BOTTOMLEFT", 0, -6)
    d.guild = Skin.text(d.lines, "body", "LEFT", true)
    d.guild:SetTextColor(CHAT.color("GUILD"))
    d.guild:SetPoint("TOPLEFT", d.what, "BOTTOMLEFT", 0, -3)
    d.when = Skin.text(d.lines, "small", "LEFT", true)
    d.when:SetPoint("TOPLEFT", d.guild, "BOTTOMLEFT", 0, -3)
    -- What the guild's list or the friends list knows of someone who doesn't share: their professions,
    -- the list's note.
    d.live = Skin.text(d.lines, "small", "LEFT", true)
    d.live:SetTextColor(Skin.rgb("dim"))
    d.live:SetPoint("TOPLEFT", d.when, "BOTTOMLEFT", 0, -3)
    -- Each line is one line, the whole of it on hover when it runs longer than that.
    for _, line in ipairs({ d.name, d.what, d.guild, d.when, d.live }) do
        local hover = CreateFrame("Frame", nil, d.lines)
        hover:SetAllPoints(line)
        hover:EnableMouse(true)
        hover:SetScript("OnEnter", function(self)
            if not line:IsTruncated() then return end
            GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
            GameTooltip:SetText(line:GetText() or "", 1, 1, 1, 1, true)
            GameTooltip:Show()
        end)
        hover:SetScript("OnLeave", hideTip)
        line.hover = hover
    end
    d.chips = { place = Skin.chip(d.hero), gold = Skin.chip(d.hero), played = Skin.chip(d.hero) }
    for _, chip in pairs(d.chips) do chip:Hide() end

    -- What in the guild bank is set aside for them or would be an upgrade for them (Upgrades.lua), at
    -- the hero's top right: the first few to hover or click, every one of them listed on hover of the
    -- line above them.
    d.bankFor = CreateFrame("Frame", nil, d.hero)
    d.bankFor:SetSize(4 * 26 + 3 * 4, 26)
    d.bankFor:SetPoint("TOPRIGHT", -PAGE_PAD, -34)
    d.bankForLabel = Skin.text(d.hero, "small", "RIGHT", true)
    d.bankForLabel:SetPoint("BOTTOMRIGHT", d.bankFor, "TOPRIGHT", 0, 5)
    d.bankForHover = CreateFrame("Frame", nil, d.hero)
    d.bankForHover:SetAllPoints(d.bankForLabel)
    d.bankForHover:EnableMouse(true)
    d.bankForHover:SetScript("OnEnter", function(self)
        local list = self.list
        if not list or #list <= 4 then return end
        d.bankForLabel:SetTextColor(Skin.rgb("parchment"))
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText(d.bankForLabel:GetText() or "")
        for _, x in ipairs(list) do
            local name = str((call(api("C_Item.GetItemInfo") or GetItemInfo, x.id))) or ("Item " .. x.id)
            GameTooltip:AddLine(name .. (x.aside and ("  " .. GREEN .. "set aside|r") or ""), 1, 1, 1)
        end
        GameTooltip:Show()
    end)
    d.bankForHover:SetScript("OnLeave", function()
        d.bankForLabel:SetTextColor(Skin.rgb("muted"))
        hideTip()
    end)
    d.bankForButtons = {}
    for i = 1, 4 do
        local b = itemButton(d.bankFor, 26)
        b:SetPoint("TOPRIGHT", -(i - 1) * 30, 0)
        d.bankForButtons[i] = b
    end

    -- A tab for each page they show: gear always, then talents, bags, bank, reputation, quests, your own
    -- characters' timeline, recipes, their roleplay profile when Total RP 3 is here, and whispers.
    d.tabs = Skin.tabs(d, "page")
    d.pageButtons = {}
    for i, pg in ipairs(PAGES) do
        local b = d.tabs:Add(pg[1], pg[2])
        b.page = pg[1]
        if pg[1] == "road" then
            b:HookScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText("Timeline")
                GameTooltip:AddLine("A stop is 10 active minutes in one zone, or a quest handed in there. Time marked AFK is left out.", 1, 1, 1, true)
                GameTooltip:Show()
            end)
            b:HookScript("OnLeave", hideTip)
        end
        d.pageButtons[i] = b
    end
    d.tabs.onSelect = function(page)
        if d.pageSel == page and page ~= "craft" then return end
        d.pageSel = page
        if page == "craft" then d.craftOnly = nil end -- the tab shows every profession
        sound("IG_CHARACTER_INFO_TAB")
        if d.redraw then d.redraw() end
    end
    d.tabRule = Skin.line(d, "ink600")
    d.tabRule:SetPoint("TOPLEFT", 0, -(HERO + PAGE_TABS))
    d.tabRule:SetPoint("TOPRIGHT", 0, -(HERO + PAGE_TABS))

    -- Each page fills the space below the tabs, padded; only the chosen one shows.
    d.pages = {}
    for _, name in ipairs({ "gear", "tal", "items", "list", "craft", "road", "rp", "whisper" }) do
        local pg = CreateFrame("Frame", nil, d)
        pg:SetPoint("TOPLEFT", PAGE_PAD, -PAGE_TOP)
        pg:SetPoint("BOTTOMRIGHT", -PAGE_PAD, 12)
        pg:Hide()
        d.pages[name] = pg
    end

    -- Gear: the paper doll read at a glance (GEAR above).
    local gear = d.pages.gear
    d.doll = CreateFrame("Frame", nil, gear)
    d.doll:SetPoint("TOPLEFT")
    d.doll:SetPoint("BOTTOMLEFT")
    d.doll:SetWidth(GEAR.doll)
    d.slots = {}
    -- A slot with its item's level on a small plate at its corner and, beside it on the side away from
    -- the doll's edge, the item's name in its quality's colour: two lines at most, centred on the slot
    -- (right: the name to the slot's left, right-aligned).
    local function slotButton(slot, right)
        local b = itemButton(d.doll, GEAR.slot)
        local _, silhouette = call(api("C_PaperDollInfo.GetInventorySlotInfo"), SLOT_NAMES[slot])
        b.emptyBackgroundTexture = silhouette
        b.label = Skin.text(d.doll, "body", right and "RIGHT" or "LEFT")
        b.label:SetWordWrap(true)
        b.label:SetMaxLines(2)
        b.label:SetJustifyV("TOP")
        b.label:SetWidth(GEAR.name)
        b.right = right
        d.slots[slot] = b
        return b
    end
    for i, slot in ipairs(LEFT_SLOTS) do slotButton(slot, false):SetPoint("TOPLEFT", 0, -(i - 1) * GEAR.pitch) end
    for i, slot in ipairs(RIGHT_SLOTS) do slotButton(slot, true):SetPoint("TOPRIGHT", 0, -(i - 1) * GEAR.pitch) end
    local weapon = floor(GEAR.doll / #WEAPON_SLOTS)
    for i, slot in ipairs(WEAPON_SLOTS) do
        local b = slotButton(slot, false)
        b:SetPoint("BOTTOMLEFT", (i - 1) * weapon, 0)
        b.label:SetWidth(weapon - GEAR.slot - 2 * GEAR.gap)
    end
    -- Between the columns: a niche. In it stands the class's crest, or for the character being played
    -- the game's own model of them, turned by dragging; on its plinth the item level, counted up.
    d.centre = CreateFrame("Frame", nil, d.doll)
    d.centre:SetPoint("TOPLEFT", GEAR.side, 0)
    d.centre:SetPoint("BOTTOMRIGHT", d.doll, "TOPRIGHT", -GEAR.side, -(7 * GEAR.pitch + GEAR.slot))
    d.niche = Skin.niche(d.centre, GEAR.niche, 7 * GEAR.pitch + GEAR.slot, GEAR.plinth)
    d.niche:SetPoint("TOP")
    d.ilvlLabel = Skin.text(d.niche.plinth, "label", "CENTER")
    d.ilvlLabel:SetPoint("TOP", 0, -9)
    Skin.label(d.ilvlLabel, "Item Level")
    d.ilvl = Skin.text(d.niche.plinth, "numeralBig", "CENTER")
    d.ilvl:SetPoint("TOP", d.ilvlLabel, "BOTTOM", 0, -3)
    d.mark = Skin.avatar(d.niche.figure, GEAR.crest)
    d.mark:SetRing("gold600")
    d.mark:SetPoint("CENTER", 0, 24)
    d.niche.moon:ClearAllPoints()
    d.niche.moon:SetPoint("CENTER", d.mark)
    d.model = CreateFrame("PlayerModel", nil, d.niche.figure)
    d.model:SetPoint("TOPLEFT", 1, -1)
    d.model:SetPoint("BOTTOMRIGHT", -1, 1)
    d.model:EnableMouse(true)
    d.model:Hide()
    d.model:SetScript("OnMouseDown", function(self, button)
        if button ~= "LeftButton" then return end
        self.from = GetCursorPosition()
        self.turned = self.rotation or MODEL.rotation
        self:SetScript("OnUpdate", function(m)
            local x = GetCursorPosition()
            if x and m.from then
                m.rotation = m.turned + (x - m.from) * MODEL.perPixel
                m:SetRotation(m.rotation)
            end
        end)
    end)
    d.model:SetScript("OnMouseUp", function(self) self:SetScript("OnUpdate", nil) self.from = nil end)
    d.model:SetScript("OnHide", function(self) self:SetScript("OnUpdate", nil) self.from = nil end)
    -- How wide a name is on one line, for how many lines it takes beside its slot.
    d.measureLine = Skin.text(gear, "body")
    d.measureLine:SetPoint("TOPLEFT")
    d.measureLine:SetAlpha(0) -- shown, so the game measures it as it lays out text it draws, and never seen
    d.gearNote = Skin.text(gear, "body", "CENTER")
    d.gearNote:SetTextColor(Skin.rgb("dim"))
    d.gearNote:SetPoint("TOPLEFT", d.doll, "TOPLEFT", 0, -160)
    d.gearNote:SetPoint("RIGHT", d.doll, "RIGHT")
    d.gearNote:SetText("Gear isn't shared with you.")

    -- The sheet: one card at the right, professions first (each with its bar and "64 / 75"; a click on
    -- one whose recipes are known opens them), then the sheet's groups as label and value rows, a pixel
    -- line between groups. It scrolls inside itself.
    d.sheetCard = Skin.card(gear)
    d.sheetCard:SetPoint("TOPRIGHT")
    d.sheetCard:SetPoint("BOTTOMRIGHT")
    d.sheetCard:SetWidth(GEAR.sheet)
    d.sheetCard.body:ClearAllPoints()
    d.sheetCard.body:SetPoint("TOPLEFT", 12, -4)
    d.sheetCard.body:SetPoint("BOTTOMRIGHT", -4, 8)
    local function sheetRow(row, line)
        if not row.label then
            row.rule = Skin.line(row, "ink600")
            row.rule:SetPoint("TOPLEFT", 0, -4)
            row.rule:SetPoint("TOPRIGHT", -8, -4)
            row.head = Skin.text(row, "label")
            row.head:SetPoint("BOTTOMLEFT", 0, 5)
            row.icon = row:CreateTexture(nil, "ARTWORK")
            row.icon:SetSize(14, 14)
            row.icon:SetPoint("LEFT", 0, 0)
            row.label = Skin.text(row, "small")
            row.value = Skin.text(row, "numeral", "RIGHT")
            row.value:SetPoint("RIGHT", -8, 0)
            row.label:SetPoint("RIGHT", row.value, "LEFT", -6, 0)
            row.bar = Skin.bar(row, 6)
            row.bar:SetPoint("BOTTOMLEFT", 0, 7)
            row.bar:SetPoint("BOTTOMRIGHT", -8, 7)
            row.hl = Skin.nine(row, "disc", { radius = Skin.RADIUS.control, layer = "BACKGROUND", color = "ink800", inset = { -4, 1, 4, 1 } })
            row.hl:SetAlpha(0)
            row:SetScript("OnClick", function(self)
                local l = self.line
                if not (l and l.kind == "prof" and l.recipes) then return end
                d.pageSel, d.craftOnly = "craft", l.prof
                sound("IG_CHARACTER_INFO_TAB")
                if d.redraw then d.redraw() end
            end)
            row:SetScript("OnEnter", function(self)
                local l = self.line
                if not l then return end
                if l.kind == "prof" then
                    Motion.fade(self.hl, 1, { from = 0, dur = "fast", set = function(n, a) n:SetAlpha(a) end, owner = self })
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    GameTooltip:SetText(l.prof)
                    GameTooltip:AddLine(plural(l.recipes, "recipe", "recipes"), 1, 1, 1)
                    if type(GameTooltip_AddInstructionLine) == "function" then GameTooltip_AddInstructionLine(GameTooltip, "Click to see them.")
                    else GameTooltip:AddLine(GREEN .. "Click to see them.|r") end
                    GameTooltip:Show()
                elseif l.tip then showTip(self, l.left, l.tip) end
            end)
            row:SetScript("OnLeave", function(self)
                Motion.stop(self.hl, "alpha")
                self.hl:SetAlpha(0)
                hideTip()
            end)
        end
        row.line = line
        local head, prof = line.kind == "shead", line.kind == "prof"
        local stat = not (head or prof)
        row.rule:SetShown(head and not line.first)
        row.head:SetShown(head)
        row.icon:SetShown(stat and line.atlas ~= nil)
        row.label:SetShown(not head)
        row.value:SetShown(not head)
        row.bar:SetShown(prof)
        row.hl:SetAlpha(0)
        row:EnableMouse((prof and line.recipes ~= nil) or (stat and line.tip ~= nil))
        if head then
            Skin.label(row.head, line.left)
            return
        end
        row.label:ClearAllPoints()
        row.value:ClearAllPoints()
        if prof then
            Skin.setRole(row.label, "body")
            row.label:SetPoint("TOPLEFT", 0, -6)
            row.value:SetPoint("TOPRIGHT", -8, -7)
            row.label:SetText(line.prof)
            row.value:SetText(format("%d / %d", line.sk or 0, line.mx or 0))
            -- Arriving, the bar fills from nothing; drawn again, it moves from what it showed.
            local was = d.profShown[line.prof]
            if d.arriving then row.bar:Set(line.sk or 0, line.mx or 0, { from = 0, delay = Motion.delay(line.n) + Motion.PAGE_AFTER })
            elseif was then row.bar:Set(line.sk or 0, line.mx or 0, { from = was })
            else row.bar:Set(line.sk or 0, line.mx or 0, { instant = true }) end
            d.profShown[line.prof] = row.bar.target
        else
            Skin.setRole(row.label, "small")
            row.label:SetPoint("LEFT", line.atlas and 20 or 0, 0)
            row.value:SetPoint("RIGHT", -8, 0)
            if line.atlas then row.icon:SetAtlas(line.atlas) end
            row.label:SetText(line.left)
            row.value:SetText(line.right)
        end
        row.label:SetPoint("RIGHT", row.value, "LEFT", -6, 0)
    end
    d.profShown = {}
    d.sheet, d.sheetBar = Skin.scroll(d.sheetCard.body, { frameType = "Button", right = 0, init = sheetRow, fade = Skin.SPACE.xl,
        extent = function(line) return SHEET[line.kind] or SHEET.stat end })

    -- The other pages, each made by its own file.
    V.makeTalents(d)
    V.makeBags(d)
    V.makeJournal(d)
    V.makeRecipes(d)
    V.makeTimeline(d)

    -- Text that can run long (what the roster knows): a list of its paragraphs, each as tall as it wraps
    -- to, scrolling past the page however long it runs.
    d.measure = text(d, "GameFontHighlight")
    d.measure:SetSpacing(4)
    d.measure:SetPoint("TOPLEFT")
    d.measure:SetAlpha(0) -- shown, so the game measures it as it lays out text it draws, and never seen
    local function paragraphs(holder)
        local list, bar = makeList(holder, "Frame", function(row, line)
            if not row.text then
                row.text = text(row, "GameFontHighlight")
                row.text:SetPoint("TOPLEFT", 2, -3)
                row.text:SetPoint("RIGHT", -2, 0)
                row.text:SetSpacing(4)
            end
            row.text:SetText(line.left or "")
        end)
        list.textWidth = PAGE_WIDTH - 8 - 16 - 4 -- the holder's width, less the scroll bar and the row's margins
        return list, bar
    end
    d.setParagraphs = function(list, body)
        local lines = {}
        for para in ((body or "") .. "\n"):gmatch("(.-)\n") do
            if para:match("%S") then
                d.measure:SetWidth(list.textWidth)
                d.measure:SetText(para)
                lines[#lines + 1] = { kind = "para", left = para, h = ceil((num(d.measure:GetStringHeight()) or 12) + 8) }
            elseif #lines > 0 then
                lines[#lines + 1] = { kind = "para", left = "", h = 8 }
            end
        end
        list:SetDataProvider(CreateDataProvider(lines))
    end

    -- Your own row in the guild's list, when you don't share: in the page's place.
    d.noteArea = CreateFrame("Frame", nil, d)
    d.noteArea:SetPoint("TOPLEFT", PAGE_PAD, -PAGE_TOP)
    d.noteArea:SetPoint("BOTTOMRIGHT", -PAGE_PAD, 12)
    d.note = paragraphs(d.noteArea)

    -- Their Total RP 3 profile (Roleplay.lua) on one reading card: in its header their name, and the
    -- button for Total RP 3's own page; under a pixel line what Total RP 3 says of them, then each part
    -- it names (what they're doing now, out of character, at first glance) under that name as a section
    -- label, with room between the lines to read. However long it runs, all of it: the card scrolls.
    local rp = d.pages.rp
    d.rpCard = Skin.card(rp)
    d.rpCard:SetPoint("TOPLEFT")
    d.rpCard:SetPoint("TOPRIGHT")
    d.rpButton = Skin.button(d.rpCard, "quiet")
    d.rpButton:SetText("Open in Total RP 3")
    d.rpButton:SetPoint("TOPRIGHT", -RP.pad, -(RP.head - d.rpButton:GetHeight()) / 2)
    d.rpButton:SetScript("OnClick", function()
        if d.who and ns.rpOpen(d.who) then sound("IG_MAINMENU_OPTION") end
    end)
    d.rpTitle = Skin.text(d.rpCard, "title")
    d.rpTitle:SetWordWrap(true)
    d.rpTitle:SetMaxLines(2)
    d.rpTitle:SetPoint("TOPLEFT", RP.pad, 0)
    d.rpTitle:SetPoint("BOTTOMRIGHT", d.rpCard, "TOPRIGHT", -(RP.pad + d.rpButton:GetWidth() + Skin.SPACE.l), -RP.head)
    -- Two lines at most, the whole of it on hover when it runs longer.
    d.rpTitle.hover = CreateFrame("Frame", nil, d.rpCard)
    d.rpTitle.hover:SetAllPoints(d.rpTitle)
    d.rpTitle.hover:EnableMouse(true)
    d.rpTitle.hover:SetScript("OnEnter", function(self)
        if not d.rpTitle:IsTruncated() then return end
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:SetText(d.rpTitle:GetText() or "", 1, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    d.rpTitle.hover:SetScript("OnLeave", hideTip)
    d.rpRule = Skin.line(d.rpCard, "ink600")
    d.rpRule:SetPoint("TOPLEFT", RP.pad, -RP.head)
    d.rpRule:SetPoint("TOPRIGHT", -RP.pad, -RP.head)
    local holder = CreateFrame("Frame", nil, d.rpCard)
    holder:SetPoint("TOPLEFT", RP.pad, -(RP.head + RP.pad))
    holder:SetPoint("BOTTOMRIGHT", -Skin.SPACE.s, RP.pad - RP.para)
    d.rpWidth = PAGE_WIDTH - 2 * RP.pad - Skin.SPACE.m
    d.rp, d.rpBar = Skin.scroll(holder, { frameType = "Frame", right = Skin.SPACE.m, fade = Skin.SPACE.xl, extent = function(line) return line.h end,
        init = function(row, line)
            if not row.text then
                row.text = Skin.text(row, "body")
                row.text:SetWordWrap(true)
                row.text:SetWidth(d.rpWidth)
            end
            row.line = line
            local label = line.kind == "label"
            Skin.setRole(row.text, label and "label" or "body")
            row.text:SetSpacing(label and 0 or RP.spacing)
            if label then Skin.label(row.text, line.left) else row.text:SetText(line.left) end
            row.text:ClearAllPoints()
            row.text:SetPoint("TOPLEFT", 0, label and -RP.labelAbove or 0)
            row.text:SetAlpha(1)
        end })
    -- How tall a paragraph runs at the card's width, its lines as far apart as the card draws them.
    d.rpMeasure = Skin.text(d.rpCard, "body")
    d.rpMeasure:SetWordWrap(true)
    d.rpMeasure:SetSpacing(RP.spacing)
    d.rpMeasure:SetWidth(d.rpWidth)
    d.rpMeasure:SetPoint("TOPLEFT")
    d.rpMeasure:SetAlpha(0) -- shown, so the game measures it as it lays out text it draws, and never seen
    -- Shows a profile (roleplayLines): the card as tall as it is, the page's height at most. A new
    -- player's profile, or the page coming into view, arrives a paragraph at a time.
    function d.setProfile(profile)
        d.rpTitle:SetText(profile.head or "")
        Skin.setRole(d.rpTitle, profile.waiting and "body" or "title")
        d.rpTitle:SetTextColor(Skin.rgb(profile.waiting and "dim" or "gold200"))
        local lines, tall = {}, 0
        for _, line in ipairs(profile.body or {}) do
            if line.kind == "label" then
                line.h = RP.labelAbove + RP.label + RP.labelBelow
            elseif (line.left or "") ~= "" then
                d.rpMeasure:SetText(line.left)
                line.h = ceil((num(d.rpMeasure:GetStringHeight()) or 12) + RP.para)
            end
            if line.h then
                lines[#lines + 1] = line
                tall = tall + line.h
            end
        end
        -- The card takes its height first, so the list lays out every row it has room for at once.
        local body = #lines > 0
        local most = (d.pageHeight or V.PAGE_HEIGHT)
        d.rpCard:SetHeight(body and min(most, RP.head + RP.pad + tall - RP.para + RP.pad) or RP.head)
        d.rpRule:SetShown(body)
        d.rp:SetShown(body)
        d.rp:SetDataProvider(CreateDataProvider(lines))
        local fresh = d.arriving or d.rpShown ~= d.who
        d.rpShown = d.who
        if fresh then
            local n = 1
            Motion.arrive(d.rpTitle, n, { delay = d.arriving and Motion.PAGE_AFTER or 0 })
            for _, row in ipairs(d.rp:GetFrames()) do
                n = n + 1
                Motion.arrive(row.text, n, { delay = d.arriving and Motion.PAGE_AFTER or 0 })
            end
        end
    end
    rp:HookScript("OnHide", function() d.rpShown = nil end)

    -- Your whispers with them (Chat.lua), read back, searched and answered here: a Battle.net friend's
    -- by BattleTag, in the game's Battle.net whisper colour, among those with the character they play.
    d.whispers = makeConversation(d.pages.whisper, {
        kind = "WHISPER",
        source = function()
            local list, _, under = ns.whispersWith(d.talk, unpack(d.talkAlso or {}))
            d.talkUnder = under
            return list
        end,
        send = function(typed) return ns.sendWhisper(d.talk, typed) end,
        speaker = function(r)
            local key = d.talkUnder and d.talkUnder[r] or d.talk
            local bn = type(key) == "string" and key:find("^bn:") ~= nil
            if r.o then
                local me, mine = str(ns.me and ns.me()), str(r.w)
                return { key = "me", name = (mine and mine ~= me) and ns.shortName(mine) or "You", class = str(r.c), color = bn and "BN_WHISPER_INFORM" or "WHISPER_INFORM" }
            end
            return { key = "them", name = d.whoName or "?", class = str(r.c) or d.whoClass, color = bn and "BN_WHISPER" or nil }
        end,
    })
    d.whispers:SetAllPoints()
    return d
end

local function showDetail(d, peer, member)
    local card = peer and type(peer.card) == "table" and peer.card
    d:SetShown((card or member or peer) and true or false)
    if not (card or member or peer) then return end
    d.redraw = function() showDetail(d, peer, member) end
    d.redrawSoon = d.redrawSoon or function()
        if d.redrawQueued or not C_Timer then return end
        d.redrawQueued = true
        C_Timer.After(0.5, function() d.redrawQueued = false if d:IsVisible() and d.redraw then d.redraw() end end)
    end
    local more = peer and type(peer.more) == "table" and peer.more or {}
    local classFile = card and card.classFile or member and member.cls
    -- Your own characters by their whole name, surname too, as the list beside it has them.
    local name = peer and peer.own and peer.label or card and card.name or member and (member.label or member.n and ns.shortName(ns.fullName(member.n)))
        or peer and ns.shortName(peer.key) or "?"
    -- Who this is, as the sharing code keys players ("own:<key>" for one of your characters, whom the
    -- guild knows by its full name). Total RP 3 may fetch their profile now (each player at most every
    -- fifteen minutes, and not in a fight: then the next look asks); your own is in Total RP 3 itself.
    local own = peer and peer.own
    local who = peer and peer.key or member and member.n and ns.fullName(member.n) or nil
    -- A new player (or the window opening) arrives: the hero's lines and the page come in order, the
    -- bars fill and the item level counts from nothing.
    local arriving = V.entrance or d.drawnWho ~= who
    d.who = who
    -- Whom the Whispers page talks to: a Battle.net friend by BattleTag, anyone else by name. It holds
    -- every whisper with them: a Battle.net friend's with the character they play too, and a
    -- character's with the Battle.net friend playing it.
    d.talk = member and member.key or who
    d.talkAlso = {}
    if type(d.talk) == "string" and d.talk:find("^bn:") then
        d.talkAlso[#d.talkAlso + 1] = member.char
        if who and who ~= member.char then d.talkAlso[#d.talkAlso + 1] = who end
    elseif who and not own then
        for _, f in ipairs(ns.friends and ns.friends() or {}) do
            if f.kind == "bnet" and f.char == who then d.talkAlso[1] = f.key break end
        end
    end
    if not own and who then ns.rpFetch(who) end
    local roleplay = not own and who ~= nil and ns.rpAvailable()
    -- Who the Whispers page talks to, by the name and class shown above it.
    d.whoName, d.whoClass = name, str(classFile)
    d.whispers.input.Instructions:SetText("Whisper " .. name)
    d.name:SetText(name)
    d.crest:SetShown(str(classFile) ~= nil)
    d.crest:SetClass(str(classFile))
    showHero(d, classFile)
    d.live:SetText("")
    local forThem = who and ns.bankFor(own and peer.name or who, own and not peer.playing and peer.key or nil) or {}
    for i, b in ipairs(d.bankForButtons) do
        local x = forThem[i]
        b:SetShown(x ~= nil)
        if x then showItem(b, x.item, true) end
    end
    d.bankFor:SetShown(#forThem > 0)
    d.bankForHover.list = forThem
    local whom = ((own and peer.playing) or (not own and who == ns.me())) and "you" or own and name or "them"
    d.bankForLabel:SetText(#forThem == 0 and "" or #forThem > 4 and format("In the guild bank for %s (%d)", whom, #forThem) or ("In the guild bank for " .. whom))
    d.bankForLabel:SetTextColor(Skin.rgb("muted"))
    local chipsWidth = 0
    for _, chip in pairs(d.chips) do chip:Hide() end
    if card then
        d.what:SetText(words(card.level and ("Level " .. card.level), card.race, classColored(card.class or "", card.classFile)))
        d.guild:SetText(card.guild and words("<" .. card.guild .. ">", card.guildRank) or (card.title or ""))
        if own then
            d.when:SetText(peer.playing and "Playing now" or peer.got and ("Saved " .. ago(peer.got)) or "")
        else
            local via = {}
            if peer.scopes and peer.scopes.g then via[#via + 1] = "your guild" end
            if peer.scopes and peer.scopes.f then via[#via + 1] = "friends" end
            if peer.scopes and peer.scopes.p then via[#via + 1] = "everyone" end
            d.when:SetText(format("Shared with %s · %s", table.concat(via, ", "), ago(peer.got)))
        end
        chipsWidth = showChips(d, more.live or {})
    elseif member then
        -- Without a reliquary, what the guild's list, the friends list or Battle.net says of them.
        local level = member.lv and ("Level " .. member.lv)
        local class = member.cls and classColored(LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[member.cls] or member.cls, member.cls)
        local kind = member.kind
        d.what:SetText(words(level, class) or "")
        if kind == "bnet" then
            d.guild:SetText(member.char and ("Playing " .. ns.shortName(member.char)) or member.on and "On Battle.net" or "Battle.net friend")
            d.when:SetText(member.char and member.z and ("In " .. member.z) or "")
        elseif kind == "friend" then
            d.guild:SetText("Friend")
            d.when:SetText(member.on and ("Online" .. (member.z and (", " .. member.z) or "")) or "Offline")
        elseif kind == "whispered" then
            d.guild:SetText("")
            d.when:SetText(member.at and ("Whispered " .. ago(member.at)) or "")
        else
            d.guild:SetText(member.rank or "")
            d.when:SetText(member.on and ("Online" .. (member.z and (", " .. member.z) or "")) or (member.seen and ("Last online " .. ago(member.seen)) or ""))
        end
        -- What else the list knows: their professions (the guild's list has them) and its note.
        local profs = {}
        if member.p1 then profs[#profs + 1] = member.p1 .. (member.p1r and (" " .. member.p1r) or "") end
        if member.p2 then profs[#profs + 1] = member.p2 .. (member.p2r and (" " .. member.p2r) or "") end
        d.live:SetText(joined("   ·   ", table.concat(profs, ", "), member.note and ("\"" .. member.note .. "\"") or nil))
    else
        d.what:SetText("")
        d.guild:SetText("")
        d.when:SetText("Waiting for their answer.")
    end
    -- The lines stop short of the guild bank's strip and of the chips, whichever reaches further in.
    local reach = max(#forThem > 0 and max(d.bankFor:GetWidth() or 0, d.bankForLabel:GetStringWidth() or 0) or 0, chipsWidth)
    for _, line in ipairs({ d.name, d.what, d.guild, d.when, d.live }) do line:SetPoint("RIGHT", d.lines, "RIGHT", -(PAGE_PAD + reach + (reach > 0 and 16 or 0)), 0) end
    -- An empty line leaves no gap and nothing to point at: the lines below it move up.
    for _, line in ipairs({ d.what, d.guild, d.when, d.live }) do line.hover:SetShown((line:GetText() or "") ~= "") end
    d.when:SetPoint("TOPLEFT", (d.guild:GetText() or "") ~= "" and d.guild or d.what, "BOTTOMLEFT", 0, -3)
    -- The hero's lines arrive in order, then what sits at its right (the chips, the guild bank's words).
    if arriving then
        local n = 1
        if d.crest:IsShown() then Motion.arrive(d.crest, n, { delay = Motion.HERO_AFTER }) end
        for _, line in ipairs({ d.name, d.what, d.guild, d.when, d.live }) do
            if (line:GetText() or "") ~= "" then
                n = n + 1
                Motion.arrive(line, n, { delay = Motion.HERO_AFTER })
            end
        end
        local bank = (d.bankForLabel:GetText() or "") ~= ""
        for _, side in ipairs({ d.chips.place, d.chips.gold, d.chips.played, bank and d.bankForLabel or false, d.bankFor }) do
            if side and side:IsShown() then
                n = n + 1
                Motion.arrive(side, n, { delay = Motion.HERO_AFTER })
            end
        end
    end
    -- The pages this player shows; the one chosen stays chosen while it is there.
    local book = who and ns.recipeBook and ns.recipeBook(who)
    -- Another player: every profession again, their first recipe chosen, and their timeline opening
    -- itself again.
    if d.who ~= d.bookFor then d.bookFor, d.craftOnly, d.roadOpen, d.roadTouched, d.recipeKey = d.who, nil, {}, nil, nil end
    -- Your own character's whole record (the window's alone, never sent), for its talents and sheet.
    local c = own and type(peer.char) == "table" and peer.char or nil
    local talented = c and type(c.talents) == "table" and ((num(c.talents.spent) or 0) > 0 or (num(c.talents.unspent) or 0) > 0)
        or not c and card and card.tal and type(card.tal.n) == "table" and #card.tal.n > 0
    -- Your whispers with another player (Chat.lua): a page of every other player's, to read back and to
    -- whisper them, whether they share or not. A guildmate, a friend or anyone else you've whispered who
    -- doesn't share has it as their page, the list's words about them above it, and their Total RP 3
    -- profile on a page beside it. Your own row in the guild's list is you: no pages.
    local talker = not own and d.talk ~= nil and not (member and member.me)
    local bare = not card and member ~= nil and not member.me
    local has = { gear = card and true or false, tal = talented and true or false, bags = more.bags ~= nil, bank = more.bank ~= nil, reps = more.reps ~= nil,
        quests = more.quests ~= nil, road = own and peer.road ~= nil, craft = book ~= nil, rp = roleplay, whisper = talker }
    if not has[d.pageSel or ""] then d.pageSel = card and "gear" or has.whisper and "whisper" or "rp" end
    for _, b in ipairs(d.pageButtons) do
        local show = has[b.page] and (card and (b.page ~= "gear" or has.tal or has.bags or has.bank or has.reps or has.quests or has.road or has.craft
            or has.rp or has.whisper) or bare)
        b:SetShown(show and true or false)
    end
    local page = (card or bare) and d.pageSel or nil
    -- The page tabs: the shown ones laid out, the marker on the chosen one, sliding when it changes.
    local samePlayer = d.drawnWho == who
    d.tabs:Layout(PAGE_PAD, -HERO)
    d.tabs:Select(page, not (samePlayer and d.drawnPage ~= page))
    d.tabRule:SetShown(page ~= nil)
    -- The same page of the same player drawn again (their data changed): its list stays where it was scrolled.
    local keep = samePlayer and d.drawnPage == page and ScrollBoxConstants and ScrollBoxConstants.RetainScrollPosition or nil
    local moved = samePlayer and d.drawnPage ~= page and d.drawnPage ~= nil and page ~= nil
    local before = d.drawnPage
    d.drawnWho, d.drawnPage = who, page
    d.arriving = arriving
    local holder = (page == "bags" or page == "bank") and "items" or (page == "reps" or page == "quests") and "list" or page
    for key, pg in pairs(d.pages) do pg:SetShown(key == holder) end
    -- Another page of the same player arrives from the side its tab lies on; a new player's page rises.
    local pg = holder and d.pages[holder]
    if pg and moved then
        Motion.fade(pg, 1, { from = 0, dur = "base", ease = "enter" })
        Motion.slide(pg, (pageIndex(page) > pageIndex(before) and 1 or -1) * Motion.SLIDE_PAGE, 0, { dur = "base", ease = "enter" })
    elseif pg and arriving then
        Motion.arrive(pg, 1, { delay = Motion.PAGE_AFTER })
    end
    d.rpButton:SetShown(page == "rp" and roleplay)
    -- Your own row in the guild's list: what it says, and where to choose who sees this character.
    d.noteArea:SetShown(not card and member ~= nil and member.me == true)
    if page == "whisper" then
        d.whispers.draw()
        return
    end
    if page == "rp" then
        d.setProfile(roleplayLines(who, name))
        return
    end
    if not card then
        if member and member.me then d.setParagraphs(d.note, GREY .. "This is you. Choose who sees this character on the Sharing tab.|r") end
        return
    end
    if page == "bags" or page == "bank" then
        showItems(d, more[page], keep, page == "bank")
        return
    end
    if page == "reps" or page == "quests" then
        V.showJournal(d, page, card, more, keep)
        return
    end
    if page == "tal" then
        showTalents(d, card, c)
        return
    end
    if page == "road" then
        V.showTimeline(d, peer.road, keep)
        return
    end
    if page == "craft" then
        V.showRecipes(d, book, keep)
        return
    end
    -- Gear: every slot with its item's name and level, an empty one showing only its silhouette; the
    -- item level counted up between the columns over the crest, or the live model of the character
    -- being played; the sheet.
    local shared = card.gear ~= nil
    d.doll:SetShown(shared)
    d.gearNote:SetShown(not shared)
    for slot, b in pairs(d.slots) do
        local it = shared and card.gear[slot] or nil
        showItem(b, it)
        local info = it and type(ns.db.items[it.id]) == "table" and type(ns.db.items[it.id].info) == "table" and ns.db.items[it.id].info or {}
        local face = it and V.itemFace(it.id, d.redrawSoon)
        local label = it and (str(it.n) or face and face.name) or nil
        local level = it and (num(it.il) or num(info.ilvl))
        local words = label and V.qualityName({ name = label, q = num(it.q) or face.q }) or nil
        b.label:SetText(words or "")
        b.label:SetShown(words ~= nil)
        b:SetPlate(level and level >= 1 and tostring(floor(level)) or nil)
        -- The name (its lines counted from its width on one line) beside the slot, centred on it. A
        -- name within a hair of the column's width counts as two lines: the game may wrap it, and a
        -- second line with no room would be cut off.
        local lines = 0
        if words then
            d.measureLine:SetText(words)
            lines = (d.measureLine:GetStringWidth() or 0) > b.label:GetWidth() - GEAR.hair and 2 or 1
        end
        local height = lines * (b.label:GetLineHeight() or 12) + max(lines - 1, 0) * GEAR.leading
        b.label:ClearAllPoints()
        b.label:SetHeight(height + GEAR.tail) -- room under the last line for its letters' tails
        b.label:SetPoint(b.right and "TOPRIGHT" or "TOPLEFT", b, b.right and "LEFT" or "RIGHT", b.right and -GEAR.gap or GEAR.gap, height / 2)
    end
    -- Whole levels, as the game's own character sheet shows it; none below one (a new character's few
    -- starting clothes).
    local ilvl = shared and num(card.ilvl)
    ilvl = ilvl and ilvl >= 1 and floor(ilvl) or nil
    d.ilvlLabel:SetShown(ilvl ~= nil)
    d.ilvl:SetShown(ilvl ~= nil)
    d.niche.step:SetShown(ilvl ~= nil) -- no plinth marked off with nothing to stand on it
    if ilvl then
        Motion.count(d.ilvl, ilvl, { from = arriving and 0 or d.ilvlShown, delay = arriving and Motion.PAGE_AFTER or nil })
        d.ilvlShown = ilvl
    end
    -- In the niche: the game's own model of the character being played; anyone else, and a model the
    -- game wouldn't give, their class's crest.
    local live = own and peer.playing and shared
    if live and not d.model.unit then
        -- SetUnit is a void method: whether the protected call succeeded decides if it can show.
        local ready = type(d.model.SetUnit) == "function" and pcall(d.model.SetUnit, d.model, "player")
        d.model.unit = ready and "player" or nil
        d.model.rotation = MODEL.rotation
        d.model:SetRotation(MODEL.rotation)
    elseif not live and d.model.unit then
        d.model:ClearModel()
        d.model.unit = nil
    end
    d.model:SetShown(d.model.unit ~= nil)
    d.mark:SetClass(str(classFile))
    d.mark:SetShown(str(classFile) ~= nil and d.model.unit == nil)
    -- The professions first, as a group of their own, then the sheet's groups.
    local counts = {}
    for _, prof in ipairs(book or {}) do counts[prof.name] = #prof.recipes end
    local rows = {}
    if type(card.profs) == "table" and #card.profs > 0 then
        rows[1] = { kind = "shead", left = "Professions" }
        for i, p in ipairs(card.profs) do
            rows[#rows + 1] = { kind = "prof", prof = p.n, recipes = counts[p.n], sk = p.sk, mx = p.mx, n = i }
        end
    end
    for _, line in ipairs(sheetOf(card, c, more.live)) do rows[#rows + 1] = line end
    if rows[1] then rows[1].first = true end
    d.sheetCard:SetShown(#rows > 0)
    d.sheet:SetDataProvider(CreateDataProvider(rows), keep)
end

V.makeDetail = makeDetail
V.showDetail = showDetail
