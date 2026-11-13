-- For renders only (tools/render.sh): what wow-ui-sim lacks that this build of the game has. Each
-- function here is in Blizzard_APIDocumentationGenerated for 1.60.1.70862; each answers as the game
-- does for an ordinary item. Without them Blizzard's own item-button code stops part way through a
-- draw and the page comes out half empty.
local function want(ns, name, fn)
    _G[ns] = _G[ns] or {}
    if _G[ns][name] == nil then _G[ns][name] = fn end
end
local no = function() return false end
local none = function() return nil end
want("C_AzeriteEmpoweredItem", "IsAzeriteEmpoweredItemByID", no)
want("C_Item", "IsCorruptedItem", no)
want("C_Item", "IsCosmeticItem", no)
want("C_Item", "IsCurioItem", no)
want("C_Item", "IsRelicItem", no)
want("C_Item", "IsDecorItem", no)
want("C_ItemSocketInfo", "IsArtifactRelicItem", no)
want("C_Soulbinds", "IsItemConduitByItemInfo", no)
want("C_TradeSkillUI", "GetItemCraftedQualityInfo", none)
want("C_TradeSkillUI", "GetItemReagentQualityInfo", none)
want("C_TradeSkillUI", "GetSkillLineForGear", none)

-- The simulator builds the item quality colours (the game's GlobalColor data) all white. The game's
-- own values, so quality borders show as they do in the client.
do
    local Q = Enum.ItemQuality
    local real = {
        COMMON_GRAY_COLOR = { 0.659, 0.659, 0.659 }, UNCOMMON_GREEN_COLOR = { 0.118, 1, 0 }, RARE_BLUE_COLOR = { 0, 0.439, 0.867 },
        EPIC_PURPLE_COLOR = { 0.639, 0.208, 0.933 }, LEGENDARY_ORANGE_COLOR = { 1, 0.502, 0 }, ARTIFACT_GOLD_COLOR = { 0.902, 0.8, 0.502 },
        HEIRLOOM_BLUE_COLOR = { 0, 0.8, 1 },
    }
    for name, c in pairs(real) do _G[name] = CreateColor(c[1], c[2], c[3]) end
    BAG_ITEM_QUALITY_COLORS[Q.Common] = COMMON_GRAY_COLOR
    BAG_ITEM_QUALITY_COLORS[Q.Uncommon] = UNCOMMON_GREEN_COLOR
    BAG_ITEM_QUALITY_COLORS[Q.Rare] = RARE_BLUE_COLOR
    BAG_ITEM_QUALITY_COLORS[Q.Epic] = EPIC_PURPLE_COLOR
    BAG_ITEM_QUALITY_COLORS[Q.Legendary] = LEGENDARY_ORANGE_COLOR
    BAG_ITEM_QUALITY_COLORS[Q.Artifact] = ARTIFACT_GOLD_COLOR
    BAG_ITEM_QUALITY_COLORS[Q.Heirloom] = HEIRLOOM_BLUE_COLOR
    -- The colours an item's name is written in (ITEM_QUALITY_COLORS[q], with its hex, as the game's
    -- ColorManager gives them: common is white in text, where a bag's border is grey).
    local text = { [Q.Poor] = "9d9d9d", [Q.Common] = "ffffff", [Q.Uncommon] = "1eff00", [Q.Rare] = "0070dd", [Q.Epic] = "a335ee",
        [Q.Legendary] = "ff8000", [Q.Artifact] = "e6cc80", [Q.Heirloom] = "00ccff" }
    if type(ITEM_QUALITY_COLORS) == "table" then
        for q, h in pairs(text) do
            local e = ITEM_QUALITY_COLORS[q] or {}
            ITEM_QUALITY_COLORS[q] = e
            e.r, e.g, e.b = tonumber(h:sub(1, 2), 16) / 255, tonumber(h:sub(3, 4), 16) / 255, tonumber(h:sub(5, 6), 16) / 255
            e.hex = "|cff" .. h
        end
    end
end

-- Forever names everyone "Given Family", unique in the region with no realm (UnitDocumentation's
-- RegionalUniqueNamesEnabled answers true there); the simulator names them Name-Realm, so guildmates
-- who share wouldn't be matched to the roster as they are in the game.
RegionalUniqueNamesEnabled = function() return true end
-- With those names Blizzard's unit frames ask whether to show the surname (PlayerInfoDocumentation).
want("C_PlayerInfo", "ShouldDisplaySurname", function() return true end)

-- Blizzard's chat window asks of each whisper whether the game hides it (ChatInfoDocumentation).
want("C_ChatInfo", "IsChatLineCensored", no)
-- The game's colour for the guild's Discord channel (the COLORS of its chat-cache.txt), which the
-- simulator doesn't load.
if ChatTypeInfo and ChatTypeInfo.GUILD_DISCORD then
    ChatTypeInfo.GUILD_DISCORD.r, ChatTypeInfo.GUILD_DISCORD.g, ChatTypeInfo.GUILD_DISCORD.b = 114 / 255, 126 / 255, 1
end

-- A test realm's issue reporter the simulator shows over the middle of the screen.
if PTR_IssueReporter then PTR_IssueReporter:Hide() end

-- The simulator says guild banks are closed (C_GuildBank.IsGuildBankEnabled, GuildBankDocumentation);
-- the game's guilds have them, so the Guild Bank tab draws as a guild with one sees it.
if C_GuildBank then C_GuildBank.IsGuildBankEnabled = function() return true end end

-- This file runs twice, as an addon before Reliquary and again before the tour; what follows hooks
-- the simulator's own functions, so it happens once.
if not RQ_RENDER_FILLED then
    RQ_RENDER_FILLED = true

    -- A film's frames are drawn minutes apart, each by a simulator of its own. With NOW (tools/render.sh)
    -- every one of them is drawn at that one moment, so the times a page shows ("1:53 AM", "2 h ago")
    -- hold still from frame to frame. Set before Reliquary loads: its files keep the clock they find.
    if RQ_NOW then
        local now, time0, date0 = RQ_NOW, time, date
        time = function(t) if t then return time0(t) end return now end
        date = function(format, at) return date0(format, at or now) end
        GetServerTime = function() return now end
    end

    -- The timers Reliquary's own file sets (its login scan among them), kept for the tour: the
    -- simulator runs timers by the clock on the wall while it starts, so whether a render caught the
    -- scan was luck. A hook after C_Timer.After, so the timer itself runs as the game runs it.
    RQ_TIMERS = {}
    hooksecurefunc(C_Timer, "After", function(delay, fn)
        local info = type(fn) == "function" and debug.getinfo(fn, "S")
        if info and tostring(info.source):find("Reliquary[/\\]Reliquary%.lua$") then RQ_TIMERS[#RQ_TIMERS + 1] = { delay = delay, fn = fn } end
    end)
    -- The guilds and what others share, as saved, copied as Reliquary's saved data arrives (before its
    -- own handler and any scan): the scan reads the simulator's own guild roster over the guild and
    -- forgets the guildmates that roster doesn't name, and the tour puts both back.
    local saved = CreateFrame("Frame")
    saved:RegisterEvent("ADDON_LOADED")
    saved:SetScript("OnEvent", function(self, _, name)
        if name ~= "Reliquary" then return end
        self:UnregisterEvent("ADDON_LOADED")
        RQ_SAVED = {}
        for _, key in ipairs({ "guilds", "peers", "chars" }) do
            local t = type(ReliquaryDB) == "table" and ReliquaryDB[key]
            RQ_SAVED[key] = type(t) == "table" and CopyTable(t) or {}
        end
    end)

    -- The simulator reads every colour given as numbers (by code, in a text's |c codes, in Blizzard's
    -- font objects) as linear light and draws it encoded to sRGB, so 0.5 grey comes out 187 of 255
    -- where the game shows 128 (measured: 0.05, 0.2, 0.5 and 0.8 drew as 63, 124, 187 and 231, the
    -- sRGB curve exactly). Each such colour is given to it again decoded from sRGB, so it draws what
    -- the game draws. The hooks run after the simulator's own functions (hooksecurefunc), as replacing
    -- them would make Blizzard's own code untrusted in the simulator. What is read back (a colour, a
    -- text) is what the simulator holds: decoded.
    local function decode(v)
        if type(v) ~= "number" then return v end
        if v <= 0.04045 then return v / 12.92 end
        return ((v + 0.055) / 1.055) ^ 2.4
    end
    -- A text's colour codes, |cAARRGGBB, with red, green and blue decoded.
    local function codes(text)
        if type(text) ~= "string" or not text:find("|c", 1, true) then return text end
        return (text:gsub("|c(%x%x)(%x%x)(%x%x)(%x%x)", function(a, r, g, b)
            local function hex(x) return ("%02x"):format(math.floor(decode(tonumber(x, 16) / 255) * 255 + 0.5)) end
            return "|c" .. a .. hex(r) .. hex(g) .. hex(b)
        end))
    end
    local holder = CreateFrame("Frame")
    local kinds = {
        texture = getmetatable(holder:CreateTexture()), line = getmetatable(holder:CreateLine()),
        text = getmetatable(holder:CreateFontString()), font = getmetatable(CreateFont("ReliquaryRenderFont")),
        bar = getmetatable(CreateFrame("StatusBar")),
    }
    -- Blizzard's own font objects, made before this ran, with the colours they were given.
    local fonts = {}
    local fontIndex = kinds.font and kinds.font.__index
    if type(fontIndex) == "table" and fontIndex.GetTextColor then
        for _, v in pairs(_G) do
            if type(v) == "table" and getmetatable(v) == kinds.font then
                local ok, r, g, b, a = pcall(fontIndex.GetTextColor, v)
                if ok and r then fonts[#fonts + 1] = { v, r, g, b, a } end
            end
        end
    end
    local again = false -- while a hook gives a colour again, its own hook leaves it be
    local function rgb(index, name)
        local real = index[name]
        if type(real) ~= "function" then return end
        hooksecurefunc(index, name, function(self, r, g, b, ...)
            if again or type(r) ~= "number" then return end
            again = true
            real(self, decode(r), decode(g), decode(b), ...)
            again = false
        end)
    end
    local seen = {}
    for _, mt in pairs(kinds) do
        local index = mt and mt.__index
        if type(index) == "table" and not seen[index] then
            seen[index] = true
            for _, name in ipairs({ "SetColorTexture", "SetVertexColor", "SetTextColor", "SetStatusBarColor" }) do rgb(index, name) end
            local gradient = index.SetGradient
            if type(gradient) == "function" then
                hooksecurefunc(index, "SetGradient", function(self, orientation, low, high)
                    if again or type(low) ~= "table" or type(high) ~= "table" then return end
                    local function linear(c) return CreateColor(decode(c.r), decode(c.g), decode(c.b), c.a) end
                    again = true
                    gradient(self, orientation, linear(low), linear(high))
                    again = false
                end)
            end
        end
    end
    for _, f in ipairs(fonts) do fontIndex.SetTextColor(f[1], f[2], f[3], f[4], f[5]) end
    local textIndex = kinds.text and kinds.text.__index
    if type(textIndex) == "table" then
        local set = textIndex.SetText
        -- The tour sets texts again (fixWrap) with what it reads back, decoded already: this sets one
        -- as it is.
        RQ_SET_TEXT_AS_IS = function(fs, text)
            again = true
            set(fs, text)
            again = false
        end
        hooksecurefunc(textIndex, "SetText", function(self, text)
            if again then return end
            local shown = codes(text)
            if shown ~= text then RQ_SET_TEXT_AS_IS(self, shown) end
        end)
        if type(textIndex.SetFormattedText) == "function" then
            hooksecurefunc(textIndex, "SetFormattedText", function(self, fmt, ...)
                if again or type(fmt) ~= "string" then return end
                local text = fmt:format(...)
                local shown = codes(text)
                if shown ~= text then RQ_SET_TEXT_AS_IS(self, shown) end
            end)
        end
    end
end

-- The simulator puts the interface's scale into every frame's effective scale (2.71 at 2081 pixels
-- high, where the game has 1) and gives the screenshot's own size as the screen's, so physical pixels
-- worked out the game's way (PixelUtil: 768 / height / effective scale) come out 2.71 times too small.
-- As the simulator draws, the screen is 768 of its pixels high: so it is said to be. It sets its own
-- functions again after the addons load, so this is done on both runs.
if GetPhysicalScreenSize ~= RQ_SCREEN_SIZE then
    local size = GetPhysicalScreenSize
    RQ_SCREEN_SIZE = function()
        local w, h = size()
        if not (w and h and h > 0) then return w, h end
        return w * 768 / h, 768
    end
    GetPhysicalScreenSize = RQ_SCREEN_SIZE
end
