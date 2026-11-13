-- Reliquary's window: a conversation, your guild's chat or your whispers with one player (Chat.lua
-- keeps them).
local ADDON, ns = ...

local V = ns.V

local Skin, Motion = ns.Skin, ns.Motion

local num, str = ns.num, ns.str
local ipairs, type = ipairs, type
local ceil, min, max = math.ceil, math.min, math.max
local PAGE_WIDTH, sound, classColored, hideTip = V.PAGE_WIDTH, V.sound, V.classColored, V.hideTip
local showTip, dayText, clockText = V.showTip, V.dayText, V.clockText
local SPACE = Skin.SPACE

---------------------------------------------------------------------------
-- A conversation: your guild's chat, or your whispers with one player (Chat.lua). Its lines are in
-- the chat's own font and the colours of the game's own chat window, their links open as they do
-- there, each speaker's lines sit under their avatar, name and time, a day's start is a small pill,
-- and a box at the foot sends what you type, as the game's chat box does.
---------------------------------------------------------------------------
local CHAT = {
    key = "\1chat",  -- the guild list's own row for its chat, never a name
    officerKey = "\1officer", -- and for its officer chat
    group = 300,     -- a speaker's lines this close together read as one
    icon = "Interface\\ChatFrame\\UI-ChatIcon-Chat-Up",
    discord = "UI-ChatIcon-Discord", -- the game's own mark for the guild's Discord, in its chat
    filters = { { "all", "All messages" }, { "today", "Today" }, { "week", "Past 7 days" }, { "me", "Mentions of you" },
        { "links", "Item links" }, { "ach", "Achievements" } },
    colors = { GUILD = { 0.25, 1, 0.25 }, GUILD_ACHIEVEMENT = { 0.25, 1, 0.25 }, GUILD_DISCORD = { 114 / 255, 126 / 255, 1 }, OFFICER = { 64 / 255, 192 / 255, 64 / 255 },
        WHISPER = { 1, 0.5, 1 }, WHISPER_INFORM = { 1, 0.5, 1 }, BN_WHISPER = { 0, 1, 0.965 }, BN_WHISPER_INFORM = { 0, 1, 0.965 } },
    words = setmetatable({}, { __mode = "k" }),   -- a line's words for searching, worked out once
    heights = setmetatable({}, { __mode = "k" }), -- a line's height, worked out once for its width
}

-- The conversation laid out (DESIGN, section 5), in units: the search and filter over it (bar tall,
-- below it the gap to the lines), the entry box at its foot (entry tall, foot over the page's foot,
-- clear of the window's grip; above it the gap to the lines), room for the scroll bar at its right. A speaker's group: its avatar (the words start
-- indent in), group above it; a line that follows in the same group, follow above it; the name's
-- line, nameGap over the first line; leading between a long line's lines; the Discord mark in an
-- avatar, mark across. A day's pill, day above it.
local LOOK = { bar = 26, below = SPACE.m, entry = 32, foot = SPACE.s, above = SPACE.m, scroll = 12, search = 240, filter = 160,
    avatar = 32, mark = 20, group = SPACE.l, follow = SPACE.xs, nameGap = SPACE.xs, leading = 2, day = SPACE.l, pill = 20, note = SPACE.xs }
LOOK.indent = LOOK.avatar + SPACE.m
LOOK.text = PAGE_WIDTH - LOOK.scroll - LOOK.indent - SPACE.s -- a line's width

-- The colour the player's own chat window gives that kind of line.
function CHAT.color(kind)
    local info = type(ChatTypeInfo) == "table" and ChatTypeInfo[kind]
    if type(info) == "table" and num(info.r) and num(info.g) and num(info.b) then return info.r, info.g, info.b end
    local c = CHAT.colors[kind] or { 1, 1, 1 }
    return c[1], c[2], c[3]
end

-- What a line says, for searching: its links as the names they show, without colours or pictures.
function CHAT.plain(r)
    local w = CHAT.words[r]
    if not w then
        w = (r.m:gsub("|H.-|h(.-)|h", "%1"):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|T.-|t", ""):gsub("|A.-|a", "")):lower()
        CHAT.words[r] = w
    end
    return w
end

-- Whether a line names someone (a given name, whole), not counting their own lines.
function CHAT.mentions(r, given)
    local words = " " .. CHAT.plain(r) .. " "
    return words:find("[^%w]" .. given:gsub("%p", "%%%0") .. "[^%w]") ~= nil
end

-- The chat's own font, at the size the player chose for chat, as the game's Guild & Communities
-- window has it.
local function chatFont(fs)
    fs:SetFontObject(ChatFontNormal)
    if DEFAULT_CHAT_FRAME then fs:SetFont(DEFAULT_CHAT_FRAME:GetFont()) end
    fs:SetJustifyH("LEFT")
end

-- A line's row: a day's pill with a line either side, or a line of the conversation, with its
-- speaker's avatar, name and time over it when it starts their group. All of it is on row.inner, which
-- is what arrives when the line is new.
local function makeRow(row, cv, opts)
    row.inner = CreateFrame("Frame", nil, row)
    row.inner:SetAllPoints()
    local inner = row.inner
    -- A day's start: the pill at the foot of its room, a pixel line either side of it out to the edges.
    row.pill = Skin.chip(inner)
    row.pill:SetPoint("BOTTOM")
    row.day = row.pill.text
    row.dayLeft = Skin.line(inner, "ink600")
    row.dayLeft:SetPoint("LEFT", inner, "BOTTOMLEFT", 0, LOOK.pill / 2)
    row.dayLeft:SetPoint("RIGHT", row.pill, "LEFT", -SPACE.m, 0)
    row.dayRight = Skin.line(inner, "ink600")
    row.dayRight:SetPoint("LEFT", row.pill, "RIGHT", SPACE.m, 0)
    row.dayRight:SetPoint("RIGHT", inner, "BOTTOMRIGHT", 0, LOOK.pill / 2)
    -- The speaker: their avatar and their name, each a click from their page; pointing at either warms
    -- the avatar's ring when there is a page to go to.
    row.who = CreateFrame("Button", nil, inner)
    row.who:SetSize(LOOK.avatar, LOOK.avatar)
    row.who:SetPoint("TOPLEFT", 0, -LOOK.group)
    row.who.avatar = Skin.avatar(row.who, LOOK.avatar)
    row.who.avatar:SetPoint("CENTER")
    row.who.avatar.ring.rqline = Skin.C.ink500
    row.who.icon = row.who.avatar.icon
    -- The game's Discord mark whole (a round mask would cut its corners away), inside the ring: on the
    -- avatar's own frame, over its floor.
    row.who.mark = row.who.avatar:CreateTexture(nil, "OVERLAY")
    row.who.mark:SetSize(LOOK.mark, LOOK.mark)
    row.who.mark:SetPoint("CENTER")
    row.named = CreateFrame("Button", nil, inner)
    row.named:SetPoint("TOPLEFT", LOOK.indent, -LOOK.group)
    row.who.name = Skin.text(row.named, "heading")
    row.who.name:SetPoint("TOPLEFT")
    row.named:SetHeight(cv.nameH)
    local function open(self)
        local who = row.who.open
        if who and opts.open then sound("IG_MAINMENU_OPTION_CHECKBOX_ON") opts.open(who) end
    end
    local function enter(self)
        local tip = opts.openTip and opts.openTip(row.who.open, row.who.label)
        if row.who.cut then
            showTip(self, row.who.label or "", tip and { tip } or nil)
        elseif tip then showTip(self, tip) end
        if row.who.open then Skin.tint(row.who.avatar.ring, "line", "gold600") end
    end
    local function leave()
        hideTip()
        Skin.tint(row.who.avatar.ring, "line", "ink500")
    end
    for _, b in ipairs({ row.who, row.named }) do
        b:SetScript("OnClick", open)
        b:SetScript("OnEnter", enter)
        b:SetScript("OnLeave", leave)
    end
    -- The time on the name's line, the two sharing their foot.
    row.when = Skin.text(inner, "dim")
    row.when:SetPoint("BOTTOMLEFT", row.who.name, "BOTTOMRIGHT", SPACE.s, 0)
    row.body = inner:CreateFontString(nil, "ARTWORK")
    chatFont(row.body)
    row.body:SetWordWrap(true)
    row.body:SetSpacing(LOOK.leading)
    -- Links in a line, as in the game's chat: their tooltip on hover, the game's own click.
    inner:SetHyperlinksEnabled(true)
    inner:SetScript("OnHyperlinkEnter", function(self, link)
        GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
        if pcall(GameTooltip.SetHyperlink, GameTooltip, link) then GameTooltip:Show() else GameTooltip:Hide() end
    end)
    inner:SetScript("OnHyperlinkLeave", hideTip)
    inner:SetScript("OnHyperlinkClick", function(self, link, shown, button)
        if type(SetItemRef) == "function" then pcall(SetItemRef, link, shown, button, self) end
    end)
end

-- A row drawn for its line. A line new since the conversation last drew, while it showed, arrives (it
-- fades in and rises); drawn again for the same line it goes on arriving; for another line it lands.
local function drawRow(row, line, cv, opts)
    if not row.inner then makeRow(row, cv, opts) end
    local was = row.line
    local same = was ~= nil and (line.rec ~= nil and was.rec == line.rec or line.kind == "day" and was.kind == "day" and was.left == line.left)
    row.line = line
    if line.fresh then
        local n = line.fresh
        line.fresh = nil
        Motion.arrive(row.inner, n)
    elseif not same then
        Motion.finish(row.inner)
    end
    local day = line.kind == "day"
    for _, part in ipairs({ row.pill, row.dayLeft, row.dayRight }) do part:SetShown(day) end
    row.body:SetShown(not day)
    local head = not day and line.head == true
    row.named:SetShown(head)
    row.when:SetShown(head)
    row.who:SetShown(false)
    if day then
        row.pill:Set(line.left or "")
        return
    end
    local r, sp = line.rec, line.speaker
    if head then
        -- Their class's icon; one on the guild's Discord whose class isn't known, the game's Discord
        -- mark; anyone else whose class isn't known, nothing, the name in its column.
        local av, mark = row.who.avatar, not sp.class and sp.discord == true
        av:SetClass(sp.class)
        row.who.mark:SetShown(mark)
        if mark then row.who.mark:SetAtlas(CHAT.discord) end
        row.who:SetShown(sp.class ~= nil or mark)
        row.who.name:SetText(classColored(sp.name, sp.class))
        -- The name takes what the row has left beside its time; cut short, it shows whole on hover.
        row.when:SetText(clockText(r.t, true))
        row.who.name:SetWidth(0)
        local room = max(1, LOOK.text - (num(row.when:GetStringWidth()) or 60) - SPACE.s)
        local fullWidth = num(row.who.name:GetStringWidth()) or room
        local nameWidth = min(room, fullWidth)
        row.who.cut = fullWidth > room
        row.who.name:SetWidth(nameWidth)
        row.named:SetWidth(max(1, nameWidth))
        row.who.open, row.who.label = sp.open, sp.name
        Motion.stop(row.who.avatar.ring, "line")
        row.who.avatar.ring:SetColor("ink500")
        row.who.avatar.ring.rqline = Skin.C.ink500
    end
    row.body:ClearAllPoints()
    row.body:SetPoint("TOPLEFT", LOOK.indent, -(head and (LOOK.group + cv.nameH + LOOK.nameGap) or LOOK.follow))
    row.body:SetPoint("RIGHT", -SPACE.s, 0)
    row.body:SetText(line.text)
    row.body:SetTextColor(CHAT.color(r.k == "a" and "GUILD_ACHIEVEMENT" or r.k == "d" and "GUILD_DISCORD" or line.color or opts.kind))
end

-- Why a line couldn't go, under the box (Chat.lua's reasons).
local WHY = {
    lockdown = "The game holds back chat from addons right now; send it from the game's chat box.",
    noguild = "This character isn't in a guild.", failed = "The game didn't send that.", unavailable = "The game didn't send that.",
    long = "That's more than the game's chat sends at once.",
    notofficer = "This character's rank doesn't hear officer chat.", nobnet = "They aren't on your Battle.net friends list now.",
}

-- A conversation over parent. opts: hint (the box's prompt), empty (what it says before anything
-- is kept), source() (its lines, oldest first), send(text) (true, or false and why), kind (the game's
-- chat kind for its colour), filters (the guild's choices), speaker(rec) (name, class, whom to open,
-- whether they're on the guild's Discord), open(who) and openTip(who) (a speaker's page, and what
-- pointing at them says).
local function makeConversation(parent, opts)
    local cv = CreateFrame("Frame", nil, parent)
    cv.filter, cv.query = "all", ""
    -- Over the lines: the search, and the guild's filter at the right.
    cv.search = Skin.search(cv)
    cv.search:SetPoint("TOPLEFT")
    cv.search:SetWidth(LOOK.search)
    cv.search.onChange = function(text)
        cv.query = (text or ""):lower()
        if cv:IsVisible() then cv.draw() end
    end
    if opts.filters then
        cv.pick = Skin.dropdown(cv)
        cv.pick:SetWidth(LOOK.filter)
        cv.pick:SetPoint("TOPRIGHT", 0, -(LOOK.bar - cv.pick:GetHeight()) / 2)
        cv.pick:SetText(CHAT.filters[1][2])
        cv.pick:SetupMenu(function(_, root)
            for _, f in ipairs(CHAT.filters) do
                root:CreateRadio(f[2], function() return cv.filter == f[1] end, function()
                    cv.filter = f[1]
                    cv.pick:SetText(f[2])
                    cv.draw()
                end, f[1])
            end
        end)
    end
    -- What's said is measured in the font it's drawn in, at its width.
    cv.measure = cv:CreateFontString(nil, "ARTWORK")
    chatFont(cv.measure)
    cv.measure:SetWordWrap(true)
    cv.measure:SetSpacing(LOOK.leading)
    cv.measure:SetPoint("TOPLEFT")
    cv.measure:SetWidth(LOOK.text)
    cv.measure:SetAlpha(0) -- shown, so the game measures it as it lays out text it draws, and never seen
    cv.nameH = ceil(select(2, Skin.font("heading"):GetFont()) or 13) -- a name's line

    cv.list, cv.bar = Skin.scroll(cv, { frameType = "Frame", right = LOOK.scroll, fade = SPACE.xl,
        extent = function(line) return line.h end,
        init = function(row, line) drawRow(row, line, cv, opts) end })

    cv.empty = Skin.text(cv, "body")
    cv.empty:SetTextColor(Skin.rgb("dim"))
    cv.empty:SetWordWrap(true)
    cv.empty:SetPoint("RIGHT", -LOOK.scroll, 0)

    -- The box to send your own, a well at the foot: Enter sends it, as the game's chat box does; why it
    -- couldn't, over it. What you type is in the chat's own font; the prompt, quiet, until you do.
    cv.box = Skin.well(cv)
    cv.box:SetPoint("BOTTOMLEFT", 0, LOOK.foot)
    cv.box:SetPoint("BOTTOMRIGHT", 0, LOOK.foot)
    cv.box:SetHeight(LOOK.entry)
    cv.box.line = Skin.nine(cv.box, "ring", { radius = Skin.RADIUS.control, layer = "BACKGROUND", sub = 2, color = "ink600" })
    cv.input = CreateFrame("EditBox", nil, cv.box)
    cv.input:SetAllPoints()
    cv.input:SetAutoFocus(false)
    chatFont(cv.input)
    cv.input:SetTextInsets(SPACE.m, SPACE.m, 0, 0)
    cv.input:SetMaxBytes(ns.CHAT_SEND_BYTES or 1280) -- as the game's chat box holds a line
    cv.input:SetVisibleTextByteLimit(ns.CHAT_SEND_VISIBLE or 255)
    cv.input.Instructions = Skin.text(cv.input, "body", "LEFT", false, "OVERLAY")
    cv.input.Instructions:SetTextColor(Skin.rgb("dim"))
    cv.input.Instructions:SetPoint("LEFT", SPACE.m, 0)
    cv.input.Instructions:SetPoint("RIGHT", -SPACE.m, 0)
    cv.input.Instructions:SetText(opts.hint or "")
    cv.input.focus = Skin.line(cv.input, "moon", { layer = "OVERLAY" })
    cv.input.focus:SetPoint("BOTTOMLEFT", SPACE.xs, 1)
    cv.input.focus:SetPoint("BOTTOMRIGHT", -SPACE.xs, 1)
    cv.input.focus:SetAlpha(0)
    cv.note = Skin.text(cv, "small")
    cv.note:SetTextColor(Skin.rgb("ember"))
    cv.note:SetPoint("BOTTOMLEFT", cv.box, "TOPLEFT", 0, LOOK.note)
    cv.note:SetPoint("RIGHT")
    cv.input:SetScript("OnTextChanged", function(self) self.Instructions:SetShown((self:GetText() or "") == "") end)
    cv.input:SetScript("OnEditFocusGained", function(self) Motion.fade(self.focus, 1, { dur = "fast", from = self.focus:GetAlpha() }) end)
    cv.input:SetScript("OnEditFocusLost", function(self) Motion.fade(self.focus, 0, { dur = "fast", from = self.focus:GetAlpha() }) end)
    cv.input:SetScript("OnEnterPressed", function(self)
        local typed = self:GetText() or ""
        if not typed:match("%S") then self:ClearFocus() return end
        local ok, why = opts.send(typed)
        cv.note:SetText(ok and "" or (WHY[why] or ""))
        if ok then self:SetText("") end
        cv.place()
    end)
    cv.input:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    -- A link shift-clicked from your bags while you type goes into this box, as into the game's.
    if type(hooksecurefunc) == "function" and type(ChatFrameUtil) == "table" and type(ChatFrameUtil.InsertLink) == "function" then
        hooksecurefunc(ChatFrameUtil, "InsertLink", function(link)
            if cv.input:HasFocus() and type(link) == "string" then cv.input:Insert(link) end
        end)
    end

    -- The lines sit on the box, newest last: a short conversation fills from the foot up, under an empty
    -- page, as a chat does; a long one scrolls under the search. The search and filter show once there is
    -- something to search; a reason the box couldn't send pushes the lines up over it.
    function cv.place()
        local noted = (cv.note:GetText() or "") ~= ""
        cv.note:SetShown(noted)
        local top = cv.search:IsShown() and (LOOK.bar + LOOK.below) or 0
        local bottom = LOOK.foot + LOOK.entry + LOOK.above + (noted and ceil((cv.note:GetLineHeight() or 11) + LOOK.note) or 0)
        local space = (num(cv:GetHeight()) or 0) - top - bottom
        local list = cv.list
        list:ClearAllPoints()
        if (cv.total or 0) < space then
            list:SetPoint("BOTTOMLEFT", 0, bottom)
            list:SetPoint("BOTTOMRIGHT", -LOOK.scroll, bottom)
            list:SetHeight(max(1, cv.total or 0))
        else
            list:SetPoint("TOPLEFT", 0, -top)
            list:SetPoint("BOTTOMRIGHT", -LOOK.scroll, bottom)
        end
        cv.empty:SetPoint("BOTTOMLEFT", 0, bottom)
    end

    -- Nothing new while it was away: what it drew last is forgotten when it, or the page it is on, hides.
    local function forget() cv.lastRec = nil end
    cv:HookScript("OnHide", forget)
    parent:HookScript("OnHide", forget)

    -- The lines that pass the search and the chosen filter, in order, a day's start marked and each
    -- speaker's run of lines under one name. Scrolled to the newest when it was there already, and then
    -- the lines new since it last drew, while it showed, arrive.
    function cv.draw()
        local recs = opts.source() or {}
        local now = time()
        local today = date("%Y%m%d", now)
        local any = #recs > 0
        cv.search:SetShown(any or cv.query ~= "")
        if cv.pick then cv.pick:SetShown(any) end
        local atEnd = not cv.drawn or not cv.list:HasScrollableExtent() or (num(cv.list:GetScrollPercentage()) or 1) > 0.99
        -- What it showed before, while it showed: the lines after it are new.
        local after
        if atEnd and cv.lastRec and not V.entrance and cv:IsVisible() and cv.drawnFilter == cv.filter and cv.drawnQuery == cv.query then
            for i = #recs, 1, -1 do if recs[i] == cv.lastRec then after = i break end end
        end
        cv.lastRec, cv.drawnFilter, cv.drawnQuery = recs[#recs], cv.filter, cv.query
        -- Your given name, as others write it: without a realm, the first of a "Given Family" name.
        local given = (ns.shortName(str(ns.me and ns.me()) or "") or ""):match("^(%S+)")
        given = given and given:lower()
        local lines, lastDay, lastWho, lastT, total, fresh = {}, nil, nil, nil, 0, 0
        for i, r in ipairs(recs) do
            if type(r) == "table" and type(r.m) == "string" and num(r.t) then
                local f, show = cv.filter, true
                if f == "today" then show = date("%Y%m%d", r.t) == today
                elseif f == "week" then show = r.t >= now - 7 * 86400
                elseif f == "links" then show = r.m:find("|Hitem:", 1, true) ~= nil
                elseif f == "ach" then show = r.k == "a"
                elseif f == "me" then show = given ~= nil and r.n ~= (ns.me and ns.me()) and CHAT.mentions(r, given) end
                local sp = show and opts.speaker(r)
                if sp and cv.query ~= "" then
                    local q = cv.query
                    show = CHAT.plain(r):find(q, 1, true) ~= nil or sp.name:lower():find(q, 1, true) ~= nil
                end
                if show and sp then
                    local new = after ~= nil and i > after
                    if new then fresh = fresh + 1 end
                    local day = date("%Y%m%d", r.t)
                    if day ~= lastDay then
                        local label = day == today and "Today" or day == date("%Y%m%d", now - 86400) and "Yesterday" or dayText(r.t)
                        lines[#lines + 1] = { kind = "day", left = label, h = LOOK.day + LOOK.pill, fresh = new and fresh or nil }
                        total = total + LOOK.day + LOOK.pill
                        lastWho = nil
                    end
                    local head = sp.key ~= lastWho or r.t - (lastT or 0) > CHAT.group or r.k == "a"
                    local body = r.m
                    -- An achievement's line puts the name where its %s is; the name is above it already.
                    if r.k == "a" then body = (body:gsub("^%%s%s*", ""):gsub("%%s", sp.name)) end
                    local hk = CHAT.heights[r]
                    if not hk then
                        cv.measure:SetText(body)
                        hk = ceil(num(cv.measure:GetStringHeight()) or 14)
                        CHAT.heights[r] = hk
                    end
                    local h = head and (LOOK.group + max(LOOK.avatar, cv.nameH + LOOK.nameGap + hk)) or (LOOK.follow + hk)
                    lines[#lines + 1] = { kind = "say", rec = r, speaker = sp, head = head, text = body, color = sp.color, h = h,
                        fresh = new and fresh or nil }
                    total = total + h
                    lastDay, lastWho, lastT = day, sp.key, r.t
                end
            end
        end
        cv.total = total
        cv.empty:SetText(#lines > 0 and "" or #recs == 0 and (opts.empty or "") or "Nothing here matches that.")
        cv.empty:SetShown((cv.empty:GetText() or "") ~= "")
        cv.place()
        cv.list:SetDataProvider(CreateDataProvider(lines), ScrollBoxConstants and ScrollBoxConstants.RetainScrollPosition)
        if atEnd then cv.list:ScrollToEnd(true) end
        cv.drawn = true
        return lines
    end
    return cv
end

V.CHAT = CHAT
V.makeConversation = makeConversation
