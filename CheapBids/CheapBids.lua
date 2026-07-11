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
local GETALL_COOLDOWN = 940       -- ~15:40 observed; only a hint for the countdown,
                                  -- CanSendAuctionQuery (green button) is the real gate
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
local floodMode = false              -- a real flood -> throttled token-bucket bidding; cleared on AH reopen
local floodAnchor = 0                -- token-bucket baseline: 1 bid earned per FLOOD_LOCK since this time
local FLOOD_LOCK = 2.0               -- flood mode: avg 1 bid / this many seconds (waiting banks bids)
local lockTok = 0                    -- token to invalidate stale button re-enable timers
local prevErrAt = 0                  -- time of the previous auction error (to detect a flood cluster)
local FLOOD_WINDOW = 3.0             -- two errors within this window = a real flood (not a stale lot)

local uiBuilt, myTabID = false, nil
local selectedItem = nil
local sortKey, sortAsc = "bid", true

local myBids = {}                    -- live "bidder" list: every auction I currently bid on
local viewMode = "scan"              -- "scan" = scan results | "bids" = live my-bids view
local bidsPollToken = 0              -- cancels the my-bids auto-refresh ticker when the view / AH closes
local alwaysRedTarget = true         -- my-bids: keep the highlight on OUTBID (red) lots only (checkbox, default ON)
local autoScanBids = true            -- my-bids: auto-refresh outbid lots into the table 1/s (checkbox, default ON)
local priceProtect = true            -- market-based protection (checkbox, default ON): confirm popup + never auto-target a lot whose bid exceeds ~70% of its market value (or 100g when unpriced); OFF = fast rebid
local bidsDismissed = {}             -- my-bids: lots right-clicked to hide (keyed by _key); reset on entry

-- times: which of the 4 legacy time-left buckets to show (all on by default)
-- quality: nil = All rarities; 0..4 = show ONLY this rarity (Poor..Epic)
local filter = { bidMin = 1, bidMax = 99, buyMin = nil, buyMax = nil,
                 quality = nil,
                 times = { [1] = true, [2] = true, [3] = true, [4] = true } }

-- "Auc min price" DB (Auctionator-style): itemID -> lowest per-UNIT buyout (copper)
-- seen across the last full GetAll. Persisted in CheapBidsDB.priceDB, overwritten on
-- each GetAll. `scanPriceDB` is the in-progress accumulator during a scan; it is
-- committed to `priceDB` (and the SavedVariable) only when the scan completes, so the
-- previous prices survive until fresh ones are ready. Only GetAll fills it (a partial
-- page scan must not clobber the whole-market minimums).
local priceDB = {}
local scanPriceDB = nil
-- how many lots (with a buyout) of each itemID the last GetAll saw. A market minimum is
-- only trustworthy with >=2 lots; with a single lot we cannot really estimate the price,
-- so price protection falls back to a flat cap. Persisted in CheapBidsDB.priceCount.
local priceCount = {}
local scanPriceCount = nil

-- UI refs
local content, leftCol, listFrame, statusFS, actFS, foundFS, cacheFS, progBar
local BTN = {}   -- scan/search/bid/stop/myBids/buy/disLoot buttons in ONE table (Lua 5.1 caps a chunk at 200 locals)
local disLootView = false            -- table currently shows the "Dis. loot" (buy+disenchant profit) view
local mBidMin, mBidMax, mBuyMin, mBuyMax
local fauxScroll, tableRows, headerArrows = nil, {}, {}
local NUM_ROWS = 0
-- adaptive column sizing: refs filled by BuildTable, driven by MeasureColumns (forward-declared
-- so UpdateTable can call it; the real body is defined after the width constants).
local tableHdr, headerBtns, sepTex, measureFS = nil, {}, {}, nil
local MeasureColumns, ResetColumnHiWater

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

-- Price protection is MARKET-BASED (not a flat 5g). A lot is "big" - it needs an explicit
-- player confirm AND is never auto-targeted by the bid-spam advance - when the bid exceeds
-- a ceiling derived from the item's real market value:
--   ceiling = protectFraction (default 70%) * AucMin-per-unit * stack size,
-- but ONLY when the last GetAll saw >=2 lots of that item (so the minimum is a real market
-- floor, not just this single lot). With <2 lots / no scan we cannot judge the price, so we
-- fall back to a flat cap (protectFallback, default 100g). Tunables live in CheapBidsDB and
-- are editable from the in-game options panel; the defaults apply until changed.
local DEF_PROTECT_FRACTION = 0.70
local DEF_PROTECT_FALLBACK = 100 * 10000    -- 100g
local function ProtectFraction() local v = CheapBidsDB and CheapBidsDB.protectFraction; return (type(v)=="number" and v>0) and v or DEF_PROTECT_FRACTION end
local function ProtectFallback() local v = CheapBidsDB and CheapBidsDB.protectFallback; return (type(v)=="number" and v>0) and v or DEF_PROTECT_FALLBACK end
local function ProtectThreshold(it)
    if it and it.itemID and it.itemID ~= 0 then
        local unit = priceDB[it.itemID]
        local cnt  = priceCount[it.itemID]
        if unit and unit > 0 and cnt and cnt >= 2 then
            return ProtectFraction() * unit * (it.cnt or 1)
        end
    end
    return ProtectFallback()
end
-- Both gates obey the "Price protection" checkbox: OFF -> any lot is auto-targetable
-- (IsBig false) AND places with no confirm popup (NeedsConfirm false) = fast rebid.
local function IsBig(it) return priceProtect and it and (it.bid or 0) > ProtectThreshold(it) end
local function NeedsConfirm(it, amount) return priceProtect and it and (amount or 0) > ProtectThreshold(it) end

local function BoxNum(e) local x = e:GetText(); if not x or x == "" then return 0 end return tonumber(x) or 0 end
local function MoneyCopper(w) return BoxNum(w.g)*10000 + BoxNum(w.s)*100 + BoxNum(w.c) end
local function MoneyHasValue(w) return w.g:GetText() ~= "" or w.s:GetText() ~= "" or w.c:GetText() ~= "" end

local function CalcBid(minBid, minInc, bidAmt)
    if bidAmt and bidAmt > 0 then return bidAmt + (minInc or 0) end
    return minBid or 0
end

local function ReadFilter()
    if not mBidMin then return end          -- UI not built (headless test): keep the set filter
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

-- Quality used for the rarity filter. The GetAll snapshot's own quality field
-- (GetAuctionItemInfo #4) is UNRELIABLE for items not yet in the local cache - the
-- same lag that loads names late during a full scan - so prefer GetItemInfo's
-- quality (#3), the SAME source as the colored link the player sees, and memoize
-- it on it.q. Fall back to the snapshot value only until the template is cached.
local function ItemQuality(it)
    if it.q ~= nil then return it.q end
    if it.itemID and it.itemID ~= 0 then
        local q = select(3, GetItemInfo(it.itemID))     -- nil while uncached (also kicks off the load)
        if q then it.q = q; return q end
    end
    return it.qual
end

-- rarity filter: nil = All; otherwise the lot's quality must match exactly (0..4)
local function QualityShown(it)
    if filter.quality == nil then return true end
    return ItemQuality(it) == filter.quality
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
    return "|cff888888(loading...)|r"
end

-- A real, chat-insertable hyperlink for the lot, or nil if none resolves yet. (ItemName
-- may hand back a bare name / "loading" string, which a chat edit box can't turn into a
-- clickable link - this returns only a proper |Hitem:..|h link.)
local function ItemLink(it)
    if it.link and it.link ~= "" then return it.link end
    if it.itemID and it.itemID ~= 0 then
        local _, l = GetItemInfo(it.itemID)
        if l then it.link = l; return l end
    end
    return nil
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

-- generic input throttle: returns true = "fired too soon, bail". Guards the heavy
-- filter/sort handlers from autoclicker / held-key spam the same way BidItem
-- guards bids. Keyed so different controls don't starve each other.
local throttleAt = {}
local function Throttled(key, interval)
    local now = GetTime and GetTime() or 0
    if now == 0 then return false end                       -- no clock yet -> don't block
    if (now - (throttleAt[key] or 0)) < interval then return true end
    throttleAt[key] = now
    return false
end

-- ===== Table =====

-- which list the table currently shows: scan results or the my-bids view
local function ActiveList() return viewMode == "bids" and myBids or cheapItems end

-- lowest per-UNIT market buyout for a lot's item (copper), from the last GetAll; nil if
-- unknown. This is the Auctionator-style "what does this item really cost" reference,
-- independent of THIS lot's own (maybe missing/inflated) buyout.
local function AucUnit(it)
    if not it or not it.itemID or it.itemID == 0 then return nil end
    local p = priceDB[it.itemID]
    if p and p > 0 then return p end
    return nil
end

-- Expected reagent value of disenchanting ONE item of this lot (copper), via the
-- Disenchant module's bridge (CheapBidsPublic.DisenchantValue - present only when the
-- CheapBids_Disenchant addon is loaded). Memoized per lot: it._dev = false remembers a
-- FINAL "not disenchantable / nothing priced" verdict; while the item's GetItemInfo is
-- still loading (known=false) nothing is memoized, so a later pass can retry.
local function DisValue(it)
    if it._dev ~= nil then
        if it._dev == false then return nil end
        return it._dev
    end
    local f = CheapBidsPublic and CheapBidsPublic.DisenchantValue
    if not f or not it.itemID or it.itemID == 0 then return nil end
    local v, known = f(it.itemID)
    if known then it._dev = v or false end
    return v
end

-- profit of "buy out + disenchant" for the whole lot: reagent EV x stack - buyout.
-- nil when it cannot be judged (no buyout / no DE data yet / not disenchantable).
local function DisProfit(it)
    if not it or not it.buyout or it.buyout <= 0 then return nil end
    local v = DisValue(it)
    if not v then return nil end
    return v * (it.cnt or 1) - it.buyout
end

-- does a BUYOUT of this lot need the protection popup? A lot whose reagent EV covers
-- the buyout (dis-loot economics) is market-justified - no popup; anything else falls
-- under the normal market-ceiling protection.
local function BuyGuarded(it)
    local p = DisProfit(it)
    if p and p > 0 then return false end
    return NeedsConfirm(it, it.buyout)
end

-- may the spam-advance (RemoveItem walk-down, RejectOldest pull-back) auto-land on this
-- lot? The predicate must match the CURRENT flow: the bid flow skips lots above the
-- market ceiling (IsBig, bid-based), the dis-loot/buy flow skips lots that would raise
-- the BUY popup. Using bid-based IsBig for buys made the highlight hop up and down
-- (advance skipped big-bid lots that NextBuyable then happily targeted).
local function AutoTargetable(it)
    if disLootView then return (it.buyout or 0) > 0 and not BuyGuarded(it) end
    return not IsBig(it)
end

local function SortItems()
    table.sort(ActiveList(), function(a, b)
        local va, vb
        if sortKey == "name" then va, vb = (a.name or ""), (b.name or "")
        elseif sortKey == "seller" then va, vb = (a.owner or ""), (b.owner or "")
        elseif sortKey == "cnt" then va, vb = a.cnt, b.cnt
        elseif sortKey == "rarity" then va, vb = (ItemQuality(a) or -1), (ItemQuality(b) or -1)
        elseif sortKey == "buyout" then va, vb = a.buyout, b.buyout
        elseif sortKey == "aucmin" then
            if disLootView then                             -- header reads "Dis. profit" here
                va, vb = (DisProfit(a) or -math.huge), (DisProfit(b) or -math.huge)
            else                                            -- sort by the displayed LOT value (unit x stack)
                local ua, ub = AucUnit(a), AucUnit(b)
                va = ua and ua * (a.cnt or 1) or -1
                vb = ub and ub * (b.cnt or 1) or -1
            end
        elseif sortKey == "time" then va, vb = (a.timeLeft or 99), (b.timeLeft or 99)
        elseif sortKey == "disprofit" then va, vb = (DisProfit(a) or -math.huge), (DisProfit(b) or -math.huge)
        elseif disLootView then                          -- "bid" header = the Disenchant price column here
            local da, db = DisValue(a), DisValue(b)
            va = da and da * (a.cnt or 1) or -1
            vb = db and db * (b.cnt or 1) or -1
        else va, vb = a.bid, b.bid end
        if va == vb then return (a.name or "") < (b.name or "") end
        if sortAsc then return va < vb else return va > vb end
    end)
end

local QCOLOR = { [0]="9d9d9d",[1]="ffffff",[2]="1eff00",[3]="0070dd",[4]="a335ee",[5]="ff8000" }

-- rarity word for the Rarity column, coloured like the quality (empty while unresolved)
local RARITY_NAME = { [0]="Poor", [1]="Common", [2]="Uncommon", [3]="Rare", [4]="Epic", [5]="Legendary" }
local function RarityLabel(q)
    local name = q and RARITY_NAME[q]
    if not name then return "" end
    local col = QCOLOR[q]
    return col and ("|cff" .. col .. name .. "|r") or name
end

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
    local bidsView = viewMode == "bids"
    cacheFS:SetText("Cache: " .. #scanCache)
    foundFS:SetText("Found: " .. (bidsView and #myBids or #cheapItems))
    if BTN.myBids then BTN.myBids:SetText(bidsView and "to scan" or "my bids") end
    if BTN.search then BTN.search:SetEnabled(not bidsView and #scanCache > 0 and idle) end
    if BTN.disLoot then
        BTN.disLoot:SetEnabled(not bidsView and #scanCache > 0 and idle
            and (CheapBidsPublic and CheapBidsPublic.DisenchantValue) ~= nil)   -- needs the Disenchant module
    end
    local now = GetTime and GetTime() or 0
    local locked = floodMode and now > 0 and now < floodAnchor + FLOOD_LOCK   -- no bid earned yet
    if BTN.buy then BTN.buy:SetEnabled(not bidsView and #cheapItems > 0 and idle and not locked) end
    if BTN.bid then
        if bidsView then
            -- enabled only when a RED (outbid) lot is the effective bid target (green = no point)
            local t = selectedItem
            if alwaysRedTarget and (not t or t.led) then
                t = nil
                for _, v in ipairs(myBids) do if not v.led and not IsBig(v) then t = v; break end end  -- never auto-pick a >5g lot
            end
            BTN.bid:SetEnabled(t ~= nil and not t.led and idle and not locked)
        else
            BTN.bid:SetEnabled(#cheapItems > 0 and idle and not locked)
        end
    end
    if BTN.stop then BTN.stop:SetEnabled(isScanning) end
    if BTN.scan then BTN.scan:SetText(isScanning and "stop" or SCAN_BTN) end
end

-- flood-mode token bucket: 1 bid is earned per FLOOD_LOCK seconds since floodAnchor,
-- so waiting banks bids. Refresh the button state and, if no bid is earned yet,
-- schedule a re-enable for when the next one is.
local function RefreshBidLock()
    UpdateButtons()
    local now = GetTime and GetTime() or 0
    if floodMode and now > 0 and now < floodAnchor + FLOOD_LOCK then
        lockTok = lockTok + 1
        local mytok = lockTok
        C_Timer.After(floodAnchor + FLOOD_LOCK - now, function()
            if mytok == lockTok then UpdateButtons() end
        end)
    end
end

local function UpdateTable()
    if not uiBuilt then return end
    UpdateButtons()
    if not fauxScroll then return end
    local list = ActiveList()
    local bidsView = viewMode == "bids"
    local total = #list
    FauxScrollFrame_Update(fauxScroll, total, NUM_ROWS, ROW_H)
    local offset = FauxScrollFrame_GetOffset(fauxScroll)
    for i = 1, NUM_ROWS do
        local row = tableRows[i]
        if not row then break end
        local it = list[i + offset]
        if it then
            row.item = it
            local ic = it.tex
            if it.itemID and it.itemID ~= 0 then
                local instTex = select(5, GetItemInfoInstant(it.itemID))   -- icon from itemID, even if uncached
                if instTex then ic = instTex end
            end
            row.icon:SetTexture(ic or 134400)
            row.cntFS:SetText(it.cnt and it.cnt > 1 and tostring(it.cnt) or "1")
            row.rarFS:SetText(RarityLabel(ItemQuality(it)))
            row.sellerFS:SetText((it.owner and it.owner ~= "" and it.owner) or "?")
            row.buyFS:SetText(it.buyout > 0 and FormatMoney(it.buyout) or "-")
            if disLootView and not bidsView then
                -- dis-loot view: this column is "Dis. profit" = reagent EV x stack - buyout
                local p = DisProfit(it)
                row.aucFS:SetText((p and p > 0) and FormatMoney(p) or "-")   -- FormatMoney can't render negatives
            else
                -- market value of the WHOLE lot: min per-unit buyout (last GetAll) x stack size,
                -- so a 20-stack shows what the 20 are worth, comparable with Bid/Buyout
                local au = AucUnit(it)
                row.aucFS:SetText(au and FormatMoney(au * (it.cnt or 1)) or "-")
            end
            if bidsView then
                -- my-bids: status by name color (green = leading, red = OUTBID)
                row.nameFS:SetText((it.name and it.name ~= "" and it.name) or ItemName(it))
                if it.led then row.nameFS:SetTextColor(0.35, 1, 0.35) else row.nameFS:SetTextColor(1, 0.4, 0.4) end
                row.bidFS:SetText(FormatMoney(it.bid))
                row.timeFS:SetText(TimeLeftText(it.timeLeft))
            else
                row.nameFS:SetText(ItemName(it))
                row.nameFS:SetTextColor(1, 1, 1)
                if disLootView then                     -- Bid column doubles as "Disenchant price" here
                    local dv = DisValue(it)
                    row.bidFS:SetText(dv and FormatMoney(dv * (it.cnt or 1)) or "-")
                else
                    row.bidFS:SetText(FormatMoney(it.bid))
                end
                row.timeFS:SetText(TimeLeftText(it.timeLeft))
            end
            if it == selectedItem then row.sel:Show() else row.sel:Hide() end
            row:SetAlpha(attempted[it] and 0.5 or 1)
            row:Show()
        else
            row.item = nil
            row:Hide()
        end
    end
    if MeasureColumns then MeasureColumns() end     -- adaptive: size columns to the current data
end

local function ApplyFilter()
    ReadFilter()
    viewMode = "scan"                -- any filter/search returns to the scan results view
    disLootView = false              -- a normal search leaves the dis. loot view
    if headerBtns.bid and headerBtns.bid.label then headerBtns.bid.label:SetText("Bid") end
    if headerBtns.aucmin and headerBtns.aucmin.label then headerBtns.aucmin.label:SetText("Auc min") end
    if ResetColumnHiWater then ResetColumnHiWater() end   -- new result set -> re-fit columns once
    cheapItems = {}
    for _, it in ipairs(scanCache) do
        if not it.done and not it.led and TimeShown(it.timeLeft) and PassesFilter(it.bid, it.buyout) and QualityShown(it) then cheapItems[#cheapItems + 1] = it end
    end
    SortItems()
    selectedItem = nil
    local sb = _G["CheapBidsFauxScrollBar"]
    if sb then sb:SetValue(0) end
    UpdateTable()
    statusFS:SetText(string.format("Found %d of %d (%s)", #cheapItems, #scanCache, FilterDesc()))
    C_Timer.After(0.7, function() if uiBuilt and not isScanning then UpdateTable() end end)
end

-- Throttled entry point for USER-driven filtering (search button, time checkboxes).
-- ApplyFilter walks the whole scanCache (up to ~200k after a GetAll), so without
-- a gate an autoclicker on "search"/a checkbox re-runs that full pass per click
-- and hangs the client - the same freeze class as the bid bug, a different button.
-- The internal scan-completion calls keep using ApplyFilter directly (they fire once).
local function RequestApplyFilter()
    if #scanCache == 0 then return end
    if Throttled("filter", 0.3) then return end
    ApplyFilter()
end

-- "Dis. loot": fill the table with the lots that are PROFITABLE to buy out and
-- disenchant - buyout > 0 and the expected reagent value (Disenchant module data x the
-- last GetAll's prices) exceeds the buyout. Sorted by profit, best on top. The money
-- filter boxes are IGNORED here on purpose (profit is the only criterion); the
-- time-left checkboxes still apply. Like the rarity filter, item info resolves async
-- for uncached items, so a manual click schedules a few re-applies while the cache
-- warms (auto=true marks those re-applies: no timers, no re-scheduling loop).
local function ApplyDisLoot(auto)
    if not (CheapBidsPublic and CheapBidsPublic.DisenchantValue) then
        if statusFS then statusFS:SetText("Dis. loot needs the CheapBids_Disenchant module.") end
        return
    end
    viewMode = "scan"
    disLootView = true
    -- Bid and Auc min are pointless here (we pay buyouts): Bid shows the reagent EV
    -- ("Dis. price") and Auc min shows the net gain ("Dis. profit" = EV x stack - buyout)
    if headerBtns.bid and headerBtns.bid.label then headerBtns.bid.label:SetText("Dis. price") end
    if headerBtns.aucmin and headerBtns.aucmin.label then headerBtns.aucmin.label:SetText("Dis. profit") end
    if ResetColumnHiWater then ResetColumnHiWater() end
    cheapItems = {}
    for _, it in ipairs(scanCache) do
        if not it.done and not it.led and TimeShown(it.timeLeft) then
            local p = DisProfit(it)
            if p and p > 0 then cheapItems[#cheapItems + 1] = it end
        end
    end
    sortKey = "disprofit"; sortAsc = false
    for _, ar in pairs(headerArrows) do ar:Hide() end
    SortItems()
    selectedItem = nil
    local sb = _G["CheapBidsFauxScrollBar"]
    if sb then sb:SetValue(0) end
    UpdateTable()
    if statusFS then statusFS:SetText(string.format(
        "Dis. loot: %d profitable of %d (buyout < reagent value).", #cheapItems, #scanCache)) end
    if not auto then
        for _, delay in ipairs({ 0.5, 1.5, 3.0, 5.0 }) do
            C_Timer.After(delay, function()
                if uiBuilt and not isScanning and disLootView and viewMode == "scan" then ApplyDisLoot(true) end
            end)
        end
    end
end

-- index of a lot in the (small) filtered list, or nil
local function IndexOf(it)
    if not it then return nil end
    for i, v in ipairs(ActiveList()) do if v == it then return i end end
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
    local name, tex, cnt, qual, _, _, _, minBid, minInc, buyout, bidAmt, high, _, owner, ownerFull, _, itemID =
        GetAuctionItemInfo("list", i)
    owner = owner or ownerFull        -- some realms fill only ownerFullName (15) in a GetAll dump
    if not name or name == "" then
        if not itemID or itemID == 0 then return end
    end
    -- Auc min price: on a GetAll (storeIdx) fold every lot's per-UNIT buyout into the
    -- market-minimum table, keyed by itemID. O(1) per lot (a single hash write) - no
    -- O(N^2) scan of scanCache. Lots with no buyout carry no market signal, skipped.
    if storeIdx and scanPriceDB and itemID and itemID ~= 0 and buyout and buyout > 0 then
        local n = cnt or 1; if n < 1 then n = 1 end
        local unit = math.floor(buyout / n)
        local cur = scanPriceDB[itemID]
        if not cur or unit < cur then scanPriceDB[itemID] = unit end
        if scanPriceCount then scanPriceCount[itemID] = (scanPriceCount[itemID] or 0) + 1 end
    end
    cache[#cache + 1] = {
        name = name or "", tex = tex, cnt = cnt or 1, qual = qual, owner = owner,
        bid = CalcBid(minBid, minInc, bidAmt), buyout = buyout or 0,
        timeLeft = GetAuctionItemTimeLeft("list", i),   -- 1<30m 2:30m-2h 3:2-12h 4:>12h
        itemID = itemID, idx = storeIdx and i or nil,
        led = high or false,            -- we ALREADY lead this lot -> not biddable, hidden from the list
        -- link is resolved lazily in ItemName via itemID; calling
        -- GetAuctionItemLink for every one of 200k+ lots is what made the scan slow
    }
end

-- ===== Diagnostic: is the GetAll snapshot ordered by REAL expiry? =====
-- The server hands us only a coarse bucket per lot (1=<30m .. 4=>12h), never exact
-- minutes. BUT if the snapshot itself arrives sorted by real expiry, then a lot's
-- POSITION in the snapshot (it.idx) is a finer "who dies first" proxy than the 4
-- buckets - which is exactly what the Bids tab shows when you sort it (that sort is
-- server-side, on the true time). This checks whether OUR GetAll snapshot has the
-- same property: for each bucket it reports how tightly its lots cluster in idx
-- space. density ~1.00 = one solid contiguous block = snapshot is time-sorted ->
-- within that block idx = true expiry order -> we CAN rank finer than the bucket.
-- density near the bucket's share-of-list = scattered = idx tells us nothing about
-- time. Runs on the EXISTING snapshot: no rescan, no extra GetAll cooldown.
local function TimeOrderDiag()
    local n = #scanCache
    if n == 0 then
        print("|cffffcc00[CB time]|r no scan in cache - run \"scan auc\" first.")
        return
    end
    if not cacheFromGetAll then
        print("|cffffcc00[CB time]|r cache is from a PAGE scan (no snapshot idx) - cannot analyze time order. Do a GetAll \"scan auc\".")
        return
    end
    local LABEL = { [1] = "<30m", [2] = "30m-2h", [3] = "2-12h", [4] = ">12h" }
    local cnt, lo, hi = {}, {}, {}
    local nilTL, valid = 0, 0
    local asc, desc, eq = 0, 0, 0
    local prev
    for k = 1, n do
        local it = scanCache[k]
        local t, p = it.timeLeft, it.idx        -- p = true snapshot position (has gaps from skipped empty slots)
        if not t or not p then
            nilTL = nilTL + 1
        else
            valid = valid + 1
            cnt[t] = (cnt[t] or 0) + 1
            if not lo[t] or p < lo[t] then lo[t] = p end
            if not hi[t] or p > hi[t] then hi[t] = p end
            if prev then
                if t > prev then asc = asc + 1 elseif t < prev then desc = desc + 1 else eq = eq + 1 end
            end
            prev = t
        end
    end
    print(string.format("|cff66ccff[CB time]|r snapshot=%d, usable=%d, no-timeLeft=%d. density 1.00 = one solid idx block = time-sorted:", n, valid, nilTL))
    for b = 1, 4 do
        local c = cnt[b] or 0
        if c > 0 then
            local span = hi[b] - lo[b] + 1
            print(string.format("|cff66ccff[CB time]|r  %-7s count=%-6d idx[%d..%d] span=%-7d density=%.3f",
                LABEL[b], c, lo[b], hi[b], span, c / span))
        else
            print(string.format("|cff66ccff[CB time]|r  %-7s count=0", LABEL[b]))
        end
    end
    local steps = asc + desc + eq
    print(string.format("|cff66ccff[CB time]|r adjacent steps: asc=%d desc=%d eq=%d  bucket-change rate=%.3f%s",
        asc, desc, eq, steps == 0 and 0 or (asc + desc) / steps,
        steps > 0 and (asc + desc) / steps < 0.02 and "  (rare changes -> globally time-sorted)" or ""))
    -- VERDICT keyed on the <30m bucket - the one we actually want to rank within.
    local c1 = cnt[1] or 0
    if c1 > 1 then
        local d1 = c1 / (hi[1] - lo[1] + 1)
        local share = c1 / math.max(1, valid)          -- density expected if <30m lots were random
        local verdict = d1 > 0.5 and "CLUSTERED -> idx IS a finer expiry order, we CAN rank within <30m"
            or (d1 > share * 3 and "partly clustered -> weak signal, maybe usable")
            or "SCATTERED -> idx is NOT a time proxy, cannot refine the bucket"
        print(string.format("|cffffcc00[CB time]|r VERDICT(<30m): density=%.3f vs random-share=%.3f -> %s", d1, share, verdict))
    else
        print("|cffffcc00[CB time]|r VERDICT(<30m): too few <30m lots in snapshot to judge - rescan when more are ending.")
    end
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

local GETALL_BATCH = 1000        -- lots processed per frame: bigger = faster scan, more per-frame lag
local function ProcessGetAll(start, total)
    if scanMode ~= "getall" then return end
    local stop = math.min(start + GETALL_BATCH - 1, total)
    for i = start, stop do ReadIndexInto(scanCache, i, true) end
    if stop < total then
        SetProgress(0.1 + 0.9 * stop / total)
        statusFS:SetText(string.format("Processing %d/%d...", stop, total))
        C_Timer.After(0, function() ProcessGetAll(stop + 1, total) end)
    else
        isScanning = false; getAllPending = false; scanMode = nil
        cacheFromGetAll = true; HideProgress()
        -- commit the freshly-built market minimums so tooltips/column/Dis. loot use
        -- them, and persist them (Auctionator-style: they outlive the AH session until
        -- the next GetAll overwrites them).
        if scanPriceDB then
            priceDB = scanPriceDB; scanPriceDB = nil
            priceCount = scanPriceCount or {}; scanPriceCount = nil
            if CheapBidsDB then
                CheapBidsDB.priceDB = priceDB; CheapBidsDB.priceCount = priceCount
                CheapBidsDB.priceDBTime = time()
            end
        end
        statusFS:SetText(string.format("Scan done: %d lots. Filter -> search -> bid.", #scanCache))
        if debugOn then TimeOrderDiag() end           -- auto time-order check while we have a fresh snapshot
        ApplyFilter()
    end
end

local function StartScan()
    viewMode = "scan"
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
    if CheapBidsDB then CheapBidsDB.lastGetAll = time() end
    scanCache = {}; cheapItems = {}; scanPriceDB = {}; scanPriceCount = {}; UpdateTable()
    scanToken = scanToken + 1
    local myToken = scanToken
    if not ITEM_QUALITY_COLORS[-1] then ITEM_QUALITY_COLORS[-1] = { r=0, g=0, b=0 } end
    scanMode = "getall"; isScanning = true; getAllPending = true
    UpdateButtons()
    SetProgress(0.05); statusFS:SetText("GetAll: downloading the whole auction house...")
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
    SetProgress(0.01); statusFS:SetText("Page-by-page scan...")
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
-- So we DON'T re-query (a focused query overwrites the live snapshot and broke the
-- direct path). Instead RelocateInLive re-finds the exact lot near its stored idx by
-- content (item + count + buyout) and bids the corrected live index inside the click.

-- Mark done + drop from the (small) filtered list. NEVER linear-scan scanCache
-- (it can hold 200k+ items -> "script ran too long").
local function RemoveItem(it)
    it.done = true
    local list = ActiveList()                    -- cheapItems in scan view, myBids in the bids view
    local removedIdx
    for i, v in ipairs(list) do if v == it then removedIdx = i; table.remove(list, i); break end end
    -- when the removed lot was the highlighted one, ADVANCE the highlight to the
    -- lot now occupying that slot (or the new last lot) instead of clearing it -
    -- so on confirm the selection visibly walks down and the next bid continues
    -- from here rather than jumping back to the top of the list.
    if it == selectedItem then
        if removedIdx and #list > 0 then
            -- advance to the next AUTO-TARGETABLE lot at/after the freed slot (per the
            -- current flow: IsBig for bids, BuyGuarded for dis-loot buys): the spam
            -- advance must never auto-land on a confirm-needing lot (manual click only).
            selectedItem = nil
            for i = removedIdx, #list do if AutoTargetable(list[i]) then selectedItem = list[i]; break end end
            if selectedItem then ScrollToItem(selectedItem) end
        else
            selectedItem = nil
        end
    end
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
    attempted[it] = nil                 -- retryable (NOT removed - the lot stays in the list)
    -- "Internal auction error" fires for a STALE lot (isolated, normal) AND for the
    -- server flood guard. Only a CLUSTER - a 2nd error within FLOOD_WINDOW - is a real
    -- flood -> switch to the token-bucket pace + lock. An isolated one is just "retry".
    local now = GetTime and GetTime() or 0
    if not floodMode and prevErrAt > 0 and now > 0 and (now - prevErrAt) < FLOOD_WINDOW then
        floodMode = true
    end
    prevErrAt = now
    if floodMode then floodAnchor = now; RefreshBidLock() end
    -- pull the highlight BACK to the rejected lot so the player retries IT, instead
    -- of letting rapid bids walk the target forward past lots the server bounced.
    -- EXCEPT a confirm-needing lot: never auto-target it, even to retry (manual only).
    local ri, si = IndexOf(it), IndexOf(selectedItem)
    if ri and AutoTargetable(it) and (not si or ri < si) then selectedItem = it; ScrollToItem(it) end
    if actFS then
        if floodMode then
            actFS:SetText(string.format("Server flood - now 1 bid / %.0fs (waiting banks bids). Placed: %d, rejected: %d.",
                FLOOD_LOCK, bidsOK, bidsFail))
        else
            actFS:SetText(string.format("Bid rejected (stale lot) - retry. Placed: %d, rejected: %d.",
                bidsOK, bidsFail))
        end
    end
    UpdateTable()
end

-- client-side anti-spam: keep a minimum gap between EVERY bid-button action so an
-- autoclicker can't drive the relocate-scan + table redraw fast enough to freeze
-- the client. A real BID waits the full interval (it hits the server's flood
-- guard); SKIPPING an unavailable lot is local-only, so it clears twice as fast.
local BID_MIN_INTERVAL  = 0.3
local SKIP_MIN_INTERVAL = 0.15
local lastActionAt = 0          -- any action (bid OR skip) - the autoclicker/freeze gate
local lastBidAt    = 0          -- real bids only - the server anti-spam gate

-- The >5g confirm popup. Its Accept button is itself a HARDWARE EVENT, so PlaceAuctionBid
-- still fires from a real click - exactly how the default UI confirms an expensive buyout.
-- Write ONLY to a key here; NEVER reassign the StaticPopupDialogs global itself.
-- `StaticPopupDialogs = StaticPopupDialogs or {}` writes the global VARIABLE from our
-- insecure code, which taints it. Then every secure Blizzard popup that reads
-- StaticPopupDialogs[which] (e.g. REPLACE_ENCHANT) runs on a tainted path and its
-- protected OnAccept is blocked: "attempted to call a forbidden function
-- (ReplaceEnchant) from a tainted execution path" (ERR-0003). The table always exists
-- at addon-load in 2.5.5, so the `or {}` guard is unnecessary as well as harmful.
StaticPopupDialogs["CHEAPBIDS_CONFIRM_BID"] = {
    text = "CheapBids: place a bid of %s on\n%s ?\n\n(price protection - confirm needed)",
    button1 = ACCEPT, button2 = CANCEL,
    OnAccept = function(self, data)
        data = data or (self and self.data)
        if data and data.commit then data.commit() end
    end,
    timeout = 0, whileDead = true, hideOnEscape = true, showAlert = true, preferredIndex = 3,
}

-- show the >5g confirm for `it`/`amount`; run `commit` ONLY when the player accepts.
local function ConfirmBig(it, amount, commit)
    local dlg = StaticPopup_Show("CHEAPBIDS_CONFIRM_BID", FormatMoney(amount), ItemName(it), { commit = commit })
    if dlg then dlg.data = { commit = commit } end       -- some clients pass data via self.data only
end

-- Place a real bid on ONE lot at a known live index. Must run inside a hardware
-- event (button / double-click / key binding).
local function PlaceOn(it, idx, eff, verb)
    attempted[it] = true
    it._bidIdx = idx
    table.insert(pending, it)
    PlaceAuctionBid("list", idx, eff)        -- accepted because we're inside a click
    bidsSent = bidsSent + 1
    if actFS then actFS:SetText(string.format("%s: %s (%s). Placed %d.", verb or "Bid", ItemName(it), FormatMoney(eff), bidsOK)) end
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
-- Returns correctedIndex, currentEff on success. On failure returns nil, nil, ledSeen
-- where ledSeen=true means our exact lot was found but WE ALREADY LEAD it (high) -
-- so it is not "gone", it is just already ours.
local function RelocateInLive(it, skipFilter)
    -- skipFilter=true (the BUY path): identity match only. The bid-price filter boxes
    -- must not veto a buyout - dis-loot lots can carry any bid, we pay the buyout.
    if not it.idx then return nil end
    local n = GetNumAuctionItems("list") or 0
    if n == 0 then return nil end
    local ledSeen = false
    local function matchAt(i)
        if i < 1 or i > n then return nil end
        local _, _, cnt, _, _, _, _, minBid, minInc, buyout, bidAmt, high, _, _, _, _, itemID =
            GetAuctionItemInfo("list", i)
        -- identify by itemID, NOT name: right after a GetAll the item NAMES lag
        -- (cache loads async), so requiring `name` wrongly marked freshly-sorted
        -- lots "unavailable". itemID is present even when the name isn't cached;
        -- an empty/used-up slot has no itemID.
        if not itemID or itemID == 0 then return nil end
        if it.itemID and itemID ~= it.itemID then return nil end
        if (cnt or 1) ~= (it.cnt or 1) then return nil end
        if (buyout or 0) ~= (it.buyout or 0) then return nil end
        if high then ledSeen = true; return nil end            -- our exact lot, but WE already lead it
        local eff = CalcBid(minBid, minInc, bidAmt)
        if not skipFilter and not PassesFilter(eff, buyout or 0) then return nil end -- price moved out of the filter
        return eff
    end
    local eff = matchAt(it.idx)                                 -- fast path: index still valid
    if eff then return it.idx, eff end
    for d = 1, RELOCATE_WINDOW do                               -- drift: search outward from the old index
        eff = matchAt(it.idx + d); if eff then return it.idx + d, eff end
        eff = matchAt(it.idx - d); if eff then return it.idx - d, eff end
    end
    return nil, nil, ledSeen
end

-- first lot at or after `fromIdx` in the filtered list that we haven't bid yet
local function NextUnattempted(fromIdx)
    for i = fromIdx, #cheapItems do
        local v = cheapItems[i]
        if not attempted[v] and not IsBig(v) then return v end   -- never auto-land on a >5g lot
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
    -- ordering probe: bids at the head vs the middle vs the tail reveal how the
    -- LIVE "list" is sorted (if bids rise with position -> sorted by bid).
    local function at(i)
        local _, _, _, _, _, _, _, mb, mi, _, ba, _, _, _, _, _, id = GetAuctionItemInfo("list", i)
        return string.format("[%s]id=%s bid=%s", tostring(i), tostring(id), tostring(CalcBid(mb, mi, ba)))
    end
    if liveN > 2 then
        print("|cff66ccff[CB head]|r " .. at(1) .. " " .. at(math.floor(liveN/2)) .. " " .. at(liveN))
    end
end

-- ===== Layer A: "my bids" view (the live "bidder" list) =====
-- Every auction WE currently have a bid on; GetAuctionItemInfo field 12 (high) =
-- leading vs outbid. This is a SEPARATE server list from the GetAll "list"
-- snapshot: reading/refreshing it is cheap (NO 15-min GetAll cooldown), never
-- touches our scan snapshot, and we can re-bid straight from it.

-- the first OUTBID (red) lot in the my-bids view (reds are sorted on top)
local function FirstRed()
    for _, it in ipairs(myBids) do if not it.led and not IsBig(it) then return it end end  -- skip >5g: never auto-targeted
    return nil
end

local function ReadMyBids()
    local selKey = selectedItem and selectedItem._key or nil   -- remember the highlight across the rebuild
    local fresh = {}
    local n = (GetNumAuctionItems and GetNumAuctionItems("bidder")) or 0
    for i = 1, n do
        local name, tex, cnt, qual, _, _, _, minBid, minInc, buyout, bidAmt, high, _, owner, ownerFull, _, itemID =
            GetAuctionItemInfo("bidder", i)
        owner = owner or ownerFull
        if name and name ~= "" then
            local it = {
                name = name, tex = tex, cnt = cnt or 1, qual = qual, owner = owner,   -- owner: DISPLAY only
                bid = CalcBid(minBid, minInc, bidAmt),     -- amount needed to (re)take the lead
                buyout = buyout or 0,
                timeLeft = GetAuctionItemTimeLeft("bidder", i),
                itemID = itemID, idx = i, led = high or false,
            }
            -- stable identity for selection-preservation across refresh: NO owner in the KEY
            -- (the seller name resolves async and can flip nil<->name, which would lose the highlight)
            it._key = tostring(itemID) .. ":" .. tostring(cnt or 1) .. ":" .. tostring(buyout or 0)
            if not bidsDismissed[it._key] then fresh[#fresh + 1] = it end   -- right-clicked lots stay hidden

        end
    end
    -- ORDER: outbid (red) first, then leading (green). Within each, SHORTEST time on
    -- top - primary key is the time-left bucket (1=<30m .. 4=>12h), tiebreak is the
    -- server's row order (true sub-bucket expiry from the one duration sort on entry).
    -- table.sort is NOT stable in Lua 5.1, so carry an explicit _ord tiebreak.
    for i, it in ipairs(fresh) do it._ord = i end
    table.sort(fresh, function(a, b)
        local la, lb = a.led and 1 or 0, b.led and 1 or 0
        if la ~= lb then return la < lb end              -- outbid (0) above leading (1)
        local ta, tb = a.timeLeft or 99, b.timeLeft or 99
        if ta ~= tb then return ta < tb end              -- shorter time bucket first (<30m on top)
        return a._ord < b._ord                           -- keep server true-time order within a bucket
    end)
    myBids = fresh
    -- re-find the previously selected lot so an auto-refresh never yanks the highlight
    selectedItem = nil
    if selKey then
        for _, it in ipairs(myBids) do if it._key == selKey then selectedItem = it; break end end
    end
    -- "always target red": if nothing red is selected, drop the highlight onto the top
    -- outbid lot, so freshly-appeared reds get targeted automatically (press bid -> hits red)
    if alwaysRedTarget and (not selectedItem or selectedItem.led) then selectedItem = FirstRed() end
end

-- ask the server for a fresh bidder list, sorted by REAL expiry (server-side sort
-- = true order, finer than the 4 buckets). The reply lands in
-- AUCTION_BIDDER_LIST_UPDATE, which re-reads + redraws.
local function RefreshMyBids(silent, resort)
    -- only sort server-side ON ENTRY: repeated SortAuctionItems calls can TOGGLE the
    -- direction on some clients, which would flip the order every poll tick.
    if resort then pcall(SortAuctionItems, "bidder", "duration") end
    pcall(GetBidderAuctionItems)            -- async; AUCTION_BIDDER_LIST_UPDATE re-reads when it lands
    ReadMyBids()
    UpdateTable()                           -- keeps the current scroll offset (we never SetValue here)
    if not silent and statusFS then statusFS:SetText(string.format(
        "My bids: %d (red = OUTBID on top, green = leading), live by real time. Select a red lot -> bid to re-bid.", #myBids)) end
end

-- auto-refresh the my-bids view so freshly-outbid lots float up (red, on top) on
-- their own. Silent = keep scroll + selection. Cancelled by bumping bidsPollToken.
local function StartBidsPoll()
    bidsPollToken = bidsPollToken + 1
    local tk = bidsPollToken
    local function tick()
        if tk ~= bidsPollToken then return end
        if viewMode ~= "bids" or not (content and content:IsShown()) then return end
        if autoScanBids then RefreshMyBids(true) end    -- "autoscan bids" off -> ticker idles, no auto-feed
        C_Timer.After(1, tick)
    end
    C_Timer.After(1, tick)
end

local function ToggleBidsView()
    selectedItem = nil
    if viewMode == "bids" then
        viewMode = "scan"
        bidsPollToken = bidsPollToken + 1                                    -- stop the auto-refresh ticker
        UpdateTable()
        if statusFS then statusFS:SetText("Scan view. scan auc -> filter -> search -> bid.") end
    else
        viewMode = "bids"
        bidsDismissed = {}                      -- fresh session: show all bids again
        pending = {}; bidWatch = bidWatch + 1   -- abort any in-flight scan reconcile (it must never target myBids)
        local sb = _G["CheapBidsFauxScrollBar"]; if sb then sb:SetValue(0) end   -- a fresh view starts at the top
        RefreshMyBids(false, true)                                               -- resort once to load true-time order
        StartBidsPoll()
    end
end

-- actually place a my-bids re-bid (small bid: called directly; >5g: from the confirm
-- popup's Accept, still a hardware event). Advances the highlight + consumes a token.
local function CommitBidderBid(target)
    if not target then return end
    local now = GetTime and GetTime() or 0
    if now > 0 and (now - lastBidAt) < BID_MIN_INTERVAL then return end           -- server anti-spam gate
    lastBidAt = now
    PlaceAuctionBid("bidder", target.idx, target.bid)                            -- inside this click -> accepted
    bidsSent = bidsSent + 1
    if actFS then actFS:SetText(string.format("Re-bid: %s (%s). Sent %d.", ItemName(target), FormatMoney(target.bid), bidsSent)) end
    -- drop this row and ADVANCE, bid landed or not, WITHOUT resetting scroll; with
    -- "always target red" on, keep the next highlight on a red lot (skip greens).
    RemoveItem(target)
    if alwaysRedTarget and (not selectedItem or selectedItem.led) then selectedItem = FirstRed() end
    if floodMode then floodAnchor = floodAnchor + FLOOD_LOCK; RefreshBidLock() end  -- consume a token
    UpdateTable()
end

-- re-bid one outbid lot straight from the live bidder list. PlaceAuctionBid on the
-- "bidder" list works from a real click, exactly like the native Bids tab button.
local function RebidBidder(it)
    local now = GetTime and GetTime() or 0
    if now > 0 and (now - lastActionAt) < SKIP_MIN_INTERVAL then return end       -- debounce (anti-freeze)
    lastActionAt = now
    -- server flood lock (shared with scan): hold until a token is available
    if floodMode and now > 0 and now < floodAnchor + FLOOD_LOCK then
        if actFS then actFS:SetText(string.format("Server flood - next bid in %.1fs.", floodAnchor + FLOOD_LOCK - now)) end
        return
    end
    local target = it or selectedItem
    if alwaysRedTarget and (not target or target.led) then target = FirstRed() end -- never sit on / bid a green
    if not target then
        if actFS then actFS:SetText(alwaysRedTarget and "No outbid (red) lots to bid." or "No bids here - refresh with \"my bids\".") end
        return
    end
    selectedItem = target
    if target.led then                          -- green = leading: nothing to bid, do NOT remove it
        if actFS then actFS:SetText(ItemName(target) .. " - already leading, nothing to bid.") end
        UpdateTable()
        return
    end
    if NeedsConfirm(target, target.bid) then    -- above the market ceiling (protection ON): ask first
        if actFS then actFS:SetText(string.format("Confirm re-bid of %s on %s (price protection).", FormatMoney(target.bid), ItemName(target))) end
        ConfirmBig(target, target.bid, function() CommitBidderBid(target) end)
        return
    end
    CommitBidderBid(target)
end

-- a my-bids re-bid got "Internal auction error" (lot changed / server flood). Behave
-- like the scan path: DON'T lose the lot (re-read the live bidder list, where a still-
-- outbid lot reappears), and on a flood cluster lock the bid button (token bucket).
local function RejectBidderBid()
    local now = GetTime and GetTime() or 0
    if now > 0 and (now - lastBidAt) > 6 then return end   -- not from one of our recent re-bids
    bidsFail = bidsFail + 1
    if not floodMode and prevErrAt > 0 and now > 0 and (now - prevErrAt) < FLOOD_WINDOW then floodMode = true end
    prevErrAt = now
    if floodMode then floodAnchor = now; RefreshBidLock() end
    if actFS then
        actFS:SetText(floodMode and string.format("Server flood - now 1 bid / %.0fs (waiting banks bids). Rejected %d.", FLOOD_LOCK, bidsFail)
            or string.format("Bid rejected (lot changed) - retry. Rejected %d.", bidsFail))
    end
    RefreshMyBids(true)        -- restore the still-outbid lot + re-target a red
end

-- right-click a my-bids row: just REMOVE the lot from the list (player doesn't want
-- to bid it), and remember it so the 1s autoscan does not re-add it.
local function DismissRow(it)
    if not it then return end
    if viewMode == "bids" and it._key then bidsDismissed[it._key] = true end
    RemoveItem(it)
    if viewMode == "bids" and alwaysRedTarget and (not selectedItem or selectedItem.led) then selectedItem = FirstRed() end
    UpdateTable()
end

-- actually place a scan-view bid on `target`. Re-locates the lot at COMMIT time (it can
-- drift while a >5g confirm popup is open) and bids the corrected live index. Called
-- directly for small bids, or from the confirm popup's Accept (also a hardware event).
local function CommitScanBid(target)
    if not target then return end
    local now = GetTime and GetTime() or 0
    local idx, eff, ledSeen = RelocateInLive(target)
    if not idx then
        if actFS then actFS:SetText(ItemName(target) ..
            (ledSeen and " - you already lead this, removed." or " - item taken/unavailable, removed.")) end
        RemoveItem(target); UpdateTable(); return
    end
    if now > 0 and (now - lastBidAt) < BID_MIN_INTERVAL then return end           -- server anti-spam gate
    lastBidAt = now
    target.idx = idx
    PlaceOn(target, idx, eff)                           -- highlight stays on the bid lot (dimmed)
    if floodMode then floodAnchor = floodAnchor + FLOOD_LOCK; RefreshBidLock() end  -- consume 1 token
    ScrollToItem(target); UpdateTable()
end

-- Bid the SELECTED lot only. If that exact lot is gone from the live auction it
-- is REMOVED from the list with an "unavailable" message and NO bid is placed on
-- any other lot (asked for explicitly). Lots already bid are skipped, so repeated
-- clicks walk down to the next fresh lot; the highlight stays on the bid lot.
local function BidItem(it)
    if isScanning then return end
    if viewMode == "bids" then RebidBidder(it); return end   -- my-bids view re-bids the live bidder list
    -- Gate the WHOLE action at the FASTER (skip) rate, so an autoclicker can't
    -- drive the relocate scan / table redraw fast enough to freeze us, while
    -- unavailable lots still clear quickly. A real bid additionally waits the
    -- full BID_MIN_INTERVAL below (it hits the server's flood guard).
    local now = GetTime and GetTime() or 0
    if now > 0 and (now - lastActionAt) < SKIP_MIN_INTERVAL then return end
    lastActionAt = now
    -- FLOOD MODE token bucket: a bid is earned every FLOOD_LOCK since the last error
    -- (waiting banks bids). If none earned yet, HOLD - don't advance/remove/bid; the
    -- rejected lot stays selected so the player retries it once a token is available.
    if floodMode and now > 0 and now < floodAnchor + FLOOD_LOCK then
        if actFS then actFS:SetText(string.format("Server flood - next bid in %.1fs (1 / %.0fs).",
            floodAnchor + FLOOD_LOCK - now, FLOOD_LOCK)) end
        return
    end
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
    local idx, eff, ledSeen = RelocateInLive(target)
    if not idx then
        -- not biddable -> drop it. Distinguish "we already lead it" from "gone".
        if actFS then actFS:SetText(ItemName(target) ..
            (ledSeen and " - you already lead this, removed." or " - item taken/unavailable, removed.")) end
        RemoveItem(target)                              -- advances the highlight to the next surviving lot
        UpdateTable()
        return
    end
    if NeedsConfirm(target, eff) then            -- above the market ceiling (protection ON): ask first
        if actFS then actFS:SetText(string.format("Confirm bid of %s on %s (price protection).", FormatMoney(eff), ItemName(target))) end
        ConfirmBig(target, eff, function() CommitScanBid(target) end)
        return
    end
    CommitScanBid(target)                               -- small bid: place straight away
end

local function DoSingleBid()
    if not uiBuilt then return end          -- hotkey pressed before AH ever opened
    if isScanning then return end
    if #ActiveList() == 0 then
        if actFS then
            actFS:SetText(viewMode == "bids" and "No bids found - press \"my bids\" to refresh."
                or "Run \"scan auc\" and search first.")
        end
        return
    end
    BidItem(selectedItem)
end

-- ===== Buy (buyout) - the SAME mechanism as bid, only the amount is the buyout =====
-- PlaceAuctionBid at the buyout price IS the buyout purchase; it reuses the whole bid
-- machinery untouched: hardware-event only, relocate-by-content before committing,
-- attempted/pending + ReconcileBids/ConfirmOldest/RejectOldest confirmation, flood
-- token bucket, watchdog. Spam-clicking "buy" walks down the list like bid does.

-- first lot at or after `fromIdx` we haven't acted on that CAN be bought without a
-- popup (auto-advance never lands on a guarded lot - manual click only, like bid;
-- BuyGuarded itself is defined up with DisProfit, shared with the highlight advance)
local function NextBuyable(fromIdx)
    for i = fromIdx, #cheapItems do
        local v = cheapItems[i]
        if not attempted[v] and (v.buyout or 0) > 0 and not BuyGuarded(v) then return v end
    end
    return nil
end

local function CommitScanBuy(target)
    if not target then return end
    local now = GetTime and GetTime() or 0
    local idx, _, ledSeen = RelocateInLive(target, true)     -- identity only: filter can't veto a buyout
    if not idx then
        if actFS then actFS:SetText(ItemName(target) ..
            (ledSeen and " - you already lead this, removed." or " - item taken/unavailable, removed.")) end
        RemoveItem(target); UpdateTable(); return
    end
    if now > 0 and (now - lastBidAt) < BID_MIN_INTERVAL then return end           -- server anti-spam gate
    lastBidAt = now
    target.idx = idx
    PlaceOn(target, idx, target.buyout, "Buy")          -- buyout amount = instant purchase
    if floodMode then floodAnchor = floodAnchor + FLOOD_LOCK; RefreshBidLock() end  -- consume 1 token
    ScrollToItem(target); UpdateTable()
end

local function BuyItem(it)
    if isScanning then return end
    if viewMode ~= "scan" then return end               -- buys work on the scan table only
    local now = GetTime and GetTime() or 0
    if now > 0 and (now - lastActionAt) < SKIP_MIN_INTERVAL then return end       -- debounce (anti-freeze)
    lastActionAt = now
    if floodMode and now > 0 and now < floodAnchor + FLOOD_LOCK then
        if actFS then actFS:SetText(string.format("Server flood - next buy in %.1fs (1 / %.0fs).",
            floodAnchor + FLOOD_LOCK - now, FLOOD_LOCK)) end
        return
    end
    -- resolve the target: the selected lot, advancing past bought/no-buyout lots
    local target = it
    if not target or attempted[target] or (target.buyout or 0) <= 0 then
        target = NextBuyable(IndexOf(target or selectedItem) or 1)
    end
    if not target then
        if actFS then actFS:SetText("No fresh lot to buy - rescan or press \"dis. loot\" again.") end
        return
    end
    selectedItem = target
    local idx, _, ledSeen = RelocateInLive(target, true)
    if not idx then
        if actFS then actFS:SetText(ItemName(target) ..
            (ledSeen and " - you already lead this, removed." or " - item taken/unavailable, removed.")) end
        RemoveItem(target)
        UpdateTable()
        return
    end
    if BuyGuarded(target) then                          -- expensive AND not reagent-covered: ask first
        if actFS then actFS:SetText(string.format("Confirm buyout of %s for %s (price protection).", ItemName(target), FormatMoney(target.buyout))) end
        ConfirmBig(target, target.buyout, function() CommitScanBuy(target) end)
        return
    end
    CommitScanBuy(target)
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

-- Column widths. These are DEFAULTS/fallbacks; MeasureColumns re-sizes them to the actual
-- data each redraw (adaptive). Order L->R: name(flex), rarity, cnt, seller, bid, AUC, BUYOUT, time.
local C_BUY, C_BID, C_CNT, C_TIME, C_RAR, C_AUC, C_SELLER = 78, 78, 28, 50, 44, 78, 80

-- right-offset (from the row/header RIGHT edge) of each column's right edge, for the CURRENT
-- widths. name flexes to fill whatever is left. A 4px gutter sits between columns.
local function ColOffs()
    local o = {}
    o.time   = 2
    o.buyout = o.time   + C_TIME + 4
    o.aucmin = o.buyout + C_BUY  + 4
    o.bid    = o.aucmin + C_AUC  + 4
    o.seller = o.bid    + C_BID  + 4
    o.cnt    = o.seller + C_SELLER + 4
    o.rarity = o.cnt    + C_CNT  + 4
    o.nameR  = o.rarity + C_RAR  + 4
    return o
end
-- key -> (width getter, row FontString field). name/time handled separately.
local COLSPEC = {
    rarity = { function() return C_RAR end,    "rarFS" },
    cnt    = { function() return C_CNT end,    "cntFS" },
    seller = { function() return C_SELLER end, "sellerFS" },
    bid    = { function() return C_BID end,    "bidFS" },
    aucmin = { function() return C_AUC end,    "aucFS" },
    buyout = { function() return C_BUY end,    "buyFS" },
    time   = { function() return C_TIME end,   "timeFS" },
}
local SEP_ORDER = { "rarity", "cnt", "seller", "bid", "aucmin", "buyout", "time" }

-- re-anchor the header buttons, separators and every row's cells for the current widths.
local function RelayoutColumns()
    if not tableHdr or not headerBtns.name then return end
    local o = ColOffs()
    local nb = headerBtns.name
    nb:ClearAllPoints(); nb:SetPoint("LEFT", tableHdr, "LEFT", 22, 0)
    nb:SetPoint("RIGHT", tableHdr, "RIGHT", -o.nameR, 0); nb:SetHeight(18)
    for key, spec in pairs(COLSPEC) do
        local b = headerBtns[key]
        if b then b:ClearAllPoints(); b:SetPoint("RIGHT", tableHdr, "RIGHT", -o[key], 0); b:SetSize(spec[1](), 18) end
    end
    for i, key in ipairs(SEP_ORDER) do
        local s = sepTex[i]
        if s then local off = o[key] + COLSPEC[key][1]()      -- the column's LEFT boundary
            s:ClearAllPoints(); s:SetPoint("TOP", tableHdr, "TOPRIGHT", -off, -2); s:SetPoint("BOTTOM", tableHdr, "BOTTOMRIGHT", -off, 2) end
    end
    for _, r in ipairs(tableRows) do
        if r.nameFS and r.icon then
            r.nameFS:ClearAllPoints(); r.nameFS:SetPoint("LEFT", r.icon, "RIGHT", 3, 0); r.nameFS:SetPoint("RIGHT", r, "RIGHT", -o.nameR, 0)
            for key, spec in pairs(COLSPEC) do
                local fs = r[spec[2]]
                if fs then fs:ClearAllPoints(); fs:SetPoint("RIGHT", r, "RIGHT", -o[key], 0); fs:SetWidth(spec[1]()) end
            end
        end
    end
end

-- Adaptive sizing, v2. Two rules learned from v1's bugs:
--  * measure the RENDERED strings of the rows on screen, not the numerically-largest value
--    (26g 58c is a bigger number than 25g 99s 70c but a SHORTER string - v1 sized to the big
--    number and ellipsized the long one);
--  * widths only GROW while a result set is on screen (high-water mark). Shrinking on every
--    redraw made the whole table jump each time a lot was bought out / removed. The marks
--    reset on the next ApplyFilter (new search -> snap to fit the new data once).
-- Guarded: any error disables adaptive sizing for the session (fixed defaults remain).
local adaptiveOff = false
local colHiWater = nil                       -- nil = start fresh from the static minimums
ResetColumnHiWater = function() colHiWater = nil end
MeasureColumns = function()
    if adaptiveOff or not measureFS or not tableHdr then return end
    local ok, err = pcall(function()
        local function w(text) measureFS:SetText(text or ""); return measureFS:GetStringWidth() or 0 end
        local function clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi else return v end end
        local pad = 10
        -- static floors: header captions + fixed label sets (these never jump)
        if not colHiWater then
            colHiWater = {
                bid  = w(disLootView and "Dis. price" or "Bid") + pad,         -- both retitled in the dis-loot view
                auc  = math.max(w(disLootView and "Dis. profit" or "Auc min") + pad, 44),
                buy  = math.max(w("Buyout") + pad, 44),
                cnt  = math.max(w("Qty") + pad, 26),
                rar  = clamp(math.max(w("Uncommon"), w("Legendary")) + pad, 40, 96),
                tim  = clamp(math.max(w("2-12h"), w(">12h"), w("Time left")) + pad, 44, 90),
                sel  = math.max(w("Seller") + pad, 34),
            }
        end
        -- grow to the widest string actually RENDERED in the visible rows
        local hw = colHiWater
        for i = 1, NUM_ROWS do
            local r = tableRows[i]
            if r and r:IsShown() then
                local function grow(key, fs)
                    if fs then local v = (fs:GetStringWidth() or 0) + pad; if v > hw[key] then hw[key] = v end end
                end
                grow("bid", r.bidFS); grow("auc", r.aucFS); grow("buy", r.buyFS)
                grow("cnt", r.cntFS); grow("rar", r.rarFS); grow("tim", r.timeFS)
                grow("sel", r.sellerFS)
            end
        end
        local nBid = clamp(hw.bid, 30, 140)
        local nAuc = clamp(hw.auc, 44, 140)
        local nBuy = clamp(hw.buy, 44, 140)
        local nCnt = clamp(hw.cnt, 26, 60)
        local nRar = clamp(hw.rar, 40, 96)
        local nTim = clamp(hw.tim, 44, 90)
        local nSel = clamp(hw.sel, 34, 120)
        -- relayout only when something actually changed (no per-frame churn)
        if nBid ~= C_BID or nAuc ~= C_AUC or nBuy ~= C_BUY or nCnt ~= C_CNT
           or nRar ~= C_RAR or nTim ~= C_TIME or nSel ~= C_SELLER then
            C_BID, C_AUC, C_BUY, C_CNT, C_RAR, C_TIME, C_SELLER = nBid, nAuc, nBuy, nCnt, nRar, nTim, nSel
            RelayoutColumns()
        end
    end)
    if not ok then adaptiveOff = true end   -- fall back to fixed layout for the rest of the session
end

local function SetSortColumn(key)
    if viewMode == "bids" then return end               -- bids view is fixed: red (outbid) on top, green below
    if Throttled("sort", 0.2) then return end           -- header-spam guard (sorts up to ~4700)
    if sortKey == key then sortAsc = not sortAsc else sortKey = key; sortAsc = (key == "bid" or key == "name" or key == "time" or key == "seller") end
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

    tableHdr = hdr
    measureFS = measureFS or hdr:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")   -- offscreen ruler
    measureFS:Hide()
    local function headerBtn(key, text, anchorFn, just)
        local b = CreateFrame("Button", nil, hdr)
        anchorFn(b)
        local f = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        f:SetAllPoints(); f:SetJustifyH(just or "LEFT"); f:SetText(text)
        b:SetScript("OnClick", function() SetSortColumn(key) end)
        b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        b.label = f                                     -- dis-loot view retitles the Bid column
        headerBtns[key] = b
        return b
    end
    headerBtn("name", "Item", function(b) b:SetPoint("LEFT", hdr, "LEFT", 22, 0); b:SetPoint("RIGHT", hdr, "RIGHT", -(C_RAR+C_CNT+C_SELLER+C_BID+C_BUY+C_AUC+C_TIME+28), 0); b:SetHeight(18) end, "LEFT")
    headerBtn("rarity", "Rarity", function(b) b:SetPoint("RIGHT", hdr, "RIGHT", -(C_CNT+C_SELLER+C_BID+C_BUY+C_AUC+C_TIME+24), 0); b:SetSize(C_RAR, 18) end, "LEFT")
    headerBtn("cnt", "Qty", function(b) b:SetPoint("RIGHT", hdr, "RIGHT", -(C_SELLER+C_BID+C_BUY+C_AUC+C_TIME+20), 0); b:SetSize(C_CNT, 18) end, "LEFT")
    headerBtn("seller", "Seller", function(b) b:SetPoint("RIGHT", hdr, "RIGHT", -(C_BID+C_BUY+C_AUC+C_TIME+16), 0); b:SetSize(C_SELLER, 18) end, "LEFT")
    headerBtn("bid", "Bid", function(b) b:SetPoint("RIGHT", hdr, "RIGHT", -(C_AUC+C_BUY+C_TIME+12), 0); b:SetSize(C_BID, 18) end, "LEFT")
    headerBtn("aucmin", "Auc min", function(b) b:SetPoint("RIGHT", hdr, "RIGHT", -(C_BUY+C_TIME+8), 0); b:SetSize(C_AUC, 18) end, "LEFT")
    headerBtn("buyout", "Buyout", function(b) b:SetPoint("RIGHT", hdr, "RIGHT", -(C_TIME+4), 0); b:SetSize(C_BUY, 18) end, "LEFT")
    headerBtn("time", "Time left", function(b) b:SetPoint("RIGHT", hdr, "RIGHT", 0, 0); b:SetSize(C_TIME, 18) end, "LEFT")
    -- vertical separators between the column headers
    local seps = { C_RAR+C_CNT+C_SELLER+C_BID+C_BUY+C_AUC+C_TIME+24, C_CNT+C_SELLER+C_BID+C_BUY+C_AUC+C_TIME+20, C_SELLER+C_BID+C_BUY+C_AUC+C_TIME+16, C_BID+C_BUY+C_AUC+C_TIME+12, C_BUY+C_AUC+C_TIME+8, C_AUC+C_TIME+4, C_TIME+2 }
    for i, off in ipairs(seps) do
        local s = hdr:CreateTexture(nil, "ARTWORK")
        s:SetColorTexture(0.45, 0.45, 0.5, 0.7); s:SetWidth(1)
        s:SetPoint("TOP", hdr, "TOPRIGHT", -off, -2)
        s:SetPoint("BOTTOM", hdr, "BOTTOMRIGHT", -off, 2)
        sepTex[i] = s
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
        nameFS:SetPoint("RIGHT", r, "RIGHT", -(C_RAR+C_CNT+C_SELLER+C_BID+C_BUY+C_AUC+C_TIME+28), 0)
        nameFS:SetJustifyH("LEFT"); nameFS:SetWordWrap(false)
        local rarFS = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        rarFS:SetPoint("RIGHT", r, "RIGHT", -(C_CNT+C_SELLER+C_BID+C_BUY+C_AUC+C_TIME+24), 0); rarFS:SetWidth(C_RAR); rarFS:SetJustifyH("LEFT")
        local cntFS = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        cntFS:SetPoint("RIGHT", r, "RIGHT", -(C_SELLER+C_BID+C_BUY+C_AUC+C_TIME+20), 0); cntFS:SetWidth(C_CNT); cntFS:SetJustifyH("CENTER")
        local sellerFS = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        sellerFS:SetPoint("RIGHT", r, "RIGHT", -(C_BID+C_BUY+C_AUC+C_TIME+16), 0); sellerFS:SetWidth(C_SELLER); sellerFS:SetJustifyH("LEFT"); sellerFS:SetWordWrap(false)
        local bidFS = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        bidFS:SetPoint("RIGHT", r, "RIGHT", -(C_AUC+C_BUY+C_TIME+12), 0); bidFS:SetWidth(C_BID); bidFS:SetJustifyH("RIGHT"); bidFS:SetWordWrap(false)
        local aucFS = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        aucFS:SetPoint("RIGHT", r, "RIGHT", -(C_BUY+C_TIME+8), 0); aucFS:SetWidth(C_AUC); aucFS:SetJustifyH("RIGHT"); aucFS:SetWordWrap(false)
        local buyFS = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        buyFS:SetPoint("RIGHT", r, "RIGHT", -(C_TIME+4), 0); buyFS:SetWidth(C_BUY); buyFS:SetJustifyH("RIGHT"); buyFS:SetWordWrap(false)
        local timeFS = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        timeFS:SetPoint("RIGHT", r, "RIGHT", -2, 0); timeFS:SetWidth(C_TIME); timeFS:SetJustifyH("RIGHT")
        r.icon, r.nameFS, r.rarFS, r.cntFS, r.sellerFS, r.bidFS, r.buyFS, r.aucFS, r.timeFS, r.sel = icon, nameFS, rarFS, cntFS, sellerFS, bidFS, buyFS, aucFS, timeFS, sel
        r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        r:SetScript("OnClick", function(self, button)
            if not self.item then return end
            -- vanilla-AH behaviour: shift-click drops the item link into an open chat edit
            -- box (ctrl = dress up, etc.). If a modified click consumed it, don't also
            -- select/bid; otherwise fall through to normal row selection.
            if button == "LeftButton" and IsModifiedClick() then
                local link = ItemLink(self.item)
                if link and HandleModifiedItemClick(link) then return end
            end
            if button == "RightButton" then
                if viewMode == "bids" then DismissRow(self.item) end   -- just remove, no bid
                return
            end
            selectedItem = self.item
            -- "always target red": clicking a green lot snaps the highlight to the top red
            if viewMode == "bids" and alwaysRedTarget and (not selectedItem or selectedItem.led) then selectedItem = FirstRed() end
            -- a >5g lot is never auto-targeted; picking it by hand is allowed but warned
            if IsBig(selectedItem) and actFS then
                actFS:SetText(string.format("WARNING: %s bid is %s (over 5g) - bid will ask to confirm.",
                    ItemName(selectedItem), FormatMoney(selectedItem.bid or 0)))
            end
            UpdateTable()
        end)
        r:SetScript("OnDoubleClick", function(self, button)
            if button == "RightButton" then return end
            if self.item then selectedItem = self.item; BidItem(self.item) end
        end)
        r:SetScript("OnEnter", function(self)
            local it = self.item
            if not it then return end
            local link = it.link
            if not link and it.itemID and it.itemID ~= 0 then
                link = select(2, GetItemInfo(it.itemID)) or ("item:" .. it.itemID)   -- bids/old rows: link from itemID
            end
            if link then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetHyperlink(link); GameTooltip:Show()
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
    mBuyMin.g:SetText("1")          -- default "Buyout from" = 1g

    -- left panel
    leftCol = CreateFrame("Frame", nil, content, bt)
    leftCol:SetPoint("TOPLEFT", content, "TOPLEFT", 7, -76)       -- +5px off the AH frame border
    leftCol:SetPoint("BOTTOMLEFT", AuctionFrame, "BOTTOMLEFT", 15, 12)  -- reach the frame's inner bottom (match rightPanel)
    leftCol:SetWidth(170)                                          -- shrink so the right edge stays put
    if leftCol.SetBackdrop then leftCol:SetBackdrop(PANEL_BACKDROP); leftCol:SetBackdropColor(0,0,0,0.55); leftCol:SetBackdropBorderColor(0.45,0.45,0.45) end

    -- 6 buttons in a 3x2 grid:
    --   [ scan auc ] [ cancel    ]      (cancel aborts the scan -> next to scan)
    --   [   bid    ] [ search    ]
    --   [   buy    ] [ Dis. loot ]      (buy under bid: same mechanism, buyout amount)
    local BTN_W, BTN_H = 75, 24
    BTN.scan = CreateFrame("Button", nil, leftCol, "UIPanelButtonTemplate")
    BTN.scan:SetSize(BTN_W, BTN_H); BTN.scan:SetPoint("TOPLEFT", leftCol, "TOPLEFT", 8, -8); BTN.scan:SetText(SCAN_BTN)
    BTN.stop = CreateFrame("Button", nil, leftCol, "UIPanelButtonTemplate")
    BTN.stop:SetSize(BTN_W, BTN_H); BTN.stop:SetPoint("LEFT", BTN.scan, "RIGHT", 4, 0); BTN.stop:SetText("cancel"); BTN.stop:SetEnabled(false)
    BTN.bid = CreateFrame("Button", nil, leftCol, "UIPanelButtonTemplate")
    BTN.bid:SetSize(BTN_W, BTN_H); BTN.bid:SetPoint("TOPLEFT", BTN.scan, "BOTTOMLEFT", 0, -6); BTN.bid:SetText("bid"); BTN.bid:SetEnabled(false)
    BTN.search = CreateFrame("Button", nil, leftCol, "UIPanelButtonTemplate")
    BTN.search:SetSize(BTN_W, BTN_H); BTN.search:SetPoint("LEFT", BTN.bid, "RIGHT", 4, 0); BTN.search:SetText("search"); BTN.search:SetEnabled(false)
    BTN.buy = CreateFrame("Button", nil, leftCol, "UIPanelButtonTemplate")
    BTN.buy:SetSize(BTN_W, BTN_H); BTN.buy:SetPoint("TOPLEFT", BTN.bid, "BOTTOMLEFT", 0, -6); BTN.buy:SetText("buy"); BTN.buy:SetEnabled(false)
    BTN.buy:SetScript("OnClick", function() BuyItem(selectedItem) end)
    BTN.disLoot = CreateFrame("Button", nil, leftCol, "UIPanelButtonTemplate")
    BTN.disLoot:SetSize(BTN_W, BTN_H); BTN.disLoot:SetPoint("LEFT", BTN.buy, "RIGHT", 4, 0); BTN.disLoot:SetText("dis. loot"); BTN.disLoot:SetEnabled(false)
    BTN.disLoot:SetScript("OnClick", function() ApplyDisLoot(false) end)

    -- toggle: scan results  <->  my bids (live "bidder" list; re-bid outbid lots).
    -- pinned to the bottom of the left panel so it never collides with the grid.
    BTN.myBids = CreateFrame("Button", nil, leftCol, "UIPanelButtonTemplate")
    BTN.myBids:SetSize(154, 22); BTN.myBids:SetPoint("BOTTOMLEFT", leftCol, "BOTTOMLEFT", 8, 8)
    BTN.myBids:SetText("my bids")
    BTN.myBids:SetScript("OnClick", ToggleBidsView)

    -- my-bids / scan options (all default ON). Stack bottom->top above the my-bids button:
    -- Price protection, then Always target red, then Autoscan bids.
    -- Price protection (default ON): the >5g guard. OFF = rebid expensive lots fast with the
    -- bid button (no confirm popup) and let the auto-target land on a >5g lot.
    local protectCB = CreateFrame("CheckButton", nil, leftCol, "UICheckButtonTemplate")
    protectCB:SetSize(20, 20); protectCB:SetPoint("BOTTOMLEFT", BTN.myBids, "TOPLEFT", 2, 6)
    protectCB:SetChecked(priceProtect)
    local protectLbl = protectCB:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    protectLbl:SetPoint("LEFT", protectCB, "RIGHT", 1, 0); protectLbl:SetText("Price protection")
    protectCB:SetScript("OnClick", function(self)
        priceProtect = self:GetChecked() and true or false
        if viewMode == "bids" and alwaysRedTarget then selectedItem = FirstRed() end
        UpdateTable()
    end)

    local redCB = CreateFrame("CheckButton", nil, leftCol, "UICheckButtonTemplate")
    redCB:SetSize(20, 20); redCB:SetPoint("BOTTOMLEFT", protectCB, "TOPLEFT", 0, 2)
    redCB:SetChecked(alwaysRedTarget)
    local redLbl = redCB:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    redLbl:SetPoint("LEFT", redCB, "RIGHT", 1, 0); redLbl:SetText("Always target red")
    redCB:SetScript("OnClick", function(self)
        alwaysRedTarget = self:GetChecked() and true or false
        if viewMode == "bids" and alwaysRedTarget then selectedItem = FirstRed() end
        UpdateTable()
    end)

    local autoCB = CreateFrame("CheckButton", nil, leftCol, "UICheckButtonTemplate")
    autoCB:SetSize(20, 20); autoCB:SetPoint("BOTTOMLEFT", redCB, "TOPLEFT", 0, 2)
    autoCB:SetChecked(autoScanBids)
    local autoLbl = autoCB:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    autoLbl:SetPoint("LEFT", autoCB, "RIGHT", 1, 0); autoLbl:SetText("Autoscan bids")
    autoCB:SetScript("OnClick", function(self)
        autoScanBids = self:GetChecked() and true or false
        if viewMode == "bids" and autoScanBids then RefreshMyBids(true) end
    end)

    -- counters sit directly under the buy/Dis.loot row. (The scan progress bar was
    -- moved out of the left panel into the top header - see next to the Rarity dropdown.)
    cacheFS = leftCol:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    cacheFS:SetPoint("TOPLEFT", BTN.buy, "BOTTOMLEFT", 0, -4); cacheFS:SetText("Cache: 0")
    foundFS = leftCol:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    foundFS:SetPoint("TOPLEFT", cacheFS, "BOTTOMLEFT", 0, -3); foundFS:SetText("Found: 0")

    -- time-left filter: 4 buckets the legacy AH actually exposes (no 24/48h split)
    local timeHdr = leftCol:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    timeHdr:SetPoint("TOPLEFT", foundFS, "BOTTOMLEFT", 0, -6); timeHdr:SetText("Time left:")
    local TIME_OPTS = { {1,"<30m"}, {2,"30m-2h"}, {3,"2-12h"}, {4,">12h"} }
    local timeChecks = {}
    for i, opt in ipairs(TIME_OPTS) do
        local cb = CreateFrame("CheckButton", nil, leftCol, "UICheckButtonTemplate")
        cb:SetSize(20, 20)
        if i == 1 then cb:SetPoint("TOPLEFT", timeHdr, "BOTTOMLEFT", 0, -3)
        elseif i == 2 then cb:SetPoint("LEFT", timeChecks[1], "LEFT", 78, 0)
        elseif i == 3 then cb:SetPoint("TOPLEFT", timeChecks[1], "BOTTOMLEFT", 0, -2)
        else cb:SetPoint("LEFT", timeChecks[3], "LEFT", 78, 0) end
        cb:SetChecked(true)
        cb.code = opt[1]
        local lbl = cb:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        lbl:SetPoint("LEFT", cb, "RIGHT", 1, 0); lbl:SetText(opt[2])
        cb:SetScript("OnClick", function(self)
            filter.times[self.code] = self:GetChecked() and true or false
            RequestApplyFilter()
        end)
        timeChecks[i] = cb
    end

    -- bid feedback (incl. the multi-line >5g WARNING): pinned by its BOTTOM just above the
    -- three checkboxes, so it grows UPWARD into the free space and can never overlap them.
    actFS = leftCol:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    actFS:SetPoint("BOTTOMLEFT", autoCB, "TOPLEFT", -2, 6)
    actFS:SetWidth(152); actFS:SetJustifyH("LEFT"); actFS:SetJustifyV("BOTTOM"); actFS:SetWordWrap(true)  -- <162: small right margin so text doesn't touch the border

    -- right panel
    local rightPanel = CreateFrame("Frame", nil, content, bt)
    rightPanel:SetPoint("TOPLEFT", leftCol, "TOPRIGHT", 1, 0)         -- left edge 5px further left
    rightPanel:SetPoint("BOTTOMRIGHT", AuctionFrame, "BOTTOMRIGHT", -8, 12)  -- stretch to the frame's bottom-right corner
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

    -- rarity filter: a Browse-tab-style dropdown directly UNDER the status line.
    -- Picking a rarity re-runs the filter automatically, exactly like the time
    -- checkboxes, so the table shows only lots of the chosen rarity.
    local rarityHdr = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    rarityHdr:SetPoint("TOPLEFT", mBidMax.last, "TOPRIGHT", 16, -26)   -- the dropdown is anchored to this label, so it follows
    rarityHdr:SetText("Rarity:")

    local RARITY_OPTS = {
        { text = "All",      value = -1 },   -- -1 sentinel: dropdowns can't key on nil
        { text = "Poor",     value = 0 },
        { text = "Common",   value = 1 },
        { text = "Uncommon", value = 2 },
        { text = "Rare",     value = 3 },
        { text = "Epic",     value = 4 },
    }
    local function RarityText(value)
        for _, o in ipairs(RARITY_OPTS) do
            if o.value == value then
                local col = QCOLOR[value]                       -- color like the rarity itself
                return col and ("|cff" .. col .. o.text .. "|r") or o.text
            end
        end
        return "All"
    end

    local rarityDD = CreateFrame("Frame", "CheapBidsRarityDD", content, "UIDropDownMenuTemplate")
    rarityDD:SetPoint("LEFT", rarityHdr, "RIGHT", -8, -2)   -- to the RIGHT of the label (-8 trims the menu's left chrome)
    local function RarityOnClick(self)
        UIDropDownMenu_SetSelectedValue(rarityDD, self.value)
        UIDropDownMenu_SetText(rarityDD, RarityText(self.value))
        -- NOT `(v==-1) and nil or v`: that idiom returns v when the result is nil,
        -- so "All" would set quality=-1 (matches nothing) instead of nil (matches all)
        if self.value == -1 then filter.quality = nil else filter.quality = self.value end
        -- Apply IMMEDIATELY (a rarity pick is a deliberate, non-spammable click, so bypass the
        -- search/checkbox throttle - that throttle was why the list "didn't react" to the pick).
        ApplyFilter()
        -- Rarity comes from GetItemInfo, which loads ASYNC for uncached lots; the pass above only
        -- kicks those loads off. One re-apply is not enough on a big cache (the lot's rarity stays
        -- unresolved until it caches), which is why it "started working by itself" later. Re-apply
        -- a few times over ~4s so the filter converges automatically as the item cache warms.
        if filter.quality ~= nil then
            for _, delay in ipairs({ 0.4, 1.0, 2.0, 4.0 }) do
                C_Timer.After(delay, function()
                    if uiBuilt and not isScanning and viewMode == "scan" and filter.quality ~= nil then ApplyFilter() end
                end)
            end
        end
    end
    UIDropDownMenu_Initialize(rarityDD, function()
        for _, opt in ipairs(RARITY_OPTS) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = RarityText(opt.value)
            info.value = opt.value
            info.func = RarityOnClick
            info.checked = (filter.quality == nil and opt.value == -1) or (filter.quality == opt.value)
            UIDropDownMenu_AddButton(info)
        end
    end)
    UIDropDownMenu_SetWidth(rarityDD, 90)
    UIDropDownMenu_SetSelectedValue(rarityDD, -1)
    UIDropDownMenu_SetText(rarityDD, RarityText(-1))

    -- scan / GetAll progress bar: lives in the top header, to the RIGHT of the Rarity
    -- dropdown (moved here from the left panel, where it overlapped the Cache counter).
    progBar = CreateFrame("StatusBar", nil, content)
    progBar:SetSize(150, 14); progBar:SetPoint("LEFT", rarityDD, "RIGHT", -8, 2)
    progBar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar"); progBar:SetStatusBarColor(0.2,0.6,1.0)
    progBar:SetMinMaxValues(0, 1); progBar:SetValue(0)
    local pbBg = progBar:CreateTexture(nil, "BACKGROUND"); pbBg:SetAllPoints(); pbBg:SetColorTexture(0,0,0,0.5)
    progBar.txt = progBar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); progBar.txt:SetPoint("CENTER", progBar, "CENTER", 0, 0)
    progBar:Hide()

    BTN.scan:SetScript("OnClick", function()
        if isScanning then AbortScan(); return end
        if not (AuctionFrame and AuctionFrame:IsVisible()) then return end
        StartScan()
    end)
    BTN.search:SetScript("OnClick", function()
        if isScanning then return end
        if #scanCache == 0 then statusFS:SetText("Run \"" .. SCAN_BTN .. "\" first.") return end
        RequestApplyFilter()
    end)
    BTN.bid:SetScript("OnClick", DoSingleBid)
    BTN.stop:SetScript("OnClick", StopAll)

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
        if not isScanning and BTN.scan then
            local _, canAll = CanSendAuctionQuery()
            local fs = BTN.scan:GetFontString()
            if canAll then
                BTN.scan:SetText(SCAN_BTN)
                if fs then fs:SetTextColor(0.3, 1.0, 0.3) end            -- green = scan now
            else
                local last = (CheapBidsDB and CheapBidsDB.lastGetAll) or 0
                local left = last > 0 and (GETALL_COOLDOWN - (time() - last)) or 0
                if left > 0 then
                    BTN.scan:SetText(string.format("scan %d:%02d", math.floor(left / 60), left % 60))  -- compact: narrow button
                else
                    BTN.scan:SetText(SCAN_BTN)                            -- estimate elapsed, server still gating
                end
                if fs then fs:SetTextColor(1, 1, 1) end                 -- white = not ready yet
            end
        end
        C_Timer.After(2, tick)
    end
    tick()
end

-- Hide the previous tab's panel so its dark background doesn't linger behind our
-- partly-transparent filter row. Hides the 3 default panels AND any other LARGE
-- child panel (e.g. an Auctioneer/Auctionator tab frame). The frame's stone art is
-- a texture (not a child frame), and the tab buttons / close button are small, so
-- they are left untouched.
local function HideOtherAHFrames()
    if AuctionFrameBrowse then AuctionFrameBrowse:Hide() end
    if AuctionFrameBid then AuctionFrameBid:Hide() end
    if AuctionFrameAuctions then AuctionFrameAuctions:Hide() end
    for _, c in ipairs({ AuctionFrame:GetChildren() }) do
        if c ~= content and c.IsShown and c:IsShown()
           and c.IsObjectType and c:IsObjectType("Frame") then
            local nm = c.GetName and c:GetName()
            if not (nm and nm:find("AuctionFrameTab"))
               and (c:GetWidth() or 0) > 200 and (c:GetHeight() or 0) > 200 then
                c:Hide()
            end
        end
    end
end

local function ShowCB()
    if not content then return end
    HideOtherAHFrames()
    content:Show()
    BuildTable()
    if not fauxScroll then C_Timer.After(0.05, BuildTable) end
    UpdateTable()
    if #cheapItems > 0 and not cacheFromGetAll and statusFS then
        statusFS:SetText("List from a previous scan. After reopening the AH the snapshot is stale - run \"scan auc\" again to bid.")
    end
    if myTabID then PanelTemplates_SetTab(AuctionFrame, myTabID) end
    PollGetAllReady()                       -- light up "scan auc" green when GetAll is available
    -- re-hide next frame in case the default/other addon re-showed its panel after us
    C_Timer.After(0, function() if content and content:IsShown() then HideOtherAHFrames() end end)
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
pcall(ev.RegisterEvent, ev, "AUCTION_BIDDER_LIST_UPDATE")   -- Bids tab (guarded: name varies by client)
pcall(ev.RegisterEvent, ev, "AUCTION_OWNED_LIST_UPDATE")    -- Auctions tab

ev:SetScript("OnEvent", function(_, event, arg1, arg2)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        CheapBidsDB = CheapBidsDB or {}
        CheapBidsDB.myBids = nil           -- drop the removed "old bids" saved record
        priceDB = CheapBidsDB.priceDB or {}   -- Auc min price survives reloads until the next GetAll
        priceCount = CheapBidsDB.priceCount or {}
        print("|cff00cc00[CheapBids]|r loaded. IMPORTANT: disable Auctioneer/Auctionator to bid.")
    elseif event == "AUCTION_HOUSE_SHOW" then
        CreateTab()
        floodMode = false; floodAnchor = 0; prevErrAt = 0   -- fresh AH session -> exit flood mode
        ev:RegisterEvent("CHAT_MSG_SYSTEM")
        ev:RegisterEvent("UI_ERROR_MESSAGE")
    elseif event == "AUCTION_HOUSE_CLOSED" then
        if isScanning or scanMode then FinishScan() end
        cacheFromGetAll = false; scanMode = nil; HideProgress()
        viewMode = "scan"; bidsPollToken = bidsPollToken + 1   -- stop the my-bids auto-refresh ticker
        pending = {}; bidWatch = bidWatch + 1
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
        if msg == AUC_ERR then
            if viewMode == "bids" then RejectBidderBid()             -- my-bids re-bid rejected -> restore + flood-lock
            elseif #pending > 0 then RejectOldest() end              -- scan bid rejected (lot gone)
        end
    elseif event == "AUCTION_ITEM_LIST_UPDATE" then
        if scanMode == "getall" and getAllPending then
            getAllPending = false
            local total = GetNumAuctionItems("list") or 0
            SetProgress(0.1); statusFS:SetText("Received " .. total .. " lots, processing...")
            ProcessGetAll(1, total)
        elseif scanMode == "page" then PageScanUpdate()
        else
            if #pending > 0 then ReconcileBids() end          -- snapshot changed after a bid -> confirm
        end
    elseif event == "AUCTION_BIDDER_LIST_UPDATE" or event == "AUCTION_OWNED_LIST_UPDATE" then
        if event == "AUCTION_BIDDER_LIST_UPDATE" and viewMode == "bids" then
            ReadMyBids(); UpdateTable()                              -- fresh bidder data -> redraw my-bids view
        end
        -- the default Bids/Auctions panel re-renders itself on these events; if OUR tab
        -- is open, re-hide it so its dark background doesn't linger behind our filter row.
        if content and content:IsShown() then HideOtherAHFrames() end
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

-- diagnostic: catch ANYTHING (another addon or the default UI) that re-queries or
-- re-sorts the live "list" AFTER our scan - that is what overwrites our GetAll
-- snapshot and makes stored indices point at the wrong lot. The stack trace names
-- the culprit. Our own scan queries are ignored (isScanning). Enable with /cb debug.
hooksecurefunc("QueryAuctionItems", function()
    if not debugOn or isScanning then return end
    print("|cffff5555[CB QUERY]|r live auction list re-queried by:")
    print(debugstack(2, 6, 0))
end)
if SortAuctionItems then
    hooksecurefunc("SortAuctionItems", function(listType, col)
        if not debugOn then return end
        print("|cffff5555[CB SORT]|r SortAuctionItems(" .. tostring(listType) .. ", " .. tostring(col) .. ") by:")
        print(debugstack(2, 6, 0))
    end)
end
if SortAuctionApplySort then
    hooksecurefunc("SortAuctionApplySort", function()
        if not debugOn then return end
        print("|cffff5555[CB SORT]|r SortAuctionApplySort by:")
        print(debugstack(2, 6, 0))
    end)
end

-- ===== Slash =====

SLASH_CHEAPBIDS1 = "/cb"
SLASH_CHEAPBIDS2 = "/cheapbids"
SlashCmdList["CHEAPBIDS"] = function(arg)
    local raw = (arg or ""):lower()
    arg = raw:gsub("%s", "")
    -- /cb check <name>: search the EXISTING scan cache (no rescan) for an item and
    -- show why it is (not) in the filtered results: bid/buyout/led/done + which
    -- filter it fails. led=1 means we stored it as "you lead it" (field 12 high).
    local checkName = raw:match("^%s*check%s+(.+)$")
    if checkName then
        checkName = checkName:gsub("%s+$", "")
        if #scanCache == 0 then print("|cffffcc00[CB check]|r no scan yet - run scan auc first.") return end
        ReadFilter()
        local n, shown = 0, 0
        for _, it in ipairs(scanCache) do
            local nm = (it.name or ""):lower()
            if nm ~= "" and nm:find(checkName, 1, true) then
                n = n + 1
                if shown < 12 then
                    shown = shown + 1
                    print(string.format("|cffffcc00[CB check]|r %s | bid=%s buy=%s led=%s done=%s | passBid=%s passTime=%s",
                        tostring(it.name), tostring(it.bid), tostring(it.buyout),
                        tostring(it.led and 1 or 0), tostring(it.done and 1 or 0),
                        tostring(PassesFilter(it.bid, it.buyout)), tostring(TimeShown(it.timeLeft))))
                end
            end
        end
        print(string.format("|cffffcc00[CB check]|r '%s': %d match(es) in cache (%d shown)", checkName, n, shown))
        return
    end
    if arg == "bids" then
        -- dump the live "bidder" list so we can confirm the API + the leading/outbid field
        pcall(GetBidderAuctionItems)
        local n = (GetNumAuctionItems and GetNumAuctionItems("bidder")) or 0
        print("|cffffcc00[CB bids]|r bidder count = " .. n .. " (if 0 but you have bids, run /cb bids again - it loads async)")
        for i = 1, math.min(n, 25) do
            local name, _, cnt, _, _, _, _, mb, mi, buy, ba, high = GetAuctionItemInfo("bidder", i)
            print(string.format("|cffffcc00[CB bids]|r [%d] %s x%s | curBid=%s nextBid=%s buy=%s | %s | tl=%s",
                i, tostring(name), tostring(cnt), tostring(ba), tostring(CalcBid(mb, mi, ba)),
                tostring(buy), high and "LEADING" or "OUTBID", tostring(GetAuctionItemTimeLeft("bidder", i))))
        end
        return
    end
    if arg == "timediag" or arg == "time" then
        -- analyze whether the EXISTING GetAll snapshot is ordered by real expiry
        -- (so a lot's idx could rank finer than the 4 time buckets). No rescan.
        TimeOrderDiag()
        return
    end
    if arg == "debug" then
        debugOn = not debugOn
        print("|cff00cc00[CheapBids]|r bid diagnostics: " .. (debugOn and "ON" or "off") ..
            ". Now place a bid normally and via CheapBids - compare the [CB debug] lines.")
        return
    end
    if arg == "frames" then
        -- dump every SHOWN child frame of AuctionFrame - run this while the leftover
        -- background is visible to see exactly which panel is still showing.
        print("|cffffcc00[CB frames]|r shown children of AuctionFrame:")
        for _, c in ipairs({ AuctionFrame:GetChildren() }) do
            if c.IsShown and c:IsShown() then
                print(string.format("  %s  %dx%d  %s",
                    tostring((c.GetName and c:GetName()) or "?"),
                    math.floor(c:GetWidth() or 0), math.floor(c:GetHeight() or 0),
                    tostring(c:GetObjectType())))
            end
        end
        return
    end
    if arg == "find" then
        -- full live-list search for the selected lot: tells us where it REALLY is
        -- vs its stored idx (one-shot, scans the whole list - a brief stutter)
        -- ONE-SHOT full diagnostic for the selected lot - works on the EXISTING
        -- snapshot, NO re-scan needed (run it on as many rows as you like after one
        -- scan). Dumps: stored data, what is live at our idx, biddable/led/total
        -- counts, nearest distance, and SAMPLES of this item's real lots.
        local it = selectedItem
        if not it then print("|cffff4444[CB find]|r select a lot in the table first.") return end
        local n = GetNumAuctionItems("list") or 0
        print(string.format("|cffffcc00[CB find]|r STORED id=%s '%s' cnt=%s buy=%s bid=%s idx=%s done=%s att=%s | liveN=%s cache=%s found=%s",
            tostring(it.itemID), tostring(it.name), tostring(it.cnt), tostring(it.buyout), tostring(it.bid),
            tostring(it.idx), tostring(it.done and 1 or 0), tostring(attempted[it] and 1 or 0),
            tostring(n), tostring(#scanCache), tostring(#cheapItems)))
        if it.idx then
            local nm, _, c2, _, _, _, _, mb, mi, b2, ba, hi, _, _, _, _, id2 = GetAuctionItemInfo("list", it.idx)
            print(string.format("|cffffcc00[CB find]|r @idx %s: id=%s '%s' cnt=%s buy=%s bid=%s high=%s",
                tostring(it.idx), tostring(id2), tostring(nm), tostring(c2), tostring(b2), tostring(CalcBid(mb, mi, ba)), tostring(hi)))
        end
        local biddable, highLed, sameAny, first, nearest = 0, 0, 0, nil, nil
        local samples = {}
        for i = 1, n do
            local _, _, cnt, _, _, _, _, mb, mi, buy, ba, high, _, _, _, _, id = GetAuctionItemInfo("list", i)
            if id and id == it.itemID then
                sameAny = sameAny + 1
                local exact = (cnt or 1) == (it.cnt or 1) and (buy or 0) == (it.buyout or 0)
                if exact and not high then
                    biddable = biddable + 1
                    if not first then first = i end
                    local d = math.abs(i - (it.idx or 0)); if not nearest or d < nearest then nearest = d end
                elseif exact and high then
                    highLed = highLed + 1
                end
                if #samples < 6 then
                    samples[#samples + 1] = string.format("[%d]cnt=%s buy=%s bid=%s hi=%s",
                        i, tostring(cnt), tostring(buy), tostring(CalcBid(mb, mi, ba)), tostring(high))
                end
            end
        end
        print(string.format("|cffffcc00[CB find]|r id=%s biddable=%s highLed=%s sameItemAny=%s first=%s nearest=%s",
            tostring(it.itemID), tostring(biddable), tostring(highLed), tostring(sameAny), tostring(first), tostring(nearest)))
        print("|cffffcc00[CB find]|r samples: " .. table.concat(samples, "  "))
        return
    end
    if myTabID and _G["AuctionFrameTab"..myTabID] then _G["AuctionFrameTab"..myTabID]:Click()
    else print("|cffff4444[CheapBids]|r Open the auction house first.") end
end

-- ===== Auc min price tooltip (Auctionator-style) =====
-- Rendered EXACTLY like Auctionator's Vendor/Auction rows: AddDoubleLine with the gold label
-- on the left and the price on the right as white numbers with REAL coin icons
-- (GetCoinTextureString) - same font, same format. Hold SHIFT to price the WHOLE hovered
-- stack ("Auc min x20"); re-hover to toggle.
-- PLACEMENT: installed as hooksecurefunc POST-hooks on the tooltip's Set* methods, NOT
-- OnTooltipSetItem. OnTooltipSetItem handlers fire DURING the Set* call, Set*-post-hooks fire
-- AFTER it - and Auctionator draws its Vendor/Auction rows from its own Set*-post-hooks
-- (registered earlier: it loads before us alphabetically). Running after it puts our row
-- directly UNDER Auctionator's, as requested. Additive hooks only - no taint (ERR-0003 class
-- untouched). Reads priceDB, which persists across reloads.
local function AucStackCount(tip, link)
    -- a CONTEXT count stashed by the Set*-hook (bag slot count, recipe reagent count,
    -- auction lot size) is authoritative - even when it is 1: a recipe needing 1 must
    -- price x1, not the item's max stack. Only context-free tooltips (chat links,
    -- comparisons) fall back to the item's max stack size.
    if tip.cbStack and tip.cbStack >= 1 then return tip.cbStack end
    local n = select(8, GetItemInfo(link))
    return (n and n > 1) and n or 1
end
-- Money text in Auctionator's exact visual format, so our row blends with its Vendor/
-- Auction rows: 12x12 coin icons with NO texture offset, a SPACE between the number and
-- its icon, a space between denominations, and silver/copper zero-padded to two digits
-- under a higher denomination ("1 [g] 91 [s] 25 [c]"). GetCoinTextureString glues the icon
-- to the digits (offset 2, no space) and skips the padding - close, but visibly different
-- next to Auctionator's rows, so we compose the string ourselves.
local COIN_ICON = {
    g = "|TInterface\\MoneyFrame\\UI-GoldIcon:12:12:0:0|t",
    s = "|TInterface\\MoneyFrame\\UI-SilverIcon:12:12:0:0|t",
    c = "|TInterface\\MoneyFrame\\UI-CopperIcon:12:12:0:0|t",
}
local function AucCoinText(copper)
    local g = math.floor(copper / 10000)
    local s = math.floor(copper % 10000 / 100)
    local c = copper % 100
    local out = ((g > 0 or s > 0) and string.format("%02d", c) or tostring(c)) .. " " .. COIN_ICON.c
    if g > 0 or s > 0 then
        out = (g > 0 and string.format("%02d", s) or tostring(s)) .. " " .. COIN_ICON.s .. " " .. out
    end
    if g > 0 then
        out = g .. " " .. COIN_ICON.g .. " " .. out
    end
    return out
end
local function PriceTip(tip)
    if CheapBidsDB and CheapBidsDB.aucTip == false then return end   -- toggled off in the options panel
    if not tip or tip.cbPriceShown or not tip.GetItem then return end -- several Set*-hooks can re-fire
    local _, link = tip:GetItem()
    if not link then return end
    local id = tonumber(string.match(link, "item:(%d+)"))
    if not id then return end
    local p = priceDB[id]
    if not p or p <= 0 then return end                              -- item never seen with a buyout
    tip.cbPriceShown = true
    local label, amount = "Auc min", p
    if IsShiftKeyDown() then
        local n = AucStackCount(tip, link)
        -- the " x20" multiplier is light blue, exactly like Auctionator's (LIGHTBLUE_FONT_COLOR)
        local xs = " x" .. n
        if LIGHTBLUE_FONT_COLOR and LIGHTBLUE_FONT_COLOR.WrapTextInColorCode then
            xs = LIGHTBLUE_FONT_COLOR:WrapTextInColorCode(xs)
        else
            xs = "|cff8080ff" .. xs .. "|r"
        end
        label, amount = "Auc min" .. xs, p * n
    end
    tip:AddDoubleLine(label, AucCoinText(amount), 1, 0.82, 0, 1, 1, 1)   -- gold label, white price
    tip:Show()                                                      -- re-fit for the new line
end
-- capture the hovered stack size for the SHIFT = whole-stack price (bag slots only)
-- Per-method CONTEXT count extractors: what "x N" should mean for THIS tooltip.
-- SetBagItem -> how many are in the hovered bag slot; SetTradeSkillItem/SetCraftItem
-- with a reagent index -> how many the RECIPE needs (Auctionator's "Vendor x4" number,
-- the bug: we showed the max stack instead); SetAuctionItem -> the lot's size.
-- Methods not listed stash nothing -> AucStackCount falls back to the max stack.
local STACK_FROM = {
    SetBagItem = function(bag, slot)
        if C_Container and C_Container.GetContainerItemInfo then
            local info = C_Container.GetContainerItemInfo(bag, slot)
            return info and info.stackCount
        elseif GetContainerItemInfo then
            return (select(2, GetContainerItemInfo(bag, slot)))
        end
    end,
    SetTradeSkillItem = function(skill, index)
        if index and GetTradeSkillReagentInfo then
            return (select(3, GetTradeSkillReagentInfo(skill, index)))   -- reagentCountRequired
        end
    end,
    SetCraftItem = function(craft, index)
        if index and GetCraftReagentInfo then
            return (select(3, GetCraftReagentInfo(craft, index)))        -- reagentCountRequired
        end
    end,
    SetAuctionItem = function(listType, index)
        if GetAuctionItemInfo then
            return (select(3, GetAuctionItemInfo(listType, index)))      -- lot stack size
        end
    end,
}
-- every item-bearing Set* method we care about (skipped silently where a method
-- does not exist on this client/tooltip)
local PRICE_TIP_METHODS = {
    "SetBagItem", "SetInventoryItem", "SetHyperlink", "SetAuctionItem", "SetAuctionSellItem",
    "SetLootItem", "SetLootRollItem", "SetMerchantItem", "SetBuybackItem", "SetQuestItem",
    "SetQuestLogItem", "SetTradeSkillItem", "SetCraftItem", "SetSendMailItem", "SetInboxItem",
    "SetTradePlayerItem", "SetTradeTargetItem", "SetGuildBankItem", "SetCompareItem",
}
local function HookPriceTip(tip)
    if not tip or not tip.HookScript then return end
    tip:HookScript("OnTooltipCleared", function(t) t.cbPriceShown = nil; t.cbStack = nil end)
    for _, m in ipairs(PRICE_TIP_METHODS) do
        if type(tip[m]) == "function" then
            local stackFn = STACK_FROM[m]
            if stackFn then
                hooksecurefunc(tip, m, function(t, a1, a2) t.cbStack = stackFn(a1, a2); PriceTip(t) end)
            else
                hooksecurefunc(tip, m, PriceTip)
            end
        end
    end
end
HookPriceTip(GameTooltip); HookPriceTip(ItemRefTooltip)
HookPriceTip(ShoppingTooltip1); HookPriceTip(ShoppingTooltip2)

-- Tiny public surface for our plug-in modules (e.g. the Disenchant-price tooltip row):
-- the LIVE per-unit market price (reads the same local priceDB the rest of this file
-- uses - the saved CheapBidsDB.priceDB copy would go stale within a session) and the
-- exact Auctionator-style coin formatter, so module rows render identically to ours.
-- A fresh global of our own, not a Blizzard table - no taint (ERR-0003 class untouched).
CheapBidsPublic = {
    UnitPrice = function(itemID)
        local p = itemID and priceDB[itemID]
        if p and p > 0 then return p end
    end,
    CoinText = AucCoinText,
}

-- ===== In-game options panel (Interface -> AddOns -> CheapBids) =====
-- Manually-tunable knobs, persisted in CheapBidsDB and read live by the code above.
-- Price-protection numbers take effect immediately; tooltip/browse toggles apply on the
-- next hover (Compact Browse: after /reload). Built inside pcall so an options-API quirk
-- on some client build can never stop the addon from loading.
local OPT_PCT_DEF, OPT_FALLBACK_DEF_G = 70, 100
local function OptPct()      local v = CheapBidsDB and CheapBidsDB.protectFraction; return (type(v)=="number") and math.floor(v*100+0.5) or OPT_PCT_DEF end
local function OptFallback() local v = CheapBidsDB and CheapBidsDB.protectFallback; return (type(v)=="number") and math.floor(v/10000) or OPT_FALLBACK_DEF_G end
local function SetPct(pct)      pct = tonumber(pct); if not pct then return end; if pct<1 then pct=1 elseif pct>100 then pct=100 end; CheapBidsDB = CheapBidsDB or {}; CheapBidsDB.protectFraction = pct/100 end
local function SetFallback(g)   g = tonumber(g);  if not g or g<0 then return end; CheapBidsDB = CheapBidsDB or {}; CheapBidsDB.protectFallback = math.floor(g)*10000 end

local function BuildOptionsPanel()
    local panel = CreateFrame("Frame", "CheapBidsOptionsPanel")
    panel.name = "CheapBids"

    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16); title:SetText("CheapBids")
    local sub = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -4)
    sub:SetText("Auction sniping helper - options are saved per account.")

    local yy = -66
    local checks = {}
    local function addCheck(label, key, needsReload)
        local cb = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
        cb:SetPoint("TOPLEFT", 16, yy); cb:SetSize(24, 24)
        local fs = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        fs:SetPoint("LEFT", cb, "RIGHT", 2, 0)
        fs:SetText(label .. (needsReload and "  |cff808080(needs /reload)|r" or ""))
        cb:SetScript("OnClick", function(self) CheapBidsDB = CheapBidsDB or {}; CheapBidsDB[key] = self:GetChecked() and true or false end)
        cb._key = key; checks[#checks+1] = cb; yy = yy - 26
    end
    addCheck("Auc min price tooltip", "aucTip")
    addCheck("Disenchant tooltip",    "disenchantTip")
    addCheck("Prospect tooltip",      "prospectTip")
    addCheck("Compact Browse tab",    "compactBrowse", true)

    yy = yy - 8
    local edits = {}
    local function addEdit(label, getf, setf)
        local fs = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        fs:SetPoint("TOPLEFT", 20, yy); fs:SetText(label)
        local eb = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
        eb:SetPoint("LEFT", fs, "RIGHT", 12, 0); eb:SetSize(70, 20)
        eb:SetAutoFocus(false); eb:SetNumeric(true)
        eb:SetScript("OnEnterPressed", function(self) setf(self:GetText()); self:SetText(tostring(getf())); self:ClearFocus() end)
        eb:SetScript("OnEscapePressed", function(self) self:SetText(tostring(getf())); self:ClearFocus() end)
        eb._get = getf; edits[#edits+1] = eb; yy = yy - 30
    end
    addEdit("Price protection cap, % of market value:", OptPct, SetPct)
    addEdit("Protection fallback when unpriced, gold:", OptFallback, SetFallback)

    panel.refresh = function()
        for _, cb in ipairs(checks) do cb:SetChecked((CheapBidsDB == nil) or (CheapBidsDB[cb._key] ~= false)) end
        for _, eb in ipairs(edits) do eb:SetText(tostring(eb._get())) end
    end
    panel.okay = function() end
    panel:SetScript("OnShow", panel.refresh)

    if InterfaceOptions_AddCategory then
        InterfaceOptions_AddCategory(panel)
    elseif Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory then
        Settings.RegisterAddOnCategory(Settings.RegisterCanvasLayoutCategory(panel, panel.name))
    end
end
pcall(BuildOptionsPanel)

-- ===== Test hook =====
-- No in-game effect: WoW never sets the CheapBidsTest global. The standalone test
-- harness (tests/) sets _G.CheapBidsTest = {} BEFORE loading this file, then uses
-- these to unit-test the REAL internal logic against a mocked WoW API.
if CheapBidsTest then
    CheapBidsTest.fn = {
        CalcBid = CalcBid, PassesFilter = PassesFilter, TimeShown = TimeShown,
        FirstRed = FirstRed, ReadMyBids = ReadMyBids, RefreshMyBids = RefreshMyBids,
        RebidBidder = RebidBidder, RejectBidderBid = RejectBidderBid, DismissRow = DismissRow,
        BidItem = BidItem, CommitScanBid = CommitScanBid,
        ActiveList = ActiveList, SortItems = SortItems, UpdateButtons = UpdateButtons, ReadFilter = ReadFilter,
        ItemLink = ItemLink,
        ReadIndexInto = ReadIndexInto, AucUnit = AucUnit, PriceTip = PriceTip,
        AucCoinText = AucCoinText, STACK_FROM = STACK_FROM,
        DisValue = DisValue, DisProfit = DisProfit, ApplyDisLoot = ApplyDisLoot, BuyItem = BuyItem,
        IsBig = IsBig, NeedsConfirm = NeedsConfirm, ProtectThreshold = ProtectThreshold,
        OptPct = OptPct, SetPct = SetPct, OptFallback = OptFallback, SetFallback = SetFallback,
    }
    CheapBidsTest.set = function(k, v)
        if k == "myBids" then myBids = v
        elseif k == "scanCache" then scanCache = v
        elseif k == "priceDB" then priceDB = v
        elseif k == "priceCount" then priceCount = v
        elseif k == "scanPriceDB" then scanPriceDB = v
        elseif k == "scanPriceCount" then scanPriceCount = v
        elseif k == "cheapItems" then cheapItems = v
        elseif k == "viewMode" then viewMode = v
        elseif k == "selectedItem" then selectedItem = v
        elseif k == "alwaysRedTarget" then alwaysRedTarget = v
        elseif k == "autoScanBids" then autoScanBids = v
        elseif k == "priceProtect" then priceProtect = v
        elseif k == "bidsDismissed" then bidsDismissed = v
        elseif k == "filter" then filter = v
        elseif k == "sortKey" then sortKey = v
        elseif k == "sortAsc" then sortAsc = v
        elseif k == "isScanning" then isScanning = v
        else error("CheapBidsTest.set: unknown key " .. tostring(k)) end
    end
    CheapBidsTest.get = function(k)
        if k == "myBids" then return myBids
        elseif k == "viewMode" then return viewMode
        elseif k == "selectedItem" then return selectedItem
        elseif k == "alwaysRedTarget" then return alwaysRedTarget
        elseif k == "autoScanBids" then return autoScanBids
        elseif k == "bidsDismissed" then return bidsDismissed
        elseif k == "filter" then return filter
        elseif k == "priceDB" then return priceDB
        elseif k == "scanPriceDB" then return scanPriceDB
        else error("CheapBidsTest.get: unknown key " .. tostring(k)) end
    end
end
