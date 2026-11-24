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

-- ===== modern client (WoW Forever): item-info aliases fall back to C_Item =====
do
    local gii, giiI, savedCItem = GetItemInfo, GetItemInfoInstant, C_Item
    GetItemInfo, GetItemInfoInstant = nil, nil
    C_Item = {
        GetItemInfo = function(x) return gii(x) end,
        GetItemInfoInstant = function(id) return id, nil, nil, nil, "ctex" end,
    }
    CheapBidsTest.set("priceDB", PRICES)
    local v, k = CheapBidsPublic.DisenchantValue(5000)
    eq(v, expEV, "C_Item: bridge EV via C_Item.GetItemInfo")
    eq(k, true, "C_Item: bridge final verdict via C_Item")
    ok(DE.BuildLines(DE.Lookup(2, DE.ARMOR, 20))[1]:find("|Tctex:14|t", 1, true), "C_Item: icon via C_Item.GetItemInfoInstant")
    C_Item = nil
    eq(DE.ItemInfo(5000), nil, "no item API at all -> nil, no error")
    GetItemInfo, GetItemInfoInstant, C_Item = gii, giiI, savedCItem
    CheapBidsTest.set("priceDB", {})
end

-- ===== modern client: tooltip hook registration choice =====
-- fake tooltip frame: HookScript THROWS for an unsupported script, like the real client
local function fakeFrame(id, scripts)
    local f = { id = id, lines = {}, dlines = {}, handlers = {} }
    function f:HasScript(s) return scripts[s] == true end
    function f:HookScript(s, fn)
        if not scripts[s] then error(s .. ": no such script") end
        self.handlers[s] = fn
    end
    function f:GetItem() return "x", link(self.id) end
    function f:AddLine(text) self.lines[#self.lines + 1] = text end
    function f:AddDoubleLine(l) self.dlines[#self.dlines + 1] = l end
    function f:Show() end
    function f:SetBagItem() end
    return f
end
local function fakeTDP()
    local t = { calls = {} }
    function t.AddTooltipPostCall(kind, fn) t.calls[#t.calls + 1] = { kind = kind, fn = fn } end
    return t
end
do
    local savedEnum = Enum
    Enum = { TooltipDataType = { Item = 0 } }
    CheapBidsDB.disenchantTip = true
    CheapBidsTest.set("priceDB", PRICES)

    -- TBC tooltip: legacy script hooked, TooltipDataProcessor ignored even if present
    local legacy = fakeFrame(5000, { OnTooltipSetItem = true, OnTooltipCleared = true })
    eq(DE.HookTip(legacy), true, "legacy: HookTip hooks OnTooltipSetItem")
    ok(legacy.handlers.OnTooltipSetItem == DE.OnSetItem, "legacy: OnSetItem is the handler")
    ok(legacy.handlers.OnTooltipCleared ~= nil, "legacy: OnTooltipCleared hooked")
    local tdp = fakeTDP()
    eq(DE.InstallModernHooks(tdp, legacy), nil, "legacy: no post-call registered")
    eq(#tdp.calls, 0, "legacy: TooltipDataProcessor untouched")

    -- modern tooltip: no OnTooltipSetItem -> HookTip must not call HookScript (would throw)
    local modern = fakeFrame(5000, { OnTooltipCleared = true })
    local okHook, res = pcall(DE.HookTip, modern)
    ok(okHook and res == false, "modern: HookTip skips (no throw)")
    tdp = fakeTDP()
    local set = DE.InstallModernHooks(tdp, nil, modern, legacy)   -- nil tooltip tolerated
    ok(set and set[modern] and not set[legacy], "modern: only the modern tooltip accepted")
    eq(#tdp.calls, 1, "modern: one post-call registered")
    eq(tdp.calls[1].kind, 0, "modern: registered for Enum.TooltipDataType.Item")
    local post = tdp.calls[1].fn
    post(modern)
    eq(#modern.lines, 4, "modern: forward block via post-call")
    eq(#modern.dlines, 1, "modern: price row via post-call")
    post(modern)
    eq(#modern.lines, 4, "modern: no duplicate block on re-fire")
    eq(#modern.dlines, 1, "modern: no duplicate price row on re-fire")
    modern.handlers.OnTooltipCleared(modern)
    ok(not modern.cheapBidsDEShown and not modern.cheapBidsDEValueShown, "modern: OnTooltipCleared resets flags")
    post(modern)
    eq(#modern.lines, 8, "modern: block shows again after a clear")

    local other = fakeFrame(5000, { OnTooltipCleared = true })
    post(other)
    eq(#other.lines, 0, "modern: foreign tooltip ignored")

    local secret = fakeFrame(5000, { OnTooltipCleared = true })
    function secret:GetItem() error("attempt to use a secret value") end
    local tdp2 = fakeTDP()
    DE.InstallModernHooks(tdp2, secret)
    ok(pcall(tdp2.calls[1].fn, secret), "modern: post-call swallows a secret-value error")

    eq(DE.InstallModernHooks(fakeTDP(), fakeFrame(5000, {})), nil, "modern: no OnTooltipCleared -> not accepted")
    Enum = nil
    eq(DE.InstallModernHooks(fakeTDP(), fakeFrame(5000, { OnTooltipCleared = true })), nil, "no Enum -> nothing registered")
    Enum = savedEnum

    -- Set* price post-hooks: bare PriceRow on TBC, pcall-wrapped on modern
    local savedHSF, hooked = hooksecurefunc, {}
    hooksecurefunc = function(t, m, fn) hooked[#hooked + 1] = { t = t, m = m, fn = fn } end
    DE.HookPriceRow(legacy)
    DE.HookPriceRow(secret)
    hooksecurefunc = savedHSF
    eq(#hooked, 2, "price hooks: one Set* method per tooltip")
    ok(hooked[1].m == "SetBagItem" and hooked[1].fn == DE.PriceRow, "price hooks: TBC gets the bare PriceRow")
    ok(hooked[2].fn ~= DE.PriceRow and pcall(hooked[2].fn, secret), "price hooks: modern wrapper swallows errors")
    CheapBidsTest.set("priceDB", {})
end

-- ===== /cbde toggle =====
SlashCmdList["CHEAPBIDSDE"]()
eq(CheapBidsDB.disenchantTip, false, "/cbde: ON -> OFF")
SlashCmdList["CHEAPBIDSDE"]()
eq(CheapBidsDB.disenchantTip, true, "/cbde: OFF -> ON")

print(string.format("RESULT (disenchant): %d passed, %d failed", passed, failed))
TEST_FAILED = (TEST_FAILED or 0) + failed
