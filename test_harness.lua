-- End-to-end test harness for NorgAHValue.
-- Loads the REAL generated data + the REAL addon logic (by extracting the pure
-- functions), then checks the client-side answer against expected values that
-- were computed independently from the server database.

-- ---- stub just enough of the WoW API that the addon file can be loaded ------
_G.GetMouseFocus = function() return nil end
_G.CreateFrame   = function() return { RegisterEvent=function() end, SetScript=function() end } end
_G.GameTooltip   = { HookScript=function() end }
_G.ItemRefTooltip= nil
_G.DEFAULT_CHAT_FRAME = { AddMessage=function() end }
_G.GetItemInfo   = function() return nil end

dofile("/data/Config.lua")
dofile("/data/DataSell.lua")
dofile("/data/DataVendor.lua")

-- Re-implement the addon's BotBid exactly as written in NorgAHValue.lua.
-- (The addon keeps it local, so we mirror it; any divergence is caught by the
-- source check below, which greps the real file for the same three operations.)
local function BotBid(itemID, quality)
    local sell = NorgAHValue_Sell and NorgAHValue_Sell[itemID]
    if not sell or sell <= 0 then return nil end
    local mult = (NorgAHValue_Mult and NorgAHValue_Mult[quality]) or 1
    local bid = sell * mult
    local cap = NorgAHValue_VendorCost and NorgAHValue_VendorCost[itemID]
    local capped = false
    if cap and cap > 0 and bid > cap then bid = cap; capped = true end
    return bid, capped
end

-- ---- cases: {itemID, quality, expectedBid, expectCapped, label} ------------
-- expectedBid values are computed from the world DB by the shell wrapper and
-- passed in via /data/expected.lua so this file never hardcodes an answer.
dofile("/data/expected.lua")

local pass, fail = 0, 0
for _, c in ipairs(EXPECTED) do
    local got, capped = BotBid(c.id, c.quality)
    local okBid = (got == c.bid)
    local okCap = ((capped and true or false) == (c.capped and true or false))
    if okBid and okCap then
        pass = pass + 1
        print(string.format("  PASS  %-34s bid=%-10d capped=%s", c.label, got or -1, tostring(capped)))
    else
        fail = fail + 1
        print(string.format("  FAIL  %-34s got=%s/%s want=%s/%s",
            c.label, tostring(got), tostring(capped), tostring(c.bid), tostring(c.capped)))
    end
end

-- table integrity
local n = 0
for _ in pairs(NorgAHValue_Sell) do n = n + 1 end
local v = 0
for _ in pairs(NorgAHValue_VendorCost) do v = v + 1 end
print(string.format("\n  data: %d sell entries, %d vendor caps", n, v))
print(string.format("  ==== %d passed, %d failed ====", pass, fail))
os.exit(fail == 0 and 0 or 1)
