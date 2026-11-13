-- Where items come from, as Reliquary sees it while you play: what vendors sell (the price, the
-- vendor and where they stand), what drops from whom and where (fishing, gathering and opened
-- containers included), what quests give, what your recipes make and use (Crafting.lua reads
-- them), and, where the game's own collection knows it, which boss drops a piece of gear. Each item keeps the newest few notes
-- of each kind. Anyone who opens an item's page asks the guild about it, and guildmates who turn
-- on "Share prices and sources" answer with their own notes, each kept with whose it was. Like
-- everything from the guild, they stay on your own dashboard and in the game, never public.
local ADDON, ns = ...

local call, num, str, plain, api, on, inCombat = ns.call, ns.num, ns.str, ns.plain, ns.api, ns.on, ns.inCombat
local pairs, ipairs, type, next, format, min, max, floor, random = pairs, ipairs, type, next, string.format, math.min, math.max, math.floor, math.random

-- The kinds of note: v sold by a vendor, d dropped or found, q a quest's reward, m made by a
-- recipe, r used in a recipe, j the game's journal; and how many of each an item keeps.
local KEEP = { v = 8, d = 12, q = 8, m = 4, r = 30, j = 8 }
local ITEMS_MAX = 6000     -- items with notes; the ones noted longest ago go first
local ASK_GAP = 600        -- seconds before the guild is asked again about the same item
local JOURNAL_AGAIN = 30 * 86400

local function N(v, lo, hi) return ns.cleanNum(v, lo, hi) end
local function S(v, n) return ns.cleanStr(v, n) end

local function sources()
    ns.db.sources = type(ns.db.sources) == "table" and ns.db.sources or {}
    return ns.db.sources
end

-- One note about an item, under a key of its own (a vendor's or creature's number, a quest's, a
-- recipe's): the newest few of each kind stay.
local function note(id, kind, key, x)
    local all = sources()
    local rec = type(all[id]) == "table" and all[id] or {}
    all[id] = rec
    local list = type(rec[kind]) == "table" and rec[kind] or {}
    rec[kind] = list
    x.at = x.at or time()
    list[key] = x
    local n, oldest = 0, nil
    for k, v in pairs(list) do
        n = n + 1
        if not oldest or (num(v.at) or 0) < (num(list[oldest].at) or 0) then oldest = k end
    end
    if n > KEEP[kind] then list[oldest] = nil end
    rec.at = max(num(rec.at) or 0, x.at)
end
-- Crafting.lua reads your recipes and notes what each makes ("m") and what goes into it ("r").
ns.noteSource = function(id, kind, key, x) if ns.db and KEEP[kind] then note(id, kind, key, x) end end

local function itemOf(link) return link and tonumber(tostring(link):match("item:(%d+)")) end

-- A unit's kind and number from its GUID: ("Creature", 1234), ("GameObject", 5678).
local function guidParts(guid)
    guid = str(guid)
    if not guid then return nil end
    local kind, id = guid:match("^(%a+)%-%d+%-%d+%-%d+%-%d+%-(%d+)%-")
    return kind or guid:match("^(%a+)%-"), tonumber(id)
end

-- Where you stand: zone, the place within it, and the map position (0 to 100).
local function where()
    local zone, sub = str(call(GetRealZoneText)), str(call(GetSubZoneText))
    local x, y
    local mapID = num(call(api("C_Map.GetBestMapForUnit"), "player"))
    local pos = mapID and call(api("C_Map.GetPlayerMapPosition"), mapID, "player")
    if type(pos) == "table" and pos.GetXY then
        local px, py = call(pos.GetXY, pos)
        if num(px) and num(py) and (px > 0 or py > 0) then x, y = floor(px * 1000 + 0.5) / 10, floor(py * 1000 + 0.5) / 10 end
    end
    return zone, (sub and sub ~= zone) and sub or nil, x, y
end

---------------------------------------------------------------------------
-- Vendors
---------------------------------------------------------------------------
local function readMerchant()
    if not ns.db then return end
    local _, npc = guidParts(call(UnitGUID, "npc"))
    local name = str(call(UnitName, "npc"))
    if not (npc or name) then return end
    local zone, sub, x, y = where()
    local MF = api("C_MerchantFrame")
    for i = 1, num(call(GetMerchantNumItems)) or 0 do
        local id = num(call(GetMerchantItemID, i)) or itemOf(str(call(GetMerchantItemLink, i)))
        local info = MF and call(MF.GetItemInfo, i)
        if id and type(info) == "table" then
            note(id, "v", npc or name, { id = npc, n = name, z = zone, s = sub, x = x, y = y, p = num(info.price), k = num(info.stackCount),
                c = plain(info.hasExtendedCost) == true or nil, l = (num(info.numAvailable) or -1) >= 0 or nil })
        end
    end
end
on("MERCHANT_SHOW", function() if C_Timer then C_Timer.After(0.5, readMerchant) end end)

---------------------------------------------------------------------------
-- Loot: from creatures, gathering, fishing and opened containers
---------------------------------------------------------------------------
local looted -- this loot window's items are noted
local opened -- { id, at }: the container you opened last
if hooksecurefunc and type(C_Container) == "table" and C_Container.UseContainerItem then
    hooksecurefunc(C_Container, "UseContainerItem", function(bag, slot)
        local id = num(call(C_Container.GetContainerItemID, bag, slot))
        if id then opened = { id = id, at = num(call(GetTime)) or 0 } end
    end)
end

on("LOOT_READY", function()
    if looted or not ns.db then return end
    looted = true
    local fishing = plain(call(IsFishingLoot)) == true
    local zone, sub = where()
    local named = {}
    for _, unit in ipairs({ "target", "mouseover" }) do
        local g = str(call(UnitGUID, unit))
        if g then named[g] = str(call(UnitName, unit)) end
    end
    for slot = 1, num(call(GetNumLootItems)) or 0 do
        local id = itemOf(str(call(GetLootSlotLink, slot)))
        local guid = str((call(GetLootSourceInfo, slot)))
        local kind, n = guidParts(guid)
        local key, x
        if not id then
            -- money, currency
        elseif fishing then
            key, x = "f:" .. (zone or "?"), { k = "f" }
        elseif (kind == "Creature" or kind == "Vehicle") and n then
            key, x = "c" .. n, { k = "c", id = n, n = named[guid] }
        elseif kind == "GameObject" and n then
            key, x = "o" .. n, { k = "o", id = n }
        elseif kind == "Item" and opened and (num(call(GetTime)) or 0) - opened.at < 5 then
            key, x = "i" .. opened.id, { k = "i", id = opened.id }
        end
        if key then
            local rec = sources()[id]
            local old = type(rec) == "table" and type(rec.d) == "table" and rec.d[key]
            x.z, x.s = zone, sub
            x.c = (type(old) == "table" and num(old.c) or 0) + 1
            if not x.n and type(old) == "table" then x.n = str(old.n) end -- a name learned before stays
            note(id, "d", key, x)
        end
    end
end)
on("LOOT_CLOSED", function() looted = nil end)

---------------------------------------------------------------------------
-- Quests: what a quest offers, and the choices
---------------------------------------------------------------------------
local function readQuest()
    if not ns.db then return end
    local qid, title = num(call(GetQuestID)), str(call(GetTitleText))
    if not (qid and qid > 0 and title) then return end
    for i = 1, num(call(GetNumQuestRewards)) or 0 do
        local id = itemOf(str(call(GetQuestItemLink, "reward", i)))
        if id then note(id, "q", qid, { t = title }) end
    end
    for i = 1, num(call(GetNumQuestChoices)) or 0 do
        local id = itemOf(str(call(GetQuestItemLink, "choice", i)))
        if id then note(id, "q", qid, { t = title, ch = true }) end
    end
end
on("QUEST_DETAIL", readQuest)
on("QUEST_COMPLETE", readQuest)

---------------------------------------------------------------------------
-- The game's own journal: which boss drops a piece of gear, where the collection knows it
---------------------------------------------------------------------------
-- Asked by an item's page, and by the background pass for gear no look has covered this month.
local function checkJournal(id)
    local TC = api("C_TransmogCollection")
    if not (TC and TC.GetItemInfo and TC.GetAppearanceSourceDrops and ns.db) then return end
    ns.db.journalAt = type(ns.db.journalAt) == "table" and ns.db.journalAt or {}
    ns.db.journalAt[id] = time()
    local _, source = call(TC.GetItemInfo, id)
    source = num(source)
    local drops = source and call(TC.GetAppearanceSourceDrops, source)
    for k, d in ipairs(type(drops) == "table" and drops or {}) do
        local enc, inst = type(d) == "table" and str(d.encounter), type(d) == "table" and str(d.instance)
        if enc and inst and k <= KEEP.j then
            local modes = {}
            for _, df in ipairs(type(d.difficulties) == "table" and d.difficulties or {}) do if str(df) then modes[#modes + 1] = str(df) end end
            note(id, "j", enc .. "|" .. inst, { e = enc, i = inst, df = #modes > 0 and table.concat(modes, ", ") or nil })
        end
    end
end
ns.checkJournal = checkJournal

-- A few gear items a few seconds, out of a fight: those Reliquary knows that no check has covered.
local journalQueue
local function journalTick()
    if not ns.db or inCombat() then return end
    if not journalQueue or #journalQueue == 0 then
        journalQueue = {}
        local at = type(ns.db.journalAt) == "table" and ns.db.journalAt or {}
        for id, rec in pairs(ns.db.items or {}) do
            local loc = type(rec) == "table" and type(rec.info) == "table" and rec.info.loc
            if loc and loc ~= "" and loc ~= "INVTYPE_BAG" and not (num(at[id]) and time() - at[id] < JOURNAL_AGAIN) then journalQueue[#journalQueue + 1] = id end
        end
        if #journalQueue == 0 then return end
    end
    for _ = 1, 3 do
        local id = table.remove(journalQueue)
        if not id then return end
        checkJournal(id)
    end
end

-- The notes noted longest ago go once there are more than the most kept.
local function prune()
    local all = sources()
    local ids = {}
    for id, rec in pairs(all) do ids[#ids + 1] = { id = id, at = type(rec) == "table" and num(rec.at) or 0 } end
    if #ids <= ITEMS_MAX then return end
    table.sort(ids, function(a, b) return a.at < b.at end)
    for k = 1, #ids - ITEMS_MAX do all[ids[k].id] = nil end
end

on("PLAYER_LOGIN", function()
    if ns.db then pcall(prune) end
    if C_Timer and C_Timer.NewTicker then C_Timer.NewTicker(2, function() pcall(journalTick) end) end
end)

---------------------------------------------------------------------------
-- Asking the guild about an item, and answering with your own notes
---------------------------------------------------------------------------
local askedAt = {} -- [itemID] = when you last asked

ns.askSources = function(id)
    id = num(id)
    if not (ns.db and id and str(call(GetGuildInfo, "player"))) then return false end
    if askedAt[id] and time() - askedAt[id] < ASK_GAP then return false end
    askedAt[id] = time()
    return ns.send({ kind = "GUILD" }, { t = "src?", id = id }, true)
end

-- Your own notes about an item as they travel (none another guildmate gave you).
local function ownNotes(rec)
    local out, any = {}, false
    for kind in pairs(KEEP) do
        for key, x in pairs(type(rec[kind]) == "table" and rec[kind] or {}) do
            if type(x) == "table" and not x.g then
                out[kind] = out[kind] or {}
                out[kind][#out[kind] + 1] = { key = key, x = x }
                any = true
            end
        end
    end
    return any and out or nil
end

ns.handlers["src?"] = function(msg, route, who)
    if route.kind ~= "GUILD" or not ns.db then return end
    local id = N(msg.id, 1, 1e7)
    local rec = id and sources()[id]
    local out = type(rec) == "table" and ownNotes(rec)
    if not (out and C_Timer) then return end
    C_Timer.After(1 + random() * 3, function()
        -- Only while you share them, as it is when the answer would go.
        if ns.db.settings.sharePrices == true then ns.send({ kind = "GUILD" }, { t = "src", id = id, s = out }) end
    end)
end

-- One note from a guildmate, cleaned: only the fields Reliquary writes, in their shapes.
local CLEAN = {
    v = function(x) return { id = N(x.id, 1, 1e7), n = S(x.n, 64), z = S(x.z, 64), s = S(x.s, 64), x = N(x.x, 0, 100), y = N(x.y, 0, 100),
        p = N(x.p, 0, 1e12), k = N(x.k, 1, 1000), c = x.c == true or nil, l = x.l == true or nil } end,
    d = function(x)
        local k = ({ c = "c", o = "o", f = "f", i = "i" })[x.k]
        return k and { k = k, id = N(x.id, 1, 1e7), n = S(x.n, 64), z = S(x.z, 64), s = S(x.s, 64), c = N(x.c, 1, 1e6) } or nil
    end,
    q = function(x) local t = S(x.t, 120) return t and { t = t, ch = x.ch == true or nil } or nil end,
    m = function(x)
        local p = S(x.p, 64)
        if not p then return nil end
        local u = {}
        for k = 1, min(type(x.u) == "table" and #x.u or 0, 10) do
            local r = x.u[k]
            if type(r) == "table" and N(r.id, 1, 1e7) then u[#u + 1] = { id = r.id, n = N(r.n, 1, 1000) or 1 } end
        end
        return { p = p, u = u }
    end,
    r = function(x) local p, o = S(x.p, 64), N(x.o, 1, 1e7) return p and o and { p = p, o = o } or nil end,
    j = function(x) local e, i = S(x.e, 120), S(x.i, 120) return e and i and { e = e, i = i, df = S(x.df, 120) } or nil end,
}

ns.handlers.src = function(msg, route, who)
    if route.kind ~= "GUILD" or not ns.db then return end
    local id = N(msg.id, 1, 1e7)
    if not (id and type(msg.s) == "table") then return end
    local from = ns.callName(who)
    local mine = sources()[id]
    for kind, list in pairs(msg.s) do
        if CLEAN[kind] and type(list) == "table" then
            for k = 1, min(#list, KEEP[kind]) do
                local e = list[k]
                local key = type(e) == "table" and (N(e.key, 1, 1e9) or ns.cleanKey(e.key, 80))
                local x = key and type(e.x) == "table" and CLEAN[kind](e.x)
                local own = type(mine) == "table" and type(mine[kind]) == "table" and mine[kind][key]
                -- Your own note on the same thing stays; theirs fills in what you haven't seen.
                if x and not (type(own) == "table" and not own.g) then
                    x.g = from
                    note(id, kind, key, x)
                    mine = sources()[id]
                end
            end
        end
    end
    ns.dataChanged()
end

---------------------------------------------------------------------------
-- In words, for an item's page
---------------------------------------------------------------------------
-- An item's name: as Reliquary kept it (its record, else the first line of the tooltip it read),
-- else the game's.
local function nameOfItem(id)
    local rec = ns.db.items[id]
    local kept = type(rec) == "table" and (type(rec.info) == "table" and str(rec.info.name)
        or type(rec.tip) == "table" and type(rec.tip[1]) == "table" and str(rec.tip[1].l))
    return kept or str(call(api("C_Item.GetItemInfo") or GetItemInfo, id)) or ("item " .. id)
end

local function sorted(list, by)
    local out = {}
    for key, x in pairs(type(list) == "table" and list or {}) do if type(x) == "table" then out[#out + 1] = x end end
    table.sort(out, by)
    return out
end

local function place(x) return x.s and x.z and (x.s .. ", " .. x.z) or x.z or x.s or "somewhere" end
local function whose(x) return x.g and ("  " .. ns.GREY .. format("(%s's note)", x.g) .. "|r") or "" end

-- The lines of where an item comes from that its page has room for; the window lists the rest on hover.
ns.ITEM_PAGE_SOURCES = 4

-- What Reliquary knows of where an item comes from, for its page: the places, the most useful first,
-- each with its kind (the page gives each kind the game's own map icon: "vendor", "quest", "boss",
-- "drop", "fish", "gather", "container" with the container's item) and its line in words; each
-- recipe that makes it (its profession, what goes into it and whose note it is); and the items it
-- is used to make.
ns.itemSources = function(id)
    local out = { places = {}, recipes = {}, makes = {} }
    local rec = ns.db and id and sources()[id]
    if type(rec) ~= "table" then return out end
    local function add(kind, line, x, item) out.places[#out.places + 1] = { kind = kind, text = line .. whose(x), item = item } end
    for _, x in ipairs(sorted(rec.v, function(a, b) return (a.p or 0) < (b.p or 0) end)) do
        local price = x.c and "" or x.p and x.p > 0 and (" for " .. ns.moneyText(x.p) .. ((x.k or 1) > 1 and format(" (%d)", x.k) or "")) or ""
        add("vendor", format("Sold by %s, %s%s%s", x.n or "a vendor", place(x), price, x.l and " (limited)" or ""), x)
    end
    for _, x in ipairs(sorted(rec.q, function(a, b) return (a.t or "") < (b.t or "") end)) do
        add("quest", format("%s from the quest %s", x.ch and "A reward choice" or "A reward", x.t or "?"), x)
    end
    for _, x in ipairs(sorted(rec.j, function(a, b) return (a.e or "") < (b.e or "") end)) do
        add("boss", format("Drops from %s in %s%s", x.e, x.i, x.df and (" (" .. x.df .. ")") or ""), x)
    end
    for _, x in ipairs(sorted(rec.d, function(a, b) return (a.c or 0) > (b.c or 0) end)) do
        if x.k == "f" then add("fish", "Fished up in " .. (x.z or "?"), x)
        elseif x.k == "o" then add("gather", "Gathered in " .. place(x), x)
        elseif x.k == "i" then add("container", format("Found in %s", x.id and nameOfItem(x.id) or "a container"), x, x.id)
        else add("drop", format("Drops from %s in %s", x.n or "a creature", place(x)), x) end
    end
    for _, x in ipairs(sorted(rec.m, function(a, b) return (a.p or "") < (b.p or "") end)) do
        out.recipes[#out.recipes + 1] = { prof = x.p, uses = x.u or {}, note = x.g }
    end
    for _, x in ipairs(sorted(rec.r, function(a, b) return (a.o or 0) < (b.o or 0) end)) do out.makes[#out.makes + 1] = x.o end
    return out
end

-- The same in words, a line each, the most useful first.
ns.sourceLines = function(id, most)
    local src = ns.itemSources(id)
    local out = {}
    for _, p in ipairs(src.places) do out[#out + 1] = p.text end
    for _, r in ipairs(src.recipes) do
        local uses = {}
        for _, u in ipairs(r.uses) do uses[#uses + 1] = format("%d %s", u.n or 1, nameOfItem(u.id)) end
        out[#out + 1] = format("Made with %s%s", r.prof, #uses > 0 and (": " .. table.concat(uses, ", ")) or "") .. whose({ g = r.note })
    end
    if #src.makes > 0 then
        local names = {}
        for k = 1, min(#src.makes, 3) do names[#names + 1] = nameOfItem(src.makes[k]) end
        out[#out + 1] = "Used to make " .. table.concat(names, ", ") .. (#src.makes > 3 and format(" and %d more", #src.makes - 3) or "")
    end
    if most and #out > most then
        local n = #out - most + 1
        for _ = 1, n do table.remove(out) end
        out[#out + 1] = ns.GREY .. format("%d more places it comes from", n) .. "|r"
    end
    return out
end

-- The item page's lines below the tooltip: the price, who can make it and whose recipes use it
-- (Crafting.lua), then where it comes from (the first few, or with all every place).
ns.itemPageLines = function(id, all)
    local out = {}
    local price = ns.priceLine and ns.priceLine(id)
    if price then out[#out + 1] = price end
    for _, l in ipairs(ns.craftLines and ns.craftLines(id) or {}) do out[#out + 1] = l end
    for _, l in ipairs(ns.sourceLines(id, not all and ns.ITEM_PAGE_SOURCES or nil)) do out[#out + 1] = l end
    return out
end
