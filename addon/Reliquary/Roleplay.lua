-- Reliquary and Total RP 3. Players who share their reliquary with you often keep a roleplay
-- profile in Total RP 3 as well. Reliquary asks Total RP 3 to fetch theirs, as Total RP 3 itself
-- does when you mouse over someone: when they say hello and when you open their page in /rq, at
-- most every fifteen minutes each, never in a fight, an instance or the chat lockdown. The window
-- shows what Total RP 3 holds for them, and its button opens Total RP 3's own page (the same as
-- /trp3 open). Total RP 3 keeps every profile it fetches in its own saved data (TRP3_Register, in
-- totalRP3_Data.lua), where your dashboard reads all of it.
--
-- Only Total RP 3's public functions are called, each in a protected call; without Total RP 3
-- none of this runs. Profile text is other players' writing: it is shown plain, its colour codes,
-- textures, links and Total RP 3 tags taken out.
local ADDON, ns = ...

local num, str = ns.num, ns.str
local type, ipairs, pcall, next, select = type, ipairs, pcall, next, select
local concat, tostring = table.concat, tostring

local ASK_EVERY = 15 * 60 -- seconds before one player's profile is asked for again
local MAX_ASKS = 60        -- players asked in a session

local function trp() return type(TRP3_API) == "table" and TRP3_API or nil end

local function field(t, ...)
    for i = 1, select("#", ...) do
        if type(t) ~= "table" then return nil end
        t = t[(select(i, ...))]
    end
    return t
end

-- Whether Total RP 3 is here to ask and to open profiles.
function ns.rpAvailable()
    return type(field(trp(), "r", "sendQuery")) == "function" and type(field(trp(), "register", "getUnitIDCurrentProfileSafe")) == "function"
end

-- Total RP 3's name for a player. On Forever both name "Given Family"; elsewhere Total RP 3 writes
-- the realm without spaces, dots or hyphens.
local function rpID(who)
    who = str(who)
    if not who or ns.regional() then return who end
    local name, realm = who:match("^([^%-]+)%-(.+)$")
    return name and (name .. "-" .. realm:gsub("[%s%.%-]", "")) or who
end
ns.rpID = rpID

local asked, askCount = {}, 0

-- Asks Total RP 3 to fetch a player's profile. Returns whether it asked.
function ns.rpFetch(who)
    local send = field(trp(), "r", "sendQuery")
    local id = rpID(who)
    if type(send) ~= "function" or not id or id == rpID(ns.me()) or not ns.quiet() then return false end
    local t = ns.now()
    if (asked[id] and t - asked[id] < ASK_EVERY) or askCount >= MAX_ASKS then return false end
    asked[id], askCount = t, askCount + 1
    pcall(send, id)
    return true
end

-- Opens Total RP 3's page for a player: at once if it has their profile, else when it arrives.
function ns.rpOpen(who)
    local open = field(trp(), "slash", "openProfile")
    local id = rpID(who)
    if type(open) ~= "function" or not id then return false end
    pcall(open, id)
    return true
end

-- Cuts a string to at most n bytes without splitting a character.
local function cut(s, n)
    if #s <= n then return s end
    while n > 0 and s:byte(n + 1) and s:byte(n + 1) >= 0x80 and s:byte(n + 1) < 0xC0 do n = n - 1 end
    return s:sub(1, n) .. "..."
end

-- Another player's text, plain: no colour codes, textures, links or Total RP 3 tags; one line.
local function plain(v, maxLen)
    local s = type(v) == "string" and v or nil
    if not s then return nil end
    s = s:gsub("|T.-|t", ""):gsub("|A.-|a", ""):gsub("|H.-|h(.-)|h", "%1"):gsub("|c%x%x%x%x%x%x%x%x", "")
        :gsub("|r", ""):gsub("|n", " "):gsub("%b{}", ""):gsub("%s+", " ")
    s = s:gsub("^ ", ""):gsub(" $", ""):gsub("|", "||")
    if s == "" then return nil end
    return cut(s, maxLen or 200)
end

-- Total RP 3's own words for these (its enUS locale).
local XP = { "Newcomer", "Veteran", "Newcomer Guide", "Casual" }
local MISC = { [2] = "House", [3] = "Nickname", [4] = "Motto", [5] = "Facial features", [6] = "Piercings", [7] = "Pronouns",
    [8] = "Guild name", [9] = "Guild rank", [10] = "Tattoos", [11] = "Voice" }

-- In the game's own text colours (Reliquary.lua).
local function gold(s) return ns.GOLD .. s .. "|r" end
local function dim(s) return ns.GREY .. s .. "|r" end

-- What Total RP 3 holds for a player, as lines for the window; nil when it holds nothing.
function ns.rpLines(who)
    local get = field(trp(), "register", "getUnitIDCurrentProfileSafe")
    if type(get) ~= "function" then return nil end
    local ok, p = pcall(get, rpID(who))
    if not ok or type(p) ~= "table" then return nil end
    local ch = type(p.characteristics) == "table" and p.characteristics or {}
    local cr = type(p.character) == "table" and p.character or {}
    local misc = type(p.misc) == "table" and p.misc or {}
    local lines = {}
    local name = plain((str(ch.FN) or "") .. " " .. (str(ch.LN) or ""), 120)
    if not name and not next(cr) then return nil end
    local title = plain(ch.TI, 60)
    lines[#lines + 1] = (name and gold(name) or "") .. (title and ("  " .. dim(title)) or "")
    local fullTitle = plain(ch.FT, 140)
    if fullTitle then lines[#lines + 1] = fullTitle end
    local status = {}
    local rp = num(cr.RP)
    if rp == 1 then status[#status + 1] = ns.GREEN .. "In character|r" elseif rp == 2 then status[#status + 1] = ns.RED .. "Out of character|r" end
    local xp = num(cr.XP)
    if xp and XP[xp] then status[#status + 1] = XP[xp] end
    if num(cr.WU) == 2 then status[#status + 1] = "Walkup friendly" end
    if #status > 0 then lines[#lines + 1] = concat(status, "  ·  ") end
    local facts = {}
    local function fact(label, v) v = plain(v, 60) if v then facts[#facts + 1] = (label and (dim(label) .. " ") or "") .. v end end
    fact(nil, (str(ch.RA) or "") .. " " .. (str(ch.CL) or ""))
    fact("Age", ch.AG)
    fact("Height", ch.HE)
    fact("Build", ch.WE)
    fact("Eyes", ch.EC)
    fact("Born in", ch.BP)
    fact("Lives in", ch.RE)
    if #facts > 0 then lines[#lines + 1] = concat(facts, "   ") end
    if plain(cr.CU) then lines[#lines + 1] = gold("Currently: ") .. plain(cr.CU, 260) end
    if plain(cr.CO) then lines[#lines + 1] = gold("Out of character: ") .. plain(cr.CO, 260) end
    local mi = {}
    for _, m in ipairs(type(ch.MI) == "table" and ch.MI or {}) do
        local label = type(m) == "table" and (plain(m.NA, 40) or MISC[num(m.ID) or 0])
        local value = type(m) == "table" and plain(m.VA, 100)
        if label and value then mi[#mi + 1] = dim(label .. ":") .. " " .. value end
    end
    if #mi > 0 then lines[#lines + 1] = concat(mi, "   ") end
    local glances = {}
    for i = 1, 5 do -- Total RP 3 keys its five glances "1" to "5" and shows the active ones
        local g = field(misc, "PE", tostring(i))
        local t = type(g) == "table" and g.AC and plain(g.TI, 60)
        if t then glances[#glances + 1] = t end
    end
    if #glances > 0 then lines[#lines + 1] = gold("At first glance: ") .. concat(glances, ", ") end
    return lines
end

-- When Total RP 3 stores someone's profile, the window shows it at once if it is showing them
-- (Total RP 3's own /trp3 open listens the same way).
ns.on("PLAYER_LOGIN", function()
    local register = field(trp(), "RegisterCallback")
    local event = type(TRP3_Addon) == "table" and field(TRP3_Addon, "Events", "REGISTER_DATA_UPDATED")
    if type(register) ~= "function" or not event then return end
    pcall(register, TRP3_Addon, event, function(_, unitID)
        if ns.onRoleplayUpdated and type(unitID) == "string" then pcall(ns.onRoleplayUpdated, unitID) end
    end)
end)
