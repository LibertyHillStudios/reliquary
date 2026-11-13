-- Several players in one simulated world, each running the whole Reliquary addon in a game
-- client of their own, talking through a simulated server that behaves like the game's: guild
-- messages reach every guildmate (and echo back to the sender), whispers reach one player of the
-- same faction, Battle.net messages reach one Battle.net friend, every addon is held to the
-- game's message rate, and nothing goes over 255 characters.
--
--     lua5.1 tests/share.lua <Reliquary.toc> [<Joan's saved data, written after the session>]
local tocPath, outPath = arg[1], arg[2]
local here = arg[0]:match("(.*/)") or "./"
local floor = math.floor

---------------------------------------------------------------------------
-- The world: one clock, the timers every client set, and the server
---------------------------------------------------------------------------
local world = { clock = 1794000000, timers = {}, clients = {}, byName = {}, byAccount = {}, log = {}, trpProfiles = {}, auctions = {}, drops = {},
    history = { ["1"] = {}, ["2"] = {}, ["3"] = {} }, lineID = 0, censored = {} }
local REALM = "CAMWOWUS2Realm11RP"
-- WoW: Forever names characters "Given Family", unique in the region, and its messages, whispers,
-- guild list, friends list and Battle.net all name them so; the realm is only the server behind
-- them. That is this world. RQ_NAMES=realm runs it with "Name-Realm" names, as other clients have.
local REGIONAL = os.getenv("RQ_NAMES") ~= "realm"
local SURNAMES = { Joan = "Ofârc", Thalia = "Moonwhisper", Mira = "Ashgrove", Brannoc = "Stonebrow", Eluned = "Dawnstride",
    Kael = "Emberwake", Grift = "Coinwhistle", Nobody = "Atall", Faelwen = "Duskleaf", Orlan = "Greymantle", Saeli = "Brightwater",
    Corvane = "Blackthorn" }
local function fullOf(name, surname)
    if REGIONAL then return name .. " " .. (surname or SURNAMES[name] or "Stranger") end
    return name .. "-" .. REALM
end
-- Your own characters are kept under their full name where names are "Given Family" (two of yours
-- may share a given name on one realm there), else under the name; and the realm.
local function ownKey(c) return (REGIONAL and (c.name .. " " .. c.surname) or c.name) .. "-" .. REALM end

local function advance(sec)
    local target = world.clock + sec
    while true do
        table.sort(world.timers, function(a, b) return a.at < b.at end)
        local t = world.timers[1]
        if not t or t.at > target then break end
        table.remove(world.timers, 1)
        if t.at > world.clock then world.clock = t.at end
        t.fn()
    end
    world.clock = target
end

local GUILD = { name = "The Moonwell Circle", motd = "Moonwell at dusk. Bring silverleaf.",
    ranks = { "Guild Master", "Officer", "Veteran", "Member", "Initiate" },
    -- Guildmates who don't use Reliquary: the roster still lists them.
    others = {
        { "Orlan", 22, 1, 2, nil, "Greymantle" }, { "Saeli", 16, 8, 4, "Teldrassil", "Brightwater" },
        { "Brindle", 14, 4, 4, nil, "Copperkettle" }, { "Tamsin", 20, 5, 3, "Ashenvale", "Reedwhistle" }, { "Hollis", 12, 9, 5, nil, "Ambervale" },
        { "Corvane", 25, 2, 2, "Stonetalon Mountains", "Blackthorn" }, { "Wren", 9, 3, 5, nil, "Thistledown" }, { "Isolde", 19, 7, 4, nil, "Starfall" },
    },
}
local CLASS_IDS = { WARRIOR = 1, PALADIN = 2, HUNTER = 3, ROGUE = 4, PRIEST = 5, SHAMAN = 7, MAGE = 8, WARLOCK = 9, DRUID = 11 }
local CLASS_NAMES = { [1] = "Warrior", [2] = "Paladin", [3] = "Hunter", [4] = "Rogue", [5] = "Priest", [7] = "Shaman", [8] = "Mage", [9] = "Warlock", [11] = "Druid" }
local CLASS_FILES = {}
for file, id in pairs(CLASS_IDS) do CLASS_FILES[id] = file end

-- Items, as the game knows them: name, quality, item level, icon file id.
local ITEMS = {
    [769] = { "Chunk of Boar Meat", 1, 5, 133970 }, [2681] = { "Roasted Boar Meat", 1, 5, 133974 }, [90021] = { "Sandy Fish Bones", 1, 5, 133970 },
    [6289] = { "Raw Longjaw Mud Snapper", 1, 15, 133918 },
    [264908] = { "Ancient Heirloom", 3, 10, 133345 }, [264120] = { "Windshaper's Circlet", 2, 14, 133071 },
    [264140] = { "Shadowgale Hide Vest", 2, 15, 132719 }, [264160] = { "Staff of the Quiet Wind", 3, 16, 135152 },
    [2591] = { "Patched Wanderer's Cloak", 1, 5, 133762 }, [264154] = { "Somebody Else's Boots", 2, 12, 132539 },
    [14146] = { "Gloves of the Dawnwatch", 3, 24, 132955 }, [2075] = { "Priest's Mace", 2, 20, 133476 },
    [6505] = { "Crescent Staff", 3, 21, 135146 }, [3742] = { "Bow of Plunder", 2, 23, 135490 },
    [2589] = { "Linen Cloth", 1, 5, 132889 }, [2592] = { "Wool Cloth", 1, 15, 132911 }, [765] = { "Silverleaf", 1, 5, 134190 },
    [2447] = { "Peacebloom", 1, 5, 134187 }, [118] = { "Minor Healing Potion", 1, 5, 134829 }, [858] = { "Lesser Healing Potion", 1, 13, 134830 },
    [2318] = { "Light Leather", 1, 10, 134252 }, [2319] = { "Medium Leather", 1, 20, 134251 }, [6948] = { "Hearthstone", 1, 1, 134414 },
    [5498] = { "Small Lustrous Pearl", 2, 20, 134123 }, [4306] = { "Silk Cloth", 1, 25, 132905 },
    -- Thalia's
    [264201] = { "Moonsilk Hood", 2, 22, 133127 }, [264202] = { "Pendant of the Quiet Grove", 2, 21, 133291 },
    [264203] = { "Mantle of Dusk", 2, 20, 135056 }, [264204] = { "Starfall Robe", 3, 24, 132649 },
    [264205] = { "Sash of Whispers", 2, 20, 132498 }, [264206] = { "Dawnwatch Leggings", 2, 21, 134599 },
    [264207] = { "Pilgrim's Slippers", 1, 18, 132560 }, [264208] = { "Band of Elune", 3, 24, 133354 },
    [264209] = { "Moonwell Talisman", 2, 22, 133434 }, [264210] = { "Lantern Orb", 2, 21, 134333 },
    [264211] = { "Wand of the Willow", 2, 20, 135466 },
    -- Brannoc's
    [264220] = { "Ironforge Greathelm", 2, 24, 133069 }, [264221] = { "Ridgeback Pauldrons", 2, 23, 135033 },
    [264222] = { "Thane's Hauberk", 3, 25, 132627 }, [264223] = { "Girdle of the Vale", 2, 22, 132493 },
    [264224] = { "Mountainguard Greaves", 2, 23, 134655 }, [264225] = { "Stoneboot Sabatons", 2, 22, 132585 },
    [264226] = { "Brawler's Gauntlets", 2, 21, 132938 }, [264227] = { "Thunderbrew Blade", 3, 25, 135274 },
    [264228] = { "Kharanos Kite Shield", 2, 23, 134955 }, [264229] = { "Dun Morogh Rifle", 2, 20, 135611 },
    [264230] = { "Signet of the Anvil", 2, 22, 133347 },
    -- Eluned's
    [264240] = { "Huntress's Coif", 2, 22, 133076 }, [264241] = { "Wildvine Shoulderpads", 2, 21, 135033 },
    [264242] = { "Glade Stalker Jerkin", 3, 24, 132627 }, [264243] = { "Fen Runner's Belt", 2, 20, 132498 },
    [264244] = { "Ashenvale Trousers", 2, 22, 134586 }, [264245] = { "Silentstep Boots", 2, 21, 132535 },
    [264246] = { "Moonbeam Bracers", 2, 20, 132606 }, [264247] = { "Thornwood Longbow", 3, 24, 135490 },
    [264248] = { "Hunting Knife", 2, 20, 135641 }, [264249] = { "Cloak of the Long Watch", 2, 21, 133768 },
}
-- Gear as the game describes it: where it's worn, its kind, its stats, the level it needs, and the
-- specs Blizzard's own list says it is for (nil: the list names none for it).
local GEAR = {
    [2075] = { "INVTYPE_WEAPON", "Mace", { ITEM_MOD_INTELLECT_SHORT = 4, ITEM_MOD_STAMINA_SHORT = 2 }, 15, { 257, 65, 264, 105, 102 } },
    [14146] = { "INVTYPE_HAND", "Cloth", { ITEM_MOD_INTELLECT_SHORT = 5, ITEM_MOD_SPIRIT_SHORT = 4 }, 19 },
    [6505] = { "INVTYPE_2HWEAPON", "Staff", { ITEM_MOD_INTELLECT_SHORT = 7, ITEM_MOD_SPIRIT_SHORT = 7, ITEM_MOD_STAMINA_SHORT = 7 }, 16, { 102, 105, 257, 63 } },
    [3742] = { "INVTYPE_RANGED", "Bow", { ITEM_MOD_AGILITY_SHORT = 4 }, 15, { 253, 259 } },
    [264154] = { "INVTYPE_FEET", "Leather", { ITEM_MOD_AGILITY_SHORT = 3, ITEM_MOD_STAMINA_SHORT = 3 }, 10 },
    [264160] = { "INVTYPE_2HWEAPON", "Staff", { ITEM_MOD_INTELLECT_SHORT = 4, ITEM_MOD_STAMINA_SHORT = 3 }, 10, { 102, 105, 257, 63 } },
    [264204] = { "INVTYPE_ROBE", "Cloth", { ITEM_MOD_INTELLECT_SHORT = 8, ITEM_MOD_STAMINA_SHORT = 5 }, 18, { 257, 63 } },
    [264210] = { "INVTYPE_HOLDABLE", "Miscellaneous", { ITEM_MOD_INTELLECT_SHORT = 3 }, 17 },
    [264120] = { "INVTYPE_HEAD", "Leather", { ITEM_MOD_INTELLECT_SHORT = 3 }, 10 },
    [264140] = { "INVTYPE_CHEST", "Leather", { ITEM_MOD_STAMINA_SHORT = 4 }, 10 },
    [264908] = { "INVTYPE_FINGER", "Miscellaneous", { ITEM_MOD_STAMINA_SHORT = 2 }, 1 },
    [2591] = { "INVTYPE_CLOAK", "Cloth", {}, 1 },
    -- A robe nobody has weighed yet.
    [264150] = { "INVTYPE_ROBE", "Cloth", { ITEM_MOD_INTELLECT_SHORT = 6, ITEM_MOD_SPIRIT_SHORT = 5 }, 18, { 257, 63 } },
}
ITEMS[264150] = { "Robe of the Silver Moon", 3, 26, 132649 }
-- Two rings in Thalia's bags: one bound to her (it can't change hands), one spare.
GEAR[264909] = { "INVTYPE_FINGER", "Miscellaneous", { ITEM_MOD_STAMINA_SHORT = 5, ITEM_MOD_INTELLECT_SHORT = 2 }, 10 }
GEAR[264910] = { "INVTYPE_FINGER", "Miscellaneous", { ITEM_MOD_STAMINA_SHORT = 4, ITEM_MOD_INTELLECT_SHORT = 3 }, 10 }
ITEMS[264909] = { "Band of Quiet Vows", 2, 18, 133345 }
ITEMS[4632] = { "Ornate Bronze Lockbox", 1, 20, 132594 }
ITEMS[264910] = { "Spare Moonsilver Band", 2, 19, 133345 }
-- Nobody here has these: the item tests (8g) ask for them.
ITEMS[5523] = { "Small Barnacled Clam", 1, 15, 134432 }
ITEMS[90001] = { "Charm of Two Spells", 2, 20, 133434 }
ITEMS[90002] = { "Circlet of Quiet Rain", 2, 18, 133071 }
ITEMS[2698] = { "Recipe: Cooked Crab Claw", 1, 17, 134939 }
ITEMS[2682] = { "Cooked Crab Claw", 1, 17, 133971 }
ITEMS[2699] = { "Recipe: Lost Stew", 1, 20, 134939 } -- its dish is gone from the game: it never loads
GEAR[90002] = { "INVTYPE_HEAD", "Leather", { ITEM_MOD_INTELLECT_SHORT = 6, ITEM_MOD_STAMINA_SHORT = 3 }, 12 }
-- Crafting (Crafting.lua): what recipes make and use, and recipe items.
for id, it in pairs({
    [2996] = { "Bolt of Linen Cloth", 1, 10, 132890 }, [2320] = { "Coarse Thread", 1, 5, 134479 }, [2568] = { "Brown Linen Vest", 1, 10, 132665 },
    [2569] = { "Linen Boots", 1, 10, 132560 }, [10940] = { "Strange Dust", 1, 10, 132858 }, [6218] = { "Runed Copper Rod", 1, 5, 135157 },
    [6217] = { "Copper Rod", 1, 5, 135225 }, [10938] = { "Lesser Magic Essence", 2, 10, 132867 }, [2304] = { "Light Armor Kit", 1, 10, 133611 },
    [4231] = { "Cured Light Hide", 1, 10, 134369 }, [783] = { "Light Hide", 1, 10, 134366 }, [4289] = { "Salt", 1, 10, 133849 },
    [2302] = { "Handstitched Leather Boots", 1, 8, 132542 }, [5081] = { "Kodo Hide Bag", 1, 13, 133634 }, [2311] = { "White Leather Jerkin", 2, 26, 132717 },
    [5083] = { "Pattern: Kodo Hide Bag", 1, 13, 134939 }, [2407] = { "Pattern: White Leather Jerkin", 2, 26, 134942 },
    [90010] = { "Pattern: Handstitched Leather Boots", 1, 8, 134939 }, [2840] = { "Copper Bar", 1, 10, 133216 }, [2770] = { "Copper Ore", 1, 10, 134566 },
    [2862] = { "Rough Sharpening Stone", 1, 10, 135248 }, [2835] = { "Rough Stone", 1, 10, 135230 }, [2851] = { "Copper Chain Belt", 1, 10, 132492 },
    [3371] = { "Empty Vial", 1, 1, 132793 },
}) do ITEMS[id] = it end
-- Recipes as the game knows them: name, what it makes (nil: an enchantment), what goes into it,
-- its profession and its group in the profession window; and the professions' skill lines.
local CRAFT = {}
CRAFT.recipes = {
    [2330] = { "Minor Healing Potion", 118, { { 2447, 1 }, { 765, 1 }, { 3371, 1 } }, "Alchemy", "Potions" },
    [2332] = { "Lesser Healing Potion", 858, { { 2447, 2 } }, "Alchemy", "Potions" },
    [2963] = { "Bolt of Linen Cloth", 2996, { { 2589, 2 } }, "Tailoring", "Cloth" },
    [2385] = { "Brown Linen Vest", 2568, { { 2996, 1 }, { 2320, 1 } }, "Tailoring", "Armor" },
    [2386] = { "Linen Boots", 2569, { { 2996, 2 }, { 2318, 1 } }, "Tailoring", "Armor" },
    [7418] = { "Enchant Bracer - Minor Health", nil, { { 10940, 1 } }, "Enchanting", "Bracer" },
    [7421] = { "Runed Copper Rod", 6218, { { 6217, 1 }, { 10940, 1 }, { 10938, 1 } }, "Enchanting", "Rods" },
    [2881] = { "Light Armor Kit", 2304, { { 2318, 1 } }, "Leatherworking", "Kits" },
    [3816] = { "Cured Light Hide", 4231, { { 783, 1 }, { 4289, 1 } }, "Leatherworking", "Materials" },
    [2149] = { "Handstitched Leather Boots", 2302, { { 2318, 2 }, { 2320, 1 } }, "Leatherworking", "Armor" },
    [5244] = { "Kodo Hide Bag", 5081, { { 4231, 3 }, { 2320, 1 } }, "Leatherworking", "Bags" },
    [2163] = { "White Leather Jerkin", 2311, { { 2318, 8 }, { 2320, 2 } }, "Leatherworking", "Armor" },
    [2657] = { "Smelt Copper", 2840, { { 2770, 1 } }, "Mining", "Smelting" },
    [2660] = { "Rough Sharpening Stone", 2862, { { 2835, 1 } }, "Blacksmithing", "Weapon Mods" },
    [2663] = { "Copper Chain Belt", 2851, { { 2840, 6 } }, "Blacksmithing", "Armor" },
    [2795] = { "Roasted Boar Meat", 2681, { { 769, 1 } }, "Cooking", "Meat" },
}
-- Trade goods of a kind the game files under one profession (Enum.ItemTradeGoodsSubclass 8:
-- Cooking), and whether the game marks each a crafting reagent.
CRAFT.goods = { [769] = { sub = "Cooking", scls = 8, reagent = true }, [90021] = { sub = "Cooking", scls = 8, reagent = false },
    [6289] = { sub = "Cooking", scls = 8, reagent = true } }
CRAFT.lines = { Alchemy = 171, Tailoring = 197, Enchanting = 333, Leatherworking = 165, Mining = 186, Blacksmithing = 164, Engineering = 202, Cooking = 185 }
CRAFT.groups, CRAFT.groupNames = {}, {}
for _, r in pairs(CRAFT.recipes) do
    if not CRAFT.groups[r[5]] then
        CRAFT.groupNames[#CRAFT.groupNames + 1] = r[5]
        CRAFT.groups[r[5]] = 1000 + #CRAFT.groupNames
    end
end
-- Recipe items: the profession they are for (Enum.ItemRecipeSubclass and its name) and the skill
-- they need.
CRAFT.items = { [5083] = { 1, "Leatherworking", 40 }, [2407] = { 1, "Leatherworking", 125 }, [90010] = { 1, "Leatherworking", 1 } }
-- The rest of each item's tooltip as the game shows it: armor (and a shield's block) or a weapon's
-- damage and speed, durability, its Equip: and Use: lines; and for gear only worn here (no one weighs
-- it), where it's worn, its kind, stats and level. The Crescent Staff's, Priest's Mace's and Bow of
-- Plunder's damage and durability are the game's own; the rest are this world's.
local TIP = {}
do
    local STR, AGI, STA, INT, SPI = "ITEM_MOD_STRENGTH_SHORT", "ITEM_MOD_AGILITY_SHORT", "ITEM_MOD_STAMINA_SHORT", "ITEM_MOD_INTELLECT_SHORT", "ITEM_MOD_SPIRIT_SHORT"
    TIP.LOOK = {
        [6505] = { dmg = { 47, 71, 2.9 }, dur = 90 }, [2075] = { dmg = { 9, 17, 2.0 }, dur = 40 }, [3742] = { dmg = { 20, 39, 2.6 }, dur = 60 },
        [264160] = { dmg = { 25, 38, 2.9 }, dur = 65 }, [14146] = { armor = 18, dur = 25 }, [264154] = { armor = 41, dur = 35 },
        [264120] = { armor = 52, dur = 45 }, [264140] = { armor = 68, dur = 70 }, [2591] = { armor = 8 }, [264204] = { armor = 34, dur = 70 },
        [264150] = { armor = 36, dur = 70 }, [90002] = { armor = 55, dur = 45 },
        [90001] = { loc = "INVTYPE_TRINKET", req = 15, effects = { "Equip: Restores 1 mana per 5 sec.", "Use: Restores 100 mana. (5 Min Cooldown)" } },
        -- A recipe shows the dish it teaches, which the game has to have loaded too.
        [2698] = { teaches = 2682, text = "Use: Teaches you how to cook a Crab Claw.", needs = "Requires Cooking (85)" },
        [2682] = { dish = "Use: Restores 294 health over 21 sec. Must remain seated while eating." },
        [2699] = { teaches = 999998, text = "Use: Teaches you how to cook Lost Stew.", needs = "Requires Cooking (100)" },
        [118] = { effects = { "Use: Restores 70 to 90 health." } }, [858] = { effects = { "Use: Restores 140 to 180 health." }, req = 3 },
        -- Thalia's
        [264201] = { loc = "INVTYPE_HEAD", kind = "Cloth", armor = 28, stats = { [INT] = 6, [SPI] = 5 }, dur = 45, req = 17 },
        [264202] = { loc = "INVTYPE_NECK", stats = { [INT] = 4, [SPI] = 3 }, req = 16 },
        [264203] = { loc = "INVTYPE_SHOULDER", kind = "Cloth", armor = 25, stats = { [STA] = 3, [INT] = 4 }, dur = 40, req = 15 },
        [264205] = { loc = "INVTYPE_WAIST", kind = "Cloth", armor = 15, stats = { [INT] = 3, [SPI] = 3 }, dur = 20, req = 15 },
        [264206] = { loc = "INVTYPE_LEGS", kind = "Cloth", armor = 30, stats = { [STA] = 4, [INT] = 5, [SPI] = 3 }, dur = 55, req = 16 },
        [264207] = { loc = "INVTYPE_FEET", kind = "Cloth", armor = 17, dur = 25, req = 13 },
        [264208] = { loc = "INVTYPE_FINGER", stats = { [INT] = 5, [SPI] = 4 }, req = 19, effects = {
            "Equip: Increases healing done by up to 9 and damage done by up to 3 for all magical spells and effects.", "Equip: Restores 2 mana per 5 sec." } },
        [264209] = { loc = "INVTYPE_TRINKET", req = 17, effects = { "Use: Restores 135 mana. (5 Min Cooldown)" } },
        [264211] = { loc = "INVTYPE_RANGEDRIGHT", kind = "Wand", dmg = { 21, 39, 1.5 }, school = "Shadow", stats = { [INT] = 2 }, dur = 40, req = 15 },
        -- Brannoc's
        [264220] = { loc = "INVTYPE_HEAD", kind = "Mail", armor = 151, stats = { [STR] = 5, [STA] = 6 }, dur = 60, req = 19 },
        [264221] = { loc = "INVTYPE_SHOULDER", kind = "Mail", armor = 130, stats = { [STR] = 4, [STA] = 4 }, dur = 60, req = 18 },
        [264222] = { loc = "INVTYPE_CHEST", kind = "Mail", armor = 196, stats = { [STR] = 7, [STA] = 8 }, dur = 100, req = 20 },
        [264223] = { loc = "INVTYPE_WAIST", kind = "Mail", armor = 101, stats = { [STR] = 3, [STA] = 4 }, dur = 35, req = 17 },
        [264224] = { loc = "INVTYPE_LEGS", kind = "Mail", armor = 172, stats = { [STR] = 5, [STA] = 6 }, dur = 75, req = 18 },
        [264225] = { loc = "INVTYPE_FEET", kind = "Mail", armor = 131, stats = { [STR] = 3, [STA] = 4 }, dur = 50, req = 17 },
        [264226] = { loc = "INVTYPE_HAND", kind = "Mail", armor = 112, stats = { [STR] = 4, [AGI] = 2 }, dur = 35, req = 16 },
        [264227] = { loc = "INVTYPE_WEAPON", kind = "Sword", dmg = { 21, 40, 2.4 }, stats = { [STR] = 3, [STA] = 2 }, dur = 75, req = 20 },
        [264228] = { loc = "INVTYPE_SHIELD", kind = "Shield", armor = 471, block = 9, stats = { [STA] = 3 }, dur = 85, req = 18 },
        [264229] = { loc = "INVTYPE_RANGEDRIGHT", kind = "Gun", dmg = { 15, 29, 2.7 }, stats = { [AGI] = 2 }, dur = 50, req = 15 },
        [264230] = { loc = "INVTYPE_FINGER", stats = { [STR] = 3, [STA] = 3 }, req = 17 },
        -- Eluned's
        [264240] = { loc = "INVTYPE_HEAD", kind = "Leather", armor = 60, stats = { [AGI] = 5, [STA] = 4 }, dur = 50, req = 18 },
        [264241] = { loc = "INVTYPE_SHOULDER", kind = "Leather", armor = 55, stats = { [AGI] = 4, [STA] = 3 }, dur = 50, req = 17 },
        [264242] = { loc = "INVTYPE_CHEST", kind = "Leather", armor = 80, stats = { [AGI] = 7, [STA] = 5 }, dur = 85, req = 19 },
        [264243] = { loc = "INVTYPE_WAIST", kind = "Leather", armor = 37, stats = { [AGI] = 3, [STA] = 2 }, dur = 30, req = 15 },
        [264244] = { loc = "INVTYPE_LEGS", kind = "Leather", armor = 68, stats = { [AGI] = 5, [STA] = 4 }, dur = 65, req = 17 },
        [264245] = { loc = "INVTYPE_FEET", kind = "Leather", armor = 50, stats = { [AGI] = 4, [STA] = 2 }, dur = 40, req = 16 },
        [264246] = { loc = "INVTYPE_WRIST", kind = "Leather", armor = 30, stats = { [AGI] = 3 }, dur = 30, req = 15 },
        [264247] = { loc = "INVTYPE_RANGED", kind = "Bow", dmg = { 23, 43, 2.8 }, stats = { [AGI] = 4 }, dur = 65, req = 19 },
        [264248] = { loc = "INVTYPE_WEAPON", kind = "Dagger", dmg = { 12, 23, 1.8 }, stats = { [AGI] = 2 }, dur = 55, req = 15 },
        [264249] = { loc = "INVTYPE_CLOAK", armor = 20, stats = { [AGI] = 3, [STA] = 2 }, req = 16 },
    }
    -- The tooltip's words and colours, as Forever writes them (its own saved tooltips are the model).
    TIP.SLOT_WORDS = { INVTYPE_WEAPON = "One-Hand", INVTYPE_2HWEAPON = "Two-Hand", INVTYPE_HAND = "Hands", INVTYPE_FEET = "Feet", INVTYPE_RANGED = "Ranged",
        INVTYPE_RANGEDRIGHT = "Ranged", INVTYPE_ROBE = "Chest", INVTYPE_CHEST = "Chest", INVTYPE_HEAD = "Head", INVTYPE_HOLDABLE = "Held In Off-hand",
        INVTYPE_FINGER = "Finger", INVTYPE_CLOAK = "Back", INVTYPE_NECK = "Neck", INVTYPE_SHOULDER = "Shoulder", INVTYPE_WAIST = "Waist",
        INVTYPE_LEGS = "Legs", INVTYPE_WRIST = "Wrist", INVTYPE_TRINKET = "Trinket", INVTYPE_SHIELD = "Off Hand" }
    TIP.STAT_ORDER = { { STR, "Strength" }, { AGI, "Agility" }, { STA, "Stamina" }, { INT, "Intellect" }, { SPI, "Spirit" } }
    local function rgb(h) return { r = tonumber(h:sub(1, 2), 16) / 255, g = tonumber(h:sub(3, 4), 16) / 255, b = tonumber(h:sub(5, 6), 16) / 255 } end
    TIP.QUALITY = { [0] = rgb("9d9d9d"), rgb("ffffff"), rgb("1eff00"), rgb("0070dd"), rgb("a335ee") }
    TIP.WHITE, TIP.GREEN, TIP.RED = rgb("ffffff"), rgb("00ff00"), { r = 1, g = 0.125, b = 0.125 }
end
-- What each class can equip, and each class's spec here: id, name, role, main stat (4 Intellect,
-- 2 Agility, 1 Strength), and which class each spec belongs to.
local CAN = {
    DRUID = { Cloth = true, Leather = true, Mace = true, Staff = true, Dagger = true, Miscellaneous = true },
    PRIEST = { Cloth = true, Mace = true, Staff = true, Dagger = true, Wand = true, Miscellaneous = true },
    MAGE = { Cloth = true, Staff = true, Dagger = true, Sword = true, Wand = true, Miscellaneous = true },
    WARRIOR = { Cloth = true, Leather = true, Mail = true, Mace = true, Sword = true, Axe = true, Dagger = true, Staff = true, Bow = true, Gun = true, Miscellaneous = true },
    HUNTER = { Cloth = true, Leather = true, Bow = true, Gun = true, Axe = true, Sword = true, Dagger = true, Staff = true, Miscellaneous = true },
    ROGUE = { Cloth = true, Leather = true, Dagger = true, Sword = true, Mace = true, Bow = true, Gun = true, Miscellaneous = true },
}
local SPEC = { DRUID = { 102, "Balance", "DAMAGER", 4 }, PRIEST = { 257, "Holy", "HEALER", 4 }, MAGE = { 63, "Fire", "DAMAGER", 4 },
    WARRIOR = { 71, "Arms", "DAMAGER", 1 }, HUNTER = { 253, "Beast Mastery", "DAMAGER", 2 }, ROGUE = { 259, "Assassination", "DAMAGER", 2 } }
local SPEC_CLASS = { [102] = 11, [105] = 11, [257] = 5, [63] = 8, [71] = 1, [253] = 3, [259] = 4, [65] = 2, [264] = 7 }

local function link(id)
    local it = ITEMS[id]
    local colors = { [0] = "ff9d9d9d", "ffffffff", "ff1eff00", "ff0070dd", "ffa335ee" }
    return "|c" .. colors[it[2]] .. "|Hitem:" .. id .. "::::::::20:::::|h[" .. it[1] .. "]|h|r"
end

-- The guild bank on the server: tab name, icon, the lowest rank that may view it, and contents.
local BANK = {
    money = 1287344,
    tabs = {
        { "Reagents", 134190, 5, { [1] = { 765, 20 }, [2] = { 2447, 20 }, [3] = { 765, 7 }, [8] = { 2589, 20 }, [9] = { 2592, 14 }, [15] = { 2318, 20 }, [16] = { 2319, 6 }, [22] = { 6289, 12 } } },
        { "Gear", 132719, 5, { [1] = { 14146, 1 }, [2] = { 2075, 1 }, [3] = { 3742, 1 }, [4] = { 264154, 1 } } },
        { "Officers", 133784, 2, { [1] = { 5498, 3 }, [2] = { 6505, 1 } } },
        { "Potions", 134829, 5, { [1] = { 118, 20 }, [2] = { 858, 12 }, [98] = { 4306, 5 } } },
    },
    perDay = { -1, 10, 4, 2, 1 },   -- stacks a day from a tab, by rank (the guild master: no limit)
    gold = { -1, 100, 20, 5, 0 },   -- gold a day, by rank
    notes = { [1] = "Herbs and cloth for crafters. Take what you need.", [3] = "Officers only: raid rewards.", [4] = "Potions are for raid nights." },
    -- Each tab's log, oldest first: kind, who, item, count, tab, to tab, days ago, hours ago.
    logs = {
        [1] = { { "withdraw", "Saeli", 765, 5, nil, nil, 1, 4 }, { "deposit", "Joan", 2447, 13, nil, nil, 0, 2 } },
        [3] = { { "deposit", "Corvane", 6505, 1, nil, nil, 3, 0 } },
        [4] = { { "deposit", "Orlan", 858, 12, nil, nil, 1, 0 }, { "move", "Corvane", 4306, 5, 4, 1, 0, 6 }, { "withdraw", "Mira", 118, 5, nil, nil, 0, 2 } },
    },
    moneyLog = { { "deposit", "Faelwen", 500000, 2, 0 }, { "repair", "Orlan", 12345, 0, 5 } },
}

local RESULT = { Success = 0, InvalidPrefix = 1, InvalidMessage = 2, AddonMessageThrottle = 3, InvalidChatType = 4, NotInGroup = 5,
    TargetRequired = 6, InvalidChannel = 7, ChannelThrottle = 8, GeneralError = 9, NotInGuild = 10, AddOnMessageLockdown = 11, TargetOffline = 12 }

-- The server's own limit per addon, like the game's: ten at once, then one a second.
local function allowance(c)
    local t = world.clock
    c.bucket = math.min(c.bucketMax, c.bucket + (t - c.bucketAt))
    c.bucketAt = t
    if c.bucket < 1 then return false end
    c.bucket = c.bucket - 1
    return true
end

local function deliver(from, prefix, text, kind, target)
    assert(#text <= 255, "a message longer than 255 characters")
    assert(not text:find("\0", 1, true), "a message with a null character")
    if from.lockdown then return RESULT.AddOnMessageLockdown end
    if not allowance(from) then from.throttled = from.throttled + 1 return RESULT.AddonMessageThrottle end
    from.sent[#from.sent + 1] = { at = world.clock, kind = kind, target = target, text = text }
    local entry = { from = from.full, kind = kind, target = target, text = text, at = world.clock }
    world.log[#world.log + 1] = entry
    if kind == "GUILD" then
        if not from.guild then return RESULT.NotInGuild end
        for _, c in ipairs(world.clients) do
            if c.online and c.guild == from.guild and c.prefixes[prefix] then c.fire("CHAT_MSG_ADDON", prefix, text, "GUILD", from.full, "", 0, 0, from.name, 0) end
        end
        return RESULT.Success
    elseif kind == "WHISPER" then
        local to = world.byName[target]
        if not to or not to.online then return RESULT.TargetOffline end
        if to.faction ~= from.faction then return RESULT.Success end -- whispers don't cross factions; the sender isn't told
        if to.prefixes[prefix] then to.fire("CHAT_MSG_ADDON", prefix, text, "WHISPER", from.full, to.full, 0, 0, from.name, 0) end
        return RESULT.Success
    end
    return RESULT.InvalidChatType
end

---------------------------------------------------------------------------
-- A client
---------------------------------------------------------------------------
-- One session of a client's game: a fresh game with the addon loaded, and its saved data as the
-- last session left it (c.saved). A new session (a relog) ends the timers of the one before.
local function boot(c)
    local opts = c.opts
    local env = setmetatable({}, { __index = _G })
    env._G = env
    local ui = dofile(here .. "wowui.lua")(env)
    c.env, c.ui = env, ui
    c.fire = function(event, ...) ui.fire(event, ...) end
    local function add(name, value) env[name] = value end

    add("print", function(...) local t = {} for i = 1, select("#", ...) do t[i] = tostring((select(i, ...))) end c.printed[#c.printed + 1] = table.concat(t, " ") end)
    -- This computer's clock (off by c.skew seconds when it's set wrong) and the game's server clock.
    add("time", function() return floor(world.clock) + (c.skew or 0) end)
    add("date", function(fmt, t) return os.date(fmt, floor(t or world.clock + (c.skew or 0))) end) -- as the game's: the time asked about, else now
    add("GetServerTime", function() return floor(world.clock) end)
    add("GetTime", function() return world.clock end)
    add("wipe", function(t) for k in pairs(t) do t[k] = nil end return t end)
    add("unpack", unpack)
    add("SlashCmdList", {})
    local session = c.session
    add("C_Timer", {
        After = function(sec, fn) world.timers[#world.timers + 1] = { at = world.clock + sec, fn = function() if c.session == session then fn() end end } end,
        NewTicker = function(sec, fn)
            local function again()
                if c.session ~= session then return end
                fn()
                world.timers[#world.timers + 1] = { at = world.clock + sec, fn = again }
            end
            world.timers[#world.timers + 1] = { at = world.clock + sec, fn = again }
        end,
    })
    -- The game's own later: what this session of the game does in a moment (nothing once it ends).
    local function later(sec, fn) world.timers[#world.timers + 1] = { at = world.clock + sec, fn = function() if c.session == session then fn() end end } end
    local loading = {} -- items the game is fetching for this session
    add("RETRIEVING_ITEM_INFO", "Retrieving item information")
    add("Enum", {
        PowerType = { Mana = 0 }, CompressionMethod = { Deflate = 0 }, SendAddonMessageResult = RESULT,
        PlayerInteractionType = { Banker = 8, GuildBanker = 10 }, BagIndex = { Backpack = 0 }, TooltipDataType = { Item = 0 },
    })
    -- The game's tooltip post-calls: what each addon asks to run after the game fills a tooltip in.
    c.postCalls = {}
    add("TooltipDataProcessor", { AddTooltipPostCall = function(kind, fn) c.postCalls[#c.postCalls + 1] = { kind = kind, fn = fn } end })
    add("C_EncodingUtil", dofile(here .. "encoding.lua"))
    add("C_AddOns", { GetAddOnMetadata = function(name, field) return name == "Reliquary" and field == "Version" and c.version or nil end })
    -- Who this is.
    add("InCombatLockdown", function() return c.combat end)
    add("UnitAffectingCombat", function() return c.combat end)
    add("IsInInstance", function() return c.inInstance, c.inInstance and "party" or "none" end)
    -- On Forever the second value is the family name; elsewhere the realm, nil on your own realm.
    add("RegionalUniqueNamesEnabled", function() return REGIONAL end)
    add("UnitName", function(unit)
        if unit == "player" then return c.name, REGIONAL and c.surname or nil end
        if unit == "target" and c.target then return c.target.name, REGIONAL and SURNAMES[c.target.name] or nil end
    end)
    add("GetRealmName", function() return REALM end)
    add("GetNormalizedRealmName", function() return REALM end)
    add("UnitRace", function() return opts.race, opts.raceFile end)
    add("UnitClass", function() return CLASS_NAMES[CLASS_IDS[opts.class]], opts.class, CLASS_IDS[opts.class] end)
    -- Specs, and what the game says about gear (Upgrades.lua).
    add("ITEM_MIN_LEVEL", "Requires Level %d")
    add("ITEM_MIN_SKILL", "Requires %s (%d)")
    add("LOOT_ITEM_SELF", "You receive loot: %s.")
    add("LOOT_ITEM_SELF_MULTIPLE", "You receive loot: %sx%d.")
    add("LOOT_ITEM_PUSHED_SELF", "You receive item: %s.")
    add("LOOT_ITEM_CREATED_SELF", "You create: %s.")
    add("CanDualWield", function() return false end)
    add("GetSpecialization", function() return SPEC[opts.class] and 1 or nil end)
    add("GetSpecializationInfo", function() local sp = SPEC[opts.class] if sp then return sp[1], sp[2], "", 0, sp[3], sp[4] end end)
    local function idOf(x) return type(x) == "number" and x or tonumber(tostring(x):match("item:(%d+)")) end
    local function statsOf(id) local out = {} for k, v in pairs(GEAR[id] and GEAR[id][3] or {}) do out[k] = v end return out end
    add("C_Item", {
        GetItemInfoInstant = function(x)
            local id = idOf(x)
            local g = id and GEAR[id]
            local ri = id and CRAFT.items[id]
            if ri then return id, "Recipe", ri[2], "", ITEMS[id][4], 9, ri[1] end
            local tg = id and CRAFT.goods[id]
            if tg then return id, "Trade Goods", tg.sub, "", ITEMS[id][4], 7, tg.scls end
            if id and ITEMS[id] then return id, g and "Armor" or "Trade Goods", g and g[2] or "Misc", g and g[1] or "", ITEMS[id][4], 4, 0 end
        end,
        GetDetailedItemLevelInfo = function(x) local id = idOf(x) return id and ITEMS[id] and ITEMS[id][3] or nil end,
        GetItemStats = function(x) local id = idOf(x) return id and ITEMS[id] and statsOf(id) or nil end,
        GetItemStatDelta = function(a, b)
            local sa, sb, out = statsOf(idOf(a)), statsOf(idOf(b)), {}
            for k, v in pairs(sa) do out[k] = v - (sb[k] or 0) end
            for k, v in pairs(sb) do if sa[k] == nil then out[k] = -v end end
            return out
        end,
        GetItemSpecInfo = function(x) local g = GEAR[idOf(x)] return g and g[5] and { unpack(g[5]) } or {} end,
        -- The item cache (the rest of this world's item functions answer whether or not it's loaded).
        IsItemDataCachedByID = function(x) local id = idOf(x) return id ~= nil and c.itemCache[id] == true end,
        RequestLoadItemDataByID = function(x)
            local id = idOf(x)
            if not id or c.itemCache[id] or loading[id] then return end
            loading[id] = true
            c.loadRequests = c.loadRequests + 1
            later(0.4, function()
                loading[id] = nil
                if ITEMS[id] then c.itemCache[id] = true end
                c.fire("ITEM_DATA_LOAD_RESULT", id, ITEMS[id] ~= nil)
            end)
        end,
        -- As the game's: an item its list names no specs for counts as anyone's.
        DoesItemContainSpec = function(x, classID, specID)
            local g = GEAR[idOf(x)]
            if not (g and g[5]) then return true end
            for _, sp in ipairs(g[5]) do if sp == specID and SPEC_CLASS[sp] == classID then return true end end
            return false
        end,
    })
    c.dressedUp, c.chatLinked = {}, {}
    add("DressUpItemLink", function(l) c.dressedUp[#c.dressedUp + 1] = l end)
    add("UnitSex", function() return opts.sex or 3 end)
    add("UnitFactionGroup", function(unit)
        if unit == "player" then return c.faction, c.faction end
        if unit == "npc" and c.npc then return c.npc.faction, c.npc.faction end
        if unit == "target" and c.target then return c.target.faction, c.target.faction end
    end)
    add("UnitLevel", function() return c.level end)
    add("UnitIsPlayer", function(unit) return unit == "target" and c.target ~= nil end)
    add("UnitIsUnit", function(a, b) return a == b end)
    add("GetGuildInfo", function(unit)
        if unit == "player" and c.guild then return GUILD.name, GUILD.ranks[c.rank], c.rank - 1, nil end
    end)
    add("IsInGuild", function() return c.guild ~= nil end)
    add("GetGuildRosterMOTD", function() return c.guild and GUILD.motd or "" end)
    add("GetClassInfo", function(id) return CLASS_NAMES[id], CLASS_FILES[id], id end)
    -- The guild list: Reliquary players and the rest.
    local function roster()
        local out = {}
        if not c.guild then return out end
        for _, other in ipairs(world.clients) do
            if other.guild == c.guild and not other.leftGuild then
                out[#out + 1] = { name = REGIONAL and other.full or other.name, given = other.name, rank = other.rank, level = other.level,
                    classID = CLASS_IDS[other.class], zone = other.zone, online = other.online, isSelf = other == c, p1 = other.prof1 }
            end
        end
        for _, m in ipairs(GUILD.others) do
            out[#out + 1] = { name = REGIONAL and (m[1] .. " " .. m[6]) or m[1], given = m[1], level = m[2], classID = m[3], rank = m[4], zone = m[5],
                online = m[5] ~= nil, offlineDays = m[5] and nil or (m[2] % 7) + 1 }
        end
        return out
    end
    -- The guild's chat as Communities streams (world.history): the game downloads a batch at a time,
    -- and has what it saw while online.
    local function have(stream) c.club[stream] = c.club[stream] or {} return c.club[stream] end
    local function ranges(stream)
        local h, r = world.history[stream], have(stream)
        if not (h and r.lo and r.hi and r.lo <= r.hi) then return {} end
        return { { oldestMessageId = h[r.lo].messageId, newestMessageId = h[r.hi].messageId } }
    end
    add("C_Club", {
        -- The guild's streams; its officer chat's only for a rank that may read it, as the game lists them.
        GetStreams = function(id)
            if not (c.guild and id == 77) then return {} end
            local out = { { streamId = "1", streamType = 1, name = "Guild" } }
            if world.officer(c) then out[#out + 1] = { streamId = "2", streamType = 2, name = "Officer" } end
            out[#out + 1] = { streamId = "3", streamType = 3, name = "Discord" }
            return out
        end,
        GetMessageRanges = function(_, stream) return ranges(stream) end,
        GetMessagesInRange = function(_, stream, oldest, newest)
            local out = {}
            for _, m in ipairs(world.history[stream] or {}) do
                if m.messageId.epoch >= oldest.epoch and m.messageId.epoch <= newest.epoch then out[#out + 1] = m end
            end
            return out
        end,
        RequestMoreMessagesBefore = function(_, stream, messageId, count)
            local h, r = world.history[stream] or {}, have(stream)
            c.historyAsks = (c.historyAsks or 0) + 1
            local before = #h + 1
            if messageId then for i, m in ipairs(h) do if m.messageId.epoch == messageId.epoch then before = i break end end end
            local lo, hi = math.max(1, before - (count or 100)), before - 1
            if hi < lo then return true end
            local wasLo, wasHi = r.lo, r.hi
            r.lo, r.hi = math.min(r.lo or lo, lo), math.max(r.hi or hi, hi)
            if r.lo == wasLo and r.hi == wasHi then return true end
            env.C_Timer.After(0.3, function() c.fire("CLUB_MESSAGE_HISTORY_RECEIVED", 77, stream) end)
            return false
        end,
        GetGuildClubId = function() return c.guild and 77 or nil end,
        GetClubMembers = function(id) local ids = {} for i in ipairs(roster()) do ids[i] = i end return ids end,
        GetMemberInfo = function(id, memberId)
            local m = roster()[memberId]
            if not m then return nil end
            return { name = m.name, guildRank = GUILD.ranks[m.rank], guildRankOrder = m.rank, level = m.level, classID = m.classID, zone = m.zone,
                presence = m.online and 1 or 3, lastOnlineDay = m.offlineDays, lastOnlineHour = m.offlineDays and 3 or nil,
                isSelf = m.isSelf, memberNote = m.given == "Thalia" and "Herbalist, ask for silverleaf" or nil,
                officerNote = "never read", profession1Name = m.p1 and m.p1[1], profession1Rank = m.p1 and m.p1[2] }
        end,
    })
    add("C_GuildInfo", {
        GuildRoster = function() if c.guild then env.C_Timer.After(0.5, function() c.fire("GUILD_ROSTER_UPDATE") end) end end,
        IsGuildOfficer = function() return world.officer(c) and true or false end,
        MemberExistsByName = function(name)
            for _, m in ipairs(roster()) do if m.name == name or (not REGIONAL and m.name .. "-" .. REALM == name) then return true end end
            return false
        end,
    })
    -- The guild bank, as this character's rank sees it.
    local function viewable(tab) return c.guild and BANK.tabs[tab] and c.rank <= BANK.tabs[tab][3] end
    add("C_GuildBank", { IsGuildBankEnabled = function() return true end })
    add("GetNumGuildBankTabs", function() return c.bankOpen and #BANK.tabs or 0 end)
    add("GetGuildBankTabInfo", function(tab)
        local t = c.bankOpen and BANK.tabs[tab]
        local perDay = viewable(tab) and BANK.perDay[c.rank] or 0
        if t then return t[1], t[2], viewable(tab), viewable(tab), perDay, perDay, false end
    end)
    add("MAX_GUILDBANK_TABS", 8)
    add("GetGuildBankWithdrawMoney", function() return c.bankOpen and (BANK.gold[c.rank] or 0) * 10000 or 0 end)
    -- Each tab's log, the gold log and each tab's note, sent a moment after they are asked for.
    local function who(name) return REGIONAL and fullOf(name) or name end
    add("QueryGuildBankLog", function(tab)
        c.logsQueried = (c.logsQueried or 0) + 1
        if tab == 9 or viewable(tab) then env.C_Timer.After(0.3, function() c.logLoaded = tab c.fire("GUILDBANKLOG_UPDATE") end) end
    end)
    add("GetNumGuildBankTransactions", function(tab) return c.bankOpen and c.logLoaded == tab and viewable(tab) and #(BANK.logs[tab] or {}) or 0 end)
    add("GetGuildBankTransaction", function(tab, i)
        local e = c.bankOpen and viewable(tab) and BANK.logs[tab] and BANK.logs[tab][i]
        if e then return e[1], who(e[2]), link(e[3]), e[4], e[5], e[6], 0, 0, e[7], e[8] end
    end)
    add("GetNumGuildBankMoneyTransactions", function() return c.bankOpen and c.logLoaded == 9 and #BANK.moneyLog or 0 end)
    add("GetGuildBankMoneyTransaction", function(i)
        local e = c.bankOpen and BANK.moneyLog[i]
        if e then return e[1], who(e[2]), e[3], 0, 0, e[4], e[5] end
    end)
    add("QueryGuildBankText", function(tab) if viewable(tab) then env.C_Timer.After(0.3, function() c.fire("GUILDBANK_UPDATE_TEXT", tab) end) end end)
    add("GetGuildBankText", function(tab) return c.bankOpen and viewable(tab) and BANK.notes[tab] or nil end)
    -- Guild Control: only the guild master reads every rank's permissions.
    add("IsGuildLeader", function() return c.guild ~= nil and c.rank == 1 end)
    add("GuildControlGetNumRanks", function() return c.guild and #GUILD.ranks or 0 end)
    add("GuildControlGetRankName", function(r) return GUILD.ranks[r] end)
    add("GuildControlSetRank", function(r) assert(c.rank == 1, "only the guild master opens Guild Control") c.gcRank = r end)
    add("GetGuildBankTabPermissions", function(tab)
        local t, r = BANK.tabs[tab], c.gcRank or 1
        local v = t and r <= t[3] or false
        return v, v, false, v and BANK.perDay[r] or 0
    end)
    add("GetGuildBankWithdrawGoldLimit", function() return BANK.gold[c.gcRank or 1] or 0 end)
    add("QueryGuildBankTab", function(tab)
        c.queried = (c.queried or 0) + 1
        if viewable(tab) then env.C_Timer.After(0.3, function() c.bankLoaded[tab] = true c.fire("GUILDBANKBAGSLOTS_CHANGED") end) end
    end)
    add("GetCurrentGuildBankTab", function() return 1 end)
    add("GetGuildBankItemInfo", function(tab, slot)
        local e = c.bankOpen and c.bankLoaded[tab] and viewable(tab) and BANK.tabs[tab][4][slot]
        if e then return ITEMS[e[1]][4], e[2], false, false, ITEMS[e[1]][2] end
    end)
    add("GetGuildBankItemLink", function(tab, slot)
        local e = c.bankOpen and c.bankLoaded[tab] and viewable(tab) and BANK.tabs[tab][4][slot]
        return e and link(e[1]) or nil
    end)
    add("GetGuildBankMoney", function() return c.bankOpen and BANK.money or 0 end)
    -- Friends.
    add("BNET_CLIENT_WOW", "WoW")
    add("WOW_PROJECT_ID", 21)
    add("BNGetNumFriends", function() return #(opts.bnFriends or {}), #(opts.bnFriends or {}) end)
    add("C_BattleNet", {
        GetFriendNumGameAccounts = function(i) return opts.bnFriends[i] and 1 or 0 end,
        GetFriendGameAccountInfo = function(i)
            local other = world.byName[fullOf(opts.bnFriends[i])]
            return { gameAccountID = other.account, clientProgram = "WoW", isOnline = other.online, wowProjectID = 21,
                characterName = REGIONAL and other.full or other.name, realmName = "CAMWOW US2 Realm 11 RP" }
        end,
        GetGameAccountInfoByID = function(id)
            local other = world.byAccount[id]
            return other and { gameAccountID = id, characterName = REGIONAL and other.full or other.name, realmName = "CAMWOW US2 Realm 11 RP", isOnline = other.online }
        end,
        -- A Battle.net account as the game describes it (world.bnAccount: its BattleTag and what it's playing).
        GetFriendAccountInfo = function(i)
            local other = opts.bnFriends[i] and world.byName[fullOf(opts.bnFriends[i])]
            return other and world.bnAccount(other, opts.bnNotes and opts.bnNotes[opts.bnFriends[i]])
        end,
        GetAccountInfoByID = function(id)
            local other = world.byAccount[id]
            return other and world.bnAccount(other)
        end,
        -- A Battle.net whisper reaches a Battle.net friend online anywhere, and comes back to its sender as sent.
        SendWhisper = function(id, text)
            assert(type(id) == "number" and type(text) == "string", "a Battle.net whisper without a friend or words")
            local to = world.byAccount[id]
            local isFriend = false
            for _, n in ipairs(opts.bnFriends or {}) do if world.byName[fullOf(n)] == to then isFriend = true end end
            if not (to and isFriend and to.online) then return false end
            c.chatSent[#c.chatSent + 1] = { text = text, kind = "BN_WHISPER", target = id }
            world.lineID = world.lineID + 1
            to.fire("CHAT_MSG_BN_WHISPER", text, "|Kq" .. c.account .. "|k", "", "", "", "", 0, 0, "", 0, world.lineID, "", c.account, false, false, false, false, { userID = 0 })
            c.fire("CHAT_MSG_BN_WHISPER_INFORM", text, "|Kq" .. id .. "|k", "", "", "", "", 0, 0, "", 0, world.lineID, "", id, false, false, false, false, { userID = 0 })
            return true
        end,
        SendGameData = function(id, prefix, text)
            assert(#text <= 255, "a Battle.net message longer than 255 characters")
            if c.lockdown then return RESULT.AddOnMessageLockdown end
            if not allowance(c) then c.throttled = c.throttled + 1 return RESULT.AddonMessageThrottle end
            c.sent[#c.sent + 1] = { at = world.clock, kind = "BN", target = id, text = text }
            local to = world.byAccount[id]
            local isFriend = false
            for _, n in ipairs(opts.bnFriends or {}) do if world.byName[fullOf(n)] == to then isFriend = true end end
            assert(isFriend, "Battle.net data sent to someone who isn't a Battle.net friend")
            if to and to.online and to.prefixes[prefix] then to.fire("BN_CHAT_MSG_ADDON", prefix, text, "WHISPER", c.account) end
            return RESULT.Success
        end,
    })
    add("C_FriendList", {
        GetNumFriends = function() return #(opts.friends or {}) end,
        GetFriendInfoByIndex = function(i)
            local other = world.byName[fullOf(opts.friends[i])]
            return { name = REGIONAL and other.full or other.name, connected = other.online, level = other.level, className = CLASS_NAMES[CLASS_IDS[other.class]],
                guid = other.env.UnitGUID("player"), area = other.online and other.zone or nil, notes = opts.friendNotes and opts.friendNotes[opts.friends[i]] or nil,
                dnd = false, afk = false, rafLinkType = 0 }
        end,
        GetFriendInfo = function(name)
            for _, n in ipairs(opts.friends or {}) do if fullOf(n) == name or (not REGIONAL and n == name) then return { name = n } end end
        end,
        IsIgnored = function(name) return c.ignores[name] == true end,
        -- Asked for news of the friends list, the game answers a moment later.
        ShowFriends = function() c.friendsAsked = (c.friendsAsked or 0) + 1 env.C_Timer.After(0.2, function() c.fire("FRIENDLIST_UPDATE") end) end,
    })
    -- Total RP 3, for those who have it, with the public functions Reliquary calls: asked for a
    -- player, it fetches their profile a moment later if they have one and are online, keeps it, and
    -- says so to whoever listens, as Total RP 3 does (RegisterExchange.lua).
    if opts.trp3 then
        c.trpQueries, c.trpKnown, c.trpCallbacks = {}, opts.trpKnown or {}, {}
        add("TRP3_Addon", { Events = { REGISTER_DATA_UPDATED = "REGISTER_DATA_UPDATED" } })
        add("TRP3_API", {
            RegisterCallback = function(registry, event, fn)
                assert(registry == env.TRP3_Addon and event == "REGISTER_DATA_UPDATED", "an unknown Total RP 3 callback")
                c.trpCallbacks[#c.trpCallbacks + 1] = fn
            end,
            r = { sendQuery = function(id)
                assert(type(id) == "string", "Total RP 3 asked for a player without a name")
                c.trpQueries[#c.trpQueries + 1] = id
                local other, prof = world.byName[id], world.trpProfiles[id]
                if other and other.online and prof then
                    env.C_Timer.After(2, function()
                        c.trpKnown[id] = prof
                        for _, fn in ipairs(c.trpCallbacks) do fn(env.TRP3_Addon, id, "P" .. id, "characteristics") end
                    end)
                end
            end },
            register = { getUnitIDCurrentProfileSafe = function(id) return c.trpKnown[id] or {} end },
            slash = { openProfile = function(...) c.trpOpened = table.concat({ ... }, " ") end },
        })
    end
    add("C_ChatInfo", {
        RegisterAddonMessagePrefix = function(prefix) c.prefixes[prefix] = true return 0 end,
        SendAddonMessage = function(prefix, text, kind, target) return deliver(c, prefix, text, kind, target) end,
        InChatMessagingLockdown = function() return c.lockdown end,
        -- The game's chat (world.say): what this game sends, and lines the game hides.
        SendChatMessage = function(text, chatType, _, target)
            c.chatSent[#c.chatSent + 1] = { text = text, kind = chatType, target = target }
            world.say(c, text, chatType, target)
        end,
        IsChatLineCensored = function(lineID) return world.censored[lineID] == true end,
    })
    -- The colours the player's chat window gives each kind of line, and the game's marks for what a
    -- Discord line has that its chat can't show (ChatFrameUtil.FormatDiscordMessage).
    add("ChatTypeInfo", { GUILD = { r = 0.25, g = 1, b = 0.25 }, GUILD_ACHIEVEMENT = { r = 0.25, g = 1, b = 0.25 }, GUILD_DISCORD = { r = 114 / 255, g = 126 / 255, b = 1 },
        OFFICER = { r = 64 / 255, g = 192 / 255, b = 64 / 255 }, WHISPER = { r = 1, g = 0.5, b = 1 }, WHISPER_INFORM = { r = 1, g = 0.5, b = 1 },
        BN_WHISPER = { r = 0, g = 1, b = 246 / 255 }, BN_WHISPER_INFORM = { r = 0, g = 1, b = 246 / 255 } })
    add("ChatFrameUtil", { FormatDiscordMessage = function(info, message)
        if not (info and info.fromDiscord) then return message end
        if info.hasAttachment then message = "|cffffff00[Attachment]|r " .. message end
        if info.hasPoll then message = "|cffffff00[Poll]|r " .. message end
        return message
    end })
    add("GetPlayerInfoByGUID", function(guid)
        for _, o in ipairs(world.clients) do
            if o.env and o.env.UnitGUID("player") == guid then return CLASS_NAMES[CLASS_IDS[o.class]], o.class, o.opts.race, o.opts.raceFile, 3, o.name, REALM end
        end
    end)
    add("C_CreatureInfo", { GetClassInfo = function(id) return CLASS_FILES[id] and { className = CLASS_NAMES[id], classFile = CLASS_FILES[id], classID = id } end })
    -- Gear, professions, talents, stats.
    add("GetInventoryItemID", function(_, slot) return opts.gear[slot] end)
    add("GetInventoryItemLink", function(_, slot) return opts.gear[slot] and link(opts.gear[slot]) end)
    -- The game's item lookup as Forever has it: in C_Item only (it has no bare GetItemInfo).
    env.C_Item.GetItemInfo = function(x)
        local id = type(x) == "number" and x or tonumber(tostring(x):match("item:(%d+)"))
        local it = ITEMS[id]
        local g = id and GEAR[id]
        local ri = id and CRAFT.items[id]
        if ri then return it[1], link(id), it[2], it[3], 1, "Recipe", ri[2], 1, "", it[4], 10, 9, ri[1], 1 end
        local tg = id and CRAFT.goods[id]
        if tg then return it[1], link(id), it[2], it[3], 1, "Trade Goods", tg.sub, 20, "", it[4], 10, 7, tg.scls, 0, 0, nil, tg.reagent end
        if it then return it[1], link(id), it[2], it[3], g and g[4] or 1, g and "Armor" or "Trade Goods", g and g[2] or "Misc", g and 1 or 20, g and g[1] or "", it[4], 10, 4, 0, g and 2 or 0 end
    end
    -- An item's tooltip as this character's game writes it: what it can't use in red. Each Equip: or
    -- Use: line waits for its spell the first time, one after another: the game fills each in a
    -- moment later and says so (TOOLTIP_DATA_UPDATE, for each tooltip it gave out without it).
    local instance, spellWait = 0, {}
    local function itemLines(id, worn)
        local it, g, look = ITEMS[id], GEAR[id], TIP.LOOK[id] or {}
        local lines = { { leftText = it[1], leftColor = TIP.QUALITY[it[2]] or TIP.WHITE } }
        if look.teaches then
            -- The dish, as its own tooltip shows it; until the game has it, the line it shows instead
            -- (and the game fetches it, saying nothing to the tooltip when it comes).
            local dish = look.teaches
            if c.itemCache[dish] then
                lines[#lines + 1] = { leftText = ITEMS[dish][1], leftColor = TIP.QUALITY[ITEMS[dish][2]] or TIP.WHITE }
                lines[#lines + 1] = { leftText = TIP.LOOK[dish].dish, leftColor = TIP.GREEN }
            else
                lines[#lines + 1] = { leftText = "Retrieving item information", leftColor = TIP.RED }
                if not loading[dish] then
                    loading[dish] = true
                    later(0.4, function()
                        loading[dish] = nil
                        if ITEMS[dish] then c.itemCache[dish] = true end
                        c.fire("GET_ITEM_INFO_RECEIVED", dish, ITEMS[dish] ~= nil)
                    end)
                end
            end
            lines[#lines + 1] = { leftText = look.text, leftColor = TIP.WHITE }
            lines[#lines + 1] = { leftText = look.needs, leftColor = TIP.RED }
            return lines
        end
        local loc, kind = g and g[1] or look.loc, g and g[2] or look.kind
        local stats, req = g and g[3] or look.stats or {}, g and g[4] or look.req
        if loc then
            if it[2] >= 2 then lines[#lines + 1] = { leftText = worn and "Soulbound" or "Binds when equipped", leftColor = TIP.WHITE } end
            -- Rings, necks, trinkets, held items and cloaks name no kind.
            local named = kind and kind ~= "Miscellaneous" and loc ~= "INVTYPE_CLOAK" and kind or nil
            lines[#lines + 1] = { leftText = TIP.SLOT_WORDS[loc] or loc, leftColor = TIP.WHITE, rightText = named,
                rightColor = named and ((CAN[opts.class] or {})[kind] and TIP.WHITE or TIP.RED) or nil }
        end
        if look.armor then lines[#lines + 1] = { leftText = look.armor .. " Armor", leftColor = TIP.WHITE } end
        if look.block then lines[#lines + 1] = { leftText = look.block .. " Block", leftColor = TIP.WHITE } end
        if look.dmg then
            local lo, hi, speed = look.dmg[1], look.dmg[2], look.dmg[3]
            lines[#lines + 1] = { leftText = ("%d - %d %sDamage"):format(lo, hi, look.school and (look.school .. " ") or ""), leftColor = TIP.WHITE,
                rightText = ("Speed %.2f"):format(speed), rightColor = TIP.WHITE }
            lines[#lines + 1] = { leftText = ("(%.1f damage per second)"):format((lo + hi) / 2 / speed), leftColor = TIP.WHITE }
        end
        for _, st in ipairs(TIP.STAT_ORDER) do
            if stats[st[1]] then lines[#lines + 1] = { leftText = ("+%d %s"):format(stats[st[1]], st[2]), leftColor = TIP.WHITE } end
        end
        local effects = {}
        for i = 1, math.min(c.spellCache[id] or 0, #(look.effects or {})) do effects[i] = { leftText = look.effects[i], leftColor = TIP.GREEN } end
        local need = req and req > 1 and { leftText = "Requires Level " .. req, leftColor = c.level < req and TIP.RED or TIP.WHITE } or nil
        if loc then
            -- Gear: its effects, then durability and the level it needs.
            for _, e in ipairs(effects) do lines[#lines + 1] = e end
            if look.dur then lines[#lines + 1] = { leftText = ("Durability %d / %d"):format(look.dur, look.dur), leftColor = TIP.WHITE } end
            if need then lines[#lines + 1] = need end
        else
            if need then lines[#lines + 1] = need end
            for _, e in ipairs(effects) do lines[#lines + 1] = e end
        end
        local ri = CRAFT.items[id]
        if ri then lines[#lines + 1] = { leftText = ("Requires %s (%d)"):format(ri[2], ri[3]), leftColor = TIP.WHITE } end
        return lines
    end
    local function tooltipOf(id, worn)
        instance = instance + 1
        c.tooltipReads[id] = (c.tooltipReads[id] or 0) + 1
        if not c.itemCache[id] then
            return { lines = { { leftText = "Retrieving item information", leftColor = TIP.RED } }, dataInstanceID = instance }
        end
        local effects = TIP.LOOK[id] and TIP.LOOK[id].effects
        if effects and (c.spellCache[id] or 0) < #effects then
            local waiting = spellWait[id]
            if not waiting then
                waiting = {}
                spellWait[id] = waiting
                later(0.3, function()
                    spellWait[id], c.spellCache[id] = nil, (c.spellCache[id] or 0) + 1
                    for _, inst in ipairs(waiting) do c.fire("TOOLTIP_DATA_UPDATE", inst) end
                end)
            end
            waiting[#waiting + 1] = instance
        end
        return { lines = itemLines(id, worn), dataInstanceID = instance }
    end
    add("C_TooltipInfo", {
        GetInventoryItem = function(_, slot) local id = opts.gear[slot] return id and ITEMS[id] and tooltipOf(id, true) end,
        GetHyperlink = function(l)
            local id = tonumber(l:match("item:(%d+)"))
            return id and ITEMS[id] and tooltipOf(id) or nil
        end,
        GetGuildBankItem = function(tab, slot) local e = BANK.tabs[tab][4][slot] return e and env.C_TooltipInfo.GetHyperlink(link(e[1])) end,
        GetItemByID = function(id) return ITEMS[id] and tooltipOf(id) or nil end,
    })
    -- The game's five slots: two professions, then archaeology, fishing and cooking (a third
    -- profession here sits in the cooking slot).
    add("GetProfessions", function() return 1, 2, nil, nil, (opts.profs or {})[3] and 3 or nil end)
    add("GetProfessionInfo", function(i)
        local p = (opts.profs or {})[i]
        if p then return p[1], p[2], p[3], p[4] or 75, 0, 0, 100 + i, 0 end
    end)
    add("UnitStat", function(_, i) return 30 + i, 30 + i + (c.level - 20), c.level - 20, 0 end)
    add("UnitArmor", function() return 300, 300 end)
    add("UnitHealthMax", function() return c.level * 18 end)
    add("UnitHealth", function() return c.level * 18 end)
    add("UnitPowerMax", function() return c.level * 21 end)
    add("UnitPower", function() return c.level * 21 end)
    add("UnitPowerType", function() return 0, "MANA" end)
    add("GetCritChance", function() return 5.1 end)
    add("GetAverageItemLevel", function() return opts.ilvl, opts.ilvl end)
    add("C_Traits", opts.talents and {
        GetConfigsByType = function(kind) return kind == 4 and { 901 } or {} end,
        GetConfigInfo = function() return { treeIDs = { 801 } } end,
        GetTreeNodes = function() local ids = {} for i in ipairs(opts.talents) do ids[i] = 10000 + i end return ids end,
        GetNodeInfo = function(_, id)
            local t = opts.talents[id - 10000]
            return { ID = id, posX = t[2], posY = t[3], currentRank = t[4], maxRanks = t[5], entryIDs = { id * 10 }, isVisible = true }
        end,
        GetEntryInfo = function(_, entry) return { definitionID = entry } end,
        GetDefinitionInfo = function(def) return { spellID = def } end,
        GetTreeCurrencyInfo = function() return { { quantity = 1, spent = 5 } } end,
    } or nil)
    add("C_Spell", {
        GetSpellInfo = function(spellID) local t = opts.talents and opts.talents[spellID / 10 - 10000] return t and { name = t[1], iconID = t[6] or 136096 } end,
        GetSpellDescription = function() return "A talent." end,
        GetSpellName = function(spellID)
            local r = CRAFT.recipes[spellID] or (world.bigRecipes or {})[spellID]
            if r then return r[1] end
            local t = opts.talents and opts.talents[spellID / 10 - 10000]
            return t and t[1]
        end,
        GetSpellTexture = function(spellID) local r = CRAFT.recipes[spellID] return r and (r[2] and ITEMS[r[2]] and ITEMS[r[2]][4] or 136244) end,
    })
    add("GetRealZoneText", function() return c.zone or "Darkshore" end)
    add("GetSubZoneText", function() return c.subzone or "Auberdine" end)
    add("GetMinimapZoneText", function() return "Auberdine" end)
    add("GetBuildInfo", function() return "1.60.1", "70862", "Nov 3 2026", 16001 end)
    add("GetMaxPlayerLevel", function() return 60 end)
    add("GetMoney", function() return 4242 end)
    add("UnitXP", function() return 100 end)
    add("UnitXPMax", function() return 1000 end)
    add("UnitAttackPower", function() return 40, 0, 0 end)
    add("UnitResistance", function() return 0, 0 end)
    add("UIParent", { IsShown = function() return true end, GetWidth = function() return 1920 end, GetHeight = function() return 1080 end })
    -- The minimap, 198 across, where the game's own layout has it (Edit Mode's default, flush in the
    -- top right corner): its centre 107.5 in from the screen's right edge and 143 down from its top.
    local minimap = env.CreateFrame("Frame", "Minimap")
    minimap:SetSize(198, 198)
    minimap:SetPoint("CENTER", env.UIParent, "TOPRIGHT", -107.5, -143)
    -- The backpack (opts.bags: { size = n, [slot] = { itemID, count } }), the quest log and reputation.
    -- Whom this character talks to (c.npc: name, faction, GUID) and what it targets, by GUID.
    add("UnitExists", function(unit) if unit == "npc" then return c.npc ~= nil end return unit == "player" end)
    add("UnitGUID", function(unit)
        if unit == "player" then return "Player-1-" .. tostring(c.account or 0) end
        if unit == "npc" then return c.npc and c.npc.guid end
        if unit == "target" then return c.targetGuid end
    end)
    local unitName = env.UnitName
    add("UnitName", function(unit)
        if unit == "npc" then return c.npc and c.npc.name end
        if unit == "target" and c.targetGuid then return c.targetName end
        return unitName(unit)
    end)
    add("hooksecurefunc", function(t, name, fn)
        if type(t) == "string" then t, name, fn = env, t, name end
        local orig = t[name]
        t[name] = function(...) local r = { orig(...) } fn(...) return unpack(r) end
    end)
    -- The auction house, as the game serves it: world.auctions[house] lists itemID, count, buyout
    -- (0: bids only) and seller; a full scan answers a moment later; searches for one item too.
    local AHK = function(id) return { itemID = id, itemLevel = 0, itemSuffix = 0, battlePetSpeciesID = 0 } end
    local function listings() return world.auctions[REALM .. "|" .. (c.npc and c.npc.faction or "Neutral")] or {} end
    local function results(id)
        local out = {}
        for _, a in ipairs(listings()) do if a[1] == id and a[3] > 0 then out[#out + 1] = a end end
        table.sort(out, function(a, b) return a[3] / a[2] < b[3] / b[2] end)
        return out
    end
    env.Enum.AuctionHouseSortOrder = { Price = 0, Name = 1, Level = 2, Bid = 3, Buyout = 4 }
    add("C_AuctionHouse", {
        ReplicateItems = function()
            world.replicateCalls = (world.replicateCalls or 0) + 1
            c.replicated = listings()
            env.C_Timer.After(3, function() c.fire("REPLICATE_ITEM_LIST_UPDATE") end)
        end,
        GetNumReplicateItems = function() return c.replicated and #c.replicated or 0 end,
        GetReplicateItemInfo = function(i)
            local a = c.replicated and c.replicated[i + 1]
            if not a then return nil end
            return ITEMS[a[1]] and ITEMS[a[1]][1], nil, a[2], 1, true, 1, "", 0, 0, a[3], 0, nil, nil, a[4], a[4], 0, a[1], true
        end,
        MakeItemKey = function(id) return AHK(id) end,
        SendSearchQuery = function(key)
            world.searches = (world.searches or 0) + 1
            local id = key.itemID
            env.C_Timer.After(1, function()
                if GEAR[id] then c.fire("ITEM_SEARCH_RESULTS_UPDATED", AHK(id)) else c.fire("COMMODITY_SEARCH_RESULTS_UPDATED", id) end
            end)
        end,
        GetNumCommoditySearchResults = function(id) return #results(id) end,
        GetCommoditySearchResultInfo = function(id, i)
            local a = results(id)[i]
            return a and { itemID = id, quantity = a[2], unitPrice = math.floor(a[3] / a[2]), auctionID = i, owners = { a[4] }, totalNumberOfOwners = 1 }
        end,
        HasFullCommoditySearchResults = function() return true end,
        GetNumItemSearchResults = function(key) return #results(key.itemID) end,
        GetItemSearchResultInfo = function(key, i)
            local a = results(key.itemID)[i]
            return a and { itemKey = key, quantity = a[2], buyoutAmount = a[3], auctionID = i, owners = { a[4] }, totalNumberOfOwners = 1 }
        end,
        HasFullItemSearchResults = function() return true end,
    })
    -- A vendor's wares (c.merchant: itemID, price, stack, how many left: -1 unlimited).
    add("GetMerchantNumItems", function() return c.merchant and #c.merchant or 0 end)
    add("GetMerchantItemID", function(i) return c.merchant and c.merchant[i] and c.merchant[i][1] end)
    add("C_MerchantFrame", { GetItemInfo = function(i)
        local m = c.merchant and c.merchant[i]
        return m and { name = ITEMS[m[1]] and ITEMS[m[1]][1], texture = 1, price = m[2], stackCount = m[3], numAvailable = m[4], isPurchasable = true,
            isUsable = true, hasExtendedCost = false } end })
    -- The loot window (c.loot: itemID and the GUID it came from), fishing, and the quest dialog
    -- (c.quest: id, title, rewards, choices).
    add("GetNumLootItems", function() return c.loot and #c.loot or 0 end)
    add("GetLootSlotLink", function(i) local l = c.loot and c.loot[i] return l and l[1] and link(l[1]) end)
    add("GetLootSourceInfo", function(i) local l = c.loot and c.loot[i] return l and l[2], 1 end)
    add("IsFishingLoot", function() return c.fishing == true end)
    add("GetQuestID", function() return c.quest and c.quest.id or 0 end)
    add("GetTitleText", function() return c.quest and c.quest.title end)
    add("GetNumQuestRewards", function() return c.quest and #c.quest.rewards or 0 end)
    add("GetNumQuestChoices", function() return c.quest and #c.quest.choices or 0 end)
    add("GetQuestItemLink", function(kind, i) local q = c.quest local id = q and (kind == "reward" and q.rewards or q.choices)[i] return id and link(id) end)
    -- The profession window (c.window: the profession it shows, and whose it is when linked from
    -- someone else) over this character's professions (c.crafts: name = { skill, max, known }), and
    -- the collection's journal: who drops a piece of gear (world.drops). The window answers about
    -- recipes while it's open; what a recipe makes and uses, the game knows any time.
    local function shown() local w = c.window return w and ((w.linked and w.linked.crafts or c.crafts or {})[w.prof] or {}) end
    add("C_TradeSkillUI", {
        GetBaseProfessionInfo = function()
            local w = c.window
            if not w then return nil end
            local p = shown()
            return { professionName = w.prof, professionID = CRAFT.lines[w.prof], skillLevel = p.skill, maxSkillLevel = p.max }
        end,
        IsTradeSkillLinked = function() return c.window ~= nil and c.window.linked ~= nil, c.window and c.window.linked and c.window.linked.full end,
        IsNPCCrafting = function() return false end,
        GetAllRecipeIDs = function()
            local ids = {}
            if not c.window then return ids end
            for rid, r in pairs(CRAFT.recipes) do if r[4] == c.window.prof and not (c.window.only and not c.window.only[rid]) then ids[#ids + 1] = rid end end
            for rid, r in pairs(world.bigRecipes or {}) do if r[4] == c.window.prof then ids[#ids + 1] = rid end end
            table.sort(ids)
            return ids
        end,
        GetRecipeInfo = function(rid)
            local r = CRAFT.recipes[rid] or (world.bigRecipes or {})[rid]
            local w = c.window
            if not (r and w and r[4] == w.prof) then return nil end
            c.recipeReads = (c.recipeReads or 0) + 1
            if c.closeAfter and c.recipeReads >= c.closeAfter then
                c.closeAfter, c.window = nil, nil -- the player closes the window part way through
                c.fire("TRADE_SKILL_CLOSE")
                return nil
            end
            return { recipeID = rid, learned = shown().known and shown().known[rid] == true or false, name = r[1],
                icon = r[2] and ITEMS[r[2]] and ITEMS[r[2]][4] or 136244, categoryID = CRAFT.groups[r[5]], relativeDifficulty = 1 }
        end,
        GetRecipeSchematic = function(rid)
            local r = CRAFT.recipes[rid] or (world.bigRecipes or {})[rid]
            if not r then return nil end
            local slots = {}
            for k, u in ipairs(r[3]) do slots[k] = { reagents = { { itemID = u[1] } }, quantityRequired = u[2], required = true } end
            return { recipeID = rid, outputItemID = r[2], quantityMin = 1, reagentSlotSchematics = slots, name = r[1] }
        end,
        GetCategoryInfo = function(id) return CRAFT.groupNames[id - 1000] and { categoryID = id, name = CRAFT.groupNames[id - 1000] } end,
        GetProfessionInfoByRecipeID = function(rid)
            local r = CRAFT.recipes[rid] or (world.bigRecipes or {})[rid]
            return r and { professionName = r[4], professionID = CRAFT.lines[r[4]] }
        end,
    })
    add("C_TransmogCollection", {
        GetItemInfo = function(x) local id = tonumber(x) or tonumber(tostring(x):match("item:(%d+)")) if world.drops[id] then return 9000 + id, 70000 + id end end,
        GetAppearanceSourceDrops = function(source) world.journalCalls = (world.journalCalls or 0) + 1 return world.drops[source - 70000] or {} end,
    })
    add("C_Container", {
        UseContainerItem = function(bag, slot) end,
        GetContainerItemID = function(bag, slot) local e = bag == 0 and opts.bags and opts.bags[slot] return e and e[1] end,
        GetContainerNumSlots = function(bag) return bag == 0 and opts.bags and opts.bags.size or 0 end,
        GetContainerItemInfo = function(bag, slot)
            local e = bag == 0 and opts.bags and opts.bags[slot]
            if not e then return nil end
            local it = ITEMS[e[1]]
            return { itemID = e[1], stackCount = e[2], quality = it[2], iconFileID = it[4], hyperlink = link(e[1]), isBound = e.bound == true }
        end,
    })
    add("C_QuestLog", opts.quests and {
        GetNumQuestLogEntries = function() return #opts.quests end,
        GetInfo = function(i)
            local q = opts.quests[i]
            if q.header then return { title = q.header, isHeader = true } end
            return { title = q[1], questID = 90000 + i, level = q[2] }
        end,
        IsComplete = function(id) return opts.quests[id - 90000].done == true end,
        GetQuestObjectives = function(id) return opts.quests[id - 90000].obj end,
    } or nil)
    add("C_Reputation", opts.reps and {
        GetNumFactions = function() return #opts.reps end,
        GetFactionDataByIndex = function(i)
            local r = opts.reps[i]
            return { name = r[1], factionID = 3000 + i, reaction = r[2], currentStanding = r[3], currentReactionThreshold = r[4], nextReactionThreshold = r[5], isHeader = r.header }
        end,
    } or nil)

    -- The addon, as the game loads it.
    local ns = {}
    c.ns = ns
    local dir = tocPath:match("(.*/)") or "./"
    for line in io.lines(tocPath) do
        c.version = c.version or line:match("^## Version:%s*(%S+)")
        if line:match("^[%w_]+%.lua$") then
            local chunk = assert(loadfile(dir .. line))
            setfenv(chunk, env)
            chunk("Reliquary", ns)
        end
    end
    env.ReliquaryDB = c.saved
    c.db = function() return env.ReliquaryDB end
    -- What the dashboard on the PC handed the game while it was closed (tools/blizzard_prices.py).
    env.ReliquaryBlizzard, c.feed = c.feed, nil
    c.feedLeft = function() return env.ReliquaryBlizzard end
    c.slash = function(msg) env.SlashCmdList.RELIQUARY(msg) end
end

local function client(opts)
    local c = { opts = opts, name = opts.name, surname = opts.surname or SURNAMES[opts.name], class = opts.class, full = fullOf(opts.name, opts.surname),
        faction = opts.faction or "Alliance", guild = opts.guild and GUILD.name,
        rank = opts.rank, online = true, prefixes = {}, sent = {}, printed = {}, throttled = 0, bucket = 10, bucketMax = 10, bucketAt = world.clock,
        combat = false, lockdown = false, inInstance = false, target = nil, account = opts.account, level = opts.level,
        bankOpen = false, bankLoaded = {}, ignores = {}, session = 1, saved = opts.db, itemCache = {}, spellCache = {}, loadRequests = 0, tooltipReads = {},
        chatSent = {}, club = {} }
    -- The game has its own gear and bags loaded; anything else it fetches when something asks.
    for _, id in pairs(opts.gear or {}) do c.itemCache[id] = true end
    for _, e in pairs(opts.bags or {}) do if type(e) == "table" then c.itemCache[e[1]] = true end end
    boot(c)
    world.clients[#world.clients + 1] = c
    world.byName[c.full] = c
    if c.account then world.byAccount[c.account] = c end
    return c
end

-- The game's chat between these games. A guild line goes to the guild's history on the server
-- (kept for whoever is away) and to every member online, the speaker too; a whisper reaches its
-- player when they're online and comes back to its sender as sent.
-- A guild line (or one into the guild's Discord channel, GUILD_DISCORD) is in its stream on the
-- server, and reaches each member online as the event of its kind.
-- Officer chat is for the guild master and officers (ranks 1 and 2 here).
function world.officer(c) return c.guild and not c.leftGuild and c.rank ~= nil and c.rank <= 2 end
function world.guildSays(stream, event, text, author, sender, guid, info)
    local id, h = world.lineID, world.history[stream]
    h[#h + 1] = { messageId = { epoch = world.clock * 1e6 + id, position = id }, content = text, destroyed = false, edited = false, author = author }
    for _, c in ipairs(world.clients) do
        if c.online and c.guild and not c.leftGuild and (stream ~= "2" or world.officer(c)) then
            local r = c.club[stream]
            if r and r.hi == #h - 1 then r.hi = #h end -- what a game sees live, it has
            c.fire(event, text, sender, "", "", sender, "", 0, 0, "", 0, id, guid, 0, false, false, false, false, info)
        end
    end
end
function world.say(from, text, kind, target)
    world.lineID = world.lineID + 1
    local id, guid = world.lineID, from.env.UnitGUID("player")
    if (kind == "GUILD" or kind == "GUILD_DISCORD" or (kind == "OFFICER" and world.officer(from))) and from.guild then
        world.guildSays(kind == "GUILD" and "1" or kind == "OFFICER" and "2" or "3", "CHAT_MSG_" .. kind, text, { name = (REGIONAL and not world.givenOnly) and from.full or from.name,
            classID = CLASS_IDS[from.class], guid = guid, officerNote = "never read", isSelf = false, discordInfo = { userID = 0 } }, from.full, guid, { userID = 0 })
    elseif kind == "WHISPER" then
        local to = world.byName[target]
        if not (to and to.online) then return end -- the game says there's no such player online
        to.fire("CHAT_MSG_WHISPER", text, from.full, "", "", from.full, "", 0, 0, "", 0, id, guid, 0, false, false, false, false, { userID = 0 })
        from.fire("CHAT_MSG_WHISPER_INFORM", text, to.full, "", "", to.full, "", 0, 0, "", 0, id, to.env.UnitGUID("player"), 0, false, false, false, false, { userID = 0 })
    end
end
-- A Battle.net account as the game describes it: its BattleTag (stable, as the real one is), and the
-- WoW: Forever character it's playing, while it is.
function world.bnAccount(other, note)
    return { bnetAccountID = other.account, accountName = "|Kq" .. other.account .. "|k", battleTag = other.name .. "#" .. (1000 + other.account), isFriend = true,
        note = note or "", gameAccountInfo = { gameAccountID = other.account, clientProgram = other.online and "WoW" or "", isOnline = other.online and true or false,
            wowProjectID = 21, characterName = other.online and (REGIONAL and other.full or other.name) or nil, realmName = other.online and "CAMWOW US2 Realm 11 RP" or nil,
            classFilename = other.online and other.class or nil, characterLevel = other.online and other.level or nil, areaName = other.online and other.zone or nil } }
end
-- A line from someone on the guild's Discord: in the Discord channel's stream as the game's Discord
-- line, or (inGuild) in the guild's own stream as a guild line from a Discord user.
function world.discord(text, info, inGuild)
    world.lineID = world.lineID + 1
    world.guildSays(inGuild and "1" or "3", inGuild and "CHAT_MSG_GUILD" or "CHAT_MSG_GUILD_DISCORD", text,
        { name = info.globalName, discordInfo = info, officerNote = "never read", isSelf = false }, info.globalName, nil, info)
end

local function login(c)
    c.online = true
    c.fire("ADDON_LOADED", "Reliquary")
    c.fire("PLAYER_LOGIN")
    -- The window's movements land at once, as with the player's Animations switch off: the layout a
    -- check measures is the finished one.
    c.db().settings.motion = false
    c.fire("PLAYER_ENTERING_WORLD", true, false)
end

-- Logging out and in again: the game writes what the addon keeps to disk, and the next session
-- loads it into a fresh game.
local function savedCopy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, x in pairs(v) do out[savedCopy(k)] = savedCopy(x) end
    return out
end
local function newSession(c)
    c.saved = savedCopy(c.db())
    c.session = c.session + 1
    c.club = {} -- a fresh game has downloaded none of the guild's chat
    c.prefixes = {}
    c.bankOpen, c.bankLoaded = false, {}
    boot(c)
    login(c)
end

local function openBank(c)
    c.bankOpen = true
    c.bankLoaded = {}
    c.fire("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", 10)
end

local function closeBank(c)
    c.bankOpen = false
    c.fire("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", 10)
end

local function peer(c, name) return c.db().peers[fullOf(name)] end
-- What a player types for /rq look: the full name on Forever (in lower case, as people type).
local function lookName(name) return (REGIONAL and fullOf(name) or name):lower() end
local function gk() return GUILD.name .. "@" .. "CAMWOWUS2Realm11RP" end
local function fail(msg) error(msg, 2) end
local function check(ok, msg) if not ok then fail(msg) end end

---------------------------------------------------------------------------
-- The players
---------------------------------------------------------------------------
local DRUID_TALENTS = {
    { "Improved Wrath", 0, 0, 5, 5, 136006 }, { "Nature's Grasp", 600, 0, 1, 1, 136063 }, { "Improved Moonfire", 600, 600, 2, 5, 136096 },
    { "Ferocity", 4400, 0, 0, 5, 132190 }, { "Furor", 8800, 0, 5, 5, 135881 }, { "Improved Healing Touch", 7600, 600, 3, 5, 136041 },
}
local PRIEST_TALENTS = {
    { "Unbreakable Will", 0, 0, 2, 5, 135940 }, { "Improved Power Word: Fortitude", 600, 0, 2, 2, 135987 }, { "Inner Fire", 600, 600, 1, 1, 135926 },
    { "Healing Focus", 4400, 0, 2, 2, 135915 }, { "Improved Renew", 3800, 600, 3, 3, 135953 }, { "Holy Specialization", 5000, 600, 3, 5, 135967 },
    { "Spirit Tap", 8200, 0, 3, 5, 136188 }, { "Shadow Affinity", 8800, 600, 0, 3, 136207 },
}
local WARRIOR_TALENTS = {
    { "Improved Charge", 0, 0, 2, 2, 132337 }, { "Deflection", 600, 0, 5, 5, 132269 }, { "Tactical Mastery", 0, 600, 3, 5, 136031 },
    { "Cruelty", 4400, 0, 5, 5, 132292 }, { "Improved Cleave", 5000, 600, 3, 3, 132338 }, { "Shield Specialization", 8200, 0, 0, 5, 134952 },
    { "Improved Thunder Clap", 8800, 600, 2, 3, 132325 },
}
local HUNTER_TALENTS = {
    { "Improved Aspect of the Hawk", 0, 0, 3, 5, 136076 }, { "Endurance Training", 600, 0, 2, 5, 136112 }, { "Improved Concussive Shot", 3800, 0, 5, 5, 135860 },
    { "Efficiency", 4400, 600, 5, 5, 135865 }, { "Aimed Shot", 4400, 1200, 1, 1, 132222 }, { "Lethal Shots", 5000, 0, 5, 5, 132109 },
    { "Monster Slaying", 8200, 0, 0, 3, 134154 },
}
-- Joan arrives with saved data from before sharing existed (schema 1), as a long-time player's does.
local joan = client({ name = "Joan", class = "DRUID", race = "High Order Skyborne", raceFile = "HighOrderSkyborne", level = 12, guild = true, rank = 2,
    gear = { [1] = 264120, [5] = 264140, [11] = 264908, [15] = 2591, [16] = 264160, [8] = 264154 }, ilvl = 13.6,
    profs = { { "Herbalism", 136246, 88, 150 }, { "Alchemy", 136240, 61, 75 } }, talents = DRUID_TALENTS, account = 501, bnFriends = { "Brannoc" },
    trp3 = true, trpKnown = { [REGIONAL and "Faelwen Duskleaf" or ("Faelwen-" .. REALM)] = { characteristics = { FN = "Faelwen", LN = "Duskleaf",
        TI = "Warden of the Glade", RA = "Night Elf", CL = "Druid", AG = "212" }, character = { RP = 1, XP = 2, CU = "Keeping watch over Auberdine's shore." },
        misc = { PE = { ["1"] = { AC = true, TI = "Antlered circlet" } } } } },
    db = { schema = 1, chars = { ["Joan-CAMWOW US2 Realm 10 RP PvP"] = { name = "Joan", level = 17, updated = world.clock - 86400 } }, settings = {} } })
local thaliaSeen = world.clock - 40 * 86400
local oldThalia = { name = "Thalia", classFile = "PRIEST", raceFile = "NightElf", level = 18, updated = world.clock - 7200, firstSeen = 1793000000,
    share = { guild = false, friends = false, public = false } }
local thalia = client({ name = "Thalia", class = "PRIEST", race = "Night Elf", raceFile = "NightElf", level = 19, guild = true, rank = 4, trp3 = true,
    db = { schema = 2, settings = {}, chars = { ["Thalia-" .. REALM] = oldThalia },
        guilds = { [GUILD.name .. "@" .. REALM] = { view = { ["Thalia-" .. REALM] = { at = thaliaSeen, tabs = { true } } } } } },
    gear = { [1] = 264201, [2] = 264202, [3] = 264203, [5] = 264204, [6] = 264205, [7] = 264206, [8] = 264207, [10] = 14146,
        [11] = 264208, [13] = 264209, [15] = 2591, [16] = 2075, [17] = 264210, [18] = 264211 },
    ilvl = 21.4, profs = { { "Tailoring", 136249, 102, 150 }, { "Enchanting", 136244, 87, 150 } }, talents = PRIEST_TALENTS, account = 502,
    bags = { size = 16, [1] = { 4306, 20 }, [2] = { 2589, 12 }, [3] = { 118, 5 }, [5] = { 6948, 1 }, [7] = { 264909, 1, bound = true }, [8] = { 264910, 1 } },
    quests = { { header = "Darkshore" }, { "The Moonwell Sickness", 18, obj = { { text = "Moonwell water: 3/5", finished = false } } },
        { "Lost in the Glades", 19, done = true, obj = { { text = "Find the lost scout", finished = true } } } },
    reps = { { "Alliance", 0, 0, 0, 0, header = true }, { "Darnassus", 6, 13450, 9000, 21000 }, { "Moonwell Circle", 5, 4100, 3000, 9000 } } })
local mira = client({ name = "Mira", class = "MAGE", race = "Human", raceFile = "Human", level = 17, guild = true, rank = 4,
    gear = { [16] = 6505 }, ilvl = 11.0, account = 503,
    db = REGIONAL and { schema = 2, settings = {}, chars = { ["Mira-" .. REALM] = { name = "Mira", classFile = "PRIEST", raceFile = "Human", level = 30, updated = world.clock - 86400 } } } or nil })
-- Records kept by name and realm that are another character of the same player with the same given
-- name: a human (Brannoc is a dwarf), and Eluned Starfall (this is Eluned Dawnstride).
local function oldRecord(name, more)
    local r = { name = name, level = 30, updated = world.clock - 86400 }
    for k, v in pairs(more) do r[k] = v end
    return REGIONAL and { schema = 2, settings = {}, chars = { [name .. "-" .. REALM] = r } } or nil
end
local brannoc = client({ name = "Brannoc", class = "WARRIOR", race = "Dwarf", raceFile = "Dwarf", level = 24,
    db = oldRecord("Brannoc", { classFile = "WARRIOR", raceFile = "Human" }),
    gear = { [1] = 264220, [3] = 264221, [5] = 264222, [6] = 264223, [7] = 264224, [8] = 264225, [10] = 264226, [11] = 264230,
        [15] = 2591, [16] = 264227, [17] = 264228, [18] = 264229 },
    ilvl = 22.8, profs = { { "Blacksmithing", 136241, 118, 150 }, { "Mining", 136248, 131, 150 } }, talents = WARRIOR_TALENTS,
    account = 504, bnFriends = { "Joan" } })
local eluned = client({ name = "Eluned", class = "HUNTER", race = "Night Elf", raceFile = "NightElf", level = 23,
    db = oldRecord("Eluned", { surname = "Starfall", classFile = "HUNTER", raceFile = "NightElf" }),
    gear = { [1] = 264240, [3] = 264241, [5] = 264242, [6] = 264243, [7] = 264244, [8] = 264245, [9] = 264246, [15] = 264249,
        [16] = 264248, [18] = 264247 },
    ilvl = 21.9, profs = { { "Leatherworking", 136247, 96, 150 }, { "Herbalism", 136246, 110, 150 } }, talents = HUNTER_TALENTS, account = 505 })
-- Faelwen has a record under her full name already, and one under her name and realm from an
-- earlier version: the one under her full name is hers now, and stays.
local faelwenBefore = { name = "Faelwen", classFile = "DRUID", raceFile = "NightElf", level = 12, updated = world.clock - 3 * 86400 }
local faelwenNow = { name = "Faelwen", surname = "Duskleaf", classFile = "DRUID", raceFile = "NightElf", level = 17, updated = world.clock - 3600,
    share = { guild = false, friends = false, public = false } }
local faelwen = client({ name = "Faelwen", class = "DRUID", race = "Night Elf", raceFile = "NightElf", level = 18, guild = true, rank = 1,
    gear = { [16] = 6505 }, ilvl = 14.0, account = 508,
    db = REGIONAL and { schema = 2, settings = {}, chars = { ["Faelwen-" .. REALM] = faelwenBefore, ["Faelwen Duskleaf-" .. REALM] = faelwenNow } } or nil })
faelwen.zone = "Darkshore"
local kael = client({ name = "Kael", class = "ROGUE", race = "Blood Elf", raceFile = "BloodElf", level = 20, faction = "Horde", gear = {}, ilvl = 12, account = 506 })
local rogue = client({ name = "Grift", class = "ROGUE", race = "Human", raceFile = "Human", level = 20, gear = { [16] = 2075 }, ilvl = 12, account = 507 })
thalia.prof1 = { "Tailoring", 102 }
joan.zone, thalia.zone, mira.zone = "Darkshore", "Darnassus", "Darkshore"
thalia.subzone = "Craftsmen's Terrace"

for _, c in ipairs(world.clients) do login(c) end
-- Joan's older character kept its place on her public page; this new one (Joan on another realm)
-- shares nothing, like every new character.
local db = joan.db()
check(db.schema == 2, "schema not raised")
check(db.chars["Joan-CAMWOW US2 Realm 10 RP PvP"].share.public == true, "a character from before sharing must stay public")
check(db.chars["Joan-CAMWOW US2 Realm 10 RP PvP"].share.guild == false, "guild sharing must start off")
local me = db.chars[ownKey(joan)]
-- Thalia's record, kept before under her name and realm, moved to her full name with all it held,
-- the guild's note of which bank tabs she was shown with it, and the key it had, for the dashboard;
-- Mira's old record is another character's (a priest), so it stays where it was.
local tdb = thalia.db()
if REGIONAL then
    check(tdb.chars[ownKey(thalia)] == oldThalia and not tdb.chars["Thalia-" .. REALM] and oldThalia.was and oldThalia.was[1] == "Thalia-" .. REALM
        and oldThalia.firstSeen == 1793000000, "Thalia's record wasn't carried over to her full name")
    local tg = tdb.guilds[GUILD.name .. "@" .. REALM]
    check(tg.view[ownKey(thalia)] and tg.view[ownKey(thalia)].at == thaliaSeen and not tg.view["Thalia-" .. REALM],
        "what the guild knew of Thalia's record stayed under its old key")
else
    check(tdb.chars[ownKey(thalia)] == oldThalia and not oldThalia.was, "with names by realm, Thalia's record moved")
end
check(me.share.guild == false and me.share.friends == false and me.share.public == false, "a new character must share nothing")
advance(9)
if REGIONAL then
    -- A record kept by name and realm that its class, race or family name says is another of yours
    -- stays where it was, and this character gets its own.
    local function stays(c, field, value)
        local a = c.db().chars
        local old, new = a[c.name .. "-" .. REALM], a[ownKey(c)]
        return old and old[field] == value and old.level == 30 and not old.was and new and new ~= old and new.level == c.level
    end
    check(stays(mira, "classFile", "PRIEST"), "Mira the mage took over a priest's record")
    check(stays(brannoc, "raceFile", "Human"), "Brannoc the dwarf took over a human's record")
    check(stays(eluned, "surname", "Starfall"), "Eluned Dawnstride took over Eluned Starfall's record")
    local fdb = faelwen.db().chars
    check(fdb[ownKey(faelwen)] == faelwenNow and faelwenNow.level == 18 and fdb["Faelwen-" .. REALM] == faelwenBefore and not faelwenBefore.was,
        "Faelwen's record was replaced by the one kept under her name and realm")
end
check(table.concat(joan.printed, "\n"):find("You can now share this character", 1, true), "the one-time sharing news wasn't printed")
check(db.settings.sharingNews == nil, "the sharing news would print again")

-- Each player chooses before the hellos go out.
joan.slash("share guild on")
joan.slash("share public on")
thalia.slash("share guild")
brannoc.slash("share friends on")
eluned.slash("share public on")
kael.slash("share public on")
rogue.slash("share public on")
check(me.share.guild and me.share.public and not me.share.friends, "/rq share")
check(table.concat(joan.printed, "\n"):find("shares with: guild |cff5fb87aon|r, friends |cff8b7e6doff|r, public |cff5fb87aon|r", 1, true), "/rq share didn't report the switches")
advance(120)

---------------------------------------------------------------------------
-- 1. The guild: each guildmate who shares reaches every other, and nobody else
---------------------------------------------------------------------------
local t = peer(joan, "Thalia")
check(t and t.scopes.g and t.card and t.card.level == 19 and t.card.class == "Priest", "Joan doesn't have Thalia's card")
check(t.card.gear[16] and t.card.gear[16].n == "Priest's Mace" and t.card.gear[16].s:match("^item:2075:") and t.card.gear[5].n == "Starfall Robe", "Thalia's gear")
check(t.card.profs[1].n == "Tailoring" and t.card.profs[1].sk == 102, "Thalia's professions")
local j = peer(thalia, "Joan")
check(j and j.scopes.g and not j.scopes.f and j.card.level == 12 and j.card.ilvl == 13.6, "Thalia doesn't have Joan's card")
check(j.card.tal and j.card.tal.pts[1] == 8 and j.card.tal.pts[2] == 0 and j.card.tal.pts[3] == 8, "Joan's talent points per tree: " .. table.concat(j.card.tal.pts, "/"))
check(peer(mira, "Joan") and peer(mira, "Thalia"), "Mira shares nothing but still sees her guildmates")
check(not peer(joan, "Mira") and not peer(thalia, "Mira"), "Mira shares nothing, so nobody has her card")
for _, c in ipairs({ brannoc, eluned, kael, rogue }) do
    for _, other in ipairs({ "Joan", "Thalia" }) do
        local p = peer(c, other)
        check(not (p and p.scopes.g), c.name .. " has a guild card from outside the guild")
    end
end
-- Nothing private in a card.
for _, k in ipairs({ "money", "bags", "bank", "quests", "photos", "played", "zone", "x", "y", "places" }) do
    check(j.card[k] == nil, "a card carries " .. k)
end
-- The roster: everyone in the guild, never an officer note.
local g = db.guilds[gk()]
check(g and #g.members == 12 and g.motd == GUILD.motd, "Joan's guild roster")
for _, m in ipairs(g.members) do check(m.officerNote == nil and m.on ~= nil or m.seen ~= nil, "roster row") end

---------------------------------------------------------------------------
-- 2. Friends: Battle.net friends, both ways, each under what the other shares
---------------------------------------------------------------------------
local b = peer(joan, "Brannoc")
check(b and b.scopes.f and not b.scopes.p and b.card and b.card.class == "Warrior" and b.card.tal.pts[2] == 8, "Joan doesn't have Brannoc's card as a friend's")
local jb = peer(brannoc, "Joan")
check(jb and jb.scopes.p and not jb.scopes.f, "Joan doesn't share with friends, but public: Brannoc should have her as public only")
for _, m in ipairs(world.log) do
    check(not (m.kind == "WHISPER" and m.from == brannoc.full and m.target == joan.full), "Battle.net friends talk over Battle.net, not whispers")
end

---------------------------------------------------------------------------
-- 3. Public: targeting a player asks them; other factions are never whispered
---------------------------------------------------------------------------
check(not peer(joan, "Eluned"), "Eluned before meeting her")
joan.target = { name = "Eluned", faction = "Alliance" }
joan.fire("PLAYER_TARGET_CHANGED")
advance(30)
local e = peer(joan, "Eluned")
check(e and e.scopes.p and e.card.class == "Hunter", "targeting Eluned didn't fetch her public reliquary")
check(peer(eluned, "Joan") and peer(eluned, "Joan").scopes.p, "Eluned should have Joan's public card back")
local before = #joan.sent
joan.target = { name = "Kael", faction = "Horde" }
joan.fire("PLAYER_TARGET_CHANGED")
advance(30)
check(#joan.sent == before, "Joan whispered a Horde player")
joan.target = { name = "Eluned", faction = "Alliance" }
joan.fire("PLAYER_TARGET_CHANGED")
advance(30)
check(#joan.sent == before, "Joan asked Eluned twice in one session")
-- /rq look asks by name and says when the card arrives.
if REGIONAL then
    -- A given name alone isn't a name on Forever: nobody is asked.
    local sent = #thalia.sent
    thalia.slash("look eluned")
    advance(5)
    check(#thalia.sent == sent and table.concat(thalia.printed, "\n"):find("/rq look takes a full name", 1, true), "/rq look with a given name only")
end
thalia.slash("look " .. lookName("Eluned"))
advance(30)
check(peer(thalia, "Eluned") and table.concat(thalia.printed, "\n"):find(fullOf("Eluned"):match("^([^%-]+)") .. " shared with you", 1, true), "/rq look")

---------------------------------------------------------------------------
-- 4. The guild bank: a tab goes only to guildmates whose rank may see it
---------------------------------------------------------------------------
-- Every message the server carried, put back together and unpacked, with who sent it and where.
local B62 = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
local function carried(since)
    local EU, parts, out = joan.env.C_EncodingUtil, {}, {}
    for k = since or 1, #world.log do
        local e = world.log[k]
        local seq, total = B62:find(e.text:sub(4, 4), 1, true) - 1, B62:find(e.text:sub(5, 5), 1, true) - 1
        local key = e.from .. "|" .. e.kind .. "|" .. tostring(e.target) .. "|" .. e.text:sub(2, 3)
        local p = parts[key] or { n = 0 }
        parts[key] = p
        if not p[seq] then p[seq], p.n = e.text:sub(6), p.n + 1 end
        if p.n == total then
            parts[key] = nil
            local raw = EU.DecompressString(EU.DecodeBase64(table.concat(p, "", 1, total)), 0)
            out[#out + 1] = { from = e.from, kind = e.kind, target = e.target, msg = EU.DeserializeCBOR(raw), at = e.at }
        end
    end
    return out
end
local function rankIn(c) return c.rank end
local banksBefore = #world.log

openBank(thalia)            -- rank 4: Reagents, Gear and Potions; never Officers
advance(15)
closeBank(thalia)
advance(30)
local tb = thalia.db().guilds[gk()].bank
check(tb.tabs[1].slots[1].id == 765 and tb.tabs[2].slots[1].id == 14146 and tb.tabs[4].slots[98].id == 4306, "Thalia's own read of the bank")
check(not tb.tabs[3], "Thalia read a tab her rank can't view")
check(thalia.queried == 3, "the bank was asked for " .. tostring(thalia.queried) .. " tabs, not the 3 Thalia may view")
-- The same visit read each tab's log and note and the gold log, as the bank's own pages do, and
-- what Thalia's rank may take today; never the Officers tab's records.
check(tb.logs and tb.logs[1] and #tb.logs[1].list == 2 and tb.logs[1].list[2].k == "deposit" and tb.logs[1].list[2].id == 2447
    and tb.logs[1].list[2].n == 13 and tb.logs[1].list[2].nm == "Peacebloom", "Thalia's read of the Reagents log")
check(tb.logs[1].list[1].at < tb.logs[1].list[2].at and world.clock - tb.logs[1].list[2].at >= 2 * 3600 - 60, "log entries keep when they happened")
check(tb.logs[4] and #tb.logs[4].list == 3 and tb.logs[4].list[2].k == "move" and tb.logs[4].list[2].t2 == 1, "Thalia's read of the Potions log")
check(tb.logs[9] and #tb.logs[9].list == 2 and tb.logs[9].list[1].m == 500000 and tb.logs[9].list[2].k == "repair", "the gold log")
check(tb.notes and tb.notes[4] and tb.notes[4].text == BANK.notes[4] and tb.notes[1].text == BANK.notes[1], "the tabs' notes")
check(not tb.logs[3] and not tb.notes[3], "Thalia read the Officers tab's records")
check(thalia.logsQueried == 4, "the bank was asked for " .. tostring(thalia.logsQueried) .. " logs, not Thalia's 3 tabs and the gold log")
local lim = tb.limits[ownKey(thalia)]
check(lim and lim.tabs[1].w == 2 and lim.tabs[4].w == 2 and not lim.tabs[3] and lim.gold == 50000, "what Thalia's rank may take today")
-- Joan (an officer) restocks Reagents and reads every tab, Officers too.
BANK.tabs[1][4][4] = { 2447, 13 }
openBank(joan)
advance(15)
closeBank(joan)
advance(60)
local jt = db.guilds[gk()].bank
check(jt.tabs[3] and jt.tabs[3].slots[2].id == 6505 and jt.tabs[1].slots[4].n == 13, "Joan's read of the bank")
check(jt.logs[3] and jt.logs[3].list[1].id == 6505 and jt.notes[3].text == BANK.notes[3], "Joan read the Officers tab's records")
-- Until the guild master sets anything, only the game knows what other ranks may see: Joan's copy
-- goes to officers and above, never to a Member. Thalia keeps her own read.
tb = thalia.db().guilds[gk()].bank
check(not tb.tabs[1].slots[4] and tb.tabs[1].by == "Thalia", "Joan's officer copy of Reagents reached a Member before the guild master's settings")
check(not tb.tabs[3], "Thalia was given the Officers tab")
check(not (mira.db().guilds[gk()].bank and mira.db().guilds[gk()].bank.tabs and next(mira.db().guilds[gk()].bank.tabs)),
    "Mira has never been shown the bank, so she keeps no tabs")
check(mira.db().guilds[gk()].bank.money == BANK.money, "guild bank money reaches every guildmate")
-- Nothing of the bank went to the whole guild, and every tab went only to a guildmate whose rank
-- may view it in game. Without the guild master's settings, nobody's records travel.
local banked = 0
for _, m in ipairs(carried(banksBefore)) do
    if m.msg.t == "gb" then
        banked = banked + 1
        check(m.kind == "WHISPER", "a bank tab went to the whole guild")
        local to = world.byName[m.target]
        check(to and to.rank <= BANK.tabs[m.msg.i][3], "tab " .. m.msg.i .. " went to " .. tostring(m.target) .. ", whose rank can't view it")
        check(m.msg.lg == nil and m.msg.nt == nil, "a tab's records travelled without the guild master's settings")
    end
end
check(banked > 0, "no bank tab travelled at all")

---------------------------------------------------------------------------
-- 5. A changed card reaches those who see it; switching off takes it back
---------------------------------------------------------------------------
joan.level = 13
joan.fire("PLAYER_LEVEL_UP", 13)
advance(200)
check(peer(thalia, "Joan").card.level == 13, "Thalia didn't hear that Joan reached level 13")
check(peer(eluned, "Joan").card.level == 12, "Eluned met Joan once: she isn't sent every change")
-- Two guildmates come online within a minute of each other: Joan's card has just gone out for the
-- first, and still reaches the second once the minute between two sends has passed.
mira.online = false
mira.db().peers[joan.full] = nil
thalia.db().peers[joan.full] = nil
thalia.ns.send({ kind = "GUILD" }, { t = "hi", w = 1 })
advance(20)
check(peer(thalia, "Joan"), "Thalia didn't get Joan's card back")
mira.online = true
mira.ns.send({ kind = "GUILD" }, { t = "hi", w = 1 })
advance(15)
check(not peer(mira, "Joan"), "Joan sent her card twice within a minute")
advance(60)
check(peer(mira, "Joan") and peer(mira, "Joan").card.level == 13, "Mira came online just after Joan's card went out, and never got it")
-- Looking up someone who doesn't answer says so.
joan.slash("look " .. lookName("Nobody"))
advance(20)
check(table.concat(joan.printed, "\n"):find("Nothing from " .. fullOf("Nobody"):match("^([^%-]+)") .. " yet", 1, true), "/rq look of a player who never answers said nothing")
thalia.slash("share guild off")
advance(30)
check(not peer(joan, "Thalia") and not peer(mira, "Thalia"), "Thalia stopped sharing with the guild, but her card is still kept")

---------------------------------------------------------------------------
-- 5b. What each sees: chosen part by part, sent section by section
---------------------------------------------------------------------------
local function parts(c) return c.db().chars[ownKey(c)].share.parts end
check(db.chars["Joan-CAMWOW US2 Realm 10 RP PvP"].share.parts.gold == "gfp" and db.chars["Joan-CAMWOW US2 Realm 10 RP PvP"].share.parts.bank == "gfp",
    "a character from before sharing must keep showing every part, as its public page did")
check(parts(thalia) == nil, "a new character's parts must be the defaults, not written down")
local tj = peer(thalia, "Joan")
-- What else a guildmate holds of someone: only what goes with their gear (what they would wear).
local function onlyFits(m) for k in pairs(m or {}) do if k ~= "fits" then return false end end return true end
check(tj.card.gear and tj.card.tal and tj.card.profs and tj.card.stats and onlyFits(tj.more), "by default the guild sees gear, talents, professions and the sheet, nothing more")
-- Thalia shares with the guild again, and shows it her bags, where she is, her quests and
-- reputation; never her gold.
thalia.slash("share guild on")
for _, cmd in ipairs({ "share bags guild on", "share place guild on", "share quests guild on", "share reps guild on" }) do thalia.slash(cmd) end
check(parts(thalia).bags == "g" and not parts(thalia).gold,
    "/rq share bags guild on")
advance(30)
local tm = peer(joan, "Thalia").more
check(tm and tm.bags and tm.bags.list[1].s[1].id == 4306 and tm.bags.list[1].s[1].c == 20, "Joan didn't get Thalia's bags")
check(tm.live and tm.live.zone == "Darnassus" and tm.live.gold == nil and tm.live.played == nil, "Thalia's place without her gold")
check(tm.quests and tm.quests.list[2].t == "Lost in the Glades" and tm.quests.list[2].d, "Thalia's quest log")
check(tm.reps and tm.reps.list[2].n == "Darnassus" and tm.reps.list[2].r == 6, "Thalia's reputation")
check(not peer(eluned, "Thalia") or not peer(eluned, "Thalia").more, "Eluned isn't in Thalia's guild and must not get her bags")
-- Eluned shows anyone her gold.
eluned.slash("share gold public on")
advance(5)
joan.slash("look " .. lookName("Eluned"))
advance(30)
check(peer(joan, "Eluned").more and peer(joan, "Eluned").more.live.gold == 4242 and not peer(joan, "Eluned").more.bags, "Eluned's gold, and only her gold")
-- New loot: only the bags go again, and not before ten minutes since they last went.
local coreAt, bagsAt = peer(joan, "Thalia").gotAt.core, peer(joan, "Thalia").gotAt.bags
thalia.opts.bags[4] = { 2592, 3 } -- she loots some wool
thalia.fire("BAG_UPDATE_DELAYED")
advance(60)
check(peer(joan, "Thalia").gotAt.bags == bagsAt, "a change to bags went out within ten minutes of the last")
advance(600)
check(peer(joan, "Thalia").gotAt.core == coreAt, "new loot sent Thalia's whole reliquary again")
check(peer(joan, "Thalia").gotAt.bags > bagsAt and peer(joan, "Thalia").more.bags.list[1].s[4].id == 2592, "Thalia's new loot never reached Joan")
-- Switching a part off takes it away at once.
thalia.slash("share bags off")
advance(15)
check(not peer(joan, "Thalia").more.bags and peer(joan, "Thalia").more.live, "Thalia switched her bags off, but Joan still has them")
-- And switching it on again brings it back without waiting for the next announcement: only the
-- minute between two sends of her bags to the guild.
thalia.slash("share bags guild on")
advance(70)
check(peer(joan, "Thalia").more.bags and peer(joan, "Thalia").more.bags.list[1].s[4].id == 2592, "Thalia showed her bags again, but they never came back")
-- A section already waiting to go when its part is switched off stays home: a guildmate asks for
-- Thalia's bags while she is in a fight, and she hides them before the fight ends.
local function guildAskedSince(t0) -- Joan, Mira or Faelwen (whoever asks first answers for all)
    for _, e in ipairs(world.log) do
        if e.at >= t0 and e.kind == "GUILD" and (e.from == joan.full or e.from == mira.full or e.from == faelwen.full) then return true end
    end
    return false
end
thalia.slash("share bags off")
advance(70)
check(not peer(joan, "Thalia").more.bags, "Thalia's bags stayed with Joan")
local askedFrom = world.clock
thalia.slash("share bags guild on")
advance(0.5)
thalia.combat = true
advance(10)
check(guildAskedSince(askedFrom) and thalia.ns.queued() > 0, "a guildmate's ask for Thalia's bags should be waiting out her fight")
thalia.slash("share bags off")
thalia.combat = false
advance(30)
check(thalia.ns.queued() == 0 and not peer(joan, "Thalia").more.bags, "Thalia's bags went out after she hid them")
-- One waiting for its turn (the minute since her bags last went) stays home too once guild
-- sharing is off.
askedFrom = world.clock
thalia.slash("share bags guild on")
advance(8)
check(guildAskedSince(askedFrom) and not peer(joan, "Thalia").more.bags, "Thalia's bags should have been asked for again, the answer waiting for its turn")
thalia.slash("share guild off")
advance(90)
check(not peer(joan, "Thalia"), "Thalia stopped sharing with the guild, but her bags still reached Joan")
thalia.slash("share guild on")
advance(30)
check(peer(joan, "Thalia") and peer(joan, "Thalia").more.bags, "Thalia shares with the guild again, but Joan didn't get her bags back")
-- Joan's window: Thalia's pages, and the Sharing tab's grid.
joan.slash("")
local jwin = joan.env.ReliquaryFrame
local TAB = { Characters = 1, Guild = 2, Bank = 3, Friends = 4, Public = 5, Sharing = 6 } -- the window's tabs (Viewer.lua)
joan.ui.run(jwin.Tabs[TAB.Guild], "OnClick")
for _, f in ipairs(joan.ui.frames) do
    if f._rows and f:IsVisible() then
        for _, row in ipairs(f._rows) do if row.row and row.row.key == fullOf("Thalia") then joan.ui.run(row, "OnClick") end end
    end
end
local questsButton
for _, f in ipairs(joan.ui.frames) do if f.page == "quests" and f:IsVisible() then questsButton = f end end
check(questsButton, "Thalia's reliquary has no Quests page in Joan's window")
joan.ui.run(questsButton, "OnClick")
-- A card for each zone, each quest with its level on its plate, its objectives under it.
do
local questCards = {}
for _, f in ipairs(joan.ui.frames) do
    if f._rows and f:IsVisible() then
        for _, row in ipairs(f._rows) do if row.element and row.element.kind == "zone" then questCards[#questCards + 1] = row.cards[1] end end
    end
end
local darkshore = questCards[1]
check(darkshore and darkshore.title._text == "Darkshore" and darkshore.questRows[1].title._text == "The Moonwell Sickness"
    and darkshore.questRows[1].plate.level._text == "18", "Thalia's quests in the window")
-- Every line starts at the left, its zone and objectives too, though their font changes with the
-- line (a font brings its own alignment in the game).
do
    local kinds = {}
    for _, c in ipairs(questCards) do
        if c.title:IsShown() then
            kinds.zone = true
            check(c.title:GetJustifyH() == "LEFT", "a quest card's title isn't aligned to the left: " .. tostring(c.title._text))
        end
        for _, row in ipairs(c.questRows) do
            if row:IsShown() then
                kinds.quest = true
                check(row.title:GetJustifyH() == "LEFT", "a quest's title isn't aligned to the left: " .. tostring(row.title._text))
            end
        end
        for _, row in ipairs(c.objRows) do
            if row:IsShown() then
                kinds.obj = true
                check(row.text:GetJustifyH() == "LEFT", "an objective isn't aligned to the left: " .. tostring(row.text._text))
            end
        end
    end
    check(kinds.zone and kinds.obj and kinds.quest, "Thalia's quest list had no zone, quest and objective to look at")
end
end
joan.ui.run(jwin.Tabs[TAB.Sharing], "OnClick")
local goldGuild
for _, f in ipairs(joan.ui.frames) do if f.part == "gold" and f.scope == "guild" and f:IsVisible() then goldGuild = f end end
check(goldGuild and not goldGuild:GetChecked(), "the grid's gold box for the guild")
goldGuild:SetChecked(true)
joan.ui.run(goldGuild, "OnClick")
check(joan.db().chars[ownKey(joan)].share.parts.gold == "g", "ticking gold for the guild in the grid")
advance(15)
check(peer(thalia, "Joan").more and peer(thalia, "Joan").more.live.gold == 4242, "Thalia didn't get Joan's gold once Joan showed it to the guild")
goldGuild:SetChecked(false)
joan.ui.run(goldGuild, "OnClick")
advance(15)
check(not (peer(thalia, "Joan").more and peer(thalia, "Joan").more.live), "Joan hid her gold again, but Thalia still has it")
joan.ui.run(jwin.Tabs[TAB.Guild], "OnClick")
joan.slash("")
-- Stopping sharing with the guild takes away all the guild saw, even from a guildmate who also
-- sees you publicly; what everyone may see comes back when asked for. Guild bank tabs waiting for
-- their turn or for a fight to end stay home: the goodbye is all the guild hears.
joan.slash("share place guild on")
thalia.slash("look " .. lookName("Joan"))
advance(30)
local tjp = peer(thalia, "Joan")
check(tjp and tjp.scopes.g and tjp.scopes.p and tjp.more and tjp.more.live and tjp.more.live.zone == "Darkshore", "Thalia should see Joan both ways, and where she is")
faelwen.ns.send({ kind = "GUILD" }, { t = "ask", to = joan.full, bt = { 1 } })
advance(5)
joan.combat = true
faelwen.ns.send({ kind = "GUILD" }, { t = "ask", to = joan.full, bt = { 1, 2 } })
advance(5)
check(joan.ns.queued() > 0, "the Gear tab should be waiting out Joan's fight")
local sentBefore, loggedBefore = #joan.sent, #world.log
joan.slash("share guild off")
joan.combat = false
advance(130)
local toGuild = 0
for i = sentBefore + 1, #joan.sent do if joan.sent[i].kind == "GUILD" then toGuild = toGuild + 1 end end
check(toGuild == 1, "Joan stopped sharing with the guild, then sent it " .. toGuild .. " messages, not just her goodbye")
for _, m in ipairs(carried(loggedBefore)) do
    check(not (m.from == joan.full and m.msg.t == "gb"), "a bank tab waiting out Joan's fight went after she stopped sharing with the guild")
end
tjp = peer(thalia, "Joan")
check(tjp and tjp.scopes.p and not tjp.scopes.g and not tjp.card and not (tjp.more and next(tjp.more)), "Joan stopped sharing with the guild, but Thalia kept what the guild saw")
thalia.slash("look " .. lookName("Joan"))
advance(30)
tjp = peer(thalia, "Joan")
check(tjp.card and tjp.card.gear and not (tjp.more and tjp.more.live), "Thalia should get back what Joan shows everyone, and only that")
joan.slash("share place guild off")
joan.slash("share guild on")
advance(30)
-- A friend who stopped sharing with friends while you were away (no goodbye reached you), and
-- shares with everyone now: what only friends saw goes the next time you hear from them.
brannoc.zone, brannoc.subzone = "Ironforge", "The Commons"
brannoc.fire("ZONE_CHANGED_NEW_AREA")
advance(5)
brannoc.slash("share place friends on")
brannoc.slash("share stats public off")
advance(30)
local jb = peer(joan, "Brannoc")
check(jb and jb.more and jb.more.live.zone == "Ironforge" and jb.card.stats, "Joan should see where Brannoc is, and his character sheet")
joan.online = false
brannoc.slash("share friends off")
brannoc.slash("share public on")
advance(10)
joan.online = true
joan.slash("look " .. lookName("Brannoc"))
-- Not for a moment after hearing it (before his public card comes) does she hold what only his
-- friends saw.
for _ = 1, 100 do
    advance(0.05)
    jb = peer(joan, "Brannoc")
    if jb and not jb.scopes.f then
        check(not (jb.card and jb.card.stats) and not (jb.more and jb.more.live), "Joan still held Brannoc's friends-only parts after hearing he shares only with everyone")
    end
end
advance(25)
jb = peer(joan, "Brannoc")
check(jb and jb.scopes.p and not jb.scopes.f and jb.card and jb.card.gear and not jb.card.stats and not (jb.more and jb.more.live),
    "Brannoc stopped sharing with friends while Joan was away: she should see only what he shows everyone")
brannoc.slash("share stats public on")
brannoc.slash("share public off")
brannoc.slash("share friends on")
advance(30)
check(peer(joan, "Brannoc").scopes.f and peer(joan, "Brannoc").more.live.zone == "Ironforge", "Brannoc shares with friends again, but Joan didn't get where he is back")
-- Hearing the same scopes again keeps what came under them: nothing is dropped and sent again.
-- (Once any answer held back for its turn has come, and his gold has.)
advance(60)
local coreAt = peer(joan, "Brannoc").gotAt.core
brannoc.slash("share gold friends on")
advance(60)
check(peer(joan, "Brannoc").more.live.gold == 4242 and peer(joan, "Brannoc").gotAt.core == coreAt, "a hello under the same scopes made Joan ask for Brannoc's card again")
brannoc.slash("share gold friends off")
brannoc.slash("share place friends off")
advance(30)
-- Options > AddOns > Reliquary: the three switches, and the same grid under What others see.
local cat = joan.ui.settings.Reliquary
check(cat and cat.registered and cat.settings.RELIQUARY_SHARE_PUBLIC and cat.sub["What others see"], "the Options panel")
cat.settings.RELIQUARY_SHARE_FRIENDS.set(true)
check(cat.settings.RELIQUARY_SHARE_FRIENDS.get() == true and me.share.friends == true, "the friends switch in Options")
cat.settings.RELIQUARY_SHARE_FRIENDS.set(false)
joan.ui.run(cat.sub["What others see"], "OnShow")
-- There the grid is drawn as the game's own options are, among other addons': the game's check boxes.
do
    local box = joan.ns.settingsMatrix and joan.ns.settingsMatrix.rows[1].boxes[1]
    check(box and rawget(box, "Text") and box.Text._font == "GameFontNormalSmall" and not rawget(box, "tick"), "the Options panel's grid isn't the game's own check boxes")
end

---------------------------------------------------------------------------
-- 6. Nobody can slip a card in: unasked, spoofed, ignored, malformed
---------------------------------------------------------------------------
local function whisper(from, to, msg) from.ns.send({ kind = "WHISPER", target = to.full }, msg) end
whisper(rogue, joan, { t = "sec", n = "core", h = "x", sc = "p", d = { name = "Grift", level = 60, class = "Rogue" } })
advance(20)
check(not peer(joan, "Grift"), "Joan kept a card she never asked for")
-- A hello alone, from a player whose card never comes, keeps nothing either.
rogue.slash("share public off")
whisper(rogue, joan, { t = "hi", s = { core = "r1" }, sc = "p" })
advance(20)
check(not peer(joan, "Grift"), "Joan kept an empty entry for a player who only said hello")
rogue.slash("share public on")
-- A card that claims to be someone else's is kept as its sender's, under the sender's name.
eluned.ns.send({ kind = "WHISPER", target = joan.full }, { t = "hi", s = { core = "zz" }, sc = "p" })
advance(4) -- Joan asks Eluned for the card behind "zz"; a forged one answers first
eluned.ns.send({ kind = "WHISPER", target = joan.full }, { t = "sec", n = "core", h = "zz", sc = "p", d = { name = "Thalia", realm = "Elsewhere", level = 60, class = "Hunter", classFile = "HUNTER" } })
advance(20)
local el = peer(joan, "Eluned")
check(el and el.card.name == fullOf("Eluned"):match("^([^%-]+)") and el.card.realm == (not REGIONAL and REALM or nil), "a card took a name that wasn't its sender's")
check(not (peer(joan, "Thalia") and peer(joan, "Thalia").card.level == 60), "a forged card replaced Thalia's")
-- Looking Eluned up again brings her real card back.
advance(70)
joan.slash("look " .. lookName("Eluned"))
advance(30)
check(peer(joan, "Eluned").card.level == 23, "Eluned's real card didn't replace the forged one")
-- Ignored players are ignored.
joan.ignores[REGIONAL and fullOf("Grift") or "Grift"] = true -- the ignore list names players as the game does
rogue.ns.send({ kind = "WHISPER", target = joan.full }, { t = "hi", s = { core = "abc" }, sc = "p", w = 1 })
advance(20)
check(not peer(joan, "Grift"), "Joan answered a player she ignores")
-- Junk of every shape: never an error, never kept.
local junk = { "", "x", "1", "1AA11", "2AA11hello", "1AA00x", "1AAz1x", "1AA1Z" .. ("A"):rep(250), "1AA11!!!!", "1AA11" .. ("QUFB"):rep(10),
    "1AB11" .. joan.env.C_EncodingUtil.EncodeBase64("not deflate"), "1AC11" .. joan.env.C_EncodingUtil.EncodeBase64(joan.env.C_EncodingUtil.CompressString("not cbor \255", 0)) }
for _, text in ipairs(junk) do joan.fire("CHAT_MSG_ADDON", "Reliquary", text, "WHISPER", rogue.full, joan.full) end
for i = 1, 80 do joan.fire("CHAT_MSG_ADDON", "Reliquary", "1" .. string.format("%02d", i % 100) .. "1Z" .. "AAAA", "WHISPER", "Stranger" .. i .. "-" .. REALM, joan.full) end
advance(100)
check(not peer(joan, "Grift"), "junk was kept")

---------------------------------------------------------------------------
-- 7. Quiet moments, the game's limits, and lost messages
---------------------------------------------------------------------------
-- In a fight, in an instance or in the chat lockdown nothing goes out; afterwards it all does.
thalia.slash("share guild on")
joan.combat = true
local queued = #joan.sent
joan.slash("share friends on")
advance(20)
check(#joan.sent == queued and joan.ns.queued() > 0, "Joan sent messages during a fight")
joan.combat = false
joan.inInstance = true
advance(20)
check(#joan.sent == queued, "Joan sent messages in an instance")
joan.inInstance, joan.lockdown = false, true
advance(20)
check(#joan.sent == queued, "Joan sent messages during the chat lockdown")
joan.lockdown = false
advance(60)
check(joan.ns.queued() == 0 and #joan.sent > queued, "the waiting messages didn't go out")
-- A server stricter than the game's own: messages are refused, retried, and all still arrive.
for _, c in ipairs(world.clients) do c.bucketMax, c.bucket = 2, 0 end
thalia.level = 20
thalia.fire("PLAYER_LEVEL_UP", 20)
advance(400)
check(thalia.throttled > 0, "the stricter server never refused anything")
check(peer(joan, "Thalia") and peer(joan, "Thalia").card.level == 20, "a refused message was lost instead of retried")
for _, c in ipairs(world.clients) do c.bucketMax = 10 end
-- The game sends the guild list again now and then: Joan's roster catches up with Thalia's level.
advance(61)
joan.fire("GUILD_ROSTER_UPDATE")
advance(5)
for _, m in ipairs(joan.db().guilds[gk()].members) do
    if m.n == "Thalia" then check(m.lv == 20, "the roster didn't catch up with Thalia's level") end
end
-- No addon ever sends faster than the game allows: at most 14 in any 10 seconds.
for _, c in ipairs(world.clients) do
    for i, m in ipairs(c.sent) do
        local n = 0
        for k = i, #c.sent do if c.sent[k].at - m.at < 10 then n = n + 1 end end
        check(n <= 14, c.name .. " sent " .. n .. " messages in ten seconds")
    end
end

---------------------------------------------------------------------------
-- 8. The window, with all of this in it
---------------------------------------------------------------------------
-- A player's window laid out: nothing in it lies over anything else or runs out of it
-- (tests/wowui.lua). With RELIQUARY_LAYOUT set to a folder, each place checked is written there too.
local layouts = 0
local texts -- below
-- Words a player reads that the game wouldn't say: "reliquary" in lower case is the addon's own word
-- for a player's record, never something to put in front of them ("2 share a reliquary"); the
-- addon's name, Reliquary, is fine.
function world.plainWords(where, said) -- a field, not a local: the main chunk is at Lua 5.1's two hundred
    local at = said:find("reliquar", 1, true)
    check(not at, where .. ": says \"" .. said:sub(math.max(1, (at or 1) - 40), (at or 1) + 40) .. "\"")
end
local function laidOut(c, where)
    local win = c.env.ReliquaryFrame
    check(win and win:IsShown(), where .. ": the window isn't open, so nothing in it can be checked")
    world.plainWords(where, texts(c))
    local over = c.ui.overlaps(win)
    check(#over == 0, where .. ": " .. table.concat(over, "; "))
    local box = c.ui.rect(win)
    local out = c.ui.outside(win, box)
    check(#out == 0, where .. " runs out of the window: " .. table.concat(out, "; "))
    local lost = c.ui.unplaced(win)
    check(#lost == 0, where .. ": nowhere to be seen: " .. table.concat(lost, "; "))
    local dir = os.getenv("RELIQUARY_LAYOUT")
    if dir and not os.getenv("RQ_NAMES") then
        layouts = layouts + 1
        c.ui.writeLayout(("%s/share-%02d %s.json"):format(dir, layouts, where), win)
    end
end

-- Every text on screen in a player's game: shown, under shown frames, and not see-through.
function texts(c)
    local all = {}
    for _, r in ipairs(c.ui.regions) do
        if r._kind == "FontString" and r._text and r._text ~= "" and r:IsVisible() and (r._alpha or 1) > 0 then all[#all + 1] = r._text end
    end
    return table.concat(all, "\n")
end
joan.slash("")
local win = joan.env.ReliquaryFrame
check(win:IsShown() and win.selectedTab == TAB.Guild, "Joan's window")
local shown = texts(joan)
check(shown:find("<The Moonwell Circle>", 1, true) and shown:find("12 members", 1, true), "the guild tab: " .. shown:sub(1, 300))
-- Its name, counts and switch head the rail (docs/DESIGN.md, section 3): inside the rail, above its
-- search field, not in the space for the list and the pages.
do
    local title
    for _, f in ipairs(joan.ui.regions) do if f._kind == "FontString" and f._text == "<The Moonwell Circle>" and f:IsVisible() then title = f end end
    local panel
    for _, f in ipairs(joan.ui.frames) do if rawget(f, "browser") and f:IsVisible() then panel = f end end
    local b = panel and panel.browser
    local t, rail, search = joan.ui.rect(title), b and joan.ui.rect(b.rail), b and joan.ui.rect(b.search)
    local only = panel and joan.ui.rect(panel.only)
    check(t and rail and search and only and t.left >= rail.left and t.right <= rail.right + 0.5 and t.bottom >= search.top - 0.5 and only.bottom >= search.top - 0.5,
        "the guild's name and switch don't head the rail")
    -- The header as the Characters tab's: the name, its counts 5 under it; under them the message of the
    -- day, two lines at most, whole on hover; the switch a gap (12, on the 4-unit grid) under the words,
    -- and the search a gap under the switch. With no message, the switch comes up under the counts.
    local rect, g = joan.ui.rect, joan.db().guilds[gk()]
    local saved = g.motd
    local function near(a, x) return math.abs(a - x) < 0.01 end
    local function header()
        joan.ui.run(win.Tabs[TAB.Guild], "OnClick")
        return rect(panel.title), rect(panel.summary), rect(panel.motd), rect(panel.onlyRow), rect(b.search), rect(b.rail)
    end
    g.motd = ("Raid nights are Tuesday and Thursday at eight; bring potions, food and your own repairs. "):rep(3)
    local tr, cr, mr, sw, sr, rr = header()
    check(panel.motd:IsShown() and panel.motd._maxLines == 2 and panel.motd:IsTruncated() and near(tr.left, rr.left + 16) and near(cr.top, tr.bottom - 5)
        and near(mr.top, cr.bottom - 4) and math.abs(mr.left - tr.left) < 0.01 and (rr.top - sw.top) % 4 == 0 and sw.top <= mr.bottom - 12 and sw.top > mr.bottom - 16
        and near(sr.top, sw.bottom - 12), "a long message of the day isn't cut to two lines over the switch and the search")
    joan.env.GameTooltip._texts = {}
    joan.ui.run(panel.motdHover, "OnEnter")
    check(joan.env.GameTooltip._shown and table.concat(joan.env.GameTooltip._texts, " "):find(g.motd, 1, true), "the whole message of the day isn't shown on hover")
    joan.ui.run(panel.motdHover, "OnLeave")
    g.motd = nil
    tr, cr, mr, sw, sr = header()
    check(not panel.motd:IsShown() and not panel.motdHover:IsShown() and sw.top <= cr.bottom - 12 and sw.top > cr.bottom - 16 and near(sr.top, sw.bottom - 12),
        "with no message of the day, the switch doesn't come up under the counts")
    g.motd = saved
    header()
end
local list
for _, f in ipairs(joan.ui.frames) do if f._rows and f:IsVisible() and #f._rows > 0 and f._rows[1].row then list = f break end end
check(list and #list._rows == 14 and list._rows[1].row.chat == "guild" and list._rows[2].row.chat == "officer",
    "the roster list: the guild's chat and, for Joan, an officer, its officer chat first, then its twelve members")
local thaliaRow
for _, row in ipairs(list._rows) do if row.row.key == fullOf("Thalia") then thaliaRow = row end end
check(thaliaRow and thaliaRow.gem:IsShown(), "Thalia's row should show she shares")
-- Under each name, what the guild's list knows: their rank, then where they are, or when they were
-- last on.
do
    local function rowOf(given) for _, row in ipairs(list._rows) do if row.row.name and row.row.name:find("^" .. given) then return row end end end
    local saeli, orlan = rowOf("Saeli"), rowOf("Orlan")
    check(saeli and saeli.info:IsShown() and saeli.info._text == "Member · Teldrassil" and orlan and orlan.info._text == "Officer · 2 days ago",
        "a guildmate's line under their name: " .. tostring(saeli and saeli.info._text) .. ", " .. tostring(orlan and orlan.info._text))
end
joan.ui.run(thaliaRow, "OnClick")
-- The page chosen earlier (Quests) stays chosen from player to player while they have it.
for _, f in ipairs(joan.ui.frames) do if f.page == "gear" and f:IsVisible() then joan.ui.run(f, "OnClick") end end
shown = texts(joan)
check(shown:find("Thalia", 1, true) and shown:find("Level 20", 1, true) and shown:find("Tailoring", 1, true), "Thalia's reliquary in the window")
laidOut(joan, "Thalia's gear, on the Guild tab")
-- Her talents: those she learned, tree by tree, each with its rank on a plate, its line gold when
-- learned in full and green in part, as the game's own talent frame colours them; no Legacy (it is her
-- own record's alone).
do
    for _, f in ipairs(joan.ui.frames) do if f.page == "tal" and f:IsVisible() then joan.ui.run(f, "OnClick") end end
    local d
    for _, f in ipairs(joan.ui.frames) do if rawget(f, "talentButtons") and f:IsVisible() then d = f end end
    local shownTalents, state, plate = {}, {}, {}
    for _, b in ipairs(d and d.talentButtons or {}) do
        if b:IsShown() then
            shownTalents[#shownTalents + 1] = b.talent.name .. " " .. b.talent.rank
            state[b.talent.name], plate[b.talent.name] = b.state, b.plate.text._text
        end
    end
    check(#shownTalents > 0 and #shownTalents == #(thalia.ns.ownCard(thalia.db().chars[thalia.ns.charKey]).card.tal.n), "Thalia's learned talents: " .. table.concat(shownTalents, ", "))
    check(state["Inner Fire"] == "full" and state["Holy Specialization"] == "part" and plate["Inner Fire"]:match("^(%d+)/%1$"),
        "the talents' ranks: " .. tostring(state["Inner Fire"]) .. " " .. tostring(plate["Inner Fire"]))
    check(d.treeCards[1].label._text == "DISCIPLINE" and not d.legacyCard:IsShown(), "a priest's trees by name: " .. tostring(d.treeCards[1].label._text))
    -- A row of talents still shows its tree's whole painting at the card's width, as the game's own
    -- talent window shows it, the talents at its top.
    local card, art = joan.ui.rect(d.treeCards[1]), d.treeCards[1].art.frame
    check(card and art._h >= art._w * 384 * 0.85 / 256 - 4 and math.abs((card.top - card.bottom) - (28 + art._h + 8)) < 0.01,
        "Thalia's trees show a strip of their paintings: " .. tostring(art._h))
    laidOut(joan, "Thalia's talents")
end
for _, page in ipairs({ "bags", "bank", "reps", "quests", "craft", "rp" }) do
    for _, f in ipairs(joan.ui.frames) do
        if f.page == page and f:IsVisible() then
            joan.ui.run(f, "OnClick")
            laidOut(joan, "Thalia's " .. page)
        end
    end
end
for _, f in ipairs(joan.ui.frames) do if f.page == "gear" and f:IsVisible() then joan.ui.run(f, "OnClick") end end
-- Her reputation, a card for the Alliance: each faction with its standing at the right in its words, on
-- a bar in the game's colour for it, how far into it on hover. Her quests, each with its level on a
-- plate in the colour of how hard it is for her; one she can turn in says so on a verdant chip, and an
-- objective that counts has a bar beside it as far along as it is.
do
for _, f in ipairs(joan.ui.frames) do if f.page == "reps" and f:IsVisible() then joan.ui.run(f, "OnClick") end end
local repRow, repCard
for _, f in ipairs(joan.ui.frames) do
    if f._rows and f:IsVisible() then
        for _, el in ipairs(f._rows) do
            for _, c in ipairs(el.cards or {}) do
                for _, r in ipairs(c.repRows or {}) do if r:IsShown() and r.line and r.line.name == "Darnassus" then repRow, repCard = r, c end end
            end
        end
    end
end
check(repRow and repCard.title._text == "Alliance" and repRow.standing._text == "Honored" and repRow.bar:IsShown() and repRow.bar.target > 0
    and repRow.line.color and repRow.line.color[2] == 0.6, "Darnassus on the reputation bar")
local br, bg = repRow.bar.fill:GetColor()
check(br == repRow.line.color[1] and bg == 0.6, "Darnassus's bar isn't in Honored's colour")
joan.ui.run(repRow, "OnEnter")
local into = repRow.standing._text
joan.ui.run(repRow, "OnLeave")
check(into:find(" / ", 1, true) and repRow.standing._text == "Honored", "how far into Honored, on hover: " .. tostring(into))
for _, f in ipairs(joan.ui.frames) do if f.page == "quests" and f:IsVisible() then joan.ui.run(f, "OnClick") end end
local questRow, readyRow, objRow
for _, f in ipairs(joan.ui.frames) do
    if f._rows and f:IsVisible() then
        for _, el in ipairs(f._rows) do
            for _, c in ipairs(el.cards or {}) do
                for _, r in ipairs(c.questRows or {}) do
                    if r:IsShown() and r.line then
                        questRow = questRow or r
                        if r.line.done then readyRow = r end
                    end
                end
                for _, r in ipairs(c.objRows or {}) do if r:IsShown() and r.line and r.line.need then objRow = objRow or r end end
            end
        end
    end
end
check(questRow, "Thalia's quests show no quest")
local pr, pg, pb = questRow.plate.level:GetTextColor()
check(questRow.plate:IsShown() and questRow.line.color and pr == 1 and math.abs(pg - 0.82) < 0.001 and pb == 0,
    "a quest's plate in the quest log's colour for its level")
check(questRow.ready:IsShown() == false and readyRow and readyRow.ready:IsShown() and readyRow.ready.text._text == "Ready to turn in",
    "a quest she can turn in says so, and only that one")
local vr, vg, vb = joan.ns.Skin.rgb("verdant")
local cr, cg, cb = readyRow.ready.text:GetTextColor()
check(cr == vr and cg == vg and cb == vb, "Ready to turn in isn't verdant")
check(objRow and objRow.text._text == "Moonwell water: 3/5" and objRow.bar:IsShown() and math.abs(objRow.bar.target - 0.6) < 1e-9,
    "an objective that counts has its bar: " .. tostring(objRow and objRow.text._text))
end
for _, f in ipairs(joan.ui.frames) do if f.page == "gear" and f:IsVisible() then joan.ui.run(f, "OnClick") end end
-- Item buttons show her gear, and its tooltip is the item's own.
local maceButton
for _, f in ipairs(joan.ui.frames) do if f._kind == "ItemButton" and f.rq and f.rq.id == 2075 and f:IsVisible() then maceButton = f end end
check(maceButton and maceButton._icon == 133476, "Thalia's mace in the window")
joan.ui.run(maceButton, "OnEnter")
check(joan.env.GameTooltip._link:match("^item:2075:"), "the mace's tooltip")
-- The guild bank tab: four tabs for an officer, the Officers tab included; search dims the rest.
joan.ui.run(win.Tabs[TAB.Bank], "OnClick")
local bankButtons = 0
for _, f in ipairs(joan.ui.frames) do if f._kind == "CheckButton" and f.index and f:IsVisible() then bankButtons = bankButtons + 1 end end
check(bankButtons == 4, "Joan should see 4 bank tabs, saw " .. bankButtons)
shown = texts(joan)
check(shown:find("Reagents", 1, true) and shown:find("Guild bank: 128g 73s 44c", 1, true), "the bank tab's text: " .. shown:sub(1, 300))
-- Under the slots, the tab's latest moves from its log, newest first.
do
    local bank
    for _, f in ipairs(joan.ui.frames) do if rawget(f, "latest") and f:IsVisible() then bank = f end end
    local lines = {}
    for _, pair in ipairs(bank and bank.latest.lines or {}) do
        if (pair.left._text or "") ~= "" then lines[#lines + 1] = (pair.left._text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) end
    end
    check(bank and bank.latest:IsVisible() and #lines == 2 and lines[1]:find("put in 13 [Peacebloom]", 1, true),
        "the Reagents tab's latest moves under its slots: " .. table.concat(lines, " / "))
    -- How it looks (docs/DESIGN.md, section 5): the tab's name heads the body, as a rail's header does;
    -- the bank's tabs down the right, 48 apart, the chosen one ringed in gold and the others resting
    -- dimmer; Items, Log and Gold log with the marker under Items; the 98 slots on one card, in seven
    -- pairs of columns spread across it, numbered down each column as at the bank; the latest moves on a
    -- card as tall as its two lines; the bank's gold a chip along the foot.
    local Skin = joan.ns.Skin
    local ring, dim = {}, {}
    for i, t in ipairs(bank.tabs) do
        if t:IsShown() then
            local r, g = t.face.line:GetColor()
            ring[#ring + 1] = (r == Skin.C.gold300[1] and g == Skin.C.gold300[2]) and "gold" or (r == Skin.C.ink600[1] and "quiet" or "?")
            dim[#dim + 1] = t.face.icon:GetAlpha() < 1 and "dim" or "lit"
            if i > 1 then check(t._points.TOPRIGHT.y == bank.tabs[i - 1]._points.TOPRIGHT.y - 48, "the bank's tabs aren't 48 apart down the right") end
        end
    end
    check(table.concat(ring, ",") == "gold,quiet,quiet,quiet" and table.concat(dim, ",") == "lit,dim,dim,dim", "the bank's tabs: " .. table.concat(ring, ",") .. " " .. table.concat(dim, ","))
    check(bank.tabName._text == "Reagents" and bank.seen._text:find("^As Joan saw it, ") and bank.views.chosen == "items" and bank.views.marker:IsShown(),
        "the bank's header and its views: " .. tostring(bank.tabName._text) .. " | " .. tostring(bank.seen._text))
    local pair = (874 - 24 - 7 * 84) / 6
    check(bank.slots[8]._points.TOPLEFT.x == 44 and bank.slots[15]._points.TOPLEFT.x == math.floor(84 + pair + 0.5)
        and bank.slots[98]._points.TOPLEFT.x == math.floor(6 * (84 + pair) + 44 + 0.5) and bank.slots[2]:GetParent() == bank.slotRows[2]
        and bank.slots[14]:GetParent() == bank.slotRows[7], "the bank's slots aren't in seven pairs of columns across their card")
    local line = bank.latest.lines[1].left:GetLineHeight()
    check(bank.latest._h == 28 + 16 + 16 + math.floor(line + 0.5), "the latest moves' card isn't as tall as its two lines: " .. tostring(bank.latest._h))
    check(bank.money:IsShown() and bank.money.text._text == "Guild bank: 128g 73s 44c", "the bank's gold: " .. tostring(bank.money.text._text))
    -- With animations on, the window opening on the bank: its tabs, its header and its cards arrive in
    -- order. Another of its tabs: its slots arrive row by row. Its Log: the card comes in from the side
    -- Log lies on.
    local M = joan.ns.Motion
    joan.db().settings.motion = nil
    joan.slash("")
    joan.slash("")
    check(M.enabled() and bank.tabs[1]:GetAlpha() == 0 and bank.tabName:GetAlpha() == 0 and bank.grid:GetAlpha() == 0 and bank.foot:GetAlpha() == 0,
        "the bank's parts show before the window opening brings them")
    for _ = 1, 90 do M.step(1 / 60) end
    check(bank.tabs[1]:GetAlpha() == 1 and bank.tabName:GetAlpha() == 1 and bank.grid:GetAlpha() == 1 and bank.foot:GetAlpha() == 1
        and bank.grid._points.TOPLEFT.y == -44 and bank.tabs[1]._points.TOPRIGHT.y == -44, "the bank's parts didn't arrive")
    joan.ui.run(bank.tabs[2], "OnClick")
    check(bank.slotRows[1]:GetAlpha() == 0 and bank.slotRows[7]:GetAlpha() == 0, "the Gear tab's slots don't arrive")
    for _ = 1, 6 do M.step(1 / 60) end
    check(bank.slotRows[1]:GetAlpha() > bank.slotRows[7]:GetAlpha(), "the Gear tab's slots don't arrive row by row")
    for _ = 1, 60 do M.step(1 / 60) end
    check(bank.slotRows[7]:GetAlpha() == 1 and bank.slotRows[7]._points.TOPLEFT.y == -6 * 44, "the Gear tab's slots didn't come to rest")
    joan.ui.run(bank.tabs[1], "OnClick")
    for _ = 1, 60 do M.step(1 / 60) end
    joan.ui.run(bank.views.buttons.log, "OnClick")
    local slid = M.value(bank.logCard, "slide")
    check(bank.logCard:GetAlpha() == 0 and slid and slid[1] == 16, "the Log card doesn't come in from the right")
    for _ = 1, 60 do M.step(1 / 60) end
    check(bank.logCard:GetAlpha() == 1 and bank.logCard._points.TOPLEFT.x == 16 and bank.views.chosen == "log", "the Log card didn't come to rest")
    joan.ui.run(bank.views.buttons.items, "OnClick")
    joan.db().settings.motion = false
    joan.slash("")
    M.finishAll()
    joan.slash("")
end
local search
for _, f in ipairs(joan.ui.frames) do if f._kind == "EditBox" and f:IsVisible() and f._scripts.OnTextChanged then search = f end end
search:SetText("silverleaf")
joan.ui.run(search, "OnTextChanged")
local lit, dim = 0, 0
for _, f in ipairs(joan.ui.frames) do
    if f._kind == "ItemButton" and f:IsVisible() and f.rq then if f:GetMatchesSearch() ~= false then lit = lit + 1 else dim = dim + 1 end end
end
check(lit == 2 and dim == 7, ("bank search lit %d and dimmed %d"):format(lit, dim)) -- the tab's other seven stacks
laidOut(joan, "the guild bank, searched")
-- Friends and Public.
joan.ui.run(win.Tabs[TAB.Friends], "OnClick")
check(texts(joan):find("Brannoc", 1, true), "Brannoc under Friends")
laidOut(joan, "Friends")
-- Its header as the Guild tab's: the title, its counts under it, the switch a gap under them, the search
-- a gap under the switch.
do
    local panel
    for _, f in ipairs(joan.ui.frames) do if rawget(f, "onlyRow") and f:IsVisible() then panel = f end end
    local rect = joan.ui.rect
    local cr, sw, sr, rr = rect(panel.summary), rect(panel.onlyRow), rect(panel.browser.search), rect(panel.browser.rail)
    check(panel.title._text == "Friends" and sw.top <= cr.bottom - 12 and sw.top > cr.bottom - 16 and (rr.top - sw.top) % 4 == 0
        and math.abs(sr.top - (sw.bottom - 12)) < 0.01, "the Friends tab's switch isn't under its counts, over the search")
end
joan.ui.run(win.Tabs[TAB.Public], "OnClick")
check(texts(joan):find("Eluned", 1, true), "Eluned under Public")
laidOut(joan, "Public")
-- Its look-up heads the rail, inset as the search under it: the field and its button on one line, then
-- what the tab is, then the search, each a gap (12, on the 4-unit grid) under what is over it.
do
    local panel
    for _, f in ipairs(joan.ui.frames) do if rawget(f, "lookup") and f:IsVisible() then panel = f end end
    local rect = joan.ui.rect
    local rail, field, ask, intro, search = rect(panel.browser.rail), rect(panel.lookup), rect(panel.ask), rect(panel.intro), rect(panel.browser.search)
    local function near(a, x) return math.abs(a - x) < 0.01 end
    check(near(field.top, rail.top - 12) and near(field.left, rail.left + 12) and near(ask.right, rail.right - 12) and near(field.left, search.left)
        and near(ask.right, search.right) and near(field.top + field.bottom, ask.top + ask.bottom) and field.right < ask.left
        and intro.top <= field.bottom - 12 and intro.top > field.bottom - 16 and search.top <= intro.bottom - 12 and search.top > intro.bottom - 16
        and (rail.top - search.top) % 4 == 0, "the look-up doesn't head the rail over its words and the search")
    -- The field says what goes in it, in the game's own word, so it isn't taken for the search under it.
    check(panel.lookup.hint._text == "Name" and panel.browser.search.hint._text == "Search", "the look-up's hint: " .. tostring(panel.lookup.hint._text))
end
joan.ui.run(win.Tabs[TAB.Sharing], "OnClick")
check(texts(joan):find("Who sees Joan", 1, true), "the Sharing tab")
laidOut(joan, "Sharing")
joan.ui.run(win.Tabs[TAB.Characters], "OnClick")
laidOut(joan, "Characters")
-- Another player's card can't change your own characters: the tab isn't drawn again for it. A change
-- that doesn't say what it is draws it again.
do
    local list
    for _, f in ipairs(joan.ui.frames) do if f._rows and f:IsVisible() and f._rows[1] and rawget(f._rows[1], "row") then list = f end end
    local before = list._provider
    joan.ns.onDataChanged("peers")
    advance(1)
    check(list._provider == before, "another player's card drew your own characters again")
    joan.ns.onDataChanged()
    advance(1)
    check(list._provider ~= before, "a change that doesn't say what it is didn't draw the tab again")
end
joan.slash("")
-- Thalia's window never shows the Officers tab; Mira's asks her to visit the bank once.
thalia.slash("")
thalia.ui.run(thalia.env.ReliquaryFrame.Tabs[TAB.Bank], "OnClick")
bankButtons = 0
for _, f in ipairs(thalia.ui.frames) do if f._kind == "CheckButton" and f.index and f:IsVisible() then bankButtons = bankButtons + 1 check(f.tabName ~= "Officers", "Thalia sees the Officers tab") end end
check(bankButtons == 3, "Thalia should see 3 bank tabs, saw " .. bankButtons)
-- With nothing to show, the Guild Bank tab is greyed, takes no click and says why on hover.
local function greyedBank(c)
    local w = c.env.ReliquaryFrame
    local tab = w.Tabs[TAB.Bank]
    c.ui.run(tab, "OnClick")
    return not tab:IsEnabled() and w.selectedTab ~= TAB.Bank and tab.reason and tab.reason:find("Open the guild bank once on this character", 1, true) ~= nil
end
mira.slash("")
check(greyedBank(mira), "Mira's bank tab before her first visit")
-- A month after Thalia was last shown the bank, what she may view is no longer known: the window
-- stops showing the tabs until she visits again (her rank may have changed).
for _, v in pairs(thalia.db().guilds[gk()].view) do v.at = v.at - 31 * 86400 end
thalia.ui.run(thalia.env.ReliquaryFrame.Tabs[TAB.Bank], "OnClick")
check(greyedBank(thalia), "Thalia's window still shows the bank a month after her last visit")
for _, v in pairs(thalia.db().guilds[gk()].view) do v.at = v.at + 31 * 86400 end

---------------------------------------------------------------------------
-- 8a. Who can use it: each game weighs the guild's items for its own character, the guild hears,
-- and for anyone who hasn't weighed one yet, your game weighs it from what they share
---------------------------------------------------------------------------
advance(30)
local thaliaShort = fullOf("Thalia"):match("^([^%-]+)")
local jf = joan.db().chars[ownKey(joan)].fits
-- Joan, a level 13 Balance druid: the mace and the Crescent Staff would help her at levels 15 and
-- 16 (they beat her staff); she wears the boots already; she can't use a bow; the gloves are six
-- levels off; herbs aren't gear.
check(jf and jf[2075] and jf[2075].v == "lvl" and jf[2075].lv == 15 and jf[2075].sl == 16 and jf[2075].cn == "Staff of the Quiet Wind", "Joan's verdict on the mace")
check(jf[6505] and jf[6505].v == "lvl" and jf[6505].lv == 16 and jf[6505].il == 21 and jf[6505].ci == 16 and jf[6505].d[1].k == "Spirit"
    and jf[6505].d[1].n == 7 and jf[6505].d[3].k == "Intellect" and jf[6505].d[3].n == 3, "Joan's verdict on the Crescent Staff")
check(jf[264154] and jf[264154].v == "no", "Joan's verdict on the boots she wears")
check(not jf[3742] and not jf[14146] and not jf[765], "Joan has a verdict on a bow, gloves six levels off, or herbs")
-- Thalia's game weighed what she sees, and the guild heard: Joan has Thalia's own verdicts. Only
-- the guild hears them: Brannoc, who sees Joan as anyone may, has none of hers.
local tf = thalia.db().chars[ownKey(thalia)].fits
check(tf and tf[2075] and tf[2075].v == "no" and tf[14146] and tf[14146].v == "no" and not tf[3742] and not tf[264154], "Thalia's own verdicts")
local heard = peer(joan, "Thalia").more.fits
check(heard and #heard.list == 2, "Joan doesn't have Thalia's verdicts")
check(not (peer(brannoc, "Joan").more and peer(brannoc, "Joan").more.fits), "a verdict went beyond the guild")
-- Everyone who can equip the staff, best help first: Thalia, who has never seen the Officers tab,
-- weighed by Joan's game from what she shares (Blizzard's list has her spec, and it beats her
-- mace); then Joan.
local list = joan.ns.whoCanUse(6505)
local function names(l) local o = {} for _, x in ipairs(l) do o[#o + 1] = (x.me and "you" or x.name) .. ":" .. x.v .. (x.own and "" or "?") end return table.concat(o, ", ") end
local function entry(l, who) for _, x in ipairs(l) do if x.who == who then return x end end end
check(#list == 2 and list[1].who == thalia.full and list[1].v == "up" and list[1].own == false and list[1].il == 21 and list[1].ci == 20
    and list[2].me and list[2].v == "lvl", "who can use the staff: " .. names(list))
list = joan.ns.whoCanUse(2075)
check(#list == 2 and list[1].me and list[1].v == "lvl" and list[2].who == thalia.full and list[2].v == "no" and list[2].own, "who can use the mace: " .. names(list))
-- The boots: Blizzard's list names no specs for them, so Joan's game doesn't guess for Thalia (a
-- priest, who can't wear leather); Thalia's own game knows she can't.
list = joan.ns.whoCanUse(264154)
check(#list == 1 and list[1].me and list[1].v == "no", "who can use the boots: " .. names(list))

-- Nobody here can use a bow.
check(#joan.ns.whoCanUse(3742) == 0, "who can use the bow: " .. names(joan.ns.whoCanUse(3742)))
-- Spares in a guildmate's bags are weighed too, but never one bound to them: Thalia shows the guild
-- her bags, with a ring bound to her and a spare one.
thalia.slash("share bags guild on")
advance(700)
local jfits = joan.db().guilds[gk()].fits
check(jfits[264910] and not jfits[264909], "the bound ring was weighed, or the spare one wasn't")
thalia.slash("share bags guild off")
advance(30)
-- Lines on the game's own tooltips, only what there is to say; a setting turns them off. The staff
-- would be an upgrade for Thalia, and the guild bank holds one; the priest's mace and the
-- silverleaf are in the guild bank; nobody has the clam.
check(joan.ns.tooltipLine(6505) == "Upgrade for " .. thaliaShort .. " · Held by the guild bank (1)", "the tooltip lines: " .. tostring(joan.ns.tooltipLine(6505)))
check(joan.ns.tooltipLine(2075) == "Held by the guild bank (1)" and joan.ns.tooltipLine(765) == "Held by the guild bank (27)",
    "the mace's and silverleaf's tooltip lines: " .. tostring(joan.ns.tooltipLine(2075)) .. " / " .. tostring(joan.ns.tooltipLine(765)))
check(joan.ns.tooltipLine(5523) == nil, "a tooltip line with nothing to say")
joan.db().settings.tipLine = false
check(joan.ns.tooltipLine(6505) == nil and #joan.ns.tooltipLines(6505) == 0, "the tooltip lines after they were turned off")
joan.db().settings.tipLine = nil
-- A robe nobody has weighed, which Joan opens. Blizzard's list says it is for priests and mages, so
-- Joan could wear it but it isn't for her. Thalia is offline, so Joan's game weighs it for her from
-- what she shares; once she's back her own game answers the next time Joan asks. Mira could wear
-- it too, but she doesn't show the guild her gear, so she says nothing.
local robe = "item:264150::::::::13:::::"
thalia.online = false
local askedAt = #world.log
check(joan.ns.askWhoCanUse(robe), "Joan's game didn't ask the guild about the robe")
advance(10)
list = joan.ns.whoCanUse(264150)
check(entry(list, thalia.full) and entry(list, thalia.full).own == false and entry(list, thalia.full).v == "trade"
    and entry(list, joan.full) and entry(list, joan.full).v == "no", "the robe while Thalia is offline: " .. names(list))
thalia.online = true
advance(301)
joan.ns.askWhoCanUse(robe)
advance(10)
local tr = entry(joan.ns.whoCanUse(264150), thalia.full)
check(tr and tr.own == true and tr.v == "trade" and tr.cn == "Starfall Robe", "Thalia's own answer about the robe")
for _, m in ipairs(carried(askedAt)) do check(not (m.msg.t == "fit" and m.from == mira.full), "Mira answered though she doesn't show the guild her gear") end
-- The window: the Officers tab marks the staff with the game's upgrade arrow; a click opens its page
-- (who can use it, best first, and the addresses to copy); Ctrl-click tries it on; Shift-click
-- links it in chat; Back returns to the bank.
local function bankTabButton(c, i) for _, f in ipairs(c.ui.frames) do if f._kind == "CheckButton" and f.index == i and f:IsVisible() then return f end end end
local function button(c, label) -- a button or small tab on a page, not one of the window's own tabs
    for _, f in ipairs(c.ui.frames) do
        local text = f._text or (rawget(f, "Text") and f.Text._text) or (rawget(f, "label") and f.label._text)
        if f._kind == "Button" and text == label and f:IsVisible() and not (f:GetName() or ""):find("^ReliquaryFrameTab") then return f end
    end
end
joan.ns.showViewer(TAB.Bank)
joan.ui.run(bankTabButton(joan, 3), "OnClick")
local staff
for _, f in ipairs(joan.ui.frames) do if f._kind == "ItemButton" and f.rq and f.rq.id == 6505 and f:IsVisible() and f ~= joan.ns.itemPage.icon then staff = f end end
check(staff and staff.up:IsShown(), "the staff's upgrade arrow in the bank")
joan.ui.run(staff, "OnClick")
shown = texts(joan)
local boxes = {}
for _, f in ipairs(joan.ui.frames) do if f._kind == "EditBox" and f:IsVisible() and f._text then boxes[#boxes + 1] = f._text end end
boxes = table.concat(boxes, " ")
check(joan.ns.itemPage:IsVisible() and shown:find("WHO CAN USE IT", 1, true) and shown:find("At level 16", 1, true) and shown:find("Upgrade", 1, true)
    and shown:find("from what they share", 1, true) and shown:find("+3 Intellect", 1, true) and shown:lower():find("the guild bank has 1.", 1, true)
    and boxes:find("https://www.wowhead.com/forever/item=6505", 1, true) and boxes:find("https://foreverdb.net/item/6505", 1, true), "the staff's page: " .. shown:sub(1, 900))
joan.env.IsModifiedClick = function(k) return k == "DRESSUP" end
joan.ui.run(staff, "OnClick")
joan.env.IsModifiedClick = function(k) return k == "CHATLINK" end
joan.env.ChatFrameUtil.InsertLink = function(l) joan.chatLinked[#joan.chatLinked + 1] = l return true end
joan.ui.run(staff, "OnClick")
joan.env.IsModifiedClick = function() return false end
check(#joan.dressedUp == 1 and joan.dressedUp[1]:find("item:6505", 1, true) and #joan.chatLinked == 1 and joan.chatLinked[1]:find("|h[", 1, true)
    and not joan.chatLinked[1]:find("|h[]|h", 1, true), "Ctrl-click and Shift-click on an item, with the game's own link: " .. tostring(joan.chatLinked[1]))
check(joan.ns.itemPage:IsVisible(), "a modified click opened nothing over the item's page")
check((joan.ns.itemPage.meta._text or ""):find("Item level", 1, true), "the staff's item level: " .. tostring(joan.ns.itemPage.meta._text))
laidOut(joan, "the staff's page")
check(joan.ns.itemPage.linkNote._text:find("(Ctrl+C)", 1, true), "the copy key on a Windows or Linux client: " .. tostring(joan.ns.itemPage.linkNote._text))
-- Everyone it would help is listed, however many: the list scrolls rather than stopping at eight.
do
    local real = joan.ns.whoCanUse
    joan.ns.whoCanUse = function()
        local list = {}
        for i = 1, 12 do list[i] = { who = "Guildmate" .. i, name = "Guildmate " .. i, v = i <= 10 and "up" or "no", lv = 20, level = 20, cls = "MAGE", own = true } end
        return list
    end
    joan.ns.itemPage.redraw()
    local people, fold = 0, nil
    for _, card in ipairs(joan.ns.itemPage.who._rows) do
        for _, r in ipairs(card:IsShown() and card.lines or {}) do if r.x then people = people + 1 elseif r.names then fold = r end end
    end
    check(people == 10 and fold and #fold.names == 2, "the item's page lists everyone it would help, not eight: " .. people)
    laidOut(joan, "the staff's page, twelve who could use it")
    joan.ns.whoCanUse = real
    joan.ns.itemPage.redraw()
end
-- Escape steps back from the item's page to the bank, and closes the window after that.
do
    local function escape() for _, name in ipairs(joan.env.UISpecialFrames) do local f = joan.env[name] if f and f:IsShown() then f:Hide() end end end
    escape()
    check(not joan.ns.itemPage:IsVisible() and joan.env.ReliquaryFrame:IsShown() and bankTabButton(joan, 3), "Escape on the item's page")
    joan.ui.run(staff, "OnClick")
end
-- Your characters change (a scan): the open item's page follows what they hold of it.
do
    local me = joan.db().chars[joan.ns.charKey]
    me.bags = me.bags or {}
    table.insert(me.bags, { size = 4, bag = 4, slots = { [1] = { id = 6505, n = 1, name = "Staff" } } })
    joan.ns.onOwnChanged()
    advance(1)
    check(texts(joan):find("Your characters have 1", 1, true), "the staff's page after a scan: " .. texts(joan):sub(1, 400))
    table.remove(me.bags)
    joan.ns.onOwnChanged()
    advance(1)
end
joan.ui.run(button(joan, "Back"), "OnClick")
check(not joan.ns.itemPage:IsVisible(), "Back didn't close the item's page")
-- An item the game hasn't loaded yet: Shift-click puts its link into the chat box that was open at the
-- click once it arrives, and into nothing when that box has closed by then.
do
    local real = joan.env.C_Item.GetItemInfo
    joan.env.C_Item.GetItemInfo = function(x)
        local id = tonumber(tostring(x):match("item:(%d+)") or x)
        if id and not joan.itemCache[id] then return nil end
        return real(x)
    end
    local box = { focus = true }
    function box.HasFocus(self) return self.focus end
    joan.env.ChatFrameUtil.InsertLink = function(l) joan.chatLinked[#joan.chatLinked + 1] = l return true end
    joan.env.ChatFrameUtil.GetActiveWindow = function() return box.focus and box or nil end
    local before, saved = #joan.chatLinked, staff.rq
    for _, closeFirst in ipairs({ false, true }) do
        staff.rq = { id = 6505, s = "item:6505::::::::20:::::" } -- as a guildmate's gear comes: an item string, no link yet
        joan.itemCache[6505] = nil
        box.focus = true
        joan.env.IsModifiedClick = function(k) return k == "CHATLINK" end
        joan.ui.run(staff, "OnClick")
        joan.env.IsModifiedClick = function() return false end -- Shift let go before the item arrives
        if closeFirst then box.focus = false end
        advance(2)
    end
    check(#joan.chatLinked == before + 1 and joan.chatLinked[#joan.chatLinked]:find("|Hitem:6505", 1, true),
        "Shift-click on an item not loaded yet: " .. (#joan.chatLinked - before) .. " links")
    joan.env.C_Item.GetItemInfo = real
    joan.itemCache[6505] = true
    staff.rq = saved
end
-- Closed with an item's page open, the window opens again on its tab.
joan.ui.run(staff, "OnClick")
joan.slash("")
joan.slash("")
check(joan.env.ReliquaryFrame:IsShown() and not joan.ns.itemPage:IsVisible() and bankTabButton(joan, 3), "the item's page outlived the window")
joan.slash("")

---------------------------------------------------------------------------
-- 8b. Total RP 3: those who share have their profile fetched by Total RP 3 itself, shown in the
-- window as plain text, and opened in Total RP 3 at a click
---------------------------------------------------------------------------
world.trpProfiles[thalia.full] = {
    characteristics = { FN = "Thalia", LN = "Moonwhisper", TI = "Keeper of the Moonwell", FT = "Thalia Moonwhisper, |cffff0000Keeper|r of the Moonwell",
        RA = "Night Elf", CL = "Priestess", AG = "Young, for a kaldorei", EC = "Silver", HE = "Tall", BP = "Darnassus", RE = "Auberdine",
        MI = { { ID = 3, VA = "Thal" }, { NA = "Motto", VA = "{col:ff0000}Elune lights the way{/col}" } } },
    character = { RP = 1, XP = 2, WU = 2, CU = "Tending the moonwell {col:ff0000}at dusk{/col} |cffff0000now|r |Hitem:765::::|h[Silverleaf]|h |TInterface\\Icons\\X:16|t",
        CO = "Happy to roleplay, just whisper." },
    misc = { PE = { ["1"] = { AC = true, TI = "Silver circlet" }, ["2"] = { AC = false, TI = "A hidden glance" }, ["3"] = { AC = true, TI = "Moonwell water" } } },
}
-- Hearing Thalia say hello asks Total RP 3 for her profile: once, not again for fifteen minutes,
-- and never in a fight.
advance(16 * 60)
local function asks(c, who) local n = 0 for _, id in ipairs(c.trpQueries) do if id == who.full then n = n + 1 end end return n end
local before8b = asks(joan, thalia)
thalia.slash("share played guild on")
advance(5)
check(asks(joan, thalia) == before8b + 1, "hearing Thalia's hello didn't ask Total RP 3 for her profile")
thalia.slash("share played guild off")
advance(60)
check(asks(joan, thalia) == before8b + 1, "Total RP 3 was asked for Thalia's profile twice within fifteen minutes")
check(not (mira.trpQueries), "Mira has no Total RP 3, and nothing pretended she did")
advance(16 * 60)
joan.combat = true
thalia.slash("share played guild on")
advance(5)
check(asks(joan, thalia) == before8b + 1, "Total RP 3 was asked for a profile in a fight")
joan.combat = false
thalia.slash("share played guild off")
advance(30)
-- Joan's window: Thalia's Roleplay page fills itself in the moment Total RP 3 has her profile.
advance(16 * 60)
joan.trpKnown[thalia.full] = nil
joan.slash("")
local jwin2 = joan.env.ReliquaryFrame
joan.ui.run(jwin2.Tabs[TAB.Guild], "OnClick")
local function rowFor(c, who)
    for _, f in ipairs(c.ui.frames) do
        if f._rows and f:IsVisible() then
            for _, row in ipairs(f._rows) do if row.row and row.row.key == who and row:IsVisible() then return row end end
        end
    end
end
joan.ui.run(rowFor(joan, fullOf("Faelwen")), "OnClick") -- away from Thalia, so coming back to her asks again
joan.ui.run(rowFor(joan, thalia.full), "OnClick")
local rpPage, detail
for _, f in ipairs(joan.ui.frames) do
    if f.page == "rp" and f:IsVisible() then rpPage = f end
    if f.rp and f.rpButton and f:IsVisible() then detail = f end
end
-- A list of paragraphs as it reads, one paragraph to a line.
function world.listText(list)
    local t = {}
    for _, r in ipairs(list._rows or {}) do if r:IsShown() and rawget(r, "text") then t[#t + 1] = r.text._text or "" end end
    return table.concat(t, "\n")
end
check(rpPage and detail, "Thalia's reliquary has no Roleplay page in Joan's window")
joan.ui.run(rpPage, "OnClick")
-- The profile's card: its header (the name, or why there is none yet, beside the button), then what it says.
function world.profileText(d) return (d.rpTitle._text or "") .. "\n" .. world.listText(d.rp) end
check(detail.rpCard:IsVisible() and world.profileText(detail):find("Total RP 3 has no profile for " .. fullOf("Thalia"):match("^([^%-]+)") .. " yet", 1, true)
    and not detail.rp:IsShown(), "before Total RP 3 has her profile, the page should say it asked: " .. world.profileText(detail))
-- Total RP 3 has her profile now and says so: the page shows it at once, with no time passing.
joan.trpKnown[thalia.full] = world.trpProfiles[thalia.full]
for _, fn in ipairs(joan.trpCallbacks) do fn(joan.env.TRP3_Addon, thalia.full, "P", "characteristics") end
local shownRP = world.profileText(detail)
laidOut(joan, "Thalia's profile")
-- One reading card: her name in its header beside the button; what Total RP 3 says of her, then each
-- part it names under that name as a section label (the label face, upper case), in Total RP 3's
-- order; room between a paragraph's lines; Reliquary's colours in place of the game's; the card as
-- tall as what it holds.
do
    local kinds, labels = {}, {}
    for _, r in ipairs(detail.rp._rows) do
        kinds[#kinds + 1] = r.line.kind
        if r.line.kind == "label" then
            labels[#labels + 1] = r.text._text
            check(r.text._font:GetFont() == joan.ns.Skin.CINZEL, "a section label isn't in the label face")
        else check(r.text._spacing == 6, "a paragraph's lines are " .. tostring(r.text._spacing) .. " apart") end
    end
    kinds = table.concat(kinds, ",")
    check(joan.ui.plain(detail.rpTitle._text):find("^Thalia Moonwhisper  Keeper of the Moonwell") and table.concat(labels, ",") == "CURRENTLY,OUT OF CHARACTER,AT FIRST GLANCE"
        and kinds == "para,para,para,para,label,para,label,para,label,para", "Thalia's reading card: " .. kinds .. " | " .. table.concat(labels, ","))
    check(not shownRP:find(joan.ns.GOLD, 1, true) and not shownRP:find(joan.ns.GREY, 1, true) and shownRP:find(joan.ns.Skin.code("dim"), 1, true),
        "Thalia's profile is in the game's colours, not the window's")
    local card, used = joan.ui.rect(detail.rpCard), 0
    for _, r in ipairs(detail.rp._rows) do used = used + r._extent end
    check(card and math.abs((card.top - card.bottom) - (48 + 20 + used - 12 + 20)) < 0.01 and detail.rpButton:IsVisible(), "Thalia's card isn't as tall as what it holds")
end
-- With animations on, the page coming into view brings her card's words in a paragraph at a time.
do
    local M = joan.ns.Motion
    M.setEnabled(true)
    joan.ui.run(button(joan, "Gear"), "OnClick")
    joan.ui.run(button(joan, "Roleplay"), "OnClick")
    local first, last = detail.rp._rows[1].text, detail.rp._rows[#detail.rp._rows].text
    check(detail.rpTitle:GetAlpha() == 0 and first:GetAlpha() == 0 and last:GetAlpha() == 0, "Thalia's profile didn't arrive")
    M.step(0.05)
    check(first:GetAlpha() > last:GetAlpha(), "Thalia's profile doesn't arrive a paragraph at a time")
    for _ = 1, 60 do M.step(1 / 60) end
    check(detail.rpTitle:GetAlpha() == 1 and last:GetAlpha() == 1, "Thalia's profile didn't land")
    M.finishAll()
    M.setEnabled(false)
end
-- However long a profile runs, all of it: the card is the page's height and scrolls, a row to a
-- paragraph, each as tall as it wraps.
do
    local long, body = {}, {}
    for i = 1, 40 do
        long[i] = "Paragraph " .. i .. ": " .. ("the moonwell's waters run deep and cold "):rep(i % 5 + 1)
        body[i] = { kind = "para", left = long[i] }
    end
    detail.setProfile({ head = "", body = body })
    local rows, tall = #detail.rp._rows, 0
    for _, r in ipairs(detail.rp._rows) do if r._extent > 30 then tall = tall + 1 end end
    local card = joan.ui.rect(detail.rpCard)
    check(rows == 40 and detail.rp._rows[40].text._text == long[40] and tall > 0 and math.abs((card.top - card.bottom) - joan.ns.V.PAGE_HEIGHT) < 0.01,
        "a long profile: " .. rows .. " paragraphs, " .. tall .. " wrapped")
    laidOut(joan, "a long profile")
end
check(shownRP:find("Thalia Moonwhisper", 1, true) and shownRP:find("Keeper of the Moonwell", 1, true) and shownRP:find("In character", 1, true)
    and shownRP:find("Veteran", 1, true) and shownRP:find("Walkup friendly", 1, true) and shownRP:find("Silver circlet, Moonwell water", 1, true)
    and shownRP:find("Thal", 1, true) and shownRP:find("Elune lights the way", 1, true), "Thalia's profile on her Roleplay page: " .. shownRP)
-- Her text is shown plain: other players' colour codes, links, textures and tags taken out.
check(shownRP:find("Tending the moonwell at dusk now [Silverleaf]", 1, true) and not shownRP:find("A hidden glance", 1, true)
    and not shownRP:find("|Hitem", 1, true) and not shownRP:find("|TInterface", 1, true) and not shownRP:find("{col", 1, true)
    and not shownRP:find("|cffff0000Keeper", 1, true), "Thalia's text wasn't made plain: " .. shownRP)
joan.ui.run(detail.rpButton, "OnClick")
check(joan.trpOpened == thalia.full, "Open in Total RP 3 opened " .. tostring(joan.trpOpened))
-- A guildmate who doesn't use Reliquary: her pages are your whispers with her, and what Total RP 3
-- already knows of her, with the button.
joan.ui.run(rowFor(joan, fullOf("Faelwen")), "OnClick")
-- (The page chosen on Thalia's, Roleplay, stays chosen: Faelwen has one too.)
check(button(joan, "Whispers") and button(joan, "Roleplay") and not button(joan, "Gear"), "Faelwen's pages aren't her whispers and her profile")
joan.ui.run(button(joan, "Roleplay"), "OnClick")
local note = world.profileText(detail)
check(note:find("Faelwen Duskleaf", 1, true) and note:find("Warden of the Glade", 1, true)
    and note:find("Keeping watch over Auberdine's shore.", 1, true) and detail.rpButton:IsVisible(), "Faelwen's profile on her Roleplay page")
laidOut(joan, "Faelwen's Roleplay page")
joan.ui.run(detail.rpButton, "OnClick")
check(joan.trpOpened == fullOf("Faelwen"), "Open in Total RP 3 for Faelwen opened " .. tostring(joan.trpOpened))
-- Her own row in the roster is her, not a guildmate who doesn't share.
joan.ui.run(rowFor(joan, joan.full), "OnClick")
note = world.listText(detail.note)
check(note:find("This is you", 1, true) and not note:find("doesn't share", 1, true), "Joan's own roster row: " .. note)
joan.slash("")
-- Without Total RP 3 there is no Roleplay page, and nothing breaks. Opened for the first time while
-- nothing has been said in the guild's chat, the Guild tab shows the first guildmate, not an empty chat.
mira.slash("")
if not mira.env.ReliquaryFrame:IsShown() then mira.slash("") end
mira.ui.run(mira.env.ReliquaryFrame.Tabs[TAB.Guild], "OnClick")
do
    check(#mira.ns.guildChat(gk()) == 0, "something was said in the guild before Mira first opened its tab")
    local chosen, first
    for _, f in ipairs(mira.ui.frames) do
        if f._rows and f:IsVisible() and f._rows[1] and rawget(f._rows[1], "row") then
            for _, r in ipairs(f._rows) do
                if r.chosen then chosen = r end
                if not first and not r.row.chat then first = r end
            end
        end
    end
    check(chosen and chosen == first, "Mira's Guild tab opened on " .. tostring(chosen and chosen.name._text) .. ", not on the first guildmate")
end
local miraRow = rowFor(mira, thalia.full)
if miraRow then mira.ui.run(miraRow, "OnClick") end
for _, f in ipairs(mira.ui.frames) do check(not (f.page == "rp" and f:IsVisible()), "Mira has no Total RP 3, but her window offers a Roleplay page") end
mira.slash("")

---------------------------------------------------------------------------
-- 8c. The guild master's settings: who sees each tab, the bank's records, and nobody else's word
---------------------------------------------------------------------------
local settingsBefore = #world.log
-- Faelwen, the guild master, visits the bank: her game reads each rank's permissions from Guild
-- Control, which only hers can, and her window offers the Sharing settings. Nobody else's does.
openBank(faelwen)
advance(15)
closeBank(faelwen)
advance(30)
local fg = faelwen.db().guilds[gk()]
check(fg.rules and fg.rules.n == 5 and fg.rules.view[4] == "1101" and fg.rules.view[2] == "1111" and fg.rules.names[3] == "Veteran"
    and fg.rules.gold[4] == 5 and fg.rules.wd[4][1] == 2 and fg.rules.gold[1] == -1, "the guild master's read of each rank's permissions")
check(not joan.db().guilds[gk()].rules and not fg.policy, "an officer read Guild Control, or settings exist before the guild master chose any")
joan.ns.showViewer(TAB.Bank)
check(not button(joan, "Sharing"), "an officer's bank page offers the guild master's settings")
faelwen.ns.showViewer(TAB.Bank)
faelwen.ui.run(assert(button(faelwen, "Sharing"), "the guild master's bank page has no Sharing button"), "OnClick")
local function pickFor(c, tab)
    for _, f in ipairs(c.ui.frames) do if f._kind == "DropdownButton" and f:IsVisible() and f:GetParent().index == tab then return f end end
end
local function labels(c, w) local out = {} for _, x in ipairs(c.ui.menu(w)) do out[#out + 1] = x.label .. (x.selected and "*" or "") end return table.concat(out, "|") end
-- Only choices wider than the game's: the Officers tab can open to Veterans, Members or everyone;
-- Reagents, which every rank views in game, can only be kept in the game.
check(labels(faelwen, pickFor(faelwen, 3)) == "As in game*|Veteran and up|Member and up|Everyone|Game only", "the Officers tab's choices: " .. labels(faelwen, pickFor(faelwen, 3)))
check(labels(faelwen, pickFor(faelwen, 1)) == "As in game*|Game only", "the Reagents tab's choices: " .. labels(faelwen, pickFor(faelwen, 1)))
check(pickFor(faelwen, 3).label._text == "As in game", "the Officers tab's dropdown doesn't say its choice: " .. tostring(pickFor(faelwen, 3).label._text))
faelwen.ui.choose(pickFor(faelwen, 3), "Member and up")
check(pickFor(faelwen, 3).label._text == "Member and up", "the Officers tab's dropdown doesn't say the new choice: " .. tostring(pickFor(faelwen, 3).label._text))
-- The tab opened to Members reaches Thalia, but its records stay home until the guild master
-- shares them.
advance(300)
check(thalia.db().guilds[gk()].bank.tabs[3] and not (thalia.db().guilds[gk()].bank.logs or {})[3], "the Officers tab's records travelled before the guild master shared the records")
local function deepCopy(v) if type(v) ~= "table" then return v end local o = {} for k, x in pairs(v) do o[k] = deepCopy(x) end return o end
local firstSettings = deepCopy(faelwen.db().guilds[gk()].policy)
local recBox
for _, f in ipairs(faelwen.ui.frames) do
    local label = f._kind == "CheckButton" and (rawget(f, "Text") or rawget(f, "label"))
    if label and label._text == "Share logs, notes and limits" and f:IsVisible() then recBox = f end
end
do -- who sends the records, chosen beside them once they're shared
    local senders
    for _, f in ipairs(faelwen.ui.frames) do if f._kind == "DropdownButton" and rawget(f, "label") and (f.label._text or ""):find(" and up$") and f:GetParent() == recBox:GetParent() then senders = f end end
    check(senders and not senders:IsVisible(), "who sends the records shows before they're shared")
    recBox:SetChecked(true)
    faelwen.ui.run(recBox, "OnClick")
    check(senders:IsVisible() and senders.label._text == "Officer and up", "who sends the records: " .. tostring(senders.label._text))
end
check(labels(faelwen, pickFor(faelwen, 3)):find("Member and up*", 1, true), "the Officers tab's choice didn't stay chosen")
local fp = fg.policy
check(fp and fp.by == faelwen.full and fp.tb[3] == 4 and fp.tb[1] == "g" and fp.rc == true and fp.kp == 2 and fp.v[4] == "1101", "the guild master's settings")
advance(30)
for _, c in ipairs({ joan, thalia, mira }) do
    local p = c.db().guilds[gk()].policy
    check(p and p.by == faelwen.full and p.tb[3] == 4 and p.rc == true and p.h == fp.h, c.name .. " doesn't have the guild master's settings")
end
-- Each rank's permissions are known now, so Joan's copies reach every guildmate whose rank may see
-- them: Thalia gets Joan's restocked Reagents and the Officers tab opened to Members, and Mira, who
-- has never been to the bank, all four. Joan keeps the records (an officer), so each tab's log and
-- note and the gold log come with them.
advance(300)
tb = thalia.db().guilds[gk()].bank
check(tb.tabs[1].slots[4] and tb.tabs[1].slots[4].n == 13 and tb.tabs[1].by == "Joan", "Thalia didn't get Joan's restocked Reagents once the guild master's settings came")
check(tb.tabs[3] and tb.tabs[3].slots[2].id == 6505, "Thalia didn't get the Officers tab opened to Members")
check(tb.logs[3] and tb.logs[3].list[1].id == 6505 and tb.logs[3].by == "Joan" and tb.notes[3].text == BANK.notes[3], "Thalia didn't get the Officers tab's records from Joan")
local mb = mira.db().guilds[gk()].bank
check(mb.tabs[1] and mb.tabs[2] and mb.tabs[3] and mb.tabs[4], "Mira didn't get the tabs her rank may see")
check(mb.logs[9] and #mb.logs[9].list == 2 and mb.logs[1] and #mb.logs[1].list == 2 and mb.notes[4].text == BANK.notes[4], "Mira didn't get the records")
local mp = mira.db().guilds[gk()].policy
check(mp.lm and mp.lm[4].g == 5 and mp.lm[4].w[1] == 2 and mp.nm[4] == "Member", "the limits for Mira's rank")
-- Nothing went where it may not: each tab only to a rank that may see it, by whisper (none is open
-- to everyone), records only from those who keep them, settings only from the guild master.
for _, m in ipairs(carried(settingsBefore)) do
    if m.msg.t == "gb" then
        local i, to = m.msg.i, world.byName[m.target]
        check(m.kind == "WHISPER", "tab " .. i .. " went to the whole guild")
        check(i == 9 or to.rank <= BANK.tabs[i][3] or (i == 3 and to.rank <= 4), "tab " .. i .. " went to " .. tostring(m.target))
        if m.msg.lg then check(world.byName[m.from].rank <= 2, "records came from " .. m.from .. ", who doesn't keep them") end
    elseif m.msg.t == "bp" then
        check(m.from == faelwen.full and m.kind == "GUILD", "settings came from " .. m.from)
    end
end
-- Thalia's window: four tabs; Potions' log, its note and what her rank may take; the gold log.
thalia.ns.showViewer(TAB.Bank)
bankButtons = 0
for _, f in ipairs(thalia.ui.frames) do if f._kind == "CheckButton" and f.index and f:IsVisible() then bankButtons = bankButtons + 1 end end
check(bankButtons == 4, "Thalia should see 4 bank tabs with the Officers tab opened to Members, saw " .. bankButtons)
thalia.ui.run(bankTabButton(thalia, 4), "OnClick")
thalia.ui.run(assert(button(thalia, "Log"), "no Log view"), "OnClick")
do
    local bank
    for _, f in ipairs(thalia.ui.frames) do if rawget(f, "logCard") and f:IsVisible() then bank = f end end
    check(bank and bank.logCard:IsVisible() and #bank.log._rows > 0 and bank.logCard._h == 16 + #bank.log._rows * 20 and bank.views.chosen == "log",
        "Potions' log isn't a card as tall as its lines: " .. tostring(bank and bank.logCard._h))
end
shown = texts(thalia)
local miraName = REGIONAL and fullOf("Mira") or "Mira"
check(shown:find(miraName, 1, true) and shown:find("took", 1, true) and shown:find("[Minor Healing Potion]", 1, true)
    and shown:find("Note: Potions are for raid nights.", 1, true) and shown:find("Your rank may take 2 stacks a day from this tab, and 5g a day from the bank.", 1, true),
    "Thalia's Potions log: " .. shown:sub(1, 600))
thalia.ui.run(assert(button(thalia, "Gold log"), "no Gold log view"), "OnClick")
check(texts(thalia):find("repaired with", 1, true) and texts(thalia):find("50g 0s 0c", 1, true), "the gold log in Thalia's window")
---------------------------------------------------------------------------
-- 8d. Handing it out: officers set bank items aside, guildmates ask for them, and every word
-- reaches whoever may see the tab: at once, or through an officer when they come back
---------------------------------------------------------------------------
local function boardOf(c, tab) local b = c.db().guilds[gk()].bank return b.board and b.board[tab] end
local function joanTabAt(c) return c.db().guilds[gk()].bank.tabs[2].at end
local function word(c, kind, tab, id, who) local bd = boardOf(c, tab) local e = bd and bd.items[id] return e and e[kind] and e[kind][who] end
-- Someone's line under Who can use it, on the item's page open now.
local function pageRow(c, who)
    for _, card in ipairs(c.ns.itemPage.who._rows) do
        for _, row in ipairs(card:IsShown() and card.lines or {}) do if row.x and row.x.who == who then return row end end
    end
end
local function openItem(c, tab, id)
    c.ns.showViewer(TAB.Bank)
    c.ui.run(assert(bankTabButton(c, tab), c.name .. " has no bank tab " .. tab), "OnClick")
    if button(c, "Items") then c.ui.run(button(c, "Items"), "OnClick") end
    for _, f in ipairs(c.ui.frames) do
        if f._kind == "ItemButton" and f.rq and f.rq.id == id and f:IsVisible() and f ~= c.ns.itemPage.icon then
            c.ui.run(f, "OnClick")
            return c.ns.itemPage:IsVisible()
        end
    end
end
local function said(c, from, needle)
    local out = {}
    for k = from + 1, #c.printed do if c.printed[k]:find(needle, 1, true) then out[#out + 1] = c.printed[k] end end
    return out
end
-- Reliquary names guildmates as the game does: "Given Family" on Forever, the name elsewhere.
local thaliaCalled, joanCalled = thaliaShort, fullOf("Joan"):match("^([^%-]+)")
do
local boardFrom = #world.log
-- Joan, an officer, opens the Crescent Staff in the Officers tab (open to Members): everyone who
-- can use it, best help first, each row with Set aside. She sets it aside for Thalia.
check(openItem(joan, 3, 6505), "Joan couldn't open the staff from the Officers tab")
local row = pageRow(joan, thalia.full)
check(row and row.act:IsShown() and row.act:GetText() == "Set aside" and pageRow(joan, joan.full).act:GetText() == "Set aside", "the officer's Set aside buttons on the staff's page")
joan.ui.run(row.act, "OnClick")
local setAt = word(joan, "aside", 3, 6505, thalia.full)
check(setAt and setAt.by == joan.full and not setAt.off, "Joan's board after she set the staff aside for Thalia")
advance(30)
for _, c in ipairs({ thalia, mira, faelwen }) do
    local x = word(c, "aside", 3, 6505, thalia.full)
    check(x and x.by == joan.full and x.at == setAt.at, c.name .. " didn't hear the staff was set aside for Thalia")
end
-- It went by whisper, only to guildmates who use Reliquary and may see the Officers tab: never to
-- the whole guild, nor to guildmates without Reliquary.
local reached = {}
for _, m in ipairs(carried(boardFrom)) do
    if m.msg.t == "bd" then
        local to = world.byName[m.target]
        check(m.kind == "WHISPER" and to and to.guild and to.rank <= 4, "a word on the Officers tab's board went to " .. m.kind .. " " .. tostring(m.target))
        reached[m.target] = true
    end
end
check(reached[thalia.full] and reached[mira.full] and reached[faelwen.full], "the set-aside didn't reach everyone who may see the Officers tab")
-- The page says so: Thalia's row takes it back, and nobody else's offers it (the tab holds one).
-- The tooltip line names her instead of calling it her upgrade.
local shownBoard = texts(joan)
check(shownBoard:find("Set aside for " .. thaliaCalled, 1, true) and pageRow(joan, thalia.full).act:GetText() == "Take back"
    and not pageRow(joan, joan.full).act:IsShown(), "the staff's page after it was set aside: " .. shownBoard:sub(1, 700))
check(not joan.ns.setAside(6505, joan.full), "the staff was set aside twice, though the tab holds one")
check(joan.ns.tooltipLine(6505) == "Set aside for " .. thaliaCalled .. " · Held by the guild bank (1)"
    and thalia.ns.tooltipLine(6505) == "Set aside for you · Held by the guild bank (1)",
    "the tooltip lines for the staff: " .. tostring(joan.ns.tooltipLine(6505)) .. " / " .. tostring(thalia.ns.tooltipLine(6505)))
-- A Member has no Set aside, and can't set one by other means.
check(openItem(thalia, 3, 6505), "Thalia couldn't open the staff")
for _, card in ipairs(thalia.ns.itemPage.who._rows) do
    for _, r in ipairs(card:IsShown() and card.lines or {}) do check(not (r.act and r.act:IsShown() and r.act:GetText() == "Set aside"), "a Member's page offers Set aside") end
end
check(not thalia.ns.setAside(5498, mira.full), "a Member set an item aside")
-- Joan's window: the bank's filter shows only what would help someone; Thalia's page in the guild
-- list shows the staff set aside for her.
check(openItem(joan, 3, 6505) and joan.ns.itemPage:IsVisible(), "Joan couldn't reopen the staff")
joan.ui.run(button(joan, "Back"), "OnClick")
local helpsBox
for _, f in ipairs(joan.ui.frames) do
    local label = f._kind == "CheckButton" and (rawget(f, "Text") or rawget(f, "label"))
    if label and label._text == "Helps someone" and f:IsVisible() then helpsBox = f end
end
check(helpsBox, "the bank has no Helps someone filter while an item there would help someone")
search:SetText("")
joan.ui.run(search, "OnTextChanged")
helpsBox:SetChecked(true)
joan.ui.run(helpsBox, "OnClick")
local dimmed, bright = 0, 0
for _, f in ipairs(joan.ui.frames) do
    if f._kind == "ItemButton" and f.rq and f:IsVisible() and f ~= joan.ns.itemPage.icon then
        if f.rq.id == 6505 then bright = f:GetMatchesSearch() elseif f.rq.id == 5498 then dimmed = f:GetMatchesSearch() end
    end
end
check(bright == true and dimmed == false, "the Helps someone filter: staff " .. tostring(bright) .. ", pearls " .. tostring(dimmed))
helpsBox:SetChecked(false)
joan.ui.run(helpsBox, "OnClick")
joan.ui.run(joan.env.ReliquaryFrame.Tabs[TAB.Guild], "OnClick")
joan.ui.run(rowFor(joan, thalia.full), "OnClick")
local strip
for _, f in ipairs(joan.ui.frames) do if f.bankFor and f.bankForButtons and f:IsVisible() then strip = f end end
check(strip and strip.bankFor:IsShown() and strip.bankForButtons[1].rq and strip.bankForButtons[1].rq.id == 6505
    and strip.bankForLabel._text == "In the guild bank for them", "Thalia's page doesn't show the staff set aside for her")
joan.slash("")
-- Thalia hears of it the next time she logs in: one line, and only once.
newSession(thalia)
local printedFrom = #thalia.printed
advance(60)
-- A minute in, Joan sets a pearl aside for her too: that waits for her next login.
check(joan.ns.setAside(5498, thalia.full), "Joan couldn't set a pearl aside for Thalia")
advance(240)
local lines = said(thalia, printedFrom, "/rq to see.")
check(#lines == 1 and lines[1]:find(joanCalled .. " set ", 1, true) and lines[1]:find("[Crescent Staff]", 1, true) and lines[1]:find("aside for you in the guild bank.", 1, true)
    and not lines[1]:find("upgrade", 1, true),
    "Thalia's line at login: " .. table.concat(lines, " | "))
newSession(thalia)
printedFrom = #thalia.printed
advance(300)
lines = said(thalia, printedFrom, "/rq to see.")
check(#lines == 1 and lines[1]:find("[Small Lustrous Pearl]", 1, true) and not lines[1]:find("[Crescent Staff]", 1, true), "Thalia's next line at login: " .. table.concat(lines, " | "))
newSession(thalia)
printedFrom = #thalia.printed
advance(300)
check(#said(thalia, printedFrom, "/rq to see.") == 0, "Thalia was told about the staff or the pearl twice")
-- Mira asks for the Gloves of the Dawnwatch on her own row: she reaches their level in two. She
-- doesn't show the guild her gear, so on Joan's page her row is her ask, and Joan sets them aside
-- for her; her own page then has nothing to ask.
check(openItem(mira, 2, 14146), "Mira couldn't open the gloves")
row = pageRow(mira, mira.full)
check(row and row.act:GetText() == "Ask for it" and texts(mira):find("At level 19", 1, true), "Mira's own row for the gloves: " .. texts(mira):sub(1, 500))
mira.ui.run(row.act, "OnClick")
advance(30)
for _, c in ipairs({ joan, thalia, faelwen }) do check(word(c, "asks", 2, 14146, mira.full), c.name .. " didn't hear Mira ask for the gloves") end
-- Her ask carries what her own game says of them (she doesn't show the guild her gear): at level 19.
local miraAsk = word(joan, "asks", 2, 14146, mira.full)
check(miraAsk.v == "lvl" and miraAsk.lv == 19 and miraAsk.f == miraAsk.at, "Mira's ask doesn't say what the gloves would be for her")
local seenAs = entry(joan.ns.whoCanUse(14146), mira.full)
check(seenAs and seenAs.v == "lvl" and seenAs.lv == 19 and seenAs.own and seenAs.asked, "who can use the gloves, as Joan sees it: " .. names(joan.ns.whoCanUse(14146)))
check(openItem(joan, 2, 14146), "Joan couldn't open the gloves")
row = pageRow(joan, mira.full)
check(row and row.act:GetText() == "Set aside" and row.verdict._text:find("At level 19", 1, true) and texts(joan):find("Asked for it", 1, true) and texts(joan):find("Asked", 1, true),
    "Mira's ask on Joan's page: " .. texts(joan):sub(1, 600))
local miraFrom = #mira.printed
joan.ui.run(row.act, "OnClick")
advance(30)
check(word(mira, "aside", 2, 14146, mira.full), "Mira didn't hear the gloves were set aside for her")
check(#said(mira, miraFrom, "/rq to see.") == 0, "Mira was told of the gloves in the session she was already playing")
check(openItem(mira, 2, 14146) and not pageRow(mira, mira.full).act:IsShown(), "Mira can still ask for gloves set aside for her")
-- Mira reaches level 19: her ask now says the gloves are an upgrade for her, still asked when it
-- was; and back at 17, at level 19 again.
mira.level = 19
mira.fire("PLAYER_LEVEL_UP", 19)
advance(30)
local grown = word(joan, "asks", 2, 14146, mira.full)
check(grown.v == "up" and grown.lv == nil and grown.f == miraAsk.f and grown.at > miraAsk.at, "Mira's ask at level 19: " .. tostring(grown.v))
check(entry(joan.ns.whoCanUse(14146), mira.full).v == "up", "Joan's page doesn't show the gloves as Mira's upgrade")
mira.level = 17
mira.fire("PLAYER_LEVEL_UP", 17)
advance(30)
check(word(joan, "asks", 2, 14146, mira.full).v == "lvl" and word(joan, "asks", 2, 14146, mira.full).f == miraAsk.f, "Mira's ask back at level 17")
-- On the staff's page Mira gains nothing (she wields one), so nothing there is hers to ask for.
check(openItem(mira, 3, 6505), "Mira couldn't open the staff")
for _, card in ipairs(mira.ns.itemPage.who._rows) do
    for _, r in ipairs(card:IsShown() and card.lines or {}) do check(not (r.act and r.act:IsShown()), "Mira's page offers to ask on someone else's row") end
end
mira.slash("")
joan.slash("")
-- She hears of it at her next login, unless she turned that line off.
mira.db().settings.headsUp = false
newSession(mira)
miraFrom = #mira.printed
advance(300)
check(#said(mira, miraFrom, "/rq to see.") == 0, "Mira was told at login with the line turned off")
mira.db().settings.headsUp = nil
newSession(mira)
miraFrom = #mira.printed
advance(300)
lines = said(mira, miraFrom, "/rq to see.")
check(#lines == 1 and lines[1]:find("[Gloves of the Dawnwatch]", 1, true) and lines[1]:find("aside for you in the guild bank.", 1, true), "Mira's line at login: " .. table.concat(lines, " | "))
-- Words reach those who were away. Joan logs out; Mira asks for the mace and the Officers tab's
-- note changes nothing. When Joan is back, Mira's game sees Joan's board is older than her ask and
-- tells her; and Faelwen, back after missing the gloves, gets Joan's whole board with the tab.
joan.online = false
faelwen.online = false
local macedFrom = #world.log
check(mira.ns.askFor(2075), "Mira couldn't ask for the mace")
check(thalia.ns.askFor(6505), "Thalia couldn't ask for the staff")
advance(30)
check(word(thalia, "asks", 2, 2075, mira.full) and not word(joan, "asks", 2, 2075, mira.full), "Mira's ask for the mace while Joan is away")
for _, m in ipairs(carried(macedFrom)) do check(not (m.msg.t == "bd" and (m.target == joan.full or m.target == faelwen.full)), "Mira whispered a guildmate who isn't in the game") end
local joanFrom = #joan.printed
newSession(joan)
advance(120)
check(word(joan, "asks", 2, 2075, mira.full) and word(joan, "aside", 3, 6505, thalia.full), "Joan, back, doesn't have Mira's ask for the mace")
check(word(joan, "asks", 3, 6505, thalia.full) and word(joan, "asks", 3, 6505, thalia.full).v == "up", "Thalia's ask, sent again to Joan, lost what the staff would be for her")
-- Once Joan has it, Mira doesn't send it again; and Joan's line at login is only ever real news
-- (the mace would help her only at level 15).
local resentFrom = #world.log
newSession(joan)
advance(300)
for _, m in ipairs(carried(resentFrom)) do check(not (m.msg.t == "bd" and m.from == mira.full and m.target == joan.full), "Mira sent Joan her ask again, though Joan had it") end
check(#said(joan, joanFrom, "/rq to see.") == 0, "Joan was told of an item that would help her only at a later level: " .. table.concat(said(joan, joanFrom, "/rq to see."), " | "))
faelwen.db().guilds[gk()].bank.board = nil -- as if she had never heard a word
newSession(faelwen)
advance(300)
check(word(faelwen, "aside", 3, 6505, thalia.full) and word(faelwen, "aside", 2, 14146, mira.full) and word(faelwen, "asks", 2, 2075, mira.full),
    "Faelwen, back, didn't get the boards from Joan")
check(word(faelwen, "asks", 2, 14146, mira.full).v == "lvl" and word(faelwen, "asks", 2, 14146, mira.full).f == miraAsk.f,
    "Joan's board reached Faelwen without what the gloves would be for Mira, or when she asked")
-- Taking an ask back reaches everyone too, and a late copy of the ask can't bring it back.
local lateAsk = word(joan, "asks", 2, 2075, mira.full).at
check(mira.ns.askFor(2075, true), "Mira couldn't take her ask for the mace back")
advance(30)
for _, c in ipairs({ joan, thalia, faelwen }) do check(word(c, "asks", 2, 2075, mira.full).off, c.name .. " didn't hear Mira take her ask back") end
mira.ns.send({ kind = "WHISPER", target = joan.full }, { t = "bd", i = 2, it = 2075, k = "w", at = lateAsk }, true)
advance(10)
check(word(joan, "asks", 2, 2075, mira.full).off, "a late copy of Mira's ask brought it back")
joan.slash("")
joan.ui.run(joan.env.ReliquaryFrame.Tabs[TAB.Guild], "OnClick")
joan.slash("")
-- Faelwen's new session: her bank settings open again, as they were.
faelwen.ns.showViewer(TAB.Bank)
faelwen.ui.run(assert(button(faelwen, "Sharing"), "the guild master's bank page has no Sharing button"), "OnClick")
end

---------------------------------------------------------------------------
-- 8f. Prices and where items come from: the auction house read at the house, item by item while
-- you stand there, and shared in the guild by those who choose to; notes from vendors, loot,
-- quests, recipes and the journal
---------------------------------------------------------------------------
local function holds(v, needle)
    if type(v) == "string" then return v:find(needle, 1, true) ~= nil end
    if type(v) == "table" then for k, x in pairs(v) do if holds(k, needle) or holds(x, needle) then return true end end end
    return false
end
do
local house, neutral = REALM .. "|Alliance", REALM .. "|Neutral"
local gm = joan.env.GetMoneyString
local auctioneer = { name = "Auctioneer Lympkin", faction = "Alliance", guid = "Creature-0-1-0-12-8669-00000A01" }
local function visit(c, npc, stay)
    c.npc = npc
    c.fire("AUCTION_HOUSE_SHOW")
    advance(stay or 10)
end
local function leave(c) c.fire("AUCTION_HOUSE_CLOSED") c.npc = nil end
-- The Alliance house: two stacks of potions, the mace, a staff up for bids only, linen, and the
-- rest of the house, more than a frame's worth.
world.auctions[house] = { { 858, 5, 9250, "Seller Bob" }, { 858, 10, 19000, "Seller Bob" }, { 2075, 1, 45000, "Seller Ann" },
    { 6505, 1, 0, "Seller Ann" }, { 2589, 20, 2400, "Seller Cid" } }
for k = 1, 640 do table.insert(world.auctions[house], { 300000 + k, 1, 1000 + k, "Seller Dee" }) end
local pricesFrom = #world.log
visit(joan, auctioneer)
local jp = joan.db().prices and joan.db().prices[house]
check(jp and jp.own and jp.n == 645 and jp.items[858].p == 1850 and jp.items[858].q == 15 and jp.items[2075].p == 45000 and jp.items[2589].p == 120
    and not jp.items[6505] and jp.items[300640].p == 1640 and world.replicateCalls == 1, "Joan's scan of the Alliance house")
check(not holds(joan.db().prices, "Seller"), "a seller's name was kept")
joan.ns.guildHello()
advance(5)
for _, m in ipairs(carried(pricesFrom)) do check(not (m.msg.px or m.msg.t == "pr"), "a scan was offered to the guild by someone who doesn't share them") end
-- Back within a quarter hour: no second scan.
leave(joan)
advance(60)
visit(joan, auctioneer)
check(world.replicateCalls == 1, "the house was scanned twice within a quarter hour")
-- A search answer nobody asked for (the house's own window searching) isn't kept as a check.
joan.fire("COMMODITY_SEARCH_RESULTS_UPDATED", 2589)
check(not joan.db().prices[house].items[2589].at, "a search Reliquary didn't make was kept as its check")
-- The tooltip line and the item's page.
check(joan.ns.tooltipLine(858) == "Auction " .. gm(1850, true) .. " each · Held by the guild bank (12)"
    and joan.ns.tooltipLine(2075) == "Auction " .. gm(45000, true) .. " · Held by the guild bank (1)",
    "the tooltip lines with prices: " .. tostring(joan.ns.tooltipLine(858)) .. " / " .. tostring(joan.ns.tooltipLine(2075)))
check(joan.ns.priceLine(858):find("Auction: " .. gm(1850, true) .. " each, 15 listed · your scan, ", 1, true), "the potion's price line: " .. joan.ns.priceLine(858))
-- The staff wasn't listed when Joan scanned: its page says so, with whose scan and when; the game's
-- tooltip says nothing of it.
check(joan.ns.priceLine(6505) and joan.ns.priceLine(6505):find("Auction: none listed · your scan, ", 1, true) and joan.ns.priceWords(6505) == nil,
    "the staff, not listed in Joan's scan: " .. tostring(joan.ns.priceLine(6505)))
-- Only the houses Joan can use count: a Horde price on her realm is never hers.
local hordeHouse = house:match("^(.*)|") .. "|Horde"
joan.db().prices[hordeHouse] = { at = world.clock, n = 40, by = "Joan", own = true, items = { [6505] = { p = 99000, q = 1 }, [2592] = { p = 1, q = 1 } } }
check(joan.ns.priceLine(6505):find("Auction: none listed · your scan, ", 1, true) and joan.ns.priceWords(6505) == nil and joan.ns.priceWords(2592) == nil,
    "a Horde price reached Alliance Joan: " .. tostring(joan.ns.priceLine(6505)) .. " / " .. tostring(joan.ns.priceWords(2592)))
joan.db().prices[hordeHouse] = nil
-- A house only checked item by item says nothing of what it wasn't asked about.
mira.db().prices = { [house] = { items = { [858] = { p = 1900, q = 4, at = world.clock } } } }
check(mira.ns.priceLine(858) and mira.ns.priceLine(858):find("checked just now", 1, true) and mira.ns.priceLine(6505) == nil,
    "Mira's checks only: " .. tostring(mira.ns.priceLine(858)) .. " / " .. tostring(mira.ns.priceLine(6505)))
mira.db().prices = nil
-- With the house open, an item's page asks it about that item there and then: a cheaper stack
-- listed since the scan; the mace, which is gear; and nothing asked away from the house.
table.insert(world.auctions[house], { 858, 3, 5100, "Seller Eve" })
local searches = world.searches or 0
check(openItem(joan, 4, 858), "Joan couldn't open the potion")
check(joan.ns.priceLine(858) == "Auction: asking the auction house...", "while the house answers: " .. joan.ns.priceLine(858))
advance(3)
check(joan.ns.priceLine(858) == "Auction: " .. gm(1700, true) .. " each, 18 listed · checked just now" and texts(joan):find("checked just now", 1, true),
    "the potion's price, checked at the house: " .. joan.ns.priceLine(858))
check(openItem(joan, 2, 2075), "Joan couldn't open the mace")
advance(3)
check(joan.ns.priceLine(2075) == "Auction: " .. gm(45000, true) .. ", 1 listed · checked just now" and world.searches == searches + 2, "the mace's price, checked: " .. joan.ns.priceLine(2075))
check(not holds(joan.db().prices, "Seller"), "a seller's name was kept from a check")
leave(joan)
check(openItem(joan, 4, 858) and world.searches == searches + 2, "an item's page asked a house you aren't at")
joan.slash("")
-- A goblin's house is the neutral one. One this big is read once; after that only item by item.
world.auctions[neutral] = {}
for k = 1, 60001 do world.auctions[neutral][k] = { 858, 1, 2500, "Seller Fay" } end
world.auctions[neutral][60001] = { 2592, 1, 300, "Seller Fay" } -- wool, listed at the neutral house only
advance(15 * 60)
local goblin = { name = "Auctioneer Beardo", guid = "Creature-0-1-0-12-8661-00000A02" }
visit(joan, goblin, 30)
local np = joan.db().prices[neutral]
check(np and np.n == 60001 and np.items[858].p == 2500 and world.replicateCalls == 2, "the neutral house's scan")
-- The wool is listed at the neutral house and not at Joan's own: her item page and tooltip give
-- the neutral house's price, not that her own had none.
check(joan.ns.priceLine(2592) and joan.ns.priceLine(2592):find("Auction: " .. gm(300, true) .. " each, 1 listed at the neutral house · your scan, ", 1, true)
    and joan.ns.priceWords(2592) == "Auction " .. gm(300, true) .. " each", "the wool: " .. tostring(joan.ns.priceLine(2592)) .. " / " .. tostring(joan.ns.priceWords(2592)))
leave(joan)
advance(16 * 60)
visit(joan, goblin)
leave(joan)
check(world.replicateCalls == 2, "a house that big was scanned again")
check(joan.ns.priceFor(858).side == "Alliance", "Joan's price for the potion isn't her own side's house")
world.auctions[neutral] = nil
-- Walking away before the scan is asked for, or before its list arrives, keeps nothing.
advance(16 * 60)
local calls = world.replicateCalls
visit(joan, auctioneer, 1)
leave(joan)
advance(10)
check(world.replicateCalls == calls, "the house was scanned after Joan walked away")
local before = joan.db().prices[house].at
visit(joan, auctioneer, 2.5)
leave(joan)
advance(10)
check(world.replicateCalls == calls + 1 and joan.db().prices[house].at == before, "a scan whose list came after Joan walked away was kept")
joan.fire("REPLICATE_ITEM_LIST_UPDATE")
advance(2)
check(joan.db().prices[house].at == before, "a list read away from the house")
visit(joan, auctioneer, 0)
joan.fire("REPLICATE_ITEM_LIST_UPDATE") -- the first few hundred read at once, the rest frame by frame
leave(joan)
advance(2)
check(joan.db().prices[house].at == before, "a read cut short by walking away was kept")
-- Sharing scans starts off. Turned on, Joan's hello offers her newest; guildmates who have none as
-- new ask on the guild channel, and the parts go once to everyone.
joan.ns.showViewer(TAB.Sharing)
local shareBox
for _, f in ipairs(joan.ui.frames) do
    local label = f._kind == "CheckButton" and rawget(f, "Text")
    if label and label._text == "Share prices and sources" and f:IsVisible() then shareBox = f end
end
check(shareBox and not shareBox:GetChecked() and joan.db().settings.sharePrices == nil, "sharing prices doesn't start off")
shareBox:SetChecked(true)
joan.ui.run(shareBox, "OnClick")
joan.slash("")
check(joan.db().settings.sharePrices == true, "the switch didn't turn sharing prices on")
local sharedFrom = #world.log
joan.ns.guildHello()
advance(180)
for _, c in ipairs({ thalia, mira, faelwen }) do
    local p = c.db().prices and c.db().prices[house]
    check(p and p.at == jp.at and p.by == joanCalled and not p.own and p.items[858] and p.items[300640].p == 1640, c.name .. " didn't get Joan's scan")
end
local asked, parts = 0, 0
for _, m in ipairs(carried(sharedFrom)) do
    if m.msg.t == "pr?" then asked = asked + 1 end
    if m.msg.t == "pr" then
        check(m.from == joan.full and m.kind == "GUILD", "a part of a scan went " .. m.kind .. " from " .. m.from)
        if m.msg.h == house then
            parts = parts + 1
            check(m.msg.of == 2, "the Alliance scan in " .. tostring(m.msg.of) .. " parts")
        end
    end
end
check(asked >= 1 and parts == 2, ("the scan was asked for %d times and went in %d parts"):format(asked, parts))
check(thalia.ns.priceLine(2589):find("· " .. joanCalled .. "'s scan, ", 1, true), "Thalia's price line: " .. tostring(thalia.ns.priceLine(2589)))
-- Those who have it don't ask again; the same scan goes at most once a half hour; only your own
-- scans are offered, and only while you share; a whispered ask is nobody's.
for _ = 1, 30 do if joan.ns.queued() == 0 then break end advance(10) end -- the first answer finishes going out
local againFrom = #world.log + 1
newSession(thalia) -- a fresh game that has the scan saved; Joan answers its hello with hers
joan.ns.guildHello()
advance(30)
for _, m in ipairs(carried(againFrom)) do check(m.msg.t ~= "pr?" and m.msg.t ~= "pr", "a scan everyone has was asked for again by " .. m.from) end
againFrom = #world.log + 1
thalia.ns.send({ kind = "GUILD" }, { t = "pr?", to = joan.full, h = house, at = jp.at }, true)
brannoc.ns.send({ kind = "WHISPER", target = joan.full }, { t = "pr?", to = joan.full, h = house, at = jp.at }, true)
thalia.db().settings.sharePrices = true
check(thalia.ns.priceOffer() == nil, "Thalia offers a scan that isn't hers")
mira.ns.send({ kind = "GUILD" }, { t = "pr?", to = thalia.full, h = house, at = jp.at }, true)
advance(60)
thalia.db().settings.sharePrices = nil
for _, m in ipairs(carried(againFrom)) do
    check(m.msg.t ~= "pr", "a scan was sent again, by " .. m.from)
end
-- Nobody else's scan counts: a whisper, an older one, and a part out of range.
brannoc.ns.send({ kind = "WHISPER", target = thalia.full }, { t = "pr", h = house, at = world.clock, k = 1, of = 1, l = { 858, 1, 1 } }, true)
mira.ns.send({ kind = "GUILD" }, { t = "pr", h = house, at = jp.at - 60, k = 1, of = 1, l = { 858, 1, 1 } }, true)
mira.ns.send({ kind = "GUILD" }, { t = "pr", h = house, at = world.clock, k = 2, of = 1, l = { 858, 1, 1 } }, true)
advance(10)
check(thalia.db().prices[house].at == jp.at and thalia.db().prices[house].items[858].p ~= 1, "a whispered, older or broken scan replaced Joan's")
-- A scan made with sharing off goes nowhere, even when asked for; turned on, a whispered ask is
-- still nobody's; and turned off while it goes, what waited stays home.
local function setShare(on)
    joan.ns.showViewer(TAB.Sharing)
    shareBox:SetChecked(on)
    joan.ui.run(shareBox, "OnClick")
    joan.slash("")
end
setShare(false)
advance(16 * 60)
visit(joan, auctioneer)
leave(joan)
local newer = joan.db().prices[house].at
check(newer > jp.at, "Joan's second scan")
local offFrom = #world.log + 1
mira.ns.send({ kind = "GUILD" }, { t = "pr?", to = joan.full, h = house, at = newer }, true)
advance(40) -- long enough for a part to finish going out
for _, m in ipairs(carried(offFrom)) do check(m.msg.t ~= "pr" and not m.msg.px, "Joan offered or sent her scan with sharing off") end
setShare(true)
offFrom = #world.log + 1
brannoc.ns.send({ kind = "WHISPER", target = joan.full }, { t = "pr?", to = joan.full, h = house, at = newer }, true)
advance(40)
for _, m in ipairs(carried(offFrom)) do check(m.msg.t ~= "pr", "Joan answered a whispered ask for her scan") end
joan.ns.guildHello()
advance(8)
setShare(false)
advance(180)
check(thalia.db().prices[house].at == jp.at, "a scan went out after sharing was turned off")
setShare(true)
-- Where things come from. A vendor's wares, as sold and where the vendor stands.
joan.npc = { name = "Innkeeper Shaussiy", faction = "Alliance", guid = "Creature-0-1-0-12-6737-0000AB01" }
joan.merchant = { { 858, 1000, 1, -1 }, { 2589, 50, 5, 12 } }
joan.fire("MERCHANT_SHOW")
advance(2)
joan.npc = nil
joan.fire("MERCHANT_SHOW") -- the window without a vendor behind it: nothing to note
advance(2)
joan.merchant = nil
local js = joan.db().sources
check(js and js[858].v[6737].n == "Innkeeper Shaussiy" and js[858].v[6737].p == 1000 and js[858].v[6737].z == "Darkshore" and js[858].v[6737].s == "Auberdine"
    and js[2589].v[6737].k == 5 and js[2589].v[6737].l == true and not js[858].v[6737].l, "the innkeeper's wares")
-- A creature's loot, counted once a loot window; fishing; a gathering node; a lockbox.
joan.targetGuid, joan.targetName = "Creature-0-1-0-12-2167-0000AB02", "Blackwood Pathfinder"
joan.loot = { { 2589, joan.targetGuid }, { nil, joan.targetGuid } }
joan.fire("LOOT_READY") joan.fire("LOOT_READY") joan.fire("LOOT_CLOSED")
joan.fire("LOOT_READY") joan.fire("LOOT_CLOSED")
joan.targetGuid, joan.targetName = nil, nil
joan.fishing, joan.loot = true, { { 765, "GameObject-0-1-0-12-35591-0000AB03" } }
joan.fire("LOOT_READY") joan.fire("LOOT_CLOSED")
joan.fishing, joan.loot = false, { { 2447, "GameObject-0-1-0-12-1618-0000AB04" } }
joan.fire("LOOT_READY") joan.fire("LOOT_CLOSED")
joan.opts.bags = { size = 4, [1] = { 4632, 1 } }
joan.env.C_Container.UseContainerItem(0, 1)
joan.loot = { { 5498, "Item-1-0-0000AB05" } }
joan.fire("LOOT_READY") joan.fire("LOOT_CLOSED")
-- What's looted from an item long after it was opened isn't from it.
joan.env.C_Container.UseContainerItem(0, 1)
advance(10)
joan.loot = { { 2592, "Item-1-0-0000AB06" } }
joan.fire("LOOT_READY") joan.fire("LOOT_CLOSED")
joan.opts.bags, joan.loot = nil, nil
check(not (js[2592] and js[2592].d), "loot long after a container was opened was noted as from it")
check(js[2589].d.c2167 and js[2589].d.c2167.n == "Blackwood Pathfinder" and js[2589].d.c2167.c == 2 and js[2589].d.c2167.z == "Darkshore", "the pathfinder's linen")
check(js[765].d["f:Darkshore"] and js[2447].d.o1618 and js[5498].d.i4632, "fishing, gathering or a lockbox")
-- A quest's reward and its choices; a recipe she knows (and none she doesn't); the journal.
joan.quest = { id = 26, title = "The Absent Minded Prospector", rewards = { 14146 }, choices = { 264150, 2075 } }
joan.fire("QUEST_DETAIL")
joan.quest = nil
joan.crafts = { Alchemy = { skill = 61, max = 75, known = { [2330] = true } } }
joan.window = { prof = "Alchemy" }
joan.fire("TRADE_SKILL_SHOW")
advance(3)
joan.window = nil
joan.fire("TRADE_SKILL_CLOSE")
world.drops[6505] = { { encounter = "Mutanus the Devourer", instance = "Wailing Caverns", difficulties = { "Normal" } } }
check(openItem(joan, 3, 6505), "Joan couldn't open the staff")
check(js[14146].q[26].t == "The Absent Minded Prospector" and not js[14146].q[26].ch and js[2075].q[26].ch == true, "the quest's rewards")
check(js[118].m[2330].p == "Alchemy" and #js[118].m[2330].u == 3 and js[2447].r[2330].o == 118 and not js[858].m, "the recipes")
check(js[6505].j["Mutanus the Devourer|Wailing Caverns"] and js[6505].j["Mutanus the Devourer|Wailing Caverns"].df == "Normal", "the journal's drop")
check(texts(joan):find("Drops from Mutanus the Devourer in Wailing Caverns (Normal)", 1, true), "the staff's page: " .. texts(joan):sub(1, 900))
joan.slash("")
local lines = joan.ns.sourceLines(858)
check(lines[1] == "Sold by Innkeeper Shaussiy, Auberdine, Darkshore for 10s", "the potion's sources: " .. table.concat(lines, " | "))
-- An item keeps the newest eight vendors.
for k = 1, 10 do
    joan.npc, joan.merchant = { name = "Vendor " .. k, guid = "Creature-0-1-0-12-" .. (7000 + k) .. "-0000AC0" .. k }, { { 4306, 1000 + k, 1, -1 } }
    joan.fire("MERCHANT_SHOW")
    advance(1)
end
joan.npc, joan.merchant = nil, nil
local vendors = 0
for _ in pairs(js[4306].v) do vendors = vendors + 1 end
check(vendors == 8 and not js[4306].v[7001] and js[4306].v[7010], "the silk's vendors: " .. vendors)
-- Every place the silk comes from, in words, the most useful first; the first few, with the rest
-- counted, for anywhere with room for only a few.
local allSources, capped = joan.ns.sourceLines(4306), joan.ns.sourceLines(4306, joan.ns.ITEM_PAGE_SOURCES)
check(#allSources == 8 and #capped == 4 and capped[4]:find("5 more places it comes from", 1, true), "the silk's lines: " .. table.concat(capped, " | "))
-- Opened as a player opens it: the silk in the guild bank, clicked.
joan.ns.showViewer(TAB.Bank)
for _, f in ipairs(joan.ui.frames) do if f._kind == "CheckButton" and f.index == 4 and f:IsVisible() then joan.ui.run(f, "OnClick") end end
do
    local silkButton
    for _, f in ipairs(joan.ui.frames) do if f._kind == "ItemButton" and f.rq and f.rq.id == 4306 and f:IsVisible() and f ~= joan.ns.itemPage.icon then silkButton = f end end
    check(silkButton, "the silk in the guild bank's fourth tab")
    joan.ui.run(silkButton, "OnClick")
end
local silkPage = joan.ns.itemPage
check(silkPage:IsVisible() and silkPage.item.id == 4306, "the silk's page")
laidOut(joan, "the silk's page")
-- Every place it comes from, each beside its kind's map icon under the people around it, and in
-- the item's own column what a vendor pays for it.
;(function()
    local function bodyLines(kind)
        local out = {}
        for _, card in ipairs(silkPage.list:GetDataProvider()._items) do
            for _, line in ipairs(card.rows or {}) do if line.kind == kind then out[#out + 1] = line end end
        end
        return out
    end
    local places, every = {}, true
    for _, card in ipairs(silkPage.who:GetDataProvider()._items) do for _, place in ipairs(card.places or {}) do places[#places + 1] = place end end
    for i, l in ipairs(places) do if l.text ~= allSources[i] or not (l.place or l.item) then every = false end end
    check(#places == 8 and every and places[1].place == "vendor", "the silk's page lists every place it comes from, each with its icon: " .. #places)
    check(not (silkPage.meta._text or ""):find("Item level", 1, true), "the silk's page gives cloth an item level: " .. tostring(silkPage.meta._text))
    local parts, auction = joan.ns.priceParts(4306), nil
    for _, l in ipairs(bodyLines("stat")) do if l.text == "Auction" then auction = l.value end end
    check(parts and auction and (parts.value and auction == parts.value or not parts.value and auction:find(parts.waiting and "Asking the auction house" or "None listed", 1, true)),
        "the silk's Auction row: " .. tostring(auction))
    -- The row in each of its three states: a price and what it rests on, none listed, still asking.
    local realParts = joan.ns.priceParts
    local states = {}
    for _, state in ipairs({ { value = "1s 32c each", about = "32 listed · your scan, 17 h ago" }, { none = true, about = "your scan, just now" }, { waiting = true } }) do
        joan.ns.priceParts = function() return state end
        silkPage.redraw()
        local row, note
        for _, l in ipairs(bodyLines("stat")) do if l.text == "Auction" then row = l.value end end
        for _, l in ipairs(bodyLines("note")) do if not l.left then note = l.text end end
        states[#states + 1] = { row = row, note = note }
    end
    joan.ns.priceParts = realParts
    silkPage.redraw()
    check(states[1].row == "1s 32c each" and states[1].note == "32 listed · your scan, 17 h ago"
        and states[2].row:find("None listed", 1, true) and states[2].note == "your scan, just now"
        and states[3].row:find("Asking the auction house", 1, true) and states[3].note == nil,
        "the Auction row: " .. tostring(states[1].row) .. " / " .. tostring(states[2].row) .. " / " .. tostring(states[3].row))
    -- The parts say what the one line says.
    for id in pairs(joan.db().prices[house] and joan.db().prices[house].items or {}) do
        local parts, line = joan.ns.priceParts(id), joan.ns.priceLine(id)
        if parts and parts.value then check(line == "Auction: " .. parts.value .. ", " .. parts.about, "an item's price apart and in one line: " .. tostring(line)) end
    end
    local sell, info = nil, joan.db().items[4306] and joan.db().items[4306].info
    for _, l in ipairs(bodyLines("stat")) do if l.text == "Sell Price" then sell = l.value end end
    check(info and (info.sell or 0) > 0 and sell == joan.env.GetMoneyString(info.sell, true), "the silk's sell price: " .. tostring(sell))
    check(texts(joan):find(allSources[8], 1, true) or not silkPage.list:HasScrollableExtent(), "the silk's last place isn't on its page")
end)()
-- A page with more than its column holds scrolls, and nothing of it runs over the addresses below.
do
    local real = joan.ns.itemSources
    joan.ns.itemSources = function(id)
        local out = real(id)
        for i = 1, 20 do out.places[#out.places + 1] = { kind = "drop", text = "Drops from creature " .. i .. ", a line long enough to wrap in its column on the page" } end
        return out
    end
    silkPage.redraw()
    laidOut(joan, "an item's page with a lot to say")
    check(silkPage.who:HasScrollableExtent(), "a long item page doesn't scroll")
    joan.ns.itemSources = real
    silkPage.redraw()
end
-- What's gathered gets the map's herb or ore icon when the game files the item as a herb or as metal
-- and stone, and the plain one otherwise.
;(function()
    local realSources, realInstant = joan.ns.itemSources, joan.env.C_Item.GetItemInfoInstant
    joan.ns.itemSources = function() return { places = { { kind = "gather", text = "Gathered in Auberdine, Darkshore" } }, recipes = {}, makes = {} } end
    local seen = {}
    for _, sub in ipairs({ 9, 7, 5 }) do
        joan.env.C_Item.GetItemInfoInstant = function() return 4306, "Trade Goods", "?", "", 0, 7, sub end
        silkPage.redraw()
        for _, card in ipairs(silkPage.who:GetDataProvider()._items) do for _, place in ipairs(card.places or {}) do seen[sub] = place.atlas or "plain" end end
    end
    joan.ns.itemSources, joan.env.C_Item.GetItemInfoInstant = realSources, realInstant
    silkPage.redraw()
    check(seen[9] == "Professions_Tracking_Herb" and seen[7] == "Professions_Tracking_Ore" and seen[5] == "plain",
        ("gathered icons: herb %s, ore %s, cloth %s"):format(tostring(seen[9]), tostring(seen[7]), tostring(seen[5])))
end)()
silkPage:Hide()
joan.env.ReliquaryFrame:Hide()
-- The journal is looked at again only after a month, unless an item's page asks.
local looks = world.journalCalls or 0
advance(120)
check((world.journalCalls or 0) == looks, "the journal was asked about items it was asked about this month")
lines = joan.ns.sourceLines(2447)
check(table.concat(lines, "|"):find("Gathered in Auberdine, Darkshore", 1, true) and table.concat(lines, "|"):find("Used to make Minor Healing Potion", 1, true), "the peacebloom's sources: " .. table.concat(lines, " | "))
-- Thalia opens the linen's page: her game asks the guild; Joan, who shares, answers with her own
-- notes; Mira, who doesn't, stays quiet. A whisper with notes is nobody's word.
local srcFrom = #world.log
mira.db().sources = { [2589] = { v = { [1] = { n = "Mira's vendor", z = "Teldrassil", at = world.clock } } } }
thalia.db().sources = { [2589] = { v = { [6737] = { n = "Innkeeper Shaussiy", z = "Darkshore", p = 45, at = world.clock - 60 } } } }
joan.db().sources[2589].j = { ["Bazzalan|Ragefire Chasm"] = { e = "Bazzalan", i = "Ragefire Chasm", df = "Normal", at = world.clock } }
check(openItem(thalia, 1, 2589), "Thalia couldn't open the linen")
advance(10)
local ts = thalia.db().sources and thalia.db().sources[2589]
check(ts and ts.d.c2167 and ts.d.c2167.g == joanCalled and ts.v[6737] and not ts.v[6737].g and ts.v[6737].p == 45 and not ts.v[1]
    and ts.j and ts.j["Bazzalan|Ragefire Chasm"] and ts.j["Bazzalan|Ragefire Chasm"].i == "Ragefire Chasm",
    "Thalia's notes on the linen from the guild, her own kept hers")
for _, m in ipairs(carried(srcFrom)) do check(not (m.msg.t == "src" and m.from ~= joan.full), "notes came from " .. m.from .. ", who doesn't share them") end
brannoc.ns.send({ kind = "WHISPER", target = thalia.full }, { t = "src", id = 2589, s = { v = { { key = 99, x = { n = "Fake Vendor", p = 1 } } } } }, true)
advance(5)
check(not ts.v[99], "a whispered note was kept")
-- Sharing, Thalia passes on only her own notes, never what Joan told her.
thalia.db().settings.sharePrices = true
local passFrom = #world.log
mira.ns.askSources(2589)
advance(10)
thalia.db().settings.sharePrices = nil
local passed = false
for _, m in ipairs(carried(passFrom)) do
    if m.msg.t == "src" and m.from == thalia.full then
        passed = true
        check(not m.msg.s.d and m.msg.s.v, "Thalia passed on notes Joan gave her")
    end
end
check(passed, "Thalia didn't answer with her own notes")
thalia.slash("")
mira.db().sources = nil
-- Five more days at the house, the market moving, for the dashboard's sample: each day's lowest
-- price of the house's real items, as the dashboard's history on the PC keeps them.
local hist = { houses = { [house] = { seen = 0, items = {} } } }
local function remember()
    local h = joan.db().prices[house]
    local rec = hist.houses[house]
    for id, e in pairs(h.items) do
        local at = e.at or h.at
        if id < 300000 and e.p and at > rec.seen then
            local day = os.date("%Y-%m-%d", at)
            local points = rec.items[tostring(id)] or {}
            rec.items[tostring(id)] = points
            if not points[day] or e.p < points[day][1] then points[day] = { e.p, e.q } end
        end
    end
    rec.seen = math.max(rec.seen, h.at)
end
remember()
for _, f in ipairs({ 0.96, 1.05, 1.11, 0.98, 1.03 }) do
    world.clock = world.clock + 86400
    for _, a in ipairs(world.auctions[house]) do if a[1] < 300000 and a[3] > 0 then a[3] = math.floor(a[3] * f + 0.5) end end
    visit(joan, auctioneer)
    leave(joan)
    remember()
end
check(#(function() local o = {} for d in pairs(hist.houses[house].items["858"]) do o[#o + 1] = d end return o end)() >= 5, "the sample's price history")
world.priceHistory = hist
end

-- Joan's guild and what others share with her, as they are now, for the dashboard's sample.
local function copy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, x in pairs(v) do out[k] = copy(x) end
    return out
end
local snapshot = { guilds = copy(joan.db().guilds), peers = copy(joan.db().peers), items = copy(joan.db().items), prices = copy(joan.db().prices),
    sources = copy(joan.db().sources), history = copy(world.priceHistory) }
-- Blizzard's own prices, which the dashboard on Joan's PC hands her game while it's closed: she takes
-- them at login when they're newer than what she has, and lets the feed go. Nobody shares scans
-- now, yet Blizzard's prices pass through the guild, marked Blizzard's, and whoever has them passes
-- them on, Joan away or not. Thirty days at most, by Blizzard's terms.
do
local house, neutral = REALM .. "|Alliance", REALM .. "|Neutral"
for _, c in ipairs({ joan, thalia, mira, faelwen }) do c.db().settings.sharePrices = nil end
world.clock = world.clock + 3600 -- the game closed an hour, the PC reading Blizzard meanwhile
local fed = world.clock - 600
local neutralBefore = joan.db().prices[neutral] and joan.db().prices[neutral].at
joan.feed = { [house] = { at = fed, n = 34110, items = { [858] = { p = 1700, q = 40 }, [2589] = { p = 95, q = 300 }, x = { p = 1 }, [77] = { p = -5 } } },
    ["no house"] = { at = fed, items = { [858] = { p = 1 } } },
    [REALM .. "|Horde"] = { at = world.clock - 31 * 86400, n = 9, items = { [858] = { p = 1 } } } }
newSession(joan)
local jb = joan.db().prices[house]
check(jb and jb.api and jb.by == "Blizzard" and not jb.own and jb.at == fed and jb.n == 34110 and jb.items[858].p == 1700 and jb.items[2589].q == 300
    and not jb.items[77] and not jb.items.x, "Joan didn't take Blizzard's prices as they came")
check(joan.feedLeft() == nil, "the game would write the dashboard's prices back")
check(not joan.db().prices["no house"] and not joan.db().prices[REALM .. "|Horde"] and (joan.db().prices[neutral] and joan.db().prices[neutral].at) == neutralBefore,
    "a broken or month-old house was taken")
check(joan.ns.priceLine(858):find("· Blizzard's hourly prices, ", 1, true), "Joan's price line: " .. joan.ns.priceLine(858))
local offer = joan.ns.priceOffer()
check(offer and #offer == 1 and offer[1].h == house and offer[1].at == fed, "Joan, who doesn't share her scans, offers something besides Blizzard's prices")
local from = #world.log + 1
joan.ns.guildHello()
advance(180)
for _, c in ipairs({ thalia, mira, faelwen }) do
    local p = c.db().prices[house]
    check(p and p.api and p.by == "Blizzard" and not p.own and p.at == fed and p.items[858].p == 1700, c.name .. " didn't get Blizzard's prices from Joan")
    check(c.ns.priceLine(858):find("· Blizzard's hourly prices, ", 1, true), c.name .. "'s price line: " .. c.ns.priceLine(858))
end
local marked, unmarked = 0, 0
for _, m in ipairs(carried(from)) do
    if m.msg.t == "pr" then if m.msg.b == 1 and m.msg.h == house then marked = marked + 1 else unmarked = unmarked + 1 end end
end
check(marked >= 1 and unmarked == 0, ("Blizzard's prices went in %d marked parts and %d others"):format(marked, unmarked))
-- With Joan away, Faelwen, who lost hers, gets them from Thalia.
joan.online = false
faelwen.db().prices[house] = nil
local relayFrom = #world.log + 1
thalia.ns.guildHello()
advance(180)
local fp = faelwen.db().prices[house]
check(fp and fp.api and fp.by == "Blizzard" and fp.at == fed and fp.items[2589].p == 95, "Faelwen didn't get Blizzard's prices from Thalia while Joan was away")
local relayed = false
for _, m in ipairs(carried(relayFrom)) do if m.msg.t == "pr" and m.from == thalia.full and m.msg.b == 1 then relayed = true end end
check(relayed, "Thalia didn't pass Blizzard's prices on")
joan.online = true
-- As most players will, nobody shows the guild their reliquary now: Mira, who lost her prices, logs
-- in, and a guildmate who has them answers her hello all the same, so they reach her; logging in
-- again with them, nobody answers, and a hello with nothing but prices to offer still goes out.
local guildWas = {}
for _, c in ipairs({ joan, thalia, mira, faelwen }) do
    guildWas[c] = c.ns.shares().guild
    c.ns.shares().guild = false
end
mira.db().prices[house] = nil
local loginFrom = #world.log + 1
newSession(mira)
advance(200)
local mp2 = mira.db().prices[house]
check(mp2 and mp2.api and mp2.at == fed, "Mira, logging in, didn't get Blizzard's prices from guildmates who don't share with the guild")
local answers = 0
for _, m in ipairs(carried(loginFrom)) do
    if m.msg.t == "hi" and m.from ~= mira.full and m.msg.px then answers = answers + 1 end
    check(not (m.msg.t == "hi" and m.msg.s and m.from ~= mira.full), m.from .. " offered its reliquary to the guild with guild sharing off")
end
check(answers >= 1 and answers <= 3, ("guildmates answered Mira with prices %d times"):format(answers))
-- A hello with nothing but prices to offer still goes out (Mira's: she hasn't sent hers on); one
-- who sent the same prices within the half hour doesn't offer them, as it wouldn't send them.
local pxOnly = #world.log + 1
mira.ns.guildHello()
advance(5)
local went = false
for _, m in ipairs(carried(pxOnly)) do if m.msg.t == "hi" and m.from == mira.full and m.msg.px and not m.msg.s then went = true end end
check(went, "a hello with only prices to offer didn't go out")
check(joan.ns.priceOffer() == nil, "Joan offers prices she sent within the half hour")
-- A half hour on, everyone may send them again: Mira, logging in again with them, isn't answered,
-- and nothing goes around.
world.clock = world.clock + 31 * 60
check(joan.ns.priceOffer() ~= nil, "Joan doesn't offer her prices a half hour on")
local quietFrom = #world.log + 1
newSession(mira)
advance(60)
for _, m in ipairs(carried(quietFrom)) do
    check(not (m.msg.t == "hi" and m.from ~= mira.full and m.msg.px), m.from .. " answered Mira with prices she has")
    check(m.msg.t ~= "pr?" and m.msg.t ~= "pr", "prices everyone has went around again")
end
-- Two guildmates offering the same prices at once: Mira, who lost hers, asks only one of them, and
-- has them.
mira.db().prices[house] = nil
local twiceFrom = #world.log + 1
mira.ns.onPriceOffer({ { h = house, at = fed } }, thalia.full)
mira.ns.onPriceOffer({ { h = house, at = fed } }, faelwen.full)
advance(120)
local asks = 0
for _, m in ipairs(carried(twiceFrom)) do if m.msg.t == "pr?" and m.from == mira.full then asks = asks + 1 end end
check(asks == 1 and mira.db().prices[house] and mira.db().prices[house].at == fed, ("Mira asked %d times for prices two guildmates offered"):format(asks))
-- Prices that came meanwhile (the answer to someone else's ask) leave nothing to ask.
local keep, fed3 = mira.db().prices[house], fed + 7
local alreadyFrom = #world.log + 1
mira.ns.onPriceOffer({ { h = house, at = fed3 } }, thalia.full)
mira.db().prices[house] = { at = fed3, by = "Blizzard", api = true, items = { [858] = { p = 1600, q = 1 } } }
advance(10)
for _, m in ipairs(carried(alreadyFrom)) do check(not (m.msg.t == "pr?" and m.from == mira.full), "Mira asked for prices she had come by meanwhile") end
mira.db().prices[house] = keep
-- A newer read reaches Joan and Faelwen; Mira hears Joan offer it and asks her, but Joan goes away
-- before answering. Faelwen's offer, heard while that ask was out, waits: offered again later, Mira
-- asks her, and has it.
local fed2 = world.clock - 60
for _, c in ipairs({ joan, faelwen }) do
    c.db().prices[house] = { at = fed2, by = "Blizzard", api = true, n = 2, items = { [858] = { p = 1650, q = 41 }, [2589] = { p = 97, q = 280 } } }
end
joan.online = false
mira.ns.onPriceOffer({ { h = house, at = fed2 } }, joan.full)
advance(10)
mira.ns.onPriceOffer({ { h = house, at = fed2 } }, faelwen.full)
advance(320)
check(mira.db().prices[house].at == fed, "Mira had prices from a guildmate who went away")
local fallFrom = #world.log + 1
mira.ns.onPriceOffer({ { h = house, at = fed2 } }, faelwen.full)
advance(60)
local askedFaelwen = false
for _, m in ipairs(carried(fallFrom)) do if m.msg.t == "pr?" and m.from == mira.full and m.msg.to == faelwen.full then askedFaelwen = true end end
check(askedFaelwen and mira.db().prices[house].at == fed2 and mira.db().prices[house].items[858].p == 1650, "Mira didn't ask another guildmate once the one asked went away")
joan.online = true
for c, was in pairs(guildWas) do c.ns.shares().guild = was end
-- An older feed never replaces newer prices.
local had = joan.db().prices[house]
joan.feed = { [house] = { at = fed - 3600, n = 1, items = { [858] = { p = 1, q = 1 } } } }
newSession(joan)
check(joan.db().prices[house].at == had.at and joan.db().prices[house].items[858].p == had.items[858].p and joan.feedLeft() == nil,
    "an older feed replaced newer prices")
-- Kept a month, they go at login; a check made at the house since stays. A month-old part from the
-- guild isn't taken.
mira.db().prices[house] = { at = world.clock - 31 * 86400, by = "Blizzard", api = true, n = 5,
    items = { [858] = { p = 1, q = 1 }, [2589] = { p = 90, q = 3, at = world.clock - 60 } } }
newSession(mira)
local mp = mira.db().prices[house]
check(mp and not mp.api and not mp.at and not mp.items[858] and mp.items[2589] and mp.items[2589].p == 90, "a month of Blizzard's prices stayed, or a check made since went")
thalia.ns.send({ kind = "GUILD" }, { t = "pr", h = house, at = world.clock - 31 * 86400 + 60, k = 1, of = 1, b = 1, l = { 858, 2, 1 } }, true)
advance(5)
check(not mira.db().prices[house].api, "a month-old part of Blizzard's prices was taken from the guild")
mira.db().prices[house] = nil
end
-- Nobody else's word counts: settings from a guildmate, records from a Member, a tab sent to the
-- whole guild that isn't open to everyone, and a Member vouching for a tab her rank may not see.
local jg = joan.db().guilds[gk()]
mira.ns.send({ kind = "GUILD" }, { t = "bp", p = { at = world.clock + 999, tb = { "a", "a", "a", "a" } } }, true)
thalia.ns.send({ kind = "WHISPER", target = joan.full }, { t = "gb", i = 3, ra = world.clock + 5, lg = { { k = "withdraw", w = "Joan", id = 6505, n = 1, at = world.clock } } }, true)
mira.ns.send({ kind = "GUILD" }, { t = "gb", i = 1, at = world.clock + 5, by = "Mira", nm = "Reagents", s = { [1] = { id = 2589, c = 1 } } }, true)
brannoc.ns.send({ kind = "WHISPER", target = joan.full }, { t = "gb", i = 1, at = world.clock + 5, by = "Brannoc", nm = "Reagents", s = { [1] = { id = 2589, c = 1 } } }, true)
local old = firstSettings
faelwen.ns.send({ kind = "GUILD" }, { t = "bp", p = { at = old.at, tb = old.tb, rc = old.rc, kp = old.kp, n = old.n, nm = old.nm, v = old.v } }, true)
advance(30)
check(jg.policy.h == fp.h and thalia.db().guilds[gk()].policy.h == fp.h, "a guildmate's forged settings, or the guild master's older ones, replaced the newest")
check(jg.bank.tabs[1].by ~= "Brannoc", "a tab from someone outside the guild was kept")
check(jg.bank.logs[3].list[1].k == "deposit", "a Member's forged log replaced the keeper's")
check(jg.bank.tabs[1].slots[1].id == 765 and thalia.db().guilds[gk()].bank.tabs[1].slots[1].id == 765, "a tab sent to the whole guild was kept")
-- Nor on the bank's board: a Member setting an item aside, an ask on the whole guild for a tab
-- that isn't open to everyone, a Member passing on a board, someone outside the guild, and a clock
-- two hours ahead.
local staffAside = word(joan, "aside", 3, 6505, thalia.full)
thalia.ns.send({ kind = "WHISPER", target = joan.full }, { t = "bd", i = 3, it = 6505, k = "a", w = mira.full, at = world.clock }, true)
mira.ns.send({ kind = "GUILD" }, { t = "bd", i = 2, it = 3742, k = "w", at = world.clock }, true)
thalia.ns.send({ kind = "WHISPER", target = joan.full }, { t = "gb", i = 3, ba = world.clock + 5,
    bd = { list = { { id = 6505, a = { { w = thalia.full, b = thalia.full, at = world.clock + 5, x = 1 } } } } } }, true)
brannoc.ns.send({ kind = "WHISPER", target = joan.full }, { t = "bd", i = 2, it = 3742, k = "w", at = world.clock }, true)
mira.ns.send({ kind = "WHISPER", target = joan.full }, { t = "bd", i = 2, it = 264154, k = "w", at = world.clock + 7200 }, true)
thalia.ns.send({ kind = "WHISPER", target = joan.full }, { t = "bd", i = 2, it = 2075, k = "w", at = world.clock, v = "bogus", lv = 5, f = world.clock + 99999 }, true)
advance(20)
local bogus = word(joan, "asks", 2, 2075, thalia.full)
check(bogus and bogus.v == nil and bogus.lv == nil and bogus.f == bogus.at, "an ask's broken verdict or first time was kept")
check(not word(joan, "aside", 3, 6505, mira.full), "a Member's set-aside was kept")
check(not word(joan, "asks", 2, 3742, mira.full) and not word(thalia, "asks", 2, 3742, mira.full), "an ask on the whole guild for a tab that isn't open to everyone was kept")
check(not word(joan, "asks", 2, 3742, brannoc.full), "an ask from outside the guild was kept")
check(not word(joan, "asks", 2, 264154, mira.full), "an ask from a clock two hours ahead was kept")
local still = word(joan, "aside", 3, 6505, thalia.full)
check(still and not still.off and still.at == staffAside.at, "a Member's copy of the board took the staff back")
check(not (jg.heard or {})[brannoc.full] and (jg.heard or {})[mira.full], "who uses Reliquary is learned from the guild channel only")
-- A Member offering the bank as if she kept its board: nobody asks her for it, and Mira's game
-- doesn't send her its own asks as it would an officer.
local offeredFrom = #world.log
thalia.ns.send({ kind = "GUILD" }, { t = "hi", v = "1.3.0", b = { t = { [2] = { ba = world.clock + 50 } } } }, true)
thalia.ns.send({ kind = "GUILD" }, { t = "hi", v = "1.3.0", b = { t = { [2] = { at = 1 } } } }, true)
advance(20)
for _, m in ipairs(carried(offeredFrom)) do
    check(not (m.msg.t == "ask" and m.msg.to == thalia.full and m.msg.bt), "a guildmate asked a Member for the bank's board")
    check(not (m.msg.t == "bd" and m.from == mira.full and m.target == thalia.full), "Mira sent her asks to a Member as if she kept the board")
end
-- Mira takes the gloves out of the bank: once a copy of the Gear tab without them is read, their
-- set-aside and her ask go, wherever the new copy reaches. The staff stays set aside.
BANK.tabs[2][4][1] = nil
openBank(joan)
advance(15)
closeBank(joan)
advance(300)
for _, c in ipairs({ joan, thalia, mira, faelwen }) do
    check(not word(c, "aside", 2, 14146, mira.full) and not word(c, "asks", 2, 14146, mira.full), c.name .. " keeps the gloves set aside after they left the bank")
    check(word(c, "aside", 3, 6505, thalia.full), c.name .. " lost the staff's set-aside")
end
-- A late word about them, older than Joan's copy of the tab, is moot (in a fight, so no tidying
-- hides a word kept).
joan.combat = true
mira.ns.send({ kind = "WHISPER", target = joan.full }, { t = "bd", i = 2, it = 14146, k = "w", at = joanTabAt(joan) - 60 }, true)
advance(3)
check(not word(joan, "asks", 2, 14146, mira.full), "a word older than Joan's copy of the tab, about gloves no longer in it, was kept")
joan.combat = false
-- The guild master keeps Potions in the game only: it leaves every Reliquary, records and all.
faelwen.ui.choose(pickFor(faelwen, 4), "Game only")
advance(60)
for _, c in ipairs({ joan, thalia, mira }) do
    local b = c.db().guilds[gk()].bank
    check(not b.tabs[4] and not (b.logs and b.logs[4]) and not (b.notes and b.notes[4]), c.name .. " still keeps the Potions tab, which the guild master keeps in the game only")
end
-- The Officers tab back to officers only, while Joan's copy for Thalia waits out a fight: it stays
-- home. Thalia's own copy goes, and a Member can't vouch for it any more: Mira whispers Joan an
-- Officers tab of her own making, and Joan's game knows Mira's rank may not see it.
BANK.tabs[3][4][3] = { 2589, 2 }
openBank(joan)
advance(15)
closeBank(joan)
joan.combat = true
advance(30)
thalia.ns.send({ kind = "GUILD" }, { t = "ask", to = joan.full, bt = { 3 } }, true)
advance(10)
local waitedFrom = #world.log
faelwen.ui.choose(pickFor(faelwen, 3), "As in game")
advance(5)
joan.combat = false
advance(60)
for _, m in ipairs(carried(waitedFrom)) do
    check(not (m.msg.t == "gb" and m.msg.i == 3 and m.target == thalia.full), "the Officers tab waiting out Joan's fight went to Thalia after it went back to officers only")
end
check(not thalia.db().guilds[gk()].bank.tabs[3], "Thalia keeps the Officers tab after it went back to officers only")
check(not boardOf(thalia, 3) and boardOf(joan, 3), "Thalia keeps the Officers tab's board after it went back to officers only")
-- Now a word on the Officers tab goes only to officers; Thalia keeps none sent her, and Mira can't
-- ask for what her rank may not see.
local officersFrom = #world.log
thalia.combat = true -- no tidying hides a word she kept
joan.ns.send({ kind = "WHISPER", target = thalia.full }, { t = "bd", i = 3, it = 6505, k = "a", w = mira.full, at = world.clock }, true)
advance(3)
check(not boardOf(thalia, 3), "Thalia kept a word on a tab her rank may not see")
thalia.combat = false
check(joan.ns.setAside(5498, faelwen.full), "Joan couldn't set the pearls aside for Faelwen")
mira.ns.send({ kind = "WHISPER", target = joan.full }, { t = "bd", i = 3, it = 6505, k = "w", at = world.clock }, true)
advance(30)
local toOfficers = 0
for _, m in ipairs(carried(officersFrom)) do
    if m.msg.t == "bd" and m.from == joan.full and m.msg.it == 5498 then
        local to = world.byName[m.target]
        check(to and to.rank <= 2, "a word on the officers-only tab went to " .. tostring(m.target))
        toOfficers = toOfficers + 1
    end
end
check(toOfficers == 1 and word(faelwen, "aside", 3, 5498, faelwen.full), "the pearls set aside didn't reach Faelwen alone")
check(not word(joan, "asks", 3, 6505, mira.full), "Mira asked for the staff on a tab her rank may not see")
-- Thalia's bank holds nothing that would help anyone now: no filter.
thalia.ns.showViewer(TAB.Bank)
for _, f in ipairs(thalia.ui.frames) do
    local label = f._kind == "CheckButton" and (rawget(f, "Text") or rawget(f, "label"))
    check(not (label and label._text == "Helps someone" and f:IsVisible()), "the Helps someone filter shows with nothing to show")
end
thalia.slash("")
mira.ns.send({ kind = "WHISPER", target = joan.full }, { t = "gb", i = 3, at = world.clock + 5, by = "Mira", nm = "Officers", s = { [1] = { id = 2589, c = 1 } } }, true)
advance(20)
check(jg.bank.tabs[3].by ~= "Mira" and jg.bank.tabs[3].slots[1].id == 5498, "a Member's copy of a tab her rank may not see was kept")
-- A new guild master: Faelwen's settings stop counting everywhere at once, and what only they
-- opened goes. Mira, who never visited the bank, keeps no tabs; Thalia keeps those her rank views.
faelwen.rank = 2
for _, m in ipairs(GUILD.others) do if m[1] == "Corvane" then m[4] = 1 end end
advance(61)
for _, c in ipairs({ joan, thalia, mira, faelwen }) do c.fire("GUILD_ROSTER_UPDATE") end
advance(5)
check(not next(mira.db().guilds[gk()].bank.tabs), "Mira keeps tabs that only the old guild master's settings showed her")
tb = thalia.db().guilds[gk()].bank
check(tb.tabs[1] and tb.tabs[2] and not tb.tabs[3], "Thalia keeps the Officers tab after the guild master who opened it stepped down")
faelwen.slash("")
thalia.slash("")
joan.slash("")

---------------------------------------------------------------------------
-- 8g. Item details: each item's whole tooltip, read once the game has the item
---------------------------------------------------------------------------
-- The game fetches an item the first time anything asks for it, and a tooltip read before it comes
-- says only "Retrieving item information", in red. Joan's game had to fetch the bank's items and
-- those her guildmates show: she keeps each as the game shows it, whole.
local function tipLines(c, id)
    local out, rec = {}, c.db().items[id]
    for _, line in ipairs(rec and rec.tip or {}) do out[#out + 1] = (line.l or "") .. (line.r and (" | " .. line.r) or "") end
    return out
end
local function hasLines(c, id, want)
    local have = {}
    for _, l in ipairs(tipLines(c, id)) do have[l] = true end
    for _, w in ipairs(want) do if not have[w] then return false end end
    return true
end
check(joan.loadRequests > 0, "Joan's game never had to fetch an item")
check(hasLines(joan, 6505, { "Crescent Staff", "Binds when equipped", "Two-Hand | Staff", "47 - 71 Damage | Speed 2.90", "(20.3 damage per second)", "+7 Stamina",
    "+7 Intellect", "+7 Spirit", "Durability 90 / 90", "Requires Level 16" }), "the staff kept without its stats: " .. table.concat(tipLines(joan, 6505), "; "))
check(hasLines(joan, 14146, { "Hands | Cloth", "18 Armor", "+5 Intellect", "+4 Spirit", "Durability 25 / 25", "Requires Level 19" }),
    "the gloves kept without their stats: " .. table.concat(tipLines(joan, 14146), "; "))
-- An Equip: or Use: line waits for its spell: the game fills each in and says so, and Joan's copy
-- has them all (Thalia's ring, with two, and her trinket, which she shows the guild).
check(hasLines(joan, 264208, { "Band of Elune", "+5 Intellect", "Equip: Increases healing done by up to 9 and damage done by up to 3 for all magical spells and effects.",
    "Equip: Restores 2 mana per 5 sec.", "Requires Level 19" }),
    "the ring's Equip: line: " .. table.concat(tipLines(joan, 264208), "; "))
check(hasLines(joan, 264209, { "Use: Restores 135 mana. (5 Min Cooldown)" }), "the trinket's Use: line: " .. table.concat(tipLines(joan, 264209), "; "))
-- Nobody kept a tooltip the game hadn't filled in.
for _, c in ipairs(world.clients) do
    for id, rec in pairs(c.db().items) do
        for _, line in ipairs(type(rec) == "table" and rec.tip or {}) do
            check(line.l ~= "Retrieving item information", c.name .. " kept item " .. tostring(id) .. " before the game had it")
        end
    end
end
-- An item that doesn't exist is asked for once, and nothing waits for it.
local asked = joan.loadRequests
joan.ns.rememberLink(999999, "|cffffffff|Hitem:999999::::::::20:::::|h[Nothing]|h|r")
advance(5)
check(joan.loadRequests == asked + 1 and not joan.db().items[999999], "an item that doesn't exist was asked for " .. (joan.loadRequests - asked) .. " times")
-- The game may say any tooltip has changed, naming none: Reliquary reads again those it read in
-- the last minute, and lets older ones go.
joan.ns.rememberLink(5523, link(5523))
advance(1)
local clam = joan.tooltipReads[5523] or 0
check(clam == 1 and hasLines(joan, 5523, { "Small Barnacled Clam" }), "the clam's tooltip: read " .. clam .. " times")
joan.fire("TOOLTIP_DATA_UPDATE")
advance(1)
check(joan.tooltipReads[5523] == 2, "a tooltip read a moment ago wasn't read again when the game said tooltips changed")
advance(61)
joan.fire("TOOLTIP_DATA_UPDATE")
advance(1)
check(joan.tooltipReads[5523] == 2, "a tooltip read over a minute ago was read again")
-- An item whose game fills in two lines one after the other: Reliquary reads it again each time the
-- game says so, until it's whole.
joan.ns.rememberLink(90001, link(90001))
advance(3)
check(hasLines(joan, 90001, { "Charm of Two Spells", "Equip: Restores 1 mana per 5 sec.", "Use: Restores 100 mana. (5 Min Cooldown)" }),
    "the charm, filled in twice: " .. table.concat(tipLines(joan, 90001), "; "))
-- An item linked in guild chat that Joan's game has never loaded: it fetches it, weighs it the
-- moment it comes, and her verdict is in what she keeps within seconds, not at her next change.
check(not joan.itemCache[90002], "Joan's game already had the circlet")
joan.fire("CHAT_MSG_GUILD", "anyone need this? |cff1eff00|Hitem:90002::::::::12:::::|h[Circlet of Quiet Rain]|h|r", thalia.full)
advance(18)
local fitsNow = joan.db().chars[ownKey(joan)].fits
check(fitsNow and fitsNow[90002] and fitsNow[90002].v == "up", "Joan's verdict on the circlet linked in guild chat: " .. tostring(fitsNow and fitsNow[90002] and fitsNow[90002].v))
-- A recipe shows the dish it teaches, which the game fetches too: until it comes, that part says
-- "Retrieving item information" (and the game doesn't say when it has come). Reliquary reads the
-- recipe again a moment later, until it's whole.
joan.ns.rememberLink(2698, link(2698))
advance(4)
check(hasLines(joan, 2698, { "Recipe: Cooked Crab Claw", "Cooked Crab Claw", "Use: Restores 294 health over 21 sec. Must remain seated while eating.",
    "Use: Teaches you how to cook a Crab Claw.", "Requires Cooking (85)" }) and not hasLines(joan, 2698, { "Retrieving item information" }),
    "the recipe: " .. table.concat(tipLines(joan, 2698), "; "))
-- A dish that never comes: the recipe is read again five times, then left as it is till next time.
joan.ns.rememberLink(2699, link(2699))
advance(30)
check(joan.tooltipReads[2699] == 6 and hasLines(joan, 2699, { "Recipe: Lost Stew", "Retrieving item information" }),
    "a recipe whose dish never loads was read " .. tostring(joan.tooltipReads[2699]) .. " times")

---------------------------------------------------------------------------
-- 8h. Crafting: each character's recipes, read from its own profession window and shared with its
-- professions; who can make an item and whose recipes use it; a line at loot for what you can't use
---------------------------------------------------------------------------
do
local T = {}
function T.called(name) return fullOf(name):match("^([^%-]+)") end
function T.recipesOf(c) return c.db().chars[ownKey(c)].recipes end
function T.craftOf(c, name) local p = peer(c, name) return p and p.more and p.more.craft end
function T.profIn(craft, name) for _, x in ipairs(craft and craft.list or {}) do if x.n == name then return x end end end
function T.recipeIn(prof, rid) for _, r in ipairs(prof and prof.r or {}) do if r.id == rid then return r end end end
function T.who(list) local t = {} for _, e in ipairs(list) do t[#t + 1] = e.name .. ":" .. e.kind .. ":" .. e.prof end return table.concat(t, ",") end
function T.count(t) local n = 0 for _ in pairs(t or {}) do n = n + 1 end return n end
-- The profession window: opened on a profession (another player's, if linked), or switched to
-- another while open; closed.
function T.open(c, prof, linked)
    c.window = { prof = prof, linked = linked }
    c.fire(c.windowOpen and "TRADE_SKILL_DATA_SOURCE_CHANGED" or "TRADE_SKILL_SHOW")
    c.windowOpen = true
    advance(3)
end
function T.close(c) c.window, c.windowOpen = nil, nil c.fire("TRADE_SKILL_CLOSE") advance(1) end
-- What the game says in chat when this character receives an item (its own GUID with it), or the
-- words given.
function T.loot(c, id, n, guid, words)
    c.itemCache[id] = true
    local text = (words or ((n or 1) > 1 and ("You receive loot: %sx" .. n .. ".") or "You receive loot: %s.")):format(link(id))
    c.fire("CHAT_MSG_LOOT", text, c.full, "", "", c.full, "", 0, 0, "", 0, 1, guid or c.env.UnitGUID("player"))
end
function T.lines(c, from) local out = {} for k = from + 1, #c.printed do out[#out + 1] = c.printed[k] end return out end

-- Everyone here shows the guild their professions, and Brannoc shows his friends. Faelwen works
-- leather, and skins.
for _, c in ipairs({ joan, thalia, faelwen, mira }) do
    c.ns.setShare("guild", true)
    c.ns.setPart("profs", "guild", true)
end
brannoc.ns.setShare("friends", true)
brannoc.ns.setPart("profs", "friends", true)
faelwen.opts.profs = { { "Leatherworking", 136247, 96, 150 }, { "Skinning", 134366, 90, 150 } }
faelwen.fire("SKILL_LINES_CHANGED")
advance(5)

do
-- Thalia opens her Tailoring: the recipes she has learned are kept with what each makes, what goes
-- into it and its group in the window; Linen Boots, which she hasn't learned, isn't.
thalia.crafts = { Tailoring = { skill = 102, max = 150, known = { [2963] = true, [2385] = true } },
    Enchanting = { skill = 87, max = 150, known = { [7418] = true, [7421] = true } } }
T.open(thalia, "Tailoring")
local tt = T.recipesOf(thalia) and T.recipesOf(thalia).Tailoring
check(tt and tt.list[2963] and tt.list[2385] and not tt.list[2386] and tt.sk == 102 and tt.mx == 150 and tt.line == 197, "Thalia's Tailoring")
local vest = tt.list[2385]
check(vest.n == "Brown Linen Vest" and vest.o == 2568 and #vest.u == 2 and vest.u[1].id == 2996 and vest.u[2].id == 2320 and vest.u[1].n == 1
    and tt.cats[vest.c] == "Armor" and vest.ic == 132665, "the vest's recipe")
check(thalia.db().sources[2568].m[2385].p == "Tailoring" and thalia.db().sources[2996].r[2385].o == 2568, "the vest in where items come from")
-- Her Enchanting, in the same window: an enchantment makes no item.
T.open(thalia, "Enchanting")
local te = T.recipesOf(thalia).Enchanting
check(te and te.list[7418] and not te.list[7418].o and te.list[7418].u[1].id == 10940 and te.list[7421].o == 6218, "Thalia's Enchanting")
-- The game may say the list changed while the window is shut: nothing is read until it opens.
T.close(thalia)
advance(61)
thalia.crafts.Tailoring.known[2386] = true
thalia.window = { prof = "Tailoring" }
thalia.fire("TRADE_SKILL_LIST_UPDATE")
advance(3)
check(not T.recipesOf(thalia).Tailoring.list[2386], "a profession was read with its window shut")
thalia.crafts.Tailoring.known[2386], thalia.window = nil, nil
-- A list the game is still filling in gives part of it: what was read before stays.
T.open(thalia, "Tailoring")
thalia.window.only = { [2963] = true }
thalia.fire("TRADE_SKILL_LIST_UPDATE")
advance(62)
thalia.fire("TRADE_SKILL_LIST_UPDATE")
advance(3)
check(T.recipesOf(thalia).Tailoring.list[2385] and T.recipesOf(thalia).Tailoring.list[2963], "a part of the list read later dropped a recipe")
thalia.window.only = nil
-- Faelwen's Leatherworking, linked in chat and opened in Thalia's window, is never Thalia's.
faelwen.crafts = { Leatherworking = { skill = 96, max = 150, known = { [2881] = true, [3816] = true, [2149] = true } } }
T.open(thalia, "Leatherworking", faelwen)
check(not T.recipesOf(thalia).Leatherworking, "someone else's profession, linked, was kept as Thalia's")
T.close(thalia)
-- A window closed part way through a read keeps nothing of it; the next opening reads it whole.
faelwen.closeAfter, faelwen.recipeReads = 2, 0
T.open(faelwen, "Leatherworking")
check(not (T.recipesOf(faelwen) and T.recipesOf(faelwen).Leatherworking), "a read cut short by closing the window was kept")
faelwen.windowOpen = nil
T.open(faelwen, "Leatherworking")
local fl = T.recipesOf(faelwen).Leatherworking
check(fl and fl.list[2881] and fl.list[3816] and fl.list[2149] and not fl.list[5244] and not fl.list[2163], "Faelwen's Leatherworking")
-- Skinning has no recipes to read: it isn't kept as a profession with none.
T.open(faelwen, "Skinning")
check(not T.recipesOf(faelwen).Skinning, "a profession without recipes was kept with none")
T.close(faelwen)
end
-- Brannoc's Mining and Blacksmithing.
brannoc.crafts = { Mining = { skill = 131, max = 150, known = { [2657] = true } }, Blacksmithing = { skill = 118, max = 150, known = { [2660] = true, [2663] = true } } }
T.open(brannoc, "Mining")
T.open(brannoc, "Blacksmithing")
T.close(brannoc)
-- The first goes out at once, and what changes after it within five minutes.
advance(320)

do
-- Their recipes reach Joan, the guildmates' on the guild channel and Brannoc's as a friend's, each
-- named by her own game; Mira, who isn't Brannoc's friend, never gets his.
local tc = T.craftOf(joan, "Thalia")
local tailoring = T.profIn(tc, "Tailoring")
local v = T.recipeIn(tailoring, 2385)
check(v and v.nm == "Brown Linen Vest" and v.o == 2568 and v.u[1].id == 2996 and v.u[1].n == 1 and tailoring.c[v.c] == "Armor" and tailoring.l == 197,
    "Thalia's vest as Joan has it")
local ench = T.recipeIn(T.profIn(tc, "Enchanting"), 7418)
check(ench and not ench.o and ench.nm == "Enchant Bracer - Minor Health", "Thalia's enchantment as Joan has it")
check(T.profIn(T.craftOf(joan, "Faelwen"), "Leatherworking") and T.profIn(T.craftOf(joan, "Brannoc"), "Mining") and T.profIn(T.craftOf(joan, "Brannoc"), "Blacksmithing"),
    "Faelwen's and Brannoc's recipes")
check(not T.craftOf(mira, "Brannoc") and T.craftOf(mira, "Faelwen"), "who got Brannoc's and Faelwen's recipes")
-- What their recipes make and use, kept with its tooltip for the dashboard.
check(joan.db().items[2304] and joan.db().items[2304].info.name == "Light Armor Kit" and joan.db().items[4289], "the recipes' items, kept for the dashboard")
end
-- Who can make an item, and whose recipes use it: Joan herself, her guildmates and her friend.
advance(2)
check(T.who(joan.ns.whoCanMake(2304)) == T.called("Faelwen") .. ":g:Leatherworking", "who can make the armor kit: " .. T.who(joan.ns.whoCanMake(2304)))
check(T.who(joan.ns.whoCanMake(2840)) == T.called("Brannoc") .. ":f:Mining", "who can make copper bars: " .. T.who(joan.ns.whoCanMake(2840)))
check(T.who(joan.ns.whoCanMake(118)) == "Joan:me:Alchemy", "who can make the potion: " .. T.who(joan.ns.whoCanMake(118)))
check(T.who(joan.ns.whoUses(2318)) == T.called("Faelwen") .. ":g:Leatherworking" and #joan.ns.whoUses(2318)[1].recipes == 2,
    "whose recipes use light leather: " .. T.who(joan.ns.whoUses(2318)))
-- Another of Joan's characters, on her realm and side, mines: hers come first.
T.bramKey = (REGIONAL and "Bram Ofârc" or "Bram") .. "-" .. REALM
joan.db().chars[T.bramKey] = { name = "Bram", surname = "Ofârc", realm = REALM, faction = "Alliance", classFile = "WARRIOR", level = 15, updated = world.clock,
    profs = { { name = "Mining", skill = 60, max = 75 }, { name = "Alchemy", skill = 30, max = 75 } },
    recipes = { Mining = { line = 186, at = world.clock, sk = 60, mx = 75, list = { [2657] = { n = "Smelt Copper", o = 2840, u = { { id = 2770, n = 1 } } } } },
        Alchemy = { line = 171, at = world.clock, sk = 30, mx = 75, list = { [2330] = { n = "Minor Healing Potion", o = 118, u = { { id = 2447, n = 1 } } } } } } }
advance(2)
check(T.who(joan.ns.whoCanMake(2840)) == "Bram:own:Mining," .. T.called("Brannoc") .. ":f:Mining", "who can make copper bars, Bram too: " .. T.who(joan.ns.whoCanMake(2840)))
-- Who else has an item: Bram's bags; not Joan's character on another realm, who can't trade with
-- her; and a guildmate who shows the guild her bags.
joan.db().chars[T.bramKey].bags = { { bag = 0, size = 16, free = 15, slots = { [3] = { id = 2770, n = 40 } } } }
joan.db().chars["Joan-CAMWOW US2 Realm 10 RP PvP"].bags = { { bag = 0, size = 16, free = 15, slots = { [1] = { id = 2770, n = 7 } } } }
thalia.slash("share bags guild on")
advance(320)
check(joan.ns.heldBy(2770) == "Bram (40)", "who has the copper ore: " .. tostring(joan.ns.heldBy(2770)))
-- (Linen: the Reagents tab's 20 and the 2 an officer put in the Officers tab.)
check(joan.ns.heldBy(2589) == "the guild bank (22) and " .. T.called("Thalia") .. " (12)", "who has the linen: " .. tostring(joan.ns.heldBy(2589)))
thalia.slash("share bags guild off")
advance(30)

do
-- Joan (Herbalism and Alchemy) loots light leather: no profession of hers uses it, Faelwen's
-- Leatherworking does. Once a day.
local from = #joan.printed
T.loot(joan, 2318, 2)
local said1 = T.lines(joan, from)
check(#said1 == 1 and said1[1] == joan.ns.TAG .. T.called("Faelwen") .. " can use your " .. link(2318) .. " for Leatherworking.",
    "the line when Joan loots light leather: " .. table.concat(said1, " | "))
T.loot(joan, 2318, 3)
check(#T.lines(joan, from) == 1, "the light leather was mentioned twice in a day")
-- What her own recipes use (peacebloom), what she makes herself, what someone else loots, and what
-- nobody uses: nothing.
T.loot(joan, 2447, 4)
T.loot(joan, 2840, 1, nil, "You create: %s.")
T.loot(joan, 783, 1, thalia.env.UnitGUID("player"), T.called("Thalia") .. " receives loot: %s.")
T.loot(joan, 4306, 2)
check(#T.lines(joan, from) == 1, "lines at loot: " .. table.concat(T.lines(joan, from), " | "))
-- Copper ore: Bram, hers, and Brannoc, her friend, both mine.
T.loot(joan, 2770, 5)
local said2 = T.lines(joan, from)
check(#said2 == 2 and said2[2] == joan.ns.TAG .. "Bram and " .. T.called("Brannoc") .. " can use your " .. link(2770) .. " for Mining.",
    "the copper ore line: " .. tostring(said2[2]))
-- Strange dust for Thalia's Enchanting; rough stone for Brannoc's Blacksmithing.
T.loot(joan, 10940)
T.loot(joan, 2835)
local said3 = T.lines(joan, from)
check(#said3 == 4 and said3[3] == joan.ns.TAG .. T.called("Thalia") .. " can use your " .. link(10940) .. " for Enchanting."
    and said3[4] == joan.ns.TAG .. T.called("Brannoc") .. " can use your " .. link(2835) .. " for Blacksmithing.", "the dust and stone lines: " .. table.concat(said3, " | "))
-- Patterns: Faelwen (Leatherworking 96) can learn the Kodo Hide Bag; the White Leather Jerkin
-- needs 125; Handstitched Leather Boots she knows already.
T.loot(joan, 5083)
T.loot(joan, 2407)
T.loot(joan, 90010)
local said4 = T.lines(joan, from)
check(#said4 == 5 and said4[5] == joan.ns.TAG .. T.called("Faelwen") .. " can learn your " .. link(5083) .. ".", "the pattern lines: " .. table.concat(said4, " | "))
-- A day later, the light leather is news again; with "Who can use what I loot" off, nothing is.
local told = joan.db().chars[ownKey(joan)].told
told.c2318 = told.c2318 - 21 * 3600
T.loot(joan, 2318)
check(#T.lines(joan, from) == 6, "the light leather wasn't mentioned again the next day")
joan.ns.showViewer(TAB.Sharing)
local lootBox
for _, f in ipairs(joan.ui.frames) do if f._kind == "CheckButton" and f.key == "craftNews" and f:IsVisible() then lootBox = f end end
check(lootBox and lootBox:GetChecked(), "the Sharing tab's switch for lines at loot")
lootBox:SetChecked(false)
joan.ui.run(lootBox, "OnClick")
T.loot(joan, 783)
check(joan.db().settings.craftNews == false and #T.lines(joan, from) == 6, "a line at loot with the switch off")
lootBox:SetChecked(true)
joan.ui.run(lootBox, "OnClick")
T.loot(joan, 783)
check(#T.lines(joan, from) == 7 and T.lines(joan, from)[7]:find(link(783), 1, true), "the light hide line after the switch came back on")

end
-- Lines under items on the game's tooltips: who else can make it, whose recipes use it, who could
-- learn a pattern, and who has it; never what this character does itself.
check(joan.ns.tooltipLine(2304) == "Made by " .. T.called("Faelwen") .. " (Leatherworking)", "the kit's tooltip lines: " .. tostring(joan.ns.tooltipLine(2304)))
check(joan.ns.tooltipLine(2318) == "Used by " .. T.called("Faelwen") .. " (Leatherworking) · Held by the guild bank (20)",
    "the leather's tooltip lines: " .. tostring(joan.ns.tooltipLine(2318)))
check(joan.ns.tooltipLine(5083) == "Can be learned by " .. T.called("Faelwen") .. " (Leatherworking)", "the pattern's tooltip lines: " .. tostring(joan.ns.tooltipLine(5083)))
check(T.who(joan.ns.whoCanMake(118)) == "Joan:me:Alchemy,Bram:own:Alchemy" and (joan.ns.tooltipLine(118) or ""):find("Made by Bram (Alchemy)", 1, true)
    and not (joan.ns.tooltipLine(118) or ""):find("Joan", 1, true), "Joan's potion: who else can make it, and never her: " .. tostring(joan.ns.tooltipLine(118)))
check(not (faelwen.ns.tooltipLine(2318) or ""):find("Used by", 1, true), "Faelwen was told she uses her own leather: " .. tostring(faelwen.ns.tooltipLine(2318)))
-- On the game's own item tooltip and a chat link's they go under the item, the first with
-- Reliquary's mark; never on the comparison tooltip beside it, nor one the game keeps from addons.
local pc = joan.postCalls[#joan.postCalls]
check(pc and pc.kind == 0, "Reliquary's tooltip post-call")
local tip, ref, shop = joan.env.GameTooltip, joan.env.ItemRefTooltip, joan.env.ShoppingTooltip1
tip._texts, ref._texts, shop._texts = {}, {}, {}
pc.fn(tip, { id = 2318, type = 0 })
pc.fn(ref, { id = 2304, type = 0 })
pc.fn(shop, { id = 2318, type = 0 })
check(#tip._texts == 2 and tip._texts[1]:find("^|T[^|]*Reliquary[^|]*|t " .. joan.ns.GOLD .. "Used by|r " .. T.called("Faelwen"):gsub("%-", "%%-") .. " %(Leatherworking%)$")
    and tip._texts[2] == joan.ns.GOLD .. "Held by|r the guild bank (20)", "the leather's lines on the game's tooltip: " .. table.concat(tip._texts, " / "))
check(#ref._texts == 1 and ref._texts[1]:find("Made by|r " .. T.called("Faelwen"), 1, true) and #shop._texts == 0, "the chat link's and the comparison tooltip's lines")
tip._texts, tip.IsForbidden = {}, function() return true end
pc.fn(tip, { id = 2318, type = 0 })
tip.IsForbidden = function() return false end
check(#tip._texts == 0, "lines on a tooltip the game keeps from addons")
do
-- The item's page in the window: who makes it, whose recipes use it, who could learn it.
local page = table.concat(joan.ns.itemPageLines(2318), "\n")
check(page:find("Used by " .. T.called("Faelwen") .. " (Leatherworking)", 1, true), "the leather's page: " .. page)
page = table.concat(joan.ns.itemPageLines(2840), "\n")
check(page:find("Made by Bram and " .. T.called("Brannoc") .. " (Mining)", 1, true) and page:find("Used by " .. T.called("Brannoc") .. " (Blacksmithing)", 1, true),
    "the copper bar's page: " .. page)
check(table.concat(joan.ns.itemPageLines(5083), "\n"):find("Can be learned by " .. T.called("Faelwen") .. " (Leatherworking)", 1, true), "the pattern's page")

end
-- The window: Faelwen's page has her recipes; her Leatherworking bar opens them, the search finds
-- one, and a recipe opens what it makes.
function T.rowsOf(c)
    for _, f in ipairs(c.ui.frames) do
        if f._rows and f:IsVisible() and f._rows[1] and f._rows[1].line ~= nil then return f._rows end
    end
    return {}
end
function T.rowTexts(c) -- each row's name (a profession's head with "|" and its count and skill), without colours; a card's foot has none
    local t = {}
    for _, r in ipairs(T.rowsOf(c)) do
        if r:IsShown() and r.line.kind ~= "foot" then
            local s = r.name._text or ""
            if r.line.kind == "head" then s = s .. "|" .. (r.count._text or "") .. (r.skill:IsShown() and ("|" .. (r.skill._text or "")) or "") end
            t[#t + 1] = (s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
        end
    end
    return t
end
-- An item's page has its columns even: what it shows is in order (its own lines, then its sections,
-- then the people around it), and no section of its own could move from one column to the other and
-- bring their ends closer. Returns the two columns' heights.
-- Whether an item's page has its columns as even as moving its own cards (each way it's made, what it
-- goes into: "cells") between them can make them: each card as tall as it is with the gap under it.
function T.even(page)
    local function cards(list) return list:GetDataProvider()._items end
    local function tall(e) return e.h + joan.ns.Skin.SPACE.l end
    local function sum(list) local h = 0 for _, e in ipairs(list) do h = h + tall(e) end return h end
    local left, right = cards(page.list), cards(page.who)
    local hl, hr = sum(left), sum(right)
    local last, first = left[#left], right[1]
    if last and last.kind == "cells" then
        local hs = tall(last)
        if math.max(hl - hs, hr + hs) < math.max(hl, hr) then return nil, "a card on the left would even the columns on the right" end
    end
    if first and first.kind == "cells" then
        local hs = tall(first)
        if math.max(hl + hs, hr - hs) < math.max(hl, hr) then return nil, "a card on the right would even the columns on the left" end
    end
    local people, moved = false, 0
    for _, e in ipairs(right) do
        if e.kind ~= "cells" then people = true elseif people then return nil, "a card of the item's own after the people around it" end
        if e.kind == "cells" then moved = moved + 1 end
    end
    return hl, hr, moved
end
function T.schematic(c) -- the recipe chosen beside the list: what it makes, then each reagent's line
    local sc
    for _, f in ipairs(c.ui.frames) do if rawget(f, "schematic") and f.schematic:IsVisible() then sc = f.schematic end end
    if not sc then return nil, nil end
    local t = { sc.name._text or "" }
    for _, cell in ipairs(sc.cells) do if cell:IsShown() then t[#t + 1] = cell.name._text or "" end end
    return (table.concat(t, " / "):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")), sc
end
do
joan.ns.showViewer(TAB.Guild)
local frow
for _, f in ipairs(joan.ui.frames) do
    if f._rows and f:IsVisible() then for _, r in ipairs(f._rows) do if r.row and r.row.key == faelwen.full then frow = r end end end
end
joan.ui.run(frow, "OnClick")
for _, f in ipairs(joan.ui.frames) do if f.page == "gear" and f:IsVisible() then joan.ui.run(f, "OnClick") end end
local bar
for _, f in ipairs(joan.ui.frames) do
    if f._kind == "Button" and rawget(f, "bar") and f.line and f.line.prof == "Leatherworking" and f:IsVisible() and f.bar:IsShown() then bar = f end
end
check(bar and bar.line.recipes == 3 and bar.label._text == "Leatherworking", "Faelwen's Leatherworking bar")
joan.env.GameTooltip._texts = {}
joan.ui.run(bar, "OnEnter")
check(table.concat(joan.env.GameTooltip._texts or {}, " "):find("Click to see them.", 1, true), "the bar says a click shows the recipes")
joan.ui.run(bar, "OnLeave")
joan.ui.run(bar, "OnClick")
local rt = T.rowTexts(joan)
check(#rt == 4 and rt[1]:find("Leatherworking", 1, true) and rt[1]:find("3 recipes", 1, true) and rt[2] == "Cured Light Hide"
    and rt[3] == "Handstitched Leather Boots" and rt[4] == "Light Armor Kit", "Faelwen's recipes in the window: " .. table.concat(rt, " / "))
check(button(joan, "Recipes"), "Faelwen's page has no Recipes button")
-- Beside the list the first recipe is chosen: what it makes, and each reagent with how many Joan has
-- of how many it takes; a click on another chooses that one, its row keeping the fill and the gold bar,
-- which glides to it from the row chosen before, and the recipe's card's parts arrive again.
do
    local shown = T.schematic(joan)
    check(shown and shown:find("^Cured Light Hide") and shown:find("/1 Light Hide", 1, true) and shown:find("/1 Salt", 1, true),
        "the first recipe beside Faelwen's list: " .. tostring(shown))
    local boots, hide
    for _, r in ipairs(T.rowsOf(joan)) do
        if r.line and r.line.r and r.line.left:find("Handstitched Leather Boots", 1, true) then boots = r end
        if r.line and r.line.r and r.line.left:find("Cured Light Hide", 1, true) then hide = r end
    end
    local M = joan.ns.Motion
    M.setEnabled(true)
    local from = hide:GetTop()
    joan.ui.run(boots, "OnClick")
    local glide = M.value(boots.bar, "slide")
    local _, sc = T.schematic(joan)
    check(glide and math.abs(glide[2] - (from - boots:GetTop())) < 1e-6 and sc.top:GetAlpha() == 0 and sc.cells[1]:GetAlpha() == 0,
        "the gold bar doesn't glide from the recipe chosen before, or the boots' card didn't arrive")
    M.finishAll()
    M.setEnabled(false)
    shown = T.schematic(joan)
    check(shown and shown:find("^Handstitched Leather Boots") and shown:find("/2 Light Leather", 1, true) and shown:find("/1 Coarse Thread", 1, true)
        and boots.chosen and boots.bar:IsShown() and not hide.chosen and not hide.bar:IsShown() and sc.cells[2]:GetAlpha() == 1, "the boots beside Faelwen's list: " .. tostring(shown))
    -- Each reagent white when Joan has enough of it, grey when she hasn't, as the Professions window.
    local _, sc = T.schematic(joan)
    for _, cell in ipairs(sc.cells) do
        if cell:IsShown() then
            local have, need = cell.name._text:match("^(%d+)/(%d+)")
            local white = (cell.name._textColor or {})[3] == 1
            check(have and white == (tonumber(have) >= tonumber(need)), "a reagent's colour beside the recipes: " .. cell.name._text)
        end
    end
    laidOut(joan, "Faelwen's recipes")
end
do
    local row
    for _, f in ipairs(joan.ui.frames) do
        if f._rows and f:IsVisible() then for _, r in ipairs(f._rows) do if r.line and r.line.r and r.line.left:find("Handstitched Leather Boots", 1, true) then row = r end end end
    end
    joan.env.GameTooltip._texts = {}
    joan.ui.run(row, "OnEnter")
    local t = table.concat(joan.env.GameTooltip._texts, "|")
    check(t:find("Reagents", 1, true) and t:find("2 Light Leather", 1, true) and t:find("1 Coarse Thread", 1, true), "a recipe's reagents on hover: " .. t)
end
local box
for _, f in ipairs(joan.ui.frames) do if rawget(f, "recipeSearch") and f.recipeSearch:IsVisible() then box = f.recipeSearch end end
box:SetText("hide")
joan.ui.run(box, "OnTextChanged")
-- A new search starts at the top of what it finds; the same search drawn again stays where it was.
do
    local page
    for _, f in ipairs(joan.ui.frames) do if rawget(f, "recipeSearch") == box then page = f end end
    check(page.recipes._keep == nil, "a new search of the recipes kept the old scroll")
    page.redraw()
    check(page.recipes._keep == true, "the same search drawn again lost its scroll")
end
rt = T.rowTexts(joan)
check(#rt == 2 and rt[2]:find("Cured Light Hide", 1, true), "searching Faelwen's recipes: " .. table.concat(rt, " / "))
box:SetText("salt")
joan.ui.run(box, "OnTextChanged")
rt = T.rowTexts(joan)
check(#rt == 2 and rt[2]:find("Cured Light Hide", 1, true), "searching Faelwen's recipes by what goes into them: " .. table.concat(rt, " / "))
box:SetText("")
joan.ui.run(box, "OnTextChanged")
local kitRow
for _, r in ipairs(T.rowsOf(joan)) do if r.line and r.line.r and r.line.r.id == 2881 then kitRow = r end end
joan.ui.run(kitRow, "OnEnter")
check(joan.env.GameTooltip._link == "item:2304", "the kit's row shows the kit's tooltip")
joan.ui.run(kitRow, "OnClick")
do
    local shown, sc = T.schematic(joan)
    check(shown and shown:find("^Light Armor Kit") and sc.out.rq and sc.out.rq.id == 2304, "the kit beside Faelwen's list: " .. tostring(shown))
    joan.ui.run(sc.out, "OnClick") -- what it makes opens its page
end
;(function()
    local page = joan.ns.itemPage
    -- The people around the kit: Faelwen under Made by, her profession beside her.
    local function personRow(who, prof)
        for _, card in ipairs(page.who._rows) do
            for _, r in ipairs(card:IsShown() and card.lines or {}) do
                if r.person and r.person.who == who and r.person.prof == prof then return r, card.e.label end
            end
        end
    end
    local faelwenRow, under = personRow(fullOf("Faelwen"), "Leatherworking")
    check(page:IsVisible() and faelwenRow and under == "Made by" and faelwenRow.prof._text:find("Leatherworking", 1, true),
        "the kit's page from Faelwen's recipes: Faelwen under Made by (" .. tostring(under) .. ")")
    local even, why = T.even(page)
    check(even, "the kit's page: " .. tostring(why))
    -- The addresses to read more come right under the item's own column, however short it is: the
    -- column as tall as its cards (each with the gap under it), the addresses' card at its foot.
    local body, links = joan.ui.rect(page.body), joan.ui.rect(page.linkCard)
    local inList = 0
    for _, e in ipairs(page.list:GetDataProvider()._items) do inList = inList + e.h + joan.ns.Skin.SPACE.l end
    check(body and links and inList > 0 and math.abs((body.top - body.bottom) - inList) < 0.5 and math.abs(links.top - body.bottom) < 0.5,
        "the kit's page: the addresses aren't right under its column")
    -- What it's made with, from Faelwen's recipe: the leather on its slot, with how many Joan has of
    -- how many it takes.
    local function slotButton(id)
        for _, f in ipairs(joan.ui.frames) do
            if f._kind == "ItemButton" and f.rq and f.rq.id == id and f:IsVisible() and f ~= page.icon then return f end
        end
    end
    local need
    for _, way in ipairs(joan.ns.recipesFor(2304)) do for _, u in ipairs(way.uses) do if u.id == 2318 then need = u.n end end end
    local me = joan.db().chars[joan.ns.charKey]
    local function carried()
        local n = 0
        for _, list in ipairs({ me.bags or {}, me.bank or {} }) do
            for _, bag in ipairs(list) do for _, it in pairs(bag.slots or {}) do if it.id == 2318 then n = n + (it.n or 1) end end end
        end
        return n
    end
    -- White with enough of it in her bags and bank, as the game's Professions window; grey without.
    me.bags = me.bags or {}
    local pouch = { size = 4, bag = 4, slots = { [1] = { id = 2318, n = (need or 1) + 4, name = "Light Leather" } } }
    table.insert(me.bags, pouch)
    page.redraw()
    local have = carried()
    local leather = slotButton(2318)
    local label = leather and leather:GetParent().name._text
    local color = leather and leather:GetParent().name._textColor or {}
    check(need and leather and have >= need and label == ("%d/%d Light Leather"):format(have, need) and color[1] == 1 and color[3] == 1,
        "the leather's slot on the kit's page: " .. tostring(label))
    for i, bag in ipairs(me.bags) do if bag == pouch then table.remove(me.bags, i) break end end
    page.redraw()
    leather = slotButton(2318)
    color = leather and leather:GetParent().name._textColor or {}
    check(carried() >= need or (color[1] or 1) < 1, "the leather's slot isn't grey with too little of it: " .. tostring(color[1]))
    have = carried()
    -- A reagent the game hasn't fetched, that Reliquary knows only by the tooltip it read, is named from
    -- that tooltip, never "Item 2318".
    do
        local items, realInfo = joan.db().items, joan.env.C_Item.GetItemInfo
        local kept = items[2318]
        items[2318] = { tip = { { l = "Light Leather" }, { l = "Crafting Reagent", lc = "66bbff" } } }
        joan.env.C_Item.GetItemInfo = function(x) if tostring(x) == "2318" or tostring(x):find("item:2318", 1, true) then return nil end return realInfo(x) end
        page.redraw()
        local named = slotButton(2318)
        local said = named and named:GetParent().name._text
        items[2318], joan.env.C_Item.GetItemInfo = kept, realInfo
        page.redraw()
        check(said == ("%d/%d Light Leather"):format(have, need), "a reagent known only by its tooltip: " .. tostring(said))
    end
    -- A click on it opens its page, one on what it goes into opens that one's, and Back and Escape step
    -- back through them, then to the recipes.
    joan.ui.run(leather, "OnClick")
    check(page:IsVisible() and page.item.id == 2318 and #page.history == 1, "the leather's page from the kit's")
    local even, why = T.even(page)
    check(even, "the leather's page: " .. tostring(why))
    local kit = slotButton(2304)
    check(kit, "the kit under Used to make, on the leather's page")
    joan.ui.run(kit, "OnClick")
    check(page.item.id == 2304 and #page.history == 2, "the kit's page from the leather's")
    -- Another tab leaves every item's page at once; so does closing the window.
    joan.ui.run(joan.env["ReliquaryFrameTab" .. TAB.Sharing], "OnClick")
    check(not page:IsVisible() and #page.history == 0, "another tab left the item's page with items to step back to: " .. #page.history)
    -- The kit's page from beside the recipes, as a player opens it: its row chosen, then what it makes.
    local function openKit()
        joan.ui.run(kitRow, "OnClick")
        local _, sc = T.schematic(joan)
        joan.ui.run(sc.out, "OnClick")
    end
    joan.ui.run(joan.env["ReliquaryFrameTab" .. TAB.Guild], "OnClick")
    openKit()
    joan.ui.run(slotButton(2318), "OnClick")
    joan.slash("")
    check(not joan.env.ReliquaryFrame:IsShown() and not page:IsShown() and #page.history == 0, "closing the window left items to step back to")
    joan.slash("")
    check(joan.env.ReliquaryFrame:IsShown() and not page:IsVisible() and kitRow:IsVisible(), "the window opened again on an item's page")
    openKit()
    joan.ui.run(slotButton(2318), "OnClick")
    joan.ui.run(slotButton(2304), "OnClick")
    joan.ui.run(button(joan, "Back"), "OnClick")
    check(page:IsVisible() and page.item.id == 2318 and #page.history == 1, "Back to the leather's page")
    local function escape() for _, name in ipairs(joan.env.UISpecialFrames) do local f = joan.env[name] if f and f:IsShown() then f:Hide() end end end
    escape()
    check(page:IsVisible() and page.item.id == 2304 and #page.history == 0, "Escape back to the kit's page")
    escape()
    check(not page:IsVisible() and joan.env.ReliquaryFrame:IsShown() and kitRow:IsVisible(), "Escape from the kit's page back to Faelwen's recipes")
    -- Faelwen's name on it opens her page, on the Guild tab.
    joan.ui.run(kitRow, "OnClick")
    faelwenRow = personRow(fullOf("Faelwen"), "Leatherworking")
    joan.ui.run(faelwenRow, "OnClick")
    local picked
    for _, f in ipairs(joan.ui.frames) do
        if f._rows and f:IsVisible() then for _, r in ipairs(f._rows) do if r.row and r.row.key == fullOf("Faelwen") and r.chosen then picked = r end end end
    end
    check(not page:IsVisible() and #page.history == 0 and joan.env.ReliquaryFrame.selectedTab == TAB.Guild and picked, "Faelwen's name on the kit's page didn't open her page")
end)()
-- Thalia's enchantment shows its spell.
local trow
for _, f in ipairs(joan.ui.frames) do
    if f._rows and f:IsVisible() then for _, r in ipairs(f._rows) do if r.row and r.row.key == thalia.full then trow = r end end end
end
joan.ui.run(trow, "OnClick")
joan.ui.run(button(joan, "Recipes"), "OnClick")
-- Professions and recipes read from the left, a profession's skill from the right, whichever font the
-- row's kind gives them.
do
    local heads, names = 0, 0
    for _, r in ipairs(T.rowsOf(joan)) do
        if r:IsShown() and r.line and rawget(r, "name") then
            check(r.name:GetJustifyH() == "LEFT" and r.skill:GetJustifyH() == "RIGHT", "a recipe row's alignment: " .. tostring(r.line.left))
            if r.line.kind == "head" then heads = heads + 1 elseif r.line.kind == "recipe" then names = names + 1 end
        end
    end
    check(heads > 0 and names > 0, "Thalia's recipe page had no profession or recipe to look at")
end
for _, r in ipairs(T.rowsOf(joan)) do if r.line and r.line.r and r.line.r.id == 7418 then joan.ui.run(r, "OnEnter") end end
check(joan.env.GameTooltip._spell == 7418, "an enchantment's row shows its spell")
joan.slash("")

end
-- Faelwen hides her professions from the guild: her recipes leave Joan; shown again, they return.
faelwen.ns.setPart("profs", "guild", false)
advance(30)
check(not T.craftOf(joan, "Faelwen"), "Faelwen hid her professions from the guild, but Joan kept her recipes")
advance(2)
check(#joan.ns.whoCanMake(2304) == 0, "Faelwen's recipes still count after she hid them")
faelwen.ns.setPart("profs", "guild", true)
advance(120)
check(T.craftOf(joan, "Faelwen"), "Faelwen showed her professions again, but her recipes never came back")
-- A recipe learned with the window closed joins its profession, and the guild hears.
faelwen.crafts.Leatherworking.known[5244] = true
faelwen.fire("NEW_RECIPE_LEARNED", 5244, 1, 5244)
advance(2)
check(T.recipesOf(faelwen).Leatherworking.list[5244] and T.recipesOf(faelwen).Leatherworking.list[5244].o == 5081, "a recipe learned with the window closed")
advance(320)
check(#joan.ns.whoCanLearn(5083) == 0 and T.who(joan.ns.whoCanMake(5081)) == T.called("Faelwen") .. ":g:Leatherworking", "the guild didn't hear of Faelwen's new recipe")

do
-- Nobody's malformed recipes are kept as they came: a list stops where it stops making sense.
mira.ns.send({ kind = "GUILD" }, { t = "sec", n = "craft", h = "bad00001", d = { p = { { n = "Alchemy", l = 171, r = { 2330, 118, 0, 1, 2447, 1, "junk", 5, 0, 0 } },
    { n = ("x"):rep(300), r = {} }, "nonsense", { n = "Cooking", r = { 1, 2, 3 } }, { n = "Herbalism", r = { -5, 1, 0, 0 } },
    -- A recipe that says it has two things in it, the second not a thing: it, and what follows, go.
    { n = "Engineering", r = { 2330, 118, 0, 2, 2447, 1, "bad", 1, 2332, 858, 0, 0 } } } } }, true)
advance(10)
local mc = T.craftOf(joan, "Mira")
local alch = T.profIn(mc, "Alchemy")
check(alch and #alch.r == 1 and alch.r[1].id == 2330 and alch.r[1].u[1].id == 2447 and #mc.list == 5 and #mc.list[2].n == 48 and #T.profIn(mc, "Cooking").r == 0
    and #T.profIn(mc, "Herbalism").r == 0 and #T.profIn(mc, "Engineering").r == 0, "a malformed recipe list")
-- The window shows only professions with recipes in them: those left empty above are kept (they
-- still say what Mira doesn't know) but have no page, and a player whose professions are all empty
-- (Forever's Fishing window lists recipes no one has learned yet) has no Recipes page at all.
local book = joan.ns.recipeBook(mira.full)
check(book and #book == 1 and book[1].name == "Alchemy", "professions with no recipes in Mira's book: " .. (book and #book or 0))
mira.ns.send({ kind = "GUILD" }, { t = "sec", n = "craft", h = "bad00003", d = { p = { { n = "Fishing", l = 356, r = {} } } } }, true)
advance(10)
check(T.profIn(T.craftOf(joan, "Mira"), "Fishing") and joan.ns.recipeBook(mira.full) == nil, "a profession with nothing learned in it gave Mira a recipe book")
joan.ns.showViewer(TAB.Guild)
local mrow
for _, f in ipairs(joan.ui.frames) do
    if f._rows and f:IsVisible() then for _, r in ipairs(f._rows) do if r.row and r.row.key == mira.full then mrow = r end end end
end
joan.ui.run(mrow, "OnClick")
check(not button(joan, "Recipes"), "Mira's page has a Recipes page with nothing in it")
joan.env.ReliquaryFrame:Hide()

end
do
-- Text from another player is plain text. The game's codes would draw a texture, colour words or
-- make a link in your window, your tooltips and your chat; every part of a card is cleaned of them
-- as it arrives, a link keeping only its words and a typed pipe staying one.
local clean = joan.ns.cleanStr
for _, case in ipairs({
    { "|cffff0000Red|r and |TInterface\\Icons\\INV_Misc_Bomb_01:400|tbig", 80, "Red and big" },
    { "|Hurl:https://example.com|h[Free gold]|h", 80, "[Free gold]" },
    { "a || b|n|Kq12|k|A:groupfinder-icon-friend:16:16|a", 80, "a || b" },
    { "cut at a pipe||", 14, "cut at a pipe" },
    { "|cffff0000", 80, nil },
    { "broken |cnRED_FONT_COLOR:red|r|", 80, "broken nRED_FONT_COLOR:red" },
    { "|cZZZZZZZZ abcdef12", 80, "ZZZZZZZZ abcdef12" },
    { "Leatherworking", 48, "Leatherworking" },
}) do
    local got = clean(case[1], case[2])
    check(got == case[3], "another player's text, cleaned: " .. case[1] .. " gave " .. tostring(got))
end
-- A guildmate's recipes with codes in a profession's and a group's names: kept plain, and Joan's
-- tooltip lines name them plainly.
mira.ns.send({ kind = "GUILD" }, { t = "sec", n = "craft", h = "bad00002", d = { p = { { n = "|TInterface\\Icons\\INV_Misc_Bomb_01:400|t|cffff0000Alche|rmy",
    l = 171, c = { "|Hurl:https://example.com|h[Free gold]|h" }, r = { 2330, 118, 1, 1, 2447, 1 } } } } }, true)
advance(10)
local alch = T.profIn(T.craftOf(joan, "Mira"), "Alchemy")
check(alch and alch.c and alch.c[1] == "[Free gold]" and #alch.r == 1, "codes in a guildmate's profession and group names were kept")
-- With a recipe again, Mira's page has its Recipes page back (the same steps that found none above).
joan.ns.showViewer(TAB.Guild)
local back
for _, f in ipairs(joan.ui.frames) do
    if f._rows and f:IsVisible() then for _, r in ipairs(f._rows) do if r.row and r.row.key == mira.full then back = r end end end
end
joan.ui.run(back, "OnClick")
check(button(joan, "Recipes"), "Mira's page has no Recipes page now that she has a recipe")
joan.env.ReliquaryFrame:Hide()
local said = {}
for _, l in ipairs(joan.ns.tooltipLines(118)) do said[#said + 1] = l[1] .. " " .. l[2] end
said = table.concat(said, " / ")
check(said:find(T.called("Mira") .. " (Alchemy)", 1, true) and not said:find("|", 1, true), "a guildmate's codes in Joan's tooltip lines: " .. said)
-- A key keeps its own separator (an auction house's "Realm|Side"), so it is checked by its shape
-- instead: an offer of a house whose key is anything else is never asked about.
local offerFrom = #world.log
joan.ns.onPriceOffer({ { h = "Realm|cffff0000|Alliance", at = world.clock }, { h = "|TInterface\\Icons\\X:400|t|Alliance", at = world.clock },
    { h = "Some Realm|Horde", at = world.clock } }, mira.full)
advance(8)
local askedKeys = {}
for _, m in ipairs(carried(offerFrom)) do if m.msg.t == "pr?" and m.from == joan.full then askedKeys[#askedKeys + 1] = m.msg.h end end
check(#askedKeys == 1 and askedKeys[1] == "Some Realm|Horde", "houses Joan asked about: " .. table.concat(askedKeys, ", "))

end
do
-- An ingredient the game files under one profession (trade goods of the Cooking kind, marked a
-- crafting reagent) names everyone who cooks, under the item and at loot, until a recipe of theirs
-- names it exactly. Thalia takes up Cooking; she hasn't opened its window.
local wasProfs = thalia.opts.profs
thalia.opts.profs = { { "Tailoring", 136249, 102, 150 }, { "Enchanting", 136244, 87, 150 }, { "Cooking", 133971, 40, 75 } }
thalia.fire("SKILL_LINES_CHANGED")
advance(400)
local users = joan.ns.whoUses(769)
check(T.who(users) == T.called("Thalia") .. ":g:Cooking" and users[1].byType and users[1].sk == 40, "who cooks with the boar meat: " .. T.who(users))
local said = {}
for _, l in ipairs(joan.ns.tooltipLines(769)) do said[#said + 1] = l[1] .. " " .. l[2] end
check(table.concat(said, " / "):find("Used by " .. T.called("Thalia") .. " (Cooking)", 1, true), "the boar meat's tooltip lines: " .. table.concat(said, " / "))
check(table.concat(joan.ns.itemPageLines(769), "\n"):find("Used by " .. T.called("Thalia") .. " (Cooking)", 1, true), "the boar meat's page in the window")
-- In Thalia's own game she's among them (her tooltip leaves her out, as for recipes).
check(T.who(thalia.ns.whoUses(769)) == "Thalia:me:Cooking", "who cooks with the boar meat, as Thalia's game has it: " .. T.who(thalia.ns.whoUses(769)))
-- The same kind, but not a crafting reagent: nobody.
check(#joan.ns.whoUses(90021) == 0, "a cooking item that isn't a reagent named a cook: " .. T.who(joan.ns.whoUses(90021)))
-- Never someone who shares with Joan only publicly, nor her character on another realm, who
-- can't trade with her.
local ep = joan.db().peers[eluned.full]
check(ep and ep.scopes.p and not ep.scopes.g and not ep.scopes.f and ep.card, "Eluned shares with Joan only publicly")
local wasCard, wasHash = ep.card.profs, ep.hashes.core
ep.card.profs, ep.hashes.core = { { n = "Cooking", sk = 60, mx = 75 } }, "cooks0001"
local far = joan.db().chars["Joan-CAMWOW US2 Realm 10 RP PvP"]
far.profs = { { name = "Cooking", skill = 5, max = 75 } }
advance(2)
check(T.who(joan.ns.whoUses(769)) == T.called("Thalia") .. ":g:Cooking", "a public sharer or a character on another realm cooks for Joan: " .. T.who(joan.ns.whoUses(769)))
ep.card.profs, ep.hashes.core, far.profs = wasCard, wasHash, nil
advance(2)
-- A guildmate whose card alone changes (Faelwen takes up Cooking; nothing else moves) is named
-- the next time anyone asks.
joan.ns.whoUses(769)
local fp = joan.db().peers[faelwen.full]
local fProfs, fHash = fp.card.profs, fp.hashes.core
local more = { { n = "Cooking", sk = 3, mx = 75 } }
for _, x in ipairs(fProfs or {}) do more[#more + 1] = x end
fp.card.profs, fp.hashes.core = more, "cooks0002"
advance(2)
check(T.who(joan.ns.whoUses(769)):find(T.called("Faelwen") .. ":g:Cooking", 1, true), "only Faelwen's card changed, and her Cooking wasn't seen: " .. T.who(joan.ns.whoUses(769)))
fp.card.profs, fp.hashes.core = fProfs, fHash
advance(2)
-- At loot: Joan, who doesn't cook, hears of Thalia; Thalia, who does, hears nothing.
local from = #joan.printed
T.loot(joan, 769)
local heard = table.concat(T.lines(joan, from), "\n")
check(heard:find(T.called("Thalia") .. " can use your", 1, true) and heard:find("for Cooking", 1, true), "Joan's line at loot for the boar meat: " .. heard)
local tfrom = #thalia.printed
T.loot(thalia, 769)
check(not table.concat(T.lines(thalia, tfrom), "\n"):find("can use your", 1, true), "Thalia, who cooks, was told who could use her boar meat")
-- Another of Joan's characters who cooks, on her realm and side: listed before the guild.
joan.db().chars[T.bramKey].profs[3] = { name = "Cooking", skill = 12, max = 75 }
advance(2)
check(T.who(joan.ns.whoUses(769)) == "Bram:own:Cooking," .. T.called("Thalia") .. ":g:Cooking", "Bram cooks too: " .. T.who(joan.ns.whoUses(769)))
joan.db().chars[T.bramKey].profs[3] = nil
advance(2)
-- Once a recipe of Thalia's uses it, that recipe says so, and she isn't listed twice.
thalia.crafts.Cooking = { skill = 40, max = 75, known = { [2795] = true } }
T.open(thalia, "Cooking")
T.close(thalia)
advance(400)
users = joan.ns.whoUses(769)
check(#users == 1 and users[1].recipes and users[1].recipes[1].id == 2795 and not users[1].byType, "Thalia by her recipe and her profession: " .. T.who(users))
-- Hidden from the guild, her professions name her no more.
thalia.ns.setPart("profs", "guild", false)
advance(400)
check(#joan.ns.whoUses(769) == 0, "Thalia hid her professions, but still cooks for Joan: " .. T.who(joan.ns.whoUses(769)))
thalia.ns.setPart("profs", "guild", true)
thalia.opts.profs, thalia.crafts.Cooking = wasProfs, nil
thalia.fire("SKILL_LINES_CHANGED")
advance(400)

end
do
-- A crafter with more than one message can carry with everything their recipes use: the largest
-- profession goes without what goes into its recipes (what they make stays), and it all arrives.
world.bigRecipes = {}
mira.crafts = { Engineering = { skill = 300, max = 300, known = {} }, Cooking = { skill = 300, max = 300, known = {} } }
for i = 1, 400 do
    world.bigRecipes[40000 + i] = { "Gadget " .. i, 50000 + i, { { 2840, 2 }, { 2589, 1 }, { 2835, 3 }, { 2996, 1 } }, "Engineering", "Devices" }
    mira.crafts.Engineering.known[40000 + i] = true
end
for i = 1, 100 do
    world.bigRecipes[41000 + i] = { "Dish " .. i, 51000 + i, { { 2672, 1 }, { 2678, 1 } }, "Cooking", "Meals" }
    mira.crafts.Cooking.known[41000 + i] = true
end
mira.opts.profs = { { "Engineering", 136243, 300, 300 }, { "Cooking", 133971, 300, 300 } }
mira.fire("SKILL_LINES_CHANGED")
advance(3)
T.open(mira, "Engineering")
T.open(mira, "Cooking")
T.close(mira)
check(T.count(T.recipesOf(mira).Engineering.list) == 400 and T.count(T.recipesOf(mira).Cooking.list) == 100, "Mira's recipes")
-- Within the five minutes between announcements, and the half minute its pieces take to go.
advance(380)
local big = T.craftOf(joan, "Mira")
local eng, cook = T.profIn(big, "Engineering"), T.profIn(big, "Cooking")
check(eng and #eng.r == 400 and eng.r[1].o == 50001 and not eng.r[1].u and cook and #cook.r == 100 and cook.r[1].u and #cook.r[1].u == 2,
    "the large crafter's recipes: " .. tostring(eng and #eng.r) .. " and " .. tostring(cook and #cook.r))

end
-- A profession given up takes its recipes with it: Thalia gives up Enchanting.
thalia.opts.profs = { { "Tailoring", 136249, 102, 150 } }
thalia.fire("SKILL_LINES_CHANGED")
advance(320)
check(not T.profIn(T.craftOf(joan, "Thalia"), "Enchanting") and T.profIn(T.craftOf(joan, "Thalia"), "Tailoring"), "Joan still has Thalia's Enchanting recipes")
newSession(thalia)
advance(15)
check(T.recipesOf(thalia).Tailoring and not T.recipesOf(thalia).Enchanting, "Thalia gave up Enchanting, but its recipes stay in her record")
check(thalia.db().items[2568] and thalia.db().items[2996], "what Thalia's recipes make and use was dropped at her next login")

-- The sample's guildmates and friend share their recipes (Mira's practice ones stay out).
for _, name in ipairs({ "Thalia", "Faelwen", "Brannoc" }) do
    local key = fullOf(name)
    local p = joan.db().peers[key]
    if p and p.more and p.more.craft then
        local sp = snapshot.peers[key] or copy(p)
        snapshot.peers[key] = sp
        sp.more = sp.more or {}
        sp.more.craft = copy(p.more.craft)
        for _, k in ipairs({ "hashes", "from", "under", "gotAt" }) do
            sp[k] = sp[k] or {}
            sp[k].craft = p[k] and p[k].craft
        end
        if sp.card and p.card then sp.card.profs = copy(p.card.profs) end
    end
end
for id, rec in pairs(joan.db().items) do if snapshot.items[id] == nil then snapshot.items[id] = copy(rec) end end
snapshot.sources = copy(joan.db().sources)
joan.db().chars[T.bramKey] = nil
end

---------------------------------------------------------------------------
-- 8b. Guild chat and whispers (Chat.lua): kept as the game shows them, what was said while away
-- read back from the guild's chat on the server, searched, filtered and answered in the window,
-- and never sent anywhere.
---------------------------------------------------------------------------
;(function() -- a function of its own: the file's main chunk is near Lua 5.1's two hundred locals
    local GUILDTAB = 2
    local function called(name) return fullOf(name):match("^([^%-]+)") end -- as the window names a player
    for _, c in ipairs({ joan, thalia, mira, faelwen }) do check(c.online and c.guild and not c.leftGuild, c.name .. " should be online in the guild") end
    local function lines(c) return c.ns.guildChat(gk()) end
    local function last(c) local l = lines(c) return l[#l] end
    local function count(c, words)
        local n = 0
        for _, r in ipairs(lines(c)) do if r.m == words then n = n + 1 end end
        return n
    end
    -- A line said in the guild: each member online keeps it, with who said it and their class; the
    -- speaker too. Nobody outside the guild hears it.
    local link = "|cffffffff|Hitem:2589::::::::12:::::::|h[Linen Cloth]|h|r"
    world.say(thalia, "Anyone need " .. link .. "? zebracorn", "GUILD")
    advance(1)
    for _, c in ipairs({ joan, mira, faelwen, thalia }) do
        local r = last(c)
        check(r and r.n == thalia.full and r.c == "PRIEST" and r.m:find("[Linen Cloth]", 1, true), c.name .. " didn't keep Thalia's line: " .. tostring(r and r.m))
    end
    check(#brannoc.ns.guildChat(gk()) == 0, "Brannoc isn't in the guild, but kept its chat")
    -- A line the game hides isn't kept.
    world.censored[world.lineID + 1] = true
    world.say(mira, "a line the game hides", "GUILD")
    advance(1)
    check(count(joan, "a line the game hides") == 0, "Joan kept a line the game hides")
    -- An achievement (the game's line has %s for the name), and a line from the guild's Discord, by
    -- the name Discord gives the speaker and the character they last played.
    for _, c in ipairs({ joan, thalia, mira, faelwen }) do
        c.fire("CHAT_MSG_GUILD_ACHIEVEMENT", "%s has earned the achievement |cffffff00|Hachievement:6:0:0:0:0:0:0:0:0|h[Level 10]|h|r!", faelwen.full, "", "",
            faelwen.full, "", 0, 0, "", 0, 900001, faelwen.env.UnitGUID("player"), 0, false, false, false, false, { userID = 0 })
    end
    world.discord("Raid at eight?", { userID = 42, globalName = "moonsong", lastOnlineName = mira.full, lastOnlineGUID = mira.env.UnitGUID("player"), fromDiscord = true })
    advance(1)
    local l = lines(joan)
    local ach, disc = l[#l - 1], l[#l]
    check(ach and ach.k == "a" and ach.n == faelwen.full and ach.c == "DRUID", "the achievement: " .. tostring(ach and ach.m))
    check(disc and disc.k == "d" and disc.d == "moonsong" and disc.n == mira.full and disc.c == "MAGE" and disc.m == "Raid at eight?", "the Discord line: " .. tostring(disc and disc.d))
    -- A Discord line with a picture, marked as the game's chat marks it; a line in the guild's own
    -- chat from someone on Discord, theirs by their Discord name; a line typed into the Discord
    -- channel from the game, the player's by their character.
    world.discord("Look at this", { userID = 43, globalName = "starfall", fromDiscord = true, hasAttachment = true })
    world.discord("On my way", { userID = 44, globalName = "brightleaf", fromDiscord = true }, true)
    world.say(mira, "Typed into Discord from the game", "GUILD_DISCORD")
    advance(1)
    l = lines(joan)
    local pic, onWay, typed = l[#l - 2], l[#l - 1], l[#l]
    check(pic and pic.k == "d" and pic.d == "starfall" and pic.m == "|cffffff00[Attachment]|r Look at this", "a Discord line with a picture: " .. tostring(pic and pic.m))
    check(onWay and onWay.k == nil and onWay.d == "brightleaf" and onWay.n == nil and onWay.m == "On my way", "a guild line from Discord: " .. tostring(onWay and onWay.d))
    check(typed and typed.k == "d" and typed.d == nil and typed.n == mira.full and typed.c == "MAGE" and typed.m == "Typed into Discord from the game",
        "a line typed into the Discord channel from the game: " .. tostring(typed and typed.n))

    -- The window: the guild's chat first in its list, and shown when chosen.
    local win = joan.env.ReliquaryFrame
    if not win:IsShown() then joan.slash("") end
    joan.ui.run(win.Tabs[GUILDTAB], "OnClick")
    local roster
    for _, f in ipairs(joan.ui.frames) do if f._rows and f:IsVisible() and f._rows[1] and f._rows[1].row then roster = f end end
    check(roster and roster._rows[1].row.chat and roster._rows[1].name._text == "Guild Chat" and roster._rows[1].class._texture == "Interface\\ChatFrame\\UI-ChatIcon-Chat-Up",
        "the guild's chat, first in its list with the game's chat icon")
    -- Under its name, its last line: who said it and what, as plain words.
    check(roster._rows[1].info:IsShown() and roster._rows[1].info._text == called("Mira") .. ": Typed into Discord from the game",
        "the guild chat's last line under its name: " .. tostring(roster._rows[1].info._text))
    joan.ui.run(roster._rows[1], "OnClick")
    local cv
    for _, f in ipairs(joan.ui.frames) do if f.input and f.pick and f.draw and f:IsVisible() then cv = f end end
    check(cv, "the guild's chat isn't shown when chosen")
    laidOut(joan, "Joan's guild chat")
    local function said()
        local out = {}
        for _, r in ipairs(cv.list._rows) do if r:IsShown() and r.line and r.line.kind == "say" then out[#out + 1] = r end end
        return out
    end
    local rows = said()
    local thaliaRow, achRow, discRow, onWayRow, typedRow
    for _, r in ipairs(rows) do
        if r.line.rec.n == thalia.full and r.line.rec.m:find("Linen", 1, true) then thaliaRow = r end
        if r.line.rec.k == "a" then achRow = r end
        if r.line.rec.d == "moonsong" then discRow = r end
        if r.line.rec == onWay then onWayRow = r end
        if r.line.rec == typed then typedRow = r end
    end
    -- Each in the colour the player's chat window gives its kind: the guild's, or its Discord channel's.
    local function colored(fs, kind)
        local c, t = fs._textColor, joan.env.ChatTypeInfo[kind]
        return c ~= nil and c[1] == t.r and c[2] == t.g and c[3] == t.b
    end
    check(thaliaRow and thaliaRow.who:IsShown() and thaliaRow.who.icon._atlas == "classicon-priest" and thaliaRow.who.name._text:find(called("Thalia"), 1, true)
        and thaliaRow.body._text:find("[Linen Cloth]", 1, true), "Thalia's line under her class icon and name, its link as the game's chat shows it")
    check(cv.list._rows[1].line.kind == "day" and cv.list._rows[1].day._text == "Today", "the day's start is marked: " .. tostring(cv.list._rows[1].day._text))
    check(achRow and achRow.body._text:match("^has earned the achievement") and achRow.who.name._text:find(called("Faelwen"), 1, true),
        "an achievement under its name, the name not said twice: " .. tostring(achRow and achRow.body._text))
    check(discRow and discRow.who.name._text:find("moonsong (Discord)", 1, true) and discRow.who.icon._atlas == "classicon-mage", "a Discord line by its Discord name")
    check(onWayRow and onWayRow.who:IsShown() and onWayRow.who.name._text:find("brightleaf (Discord)", 1, true), "a guild line from Discord by its Discord name")
    check(typedRow and typedRow.who:IsShown() and typedRow.who.name._text:find(called("Mira"), 1, true) and not typedRow.who.name._text:find("Discord", 1, true),
        "a line typed into the Discord channel by the player's character")
    check(colored(thaliaRow.body, "GUILD") and colored(onWayRow.body, "GUILD") and colored(discRow.body, "GUILD_DISCORD") and colored(typedRow.body, "GUILD_DISCORD"),
        "the guild's lines and its Discord channel's in their chat colours")
    -- Pointing at a Discord name names the character it opens, its avatar's ring warming to gold; at one
    -- with no character, nothing shows and the ring stays as it is.
    local C = joan.ns.Skin.C
    joan.ui.run(discRow.who, "OnEnter")
    local tipText, warm = joan.env.GameTooltip._text or "", discRow.who.avatar.ring.rqline
    joan.ui.run(discRow.who, "OnLeave")
    local cooled = discRow.who.avatar.ring.rqline
    joan.ui.run(onWayRow.who, "OnEnter")
    check(tipText:find("See " .. called("Mira"), 1, true) and not tipText:find("Discord", 1, true) and not joan.env.GameTooltip._shown, "pointing at Discord names: " .. tipText)
    check(warm == C.gold600 and cooled == C.ink500 and onWayRow.who.avatar.ring.rqline == C.ink500, "a speaker's ring doesn't warm only when there's a page to open")
    joan.ui.run(onWayRow.who, "OnLeave")
    -- The newest lines show: the list is scrolled to its end.
    check(cv.list._atEnd, "the guild's chat didn't open at its newest line")
    -- The page (docs/DESIGN.md, section 5): the search and the filter over the lines, the filter
    -- Reliquary's own dropdown with its choice's words on it; each speaker's group under their avatar,
    -- name and time (dim), a Discord name with no character the game's Discord mark; a day's start a
    -- pill in the middle with a line either side; the box at the foot a lined well, its prompt quiet
    -- until something is typed. Lines fewer than the page holds sit on the box, newest just over it.
    do
        local Skin, rect = joan.ns.Skin, joan.ui.rect
        local function near(a, b) return math.abs(a - b) < 0.01 end
        local cr, sr, pr, br, lr = rect(cv), rect(cv.search), rect(cv.pick), rect(cv.box), rect(cv.list)
        check(cv.search:IsShown() and cv.pick:IsShown() and cv.pick.chevron and cv.pick.label._text == "All messages" and near(sr.left, cr.left)
            and near(pr.right, cr.right) and near(sr.top + sr.bottom, pr.top + pr.bottom), "the search and the filter over the lines")
        local day = cv.list._rows[1]
        local dr, pill = rect(day), rect(day.pill)
        check(day.pill:IsShown() and day.dayLeft:IsShown() and day.dayRight:IsShown() and not day.body:IsShown() and not day.named:IsShown()
            and near(pill.left + pill.right, dr.left + dr.right) and near(pill.bottom, dr.bottom)
            and not (thaliaRow.pill:IsShown() or thaliaRow.dayLeft:IsShown() or thaliaRow.dayRight:IsShown()), "the day's start isn't a pill between two lines")
        local tr, nr, wr, br2 = rect(thaliaRow.who), rect(thaliaRow.who.name), rect(thaliaRow.when), rect(thaliaRow.body)
        local dim = { thaliaRow.when:GetTextColor() }
        check(thaliaRow.who.avatar:IsShown() and thaliaRow.who.icon == thaliaRow.who.avatar.icon and near(tr.top, nr.top) and near(nr.left, br2.left)
            and nr.left > tr.right and near(wr.bottom, nr.bottom) and wr.left > nr.right and br2.top < nr.bottom and near(dim[1], Skin.C.dim[1])
            and thaliaRow.when._text ~= "", "Thalia's group: her avatar, her name and its time over her line")
        check(onWayRow.who:IsShown() and onWayRow.who.mark:IsShown() and onWayRow.who.mark._atlas == "UI-ChatIcon-Discord" and not thaliaRow.who.mark:IsShown(),
            "a Discord name with no character has no Discord mark")
        local hint = cv.input.Instructions
        check(cv.box.floor and cv.box.line.art == "ring" and hint:IsShown() and near((hint:GetTextColor()), Skin.C.dim[1]) and hint._text == "Message your guild",
            "the box isn't a lined well with a quiet prompt")
        cv.input:SetText("x")
        joan.ui.run(cv.input, "OnTextChanged")
        check(not hint:IsShown(), "the box's prompt stays over what's typed")
        cv.input:SetText("")
        joan.ui.run(cv.input, "OnTextChanged")
        local total = 0
        for _, r in ipairs(cv.list._rows) do if r:IsShown() then total = total + r._extent end end
        check(br.bottom > cr.bottom and near(lr.bottom, br.top + 12) and near(lr.top - lr.bottom, total) and lr.top < sr.bottom - 12,
            "a short conversation doesn't sit on the box: " .. (lr.top - lr.bottom) .. " of " .. total)
    end
    -- A line arriving while the page shows eases in (DESIGN, section 2, a new chat line): it fades in and
    -- rises 8 units into place, the list following it down as it was at its foot; the lines there before
    -- stay as they are. A long conversation runs from under the search to the box; scrolled up to read
    -- it, the list stays where it is and a new line is simply there. Chosen again from a player's page,
    -- the conversation arrives as a page does; lines said while the tab was away don't arrive.
    do
        local M, rect = joan.ns.Motion, joan.ui.rect
        local function near(a, b) return math.abs(a - b) < 0.01 end
        local function rowSaying(words)
            for _, r in ipairs(said()) do if r.line.rec.m == words then return r end end
        end
        local function still(r) return r and r.inner:GetAlpha() == 1 and not M.running(r.inner, "alpha") and not M.running(r.inner, "slide") end
        M.setEnabled(true)
        world.say(mira, "Heading out now", "GUILD")
        advance(1)
        local fresh, before = rowSaying("Heading out now"), rowSaying("Raid at eight?")
        local rise = fresh and M.value(fresh.inner, "slide")
        check(fresh and fresh.inner:GetAlpha() == 0 and rise and rise[1] == 0 and rise[2] == -8 and cv.list._atEnd and still(before),
            "a new line doesn't arrive, or the lines before it moved")
        M.step(1 / 60)
        cv.draw() -- drawn again as it arrives (another change): it goes on arriving
        check(M.running(fresh.inner, "alpha") and M.running(fresh.inner, "slide") and fresh.line.rec.m == "Heading out now", "a line arriving stopped when the page drew again")
        for _ = 1, 30 do M.step(1 / 60) end
        check(still(fresh) and fresh.inner._points.TOPLEFT.y == 0, "the new line didn't land in place")
        for i = 1, 12 do world.say(i % 2 == 0 and mira or thalia, "Evening line " .. i, "GUILD") end
        advance(1)
        for _ = 1, 60 do M.step(1 / 60) end
        local sr, br, lr = rect(cv.search), rect(cv.box), rect(cv.list)
        check(cv.list:HasScrollableExtent() and near(lr.top, sr.bottom - 12) and near(lr.bottom, br.top + 12) and cv.list._atEnd,
            "a long conversation doesn't run from under the search to the box")
        cv.list._atEnd = false -- scrolled up to read
        world.say(mira, "Still there?", "GUILD")
        advance(1)
        check(not cv.list._atEnd and still(rowSaying("Still there?")), "a line arrived, or pulled the list down, while it was scrolled up")
        joan.ui.run(rowFor(joan, thalia.full), "OnClick")
        joan.ui.run(roster._rows[1], "OnClick")
        local come = M.value(cv, "slide")
        check(cv:IsVisible() and cv:GetAlpha() == 0 and come and come[2] == -8, "the guild's chat doesn't arrive when chosen")
        for _ = 1, 30 do M.step(1 / 60) end
        check(cv:GetAlpha() == 1 and not M.running(cv, "slide"), "the guild's chat didn't arrive whole")
        cv.list:ScrollToEnd() -- back at its foot, where a new line would arrive
        joan.ui.run(win.Tabs[1], "OnClick")
        for _ = 1, 30 do M.step(1 / 60) end -- the Guild tab gone
        world.say(thalia, "Said while the tab was away", "GUILD")
        advance(1)
        joan.ui.run(win.Tabs[GUILDTAB], "OnClick")
        check(cv:IsVisible() and still(rowSaying("Said while the tab was away")), "a line said while the tab was away arrived when it came back")
        M.setEnabled(false)
        M.finishAll()
    end

    -- Search: words in a line (a link by the name it shows) or a speaker's name.
    cv.search:SetText("linen")
    joan.ui.run(cv.search, "OnTextChanged")
    rows = said()
    check(#rows == 1 and rows[1].line.rec.n == thalia.full, "searching for linen: " .. #rows)
    cv.search:SetText(called("Faelwen"):lower())
    joan.ui.run(cv.search, "OnTextChanged")
    rows = said()
    check(#rows == 1 and rows[1].line.rec.k == "a", "searching for Faelwen: " .. #rows)
    -- Nothing found: the words say so where the lines would be, on the box; the search stays.
    cv.search:SetText("zzqx")
    joan.ui.run(cv.search, "OnTextChanged")
    local er, bx = joan.ui.rect(cv.empty), joan.ui.rect(cv.box)
    check(#said() == 0 and cv.empty:IsShown() and cv.empty._text == "Nothing here matches that." and cv.search:IsShown() and math.abs(er.bottom - (bx.top + 12)) < 0.01,
        "a search that finds nothing")
    cv.search:SetText("")
    joan.ui.run(cv.search, "OnTextChanged")
    -- Filters: achievements, item links, mentions of you, today.
    joan.ui.choose(cv.pick, "Achievements")
    rows = said()
    check(#rows == 1 and rows[1].line.rec.k == "a" and cv.pick.label._text == "Achievements", "only achievements: " .. #rows)
    joan.ui.choose(cv.pick, "Item links")
    rows = said()
    local linen, unlinked = false, false
    for _, r in ipairs(rows) do
        if r.line.rec.m:find("[Linen Cloth]", 1, true) then linen = true end
        if not r.line.rec.m:find("|Hitem:", 1, true) then unlinked = true end
    end
    check(linen and not unlinked and #rows < #lines(joan), "only the lines with item links: " .. #rows)
    world.say(faelwen, called("Joan"):match("^(%S+)") .. ", can you make me a bag?", "GUILD")
    world.say(faelwen, "Joanna isn't Joan's name in full", "GUILD")
    advance(1)
    joan.ui.choose(cv.pick, "Mentions of you")
    rows = said()
    check(#rows == 2 and rows[1].line.rec.m:find("make me a bag", 1, true), "mentions of Joan: " .. #rows)
    local old = { t = world.clock - 3 * 86400, n = mira.full, c = "MAGE", m = "Three days ago" }
    table.insert(lines(joan), 1, old)
    joan.ui.choose(cv.pick, "All messages")
    rows = said()
    check(rows[1].line.rec == old and cv.list._rows[1].day._text ~= "Today", "an older line under its own day")
    joan.ui.choose(cv.pick, "Today")
    rows = said()
    check(rows[1].line.rec ~= old, "today's lines show an older one")
    joan.ui.choose(cv.pick, "All messages")

    -- A speaker's icon or name opens their page; what you missed meanwhile counts on the chat's row.
    rows = said()
    for _, r in ipairs(rows) do if r.line.rec.n == thalia.full and r.who:IsShown() then thaliaRow = r end end
    joan.ui.run(thaliaRow.who, "OnClick")
    local page
    for _, f in ipairs(joan.ui.frames) do if f.pageButtons and f:IsVisible() then page = f end end
    check(page and page.name._text:find(called("Thalia"), 1, true) and not cv:IsVisible(), "Thalia's name in the chat didn't open her page")
    world.say(mira, "Back in a bit", "GUILD")
    world.say(joan, "My own line isn't news to me", "GUILD")
    advance(1)
    for _, f in ipairs(joan.ui.frames) do if f._rows and f:IsVisible() and f._rows[1] and f._rows[1].row then roster = f end end
    local missed = (roster._rows[1].level._text or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    check(missed == "1", "the lines missed, your own not among them, count on the chat's row: " .. tostring(roster._rows[1].level._text))
    joan.ui.run(roster._rows[1], "OnClick")
    advance(1)
    check(not (roster._rows[1].level._text or ""):find("%d"), "the chat's row still counts lines once they're seen")

    -- Sending: Enter sends what you typed to the guild's chat, as the game's chat box does.
    cv.input:SetText("Evening, all")
    joan.ui.run(cv.input, "OnEnterPressed")
    advance(1)
    local sent = joan.chatSent[#joan.chatSent]
    check(sent and sent.text == "Evening, all" and sent.kind == "GUILD" and cv.input._text == "", "Enter didn't send to the guild")
    check(last(thalia).m == "Evening, all" and last(thalia).n == joan.full and last(joan).m == "Evening, all", "Joan's line didn't reach the guild")
    -- The box holds a line as the game's chat box does (255 bytes you see, more with links), and a
    -- line with links goes whole, however long their codes make it; one longer still is refused.
    check(cv.input._maxBytes == 1280 and cv.input._visibleBytes == 255, "the box doesn't hold what the game's chat box holds")
    local linked = ("Selling " .. link .. " "):rep(4):sub(1, -2)
    check(#linked > 255, "the linked line isn't long enough to test: " .. #linked)
    cv.input:SetText(linked)
    joan.ui.run(cv.input, "OnEnterPressed")
    advance(1)
    check(joan.chatSent[#joan.chatSent].text == linked and last(thalia).m == linked, "a line with links didn't go whole: " .. tostring(joan.chatSent[#joan.chatSent].text))
    local sentBefore = #joan.chatSent
    local ok, why = joan.ns.sendGuildChat(("x"):rep(1281))
    check(not ok and why == "long" and #joan.chatSent == sentBefore, "a line longer than the game's chat box holds was sent")
    -- In the game's chat lockdown nothing is sent, and the box says why and keeps the words.
    local before = #joan.chatSent
    joan.lockdown = true
    cv.input:SetText("Held back")
    joan.ui.run(cv.input, "OnEnterPressed")
    joan.lockdown = false
    check(#joan.chatSent == before and cv.input._text == "Held back" and (cv.note._text or ""):find("holds back", 1, true), "a line sent in the chat lockdown")
    cv.input:SetText("")

    -- What was said while you were away: the guild's chat on the server, read back after a login, in
    -- time order and each line once (the ones kept live too). The server may name a speaker by their
    -- given name alone: they're still the guild member they are.
    world.givenOnly = true
    mira.online = false
    world.clock = world.clock + 60
    world.say(thalia, "Said while Mira was away", "GUILD")
    world.say(faelwen, "And this too", "GUILD")
    advance(1)
    check(count(mira, "Said while Mira was away") == 0, "Mira kept a line said while she was away, before she came back")
    local livePrior = count(mira, "Evening, all")
    newSession(mira)
    mira.fire("INITIAL_CLUBS_LOADED")
    advance(10)
    local ml = lines(mira)
    check(count(mira, "Said while Mira was away") == 1 and count(mira, "And this too") == 1, "what was said while Mira was away isn't read back")
    check(livePrior == 1 and count(mira, "Evening, all") == 1, "a line kept live came back twice")
    for _, words in ipairs({ "Raid at eight?", "Look at this", "On my way", "Typed into Discord from the game" }) do
        local n = 0
        for _, r in ipairs(lines(mira)) do if r.m:find(words, 1, true) then n = n + 1 end end
        check(n == 1, "a Discord line kept live came back twice: " .. words .. " " .. n)
    end
    check(count(mira, "|cffffff00[Attachment]|r Look at this") == 1, "the Discord line with a picture isn't marked as the game marks it")
    for i = 2, #ml do check(ml[i].t >= ml[i - 1].t, "the guild's chat out of time order at line " .. i) end
    check(ml[#ml].m == "And this too" and ml[#ml].id ~= nil, "the server's lines aren't marked: " .. tostring(ml[#ml].m))
    for _, r in ipairs(ml) do
        if r.m == "Said while Mira was away" then check(r.n == thalia.full and r.c == "PRIEST", "a line read back isn't Thalia's by her full name: " .. tostring(r.n)) end
    end
    -- When two members share a given name, a line Mira heard live is still the one the server names
    -- by that given name alone, and doesn't come back twice after her next login.
    if REGIONAL then
        local function thalias()
            local n = 0
            for _, m in ipairs(mira.db().guilds[gk()].members or {}) do if type(m.n) == "string" and m.n:find("^Thalia ") then n = n + 1 end end
            return n
        end
        table.insert(GUILD.others, { "Thalia", 10, 5, 4, nil, "Brightwater" })
        world.clock = world.clock + 61 -- Reliquary reads the whole roster at most once a minute
        mira.fire("GUILD_ROSTER_UPDATE")
        advance(5)
        check(thalias() == 2, "Mira's guild list doesn't have both Thalias: " .. thalias())
        world.say(thalia, "Heard live and kept on the server", "GUILD")
        advance(1)
        check(count(mira, "Heard live and kept on the server") == 1, "Mira didn't hear Thalia live")
        newSession(mira)
        mira.fire("INITIAL_CLUBS_LOADED")
        advance(10)
        check(count(mira, "Heard live and kept on the server") == 1, "a line heard live came back twice when the server named its speaker by a shared given name")
        -- Two members with that given name are two players: the same words from each, a minute
        -- apart (one while Mira was away, one she hears as she comes back, before the server's
        -- answer), are two lines, each by its own speaker.
        world.givenOnly = nil
        mira.online = false
        world.lineID = world.lineID + 1
        world.history["1"][#world.history["1"] + 1] = { messageId = { epoch = world.clock * 1e6 + world.lineID, position = world.lineID }, content = "Grats!",
            destroyed = false, edited = false, author = { name = "Thalia Brightwater", classID = 5, guid = "Player-1-0000B7", officerNote = "never read", isSelf = false } }
        world.clock = world.clock + 60
        newSession(mira)
        world.say(thalia, "Grats!", "GUILD")
        mira.fire("INITIAL_CLUBS_LOADED")
        advance(10)
        local by = {}
        for _, r in ipairs(lines(mira)) do if r.m == "Grats!" then by[#by + 1] = r.n end end
        table.sort(by)
        check(#by == 2 and by[1] == "Thalia Brightwater" and by[2] == thalia.full, "two players with one given name, the same words, as one: " .. table.concat(by, ", "))
        table.remove(GUILD.others)
        world.clock = world.clock + 61
        mira.fire("GUILD_ROSTER_UPDATE")
        advance(5)
        check(thalias() == 1, "Mira's guild list still has the second Thalia: " .. thalias())
    end
    world.givenOnly = nil
    check(mira.historyAsks and mira.historyAsks >= 1, "Mira's game was never asked for the guild's chat")
    -- With this computer's clock ten minutes off, a line heard live is still the server's line: both
    -- carry the game's server time.
    mira.skew = 600
    world.say(thalia, "Heard on a computer whose clock is off", "GUILD")
    advance(1)
    newSession(mira)
    mira.fire("INITIAL_CLUBS_LOADED")
    advance(10)
    mira.skew = nil
    check(count(mira, "Heard on a computer whose clock is off") == 1, "a line heard live came back twice on a computer whose clock is off")
    -- Asked again in the same session, nothing comes twice.
    local n = #lines(mira)
    mira.fire("CLUB_STREAMS_LOADED", 77)
    advance(5)
    check(#lines(mira) == n, "the guild's chat read back twice")
    -- A line taken down on the server (by an officer, or by who said it) leaves Mira's list at her
    -- next login: one she heard live, and one read back before, its words gone from the server too.
    -- One taken down before she ever saw it never joins it.
    world.say(thalia, "Taken down later", "GUILD")
    advance(1)
    check(count(mira, "Taken down later") == 1, "Mira didn't hear the line taken down later")
    mira.online = false
    world.say(thalia, "Taken down before Mira saw it", "GUILD")
    for _, m in ipairs(world.history["1"]) do
        if m.content == "Taken down later" or m.content == "Taken down before Mira saw it" then m.destroyed = true end
        if m.content == "And this too" then m.destroyed, m.content = true, "" end
    end
    newSession(mira)
    mira.fire("INITIAL_CLUBS_LOADED")
    advance(10)
    check(count(mira, "Taken down later") + count(mira, "And this too") + count(mira, "Taken down before Mira saw it") == 0
        and count(mira, "Said while Mira was away") == 1, "a line taken down on the server is in Mira's list")
    -- Lines alike from different places are different lines: the same words from two people on
    -- Discord, and from one player in the guild and in its Discord channel (either one first), some
    -- said while Mira was away and some she hears as she comes back, before the server's answer, are
    -- each kept once, whichever of the two streams the server answers first.
    mira.online = false
    world.discord("lol", { userID = 44, globalName = "brightleaf", fromDiscord = true })
    world.say(thalia, "lol", "GUILD")
    world.say(thalia, "brb", "GUILD_DISCORD")
    world.clock = world.clock + 60
    newSession(mira)
    world.discord("lol", { userID = 43, globalName = "starfall", fromDiscord = true })
    world.say(thalia, "lol", "GUILD_DISCORD")
    world.say(thalia, "brb", "GUILD")
    mira.fire("INITIAL_CLUBS_LOADED")
    advance(10)
    local alike, want = {}, { "lol: brightleaf on Discord", "lol: starfall on Discord", "lol: " .. thalia.full .. " in the guild", "lol: " .. thalia.full .. " on Discord",
        "brb: " .. thalia.full .. " in the guild", "brb: " .. thalia.full .. " on Discord" }
    for _, r in ipairs(lines(mira)) do
        if r.m == "lol" or r.m == "brb" then alike[#alike + 1] = r.m .. ": " .. (r.d or r.n) .. (r.k == "d" and " on Discord" or " in the guild") end
    end
    table.sort(alike)
    table.sort(want)
    check(table.concat(alike, ", ") == table.concat(want, ", "), "the same words from different places: " .. table.concat(alike, ", "))

    -- Someone who shares, before any whisper: their page has Whispers, nothing on it but the box.
    joan.ui.run(rowFor(joan, thalia.full), "OnClick")
    local before = button(joan, "Whispers")
    check(before and before:IsShown() and button(joan, "Gear"), "Thalia's page has no Whispers page before a whisper")
    joan.ui.run(before, "OnClick")
    local bv
    for _, f in ipairs(joan.ui.frames) do if f.input and f.draw and not f.pick and f:IsVisible() then bv = f end end
    check(bv and bv.box:IsShown() and not bv.search:IsShown() and not bv.empty:IsShown() and bv.input.Instructions._text == "Whisper " .. called("Thalia"),
        "Thalia's Whispers page before a whisper isn't the box alone")
    -- Whispers: each side keeps the conversation under the other player.
    world.say(thalia, "Psst, are you crafting tonight? quixotic", "WHISPER", joan.full)
    advance(1)
    local jw = joan.ns.whispersWith(thalia.full)
    local tw = thalia.ns.whispersWith(joan.full)
    check(#jw == 1 and not jw[1].o and jw[1].c == "PRIEST" and jw[1].m:find("crafting tonight", 1, true), "Joan didn't keep Thalia's whisper")
    check(#tw == 1 and tw[1].o == 1 and tw[1].c == "PRIEST", "Thalia didn't keep the whisper she sent")
    -- To someone who isn't online, nothing is sent, so nothing is kept.
    world.say(joan, "Anyone there?", "WHISPER", eluned.full .. "x")
    advance(1)
    check(not next(joan.db().whispers[eluned.full .. "x"] or {}), "a whisper the game didn't send was kept")
    -- On Thalia's page, a Whispers page: the conversation, and a box that whispers her.
    for _, f in ipairs(joan.ui.frames) do if f._rows and f:IsVisible() and f._rows[1] and f._rows[1].row then roster = f end end
    joan.ui.run(rowFor(joan, thalia.full), "OnClick")
    local wb = button(joan, "Whispers")
    check(wb and wb:IsShown(), "Thalia's page has no Whispers page")
    joan.ui.run(wb, "OnClick")
    local wv
    for _, f in ipairs(joan.ui.frames) do if f.input and f.draw and not f.pick and f:IsVisible() then wv = f end end
    check(wv, "the Whispers page isn't shown")
    laidOut(joan, "Joan's whispers with Thalia")
    check(wv.input.Instructions._text == "Whisper " .. called("Thalia"), "the box's prompt: " .. tostring(wv.input.Instructions._text))
    wv.input:SetText("Yes, at eight")
    joan.ui.run(wv.input, "OnEnterPressed")
    advance(1)
    sent = joan.chatSent[#joan.chatSent]
    check(sent.kind == "WHISPER" and sent.target == thalia.full and sent.text == "Yes, at eight", "the box didn't whisper Thalia")
    jw = joan.ns.whispersWith(thalia.full)
    check(#jw == 2 and jw[2].o == 1 and jw[2].c == "DRUID", "Joan's reply wasn't kept as sent")
    local wrows = {}
    for _, r in ipairs(wv.list._rows) do if r:IsShown() and r.line and r.line.kind == "say" then wrows[#wrows + 1] = r end end
    check(#wrows == 2 and wrows[1].who.name._text:find(called("Thalia"), 1, true) and wrows[2].who.name._text:find("You", 1, true),
        "the conversation on Thalia's page: " .. #wrows)
    -- A guildmate without a reliquary: the roster's page and the whispers, each on its own page.
    local other = GUILD.others[1]
    local otherName = REGIONAL and (other[1] .. " " .. other[6]) or (other[1] .. "-" .. REALM)
    joan.fire("CHAT_MSG_WHISPER", "Hello from the roster", otherName, "", "", otherName, "", 0, 0, "", 0, 900002, nil, 0, false, false, false, false, { userID = 0 })
    advance(1)
    joan.ui.run(win.Tabs[GUILDTAB], "OnClick")
    joan.ui.run(rowFor(joan, otherName), "OnClick")
    check(button(joan, "Whispers") and not button(joan, "Roster") and not button(joan, "Gear"), "a guildmate without a reliquary has no Whispers page")
    joan.ui.run(button(joan, "Whispers"), "OnClick")
    laidOut(joan, "a guildmate's whispers")

    -- None of it goes anywhere: no other player's game has a word of it.
    for _, c in ipairs(world.clients) do
        check(not holds(c.db().peers, "zebracorn") and not holds(c.db().peers, "quixotic") and not holds(c.db().guilds, "zebracorn"),
            c.name .. " got guild chat or a whisper from another player's Reliquary")
    end
    -- A full list keeps its newest lines: five thousand for the guild, a thousand with one player.
    for i = 1, 5005 do
        joan.fire("CHAT_MSG_GUILD", "line " .. i, mira.full, "", "", mira.full, "", 0, 0, "", 0, 910000 + i, mira.env.UnitGUID("player"), 0, false, false, false, false, { userID = 0 })
    end
    for i = 1, 1005 do
        joan.fire("CHAT_MSG_WHISPER", "whisper " .. i, mira.full, "", "", mira.full, "", 0, 0, "", 0, 920000 + i, mira.env.UnitGUID("player"), 0, false, false, false, false, { userID = 0 })
    end
    local gl, wl = lines(joan), joan.ns.whispersWith(mira.full)
    check(#gl == 5000 and gl[#gl].m == "line 5005" and gl[1].m == "line 6", "the guild's chat kept: " .. #gl .. ", first " .. tostring(gl[1].m))
    check(#wl == 1000 and wl[#wl].m == "whisper 1005" and wl[1].m == "whisper 6", "whispers kept with Mira: " .. #wl)
    if win:IsShown() then joan.slash("") end
end)()

---------------------------------------------------------------------------
-- 8c. Officer chat for officers, Battle.net whispers, and everyone you talk to on the Friends tab.
-- None of it leaves the player's own computer either.
---------------------------------------------------------------------------
;(function()
    local GUILDTAB = 2
    local function called(name) return fullOf(name):match("^([^%-]+)") end
    local function list(c)
        for _, f in ipairs(c.ui.frames) do if f._rows and f:IsVisible() and f._rows[1] and f._rows[1].row then return f end end
    end
    local function plain(s) return ((s or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) end
    local function conversation(c)
        for _, f in ipairs(c.ui.frames) do if f.input and f.draw and f:IsVisible() then return f end end
    end
    local function said(cv)
        local out = {}
        for _, r in ipairs(cv.list._rows) do if r:IsShown() and r.line and r.line.kind == "say" then out[#out + 1] = r end end
        return out
    end
    local function colored(fs, kind, env)
        local col, t = fs._textColor, env.ChatTypeInfo[kind]
        return col ~= nil and col[1] == t.r and col[2] == t.g and col[3] == t.b
    end
    local win = joan.env.ReliquaryFrame
    if not win:IsShown() then joan.slash("") end

    -- Officer chat: the guild master's line reaches the officers, not the members; Joan, an officer,
    -- keeps it apart from the guild's chat, and her Guild tab has its row under Guild Chat, counting
    -- what she hasn't seen.
    world.say(faelwen, "The bank needs sorting, pterodactyl", "OFFICER")
    advance(1)
    local ol = joan.ns.officerChat(gk())
    check(ol[#ol] and ol[#ol].m == "The bank needs sorting, pterodactyl" and ol[#ol].n == faelwen.full and ol[#ol].c == "DRUID", "Joan didn't keep the officer line")
    check(#thalia.ns.officerChat(gk()) == 0 and #mira.ns.officerChat(gk()) == 0, "a member kept officer chat")
    for _, r in ipairs(joan.ns.guildChat(gk())) do check(r.m ~= "The bank needs sorting, pterodactyl", "officer chat kept in the guild's chat") end
    joan.ui.run(win.Tabs[GUILDTAB], "OnClick")
    local roster = list(joan)
    check(roster._rows[1].row.chat == "guild" and roster._rows[2].row.chat == "officer" and roster._rows[2].name._text == "Officer Chat"
        and plain(roster._rows[2].level._text) == "1", "Joan's Officer Chat row, with the line she missed: " .. tostring(roster._rows[2].name._text))
    joan.ui.run(roster._rows[2], "OnClick")
    local ov = conversation(joan)
    check(ov and ov.pick and ov.input.Instructions._text == "Message your officers", "officer chat isn't shown when chosen")
    laidOut(joan, "Joan's officer chat")
    local rows = said(ov)
    check(#rows == 1 and rows[1].body._text == "The bank needs sorting, pterodactyl" and colored(rows[1].body, "OFFICER", joan.env),
        "officer chat's line, in the officer chat colour: " .. #rows)
    check(plain(list(joan)._rows[2].level._text) == "", "the Officer Chat row still counts lines once they're seen")
    -- Her box sends to officer chat: the guild master hears it, a member doesn't, and a member can't send there.
    ov.input:SetText("I'll sort it tonight")
    joan.ui.run(ov.input, "OnEnterPressed")
    advance(1)
    local sent = joan.chatSent[#joan.chatSent]
    check(sent.kind == "OFFICER" and sent.text == "I'll sort it tonight", "Joan's box didn't send to officer chat")
    local fo = faelwen.ns.officerChat(gk())
    check(fo[#fo].m == "I'll sort it tonight" and #thalia.ns.officerChat(gk()) == 0, "officer chat reached the wrong people")
    local ok, why = thalia.ns.sendOfficerChat("let me in")
    check(not ok and why == "notofficer", "a member sent to officer chat")
    -- A member's Guild tab has no Officer Chat row.
    thalia.slash("")
    thalia.ui.run(thalia.env.ReliquaryFrame.Tabs[GUILDTAB], "OnClick")
    local tr = list(thalia)
    check(tr._rows[1].row.chat == "guild" and tr._rows[2].row.chat == nil, "a member's Guild tab has an Officer Chat row")
    thalia.slash("")
    -- What officers said while the guild master was away comes back from officer chat's own stream.
    faelwen.online = false
    world.say(joan, "Said in officer chat while Faelwen was away", "OFFICER")
    advance(1)
    newSession(faelwen)
    faelwen.fire("INITIAL_CLUBS_LOADED")
    advance(10)
    local back = 0
    for _, r in ipairs(faelwen.ns.officerChat(gk())) do if r.m == "Said in officer chat while Faelwen was away" then back = back + 1 end end
    check(back == 1, "officer chat said while Faelwen was away isn't read back once: " .. back)
    for _, r in ipairs(faelwen.ns.guildChat(gk())) do check(r.m ~= "Said in officer chat while Faelwen was away", "officer chat read back into the guild's chat") end
    check(#thalia.ns.officerChat(gk()) == 0, "a member's game read back officer chat")

    -- Battle.net whispers: Brannoc, Joan's Battle.net friend, whispers her from the game. Each keeps it
    -- under the other's BattleTag (the game names a Battle.net friend in chat by a string an addon
    -- can't keep), as received or as sent, with the class of the character the friend was playing.
    local brannocTag, joanTag = "bn:Brannoc#1504", "bn:Joan#1501"
    check(brannoc.env.C_BattleNet.SendWhisper(joan.account, "Ready for the Deadmines? mumblecore") == true, "Brannoc's Battle.net whisper wasn't sent")
    advance(1)
    local jb, bj = joan.ns.whispersWith(brannocTag), brannoc.ns.whispersWith(joanTag)
    check(#jb == 1 and not jb[1].o and jb[1].c == "WARRIOR" and jb[1].m:find("Deadmines", 1, true), "Joan didn't keep Brannoc's Battle.net whisper")
    check(#bj == 1 and bj[1].o == 1 and bj[1].m:find("Deadmines", 1, true), "Brannoc didn't keep the Battle.net whisper he sent")
    check(#joan.ns.whispersWith(brannoc.full) == 0 and #joan.ns.whispersWith("|Kq504|k") == 0, "a Battle.net whisper kept under a name")

    -- The Friends tab: everyone Joan calls a friend, her reliquary-sharing Battle.net friend Brannoc
    -- and Grift from her friends list, who doesn't use Reliquary; a Battle.net friend who is away and
    -- silent and shares nothing (Eluned) isn't listed.
    joan.opts.friends, joan.opts.friendNotes = { "Grift" }, { Grift = "Met in Westfall" }
    joan.opts.bnFriends = { "Brannoc", "Eluned" }
    eluned.online = false
    joan.ui.run(win.Tabs[TAB.Friends], "OnClick")
    advance(1)
    check((joan.friendsAsked or 0) >= 1, "the Friends tab didn't ask the game for news of the friends list")
    local fl = list(joan)
    local function rowOf(key)
        for _, r in ipairs(fl._rows) do if r.row and r.row.key == key then return r end end
    end
    local bRow, gRow = rowOf(brannocTag), rowOf(rogue.full)
    local brannocs = 0
    for _, r in ipairs(fl._rows) do if r.row and plain(r.row.label):find("Brannoc", 1, true) then brannocs = brannocs + 1 end end
    check(bRow and brannocs == 1 and bRow.name._text:find("|cff82c5ffBrannoc|r", 1, true) and bRow.class._atlas == "classicon-warrior" and bRow.gem:IsShown()
        and bRow.dot:IsShown() and select(2, bRow.dot:GetVertexColor()) == joan.ns.Skin.C.verdant[2], "Brannoc's Battle.net row: " .. tostring(bRow and bRow.name._text) .. ", " .. brannocs)
    check(gRow and plain(gRow.name._text) == called("Grift") and gRow.class._atlas == "classicon-rogue" and not gRow.gem:IsShown() and gRow.level._text == 20,
        "Grift's row on the friends list")
    check(not rowOf("bn:Eluned#1505"), "a Battle.net friend away, silent and sharing nothing is listed")
    local summary = texts(joan):match("%d+ friends? · %d+ online")
    check(summary == "2 friends · 2 online", "the Friends tab's count: " .. tostring(summary))
    laidOut(joan, "the Friends tab")
    -- Brannoc's page: his reliquary, and the Battle.net whispers, answered from its box by Battle.net.
    joan.ui.run(bRow, "OnClick")
    check(button(joan, "Gear") and button(joan, "Whispers"), "Brannoc's page has no Gear or Whispers")
    joan.ui.run(button(joan, "Whispers"), "OnClick")
    local wv = conversation(joan)
    check(wv and not wv.pick, "Brannoc's Whispers page isn't shown")
    rows = said(wv)
    check(#rows == 1 and rows[1].body._text:find("Deadmines", 1, true) and colored(rows[1].body, "BN_WHISPER", joan.env), "the Battle.net whisper on Brannoc's page")
    wv.input:SetText("On my way")
    joan.ui.run(wv.input, "OnEnterPressed")
    advance(1)
    sent = joan.chatSent[#joan.chatSent]
    check(sent.kind == "BN_WHISPER" and sent.target == brannoc.account and sent.text == "On my way", "the box didn't whisper Brannoc by Battle.net")
    bj = brannoc.ns.whispersWith(joanTag)
    check(#bj == 2 and not bj[2].o and bj[2].m == "On my way" and bj[2].c == "DRUID", "Brannoc didn't get Joan's Battle.net whisper")
    rows = said(wv)
    check(#rows == 2 and colored(rows[2].body, "BN_WHISPER_INFORM", joan.env), "Joan's Battle.net whisper on Brannoc's page, as sent")
    laidOut(joan, "Brannoc's Battle.net whispers")
    -- Brannoc whispers Joan in the game by his character's name: it joins the Battle.net ones on his
    -- page, after them, in the whisper colour, and his page in the guild's or anyone's list has them all.
    world.say(brannoc, "Bring bandages", "WHISPER", joan.full)
    advance(1)
    check(#joan.ns.whispersWith(brannoc.full) == 1, "Joan didn't keep Brannoc's whisper under his character")
    rows = said(conversation(joan))
    check(#rows == 3 and rows[3].body._text == "Bring bandages" and colored(rows[3].body, "WHISPER", joan.env) and colored(rows[1].body, "BN_WHISPER", joan.env),
        "Brannoc's whispers by Battle.net and by name, on one page: " .. #rows)
    local both = joan.ns.whispersWith(brannoc.full, brannocTag)
    check(#both == 3 and both[3].m == "Bring bandages" and both[1].m:find("Deadmines", 1, true), "his whispers by name and by Battle.net, in time order")
    -- Grift's page: what the friends list says above your whispers with him, a box to whisper him
    -- before there are any.
    joan.ui.run(rowOf(rogue.full), "OnClick")
    local page = texts(joan)
    check(page:find("Level 20", 1, true) and page:find("Friend", 1, true) and page:find("Met in Westfall", 1, true)
        and button(joan, "Whispers") and #said(conversation(joan)) == 0 and conversation(joan).input.Instructions._text == "Whisper " .. called("Grift"),
        "Grift's page from the friends list: " .. page:sub(1, 400))
    laidOut(joan, "a friend without a reliquary")
    -- Nothing said yet: no search and no words, only the box.
    local gv = conversation(joan)
    check(not gv.search:IsShown() and not gv.empty:IsShown() and gv.box:IsShown(), "a conversation with nothing in it shows a search or words")
    world.say(joan, "Thanks for the help in Westfall", "WHISPER", rogue.full)
    advance(1)
    check(conversation(joan).search:IsShown(), "a conversation with a line in it has no search")
    check(button(joan, "Whispers") and not button(joan, "Friend"), "a friend without a reliquary has no Whispers page after a whisper")
    rows = said(conversation(joan))
    check(#rows == 1 and rows[1].body._text == "Thanks for the help in Westfall", "the whisper on Grift's page")
    -- Someone who's no friend and not in the guild whispers Joan: they're under Others you've
    -- whispered, below the friends, their page the whispers alone. Guildmates she's whispered with
    -- aren't there: their page is on the Guild tab.
    world.say(kael, "Got a spare silk?", "WHISPER", joan.full)
    advance(1)
    fl = list(joan)
    local head, kRow, heads = nil, rowOf(kael.full), 0
    for i, r in ipairs(fl._rows) do
        if r.row and r.row.head then head, heads = i, heads + 1 end
    end
    -- Orlan, a guildmate who doesn't share, whispered Joan earlier: his page is on the Guild tab.
    local orlan = REGIONAL and (GUILD.others[1][1] .. " " .. GUILD.others[1][6]) or (GUILD.others[1][1] .. "-" .. REALM)
    check(#joan.ns.whispersWith(orlan) > 0, "Orlan's whisper to Joan is gone")
    check(heads == 1 and kRow and head and fl._rows[head].title._text == "OTHERS YOU'VE WHISPERED" and fl._rows[head + 1] == kRow
        and not rowOf(mira.full) and not rowOf(thalia.full) and not rowOf(orlan), "Kael under Others you've whispered, and no guildmate")
    -- The heading is nothing to choose: Grift stays chosen, his page open.
    joan.ui.run(fl._rows[head], "OnEnter")
    joan.ui.run(fl._rows[head], "OnClick")
    advance(1)
    fl = list(joan)
    check(rowOf(rogue.full).chosen and not fl._rows[head].chosen and (fl._rows[head].fill.alpha or 0) == 0 and button(joan, "Whispers"),
        "the heading was chosen or opened something")
    joan.ui.run(kRow, "OnClick")
    check(button(joan, "Whispers") and not button(joan, "Friend") and not button(joan, "Roster") and not button(joan, "Gear"), "Kael's page isn't his whispers alone")
    rows = said(conversation(joan))
    check(#rows == 1 and rows[1].body._text == "Got a spare silk?" and texts(joan):find("Whispered", 1, true), "Kael's whispers and when")
    laidOut(joan, "someone else you've whispered")
    -- Reliquary users only: Brannoc alone, and nobody else you've whispered.
    local only
    for _, f in ipairs(joan.ui.frames) do
        if rawget(f, "onlyLabel") and f:IsVisible() and f.onlyLabel._text == "Reliquary users only" then only = f.only end
    end
    only:SetChecked(true) -- as the game ticks a box before its click runs
    joan.ui.run(only, "OnClick")
    fl = list(joan)
    local keys = {}
    for _, r in ipairs(fl._rows) do if r:IsShown() and r.row then keys[#keys + 1] = r.row.key end end
    check(#keys == 1 and keys[1] == brannocTag, "Reliquary users only: " .. table.concat(keys, ", "))
    only:SetChecked(false)
    joan.ui.run(only, "OnClick")
    -- The list follows the friends list while it shows: Eluned, online again and added as a friend,
    -- appears without the tab being opened again.
    eluned.online = true
    joan.opts.friends = { "Grift", "Eluned" }
    joan.fire("FRIENDLIST_UPDATE")
    advance(1)
    fl = list(joan)
    check(rowOf(eluned.full), "a friend added while the Friends tab shows isn't listed")
    -- Someone sharing as a friend whom the lists no longer name (Brannoc, off Joan's Battle.net list)
    -- still shows, by their reliquary; the Battle.net whispers, with no Battle.net friend now to sit
    -- under, go to Others you've whispered.
    joan.opts.friends, joan.opts.bnFriends = { "Grift" }, {}
    joan.fire("BN_FRIEND_LIST_SIZE_CHANGED")
    advance(1)
    fl = list(joan)
    local kept, after = rowOf(fullOf("Brannoc")), false
    for _, r in ipairs(fl._rows) do
        if r.row and r.row.head then after = true end
        if r.row and r.row.key == brannocTag then check(after, "Brannoc's Battle.net whispers above the heading once he's off the list") end
    end
    check(kept and kept.gem:IsShown() and rowOf(brannocTag), "a reliquary shared as a friend, or its Battle.net whispers, unlisted once the friends lists don't name them")
    -- A Battle.net friend who doesn't share (Grift, off Joan's friends list and on her Battle.net list),
    -- playing a character she whispered by name: one row, by BattleTag, none under Others you've
    -- whispered, and his page has the whispers with that character.
    local griftTag = "bn:Grift#" .. (1000 + rogue.account)
    joan.opts.friends, joan.opts.bnFriends = {}, { "Brannoc", "Grift" }
    joan.fire("FRIENDLIST_UPDATE")
    joan.fire("BN_FRIEND_LIST_SIZE_CHANGED")
    advance(1)
    fl = list(joan)
    local gb = rowOf(griftTag)
    check(gb and not rowOf(rogue.full), "Grift on Battle.net: a row by BattleTag, and another under Others for his character")
    joan.ui.run(gb, "OnClick")
    rows = said(conversation(joan))
    check(button(joan, "Whispers") and #rows == 1 and rows[1].body._text == "Thanks for the help in Westfall" and colored(rows[1].body, "WHISPER_INFORM", joan.env),
        "Grift's Battle.net page doesn't have the whisper to his character: " .. #rows)
    joan.opts.friends, joan.opts.friendNotes, joan.opts.bnFriends = nil, nil, { "Brannoc" }

    -- None of it goes anywhere.
    for _, c in ipairs(world.clients) do
        check(not holds(c.db().peers, "mumblecore") and not holds(c.db().peers, "pterodactyl") and not holds(c.db().guilds, "pterodactyl"),
            c.name .. " got officer chat or a Battle.net whisper from another player's Reliquary")
    end
    if win:IsShown() then joan.slash("") end
end)()

for _, c in ipairs(world.clients) do world.plainWords(c.name .. "'s chat", table.concat(c.printed, "\n")) end

---------------------------------------------------------------------------
-- 8i. The minimap: Reliquary's button on its edge, drawn, placed and dragged as LibDBIcon's buttons
-- are (radius 104 on a minimap of 198), and its line in the minimap's Addons menu. A click opens the
-- window as /rq does, a right-click opens Sharing; its switch, on the Sharing tab and in Options,
-- hides it, and where it sits and whether it shows outlast the session.
---------------------------------------------------------------------------
;(function()
    local env, ui, b
    local function current()
        env, ui = joan.env, joan.ui
        b = env.ReliquaryMinimapButton
    end
    current()
    local settings = function() return joan.db().settings end
    local function near(a, x) return type(a) == "number" and math.abs(a - x) < 0.01 end
    local function placed(deg, what)
        local point, rel, relPoint, x, y = b:GetPoint(1)
        local ex, ey = math.cos(math.rad(deg)) * 104, math.sin(math.rad(deg)) * 104
        check(point == "CENTER" and rel == env.Minimap and relPoint == "CENTER" and near(x, ex) and near(y, ey),
            ("%s: the button at (%s, %s), not at %d degrees (%.2f, %.2f)"):format(what, tostring(x), tostring(y), deg, ex, ey))
    end
    local function coords() return table.concat(b.icon._texCoord or {}, ",") end
    local AT_REST, HELD = "0.05,0.95,0.05,0.95", "0,1,0,1"
    local function closed() if env.ReliquaryFrame and env.ReliquaryFrame:IsShown() then joan.slash("") end end

    check(b and b:GetParent() == env.Minimap and b:IsShown() and b:GetWidth() == 31 and b:GetHeight() == 31, "no minimap button of LibDBIcon's size after logging in")
    local art = {}
    for _, r in ipairs(ui.regions) do if r._parent == b and r._kind == "Texture" then art[tostring(r._texture)] = r end end
    check(art["136430"] and art["136430"]:GetWidth() == 50 and art["136467"] and art["136467"]:GetWidth() == 24
        and b.icon._texture == "Interface\\AddOns\\Reliquary\\Media\\icon" and b.icon:GetWidth() == 18, "the button isn't drawn as LibDBIcon draws one")
    placed(111, "where it starts")
    -- The icon a little smaller while held.
    check(coords() == AT_REST, "the icon at rest: " .. coords())
    ui.run(b, "OnMouseDown", "LeftButton")
    check(coords() == HELD, "the icon held: " .. coords())
    ui.run(b, "OnMouseUp", "LeftButton")
    check(coords() == AT_REST, "the icon let go: " .. coords())

    -- Its tooltip, toward the middle of the screen: below it, lined up with its right side, in the
    -- top right corner.
    local tip = env.GameTooltip
    tip._texts = {}
    ui.run(b, "OnEnter")
    local said = table.concat(tip._texts, "|")
    check(tip._shown and tip._owner == b and tip._text == "Reliquary" and said == "Click to open|Right-click for Sharing|Drag to move", "the button's tooltip: " .. tostring(tip._text) .. " | " .. said)
    check(tip._point and tip._point[1] == "TOPRIGHT" and tip._point[2] == b and tip._point[3] == "BOTTOMRIGHT", "the tooltip isn't below the button: " .. table.concat(tip._point or {}, " ", 1, 1))
    world.plainWords("the minimap button's tooltip", tip._text .. "\n" .. said)
    ui.run(b, "OnLeave")
    check(not tip._shown, "the tooltip stayed")

    -- Dragged, it follows the cursor around the edge (only the angle counts) and keeps its place;
    -- no tooltip while it moves.
    local mx, my = env.Minimap:GetCenter()
    local cursor = { mx, my }
    env.GetCursorPosition = function() return cursor[1], cursor[2] end
    ui.run(b, "OnDragStart")
    check(b:GetScript("OnUpdate") and coords() == HELD, "dragging didn't start")
    tip._shown = false
    ui.run(b, "OnEnter")
    check(not tip._shown, "a tooltip while the button is dragged")
    cursor = { mx + math.cos(math.rad(200)) * 40, my + math.sin(math.rad(200)) * 40 }
    ui.run(b, "OnUpdate", 0.01)
    check(near(settings().minimapPos, 200), "dragged to 200 degrees, it saved " .. tostring(settings().minimapPos))
    placed(200, "dragged")
    cursor = { mx + 300, my - 300 } -- past the edge, down and to the right
    ui.run(b, "OnUpdate", 0.01)
    placed(315, "dragged past the edge")
    ui.run(b, "OnDragStop")
    check(b:GetScript("OnUpdate") == nil and coords() == AT_REST, "dragging didn't stop")
    -- A minimap another addon made square: the button runs along the edge, as LibDBIcon's.
    env.GetMinimapShape = function() return "SQUARE" end
    settings().minimapPos = 45
    joan.ns.updateMinimapButton()
    local _, _, _, sx, sy = b:GetPoint(1)
    local along = math.min(math.cos(math.rad(45)) * (math.sqrt(2 * 104 * 104) - 10), 104)
    check(near(sx, along) and near(sy, along), ("on a square minimap the button at (%s, %s), not on its edge at %.2f"):format(tostring(sx), tostring(sy), along))
    env.GetMinimapShape = nil
    settings().minimapPos = 200
    joan.ns.updateMinimapButton()
    -- Where it was left is where the next session puts it.
    newSession(joan)
    current()
    placed(200, "after logging in again")

    -- A click opens the window as /rq does and closes it again; a right-click opens Sharing.
    closed()
    ui.run(b, "OnClick", "LeftButton")
    local win = env.ReliquaryFrame
    check(win and win:IsShown(), "a click didn't open the window")
    ui.run(b, "OnClick", "LeftButton")
    check(not win:IsShown(), "a second click didn't close it")
    ui.run(b, "OnClick", "RightButton")
    check(win:IsShown() and win.selectedTab == TAB.Sharing, "a right-click didn't open Sharing")

    -- Its switch on the Sharing tab hides it, for the next session too.
    local box
    for _, f in ipairs(ui.frames) do
        local label = f._kind == "CheckButton" and rawget(f, "Text")
        if label and label._text == "Show the minimap button" and f:IsVisible() then box = f end
    end
    check(box and box:GetChecked(), "the minimap button's switch on the Sharing tab isn't on")
    box:SetChecked(false)
    ui.run(box, "OnClick")
    check(not b:IsShown() and settings().minimapButton == false, "the switch didn't hide the button")
    closed()
    newSession(joan)
    current()
    check(b and not b:IsShown(), "the hidden button came back in the next session")
    -- Options > AddOns > Reliquary has the same switch.
    local opt = ui.settings.Reliquary and ui.settings.Reliquary.settings.RELIQUARY_MINIMAP_BUTTON
    check(opt and opt.default == true and opt.get() == false, "Options' minimap button switch")
    opt.set(true)
    check(b:IsShown() and opt.get() == true and settings().minimapButton == true, "Options didn't show the button")
    world.plainWords("the minimap button's switches", (box.Text._text or "") .. "\n" .. opt.name .. "\n" .. (opt.tooltip or ""))

    -- The minimap's Addons menu: the game calls the three functions the TOC names. The same clicks;
    -- the tooltip beside the menu, on the side with room, and nothing about dragging.
    local toc = assert(io.open(tocPath)):read("*a")
    local fn = {}
    for field, name in toc:gmatch("## (AddonCompartmentFunc%w*): (%S+)") do fn[field] = env[name] end
    check(type(fn.AddonCompartmentFunc) == "function" and type(fn.AddonCompartmentFuncOnEnter) == "function" and type(fn.AddonCompartmentFuncOnLeave) == "function",
        "the TOC's Addons menu functions don't exist")
    closed()
    fn.AddonCompartmentFunc("Reliquary", "LeftButton")
    win = env.ReliquaryFrame
    check(win and win:IsShown(), "the Addons menu didn't open the window")
    fn.AddonCompartmentFunc("Reliquary", "LeftButton")
    check(not win:IsShown(), "the Addons menu didn't close it")
    fn.AddonCompartmentFunc("Reliquary", "RightButton")
    check(win:IsShown() and win.selectedTab == TAB.Sharing, "a right-click in the Addons menu didn't open Sharing")
    closed()
    tip = env.GameTooltip
    for _, side in ipairs({ { "TOPRIGHT", -20, "TOPRIGHT", "TOPLEFT" }, { "TOPLEFT", 20, "TOPLEFT", "TOPRIGHT" } }) do
        local entry = env.CreateFrame("Button", nil, env.UIParent)
        entry:SetSize(150, 20)
        entry:SetPoint(side[1], env.UIParent, side[1], side[2], -60)
        tip._texts = {}
        fn.AddonCompartmentFuncOnEnter("Reliquary", entry)
        said = table.concat(tip._texts, "|")
        check(tip._shown and tip._owner == entry and tip._text == "Reliquary" and said == "Click to open|Right-click for Sharing", "the Addons menu's tooltip: " .. said)
        check(tip._point and tip._point[1] == side[3] and tip._point[2] == entry and tip._point[3] == side[4],
            "the Addons menu's tooltip by a menu at the " .. side[1] .. " isn't beside it: " .. tostring(tip._point and tip._point[1]))
        fn.AddonCompartmentFuncOnLeave("Reliquary", entry)
        check(not tip._shown, "the Addons menu's tooltip stayed")
    end
    settings().minimapPos, settings().minimapButton = nil, nil
    joan.ns.updateMinimapButton()
    placed(111, "back where it starts")
end)()

---------------------------------------------------------------------------
-- 9. Forgetting: public cards after two weeks, friends' after a month, leavers at once
---------------------------------------------------------------------------
-- With no guild master's settings in force, a guildmate who sends the Officers tab to the whole
-- guild is ignored; sent by whisper to someone who may view it, it is kept, newest copy wins, and
-- it says who saw it: guildmates are trusted with the bank, and named.
mira.ns.send({ kind = "GUILD" }, { t = "gb", i = 3, at = world.clock, by = "Mira", nm = "Officers", s = { [1] = { id = 5498, c = 3 } } })
advance(20)
check(joan.db().guilds[gk()].bank.tabs[3].by ~= "Mira", "a tab sent to the whole guild was kept")
mira.ns.send({ kind = "WHISPER", target = joan.full }, { t = "gb", i = 3, at = joan.db().guilds[gk()].bank.tabs[3].at - 60, by = "Mira", nm = "Officers", s = { [1] = { id = 5498, c = 3 } } })
advance(20)
check(joan.db().guilds[gk()].bank.tabs[3].by ~= "Mira", "an older copy of a tab replaced a newer one")
mira.ns.send({ kind = "WHISPER", target = joan.full }, { t = "gb", i = 3, at = world.clock, by = "Mira", nm = "Officers", s = { [1] = { id = 5498, c = 3 } } })
mira.ns.send({ kind = "WHISPER", target = thalia.full }, { t = "gb", i = 3, at = world.clock, by = "Mira", nm = "Officers", s = { [1] = { id = 5498, c = 3 } } })
advance(20)
check(not thalia.db().guilds[gk()].bank.tabs[3], "Thalia stored an Officers tab sent to her")
check(joan.db().guilds[gk()].bank.tabs[3].by == "Mira", "the Officers tab Joan keeps doesn't say who saw it")
local function relog(c) c.ns.prunePeers() end -- what a new session does first with the saved data
thalia.leftGuild = true
joan.fire("GUILD_ROSTER_UPDATE")
advance(70)
joan.fire("GUILD_ROSTER_UPDATE")
advance(5)
check(not (peer(joan, "Thalia") and peer(joan, "Thalia").scopes.g), "Thalia left the guild, but Joan still keeps her guild card")
world.clock = world.clock + 15 * 86400
relog(joan)
advance(20)
check(not word(joan, "aside", 3, 6505, thalia.full) and not word(joan, "aside", 3, 5498, faelwen.full), "a set-aside is kept after two weeks")
check(joan.ns.priceWords(858) == nil and joan.ns.priceLine(858), "a price two weeks old is still on the game's tooltips, or gone from the item's page")
check(not peer(joan, "Eluned"), "a public card nobody refreshed for two weeks is still kept")
check(peer(joan, "Brannoc"), "a friend's card was forgotten too early")
world.clock = world.clock + 16 * 86400
relog(joan)
check(not peer(joan, "Brannoc"), "a friend's card nobody refreshed for a month is still kept")

---------------------------------------------------------------------------
-- 10. Two of your characters with the same given name on one realm: each keeps its own record
---------------------------------------------------------------------------
-- Where names are "Given Family" the game allows it. Joan logs out, and another Joan of the same
-- account, in the same guild, plays: she gets her own record, Joan's stays as it was, and the
-- guild's items name Joan by her full name for her.
if REGIONAL then
    joan.online = false
    local before = savedCopy(joan.db().chars[ownKey(joan)])
    local twin = client({ name = "Joan", surname = "Brightwood", class = "MAGE", race = "Human", raceFile = "Human", level = 9, guild = true, rank = 4,
        gear = { [16] = 264160 }, ilvl = 5, db = savedCopy(joan.db()), alt = true })
    login(twin)
    advance(20)
    local a = twin.db().chars
    local hers, other = a[ownKey(joan)], a[ownKey(twin)]
    check(hers and other and hers ~= other and other.classFile == "MAGE" and other.level == 9 and hers.classFile == "DRUID" and hers.level == before.level
        and hers.updated == before.updated, "two of your characters with the same given name on one realm share a record")
    local own
    for _, x in ipairs(twin.ns.whoCanUse(6505)) do if x.who == "own:" .. ownKey(joan) then own = x end end
    check(own and own.name == "Joan Ofârc" and own.cls == "DRUID", "the other Joan isn't named apart on the staff's page: " .. tostring(own and own.name))
    twin.online = false
end

---------------------------------------------------------------------------
-- What every client saved: no secrets, nothing unsaveable, never an officer note
---------------------------------------------------------------------------
local function walk(v, path)
    check(type(v) ~= "function" and type(v) ~= "userdata", "unsaveable value at " .. path)
    if type(v) == "table" then for k, x in pairs(v) do walk(k, path .. ".<key>") walk(x, path .. "." .. tostring(k)) end end
    check(v ~= "never read", "an officer note was saved at " .. path)
end
for _, c in ipairs(world.clients) do
    walk(c.db(), c.name)
    check(not holds(c.db(), "Seller"), c.name .. " saved an auction seller's name")
    for _, ch in pairs(c.db().chars) do check(not ch.errors, c.name .. " recorded errors") end
end

if outPath then
    -- Joan's guild and what others share with her, for the dashboard's sample data.
    local function q(s) return '"' .. s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n") .. '"' end
    local function emit(v, indent)
        local tv = type(v)
        if tv == "string" then return q(v) end
        if tv == "number" then return v == floor(v) and string.format("%d", v) or string.format("%.14g", v) end
        if tv ~= "table" then return tostring(v) end
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = k end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        local lines = { "{" }
        for _, k in ipairs(keys) do
            lines[#lines + 1] = indent .. "\t[" .. (type(k) == "string" and q(k) or tostring(k)) .. "] = " .. emit(v[k], indent .. "\t") .. ","
        end
        lines[#lines + 1] = indent .. "}"
        return table.concat(lines, "\n")
    end
    local f = assert(io.open(outPath, "w"))
    f:write("ReliquaryShared = " .. emit(snapshot, "") .. "\n")
    f:close()
end
-- A tab left with nothing to show is greyed, and while it shows gives way to Characters; it opens again
-- once it has something. (Last, as opening a page asks its player for news the checks above count.)
do
    local w = joan.env.ReliquaryFrame
    if not w:IsShown() then joan.slash("") end
    joan.online = true
    eluned.slash("share public on")
    joan.slash("look " .. lookName("Eluned"))
    advance(30)
    check(#joan.ns.peerList("p") > 0, "Eluned doesn't share with Joan publicly")
    joan.ns.onDataChanged()
    advance(1)
    joan.ui.run(w.Tabs[TAB.Public], "OnClick")
    check(w.selectedTab == TAB.Public, "the Public tab doesn't open")
    local held = {}
    for _, p in pairs(joan.db().peers) do if type(p) == "table" and p.scopes and p.scopes.p then held[p] = p.scopes.p p.scopes.p = nil end end
    joan.ns.onDataChanged("peers")
    advance(1)
    check(w.selectedTab == TAB.Characters and not w.Tabs[TAB.Public]:IsEnabled(), "the Public tab, left with nobody, kept showing")
    for p, v in pairs(held) do p.scopes.p = v end
    joan.ns.onDataChanged("peers")
    advance(1)
    check(w.Tabs[TAB.Public]:IsEnabled() and w.selectedTab == TAB.Characters, "the Public tab didn't open again once it had someone")
end
local total, players = 0, 0
for _, c in ipairs(world.clients) do
    total = total + #c.sent
    if not c.opts.alt then players = players + 1 end
end
print(("share ok: %d players, %d messages, none over 255 characters, %d refused and retried"):format(players, total, thalia.throttled))
