-- Runs the Reliquary addon against a simulated WoW: Forever client (no game needed),
-- fires the events a session fires, and writes ReliquaryDB the way the game writes
-- SavedVariables. Usage: lua5.1 tests/harness.lua <Reliquary.toc> <out.lua> [scenario]
-- Scenarios: full (default), secrets (every value secret), bare (an old client without
-- the retail APIs), combat (events arrive mid-fight).
local tocPath, outPath, scenario = arg[1], arg[2], arg[3] or "full"
local here = arg[0]:match("(.*/)") or "./"
dofile(here .. "icons_fixture.lua")
local function I(name) return assert(ICON_IDS[name], "no icon " .. name) end

---------------------------------------------------------------------------
-- Secret values (Midnight): a sentinel the addon must never store
---------------------------------------------------------------------------
local SECRET = setmetatable({}, {
    __tostring = function() return "SECRET" end,
    __eq = function() error("compared a secret value") end,
    __lt = function() error("compared a secret value") end,
    __le = function() error("compared a secret value") end,
    __concat = function() error("concatenated a secret value") end,
})
local secrets = scenario == "secrets"
local function S(v) if secrets then return SECRET end return v end
issecretvalue = function(v) return rawequal(v, SECRET) end

---------------------------------------------------------------------------
-- Timers, frames, events
---------------------------------------------------------------------------
local clock = os.time() - 7200
time = function() return math.floor(clock) end -- the game's time() is whole seconds
local timers = {}
C_Timer = { After = function(sec, fn) timers[#timers + 1] = { at = clock + sec, fn = fn } end }
-- Runs every timer due within sec, in order, each at its own moment (a timer can set another).
local function advance(sec)
    local target = clock + sec
    while true do
        table.sort(timers, function(a, b) return a.at < b.at end)
        local t = timers[1]
        if not t or t.at > target then break end
        table.remove(timers, 1)
        if t.at > clock then clock = t.at end
        t.fn()
    end
    clock = target
end

date = function(fmt, t) return os.date(fmt, math.floor(t or clock)) end

-- The game's widgets, strict about which methods exist (tests/wowui.lua).
local ui = dofile(here .. "wowui.lua")(_G) -- SOUNDKIT, with every sound the window plays, comes with it
-- The window laid out: nothing in it lies over anything else, and nothing runs out of it. With
-- RELIQUARY_LAYOUT set to a folder, each place checked is written there too, for a picture of it.
local layouts = 0
local function WHITE_FONT() return "|c" .. HIGHLIGHT_FONT_COLOR:GenerateHexColor() end
-- Words a player reads that the game wouldn't say: "reliquary" in lower case is the addon's own word
-- for a player's record, never something to put in front of them; the addon's name, Reliquary, is fine.
local function plainWords(where, said)
    local at = said:find("reliquar", 1, true)
    assert(not at, where .. ": says \"" .. said:sub(math.max(1, (at or 1) - 40), (at or 1) + 40) .. "\"")
end
local function laidOut(where)
    local win = ReliquaryFrame
    assert(win and win:IsShown(), where .. ": the window isn't open, so nothing in it can be checked")
    local words = {}
    for _, w in ipairs(ui.regions) do
        if w._kind == "FontString" and w._text and w:IsVisible() then words[#words + 1] = w._text end
    end
    plainWords(where, table.concat(words, "\n"))
    local over = ui.overlaps(win)
    assert(#over == 0, where .. ": " .. table.concat(over, "; "))
    local box = ui.rect(win)
    local out = ui.outside(win, box)
    assert(#out == 0, where .. " runs out of the window: " .. table.concat(out, "; "))
    local lost = ui.unplaced(win)
    assert(#lost == 0, where .. ": nowhere to be seen: " .. table.concat(lost, "; "))
    local dir = os.getenv("RELIQUARY_LAYOUT")
    if dir and scenario == "full" then
        layouts = layouts + 1
        ui.writeLayout(("%s/harness-%02d %s.json"):format(dir, layouts, where), win)
    end
end
local played = {}
PlaySound = function(id) played[#played + 1] = id end
local chatPrinted = {}
for i = 1, 3 do
    local f = CreateFrame("Frame", "ChatFrame" .. i)
    f:RegisterEvent("TIME_PLAYED_MSG")
    f:SetScript("OnEvent", function(_, e) if e == "TIME_PLAYED_MSG" then chatPrinted[#chatPrinted + 1] = i end end)
end
NUM_CHAT_WINDOWS = 3
local fire = ui.fire

local printed = {}
print = function(...) local t = {} for i = 1, select("#", ...) do t[i] = tostring((select(i, ...))) end printed[#printed + 1] = table.concat(t, " ") end
wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
unpack = unpack or table.unpack
SlashCmdList = {}

---------------------------------------------------------------------------
-- Joan, level 12, on Zephras Isle (sample data)
---------------------------------------------------------------------------
local inCombat = scenario == "combat"
InCombatLockdown = function() return inCombat end
UnitAffectingCombat = function() return inCombat end
-- WoW: Forever: "Given Family" names, the family name second where other clients give the realm.
RegionalUniqueNamesEnabled = function() return true end
UnitName = function() return S("Joan"), S("Ofârc") end
GetRealmName = function() return "CAMWOWUS2Realm11RP" end
UnitRace = function() return S("High Order Skyborne"), "HighOrderSkyborne" end
UnitClass = function() return S("Druid"), "DRUID" end
UnitSex = function() return 3 end
UnitFactionGroup = function() return "Alliance", "Alliance" end
UnitLevel = function() return S(12) end
UnitGUID = function(u) if u == "player" then return S("Player-3299-0A1B2C3D") end end
UnitIsAFK = function() return false end
GetMaxPlayerLevel = function() return 60 end
GetGuildInfo = function() return nil end
GetCurrentTitle = function() return 0 end
GetBindLocation = function() return S("Valanaar") end
GetMoney = function() return S(12345) end
local loggingOut = false
UnitXP = function() return loggingOut and 0 or S(3890) end
UnitXPMax = function() return loggingOut and 0 or S(8800) end
GetXPExhaustion = function() return S(6200) end
IsResting = function() return true end
UnitHealth = function() return S(342) end
UnitHealthMax = function() return S(342) end
UnitPowerType = function() return 0, "MANA" end
UnitPower = function() return S(410) end
UnitPowerMax = function() return S(455) end
GetRealZoneText = function() return S("Zephras Isle") end
GetZoneText = GetRealZoneText
GetSubZoneText = function() return S("Valanaar") end
GetMinimapZoneText = function() return S("Calmbreeze Inn") end
GetBuildInfo = function() return "1.60.1", "70412", "Nov 3 2026", 16001 end
RequestTimePlayed = function() C_Timer.After(0.5, function() fire("TIME_PLAYED_MSG", S(41820), S(9120)) end) end
Enum = {
    GameRule = { HardcoreRuleset = 1, RPRuleset = 2, PvPRuleset = 3 },
    TraitConfigType = { Generic = 3, CamelotCombat = 4 },
    PowerType = { Mana = 0 },
    BagIndex = { Backpack = 0, Bag_1 = 1, Bag_2 = 2, Bag_3 = 3, Bag_4 = 4, CharacterBankTab_1 = 6, CharacterBankTab_2 = 7 },
}
C_GameRules = { IsGameRuleActive = function(r) return r == 2 or r == 3 end }
C_Map = {
    GetBestMapForUnit = function() return 2441 end,
    GetPlayerMapPosition = function() return { GetXY = function() return S(0.4612), S(0.5233) end } end,
    GetMapInfo = function(id)
        if id == 2440 then return { name = "Forever", parentMapID = 0 } end
        return { name = "Zephras Isle", parentMapID = 2440 }
    end,
}

UnitStat = function(_, i)
    local s = { { 34, 34 }, { 27, 29 }, { 31, 33 }, { 44, 49 }, { 52, 56 } }
    return S(s[i][1]), S(s[i][2]), S(s[i][2] - s[i][1]), 0
end
UnitArmor = function() return 268, S(268), 268, 0, 0 end
UnitResistance = function(_, i) return 0, (i == 3 and S(5) or 0), 0, 0 end
UnitAttackPower = function() return S(68), 0, 0 end
UnitRangedAttackPower = function() return 0, 0, 0 end
GetCritChance = function() return S(5.31) end
GetRangedCritChance = function() return 5.31 end
GetHitModifier = function() return 0 end
GetSpellHitModifier = function() return 0 end
GetDodgeChance = function() return S(6.12) end
GetParryChance = function() return 0 end
GetBlockChance = function() return 0 end
GetSpellBonusDamage = function(school) return school == 4 and S(9) or 0 end
GetSpellCritChance = function(school) return school == 4 and S(3.87) or 2.1 end
GetSpellBonusHealing = function() return S(11) end
GetManaRegen = function() return S(3.4), S(0.85) end
UnitAttackSpeed = function() return S(2.9), nil end
UnitDamage = function() return S(24.2), S(33.8) end
GetAverageItemLevel = function() return 14.2, S(13.6) end

-- Items: id -> name, quality, item level, icon, required level, kind, sub, equip slot, tooltip
local ITEMS = {
    [264908] = { "Ancient Heirloom", 3, 10, I("inv_jewelry_ring_03"), 1, "Armor", "Miscellaneous", "INVTYPE_FINGER",
        { { "Ancient Heirloom", "0070dd" }, { "Soulbound", "ffffff" }, { "Finger", "ffffff" }, { "+2 Spirit", "ffffff" },
          { "Equip: Lets you see the spirits of those who wore it before you.", "1eff00" },
          { "\"With love always, KG\"", "ffd100" } } },
    [264120] = { "Windshaper's Circlet", 2, 14, I("inv_helmet_15"), 10, "Armor", "Leather", "INVTYPE_HEAD",
        { { "Windshaper's Circlet", "1eff00" }, { "Binds when picked up", "ffffff" }, { "Head", "ffffff", "Leather", "ffffff" },
          { "52 Armor", "ffffff" }, { "+3 Intellect", "ffffff" }, { "+2 Spirit", "ffffff" }, { "Durability 38 / 45", "ffffff" }, { "Requires Level 10", "ffffff" } } },
    [264131] = { "Thendal Grove Pendant", 2, 13, I("inv_jewelry_necklace_07"), 9, "Armor", "Miscellaneous", "INVTYPE_NECK",
        { { "Thendal Grove Pendant", "1eff00" }, { "Binds when picked up", "ffffff" }, { "Neck", "ffffff" }, { "+2 Intellect", "ffffff" }, { "+2 Stamina", "ffffff" } } },
    [2591] = { "Patched Wanderer's Cloak", 1, 5, I("inv_misc_cape_02"), 1, "Armor", "Cloth", "INVTYPE_CLOAK",
        { { "Patched Wanderer's Cloak", "ffffff" }, { "Back", "ffffff" }, { "9 Armor", "ffffff" } } },
    [264140] = { "Shadowgale Hide Vest", 2, 15, I("inv_chest_leather_09"), 11, "Armor", "Leather", "INVTYPE_CHEST",
        { { "Shadowgale Hide Vest", "1eff00" }, { "Binds when picked up", "ffffff" }, { "Chest", "ffffff", "Leather", "ffffff" },
          { "71 Armor", "ffffff" }, { "+3 Agility", "ffffff" }, { "+2 Stamina", "ffffff" }, { "Durability 61 / 70", "ffffff" } } },
    [45] = { "Orchard-Keeper's Shirt", 1, 1, I("inv_shirt_white_01"), 1, "Armor", "Miscellaneous", "INVTYPE_BODY",
        { { "Orchard-Keeper's Shirt", "ffffff" }, { "Shirt", "ffffff" } } },
    [264152] = { "Nightclaw Cord", 2, 12, I("inv_belt_03"), 8, "Armor", "Leather", "INVTYPE_WAIST",
        { { "Nightclaw Cord", "1eff00" }, { "Waist", "ffffff", "Leather", "ffffff" }, { "29 Armor", "ffffff" }, { "+2 Spirit", "ffffff" } } },
    [264153] = { "Borrowed Breeches", 1, 10, I("inv_pants_leather_09"), 5, "Armor", "Leather", "INVTYPE_LEGS",
        { { "Borrowed Breeches", "ffffff" }, { "Legs", "ffffff", "Leather", "ffffff" }, { "48 Armor", "ffffff" } } },
    [264154] = { "Somebody Else's Boots", 2, 12, I("inv_boots_05"), 8, "Armor", "Leather", "INVTYPE_FEET",
        { { "Somebody Else's Boots", "1eff00" }, { "Feet", "ffffff", "Leather", "ffffff" }, { "38 Armor", "ffffff" }, { "+2 Agility", "ffffff" }, { "+1 Stamina", "ffffff" } } },
    [264155] = { "Skydock Bracers", 1, 9, I("inv_bracer_02"), 4, "Armor", "Leather", "INVTYPE_WRIST",
        { { "Skydock Bracers", "ffffff" }, { "Wrist", "ffffff", "Leather", "ffffff" }, { "20 Armor", "ffffff" } } },
    [264156] = { "Orchard Gloves", 2, 11, I("inv_gauntlets_05"), 7, "Armor", "Leather", "INVTYPE_HAND",
        { { "Orchard Gloves", "1eff00" }, { "Hands", "ffffff", "Leather", "ffffff" }, { "31 Armor", "ffffff" }, { "+2 Intellect", "ffffff" } } },
    [264160] = { "Staff of the Quiet Wind", 3, 16, I("inv_staff_08"), 11, "Weapon", "Staves", "INVTYPE_2HWEAPON",
        { { "Staff of the Quiet Wind", "0070dd" }, { "Binds when picked up", "ffffff" }, { "Two-Hand", "ffffff", "Staff", "ffffff" },
          { "24 - 37 Damage", "ffffff", "Speed 2.90", "ffffff" }, { "(10.5 damage per second)", "ffffff" }, { "+4 Intellect", "ffffff" }, { "+4 Spirit", "ffffff" },
          { "Equip: Increases healing done by spells and effects by up to 7.", "1eff00" }, { "Durability 70 / 85", "ffffff" } } },
    [264161] = { "Idol of the Orchard", 2, 12, I("inv_relics_idolofhealth"), 10, "Armor", "Idols", "INVTYPE_RELIC",
        { { "Idol of the Orchard", "1eff00" }, { "Relic", "ffffff", "Idol", "ffffff" }, { "Equip: Your Rejuvenation heals 4 more.", "1eff00" } } },
    [4496] = { "Small Brown Pouch", 1, 5, I("inv_misc_bag_07"), 0, "Container", "Bag", "INVTYPE_BAG", { { "Small Brown Pouch", "ffffff" }, { "6 Slot Bag", "ffffff" } } },
    [4240] = { "Woolen Bag", 1, 15, I("inv_misc_bag_10"), 0, "Container", "Bag", "INVTYPE_BAG", { { "Woolen Bag", "ffffff" }, { "8 Slot Bag", "ffffff" } } },
    [4540] = { "Tough Hunk of Bread", 1, 5, I("inv_misc_food_11"), 1, "Consumable", "Food & Drink", "", { { "Tough Hunk of Bread", "ffffff" }, { "Use: Restores 61 health over 18 sec.", "1eff00" } } },
    [159] = { "Refreshing Spring Water", 1, 5, I("inv_drink_04"), 1, "Consumable", "Food & Drink", "", { { "Refreshing Spring Water", "ffffff" }, { "Use: Restores 151 mana over 18 sec.", "1eff00" } } },
    [2318] = { "Light Leather", 1, 10, I("inv_misc_leatherscrap_03"), 0, "Trade Goods", "Leather", "", { { "Light Leather", "ffffff" } } },
    [2589] = { "Linen Cloth", 1, 5, I("inv_fabric_linen_01"), 0, "Trade Goods", "Cloth", "", { { "Linen Cloth", "ffffff" } } },
    [765] = { "Silverleaf", 1, 5, I("inv_misc_herb_10"), 0, "Trade Goods", "Herb", "", { { "Silverleaf", "ffffff" } } },
    [2447] = { "Peacebloom", 1, 5, I("inv_misc_herb_11"), 0, "Trade Goods", "Herb", "", { { "Peacebloom", "ffffff" } } },
    [118] = { "Minor Healing Potion", 1, 5, I("inv_potion_51"), 1, "Consumable", "Potion", "", { { "Minor Healing Potion", "ffffff" }, { "Use: Restores 70 to 90 health.", "1eff00" } } },
    [264170] = { "Slab Rubbing, Thendal", 1, 1, I("inv_scroll_03"), 0, "Quest", "Quest", "", { { "Slab Rubbing, Thendal", "ffffff" }, { "Quest Item", "ffffff" } } },
    [264171] = { "Smoothed Sky Pearl", 2, 12, I("inv_misc_gem_pearl_04"), 0, "Trade Goods", "Jewelcrafting", "", { { "Smoothed Sky Pearl", "1eff00" } } },
    [264172] = { "Faded Crystal Shard", 0, 1, I("inv_misc_rune_01"), 0, "Junk", "Junk", "", { { "Faded Crystal Shard", "9d9d9d" } } },
    [264173] = { "Worn Book of Lodge Songs", 1, 1, I("inv_misc_book_09"), 0, "Miscellaneous", "Other", "", { { "Worn Book of Lodge Songs", "ffffff" }, { "\"Someone underlined one verse twice.\"", "ffd100" } } },
    -- What her recipes make and use.
    [2455] = { "Minor Mana Potion", 1, 5, I("inv_potion_70"), 1, "Consumable", "Potion", "", { { "Minor Mana Potion", "ffffff" }, { "Use: Restores 140 to 180 mana.", "1eff00" } } },
    [858] = { "Lesser Healing Potion", 1, 13, I("inv_potion_50"), 3, "Consumable", "Potion", "", { { "Lesser Healing Potion", "ffffff" }, { "Use: Restores 140 to 180 health.", "1eff00" } } },
    [3371] = { "Empty Vial", 1, 1, I("inv_drink_06"), 0, "Trade Goods", "Other", "", { { "Empty Vial", "ffffff" } } },
    [785] = { "Mageroyal", 1, 10, I("inv_misc_flower_02"), 0, "Trade Goods", "Herb", "", { { "Mageroyal", "ffffff" } } },
    [2450] = { "Briarthorn", 1, 15, I("inv_misc_root_01"), 0, "Trade Goods", "Herb", "", { { "Briarthorn", "ffffff" } } },
    [2679] = { "Charred Wolf Meat", 1, 5, I("inv_misc_food_09"), 1, "Consumable", "Food & Drink", "", { { "Charred Wolf Meat", "ffffff" }, { "Use: Restores 61 health over 18 sec.", "1eff00" } } },
    [2672] = { "Stringy Wolf Meat", 1, 5, I("inv_misc_food_14"), 0, "Trade Goods", "Meat", "", { { "Stringy Wolf Meat", "ffffff" } } },
    [2681] = { "Roasted Boar Meat", 1, 5, I("inv_misc_food_04"), 1, "Consumable", "Food & Drink", "", { { "Roasted Boar Meat", "ffffff" }, { "Use: Restores 61 health over 18 sec.", "1eff00" } } },
    [769] = { "Chunk of Boar Meat", 1, 5, I("inv_misc_food_02"), 0, "Trade Goods", "Meat", "", { { "Chunk of Boar Meat", "ffffff" } } },
    [6888] = { "Herb Baked Egg", 1, 5, I("inv_misc_food_06"), 1, "Consumable", "Food & Drink", "", { { "Herb Baked Egg", "ffffff" }, { "Use: Restores 61 health over 18 sec.", "1eff00" } } },
    [6889] = { "Small Egg", 1, 5, I("inv_egg_01"), 0, "Trade Goods", "Meat", "", { { "Small Egg", "ffffff" } } },
    [2678] = { "Mild Spices", 1, 5, I("inv_misc_food_wheat_01"), 0, "Trade Goods", "Other", "", { { "Mild Spices", "ffffff" } } },
    [2996] = { "Bolt of Linen Cloth", 1, 10, I("inv_fabric_linen_02"), 0, "Trade Goods", "Cloth", "", { { "Bolt of Linen Cloth", "ffffff" } } },
    -- A pattern she found, for a profession she doesn't have.
    [4293] = { "Pattern: Embossed Leather Gloves", 1, 17, I("inv_scroll_03"), 0, "Recipe", "Leatherworking", "", { { "Pattern: Embossed Leather Gloves", "ffffff" },
        { "Requires Leatherworking (55)", "ff2020" }, { "Use: Teaches you how to make Embossed Leather Gloves.", "1eff00" } } },
}
local CLASS_OF = { Recipe = 9 } -- the game's numbers for an item's class, and a recipe's profession
local RECIPE_KIND = { Leatherworking = 1 }
local function link(id)
    local it = ITEMS[id]
    local colors = { [0] = "ff9d9d9d", "ffffffff", "ff1eff00", "ff0070dd", "ffa335ee" }
    return "|c" .. colors[it[2]] .. "|Hitem:" .. id .. "::::::::12:::::|h[" .. it[1] .. "]|h|r"
end
-- The game's item lookup as Forever has it: in C_Item only (it has no bare GetItemInfo).
C_Item = {
    GetItemInfo = function(x)
        local id = type(x) == "number" and x or tonumber(tostring(x):match("|Hitem:(%d+)"))
        local it = ITEMS[id]
        if not it then return nil end
        return it[1], link(id), it[2], it[3], it[5], it[6], it[7], 20, it[8], it[4], 25, CLASS_OF[it[6]] or 7, RECIPE_KIND[it[7]] or 0
    end,
}
GetDetailedItemLevelInfo = function(x) return select(4, C_Item.GetItemInfo(x)) end
local function tooltip(id)
    local lines = {}
    for _, l in ipairs(ITEMS[id][9]) do
        local function color(h) return { r = tonumber(h:sub(1, 2), 16) / 255, g = tonumber(h:sub(3, 4), 16) / 255, b = tonumber(h:sub(5, 6), 16) / 255 } end
        lines[#lines + 1] = { leftText = S(l[1]), leftColor = color(l[2]), rightText = l[3], rightColor = l[4] and color(l[4]) or nil }
    end
    return { lines = lines }
end

local GEAR = { [1] = 264120, [2] = 264131, [4] = 45, [5] = 264140, [6] = 264152, [7] = 264153, [8] = 264154,
    [9] = 264155, [10] = 264156, [11] = 264908, [15] = 2591, [16] = 264160, [18] = 264161, [20] = 4496, [21] = 4240 }
GetInventoryItemID = function(_, slot) return GEAR[slot] end
GetInventoryItemLink = function(_, slot) return GEAR[slot] and S(link(GEAR[slot])) end
GetInventoryItemDurability = function(slot)
    local d = { [1] = { 38, 45 }, [5] = { 61, 70 }, [16] = { 70, 85 }, [7] = { 40, 50 }, [8] = { 33, 40 } }
    if d[slot] then return S(d[slot][1]), d[slot][2] end
end
C_TooltipInfo = {
    GetHyperlink = function(l) local id = tonumber(tostring(l):match("item:(%d+)")) return id and ITEMS[id] and tooltip(id) or nil end,
    GetInventoryItem = function(_, slot) return GEAR[slot] and tooltip(GEAR[slot]) end,
    GetBagItem = function(bag, slot) local c = CONTAINERS[bag] local e = c and c[slot] return e and tooltip(e[1]) end,
}

CONTAINERS = {
    [0] = { size = 16, { 4540, 7 }, { 159, 12 }, { 118, 3 }, { 2318, 9 }, { 2589, 14 }, nil, { 765, 6 }, { 2447, 4 }, nil, { 264170, 1 }, { 264171, 1 }, { 264172, 2 } },
    [1] = { size = 6, { 264173, 1 }, { 4293, 1 }, { 2589, 5 } },
    [2] = { size = 8 },
}
local BANKS = { [6] = { size = 28, { 2318, 20 }, { 765, 11 } }, [7] = { size = 0 } }
local bankVisible = false
C_Container = {
    GetContainerNumSlots = function(bag)
        local c = CONTAINERS[bag] or (bankVisible and BANKS[bag])
        return c and c.size or 0
    end,
    GetContainerItemInfo = function(bag, slot)
        local c = CONTAINERS[bag] or (bankVisible and BANKS[bag])
        local e = c and c[slot]
        if not e then return nil end
        local it = ITEMS[e[1]]
        return { itemID = e[1], stackCount = S(e[2]), quality = it[2], iconFileID = it[4], hyperlink = link(e[1]) }
    end,
    ContainerIDToInventoryID = function(bag) return ({ [1] = 20, [2] = 21 })[bag] end,
}

-- Talents: Forever's three tabs on one trait tree, columns 600 apart, tabs ~2200 apart.
local TREE = {
    { "Improved Wrath", "spell_nature_abolishmagic", 0, 0, 3, 5 }, { "Nature's Grasp", "spell_nature_natureswrath", 600, 0, 0, 1 },
    { "Improved Nature's Grasp", "spell_nature_natureswrath", 1200, 0, 0, 4 },
    { "Improved Entangling Roots", "spell_nature_stranglevines", 0, 600, 0, 3 }, { "Improved Moonfire", "spell_nature_starfall", 600, 600, 0, 5 },
    { "Natural Weapons", "inv_staff_01", 1200, 600, 0, 5 }, { "Natural Shapeshifter", "spell_nature_wispsplode", 1800, 600, 0, 3 },
    { "Improved Thorns", "spell_nature_thorns", 0, 1200, 0, 3 }, { "Omen of Clarity", "spell_nature_crystalball", 1200, 1200, 0, 1 },
    { "Nature's Reach", "spell_nature_naturetouchgrow", 1800, 1200, 0, 2 }, { "Vengeance", "spell_nature_purge", 600, 1800, 0, 5 },
    { "Improved Starfire", "spell_arcane_starfire", 1200, 1800, 0, 5 }, { "Nature's Grace", "spell_nature_naturesblessing", 600, 2400, 0, 1 },
    { "Moonglow", "spell_nature_sentinal", 1200, 2400, 0, 3 }, { "Moonfury", "spell_nature_moonglow", 600, 3000, 0, 5 },
    { "Moonkin Form", "spell_nature_forceofnature", 600, 3600, 0, 1 },
    { "Ferocity", "ability_hunter_pet_hyena", 4400, 0, 0, 5 }, { "Feral Aggression", "ability_druid_demoralizingroar", 5000, 0, 0, 5 },
    { "Feral Instinct", "ability_ambush", 3800, 600, 0, 5 }, { "Brutal Impact", "ability_druid_bash", 4400, 600, 0, 2 },
    { "Thick Hide", "inv_misc_pelt_bear_03", 5000, 600, 0, 5 }, { "Feline Swiftness", "spell_nature_spiritwolf", 3800, 1200, 0, 2 },
    { "Feral Charge", "ability_hunter_pet_bear", 4400, 1200, 0, 1 }, { "Sharpened Claws", "inv_misc_monsterclaw_04", 5000, 1200, 0, 3 },
    { "Improved Shred", "spell_shadow_vampiricaura", 3800, 1800, 0, 2 }, { "Predatory Strikes", "ability_hunter_pet_cat", 4400, 1800, 0, 3 },
    { "Blood Frenzy", "ability_ghoulfrenzy", 5000, 1800, 0, 2 }, { "Primal Fury", "ability_racial_cannibalize", 5600, 1800, 0, 2 },
    { "Savage Fury", "ability_druid_ravage", 3800, 2400, 0, 2 }, { "Faerie Fire (Feral)", "spell_nature_faeriefire", 4400, 2400, 0, 1 },
    { "Heart of the Wild", "spell_holy_blessingofagility", 5000, 2400, 0, 5 }, { "Leader of the Pack", "spell_nature_unyeildingstamina", 4400, 3600, 0, 1 },
    { "Improved Mark of the Wild", "spell_nature_regeneration", 8200, 0, 0, 5 }, { "Furor", "spell_holy_blessingofstamina", 8800, 0, 0, 5 },
    { "Improved Healing Touch", "spell_nature_healingtouch", 7600, 600, 0, 5 }, { "Nature's Focus", "spell_nature_healingwavegreater", 8200, 600, 0, 5 },
    { "Improved Enrage", "ability_druid_enrage", 8800, 600, 0, 2 }, { "Reflection", "spell_frost_windwalkon", 8200, 1200, 0, 3 },
    { "Insect Swarm", "spell_nature_insectswarm", 8800, 1200, 0, 1 }, { "Subtlety", "ability_eyeoftheowl", 9400, 1200, 0, 5 },
    { "Tranquil Spirit", "spell_holy_elunesgrace", 8200, 1800, 0, 5 }, { "Improved Rejuvenation", "spell_nature_rejuvenation", 9400, 1800, 0, 3 },
    { "Nature's Swiftness", "spell_nature_ravenform", 7600, 2400, 0, 1 }, { "Gift of Nature", "spell_nature_protectionformnature", 8800, 2400, 0, 5 },
    { "Improved Tranquility", "spell_nature_tranquility", 9400, 2400, 0, 2 }, { "Improved Regrowth", "spell_nature_resistnature", 8800, 3000, 0, 5 },
    { "Swiftmend", "inv_relics_idolofrejuvenation", 8800, 3600, 0, 1 },
}
local LEGACY = {
    { "Well Rested", "spell_holy_sealofsacrifice", 0, 0, 2, 5 }, { "Fleet of Foot", "ability_druid_travelform", 600, 0, 1, 3 },
    { "Gatherer's Eye", "trade_herbalism", 0, 600, 0, 3 }, { "Old Coin", "inv_misc_orb_02", 600, 600, 0, 3 },
}
local function treeNodes(list, base) local ids = {} for i in ipairs(list) do ids[i] = base + i end return ids end
C_Traits = {
    GetConfigsByType = function(kind) return kind == 4 and { 901 } or kind == 3 and { 902 } or {} end,
    GetConfigInfo = function(config) return config == 901 and { treeIDs = { 801 } } or { treeIDs = { 1118, 1119 } } end,
    GetTreeNodes = function(tree)
        if tree == 801 then return treeNodes(TREE, 10000) end
        if tree == 1119 then return treeNodes(LEGACY, 20000) end
        return {}
    end,
    GetNodeInfo = function(config, id)
        local list, base = TREE, 10000
        if id > 20000 then list, base = LEGACY, 20000 end
        local t = list[id - base]
        if not t then return { ID = 0 } end
        local edges = {}
        if id == 10001 then edges = { { targetNode = 10002 } } end
        if id == 10002 then edges = { { targetNode = 10003 } } end
        return { ID = id, posX = t[3], posY = t[4], currentRank = S(t[5]), maxRanks = t[6], entryIDs = { id * 10 }, activeEntry = { entryID = id * 10 }, visibleEdges = edges, isVisible = true }
    end,
    GetEntryInfo = function(_, entryID) return { definitionID = entryID + 1 } end,
    GetDefinitionInfo = function(def) return { spellID = def + 500000 } end,
    GetTreeCurrencyInfo = function(config, tree)
        if config == 901 then return { { quantity = 0, spent = 3 } } end
        if tree == 1119 then return { { quantity = 5, spent = 3, maxQuantity = 16 } } end
        return {}
    end,
}
C_Spell = {
    GetSpellInfo = function(spellID)
        local id = math.floor((spellID - 500001) / 10)
        local list, base = TREE, 10000
        if id > 20000 then list, base = LEGACY, 20000 end
        local t = list[id - base]
        return t and { name = S(t[1]), iconID = I(t[2]) }
    end,
    GetSpellDescription = function(spellID)
        local info = C_Spell.GetSpellInfo(spellID)
        return info and ("Rank description for " .. tostring(info.name) .. ".")
    end,
}

GetProfessions = function() return 1, 2, nil, nil, 3 end
-- Each paper doll slot's silhouette, as the game gives it for an empty slot.
C_PaperDollInfo = { GetInventorySlotInfo = function(slotName) return 1, "Interface\\PaperDoll\\UI-PaperDoll-" .. slotName end }
GetProfessionInfo = function(i)
    local p = { { "Herbalism", I("trade_herbalism"), 64, 75 }, { "Alchemy", I("trade_alchemy"), 41, 75 }, { "Cooking", I("inv_misc_food_15"), 22, 75 } }
    local t = p[i]
    return S(t[1]), t[2], S(t[3]), t[4], 0, 0, 100 + i, 0
end
GetNumSkillLines = function() return scenario == "bare" and 0 or 4 end
-- The profession window, as the game's own (Blizzard_Professions): her Alchemy and Cooking, and
-- someone else's Tailoring linked in chat. It answers about recipes while it's open; what a recipe
-- makes and uses, the game knows any time.
local window -- what the window shows: { prof, linked }
local RECIPES = {
    [2330] = { "Minor Healing Potion", 118, { { 2447, 1 }, { 765, 1 }, { 3371, 1 } }, "Alchemy", 1001 },
    [2331] = { "Minor Mana Potion", 2455, { { 785, 1 }, { 765, 1 }, { 3371, 1 } }, "Alchemy", 1001 },
    [2337] = { "Lesser Healing Potion", 858, { { 118, 1 }, { 2450, 1 } }, "Alchemy", 1001 },
    [2538] = { "Charred Wolf Meat", 2679, { { 2672, 1 } }, "Cooking", 1101 },
    [2540] = { "Roasted Boar Meat", 2681, { { 769, 1 } }, "Cooking", 1101 },
    [8604] = { "Herb Baked Egg", 6888, { { 6889, 1 }, { 2678, 1 } }, "Cooking", 1102 },
    [2963] = { "Bolt of Linen Cloth", 2996, { { 2589, 2 } }, "Tailoring", 1201 },
}
local KNOWN = { [2330] = true, [2331] = true, [2538] = true, [2540] = true, [8604] = true }
local PROFESSIONS = { Alchemy = { 171, 41, 75 }, Cooking = { 185, 22, 75 }, Tailoring = { 197, 150, 150 } }
local GROUPS = { [1001] = "Potions", [1101] = "Meat", [1102] = "Eggs", [1201] = "Cloth" }
C_TradeSkillUI = {
    GetBaseProfessionInfo = function()
        local p = window and PROFESSIONS[window.prof]
        local V = window and window.plain and function(v) return v end or S
        if p then return { professionName = V(window.prof), professionID = V(p[1]), skillLevel = V(p[2]), maxSkillLevel = V(p[3]) } end
    end,
    IsTradeSkillLinked = function() if window and window.secretLink then return SECRET end return S(window ~= nil and window.linked == true) end,
    IsTradeSkillGuild = function() return S(false) end,
    IsNPCCrafting = function() return S(false) end,
    GetAllRecipeIDs = function()
        local ids = {}
        for rid, r in pairs(RECIPES) do if window and r[4] == window.prof then ids[#ids + 1] = rid end end
        table.sort(ids)
        return ids
    end,
    GetRecipeInfo = function(rid)
        local r = RECIPES[rid]
        if not (window and r and r[4] == window.prof) then return nil end
        local V = window.plain and function(v) return v end or S
        return { recipeID = rid, name = V(r[1]), learned = V(window.linked or KNOWN[rid] == true), icon = V(ITEMS[r[2]][4]), categoryID = V(r[5]),
            relativeDifficulty = V(rid == 2330 and 2 or 0) }
    end,
    GetRecipeSchematic = function(rid)
        local r = RECIPES[rid]
        if not r then return nil end
        local slots = {}
        for k, u in ipairs(r[3]) do slots[k] = { reagents = { { itemID = S(u[1]) } }, quantityRequired = S(u[2]), required = true } end
        return { outputItemID = S(r[2]), quantityMin = S(1), reagentSlotSchematics = slots, name = S(r[1]), icon = S(ITEMS[r[2]][4]) }
    end,
    GetCategoryInfo = function(id) return GROUPS[id] and { categoryID = id, name = S(GROUPS[id]) } end,
    GetProfessionInfoByRecipeID = function(rid) local r = RECIPES[rid] return r and { professionName = S(r[4]), professionID = S(PROFESSIONS[r[4]][1]) } end,
}
GetSkillLineInfo = function(i)
    local s = { { "Weapon Skills", true }, { "Staves", false, 58, 60 }, { "Unarmed", false, 31, 60 }, { "Languages", true } }
    local t = s[i]
    return t[1], t[2], false, t[3], 0, 0, t[4]
end
C_Reputation = {
    GetNumFactions = function() return 5 end,
    GetFactionDataByIndex = function(i)
        local f = {
            { name = "Alliance", isHeader = true },
            { name = "Valanaar", factionID = 2800, reaction = 5, currentStanding = S(4350), currentReactionThreshold = 3000, nextReactionThreshold = 9000, isChild = true },
            { name = "The Windshapers", factionID = 2801, reaction = 4, currentStanding = 1800, currentReactionThreshold = 0, nextReactionThreshold = 3000, isChild = true },
            { name = "Darnassus", factionID = 69, reaction = 4, currentStanding = 250, currentReactionThreshold = 0, nextReactionThreshold = 3000, isChild = true },
            { name = "Al'Aketh", factionID = 2802, reaction = 1, currentStanding = -30000, currentReactionThreshold = -42000, nextReactionThreshold = -6000, atWarWith = true },
        }
        return f[i]
    end,
}
C_QuestLog = {
    GetNumQuestLogEntries = function() return 4 end,
    GetInfo = function(i)
        local q = {
            { title = "Zephras Isle", isHeader = true },
            { title = "Al'Aketh Thugs", questID = 98101, level = 11 },
            { title = "Free the Hollows", questID = 98102, level = 12 },
            { title = "The Calmbreeze Crystal", questID = 98103, level = 12 },
        }
        return q[i]
    end,
    IsComplete = function(id) return id == 98103 end,
    GetTitleForQuestID = function(id) if id == 98201 then return S("The Lighthouse Keeper") end end,
    GetQuestObjectives = function(id)
        if id == 98101 then return { { text = "Al'Aketh Thug slain: 6/8", finished = false } } end
        if id == 98102 then return { { text = "Wind Hollow freed: 1/3", finished = false }, { text = "Speak with Ranger Ithiel", finished = true } } end
        return { { text = "Read the crystal", finished = true } }
    end,
}

-- What the game remembers from before Reliquary (History.lua): Legacy challenges (achievements),
-- completed quests, the explored map, lifetime statistics, PvP and titles.
local challenges = {
    { 64208, "A New Beginning", 5, true, 11, 6, 26, "Finish the journey on Zephras Isle.", true },
    { 64301, "Wings of the Isle", 10, true, 11, 7, 26, "", false },             -- another character's
    { 64302, "Calmbreeze Regular", 10, false, nil, nil, nil, "", true },
}
GetCategoryList = function() return S({ 15001 }) end
GetCategoryInfo = function(id) return ({ [15001] = S("Adventure"), [16001] = S("Combat") })[id], -1 end
GetCategoryNumAchievements = function(id) return id == 15001 and #challenges or id == 16001 and 2 or 0 end
GetAchievementInfo = function(a, b)
    if b then
        local x = challenges[b]
        return S(x[1]), S(x[2]), S(x[3]), S(x[4]), S(x[5]), S(x[6]), S(x[7]), S(x[8]), nil, nil, nil, nil, S(x[9])
    end
    return a, ({ [70001] = S("Creatures killed"), [70002] = S("Deaths") })[a]
end
GetStatisticsCategoryList = function() return S({ 16001 }) end
GetStatistic = function(_, i) if i == 1 then return S("214"), false, 70001 end return S("--"), false, 70002 end
GetPVPLifetimeStats = function() return S(0), S(0) end
GetNumTitles = function() return S(1) end
IsTitleKnown = function() return S(false) end
GetTitleName = function() return S("Private ") end
C_QuestLog.GetAllCompletedQuestIDs = function() return S({ 98001, 98002, 98003, 98004 }) end
C_QuestLog.RequestLoadQuestByID = function() end
local doneTitles = { [98001] = "Into the Grove", [98002] = "The Moonwell", [98003] = "Shadowgale's Edge" }
local logTitle = C_QuestLog.GetTitleForQuestID
C_QuestLog.GetTitleForQuestID = function(id) if doneTitles[id] then return S(doneTitles[id]) end return logTitle(id) end
C_Map.GetMapChildrenInfo = function(id) if id == 2440 then return { { mapID = 2441, name = S("Zephras Isle") }, { mapID = 2442, name = S("Darkshore") } } end return {} end
C_Map.GetMapArtLayers = function() return { { layerWidth = 1000, layerHeight = 700 } } end
C_Map.GetAreaInfo = function(id) return ({ [8001] = S("Thendal Village"), [8002] = S("Valanaar"), [8003] = S("Thendal Grove") })[id] end
C_MapExplorationInfo = {
    GetExploredMapTextures = function(id)
        if id == 2441 then return { { offsetX = 100, offsetY = 100, textureWidth = 400, textureHeight = 300 } } end
        return {}
    end,
    GetExploredAreaIDsAtPosition = function(_, at) if at.x < 0.25 then return { 8001 } elseif at.x < 0.35 then return { 8002, 8003 } end return { 8002 } end,
}
CreateVector2D = function(x, y) return { x = x, y = y } end
-- A class's dressing-room painting, as the game's atlas list has it: 478 by 500, in a sheet of its own
-- (the druid's is 4558154).
C_Texture = { GetAtlasInfo = function(atlas)
    local class = atlas:match("^dressingroom%-background%-(%l+)$")
    if not class then return nil end
    return { width = 478, height = 500, leftTexCoord = 0, rightTexCoord = 0.93359375, topTexCoord = 0, bottomTexCoord = 0.9765625,
        tilesHorizontally = false, tilesVertically = false, file = class == "druid" and 4558154 or 4558154 + #class * 7 + class:byte() }
end }
Enum.UIMapType = { Zone = 3 }

if scenario == "bare" then
    C_TooltipInfo, C_Traits, C_Spell, C_Reputation, C_QuestLog, C_GameRules, C_Map = nil, nil, nil, nil, nil, nil, nil
    C_TradeSkillUI = nil
    C_MapExplorationInfo = nil
    GetCategoryList, GetStatisticsCategoryList, GetPVPLifetimeStats, GetNumTitles = nil, nil, nil, nil
    Enum.BagIndex = nil
    GetFactionInfo = function(i)
        if i == 1 then return "Alliance", "", 4, 0, 3000, 100, false, false, true, false, false, false, false, 469 end
        return "Darnassus", "", 5, 3000, 9000, 4200, false, false, false, false, true, false, true, 69
    end
    GetNumFactions = function() return 2 end
    GetNumQuestLogEntries = function() return 1 end
    GetQuestLogTitle = function() return "The Calmbreeze Crystal", 12, nil, false, false, 1, nil, 98103 end
    local cc = C_Container
    C_Container = nil
    GetContainerNumSlots = cc.GetContainerNumSlots
    GetContainerItemInfo = function(bag, slot)
        local i = cc.GetContainerItemInfo(bag, slot)
        if i then return i.iconFileID, i.stackCount, false, i.quality, false, false, i.hyperlink, false, false, i.itemID end
    end
end

-- Screenshots and the camera: the interface, the settings, and what each picture looked like.
local uiShown, onHide = true, nil
UIParent = {}
function UIParent:IsShown() return uiShown end
function UIParent:GetWidth() return 1920 end
function UIParent:GetHeight() return 1080 end
-- The minimap where the game's own layout has it, in the top right corner (as in tests/share.lua).
CreateFrame("Frame", "Minimap"):SetSize(198, 198)
Minimap:SetPoint("CENTER", UIParent, "TOPRIGHT", -107.5, -143)
function UIParent:Hide()
    if not inCombat then uiShown = false end
    if onHide then local f = onHide onHide = nil f() end
end
function UIParent:Show() if not inCombat then uiShown = true end end
-- Alt+Z. Showing the interface again from a timer hides the druid mana bar, as on the live client.
AlternatePowerBar = { isEnabled = true, shown = true }
function AlternatePowerBar:IsShown() return self.shown end
function AlternatePowerBar:Show() if not inCombat then self.shown = true end end
local nameplates = true -- only Alt+Z hides them; hiding UIParent alone leaves them in the picture
SetUIVisibility = function(v)
    if inCombat then return end
    uiShown, nameplates = v, v
    if v then AlternatePowerBar.shown = false end
    if not v and onHide then local f = onHide onHide = nil f() end
end
cvars = { screenshotQuality = "3", cameraZoomSpeed = "20", UnitNameOwn = "0", UnitNameNPC = "1", UnitNameFriendlyPlayerName = "1" }
GetCVar = function(k) return cvars[k] end
SetCVar = function(k, v) if inCombat then error("blocked") end cvars[k] = tostring(v) end
-- The camera glides to a new distance at cameraZoomSpeed yards a second. In the full scenario
-- GetCameraZoom reports only where it is heading (the worst case); in the others, where it is.
-- yaw is the camera's angle from behind her: 0 is behind, 180 in front. She starts with the
-- camera turned to one side, as a player leaves it.
local cam = { target = 15, from = 15, t = 0, yaw = 70 }
local zoomReportsTarget = scenario == "full"
local function camNow()
    -- Full: a slow camera that ignores cameraZoomSpeed. Others: it follows the setting.
    local speed = scenario == "full" and 10 or tonumber(cvars and cvars.cameraZoomSpeed) or 20
    local d = cam.target - cam.from
    local travel = math.min(math.abs(d), speed * math.max(0, clock - cam.t))
    return cam.from + (d >= 0 and travel or -travel)
end
local function zoomTowards(goal) cam.from, cam.t, cam.target = camNow(), clock, math.max(0, math.min(39, goal)) end
GetCameraZoom = function() if zoomReportsTarget then return cam.target end return camNow() end
CameraZoomIn = function(d) zoomTowards(cam.target - d) end
CameraZoomOut = function(d) zoomTowards(cam.target + d) end
FlipCameraYaw = function(deg) cam.yaw = (cam.yaw + deg) % 360 cam.turnedAt = clock end
CenterCamera = function() cam.yaw = 0 cam.turnedAt = clock end
local swimming = false
IsSwimming = function() return swimming end
local shots, screenshotAnswers = {}, true
local function snap()
    shots[#shots + 1] = { ui = uiShown, quality = cvars.screenshotQuality, yaw = cam.yaw, zoom = camNow(), at = clock,
        sinceTurn = clock - (cam.turnedAt or -1e9), nameplates = nameplates,
        names = cvars.UnitNameOwn .. cvars.UnitNameNPC .. cvars.UnitNameFriendlyPlayerName, stamp = os.date("%m%d%y_%H%M%S", math.floor(clock)) }
    if screenshotAnswers then C_Timer.After(0.4, function() fire("SCREENSHOT_SUCCEEDED") end) end
end
Screenshot = snap
local form = 0
GetShapeshiftForm = function() return form end
GetShapeshiftFormInfo = function(i) if i == 1 then return 132276, true, true, 5487 end end
C_Spell = C_Spell or {}
C_Spell.GetSpellName = function(id) if id == 5487 then return S("Bear Form") end end
-- She is on the move until a test stands her still.
local moving, talking = true, false
GetUnitSpeed = function() return S(moving and 7 or 0) end
IsPlayerMoving = function() return S(moving) end
IsMounted = function() return false end
UnitOnTaxi = function() return false end
UnitInVehicle = function() return false end
UnitIsDeadOrGhost = function() return false end
UnitCastingInfo = function() return nil end
UnitChannelInfo = function() return nil end
IsMouselooking = function() return false end
IsMouseButtonDown = function() return false end
ChatEdit_GetActiveWindow = function() return nil end
UnitExists = function(u) return u == "npc" and talking end
GetTime = function() return clock end
C_Timer.NewTicker = function(sec, fn)
    local function again() fn() C_Timer.After(sec, again) end
    C_Timer.After(sec, again)
end
if scenario == "bare" then Screenshot, SetUIVisibility = nil, nil end
-- A crash in the middle of a photo last session left a name setting off: the next login fixes it.
cvars.UnitNameNPC = "0"
-- The window's movements land at once, as with the player's Animations switch off: the layout a test
-- measures is the finished one (a test of the motion turns it on).
ReliquaryDB = { settings = { restore = { UnitNameNPC = "1" }, motion = false } }

---------------------------------------------------------------------------
-- A session
---------------------------------------------------------------------------
-- The addon as the game loads it: each file the TOC lists, sharing one table.
local addonDir = tocPath:match("(.*/)") or "./"
local tocVersion
local files = {}
for line in io.lines(tocPath) do
    tocVersion = tocVersion or line:match("^## Version:%s*(%S+)")
    if line:match("^[%w_]+%.lua$") then files[#files + 1] = line end
end
C_AddOns = { GetAddOnMetadata = function(name, field) if name == "Reliquary" and field == "Version" then return tocVersion end end }
if scenario ~= "bare" then
    C_EncodingUtil = dofile(here .. "encoding.lua")
    Enum.CompressionMethod = { Deflate = 0 }
end
local sent = {}
C_ChatInfo = { RegisterAddonMessagePrefix = function() return 0 end,
    SendAddonMessage = function(prefix, text, kind, target) sent[#sent + 1] = { prefix, text, kind, target } return 0 end }
IsInInstance = function() return false end
local ns = {}
for _, file in ipairs(files) do assert(loadfile(addonDir .. file))("Reliquary", ns) end
fire("ADDON_LOADED", "Reliquary")
fire("PLAYER_LOGIN")
fire("PLAYER_ENTERING_WORLD", true, false)
advance(2)
-- Its minimap button, in every scenario (in combat, and on a client without much of the API).
assert(ReliquaryMinimapButton and ReliquaryMinimapButton:IsShown() and ReliquaryMinimapButton:GetParent() == Minimap, "no minimap button")
if scenario == "combat" then
    assert(ReliquaryDB.chars["Joan Ofârc-CAMWOWUS2Realm11RP"].gear == nil, "scanned in combat")
    SlashCmdList.RELIQUARY("photo")
    advance(1)
    assert(#shots == 0 and uiShown, "photo taken in combat")
    inCombat = false
    fire("PLAYER_REGEN_ENABLED")
end
advance(20)
-- Main-hand damage uses the character sheet's floor/ceil and minimum of one, never nearest
-- rounding. Exercise the actual event-driven scan, including unavailable and protected endpoints.
do
    local damage = UnitDamage
    local me = ReliquaryDB.chars["Joan Ofârc-CAMWOWUS2Realm11RP"] or ReliquaryDB.chars["Unknown-CAMWOWUS2Realm11RP"]
    for _, sample in ipairs({
        { low = 1.6, high = 3.2, want = { 1, 4 } },
        { low = 2, high = 4, want = { 2, 4 } },
        { low = 0, high = 0.2, want = { 1, 1 } },
        { low = -2, high = -1, want = { 1, 1 } },
        { high = 4 }, { low = 1 }, { low = SECRET, high = 4 }, { low = 1, high = SECRET },
        { low = 0 / 0, high = 4 }, { low = 1, high = math.huge },
    }) do
        UnitDamage = function() return sample.low, sample.high end
        fire("UNIT_STATS", "player")
        advance(2)
        local got = me.stats.dmg
        assert(sample.want and got and got[1] == sample.want[1] and got[2] == sample.want[2] or not sample.want and got == nil,
            "main-hand damage differs from the character sheet")
    end
    UnitDamage = damage
    fire("UNIT_STATS", "player")
    advance(2)
end
fire("ZONE_CHANGED", nil)
GetSubZoneText = function() return "Thendal Grove" end
fire("ZONE_CHANGED")
advance(3)
bankVisible = true
fire("BANKFRAME_OPENED")
advance(3)
bankVisible = false
fire("BANKFRAME_CLOSED")
-- 13a. Professions: her Alchemy window, then her Cooking in the same window, read as the game shows
-- them; a fight holds the read back until it ends; someone else's Tailoring, linked, is never hers;
-- and a recipe learned with the window closed joins her Alchemy.
if secrets then
    -- Everything about it plain but whether it's someone else's: never read.
    window = { prof = "Alchemy", plain = true, secretLink = true }
    fire("TRADE_SKILL_SHOW")
    advance(2)
    local me = ReliquaryDB.chars["Joan Ofârc-CAMWOWUS2Realm11RP"] or ReliquaryDB.chars["Unknown-CAMWOWUS2Realm11RP"]
    assert(not me.recipes, "a profession window the game wouldn't say was hers was read")
    window = nil
    fire("TRADE_SKILL_CLOSE")
end
if scenario == "combat" then inCombat = true end
window = { prof = "Alchemy" }
fire("TRADE_SKILL_SHOW")
advance(2)
if scenario == "combat" then
    local me = ReliquaryDB.chars["Joan Ofârc-CAMWOWUS2Realm11RP"]
    assert(not (me.recipes and me.recipes.Alchemy), "a profession window was read in a fight")
    inCombat = false
    fire("PLAYER_REGEN_ENABLED")
    advance(2)
end
window = { prof = "Cooking" }
fire("TRADE_SKILL_DATA_SOURCE_CHANGED")
advance(2)
window = { prof = "Tailoring", linked = true }
fire("TRADE_SKILL_DATA_SOURCE_CHANGED")
advance(2)
window = nil
fire("TRADE_SKILL_CLOSE")
KNOWN[2337] = true
fire("NEW_RECIPE_LEARNED", 2337, 1, 2337)
advance(5)
-- Photos ----------------------------------------------------------------------
local auto = scenario == "full" or scenario == "combat"   -- the game tells us enough to take them
local function goTo(sub)
    GetSubZoneText = function() return S(sub) end
    fire("ZONE_CHANGED")
end
local function near(a, b) return math.abs(a - b) < 0.01 end
local function framed(shot, zoom)
    return shot.ui == false and not shot.nameplates and shot.quality == "10" and shot.yaw == 180 and near(shot.zoom, zoom) and shot.names == "000"
        and shot.sinceTurn >= 0.5 -- the camera had time to finish its swing
end
-- After a framed photo the camera is behind her (0); an unframed one leaves it alone (70).
local function camBack() return (cam.yaw == 0 or cam.yaw == 70) and near(camNow(), 15) end
local function settledBack()
    return uiShown and camBack() and cvars.screenshotQuality == "3" and cvars.cameraZoomSpeed == "20"
        and cvars.UnitNameOwn .. cvars.UnitNameNPC .. cvars.UnitNameFriendlyPlayerName == "011"
        and (scenario == "bare" or AlternatePowerBar.shown) and not ReliquaryDB.settings.restore
end
assert(cvars.UnitNameNPC == "1" and not ReliquaryDB.settings.restore, "settings a crash left behind not put back at login")

-- 1. /rq photo: the camera stays exactly where the player left it.
SlashCmdList.RELIQUARY("photo")
if scenario ~= "bare" then assert(not uiShown, "interface not hidden for the photo") end
advance(1)
assert(uiShown and cvars.screenshotQuality == "3", "interface or quality not restored after the photo")
if scenario ~= "bare" then
    assert(#shots == 1 and shots[1].ui == false and shots[1].quality == "10" and shots[1].yaw == 70 and shots[1].zoom == 15 and shots[1].names == "000" and not shots[1].nameplates, "manual photo")
    advance(1)
    assert(settledBack(), "settings, names or the druid mana bar not put back after the photo")
end

-- 2. The player's own Print Screen, in Bear Form.
form = 1
fire("SCREENSHOT_SUCCEEDED")

-- 3. A level-up and a new place wait while she runs, and while she is a bear.
fire("PLAYER_LEVEL_UP", 13)
local before = #shots
form = 0
advance(30)
assert(#shots == before, "photo taken while she was moving")
form = 1
moving = false
advance(15)
assert(#shots == before, "photo taken in Bear Form")
form = 0
advance(4)
if auto then
    assert(#shots == before + 1 and framed(shots[#shots], 5), "level-up photo not framed at 5 yards")
    advance(3)
    assert(settledBack(), "camera, interface or settings not put back after the level-up photo")
    -- 4. Then the new place she reached while running, framed wider, and 5. as she is resting,
    -- a close portrait. Never two at once: at least eight seconds apart.
    advance(40)
    assert(#shots == before + 3, "place photo and portrait: " .. (#shots - before - 1))
    assert(framed(shots[before + 2], 9), "place photo")
    assert(framed(shots[before + 3], 3.2), "resting portrait")
    advance(60)
    assert(#shots == before + 3, "second portrait in one session")
    assert(settledBack(), "not settled after the portrait")
    -- 6. A second new place waits for the three-minute gap between place photos.
    goTo("Moonwell Glade")
    advance(60)
    assert(#shots == before + 3, "place photos too close together")
    advance(130)
    assert(#shots == before + 4 and framed(shots[#shots], 9), "second place photo")
    -- 6b. Floating still in water is not standing still.
    swimming = true
    goTo("Moonwell Pool")
    advance(200)
    assert(#shots == before + 4, "photo taken while swimming")
    swimming = false
    goTo("Moonwell Glade")
    -- 7. Talking to someone: no photo until the conversation ends.
    talking = true
    goTo("Starfall Rest")
    advance(200)
    assert(#shots == before + 4, "photo taken while talking to someone")
    talking = false
    advance(10)
    assert(#shots == before + 5, "photo after the conversation")
    -- 8. A fight starts as the interface hides, or a moment later, just before the picture:
    -- no picture either way, and everything comes back.
    for _, delay in ipairs({ 0, 0.1 }) do
        goTo("Windward Rise " .. delay)
        onHide = function()
            if delay == 0 then inCombat = true else C_Timer.After(delay, function() inCombat = true end) end
        end
        advance(200)
        assert(#shots == before + 5, "picture taken after a fight started (" .. delay .. " s)")
        assert(camBack(), "camera not put back when the photo was called off")
        inCombat = false
        fire("PLAYER_REGEN_ENABLED")
        advance(3)
        assert(settledBack(), "not settled after the fight")
    end
    -- 9. The game refuses to turn the camera: framing stops, photos carry on unframed.
    local flip = FlipCameraYaw
    FlipCameraYaw = function() fire("ADDON_ACTION_BLOCKED", "Reliquary", "FlipCameraYaw()") end
    goTo("Silverwind Refuge")
    advance(200)
    assert(#shots == before + 5, "picture taken during a refused framing")
    assert(ReliquaryDB.settings.framing == false, "framing not turned off after the game refused it")
    advance(3)
    assert(uiShown and camBack() and cvars.cameraZoomSpeed == "20", "not settled after the refusal")
    FlipCameraYaw = flip
    goTo("Shrine of the Moon")
    advance(200)
    assert(#shots == before + 6 and shots[#shots].yaw ~= 180 and near(shots[#shots].zoom, 15) and shots[#shots].ui == false, "unframed photo after the refusal")
    ReliquaryDB.settings.framing = nil
    -- 10. /rq auto turns them all off, and back on.
    SlashCmdList.RELIQUARY("auto")
    fire("PLAYER_LEVEL_UP", 14)
    goTo("Elune's Rest")
    advance(400)
    assert(#shots == before + 6, "automatic photo with /rq auto off")
    SlashCmdList.RELIQUARY("auto")
else
    advance(400)
    assert(#shots == before, "automatic photo when the game hides whether she is moving")
end
moving = true

-- 11. /rq portrait: framed now, whatever she is doing.
before = #shots
SlashCmdList.RELIQUARY("portrait")
advance(5)
if scenario ~= "bare" then assert(#shots == before + 1 and framed(shots[#shots], 3.2), "/rq portrait") end
assert(uiShown and camBack(), "not settled after /rq portrait")

-- 11b. Two framed photos back to back: the zoom speed still ends up as the player had it.
if scenario ~= "bare" then
    before = #shots
    SlashCmdList.RELIQUARY("portrait")
    advance(2.6)
    -- Not framed, so it never touches the zoom speed itself, and still running (the game is
    -- slow to answer) when the first photo's delayed zoom-speed restore comes due.
    screenshotAnswers = false
    SlashCmdList.RELIQUARY("photo")
    advance(8)
    screenshotAnswers = true
    assert(#shots == before + 2, "back-to-back photos")
    assert(uiShown and camBack() and cvars.cameraZoomSpeed == "20" and not ReliquaryDB.settings.restore, "zoom speed left changed after back-to-back photos")
end

-- 12. A fight that starts between hiding the interface and the picture: it comes back afterwards.
SlashCmdList.RELIQUARY("photo")
inCombat = true
advance(1)
if scenario ~= "bare" then assert(not uiShown and cvars.screenshotQuality == "10", "interface or quality changed during combat") end
inCombat = false
fire("PLAYER_REGEN_ENABLED")
assert(uiShown and cvars.screenshotQuality == "3", "interface or quality not restored after the fight")

-- 13. The game never answers: the interface still comes back.
screenshotAnswers = false
SlashCmdList.RELIQUARY("photo")
advance(6)
assert(uiShown and cvars.screenshotQuality == "3", "interface or quality stuck after an unanswered screenshot")
screenshotAnswers = true
-- 13b. Travel for the timeline: a quest handed in and killing blows on Zephras Isle (a
-- groupmate's does not count), a short crossing, then long enough in Darkshore for an entry.
fire("QUEST_TURNED_IN", S(98103), S(850), S(0))
for _ = 1, 3 do fire("PARTY_KILL", S("Player-3299-0A1B2C3D"), S("Creature-0-3299-1")) end
fire("PARTY_KILL", S("Player-3299-0E0F1A2B"), S("Creature-0-3299-2"))
GetRealZoneText = function() return S("The Great Sea") end
fire("ZONE_CHANGED_NEW_AREA")
advance(240)
GetRealZoneText = function() return S("Darkshore") end
GetSubZoneText = function() return S("Auberdine") end
GetMinimapZoneText = function() return S("Auberdine") end
fire("ZONE_CHANGED_NEW_AREA")
advance(660)
for _ = 1, 2 do fire("PARTY_KILL", S("Player-3299-0A1B2C3D"), S("Creature-0-3299-3")) end
fire("QUEST_TURNED_IN", S(98201), S(1100), S(0))
advance(60)

IsMacClient = function() return true end -- the copy key the item page names (Cmd+C on a Mac)
-- 15. /rq opens the window, every tab draws, and the Sharing tab's boxes are this character's own
-- switches. A character that shares nothing, with no guild and no friends online, sends nothing.
do
    local me = ReliquaryDB.chars["Joan Ofârc-CAMWOWUS2Realm11RP"] or ReliquaryDB.chars["Unknown-CAMWOWUS2Realm11RP"]
    assert(type(me.share) == "table" and me.share.guild == false and me.share.friends == false and me.share.public == false, "a new character must share nothing")
    assert(ReliquaryDB.schema == 2 and ReliquaryDB.meta.addon == tocVersion, "version " .. tostring(ReliquaryDB.meta.addon) .. " is not the TOC's " .. tostring(tocVersion))
    assert(ReliquaryDB.meta.names == "regional" and me.surname == (not secrets and "Ofârc" or nil), "Forever's names: the family name and how players are named")
    SlashCmdList.RELIQUARY("")
    local win = ReliquaryFrame
    assert(win and win:IsShown() and win.wordmark._text == "RELIQUARY" and win.selectedTab == 1, "/rq didn't open the window")
    -- Escape closes it through its stand-in, shown while the window is.
    assert(UISpecialFrames[#UISpecialFrames] == "ReliquaryEscape" and ReliquaryEscape:IsShown(), "Escape doesn't close the window")
    -- A tab with nothing to show for this character (no guild, nobody sharing with everyone) is greyed
    -- and takes no click, and says why on hover; the others open.
    local open, greyed = 0, {}
    for i = 1, #win.Tabs do
        local tab = win.Tabs[i]
        ui.run(tab, "OnClick")
        if tab:IsEnabled() then
            open = open + 1
            assert(win.selectedTab == i and not tab.reason, "tab " .. i)
        else
            assert(win.selectedTab ~= i and tab.reason, "a greyed tab " .. i .. " opened, or says nothing of why")
            GameTooltip._texts = {}
            ui.run(tab, "OnEnter")
            assert(GameTooltip._shown and table.concat(GameTooltip._texts, " ") == tab.reason, "a greyed tab's reason on hover: " .. tostring(tab.reason))
            greyed[#greyed + 1] = tab.label._text
        end
    end
    assert(table.concat(greyed, ",") == "Guild,Guild Bank,Friends,Public", "the greyed tabs: " .. table.concat(greyed, ","))
    -- The Sharing tab: "Share with anyone" switches public on for this character only, and back.
    local sharing
    for _, child in ipairs(ui.frames) do if child._kind == "CheckButton" and child.key == "public" then sharing = child end end
    assert(sharing and sharing:IsVisible(), "no visible public box on the Sharing tab")
    sharing:SetChecked(true)
    ui.run(sharing, "OnClick")
    assert(me.share.public == true, "the public box didn't switch sharing on")
    SlashCmdList.RELIQUARY("share public off")
    assert(me.share.public == false, "/rq share public off")
    SlashCmdList.RELIQUARY("share public on") -- Joan shares publicly: the photo tests read the public copy
    SlashCmdList.RELIQUARY("")
    assert(not win:IsShown(), "/rq again didn't close the window")
    -- Opening, each tab, the switch ticked on, closing: each with the game's own sound.
    assert(table.concat(played, ",") == "839," .. ("841,"):rep(open) .. "856,840", "the window's sounds: " .. table.concat(played, ","))
    assert(#sent == 0, "a character sharing nothing sent " .. #sent .. " messages")
end

-- 15b. The window's Characters tab: every character on the account, the one played now first, each
-- with every part of it whatever it shares (Joan shares nothing), its timeline with each stop's
-- details a click away, its recipes, and its bags in full however many items they hold. Nothing in
-- the window points anywhere outside the game.
do
    local joanKey = ReliquaryDB.chars["Joan Ofârc-CAMWOWUS2Realm11RP"] and "Joan Ofârc-CAMWOWUS2Realm11RP" or "Unknown-CAMWOWUS2Realm11RP"
    local miraKey = "Mira Vale-CAMWOWUS2Realm11RP"
    local mira = { name = "Mira", surname = "Vale", realm = ReliquaryDB.chars[joanKey].realm, level = 30, class = "Mage", classFile = "MAGE",
        race = "Human", updated = time() - 3 * 3600, share = { guild = false, friends = false, public = false },
        profs = { { name = "Tailoring", skill = 60, max = 75 }, { name = "Enchanting", skill = 40, max = 75 }, { name = "First Aid", skill = 75, max = 75 },
            { name = "Cooking", skill = 30, max = 75 }, { name = "Fishing", skill = 12, max = 75 } },
        recipes = { Tailoring = { line = 197, list = { [2385] = { o = 2568, n = "Brown Linen Vest", u = { { id = 2589, n = 3 } } } } } },
        bags = { { size = 140, bag = 0, slots = {} }, { size = 32, bag = -1, slots = { [1] = { id = 7146, name = "The Scarlet Key", q = 1 },
            [6] = { id = 5396, name = "Key to Searing Gorge", q = 1 } } } },
        -- The bank as this game keeps it: its own slots in a container the game names for its developers,
        -- and a bag in one of its bag slots.
        bank = { { size = 48, bag = 6, item = { id = 194019, name = "Character Bank Tab Bag (DNT)" }, slots = { [3] = { id = 2589, name = "Linen Cloth", n = 5, q = 1 } } },
            { size = 6, bag = 7, item = { id = 4238, name = "Linen Bag", icon = 133652, q = 1 }, slots = {} } } }
    for i = 1, 130 do mira.bags[1].slots[i] = { id = 2589, name = "Linen Cloth", n = 2, q = 1 } end
    -- Her one stop: half an hour either side of midnight, with nothing more to it.
    local today = os.date("*t", time())
    local midnight = os.time({ year = today.year, month = today.month, day = today.day, hour = 0 })
    mira.timeline = { entries = { { zone = "Elwynn Forest", from = midnight - 1800, to = midnight + 1200, active = 1500, level = 30 } } }
    ReliquaryDB.chars[miraKey] = mira
    SlashCmdList.RELIQUARY("")
    local win = ReliquaryFrame
    ui.run(win.Tabs[1], "OnClick")
    assert(win:IsShown() and win.selectedTab == 1, "the Characters tab")
    local function visible(pred)
        for _, f in ipairs(ui.frames) do if pred(f) and f:IsVisible() then return f end end
    end
    local list = visible(function(f) return f._rows and f._rows[1] and f._rows[1].row ~= nil end)
    assert(list and #list._rows == 2, "the Characters tab lists both characters")
    assert(list._rows[1].row.key == joanKey and list._rows[2].row.key == miraKey, "the character played now comes first, then by level: " .. tostring(list._rows[1].row.key))
    assert(list._rows[1].dot:IsShown() and not list._rows[2].dot:IsShown(), "the green dot marks the character played now")
    local d = visible(function(f) return f.pageButtons ~= nil end)
    assert(d and d.when._text == "Playing now", "Joan's page: " .. tostring(d and d.when._text))
    -- Heading the rail: how many characters there are, and the gold and time played between them (Mira
    -- has neither, so they're Joan's, as the chips along her hero show them).
    if scenario ~= "secrets" then
        local summary = visible(function(f) return rawget(f, "summary") ~= nil and rawget(f, "browser") ~= nil end).summary
        local gold, time = d.chips.gold, d.chips.played
        assert(gold:IsShown() and time:IsShown() and summary._text == "2 characters · " .. gold.text._text .. " · " .. time.text._text,
            "the Characters tab's header: " .. tostring(summary._text) .. " | " .. tostring(gold.text._text) .. " | " .. tostring(time.text._text))
    end
    -- Joan has no guild: the line under her race and class moves up rather than leaving a gap.
    assert(d.when._points.TOPLEFT.rel == d.what, "an empty guild line left a gap")
    -- On a Mac, the item page names the Mac's copy key.
    assert(ReliquaryItemPage.linkNote._text:find("(Cmd+C)", 1, true), "the Mac's copy key: " .. tostring(ReliquaryItemPage.linkNote._text))
    local function pageButton(page)
        for _, b in ipairs(d.pageButtons) do if b.page == page and b:IsShown() then return b end end
    end
    local function selected()
        local on = {}
        for _, b in ipairs(d.pageButtons) do if b:IsShown() and b:IsSelected() then on[#on + 1] = b.page end end
        return table.concat(on, ",")
    end
    -- A timeline when the game gave Reliquary one to keep (a client hiding everything gives none),
    -- never a Roleplay page: your own profile is in Total RP 3 itself.
    assert((scenario == "secrets") == (pageButton("road") == nil) and not pageButton("rp"), "your character's Timeline and Roleplay pages")
    assert(selected() == "gear", "the Gear tab is the one selected: " .. selected())
    laidOut("Joan's gear")
    -- The gear page: every slot in Reliquary's rounded frame, the line taking the item's quality colour
    -- (Joan's circlet is uncommon: green); each item's name in its quality's colour beside it, with its
    -- item level; the item level over the crest between the columns.
    do
        local head = d.slots[1]
        local q = scenario ~= "secrets" and head.rq and head.rq.q
        assert(head.rqLine and head.rqWell and head.rqGlow, "the gear page's slots")
        if q then
            assert(head.label:IsShown(), "the head slot's name")
            local r, g, b = head.rqLine:GetColor()
            local qr, qg, qb = ns.Skin.qualityColor(q)
            assert(math.abs(r - qr * 0.8) < 0.001 and math.abs(g - qg * 0.8) < 0.001 and math.abs(b - qb * 0.8) < 0.001
                and head.label._text:find(ITEM_QUALITY_COLORS[q].hex, 1, true), "the head slot's quality colour on its line and its name")
            -- Its item level on a small plate at the slot's corner; an empty slot has none.
            local plate = head.rqPlate
            assert(plate and plate:IsShown() and plate.text._text:match("^%d+$"), "the head slot's item level: " .. tostring(plate and plate.text._text))
            assert(not (d.slots[3].rqPlate and d.slots[3].rqPlate:IsShown()), "an empty slot has an item level")
            -- Its icon cut in past the border the game bakes into every icon, each time the game sets it.
            local cut = head.icon._texCoord
            assert(cut and cut[1] == 0.08 and cut[2] == 0.92 and cut[3] == 0.08 and cut[4] == 0.92 and head.icon._texture == head._icon,
                "the head slot's icon isn't cut in from its edge")
            -- Its name (two lines in the full scenario) with room between the lines and under the last
            -- for its letters' tails: one block, centred on the slot.
            local name, slot, lh = ui.rect(head.label), ui.rect(head), head.label:GetLineHeight()
            local lines = name and math.floor((name.top - name.bottom - 4) / lh + 0.001) or 0
            local tall = lines * lh + (lines - 1) * 4
            assert(lines >= 1 and (scenario ~= "full" or lines == 2) and math.abs((name.top - name.bottom) - (tall + 4)) < 0.01,
                "the head slot's name has no room for its lines: " .. tostring(name and name.top - name.bottom))
            assert(math.abs(name.top - tall / 2 - (slot.top + slot.bottom) / 2) < 0.5, "the head slot's name isn't centred on the slot")
        end
        -- Between the columns a niche: in it the class's crest in its light, or the played character's
        -- model in the crest's place; on its plinth the item level.
        local stands = d.model:IsShown() and d.model or d.mark
        local niche, figure, sill = ui.rect(d.niche), ui.rect(stands), ui.rect(d.ilvl)
        assert(d.niche.line.art == "ring" and d.niche.floor.art == "disc" and d.niche.art:DoesClipChildren(), "the niche's arch")
        assert(stands:IsShown() and d.model:IsShown() ~= d.mark:IsShown() and figure.top <= niche.top and figure.bottom >= niche.bottom + 52
            and d.niche.moon._points.CENTER.rel == d.mark, "nothing stands in the niche's light, or the crest and the model both do")
        assert(scenario == "secrets" or sill.top <= niche.bottom + 52 and sill.bottom >= niche.bottom, "the item level isn't on the niche's plinth")
        assert(d.ilvl:IsShown() == (scenario ~= "secrets") and (scenario == "secrets" or d.ilvl._text == "13"), "the item level: " .. tostring(d.ilvl._text))
        assert(d.niche.step:IsShown() == d.ilvl:IsShown(), "the niche's plinth is marked off with no item level to stand on it")
    end
    -- Behind Joan's name, her class's painting: a band of it at the painting's own proportions, and
    -- each character in the list with their class's icon.
    if scenario ~= "secrets" then
        local art = d.paintings[d.front]
        local tc, box = art._texCoord, ui.rect(d.hero)
        assert(art:IsShown() and art._texture == 4558154 and tc and box, "the druid's painting behind Joan's name")
        local wide, high = (tc[2] - tc[1]) / 0.93359375 * 478, (tc[4] - tc[3]) / 0.9765625 * 500
        assert(math.abs((wide / high) / ((box.right - box.left) / (box.top - box.bottom)) - 1) < 0.01,
            ("the painting behind Joan's name is stretched: %.2f against %.2f"):format(wide / high, (box.right - box.left) / (box.top - box.bottom)))
        assert(list._rows[1].class._atlas == "classicon-druid" and list._rows[2].class._atlas == "classicon-mage",
            "each character's class icon: " .. tostring(list._rows[1].class._atlas) .. ", " .. tostring(list._rows[2].class._atlas))
    end
    -- The crest at the top bar's left: Reliquary's shrine in its ring, the art centred in the ring, drawn
    -- from the texture nearest the size the screen shows it (32 units), after a change of screen or of
    -- the window's scale too.
    do
        local c = win.crest
        local cb, ab = ui.rect(c), ui.rect(c.art)
        assert(cb and ab and math.abs((cb.left + cb.right) / 2 - (ab.left + ab.right) / 2) < 0.001 and math.abs((cb.top + cb.bottom) / 2 - (ab.top + ab.bottom) / 2) < 0.001
            and math.abs(ab.right - ab.left - 32) < 0.001, "the crest isn't centred in its ring")
        local screen, scale = GetPhysicalScreenSize, win._scale
        for _, case in ipairs({ { 4320, 1, 256 }, { 2160, 1, 128 }, { 2160, 1.25, 128 }, { 1440, 1, 64 }, { 2160, 0.75, 128 }, { 1080, 1, 64 } }) do
            GetPhysicalScreenSize = function() return case[1] * 16 / 9, case[1] end
            win:SetScale(case[2])
            fire("UI_SCALE_CHANGED")
            assert(c.art._texture == "Interface\\AddOns\\Reliquary\\Media\\portrait-" .. case[3],
                ("the crest at %dp, scale %.2f: %s"):format(case[1], case[2], tostring(c.art._texture)))
        end
        GetPhysicalScreenSize, win._scale = screen, scale
        fire("DISPLAY_SIZE_CHANGED")
    end
    -- An empty slot shows the paper doll's silhouette; the list marks the character played now with a
    -- verdant presence dot; a list's scroll bar hides when there is nothing to scroll.
    do
        local dot = list._rows[1].dot
        local r, g, b = dot:GetVertexColor()
        local vr, vg, vb = ns.Skin.rgb("verdant")
        assert(d.slots[1].emptyBackgroundTexture == "Interface\\PaperDoll\\UI-PaperDoll-HeadSlot" and r == vr and g == vg and b == vb
            and d.roadBar._hideIfUnscrollable and d.itemsBar._hideIfUnscrollable and d.listBar._hideIfUnscrollable and d.sheetBar._hideIfUnscrollable,
            "the silhouettes, the presence dot, the scroll bars")
    end
    -- The character sheet, one card beside the paper doll, as the game's own sheet orders it: the
    -- professions first, then its groups in order, each with what the game recorded for Joan, a pixel
    -- line over every group but the first.
    if scenario ~= "secrets" then
        local sheet, heads = {}, {}
        for i, r in ipairs(d.sheet._rows) do
            local l = r.line
            if l.kind == "shead" then
                heads[#heads + 1] = l.left
                assert(r.rule:IsShown() == (i > 1), "the line over the sheet's group " .. l.left)
            elseif l.kind == "stat" then sheet[l.left] = { value = l.right, tip = l.tip } end
        end
        local order = table.concat(heads, ",")
        assert(order == "General,Attributes,Weapons,Modifiers,Defense,Resistance" or order == "Professions,General,Attributes,Weapons,Modifiers,Defense,Resistance",
            "the sheet's groups: " .. order)
        assert(sheet.Health and sheet.Health.value == "342" and sheet.Mana and sheet.Mana.value == "455" and sheet.Experience and sheet.Experience.value == "3,890 / 8,800"
            and sheet.Rested and sheet.Hearthstone and sheet.Hearthstone.value == "Valanaar" and sheet.Played, "the sheet's General: " .. tostring(sheet.Health and sheet.Health.value))
        assert(sheet.Strength and sheet.Strength.tip and sheet.Strength.tip[1]:find("^Base "), "Strength with its base on hover")
        assert(sheet.Arcane and sheet.Fire and sheet.Shadow and sheet.Armor, "resistances and armor, shown even at nothing")
    end
    -- Talents: the druid's three trees as three cards, each with the tree's name and points in its
    -- header and its painting under them; the talents on it, a learned one with its rank on a plate, one
    -- not learned grey and dim; the arrows between them; Joan's Legacy a fourth card under them; all of
    -- it the page's height at most, its talents as large as that allows.
    if scenario ~= "secrets" and scenario ~= "bare" then
        local M, Skin = ns.Motion, ns.Skin
        ui.run(assert(pageButton("tal"), "Joan has no Talents page"), "OnClick")
        local learned, grey, wrath, dim = 0, 0, nil, nil
        for _, b in ipairs(d.talentButtons) do
            if b:IsShown() then
                if b.talent.rank > 0 then learned = learned + 1 else grey = grey + 1 dim = dim or b end
                if b.talent.name == "Improved Wrath" then wrath = b end
            end
        end
        -- Whether a colour ({ r, g, b }) is one of the window's.
        local function colorIs(c, name)
            local r, g, b = Skin.rgb(name)
            return math.abs(c[1] - r) < 1e-6 and math.abs(c[2] - g) < 1e-6 and math.abs(c[3] - b) < 1e-6
        end
        assert(learned == 1 and grey == 46 and wrath and wrath.state == "part" and wrath.plate:IsShown() and wrath.plate.text._text == "3/5"
            and colorIs({ wrath.tile.line:GetColor() }, "verdant") and colorIs(wrath.plate.text._textColor, "verdant"),
            "Joan's talents: " .. learned .. " learned, " .. grey .. " not")
        assert(dim.state == "none" and not dim.plate:IsShown() and dim.tile.icon:GetAlpha() < 1 and colorIs({ dim.tile.line:GetColor() }, "ink600"),
            "a talent not learned isn't grey and dim")
        local cards = d.treeCards
        -- The trees and the Legacy fit the page at the largest talents that let them (32 here, beside the
        -- game's own 40), unshrunk; the Legacy's card under the trees.
        local a, lc, pageBox = ui.rect(cards[1]), ui.rect(d.legacyCard), ui.rect(d.pages.tal)
        assert(wrath._w == 32 and d.trees:GetScale() == 1 and a and lc and pageBox and lc.top < a.bottom and lc.bottom >= pageBox.bottom - 0.01,
            "Joan's trees and Legacy don't fit the page: talents " .. tostring(wrath._w))
        assert(cards[1].label._text == "BALANCE" and cards[1].points._text == "3" and cards[2].label._text == "FERAL COMBAT" and cards[2].points._text == "0",
            "the trees' names and points: " .. tostring(cards[1].label._text) .. " " .. tostring(cards[1].points._text))
        -- The cards side by side, the page's width between them, the same height.
        local b, c = ui.rect(cards[2]), ui.rect(cards[3])
        assert(a and b and c and math.abs(a.top - c.top) < 0.01 and math.abs((a.top - a.bottom) - (c.top - c.bottom)) < 0.01 and b.left > a.right and c.left > b.right
            and math.abs((c.right - a.left) - ns.V.PAGE_WIDTH) < 0.01, "the tree cards aren't side by side across the page")
        local arrows = 0
        for _, e in ipairs(d.talentLines) do if e.line:IsShown() then arrows = arrows + 1 assert(e.line._atlas == "talents-arrow-line-gray", "an arrow from a talent not learned in full is grey") end end
        assert(arrows == 2, "the arrows between talents: " .. arrows)
        -- Each tree on the painting the game's talent window gives it, cut to its place's shape, never stretched.
        local painted = {}
        for i, card in ipairs(cards) do
            local art = card.art
            painted[i] = tostring(art.top._texture) .. "|" .. tostring(art.bottom._texture)
            for _, piece in ipairs({ { art.top, 256 }, { art.bottom, 128 } }) do
                local t, tall = piece[1], piece[2]
                if t:IsShown() then
                    local tc = t._texCoord
                    local ratio = ((tc[2] - tc[1]) * 256) / ((tc[4] - tc[3]) * tall)
                    assert(math.abs(ratio / (t._w / t._h) - 1) < 0.01, ("a tree's painting is stretched: %.3f against %.3f"):format(ratio, t._w / t._h))
                end
            end
        end
        assert(painted[1] == "Interface\\TalentFrame\\DruidBalance-TopLeft|Interface\\TalentFrame\\DruidBalance-BottomLeft"
            and painted[2]:find("DruidFeralCombat-TopLeft", 1, true) and painted[3]:find("DruidRestoration-BottomLeft", 1, true), "the trees' paintings: " .. painted[1])
        local legacy = {}
        for _, lb in ipairs(d.legacyButtons) do if lb:IsShown() then legacy[#legacy + 1] = lb.talent.name .. "=" .. lb.state end end
        local spent = ui.plain(d.legacyCard.spent._text)
        assert(d.legacyCard:IsShown() and d.legacyCard.label._text == "LEGACY" and spent == "3 spent   5 to spend"
            and table.concat(legacy, ",") == "Well Rested=part,Fleet of Foot=part", "Joan's Legacy: " .. spent .. " | " .. table.concat(legacy, ","))
        GameTooltip._texts = {}
        ui.run(wrath, "OnEnter")
        assert(GameTooltip._spell and table.concat(GameTooltip._texts or {}, " "):find("Rank 3/5", 1, true), "a talent's tooltip: its spell and rank")
        ui.run(wrath, "OnLeave")
        laidOut("Joan's talents")
        -- Points still to spend: their line under the trees, the Legacy under it, all of it still the
        -- page's height at most, at smaller talents.
        do
            local tal = ReliquaryDB.chars[joanKey].talents
            local was = tal.unspent
            tal.unspent = 2
            ui.run(pageButton("gear"), "OnClick")
            ui.run(pageButton("tal"), "OnClick")
            local note, lc2, page = ui.rect(d.talentNote), ui.rect(d.legacyCard), ui.rect(d.pages.tal)
            assert(d.talentNote:IsShown() and ui.plain(d.talentNote._text) == "Unspent talent points:  2" and note.top < ui.rect(cards[1]).bottom
                and lc2.top < note.bottom and lc2.bottom >= page.bottom - 0.01 and wrath._w == 28 and d.trees:GetScale() == 1,
                "the points to spend: " .. tostring(d.talentNote._text) .. ", talents " .. tostring(wrath._w))
            laidOut("Joan's talents, with points to spend")
            tal.unspent = was
            ui.run(pageButton("gear"), "OnClick")
            ui.run(pageButton("tal"), "OnClick")
            assert(not d.talentNote:IsShown() and wrath._w == 32, "no points to spend, but their line stayed")
        end
        -- With animations on: the page coming into view brings the cards in, then the talents row by row,
        -- the arrows with the row they point to, the Legacy last; a talent under the cursor grows to 1.06
        -- and back.
        M.setEnabled(true)
        ui.run(pageButton("gear"), "OnClick")
        ui.run(pageButton("tal"), "OnClick")
        local first, last
        for _, tb in ipairs(d.talentButtons) do
            if tb:IsShown() then
                if tb.talent.name == "Improved Wrath" then first = tb end
                if tb.talent.name == "Swiftmend" then last = tb end
            end
        end
        assert(cards[1]:GetAlpha() == 0 and first:GetAlpha() == 0 and last:GetAlpha() == 0 and d.legacyButtons[1]:GetAlpha() == 0, "the talents didn't arrive")
        M.step(0.06)
        assert(first:GetAlpha() > last:GetAlpha() and last:GetAlpha() < 1, "the talents don't arrive row by row")
        for _ = 1, 60 do M.step(1 / 60) end
        assert(first:GetAlpha() == 1 and last:GetAlpha() == 1 and cards[3]:GetAlpha() == 1 and d.legacyButtons[2]:GetAlpha() == 1 and not M.running(last, "slide"),
            "the talents didn't land")
        ui.run(wrath, "OnEnter")
        for _ = 1, 12 do M.step(1 / 60) end
        assert(math.abs(wrath.tile:GetScale() - 1.06) < 1e-9, "a talent under the cursor doesn't grow: " .. wrath.tile:GetScale())
        ui.run(wrath, "OnLeave")
        for _ = 1, 12 do M.step(1 / 60) end
        assert(wrath.tile:GetScale() == 1, "a talent left by the cursor doesn't shrink back")
        M.finishAll()
        M.setEnabled(false)
        ui.run(pageButton("gear"), "OnClick")
    end
    -- Your own character's card for the window packs no recipe book for sending: the window reads
    -- recipes from the character itself.
    assert(ns.ownCard(ReliquaryDB.chars[joanKey]).more.craft == nil, "your own card packs its recipes for the wire")
    -- Dragged, the window keeps where you left it.
    win:ClearAllPoints()
    win:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 120, -80)
    ui.run(win.top, "OnDragStop")
    local at = ReliquaryDB.settings.window
    assert(at and at[1] == "TOPLEFT" and at[2] == "TOPLEFT" and at[3] == 120 and at[4] == -80, "the window's place after a drag")
    if scenario ~= "secrets" then
        -- The Timeline tab says what a stop is; each stop is a card, newest first.
        ui.run(pageButton("road"), "OnEnter")
        assert(table.concat(GameTooltip._texts or {}, " "):find("A stop is 10 active minutes", 1, true), "the Timeline tab's tooltip")
        ui.run(pageButton("road"), "OnClick")
        assert(selected() == "road", "the Timeline tab is selected once clicked: " .. selected())
        -- Each card as "zone | when | facts | level", and under an open one its lines as "left | right".
        local function roadText()
            local t = {}
            for _, f in ipairs(d.road._rows) do
                local e = f.element
                if e.kind == "stop" then
                    t[#t + 1] = table.concat({ e.zone, e.when or "", e.facts or "", e.level or "" }, " | ")
                    for _, r in ipairs(f.card.rows) do if r:IsShown() then t[#t + 1] = (r.line.left or "") .. " | " .. (r.line.right or "") end end
                else t[#t + 1] = e.left end
            end
            return table.concat(t, "\n")
        end
        local function chips(f)
            local out = {}
            for _, chip in ipairs(f.card.head.chips) do if chip:IsShown() then out[#out + 1] = chip.text._text end end
            return table.concat(out, ",")
        end
        local dark = d.road._rows[1]
        local head = dark.card.head
        assert(dark.element.kind == "stop" and dark.element.zone == "Darkshore" and head.zone._text == "Darkshore" and head.first:IsShown()
            and head.first._text == "First visit", "newest stop first, a first visit marked: " .. roadText())
        -- Its facts as chips, its level at the right of them; nothing is said that the game didn't give.
        assert(chips(dark):find("1 quest", 1, true) and chips(dark):find("2 killing blows", 1, true) and not chips(dark):find("challenge", 1, true)
            and head.level._text == "Level 12" and head.level:IsShown(), "Darkshore's facts: " .. chips(dark) .. " | " .. tostring(head.level._text))
        -- The line down the left: a ring at each stop, level with its zone's line, the line starting at the
        -- first ring and ending at the last.
        local zone, ring = ui.rect(head.zone), ui.rect(dark.ring)
        assert(zone and ring and math.abs((zone.top + zone.bottom) / 2 - 2 - (ring.top + ring.bottom) / 2) < 0.5 and not dark.above:IsShown()
            and dark.below:IsShown(), "the first stop's ring isn't level with its zone, or the line runs above it")
        local cards = 0
        for _, f in ipairs(d.road._rows) do
            if f.element.kind == "stop" then
                cards = cards + 1
                assert(f.ring:IsShown() and f.below:IsShown() == not f.element.lastCard and f.above:IsShown() == not f.element.firstCard,
                    "the line and ring at " .. f.element.zone)
            end
        end
        assert(cards >= 2, "Joan's timeline has " .. cards .. " cards")
        -- First visit and the day and hours stand on the zone's line.
        local first, when = ui.rect(head.first), ui.rect(head.when)
        assert(first and when and math.abs(first.bottom - (zone.bottom + 1.5)) < 0.01 and math.abs(when.bottom - (zone.bottom + 1.5)) < 0.01,
            "First visit or the day and hours don't stand on the zone's line")
        -- With room on the page, the newest stops open themselves, all they hold within the page.
        local box, used = ui.rect(d.road), 0
        for _, r in ipairs(d.road._rows) do used = used + r._extent end
        assert(dark.element.open and head.chev.up:IsShown() and not head.chev.down:IsShown() and roadText():find("Quests handed in", 1, true)
            and used <= box.top - box.bottom + 0.5, "the newest stop didn't open itself within the page: " .. roadText())
        laidOut("Joan's timeline")
        -- A click on its head closes it: its lines go, the card is its head alone, and closed it stays.
        ui.run(head, "OnClick")
        assert(not dark.element.open and head.chev.down:IsShown() and not dark.card.lines:IsShown() and dark.card._h == dark.element.headH
            and d.road._rows[2].element.zone == "Zephras Isle", "a click closes the newest stop: " .. roadText())
        -- Joan's page follows the game while it shows: a scan of her money draws it again.
        local was = GetMoney
        GetMoney = function() return S(9999999) end
        fire("PLAYER_MONEY")
        advance(3)
        assert(d.chips.gold.text._text:find("999g 99s 99c", 1, true), "Joan's page after her money changed: " .. tostring(d.chips.gold.text._text))
        GetMoney = was
        fire("PLAYER_MONEY")
        advance(3)
        dark = d.road._rows[1]
        head = dark.card.head
        assert(dark.element.zone == "Darkshore" and not dark.element.open, "a stop closed by hand opened itself again when the page drew again: " .. roadText())
        ui.run(head, "OnClick")
        local t = roadText()
        assert(t:find("Quests handed in", 1, true) and t:find("+1,100 XP", 1, true) and t:find("Passed through", 1, true) and t:find("The Great Sea", 1, true),
            "Darkshore's details: " .. t)
        assert(dark.element.open and head.chev.up:IsShown(), "an open stop shows its chevron up")
        -- An open stop's lines read from the left, whichever face their kind gives them; a heading is
        -- the label face, the experience a quest gave verdant.
        local lines, xp = 0, nil
        for _, r in ipairs(dark.card.rows) do
            if r:IsShown() then
                lines = lines + 1
                assert(r.left:GetJustifyH() == "LEFT", "a timeline line isn't aligned to the left: " .. tostring(r.line.left))
                if r.line.kind == "sub" then assert(r.left._font == ns.Skin.font("label"), "a heading in an open stop isn't the label face") end
                if r.line.gain then xp = r end
            end
        end
        assert(lines > 0, "Darkshore's open stop showed no lines to look at")
        local vr, vg, vb = ns.Skin.rgb("verdant")
        assert(xp, "Darkshore's quest shows no experience")
        local xr, xg, xb = xp.right:GetTextColor()
        assert(xp.right._text == "+1,100 XP" and xr == vr and xg == vg and xb == vb, "the experience a quest gave isn't verdant")
        assert(scenario == "bare" or t:find("The Lighthouse Keeper | +1,100 XP", 1, true), "the quest's title from the game: " .. t)
        local before
        for _, f in ipairs(d.road._rows) do if f.element.key == "before" and f.element.when:find("Up to", 1, true) then before = f end end
        -- An old client remembered nothing from before Reliquary: the part is left out, not shown empty.
        assert((scenario == "bare") == (before == nil), "Before Reliquary: " .. roadText())
        if before then
            -- The last card.
            local last
            for _, f in ipairs(d.road._rows) do if f.element.kind == "stop" then last = f end end
            assert(last == before and before.element.lastCard, "Before Reliquary isn't the last card")
            if not before.element.open then ui.run(before.card.head, "OnClick") end
            -- Opened, its groups show folded with how many lines each holds, as the game's Statistics do.
            t = roadText()
            assert(t:find("Legacy challenges | 1", 1, true) and t:find("Zones explored | 1", 1, true) and t:find("Quests completed | 4", 1, true)
                and not t:find("Into the Grove", 1, true), "Before Reliquary's groups, folded: " .. t)
            local groups = 0
            for _ = 1, 10 do
                local closed
                for _, r in ipairs(before.card.rows) do if r:IsShown() and r.line.kind == "group" and not r.line.open then closed = r end end
                if not closed then break end
                assert(closed.chev.down:IsShown() and not closed.chev.up:IsShown(), "a folded group shows its chevron down")
                ui.run(closed, "OnClick")
                groups = groups + 1
            end
            t = roadText()
            assert(groups >= 4 and t:find("A New Beginning | Nov 6", 1, true) and t:find("Zephras Isle | 3 areas", 1, true) and t:find("Creatures killed | 214", 1, true)
                and t:find("Into the Grove", 1, true), "Before Reliquary's details: " .. t)
            laidOut("Joan's timeline, opened")
            ui.run(before.card.head, "OnClick")
            assert(not roadText():find("Into the Grove", 1, true), "a second click closes Before Reliquary")
        end
    end
    -- Mira, who isn't played now: saved three hours ago, every item in her bags, her recipes.
    ui.run(list._rows[2], "OnClick")
    d = visible(function(f) return f.pageButtons ~= nil end)
    assert(d.when._text == "Saved 3 h ago", "Mira's page: " .. tostring(d.when._text))
    -- Every profession she has, each on its bar, the fifth included.
    ui.run(pageButton("gear"), "OnClick")
    local bars, tailoring = {}, nil
    for _, row in ipairs(d.sheet._rows) do
        if row.line.kind == "prof" then
            assert(row.bar:IsShown() and row.bar.target == (row.line.sk or 0) / row.line.mx, "a profession's bar doesn't show its skill")
            bars[#bars + 1] = row.label._text .. "  " .. row.value._text
            if row.line.prof == "Tailoring" then tailoring = row end
        end
    end
    assert(#bars == 5 and bars[5] == "Fishing  12 / 75", "Mira's professions: " .. table.concat(bars, ", "))
    laidOut("Mira's gear")
    -- A profession with recipes opens them, that profession's alone.
    ui.run(tailoring, "OnClick")
    assert(selected() == "craft" and d.recipes._rows[1].line.name == "Tailoring", "Mira's Tailoring bar didn't open her Tailoring recipes")
    ui.run(pageButton("gear"), "OnClick")
    -- Her one stop opens nothing (there's nothing in it), and runs past midnight: both days show. Its card
    -- is the one card: no line runs above or below its ring.
    ui.run(assert(pageButton("road"), "Mira has no Timeline page"), "OnClick")
    local stop = d.road._rows[1]
    local stopHead = stop.card.head
    assert(#d.road._rows == 1 and stop.element.key == nil and not stopHead.chev.down:IsShown() and not stopHead.chev.up:IsShown()
        and not stop.above:IsShown() and not stop.below:IsShown(), "a stop with nothing in it opens nothing")
    local sounds = #played
    ui.run(stopHead, "OnClick")
    ui.run(stopHead, "OnEnter")
    assert(#played == sounds and #d.road._rows == 1 and not stop.element.open, "clicking a stop with nothing in it did something")
    local lr, lg, lb = stop.card.surface.line:GetColor()
    local ir, ig, ib = ns.Skin.rgb("ink600")
    assert(lr == ir and lg == ig and lb == ib, "a stop with nothing in it warms on hover as if it opened")
    ui.run(stopHead, "OnLeave")
    -- What it has: no quests, challenges or killing blows, so its one chip is its time.
    local shownChips = 0
    for _, chip in ipairs(stopHead.chips) do if chip:IsShown() then shownChips = shownChips + 1 end end
    assert(shownChips == 1 and stopHead.chips[1].text._text == "25 min" and stopHead.level._text == "Level 30", "Mira's stop: its time and level")
    assert(stop.element.when:find(" - ", 1, true) and select(2, stop.element.when:gsub("%a%a%a %d+", "")) == 2, "a stop past midnight shows both days: " .. stop.element.when)
    laidOut("Mira's timeline")
    -- A longer timeline: the newest stops open themselves one after another only while what they hold
    -- fits the page; the rest wait for a click.
    do
        local was = mira.timeline
        local entries = {}
        for i = 1, 4 do
            local from = midnight - 2 * 86400 - i * 7200
            entries[i] = { zone = "Westfall", from = from, to = from + 3600, active = 3000, level = 30,
                quests = { { title = "Quest " .. i .. " one", xp = 100 }, { title = "Quest " .. i .. " two", xp = 100 } } }
        end
        mira.timeline = { entries = entries }
        ui.run(list._rows[1], "OnClick") -- away and back, so her page is drawn anew
        ui.run(list._rows[2], "OnClick")
        d = visible(function(f) return f.pageButtons ~= nil end)
        ui.run(pageButton("road"), "OnClick")
        local box, used, open, shut = ui.rect(d.road), 0, 0, 0
        for _, r in ipairs(d.road._rows) do
            used = used + r._extent
            if r.element.key then if r.element.open then open = open + 1 else shut = shut + 1 end end
        end
        assert(open > 0 and shut > 0 and used <= box.top - box.bottom + 0.5,
            ("a longer timeline: %d stops opened, %d shut, %d of %d high"):format(open, shut, used, box.top - box.bottom))
        laidOut("Mira's longer timeline")
        mira.timeline = was
        ui.run(list._rows[1], "OnClick")
        ui.run(list._rows[2], "OnClick")
        d = visible(function(f) return f.pageButtons ~= nil end)
    end
    ui.run(assert(pageButton("bags"), "Mira has no Bags page"), "OnClick")
    -- Each bag a card (docs/DESIGN.md, section 5): its name and how many of its slots are full on its
    -- band, every slot drawn (an empty one a quiet well, with none of the game's art in it), the card as
    -- big as its slots. Her backpack's 140 slots take the fewest rows the page allows, their columns as
    -- even as they can be: fourteen across, ten down. The keyring shows the rows that hold its keys, and
    -- keys aren't bag space. The cards flow left to right and wrap: the keyring has no room beside the
    -- backpack, so it starts the next shelf. The totals are chips along the page's foot.
    local function bags()
        local cards, items, empty = {}, 0, 0
        for _, r in ipairs(d.itemRows._rows) do
            for _, c in ipairs(r.cards) do
                if c:IsShown() then
                    local shown = 0
                    for _, b in ipairs(c.slots) do
                        if b:IsShown() then
                            shown = shown + 1
                            if b.rq then items = items + 1
                            else
                                empty = empty + 1
                                assert(b._icon == nil and not b.rqFilled and b.rqLine:GetColor() == ns.Skin.C.ink600[1] and not b.emptyBackgroundAtlas
                                    and not b.emptyBackgroundTexture, "an empty slot isn't a quiet well")
                            end
                        end
                    end
                    cards[#cards + 1] = { c = c, row = r, name = c.title._text, value = c.value._text, slots = shown }
                end
            end
        end
        local names = {}
        for i, card in ipairs(cards) do names[i] = card.name end
        return cards, table.concat(names, ","), items, empty
    end
    local function chips()
        local out = {}
        for _, chip in ipairs(d.itemChips) do if chip:IsShown() then out[#out + 1] = chip.text._text end end
        return table.concat(out, " | ")
    end
    local cards, heads, shownItems, empty = bags()
    local pack, keys = cards[1], cards[2]
    assert(heads == "Backpack,Keyring" and pack.value == "130 / 140" and keys.value == "2 / 32" and shownItems == 132 and empty == 16,
        "Mira's bags: " .. heads .. ", " .. shownItems .. " items, " .. empty .. " empty")
    -- A stack's count on the slot's plate (Mira's linen, two to a slot), not in the game's outlined
    -- numerals over the icon; a common item's line is quiet, not its quality's white.
    do
        local cloth = pack.c.slots[1]
        local r, g, bl = cloth.rqLine:GetColor()
        local ir, ig, ib = ns.Skin.rgb("ink500")
        assert(cloth.rq and cloth.rq.n == 2 and cloth.rqPlate and cloth.rqPlate:IsShown() and cloth.rqPlate.text._text == "2" and cloth._count == 0,
            "a stack's count isn't on its slot's plate: " .. tostring(cloth.rqPlate and cloth.rqPlate.text._text) .. ", " .. tostring(cloth._count))
        assert(r == ir and g == ig and bl == ib and cloth.rqGlow.alpha == 0, "a common item's slot is lit or lined in white")
        assert(cloth._quality == 1 and not cloth.IconBorder:IsShown(), "the game's own frame shows round a slot's icon")
    end
    assert(pack.slots == 140 and pack.c._w == 24 + 14 * 44 - 4 and pack.c._h == 40 + 24 + 10 * 44 - 4 and pack.c.slots[14]._points.TOPLEFT.x == 13 * 44
        and pack.c.slots[15]._points.TOPLEFT.x == 0 and pack.c.slots[15]._points.TOPLEFT.y == -44, "the backpack's card: fourteen across, ten down")
    assert(keys.slots == 8 and keys.c._w == 24 + 4 * 44 - 4 and keys.c._h == 40 + 24 + 2 * 44 - 4, "the keyring's card: its two rows of keys")
    assert(pack.c._points.TOPLEFT.x == 0 and pack.c._points.TOPLEFT.y == 0 and keys.row ~= pack.row and keys.c._points.TOPLEFT.x == 0,
        "the cards don't start at the page's top left, or the keyring didn't wrap")
    assert(chips() == "130 items | 10 of 140 slots free", "Mira's bags' totals: " .. chips())
    -- Pointing at a bag's band warms its name.
    ui.run(pack.c.head, "OnEnter")
    local warm = { pack.c.title:GetTextColor() }
    ui.run(pack.c.head, "OnLeave")
    assert(warm[1] == ns.Skin.C.gold100[1] and warm[3] == ns.Skin.C.gold100[3] and pack.c.title:GetTextColor() == ns.Skin.C.parchment[1],
        "pointing at the backpack's band doesn't warm its name")
    laidOut("Mira's bags")
    -- The bank under the game's own word for it, never the name the game gives its container; its 48
    -- slots in four rows of twelve; a bag in it under the bag's name, beside it where there's room (here
    -- there isn't), a click on its band away from its page. When the bank was seen, a chip says so.
    mira.bankAt = time() - 2 * 3600
    ui.run(list._rows[1], "OnClick")
    ui.run(list._rows[2], "OnClick")
    ui.run(assert(pageButton("bank"), "Mira has no Bank page"), "OnClick")
    cards, heads, shownItems, empty = bags()
    assert(heads == "Bank,Linen Bag" and cards[1].value == "1 / 48" and cards[2].value == "0 / 6" and shownItems == 1 and empty == 53
        and cards[1].c._w == 24 + 12 * 44 - 4 and cards[2].row ~= cards[1].row, "Mira's bank: " .. heads .. ", " .. shownItems .. " items, " .. empty .. " empty")
    assert(chips() == "1 item | 53 of 54 slots free | Seen at the bank 2 h ago", "Mira's bank's totals: " .. chips())
    -- The bank's own slots have no icon: its name starts where the icon would be.
    assert(not cards[1].c.icon:IsShown() and cards[1].c.title._points.TOPLEFT.x == 12 and cards[2].c.icon:IsShown() and cards[2].c.title._points.TOPLEFT.x == 46,
        "the bank's band keeps room for an icon it hasn't")
    ui.run(cards[2].c.head, "OnClick")
    assert(ReliquaryItemPage:IsShown() and ReliquaryItemPage.item.id == 4238, "the Linen Bag's band didn't open its page")
    ReliquaryItemPage:Hide()
    laidOut("Mira's bank")
    -- A bag that fits beside the one before it stands beside it, top-aligned, the room between them 12.
    mira.bank[2].size = 4
    mira.bank[1].size = 24
    ui.run(list._rows[1], "OnClick")
    ui.run(list._rows[2], "OnClick")
    ui.run(pageButton("bank"), "OnClick")
    cards = bags()
    assert(#cards == 2 and cards[2].row == cards[1].row and cards[2].c._points.TOPLEFT.x == cards[1].c._w + 12 and cards[2].c._points.TOPLEFT.y == 0,
        "a small bag didn't stand beside the bank")
    laidOut("Mira's bank, two cards on a shelf")
    -- Arriving (another player, or the window opening), the cards come in order, then the chips: each
    -- fades in and rises into place after the one before it.
    do
        local M = ns.Motion
        ReliquaryDB.settings.motion = nil
        SlashCmdList.RELIQUARY("")
        SlashCmdList.RELIQUARY("")
        cards = bags()
        local first, second, chip = cards[1].c, cards[2].c, d.itemChips[1]
        assert(M.enabled() and first:GetAlpha() == 0 and second:GetAlpha() == 0 and chip:GetAlpha() == 0, "Mira's bank's cards show before they arrive")
        for _ = 1, 22 do M.step(1 / 60) end
        assert(first:GetAlpha() > second:GetAlpha() and second:GetAlpha() > chip:GetAlpha(), "the cards and chips don't arrive one after another: "
            .. first:GetAlpha() .. ", " .. second:GetAlpha() .. ", " .. chip:GetAlpha())
        for _ = 1, 60 do M.step(1 / 60) end
        assert(first:GetAlpha() == 1 and second:GetAlpha() == 1 and chip:GetAlpha() == 1 and first._points.TOPLEFT.y == 0 and second._points.TOPLEFT.y == 0,
            "the cards didn't come to rest in their places")
        ReliquaryDB.settings.motion = false
        SlashCmdList.RELIQUARY("")
        M.finishAll()
        SlashCmdList.RELIQUARY("")
        d = visible(function(f) return f.pageButtons ~= nil end)
    end
    mira.bank[2].size, mira.bank[1].size = 6, 48
    ui.run(assert(pageButton("craft"), "Mira has no Recipes page"), "OnClick")
    local recipes = {}
    for _, r in ipairs(d.recipes._rows) do recipes[#recipes + 1] = r.line.name or r.line.left or "" end
    recipes = table.concat(recipes, "\n")
    assert(recipes:find("Tailoring", 1, true) and recipes:find("Brown Linen Vest", 1, true), "Mira's recipes: " .. recipes)
    laidOut("Mira's recipes")
    -- Her Tailoring is a card down the list, a row at a time: its head (its name, how many recipes, its
    -- skill on its bar) the card's top, the recipe its middle, then its foot; the recipe chosen keeps the
    -- fill and the gold bar, and beside the list, on a card of its own, what it makes and its reagents.
    -- Her head folds the card away (its recipe still chosen beside it) and opens it again.
    do
        local M = ns.Motion
        local function parts()
            local t = {}
            for _, r in ipairs(d.recipes._rows) do t[#t + 1] = r.line.kind .. "=" .. (r.slice:IsShown() and r.slice.part or "-") end
            return table.concat(t, ",")
        end
        local head, vest = d.recipes._rows[1], d.recipes._rows[2]
        assert(parts() == "head=top,recipe=middle,foot=bottom", "Mira's Tailoring card: " .. parts())
        assert(head.name._text == "Tailoring" and head.count._text == "1 recipe" and head.skill._text == "60 / 75" and head.progress:IsShown()
            and math.abs(head.progress.target - 60 / 75) < 1e-9 and head.fold:IsShown() and not head.folded:IsShown(), "Mira's Tailoring head")
        assert(vest.chosen and vest.bar:IsShown() and vest.fill.alpha == 1 and vest.tile:IsShown() and d.schematic:IsShown()
            and d.schematic.name._text:find("Brown Linen Vest", 1, true) and d.schematic.cells[1]:IsShown() and not d.schematic.cells[2]:IsShown(),
            "Mira's chosen recipe beside her list")
        -- The chosen recipe's card is as tall as what it holds, its reagents under their label.
        local card, last = ui.rect(d.schematic), ui.rect(d.schematic.cells[1])
        assert(card and last and math.abs((last.bottom - card.bottom) - 12) < 0.01, "the chosen recipe's card isn't as tall as what it holds")
        ui.run(head, "OnClick")
        assert(parts() == "head=top,foot=bottom" and d.recipes._rows[1].folded:IsShown() and not d.recipes._rows[1].fold:IsShown()
            and d.schematic:IsShown() and d.schematic.name._text:find("Brown Linen Vest", 1, true), "folding Mira's Tailoring: " .. parts())
        laidOut("Mira's recipes, folded")
        ui.run(d.recipes._rows[1], "OnClick")
        assert(parts() == "head=top,recipe=middle,foot=bottom", "opening Mira's Tailoring again: " .. parts())
        -- With animations on, the head folds the card's rows shut over slow time, and opens them again.
        M.setEnabled(true)
        ui.run(d.recipes._rows[1], "OnClick")
        local v = M.value(d.recipes, "fold:Tailoring")
        assert(v == 1 and M.running(d.recipes, "fold:Tailoring") and d.recipes._rows[1].folded:IsShown(), "folding with animations on doesn't ease")
        M.finishAll()
        assert(parts() == "head=top,foot=bottom", "the fold didn't land: " .. parts())
        ui.run(d.recipes._rows[1], "OnClick")
        assert(parts() == "head=top,recipe=middle,foot=bottom" and M.value(d.recipes, "fold:Tailoring") == 0 and d.recipes._rows[2]._extent < 1,
            "opening with animations on doesn't ease")
        M.finishAll()
        assert(not d.recipes._rows[2].line.open, "the card didn't open")
        -- The page coming into view: the card fades in a row at a time, each row's words rising into it, the
        -- bar filling from nothing; then the chosen recipe's card.
        ui.run(pageButton("gear"), "OnClick")
        ui.run(pageButton("craft"), "OnClick")
        head, vest = d.recipes._rows[1], d.recipes._rows[2]
        assert(head.slice:GetAlpha() == 0 and head.inner:GetAlpha() == 0 and vest.slice:GetAlpha() == 0 and head.progress.frac == 0 and d.schematic:GetAlpha() == 0,
            "Mira's recipes didn't arrive")
        M.step(0.05)
        assert(head.slice:GetAlpha() > vest.slice:GetAlpha(), "Mira's recipe rows don't arrive in order")
        for _ = 1, 60 do M.step(1 / 60) end
        assert(head.slice:GetAlpha() == 1 and vest.inner:GetAlpha() == 1 and d.schematic:GetAlpha() == 1 and math.abs(head.progress.frac - 60 / 75) < 1e-9,
            "Mira's recipes didn't land")
        M.finishAll()
        M.setEnabled(false)
    end
    for _, f in ipairs(ui.frames) do
        for _, v in pairs(f) do
            if type(v) == "table" and v._kind == "FontString" and type(v._text) == "string" then
                assert(not v._text:lower():find("dashboard", 1, true), "the window points outside the game: " .. v._text)
            end
        end
    end
    SlashCmdList.RELIQUARY("")
    ReliquaryDB.chars[miraKey] = nil
end

-- 15c. The window's clock (Motion.lua): a tween lands where it was sent, along its curve; a new one
-- takes over from where the last one was; animations off (and anything hidden) lands at once; the
-- ticker runs only while something moves, and never behind a shut window.
do
    local M = ns.Motion
    local holder = CreateFrame("Frame")
    local spot = CreateFrame("Frame", nil, holder)
    M.setEnabled(true)
    assert(not M.ticking(), "the clock ticks with nothing moving")
    local landed = 0
    M.fade(spot, 1, { from = 0, dur = 0.2, done = function() landed = landed + 1 end })
    assert(M.ticking() and spot:GetAlpha() == 0, "a fade doesn't start where it was sent from")
    M.step(0.1)
    assert(math.abs(spot:GetAlpha() - 0.875) < 1e-9, ("halfway along cubic out is 0.875, not %.4f"):format(spot:GetAlpha()))
    M.step(0.1)
    assert(spot:GetAlpha() == 1 and landed == 1 and not M.running(spot, "alpha") and not M.ticking(), "a fade didn't land, or the clock kept ticking")
    -- Retargeted halfway: from where it is, and the first one's ending never runs.
    landed = 0
    M.fade(spot, 0, { dur = 0.2, done = function() landed = landed + 10 end })
    M.step(0.1)
    local mid = spot:GetAlpha()
    M.fade(spot, 1, { dur = 0.2, done = function() landed = landed + 1 end })
    assert(spot:GetAlpha() == mid and M.value(spot, "alpha") == mid, "a new tween didn't take over from where the last one was")
    M.step(0.2)
    assert(spot:GetAlpha() == 1 and landed == 1, "a replaced tween's ending ran, or the new one didn't land: " .. landed)
    -- A tween with no way to read where it is (a counted number, a bar's fill) takes over from the
    -- running one's place too.
    local box = {}
    local function put(_, v) box.n = v end
    M.to(spot, "n", 10, { from = 0, dur = 0.2, set = put })
    M.step(0.1)
    M.to(spot, "n", 0, { dur = 0.2, set = put })
    assert(math.abs(box.n - 8.75) < 1e-9, "a tween with no getter didn't take over from where the last one was: " .. tostring(box.n))
    M.step(0.2)
    assert(box.n == 0 and not M.ticking(), "a retargeted number didn't land")
    -- A list's items wait their turn, ten at most.
    assert(M.delay(1) == 0 and math.abs(M.delay(3) - 0.05) < 1e-9 and math.abs(M.delay(40) - 0.225) < 1e-9, "the stagger")
    -- Something hidden doesn't move: it lands at once, and hiding it mid-way lands it on the next tick.
    holder:Hide()
    M.fade(spot, 0.25, { from = 1, dur = 1 })
    assert(spot:GetAlpha() == 0.25 and not M.ticking(), "a tween on something hidden ran")
    holder:Show()
    M.fade(spot, 1, { from = 0.25, dur = 1 })
    holder:Hide()
    M.step(0.01)
    assert(spot:GetAlpha() == 1 and not M.ticking(), "hidden mid-way, a tween kept the clock ticking")
    holder:Show()
    -- A loop runs while it shows, and stops at its start when hidden.
    M.loop(spot, "swing", 0.2, 0.6, 1, function(f, a) f:SetAlpha(a) end)
    for _ = 1, 30 do M.step(0.1) end
    assert(M.ticking() and M.running(spot, "swing"), "a loop stopped by itself")
    holder:Hide()
    M.step(0.01)
    assert(spot:GetAlpha() == 0.2 and not M.ticking(), "a hidden loop kept ticking, or didn't stop at its start")
    holder:Show()
    -- A slide arrives at the region's own anchors and leaves them exactly as they were.
    spot:SetPoint("TOPLEFT", 10, -10)
    M.slide(spot, 16, 0, { dur = 0.2 })
    assert(spot._points.TOPLEFT.x == 26, "a slide doesn't start its distance away")
    M.step(0.3)
    assert(spot._points.TOPLEFT.x == 10 and spot._points.TOPLEFT.y == -10, "a slide didn't come back to its anchors")
    -- An ending may land everything else: the window's closing ends by hiding it, and a window hidden
    -- lands all that moves. The step that ending came in goes on down its list, which nothing has
    -- shortened under it (in the game this was an error each time the window closed with something
    -- else still moving).
    do
        local other, ended = holder:CreateTexture(), 0
        M.fade(spot, 0.5, { dur = 0.1, from = 1, done = function() ended = ended + 1 M.finishAll() end })
        M.fade(other, 0, { dur = 1, from = 1 })
        M.to(holder, "late", 1, { dur = 1, from = 0, set = function() end })
        local ok, err = pcall(M.step, 0.2)
        assert(ok, "an ending that lands everything broke the step it came in: " .. tostring(err))
        assert(ended == 1 and other:GetAlpha() == 0 and M.moving() == 0 and not M.ticking(),
            "an ending that lands everything left something moving: " .. M.moving())
        M.fade(spot, 1, { dur = 0.1 })
        M.step(0.2)
        assert(spot:GetAlpha() == 1 and not M.ticking(), "the clock didn't run again after an ending landed everything")
        -- An ending that fails (another addon's fault, say) costs that one tick: the game's next tick
        -- starts afresh, what is left lands, and the clock stops.
        M.fade(spot, 0.5, { dur = 0.1, done = function() error("an ending failed") end })
        M.fade(other, 1, { dur = 0.3, from = 0 })
        assert(not pcall(ui.run, ReliquaryMotion, "OnUpdate", 0.2), "the failing ending didn't fail")
        ui.run(ReliquaryMotion, "OnUpdate", 0.4)
        assert(other:GetAlpha() == 1 and M.moving() == 0 and not M.ticking(), "after an ending failed the clock never stopped: " .. M.moving())
    end
    -- Off, as with the player's Animations switch off: everything lands at once, a running tween too.
    M.fade(spot, 0, { dur = 1 })
    M.setEnabled(false)
    assert(spot:GetAlpha() == 0 and not M.ticking(), "turning animations off didn't land a running tween")
    landed = 0
    M.fade(spot, 1, { from = 0, dur = 1, done = function() landed = landed + 1 end })
    assert(spot:GetAlpha() == 1 and landed == 1 and not M.ticking(), "with animations off a tween didn't land at once")
    assert(M.loop(spot, "swing", 0.2, 0.6, 1, function(f, a) f:SetAlpha(a) end) == nil and spot:GetAlpha() == 0.2, "a loop ran with animations off")
    -- The clock is the ticker's own OnUpdate: the game moves it on each frame.
    M.setEnabled(true)
    M.fade(spot, 0, { from = 1, dur = 0.1 })
    ui.run(ReliquaryMotion, "OnUpdate", 0.1)
    assert(spot:GetAlpha() == 0 and not ReliquaryMotion:IsShown(), "the ticker's OnUpdate isn't the clock")
    M.setEnabled(false)
end

-- 15d. The window (docs/DESIGN.md, section 3): it opens and closes moving, with animations on;
-- Escape closes it through its stand-in and steps back from an item's page first; the tabs' marker
-- sits under the chosen tab; the grip scales it within 0.75 and 1.25 with its top left kept, back to 1
-- on a double-click; its place and scale are kept. The rail's chosen row keeps the gold bar, which
-- glides from the row chosen before; the hero; the Gear page and the model of the character played.
do
    local M, Skin, V = ns.Motion, ns.Skin, ns.V
    local joanKey = ReliquaryDB.chars["Joan Ofârc-CAMWOWUS2Realm11RP"] and "Joan Ofârc-CAMWOWUS2Realm11RP" or "Unknown-CAMWOWUS2Realm11RP"
    local miraKey = "Mira Vale-CAMWOWUS2Realm11RP"
    ReliquaryDB.chars[miraKey] = { name = "Mira", surname = "Vale", realm = ReliquaryDB.chars[joanKey].realm, level = 30, class = "Mage", classFile = "MAGE",
        race = "Human", updated = time() - 3 * 3600, share = { guild = false, friends = false, public = false },
        gear = { [1] = { id = 264120, name = "Windshaper's Circlet", q = 2, ilvl = 14 } } }
    ReliquaryDB.settings.motion = nil -- the player's Animations switch, on
    SlashCmdList.RELIQUARY("")
    local win = ReliquaryFrame
    local c = win.canvas
    assert(win:IsShown() and M.enabled() and c:GetAlpha() == 0 and math.abs(c:GetScale() - M.OPEN_SCALE) < 1e-9, "the window doesn't open from nothing")
    -- The chosen row's fill and gold bar arrive with its words, never ahead of them.
    local chosen = (function() for _, f in ipairs(ui.frames) do if rawget(f, "chosen") and f:IsVisible() then return f end end end)()
    assert(chosen and chosen.bar:GetAlpha() == 0 and chosen.fill.alpha == 0 and chosen.inner:GetAlpha() == 0,
        "the chosen row's fill and bar show before its words")
    for _ = 1, 30 do M.step(1 / 60) end
    assert(c:GetAlpha() == 1 and c:GetScale() == 1 and c._points.CENTER.y == 0, "the window didn't open into place")
    assert(chosen.bar:GetAlpha() == 1 and chosen.fill.alpha == 1 and chosen.inner:GetAlpha() == 1, "the chosen row didn't arrive whole")
    assert(M.ticking() and M.running(win.crest.moon, "breathe"), "the moon in the crest doesn't breathe while the window is open")
    -- Escape: the game hides what UISpecialFrames names (CloseSpecialWindows); the stand-in closes the
    -- window as the X does, fading, then gone, and the clock stops behind it.
    local function escape()
        for _, name in ipairs(UISpecialFrames) do if _G[name] and _G[name]:IsShown() then _G[name]:Hide() end end
    end
    escape()
    assert(win:IsShown() and win.closing, "Escape didn't start closing the window")
    M.step(M.close / 2)
    assert(win:IsShown() and c:GetAlpha() < 1 and c:GetScale() < 1, "the window doesn't fade and sink as it closes")
    M.step(M.close)
    assert(not win:IsShown() and not ReliquaryEscape:IsShown() and not M.ticking(), "the window didn't close, or something kept ticking behind it")
    -- With animations off: open and shut at once, and Escape steps back from an item's page first.
    ReliquaryDB.settings.motion = false
    SlashCmdList.RELIQUARY("")
    assert(win:IsShown() and c:GetAlpha() == 1 and not M.ticking(), "with animations off the window didn't open at once")
    local list = (function() for _, f in ipairs(ui.frames) do if f._rows and f:IsVisible() and f._rows[1] and rawget(f._rows[1], "row") then return f end end end)()
    local joanRow, miraRow
    local function rows()
        for _, r in ipairs(list._rows) do
            if r.row.key == joanKey then joanRow = r elseif r.row.key == miraKey then miraRow = r end
        end
    end
    rows()
    ui.run(joanRow, "OnClick")
    local d = (function() for _, f in ipairs(ui.frames) do if f.pageButtons and f:IsVisible() then return f end end end)()
    -- A list fades only at an edge with more beyond it: the rail's few rows fit and fade nowhere; Joan's
    -- character sheet runs on past its card and fades at its foot, not at its top.
    local railTop, railFoot = list:CalculateEdgeFade()
    assert(list._edgeFade and not list:HasScrollableExtent() and railTop == 0 and railFoot == 0, "the rail fades though all its rows fit")
    if scenario == "full" then
        local sheetTop, sheetFoot = d.sheet:CalculateEdgeFade()
        assert(d.sheet._edgeFade and d.sheet:HasScrollableExtent() and sheetTop == 0 and sheetFoot == 1, "the sheet doesn't fade at its foot alone")
    end
    -- Lines are rings over their fills, never discs under them: the game fades a frame's textures one
    -- by one, so a line under a fill would show its colour through it while the window fades. The
    -- crest's gold band has a hole the portrait's size, and the portrait lies in it.
    local function over(line, fill)
        local l, f = line.tex.t, fill.tex.t
        return line.art == "ring" and not line.tex.c:IsShown() and tostring(l._texture):find("ui-ring-", 1, true) ~= nil
            and l._layer == f._layer and l._sub > f._sub
    end
    assert(over(win.surface.line, win.surface.fill), "the window's line isn't a ring over its body")
    assert(over(d.slots[1].rqLine, d.slots[1].rqWell), "a slot's line isn't a ring over its well")
    assert(over(joanRow.avatar.ring, joanRow.avatar.floor), "an avatar's ring isn't over its floor")
    -- Each ring's line is the art's width nearest one screen pixel: on this 1080p screen the window's
    -- corner (8 units, 11.25 pixels) is the 32-pixel ring shrunk 1.42 times, so its 1.5-pixel line; a
    -- card's (6 units, 8.4 pixels) shrunk 1.9 times, the 1.75.
    local function art(n) return tostring(n.tex.tl._texture):match("ui%-ring%-%d+%-%d+$") end
    assert(art(win.surface.line) == "ui-ring-32-150" and art(d.sheetCard.surface.line) == "ui-ring-32-175",
        "a ring's line isn't one pixel on the screen: " .. tostring(art(win.surface.line)) .. ", " .. tostring(art(d.sheetCard.surface.line)))
    local hole = win.crest.ring.hole
    assert(hole and math.abs(hole:GetWidth() * 112 / 128 - 32) < 1e-9 and win.crest.ring.tex.tl._masks[1] == hole,
        "the crest's band has no hole the portrait's size")
    if scenario == "secrets" then V.openItemPage({ id = 264120 }, "item:264120") -- a client hiding everything recorded no gear
    else ui.run(d.slots[1], "OnClick") end
    assert(ReliquaryItemPage:IsShown() and UISpecialFrames[#UISpecialFrames] == "ReliquaryItemPage", "the head slot's click didn't open its page")
    escape()
    assert(win:IsShown() and not ReliquaryItemPage:IsShown() and UISpecialFrames[#UISpecialFrames] == "ReliquaryEscape" and ReliquaryEscape:IsShown(),
        "Escape on an item's page closed the window, or left Escape on the page")
    escape()
    assert(not win:IsShown(), "Escape didn't close the window")
    SlashCmdList.RELIQUARY("")
    -- The tabs: the chosen one in gold.200 with the marker under its words; one with nothing to show faint.
    local tabs = win.tabs
    local chosen = win.Tabs[win.selectedTab]
    assert(tabs.marker:IsShown() and tabs.marker._points.BOTTOMLEFT.rel == chosen and chosen.label.rqtext == Skin.C.gold200
        and win.Tabs[2].label.rqtext == Skin.C.faint and win.Tabs[6].label.rqtext == Skin.C.muted, "the tabs' marker and colours")
    ui.run(win.Tabs[6], "OnClick")
    assert(win.selectedTab == 6 and tabs.marker._points.BOTTOMLEFT.rel == win.Tabs[6], "the marker didn't move to Sharing")
    ui.run(win.Tabs[1], "OnClick")
    -- The grip: dragged, it scales the window from its top left, within 0.75 and 1.25; a double-click
    -- puts it back to 1; the scale is kept.
    local cursor = { 0, 0 }
    GetCursorPosition = function() return cursor[1], cursor[2] end
    local left, top = win:GetLeft() * win:GetEffectiveScale(), win:GetTop() * win:GetEffectiveScale()
    cursor = { left + 960, top - 640 }
    ui.run(win.grip, "OnMouseDown", "LeftButton")
    cursor = { left + 960 * 3, top - 640 * 3 }
    ui.run(win.grip, "OnUpdate", 0.016)
    assert(win:GetScale() == 1.25 and ReliquaryDB.settings.windowScale == 1.25, "the grip went past 1.25: " .. win:GetScale())
    assert(math.abs(win:GetLeft() * win:GetEffectiveScale() - left) < 0.01 and math.abs(win:GetTop() * win:GetEffectiveScale() - top) < 0.01,
        "the window's top left moved as it scaled")
    cursor = { left + 10, top - 10 }
    ui.run(win.grip, "OnUpdate", 0.016)
    assert(win:GetScale() == 0.75, "the grip went below 0.75: " .. win:GetScale())
    ui.run(win.grip, "OnMouseUp", "LeftButton")
    local kept = ReliquaryDB.settings.window
    assert(not win.grip._scripts.OnUpdate and ReliquaryDB.settings.windowScale == 0.75 and kept[1] == "TOPLEFT" and kept[2] == "BOTTOMLEFT"
        and math.abs(kept[3] * 0.75 - left) < 0.01, "the grip kept running after the drag, or its scale and place weren't kept")
    ui.run(win.grip, "OnDoubleClick", "LeftButton")
    assert(win:GetScale() == 1 and ReliquaryDB.settings.windowScale == 1, "a double-click didn't put the scale back to 1")
    -- Closing while held can hide the grip before mouse-up. Escape and the X must end the drag
    -- immediately, including during the closing animation; hiding the parent must do so too.
    for _, how in ipairs({ "escape", "close", "hide" }) do
        M.setEnabled(true)
        left, top = win:GetLeft() * win:GetEffectiveScale(), win:GetTop() * win:GetEffectiveScale()
        cursor = { left + 960, top - 640 }
        ui.run(win.grip, "OnMouseDown", "LeftButton")
        if how == "escape" then escape()
        elseif how == "close" then ui.run(win.close, "OnClick")
        else win:Hide() end
        local saved = win:GetScale()
        assert(not win.grip._scripts.OnUpdate and not win.grip.start, "interrupted resize remains active after " .. how)
        M.finishAll()
        SlashCmdList.RELIQUARY("")
        M.finishAll()
        cursor = { left + 10, top - 10 }
        if win.grip._scripts.OnUpdate then ui.run(win.grip, "OnUpdate", 0.016) end
        assert(win:GetScale() == saved and ReliquaryDB.settings.windowScale == saved, "pointer movement resized a reopened window")
    end
    M.setEnabled(false)
    -- A window restored near an edge, a smaller display and reset-to-one all leave every control
    -- reachable. These are UIParent units, including canvases produced by larger interface scales.
    local width, height = UIParent.GetWidth, UIParent.GetHeight
    for _, size in ipairs({ { 1366, 768 }, { 1280 / 1.5, 800 / 1.5 }, { 640, 400 }, { 1920, 1080 } }) do
        UIParent.GetWidth = function() return size[1] end
        UIParent.GetHeight = function() return size[2] end
        win:SetScale(1.25)
        win:ClearAllPoints()
        win:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", -80, size[2] + 80)
        fire("DISPLAY_SIZE_CHANGED")
        local function inside()
            local r, g = ui.rect(win), ui.rect(win.grip)
            assert(r.left >= -0.01 and r.right <= size[1] + 0.01 and r.bottom >= -0.01 and r.top <= size[2] + 0.01
                and g.left >= -0.01 and g.right <= size[1] + 0.01 and g.bottom >= -0.01 and g.top <= size[2] + 0.01,
                "window or resize grip extends beyond the viewport")
            assert(ReliquaryDB.settings.windowScale == win:GetScale(), "fitted scale wasn't saved")
        end
        inside()
        ui.run(win.grip, "OnDoubleClick", "LeftButton")
        inside()
        win:Hide()
        win:SetScale(1.25)
        win:Show()
        inside()
        fire("UI_SCALE_CHANGED")
        inside()
    end
    UIParent.GetWidth, UIParent.GetHeight = width, height
    ui.run(win.grip, "OnDoubleClick", "LeftButton")
    GetCursorPosition = nil
    -- Reliquary's labels are in Cinzel, from the addon's own Media (a file that doesn't load leaves them
    -- in the client's font).
    assert(Skin.CINZEL == "Interface\\AddOns\\Reliquary\\Media\\Cinzel-Bold.ttf" and Skin.font("label"):GetFont() == Skin.CINZEL
        and win.wordmark._font:GetFont() == Skin.CINZEL and win.wordmark._text == "RELIQUARY", "the labels' face")
    -- Cinzel has Latin letters only: a client in Russian or Korean keeps its own font for the labels.
    assert(Skin.labelFace("Cinzel-Bold.ttf", "deDE") == Skin.CINZEL and Skin.labelFace("Cinzel-Bold.ttf", "ruRU") == Skin.FRIZ
        and Skin.labelFace("Cinzel-Bold.ttf", "koKR") == Skin.FRIZ, "the labels' face on a client not in Latin letters")
    -- The rail's search: a name finds its row, a clear button shows while it has words, and clearing it
    -- brings every row back.
    local search = (function() for _, f in ipairs(ui.frames) do if f._kind == "EditBox" and f:IsVisible() and rawget(f, "glass") then return f end end end)()
    local every = #list._rows
    search:SetText("Mira")
    ui.run(search, "OnTextChanged", true)
    assert(every > 1 and #list._rows == 1 and list._rows[1].row.key == miraKey and search.clear:IsShown() and not search.hint:IsShown(), "the rail's search")
    ui.run(search.clear, "OnClick")
    assert(#list._rows == every and not search.clear:IsShown() and search.hint:IsShown(), "clearing the rail's search")
    rows()
    ui.run(joanRow, "OnClick") -- the search chose its first find; Joan again
    -- The rail: the chosen row keeps its fill and the gold bar; choosing another, the bar glides to it
    -- from the row chosen before.
    ReliquaryDB.settings.motion = nil
    SlashCmdList.RELIQUARY("")
    SlashCmdList.RELIQUARY("")
    M.setEnabled(true)
    rows()
    -- Opening on Joan, her hero's chips (her gold, her time played) arrive after her name, as its lines
    -- do, never ahead of them.
    local hero = (function() for _, f in ipairs(ui.frames) do if f.pageButtons and f:IsVisible() then return f end end end)()
    -- (A client hiding everything leaves her neither chips nor a name.)
    local chip = (function() for _, k in ipairs({ "gold", "played", "place" }) do if hero.chips[k]:IsShown() then return hero.chips[k] end end end)()
    assert(scenario == "secrets" or (hero.name._text == "Joan Ofârc" and chip), "Joan's hero has no chips")
    if chip then assert(chip:GetAlpha() == 0 and hero.name:GetAlpha() == 0, "the hero's chips show before its name") end
    for _ = 1, 30 do M.step(1 / 60) end
    assert((not chip or chip:GetAlpha() == 1) and hero.name:GetAlpha() == 1, "the hero's chips didn't arrive")
    assert(joanRow.chosen and joanRow.bar:IsShown() and not miraRow.bar:IsShown(), "the played character's row isn't the chosen one")
    local from = joanRow:GetTop()
    ui.run(miraRow, "OnClick")
    assert(miraRow.chosen and miraRow.bar:IsShown() and not joanRow.chosen and not joanRow.bar:IsShown(), "Mira's row isn't chosen after a click")
    local glide = M.value(miraRow.bar, "slide")
    assert(glide and math.abs(glide[2] - (from - miraRow:GetTop())) < 1e-6, "the gold bar doesn't glide from Joan's row")
    -- The hero: Mira's name and lines, her class's crest; no chips, as she has no gold or time played on
    -- record; the mage's painting fades in over the druid's.
    d = (function() for _, f in ipairs(ui.frames) do if f.pageButtons and f:IsVisible() then return f end end end)()
    assert(d.name._text == "Mira Vale" and d.crest.icon._atlas == "classicon-mage" and d.when._text == "Saved 3 h ago", "Mira's hero")
    for _, chip in pairs(d.chips) do assert(not chip:IsShown(), "a chip for what Mira doesn't have") end
    local front = d.paintings[d.front]
    assert(front:IsShown() and front:GetAlpha() == 0 and d.paintings[3 - d.front]:IsShown(), "the mage's painting doesn't fade in over the druid's")
    for _ = 1, 30 do M.step(1 / 60) end
    assert(not M.running(miraRow.bar, "slide") and miraRow.bar._points.LEFT.y == 0, "the gold bar didn't come to rest on Mira's row")
    assert(front:GetAlpha() == 1 and not d.paintings[3 - d.front]:IsShown(), "the druid's painting stayed under the mage's")
    -- Gear: Mira's circlet beside its slot, in its quality's colour, with its item level; the item level
    -- counts up from nothing; no model, as she isn't the character played.
    local head = d.slots[1]
    assert(head.label._text == ITEM_QUALITY_COLORS[2].hex .. "Windshaper's Circlet|r" and head.rqPlate.text._text == "14" and not d.slots[5].label:IsShown(),
        "Mira's head slot: " .. tostring(head.label._text) .. " " .. tostring(head.rqPlate.text._text))
    assert(not d.model:IsShown() and d.mark:IsShown(), "the model stands for a character not being played, or her crest doesn't")
    -- Joan, played now: the game's own model of her, turned by dragging; the item level counts up.
    ui.run(joanRow, "OnClick")
    assert(d.model:IsShown() and d.model._unit == "player" and not d.mark:IsShown(), "the played character's model, in the crest's place")
    -- A missing or rejected model call leaves the crest, and a later refresh can retry.
    do
        local setUnit = d.model.SetUnit
        for _, unavailable in ipairs({ false, function() error("model unavailable") end }) do
            ui.run(miraRow, "OnClick")
            d.model.SetUnit = unavailable
            ui.run(joanRow, "OnClick")
            assert(not d.model:IsShown() and d.mark:IsShown() and d.model.unit == nil, "unavailable model hid the fallback crest")
            d.model.SetUnit = setUnit
            ui.run(joanRow, "OnClick")
            assert(d.model:IsShown() and d.model._unit == "player" and not d.mark:IsShown(), "model call wasn't retried")
        end
        -- Restore the arrival used by the item-level animation checks below.
        ui.run(miraRow, "OnClick")
        ui.run(joanRow, "OnClick")
    end
    if scenario ~= "secrets" then
        assert(d.ilvl._text == "0", "the item level doesn't count up from nothing: " .. tostring(d.ilvl._text))
        for _ = 1, 60 do M.step(1 / 60) end
        assert(d.ilvl._text == "13", "the item level didn't count up to 13: " .. tostring(d.ilvl._text))
    end
    GetCursorPosition = function() return 100, 0 end
    ui.run(d.model, "OnMouseDown", "LeftButton")
    GetCursorPosition = function() return 150, 0 end
    ui.run(d.model, "OnUpdate", 0.016)
    assert(math.abs(d.model._rotation - (0.61 + 50 * 0.01)) < 1e-9, "dragging didn't turn the model: " .. tostring(d.model._rotation))
    ui.run(d.model, "OnMouseUp", "LeftButton")
    GetCursorPosition = nil
    ui.run(miraRow, "OnClick")
    assert(not d.model:IsShown() and d.model._unit == nil and d.mark:IsShown(), "the model stayed for Mira, or her crest didn't come back")
    -- The pieces no page uses yet, in their states. A check set from code ticks at once; clicked (the
    -- game ticks a CheckButton, then runs its OnClick) its tick pops in from small and lands whole. A
    -- dropdown shows its words; a divider is a line, or with its arch a line each side of it.
    do
        local host = CreateFrame("Frame", nil, UIParent)
        local box = Skin.check(host)
        assert(not box.tick:IsShown(), "a new check is ticked")
        box:SetChecked(true)
        assert(box.tick:IsShown() and box.tick:GetScale() == 1 and not M.running(box.tick, "pop"), "a check set from code didn't tick at once")
        box:SetChecked(false)
        assert(not box.tick:IsShown(), "a check set off from code kept its tick")
        box._checked = true
        ui.run(box, "OnClick", "LeftButton")
        assert(box.tick:IsShown() and box.tick:GetScale() < 1 and M.running(box.tick, "pop"), "a clicked check's tick doesn't pop in")
        for _ = 1, 30 do M.step(1 / 60) end
        assert(box.tick:GetScale() == 1 and not M.running(box.tick, "pop"), "a clicked check's tick didn't land whole")
        local menu = Skin.dropdown(host)
        menu:SetText("All messages")
        assert(menu.label._text == "All messages", "a dropdown's words")
        local plain, arch = Skin.divider(host), Skin.divider(host, true)
        assert(plain.line and not plain.mark and arch.mark and arch.left and arch.right, "a divider's line, and its arch")
        host:Hide()
    end
    ReliquaryDB.settings.motion = false
    SlashCmdList.RELIQUARY("")
    M.finishAll()
    ReliquaryDB.chars[miraKey] = nil
end

-- 15e. A character's Reputation, Quests and Timeline pages (docs/DESIGN.md, section 5). Reputation: a
-- card for each of the game's groups, in two columns once there are two, each card in the column that
-- is shorter so far; a sub-group's factions stand in; a faction at war is red; the bars fill as the page
-- arrives and move from where they were when it draws again. Quests: a card for each zone, the level on
-- a plate, the bars beside a card's objectives in one column past the longest. Timeline: the cards
-- arrive one after another; a stop opens and closes with its card easing to its new height, its lines
-- fading, and the cards under it moving with its foot.
do
    local M, Skin, V = ns.Motion, ns.Skin, ns.V
    local joanKey = ReliquaryDB.chars["Joan Ofârc-CAMWOWUS2Realm11RP"] and "Joan Ofârc-CAMWOWUS2Realm11RP" or "Unknown-CAMWOWUS2Realm11RP"
    local miraKey = "Mira Vale-CAMWOWUS2Realm11RP"
    local today = os.date("*t", time())
    local midnight = os.time({ year = today.year, month = today.month, day = today.day, hour = 0 })
    local entries = {}
    for i = 1, 4 do
        local from = midnight - 2 * 86400 - i * 7200
        entries[i] = { zone = "Westfall", from = from, to = from + 3600, active = 3000, level = 30,
            quests = { { title = "Quest " .. i .. " one", xp = 100 }, { title = "Quest " .. i .. " two", xp = 100 } } }
    end
    local mira = { name = "Mira", surname = "Vale", realm = ReliquaryDB.chars[joanKey].realm, level = 30, class = "Mage", classFile = "MAGE",
        race = "Human", updated = time() - 3 * 3600, share = { guild = false, friends = false, public = false },
        reps = { { name = "Alliance", header = true }, { name = "Stormwind", reaction = 6, value = 13000, lo = 9000, hi = 21000 },
            { name = "Ironforge", reaction = 5, value = 4500, lo = 3000, hi = 9000 },
            { name = "Alliance Forces", header = true, child = true }, { name = "Silverwing Sentinels", reaction = 4, value = 600, lo = 0, hi = 3000, child = true },
            { name = "Steamwheedle Cartel", header = true }, { name = "Booty Bay", reaction = 4, value = 1500, lo = 0, hi = 3000, child = true },
            { name = "Other", header = true }, { name = "Cenarion Circle", reaction = 8, value = 42999, lo = 42000, hi = 43000 },
            { name = "Bloodsail Buccaneers", reaction = 2, value = -4000, lo = -6000, hi = -3000, war = true },
            { name = "Wintersaber Trainers", reaction = 4, value = 0, lo = 0, hi = 3000 } },
        quests = { { id = 501, title = "The Defias Brotherhood", level = 22, group = "Westfall", obj = { { text = "Defias Messenger slain: 6/8" },
                { text = "Report to Gryan Stoutmantle" }, { text = "Collected the long list of Westfall's stolen goods: 1/12" } } },
            { id = 502, title = "Red Leather Bandanas", level = 15, group = "Westfall", done = true, obj = { { text = "Red Leather Bandana: 15/15", done = true } } },
            { id = 503, title = "Elmore's Task", level = 10, group = "Elwynn Forest" } },
        timeline = { entries = entries } }
    ReliquaryDB.chars[miraKey] = mira
    ReliquaryDB.settings.motion = false
    if not ReliquaryFrame:IsShown() then SlashCmdList.RELIQUARY("") end
    ui.run(ReliquaryFrame.Tabs[1], "OnClick")
    local list = (function() for _, f in ipairs(ui.frames) do if f._rows and f:IsVisible() and f._rows[1] and rawget(f._rows[1], "row") then return f end end end)()
    local miraRow
    for _, r in ipairs(list._rows) do if r.row.key == miraKey then miraRow = r end end
    ui.run(miraRow, "OnClick")
    local d = (function() for _, f in ipairs(ui.frames) do if f.pageButtons and f:IsVisible() then return f end end end)()
    local function page(key) for _, b in ipairs(d.pageButtons) do if b.page == key and b:IsShown() then ui.run(b, "OnClick") return end end error("no " .. key .. " page") end

    -- Reputation: three groups in two columns; the third under the shorter of the first two.
    page("reps")
    local el = d.list._rows[1]
    local cards = {}
    for _, c in ipairs(el.cards) do if c:IsShown() then cards[#cards + 1] = c end end
    local w = math.floor((V.PAGE_WIDTH - 12) / 2)
    assert(#cards == 3 and cards[1].title._text == "Alliance" and cards[2].title._text == "Steamwheedle Cartel" and cards[3].title._text == "Other",
        "Mira's reputation: one card for each group")
    local p1, p2, p3 = cards[1]._points.TOPLEFT, cards[2]._points.TOPLEFT, cards[3]._points.TOPLEFT
    assert(cards[1]._w == w and cards[2]._w == w and p1.x == 0 and p1.y == 0 and p2.x == w + 12 and p2.y == 0 and p3.x == w + 12
        and p3.y == -(cards[2]._h + 12) and cards[2]._h < cards[1]._h, "Mira's reputation isn't two columns, each card under the shorter one")
    assert(el._extent == math.max(cards[1]._h, cards[2]._h + 12 + cards[3]._h) + 12, "the reputation's height isn't its taller column's")
    -- In Alliance: a sub-group's name, and its faction a little in from the others; at war, red.
    local alliance = cards[1].repRows
    assert(alliance[3].line.kind == "sub" and alliance[3].name._text == "Alliance Forces" and not alliance[3].bar:IsShown()
        and alliance[4].name._points.BOTTOMLEFT.x == 12 and alliance[1].name._points.BOTTOMLEFT.x == 0, "a sub-group and its faction")
    -- A faction the game calls a child with no sub-group over it in its card stands with the others.
    assert(cards[2].repRows[1].name._text == "Booty Bay" and cards[2].repRows[1].name._points.BOTTOMLEFT.x == 0, "a faction stands in under no sub-group")
    local bloodsail = cards[3].repRows[2]
    assert(bloodsail.name._text == RED_FONT_COLOR:WrapTextInColorCode("Bloodsail Buccaneers") or bloodsail.name._text:find("^|c%x+Bloodsail"), "a faction at war isn't red")
    -- A faction's name and its standing stand level on the line over its bar; Exalted is full.
    local storm = alliance[1]
    assert(storm.name._points.BOTTOMLEFT.y == storm.standing._points.BOTTOMRIGHT.y and storm.standing._text == "Honored"
        and math.abs(storm.bar.target - 4000 / 12000) < 1e-9, "Stormwind's row")
    assert(cards[3].repRows[1].bar.target == 1, "an Exalted faction's bar isn't full")
    laidOut("Mira's reputation")
    -- One group: its card in the left column, at its own size. (The tab drawn again reads the record again.)
    local function again() ui.run(ReliquaryFrame.Tabs[1], "OnClick") end
    local was = mira.reps
    mira.reps = { { name = "Alliance", header = true }, { name = "Stormwind", reaction = 6, value = 13000, lo = 9000, hi = 21000 } }
    again()
    assert(d.list._rows[1].cards[1]._w == w and d.list._rows[1].cards[1]._points.TOPLEFT.x == 0 and not d.list._rows[1].cards[2]:IsShown(),
        "one group's card isn't in the left column at its own size")
    mira.reps = was
    again()

    -- Quests: a card for each zone; the level on its plate; the bars of a card in one column past the
    -- longest objective that counts, an objective that doesn't count with none.
    page("quests")
    local west, elwynn = d.list._rows[1].cards[1], d.list._rows[2].cards[1]
    assert(#d.list._rows == 2 and west.title._text == "Westfall" and elwynn.title._text == "Elwynn Forest" and west.questRows[1].plate.level._text == "22"
        and west.questRows[2].ready:IsShown() and not west.questRows[1].ready:IsShown(), "Mira's quest log")
    local objs = west.objRows
    local x = objs[1].bar._points.LEFT.x
    west.measure:SetText(objs[3].text._text)
    local longest = west.measure:GetStringWidth()
    west.measure:SetText("")
    assert(objs[1].bar:IsShown() and not objs[2].bar:IsShown() and objs[3].bar:IsShown() and objs[4].bar:IsShown()
        and objs[3].bar._points.LEFT.x == x and objs[4].bar._points.LEFT.x == x and x >= 32 + longest, "the objectives' bars aren't one column past the longest")
    assert(math.abs(objs[1].bar.target - 6 / 8) < 1e-9 and objs[4].bar.target == 1, "an objective's bar isn't as far along as it is")
    laidOut("Mira's quests")

    -- With animations on.
    page("reps")
    M.setEnabled(true)
    -- Reputation arriving (here, shown again after Gear): the cards fade in after one another, the bars
    -- fill from nothing; drawn again with a faction risen, its bar moves from where it was.
    page("gear")
    page("reps")
    el = d.list._rows[1]
    storm = el.cards[1].repRows[1]
    assert(el.cards[1]:GetAlpha() == 0 and el.cards[2]:GetAlpha() == 0 and storm.bar.frac == 0, "the reputation page doesn't arrive")
    M.step(0.03)
    assert(el.cards[1]:GetAlpha() > el.cards[2]:GetAlpha(), "the reputation's cards don't arrive one after another")
    for _ = 1, 60 do M.step(1 / 60) end
    assert(el.cards[3]:GetAlpha() == 1 and math.abs(storm.bar.frac - 4000 / 12000) < 1e-9, "the reputation page didn't arrive whole")
    mira.reps[2].value = 16000
    again()
    local from = M.value(storm.bar, "fill")
    assert(el.cards[1]:GetAlpha() == 1 and from and math.abs(from - 4000 / 12000) < 1e-9, "a faction risen doesn't move from where its bar was")
    for _ = 1, 60 do M.step(1 / 60) end
    assert(math.abs(storm.bar.frac - 7000 / 12000) < 1e-9, "a faction's bar didn't move to its new standing")

    -- Timeline arriving: its cards one after another.
    page("road")
    local rows = d.road._rows
    assert(rows[1].content:GetAlpha() == 0 and rows[2].content:GetAlpha() == 0, "the timeline's cards don't arrive")
    M.step(0.03)
    assert(rows[1].content:GetAlpha() > rows[2].content:GetAlpha(), "the timeline's cards don't arrive one after another")
    for _ = 1, 60 do M.step(1 / 60) end
    assert(rows[4].content:GetAlpha() == 1 and rows[4].content._points.TOPLEFT.y == 0, "the timeline didn't arrive whole")
    -- A stop opening: its card grows from its height closed to its height open, its lines fading in, and
    -- the card under it moves down with its foot; the list takes the new height once it has grown.
    local f, under = rows[1], rows[2]
    if f.element.open then
        ui.run(f.card.head, "OnClick")
        for _ = 1, 60 do M.step(1 / 60) end
    end
    local h0, extent0 = f.card._h, f._extent
    assert(not f.element.open and h0 == f.element.h and extent0 == h0 + 8, "the first stop isn't closed to begin with")
    ui.run(f.card.head, "OnClick")
    local h1 = f.element.h
    assert(f.element.open and h1 > h0 and f.card._h == h0 and f.card.lines:GetAlpha() == 0 and f.card.lines:IsShown() and f._extent == extent0
        and under.content._points.TOPLEFT.y == 0, "a stop doesn't start opening from its height closed")
    M.step(M.slow / 2)
    local h = f.card._h
    assert(h > h0 and h < h1 and f.card.lines:GetAlpha() > 0 and f.card.lines:GetAlpha() < 1 and f._extent == extent0,
        ("a stop opening isn't halfway: %s of %s to %s"):format(tostring(h), h0, h1))
    assert(math.abs(under.content._points.TOPLEFT.y + (h - h0)) < 1e-6, "the card under an opening stop doesn't move with its foot")
    M.step(M.slow)
    assert(f.card._h == h1 and f._extent == h1 + 8 and f.card.lines:GetAlpha() == 1 and under.content._points.TOPLEFT.y == 0
        and not M.running(f.card, "height") and not M.running(under.content, "slide"), "a stop didn't come to rest open")
    -- Closing: the list takes the closed height at once, the card shrinks from its height open with its
    -- lines fading out, and the card under it rises with its foot.
    ui.run(f.card.head, "OnClick")
    assert(not f.element.open and f._extent == h0 + 8 and f.card._h == h1 and f.card.lines:GetAlpha() == 1
        and math.abs(under.content._points.TOPLEFT.y + (h1 - h0)) < 1e-6 and f.card.head.chev.down:IsShown(), "a stop doesn't start closing from its height open")
    M.step(M.slow / 2)
    h = f.card._h
    assert(h < h1 and h > h0 and f.card.lines:GetAlpha() < 1 and math.abs(under.content._points.TOPLEFT.y + (h - h0)) < 1e-6,
        "a stop closing isn't halfway, or the card under it doesn't rise with its foot")
    M.step(M.slow)
    assert(f.card._h == h0 and not f.card.lines:IsShown() and under.content._points.TOPLEFT.y == 0 and not M.running(f.card, "height"),
        "a stop didn't come to rest closed")
    M.setEnabled(false)
    ReliquaryDB.chars[miraKey] = nil
    ui.run(ReliquaryFrame.Tabs[1], "OnClick")
end

-- 15f. An item's page slides in from the right over the tab it was opened from, which goes once the
-- page lies over it; Back and Escape slide it away over the tab, shown again under it; another item
-- arrives from the right, the one before it from the left. The Sharing tab's Animations switch: off,
-- every movement lands at once, and it stays off; on, the window moves again. /rq tour: a screenshot
-- of every tab and every page of the character played, each once its movement has landed, with the
-- interface showing; then the window as it was.
do
    local M, Skin, V = ns.Motion, ns.Skin, ns.V
    local function steps(n) for _ = 1, n do M.step(1 / 60) end end
    -- The game's clock and the window's together, a frame at a time.
    local function play(sec) for _ = 1, math.floor(sec * 60 + 0.5) do advance(1 / 60) M.step(1 / 60) end end
    local function escape()
        for _, name in ipairs(UISpecialFrames) do if _G[name] and _G[name]:IsShown() then _G[name]:Hide() end end
    end
    -- From a shut window, whatever the checks before left showing.
    if ReliquaryFrame:IsShown() then
        SlashCmdList.RELIQUARY("")
        M.finishAll()
    end
    ReliquaryDB.settings.motion = nil
    SlashCmdList.RELIQUARY("")
    local win = ReliquaryFrame
    ui.run(win.Tabs[1], "OnClick")
    steps(60)
    local d = (function() for _, f in ipairs(ui.frames) do if f.pageButtons and f:IsVisible() then return f end end end)()
    local tab = d:GetParent()
    local page, sheet = ReliquaryItemPage, ReliquaryItemPage.sheet
    local content, plate = sheet.content, sheet.plate
    local head = d.slots[1]
    local function open(id) if scenario == "secrets" or not head.rq then V.openItemPage({ id = id }, "item:" .. id) else ui.run(head, "OnClick") end end
    open(264120)
    local slide = M.value(content, "slide")
    assert(page:IsShown() and sheet:IsShown() and tab:IsShown() and slide and slide[1] > 0 and content:GetAlpha() == 0 and plate:IsShown() and plate:GetAlpha() == 0,
        "an item's page doesn't slide in over its tab")
    -- Over the tab: the sheet above it, the page's content above the plate that covers the tab.
    assert(sheet:GetFrameLevel() > tab:GetFrameLevel() and content:GetFrameLevel() > plate:GetFrameLevel(),
        "the item's page isn't drawn over its tab, or its content over its plate")
    steps(6)
    assert(tab:IsShown() and M.value(content, "slide")[1] < slide[1] and content:GetAlpha() > 0, "the item's page doesn't move in")
    steps(30)
    assert(not tab:IsShown() and not M.running(content, "slide") and content._points.TOPLEFT.x == 0 and content:GetAlpha() == 1 and not plate:IsShown(),
        "the item's page in place didn't cover its tab, or its plate stayed")
    -- Another item from its page arrives from the right; Escape steps back to the first, from the left.
    V.openItemPage({ id = 2589 }, "item:2589")
    assert(page:IsShown() and #page.history == 1 and M.value(content, "slide")[1] > 0, "another item's page doesn't arrive from the right")
    steps(30)
    escape()
    assert(page:IsShown() and page.item.id == 264120 and #page.history == 0 and M.value(content, "slide")[1] < 0 and not tab:IsShown(),
        "stepping back doesn't bring the item before from the left")
    steps(30)
    -- Back: the page closes at once and the tab is back under it; the sheet slides away to the right.
    ui.run(page.back, "OnClick")
    assert(not page:IsShown() and tab:IsShown() and sheet:IsShown() and plate:IsShown(), "Back didn't uncover the tab under the sliding page")
    steps(4)
    local away = M.value(content, "slide")
    assert(away and away[1] > 0 and content:GetAlpha() < 1, "Back doesn't slide the page away to the right")
    steps(30)
    assert(not sheet:IsShown() and content._points.TOPLEFT.x == 0 and content:GetAlpha() == 1, "the page didn't go once it slid away")
    -- Escape, the same; back before it lands and it slides in again from where it is.
    open(264120)
    steps(30)
    escape()
    assert(not page:IsShown() and tab:IsShown() and sheet:IsShown() and UISpecialFrames[#UISpecialFrames] == "ReliquaryEscape", "Escape doesn't slide the page away")
    steps(4)
    open(264120)
    local back = M.value(content, "slide")
    assert(page:IsShown() and back and back[1] > 0 and back[1] < 3 * M.SLIDE_PAGE and tab:IsShown(), "opened again while leaving, it didn't come back from where it was")
    steps(30)
    assert(not tab:IsShown() and not plate:IsShown(), "opened again while leaving, it didn't cover its tab")
    -- The window closing takes it at once.
    escape()
    steps(4)
    SlashCmdList.RELIQUARY("")
    steps(30)
    assert(not win:IsShown() and not sheet:IsShown() and not M.ticking(), "the page outlived the window")

    -- The Animations switch.
    SlashCmdList.RELIQUARY("")
    ui.run(win.Tabs[6], "OnClick")
    steps(30)
    -- Each setting's row holds its title and its line, and the next row starts below it.
    local rowsChecked = 0
    for _, f in ipairs(ui.frames) do
        local row = f._kind == "CheckButton" and f.key and rawget(f, "Text") and f:IsVisible() and f:GetParent()
        local line = row and rawget(row, "line")
        if line then
            local r, words = ui.rect(row), ui.rect(line)
            assert(r and words and words.bottom >= r.bottom - 0.5, "a setting's line runs out of its row: " .. tostring(f.key))
            rowsChecked = rowsChecked + 1
        end
    end
    assert(rowsChecked == 6, "the Sharing tab's rows with a line: " .. rowsChecked)
    local switch
    for _, f in ipairs(ui.frames) do if f._kind == "CheckButton" and f.key == "motion" and f:IsVisible() then switch = f end end
    assert(switch and switch:GetChecked() and switch.Text._text == "Animations", "the Animations switch isn't on")
    ui.run(win.Tabs[1], "OnClick")
    assert(M.running(tab, "slide"), "changing tab didn't move")
    ui.run(win.Tabs[6], "OnClick")
    -- A click as the game makes it: the box switched, then its scripts.
    local function click(box) box._checked = not box._checked if box:GetScript("PreClick") then ui.run(box, "PreClick") end ui.run(box, "OnClick") end
    -- A switch's knob slides and its track warms; a tick in the grid pops in. Neither is landed by the
    -- tab drawing itself again after the click.
    local public, gold
    for _, f in ipairs(ui.frames) do
        if f._kind == "CheckButton" and f:IsVisible() then
            if f.key == "public" then public = f elseif f.part == "gold" and f.scope == "public" then gold = f end
        end
    end
    local wasPublic, wasGold = public:GetChecked() and true or false, gold:GetChecked() and true or false
    click(public)
    local knob = M.value(public.knob, "x")
    assert(knob and M.running(public.track.fill, "fill"), "a switch's knob doesn't slide, or its track doesn't change colour")
    steps(30)
    assert(not M.running(public.knob, "x") and public.knobX == (wasPublic and 2 or 18), "a switch's knob didn't come to rest")
    click(public)
    steps(30)
    if not gold:GetChecked() then
        click(gold)
        assert(gold.tick:IsShown() and gold.tick:GetScale() < 1 and M.running(gold.tick, "pop"), "a tick in the grid doesn't pop in")
        steps(30)
        click(gold)
    end
    assert((public:GetChecked() and true or false) == wasPublic and (gold:GetChecked() and true or false) == wasGold, "the switch and the box didn't go back as they were")
    click(switch)
    assert(ReliquaryDB.settings.motion == false and not M.enabled() and M.moving() == 0, "Animations off didn't land the window's movement at once")
    -- A setting's row lights while the pointer is on its switch (anywhere on the row), and goes dark again.
    local lit = switch:GetParent()
    ui.run(switch, "OnEnter")
    assert(lit.fill.alpha == 1, "a setting's row doesn't light under the pointer")
    ui.run(switch, "OnLeave")
    assert(lit.fill.alpha == 0, "a setting's row stays lit after the pointer leaves")
    -- The line under the switches says only what there is to say: messages waiting to go out, or a
    -- client that can't pack them; nothing, otherwise.
    local panel = lit:GetParent():GetParent():GetParent()
    local queued, canShare = ns.queued, ns.canShare
    assert(panel.status:IsShown() == (ns.queued() > 0 or not ns.canShare()), "the line under the switches shows with nothing to say")
    ns.queued, ns.canShare = function() return 3 end, function() return true end
    panel.refresh()
    assert(panel.status:IsShown() and panel.status._text == "3 messages waiting to go out: they leave about one a second, and wait out fights and instances."
        and panel.status._points.TOPLEFT.rel == panel.every, "the messages waiting, under the switches: " .. tostring(panel.status._text))
    ns.canShare = function() return false end
    panel.refresh()
    assert(panel.status._text == "This game client can't pack messages for other players, so sharing waits.", "a client that can't pack messages")
    ns.queued, ns.canShare = function() return 0 end, function() return true end
    panel.refresh()
    assert(not panel.status:IsShown(), "the line under the switches shows with nothing to say")
    ns.queued, ns.canShare = queued, canShare
    panel.refresh()
    ui.run(win.Tabs[1], "OnClick")
    assert(tab:GetAlpha() == 1 and not M.running(tab, "slide"), "with Animations off, a tab still slides in")
    SlashCmdList.RELIQUARY("")
    SlashCmdList.RELIQUARY("")
    assert(not M.enabled() and win.canvas:GetAlpha() == 1, "Animations off didn't hold for the next opening")
    ui.run(win.Tabs[6], "OnClick")
    assert(not switch:GetChecked(), "the Animations switch shows on")
    click(switch)
    assert(ReliquaryDB.settings.motion == true and M.enabled() and M.running(switch.knob, "x"), "Animations on: the window, and the switch's own knob, don't move")
    steps(30)
    SlashCmdList.RELIQUARY("")
    steps(30)
    ReliquaryDB.settings.motion = nil

    -- /rq tour.
    local seen = {}
    Screenshot = function()
        seen[#seen + 1] = { tab = win.selectedTab, page = d.pageSel, item = page:IsShown(), alpha = win.canvas:GetAlpha(), ilvl = d.ilvl._text,
            content = content:GetAlpha(), sliding = M.running(content, "slide"), ui = uiShown, names = cvars.UnitNameOwn .. cvars.UnitNameNPC }
        snap()
    end
    if scenario == "bare" then Screenshot = nil end
    local said, shotsBefore = #printed, #shots
    local names = cvars.UnitNameOwn .. cvars.UnitNameNPC
    local me = ReliquaryDB.chars["Joan Ofârc-CAMWOWUS2Realm11RP"] or ReliquaryDB.chars["Unknown-CAMWOWUS2Realm11RP"]
    local notes = #(me.photos or {})
    SlashCmdList.RELIQUARY("tour")
    if scenario == "bare" then
        assert(printed[#printed] == "|cffe8a13aReliquary|r No photo: this game client doesn't let addons take screenshots." and not win:IsShown(),
            "/rq tour on a client without screenshots: " .. tostring(printed[#printed]))
    else
        play(60)
        -- What it should have shown: Characters on the character played, each of its pages, the page of
        -- the first item it wears, and every other tab that isn't greyed.
        local want, pages = 0, {}
        for _, b in ipairs(d.pageButtons) do if b:IsShown() then want, pages[b.page] = want + 1, true end end
        local worn = scenario ~= "secrets"
        if worn then want = want + 1 end
        local tabs = {}
        for i = 2, #win.Tabs do if win.Tabs[i]:IsEnabled() then want, tabs[i] = want + 1, true end end
        assert(#seen == want and #shots == shotsBefore + want, "/rq tour took " .. #seen .. " pictures, not " .. want)
        local item = 0
        for _, s in ipairs(seen) do
            -- Each once its movement has landed (the window open, an item's page in place, the item level
            -- counted up), with the interface showing and the names over heads as they were.
            assert(s.alpha == 1 and s.content == 1 and not s.sliding and s.ui and s.names == names, "a picture of the tour was taken too soon, or without the interface")
            if s.item then item = item + 1
            elseif s.tab == 1 then
                assert(pages[s.page], "a picture of a page that doesn't show: " .. tostring(s.page))
                pages[s.page] = nil
                if s.page == "gear" and worn then assert(s.ilvl == "13", "the tour's picture of Gear before its item level counted up: " .. tostring(s.ilvl)) end
            else
                assert(tabs[s.tab], "a picture of a tab twice, or of a greyed one: " .. tostring(s.tab))
                tabs[s.tab] = nil
            end
        end
        assert(next(pages) == nil and next(tabs) == nil and item == (worn and 1 or 0), "/rq tour missed a page or a tab")
        assert(not win:IsShown() and printed[#printed] == "|cffe8a13aReliquary|r Photos taken: they're in the game's Screenshots folder." and #printed == said + 1,
            "/rq tour didn't put the window back, or said something else: " .. tostring(printed[#printed]))
        -- Open on Characters at another page with an item's page over it, it comes back to all three.
        SlashCmdList.RELIQUARY("")
        ui.run(win.Tabs[1], "OnClick")
        d.tabs.onSelect("tal")
        V.openItemPage({ id = 2589 }, "item:2589")
        play(1)
        seen = {}
        SlashCmdList.RELIQUARY("tour")
        play(60)
        assert(#seen == want and win:IsShown() and win.selectedTab == 1 and d.pageSel == "tal" and page:IsShown() and page.item.id == 2589,
            "/rq tour didn't put the window back as it was: tab " .. tostring(win.selectedTab) .. ", page " .. tostring(d.pageSel))
        page.close()
        -- Closed by hand while the last picture before the other tabs is being taken (each tab would open
        -- the window again), it takes no more and the window stays shut.
        local others = 0
        for i = 2, #win.Tabs do if win.Tabs[i]:IsEnabled() then others = others + 1 end end
        seen = {}
        local take = Screenshot
        Screenshot = function()
            take()
            if #seen == want - others then SlashCmdList.RELIQUARY("") end
        end
        SlashCmdList.RELIQUARY("")
        SlashCmdList.RELIQUARY("tour")
        play(60)
        Screenshot = take
        local taken = #seen
        assert(others > 0 and taken == want - others and not win:IsShown(), "/rq tour went on after the window was closed: " .. taken .. " pictures")
        -- Never in a fight, and the window doesn't open for it.
        inCombat = true
        SlashCmdList.RELIQUARY("tour")
        local opened = win:IsShown()
        play(30)
        inCombat = false
        assert(not opened and #seen == taken and not win:IsShown() and printed[#printed] == "|cffe8a13aReliquary|r No photo: not during a fight.", "/rq tour in a fight")
        -- Each picture is noted as a Print Screen is: a screenshot, never one of her photos.
        local added = #shots - shotsBefore
        assert(#me.photos == notes + added, "the tour's pictures weren't each noted once: " .. (#me.photos - notes) .. " of " .. added)
        for k = notes + 1, #me.photos do assert(me.photos[k].kind == "screenshot", "a tour's picture noted as " .. tostring(me.photos[k].kind)) end
        for k = #me.photos, notes + 1, -1 do me.photos[k] = nil end -- the photos' own checks below count only theirs
    end
    Screenshot = scenario ~= "bare" and snap or nil
    ReliquaryDB.settings.motion = false
    M.finishAll()

    -- A wrapped text's height is its lines at one line's height each, whatever height the client gives
    -- the block as a whole (a renderer that measures two lines as nearly three); one line is its own.
    do
        local host = CreateFrame("Frame", nil, UIParent)
        local one = host:CreateFontString(nil, "ARTWORK")
        one:SetFontObject(Skin.font("small"))
        local function wrapped(lines, said)
            return { GetStringHeight = function() return said end, GetNumLines = function() return lines end,
                GetFontObject = function() return Skin.font("small") end, GetParent = function() return host end }
        end
        one:SetText("Ag")
        local line = one:GetStringHeight()
        assert(Skin.textHeight(wrapped(2, 36.25)) == 2 * line and Skin.textHeight(wrapped(1, 13)) == 13 and Skin.textHeight(one) == line,
            "a wrapped text's height isn't its lines: " .. Skin.textHeight(wrapped(2, 36.25)))
        host:Hide()
    end
    -- How an item's page is laid out: the item on a 56-unit slot lined in its quality's colour, its name
    -- in that colour, Back a quiet button with its chevron; an item nothing is known of has no cards in
    -- either column, nothing under its name, and the addresses head its column; an address typed over
    -- comes back.
    SlashCmdList.RELIQUARY("")
    V.openItemPage({ id = 999999 }, "item:999999")
    assert(page:IsShown() and #page.list:GetDataProvider()._items == 0 and #page.who:GetDataProvider()._items == 0
        and page.linkCard._points.TOPLEFT.relPoint == "TOPLEFT" and not page.meta:IsShown() and not page.board:IsShown(),
        "an item nothing is known of: its page isn't empty, or its addresses don't head its column")
    assert(page.back.kind == "quiet" and page.back.glyph and page.back:GetText() == "Back", "Back isn't a quiet button with its chevron")
    local box = page.links[1]
    box:SetText("typed over")
    ui.run(box, "OnTextChanged", true)
    assert(box:GetText() == "https://www.wowhead.com/forever/item=999999" and page.links[2]:GetText() == "https://foreverdb.net/item/999999",
        "the addresses: " .. tostring(box:GetText()))
    if scenario ~= "secrets" then
        V.openItemPage({ id = 264120, q = 2 }, "item:264120")
        local r, g = Skin.qualityColor(2)
        assert(page.icon:GetWidth() == 56 and page.icon.rqLine:GetColor() == r * 0.8 and select(2, page.icon.rqLine:GetColor()) == g * 0.8
            and page.name._text:find(ITEM_QUALITY_COLORS[2].hex, 1, true) == 1, "the circlet's slot and name aren't in its quality's colour")
        -- Its own column: a card of what it is, then the addresses right under it.
        local cards = page.list:GetDataProvider()._items
        assert(cards[1] and cards[1].kind == "facts" and page.linkCard._points.TOPLEFT.relPoint == "BOTTOMLEFT", "the circlet's own column")
    end
    SlashCmdList.RELIQUARY("")
end

-- 14. Logging out in the middle of a photo: the settings go back before the game saves them.
screenshotAnswers = false
SlashCmdList.RELIQUARY("portrait")
advance(0.2)
screenshotAnswers = true
SlashCmdList.RELIQUARY("status")
loggingOut = true
fire("PLAYER_LOGOUT")

---------------------------------------------------------------------------
-- Checks
---------------------------------------------------------------------------
local function walk(v, path)
    assert(not rawequal(v, SECRET), "secret value stored at " .. path)
    if type(v) == "table" then for k, x in pairs(v) do walk(k, path .. ".<key>") walk(x, path .. "." .. tostring(k)) end end
    assert(type(v) ~= "function" and type(v) ~= "userdata", "unsaveable value at " .. path)
end
walk(ReliquaryDB, "ReliquaryDB")
assert(cvars.screenshotQuality == "3" and cvars.cameraZoomSpeed == "20" and cvars.UnitNameNPC == "1" and cvars.UnitNameFriendlyPlayerName == "1"
    and not ReliquaryDB.settings.restore, "settings not put back when logging out in the middle of a photo")
local c = ReliquaryDB.chars["Joan Ofârc-CAMWOWUS2Realm11RP"] or ReliquaryDB.chars["Unknown-CAMWOWUS2Realm11RP"]
assert(c, "character not recorded")
if scenario ~= "secrets" then
    assert(c.level == 12 and c.xp == 3890 and c.xpMax == 8800, "XP lost at logout")
    assert(c.money == 12345 and c.played and c.played >= 41820, "money or played")
    assert(c.gear[11] and c.gear[11].name == "Ancient Heirloom", "ring missing")
    assert(#chatPrinted == 0, "played time printed in chat")
    assert(c.places["Thendal Grove"], "travel not recorded")
    local tl = c.timeline
    assert(tl and #tl.entries == 2 and #tl.pending == 0 and not tl.cur, "timeline entries")
    local a, b = tl.entries[1], tl.entries[2]
    assert(a.zone == "Zephras Isle" and a.kills == 3 and a.level == 12 and a.active > 0, "first timeline entry") -- the quest makes it, whatever the time
    assert(#a.quests == 1 and a.quests[1].title == "The Calmbreeze Crystal" and a.quests[1].xp == 850, "quest on the first entry")
    assert(b.zone == "Darkshore" and b.kills == 2 and b.passed and b.passed[1] == "The Great Sea" and #b.passed == 1, "second timeline entry")
    assert(b.quests[1].xp == 1100 and b.quests[1].title == (scenario ~= "bare" and "The Lighthouse Keeper" or nil), "quest title from the game")
    assert(tl.atLogout == true and not tl.hiddenKills, "timeline at logout")
    local b = c.before
    assert(b and b.done and b.level == 12, "before Reliquary: read")
    if scenario ~= "bare" then
        assert(#b.challenges == 1 and b.challenges[1].name == "A New Beginning" and b.challenges[1].date == "2026-11-06", "before: challenges")
        assert(b.quests.count == 4 and b.quests.titles[98001] == "Into the Grove" and b.quests.titles[98004] == nil, "before: quests")
        assert(#b.explored == 1 and b.explored[1].zone == "Zephras Isle" and table.concat(b.explored[1].areas, ",") == "Thendal Grove,Thendal Village,Valanaar", "before: explored")
        assert(b.flights == nil, "before: no flight paths")
        assert(#b.stats == 1 and b.stats[1].name == "Creatures killed" and b.stats[1].value == 214, "before: statistics")
        assert(b.played and b.played >= 41820 and #b.titles == 0 and b.pvp.kills == 0, "before: played, titles, PvP")
    else
        for _, part in ipairs({ "challenges", "quests", "stats", "pvp", "titles", "explored" }) do
            assert(b.missing and b.missing[part], "old client: " .. part .. " not named as missing")
        end
    end
    local kinds = {}
    for i, p in ipairs(c.photos or {}) do kinds[i] = p.kind end
    kinds = table.concat(kinds, ",")
    if auto then
        assert(kinds == "photo,screenshot,levelup,place,portrait,place,place,place,portrait,portrait,photo", "photo notes: " .. kinds)
        local cam = c.photos[5].cam -- the resting portrait: how the framing went
        assert(cam and cam.from == 15 and cam.to == 3.2 and #cam.seen > 0 and cam.at and cam.waited >= 1.6, "framing measurements")
        assert(not c.photos[1].cam, "measurements on an unframed photo")
        local p = c.photos
        assert(p[1].stamp == shots[1].stamp and p[1].sub == "Thendal Grove" and p[1].zone == "Zephras Isle", "photo note")
        assert(p[2].form == "Bear Form" and not p[3].form and p[3].level == 12, "form or level in the notes")
        assert(p[4].sub == "Thendal Grove" and p[6].sub == "Moonwell Glade" and p[8].sub == "Shrine of the Moon", "place photo notes")
        assert(c.errors and c.errors.photos and c.errors.photos:find("FlipCameraYaw"), "refused framing not reported")
        c.errors.photos = nil
        if next(c.errors) == nil then c.errors = nil end
    elseif scenario == "bare" then
        assert(kinds == "screenshot", "old client: only the player's own screenshot is noted, got " .. kinds)
    end
    if scenario ~= "bare" then
        assert(c.ruleset == "rppvp", "ruleset " .. tostring(c.ruleset))
        assert(c.gear[11].tip and #c.gear[11].tip >= 5, "ring tooltip")
        assert(#c.talents.nodes == #TREE, "talents")
        assert(c.legacy and c.legacy.spent == 3, "legacy")
        assert(c.bank and #c.bank == 1, "bank")
        assert(#c.quests == 3 and c.quests[3].done, "quests")
        assert(c.reps and #c.reps == 5, "reputation")
    else
        assert(#c.quests == 1, "old quest API")
        assert(c.reps and #c.reps == 2, "old reputation API")
    end
end
if scenario ~= "bare" and not secrets then
    local r = c.recipes
    assert(r and r.Alchemy and r.Cooking and not r.Tailoring, "recipes: her professions, and never someone else's linked one")
    local a = r.Alchemy
    assert(a.line == 171 and a.sk == 41 and a.mx == 75 and a.cats[1001] == "Potions", "recipes: Alchemy")
    local p = a.list[2330]
    assert(p.n == "Minor Healing Potion" and p.o == 118 and #p.u == 3 and p.u[3].id == 3371 and p.d == 2 and p.ic == I("inv_potion_51") and a.cats[p.c] == "Potions",
        "recipes: the healing potion")
    assert(a.list[2337] and a.list[2337].o == 858 and a.list[2337].n == "Lesser Healing Potion", "recipes: one learned with the window closed")
    local egg = r.Cooking.list[8604]
    assert(egg and egg.u[2].id == 2678 and r.Cooking.cats[egg.c] == "Eggs" and r.Cooking.list[2540] and r.Cooking.line == 185, "recipes: Cooking")
    assert(ReliquaryDB.sources[118].m[2330].p == "Alchemy" and ReliquaryDB.sources[2678].r[8604].o == 6888, "recipes: where items come from")
    assert(ReliquaryDB.items[6888] and ReliquaryDB.items[6888].info.name == "Herb Baked Egg" and ReliquaryDB.items[3371], "recipes: what they make and use, kept for the dashboard")
else
    assert(not c.recipes, "recipes where the game gave none")
end
-- A whisper (Chat.lua) is kept as the game gave it; one the game keeps secret isn't kept at all.
fire("CHAT_MSG_WHISPER", S("Meet me at the moonwell"), S("Thalia Moonwhisper"), "", "", "Thalia Moonwhisper", "", 0, 0, "", 0, 41, nil, 0, false, false, false, false, { userID = 0 })
do
    local who, talk = next(ReliquaryDB.whispers or {})
    if scenario == "secrets" then
        assert(who == nil, "a secret whisper was kept")
    else
        assert(type(talk) == "table" and talk.list[1].m == "Meet me at the moonwell" and not talk.list[1].o, "a whisper wasn't kept: " .. tostring(who))
    end
end
-- A Battle.net whisper is kept under the friend's BattleTag, never the protected name the game gives
-- in chat; one the game keeps secret isn't kept either.
C_BattleNet = { GetAccountInfoByID = function(id)
    if id == 504 then return { bnetAccountID = 504, battleTag = "Brannoc#1504", gameAccountInfo = { classFilename = "WARRIOR" } } end
end }
fire("CHAT_MSG_BN_WHISPER", S("Ready when you are"), S("|Kq504|k"), "", "", "", "", 0, 0, "", 0, 42, "", S(504), false, false, false, false, { userID = 0 })
do
    local bn = (ReliquaryDB.whispers or {})["bn:Brannoc#1504"]
    if scenario == "secrets" then
        assert(bn == nil, "a secret Battle.net whisper was kept")
    else
        assert(type(bn) == "table" and bn.list[1].m == "Ready when you are" and bn.list[1].c == "WARRIOR" and not (ReliquaryDB.whispers or {})["|Kq504|k"],
            "a Battle.net whisper wasn't kept under the BattleTag")
    end
end
if scenario == "secrets" then
    local tl = c.timeline
    assert(tl and #tl.entries == 0 and tl.hiddenKills == 6, "everything secret: no timeline entries, every kill counted apart")
    assert(c.before and c.before.done and not c.before.challenges and not c.before.quests, "everything secret: nothing from before")
end
assert(not c.errors, "errors: " .. (function() local t = {} for k, v in pairs(c.errors or {}) do t[#t + 1] = k .. "=" .. v end return table.concat(t, "; ") end)())

---------------------------------------------------------------------------
-- Write the file like the game does
---------------------------------------------------------------------------
local function q(s)
    return '"' .. s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "\\r") .. '"'
end
local out = {}
local function emit(v, indent)
    local t = type(v)
    if t == "string" then return q(v) end
    if t == "number" then
        if v == math.floor(v) then return string.format("%d", v) end
        return string.format("%.14g", v)
    end
    if t == "boolean" or t == "nil" then return tostring(v) end
    local lines = { "{" }
    local n = #v
    for i = 1, n do lines[#lines + 1] = indent .. "\t" .. emit(v[i], indent .. "\t") .. ", -- [" .. i .. "]" end
    local keys = {}
    for k in pairs(v) do if not (type(k) == "number" and k >= 1 and k <= n and k == math.floor(k)) then keys[#keys + 1] = k end end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, k in ipairs(keys) do
        local key = type(k) == "string" and "[" .. q(k) .. "]" or "[" .. tostring(k) .. "]"
        lines[#lines + 1] = indent .. "\t" .. key .. " = " .. emit(v[k], indent .. "\t") .. ","
    end
    lines[#lines + 1] = indent .. "}"
    return table.concat(lines, "\n")
end
plainWords("what was printed in chat", table.concat(printed, "\n"))
local f = assert(io.open(outPath, "w"))
f:write("\nReliquaryDB = " .. emit(ReliquaryDB, "") .. "\n")
f:close()
io.stderr:write(("ok %s: %d gear, %d talents, %d printed lines\n"):format(scenario, (function() local n = 0 for _ in pairs(c.gear or {}) do n = n + 1 end return n end)(), c.talents and #c.talents.nodes or 0, #printed))
for _, p in ipairs(printed) do io.stderr:write("  > " .. p .. "\n") end
