-- ===========================================================================
-- CheapBids Prospect
-- ---------------------------------------------------------------------------
-- A self-contained port of Enchantrix's PROSPECTING tooltip for TBC 2.5.6: hover
-- a prospectable ore and the tooltip gains a "Prospects into (per 5 ore):" block
-- listing the gems it can yield and their chance; hover a gem and it shows
-- "Prospected from:" the ores that produce it (the reverse lookup).
--
-- Data is Enchantrix's const.ProspectableItems (EnxConstantsJewelcrafting.lua,
-- v2.6.6 crediar), trimmed to the ores that exist on a TBC client (classic +
-- Burning Crusade: Copper..Thorium, Fel Iron, Adamantite). Probabilities are the
-- community-measured per-prospect (per 5 ore) chances - the game exposes no API
-- for them, exactly like disenchanting.
--
-- Separate plug-in addon (folder CheapBids_Prospect, its own .toc with
-- "## Dependencies: CheapBids"), like CheapBids_Disenchant. Additive HookScript on
-- the standard tooltips only (no taint). Toggle with /cbpr (persisted in
-- CheapBidsDB.prospectTip, applies immediately). ASCII/English text only.
-- ===========================================================================

-- ---- gems: itemID -> { English name, quality (for name colour) } -----------
-- Names are hardcoded so lines render for uncached items; the live GetItemInfo
-- name wins when available. Icons come from GetItemInfoInstant (works uncached).
local GEM = {
    -- classic (all uncommon/green)
    [818]   = { "Tigerseye",          2 },
    [774]   = { "Malachite",          2 },
    [1210]  = { "Shadowgem",          2 },
    [1705]  = { "Lesser Moonstone",   2 },
    [1206]  = { "Moss Agate",         2 },
    [3864]  = { "Citrine",            2 },
    [1529]  = { "Jade",               2 },
    [7909]  = { "Aquamarine",         2 },
    [7910]  = { "Star Ruby",          2 },
    [12800] = { "Azerothian Diamond", 2 },
    [12361] = { "Blue Sapphire",      2 },
    [12799] = { "Large Opal",         2 },
    [12364] = { "Huge Emerald",       2 },
    -- Burning Crusade (uncommon)
    [23077] = { "Blood Garnet",       2 },
    [21929] = { "Flame Spessarite",   2 },
    [23112] = { "Golden Draenite",    2 },
    [23079] = { "Deep Peridot",       2 },
    [23117] = { "Azure Moonstone",    2 },
    [23107] = { "Shadow Draenite",    2 },
    -- Burning Crusade (rare)
    [23436] = { "Living Ruby",        3 },
    [23439] = { "Noble Topaz",        3 },
    [23440] = { "Dawnstone",          3 },
    [23437] = { "Talasite",           3 },
    [23438] = { "Star of Elune",      3 },
    [23441] = { "Nightseye",          3 },
    -- misc
    [24243] = { "Adamantite Powder",  1 },
}

-- ---- ores: itemID -> English name (for the reverse "Prospected from:" line) --
local ORE_NAME = {
    [2770]  = "Copper Ore",
    [2771]  = "Tin Ore",
    [2772]  = "Iron Ore",
    [3858]  = "Mithril Ore",
    [10620] = "Thorium Ore",
    [23424] = "Fel Iron Ore",
    [23425] = "Adamantite Ore",
}

-- ---- ore itemID -> { {gemID, prob}, ... } (Enchantrix ProspectableItems, 1:1) --
local PROSPECT = {
    [2770] = {   -- Copper Ore
        { 818, 0.50 }, { 774, 0.50 }, { 1210, 0.10 },
    },
    [2771] = {   -- Tin Ore
        { 1210, 0.375 }, { 1705, 0.375 }, { 1206, 0.375 },
        { 3864, 0.04 }, { 1529, 0.04 }, { 7909, 0.04 },
    },
    [2772] = {   -- Iron Ore
        { 3864, 0.375 }, { 1705, 0.375 }, { 1529, 0.375 },
        { 7909, 0.05 }, { 7910, 0.05 },
    },
    [3858] = {   -- Mithril Ore
        { 3864, 0.375 }, { 7910, 0.375 }, { 7909, 0.375 },
        { 12800, 0.03 }, { 12361, 0.03 }, { 12799, 0.03 }, { 12364, 0.03 },
    },
    [10620] = {  -- Thorium Ore
        { 7910, 0.15 }, { 12799, 0.30 }, { 12361, 0.30 }, { 12800, 0.30 }, { 12364, 0.30 },
    },
    [23424] = {  -- Fel Iron Ore
        { 23077, 0.19 }, { 21929, 0.19 }, { 23112, 0.19 }, { 23079, 0.19 }, { 23117, 0.19 }, { 23107, 0.19 },
        { 23436, 0.011 }, { 23439, 0.011 }, { 23440, 0.011 }, { 23437, 0.011 }, { 23438, 0.011 }, { 23441, 0.011 },
    },
    [23425] = {  -- Adamantite Ore
        { 24243, 1.00 },
        { 23077, 0.19 }, { 21929, 0.19 }, { 23112, 0.19 }, { 23079, 0.19 }, { 23117, 0.19 }, { 23107, 0.19 },
        { 23436, 0.03 }, { 23439, 0.03 }, { 23440, 0.03 }, { 23437, 0.03 }, { 23438, 0.03 }, { 23441, 0.03 },
    },
}

-- reverse: gemID -> { oreID, ... } (built once from PROSPECT, ores in a fixed order)
local ORE_ORDER = { 2770, 2771, 2772, 3858, 10620, 23424, 23425 }
local FROM_ORE = {}
for _, oreID in ipairs(ORE_ORDER) do
    for _, row in ipairs(PROSPECT[oreID]) do
        local gemID = row[1]
        FROM_ORE[gemID] = FROM_ORE[gemID] or {}
        FROM_ORE[gemID][#FROM_ORE[gemID] + 1] = oreID
    end
end

-- ---- tooltip helpers ------------------------------------------------------
local QUALITY_HEX = { [1] = "|cffffffff", [2] = "|cff1eff00", [3] = "|cff0070dd", [4] = "|cffa335ee" }
local function GemText(gemID)
    local g = GEM[gemID]
    local fallbackName, q = (g and g[1]) or ("item:" .. gemID), (g and g[2]) or 1
    local name = GetItemInfo(gemID) or fallbackName
    local qc = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q]
    local hex = (qc and qc.hex) or QUALITY_HEX[q] or "|cffffffff"
    local icon = select(5, GetItemInfoInstant(gemID))
    local iconTag = icon and ("|T" .. icon .. ":14|t ") or ""
    return iconTag .. hex .. name .. "|r"
end

-- one line per gem, highest chance first: "50%  [icon] Malachite"
local function BuildLines(rows)
    local sorted = {}
    for i, row in ipairs(rows) do sorted[i] = row end
    table.sort(sorted, function(a, b) return a[2] > b[2] end)
    local lines = {}
    for _, row in ipairs(sorted) do
        lines[#lines + 1] = string.format("%g%%  %s", row[2] * 100, GemText(row[1]))
    end
    return lines
end

-- ---- the hook -------------------------------------------------------------
local function Enabled()
    if CheapBidsDB == nil then return true end
    return CheapBidsDB.prospectTip ~= false
end

local function OnSetItem(tip)
    if not Enabled() then return end
    if tip.cheapBidsPRShown then return end
    local _, link = tip:GetItem()
    if not link then return end
    local itemID = tonumber(string.match(link, "item:(%d+)"))
    if not itemID then return end
    local rows = PROSPECT[itemID]
    if rows then
        tip.cheapBidsPRShown = true
        tip:AddLine("Prospects into (per 5 ore):", 0.6, 0.9, 0.6)
        for _, line in ipairs(BuildLines(rows)) do tip:AddLine("  " .. line) end
        tip:Show()
        return
    end
    local ores = FROM_ORE[itemID]                 -- reverse: this is a gem
    if ores then
        tip.cheapBidsPRShown = true
        local names = {}
        for _, oreID in ipairs(ores) do names[#names + 1] = ORE_NAME[oreID] or ("item:" .. oreID) end
        tip:AddLine("Prospected from: " .. table.concat(names, ", "), 0.6, 0.9, 0.6, true)
        tip:Show()
    end
end

local function HookTip(tip)
    if tip and tip.HookScript then
        tip:HookScript("OnTooltipSetItem", OnSetItem)
        tip:HookScript("OnTooltipCleared", function(t) t.cheapBidsPRShown = nil end)
    end
end
HookTip(GameTooltip)
HookTip(ItemRefTooltip)
HookTip(ShoppingTooltip1)
HookTip(ShoppingTooltip2)

-- ---- /cbpr : toggle (persisted, applies immediately) -----------------------
SLASH_CHEAPBIDSPR1 = "/cbpr"
SlashCmdList["CHEAPBIDSPR"] = function()
    CheapBidsDB = CheapBidsDB or {}
    CheapBidsDB.prospectTip = not (CheapBidsDB.prospectTip ~= false)
    local on = CheapBidsDB.prospectTip ~= false
    print("|cff33ff99CheapBids Prospect|r: " .. (on and "ON" or "OFF"))
end

-- ---- test hook ------------------------------------------------------------
if CheapBidsTest then
    CheapBidsTest.PR = {
        OnSetItem = OnSetItem, BuildLines = BuildLines,
        PROSPECT = PROSPECT, FROM_ORE = FROM_ORE, GEM = GEM, ORE_NAME = ORE_NAME,
    }
end
