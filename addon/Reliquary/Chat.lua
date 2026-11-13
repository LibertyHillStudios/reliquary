-- Reliquary chat: your guild's chat, its officer chat and your whispers, kept as the game showed
-- them, to read back, search and answer in the window. Guild chat (the guild's own lines, those
-- from the guild's Discord and its achievements, the three the game's chat shows for a guild) is
-- kept under the guild, and officer chat beside it for a character the game lets hear it; a
-- whisper, either way, under the player on the other end: a character by name, a Battle.net
-- friend by BattleTag. None of it leaves this computer: nothing here is sent to another player's
-- Reliquary, shared or shown on the public copy. A line the game hides (censored) or keeps secret
-- isn't kept. What is sent is only what you type and send yourself, as the game's own chat box
-- sends it.
local ADDON, ns = ...

local call, num, str, api, on = ns.call, ns.num, ns.str, ns.api, ns.on
local type, pairs, ipairs, tremove, tinsert, time, floor, abs, format = type, pairs, ipairs, table.remove, table.insert, time, math.floor, math.abs, string.format

local GUILD_MAX = 5000     -- lines kept for one guild; the oldest go first
local WHISPER_MAX = 1000   -- lines kept with one player
local PEOPLE_MAX = 400     -- players whose whispers are kept: the most recent conversations
local LINE_MAX = 1024      -- characters kept of one line (the game's own stop at 255)
-- What the game's chat box holds (ChatFrameEditBoxTemplate): 255 bytes you see, 1,280 with links.
local SEND_BYTES, SEND_VISIBLE = 1280, 255

local function store(kind)
    local db = ns.db
    if type(db) ~= "table" then return nil end
    if type(db[kind]) ~= "table" then db[kind] = {} end
    return db[kind]
end

local function changed(kind)
    if ns.dataChanged then pcall(ns.dataChanged, kind) end
end

-- When a line was said: the game's server clock, the one its chat history is stamped with (as its
-- own Communities window compares them), so a line kept live and the server's copy agree even when
-- this computer's clock is off.
local function now() return num(call(GetServerTime)) or time() end

-- A line as the game gave it, or nil when the game keeps it secret or hides it.
local function lineText(text, lineID)
    text = str(text)
    if not text then return nil end
    if num(lineID) and call(api("C_ChatInfo.IsChatLineCensored"), num(lineID)) == true then return nil end
    return text:sub(1, LINE_MAX)
end

-- A player's class from the GUID the game sends with what they said.
local function classOf(guid)
    guid = str(guid)
    if not guid then return nil end
    local _, cls = call(GetPlayerInfoByGUID, guid)
    return str(cls)
end

local function keep(list, rec, cap)
    list[#list + 1] = rec
    while #list > cap do tremove(list, 1) end
end

---------------------------------------------------------------------------
-- Guild chat
---------------------------------------------------------------------------
local guildList -- below: one of the current guild's lists of lines ("list", or "officer"), made when first needed

local function guildLine(rec, which)
    local list = guildList(which)
    if not list then return end
    keep(list, rec, GUILD_MAX)
    changed("chat")
end

-- Whether a line is from someone on the guild's Discord, as the game's chat window decides it.
local function discordUser(info) return type(info) == "table" and (num(info.userID) or 0) ~= 0 end

-- What the game's chat shows of a Discord line: it marks what it can't show (a picture, a poll).
local function discordWords(info, m)
    local util = ChatFrameUtil
    if type(util) == "table" and type(util.FormatDiscordMessage) == "function" then
        m = str(call(util.FormatDiscordMessage, info, m)) or m
    end
    return m:sub(1, LINE_MAX)
end

-- A line said in the guild (kind nil) or in its Discord channel (kind "d"), or in officer chat
-- (which "officer"): by a player in the game, or by someone on the guild's Discord, under the name
-- Discord gives them and the character they last played when the game knows it.
local function said(text, sender, lineID, guid, info, kind, which)
    local m = lineText(text, lineID)
    if not m then return end
    local rec = { t = now(), m = m, k = kind }
    if discordUser(info) then
        local played = str(info.lastOnlineName)
        rec.m, rec.d = discordWords(info, m), str(info.globalName) or str(sender)
        rec.n, rec.c = played and ns.fullName(played) or nil, classOf(info.lastOnlineGUID)
        if not (rec.d or rec.n) then return end
    else
        rec.n, rec.c = ns.fullName(sender), classOf(guid)
        if not rec.n then return end
    end
    guildLine(rec, which)
end

on("CHAT_MSG_GUILD", function(text, sender, _, _, _, _, _, _, _, _, lineID, guid, _, _, _, _, _, info)
    said(text, sender, lineID, guid, info)
end)
on("CHAT_MSG_GUILD_DISCORD", function(text, sender, _, _, _, _, _, _, _, _, lineID, guid, _, _, _, _, _, info)
    said(text, sender, lineID, guid, info, "d")
end)
-- Officer chat: the game sends it only to a character whose rank may hear it.
on("CHAT_MSG_OFFICER", function(text, sender, _, _, _, _, _, _, _, _, lineID, guid, _, _, _, _, _, info)
    said(text, sender, lineID, guid, info, nil, "officer")
end)

-- An achievement: the game's line has a %s where the name goes.
on("CHAT_MSG_GUILD_ACHIEVEMENT", function(text, sender, _, _, _, _, _, _, _, _, lineID, guid)
    local m = lineText(text, lineID)
    local who = m and ns.fullName(sender)
    if not who then return end
    guildLine({ t = now(), n = who, c = classOf(guid), m = m, k = "a" })
end)

---------------------------------------------------------------------------
-- What the guild said while you were away. The game keeps a guild's chat on its servers (a
-- Communities stream, as the game's own Guild & Communities window shows it when you scroll up):
-- after each login Reliquary asks for the newest of it the way that window asks, a batch at a
-- time, and each line joins those kept here in time order, once. Only the speaker's name, class and
-- words are read; the game's notes about members (officer notes included) are never read.
---------------------------------------------------------------------------
local BATCH = 100           -- lines asked for at once, as the game's own window asks
local BATCHES = 10          -- batches asked for after a login, newest first
local SAME_LINE = 300       -- seconds within which a line kept live and the server's are the same line
-- Enum.ClubStreamType: the guild's chat, its officer chat (the game lists it only for a character
-- whose rank may read it) and its Discord's; the list each joins, and the kind of its lines.
local STREAMS = { [1] = { list = "list" }, [2] = { list = "officer" }, [3] = { list = "list", kind = "d" } }

-- A message the server kept, as a line here, or nil when it can't be read. One taken down on the
-- server (moderated, or deleted by who said it) comes back marked gone, to be taken out here too.
local function fromServer(msg, kind)
    if type(msg) ~= "table" then return nil end
    local id = type(msg.messageId) == "table" and msg.messageId
    local epoch = id and num(id.epoch)
    if not epoch then return nil end
    local rec = { t = floor(epoch / 1e6), id = format("%.0f:%.0f", epoch, num(id.position) or 0), gone = msg.destroyed == true or nil }
    local m = str(msg.content)
    if not m then return rec.gone and rec or nil end
    local a = type(msg.author) == "table" and msg.author or {}
    local info = num(a.classID) and call(api("C_CreatureInfo.GetClassInfo"), num(a.classID))
    rec.c, rec.k, rec.m = type(info) == "table" and str(info.classFile) or nil, kind == "d" and "d" or nil, m:sub(1, LINE_MAX)
    local d = a.discordInfo
    if discordUser(d) then -- as the line kept live has it
        local played = str(d.lastOnlineName)
        rec.m, rec.d = discordWords(d, m), str(d.globalName) or str(a.name)
        rec.n = played and ns.fullName(played) or nil
        if not (rec.d or rec.n) then return rec.gone and rec or nil end
        return rec
    end
    rec.n = ns.fullName(a.name)
    if not rec.n then return rec.gone and rec or nil end
    -- A given name alone: the guild member it is, when only one has it.
    if ns.regional and ns.regional() and not rec.n:find(" ", 1, true) then
        local gk = ns.guildKey and ns.guildKey()
        local g = gk and ns.db and type(ns.db.guilds) == "table" and ns.db.guilds[gk]
        local found
        for _, member in ipairs(type(g) == "table" and type(g.members) == "table" and g.members or {}) do
            local full = type(member) == "table" and ns.fullName(member.n)
            if full and full:sub(1, #rec.n + 1) == rec.n .. " " then
                if found then found = nil break end
                found = full
            end
        end
        rec.n = found or rec.n
    end
    return rec
end

-- Two names for one speaker: the same, or a given name alone (the server may give only that, when
-- two members have it) and a full name that begins with it. Two full names that differ are two
-- players, whatever their given names.
local function sameSpeaker(a, b)
    if a == b then return true end
    if type(a) ~= "string" or type(b) ~= "string" then return false end
    if a:find("[%s%-]") then a, b = b, a end -- a: the given name alone, when either is
    return not a:find("[%s%-]") and b:lower():sub(1, #a + 1) == a:lower() .. " "
end

-- A line from the server joins the list: the same line kept already (live, or asked for before)
-- only gets the server's mark; a new one goes where its time puts it. When the list is full,
-- nothing older than its oldest line is added. A line the server took down leaves the list.
-- Whether the list changed.
local function merge(list, rec)
    local lo, hi = 1, #list + 1
    while lo < hi do -- the first line said after this one
        local mid = floor((lo + hi) / 2)
        if (num(list[mid] and list[mid].t) or 0) <= rec.t then lo = mid + 1 else hi = mid end
    end
    for _, step in ipairs({ -1, 1 }) do
        local i = step < 0 and lo - 1 or lo
        while list[i] and abs((num(list[i].t) or 0) - rec.t) <= SAME_LINE do
            local r = list[i]
            if r.id == rec.id or (not r.id and rec.m and r.m == rec.m and r.k == rec.k and r.d == rec.d and sameSpeaker(r.n, rec.n)) then
                if rec.gone then tremove(list, i) return true end
                r.id = rec.id
                return false
            end
            i = i + step
        end
    end
    if rec.gone or (#list >= GUILD_MAX and lo == 1) then return false end
    tinsert(list, lo, rec)
    while #list > GUILD_MAX do tremove(list, 1) end
    return true
end

local asked = {} -- each guild stream asked of after this login: its club, stream, list, kind and batches

function guildList(which)
    local gk = ns.guildKey and ns.guildKey()
    local chat = gk and store("chat")
    if not chat then return nil end
    local g = type(chat[gk]) == "table" and chat[gk] or {}
    chat[gk] = g
    which = which or "list"
    if type(g[which]) ~= "table" then g[which] = {} end
    return g[which]
end

-- Everything the game has downloaded of a stream, into its list.
local function readStream(s)
    local list = guildList(s.list)
    if not list then return end
    local news = false
    for _, range in ipairs(call(api("C_Club.GetMessageRanges"), s.club, s.stream) or {}) do
        if type(range) == "table" then
            for _, msg in ipairs(call(api("C_Club.GetMessagesInRange"), s.club, s.stream, range.oldestMessageId, range.newestMessageId) or {}) do
                local rec = fromServer(msg, s.kind)
                if rec and merge(list, rec) then news = true end
            end
        end
    end
    if news then changed("chat") end
end

-- Asks for the batch before the oldest line the game has of a stream (the newest, the first time).
local function askOlder(s)
    if s.batches >= BATCHES then return end
    local oldest
    for _, range in ipairs(call(api("C_Club.GetMessageRanges"), s.club, s.stream) or {}) do
        local o = type(range) == "table" and type(range.oldestMessageId) == "table" and range.oldestMessageId
        if o and (not oldest or (num(o.epoch) or 0) < (num(oldest.epoch) or 0)) then oldest = o end
    end
    if s.batches > 0 and oldest and s.oldest and (num(oldest.epoch) or 0) >= s.oldest then return end -- the server has nothing older
    s.oldest = oldest and num(oldest.epoch) or nil
    s.batches = s.batches + 1
    local already = call(api("C_Club.RequestMoreMessagesBefore"), s.club, s.stream, s.batches > 1 and oldest or nil, BATCH)
    if already == true then
        readStream(s)
        askOlder(s)
    end
end

local function backfill()
    local club = call(api("C_Club.GetGuildClubId"))
    if not club or not (ns.guildKey and ns.guildKey()) then return end
    for _, info in ipairs(call(api("C_Club.GetStreams"), club) or {}) do
        local known = type(info) == "table" and STREAMS[num(info.streamType) or -1]
        if known and info.streamId ~= nil then
            local key = tostring(club) .. "/" .. tostring(info.streamId)
            if not asked[key] then
                asked[key] = { club = club, stream = info.streamId, list = known.list, kind = known.kind, batches = 0 }
                askOlder(asked[key])
            end
        end
    end
end

on("CLUB_MESSAGE_HISTORY_RECEIVED", function(club, stream)
    local s = asked[tostring(club) .. "/" .. tostring(stream)]
    if not s then return end
    readStream(s)
    askOlder(s)
end)
-- The guild's streams arrive a moment after login; asked again, a stream already asked of isn't.
on("INITIAL_CLUBS_LOADED", backfill)
on("CLUB_STREAMS_LOADED", backfill)
on("PLAYER_GUILD_UPDATE", backfill)
on("GUILD_ROSTER_UPDATE", backfill)
ns.chatBackfill = backfill

-- Your guild's lines, oldest first; its officer chat's.
ns.guildChat = function(gk, which)
    local chat = ns.db and ns.db.chat
    local g = type(chat) == "table" and gk and chat[gk]
    local list = type(g) == "table" and g[which or "list"]
    return type(list) == "table" and list or {}
end
ns.officerChat = function(gk) return ns.guildChat(gk, "officer") end

-- Whether this character may hear its guild's officer chat: the game lists the guild's officer
-- stream only for a rank that may read it; until the guild's streams have arrived, its rank says.
ns.canSeeOfficerChat = function()
    if not (ns.guildKey and ns.guildKey()) then return false end
    local club = call(api("C_Club.GetGuildClubId"))
    local streams = club and call(api("C_Club.GetStreams"), club)
    if type(streams) == "table" and #streams > 0 then
        for _, info in ipairs(streams) do
            if type(info) == "table" and num(info.streamType) == 2 then return true end
        end
        return false
    end
    return call(api("C_GuildInfo.IsGuildOfficer")) == true
end

---------------------------------------------------------------------------
-- Whispers
---------------------------------------------------------------------------
local function whisperLine(who, rec, cls)
    local all = store("whispers")
    if not (all and who) then return end
    local p = all[who]
    if type(p) ~= "table" then
        -- A new conversation: the one longest quiet goes when there are too many.
        local n, oldest, oldestAt = 0, nil, nil
        for k, q in pairs(all) do
            n = n + 1
            local at = type(q) == "table" and num(q.at) or 0
            if not oldestAt or at < oldestAt then oldest, oldestAt = k, at end
        end
        if n >= PEOPLE_MAX and oldest then all[oldest] = nil end
        p = { list = {} }
        all[who] = p
    end
    if type(p.list) ~= "table" then p.list = {} end
    p.at = rec.t
    p.c = cls or p.c
    keep(p.list, rec, WHISPER_MAX)
    changed("whisper")
end

on("CHAT_MSG_WHISPER", function(text, sender, _, _, _, _, _, _, _, _, lineID, guid)
    local m = lineText(text, lineID)
    local who = m and ns.fullName(sender)
    if not who then return end
    local cls = classOf(guid)
    whisperLine(who, { t = now(), m = m, c = cls, w = ns.me and ns.me() }, cls)
end)

-- One you sent: the game names whom it went to.
on("CHAT_MSG_WHISPER_INFORM", function(text, target, _, _, _, _, _, _, _, _, lineID, guid)
    local m = lineText(text, lineID)
    local who = m and ns.fullName(target)
    if not who then return end
    local _, mine = call(UnitClass, "player")
    whisperLine(who, { t = now(), m = m, o = 1, c = str(mine), w = ns.me and ns.me() }, classOf(guid))
end)

-- Battle.net whispers, kept under the friend's BattleTag ("bn:Name#1234"): the game names them in
-- chat by a protected string an addon can neither read nor keep, and their account's number changes
-- with each session. With them, the class of the character they were playing, when they were.
local function bnFriend(id)
    local info = num(id) and call(api("C_BattleNet.GetAccountInfoByID"), num(id))
    local tag = type(info) == "table" and str(info.battleTag)
    if not tag then return nil end
    local game = type(info.gameAccountInfo) == "table" and info.gameAccountInfo or {}
    return "bn:" .. tag, str(game.classFilename)
end

on("CHAT_MSG_BN_WHISPER", function(text, _, _, _, _, _, _, _, _, _, lineID, _, bnID)
    local m = lineText(text, lineID)
    local who, cls = bnFriend(m and bnID)
    if not who then return end
    whisperLine(who, { t = now(), m = m, c = cls, w = ns.me and ns.me() }, cls)
end)

on("CHAT_MSG_BN_WHISPER_INFORM", function(text, _, _, _, _, _, _, _, _, _, lineID, _, bnID)
    local m = lineText(text, lineID)
    local who, cls = bnFriend(m and bnID)
    if not who then return end
    local _, mine = call(UnitClass, "player")
    whisperLine(who, { t = now(), m = m, o = 1, c = str(mine), w = ns.me and ns.me() }, cls)
end)

-- A Battle.net friend's account, from their BattleTag, while they're on your Battle.net friends list.
local function bnAccount(who)
    local tag = type(who) == "string" and who:match("^bn:(.+)$")
    if not tag then return nil end
    local get = api("C_BattleNet.GetFriendAccountInfo")
    for i = 1, num(call(BNGetNumFriends)) or 0 do
        local info = call(get, i)
        if type(info) == "table" and str(info.battleTag) == tag then return num(info.bnetAccountID) end
    end
end

-- Your whispers with a player (or a Battle.net friend), oldest first, and their class as last seen.
-- Given more names for the same person (a Battle.net friend's BattleTag and the character they play),
-- the whispers kept under each, in time order as one conversation, and for each line the name it
-- was kept under.
ns.whispersWith = function(who, ...)
    local all = ns.db and ns.db.whispers
    if select("#", ...) == 0 then
        local p = type(all) == "table" and who and all[who]
        if type(p) ~= "table" or type(p.list) ~= "table" then return {}, nil end
        return p.list, str(p.c)
    end
    if type(all) ~= "table" then return {}, nil, {} end
    local lists, seen, cls, latest = {}, {}, nil, nil
    for i = 1, select("#", ...) + 1 do
        local key = i == 1 and who or select(i - 1, ...)
        local p = type(key) == "string" and not seen[key] and all[key]
        if type(key) == "string" then seen[key] = true end
        if type(p) == "table" and type(p.list) == "table" and #p.list > 0 then
            lists[#lists + 1] = { key = key, list = p.list, at = 1 }
            local at = num(p.at) or 0
            if str(p.c) and (not latest or at > latest) then cls, latest = str(p.c), at end
        end
    end
    -- Each list is in time order: the earliest line at the head of any of them goes next.
    local out, under = {}, {}
    while true do
        local best, bestT
        for _, l in ipairs(lists) do
            local r = l.list[l.at]
            local t = r ~= nil and (type(r) == "table" and num(r.t) or 0) or nil
            if t and (not bestT or t < bestT) then best, bestT = l, t end
        end
        if not best then break end
        local r = best.list[best.at]
        best.at = best.at + 1
        out[#out + 1] = r
        if type(r) == "table" then under[r] = best.key end
    end
    return out, cls, under
end

---------------------------------------------------------------------------
-- Sending what you type, as the game's chat box does
---------------------------------------------------------------------------
-- To a chat (chatType, with its target for a whisper), or as a Battle.net whisper (bnID).
local function send(text, chatType, target, bnID)
    text = str(text)
    text = text and text:match("^%s*(.-)%s*$")
    if not text or text == "" then return false, "empty" end
    if #text > SEND_BYTES then return false, "long" end -- more than the game's chat box holds: never cut short
    if call(api("C_ChatInfo.InChatMessagingLockdown")) == true then return false, "lockdown" end
    if bnID then
        local fn = api("C_BattleNet.SendWhisper")
        if type(fn) ~= "function" then return false, "unavailable" end
        local ok, sent = pcall(fn, bnID, text)
        if not ok or sent == false then return false, "failed" end
        return true
    end
    local fn = api("C_ChatInfo.SendChatMessage") or SendChatMessage
    if type(fn) ~= "function" then return false, "unavailable" end
    local ok = pcall(fn, text, chatType, nil, target)
    if not ok then return false, "failed" end
    return true
end

ns.sendGuildChat = function(text)
    if not (ns.guildKey and ns.guildKey()) then return false, "noguild" end
    return send(text, "GUILD")
end

ns.sendOfficerChat = function(text)
    if not ns.canSeeOfficerChat() then return false, "notofficer" end
    return send(text, "OFFICER")
end

-- A whisper to a character, or to a Battle.net friend by their BattleTag ("bn:Name#1234").
ns.sendWhisper = function(who, text)
    who = str(who)
    if not who then return false, "nobody" end
    if who:find("^bn:") then
        local id = bnAccount(who)
        if not id then return false, "nobnet" end
        return send(text, nil, nil, id)
    end
    return send(text, "WHISPER", who)
end

ns.CHAT_SEND_BYTES, ns.CHAT_SEND_VISIBLE = SEND_BYTES, SEND_VISIBLE
