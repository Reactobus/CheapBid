-- ===========================================================================
-- CheapBids CompactBrowse
-- ---------------------------------------------------------------------------
-- A self-contained port of Auctioneer's "Auc-Util-CompactUI" module: it turns
-- the DEFAULT Blizzard auction Browse tab into a dense list of THIN 19px rows
-- (14 rows instead of ~8), so you see far more auctions at a glance. Item names
-- are drawn as item links, so they carry their rarity colour automatically.
--
-- How the original works, kept here 1:1:
--   * hide Blizzard's column-sort header buttons,
--   * hide + drop the default BrowseButton1..N, build 14 compact ones (19px),
--   * replace the GLOBAL AuctionFrameBrowse_Update with our own updater,
--   * on every list update read GetAuctionItemInfo("list", i) into a page table,
--     (optionally client-sorted by the clicked header) and paint the 14 rows.
--
-- Everything Auc-Advanced-specific is stripped: no price-level "Pct" column, no
-- seller-ignore, no Configator options window, no localization, no CreateMoney
-- widget (we use GetCoinTextureString instead).
--
-- TAINT NOTE (see CheapBids/docs/LESSONS.md, class of ERR-0003): we DO reassign
-- the global *function* AuctionFrameBrowse_Update. That only taints the Browse
-- update path itself - it does NOT poison unrelated secure popups the way writing
-- a global *table* (StaticPopupDialogs) did. Bidding still goes through Blizzard's
-- own BrowseBidButton: we only set the selection + bid price from the hardware
-- row-click path, exactly like CompactUI, which is what keeps bids working.
--
-- This is a SEPARATE plug-in addon (folder CheapBids_CompactBrowse, its own .toc
-- with "## Dependencies: CheapBids"), exactly like an Auctioneer sub-module hangs
-- off Auc-Advanced. It touches nothing in CheapBids.lua and shares no code with the
-- scan/bid engine, so it can be switched off with /cbrowse (persisted in
-- CheapBidsDB.compactBrowse) or unticked in the AddOns list without any effect on
-- CheapBids itself. Displayed text is ASCII only (rarity comes from the item link).
--
-- License: GNU GPL v2 or later, see LICENSE. Modified in 2026 by Reactobus from
-- Auc-Util-CompactUI, part of Auctioneer by Norganna's AddOns
-- (http://auctioneeraddon.com/), GPL v2 or later.
-- ===========================================================================

local M = {}
M.buttons     = {}
M.pageContents = {}
M.huge        = false        -- true when "list" holds a GetAll dump: skip build/sort, read live
M.sortField   = nil          -- nil = server order; else a field name below
M.sortDir     = 1            -- 1 asc, -1 desc
M.active      = false        -- did we install the override this session

local NUM_ROWS  = 15         -- one more than CompactUI: we freed a row by putting the
local ROW_H     = 19         -- results count on the SAME line as the pager (see Install)
local ROW_W     = 610
local HUGE_PAGE = 200        -- above this many "list" rows we assume a GetAll snapshot

-- ---- money / time helpers (no Auc-Advanced dependency) --------------------
-- Compact, coloured-LETTER money (g/s/c), NOT GetCoinTextureString: the coin-icon
-- textures are fixed-width and wide, so big prices overflowed the Bid/Buy columns
-- and got clipped to "...". We show only the TWO highest non-zero denominations,
-- which is exact for cheap lots (s/c) and plenty precise for gear (g). The real bid
-- amount is taken from the live data, never from this text, so trimming is safe.
local Gc, Sc, Cc = "ffd700", "c7c7cf", "eda55f"   -- gold / silver / copper colours
local function MoneyStr(copper)
    copper = tonumber(copper)
    if not copper or copper <= 0 then return "" end
    local g = math.floor(copper / 10000)
    local s = math.floor(copper % 10000 / 100)
    local c = copper % 100
    if g > 0 then
        if s > 0 then return g .. "|cff" .. Gc .. "g|r" .. s .. "|cff" .. Sc .. "s|r" end
        return g .. "|cff" .. Gc .. "g|r"
    elseif s > 0 then
        if c > 0 then return s .. "|cff" .. Sc .. "s|r" .. c .. "|cff" .. Cc .. "c|r" end
        return s .. "|cff" .. Sc .. "s|r"
    end
    return c .. "|cff" .. Cc .. "c|r"
end

local TIME_TEXT = { [1] = "<30m", [2] = "2h", [3] = "12h", [4] = ">12h" }
local function TimeStr(code) return TIME_TEXT[code or 0] or "" end

-- ---- read one live "list" row into a plain data table ---------------------
-- Field layout is the one CheapBids.lua already relies on for this 2.5.5 client:
-- 1name 2tex 3cnt 4qual 5canUse 6level 7lvlCol 8minBid 9minInc 10buyout 11bidAmt
-- 12highBidder 13bidderFullName 14owner 15ownerFullName 16saleStatus 17itemID
local function BuildRow(i)
    local name, tex, cnt, qual, _, level, levelCol, minBid, minInc, buyout, bidAmt,
          high, _, owner = GetAuctionItemInfo("list", i)
    local link = GetAuctionItemLink("list", i)
    if not link and (not name or name == "") then return nil end

    if not cnt or cnt < 1 then cnt = 1 end
    minBid, minInc, buyout, bidAmt = minBid or 0, minInc or 0, buyout or 0, bidAmt or 0

    -- effective required bid (same rule as CheapBids.lua CalcBid, capped at buyout)
    local requiredBid
    if bidAmt > 0 then
        requiredBid = bidAmt + minInc
        if buyout > 0 and requiredBid > buyout then requiredBid = buyout end
    elseif minBid > 0 then
        requiredBid = minBid
    else
        requiredBid = 1
    end

    -- Min column shows the required/min level; iLvl from GetItemInfo (async, may be blank)
    local itemLevel = 0
    if link then itemLevel = select(4, GetItemInfo(link)) or 0 end
    if levelCol == "ITEM_LEVEL_ABBR" then itemLevel = level or itemLevel end

    return {
        id = i, count = cnt, texture = tex, quality = qual or 1,
        name = name or "", link = link,
        minLevel = level or 0, itemLevel = tonumber(itemLevel) or 0,
        timeLeft = GetAuctionItemTimeLeft("list", i) or 0,
        owner = owner or "",
        minBid = minBid, bidAmount = bidAmt, minIncrement = minInc,
        requiredBid = requiredBid, buyout = buyout, highBidder = high or false,
    }
end

-- ---- client-side sort of the current page (mirrors CompactUI's page sort) --
local function Compare(a, b)
    local f = M.sortField
    local va, vb = a[f], b[f]
    if va ~= vb then
        if type(va) == "string" or type(vb) == "string" then
            va, vb = tostring(va), tostring(vb)
        end
        if M.sortDir > 0 then return va < vb else return va > vb end
    end
    return (a.name or "") < (b.name or "")   -- stable tiebreak by name
end

function M.RetrievePage()
    wipe(M.pageContents)
    local num, total = GetNumAuctionItems("list")
    num, total = num or 0, total or 0
    if num == 0 then M.huge = false; return 0, 0 end
    if num > HUGE_PAGE then M.huge = true; return num, total end   -- GetAll dump: don't build/sort
    M.huge = false
    for i = 1, num do
        local row = BuildRow(i)
        if row then M.pageContents[#M.pageContents + 1] = row end
    end
    -- only client-sort when the SERVER did not (i.e. the iLvl fallback); a server sort
    -- already ordered every page, so re-sorting the page here would fight it.
    if M.sortField and not M.serverSorted then table.sort(M.pageContents, Compare) end
    return num, total
end

-- ---- paint one button from a data row (or hide it) ------------------------
function M.SetAuction(button, data, slot)
    if not data then button.id = nil; button:Hide(); return end

    local selected = (GetSelectedAuctionItem("list") == data.id)
    button.id = data.id

    -- Zebra by ON-SCREEN slot parity, not data.id: after a client-side header sort the
    -- live-list ids no longer alternate down the screen, so id parity gave an irregular
    -- stripe. slot (1..NUM_ROWS) always alternates cleanly. data.id stays the live index
    -- used for selection / bidding below - untouched.
    if selected then
        button.Line:SetColorTexture(1, 1, 0.3, 0.2)
    elseif (slot and slot % 2 == 0) then
        button.Line:SetColorTexture(0.3, 0.3, 0.4, 0.1)
    else
        button.Line:SetColorTexture(0, 0, 0.1, 0.1)
    end

    -- stack size (kept, but shown as a small "xN" tag before the name, not a column)
    local ntext = data.link or data.name or ""
    if data.count and data.count > 1 then ntext = "|cffa0a0a0x" .. data.count .. "|r " .. ntext end
    button.Icon:SetTexture(data.texture or 134400)
    button.Name:SetText(ntext)                    -- item link => rarity colour for free
    button.Min:SetText((data.minLevel and data.minLevel > 0) and data.minLevel or "")
    button.ILvl:SetText((data.itemLevel and data.itemLevel > 0) and data.itemLevel or "")
    button.Left:SetText(TimeStr(data.timeLeft))
    button.Owner:SetText(data.owner)
    button.Bid:SetText(MoneyStr(data.requiredBid))
    button.Buy:SetText(MoneyStr(data.buyout))

    -- When this row is the selected one, arm Blizzard's own bid/buyout buttons.
    -- This runs inside the hardware-driven update (row click -> update), so the
    -- selection and bid price are set from a real click, exactly like CompactUI.
    if selected then
        MoneyInputFrame_SetCopper(BrowseBidPrice, data.requiredBid)
        if data.buyout > 0 and data.buyout >= data.minBid then
            local canBuyout = true
            if GetMoney() < data.buyout then
                if (not data.highBidder) or (GetMoney() + data.bidAmount < data.buyout) then
                    canBuyout = false
                end
            end
            if canBuyout then
                BrowseBuyoutButton:Enable()
                AuctionFrame.buyoutPrice = data.buyout
            end
        else
            AuctionFrame.buyoutPrice = nil
        end
        if (not data.highBidder) and data.owner ~= UnitName("player") then
            if GetMoney() >= data.requiredBid and data.requiredBid <= MAXIMUM_BID_PRICE then
                BrowseBidButton:Enable()
            end
        end
    end
    button:Show()
end

-- ---- keep Blizzard's native browse column-sort headers hidden -------------
-- Their exact global names vary between 2.5.5 builds (Level/Duration/Seller/
-- CurrentBid...) and Blizzard re-shows them on filter clicks, so we collect them
-- ONCE by name + by a "Browse*Sort" child pattern, then re-hide on every paint.
local NATIVE_HEADERS
local function CollectNativeHeaders()
    NATIVE_HEADERS = {}
    local names = {
        "BrowseQualitySort", "BrowseLevelSort", "BrowseDurationSort",
        "BrowseHighBidderSort", "BrowseCurrentBidSort", "BrowseBuyoutSort",
        "BrowseSellerSort", "BrowseOwnerSort", "BrowseNameSort", "BrowseItemSort",
    }
    for _, n in ipairs(names) do if _G[n] then NATIVE_HEADERS[_G[n]] = true end end
    if AuctionFrameBrowse then
        for _, kid in ipairs({ AuctionFrameBrowse:GetChildren() }) do
            local n = kid.GetName and kid:GetName()
            if n and n:match("^Browse") and n:match("Sort") then NATIVE_HEADERS[kid] = true end
        end
    end
end
local function HideNativeHeaders()
    if not NATIVE_HEADERS then return end
    for f in pairs(NATIVE_HEADERS) do if f.Hide then f:Hide() end end
end

-- ---- our replacement for the global AuctionFrameBrowse_Update --------------
function M.Update()
    if not AuctionFrameBrowse or not AuctionFrameBrowse:IsVisible() then return end
    if TOKEN_FILTER_LABEL and AuctionFrameBrowse.selectedClass == TOKEN_FILTER_LABEL then return end
    if not BrowseScrollFrame then return end
    HideNativeHeaders()   -- Blizzard re-shows its own sort headers; keep them hidden

    local num, total = M.RetrievePage()

    -- After a buyout the bought auction vanishes and the rest shift up, so re-selecting
    -- the SAME index lands the target on the NEXT item (see the BrowseBuyoutButton hook).
    -- Fire ONLY on a genuine, matched buy: within a few seconds of the click, on the same
    -- page, with the result total actually dropped, and only while the display order equals
    -- the live "list" order (a client-side iLvl sort scrambles indices, and the index is
    -- page-relative so it must stay on the click's page). Always clear the flags once the
    -- buy resolves OR the window lapses, so a stale advance can never hijack a later query.
    if M.advanceIdx then
        if (not M.advanceTime) or (GetTime() - M.advanceTime >= 5) then
            M.advanceIdx, M.advanceTotal, M.advancePage, M.advanceTime = nil, nil, nil, nil
        elseif M.advanceTotal and total < M.advanceTotal then
            local samePage  = (AuctionFrameBrowse.page or 0) == M.advancePage
            local liveOrder = (not M.sortField) or M.serverSorted
            if samePage and liveOrder and num > 0 then
                local t = M.advanceIdx
                if t > num then t = num end
                if t >= 1 then SetSelectedAuctionItem("list", t) end
            end
            M.advanceIdx, M.advanceTotal, M.advancePage, M.advanceTime = nil, nil, nil, nil
        end
    end

    local offset = FauxScrollFrame_GetOffset(BrowseScrollFrame)

    if BrowseBidButton   then BrowseBidButton:Disable()   end
    if BrowseBuyoutButton then BrowseBuyoutButton:Disable() end
    if BrowseNoResultsText then BrowseNoResultsText:SetShown(num == 0) end

    for i = 1, NUM_ROWS do
        local button = M.buttons[i]
        local index  = offset + i
        if index > num then
            M.SetAuction(button, nil, i)
        elseif M.huge then
            M.SetAuction(button, BuildRow(index), i)       -- GetAll dump: read live, no sort
        else
            M.SetAuction(button, M.pageContents[index], i)
        end
    end

    local rowH = AUCTIONS_BUTTON_HEIGHT or ROW_H
    FauxScrollFrame_Update(BrowseScrollFrame, num, NUM_ROWS, rowH)

    -- pager / result count
    if total > 0 then
        if M.candy then for _, c in ipairs(M.candy) do c:Show() end end
        local page   = AuctionFrameBrowse.page or 0
        local perPg  = NUM_AUCTION_ITEMS_PER_PAGE
        local pageMax = math.max(1, math.ceil(total / perPg))
        if BrowseSearchCountText then
            local lo = page * perPg + 1
            BrowseSearchCountText:SetFormattedText(NUMBER_OF_RESULTS_TEMPLATE, lo, lo + num - 1, total)
            BrowseSearchCountText:Show()
        end
        -- This client gates the page arrows through an ".isEnabled" flag (same as the
        -- original Auc CompactUI) - a bare :Enable() gets overridden and the button
        -- stays greyed. Set the flag AND Enable/Disable so it works either way.
        if BrowsePrevPageButton then
            local on = page > 0
            BrowsePrevPageButton:Show(); BrowsePrevPageButton.isEnabled = on
            if on then BrowsePrevPageButton:Enable() else BrowsePrevPageButton:Disable() end
        end
        if BrowseNextPageButton then
            local on = page < pageMax - 1
            BrowseNextPageButton:Show(); BrowseNextPageButton.isEnabled = on
            if on then BrowseNextPageButton:Enable() else BrowseNextPageButton:Disable() end
        end
        if M.pageNum then M.pageNum:SetFormattedText("%d/%d", page + 1, pageMax) end
    else
        if M.candy then for _, c in ipairs(M.candy) do c:Hide() end end
        if BrowsePrevPageButton  then BrowsePrevPageButton:Hide()  end
        if BrowseNextPageButton  then BrowseNextPageButton:Hide()  end
        if BrowseSearchCountText then BrowseSearchCountText:Hide() end
    end
end

-- ---- row interaction (click to select / modified-click to link) -----------
local function RowClick(button, mouseButton)
    if not button.id then return end
    if IsModifiedClick() then
        HandleModifiedItemClick(GetAuctionItemLink("list", button.id))
        return
    end
    if GetCVarBool("auctionDisplayOnCharacter") then
        DressUpItemLink(GetAuctionItemLink("list", button.id))
    end
    SetSelectedAuctionItem("list", button.id)   -- HARDWARE event: selection set securely
    CloseAuctionStaticPopups()
    AuctionFrameBrowse_Update()                 -- = M.Update (paints selection + arms bid)
end

-- Shared item tooltip, shown both from the icon hitbox AND from hovering the row
-- (i.e. the item name / any cell), so the name behaves like the icon.
local function ShowTip(owner, id)
    if not id then return end
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    if GameTooltip.SetAuctionItem then
        GameTooltip:SetAuctionItem("list", id)
    else
        local link = GetAuctionItemLink("list", id)
        if link then GameTooltip:SetHyperlink(link) end
    end
    GameTooltip:Show()
end
local function IconEnter(icon) ShowTip(icon, icon:GetParent().id) end
local function RowEnter(row)   ShowTip(row, row.id) end
local function HideTip()       GameTooltip:Hide() end

-- ---- column headers with click-to-sort (client side, current page) --------
-- {label, field, x, width, justify}. field=nil => not sortable ("Item" sorts by name).
-- No "#"/Count column (removed on request). Geometry MUST match the cell layout in
-- Install(). "Item" header spans the icon + name area.
local COLS = {
    { "Item",  "name",         2,  226, "LEFT"   },
    { "Min",   "minLevel",   232,   28, "RIGHT"  },
    { "iLvl",  "itemLevel",  262,   28, "RIGHT"  },
    { "Owner", "owner",      294,   96, "RIGHT"  },   -- right-aligned (per request)
    { "Bid",   "requiredBid",394,   80, "RIGHT"  },
    { "Buy",   "buyout",     478,   80, "RIGHT"  },
    { "Left",  "timeLeft",   562,   46, "CENTER" },   -- rightmost, fills to the row edge
}

-- Map our columns to the SERVER's sort keys. Using the server sort makes it order the
-- ENTIRE result set (all pages), not just the 50 rows on the current page. iLvl has no
-- server key, so it falls back to a client-side sort of the visible page only.
local SERVER_SORT = {
    name        = "name",
    minLevel    = "level",
    owner       = "seller",
    requiredBid = "bid",
    buyout      = "minbidbuyout",
    timeLeft    = "duration",
}

local function HeaderClick(self)
    local field = self.field
    if not field then return end
    if M.sortField == field then M.sortDir = -M.sortDir
    else M.sortField, M.sortDir = field, 1 end

    local col = SERVER_SORT[field]
    if col and SortAuctionSetSort and QueryAuctionItems and M.lastQuery
       and (not CanSendAuctionQuery or CanSendAuctionQuery()) then
        -- SERVER-side sort of the WHOLE result. SortAuctionApplySort alone only reorders
        -- the 50 rows already on the client (or nothing), so it never sorted across pages.
        -- Instead: set the sort key, then RE-RUN the original search from page 0 - the
        -- server then orders every page and returns page 1 of the new order. This is how
        -- Auc CompactUI does it (it captures the query params and re-issues them).
        M.serverSorted = true
        SortAuctionSetSort("list", col, M.sortDir < 0)   -- 3rd arg = reverse (descending)
        local q = M.lastQuery
        AuctionFrameBrowse.page = 0                        -- show the top of the new order
        QueryAuctionItems(q[1], q[2], q[3], 0, q[5], q[6], false, q[7], q[8])
    else
        -- iLvl (no server key) or no captured search yet: client-side sort of this page
        M.serverSorted = false
        AuctionFrameBrowse_Update()
    end
end

-- ---- one-time install onto the Browse tab ---------------------------------
function M.Install()
    if M.active then return end
    if not AuctionFrameBrowse then return end
    M.active = true
    M.candy = {}

    -- 1) hide Blizzard's own column-sort headers robustly (their names vary and they get
    --    re-shown on filter clicks / resets), and arm the after-buyout target advance.
    --    CollectNativeHeaders runs BEFORE we build our own row buttons.
    CollectNativeHeaders()
    HideNativeHeaders()
    if type(AuctionFrameFilter_OnClick) == "function" then
        hooksecurefunc("AuctionFrameFilter_OnClick", HideNativeHeaders)
    end
    if type(AuctionFrameBrowse_Reset) == "function" then
        hooksecurefunc("AuctionFrameBrowse_Reset", HideNativeHeaders)
    end
    if BrowseBuyoutButton then
        BrowseBuyoutButton:HookScript("OnClick", function()
            local idx = GetSelectedAuctionItem("list")
            if idx and idx > 0 then
                M.advanceIdx   = idx
                local _, tot   = GetNumAuctionItems("list")
                M.advanceTotal = tot or 0
                M.advancePage  = AuctionFrameBrowse.page or 0
                M.advanceTime  = GetTime()
            end
        end)
    end
    -- Remember every NORMAL Browse search's parameters, so a header click can re-run that
    -- exact search under a new server sort - the mechanism that sorts across ALL pages.
    if type(QueryAuctionItems) == "function" then
        hooksecurefunc("QueryAuctionItems", function(name, minL, maxL, page, usable, quality, getAll, exact, filterData)
            if getAll then return end   -- ignore GetAll dumps (CheapBids scans)
            M.lastQuery = { name, minL, maxL, page, usable, quality, exact, filterData }
        end)
    end

    -- 2) drop the default row buttons, build 14 compact ones (reuse the names)
    local last
    for i = 1, NUM_ROWS do
        local nm = "BrowseButton" .. i
        local orig = _G[nm]
        if orig then orig:Hide(); _G[nm] = nil end

        local b = CreateFrame("Button", nm, AuctionFrameBrowse)
        b:SetWidth(ROW_W); b:SetHeight(ROW_H); b:EnableMouse(true)
        if i == 1 then b:SetPoint("TOPLEFT", AuctionFrameBrowse, "TOPLEFT", 188, -103)
        else            b:SetPoint("TOPLEFT", last, "BOTTOMLEFT") end
        M.buttons[i] = b; last = b

        b.Line = b:CreateTexture(nil, "BACKGROUND")
        b.Line:SetPoint("TOPLEFT", 0, 0); b.Line:SetPoint("BOTTOMRIGHT", 0, 1)
        local hl = b:CreateTexture(nil, "HIGHLIGHT")
        hl:SetPoint("TOPLEFT", 0, 0); hl:SetPoint("BOTTOMRIGHT", 0, 1)
        hl:SetColorTexture(1, 1, 0.3, 0.2); b:SetHighlightTexture(hl, "ADD")

        local function FS(x, w, justify, size)
            local fs = b:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            fs:SetPoint("TOPLEFT", b, "TOPLEFT", x, 0)
            fs:SetWidth(w); fs:SetHeight(ROW_H)
            fs:SetJustifyH(justify); fs:SetJustifyV("MIDDLE")
            fs:SetFont(STANDARD_TEXT_FONT, size or 11)
            return fs
        end
        -- icon in its own hitbox button (hover -> item tooltip). No "#" column now,
        -- so the icon sits at the far left and stack size rides inline as "xN".
        b.IconBtn = CreateFrame("Button", nm .. "Item", b)
        b.IconBtn:SetPoint("TOPLEFT", b, "TOPLEFT", 2, 0)
        b.IconBtn:SetWidth(16); b.IconBtn:SetHeight(ROW_H)
        b.IconBtn:SetScript("OnEnter", IconEnter)
        b.IconBtn:SetScript("OnLeave", HideTip)
        b.IconBtn:SetScript("OnClick", function(self, mb) RowClick(self:GetParent(), mb) end)
        b.Icon = b.IconBtn:CreateTexture(nm .. "ItemIconTexture", "ARTWORK")
        b.Icon:SetPoint("TOPLEFT", 0, -1); b.Icon:SetWidth(16); b.Icon:SetHeight(16)

        b.Name  = FS(22, 206, "LEFT",   10)   -- geometry mirrors COLS above
        b.Min   = FS(232, 28, "RIGHT",  11)
        b.ILvl  = FS(262, 28, "RIGHT",  11)
        b.Owner = FS(294, 96, "RIGHT",  10)   -- owner right-aligned (per request)
        b.Bid   = FS(394, 80, "RIGHT",  11)
        b.Buy   = FS(478, 80, "RIGHT",  11)
        b.Left  = FS(562, 46, "CENTER", 11)   -- rightmost, fills to the row edge

        b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        b:SetScript("OnClick", RowClick)
        b:SetScript("OnEnter", RowEnter)      -- hover name / any cell -> item tooltip
        b:SetScript("OnLeave", HideTip)
    end
    NUM_BROWSE_TO_DISPLAY = NUM_ROWS   -- keep Blizzard scroll math in sync

    -- 3) our own thin column headers above row 1
    M.headers = CreateFrame("Frame", nil, AuctionFrameBrowse)
    table.insert(M.candy, M.headers)
    for _, col in ipairs(COLS) do
        local label, field, x, w, justify = col[1], col[2], col[3], col[4], col[5]
        local h = CreateFrame("Button", nil, M.headers)
        h:SetPoint("BOTTOMLEFT", M.buttons[1], "TOPLEFT", x, 2)
        h:SetWidth(w); h:SetHeight(16)
        h:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
        local bg = h:CreateTexture(nil, "ARTWORK")
        bg:SetAllPoints(); bg:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
        bg:SetTexCoord(0.1, 0.8, 0, 1); bg:SetVertexColor(1, 1, 1, 0.6)
        local t = h:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        t:SetAllPoints(); t:SetJustifyH(justify); t:SetJustifyV("MIDDLE"); t:SetText(label)
        h.field = field
        h:SetScript("OnClick", HeaderClick)
    end

    -- 4) ONE bottom line under the list: results count pinned LEFT, pager pinned far
    --    RIGHT. Collapsing the old two-line footer into one is what frees the 15th row.
    local anchor = M.buttons[NUM_ROWS]

    if BrowseSearchCountText then
        BrowseSearchCountText:ClearAllPoints()
        BrowseSearchCountText:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 2, -5)
        BrowseSearchCountText:SetJustifyH("LEFT")
    end

    -- Reuse Blizzard's own Prev/Next page buttons: they KEEP their native "Prev"/"Next"
    -- text and their secure paging OnClick - we only reposition them. (Adding our own
    -- captions produced a DOUBLE "Next", and clearing the native text via SetText did
    -- NOT work on this client, so we keep the native labels and just space the two
    -- buttons well apart.) The page number sits to the LEFT of the pair, so it no
    -- longer overlaps the button text.
    local pager = CreateFrame("Frame", nil, AuctionFrameBrowse)
    pager:SetPoint("TOPRIGHT", anchor, "BOTTOMRIGHT", -2, -3)
    pager:SetSize(1, 20)
    table.insert(M.candy, pager)

    if BrowseNextPageButton then
        BrowseNextPageButton:ClearAllPoints()
        BrowseNextPageButton:SetPoint("RIGHT", pager, "RIGHT", 0, 0)
    end
    if BrowsePrevPageButton then
        BrowsePrevPageButton:ClearAllPoints()
        BrowsePrevPageButton:SetPoint("RIGHT", BrowseNextPageButton or pager, "LEFT", -72, 0)
    end

    M.pageNum = pager:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    M.pageNum:SetPoint("RIGHT", BrowsePrevPageButton or pager, "LEFT", -16, 0)
    M.pageNum:SetText("")

    -- 5) take over the update path and paint immediately
    AuctionFrameBrowse_Update = M.Update
    M.Update()
end

-- ---- bootstrap: install when the AH (Blizzard_AuctionUI) is available ------
local function Enabled()
    if CheapBidsDB == nil then return true end            -- default ON, like CompactUI
    return CheapBidsDB.compactBrowse ~= false
end

local boot = CreateFrame("Frame")
boot:RegisterEvent("AUCTION_HOUSE_SHOW")
boot:RegisterEvent("ADDON_LOADED")
boot:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" and arg1 == "Blizzard_AuctionUI" then
        if Enabled() then M.Install() end
    elseif event == "AUCTION_HOUSE_SHOW" then
        if Enabled() then
            M.Install()          -- no-op if already installed; also covers pre-loaded AH UI
            if M.active then M.Update() end
        end
    end
end)

-- ---- /cbrowse : toggle the compact Browse (persisted, needs /reload) -------
SLASH_CHEAPBROWSE1 = "/cbrowse"
SlashCmdList["CHEAPBROWSE"] = function()
    CheapBidsDB = CheapBidsDB or {}
    CheapBidsDB.compactBrowse = not (CheapBidsDB.compactBrowse ~= false)   -- flip; default was ON
    local on = CheapBidsDB.compactBrowse ~= false
    print("|cff33ff99CheapBids CompactBrowse|r: " .. (on and "ON" or "OFF") ..
          " - type /reload to apply.")
end

CheapBids_CompactBrowse = M   -- expose for debugging / headless inspection
