-- Unit tests for CheapBids_Selling (loaded via the CheapBidsTest.SELL hook).
local SE = CheapBidsTest.SELL
local passed, failed = 0, 0
local function ok(cond, msg) if cond then passed = passed + 1 else failed = failed + 1; print("  FAIL: " .. tostring(msg)) end end
local function eq(a, b, msg) ok(a == b, (msg or "") .. "  (got " .. tostring(a) .. ", want " .. tostring(b) .. ")") end

CheapBidsDB = { priceDB = { [100] = 10000 }, undercutCopper = 1 }

-- ===== market min + undercut suggestion =====
eq(SE.MarketUnit(100), 10000, "market: per-unit from priceDB")
eq(SE.MarketUnit(999), nil, "market: unknown -> nil")
eq(SE.Undercut(), 1, "undercut: default 1c")
eq(SE.SuggestUnit(100), 9999, "suggest: market - 1c")

-- tuned undercut
CheapBidsDB.undercutCopper = 50
eq(SE.Undercut(), 50, "undercut: reads tuned value")
eq(SE.SuggestUnit(100), 9950, "suggest: market - 50c")

-- floor at 1c when undercut would go below
CheapBidsDB.priceDB[200] = 10
eq(SE.SuggestUnit(200), 1, "suggest: never below 1c")

-- unpriced item
eq(SE.SuggestUnit(999), nil, "suggest: unpriced -> nil")

-- negative/invalid undercut falls back to 1
CheapBidsDB.undercutCopper = -5
eq(SE.Undercut(), 1, "undercut: invalid -> 1c")

-- money
eq(SE.Money(0), "-", "money: zero -> dash")
ok(SE.Money(10000):find("1"), "money: 1g")

print(string.format("RESULT (selling): %d passed, %d failed", passed, failed))
TEST_FAILED = (TEST_FAILED or 0) + failed
