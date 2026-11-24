-- Modern-client (WoW Forever / C_AuctionHouse) mock layer. Loaded in a SEPARATE Lua
-- state AFTER tests/mocks.lua (whose generic time()/GetTime()/MOCK/StaticPopup mocks
-- we reuse) and BEFORE CheapBids/Modern.lua + CheapBids/CheapBids.lua.
--
-- What it does:
--   * removes the legacy AH/item globals, so any code path that still reaches them
--     fails loudly ("attempt to call a nil value") instead of silently passing;
--   * provides a scriptable C_AuctionHouse / C_Item / Enum / UnitGUID;
--   * replaces CreateFrame with a recording frame (text, shown state, scripts,
--     registered events) so the spec can click buttons and fire events into BOTH
--     Modern.lua's event frame and CheapBids.lua's event frame (WoW-style: every
--     frame that registered the event receives it);
--   * replaces C_Timer.After with a queue the spec drives with MOCKM.advance(dt).
-- All scripted state lives in the global MOCKM table.

MOCKM = {
    frames = {},              -- every frame created, in creation order
    eventFrames = {},         -- frames that registered an event or set OnEvent (delivery order)
    texts = {},               -- log of every SetText(string) call (status/act messages)
    timers = {},              -- pending C_Timer.After callbacks { due, seq, fn }
    timerSeq = 0,
    errors = {},              -- errors raised inside fired events / timers
    -- C_AuctionHouse scripted data
    replicate = {},           -- 1-based Lua list; the API is called 0-based
    badIndex = {},            -- out-of-range indices the addon asked GetReplicateItem* for
    replicateCalls = 0,
    results = {},             -- [itemID] = { pages = { {r,...}, {r,...} } }
    delivered = {},           -- [itemID] = pages handed out so far
    searches = {},            -- SendSearchQuery calls: { itemID = id, sorts = ..., separate = ... }
    moreCalls = {},           -- RequestMoreItemSearchResults calls: { itemID = id }
    placeBids = {},           -- PlaceBid calls: { aid = auctionID, amount = copper }
    bids = {},                -- C_AuctionHouse.GetBids() payload
    queryBidsCalls = 0,
    copper = true,            -- SupportsCopperValues()
    throttleReady = true,     -- IsThrottledMessageSystemReady()
    commodity = {},           -- [itemID] = true -> Enum.ItemCommodityStatus.Commodity
    quality = {},             -- [itemID] = quality for C_Item.GetItemInfo
    displayModes = {},        -- AuctionHouseFrame:SetDisplayMode calls
    playerGUID = "Player-4711-00000001",
    unknownEvents = {         -- not present on the modern client: RegisterEvent errors (like WoW)
        AUCTION_ITEM_LIST_UPDATE = true,
        AUCTION_BIDDER_LIST_UPDATE = true,
        AUCTION_OWNED_LIST_UPDATE = true,
    },
}

-- ---- remove the legacy client globals ---------------------------------------
GetAuctionItemInfo = nil
GetAuctionItemTimeLeft = nil
GetAuctionItemLink = nil
GetNumAuctionItems = nil
PlaceAuctionBid = nil
QueryAuctionItems = nil
CanSendAuctionQuery = nil
SortAuctionItems = nil
GetBidderAuctionItems = nil
GetItemInfo = nil
GetItemInfoInstant = nil
AuctionFrame = nil

-- ---- localized error / system strings (exist on modern clients too) ---------
ERR_AUCTION_BID_PLACED     = "Bid accepted."
ERR_AUCTION_DATABASE_ERROR = "Internal auction error."
ERR_AUCTION_HIGHER_BID     = "There is already a higher bid on that item."
ERR_ITEM_NOT_FOUND         = "Item not found."
ERR_AUCTION_BID_OWN        = "You cannot bid on your own auction."
ERR_NOT_ENOUGH_MONEY       = "You don't have enough money."
ERR_AUCTION_BID_INCREMENT  = "Your bid increment is too small."
ERR_AUCTION_MIN_BID        = "You must bid at least the minimum bid."

-- ---- Enum --------------------------------------------------------------------
Enum = {
    AuctionHouseSortOrder = { Price = 0, Name = 1, Level = 2, Bid = 3, Buyout = 4 },
    AuctionHouseTimeLeftBand = { Short = 0, Medium = 1, Long = 2, VeryLong = 3 },
    ItemCommodityStatus = { Unknown = 0, Item = 1, Commodity = 2 },
}

function UnitGUID(unit) if unit == "player" then return MOCKM.playerGUID end end

-- ---- C_Item ------------------------------------------------------------------
local function IdFrom(x)
    if type(x) == "number" then return x end
    if type(x) == "string" then return tonumber(x:match("item:(%d+)")) end
end
function MOCKM.Link(id)
    return "|cffffffff|Hitem:" .. id .. "::::::::70:::::|h[Item" .. id .. "]|h|r"
end
C_Item = {
    GetItemInfo = function(x)
        local id = IdFrom(x)
        if not id then return nil end
        return "Item" .. id, MOCKM.Link(id), MOCKM.quality[id] or 1, 10, 1, "Armor", "Cloth", 1
    end,
    GetItemInfoInstant = function(x)
        local id = IdFrom(x)
        if not id then return nil end
        return id, "Armor", "Cloth", "", "tex" .. id
    end,
}

-- ---- C_AuctionHouse -----------------------------------------------------------
-- replicate lot fields: name cnt qual minBid minInc buyout bidAmt high owner ownerFull itemID band
local function Rep(i)          -- 0-based client index -> scripted lot (records misuse)
    if type(i) ~= "number" or i < 0 or i >= #MOCKM.replicate or i % 1 ~= 0 then
        MOCKM.badIndex[#MOCKM.badIndex + 1] = i
        return nil
    end
    return MOCKM.replicate[i + 1]
end

local function KeyID(key) return type(key) == "table" and key.itemID or nil end

local function Delivered(id)
    local r = MOCKM.results[id]
    local out = {}
    if not r then return out end
    for p = 1, math.min(MOCKM.delivered[id] or 0, #r.pages) do
        for _, x in ipairs(r.pages[p]) do out[#out + 1] = x end
    end
    return out
end

C_AuctionHouse = {
    ReplicateItems = function() MOCKM.replicateCalls = MOCKM.replicateCalls + 1 end,
    GetNumReplicateItems = function() return #MOCKM.replicate end,
    GetReplicateItemInfo = function(i)
        local a = Rep(i)
        if not a then return nil end
        -- name texture count qualityID usable level levelType minBid minIncrement
        -- buyoutPrice bidAmount highBidder bidderName owner ownerFullName saleStatus itemID hasAllInfo
        return a.name, "tex", a.cnt or 1, a.qual or 1, true, 1, "lvl",
               a.minBid or 0, a.minInc or 0, a.buyout or 0, a.bidAmt or 0, a.high or false,
               nil, a.owner, a.ownerFull, 0, a.itemID, true
    end,
    GetReplicateItemTimeLeft = function(i)
        local a = Rep(i)
        return a and a.band
    end,
    GetReplicateItemLink = function(i)
        local a = Rep(i)
        return a and a.itemID and MOCKM.Link(a.itemID) or nil
    end,
    MakeItemKey = function(id)
        return { itemID = id, itemLevel = 0, itemSuffix = 0, battlePetSpeciesID = 0 }
    end,
    SendSearchQuery = function(key, sorts, separateOwnerItems)
        local id = KeyID(key)
        MOCKM.searches[#MOCKM.searches + 1] = { itemID = id, sorts = sorts, separate = separateOwnerItems }
        MOCKM.delivered[id] = 1
    end,
    RequestMoreItemSearchResults = function(key)
        local id = KeyID(key)
        MOCKM.moreCalls[#MOCKM.moreCalls + 1] = { itemID = id }
        MOCKM.delivered[id] = (MOCKM.delivered[id] or 0) + 1
    end,
    HasFullItemSearchResults = function(key)
        local id = KeyID(key)
        local r = MOCKM.results[id]
        return (not r) or (MOCKM.delivered[id] or 0) >= #r.pages
    end,
    GetNumItemSearchResults = function(key) return #Delivered(KeyID(key)) end,
    GetItemSearchResultInfo = function(key, i)          -- 1-based
        return Delivered(KeyID(key))[i]
    end,
    IsThrottledMessageSystemReady = function() return MOCKM.throttleReady end,
    PlaceBid = function(aid, amount)
        MOCKM.placeBids[#MOCKM.placeBids + 1] = { aid = aid, amount = amount }
    end,
    GetBids = function() return MOCKM.bids end,
    QueryBids = function() MOCKM.queryBidsCalls = MOCKM.queryBidsCalls + 1 end,
    SupportsCopperValues = function() return MOCKM.copper end,
    GetItemCommodityStatus = function(id)
        if MOCKM.commodity[id] then return Enum.ItemCommodityStatus.Commodity end
        return Enum.ItemCommodityStatus.Item
    end,
}

-- ---- recording frames -----------------------------------------------------------
local function noop() end
local Methods = {}
local FrameMT = {
    __index = function(_, k)
        local m = Methods[k]
        if m then return m end
        -- unknown widget METHODS (CamelCase) are harmless no-ops returning nil;
        -- unknown lowercase FIELDS stay nil like on a real frame table
        if type(k) == "string" and k:match("^%u") then return noop end
        return nil
    end,
}

local function NewFrame(ftype, name, parent, template)
    local f = setmetatable({ _type = ftype, _name = name, _parent = parent, _template = template,
                             _scripts = {}, _events = {}, _shown = true }, FrameMT)
    MOCKM.frames[#MOCKM.frames + 1] = f
    if name then _G[name] = f end
    return f
end
MOCKM.NewFrame = NewFrame

local function TrackEvents(f)
    if f._tracked then return end
    f._tracked = true
    MOCKM.eventFrames[#MOCKM.eventFrames + 1] = f
end

function Methods:SetText(t)
    self._text = t
    if self._firstText == nil and t ~= nil then self._firstText = t end
    if type(t) == "string" then MOCKM.texts[#MOCKM.texts + 1] = t end
end
function Methods:SetFormattedText(fmt, ...) Methods.SetText(self, string.format(fmt, ...)) end
function Methods:GetText() return self._text or "" end
function Methods:Show() self._shown = true end
function Methods:Hide() self._shown = false end
function Methods:SetShown(v) self._shown = v and true or false end
function Methods:IsShown() return self._shown end
function Methods:IsVisible()
    if not self._shown then return false end
    local p = self._parent
    if type(p) == "table" and getmetatable(p) == FrameMT then return p:IsVisible() end
    return true
end
function Methods:SetScript(what, fn)
    self._scripts[what] = fn
    if what == "OnEvent" then TrackEvents(self) end
end
function Methods:GetScript(what) return self._scripts[what] end
function Methods:HookScript(what, fn)
    local prev = self._scripts[what]
    self._scripts[what] = function(...) if prev then prev(...) end return fn(...) end
end
function Methods:RegisterEvent(e)
    if MOCKM.unknownEvents[e] then error("Attempt to register unknown event \"" .. e .. "\"") end
    self._events[e] = true
    TrackEvents(self)
end
function Methods:UnregisterEvent(e) self._events[e] = nil end
function Methods:IsEventRegistered(e) return self._events[e] == true end
function Methods:CreateFontString(name) return NewFrame("FontString", name, self) end
function Methods:CreateTexture(name) return NewFrame("Texture", name, self) end
function Methods:GetFontString()
    if not self._fs then self._fs = NewFrame("FontString", nil, self) end
    return self._fs
end
function Methods:SetChecked(v) self._checked = v and true or false end
function Methods:GetChecked() return self._checked end
function Methods:SetEnabled(v) self._enabled = v and true or false end
function Methods:Enable() self._enabled = true end
function Methods:Disable() self._enabled = false end
function Methods:IsEnabled() return self._enabled ~= false end
function Methods:GetName() return self._name end
function Methods:GetParent() return self._parent end
function Methods:IsObjectType(t) return t == self._type or t == "Frame" end
function Methods:GetObjectType() return self._type end
function Methods:Click(...)
    local s = self._scripts.OnClick
    if s then return s(self, ...) end
end

function CreateFrame(ftype, name, parent, template)
    return NewFrame(ftype, name, parent, template)
end

-- the modern auction house frame (Blizzard_AuctionHouseUI)
AuctionHouseFrame = NewFrame("Frame", "AuctionHouseFrame", nil, nil)
AuctionHouseFrame.Tabs = { NewFrame("Button", "AuctionHouseFrameBuyTab"),
                           NewFrame("Button", "AuctionHouseFrameSellTab"),
                           NewFrame("Button", "AuctionHouseFrameAuctionsTab") }
AuctionHouseFrame.SetDisplayMode = function(self, mode)
    MOCKM.displayModes[#MOCKM.displayModes + 1] = mode
end

-- a real post-hook (Modern.lua hooks AuctionHouseFrame:SetDisplayMode)
function hooksecurefunc(a, b, c)
    local tbl, name, fn
    if type(a) == "table" then tbl, name, fn = a, b, c else tbl, name, fn = _G, a, b end
    local orig = rawget(tbl, name) or (type(tbl[name]) == "function" and tbl[name] or nil)
    if type(orig) ~= "function" then return end
    rawset(tbl, name, function(...)
        local r = table.pack(orig(...))
        fn(...)
        return table.unpack(r, 1, r.n)
    end)
end

-- ---- event delivery + timer queue ------------------------------------------------
local function Report(where, err)
    MOCKM.errors[#MOCKM.errors + 1] = where .. ": " .. tostring(err)
    print("  ERROR in " .. where .. ": " .. tostring(err))
end

-- deliver `event` to every frame that registered it (WoW semantics), creation order
function MOCKM.fire(event, ...)
    local snap = {}
    for _, f in ipairs(MOCKM.eventFrames) do snap[#snap + 1] = f end
    local n = 0
    for _, f in ipairs(snap) do
        local h = f._scripts.OnEvent
        if f._events[event] and h then
            n = n + 1
            local ok, err = pcall(h, f, event, ...)
            if not ok then Report("event " .. event, err) end
        end
    end
    return n                          -- how many frames received it
end

C_Timer = {
    After = function(delay, fn)
        MOCKM.timerSeq = MOCKM.timerSeq + 1
        MOCKM.timers[#MOCKM.timers + 1] = { due = MOCK.gt + (delay or 0), seq = MOCKM.timerSeq, fn = fn }
    end,
}

-- move the clock forward by dt seconds and run every timer that came due (in due
-- order; timers scheduled by a running timer also run if they are already due)
function MOCKM.advance(dt)
    MOCK.gt = MOCK.gt + (dt or 0)
    for _ = 1, 100000 do
        local bi
        for i, t in ipairs(MOCKM.timers) do
            if t.due <= MOCK.gt + 1e-9 then
                local b = bi and MOCKM.timers[bi]
                if not b or t.due < b.due or (t.due == b.due and t.seq < b.seq) then bi = i end
            end
        end
        if not bi then return end
        local t = table.remove(MOCKM.timers, bi)
        local ok, err = pcall(t.fn)
        if not ok then Report("timer", err) end
    end
    error("MOCKM.advance: timer storm (a 0-delay timer re-schedules itself)")
end

-- find a recorded Button by the first text it was given
function MOCKM.button(text)
    for _, f in ipairs(MOCKM.frames) do
        if f._type == "Button" and f._firstText == text then return f end
    end
end

-- was a text matching `pat` (plain find) set since log position `since`?
function MOCKM.saw(pat, since)
    for i = (since or 0) + 1, #MOCKM.texts do
        if string.find(MOCKM.texts[i], pat, 1, true) then return true end
    end
    return false
end
