-- Reliquary's window: a character's Recipes page (docs/DESIGN.md, section 5), as the game's
-- Professions window shows them: left, the search over each profession's card, its bar and its
-- recipes as rows; right, the chosen recipe's card, what it makes on a big slot and each reagent on a
-- slot of its own with how many you have of how many it takes.
local ADDON, ns = ...

local V = ns.V
local Skin, Motion = ns.Skin, ns.Motion

local call, num, str, api = ns.call, ns.num, ns.str, ns.api
local ipairs, tostring = ipairs, tostring
local floor, min, max, format = math.floor, math.min, math.max, string.format
local sound, showItemTip, hideTip, itemButton, carried = V.sound, V.showItemTip, V.hideTip, V.itemButton, V.carried
local itemFace, qualityName, plural, PAGE_WIDTH, PAGE_HEIGHT = V.itemFace, V.qualityName, V.plural, V.PAGE_WIDTH, V.PAGE_HEIGHT

-- The page, in units: the list's column (its cards, and room for its scroll bar beside them), the
-- search over it; in a profession's head its name's line, the room under it to its bar and the bar,
-- the chevron that folds it; a recipe's icon, and the chosen one's gold bar; the chosen recipe's card:
-- what it makes on its slot, each reagent's slot, the room between reagents, and the most reagents a
-- recipe shows.
local RECIPE = { list = 300, bar = 12, search = 26, name = 13, progress = 6, chevron = 12, icon = 20, mark = { 3, 14 }, out = 56, slot = 36,
    pitch = 44, reagents = 7 }
RECIPE.card = PAGE_WIDTH - RECIPE.list - Skin.SPACE.l
RECIPE.barTop = Skin.SPACE.m + RECIPE.name + Skin.SPACE.s + 1 -- a head's bar, under its name
-- A card's foot, and the gap under it before the next card; a list row's height by kind (a
-- profession's head with its bar and without, a recipe, a card's foot, the note when nothing matches).
local FOOT = { card = Skin.SPACE.s, gap = Skin.SPACE.m }
local ROW = { head = 50, headBare = 36, recipe = 26, foot = FOOT.card + FOOT.gap, note = 30 }
-- Where the chosen recipe's reagents begin: under what it makes, a pixel line and their label.
local REAGENTS_TOP = Skin.SPACE.m + RECIPE.out + Skin.SPACE.m + Skin.CARD_HEAD + Skin.SPACE.s

-- A recipe's line: its icon and its name in the colour of what it makes (the game's, once it has the
-- item; the page draws again then).
local function recipeLine(d, prof, r)
    local face = r.o and itemFace(r.o, d.redrawSoon)
    local icon = face and face.icon or r.ic or num(call(api("C_Spell.GetSpellTexture"), r.id))
    local c = face and face.q and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[face.q]
    return { kind = "recipe", r = r, icon = icon, left = c and c.hex and (c.hex .. r.label .. "|r") or r.label, profName = prof.name,
        key = prof.name .. ":" .. tostring(r.id or r.label) }
end

-- Each profession's card: its head (its name, how many recipes it has, its skill on its bar), the
-- recipes the search finds, its foot. Returns the lines to show, and every recipe found (a folded
-- card's too: folding a card never changes the recipe chosen).
local function recipeLines(d, book)
    local out, found = {}, {}
    local q = d.craftQuery or ""
    for _, prof in ipairs(book) do
        if not d.craftOnly or d.craftOnly == prof.name then
            local rows = {}
            for _, r in ipairs(prof.recipes) do
                local hit = q == "" or r.label:lower():find(q, 1, true)
                for _, u in ipairs(not hit and r.u or {}) do
                    if itemFace(u.id, d.redrawSoon).name:lower():find(q, 1, true) then hit = true break end -- or once the game has its name
                end
                if hit then rows[#rows + 1] = recipeLine(d, prof, r) end
            end
            if #rows > 0 or q == "" then
                local folded = d.recipeFolds[prof.name] and true or false
                out[#out + 1] = { kind = "head", name = prof.name, sk = prof.sk, mx = prof.mx, count = plural(#prof.recipes, "recipe", "recipes"),
                    folded = folded, h = (prof.sk and prof.mx) and ROW.head or ROW.headBare }
                for _, row in ipairs(rows) do
                    found[#found + 1] = row
                    if not folded then out[#out + 1] = row end
                end
                out[#out + 1] = { kind = "foot", name = prof.name }
            end
        end
    end
    if #out == 0 then out[1] = { kind = "note", left = "No recipe matches that search." } end
    return out, found
end

-- The recipe chosen beside the list: what it makes on its slot (its page a click away), the
-- profession, and each reagent on its own slot with how many this character has in its bags and bank
-- of how many it takes, white when that's enough, as the game's Professions window shows them. A new
-- recipe's parts arrive in order.
local function showSchematic(d, line, arriving)
    local sc = d.schematic
    sc:SetShown(line ~= nil)
    if not line then return end
    local r = line.r
    local face = r.o and itemFace(r.o, d.redrawSoon)
    sc.out.rq = face and { id = face.id, link = "item:" .. face.id } or nil
    sc.out.spell = r.id
    SetItemButtonTexture(sc.out, line.icon)
    SetItemButtonQuality(sc.out, face and face.q)
    sc.out:SetQuality(face and face.q, true)
    sc.name:SetText(face and qualityName({ name = r.label, q = face.q }) or r.label)
    sc.prof:SetText(line.profName)
    -- The name (one line or two) and the profession under it, as one block centred on the slot.
    local nameH = sc.name:GetStringHeight() or 0
    local profH = sc.prof:GetLineHeight() or 0
    sc.name:SetHeight(max(nameH, 1))
    sc.name:ClearAllPoints()
    sc.name:SetPoint("TOPLEFT", sc.out, "RIGHT", Skin.SPACE.m, (nameH + Skin.SPACE.xs + profH) / 2)
    sc.name:SetPoint("RIGHT", sc, "RIGHT", -Skin.SPACE.m, 0)
    local short = DISABLED_REAGENT_COLOR or GRAY_FONT_COLOR
    local count = r.u and #r.u or 0
    -- The most reagents a recipe has still fit the page: closer together, on the 4-unit grid.
    local pitch = RECIPE.pitch
    if count > 1 then
        local room = (d.pageHeight or PAGE_HEIGHT) - REAGENTS_TOP - RECIPE.slot - Skin.SPACE.m
        pitch = min(pitch, floor(room / (count - 1) / 4) * 4)
    end
    local shown = 0
    for i, cell in ipairs(sc.cells) do
        local u = r.u and r.u[i]
        cell:SetShown(u ~= nil)
        if u then
            shown = i
            cell:ClearAllPoints()
            cell:SetPoint("TOPLEFT", Skin.SPACE.m, -(REAGENTS_TOP + (i - 1) * pitch))
            cell:SetPoint("RIGHT", -Skin.SPACE.m, 0)
            local f, need = itemFace(u.id, d.redrawSoon), u.n or 1
            local have = carried(u.id)
            cell.button.rq = { id = f.id, link = "item:" .. f.id }
            SetItemButtonTexture(cell.button, f.icon)
            SetItemButtonQuality(cell.button, f.q)
            cell.button:SetQuality(f.q, true)
            cell.name:SetText(format(str(TRADESKILL_REAGENT_COUNT) or "%s/%d", have, need) .. " " .. f.name)
            local c = have >= need and HIGHLIGHT_FONT_COLOR or short
            if c then cell.name:SetTextColor(c.r, c.g, c.b) end
        end
    end
    sc.label:SetShown(shown > 0)
    sc.rule:SetShown(shown > 0)
    -- The card as tall as what it holds.
    sc:SetHeight(shown > 0 and (REAGENTS_TOP + (shown - 1) * pitch + RECIPE.slot + Skin.SPACE.m) or (Skin.SPACE.m + RECIPE.out + Skin.SPACE.m))
    if arriving then
        local at = arriving == true and 0 or arriving
        Motion.arrive(sc.top, 1, { delay = at })
        if shown > 0 then Motion.arrive(sc.head, 2, { delay = at }) end
        for i = 1, shown do Motion.arrive(sc.cells[i], i + 2, { delay = at }) end
    end
end

-- A list row, as its line's kind draws it: a profession's head, a recipe, a card's foot, the note.
local function drawRow(d, row, line)
    row.line = line
    local kind = line.kind
    local carded = kind ~= "note"
    row.slice:SetShown(carded)
    if carded then row.slice:SetPart(kind == "head" and "top" or kind == "foot" and "bottom" or "middle", FOOT.gap) end
    row.inner:SetFrameLevel(row.slice:GetFrameLevel() + 1)
    row:EnableMouse(kind == "head" or kind == "recipe")
    local head, recipe = kind == "head", kind == "recipe"
    row.name:SetShown(head or recipe or kind == "note")
    row.count:SetShown(head)
    row.skill:SetShown(head and line.sk ~= nil and line.mx ~= nil)
    row.progress:SetShown(head and line.sk ~= nil and line.mx ~= nil)
    row.fold:SetShown(head and not line.folded)
    row.folded:SetShown(head and line.folded)
    row.tile:SetShown(recipe)
    Motion.stop(row.fill, "alpha")
    row.chosen = recipe and line.key == d.recipeKey
    row.fill:SetAlpha(row.chosen and 1 or 0)
    row.bar:SetShown(row.chosen)
    row.name:ClearAllPoints()
    if head then
        Skin.setRole(row.name, "heading")
        row.name:SetTextColor(Skin.rgb("parchment"))
        row.name:SetText(line.name)
        row.count:SetText(line.count)
        row.name:SetPoint("TOPLEFT", Skin.SPACE.m, -Skin.SPACE.m)
        -- The name, then how many recipes, as far as the skill at the right lets them reach.
        local right = Skin.SPACE.m + RECIPE.chevron + Skin.SPACE.s
        if row.skill:IsShown() then
            row.skill:SetText(format("%d / %d", line.sk, line.mx))
            right = right + (row.skill:GetStringWidth() or 0) + Skin.SPACE.s
            local was = d.recipeProfShown[line.name]
            if was then row.progress:Set(line.sk, line.mx, { from = was }) else row.progress:Set(line.sk, line.mx, { instant = true }) end
            d.recipeProfShown[line.name] = row.progress.target
        end
        local room = RECIPE.list - RECIPE.bar - Skin.SPACE.m - right
        local countW = (row.count:GetStringWidth() or 0) + Skin.SPACE.s
        row.name:SetWidth(max(1, min((row.name:GetStringWidth() or 0) + 1, room - countW)))
    elseif recipe then
        Skin.setRole(row.name, "body")
        row.name:SetTextColor(Skin.rgb("parchment"))
        row.name:SetText(line.left)
        row.name:SetPoint("LEFT", row.tile, "RIGHT", Skin.SPACE.s, 0)
        row.name:SetPoint("RIGHT", -Skin.SPACE.m, 0)
        row.tile:SetIcon(line.icon)
    elseif kind == "note" then
        Skin.setRole(row.name, "body")
        row.name:SetTextColor(Skin.rgb("dim"))
        row.name:SetText(line.left)
        row.name:SetPoint("LEFT", Skin.SPACE.xs, 0)
        row.name:SetPoint("RIGHT")
    end
    row.inner:SetAlpha(1)
end

-- The page: makeDetail makes it, showDetail fills it (V.showRecipes).
function V.makeRecipes(d)
    -- The search finds a recipe by its name or by what goes into it. A profession's head folds its card
    -- away and opens it again; a recipe shows what it makes on hover, and a click chooses it; every item
    -- beside the list opens its page.
    local craft = d.pages.craft
    d.recipeFolds, d.recipeProfShown = {}, {}
    d.recipeSearch = Skin.search(craft, SEARCH)
    d.recipeSearch:SetPoint("TOPLEFT")
    d.recipeSearch:SetWidth(RECIPE.list - RECIPE.bar)
    d.recipeSearch.onChange = function(text)
        d.craftQuery = (text or ""):lower()
        if d.redraw and d.pageSel == "craft" then d.redraw() end
    end
    local holder = CreateFrame("Frame", nil, craft)
    holder:SetPoint("TOPLEFT", 0, -(RECIPE.search + Skin.SPACE.m))
    holder:SetPoint("BOTTOMLEFT")
    holder:SetWidth(RECIPE.list)
    local function init(row, line)
        if not row.inner then
            row.slice = Skin.slice(row)
            row.inner = CreateFrame("Frame", nil, row)
            row.inner:SetAllPoints()
            -- Hover fills a recipe's row; the chosen one keeps the fill and the gold bar at its left, as a
            -- chosen row of the rail does (Skin.row).
            local x = Skin.SPACE.xs
            row.fill = Skin.nine(row.inner, "disc", { radius = Skin.RADIUS.control, layer = "BACKGROUND", color = "ink800", inset = { x, 1, x, 1 } })
            row.fill:SetAlpha(0)
            row.bar = row.inner:CreateTexture(nil, "ARTWORK", nil, 3)
            row.bar:SetTexture("Interface\\AddOns\\Reliquary\\Media\\ui-disc-16")
            row.bar:SetSize(RECIPE.mark[1], RECIPE.mark[2])
            row.bar:SetPoint("LEFT", x, 0)
            row.bar:SetVertexColor(Skin.rgb("gold300"))
            row.tile = Skin.tile(row.inner, RECIPE.icon)
            row.tile:SetPoint("LEFT", Skin.SPACE.m + Skin.SPACE.xs, 0)
            row.name = Skin.text(row.inner, "body")
            row.count = Skin.text(row.inner, "small")
            row.count:SetTextColor(Skin.rgb("dim"))
            row.count:SetPoint("BOTTOMLEFT", row.name, "BOTTOMRIGHT", Skin.SPACE.s, 1)
            row.skill = Skin.text(row.inner, "numeral", "RIGHT")
            -- Open, a chevron pointing down; folded, one pointing right.
            row.fold = Skin.glyph(row.inner, "chevronDown", RECIPE.chevron, "dim")
            row.fold:SetPoint("TOPRIGHT", -Skin.SPACE.m, -Skin.SPACE.m - 1)
            row.folded = Skin.glyph(row.inner, "chevronRight", RECIPE.chevron, "dim")
            row.folded:SetPoint("CENTER", row.fold)
            row.skill:SetPoint("TOPRIGHT", row.fold, "TOPLEFT", -Skin.SPACE.s, 1)
            row.progress = Skin.bar(row.inner, RECIPE.progress)
            row.progress:SetPoint("TOPLEFT", Skin.SPACE.m, -RECIPE.barTop)
            row.progress:SetPoint("TOPRIGHT", -Skin.SPACE.m, -RECIPE.barTop)
            row:SetScript("OnEnter", function(self)
                local l = self.line
                if not l then return end
                if l.kind == "head" then
                    Skin.tint(self.fold, "glyph", "parchment")
                    Skin.tint(self.folded, "glyph", "parchment")
                    return
                end
                local r = l.r
                if not r then return end
                if not self.chosen then Motion.fade(self.fill, 1, { dur = "fast", from = self.fill.alpha or 0, set = function(n, v) n:SetAlpha(v) end, owner = self }) end
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                if r.o then GameTooltip:SetItemByID(r.o) else GameTooltip:SetSpellByID(r.id) end
                -- Everything it is made with, under what it makes.
                if r.u and #r.u > 0 then
                    GameTooltip:AddLine(" ")
                    GameTooltip:AddLine("Reagents", 1, 0.82, 0)
                    for _, u in ipairs(r.u) do GameTooltip:AddLine(format("%d %s", u.n or 1, itemFace(u.id).name), 1, 1, 1) end
                end
                GameTooltip:Show()
            end)
            row:SetScript("OnLeave", function(self)
                local l = self.line
                if l and l.kind == "head" then
                    Skin.tint(self.fold, "glyph", "dim")
                    Skin.tint(self.folded, "glyph", "dim")
                end
                if not self.chosen then Motion.fade(self.fill, 0, { dur = "fast", from = self.fill.alpha or 0, set = function(n, v) n:SetAlpha(v) end, owner = self }) end
                hideTip()
            end)
            row:SetScript("OnClick", function(self)
                local l = self.line
                if not l then return end
                if l.kind == "head" then return d.foldRecipes(l.name) end
                if not l.r or d.recipeKey == l.key then return end
                d.recipeKey = l.key
                d.recipeChosen = true
                sound("IG_MAINMENU_OPTION_CHECKBOX_ON")
                if d.redraw then d.redraw() end
            end)
        end
        drawRow(d, row, line)
    end
    d.recipes, d.recipesBar = Skin.scroll(holder, { frameType = "Button", right = RECIPE.bar, init = init, fade = Skin.SPACE.xl,
        extent = function(line)
            local h = line.h or ROW[line.kind] or ROW.recipe
            return line.kind == "recipe" and line.open and max(0.5, h * line.open) or h
        end })
    -- A profession's head folds its card: the recipes' rows ease shut (or open) as they fade, and the
    -- head's chevron turns at once. A card still moving turns back from where it is.
    function d.foldRecipes(name)
        local shut = not d.recipeFolds[name]
        d.recipeFolds[name] = shut or nil
        sound(shut and "IG_MAINMENU_OPTION_CHECKBOX_OFF" or "IG_MAINMENU_OPTION_CHECKBOX_ON")
        if not Motion.enabled() then d.redraw() return end
        for _, f in ipairs(d.recipes:GetFrames()) do
            if f.line and f.line.kind == "head" and f.line.name == name then
                f.fold:SetShown(not shut)
                f.folded:SetShown(shut)
            end
        end
        local channel = "fold:" .. name
        local was = Motion.value(d.recipes, channel)
        Motion.stop(d.recipes, channel)
        -- Opening a folded card: its rows are listed again, from nothing.
        if not shut and not was then
            d.recipeOpening = name
            d.redraw()
            d.recipeOpening = nil
        end
        local moving = {}
        for _, l in ipairs(d.recipeLines or {}) do if l.kind == "recipe" and l.profName == name then moving[#moving + 1] = l end end
        local function set(_, v)
            for _, l in ipairs(moving) do l.open = v end
            -- Between its ends the rows' heights change: each row takes its new height and the list lays
            -- them out again (at its ends the list is as it was drawn). Their words are gone by the time
            -- the rows are half shut, and come back once they're half open.
            local between = v > 0 and v < 1
            local seen = min(1, max(0, 2 * v - 1))
            for _, f in ipairs(d.recipes:GetFrames()) do
                if f.line and f.line.kind == "recipe" and f.line.profName == name then
                    f.inner:SetAlpha(seen)
                    if between then f:SetHeight(max(0.5, ROW.recipe * v)) end
                end
            end
            if between then d.recipes:FullUpdate(ScrollBoxConstants.UpdateImmediately) end
        end
        Motion.to(d.recipes, channel, shut and 0 or 1, { from = was or (shut and 1 or 0), dur = "slow", ease = "out", set = set,
            done = function() for _, l in ipairs(moving) do l.open = nil end d.redraw() end })
    end

    -- The recipe chosen, on a card of its own: what it makes and its name over a pixel line, then its
    -- reagents under their label.
    local sc = Skin.card(craft)
    sc:SetPoint("TOPLEFT", RECIPE.list + Skin.SPACE.l, 0)
    sc:SetWidth(RECIPE.card)
    d.schematic = sc
    sc.top = CreateFrame("Frame", nil, sc)
    sc.top:SetPoint("TOPLEFT")
    sc.top:SetPoint("RIGHT")
    sc.top:SetHeight(Skin.SPACE.m + RECIPE.out + Skin.SPACE.m)
    sc.out = itemButton(sc.top, RECIPE.out)
    sc.out:SetPoint("TOPLEFT", Skin.SPACE.m, -Skin.SPACE.m)
    -- A recipe that makes no item (an enchantment) shows its spell.
    sc.out:SetScript("OnEnter", function(self)
        if self.rq then return showItemTip(self) end
        if not self.spell then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetSpellByID(self.spell)
        GameTooltip:Show()
    end)
    sc.name = Skin.text(sc.top, "title")
    sc.name:SetWordWrap(true)
    sc.name:SetMaxLines(2)
    sc.name:SetJustifyV("TOP")
    sc.name:SetWidth(RECIPE.card - RECIPE.out - 3 * Skin.SPACE.m)
    sc.prof = Skin.text(sc.top, "dim")
    sc.prof:SetPoint("TOPLEFT", sc.name, "BOTTOMLEFT", 0, -Skin.SPACE.xs)
    sc.prof:SetPoint("RIGHT", -Skin.SPACE.m, 0)
    sc.head = CreateFrame("Frame", nil, sc)
    sc.head:SetPoint("TOPLEFT", 0, -(Skin.SPACE.m + RECIPE.out + Skin.SPACE.m))
    sc.head:SetPoint("RIGHT")
    sc.head:SetHeight(Skin.CARD_HEAD)
    sc.rule = Skin.line(sc.head, "ink600")
    sc.rule:SetPoint("TOPLEFT", Skin.SPACE.m, 0)
    sc.rule:SetPoint("TOPRIGHT", -Skin.SPACE.m, 0)
    sc.label = Skin.text(sc.head, "label")
    sc.label:SetPoint("TOPLEFT", Skin.SPACE.m, -(Skin.SPACE.m + 2))
    Skin.label(sc.label, "Reagents")
    sc.cells = {}
    for i = 1, RECIPE.reagents do
        local cell = CreateFrame("Frame", nil, sc)
        cell:SetHeight(RECIPE.slot)
        cell.button = itemButton(cell, RECIPE.slot)
        cell.button:SetPoint("LEFT")
        cell.name = Skin.text(cell, "body")
        cell.name:SetWordWrap(true)
        cell.name:SetMaxLines(2)
        cell.name:SetPoint("LEFT", cell.button, "RIGHT", Skin.SPACE.m, 0)
        cell.name:SetPoint("RIGHT")
        sc.cells[i] = cell
    end
    -- A new player's recipes, or the page coming into view, arrive again.
    craft:HookScript("OnHide", function() d.recipesShown = nil end)
end

function V.showRecipes(d, book, keep)
    -- Another player: every card open again.
    if d.recipeFoldsFor ~= d.who then d.recipeFolds, d.recipeFoldsFor = {}, d.who end
    -- A new search, or another profession, starts at the top of what it finds. The recipe chosen
    -- stays chosen while the search finds it, else the first found is.
    local same = d.drawnQuery == (d.craftQuery or "") and d.drawnOnly == d.craftOnly
    d.drawnQuery, d.drawnOnly = d.craftQuery or "", d.craftOnly
    local lines, found = recipeLines(d, book)
    -- A card opening: its rows start from nothing (foldRecipes eases them open).
    if d.recipeOpening then
        for _, l in ipairs(lines) do if l.kind == "recipe" and l.profName == d.recipeOpening then l.open = 0.001 end end
    end
    d.recipeLines = lines
    local chosen = nil
    for _, line in ipairs(found) do if line.key == d.recipeKey then chosen = line end end
    chosen = chosen or found[1]
    d.recipeKey = chosen and chosen.key or nil
    -- The gold bar glides from the recipe chosen before to the one chosen now.
    local wasTop
    if d.recipeChosen then
        for _, f in ipairs(d.recipes:GetFrames()) do if f.chosen and f:IsVisible() then wasTop = f:GetTop() end end
    end
    d.recipes:SetDataProvider(CreateDataProvider(lines), same and keep or nil)
    local fresh = d.arriving or d.recipesShown ~= d.who
    d.recipesShown = d.who
    local base = d.arriving and Motion.PAGE_AFTER or 0
    local n = 0
    for _, f in ipairs(d.recipes:GetFrames()) do
        if f.chosen and wasTop then Skin.glide(f, wasTop) end
        if fresh and f:IsVisible() then
            -- The cards fade in a row at a time, each row's words rising into it; the bars fill from nothing.
            n = n + 1
            Motion.fade(f.slice, 1, { from = 0, dur = "base", ease = "enter", delay = base + Motion.delay(n) })
            Motion.arrive(f.inner, n, { delay = base })
            if f.line.kind == "head" and f.progress:IsShown() then
                f.progress:Set(f.line.sk, f.line.mx, { from = 0, delay = base + Motion.delay(n) })
            end
        end
    end
    local picked = d.recipeChosen
    d.recipeChosen = nil
    showSchematic(d, chosen, fresh and (base + Motion.delay(min(n, Motion.STAGGER_MOST) + 1)) or picked)
    if fresh then Motion.fade(d.schematic, 1, { from = 0, dur = "base", ease = "enter", delay = base + Motion.delay(min(n, Motion.STAGGER_MOST) + 1) }) end
end
