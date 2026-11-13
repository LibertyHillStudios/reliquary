-- Reliquary sharing: a character's reliquary can be seen by its guild, its friends or anyone,
-- each switched on and off separately (/rq share, the Sharing tab of /rq, or Options > AddOns >
-- Reliquary). A new character shares with its guild and friends, and not with anyone else, until
-- its player says otherwise.
--
-- What each of them sees is chosen part by part (char.share.parts, ns.PART_DEFAULT in
-- Reliquary.lua): guild and friends start with every part; switched on, public starts with gear,
-- talents, professions and the character sheet, not gold, where you are, time played, reputation,
-- quests, bags or bank. Who the character is (name, race, class, level, guild, title) goes with
-- any of them. Photos never travel. The guild bank goes to the guild only, and a guildmate keeps
-- only the tabs their own character has been shown at the bank (the game's rank permissions).
--
-- It travels as addon messages, the way other addons talk in game: on the guild's addon channel
-- to guildmates, by whisper (or Battle.net, for Battle.net friends) to friends, and to anyone
-- else only when they ask, which Reliquary does when you target a player. Messages wait out
-- fights, instances and the game's chat lockdown, and go out about one a second so they never
-- crowd other addons. What others share is kept in ReliquaryDB.peers. Nothing here presses a key
-- or acts in the game.
local ADDON, ns = ...

local call, num, str, plain, api, on, inCombat = ns.call, ns.num, ns.str, ns.plain, ns.api, ns.on, ns.inCombat
local pairs, ipairs, type, tostring, next, pcall = pairs, ipairs, type, tostring, next, pcall
local floor, min, max, format, random = math.floor, math.min, math.max, string.format, math.random
local time = time

local PREFIX = "Reliquary"
local PROTOCOL = "1"            -- first character of every message; a new wire format gets a new one
local CARD_FORMAT = 2
local CHUNK = 250               -- a message is 255 characters: 5 for the header, 250 of payload
local MAX_CHUNKS = 61           -- one base-62 digit counts the chunks
local MAX_RAW = 65536           -- the largest message once unpacked
local PARTIAL_TTL = 90          -- seconds a half-arrived message waits for the rest
local MAX_PARTIALS = 48
local SEND_RATE = 1             -- messages a second, steady (the game's own limit per addon)
local SEND_BURST = 4
local CARD_GAP = 60             -- seconds between two sends of one section to the same place
local BANK_GAP = 120            -- the same, for one guild bank tab
local ASK_TTL = 180             -- an answer is accepted this long after asking for it
local LOOK_GAP = 3              -- seconds between two players asked because you targeted them
local LOOK_MAX = 40             -- players asked that way in a session
local KEEP = { g = 30 * 86400, f = 30 * 86400, p = 14 * 86400 } -- a card nobody refreshes is forgotten
local VIEW_KEEP = 30 * 86400    -- a record of which bank tabs you may view counts this long
local MAX_PEERS = 400
local B62 = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
local SCOPE_OF = { guild = "g", friends = "f", public = "p" }
-- The parts of a reliquary a player chooses to show, and to whom (the scopes, as letters).
local PARTS = ns.PARTS -- Reliquary.lua: gear, talents, profs, stats, gold, place, played, reps, quests, bags, bank
local PART_DEFAULT = ns.PART_DEFAULT -- Reliquary.lua: what a new character shows, and to whom
local PART_NAMES = {
    gear = "Gear", talents = "Talents", profs = "Professions", stats = "Character sheet", gold = "Gold",
    place = "Where you are", played = "Time played", reps = "Reputation", quests = "Quest log", bags = "Bags", bank = "Bank",
}
local PART_WORDS = { -- what /rq share understands for each part
    gear = "gear", equipment = "gear", talents = "talents", talent = "talents", profs = "profs", professions = "profs",
    profession = "profs", stats = "stats", sheet = "stats", gold = "gold", money = "gold", place = "place", location = "place",
    where = "place", played = "played", time = "played", reps = "reps", rep = "reps", reputation = "reps", quests = "quests",
    quest = "quests", bags = "bags", bag = "bags", bank = "bank",
}
-- A reliquary travels in sections, each with its own fingerprint, so new loot resends only the
-- bags. Gold, place and time played change most, so they are announced least often.
local SECTIONS = { "core", "live", "reps", "quests", "bags", "bank" }
local SECTION_PARTS = { core = { "gear", "talents", "profs", "stats" }, live = { "gold", "place", "played" },
    reps = { "reps" }, quests = { "quests" }, bags = { "bags" }, bank = { "bank" } }
local SECTION_GAP = { core = 120, live = 600, reps = 600, quests = 300, bags = 600, bank = 600 } -- seconds between announcements
local STAT_KEYS = { "str", "agi", "sta", "int", "spi", "armor", "ap", "sp", "heal", "crit", "scrit", "dodge", "hp", "mp" }

local Result = api("Enum.SendAddonMessageResult") or {}
local SENT = Result.Success or 0
local THROTTLED = { [Result.AddonMessageThrottle or 3] = true, [Result.ChannelThrottle or 8] = true }
local LOCKDOWN = Result.AddOnMessageLockdown or 11

local function now() return num(call(GetTime)) or time() end
local function db() return ns.db end
local function peers() return ns.db.peers end

---------------------------------------------------------------------------
-- Names. On WoW: Forever a character is "Given Family", unique in the region with no realm: the
-- game's addon messages, whispers and Battle.net all use that full name, and UnitName gives the
-- family name where other clients give the realm. Elsewhere everyone is "Name-Realm", with the
-- realm written as the game does in addon messages.
---------------------------------------------------------------------------
local function regional() return plain(call(RegionalUniqueNamesEnabled)) == true end

local function normRealm(realm) return realm and (realm:gsub("[%s%-]", "")) end

local function myRealm() return normRealm(str(call(GetNormalizedRealmName)) or str(call(GetRealmName))) end

local function fullName(name)
    name = str(name)
    if not name then return nil end
    if regional() then
        -- A realm after a full name is only the realm behind it, not part of who it is; and
        -- "Given-Family" (which the game's whisper box accepts too) is the same name.
        local full = name:match("^([^%-]+ [^%-]+)%-") or name
        if not full:find(" ", 1, true) then full = full:gsub("%-", " ", 1) end
        return full
    end
    local n, r = name:match("^([^%-]+)%-(.+)$")
    if n then return n .. "-" .. normRealm(r) end
    local realm = myRealm()
    return realm and (name .. "-" .. realm) or name
end

-- A unit's name as above. The game sometimes gives Forever's full name as one value.
local function unitName(unit)
    local name, second = call(UnitName, unit)
    name, second = str(name), str(second)
    if not name then return nil end
    if regional() then
        if second and not name:find(" ", 1, true) then name = name .. " " .. second end
        return fullName(name)
    end
    return fullName(second and (name .. "-" .. second) or name)
end

local function shortName(full) return full and full:match("^([^%-]+)") or full end

local function me() return unitName("player") end

ns.fullName, ns.shortName, ns.regional = fullName, shortName, regional

---------------------------------------------------------------------------
-- What this character shares, and with whom
---------------------------------------------------------------------------
local function shares()
    local c = ns.char
    return (c and type(c.share) == "table") and c.share or {}
end
ns.shares = shares

local function isGuildmate(who)
    if not str(call(GetGuildInfo, "player")) then return false end
    local exists = api("C_GuildInfo.MemberExistsByName")
    if exists then
        if plain(call(exists, who)) == true then return true end
        if who:match("%-(.+)$") == myRealm() and plain(call(exists, shortName(who))) == true then return true end
    end
    local g = ns.db and ns.db.guilds[ns.guildKey() or ""]
    for _, m in ipairs(g and type(g.members) == "table" and g.members or {}) do
        if fullName(m.n) == who then return true end
    end
    return false
end

-- Your friends who are playing WoW: Forever now, and how to reach each: Battle.net friends through
-- Battle.net (any realm), the rest of your friends list by whisper.
local function onlineFriends()
    local out, seen = {}, {}
    local BN = api("C_BattleNet")
    if BN and BN.GetFriendNumGameAccounts and BN.GetFriendGameAccountInfo then
        for i = 1, num(call(BNGetNumFriends)) or 0 do
            for j = 1, num(call(BN.GetFriendNumGameAccounts, i)) or 0 do
                local ga = call(BN.GetFriendGameAccountInfo, i, j)
                if type(ga) == "table" and plain(ga.isOnline) == true and plain(ga.clientProgram) == (BNET_CLIENT_WOW or "WoW")
                    and (WOW_PROJECT_ID == nil or plain(ga.wowProjectID) == WOW_PROJECT_ID) and num(ga.gameAccountID) and str(ga.characterName) then
                    local who = fullName(str(ga.characterName) .. (str(ga.realmName) and ("-" .. str(ga.realmName)) or ""))
                    if who and not seen[who] then
                        seen[who] = true
                        out[#out + 1] = { who = who, route = { kind = "BN", target = ga.gameAccountID } }
                    end
                end
            end
        end
    end
    local FL = api("C_FriendList")
    if FL and FL.GetNumFriends and FL.GetFriendInfoByIndex then
        for i = 1, num(call(FL.GetNumFriends)) or 0 do
            local info = call(FL.GetFriendInfoByIndex, i)
            if type(info) == "table" and plain(info.connected) == true and str(info.name) then
                local who = fullName(info.name)
                if who and not seen[who] then
                    seen[who] = true
                    out[#out + 1] = { who = who, route = { kind = "WHISPER", target = who } }
                end
            end
        end
    end
    return out
end

-- A class's file name (DRUID) from its name in the game's language, as the friends list gives it.
local function classFileOf(name)
    name = str(name)
    if not name then return nil end
    for _, names in ipairs({ LOCALIZED_CLASS_NAMES_MALE, LOCALIZED_CLASS_NAMES_FEMALE }) do
        if type(names) == "table" then
            for file, n in pairs(names) do if n == name then return file end end
        end
    end
end

-- Everyone on your friends lists, for the window's Friends tab: the friends list, online or not,
-- each with what the list says of them; and Battle.net friends, by BattleTag, with the WoW: Forever
-- character they're playing now, if they are, or the program they're in. Notes are your own.
ns.friends = function()
    local out = {}
    local FL = api("C_FriendList")
    if FL and FL.GetNumFriends and FL.GetFriendInfoByIndex then
        for i = 1, num(call(FL.GetNumFriends)) or 0 do
            local info = call(FL.GetFriendInfoByIndex, i)
            local who = type(info) == "table" and str(info.name) and fullName(info.name)
            if who then
                local _, cls = call(GetPlayerInfoByGUID, str(info.guid))
                out[#out + 1] = { kind = "friend", key = who, n = who, lv = num(info.level), cls = str(cls) or classFileOf(info.className),
                    z = str(info.area), on = plain(info.connected) == true, note = str(info.notes) }
            end
        end
    end
    local get = api("C_BattleNet.GetFriendAccountInfo")
    for i = 1, get and num(call(BNGetNumFriends)) or 0 do
        local info = call(get, i)
        local tag = type(info) == "table" and str(info.battleTag)
        if tag then
            local ga = type(info.gameAccountInfo) == "table" and info.gameAccountInfo or {}
            local online = plain(ga.isOnline) == true
            local here = online and plain(ga.clientProgram) == (BNET_CLIENT_WOW or "WoW") and (WOW_PROJECT_ID == nil or plain(ga.wowProjectID) == WOW_PROJECT_ID)
                and str(ga.characterName)
            out[#out + 1] = { kind = "bnet", key = "bn:" .. tag, label = tag:match("^([^#]+)") or tag, on = online, note = str(info.note),
                char = here and fullName(here .. (str(ga.realmName) and ("-" .. str(ga.realmName)) or "")) or nil,
                cls = here and str(ga.classFilename) or nil, lv = here and num(ga.characterLevel) or nil, z = here and str(ga.areaName) or nil,
                client = online and str(ga.clientProgram) or nil }
        end
    end
    return out
end

local function isFriend(who)
    local FL = api("C_FriendList")
    if FL and FL.GetFriendInfo then
        -- One value, the friend or nil, however the call answers: a lookup that fails or gives nothing back is no friend.
        if type((call(FL.GetFriendInfo, who))) == "table" then return true end
        if who:match("%-(.+)$") == myRealm() and type((call(FL.GetFriendInfo, shortName(who)))) == "table" then return true end
    end
    for _, f in ipairs(onlineFriends()) do
        if f.who == who then return true end
    end
    return false
end

local function isIgnored(who)
    local ignored = api("C_FriendList.IsIgnored")
    return ignored and (plain(call(ignored, who)) == true or plain(call(ignored, shortName(who))) == true) or false
end

-- The scopes under which you would show your card to this player, as letters (g, f, p).
local function scopesFor(who, route)
    local s, out = shares(), ""
    if s.guild and isGuildmate(who) then out = out .. "g" end
    if s.friends and (route.kind == "BN" or isFriend(who)) then out = out .. "f" end
    if s.public then out = out .. "p" end
    return out
end

-- The scopes among these that are still switched on: a send waiting for its turn goes only to them.
local function allowed(letters)
    local s, out = shares(), ""
    for l in (letters or ""):gmatch("[gfp]") do
        if (l == "g" and s.guild) or (l == "f" and s.friends) or (l == "p" and s.public) then out = out .. l end
    end
    return out
end

-- Which scopes see one part of this character (its own choice, else the default).
local function partLetters(part)
    local s = shares()
    local v = type(s.parts) == "table" and s.parts[part]
    if type(v) ~= "string" then v = PART_DEFAULT[part] or "" end
    return v
end

-- Whether an audience with these scopes sees a part. "*" is you, looking at your own characters
-- on the window's Characters tab: every part of them.
local function sees(letters, part)
    if letters == "*" then return true end
    local allowed = partLetters(part)
    for l in letters:gmatch("[gfp]") do
        if allowed:find(l, 1, true) then return true end
    end
    return false
end
ns.PART_NAMES, ns.partLetters = PART_NAMES, partLetters

---------------------------------------------------------------------------
-- The card: what others see of this character
---------------------------------------------------------------------------
local function itemString(link)
    local s = type(link) == "string" and link:match("|H(item:[%-%d:]+)|h")
    return s
end

-- Forever puts a class's three talent trees side by side in one tree: a tree is a group of
-- columns with a wide gap before the next (the dashboard splits them the same way).
local function talentSummary(t)
    if type(t) ~= "table" or type(t.nodes) ~= "table" then return nil end
    local xs, seen = {}, {}
    for _, n in ipairs(t.nodes) do
        local x = type(n) == "table" and not n.hidden and num(n.x)
        if x and not seen[x] then seen[x] = true xs[#xs + 1] = x end
    end
    table.sort(xs)
    local treeOf, tree = {}, 1
    for i, x in ipairs(xs) do
        if i > 1 and x - xs[i - 1] > 1500 then tree = tree + 1 end
        treeOf[x] = min(tree, 3)
    end
    local out = { pts = { 0, 0, 0 }, n = {}, spent = num(t.spent), left = num(t.unspent) }
    for _, n in ipairs(t.nodes) do
        local r = type(n) == "table" and num(n.rank) or 0
        local tr = r > 0 and not n.hidden and treeOf[num(n.x) or false]
        if tr then
            out.pts[tr] = out.pts[tr] + r
            out.n[#out.n + 1] = { sp = num(n.spell), nm = str(n.name), ic = num(n.icon), r = r, m = num(n.max), t = tr, x = num(n.x), y = num(n.y) }
        end
    end
    return out
end

local function itemFor(it, withCount)
    if type(it) ~= "table" or not num(it.id) then return nil end
    local out = { id = it.id, s = itemString(it.link) or str(it.s), n = str(it.name), q = num(it.q), ic = num(it.icon) }
    if withCount then out.c, out.bd = num(it.n) or 1, it.bd == true or nil else out.il = num(it.ilvl) end
    return out
end

-- Bags or bank as the addon records them, as others get them.
local function containers(list)
    local out = {}
    for _, b in ipairs(type(list) == "table" and list or {}) do
        if type(b) == "table" and num(b.size) then
            local bag = { z = b.size, b = num(b.bag), it = itemFor(b.item), s = {} }
            for key, it in pairs(type(b.slots) == "table" and b.slots or {}) do
                local slot = tonumber(key)
                if slot then bag.s[slot] = itemFor(it, true) end
            end
            out[#out + 1] = bag
        end
    end
    return #out > 0 and out or nil
end

-- Each section of this character as an audience with these scopes sees it, or nil when they see
-- none of it. Who the character is goes in the core, which every audience gets.
local BUILD = {}

function BUILD.core(c, letters)
    local card = {
        f = CARD_FORMAT, name = c.name, realm = c.realm, race = c.race, raceFile = c.raceFile, class = c.class,
        classFile = c.classFile, cid = c.classID, sex = c.sex, level = c.level, faction = c.faction, guild = c.guild,
        guildRank = c.guildRank, title = c.title, ruleset = c.ruleset, addon = ns.version,
    }
    local s = type(c.stats) == "table" and c.stats or {}
    if sees(letters, "gear") then
        card.ilvl = num(s.ilvl)
        card.gear = {}
        for key, it in pairs(type(c.gear) == "table" and c.gear or {}) do
            local slot = tonumber(key)
            if slot then card.gear[slot] = itemFor(it) end
        end
    end
    if sees(letters, "stats") then
        local function total(k) return type(s[k]) == "table" and num(s[k].total) or nil end
        card.stats = {
            str = total("str"), agi = total("agi"), sta = total("sta"), int = total("int"), spi = total("spi"),
            armor = num(s.armor), ap = num(s.ap), sp = num(s.spellPower), heal = num(s.healing), crit = num(s.crit),
            scrit = num(s.spellCrit), dodge = num(s.dodge), hp = num(c.healthMax), mp = num(c.manaMax) or num(c.powerMax),
        }
    end
    if sees(letters, "profs") then
        card.profs = {}
        for _, p in ipairs(type(c.profs) == "table" and c.profs or {}) do
            if type(p) == "table" and str(p.name) then
                card.profs[#card.profs + 1] = { n = p.name, ic = num(p.icon), sk = num(p.skill), mx = num(p.max) }
            end
        end
    end
    if sees(letters, "talents") then
        card.tal = talentSummary(c.talents)
        local sp = type(c.spec) == "table" and c.spec
        if sp then card.spec = { id = sp.id, n = sp.name, r = sp.role, ps = sp.ps } end
    end
    return card
end

function BUILD.live(c, letters)
    local out = {}
    if sees(letters, "gold") then out.gold = num(c.money) end
    if sees(letters, "place") then
        out.zone, out.sub, out.map, out.x, out.y, out.hearth = str(c.zone), str(c.subzone), str(c.mapName), num(c.x), num(c.y), str(c.hearth)
    end
    if sees(letters, "played") then out.played, out.playedLevel = num(c.played), num(c.playedLevel) end
    return next(out) and out or nil
end

function BUILD.reps(c, letters)
    if not sees(letters, "reps") then return nil end
    local out = {}
    for _, r in ipairs(type(c.reps) == "table" and c.reps or {}) do
        if type(r) == "table" and str(r.name) then
            out[#out + 1] = { n = r.name, r = num(r.reaction), v = num(r.value), lo = num(r.lo), hi = num(r.hi),
                h = r.header == true or nil, w = r.war == true or nil, c = r.child == true or nil }
        end
    end
    return #out > 0 and { list = out } or nil
end

function BUILD.quests(c, letters)
    if not sees(letters, "quests") then return nil end
    local out = {}
    for _, q in ipairs(type(c.quests) == "table" and c.quests or {}) do
        if type(q) == "table" and str(q.title) then
            local rec = { t = q.title, l = num(q.level), d = q.done == true or nil, g = str(q.group) }
            for _, o in ipairs(type(q.obj) == "table" and q.obj or {}) do
                if type(o) == "table" and str(o.text) then
                    rec.o = rec.o or {}
                    rec.o[#rec.o + 1] = { t = o.text, d = o.done == true or nil }
                end
            end
            out[#out + 1] = rec
        end
    end
    return #out > 0 and { list = out } or nil
end

function BUILD.bags(c, letters)
    local list = sees(letters, "bags") and containers(c.bags)
    return list and { list = list } or nil
end

function BUILD.bank(c, letters)
    local list = sees(letters, "bank") and containers(c.bank)
    return list and { list = list, at = num(c.bankAt) } or nil
end

-- One of your own characters as the window shows it (its Characters tab): its card and the sections
-- its pages show, as a guildmate's arrive, with every part shown whatever it shares. (Its recipes the
-- window reads from the character itself, never packed for sending.)
local OWN_SECTIONS = { "live", "reps", "quests", "bags", "bank" }
ns.ownCard = function(c)
    if type(c) ~= "table" then return nil end
    local more = {}
    for _, name in ipairs(OWN_SECTIONS) do more[name] = BUILD[name](c, "*") end
    return { card = BUILD.core(c, "*"), more = more }
end

-- A short fingerprint of a table that is the same whatever order its keys were added in.
local function canon(v, out)
    local t = type(v)
    if t == "table" then
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = k end
        table.sort(keys, function(a, b)
            local ta, tb = type(a), type(b)
            if ta ~= tb then return ta < tb end
            return a < b
        end)
        out[#out + 1] = "{"
        for _, k in ipairs(keys) do
            canon(k, out)
            out[#out + 1] = "="
            canon(v[k], out)
            out[#out + 1] = ";"
        end
        out[#out + 1] = "}"
    elseif t == "string" then
        out[#out + 1] = format("%q", v)
    else
        out[#out + 1] = tostring(v)
    end
    return out
end

local function hash(v)
    local s = table.concat(canon(v, {}))
    local h = 5381
    for i = 1, #s do h = (h * 33 + s:byte(i)) % 4294967296 end
    return format("%08x", h)
end
ns.hash = hash

-- This character's sections for one audience: { [name] = { d = data, h = fingerprint } },
-- built at most every few seconds.
local sectionCache = {}
local function sectionsFor(letters)
    local c = ns.char
    if type(c) ~= "table" or not str(c.name) or letters == "" then return {} end
    local key = (ns.charKey or "") .. "|" .. letters
    local hit = sectionCache[key]
    local t = now()
    if hit and t - hit.at <= 5 then return hit.sections end
    local out = {}
    for _, name in ipairs(SECTIONS) do
        local d = BUILD[name](c, letters)
        if d then out[name] = { d = d, h = hash(d) } end
    end
    sectionCache[key] = { at = t, sections = out }
    return out
end

local function fingerprints(letters)
    local out = {}
    for name, sec in pairs(sectionsFor(letters)) do out[name] = sec.h end
    return next(out) and out or nil
end

local function forgetSections() sectionCache = {} end

---------------------------------------------------------------------------
-- The guild bank: what you hold of it, and who may see each tab. In game each rank sees the tabs
-- the guild master lets it view, and so it is here: a tab goes only to guildmates whose rank may
-- see it, by whisper (or to the whole guild when the guild master opens it to everyone), and the
-- sender checks the asker's rank in its own copy of the guild list first. The guild master's
-- settings (g.policy, sent from their own game) can open a tab wider, keep it in the game only,
-- and share the bank's records: each tab's log and note, the gold log and each rank's limits.
-- Without those settings only the game knows other ranks' permissions, so a tab goes only to
-- guildmates of the sender's rank or higher, who nearly always see what the sender sees.
---------------------------------------------------------------------------
local GOLD_LOG = ns.GOLD_LOG or 9 -- the gold log travels like a tab of its own
local RANKS_MAX = 10

local myGuild, myRank, rankOf, policyOf, tabFingerprint, canView, rankSees, iSee, theySee, iKeep, theyKeep, recordsAt, tidyBank, bankIndex
do
    function myGuild()
        local gk = ns.guildKey()
        return gk and ns.db.guilds[gk], gk
    end

    -- Your rank in your guild, 1 being the guild master (the game counts from 0).
    function myRank()
        local _, _, idx = call(GetGuildInfo, "player")
        idx = num(idx)
        return idx and idx + 1 or nil
    end

    -- A guildmate's rank in your copy of the guild list, or nil for anyone not in it.
    function rankOf(who)
        if not who then return nil end
        if who == me() then return myRank() end
        local g = myGuild()
        for _, m in ipairs(g and type(g.members) == "table" and g.members or {}) do
            if type(m) == "table" and m.n and fullName(m.n) == who then return num(m.ro) end
        end
        return nil
    end

    -- The guild master's settings, while whoever made them is still guild master in your guild list.
    function policyOf(g)
        local p = type(g) == "table" and type(g.policy) == "table" and g.policy or nil
        if not (p and p.by) or rankOf(p.by) ~= 1 then return nil end
        return p
    end

    -- A tab's contents as everyone fingerprints them: the item and count in each slot.
    local function tabHash(t)
        local plainSlots = {}
        for slot, it in pairs(type(t.slots) == "table" and t.slots or {}) do
            if type(it) == "table" and num(it.id) then plainSlots[slot] = it.id .. "x" .. (num(it.n) or 1) end
        end
        return hash(plainSlots)
    end

    function tabFingerprint(t)
        if t.hashedAt ~= t.at then t.h, t.hashedAt = tabHash(t), t.at end
        return t.h
    end

    -- Whether one of your characters in this guild has been shown this tab at the bank lately.
    function canView(g, tab)
        if type(g) ~= "table" or type(g.view) ~= "table" then return false end
        local t = time()
        for ck, v in pairs(g.view) do
            if type(v) == "table" and type(v.tabs) == "table" and v.tabs[tab] == true and t - (num(v.at) or 0) <= VIEW_KEEP
                and type(g.mine) == "table" and g.mine[ck] then
                return true
            end
        end
        return false
    end
    ns.canViewTab = canView

    -- The lowest rank (the largest number) among your characters the bank showed this tab lately.
    local function viewRank(g, tab)
        local best
        if type(g) ~= "table" or type(g.view) ~= "table" then return nil end
        local t = time()
        for ck, v in pairs(g.view) do
            local m = type(g.mine) == "table" and g.mine[ck]
            if type(v) == "table" and type(v.tabs) == "table" and v.tabs[tab] == true and t - (num(v.at) or 0) <= VIEW_KEEP
                and type(m) == "table" and num(m.ro) then
                best = max(best or 0, m.ro)
            end
        end
        return best
    end

    -- Whether a guildmate of rank `ro` sees tab `i` in Reliquary under the guild master's settings
    -- `p`: true or false, or nil when only the game knows. "As in game" uses the guild master's copy
    -- of each rank's permissions; a wider choice opens it to that rank and up, or to everyone; "game
    -- only" keeps it out of Reliquary. The gold log goes to whoever sees any tab.
    function rankSees(ro, i, p)
        if not ro then return nil end
        if i == GOLD_LOG then
            local unknown = false
            for t = 1, 8 do
                local v = rankSees(ro, t, p)
                if v then return true end
                if v == nil then unknown = true end
            end
            if unknown then return nil end
            return false
        end
        local a = p and type(p.tb) == "table" and p.tb[i] or "g"
        if a == "n" then return false end
        if ro == 1 or a == "a" or (type(a) == "number" and ro <= a) then return true end
        local row = p and type(p.v) == "table" and p.v[ro]
        if type(row) == "string" then return row:sub(i, i) == "1" end
        return nil
    end

    -- Whether any of your characters in this guild sees a tab (or the gold log) in Reliquary.
    function iSee(g, i)
        if type(g) ~= "table" then return false end
        local p, unknown = policyOf(g), false
        for _, m in pairs(type(g.mine) == "table" and g.mine or {}) do
            local v = rankSees(type(m) == "table" and num(m.ro) or nil, i, p)
            if v then return true end
            if v == nil then unknown = true end
        end
        if not unknown then return false end
        if i == GOLD_LOG then
            for t = 1, 8 do if canView(g, t) then return true end end
            return false
        end
        return canView(g, i)
    end
    ns.maySeeTab = function(g, i) return iSee(g, i) end

    -- Whether a guildmate sees a tab, as you judge before sending it to them.
    function theySee(g, who, i)
        local ro = rankOf(who)
        if not ro then return false end
        local v = rankSees(ro, i, policyOf(g))
        if v ~= nil then return v end
        local r
        if i == GOLD_LOG then
            for t = 1, 8 do local x = viewRank(g, t) if x and (not r or x > r) then r = x end end
        else
            r = viewRank(g, i)
        end
        return r ~= nil and ro <= r
    end

    -- Whether the guild master shares the bank's records, and trusts this rank to keep them.
    local function keeps(g, ro)
        local p = policyOf(g)
        return p ~= nil and p.rc == true and ro ~= nil and ro <= (num(p.kp) or 0)
    end
    function iKeep(g) return keeps(g, myRank()) end
    function theyKeep(g, who) return keeps(g, rankOf(who)) end

    -- When a tab's records (its log and note, or the gold log) were last read at the bank.
    function recordsAt(b, i)
        local log = type(b.logs) == "table" and b.logs[i]
        local note = type(b.notes) == "table" and b.notes[i]
        local at = max(type(log) == "table" and num(log.at) or 0, type(note) == "table" and num(note.at) or 0)
        return at > 0 and at or nil
    end

    -- Forgets the tabs and records none of your characters may see any longer (the guild master
    -- closed them, or the guild master changed), and notes for the dashboard which tabs your
    -- characters see and whether the game or the guild master's settings say so.
    function tidyBank(g)
        if type(g) ~= "table" or type(g.members) ~= "table" or #g.members == 0 then return end -- the guild list judges
        local b = type(g.bank) == "table" and g.bank
        if b then
            for i = 1, GOLD_LOG do
                if not iSee(g, i) then
                    if type(b.tabs) == "table" then b.tabs[i] = nil end
                    if type(b.logs) == "table" then b.logs[i] = nil end
                    if type(b.notes) == "table" then b.notes[i] = nil end
                end
            end
        end
        local see = {}
        for i = 1, 8 do
            if iSee(g, i) then see[i] = canView(g, i) and "g" or "p" end
        end
        g.see = see
    end

    function bankIndex()
        local g = myGuild()
        local b = g and type(g.bank) == "table" and g.bank
        if not b then return nil end
        local keeper = iKeep(g)
        local idx = { m = num(b.money), mt = num(b.moneyAt), n = num(b.count), t = {} }
        local any = idx.m ~= nil
        for i = 1, GOLD_LOG do
            local tab = i <= 8 and type(b.tabs) == "table" and b.tabs[i]
            local offer = {}
            if type(tab) == "table" and type(tab.slots) == "table" and num(tab.at) then offer.h, offer.at = tabFingerprint(tab), tab.at end
            if keeper then offer.ra = recordsAt(b, i) end
            if i <= 8 and ns.boardAt then offer.ba = ns.boardAt(g, i) end
            if next(offer) then
                idx.t[i] = offer
                any = true
            end
        end
        return any and idx or nil
    end
end

---------------------------------------------------------------------------
-- Packing: CBOR, Deflate and Base64, as Blizzard's own UI packs shared settings
---------------------------------------------------------------------------
local EU = api("C_EncodingUtil")
local DEFLATE = api("Enum.CompressionMethod.Deflate") or 0

local function encode(t)
    if not (EU and EU.SerializeCBOR and EU.CompressString and EU.EncodeBase64) then return nil end
    local ok, s = pcall(EU.SerializeCBOR, t)
    if not ok or type(s) ~= "string" then return nil end
    ok, s = pcall(EU.CompressString, s, DEFLATE)
    if not ok or type(s) ~= "string" then return nil end
    ok, s = pcall(EU.EncodeBase64, s)
    return ok and type(s) == "string" and s or nil
end

local function decode(s)
    if not (EU and EU.DeserializeCBOR and EU.DecompressString and EU.DecodeBase64) then return nil end
    local ok, d = pcall(EU.DecodeBase64, s)
    if not ok or type(d) ~= "string" then return nil end
    ok, d = pcall(EU.DecompressString, d, DEFLATE)
    if not ok or type(d) ~= "string" or #d > MAX_RAW then return nil end
    ok, d = pcall(EU.DeserializeCBOR, d)
    return ok and type(d) == "table" and d or nil
end

ns.canShare = function() return encode({ t = "x" }) ~= nil end

---------------------------------------------------------------------------
-- Sending: a queue that waits for quiet moments and keeps under the game's limits
---------------------------------------------------------------------------
local control, bulk = {}, {}   -- small messages first, then cards and bank tabs
local tokens, lastPump = SEND_BURST, nil
local pausedUntil = 0
local lastId = random(0, 62 * 62 - 1)

local function digit(n) return B62:sub(n + 1, n + 1) end
local function undigit(c) local i = B62:find(c, 1, true) return i and i - 1 end

local function routeKey(route) return route.kind .. ":" .. tostring(route.target or "") end

local function quiet()
    if inCombat() then return false end
    if plain(call(api("C_ChatInfo.InChatMessagingLockdown"))) == true then return false end
    if plain((call(IsInInstance))) == true then return false end
    return true
end

local function send(route, msg, urgent)
    local text = encode(msg)
    if not text then return false end
    local n = floor((#text + CHUNK - 1) / CHUNK)
    if n < 1 or n > MAX_CHUNKS then return false end
    lastId = (lastId + 1) % (62 * 62)
    local id = digit(floor(lastId / 62)) .. digit(lastId % 62)
    local list = urgent and control or bulk
    for i = 1, n do
        list[#list + 1] = { route = route, id = id, t = msg.t, n = msg.n, h = msg.h, sc = msg.sc, i = msg.i,
            text = PROTOCOL .. id .. digit(i) .. digit(n) .. text:sub((i - 1) * CHUNK + 1, i * CHUNK) }
    end
    return true
end
ns.send = send

local function dropRest(m)
    for _, list in ipairs({ control, bulk }) do
        for i = #list, 1, -1 do
            if list[i].id == m.id and routeKey(list[i].route) == routeKey(m.route) then table.remove(list, i) end
        end
    end
end

local function transmit(m)
    local r = m.route
    if r.kind == "BN" then
        local sendData = api("C_BattleNet.SendGameData")
        if sendData then return call(sendData, r.target, PREFIX, m.text) end
        if type(BNSendGameData) == "function" then return pcall(BNSendGameData, r.target, PREFIX, m.text) end -- older clients answer nothing
        return nil
    end
    return call(api("C_ChatInfo.SendAddonMessage"), PREFIX, m.text, r.kind, r.target)
end

local function pump()
    local t = now()
    tokens = min(SEND_BURST, tokens + (t - (lastPump or t)) * SEND_RATE)
    lastPump = t
    if not (control[1] or bulk[1]) or t < pausedUntil or not quiet() then return end
    while tokens >= 1 do
        local list = control[1] and control or bulk
        local m = list[1]
        if not m then return end
        table.remove(list, 1)
        local result = transmit(m)
        if result == SENT or result == true then
            tokens = tokens - 1
        elseif THROTTLED[result] or result == false then
            table.insert(list, 1, m)  -- the game wants a pause: try the same one again shortly
            tokens, pausedUntil = 0, t + 2
            return
        elseif result == LOCKDOWN then
            table.insert(list, 1, m)
            pausedUntil = t + 15
            return
        else
            dropRest(m)               -- not in a guild any more, gone offline, or refused
        end
    end
end

ns.queued = function() return #control + #bulk end
ns.quiet, ns.now, ns.me = quiet, now, me

-- Takes out of the queue every section and bank tab not shown as it was when queued: called when
-- a switch changes, so nothing hidden goes out after the hello or goodbye that says so. A section
-- whose contents are unchanged for its audience stays queued; whoever lost one asks again.
local function stillShown(m)
    if m.t == "gb" then
        if not shares().guild then return false end
        local g = myGuild()
        if not (g and m.i) then return false end
        if m.route.kind == "GUILD" then
            local p = policyOf(g)
            return m.i <= 8 and p ~= nil and type(p.tb) == "table" and p.tb[m.i] == "a"
        end
        return theySee(g, m.route.target, m.i)
    end
    if m.t == "pr" or m.t == "src" then return ns.db.settings.sharePrices == true end -- turned off while it waited
    if m.t ~= "sec" then return true end
    if allowed(m.sc) ~= m.sc then return false end
    local sec = sectionsFor(m.sc)[m.n]
    return sec ~= nil and sec.h == m.h
end

local function purgeQueued()
    for _, list in ipairs({ control, bulk }) do
        for i = #list, 1, -1 do
            if not stillShown(list[i]) then table.remove(list, i) end
        end
    end
end
ns.purgeQueued = purgeQueued

---------------------------------------------------------------------------
-- Receiving: pieces put back together, then each kind of message
---------------------------------------------------------------------------
local partials, partialCount = {}, 0
local asked = {}          -- [who] = when we asked them (for a card, or whether they share)
local askedGuild = {}     -- [who .. "|" .. section] = { h = fingerprint asked for, at = when }, on the guild channel
local othersAsked = {}    -- [who .. "|" .. section .. "|" .. fingerprint] = when another guildmate asked for it
local lastCardSent = {}   -- [route and section] = when
local lastTabSent = {}    -- [tab] = when
local wantTabs = {}       -- [tab] = { who = holder of the newest copy, at = when they saw it }
local wantTimer = false
local lastGuildHello = -math.huge
local looking = {}        -- [who] = true for /rq look, to say when their card arrives

-- The window draws again what a change touches: "peers" (another player's card or goodbye), "bank"
-- (the guild bank or its settings), or anything when it doesn't say.
local function changed(kind) if ns.onDataChanged then pcall(ns.onDataChanged, kind) end end

-- Tooltips of items others share, for the dashboard: read a few at a time, never in a fight.
local tipQueue, tipQueued = {}, {}
local function noteTip(it)
    if type(it) == "table" and it.s and not tipQueued[it.id] then
        tipQueued[it.id] = true
        tipQueue[#tipQueue + 1] = it
    end
end
local function readTips()
    if inCombat() then return end
    for _ = 1, 4 do
        local it = table.remove(tipQueue, 1)
        if not it then return end
        ns.rememberLink(it.id, it.s)
    end
end

-- Text from another player, kept as plain text: the game's codes (colours, links, textures,
-- atlases, Battle.net names, line breaks and the rest) are taken out, a link keeps only its words
-- and a typed pipe (||) stays one, so nothing another player sends can draw, link or colour
-- anything in your window, your tooltips or your chat. At most maxLen bytes (64 unless said).
local function S(v, maxLen)
    if type(v) ~= "string" or v == "" then return nil end
    if v:find("|", 1, true) then
        local out, i, n = {}, 1, #v
        while i <= n do
            local p = v:find("|", i, true)
            if not p then out[#out + 1] = v:sub(i) break end
            out[#out + 1] = v:sub(i, p - 1)
            local c = v:sub(p + 1, p + 1)
            if c == "|" then
                out[#out + 1] = "||"
                i = p + 2
            elseif c == "c" and v:find("^%x%x%x%x%x%x%x%x", p + 2) then
                i = p + 10
            elseif c == "H" or c == "T" or c == "A" or c == "K" then
                -- To its closing code: a link's data (its words, up to the next |h, stay), a texture,
                -- an atlas or a Battle.net name.
                local e = v:find("|" .. c:lower(), p + 2, true)
                i = e and e + 2 or n + 1
            else
                i = p + 2 -- |r, a link's closing |h, |n and any other code
            end
        end
        v = table.concat(out)
    end
    v = v:sub(1, maxLen or 64)
    if #v:match("|*$") % 2 == 1 then v = v:sub(1, -2) end -- never end on half of a typed pipe
    if v ~= "" then return v end
end

-- A key that carries its own separator (an auction house's "Realm|Side", a boss's
-- "name|instance"): only cut to length. Keys are matched, never shown.
local function K(v, maxLen)
    if type(v) == "string" and v ~= "" then return v:sub(1, maxLen or 64) end
end

local function N(v, lo, hi)
    if type(v) == "number" and v == v and v >= (lo or -2147483648) and v <= (hi or 2147483647) then return v end
end

local function cleanItem(it, withCount)
    if type(it) ~= "table" or not N(it.id, 1) then return nil end
    local s = S(it.s, 160)
    if s and not s:match("^item:[%-%d:]+$") then s = nil end -- only ever an item link, never another kind
    local out = { id = it.id, s = s, n = S(it.n, 80), q = N(it.q, 0, 9), il = N(it.il, 0, 9999), ic = N(it.ic, 1) }
    if withCount then out.c, out.bd = N(it.c, 1, 100000) or 1, it.bd == true or nil end
    return out
end

-- Each section as it arrives, cleaned field by field; nil when it isn't one. A part the sender
-- doesn't show stays nil, so the window can say so instead of showing it empty.
local CLEAN = {}

function CLEAN.core(d)
    if type(d) ~= "table" or not S(d.name, 24) then return nil end
    local out = {
        f = N(d.f, 1, 99), name = S(d.name, 24), realm = S(d.realm, 48), race = S(d.race, 48), raceFile = S(d.raceFile, 48),
        class = S(d.class, 32), classFile = S(d.classFile, 16), sex = N(d.sex, 0, 3), level = N(d.level, 1, 999),
        faction = S(d.faction, 16), guild = S(d.guild, 48), guildRank = S(d.guildRank, 48), title = S(d.title, 64),
        ruleset = S(d.ruleset, 16), addon = S(d.addon, 16), ilvl = N(d.ilvl, 0, 9999), cid = N(d.cid, 1, 99),
    }
    if type(d.spec) == "table" and N(d.spec.id, 1, 100000) then
        out.spec = { id = d.spec.id, n = S(d.spec.n, 48), r = S(d.spec.r, 16), ps = N(d.spec.ps, 1, 5) }
    end
    if out.classFile and not out.classFile:match("^[A-Z]+$") then out.classFile = nil end
    if type(d.stats) == "table" then
        out.stats = {}
        for _, k in ipairs(STAT_KEYS) do out.stats[k] = N(d.stats[k], -1e6, 1e8) end
    end
    if type(d.gear) == "table" then
        out.gear = {}
        for slot = 1, 19 do out.gear[slot] = cleanItem(d.gear[slot]) end
    end
    if type(d.profs) == "table" then
        out.profs = {}
        for i = 1, min(#d.profs, 12) do
            local p = d.profs[i]
            if type(p) == "table" and S(p.n) then
                out.profs[#out.profs + 1] = { n = S(p.n, 48), ic = N(p.ic, 1), sk = N(p.sk, 0, 9999), mx = N(p.mx, 0, 9999) }
            end
        end
    end
    if type(d.tal) == "table" then
        local tal = { pts = {}, n = {}, spent = N(d.tal.spent, 0, 999), left = N(d.tal.left, 0, 999) }
        for i = 1, 3 do tal.pts[i] = N(type(d.tal.pts) == "table" and d.tal.pts[i], 0, 999) or 0 end
        if type(d.tal.n) == "table" then
            for i = 1, min(#d.tal.n, 150) do
                local n = d.tal.n[i]
                if type(n) == "table" and N(n.r, 1, 99) then
                    tal.n[#tal.n + 1] = { sp = N(n.sp, 1), nm = S(n.nm, 64), ic = N(n.ic, 1), r = n.r, m = N(n.m, 0, 99), t = N(n.t, 1, 3), x = N(n.x, -1e6, 1e6), y = N(n.y, -1e6, 1e6) }
                end
            end
        end
        out.tal = tal
    end
    return out
end

function CLEAN.live(d)
    if type(d) ~= "table" then return nil end
    local out = {
        gold = N(d.gold, 0, 1e13), zone = S(d.zone, 64), sub = S(d.sub, 64), map = S(d.map, 64), x = N(d.x, 0, 100),
        y = N(d.y, 0, 100), hearth = S(d.hearth, 64), played = N(d.played, 0, 1e10), playedLevel = N(d.playedLevel, 0, 1e10),
    }
    return next(out) and out or nil
end

function CLEAN.reps(d)
    if type(d) ~= "table" or type(d.list) ~= "table" then return nil end
    local out = {}
    for i = 1, min(#d.list, 300) do
        local r = d.list[i]
        if type(r) == "table" and S(r.n) then
            out[#out + 1] = { n = S(r.n, 64), r = N(r.r, 1, 8), v = N(r.v, -1e7, 1e7), lo = N(r.lo, -1e7, 1e7), hi = N(r.hi, -1e7, 1e7),
                h = r.h == true or nil, w = r.w == true or nil, c = r.c == true or nil }
        end
    end
    return #out > 0 and { list = out } or nil
end

function CLEAN.quests(d)
    if type(d) ~= "table" or type(d.list) ~= "table" then return nil end
    local out = {}
    for i = 1, min(#d.list, 60) do
        local q = d.list[i]
        if type(q) == "table" and S(q.t) then
            local rec = { t = S(q.t, 96), l = N(q.l, 1, 999), d = q.d == true or nil, g = S(q.g, 64) }
            if type(q.o) == "table" then
                for k = 1, min(#q.o, 12) do
                    local o = q.o[k]
                    if type(o) == "table" and S(o.t) then
                        rec.o = rec.o or {}
                        rec.o[#rec.o + 1] = { t = S(o.t, 160), d = o.d == true or nil }
                    end
                end
            end
            out[#out + 1] = rec
        end
    end
    return #out > 0 and { list = out } or nil
end

local function cleanContainers(d)
    if type(d) ~= "table" or type(d.list) ~= "table" then return nil end
    local out = {}
    for i = 1, min(#d.list, 24) do
        local b = d.list[i]
        if type(b) == "table" and N(b.z, 1, 98) then
            local bag = { z = b.z, b = N(b.b, -10, 50), it = cleanItem(b.it), s = {} }
            if type(b.s) == "table" then
                for slot = 1, b.z do bag.s[slot] = cleanItem(b.s[slot], true) end
            end
            out[#out + 1] = bag
        end
    end
    return #out > 0 and { list = out, at = N(d.at, 1) } or nil
end
CLEAN.bags, CLEAN.bank = cleanContainers, cleanContainers

local function cleanTab(d)
    if type(d) ~= "table" or not N(d.i, 1, 8) or not N(d.at, 1) then return nil end
    local tab = { name = S(d.nm, 48), icon = N(d.ic, 1), at = d.at, by = S(d.by, 24), slots = {} }
    if type(d.s) == "table" then
        for slot = 1, 98 do
            local it = cleanItem(d.s[slot], true)
            if it then tab.slots[slot] = { id = it.id, n = it.c, q = it.q, icon = it.ic, name = it.n, s = it.s } end
        end
    end
    return d.i, tab
end

local function peerFor(who, create)
    local p = peers()[who]
    if not p and create then
        p = { key = who, scopes = {} }
        peers()[who] = p
    end
    return p
end

-- Forgets one section a player sent.
local function dropSection(p, name)
    if type(p.hashes) == "table" then p.hashes[name] = nil end
    if type(p.from) == "table" then p.from[name] = nil end
    if type(p.under) == "table" then p.under[name] = nil end
    if type(p.gotAt) == "table" then p.gotAt[name] = nil end
    if name == "core" then p.card = nil elseif type(p.more) == "table" then p.more[name] = nil end
end

-- Forgets what was asked of a player on the guild channel: once they stop sharing with the guild,
-- nothing asked will be answered, and when they share again everything is asked for afresh.
local function forgetAsks(who)
    for _, name in ipairs(SECTIONS) do askedGuild[who .. "|" .. name] = nil end
end

-- Forgets every section a player sent under a scope they no longer share with you. `class` limits
-- it to sections that came one way ("guild" or "direct"); nil means any way.
local function dropUnder(p, gone, class)
    if gone == "" then return end
    for name in pairs(type(p.hashes) == "table" and p.hashes or {}) do
        local from = type(p.from) == "table" and p.from[name]
        local under = type(p.under) == "table" and p.under[name] or (from == "guild" and "g" or "gfp")
        if (not class or from == class) and under:find("[" .. gone .. "]") then dropSection(p, name) end
    end
end

-- The scopes a player says they share with you, as they count for the way the message came: the
-- guild channel speaks only for the guild, and "guild" by whisper only from a guildmate.
local function scopeLetters(who, route, letters)
    letters = type(letters) == "string" and letters or ""
    if route.kind == "GUILD" then return letters:find("g", 1, true) and "g" or "" end
    if letters:find("g", 1, true) and not isGuildmate(who) then letters = letters:gsub("g", "") end
    return (letters:gsub("[^gfp]", ""))
end

-- Applies those scopes. A whisper or Battle.net message speaks for all three, so a scope it
-- leaves out is taken back; a player is kept only once their card has come (create).
local function applyScopes(who, route, letters, create)
    letters = scopeLetters(who, route, letters)
    local p = peerFor(who, create and letters ~= "")
    if not p then return nil end
    local t = time()
    local gone = ""
    for _, l in ipairs(route.kind == "GUILD" and { "g" } or { "g", "f", "p" }) do
        if letters:find(l, 1, true) then p.scopes[l] = t else p.scopes[l] = nil gone = gone .. l end
    end
    -- What came this way under a scope it no longer speaks for goes; what is still shown comes again.
    dropUnder(p, gone, route.kind == "GUILD" and "guild" or "direct")
    if p.scopes.g then p.gk = ns.guildKey() end
    p.seen, p.via = t, route.kind
    if not next(p.scopes) then
        peers()[who] = nil
        changed("peers")
        return nil
    end
    return p
end

local waitingSend = {}    -- [key] = true: a card or tab held back by its gap, to go when the gap ends

-- Runs send now, or once the gap since the last one has passed (never twice in a gap). `fn` says
-- whether it sent anything: one with nothing left to send doesn't start a gap.
local function inTurn(key, last, gap, fn)
    local t = now()
    if not last[key] or t - last[key] >= gap then
        if fn() then last[key] = t end
        return
    end
    if waitingSend[key] or not C_Timer then return end
    waitingSend[key] = true
    C_Timer.After(gap - (t - last[key]) + 0.1, function()
        waitingSend[key] = nil
        if fn() then last[key] = now() end
    end)
end

local function sendSection(route, name, letters)
    inTurn("sec:" .. routeKey(route) .. ":" .. name, lastCardSent, CARD_GAP, function()
        local sc = allowed(letters) -- a switch turned off while it waited counts
        local sec = sectionsFor(sc)[name]
        return sec ~= nil and send(route, { t = "sec", n = name, h = sec.h, sc = sc, d = sec.d })
    end)
end

-- Sends the sections asked for, in the order they are best received: who the character is first.
local function sendSections(route, list, letters)
    for _, name in ipairs(SECTIONS) do
        if list[name] then sendSection(route, name, letters) end
    end
end

local sendTab
do
    -- A bank tab as it travels: its slots, and with them its log and note when you keep the bank's
    -- records for the guild. The gold log (GOLD_LOG) is records alone.
    local function tabMessage(g, i)
        local b = type(g.bank) == "table" and g.bank or {}
        local msg = { t = "gb", i = i }
        local tab = i <= 8 and type(b.tabs) == "table" and b.tabs[i]
        if type(tab) == "table" and type(tab.slots) == "table" and num(tab.at) then
            local slots = {}
            for slot, it in pairs(tab.slots) do
                if type(it) == "table" and num(it.id) then
                    slots[slot] = { id = it.id, c = num(it.n) or 1, q = num(it.q), ic = num(it.icon), n = str(it.name), s = itemString(it.link) or it.s }
                end
            end
            msg.at, msg.by, msg.nm, msg.ic, msg.h, msg.s = tab.at, tab.by, tab.name, tab.icon, tabFingerprint(tab), slots
        end
        local at = iKeep(g) and recordsAt(b, i)
        if at then
            local log = type(b.logs) == "table" and b.logs[i]
            local note = type(b.notes) == "table" and b.notes[i]
            msg.ra = at
            msg.rb = type(log) == "table" and log.by or type(note) == "table" and note.by or nil
            if type(log) == "table" and type(log.list) == "table" then msg.lg = log.list end
            if i <= 8 and type(note) == "table" then msg.nt = note.text or "" end
        end
        if i <= 8 and ns.boardOut then msg.bd, msg.ba = ns.boardOut(g, i) end
        if not (msg.at or msg.ra or msg.ba) then return nil end
        return msg
    end

    -- A tab the guild master opened to everyone goes once to the whole guild; any other, by whisper.
    local function tabRoute(g, i, who)
        local p = policyOf(g)
        if i <= 8 and p and type(p.tb) == "table" and p.tb[i] == "a" then return { kind = "GUILD" } end
        return { kind = "WHISPER", target = who }
    end

    local function sendTabNow(i, route)
        if not shares().guild then return false end -- switched off while it waited
        local g = myGuild()
        if not g then return false end
        if route.kind == "GUILD" then
            local p = policyOf(g)
            if not (i <= 8 and p and p.tb[i] == "a") then return false end -- the guild master changed it meanwhile
        elseif not theySee(g, route.target, i) then
            return false
        end
        local msg = tabMessage(g, i)
        return msg ~= nil and send(route, msg)
    end

    function sendTab(i, who)
        local g = myGuild()
        if not g then return end
        local route = tabRoute(g, i, who)
        inTurn("tab:" .. i .. ":" .. routeKey(route), lastTabSent, BANK_GAP, function() return sendTabNow(i, route) end)
    end
end

local announcedBank -- the fingerprint of the bank index the guild last heard from you

-- "Hello": the fingerprint of each section whoever hears this sees, and the scopes you share it
-- under; on the guild channel your guild bank index and, from the guild master, the fingerprint
-- of their bank settings; and with w = 1 a request for their hello.
local function hello(route, letters, wantReply)
    local msg = { t = "hi", v = ns.version, w = wantReply and 1 or nil }
    if letters ~= "" then msg.s = fingerprints(letters) end
    if msg.s then msg.sc = letters end
    if route.kind == "GUILD" then
        local g = myGuild()
        if shares().guild then
            msg.b = bankIndex()
            announcedBank = msg.b and hash(msg.b) or nil
        end
        local p = g and policyOf(g)
        if p and p.by == me() and p.h then msg.bp = p.h end
        if ns.priceOffer then msg.px = ns.priceOffer() end
        lastGuildHello = now()
    end
    if not msg.s and not msg.w and not msg.b and not msg.bp and not msg.px then return end
    send(route, msg, true)
end

local function askForTabs()
    wantTimer = false
    local byHolder = {}
    for i, want in pairs(wantTabs) do
        byHolder[want.who] = byHolder[want.who] or {}
        table.insert(byHolder[want.who], i)
    end
    wantTabs = {}
    for who, tabs in pairs(byHolder) do
        table.sort(tabs)
        send({ kind = "GUILD" }, { t = "ask", to = who, bt = tabs }, true)
    end
end

local offers = {} -- [who] = the bank index they offered last, looked at again when what you may see changes

local function onBankIndex(idx, who)
    local g = myGuild()
    if type(idx) ~= "table" or not g then return end
    offers[who] = idx
    g.bank = type(g.bank) == "table" and g.bank or {}
    local b = g.bank
    b.tabs = type(b.tabs) == "table" and b.tabs or {}
    if N(idx.mt, 1) and N(idx.m, 0) and idx.mt > (num(b.moneyAt) or 0) then
        b.money, b.moneyAt = idx.m, idx.mt
        changed("bank")
    end
    if N(idx.n, 1, 8) then b.count = max(num(b.count) or 0, idx.n) end
    if type(idx.t) ~= "table" then return end
    local p, keeper = policyOf(g), theyKeep(g, who)
    for i = 1, GOLD_LOG do
        local offer = idx.t[i]
        -- Only what you may see, from a guildmate who may see it too.
        if type(offer) == "table" and iSee(g, i) and rankSees(rankOf(who), i, p) ~= false then
            local want = false
            if i <= 8 and N(offer.at, 1) and type(offer.h) == "string" then
                local mine = b.tabs[i]
                want = type(mine) ~= "table" or not num(mine.at) or (offer.at > mine.at and offer.h ~= tabFingerprint(mine))
            end
            if keeper and N(offer.ra, 1) and offer.ra > (recordsAt(b, i) or 0) then want = true end
            if i <= 8 and ns.boardWanted and ns.boardWanted(g, i, offer, who) then want = true end
            if i <= 8 and ns.boardOffered then ns.boardOffered(g, i, offer, who) end
            if want then
                local at = max(N(offer.at, 1) or 0, N(offer.ra, 1) or 0, N(offer.ba, 1) or 0)
                if not wantTabs[i] or at > wantTabs[i].at then wantTabs[i] = { who = who, at = at } end
            end
        end
    end
    if next(wantTabs) and not wantTimer and C_Timer then
        wantTimer = true
        C_Timer.After(1 + random() * 3, askForTabs)
    end
end

local policyWire, cleanPolicy
do
    -- The guild master's settings as they travel: who sees each tab ("g" as in game, "a" everyone,
    -- "n" the game only, or a rank number for that rank and up), whether the bank's records are
    -- shared (rc) and which ranks keep them (kp), the ranks' names, and the game's own permissions:
    -- which tabs each rank may view (v), and with the records each rank's limits (lm).
    function policyWire(p)
        return { at = p.at, tb = p.tb, rc = p.rc, kp = p.kp, n = p.n, nm = p.nm, v = p.v, lm = p.rc and p.lm or nil }
    end

    local function bits(v)
        local s = S(v, 8)
        return s and s:match("^[01]+$") and s or nil
    end

    function cleanPolicy(d)
        if type(d) ~= "table" or not N(d.at, 1) then return nil end
        local p = { at = d.at, tb = {}, nm = {}, rc = d.rc == true or nil, kp = N(d.kp, 1, RANKS_MAX), n = N(d.n, 1, RANKS_MAX) }
        for i = 1, 8 do
            local a = type(d.tb) == "table" and d.tb[i] or nil
            if a == "a" or a == "n" or a == "g" then p.tb[i] = a else p.tb[i] = N(a, 1, RANKS_MAX) or "g" end
        end
        for r = 1, RANKS_MAX do p.nm[r] = type(d.nm) == "table" and S(d.nm[r], 48) or nil end
        if type(d.v) == "table" then
            p.v = {}
            for r = 1, RANKS_MAX do p.v[r] = bits(d.v[r]) end
        end
        if p.rc and type(d.lm) == "table" then
            p.lm = {}
            for r = 1, RANKS_MAX do
                local x = d.lm[r]
                if type(x) == "table" then
                    local row = { g = N(x.g, -1, 1e9), d = bits(x.d), w = {} }
                    for i = 1, 8 do row.w[i] = type(x.w) == "table" and N(x.w[i], -1, 100000) or nil end
                    p.lm[r] = row
                end
            end
        end
        return p
    end
end

local policyChanged, sendPolicy, onPolicyOffer
do
    -- What changes when the guild master's settings do: what you hold that you may no longer see
    -- goes, waiting tabs go only where they may, and offers already heard are looked at again.
    function policyChanged(g)
        tidyBank(g)
        purgeQueued()
        for who, idx in pairs(offers) do onBankIndex(idx, who) end
        -- What you offer may have changed (you may keep the records now): the guild hears, once.
        local idx = shares().guild and ns.isLoggedIn() and bankIndex()
        if idx and hash(idx) ~= announcedBank and C_Timer then
            announcedBank = hash(idx)
            C_Timer.After(2 + random() * 3, function() hello({ kind = "GUILD" }, "g") end)
        end
        changed("bank")
    end

    -- From the guild master's game: their settings to the whole guild, at most every half minute
    -- unless they just changed.
    local policySentAt = -math.huge
    function sendPolicy(force)
        local g = myGuild()
        local p = g and policyOf(g)
        if not (p and p.by == me()) then return end
        if not force and now() - policySentAt < 30 then return end
        policySentAt = now()
        send({ kind = "GUILD" }, { t = "bp", p = policyWire(p) }, true)
    end

    -- A hello from the guild master offers settings you haven't got: ask for them, unless another
    -- guildmate just did (the answer goes to the whole guild).
    local policyAsked = {}
    function onPolicyOffer(h, who)
        local g = myGuild()
        if not g or rankOf(who) ~= 1 then return end
        local cur = type(g.policy) == "table" and g.policy
        if cur and cur.by == who and cur.h == h then return end
        local key = who .. "|" .. h
        if policyAsked[key] and now() - policyAsked[key] < ASK_TTL then return end
        policyAsked[key] = now()
        if not C_Timer then return end
        C_Timer.After(1 + random() * 3, function()
            local c2 = type(g.policy) == "table" and g.policy
            if c2 and c2.by == who and c2.h == h then return end
            local other = othersAsked[who .. "|bp|" .. h]
            if other and now() - other < 10 then return end
            send({ kind = "GUILD" }, { t = "ask", to = who, bp = h }, true)
        end)
    end

    -- The guild master's settings built from the last ones and one change, with the game's rank
    -- permissions as the guild master's own game last read them, cleaned as guildmates will keep them.
    local function makePolicy(g, base, change)
        local p = { at = max(time(), (num(base.at) or 0) + 1), tb = {}, rc = base.rc, kp = base.kp or 2 }
        for i = 1, 8 do p.tb[i] = type(base.tb) == "table" and base.tb[i] or "g" end
        if change then
            if change.tab and change.aud ~= nil then p.tb[change.tab] = change.aud end
            if change.rec ~= nil then p.rc = change.rec and true or nil end
            if change.keep then p.kp = change.keep end
        end
        local rules = g.rules
        if type(rules) == "table" and num(rules.n) then
            p.n, p.nm, p.v, p.lm = rules.n, rules.names, rules.view, {}
            for r = 1, rules.n do
                p.lm[r] = { g = type(rules.gold) == "table" and rules.gold[r] or nil, d = type(rules.dep) == "table" and rules.dep[r] or nil,
                    w = type(rules.wd) == "table" and rules.wd[r] or nil }
            end
        end
        local clean = cleanPolicy(policyWire(p))
        clean.by = me()
        clean.h = hash(policyWire(clean))
        return clean
    end

    local function policyContent(p)
        local w = policyWire(p)
        w.at = nil
        return hash(w)
    end

    -- For the guild master: one change to the settings, told to the guild at once. `change` is
    -- { tab = i, aud = "g" | "a" | "n" | rank }, { rec = true | false } or { keep = rank }.
    ns.setBankPolicy = function(change)
        local g = myGuild()
        if not (g and ns.isGuildLeader()) then return false end
        local rules = ns.readRankRules()
        if rules then g.rules = rules end
        local cur = type(g.policy) == "table" and g.policy.by == me() and g.policy or {}
        g.policy = makePolicy(g, cur, change or {})
        sendPolicy(true)
        policyChanged(g)
        return true
    end

    -- The guild master's game read every rank's permissions afresh at the bank: their settings
    -- follow, and the guild hears only if something changed.
    ns.onRankRules = function(g)
        local cur = type(g.policy) == "table" and g.policy.by == me() and g.policy
        if not cur then return end
        local p = makePolicy(g, cur, nil)
        if policyContent(p) == policyContent(cur) then return end
        g.policy = p
        sendPolicy(true)
        policyChanged(g)
    end

    ns.bankPolicy = function(g) return policyOf(g) end
    ns.theySeeTab = function(g, who, i) return theySee(g, who, i) end
    ns.rankSeesTab = function(ro, i, g) return rankSees(ro, i, policyOf(g)) end
    ns.myRank, ns.rankOf, ns.bankKeeps = myRank, rankOf, function(g) return iKeep(g) end
end

local handlers = {}
ns.handlers = handlers
ns.dataChanged = function(kind) changed(kind) end
ns.cleanKey = K
ns.cleanNum, ns.cleanStr, ns.myGuild, ns.isGuildmate, ns.itemString, ns.noteTip = N, S, myGuild, isGuildmate, itemString, noteTip

-- Another file's section of the card: who sees it (the parts it goes with), how often it is
-- announced, how it is built and cleaned, and what to do once it has arrived (`arrived`, optional).
local ARRIVED = {}
ns.addSection = function(name, parts, gap, build, clean, arrived)
    SECTIONS[#SECTIONS + 1] = name
    SECTION_PARTS[name], SECTION_GAP[name] = parts, gap
    BUILD[name], CLEAN[name], ARRIVED[name] = build, clean, arrived
end
-- How long a message would be once packed (nil when this client can't pack): a section must fit in
-- the most pieces one message may have.
ns.packedLength = function(msg)
    local text = encode(msg)
    return text and #text or nil
end
ns.sees = function(letters, part) return sees(letters, part) end

-- The sections a hello offers that this player hasn't got yet, by fingerprint.
local function wanted(p, offered)
    local out = {}
    for _, name in ipairs(SECTIONS) do
        local h = offered[name]
        if type(h) == "string" and not (p and type(p.hashes) == "table" and p.hashes[name] == h) then out[name] = h end
    end
    return next(out) and out or nil
end

-- A section this player had from the way this hello came and no longer offers: they stopped
-- showing it. (Who the character is never goes; it leaves with the player.)
local function dropUnoffered(p, route, offered)
    local from = route.kind == "GUILD" and "guild" or "direct"
    for name in pairs(type(p.hashes) == "table" and p.hashes or {}) do
        if name ~= "core" and offered[name] == nil and type(p.from) == "table" and p.from[name] == from then dropSection(p, name) end
    end
end

function handlers.hi(msg, route, who)
    local offered = type(msg.s) == "table" and msg.s or nil
    local letters = scopeLetters(who, route, offered and msg.sc or "")
    if route.kind == "GUILD" then
        -- An ask for something they no longer offer as it was is moot: ask afresh when it comes back.
        for _, name in ipairs(SECTIONS) do
            local a = askedGuild[who .. "|" .. name]
            if a and (offered or {})[name] ~= a.h then askedGuild[who .. "|" .. name] = nil end
        end
    end
    local p = peers()[who] and applyScopes(who, route, letters)
    if p then
        p.ver = S(msg.v, 16)
        if offered then dropUnoffered(p, route, offered) end
        if ns.rpFetch then ns.rpFetch(who) end -- they are online: Total RP 3 may fetch their profile
        changed("peers")
    end
    local want = letters ~= "" and offered and wanted(p, offered)
    if want then
        if route.kind == "GUILD" then
            -- Asked on the guild channel, so one answer serves every guildmate who wants it: wait a
            -- moment, and ask only for what nobody else has asked for meanwhile.
            local t = now()
            local fresh = {}
            for name, h in pairs(want) do
                local key = who .. "|" .. name
                local a = askedGuild[key]
                if not (a and t - a.at <= ASK_TTL) then
                    askedGuild[key] = { h = h, at = t }
                    fresh[name] = h
                end
            end
            if next(fresh) and C_Timer then
                C_Timer.After(1 + random() * 3, function()
                    local q = peers()[who]
                    local still = {}
                    for name, h in pairs(fresh) do
                        local other = othersAsked[who .. "|" .. name .. "|" .. h]
                        local has = q and type(q.hashes) == "table" and q.hashes[name] == h
                        if not has and not (other and now() - other < 10) then still[name] = h end
                    end
                    if next(still) then send({ kind = "GUILD" }, { t = "ask", to = who, s = still }, true) end
                end)
            end
        else
            asked[who] = now()
            send(route, { t = "ask", s = want }, true)
        end
    end
    if route.kind == "GUILD" and msg.b then onBankIndex(msg.b, who) end
    if route.kind == "GUILD" and type(msg.bp) == "string" then onPolicyOffer(msg.bp, who) end
    if route.kind == "GUILD" and type(msg.px) == "table" and ns.onPriceOffer then ns.onPriceOffer(msg.px, who) end
    if msg.w == 1 then
        if route.kind == "GUILD" then
            -- A guildmate just came: answer if you share with the guild, or hold prices newer than
            -- any heard since (theirs included, so nobody answers with what they have), so prices
            -- reach them whoever has them. One answer serves everyone.
            local heard, since = now(), time()
            local function answer() return shares().guild or (ns.priceAnswer and ns.priceAnswer(since)) end
            if answer() and C_Timer then
                C_Timer.After(1 + random() * 7, function()
                    if lastGuildHello < heard and answer() then hello({ kind = "GUILD" }, shares().guild and "g" or "") end
                end)
            end
        else
            local letters = scopesFor(who, route)
            if letters ~= "" then hello(route, letters) end
        end
    end
end

function handlers.ask(msg, route, who)
    local list = type(msg.s) == "table" and msg.s or nil
    if route.kind == "GUILD" then
        if msg.to ~= me() then
            -- Someone else asked: their answer reaches you too, so don't ask again for it.
            if type(msg.to) == "string" and list then
                for name, h in pairs(list) do
                    if type(name) == "string" and type(h) == "string" then othersAsked[msg.to .. "|" .. name .. "|" .. h] = now() end
                end
            end
            if type(msg.bt) == "table" then
                -- Only a tab sent to the whole guild answers you too; the rest go by whisper.
                local g = myGuild()
                local p = g and policyOf(g)
                for _, i in ipairs(msg.bt) do
                    if wantTabs[i] and wantTabs[i].who == msg.to and type(i) == "number" and i <= 8 and p and p.tb[i] == "a" then wantTabs[i] = nil end
                end
            end
            if type(msg.bp) == "string" and type(msg.to) == "string" then othersAsked[msg.to .. "|bp|" .. msg.bp] = now() end
            return
        end
        if msg.bp ~= nil then sendPolicy(false) end -- the guild master's settings go whether or not you share
        if not shares().guild then return end
        if list then sendSections(route, list, "g") end
        if type(msg.bt) == "table" then
            for k = 1, min(#msg.bt, GOLD_LOG) do
                local i = N(msg.bt[k], 1, GOLD_LOG)
                if i then sendTab(i, who) end
            end
        end
        return
    end
    local letters = scopesFor(who, route)
    if letters ~= "" and list then sendSections(route, list, letters) end
end

function handlers.sec(msg, route, who)
    local name = msg.n
    if type(name) ~= "string" or not CLEAN[name] or type(msg.h) ~= "string" then return end
    if route.kind ~= "GUILD" then
        local t = asked[who]
        if not (t and now() - t <= ASK_TTL) and not isFriend(who) and not isGuildmate(who) then return end
    end
    local data = CLEAN[name](msg.d)
    if not data then return end
    if name == "core" then
        -- A card can only be the sender's own: the name and realm come from who sent it.
        local realm = who:match("%-(.+)$")
        data.name = shortName(who)
        if not data.realm or normRealm(data.realm) ~= realm then data.realm = realm end
    end
    -- Sections can arrive in any order; whichever comes first starts the entry.
    local p = applyScopes(who, route, route.kind == "GUILD" and "g" or msg.sc, true)
    if not p then return end
    p.hashes = type(p.hashes) == "table" and p.hashes or {}
    p.from = type(p.from) == "table" and p.from or {}
    p.under = type(p.under) == "table" and p.under or {}
    p.gotAt = type(p.gotAt) == "table" and p.gotAt or {}
    p.hashes[name], p.from[name], p.gotAt[name], p.got = msg.h:sub(1, 16), route.kind == "GUILD" and "guild" or "direct", time(), time()
    p.under[name] = scopeLetters(who, route, route.kind == "GUILD" and "g" or msg.sc)
    if ns.rpFetch then ns.rpFetch(who) end
    if name == "core" then
        p.card, p.name, p.realm = data, data.name, data.realm
        for _, it in pairs(data.gear or {}) do noteTip(it) end
        if looking[who] then
            looking[who] = nil
            print(format("%s%s shared with you. /rq to see.", ns.TAG, data.name))
        end
    else
        p.more = type(p.more) == "table" and p.more or {}
        p.more[name] = data
        if name == "bags" or name == "bank" then
            for _, bag in ipairs(data.list) do
                for _, it in pairs(bag.s) do noteTip(it) end
            end
        end
        if ARRIVED[name] then pcall(ARRIVED[name], p, data, who) end
    end
    changed("peers")
end

local cleanLog
do
    local LOG_KINDS = { deposit = true, withdraw = true, move = true, repair = true, withdrawForTab = true, buyTab = true, depositSummary = true }

    -- A tab's log (or the gold log), as it arrives: oldest first, at most fifty entries.
    function cleanLog(list, gold)
        local out = {}
        for k = 1, min(type(list) == "table" and #list or 0, 50) do
            local e = list[k]
            if type(e) == "table" and LOG_KINDS[e.k] and N(e.at, 1) then
                local rec = { k = e.k, w = S(e.w, 48), at = e.at }
                if gold then
                    rec.m = N(e.m, 0, 1e13)
                else
                    rec.id, rec.nm, rec.q, rec.ic = N(e.id, 1), S(e.nm, 80), N(e.q, 0, 9), N(e.ic, 1)
                    rec.n, rec.t1, rec.t2 = N(e.n, 1, 100000), N(e.t1, 1, 8), N(e.t2, 1, 8)
                    local s = S(e.s, 160)
                    if s and s:match("^item:[%-%d:]+$") then rec.s = s end
                    if rec.id and rec.s then noteTip({ id = rec.id, s = rec.s }) end
                end
                out[#out + 1] = rec
            end
        end
        return out
    end
end

function handlers.gb(msg, route, who)
    local g = myGuild()
    local i = N(msg.i, 1, GOLD_LOG)
    local ro = rankOf(who)
    if not (g and i and ro) then return end -- only from someone in your guild list
    local p = policyOf(g)
    if route.kind == "GUILD" then
        if not (i <= 8 and p and p.tb[i] == "a") then return end -- only a tab open to everyone goes to the whole guild
    elseif route.kind ~= "WHISPER" then
        return
    end
    if not iSee(g, i) then return end
    if rankSees(ro, i, p) == false then return end -- a guildmate who may not see it can't vouch for it
    g.bank = type(g.bank) == "table" and g.bank or {}
    local b = g.bank
    local got = false
    if i <= 8 and msg.at then
        local _, tab = cleanTab(msg)
        if tab then
            b.tabs = type(b.tabs) == "table" and b.tabs or {}
            local mine = b.tabs[i]
            if not (type(mine) == "table" and num(mine.at) and mine.at >= tab.at) then
                tab.by = tab.by or shortName(who)
                b.tabs[i] = tab
                got = true
            end
        end
    end
    -- The records come only from the guild master and the ranks they trust to keep them.
    local ra = N(msg.ra, 1)
    if ra and theyKeep(g, who) and ra > (recordsAt(b, i) or 0) then
        local by = S(msg.rb, 48) or shortName(who)
        if type(msg.lg) == "table" then
            b.logs = type(b.logs) == "table" and b.logs or {}
            b.logs[i] = { at = ra, by = by, list = cleanLog(msg.lg, i == GOLD_LOG) }
        end
        if i <= 8 and type(msg.nt) == "string" then
            b.notes = type(b.notes) == "table" and b.notes or {}
            b.notes[i] = { at = ra, by = by, text = S(msg.nt, 600) }
        end
        got = true
    end
    if i <= 8 and ns.boardIn and ns.boardIn(g, i, msg, who) then got = true end
    if got then
        if wantTabs[i] then wantTabs[i] = nil end
        changed("bank")
    end
end

-- The guild master's settings, from the guild master's own game.
function handlers.bp(msg, route, who)
    if route.kind ~= "GUILD" then return end
    local g = myGuild()
    if not g or rankOf(who) ~= 1 then return end -- only the guild master in your own guild list
    local p = cleanPolicy(msg.p)
    if not p then return end
    local cur = type(g.policy) == "table" and g.policy
    if cur and cur.by == who and num(cur.at) and cur.at >= p.at then return end
    p.by, p.h = who, hash(policyWire(p))
    g.policy = p
    policyChanged(g)
end

function handlers.bye(msg, route, who)
    local p = peers()[who]
    if not p or type(msg.sc) ~= "string" then return end
    local gone = ""
    for _, l in ipairs(route.kind == "GUILD" and { "g" } or { "g", "f", "p" }) do
        if msg.sc:find(l, 1, true) then p.scopes[l], gone = nil, gone .. l end
    end
    -- Whatever came under that scope goes with it, however it came: what they still show you
    -- comes again the next time they say hello.
    dropUnder(p, gone)
    if gone:find("g", 1, true) then forgetAsks(who) end
    if not next(p.scopes) then peers()[who] = nil end
    changed("peers")
end

local function receive(text, route, who)
    if type(text) ~= "string" or #text < 6 or text:sub(1, 1) ~= PROTOCOL then return end
    if not who or who == me() or isIgnored(who) then return end
    local id, seq, total = text:sub(2, 3), undigit(text:sub(4, 4)), undigit(text:sub(5, 5))
    if not (seq and total) or seq < 1 or total < 1 or seq > total or total > MAX_CHUNKS then return end
    local body = text:sub(6)
    if total > 1 then
        local key = who .. "|" .. id
        local part = partials[key]
        if not part then
            if partialCount >= MAX_PARTIALS then return end
            part = { total = total, parts = {}, got = 0, at = now() }
            partials[key], partialCount = part, partialCount + 1
        end
        if part.total ~= total then return end
        if not part.parts[seq] then part.parts[seq], part.got = body, part.got + 1 end
        if part.got < total then return end
        partials[key], partialCount = nil, partialCount - 1
        body = table.concat(part.parts)
    end
    local msg = decode(body)
    local handle = type(msg) == "table" and type(msg.t) == "string" and handlers[msg.t]
    if not handle then return end
    if route.kind == "GUILD" then
        -- Whoever speaks on the guild channel runs Reliquary: news of the bank's board goes to them.
        local g = myGuild()
        if g then
            g.heard = type(g.heard) == "table" and g.heard or {}
            g.heard[who] = time()
        end
    end
    handle(msg, route, who)
end

local function sweepPartials()
    local t = now()
    for key, part in pairs(partials) do
        if t - part.at > PARTIAL_TTL then partials[key], partialCount = nil, partialCount - 1 end
    end
    for key, at in pairs(othersAsked) do
        if t - at > 60 then othersAsked[key] = nil end
    end
end

---------------------------------------------------------------------------
-- When to say hello
---------------------------------------------------------------------------
local greeted = {}   -- [who] = true: friends greeted this session

local function friendLetters(route, who)
    local s = shares()
    local out = ""
    if s.friends then out = out .. "f" end
    if s.guild and isGuildmate(who) then out = "g" .. out end
    if s.public then out = out .. "p" end
    return out
end

local guildGreeted, started = false, false
local announced, announcedAt = {}, {} -- each section's fingerprint when last announced, and when

-- Every scope this character shares with, as letters: whose view an announcement is judged by.
local function audienceAll()
    local s, out = shares(), ""
    if s.guild then out = out .. "g" end
    if s.friends then out = out .. "f" end
    if s.public then out = out .. "p" end
    return out
end

local function markAnnounced()
    local t, fps = now(), fingerprints(audienceAll()) or {}
    for _, name in ipairs(SECTIONS) do
        if fps[name] ~= announced[name] then announcedAt[name] = t end
        announced[name] = fps[name]
    end
end

-- Hello to the guild and every friend online. On logging in it also asks for theirs (w = 1);
-- later it only says your card changed, to those who see it.
local function helloAll(wantReply)
    local s = shares()
    if str(call(GetGuildInfo, "player")) then
        guildGreeted = guildGreeted or wantReply
        hello({ kind = "GUILD" }, s.guild and "g" or "", wantReply)
    end
    for _, f in ipairs(onlineFriends()) do
        if wantReply then greeted[f.who] = true end
        if wantReply or s.friends or s.public then hello(f.route, friendLetters(f.route, f.who), wantReply) end
    end
    markAnnounced()
end

local function greetFriends()
    for _, f in ipairs(onlineFriends()) do
        if not greeted[f.who] then
            greeted[f.who] = true
            hello(f.route, friendLetters(f.route, f.who), true)
        end
    end
end

-- A hello to the guild now (Prices.lua: a newer scan to offer).
ns.guildHello = function()
    if str(call(GetGuildInfo, "player")) then hello({ kind = "GUILD" }, shares().guild and "g" or "") end
end

local function greetGuild()
    if guildGreeted or not str(call(GetGuildInfo, "player")) then return end
    guildGreeted = true
    hello({ kind = "GUILD" }, shares().guild and "g" or "", true)
end

local function greet()
    if not (ns.isLoggedIn() and ns.db) or started then return end
    started = true
    helloAll(true)
end

-- Something others see changed (a level, gear, gold, loot): tell them, each section at most as
-- often as SECTION_GAP allows. A hello carries every fingerprint, so one serves all changes.
local announceQueued = false
local function announce()
    local all = audienceAll()
    if all == "" or not started then return end
    local fps = fingerprints(all) or {}
    local t, due, wait = now(), false, math.huge
    for _, name in ipairs(SECTIONS) do
        if fps[name] ~= announced[name] then
            local left = SECTION_GAP[name] - (t - (announcedAt[name] or -math.huge))
            if left <= 0 then due = true else wait = min(wait, left) end
        end
    end
    if due then
        helloAll(false)
    elseif wait < math.huge and C_Timer and not announceQueued then
        announceQueued = true
        C_Timer.After(wait, function() announceQueued = false announce() end)
    end
end

-- After each scan: the card may have changed, and a fresh guild roster may show who has left.
local prunedRoster
ns.afterScan = function()
    forgetSections()
    if not ns.db then return end
    local g = myGuild()
    if g and g.at ~= prunedRoster then
        prunedRoster = g.at
        ns.prunePeers()
        tidyBank(g) -- the guild list may name a new guild master
        changed()
    end
    if started then announce() end
end

-- Another file changed something in the card (Upgrades.lua: your verdicts): those who see it hear.
ns.cardChanged = function()
    forgetSections()
    if started then announce() end
end

local bankAnnouncedAt = -math.huge
ns.onGuildBankRead = function()
    local g = myGuild()
    if g then tidyBank(g) end
    changed("bank")
    if not shares().guild or now() - bankAnnouncedAt < 30 then return end
    bankAnnouncedAt = now()
    hello({ kind = "GUILD" }, "g")
end

---------------------------------------------------------------------------
-- Switching sharing on and off
---------------------------------------------------------------------------
local function setShare(scope, value)
    local s = ns.char and ns.char.share
    if type(s) ~= "table" or SCOPE_OF[scope] == nil then return end
    value = value and true or false
    if s[scope] == value then return end
    s[scope], s.at = value, time()
    forgetSections()
    purgeQueued()
    local inGuild = str(call(GetGuildInfo, "player")) ~= nil
    if not value then
        -- Those who had it are told to forget it. Anyone who saw it publicly forgets it within two
        -- weeks, and nobody new gets it.
        if scope == "guild" and inGuild then send({ kind = "GUILD" }, { t = "bye", sc = "g" }, true) end
        if scope == "friends" then
            for _, f in ipairs(onlineFriends()) do send(f.route, { t = "bye", sc = "f" }, true) end
        end
    end
    -- Whoever still sees something hears what that is now, and asks again for what they lost.
    if started then helloAll(false) end
    changed()
end
ns.setShare = setShare

-- Shows or hides one part to one scope. Those who see it hear at once, so a part switched off
-- leaves them straight away; anyone who saw it publicly forgets it within two weeks.
local function setPart(part, scope, value)
    local s = ns.char and ns.char.share
    local l = SCOPE_OF[scope]
    if type(s) ~= "table" or not PART_NAMES[part] or not l then return end
    local cur = partLetters(part)
    if (cur:find(l, 1, true) ~= nil) == (value and true or false) then return end
    local new = ""
    for _, x in ipairs({ "g", "f", "p" }) do
        if (x == l and value) or (x ~= l and cur:find(x, 1, true)) then new = new .. x end
    end
    s.parts = type(s.parts) == "table" and s.parts or {}
    s.parts[part], s.at = new, time()
    forgetSections()
    purgeQueued()
    if started then helloAll(false) end
    changed()
end
ns.setPart = setPart

local function shareLine()
    local s = shares()
    local function word(k) return s[k] and "|cff5fb87aon|r" or "|cff8b7e6doff|r" end
    return format("%s%s shares with: guild %s, friends %s, public %s.", ns.TAG, ns.char and ns.char.name or "?", word("guild"), word("friends"), word("public"))
end

-- What each scope sees, in one line: "Gold: guild", "Bags: nobody".
local function partsLine()
    local bits = {}
    for _, part in ipairs(PARTS) do
        local who = {}
        for _, scope in ipairs({ "guild", "friends", "public" }) do
            if partLetters(part):find(SCOPE_OF[scope], 1, true) then who[#who + 1] = scope end
        end
        bits[#bits + 1] = format("%s: %s", PART_NAMES[part], #who > 0 and table.concat(who, ", ") or "|cff8b7e6dnobody|r")
    end
    return ns.TAG .. "What each sees. " .. table.concat(bits, "; ") .. "."
end

ns.shareCommand = function(rest)
    local words = {}
    for w in (rest or ""):lower():gmatch("%S+") do words[#words + 1] = w end
    local first, second, third = words[1] or "", words[2] or "", words[3] or ""
    local part = PART_WORDS[first]
    if part then
        -- /rq share gold [guild|friends|public|all] [on|off]
        local scopes = SCOPE_OF[second] and { second } or { "guild", "friends", "public" }
        local value = (SCOPE_OF[second] and third or second)
        if value ~= "on" and value ~= "off" then
            local any = false
            for _, sc in ipairs(scopes) do if partLetters(part):find(SCOPE_OF[sc], 1, true) then any = true end end
            value = any and "off" or "on"
        end
        for _, sc in ipairs(scopes) do setPart(part, sc, value == "on") end
        print(partsLine())
        return
    end
    if first == "off" or first == "none" then
        for k in pairs(SCOPE_OF) do setShare(k, false) end
    elseif SCOPE_OF[first] then
        local s = shares()
        if second == "on" then setShare(first, true)
        elseif second == "off" then setShare(first, false)
        else setShare(first, not s[first]) end
    elseif first == "parts" or first == "what" then
        print(partsLine())
        return
    elseif first ~= "" then
        print(ns.TAG .. "/rq share guild, friends or public switches who sees this character. /rq share gold, bags, place (and the other parts) switches what they see, for everyone or add guild, friends or public. /rq share off stops all.")
        return
    end
    print(shareLine())
    if first == "" then
        print(partsLine())
        print(ns.TAG .. "/rq share guild, friends or public switches one; /rq share gold off (or bags guild on, and so on) chooses what they see. Each character chooses for itself.")
    end
    if not ns.canShare() then print(ns.TAG .. "This game client can't pack messages for other players, so nothing is sent yet.") end
end

---------------------------------------------------------------------------
-- Looking players up: when you target one, and with /rq look <name>
---------------------------------------------------------------------------
local lookedAt, lookCount = -math.huge, 0

local function ask(who, explicit)
    if not who or who == me() then return false end
    local route = { kind = "WHISPER", target = who }
    asked[who] = now()
    hello(route, scopesFor(who, route), true)
    if explicit then
        looking[who] = true
        if C_Timer then
            C_Timer.After(15, function()
                if looking[who] then
                    looking[who] = nil
                    print(format("%sNothing from %s yet: they may not use Reliquary, may not share with you, or may be offline.", ns.TAG, shortName(who)))
                end
            end)
        end
    end
    return true
end

ns.lookCommand = function(rest)
    local name = str(rest and rest:match("^%s*(.-)%s*$"))
    if not name then
        print(ns.TAG .. (regional() and "/rq look <full name>" or "/rq look <name>") .. " asks a player what they share. They answer if they share with you.")
        return
    end
    local who
    if regional() then
        -- Forever's names are "Given Family": both, as /rq look Thalia Moonwhisper.
        local words = {}
        for w in name:gsub("%-", " "):gmatch("%S+") do words[#words + 1] = w:sub(1, 1):upper() .. w:sub(2):lower() end
        if #words ~= 2 then
            print(ns.TAG .. "/rq look takes a full name, as /rq look Thalia Moonwhisper.")
            return
        end
        who = fullName(words[1] .. " " .. words[2])
    else
        local n, realm = name:match("^([^%-]+)%-?(.*)$")
        n = n:sub(1, 1):upper() .. n:sub(2):lower()
        who = fullName(realm ~= "" and (n .. "-" .. realm) or n)
    end
    if ask(who, true) then print(format("%sAsked %s. If they share with you, it arrives in a moment.", ns.TAG, shortName(who))) end
end

on("PLAYER_TARGET_CHANGED", function()
    if not (ns.isLoggedIn() and ns.db) or ns.db.settings.discover == false or not quiet() then return end
    if plain(call(UnitIsPlayer, "target")) ~= true or plain(call(UnitIsUnit, "target", "player")) == true then return end
    local theirs, mine = plain(call(UnitFactionGroup, "target")), plain(call(UnitFactionGroup, "player"))
    if not theirs or theirs ~= mine then return end -- whispers don't cross factions
    local who = unitName("target")
    if not who then return end
    local t = now()
    if not who or asked[who] or lookCount >= LOOK_MAX or t - lookedAt < LOOK_GAP then return end
    lookedAt, lookCount = t, lookCount + 1
    ask(who, false)
end)

---------------------------------------------------------------------------
-- Keeping what others share tidy
---------------------------------------------------------------------------
local function prune()
    local list = peers()
    local t = time()
    local rosters = {}
    local count = 0
    for who, p in pairs(list) do
        if type(p) ~= "table" or type(p.scopes) ~= "table" then
            list[who] = nil
        else
            for l, limit in pairs(KEEP) do
                if p.scopes[l] and t - p.scopes[l] > limit then p.scopes[l] = nil end
            end
            -- A guildmate's card counts only while they are still in that guild's roster.
            local g = p.scopes.g and p.gk and ns.db.guilds[p.gk]
            if p.scopes.g and not g then p.scopes.g = nil end
            if g and type(g.members) == "table" and #g.members > 0 then
                local names = rosters[p.gk]
                if not names then
                    names = {}
                    for _, m in ipairs(g.members) do if type(m) == "table" and m.n then names[fullName(m.n)] = true end end
                    rosters[p.gk] = names
                end
                if not names[who] then p.scopes.g = nil end
            end
            if next(p.scopes) then count = count + 1 else list[who] = nil end
        end
    end
    if count > MAX_PEERS then
        -- Too many: forget the ones met longest ago, public first.
        local order = {}
        for who, p in pairs(list) do order[#order + 1] = { who = who, keep = (p.scopes.g or p.scopes.f) and 1 or 0, seen = p.seen or 0 } end
        table.sort(order, function(a, b) if a.keep ~= b.keep then return a.keep < b.keep end return a.seen < b.seen end)
        for i = 1, count - MAX_PEERS do list[order[i].who] = nil end
    end
end
ns.prunePeers = prune

---------------------------------------------------------------------------
-- Options > AddOns > Reliquary
---------------------------------------------------------------------------
local function registerSettings()
    local S = Settings
    if not (S and S.RegisterVerticalLayoutCategory and S.RegisterProxySetting and S.CreateCheckbox and S.RegisterAddOnCategory) then return end
    local category = S.RegisterVerticalLayoutCategory("Reliquary")
    local boolean = (S.VarType and S.VarType.Boolean) or "boolean"
    local function add(variable, label, tooltip, default, get, set)
        local setting = S.RegisterProxySetting(category, "RELIQUARY_" .. variable, boolean, label, default, get, set)
        S.CreateCheckbox(category, setting, tooltip)
    end
    add("SHARE_GUILD", "Share with my guild",
        "Guildmates who use Reliquary see this character, as you choose under What others see, and the guild bank as you last saw it.",
        true, function() return shares().guild == true end, function(v) setShare("guild", v) end)
    add("SHARE_FRIENDS", "Share with my friends",
        "Friends on your friends list and Battle.net friends playing WoW: Forever see this character, as you choose under What others see.",
        true, function() return shares().friends == true end, function(v) setShare("friends", v) end)
    add("SHARE_PUBLIC", "Share with anyone",
        "Any player who uses Reliquary can ask for this character, for example by targeting you, and sees what you choose under What others see.",
        false, function() return shares().public == true end, function(v) setShare("public", v) end)
    add("DISCOVER", "Ask players I target",
        "When you target a player, Reliquary asks whether they share with you. They see nothing unless they use Reliquary.",
        true, function() return ns.db.settings.discover ~= false end, function(v) ns.db.settings.discover = v and true or false end)
    add("AUTO_PHOTOS", "Take photos automatically",
        "New places, level-ups and a portrait while you rest. /rq photo and /rq portrait work either way.",
        true, function() return ns.db.settings.autoPhoto ~= false end, function(v) ns.db.settings.autoPhoto = v and true or false end)
    add("MINIMAP_BUTTON", "Show the minimap button",
        "A button on the edge of the minimap: click it to open the Reliquary window, right-click for Sharing, and drag it around the edge. Reliquary is in the minimap's Addons menu either way.",
        true, function() return ns.db.settings.minimapButton ~= false end, function(v)
            ns.db.settings.minimapButton = v and true or false
            if ns.updateMinimapButton then ns.updateMinimapButton() end
        end)
    -- What each of them sees: the same grid as the Sharing tab of /rq.
    if ns.makeShareMatrix and S.RegisterCanvasLayoutSubcategory then
        local canvas = CreateFrame("Frame")
        local matrix = ns.makeShareMatrix(canvas)
        canvas:SetScript("OnShow", function() matrix.refresh() end)
        S.RegisterCanvasLayoutSubcategory(category, canvas, "What others see")
        ns.settingsMatrix = matrix
    end
    S.RegisterAddOnCategory(category)
    ns.settingsCategory = category
end

---------------------------------------------------------------------------
-- Start
---------------------------------------------------------------------------
on("PLAYER_LOGIN", function()
    if not ns.db then return end
    call(api("C_ChatInfo.RegisterAddonMessagePrefix"), PREFIX)
    pcall(registerSettings)
    prune()
    if C_Timer and C_Timer.NewTicker then
        C_Timer.NewTicker(0.25, function() readTips() pump() end)
        C_Timer.NewTicker(10, sweepPartials)
    end
    if C_Timer then
        C_Timer.After(8, function()
            -- Once: for characters from before sharing, that it exists; for a new character, who it
            -- shares with.
            local news, fresh = ns.db.settings.sharingNews, ns.char and ns.char.shareNews
            ns.db.settings.sharingNews = nil
            if ns.char then ns.char.shareNews = nil end
            if news then print(ns.TAG .. "You can now share this character with your guild, your friends or everyone, and see what they share with /rq.") end
            if news or fresh then print(shareLine() .. ((news and not fresh) and " Guild and friends start off." or "") .. " /rq share to choose.") end
        end)
        C_Timer.After(20, greet)
    end
end)

on("CHAT_MSG_ADDON", function(prefix, text, channel, sender)
    if prefix ~= PREFIX or not ns.db or (channel ~= "GUILD" and channel ~= "WHISPER") then return end
    local who = fullName(sender)
    receive(text, channel == "GUILD" and { kind = "GUILD" } or { kind = "WHISPER", target = who }, who)
end)

on("BN_CHAT_MSG_ADDON", function(prefix, text, _, senderID)
    if prefix ~= PREFIX or not ns.db or not num(senderID) then return end
    local ga = call(api("C_BattleNet.GetGameAccountInfoByID"), senderID)
    local name = type(ga) == "table" and str(ga.characterName)
    if not name then return end
    local who = fullName(name .. (str(ga.realmName) and ("-" .. str(ga.realmName)) or ""))
    receive(text, { kind = "BN", target = senderID }, who)
end)

-- Friends who come online, and a guild you join, hear hello once.
local friendsQueued = false
local function friendsChanged()
    if friendsQueued or not C_Timer or not started then return end
    friendsQueued = true
    C_Timer.After(5, function() friendsQueued = false greetFriends() end)
end
on("FRIENDLIST_UPDATE", friendsChanged)
on("BN_FRIEND_ACCOUNT_ONLINE", friendsChanged)
on("BN_FRIEND_INFO_CHANGED", friendsChanged)
on("PLAYER_GUILD_UPDATE", function()
    if not str(call(GetGuildInfo, "player")) then guildGreeted = false return end
    if ns.isLoggedIn() and ns.db and C_Timer then C_Timer.After(5, greetGuild) end
end)

-- For the window: lists of what others share.
ns.peerList = function(letter)
    local out = {}
    for who, p in pairs(peers()) do
        if type(p) == "table" and type(p.scopes) == "table" and (not letter or p.scopes[letter]) then out[#out + 1] = p end
    end
    table.sort(out, function(a, b) return (a.name or a.key) < (b.name or b.key) end)
    return out
end
ns.askPlayer = function(who) return ask(fullName(who), true) end
