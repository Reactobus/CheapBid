-- ===========================================================================
-- CheapBids Disenchant
-- ---------------------------------------------------------------------------
-- A self-contained port of Enchantrix's disenchant tooltip for TBC 2.5.5: when
-- you hover an uncommon/rare/epic weapon or armor piece, the tooltip gets a
-- "Disenchants into:" block listing the possible reagents, their drop chance
-- and average quantity.
--
-- The data is Enchantrix's baseDisenchantTable, CLASSIC branch (EnxConstants.lua,
-- "if const.Classic then" section, v2.6.6 crediar) - the [quality][class][ilvl
-- bracket] table below is copied 1:1, only reshaped. Bracket selection is their
-- roundupLevel(): first bound >= item level, nil above the last bound. Weapon
-- lookups for rare/epic fall back to the armor table, like the original.
--
-- Everything Norganna-specific is stripped: no LibStub/Babylonian/Stubby, no
-- saved per-item statistics, no localization, no price valuation. Static table
-- only, so no SavedVariables besides the on/off flag.
--
-- This is a SEPARATE plug-in addon (folder CheapBids_Disenchant, its own .toc
-- with "## Dependencies: CheapBids"), like CheapBids_CompactBrowse. It touches
-- nothing in CheapBids.lua, only HookScript's the standard tooltips (additive,
-- no taint: we never replace secure functions). Toggle with /cbde (persisted in
-- CheapBidsDB.disenchantTip, applies immediately, no /reload needed).
-- Displayed text is ASCII/English only, per project rules.
-- ===========================================================================

-- ---- reagents: itemID, English name, reagent quality (for name colour) -----
-- Names are hardcoded so lines render even when the reagent is not in the
-- player's item cache (GetItemInfo would return nil there); when GetItemInfo
-- does answer, the live (localized) name wins. Icons come from
-- GetItemInfoInstant, which works for uncached items too.
local R = {
    -- dusts (common)
    STRANGE     = { 10940, "Strange Dust",           1 },
    SOUL        = { 11083, "Soul Dust",              1 },
    VISION      = { 11137, "Vision Dust",            1 },
    DREAM       = { 11176, "Dream Dust",             1 },
    ILLUSION    = { 16204, "Illusion Dust",          1 },
    ARCANE      = { 22445, "Arcane Dust",            1 },
    -- essences (uncommon)
    LMAGIC      = { 10938, "Lesser Magic Essence",   2 },
    GMAGIC      = { 10939, "Greater Magic Essence",  2 },
    LASTRAL     = { 10998, "Lesser Astral Essence",  2 },
    GASTRAL     = { 11082, "Greater Astral Essence", 2 },
    LMYSTIC     = { 11134, "Lesser Mystic Essence",  2 },
    GMYSTIC     = { 11135, "Greater Mystic Essence", 2 },
    LNETHER     = { 11174, "Lesser Nether Essence",  2 },
    GNETHER     = { 11175, "Greater Nether Essence", 2 },
    LETERNAL    = { 16202, "Lesser Eternal Essence", 2 },
    GETERNAL    = { 16203, "Greater Eternal Essence",2 },
    LPLANAR     = { 22447, "Lesser Planar Essence",  2 },
    GPLANAR     = { 22446, "Greater Planar Essence", 2 },
    -- shards (rare)
    SGLIMMERING = { 10978, "Small Glimmering Shard", 3 },
    LGLIMMERING = { 11084, "Large Glimmering Shard", 3 },
    SGLOWING    = { 11138, "Small Glowing Shard",    3 },
    LGLOWING    = { 11139, "Large Glowing Shard",    3 },
    SRADIANT    = { 11177, "Small Radiant Shard",    3 },
    LRADIANT    = { 11178, "Large Radiant Shard",    3 },
    SBRILLIANT  = { 14343, "Small Brilliant Shard",  3 },
    LBRILLIANT  = { 14344, "Large Brilliant Shard",  3 },
    SPRISMATIC  = { 22448, "Small Prismatic Shard",  3 },
    LPRISMATIC  = { 22449, "Large Prismatic Shard",  3 },
    -- crystals (epic)
    NEXUS       = { 20725, "Nexus Crystal",          4 },
    VOID        = { 22450, "Void Crystal",           4 },
}

-- ---- equip slot -> weapon/armor (Enchantrix const.InventoryTypes, 1:1) -----
local WEAPON, ARMOR = 2, 4
local SLOT_CLASS = {
    INVTYPE_2HWEAPON = WEAPON, INVTYPE_WEAPON = WEAPON,
    INVTYPE_WEAPONMAINHAND = WEAPON, INVTYPE_WEAPONOFFHAND = WEAPON,
    INVTYPE_RANGED = WEAPON, INVTYPE_RANGEDRIGHT = WEAPON, INVTYPE_THROWN = WEAPON,
    INVTYPE_CHEST = ARMOR, INVTYPE_CLOAK = ARMOR, INVTYPE_FEET = ARMOR,
    INVTYPE_FINGER = ARMOR, INVTYPE_HAND = ARMOR, INVTYPE_HEAD = ARMOR,
    INVTYPE_HOLDABLE = ARMOR, INVTYPE_LEGS = ARMOR, INVTYPE_NECK = ARMOR,
    INVTYPE_ROBE = ARMOR, INVTYPE_SHIELD = ARMOR, INVTYPE_SHOULDER = ARMOR,
    INVTYPE_TABARD = ARMOR, INVTYPE_TRINKET = ARMOR, INVTYPE_WAIST = ARMOR,
    INVTYPE_WRIST = ARMOR, INVTYPE_RELIC = ARMOR,
}

-- ---- items that look disenchantable but are not (Enchantrix list, ---------
-- ---- trimmed to itemIDs that exist on a TBC client) ------------------------
local NON_DE = {
    [3456] = true, [5976] = true,                              -- dog whistle, guild tabard
    [11287] = true, [11288] = true, [11289] = true, [11290] = true, -- enchanter wands
    [13544] = true, [18706] = true,                            -- quest trinkets
    [17690] = true, [17691] = true,                            -- AV insignias
    [17900] = true, [17901] = true, [17902] = true, [17903] = true, [17904] = true,
    [17905] = true, [17906] = true, [17907] = true, [17908] = true, [17909] = true,
    [20406] = true, [20407] = true, [20408] = true,            -- twilight cultist garb
    [22206] = true,                                            -- bouquet of red roses
    [32538] = true, [32539] = true,                            -- skyguard drapes
    [32757] = true,                                            -- black temple medallion
    [33292] = true,                                            -- hallowed helm
    [34073] = true, [34484] = true,                            -- horseman ring, old ironjaw
    [34648] = true, [34649] = true, [34650] = true, [34651] = true,
    [34652] = true, [34653] = true, [34655] = true, [34656] = true,
    [35279] = true, [35494] = true, [35497] = true,            -- fire festival tabard, ahune cloaks
}

-- ---- the disenchant table: [quality][class][bracket] = {reagentKey,prob,avg}
-- Copied from Enchantrix baseDisenchantTable (Classic branch). bounds must stay
-- sorted ascending; a lookup picks the first bound >= item level.
local UNCOMMON, RARE, EPIC = 2, 3, 4
local DE_TABLE = {
    [UNCOMMON] = {
        [WEAPON] = {
            bounds = { 15, 20, 25, 30, 35, 40, 45, 50, 55, 60, 65, 99, 120 },
            [15]  = { { "STRANGE", 0.20, 1.5 }, { "LMAGIC",   0.80, 1.5 } },
            [20]  = { { "STRANGE", 0.20, 2.5 }, { "GMAGIC",   0.75, 1.5 }, { "SGLIMMERING", 0.05, 1.0 } },
            [25]  = { { "STRANGE", 0.15, 5.0 }, { "LASTRAL",  0.75, 1.5 }, { "SGLIMMERING", 0.10, 1.0 } },
            [30]  = { { "SOUL",    0.20, 1.5 }, { "GASTRAL",  0.75, 1.5 }, { "LGLIMMERING", 0.05, 1.0 } },
            [35]  = { { "SOUL",    0.20, 3.5 }, { "LMYSTIC",  0.75, 1.5 }, { "SGLOWING",    0.05, 1.0 } },
            [40]  = { { "VISION",  0.20, 1.5 }, { "GMYSTIC",  0.75, 1.5 }, { "LGLOWING",    0.05, 1.0 } },
            [45]  = { { "VISION",  0.20, 3.5 }, { "LNETHER",  0.75, 1.5 }, { "SRADIANT",    0.05, 1.0 } },
            [50]  = { { "DREAM",   0.20, 1.5 }, { "GNETHER",  0.75, 1.5 }, { "LRADIANT",    0.05, 1.0 } },
            [55]  = { { "DREAM",   0.20, 3.5 }, { "LETERNAL", 0.75, 1.5 }, { "SBRILLIANT",  0.05, 1.0 } },
            [60]  = { { "ILLUSION",0.20, 1.5 }, { "GETERNAL", 0.75, 1.5 }, { "LBRILLIANT",  0.05, 1.0 } },
            [65]  = { { "ILLUSION",0.20, 3.5 }, { "GETERNAL", 0.75, 2.5 }, { "LBRILLIANT",  0.05, 1.0 } },
            [99]  = { { "ARCANE",  0.20, 2.5 }, { "LPLANAR",  0.75, 2.5 }, { "SPRISMATIC",  0.05, 1.0 } },
            [120] = { { "ARCANE",  0.20, 3.5 }, { "GPLANAR",  0.75, 1.5 }, { "LPRISMATIC",  0.05, 1.0 } },
        },
        [ARMOR] = {
            bounds = { 15, 20, 25, 30, 35, 40, 45, 50, 55, 60, 65, 99, 120 },
            [15]  = { { "STRANGE", 0.80, 1.5 }, { "LMAGIC",   0.20, 1.5 } },
            [20]  = { { "STRANGE", 0.75, 2.5 }, { "GMAGIC",   0.20, 1.5 }, { "SGLIMMERING", 0.05, 1.0 } },
            [25]  = { { "STRANGE", 0.75, 5.0 }, { "LASTRAL",  0.15, 1.5 }, { "SGLIMMERING", 0.10, 1.0 } },
            [30]  = { { "SOUL",    0.75, 1.5 }, { "GASTRAL",  0.20, 1.5 }, { "LGLIMMERING", 0.05, 1.0 } },
            [35]  = { { "SOUL",    0.75, 3.5 }, { "LMYSTIC",  0.20, 1.5 }, { "SGLOWING",    0.05, 1.0 } },
            [40]  = { { "VISION",  0.75, 1.5 }, { "GMYSTIC",  0.20, 1.5 }, { "LGLOWING",    0.05, 1.0 } },
            [45]  = { { "VISION",  0.75, 3.5 }, { "LNETHER",  0.20, 1.5 }, { "SRADIANT",    0.05, 1.0 } },
            [50]  = { { "DREAM",   0.75, 1.5 }, { "GNETHER",  0.20, 1.5 }, { "LRADIANT",    0.05, 1.0 } },
            [55]  = { { "DREAM",   0.75, 3.5 }, { "LETERNAL", 0.20, 1.5 }, { "SBRILLIANT",  0.05, 1.0 } },
            [60]  = { { "ILLUSION",0.75, 1.5 }, { "GETERNAL", 0.20, 1.5 }, { "LBRILLIANT",  0.05, 1.0 } },
            [65]  = { { "ILLUSION",0.75, 3.5 }, { "GETERNAL", 0.20, 2.5 }, { "LBRILLIANT",  0.05, 1.0 } },
            [99]  = { { "ARCANE",  0.75, 2.5 }, { "LPLANAR",  0.20, 2.5 }, { "SPRISMATIC",  0.05, 1.0 } },
            [120] = { { "ARCANE",  0.75, 3.5 }, { "GPLANAR",  0.20, 1.5 }, { "LPRISMATIC",  0.05, 1.0 } },
        },
    },
    [RARE] = {
        [ARMOR] = {  -- weapons use this table too (fallback, like Enchantrix)
            bounds = { 25, 30, 35, 40, 45, 50, 55, 65, 99, 120 },
            [25]  = { { "SGLIMMERING", 1.00, 1.0 } },
            [30]  = { { "LGLIMMERING", 1.00, 1.0 } },
            [35]  = { { "SGLOWING",    1.00, 1.0 } },
            [40]  = { { "LGLOWING",    1.00, 1.0 } },
            [45]  = { { "SRADIANT",    1.00, 1.0 } },
            [50]  = { { "LRADIANT",    1.00, 1.0 } },
            [55]  = { { "SBRILLIANT",  1.00, 1.0 } },
            [65]  = { { "LBRILLIANT",  1.00, 1.0 } },
            [99]  = { { "SPRISMATIC",  1.00, 1.0 } },
            [120] = { { "LPRISMATIC",  1.00, 1.0 } },
        },
    },
    [EPIC] = {
        [ARMOR] = {  -- weapons use this table too (fallback, like Enchantrix)
            bounds = { 40, 45, 50, 55, 66, 94, 99, 164 },
            [40]  = { { "SRADIANT",   1.00, 3.0 } },
            [45]  = { { "SRADIANT",   1.00, 3.5 } },
            [50]  = { { "LRADIANT",   1.00, 3.5 } },
            [55]  = { { "SBRILLIANT", 1.00, 3.5 } },
            [66]  = { { "LBRILLIANT", 0.60, 4.0 }, { "GETERNAL", 0.25, 3.5 }, { "ILLUSION", 0.15, 4.5 } },
            [94]  = { { "NEXUS",      1.00, 1.5 } },  -- last classic epic is ilvl 94
            [99]  = { { "VOID",       1.00, 1.0 } },  -- first TBC epic is 95
            [164] = { { "VOID",       1.00, 1.5 } },  -- highest TBC epic
        },
    },
}

-- ---- lookup ---------------------------------------------------------------
local function RoundupLevel(level, bounds)
    for _, b in ipairs(bounds) do
        if b >= level then return b end
    end
    return nil  -- above the last bound: unknown, show nothing
end

-- returns the {reagentKey, prob, avg} rows for an item, or nil
local function Lookup(quality, slotClass, ilvl)
    if not quality or not slotClass or not ilvl then return nil end
    local byQuality = DE_TABLE[quality]
    if not byQuality then return nil end
    local t = byQuality[slotClass] or byQuality[ARMOR]
    if not t then return nil end
    local bracket = RoundupLevel(ilvl, t.bounds)
    return bracket and t[bracket] or nil
end

-- ---- tooltip lines --------------------------------------------------------
local QUALITY_HEX = {  -- fallback when ITEM_QUALITY_COLORS has no .hex (tests)
    [1] = "|cffffffff", [2] = "|cff1eff00", [3] = "|cff0070dd", [4] = "|cffa335ee",
}
local function ReagentText(key)
    local id, fallbackName, rq = R[key][1], R[key][2], R[key][3]
    local name = GetItemInfo(id) or fallbackName
    local qc = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[rq]
    local hex = (qc and qc.hex) or QUALITY_HEX[rq] or "|cffffffff"
    local icon = select(5, GetItemInfoInstant(id))
    local iconTag = icon and ("|T" .. icon .. ":14|t ") or ""
    return iconTag .. hex .. name .. "|r"
end

-- one text line per reagent, highest chance first: "75%  [icon] Strange Dust x2.5"
local function BuildLines(rows)
    local sorted = {}
    for i, row in ipairs(rows) do sorted[i] = row end
    table.sort(sorted, function(a, b) return a[2] > b[2] end)
    local lines = {}
    for _, row in ipairs(sorted) do
        local key, prob, avg = row[1], row[2], row[3]
        lines[#lines + 1] = string.format("%g%%  %s x%g", prob * 100, ReagentText(key), avg)
    end
    return lines
end

-- ---- the hook -------------------------------------------------------------
local function Enabled()
    if CheapBidsDB == nil then return true end  -- default ON
    return CheapBidsDB.disenchantTip ~= false
end

local function OnSetItem(tip)
    if not Enabled() then return end
    if tip.cheapBidsDEShown then return end     -- OnTooltipSetItem can re-fire
    local _, link = tip:GetItem()
    if not link then return end
    local itemID = tonumber(string.match(link, "item:(%d+)"))
    if not itemID or NON_DE[itemID] then return end
    local _, _, quality, ilvl, _, _, _, _, equipLoc = GetItemInfo(link)
    if not quality or quality < UNCOMMON or quality > EPIC then return end
    local rows = Lookup(quality, SLOT_CLASS[equipLoc], ilvl)
    if not rows then return end
    tip.cheapBidsDEShown = true
    tip:AddLine("Disenchants into:", 0.8, 0.6, 1.0)
    for _, line in ipairs(BuildLines(rows)) do
        tip:AddLine("  " .. line)
    end
    tip:Show()  -- re-measure so the new lines fit
end

local function HookTip(tip)
    if tip and tip.HookScript then
        tip:HookScript("OnTooltipSetItem", OnSetItem)
        tip:HookScript("OnTooltipCleared", function(t) t.cheapBidsDEShown = nil end)
    end
end
HookTip(GameTooltip)
HookTip(ItemRefTooltip)
HookTip(ShoppingTooltip1)
HookTip(ShoppingTooltip2)

-- ---- /cbde : toggle (persisted, applies immediately) -----------------------
SLASH_CHEAPBIDSDE1 = "/cbde"
SlashCmdList["CHEAPBIDSDE"] = function()
    CheapBidsDB = CheapBidsDB or {}
    CheapBidsDB.disenchantTip = not (CheapBidsDB.disenchantTip ~= false)  -- flip; default ON
    local on = CheapBidsDB.disenchantTip ~= false
    print("|cff33ff99CheapBids Disenchant|r: " .. (on and "ON" or "OFF"))
end

-- ---- test hook (headless suite defines CheapBidsTest before loading us) ----
if CheapBidsTest then
    CheapBidsTest.DE = {
        Lookup = Lookup, BuildLines = BuildLines, OnSetItem = OnSetItem,
        RoundupLevel = RoundupLevel, R = R, NON_DE = NON_DE,
        SLOT_CLASS = SLOT_CLASS, DE_TABLE = DE_TABLE,
        WEAPON = WEAPON, ARMOR = ARMOR,
    }
end
