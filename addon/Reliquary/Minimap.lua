-- Reliquary on the minimap: a button on its edge, and a line in the minimap's Addons menu. Click
-- either to open the window (as /rq does), right-click for the Sharing tab, and drag the button
-- around the edge. The button is drawn, placed and dragged as LibDBIcon draws other addons' buttons
-- (its version 57, the one DBM and Total RP 3 bring to this game), so it sits among theirs as one
-- of them. Where it sits and whether it shows hold for every character: settings.minimapPos
-- (degrees counter-clockwise from the right, as LibDBIcon counts) and settings.minimapButton
-- (false when hidden, from the Sharing tab or Options).
local ADDON, ns = ...

local call, num, on = ns.call, ns.num, ns.on
local type, pcall, rad, deg, cos, sin, sqrt, max, min, atan2 = type, pcall, math.rad, math.deg, math.cos, math.sin, math.sqrt, math.max, math.min, math.atan2

local ICON = "Interface\\AddOns\\Reliquary\\Media\\icon"
local START = 111 -- where it first sits: upper left, under the zone's name, clear of the game's own marks and buttons
local OUTSIDE = 5 -- its centre this far outside the minimap's edge, as LibDBIcon has it
-- For each shape a minimap addon may give the minimap (through GetMinimapShape), whether each
-- quarter is round: lower right, lower left, upper right, upper left. Past a square corner the
-- button runs along the edge, as LibDBIcon's do.
local SHAPES = {
    ROUND = { true, true, true, true },
    SQUARE = { false, false, false, false },
    ["CORNER-TOPLEFT"] = { false, false, false, true },
    ["CORNER-TOPRIGHT"] = { false, false, true, false },
    ["CORNER-BOTTOMLEFT"] = { false, true, false, false },
    ["CORNER-BOTTOMRIGHT"] = { true, false, false, false },
    ["SIDE-LEFT"] = { false, true, false, true },
    ["SIDE-RIGHT"] = { true, false, true, false },
    ["SIDE-TOP"] = { false, false, true, true },
    ["SIDE-BOTTOM"] = { true, true, false, false },
    ["TRICORNER-TOPLEFT"] = { false, true, true, true },
    ["TRICORNER-TOPRIGHT"] = { true, false, true, true },
    ["TRICORNER-BOTTOMLEFT"] = { true, true, false, true },
    ["TRICORNER-BOTTOMRIGHT"] = { true, true, true, false },
}

local button, dragging

local function settings() return type(ns.db) == "table" and type(ns.db.settings) == "table" and ns.db.settings or nil end

local function place()
    local s = settings()
    if not (button and s) then return end
    local a = rad(num(s.minimapPos) or START)
    local x, y, q = cos(a), sin(a), 1
    if x < 0 then q = q + 1 end
    if y > 0 then q = q + 2 end
    local w = (num(Minimap:GetWidth()) or 0) / 2 + OUTSIDE
    local h = (num(Minimap:GetHeight()) or 0) / 2 + OUTSIDE
    if (SHAPES[call(GetMinimapShape)] or SHAPES.ROUND)[q] then
        x, y = x * w, y * h
    else
        local dw, dh = sqrt(2 * w * w) - 10, sqrt(2 * h * h) - 10
        x = max(-w, min(x * dw, w))
        y = max(-h, min(y * dh, h))
    end
    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

-- Shows or hides the button as its switch says, in its place.
local function update()
    local s = settings()
    if not (button and s) then return end
    place()
    button:SetShown(s.minimapButton ~= false)
end
ns.updateMinimapButton = update

-- The icon a little smaller while the button is held, as on LibDBIcon's.
local function pressed(down)
    local d = down and 0 or 0.05
    button.icon:SetTexCoord(d, 1 - d, d, 1 - d)
end

-- What a click does, on the button or in the Addons menu.
local function click(which)
    if which == "RightButton" then
        if ns.showViewer then pcall(ns.showViewer, "Sharing") end
    elseif SlashCmdList and SlashCmdList.RELIQUARY then
        SlashCmdList.RELIQUARY("")
    end
end

-- The tooltip, its point at the owner's: the game's white title, and green lines for what a click
-- does.
local function tip(owner, drag, point, ownerPoint)
    GameTooltip:SetOwner(owner, "ANCHOR_NONE")
    GameTooltip:SetPoint(point, owner, ownerPoint)
    if type(GameTooltip_SetTitle) == "function" then GameTooltip_SetTitle(GameTooltip, "Reliquary")
    else GameTooltip:SetText("Reliquary", 1, 1, 1) end
    local lines = { "Click to open", "Right-click for Sharing" }
    if drag then lines[3] = "Drag to move" end
    for _, line in ipairs(lines) do
        if type(GameTooltip_AddInstructionLine) == "function" then GameTooltip_AddInstructionLine(GameTooltip, line)
        else GameTooltip:AddLine(line, 0.1, 1, 0.1) end
    end
    GameTooltip:Show()
end

-- Where the button's tooltip goes: above or below it toward the middle of the screen, and lined
-- up with its side nearer an edge, as LibDBIcon puts it.
local function towardMiddle(self)
    local x, y = self:GetCenter()
    local w, h = num(UIParent and UIParent:GetWidth()), num(UIParent and UIParent:GetHeight())
    if not (num(x) and num(y) and w and h) then return "TOP", "BOTTOM" end
    local across = (x > w * 2 / 3) and "RIGHT" or (x < w / 3) and "LEFT" or ""
    if y > h / 2 then return "TOP" .. across, "BOTTOM" .. across end
    return "BOTTOM" .. across, "TOP" .. across
end

-- While dragged: the angle from the minimap's centre to the cursor.
local function follow()
    local s = settings()
    local mx, my = Minimap:GetCenter()
    local px, py = GetCursorPosition()
    local scale = num(Minimap:GetEffectiveScale()) or 1
    if not (s and num(mx) and num(my) and num(px) and num(py) and scale > 0) then return end
    s.minimapPos = deg(atan2(py / scale - my, px / scale - mx)) % 360
    place()
end

local function build()
    button = CreateFrame("Button", "ReliquaryMinimapButton", Minimap)
    button:SetFrameStrata("MEDIUM")
    button:SetFixedFrameStrata(true)
    button:SetFrameLevel(8)
    button:SetFixedFrameLevel(true)
    button:SetSize(31, 31)
    button:RegisterForClicks("AnyUp")
    button:RegisterForDrag("LeftButton")
    button:SetHighlightTexture(136477) -- Interface\Minimap\UI-Minimap-ZoomButton-Highlight
    local border = button:CreateTexture(nil, "OVERLAY")
    border:SetTexture(136430) -- Interface\Minimap\MiniMap-TrackingBorder
    border:SetSize(50, 50)
    border:SetPoint("TOPLEFT")
    local background = button:CreateTexture(nil, "BACKGROUND")
    background:SetTexture(136467) -- Interface\Minimap\UI-Minimap-Background
    background:SetSize(24, 24)
    background:SetPoint("CENTER")
    button.icon = button:CreateTexture(nil, "ARTWORK")
    button.icon:SetTexture(ICON)
    button.icon:SetSize(18, 18)
    button.icon:SetPoint("CENTER")
    pressed(false)
    button:SetScript("OnClick", function(_, which) click(which) end)
    button:SetScript("OnMouseDown", function() pressed(true) end)
    button:SetScript("OnMouseUp", function() pressed(false) end)
    button:SetScript("OnEnter", function(self)
        if dragging then return end
        tip(self, true, towardMiddle(self))
    end)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)
    button:SetScript("OnDragStart", function(self)
        dragging = true
        self:LockHighlight()
        pressed(true)
        GameTooltip:Hide()
        self:SetScript("OnUpdate", follow)
    end)
    button:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
        dragging = false
        pressed(false)
        self:UnlockHighlight()
    end)
end

-- Made once the game has logged in, as LibDBIcon waits for addons that change the minimap's shape.
on("PLAYER_LOGIN", function()
    if button or not (settings() and Minimap) then return end
    build()
    update()
end)

-- The minimap's Addons menu: the game finds these three through the TOC. The same clicks, and the
-- same tooltip less dragging, beside the menu on the side with room.
function Reliquary_OnAddonCompartmentClick(_, which) click(which) end

function Reliquary_OnAddonCompartmentEnter(_, menuButton)
    if type(menuButton) ~= "table" then return end
    local x = num((menuButton:GetCenter()))
    local w = num(UIParent and UIParent:GetWidth())
    if x and w and x < w / 2 then tip(menuButton, false, "TOPLEFT", "TOPRIGHT")
    else tip(menuButton, false, "TOPRIGHT", "TOPLEFT") end
end

function Reliquary_OnAddonCompartmentLeave() GameTooltip:Hide() end
