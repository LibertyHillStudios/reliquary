-- Reliquary's window (/rq), the parts its pages share: the words (how long ago, money, a day and a
-- time), the texts, tooltips and item buttons, a list row on the left, the game's bar and a
-- scrolling list. The window is in Viewer.lua, each page in a file of its own (Viewer*.lua); what
-- they share travels on ns.V, never as globals. It shows only what is already in ReliquaryDB.
local ADDON, ns = ...

local V = {}
ns.V = V

local call, num, str, api = ns.call, ns.num, ns.str, ns.api
local pairs, ipairs, type, tostring = pairs, ipairs, type, tostring
local floor, min, max, format = math.floor, math.min, math.max, string.format

-- The window (docs/DESIGN.md, section 3): its size, its top bar, and what is under it (its body).
local WIDTH, HEIGHT, TOP_BAR = 960, 640, 46
local BODY_HEIGHT = HEIGHT - TOP_BAR - 1
-- The rail down the left of a list's tab, and a tab's header over its body when it has no rail.
local RAIL, HEADER = 248, 44
-- A player's page right of the rail: the hero across its top, the page tabs under it, and the page,
-- padded, below them.
local HERO, PAGE_TABS, PAGE_PAD = 124, 32, 16
local PANE_WIDTH = WIDTH - 2 - RAIL - 1
local PAGE_TOP = HERO + PAGE_TABS + 12
local PAGE_WIDTH = PANE_WIDTH - 2 * PAGE_PAD
local PAGE_HEIGHT = BODY_HEIGHT - PAGE_TOP - 12

local function sound(name) if SOUNDKIT and SOUNDKIT[name] then call(PlaySound, SOUNDKIT[name]) end end -- as the game's own panels do
local state = { tab = 1, pick = {}, bankTab = nil, bankQuery = "", guildQuery = "", sharersOnly = false, friendsQuery = "", friendSharersOnly = false }

---------------------------------------------------------------------------
-- Words and colours
---------------------------------------------------------------------------
-- The game's own text colours (Reliquary.lua): never colours of Reliquary's own.
local GOLD, WHITE, GREY, GREEN, BLUE, RED, ORANGE = ns.GOLD, ns.WHITE, ns.GREY, ns.GREEN, ns.BLUE, ns.RED, ns.ORANGE

local function ago(t)
    t = num(t)
    if not t then return "" end
    local s = max(0, time() - t)
    if s < 60 then return "just now" end
    if s < 3600 then return format("%d min ago", floor(s / 60 + 0.5)) end
    if s < 86400 then return format("%d h ago", floor(s / 3600 + 0.5)) end
    local d = floor(s / 86400 + 0.5)
    return d == 1 and "yesterday" or format("%d days ago", d)
end

local function classColored(text, classFile)
    local c = classFile and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile]
    if c and c.WrapTextInColorCode then return c:WrapTextInColorCode(text) end
    return text
end

local function money(copper)
    copper = num(copper)
    if not copper then return "" end
    if type(GetMoneyString) == "function" then
        local ok, s = pcall(GetMoneyString, copper, true)
        if ok and s then return s end
    end
    local coins = api("C_CurrencyInfo.GetCoinTextureString")
    if coins then
        local ok, s = pcall(coins, copper)
        if ok and s then return s end
    end
    return format("%dg %ds %dc", floor(copper / 10000), floor(copper / 100) % 100, copper % 100)
end

-- Text parts joined by sep, those that are missing or empty left out.
local function joined(sep, ...)
    local out = {}
    for i = 1, select("#", ...) do
        local w = select(i, ...)
        if w and w ~= "" then out[#out + 1] = tostring(w) end
    end
    return table.concat(out, sep)
end

local function words(...) return joined(" ", ...) end

---------------------------------------------------------------------------
-- Pieces
---------------------------------------------------------------------------
local function text(parent, font, justify)
    local fs = parent:CreateFontString(nil, "ARTWORK", font or "GameFontHighlight")
    fs:SetJustifyH(justify or "LEFT")
    fs:SetWordWrap(true)
    return fs
end

-- Another font for a text: a font brings its own alignment (centred), so the one wanted is set
-- again after it, as Blizzard's own code does.
local function setFont(fs, font, justify)
    fs:SetFontObject(font)
    fs:SetJustifyH(justify or "LEFT")
end

-- An item button's record is kept as rq: the game's own ItemButton keeps its item in item.
local function showItemTip(button)
    local it = button.rq
    if not it then return end
    GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
    if it.s then GameTooltip:SetHyperlink(it.s)
    elseif it.link then GameTooltip:SetHyperlink(it.link)
    elseif it.id then GameTooltip:SetItemByID(it.id) end
    GameTooltip:Show()
end

local function hideTip() GameTooltip:Hide() end

-- A tooltip the way the game's own lists write one: a white title, then gold lines, wrapped (Skin.tip).
local showTip = ns.Skin.tip

-- An item's button: the game's own (its clicks and tooltip as anywhere), drawn as Reliquary's slot
-- (Skin.slot) when it is given a size.
local function itemButton(parent, size)
    local b = size and ns.Skin.slot(parent, size) or CreateFrame("ItemButton", nil, parent)
    b:HookScript("OnEnter", showItemTip)
    b:HookScript("OnLeave", hideTip)
    b:HookScript("OnClick", function(self)
        local it = self.rq
        local s = it and (it.link or it.s)
        if not s then return end
        -- As anywhere else in the game: Shift-click puts the item's link in the chat box, Ctrl-click
        -- tries it on in the dressing room, each with the game's own link (its name and colour); an
        -- item the game hasn't loaded yet gets its click once it has. A plain click opens its page.
        if IsModifiedClick and (IsModifiedClick("CHATLINK") or IsModifiedClick("DRESSUP")) then
            local function linkOf() return s:find("|H", 1, true) and s or select(2, call(api("C_Item.GetItemInfo") or GetItemInfo, s)) end
            local link = linkOf()
            if link then
                if type(HandleModifiedItemClick) == "function" then HandleModifiedItemClick(link) return end
                if IsModifiedClick("CHATLINK") then
                    local insert = ChatFrameUtil and ChatFrameUtil.InsertLink or ChatEdit_InsertLink
                    if insert then insert(link) end
                else
                    local dress = DressUpLink or DressUpItemLink
                    if dress then dress(link) end
                end
                return
            end
            -- Not loaded yet: what was asked for at the click, and the chat box open then, kept for when
            -- it has; a link goes only into that box, and only while it is still the one open.
            local chat = IsModifiedClick("CHATLINK")
            local util = ChatFrameUtil
            local box = chat and util and type(util.GetActiveWindow) == "function" and util.GetActiveWindow() or nil
            if not (it.id and ns.itemLoaded) then return end
            ns.itemLoaded(it.id, function()
                local later = linkOf()
                if not later then return end
                if chat then
                    if box and box:HasFocus() and util.GetActiveWindow() == box then util.InsertLink(later) end
                else
                    local dress = DressUpLink or DressUpItemLink
                    if dress then dress(later) end
                end
            end)
            return
        end
        if V.openItemPage then V.openItemPage(it, s) end
    end)
    -- The game's own upgrade arrow, as on bag slots: green when the item would help you, grey when it
    -- would help someone else in the guild.
    b.up = b:CreateTexture(nil, "OVERLAY")
    b.up:SetAtlas("bags-greenarrow", true)
    b.up:SetPoint("TOPLEFT", -2, 2)
    b.up:Hide()
    return b
end

-- Whether the guild's last weighing says an item helps someone, and whether it helps you.
local function helps(id)
    local g = ns.myGuild and ns.myGuild()
    local list = g and type(g.fits) == "table" and g.fits[id]
    local anyone, you = false, false
    for _, x in ipairs(type(list) == "table" and list or {}) do
        if x.v == "up" then
            anyone = true
            if x.me then you = true end
        end
    end
    return anyone, you
end

-- An item from a shared card (icon in ic, name in n) or a guild bank slot (icon in icon, count in n).
local function showItem(b, it, fromBank)
    b.rq = it
    local art = b.rqSlot and b.icon
    if not it then
        SetItemButtonTexture(b, nil)
        SetItemButtonCount(b, 0)
        SetItemButtonQuality(b, nil)
        -- An empty slot: Reliquary's slot is a quiet well with its silhouette; the game's is dimmed.
        if b.rqSlot then
            b:SetQuality(nil, false)
            b:SetPlate(nil)
            if art then art:SetAlpha(0.35) end
        else
            b:SetAlpha(fromBank and 1 or 0.55)
        end
        b.up:Hide()
        return
    end
    local icon = fromBank and it.icon or it.ic
    if not icon and it.id then icon = num(call(api("C_Item.GetItemIconByID"), it.id)) or num(call(GetItemIcon, it.id)) end
    SetItemButtonTexture(b, icon)
    -- A stack's count: on Reliquary's slot it goes on the slot's plate, where the game writes it over
    -- the icon in its outlined numerals.
    local count = fromBank and (num(it.n) or 1) or 0
    SetItemButtonCount(b, b.rqSlot and 0 or count)
    SetItemButtonQuality(b, num(it.q), it.link or it.s or it.id)
    if b.rqSlot then
        b:SetPlate(count > 1 and tostring(count) or nil)
        b:SetQuality(num(it.q), true)
        if art then art:SetAlpha(1) end
    end
    b:SetAlpha(1)
    local anyone, you = helps(it.id)
    b.up:SetShown(anyone)
    if anyone then b.up:SetDesaturated(not you) end
end

-- How many of an item this character has in its bags and bank: what the game's Professions window
-- counts beside a reagent.
local function carried(id)
    local n = 0
    local c = ns.char
    for _, list in ipairs({ c and c.bags or {}, c and c.bank or {} }) do
        for _, bag in ipairs(list) do
            for _, it in pairs(type(bag.slots) == "table" and bag.slots or {}) do if it.id == id then n = n + (it.n or 1) end end
        end
    end
    return n
end

-- An item as a page shows it: its name, quality and icon as Reliquary kept them (its record, else
-- the tooltip it read), else the game's. When the game hasn't fetched it yet, `later` runs once it has.
local function itemFace(id, later)
    local rec = ns.db.items[id]
    local info = type(rec) == "table" and type(rec.info) == "table" and rec.info or {}
    local gameName, _, gameQ, _, _, _, _, _, _, gameIcon = call(api("C_Item.GetItemInfo") or GetItemInfo, id)
    local tipName = type(rec) == "table" and type(rec.tip) == "table" and type(rec.tip[1]) == "table" and str(rec.tip[1].l)
    local face = { id = id, name = str(info.name) or tipName or str(gameName),
        q = num(info.q) or num(gameQ) or num(call(api("C_Item.GetItemQualityByID"), id)),
        icon = num(info.icon) or num(gameIcon) or num(call(api("C_Item.GetItemIconByID"), id)) or num(call(GetItemIcon, id)) }
    if not (face.name and face.icon) and later and ns.itemLoaded then ns.itemLoaded(id, later) end
    face.name = face.name or ("Item " .. id)
    return face
end
local function qualityName(face)
    local c = face.q and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[face.q]
    return c and c.hex and (c.hex .. face.name .. "|r") or face.name
end

local ROW_HEIGHT = { stop = 40, head = 26, sub = 22, rep = 30, quest = 20, obj = 16, recipe = 22, line = 20, note = 30, shead = 40, stat = 23, prof = 31 }
local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }

local function duration(sec)
    sec = num(sec)
    if not sec then return nil end
    local d, h = floor(sec / 86400), floor(sec % 86400 / 3600)
    if d > 0 then return format("%d %s %d h", d, d == 1 and "day" or "days", h) end
    return format("%d h %d min", h, floor(sec % 3600 / 60))
end

local function played(sec)
    local d = duration(sec)
    return d and (d .. " played")
end

local function big(n) return type(BreakUpLargeNumbers) == "function" and BreakUpLargeNumbers(n) or tostring(n) end
local function plural(n, one, many) return big(n) .. " " .. (n == 1 and one or many) end

local function dayText(t)
    local y, m, d = tonumber(date("%Y", t)), tonumber(date("%m", t)), tonumber(date("%d", t))
    return format("%s %d", MONTHS[m] or "?", d) .. (y ~= tonumber(date("%Y", time())) and (", " .. y) or "")
end

-- A time of day as the game's own clock shows it, in 12 or 24 hours as the player chose.
local function clockText(t, ampm)
    local h, m = tonumber(date("%H", t)), tonumber(date("%M", t))
    if type(GameTime_GetFormattedTime) == "function" then return GameTime_GetFormattedTime(h, m, ampm) end
    local h12 = h % 12 == 0 and 12 or h % 12
    return ampm and format("%d:%02d %s", h12, m, h < 12 and "AM" or "PM") or format("%d:%02d", h12, m)
end

-- A list that draws each row by its kind, rows as tall as their kind (ROW_HEIGHT), in a page.
local function makeList(page, frameType, init, top)
    local list = CreateFrame("Frame", nil, page, "WowScrollBoxList")
    list:SetPoint("TOPLEFT", 0, top or 0)
    list:SetPoint("BOTTOMRIGHT", -16, 4)
    local bar = CreateFrame("EventFrame", nil, page, "MinimalScrollBar")
    bar:SetPoint("TOPLEFT", list, "TOPRIGHT", 4, 0)
    bar:SetPoint("BOTTOMLEFT", list, "BOTTOMRIGHT", 4, 0)
    bar:SetHideIfUnscrollable(true)
    ns.Skin.thinBar(bar)
    list:SetInterpolateScroll(true)
    bar:SetInterpolateScroll(true)
    local view = CreateScrollBoxListLinearView()
    view:SetElementExtentCalculator(function(_, line) return line.h or ROW_HEIGHT[line.kind or "line"] or 18 end)
    view:SetElementInitializer(frameType, init)
    ScrollUtil.InitScrollBoxListWithScrollBar(list, bar, view)
    return list, bar
end

-- A header row the way the game's skills, reputation and statistics lists draw one.
local function headerArt(row)
    row.headBg = row:CreateTexture(nil, "BACKGROUND")
    row.headBg:SetAtlas("common-button-list-collapseExpand")
    row.headBg:SetAllPoints()
    row.headHl = row:CreateTexture(nil, "HIGHLIGHT")
    row.headHl:SetAtlas("common-button-list-collapseExpand")
    row.headHl:SetAllPoints()
    row.headHl:SetBlendMode("ADD")
    row.headHl:SetAlpha(0.3)
    row.state = row:CreateTexture(nil, "BORDER")
    row.state:SetPoint("RIGHT", -8, -1)
end

local function myGuild()
    local gk = ns.guildKey()
    return gk and ns.db.guilds[gk]
end

V.WIDTH = WIDTH
V.HEIGHT = HEIGHT
V.TOP_BAR = TOP_BAR
V.BODY_HEIGHT = BODY_HEIGHT
V.RAIL = RAIL
V.HEADER = HEADER
V.HERO = HERO
V.PAGE_TABS = PAGE_TABS
V.PAGE_PAD = PAGE_PAD
V.PANE_WIDTH = PANE_WIDTH
V.PAGE_TOP = PAGE_TOP
V.PAGE_WIDTH = PAGE_WIDTH
V.PAGE_HEIGHT = PAGE_HEIGHT
V.ROW_HEIGHT = ROW_HEIGHT
V.MONTHS = MONTHS
V.state = state
V.sound = sound
V.ago = ago
V.classColored = classColored
V.money = money
V.joined = joined
V.words = words
V.text = text
V.setFont = setFont
V.showItemTip = showItemTip
V.hideTip = hideTip
V.showTip = showTip
V.itemButton = itemButton
V.helps = helps
V.showItem = showItem
V.carried = carried
V.itemFace = itemFace
V.qualityName = qualityName
V.duration = duration
V.played = played
V.big = big
V.plural = plural
V.dayText = dayText
V.clockText = clockText
V.makeList = makeList
V.headerArt = headerArt
V.myGuild = myGuild
