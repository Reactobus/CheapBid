-- Unit tests for the MODERN auction-house path (WoW Forever, C_AuctionHouse):
-- CheapBids/Modern.lua as the `AH` adapter of CheapBids/CheapBids.lua.
-- Runs in its own Lua state (see tests/run.js): mocks.lua -> mocks_modern.lua ->
-- Modern.lua -> CheapBids.lua -> this file. Run with: node tests/run.js

local fn        = CheapBidsTest.fn
local set, get  = CheapBidsTest.set, CheapBidsTest.get
local M         = CheapBidsModern
local fire, advance = MOCKM.fire, MOCKM.advance

local passed, failed = 0, 0
local function ok(cond, msg)
    if cond then passed = passed + 1
    else failed = failed + 1; print("  FAIL (modern): " .. tostring(msg)) end
end
local function eq(a, b, msg)
    ok(a == b, (msg or "") .. "  (got " .. tostring(a) .. ", want " .. tostring(b) .. ")")
end

local function lots() return fn.ActiveList() end          -- cheapItems in the scan view
local function find(id, bid)
    for _, it in ipairs(lots()) do
        if it.itemID == id and (bid == nil or it.bid == bid) then return it end
    end
end
local function inList(it)
    for _, v in ipairs(lots()) do if v == it then return true end end
    return false
end
local function mark() return #MOCKM.texts end
local function key(id) return { itemID = id, itemLevel = 0, itemSuffix = 0, battlePetSpeciesID = 0 } end

-- let time pass WITHOUT the resolver sending a search (throttle closed meanwhile)
local function idle(dt)
    MOCKM.throttleReady = false
    advance(dt)
    MOCKM.throttleReady = true
end
-- pump the resolver (0.2 s steps) until it sends the next item search; returns its itemID
local function pumpToSearch()
    local n = #MOCKM.searches
    for _ = 1, 60 do
        advance(0.2)
        if #MOCKM.searches > n then return MOCKM.searches[#MOCKM.searches].itemID end
    end
    return nil
end
-- answer the in-flight search for `id`
local function respond(id) fire("ITEM_SEARCH_RESULTS_UPDATED", key(id)) end
-- a bid click a little later than the previous one (client anti-spam gates: 0.15 / 0.3 s)
local function click(it) advance(0.4); fn.BidItem(it) end

-- ======================================================================
-- 1. Detection: Modern.lua published CheapBidsModern and CheapBids uses it
-- ======================================================================
ok(M ~= nil and M.modern == true, "detect: CheapBidsModern published (C_AuctionHouse has ReplicateItems + PlaceBid)")
ok(GetAuctionItemInfo == nil and PlaceAuctionBid == nil and GetItemInfo == nil,
   "detect: legacy globals are really gone in this state")
-- AH.ItemInfo must route through Modern (C_Item) - the legacy GetItemInfo is nil here
eq(fn.ItemLink({ itemID = 4242 }), MOCKM.Link(4242), "detect: ItemLink resolves via CheapBidsModern -> C_Item.GetItemInfo")

local function framesWith(ev)
    local n = 0
    for _, f in ipairs(MOCKM.eventFrames) do if f._events[ev] then n = n + 1 end end
    return n
end
eq(framesWith("REPLICATE_ITEM_LIST_UPDATE"), 1, "detect: CheapBids registered REPLICATE_ITEM_LIST_UPDATE (AH.events)")
eq(framesWith("BIDS_UPDATED"), 1, "detect: CheapBids registered BIDS_UPDATED (AH.events)")
eq(framesWith("ITEM_SEARCH_RESULTS_UPDATED"), 1, "detect: Modern.lua registered ITEM_SEARCH_RESULTS_UPDATED")
eq(framesWith("AUCTION_ITEM_LIST_UPDATE"), 0, "detect: legacy-only event registration failed safely (pcall)")

ok(fire("ADDON_LOADED", "CheapBids") >= 1, "ADDON_LOADED delivered")

CheapBidsDB.lastGetAll = MOCK.now - 100
eq(select(2, M.CanQuery()), false, "CanQuery: full scan refused 100 s after the last one")
CheapBidsDB.lastGetAll = MOCK.now - 900
eq(select(2, M.CanQuery()), true, "CanQuery: full scan allowed after 900 s")

-- ---- open the AH: tab on the modern AuctionHouseFrame -----------------------------
MOCKM.throttleReady = false                 -- keep the resolver quiet until section 3
eq(fire("AUCTION_HOUSE_SHOW"), 2, "AUCTION_HOUSE_SHOW reaches Modern.lua's frame AND CheapBids' frame")
local tab = _G.CheapBidsAHTab
ok(tab ~= nil, "tab: CheapBidsAHTab created on AuctionHouseFrame")
eq(tab and tab._template, "AuctionHouseFrameDisplayModeTabTemplate", "tab: uses the modern tab template")
eq(tab and tab._text, "CheapBids", "tab: labelled CheapBids")
local content = _G.CheapBidsContent
ok(content ~= nil and not content:IsShown(), "tab: our panel starts hidden")
local modesBefore = #MOCKM.displayModes
if tab then tab:Click() end
ok(content and content:IsShown(), "tab click: panel shown")
eq(#MOCKM.displayModes, modesBefore + 1, "tab click: Blizzard panels hidden via SetDisplayMode (HideOthers)")
AuctionHouseFrame:SetDisplayMode("ItemBuy")                  -- player clicks a Blizzard tab
ok(content and not content:IsShown(), "Blizzard tab click: our panel hidden (SetDisplayMode post-hook)")
if tab then tab:Click() end
ok(content and content:IsShown(), "tab click again: panel shown")

-- the money boxes of the filter row (BuildUI order: bidMin g/s/c, bidMax, buyMin, buyMax)
local boxes = {}
for _, f in ipairs(MOCKM.frames) do
    if f._type == "EditBox" and f._parent == content then boxes[#boxes + 1] = f end
end
eq(#boxes, 12, "filter: 12 money boxes found")
local bidMaxC, buyMinG = boxes[6], boxes[7]
eq(bidMaxC and bidMaxC:GetText(), "99", "filter: default Bid to = 99c")
eq(buyMinG and buyMinG:GetText(), "1", "filter: default Buyout from = 1g")

-- ======================================================================
-- 2. Scan: ReplicateItems + REPLICATE_ITEM_LIST_UPDATE -> scanCache -> filter
-- ======================================================================
-- 0-based client snapshot (index in comment)
MOCKM.replicate = {
    { name = "A", itemID = 101, cnt = 1,  minBid = 5,   minInc = 1, buyout = 20000, band = 0, owner = "s0" },   -- 0
    { name = "B", itemID = 102, cnt = 5,  minBid = 50,  minInc = 5, buyout = 30000, band = 3, owner = "s1" },   -- 1
    { name = "A", itemID = 101, cnt = 1,  minBid = 7,   minInc = 1, buyout = 20000, band = 1, owner = "s2" },   -- 2 twin of 0
    { name = "C", itemID = 103, cnt = 1,  minBid = 500, minInc = 5, buyout = 90000, band = 2, owner = "s3" },   -- 3 too pricey
    { name = "D", itemID = 104, cnt = 1,  minBid = 10,  buyout = 0, band = 2, high = true, owner = "s4" },      -- 4 we lead
    { name = "E", itemID = 105, cnt = 1,  minBid = 10,  minInc = 5, bidAmt = 20, buyout = 40000, band = 2,
      ownerFull = "s5-Realm" },                                                                                 -- 5 bid 25
    { name = "F", itemID = 106, cnt = 20, minBid = 3,   buyout = 15000, band = 3, owner = "s6" },              -- 6 commodity
    { name = "G", itemID = 107, cnt = 1,  minBid = 9,   buyout = 25000, band = 3, owner = "s7" },              -- 7
    { name = "H", itemID = 108, cnt = 1,  minBid = 42,  buyout = 26000, band = 3, owner = "s8" },              -- 8
    { name = nil, itemID = 109, cnt = 2,  minBid = 11,  buyout = 27000, band = 2, owner = "s9" },              -- 9 name uncached
    { name = "",  itemID = 0 },                                                                                 -- 10 empty slot
    { name = "Q", itemID = 110, cnt = 1,  minBid = 60,  buyout = 0, band = 0, owner = "s11" },                 -- 11
    { name = "R", itemID = 111, cnt = 1,  minBid = 61,  buyout = 0, band = 0, owner = "s12" },                 -- 12
}
MOCKM.commodity[106] = true

-- wide filter for the mapping checks: no bid max, no buyout floor
bidMaxC:SetText(""); buyMinG:SetText("")
local scanBtn = MOCKM.button("scan auc")
ok(scanBtn ~= nil and scanBtn:GetScript("OnClick") ~= nil, "scan button found")

-- cooldown branch: 100 s after the last full scan -> refused, ReplicateItems NOT called
CheapBidsDB.lastGetAll = MOCK.now - 100
local m0 = mark()
scanBtn:Click()
eq(MOCKM.replicateCalls, 0, "scan on cooldown: ReplicateItems not called")
ok(MOCKM.saw("on cooldown", m0), "scan on cooldown: player told to wait")
eq(CheapBidsDB.lastGetAll, MOCK.now - 100, "scan on cooldown: lastGetAll untouched")

-- ready: ReplicateItems once
CheapBidsDB.lastGetAll = MOCK.now - 901
scanBtn:Click()
eq(MOCKM.replicateCalls, 1, "scan: ReplicateItems called once")
eq(CheapBidsDB.lastGetAll, MOCK.now, "scan: lastGetAll stamped")
eq(#lots(), 0, "scan: nothing listed before the snapshot arrives")
fire("REPLICATE_ITEM_LIST_UPDATE")
eq(MOCKM.replicateCalls, 1, "scan: still exactly one ReplicateItems after the update event")
eq(#MOCKM.badIndex, 0, "scan: GetReplicateItem* never called out of range (0-based mapping)")

local function calc(a) return (a.bidAmt or 0) > 0 and (a.bidAmt + (a.minInc or 0)) or (a.minBid or 0) end
local byIdx = {}
for _, it in ipairs(lots()) do if it.idx then byIdx[it.idx] = it end end
local wideWant = { 0, 1, 2, 3, 5, 6, 7, 8, 9, 11, 12 }       -- 0-based client indices expected
eq(#lots(), #wideWant, "wide filter: every live, non-led lot listed")
for _, k in ipairs(wideWant) do
    local a, it = MOCKM.replicate[k + 1], byIdx[k + 1]
    ok(it ~= nil, "mapping: client index " .. k .. " -> lot idx " .. (k + 1))
    if it then
        eq(it.itemID, a.itemID, "mapping idx " .. (k + 1) .. ": itemID")
        eq(it.timeLeft, a.band + 1, "mapping idx " .. (k + 1) .. ": time band " .. a.band .. " -> code " .. (a.band + 1))
        eq(it.bid, calc(a), "mapping idx " .. (k + 1) .. ": effective bid")
        eq(it.cnt, a.cnt, "mapping idx " .. (k + 1) .. ": count")
        eq(it.buyout, a.buyout, "mapping idx " .. (k + 1) .. ": buyout")
    end
end
ok(byIdx[5] == nil, "mapping: lot we already lead (highBidder) is hidden")
ok(byIdx[11] == nil, "mapping: empty snapshot slot skipped")
eq(byIdx[6] and byIdx[6].owner, "s5-Realm", "mapping: ownerFullName used when owner is empty")
eq(byIdx[10] and byIdx[10].name, "", "mapping: lot with uncached name still kept (by itemID)")
eq(M.Info("list", 2), "B", "M.Info('list', 2) reads client index 1")

-- the cheap filter: bid 1..99c
bidMaxC:SetText("99")
advance(0.5)                                  -- past the search-button throttle
MOCKM.button("search"):Click()
eq(#lots(), 10, "cheap filter: 10 lots with a 1-99c bid")
ok(find(103) == nil, "cheap filter: 5s lot filtered out")
ok(find(104) == nil, "cheap filter: led lot filtered out")
local lotB  = find(102)
local lotA5, lotA7 = find(101, 5), find(101, 7)
local lotE, lotF, lotG, lotH = find(105), find(106), find(107), find(108)
local lot9, lotQ, lotR = find(109), find(110), find(111)
ok(lotB and lotA5 and lotA7 and lotE and lotF and lotG and lotH and lot9 and lotQ and lotR, "cheap filter: expected lots present")

-- ======================================================================
-- 3 + 4. Resolver (auctionID lookup) and bidding
-- ======================================================================
eq(#MOCKM.searches, 0, "resolver: no search while the throttled message system is not ready")

-- a bid click on a NOT yet resolved lot: kept, no PlaceBid, "locating" message
local m1 = mark()
click(lotB)
eq(#MOCKM.placeBids, 0, "unresolved lot: PlaceBid NOT called")
ok(inList(lotB) and not lotB.done, "unresolved lot: kept in the list")
ok(MOCKM.saw("Locating this lot", m1), "unresolved lot: wait message shown")

-- the clicked lot jumped to the FRONT of the queue (Prefetch had queued the cheapest first)
MOCKM.throttleReady = true
eq(pumpToSearch(), 102, "resolver: clicked lot is searched first")
local s1 = MOCKM.searches[1]
eq(s1 and s1.separate, true, "resolver: SendSearchQuery(separateOwnerItems = true)")
eq(s1 and s1.sorts and s1.sorts[1] and s1.sorts[1].sortOrder, Enum.AuctionHouseSortOrder.Price, "resolver: sorted by price")

MOCKM.results[102] = { pages = { {
    { auctionID = 5102, itemKey = key(102), quantity = 5, buyoutAmount = 30000, minBid = 60, timeLeft = 2 },
} } }
fire("ITEM_SEARCH_RESULTS_UPDATED", key(999))     -- some other item's results: ignored
eq(lotB._aid, nil, "resolver: results for another item are ignored")
respond(102)
eq(lotB._aid, 5102, "resolver: lot B got its auctionID")
eq(lotB._next, 60, "resolver: next bid taken from the search result")
eq(lotB.timeLeft, 3, "resolver: timeLeft refined from the result band (2 -> 3)")
eq(M.aidByIdx[lotB.idx], 5102, "resolver: aidByIdx[idx] set")

-- resolved: exactly one PlaceBid(auctionID, amount); chat confirm removes the lot
click(lotB)
eq(#MOCKM.placeBids, 1, "bid: PlaceBid called once")
eq(MOCKM.placeBids[1] and MOCKM.placeBids[1].aid, 5102, "bid: PlaceBid(auctionID)")
eq(MOCKM.placeBids[1] and MOCKM.placeBids[1].amount, 60, "bid: PlaceBid(amount = current min bid)")
ok(inList(lotB), "bid: lot stays until the server confirms")
fire("CHAT_MSG_SYSTEM", ERR_AUCTION_BID_PLACED)
ok(lotB.done and not inList(lotB), "bid: ERR_AUCTION_BID_PLACED confirms and removes the lot")

-- next in queue: 106 is a commodity -> flagged, never searched; then 101
eq(pumpToSearch(), 101, "resolver: commodity skipped, next search is item 101")
ok(lotF._commodity == true, "commodity: lot flagged")
MOCKM.results[101] = { pages = { {
    { auctionID = 9001, quantity = 1, buyoutAmount = 20000, minBid = 7, timeLeft = 1 },
    { auctionID = 9002, quantity = 1, buyoutAmount = 20000, minBid = 5, timeLeft = 0 },
    { auctionID = 9003, quantity = 2, buyoutAmount = 20000, minBid = 5, timeLeft = 0 },   -- wrong stack size
} } }
respond(101)
eq(lotA5._aid, 9002, "resolver: twin lot (bid 5) -> auction with nearest bid (9002)")
eq(lotA7._aid, 9001, "resolver: twin lot (bid 7) -> the other auction (9001)")
ok(lotA5._aid ~= lotA7._aid, "resolver: twins get DISTINCT auctionIDs")
eq(M.claimed[9003], nil, "resolver: quantity mismatch never claimed")
eq(lotA5.timeLeft, 1, "resolver: twin 5 timeLeft band 0 -> 1")
eq(lotA7.timeLeft, 2, "resolver: twin 7 timeLeft band 1 -> 2")
eq(M.aidByIdx[1], 9002, "resolver: aidByIdx[1]")
eq(M.aidByIdx[3], 9001, "resolver: aidByIdx[3]")

-- commodity click: message, kept, no PlaceBid
local m2 = mark()
click(lotF)
eq(#MOCKM.placeBids, 1, "commodity: PlaceBid NOT called")
ok(inList(lotF), "commodity: lot kept")
ok(MOCKM.saw("Commodity", m2), "commodity: told to use the Blizzard Buy tab")

-- 107: our own leading bid in the results -> _led -> removed as "already lead"
eq(pumpToSearch(), 107, "resolver: next search is item 107")
MOCKM.results[107] = { pages = { {
    { auctionID = 7107, quantity = 1, buyoutAmount = 25000, minBid = 10, timeLeft = 3, bidder = MOCKM.playerGUID },
} } }
respond(107)
eq(lotG._led, true, "resolver: our own leading bid flagged (_led via UnitGUID)")
local m3 = mark()
click(lotG)
eq(#MOCKM.placeBids, 1, "led lot: no PlaceBid")
ok(not inList(lotG) and MOCKM.saw("already lead", m3), "led lot: removed with 'already lead' message")

-- 109: first page lacks the lot, HasFullItemSearchResults false -> RequestMore
eq(pumpToSearch(), 109, "resolver: next search is item 109")
MOCKM.results[109] = { pages = {
    { { auctionID = 1, quantity = 1, buyoutAmount = 27000, minBid = 11, timeLeft = 2 } },
    { { auctionID = 9109, quantity = 2, buyoutAmount = 27000, minBid = 11, timeLeft = 1 } },
} }
respond(109)
eq(#MOCKM.moreCalls, 1, "resolver: partial results -> RequestMoreItemSearchResults")
ok(lot9._aid == nil and not lot9._nf, "resolver: lot not judged on a partial page")
respond(109)
eq(#MOCKM.moreCalls, 1, "resolver: full results -> no further page requests")
eq(lot9._aid, 9109, "resolver: lot found on the second page")

-- 105: no matching auction any more -> _nf -> removed as unavailable
eq(pumpToSearch(), 105, "resolver: next search is item 105")
MOCKM.results[105] = { pages = { {
    { auctionID = 5105, quantity = 1, buyoutAmount = 99999, minBid = 25, timeLeft = 2 },
} } }
respond(105)
eq(lotE._nf, true, "resolver: unmatched lot marked _nf")
local m4 = mark()
click(lotE)
eq(#MOCKM.placeBids, 1, "_nf lot: no PlaceBid")
ok(not inList(lotE) and MOCKM.saw("unavailable, removed", m4), "_nf lot: removed with 'unavailable' message")

-- 108: copper rounding when the realm takes whole silver only
eq(pumpToSearch(), 108, "resolver: next search is item 108")
MOCKM.results[108] = { pages = { {
    { auctionID = 8108, quantity = 1, buyoutAmount = 26000, minBid = 42, timeLeft = 3 },
} } }
respond(108)
MOCKM.copper = false
click(lotH)
eq(#MOCKM.placeBids, 2, "silver-only realm: PlaceBid called")
eq(MOCKM.placeBids[2] and MOCKM.placeBids[2].amount, 100, "silver-only realm: 42c rounded UP to 1s")
MOCKM.copper = true
fire("CHAT_MSG_SYSTEM", ERR_AUCTION_BID_PLACED)
ok(not inList(lotH), "silver-only realm: confirmed + removed")

-- bid error (UI_ERROR_MESSAGE, message in arg2) -> invalidate + re-queue that lot
click(lotA7)
eq(MOCKM.placeBids[3] and MOCKM.placeBids[3].aid, 9001, "bid twin 7 on 9001")
fire("UI_ERROR_MESSAGE", 1, ERR_AUCTION_HIGHER_BID)
eq(lotA7._aid, nil, "bid error: auctionID forgotten")
eq(M.claimed[9001], nil, "bid error: auctionID unclaimed")
eq(M.aidByIdx[3], nil, "bid error: aidByIdx cleared")
ok(inList(lotA7) and not lotA7.done, "bid error: lot kept")
eq(lotA5._aid, 9002, "bid error: the twin keeps its auctionID")
eq(pumpToSearch(), 101, "bid error: the lot's item is searched again (front of the queue)")
MOCKM.results[101] = { pages = { {
    { auctionID = 9002, quantity = 1, buyoutAmount = 20000, minBid = 5, timeLeft = 0 },   -- still the twin's
    { auctionID = 9011, quantity = 1, buyoutAmount = 20000, minBid = 8, timeLeft = 1 },
} } }
respond(101)
eq(lotA7._aid, 9011, "bid error: re-resolved to a fresh auction (not the twin's claimed one)")
local n4 = #MOCKM.placeBids
click(lotA7)
eq(#MOCKM.placeBids, n4 + 1, "re-resolved lot: bid placed")
eq(MOCKM.placeBids[n4 + 1] and MOCKM.placeBids[n4 + 1].aid, 9011, "re-resolved lot: bids the new auctionID")
eq(MOCKM.placeBids[n4 + 1] and MOCKM.placeBids[n4 + 1].amount, 8, "re-resolved lot: bids the new min bid")

-- "Internal auction error" is in Modern's BID_ERRORS list too: it must also invalidate
idle(3.5)                                      -- not a flood cluster
fire("UI_ERROR_MESSAGE", 1, ERR_AUCTION_DATABASE_ERROR)
eq(lotA7._aid, nil, "database error: auctionID forgotten (re-lookup)")
local n5 = #MOCKM.placeBids
idle(3.5)
click(lotA7)
ok(#MOCKM.placeBids == n5 or MOCKM.placeBids[#MOCKM.placeBids].aid ~= 9011,
   "database error: retry does not re-bid the same stale auctionID")

-- two bids in flight, the OLDEST is rejected (CheapBids is FIFO: RejectOldest)
idle(3.5)
-- answer the searches for several items, in WHATEVER order the queue sends them: a lot whose
-- answer has no matching result would be marked gone, so each item gets its own prepared reply
local function resolveAll(spec)               -- spec: { [itemID] = { aid, minBid } }
    local left = 0
    for _ in pairs(spec) do left = left + 1 end
    for _ = 1, 12 do
        if left == 0 then break end
        local got = pumpToSearch()
        local want = got and spec[got]
        if want then
            MOCKM.results[got] = { pages = { {
                { auctionID = want[1], quantity = 1, buyoutAmount = 0, minBid = want[2], timeLeft = 0 },
            } } }
            spec[got] = nil; left = left - 1
        end
        if got then respond(got) end
    end
    eq(left, 0, "resolver: every wanted item was searched")
end
resolveAll({ [110] = { 1110, 60 }, [111] = { 1111, 61 } })
eq(lotQ._aid, 1110, "lot Q resolved")
eq(lotR._aid, 1111, "lot R resolved")
idle(7)                                        -- let the 6 s bid watchdog drain older pending bids
local n6 = #MOCKM.placeBids
click(lotQ)
click(lotR)
eq(#MOCKM.placeBids, n6 + 2, "two bids in flight")
fire("UI_ERROR_MESSAGE", 1, ERR_AUCTION_HIGHER_BID)  -- the reply to the FIRST bid (lot Q)
eq(lotQ._aid, nil, "FIFO error: the rejected (oldest) lot Q is the one invalidated")
eq(lotR._aid, 1111, "FIFO error: lot R (still pending, maybe accepted) keeps its auctionID")

-- a search that never answers is retried after the timeout
idle(7)
local before = #MOCKM.searches
local first = pumpToSearch()
ok(first ~= nil, "timeout: a search went out")
local again
for _ = 1, 100 do                                  -- no answer: >6 s later it must be re-sent
    advance(0.2)
    for i = before + 2, #MOCKM.searches do
        if MOCKM.searches[i].itemID == first then again = true end
    end
    if again then break end
end
ok(again, "timeout: unanswered search re-sent later")

-- AH closed: the pump stops, no searches while closed
fire("AUCTION_HOUSE_CLOSED")
local nClosed = #MOCKM.searches
advance(5)
eq(#MOCKM.searches, nClosed, "AH closed: resolver idle")
fire("AUCTION_HOUSE_SHOW")
if tab then tab:Click() end

-- ======================================================================
-- 5. My bids: C_AuctionHouse.GetBids -> "bidder" list -> re-bid by auctionID
-- ======================================================================
MOCKM.bids = {
    { auctionID = 7002, itemKey = { itemID = 202 }, itemLink = MOCKM.Link(202), timeLeft = 3,
      minBid = 80, bidAmount = 70, buyoutAmount = 0, bidder = MOCKM.playerGUID },          -- leading (green)
    { auctionID = 7001, itemKey = { itemID = 201 }, itemLink = MOCKM.Link(201), timeLeft = 0,
      minBid = 150, bidAmount = 100, buyoutAmount = 5000, bidder = "Player-9-0000BEEF" },  -- outbid (red)
    { auctionID = 7003, itemKey = { itemID = 203 }, timeLeft = 1, minBid = 40 },          -- red, no link
}
set("alwaysRedTarget", true); set("bidsDismissed", {})
-- an unconfirmed scan bid first (lot A5 on 9002): its auctionID must survive a later
-- error that belongs to a my-bids re-bid
local nA5 = #MOCKM.placeBids
click(lotA5)
eq(MOCKM.placeBids[nA5 + 1] and MOCKM.placeBids[nA5 + 1].aid, 9002, "scan bid on twin 5 (9002) before entering my bids")
local qb = MOCKM.queryBidsCalls
advance(0.5)
MOCKM.button("my bids"):Click()
eq(get("viewMode"), "bids", "my bids: view switched")
ok(MOCKM.queryBidsCalls > qb, "my bids: C_AuctionHouse.QueryBids requested")
local mb = get("myBids")
eq(#mb, 3, "my bids: 3 bids read from GetBids")
eq(mb[1] and mb[1].itemID, 201, "my bids: red <30m on top")
eq(mb[2] and mb[2].itemID, 203, "my bids: red 30m-2h next")
eq(mb[3] and mb[3].itemID, 202, "my bids: green last")
eq(mb[1] and mb[1].led, false, "my bids: other bidder -> outbid")
eq(mb[3] and mb[3].led, true, "my bids: our GUID -> leading")
eq(mb[1] and mb[1].bid, 150, "my bids: re-bid amount = minBid (not bidAmount + inc)")
eq(mb[1] and mb[1].timeLeft, 1, "my bids: time band 0 -> 1")
eq(mb[1] and mb[1].buyout, 5000, "my bids: buyout")
eq(mb[1] and mb[1].name, "Item201", "my bids: name from the item link")
eq(mb[2] and mb[2].name, "Item203", "my bids: name from the itemID when no link")
eq(mb[1] and mb[1].idx, 2, "my bids: idx = position in GetBids (before sorting)")
eq(get("selectedItem") and get("selectedItem").itemID, 201, "my bids: top red auto-targeted")

local n7 = #MOCKM.placeBids
advance(0.5)
fn.BidItem(nil)
eq(#MOCKM.placeBids, n7 + 1, "my bids re-bid: PlaceBid called")
eq(MOCKM.placeBids[n7 + 1] and MOCKM.placeBids[n7 + 1].aid, 7001, "my bids re-bid: right auctionID after sorting")
eq(MOCKM.placeBids[n7 + 1] and MOCKM.placeBids[n7 + 1].amount, 150, "my bids re-bid: amount = minBid")
eq(get("selectedItem") and get("selectedItem").itemID, 203, "my bids re-bid: advanced to the next red")
advance(0.5)
fn.BidItem(nil)
eq(MOCKM.placeBids[n7 + 2] and MOCKM.placeBids[n7 + 2].aid, 7003, "my bids re-bid #2: auctionID 7003")
eq(MOCKM.placeBids[n7 + 2] and MOCKM.placeBids[n7 + 2].amount, 40, "my bids re-bid #2: amount 40")

-- the server rejects the LAST my-bids re-bid: the bidder list is restored, and the
-- unrelated scan lot (A5, bid earlier on the scan list) must keep its auctionID
fire("UI_ERROR_MESSAGE", 1, ERR_AUCTION_HIGHER_BID)
eq(#get("myBids"), 3, "my bids re-bid rejected: bidder list re-read (lots restored)")
eq(lotA5._aid, 9002, "my bids re-bid rejected: unrelated scan lot keeps its auctionID")

MOCKM.bids[2].bidder = MOCKM.playerGUID          -- our re-bid landed: we lead 201 now
fire("BIDS_UPDATED")
mb = get("myBids")
local led201
for _, it in ipairs(mb) do if it.itemID == 201 then led201 = it.led end end
eq(led201, true, "BIDS_UPDATED: re-read, 201 now leading")
MOCKM.button("my bids"):Click()                     -- back to the scan view
eq(get("viewMode"), "scan", "my bids: toggled back to scan view")

-- buyout path: same adapter, amount = buyout (PlaceBid at the buyout price = buy)
advance(0.5)
local nBuy = #MOCKM.placeBids
fn.BuyItem(lot9)
eq(#MOCKM.placeBids, nBuy + 1, "buy: PlaceBid called once")
eq(MOCKM.placeBids[nBuy + 1] and MOCKM.placeBids[nBuy + 1].aid, 9109, "buy: auctionID of the lot")
eq(MOCKM.placeBids[nBuy + 1] and MOCKM.placeBids[nBuy + 1].amount, 27000, "buy: amount = buyout")

-- ======================================================================
-- 6. Commodities are never bid on / searched
-- ======================================================================
local searched106, bid106 = false, false
for _, s in ipairs(MOCKM.searches) do if s.itemID == 106 then searched106 = true end end
ok(not searched106, "commodity: never item-searched")
ok(lotF._aid == nil, "commodity: never got an auctionID")
advance(0.5)
local n8 = #MOCKM.placeBids
fn.BidItem(lotF)
eq(#MOCKM.placeBids, n8, "commodity: PlaceBid never called")

eq(#MOCKM.errors, 0, "no Lua errors inside fired events / timers")

print(string.format("RESULT (modern): %d passed, %d failed", passed, failed))
TEST_FAILED = (TEST_FAILED or 0) + failed
