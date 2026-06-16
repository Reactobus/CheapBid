-- CheapBids.lua  (TBC Classic 2.5.5 / anniversary)
-- Self-contained AH tab: own table (no external libs), GetAll scan, and manual
-- bidding driven by the player's clicks.
--
-- IMPORTANT: run this with Auctioneer / Auctionator DISABLED. Two auction
-- addons fight over the single auction list (each re-queries and overwrites it),
-- which makes bids hit a stale list and silently fail. With CheapBids as the
-- only AH addon, the GetAll snapshot stays valid and bids go through instantly.
--
-- Flow: "scan auc" (GetAll) -> filter -> "search" -> select a row and "bid"
-- (one per click / hotkey). "cancel" stops.
-- Not a bot: every bid needs a player button click.

local ADDON_NAME = "CheapBids"
local SCAN_BTN   = "scan auc"
local PER_PAGE   = NUM_AUCTION_ITEMS_PER_PAGE or 50
local GETALL_COOLDOWN = 1080      -- ~18 min: observed a bit longer than the nominal 15;
                                  -- only a hint for the countdown, CanSendAuctionQuery is the real gate
local ROW_H      = 18
local BID_OK  = ERR_AUCTION_BID_PLACED or "Bid accepted"
local AUC_ERR = ERR_AUCTION_DATABASE_ERROR or "Internal auction error."

-- key-binding labels (shown in Esc -> Key Bindings -> CheapBids)
BINDING_HEADER_CHEAPBIDS = "CheapBids"
BINDING_NAME_CHEAPBIDS_BIDTOP = "Bid on selected lot"

-- ===== State =====
local scanCache, cheapItems = {}, {}
local cacheFromGetAll = false
local scanMode, isScanning, scanPage, scanTotalPages = nil, false, 0, 1
local getAllPending, scanToken, pageConfirm = false, 0, false

local attempted = {}                 -- lot currently awaiting a server reply
local pending = {}                   -- FIFO of bids awaiting server reply
local bidWatch = 0                   -- watchdog / step token
local bidsSent, bidsOK, bidsFail = 0, 0, 0
local debugOn = false

-- focused re-query state: the selected lot is re-queried (small exact-match list)
-- so its live index is fresh at bid time (the GetAll snapshot goes stale fast)
local focusItem, focusReady, focusQuerying = nil, false, false
local focusTok = 0

local uiBuilt, myTabID = false, nil
local selectedItem = nil
local sortKey, sortAsc = "bid", true

-- times: which of the 4 legacy time-left buckets to show (all on by default)
local filter = { bidMin = 1, bidMax = 99, buyMin = nil, buyMax = nil,
                 times = { [1] = true, [2] = true, [3] = true, [4] = true } }

-- UI refs
local content, leftCol, listFrame, statusFS, actFS, foundFS, cacheFS, progBar
local scanBtn, searchBtn, bidBtn, stopBtn
local mBidMin, mBidMax, mBuyMin, mBuyMax
local fauxScroll, tableRows, headerArrows = nil, {}, {}
local NUM_ROWS = 0

-- event frame
local ev = CreateFrame("Frame")

-- ===== Money / filter helpers =====

local function FormatMoney(copper)
    if not copper or copper == 0 then return "0" end
    local g = math.floor(copper / 10000)
    local s = math.floor(copper % 10000 / 100)
    local c = copper % 100
    local t = ""
    if g > 0 then t = t .. g .. "|cffffd700g|r " end
    if s > 0 then t = t .. s .. "|cffc7c7cfs|r " end
    if c > 0 or t == "" then t = t .. c .. "|cffeda55fc|r" end
    return t
end

local function BoxNum(e) local x = e:GetText(); if not x or x == "" then return 0 end return tonumber(x) or 0 end
local function MoneyCopper(w) return BoxNum(w.g)*10000 + BoxNum(w.s)*100 + BoxNum(w.c) end
local function MoneyHasValue(w) return w.g:GetText() ~= "" or w.s:GetText() ~= "" or w.c:GetText() ~= "" end

local function CalcBid(minBid, minInc, bidAmt)
    if bidAmt and bidAmt > 0 then return bidAmt + (minInc or 0) end
    return minBid or 0
end

local function ReadFilter()
    filter.bidMin = MoneyCopper(mBidMin)
    filter.bidMax = MoneyHasValue(mBidMax) and MoneyCopper(mBidMax) or nil
    filter.buyMin = MoneyHasValue(mBuyMin) and MoneyCopper(mBuyMin) or nil
    filter.buyMax = MoneyHasValue(mBuyMax) and MoneyCopper(mBuyMax) or nil
end

local function PassesFilter(bid, buyout)
    if bid < (filter.bidMin or 0) then return false end
    if filter.bidMax and bid > filter.bidMax then return false end
    if filter.buyMin or filter.buyMax then
        if not buyout or buyout == 0 then return false end
        if filter.buyMin and buyout < filter.buyMin then return false end
        if filter.buyMax and buyout > filter.buyMax then return false end
    end
    return true
end

-- legacy AH gives only 4 time-left buckets; show only the checked ones
local function TimeShown(code)
    if not code then return true end            -- unknown bucket -> always show
    return filter.times[code] ~= false
end

local function FilterDesc()
    local b = "bid " .. FormatMoney(filter.bidMin or 0) .. " - " ..
              (filter.bidMax and FormatMoney(filter.bidMax) or "max")
    if filter.buyMin or filter.buyMax then
        b = b .. ", buyout " .. (filter.buyMin and FormatMoney(filter.buyMin) or "0") ..
            " - " .. (filter.buyMax and FormatMoney(filter.buyMax) or "max")
    end
    return b
end

local function ItemName(it)
    if it.link and it.link ~= "" then return it.link end
    if it.itemID and it.itemID ~= 0 then
        local n, l = GetItemInfo(it.itemID)
        if l then it.link = l; return l end
        if n then return n end
    end
    if it.name and it.name ~= "" then return it.name end
    return "|cff888888(loading…)|r"
end

-- ===== Throttled query =====

local function SafeQuery(fn, depth)
    depth = depth or 0
    if CanSendAuctionQuery() then fn()
    elseif depth < 600 then C_Timer.After(0.05, function() SafeQuery(fn, depth + 1) end)
    else if statusFS then statusFS:SetText("Server not responding (throttled). Try later.") end end
end

local function SetProgress(frac)
    if not progBar then return end
    progBar:Show()
    frac = math.max(0, math.min(1, frac or 0))
    progBar:SetValue(frac)
    progBar.txt:SetText(math.floor(frac * 100) .. "%")
end
local function HideProgress() if progBar then progBar:Hide() end end

-- ===== Table =====

local function SortItems()
    table.sort(cheapItems, function(a, b)
        local va, vb
        if sortKey == "name" then va, vb = (a.name or ""), (b.name or "")
        elseif sortKey == "cnt" then va, vb = a.cnt, b.cnt
        elseif sortKey == "buyout" then va, vb = a.buyout, b.buyout
        elseif sortKey == "time" then va, vb = (a.timeLeft or 99), (b.timeLeft or 99)
        else va, vb = a.bid, b.bid end
        if va == vb then return (a.name or "") < (b.name or "") end
        if sortAsc then return va < vb else return va > vb end
    end)
end

local QCOLOR = { [0]="9d9d9d",[1]="ffffff",[2]="1eff00",[3]="0070dd",[4]="a335ee",[5]="ff8000" }

-- legacy AH time-left is a 4-bucket code, not exact seconds
local TIME_LABEL = {
    [1] = "|cffff3030<30m|r",
    [2] = "|cffff902030m-2h|r",
    [3] = "|cffffe0202-12h|r",
    [4] = "|cff30ff30>12h|r",
}
local function TimeLeftText(code) return TIME_LABEL[code or 0] or "-" end

local function UpdateButtons()
    if not uiBuilt then return end
    local idle = not isScanning
    cacheFS:SetText("Cache: " .. #scanCache)
    foundFS:SetText("Found: " .. #cheapItems)
    if searchBtn then searchBtn:SetEnabled(#scanCache > 0 and idle) end
    if bidBtn    then bidBtn:SetEnabled(#cheapItems > 0 and idle) end
    if stopBtn   then stopBtn:SetEnabled(isScanning) end
    if scanBtn   then scanBtn:SetText(isScanning and "Stop" or SCAN_BTN) end
end

local function UpdateTable()
    if not uiBuilt then return end
    UpdateButtons()
    if not fauxScroll then return end
    local total = #cheapItems
    FauxScrollFrame_Update(fauxScroll, total, NUM_ROWS, ROW_H)
    local offset = FauxScrollFrame_GetOffset(fauxScroll)
    for i = 1, NUM_ROWS do
        local row = tableRows[i]
        if not row then break end
        local it = cheapItems[i + offset]
        if it then
            row.item = it
            local ic = it.tex
            if it.itemID and it.itemID ~= 0 then
                local instTex = select(5, GetItemInfoInstant(it.itemID))   -- icon from itemID, even if uncached
                if instTex then ic = instTex end
            end
            row.icon:SetTexture(ic or 134400)
            row.nameFS:SetText(ItemName(it))
            row.cntFS:SetText(it.cnt and it.cnt > 1 and tostring(it.cnt) or "1")
            row.bidFS:SetText(FormatMoney(it.bid))
            row.buyFS:SetText(it.buyout > 0 and FormatMoney(it.buyout) or "-")
            row.timeFS:SetText(TimeLeftText(it.timeLeft))
            if it == selectedItem then row.sel:Show() else row.sel:Hide() end
            row:SetAlpha(attempted[it] and 0.5 or 1)
            row:Show()
        else
            row.item = nil
            row:Hide()
        end
    end
end

local function ApplyFilter()
    ReadFilter()
    cheapItems = {}
    for _, it in ipairs(scanCache) do
        if not it.done and TimeShown(it.timeLeft) and PassesFilter(it.bid, it.buyout) then cheapItems[#cheapItems + 1] = it end
    end
    SortItems()
    selectedItem = nil
    local sb = _G["CheapBidsFauxScrollBar"]
    if sb then sb:SetValue(0) end
    UpdateTable()
    statusFS:SetText(string.format("Found %d of %d (%s)", #cheapItems, #scanCache, FilterDesc()))
    C_Timer.After(0.7, function() if uiBuilt and not isScanning then UpdateTable() end end)
end

-- index of a lot in the (small) filtered list, or nil
local function IndexOf(it)
    if not it then return nil end
    for i, v in ipairs(cheapItems) do if v == it then return i end end
    return nil
end

-- scroll the table so `it` is visible (keeps the just-bid lot in view so the
-- highlight is never off-screen)
local function ScrollToItem(it)
    if not it or not fauxScroll then return end
    local idx = IndexOf(it)
    if not idx then return end
    local offset = FauxScrollFrame_GetOffset(fauxScroll) or 0
    -- only scroll when the target is OUTSIDE the visible window; then place it a
    -- couple rows from the top so the UPCOMING lots stay visible below it (the
    -- bid walks downward as live lots get taken).
    if idx > offset and idx <= offset + NUM_ROWS then return end
    local lead = math.min(2, NUM_ROWS - 1)              -- rows of context above the target
    local newOffset = idx - 1 - lead
    if newOffset < 0 then newOffset = 0 end
    if newOffset ~= offset then
        local sb = _G["CheapBidsFauxScrollBar"]
        if sb then sb:SetValue(newOffset * ROW_H) end   -- fires OnVerticalScroll -> UpdateTable
    end
end

-- ===== Reading the auction list =====
-- GetAuctionItemInfo: 1name 2tex 3cnt 4qual 5canUse 6lvl 7lvlCol 8minBid 9minInc 10buyout 11bidAmt 12high ... 17itemID
local function ReadIndexInto(cache, i, storeIdx)
    local name, tex, cnt, qual, _, _, _, minBid, minInc, buyout, bidAmt, _, _, _, _, _, itemID =
        GetAuctionItemInfo("list", i)
    if not name or name == "" then
        if not itemID or itemID == 0 then return end
    end
    cache[#cache + 1] = {
        name = name or "", tex = tex, cnt = cnt or 1,
        bid = CalcBid(minBid, minInc, bidAmt), buyout = buyout or 0,
        timeLeft = GetAuctionItemTimeLeft("list", i),   -- 1<30m 2:30m-2h 3:2-12h 4:>12h
        itemID = itemID, idx = storeIdx and i or nil,
        -- link is resolved lazily in ItemName via itemID; calling
        -- GetAuctionItemLink for every one of 200k+ lots is what made the scan slow
    }
end

-- ===== Scan =====

local StartPageScan

local function FinishScan(msg)
    scanMode = nil; isScanning = false; getAllPending = false
    HideProgress()
    if statusFS and msg then statusFS:SetText(msg) end
    UpdateButtons()
end

-- Aborting a scan must DISCARD the partial cache — never present a truncated
-- count as a real result, and never leave a half-snapshot that breaks bidding.
local function AbortScan()
    scanMode = nil; isScanning = false; getAllPending = false
    scanCache = {}; cheapItems = {}; cacheFromGetAll = false
    HideProgress(); UpdateTable()
    if statusFS then statusFS:SetText("Scan aborted - press \"scan auc\" again.") end
    UpdateButtons()
end

local GETALL_BATCH = 5000
local function ProcessGetAll(start, total)
    if scanMode ~= "getall" then return end
    local stop = math.min(start + GETALL_BATCH - 1, total)
    for i = start, stop do ReadIndexInto(scanCache, i, true) end
    if stop < total then
        SetProgress(0.1 + 0.9 * stop / total)
        statusFS:SetText(string.format("Processing %d/%d…", stop, total))
        C_Timer.After(0, function() ProcessGetAll(stop + 1, total) end)
    else
        isScanning = false; getAllPending = false; scanMode = nil
        cacheFromGetAll = true; HideProgress()
        statusFS:SetText(string.format("Scan done: %d lots. Filter -> search -> bid.", #scanCache))
        ApplyFilter()
    end
end

local function StartScan()
    local _, canAll = CanSendAuctionQuery()
    if not canAll then
        local last = (CheapBidsDB and CheapBidsDB.lastGetAll) or 0
        local left = math.ceil((GETALL_COOLDOWN - (time() - last)) / 60)
        if left < 0 or last == 0 then left = 0 end
        if not pageConfirm then
            pageConfirm = true
            statusFS:SetText((left > 0 and ("Fast GetAll on cooldown ~" .. left .. " min. ") or
                "Fast GetAll unavailable now. ") ..
                "Press again for slow page-by-page scan (not good for bidding).")
            C_Timer.After(6, function() pageConfirm = false end)
            return
        end
        pageConfirm = false; cacheFromGetAll = false
        scanCache = {}; cheapItems = {}; UpdateTable()
        StartPageScan()
        return
    end
    pageConfirm = false; cacheFromGetAll = false
    attempted = {}; pending = {}; bidsSent = 0; bidsOK = 0; bidsFail = 0; bidWatch = bidWatch + 1
    focusItem = nil; focusReady = false; focusQuerying = false
    if CheapBidsDB then CheapBidsDB.lastGetAll = time() end
    scanCache = {}; cheapItems = {}; UpdateTable()
    scanToken = scanToken + 1
    local myToken = scanToken
    if not ITEM_QUALITY_COLORS[-1] then ITEM_QUALITY_COLORS[-1] = { r=0, g=0, b=0 } end
    scanMode = "getall"; isScanning = true; getAllPending = true
    UpdateButtons()
    SetProgress(0.05); statusFS:SetText("GetAll: downloading the whole auction house…")
    QueryAuctionItems("", nil, nil, 0, nil, nil, true, false, nil)
    C_Timer.After(90, function()
        if myToken == scanToken and scanMode == "getall" and getAllPending then
            FinishScan("GetAll did not respond in 90s. Try again.")
        end
    end)
end

StartPageScan = function()
    cacheFromGetAll = false
    scanMode = "page"; scanPage = 0; scanTotalPages = 1; isScanning = true
    UpdateButtons()
    SetProgress(0.01); statusFS:SetText("Page-by-page scan…")
    SafeQuery(function() QueryAuctionItems("", nil, nil, scanPage, nil, nil, false, false, nil) end)
end

local function PageScanUpdate()
    if scanMode ~= "page" then return end
    local numOnPage, total = GetNumAuctionItems("list")
    numOnPage = numOnPage or 0; total = total or 0
    if scanPage == 0 then scanTotalPages = math.max(1, math.ceil(total / PER_PAGE)) end
    for i = 1, numOnPage do ReadIndexInto(scanCache, i) end
    SetProgress((scanPage + 1) / scanTotalPages)
    statusFS:SetText(string.format("Scan page %d/%d, collected %d", scanPage + 1, scanTotalPages, #scanCache))
    if numOnPage >= PER_PAGE and (scanPage + 1) < scanTotalPages then
        scanPage = scanPage + 1
        SafeQuery(function() QueryAuctionItems("", nil, nil, scanPage, nil, nil, false, false, nil) end)
    else
        isScanning = false; scanMode = nil; HideProgress()
        statusFS:SetText(string.format("Scan done: %d lots.", #scanCache))
        ApplyFilter()
    end
end

-- ===== Bidding =====
-- TWO hard limits shape this:
--   1) PlaceAuctionBid works ONLY from a HARDWARE EVENT (a real click/keypress);
--      bids issued from timers or event handlers are silently dropped.
--   2) The full-scan (GetAll) snapshot goes STALE fast - after a few bids or a
--      little time, GetAuctionItemInfo("list", idx) no longer matches our cache,
--      so bidding straight off the snapshot fails ("no available lots").
-- So we bid like Auctionator/Auctioneer: re-query the ONE selected lot with a
-- small exact-match search (sorted by bid) to refresh the live list, then place
-- the bid from THAT fresh list inside the click. MatchInLive finds the exact lot.

-- Mark done + drop from the (small) filtered list. NEVER linear-scan scanCache
-- (it can hold 200k+ items -> "script ran too long").
local function RemoveItem(it)
    it.done = true
    if it == focusItem then focusItem = nil; focusReady = false end
    local removedIdx
    for i, v in ipairs(cheapItems) do if v == it then removedIdx = i; table.remove(cheapItems, i); break end end
    -- when the removed lot was the highlighted one, ADVANCE the highlight to the
    -- lot now occupying that slot (or the new last lot) instead of clearing it -
    -- so on confirm the selection visibly walks down and the next bid continues
    -- from here rather than jumping back to the top of the list.
    if it == selectedItem then
        if removedIdx and #cheapItems > 0 then
            local nextIdx = removedIdx > #cheapItems and #cheapItems or removedIdx
            selectedItem = cheapItems[nextIdx]
            ScrollToItem(selectedItem)
        else
            selectedItem = nil
        end
    end
end

-- Find the live-list index of the auction matching `it` (same item, count, prices
-- and not already led by us). Safe ONLY on a small list (a focused query result);
-- capped so it can never scan a 200k GetAll snapshot.
local function MatchInLive(it)
    local n = math.min(GetNumAuctionItems("list") or 0, 300)
    for i = 1, n do
        local name, _, cnt, _, _, _, _, minBid, minInc, buyout, bidAmt, high, _, _, _, _, itemID =
            GetAuctionItemInfo("list", i)
        if name and not high
           and (not it.itemID or itemID == it.itemID)
           and (cnt or 1) == (it.cnt or 1)
           and (buyout or 0) == (it.buyout or 0) then
            local eff = CalcBid(minBid, minInc, bidAmt)
            -- price may have moved since the scan; bid the CURRENT amount if it's still in range
            if PassesFilter(eff, buyout or 0) then return i, eff end
        end
    end
    return nil
end

-- Refresh the live list for one lot via a small exact-match query, sorted by bid
-- so our 1-99c lot lands on the first page. This replaces the GetAll snapshot in
-- "list" - fine, because the table shows our own cached copy, not the live list.
local function FocusQuery(it)
    if isScanning or not it or not it.name or it.name == "" then return end
    if focusItem == it and (focusQuerying or focusReady) then return end
    focusItem = it; focusReady = false; focusQuerying = true
    focusTok = focusTok + 1
    local tok, nm = focusTok, it.name
    SafeQuery(function()
        if focusItem ~= it then return end
        pcall(SortAuctionSetSort, "list", "bid", false)       -- best effort; must NOT block the query
        QueryAuctionItems(nm, nil, nil, 0, nil, nil, false, true, nil)   -- exact match, page 0
    end)
    -- safety: if no AUCTION_ITEM_LIST_UPDATE arrives, free the flag so a retry re-queries
    C_Timer.After(4, function()
        if tok == focusTok and focusQuerying and not focusReady then focusQuerying = false end
    end)
end

-- watchdog: if a sent bid gets no reply in 6s, free it (retryable)
local function ArmBidWatch()
    bidWatch = bidWatch + 1
    local tk = bidWatch
    C_Timer.After(6, function()
        if bidWatch ~= tk then return end
        for _, it in ipairs(pending) do attempted[it] = nil end
        pending = {}
        UpdateTable()
    end)
end

-- Drop one pending lot from the queue.
local function PopPending(it)
    for i, v in ipairs(pending) do if v == it then table.remove(pending, i); break end end
end

-- Confirm bids by GAME STATE, not by a localized chat string. After a bid the
-- client patches the snapshot so the lot we now lead reads highBidder=true
-- (field 12). We scan every pending lot and drop the ones we already lead. This
-- fires on AUCTION_ITEM_LIST_UPDATE (always) and on the bid-placed message, so a
-- placed bid removes its row regardless of client language.
local function ReconcileBids()
    if #pending == 0 then return end
    local snap = {}
    for _, it in ipairs(pending) do snap[#snap + 1] = it end
    for _, it in ipairs(snap) do
        local probe = it._bidIdx or it.idx
        if probe then
            local name, _, _, _, _, _, _, _, _, _, _, high, _, _, _, _, itemID =
                GetAuctionItemInfo("list", probe)
            if name and (not it.itemID or itemID == it.itemID) and high then
                PopPending(it)
                bidsOK = bidsOK + 1
                RemoveItem(it)              -- we lead this lot now -> bid went through
            end
        end
    end
    if actFS then actFS:SetText(string.format(
        "Placed: %d, rejected: %d, pending: %d.", bidsOK, bidsFail, #pending)) end
    UpdateTable()
end

-- Fallback: the server confirmed a bid by chat message but the snapshot hasn't
-- flipped highBidder yet -> accept the oldest pending bid as placed.
local function ConfirmOldest()
    local it = table.remove(pending, 1)
    if not it then return end
    bidsOK = bidsOK + 1
    RemoveItem(it)
    if actFS then actFS:SetText(string.format(
        "Placed: %d, rejected: %d, pending: %d.", bidsOK, bidsFail, #pending)) end
    UpdateTable()
end

-- server rejected the oldest pending bid (lot gone / internal error) -> retryable
local function RejectOldest()
    local it = table.remove(pending, 1)
    if not it then return end
    bidsFail = bidsFail + 1
    attempted[it] = nil
    if actFS then actFS:SetText(string.format(
        "Placed: %d, rejected by server: %d.", bidsOK, bidsFail)) end
    UpdateTable()
end

local function NoSnapshot()
    if actFS then actFS:SetText("Bidding unavailable: run a fresh \"scan auc\" (Auctioneer/Auctionator OFF).") end
end

-- client-side anti-spam: keep a minimum gap between real bids so a burst of
-- clicks / key-repeat doesn't trip the server flood guard ("Internal auction
-- error"). Only actual bids count - skipping/removing a lot is free.
local BID_MIN_INTERVAL = 0.3
local lastBidAt = 0

-- Place a real bid on ONE lot at a known live index. Must run inside a hardware
-- event (button / double-click / key binding).
local function PlaceOn(it, idx, eff)
    attempted[it] = true
    it._bidIdx = idx
    table.insert(pending, it)
    PlaceAuctionBid("list", idx, eff)        -- accepted because we're inside a click
    bidsSent = bidsSent + 1
    lastBidAt = GetTime and GetTime() or 0
    if actFS then actFS:SetText(string.format("Bid: %s (%s). Placed %d.", ItemName(it), FormatMoney(eff), bidsOK)) end
    UpdateTable()
    ArmBidWatch()
end

-- The GetAll snapshot indices DRIFT: as auctions sell/expire the live "list"
-- shifts, so a stored idx soon points at a DIFFERENT lot (proven via /cb debug:
-- want id=10513 @idx=24549 but the live list there held id=6712). So before
-- bidding, RE-FIND this exact lot near its old index by content (item + count +
-- buyout), and bid the CORRECTED live index. Bounded window so we never scan the
-- whole 200k snapshot. Returns correctedIndex, currentEff or nil.
local RELOCATE_WINDOW = 150
local function RelocateInLive(it)
    if not it.idx then return nil end
    local n = GetNumAuctionItems("list") or 0
    if n == 0 then return nil end
    local function matchAt(i)
        if i < 1 or i > n then return nil end
        local name, _, cnt, _, _, _, _, minBid, minInc, buyout, bidAmt, high, _, _, _, _, itemID =
            GetAuctionItemInfo("list", i)
        if not name or high then return nil end                 -- empty slot, or we already lead it
        if it.itemID and itemID ~= it.itemID then return nil end
        if (cnt or 1) ~= (it.cnt or 1) then return nil end
        if (buyout or 0) ~= (it.buyout or 0) then return nil end
        local eff = CalcBid(minBid, minInc, bidAmt)
        if not PassesFilter(eff, buyout or 0) then return nil end -- price moved out of the filter
        return eff
    end
    local eff = matchAt(it.idx)                                 -- fast path: index still valid
    if eff then return it.idx, eff end
    for d = 1, RELOCATE_WINDOW do                               -- drift: search outward from the old index
        eff = matchAt(it.idx + d); if eff then return it.idx + d, eff end
        eff = matchAt(it.idx - d); if eff then return it.idx - d, eff end
    end
    return nil
end

-- first lot at or after `fromIdx` in the filtered list that we haven't bid yet
local function NextUnattempted(fromIdx)
    for i = fromIdx, #cheapItems do
        local v = cheapItems[i]
        if not attempted[v] then return v end
    end
    return nil
end

-- diagnostic: dump what the LIVE "list" shows at a lot's cached idx, so we can
-- see WHY the selected lot is (not) biddable - snapshot replaced (liveN small),
-- re-sorted/desynced (id mismatch), already led (high=true), or uncached (nil).
local function BidDebug(tag, it)
    if not debugOn or not it then return end
    local liveN = GetNumAuctionItems("list") or 0
    local ln, li, lhigh, lbid, lbuy = "nil", "nil", "nil", "nil", "nil"
    if it.idx then
        local name, _, _, _, _, _, _, minBid, minInc, buyout, bidAmt, high, _, _, _, _, itemID =
            GetAuctionItemInfo("list", it.idx)
        ln = tostring(name); li = tostring(itemID); lhigh = tostring(high)
        lbid = tostring(CalcBid(minBid, minInc, bidAmt)); lbuy = tostring(buyout)
    end
    local ridx, reff = RelocateInLive(it)
    print(string.format("|cff66ccff[CB %s]|r want id=%s '%s' idx=%s | liveN=%s @idx: id=%s '%s' high=%s bid=%s buy=%s | relocate=%s eff=%s",
        tag, tostring(it.itemID), tostring(it.name), tostring(it.idx), tostring(liveN), li, ln, lhigh, lbid, lbuy,
        tostring(ridx), tostring(reff)))
end

-- Bid the SELECTED lot only. If that exact lot is gone from the live auction it
-- is REMOVED from the list with an "unavailable" message and NO bid is placed on
-- any other lot (asked for explicitly). Lots already bid are skipped, so repeated
-- clicks walk down to the next fresh lot; the highlight stays on the bid lot.
local function BidItem(it)
    if isScanning then return end
    ReadFilter()
    -- resolve the target: the selected lot, advancing past lots we've already bid
    local target = it
    if not target or attempted[target] then
        target = NextUnattempted(IndexOf(it) or 1)
    end
    if not target then
        if actFS then actFS:SetText("No fresh lot to bid - rescan when \"scan auc\" is green.") end
        return
    end
    selectedItem = target
    BidDebug("sel", target)                             -- why is the target (not) biddable?
    local idx, eff = RelocateInLive(target)
    if not idx then
        -- the selected lot is gone -> drop it, say so, and bid NOTHING else
        if actFS then actFS:SetText(ItemName(target) .. " - item unavailable, removed.") end
        RemoveItem(target)                              -- advances the highlight to the next surviving lot
        UpdateTable()
        return
    end
    local now = GetTime and GetTime() or 0              -- anti-spam gap between real bids
    if now > 0 and (now - lastBidAt) < BID_MIN_INTERVAL then
        if actFS then actFS:SetText("Too fast - slow down a touch (anti-spam).") end
        return
    end
    target.idx = idx
    PlaceOn(target, idx, eff)                           -- highlight stays on the bid lot (dimmed)
    ScrollToItem(target); UpdateTable()
end

local function DoSingleBid()
    if not uiBuilt then return end          -- hotkey pressed before AH ever opened
    if isScanning then return end
    if #cheapItems == 0 then if actFS then actFS:SetText("Run \"scan auc\" and search first.") end return end
    BidItem(selectedItem)
end

local function StopAll()
    if isScanning or scanMode then AbortScan() end
    UpdateButtons()
end

-- global wrapper so a Key Binding (a hardware event) can place a bid
function CheapBids_KeyBid() DoSingleBid() end

-- ===== Build UI =====

local function MakeBox(parent, w, maxd)
    local e = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    e:SetSize(w, 18); e:SetAutoFocus(false); e:SetNumeric(true); e:SetMaxLetters(maxd)
    e:SetScript("OnEscapePressed", function(s) s:ClearFocus() end)
    e:SetScript("OnEnterPressed",  function(s) s:ClearFocus() end)
    return e
end

local COIN_TEX = { g="Interface\\MoneyFrame\\UI-GoldIcon", s="Interface\\MoneyFrame\\UI-SilverIcon", c="Interface\\MoneyFrame\\UI-CopperIcon" }
local function MakeMoney(parent, anchor, xoff)
    local function coin(after, kind)
        local t = parent:CreateTexture(nil, "OVERLAY"); t:SetSize(13, 13)
        t:SetTexture(COIN_TEX[kind]); t:SetPoint("LEFT", after, "RIGHT", 1, 0); return t
    end
    local g = MakeBox(parent, 42, 6); g:SetPoint("LEFT", anchor, "RIGHT", xoff, 0)
    local gl = coin(g, "g")
    local s = MakeBox(parent, 22, 2); s:SetPoint("LEFT", gl, "RIGHT", 3, 0)
    local sl = coin(s, "s")
    local c = MakeBox(parent, 22, 2); c:SetPoint("LEFT", sl, "RIGHT", 3, 0)
    local cl = coin(c, "c")
    return { g = g, s = s, c = c, last = cl }
end

local PANEL_BACKDROP = {
    bgFile = "Interface/Tooltips/UI-Tooltip-Background",
    edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 16, insets = { left = 4, right = 4, top = 4, bottom = 4 },
}

-- column right-offsets (from row right edge): time, buyout, bid, cnt; name flexes
local C_BUY, C_BID, C_CNT, C_TIME = 96, 96, 38, 58

local function SetSortColumn(key)
    if sortKey == key then sortAsc = not sortAsc else sortKey = key; sortAsc = (key == "bid" or key == "name" or key == "time") end
    for k, ar in pairs(headerArrows) do
        if k == key then ar:Show(); ar:SetTexCoord(0, 0.5625, sortAsc and 0 or 1, sortAsc and 1 or 0)
        else ar:Hide() end
    end
    SortItems(); UpdateTable()
end

local function BuildTable()
    if fauxScroll or not listFrame then return end
    if (listFrame:GetWidth() or 0) < 50 or (listFrame:GetHeight() or 0) < 40 then return end

    -- header
    local hdr = CreateFrame("Frame", nil, listFrame)
    hdr:SetPoint("TOPLEFT", listFrame, "TOPLEFT", 2, -2)
    hdr:SetPoint("TOPRIGHT", listFrame, "TOPRIGHT", -18, -2)
    hdr:SetHeight(18)
    -- header background spans the FULL table width (symmetric left/right margins)
    local hbg = hdr:CreateTexture(nil, "BACKGROUND")
    hbg:SetPoint("TOPLEFT", listFrame, "TOPLEFT", 2, -2)
    hbg:SetPoint("BOTTOMRIGHT", listFrame, "TOPRIGHT", -2, -20)
    hbg:SetColorTexture(0.12, 0.12, 0.28, 0.95)

    local function headerBtn(key, text, anchorFn, just)
        local b = CreateFrame("Button", nil, hdr)
        anchorFn(b)
        local f = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        f:SetAllPoints(); f:SetJustifyH(just or "LEFT"); f:SetText(text)
        b:SetScript("OnClick", function() SetSortColumn(key) end)
        b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        return b
    end
    headerBtn("name", "Item", function(b) b:SetPoint("LEFT", hdr, "LEFT", 22, 0); b:SetPoint("RIGHT", hdr, "RIGHT", -(C_CNT+C_BID+C_BUY+C_TIME+14), 0); b:SetHeight(18) end, "LEFT")
    headerBtn("cnt", "Qty", function(b) b:SetPoint("RIGHT", hdr, "RIGHT", -(C_BID+C_BUY+C_TIME+10), 0); b:SetSize(C_CNT, 18) end, "LEFT")
    headerBtn("bid", "Bid", function(b) b:SetPoint("RIGHT", hdr, "RIGHT", -(C_BUY+C_TIME+6), 0); b:SetSize(C_BID, 18) end, "LEFT")
    headerBtn("buyout", "Buyout", function(b) b:SetPoint("RIGHT", hdr, "RIGHT", -(C_TIME+4), 0); b:SetSize(C_BUY, 18) end, "LEFT")
    headerBtn("time", "Time left", function(b) b:SetPoint("RIGHT", hdr, "RIGHT", 0, 0); b:SetSize(C_TIME, 18) end, "LEFT")
    -- vertical separators between the column headers
    local seps = { C_CNT+C_BID+C_BUY+C_TIME+14, C_BID+C_BUY+C_TIME+10, C_BUY+C_TIME+6, C_TIME+4 }
    for _, off in ipairs(seps) do
        local s = hdr:CreateTexture(nil, "ARTWORK")
        s:SetColorTexture(0.45, 0.45, 0.5, 0.7); s:SetWidth(1)
        s:SetPoint("TOP", hdr, "TOPRIGHT", -off, -2)
        s:SetPoint("BOTTOM", hdr, "BOTTOMRIGHT", -off, 2)
    end

    -- faux scroll
    fauxScroll = CreateFrame("ScrollFrame", "CheapBidsFaux", listFrame, "FauxScrollFrameTemplate")
    fauxScroll:SetPoint("TOPLEFT", hdr, "BOTTOMLEFT", 0, -1)
    fauxScroll:SetPoint("BOTTOMRIGHT", listFrame, "BOTTOMRIGHT", -18, 2)
    fauxScroll:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, ROW_H, UpdateTable)
    end)

    NUM_ROWS = math.max(1, math.floor((fauxScroll:GetHeight() or (ROW_H*15)) / ROW_H))
    for i = 1, NUM_ROWS do
        local r = CreateFrame("Button", nil, listFrame)
        r:SetHeight(ROW_H)
        r:SetPoint("TOPLEFT", hdr, "BOTTOMLEFT", 0, -1 - (i-1)*ROW_H)
        r:SetPoint("TOPRIGHT", hdr, "BOTTOMRIGHT", 0, -1 - (i-1)*ROW_H)
        local bg = r:CreateTexture(nil, "BACKGROUND"); bg:SetAllPoints()
        if i % 2 == 0 then bg:SetColorTexture(0.10,0.10,0.18,0.5) else bg:SetColorTexture(0.05,0.05,0.10,0.4) end
        local sel = r:CreateTexture(nil, "BORDER"); sel:SetAllPoints(); sel:SetColorTexture(1,0.82,0,0.30); sel:Hide()
        r:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        local icon = r:CreateTexture(nil, "ARTWORK"); icon:SetSize(16,16); icon:SetPoint("LEFT", r, "LEFT", 3, 0)
        local nameFS = r:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        nameFS:SetPoint("LEFT", icon, "RIGHT", 3, 0)
        nameFS:SetPoint("RIGHT", r, "RIGHT", -(C_CNT+C_BID+C_BUY+C_TIME+14), 0)
        nameFS:SetJustifyH("LEFT"); nameFS:SetWordWrap(false)
        local cntFS = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        cntFS:SetPoint("RIGHT", r, "RIGHT", -(C_BID+C_BUY+C_TIME+10), 0); cntFS:SetWidth(C_CNT); cntFS:SetJustifyH("CENTER")
        local bidFS = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        bidFS:SetPoint("RIGHT", r, "RIGHT", -(C_BUY+C_TIME+6), 0); bidFS:SetWidth(C_BID); bidFS:SetJustifyH("RIGHT")
        local buyFS = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        buyFS:SetPoint("RIGHT", r, "RIGHT", -(C_TIME+4), 0); buyFS:SetWidth(C_BUY); buyFS:SetJustifyH("RIGHT")
        local timeFS = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        timeFS:SetPoint("RIGHT", r, "RIGHT", -2, 0); timeFS:SetWidth(C_TIME); timeFS:SetJustifyH("RIGHT")
        r.icon, r.nameFS, r.cntFS, r.bidFS, r.buyFS, r.timeFS, r.sel = icon, nameFS, cntFS, bidFS, buyFS, timeFS, sel
        r:SetScript("OnClick", function(self)
            if self.item then selectedItem = self.item; UpdateTable() end
        end)
        r:SetScript("OnDoubleClick", function(self)
            if self.item then selectedItem = self.item; BidItem(self.item) end
        end)
        r:SetScript("OnEnter", function(self)
            if self.item and self.item.link then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetHyperlink(self.item.link); GameTooltip:Show()
            end
        end)
        r:SetScript("OnLeave", function() GameTooltip:Hide() end)
        tableRows[i] = r
    end
    UpdateTable()
end

local function BuildUI()
    if uiBuilt or not AuctionFrame then return end
    local bt = BackdropTemplateMixin and "BackdropTemplate" or nil

    content = CreateFrame("Frame", "CheapBidsContent", AuctionFrame)
    content:SetPoint("TOPLEFT", AuctionFrame, "TOPLEFT", 8, -22)
    content:SetPoint("BOTTOMRIGHT", AuctionFrame, "BOTTOMRIGHT", -32, 28)
    content:Hide()

    -- filter (two rows)
    local bidLbl = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    bidLbl:SetPoint("TOPLEFT", content, "TOPLEFT", 80, -26)
    bidLbl:SetWidth(84); bidLbl:SetJustifyH("RIGHT"); bidLbl:SetText("Bid from:")
    mBidMin = MakeMoney(content, bidLbl, 6)
    local bidTo = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    bidTo:SetPoint("LEFT", mBidMin.last, "RIGHT", 8, 0); bidTo:SetText("to:")
    mBidMax = MakeMoney(content, bidTo, 6)
    mBidMin.c:SetText("1"); mBidMax.c:SetText("99")

    local buyLbl = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    buyLbl:SetPoint("TOPRIGHT", bidLbl, "BOTTOMRIGHT", 0, -8)
    buyLbl:SetWidth(84); buyLbl:SetJustifyH("RIGHT"); buyLbl:SetText("Buyout from:")
    mBuyMin = MakeMoney(content, buyLbl, 6)
    local buyTo = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    buyTo:SetPoint("LEFT", mBuyMin.last, "RIGHT", 8, 0); buyTo:SetText("to:")
    mBuyMax = MakeMoney(content, buyTo, 6)

    -- left panel
    leftCol = CreateFrame("Frame", nil, content, bt)
    leftCol:SetPoint("TOPLEFT", content, "TOPLEFT", 7, -76)       -- +5px off the AH frame border
    leftCol:SetPoint("BOTTOMLEFT", content, "BOTTOMLEFT", 7, 7)   -- match table panel bottom
    leftCol:SetWidth(170)                                          -- shrink so the right edge stays put
    if leftCol.SetBackdrop then leftCol:SetBackdrop(PANEL_BACKDROP); leftCol:SetBackdropColor(0,0,0,0.55); leftCol:SetBackdropBorderColor(0.45,0.45,0.45) end

    scanBtn = CreateFrame("Button", nil, leftCol, "UIPanelButtonTemplate")
    scanBtn:SetSize(154, 26); scanBtn:SetPoint("TOP", leftCol, "TOP", 0, -8); scanBtn:SetText(SCAN_BTN)
    searchBtn = CreateFrame("Button", nil, leftCol, "UIPanelButtonTemplate")
    searchBtn:SetSize(154, 24); searchBtn:SetPoint("TOP", scanBtn, "BOTTOM", 0, -6); searchBtn:SetText("search"); searchBtn:SetEnabled(false)
    bidBtn = CreateFrame("Button", nil, leftCol, "UIPanelButtonTemplate")
    bidBtn:SetSize(154, 24); bidBtn:SetPoint("TOP", searchBtn, "BOTTOM", 0, -6); bidBtn:SetText("bid"); bidBtn:SetEnabled(false)
    stopBtn = CreateFrame("Button", nil, leftCol, "UIPanelButtonTemplate")
    stopBtn:SetSize(154, 22); stopBtn:SetPoint("TOP", bidBtn, "BOTTOM", 0, -6); stopBtn:SetText("cancel"); stopBtn:SetEnabled(false)

    progBar = CreateFrame("StatusBar", nil, leftCol)
    progBar:SetSize(154, 14); progBar:SetPoint("TOPLEFT", stopBtn, "BOTTOMLEFT", 0, -12)
    progBar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar"); progBar:SetStatusBarColor(0.2,0.6,1.0)
    progBar:SetMinMaxValues(0, 1); progBar:SetValue(0)
    local pbBg = progBar:CreateTexture(nil, "BACKGROUND"); pbBg:SetAllPoints(); pbBg:SetColorTexture(0,0,0,0.5)
    progBar.txt = progBar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); progBar.txt:SetPoint("CENTER", progBar, "CENTER", 0, 0)
    progBar:Hide()

    -- counters live UNDER the status bar
    cacheFS = leftCol:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    cacheFS:SetPoint("TOPLEFT", progBar, "BOTTOMLEFT", 0, -8); cacheFS:SetText("Cache: 0")
    foundFS = leftCol:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    foundFS:SetPoint("TOPLEFT", cacheFS, "BOTTOMLEFT", 0, -4); foundFS:SetText("Found: 0")

    -- time-left filter: 4 buckets the legacy AH actually exposes (no 24/48h split)
    local timeHdr = leftCol:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    timeHdr:SetPoint("TOPLEFT", foundFS, "BOTTOMLEFT", 0, -10); timeHdr:SetText("Time left:")
    local TIME_OPTS = { {1,"<30m"}, {2,"30m-2h"}, {3,"2-12h"}, {4,">12h"} }
    local timeChecks = {}
    for i, opt in ipairs(TIME_OPTS) do
        local cb = CreateFrame("CheckButton", nil, leftCol, "UICheckButtonTemplate")
        cb:SetSize(20, 20)
        if i == 1 then cb:SetPoint("TOPLEFT", timeHdr, "BOTTOMLEFT", 0, -4)
        elseif i == 2 then cb:SetPoint("LEFT", timeChecks[1], "LEFT", 78, 0)
        elseif i == 3 then cb:SetPoint("TOPLEFT", timeChecks[1], "BOTTOMLEFT", 0, -2)
        else cb:SetPoint("LEFT", timeChecks[3], "LEFT", 78, 0) end
        cb:SetChecked(true)
        cb.code = opt[1]
        local lbl = cb:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        lbl:SetPoint("LEFT", cb, "RIGHT", 1, 0); lbl:SetText(opt[2])
        cb:SetScript("OnClick", function(self)
            filter.times[self.code] = self:GetChecked() and true or false
            if #scanCache > 0 then ApplyFilter() end
        end)
        timeChecks[i] = cb
    end

    -- bid feedback lives under the checkboxes
    actFS = leftCol:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    actFS:SetPoint("TOPLEFT", timeChecks[3], "BOTTOMLEFT", 0, -12)
    actFS:SetWidth(162); actFS:SetJustifyH("LEFT"); actFS:SetWordWrap(true)

    -- right panel
    local rightPanel = CreateFrame("Frame", nil, content, bt)
    rightPanel:SetPoint("TOPLEFT", leftCol, "TOPRIGHT", 1, 0)         -- left edge 5px further left
    rightPanel:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", 23, 7)
    if rightPanel.SetBackdrop then rightPanel:SetBackdrop(PANEL_BACKDROP); rightPanel:SetBackdropColor(0.045,0.05,0.07,1); rightPanel:SetBackdropBorderColor(0.45,0.45,0.45) end

    listFrame = CreateFrame("Frame", "CheapBidsList", rightPanel)
    listFrame:SetPoint("TOPLEFT", rightPanel, "TOPLEFT", 8, -8)
    listFrame:SetPoint("BOTTOMRIGHT", rightPanel, "BOTTOMRIGHT", -8, 8)
    local lbg = listFrame:CreateTexture(nil, "BACKGROUND"); lbg:SetAllPoints(); lbg:SetColorTexture(0.045,0.05,0.07,1)

    -- system / scan status: top area, to the right of the "Bid from" row
    statusFS = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    statusFS:SetPoint("TOPLEFT", mBidMax.last, "TOPRIGHT", 16, 3)
    statusFS:SetPoint("TOPRIGHT", content, "TOPRIGHT", -8, 3)
    statusFS:SetJustifyH("LEFT"); statusFS:SetWordWrap(true)
    statusFS:SetText("Disable Auctioneer/Auctionator! scan auc -> filter -> search -> bid.")

    scanBtn:SetScript("OnClick", function()
        if isScanning then AbortScan(); return end
        if not (AuctionFrame and AuctionFrame:IsVisible()) then return end
        StartScan()
    end)
    searchBtn:SetScript("OnClick", function()
        if isScanning then return end
        if #scanCache == 0 then statusFS:SetText("Run \"" .. SCAN_BTN .. "\" first.") return end
        ApplyFilter()
    end)
    bidBtn:SetScript("OnClick", DoSingleBid)
    stopBtn:SetScript("OnClick", StopAll)

    uiBuilt = true
end

-- ===== Tab =====

-- Poll the server's GetAll gate so the player can SEE when a fresh scan is
-- allowed: the cooldown runs ~15-18 min and CanSendAuctionQuery is the ONLY
-- authority (our minute estimate is just a hint). Tints "scan auc" GREEN the
-- moment a GetAll is actually permitted, white while it is cooling down.
local readyToken = 0
local function PollGetAllReady()
    readyToken = readyToken + 1
    local tk = readyToken
    local function tick()
        if tk ~= readyToken then return end                          -- superseded by a newer poll
        if not (uiBuilt and AuctionFrame and AuctionFrame:IsVisible()
                and content and content:IsShown()) then return end   -- tab/AH closed -> stop the chain
        if not isScanning and scanBtn then
            local _, canAll = CanSendAuctionQuery()
            local fs = scanBtn:GetFontString()
            if canAll then
                scanBtn:SetText(SCAN_BTN)
                if fs then fs:SetTextColor(0.3, 1.0, 0.3) end            -- green = scan now
            else
                local last = (CheapBidsDB and CheapBidsDB.lastGetAll) or 0
                local left = last > 0 and (GETALL_COOLDOWN - (time() - last)) or 0
                if left > 0 then
                    scanBtn:SetText(string.format("%s  %d:%02d", SCAN_BTN, math.floor(left / 60), left % 60))
                else
                    scanBtn:SetText(SCAN_BTN)                            -- estimate elapsed, server still gating
                end
                if fs then fs:SetTextColor(1, 1, 1) end                 -- white = not ready yet
            end
        end
        C_Timer.After(2, tick)
    end
    tick()
end

local function ShowCB()
    if not content then return end
    if AuctionFrameBrowse then AuctionFrameBrowse:Hide() end
    if AuctionFrameBid then AuctionFrameBid:Hide() end
    if AuctionFrameAuctions then AuctionFrameAuctions:Hide() end
    content:Show()
    BuildTable()
    if not fauxScroll then C_Timer.After(0.05, BuildTable) end
    UpdateTable()
    if #cheapItems > 0 and not cacheFromGetAll and statusFS then
        statusFS:SetText("List from a previous scan. After reopening the AH the snapshot is stale - run \"scan auc\" again to bid.")
    end
    if myTabID then PanelTemplates_SetTab(AuctionFrame, myTabID) end
    PollGetAllReady()                       -- light up "scan auc" green when GetAll is available
end
local function HideCB() if content then content:Hide() end end

local function CreateTab()
    if myTabID or not AuctionFrame then return end
    BuildUI()
    local index = (AuctionFrame.numTabs or 3) + 1
    local tab = CreateFrame("Button", "AuctionFrameTab"..index, AuctionFrame, "AuctionTabTemplate")
    tab:SetID(index); tab:SetText("CheapBids")
    tab:SetPoint("LEFT", _G["AuctionFrameTab"..(index-1)], "RIGHT", -15, 0)
    PanelTemplates_SetNumTabs(AuctionFrame, index)
    PanelTemplates_EnableTab(AuctionFrame, index)
    PanelTemplates_TabResize(tab, 0)
    myTabID = index
    hooksecurefunc("AuctionFrameTab_OnClick", function(self, _, _, idx)
        idx = idx or (self and self.GetID and self:GetID())
        if idx == myTabID then ShowCB() else HideCB() end
    end)
end

-- ===== Events =====

ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("AUCTION_HOUSE_SHOW")
ev:RegisterEvent("AUCTION_HOUSE_CLOSED")
ev:RegisterEvent("AUCTION_ITEM_LIST_UPDATE")

ev:SetScript("OnEvent", function(_, event, arg1, arg2)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        CheapBidsDB = CheapBidsDB or {}
        print("|cff00cc00[CheapBids]|r loaded. IMPORTANT: disable Auctioneer/Auctionator to bid.")
    elseif event == "AUCTION_HOUSE_SHOW" then
        CreateTab()
        ev:RegisterEvent("CHAT_MSG_SYSTEM")
        ev:RegisterEvent("UI_ERROR_MESSAGE")
    elseif event == "AUCTION_HOUSE_CLOSED" then
        if isScanning or scanMode then FinishScan() end
        cacheFromGetAll = false; scanMode = nil; HideProgress()
        pending = {}; bidWatch = bidWatch + 1
        focusItem = nil; focusReady = false; focusQuerying = false
        ev:UnregisterEvent("CHAT_MSG_SYSTEM")
        ev:UnregisterEvent("UI_ERROR_MESSAGE")
    elseif event == "CHAT_MSG_SYSTEM" then
        if arg1 == BID_OK then                             -- a bid was placed (coin sound)
            local before = #pending
            ReconcileBids()                                -- prefer game-state confirmation
            if #pending == before then ConfirmOldest() end -- snapshot lagged -> trust the message
        end
    elseif event == "UI_ERROR_MESSAGE" then
        local msg = arg2 or arg1
        if msg == AUC_ERR and #pending > 0 then RejectOldest() end   -- bid rejected (lot gone)
    elseif event == "AUCTION_ITEM_LIST_UPDATE" then
        if scanMode == "getall" and getAllPending then
            getAllPending = false
            local total = GetNumAuctionItems("list") or 0
            SetProgress(0.1); statusFS:SetText("Received " .. total .. " lots, processing…")
            ProcessGetAll(1, total)
        elseif scanMode == "page" then PageScanUpdate()
        else
            if focusQuerying then
                focusQuerying = false; focusReady = true     -- focused list ready
                if actFS and focusItem then actFS:SetText("Ready - press bid for " .. ItemName(focusItem)) end
            end
            if #pending > 0 then ReconcileBids() end          -- snapshot changed after a bid -> confirm
        end
    end
end)

-- diagnostic: log every PlaceAuctionBid (native or ours) so the default bid path
-- can be compared with ours (enable with /cb debug)
hooksecurefunc("PlaceAuctionBid", function(atype, index, bid)
    if not debugOn then return end
    local nb, total = GetNumAuctionItems(atype)
    local name = GetAuctionItemInfo(atype, index)
    local link = GetAuctionItemLink(atype, index)
    print(string.format("|cff66ccff[CB debug]|r PlaceAuctionBid(%s, idx=%s, bid=%s) | listN=%s/%s | name=%s | link=%s",
        tostring(atype), tostring(index), tostring(bid), tostring(nb), tostring(total), tostring(name), tostring(link)))
end)

-- ===== Slash =====

SLASH_CHEAPBIDS1 = "/cb"
SLASH_CHEAPBIDS2 = "/cheapbids"
SlashCmdList["CHEAPBIDS"] = function(arg)
    arg = (arg or ""):lower():gsub("%s", "")
    if arg == "debug" then
        debugOn = not debugOn
        print("|cff00cc00[CheapBids]|r bid diagnostics: " .. (debugOn and "ON" or "off") ..
            ". Now place a bid normally and via CheapBids - compare the [CB debug] lines.")
        return
    end
    if myTabID and _G["AuctionFrameTab"..myTabID] then _G["AuctionFrameTab"..myTabID]:Click()
    else print("|cffff4444[CheapBids]|r Open the auction house first.") end
end
