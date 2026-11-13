-- Plays History.lua against a small simulated world and checks the "Before Reliquary" record:
-- challenges (only this character's, with dates), completed quests and their titles as the game
-- loads them, explored areas from the map's overlays, no flight paths (Forever's map gets them wrong),
-- lifetime statistics as Forever's Statistics window shows them, PvP and titles; then that it is
-- read once, waits out a fight, is let go when logging out mid-read, stores no secret and names
-- what an old client cannot answer.
-- Usage: lua5.1 tests/history.lua addon/Reliquary/History.lua
local path = assert(arg[1], "usage: history.lua <History.lua>")

local SECRET = setmetatable({}, { __tostring = function() return "<secret>" end })
issecretvalue = function(v) return rawequal(v, SECRET) end
local function plain(v) if v == nil or issecretvalue(v) then return nil end return v end

local clock = os.time({ year = 2026, month = 11, day = 9, hour = 12 })
time = function() return math.floor(clock) end
local timers, handlers
C_Timer = { After = function(sec, fn) timers[#timers + 1] = { at = clock + sec, fn = fn } end }
local function advance(sec)
    local target = clock + sec
    while true do
        table.sort(timers, function(a, b) return a.at < b.at end)
        local t = timers[1]
        if not t or t.at > target then break end
        table.remove(timers, 1)
        if t.at > clock then clock = t.at end
        t.fn()
    end
    clock = target
end
local function fire(event, ...) for _, fn in ipairs(handlers[event] or {}) do fn(...) end end

local function eq(got, want, what)
    if got ~= want then error(("%s: got %s, want %s"):format(what, tostring(got), tostring(want)), 2) end
end
local function join(t, key)
    local out = {}
    for i, v in ipairs(t or {}) do out[i] = key and tostring(v[key]) or tostring(v) end
    return table.concat(out, ",")
end

---------------------------------------------------------------------------
-- The world
---------------------------------------------------------------------------
local combat = false
local S = function(v) return v end -- every value as the game gives it (secret in the last part)
local function world()
    InCombatLockdown = function() return combat end
    UnitLevel = function() return S(24) end
    UnitFactionGroup = function() return S("Alliance"), "Alliance" end
    -- Challenges: two categories; one earned by another character, one not yet, one listed twice.
    local categories = {
        [10] = { "Exploration", { { 900, "Explore Darkshore", 10, true, 11, 7, 26, "Explore |cffffffffDarkshore|r.", true },
                                  { 901, "Explore Ashenvale", 10, true, 11, 8, 26, "", false },
                                  { 902, "Explore Felwood", 10, false, nil, nil, nil, "", true } } },
        [11] = { "Quests", { { 903, "Hero of Auberdine", 15, true, 11, 8, 26, "", true },
                             { 900, "Explore Darkshore", 10, true, 11, 7, 26, "", true } } },
    }
    GetCategoryList = function() return S({ 10, 11 }) end
    local statCats = { [20] = { "Combat", -1 }, [21] = { "Kills", 20 } }
    GetCategoryInfo = function(id)
        if categories[id] then return S(categories[id][1]), -1 end
        if statCats[id] then return S(statCats[id][1]), statCats[id][2] end
    end
    local stats = { [20] = { { "412", false, 5001 }, { "--", false, 5002 }, { "0", false, 5003 } },
                    [21] = { { "37", false, 5004 }, { "9", true, 5005 }, { "3 |TInterface\\MoneyFrame\\UI-GoldIcon:0|t", false, 5006 } } }
    GetCategoryNumAchievements = function(id) return #((categories[id] and categories[id][2]) or stats[id] or {}) end
    local statNames = { [5001] = "Creatures killed", [5004] = "Beasts killed", [5006] = "Gold looted" }
    GetAchievementInfo = function(a, b)
        if b then
            local x = categories[a] and categories[a][2][b]
            if not x then return end
            return S(x[1]), S(x[2]), S(x[3]), S(x[4]), S(x[5]), S(x[6]), S(x[7]), S(x[8]), nil, nil, nil, nil, S(x[9])
        end
        return S(a), S(statNames[a])
    end
    GetStatisticsCategoryList = function() return S({ 20, 21 }) end
    GetStatistic = function(cat, i) local x = stats[cat][i] return S(x[1]), S(x[2]), S(x[3]) end
    Constants = { LegacyConsts = { LEGACY_POINTS_TRAIT_CURRENCY_ID = 1234 } }
    C_Traits = { GetTraitCurrencyForAchievement = function(cur, id) if cur == 1234 and id == 900 then return S(25) end end }
    GetPVPLifetimeStats = function() return S(37), S(3) end
    local titleNames = { "Private ", "Scout", " the Explorer" }
    GetNumTitles = function() return S(3) end
    IsTitleKnown = function(i) return S(i ~= 2) end
    GetTitleName = function(i) return S(titleNames[i]) end
    -- Quests: three done; one title is known now, one arrives later, one never.
    local questTitles = { [100] = "The Washing" }
    C_QuestLog = {
        GetAllCompletedQuestIDs = function() return S({ 300, 100, 200 }) end,
        GetTitleForQuestID = function(id) return S(questTitles[id]) end,
        RequestLoadQuestByID = function(id) requested[#requested + 1] = id end,
    }
    loadLater = function(id, title) questTitles[id] = title end
    -- Maps: Teldrassil and Darkshore explored, Ashenvale not.
    C_Map = {
        GetBestMapForUnit = function() return S(1438) end,
        GetMapInfo = function(id) return ({ [1438] = { parentMapID = 12 }, [12] = { parentMapID = 947 }, [947] = { parentMapID = 0 } })[id] end,
        GetMapChildrenInfo = function(id, kind, all)
            assert(id == 947 and kind == 3 and all == true, "zones from the top of the map tree")
            return { { mapID = 1438, name = S("Teldrassil") }, { mapID = 1439, name = S("Darkshore") }, { mapID = 1440, name = S("Ashenvale") } }
        end,
        GetMapArtLayers = function() return { { layerWidth = 1000, layerHeight = 600 } } end,
        GetAreaInfo = function(id) return S(({ [141] = "Dolanaar", [142] = "Shadowglen", [150] = "Auberdine", [151] = "Auberdine", [152] = "Cliffspring River" })[id]) end,
    }
    Enum = { UIMapType = { Zone = 3 }, FlightPathFaction = { Neutral = 0, Horde = 1, Alliance = 2 } }
    C_MapExplorationInfo = {
        GetExploredMapTextures = function(id)
            if id == 1438 then return { { offsetX = 100, offsetY = 100, textureWidth = 300, textureHeight = 200 } } end
            if id == 1439 then return { { offsetX = 0, offsetY = 0, textureWidth = 200, textureHeight = 200 },
                                        { offsetX = 600, offsetY = 300, textureWidth = 300, textureHeight = 300 } } end
            return {}
        end,
        GetExploredAreaIDsAtPosition = function(id, at)
            assert(at.x >= 0 and at.x <= 1 and at.y >= 0 and at.y <= 1, "a point outside the map")
            if id == 1438 then return { at.x < 0.3 and 141 or 142 } end
            if id == 1439 then return at.x < 0.5 and { 150 } or { 151, 152 } end
        end,
    }
    CreateVector2D = function(x, y) return { x = x, y = y } end
    C_TaxiMap = {
        GetTaxiNodesForMap = function(id)
            if id == 1438 then return { { nodeID = 1, name = S("Rut'theran Village"), faction = 2, isUndiscovered = false },
                                        { nodeID = 2, name = S("Zoram'gar Outpost"), faction = 1, isUndiscovered = false },
                                        { nodeID = 3, name = S("Talonbranch Glade"), faction = 0, isUndiscovered = true } } end
            if id == 1439 then return { { nodeID = 4, name = S("Auberdine"), faction = 0, isUndiscovered = false },
                                        { nodeID = 1, name = S("Rut'theran Village"), faction = 2, isUndiscovered = false } } end
            return {}
        end,
    }
end

local function login(char)
    timers, handlers = {}, {}
    local ns = {
        call = function(fn, ...) if type(fn) == "function" then return fn(...) end end,
        num = function(v) v = plain(v) if type(v) == "number" then return v end end,
        str = function(v) v = plain(v) if type(v) == "string" and v ~= "" then return v end end,
        plain = plain,
        api = function(p) local t = _G for k in p:gmatch("[^%.]+") do t = type(t) == "table" and t[k] or nil end return t end,
        on = function(e, fn) handlers[e] = handlers[e] or {} table.insert(handlers[e], fn) end,
        char = char,
    }
    assert(loadfile(path))("Reliquary", ns)
    fire("PLAYER_LOGIN")
end

---------------------------------------------------------------------------
-- A character well into the game
---------------------------------------------------------------------------
world()
requested = {}
local char = { played = 50000, playedAt = clock }
combat = true                                 -- in a fight when the read comes due: it waits
login(char)
advance(5)
eq(char.before.done, nil, "nothing read during a fight") eq(char.before.challenges, nil, "not even a part")
combat = false
advance(5)
local B = char.before
eq(B.done, true, "read once out of the fight") eq(B.level, 24, "level") eq(B.played, 50000, "played time this session")
eq(B.missing, nil, "nothing missing")
eq(join(B.challenges, "id"), "900,903", "challenges: this character's completed ones, each once, by date")
eq(B.challenges[1].date, "2026-11-07", "date") eq(B.challenges[1].points, 25, "Legacy points")
eq(B.challenges[2].points, 15, "achievement points when there are no Legacy points")
eq(B.challenges[1].description, "Explore Darkshore.", "colour codes taken out") eq(B.challenges[1].group, "Exploration", "category")
eq(B.quests.count, 3, "quests done") eq(join(B.quests.ids), "100,200,300", "quest ids")
eq(B.quests.titles[100], "The Washing", "a title known now")
eq(join(requested), "200,300", "the other titles asked of the game")
loadLater(200, "Bathed in Light")
fire("QUEST_DATA_LOAD_RESULT", 200, true)
fire("QUEST_DATA_LOAD_RESULT", 300, false)     -- the game had no data: no title invented
loadLater(999, "Someone Else's Errand")
fire("QUEST_DATA_LOAD_RESULT", 999, true)      -- someone else's request: not stored
eq(B.quests.titles[200], "Bathed in Light", "a title that arrived") eq(B.quests.titles[300], nil, "no title invented")
eq(B.quests.titles[999], nil, "only this character's quests")
eq(#B.stats, 2, "statistics the window shows (not --, 0, skipped or money text)")
eq(B.stats[1].name, "Creatures killed", "stat name") eq(B.stats[1].value, 412, "stat value") eq(B.stats[1].group, "Combat", "stat group")
eq(B.stats[2].group, "Combat", "a child category under its parent") eq(B.stats[2].sub, "Kills", "its own name")
eq(B.pvp.kills, 37, "honorable kills") eq(B.pvp.rank, 3, "highest rank")
eq(join(B.titles), "Private,the Explorer", "titles earned, trimmed")
eq(join(B.explored, "zone"), "Teldrassil,Darkshore", "zones with anything uncovered")
eq(join(B.explored[1].areas), "Dolanaar,Shadowglen", "two areas in one overlay")
eq(join(B.explored[2].areas), "Auberdine,Cliffspring River", "areas by name, each once")
eq(B.flights, nil, "no flight paths: Forever's world map marks every one found")
fire("PLAYER_LOGOUT")

-- Logging in again reads nothing again: the record is what came before Reliquary.
local at = B.at
C_QuestLog.GetAllCompletedQuestIDs = function() return { 100, 200, 300, 400 } end
requested = {}
advance(3600)
login(char)
advance(30)
eq(char.before, B, "the same record") eq(B.at, at, "taken once") eq(B.quests.count, 3, "not read again")
eq(join(requested), "300", "the missing title asked again")

---------------------------------------------------------------------------
-- Logging out before the read: nothing half-read is kept
---------------------------------------------------------------------------
local early = { played = 100, playedAt = clock - 86400 }  -- played time from yesterday's session
login(early)
advance(2)
fire("PLAYER_LOGOUT")
eq(early.before, nil, "a read cut short is let go")
login(early)
advance(10)
eq(early.before.done, true, "and made at the next login")
eq(early.before.played, nil, "played time only when the game answered this session")

---------------------------------------------------------------------------
-- Everything secret: nothing stored that the game kept secret
---------------------------------------------------------------------------
S = function() return SECRET end
world()
local hidden = {}
login(hidden)
advance(10)
local function walk(v, where)
    assert(not issecretvalue(v), "secret stored at " .. where)
    assert(type(v) ~= "function" and type(v) ~= "userdata", "unsaveable value at " .. where)
    if type(v) == "table" then for k, x in pairs(v) do walk(k, where .. ".<key>") walk(x, where .. "." .. tostring(k)) end end
end
walk(hidden, "char")
eq(hidden.before.done, true, "secrets: read")
eq(hidden.before.challenges, nil, "secrets: no challenges") eq(hidden.before.quests, nil, "secrets: no quests")
eq(hidden.before.explored, nil, "secrets: no areas") eq(hidden.before.level, nil, "secrets: no level")

---------------------------------------------------------------------------
-- An old client without any of it: every part named as missing
---------------------------------------------------------------------------
S = function(v) return v end
GetCategoryList, GetStatisticsCategoryList, GetPVPLifetimeStats, GetNumTitles = nil, nil, nil, nil
C_QuestLog, C_Map, C_MapExplorationInfo, C_TaxiMap = nil, nil, nil, nil
local old = {}
login(old)
advance(10)
local m = old.before.missing or {}
eq(old.before.done, true, "old client: read")
for _, part in ipairs({ "challenges", "quests", "stats", "pvp", "titles", "explored" }) do
    assert(m[part], "old client: " .. part .. " not named as missing")
end

io.stderr:write("history ok: challenges, quests and titles, explored areas, statistics, PvP, titles, no flight paths; once, a fight, a cut-short read, secrets, an old client\n")
