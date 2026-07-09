-- ===========================================================================
-- CheapBids Shopping
-- ---------------------------------------------------------------------------
-- A lean take on Auctionator's "Shopping" tab: keep a saved shopping list of items,
-- and with one click search any of them in the auction house. Each list row shows the
-- item's last-scan market price (from CheapBids' shared CheapBidsDB.priceDB), so you
-- know the going rate before you even search.
--
-- SAFE BY DESIGN: we do NOT run our own buying code. Clicking a row drives Blizzard's
-- OWN Browse search (AuctionFrameBrowse_Search) - the results appear in the standard
-- Browse list (nicely compacted if CheapBids_CompactBrowse is on), and you buy with
-- Blizzard's own Buyout button. So there is no custom gold-spending path here at all.
--
-- Add items by shift-clicking them into the window (bag, AH, anywhere a link comes from)
-- or by typing a name. Separate plug-in addon; touches no CheapBids code; shares only the
-- CheapBidsDB saved table. Toggle window with /cbshop. ASCII/English UI text.
-- ===========================================================================

local ROWS = 12

-- ---- shopping list model (pure, unit-tested) ------------------------------
-- list = array of { name = "Copper Ore", itemID = 2770|nil }. Keyed/deduped by lower-name.
local function ListGet()
    CheapBidsDB = CheapBidsDB or {}
    CheapBidsDB.shopList = CheapBidsDB.shopList or {}
    return CheapBidsDB.shopList
end
local function AddEntry(list, name, itemID)
    if not name or name == "" then return false end
    local key = name:lower()
    for _, e in ipairs(list) do if (e.name or ""):lower() == key then
        if itemID and not e.itemID then e.itemID = itemID end   -- fill in a missing id
        return false
    end end
    list[#list + 1] = { name = name, itemID = itemID }
    return true
end
local function RemoveAt(list, i)
    if i >= 1 and i <= #list then table.remove(list, i); return true end
    return false
end

-- market price (per unit, copper) for an entry, from the shared price DB; nil if unknown
local function MarketPrice(entry)
    if not entry or not entry.itemID then return nil end
    local db = CheapBidsDB and CheapBidsDB.priceDB
    local p = db and db[entry.itemID]
    if p and p > 0 then return p end
    return nil
end

-- ---- money text (compact g/s/c, ASCII) ------------------------------------
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
    if not (AuctionFrame and AuctionFrame:IsShown()) then
        print("|cff33ff99CheapBids Shopping|r: open the auction house first.")
        return
    end
    if _G["AuctionFrameTab1"] then _G["AuctionFrameTab1"]:Click() end   -- Browse tab
    if BrowseName then BrowseName:SetText(name) end
    if BrowseResetButton then BrowseResetButton:Enable() end
    if AuctionFrameBrowse_Search then AuctionFrameBrowse_Search() end
end

-- ---- window ---------------------------------------------------------------
local win
local function Refresh()
    if not win or not win:IsShown() then return end
    local list = ListGet()
    FauxScrollFrame_Update(win.scroll, #list, ROWS, 18)
    local off = FauxScrollFrame_GetOffset(win.scroll)
    for i = 1, ROWS do
        local row = win.rows[i]
        local e = list[i + off]
        if e then
            row.idx = i + off
            row.name:SetText(e.name)
            row.price:SetText(Money(MarketPrice(e)))
            row:Show()
        else
            row.idx = nil; row:Hide()
        end
    end
end

local function AddFromInput()
    local txt = win and win.input and win.input:GetText()
    if txt and txt ~= "" then
        AddEntry(ListGet(), txt, nil)
        win.input:SetText("")
        Refresh()
    end
end

local function BuildWindow()
    local f = CreateFrame("Frame", "CheapBidsShoppingWindow", UIParent, "BackdropTemplate")
    f:SetSize(300, 360)
    f:SetPoint("CENTER")
    f:SetBackdrop({ bgFile = "Interface/Tooltips/UI-Tooltip-Background",
        edgeFile = "Interface/Tooltips/UI-Tooltip-Border", tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 } })
    f:SetBackdropColor(0, 0, 0, 0.9)
    f:SetMovable(true); f:EnableMouse(true); f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving); f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetClampedToScreen(true)
    if UISpecialFrames then tinsert(UISpecialFrames, "CheapBidsShoppingWindow") end   -- Esc closes

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", 0, -8); title:SetText("CheapBids Shopping")
    local hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("TOP", title, "BOTTOM", 0, -2); hint:SetText("shift-click items here to add; click a row to search")

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", 0, 0)

    local input = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    input:SetSize(190, 20); input:SetPoint("TOPLEFT", 16, -40); input:SetAutoFocus(false)
    input:SetScript("OnEnterPressed", AddFromInput)
    f.input = input
    -- shift-clicking an item anywhere drops its link into the focused edit box; capture it
    input:SetScript("OnTextChanged", function(self)
        local t = self:GetText()
        local id, name = t:match("|Hitem:(%d+):.-|h%[(.-)%]|h")
        if id and name then AddEntry(ListGet(), name, tonumber(id)); self:SetText(""); Refresh() end
    end)
    local addBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    addBtn:SetSize(60, 22); addBtn:SetPoint("LEFT", input, "RIGHT", 6, 0); addBtn:SetText("Add")
    addBtn:SetScript("OnClick", AddFromInput)

    local scroll = CreateFrame("ScrollFrame", "CheapBidsShoppingScroll", f, "FauxScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 12, -72); scroll:SetPoint("BOTTOMRIGHT", -30, 14)
    scroll:SetScript("OnVerticalScroll", function(self, o) FauxScrollFrame_OnVerticalScroll(self, o, 18, Refresh) end)
    f.scroll = scroll

    f.rows = {}
    for i = 1, ROWS do
        local r = CreateFrame("Button", nil, f)
        r:SetHeight(18); r:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, -(i - 1) * 18)
        r:SetPoint("TOPRIGHT", scroll, "TOPRIGHT", 0, -(i - 1) * 18)
        r:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        local nm = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        nm:SetPoint("LEFT", 4, 0); nm:SetWidth(160); nm:SetJustifyH("LEFT"); nm:SetWordWrap(false)
        local pr = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        pr:SetPoint("RIGHT", -20, 0); pr:SetJustifyH("RIGHT")
        local del = CreateFrame("Button", nil, r, "UIPanelCloseButton")
        del:SetSize(18, 18); del:SetPoint("RIGHT", 0, 0)
        del:SetScript("OnClick", function() if r.idx then RemoveAt(ListGet(), r.idx); Refresh() end end)
        r.name, r.price = nm, pr
        r:SetScript("OnClick", function()
            if not r.idx then return end
            local e = ListGet()[r.idx]
            if e then SearchAH(e.name) end
        end)
        f.rows[i] = r
    end

    f:SetScript("OnShow", Refresh)
    win = f
    return f
end

-- ---- /cbshop : toggle the window ------------------------------------------
SLASH_CHEAPBIDSSHOP1 = "/cbshop"
SlashCmdList["CHEAPBIDSSHOP"] = function()
    if not win then BuildWindow() end
    if win:IsShown() then win:Hide() else win:Show() end
end

-- ---- test hook ------------------------------------------------------------
if CheapBidsTest then
    CheapBidsTest.SHOP = {
        AddEntry = AddEntry, RemoveAt = RemoveAt, MarketPrice = MarketPrice, Money = Money,
    }
end
