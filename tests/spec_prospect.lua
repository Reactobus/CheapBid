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

SlashCmdList["CHEAPBIDSPR"]()
eq(CheapBidsDB.prospectTip, false, "/cbpr: ON -> OFF")
SlashCmdList["CHEAPBIDSPR"]()
eq(CheapBidsDB.prospectTip, true, "/cbpr: OFF -> ON")

print(string.format("RESULT (prospect): %d passed, %d failed", passed, failed))
TEST_FAILED = (TEST_FAILED or 0) + failed
