-- Who in the guild can use an item, and who it helps most: for each item that could change hands
-- (the guild bank's, spares guildmates show in their bags, items linked in guild chat), so the
-- guild can hand gear to whoever it helps.
--
-- Each player's own game judges for its own character, because it knows best: whether the
-- character can use the item (the game marks in red whatever it can't, a level still to reach
-- included), whether it suits the character's spec (Blizzard's own list of which specs an item is
-- for, or else the spec's main stat), and whether it beats what the character wears in that slot
-- (the game's own comparison of two items, and item level; for rings, trinkets and weapons for two
-- hands, the weaker of the two). The verdicts go to the guild with the gear the player already
-- shares with it (the "fits" section of their card). For a guildmate whose game hasn't judged an
-- item yet, yours judges from the gear, level and spec they share, with Blizzard's list of which
-- specs can use an item; when that list says nothing, they wait for their own game's answer
-- instead of a guess. Nothing here presses a key or acts in the game.
local ADDON, ns = ...

local call, num, str, plain, api, on, inCombat = ns.call, ns.num, ns.str, ns.plain, ns.api, ns.on, ns.inCombat
local pairs, ipairs, type, next, format, min, max, random = pairs, ipairs, type, next, string.format, math.min, math.max, math.random

local LEVEL_AHEAD = 5        -- an item is worth naming for someone this many levels short of it
local LINKED_KEEP = 3 * 86400 -- an item linked in guild chat is weighed this long
local LINKED_MAX = 30
local ASK_GAP = 300          -- seconds before the guild is asked again about the same item
local FITS_GAP = 300         -- seconds between two announcements of your verdicts
local ORDER = { up = 1, lvl = 2, trade = 3, no = 4 }

-- Where each kind of gear is worn (one-hand weapons in either hand only for those who can hold two).
local SLOTS = {
    INVTYPE_HEAD = { 1 }, INVTYPE_NECK = { 2 }, INVTYPE_SHOULDER = { 3 }, INVTYPE_CHEST = { 5 }, INVTYPE_ROBE = { 5 },
    INVTYPE_WAIST = { 6 }, INVTYPE_LEGS = { 7 }, INVTYPE_FEET = { 8 }, INVTYPE_WRIST = { 9 }, INVTYPE_HAND = { 10 },
    INVTYPE_FINGER = { 11, 12 }, INVTYPE_TRINKET = { 13, 14 }, INVTYPE_CLOAK = { 15 },
    INVTYPE_WEAPON = { 16, 17 }, INVTYPE_2HWEAPON = { 16 }, INVTYPE_WEAPONMAINHAND = { 16 }, INVTYPE_WEAPONOFFHAND = { 17 },
    INVTYPE_SHIELD = { 17 }, INVTYPE_HOLDABLE = { 17 }, INVTYPE_RANGED = { 18 }, INVTYPE_RANGEDRIGHT = { 18 },
    INVTYPE_THROWN = { 18 }, INVTYPE_RELIC = { 18 },
}
-- The game's numbers for a spec's main stat, and the names its item stats go by.
local PRIMARY = { [1] = "ITEM_MOD_STRENGTH_SHORT", [2] = "ITEM_MOD_AGILITY_SHORT", [4] = "ITEM_MOD_INTELLECT_SHORT" }
local SHOWN_STATS = { "ITEM_MOD_STRENGTH_SHORT", "ITEM_MOD_AGILITY_SHORT", "ITEM_MOD_INTELLECT_SHORT", "ITEM_MOD_STAMINA_SHORT",
    "ITEM_MOD_SPIRIT_SHORT", "ITEM_MOD_SPELL_POWER_SHORT", "ITEM_MOD_ATTACK_POWER_SHORT", "ITEM_MOD_CRIT_RATING_SHORT",
    "ITEM_MOD_HIT_RATING_SHORT", "RESISTANCE0_NAME" }
local STAT_WORDS = { ITEM_MOD_STRENGTH_SHORT = "Strength", ITEM_MOD_AGILITY_SHORT = "Agility", ITEM_MOD_INTELLECT_SHORT = "Intellect",
    ITEM_MOD_STAMINA_SHORT = "Stamina", ITEM_MOD_SPIRIT_SHORT = "Spirit", ITEM_MOD_SPELL_POWER_SHORT = "Spell Power",
    ITEM_MOD_ATTACK_POWER_SHORT = "Attack Power", ITEM_MOD_CRIT_RATING_SHORT = "Critical Strike", ITEM_MOD_HIT_RATING_SHORT = "Hit",
    RESISTANCE0_NAME = "Armor" }

local CI = api("C_Item") or {}
local function N(v, lo, hi) return ns.cleanNum(v, lo, hi) end
local function S(v, n) return ns.cleanStr(v, n) end

-- A guildmate as Reliquary names them in a line: "you", the name on their card, or as the guild
-- list has it.
local function callName(who)
    if who == ns.me() then return "you" end
    local p = ns.db and ns.db.peers[who]
    return type(p) == "table" and type(p.card) == "table" and str(p.card.name) or ns.shortName(who)
end
ns.callName = callName

---------------------------------------------------------------------------
-- Items
---------------------------------------------------------------------------
-- A link the game's item functions accept, from an item link or an item string.
local function linkOf(x)
    x = str(x)
    if not x then return nil end
    if x:find("|H", 1, true) then return x end
    if x:match("^item:[%-%d:]+$") then return "|H" .. x .. "|h[]|h" end
    return nil
end

local function idOf(link) return link and tonumber(link:match("item:(%d+)")) end

local function slotsOf(link)
    local _, _, _, loc = call(CI.GetItemInfoInstant or GetItemInfoInstant, link)
    loc = str(loc)
    return loc and SLOTS[loc], loc
end

local function levelOfItem(link)
    return num(call(CI.GetDetailedItemLevelInfo or GetDetailedItemLevelInfo, link)) or num(select(4, call(CI.GetItemInfo or GetItemInfo, link)))
end

local function nameOf(link)
    return (link and link:match("|h%[(.-)%]|h") ~= "" and link:match("|h%[(.-)%]|h")) or str(call(CI.GetItemInfo or GetItemInfo, link))
end

local function requiredLevel(link) return num(select(5, call(CI.GetItemInfo or GetItemInfo, link))) end

-- The game's tooltip line, from either of the two shapes the game hands it out in.
local function surface(line)
    if type(line) ~= "table" or line.leftText ~= nil or line.rightText ~= nil or type(line.args) ~= "table" then return line end
    local out = {}
    for _, a in ipairs(line.args) do
        if type(a) == "table" and a.field then out[a.field] = a.stringVal or a.colorVal or a.intVal or a.floatVal or a.boolVal end
    end
    return out
end

local function isRed(c)
    return type(c) == "table" and (num(c.r) or 0) > 0.9 and (num(c.g) or 1) < 0.25 and (num(c.b) or 1) < 0.25
end

-- "Requires Level 17", in the game's own words for this language.
local LEVEL_LINE = (str(ITEM_MIN_LEVEL) or "Requires Level %d"):gsub("([%(%)%.%[%]%*%+%-%?%^%$])", "%%%1"):gsub("%%d", "(%%d+)")
local function levelLine(text) return text and tonumber(text:match("^" .. LEVEL_LINE .. "$")) end

-- Everything weighed again a moment after an item the game was fetching arrives.
local weighQueued = false
local function weighSoon()
    if weighQueued or not C_Timer then return end
    weighQueued = true
    C_Timer.After(1, function() weighQueued = false if ns.weighUpgrades then ns.weighUpgrades(true) end end)
end

-- Whether this character can use an item, as the game's tooltip says (nothing in red), and the
-- level it still needs, if that is all; false when it can't; nil when the game didn't say. An item
-- the game is still fetching has a bare tooltip in red: it is weighed once it comes.
local function usable(link)
    local id = idOf(link)
    if id and ns.itemLoaded and not ns.itemLoaded(id, weighSoon) then return nil end
    local data = call(api("C_TooltipInfo.GetHyperlink"), link)
    if type(data) ~= "table" or type(data.lines) ~= "table" then return nil end
    local need
    for _, raw in ipairs(data.lines) do
        local line = surface(raw)
        if isRed(line.leftColor) or isRed(line.rightColor) then
            local lvl = levelLine(str(line.leftText))
            if not lvl then return false end
            need = lvl
        end
    end
    return true, need
end

-- Whether an item suits a spec: Blizzard's list of the specs an item is for, or, for an item it
-- lists none for, whether its main stats include the spec's (an item with none suits anyone).
local function suits(link, classID, specID, primary)
    local specs = call(CI.GetItemSpecInfo or GetItemSpecInfo, link)
    if type(specs) == "table" and next(specs) then
        if not specID then return nil end
        for _, s in pairs(specs) do if num(s) == specID then return true end end
        return false
    end
    local stats = call(CI.GetItemStats or GetItemStats, link)
    if type(stats) ~= "table" then return nil end
    local any = false
    for _, key in pairs(PRIMARY) do if (num(stats[key]) or 0) > 0 then any = true end end
    if not any then return true end
    local mine = primary and PRIMARY[primary]
    if not mine then return nil end
    return (num(stats[mine]) or 0) > 0
end

-- The stat changes worth naming, biggest first: { { k = "Intellect", n = 3 }, ... }.
local function changes(delta)
    local out = {}
    for _, key in ipairs(SHOWN_STATS) do
        local n = type(delta) == "table" and num(delta[key])
        if n and n ~= 0 then out[#out + 1] = { k = str(_G[key]) or STAT_WORDS[key] or key, n = n, key = key } end
    end
    table.sort(out, function(a, b) return math.abs(a.n) > math.abs(b.n) end)
    for i = #out, 4, -1 do out[i] = nil end
    for _, x in ipairs(out) do x.key = nil end
    return out
end

-- Weighs an item against what someone wears: the slot it would go in (the weaker of two), and the
-- verdict. `worn(slot)` gives the link worn there; `ok` whether the item suits them (false: they
-- can equip it but it isn't for them); `need` a level still to reach.
local function weigh(link, slots, worn, ok, primary, need)
    local il = levelOfItem(link) or 0
    local slot, cur, curIl
    for _, s in ipairs(slots) do
        local w = worn(s)
        if not w then slot, cur, curIl = s, nil, nil break end
        local wl = levelOfItem(w) or 0
        if not slot or wl < (curIl or 0) then slot, cur, curIl = s, w, wl end
    end
    local delta
    if cur then delta = call(CI.GetItemStatDelta or GetItemStatDelta, link, cur) else delta = call(CI.GetItemStats or GetItemStats, link) end
    local gain = il - (curIl or 0)
    local main = primary and PRIMARY[primary]
    local p = (main and type(delta) == "table" and num(delta[main])) or (cur and 0 or 1)
    local v
    if ok == false then v = "no"
    elseif not cur or (gain > 0 and p >= 0) or (gain >= 0 and p > 0) then v = "up"
    elseif (gain > 0 and p < 0) or (gain < 0 and p > 0) then v = "trade"
    else v = "no" end
    if v == "up" and need then v = "lvl" end
    return { v = v, sl = slot, il = il, ci = curIl, cn = cur and nameOf(cur) or nil, lv = need, d = changes(delta) }
end

-- This character's verdict on an item, or nil when it can't equip it (or the game didn't say).
local function judgeSelf(link)
    local slots = slotsOf(link)
    if not slots then return nil end
    local can, need = usable(link)
    if not can then return nil end
    local level = num(call(UnitLevel, "player")) or 0
    if need and need - level > LEVEL_AHEAD then return nil end
    if #slots == 2 and slots[1] == 16 and plain(call(CanDualWield)) ~= true then slots = { 16 } end
    local c = ns.char or {}
    local spec = type(c.spec) == "table" and c.spec or {}
    local ok = suits(link, c.classID, spec.id, spec.ps)
    return weigh(link, slots, function(s) return str(call(GetInventoryItemLink, "player", s)) end, ok, spec.ps, need)
end

-- A verdict for someone whose game hasn't weighed the item, from what they share: their class,
-- level and spec, and the gear they wear. Only when Blizzard's list says which specs can use it.
local function judgeFrom(link, card)
    if type(card) ~= "table" or not num(card.cid) or type(card.spec) ~= "table" or not num(card.spec.id) then return nil end
    local specs = call(CI.GetItemSpecInfo or GetItemSpecInfo, link)
    if not (type(specs) == "table" and next(specs)) then return nil end
    if plain(call(CI.DoesItemContainSpec or DoesItemContainSpec, link, card.cid, card.spec.id)) ~= true then return nil end
    local slots = slotsOf(link)
    if not slots then return nil end
    local gear = type(card.gear) == "table" and card.gear or {}
    if #slots == 2 and slots[1] == 16 then
        -- Two hands for one-hand weapons only for someone already holding one in the off hand.
        local off = gear[17]
        local offLoc = off and select(2, slotsOf(linkOf(off.s or off.link)))
        if offLoc ~= "INVTYPE_WEAPON" and offLoc ~= "INVTYPE_WEAPONOFFHAND" then slots = { 16 } end
    end
    local req, level = requiredLevel(link), num(card.level) or 0
    local need = req and req > level and req or nil
    if need and need - level > LEVEL_AHEAD then return nil end
    return weigh(link, slots, function(s) local g = gear[s] return g and linkOf(g.s or g.link) end, true, card.spec.ps, need)
end

---------------------------------------------------------------------------
-- What gets weighed: the guild bank, guildmates' spares, items linked in guild chat
---------------------------------------------------------------------------
local linked = {} -- [itemID] = { s = item string, at = when it was linked or asked about }

local function candidates()
    local out = {}
    local function add(x)
        local link = linkOf(x)
        local id = link and idOf(link)
        if id and not out[id] and slotsOf(link) then out[id] = link end
    end
    local g = ns.db and ns.myGuild()
    if g and type(g.bank) == "table" and type(g.bank.tabs) == "table" then
        for i, tab in pairs(g.bank.tabs) do
            if type(tab) == "table" and type(tab.slots) == "table" and ns.maySeeTab(g, i) then
                for _, it in pairs(tab.slots) do if type(it) == "table" then add(it.link or it.s) end end
            end
        end
    end
    for _, p in pairs(ns.db and ns.db.peers or {}) do
        local more = type(p) == "table" and p.scopes and p.scopes.g and type(p.more) == "table" and p.more
        if more then
            for _, name in ipairs({ "bags", "bank" }) do
                for _, bag in ipairs(type(more[name]) == "table" and type(more[name].list) == "table" and more[name].list or {}) do
                    for _, it in pairs(type(bag.s) == "table" and bag.s or {}) do
                        if type(it) == "table" and not it.bd then add(it.s) end -- a bound item can't change hands
                    end
                end
            end
        end
    end
    local t = time()
    for id, l in pairs(linked) do
        if t - l.at > LINKED_KEEP then linked[id] = nil else add(l.s) end
    end
    return out
end

---------------------------------------------------------------------------
-- Your verdicts, in your card for the guild
---------------------------------------------------------------------------
local VERDICTS = { up = true, lvl = true, trade = true, no = true }

local function wireVerdict(v)
    return { v = v.v, sl = v.sl, il = v.il, ci = v.ci, cn = v.cn, lv = v.lv, d = v.d }
end

local function cleanVerdict(x)
    if type(x) ~= "table" or not VERDICTS[x.v] then return nil end
    local out = { v = x.v, sl = N(x.sl, 1, 19), il = N(x.il, 0, 9999), ci = N(x.ci, 0, 9999), cn = S(x.cn, 80), lv = N(x.lv, 1, 999), d = {} }
    if type(x.d) == "table" then
        for i = 1, min(#x.d, 4) do
            local c = x.d[i]
            if type(c) == "table" and S(c.k, 32) and N(c.n, -1e6, 1e6) then out.d[#out.d + 1] = { k = S(c.k, 32), n = c.n } end
        end
    end
    return out
end

ns.addSection("fits", { "gear" }, FITS_GAP, function(c, letters)
    -- Only the guild hears what you would wear from its bank and its members' spares.
    if not (letters:find("g", 1, true) and ns.sees(letters, "gear")) then return nil end
    local list = {}
    for id, v in pairs(type(c.fits) == "table" and c.fits or {}) do
        local w = wireVerdict(v)
        w.id = id
        list[#list + 1] = w
    end
    table.sort(list, function(a, b) return a.id < b.id end)
    return #list > 0 and { list = list } or nil
end, function(d)
    if type(d) ~= "table" or type(d.list) ~= "table" then return nil end
    local out = {}
    for i = 1, min(#d.list, 200) do
        local x = d.list[i]
        local v = type(x) == "table" and N(x.id, 1) and cleanVerdict(x)
        if v then
            v.id = x.id
            out[#out + 1] = v
        end
    end
    return #out > 0 and { list = out } or nil
end)

-- Answers heard on the guild channel ("fit"), from guildmates whose card hasn't caught up yet.
local answers = {} -- [itemID] = { [who] = verdict }

---------------------------------------------------------------------------
-- Everyone in the guild who can equip an item
---------------------------------------------------------------------------
local function peerVerdict(p, id)
    local fits = type(p.more) == "table" and type(p.more.fits) == "table" and p.more.fits.list
    for _, v in ipairs(type(fits) == "table" and fits or {}) do
        if v.id == id then return v end
    end
end

-- Your other characters in this guild, as their saved records show them: for judging from.
local function ownCard(c)
    local gear = {}
    for slot, rec in pairs(type(c.gear) == "table" and c.gear or {}) do
        local n = tonumber(slot)
        if n and type(rec) == "table" then gear[n] = { link = rec.link } end
    end
    local sp = type(c.spec) == "table" and c.spec
    return { cid = c.classID, level = c.level, spec = sp and { id = sp.id, ps = sp.ps }, gear = gear }
end

-- Every guildmate (and your own characters here) who can equip the item: their verdict, best help
-- first. `own` says their own game weighed it; otherwise yours did, from what they share.
local function whoCanUse(id, link)
    link = linkOf(link) or (linked[id] and linkOf(linked[id].s)) or (id and linkOf("item:" .. id))
    local g = ns.db and ns.myGuild()
    if not (g and id) then return {} end
    local out, seen = {}, {}
    local function add(who, name, cls, level, v, own, me)
        if not v or seen[who] then return end
        seen[who] = true
        out[#out + 1] = { who = who, name = name, cls = cls, level = level, me = me, own = own, v = v.v, sl = v.sl, il = v.il, ci = v.ci,
            cn = v.cn, lv = v.lv, d = v.d }
    end
    -- You, as your game weighs it now.
    local me = ns.me()
    if link then add(me, ns.char and ns.char.name or ns.shortName(me), ns.char and ns.char.classFile, ns.char and ns.char.level, judgeSelf(link), true, true) end
    -- Guildmates who share with the guild: their own verdict, else one from what they share.
    for who, p in pairs(ns.db.peers) do
        if type(p) == "table" and p.scopes and p.scopes.g and p.gk == ns.guildKey() and type(p.card) == "table" then
            local c = p.card
            local v, own = peerVerdict(p, id), true
            if not v and answers[id] and answers[id][who] then v = answers[id][who] end
            if not v and link then v, own = judgeFrom(link, c), false end
            add(who, c.name or ns.shortName(who), c.classFile, c.level, v, own)
        end
    end
    -- Guildmates who asked for it from the bank: their ask carries their own game's verdict, so it
    -- counts even when they don't show the guild their gear.
    for who, x in pairs(ns.askVerdicts and ns.askVerdicts(id) or {}) do
        if not seen[who] and who ~= me then
            local m
            for _, r in ipairs(type(g.members) == "table" and g.members or {}) do
                if type(r) == "table" and r.n and ns.fullName(r.n) == who then m = r end
            end
            add(who, callName(who), m and m.cls, m and m.lv, { v = x.v, lv = x.lv }, true)
            out[#out].asked = true
        end
    end
    -- Your other characters in this guild, by full name where another of yours here has the same
    -- given name.
    local mine = type(g.mine) == "table" and g.mine or {}
    local function ownName(ck, c)
        for other in pairs(mine) do
            local o = ns.db.chars[other]
            if other ~= ck and type(o) == "table" and o.name == c.name and str(c.surname) then return c.name .. " " .. c.surname end
        end
        return c.name or ck
    end
    for ck in pairs(mine) do
        local c = ns.db.chars[ck]
        if ck ~= ns.charKey and type(c) == "table" and link then
            add("own:" .. ck, ownName(ck, c), c.classFile, c.level, judgeFrom(link, ownCard(c)), false, true)
        end
    end
    table.sort(out, function(a, b)
        if ORDER[a.v] ~= ORDER[b.v] then return ORDER[a.v] < ORDER[b.v] end
        local ga, gb = (a.il or 0) - (a.ci or 0), (b.il or 0) - (b.ci or 0)
        if ga ~= gb then return ga > gb end
        return (a.name or "") < (b.name or "")
    end)
    return out
end
ns.whoCanUse = whoCanUse

---------------------------------------------------------------------------
-- Weighing, when something changes
---------------------------------------------------------------------------
local signature -- what the last weighing looked at: your gear, level and spec, and the candidates
local function mySignature(cands)
    local parts = {}
    for s = 1, 19 do parts[#parts + 1] = str(call(GetInventoryItemLink, "player", s)) or "-" end
    local c = ns.char or {}
    parts[#parts + 1] = tostring(num(call(UnitLevel, "player")) or 0)
    parts[#parts + 1] = tostring(type(c.spec) == "table" and c.spec.id)
    local ids = {}
    for id in pairs(cands) do ids[#ids + 1] = id end
    table.sort(ids)
    parts[#parts + 1] = table.concat(ids, ",")
    for who, p in pairs(ns.db.peers) do
        if type(p) == "table" and p.scopes and p.scopes.g then parts[#parts + 1] = who .. "=" .. tostring(type(p.hashes) == "table" and (p.hashes.core or "") .. (p.hashes.fits or "")) end
    end
    table.sort(parts)
    return ns.hash(parts)
end

local function weighAll(force)
    if not (ns.db and ns.char) or inCombat() then return end
    if ns.tidyBoard then ns.tidyBoard() end
    local cands = candidates()
    local sig = mySignature(cands)
    if sig == signature and not force then return end
    signature = sig
    local fits = {}
    for id, link in pairs(cands) do
        local v = judgeSelf(link)
        if v then fits[id] = v end
    end
    local before = ns.hash(ns.char.fits or {})
    ns.char.fits = next(fits) and fits or nil
    if ns.refreshAsks then ns.refreshAsks(fits) end
    -- For the dashboard: everyone who can equip each item, as of now.
    local g = ns.myGuild()
    if g then
        local all = {}
        for id, link in pairs(cands) do
            local list = whoCanUse(id, link)
            if #list > 0 then all[id] = list end
        end
        g.fits = all
        g.fitsAt = time()
    end
    if ns.hash(ns.char.fits or {}) ~= before and ns.cardChanged then ns.cardChanged() end
    if ns.onFitsChanged then pcall(ns.onFitsChanged) end
end
ns.weighUpgrades = function(force) return pcall(weighAll, force) end

---------------------------------------------------------------------------
-- Asking the guild about one item: everyone whose game can equip it answers
---------------------------------------------------------------------------
local askedAt = {} -- [itemID] = when you last asked

ns.askWhoCanUse = function(x)
    local link = linkOf(x)
    local id = link and idOf(link)
    local s = link and link:match("|H(item:[%-%d:]+)|h")
    if not (id and s and slotsOf(link)) or not str(call(GetGuildInfo, "player")) then return false end
    linked[id] = { s = s, at = time() }
    if askedAt[id] and ns.now() - askedAt[id] < ASK_GAP then return false end
    askedAt[id] = ns.now()
    return ns.send({ kind = "GUILD" }, { t = "fit?", s = s }, true)
end

ns.handlers["fit?"] = function(msg, route, who)
    if route.kind ~= "GUILD" then return end -- the game's guild channel: only guildmates speak on it
    local s = S(msg.s, 160)
    if not (s and s:match("^item:[%-%d:]+$")) then return end
    local link = linkOf(s)
    local id = idOf(link)
    if not (id and slotsOf(link)) then return end
    linked[id] = { s = s, at = time() }
    -- Only someone who shows the guild their gear says what they would wear.
    if not (ns.shares().guild and ns.sees("g", "gear")) then return end
    local v = judgeSelf(link)
    if not v then return end
    ns.char.fits = ns.char.fits or {}
    ns.char.fits[id] = v
    if C_Timer then
        C_Timer.After(1 + random() * 3, function() ns.send({ kind = "GUILD" }, { t = "fit", s = s, f = wireVerdict(v) }) end)
    end
end

ns.handlers.fit = function(msg, route, who)
    if route.kind ~= "GUILD" then return end
    local s = S(msg.s, 160)
    local id = s and s:match("^item:[%-%d:]+$") and idOf(s)
    local v = id and cleanVerdict(msg.f)
    if not v then return end
    answers[id] = answers[id] or {}
    answers[id][who] = v
    if ns.onFitsChanged then pcall(ns.onFitsChanged) end
end

---------------------------------------------------------------------------
-- One line on the game's own item tooltips
---------------------------------------------------------------------------
-- "Tamsin and Isolde", from the last weighing: the names of everyone it helps now (but those in
-- `skip`); upgradeWords puts "Upgrade for" before them.
local function upgradeNames(id, skip)
    local g = ns.db and ns.myGuild()
    local list = g and type(g.fits) == "table" and g.fits[id]
    if type(list) ~= "table" then return nil end
    local names = {}
    for _, x in ipairs(list) do
        if x.v == "up" and not (skip and skip[x.who]) then names[#names + 1] = x.me and "you" or ns.shortName(x.name or "?") end
    end
    if #names == 0 then return nil end
    if #names > 3 then return format("%s, %s and %d more", names[1], names[2], #names - 2) end
    if #names == 1 then return names[1] end
    return table.concat(names, ", ", 1, #names - 1) .. " and " .. names[#names]
end
local function upgradeWords(id, skip)
    local names = upgradeNames(id, skip)
    return names and ("Upgrade for " .. names) or nil
end
ns.upgradeWords = upgradeWords

-- Who else has an item, for its tooltip: your other characters on this realm and side (their bags
-- and bank as last saved), the guild bank's tabs you may see, and guildmates who show the guild
-- their bags or bank. What this character carries isn't news. Counted once a second at most, and
-- only again when one of those changed.
local held, heldSig, heldAt
local function heldIndex()
    local t = num(call(GetTime)) or time()
    if held and heldAt and t - heldAt < 1 then return held end
    heldAt = t
    local c, g = ns.char, ns.myGuild()
    local parts = { tostring(ns.charKey), tostring(ns.guildKey()) }
    for key, o in pairs(ns.db.chars) do
        if key ~= ns.charKey and type(o) == "table" then parts[#parts + 1] = key .. "=" .. tostring(o.updated) end
    end
    for i, tab in pairs(g and type(g.bank) == "table" and type(g.bank.tabs) == "table" and g.bank.tabs or {}) do
        parts[#parts + 1] = "t" .. tostring(i) .. "=" .. tostring(type(tab) == "table" and tab.at) .. tostring(ns.maySeeTab(g, i))
    end
    for who, p in pairs(ns.db.peers) do
        if type(p) == "table" and type(p.hashes) == "table" and (p.hashes.bags or p.hashes.bank) and type(p.scopes) == "table" then
            parts[#parts + 1] = who .. "=" .. tostring(p.hashes.bags) .. tostring(p.hashes.bank) .. tostring(p.scopes.g) .. tostring(p.gk)
        end
    end
    table.sort(parts)
    local sig = table.concat(parts, ";")
    if held and sig == heldSig then return held end
    local out = {} -- [itemID] = { { name, n, rank }, ... }
    local function add(id, name, n, rank)
        if not (id and name) then return end
        local list = out[id] or {}
        out[id] = list
        for _, x in ipairs(list) do
            if x.name == name then x.n = x.n + n return end
        end
        list[#list + 1] = { name = name, n = n, rank = rank }
    end
    for key, o in pairs(ns.db.chars) do
        if key ~= ns.charKey and type(o) == "table" and o.realm == c.realm and o.faction == c.faction then
            for _, list in ipairs({ o.bags, o.bank }) do
                for _, bag in ipairs(type(list) == "table" and list or {}) do
                    for _, it in pairs(type(bag) == "table" and type(bag.slots) == "table" and bag.slots or {}) do
                        if type(it) == "table" then add(num(it.id), str(o.name), num(it.n) or 1, 1) end
                    end
                end
            end
        end
    end
    for i, tab in pairs(g and type(g.bank) == "table" and type(g.bank.tabs) == "table" and g.bank.tabs or {}) do
        if type(tab) == "table" and type(tab.slots) == "table" and ns.maySeeTab(g, i) then
            for _, it in pairs(tab.slots) do
                if type(it) == "table" then add(num(it.id), "the guild bank", num(it.n) or 1, 2) end
            end
        end
    end
    local gk = ns.guildKey()
    for who, p in pairs(ns.db.peers) do
        local more = type(p) == "table" and type(p.scopes) == "table" and p.scopes.g and gk and p.gk == gk and type(p.more) == "table" and p.more
        for _, name in ipairs(more and { "bags", "bank" } or {}) do
            for _, bag in ipairs(type(more[name]) == "table" and type(more[name].list) == "table" and more[name].list or {}) do
                for _, it in pairs(type(bag.s) == "table" and bag.s or {}) do
                    if type(it) == "table" then add(num(it.id), callName(who), num(it.c) or 1, 3) end
                end
            end
        end
    end
    held, heldSig = out, sig
    return out
end

-- "Bram (40), the guild bank (20) and Thalia (12)": the most first, your own characters first
-- among equals; "and 3 more" past three.
ns.heldBy = function(id)
    if not (ns.db and ns.char and id) then return nil end
    local list = heldIndex()[id]
    if not list or #list == 0 then return nil end
    local sorted = {}
    for i, x in ipairs(list) do sorted[i] = x end
    table.sort(sorted, function(a, b)
        if a.n ~= b.n then return a.n > b.n end
        if a.rank ~= b.rank then return a.rank < b.rank end
        return a.name < b.name
    end)
    local shown = {}
    for i = 1, #sorted <= 3 and #sorted or 2 do shown[i] = format("%s (%d)", sorted[i].name, sorted[i].n) end
    if #sorted > 3 then shown[#shown + 1] = format("%d more", #sorted - 2) end
    if #shown == 1 then return shown[1] end
    return table.concat(shown, ", ", 1, #shown - 1) .. " and " .. shown[#shown]
end

-- Reliquary's lines under an item on the game's own tooltips: each a label and what it says, and
-- only those with something to say: its auction price, who it's set aside for and who it would be
-- an upgrade for (the guild bank's board), who else can make it, whose recipes use it and who could
-- learn it (Crafting.lua), and who else has it.
ns.tooltipLines = function(id)
    local out = {}
    if not (ns.db and ns.char and id) or ns.db.settings.tipLine == false then return out end
    local price = ns.priceValue and ns.priceValue(id)
    if price then out[#out + 1] = { "Auction", price } end
    local board = ns.boardFor(id)
    local skip = {}
    if board and #board.aside > 0 then
        local names = {}
        for _, x in ipairs(board.aside) do
            names[#names + 1] = callName(x.who)
            skip[x.who] = true
        end
        out[#out + 1] = { "Set aside for", table.concat(names, " and ") }
    end
    local up = upgradeNames(id, skip)
    if up then out[#out + 1] = { "Upgrade for", up } end
    for _, l in ipairs(ns.craftTips and ns.craftTips(id) or {}) do out[#out + 1] = l end
    local has = ns.heldBy(id)
    if has then out[#out + 1] = { "Held by", has } end
    return out
end

-- The same as one line of text ("Auction 18s each · Made by Faelwen"), or nil when there's nothing.
ns.tooltipLine = function(id)
    local bits = {}
    for _, l in ipairs(ns.tooltipLines(id)) do bits[#bits + 1] = l[1] .. " " .. l[2] end
    return #bits > 0 and table.concat(bits, " · ") or nil
end

-- Added through the game's own tooltip post-call (TooltipDataProcessor), which every addon shares
-- without touching another's lines, and only to the game's item tooltip and a chat link's: never
-- the comparison tooltips beside them, another addon's own tooltip, or one the game keeps from
-- addons. The first line carries Reliquary's mark; each label is in the game's gold and what it
-- says in white, as the game writes its own tooltip lines.
local MARK = "|TInterface\\AddOns\\Reliquary\\Media\\icon:0|t "
local function onItemTooltip(tooltip, data)
    if not (tooltip and (tooltip == GameTooltip or tooltip == ItemRefTooltip) and tooltip.AddLine) then return end
    if tooltip.IsForbidden and tooltip:IsForbidden() then return end
    local id = type(data) == "table" and num(data.id)
    for i, l in ipairs(id and ns.tooltipLines(id) or {}) do
        tooltip:AddLine((i == 1 and MARK or "") .. ns.GOLD .. l[1] .. "|r " .. l[2], 1, 1, 1, true)
    end
end
ns.onItemTooltip = onItemTooltip

---------------------------------------------------------------------------
-- Handing it out: officers set bank items aside for guildmates, and guildmates ask for them
---------------------------------------------------------------------------
-- Each bank tab you may see has a board, kept with the tab: { at = its newest word, items = {
-- [itemID] = { aside = { [who] = { by, at, off } }, asks = { [who] = { at, off } } } } }. An officer
-- sets an item aside for a guildmate (as many as the tab holds) or takes it back; a guildmate asks
-- for one, or takes the ask back. Every word carries its time and the newest word on each entry
-- wins, a take-back included (kept, marked off, until it expires), so words may arrive in any
-- order. A word goes at once to the guildmates in the game who use Reliquary and may see the tab
-- (the whole guild, for a tab open to everyone); officers' copies of the tab carry its board to
-- whoever missed it, and your own asks go again to an officer who missed them. Officers are the
-- ranks the guild master trusts with the bank's records (Officer and up unless they say
-- otherwise). A set-aside clears once the item has left the bank, and everything is forgotten
-- after two weeks. Reliquary never decides who gets an item: people do.
local BOARD_KEEP = 14 * 86400
local BOARD_ITEMS, BOARD_NAMES = 100, 40 -- the most a board keeps: items, and names on each
local CLOCK_SLACK = 3600                  -- how far ahead of yours another player's clock may run
local HEARD_KEEP = 30 * 86400             -- how long a guildmate heard on the guild channel counts as using Reliquary

local function bankOf(g) return type(g) == "table" and type(g.bank) == "table" and g.bank or nil end

local function boardOf(g, tab, create)
    local b = bankOf(g)
    if not b then return nil end
    if type(b.board) ~= "table" then
        if not create then return nil end
        b.board = {}
    end
    local bd = b.board[tab]
    if type(bd) ~= "table" or type(bd.items) ~= "table" then
        if not create then return nil end
        bd = { at = 0, items = {} }
        b.board[tab] = bd
    end
    return bd
end

local function officerRank(g)
    local p = ns.bankPolicy(g)
    return p and num(p.kp) or 2
end
local function isOfficer(g, ro) return ro ~= nil and ro <= officerRank(g) end
ns.isOfficer = function()
    local g = ns.myGuild()
    return g ~= nil and isOfficer(g, ns.myRank())
end

-- How many of an item lie in a bank tab you may see, and one of them as the tab holds it.
local function countIn(g, tab, id)
    local b = bankOf(g)
    local t = b and type(b.tabs) == "table" and b.tabs[tab]
    if type(t) ~= "table" or type(t.slots) ~= "table" or not ns.maySeeTab(g, tab) then return 0 end
    local n, one = 0, nil
    for _, it in pairs(t.slots) do
        if type(it) == "table" and it.id == id then n, one = n + (num(it.n) or 1), one or it end
    end
    return n, one
end

-- The bank tab an item lies in, among those you may see (the one given, if it's there).
local function tabWith(g, id, tab)
    if tab and countIn(g, tab, id) > 0 then return tab end
    for i = 1, 8 do if countIn(g, i, id) > 0 then return i end end
    return nil
end

-- Whether a word about an item is moot: forgotten after two weeks, or the item has left the bank
-- since (your copy of the tab, read after the word, no longer holds it).
local function gone(g, tab, id, at)
    if time() - at > BOARD_KEEP then return true end
    local b = bankOf(g)
    local t = b and type(b.tabs) == "table" and b.tabs[tab]
    if type(t) ~= "table" or type(t.slots) ~= "table" or not num(t.at) or t.at <= at then return false end
    for _, it in pairs(t.slots) do if type(it) == "table" and it.id == id then return false end end
    return true
end

local function size(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end

-- Who an item in the bank is set aside for and who asked for it, oldest first, with the tab it
-- lies in, how many the tab holds and one of them; nil when it isn't in a tab you may see.
ns.boardFor = function(id, tab)
    local g = ns.myGuild()
    tab = g and id and tabWith(g, id, tab)
    if not tab then return nil end
    local n, one = countIn(g, tab, id)
    local out = { tab = tab, count = n, item = one, aside = {}, asks = {} }
    local bd = boardOf(g, tab)
    local e = bd and bd.items[id]
    for _, kind in ipairs({ "aside", "asks" }) do
        for who, x in pairs(type(e) == "table" and type(e[kind]) == "table" and e[kind] or {}) do
            if type(x) == "table" and not x.off and num(x.at) then out[kind][#out[kind] + 1] = { who = who, by = x.by, at = num(x.f) or x.at } end
        end
        table.sort(out[kind], function(a, b) if a.at ~= b.at then return a.at < b.at end return a.who < b.who end)
    end
    return out
end

-- One word on a board: who an item is set aside for (kind "aside"), or who asks for it ("asks").
-- The newest word on each entry wins; at the same moment, a take-back.
local function put(g, tab, id, kind, who, x)
    if gone(g, tab, id, x.at) then return false end
    local bd = boardOf(g, tab, true)
    local e = bd.items[id]
    if type(e) ~= "table" then
        if size(bd.items) >= BOARD_ITEMS then return false end
        e = {}
    end
    local list = type(e[kind]) == "table" and e[kind] or {}
    local old = list[who]
    if type(old) == "table" and num(old.at) and (old.at > x.at or (old.at == x.at and (old.off or not x.off))) then return false end
    if not old and size(list) >= BOARD_NAMES then return false end
    list[who] = x
    e[kind] = list
    bd.items[id] = e
    bd.at = max(num(bd.at) or 0, x.at)
    return true
end

local function openToAll(g, tab)
    local p = ns.bankPolicy(g)
    return p ~= nil and type(p.tb) == "table" and p.tb[tab] == "a"
end

-- A word, to the guildmates in the game now who use Reliquary and may see the tab: by whisper,
-- or to the whole guild for a tab open to everyone.
local function tellTab(g, tab, msg)
    if openToAll(g, tab) then
        ns.send({ kind = "GUILD" }, msg, true)
        return
    end
    local me, t, names = ns.me(), time(), {}
    local heard = type(g.heard) == "table" and g.heard or {}
    for _, m in ipairs(type(g.members) == "table" and g.members or {}) do
        local who = type(m) == "table" and m.n and ns.fullName(m.n)
        if who and who ~= me and num(heard[who]) and t - heard[who] <= HEARD_KEEP and ns.theySeeTab(g, who, tab) then names[who] = m end
    end
    local now = ns.inGameNow and ns.inGameNow(names)
    for who, m in pairs(names) do
        if (now and now[who]) or (not now and m.on and not m.mobile) then ns.send({ kind = "WHISPER", target = who }, msg, true) end
    end
end

-- `ask`: an ask's own game's verdict on the item (its kind, and the level for "at level") and when
-- it was first made, so the guild sees whether it would help the asker even if they don't show
-- their gear; never what they wear.
local function word(g, tab, id, kind, who, off, ask)
    local bd = boardOf(g, tab)
    local at = max(time(), (bd and num(bd.at) or 0) + 1)
    local x = { at = at, off = off or nil, by = kind == "aside" and ns.me() or nil }
    if ask then x.v, x.lv, x.f = ask.v, ask.lv, ask.f or at end
    if not put(g, tab, id, kind, who, x) then return false end
    tellTab(g, tab, { t = "bd", i = tab, it = id, k = kind == "aside" and "a" or "w", w = kind == "aside" and who or nil, x = off and 1 or nil, at = at,
        v = x.v, lv = x.lv, f = x.f })
    ns.dataChanged()
    return true
end

-- A verdict as an ask carries it: one of the four kinds, with the level only for "at level".
local function askVerdict(v, lv)
    v = VERDICTS[v] and v or nil
    return v, v == "lvl" and N(lv, 1, 999) or nil
end

-- What your own game thinks of a bank item now, for your ask.
local function myVerdict(g, tab, id)
    local _, one = countIn(g, tab, id)
    local v = one and judgeSelf(linkOf(one.link or one.s))
    return askVerdict(v and v.v, v and v.lv)
end

-- For the window. An officer sets a bank item aside for a guildmate (no more than the tab holds),
-- or takes it back (off).
ns.setAside = function(id, who, off, tab)
    local g = ns.myGuild()
    tab = g and id and tabWith(g, id, tab)
    who = S(who, 64)
    if not (tab and who and isOfficer(g, ns.myRank())) or who:find("^own:") then return false end
    local b = ns.boardFor(id, tab)
    local had = false
    for _, x in ipairs(b.aside) do if x.who == who then had = true end end
    if off then
        if not had then return false end
    elseif had or #b.aside >= b.count then
        return false
    end
    return word(g, tab, id, "aside", who, off)
end

-- Anyone who may see the tab asks for an item, or takes the ask back (off).
ns.askFor = function(id, off, tab)
    local g = ns.myGuild()
    tab = g and id and tabWith(g, id, tab)
    if not tab then return false end
    if off then return word(g, tab, id, "asks", ns.me(), true) end
    local v, lv = myVerdict(g, tab, id)
    return word(g, tab, id, "asks", ns.me(), nil, { v = v, lv = lv })
end

-- Your asks still standing say what your game thinks of the item now (a level gained, new gear),
-- each keeping when it was first made.
ns.refreshAsks = function(fits)
    local g = ns.myGuild()
    local b = g and bankOf(g)
    local me = ns.me()
    for tab, bd in pairs(b and type(b.board) == "table" and b.board or {}) do
        for id, e in pairs(type(bd) == "table" and type(bd.items) == "table" and bd.items or {}) do
            local x = type(e) == "table" and type(e.asks) == "table" and e.asks[me]
            if type(x) == "table" and not x.off and num(x.at) and countIn(g, tab, id) > 0 then
                local cur = fits and fits[id]
                local v, lv = askVerdict(cur and cur.v, cur and cur.lv)
                if v ~= x.v or lv ~= x.lv then word(g, tab, id, "asks", me, nil, { v = v, lv = lv, f = num(x.f) or x.at }) end
            end
        end
    end
end

-- Who asked for an item in a bank tab you may see, with their own game's verdict: {who = {v, lv}}.
ns.askVerdicts = function(id)
    local g = ns.myGuild()
    local out = {}
    local b = g and bankOf(g)
    for tab, bd in pairs(b and type(b.board) == "table" and b.board or {}) do
        local e = type(bd) == "table" and type(bd.items) == "table" and bd.items[id]
        for who, x in pairs(type(e) == "table" and type(e.asks) == "table" and e.asks or {}) do
            if type(x) == "table" and not x.off and x.v and countIn(g, tab, id) > 0 then out[who] = { v = x.v, lv = x.lv } end
        end
    end
    return out
end

ns.handlers.bd = function(msg, route, who)
    local g = ns.myGuild()
    local tab, id, at = N(msg.i, 1, 8), N(msg.it, 1), N(msg.at, 1, time() + CLOCK_SLACK)
    local ro = ns.rankOf(who)
    if not (g and tab and id and at and ro) or not ns.maySeeTab(g, tab) then return end
    if route.kind == "GUILD" then
        if not openToAll(g, tab) then return end -- only an open tab's board goes to everyone
    elseif route.kind ~= "WHISPER" then
        return
    end
    local off = msg.x == 1 or nil
    local ok = false
    if msg.k == "a" then
        local to = S(msg.w, 64)
        if not (to and isOfficer(g, ro)) then return end -- only officers set items aside
        ok = put(g, tab, id, "aside", to, { by = who, at = at, off = off })
    elseif msg.k == "w" then
        if ns.rankSeesTab(ro, tab, g) == false then return end -- only someone who may see the tab asks
        local v, lv = askVerdict(msg.v, msg.lv)
        ok = put(g, tab, id, "asks", who, { at = at, off = off, v = not off and v or nil, lv = not off and lv or nil, -- and only for themselves
            f = not off and (N(msg.f, 1, at) or at) or nil })
    end
    if ok then ns.dataChanged() end
end

-- With a tab, from officers: its whole board, take-backs included, for whoever missed a word.
ns.boardAt = function(g, tab)
    if not isOfficer(g, ns.myRank()) then return nil end
    local bd = boardOf(g, tab)
    return bd and num(bd.at) and bd.at > 0 and bd.at or nil
end

ns.boardOut = function(g, tab)
    local at = ns.boardAt(g, tab)
    if not at then return nil end
    local list = {}
    for id, e in pairs(boardOf(g, tab).items) do
        local out = { id = id }
        for kind, key in pairs({ aside = "a", asks = "q" }) do
            for who, x in pairs(type(e) == "table" and type(e[kind]) == "table" and e[kind] or {}) do
                if type(x) == "table" and num(x.at) then
                    out[key] = out[key] or {}
                    out[key][#out[key] + 1] = { w = who, b = x.by, at = x.at, x = x.off and 1 or nil, v = x.v, lv = x.lv, f = x.f }
                end
            end
        end
        if out.a or out.q then list[#list + 1] = out end
    end
    table.sort(list, function(a, b) return a.id < b.id end)
    return { list = list }, at
end

ns.boardWanted = function(g, tab, offer, who)
    local ba = N(offer.ba, 1)
    if not (ba and isOfficer(g, ns.rankOf(who))) then return false end
    local bd = boardOf(g, tab)
    return ba > (bd and num(bd.at) or 0)
end

ns.boardIn = function(g, tab, msg, who)
    local ba = N(msg.ba, 1, time() + CLOCK_SLACK)
    if not (ba and type(msg.bd) == "table" and isOfficer(g, ns.rankOf(who))) then return false end
    local list = type(msg.bd.list) == "table" and msg.bd.list or {}
    for k = 1, min(#list, BOARD_ITEMS) do
        local e = list[k]
        local id = type(e) == "table" and N(e.id, 1)
        if id then
            for kind, key in pairs({ aside = "a", asks = "q" }) do
                local words = type(e[key]) == "table" and e[key] or {}
                for j = 1, min(#words, BOARD_NAMES) do
                    local x = words[j]
                    local name, at = type(x) == "table" and S(x.w, 64), type(x) == "table" and N(x.at, 1, time() + CLOCK_SLACK)
                    if name and at then
                        local off = x.x == 1 or nil
                        local v, lv = askVerdict(x.v, x.lv)
                        local ask = kind == "asks" and not off
                        put(g, tab, id, kind, name, { by = kind == "aside" and S(x.b, 64) or nil, at = at, off = off,
                            v = ask and v or nil, lv = ask and lv or nil, f = ask and (N(x.f, 1, at) or at) or nil })
                    end
                end
            end
        end
    end
    local bd = boardOf(g, tab, true)
    bd.at = max(num(bd.at) or 0, ba)
    return true
end

-- An officer offers the bank: if they missed your own latest asks on a tab, they go to them again.
ns.boardOffered = function(g, tab, offer, who)
    if not isOfficer(g, ns.rankOf(who)) then return end
    local bd = boardOf(g, tab)
    local me = ns.me()
    local theirs = N(offer.ba, 1) or 0
    for id, e in pairs(bd and bd.items or {}) do
        local x = type(e) == "table" and type(e.asks) == "table" and e.asks[me]
        if type(x) == "table" and num(x.at) and x.at > theirs and not gone(g, tab, id, x.at) then
            ns.send({ kind = "WHISPER", target = who }, { t = "bd", i = tab, it = id, k = "w", x = x.off and 1 or nil, at = x.at, v = x.v, lv = x.lv, f = x.f }, true)
        end
    end
end

-- Words that are moot go: forgotten after two weeks, or about an item that has left the bank; and
-- the boards of tabs you may no longer see.
local function tidyBoard(g)
    local t = time()
    if type(g.heard) == "table" then
        for who, at in pairs(g.heard) do if not num(at) or t - at > HEARD_KEEP then g.heard[who] = nil end end
    end
    local b = bankOf(g)
    if not (b and type(b.board) == "table") then return end
    for tab, bd in pairs(b.board) do
        if type(bd) ~= "table" or type(bd.items) ~= "table" or not ns.maySeeTab(g, tab) then
            b.board[tab] = nil
        else
            for id, e in pairs(bd.items) do
                for _, kind in ipairs({ "aside", "asks" }) do
                    local list = type(e) == "table" and type(e[kind]) == "table" and e[kind] or nil
                    for who, x in pairs(list or {}) do
                        if type(x) ~= "table" or not num(x.at) or gone(g, tab, id, x.at) then list[who] = nil end
                    end
                    if list and not next(list) then e[kind] = nil end
                end
                if type(e) ~= "table" or not (e.aside or e.asks) then bd.items[id] = nil end
            end
        end
    end
end
ns.tidyBoard = function() local g = ns.myGuild() if g then tidyBoard(g) end end

-- For a guildmate's page: the bank items set aside for them, then those that would be an upgrade
-- for them now, the biggest first. Each as the bank holds it. also: the key the guild's weighing
-- files one of your other characters under ("own:<key>").
ns.bankFor = function(who, also)
    local g = ns.myGuild()
    local out, seen = {}, {}
    if not (g and who) then return out end
    local b = bankOf(g)
    for tab, bd in pairs(b and type(b.board) == "table" and b.board or {}) do
        for id, e in pairs(type(bd) == "table" and type(bd.items) == "table" and bd.items or {}) do
            local x = type(e) == "table" and type(e.aside) == "table" and e.aside[who]
            local n, one = countIn(g, tab, id)
            if type(x) == "table" and not x.off and n > 0 and not seen[id] then
                seen[id] = true
                out[#out + 1] = { id = id, item = one, aside = true, gain = 1e6 }
            end
        end
    end
    for id, list in pairs(type(g.fits) == "table" and g.fits or {}) do
        for _, x in ipairs(type(list) == "table" and list or {}) do
            local tab = (x.who == who or (also and x.who == also)) and x.v == "up" and not seen[id] and tabWith(g, id)
            if tab then
                seen[id] = true
                out[#out + 1] = { id = id, item = select(2, countIn(g, tab, id)), gain = (x.il or 0) - (x.ci or 0) }
            end
        end
    end
    table.sort(out, function(a, b) if a.gain ~= b.gain then return a.gain > b.gain end return a.id < b.id end)
    return out
end

---------------------------------------------------------------------------
-- One line at login: gear set aside for you, and new upgrades for you in the guild bank
---------------------------------------------------------------------------
local HEADS_UP_FROM, HEADS_UP_UNTIL = 45, 240 -- seconds after login: time for the guild's news to arrive, and the window to tell it in
local TOLD_KEEP = 30 * 86400
local headsUpDone = false

local function itemText(id)
    local _, link = call(CI.GetItemInfo or GetItemInfo, id)
    link = str(link)
    if link then return link end
    local rec = ns.db.items[id]
    local name = type(rec) == "table" and type(rec.info) == "table" and rec.info.name
    return name and ("[" .. name .. "]") or ("item " .. id)
end

local function headsUp()
    if headsUpDone or not (ns.db and ns.char and ns.loginAt) or inCombat() then return end
    local since = time() - ns.loginAt
    if since < HEADS_UP_FROM then return end
    if since > HEADS_UP_UNTIL or ns.db.settings.headsUp == false then
        headsUpDone = true
        return
    end
    local g = ns.myGuild()
    if not g then return end
    local me, t = ns.me(), time()
    local told = type(ns.char.told) == "table" and ns.char.told or {}
    for k, at in pairs(told) do if not num(at) or t - at > TOLD_KEEP then told[k] = nil end end
    -- Gear set aside for you that's still in the bank, newest first.
    local asides, taken = {}, {}
    local b = bankOf(g)
    for tab, bd in pairs(b and type(b.board) == "table" and b.board or {}) do
        for id, e in pairs(type(bd) == "table" and type(bd.items) == "table" and bd.items or {}) do
            local n = countIn(g, tab, id)
            local live = 0
            for who, x in pairs(type(e) == "table" and type(e.aside) == "table" and e.aside or {}) do
                if type(x) == "table" and not x.off and num(x.at) then
                    live = live + 1
                    if who == me and not told["a" .. id .. ":" .. x.at] then asides[#asides + 1] = { id = id, by = x.by, at = x.at } end
                end
            end
            if n > 0 and live >= n then taken[id] = true end
        end
    end
    table.sort(asides, function(a, b) return a.at > b.at end)
    -- Upgrades for you now (never trade-offs), not yet told, and not all set aside for others.
    local ups = {}
    for id, list in pairs(type(g.fits) == "table" and g.fits or {}) do
        for _, x in ipairs(type(list) == "table" and list or {}) do
            if x.who == me and x.v == "up" and not taken[id] and not told["u" .. id] and tabWith(g, id) then ups[#ups + 1] = id end
        end
    end
    table.sort(ups)
    if #asides == 0 and #ups == 0 then return end
    headsUpDone = true
    ns.char.told = told
    local bits = {}
    if #asides == 1 then
        bits[#bits + 1] = format("%s set %s aside for you in the guild bank.", asides[1].by and callName(asides[1].by) or "An officer", itemText(asides[1].id))
    elseif #asides > 1 then
        bits[#bits + 1] = format("%d items are set aside for you in the guild bank.", #asides)
    end
    for _, x in ipairs(asides) do told["a" .. x.id .. ":" .. x.at] = t end
    if #ups == 1 then
        bits[#bits + 1] = format("The guild bank has an upgrade for you: %s.", itemText(ups[1]))
    elseif #ups > 1 then
        bits[#bits + 1] = format("The guild bank has %d upgrades for you.", #ups)
    end
    for _, id in ipairs(ups) do told["u" .. id] = t end
    print(ns.TAG .. table.concat(bits, " ") .. " /rq to see.")
end
ns.headsUp = headsUp

---------------------------------------------------------------------------
-- Start
---------------------------------------------------------------------------
on("PLAYER_LOGIN", function()
    ns.loginAt = time()
    local processor, kind = api("TooltipDataProcessor.AddTooltipPostCall"), api("Enum.TooltipDataType.Item")
    if processor and kind then pcall(processor, kind, onItemTooltip) end
    if C_Timer and C_Timer.NewTicker then
        C_Timer.After(25, function() ns.weighUpgrades(true) end)
        C_Timer.NewTicker(15, function()
            ns.weighUpgrades(false)
            pcall(headsUp)
        end)
    end
end)

-- Items linked in guild chat are weighed too (the chat lockdown hides their text: nothing then).
on("CHAT_MSG_GUILD", function(text)
    text = str(text)
    if not text or not ns.db then return end
    for s in text:gmatch("|H(item:[%-%d:]+)|h") do
        local id = idOf(s)
        if id then linked[id] = { s = s, at = time() } end
    end
    local n = 0
    for _ in pairs(linked) do n = n + 1 end
    if n > LINKED_MAX then
        local oldest
        for id, l in pairs(linked) do if not oldest or l.at < linked[oldest].at then oldest = id end end
        linked[oldest] = nil
    end
end)

for _, event in ipairs({ "PLAYER_EQUIPMENT_CHANGED", "PLAYER_LEVEL_UP", "PLAYER_SPECIALIZATION_CHANGED", "ACTIVE_TALENT_GROUP_CHANGED" }) do
    on(event, function() if C_Timer then C_Timer.After(2, function() ns.weighUpgrades(false) end) end end)
end
