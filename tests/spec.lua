-- Unit tests for CheapBids internal logic (loaded via the CheapBidsTest hook).
-- Run with: node tests/run.js

local fn        = CheapBidsTest.fn
local set, get  = CheapBidsTest.set, CheapBidsTest.get

local passed, failed = 0, 0
local function ok(cond, msg)
    if cond then passed = passed + 1
    else failed = failed + 1; print("  FAIL: " .. tostring(msg)) end
end
local function eq(a, b, msg)
    ok(a == b, (msg or "") .. "  (got " .. tostring(a) .. ", want " .. tostring(b) .. ")")
end

local OUTBID_FILTER = { bidMin = 1, bidMax = 99, buyMin = nil, buyMax = nil,
                        quality = nil, times = { [1] = true, [2] = true, [3] = true, [4] = true } }

-- helper: build a bidder list and (re)read it into myBids
local function setBidder(list) MOCK.auctions.bidder = list end
local function lot(name, id, high, tl, owner)
    return { name = name, itemID = id, cnt = 1, buyout = 100, minBid = 10, minInc = 1,
             bidAmt = 20, high = high, timeLeft = tl, owner = owner or ("s" .. id) }
end

-- ===== CalcBid =====
eq(fn.CalcBid(100, 5, 0),  100, "CalcBid: no current bid -> minBid")
eq(fn.CalcBid(100, 5, 80), 85,  "CalcBid: current bid -> bid + increment")

-- ===== PassesFilter / TimeShown =====
set("filter", OUTBID_FILTER)
ok(fn.PassesFilter(50, 0)  == true,  "PassesFilter: 50c inside [1,99]")
ok(fn.PassesFilter(150, 0) == false, "PassesFilter: 150c above max 99")
ok(fn.PassesFilter(0, 0)   == false, "PassesFilter: 0c below min 1")
eq(fn.TimeShown(1), true, "TimeShown: bucket 1 enabled")
set("filter", { bidMin = 1, bidMax = 99, quality = nil, times = { [1] = false, [2] = true, [3] = true, [4] = true } })
eq(fn.TimeShown(1), false, "TimeShown: bucket 1 disabled")
set("filter", OUTBID_FILTER)

-- ===== my-bids: order (reds on top, shortest time first) + red auto-target =====
set("viewMode", "bids"); set("alwaysRedTarget", true); set("autoScanBids", true)
set("bidsDismissed", {}); set("selectedItem", nil)
setBidder({
    lot("A", 1, false, 4),   -- red, >12h
    lot("B", 2, true,  1),   -- green, <30m
    lot("C", 3, false, 1),   -- red, <30m
    lot("D", 4, false, 2),   -- red, 30m-2h
})
fn.ReadMyBids()
local mb = get("myBids")
eq(#mb, 4, "ReadMyBids: count")
eq(mb[1].name, "C", "order: red <30m on top")
eq(mb[2].name, "D", "order: red 30m-2h next")
eq(mb[3].name, "A", "order: red >12h next")
eq(mb[4].name, "B", "order: green last")
ok(get("selectedItem") and get("selectedItem").name == "C", "alwaysRedTarget: top red selected")

-- ===== dismissed lots stay hidden across refresh =====
local dis = {}; dis["3:1:100"] = true             -- C's key (itemID:cnt:buyout, no owner)
set("bidsDismissed", dis)
fn.ReadMyBids()
mb = get("myBids")
eq(#mb, 3, "dismissed: C skipped")
local seenC = false
for _, it in ipairs(mb) do if it.name == "C" then seenC = true end end
ok(not seenC, "dismissed: C absent from list")
set("bidsDismissed", {})

-- ===== selection preserved by _key across refresh =====
fn.ReadMyBids()                                   -- C,D,A,B again; selected C
set("selectedItem", get("myBids")[2])             -- D
fn.ReadMyBids()
ok(get("selectedItem") and get("selectedItem").name == "D", "selection preserved across refresh")

-- ===== RebidBidder: bid a red -> PlaceAuctionBid(bidder), remove, advance to next red =====
set("selectedItem", get("myBids")[1])             -- C (top red)
MOCK.bids = {}; MOCK.gt = MOCK.gt + 1
fn.RebidBidder(nil)
eq(#MOCK.bids, 1, "RebidBidder: one bid placed")
eq(MOCK.bids[1].listType, "bidder", "RebidBidder: bids the bidder list")
mb = get("myBids")
eq(#mb, 3, "RebidBidder: bid row removed")
ok(get("selectedItem") and get("selectedItem").name == "D", "RebidBidder: advanced to next red D")

-- ===== RebidBidder: alwaysRedTarget ON + green selected -> bids a RED, not the green =====
setBidder({ lot("C", 3, false, 1), lot("B", 2, true, 1) })   -- one red (C), one green (B)
fn.ReadMyBids()
set("selectedItem", get("myBids")[2])             -- B (green)
MOCK.bids = {}; MOCK.gt = MOCK.gt + 1
fn.RebidBidder(nil)
eq(#MOCK.bids, 1, "green selected + alwaysRedTarget: still bids a red")
mb = get("myBids")
local greenStill = false
for _, it in ipairs(mb) do if it.name == "B" then greenStill = true end end
ok(greenStill, "green B not consumed when a red exists")

-- ===== RebidBidder: alwaysRedTarget OFF + green selected -> no bid, no remove =====
set("alwaysRedTarget", false)
setBidder({ lot("B", 2, true, 1) })               -- only a green
fn.ReadMyBids()
set("selectedItem", get("myBids")[1])             -- B green
MOCK.bids = {}; MOCK.gt = MOCK.gt + 1
fn.RebidBidder(nil)
eq(#MOCK.bids, 0, "green + alwaysRedTarget OFF: no bid placed")
eq(#get("myBids"), 1, "green not removed on a no-op bid")
set("alwaysRedTarget", true)

-- ===== RejectBidderBid: internal auction error keeps the lot (restores from bidder list) =====
set("viewMode", "bids"); set("alwaysRedTarget", true); set("bidsDismissed", {})
setBidder({ lot("C", 3, false, 1) })              -- a still-outbid lot in the live bidder list
fn.ReadMyBids()
set("selectedItem", get("myBids")[1])
MOCK.bids = {}; MOCK.gt = MOCK.gt + 5
fn.RebidBidder(nil)
eq(#MOCK.bids, 1, "RebidBidder: bid placed")
eq(#get("myBids"), 0, "RebidBidder: row optimistically removed")
fn.RejectBidderBid()
eq(#get("myBids"), 1, "RejectBidderBid: still-outbid lot restored (not lost on error)")

-- ===== DismissRow (my-bids): marks dismissed + removes =====
set("viewMode", "bids"); set("bidsDismissed", {})
setBidder({ lot("C", 3, false, 1), lot("D", 4, false, 2) })
fn.ReadMyBids()
local target = get("myBids")[1]
fn.DismissRow(target)
ok(get("bidsDismissed")[target._key] == true, "DismissRow(bids): key marked dismissed")
eq(#get("myBids"), 1, "DismissRow(bids): row removed")

-- ===== >5g re-bid needs confirmation: no immediate bid, popup commit places it =====
set("viewMode", "bids"); set("alwaysRedTarget", true); set("bidsDismissed", {})
-- a red lot whose required re-bid is > 5g (bidAmt 6g + 1 inc = 6g 1c)
setBidder({ { name = "BIG", itemID = 99, cnt = 1, buyout = 100, minBid = 10, minInc = 1,
             bidAmt = 1500000, high = false, timeLeft = 1, owner = "s99" } })
fn.ReadMyBids()
set("selectedItem", get("myBids")[1])
MOCK.bids = {}; MOCK.popups = {}; MOCK.gt = MOCK.gt + 5
fn.RebidBidder(nil)
eq(#MOCK.bids, 0, ">5g re-bid: NOT placed immediately")
eq(#MOCK.popups, 1, ">5g re-bid: confirmation popup shown")
local p = MOCK.popups[1]
if p and p.data and p.data.commit then p.data.commit() end   -- player presses Accept
eq(#MOCK.bids, 1, ">5g re-bid: placed after confirm")
eq(MOCK.bids[1] and MOCK.bids[1].amount, 1500001, ">5g re-bid: bids the full required amount")

-- ===== <=5g re-bid still places immediately (no popup) =====
setBidder({ lot("C", 3, false, 1) })            -- eff = 20 + 1 = 21c, well under 5g
fn.ReadMyBids()
set("selectedItem", get("myBids")[1])
MOCK.bids = {}; MOCK.popups = {}; MOCK.gt = MOCK.gt + 5
fn.RebidBidder(nil)
eq(#MOCK.popups, 0, "small re-bid: no confirmation popup")
eq(#MOCK.bids, 1, "small re-bid: placed immediately")

-- ===== auto-target NEVER lands on a >5g lot (my bids): FirstRed + alwaysRedTarget =====
set("viewMode", "bids"); set("alwaysRedTarget", true); set("bidsDismissed", {}); set("selectedItem", nil)
setBidder({
    { name = "BIGRED",   itemID = 70, cnt = 1, buyout = 100, minBid = 10, minInc = 1, bidAmt = 1500000, high = false, timeLeft = 1, owner = "s70" }, -- red <30m, >5g
    { name = "SMALLRED", itemID = 71, cnt = 1, buyout = 100, minBid = 10, minInc = 1, bidAmt = 20,    high = false, timeLeft = 2, owner = "s71" }, -- red 30m-2h, cheap
})
fn.ReadMyBids()
ok(fn.FirstRed() and fn.FirstRed().name == "SMALLRED", "FirstRed: skips the >5g red, returns the cheap red")
ok(get("selectedItem") and get("selectedItem").name == "SMALLRED", "alwaysRedTarget: auto-select skips the >5g red")

-- ===== all reds >5g: nothing auto-targeted; manual pick still goes through confirm =====
set("selectedItem", nil)
setBidder({ { name = "BIG1", itemID = 72, cnt = 1, buyout = 100, minBid = 10, minInc = 1, bidAmt = 1500000, high = false, timeLeft = 1, owner = "s72" } })
fn.ReadMyBids()
ok(fn.FirstRed() == nil, "FirstRed: nil when every red is >5g (none auto-targetable)")
ok(get("selectedItem") == nil, "alwaysRedTarget: no auto-select when all reds are >5g")
set("selectedItem", get("myBids")[1])             -- manual pick of the big red
MOCK.bids = {}; MOCK.popups = {}; MOCK.gt = MOCK.gt + 5
fn.RebidBidder(nil)
eq(#MOCK.bids, 0, "manual >5g pick: not placed immediately")
eq(#MOCK.popups, 1, "manual >5g pick: confirmation popup shown")

-- ===== SCAN view: a >5g bid asks to confirm, never auto-places (regression: 7g) =====
set("viewMode", "scan")
set("filter", { bidMin = 1, bidMax = nil, buyMin = nil, buyMax = nil, quality = nil,
                times = { [1] = true, [2] = true, [3] = true, [4] = true } })
-- live snapshot lot whose effective bid is 7g; cheapItems entry points at idx 1
MOCK.auctions.list = { { name = "GOLD7", itemID = 200, cnt = 1, buyout = 0, minBid = 1500000, minInc = 1, bidAmt = 0, high = false } }
local scanItem = { name = "GOLD7", itemID = 200, cnt = 1, buyout = 0, bid = 1500000, idx = 1 }
set("cheapItems", { scanItem })
set("selectedItem", scanItem)
MOCK.bids = {}; MOCK.popups = {}; MOCK.gt = MOCK.gt + 5
fn.BidItem(scanItem)
eq(#MOCK.bids, 0, "scan >5g: NOT placed immediately (no money spent)")
eq(#MOCK.popups, 1, "scan >5g: confirmation popup shown")
local sp = MOCK.popups[1]
if sp and sp.data and sp.data.commit then sp.data.commit() end   -- player presses Accept
eq(#MOCK.bids, 1, "scan >5g: placed only after confirm")
eq(MOCK.bids[1] and MOCK.bids[1].listType, "list", "scan >5g: bids the live snapshot list")
eq(MOCK.bids[1] and MOCK.bids[1].amount, 1500000, "scan >5g: amount = 7g")

-- ===== SCAN view: a cheap bid still places immediately (no popup) =====
MOCK.auctions.list = { { name = "CHEAP", itemID = 201, cnt = 1, buyout = 0, minBid = 50, minInc = 1, bidAmt = 0, high = false } }
local smallItem = { name = "CHEAP", itemID = 201, cnt = 1, buyout = 0, bid = 50, idx = 1 }
set("cheapItems", { smallItem })
set("selectedItem", smallItem)
MOCK.bids = {}; MOCK.popups = {}; MOCK.gt = MOCK.gt + 5
fn.BidItem(smallItem)
eq(#MOCK.popups, 0, "scan small: no confirmation popup")
eq(#MOCK.bids, 1, "scan small: placed immediately")

-- ===== Perfect sort: significance = buyout/bid, best steal (low bid, high buyout) on top =====
set("viewMode", "scan")
set("sortKey", "perfect"); set("sortAsc", false)
set("cheapItems", {
    { name = "mid",   bid = 10, buyout = 100 },   -- ratio 10
    { name = "steal", bid = 1,  buyout = 100 },   -- ratio 100 -> top
    { name = "poor",  bid = 50, buyout = 100 },   -- ratio 2
    { name = "nobuy", bid = 1,  buyout = 0   },   -- ratio 0   -> bottom
})
fn.SortItems()
local ps = fn.ActiveList()
eq(ps[1].name, "steal", "perfect: lowest bid + high buyout on top")
eq(ps[2].name, "mid",   "perfect: next best ratio")
eq(ps[3].name, "poor",  "perfect: higher bid sinks")
eq(ps[4].name, "nobuy", "perfect: no buyout sinks to bottom")

-- ===== Price protection OFF: >5g bids place immediately, no popup; >5g red targetable =====
set("priceProtect", false)
-- scan path: 7g bid places with no confirmation
set("viewMode", "scan")
set("filter", { bidMin = 1, bidMax = nil, buyMin = nil, buyMax = nil, quality = nil,
                times = { [1] = true, [2] = true, [3] = true, [4] = true } })
MOCK.auctions.list = { { name = "GOLD7", itemID = 200, cnt = 1, buyout = 0, minBid = 1500000, minInc = 1, bidAmt = 0, high = false } }
local bigItem = { name = "GOLD7", itemID = 200, cnt = 1, buyout = 0, bid = 1500000, idx = 1 }
set("cheapItems", { bigItem }); set("selectedItem", bigItem)
MOCK.bids = {}; MOCK.popups = {}; MOCK.gt = MOCK.gt + 5
fn.BidItem(bigItem)
eq(#MOCK.popups, 0, "protection OFF: >5g scan bid shows NO popup")
eq(#MOCK.bids, 1, "protection OFF: >5g scan bid placed immediately")
-- my-bids path: a >5g red is now auto-targetable
set("viewMode", "bids"); set("alwaysRedTarget", true); set("bidsDismissed", {})
setBidder({ { name = "BIGRED", itemID = 70, cnt = 1, buyout = 100, minBid = 10, minInc = 1, bidAmt = 1500000, high = false, timeLeft = 1, owner = "s70" } })
fn.ReadMyBids()
ok(fn.FirstRed() and fn.FirstRed().name == "BIGRED", "protection OFF: a >5g red IS auto-targetable")
set("priceProtect", true)   -- restore the default for any later tests

-- ===== market-based price protection (ProtectThreshold / IsBig / NeedsConfirm) =====
set("priceProtect", true); set("priceDB", {}); set("priceCount", {})
-- unpriced item -> flat 100g fallback
eq(fn.ProtectThreshold({ itemID = 700, cnt = 1 }), 100 * 10000, "protect: unpriced -> 100g fallback")
ok(fn.NeedsConfirm({ itemID = 700, cnt = 1 }, 101 * 10000) == true,  "protect: 101g on unpriced -> confirm")
ok(fn.NeedsConfirm({ itemID = 700, cnt = 1 }, 99 * 10000) == false,  "protect: 99g on unpriced -> no confirm")
-- priced with >=2 lots: ceiling = 70% of unit * stack
set("priceDB", { [800] = 10000 }); set("priceCount", { [800] = 3 })   -- 1g/unit, 3 lots -> reliable
eq(fn.ProtectThreshold({ itemID = 800, cnt = 2 }), 0.70 * 10000 * 2, "protect: 70% of unit*stack (2 items)")
ok(fn.NeedsConfirm({ itemID = 800, cnt = 1 }, 8000) == true,  "protect: 80c > 70c (70% of 1g) -> confirm")
ok(fn.NeedsConfirm({ itemID = 800, cnt = 1 }, 6000) == false, "protect: 60c < 70c -> no confirm")
ok(fn.IsBig({ itemID = 800, cnt = 1, bid = 8000 }) == true,   "protect: IsBig above market ceiling")
ok(fn.IsBig({ itemID = 800, cnt = 1, bid = 6000 }) == false,  "protect: not big below market ceiling")
-- priced but only ONE lot -> cannot estimate -> 100g fallback (not 70%)
set("priceDB", { [900] = 10000 }); set("priceCount", { [900] = 1 })
eq(fn.ProtectThreshold({ itemID = 900, cnt = 1 }), 100 * 10000, "protect: single lot -> 100g fallback, not 70%")
-- protection OFF -> never confirms, never big, whatever the amount
set("priceProtect", false)
ok(fn.NeedsConfirm({ itemID = 700, cnt = 1 }, 500 * 10000) == false, "protect OFF: never confirms")
ok(fn.IsBig({ itemID = 700, cnt = 1, bid = 500 * 10000 }) == false,  "protect OFF: never big")
set("priceProtect", true); set("priceDB", {}); set("priceCount", {})

-- ===== rarity sort: highest quality on top (descending) =====
set("viewMode", "scan")
set("sortKey", "rarity"); set("sortAsc", false)
set("cheapItems", {
    { name = "common", q = 1, bid = 1, buyout = 1 },
    { name = "epic",   q = 4, bid = 1, buyout = 1 },
    { name = "rare",   q = 3, bid = 1, buyout = 1 },
})
fn.SortItems()
local rs = fn.ActiveList()
eq(rs[1].name, "epic",   "rarity: epic on top (descending)")
eq(rs[2].name, "rare",   "rarity: rare in the middle")
eq(rs[3].name, "common", "rarity: common last")

-- ===== ItemLink: a real chat-insertable hyperlink (shift-click), or nil =====
local LNK = "|cffff0000|Hitem:555|h[Boom]|h|r"
eq(fn.ItemLink({ link = LNK }), LNK, "ItemLink: uses an existing it.link")
ok(fn.ItemLink({ itemID = 123 }) and fn.ItemLink({ itemID = 123 }):find("Hitem:123"),
   "ItemLink: resolves a link from itemID")
eq(fn.ItemLink({ name = "x" }), nil, "ItemLink: nil when only a name (no link/itemID)")

-- ===== Auc min price DB + Perfect sort + price tooltip =====
set("priceDB", {}); set("scanPriceDB", {})
MOCK.auctions.list = {
    { name = "A", itemID = 500, cnt = 1, buyout = 1000, minBid = 1, bidAmt = 0 },   -- unit 1000
    { name = "B", itemID = 500, cnt = 5, buyout = 2500, minBid = 1, bidAmt = 0 },   -- unit 500  (min)
    { name = "C", itemID = 500, cnt = 2, buyout = 3000, minBid = 1, bidAmt = 0 },   -- unit 1500
    { name = "D", itemID = 600, cnt = 1, buyout = 0,    minBid = 1, bidAmt = 0 },   -- no buyout -> skip
}
local pcache = {}
for i = 1, 4 do fn.ReadIndexInto(pcache, i, true) end
local pdb = get("scanPriceDB")
eq(pdb[500], 500, "priceDB: lowest per-unit buyout for item 500")
eq(pdb[600], nil, "priceDB: buyout=0 lot not recorded")
-- scan-only accumulation: a page read (no storeIdx) must NOT touch the market DB
set("scanPriceDB", {})
fn.ReadIndexInto({}, 1)
eq(next(get("scanPriceDB")), nil, "priceDB: page scan (no storeIdx) records nothing")

set("priceDB", pdb)
eq(fn.AucUnit({ itemID = 500 }), 500, "AucUnit: per-unit market price from DB")
eq(fn.AucUnit({ itemID = 999 }), nil, "AucUnit: unknown item -> nil")
local sig = fn.Significance({ itemID = 500, cnt = 3, bid = 100, buyout = 99999 })
ok(math.abs(sig - 15) < 1e-6, "Significance: market unit(500)*cnt(3)/bid(100) = 15, not lot buyout")
local sig2 = fn.Significance({ itemID = 999, cnt = 1, bid = 10, buyout = 200 })
ok(math.abs(sig2 - 20) < 1e-6, "Significance: unknown item falls back to lot buyout/bid")
eq(fn.Significance({ itemID = 500, cnt = 1, bid = 0, buyout = 100 }), 0, "Significance: zero bid -> 0")

-- price tooltip: Auctionator-style double line (gold label left, price right);
-- per-item by default, whole stack while SHIFT is held
local function priceTip(id, stack)
    local t = { lines = {} }
    function t:GetItem() return "x", "|Hitem:" .. id .. ":0|h[x]|h" end
    function t:AddDoubleLine(l, r) self.lines[#self.lines + 1] = { l = l, r = r } end
    function t:Show() end
    t.cbStack = stack
    return t
end
MOCK.shift = false
local tp = priceTip(500)
fn.PriceTip(tp)
eq(#tp.lines, 1, "priceTip: one double line for a known item")
eq(tp.lines[1].l, "Auc min", "priceTip: plain label without shift")
ok(tp.lines[1].r and tp.lines[1].r:find("5"), "priceTip: price on the right side (500c -> 5s)")
fn.PriceTip(tp)
eq(#tp.lines, 1, "priceTip: guard prevents a duplicate line")
local tpU = priceTip(999)
fn.PriceTip(tpU)
eq(#tpU.lines, 0, "priceTip: unknown item shows nothing")
MOCK.shift = true
local tpS = priceTip(500, 4)
fn.PriceTip(tpS)
eq(tpS.lines[1].l, "Auc min x4", "priceTip: SHIFT label carries the stack size")
ok(tpS.lines[1].r:find("20"), "priceTip: SHIFT prices the whole stack (500c x 4 = 20s)")
MOCK.shift = false
CheapBidsDB = CheapBidsDB or {}; CheapBidsDB.aucTip = false
local tpOff = priceTip(500)
fn.PriceTip(tpOff)
eq(#tpOff.lines, 0, "priceTip: options toggle off -> nothing")
CheapBidsDB.aucTip = nil

-- coin text: Auctionator's format (12px icons, space before icon, zero-padded under gold)
local ct = fn.AucCoinText(19125)                 -- 1g 91s 25c
ok(ct:find("UI-GoldIcon:12:12:0:0", 1, true), "coin: gold icon 12px, no offset")
ok(ct:find("1 |T", 1, true) == 1, "coin: space between number and icon")
ok(ct:find("91 |T", 1, true), "coin: silver kept two-digit")
ok(ct:find("25 |T", 1, true), "coin: copper kept two-digit")
local ct2 = fn.AucCoinText(10002)                -- 1g 00s 02c: zero-padding under gold
ok(ct2:find("00 |T", 1, true) and ct2:find("02 |T", 1, true), "coin: silver/copper zero-padded under gold")
local ct3 = fn.AucCoinText(25)                   -- bare copper: no padding, no silver segment
ok(ct3:find("25 |T", 1, true) == 1 and not ct3:find("SilverIcon", 1, true), "coin: bare copper stays unpadded, no silver")

-- ===== options panel: tunables validate + persist to CheapBidsDB, read back live =====
CheapBidsDB = {}
eq(fn.OptPct(), 70, "options: default protection cap 70%")
eq(fn.OptFallback(), 100, "options: default fallback 100g")
fn.SetPct(55); eq(CheapBidsDB.protectFraction, 0.55, "options: set cap 55% -> 0.55 fraction")
eq(fn.OptPct(), 55, "options: reads cap back as 55")
fn.SetPct(150); eq(CheapBidsDB.protectFraction, 1.0, "options: cap clamps to 100%")
fn.SetPct(0);   eq(CheapBidsDB.protectFraction, 0.01, "options: cap clamps up to 1%")
fn.SetPct("abc"); eq(CheapBidsDB.protectFraction, 0.01, "options: non-number cap ignored")
fn.SetFallback(250); eq(CheapBidsDB.protectFallback, 250 * 10000, "options: fallback gold -> copper")
-- and the protection math actually uses the tuned values
set("priceProtect", true); set("priceDB", { [321] = 10000 }); set("priceCount", { [321] = 4 })
CheapBidsDB.protectFraction = 0.50
eq(fn.ProtectThreshold({ itemID = 321, cnt = 1 }), 0.50 * 10000, "options: ProtectThreshold uses tuned 50% cap")
CheapBidsDB = {}; set("priceDB", {}); set("priceCount", {})

-- ===== summary =====
print(string.format("\nRESULT: %d passed, %d failed", passed, failed))
TEST_FAILED = failed
