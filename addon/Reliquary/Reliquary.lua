-- Reliquary: records each of your characters, and lets you share them with your guild, your
-- friends or anyone (Share.lua), and look at what others share (the Viewer files, /rq).
--
-- This file only reads. It never clicks, casts, moves, buys or sends anything and adds no
-- button. Besides reading it takes photos of your character (see Photos below): it may turn
-- the camera and zoom, hides the interface for a moment and takes an ordinary game screenshot,
-- then puts everything back. Everything goes into ReliquaryDB, which the game writes to
-- WTF/Account/<account>/SavedVariables/Reliquary.lua when you log out or type /reload; the
-- dashboard watches that file.
--
-- Forever runs a retail client (interface 16001) with Classic data, so every read goes
-- through call(), which survives a function this client lacks, and every value goes through
-- num()/str(), which drop Midnight's secret values (one secret in the table breaks the whole
-- SavedVariables write). Each part is scanned on its own: one that fails is recorded in
-- char.errors and the rest still save. Timeline.lua keeps each character's timeline.
local ADDON, ns = ...
ns = ns or {}

-- 2: each character has share = { guild, friends, public, parts }; db.guilds and db.peers hold
-- the guild roster, the guild bank and what other players share (Share.lua).
-- 3: every character's share.parts names each part: a new character shares all of it with its
-- guild and friends, and the characters from before keep what they showed.
local SCHEMA = 3
-- The parts of a character others may be shown (Share.lua chooses, per part, who sees it).
ns.PARTS = { "gear", "talents", "profs", "stats", "gold", "place", "played", "reps", "quests", "bags", "bank" }
-- Who sees each part of a new character, as Share.lua's letters (g guild, f friends, p public): its
-- guild and friends see everything; switched on, public sees its gear, talents, professions and
-- character sheet.
ns.PART_DEFAULT = { gear = "gfp", talents = "gfp", profs = "gfp", stats = "gfp", gold = "gf", place = "gf", played = "gf",
    reps = "gf", quests = "gf", bags = "gf", bank = "gf" }
-- Up to 1.7.0 a part nobody had chosen for went to these (the rest to nobody).
local PART_DEFAULT_BEFORE = { gear = "gfp", talents = "gfp", profs = "gfp", stats = "gfp" }

local pairs, ipairs, type, select, tostring, tonumber, pcall, next = pairs, ipairs, type, select, tostring, tonumber, pcall, next
local floor, format, time, date, wipe, unpack = math.floor, string.format, time, date, wipe, unpack or table.unpack
local issecretvalue = issecretvalue or function() return false end

---------------------------------------------------------------------------
-- Safe reading
---------------------------------------------------------------------------
local function pack(...) return { n = select("#", ...), ... } end

-- Calls fn if it exists; returns its results, or nothing if it is missing or errors.
local function call(fn, ...)
    if type(fn) ~= "function" then return end
    local r = pack(pcall(fn, ...))
    if not r[1] then return end
    return unpack(r, 2, r.n)
end

local function plain(v)
    if v == nil or issecretvalue(v) then return nil end
    return v
end

local function num(v)
    v = plain(v)
    if type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge then return v end
end

local function str(v)
    v = plain(v)
    if type(v) == "string" and v ~= "" then return v end
end

-- WoW: Forever names characters "Given Family", unique in the region: UnitName gives the family
-- name where other clients give the realm (Blizzard's Camelot NameUtil.lua).
local function regionalNames() return plain(call(RegionalUniqueNamesEnabled)) == true end

local function round(v, places)
    v = num(v)
    if not v then return nil end
    local m = 10 ^ (places or 0)
    return floor(v * m + 0.5) / m
end

local function hex(c)
    if type(c) ~= "table" then return nil end
    local r, g, b = num(c.r), num(c.g), num(c.b)
    if not (r and g and b) then return nil end
    return format("%02x%02x%02x", floor(r * 255 + 0.5), floor(g * 255 + 0.5), floor(b * 255 + 0.5))
end

local function api(path)
    local t = _G
    for part in path:gmatch("[^%.]+") do
        if type(t) ~= "table" then return nil end
        t = t[part]
    end
    return t
end

-- The version lives in one place, the TOC (the release packager stamps it there).
local VERSION = str(call(api("C_AddOns.GetAddOnMetadata"), ADDON, "Version"))
    or str(call(GetAddOnMetadata, ADDON, "Version")) or "unknown"

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------
local db, char, charKey
local itemsSeen = {}       -- itemIDs whose tooltip was read this session
local dirty = {}           -- parts waiting for a scan
local flushQueued = false
local bankOpen = false
local loggedIn = false
local gearRetries = 0
local onNewPlace           -- set by the Photos section: she has stood somewhere new

local frame = CreateFrame("Frame")
local handlers = {}
local function on(event, fn)
    if not handlers[event] then
        handlers[event] = {}
        pcall(frame.RegisterEvent, frame, event) -- an event this client lacks is skipped
    end
    local list = handlers[event]
    list[#list + 1] = fn
end
frame:SetScript("OnEvent", function(_, event, ...)
    local list = handlers[event]
    if not list then return end
    for i = 1, #list do list[i](...) end
end)

local function inCombat()
    return (call(InCombatLockdown) == true) or (call(UnitAffectingCombat, "player") == true)
end

---------------------------------------------------------------------------
-- Tooltips: the game's own lines, with their colours
---------------------------------------------------------------------------
local function surface(line)
    if line.leftText ~= nil or line.rightText ~= nil or type(line.args) ~= "table" then return line end
    local out = {}
    for _, a in ipairs(line.args) do
        if type(a) == "table" and a.field then
            out[a.field] = a.stringVal or a.colorVal or a.intVal or a.floatVal or a.boolVal
        end
    end
    return out
end

local function tooltipLines(data)
    if type(data) ~= "table" or type(data.lines) ~= "table" then return nil end
    local out = {}
    for _, raw in ipairs(data.lines) do
        if type(raw) == "table" then
            local line = surface(raw)
            local l, r = str(line.leftText), str(line.rightText)
            if l or r then
                out[#out + 1] = { l = l, lc = hex(line.leftColor), r = r, rc = hex(line.rightColor) }
            end
        end
    end
    if #out > 0 then return out end
end

local TT = api("C_TooltipInfo")

---------------------------------------------------------------------------
-- Items
---------------------------------------------------------------------------
local CI = api("C_Item") or {}

local function itemID(link)
    return link and tonumber(link:match("|Hitem:(%d+)"))
end

-- What the dashboard needs about one item: id, name, quality, icon, item level, kind (in words, and
-- as the game numbers its classes, which every language shares).
local function itemRecord(link, id)
    link = str(link)
    id = num(id) or itemID(link)
    if not id then return nil end
    local rec = { id = id, link = link }
    rec.name = link and link:match("|h%[(.-)%]|h")
    local name, _, quality, ilvl, reqLevel, kind, subKind, _, equipLoc, icon, sell, classID, subClassID, bind, _, _, reagent = call(CI.GetItemInfo or GetItemInfo, link or id)
    rec.name = rec.name or str(name)
    rec.q = num(quality) or num(call(CI.GetItemQualityByID, link or id))
    rec.icon = num(icon) or num(call(CI.GetItemIconByID, id)) or num(call(GetItemIcon, id))
    rec.ilvl = num(call(CI.GetDetailedItemLevelInfo or GetDetailedItemLevelInfo, link or id)) or num(ilvl)
    rec.req = num(reqLevel)
    rec.kind, rec.sub, rec.loc = str(kind), str(subKind), str(equipLoc)
    rec.cls, rec.scls = num(classID), num(subClassID)
    rec.sell = num(sell)
    rec.bind = num(bind) -- 1 binds when picked up, 2 when equipped, 3 when used, 4 a quest item
    rec.reagent = plain(reagent) == true or nil -- the game's "Crafting Reagent"
    return rec
end

-- The game fetches an item from the server the first time anything asks about it (a guildmate's
-- item, one in the guild bank). Until it arrives its tooltip says only "Retrieving item
-- information", in red, with no stats. itemLoaded(id, fn) says whether the game has the item (yes
-- when the game can't tell); if not, it asks for it and runs fn when it comes.
local loadWaits = {} -- [itemID] = what runs when the game has the item
local function itemLoaded(id, fn)
    if not (id and CI.IsItemDataCachedByID and CI.RequestLoadItemDataByID) or plain(call(CI.IsItemDataCachedByID, id)) ~= false then return true end
    local list = loadWaits[id]
    if not list then
        list = {}
        loadWaits[id] = list
        call(CI.RequestLoadItemDataByID, id)
    end
    if fn then list[#list + 1] = fn end
    return false
end
ns.itemLoaded = itemLoaded
local function itemArrived(itemID, success)
    local id = num(itemID)
    local list = id and loadWaits[id]
    if not list then return end
    loadWaits[id] = nil
    if plain(success) == false then return end -- no such item: nothing waits for it
    for _, fn in ipairs(list) do pcall(fn) end
end
on("ITEM_DATA_LOAD_RESULT", itemArrived)
on("GET_ITEM_INFO_RECEIVED", itemArrived)

-- One tooltip per item kind, shared by every character, refreshed once a session, read once the
-- game has the item (an item it had to fetch is read from its link). A line the game is still
-- filling in after that (an Equip: effect waits for its spell) is read again when the game says it
-- has it, as the game's own tooltip does (TOOLTIP_DATA_UPDATE). A tooltip that shows another item
-- (a recipe shows the dish it teaches) says "Retrieving item information" for it until the game
-- has fetched that one too: it is read again a moment later, a few times at most.
local filling = {} -- [dataInstanceID] = { id, link, at }: tooltips read in the last minute
local rereads = {} -- [itemID] = times a tooltip still loading a part was read again this session
local function rememberTooltip(id, link, reader, ...)
    if not (id and TT and reader) or itemsSeen[id] then return end
    link = str(link) or ("item:" .. id)
    if not itemLoaded(id, function() rememberTooltip(id, link, TT.GetHyperlink, link) end) then return end
    local data = call(reader, ...)
    local lines = tooltipLines(data)
    if lines then
        local r = itemRecord(nil, id)
        local stack = num(select(8, call(CI.GetItemInfo or GetItemInfo, id)))
        db.items[id] = { tip = lines, at = time(), info = r and { name = r.name, q = r.q, icon = r.icon, ilvl = r.ilvl, req = r.req, kind = r.kind,
            sub = r.sub, loc = r.loc, sell = r.sell, bind = r.bind, stack = stack and stack > 1 and stack or nil, cls = r.cls, scls = r.scls, reagent = r.reagent } or nil }
        local loading, whole = str(RETRIEVING_ITEM_INFO), true
        for _, l in ipairs(lines) do if loading and l.l == loading then whole = false end end
        if whole or (rereads[id] or 0) >= 5 or not C_Timer then
            itemsSeen[id] = true
        else
            rereads[id] = (rereads[id] or 0) + 1
            C_Timer.After(1, function() rememberTooltip(id, link, TT.GetHyperlink, link) end)
        end
        local inst = num(data.dataInstanceID)
        if inst then filling[inst] = { id = id, link = link, at = num(call(GetTime)) or 0 } end
    end
end

-- Reads again the tooltips the game says it has filled in; those read over a minute ago are let go.
local refilling = false
local function refill()
    refilling = false
    local t, again = num(call(GetTime)) or 0, {}
    for inst, f in pairs(filling) do
        if t - f.at > 60 then
            filling[inst] = nil
        elseif f.due then
            filling[inst] = nil
            local data = call(TT.GetHyperlink, f.link)
            local lines = tooltipLines(data)
            if lines and type(db.items[f.id]) == "table" then db.items[f.id].tip = lines end
            local later = type(data) == "table" and num(data.dataInstanceID)
            if later then again[later] = { id = f.id, link = f.link, at = f.at } end
        end
    end
    for inst, f in pairs(again) do filling[inst] = f end
end
on("TOOLTIP_DATA_UPDATE", function(dataInstanceID)
    local inst, any = num(dataInstanceID), false -- no instance: any of them may have changed
    if inst then
        if filling[inst] then filling[inst].due, any = true, true end
    else
        for _, f in pairs(filling) do f.due, any = true, true end
    end
    if any and not refilling and C_Timer and TT then refilling = true C_Timer.After(0.2, refill) end
end)

---------------------------------------------------------------------------
-- Character basics, money, XP and place
---------------------------------------------------------------------------
local function scanBasics()
    local c = char
    local name, second = call(UnitName, "player")
    c.name = str(name) or c.name
    c.realm = str(call(GetRealmName)) or c.realm
    -- The family name, where the game has them; the realm is c.realm. (The key is both: start().)
    if regionalNames() then c.surname = str(second) or c.surname end
    local race, raceFile = call(UnitRace, "player")
    c.race, c.raceFile = str(race) or c.race, str(raceFile) or c.raceFile
    local class, classFile, classID = call(UnitClass, "player")
    c.class, c.classFile, c.classID = str(class) or c.class, str(classFile) or c.classFile, num(classID) or c.classID
    -- The spec: its role and main stat say which items suit this character (Upgrades.lua).
    local specIndex = num(call(GetSpecialization))
    if specIndex then
        local specID, specName, _, _, role, primaryStat = call(GetSpecializationInfo, specIndex)
        if num(specID) then c.spec = { id = num(specID), name = str(specName), role = str(role), ps = num(primaryStat) } end
    end
    c.sex = num(call(UnitSex, "player")) or c.sex
    local faction, factionName = call(UnitFactionGroup, "player")
    c.faction = str(faction) or c.faction
    c.factionName = str(factionName) or c.factionName
    local level = num(call(UnitLevel, "player"))
    if level and level > 0 then c.level = level end
    c.maxLevel = num(call(GetMaxPlayerLevel)) or c.maxLevel
    local guild, rank, rankIndex = call(GetGuildInfo, "player")
    c.guild, c.guildRank = str(guild), str(rank)
    -- The rank's place in the guild's order, 1 being the guild master (the game counts from 0).
    c.guildRankOrder = c.guild and num(rankIndex) and num(rankIndex) + 1 or nil
    local titleID = num(call(GetCurrentTitle))
    c.title = titleID and titleID > 0 and str(call(GetTitleName, titleID)) or nil
    c.hearth = str(call(GetBindLocation)) or c.hearth
    c.ruleset = (function()
        local rules, active = api("Enum.GameRule"), api("C_GameRules.IsGameRuleActive")
        if not (rules and active) then return c.ruleset end
        local asked
        for _, pair in ipairs({ { "HardcoreRuleset", "hardcore" }, { "RPRuleset", "rp" }, { "PvPRuleset", "pvp" } }) do
            if rules[pair[1]] ~= nil then
                local onRule = plain(call(active, rules[pair[1]]))
                if onRule ~= nil then asked = true end
                if onRule then return pair[2] end
            end
        end
        if not asked then return c.ruleset end
        return "normal"
    end)()
    -- The game reports the RP-PvP ruleset as both PvP and RP: name it once.
    if c.ruleset == "rp" or c.ruleset == "pvp" then
        local rules, active = api("Enum.GameRule"), api("C_GameRules.IsGameRuleActive")
        local rp = rules and rules.RPRuleset and plain(call(active, rules.RPRuleset))
        local pvp = rules and rules.PvPRuleset and plain(call(active, rules.PvPRuleset))
        if rp and pvp then c.ruleset = "rppvp" end
    end
end

local function scanMoneyXP()
    local c = char
    local money = num(call(GetMoney))
    if money then c.money = money end
    local xp, xpMax = num(call(UnitXP, "player")), num(call(UnitXPMax, "player"))
    -- While logging out the game reports max XP as 0: never store that.
    if xp and xpMax and xpMax > 0 then
        c.xp, c.xpMax = xp, xpMax
        c.rested = num(call(GetXPExhaustion)) or 0
        c.resting = call(IsResting) == true or nil
    end
    local hp, hpMax = num(call(UnitHealth, "player")), num(call(UnitHealthMax, "player"))
    if hpMax and hpMax > 0 then c.health, c.healthMax = hp, hpMax end
    local powerType, powerToken = call(UnitPowerType, "player")
    local pMax = num(call(UnitPowerMax, "player"))
    if pMax and pMax > 0 then
        c.power, c.powerMax = num(call(UnitPower, "player")), pMax
        c.powerType = num(powerType)
        c.powerToken = str(powerToken)
    end
    -- Druids always have mana as well, whatever form they are in.
    local manaType = api("Enum.PowerType.Mana") or 0
    local manaMax = num(call(UnitPowerMax, "player", manaType))
    if manaMax and manaMax > 0 then
        c.mana, c.manaMax = num(call(UnitPower, "player", manaType)), manaMax
    end
end

local function scanPlace()
    local c = char
    local zone = str(call(GetRealZoneText)) or str(call(GetZoneText))
    local sub = str(call(GetSubZoneText))
    local mini = str(call(GetMinimapZoneText))
    if zone then c.zone = zone end
    c.subzone = sub
    c.places = c.places or {}
    local now = time()
    local newest
    for _, place in ipairs({ zone, sub, mini }) do
        if place and not c.places[place] then
            c.places[place] = now
            newest = place -- the most specific new name wins (zone, then subzone, then spot)
        end
    end
    if newest and onNewPlace then onNewPlace(newest) end
    local mapID = num(call(api("C_Map.GetBestMapForUnit"), "player"))
    c.mapID = mapID
    c.x, c.y = nil, nil
    if mapID then
        local pos = call(api("C_Map.GetPlayerMapPosition"), mapID, "player")
        if type(pos) == "table" and pos.GetXY then
            local x, y = call(pos.GetXY, pos)
            if num(x) and num(y) and (x > 0 or y > 0) then
                c.x, c.y = round(x * 100, 1), round(y * 100, 1)
            end
        end
        local info = call(api("C_Map.GetMapInfo"), mapID)
        if type(info) == "table" then c.mapName = str(info.name) end
    end
end

---------------------------------------------------------------------------
-- Stats: the numbers on the character sheet
---------------------------------------------------------------------------
local STAT_NAMES = { "str", "agi", "sta", "int", "spi" }
local SCHOOLS = { "holy", "fire", "nature", "frost", "shadow", "arcane" } -- spell schools 2..7

local function scanStats()
    local s = {}
    for i, key in ipairs(STAT_NAMES) do
        local base, total, plus, minus = call(UnitStat, "player", i)
        if num(total) then s[key] = { base = num(base), total = num(total), plus = num(plus), minus = num(minus) } end
    end
    local baseArmor, armor = call(UnitArmor, "player")
    s.armor = num(armor) or num(baseArmor)
    s.resist = {}
    for i, key in ipairs(SCHOOLS) do
        local _, total = call(UnitResistance, "player", i)
        if num(total) then s.resist[key] = num(total) end
    end
    local apBase, apPlus, apMinus = call(UnitAttackPower, "player")
    if num(apBase) then s.ap = num(apBase) + (num(apPlus) or 0) + (num(apMinus) or 0) end
    local rapBase, rapPlus, rapMinus = call(UnitRangedAttackPower, "player")
    if num(rapBase) then s.rap = num(rapBase) + (num(rapPlus) or 0) + (num(rapMinus) or 0) end
    s.crit = round(call(GetCritChance), 2)
    s.rangedCrit = round(call(GetRangedCritChance), 2)
    s.hit = round(call(GetHitModifier), 2)
    s.spellHit = round(call(GetSpellHitModifier), 2)
    s.dodge = round(call(GetDodgeChance), 2)
    s.parry = round(call(GetParryChance), 2)
    s.block = round(call(GetBlockChance), 2)
    local best, bestCrit
    for i = 2, 7 do
        local dmg, crit = num(call(GetSpellBonusDamage, i)), num(call(GetSpellCritChance, i))
        if dmg and (not best or dmg > best) then best = dmg end
        if crit and (not bestCrit or crit > bestCrit) then bestCrit = crit end
    end
    s.spellPower = best
    s.spellCrit = round(bestCrit, 2)
    s.healing = num(call(GetSpellBonusHealing))
    local regenBase, regenCasting = call(GetManaRegen)
    s.mp5 = round(num(regenBase) and regenBase * 5, 0)
    s.mp5Casting = round(num(regenCasting) and regenCasting * 5, 0)
    local mainSpeed, offSpeed = call(UnitAttackSpeed, "player")
    s.speed = round(mainSpeed, 2)
    s.offSpeed = round(offSpeed, 2)
    local minDmg, maxDmg = call(UnitDamage, "player")
    -- Match the game's main-hand character sheet, including its minimum of one.
    if num(minDmg) and num(maxDmg) then s.dmg = { math.max(floor(minDmg), 1), math.max(math.ceil(maxDmg), 1) } end
    local _, avgEquipped = call(GetAverageItemLevel)
    s.ilvl = round(avgEquipped, 1)
    char.stats = s
end

---------------------------------------------------------------------------
-- Gear: every slot with its tooltip and wear
---------------------------------------------------------------------------
local GEAR_SLOTS = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19 }

-- Returns true when an item is in a slot but its link isn't ready yet: try again shortly.
local function scanGear()
    local gear = char.gear or {}
    local incomplete = false
    local any = false
    for _, slot in ipairs(GEAR_SLOTS) do
        if num(call(GetInventoryItemID, "player", slot)) then any = true break end
    end
    -- Just after login the game may know nothing yet: never wipe what we had.
    if not any and next(gear) then return true end
    local lowest
    for _, slot in ipairs(GEAR_SLOTS) do
        local link = str(call(GetInventoryItemLink, "player", slot))
        local id = num(call(GetInventoryItemID, "player", slot))
        if link then
            local rec = itemRecord(link, id) or { id = id }
            rec.tip = TT and tooltipLines(call(TT.GetInventoryItem, "player", slot)) or nil
            local cur, max = call(GetInventoryItemDurability, slot)
            cur, max = num(cur), num(max)
            if cur and max and max > 0 then
                rec.dur = { cur, max }
                local pct = cur / max
                if not lowest or pct < lowest then lowest = pct end
            end
            gear[slot] = rec
        elseif id then
            incomplete = true
        else
            gear[slot] = nil
        end
    end
    char.gear = gear
    char.durability = lowest and floor(lowest * 100 + 0.5) or nil
    return incomplete
end

---------------------------------------------------------------------------
-- Bags and bank
---------------------------------------------------------------------------
local CC = api("C_Container") or {}
local BagIndex = api("Enum.BagIndex")

local function bagList(names, fallback)
    local list = {}
    if BagIndex then
        for _, name in ipairs(names) do
            local bag = BagIndex[name]
            if bag then list[#list + 1] = bag end
        end
    end
    if #list == 0 then for _, bag in ipairs(fallback) do list[#list + 1] = bag end end
    return list
end

local CARRIED = bagList({ "Backpack", "Bag_1", "Bag_2", "Bag_3", "Bag_4", "ReagentBag", "Keyring" }, { 0, 1, 2, 3, 4 })
local BANK = (function()
    local names = { "Bank", "BankBag_1", "BankBag_2", "BankBag_3", "BankBag_4", "BankBag_5", "BankBag_6", "BankBag_7" }
    for i = 1, 9 do names[#names + 1] = "CharacterBankTab_" .. i end
    return bagList(names, { -1, 5, 6, 7, 8, 9, 10, 11 })
end)()

local function slotCount(bag)
    return num(call(CC.GetContainerNumSlots or GetContainerNumSlots, bag)) or 0
end

local function readSlot(bag, slot)
    local info = call(CC.GetContainerItemInfo, bag, slot)
    if type(info) == "table" then
        local id = num(info.itemID)
        if not id then return nil end
        return id, num(info.stackCount) or 1, str(info.hyperlink), num(info.quality), num(info.iconFileID), plain(info.isBound) == true
    end
    -- Older clients return a list instead of a table.
    local icon, count, _, quality, _, _, link, _, _, id = call(GetContainerItemInfo, bag, slot)
    id = num(id) or itemID(str(link))
    if id then return id, num(count) or 1, str(link), num(quality), num(icon) end
end

local function scanContainers(bags)
    local out = {}
    for _, bag in ipairs(bags) do
        local size = slotCount(bag)
        if size > 0 then
            local rec = { bag = bag, size = size, slots = {} }
            local inv = num(call(CC.ContainerIDToInventoryID, bag))
            if inv then
                local link = str(call(GetInventoryItemLink, "player", inv))
                if link then rec.item = itemRecord(link) end
            end
            local free = 0
            for slot = 1, size do
                local id, count, link, quality, icon, bound = readSlot(bag, slot)
                if id then
                    local item = { id = id, n = count, q = quality, icon = icon, link = link, bd = bound or nil }
                    item.name = link and link:match("|h%[(.-)%]|h")
                    if not item.name or not item.q or not item.icon then
                        local r = itemRecord(link, id)
                        if r then
                            item.name = item.name or r.name
                            item.q = item.q or r.q
                            item.icon = item.icon or r.icon
                        end
                    end
                    rec.slots[slot] = item
                    rememberTooltip(id, link, TT and TT.GetBagItem, bag, slot)
                else
                    free = free + 1
                end
            end
            rec.free = free
            out[#out + 1] = rec
        end
    end
    return out
end

local function scanBags()
    char.bags = scanContainers(CARRIED)
end

local function scanBank()
    if not bankOpen then return end
    local bank = scanContainers(BANK)
    -- An empty read while the bank is open is the game not being ready: keep the last one.
    if #bank > 0 then
        char.bank = bank
        char.bankAt = time()
    end
end

---------------------------------------------------------------------------
-- Talents and Legacy (Forever runs both on retail's trait system)
---------------------------------------------------------------------------
local Traits = api("C_Traits")
local CLASS_CONFIG, LEGACY_CONFIG = 4, 3

local function configOf(kind, fallback)
    if not (Traits and Traits.GetConfigsByType) then return nil end
    local t = api("Enum.TraitConfigType")
    local list = call(Traits.GetConfigsByType, (t and t[kind]) or fallback)
    return type(list) == "table" and num(list[1]) or nil
end

local function spellInfo(spellID)
    local info = call(api("C_Spell.GetSpellInfo"), spellID)
    if type(info) == "table" then return str(info.name), num(info.iconID) end
    local name, _, icon = call(GetSpellInfo, spellID)
    return str(name), num(icon)
end

local function spellDescription(spellID)
    return str(call(api("C_Spell.GetSpellDescription"), spellID)) or str(call(GetSpellDescription, spellID))
end

local function readTree(config, tree)
    local ids = call(Traits.GetTreeNodes, tree)
    if type(ids) ~= "table" then return nil end
    local nodes = {}
    for _, nodeID in ipairs(ids) do
        local n = call(Traits.GetNodeInfo, config, nodeID)
        if type(n) == "table" and num(n.ID) == nodeID then
            local rec = {
                id = nodeID, x = num(n.posX), y = num(n.posY),
                rank = num(n.currentRank) or 0, max = num(n.maxRanks) or 0,
            }
            if plain(n.isVisible) == false then rec.hidden = true end
            local entryID = (type(n.activeEntry) == "table" and num(n.activeEntry.entryID))
                or (type(n.entryIDs) == "table" and num(n.entryIDs[1]))
            if entryID then
                local e = call(Traits.GetEntryInfo, config, entryID)
                local defID = type(e) == "table" and num(e.definitionID)
                local def = defID and call(Traits.GetDefinitionInfo, defID)
                if type(def) == "table" then
                    rec.spell = num(def.spellID) or num(def.overriddenSpellID)
                    rec.name = str(def.overrideName)
                    rec.icon = num(def.overrideIcon)
                end
            end
            if rec.spell then
                local name, icon = spellInfo(rec.spell)
                rec.name = rec.name or name
                rec.icon = rec.icon or icon
                rec.desc = spellDescription(rec.spell)
            end
            if type(n.visibleEdges) == "table" then
                for _, edge in ipairs(n.visibleEdges) do
                    local target = type(edge) == "table" and num(edge.targetNode)
                    if target then
                        rec.to = rec.to or {}
                        rec.to[#rec.to + 1] = target
                    end
                end
            end
            nodes[#nodes + 1] = rec
        end
    end
    return nodes
end

local function treeCurrency(config, tree)
    local list = call(Traits.GetTreeCurrencyInfo, config, tree, false)
    local cur = type(list) == "table" and list[1]
    if type(cur) == "table" then return num(cur.quantity), num(cur.spent), num(cur.maxQuantity) end
end

local function scanTalents()
    if not Traits then return end
    local config = configOf("CamelotCombat", CLASS_CONFIG)
    if not config then return end
    local info = call(Traits.GetConfigInfo, config)
    local tree = type(info) == "table" and type(info.treeIDs) == "table" and num(info.treeIDs[1])
    if not tree then return end
    local nodes = readTree(config, tree)
    if not nodes or #nodes == 0 then return end
    local left, spent = treeCurrency(config, tree)
    char.talents = { tree = tree, nodes = nodes, unspent = left, spent = spent, at = time() }
end

local function scanLegacy()
    if not Traits then return end
    local config = configOf("Generic", LEGACY_CONFIG)
    if not config then return end
    local info = call(Traits.GetConfigInfo, config)
    local trees = type(info) == "table" and type(info.treeIDs) == "table" and info.treeIDs
    if not trees then return end
    local out = { trees = {} }
    for _, raw in ipairs(trees) do
        local tree = num(raw)
        if tree then
            local nodes = readTree(config, tree)
            if nodes and #nodes > 0 then out.trees[#out.trees + 1] = { id = tree, nodes = nodes } end
            if not out.left then
                local left, spent = treeCurrency(config, tree)
                if left and spent then out.left, out.spent = left, spent end
            end
        end
    end
    if #out.trees > 0 then
        out.at = time()
        char.legacy = out
    end
end

---------------------------------------------------------------------------
-- Professions and skills
---------------------------------------------------------------------------
local function scanProfessions()
    local profs = {}
    local indexes = pack(call(GetProfessions))
    for i = 1, indexes.n do
        local index = num(indexes[i])
        if index then
            local name, icon, skill, max, _, _, skillLine, modifier = call(GetProfessionInfo, index)
            if str(name) then
                profs[#profs + 1] = {
                    name = str(name), icon = num(icon), skill = num(skill), max = num(max),
                    line = num(skillLine), bonus = num(modifier), primary = i <= 2 or nil,
                }
            end
        end
    end
    if #profs > 0 or not char.profs then char.profs = profs end

    -- Classic's skill list (weapon skills, languages, riding): only if this client has it.
    local count = num(call(GetNumSkillLines))
    if count and count > 0 then
        local skills, header = {}, nil
        for i = 1, count do
            local name, isHeader, _, rank, temp, modifier, maxRank = call(GetSkillLineInfo, i)
            name = str(name)
            if name then
                if plain(isHeader) then
                    header = name
                else
                    skills[#skills + 1] = { name = name, group = header, rank = num(rank), max = num(maxRank), bonus = (num(temp) or 0) + (num(modifier) or 0) }
                end
            end
        end
        if #skills > 0 then char.skills = skills end
    end
end

---------------------------------------------------------------------------
-- Reputation (the list in the order the game shows it)
---------------------------------------------------------------------------
local function scanReputation()
    local R = api("C_Reputation")
    local list = {}
    if R and R.GetNumFactions and R.GetFactionDataByIndex then
        for i = 1, num(call(R.GetNumFactions)) or 0 do
            local d = call(R.GetFactionDataByIndex, i)
            if type(d) == "table" and str(d.name) then
                local isHeader = plain(d.isHeader)
                local rec = { name = str(d.name), id = num(d.factionID) }
                if isHeader and not plain(d.isHeaderWithRep) then
                    rec.header = true
                else
                    rec.reaction = num(d.reaction)
                    rec.value = num(d.currentStanding)
                    rec.lo = num(d.currentReactionThreshold)
                    rec.hi = num(d.nextReactionThreshold)
                    rec.war = plain(d.atWarWith) == true or nil
                    rec.child = plain(d.isChild) == true or nil
                    if isHeader then rec.header = true end
                end
                list[#list + 1] = rec
            end
        end
    else
        for i = 1, num(call(GetNumFactions)) or 0 do
            local name, _, standing, lo, hi, value, war, _, isHeader, _, hasRep, _, isChild, id = call(GetFactionInfo, i)
            if str(name) then
                local rec = { name = str(name), id = num(id) }
                if plain(isHeader) and not plain(hasRep) then
                    rec.header = true
                else
                    rec.reaction, rec.lo, rec.hi, rec.value = num(standing), num(lo), num(hi), num(value)
                    rec.war = plain(war) == true or nil
                    rec.child = plain(isChild) == true or nil
                    if plain(isHeader) then rec.header = true end
                end
                list[#list + 1] = rec
            end
        end
    end
    if #list > 0 then char.reps = list end
end

---------------------------------------------------------------------------
-- Quest log
---------------------------------------------------------------------------
local function objectives(questID)
    local list = call(api("C_QuestLog.GetQuestObjectives"), questID)
    if type(list) ~= "table" then return nil end
    local out = {}
    for _, o in ipairs(list) do
        if type(o) == "table" and str(o.text) then
            out[#out + 1] = { text = str(o.text), done = plain(o.finished) == true or nil }
        end
    end
    if #out > 0 then return out end
end

local function scanQuests()
    local Q = api("C_QuestLog")
    local quests, header = {}, nil
    if Q and Q.GetNumQuestLogEntries and Q.GetInfo then
        for i = 1, num(call(Q.GetNumQuestLogEntries)) or 0 do
            local info = call(Q.GetInfo, i)
            if type(info) == "table" and str(info.title) then
                if plain(info.isHeader) then
                    header = str(info.title)
                elseif not plain(info.isHidden) then
                    local id = num(info.questID)
                    quests[#quests + 1] = {
                        id = id, title = str(info.title), level = num(info.level), group = header,
                        done = id and call(Q.IsComplete, id) == true or nil,
                        obj = id and objectives(id) or nil,
                    }
                end
            end
        end
    else
        for i = 1, num(call(GetNumQuestLogEntries)) or 0 do
            local title, level, _, isHeader, _, isComplete, _, id = call(GetQuestLogTitle, i)
            if str(title) then
                if plain(isHeader) then
                    header = str(title)
                else
                    quests[#quests + 1] = { id = num(id), title = str(title), level = num(level), group = header, done = num(isComplete) == 1 or nil }
                end
            end
        end
    end
    char.quests = quests
end

---------------------------------------------------------------------------
-- Guild: the roster as the game lists it, and the guild bank as last seen
---------------------------------------------------------------------------
-- The roster comes from the game's own guild list: names, ranks, levels, classes, zones, public
-- notes and professions, never officer notes. A guild is kept only while one of your characters
-- is in it. The guild bank can only be read while it is open: each tab this character may view
-- is asked for in turn, as clicking the bank's own tabs does, and read when the game sends it.
local GUILD_READ_GAP = 60   -- seconds between two reads of a whole roster
local BANK_SLOTS = 98       -- slots in a guild bank tab
local guildReadAt = -math.huge

local function guildKey()
    local name, _, _, realm = call(GetGuildInfo, "player")
    name = str(name)
    if not name then return nil end
    realm = str(realm) or str(call(GetRealmName)) or "?"
    return name .. "@" .. realm, name, realm
end

local function guildRecord(create)
    local gk, name, realm = guildKey()
    if not gk then return nil end
    local g = db.guilds[gk]
    if not g and create then
        g = {}
        db.guilds[gk] = g
    end
    if g then g.key, g.name, g.realm = gk, name, realm end
    return g, gk
end

local ONLINE = { [1] = true, [2] = true, [4] = true, [5] = true } -- Enum.ClubMemberPresence: online, mobile, away, busy

local function classFileOf(classID)
    local _, file = call(GetClassInfo, classID)
    return str(file)
end

-- Time since a member was last online, from the game's years, months, days and hours.
local function offlineFor(y, mo, d, h)
    y, mo, d, h = num(y), num(mo), num(d), num(h)
    if not (y or mo or d or h) then return nil end
    return (((y or 0) * 365 + (mo or 0) * 30 + (d or 0)) * 24 + (h or 0)) * 3600
end

local function readRoster()
    local out = {}
    local Club = api("C_Club")
    local clubId = Club and call(Club.GetGuildClubId)
    local ids = clubId and call(Club.GetClubMembers, clubId)
    local now = time()
    if type(ids) == "table" then
        for _, memberId in ipairs(ids) do
            local m = call(Club.GetMemberInfo, clubId, memberId)
            local name = type(m) == "table" and str(m.name)
            if name then
                local presence = num(m.presence)
                local away = not ONLINE[presence] and offlineFor(m.lastOnlineYear, m.lastOnlineMonth, m.lastOnlineDay, m.lastOnlineHour)
                out[#out + 1] = {
                    n = name, rank = str(m.guildRank), ro = num(m.guildRankOrder), lv = num(m.level),
                    cls = num(m.classID) and classFileOf(m.classID), z = str(m.zone), note = str(m.memberNote),
                    on = ONLINE[presence] or nil, mobile = presence == 2 or nil, seen = away and now - away or nil,
                    p1 = str(m.profession1Name), p1r = num(m.profession1Rank),
                    p2 = str(m.profession2Name), p2r = num(m.profession2Rank),
                    me = plain(m.isSelf) == true or nil,
                }
            end
        end
    end
    if #out == 0 then -- a client without the club roster
        for i = 1, num(call(GetNumGuildMembers)) or 0 do
            local name, rank, rankIndex, level, _, zone, note, _, online, _, classFile = call(GetGuildRosterInfo, i)
            name = str(name)
            if name then
                local on = plain(online) == true
                local away = not on and offlineFor(call(GetGuildRosterLastOnline, i))
                rankIndex = num(rankIndex)
                out[#out + 1] = {
                    n = name, rank = str(rank), ro = rankIndex and rankIndex + 1, lv = num(level), cls = str(classFile),
                    z = str(zone), note = str(note), on = on or nil, seen = away and now - away or nil,
                }
            end
        end
    end
    return out
end

-- Which of these guildmates (a set of full names) are in the game this moment, as the game's guild
-- list says now: not those on the mobile app, who can't hear addons. nil when the game won't say.
ns.inGameNow = function(names)
    local out = {}
    local Club = api("C_Club")
    local clubId = Club and call(Club.GetGuildClubId)
    local ids = clubId and call(Club.GetClubMembers, clubId)
    if type(ids) == "table" and #ids > 0 then
        for _, memberId in ipairs(ids) do
            local m = call(Club.GetMemberInfo, clubId, memberId)
            local name = type(m) == "table" and str(m.name)
            local who = name and ns.fullName(name)
            local presence = type(m) == "table" and num(m.presence)
            if who and names[who] and ONLINE[presence] and presence ~= 2 then out[who] = true end
        end
        return out
    end
    local n = num(call(GetNumGuildMembers)) or 0
    if n == 0 then return nil end
    for i = 1, n do
        local name, _, _, _, _, _, _, _, online = call(GetGuildRosterInfo, i)
        name = str(name)
        local who = name and ns.fullName(name)
        if who and names[who] and plain(online) == true then out[who] = true end
    end
    return out
end

local function scanGuild()
    local g = guildRecord(true)
    for gk, other in pairs(db.guilds) do
        -- A guild this character has left: forget it once none of your characters is in it.
        if other ~= g and type(other.mine) == "table" and other.mine[charKey] then
            other.mine[charKey] = nil
            if next(other.mine) == nil then db.guilds[gk] = nil end
        end
    end
    if not g then return end
    g.faction = char.faction or g.faction
    g.motd = str(call(GetGuildRosterMOTD)) or g.motd
    g.mine = type(g.mine) == "table" and g.mine or {}
    g.mine[charKey] = { rank = char.guildRank, ro = char.guildRankOrder, at = time() }
    if g.members and time() - guildReadAt < GUILD_READ_GAP then return end
    -- In the chat lockdown the game hides members' details: keep the last full list.
    if plain(call(api("C_ChatInfo.InChatMessagingLockdown"))) == true then return end
    local members = readRoster()
    if #members > 0 then
        g.members, g.at = members, time()
        guildReadAt = time()
    end
end

local guildBank = { open = false, read = {} } -- the guild bank while it is open
local GOLD_LOG = 9          -- the gold log, kept beside the tabs' logs (the game numbers it one past the last tab)

local function guildBankEnabled()
    local enabled = api("C_GuildBank.IsGuildBankEnabled")
    return not enabled or plain(call(enabled)) ~= false
end

local function readGuildBankTab(tab)
    local slots = {}
    for slot = 1, BANK_SLOTS do
        local texture, count, _, _, quality = call(GetGuildBankItemInfo, tab, slot)
        local link = str(call(GetGuildBankItemLink, tab, slot))
        local id = itemID(link)
        if id then
            slots[slot] = { id = id, n = num(count) or 1, q = num(quality), icon = num(texture), link = link, name = link:match("|h%[(.-)%]|h") }
            rememberTooltip(id, link, TT and TT.GetGuildBankItem, tab, slot)
        end
    end
    return slots
end

-- One tab's log as the game keeps it, oldest first: who put in, took out or moved what, and
-- when. Or the gold log: deposits, withdrawals and repairs. The game says how long ago in years,
-- months, days and hours; this keeps the moment that was.
local function readBankLog(tab)
    local list, now = {}, time()
    if tab == GOLD_LOG then
        for i = 1, num(call(GetNumGuildBankMoneyTransactions)) or 0 do
            local kind, who, amount, y, mo, d, h = call(GetGuildBankMoneyTransaction, i)
            kind = str(kind)
            if kind then list[#list + 1] = { k = kind, w = str(who), m = num(amount), at = now - (offlineFor(y, mo, d, h) or 0) } end
        end
        return list
    end
    for i = 1, num(call(GetNumGuildBankTransactions, tab)) or 0 do
        local kind, who, link, count, tab1, tab2, y, mo, d, h = call(GetGuildBankTransaction, tab, i)
        kind, link = str(kind), str(link)
        if kind then
            local rec = link and itemRecord(link) or nil
            if rec and rec.id then rememberTooltip(rec.id, link, TT and TT.GetHyperlink, link) end
            list[#list + 1] = { k = kind, w = str(who), id = rec and rec.id, nm = rec and rec.name, q = rec and rec.q, ic = rec and rec.icon,
                s = link and link:match("|H(item:[%-%d:]+)|h"), n = num(count), t1 = num(tab1), t2 = num(tab2), at = now - (offlineFor(y, mo, d, h) or 0) }
        end
    end
    return list
end

-- What this character's rank may take today: stacks from each tab it may view, and gold.
local function readLimits(b)
    local count = num(call(GetNumGuildBankTabs)) or 0
    if count < 1 then return end
    local lim = { at = time(), tabs = {}, gold = num(call(GetGuildBankWithdrawMoney)) }
    for i = 1, count do
        local _, _, viewable, deposit, perDay, left = call(GetGuildBankTabInfo, i)
        if plain(viewable) == true then lim.tabs[i] = { d = plain(deposit) == true or nil, w = num(perDay), left = num(left) } end
    end
    b.limits = type(b.limits) == "table" and b.limits or {}
    b.limits[charKey] = lim
end

-- The guild master's copy of every rank's bank permissions, read from Guild Control as the game's
-- own Guild Control window reads them: which tabs each rank may view and deposit in, how many
-- stacks a day it may take from each, and its gold a day. Only the guild master sees them all,
-- and only once the bank has told the game its tabs. An open Guild Control window is left alone.
local function readRankRules()
    if plain(call(IsGuildLeader)) ~= true then return nil end
    local ranks = math.min(num(call(GuildControlGetNumRanks)) or 0, 10)
    local tabs = math.min(num(call(GetNumGuildBankTabs)) or 0, 8)
    if ranks < 1 or tabs < 1 then return nil end
    local window = GuildControlUI
    if type(window) == "table" and window.IsShown and window:IsShown() then return nil end
    local rules = { n = ranks, tabs = tabs, at = time(), names = {}, view = {}, dep = {}, wd = {}, gold = {} }
    for r = 1, ranks do
        call(GuildControlSetRank, r)
        rules.names[r] = str(call(GuildControlGetRankName, r))
        rules.gold[r] = r == 1 and -1 or num(call(GetGuildBankWithdrawGoldLimit))
        local v, d, w = {}, {}, {}
        for t = 1, tabs do
            local viewable, deposit, _, perDay = call(GetGuildBankTabPermissions, t)
            v[t] = (r == 1 or plain(viewable) == true) and "1" or "0"
            d[t] = (r == 1 or plain(deposit) == true) and "1" or "0"
            w[t] = r == 1 and -1 or num(perDay)
        end
        rules.view[r], rules.dep[r], rules.wd[r] = table.concat(v), table.concat(d), w
    end
    return rules
end

-- Which tabs this character may view, the tabs' names and icons, the money, and the contents of
-- one tab the game has just sent.
local function readGuildBank(tab)
    local g = guildRecord(true)
    if not g then return end
    g.bank = type(g.bank) == "table" and g.bank or {}
    local b = g.bank
    b.tabs = type(b.tabs) == "table" and b.tabs or {}
    local count = num(call(GetNumGuildBankTabs)) or 0
    if count > 0 then
        local view = { at = time(), tabs = {} }
        for i = 1, count do
            local name, icon, viewable = call(GetGuildBankTabInfo, i)
            view.tabs[i] = plain(viewable) == true
            if view.tabs[i] then
                local t = type(b.tabs[i]) == "table" and b.tabs[i] or {}
                t.name, t.icon = str(name) or t.name, num(icon) or t.icon
                b.tabs[i] = t
            end
        end
        g.view = type(g.view) == "table" and g.view or {}
        g.view[charKey] = view
        b.count = count
        if tab and view.tabs[tab] then
            local t = b.tabs[tab]
            t.slots, t.at, t.by = readGuildBankTab(tab), time(), char.name
        end
        readLimits(b)
        if not tab then
            local rules = readRankRules()
            if rules then
                g.rules = rules
                if ns.onRankRules then ns.onRankRules(g) end
            end
        end
    end
    local money = num(call(GetGuildBankMoney))
    if money then b.money, b.moneyAt = money, time() end
end

-- After the tabs, each tab's log, the gold log and each tab's note, asked for one at a time as
-- the bank's own Log, Money Log and Tab Info pages ask, and read when the game sends them.
local function recordSteps()
    local steps, notes = {}, {}
    for i = 1, num(call(GetNumGuildBankTabs)) or 0 do
        local _, _, viewable = call(GetGuildBankTabInfo, i)
        if plain(viewable) == true then
            steps[#steps + 1] = { kind = "log", tab = i }
            notes[#notes + 1] = { kind = "note", tab = i }
        end
    end
    if #steps > 0 then steps[#steps + 1] = { kind = "log", tab = GOLD_LOG } end
    for _, n in ipairs(notes) do steps[#steps + 1] = n end
    return steps
end

local function recordNext()
    if not guildBank.open or guildBank.asking or guildBank.step then return end
    local step = guildBank.steps and table.remove(guildBank.steps, 1)
    if not step then return end
    guildBank.step = step
    if step.kind == "log" then
        call(QueryGuildBankLog, step.tab == GOLD_LOG and (MAX_GUILDBANK_TABS or 8) + 1 or step.tab)
    else
        call(QueryGuildBankText, step.tab)
    end
    -- No answer within a few seconds: leave that record as it was and go on.
    if C_Timer then C_Timer.After(3, function() if guildBank.step == step then guildBank.step = nil recordNext() end end) end
end

local function recordArrived(kind, tab)
    local step = guildBank.step
    if not (guildBank.open and db and step and step.kind == kind and (tab == nil or tab == step.tab)) then return end
    guildBank.step = nil
    local g = guildRecord(true)
    if g then
        g.bank = type(g.bank) == "table" and g.bank or {}
        local b = g.bank
        if kind == "log" then
            b.logs = type(b.logs) == "table" and b.logs or {}
            b.logs[step.tab] = { at = time(), by = char.name, list = readBankLog(step.tab) }
        else
            b.notes = type(b.notes) == "table" and b.notes or {}
            b.notes[step.tab] = { at = time(), by = char.name, text = str(call(GetGuildBankText, step.tab)) }
        end
    end
    if C_Timer then C_Timer.After(0.3, recordNext) else recordNext() end
end

-- Asks the game for the next tab this character may view that hasn't been read this visit; once
-- every tab is read, the logs and notes.
local function guildBankNext()
    if not guildBank.open or guildBank.asking then return end
    for i = 1, num(call(GetNumGuildBankTabs)) or 0 do
        local _, _, viewable = call(GetGuildBankTabInfo, i)
        if plain(viewable) == true and not guildBank.read[i] then
            guildBank.asking = i
            call(QueryGuildBankTab, i)
            -- No answer within a few seconds: leave that tab as it was and go on.
            if C_Timer then C_Timer.After(3, function() if guildBank.open and guildBank.asking == i then guildBank.read[i] = true guildBank.asking = nil guildBankNext() end end) end
            return
        end
    end
    guildBank.asking = nil
    if not guildBank.steps then
        guildBank.steps = recordSteps()
        recordNext()
    end
end

local function guildBankChanged()
    if not (guildBank.open and db) then return end
    local asked = guildBank.asking
    local current = num(call(GetCurrentGuildBankTab))
    if asked then
        readGuildBank(asked)
        guildBank.read[asked] = true
        guildBank.asking = nil
    end
    if current and current ~= asked and guildBank.read[current] then readGuildBank(current) end -- a change the player made
    if C_Timer then C_Timer.After(0.5, guildBankNext) else guildBankNext() end
end

local function guildBankOpened()
    if guildBank.open or not (loggedIn and db) or not guildBankEnabled() or not str(call(GetGuildInfo, "player")) then return end
    guildBank.open, guildBank.read, guildBank.asking, guildBank.steps, guildBank.step = true, {}, nil, nil, nil
    readGuildBank(nil)
    guildBankNext()
end

local function guildBankClosed()
    if not guildBank.open then return end
    guildBank.open, guildBank.asking, guildBank.steps, guildBank.step = false, nil, nil, nil
    if ns.onGuildBankRead then ns.onGuildBankRead() end
end

---------------------------------------------------------------------------
-- Played time, without printing it in chat
---------------------------------------------------------------------------
local muted = {}
local function muteChat()
    for i = 1, NUM_CHAT_WINDOWS or 10 do
        local f = _G["ChatFrame" .. i]
        if f and f.IsEventRegistered and f:IsEventRegistered("TIME_PLAYED_MSG") then
            f:UnregisterEvent("TIME_PLAYED_MSG")
            muted[#muted + 1] = f
        end
    end
end
local function unmuteChat()
    for i = #muted, 1, -1 do
        muted[i]:RegisterEvent("TIME_PLAYED_MSG")
        muted[i] = nil
    end
end

on("TIME_PLAYED_MSG", function(total, level)
    if char and num(total) then
        char.played, char.playedLevel, char.playedAt = num(total), num(level), time()
    end
    if #muted > 0 and C_Timer then C_Timer.After(1, unmuteChat) end
end)

---------------------------------------------------------------------------
-- Scheduling: each part scans on its own, after a short pause, never in combat
---------------------------------------------------------------------------
local PARTS = {
    basics = scanBasics, money = scanMoneyXP, place = scanPlace, stats = scanStats,
    gear = scanGear, bags = scanBags, bank = scanBank, talents = scanTalents, legacy = scanLegacy,
    profs = scanProfessions, reps = scanReputation, quests = scanQuests, guild = scanGuild,
}
local ORDER = { "basics", "guild", "money", "place", "stats", "gear", "bags", "bank", "talents", "legacy", "profs", "reps", "quests" }

local function runPart(name)
    local ok, result = pcall(PARTS[name])
    char.errors = char.errors or {}
    if ok then
        char.errors[name] = nil
        if next(char.errors) == nil then char.errors = nil end
    else
        char.errors[name] = tostring(result):sub(1, 240)
    end
    return ok, result
end

local function flush()
    flushQueued = false
    if not char then return end
    if inCombat() then return end -- PLAYER_REGEN_ENABLED flushes later
    local retryGear = false
    for _, name in ipairs(ORDER) do
        if dirty[name] then
            dirty[name] = nil
            local ok, result = runPart(name)
            if name == "gear" and ok and result == true then retryGear = true end
        end
    end
    char.updated = time()
    if ns.afterScan then pcall(ns.afterScan) end -- sharing notices what changed
    if ns.onOwnChanged then pcall(ns.onOwnChanged) end -- the window, when it shows this character
    -- A link that isn't ready yet is usually ready in a few seconds; give up after five
    -- tries (a link the game keeps secret would otherwise retry forever).
    if retryGear then gearRetries = gearRetries + 1 else gearRetries = 0 end
    if retryGear and gearRetries <= 5 and C_Timer then
        C_Timer.After(3, function()
            dirty.gear = true
            dirty.stats = true
            flush()
        end)
    end
end

local function mark(...)
    for i = 1, select("#", ...) do dirty[select(i, ...)] = true end
    if flushQueued or not C_Timer then return end
    flushQueued = true
    C_Timer.After(1.5, flush)
end

---------------------------------------------------------------------------
-- Start
---------------------------------------------------------------------------
-- Item tooltips are kept for items something still shows: your characters' gear, bags and bank,
-- the guild banks you see, what other players share with you, and what everyone's recipes make
-- and use.
local function pruneItems()
    local used = {}
    local function use(item) if type(item) == "table" and item.id then used[item.id] = true end end
    for _, c in pairs(db.chars) do
        for _, rec in pairs(c.gear or {}) do use(rec) end
        for _, list in ipairs({ c.bags or {}, c.bank or {} }) do
            for _, bag in ipairs(list) do
                for _, item in pairs(bag.slots or {}) do use(item) end
            end
        end
    end
    for _, g in pairs(db.guilds) do
        for _, tab in pairs(type(g.bank) == "table" and type(g.bank.tabs) == "table" and g.bank.tabs or {}) do
            for _, item in pairs(type(tab.slots) == "table" and tab.slots or {}) do use(item) end
        end
        for _, log in pairs(type(g.bank) == "table" and type(g.bank.logs) == "table" and g.bank.logs or {}) do
            for _, e in ipairs(type(log) == "table" and type(log.list) == "table" and log.list or {}) do use(e) end
        end
    end
    for _, p in pairs(db.peers) do
        for _, item in pairs(type(p.card) == "table" and type(p.card.gear) == "table" and p.card.gear or {}) do use(item) end
        local more = type(p.more) == "table" and p.more or {}
        for _, name in ipairs({ "bags", "bank" }) do
            for _, bag in ipairs(type(more[name]) == "table" and type(more[name].list) == "table" and more[name].list or {}) do
                for _, item in pairs(type(bag.s) == "table" and bag.s or {}) do use(item) end
            end
        end
    end
    -- What recipes make and use (Crafting.lua).
    if ns.itemsInUse then pcall(ns.itemsInUse, function(id) if id then used[id] = true end end, db) end
    for id in pairs(db.items) do
        if not used[id] then db.items[id] = nil end
    end
end

local function start()
    ReliquaryDB = type(ReliquaryDB) == "table" and ReliquaryDB or {}
    db = ReliquaryDB
    db.chars = db.chars or {}
    db.items = db.items or {}
    db.settings = type(db.settings) == "table" and db.settings or {}
    db.guilds = type(db.guilds) == "table" and db.guilds or {}
    db.peers = type(db.peers) == "table" and db.peers or {}
    if (num(db.schema) or 1) < 2 then
        -- Before sharing existed, every recorded character was on its owner's public page, all of
        -- it, so they stay public and show every part. Guild and friends start off for them.
        for _, c in pairs(db.chars) do
            if type(c) == "table" and type(c.share) ~= "table" then
                local parts = {}
                for _, part in ipairs(ns.PARTS) do parts[part] = "gfp" end
                c.share = { guild = false, friends = false, public = true, at = time(), parts = parts }
            end
        end
        if next(db.chars) then db.settings.sharingNews = true end
    end
    if db.schema == nil and not next(db.chars) then
        -- A new install: guildmates get your auction scans and notes of where items come from, as
        -- they get the rest of what you share. One that had Reliquary before keeps its choice.
        db.settings.sharePrices = true
    elseif (num(db.schema) or 1) < 3 then
        -- Characters from 1.7.0 or earlier keep showing what they showed: each part nobody chose for
        -- is written down as it was, so the new defaults reach new characters only.
        for _, c in pairs(db.chars) do
            if type(c) == "table" and type(c.share) == "table" then
                c.share.parts = type(c.share.parts) == "table" and c.share.parts or {}
                for _, part in ipairs(ns.PARTS) do
                    if type(c.share.parts[part]) ~= "string" then c.share.parts[part] = PART_DEFAULT_BEFORE[part] or "" end
                end
            end
        end
    end
    db.schema = SCHEMA
    local given, second = call(UnitName, "player")
    local name = str(given) or "Unknown"
    local realm = str(call(GetRealmName)) or "Unknown"
    -- Each of your characters is kept under its full name where the game gives names as "Given
    -- Family" (unique in the region, so two of yours with the same given name on one realm stay
    -- apart), else under its name, which the realm keeps unique; and the realm.
    local family = regionalNames() and str(second) or nil
    charKey = (family and (name .. " " .. family) or name) .. "-" .. realm
    local oldKey = name .. "-" .. realm
    if charKey ~= oldKey and type(db.chars[charKey]) ~= "table" and type(db.chars[oldKey]) == "table" then
        -- Kept before by name and realm: this character's record, unless what it recorded says it
        -- is another of yours with the same given name (its family name, class or race).
        local old = db.chars[oldKey]
        local _, raceFile = call(UnitRace, "player")
        local _, classFile = call(UnitClass, "player")
        local function agrees(saved, now) return saved == nil or str(now) == nil or saved == str(now) end
        if agrees(old.surname, family) and agrees(old.classFile, classFile) and agrees(old.raceFile, raceFile) then
            db.chars[charKey], db.chars[oldKey] = old, nil
            old.was = type(old.was) == "table" and old.was or {}
            old.was[#old.was + 1] = oldKey -- the dashboard keeps its photos and chosen portrait under it
            -- Its guilds know it by key too: which of yours is in each, which bank tabs it may view,
            -- and what it may take.
            for _, g in pairs(db.guilds) do
                if type(g) == "table" then
                    local b = type(g.bank) == "table" and g.bank or {}
                    for _, list in pairs({ mine = g.mine, view = g.view, limits = b.limits }) do
                        if type(list) == "table" and list[oldKey] ~= nil then list[charKey], list[oldKey] = list[oldKey], nil end
                    end
                end
            end
        end
    end
    db.chars[charKey] = db.chars[charKey] or {}
    char = db.chars[charKey]
    char.key = charKey
    if type(char.share) ~= "table" then
        -- A new character shares everything with its guild and friends, and nothing with anyone else.
        local parts = {}
        for _, part in ipairs(ns.PARTS) do parts[part] = ns.PART_DEFAULT[part] or "" end
        char.share = { guild = true, friends = true, public = false, at = time(), parts = parts }
        char.shareNews = true -- Share.lua says so in chat once, after login
    end
    local version, build, _, iface = call(GetBuildInfo)
    db.meta = { addon = VERSION, client = str(version), build = str(build), interface = num(iface), account = nil,
        names = regionalNames() and "regional" or nil } -- how players are named: "Given Family", or Name-Realm
    pruneItems()
    ns.db, ns.char, ns.charKey = db, char, charKey
end

on("PLAYER_LOGIN", function()
    start()
    loggedIn = true
    call(api("C_GuildInfo.GuildRoster")) -- ask the server for the guild list; GUILD_ROSTER_UPDATE follows
    mark("basics", "guild", "money", "place", "stats", "gear", "bags", "talents", "legacy", "profs", "reps", "quests")
    if RequestTimePlayed and C_Timer then
        C_Timer.After(4, function()
            muteChat()
            RequestTimePlayed()
            C_Timer.After(10, unmuteChat) -- in case no answer comes
        end)
    end
end)

on("PLAYER_ENTERING_WORLD", function() if loggedIn then mark("basics", "money", "place", "gear", "stats") end end)
on("PLAYER_REGEN_ENABLED", function() if loggedIn and next(dirty) then mark("money") end end)

for event, parts in pairs({
    PLAYER_MONEY = { "money" },
    PLAYER_XP_UPDATE = { "money" },
    UPDATE_EXHAUSTION = { "money" },
    PLAYER_UPDATE_RESTING = { "money" },
    PLAYER_LEVEL_UP = { "basics", "money", "stats", "talents" },
    ZONE_CHANGED_NEW_AREA = { "place" },
    ZONE_CHANGED = { "place" },
    ZONE_CHANGED_INDOORS = { "place" },
    HEARTHSTONE_BOUND = { "basics" },
    PLAYER_GUILD_UPDATE = { "basics", "guild" },
    GUILD_ROSTER_UPDATE = { "basics", "guild" },
    KNOWN_TITLES_UPDATE = { "basics" },
    PLAYER_EQUIPMENT_CHANGED = { "gear", "stats" },
    UNIT_INVENTORY_CHANGED = { "gear" },
    UPDATE_INVENTORY_DURABILITY = { "gear" },
    BAG_UPDATE_DELAYED = { "bags" },
    BAG_CONTAINER_UPDATE = { "bags", "gear" },
    UNIT_STATS = { "stats" },
    UNIT_RESISTANCES = { "stats" },
    UNIT_ATTACK_POWER = { "stats" },
    TRAIT_CONFIG_UPDATED = { "talents", "legacy", "stats" },
    TRAIT_TREE_CURRENCY_INFO_UPDATED = { "talents", "legacy" },
    CHARACTER_POINTS_CHANGED = { "talents" },
    SKILL_LINES_CHANGED = { "profs" },
    TRADE_SKILL_LIST_UPDATE = { "profs" },
    UPDATE_FACTION = { "reps" },
    QUEST_LOG_UPDATE = { "quests" },
    QUEST_TURNED_IN = { "quests", "money" },
}) do
    on(event, function(unit)
        if not loggedIn then return end
        if (event == "UNIT_INVENTORY_CHANGED" or event == "UNIT_STATS" or event == "UNIT_RESISTANCES"
            or event == "UNIT_ATTACK_POWER") and unit ~= "player" then return end
        mark(unpack(parts))
    end)
end

-- The bank can only be read while it is open.
local function bankOpened() bankOpen = true mark("bank") end
local function bankClosed() bankOpen = false end
on("BANKFRAME_OPENED", bankOpened)
on("BANKFRAME_CLOSED", bankClosed)
on("PLAYERBANKSLOTS_CHANGED", function() if bankOpen then mark("bank") end end)
on("BAG_UPDATE", function(bag)
    if not bankOpen then return end
    for _, b in ipairs(BANK) do if b == bag then mark("bank") return end end
end)
local Banker = api("Enum.PlayerInteractionType.Banker")
if Banker then
    on("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", function(kind) if kind == Banker then bankOpened() end end)
    on("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", function(kind) if kind == Banker then bankClosed() end end)
end

-- The guild bank, likewise only while it is open.
local GuildBanker = api("Enum.PlayerInteractionType.GuildBanker")
if GuildBanker then
    on("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", function(kind) if kind == GuildBanker then guildBankOpened() end end)
    on("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", function(kind) if kind == GuildBanker then guildBankClosed() end end)
end
on("GUILDBANKFRAME_OPENED", function() guildBankOpened() end)
on("GUILDBANKFRAME_CLOSED", function() guildBankClosed() end)
local bankChangeQueued = false
on("GUILDBANKBAGSLOTS_CHANGED", function()
    -- The game sends a tab in one burst of these: read it once the burst is over.
    if bankChangeQueued or not C_Timer then return end
    bankChangeQueued = true
    C_Timer.After(0.2, function() bankChangeQueued = false guildBankChanged() end)
end)
on("GUILDBANK_UPDATE_TABS", function() if guildBank.open then readGuildBank(nil) end end)
on("GUILDBANK_UPDATE_MONEY", function() if guildBank.open then readGuildBank(nil) end end)
on("GUILDBANKLOG_UPDATE", function() recordArrived("log") end)
on("GUILDBANK_UPDATE_TEXT", function(tab) recordArrived("note", num(tab)) end)

-- Last word before the game writes the file. Only cheap, safe reads: by now the game
-- reports some values as zero (handled in scanMoneyXP).
on("PLAYER_LOGOUT", function()
    if not char then return end
    pcall(scanMoneyXP)
    pcall(scanPlace)
    if char.played and char.playedAt then
        local now = time()
        char.played = char.played + (now - char.playedAt)
        if char.playedLevel then char.playedLevel = char.playedLevel + (now - char.playedAt) end
        char.playedAt = now
    end
    char.updated = time()
    db.meta.savedAt = time()
end)

---------------------------------------------------------------------------
-- Photos
---------------------------------------------------------------------------
-- Reliquary takes her photo by itself (unless "/rq auto" turns that off):
--   place     the first time she stands somewhere new, once she has been still a moment
--   levelup   each new level, once the fight is over and she is still
--   portrait  once a session, a close portrait while she rests at an inn or in a city
-- and on request: "/rq photo" exactly as the camera is now, "/rq portrait" framed.
--
-- An automatic photo waits until she is in her own shape, standing still, out of combat, not
-- mounted or on a flight, not casting, not talking to anyone, and you are not typing or turning
-- the camera. Framing swings the camera round to face her and zooms in; the interface hides
-- for the picture. Then the camera, the interface and every setting go back as they were,
-- about a second in all. Nothing here presses a key, moves her or acts in the game.
--
-- The game names each screenshot WoWScrnShot_MMDDYY_HHMMSS from its own clock, which is the
-- clock date() reads, so the dashboard matches a note to its file by that stamp.
local MAX_PHOTOS = 300
local SHOTS = {                 -- camera distance in yards, seconds she must be still first
    photo = { still = 0 },      -- framed by the player
    portrait = { zoom = 3.2, still = 20 },
    levelup = { zoom = 5, still = 2 },
    place = { zoom = 9, still = 6 },
    screenshot = { still = 0, ui = true }, -- the interface as it shows (/rq tour): kept showing, the camera and names as they are
}
local ORDER_OF_PHOTOS = { "levelup", "place", "portrait" } -- which goes first when several wait
local PLACE_GAP = 180           -- seconds between two place photos
local PHOTO_GAP = 8             -- seconds between any two automatic photos
local LEVELUP_STALE = 300       -- a level-up photo not taken within this long is let go
local SESSION_CAP = 25          -- automatic photos per session
-- The camera glides to a new distance, and GetCameraZoom may report where it is heading rather
-- than where it is (the first real photos, 2026-11-07, were taken before it arrived). So a framed
-- photo waits as if the camera were slow, ZOOM_SPEED yards a second, and also until
-- GetCameraZoom says it has arrived, whichever is later, up to ZOOM_WAIT.
local ZOOM_SPEED = 10
local ZOOM_WAIT = 2.5           -- longest wait for the camera to arrive
local FRAME_SETTLE = 0.5        -- at least this long after turning the camera
-- Names over heads are drawn by the world, not the interface, so they stay when it hides
-- (DialogueUI on Forever hides them the same way). Changed only out of combat.
local NAME_CVARS = {
    "UnitNameOwn", "UnitNameNonCombatCreatureName", "UnitNameFriendlyPlayerName", "UnitNameFriendlyPetName",
    "UnitNameFriendlyMinionName", "UnitNameFriendlyGuardianName", "UnitNameFriendlySpecialNPCName",
    "UnitNameEnemyPlayerName", "UnitNameEnemyPetName", "UnitNameEnemyGuardianName", "UnitNameNPC",
    "UnitNameInteractiveNPC", "UnitNameHostleNPC",
}

local photo = nil               -- the photo being taken
local touring = false           -- /rq tour is taking its pictures of the window: automatic photos wait
local afterCombat = nil         -- what a fight kept us from putting back
local wants = {}                -- automatic photos waiting for their moment, by kind: { place, at }
local stillSince = nil
local autoTaken, lastPlaceShot, lastAutoShot, portraitDone = 0, nil, nil, false

local function yes(v)
    v = plain(v)
    return v ~= nil and v ~= false
end

local function now() return num(call(GetTime)) or time() end

local function formName()
    local i = num(call(GetShapeshiftForm))
    if not i or i == 0 then return nil end
    local _, _, _, spellID = call(GetShapeshiftFormInfo, i)
    spellID = num(spellID)
    if not spellID then return nil end
    local name = C_Spell and str(call(C_Spell.GetSpellName, spellID))
    return name or str((call(GetSpellInfo, spellID)))
end

local function inOwnShape()
    local i = num(call(GetShapeshiftForm))
    return i == 0 or (i == nil and type(GetShapeshiftForm) ~= "function")
end

-- Why now is not a moment for a photo, or nil when it is. A value the game keeps secret
-- counts as busy: the camera never turns on someone who might be running.
local function busy()
    if inCombat() then return "fight" end
    local speed = num(call(GetUnitSpeed, "player"))
    local moving = plain(call(IsPlayerMoving))
    if (speed and speed > 0) or moving == true then return "moving" end
    if speed == nil and moving == nil then return "unknown" end
    if yes(call(IsMounted)) or yes(call(UnitOnTaxi, "player")) or yes(call(UnitInVehicle, "player")) then return "riding" end
    if yes(call(IsSwimming)) or yes(call(IsSubmerged)) or yes(call(IsFalling)) or yes(call(IsFlying)) then return "not on her feet" end
    if yes(call(UnitIsDeadOrGhost, "player")) then return "dead" end
    if yes(call(UnitCastingInfo, "player")) or yes(call(UnitChannelInfo, "player")) then return "casting" end
    if yes(call(IsMouselooking)) or yes(call(IsMouseButtonDown, "RightButton")) or yes(call(IsMouseButtonDown, "LeftButton")) then return "camera" end
    if yes(call(ChatEdit_GetActiveWindow)) then return "typing" end
    if yes(call(UnitExists, "npc")) then return "talking" end
    if yes(call(InCinematic)) or (MovieFrame and MovieFrame:IsShown()) then return "cinematic" end
    return nil
end

local function here()
    return str(call(GetRealZoneText)), str(call(GetSubZoneText)), str(call(GetMinimapZoneText))
end

local function standingIn(place)
    local zone, sub, spot = here()
    return place == zone or place == sub or place == spot
end

local function notePhoto(kind, cam)
    if not char then return end
    char.photos = type(char.photos) == "table" and char.photos or {}
    local zone, sub, spot = here()
    local list = char.photos
    list[#list + 1] = {
        t = time(), stamp = str(call(date, "%m%d%y_%H%M%S")), kind = kind,
        zone = zone, sub = sub ~= zone and sub or nil, spot = spot ~= sub and spot ~= zone and spot or nil,
        level = num(call(UnitLevel, "player")), form = formName(),
        cam = cam, -- how the framing went, to tune it from real photos
    }
    while #list > MAX_PHOTOS do table.remove(list, 1) end
end

-- The camera only takes steps, so a photo zooms by a known amount and undoes exactly that.
local function zoomBy(yardsIn)
    if yardsIn > 0 then call(CameraZoomIn, yardsIn) elseif yardsIn < 0 then call(CameraZoomOut, -yardsIn) end
end

-- Settings a photo changes are written down in the saved data before they change, so a crash
-- or a logout in the middle of a photo is put right at the next login.
local function changeCVar(p, name, value)
    -- A setting still waiting to go back from an earlier photo keeps its true original value.
    local pending = db.settings.restore and db.settings.restore[name]
    local old = pending or str(call(GetCVar, name))
    if not old or (old == value and not pending) then return end
    p.cvars = p.cvars or {}
    if p.cvars[name] == nil then p.cvars[name] = old end
    db.settings.restore = db.settings.restore or {}
    if db.settings.restore[name] == nil then db.settings.restore[name] = old end
    if str(call(GetCVar, name)) ~= value then call(SetCVar, name, value) end
end

local function restoreCVars(list)
    for name, value in pairs(list) do
        call(SetCVar, name, value)
        if db.settings.restore then db.settings.restore[name] = nil end
    end
    if db.settings.restore and next(db.settings.restore) == nil then db.settings.restore = nil end
end

local function setUIShown(shown)
    if type(SetUIVisibility) == "function" then
        call(SetUIVisibility, shown) -- the game's own Alt+Z: hides nameplates too
    elseif UIParent then
        call(shown and UIParent.Show or UIParent.Hide, UIParent)
    end
    if shown and C_Timer then
        -- Showing the interface from a timer leaves the druid mana bar hidden (DialogueUI does the same fix).
        C_Timer.After(0, function()
            local bar = AlternatePowerBar
            if bar and bar.isEnabled and not bar:IsShown() and not inCombat() then call(bar.Show, bar) end
        end)
    end
end

-- Puts back the camera, the settings and the interface. The camera goes back at once; the game
-- refuses settings and the interface during a fight, so then they wait for its end.
local function restore(r)
    if r.flipped then pcall(FlipCameraYaw, 180) r.flipped = nil end
    if r.zoomIn then zoomBy(-r.zoomIn) r.zoomIn = nil end
    if inCombat() then
        afterCombat = afterCombat or { cvars = {} }
        for name, value in pairs(r.cvars or {}) do
            if afterCombat.cvars[name] == nil then afterCombat.cvars[name] = value end
        end
        afterCombat.hidUI = afterCombat.hidUI or r.hidUI
        return
    end
    local cvars = r.cvars or {}
    local zoomSpeed = cvars.cameraZoomSpeed
    cvars.cameraZoomSpeed = nil
    restoreCVars(cvars)
    if zoomSpeed then
        -- The camera is still gliding back; slow it down only once it has arrived.
        local function back()
            if photo then -- another photo started meanwhile: it puts the speed back when it ends
                photo.cvars = photo.cvars or {}
                if photo.cvars.cameraZoomSpeed == nil then photo.cvars.cameraZoomSpeed = zoomSpeed end
            else
                restoreCVars({ cameraZoomSpeed = zoomSpeed })
            end
        end
        if C_Timer then C_Timer.After(ZOOM_WAIT, back) else back() end
    end
    if r.hidUI and UIParent and not UIParent:IsShown() then setUIShown(true) end
end

local PHOTO_TAKEN = "|cffe8a13aReliquary|r Photo taken: it's in the game's Screenshots folder."
local PHOTOS_TAKEN = "|cffe8a13aReliquary|r Photos taken: they're in the game's Screenshots folder."
local PHOTO_FAILED = "|cffe8a13aReliquary|r The game couldn't take that photo."
local function finishPhoto(ok)
    local p = photo
    if not p then return end
    photo = nil
    restore(p)
    if p.done then p.done(ok)
    elseif p.manual then print(ok and PHOTO_TAKEN or PHOTO_FAILED) end
end

-- Why no photo can be taken now, or nil when one can.
local function cantPhoto()
    if photo then return "a photo is already being taken" end
    if inCombat() then return "not during a fight" end
    if type(Screenshot) ~= "function" then return "this game client doesn't let addons take screenshots" end
end

-- Hides the interface, frames her if this kind of photo is framed, waits until the camera has
-- arrived and the interface is gone from the picture, takes a screenshot at full quality, then
-- puts everything back when the game reports the file written. done(ok), when given, hears how it
-- went in place of the line in chat.
local function takePhoto(kind, manual, done)
    local why = cantPhoto()
    if why then return false, why end
    local spec = SHOTS[kind] or SHOTS.photo
    local p = { kind = kind, manual = manual, done = done }
    photo = p
    changeCVar(p, "screenshotQuality", "10")
    if not spec.ui then
        for _, name in ipairs(NAME_CVARS) do changeCVar(p, name, "0") end
        if UIParent and UIParent:IsShown() then
            setUIShown(false)
            p.hidUI = not UIParent:IsShown()
        end
    end
    local target = spec.zoom
    if target and db.settings.framing ~= false and type(FlipCameraYaw) == "function" then
        local zoom0 = num(call(GetCameraZoom))
        if zoom0 then
            changeCVar(p, "cameraZoomSpeed", "50")
            p.framed = true
            -- Addons cannot read where the camera points, so put it behind her first (the game's
            -- Center Camera key), then turn it round to face her. Afterwards it is turned back,
            -- so it ends up behind her: the usual place.
            p.centered = type(CenterCamera) == "function" and pcall(CenterCamera) or nil
            if photo ~= p then return true end
            p.flipped = pcall(FlipCameraYaw, 180) or nil
            if photo ~= p then return true end -- the game refused the turn and the photo was called off
            p.zoomIn = zoom0 - target
            zoomBy(p.zoomIn)
            if photo ~= p then return true end
            p.cam = { from = round(zoom0, 2), to = target, speed = num(tonumber(str(call(GetCVar, "cameraZoomSpeed")) or "")), seen = {}, centered = p.centered }
        end
    end
    local started = now()
    local minWait = p.zoomIn and math.min(ZOOM_WAIT, FRAME_SETTLE + math.abs(p.zoomIn) / ZOOM_SPEED) or 0
    local function shoot()
        if photo ~= p then return end
        if not manual and busy() then finishPhoto(false) return end -- she moved or a fight began
        if p.cam then p.cam.at, p.cam.waited = round(num(call(GetCameraZoom)), 2), round(now() - started, 2) end
        if not pcall(Screenshot) then finishPhoto(false) return end
        -- Never leave the interface hidden: if the game never answers, put it back anyway.
        if C_Timer then C_Timer.After(5, function() if photo == p then finishPhoto(false) end end) end
    end
    local function settle()
        if photo ~= p then return end
        if not manual and busy() then finishPhoto(false) return end
        local cur = num(call(GetCameraZoom))
        local waited = now() - started
        if p.cam and #p.cam.seen < 12 and (#p.cam.seen == 0 or waited >= #p.cam.seen * 0.2) then
            p.cam.seen[#p.cam.seen + 1] = round(cur, 2) -- GetCameraZoom every 0.2 s while it glides
        end
        local arriving = p.zoomIn and cur and math.abs(cur - target) > 0.35
        if ((arriving or waited < minWait) and waited < ZOOM_WAIT) and C_Timer then
            C_Timer.After(0.05, settle)
            return
        end
        if C_Timer then C_Timer.After(0.15, shoot) else shoot() end
    end
    settle()
    return true
end

local function want(kind, place)
    if not loggedIn or db.settings.autoPhoto == false then return end
    wants[kind] = { place = place, at = now() }
end

onNewPlace = function(place) want("place", place) end

-- Twice a second: is she still, and is a photo waiting for exactly this moment?
local function tick()
    if not loggedIn or not char then return end
    if busy() then stillSince = nil return end
    local t = now()
    stillSince = stillSince or t
    if photo or touring or db.settings.autoPhoto == false or autoTaken >= SESSION_CAP then return end
    local resting = yes(call(IsResting))
    if resting and not portraitDone and not wants.portrait then want("portrait") end
    if wants.portrait and not resting then wants.portrait = nil end
    if wants.place and not standingIn(wants.place.place) then wants.place = nil end
    if wants.levelup and t - wants.levelup.at > LEVELUP_STALE then wants.levelup = nil end
    if not inOwnShape() or (lastAutoShot and t - lastAutoShot < PHOTO_GAP) then return end
    for _, kind in ipairs(ORDER_OF_PHOTOS) do
        local ready = wants[kind] and t - stillSince >= SHOTS[kind].still
            and not (kind == "place" and lastPlaceShot and t - lastPlaceShot < PLACE_GAP)
        if ready then
            wants[kind] = nil
            if takePhoto(kind) then
                autoTaken, lastAutoShot = autoTaken + 1, t
                if kind == "place" then lastPlaceShot = t end
                if kind == "portrait" then portraitDone = true end
            end
            return
        end
    end
end

on("PLAYER_LOGIN", function()
    if type(db.settings.restore) == "table" then
        if inCombat() then
            afterCombat = { cvars = {} }
            for name, value in pairs(db.settings.restore) do afterCombat.cvars[name] = value end
        else
            restoreCVars(db.settings.restore)
        end
    end
    if C_Timer and C_Timer.NewTicker then C_Timer.NewTicker(0.5, tick) end
end)
on("SCREENSHOT_SUCCEEDED", function()
    notePhoto(photo and photo.kind or "screenshot", photo and photo.cam)
    finishPhoto(true)
end)
on("SCREENSHOT_FAILED", function() finishPhoto(false) end)
on("PLAYER_REGEN_ENABLED", function()
    if afterCombat then
        local r = afterCombat
        afterCombat = nil
        restore(r)
    end
end)
-- A logout during a photo puts the settings back before the game saves them; anything a crash
-- left behind is put back at the next login.
on("PLAYER_LOGOUT", function()
    if not db then return end
    if photo then
        local p = photo
        photo = nil
        restoreCVars(p.cvars or {})
    end
    if afterCombat then restoreCVars(afterCombat.cvars or {}) afterCombat = nil end
    if type(db.settings.restore) == "table" then restoreCVars(db.settings.restore) end -- anything still waiting
end)
on("PLAYER_LEVEL_UP", function() want("levelup") end)

-- If the game ever refuses one of these calls, stop asking it, and say so on the dashboard.
local function blocked(addon, fn)
    if addon ~= ADDON or not db then return end
    fn = tostring(fn or "?")
    if fn:find("Camera") or fn:find("Zoom") then db.settings.framing = false
    else db.settings.autoPhoto = false end
    if photo then finishPhoto(false) end
    if char then
        char.errors = char.errors or {}
        char.errors.photos = "the game refused " .. fn .. (db.settings.framing == false and "; photos are no longer framed" or "; automatic photos are off")
    end
end
on("ADDON_ACTION_BLOCKED", blocked)
on("ADDON_ACTION_FORBIDDEN", blocked)

---------------------------------------------------------------------------
-- What Share.lua and the window (Viewer*.lua) use from here
---------------------------------------------------------------------------
ns.version = VERSION
ns.call, ns.num, ns.str, ns.plain, ns.round, ns.api, ns.pack = call, num, str, plain, round, api, pack

-- The game's own text colours (its font colours) as text codes, each with the same colour to fall
-- back on, for everything Reliquary colours in its window: never colours of its own.
local function colorCode(color, fallback)
    local hex = type(color) == "table" and type(color.GenerateHexColor) == "function" and color:GenerateHexColor()
    return "|c" .. (type(hex) == "string" and #hex == 8 and hex or fallback)
end
ns.colorCode = colorCode
ns.GOLD, ns.WHITE, ns.GREY = colorCode(NORMAL_FONT_COLOR, "ffffd100"), colorCode(HIGHLIGHT_FONT_COLOR, "ffffffff"), colorCode(GRAY_FONT_COLOR, "ff808080")
ns.GREEN, ns.BLUE = colorCode(GREEN_FONT_COLOR, "ff19ff19"), colorCode(LIGHTBLUE_FONT_COLOR, "ff88aaff")
ns.RED, ns.ORANGE = colorCode(RED_FONT_COLOR, "ffff1919"), colorCode(ORANGE_FONT_COLOR, "ffff7f3f")
ns.on, ns.inCombat, ns.itemID, ns.guildKey = on, inCombat, itemID, guildKey
ns.isLoggedIn = function() return loggedIn end
-- A tooltip for an item someone else shows you, read from its link, kept like your own items'.
ns.rememberLink = function(id, link)
    if db and TT and TT.GetHyperlink and type(link) == "string" then rememberTooltip(id, link, TT.GetHyperlink, link) end
end
ns.requestGuildRoster = function() call(api("C_GuildInfo.GuildRoster")) end
ns.isGuildLeader = function() return plain(call(IsGuildLeader)) == true end
-- The guild master's rank permissions, read afresh (nil for anyone else, or before the bank is known).
ns.readRankRules = function() return readRankRules() end
ns.GOLD_LOG = GOLD_LOG

---------------------------------------------------------------------------
-- /reliquary (/rq): the window, and commands
---------------------------------------------------------------------------
SLASH_RELIQUARY1 = "/reliquary"
SLASH_RELIQUARY2 = "/rq"
local TAG = "|cffe8a13aReliquary|r "
ns.TAG = TAG

local function status()
    local gear, items = 0, 0
    for _ in pairs(char.gear or {}) do gear = gear + 1 end
    for _, bag in ipairs(char.bags or {}) do for _ in pairs(bag.slots or {}) do items = items + 1 end end
    local chars = 0
    for _ in pairs(db.chars) do chars = chars + 1 end
    local talents = char.talents and #char.talents.nodes or 0
    print(format("%s%s: %d gear slots, %d bag items, %d talents, %d characters recorded.", TAG, char.name or "?", gear, items, talents, chars))
    if char.errors then
        for part, err in pairs(char.errors) do print(format("%scouldn't read %s: %s", TAG, part, err)) end
    end
    local tl = type(char.timeline) == "table" and type(char.timeline.entries) == "table" and #char.timeline.entries or 0
    if tl > 0 then print(format("%s%d timeline %s.", TAG, tl, tl == 1 and "entry" or "entries")) end
    local photos = type(char.photos) == "table" and #char.photos or 0
    print(format("%s%d %s noted. Automatic photos are %s (/rq auto). /rq portrait frames one now, /rq photo keeps your camera.",
        TAG, photos, photos == 1 and "photo" or "photos", db.settings.autoPhoto == false and "off" or "on"))
    print(TAG .. "The game saves this when you log out or type /reload.")
end

local function help()
    print(TAG .. "/rq opens the window: your guild, its bank, your friends and the players you've met.")
    print(TAG .. "/rq share: who sees this character. /rq share guild, friends or public switches one; /rq share off stops all.")
    print(TAG .. "/rq share gold public off (or bags guild on, and so on) chooses what each sees; /rq share parts lists them.")
    print(TAG .. "/rq look <name>: ask a player what they share. /rq status: what's recorded.")
    print(TAG .. "/rq photo, /rq portrait, /rq auto: photos.")
end

-- /rq tour: the window's every tab, and every page of the character played that has something on
-- it (and the page of the first item they wear), each in a screenshot of the game's own, for what a
-- render of the window can't draw (the live model, coin icons). Each is taken as a photo is (never in
-- a fight, at full quality, noted as a screenshot is) but with the interface showing, once the page's
-- movement has landed. It runs only when typed, sends no input, and puts the window back as it was;
-- the window closed by hand ends it.
local function tour()
    local V, Motion = ns.V, ns.Motion
    local why = touring and "a photo is already being taken" or cantPhoto()
    if why then print(TAG .. "No photo: " .. why .. ".") return end
    if not (V and ns.showViewer) then return end
    -- Where the window was: open or not, its tab, the character chosen and their page, the search over
    -- the list, an item's page over it.
    local frame, page = V.frame, ns.itemPage
    local was = { open = frame and frame:IsShown() and not frame.closing or false, tab = V.state.tab, pick = V.state.pick.chars }
    if page and page:IsShown() then
        was.item, was.link = page.item, page.link
        page.close()
    end
    if not ns.showViewer(V.state.tab) then return end
    frame, page = V.frame, ns.itemPage
    local chars
    for _, p in ipairs({ frame.body:GetChildren() }) do if p.browser and p.browser.key == "chars" then chars = p.browser end end
    if not chars then return end
    local d = chars.detail
    was.page, was.search = d.pageSel, chars.search:GetText() or ""
    touring = true
    -- The last of a page's movements: its bars and numbers, after the page arrives and the stagger of
    -- its rows.
    local land = Motion.enabled() and (Motion.PAGE_AFTER + Motion.delay(Motion.STAGGER_MOST) + Motion.long) or 0
    local steps, i = {}, 0
    local function finish(line)
        touring = false
        if chars.search:GetText() ~= was.search then chars.search:SetText(was.search) end
        V.state.pick.chars = was.pick
        if frame:IsShown() and not frame.closing then
            ns.showViewer(was.tab)
            if was.tab == 1 and was.page and d.pageSel ~= was.page and d:IsShown() then d.tabs.onSelect(was.page) end
            if was.item then V.openItemPage(was.item, was.link) end
            if not was.open then V.close() end
        end
        if line then print(line) end
    end
    local nextStep
    local function shoot()
        if not frame:IsShown() or frame.closing then finish() return end -- closed by hand
        local ok, refused = takePhoto("screenshot", true, function(taken) if taken then nextStep() else finish(PHOTO_FAILED) end end)
        if not ok then finish(TAG .. "No photo: " .. refused .. ".") end
    end
    -- Each step puts the window on a page, or says there was nothing to show (false).
    nextStep = function()
        i = i + 1
        if not frame:IsShown() or frame.closing then finish() return end
        if i > #steps then finish(PHOTOS_TAKEN) return end
        if steps[i]() == false then return nextStep() end
        C_Timer.After(land, shoot)
    end
    local function onPage(key) return function() if d.pageSel ~= key then d.tabs.onSelect(key) end end end
    -- Characters, on the character played: each of its pages that shows, the first item it wears, then
    -- each other tab that has something to show.
    steps[1] = function()
        if chars.search:GetText() ~= "" then chars.search:SetText("") end
        V.state.pick.chars = ns.charKey
        ns.showViewer(1)
        local first = true
        for _, b in ipairs(d.pageButtons) do
            if b:IsShown() then
                if first then onPage(b.page)() else steps[#steps + 1] = onPage(b.page) end
                first = false
            end
        end
        steps[#steps + 1] = function()
            if not d.pageButtons[1]:IsShown() then return false end
            onPage("gear")()
            for slot = 1, 19 do
                local it = d.slots[slot] and d.slots[slot].rq
                if it then V.openItemPage(it, it.link or it.s) return end
            end
            return false
        end
        for tab = 2, #frame.Tabs do
            steps[#steps + 1] = function()
                if not frame.Tabs[tab]:IsEnabled() then return false end
                page.close() -- as a click on a tab leaves an item's page
                ns.showViewer(tab)
            end
        end
    end
    nextStep()
end

SlashCmdList.RELIQUARY = function(msg)
    if not char then return end
    msg = strtrim and strtrim(msg or "") or (msg or ""):match("^%s*(.-)%s*$")
    local cmd, rest = msg:match("^(%S*)%s*(.-)$")
    cmd = (cmd or ""):lower()
    if cmd == "photo" or cmd == "portrait" then
        local ok, why = takePhoto(cmd, true)
        if not ok then print(TAG .. "No photo: " .. why .. ".") end
        return
    end
    if cmd == "auto" then
        db.settings.autoPhoto = db.settings.autoPhoto == false
        print(TAG .. (db.settings.autoPhoto and "Automatic photos are on: new places, level-ups and a portrait while you rest."
            or "Automatic photos are off. /rq photo and /rq portrait still work; /rq auto turns them back on."))
        return
    end
    if cmd == "tour" then tour() return end
    if cmd == "share" and ns.shareCommand then ns.shareCommand(rest) return end
    if cmd == "look" and ns.lookCommand then ns.lookCommand(rest) return end
    if cmd == "" and ns.toggleViewer then
        local ok, shown = pcall(ns.toggleViewer)
        if ok and shown ~= nil then return end
        if not ok then char.errors = char.errors or {} char.errors.viewer = tostring(shown):sub(1, 240) end
    end
    if cmd == "help" then help() return end
    status()
    if cmd ~= "" and cmd ~= "status" then help() end
end
