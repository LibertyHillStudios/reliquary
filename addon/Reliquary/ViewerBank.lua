-- Reliquary's window: the Guild Bank tab (docs/DESIGN.md, section 5). The tab's name over its body, as a
-- rail's header has it; the bank's tabs as icon buttons down the right, the chosen one ringed in gold;
-- Items, Log and Gold log as text tabs over one card of the tab's slots (or its log); under the slots
-- the tab's latest moves as a card; along the foot the bank's gold as a chip, the tab's note and what
-- your rank may take. The guild master also gets the Sharing settings: who sees each tab in Reliquary.
local ADDON, ns = ...

local V = ns.V
local Skin, Motion = ns.Skin, ns.Motion

local call, num, str, api = ns.call, ns.num, ns.str, ns.api
local pairs, ipairs, type, tostring = pairs, ipairs, type, tostring
local floor, min, max, format = math.floor, math.min, math.max, string.format
local WHITE, GREY, GREEN, BLUE, RED = ns.WHITE, ns.GREY, ns.GREEN, ns.BLUE, ns.RED
local HEADER, WIDTH, BODY_HEIGHT, state, sound, ago, money, hideTip, showTip = V.HEADER, V.WIDTH, V.BODY_HEIGHT, V.state, V.sound, V.ago, V.money, V.hideTip, V.showTip
local itemButton, helps, showItem, myGuild = V.itemButton, V.helps, V.showItem, V.myGuild

-- Where things are, in units down from the top of the tab's body (the panel starts HEADER below it)
-- and in from its sides: the title and the line under it as a rail's header has them, the row of
-- Items, Log and Gold log, then the cards. The slots are 98, in seven pairs of columns as at the bank
-- itself, 40 square and 4 apart, the pairs spread across their card; the bank's tabs are 40 square,
-- 8 apart, down the right. Under the slots, the tab's latest five moves.
local BANK = { side = 16, title = 16, row = 56, cards = 88, gutter = 12, foot = 20, slot = 40, gap = 4, columns = 7, rows = 7,
    tab = 40, tabGap = 8, latest = 5, line = 16, logLine = 20, search = 200 }
BANK.width = WIDTH - 2
BANK.cardWidth = BANK.width - 2 * BANK.side - BANK.tab - BANK.gutter
BANK.slotsHeight = 2 * Skin.SPACE.m + BANK.rows * (BANK.slot + BANK.gap) - BANK.gap
BANK.bottom = BODY_HEIGHT - Skin.SPACE.m - BANK.foot - BANK.gutter -- where the cards end, at the latest
-- Each pair's room, and the room between pairs that spreads them across the card.
BANK.pair = 2 * BANK.slot + BANK.gap
BANK.between = (BANK.cardWidth - 2 * Skin.SPACE.m - BANK.columns * BANK.pair) / (BANK.columns - 1)

-- A place down from the top of the tab's body, as an offset from the panel's top.
local function down(y) return HEADER - y end

local LOG_WORDS = { deposit = "put in", withdraw = "took", move = "moved", repair = "repaired with", withdrawForTab = "bought a tab with",
    buyTab = "bought a tab for", depositSummary = "put in" }
local LOG_COLOR = { deposit = GREEN, withdraw = RED, move = BLUE, repair = RED, withdrawForTab = RED, buyTab = RED, depositSummary = GREEN }

local function qualityColored(text, q)
    local c = q and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q]
    if c and c.hex then return c.hex .. text .. "|r" end
    return text
end

-- One line of a tab's log (or the gold log), newest first.
local function logLines(log, tabs, gold)
    local out = {}
    local list = type(log) == "table" and type(log.list) == "table" and log.list or {}
    for k = #list, 1, -1 do
        local e = list[k]
        local who = WHITE .. (e.w or "Someone") .. "|r"
        local verb = (LOG_COLOR[e.k] or GREY) .. (LOG_WORDS[e.k] or e.k) .. "|r"
        local line
        if gold then
            line = format("%s %s %s", who, verb, money(e.m))
        else
            local what = qualityColored("[" .. (e.nm or ("item " .. tostring(e.id or "?"))) .. "]", e.q)
            line = format("%s %s %s%s", who, verb, (e.n and e.n > 1) and (e.n .. " ") or "", what)
            if e.k == "move" and e.t2 then
                local to = type(tabs[e.t2]) == "table" and tabs[e.t2].name or ("tab " .. e.t2)
                line = line .. " to " .. to
            end
        end
        out[#out + 1] = { line, ago(e.at) }
    end
    return out
end

-- The names of the guild's ranks, from the guild master's settings or the guild list.
local function rankNames(g)
    local names = {}
    local p = ns.bankPolicy(g)
    for r, n in pairs(p and type(p.nm) == "table" and p.nm or {}) do names[r] = n end
    for r, n in pairs(type(g.rules) == "table" and type(g.rules.names) == "table" and g.rules.names or {}) do names[r] = names[r] or n end
    for _, m in ipairs(type(g.members) == "table" and g.members or {}) do
        if type(m) == "table" and num(m.ro) and m.rank then names[m.ro] = names[m.ro] or m.rank end
    end
    return names
end

-- What a choice for a tab says, as the settings and the bank's own page put it.
local function audienceText(a, names)
    if a == "a" then return "Everyone" end
    if a == "n" then return "Game only" end
    if type(a) == "number" then return format("%s and up", names[a] or ("Rank " .. a)) end
    return "As in game"
end

-- Who may send the bank's records, as the settings put it.
local function keeperText(r, names)
    return r == 1 and "The guild master only" or format("%s and up", names[r] or ("Rank " .. r))
end

-- The lowest rank the game lets view a tab, from the guild master's copy of each rank's permissions.
local function gameRank(view, i)
    local low
    for r, row in pairs(type(view) == "table" and view or {}) do
        if type(row) == "string" and row:sub(i, i) == "1" and (not low or r > low) then low = r end
    end
    return low
end

-- The guild bank's tabs this character may see in Reliquary, and why the Guild Bank tab has nothing to
-- show (nil when it has something): the settings page counts as something for the guild master.
local function bankTabs(g)
    local b = g and type(g.bank) == "table" and g.bank or nil
    local tabs = b and type(b.tabs) == "table" and b.tabs or {}
    local viewable = {}
    for i = 1, 8 do
        if type(tabs[i]) == "table" and (tabs[i].slots or tabs[i].name) and ns.maySeeTab(g, i) then viewable[#viewable + 1] = i end
    end
    return viewable, b, tabs
end
local function bankEmpty(viewable, settings)
    if not ns.guildKey() then return "This character isn't in a guild." end
    if api("C_GuildBank.IsGuildBankEnabled") and call(api("C_GuildBank.IsGuildBankEnabled")) == false then return "Guild banks aren't open in this game." end
    if #viewable == 0 and not settings then
        return "Open the guild bank once on this character. The tabs your rank may see then show here, as you or your guildmates last saw them."
    end
end

-- A line of words that may run longer than its room: cut, and whole on hover.
local function hoverWhole(parent, fs, title)
    local hover = CreateFrame("Frame", nil, parent)
    hover:SetAllPoints(fs)
    hover:EnableMouse(true)
    hover:SetScript("OnEnter", function(self)
        local whole = fs.whole or fs:GetText()
        if (fs.whole and fs.whole ~= "") or fs:IsTruncated() then showTip(self, title and title() or whole, title and { whole } or nil) end
    end)
    hover:SetScript("OnLeave", hideTip)
    return hover
end

-- A small box with its words beside it; a click on the words ticks it too, as on the game's own.
local function labelledCheck(parent, words, role)
    local box = Skin.check(parent)
    box.label = Skin.text(box, role or "body")
    box.label:SetPoint("LEFT", box, "RIGHT", Skin.SPACE.s, 0)
    box.label:SetText(words)
    box.width = 16 + Skin.SPACE.s + floor((box.label:GetStringWidth() or 0) + 0.5)
    box:SetHitRectInsets(0, -(box.width - 16), -Skin.SPACE.xs, -Skin.SPACE.xs)
    return box
end

local function buildBank(panel)
    -- The header: the tab's name (title) and, under it, when it was seen or its log read, each cut and
    -- whole on hover when long. The guild master's Sharing button at its right.
    panel.tabName = Skin.text(panel, "title")
    panel.tabName:SetPoint("TOPLEFT", BANK.side, down(BANK.title))
    panel.seen = Skin.text(panel, "small")
    panel.seen:SetPoint("TOPLEFT", panel.tabName, "BOTTOMLEFT", 0, -5)
    panel.tabNameHover = hoverWhole(panel, panel.tabName)
    panel.seenHover = hoverWhole(panel, panel.seen)
    panel.sharing = Skin.button(panel, "quiet")
    panel.sharing:SetText("Sharing")
    panel.sharing:SetPoint("TOPRIGHT", -BANK.side, down(BANK.title + 4))
    for _, line in ipairs({ panel.tabName, panel.seen }) do line:SetPoint("RIGHT", panel.sharing, "LEFT", -BANK.gutter, 0) end
    panel.sharing:SetScript("OnClick", function() state.bankSettings = not state.bankSettings sound("IG_MAINMENU_OPTION") panel.refresh() end)

    -- Items, Log and Gold log: text tabs with the gold marker, as a player's pages have them.
    panel.views = Skin.tabs(panel, "page")
    for _, v in ipairs({ { "items", "Items" }, { "log", "Log" }, { "gold", "Gold log" } }) do panel.views:Add(v[1], v[2]) end
    panel.views.onSelect = function(key)
        if state.bankView ~= key then sound("IG_CHARACTER_INFO_TAB") end
        state.bankView = key
        panel.refresh()
    end

    -- Over the slots at their right: the search (what doesn't match is darkened, as the game's bags do
    -- it) and the filter for what would be an upgrade for someone in the guild (the items the upgrade
    -- arrow marks).
    local right = BANK.side + BANK.tab + BANK.gutter
    panel.search = Skin.search(panel)
    panel.search:SetWidth(BANK.search)
    panel.search:SetPoint("TOPRIGHT", -right, down(BANK.row + 3))
    panel.search.onChange = function(text)
        state.bankQuery = text
        panel.refresh()
    end
    panel.helps = labelledCheck(panel, "Helps someone", "small")
    panel.helps:SetPoint("RIGHT", panel.search, "LEFT", -(BANK.gutter + 4 + panel.helps.width - 16), 0)
    panel.helps:HookScript("OnClick", function(self)
        state.bankHelps = self:GetChecked() and true or false
        sound(state.bankHelps and "IG_MAINMENU_OPTION_CHECKBOX_ON" or "IG_MAINMENU_OPTION_CHECKBOX_OFF")
        panel.refresh()
    end)
    panel.helps:HookScript("OnEnter", function(self) showTip(self, "Only what would be an upgrade for someone in the guild") end)
    panel.helps:HookScript("OnLeave", hideTip)

    -- The slots: one card of wells, seven pairs of columns of seven, numbered down each column as at the
    -- bank. Each row of them is a frame of its own, so the rows can arrive one after another.
    panel.grid = Skin.card(panel)
    panel.grid:SetPoint("TOPLEFT", BANK.side, down(BANK.cards))
    panel.grid:SetSize(BANK.cardWidth, BANK.slotsHeight)
    panel.slots, panel.slotRows = {}, {}
    for row = 1, BANK.rows do
        local r = CreateFrame("Frame", nil, panel.grid.body)
        r:SetPoint("TOPLEFT", 0, -(row - 1) * (BANK.slot + BANK.gap))
        r:SetPoint("RIGHT")
        r:SetHeight(BANK.slot)
        panel.slotRows[row] = r
    end
    for column = 0, BANK.columns - 1 do
        for index = 0, 13 do
            local row, side = index % 7, index >= 7 and 1 or 0
            local b = itemButton(panel.slotRows[row + 1], BANK.slot)
            b:SetPoint("TOPLEFT", floor(column * (BANK.pair + BANK.between) + side * (BANK.slot + BANK.gap) + 0.5), 0)
            panel.slots[column * 14 + index + 1] = b
        end
    end

    -- Under the slots, the tab's latest moves from its log, newest first, when someone read it.
    panel.latest = Skin.card(panel, "Log")
    panel.latest:SetPoint("TOPLEFT", BANK.side, down(BANK.cards + BANK.slotsHeight + BANK.gutter))
    panel.latest:SetWidth(BANK.cardWidth)
    panel.latest.read = Skin.text(panel.latest, "small", "RIGHT")
    panel.latest.read:SetPoint("TOPRIGHT", -Skin.SPACE.m, -10)
    panel.latest.label:SetPoint("RIGHT", panel.latest.read, "LEFT", -Skin.SPACE.m, 0)
    panel.latest.lines = {}
    for i = 1, BANK.latest do
        local left, right = Skin.text(panel.latest.body, "small"), Skin.text(panel.latest.body, "dim", "RIGHT")
        left:SetTextColor(Skin.rgb("parchment"))
        left:SetPoint("TOPLEFT", 0, -(i - 1) * BANK.line)
        right:SetPoint("TOPRIGHT", 0, -(i - 1) * BANK.line)
        left:SetPoint("RIGHT", right, "LEFT", -Skin.SPACE.m, 0)
        panel.latest.lines[i] = { left = left, right = right }
    end

    -- A tab's log, or the gold log: a card of lines, newest first, as tall as they are, scrolling when
    -- they run past the foot.
    panel.logCard = Skin.card(panel)
    panel.logCard:SetPoint("TOPLEFT", BANK.side, down(BANK.cards))
    panel.logCard:SetWidth(BANK.cardWidth)
    panel.log, panel.logBar = Skin.scroll(panel.logCard, { left = Skin.SPACE.m, top = -Skin.SPACE.s, right = Skin.SPACE.m, bottom = Skin.SPACE.s,
        fade = Skin.SPACE.xl, extent = function() return BANK.logLine end,
        init = function(row, line)
            if not row.left then
                row.left = Skin.text(row, "body")
                row.left:SetPoint("LEFT", 0, 0)
                row.right = Skin.text(row, "dim", "RIGHT")
                row.right:SetPoint("RIGHT", -Skin.SPACE.xs, 0)
                row.left:SetPoint("RIGHT", row.right, "LEFT", -Skin.SPACE.m, 0)
            end
            row.left:SetText(line[1])
            row.right:SetText(line[2] or "")
        end })

    -- Along the foot, as wide as the cards over it (the window's grip has the corner): the bank's gold,
    -- the tab's note (one line, its line breaks as spaces, the whole of it on hover) and what your rank
    -- may take.
    panel.foot = CreateFrame("Frame", nil, panel)
    panel.foot:SetPoint("BOTTOMLEFT", BANK.side, Skin.SPACE.m)
    panel.foot:SetPoint("BOTTOMRIGHT", -(BANK.side + BANK.tab + BANK.gutter), Skin.SPACE.m)
    panel.foot:SetHeight(BANK.foot)
    panel.money = Skin.chip(panel.foot)
    panel.money:SetPoint("LEFT")
    panel.limits = Skin.text(panel.foot, "small", "RIGHT")
    panel.limits:SetPoint("RIGHT")
    panel.note = Skin.text(panel.foot, "small")
    panel.note:SetTextColor(Skin.rgb("dim"))
    panel.note:SetPoint("RIGHT", panel.limits, "LEFT", -(BANK.gutter + 4), 0)
    panel.noteHover = hoverWhole(panel.foot, panel.note, function() return panel.tabName:GetText() or "Guild bank" end)

    -- The bank's own tabs: each tab's icon, the chosen one ringed in gold.
    panel.tabs = {}
    for i = 1, 8 do
        local t = Skin.iconTab(panel, BANK.tab)
        t:SetPoint("TOPRIGHT", -BANK.side, down(BANK.cards) - (i - 1) * (BANK.tab + BANK.tabGap))
        t:HookScript("OnClick", function(self)
            if state.bankTab ~= self.index then sound("IG_MAINMENU_OPTION_CHECKBOX_ON") end
            state.bankTab = self.index
            panel.refresh()
        end)
        t:HookScript("OnEnter", function(self)
            if not self.tabName then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(self.tabName)
            if self.wider then GameTooltip:AddLine(self.wider, 1, 1, 1, true) end
            GameTooltip:Show()
        end)
        t:HookScript("OnLeave", hideTip)
        panel.tabs[i] = t
    end

    panel.empty = Skin.text(panel, "body", "CENTER")
    panel.empty:SetTextColor(Skin.rgb("dim"))
    panel.empty:SetWordWrap(true)
    panel.empty:SetPoint("TOPLEFT", 48, down(120))
    panel.empty:SetPoint("RIGHT", -48, 0)
    panel.empty:SetSpacing(5)

    -- The guild master's settings: who sees each tab in Reliquary, and the bank's records. One card, as
    -- tall as what it holds: a row for each tab (its icon, its name, who sees it in the game, and the
    -- choice), a line, then the records and when the settings were set.
    local st = Skin.card(panel, "Who sees each tab in Reliquary")
    panel.settings = st
    st:SetPoint("TOPLEFT", BANK.side, down(BANK.row))
    st:SetWidth(BANK.cardWidth)
    st.lead = Skin.text(st.body, "small")
    st.lead:SetTextColor(Skin.rgb("dim"))
    st.lead:SetPoint("TOPLEFT")
    st.lead:SetPoint("RIGHT")
    st.lead:SetText("Only you, the guild master, can change these. Guildmates who use Reliquary follow them.")
    st.rows = {}
    for i = 1, 8 do
        local row = CreateFrame("Frame", nil, st.body)
        row:SetHeight(Skin.ROW)
        row:SetPoint("TOPLEFT", 0, -(24 + (i - 1) * Skin.ROW))
        row:SetPoint("RIGHT")
        row.rule = Skin.line(row, "ink600")
        row.rule:SetPoint("TOPLEFT")
        row.rule:SetPoint("TOPRIGHT")
        row.icon = Skin.framedIcon(row, 24)
        row.icon:SetPoint("LEFT", 0, 0)
        row.pick = Skin.dropdown(row)
        row.pick:SetWidth(BANK.search + 20)
        row.pick:SetPoint("RIGHT", 0, 0)
        row.name = Skin.text(row, "heading")
        row.name:SetPoint("TOPLEFT", 34, -7)
        row.name:SetPoint("RIGHT", row.pick, "LEFT", -Skin.SPACE.l, 0)
        row.game = Skin.text(row, "small")
        row.game:SetTextColor(Skin.rgb("dim"))
        row.game:SetPoint("TOPLEFT", 34, -23)
        row.game:SetPoint("RIGHT", row.pick, "LEFT", -Skin.SPACE.l, 0)
        row.index = i
        st.rows[i] = row
    end
    st.recordsRule = Skin.line(st.body, "ink600")
    st.records = labelledCheck(st.body, "Share logs, notes and limits")
    st.records:HookScript("OnClick", function(self)
        sound(self:GetChecked() and "IG_MAINMENU_OPTION_CHECKBOX_ON" or "IG_MAINMENU_OPTION_CHECKBOX_OFF")
        ns.setBankPolicy({ rec = self:GetChecked() and true or false })
        panel.refresh()
    end)
    st.recordsNote = Skin.text(st.body, "small")
    st.recordsNote:SetTextColor(Skin.rgb("dim"))
    st.recordsNote:SetText("Each goes to whoever sees its tab. Sent only by:")
    st.keep = Skin.dropdown(st.body)
    st.keep:SetWidth(BANK.search + 20)
    st.keep:SetPoint("LEFT", st.recordsNote, "RIGHT", Skin.SPACE.m, 0)
    st.foot = Skin.text(st.body, "small")
    st.foot:SetTextColor(Skin.rgb("dim"))

    -- The settings for each tab, from the game's rank permissions as the guild master's game read them.
    local function refreshSettings(g, b, tabs)
        local p = ns.bankPolicy(g)
        local mine = p and p.by == ns.me() and p or nil
        local names = rankNames(g)
        local rules = type(g.rules) == "table" and g.rules or nil
        local n = rules and num(rules.n) or 0
        local count = num(b and b.count) or 0
        local shown = 0
        for i, row in ipairs(st.rows) do
            local t = tabs[i]
            local show = i <= count
            row:SetShown(show)
            if show then
                shown = i
                row.rule:SetShown(i > 1)
                row.icon:SetIcon(type(t) == "table" and t.icon or 134400)
                row.name:SetText(type(t) == "table" and t.name or ("Tab " .. i))
                local low = rules and gameRank(rules.view, i)
                row.game:SetText(low and (low >= n and "In game: everyone" or format("In game: %s and up", names[low] or ("rank " .. low))) or "In game: as the bank shows each rank")
                local cur = mine and mine.tb and mine.tb[i] or "g"
                row.pick:SetText(audienceText(cur, names))
                row.pick:SetupMenu(function(_, root)
                    local function choice(label, value)
                        root:CreateRadio(label, function() return cur == value end, function()
                            ns.setBankPolicy({ tab = i, aud = value })
                            panel.refresh()
                        end, value)
                    end
                    choice("As in game", "g")
                    -- Only choices wider than the game's: a tab is never narrowed except to the game alone.
                    for r = (low or 1) + 1, n - 1 do choice(format("%s and up", names[r] or ("Rank " .. r)), r) end
                    if not (low and low >= n) then choice("Everyone", "a") end
                    choice("Game only", "n")
                end)
            end
        end
        -- Down the card from the rows: the line, the records, who may send them (once they're shared),
        -- when the settings were set; the card ends under that.
        local y = 24 + shown * Skin.ROW
        st.recordsRule:SetPoint("TOPLEFT", 0, -y)
        st.recordsRule:SetPoint("TOPRIGHT", 0, -y)
        y = y + Skin.SPACE.l
        st.records:ClearAllPoints()
        st.records:SetPoint("TOPLEFT", 0, -y)
        y = y + 16
        st.records:SetChecked(mine and mine.rc == true or false)
        local shared = st.records:GetChecked() and true or false
        if shared then
            y = y + Skin.SPACE.s
            st.recordsNote:SetPoint("LEFT", st.body, "TOPLEFT", 24, -(y + 12))
            y = y + 24
        end
        y = y + Skin.SPACE.l
        st.foot:SetPoint("TOPLEFT", 0, -y)
        st.foot:SetPoint("RIGHT")
        st:SetHeight(Skin.CARD_HEAD + Skin.SPACE.s + y + floor((st.foot:GetLineHeight() or 11) + 0.5) + Skin.SPACE.m)
        local keep = mine and mine.kp or 2
        st.keep:SetText(keeperText(keep, names))
        st.keep:SetupMenu(function(_, root)
            for r = 1, max(1, n - 1) do
                root:CreateRadio(keeperText(r, names), function() return keep == r end, function() ns.setBankPolicy({ keep = r }) panel.refresh() end, r)
            end
        end)
        st.keep:SetShown(shared)
        st.recordsNote:SetShown(shared)
        st.foot:SetText(mine and format("Set %s. Guildmates who use Reliquary have them the next time you're both online.", ago(mine.at))
            or (rules and "Nothing set yet: every tab is as in game." or "Open the guild bank once: Reliquary reads each rank's permissions there."))
    end

    -- What this character's rank may take today, from the guild master's settings or the bank itself.
    local function limitsText(g, b, i)
        local p = ns.bankPolicy(g)
        local ro = ns.myRank()
        local lm = p and p.rc and type(p.lm) == "table" and ro and p.lm[ro]
        local own = type(b.limits) == "table" and b.limits[ns.charKey]
        local perDay = lm and type(lm.w) == "table" and lm.w[i] or (type(own) == "table" and type(own.tabs) == "table" and own.tabs[i] and own.tabs[i].w)
        local gold = lm and lm.g or nil
        local bits = {}
        if perDay and perDay > 0 then bits[#bits + 1] = format("%d %s a day from this tab", perDay, perDay == 1 and "stack" or "stacks")
        elseif perDay == -1 then bits[#bits + 1] = "as many stacks as you like from this tab" end
        if gold and gold > 0 then bits[#bits + 1] = format("%dg a day from the bank", gold) elseif gold == -1 then bits[#bits + 1] = "any gold from the bank" end
        if #bits == 0 then return "" end
        return "Your rank may take " .. table.concat(bits, ", and ") .. "."
    end

    -- What changed since the tab was last drawn, for how it moves: the window opening (everything
    -- arrives in order), another of the bank's tabs (its slots arrive row by row), another view or the
    -- settings (the new card arrives from the side its tab lies on).
    local VIEW_ORDER = { items = 1, log = 2, gold = 3, settings = 4 }
    panel:HookScript("OnHide", function() panel.drawn = nil end)
    local function arrive(mode, current, cards)
        local was = panel.drawn
        panel.drawn = { mode = mode, tab = current }
        if V.entrance then
            local n = 0
            for _, t in ipairs(panel.tabs) do
                if t:IsShown() then n = n + 1 Motion.arrive(t, n, { delay = Motion.ROWS_AFTER }) end
            end
            n = 0
            for _, line in ipairs({ panel.tabName, panel.seen }) do
                if (line:GetText() or "") ~= "" then n = n + 1 Motion.arrive(line, n, { delay = Motion.HERO_AFTER }) end
            end
            n = 0
            for _, c in ipairs(cards) do
                if c:IsShown() then n = n + 1 Motion.arrive(c, n, { delay = Motion.PAGE_AFTER }) end
            end
            Motion.arrive(panel.foot, n + 1, { delay = Motion.PAGE_AFTER })
        elseif was and was.mode ~= mode then
            for _, c in ipairs(cards) do
                if c:IsShown() then
                    Motion.fade(c, 1, { from = 0, dur = "base", ease = "enter" })
                    Motion.slide(c, ((VIEW_ORDER[mode] or 1) > (VIEW_ORDER[was.mode] or 1) and 1 or -1) * Motion.SLIDE_PAGE, 0, { dur = "base", ease = "enter" })
                end
            end
        elseif was and was.tab ~= current and mode == "items" then
            for i, r in ipairs(panel.slotRows) do Motion.arrive(r, i) end
            if panel.latest:IsShown() then Motion.arrive(panel.latest, #panel.slotRows + 1) end
        end
    end

    function panel.refresh()
        local g = myGuild()
        local viewable, b, tabs = bankTabs(g)
        local leader = g and ns.isGuildLeader() or false
        local settings = leader and state.bankSettings and true or false
        panel.sharing:SetShown(leader)
        panel.settings:SetShown(settings)
        local message = bankEmpty(viewable, settings)
        local view = state.bankView or "items"
        local goldLog = b and type(b.logs) == "table" and b.logs[ns.GOLD_LOG]
        if view == "gold" and not goldLog then view = "items" end
        local current = state.bankTab
        local okTab = false
        for _, i in ipairs(viewable) do if i == current then okTab = true end end
        if not okTab then current = viewable[1] state.bankTab = current end
        local log = current and b and type(b.logs) == "table" and b.logs[current]
        if view == "log" and not log then view = "items" end
        local main = not message and not settings
        local items = main and view == "items"
        panel.grid:SetShown(items)
        panel.search:SetShown(items)
        panel.logCard:SetShown(main and view ~= "items")
        -- Under the slots, the tab's latest moves, when someone read its log: the card as tall as they are.
        local latest = items and log and logLines(log, tabs, false) or {}
        panel.latest:SetShown(#latest > 0)
        for i, pair in ipairs(panel.latest.lines) do
            pair.left:SetText(latest[i] and latest[i][1] or "")
            pair.right:SetText(latest[i] and latest[i][2] or "")
        end
        -- As much room under the last line as over the first.
        local lines = min(#latest, BANK.latest)
        local first = panel.latest.lines[1].left
        panel.latest:SetHeight(Skin.CARD_HEAD + 2 * Skin.SPACE.s + max(lines - 1, 0) * BANK.line + floor((first:GetLineHeight() or 11) + 0.5))
        panel.latest.read:SetText(#latest > 0 and log.at and format("Read at the bank by %s, %s", log.by or "a guildmate", ago(log.at)) or "")
        -- The filter, only while some item in these tabs would help someone.
        local anyHelps = false
        for _, i in ipairs(viewable) do
            for _, it in pairs(type(tabs[i].slots) == "table" and tabs[i].slots or {}) do
                if type(it) == "table" and helps(it.id) then anyHelps = true end
            end
        end
        panel.helps:SetShown(items and anyHelps)
        panel.helps:SetChecked(state.bankHelps and anyHelps or false)
        local onlyHelps = state.bankHelps and anyHelps
        panel.empty:SetShown(message and true or false)
        panel.empty:SetText(message or "")
        panel.money:SetShown(b ~= nil and b.money ~= nil)
        if b and b.money then panel.money:Set("Guild bank: " .. money(b.money)) end
        panel.note:ClearAllPoints()
        if panel.money:IsShown() then panel.note:SetPoint("LEFT", panel.money, "RIGHT", BANK.gutter + 4, 0) else panel.note:SetPoint("LEFT") end
        panel.note:SetPoint("RIGHT", panel.limits, "LEFT", -(BANK.gutter + 4), 0)
        for _, t in ipairs(panel.tabs) do t:Hide() end
        if settings then panel.helps:Hide() refreshSettings(g, b, tabs) end
        -- The header and the cards under it, the right one for what shows; the row of views only when
        -- someone read a log.
        local withViews = main and (log ~= nil or goldLog ~= nil)
        if message or settings then
            panel.views:Layout(BANK.side, down(BANK.row))
            for _, v in ipairs(panel.views.order) do v:Hide() end
            panel.views:Select(nil, true)
            panel.tabName:SetText(settings and "Sharing" or "")
            panel.seen:SetText("")
            panel.note:SetText("")
            panel.note.whole = nil
            panel.limits:SetText("")
            if not settings then panel.drawn = nil return end
        end
        local p = ns.bankPolicy(g)
        for n, i in ipairs(viewable) do
            local t = panel.tabs[n]
            t.index, t.tabName = i, tabs[i].name or ("Tab " .. i)
            local a = p and type(p.tb) == "table" and p.tb[i]
            t.wider = (a == "a" or type(a) == "number") and format("The guild master shares this tab with %s.", audienceText(a, rankNames(g)):lower()) or nil
            t:SetIcon(tabs[i].icon or 134400)
            t:SetChecked(i == current and not settings)
            t:Show()
        end
        if settings then
            arrive("settings", current, { panel.settings })
            return
        end
        local tab = tabs[current]
        panel.tabName:SetText(view == "gold" and "Gold log" or (tab.name or ("Tab " .. current)))
        -- Items, Log and Gold log, over the cards; Log and Gold log only when someone read them.
        for _, v in ipairs(panel.views.order) do
            v:SetShown(withViews and (v.key == "items" or (v.key == "log" and log ~= nil) or (v.key == "gold" and goldLog ~= nil)))
        end
        panel.views:Layout(BANK.side, down(BANK.row))
        local drawnMode = panel.drawn and panel.drawn.mode
        panel.views:Select(withViews and view or nil, not (drawnMode and drawnMode ~= view))
        local note = view ~= "gold" and b and type(b.notes) == "table" and b.notes[current]
        local noteText = note and note.text and ("Note: " .. note.text) or ""
        panel.note:SetText((noteText:gsub("[\r\n]+", " ")))
        panel.note.whole = noteText ~= "" and noteText or nil
        panel.limits:SetText(view == "gold" and "" or limitsText(g, b, current))
        if view ~= "items" then
            local which = view == "gold" and goldLog or log
            local lines = logLines(which, tabs, view == "gold")
            panel.logCard:SetShown(#lines > 0) -- a log read with nothing in it: its header says when
            panel.logCard:SetHeight(min(BANK.bottom - BANK.cards, 2 * Skin.SPACE.s + #lines * BANK.logLine))
            panel.log:SetDataProvider(CreateDataProvider(lines))
            panel.seen:SetText(which and which.at and format("Read at the bank by %s, %s", which.by or "a guildmate", ago(which.at)) or "")
            arrive(view, current, { panel.logCard })
            return
        end
        panel.seen:SetText(tab.at and format("As %s saw it, %s", tab.by or "a guildmate", ago(tab.at)) or "Not seen yet")
        local q = (state.bankQuery or ""):lower()
        local slots = type(tab.slots) == "table" and tab.slots or {}
        for slot, button in ipairs(panel.slots) do
            local it = slots[slot]
            showItem(button, it, true)
            local match = true
            if q ~= "" then
                local name = it and (it.name or (it.id and str((call(api("C_Item.GetItemInfo") or GetItemInfo, it.id)))))
                match = it and name and name:lower():find(q, 1, true) and true or false
            end
            if onlyHelps and not (it and helps(it.id)) then match = false end
            -- As the game's bags show a search: what doesn't match is darkened.
            button:SetMatchesSearch(match)
        end
        arrive("items", current, { panel.grid, panel.latest })
    end
end

V.bankTabs = bankTabs
V.bankEmpty = bankEmpty
V.buildBank = buildBank
