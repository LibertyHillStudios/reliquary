-- Reliquary's window: a character's Bags and Bank pages (docs/DESIGN.md, section 5). Each bag is a card:
-- its icon, its name and how full it is on the card's band, its slots in a grid of wells under it. The
-- cards flow left to right and wrap, each as big as what it holds, and the totals are chips along the
-- page's foot.
local ADDON, ns = ...

local V = ns.V
local Skin, Motion = ns.Skin, ns.Motion

local num, str, api = ns.num, ns.str, ns.api
local ipairs, type = ipairs, type
local floor, ceil, min, max, format = math.floor, math.ceil, math.min, math.max, string.format
local PAGE_WIDTH, ago, hideTip, itemButton, showItem, plural = V.PAGE_WIDTH, V.ago, V.hideTip, V.itemButton, V.showItem, V.plural

-- A bag's card, in units: slots 40 square and 4 apart, four across as a bag opens in the game; a
-- container of more than 24 slots (the bank's own) in the fewest rows the page's width allows, its
-- columns as even as they can be. Cards are 12 apart; the chips of the totals are under the cards,
-- 12 below them. The list leaves room at its right for its scroll bar.
local BAG = { slot = 40, gap = 4, cols = 4, most = 24, gutter = 12, foot = 20, scroll = 12 }
BAG.pitch = BAG.slot + BAG.gap
BAG.width = PAGE_WIDTH - BAG.scroll
BAG.widest = floor((BAG.width - 2 * Skin.SPACE.m + BAG.gap) / BAG.pitch)

local function cardWidth(cols) return 2 * Skin.SPACE.m + cols * BAG.pitch - BAG.gap end
local function cardHeight(rows) return Skin.ITEM_HEAD + 2 * Skin.SPACE.m + rows * BAG.pitch - BAG.gap end

-- How many columns a container's slots take.
local function columns(shown)
    if shown <= BAG.most then return BAG.cols end
    return ceil(shown / ceil(shown / BAG.widest))
end

-- The bags of a section (Share.lua's: each bag's size z, its index b, its own item it, its slots s) as
-- the page draws them: each a card with the name and icon the game gives the bag and how many of its
-- slots are full, laid out left to right in shelves, a shelf as tall as its tallest card. The keyring
-- shows the rows that hold keys, as the game's own keyring does (GetKeyRingSize).
local function bagShelves(section, bank)
    local shelves, shelf, x = {}, nil, 0
    local keyring = api("Enum.BagIndex.Keyring") or -1
    for _, bag in ipairs(section and section.list or {}) do
        local size, slots, used, last = num(bag.z) or 0, {}, 0, 0
        for slot = 1, size do
            local it = type(bag.s) == "table" and bag.s[slot]
            if type(it) == "table" and num(it.id) then
                slots[slot] = { id = it.id, s = it.s, q = it.q, icon = it.ic, n = it.c or 1, name = it.n }
                used, last = used + 1, slot
            end
        end
        local it = type(bag.it) == "table" and num(bag.it.id) and bag.it or nil
        if it and str(it.n) and it.n:find("(DNT)", 1, true) then it = nil end -- the game's stand-in for the bank, never a name to show
        local card = { slots = slots, item = it, icon = it and num(it.ic) or nil, q = it and num(it.q) or nil, value = format("%d / %d", used, size) }
        local shown = size
        if not bank and bag.b == keyring then
            card.name, card.icon = str(KEYRING) or "Keyring", "Interface\\ICONS\\ui-hud-actionbar-keyring"
            shown = last == 0 and 0 or min(size, last + (BAG.cols - last % BAG.cols) % BAG.cols)
        elseif not bank and bag.b == 0 then
            card.name, card.icon, card.atlas = str(BACKPACK_TOOLTIP) or "Backpack", "bag-main", true
        elseif not it and bank then
            card.name = str(BANK) or "Bank"
        else
            card.name = it and str(it.n) or (str(BAGSLOT) or "Bag")
        end
        if shown > 0 then
            card.shown, card.cols = shown, columns(shown)
            card.w, card.h = cardWidth(card.cols), cardHeight(ceil(shown / card.cols))
            if shelf and x + card.w > BAG.width then
                shelves[#shelves + 1] = shelf
                shelf = nil
            end
            if not shelf then shelf, x = { h = 0, cards = {} }, 0 end
            card.x = x
            shelf.cards[#shelf.cards + 1] = card
            shelf.h = max(shelf.h, card.h)
            x = x + card.w + BAG.gutter
        end
    end
    if shelf then shelves[#shelves + 1] = shelf end
    -- Each shelf with the room under it, the last one's too: the list's edge fades over that room
    -- before it reaches a card.
    for _, s in ipairs(shelves) do s.h = s.h + BAG.gutter end
    return shelves
end

-- A bag's card: its head shows the bag's own tooltip (its name, for the backpack, the keyring and the
-- bank's own slots), and a bag that is an item opens its page, as any item does here.
local function headEnter(self)
    local card = self.card
    local it = card and card.item
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    if it and it.s then GameTooltip:SetHyperlink(it.s)
    elseif it and it.id then GameTooltip:SetItemByID(it.id)
    else GameTooltip:SetText(card and card.name or "") end
    GameTooltip:Show()
end
local function headClick(self)
    local it = self.card and self.card.item
    if it and it.id and V.openItemPage then V.openItemPage({ id = it.id, q = it.q, ic = it.ic, n = it.n }, it.s or ("item:" .. it.id)) end
end

local function newCard(row)
    local c = Skin.itemCard(row)
    c.head:HookScript("OnEnter", headEnter)
    c.head:HookScript("OnLeave", hideTip)
    c.head:SetScript("OnClick", headClick)
    c.slots = {}
    return c
end

-- A shelf of cards, drawn into a row of the list: each card at its place, its slots in its grid, an
-- empty one a quiet well.
local function drawShelf(row, shelf)
    row.cards = row.cards or {}
    for i, card in ipairs(shelf.cards) do
        local c = row.cards[i] or newCard(row)
        row.cards[i] = c
        Motion.finish(c) -- a card still arriving lands before it moves
        c.head.card = card
        c:SetSize(card.w, card.h)
        c:ClearAllPoints()
        c:SetPoint("TOPLEFT", card.x, 0)
        c:SetHead(card.name, card.value, card.icon, card.atlas, card.q)
        c:Show()
        for k = 1, card.shown do
            local b = c.slots[k]
            if not b then
                b = itemButton(c.body, BAG.slot)
                c.slots[k] = b
            end
            local i0 = k - 1
            b:ClearAllPoints()
            b:SetPoint("TOPLEFT", (i0 % card.cols) * BAG.pitch, -floor(i0 / card.cols) * BAG.pitch)
            b:Show()
            showItem(b, card.slots[k], true)
        end
        for k = card.shown + 1, #c.slots do c.slots[k]:Hide() end
    end
    for i = #shelf.cards + 1, #row.cards do row.cards[i]:Hide() end
end

-- The page: makeDetail makes it, showDetail fills it (showItems).
function V.makeBags(d)
    local items = d.pages.items
    d.itemRows, d.itemsBar = Skin.scroll(items, { frameType = "Frame", right = BAG.scroll, bottom = BAG.foot + BAG.gutter, fade = Skin.SPACE.xl,
        init = drawShelf, extent = function(shelf) return shelf.h end })
    -- The totals along the foot: how many items, how many slots are free, and when the bank was seen.
    d.itemChips = {}
    for i = 1, 3 do
        local chip = Skin.chip(items)
        chip:Hide()
        d.itemChips[i] = chip
    end
end

local function showItems(d, section, keep, bank)
    local slots, free, n = 0, 0, 0
    local keyring = api("Enum.BagIndex.Keyring") or -1
    for _, bag in ipairs(section and section.list or {}) do
        if bank or bag.b ~= keyring then -- keys aren't bag space, as the game counts it
            slots = slots + (num(bag.z) or 0)
            for slot = 1, num(bag.z) or 0 do
                if type(bag.s) == "table" and bag.s[slot] then n = n + 1 else free = free + 1 end
            end
        end
    end
    d.itemRows:SetDataProvider(CreateDataProvider(bagShelves(section, bank)), keep)
    local words = { plural(n, "item", "items"), format("%d of %d slots free", free, slots) }
    if section and section.at then words[3] = "Seen at the bank " .. ago(section.at) end
    local x = 0
    for i, chip in ipairs(d.itemChips) do
        chip:SetShown(words[i] ~= nil)
        if words[i] then
            chip:Set(words[i])
            chip:ClearAllPoints()
            chip:SetPoint("BOTTOMLEFT", x, 0)
            x = x + chip.width + Skin.SPACE.s
        end
    end
    -- A player (or the window opening) arrives: the cards come in order, then the chips under them.
    if d.arriving then
        local order = 0
        for _, row in ipairs(d.itemRows:GetFrames()) do
            for _, c in ipairs(row.cards or {}) do
                if c:IsShown() then
                    order = order + 1
                    Motion.arrive(c, order, { delay = Motion.PAGE_AFTER })
                end
            end
        end
        for _, chip in ipairs(d.itemChips) do
            if chip:IsShown() then
                order = order + 1
                Motion.arrive(chip, order, { delay = Motion.PAGE_AFTER })
            end
        end
    end
end

V.showItems = showItems
