-- ===========================================================================
-- CheapBids - modern auction house backend (WoW Forever)
-- ---------------------------------------------------------------------------
-- Loaded ONLY by CheapBids_Camelot.toc, before CheapBids.lua. TBC Anniversary
-- reads CheapBids.toc and never sees this file, so its legacy path is untouched.
--
-- CheapBids.lua talks to the auction house through ONE adapter table (`AH`). On
-- TBC that table wraps the legacy calls (GetAuctionItemInfo, PlaceAuctionBid...).
-- Here we publish the same calls, built on C_AuctionHouse:
--   * "list"   = the full-scan snapshot from C_AuctionHouse.ReplicateItems (the
--                modern GetAll; 0-based on the client, 1-based for the caller).
--   * "bidder" = C_AuctionHouse.GetBids() (my bids).
-- The big difference: a modern bid needs an auctionID, and a full scan does not
-- carry one. So each cheap lot is RESOLVED by an item search (SendSearchQuery ->
-- ITEM_SEARCH_RESULTS_UPDATED -> GetItemSearchResultInfo), matched by quantity +
-- buyout. Searches run in the background in list order (throttled), and a bid
-- click on a not-yet-resolved lot just moves it to the front of the queue.
--
-- License: GNU GPL v2 or later, see LICENSE.
-- ===========================================================================

local CAH = C_AuctionHouse
if not (CAH and CAH.ReplicateItems and CAH.PlaceBid) then return end   -- not a modern AH client

local M = { modern = true }
CheapBidsModern = M

local REPLICATE_COOLDOWN = 900        -- 15 min, account-wide (warcraft.wiki.gg ReplicateItems)
local SEARCH_GAP = 0.7                -- <= ~85 searches/min, under the 100/min server limit
local SEARCH_TIMEOUT = 6
local MAX_MORE = 4                    -- extra result pages per search

M.events = { "REPLICATE_ITEM_LIST_UPDATE", "BIDS_UPDATED" }

-- ---- item info (the bare globals are gone on modern clients) ---------------
local CItem = C_Item
function M.ItemInfo(...)
    if CItem and CItem.GetItemInfo then return CItem.GetItemInfo(...) end
    if GetItemInfo then return GetItemInfo(...) end
end
function M.ItemInfoInstant(...)
    if CItem and CItem.GetItemInfoInstant then return CItem.GetItemInfoInstant(...) end
    if GetItemInfoInstant then return GetItemInfoInstant(...) end
end

function M.Host() return AuctionHouseFrame end

-- ---- snapshot / bids read API (legacy-shaped) ------------------------------
local bids = {}                       -- cached C_AuctionHouse.GetBids()
local function ReadBids()
    local ok, list = pcall(CAH.GetBids)
    bids = (ok and type(list) == "table") and list or {}
    return bids
end

local function ItemIDOf(key) return key and key.itemID end

-- Enum.AuctionHouseTimeLeftBand is 0..3 (Short..VeryLong); legacy codes are 1..4.
local function Band(b) if type(b) == "number" then return b + 1 end end

function M.Num(list)
    if list == "bidder" then return #ReadBids() end
    local n = CAH.GetNumReplicateItems and CAH.GetNumReplicateItems() or 0
    return n, n
end

-- Same 17 leading values as the legacy GetAuctionItemInfo, so CheapBids.lua reads
-- both clients with one destructuring line.
function M.Info(list, i)
    if list == "bidder" then
        local b = bids[i]
        if not b then return end
        local id = ItemIDOf(b.itemKey)
        local name, _, q = M.ItemInfo(b.itemLink or id)
        local tex = id and select(5, M.ItemInfoInstant(id))
        -- minBid IS the next acceptable bid here; report bidAmount 0 so CalcBid keeps it
        return name or b.itemLink or "", tex, 1, q, true, 0, nil,
               b.minBid or 0, 0, b.buyoutAmount or 0, 0,
               (b.bidder ~= nil and b.bidder == UnitGUID("player")), nil, nil, nil, 0, id
    end
    return CAH.GetReplicateItemInfo(i - 1)
end

function M.TimeLeft(list, i)
    if list == "bidder" then return Band(bids[i] and bids[i].timeLeft) end
    if CAH.GetReplicateItemTimeLeft then
        local ok, t = pcall(CAH.GetReplicateItemTimeLeft, i - 1)
        if ok then return Band(t) end
    end
end

function M.Link(list, i)
    if list == "bidder" then return bids[i] and bids[i].itemLink end
    if CAH.GetReplicateItemLink then return CAH.GetReplicateItemLink(i - 1) end
end

-- second value = may a FULL scan be sent now (cooldown estimate; the server has no query)
function M.CanQuery()
    local last = (CheapBidsDB and CheapBidsDB.lastGetAll) or 0
    return true, (time() - last) >= REPLICATE_COOLDOWN
end

-- legacy QueryAuctionItems(..., getAll=7th arg): only the full scan exists here
function M.Query(_, _, _, _, _, _, getAll)
    if getAll then
        M.aidByIdx = {}; M.claimed = {}
        CAH.ReplicateItems()
    end
end

function M.QueryBids()
    if CAH.QueryBids then pcall(CAH.QueryBids, {}, {}) end
    ReadBids()
end

-- ---- background lot resolver (auctionID lookup) ----------------------------
M.aidByIdx = {}                       -- snapshot idx -> auctionID (what Bid("list", idx) uses)
M.claimed = {}                        -- auctionIDs already matched to a lot
local api = nil                       -- callbacks from CheapBids.lua (M.Bind)
local queue, queued = {}, {}          -- itemIDs waiting for a search
local searching = nil                 -- { id, key, t, more }
local lastSearchAt = 0
local SORTS = { { sortOrder = Enum and Enum.AuctionHouseSortOrder and Enum.AuctionHouseSortOrder.Price or 0, reverseSort = false } }

function M.Bind(t) api = t end

local function IsCommodity(id)
    if not (CAH.GetItemCommodityStatus and Enum and Enum.ItemCommodityStatus) then return false end
    local ok, st = pcall(CAH.GetItemCommodityStatus, id)
    return ok and st == Enum.ItemCommodityStatus.Commodity
end

local function Enqueue(id, front)
    if not id or id == 0 then return end
    if searching and searching.id == id then return end
    if queued[id] then
        if not front then return end
        for i, v in ipairs(queue) do if v == id then table.remove(queue, i); break end end
    end
    queued[id] = true
    if front then table.insert(queue, 1, id) else queue[#queue + 1] = id end
end

-- Match the search results of item `id` to our lots of that item (quantity + buyout,
-- nearest bid), assign each lot its own auctionID, flag the rest as gone.
local function MatchResults(id, results)
    local lots = api and api.lots() or {}
    for _, it in ipairs(lots) do
        if it.itemID == id and not it._aid then
            local best, bestScore
            for _, r in ipairs(results) do
                if r.auctionID and not M.claimed[r.auctionID]
                   and (r.quantity or 1) == (it.cnt or 1)
                   and (r.buyoutAmount or 0) == (it.buyout or 0) then
                    local score = math.abs((r.minBid or 0) - (it.bid or 0))
                    if not bestScore or score < bestScore then best, bestScore = r, score end
                end
            end
            if best then
                M.claimed[best.auctionID] = true
                it._aid = best.auctionID
                it._next = (best.minBid and best.minBid > 0) and best.minBid or it.bid
                it._led = (best.bidder ~= nil and best.bidder == UnitGUID("player"))
                it.timeLeft = Band(best.timeLeft) or it.timeLeft
                it._nf = nil
                if it.idx then M.aidByIdx[it.idx] = best.auctionID end
            else
                it._nf = true                  -- sold / outbid away since the scan
            end
        end
    end
    if api then api.redraw() end
end

local function FinishSearch(key)
    local id = searching and searching.id
    local results = {}
    local n = CAH.GetNumItemSearchResults and CAH.GetNumItemSearchResults(key) or 0
    for i = 1, n do
        local ok, r = pcall(CAH.GetItemSearchResultInfo, key, i)
        if ok and r then results[#results + 1] = r end
    end
    searching = nil
    if id then MatchResults(id, results) end
end

local function SendNext()
    if searching or #queue == 0 then return end
    local now = GetTime()
    if now - lastSearchAt < SEARCH_GAP then return end
    if CAH.IsThrottledMessageSystemReady and not CAH.IsThrottledMessageSystemReady() then return end
    local id = table.remove(queue, 1); queued[id] = nil
    if IsCommodity(id) then
        for _, it in ipairs(api and api.lots() or {}) do if it.itemID == id then it._commodity = true end end
        return
    end
    local key = CAH.MakeItemKey(id)
    searching = { id = id, key = key, t = now, more = 0 }
    lastSearchAt = now
    local ok = pcall(CAH.SendSearchQuery, key, SORTS, true)
    if not ok then searching = nil end
end

-- the pump runs only while the auction house is open
local pumpOn = false
local function Pump()
    if not pumpOn then return end
    if searching and (GetTime() - searching.t) > SEARCH_TIMEOUT then
        local id = searching.id; searching = nil
        Enqueue(id)                    -- no answer: retry later
    end
    SendNext()
    C_Timer.After(0.2, Pump)
end

-- queue every visible lot in display order (called after each filter pass)
function M.Prefetch()
    if not api then return end
    for _, it in ipairs(api.lots()) do
        if not it._aid and not it._nf and not it._commodity then Enqueue(it.itemID) end
    end
end

-- forget a lot's auctionID (its bid was rejected): look it up again
function M.Invalidate(idx)
    if not (idx and api) then return end
    local aid = M.aidByIdx[idx]
    for _, it in ipairs(api.lots()) do
        if it.idx == idx then
            it._aid = nil; it._nf = nil
            if aid then M.claimed[aid] = nil end
            M.aidByIdx[idx] = nil
            Enqueue(it.itemID, true)
            return
        end
    end
end

-- RelocateInLive replacement: returns idx, eff when the lot is bid-ready; nil when it
-- is gone (3rd value: we already lead it); nil, nil, false, msg = wait, keep the lot.
function M.Relocate(it, skipFilter, PassesFilter)
    if it._commodity then
        return nil, nil, false, "Commodity (no bids here) - buy it in the Blizzard Buy tab."
    end
    if it._aid then
        if it._led then return nil, nil, true end
        local eff = it._next or it.bid
        if not skipFilter and not PassesFilter(eff, it.buyout or 0) then return nil end
        return it.idx, eff
    end
    if it._nf then return nil end
    Enqueue(it.itemID, true)
    return nil, nil, false, "Locating this lot on the server - press again in a moment."
end

-- Some modern realms take bids in whole silver only and silently drop copper.
local function Amount(v)
    v = math.floor(v or 0)
    if CAH.SupportsCopperValues and not CAH.SupportsCopperValues() then v = math.ceil(v / 100) * 100 end
    return v
end

-- PlaceAuctionBid replacement. Must run inside a hardware event (a click), like legacy.
function M.Bid(list, idx, amount)
    local aid
    if list == "bidder" then aid = bids[idx] and bids[idx].auctionID
    else aid = M.aidByIdx[idx] end
    if not aid then return end
    CAH.PlaceBid(aid, Amount(amount))
end

-- auction errors that mean "this bid did not land" (the legacy client only had one)
local BID_ERRORS = {}
for _, k in ipairs({ "ERR_AUCTION_DATABASE_ERROR", "ERR_AUCTION_HIGHER_BID", "ERR_ITEM_NOT_FOUND",
                     "ERR_AUCTION_BID_OWN", "ERR_NOT_ENOUGH_MONEY", "ERR_AUCTION_BID_INCREMENT",
                     "ERR_AUCTION_MIN_BID" }) do
    if _G[k] then BID_ERRORS[_G[k]] = true end
end
-- pure check; the caller (CheapBids.lua) knows WHICH lot was rejected and calls M.Invalidate
function M.IsBidError(msg)
    return BID_ERRORS[msg] and true or false
end

-- ---- auction house tab -------------------------------------------------------
-- A tab button next to Blizzard's own tabs. Showing our panel switches the frame to
-- an empty display mode (Blizzard's panels hide); any Blizzard tab click calls
-- SetDisplayMode again, which our post-hook uses to hide the panel.
local ownMode = false
function M.HideOthers()
    local f = AuctionHouseFrame
    if f and f.SetDisplayMode then
        ownMode = true; pcall(f.SetDisplayMode, f, {}); ownMode = false
    end
end

function M.CreateTab(content, onShow, onHide)
    local f = AuctionHouseFrame
    if not f then return nil end
    local tabs = f.Tabs or {}
    local ok, tab = pcall(CreateFrame, "Button", "CheapBidsAHTab", f, "AuctionHouseFrameDisplayModeTabTemplate")
    if not ok or not tab then
        tab = CreateFrame("Button", "CheapBidsAHTab", f, "UIPanelButtonTemplate")
        tab:SetSize(96, 22)
    end
    tab:SetText("CheapBids")
    local last = tabs[#tabs]
    if last then tab:SetPoint("LEFT", last, "RIGHT", 3, 0)
    else tab:SetPoint("TOPLEFT", f, "BOTTOMLEFT", 20, 2) end
    if PanelTemplates_TabResize then pcall(PanelTemplates_TabResize, tab, 0) end
    local function Mark(selected)
        if selected then
            for _, t in ipairs(tabs) do if PanelTemplates_DeselectTab then pcall(PanelTemplates_DeselectTab, t) end end
            if PanelTemplates_SelectTab then pcall(PanelTemplates_SelectTab, tab) end
        elseif PanelTemplates_DeselectTab then
            pcall(PanelTemplates_DeselectTab, tab)
        end
    end
    tab:SetScript("OnClick", function()
        if PlaySound and SOUNDKIT then pcall(PlaySound, SOUNDKIT.IG_CHARACTER_INFO_TAB) end
        onShow()                       -- switches Blizzard's panels off first (HideOthers)
        Mark(true)
    end)
    if f.SetDisplayMode then
        hooksecurefunc(f, "SetDisplayMode", function()
            if ownMode then return end
            Mark(false)
            onHide()
        end)
    end
    Mark(false)
    return 1
end

-- ---- events -----------------------------------------------------------------
local ev = CreateFrame("Frame")
ev:RegisterEvent("AUCTION_HOUSE_SHOW")
ev:RegisterEvent("AUCTION_HOUSE_CLOSED")
ev:RegisterEvent("ITEM_SEARCH_RESULTS_UPDATED")
ev:SetScript("OnEvent", function(_, event, a1)
    if event == "AUCTION_HOUSE_SHOW" then
        if not pumpOn then pumpOn = true; Pump() end
    elseif event == "AUCTION_HOUSE_CLOSED" then
        pumpOn = false
        searching = nil; queue = {}; queued = {}
    elseif event == "ITEM_SEARCH_RESULTS_UPDATED" then
        if not (searching and ItemIDOf(a1) == searching.id) then return end
        if CAH.HasFullItemSearchResults and not CAH.HasFullItemSearchResults(a1)
           and searching.more < MAX_MORE and CAH.RequestMoreItemSearchResults then
            searching.more = searching.more + 1
            searching.t = GetTime()
            pcall(CAH.RequestMoreItemSearchResults, a1)
            return
        end
        FinishSearch(a1)
    end
end)
