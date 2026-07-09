-- ===========================================================================
-- CheapBids Selling
-- ---------------------------------------------------------------------------
-- A lean take on Auctionator's "Selling" tab: an extra tab in the auction house where you
-- shift-click an item to get a suggested sell price that undercuts the item's market
-- minimum by 1 copper (tunable in the CheapBids options panel). The market minimum is the
-- per-unit price from CheapBids' last full GetAll (shared CheapBidsDB.priceDB) - i.e. the
-- "scan the item on the AH" number, without a second scan.
--
-- SAFE BY DESIGN: this addon does NOT post auctions itself (no StartAuction, no deposit
-- risk from our code). "Fill Auctions price" only writes the suggested numbers into
-- Blizzard's OWN Start/Buyout money fields on the default Auctions tab; you review them and
-- click Blizzard's own "Create Auction". Nothing is posted without that click.
--
-- The tab is created like CheapBids' own tab. Shares only CheapBidsDB. /cbsell selects the
-- tab. The pure price math is unit-tested headless. ASCII/English UI text.
-- ===========================================================================

-- ---- price math (pure, unit-tested) ---------------------------------------
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
local function SuggestUnit(itemID)
    local m = MarketUnit(itemID)
    if not m then return nil end
    local p = m - Undercut()
    if p < 1 then p = 1 end
    return p
end
local function Money(copper)
    if not copper or copper <= 0 then return "-" end
    local g = math.floor(copper / 10000)
    local s = math.floor(copper % 10000 / 100)
    local c = copper % 100
    local out = ""
    if g > 0 then out = out .. g .. "|cffffd700g|r " end
    if s > 0 then out = out .. s .. "|cffc7c7cfs|r " end
    return out .. c .. "|cffeda55fc|r"
end

-- ---- tab + content panel --------------------------------------------------
local content, myTabID

local function Update()
    if not content then return end
    local id = content.itemID
    if not id then
        content.itemFS:SetText("|cff808080shift-click an item into the box above|r")
        content.marketFS:SetText(""); content.suggestFS:SetText(""); content.fill:Disable()
        return
    end
    local name = GetItemInfo(id) or ("item:" .. id)
    content.itemFS:SetText(content.itemLink or name)
    content.marketFS:SetText("Market min / unit: " .. Money(MarketUnit(id)))
    local unit = SuggestUnit(id)
    if unit then
        content.suggestFS:SetText("Suggested / unit: |cff33ff99" .. Money(unit) .. "|r  (market - " .. Undercut() .. "c)")
        content.fill:Enable()
    else
        content.suggestFS:SetText("|cffff8080No scan data - run a GetAll in the CheapBids tab first.|r")
        content.fill:Disable()
    end
end

-- Fill Blizzard's OWN Start/Buyout fields for the WHOLE stack currently in Blizzard's sell
-- slot. We never post - you click Blizzard's Create Auction.
local function FillBlizzardPrice()
    local id = content and content.itemID
    local unit = id and SuggestUnit(id)
    if not unit then return end
    local slotName, _, slotCount = GetAuctionSellItemInfo and GetAuctionSellItemInfo()
    if not slotName then
        content.suggestFS:SetText("|cffff8080Put the item in Blizzard's Auctions sell slot first, then Fill.|r"); return
    end
    local myName = GetItemInfo(id)
    if myName and slotName and myName ~= slotName then
        content.suggestFS:SetText("|cffff8080Sell slot holds '" .. slotName .. "', not '" .. myName .. "'.|r"); return
    end
    local stackTotal = unit * (slotCount or 1)
    if StartPrice and BuyoutPrice and MoneyInputFrame_SetCopper then
        MoneyInputFrame_SetCopper(StartPrice, stackTotal)
        MoneyInputFrame_SetCopper(BuyoutPrice, stackTotal)
        content.suggestFS:SetText("|cff33ff99Filled: " .. Money(stackTotal) .. " for x" .. (slotCount or 1) ..
            ". Review + click Create Auction.|r")
    else
        content.suggestFS:SetText("|cffff8080Open Blizzard's Auctions (sell) tab first.|r")
    end
end

local function SetItem(itemID, itemLink)
    if not content then return end
    content.itemID = itemID; content.itemLink = itemLink; Update()
end

local function BuildContent()
    if content or not AuctionFrame then return end
    local f = CreateFrame("Frame", "CheapBidsSellContent", AuctionFrame)
    f:SetPoint("TOPLEFT", AuctionFrame, "TOPLEFT", 8, -22)
    f:SetPoint("BOTTOMRIGHT", AuctionFrame, "BOTTOMRIGHT", -32, 28)
    f:Hide()

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 8, -6); title:SetText("Selling - suggested price")

    local grab = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    grab:SetSize(320, 20); grab:SetPoint("TOPLEFT", 12, -30); grab:SetAutoFocus(false)
    grab:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    grab:SetScript("OnTextChanged", function(self)
        local id = self:GetText():match("|Hitem:(%d+):")
        if id then SetItem(tonumber(id), self:GetText():match("|Hitem:.-|h%[.-%]|h")) end
        self:SetText("")
    end)
    local grabLbl = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    grabLbl:SetPoint("LEFT", grab, "RIGHT", 8, 0); grabLbl:SetText("shift-click item here")

    f.itemFS = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.itemFS:SetPoint("TOPLEFT", 16, -60); f.itemFS:SetWidth(400); f.itemFS:SetJustifyH("LEFT")
    f.marketFS = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.marketFS:SetPoint("TOPLEFT", 16, -84)
    f.suggestFS = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.suggestFS:SetPoint("TOPLEFT", 16, -104); f.suggestFS:SetWidth(440); f.suggestFS:SetJustifyH("LEFT")

    local fill = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    fill:SetSize(180, 24); fill:SetPoint("TOPLEFT", 16, -132); fill:SetText("Fill Auctions price")
    fill:SetScript("OnClick", FillBlizzardPrice)
    f.fill = fill

    content = f
end

local function HideOthers()
    if AuctionFrameBrowse then AuctionFrameBrowse:Hide() end
    if AuctionFrameBid then AuctionFrameBid:Hide() end
    if AuctionFrameAuctions then AuctionFrameAuctions:Hide() end
    for _, c in ipairs({ AuctionFrame:GetChildren() }) do
        if c ~= content and c.IsShown and c:IsShown() and c.IsObjectType and c:IsObjectType("Frame") then
            local nm = c.GetName and c:GetName()
            if not (nm and nm:find("AuctionFrameTab")) and (c:GetWidth() or 0) > 200 and (c:GetHeight() or 0) > 200 then c:Hide() end
        end
    end
end
local function ShowMine()
    if not content then return end
    HideOthers(); content:Show()
    if myTabID then PanelTemplates_SetTab(AuctionFrame, myTabID) end
    Update()
    C_Timer.After(0, function() if content and content:IsShown() then HideOthers() end end)
end
local function HideMine() if content then content:Hide() end end

local function CreateTab()
    if myTabID or not AuctionFrame then return end
    BuildContent()
    local index = (AuctionFrame.numTabs or 3) + 1
    local tab = CreateFrame("Button", "AuctionFrameTab" .. index, AuctionFrame, "AuctionTabTemplate")
    tab:SetID(index); tab:SetText("CB Sell")
    tab:SetPoint("LEFT", _G["AuctionFrameTab" .. (index - 1)], "RIGHT", -15, 0)
    PanelTemplates_SetNumTabs(AuctionFrame, index)
    PanelTemplates_EnableTab(AuctionFrame, index)
    PanelTemplates_TabResize(tab, 0)
    myTabID = index
    hooksecurefunc("AuctionFrameTab_OnClick", function(self, _, _, idx)
        idx = idx or (self and self.GetID and self:GetID())
        if idx == myTabID then ShowMine() else HideMine() end
    end)
end

local boot = CreateFrame("Frame")
boot:RegisterEvent("AUCTION_HOUSE_SHOW")
boot:SetScript("OnEvent", function() CreateTab() end)

SLASH_CHEAPBIDSSELL1 = "/cbsell"
SlashCmdList["CHEAPBIDSSELL"] = function()
    if myTabID and _G["AuctionFrameTab" .. myTabID] then _G["AuctionFrameTab" .. myTabID]:Click()
    else print("|cff33ff99CheapBids Selling|r: open the auction house first (adds a 'CB Sell' tab).") end
end

-- ---- test hook ------------------------------------------------------------
if CheapBidsTest then
    CheapBidsTest.SELL = { MarketUnit = MarketUnit, Undercut = Undercut, SuggestUnit = SuggestUnit, Money = Money }
end
