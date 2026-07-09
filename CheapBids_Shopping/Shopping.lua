-- ===========================================================================
-- CheapBids Shopping
-- ---------------------------------------------------------------------------
-- A lean take on Auctionator's "Shopping" tab: a saved shopping list of items, shown as
-- an extra tab in the auction house next to Browse/Bids/Auctions/CheapBids. Each row shows
-- the item's last-scan market price (from the shared CheapBidsDB.priceDB); click a row to
-- run Blizzard's OWN Browse search for it.
--
-- SAFE BY DESIGN: no custom buying code. Clicking a row drives Blizzard's Browse search;
-- results appear in the standard Browse list (compacted if CheapBids_CompactBrowse is on)
-- and you buy with Blizzard's own Buyout button. No gold-spending path lives here.
--
-- The tab is created the same way CheapBids' own tab is (AuctionTabTemplate + numTabs+1 +
-- AuctionFrameTab_OnClick hook), so it chains after whatever tabs already exist. Add items
-- by shift-clicking them into the input box or typing a name. Shares only CheapBidsDB.
-- /cbshop selects the tab. ASCII/English UI text.
-- ===========================================================================

local ROWS = 14

-- ---- shopping list model (pure, unit-tested) ------------------------------
local function ListGet()
    CheapBidsDB = CheapBidsDB or {}
    CheapBidsDB.shopList = CheapBidsDB.shopList or {}
    return CheapBidsDB.shopList
end
local function AddEntry(list, name, itemID)
    if not name or name == "" then return false end
    local key = name:lower()
    for _, e in ipairs(list) do if (e.name or ""):lower() == key then
        if itemID and not e.itemID then e.itemID = itemID end
        return false
    end end
    list[#list + 1] = { name = name, itemID = itemID }
    return true
end
local function RemoveAt(list, i)
    if i >= 1 and i <= #list then table.remove(list, i); return true end
    return false
end
local function MarketPrice(entry)
    if not entry or not entry.itemID then return nil end
    local db = CheapBidsDB and CheapBidsDB.priceDB
    local p = db and db[entry.itemID]
    if p and p > 0 then return p end
    return nil
end
local function Money(copper)
    if not copper or copper <= 0 then return "-" end
    local g = math.floor(copper / 10000)
    local s = math.floor(copper % 10000 / 100)
    local c = copper % 100
    if g > 0 then return g .. "|cffffd700g|r " .. s .. "|cffc7c7cfs|r" end
    if s > 0 then return s .. "|cffc7c7cfs|r " .. c .. "|cffeda55fc|r" end
    return c .. "|cffeda55fc|r"
end

-- ---- drive Blizzard's own Browse search (no custom buying) ----------------
local function SearchAH(name)
    if not (AuctionFrame and AuctionFrame:IsShown()) then return end
    if _G["AuctionFrameTab1"] then _G["AuctionFrameTab1"]:Click() end   -- Browse tab
    if BrowseName then BrowseName:SetText(name) end
    if BrowseResetButton then BrowseResetButton:Enable() end
    if AuctionFrameBrowse_Search then AuctionFrameBrowse_Search() end
end

-- ---- tab + content panel (inside AuctionFrame) ----------------------------
local content, myTabID

local function Refresh()
    if not content or not content:IsShown() then return end
    local list = ListGet()
    FauxScrollFrame_Update(content.scroll, #list, ROWS, 18)
    local off = FauxScrollFrame_GetOffset(content.scroll)
    for i = 1, ROWS do
        local row = content.rows[i]
        local e = list[i + off]
        if e then
            row.idx = i + off
            row.name:SetText(e.name); row.price:SetText(Money(MarketPrice(e))); row:Show()
        else
            row.idx = nil; row:Hide()
        end
    end
end

local function AddFromInput()
    local txt = content and content.input and content.input:GetText()
    if txt and txt ~= "" then AddEntry(ListGet(), txt, nil); content.input:SetText(""); Refresh() end
end

local function BuildContent()
    if content or not AuctionFrame then return end
    local f = CreateFrame("Frame", "CheapBidsShopContent", AuctionFrame)
    f:SetPoint("TOPLEFT", AuctionFrame, "TOPLEFT", 8, -22)
    f:SetPoint("BOTTOMRIGHT", AuctionFrame, "BOTTOMRIGHT", -32, 28)
    f:Hide()

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 8, -6); title:SetText("Shopping list")
    local hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("LEFT", title, "RIGHT", 10, 0)
    hint:SetText("shift-click items to add; click a row to search in Browse")

    local input = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    input:SetSize(220, 20); input:SetPoint("TOPLEFT", 12, -30); input:SetAutoFocus(false)
    input:SetScript("OnEnterPressed", AddFromInput)
    input:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    input:SetScript("OnTextChanged", function(self)
        local id, name = self:GetText():match("|Hitem:(%d+):.-|h%[(.-)%]|h")
        if id and name then AddEntry(ListGet(), name, tonumber(id)); self:SetText(""); Refresh() end
    end)
    f.input = input
    local addBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    addBtn:SetSize(60, 22); addBtn:SetPoint("LEFT", input, "RIGHT", 6, 0); addBtn:SetText("Add")
    addBtn:SetScript("OnClick", AddFromInput)

    local scroll = CreateFrame("ScrollFrame", "CheapBidsShopScroll", f, "FauxScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 12, -58); scroll:SetPoint("BOTTOMRIGHT", -34, 10)
    scroll:SetScript("OnVerticalScroll", function(self, o) FauxScrollFrame_OnVerticalScroll(self, o, 18, Refresh) end)
    f.scroll = scroll

    f.rows = {}
    for i = 1, ROWS do
        local r = CreateFrame("Button", nil, f)
        r:SetHeight(18); r:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, -(i - 1) * 18)
        r:SetPoint("TOPRIGHT", scroll, "TOPRIGHT", 0, -(i - 1) * 18)
        if i % 2 == 0 then local bg = r:CreateTexture(nil, "BACKGROUND"); bg:SetAllPoints(); bg:SetColorTexture(1,1,1,0.04) end
        r:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        local nm = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        nm:SetPoint("LEFT", 4, 0); nm:SetWidth(300); nm:SetJustifyH("LEFT"); nm:SetWordWrap(false)
        local pr = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        pr:SetPoint("RIGHT", -22, 0); pr:SetJustifyH("RIGHT")
        local del = CreateFrame("Button", nil, r, "UIPanelCloseButton")
        del:SetSize(18, 18); del:SetPoint("RIGHT", 2, 0)
        del:SetScript("OnClick", function() if r.idx then RemoveAt(ListGet(), r.idx); Refresh() end end)
        r.name, r.price = nm, pr
        r:SetScript("OnClick", function()
            if not r.idx then return end
            local e = ListGet()[r.idx]; if e then SearchAH(e.name) end
        end)
        f.rows[i] = r
    end
    content = f
end

-- hide the default AH panels (and any other large tab panel) so ours shows cleanly
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
    Refresh()
    C_Timer.After(0, function() if content and content:IsShown() then HideOthers() end end)
end
local function HideMine() if content then content:Hide() end end

local function CreateTab()
    if myTabID or not AuctionFrame then return end
    BuildContent()
    local index = (AuctionFrame.numTabs or 3) + 1
    local tab = CreateFrame("Button", "AuctionFrameTab" .. index, AuctionFrame, "AuctionTabTemplate")
    tab:SetID(index); tab:SetText("CB Shop")
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

-- /cbshop : open the AH on our tab (or say to open the AH)
SLASH_CHEAPBIDSSHOP1 = "/cbshop"
SlashCmdList["CHEAPBIDSSHOP"] = function()
    if myTabID and _G["AuctionFrameTab" .. myTabID] then _G["AuctionFrameTab" .. myTabID]:Click()
    else print("|cff33ff99CheapBids Shopping|r: open the auction house first (adds a 'CB Shop' tab).") end
end

-- ---- test hook ------------------------------------------------------------
if CheapBidsTest then
    CheapBidsTest.SHOP = { AddEntry = AddEntry, RemoveAt = RemoveAt, MarketPrice = MarketPrice, Money = Money }
end
