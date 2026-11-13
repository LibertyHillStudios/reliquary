-- Plays Timeline.lua through several sessions of simulated travel and checks every entry it
-- keeps: stretches and their threshold, short stops, detours, AFK time, quests, killing blows,
-- logging back in soon or late, a stalled client, folding after 30 days and a client that keeps
-- everything secret. Each session loads the file afresh, as the game does at each login.
-- Usage: lua5.1 tests/timeline.lua addon/Reliquary/Timeline.lua
local path = assert(arg[1], "usage: timeline.lua <Timeline.lua>")

-- GUIDs are tables here so that, as in the game, comparing a secret value with anything fails.
local GUID = {}
GUID.__eq = function(a, b)
    if rawequal(a, GUID.secret) or rawequal(b, GUID.secret) then error("compared a secret value", 2) end
    return rawequal(a, b)
end
GUID.__tostring = function(g) return g.name end
local function guid(name) return setmetatable({ name = name }, GUID) end
local SECRET = guid("<secret>")
GUID.secret = SECRET
local PLAYER, PET, GROUPMATE = guid("Player-1"), guid("Pet-7"), guid("Player-2")
issecretvalue = function(v) return rawequal(v, SECRET) end
local function plain(v) if v == nil or issecretvalue(v) then return nil end return v end

local clock = os.time({ year = 2026, month = 10, day = 1, hour = 12 })
local T0 = clock
time = function() return math.floor(clock) end
date = function(fmt, t) return os.date(fmt, math.floor(t or clock)) end

local timers, handlers
C_Timer = {
    After = function(sec, fn) timers[#timers + 1] = { at = clock + sec, fn = fn } end,
    NewTicker = function(sec, fn)
        local function again() fn() C_Timer.After(sec, again) end
        C_Timer.After(sec, again)
    end,
}
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
local function minutes(m) advance(m * 60) end
local function fire(event, ...) for _, fn in ipairs(handlers[event] or {}) do fn(...) end end

local zone, level, afk, pet = "Darnassus", 20, false, true
GetRealZoneText = function() return zone end
GetZoneText = GetRealZoneText
UnitLevel = function() return level end
UnitIsAFK = function() return afk end
UnitGUID = function(u) if u == "player" then return PLAYER elseif u == "pet" and pet then return PET end end
local titles = { [202] = "Ashenvale Hunt" }
local challengeNames = { [500] = "Darkshore Explorer", [501] = "Wings of Teldrassil" }
GetAchievementInfo = function(id) return id, challengeNames[id] end
C_QuestLog = { GetTitleForQuestID = function(id) return titles[id] end }

local char = { quests = { { id = 101, title = "The Washing" } } }

local function login()
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
    fire("PLAYER_ENTERING_WORLD", true, false)
end
local function logout() fire("PLAYER_LOGOUT") timers = {} end
local function go(z) zone = z fire("ZONE_CHANGED_NEW_AREA") end
local function at(m) return T0 + m * 60 end

local function eq(got, want, what)
    if got ~= want then error(("%s: got %s, want %s"):format(what, tostring(got), tostring(want)), 2) end
end
local function names(list) return table.concat(list or {}, ",") end

---------------------------------------------------------------------------
-- Session 1: Darnassus, a detour, then on through Darkshore and Ashenvale
---------------------------------------------------------------------------
login()
minutes(12)                                    -- 10 active minutes make the entry
local tl = char.timeline
eq(#tl.entries, 1, "an entry after 10 active minutes")
fire("PARTY_KILL", PLAYER, "Creature-1")
fire("PARTY_KILL", PLAYER, "Creature-2")
fire("PARTY_KILL", PLAYER, "Creature-3")
fire("PARTY_KILL", PET, "Creature-4")       -- the pet's killing blow is hers
fire("PARTY_KILL", GROUPMATE, "Creature-5")    -- a groupmate's is not
fire("PARTY_KILL", SECRET, "Creature-6")        -- the game keeps the killer secret: counted apart
afk = true fire("PLAYER_FLAGS_CHANGED", "player")
minutes(10)                                    -- AFK: no active time
afk = false fire("PLAYER_FLAGS_CHANGED", "player")
fire("QUEST_TURNED_IN", 101, 1200, 35)
level = 21 fire("PLAYER_LEVEL_UP", 21)
minutes(2)
go("Teldrassil") minutes(4)                    -- a short stop...
go("Darnassus") minutes(3)                     -- ...and back within 15 minutes: the same entry
go("Teldrassil") minutes(2)
fire("ACHIEVEMENT_EARNED", 501, false)         -- a challenge on a short stop goes with it
go("Darkshore") minutes(12)                    -- on to a new entry
fire("ACHIEVEMENT_EARNED", 500, false)
fire("ACHIEVEMENT_EARNED", 77, true)           -- earned before (another character): not this one's
fire("PARTY_KILL", PLAYER, "Creature-7")
fire("PARTY_KILL", PLAYER, "Creature-8")
go("Ashenvale") minutes(1)
fire("QUEST_TURNED_IN", 202, 900, 0)            -- a quest makes an entry at once
eq(#tl.entries, 3, "a quest makes an entry the moment it is handed in")
minutes(2)
go("Felwood") minutes(3)                       -- logs out after a short stop
logout()

local e = tl.entries
eq(#e, 3, "entries after session 1")
eq(e[1].zone, "Darnassus", "1 zone") eq(e[1].from, at(0), "1 from") eq(e[1].to, at(31), "1 to")
eq(e[1].active, 21 * 60, "1 active: 12 + 2 + 4 + 3 minutes, not the 10 AFK")
eq(e[1].kills, 4, "1 killing blows: hers and her pet's")
eq(#e[1].quests, 1, "1 quests") eq(e[1].quests[1].title, "The Washing", "title from her quest log")
eq(e[1].quests[1].xp, 1200, "quest XP") eq(e[1].level, 20, "1 level") eq(e[1].levelTo, 21, "1 level reached")
eq(names(e[1].passed), "Teldrassil", "1 passed through")
eq(e[2].zone, "Darkshore", "2 zone") eq(e[2].from, at(31), "2 begins with the stop before it")
eq(e[2].to, at(45), "2 to") eq(e[2].active, 14 * 60, "2 active") eq(e[2].kills, 2, "2 kills")
eq(names(e[2].passed), "Teldrassil", "2 passed through") eq(e[2].quests, nil, "2 has no quests")
eq(#e[2].challenges, 2, "2 challenges") eq(e[2].challenges[1].name, "Wings of Teldrassil", "the stop's challenge first")
eq(e[2].challenges[2].id, 500, "then Darkshore's") eq(e[1].challenges, nil, "1 has no challenges")
eq(e[3].zone, "Ashenvale", "3 zone") eq(e[3].active, 3 * 60, "3 active") eq(e[3].quests[1].title, "Ashenvale Hunt", "title from the game")
eq(e[3].quests[1].xp, 900, "3 xp") eq(e[3].kills, nil, "3 has no kills")
eq(tl.hiddenKills, 1, "hidden kills")
eq(#tl.pending, 1, "the Felwood stop waits") eq(tl.pending[1].zone, "Felwood", "pending zone")
eq(tl.atLogout, nil, "logged out between entries") eq(tl.cur, nil, "no stretch kept over logout")

---------------------------------------------------------------------------
-- Session 2, 20 minutes later in Felwood: the stop before logging out joins the new entry
---------------------------------------------------------------------------
advance(20 * 60)
login()
minutes(11)
logout()
e = tl.entries
eq(#e, 4, "a Felwood entry") eq(e[4].zone, "Felwood", "4 zone") eq(e[4].from, at(48), "4 begins at the stop")
eq(e[4].active, 14 * 60, "4 active: 3 before logging out and 11 after") eq(e[4].passed, nil, "its own zone is not passed through")
eq(tl.atLogout, true, "logged out in an entry")

---------------------------------------------------------------------------
-- Session 3, 25 minutes later: the same entry carries on
---------------------------------------------------------------------------
advance(25 * 60)
login()
minutes(5)
logout()
eq(#tl.entries, 4, "logging back in within 30 minutes carries on") eq(tl.entries[4].active, 19 * 60, "4 active")

---------------------------------------------------------------------------
-- Session 4, 40 minutes later: a new entry, then a short stop at logout
---------------------------------------------------------------------------
advance(40 * 60)
local s4 = clock
login()
minutes(10)
go("Moonglade") minutes(2)
logout()
e = tl.entries
eq(#e, 5, "a new entry after 40 minutes away") eq(e[5].from, s4, "5 from") eq(e[5].active, 10 * 60, "5 active")

---------------------------------------------------------------------------
-- Session 5, two hours later: the Moonglade stop joins session 4's last entry; a stalled client
-- counts at most 90 seconds; a session too short for an entry leaves none
---------------------------------------------------------------------------
advance(2 * 3600)
zone = "Darnassus"
login()
eq(names(tl.entries[5].passed), "Moonglade", "a stop at the end of a session joins its last entry")
eq(tl.entries[5].active, 12 * 60, "5 active with the stop") eq(tl.entries[5].to, s4 + 12 * 60, "5 to")
minutes(1)
clock = clock + 600                            -- ten minutes with no look at all
fire("ZONE_CHANGED_NEW_AREA")
eq(tl.cur.active, 60 + 90, "a stall counts 90 seconds at most")
logout()
eq(#tl.entries, 5, "no entry for a short session")

---------------------------------------------------------------------------
-- Session 6, 31 days later: everything older than 30 days folds into days; session 5's stop,
-- hours after any entry, is let go
---------------------------------------------------------------------------
clock = T0 + 31 * 86400
zone = "Stormwind City"
login()
eq(#tl.pending, 0, "a stale stop is let go")
local d = tl.days
eq(#d, 4, "one line per zone per day")
eq(d[1].zone, "Darnassus", "day 1") eq(d[1].date, os.date("%Y-%m-%d", T0), "day date")
eq(d[1].active, 21 * 60, "day active") eq(d[1].kills, 4, "day kills") eq(d[1].quests, 1, "day quests")
eq(d[1].xp, 1200, "day xp") eq(d[1].level, 20, "day level") eq(d[1].levelTo, 21, "day level reached")
eq(d[2].zone, "Darkshore", "day 2") eq(d[2].challenges, 2, "day 2 challenges") eq(d[3].zone, "Ashenvale", "day 3") eq(d[3].xp, 900, "day 3 xp")
eq(d[4].zone, "Felwood", "Felwood's two entries are one line") eq(d[4].active, 31 * 60, "Felwood day active")
eq(#tl.entries, 0, "entries folded")
minutes(15)
eq(#tl.entries, 1, "a new entry today") eq(tl.entries[1].zone, "Stormwind City", "today's zone")
fire("QUEST_TURNED_IN", 303, 0, 0)              -- no title anywhere, no XP: neither is made up
local q = tl.entries[1].quests[1]
eq(q.id, 303, "quest id") eq(q.title, nil, "no title invented") eq(q.xp, nil, "no XP invented")
go("Elwynn Forest") minutes(7)                 -- 7 minutes is under the threshold
eq(#tl.entries, 1, "7 minutes make no entry") eq(tl.cur.attached, nil, "the stop is still a stretch")
logout()
-- Logging in again folds nothing twice, and the Elwynn stop joins the day's last entry.
advance(3600)
login()
eq(#tl.days, 4, "days kept") eq(#tl.entries, 1, "today kept")
eq(names(tl.entries[1].passed), "Elwynn Forest", "the stop joins the entry it followed")
logout()

---------------------------------------------------------------------------
-- Session 7: a client that keeps everything secret records nothing and stores no secret
---------------------------------------------------------------------------
local before = #tl.entries
advance(3600)
zone, level = SECRET, SECRET
login()
minutes(15)
fire("QUEST_TURNED_IN", SECRET, SECRET, SECRET)
fire("PARTY_KILL", SECRET, SECRET)
logout()
eq(#tl.entries, before, "nothing recorded from secrets") eq(tl.hiddenKills, 2, "hidden kills")
local function walk(v, where)
    assert(not issecretvalue(v), "secret stored at " .. where)
    assert(type(v) ~= "function" and type(v) ~= "userdata", "unsaveable value at " .. where)
    if type(v) == "table" then for k, x in pairs(v) do walk(k, where .. ".<key>") walk(x, where .. "." .. tostring(k)) end end
end
walk(char, "char")

io.stderr:write("timeline ok: 7 sessions: threshold, short stops, detours, AFK, quests, challenges, killing blows, relogs, a stall, folding, secrets\n")
