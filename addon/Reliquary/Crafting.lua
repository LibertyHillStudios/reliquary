-- Reliquary crafting: what each of your characters can make. The game's own profession window is
-- read while it shows this character's own profession (never another player's linked one, the
-- guild's or an NPC's), and the recipes go with its professions to whoever sees them (the "craft"
-- section of its card). From your characters' recipes and those your guildmates and friends share,
-- Reliquary says who can make an item and whose recipes use it: on the item's page, in its one
-- tooltip line, and in chat when you loot something no profession of yours uses but someone else's
-- recipes do, so it can go to them. Nothing here presses a key or acts in the game.
local ADDON, ns = ...

local call, num, str, plain, api, on, inCombat = ns.call, ns.num, ns.str, ns.plain, ns.api, ns.on, ns.inCombat
local pairs, ipairs, type, next, tostring, tonumber = pairs, ipairs, type, next, tostring, tonumber
local format, min, floor, sort, concat = string.format, math.min, math.floor, table.sort, table.concat
local issecretvalue = issecretvalue or function() return false end

local CRAFT_GAP = 300          -- seconds between two announcements of your recipes (they change in bursts)
local READ_AGAIN = 60          -- a profession's window is read again this soon only when something changed
local PER_FRAME = 30           -- recipes read a frame
local PROFS_MAX = 8            -- professions a card carries
local RECIPES_MAX = 900        -- recipes one profession carries
local RECIPES_TOTAL = 2000     -- recipes one card carries
local REAGENTS_MAX = 12        -- what one recipe is made with
local CATS_MAX = 60            -- the window's groups of recipes, in one profession
local TELL_AGAIN = 20 * 3600   -- an item looted again is mentioned again after this long
local NAMES_SHOWN = 3          -- names in one line before "and N more"
local WIRE_MAX = 60 * 250      -- the most one section may pack into (Share.lua sends 61 pieces of 250 at most)

-- Recipe items name the profession they are for by their kind (Enum.ItemRecipeSubclass); these are
-- those professions' skill lines, which are the same in every language.
local RECIPE_ITEM = 9 -- Enum.ItemClass.Recipe
local RECIPE_LINES = { [1] = 165, [2] = 197, [3] = 202, [4] = 164, [5] = 185, [6] = 171, [7] = 129, [8] = 333, [9] = 356, [10] = 755, [11] = 773 }
-- Trade goods the game files under one profession, by kind (Enum.ItemTradeGoodsSubclass): cooking
-- ingredients, enchanting materials, engineering parts, explosives and devices, jewelcrafting and
-- inscription materials. Cloth, leather, herbs, metal and the rest go into several professions.
-- Only an item the game marks as a crafting reagent counts.
local TRADE_GOODS = 7 -- Enum.ItemClass.Tradegoods
local REAGENT_LINES = { [8] = 185, [12] = 333, [1] = 202, [2] = 202, [3] = 202, [17] = 202, [4] = 755, [16] = 773 }
local LINE_NAMES = { [185] = "Cooking", [333] = "Enchanting", [202] = "Engineering", [755] = "Jewelcrafting", [773] = "Inscription" }

local function N(v, lo, hi) return ns.cleanNum(v, lo, hi) end
local function S(v, n) return ns.cleanStr(v, n) end

local function changed()
    if ns.cardChanged then pcall(ns.cardChanged) end
    if ns.dataChanged then pcall(ns.dataChanged) end
end

local function spellName(id)
    local name = str(call(api("C_Spell.GetSpellName"), id))
    if name then return name end
    local info = call(api("C_Spell.GetSpellInfo"), id)
    if type(info) == "table" and str(info.name) then return str(info.name) end
    return str((call(GetSpellInfo, id)))
end

local function itemName(id)
    local rec = ns.db and ns.db.items[id]
    local n = type(rec) == "table" and type(rec.info) == "table" and str(rec.info.name)
    return n or str((call(api("C_Item.GetItemInfo") or GetItemInfo, id)))
end

-- An item's link for a line in chat, as the game gives it (its colour, clickable).
local function itemLink(id)
    local _, link = call(api("C_Item.GetItemInfo") or GetItemInfo, id)
    link = str(link)
    if link then return link end
    local name = itemName(id)
    return name and ("[" .. name .. "]") or ("item " .. id)
end

-- The dashboard shows what recipes make and use with their names and tooltips: each is read once,
-- a few at a time and never in a fight, unless Reliquary keeps it already.
local tipQueue, tipNext, tipLast, tipQueued, tipDraining = {}, 1, 0, {}, false
local function drain()
    tipDraining = false
    if not (ns.db and ns.rememberLink) then return end
    if not inCombat() then
        for _ = 1, 8 do
            local id = tipQueue[tipNext]
            if not id then break end
            tipQueue[tipNext], tipNext = nil, tipNext + 1
            if not ns.db.items[id] then ns.rememberLink(id, "item:" .. id) end
        end
    end
    if tipQueue[tipNext] then
        tipDraining = true
        C_Timer.After(inCombat() and 2 or 0.2, drain)
    end
end
local function remember(id)
    if not (id and C_Timer) or tipQueued[id] then return end
    tipQueued[id] = true
    tipLast = tipLast + 1
    tipQueue[tipLast] = id
    if not tipDraining then
        tipDraining = true
        C_Timer.After(0.2, drain)
    end
end

-- Whether a character practises a profession, by its name or skill line. Before its professions
-- have been read, everything read from its windows counts.
local function practises(c, name, line)
    local profs = type(c) == "table" and type(c.profs) == "table" and c.profs or {}
    if #profs == 0 then return true end
    for _, p in ipairs(profs) do
        if type(p) == "table" and ((name and p.name == name) or (line and num(p.line) == line)) then return true end
    end
    return false
end

---------------------------------------------------------------------------
-- Your recipes, from the game's own profession window
---------------------------------------------------------------------------
-- Another player's linked profession, the guild's, an NPC's crafting and runeforging are never
-- recorded as yours; nor is anything when the game won't say which it is.
local NOT_YOURS = { "IsTradeSkillLinked", "IsTradeSkillGuild", "IsTradeSkillGuildMember", "IsNPCCrafting", "IsRuneforging" }
local function ownWindow(TS)
    for _, fn in ipairs(NOT_YOURS) do
        local v = call(TS[fn])
        if v ~= nil and (issecretvalue(v) or v == true) then return false end
    end
    return true
end

-- What a recipe makes and what goes into it, from its schematic, which the game gives for any
-- recipe whether or not its window is open (Blizzard's own recipe tracker reads it so).
local function schematic(TS, rid, rec)
    local sch = call(TS.GetRecipeSchematic, rid, false)
    if type(sch) == "table" then
        rec.o = num(sch.outputItemID)
        local k = num(sch.quantityMin)
        if rec.o and k and k > 1 then rec.k = k end
        rec.n, rec.ic = rec.n or str(sch.name), rec.ic or num(sch.icon)
        local uses = {}
        for _, slot in ipairs(type(sch.reagentSlotSchematics) == "table" and sch.reagentSlotSchematics or {}) do
            local r = type(slot) == "table" and type(slot.reagents) == "table" and slot.reagents[1]
            local id = type(r) == "table" and num(r.itemID)
            if id and id > 0 and plain(slot.required) ~= false and #uses < REAGENTS_MAX then
                uses[#uses + 1] = { id = id, n = num(slot.quantityRequired) or 1 }
            end
        end
        if #uses > 0 then rec.u = uses end
    end
    if not (rec.n or rec.o) then return nil end
    return rec
end

-- One learned recipe as the window has it: its name and icon, the window's group, how it would
-- skill up (0 best to 3 not at all), what it makes (and how many, if more than one) and what it
-- is made with. Recipes that make nothing to keep (gathering, salvage, recrafting) are left out.
local function readOne(TS, rid)
    local info = call(TS.GetRecipeInfo, rid)
    if type(info) ~= "table" or plain(info.learned) ~= true then return nil end
    for _, flag in ipairs({ "isDummyRecipe", "isGatheringRecipe", "isSalvageRecipe", "isRecraft" }) do
        if plain(info[flag]) == true then return nil end
    end
    return schematic(TS, rid, { n = str(info.name), ic = num(info.icon), c = num(info.categoryID), d = num(info.relativeDifficulty) })
end

-- A recipe the game has just said you learned: as the window describes it if it's open, else from
-- its schematic and its spell's name.
local function readLearned(TS, rid)
    return readOne(TS, rid) or schematic(TS, rid, { n = spellName(rid), ic = num(call(api("C_Spell.GetSpellTexture"), rid)) })
end

-- Where items come from (Sources.lua): what a recipe makes, and what goes into it.
local function noteSources(rid, rec, prof)
    if not (ns.noteSource and rec.o) then return end
    local uses = {}
    for _, u in ipairs(rec.u or {}) do uses[#uses + 1] = { id = u.id, n = u.n } end
    ns.noteSource(rec.o, "m", rid, { p = prof, u = uses })
    for _, u in ipairs(uses) do ns.noteSource(u.id, "r", rid, { p = prof, o = rec.o }) end
end

local reading                -- the profession being read, a few recipes a frame
local readAt = {}            -- [profession] = { at, sk, again }: its window's last read
local readQueued = false
local windowShown = false    -- the profession window is open (TRADE_SKILL_SHOW until TRADE_SKILL_CLOSE)

local function finish(r)
    readAt[r.prof] = { at = time(), sk = r.sk } -- only a read that finished counts as one
    local c = r.char
    c.recipes = type(c.recipes) == "table" and c.recipes or {}
    local old = c.recipes[r.prof]
    local list = r.list
    -- A recipe once learned is never forgotten while its profession is kept, so a read only adds:
    -- a client without the full list gives only what its window's filters let through, and a list
    -- the game is still filling in gives part of it. A profession learned afresh (its skill fell)
    -- starts again.
    local cats = {}
    if type(old) == "table" and type(old.list) == "table" and not (num(old.sk) and r.sk and r.sk < old.sk) then
        for rid, rec in pairs(old.list) do if list[rid] == nil then list[rid] = rec end end
        for id, name in pairs(type(old.cats) == "table" and old.cats or {}) do cats[id] = name end -- the groups of those kept
    end
    for id, name in pairs(r.cats) do if name then cats[id] = name end end
    c.recipes[r.prof] = { line = r.line, at = time(), sk = r.sk, mx = r.mx, cats = next(cats) and cats or nil, list = list }
    for rid, rec in pairs(r.list) do noteSources(rid, rec, r.prof) end
    for _, rec in pairs(list) do
        remember(rec.o)
        for _, u in ipairs(rec.u or {}) do remember(u.id) end
    end
    changed()
end

local function step(r)
    if reading ~= r then return end -- the window closed, or shows another profession now
    if inCombat() then C_Timer.After(1, function() step(r) end) return end -- the rest waits out the fight
    local TS = api("C_TradeSkillUI")
    for _ = 1, PER_FRAME do
        if reading ~= r then return end
        r.k = r.k + 1
        local rid = r.ids[r.k]
        if not rid then
            reading = nil
            finish(r)
            return
        end
        local rec = readOne(TS, rid)
        if rec then
            r.list[rid] = rec
            if rec.c and r.cats[rec.c] == nil then
                local ci = call(TS.GetCategoryInfo, rec.c)
                r.cats[rec.c] = type(ci) == "table" and str(ci.name) or false
            end
        end
    end
    C_Timer.After(0, function() step(r) end)
end

local function readWindow()
    readQueued = false
    local TS = api("C_TradeSkillUI")
    if reading or not (windowShown and TS and ns.char and C_Timer) or not ownWindow(TS) then return end
    local info = call(TS.GetBaseProfessionInfo)
    local name = type(info) == "table" and str(info.professionName)
    if not name then return end
    local sk = num(info.skillLevel)
    local last = readAt[name]
    if last and time() - last.at < READ_AGAIN and last.sk == sk and not last.again then return end
    local ids = call(TS.GetAllRecipeIDs)
    if type(ids) ~= "table" then ids = call(TS.GetFilteredRecipeIDs) end
    local list = {}
    for _, rid in ipairs(type(ids) == "table" and ids or {}) do
        rid = num(rid)
        if rid then list[#list + 1] = rid end
    end
    if #list == 0 then return end -- a profession without recipes (gathering), or a list not there yet
    reading = { prof = name, line = num(info.professionID), sk = sk, mx = num(info.maxSkillLevel), ids = list, k = 0, list = {}, cats = {}, char = ns.char }
    step(reading)
end

local function readSoon()
    if readQueued or not C_Timer then return end
    readQueued = true
    C_Timer.After(1, readWindow)
end
on("TRADE_SKILL_SHOW", function()
    windowShown = true
    readSoon()
end)
on("TRADE_SKILL_LIST_UPDATE", readSoon)
on("TRADE_SKILL_DATA_SOURCE_CHANGED", function()
    reading = nil -- another profession, or someone else's: what was being read is let go
    readSoon()
end)
-- A window closed part way through a read gives no more answers: that read is let go.
on("TRADE_SKILL_CLOSE", function() reading, windowShown = nil, false end)

-- A recipe learned with the window closed (from a trainer or a recipe item): it joins its
-- profession at once when the game says which that is, and the window is read afresh next time.
on("NEW_RECIPE_LEARNED", function(recipeID)
    local rid = num(recipeID)
    for _, last in pairs(readAt) do last.again = true end
    local c = ns.char
    if not (rid and c and C_Timer) then return end
    C_Timer.After(1, function()
        local TS = api("C_TradeSkillUI")
        if not TS or ns.char ~= c then return end
        local info = call(TS.GetProfessionInfoByRecipeID, rid)
        local name = type(info) == "table" and (str(info.parentProfessionName) or str(info.professionName))
        local p = name and type(c.recipes) == "table" and c.recipes[name]
        if type(p) ~= "table" or type(p.list) ~= "table" or p.list[rid] then return end -- its window, once read, will have it
        local rec = readLearned(TS, rid)
        if not rec then return end
        p.list[rid], p.at = rec, time()
        noteSources(rid, rec, name)
        remember(rec.o)
        for _, u in ipairs(rec.u or {}) do remember(u.id) end
        changed()
    end)
end)

-- A profession given up takes its recipes with it.
local function tidyRecipes(c)
    if type(c) ~= "table" or type(c.recipes) ~= "table" then return end
    for name, p in pairs(c.recipes) do
        if type(p) ~= "table" or type(p.list) ~= "table" or not practises(c, name, num(p.line)) then c.recipes[name] = nil end
    end
    if next(c.recipes) == nil then c.recipes = nil end
end

---------------------------------------------------------------------------
-- Your recipes in your card, for whoever sees your professions
---------------------------------------------------------------------------
-- Each profession travels as its name, skill line and when it was read, the names of its window's
-- groups, and its recipes as one list of numbers: the recipe, what it makes (0 for nothing, an
-- enchantment), its group (0 for none), how many things it is made with, and each of those with
-- how many. A receiver names the recipes from its own game.
local function wireOf(c, bare, cap)
    local out = {}
    for name, p in pairs(type(c.recipes) == "table" and c.recipes or {}) do
        if type(p) == "table" and type(p.list) == "table" and practises(c, name, num(p.line)) and #out < PROFS_MAX then
            local ids = {}
            for rid in pairs(p.list) do if num(rid) then ids[#ids + 1] = rid end end
            sort(ids)
            local cats, catIndex, flat = {}, {}, {}
            for i = 1, min(#ids, cap or RECIPES_MAX) do
                local rid = ids[i]
                local rec = p.list[rid]
                local ci = 0
                local cname = type(rec) == "table" and rec.c and type(p.cats) == "table" and str(p.cats[rec.c])
                if cname then
                    ci = catIndex[cname]
                    if not ci and #cats < CATS_MAX then
                        cats[#cats + 1] = cname
                        ci = #cats
                        catIndex[cname] = ci
                    end
                    ci = ci or 0
                end
                local uses = {}
                if not (bare and bare[name]) then
                    for _, u in ipairs(type(rec) == "table" and type(rec.u) == "table" and rec.u or {}) do
                        if num(u.id) and #uses < REAGENTS_MAX then uses[#uses + 1] = u end
                    end
                end
                flat[#flat + 1] = rid
                flat[#flat + 1] = type(rec) == "table" and num(rec.o) or 0
                flat[#flat + 1] = ci
                flat[#flat + 1] = #uses
                for _, u in ipairs(uses) do
                    flat[#flat + 1] = u.id
                    flat[#flat + 1] = num(u.n) or 1
                end
            end
            out[#out + 1] = { n = name, l = num(p.line), at = num(p.at), c = #cats > 0 and cats or nil, r = flat, size = #ids }
        end
    end
    sort(out, function(a, b) return a.n < b.n end)
    for _, p in ipairs(out) do p.size = nil end
    return out
end

local function fits(d)
    local n = ns.packedLength and ns.packedLength({ t = "sec", n = "craft", h = "00000000", sc = "gfp", d = d })
    return not n or n <= WIRE_MAX
end

local function build(c, letters)
    if not ns.sees(letters, "profs") then return nil end
    local d = { p = wireOf(c) }
    if #d.p == 0 then return nil end
    if fits(d) then return d end
    -- More than one message can carry: the largest professions go without what their recipes are
    -- made with (what they make stays), and if even that is too much, fewer of their recipes go.
    local sizes = {}
    for name, p in pairs(c.recipes) do
        local n = 0
        for _ in pairs(type(p) == "table" and type(p.list) == "table" and p.list or {}) do n = n + 1 end
        sizes[#sizes + 1] = { name = name, n = n }
    end
    sort(sizes, function(a, b) return a.n > b.n end)
    local bare = {}
    for _, s in ipairs(sizes) do
        bare[s.name] = true
        d = { p = wireOf(c, bare) }
        if fits(d) then return d end
    end
    local cap = RECIPES_MAX
    while cap > 25 do
        cap = floor(cap / 2)
        d = { p = wireOf(c, bare, cap) }
        if fits(d) then return d end
    end
    return nil
end

local function clean(d)
    if type(d) ~= "table" or type(d.p) ~= "table" then return nil end
    local out, total = {}, 0
    for i = 1, min(#d.p, PROFS_MAX) do
        local p = d.p[i]
        local name = type(p) == "table" and S(p.n, 48)
        local flat = type(p) == "table" and type(p.r) == "table" and p.r or nil
        if name and flat then
            local cats = {}
            for k = 1, min(type(p.c) == "table" and #p.c or 0, CATS_MAX) do cats[k] = S(p.c[k], 48) or "" end
            local list, j = {}, 1
            while #list < RECIPES_MAX and total < RECIPES_TOTAL do
                local rid, o, ci, nu = N(flat[j], 1, 1e8), N(flat[j + 1], 0, 1e8), N(flat[j + 2], 0, CATS_MAX), N(flat[j + 3], 0, REAGENTS_MAX)
                if not (rid and o and ci and nu) then break end
                j = j + 4
                local uses = {}
                for _ = 1, nu do
                    local id, n = N(flat[j], 1, 1e8), N(flat[j + 1], 1, 1000)
                    j = j + 2
                    if not (id and n) then uses = nil break end
                    uses[#uses + 1] = { id = id, n = n }
                end
                if not uses then break end
                -- The recipe's name (and, for one that makes no item, an enchantment, its icon) from
                -- this game's own spell data rather than the sender's word.
                list[#list + 1] = { id = rid, o = o > 0 and o or nil, c = ci > 0 and cats[ci] and cats[ci] ~= "" and ci or nil,
                    u = #uses > 0 and uses or nil, nm = spellName(rid), ic = o == 0 and num(call(api("C_Spell.GetSpellTexture"), rid)) or nil }
                total = total + 1
            end
            out[#out + 1] = { n = name, l = N(p.l, 1, 1e6), at = N(p.at, 1), c = #cats > 0 and cats or nil, r = list }
        end
    end
    return #out > 0 and { list = out } or nil
end

-- What arrives is read for the dashboard: the names and tooltips of what each recipe makes and uses.
local function arrived(_, data)
    for _, p in ipairs(data.list) do
        for _, r in ipairs(p.r) do
            remember(r.o)
            for _, u in ipairs(r.u or {}) do remember(u.id) end
        end
    end
end

ns.addSection("craft", { "profs" }, CRAFT_GAP, function(c, letters) return build(c, letters) end, clean, arrived)

---------------------------------------------------------------------------
-- Everyone's recipes: who can make an item, and whose recipes use it
---------------------------------------------------------------------------
-- Everyone whose recipes Reliquary knows, as you can reach them in game: this character ("me"),
-- your other characters on its realm and side ("own"), guildmates who share with the guild ("g")
-- and friends who share with you ("f"). Each with their professions: name, skill line, skill, the
-- most it can reach, and recipes { id, o, u, nm }.
local KIND_ORDER = { me = 0, own = 1, g = 2, f = 3 }

local function ownBook(c)
    local out = {}
    for name, p in pairs(type(c.recipes) == "table" and c.recipes or {}) do
        if type(p) == "table" and type(p.list) == "table" and practises(c, name, num(p.line)) then
            local sk, mx = num(p.sk), num(p.mx)
            for _, cur in ipairs(type(c.profs) == "table" and c.profs or {}) do
                if type(cur) == "table" and cur.name == name then sk, mx = num(cur.skill) or sk, num(cur.max) or mx end
            end
            local list = {}
            for rid, rec in pairs(p.list) do
                if num(rid) and type(rec) == "table" then
                    local cname = rec.c and type(p.cats) == "table" and str(p.cats[rec.c])
                    list[#list + 1] = { id = rid, o = num(rec.o), u = type(rec.u) == "table" and rec.u or nil, nm = str(rec.n), cat = cname or nil, d = num(rec.d), k = num(rec.k) }
                end
            end
            out[#out + 1] = { name = name, line = num(p.line), sk = sk, mx = mx, at = num(p.at), recipes = list }
        end
    end
    return out
end

local function peerBook(p)
    local out = {}
    local craft = type(p.more) == "table" and type(p.more.craft) == "table" and type(p.more.craft.list) == "table" and p.more.craft.list or {}
    local profs = type(p.card) == "table" and type(p.card.profs) == "table" and p.card.profs or {}
    for _, x in ipairs(craft) do
        if type(x) == "table" and x.n and type(x.r) == "table" then
            local sk, mx
            for _, cur in ipairs(profs) do if type(cur) == "table" and cur.n == x.n then sk, mx = cur.sk, cur.mx end end
            local list = {}
            for _, r in ipairs(x.r) do
                if type(r) == "table" and num(r.id) then
                    list[#list + 1] = { id = r.id, o = r.o, u = r.u, nm = r.nm, ic = r.ic, cat = r.c and type(x.c) == "table" and x.c[r.c] ~= "" and x.c[r.c] or nil }
                end
            end
            out[#out + 1] = { name = x.n, line = x.l, sk = sk, mx = mx, at = x.at, recipes = list }
        end
    end
    return out
end

local function people()
    local out = {}
    local c, db = ns.char, ns.db
    if not (c and db) then return out end
    out[#out + 1] = { who = ns.me() or ns.charKey, name = c.name, cls = c.classFile, kind = "me", book = ownBook(c) }
    for key, o in pairs(db.chars) do
        if key ~= ns.charKey and type(o) == "table" and type(o.recipes) == "table" and o.realm == c.realm and o.faction == c.faction then
            out[#out + 1] = { who = "own:" .. key, name = o.name, cls = o.classFile, kind = "own", book = ownBook(o) }
        end
    end
    local gk = ns.guildKey()
    for who, p in pairs(db.peers) do
        if type(p) == "table" and type(p.scopes) == "table" and type(p.more) == "table" and type(p.more.craft) == "table" then
            local kind = (gk and p.scopes.g and p.gk == gk) and "g" or (p.scopes.f and "f") or nil
            if kind then
                local card = type(p.card) == "table" and p.card or {}
                out[#out + 1] = { who = who, name = card.name or ns.shortName(who), cls = card.classFile, kind = kind, book = peerBook(p) }
            end
        end
    end
    return out
end

-- What the index was built from: your characters' recipes and professions, and the recipes others
-- share and how; looked at once a second at most.
local sig, sigAt
local function signature()
    local t = num(call(GetTime)) or time()
    if sig and sigAt and t - sigAt < 1 then return sig end
    local g = ns.myGuild and ns.myGuild()
    local parts = { tostring(ns.charKey), tostring(ns.guildKey()), tostring(g and g.at) }
    for key, c in pairs(ns.db.chars) do
        if type(c) == "table" and type(c.recipes) == "table" then
            for name, p in pairs(c.recipes) do
                local n = 0
                for _ in pairs(type(p) == "table" and type(p.list) == "table" and p.list or {}) do n = n + 1 end
                parts[#parts + 1] = key .. "|" .. tostring(name) .. "|" .. tostring(type(p) == "table" and p.at) .. "|" .. n
            end
        end
        if type(c) == "table" then
            for _, p in ipairs(type(c.profs) == "table" and c.profs or {}) do
                if type(p) == "table" then parts[#parts + 1] = key .. "|p|" .. tostring(p.name) .. "|" .. tostring(p.skill) end
            end
        end
    end
    -- Others' recipes, and their cards (which carry their professions).
    for who, p in pairs(ns.db.peers) do
        if type(p) == "table" and type(p.hashes) == "table" and (p.hashes.craft or p.hashes.core) and type(p.scopes) == "table" then
            parts[#parts + 1] = who .. "|" .. tostring(p.hashes.craft) .. "|" .. tostring(p.hashes.core) .. "|" .. (p.scopes.g and "g" or "") .. (p.scopes.f and "f" or "") .. "|" .. tostring(p.gk)
        end
    end
    sort(parts)
    sig, sigAt = concat(parts, ";"), t
    return sig
end

-- You first, then your other characters, guildmates in the game now, the rest of the guild, and
-- friends; by name within each.
local function order(a, b)
    if KIND_ORDER[a.kind] ~= KIND_ORDER[b.kind] then return KIND_ORDER[a.kind] < KIND_ORDER[b.kind] end
    if (a.on and 0 or 1) ~= (b.on and 0 or 1) then return a.on ~= nil end
    if (a.name or "") ~= (b.name or "") then return (a.name or "") < (b.name or "") end
    return (a.prof or "") < (b.prof or "")
end

local built, builtSig
local function index()
    local s = signature()
    if built and builtSig == s then return built end
    local makes, uses, made, madeSeen = {}, {}, {}, {}
    local everyone = people()
    local online = {}
    local g = ns.myGuild and ns.myGuild()
    for _, m in ipairs(g and type(g.members) == "table" and g.members or {}) do
        if type(m) == "table" and m.n and m.on and not m.mobile then online[ns.fullName(m.n)] = true end
    end
    for _, person in ipairs(everyone) do
        person.on = online[person.who] or nil
        for _, prof in ipairs(person.book) do
            for _, r in ipairs(prof.recipes) do
                local base = { who = person.who, name = person.name, cls = person.cls, kind = person.kind, on = person.on, prof = prof.name, line = prof.line }
                if r.o then
                    -- Each way to make it once: its profession and what goes into it.
                    local parts = {}
                    for _, u in ipairs(r.u or {}) do parts[#parts + 1] = (u.id or 0) .. "x" .. (u.n or 1) end
                    local key = r.o .. "|" .. prof.name .. ":" .. table.concat(parts, ",")
                    if not madeSeen[key] then
                        madeSeen[key] = true
                        local ways = made[r.o] or {}
                        made[r.o] = ways
                        ways[#ways + 1] = { prof = prof.name, uses = r.u or {} }
                    end
                    local list = makes[r.o] or {}
                    makes[r.o] = list
                    local seen = false
                    for _, e in ipairs(list) do if e.who == person.who and e.prof == prof.name then seen = true end end
                    if not seen then
                        base.rid, base.nm = r.id, r.nm
                        list[#list + 1] = base
                    end
                end
                for _, u in ipairs(r.u or {}) do
                    local list = uses[u.id] or {}
                    uses[u.id] = list
                    local e
                    for _, x in ipairs(list) do if x.who == person.who and x.prof == prof.name then e = x end end
                    if not e then
                        e = { who = person.who, name = person.name, cls = person.cls, kind = person.kind, on = person.on, prof = prof.name, line = prof.line, recipes = {} }
                        list[#list + 1] = e
                    end
                    e.recipes[#e.recipes + 1] = { id = r.id, o = r.o, nm = r.nm, n = u.n }
                end
            end
        end
    end
    for _, list in pairs(makes) do sort(list, order) end
    for _, list in pairs(uses) do sort(list, order) end
    sort(everyone, order)
    built, builtSig = { makes = makes, uses = uses, made = made, people = everyone, online = online, byLine = {} }, s
    return built
end

-- What a recipe item teaches, as the game describes the item: its profession (by kind and skill
-- line), the recipe's name (what follows "Pattern:", "Plans:" and the like) and the skill it needs
-- ("Requires Leatherworking (100)", the game's own words). Nil for any other item.
local SKILL_LINE = (str(ITEM_MIN_SKILL) or "Requires %s (%d)"):gsub("([%(%)%.%[%]%*%+%-%?%^%$])", "%%%1"):gsub("%%s", "(.+)"):gsub("%%d", "(%%d+)")
local function recipeItem(id)
    local _, _, sub, _, _, classID, subClassID = call(api("C_Item.GetItemInfoInstant") or GetItemInfoInstant, id)
    if num(classID) ~= RECIPE_ITEM then return nil end
    local line = RECIPE_LINES[num(subClassID) or -1]
    local name = itemName(id)
    local taught = name and name:match("^[^:]+:%s*(.+)$")
    if not (line and taught) then return nil end
    -- The skill it needs, from the tooltip Reliquary kept of it, else the game's tooltip now.
    local need
    local kept = ns.db.items[id]
    local lines = type(kept) == "table" and type(kept.tip) == "table" and kept.tip or nil
    if not lines then
        local data = call(api("C_TooltipInfo.GetItemByID"), id)
        lines = type(data) == "table" and type(data.lines) == "table" and data.lines or {}
    end
    for _, raw in ipairs(lines) do
        local text = type(raw) == "table" and (str(raw.l) or str(raw.leftText))
        local n = text and select(2, text:match("^" .. SKILL_LINE .. "$"))
        if n then need = tonumber(n) end
    end
    return { line = line, prof = str(sub), taught = taught:lower(), need = need }
end

-- This character's professions, by name and skill line.
local function myProfessions()
    local names, lines = {}, {}
    for _, p in ipairs(ns.char and type(ns.char.profs) == "table" and ns.char.profs or {}) do
        if type(p) == "table" then
            if p.name then names[p.name] = true end
            if num(p.line) then lines[num(p.line)] = true end
        end
    end
    return names, lines
end

local function knows(prof, taught)
    for _, r in ipairs(prof.recipes) do
        local n = r.nm or (r.o and itemName(r.o))
        if n and n:lower() == taught then return true end
    end
    return false
end

-- The one profession an ingredient is for, by the game's own word on it: trade goods of a kind that
-- belongs to one profession (REAGENT_LINES), that the game marks as a crafting reagent (what
-- Reliquary kept of it, when the game hasn't loaded it). Its skill line, or nil.
local function reagentLine(id)
    local _, _, _, _, _, classID, subClassID = call(api("C_Item.GetItemInfoInstant") or GetItemInfoInstant, id)
    local line = num(classID) == TRADE_GOODS and REAGENT_LINES[num(subClassID) or -1]
    if not line then return nil end
    local reagent = plain((select(17, call(api("C_Item.GetItemInfo") or GetItemInfo, id))))
    if reagent == nil then
        local kept = ns.db.items[id]
        reagent = type(kept) == "table" and type(kept.info) == "table" and kept.info.reagent
    end
    return reagent == true and line or nil
end

-- Everyone with a profession (by skill line): this character, your others on its realm and side,
-- and the guildmates and friends who show you their professions. Each with the profession's name
-- and skill; asked once per index.
local function withProfession(line)
    local b = index()
    if b.byLine[line] then return b.byLine[line] end
    local name = LINE_NAMES[line]
    local function find(list, nameKey, skillKey, lineKey)
        for _, p in ipairs(type(list) == "table" and list or {}) do
            if type(p) == "table" and ((lineKey and num(p[lineKey]) == line) or (name and p[nameKey] == name)) then
                return str(p[nameKey]) or name, num(p[skillKey])
            end
        end
    end
    local out = {}
    local c, db = ns.char, ns.db
    local function add(who, nm, cls, kind, prof, sk)
        if prof then out[#out + 1] = { who = who, name = nm, cls = cls, kind = kind, on = b.online[who], prof = prof, sk = sk, line = line, byType = true } end
    end
    add(ns.me() or ns.charKey, c.name, c.classFile, "me", find(c.profs, "name", "skill", "line"))
    for key, o in pairs(db.chars) do
        if key ~= ns.charKey and type(o) == "table" and o.realm == c.realm and o.faction == c.faction then
            add("own:" .. key, o.name, o.classFile, "own", find(o.profs, "name", "skill", "line"))
        end
    end
    local gk = ns.guildKey()
    for who, p in pairs(db.peers) do
        if type(p) == "table" and type(p.scopes) == "table" and type(p.card) == "table" then
            local kind = (gk and p.scopes.g and p.gk == gk) and "g" or (p.scopes.f and "f") or nil
            if kind then add(who, p.card.name or ns.shortName(who), p.card.classFile, kind, find(p.card.profs, "n", "sk")) end
        end
    end
    sort(out, order)
    b.byLine[line] = out
    return out
end

-- Who can make an item: everyone whose recipes make it, you included.
ns.whoCanMake = function(id)
    id = num(id)
    if not (id and ns.db and ns.char) then return {} end
    return index().makes[id] or {}
end

-- The ways anyone you know makes an item, from their recipes: each one's profession and what goes into
-- it ({ prof, uses = { { id, n } } }).
ns.recipesFor = function(id)
    id = num(id)
    if not (id and ns.db and ns.char) then return {} end
    return index().made[id] or {}
end

-- What anyone you know makes with an item, from their recipes: the items, each once.
ns.usedToMake = function(id)
    id = num(id)
    if not (id and ns.db and ns.char) then return {} end
    local out, seen = {}, {}
    for _, e in ipairs(index().uses[id] or {}) do
        for _, r in ipairs(e.recipes) do
            if r.o and not seen[r.o] then
                seen[r.o] = true
                out[#out + 1] = r.o
            end
        end
    end
    return out
end

-- Whose recipes use an item, you included, with the recipes; and for an ingredient the game files
-- under one profession (a cooking ingredient), everyone with that profession whose recipes don't
-- already name it (`byType`).
ns.whoUses = function(id)
    id = num(id)
    if not (id and ns.db and ns.char) then return {} end
    local exact = index().uses[id] or {}
    local line = reagentLine(id)
    if not line then return exact end
    local out = {}
    for _, e in ipairs(exact) do out[#out + 1] = e end
    for _, e in ipairs(withProfession(line)) do
        local listed = false
        for _, x in ipairs(exact) do if x.who == e.who and (x.line == line or x.prof == e.prof) then listed = true end end
        if not listed then out[#out + 1] = e end
    end
    sort(out, order)
    return out
end

-- Who could learn the recipe a recipe item teaches: someone with its profession, skill enough for
-- it, whose recipes show they don't know it yet. You included.
ns.whoCanLearn = function(id)
    id = num(id)
    local ri = id and ns.db and ns.char and recipeItem(id)
    if not ri then return {} end
    local out = {}
    for _, person in ipairs(index().people) do
        for _, prof in ipairs(person.book) do
            if (prof.line and prof.line == ri.line) or (not prof.line and ri.prof and prof.name == ri.prof) then
                if not knows(prof, ri.taught) and not (ri.need and (prof.sk or 0) < ri.need) then
                    out[#out + 1] = { who = person.who, name = person.name, cls = person.cls, kind = person.kind, on = person.on, prof = prof.name, sk = prof.sk }
                end
            end
        end
    end
    return out
end

-- Everyone else who has a use for an item that's of no use to this character: their recipes use it
-- (none of yours does, and it isn't for a profession of yours), or it's a recipe they could learn
-- (for a profession you don't have). { list, learn } or nil.
local function othersFor(id)
    local names, lines = myProfessions()
    local users = ns.whoUses(id)
    if #users > 0 then
        local out = {}
        for _, e in ipairs(users) do
            if e.kind == "me" or names[e.prof] or (e.line and lines[e.line]) then return nil end
            out[#out + 1] = e
        end
        return out, false
    end
    local ri = recipeItem(id)
    if not ri or lines[ri.line] or (ri.prof and names[ri.prof]) then return nil end
    local out = {}
    for _, e in ipairs(ns.whoCanLearn(id)) do
        if e.kind ~= "me" then out[#out + 1] = e end
    end
    if #out == 0 then return nil end
    return out, true
end
ns.othersFor = othersFor

-- "Eluned", "Eluned and Ansel", "Eluned, Ansel and 2 more"; with each one's profession when they
-- differ (`withProf`). Also gives the one profession they share, if they do.
local function names(list, withProf)
    local profs, nprofs = {}, 0
    for _, e in ipairs(list) do if not profs[e.prof] then profs[e.prof], nprofs = true, nprofs + 1 end end
    local one = nprofs == 1 and next(profs) or nil
    local shown = {}
    for i = 1, #list <= NAMES_SHOWN and #list or NAMES_SHOWN - 1 do
        local e = list[i]
        local n = e.kind == "me" and "you" or (e.name or "?")
        shown[#shown + 1] = (withProf and not one and e.prof) and format("%s (%s)", n, e.prof) or n
    end
    local more = #list - #shown
    if more > 0 then shown[#shown + 1] = format("%d more", more) end
    if #shown == 1 then return shown[1], one end
    return concat(shown, ", ", 1, #shown - 1) .. " and " .. shown[#shown], one
end

---------------------------------------------------------------------------
-- In words: the tooltip's lines, the item's page, and a line in chat at loot
---------------------------------------------------------------------------
-- "Faelwen and Eluned (Leatherworking)", or each with their own profession when they differ.
local function namesWithProf(list)
    local who, one = names(list, true)
    return one and format("%s (%s)", who, one) or who
end

local function others(list)
    local out = {}
    for _, e in ipairs(list) do if e.kind ~= "me" then out[#out + 1] = e end end
    return out
end

-- For the lines under an item on the game's tooltips (Upgrades.lua): who else can make it, whose
-- recipes use it, and who could learn it, in your guild, among your friends and your characters.
-- What this character can do isn't news.
ns.craftTips = function(id)
    local out = {}
    if not (ns.db and ns.char) then return out end
    local makers, users, learners = others(ns.whoCanMake(id)), others(ns.whoUses(id)), others(ns.whoCanLearn(id))
    if #makers > 0 then out[#out + 1] = { "Made by", namesWithProf(makers) } end
    if #users > 0 then out[#out + 1] = { "Used by", namesWithProf(users) } end
    if #learners > 0 then out[#out + 1] = { "Can be learned by", namesWithProf(learners) } end
    return out
end

-- For the item's page in /rq: who can make it, whose recipes use it, who could learn it, each with
-- their profession.
ns.craftLines = function(id)
    local out = {}
    if not (ns.db and ns.char) then return out end
    local makers = ns.whoCanMake(id)
    if #makers > 0 then out[#out + 1] = "Made by " .. namesWithProf(makers) end
    local users = ns.whoUses(id)
    if #users > 0 then out[#out + 1] = "Used by " .. namesWithProf(users) end
    local learners = ns.whoCanLearn(id)
    if #learners > 0 then out[#out + 1] = "Can be learned by " .. namesWithProf(learners) end
    return out
end

-- The line in chat when you loot something no profession of yours uses but someone else's recipes
-- do: once a day for each item, and not at all with "Who can use what I loot" off.
local function tell(id, link)
    if not (ns.db and ns.char) or ns.db.settings.craftNews == false then return end
    local c, t = ns.char, time()
    local told = type(c.told) == "table" and c.told or {}
    if num(told["c" .. id]) and t - told["c" .. id] < TELL_AGAIN then return end
    local others, learn = othersFor(id)
    if not others then return end
    for k, at in pairs(told) do
        if type(k) == "string" and k:match("^c%d+$") and (not num(at) or t - at >= TELL_AGAIN) then told[k] = nil end
    end
    told["c" .. id] = t
    c.told = told
    link = link or itemLink(id)
    local who, prof = names(others, true)
    if learn then
        print(format("%s%s can learn your %s.", ns.TAG, who, link))
    else
        print(format("%s%s can use your %s%s.", ns.TAG, who, link, prof and (" for " .. prof) or ""))
    end
end
ns.craftTell = tell

-- The game's own words for what you receive (loot, items given to you), and for what you make,
-- which you know about already.
local function wordsPattern(s)
    s = str(s)
    if not s then return nil end
    s = s:gsub("([%(%)%.%[%]%*%+%-%?%^%$])", "%%%1"):gsub("%%s", ".+"):gsub("%%d", "%%d+")
    return "^" .. s .. "$"
end
local SELF_WORDS, MADE_WORDS
local function selfWords()
    if SELF_WORDS then return SELF_WORDS, MADE_WORDS end
    SELF_WORDS = {}
    for _, s in ipairs({ LOOT_ITEM_SELF or "You receive loot: %s.", LOOT_ITEM_SELF_MULTIPLE or "You receive loot: %sx%d.",
        LOOT_ITEM_PUSHED_SELF or "You receive item: %s.", LOOT_ITEM_PUSHED_SELF_MULTIPLE or "You receive item: %sx%d." }) do
        local p = wordsPattern(s)
        if p then SELF_WORDS[#SELF_WORDS + 1] = p end
    end
    MADE_WORDS = {}
    for _, s in ipairs({ LOOT_ITEM_CREATED_SELF or "You create: %s.", LOOT_ITEM_CREATED_SELF_MULTIPLE or "You create: %sx%d." }) do
        local p = wordsPattern(s)
        if p then MADE_WORDS[#MADE_WORDS + 1] = p end
    end
    return SELF_WORDS, MADE_WORDS
end

local function matchesAny(text, list)
    for _, p in ipairs(list) do if text:match(p) then return true end end
    return false
end

-- The chat lockdown hides these messages' text: then there is nothing to say.
on("CHAT_MSG_LOOT", function(text, ...)
    text = str(text)
    if not (text and ns.db and ns.char) then return end
    local guid = str((select(11, ...)))
    local own, made = selfWords()
    if matchesAny(text, made) then return end
    local mine = guid and guid == str(call(UnitGUID, "player"))
    if not (mine or matchesAny(text, own)) then return end
    -- Each item once, with its link as the message gives it (its colour, clickable).
    local seen = {}
    for id in text:gmatch("|Hitem:(%d+)") do
        id = tonumber(id)
        if id and not seen[id] then
            seen[id] = true
            pcall(tell, id, text:match("(|c[^|]*|Hitem:" .. id .. "[:%d%-]*|h%[.-%]|h|r)"))
        end
    end
end)

---------------------------------------------------------------------------
-- For the window and the item memory
---------------------------------------------------------------------------
-- A player's recipes for the window: their professions (the order their card gives them), each with
-- its recipes by name. Nil when they share none. A profession read with nothing learned in it
-- (Forever's Fishing window lists recipes no one has learned yet) has no page to show; it still
-- counts for who could learn a recipe for it. "own:<key>" is one of your own characters.
ns.recipeBook = function(who)
    local own = type(who) == "string" and who:match("^own:(.+)$")
    local c = own and ns.db and ns.db.chars[own]
    local p = not own and ns.db and who and ns.db.peers[who]
    if type(c) ~= "table" and type(p) ~= "table" then return nil end
    local book = {}
    for _, prof in ipairs(type(c) == "table" and ownBook(c) or peerBook(p)) do
        if #prof.recipes > 0 then book[#book + 1] = prof end
    end
    if #book == 0 then return nil end
    local order = {}
    if type(c) == "table" then
        for i, cur in ipairs(type(c.profs) == "table" and c.profs or {}) do
            if type(cur) == "table" and cur.name then order[cur.name] = i end
        end
    else
        for i, cur in ipairs(type(p.card) == "table" and type(p.card.profs) == "table" and p.card.profs or {}) do
            if type(cur) == "table" and cur.n then order[cur.n] = i end
        end
    end
    sort(book, function(a, b) return (order[a.name] or 99) < (order[b.name] or 99) or ((order[a.name] or 99) == (order[b.name] or 99) and a.name < b.name) end)
    for _, prof in ipairs(book) do
        for _, r in ipairs(prof.recipes) do r.label = r.nm or (r.o and itemName(r.o)) or ("Recipe " .. r.id) end
        sort(prof.recipes, function(a, b) return a.label < b.label end)
    end
    return book
end

-- The items recipes make and use, so their tooltips stay kept (Reliquary.lua prunes the rest, at
-- login, before ns.db is set: it passes the saved data).
ns.itemsInUse = function(use, db)
    db = db or ns.db
    for _, c in pairs(db and db.chars or {}) do
        for _, p in pairs(type(c) == "table" and type(c.recipes) == "table" and c.recipes or {}) do
            for _, rec in pairs(type(p) == "table" and type(p.list) == "table" and p.list or {}) do
                if type(rec) == "table" then
                    use(rec.o)
                    for _, u in ipairs(type(rec.u) == "table" and rec.u or {}) do use(u.id) end
                end
            end
        end
    end
    for _, p in pairs(db and db.peers or {}) do
        local craft = type(p) == "table" and type(p.more) == "table" and type(p.more.craft) == "table" and p.more.craft.list
        for _, x in ipairs(type(craft) == "table" and craft or {}) do
            for _, r in ipairs(type(x) == "table" and type(x.r) == "table" and x.r or {}) do
                if type(r) == "table" then
                    use(r.o)
                    for _, u in ipairs(type(r.u) == "table" and r.u or {}) do use(u.id) end
                end
            end
        end
    end
end

on("PLAYER_LOGIN", function()
    if not (ns.db and C_Timer) then return end
    -- Once its professions are read: the recipes of any it has given up go.
    C_Timer.After(10, function() pcall(tidyRecipes, ns.char) end)
end)
