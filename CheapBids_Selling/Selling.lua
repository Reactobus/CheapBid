-- ===========================================================================
-- CheapBids Selling
-- ---------------------------------------------------------------------------
-- A lean take on Auctionator's "Selling" tab: shift-click an item into the window and
-- it suggests a sell price that undercuts the item's market minimum by 1 copper (the
-- amount is tunable in the CheapBids options panel). The market minimum is the per-unit
-- price from CheapBids' last full GetAll (shared CheapBidsDB.priceDB) - i.e. exactly the
-- "scan the item on the AH" number Auctionator computes, without a second scan.
--
-- SAFE BY DESIGN: this addon does NOT post auctions itself (no StartAuction, no deposit
-- risk from our code). The "Fill Auctions price" button only writes the suggested numbers
-- into Blizzard's OWN Start Price / Buyout money fields on the default Auctions tab; YOU
-- review them and click Blizzard's own "Create Auction". Nothing is posted without your
-- explicit click on Blizzard's button.
--
-- Separate plug-in addon; shares only CheapBidsDB. Toggle window with /cbsell. The pure
-- price math is unit-tested headless. ASCII/English UI text.
-- ===========================================================================

-- ---- price math (pure, unit-tested) ---------------------------------------
-- market min per unit (copper) for an item from the shared price DB, or nil
local function MarketUnit(itemID)
    local db = CheapBidsDB and CheapBidsDB.priceDB
    local p = itemID and db and db[itemID]
    if p and p > 0 then return p end
    return nil
end
local function Undercut()
    local u = CheapBidsDB and CheapBidsDB.undercutCopper
    return (type(u) == "number" and u >= 0) and u or 1
end
-- suggested PER-UNIT buyout = market min - undercut (never below 1c). nil if unpriced.
local function SuggestUnit(itemID)
    local m = MarketUnit(itemID)
    if not m then return nil end
    local p = m - Undercut()
    if p < 1 then p = 1 end
    return p
end

-- ---- money text -----------------------------------------------------------
local function Money(copper)
    if not copper or copper <= 0 then return "-" end
    local g = math.floor(copper / 10000)
    local s = math.floor(copper % 10000 / 100)
    local c = copper % 100
    local out = ""
    if g > 0 then out = out .. g .. "|cffffd700g|r " end
    if s > 0 then out = out .. s .. "|cffc7c7cfs|r " end
    out = out .. c .. "|cffeda55fc|r"
    return out
end

-- ---- window ---------------------------------------------------------------
local win
local function Update()
    if not win then return end
    local id = win.itemID
    if not id then
        win.itemFS:SetText("|cff808080shift-click an item here|r")
        win.marketFS:SetText(""); win.suggestFS:SetText(""); win.fill:Disable()
        return
    end
    local name = GetItemInfo(id) or ("item:" .. id)
    local market = MarketUnit(id)
    local unit = SuggestUnit(id)
    win.itemFS:SetText(win.itemLink or name)
    win.marketFS:SetText("Market min / unit: " .. Money(market))
    if unit then
        win.suggestFS:SetText("Suggested / unit: |cff33ff99" .. Money(unit) .. "|r  (market - " .. Undercut() .. "c)")
        win.fill:Enable()
    else
        win.suggestFS:SetText("|cffff8080No scan data for this item - run a GetAll in CheapBids first.|r")
        win.fill:Disable()
    end
end

-- Fill Blizzard's OWN Start Price / Buyout fields (default Auctions tab) with the suggested
-- price for the WHOLE stack currently in Blizzard's sell slot. We never post - you click
-- Blizzard's Create Auction. If the slot is empty or holds a different item, we say so.
local function FillBlizzardPrice()
    local id = win and win.itemID
    local unit = id and SuggestUnit(id)
    if not unit then return end
    local slotName, _, slotCount = GetAuctionSellItemInfo and GetAuctionSellItemInfo()
    if not slotName then
        win.suggestFS:SetText("|cffff8080Put the item in Blizzard's Auctions sell slot first, then Fill.|r")
        return
    end
    local myName = GetItemInfo(id)
    if myName and slotName and myName ~= slotName then
        win.suggestFS:SetText("|cffff8080Sell slot holds '" .. slotName .. "', not '" .. myName .. "'.|r")
        return
    end
    local stackTotal = unit * (slotCount or 1)
    if StartPrice and BuyoutPrice and MoneyInputFrame_SetCopper then
        MoneyInputFrame_SetCopper(StartPrice, stackTotal)
        MoneyInputFrame_SetCopper(BuyoutPrice, stackTotal)
        win.suggestFS:SetText("|cff33ff99Filled Blizzard price: " .. Money(stackTotal) ..
            " for x" .. (slotCount or 1) .. ". Review + click Create Auction.|r")
    else
        win.suggestFS:SetText("|cffff8080Open the Auctions tab (sell) first.|r")
    end
end

local function SetItem(itemID, itemLink)
    if not win then return end
    win.itemID = itemID; win.itemLink = itemLink
    Update()
end

local function BuildWindow()
    local f = CreateFrame("Frame", "CheapBidsSellingWindow", UIParent, "BackdropTemplate")
    f:SetSize(320, 190); f:SetPoint("CENTER")
    f:SetBackdrop({ bgFile = "Interface/Tooltips/UI-Tooltip-Background",
        edgeFile = "Interface/Tooltips/UI-Tooltip-Border", tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 } })
    f:SetBackdropColor(0, 0, 0, 0.9)
    f:SetMovable(true); f:EnableMouse(true); f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving); f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetClampedToScreen(true)
    if UISpecialFrames then tinsert(UISpecialFrames, "CheapBidsSellingWindow") end

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", 0, -8); title:SetText("CheapBids Selling")
    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", 0, 0)

    -- shift-click target: an edit box that captures the dropped item link
    local grab = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    grab:SetSize(280, 20); grab:SetPoint("TOP", 0, -30); grab:SetAutoFocus(false)
    grab:SetScript("OnTextChanged", function(self)
        local link = self:GetText()
        local id = link:match("|Hitem:(%d+):")
        if id then SetItem(tonumber(id), link:match("|Hitem:.-|h%[.-%]|h") or link) end
        self:SetText("")
    end)
    grab:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    f.itemFS = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.itemFS:SetPoint("TOPLEFT", 16, -58); f.itemFS:SetWidth(288); f.itemFS:SetJustifyH("LEFT")
    f.marketFS = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.marketFS:SetPoint("TOPLEFT", 16, -82)
    f.suggestFS = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.suggestFS:SetPoint("TOPLEFT", 16, -102); f.suggestFS:SetWidth(288); f.suggestFS:SetJustifyH("LEFT")

    local fill = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    fill:SetSize(180, 24); fill:SetPoint("BOTTOM", 0, 16); fill:SetText("Fill Auctions price")
    fill:SetScript("OnClick", FillBlizzardPrice)
    f.fill = fill

    f:SetScript("OnShow", Update)
    win = f
    Update()
    return f
end

SLASH_CHEAPBIDSSELL1 = "/cbsell"
SlashCmdList["CHEAPBIDSSELL"] = function()
    if not win then BuildWindow() end
    if win:IsShown() then win:Hide() else win:Show() end
end

-- ---- test hook ------------------------------------------------------------
if CheapBidsTest then
    CheapBidsTest.SELL = {
        MarketUnit = MarketUnit, Undercut = Undercut, SuggestUnit = SuggestUnit, Money = Money,
    }
end
