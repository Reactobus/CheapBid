-- Unit tests for CheapBids_Prospect (loaded via the CheapBidsTest.PR hook).
-- Run with: node tests/run.js

local PR = CheapBidsTest.PR

local passed, failed = 0, 0
local function ok(cond, msg)
    if cond then passed = passed + 1
    else failed = failed + 1; print("  FAIL: " .. tostring(msg)) end
end
local function eq(a, b, msg)
    ok(a == b, (msg or "") .. "  (got " .. tostring(a) .. ", want " .. tostring(b) .. ")")
end

local function fakeTip(id)
    local t = { lines = {} }
    function t:GetItem() return "x", "|Hitem:" .. id .. ":0|h[x]|h" end
    function t:AddLine(text) self.lines[#self.lines + 1] = text end
    function t:Show() end
    return t
end

CheapBidsDB = {}

-- ===== data sanity =====
ok(PR.PROSPECT[2770], "Copper Ore is prospectable")
eq(#PR.PROSPECT[2770], 3, "Copper Ore yields 3 gems")
ok(PR.FROM_ORE[818], "Tigerseye has a reverse ore list")
eq(PR.FROM_ORE[818][1], 2770, "Tigerseye comes from Copper Ore")

-- ===== forward: hover an ore -> "Prospects into" + gem lines, sorted by chance =====
local tip = fakeTip(2770)       -- Copper Ore: Tigerseye .5, Malachite .5, Shadowgem .1
PR.OnSetItem(tip)
eq(#tip.lines, 4, "ore: header + 3 gem lines")
eq(tip.lines[1], "Prospects into (per 5 ore):", "ore: header text")
local plines = PR.BuildLines(PR.PROSPECT[2770])       -- un-indented, to assert ordering
ok(plines[1]:find("^50%%"), "ore: highest chance first (50%)")
ok(plines[3]:find("^10%%"), "ore: lowest chance last (10%)")
PR.OnSetItem(tip)
eq(#tip.lines, 4, "ore: no duplicate block on re-fire")

-- ===== reverse: hover a gem -> "Prospected from: <ores>" =====
tip = fakeTip(23077)            -- Blood Garnet: Fel Iron + Adamantite
PR.OnSetItem(tip)
eq(#tip.lines, 1, "gem: one reverse line")
ok(tip.lines[1]:find("Prospected from"), "gem: reverse label")
ok(tip.lines[1]:find("Fel Iron Ore") and tip.lines[1]:find("Adamantite Ore"), "gem: both source ores listed")

-- ===== ignore unrelated items / toggle =====
tip = fakeTip(6948); PR.OnSetItem(tip)     -- Hearthstone
eq(#tip.lines, 0, "unrelated item ignored")
CheapBidsDB.prospectTip = false
tip = fakeTip(2770); PR.OnSetItem(tip)
eq(#tip.lines, 0, "/cbpr off -> nothing")
CheapBidsDB.prospectTip = true

-- ===== modern client (WoW Forever): C_Item fallback + TooltipDataProcessor path =====
do
    local gii, savedCItem = GetItemInfo, C_Item
    GetItemInfo, C_Item = nil, { GetItemInfo = function() return "LiveGem" end }
    ok(PR.BuildLines(PR.PROSPECT[2770])[1]:find("LiveGem", 1, true), "C_Item: gem name via C_Item.GetItemInfo")
    C_Item = nil
    ok(PR.BuildLines(PR.PROSPECT[2770])[1]:find("Tigerseye", 1, true), "no item API -> fallback name, no error")
    GetItemInfo, C_Item = gii, savedCItem
end
do
    local function frame(id, scripts)
        local f = fakeTip(id); f.handlers = {}
        function f:HasScript(s) return scripts[s] == true end
        function f:HookScript(s, fn)
            if not scripts[s] then error(s .. ": no such script") end
            self.handlers[s] = fn
        end
        return f
    end
    local function tdp()
        local t = { calls = {} }
        function t.AddTooltipPostCall(kind, fn) t.calls[#t.calls + 1] = { kind = kind, fn = fn } end
        return t
    end
    local savedEnum = Enum
    Enum = { TooltipDataType = { Item = 0 } }

    local legacy = frame(2770, { OnTooltipSetItem = true, OnTooltipCleared = true })
    eq(PR.HookTip(legacy), true, "legacy: HookTip hooks OnTooltipSetItem")
    local t1 = tdp()
    eq(PR.InstallModernHooks(t1, legacy), nil, "legacy: no post-call even with TDP present")
    eq(#t1.calls, 0, "legacy: TooltipDataProcessor untouched")

    local modern = frame(2770, { OnTooltipCleared = true })
    local okHook, res = pcall(PR.HookTip, modern)
    ok(okHook and res == false, "modern: HookTip skips (no throw)")
    local t2 = tdp()
    ok(PR.InstallModernHooks(t2, modern), "modern: post-call registered")
    eq(t2.calls[1] and t2.calls[1].kind, 0, "modern: registered for Enum.TooltipDataType.Item")
    t2.calls[1].fn(modern); t2.calls[1].fn(modern)
    eq(#modern.lines, 4, "modern: ore block once (de-dup)")
    modern.handlers.OnTooltipCleared(modern)
    t2.calls[1].fn(modern)
    eq(#modern.lines, 8, "modern: shows again after a clear")

    local secret = frame(2770, { OnTooltipCleared = true })
    function secret:GetItem() error("attempt to use a secret value") end
    local t3 = tdp(); PR.InstallModernHooks(t3, secret)
    ok(pcall(t3.calls[1].fn, secret), "modern: post-call swallows a secret-value error")
    Enum = savedEnum
end

SlashCmdList["CHEAPBIDSPR"]()
eq(CheapBidsDB.prospectTip, false, "/cbpr: ON -> OFF")
SlashCmdList["CHEAPBIDSPR"]()
eq(CheapBidsDB.prospectTip, true, "/cbpr: OFF -> ON")

print(string.format("RESULT (prospect): %d passed, %d failed", passed, failed))
TEST_FAILED = (TEST_FAILED or 0) + failed
