-- Reliquary's timeline: where each character spends their time, as the game reports it.
--
-- Play is cut into stretches, one per zone. A stretch becomes a timeline entry once the
-- character has spent 10 active minutes in that zone, or handed in a quest there. A shorter stop
-- waits and is listed on the next entry as a place passed through (or on the session's last
-- entry, when the session ends first; a session too short for any entry leaves none). Coming
-- back to the same zone within 15 minutes carries on the entry that was left, and so does
-- logging back in within 30 minutes. Each entry keeps when it began and ended, its active time
-- (time marked AFK is left out), the level at its start and end, the quests handed in and the
-- character's killing blows and the Legacy challenges completed. Entries older than 30 days
-- fold into one line per zone per day.
--
-- It only counts what the game says. Nothing here writes about the character, presses a key or
-- acts in the game. The game keeps the creature in each kill secret from addons, so kills are
-- a count of killing blows; a kill whose killer the game also keeps secret is counted apart
-- (hiddenKills) and never guessed.
local _, ns = ...
local call, num, str, plain, api, on = ns.call, ns.num, ns.str, ns.plain, ns.api, ns.on
local time, date, ipairs, type, min, max = time, date, ipairs, type, math.min, math.max
local issecretvalue = issecretvalue or function() return false end

local TICK = 30          -- seconds between looks at where the character is
local MAX_STEP = 90      -- the most one look credits (a loading screen or a stall counts no more)
local MIN_ACTIVE = 600   -- active seconds in a zone that make an entry (or a quest handed in there)
local DETOUR = 900       -- back in the same zone within this long: the same entry carries on
local RELOG = 1800       -- logged back in within this long, in the same zone: the same entry
local KEEP_DAYS = 30     -- entries older than this fold into one line per zone per day

-- char.timeline:
--   entries   oldest first: { zone, from, to, active, level, levelTo, kills, quests, challenges, passed }
--             quests = { { id, title, xp } }, challenges = { { id, name } }, passed = zone names,
--             in the order passed through
--   days      entries folded by day and zone: { date, zone, from, to, active, level, levelTo,
--             kills, quests and challenges (counts), xp }
--   pending   short stops waiting for the next entry: { zone, from, to, active, level, levelTo, kills }
--   cur       the stretch being played now, or { zone, attached = true } once it is the newest entry
--   seen      when time was last credited; atLogout: the newest entry was current at logout
--   hiddenKills  kills whose killer the game kept secret
local T
local wasAFK = false     -- AFK at the last look: the time since then is counted by this
local resume = false     -- logged back in soon enough to carry on the newest entry
local ticking = false

local function zoneNow() return str(call(GetRealZoneText)) or str(call(GetZoneText)) end
local function levelNow()
    local l = num(call(UnitLevel, "player"))
    if l and l > 0 then return l end
end
local function isAFK() return plain(call(UnitIsAFK, "player")) == true end

local function newest() return T.entries[#T.entries] end

-- Where what happens now is counted: the newest entry once the stretch belongs to it.
local function counted()
    local cur = T.cur
    if not cur then return nil end
    if cur.attached then return newest() end
    return cur
end

local function notePassed(e, zone)
    if not zone or zone == e.zone then return end
    e.passed = e.passed or {}
    for _, z in ipairs(e.passed) do if z == zone then return end end
    e.passed[#e.passed + 1] = zone
end

-- Takes stretch s into entry e: its time, kills, quests and levels, and its zone as a place
-- passed through when it was a short stop.
local function absorb(e, s, stop)
    e.from = min(e.from, s.from)
    e.to = max(e.to, s.to)
    e.active = (e.active or 0) + (s.active or 0)
    if s.kills then e.kills = (e.kills or 0) + s.kills end
    for _, key in ipairs({ "quests", "challenges" }) do
        if s[key] then
            e[key] = e[key] or {}
            for _, x in ipairs(s[key]) do e[key][#e[key] + 1] = x end
        end
    end
    if s.level then e.level = e.level and min(e.level, s.level) or s.level end
    local top = s.levelTo or s.level
    if top then e.levelTo = e.levelTo and max(e.levelTo, top) or top end
    if stop then notePassed(e, s.zone) end
end

local function takePending(e)
    for _, s in ipairs(T.pending) do absorb(e, s, true) end
    T.pending = {}
end

-- The current stretch has earned an entry: it carries on the newest one when that is the same
-- zone and recent, or starts a new one. Short stops before it go with it either way.
local function promote()
    local s, e = T.cur, newest()
    if not (e and e.zone == s.zone and s.from - e.to <= DETOUR) then
        e = { zone = s.zone, from = s.from, to = s.to, active = 0 }
        T.entries[#T.entries + 1] = e
    end
    takePending(e)
    absorb(e, s)
    T.cur = { zone = s.zone, attached = true }
end

local function qualifies(s)
    return (s.active or 0) >= MIN_ACTIVE or (s.quests ~= nil and #s.quests > 0)
end

-- Credits the time since the last look to where the character was, then notes where they are.
local function look()
    if not T then return end
    local now = time()
    local c = counted()
    if c and T.seen and now > T.seen then
        if not wasAFK then c.active = (c.active or 0) + min(now - T.seen, MAX_STEP) end
        c.to = max(c.to, now)
    end
    T.seen = now
    wasAFK = isAFK()
    local zone = zoneNow()
    if not zone then return end -- a loading screen, or a secret: the next look tries again
    local cur = T.cur
    if cur and cur.zone ~= zone then
        if not cur.attached then T.pending[#T.pending + 1] = cur end
        cur = nil
    end
    if not cur then
        local e = newest()
        if e and e.zone == zone and (resume or now - e.to <= DETOUR) then
            takePending(e)
            e.to = max(e.to, now)
            cur = { zone = zone, attached = true }
        else
            local l = levelNow()
            cur = { zone = zone, from = now, to = now, active = 0, level = l, levelTo = l }
        end
        T.cur = cur
        resume = false
    end
    if not cur.attached and qualifies(cur) then promote() end
    local l, here = levelNow(), counted()
    if l and here then
        here.level = here.level or l
        here.levelTo = here.levelTo and max(here.levelTo, l) or l
    end
    if ns.onOwnChanged then pcall(ns.onOwnChanged) end -- the window, when it shows this character
end

-- Entries older than KEEP_DAYS become one line per zone per day.
local function fold(now)
    local cutoff = now - KEEP_DAYS * 86400
    local keep, byKey = {}, {}
    for _, d in ipairs(T.days) do byKey[d.date .. "|" .. d.zone] = d end
    for _, e in ipairs(T.entries) do
        if e.to < cutoff then
            local day = str(call(date, "%Y-%m-%d", e.from)) or "?"
            local key = day .. "|" .. e.zone
            local d = byKey[key]
            if not d then
                d = { date = day, zone = e.zone, from = e.from, to = e.to, active = 0 }
                byKey[key] = d
                T.days[#T.days + 1] = d
            end
            d.from, d.to = min(d.from, e.from), max(d.to, e.to)
            d.active = d.active + (e.active or 0)
            if e.kills then d.kills = (d.kills or 0) + e.kills end
            for _, q in ipairs(e.quests or {}) do
                d.quests = (d.quests or 0) + 1
                if q.xp then d.xp = (d.xp or 0) + q.xp end
            end
            if e.challenges then d.challenges = (d.challenges or 0) + #e.challenges end
            if e.level then d.level = d.level and min(d.level, e.level) or e.level end
            if e.levelTo then d.levelTo = d.levelTo and max(d.levelTo, e.levelTo) or e.levelTo end
        else
            keep[#keep + 1] = e
        end
    end
    T.entries = keep
    table.sort(T.days, function(a, b) return a.from < b.from end)
end

local function list(v) return type(v) == "table" and v or {} end

on("PLAYER_LOGIN", function()
    local c = ns.char
    if not c then return end
    c.timeline = type(c.timeline) == "table" and c.timeline or {}
    T = c.timeline
    T.entries, T.days, T.pending = list(T.entries), list(T.days), list(T.pending)
    local now = time()
    if T.cur and not T.cur.attached then T.pending[#T.pending + 1] = T.cur end -- a crash mid-stretch
    T.cur = nil
    local away = T.seen and now - T.seen
    if away and away <= RELOG then
        resume = T.atLogout == true
    else
        -- A new session. Short stops that followed straight on from the last entry belong to it;
        -- any others came to less than an entry and are let go.
        local e = newest()
        for _, s in ipairs(T.pending) do
            if not e or s.from - e.to > DETOUR then break end
            absorb(e, s, true)
        end
        T.pending = {}
    end
    T.atLogout, T.seen, wasAFK = nil, nil, false
    fold(now)
    look()
    if not ticking and C_Timer then
        ticking = true
        if C_Timer.NewTicker then
            C_Timer.NewTicker(TICK, look)
        else
            local function again() look() C_Timer.After(TICK, again) end
            C_Timer.After(TICK, again)
        end
    end
end)

on("PLAYER_ENTERING_WORLD", look)
on("ZONE_CHANGED_NEW_AREA", look)
on("PLAYER_FLAGS_CHANGED", function(unit) if unit == "player" then look() end end)

on("PLAYER_LEVEL_UP", function(level)
    if not T then return end
    look()
    local here, l = counted(), num(level)
    if here and l then here.levelTo = here.levelTo and max(here.levelTo, l) or l end
end)

-- A quest's title from the quest log as it was before the hand-in, else from the game.
local function questTitle(id)
    for _, q in ipairs(list(ns.char and ns.char.quests)) do
        if q.id == id and q.title then return q.title end
    end
    return str(call(api("C_QuestLog.GetTitleForQuestID"), id))
end

on("QUEST_TURNED_IN", function(questID, xp)
    if not T then return end
    look()
    local here = counted()
    if not here then return end
    local id = num(questID)
    local gained = num(xp)
    here.quests = here.quests or {}
    here.quests[#here.quests + 1] = { id = id, title = id and questTitle(id), xp = gained and gained > 0 and gained or nil }
    if not T.cur.attached then promote() end
end)

-- A Legacy challenge (an achievement on Forever) completed by this character.
on("ACHIEVEMENT_EARNED", function(id, alreadyEarned)
    if not T or plain(alreadyEarned) == true then return end
    id = num(id)
    if not id then return end
    look()
    local here = counted()
    if not here then return end
    local _, name = call(GetAchievementInfo, id)
    here.challenges = here.challenges or {}
    here.challenges[#here.challenges + 1] = { id = id, name = str(name) }
end)

-- PARTY_KILL fires for each kill by the character or their group. Only the character's own
-- killing blows, or their pet's, count.
on("PARTY_KILL", function(attacker)
    if not T then return end
    if issecretvalue(attacker) then
        T.hiddenKills = (T.hiddenKills or 0) + 1
        return
    end
    if attacker == nil then return end
    if attacker ~= plain(call(UnitGUID, "player")) and attacker ~= plain(call(UnitGUID, "pet")) then return end
    if not T.cur then look() end
    local here = counted()
    if here then here.kills = (here.kills or 0) + 1 end
end)

on("PLAYER_LOGOUT", function()
    if not T then return end
    look()
    local cur = T.cur
    if cur and not cur.attached then T.pending[#T.pending + 1] = cur end
    T.atLogout = cur ~= nil and cur.attached == true or nil
    T.cur = nil
end)
