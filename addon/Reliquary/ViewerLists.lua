-- Reliquary's window: a list on the left and the chosen player on the right, and the tabs made of
-- them: Characters, Guild, Friends and Public.
local ADDON, ns = ...

local V = ns.V

local Skin, Motion = ns.Skin, ns.Motion

local num, str = ns.num, ns.str
local pairs, ipairs, type = pairs, ipairs, type
local format = string.format
local GOLD, GREY = ns.GOLD, ns.GREY
local RAIL, PAGE_HEIGHT, state, sound, ago, classColored, money = V.RAIL, V.PAGE_HEIGHT, V.state, V.sound, V.ago, V.classColored, V.money
local joined, words, hideTip, showTip, played, plural = V.joined, V.words, V.hideTip, V.showTip, V.played, V.plural
local myGuild, CHAT, makeConversation, makeDetail, showDetail, roadOf = V.myGuild, V.CHAT, V.makeConversation, V.makeDetail, V.showDetail, V.roadOf

---------------------------------------------------------------------------
-- A list on the left and the chosen player on the right
---------------------------------------------------------------------------
-- The rail down the left (docs/DESIGN.md, section 3): an ink.950 well with a pixel line on its right,
-- headed by the tab's title, its counts and its switch (b.head; the tab lays it out and says how tall it
-- is with b.setHead), then the search field and the list. Each row is a player (or a conversation): an
-- avatar, the name and what the list knows of them, the level, Reliquary's mark for one who shares; the
-- chosen one keeps a fill and the gold bar that glides to it. Right of the rail, the chosen player's
-- page (makeDetail) or a conversation.
local function makeBrowser(panel, key)
    local b = { key = key }
    b.rail = Skin.well(panel, { flat = true, radius = Skin.RADIUS.window, square = { tl = true, tr = true, br = true } })
    b.rail:SetPoint("TOPLEFT")
    b.rail:SetPoint("BOTTOMLEFT")
    b.rail:SetWidth(RAIL)
    b.edge = Skin.line(b.rail, "ink600", { vertical = true })
    b.edge:SetPoint("TOPLEFT", b.rail, "TOPRIGHT")
    b.edge:SetPoint("BOTTOMLEFT", b.rail, "BOTTOMRIGHT")
    b.head = CreateFrame("Frame", nil, b.rail)
    b.head:SetPoint("TOPLEFT")
    b.head:SetPoint("TOPRIGHT")
    b.search = Skin.search(b.rail)
    b.search.onChange = function(text)
        state[key .. "Query"] = text
        if b.refresh then b.refresh() end
    end
    b.list, b.bar = Skin.scroll(b.rail, { frameType = "Button", right = 9, bottom = 6, fade = Skin.SPACE.xl,
        extent = function(row) return row.head and Skin.ROW_HEAD or Skin.ROW end,
        init = function(button, row)
            Skin.row(button)
            Skin.sectionRow(button)
            if not button.rqClick then
                button.rqClick = true
                button:SetScript("OnClick", function(self)
                    local pick = self.row and not self.row.head and self.row.key
                    if not pick then return end
                    if pick ~= state.pick[key] then sound("IG_MAINMENU_OPTION_CHECKBOX_ON") end
                    state.pick[key] = pick
                    if b.refresh then b.refresh() end
                end)
            end
            b.drawRow(button, row)
        end })
    -- The header's height, and the search and list under it.
    function b.setHead(height)
        b.head:SetHeight(height)
        b.search:ClearAllPoints()
        b.search:SetPoint("TOPLEFT", 12, -height)
        b.search:SetPoint("TOPRIGHT", -12, -height)
        b.list:SetPoint("TOPLEFT", 0, -(height + 26 + 8))
    end
    b.setHead(56)
    function b.drawRow(button, row)
        button.row = row
        local head = row.head == true
        button.inert = head
        button:SetHeight(head and Skin.ROW_HEAD or Skin.ROW)
        -- A heading: the label face and a line to the edge; it is nothing to point at.
        button.title:SetShown(head)
        button.rule:SetShown(head)
        button.inner:SetShown(not head)
        if head then
            Skin.label(button.title, row.label)
            button:SetChosen(false)
            button.fill:SetAlpha(0)
            return
        end
        button.name:SetText(row.label)
        button.info:SetText(row.info or "")
        local hasInfo = (row.info or "") ~= ""
        button.info:SetShown(hasInfo)
        button.name:ClearAllPoints()
        button.info:ClearAllPoints()
        if hasInfo then
            button.name:SetPoint("TOPLEFT", button.avatar, "TOPRIGHT", 10, 1)
            button.info:SetPoint("TOPLEFT", button.name, "BOTTOMLEFT", 0, -3)
        else
            button.name:SetPoint("LEFT", button.avatar, "RIGHT", 10, 0)
        end
        button.level:SetText(row.level or "")
        button.gem:SetShown(row.shares and true or false)
        button.gem:ClearAllPoints()
        if (row.level or "") ~= "" then button.gem:SetPoint("RIGHT", button.level, "LEFT", -6, 0) else button.gem:SetPoint("RIGHT", -14, 0) end
        -- The name and the line under it run up to the mark of one who shares, else to the level.
        local stop = row.shares and button.gem or (row.level or "") ~= "" and button.level or nil
        for _, line in ipairs({ button.name, button.info }) do
            if stop then line:SetPoint("RIGHT", stop, "LEFT", -6, 0) else line:SetPoint("RIGHT", -14, 0) end
        end
        -- Their class's icon (a conversation's, the chat icon; a Battle.net friend away from WoW:
        -- Forever, the program they're in), dimmed with the name when offline; their presence.
        local av = button.avatar
        local cls = str(row.cls)
        av:SetShown(cls ~= nil or row.chat ~= nil or row.atlas ~= nil)
        if row.chat then av:SetIcon(CHAT.icon)
        elseif cls then av:SetClass(cls)
        elseif row.atlas then av:SetIcon(row.atlas, true) end
        av:SetDimmed(row.online == false and not row.chat)
        av:SetPresence(row.online)
        button.name:SetAlpha(row.online == false and 0.6 or 1)
        button:SetChosen(state.pick[key] == row.key)
    end
    b.detail = makeDetail(panel)
    b.detail.pageHeight = PAGE_HEIGHT
    b.detail:SetPoint("TOPLEFT", b.edge, "TOPRIGHT")
    b.detail:SetPoint("BOTTOMRIGHT")
    b.empty = Skin.text(panel, "body", "CENTER")
    b.empty:SetTextColor(Skin.rgb("dim"))
    b.empty:SetWordWrap(true)
    b.empty:SetPoint("TOPLEFT", b.edge, "TOPRIGHT", 48, -120)
    b.empty:SetPoint("RIGHT", -48, 0)
    b.empty:SetSpacing(5)
    -- A player's row on the screen now, by their key.
    local function rowOf(pick)
        for _, f in ipairs(b.list:GetFrames()) do
            if pick ~= nil and f.row and not f.row.head and f.row.key == pick and f:IsVisible() then return f end
        end
    end
    function b.fill(rows, find, emptyText)
        local pick = state.pick[key]
        local listed, first = false, nil
        for _, row in ipairs(rows) do
            if not row.head then
                first = first or row.key
                if row.key == pick then listed = true break end
            end
        end
        if not listed then state.pick[key] = first end
        local found = state.pick[key] and find(state.pick[key])
        -- The gold bar glides from the row chosen before to the one chosen now.
        local was = b.lastPick ~= state.pick[key] and rowOf(b.lastPick)
        local wasTop = was and was:GetTop() or nil
        b.list:SetDataProvider(CreateDataProvider(rows), ScrollBoxConstants and ScrollBoxConstants.RetainScrollPosition)
        local now = rowOf(state.pick[key])
        if now and wasTop then Skin.glide(now, wasTop) end
        b.lastPick = state.pick[key]
        -- The window opening: the rows arrive in order, the chosen one's fill and gold bar with its words.
        if V.entrance then
            local n = 0
            for _, f in ipairs(b.list:GetFrames()) do
                if f:IsVisible() then
                    n = n + 1
                    Motion.arrive(f.inner:IsShown() and f.inner or f.title, n, { delay = Motion.ROWS_AFTER })
                    if f.chosen then
                        local at = Motion.ROWS_AFTER + Motion.delay(n)
                        Motion.fade(f.bar, 1, { from = 0, dur = "base", delay = at, ease = "enter" })
                        Motion.fade(f.fill, 1, { from = 0, dur = "base", delay = at, ease = "enter", owner = f })
                    end
                end
            end
        end
        -- A row for a conversation (the guild's chat, its officer chat) shows it in place of a player's page.
        local talk = found and found.chat and b.chats and b.chats[found.chat]
        local fresh = talk and (V.entrance or not talk:IsShown())
        for _, cv in pairs(b.chats or {}) do cv:SetShown(cv == talk) end
        if talk then
            b.empty:Hide()
            b.detail:Hide()
            if ns.chatBackfill then ns.chatBackfill() end -- what was said while you were away, if not asked for yet
            talk.draw()
            -- Chosen, or the window opening on it: it arrives as a player's page does, after the rows.
            if fresh then Motion.arrive(talk, 1, { delay = V.entrance and Motion.PAGE_AFTER or 0 }) end
            if b.chatSeen then b.chatSeen(found.chat) end
        elseif found then
            b.empty:Hide()
            showDetail(b.detail, found.peer, found.member)
        else
            b.detail:Hide()
            b.empty:SetText(emptyText or "")
            b.empty:Show()
        end
    end
    return b
end

-- The header's words, in units: the title and its counts at the Characters tab's place, a
-- line or two of dim words under them (between: under the counts), and a control under the words
-- (gap), on the 4-unit grid; the search under that, gap again. Words run the rail's width less inset
-- each side.
local HEAD = { top = 16, title = 5, between = 4, gap = Skin.SPACE.m, inset = 16, leading = 2 }
HEAD.width = RAIL - 2 * HEAD.inset
local function onGrid(y) return math.ceil(y / Skin.SPACE.xs) * Skin.SPACE.xs end
local function lineOf(fs) return fs:GetLineHeight() or select(2, fs:GetFont()) or 0 end

-- A tab's title (title face) and its counts under it (small), heading the rail; a long title is cut
-- and shows whole on hover.
local function heading(b, panel)
    panel.title = Skin.text(b.head, "title")
    panel.title:SetPoint("TOPLEFT", HEAD.inset, -HEAD.top)
    panel.title:SetPoint("RIGHT", -HEAD.inset, 0)
    panel.titleHover = CreateFrame("Frame", nil, b.head)
    panel.titleHover:SetAllPoints(panel.title)
    panel.titleHover:EnableMouse(true)
    panel.titleHover:SetScript("OnEnter", function(self)
        if panel.title:IsTruncated() then showTip(self, panel.title:GetText()) end
    end)
    panel.titleHover:SetScript("OnLeave", hideTip)
    panel.summary = Skin.text(b.head, "small")
    panel.summary:SetPoint("TOPLEFT", panel.title, "BOTTOMLEFT", 0, -HEAD.title)
    panel.summary:SetPoint("RIGHT", -HEAD.inset, 0)
end

-- Where the title's words end: its counts' foot (when it has counts), or under them the dim lines
-- when there are any.
local function wordsFoot(panel, more)
    local y = HEAD.top + lineOf(panel.title)
    if (panel.summary:GetText() or "") ~= "" then y = y + HEAD.title + lineOf(panel.summary) end
    if more and more:IsShown() then y = y + HEAD.between + (more:GetStringHeight() or 0) end
    return y
end

-- The filter switch heading a rail, with its words: "Reliquary users only", the switch at the row's
-- right, both on its middle.
local function onlySwitch(b, panel, field)
    panel.onlyRow = CreateFrame("Frame", nil, b.head)
    panel.only = Skin.switch(panel.onlyRow)
    panel.onlyRow:SetHeight(panel.only:GetHeight())
    panel.only:SetPoint("RIGHT", -HEAD.inset, 0)
    panel.onlyLabel = Skin.text(panel.onlyRow, "small")
    panel.onlyLabel:SetPoint("LEFT", HEAD.inset, 0)
    panel.onlyLabel:SetPoint("RIGHT", panel.only, "LEFT", -Skin.SPACE.s, 0)
    panel.onlyLabel:SetText("Reliquary users only")
    panel.only:HookScript("OnClick", function(self)
        state[field] = self:GetChecked() and true or false
        sound(state[field] and "IG_MAINMENU_OPTION_CHECKBOX_ON" or "IG_MAINMENU_OPTION_CHECKBOX_OFF")
        panel.refresh()
    end)
end

-- The switch's row a gap under the words (more: the dim lines under the counts, if any), and the search
-- a gap under it; with nothing to filter, the switch hides and the search comes up under the words.
local function placeSwitch(b, panel, more)
    local top = onGrid(wordsFoot(panel, more) + HEAD.gap)
    panel.onlyRow:SetPoint("TOPLEFT", 0, -top)
    panel.onlyRow:SetPoint("TOPRIGHT", 0, -top)
    b.setHead(panel.onlyRow:IsShown() and top + panel.onlyRow:GetHeight() + HEAD.gap or top)
end

-- A list row's second line: the parts of it that are known, in grey.
local function rowInfo(...) return joined(" · ", ...) end

local function matches(query, ...)
    query = (query or ""):lower()
    if query == "" then return true end
    for i = 1, select("#", ...) do
        local v = select(i, ...)
        if type(v) == "string" and v:lower():find(query, 1, true) then return true end
    end
    return false
end

-- The name one of your characters goes by in the window: its full name, else (when the game kept
-- it from Reliquary) the name it is filed under.
local function ownLabel(key, c)
    if str(c.name) then return c.name .. (str(c.surname) and (" " .. c.surname) or "") end
    return key:match("^([^%-]+)") or key
end

-- One of your characters as the window shows a player: its card and sections with every part
-- (Share.lua), its timeline, and the full name the guild knows it by.
local function ownPeer(key, c)
    local built = ns.ownCard and ns.ownCard(c)
    if not built then return nil end
    built.card.name = built.card.name or ownLabel(key, c)
    return { key = "own:" .. key, own = true, playing = key == ns.charKey, name = ns.fullName(key), label = ownLabel(key, c),
        card = built.card, more = built.more, got = num(c.updated), road = roadOf(c), char = c }
end

-- Characters: every character on this account as the game last saved them, the one you are playing
-- as it is now, first.
local function buildChars(panel)
    -- Over the list: how many characters there are, the gold they carry between them and their time
    -- played, each when the game gave it.
    panel.browser = makeBrowser(panel, "chars")
    heading(panel.browser, panel)
    panel.title:SetText("Characters")
    panel.browser.setHead(62)
    function panel.refresh()
        local rows, byKey = {}, {}
        local count, gold, playedAll = 0, 0, 0
        for key, c in pairs(ns.db.chars) do
            if type(c) == "table" then
                byKey[key] = c
                count, gold, playedAll = count + 1, gold + (num(c.money) or 0), playedAll + (num(c.played) or 0)
                local full = ownLabel(key, c)
                if matches(state.charsQuery, full, c.realm, c.class, c.race, c.guild, c.zone) then
                    local playing = key == ns.charKey
                    rows[#rows + 1] = { key = key, label = classColored(full, c.classFile), level = c.level, online = playing or nil,
                        info = rowInfo(str(c.zone), not playing and num(c.updated) and ago(c.updated) or nil),
                        playing = playing, lv = num(c.level) or 0, name = full, cls = c.classFile }
                end
            end
        end
        table.sort(rows, function(a, b)
            if a.playing ~= b.playing then return a.playing end
            if a.lv ~= b.lv then return a.lv > b.lv end
            return a.name < b.name
        end)
        local bits = { plural(count, "character", "characters") }
        if gold > 0 then bits[#bits + 1] = money(gold) end
        if playedAll > 0 then bits[#bits + 1] = played(playedAll) end
        panel.summary:SetText(table.concat(bits, " · "))
        panel.browser.fill(rows, function(k) return byKey[k] and { peer = ownPeer(k, byKey[k]) } end, "No character of yours matches that search.")
    end
    panel.browser.refresh = panel.refresh
end

-- Guild: the roster, guildmates who share first among those online.
local function buildGuild(panel)
    panel.browser = makeBrowser(panel, "guild")
    local b = panel.browser
    heading(b, panel)
    -- The message of the day, two lines at most (whole on hover), and the filter.
    panel.motd = Skin.text(b.head, "small")
    panel.motd:SetTextColor(Skin.rgb("dim"))
    panel.motd:SetWordWrap(true)
    panel.motd:SetMaxLines(2)
    panel.motd:SetSpacing(HEAD.leading)
    panel.motd:SetWidth(HEAD.width)
    panel.motd:SetPoint("TOPLEFT", panel.summary, "BOTTOMLEFT", 0, -HEAD.between)
    panel.motdHover = CreateFrame("Frame", nil, b.head)
    panel.motdHover:SetAllPoints(panel.motd)
    panel.motdHover:EnableMouse(true)
    panel.motdHover:SetScript("OnEnter", function(self)
        if panel.motd:IsTruncated() then showTip(self, panel.title:GetText() or "", { panel.motd:GetText() }) end
    end)
    panel.motdHover:SetScript("OnLeave", hideTip)
    onlySwitch(b, panel, "sharersOnly")
    placeSwitch(b, panel)
    -- The guild's chat, first in the list (Chat.lua): what's said there as the game's chat shows it,
    -- kept, searched and filtered, each speaker a click from their page, and a box to say your own.
    -- The guild's chat, and for a character who may hear it its officer chat, alike but for what they
    -- keep, their colour and where the box sends.
    local function guildTalk(which)
        local officer = which == "officer"
        return {
            kind = officer and "OFFICER" or "GUILD", filters = true, hint = officer and "Message your officers" or "Message your guild",
            empty = officer and "Nothing said in officer chat yet." or "Nothing said in the guild yet.",
            source = function() return ns.guildChat(ns.guildKey(), officer and "officer" or nil) end,
            send = function(typed) if officer then return ns.sendOfficerChat(typed) end return ns.sendGuildChat(typed) end,
            speaker = function(r)
                local who, discord = str(r.n), str(r.d)
                local name = discord and (discord .. " (Discord)") or (who and ns.shortName(who))
                if not name then return nil end
                local known = who and panel.byKey and panel.byKey[who]
                return { key = discord and ("d:" .. discord) or who, name = name, open = who, discord = discord ~= nil or nil,
                    class = str(r.c) or known and known.member and str(known.member.cls) or nil }
            end,
            open = function(who)
                if not (panel.byKey and panel.byKey[who]) then return end
                state.pick.guild = who
                panel.refresh()
            end,
            openTip = function(who, label)
                if not who then return nil end -- someone on the guild's Discord with no character the game knows
                -- A Discord name's page is the character they last played.
                local known, name = panel.byKey and panel.byKey[who], ns.shortName(who) or label
                if not known then return label .. "\n" .. GREY .. (name == label and "Not" or (name .. " isn't")) .. " in the guild's list now.|r" end
                return "See " .. name
            end,
        }
    end
    b.chats = { guild = makeConversation(panel, guildTalk("guild")), officer = makeConversation(panel, guildTalk("officer")) }
    b.chat = b.chats.guild
    for _, cv in pairs(b.chats) do
        cv:SetPoint("TOPLEFT", b.edge, "TOPRIGHT", V.PAGE_PAD, -V.PAGE_PAD)
        cv:SetPoint("BOTTOMRIGHT", -V.PAGE_PAD, 12)
        cv:Hide()
    end
    -- What you've seen of each chat: lines after it, said by others, count on its row.
    state.chatSeen = {}
    b.chatSeen = function(which)
        local list = ns.guildChat(ns.guildKey(), which == "officer" and "officer" or nil)
        state.chatSeen[which] = { gk = ns.guildKey(), last = list[#list] }
    end
    local function unread(which, gk, list)
        local seen = state.chatSeen[which]
        if not (seen and seen.gk == gk) then
            state.chatSeen[which] = { gk = gk, last = list[#list] } -- what was said before you first looked isn't new
            return 0
        end
        local n, me = 0, ns.me and ns.me()
        for i = #list, 1, -1 do
            local r = list[i]
            if r == seen.last or n >= 99 then break end
            if type(r) == "table" and r.n ~= me then n = n + 1 end
        end
        return n
    end
    function panel.refresh()
        local g = myGuild()
        local peers = ns.db.peers
        if not g then
            panel.title:SetText("No guild")
            panel.summary:SetText("")
            panel.motd:SetText("")
            panel.motd:Hide()
            panel.motdHover:Hide()
            panel.onlyRow:Hide()
            placeSwitch(b, panel)
            panel.browser.fill({}, function() end, "This character isn't in a guild.")
            return
        end
        local members = type(g.members) == "table" and g.members or {}
        local rows, byKey, online = {}, {}, 0
        for _, m in ipairs(members) do
            local who = ns.fullName(m.n)
            local peer = who and peers[who]
            local shares = peer and peer.scopes and peer.scopes.g and peer.card and true or false
            if m.on then online = online + 1 end
            byKey[who] = { member = m, peer = shares and peer or nil }
            if (not state.sharersOnly or shares) and matches(state.guildQuery, m.n, m.rank, m.z, m.p1, m.p2, m.note) then
                rows[#rows + 1] = { key = who, label = classColored(ns.shortName(who), m.cls), level = m.lv, online = m.on and true or false,
                    info = rowInfo(str(m.rank), m.on and str(m.z) or (num(m.seen) and ago(m.seen)) or nil),
                    shares = shares, sortOn = m.on and 0 or 1, sortShare = shares and 0 or 1, rank = m.ro or 99, name = who, cls = m.cls }
            end
        end
        table.sort(rows, function(a, b)
            if a.sortOn ~= b.sortOn then return a.sortOn < b.sortOn end
            if a.sortShare ~= b.sortShare then return a.sortShare < b.sortShare end
            if a.rank ~= b.rank then return a.rank < b.rank end
            return a.name < b.name
        end)
        local gk = ns.guildKey()
        -- The conversation open now has nothing unseen in it.
        local reading = state.pick.guild == CHAT.key and "guild" or state.pick.guild == CHAT.officerKey and "officer" or nil
        if reading then b.chatSeen(reading) end
        local function talkRow(which, at, label)
            local list = ns.guildChat(gk, which == "officer" and "officer" or nil)
            local new = unread(which, gk, list)
            -- Under its name, its last line: who said it and what, as plain words.
            local last, said = list[#list], nil
            if type(last) == "table" and type(last.m) == "string" then
                local who = str(last.d) or (str(last.n) and ns.shortName(last.n))
                local body = last.m:gsub("|H.-|h(.-)|h", "%1"):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|T.-|t", ""):gsub("|A.-|a", "")
                if last.k == "a" then body = body:gsub("^%%s%s*", ""):gsub("%%s", ((who or ""):gsub("%%", "%%%%"))) end
                said = who and (who .. ": " .. body) or body
            end
            table.insert(rows, at, { key = which == "officer" and CHAT.officerKey or CHAT.key, chat = which, label = label, info = said,
                level = new > 0 and (GOLD .. new .. "|r") or nil })
            byKey[rows[at].key] = { chat = which }
        end
        talkRow("guild", 1, "Guild Chat")
        if ns.canSeeOfficerChat() then talkRow("officer", 2, "Officer Chat") end
        -- Opened for the first time: the guild's chat once something has been said in it, else the
        -- first guildmate in the list, rather than an empty conversation.
        if state.pick.guild == nil and #ns.guildChat(gk) == 0 then
            for _, r in ipairs(rows) do if not r.chat then state.pick.guild = r.key break end end
        end
        panel.byKey = byKey
        panel.title:SetText("<" .. (g.name or "?") .. ">")
        panel.summary:SetText(format("%d members · %d online", #members, online))
        panel.motd:SetText(g.motd and ("\"" .. g.motd .. "\"") or "")
        local motd = (panel.motd:GetText() or "") ~= ""
        panel.motd:SetShown(motd)
        panel.motdHover:SetShown(motd)
        panel.onlyRow:Show()
        placeSwitch(b, panel, panel.motd)
        panel.only:SetChecked(state.sharersOnly)
        panel.browser.fill(rows, function(k) return byKey[k] end,
            #members == 0 and "The guild list arrives a moment after you log in." or "Nobody here matches that search.")
    end
    panel.browser.refresh = panel.refresh
end

-- Friends: everyone on your friends list, and your Battle.net friends who are online, share with
-- you or have whispers with you, as the Guild tab lists the guild: their reliquary when they share
-- one, else what the friends list or Battle.net says of them, and your whispers. Then anyone else
-- you've whispered, so every conversation has a page.
local OTHERS = "\1others" -- the list's own heading, never a name
local BNET_NAME = FRIENDS_BNET_NAME_COLOR_CODE or "|cff82c5ff" -- a Battle.net friend's name, as the game's friends list colours it
local function buildFriends(panel)
    panel.browser = makeBrowser(panel, "friends")
    heading(panel.browser, panel)
    panel.title:SetText("Friends")
    onlySwitch(panel.browser, panel, "friendSharersOnly")
    placeSwitch(panel.browser, panel)
    function panel.refresh()
        local peers, whispers = ns.db.peers, type(ns.db.whispers) == "table" and ns.db.whispers or {}
        local rows, byKey, count, online = {}, {}, 0, 0
        -- Someone's reliquary, whichever way they share it with you.
        local function cardOf(who)
            local p = who and peers[who]
            return p and type(p.card) == "table" and p or nil
        end
        for _, f in ipairs(ns.friends and ns.friends() or {}) do
            local bn = f.kind == "bnet"
            local peer = cardOf(bn and f.char or f.key)
            local talked = type(whispers[f.key]) == "table"
            -- A Battle.net friend away and silent, sharing nothing, is the Battle.net app's to show.
            if not byKey[f.key] and (not bn or f.on or peer or talked) then
                count = count + 1
                if f.on then online = online + 1 end
                byKey[f.key] = { member = f, peer = peer }
                if (not state.friendSharersOnly or peer) and matches(state.friendsQuery, bn and f.label or f.key, f.char, f.z, f.note) then
                    local where = f.on and (str(f.z) or (bn and "Online") or nil) or "Offline"
                    rows[#rows + 1] = { key = f.key, label = bn and (BNET_NAME .. f.label .. "|r") or classColored(ns.shortName(f.key), f.cls), level = f.lv,
                        info = rowInfo(bn and f.char and ns.shortName(f.char) or nil, where),
                        online = f.on, shares = peer ~= nil, cls = f.cls, atlas = bn and not f.cls and ("Battlenet-ClientIcon-" .. (f.on and f.client or "App")) or nil,
                        sortOn = f.on and 0 or 1, sortShare = peer and 0 or 1, name = (bn and f.label or ns.shortName(f.key)):lower() }
                end
            end
        end
        -- Anyone sharing with you as a friend whom the lists don't name (a list not loaded yet, a friend
        -- the game no longer lists): their reliquary still shows.
        local named = {}
        for k, e in pairs(byKey) do
            named[k] = true
            if e.member.char then named[e.member.char] = true end
        end
        for _, p in ipairs(ns.peerList("f")) do
            local c = type(p.card) == "table" and p.card
            if c and not named[p.key] then
                count = count + 1
                byKey[p.key] = { peer = p }
                if matches(state.friendsQuery, p.key, c.name, c.guild, c.class, c.race) then
                    rows[#rows + 1] = { key = p.key, label = classColored(c.name or ns.shortName(p.key), c.classFile), level = c.level, shares = true, cls = c.classFile,
                        info = str(c.guild) and ("<" .. c.guild .. ">") or words(c.race, c.class), sortOn = 1, sortShare = 0, name = (c.name or ns.shortName(p.key)):lower() }
                end
            end
        end
        table.sort(rows, function(a, b)
            if a.sortOn ~= b.sortOn then return a.sortOn < b.sortOn end
            if a.sortShare ~= b.sortShare then return a.sortShare < b.sortShare end
            return a.name < b.name
        end)
        -- Anyone else you've whispered who has no page elsewhere (the Guild tab's list, a reliquary
        -- shared with you, the Battle.net friend playing that character), the most recent first, under
        -- their own quiet heading.
        local g = myGuild()
        local inGuild = {}
        for _, m in ipairs(g and type(g.members) == "table" and g.members or {}) do
            local who = ns.fullName(m.n)
            if who then inGuild[who] = true end
        end
        local others = {}
        for key, p in pairs(whispers) do
            if type(key) == "string" and type(p) == "table" and not named[key] and not inGuild[key] and not cardOf(key) then
                local bn = key:find("^bn:") ~= nil
                local label = bn and (key:match("^bn:([^#]+)") or key) or ns.shortName(key)
                byKey[key] = { member = { kind = "whispered", key = key, n = not bn and key or nil, label = label, cls = str(p.c), at = num(p.at) } }
                if not state.friendSharersOnly and matches(state.friendsQuery, label, key) then
                    others[#others + 1] = { key = key, label = bn and (BNET_NAME .. label .. "|r") or classColored(label, str(p.c)), cls = str(p.c),
                        info = num(p.at) and ("Whispered " .. ago(p.at)) or nil, atlas = bn and not str(p.c) and "Battlenet-ClientIcon-App" or nil, at = num(p.at) or 0 }
                end
            end
        end
        table.sort(others, function(a, b) if a.at ~= b.at then return a.at > b.at end return a.key < b.key end)
        if #others > 0 then
            rows[#rows + 1] = { key = OTHERS, head = true, label = "Others you've whispered" }
            for _, r in ipairs(others) do rows[#rows + 1] = r end
        end
        panel.byKey = byKey
        panel.summary:SetText(format("%d %s · %d online", count, count == 1 and "friend" or "friends", online))
        placeSwitch(panel.browser, panel)
        panel.only:SetChecked(state.friendSharersOnly)
        panel.browser.fill(rows, function(k) return byKey[k] end, (count == 0 and next(whispers) == nil)
            and "No friends yet."
            or "Nobody here matches that search.")
    end
    panel.browser.refresh = panel.refresh
end

-- Public: the players who share with you that way.
local function buildPeers(panel, letter, intro, emptyText)
    local key = letter == "f" and "friends" or "public"
    panel.browser = makeBrowser(panel, key)
    local b = panel.browser
    -- Looking someone up by name heads the rail, the field and its button on one line, inset as the
    -- search is; then what the tab is, in dim words at the title's inset.
    local inset = Skin.SPACE.m
    panel.ask = Skin.button(b.head, "primary")
    panel.ask:SetText("Look up")
    panel.lookup = Skin.search(b.head, NAME or "Name") -- the game's own word for a name's field
    panel.lookup:SetPoint("TOPLEFT", inset, -inset)
    panel.lookup:SetPoint("RIGHT", panel.ask, "LEFT", -Skin.SPACE.s, 0)
    panel.ask:SetPoint("TOPRIGHT", -inset, -(inset + (panel.lookup:GetHeight() - panel.ask:GetHeight()) / 2))
    local function go()
        local name = str(panel.lookup:GetText())
        if name then ns.lookCommand(name) panel.lookup:SetText("") panel.lookup:ClearFocus() end
    end
    panel.ask:SetScript("OnClick", go)
    panel.lookup:SetScript("OnEnterPressed", go)
    panel.intro = Skin.text(b.head, "small")
    panel.intro:SetTextColor(Skin.rgb("dim"))
    panel.intro:SetWordWrap(true)
    panel.intro:SetSpacing(HEAD.leading)
    panel.intro:SetWidth(HEAD.width)
    local introTop = onGrid(inset + panel.lookup:GetHeight() + HEAD.gap)
    panel.intro:SetPoint("TOPLEFT", HEAD.inset, -introTop)
    panel.intro:SetText(intro)
    local function placeSearch() b.setHead(onGrid(introTop + (panel.intro:GetStringHeight() or 0) + HEAD.gap)) end
    placeSearch()
    function panel.refresh()
        placeSearch() -- its words' lines, now the game has laid them out
        local rows, byKey = {}, {}
        for _, p in ipairs(ns.peerList(letter)) do
            local c = type(p.card) == "table" and p.card or {}
            byKey[p.key] = { peer = p }
            if matches(state[key .. "Query"], p.key, c.name, c.guild, c.class, c.race) then
                rows[#rows + 1] = { key = p.key, label = classColored(c.name or ns.shortName(p.key), c.classFile), level = c.level, shares = true, cls = c.classFile,
                    info = str(c.guild) and ("<" .. c.guild .. ">") or words(c.race, c.class) }
            end
        end
        panel.browser.fill(rows, function(k) return byKey[k] end, emptyText)
    end
    panel.browser.refresh = panel.refresh
end

V.buildChars = buildChars
V.buildGuild = buildGuild
V.buildFriends = buildFriends
V.buildPeers = buildPeers
