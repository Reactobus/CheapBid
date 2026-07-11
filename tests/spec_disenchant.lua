-- Unit tests for CheapBids_Disenchant (loaded via the CheapBidsTest.DE hook).
-- Run with: node tests/run.js  (run.js loads this after the main spec)

local DE = CheapBidsTest.DE

local passed, failed = 0, 0
local function ok(cond, msg)
    if cond then passed = passed + 1
    else failed = failed + 1; print("  FAIL: " .. tostring(msg)) end
end
local function eq(a, b, msg)
    ok(a == b, (msg or "") .. "  (got " .. tostring(a) .. ", want " .. tostring(b) .. ")")
end

-- scripted items: [itemID] = { name, quality, ilvl, equipLoc }
local ITEMS = {
    [5000] = { "Green Chest",   2, 20,  "INVTYPE_CHEST" },
    [5001] = { "Green Sword",   2, 20,  "INVTYPE_WEAPON" },
    [5002] = { "Blue Sword",    3, 60,  "INVTYPE_WEAPON" },
    [5003] = { "TBC Epic Helm", 4, 115, "INVTYPE_HEAD" },
    [5004] = { "White Shirt",   1, 20,  "INVTYPE_CHEST" },
    [5005] = { "Green Potion",  2, 20,  "" },              -- not equippable
    [3456] = { "Dog Whistle",   2, 20,  "INVTYPE_TRINKET" }, -- NON_DE listed
}
function GetItemInfo(arg)
    local id = tonumber(arg) or tonumber(string.match(tostring(arg), "item:(%d+)"))
    local it = id and ITEMS[id]
    if not it then return nil end   -- reagents stay uncached -> fallback names
    return it[1], "|Hitem:" .. id .. "|h[" .. it[1] .. "]|h", it[2], it[3],
           1, "class", "subclass", 20, it[4]
end

local function link(id) return "|Hitem:" .. id .. ":0|h[x]|h" end
local function fakeTip(id)
    local t = { lines = {} }
    function t:GetItem() return "x", link(id) end
    function t:AddLine(text) self.lines[#self.lines + 1] = text end
    function t:Show() end
    return t
end

-- ===== RoundupLevel =====
local B = { 15, 20, 25 }
eq(DE.RoundupLevel(1, B),   15,  "roundup: below first bound")
eq(DE.RoundupLevel(16, B),  20,  "roundup: between bounds")
eq(DE.RoundupLevel(25, B),  25,  "roundup: exact last bound")
eq(DE.RoundupLevel(26, B),  nil, "roundup: above last bound -> nil")

-- ===== Lookup =====
local rows = DE.Lookup(2, DE.ARMOR, 10)          -- uncommon armor ilvl 10 -> bracket 15
ok(rows and rows[1][1] == "STRANGE" and rows[1][2] == 0.80, "uncommon armor: dust 80%")
rows = DE.Lookup(2, DE.WEAPON, 10)               -- same bracket, weapon: essence-heavy
ok(rows and rows[2][1] == "LMAGIC" and rows[2][2] == 0.80, "uncommon weapon: essence 80%")
rows = DE.Lookup(3, DE.WEAPON, 60)               -- rare weapon falls back to armor table
ok(rows and rows[1][1] == "LBRILLIANT" and rows[1][2] == 1.00, "rare weapon: armor fallback, LBRILLIANT")
rows = DE.Lookup(4, DE.ARMOR, 95)                -- epic 95-99 -> Void x1.0
ok(rows and rows[1][1] == "VOID" and rows[1][3] == 1.0, "epic 95: void crystal x1")
rows = DE.Lookup(4, DE.ARMOR, 115)               -- epic 100-164 -> Void x1.5
ok(rows and rows[1][1] == "VOID" and rows[1][3] == 1.5, "epic 115: void crystal x1.5")
eq(DE.Lookup(1, DE.ARMOR, 20), nil, "common quality -> nil")
eq(DE.Lookup(5, DE.ARMOR, 80), nil, "legendary -> nil")
eq(DE.Lookup(2, DE.ARMOR, 200), nil, "ilvl above table -> nil")
eq(DE.Lookup(2, nil, 20), nil, "no slot class -> nil")

-- ===== BuildLines: sorted by chance, formatted =====
local lines = DE.BuildLines(DE.Lookup(2, DE.ARMOR, 20))   -- 75/20/5 bracket
eq(#lines, 3, "lines: one per reagent")
ok(string.find(lines[1], "^75%%"), "lines: 75% first")
ok(string.find(lines[1], "Strange Dust"), "lines: fallback reagent name used")
ok(string.find(lines[3], "^5%%"), "lines: 5% last")
ok(string.find(lines[3], "x1"), "lines: avg quantity printed")

-- ===== OnSetItem: full tooltip path =====
CheapBidsDB = {}                                  -- default = enabled
local tip = fakeTip(5000)                         -- green armor -> header + 3 rows
DE.OnSetItem(tip)
eq(#tip.lines, 4, "tooltip: header + 3 reagent lines")
eq(tip.lines[1], "Disenchants into:", "tooltip: header text")
ok(tip.cheapBidsDEShown, "tooltip: guard flag set")
DE.OnSetItem(tip)                                 -- re-fire must not duplicate
eq(#tip.lines, 4, "tooltip: no duplicate block on re-fire")

tip = fakeTip(5004); DE.OnSetItem(tip)
eq(#tip.lines, 0, "tooltip: white item ignored")
tip = fakeTip(5005); DE.OnSetItem(tip)
eq(#tip.lines, 0, "tooltip: non-equippable ignored")
tip = fakeTip(3456); DE.OnSetItem(tip)
eq(#tip.lines, 0, "tooltip: NON_DE exception ignored")
tip = fakeTip(9999); DE.OnSetItem(tip)
eq(#tip.lines, 0, "tooltip: uncached item ignored")

CheapBidsDB.disenchantTip = false
tip = fakeTip(5000); DE.OnSetItem(tip)
eq(#tip.lines, 0, "tooltip: /cbde off -> nothing")
CheapBidsDB.disenchantTip = true

-- ===== reverse: hover a reagent -> "Disenchanted from: gear ilvl X-Y" =====
CheapBidsDB.disenchantTip = true
tip = fakeTip(10940); DE.OnSetItem(tip)                    -- Strange Dust -> ilvl 1-25
eq(#tip.lines, 1, "reverse: reagent gets one source line")
ok(tip.lines[1]:find("Disenchanted from"), "reverse: source label")
ok(tip.lines[1]:find("1%-25"), "reverse: Strange Dust from ilvl 1-25")
eq(DE.REVERSE_DE[22450][2], 164, "reverse: Void Crystal upper bound 164")
tip = fakeTip(5000); DE.OnSetItem(tip)                    -- a gear item still shows the forward block
ok(tip.lines[1] == "Disenchants into:", "reverse: gear still shows the forward DE block")

-- ===== Disenchant price: EV of the reagents at Auc-min market prices =====
local function fakeTipD(id)
    local t = { dlines = {} }
    function t:GetItem() return "x", link(id) end
    function t:AddDoubleLine(l, r) self.dlines[#self.dlines + 1] = { l = l, r = r } end
    function t:Show() end
    return t
end
-- synthetic rows, hand-checkable: 0.5*2*100 + 0.5*1*200 = 200
CheapBidsTest.set("priceDB", { [10940] = 100, [10938] = 200 })   -- Strange Dust 1s, L.Magic 2s
eq(DE.DEValue({ { "STRANGE", 0.5, 2.0 }, { "LMAGIC", 0.5, 1.0 } }), 200, "EV: sum of chance x avg x unit")
CheapBidsTest.set("priceDB", { [10940] = 100 })                  -- only the dust is priced
eq(DE.DEValue({ { "STRANGE", 0.5, 2.0 }, { "LMAGIC", 0.5, 1.0 } }), 100, "EV: unpriced reagent contributes 0")
CheapBidsTest.set("priceDB", {})
eq(DE.DEValue({ { "STRANGE", 0.5, 2.0 } }), nil, "EV: nothing priced -> nil (no row)")

-- full row path on the green chest (bracket 20): expected = sum over the REAL table rows
local PRICES = { [10940] = 100, [10938] = 200, [10978] = 1000 }  -- dust / essence / shard
CheapBidsTest.set("priceDB", PRICES)
local expEV = 0
for _, row in ipairs(DE.Lookup(2, DE.ARMOR, 20)) do
    local rg = DE.R[row[1]]
    local p = PRICES[rg[1]]
    if p then expEV = expEV + row[2] * row[3] * p end
end
expEV = math.floor(expEV + 0.5)
eq(DE.DEValue(DE.Lookup(2, DE.ARMOR, 20)), expEV, "EV: matches the real bracket-20 table")
local tipP = fakeTipD(5000)
DE.PriceRow(tipP)
eq(#tipP.dlines, 1, "price row: one double line on DE-able gear")
eq(tipP.dlines[1].l, "Disenchant price", "price row: capitalized label")
DE.PriceRow(tipP)
eq(#tipP.dlines, 1, "price row: guard prevents a duplicate")
local tipC = fakeTipD(5004)                       -- common shirt: not disenchantable
DE.PriceRow(tipC)
eq(#tipC.dlines, 0, "price row: common item shows nothing")
CheapBidsTest.set("priceDB", {})
local tipN = fakeTipD(5000)
DE.PriceRow(tipN)
eq(#tipN.dlines, 0, "price row: no scan data -> no row")

-- ===== CheapBidsPublic.DisenchantValue: the bridge the main addon's Dis. loot uses =====
CheapBidsTest.set("priceDB", PRICES)
local dv, known = CheapBidsPublic.DisenchantValue(5000)
eq(dv, expEV, "bridge: green chest EV matches the bracket table")
eq(known, true, "bridge: cached gear -> final verdict")
dv, known = CheapBidsPublic.DisenchantValue(9999)
eq(dv, nil, "bridge: uncached item -> no value")
eq(known, false, "bridge: uncached item -> known=false (retry later)")
dv, known = CheapBidsPublic.DisenchantValue(5004)
eq(dv, nil, "bridge: common shirt -> no value")
eq(known, true, "bridge: common shirt -> final verdict")
dv, known = CheapBidsPublic.DisenchantValue(3456)
eq(dv, nil, "bridge: NON_DE exception -> no value")
eq(known, true, "bridge: NON_DE -> final verdict")
CheapBidsTest.set("priceDB", {})

-- ===== /cbde toggle =====
SlashCmdList["CHEAPBIDSDE"]()
eq(CheapBidsDB.disenchantTip, false, "/cbde: ON -> OFF")
SlashCmdList["CHEAPBIDSDE"]()
eq(CheapBidsDB.disenchantTip, true, "/cbde: OFF -> ON")

print(string.format("RESULT (disenchant): %d passed, %d failed", passed, failed))
TEST_FAILED = (TEST_FAILED or 0) + failed
