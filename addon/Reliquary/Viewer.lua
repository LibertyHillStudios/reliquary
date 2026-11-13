-- Reliquary's window (/rq): every character on your account, your guild with every guildmate's
-- reliquary, the guild bank as it was last seen, your friends' and other players' reliquaries, and
-- who sees this character's. It shows only what is already in ReliquaryDB (recorded by
-- Reliquary.lua, shared by Share.lua) and is built the first time it opens. This file is the window
-- itself (docs/DESIGN.md, section 3): its own frame art, the top bar with the crest, the wordmark and
-- the tabs, opening and closing, the scale grip and where it was left; each tab and page is in a file
-- of its own (Viewer*.lua), drawn from Skin.lua's pieces and moved by Motion.lua's clock.
local ADDON, ns = ...

local V = ns.V
local Skin, Motion = ns.Skin, ns.Motion

local call, num, str, api = ns.call, ns.num, ns.str, ns.api
local ipairs, type, next = ipairs, type, next
local min, max, floor, sqrt = math.min, math.max, math.floor, math.sqrt
local WIDTH, HEIGHT, TOP_BAR, state, sound, hideTip, myGuild = V.WIDTH, V.HEIGHT, V.TOP_BAR, V.state, V.sound, V.hideTip, V.myGuild

local TABS = { "Characters", "Guild", "Guild Bank", "Friends", "Public", "Sharing" }
-- The window's scale, by its grip: within these, back to 1 on a double-click.
local SCALE = { least = 0.75, most = 1.25 }
-- The crest: Reliquary's shrine on its round night sky (Media/portrait-<size>.tga, from
-- brand/portrait.svg) in a thin gold ring, drawn from the texture nearest the size the screen shows it.
local CREST = { size = 32, sizes = { 64, 128, 256 }, file = "Interface\\AddOns\\Reliquary\\Media\\portrait-" }
-- The tabs whose header stands over the window's body rather than heading the rail.
local HEADED = { ["Guild Bank"] = true, Sharing = true }

local frame
local panels = {}

---------------------------------------------------------------------------
-- The tabs
---------------------------------------------------------------------------
-- Why a tab has nothing to show, or nil when it has something. Such a tab is greyed, as the game greys
-- a tab that doesn't apply, and says why on hover.
local function tabReason(name)
    if name == "Guild" and not ns.guildKey() then return "This character isn't in a guild." end
    if name == "Guild Bank" then
        local g = myGuild()
        return V.bankEmpty((V.bankTabs(g)), g and ns.isGuildLeader() or false)
    end
    if name == "Friends" then
        if next(type(ns.db.whispers) == "table" and ns.db.whispers or {}) or #ns.peerList("f") > 0 then return nil end
        for _, f in ipairs(ns.friends and ns.friends() or {}) do
            if f.kind ~= "bnet" or f.on then return nil end
        end
        return "No friends or whispers yet."
    end
    if name == "Public" and #ns.peerList("p") == 0 then
        return "Players who share with everyone show here. Target a player who uses Reliquary to ask them, or type /rq look and their name."
    end
end

-- Greys the tabs with nothing to show, and leaves one of them for Characters.
local function updateTabs()
    for i, name in ipairs(TABS) do
        local tab = frame.Tabs[i]
        tab.reason = tabReason(name)
        frame.tabs:SetEnabled(i, not tab.reason)
    end
    if frame.Tabs[state.tab].reason then state.tab = 1 end
end

-- Another tab: the marker slides to it, the old page leaves and the new one arrives from the side it
-- lies on.
local function selectTab(i, instant)
    local was = frame.selectedTab
    state.tab = i
    updateTabs()
    i = state.tab
    frame.selectedTab = i
    frame.tabs:Select(i, instant)
    if TABS[i] == "Friends" then call(api("C_FriendList.ShowFriends")) end -- fresh news of your friends, as the game's friends frame asks
    for n, p in ipairs(panels) do
        if n ~= i and p:IsShown() then
            if instant or n ~= was then p:Hide()
            else Motion.fade(p, 0, { dur = Motion.leave, done = function(q) q:Hide() q:SetAlpha(1) end }) end
        end
    end
    local p = panels[i]
    Motion.stop(p, "alpha")
    p:SetAlpha(1)
    p:Show()
    if not instant and was and was ~= i then
        Motion.fade(p, 1, { from = 0, dur = "base", ease = "enter" })
        Motion.slide(p, (i > was and 1 or -1) * Motion.SLIDE_PAGE, 0, { dur = "base", ease = "enter" })
    end
    p.refresh()
end

---------------------------------------------------------------------------
-- The frame
---------------------------------------------------------------------------
-- The crest's texture: the size nearest what the screen draws it.
local function placeCrest()
    local c = frame.crest
    local across = CREST.size / Skin.pixel(c.art)
    local pick = CREST.sizes[#CREST.sizes]
    for _, n in ipairs(CREST.sizes) do
        if n >= across then pick = n break end
    end
    if c.art.rqSize ~= pick then
        c.art:SetTexture(CREST.file .. pick)
        c.art.rqSize = pick
    end
end

local function remember()
    local point, _, rel, x, y = frame:GetPoint(1)
    if type(ns.db.settings) == "table" and point then ns.db.settings.window = { point, rel, x, y } end
end

-- UIParent's dimensions are already in its own units, so its interface scale applies equally to
-- the screen and the window. On a very small canvas, fitting takes precedence over the usual minimum.
local function fitScale(s)
    local w, h = num(call(UIParent.GetWidth, UIParent)), num(call(UIParent.GetHeight, UIParent))
    local most = SCALE.most
    if w and w > 0 then most = min(most, w / WIDTH) end
    if h and h > 0 then most = min(most, h / HEIGHT) end
    return min(most, max(min(SCALE.least, most), s)), w, h
end

-- Keep the top left where it was, unless an edge would leave the screen. This also recovers an old
-- saved size or position after changing the display or the game's interface scale.
local function setScale(s)
    local w, h
    s, w, h = fitScale(s)
    local old = frame:GetScale()
    local left, top = frame:GetLeft(), frame:GetTop()
    frame:SetScale(s)
    if left and top then
        left, top = left * old, top * old
        if w and w > 0 then left = max(0, min(left, w - WIDTH * s)) end
        if h and h > 0 then top = min(h, max(top, HEIGHT * s)) end
        frame:ClearAllPoints()
        frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left / s, top / s)
    end
    if type(ns.db.settings) == "table" then ns.db.settings.windowScale = s end
    remember()
    Skin.refresh()
    placeCrest()
end

local function stopResize()
    if not frame or not frame.grip then return end
    local g = frame.grip
    g:SetScript("OnUpdate", nil)
    g.start = nil
    Skin.tint(g.glyph, "glyph", "muted")
    frame:StopMovingOrSizing()
    remember()
end

-- The body: ink.900 with a faint field of stars, a soft dark vignette at its edges, one gold.500 line
-- all round with its corners lit, and a wide soft shadow under it.
local function body(c)
    Skin.nine(c, "shadow", { layer = "BACKGROUND", sub = -8, rect = c, inset = { 0, -6, 0, 6 } })
    local s = Skin.surface(c, { fill = "ink900", line = "gold500", radius = Skin.RADIUS.window, layer = "BACKGROUND", sub = -7 })
    frame.surface = s
    -- The line's corners catch the light: drawn a little brighter.
    for _, key in ipairs({ "tl", "tr", "bl", "br" }) do s.line.tex[key]:SetVertexColor(Skin.rgb("gold400")) end
    -- Stars: small soft points of the moon's colour, added to the ink (4% of it at most), at places a
    -- seeded count gives, the same each time.
    local seed = 1107
    local function rand()
        seed = (seed * 1103515245 + 12345) % 2147483648
        return seed / 2147483648
    end
    for _ = 1, 64 do
        local s = c:CreateTexture(nil, "BACKGROUND", nil, -5)
        s:SetTexture("Interface\\AddOns\\Reliquary\\Media\\ui-glow")
        s:SetBlendMode("ADD")
        local size = 2 + rand() * 2.5
        s:SetSize(size, size)
        s:SetPoint("CENTER", c, "TOPLEFT", 12 + rand() * (WIDTH - 24), -(TOP_BAR + 8 + rand() * (HEIGHT - TOP_BAR - 20)))
        s:SetVertexColor(Skin.rgb("moon"))
        s:SetAlpha(0.012 + rand() * 0.034)
    end
    -- The vignette: each edge darkened inward along the fade's curve.
    local fade = "Interface\\AddOns\\Reliquary\\Media\\ui-fade"
    for _, e in ipairs({ { "BOTTOMLEFT", "BOTTOMRIGHT", 0, 1, 1, 0, 56 }, { "TOPLEFT", "BOTTOMLEFT", 0, 1, 0, 1, 64, true },
        { "TOPRIGHT", "BOTTOMRIGHT", 1, 0, 0, 1, 64, true } }) do
        local v = c:CreateTexture(nil, "BACKGROUND", nil, -4)
        v:SetTexture(fade)
        v:SetVertexColor(Skin.rgb("black"))
        v:SetAlpha(0.4)
        if e[8] then
            -- A side: the fade turned to run across.
            v:SetPoint(e[1], c, e[1], e[1]:find("LEFT") and 1 or -1, -TOP_BAR)
            v:SetPoint(e[2], c, e[2], 0, 1)
            v:SetWidth(e[7])
            -- The fade's top (whole) at the window's edge: its corners' coordinates turned a quarter.
            if e[1]:find("LEFT") then v:SetTexCoord(0, 0, 1, 0, 0, 1, 1, 1) else v:SetTexCoord(0, 1, 1, 1, 0, 0, 1, 0) end
        else
            v:SetPoint(e[1], c, e[1], 1, 1)
            v:SetPoint(e[2], c, e[2], -1, 1)
            v:SetHeight(e[7])
            v:SetTexCoord(0, 1, 1, 0)
        end
    end
end

-- The top bar: ink.850 with a gold.600 line under it; the crest, the wordmark, the tabs (Sharing apart
-- at the right) and the close button. The window moves by it.
local function topBar(c)
    local top = CreateFrame("Frame", nil, c)
    frame.top = top
    top:SetPoint("TOPLEFT")
    top:SetPoint("TOPRIGHT")
    top:SetHeight(TOP_BAR)
    Skin.nine(top, "disc", { radius = Skin.RADIUS.window, layer = "BACKGROUND", sub = -3, color = "ink850", px = 1,
        square = { bl = true, br = true } })
    local rule = Skin.line(top, "gold600", { layer = "BORDER" })
    rule:SetPoint("BOTTOMLEFT", 1, 0)
    rule:SetPoint("BOTTOMRIGHT", -1, 0)
    top:EnableMouse(true)
    top:RegisterForDrag("LeftButton")
    top:SetScript("OnDragStart", function() frame:StartMoving() end)
    top:SetScript("OnDragStop", function()
        frame:StopMovingOrSizing()
        remember()
    end)

    -- The crest in a thin gold ring, its moon breathing.
    local crest = CreateFrame("Frame", nil, top)
    frame.crest = crest
    crest:SetSize(CREST.size + 2, CREST.size + 2)
    crest:SetPoint("LEFT", 14, 0)
    crest.ring = Skin.band(crest, CREST.size, { color = "gold600", layer = "ARTWORK", sub = 0 })
    crest.art = crest:CreateTexture(nil, "ARTWORK", nil, 1)
    crest.art:SetPoint("TOPLEFT", 1, -1)
    crest.art:SetPoint("BOTTOMRIGHT", -1, 1)
    crest.moon = crest:CreateTexture(nil, "ARTWORK", nil, 2)
    crest.moon:SetTexture("Interface\\AddOns\\Reliquary\\Media\\ui-glow")
    crest.moon:SetBlendMode("ADD")
    crest.moon:SetSize(16, 16)
    crest.moon:SetPoint("CENTER", 1, -3)
    crest.moon:SetVertexColor(Skin.rgb("moon"))
    crest.moon:SetAlpha(0.2)

    frame.wordmark = Skin.text(top, "wordmark", "LEFT")
    frame.wordmark:SetPoint("LEFT", crest, "RIGHT", 10, 0)
    Skin.label(frame.wordmark, "Reliquary")

    frame.close = Skin.button(top, "icon")
    frame.close:SetSize(28, 28)
    frame.close:SetGlyph("close", 14)
    frame.close:SetPoint("RIGHT", -10, 0)
    frame.close:SetScript("OnClick", function() V.close() end)

    -- The tabs, keeping the names the game's own tabs had (ReliquaryFrameTab1 to 6).
    local tabs = Skin.tabs(top, "window")
    frame.tabs, frame.Tabs = tabs, {}
    for i, label in ipairs(TABS) do
        local tab = tabs:Add(i, label, "ReliquaryFrameTab" .. i, label == "Sharing")
        tab:SetID(i)
        tab:HookScript("OnEnter", function(self)
            if not self.reason then return end
            GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
            GameTooltip:SetText(TABS[i])
            GameTooltip:AddLine(self.reason, 1, 1, 1, true)
            GameTooltip:Show()
        end)
        tab:HookScript("OnLeave", hideTip)
        frame.Tabs[i] = tab
    end
    tabs.onSelect = function(i)
        sound("IG_CHARACTER_INFO_TAB")
        selectTab(i)
    end
    tabs:Layout(14 + CREST.size + 2 + 10 + floor((frame.wordmark:GetStringWidth() or 0) + 0.5) + 20, 0, 10 + 28 + 6)

    -- The line of light that crosses the top border once as the window opens.
    frame.light = top:CreateTexture(nil, "OVERLAY", nil, 7)
    frame.light:SetTexture("Interface\\AddOns\\Reliquary\\Media\\ui-light")
    frame.light:SetBlendMode("ADD")
    frame.light:SetSize(220, 10)
    frame.light:SetVertexColor(Skin.rgb("gold100"))
    frame.light:Hide()
end

-- The grip in the bottom right corner: dragged, it scales the whole window; a double-click sets it
-- back to 1.
local function grip(c)
    local g = Skin.button(c, "icon")
    frame.grip = g
    g:SetSize(18, 18)
    g:SetGlyph("grip", 12)
    g:SetPoint("BOTTOMRIGHT", -3, 3)
    g:SetFrameLevel(c:GetFrameLevel() + 40)
    g:RegisterForClicks("LeftButtonUp")
    g:SetScript("OnMouseDown", function(self, button)
        if button ~= "LeftButton" or frame.closing then return end
        local x, y = GetCursorPosition()
        local left, top = frame:GetLeft(), frame:GetTop()
        local fs = frame:GetEffectiveScale()
        if not (x and left and top) then return end
        -- How far the cursor is from the window's top left, on the screen, as the drag starts.
        self.start = { scale = frame:GetScale(), dist = sqrt((x - left * fs) ^ 2 + (y - top * fs) ^ 2), left = left * fs, top = top * fs }
        self:SetScript("OnUpdate", function()
            local cx, cy = GetCursorPosition()
            local d = sqrt((cx - self.start.left) ^ 2 + (cy - self.start.top) ^ 2)
            if self.start.dist > 0 then setScale(self.start.scale * d / self.start.dist) end
        end)
        Skin.tint(self.glyph, "glyph", "gold200")
    end)
    g:SetScript("OnMouseUp", function(_, button)
        if button == "LeftButton" then stopResize() end
    end)
    g:SetScript("OnDoubleClick", function()
        setScale(1)
        remember()
    end)
    g:HookScript("OnEnter", function(self) GameTooltip:SetOwner(self, "ANCHOR_RIGHT") GameTooltip:SetText(str(UI_SCALE) or "Scale") GameTooltip:Show() end)
    g:HookScript("OnLeave", hideTip)
end

-- Opening: the window fades in, rises and grows into place, a line of light crosses its top border,
-- then the list, the hero and the page arrive in order (V.entrance, for the pages).
local function opening()
    local c = frame.canvas
    Motion.fade(c, 1, { from = 0, dur = "slow", ease = "enter" })
    Motion.scale(c, 1, { from = Motion.OPEN_SCALE, dur = "slow", ease = "enter" })
    Motion.slide(c, 0, -Motion.RISE_WINDOW, { dur = "slow", ease = "enter" })
    local light = frame.light
    if Motion.enabled() then
        light:Show()
        Motion.to(light, "sweep", WIDTH + 220, { from = -220, dur = "long", delay = Motion.base, ease = "ambient",
            set = function(l, x)
                l:ClearAllPoints()
                l:SetPoint("CENTER", frame.top, "TOPLEFT", x, 0)
                l:SetAlpha(max(0, min(1, 3 * (1 - math.abs(x / (WIDTH / 2) - 1))))) -- brightest over the middle
            end,
            done = function(l) l:Hide() end })
    end
    -- The moon in the crest breathes while the window is open.
    Motion.loop(frame.crest.moon, "breathe", 0.12, 0.42, Motion.breathe, function(t, a) t:SetAlpha(a) end)
end

-- Closing (the X, /rq, Escape): it fades and sinks a little, then hides.
function V.close()
    if not frame or not frame:IsShown() or frame.closing then return end
    stopResize()
    if not Motion.enabled() then frame:Hide() return end
    frame.closing = true
    local c = frame.canvas
    Motion.scale(c, Motion.CLOSE_SCALE, { from = 1, dur = Motion.close, ease = "out" })
    Motion.fade(c, 0, { from = c:GetAlpha(), dur = Motion.close, ease = "out", done = function() frame:Hide() end })
end

local function build()
    -- The window places itself (where you last left it, at the scale you left it) and holds the
    -- canvas, which draws it and moves as it opens and closes. At the game's own panels' level, a click
    -- brings it to the front; it is kept on the screen.
    frame = CreateFrame("Frame", "ReliquaryFrame", UIParent)
    V.frame = frame
    frame:SetSize(WIDTH, HEIGHT)
    local settings = type(ns.db.settings) == "table" and ns.db.settings or {}
    local at = type(settings.window) == "table" and settings.window
    if at and str(at[1]) and str(at[2]) and num(at[3]) and num(at[4]) then
        frame:SetPoint(at[1], UIParent, at[2], at[3], at[4])
    else
        frame:SetPoint("CENTER")
    end
    frame:SetScale((fitScale(num(settings.windowScale) or 1)))
    frame:SetToplevel(true)
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:Hide()
    local c = CreateFrame("Frame", nil, frame)
    frame.canvas = c
    c:SetSize(WIDTH, HEIGHT)
    c:SetPoint("CENTER")
    body(c)
    topBar(c)
    -- What the tabs draw on: everything under the top bar, inside the line.
    frame.body = CreateFrame("Frame", nil, c)
    frame.body:SetPoint("TOPLEFT", 1, -TOP_BAR)
    frame.body:SetPoint("BOTTOMRIGHT", -1, 1)
    grip(c)
    placeCrest()

    -- Escape closes it through a stand-in in UISpecialFrames, so the game's own close-on-Escape runs
    -- and the window still closes as it does by the X. The stand-in shows only while the window does.
    local escape = CreateFrame("Frame", "ReliquaryEscape", UIParent)
    escape:Hide()
    escape:SetScript("OnHide", function() if frame:IsShown() and not frame.quiet then V.close() end end)
    tinsert(UISpecialFrames, "ReliquaryEscape")

    local builders = {
        V.buildChars, V.buildGuild, V.buildBank,
        V.buildFriends,
        function(p) V.buildPeers(p, "p", "Players who share with everyone. Target a player to ask them, or look one up by name.",
            "Nobody yet. Target a player who uses Reliquary and shares publicly, or look one up by name above.") end,
        V.buildSharing,
    }
    for i, make in ipairs(builders) do
        local p = CreateFrame("Frame", nil, frame.body)
        -- A tab without the rail has its header over its body (V.HEADER tall).
        p:SetPoint("TOPLEFT", 0, HEADED[TABS[i]] and -V.HEADER or 0)
        p:SetPoint("BOTTOMRIGHT")
        p:Hide()
        make(p)
        panels[i] = p
    end
    -- The tab showing draws again; the others are greyed or not by what they have now, and the one
    -- showing gives way to Characters when it has nothing left.
    local function refreshShown(tabsOnly)
        local was = state.tab
        updateTabs()
        if state.tab ~= was then selectTab(state.tab, true) elseif not tabsOnly then panels[state.tab].refresh() end
    end
    frame:SetScript("OnShow", function()
        sound("IG_CHARACTER_INFO_OPEN")
        Motion.setEnabled(type(ns.db.settings) ~= "table" or ns.db.settings.motion ~= false)
        setScale(frame:GetScale())
        Skin.refresh() -- the screen or the interface's scale may have changed since it last showed
        placeCrest()
        escape:Show()
        ns.requestGuildRoster()
        V.entrance = true
        opening()
        selectTab(state.tab, true)
        V.entrance = false
    end)
    -- The screen or the interface's scale changed: lines and corners follow. Your friends lists
    -- changed: the Friends tab does, when it shows.
    local FRIENDS_NEWS = { FRIENDLIST_UPDATE = true, BN_FRIEND_INFO_CHANGED = true, BN_FRIEND_LIST_SIZE_CHANGED = true }
    for _, event in ipairs({ "UI_SCALE_CHANGED", "DISPLAY_SIZE_CHANGED", "FRIENDLIST_UPDATE", "BN_FRIEND_INFO_CHANGED", "BN_FRIEND_LIST_SIZE_CHANGED" }) do
        call(frame.RegisterEvent, frame, event)
    end
    local friendsQueued = false
    frame:SetScript("OnEvent", function(_, event)
        if event == "UI_SCALE_CHANGED" or event == "DISPLAY_SIZE_CHANGED" then
            stopResize()
            setScale(frame:GetScale())
        end
        if FRIENDS_NEWS[event] and frame:IsShown() and not friendsQueued and C_Timer then
            friendsQueued = true
            C_Timer.After(0.3, function()
                friendsQueued = false
                if frame:IsShown() then refreshShown(TABS[state.tab] ~= "Friends") end
            end)
        end
    end)
    -- An item's page takes the tab's place over the window's body, and closes with the window. While
    -- it shows, Escape (or Back) steps back to the item opened before it from an item's page, then to
    -- the tab; once more, and the window closes (whichever is in UISpecialFrames is what Escape closes).
    local page = V.makeItemPage(frame.body)
    page:SetFrameLevel((frame.body:GetFrameLevel() or 1) + 20)
    local function escapeCloses(name)
        for i, n in ipairs(UISpecialFrames) do
            if n == "ReliquaryEscape" or n == "ReliquaryItemPage" then
                UISpecialFrames[i] = name
                return
            end
        end
        tinsert(UISpecialFrames, name)
    end
    page:HookScript("OnShow", function() escapeCloses("ReliquaryItemPage") end)
    page:HookScript("OnHide", function()
        local before = not page.closing and frame:IsShown() and table.remove(page.history)
        if before then
            page.item, page.link = before.item, before.link
            page:Show()
            page.redraw()
            return
        end
        page.history = {}
        escapeCloses("ReliquaryEscape")
        if panels[state.tab] then panels[state.tab]:Show() end
    end)
    -- All of it at once: the window closing, another tab, a person's page.
    function page.close()
        page.closing = true
        page:Hide()
        page.closing = false
        page.history = {}
    end
    frame:SetScript("OnHide", function()
        stopResize()
        frame.closing = false
        frame.quiet = true
        escape:Hide()
        frame.quiet = false
        page.close()
        sound("IG_CHARACTER_INFO_CLOSE")
        -- Nothing keeps moving behind a shut window, and it opens from its own place next time.
        Motion.finishAll()
        frame.canvas:SetAlpha(1)
        frame.canvas:SetScale(1)
    end)
    V.openItemPage = function(it, link)
        if page:IsShown() and page.item and page.item.id ~= it.id then
            page.history[#page.history + 1] = { item = page.item, link = page.link }
        end
        page.item, page.link = it, link
        if ns.rememberLink and link then ns.rememberLink(it.id, link) end
        if ns.askWhoCanUse then ns.askWhoCanUse(link) end
        -- Its price at the house you stand at, the guild's notes of where it comes from, the journal.
        if ns.checkPrice then ns.checkPrice(it.id) end
        if ns.askSources then ns.askSources(it.id) end
        if ns.checkJournal then pcall(ns.checkJournal, it.id) end
        -- The page slides in over the tab, which goes once the page lies over it.
        page:Show()
        page.redraw()
        page.cover(function() for _, p in ipairs(panels) do p:Hide() end end)
        sound("IG_MAINMENU_OPTION")
    end
    ns.itemPage = page
    ns.onFitsChanged = function() if page:IsVisible() then page.redraw() end end
    ns.onPricesChanged = function() if page:IsVisible() then page.redraw() end end
    local pageQueued = false
    local function redrawPage()
        if pageQueued or not page:IsVisible() or not C_Timer then return end
        pageQueued = true
        C_Timer.After(0.3, function() pageQueued = false if page:IsVisible() then page.redraw() end end)
    end
    -- Another tab closes the page.
    for i = 1, #TABS do frame.Tabs[i]:HookScript("OnClick", function() page.close() end) end
    -- What changed decides what draws again: another player's card or goodbye can't change your own
    -- characters, the guild bank or your sharing; a price shows only on an item's page.
    -- The guild's chat shows on the Guild tab only, whispers on another player's page.
    local UNCHANGED = { peers = { Characters = true, ["Guild Bank"] = true, Sharing = true }, prices = { all = true },
        chat = { Characters = true, ["Guild Bank"] = true, Friends = true, Public = true, Sharing = true },
        whisper = { Characters = true, ["Guild Bank"] = true, Sharing = true } }
    local queued, tabsQueued = false, false
    ns.onDataChanged = function(kind)
        redrawPage()
        if not frame:IsShown() or not C_Timer then return end
        local same = kind and UNCHANGED[kind]
        if same and (same.all or same[TABS[state.tab]]) then
            if tabsQueued or queued then return end
            tabsQueued = true
            C_Timer.After(0.3, function() tabsQueued = false if frame:IsShown() then refreshShown(true) end end)
            return
        end
        if queued then return end
        queued = true
        C_Timer.After(0.3, function() queued = false if frame:IsShown() then refreshShown() end end)
    end
    -- The character you play changed (a scan, the timeline's look): an item's page open over the window
    -- (what your characters hold of it) and the Characters tab (its page, its line in the list) follow.
    local ownQueued = false
    ns.onOwnChanged = function()
        redrawPage()
        if ownQueued or not frame:IsShown() or TABS[state.tab] ~= "Characters" or not C_Timer then return end
        ownQueued = true
        C_Timer.After(0.5, function()
            ownQueued = false
            if frame:IsShown() and TABS[state.tab] == "Characters" then panels[state.tab].refresh() end
        end)
    end
end

-- Opens or closes the window; returns whether it is now open (closing counts as closed).
ns.toggleViewer = function()
    if not ns.db then return nil end
    if not frame then build() end
    if frame:IsShown() and not frame.closing then
        V.close()
        return false
    end
    if frame.closing then
        -- Opened again while closing: it comes back from where it is.
        frame.closing = false
        Motion.fade(frame.canvas, 1, { dur = "slow", ease = "enter" })
        Motion.scale(frame.canvas, 1, { dur = "slow", ease = "enter" })
        return true
    end
    frame:Show()
    return frame:IsShown()
end

-- Opens the window on a tab, by its number or its name ("Sharing"), or on the one it was last on.
ns.showViewer = function(tab)
    if not ns.db then return nil end
    if not frame then build() end
    for i, name in ipairs(TABS) do
        if tab == i or tab == name then state.tab = i end
    end
    if frame.closing then ns.toggleViewer() end
    frame:Show()
    if frame:IsShown() then selectTab(state.tab, true) end
    return true
end
