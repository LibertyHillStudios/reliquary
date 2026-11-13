-- Reliquary's window: the Sharing tab (docs/DESIGN.md, section 5), and what each scope sees of this
-- character. Left, this character's three big choices as switches, each with its title and its line,
-- then the smaller switches that hold for every character; right, a card of what each of them sees,
-- part by part, then the item lines.
local ADDON, ns = ...

local V = ns.V
local Skin, Motion = ns.Skin, ns.Motion

local ipairs = ipairs
local floor, ceil, format = math.floor, math.ceil, string.format
local HEADER, sound, text, hideTip = V.HEADER, V.sound, V.text, V.hideTip
local SPACE = Skin.SPACE

-- What each scope sees of this character: a box for every part and scope. A scope that is off
-- keeps its choices, greyed, for when it is switched on. The Sharing tab draws it as Reliquary's
-- card; Options > AddOns > Reliquary > What others see draws it as the game's own options do.
local SCOPES = { { "guild", "g", "Guild" }, { "friends", "f", "Friends" }, { "public", "p", "Public" } }

-- A box of the grid: a click shows or hides its part to its scope, and its hover says which.
-- skinned: the window's own tick, whose look follows its clicks itself (its scripts are hooked).
local function gridBox(box, part, i, refresh, skinned)
    local sc = SCOPES[i]
    box.part, box.scope, box.label = part, sc[1], sc[3]
    local set = skinned and box.HookScript or box.SetScript
    set(box, "OnClick", function(self)
        sound(self:GetChecked() and "IG_MAINMENU_OPTION_CHECKBOX_ON" or "IG_MAINMENU_OPTION_CHECKBOX_OFF")
        ns.setPart(self.part, self.scope, self:GetChecked() and true or false)
        refresh()
    end)
    set(box, "OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        local shown = ns.partLetters(self.part):find(sc[2], 1, true)
        GameTooltip:SetText(format("%s: %s", ns.PART_NAMES[self.part], shown and ("shown to " .. self.label:lower()) or ("hidden from " .. self.label:lower())))
        if self.part == "profs" then GameTooltip:AddLine("Each profession's skill and every recipe it knows.", 1, 1, 1, true) end
        if not ns.shares()[self.scope] then GameTooltip:AddLine(format("%s sharing is off, so nobody sees it now.", self.label), 1, 1, 1, true) end
        GameTooltip:Show()
    end)
    set(box, "OnLeave", hideTip)
end

-- A switch or box set to what it should show; one that shows it already is left alone, so the knob a
-- click set sliding, or the tick it set popping in, isn't landed at once.
local function show(box, on)
    if (box:GetChecked() and true or false) ~= on then box:SetChecked(on) end
end

-- Each box ticked for what its scope sees; a scope that is off, and its column, greyed.
local function refreshGrid(m)
    local s = ns.shares()
    for i, sc in ipairs(SCOPES) do
        local on = s[sc[1]] == true
        if m.skinned then m.heads[sc[1]]:SetTextColor(Skin.rgb(on and "gold400" or "faint")) else m.heads[sc[1]]:SetAlpha(on and 1 or 0.45) end
    end
    for _, row in ipairs(m.rows) do
        local letters = ns.partLetters(row.part)
        for i, box in ipairs(row.boxes) do
            local on = s[SCOPES[i][1]] == true
            show(box, letters:find(SCOPES[i][2], 1, true) ~= nil)
            box:SetAlpha(on and 1 or 0.4)
        end
    end
end

-- The grid as Options > AddOns > Reliquary > What others see draws it, among other addons' options:
-- the game's own check boxes and fonts.
local function makeShareMatrix(parent)
    local m = CreateFrame("Frame", nil, parent)
    m:SetSize(400, 380)
    m:SetPoint("TOPLEFT", 16, -16)
    m.title = text(m, "GameFontNormalLarge")
    m.title:SetPoint("TOPLEFT", 0, 0)
    m.title:SetText("What each sees")
    m.hint = text(m, "GameFontDisableSmall")
    m.hint:SetPoint("TOPLEFT", m.title, "BOTTOMLEFT", 0, -4)
    m.hint:SetWidth(390)
    m.hint:SetText("Who the character is (name, race, class, level, guild) goes with any of them. Photos never leave your PC.")
    local x0, colW, rowH, top = 170, 72, 26, -60
    m.heads, m.rows = {}, {}
    function m.refresh() refreshGrid(m) end
    for i, sc in ipairs(SCOPES) do
        local h = text(m, "GameFontNormalSmall", "CENTER")
        h:SetWidth(colW)
        h:SetPoint("TOPLEFT", x0 + (i - 1) * colW, top)
        h:SetText(sc[3])
        m.heads[sc[1]] = h
    end
    for r, part in ipairs(ns.PARTS) do
        local y = top - 18 - (r - 1) * rowH
        local row = { part = part, boxes = {} }
        row.label = text(m, "GameFontHighlight")
        row.label:SetPoint("TOPLEFT", 0, y - 5)
        row.label:SetText(ns.PART_NAMES[part])
        for i = 1, #SCOPES do
            local box = CreateFrame("CheckButton", nil, m, "UICheckButtonTemplate")
            box:SetSize(24, 24)
            box:SetPoint("TOPLEFT", x0 + (i - 1) * colW + (colW - 24) / 2, y)
            gridBox(box, part, i, m.refresh, false)
            row.boxes[i] = box
        end
        m.rows[r] = row
    end
    return m
end
ns.makeShareMatrix = makeShareMatrix

---------------------------------------------------------------------------
-- The Sharing tab
---------------------------------------------------------------------------
-- In units: the left column's width (the right card takes the rest); a setting's switch and the room
-- between it and its words; the grid's rows and its scopes' columns; how far a hovered row's fill
-- reaches past its words.
local SHARING = { left = 440, switch = 32, row = 24, column = 72, reach = SPACE.s }
SHARING.right = V.WIDTH - 2 - 2 * SPACE.l - SHARING.left - SPACE.l

-- The settings that hold for every character, each on until turned off.
local EVERY_CHARACTER = { discover = true, autoPhoto = true, minimapButton = true, motion = true }

-- A setting: its title and its line (when it has one) at the left, its switch at the right; the whole
-- row takes the click and lights on hover. big: one of this character's three choices. row.fit()
-- sets its height from its words as the game lays them out, once they show, and returns it.
local function settingRow(parent, o, width, big)
    local row = CreateFrame("Frame", nil, parent)
    row:SetWidth(width)
    row.fill = Skin.nine(row, "disc", { radius = Skin.RADIUS.control, layer = "BACKGROUND", color = "ink800",
        inset = { -SHARING.reach, -SHARING.reach, -SHARING.reach, -SHARING.reach } })
    row.fill:SetAlpha(0)
    local words = width - SHARING.switch - SPACE.l
    local box = Skin.switch(row)
    box.key = o[1]
    box.Text = Skin.text(row, big and "heading" or "body")
    box.Text:SetPoint("TOPLEFT")
    box.Text:SetWidth(words)
    box.Text:SetText(o[2])
    local titleHeight = floor((box.Text:GetLineHeight() or 13) + 0.5)
    if o[3] then
        row.line = Skin.text(row, "small")
        row.line:SetTextColor(Skin.rgb(big and "muted" or "dim"))
        row.line:SetWordWrap(true)
        row.line:SetJustifyV("TOP")
        row.line:SetPoint("TOPLEFT", box.Text, "BOTTOMLEFT", 0, -SPACE.xs)
        row.line:SetWidth(words)
        row.line:SetText(o[3])
    end
    -- The switch level with the title, taking clicks across its whole row, which lights while the pointer
    -- is on it.
    local middle = floor(titleHeight / 2 + 0.5)
    box:SetPoint("RIGHT", row, "TOPRIGHT", 0, -middle)
    local half = box:GetHeight() / 2
    function row.fit()
        local h = titleHeight
        if row.line then
            local lines = ceil(Skin.textHeight(row.line))
            row.line:SetHeight(lines)
            h = h + SPACE.xs + lines
        end
        row:SetHeight(h)
        box:SetHitRectInsets(-(width - SHARING.switch + SHARING.reach), -SHARING.reach, -(SHARING.reach + middle - half), -(h - middle - half + SHARING.reach))
        return h
    end
    local function light(a) Motion.fade(row.fill, a, { dur = "fast", from = row.fill.alpha or 0, set = function(n, v) n:SetAlpha(v) end, owner = row }) end
    box:HookScript("OnEnter", function() light(1) end)
    box:HookScript("OnLeave", function() light(0) end)
    row.box = box
    return row
end

-- A card of settings, one under another with a pixel line between them; returns the card and its
-- switches. card.fit() lays them out once their words show.
local function settingsCard(parent, list, big)
    local card = Skin.card(parent)
    card:SetWidth(SHARING.left)
    local width = SHARING.left - 2 * SPACE.m
    local rows, rules, boxes = {}, {}, {}
    for i, o in ipairs(list) do
        if i > 1 then rules[i] = Skin.line(card.body, "ink600") end
        rows[i] = settingRow(card.body, o, width, big)
        boxes[i] = rows[i].box
    end
    function card.fit()
        local y = 0
        for i, row in ipairs(rows) do
            if rules[i] then
                rules[i]:ClearAllPoints()
                rules[i]:SetPoint("TOPLEFT", 0, y - SPACE.m)
                rules[i]:SetPoint("TOPRIGHT", 0, y - SPACE.m)
                y = y - 2 * SPACE.m - 1
            end
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", 0, y)
            y = y - row.fit()
        end
        card:SetHeight(2 * SPACE.m - y)
    end
    return card, boxes
end

local function buildSharing(panel)
    -- The tab's header over the body, as a rail's header has it: whose sharing this is.
    panel.head = Skin.text(panel, "title")
    panel.head:SetPoint("TOPLEFT", panel, "TOPLEFT", 16, HEADER - 14)
    panel.lead = Skin.text(panel, "small")
    panel.lead:SetPoint("LEFT", panel.head, "RIGHT", 12, -1)
    panel.lead:SetText("Each of your characters chooses for itself.")

    -- Left: this character's three switches, then the ones for every character.
    local mine, every
    mine, panel.boxes = settingsCard(panel, {
        { "guild", "Share with my guild", "Guildmates who use Reliquary, and the guild bank as you last saw it. Each keeps only the bank tabs their own rank may see." },
        { "friends", "Share with my friends", "Your friends list, and Battle.net friends playing WoW: Forever." },
        { "public", "Share with anyone", "Any player who uses Reliquary can ask, for example by targeting you." },
    }, true)
    mine:SetPoint("TOPLEFT", SPACE.l, -SPACE.s)
    local more
    every, more = settingsCard(panel, {
        { "discover", "Ask players I target", "Reliquary asks whether they share theirs with you. Players without Reliquary see nothing." },
        { "autoPhoto", "Take photos automatically", "New places, level-ups and a portrait while you rest." },
        { "minimapButton", "Show the minimap button", "Click it to open this window, drag it around the edge. Reliquary is in the minimap's Addons menu either way." },
        { "motion", "Animations" },
    }, false)
    every:SetPoint("TOPLEFT", mine, "BOTTOMLEFT", 0, -SPACE.l)
    for _, box in ipairs(more) do panel.boxes[#panel.boxes + 1] = box end
    panel.mine, panel.every = mine, every
    for _, box in ipairs(panel.boxes) do
        box:HookScript("OnClick", function(self)
            local on = self:GetChecked() and true or false
            sound(on and "IG_MAINMENU_OPTION_CHECKBOX_ON" or "IG_MAINMENU_OPTION_CHECKBOX_OFF")
            if EVERY_CHARACTER[self.key] then ns.db.settings[self.key] = on
            else ns.setShare(self.key, on) end
            if self.key == "minimapButton" and ns.updateMinimapButton then ns.updateMinimapButton() end
            -- Off, every movement lands where it is going at once; on, the window moves again.
            if self.key == "motion" then Motion.setEnabled(on) end
            panel.refresh()
        end)
        -- Turned on, the clock runs before the click is drawn, so this switch's own knob slides too.
        if box.key == "motion" then box:SetScript("PreClick", function() if not Motion.enabled() then Motion.setEnabled(true) end end) end
    end

    -- Right: what each sees, part by part (a scope that is off keeps its choices, greyed), then the item
    -- lines: Reliquary's line on the game's item tooltips, its line when you log in, its line when you
    -- loot something someone else can use, and sharing prices. What each says is on hover.
    local card = Skin.card(panel, "What each sees")
    card:SetPoint("TOPLEFT", mine, "TOPRIGHT", SPACE.l, 0)
    card:SetWidth(SHARING.right)
    panel.matrix = card
    local width = SHARING.right - 2 * SPACE.m
    local m = { skinned = true, heads = {}, rows = {} }
    function m.refresh() refreshGrid(m) end
    card.refresh = m.refresh
    card.hint = Skin.text(card.body, "small")
    card.hint:SetTextColor(Skin.rgb("dim"))
    card.hint:SetWordWrap(true)
    card.hint:SetJustifyV("TOP")
    card.hint:SetPoint("TOPLEFT")
    card.hint:SetWidth(width)
    card.hint:SetText("Who the character is (name, race, class, level, guild) goes with any of them. Photos never leave your PC.")
    -- The grid and the item lines under the hint, however many lines it takes.
    local grid = CreateFrame("Frame", nil, card.body)
    grid:SetPoint("TOPLEFT", card.hint, "BOTTOMLEFT", 0, -SPACE.l)
    grid:SetWidth(width)
    card.grid = grid
    local y = 0
    local x0 = width - #SCOPES * SHARING.column
    for i, sc in ipairs(SCOPES) do
        local h = Skin.text(grid, "label", "CENTER")
        h:SetWidth(SHARING.column)
        h:SetPoint("TOP", grid, "TOPLEFT", x0 + (i - 0.5) * SHARING.column, y)
        Skin.label(h, sc[3])
        m.heads[sc[1]] = h
    end
    y = y - SPACE.l
    for r, part in ipairs(ns.PARTS) do
        local row = { part = part, boxes = {} }
        local middle = y - SHARING.row / 2
        row.label = Skin.text(grid, "body")
        row.label:SetPoint("LEFT", grid, "TOPLEFT", 0, middle)
        row.label:SetPoint("RIGHT", grid, "TOPLEFT", x0 - SPACE.s, middle)
        row.label:SetText(ns.PART_NAMES[part])
        for i = 1, #SCOPES do
            local box = Skin.check(grid)
            box:SetPoint("CENTER", grid, "TOPLEFT", x0 + (i - 0.5) * SHARING.column, middle)
            gridBox(box, part, i, m.refresh, true)
            row.boxes[i] = box
        end
        m.rows[r] = row
        y = y - SHARING.row
    end
    -- The item lines, under their label and a line to the card's edge.
    y = y - SPACE.m
    card.items = Skin.text(grid, "label")
    card.items:SetPoint("TOPLEFT", 0, y)
    Skin.label(card.items, "Items")
    card.itemsRule = Skin.line(grid, "ink600")
    card.itemsRule:SetPoint("LEFT", card.items, "RIGHT", SPACE.s, 0)
    card.itemsRule:SetPoint("RIGHT", grid, "RIGHT")
    y = y - (Skin.CARD_HEAD - SPACE.s)
    panel.itemBoxes = {}
    for _, o in ipairs({
        { "tipLine", "Lines on item tooltips", "Under an item: its auction price, who in the guild it's set aside for or would be an upgrade for, who in your guild, among your friends and your characters can make it, uses it in a recipe or could learn it, and who else has it." },
        { "headsUp", "Gear news when I log in", "At most one line: gear set aside for you, and new upgrades for you in the guild bank." },
        { "craftNews", "Who can use what I loot", "A line in chat when you loot something no profession of yours uses but a guildmate's, a friend's or another of your characters' recipes do. Once a day for each item." },
        { "sharePrices", "Share prices and sources", "Your auction scans and your notes of where items come from go to guildmates who use Reliquary. Theirs come to you either way, and Blizzard's own prices pass through the guild either way.", true },
    }) do
        local middle = y - SHARING.row / 2
        local box = Skin.check(grid)
        box:SetPoint("LEFT", grid, "TOPLEFT", 0, middle)
        box.Text = Skin.text(grid, "body")
        box.Text:SetPoint("LEFT", box, "RIGHT", SPACE.s, 0)
        box.Text:SetText(o[2])
        -- Its words take the click too, as a check box's label does.
        box:SetHitRectInsets(0, -(SPACE.s + floor((box.Text:GetStringWidth() or 0) + 0.5)), 0, 0)
        box.key, box.tip, box.optIn = o[1], o[3], o[4]
        box:HookScript("OnClick", function(self)
            sound(self:GetChecked() and "IG_MAINMENU_OPTION_CHECKBOX_ON" or "IG_MAINMENU_OPTION_CHECKBOX_OFF")
            ns.db.settings[self.key] = self:GetChecked() and true or false
            if self.key == "sharePrices" and not self:GetChecked() then ns.purgeQueued() end -- what waited to go out stays home
        end)
        box:HookScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(self.Text:GetText())
            GameTooltip:AddLine(self.tip, 1, 1, 1, true)
            GameTooltip:Show()
        end)
        box:HookScript("OnLeave", hideTip)
        panel.itemBoxes[#panel.itemBoxes + 1] = box
        y = y - SHARING.row
    end
    grid:SetHeight(-y)
    -- Its height, from the hint's lines as the game lays them out, once they show.
    function card.fit()
        local hint = ceil(Skin.textHeight(card.hint))
        card.hint:SetHeight(hint)
        card:SetHeight(Skin.CARD_HEAD + SPACE.s + hint + SPACE.l + grid:GetHeight() + SPACE.m)
    end

    -- Under the switches: messages waiting to go out, or why sharing can't.
    panel.status = Skin.text(panel, "small")
    panel.status:SetTextColor(Skin.rgb("dim"))
    panel.status:SetWordWrap(true)
    panel.status:SetPoint("TOPLEFT", every, "BOTTOMLEFT", SPACE.xs, -SPACE.m)
    panel.status:SetWidth(SHARING.left - 2 * SPACE.xs)

    -- The game cannot open a mail app, so keep the studio's address ready to copy.
    local contact = CreateFrame("Frame", nil, panel)
    contact:SetPoint("BOTTOMLEFT", SPACE.l, SPACE.l)
    contact:SetSize(SHARING.left, 48)
    contact.title = Skin.text(contact, "heading")
    contact.title:SetPoint("TOPLEFT")
    contact.title:SetText("Suggestions?")
    contact.email = Skin.field(contact)
    contact.email:SetPoint("BOTTOMLEFT")
    contact.email:SetPoint("RIGHT")
    local address = "suggestions@libertyhillstudio.com"
    contact.email:SetText(address)
    contact.email:HookScript("OnEditFocusGained", function(self) self:HighlightText() end)
    contact.email:SetScript("OnTextChanged", function(self, user)
        if user then self:SetText(address) self:HighlightText() end
    end)
    contact.email:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    contact.email:HookScript("OnHide", function(self) self:ClearFocus() end)
    contact.email:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        local copyKey = (type(IsMacClient) == "function" and IsMacClient()) and "Cmd+C" or "Ctrl+C"
        GameTooltip:SetText("Click the address, then " .. copyKey .. " to copy.")
        GameTooltip:Show()
    end)
    contact.email:HookScript("OnLeave", hideTip)
    panel.contact = contact
    function panel.refresh()
        mine.fit()
        every.fit()
        card.fit()
        local s = ns.shares()
        panel.head:SetText(format("Who sees %s", ns.char and ns.char.name or "this character"))
        for _, box in ipairs(panel.boxes) do
            if EVERY_CHARACTER[box.key] then show(box, ns.db.settings[box.key] ~= false)
            else show(box, s[box.key] == true) end
        end
        m.refresh()
        for _, box in ipairs(panel.itemBoxes) do
            if box.optIn then show(box, ns.db.settings[box.key] == true) else show(box, ns.db.settings[box.key] ~= false) end
        end
        local waiting = ns.queued()
        panel.status:SetText(ns.canShare() and (waiting > 0 and format("%d messages waiting to go out: they leave about one a second, and wait out fights and instances.", waiting) or "")
            or "This game client can't pack messages for other players, so sharing waits.")
        panel.status:SetShown((panel.status:GetText() or "") ~= "")
    end
end

V.buildSharing = buildSharing
