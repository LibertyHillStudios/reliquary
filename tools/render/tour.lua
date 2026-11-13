-- For renders only (tools/render.sh): opens /rq and goes to one page the way a player's clicks
-- would, by calling the same click scripts. RQ_STEP names the page; the runner sets it before this
-- file. Nothing here is typed into or clicked in the game: it runs inside wow-ui-sim.
--
-- A page is drawn as it ends up: with the player's own Animations switch off, every movement lands at
-- once. A shot of tools/film.sh (open, tab, chat) is drawn RQ_FRAME sixtieths of a second into its movement
-- instead: animations on, and Reliquary's clock stepped as the game steps it each frame, by its own
-- OnUpdate (the simulator never moves time on by itself).

local function plain(s) return (s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) end
local function ns_short(full) return full:match("^([^%-]+)") or full end -- as the window names a player

-- Whether a shown text of f's, or of a frame inside it that isn't a button of its own, reads label.
local function says(f, label)
    for _, r in ipairs({ f:GetRegions() }) do
        if r:GetObjectType() == "FontString" and r:IsShown() and plain(r:GetText() or "") == label then return true end
    end
    for _, c in ipairs({ f:GetChildren() }) do
        if c:IsShown() and not c:IsObjectType("Button") and says(c, label) then return true end
    end
    return false
end

-- The first shown button under root with a text that reads label.
local function find(root, label)
    local found
    local function walk(f)
        if found then return end
        if f:IsVisible() and f:IsObjectType("Button") and says(f, label) then found = f return end
        for _, c in ipairs({ f:GetChildren() }) do walk(c) end
    end
    walk(root)
    return found
end

local function click(label)
    local b = find(ReliquaryFrame, label)
    if not b then error("render tour: nothing to click called " .. label) end
    b:GetScript("OnClick")(b, "LeftButton", false)
end

local function tab(i)
    local t = _G["ReliquaryFrameTab" .. i]
    t:GetScript("OnClick")(t, "LeftButton", false)
end

-- The character you played last, by the name the list gives it. The simulator's own player (just
-- logged in, with nothing of its own) is passed over.
local function own()
    local best
    local playing = UnitName("player")
    for _, c in pairs(ReliquaryDB.chars or {}) do
        local at = type(c) == "table" and tonumber(c.updated)
        if at and c.name and c.name ~= playing and (not best or at > tonumber(best.updated)) then best = c end
    end
    -- With SAMPLE=1 the made-up character is the one played, and the only one.
    if not best and RQ_SAMPLE then
        for _, c in pairs(ReliquaryDB.chars or {}) do if type(c) == "table" and c.name == playing then best = c end end
    end
    if not best then error("render tour: no saved character to show") end
    click(best.name .. (best.surname and best.surname ~= "" and (" " .. best.surname) or ""))
end

-- Guild chat and whispers from the guild's own members, delivered as the game delivers them (the
-- simulator's own event), so they're kept by Reliquary's own code.
local function members()
    local name, _, _, realm = GetGuildInfo("player")
    local g = name and ReliquaryDB.guilds and ReliquaryDB.guilds[name .. "@" .. (realm or GetRealmName() or "?")]
    local out = {}
    for _, m in ipairs(g and g.members or {}) do if m.n and not m.me then out[#out + 1] = m.n end end
    return out
end
local function say(event, text, who, info)
    A_Admin.FireEvent(event, text, who, "", "", who, "", 0, 0, "", 0, math.random(1, 1e6), nil, 0, false, false, false, false, info or { userID = 0 })
end
local function chatter()
    local m = members()
    if #m < 3 then return end
    say("CHAT_MSG_GUILD", "Anyone heading to Blackfathom tonight? Need a healer.", m[1])
    say("CHAT_MSG_GUILD", "I can come after nine.", m[2])
    say("CHAT_MSG_GUILD_DISCORD", "Running late, start without me", "moonsong", { userID = 42, globalName = "moonsong", fromDiscord = true, lastOnlineName = m[3] })
    say("CHAT_MSG_GUILD", "Bringing |cffffffff|Hitem:2589::::::::12:::::::|h[Linen Cloth]|h|r for whoever needs bandages.", m[2])
    say("CHAT_MSG_GUILD_ACHIEVEMENT", "%s has earned the achievement |cffffff00|Hachievement:7:0:0:0:0:0:0:0:0|h[Level 20]|h|r!", m[3])
    say("CHAT_MSG_GUILD", "Grats!", m[1])
    say("CHAT_MSG_GUILD_DISCORD", "Grats from Discord", "starfall", { userID = 43, globalName = "starfall", fromDiscord = true })
end

-- Reliquary's clock moved on so many sixtieths of a second, a frame at a time.
local function tick(frames)
    local clock = ReliquaryMotion
    for _ = 1, frames do
        if clock:IsShown() then clock:GetScript("OnUpdate")(clock, 1 / 60) end
    end
end

-- Total RP 3 isn't in the simulator: for the Roleplay page a stand-in answers as it does, with the
-- profile data/sample/totalRP3_Data.lua keeps for Thalia Moonwhisper (or with nothing yet, waiting).
local THALIA = {
    characteristics = { FN = "Thalia", LN = "Moonwhisper", TI = "Keeper of the Moonwell", FT = "Priestess of the Moonwell Circle",
        RA = "Kaldorei", CL = "Priestess", AG = "About four hundred", HE = "Tall", WE = "Slender", EC = "Silver", BP = "Darnassus", RE = "Auberdine",
        MI = { { ID = 3, VA = "Thal" }, { ID = 4, VA = "Still water keeps the moon." } } },
    character = { RP = 1, XP = 2, WU = 2, CU = "At the moonwell in Auberdine most evenings, cleaning the stones.",
        CO = "Happy to roleplay. Whisper me first if it's a long scene." },
    misc = { PE = { ["1"] = { AC = true, TI = "Moonsilver circlet" }, ["2"] = { AC = true, TI = "Wet hems" } } },
}
local function roleplay(profile, before)
    TRP3_API = { r = { sendQuery = function() end }, slash = { openProfile = function() end },
        register = { getUnitIDCurrentProfileSafe = function() return profile end } }
    tab(2)
    -- The profile is Thalia's: her page, when the guild has her.
    local hers = profile and find(ReliquaryFrame, "Thalia Moonwhisper")
    if hers then hers:GetScript("OnClick")(hers, "LeftButton", false) end
    if before then before() end
    click("Roleplay")
end

-- A shot of the Talents or Recipes page for a film (FRAMES): the window shut and opened again with
-- animations on, left to come to rest, before what moves. Every list row of a kind on the screen, top
-- down (a profession's head, a recipe), and a click on the n-th.
local function filming()
    ReliquaryDB.settings.motion = true
    SlashCmdList.RELIQUARY("")
    SlashCmdList.RELIQUARY("")
    ReliquaryFrame:ClearAllPoints()
    ReliquaryFrame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", RQ_X, -RQ_Y)
    tick(90)
end
local function clickRow(kind, n)
    local found = {}
    local function walk(f)
        if f:IsVisible() and f:IsObjectType("Button") and type(f.line) == "table" and f.line.kind == kind then found[#found + 1] = f end
        for _, c in ipairs({ f:GetChildren() }) do walk(c) end
    end
    walk(ReliquaryFrame)
    table.sort(found, function(a, b) return (a:GetTop() or 0) > (b:GetTop() or 0) end)
    local b = found[n or 1]
    if not b then error("render tour: no " .. kind .. " row to click") end
    b:GetScript("OnClick")(b, "LeftButton", false)
end

local STEPS = {
    gear = function() own() end,
    talents = function() own() click("Talents") end,
    -- Another player's talents: the first guildmate whose page has them.
    ["talents-shared"] = function()
        tab(2)
        for _, m in ipairs(members()) do
            local row = find(ReliquaryFrame, ns_short(m))
            if row then
                row:GetScript("OnClick")(row, "LeftButton", false)
                if find(ReliquaryFrame, "Talents") then click("Talents") return end
            end
        end
        error("render tour: no guildmate shows their talents")
    end,
    bags = function() own() click("Bags") end,
    bank = function() own() click("Bank") end,
    reputation = function() own() click("Reputation") end,
    quests = function() own() click("Quests") end,
    timeline = function() own() click("Timeline") end,
    recipes = function() own() click("Recipes") end,
    -- A guildmate's Roleplay page, and the same before Total RP 3 has heard from them.
    roleplay = function() roleplay(THALIA) end,
    ["roleplay-waiting"] = function() roleplay(nil) end,
    -- Shots: the talents arriving row by row, a profession's card folding, a recipe chosen, a profile
    -- arriving.
    ["talents-in"] = function() own() filming() click("Talents") tick(RQ_FRAME or 600) end,
    ["recipes-fold"] = function() own() click("Recipes") filming() clickRow("head") tick(RQ_FRAME or 600) end,
    ["recipes-pick"] = function() own() click("Recipes") filming() clickRow("recipe", 3) tick(RQ_FRAME or 600) end,
    ["roleplay-in"] = function() roleplay(THALIA, filming) tick(RQ_FRAME or 600) end,
    guild = function() tab(2) end,
    ["guild-chat"] = function() chatter() tab(2) click("Guild Chat") end,
    ["officer-chat"] = function()
        local m = members()
        if m[2] then
            say("CHAT_MSG_OFFICER", "Bank tabs need sorting before the raid.", m[1])
            say("CHAT_MSG_OFFICER", "I'll take the cloth and herbs.", m[2])
        end
        tab(2)
        click("Officer Chat")
    end,
    whispers = function()
        local m = members()
        if m[1] then
            say("CHAT_MSG_WHISPER", "Do you still have that pattern?", m[1])
            say("CHAT_MSG_WHISPER", "I'll trade you some silk for it.", m[1])
        end
        tab(2)
        if m[1] then click(ns_short(m[1])) click("Whispers") end
    end,
    ["guild-bank"] = function() tab(3) end,
    -- The guild bank's Log view, and the guild master's settings for it (the simulator's game says the
    -- played character leads its guild).
    ["guild-bank-log"] = function() tab(3) click("Log") end,
    ["guild-bank-sharing"] = function()
        tab(3)
        for _, p in ipairs({ ReliquaryFrame.body:GetChildren() }) do
            local b = p:IsShown() and find(p, "Sharing")
            if b then b:GetScript("OnClick")(b, "LeftButton", false) return end
        end
        error("render tour: the guild bank has no Sharing button")
    end,
    -- A whisper from someone outside the guild and the friends list, so Others you've whispered shows.
    friends = function() say("CHAT_MSG_WHISPER", "Are you still selling that bag?", "Corin Ashvale") tab(4) end,
    public = function() tab(5) end,
    sharing = function() tab(6) end,
    -- An item's page (RQ_ITEM, else Handstitched Leather Boots), opened as a click on an item opens it.
    item = function()
        local page = ReliquaryItemPage
        local id = tonumber(RQ_ITEM) or 2302
        for _, p in ipairs({ ReliquaryFrame.body:GetChildren() }) do if p ~= page then p:Hide() end end
        page.item, page.link = { id = id }, "item:" .. id
        page:Show()
        page.redraw()
    end,
    -- The minimap button and its tooltip, with the minimap where the game's default layout has it
    -- (flush in the top right corner; the simulator leaves it at the top left) and the window shut.
    -- Shots: the window opening on Characters, and Characters giving way to Guild.
    open = function() tick(RQ_FRAME or 600) end,
    tab = function()
        tick(90)
        tab(2)
        tick(RQ_FRAME or 600)
    end,
    -- Shots of the bags and the guild bank: the window opening on the Bags page (its cards arriving in
    -- order, then the chips), and on the Guild Bank (its tabs, its header, its cards); another of the
    -- bank's tabs (its slots arriving row by row); its Log (the marker sliding, the card arriving from
    -- the side).
    ["bags-open"] = function()
        tick(90)
        own()
        click("Bags")
        tick(60)
        ReliquaryFrame:Hide()
        SlashCmdList.RELIQUARY("")
        tick(RQ_FRAME or 600)
    end,
    ["bank-open"] = function()
        tick(90)
        tab(3)
        tick(60)
        ReliquaryFrame:Hide()
        SlashCmdList.RELIQUARY("")
        tick(RQ_FRAME or 600)
    end,
    ["bank-tab"] = function()
        tick(90)
        tab(3)
        tick(60)
        local second
        local function walk(f)
            if f:IsVisible() and f:IsObjectType("CheckButton") and f.index and not f:GetChecked() then second = second or f end
            for _, c in ipairs({ f:GetChildren() }) do walk(c) end
        end
        walk(ReliquaryFrame.body)
        if not second then error("render tour: the guild bank has one tab") end
        second:GetScript("OnClick")(second, "LeftButton", false)
        tick(RQ_FRAME or 600)
    end,
    ["bank-view"] = function()
        tick(90)
        tab(3)
        tick(60)
        click("Log")
        tick(RQ_FRAME or 600)
    end,
    minimap = function()
        MinimapCluster:ClearAllPoints()
        MinimapCluster:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", 0, 0)
        ReliquaryFrame:Hide()
        ReliquaryMinimapButton:GetScript("OnEnter")(ReliquaryMinimapButton)
    end,
}

-- A character's Timeline: a stop opened by a click (timeline-open), and the film of one opening, its
-- card easing to its new height while the cards under it move down (tools/film.sh fold). The stop is
-- the topmost one showing that opens and is closed. And the film of a page's bars: Reputation reached
-- from Gear, its cards arriving one after another and its bars filling (tools/film.sh bars).
local function closedStop()
    local best
    local function walk(f)
        if not f:IsVisible() then return end
        local chev = f:IsObjectType("Button") and rawget(f, "chev")
        if type(chev) == "table" and chev.down and chev.down:IsShown() and rawget(f, "zone")
            and (not best or (f:GetTop() or 0) > (best:GetTop() or 0)) then best = f end
        for _, c in ipairs({ f:GetChildren() }) do walk(c) end
    end
    walk(ReliquaryFrame)
    if not best then error("render tour: no closed stop to open") end
    return best
end
STEPS["timeline-open"] = function()
    own()
    click("Timeline")
    local head = closedStop()
    head:GetScript("OnClick")(head, "LeftButton", false)
end
-- With animations on: the window shut and opened again, so it takes them up.
local function moving()
    ReliquaryDB.settings.motion = RQ_FRAME ~= nil
    ReliquaryFrame:Hide()
    SlashCmdList.RELIQUARY("")
    ReliquaryFrame:ClearAllPoints()
    ReliquaryFrame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", RQ_X, -RQ_Y)
end
STEPS.fold = function()
    -- The page reached and settled, the stop shown closed for the film's first tenth of a second, then
    -- the click.
    moving()
    own()
    click("Timeline")
    tick(90)
    local closed, at = 6, RQ_FRAME or 600
    if at < closed then return end
    local head = closedStop()
    head:GetScript("OnClick")(head, "LeftButton", false)
    tick(at - closed)
end
STEPS.bars = function()
    moving()
    own()
    tick(90)
    click("Reputation")
    tick(RQ_FRAME or 600)
end

-- Shots of an item's page and of the Sharing tab (tools/film.sh item-page, switch). Each turns the
-- window's movement on with the Sharing tab's own Animations switch, as a player would, then plays its
-- moments at the frames given, RQ_FRAME sixtieths in. Drawn without RQ_FRAME, a step shows how it ends.
do
    -- A click as the game makes one: a check box switched, then its PreClick and OnClick.
    local function press(b) b:Click("LeftButton") end
    local function checkButton(test)
        local found
        local function walk(f)
            if found then return end
            if f:IsVisible() and f:IsObjectType("CheckButton") and test(f) then found = f return end
            for _, c in ipairs({ f:GetChildren() }) do walk(c) end
        end
        walk(ReliquaryFrame)
        return found or error("render tour: no such switch")
    end
    local function animate()
        if not RQ_FRAME then return end
        tab(6)
        local motion = checkButton(function(b) return b.key == "motion" end)
        if not motion:GetChecked() then press(motion) end
    end
    -- The moments at their frames (each before that frame is drawn), the clock stepped between them.
    local function play(moments)
        local last = RQ_FRAME or 600
        for frame = 0, last do
            if moments[frame] then moments[frame]() end
            if frame < last then tick(1) end
        end
    end
    -- An item's page: opened from the first item on the Gear page, it slides in over it; Back slides it
    -- away again.
    STEPS["item-page"] = function()
        animate()
        tab(1)
        own()
        tick(90)
        local slot
        local function walk(f)
            if slot then return end
            if f:IsVisible() and f.rqSlot and f.rq then slot = f return end
            for _, c in ipairs({ f:GetChildren() }) do walk(c) end
        end
        walk(ReliquaryFrame)
        if not slot then error("render tour: no item on the Gear page") end
        play({ [0] = function() press(slot) end, [40] = function() click("Back") end })
    end
    -- Sharing: a switch turned on (its knob slides, its track warms), then a box of the grid ticked.
    STEPS.switch = function()
        animate()
        tab(6)
        tick(90)
        local share = checkButton(function(b) return b.key and not b:GetChecked() end)
        play({ [0] = function() press(share) end,
            [24] = function() press(checkButton(function(b) return b.part == "gold" and not b:GetChecked() end)) end })
    end
    -- The guild bank: the bank's tab that holds an item (RQ_ITEM, else the first item showing) chosen, its
    -- slots arriving, then that item clicked: its page slides in over the bank.
    STEPS["bank-item"] = function()
        animate()
        tab(3)
        tick(90)
        local want = tonumber(RQ_ITEM)
        local function slotOf()
            local slot
            local function walk(f)
                if slot then return end
                if f:IsVisible() and f.rqSlot and type(f.rq) == "table" and (not want or tonumber(f.rq.id) == want) then slot = f return end
                for _, c in ipairs({ f:GetChildren() }) do walk(c) end
            end
            walk(ReliquaryFrame.body)
            return slot
        end
        local tabs = {}
        local function walk(f)
            if f:IsVisible() and f:IsObjectType("CheckButton") and f.index then tabs[#tabs + 1] = f end
            for _, c in ipairs({ f:GetChildren() }) do walk(c) end
        end
        walk(ReliquaryFrame.body)
        table.sort(tabs, function(a, b) return a.index < b.index end)
        -- Which of the bank's tabs holds it: each looked at in turn, then the first one shown again.
        local holder
        if not slotOf() then
            for _, t in ipairs(tabs) do
                if not t:GetChecked() then
                    press(t)
                    tick(90)
                    if slotOf() then holder = t break end
                end
            end
            if not holder then error("render tour: the guild bank doesn't hold that item") end
            press(tabs[1])
            tick(90)
        end
        play({ [20] = function() if holder then press(holder) end end,
            [80] = function() press(slotOf() or error("render tour: the item left the guild bank")) end })
    end
end

-- The simulator wraps a text only within a width it worked out while the text was shown on its own
-- parent; the game wraps it within whatever its anchors make. Each wrapping text gets that width, and
-- its text again as it reads back (its colours decoded already: shims.lua).
local function fixWrap(f)
    for _, r in ipairs({ f:GetRegions() }) do
        if r:GetObjectType() == "FontString" and r:IsVisible() and r:GetWordWrap() then
            local _, _, w = r:GetRect()
            if r:GetNumPoints() >= 2 and w and w > 1 and r:GetWidth() > w + 0.5 then
                local t = r:GetText()
                r:SetWidth(w)
                RQ_SET_TEXT_AS_IS(r, t)
            elseif r:GetNumPoints() == 1 and (r:GetStringWidth() or 0) > r:GetWidth() + 0.5 then
                -- One anchor and a width of its own: the simulator sized it as if every word took a
                -- line; set again now that it shows, it takes the lines the game gives it.
                RQ_SET_TEXT_AS_IS(r, r:GetText())
            end
        end
    end
    for _, c in ipairs({ f:GetChildren() }) do fixWrap(c) end
end

-- The conversations. chat-long: the guild's chat with a day before today's and more than the page holds,
-- so it scrolls under its search. chat-empty: officer chat with nothing said in it yet. chat (a shot of
-- tools/film.sh): the guild's chat open and still, then a line arriving, as the game's next line would:
-- kept, and the Guild tab drawn again as it is for any line (the Guild Chat row's own click draws it
-- the same way).
local function guildLines()
    for _, g in pairs(ReliquaryDB.chat or {}) do if type(g) == "table" and type(g.list) == "table" and #g.list > 0 then return g.list end end
end
local function classOf(full)
    local name, _, _, realm = GetGuildInfo("player")
    local g = name and ReliquaryDB.guilds and ReliquaryDB.guilds[name .. "@" .. (realm or GetRealmName() or "?")]
    for _, m in ipairs(g and g.members or {}) do if m.n == full then return m.cls end end
end
STEPS["chat-long"] = function()
    local m = members()
    if #m < 3 then tab(2) return end
    chatter()
    say("CHAT_MSG_GUILD", "Does anyone have a spare Small Brown Pouch? Mine is full of quest items again and I keep leaving herbs behind in Ashenvale.", m[3])
    say("CHAT_MSG_GUILD", "Check the bank, there were two in the second tab.", m[1])
    say("CHAT_MSG_GUILD", "Thanks!", m[3])
    local list = guildLines()
    local day = time() - 86400
    for i, line in ipairs({ { m[1], "Good run tonight, all." }, { m[2], "Same time tomorrow?" }, { m[1], "Yes, Blackfathom at nine." },
        { m[3], "I'll bring food for everyone." } }) do
        table.insert(list, i, { t = day + i * 60, n = line[1], c = classOf(line[1]), m = line[2] })
    end
    tab(2)
    click("Guild Chat")
end
STEPS["chat-empty"] = function() tab(2) click("Officer Chat") end
STEPS.chat = function()
    chatter()
    tab(2)
    click("Guild Chat")
    tick(90)
    -- Kept as Chat.lua keeps a line, so no timer of the simulator's runs into the film.
    local m, list = members(), guildLines()
    if m[1] and list then list[#list + 1] = { t = time(), n = m[1], c = classOf(m[1]), m = "See you all there." } end
    click("Guild Chat")
    tick(RQ_FRAME or 600)
end

local step = STEPS[RQ_STEP]
if not step then error("render tour: no page called " .. tostring(RQ_STEP)) end
-- Reliquary records the character played 1.5 s after login (its scan, on a timer). The simulator may
-- or may not have reached it before this runs, so it runs now (again, when it has: a scan with nothing
-- new does nothing new), and every render starts from the same recorded character. The scan read the
-- simulator's own guild roster over the saved guild and forgot the guildmates it doesn't name: the
-- guilds and what others share go back as saved (with SAMPLE=1, the made-up players of data/sample).
for _, t in ipairs(RQ_TIMERS) do if t.delay <= 1.5 then t.fn() end end
for key, t in pairs(RQ_SAVED or {}) do
    if type(ReliquaryDB[key]) == "table" then
        wipe(ReliquaryDB[key])
        for k, v in pairs(t) do ReliquaryDB[key][k] = v end
    end
end
-- With SAMPLE=1 the simulator's own player (a paladin of its making) gives way to the made-up
-- character of data/sample: the record the scan just made takes that character's saved one, so the
-- window shows them as the character being played, and no other.
if RQ_SAMPLE then
    -- The simulator's own friends list (players of its making) gives way too: with none, the Friends tab
    -- lists the made-up players who share as friends, and whoever was whispered.
    if C_FriendList then
        C_FriendList.GetNumFriends = function() return 0 end
        C_FriendList.GetNumOnlineFriends = function() return 0 end
    end
    local saved, newest, newestKey = RQ_SAVED and RQ_SAVED.chars or {}
    for key, c in pairs(saved) do
        local at = type(c) == "table" and tonumber(c.updated)
        if at and (not newest or at > tonumber(newest.updated)) then newest, newestKey = c, key end
    end
    for key, c in pairs(ReliquaryDB.chars or {}) do
        if newest and type(c) == "table" and saved[key] == nil then
            wipe(c)
            for k, v in pairs(newest) do c[k] = v end
            ReliquaryDB.chars[newestKey] = nil
        end
    end
end
local FILMED = { open = true, tab = true, chat = true, ["bags-open"] = true, ["bank-open"] = true, ["bank-tab"] = true, ["bank-view"] = true }
ReliquaryDB.settings.motion = FILMED[RQ_STEP] and RQ_FRAME ~= nil or false
SlashCmdList.RELIQUARY("")
-- Where tools/render.sh crops it from.
ReliquaryFrame:ClearAllPoints()
ReliquaryFrame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", RQ_X, -RQ_Y)
step()
fixWrap(ReliquaryFrame)
