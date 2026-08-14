-- Stub harness for NorgAHValue's auto-pricing.
--
-- (!) WHY THIS EXISTS. Seven stacked auctions were listed at exactly count x the
-- price the auction-house bot is willing to pay, so none of them could ever sell,
-- while every single-item listing was priced at precisely the bot's maximum and
-- sold fine. With count = 1 the error is invisible (x1 twice is x1), which is why
-- it survived every manual check.
--
-- Reading the code says the on-disk version computes the right number. Reading the
-- code is what I got wrong twice today, so this drives the REAL module against a
-- fake auction frame and asserts on the copper value it actually puts in the box.
--
-- The bot's rule, from AuctionHouseBot.cpp:
--     maximumBid = SellPrice * count * buyerPriceMultiplier(quality)
--   capped, for vendor-sold items, at BuyPrice * count.
-- Anything above that never gets a bid.

local placed = {}          -- what the addon wrote into the money boxes
local sellSlot = nil       -- what is currently "in" the auction sell slot

-- ------------------------------------------------------------ client API stubs
local allFrames = {}
local function newFrame()
    local f = { _scripts = {}, _events = {} }
    function f:GetItem() return sellSlot and sellSlot.name, sellSlot and sellSlot.link end
    function f:GetParent() return self end
    function f:GetChecked() return true end
    function f:RegisterEvent(e) self._events[e] = true end
    function f:UnregisterEvent(e) self._events[e] = nil end
    function f:SetScript(k, v) self._scripts[k] = v end
    function f:GetScript(k) return self._scripts[k] end
    function f:Show() end
    function f:Hide() end
    function f:IsShown() return true end
    function f:SetPoint() end
    function f:SetWidth() end
    function f:SetHeight() end
    function f:SetJustifyH() end
    function f:SetOwner() end
    function f:ClearLines() end
    function f:SetAuctionSellItem() end
    function f:CreateFontString()
        return { SetPoint = function() end, SetWidth = function() end,
                 SetJustifyH = function() end,
                 SetText = function(s, t) s.text = t end }
    end
    table.insert(allFrames, f)
    return f
end

_G.CreateFrame = function() return newFrame() end
_G.UIParent = newFrame()
_G.StartPrice = newFrame()
_G.BuyoutPrice = newFrame()
_G.AuctionFrame = newFrame()
_G.AuctionsItemButton = newFrame()

_G.MoneyInputFrame_SetCopper = function(frame, copper)
    placed[frame == _G.StartPrice and "start" or "buyout"] = copper
end

-- 3.3.5a: name, texture, count, quality, canUse, price
_G.GetAuctionSellItemInfo = function()
    if not sellSlot then return nil end
    return sellSlot.name, "tex", sellSlot.count, sellSlot.quality, 1, 0
end

-- 3.3.5a: name, link, quality, iLevel, reqLevel, class, subclass, maxStack, ...
_G.GetItemInfo = function()
    if not sellSlot then return nil end
    return sellSlot.name, sellSlot.link, sellSlot.quality, 1, 1, "", "", 20
end

_G.AuctionsDuration1 = newFrame()
_G.AuctionsDuration2 = newFrame()
_G.AuctionsDuration3 = newFrame()
-- (!) THE PRICE-MODE DROPDOWN. In "per item" mode the client multiplies what the
-- addon typed by the stack size. Every mispriced auction came from filling the
-- stack TOTAL while this was set to per item -- and it is invisible at count 1.
_G._priceMode = 2   -- 1 = per item, 2 = per stack
_G.AuctionsPriceDropDown = newFrame()
_G.UIDropDownMenu_GetSelectedValue = function() return _G._priceMode end
_G.UIDropDownMenu_GetText = function() return _G._priceMode == 1 and "per item" or "per stack" end
_G.GetAuctionDuration = function() return 3 end
_G.UnitName = function() return "Tester" end
_G.DEFAULT_CHAT_FRAME = { AddMessage = function() end }
_G.SlashCmdList = {}

-- The addon reads the item id out of a scratch tooltip because 3.3.5a gives the
-- sell slot no link API. Model that: the tooltip yields whatever is in the slot.
_G.GameTooltip = newFrame()

dofile("/data/NorgAHValue/Config.lua")
dofile("/data/NorgAHValue/DataSell.lua")
dofile("/data/NorgAHValue/DataVendor.lua")
dofile("/data/NorgAHValue/AutoPrice.lua")

local pass, fail = 0, 0
local function check(name, cond, detail)
    if cond then pass = pass + 1; print("  PASS  " .. name)
    else fail = fail + 1; print("  FAIL  " .. name .. "   " .. tostring(detail)) end
end

-- What the server would actually pay, recomputed here independently of the addon
-- so the test cannot drift into agreeing with the code it is checking.
local BOT_MULT = { [0] = 1, [1] = 3, [2] = 5, [3] = 12, [4] = 15, [5] = 20 }
-- (!) THE CAP BINDS ONLY ON ITEMS AN NPC ACTUALLY SELLS. AuctionHouseBot.cpp
-- gates it on config->NpcItems membership, NOT on BuyPrice > 0. Tigerseye has
-- BuyPrice 400 and ZERO vendors, so it is uncapped -- my first version of this
-- helper capped on BuyPrice alone and reported a bug in the addon that did not
-- exist. Model the real condition.
local function botMax(sell, count, quality, vendorBuy)
    local bid = sell * count * BOT_MULT[quality]
    if vendorBuy and vendorBuy > 0 then
        local cap = vendorBuy * count
        if bid > cap then bid = cap end
    end
    return math.floor(bid)
end

check("module loaded and hooked the auction events",
      type(NorgAHValue_Mult) == "table" and NorgAHValue_Mult[1] == 3,
      tostring(NorgAHValue_Mult and NorgAHValue_Mult[1]))

-- (!) THE REGRESSION. Real numbers from the live auction house:
--   Linen Cloth  (2589) SellPrice 13, quality 1, BuyPrice 55  -- listed x12 at 5616
--   Deviate Scale(6470) SellPrice 20, quality 1, BuyPrice 80  -- listed x3  at 540
--   Silk Cloth   (4306) SellPrice 150,quality 1, BuyPrice 600 -- listed x2  at 1800
--   Tigerseye    (818)  SellPrice 100,quality 2, BuyPrice 400 -- listed x2  at 2000
local cases = {
    { id = 2589, name = "Linen Cloth",   sell = 13,  buy = 55,  q = 1, count = 12, wasListed = 5616 },
    { id = 6470, name = "Deviate Scale", sell = 20,  buy = 80,  q = 1, count = 3,  wasListed = 540,  novendor = true },
    { id = 4306, name = "Silk Cloth",    sell = 150, buy = 600, q = 1, count = 2,  wasListed = 1800 },
    { id = 818,  name = "Tigerseye",     sell = 100, buy = 400, q = 2, count = 2,  wasListed = 2000, novendor = true },
    { id = 2287, name = "Haunch of Meat",sell = 6,   buy = 125, q = 1, count = 1,  wasListed = 18   },
}

for _, c in ipairs(cases) do
    placed = {}
    sellSlot = { name = c.name, count = c.count, quality = c.q,
                 link = "|cffffffff|Hitem:" .. c.id .. ":0:0:0:0:0:0:0|h[" .. c.name .. "]|h|r" }

    -- drive the addon the way the client would
    -- (!) The addon keeps its frame in a LOCAL, so there is nothing to look up.
    -- Find it by what it registered for -- that is also a real assertion: if the
    -- module ever stops listening for NEW_AUCTION_UPDATE this test stops working
    -- rather than quietly passing.
    local ev
    for _, fr in ipairs(allFrames) do
        if fr._events["NEW_AUCTION_UPDATE"] and fr._scripts["OnEvent"] then ev = fr end
    end
    assert(ev, "no frame registered NEW_AUCTION_UPDATE")
    ev._scripts["OnEvent"](ev, "ADDON_LOADED", "Blizzard_AuctionUI")
    ev._scripts["OnEvent"](ev, "NEW_AUCTION_UPDATE")
    -- (!) The event only raises a flag; the work happens on a deliberate
    -- two-tick OnUpdate delay, because the sell slot is not populated yet on
    -- the frame the event fires. Drive both ticks or nothing is ever priced.
    ev._scripts["OnUpdate"](ev)
    ev._scripts["OnUpdate"](ev)

    local want = botMax(c.sell, c.count, c.q, (not c.novendor) and c.buy or nil)
    -- what the client will actually list, from what the addon typed
    local listed = (_G._priceMode == 1) and ((placed.buyout or 0) * c.count) or placed.buyout
    local got = placed.buyout
    check(string.format("%s x%d priced at the bot's max (%d, not %d)",
                        c.name, c.count, want, c.wasListed),
          got == want, "addon put " .. tostring(got))
end

-- ===================================== the same cases again, in PER ITEM mode
-- The number in the box differs, but what the client LISTS must be identical.
_G._priceMode = 1
for _, c in ipairs(cases) do
    placed = {}
    lastLinkReset = true
    sellSlot = { name = c.name, count = c.count, quality = c.q,
                 link = "|cffffffff|Hitem:" .. c.id .. ":0:0:0:0:0:0:9|h[" .. c.name .. "]|h|r" }
    local ev
    for _, fr in ipairs(allFrames) do
        if fr._events["NEW_AUCTION_UPDATE"] and fr._scripts["OnEvent"] then ev = fr end
    end
    ev._scripts["OnEvent"](ev, "NEW_AUCTION_UPDATE")
    ev._scripts["OnUpdate"](ev)
    ev._scripts["OnUpdate"](ev)
    local want = botMax(c.sell, c.count, c.q, (not c.novendor) and c.buy or nil)
    local listedTotal = (placed.buyout or 0) * c.count
    check(string.format("%s x%d lists at %d in PER ITEM mode", c.name, c.count, want),
          listedTotal == want,
          "addon typed " .. tostring(placed.buyout) .. " -> client lists " .. listedTotal)
end

-- ============================ switching the dropdown must RE-PRICE the slot
-- (!) The fill happens on item change. The mode is not part of the item, so a
-- flip mid-listing would leave the old number and the client would multiply it.
_G._priceMode = 2
placed = {}
sellSlot = { name = "Silk Cloth", count = 2, quality = 1,
             link = "|cffffffff|Hitem:4306:0:0:0:0:0:0:77|h[Silk Cloth]|h|r" }
local ev
for _, fr in ipairs(allFrames) do
    if fr._events["NEW_AUCTION_UPDATE"] and fr._scripts["OnEvent"] then ev = fr end
end
ev._scripts["OnEvent"](ev, "NEW_AUCTION_UPDATE")
ev._scripts["OnUpdate"](ev); ev._scripts["OnUpdate"](ev)
check("per stack fills the total", placed.buyout == 900, tostring(placed.buyout))

-- now flip the dropdown WITHOUT touching the item
_G._priceMode = 1
placed = {}
ev._scripts["OnUpdate"](ev); ev._scripts["OnUpdate"](ev); ev._scripts["OnUpdate"](ev)
local listed = (placed.buyout or 0) * 2
check("flipping to per item re-prices the slot", listed == 900,
      "typed " .. tostring(placed.buyout) .. " -> client lists " .. listed)

print(string.format("\n  ==== %d passed, %d failed ====", pass, fail))
os.exit(fail == 0 and 0 or 1)
