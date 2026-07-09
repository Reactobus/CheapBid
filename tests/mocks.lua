-- Minimal WoW API mock so CheapBids.lua loads and its internal logic can be
-- unit-tested headless. Only what the addon touches at load time + the functions
-- the tests exercise. Controllable scripted data lives in the global MOCK table.

CheapBidsTest = {}            -- presence of this global makes the addon expose internals
CheapBidsDB = {}

MOCK = {
    now  = 1700000000,        -- time()  (control prune windows)
    gt   = 1000.0,            -- GetTime() seconds (advance between debounce-sensitive calls)
    bids = {},                -- PlaceAuctionBid calls: { {listType, idx, amount}, ... }
    queries = {},             -- QueryAuctionItems calls
    auctions = { list = {}, bidder = {} },   -- scripted lots per list type
    popups = {},              -- StaticPopup_Show calls: { {which, a1, a2, data}, ... }
}

function time() return MOCK.now end
function GetTime() return MOCK.gt end

-- a frame whose every method is a chainable no-op (load-time UI calls never crash)
local function frame()
    local f = {}
    setmetatable(f, { __index = function() return function() return f end end })
    return f
end
function CreateFrame() return frame() end
function hooksecurefunc() end
C_Timer = { After = function() end }          -- timers never auto-fire under test
ITEM_QUALITY_COLORS = setmetatable({}, { __index = function() return { r = 1, g = 1, b = 1 } end })

function IsShiftKeyDown() return MOCK.shift or false end
function CanSendAuctionQuery() return true, true end
function QueryAuctionItems(name) MOCK.queries[#MOCK.queries + 1] = { name = name } end
function SortAuctionItems() end
function GetBidderAuctionItems() end
function PlaceAuctionBid(listType, idx, amount)
    MOCK.bids[#MOCK.bids + 1] = { listType = listType, idx = idx, amount = amount }
end

function GetNumAuctionItems(listType)
    local t = MOCK.auctions[listType] or {}
    return #t, #t
end

-- lot fields: name cnt qual minBid minInc buyout bidAmt high owner itemID timeLeft
function GetAuctionItemInfo(listType, i)
    local a = (MOCK.auctions[listType] or {})[i]
    if not a then return nil end
    return a.name, "tex", a.cnt or 1, a.qual or 1, true, 1, "lvl",
           a.minBid or 0, a.minInc or 0, a.buyout or 0, a.bidAmt or 0, a.high or false,
           nil, a.owner, 0, nil, a.itemID
end
function GetAuctionItemTimeLeft(listType, i)
    local a = (MOCK.auctions[listType] or {})[i]
    return a and a.timeLeft or 4
end
function GetAuctionItemLink() return nil end
function GetItemInfo(id)
    return "Item" .. tostring(id), "|cffffffff|Hitem:" .. tostring(id) .. "|h[Item" .. tostring(id) .. "]|h|r", 1
end
function GetItemInfoInstant(id) return id, nil, nil, nil, "tex" end

NUM_AUCTION_ITEMS_PER_PAGE = 50
AuctionFrame = nil
SlashCmdList = {}
function debugstack() return "" end

-- confirm-popup mock: record the call + return a dialog whose .data carries the
-- commit closure, so a test can simulate the player pressing Accept.
ACCEPT, CANCEL = "Accept", "Cancel"
StaticPopupDialogs = {}
function StaticPopup_Show(which, a1, a2, data)
    local dlg = { which = which, a1 = a1, a2 = a2, data = data }
    MOCK.popups[#MOCK.popups + 1] = dlg
    return dlg
end
