-- End-to-end DATA check for NorgAHValue's tooltip bid.
--
-- WHAT THIS COVERS THAT ahvalue_test.lua DOES NOT. ahvalue_test drives
-- AutoPrice.lua -- the auction SELL SLOT, stack maths and the per-item/per-stack
-- dropdown -- against hand-written items. This harness drives the other half:
-- NorgAHValue.lua's tooltip line, priced from the GENERATED tables. It is NOT the
-- sole check on those tables: ahvalue_test dofiles DataSell.lua and DataVendor.lua
-- as well, so a table that fails to load or loses an item it asserts on breaks
-- that suite too. What this one adds is where the expected bids come from -- the
-- server's own data rather than the addon's arithmetic. See LoadExpected() below.
--
-- (!) NOTHING IN THE TREE RUNS THIS FILE -- run it by hand. norg-wow-sync.sh names
-- it, but only to copy it to the public addons mirror; no suite, script or CI job
-- invokes it. The name is why it has to be named there at all: it does not end in
-- _test.lua, so it misses the glob that matches every other suite. Run it from the
-- addon root:
--     docker run --rm -v "$PWD:/data" nickblah/lua:5.1-luarocks lua /data/test_harness.lua

-- (!) THE RULE: EVERY dofile PATH IS ADDON-QUALIFIED, "/data/<AddOn>/<file>.lua".
-- Every suite in this project is run from the addon ROOT with -v "$PWD:/data", so
-- /data IS that root and an addon's own files only exist one folder down. An
-- unqualified "/data/Config.lua" resolves ONLY when this single addon folder is
-- mounted on its own -- which passes in isolation and then dies as a BROKEN TEST
-- in a run-everything loop, so the file quietly ships unverified. The rule holds
-- for every suite here and for any new one; never drop the folder segment, and do
-- not restate it as a count of how many suites currently comply.
-- This file had exactly that bug and could not run from ANY directory: the addon's
-- own files only exist under NorgAHValue/, and expected.lua exists nowhere at all.

-- ---- stub just enough of the WoW API that the addon file can be loaded ------
local CURRENT              -- the item the tooltip is currently describing
local MONEY, SUFFIX        -- what the addon drew into the tooltip's money row

_G.GetMouseFocus = function() return nil end   -- no item button -> StackCount() = 1
_G.CreateFrame   = function() return { RegisterEvent=function() end, SetScript=function() end } end
_G.ItemRefTooltip= nil
_G.DEFAULT_CHAT_FRAME = { AddMessage=function() end }

-- 3.3.5a GetItemInfo: name, link, quality, ... -- quality is the third return.
_G.GetItemInfo = function()
    if not CURRENT then return nil end
    return CURRENT.name, CURRENT.link, CURRENT.quality
end

-- Blizzard's own money-row renderer, which is what the addon calls:
--     SetTooltipMoney(tt, copper, nil, prefixLabel, suffixText)
_G.SetTooltipMoney = function(_, copper, _, _, suffix) MONEY, SUFFIX = copper, suffix end

local hooks = {}
_G.GameTooltip = {
    HookScript = function(_, script, fn) hooks[script] = fn end,
    GetItem    = function() return CURRENT and CURRENT.name, CURRENT and CURRENT.link end,
    Show       = function() end,
    -- Only reached if SetTooltipMoney is missing. It is not, so a call here means
    -- the addon took its degraded path and the assertions should say so.
    AddLine    = function(_, text) MONEY, SUFFIX = nil, "FELL BACK TO AddLine: " .. tostring(text) end,
}

dofile("/data/NorgAHValue/Config.lua")
dofile("/data/NorgAHValue/DataSell.lua")
dofile("/data/NorgAHValue/DataVendor.lua")
dofile("/data/NorgAHValue/NorgAHValue.lua")

-- (!) THE REAL BotBid IS DRIVEN, NOT MIRRORED. This file used to carry a hand-copy
-- of BotBid and a comment claiming "the source check below" caught any divergence
-- -- there was no such check, and there never had been, so the harness was really
-- asserting that a copy of the formula agreed with itself while the shipped
-- function could say anything at all. The addon keeps BotBid local, so it is
-- reached the way the game reaches it: through the OnTooltipSetItem hook it
-- registers on GameTooltip. That also makes `capped` observable the way a PLAYER
-- sees it -- as the "(vendor capped)" annotation, not as a private boolean.
local function Ask(itemID, quality)
    MONEY, SUFFIX = nil, nil
    CURRENT = {
        name    = "item" .. itemID,
        link    = "|cffffffff|Hitem:" .. itemID .. ":0:0:0:0:0:0:0|h[item]|h|r",
        quality = quality,
    }
    -- AddLine() draws once per tooltip and latches tt.norgAHDone; OnHide is what
    -- clears it in game, so drive that too or every case after the first is a no-op.
    if hooks["OnHide"] then hooks["OnHide"](_G.GameTooltip) end
    if not hooks["OnTooltipSetItem"] then return nil, false, "no OnTooltipSetItem hook registered" end
    hooks["OnTooltipSetItem"](_G.GameTooltip)
    return MONEY, (SUFFIX or ""):find("vendor capped", 1, true) ~= nil, SUFFIX
end

-- ---- cases: {id, quality, bid, capped, label} ------------------------------
-- The expected bids live OUTSIDE this file, so it cannot drift into agreeing with
-- the code it is checking. Every row is recomputable from the server's own data
-- with the formula in gen-ahvalue-addon.sh's header, at stack count 1 (which is
-- what StackCount() returns here, since the GetMouseFocus stub yields no button):
-- SellPrice * the mod_auctionhousebot buyer multiplier for that quality, capped
-- at BuyPrice when the item appears in npc_vendor.
--
-- expected_body.txt, checked in beside this file, is the source in practice.
-- /data/expected.lua is an OPTIONAL override preferred over it when present; no
-- file of that name exists in the tree and nothing writes one -- gen-ahvalue-addon.sh
-- emits Config.lua, DataSell.lua and DataVendor.lua and nothing else -- so treat it
-- as a hook someone can drop a fresh recomputation into, NOT as generated output.
-- Neither present is a hard FAIL, not a silent zero-case pass -- an empty EXPECTED
-- would otherwise print "0 passed, 0 failed" and exit 0.
local function LoadExpected()
    local f = io.open("/data/expected.lua")
    if f then
        f:close()
        dofile("/data/expected.lua")
        return "/data/expected.lua"
    end
    local b = io.open("/data/expected_body.txt")
    if not b then return nil end
    local body = b:read("*a")
    b:close()
    local chunk, err = loadstring("EXPECTED = {\n" .. body .. "\n}", "expected_body.txt")
    if not chunk then return nil, err end
    chunk()
    return "/data/expected_body.txt"
end

local pass, fail = 0, 0
local function summary()
    print(string.format("\n  ==== %d passed, %d failed ====", pass, fail))
end

local source, err = LoadExpected()
if not source or type(EXPECTED) ~= "table" or #EXPECTED == 0 then
    fail = fail + 1
    print("  FAIL  expected values could not be loaded  " ..
          tostring(err or "no /data/expected.lua and no /data/expected_body.txt"))
    summary()
    os.exit(1)
end
print("  expectations from " .. source .. " (" .. #EXPECTED .. " items)")

for _, c in ipairs(EXPECTED) do
    local got, capped, suffix = Ask(c.id, c.quality)
    local okBid = (got == c.bid)
    local okCap = ((capped and true or false) == (c.capped and true or false))
    if okBid and okCap then
        pass = pass + 1
        print(string.format("  PASS  %-34s bid=%-10d capped=%s", c.label, got or -1, tostring(capped)))
    else
        fail = fail + 1
        print(string.format("  FAIL  %-34s got=%s/%s want=%s/%s  %s",
            c.label, tostring(got), tostring(capped), tostring(c.bid), tostring(c.capped),
            tostring(suffix)))
    end
end

-- An item the bot will not bid on at all must draw NO money row, not a zero one.
local none = Ask(0, 1)
if none == nil then
    pass = pass + 1
    print("  PASS  unknown item draws no AH Value row at all")
else
    fail = fail + 1
    print("  FAIL  unknown item draws no AH Value row at all  got " .. tostring(none))
end

-- table integrity
local n = 0
for _ in pairs(NorgAHValue_Sell) do n = n + 1 end
local v = 0
for _ in pairs(NorgAHValue_VendorCost) do v = v + 1 end
print(string.format("\n  data: %d sell entries, %d vendor caps", n, v))
summary()
os.exit(fail == 0 and 0 or 1)
