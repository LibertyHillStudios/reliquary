-- Reliquary's window: an item's page (docs/DESIGN.md, section 5): a band across the top with the item
-- on its slot, its name and Back, and under it two columns of cards: what the item is (its tooltip,
-- what it's worth, what it's made with and goes into) and the people around it (who can use it, make
-- it, use it or learn it, and where it comes from). It slides in from the right over the tab it was
-- opened from, and Back and Escape slide it away again (DESIGN, section 2, moment 8).
local ADDON, ns = ...

local V = ns.V
local Skin, Motion = ns.Skin, ns.Motion

local call, num, str, api = ns.call, ns.num, ns.str, ns.api
local pairs, ipairs, type = pairs, ipairs, type
local min, max, floor, ceil, format = math.min, math.max, math.floor, math.ceil, string.format
local GREY, GREEN, BLUE, RED, ORANGE = ns.GREY, ns.GREEN, ns.BLUE, ns.RED, ns.ORANGE
local state, sound, ago, classColored = V.state, V.sound, V.ago, V.classColored
local money, showItemTip, hideTip, showTip, itemButton = V.money, V.showItemTip, V.hideTip, V.showTip, V.itemButton
local carried, itemFace, qualityName, myGuild = V.carried, V.itemFace, V.qualityName, V.myGuild

---------------------------------------------------------------------------
-- What the page says
---------------------------------------------------------------------------
local VERDICT_WORDS = { up = GREEN .. "Upgrade|r", lvl = BLUE .. "At level %d|r", trade = ORANGE .. "Trade-off|r", no = GREY .. "No gain|r" }
local function nameOf(who) return ns.callName(who) end

local function listNames(names)
    if #names <= 1 then return names[1] or "" end
    return table.concat(names, ", ", 1, #names - 1) .. " and " .. names[#names]
end

-- A guildmate as your copy of the guild list knows them, for a row of someone with no verdict.
local function rosterRow(who)
    local g = myGuild()
    for _, m in ipairs(g and type(g.members) == "table" and g.members or {}) do
        if type(m) == "table" and m.n and ns.fullName(m.n) == who then
            return { who = who, name = who == ns.me() and ns.char.name or ns.callName(who), cls = m.cls, level = m.lv, me = who == ns.me() or nil, own = true }
        end
    end
    return { who = who, name = who == ns.me() and ns.char.name or ns.callName(who), me = who == ns.me() or nil, own = true }
end

-- A row's details on hover: what it replaces, every change, how it was judged, and the board.
local function rowTip(row)
    local x = row.x
    if not x then return end
    GameTooltip:SetOwner(row, "ANCHOR_LEFT")
    GameTooltip:SetText(classColored(x.me and x.who == ns.me() and (x.name .. " (you)") or x.name or "?", x.cls))
    if x.v then GameTooltip:AddLine(format(VERDICT_WORDS[x.v] or x.v, x.lv or 0)) end
    if x.cn then GameTooltip:AddLine(format("Replaces %s, item level %d", x.cn, x.ci or 0), 1, 1, 1, true)
    elseif x.sl then GameTooltip:AddLine("For an empty slot", 1, 1, 1) end
    if x.il and x.ci and x.il ~= x.ci then GameTooltip:AddLine(format("%+d item levels", x.il - x.ci), 1, 1, 1) end
    for _, c in ipairs(x.d or {}) do
        GameTooltip:AddLine((c.n > 0 and GREEN or RED) .. format("%+d %s", c.n, c.k) .. "|r")
    end
    if x.v and not x.own then GameTooltip:AddLine(GREY .. "Your game judged this from the gear they share. Their own game's answer replaces it once they're online.|r", 1, 1, 1, true) end
    if row.aside then GameTooltip:AddLine(GREEN .. format("Set aside for them by %s, %s.", row.aside.by and nameOf(row.aside.by) or "an officer", ago(row.aside.at)) .. "|r", 1, 1, 1, true) end
    if row.asked then GameTooltip:AddLine(ORANGE .. format("Asked for it %s.", ago(row.asked.at)) .. "|r", 1, 1, 1, true) end
    if x.asked then GameTooltip:AddLine(GREY .. "Their own game's verdict, sent with their ask.|r", 1, 1, 1, true) end
    GameTooltip:Show()
end

-- What changes for someone, in a few words: what it replaces and the stats that move.
local function verdictDetail(x)
    local bits = {}
    if x.cn then bits[#bits + 1] = format("replaces %s (%d)", x.cn, x.ci or 0) elseif x.sl then bits[#bits + 1] = "an empty slot" end
    if x.il and x.ci and x.il ~= x.ci then bits[#bits + 1] = format("%+d item levels", x.il - x.ci) end
    for _, c in ipairs(x.d or {}) do bits[#bits + 1] = format("%+d %s", c.n, c.k) end
    return table.concat(bits, ", ")
end

-- How many of this item your characters have, and the guild bank.
local function holdings(id)
    local yours, bank = 0, 0
    for _, c in pairs(ns.db.chars) do
        for _, rec in pairs(type(c.gear) == "table" and c.gear or {}) do if type(rec) == "table" and rec.id == id then yours = yours + 1 end end
        for _, list in ipairs({ c.bags or {}, c.bank or {} }) do
            for _, bag in ipairs(list) do
                for _, it in pairs(type(bag.slots) == "table" and bag.slots or {}) do if it.id == id then yours = yours + (it.n or 1) end end
            end
        end
    end
    local g = myGuild()
    for i, tab in pairs(g and type(g.bank) == "table" and type(g.bank.tabs) == "table" and g.bank.tabs or {}) do
        if ns.maySeeTab(g, i) then
            for _, it in pairs(type(tab.slots) == "table" and tab.slots or {}) do if it.id == id then bank = bank + (it.n or 1) end end
        end
    end
    return yours, bank
end

-- Where each kind of place an item comes from gets the game's own map icon (an atlas), or a
-- container its own icon.
local PLACE_ICONS = { vendor = "auctionhouse-icon-coin-gold", quest = "QuestNormal", boss = "DungeonSkull", drop = "VignetteKill",
    fish = "Professions_Tracking_Fish", gather = "VignetteLoot", container = "VignetteLoot" }
-- What's gathered gets the map's herb or ore icon when the game files the item as a herb or as metal
-- and stone (trade goods, Enum.ItemTradeGoodsSubclass Herb 9, MetalStone 7).
local GATHER_ICONS = { [9] = "Professions_Tracking_Herb", [7] = "Professions_Tracking_Ore" }
local function gatherIcon(id)
    local _, _, _, _, _, classID, subClassID = call(api("C_Item.GetItemInfoInstant") or GetItemInfoInstant, id)
    return num(classID) == 7 and GATHER_ICONS[num(subClassID) or -1] or nil
end

-- A person on the item's page opens their page: yours and your other characters' on Characters, a
-- guildmate's on Guild, a friend's on Friends.
local PERSON_TAB = { me = { "Characters", "chars" }, own = { "Characters", "chars" }, g = { "Guild", "guild" }, f = { "Friends", "friends" } }
local function personKey(e)
    if e.kind == "me" then return ns.charKey end
    if e.kind == "own" then return (e.who or ""):match("^own:(.+)$") end
    return e.who
end

---------------------------------------------------------------------------
-- How it is laid out, in units
---------------------------------------------------------------------------
-- The band across the top and the item's slot in it; the item's own column (its width) and the
-- people's (the rest); a card's padding and the room its label takes; the rows inside the cards: a
-- reagent's or product's slot and the gap between their rows, a person who can use it (an avatar and
-- two lines), one who makes, uses or learns it, a place's icon, a value's row, the gap between a
-- tooltip's lines and the room round the line under them; how far a card's note sits below the middle
-- of its label's line, level with the label's capitals (Cinzel's sit low in their line).
local SPACE = Skin.SPACE
local ITEM = { band = 88, slot = 56, left = 352, cell = 40, user = 44, userFace = 28, person = 32, personFace = 24, icon = 16, stat = 20,
    tipGap = 2, fold = 2, noteDrop = 2 }
ITEM.width = V.WIDTH - 2 -- the window's body, inside its line
ITEM.top = ITEM.band + SPACE.l
ITEM.height = V.BODY_HEIGHT - ITEM.top - SPACE.l
ITEM.right = ITEM.width - 2 * SPACE.l - ITEM.left - SPACE.l
local CARD_PAD, CARD_TOP = SPACE.m, Skin.CARD_HEAD + SPACE.s
local function inner(width) return width - 2 * CARD_PAD end
-- An item page comes from further than another tab: it lies over the one it was opened from.
local SLIDE = 3 * Motion.SLIDE_PAGE

---------------------------------------------------------------------------
-- The cards' contents: each made the first time a card is one of them, in the card's body
---------------------------------------------------------------------------
local PART = {}

-- What it is: its tooltip's lines as the game showed them (left and right, in their colours), then
-- under a line what it's worth (Auction, Sell Price, with what a price rests on) and how many your
-- characters and the guild bank have.
function PART.facts(body)
    local p = CreateFrame("Frame", nil, body)
    p:SetAllPoints()
    p.texts, p.rules = {}, {}
    function p.fill(e)
        local y, t, r = 0, 0, 0
        for _, row in ipairs(e.rows) do
            if row.kind == "rule" then
                r = r + 1
                local rule = p.rules[r] or Skin.line(p, "ink600")
                p.rules[r] = rule
                rule:ClearAllPoints()
                rule:SetPoint("TOPLEFT", 0, y - floor(row.h / 2))
                rule:SetPoint("TOPRIGHT", 0, y - floor(row.h / 2))
                rule:Show()
            else
                t = t + 1
                local pair = p.texts[t]
                if not pair then
                    pair = { left = Skin.text(p, "body"), right = Skin.text(p, "body", "RIGHT") }
                    pair.left:SetWordWrap(true)
                    pair.left:SetJustifyV("TOP")
                    p.texts[t] = pair
                end
                local left, right = pair.left, pair.right
                left:ClearAllPoints()
                right:ClearAllPoints()
                if row.kind == "tip" then
                    Skin.setRole(left, "body")
                    Skin.setRole(right, "body", "RIGHT")
                    left:SetPoint("TOPLEFT", 0, y)
                    left:SetWidth(row.w)
                    right:SetPoint("TOPRIGHT", 0, y)
                    left:SetText(row.l)
                    right:SetText(row.r or "")
                elseif row.kind == "stat" then
                    Skin.setRole(left, "small")
                    Skin.setRole(right, "numeral", "RIGHT")
                    left:SetPoint("LEFT", p, "TOPLEFT", 0, y - row.h / 2)
                    left:SetWidth(row.w)
                    right:SetPoint("RIGHT", p, "TOPRIGHT", 0, y - row.h / 2)
                    right:SetPoint("LEFT", left, "RIGHT", SPACE.s, 0)
                    left:SetText(row.text)
                    right:SetText(row.value or "")
                else
                    -- A note: what a price rests on, under it at the right; what you have, at the left.
                    Skin.setRole(left, row.left and "small" or "dim", row.left and "LEFT" or "RIGHT")
                    if row.left then left:SetTextColor(Skin.rgb("parchment")) end
                    left:SetPoint("TOPLEFT", 0, y)
                    left:SetWidth(row.w)
                    left:SetText(row.text)
                    right:SetText("")
                end
                left:Show()
                right:SetShown(row.kind ~= "note" and (row.kind == "stat" or row.r ~= nil))
            end
            y = y - row.h
        end
        for i = t + 1, #p.texts do p.texts[i].left:Hide() p.texts[i].right:Hide() end
        for i = r + 1, #p.rules do p.rules[i]:Hide() end
    end
    return p
end

-- Items on their slots, two to a row, each name beside its slot (a click opens the item's page;
-- Shift-click and Ctrl-click as anywhere): what it's made with, with how many you have of how many it
-- takes, and what it goes into.
function PART.cells(body)
    local p = CreateFrame("Frame", nil, body)
    p:SetAllPoints()
    p.cells = {}
    function p.fill(e)
        local width = floor((e.inner - SPACE.l) / 2)
        for i, it in ipairs(e.items) do
            local cell = p.cells[i]
            if not cell then
                cell = CreateFrame("Frame", nil, p)
                cell:SetHeight(ITEM.cell)
                cell.button = itemButton(cell, ITEM.cell)
                cell.button:SetPoint("LEFT")
                cell.name = Skin.text(cell, "body")
                cell.name:SetWordWrap(true)
                cell.name:SetMaxLines(2)
                cell.name:SetPoint("LEFT", cell.button, "RIGHT", SPACE.s, 0)
                p.cells[i] = cell
            end
            cell:ClearAllPoints()
            cell:SetPoint("TOPLEFT", ((i - 1) % 2) * (width + SPACE.l), -floor((i - 1) / 2) * (ITEM.cell + SPACE.s))
            cell:SetWidth(width)
            cell.name:SetWidth(width - ITEM.cell - SPACE.s)
            local face = it.face
            local b = cell.button
            b.rq = { id = face.id, link = "item:" .. face.id }
            SetItemButtonTexture(b, face.icon)
            SetItemButtonQuality(b, face.q)
            b:SetQuality(face.q, true)
            cell.name:SetText(it.label)
            local c = it.color
            if c then cell.name:SetTextColor(c.r, c.g, c.b) else cell.name:SetTextColor(Skin.rgb("parchment")) end
            cell:Show()
        end
        for i = #e.items + 1, #p.cells do p.cells[i]:Hide() end
    end
    return p
end

-- A row of a card's list that can be pointed at: its background fills on hover.
local function hoverRow(parent)
    local b = CreateFrame("Button", nil, parent)
    b.fill = Skin.nine(b, "disc", { radius = Skin.RADIUS.control, layer = "BACKGROUND", color = "ink800", inset = { -SPACE.xs, 0, -SPACE.xs, 0 } })
    b.fill:SetAlpha(0)
    local function fill(self, a)
        Motion.fade(self.fill, a, { dur = "fast", from = self.fill.alpha or 0, set = function(n, v) n:SetAlpha(v) end, owner = self })
    end
    b:HookScript("OnEnter", function(self) fill(self, 1) end)
    b:HookScript("OnLeave", function(self) fill(self, 0) hideTip() end)
    return b
end

-- Who in the guild can use it: each under their class icon, their name (with their level, and Set
-- aside or Asked when it is), what changes for them under it, the verdict at the right, and Set
-- aside, Take back or Ask for it for whoever may; then the rest, folded into a line.
function PART.users(body, pg)
    local p = CreateFrame("Frame", nil, body)
    p:SetAllPoints()
    p.rows, p.shown = {}, {}
    local function make()
        local row = hoverRow(p)
        row:SetHeight(ITEM.user)
        row.avatar = Skin.avatar(row, ITEM.userFace)
        row.avatar:SetPoint("LEFT")
        row.act = Skin.button(row, "quiet")
        row.act:SetHeight(22)
        row.act:SetPoint("RIGHT")
        row.act:HookScript("OnEnter", function(self)
            if self:GetText() ~= "Ask for it" then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText("Ask for it")
            GameTooltip:AddLine("Guildmates who may see this tab see your ask, with what your game says it would be for you (Upgrade, At level N, Trade-off or No gain), never what you wear.", 1, 1, 1, true)
            GameTooltip:Show()
        end)
        row.act:HookScript("OnLeave", hideTip)
        row.act:SetScript("OnClick", function(self)
            if self.run and self.run() then sound("IG_MAINMENU_OPTION") end
            pg.redraw()
        end)
        row.verdict = Skin.text(row, "small", "RIGHT")
        row.name = Skin.text(row, "heading")
        row.name:SetPoint("TOPLEFT", ITEM.userFace + SPACE.m, -6)
        row.name:SetPoint("RIGHT", row.verdict, "LEFT", -SPACE.s, 0)
        row.detail = Skin.text(row, "small")
        row.detail:SetTextColor(Skin.rgb("dim"))
        row.detail:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -4)
        row:HookScript("OnEnter", rowTip)
        return row
    end
    p.foldRow = hoverRow(p)
    p.foldRow.text = Skin.text(p.foldRow, "small")
    p.foldRow.text:SetTextColor(Skin.rgb("dim"))
    p.foldRow.text:SetWordWrap(true)
    p.foldRow.text:SetMaxLines(2)
    p.foldRow.text:SetJustifyV("TOP")
    p.foldRow.text:SetPoint("TOPLEFT", 0, -ITEM.fold)
    p.foldRow.text:SetPoint("RIGHT")
    p.foldRow:HookScript("OnEnter", function(self) showTip(self, "Can equip it, with no gain", { table.concat(self.names, ", ") }) end)
    function p.fill(e)
        wipe(p.shown)
        for i, u in ipairs(e.users) do
            local row = p.rows[i] or make()
            p.rows[i] = row
            local x = u.x
            row.x, row.aside, row.asked = x, u.aside, u.asked
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", 0, -(i - 1) * ITEM.user)
            row:SetPoint("RIGHT")
            row.avatar:SetShown(x.cls ~= nil)
            row.avatar:SetClass(x.cls)
            local tag = u.aside and ("  " .. GREEN .. "Set aside|r") or u.asked and ("  " .. ORANGE .. "Asked|r") or ""
            row.name:SetText(classColored(x.me and x.who == ns.me() and (x.name .. " (you)") or ns.shortName(x.name), x.cls)
                .. (x.level and ("  " .. GREY .. x.level .. "|r") or "") .. tag .. ((x.v and not x.own) and ("  " .. GREY .. "(from what they share)|r") or ""))
            row.verdict:SetText(x.v and format(VERDICT_WORDS[x.v] or x.v, x.lv or 0) or "")
            local detail = x.v and verdictDetail(x) or ""
            if detail == "" and u.asked then detail = format("Asked for it %s", ago(u.asked.at)) end
            row.detail:SetText(detail)
            row.act:SetShown(u.run ~= nil)
            row.act:SetText(u.label or "")
            row.act.run = u.run
            -- The verdict at the right, level with the button beside it; what changes runs under the name, up
            -- to them (all of it on hover).
            row.verdict:ClearAllPoints()
            row.verdict:SetPoint("RIGHT", row, "RIGHT", u.run and -(row.act:GetWidth() + SPACE.m) or 0, 0)
            local stop = (row.verdict:GetText() or "") ~= "" and row.verdict or u.run and row.act or nil
            row.detail:SetPoint("RIGHT", stop or row, stop and "LEFT" or "RIGHT", stop and -SPACE.m or 0, 0)
            row:Show()
            p.shown[#p.shown + 1] = row
        end
        for i = #e.users + 1, #p.rows do p.rows[i]:Hide() end
        local f = p.foldRow
        f:SetShown(e.fold ~= nil)
        f.names = e.fold and e.fold.names or nil
        if e.fold then
            f:ClearAllPoints()
            f:SetPoint("TOPLEFT", 0, -#e.users * ITEM.user)
            f:SetPoint("RIGHT")
            f:SetHeight(e.fold.h)
            f.text:SetText(e.fold.text)
            p.shown[#p.shown + 1] = f
        end
    end
    return p
end

-- Who can make it, uses it or could learn it: each under their class icon, their profession and skill
-- at the right; a click opens their page.
function PART.people(body, pg)
    local p = CreateFrame("Frame", nil, body)
    p:SetAllPoints()
    p.rows, p.shown = {}, {}
    local function make()
        local row = hoverRow(p)
        row:SetHeight(ITEM.person)
        row.avatar = Skin.avatar(row, ITEM.personFace)
        row.avatar:SetPoint("LEFT")
        row.prof = Skin.text(row, "small", "RIGHT")
        row.prof:SetTextColor(Skin.rgb("dim"))
        row.prof:SetPoint("RIGHT")
        row.name = Skin.text(row, "heading")
        row.name:SetPoint("LEFT", ITEM.personFace + SPACE.m, 0)
        row.name:SetPoint("RIGHT", row.prof, "LEFT", -SPACE.s, 0)
        row:HookScript("OnEnter", function(self)
            local e = self.person
            showTip(self, e.kind == "me" and "You" or e.name or "?", { (e.prof or "") .. (e.sk and (" " .. e.sk) or "") })
        end)
        row:SetScript("OnClick", function(self)
            local e = self.person
            local go = e and PERSON_TAB[e.kind]
            local key = e and personKey(e)
            if not (go and key and pg.close and ns.showViewer) then return end
            state.pick[go[2]] = key
            pg.close()
            ns.showViewer(go[1])
        end)
        return row
    end
    function p.fill(e)
        wipe(p.shown)
        for i, person in ipairs(e.people) do
            local row = p.rows[i] or make()
            p.rows[i] = row
            row.person = person
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", 0, -(i - 1) * ITEM.person)
            row:SetPoint("RIGHT")
            row.avatar:SetShown(person.cls ~= nil)
            row.avatar:SetClass(person.cls)
            row.name:SetText(classColored(person.kind == "me" and (person.name .. " (you)") or ns.shortName(person.name or "?"), person.cls))
            row.prof:SetText((person.prof or "") .. (person.sk and ("  " .. person.sk) or ""))
            row:Show()
            p.shown[#p.shown + 1] = row
        end
        for i = #e.people + 1, #p.rows do p.rows[i]:Hide() end
    end
    return p
end

-- Where it comes from: each place beside the game's map icon for its kind.
function PART.places(body)
    local p = CreateFrame("Frame", nil, body)
    p:SetAllPoints()
    p.rows, p.shown = {}, {}
    function p.fill(e)
        wipe(p.shown)
        local y = 0
        for i, place in ipairs(e.places) do
            local row = p.rows[i]
            if not row then
                row = CreateFrame("Frame", nil, p)
                row.icon = row:CreateTexture(nil, "ARTWORK")
                row.icon:SetSize(ITEM.icon, ITEM.icon)
                row.icon:SetPoint("TOPLEFT", 0, -1)
                row.text = Skin.text(row, "small")
                row.text:SetTextColor(Skin.rgb("parchment"))
                row.text:SetWordWrap(true)
                row.text:SetJustifyV("TOP")
                row.text:SetPoint("TOPLEFT", ITEM.icon + SPACE.s, -2)
                row.text:SetPoint("RIGHT")
                p.rows[i] = row
            end
            row.place = place
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", 0, y)
            row:SetPoint("RIGHT")
            row:SetHeight(place.h)
            if place.item then
                row.icon:SetTexture(place.item)
                row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92) -- an icon, cut in from its baked border
            else
                row.icon:SetAtlas(place.atlas or PLACE_ICONS[place.place] or "VignetteLoot")
                row.icon:SetTexCoord(0, 1, 0, 1)
            end
            row.text:SetText(place.text)
            row:Show()
            p.shown[#p.shown + 1] = row
            y = y - place.h
        end
        for i = #e.places + 1, #p.rows do p.rows[i]:Hide() end
    end
    return p
end

---------------------------------------------------------------------------
-- The page
---------------------------------------------------------------------------
local function makeItemPage(parent)
    -- The page itself is what the window shows and Escape closes. What it draws is a sheet laid over
    -- the window's body beside it rather than inside it, so that once Back or Escape has closed the
    -- page the sheet can still slide away over the tab it uncovers.
    local pg = CreateFrame("Frame", "ReliquaryItemPage", parent)
    pg:SetAllPoints()
    pg:Hide()
    pg.history = {} -- the items opened from this one's page, in order: Back and Escape step back through them
    local sheet = CreateFrame("Frame", nil, parent)
    sheet:SetAllPoints()
    sheet:SetFrameLevel((parent:GetFrameLevel() or 1) + 20)
    sheet:SetClipsChildren(true)
    sheet:Hide()
    pg.sheet = sheet
    -- The plate: the window's ink laid over the tab while the page arrives or leaves; once the page is
    -- in place, the tab under it goes and the plate gives way to the body.
    local plate = CreateFrame("Frame", nil, sheet)
    plate:SetAllPoints()
    plate.ink = Skin.nine(plate, "disc", { radius = Skin.RADIUS.window - 1, layer = "BACKGROUND", color = "ink900", square = { tl = true, tr = true } })
    plate:Hide()
    sheet.plate = plate
    local content = CreateFrame("Frame", nil, sheet)
    content:SetAllPoints()
    content:SetFrameLevel(plate:GetFrameLevel() + 1) -- over the plate, never level with it
    sheet.content = content
    pg.redrawSoon = function() if pg:IsVisible() then pg.redraw() end end

    -- The band: the item on its slot (its tooltip on hover), its name in its quality's colour, its item
    -- level (gear only, as the game's tooltips) and level to use it, who it's set aside for; Back.
    local band = CreateFrame("Frame", nil, content)
    band:SetPoint("TOPLEFT")
    band:SetPoint("TOPRIGHT")
    band:SetHeight(ITEM.band)
    band.fill = Skin.nine(band, "disc", { radius = 1, layer = "BACKGROUND", color = "ink850", square = { tl = true, tr = true, bl = true, br = true } })
    band.rule = Skin.line(band, "ink600")
    band.rule:SetPoint("BOTTOMLEFT")
    band.rule:SetPoint("BOTTOMRIGHT")
    pg.band = band
    pg.icon = Skin.slot(band, ITEM.slot)
    pg.icon:SetPoint("LEFT", SPACE.l, 0)
    pg.icon:HookScript("OnEnter", showItemTip)
    pg.icon:HookScript("OnLeave", hideTip)
    pg.back = Skin.button(band, "quiet")
    pg.back:SetText("Back")
    pg.back:SetGlyph("chevronLeft", 12)
    pg.back:SetPoint("RIGHT", -SPACE.l, 0)
    pg.back:SetScript("OnClick", function() pg:Hide() sound("IG_MAINMENU_OPTION") end)
    pg.lines = CreateFrame("Frame", nil, band)
    pg.lines:SetPoint("LEFT", pg.icon, "RIGHT", SPACE.l, 0)
    pg.lines:SetPoint("RIGHT", pg.back, "LEFT", -SPACE.l, 0)
    pg.name = Skin.text(pg.lines, "title")
    pg.name:SetPoint("TOPLEFT")
    pg.name:SetPoint("RIGHT")
    pg.meta = Skin.text(pg.lines, "small")
    pg.meta:SetPoint("TOPLEFT", pg.name, "BOTTOMLEFT", 0, -SPACE.s)
    pg.meta:SetPoint("RIGHT")
    pg.board = Skin.text(pg.lines, "small")
    pg.board:SetPoint("TOPLEFT", pg.meta, "BOTTOMLEFT", 0, -SPACE.xs)
    pg.board:SetPoint("RIGHT")
    -- A line cut short shows whole on hover.
    for _, line in ipairs({ pg.name, pg.board }) do
        local hover = CreateFrame("Frame", nil, pg.lines)
        hover:SetAllPoints(line)
        hover:EnableMouse(true)
        hover:SetScript("OnEnter", function(self)
            if not line:IsTruncated() then return end
            GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
            GameTooltip:SetText(line:GetText() or "", 1, 1, 1, 1, true)
            GameTooltip:Show()
        end)
        hover:SetScript("OnLeave", hideTip)
        line.hover = hover
    end

    -- How tall a text is at its width, as the game lays it out (shown and never seen).
    pg.measure = Skin.text(content, "body")
    pg.measure:SetWordWrap(true)
    pg.measure:SetPoint("TOPLEFT")
    pg.measure:SetAlpha(0)
    local function tall(s, width, role)
        Skin.setRole(pg.measure, role or "body")
        pg.measure:SetWidth(width)
        pg.measure:SetText(s)
        local h = num(Skin.textHeight(pg.measure)) or 12
        pg.measure:SetText("")
        return max(12, ceil(h))
    end

    -- Each column is a list of cards, one card a section, sized to what it holds; it scrolls when they
    -- run past it, its cards fading out at an edge with more beyond it.
    local function drawCard(row, e)
        if not row.card then
            local card = Skin.card(row)
            card:SetPoint("TOPLEFT")
            card:SetPoint("TOPRIGHT")
            card.note = Skin.text(card, "small", "RIGHT")
            card.note:SetTextColor(Skin.rgb("dim"))
            card.note:SetPoint("RIGHT", card, "TOPRIGHT", -CARD_PAD, -(CARD_TOP - SPACE.s) / 2 - ITEM.noteDrop)
            row.card, row.parts = card, {}
        end
        local card = row.card
        row.e = e
        card:SetHeight(e.h)
        card:SetLabel(e.label)
        card.note:SetText(e.note or "")
        card.note:SetShown(e.note ~= nil)
        card.label:SetPoint("RIGHT", e.note and card.note or card, e.note and "LEFT" or "RIGHT", e.note and -SPACE.s or -CARD_PAD, 0)
        for kind, part in pairs(row.parts) do part:SetShown(kind == e.kind) end
        local part = row.parts[e.kind] or PART[e.kind](card.body, pg)
        row.parts[e.kind] = part
        part:Show()
        part.fill(e)
        row.lines = part.shown
    end
    local function extent(e) return e.h + SPACE.l end
    pg.body = CreateFrame("Frame", nil, content)
    pg.body:SetPoint("TOPLEFT", SPACE.l, -ITEM.top)
    pg.body:SetWidth(ITEM.left)
    pg.list = Skin.scroll(pg.body, { right = 0, fade = SPACE.xl, init = drawCard, extent = extent })
    pg.whoArea = CreateFrame("Frame", nil, content)
    pg.whoArea:SetPoint("TOPLEFT", SPACE.l + ITEM.left + SPACE.l, -ITEM.top)
    pg.whoArea:SetPoint("BOTTOMRIGHT", -SPACE.l, SPACE.l)
    pg.who = Skin.scroll(pg.whoArea, { right = 0, fade = SPACE.xl, init = drawCard, extent = extent })

    -- The addresses to read more, a card right under the item's own column. The game can't open a
    -- browser: each address is there to copy, all of it chosen when the field is.
    pg.links = {}
    local links = Skin.card(content)
    links:SetPoint("TOPLEFT", pg.body, "BOTTOMLEFT")
    links:SetWidth(ITEM.left)
    pg.linkCard = links
    pg.linkNote = Skin.text(links.body, "small")
    pg.linkNote:SetTextColor(Skin.rgb("dim"))
    pg.linkNote:SetWordWrap(true)
    pg.linkNote:SetJustifyV("TOP")
    pg.linkNote:SetPoint("TOPLEFT")
    pg.linkNote:SetWidth(inner(ITEM.left))
    local copyKey = (type(IsMacClient) == "function" and IsMacClient()) and "Cmd+C" or "Ctrl+C"
    pg.linkNote:SetText("To read more, copy an address (" .. copyKey .. ") into your browser:")
    local FIELD, SITE = 24, 74
    for i, site in ipairs({ { "Wowhead", "https://www.wowhead.com/forever/item=%d" }, { "ForeverDB", "https://foreverdb.net/item/%d" } }) do
        local box = Skin.field(links.body, "small")
        box:SetPoint("TOPLEFT", pg.linkNote, "BOTTOMLEFT", SITE, -(SPACE.s + (i - 1) * (FIELD + SPACE.s)))
        box:SetPoint("RIGHT", links.body, "RIGHT")
        box.site = Skin.text(links.body, "small")
        box.site:SetPoint("LEFT", pg.linkNote, "BOTTOMLEFT", 0, -(SPACE.s + (i - 1) * (FIELD + SPACE.s) + FIELD / 2))
        box.site:SetText(site[1])
        box.format = site[2]
        box:HookScript("OnEditFocusGained", function(self) self:HighlightText() end)
        box:SetScript("OnTextChanged", function(self, user) if user and self.url then self:SetText(self.url) self:HighlightText() end end)
        pg.links[i] = box
    end
    -- The addresses' card as tall as its note's lines as the game lays them out, once they show.
    local function fitLinks()
        local note = tall(pg.linkNote:GetText(), inner(ITEM.left), "small")
        pg.linkNote:SetHeight(note)
        links:SetHeight(2 * CARD_PAD + note + SPACE.s + 2 * FIELD + SPACE.s)
    end

    -- The item's own column, as cards.
    local function bodyCards(id, info, src)
        local cards = {}
        local width = inner(ITEM.left)
        -- Its tooltip as the game showed it (its name is the page's title), then what it's worth and
        -- what you have.
        local rows = {}
        local rec = ns.db.items[id]
        for i, l in ipairs(type(rec) == "table" and type(rec.tip) == "table" and rec.tip or {}) do
            if i > 1 and (l.l or l.r) then
                local left = l.l and ((l.lc and l.lc ~= "ffffff") and format("|cff%s%s|r", l.lc, l.l) or l.l) or ""
                local right = l.r and ((l.rc and l.rc ~= "ffffff") and format("|cff%s%s|r", l.rc, l.r) or l.r) or nil
                -- A line with words at its right shares the width with them; one without wraps across it.
                local w = right and floor(width * 0.6) or width
                rows[#rows + 1] = { kind = "tip", l = left, r = right, w = w, h = tall(left, w) + ITEM.tipGap }
            end
        end
        local tips = #rows
        local function stat(text, value) rows[#rows + 1] = { kind = "stat", text = text, value = value, w = floor(width / 2), h = ITEM.stat } end
        local function note(text, left) rows[#rows + 1] = { kind = "note", text = text, left = left, w = width, h = tall(text, width, "small") + SPACE.xs } end
        -- At the auction house, and to a vendor (as the game's tooltip says it).
        local price = ns.priceParts and ns.priceParts(id)
        if price then
            stat("Auction", price.value or (GREY .. (price.waiting and "Asking the auction house..." or "None listed") .. "|r"))
            if price.about then note(price.about) end
        end
        if info.sell and info.sell > 0 then stat(str(SELL_PRICE) or "Sell Price", money(info.sell)) end
        local yours, bank = holdings(id)
        local have = {}
        if yours > 0 then have[#have + 1] = format("your characters have %d", yours) end
        if bank > 0 then have[#have + 1] = format("the guild bank has %d", bank) end
        if #have > 0 then
            local said = table.concat(have, ", and ") .. "."
            note(said:sub(1, 1):upper() .. said:sub(2), true)
        end
        if tips > 0 and #rows > tips then table.insert(rows, tips + 1, { kind = "rule", h = 2 * SPACE.s + 1 }) end
        if #rows > 0 then
            local h = 0
            for _, r in ipairs(rows) do h = h + r.h end
            cards[#cards + 1] = { kind = "facts", rows = rows, h = 2 * CARD_PAD + h }
        end
        -- What goes into it, a card a recipe: each reagent on its slot with how many you have of how many
        -- it takes, white when you have enough, as the game's Professions window shows them. Your notes of
        -- how it's made and what it goes into, with what everyone's recipes say (yours, your other
        -- characters', and those your guildmates and friends share), each way once.
        local ways, seenWay = {}, {}
        local function way(r)
            local parts = {}
            for _, u in ipairs(r.uses or {}) do parts[#parts + 1] = (u.id or 0) .. "x" .. (u.n or 1) end
            local key = (r.prof or "") .. ":" .. table.concat(parts, ",")
            if seenWay[key] then return end
            seenWay[key] = true
            ways[#ways + 1] = r
        end
        for _, r in ipairs(src.recipes) do way(r) end
        for _, r in ipairs(ns.recipesFor and ns.recipesFor(id) or {}) do way(r) end
        local makes, seenMake = {}, {}
        for _, list in ipairs({ src.makes, ns.usedToMake and ns.usedToMake(id) or {} }) do
            for _, o in ipairs(list) do
                if not seenMake[o] then
                    seenMake[o] = true
                    makes[#makes + 1] = o
                end
            end
        end
        local short = DISABLED_REAGENT_COLOR or GRAY_FONT_COLOR
        local enough = HIGHLIGHT_FONT_COLOR
        local function cellsCard(label, items, noteText)
            local lines = ceil(#items / 2)
            cards[#cards + 1] = { kind = "cells", label = label, note = noteText, items = items,
                h = CARD_TOP + lines * ITEM.cell + (lines - 1) * SPACE.s + CARD_PAD }
        end
        for _, r in ipairs(ways) do
            local items = {}
            for _, u in ipairs(r.uses) do
                local face, need = itemFace(u.id, pg.redrawSoon), u.n or 1
                local got = carried(u.id)
                items[#items + 1] = { face = face, label = format(str(TRADESKILL_REAGENT_COUNT) or "%s/%d", got, need) .. " " .. face.name,
                    color = got >= need and enough or short }
            end
            cellsCard("Made with " .. (r.prof or "a profession"), items, r.note and format("%s's note", r.note) or nil)
        end
        -- What it goes into, each item on its slot in its quality's colour.
        if #makes > 0 then
            local items = {}
            for _, o in ipairs(makes) do
                local face = itemFace(o, pg.redrawSoon)
                items[#items + 1] = { face = face, label = qualityName(face) }
            end
            cellsCard("Used to make", items)
        end
        return cards
    end

    -- The people's column, as cards, and last where it comes from.
    local function peopleCards(id, link, board, officer, places)
        local width = inner(ITEM.right)
        local asideTo, askedBy = {}, {}
        for _, x in ipairs(board and board.aside or {}) do asideTo[x.who] = x end
        for _, x in ipairs(board and board.asks or {}) do askedBy[x.who] = x end
        -- Who in the guild can equip it, the people it would help most first; anyone who asked for it
        -- or has it set aside is never folded away.
        local list = ns.whoCanUse and ns.whoCanUse(id, link) or {}
        local shown, gains, listed = {}, {}, {}
        for _, x in ipairs(list) do
            listed[x.who] = true
            if x.v ~= "no" or asideTo[x.who] or askedBy[x.who] then shown[#shown + 1] = x else gains[#gains + 1] = x end
        end
        local others = 0
        for _, kind in ipairs({ "aside", "asks" }) do
            for _, x in ipairs(board and board[kind] or {}) do
                if not listed[x.who] then
                    listed[x.who], others = true, others + 1
                    shown[#shown + 1] = rosterRow(x.who)
                end
            end
        end
        local cards = {}
        if #shown + #gains > 0 then
            -- Officers: Set aside (as many as the tab holds) or Take back. You: Ask for it, or take your
            -- ask back, unless it's set aside for you already.
            local me = ns.me()
            local users = {}
            for _, x in ipairs(shown) do
                local e = { x = x, aside = asideTo[x.who], asked = askedBy[x.who] }
                if officer and not x.who:find("^own:") then
                    if e.aside then e.label, e.run = "Take back", function() return ns.setAside(id, x.who, true, board.tab) end
                    elseif #board.aside < board.count then e.label, e.run = "Set aside", function() return ns.setAside(id, x.who, false, board.tab) end end
                elseif board and not officer and x.who == me and not e.aside then
                    if e.asked then e.label, e.run = "Take back", function() return ns.askFor(id, true, board.tab) end
                    else e.label, e.run = "Ask for it", function() return ns.askFor(id, false, board.tab) end end
                end
                users[#users + 1] = e
            end
            local fold
            if #gains > 0 then
                local names = {}
                for _, x in ipairs(gains) do names[#names + 1] = x.me and "you" or ns.shortName(x.name) end
                local text = format("%d more can equip it, with no gain: %s.", #gains, table.concat(names, ", "))
                fold = { names = names, text = text, h = min(tall(text, width, "small"), 2 * tall("|", width, "small")) + 2 * ITEM.fold }
            end
            -- The count is of those whose game weighed it; with others listed it would read as theirs too.
            cards[#cards + 1] = { kind = "users", label = "Who can use it", users = users, fold = fold,
                note = (#list > 0 and others == 0) and format("%d in the guild can equip it", #list) or nil,
                h = CARD_TOP + #users * ITEM.user + (fold and fold.h or 0) + CARD_PAD }
        end
        -- Who can make it, whose recipes use it, who could learn it (Crafting.lua), each under the words
        -- its line under the item's tooltip uses.
        for _, group in ipairs({ { "Made by", ns.whoCanMake }, { "Used by", ns.whoUses }, { "Can be learned by", ns.whoCanLearn } }) do
            local people = group[2] and group[2](id) or {}
            if #people > 0 then
                cards[#cards + 1] = { kind = "people", label = group[1], people = people, h = CARD_TOP + #people * ITEM.person + CARD_PAD }
            end
        end
        -- Where it comes from, each place beside its kind's map icon.
        if #places > 0 then
            local gathered = gatherIcon(id)
            local rows, h = {}, 0
            for _, p in ipairs(places) do
                local icon = p.item and itemFace(p.item).icon or nil
                local row = { place = p.kind, item = icon, atlas = p.kind == "gather" and gathered or nil, text = p.text,
                    h = max(ITEM.icon, tall(p.text, width - ITEM.icon - SPACE.s, "small")) + SPACE.s }
                rows[#rows + 1] = row
                h = h + row.h
            end
            cards[#cards + 1] = { kind = "places", label = "Where it comes from", places = rows, h = CARD_TOP + h - SPACE.s + CARD_PAD }
        end
        return cards
    end

    local function tallOf(cards)
        local h = 0
        for _, e in ipairs(cards) do h = h + extent(e) end
        return h
    end

    function pg.redraw()
        local it, link = pg.item, pg.link
        if not it then return end
        local id = it.id
        local rec = ns.db.items[id]
        local info = type(rec) == "table" and type(rec.info) == "table" and rec.info or {}
        local face = itemFace(id, pg.redrawSoon)
        pg.icon.rq = it
        local q = face.q or num(it.q)
        SetItemButtonTexture(pg.icon, face.icon or it.icon or it.ic)
        SetItemButtonQuality(pg.icon, q, link)
        pg.icon:SetQuality(q, true)
        -- Its name as Reliquary or the game knows it, else as the button it was opened from had it.
        local name = face.name
        if name == "Item " .. id then name = str(it.name) or str(it.n) or name end
        pg.name:SetText(qualityName({ name = name, q = q }))
        local meta = {}
        if info.ilvl and info.loc then meta[#meta + 1] = "Item level " .. info.ilvl end -- as the game's tooltips, on gear only
        if info.req and info.req > 1 then meta[#meta + 1] = "Requires level " .. info.req end
        pg.meta:SetText(table.concat(meta, "  ·  "))
        -- In a bank tab you may see: who it's set aside for, and who asked (Upgrades.lua).
        local board = ns.boardFor(id)
        if board and #board.aside > 0 then
            local names = {}
            for _, x in ipairs(board.aside) do names[#names + 1] = nameOf(x.who) end
            local last = board.aside[#board.aside]
            pg.board:SetText(GREEN .. "Set aside for " .. listNames(names) .. "|r  " .. GREY .. format("by %s, %s", last.by and nameOf(last.by) or "an officer", ago(last.at)) .. "|r")
        else
            pg.board:SetText("")
        end
        -- The name and the lines under it, centred on the slot as one block; an empty line takes no room.
        local hasMeta, hasBoard = (pg.meta:GetText() or "") ~= "", (pg.board:GetText() or "") ~= ""
        pg.meta:SetShown(hasMeta)
        pg.board:SetShown(hasBoard)
        pg.board:SetPoint("TOPLEFT", hasMeta and pg.meta or pg.name, "BOTTOMLEFT", 0, hasMeta and -SPACE.xs or -SPACE.s)
        local block = (pg.name:GetLineHeight() or 16) + (hasMeta and SPACE.s + (pg.meta:GetLineHeight() or 11) or 0)
            + (hasBoard and (hasMeta and SPACE.xs or SPACE.s) + (pg.board:GetLineHeight() or 11) or 0)
        pg.lines:SetHeight(block)
        pg.board.hover:SetShown(hasBoard)
        local fresh = pg.drawnId ~= id
        pg.drawnId = id
        local keep = not fresh and ScrollBoxConstants and ScrollBoxConstants.RetainScrollPosition or nil
        local src = ns.itemSources and ns.itemSources(id) or { places = {}, recipes = {}, makes = {} }
        local left, right = bodyCards(id, info, src), peopleCards(id, link, board, board and ns.isOfficer(), src.places)
        -- The item's own cards (each way it's made, what it goes into) move, last first, to the top of the
        -- people's column while that brings the two columns' ends closer: no column stands empty beside a
        -- long one.
        while true do
            local last = left[#left]
            if not (last and last.kind == "cells") then break end
            local hL, hR, hS = tallOf(left), tallOf(right), extent(last)
            if max(hL - hS, hR + hS) >= max(hL, hR) then break end
            left[#left] = nil
            table.insert(right, 1, last)
        end
        for _, e in ipairs(left) do e.inner = inner(ITEM.left) end
        for _, e in ipairs(right) do e.inner = inner(ITEM.right) end
        pg.list:SetDataProvider(CreateDataProvider(left), keep)
        pg.who:SetDataProvider(CreateDataProvider(right), keep)
        -- The item's column as tall as its cards, the addresses right under it; the most it takes leaves
        -- the addresses room above the window's foot.
        fitLinks()
        pg.body:SetHeight(max(1, min(tallOf(left), ITEM.height - links:GetHeight())))
        links:ClearAllPoints()
        links:SetPoint("TOPLEFT", pg.body, #left > 0 and "BOTTOMLEFT" or "TOPLEFT")
        links:SetWidth(ITEM.left)
        for _, box in ipairs(pg.links) do
            box.url = format(box.format, id)
            box:SetText(box.url)
            box:SetCursorPosition(0)
        end
        -- Another item opened from this one's page arrives from the right; the one before it, stepping
        -- back, from the left. The page opening slides in whole (below) and isn't moved again.
        if fresh and not pg.entering and pg.how ~= "open" then
            Motion.fade(content, 1, { from = 0, dur = "base", ease = "enter" })
            Motion.slide(content, (pg.how == "back" and -1 or 1) * Motion.SLIDE_PAGE, 0, { dur = "base", ease = "enter" })
        end
        pg.how = nil
    end

    ---------------------------------------------------------------------------
    -- Arriving and leaving
    ---------------------------------------------------------------------------
    -- The sheet at rest, where the page draws it.
    local function settle()
        Motion.stop(content, "slide")
        Motion.stop(content, "alpha")
        Motion.stop(plate, "alpha")
        content:ClearAllPoints()
        content:SetAllPoints()
        content:SetAlpha(1)
    end
    -- In place over the tab: the tab goes (pg.cover), then the plate gives way to the body.
    local function landed()
        pg.entering = false
        local covered = pg.onCovered
        pg.onCovered = nil
        if covered then covered() end
        Motion.fade(plate, 0, { from = plate:GetAlpha(), dur = "fast", done = function(f) f:Hide() end })
    end
    -- fn hides the tab the page lies over: now when the page is in place, else once it is.
    function pg.cover(fn)
        if pg.entering then pg.onCovered = fn else fn() end
    end
    -- Opened: the sheet slides in from the right over the tab, from wherever it was if it was still
    -- leaving. Shown again stepping back to the item before, it stays where it is.
    pg:HookScript("OnShow", function()
        if pg.stepping then
            pg.stepping = nil
            pg.how = "back"
            return
        end
        pg.how = "open"
        pg.entering = true
        local fresh = not sheet:IsShown()
        if fresh then
            settle()
            plate:SetAlpha(0)
            content:SetAlpha(0)
        end
        sheet:Show()
        plate:Show()
        Motion.fade(plate, 1, { from = plate:GetAlpha(), dur = "base", ease = "out" })
        Motion.fade(content, 1, { from = content:GetAlpha(), dur = "base", ease = "enter" })
        Motion.slide(content, SLIDE, 0, { dur = "base", ease = "enter", done = landed })
    end)
    -- Closed: by Back or Escape the sheet slides away to the right over the tab, which shows again under
    -- it; stepping back to the item before, it stays (the window shows that item next); with the window,
    -- another tab or a person's page (pg.close), it goes at once.
    pg:HookScript("OnHide", function()
        if pg.closing or not parent:IsVisible() then
            pg.entering, pg.onCovered = false, nil
            settle()
            plate:Hide()
            sheet:Hide()
            return
        end
        if #pg.history > 0 then
            pg.stepping = true
            return
        end
        pg.entering, pg.onCovered = false, nil
        local from = plate:IsShown() and plate:GetAlpha() or 1
        plate:Show()
        Motion.fade(plate, 0, { from = from, dur = "base", ease = "out" })
        Motion.fade(content, 0, { from = content:GetAlpha(), dur = "base", ease = "out" })
        Motion.slide(content, 0, 0, { to = { SLIDE, 0 }, from = Motion.value(content, "slide") or { 0, 0 }, dur = "base", ease = "out",
            done = function()
                settle()
                plate:Hide()
                sheet:Hide()
            end })
    end)
    return pg
end

V.makeItemPage = makeItemPage
