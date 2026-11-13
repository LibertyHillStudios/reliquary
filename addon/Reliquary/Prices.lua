-- Auction prices. Reliquary reads the auction house the way Blizzard's own full scan does
-- (C_AuctionHouse.ReplicateItems, the call Auctionator and TSM make): only while you stand at the
-- house, at most once every fifteen minutes (the game's own limit, for the whole account), a few
-- hundred listings a frame. For each item it keeps the cheapest price for one, how many are
-- listed and when; never who sells. With the house open, an item's page in /rq asks it for that
-- item's listings at that moment. A player who turns on "Share prices and sources" offers their
-- newest scan to the guild, which takes it in parts on the guild channel. The game keeps only the
-- newest scan of each house; the dashboard on your PC keeps thirty days of them. Blizzard's own
-- hourly prices, which the dashboard reads from Blizzard's web API and hands the game while it is
-- closed (ReliquaryBlizzard), are kept the same way, and pass through the guild whoever has them:
-- they name no player, so no switch holds them back, and Blizzard's terms keep them thirty days at
-- most. Nothing here buys, sells or bids: those are the game's protected calls, and Reliquary never
-- makes them.
local ADDON, ns = ...

local call, num, str, plain, api, on, inCombat = ns.call, ns.num, ns.str, ns.plain, ns.api, ns.on, ns.inCombat
local pairs, ipairs, type, next, format, min, max, floor, random = pairs, ipairs, type, next, string.format, math.min, math.max, math.floor, math.random

local SCAN_GAP = 15 * 60    -- one full scan a quarter hour, account-wide, as the game allows
local PER_FRAME = 250       -- listings read each frame
local HUGE = 60000          -- past this many listings a house gets live checks only (full scans of the biggest have dropped players)
local PART_ITEMS = 600      -- items in each part of a scan shared with the guild
local PARTS_MAX = 60
local SHARE_GAP = 30 * 60   -- the same scan goes to the guild at most this often
local FRESH = 7 * 86400     -- an older price stays off the game's tooltips
local CLOCK_SLACK = 3600    -- how far ahead of yours another player's clock may run
local KEEP_API = 30 * 86400 -- Blizzard's terms: their prices are kept thirty days at most
local AH = api("C_AuctionHouse") or {}

local function N(v, lo, hi) return ns.cleanNum(v, lo, hi) end
local function S(v, n) return ns.cleanStr(v, n) end
-- A house's key as another player sends it: "Realm|Side", its one pipe the separator.
local function houseKey(v)
    local k = ns.cleanKey(v, 80)
    return k and k:match("^[^|]+|%a+$") and k or nil
end

-- Money as the game writes it: "1g 18s 50c".
local function moneyText(c)
    c = floor(c or 0)
    local g, s, k = floor(c / 10000), floor(c / 100) % 100, c % 100
    local bits = {}
    if g > 0 then bits[#bits + 1] = g .. "g" end
    if s > 0 then bits[#bits + 1] = s .. "s" end
    if k > 0 or #bits == 0 then bits[#bits + 1] = k .. "c" end
    return table.concat(bits, " ")
end
ns.moneyText = moneyText

-- With the game's coin icons where it has them.
local function money(c)
    if type(GetMoneyString) == "function" then
        local ok, s = pcall(GetMoneyString, floor(c), true)
        if ok and type(s) == "string" and s ~= "" then return s end
    end
    return moneyText(c)
end

local function agoText(t)
    local s = max(0, time() - (t or 0))
    if s < 90 then return "just now" end
    if s < 3600 then return floor(s / 60 + 0.5) .. " min ago" end
    if s < 86400 then return floor(s / 3600 + 0.5) .. " h ago" end
    local d = floor(s / 86400 + 0.5)
    return d == 1 and "yesterday" or (d .. " days ago")
end
ns.agoText = agoText

local function prices()
    ns.db.prices = type(ns.db.prices) == "table" and ns.db.prices or {}
    return ns.db.prices
end

local function changed()
    ns.dataChanged("prices")
    if ns.onPricesChanged then pcall(ns.onPricesChanged) end
end

---------------------------------------------------------------------------
-- Which house: your realm, and Alliance, Horde or neutral
---------------------------------------------------------------------------
-- The auctioneer's own side says which house this is: a goblin's is neutral. Without one, your own.
local function houseNow()
    local realm = str(call(GetRealmName)) or "?"
    local side
    if plain(call(UnitExists, "npc")) == true then
        local f = str(call(UnitFactionGroup, "npc"))
        side = (f == "Alliance" or f == "Horde") and f or "Neutral"
    else
        side = str(call(UnitFactionGroup, "player"))
        if side ~= "Alliance" and side ~= "Horde" then side = "Neutral" end
    end
    return realm .. "|" .. side
end

local house   -- the house you stand at now
local reading -- the full scan being read: { key, total, i, items, at }

---------------------------------------------------------------------------
-- The full scan
---------------------------------------------------------------------------
-- Keeps a scan as the house's newest, with any live checks made since it began.
local function keepScan(key, scan)
    local old = prices()[key]
    for id, e in pairs(type(old) == "table" and type(old.items) == "table" and old.items or {}) do
        if type(e) == "table" and num(e.at) and e.at >= scan.at then scan.items[id] = e end
    end
    prices()[key] = scan
    changed()
end

local function finish(s)
    reading = nil
    if not next(s.items) then return end
    keepScan(s.key, { at = s.at, by = ns.char and ns.char.name, own = true, n = s.total, items = s.items })
    -- Guildmates who use Reliquary hear there is a newer scan, if you share them.
    if ns.db.settings.sharePrices == true and ns.guildHello then ns.guildHello() end
end

local function readSome()
    local s = reading
    if not (s and house == s.key) then -- the house closed: an unfinished read is dropped
        reading = nil
        return
    end
    local last = min(s.total, s.i + PER_FRAME)
    for i = s.i, last - 1 do -- the game counts these from 0
        local _, _, count, _, _, _, _, _, _, buyout, _, _, _, _, _, _, id = call(AH.GetReplicateItemInfo, i)
        count, buyout, id = num(count), num(buyout), num(id)
        if id and id > 0 and count and count > 0 and buyout and buyout > 0 then
            local unit = floor(buyout / count)
            local e = s.items[id]
            if e then
                if unit < e.p then e.p = unit end
                e.q = e.q + count
            else
                s.items[id] = { p = unit, q = count }
            end
        end
    end
    s.i = last
    if s.i >= s.total then
        finish(s)
    elseif C_Timer then
        C_Timer.After(0, readSome)
    end
end

-- The game says the house's listings are here: read them, whoever asked for them.
on("REPLICATE_ITEM_LIST_UPDATE", function()
    if not (ns.db and house) or reading then return end
    local total = num(call(AH.GetNumReplicateItems)) or 0
    if total <= 0 then return end
    reading = { key = house, total = total, i = 0, items = {}, at = time() }
    readSome()
end)

on("AUCTION_HOUSE_SHOW", function()
    house = houseNow()
    if not (ns.db and AH.ReplicateItems and C_Timer) then return end
    local last = prices()[house]
    if type(last) == "table" and (num(last.n) or 0) > HUGE then return end
    C_Timer.After(2, function()
        if not house or reading or inCombat() then return end
        if time() - (num(ns.db.scanAt) or 0) < SCAN_GAP then return end
        ns.db.scanAt = time()
        call(AH.ReplicateItems)
    end)
end)

on("AUCTION_HOUSE_CLOSED", function() house = nil end)

---------------------------------------------------------------------------
-- The live check: an item's page asks the open house about that item now
---------------------------------------------------------------------------
local wanted = {} -- [itemID] = when its page asked

ns.checkPrice = function(id)
    id = num(id)
    if not (house and id and AH.SendSearchQuery and AH.MakeItemKey) or inCombat() then return false end
    if wanted[id] and time() - wanted[id] < 20 then return false end
    local key = call(AH.MakeItemKey, id)
    if type(key) ~= "table" then return false end
    wanted[id] = time()
    call(AH.SendSearchQuery, key, { { sortOrder = api("Enum.AuctionHouseSortOrder.Price") or 0, reverseSort = false } }, false)
    return true
end
ns.checkingPrice = function(id) return house ~= nil and wanted[id] ~= nil and time() - wanted[id] < 20 end

-- What the check found: the cheapest for one (none listed: nil), how many, and whether the game
-- sent them all.
local function keepLive(id, p, q, full)
    wanted[id] = nil
    local t = prices()
    local h = type(t[house]) == "table" and t[house] or { items = {} }
    t[house] = h
    h.items = type(h.items) == "table" and h.items or {}
    h.items[id] = { p = p, q = q, at = time(), more = (not full and q > 0) or nil }
    changed()
end

on("COMMODITY_SEARCH_RESULTS_UPDATED", function(itemID)
    local id = num(itemID)
    if not (id and wanted[id] and house) then return end
    local p, q = nil, 0
    for i = 1, num(call(AH.GetNumCommoditySearchResults, id)) or 0 do
        local r = call(AH.GetCommoditySearchResultInfo, id, i)
        local unit, qty = type(r) == "table" and num(r.unitPrice), type(r) == "table" and num(r.quantity)
        if unit and unit > 0 and qty and qty > 0 then
            p = p and min(p, unit) or unit
            q = q + qty
        end
    end
    keepLive(id, p, q, plain(call(AH.HasFullCommoditySearchResults, id)) == true)
end)

on("ITEM_SEARCH_RESULTS_UPDATED", function(itemKey)
    local id = type(itemKey) == "table" and num(itemKey.itemID)
    if not (id and wanted[id] and house) then return end
    local p, q = nil, 0
    for i = 1, num(call(AH.GetNumItemSearchResults, itemKey)) or 0 do
        local r = call(AH.GetItemSearchResultInfo, itemKey, i)
        local buyout, qty = type(r) == "table" and num(r.buyoutAmount), type(r) == "table" and (num(r.quantity) or 1)
        if buyout and buyout > 0 and qty and qty > 0 then
            local unit = floor(buyout / qty)
            p = p and min(p, unit) or unit
            q = q + qty
        end
    end
    keepLive(id, p, q, plain(call(AH.HasFullItemSearchResults, itemKey)) == true)
end)

---------------------------------------------------------------------------
-- What an item costs
---------------------------------------------------------------------------
-- The newest price of an item at the houses you can use, your realm's own faction's and its neutral
-- one, your own faction's first:
-- { p (nil when none is listed), q, at, side, by, own, live, more } or nil. When no house has a
-- word on the item, the newest full scan that didn't list it says none were listed then (a house
-- only checked item by item has no scan time, and says nothing of the rest).
local function priceFor(id)
    if not (ns.db and id) then return nil end
    local realm = str(call(GetRealmName))
    local mine = str(call(UnitFactionGroup, "player"))
    local best, unlisted
    local function better(a, b) return not b or a.rank > b.rank or (a.rank == b.rank and a.at > b.at) end
    for key, h in pairs(type(ns.db.prices) == "table" and ns.db.prices or {}) do
        local r, side = tostring(key):match("^(.*)|(%a+)$")
        local e = type(h) == "table" and type(h.items) == "table" and h.items[id]
        local rank = side == mine and 2 or 1
        local usable = r == realm and (side == mine or side == "Neutral" or not mine)
        if usable and type(e) == "table" then
            local word = { p = num(e.p), q = num(e.q) or 0, at = num(e.at) or num(h.at) or 0, side = side, by = h.by, own = h.own, api = h.api and e.at == nil,
                live = e.at ~= nil, more = e.more, rank = rank }
            if better(word, best) then best = word end
        elseif usable and type(h) == "table" and num(h.at) then
            local word = { q = 0, at = num(h.at), side = side, by = h.by, own = h.own, api = h.api, live = false, rank = rank }
            if better(word, unlisted) then unlisted = word end
        end
    end
    return best or unlisted
end
ns.priceFor = priceFor

local function stackable(id)
    local stack = num(select(8, call(api("C_Item.GetItemInfo") or GetItemInfo, id)))
    return stack ~= nil and stack > 1
end

-- For the Auction line under an item on the game's tooltips: "18s 50c each", from a real price no
-- older than a week (a scan that didn't list the item says nothing there).
ns.priceValue = function(id)
    local x = priceFor(id)
    if not (x and x.p and time() - x.at <= FRESH) then return nil end
    return money(x.p) .. (stackable(id) and " each" or "")
end
-- The same with its label: "Auction 18s 50c each".
ns.priceWords = function(id)
    local v = ns.priceValue(id)
    return v and ("Auction " .. v) or nil
end

-- Whose word a price is and when ("your scan, 2 h ago"), and which house when it isn't yours.
local function about(x)
    local whose = x.live and ("checked " .. agoText(x.at))
        or format("%s, %s", x.api and "Blizzard's hourly prices" or x.own and "your scan" or ((x.by or "a guildmate") .. "'s scan"), agoText(x.at))
    local side = x.side ~= str(call(UnitFactionGroup, "player")) and (x.side == "Neutral" and " at the neutral house" or (" at the " .. x.side .. " house")) or ""
    return whose, side
end

-- For an item's page: the price, how many are listed, and whose word it is and when.
ns.priceLine = function(id)
    if ns.checkingPrice(id) then return "Auction: asking the auction house..." end
    local x = priceFor(id)
    if not x then return nil end
    local whose, side = about(x)
    if not x.p then return format("Auction: none listed%s · %s", side, whose) end
    return format("Auction: %s%s, %s%s listed%s · %s", money(x.p), stackable(id) and " each" or "", x.q, x.more and "+" or "", side, whose)
end
-- The same apart, for the page's Auction row: the price ("18s 50c each"; none while the house is
-- asked, `waiting`, or when nothing is listed, `none`) and what it rests on ("20 listed · your scan,
-- 2 h ago").
ns.priceParts = function(id)
    if ns.checkingPrice(id) then return { waiting = true } end
    local x = priceFor(id)
    if not x then return nil end
    local whose, side = about(x)
    if not x.p then return { none = true, about = (side ~= "" and (side:sub(2) .. " · ") or "") .. whose } end
    return { value = money(x.p) .. (stackable(id) and " each" or ""), about = format("%s%s listed%s · %s", x.q, x.more and "+" or "", side, whose) }
end

---------------------------------------------------------------------------
-- Shared in the guild, for those who turn it on
---------------------------------------------------------------------------
local askedFor, othersAsked, sentAt, incoming = {}, {}, {}, {}
local heardOffers = {} -- [house] = { at, t }: the newest offer heard in the guild for a house, and when (time())
local asking = {}      -- [house|at] = time(): when someone in the guild, you too, last asked for those prices
local ASK_WAIT = 300   -- while an ask is this fresh nobody else asks for the same: its answer reaches all

-- The newest scans you offer in your hello to the guild: Blizzard's prices always (they name no
-- player), your own while you share them; never one you sent so lately that you wouldn't send it.
local function offered(h)
    return type(h) == "table" and (h.api or (h.own and ns.db.settings.sharePrices == true)) and type(h.items) == "table"
end
local function sentLately(key, at) return sentAt[key .. at] and time() - sentAt[key .. at] < SHARE_GAP end
ns.priceOffer = function()
    if not ns.db then return nil end
    local out = {}
    for key, h in pairs(prices()) do
        if offered(h) and num(h.at) and time() - h.at <= FRESH and not sentLately(key, h.at) then out[#out + 1] = { h = key, at = h.at } end
    end
    table.sort(out, function(a, b) return a.at > b.at end)
    while #out > 4 do table.remove(out) end
    return #out > 0 and out or nil
end


-- A guildmate offers a scan newer than yours: ask for it on the guild channel, where one answer
-- serves everyone who wants it.
ns.onPriceOffer = function(list, who)
    if not (ns.db and C_Timer) or type(list) ~= "table" then return end
    for k = 1, min(#list, 4) do
        local x = list[k]
        local key = type(x) == "table" and houseKey(x.h)
        local at = type(x) == "table" and N(x.at, 1, time() + CLOCK_SLACK)
        local mine = key and prices()[key]
        if key and at and key:find("|", 1, true) then
            local seen = heardOffers[key]
            if not seen or at > seen.at then heardOffers[key] = { at = at, t = time() } elseif at == seen.at then seen.t = time() end
        end
        if key and at and key:find("|", 1, true) and at > (type(mine) == "table" and num(mine.at) or 0) then
            local tag, want = who .. "|" .. key .. "|" .. at, key .. "|" .. at
            if not askedFor[tag] then
                askedFor[tag] = time()
                C_Timer.After(1 + random() * 4, function()
                    -- Someone asked them meanwhile, or the prices came: nothing to ask.
                    local now = prices()[key]
                    if othersAsked[tag] or (type(now) == "table" and num(now.at) or 0) >= at then return end
                    -- An ask for the same prices is out (of another who has them): its answer reaches
                    -- you too. Should it not come, they may be asked when they offer again.
                    if asking[want] and time() - asking[want] < ASK_WAIT then
                        askedFor[tag] = nil
                        return
                    end
                    asking[want] = time()
                    ns.send({ kind = "GUILD" }, { t = "pr?", to = who, h = key, at = at }, true)
                end)
            end
        end
    end
end

-- Whether to answer a guildmate's hello with your offers: you hold one newer than any offer heard in
-- the guild since (time()): theirs, and anyone else's who answered first.
ns.priceAnswer = function(since)
    for _, x in ipairs(ns.priceOffer() or {}) do
        local seen = heardOffers[x.h]
        if not (seen and seen.at >= x.at and seen.t >= since) then return true end
    end
    return false
end

ns.handlers["pr?"] = function(msg, route, who)
    if route.kind ~= "GUILD" then return end
    local key, at, to = houseKey(msg.h), N(msg.at, 1), S(msg.to, 64)
    if not (key and at and to) then return end
    asking[key .. "|" .. at] = time()
    if to ~= ns.me() then
        othersAsked[to .. "|" .. key .. "|" .. at] = true
        return
    end
    local h = prices()[key]
    if not (offered(h) and h.at == at) or sentLately(key, at) then return end
    sentAt[key .. at] = time()
    local ids = {}
    for id, e in pairs(h.items) do if type(e) == "table" and num(e.p) then ids[#ids + 1] = id end end
    table.sort(ids)
    local parts = min(PARTS_MAX, max(1, math.ceil(#ids / PART_ITEMS)))
    for k = 1, parts do
        local l = {}
        for j = (k - 1) * PART_ITEMS + 1, min(#ids, k * PART_ITEMS) do
            local e = h.items[ids[j]]
            l[#l + 1], l[#l + 2], l[#l + 3] = ids[j], e.p, e.q or 0
        end
        ns.send({ kind = "GUILD" }, { t = "pr", h = key, at = at, k = k, of = parts, n = h.n, b = h.api and 1 or nil, l = l })
    end
end

-- A guildmate's scan, in parts: kept once every part is here, if it's newer than yours. One marked
-- Blizzard's (b) is Blizzard's prices, whoever passed them on, and none older than thirty days.
ns.handlers.pr = function(msg, route, who)
    if route.kind ~= "GUILD" then return end
    local key, at = houseKey(msg.h), N(msg.at, 1, time() + CLOCK_SLACK)
    local k, of = N(msg.k, 1, PARTS_MAX), N(msg.of, 1, PARTS_MAX)
    if not (key and at and k and of and k <= of and type(msg.l) == "table" and key:find("|", 1, true)) then return end
    local blizzard = msg.b == 1
    if blizzard and time() - at > KEEP_API then return end
    local mine = prices()[key]
    if at <= (type(mine) == "table" and num(mine.at) or 0) then return end
    for tag, inc in pairs(incoming) do if time() - inc.t > 600 then incoming[tag] = nil end end
    local tag = who .. "|" .. key .. "|" .. at .. (blizzard and "|b" or "")
    local inc = incoming[tag]
    if not inc or inc.of ~= of then
        inc = { of = of, got = 0, parts = {}, n = N(msg.n, 0, 1e7), t = time() }
        incoming[tag] = inc
    end
    if inc.parts[k] then return end
    local items, l = {}, msg.l
    for j = 1, min(#l, PART_ITEMS * 3), 3 do
        local id, p, q = N(l[j], 1, 1e7), N(l[j + 1], 1, 1e12), N(l[j + 2], 0, 1e7)
        if id and p then items[id] = { p = p, q = q or 0 } end
    end
    inc.parts[k], inc.got = items, inc.got + 1
    if inc.got < of then return end
    incoming[tag] = nil
    asking[key .. "|" .. at] = nil -- answered
    local all = {}
    for _, part in pairs(inc.parts) do for id, e in pairs(part) do all[id] = e end end
    if blizzard then
        keepScan(key, { at = at, by = "Blizzard", api = true, n = inc.n, items = all })
    else
        keepScan(key, { at = at, by = ns.callName(who), n = inc.n, items = all })
    end
end

---------------------------------------------------------------------------
-- Blizzard's prices from the dashboard, and their thirty days
---------------------------------------------------------------------------
-- What the dashboard on your PC handed the game while it was closed: each of your houses' newest
-- read from Blizzard, kept like a scan when it's newer than what you have, then let go (the game
-- writes back nothing of it).
local function takeFeed()
    local feed = ReliquaryBlizzard
    ReliquaryBlizzard = nil
    if type(feed) ~= "table" then return end
    for key, h in pairs(feed) do
        key = houseKey(key)
        local at = type(h) == "table" and N(h.at, 1, time() + CLOCK_SLACK)
        local mine = key and prices()[key]
        if key and at and time() - at <= KEEP_API and type(h.items) == "table" and at > (type(mine) == "table" and num(mine.at) or 0) then
            local items = {}
            for id, e in pairs(h.items) do
                id = N(id, 1, 1e7)
                local p, q = type(e) == "table" and N(e.p, 1, 1e12), type(e) == "table" and N(e.q, 0, 1e7)
                if id and p then items[id] = { p = p, q = q or 0 } end
            end
            if next(items) then keepScan(key, { at = at, by = "Blizzard", api = true, n = N(h.n, 0, 1e7), items = items }) end
        end
    end
end

-- Blizzard's prices go after thirty days; checks made at the house since stay.
local function letOldGo()
    for key, h in pairs(prices()) do
        if type(h) == "table" and h.api and time() - (num(h.at) or 0) > KEEP_API then
            local kept = {}
            for id, e in pairs(type(h.items) == "table" and h.items or {}) do
                if type(e) == "table" and num(e.at) and time() - e.at <= KEEP_API then kept[id] = e end
            end
            prices()[key] = next(kept) and { items = kept } or nil
        end
    end
end

on("PLAYER_LOGIN", function()
    if not ns.db then return end
    pcall(letOldGo)
    pcall(takeFeed)
end)
