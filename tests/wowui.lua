-- A stand-in for WoW: Forever's interface widgets, strict about what exists. Calling a method the
-- game's widget of that kind doesn't have is an error (the list in widget_api.lua comes from
-- Blizzard's documentation for the build), and so are an unknown template, an unknown frame type
-- and a misspelled anchor point. It keeps what a test looks at: what is shown, texts, scripts,
-- checked boxes, the item each item button shows, and where each region is: its anchors and size
-- laid out as the game lays them out (M.rect), so a test can find what lies over something else
-- (M.overlaps) or runs out of the window (M.outside). Text is measured from its length.
--
--     local ui = dofile("tests/wowui.lua")(env)  -- puts CreateFrame and friends into env
local here = debug.getinfo(1, "S").source:match("^@(.*/)") or "./"
local API = dofile(here .. "widget_api.lua")

return function(env)
    local M = { frames = {}, regions = {} }
    local allowed = {}
    for kind, names in pairs(API) do
        local set = {}
        for _, n in ipairs(names) do set[n] = true end
        allowed[kind] = set
    end
    allowed.ItemButton, allowed.EventFrame, allowed.DropdownButton = allowed.Button, allowed.Frame, allowed.Button
    -- Where the addon's own files are, for a font it ships (tests/ is beside addon/).
    local ADDON_DIR = here .. "../addon/Reliquary/"
    local POINTS = { TOPLEFT = true, TOP = true, TOPRIGHT = true, LEFT = true, CENTER = true, RIGHT = true, BOTTOMLEFT = true, BOTTOM = true, BOTTOMRIGHT = true }

    local does = {} -- methods with an effect a test can see; any other documented method does nothing
    function does.Show(w)
        if w._shown then return end
        w._shown = true
        if w._scripts.OnShow then w._scripts.OnShow(w) end
    end
    function does.Hide(w)
        if not w._shown then return end
        w._shown = false
        if w._scripts.OnHide then w._scripts.OnHide(w) end
    end
    function does.SetShown(w, v) if v then does.Show(w) else does.Hide(w) end end
    function does.IsShown(w) return w._shown end
    function does.IsVisible(w)
        local p = w
        while type(p) == "table" and p._kind do
            if not p._shown then return false end
            p = p._parent
        end
        return true
    end
    function does.SetText(w, t) w._text = t end
    function does.SetTextColor(w, r, g, b, a) w._textColor = { r, g, b, a } end
    function does.GetTextColor(w)
        local c = w._textColor or (type(w._font) == "table" and w._font ~= w and w._font._textColor) or { 1, 1, 1, 1 }
        return c[1], c[2], c[3], c[4] or 1
    end
    function does.SetVertexColor(w, r, g, b, a) w._vertex = { r, g, b, a } end
    function does.GetVertexColor(w) local c = w._vertex or { 1, 1, 1 } return c[1], c[2], c[3], c[4] or 1 end
    function does.SetBlendMode(w, mode) w._blend = mode end
    -- A font object brings its own alignment, as in the game (Blizzard's code sets the alignment again
    -- after changing a font): the game's fonts say none, so text is centred until told otherwise.
    function does.SetFontObject(w, f)
        if type(f) == "string" and type(env[f]) == "table" and env[f]._kind == "Font" then f = env[f] end
        w._font, w._justifyH = f, nil
    end
    -- A font file loads when the game has it (its own Fonts folder) or the addon ships it.
    function M.fontLoads(file)
        if type(file) ~= "string" then return false end
        if file:match("^Fonts\\") then return true end
        local own = file:match("^Interface\\AddOns\\Reliquary\\(.+)$")
        if not own then return false end
        local f = io.open(ADDON_DIR .. own:gsub("\\", "/"), "rb")
        if f then f:close() return true end
        return false
    end
    function does.SetFont(w, file, size, flags)
        if not M.fontLoads(file) then return false end
        w._fontFile, w._size, w._flags = file, size, flags
        if w._kind == "FontString" then w._font = w end
        return true
    end
    function does.GetFont(w) return w._fontFile, w._size, w._flags end
    function does.SetShadowOffset(w, x, y) w._shadow = { x, y } end
    function does.SetJustifyH(w, j) w._justifyH = j end
    function does.GetJustifyH(w) return w._justifyH or "CENTER" end
    function does.SetWordWrap(w, v) w._wrap = v and true or false end
    function does.SetMaxLines(w, n) w._maxLines = n end
    function does.SetMaxBytes(w, n) w._maxBytes = n end
    function does.SetVisibleTextByteLimit(w, n) w._visibleBytes = n end
    function does.SetSpacing(w, n) w._spacing = n end
    function does.EnableMouse(w, v) w._mouse = v and true or false end
    function does.GetText(w) return w._text end
    function does.SetScript(w, name, fn) w._scripts[name] = fn end
    function does.GetScript(w, name) return w._scripts[name] end
    function does.HookScript(w, name, fn)
        local old = w._scripts[name]
        w._scripts[name] = old and function(...) old(...) fn(...) end or fn
    end
    -- A disabled button takes no clicks (M.run), as in the game.
    function does.Disable(w) w._disabled = true end
    function does.Enable(w) w._disabled = nil end
    function does.SetEnabled(w, v) w._disabled = not v or nil end
    function does.IsEnabled(w) return not w._disabled end
    function does.SetChecked(w, v) w._checked = v and true or false end
    function does.GetChecked(w) return w._checked end
    -- A texture keeps its draw layer and sublevel (CreateTexture's name, layer, template, sublevel).
    function does.CreateTexture(w, _, layer, _, sub)
        local t = M.new("Texture", nil, w)
        t._layer, t._sub = layer or "ARTWORK", sub or 0
        return t
    end
    function does.SetDrawLayer(w, layer, sub) w._layer, w._sub = layer, sub or 0 end
    function does.GetDrawLayer(w) return w._layer, w._sub end
    function does.CreateFontString(w, _, _, font)
        local fs = M.new("FontString", nil, w)
        fs._font = font
        return fs
    end
    function does.GetParent(w) return w._parent end
    -- The frames made with w as their parent, in the order they were made (its textures and texts are
    -- its regions, not its children).
    function does.GetChildren(w)
        local out = {}
        for _, f in ipairs(M.frames) do if f._parent == w then out[#out + 1] = f end end
        return unpack(out)
    end
    function does.GetName(w) return w._name end
    function does.SetID(w, id) w._id = id end
    function does.GetID(w) return w._id or 0 end
    function does.SetAlpha(w, a) w._alpha = a end
    function does.GetAlpha(w) return w._alpha or 1 end
    function does.RegisterEvent(w, e) w._events[e] = true end
    function does.UnregisterEvent(w, e) w._events[e] = nil end
    function does.IsEventRegistered(w, e) return w._events[e] == true end
    function does.SetWidth(w, v) w._w = v end
    function does.SetHeight(w, v) w._h = v end
    function does.SetSize(w, a, b) w._w, w._h = a, b end
    local function own(w)
        local s, p = 1, w
        while type(p) == "table" and p._kind do s, p = s * (p._scale or 1), p._parent end
        return s
    end
    function does.GetWidth(w)
        if w._w then return w._w end
        local r = M.rect(w)
        return r and (r.right - r.left) / own(w) or 0
    end
    function does.GetHeight(w)
        if w._h then return w._h end
        local r = M.rect(w)
        return r and (r.top - r.bottom) / own(w) or 0
    end
    function does.GetTop(w) local r = M.rect(w) return r and r.top / own(w) end
    function does.GetBottom(w) local r = M.rect(w) return r and r.bottom / own(w) end
    function does.GetLeft(w) local r = M.rect(w) return r and r.left / own(w) end
    function does.GetRight(w) local r = M.rect(w) return r and r.right / own(w) end
    -- A model shows a unit (the played character's), turned to a rotation.
    function does.SetUnit(w, unit) w._unit = unit end
    function does.ClearModel(w) w._unit = nil end
    function does.SetRotation(w, r) w._rotation = r end
    function does.SetValue(w, v) w._value = v end
    function does.GetValue(w) return w._value end
    function does.SetMinMaxValues(w, a, b) w._min, w._max = a, b end
    function does.SetTexture(w, t) w._texture = t end
    function does.SetAtlas(w, a) w._atlas = a end
    function does.SetTexCoord(w, ...) w._texCoord = { ... } end
    function does.SetClipsChildren(w, clips) w._clips = clips and true or false end
    function does.DoesClipChildren(w) return w._clips or false end
    function does.SetScale(w, s) w._scale = s end
    -- Frame levels: one above the parent's unless set.
    function does.SetFrameLevel(w, n) w._level = n end
    function does.GetFrameLevel(w)
        if w._level then return w._level end
        local p = w._parent
        return (type(p) == "table" and p._kind and does.GetFrameLevel(p) or 0) + 1
    end
    -- A button's own textures (its NormalTexture and the rest).
    function does.GetNormalTexture(w) return w._normal end
    function does.GetPushedTexture(w) return w._pushed end
    function does.GetHighlightTexture(w) return w._highlight end
    function does.GetScale(w) return w._scale or 1 end
    function does.GetEffectiveScale(w)
        local s, p = 1, w
        while type(p) == "table" and p._kind do s, p = s * (p._scale or 1), p._parent end
        return s
    end
    -- A texture's masks (the portrait frame's circle), and whether it snaps to whole pixels.
    function does.CreateMaskTexture(w) return M.new("MaskTexture", nil, w) end
    function does.AddMaskTexture(w, mask)
        w._masks = w._masks or {}
        w._masks[#w._masks + 1] = mask
    end
    function does.RemoveMaskTexture(w, mask)
        for i, m in ipairs(w._masks or {}) do if m == mask then table.remove(w._masks, i) break end end
    end
    function does.SetSnapToPixelGrid(w, v) w._snap = v end
    function does.SetTexelSnappingBias(w, v) w._snapBias = v end
    -- Anchors as the game takes them: (point), (point, x, y), (point, relativeTo [, relativePoint] [, x, y]).
    function does.SetPoint(w, point, ...)
        if not POINTS[point] then error("SetPoint: no anchor point called " .. tostring(point), 2) end
        local a, b, c, d = ...
        local rel, relPoint, x, y
        if type(a) == "number" or a == nil then
            x, y = a, b
        else
            rel = a
            if type(rel) == "string" then
                if POINTS[rel] then return end
                rel = env[rel]
            end
            if type(b) == "string" then
                if not POINTS[b] then error("SetPoint: no anchor point called " .. b, 2) end
                relPoint, x, y = b, c, d
            else
                x, y = b, c
            end
        end
        w._points = w._points or {}
        w._points[point] = { rel = rel or w._parent, relPoint = relPoint or point, x = x or 0, y = y or 0 }
        w._cover = nil
    end
    function does.ClearAllPoints(w) w._points, w._cover = nil, nil end
    function does.GetNumPoints(w)
        local n = 0
        for _ in pairs(w._points or {}) do n = n + 1 end
        return n
    end
    function does.GetPoint(w, i)
        local list = {}
        for point, a in pairs(w._points or {}) do list[#list + 1] = { point, a } end
        table.sort(list, function(x, y) return x[1] < y[1] end)
        local e = list[i or 1]
        if not e then return nil end
        return e[1], e[2].rel, e[2].relPoint, e[2].x, e[2].y
    end
    function does.SetAllPoints(w, rel)
        rel = rel or w._parent
        w._points = { TOPLEFT = { rel = rel, relPoint = "TOPLEFT", x = 0, y = 0 }, BOTTOMRIGHT = { rel = rel, relPoint = "BOTTOMRIGHT", x = 0, y = 0 } }
        w._cover = rel -- a frame laid over a text, for its hover, covers it by design
    end
    -- Its centre on the screen, as the game gives it for a region at scale 1 (nil until it's placed).
    function does.GetCenter(w)
        local r = M.rect(w)
        if not r then return nil end
        return (r.left + r.right) / 2, (r.top + r.bottom) / 2
    end
    function does.GetStringWidth(w) return M.textWidth(w) end
    function does.GetLineHeight(w) return M.fontSize(w) end
    function does.GetStringHeight(w)
        local lines = M.lineCount(w, w._w)
        return lines * M.fontSize(w) + (lines - 1) * (w._spacing or 0)
    end
    function does.CreateLine(w) return M.new("Line", nil, w) end
    -- Cut short: one line wider than its room, or more lines than it may show.
    function does.IsTruncated(w)
        local r = M.rect(w)
        if not r then return false end
        local s, p = 1, w
        while type(p) == "table" and p._kind do s, p = s * (p._scale or 1), p._parent end
        local width = (r.right - r.left) / s
        if w._wrap == false then return M.textWidth(w) > width + 0.5 end
        if not (w._maxLines and w._maxLines > 0) then return false end
        local most = w._maxLines
        w._maxLines = nil
        local lines = M.lineCount(w, width)
        w._maxLines = most
        return lines > most
    end

    local widget = {}
    widget.__index = function(w, key)
        local mixin = rawget(w, "_mixin")
        if mixin and mixin[key] then return mixin[key] end
        if allowed[w._kind][key] then return does[key] or function() end end
        if type(key) == "string" and key:match("^%u") then
            error(("%s has no method or part called %s"):format(w._kind, key), 2)
        end
        return nil
    end

    local templates = {}
    function templates.ButtonFrameTemplate(w)
        w.Inset = M.new("Frame", nil, w)
        w.Inset:SetPoint("TOPLEFT", 4, -60) -- as SharedUIPanelTemplates.xml has it
        w.Inset:SetPoint("BOTTOMRIGHT", -6, 26)
        -- The portrait, as PortraitFrameBaseTemplate has it: 62 square at (-5, 7), under a circle mask.
        w.PortraitContainer = M.new("Frame", nil, w)
        w.PortraitContainer:SetSize(1, 1)
        w.PortraitContainer:SetPoint("TOPLEFT")
        w.PortraitContainer.portrait = M.new("Texture", nil, w.PortraitContainer)
        w.PortraitContainer.portrait:SetSize(62, 62)
        w.PortraitContainer.portrait:SetPoint("TOPLEFT", -5, 7)
        w.PortraitContainer.CircleMask = { _mask = "Interface\\CharacterFrame\\TempPortraitAlphaMask" }
        w.PortraitContainer.portrait._masks = { w.PortraitContainer.CircleMask }
        w.CloseButton = M.new("Button", nil, w)
        w.CloseButton:SetSize(24, 24)
        w.CloseButton:SetPoint("TOPRIGHT", -2, -2)
        w._mixin = {
            SetTitle = function(self, t) self._title = t end,
            SetPortraitToAsset = function(self, t) self._portrait = t end,
        }
    end
    function templates.PanelTabButtonTemplate(w, parent)
        rawset(parent, "Tabs", rawget(parent, "Tabs") or {})
        table.insert(parent.Tabs, w)
        w._w, w._h = 100, 32
        w.Text = M.new("FontString", nil, w)
    end
    function templates.UICheckButtonTemplate(w)
        w._w, w._h = 32, 32
        w.Text = M.new("FontString", nil, w)
        w.Text._font = "GameFontNormalSmall"
        w.Text:SetPoint("LEFT", w, "RIGHT", 0, 1)
    end
    -- The Settings panel's small tabs (Shared/Tabs/MinimalTab.xml): 37 high, selected by SetSelected.
    function templates.MinimalTabTemplate(w)
        w._w, w._h = 40, 37
        w.Text = M.new("FontString", nil, w)
        w.Text._font = "GameFontNormalSmall"
        w.Text:SetPoint("BOTTOM", 0, 4)
        w._selected = false
        w._scripts.OnEnter, w._scripts.OnLeave = function() end, function() end -- MinimalTabMixin's own, which hooks add to
        w._mixin = {
            SetSelected = function(self, v) self._selected = v and true or false end, -- SelectableButtonMixin
            IsSelected = function(self) return self._selected == true end,
        }
    end
    -- The coloured bar of the character sheet and the Skills and Reputation lists (Camelot only).
    function templates.ColoredProgressBarTemplate(w)
        w._w, w._h = 67, 29
        w.Text = M.new("FontString", nil, w)
        w.Text._font = "GameFontHighlight"
        w.Text:SetPoint("LEFT")
        w.Text:SetPoint("RIGHT")
        w.Fill = M.new("Texture", nil, w)
        w.FillArea = M.new("Frame", nil, w)
        w._mixin = {
            SetFillPercent = function(self, p)
                assert(type(p) == "number" and p == p, "SetFillPercent needs a number")
                self._fill = math.min(1, math.max(0, p))
            end,
            SetText = function(self, t) self.Text:SetText(t) end,
            SetFillTextureByColorType = function(self, kind) self._colorType = kind end,
        }
    end
    -- The game's dropdown (Blizzard_Menu): a menu built by a generator each time it opens, with
    -- radio choices; it shows the selected choice's text.
    function templates.WowStyle1DropdownTemplate(w)
        w._w, w._h = 150, 26
        w._mixin = {
            SetupMenu = function(self, generator)
                assert(type(generator) == "function", "SetupMenu needs a generator")
                self._generator = generator
            end,
            GenerateMenu = function() end,
            SetDefaultText = function(self, t) self._default = t end,
        }
    end
    function templates.SearchBoxTemplate() end
    function templates.TooltipBackdropTemplate() end -- SharedTooltipTemplates.xml: the game's tooltip box
    function templates.InputBoxTemplate() end
    -- InputBoxTemplates.xml: an InputBoxTemplate with its prompt, shown while the box is empty.
    function templates.InputBoxInstructionsTemplate(w)
        w.Instructions = M.new("FontString", nil, w)
    end
    function templates.UIPanelButtonTemplate() end
    function templates.MinimalScrollBar(w)
        w._w = 8
        -- Its parts where the XML puts them. They are the bar's own and show only while there is
        -- something to scroll, so they stand in as frames the layout checks pass over.
        w.Track = M.new("Frame", nil, w)
        w.Track:SetPoint("TOP", 0, -19)
        w.Track:SetPoint("BOTTOM", 0, 19)
        w.Track:SetWidth(8)
        w.Track.Thumb = M.new("Frame", nil, w.Track)
        w.Track.Thumb:SetPoint("TOP")
        w.Track.Thumb:SetSize(8, 23)
        for _, part in ipairs({ w.Track, w.Track.Thumb }) do
            for _, key in ipairs({ "Begin", "Middle", "End" }) do part[key] = M.new("Texture", nil, part) end
        end
        w.Back, w.Forward = M.new("Frame", nil, w), M.new("Frame", nil, w)
        w.Back:SetPoint("TOP")
        w.Forward:SetPoint("BOTTOM")
        w.Back:SetSize(17, 11)
        w.Forward:SetSize(17, 11)
        w._mixin = {
            SetHideIfUnscrollable = function(self, v) self._hideIfUnscrollable = v and true or false end,
            SetInterpolateScroll = function(self, v) self._interpolate = v and true or false end,
        }
    end
    function templates.WowScrollBoxList(w)
        w._pool, w._rows = {}, {}
        w._mixin = {
            -- Like the real list: every element gets a frame from a pool, and its initializer runs.
            SetDataProvider = function(self, provider, retain)
                assert(type(provider) == "table" and provider._items, "SetDataProvider needs a data provider")
                self._provider, self._keep = provider, retain
                if not retain then self._atEnd = false end -- a new list starts at its top, as the game's does
                local view = assert(self._view, "a list used before ScrollUtil.InitScrollBoxListWithScrollBar")
                self._rows = {}
                local y = 0
                for i, element in ipairs(provider._items) do
                    local frame = self._pool[i] or M.new(view._frameType, nil, self)
                    self._pool[i] = frame
                    frame._shown = true
                    frame._extent = view._extent
                    if view._extentOf then
                        local h = view._extentOf(i, element)
                        assert(type(h) == "number" and h > 0, "an element with no height")
                        frame._extent = h
                    end
                    -- Stacked top down from the list's top, as the list lays them out unscrolled.
                    frame._list, frame._listTop = self, y
                    y = y + (frame._extent or 0)
                    view._init(frame, element)
                    self._rows[i] = frame
                end
                for i = #provider._items + 1, #self._pool do self._pool[i]._shown = false end
            end,
            GetDataProvider = function(self) return self._provider end,
            -- ScrollBoxBaseMixin's: the rows it has frames for now, those it would cut off left out.
            GetFrames = function(self)
                local out = {}
                for _, row in ipairs(self._rows) do if M.rect(row) then out[#out + 1] = row end end
                return out
            end,
            SetInterpolateScroll = function(self, v) self._interpolate = v and true or false end,
            -- ScrollBox.lua's: its rows fade out over this many units at an edge with more beyond it.
            SetEdgeFadeLength = function(self, n) self._edgeFade = n end,
            -- ScrollBox.lua's: how strongly its top and foot fade, from how far down it is scrolled.
            CalculateEdgeFade = function(self)
                local p, first, second = self:GetScrollPercentage(), 1, 1
                if p < 0.15 then first = math.max(0, math.min(1, p / 0.15)) end
                if p > 0.85 then second = 1 - math.max(0, math.min(1, (p - 0.85) / 0.15)) end
                return first, second
            end,
            -- ScrollBox.lua's: scrolled to its last row, and how far down it is (0 to 1).
            ScrollToEnd = function(self) self._atEnd = true end,
            GetScrollPercentage = function(self) return self._atEnd and 1 or 0 end,
            HasScrollableExtent = function(self)
                local r, total = M.rect(self), 0
                for _, row in ipairs(self._rows) do total = total + (row._extent or 0) end
                return r ~= nil and total > r.top - r.bottom
            end,
        }
    end

    function M.new(kind, name, parent, template)
        if not allowed[kind] then error("CreateFrame: no frame type " .. tostring(kind), 3) end
        local w = setmetatable({ _kind = kind, _name = name, _parent = parent, _shown = true, _scripts = {}, _events = {} }, widget)
        if kind == "DropdownButton" and not template then
            w._mixin = {
                SetupMenu = function(self, generator)
                    assert(type(generator) == "function", "SetupMenu needs a generator")
                    self._generator = generator
                end,
                GenerateMenu = function() end,
            }
        end
        if kind == "ItemButton" then
            w._w, w._h = 37, 37
            -- Its parts, as Blizzard_ItemButton's ItemButtonTemplate.xml has them.
            w.icon = M.new("Texture", nil, w)
            w.icon:SetAllPoints()
            w.Mask = M.new("MaskTexture", nil, w)
            w.Mask:SetAllPoints()
            w.icon._masks = { w.Mask }
            w.Count = M.new("FontString", nil, w)
            w.Count:SetPoint("BOTTOMRIGHT", -5, 2)
            w.IconBorder = M.new("Texture", nil, w)
            w.IconBorder:SetAllPoints()
            w.searchOverlay = M.new("Texture", nil, w)
            w.searchOverlay:SetAllPoints()
            w._normal, w._pushed, w._highlight = M.new("Texture", nil, w), M.new("Texture", nil, w), M.new("Texture", nil, w)
            -- The game's ItemButtonMixin: a search darkens what doesn't match.
            w._mixin = { SetMatchesSearch = function(self, v) self._matches = v end, GetMatchesSearch = function(self) return self._matches end }
        end
        M.regions[#M.regions + 1] = w
        if template then
            for t in tostring(template):gmatch("[^,%s]+") do
                if not templates[t] then error("CreateFrame: no template " .. t .. " in the test client", 3) end
                templates[t](w, parent)
            end
        end
        if kind ~= "Texture" and kind ~= "FontString" and kind ~= "MaskTexture" then M.frames[#M.frames + 1] = w end
        if name then env[name] = w end
        return w
    end

    function M.fire(event, ...)
        for _, f in ipairs(M.frames) do
            if f._events[event] and f._scripts.OnEvent then f._scripts.OnEvent(f, event, ...) end
        end
    end

    -- A dropdown's choices as its menu would list them: { label, selected, pick }.
    function M.menu(w)
        local list = {}
        local root = {}
        function root:CreateRadio(label, isSelected, setSelected, data)
            assert(type(label) == "string" and type(isSelected) == "function" and type(setSelected) == "function", "CreateRadio needs a label and two functions")
            list[#list + 1] = { label = label, selected = isSelected(data) and true or false, pick = function() setSelected(data) end }
            return {}
        end
        assert(w._generator, "a dropdown with no menu")
        w._generator(w, root)
        return list
    end
    -- Picks the choice with this label, as a player would from the open menu.
    function M.choose(w, label)
        for _, c in ipairs(M.menu(w)) do
            if c.label == label then c.pick() return true end
        end
        local labels = {}
        for _, c in ipairs(M.menu(w)) do labels[#labels + 1] = c.label end
        error("no choice called " .. label .. " (there are: " .. table.concat(labels, ", ") .. ")", 2)
    end

    -- Runs a script as the game would: a click, typing, the mouse coming over.
    function M.run(w, script, ...)
        local fn = assert(w._scripts[script], (w._name or w._kind) .. " has no " .. script .. " script")
        if script == "OnClick" and w._disabled then return nil end -- the game doesn't click a disabled button
        return fn(w, ...)
    end

    ---------------------------------------------------------------------------
    -- Layout, as the game does it: each region's rectangle on the screen (y up) from its anchors,
    -- its size and the scales above it. A region whose anchors don't say where it is has none (the
    -- rows a scroll list places itself, for one).
    ---------------------------------------------------------------------------
    local FONT = { GameFontNormalSmall = 10, GameFontHighlightSmall = 10, GameFontDisableSmall = 10, GameFontNormal = 12, GameFontHighlight = 12,
        GameFontDisable = 12, GameFontNormalLarge = 16, GameFontHighlightLarge = 16, GameFontNormalHuge = 20, Game15Font_o1 = 15, NumberFontNormal = 12 }
    local SCREEN = { left = 0, right = 1920, bottom = 0, top = 1080 }
    function M.plain(t)
        t = type(t) == "string" and t or ""
        return (t:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|T.-|t", "WW"):gsub("|A.-|a", "WW"):gsub("||", "|"))
    end
    function M.fontSize(w)
        local f = w._font
        if type(f) == "table" then return f._size or 12 end
        return FONT[f or "GameFontHighlight"] or 12
    end
    -- Friz Quadrata runs about 0.55 of its size a character, Cinzel's capitals about 0.72.
    function M.charWidth(w)
        local f = w._font
        local file = type(f) == "table" and f._fontFile
        return (type(file) == "string" and file:find("Cinzel", 1, true)) and 0.72 or 0.55
    end
    function M.textWidth(w)
        local longest = 0
        for line in (M.plain(w._text) .. "\n"):gmatch("(.-)\n") do longest = math.max(longest, #line) end
        return longest * M.fontSize(w) * M.charWidth(w)
    end
    -- How many lines a text takes at a width: each of its own lines, wrapped when it may wrap.
    function M.lineCount(w, width)
        local size, lines = M.fontSize(w), 0
        for line in (M.plain(w._text) .. "\n"):gmatch("(.-)\n") do
            local need = #line * size * M.charWidth(w)
            lines = lines + ((w._wrap ~= false and width and width > 0 and need > width) and math.ceil(need / width) or 1)
        end
        if w._maxLines and w._maxLines > 0 then lines = math.min(lines, w._maxLines) end
        return lines
    end
    local function scaleOf(w)
        local s, p = 1, w
        while type(p) == "table" and p._kind do s, p = s * (p._scale or 1), p._parent end
        return s
    end
    local function at(rect, point)
        local x = point:find("LEFT") and rect.left or point:find("RIGHT") and rect.right or (rect.left + rect.right) / 2
        local y = point:find("TOP") and rect.top or point:find("BOTTOM") and rect.bottom or (rect.top + rect.bottom) / 2
        return x, y
    end
    local busy = {}
    function M.rect(w)
        if type(w) ~= "table" or not w._kind then return SCREEN end
        -- A list's row: the list's width, its height, below the rows before it; one the list would
        -- cut off (it runs past the list's bottom) isn't counted as shown.
        if w._list and w._extent then
            local lr = M.rect(w._list)
            if not lr then return nil end
            local s = scaleOf(w._list)
            local top = lr.top - w._listTop * s
            local bottom = top - w._extent * s
            if bottom < lr.bottom - 0.5 then return nil end
            return { left = lr.left, right = lr.right, top = top, bottom = bottom }
        end
        if busy[w] or not w._points then return nil end
        busy[w] = true
        local s = scaleOf(w)
        local left, right, cx, top, bottom, cy
        local ok = true
        for point, a in pairs(w._points) do
            local r = M.rect(a.rel)
            if not r then ok = false break end
            local x, y = at(r, a.relPoint)
            x, y = x + a.x * s, y + a.y * s
            if point:find("LEFT") then left = x elseif point:find("RIGHT") then right = x else cx = x end
            if point:find("TOP") then top = y elseif point:find("BOTTOM") then bottom = y else cy = y end
        end
        busy[w] = nil
        if not ok then return nil end
        local width, height = w._w, w._h
        if w._kind == "FontString" then
            local size = M.fontSize(w)
            width = width or (left and right and (right - left) / s) or M.textWidth(w)
            local lines = M.lineCount(w, width)
            height = height or lines * size + (lines - 1) * (w._spacing or 0)
        end
        local rect = {}
        if left and right then rect.left, rect.right = left, right
        elseif width and left then rect.left, rect.right = left, left + width * s
        elseif width and right then rect.left, rect.right = right - width * s, right
        elseif width and cx then rect.left, rect.right = cx - width * s / 2, cx + width * s / 2
        else return nil end
        if top and bottom then rect.top, rect.bottom = top, bottom
        elseif height and top then rect.top, rect.bottom = top, top - height * s
        elseif height and bottom then rect.top, rect.bottom = bottom + height * s, bottom
        elseif height and cy then rect.top, rect.bottom = cy + height * s / 2, cy - height * s / 2
        else return nil end
        return rect
    end

    local INTERACTIVE = { Button = true, CheckButton = true, ItemButton = true, EditBox = true, DropdownButton = true }
    local function under(root, w)
        local p = w._parent
        while type(p) == "table" and p._kind do
            if p == root then return true end
            p = p._parent
        end
        return false
    end
    -- What a test can see or point at under root: shown, with a place, and text or the mouse.
    local function shownParts(root)
        local out = {}
        for _, w in ipairs(M.regions) do
            local alpha, p = 1, w
            while type(p) == "table" and p._kind do alpha, p = alpha * (p._alpha or 1), p._parent end
            if under(root, w) and w:IsVisible() and alpha > 0 then
                local text = w._kind == "FontString" and M.plain(w._text):match("%S") ~= nil
                local mouse = INTERACTIVE[w._kind] or ((w._kind == "Frame" or w._kind == "EventFrame") and w._mouse)
                if text or mouse then
                    local r = M.rect(w)
                    if r and r.right - r.left > 0.5 and r.top - r.bottom > 0.5 then out[#out + 1] = { w = w, r = r } end
                end
            end
        end
        return out
    end
    -- What a region is called, for a message: the key its parent keeps it under, and its text.
    function M.describe(w)
        local names = {}
        local p = w
        while type(p) == "table" and p._kind and #names < 4 do
            local parent, key = p._parent, nil
            if type(parent) == "table" then
                for k, v in pairs(parent) do if v == p and type(k) == "string" and not k:match("^_") then key = k break end end
            end
            table.insert(names, 1, key or p._kind)
            p = parent
        end
        local t = M.plain(w._text)
        return table.concat(names, ".") .. (t ~= "" and (" \"" .. t:sub(1, 40) .. "\"") or "")
    end
    -- Every two parts under root that lie over each other, by more than a pixel each way: a text over
    -- a button, two buttons, two texts. A part and what it holds don't count, nor a frame laid over a
    -- text for its hover.
    function M.overlaps(root)
        local parts, out = shownParts(root), {}
        local function inside(a, b)
            local p = b._parent
            while type(p) == "table" and p._kind do if p == a then return true end p = p._parent end
            return false
        end
        for i = 1, #parts do
            for j = i + 1, #parts do
                local a, b = parts[i], parts[j]
                if not (inside(a.w, b.w) or inside(b.w, a.w) or a.w._cover == b.w or b.w._cover == a.w) then
                    local w = math.min(a.r.right, b.r.right) - math.max(a.r.left, b.r.left)
                    local h = math.min(a.r.top, b.r.top) - math.max(a.r.bottom, b.r.bottom)
                    if w > 1 and h > 1 then out[#out + 1] = M.describe(a.w) .. " over " .. M.describe(b.w) .. (" (%dx%d)"):format(w, h) end
                end
            end
        end
        return out
    end
    -- Every part under root a player can point at that has no place: anchors that don't say where it
    -- is (a list's rows the list would cut off are not shown, so they don't count).
    function M.unplaced(root)
        local out = {}
        for _, w in ipairs(M.regions) do
            if under(root, w) and w:IsVisible() and (INTERACTIVE[w._kind] or ((w._kind == "Frame" or w._kind == "EventFrame") and w._mouse)) and not M.rect(w) then
                local p, clipped = w, false
                while type(p) == "table" and p._kind do
                    if p._list then clipped = true break end
                    p = p._parent
                end
                if not clipped then out[#out + 1] = M.describe(w) end
            end
        end
        return out
    end
    -- Every part under root that runs out of root's rectangle by more than a pixel.
    function M.outside(root, box)
        box = box or M.rect(root)
        local out = {}
        for _, p in ipairs(shownParts(root)) do
            if p.r.left < box.left - 1 or p.r.right > box.right + 1 or p.r.bottom < box.bottom - 1 or p.r.top > box.top + 1 then
                out[#out + 1] = M.describe(p.w)
            end
        end
        return out
    end
    -- Every shown region under root with a place, for a picture of the layout.
    function M.dump(root)
        local out = {}
        for _, w in ipairs(M.regions) do
            if under(root, w) and w:IsVisible() then
                local r = M.rect(w)
                if r then out[#out + 1] = { kind = w._kind, r = r, text = w._kind == "FontString" and M.plain(w._text) or nil, name = M.describe(w),
                    font = w._font, mouse = (INTERACTIVE[w._kind] or w._mouse) and true or nil } end
            end
        end
        return out
    end

    -- Writes what M.dump finds as JSON, for a picture of the layout (tools/window-pictures.py).
    function M.writeLayout(path, root)
        local function q(v) return '"' .. tostring(v):gsub('[%c"\\]', function(c) return ("\\u%04x"):format(c:byte()) end) .. '"' end
        local out = {}
        for _, p in ipairs(M.dump(root)) do
            out[#out + 1] = ('{"kind":%s,"l":%.1f,"r":%.1f,"t":%.1f,"b":%.1f,"name":%s%s%s%s}'):format(q(p.kind), p.r.left, p.r.right, p.r.top, p.r.bottom,
                q(p.name), p.text and (',"text":' .. q(p.text)) or "", p.font and (',"font":' .. q(p.font)) or "", p.mouse and ',"mouse":true' or "")
        end
        local box = M.rect(root)
        local f = assert(io.open(path, "w"))
        f:write(('{"box":{"l":%.1f,"r":%.1f,"t":%.1f,"b":%.1f},"parts":[%s]}'):format(box.left, box.right, box.top, box.bottom, table.concat(out, ",")))
        f:close()
    end

    env.CreateFrame = function(kind, name, parent, template) return M.new(kind, name, parent, template) end
    env.CreateFont = function(name)
        local f = setmetatable({ _kind = "Font", _name = name, _shown = true, _scripts = {}, _events = {} }, widget)
        if name then env[name] = f end
        return f
    end
    -- One physical pixel (Blizzard_SharedXML PixelUtil.lua), and the screen: 1920 by 1080 unless a
    -- test says otherwise.
    env.GetPhysicalScreenSize = env.GetPhysicalScreenSize or function() return 1920, 1080 end
    env.PixelUtil = { GetPixelToUIUnitFactor = function()
        local _, h = env.GetPhysicalScreenSize()
        return 768 / h
    end }
    local tooltip = { _shown = false }
    local function tip(name, fn) tooltip[name] = fn or function() end end
    tip("IsForbidden", function() return false end)
    tip("ClearLines", function(self) self._texts = {} end)
    tip("SetOwner", function(self, owner) self._owner, self._link, self._text = owner, nil, nil end)
    tip("SetHyperlink", function(self, link)
        assert(type(link) == "string" and link:match("^item:[%-%d:]+$") or link:match("|Hitem:"), "tooltip given something that isn't an item: " .. tostring(link))
        self._link = link
    end)
    tip("SetItemByID", function(self, id) self._link = "item:" .. id end)
    tip("SetSpellByID", function(self, id) assert(type(id) == "number", "a spell tooltip without a spell") self._link, self._spell = nil, id end)
    tip("SetText", function(self, t) self._text = t end)
    tip("SetPoint", function(self, ...) self._point = { ... } end)
    tip("AddLine", function(self, t)
        self._lines = (self._lines or 0) + 1
        self._texts = self._texts or {}
        self._texts[#self._texts + 1] = t
    end)
    tip("Show", function(self) self._shown = true end)
    tip("Hide", function(self) self._shown = false end)
    env.GameTooltip = tooltip
    -- A chat link's tooltip and the comparison tooltip beside the game's own, made the same way.
    for _, name in ipairs({ "ItemRefTooltip", "ShoppingTooltip1" }) do
        local other = {}
        for k, v in pairs(tooltip) do if type(v) == "function" then other[k] = v end end
        other._shown = false
        env[name] = other
    end
    -- As Blizzard_ItemButton's ItemButtonTemplate.lua does it: a button with a way of its own to show
    -- its icon is asked first.
    env.SetItemButtonTexture = function(b, t)
        b._icon = t
        if rawget(b, "SetItemButtonTexture") then b:SetItemButtonTexture(t) end
    end
    env.SetItemButtonCount = function(b, c) b._count = c end
    -- As ItemButtonTemplate.lua does it: an item of a quality gets the game's frame round its icon,
    -- unless the button has a way of its own to show its border.
    env.SetItemButtonQuality = function(b, q, link)
        b._quality, b._link = q, link
        if rawget(b, "SetItemButtonBorder") then b:SetItemButtonBorder(q and "Interface\\Common\\WhiteIconFrame" or nil)
        elseif rawget(b, "IconBorder") then b.IconBorder:SetShown(q ~= nil) end
    end
    env.SearchBoxTemplate_OnTextChanged = function() end
    -- As SharedUIPanelTemplates.lua does it: the inset down to PANEL_INSET_BOTTOM_OFFSET (4) above the
    -- window's bottom edge, where the button bar's 26 was.
    env.ButtonFrameTemplate_HideButtonBar = function(frame) frame.Inset:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -6, 4) end
    env.CreateDataProvider = function(t) return { _items = t or {} } end
    env.CreateScrollBoxListLinearView = function()
        local view = {}
        function view:SetElementExtent(n) self._extent = n end
        function view:SetElementExtentCalculator(fn)
            assert(type(fn) == "function", "SetElementExtentCalculator needs a function")
            self._extentOf = fn
        end
        function view:SetElementInitializer(frameType, init)
            if not allowed[frameType] then error("SetElementInitializer: no frame type " .. tostring(frameType), 2) end
            self._frameType, self._init = frameType, init
        end
        return view
    end
    env.ScrollUtil = { InitScrollBoxListWithScrollBar = function(list, bar, view) list._view, list._bar = view, bar end }
    env.ScrollBoxConstants = { RetainScrollPosition = true }
    env.PanelTemplates_SetNumTabs = function(frame, n)
        assert(frame.Tabs and #frame.Tabs == n, "PanelTemplates_SetNumTabs: the frame has " .. #(frame.Tabs or {}) .. " tabs, not " .. n)
        frame.numTabs = n
        for i = 2, n do frame.Tabs[i]:SetPoint("TOPLEFT", frame.Tabs[i - 1], "TOPRIGHT", 3, 0) end -- PanelTemplates_AnchorTabs
    end
    env.PanelTemplates_SetTab = function(frame, id)
        assert(frame.numTabs and id >= 1 and id <= frame.numTabs, "PanelTemplates_SetTab: no tab " .. tostring(id))
        frame.selectedTab = id
    end
    env.PanelTemplates_TabResize = function() end
    -- SharedUIPanelTemplates.lua: a disabled tab is greyed and takes no clicks.
    env.PanelTemplates_DisableTab = function(frame, i) frame.Tabs[i].isDisabled = 1 frame.Tabs[i]:Disable() end
    env.PanelTemplates_EnableTab = function(frame, i) frame.Tabs[i].isDisabled = nil frame.Tabs[i]:Enable() end
    local colors = { DRUID = "ff7c0a", WARRIOR = "c69b6d", PALADIN = "f48cba", HUNTER = "aad372", ROGUE = "fff468", PRIEST = "ffffff", SHAMAN = "0070dd", MAGE = "3fc7eb", WARLOCK = "8788ee" }
    env.RAID_CLASS_COLORS = {}
    env.LOCALIZED_CLASS_NAMES_MALE = {}
    for file, hex in pairs(colors) do
        env.RAID_CLASS_COLORS[file] = { WrapTextInColorCode = function(_, t) return "|cff" .. hex .. t .. "|r" end }
        env.LOCALIZED_CLASS_NAMES_MALE[file] = file:sub(1, 1) .. file:sub(2):lower()
    end
    env.GetMoneyString = function(c) return ("%dg %ds %dc"):format(math.floor(c / 10000), math.floor(c / 100) % 100, c % 100) end
    -- The game's number and clock formats as an English client with a 12-hour clock gives them
    -- (Blizzard_FrameXMLUtil/GameTimeUtil.lua: TIME_TWELVEHOURAM, TIME_TWELVEHOURPM, TIMEMANAGER_TICKER_12HOUR).
    env.BreakUpLargeNumbers = function(n)
        local s = tostring(math.floor(n))
        local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
        return (out:gsub("^,", ""))
    end
    env.GameTime_GetFormattedTime = function(hour, minute, wantAMPM)
        local pm = hour >= 12
        if hour == 0 then hour = 12 elseif hour > 12 then hour = hour - 12 end
        if wantAMPM then return ("%d:%02d %s"):format(hour, minute, pm and "PM" or "AM") end
        return ("%d:%02d"):format(hour, minute)
    end
    -- Options > AddOns: what was registered, so a test can read and switch the settings.
    M.settings = {}
    env.Settings = {
        VarType = { Boolean = "boolean", String = "string", Number = "number" }, Default = { True = true, False = false },
        RegisterVerticalLayoutCategory = function(name)
            local cat = { name = name, settings = {}, sub = {} }
            M.settings[name] = cat
            return cat
        end,
        RegisterProxySetting = function(cat, variable, kind, name, default, get, set)
            assert(kind == "boolean" and type(get) == "function" and type(set) == "function", "a proxy setting needs a type, a getter and a setter")
            local setting = { variable = variable, name = name, default = default, get = get, set = set }
            cat.settings[variable] = setting
            return setting
        end,
        CreateCheckbox = function(cat, setting, tooltip)
            assert(cat.settings[setting.variable] == setting, "a checkbox for a setting not in its category")
            setting.tooltip = tooltip
        end,
        RegisterCanvasLayoutSubcategory = function(cat, frame, name) cat.sub[name] = frame end,
        RegisterAddOnCategory = function(cat) cat.registered = true end,
    }
    env.UISpecialFrames = {}
    env.tinsert = table.insert
    env.IsModifiedClick = function() return false end
    -- The game's text colours and its reputation bars' (ColorMixin objects), its standings' names,
    -- and the quest log's difficulty colours (Blizzard_FrameXMLBase/Constants.lua, DifficultyUtil.lua).
    local function color(r, g, b)
        local c = { r = r, g = g, b = b }
        function c.GetRGB(self) return self.r, self.g, self.b end
        function c.GenerateHexColor(self) return ("ff%02x%02x%02x"):format(math.floor(self.r * 255), math.floor(self.g * 255), math.floor(self.b * 255)) end
        function c.WrapTextInColorCode(self, t) return "|c" .. self:GenerateHexColor() .. t .. "|r" end
        return c
    end
    env.CreateColor = function(r, g, b, a)
        local c = color(r, g, b)
        c.a = a or 1
        function c.GetRGBA(self) return self.r, self.g, self.b, self.a end
        return c
    end
    env.NORMAL_FONT_COLOR, env.HIGHLIGHT_FONT_COLOR, env.GRAY_FONT_COLOR = color(1, 0.82, 0), color(1, 1, 1), color(0.5, 0.5, 0.5)
    env.GREEN_FONT_COLOR, env.RED_FONT_COLOR, env.LIGHTBLUE_FONT_COLOR, env.ORANGE_FONT_COLOR = color(0.1, 1, 0.1), color(1, 0.1, 0.1), color(0.53, 0.67, 1), color(1, 0.5, 0.25)
    env.YELLOW_FONT_COLOR = color(1, 1, 0)
    local red, orange, yellow, green = color(0.8, 0.3, 0.22), color(0.75, 0.27, 0), color(0.9, 0.7, 0), color(0, 0.6, 0.1)
    env.FACTION_BAR_COLORS = { red, red, orange, yellow, green, green, green, green }
    for i, name in ipairs({ "Hated", "Hostile", "Unfriendly", "Neutral", "Friendly", "Honored", "Revered", "Exalted" }) do env["FACTION_STANDING_LABEL" .. i] = name end
    env.GetText = function(token, gender) return (gender == 3 and env[token .. "_FEMALE"]) or env[token] end
    env.QuestDifficultyColors = { impossible = { r = 1, g = 0.1, b = 0.1 }, verydifficult = { r = 1, g = 0.5, b = 0.25 }, difficult = { r = 1, g = 0.82, b = 0 },
        standard = { r = 0.25, g = 0.75, b = 0.25 }, trivial = { r = 0.5, g = 0.5, b = 0.5 } }
    env.UnitQuestTrivialLevelRange = function() return 5 end
    env.GetRelativeDifficultyColor = function(unitLevel, challengeLevel)
        local c, diff = env.QuestDifficultyColors, challengeLevel - unitLevel
        if diff >= 5 then return c.impossible elseif diff >= 3 then return c.verydifficult elseif diff >= -4 then return c.difficult
        elseif -diff <= env.UnitQuestTrivialLevelRange("player") then return c.standard else return c.trivial end
    end
    -- Every sound the window plays, by the game's own ids (Blizzard_SharedXML/Mainline/SoundKitConstants.lua).
    env.SOUNDKIT = env.SOUNDKIT or {}
    for k, v in pairs({ IG_CHARACTER_INFO_OPEN = 839, IG_CHARACTER_INFO_CLOSE = 840, IG_CHARACTER_INFO_TAB = 841, IG_MAINMENU_OPTION = 852,
        IG_MAINMENU_OPTION_CHECKBOX_ON = 856, IG_MAINMENU_OPTION_CHECKBOX_OFF = 857 }) do env.SOUNDKIT[k] = env.SOUNDKIT[k] or v end
    env.ColoredProgressBarMixin = { ColorType = { Red = 1, Green = 2, Blue = 3, White = 4 } }
    env.ITEM_QUALITY_COLORS = {}
    for q, hex in pairs({ [0] = "ff9d9d9d", "ffffffff", "ff1eff00", "ff0070dd", "ffa335ee", "ffff8000" }) do env.ITEM_QUALITY_COLORS[q] = { hex = "|c" .. hex } end
    return M
end
