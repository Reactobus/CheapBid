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
             bidAmt = 60000, high = false, timeLeft = 1, owner = "s99" } })
fn.ReadMyBids()
set("selectedItem", get("myBids")[1])
MOCK.bids = {}; MOCK.popups = {}; MOCK.gt = MOCK.gt + 5
fn.RebidBidder(nil)
eq(#MOCK.bids, 0, ">5g re-bid: NOT placed immediately")
eq(#MOCK.popups, 1, ">5g re-bid: confirmation popup shown")
local p = MOCK.popups[1]
if p and p.data and p.data.commit then p.data.commit() end   -- player presses Accept
eq(#MOCK.bids, 1, ">5g re-bid: placed after confirm")
eq(MOCK.bids[1] and MOCK.bids[1].amount, 60001, ">5g re-bid: bids the full required amount")

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
    { name = "BIGRED",   itemID = 70, cnt = 1, buyout = 100, minBid = 10, minInc = 1, bidAmt = 60000, high = false, timeLeft = 1, owner = "s70" }, -- red <30m, >5g
    { name = "SMALLRED", itemID = 71, cnt = 1, buyout = 100, minBid = 10, minInc = 1, bidAmt = 20,    high = false, timeLeft = 2, owner = "s71" }, -- red 30m-2h, cheap
})
fn.ReadMyBids()
ok(fn.FirstRed() and fn.FirstRed().name == "SMALLRED", "FirstRed: skips the >5g red, returns the cheap red")
ok(get("selectedItem") and get("selectedItem").name == "SMALLRED", "alwaysRedTarget: auto-select skips the >5g red")

-- ===== all reds >5g: nothing auto-targeted; manual pick still goes through confirm =====
set("selectedItem", nil)
setBidder({ { name = "BIG1", itemID = 72, cnt = 1, buyout = 100, minBid = 10, minInc = 1, bidAmt = 60000, high = false, timeLeft = 1, owner = "s72" } })
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
MOCK.auctions.list = { { name = "GOLD7", itemID = 200, cnt = 1, buyout = 0, minBid = 70000, minInc = 1, bidAmt = 0, high = false } }
local scanItem = { name = "GOLD7", itemID = 200, cnt = 1, buyout = 0, bid = 70000, idx = 1 }
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
eq(MOCK.bids[1] and MOCK.bids[1].amount, 70000, "scan >5g: amount = 7g")

-- ===== SCAN view: a cheap bid still places immediately (no popup) =====
MOCK.auctions.list = { { name = "CHEAP", itemID = 201, cnt = 1, buyout = 0, minBid = 50, minInc = 1, bidAmt = 0, high = false } }
local smallItem = { name = "CHEAP", itemID = 201, cnt = 1, buyout = 0, bid = 50, idx = 1 }
set("cheapItems", { smallItem })
set("selectedItem", smallItem)
MOCK.bids = {}; MOCK.popups = {}; MOCK.gt = MOCK.gt + 5
fn.BidItem(smallItem)
eq(#MOCK.popups, 0, "scan small: no confirmation popup")
eq(#MOCK.bids, 1, "scan small: placed immediately")

-- ===== summary =====
print(string.format("\nRESULT: %d passed, %d failed", passed, failed))
TEST_FAILED = failed
