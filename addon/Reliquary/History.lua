-- Before Reliquary: what the game itself still knows about a character's past, read once, the
-- first time Reliquary runs for them. Players often add Reliquary well into the game, and the
-- timeline (Timeline.lua) only starts then; this is the record of everything before it, read the
-- way Forever's own windows read it, with nothing guessed:
--   challenges  Forever's Legacy challenges this character completed, each with its date
--               (achievements: GetCategoryList, GetAchievementInfo; earned by this character only)
--   quests      every quest completed (C_QuestLog.GetAllCompletedQuestIDs), with the game's titles
--   explored    the areas of each zone uncovered on the world map (C_MapExplorationInfo)
--   stats       the lifetime statistics of the game's Statistics window (GetStatistic)
--   pvp         lifetime honorable kills and highest rank (GetPVPLifetimeStats)
--   titles      titles earned (IsTitleKnown)
-- with the character's level and played time at that moment. The game keeps no dates for
-- anything but challenges, so nothing else is placed in time. A part the game does not answer is
-- left out and named in `missing`. Flight paths are not read: on Forever the world map's flight
-- points (C_TaxiMap.GetTaxiNodesForMap) come back for a whole continent with every one marked
-- found, internal placeholder nodes included (seen 2026-11-09 on a level 21 character). It only
-- reads: nothing here presses a key or acts in the game.
local _, ns = ...
local call, num, str, plain, api, on = ns.call, ns.num, ns.str, ns.plain, ns.api, ns.on
local ipairs, type, format, tostring, pcall, next, time = ipairs, type, string.format, tostring, pcall, next, time

local SETTLE = 5           -- seconds after login before reading (the game is still loading data)
local ZONES_PER_STEP = 3   -- zones read per frame, so a whole world never stalls one frame
local TITLES_PER_STEP = 25 -- quest titles asked of the game each second

local B                    -- this character's record (char.before)
local wanted = {}          -- completed quests whose titles are still unknown

-- Game text as plain words: no colour codes, textures, atlases or links.
local function clean(s)
    s = str(s)
    if not s then return nil end
    s = s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|T.-|t", ""):gsub("|A.-|a", ""):gsub("|H.-|h(.-)|h", "%1")
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    if s == "" then return nil end
    return s
end

-- A table from the game, or an empty one (also when the game keeps it secret).
local function list(v) v = plain(v) return type(v) == "table" and v or {} end

local function readChallenges()
    local categories = plain(call(GetCategoryList))
    if type(categories) ~= "table" then return nil, "the game has no challenge list" end
    local GetLegacyPoints = api("C_Traits.GetTraitCurrencyForAchievement")
    local legacyCurrency = num(api("Constants.LegacyConsts.LEGACY_POINTS_TRAIT_CURRENCY_ID"))
    local out, seen = {}, {}
    for _, category in ipairs(categories) do
        category = num(category)
        local group = category and clean((call(GetCategoryInfo, category)))
        for i = 1, category and num((call(GetCategoryNumAchievements, category))) or 0 do
            local id, name, points, completed, month, day, year, description, _, _, _, _, mine = call(GetAchievementInfo, category, i)
            id = num(id)
            -- Achievements earned by another character on the account are not this one's.
            if id and not seen[id] and plain(completed) == true and plain(mine) == true then
                seen[id] = true
                local y, m, d = num(year), num(month), num(day)
                out[#out + 1] = {
                    id = id, name = clean(name), group = group, description = clean(description),
                    points = legacyCurrency and num(call(GetLegacyPoints, legacyCurrency, id)) or num(points),
                    date = y and m and d and format("%04d-%02d-%02d", y < 100 and 2000 + y or y, m, d) or nil,
                }
            end
        end
    end
    table.sort(out, function(a, b)
        if (a.date or "") ~= (b.date or "") then return (a.date or "") < (b.date or "") end
        return a.id < b.id
    end)
    return out
end

local function readQuests()
    local ids = plain(call(api("C_QuestLog.GetAllCompletedQuestIDs")))
    if type(ids) ~= "table" then return nil, "the game has no list of completed quests" end
    local out = {}
    for _, id in ipairs(ids) do
        id = num(id)
        if id then out[#out + 1] = id end
    end
    table.sort(out)
    return { count = #out, ids = out, titles = {} }
end

local function readStats()
    local categories = plain(call(GetStatisticsCategoryList))
    if type(categories) ~= "table" then return nil, "the game has no statistics" end
    local out = {}
    for _, category in ipairs(categories) do
        category = num(category)
        if category then
            local name, parent = call(GetCategoryInfo, category)
            parent = num(parent)
            local group = clean(name)
            if parent and parent > 0 then group = clean((call(GetCategoryInfo, parent))) or group end
            local sub = group ~= clean(name) and clean(name) or nil
            for i = 1, num((call(GetCategoryNumAchievements, category))) or 0 do
                local quantity, skip, statID = call(GetStatistic, category, i)
                statID = num(statID)
                if statID and plain(skip) ~= true then
                    -- As Forever's Statistics window shows it: a number above zero, else nothing.
                    local q = plain(quantity)
                    local value = q ~= nil and tonumber(q) or nil
                    if value and value > 0 then
                        local _, statName = call(GetAchievementInfo, statID)
                        out[#out + 1] = { group = group, sub = sub, name = clean(statName), value = value }
                    end
                end
            end
        end
    end
    return out
end

local function readPvp()
    local kills, rank = call(GetPVPLifetimeStats)
    kills, rank = num(kills), num(rank)
    if not kills and not rank then return nil, "the game gives no lifetime PvP" end
    return { kills = kills, rank = rank }
end

local function readTitles()
    local n = num(call(GetNumTitles))
    if not n then return nil, "the game has no titles" end
    local out = {}
    for i = 1, n do
        if plain(call(IsTitleKnown, i)) == true then
            local name = clean(call(GetTitleName, i))
            if name then out[#out + 1] = name end
        end
    end
    return out
end

-- Every zone in the world: up to the top of the map tree, then every zone below it.
local function zoneMaps()
    local GetMapInfo = api("C_Map.GetMapInfo")
    local mapID = num(call(api("C_Map.GetBestMapForUnit"), "player")) or num(call(api("C_Map.GetFallbackWorldMapID")))
    if not mapID then return nil end
    local root, info, guard = mapID, call(GetMapInfo, mapID), 0
    while type(info) == "table" and num(info.parentMapID) and num(info.parentMapID) > 0 and guard < 12 do
        root = num(info.parentMapID)
        info = call(GetMapInfo, root)
        guard = guard + 1
    end
    local zones = call(api("C_Map.GetMapChildrenInfo"), root, num(api("Enum.UIMapType.Zone")) or 3, true)
    local out, seen = {}, {}
    for _, z in ipairs(list(zones)) do
        local id, name = num(z.mapID), clean(z.name)
        if id and name and not seen[id] then
            seen[id] = true
            out[#out + 1] = { mapID = id, name = name }
        end
    end
    return out
end

-- The explored areas of one zone. Each uncovered overlay of the map is sampled at nine points
-- inside it; the game answers with the explored areas there (never an unexplored one).
local function exploredIn(mapID)
    local overlays = list(call(api("C_MapExplorationInfo.GetExploredMapTextures"), mapID))
    if #overlays == 0 then return nil end
    local layer = list(call(api("C_Map.GetMapArtLayers"), mapID))[1]
    local w, h = type(layer) == "table" and num(layer.layerWidth), type(layer) == "table" and num(layer.layerHeight)
    if not w or not h or w <= 0 or h <= 0 then return nil end
    local At, AreaName = api("C_MapExplorationInfo.GetExploredAreaIDsAtPosition"), api("C_Map.GetAreaInfo")
    local areas, seenArea, seenName = {}, {}, {}
    for _, o in ipairs(overlays) do
        local ox, oy, ow, oh = num(o.offsetX), num(o.offsetY), num(o.textureWidth), num(o.textureHeight)
        if ox and oy and ow and oh then
            for gx = 1, 5, 2 do
                for gy = 1, 5, 2 do
                    local x, y = (ox + ow * gx / 6) / w, (oy + oh * gy / 6) / h
                    if x >= 0 and x <= 1 and y >= 0 and y <= 1 then
                        local at = CreateVector2D and CreateVector2D(x, y) or { x = x, y = y }
                        for _, a in ipairs(list(call(At, mapID, at))) do
                            a = num(a)
                            if a and not seenArea[a] then
                                seenArea[a] = true
                                local name = clean(call(AreaName, a))
                                if name and not seenName[name] then
                                    seenName[name] = true
                                    areas[#areas + 1] = name
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    if #areas == 0 then return nil end
    table.sort(areas)
    return areas
end

-- Quest titles the game has not loaded yet are asked for a few at a time; they arrive with
-- QUEST_DATA_LOAD_RESULT, this session or a later one.
local function askTitles()
    local q = B and B.quests
    if type(q) ~= "table" then return end
    q.titles = type(q.titles) == "table" and q.titles or {}
    local Title, Load = api("C_QuestLog.GetTitleForQuestID"), api("C_QuestLog.RequestLoadQuestByID")
    local ask = {}
    for _, id in ipairs(list(q.ids)) do
        if not q.titles[id] then
            local t = clean(call(Title, id))
            if t then
                q.titles[id] = t
            elseif Load then
                wanted[id] = true
                ask[#ask + 1] = id
            end
        end
    end
    if #ask == 0 or not C_Timer then return end
    local i = 0
    local function batch()
        for _ = 1, TITLES_PER_STEP do
            i = i + 1
            if not ask[i] then return end
            call(Load, ask[i])
        end
        C_Timer.After(1, batch)
    end
    batch()
end

on("QUEST_DATA_LOAD_RESULT", function(id, success)
    id = num(id)
    if not (id and wanted[id] and B and type(B.quests) == "table") then return end
    wanted[id] = nil
    if plain(success) == true then B.quests.titles[id] = clean(call(api("C_QuestLog.GetTitleForQuestID"), id)) end
end)

local function finish(missing)
    local c = ns.char
    -- Played time only when the game answered this session (Reliquary.lua asks at login).
    if c and num(c.played) and num(c.playedAt) and c.playedAt >= B.at - 60 then B.played = c.played end
    B.missing = next(missing) and missing or nil
    B.done = true
    askTitles()
end

local function read()
    if not B or B.done then return end
    if call(InCombatLockdown) == true then C_Timer.After(2, read) return end
    local missing = {}
    for _, p in ipairs({ { "challenges", readChallenges }, { "quests", readQuests }, { "stats", readStats },
                         { "pvp", readPvp }, { "titles", readTitles } }) do
        local ok, value, why = pcall(p[2])
        if ok and value ~= nil then B[p[1]] = value else missing[p[1]] = ok and why or tostring(value):sub(1, 200) end
    end
    local ok, zones = pcall(zoneMaps)
    zones = ok and zones or {}
    if #zones == 0 then missing.explored = "the game gives no world map" end
    local explored, i = {}, 0
    local function step()
        if not B or B.done then return end
        if call(InCombatLockdown) == true then C_Timer.After(2, step) return end
        for _ = 1, ZONES_PER_STEP do
            i = i + 1
            local z = zones[i]
            if not z then
                if #zones > 0 and #explored > 0 then B.explored = explored
                elseif #zones > 0 then missing.explored = "nothing uncovered on the world map" end
                finish(missing)
                return
            end
            local okArea, areas = pcall(exploredIn, z.mapID)
            if okArea and areas then explored[#explored + 1] = { zone = z.name, areas = areas } end
        end
        C_Timer.After(0, step)
    end
    step()
end

on("PLAYER_LOGIN", function()
    local c = ns.char
    if not c then return end
    if type(c.before) == "table" and c.before.done then
        B = c.before
        askTitles()
        return
    end
    c.before = { at = time(), level = num(call(UnitLevel, "player")) }
    B = c.before
    if C_Timer then C_Timer.After(SETTLE, read) end
end)

-- A read cut short by logging out is let go, and made again at the next login.
on("PLAYER_LOGOUT", function()
    local c = ns.char
    if c and B and not B.done and c.before == B then c.before = nil end
end)
