-- Unit tests for CheapBids_Shopping (loaded via the CheapBidsTest.SHOP hook).
local S = CheapBidsTest.SHOP
local passed, failed = 0, 0
local function ok(cond, msg) if cond then passed = passed + 1 else failed = failed + 1; print("  FAIL: " .. tostring(msg)) end end
local function eq(a, b, msg) ok(a == b, (msg or "") .. "  (got " .. tostring(a) .. ", want " .. tostring(b) .. ")") end

CheapBidsDB = { priceDB = { [2770] = 500 } }

-- ===== list model: add / dedupe / fill-id / remove =====
local list = {}
ok(S.AddEntry(list, "Copper Ore", 2770), "add: new entry accepted")
eq(#list, 1, "add: list size 1")
ok(not S.AddEntry(list, "copper ore", 2770), "add: dedupe is case-insensitive")
eq(#list, 1, "add: no duplicate row")
ok(S.AddEntry(list, "Tin Ore", nil), "add: second entry without id")
eq(#list, 2, "add: list size 2")
S.AddEntry(list, "Tin Ore", 2771)
eq(list[2].itemID, 2771, "add: re-adding fills a missing itemID")
ok(not S.AddEntry(list, "", 1), "add: empty name rejected")

-- ===== market price from the shared price DB =====
eq(S.MarketPrice({ itemID = 2770 }), 500, "market: price from priceDB")
eq(S.MarketPrice({ itemID = 9999 }), nil, "market: unknown item -> nil")
eq(S.MarketPrice({ name = "x" }), nil, "market: no itemID -> nil")

-- ===== remove =====
ok(S.RemoveAt(list, 1), "remove: valid index")
eq(#list, 1, "remove: size 1 after remove")
eq(list[1].name, "Tin Ore", "remove: correct row left")
ok(not S.RemoveAt(list, 9), "remove: out-of-range -> false")

-- ===== money text =====
eq(S.Money(0), "-", "money: zero -> dash")
ok(S.Money(500):find("5"), "money: 5s shows 5")

print(string.format("RESULT (shopping): %d passed, %d failed", passed, failed))
TEST_FAILED = (TEST_FAILED or 0) + failed
