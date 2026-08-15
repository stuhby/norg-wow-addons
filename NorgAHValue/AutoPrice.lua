-- (!) SAY THE VERSION AT LOGIN. Half a day was lost today to a listing that
-- could not have come from this code: the copy in the WoW folder was older than
-- the copy on the server, and nothing in game could tell them apart. A version
-- in the chat frame at login makes "is my copy current?" answerable in one
-- second instead of by arithmetic archaeology on auction prices.
--
-- (!) AND IT IS READ FROM THE .toc, NEVER COPIED INTO A CONSTANT HERE. A second
-- copy of the number drifts from the .toc in silence, and a login line that lies
-- is worse than no login line at all, because the wiki's troubleshooting page
-- tells you to trust it.
-- "?" means the client never indexed this folder, which is itself the answer to
-- "why is nothing happening".
local ADDON = "NorgAHValue"      -- FOLDER name; GetAddOnMetadata keys on that
NORGAHVALUE_VERSION = GetAddOnMetadata(ADDON, "Version") or "?"
local vf = CreateFrame("Frame")
vf:RegisterEvent("PLAYER_LOGIN")
vf:SetScript("OnEvent", function()
    -- (!) ONE LINE PER ADDON. The item count used to be a SECOND "loaded" line,
    -- printed from NorgAHValue.lua's ADDON_LOADED handler; the operator loads
    -- eight of these, so two lines each is login spam. The count is worth
    -- keeping -- it is the only proof DataSell.lua actually loaded -- so it
    -- rides along here and that branch is gone.
    local n = 0
    if NorgAHValue_Sell then for _ in pairs(NorgAHValue_Sell) do n = n + 1 end end
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00NorgAHValue|r v" .. NORGAHVALUE_VERSION ..
        " loaded -- " .. n .. " items priced. /ahprice to re-price the sell slot.")
end)

--[[----------------------------------------------------------------------------
  NorgAHValue -- auto-pricing for the auction sell tab.

  Drop an item into the Auctions sell slot and the Starting Price and Buyout are
  filled in at the highest price the Norg auction-house bot will actually pay,
  with the deposit and the house cut spelled out underneath.

  WHY THE BOT PRICE IS A CEILING, NOT A SUGGESTION
  The bot has a hard maximum per item. List one copper above it and the bot will
  never buy, and on a server whose economy is mostly bots that usually means the
  auction simply expires and you are out the deposit. So the useful answer is
  "the most I can charge and still be certain of a sale", which is exactly the
  number this fills in.

  (!) THESE RATES TRACK worldserver.conf AND MUST BE UPDATED WITH IT.
  AllowTwoSide.Interaction.Auction = 1, so AuctionHouseMgr::GetAuctionHouseEntry()
  routes every auction to the NEUTRAL house whichever auctioneer you use, and in
  AuctionHouse.dbc the neutral house is far harsher than the faction ones:

                     depositPercent   cutPercent
      faction 1-6           5              5
      NEUTRAL   7          25             15

  Norg scales that back down to faction economics with the two config
  multipliers rather than by editing a DBC the client also ships:

      Rate.Auction.Cut     = 0.333333    ->  15% x 0.333333 = 5%
      Rate.Auction.Deposit = 0.2         ->  0.75 x 0.2     = 0.15

  So the EFFECTIVE numbers below are the faction ones. If those config lines ever
  change, change these to match -- an addon quietly quoting the old cut is worse
  than one that quotes none, because it looks authoritative.

  Deposit, straight from AuctionHouseMgr::GetAuctionDeposit:

      multiplier = depositPercent * 3 / 100 * Rate.Auction.Deposit   = 0.15
      timeHr     = ((seconds / 60) / 60) / 12                        = 1, 2 or 4
      deposit    = multiplier * SellPrice * count * timeHr
      minimum    = AH_MINIMUM_DEPOSIT (100c) * Rate.Auction.Deposit  = 20c

  (The /3 and *3 in the original expression cancel; this is the same arithmetic.)
------------------------------------------------------------------------------]]

-- Effective rates AFTER the Rate.Auction.* multipliers in worldserver.conf.
local CUT_PCT     = 5        -- 15 (neutral dbc) x 0.333333
local DEPOSIT_MUL = 0.15     -- 0.75 (neutral dbc) x 0.2
local MIN_DEPOSIT = 20       -- AH_MINIMUM_DEPOSIT 100c x 0.2

-- Duration radio -> 12-hour blocks, matching timeHr in the server formula.
local DURATION_BLOCKS = { [1] = 1, [2] = 2, [3] = 4 }

local lastLink, infoFS, pending, lastSaid

local function Money(c)
    c = math.floor(c or 0)
    local g, s, k = math.floor(c / 10000), math.floor((c % 10000) / 100), c % 100
    local out = ""
    if g > 0 then out = out .. g .. "|cffffd700g|r " end
    if s > 0 then out = out .. s .. "|cffc7c7cfs|r " end
    if k > 0 or out == "" then out = out .. k .. "|cffeda55fc|r" end
    return (out:gsub("%s+$", ""))
end

--- What the bot pays for ONE of this item. Mirrors NorgAHValue's tooltip logic;
--- kept in step with it deliberately, since a sell price that disagreed with the
--- tooltip on the same item would be worse than having neither.
local function BotUnitPrice(itemID, quality)
    local sell = NorgAHValue_Sell and NorgAHValue_Sell[itemID]
    if not sell or sell <= 0 then return nil end

    local bid = sell * ((NorgAHValue_Mult and NorgAHValue_Mult[quality]) or 1)

    -- Never above what a player could pay a vendor for the same goods; the bot
    -- applies this cap too, so ignoring it would price the auction out of reach.
    local cap = NorgAHValue_VendorCost and NorgAHValue_VendorCost[itemID]
    if cap and cap > 0 and bid > cap then bid = cap end

    return math.floor(bid)
end

--- (!) THE SELL SLOT HAS NO ITEM-LINK API IN 3.3.5a.
--- GetAuctionSellItemInfo() returns a name, a texture and a count but no link
--- and no item id, and the name alone is ambiguous across item ids. The only
--- route to the id is to point a scratch tooltip at the slot and read the link
--- back out of it, which is what SetAuctionSellItem exists for.
local scanner
local function SellSlotItem()
    if not scanner then
        scanner = CreateFrame("GameTooltip", "NorgAHAutoPriceScanner", nil, "GameTooltipTemplate")
    end
    scanner:SetOwner(UIParent, "ANCHOR_NONE")
    scanner:ClearLines()

    local ok = pcall(function() scanner:SetAuctionSellItem() end)
    if not ok then return nil end

    local _, link = scanner:GetItem()
    if not link or link == "" then return nil end

    return link, tonumber(link:match("item:(%d+)"))
end

--- (!) PER ITEM OR PER STACK -- THE BOX MEANS DIFFERENT THINGS.
---
--- The auction panel has a price-mode dropdown. In "per stack" mode the number
--- you type IS the total. In "per item" mode the client multiplies it by the
--- stack size. Filling the stack total while the dropdown says "per item" lists
--- the goods at total x count -- which is silently unsellable, and invisible on
--- single items because x1 twice is x1. Every mispriced auction traced back to
--- this, not to the arithmetic.
---
--- The dropdown's global name differs between builds, so probe rather than
--- assume, and fall back to per-stack (the old behaviour) when nothing is found.
--- Returns true when the client will multiply by the stack size for us.
--- (!) FIND THE DROPDOWN RATHER THAN GUESSING ITS NAME. /framestack over the
--- open menu reports DropDownList1, which is the shared popup every dropdown
--- borrows -- not the control. What it does tell us is the parent chain:
--- AuctionFrameAuctions. So walk that frame's children and take the dropdown
--- whose name mentions price. Cached, because the frame never changes once the
--- auction UI has loaded.
local foundDD, searched
local function PriceDropDown()
    if foundDD then return foundDD end

    foundDD = _G["AuctionsPriceDropDown"] or _G["AuctionPriceDropDown"]
    if foundDD then return foundDD end

    if searched or not AuctionFrameAuctions or not AuctionFrameAuctions.GetNumChildren then
        return nil
    end
    searched = true

    local kids = { AuctionFrameAuctions:GetChildren() }
    for i = 1, #kids do
        local c = kids[i]
        local n = c and c.GetName and c:GetName()
        if n then
            local ln = n:lower()
            if ln:find("price") and ln:find("drop") then
                foundDD = c
                return c
            end
        end
    end
    return nil
end

NorgAHValue_PriceDropDown = PriceDropDown

local function PerItemMode()
    local dd = PriceDropDown()

    -- Prefer the selected VALUE: 1 = per item, 2 = per stack in every build that
    -- has this control.
    if dd and UIDropDownMenu_GetSelectedValue then
        local v = UIDropDownMenu_GetSelectedValue(dd)
        if v == 1 then return true end
        if v == 2 then return false end
    end

    -- Some builds only expose the label. Matching on text is locale-bound, so it
    -- is the fallback and not the primary test.
    if dd and UIDropDownMenu_GetText then
        local t = UIDropDownMenu_GetText(dd)
        if type(t) == "string" then
            t = t:lower()
            if t:find("item") then return true end
            if t:find("stack") then return false end
        end
    end

    if AuctionFrameAuctions and AuctionFrameAuctions.priceType then
        return AuctionFrameAuctions.priceType == 1
    end

    return false
end

NorgAHValue_PerItemMode = PerItemMode

local function CurrentDurationBlocks()
    for i = 1, 3 do
        local radio = _G["AuctionsDuration" .. i]
        if radio and radio:GetChecked() then return DURATION_BLOCKS[i] or 2 end
    end
    return 2   -- the default selection is 24 hours
end

local function Update()
    if not infoFS then return end

    local link, itemID = SellSlotItem()
    if not link or not itemID then
        lastSaid = nil
        lastLink = nil
        return
    end

    local _, _, quality = GetItemInfo(link)
    local _, _, count = GetAuctionSellItemInfo()
    count = count or 1

    local unit = BotUnitPrice(itemID, quality)
    if not unit then
        infoFS:SetText("|cff808080The bot does not buy this item -- price it yourself.|r")
        lastLink = link
        return
    end

    local total = unit * count

    -- Fill whatever the client will turn INTO that total. See PerItemMode.
    local perItem = PerItemMode()
    local fill = perItem and unit or total

    -- (!) Only fill the fields when the ITEM changes. Re-filling on every event
    -- would fight the player the moment they typed a different number, and
    -- NEW_AUCTION_UPDATE fires for duration and stack changes too.
    if link ~= lastLink then
        lastLink = link
        MoneyInputFrame_SetCopper(StartPrice, fill)
        MoneyInputFrame_SetCopper(BuyoutPrice, fill)
    end

    local sell = (NorgAHValue_Sell and NorgAHValue_Sell[itemID]) or 0
    local deposit = math.max(MIN_DEPOSIT,
        math.floor(DEPOSIT_MUL * sell * count * CurrentDurationBlocks()))
    local cut = math.floor(total * CUT_PCT / 100)
    local net = total - cut - deposit

    -- (!) ONE LINE. This used to be a two-line label with an embedded newline,
    -- which the chat frame does not split on -- and which, on the auction panel,
    -- overflowed the panel width on the second line and sat across the Stack Size
    -- rows on anything stackable.
    infoFS:SetText(string.format(
        "bot pays %s |cff808080(%s each x%d, filled %s)|r -- deposit %s, %d%% cut %s, you keep |cff%s%s|r",
        Money(total), Money(unit), count, perItem and "per item" or "per stack",
        Money(deposit), CUT_PCT, Money(cut),
        net > 0 and "00ff00" or "ff4040", Money(net)))
end

local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("NEW_AUCTION_UPDATE")
f:RegisterEvent("AUCTION_HOUSE_SHOW")
f:RegisterEvent("AUCTION_HOUSE_CLOSED")

f:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        -- (!) Blizzard_AuctionUI is LOAD-ON-DEMAND. Building the label at login
        -- would attach it to frames that do not exist yet, and it would silently
        -- never appear. Wait for the auction UI to actually load.
        if arg1 ~= "Blizzard_AuctionUI" then return end

        -- (!) NO LABEL ON THE AUCTION FRAME. There is no free space in that panel:
        -- anchored under the item button it lands across Stack Size and the
        -- deposit line, and every other anchor either collides with Price and
        -- Duration or drifts into the auction list, which is empty only until you
        -- have listings. Guessing pixels blind is what produced the overlap in the
        -- first place, so the explanation goes to the CHAT FRAME instead -- the
        -- price itself is already filled into the boxes, which is the actual job.
        --
        -- infoFS survives as an inert stub so the call sites below stay simple.
        infoFS = { SetText = function(_, t)
            if t and t ~= "" and t ~= lastSaid then
                lastSaid = t
                DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00NorgAHValue|r: " .. t)
            end
        end }
        return
    end

    if event == "AUCTION_HOUSE_CLOSED" then
        lastLink = nil
        lastSaid = nil
        return
    end

    -- The sell slot is not populated yet on the frame the event fires, so read it
    -- on the next one.
    --
    -- (!) The delay must be driven from a FRAME. A FontString is not a frame and
    -- has no SetScript, so hanging this off the label would throw the moment an
    -- item was dropped in the slot -- and only then, which is exactly the kind of
    -- error that gets shipped.
    if infoFS then
        pending = true
    end
end)

-- (!) SWITCHING THE DROPDOWN MUST RE-PRICE THE SLOT.
-- The price is filled when the ITEM changes, which is right -- re-filling on
-- every event would fight you the moment you typed your own number. But the
-- price mode is not part of the item, so flipping per stack -> per item leaves
-- the previous number in the box and the client then multiplies it by the stack
-- size. 900 becomes 1800 without a single keystroke, which is precisely the
-- failure this whole addon exists to prevent.
local lastMode
local waited = false
f:SetScript("OnUpdate", function(self)
    local mode = PerItemMode()
    if mode ~= lastMode then
        lastMode = mode
        -- Only when something is actually in the slot and already priced;
        -- otherwise this just arms the next fill, which happens anyway.
        if lastLink then
            lastLink = nil
            pending = true
        end
    end

    if not pending then return end
    if not waited then waited = true return end
    waited = false
    pending = false
    Update()
end)

SLASH_NORGAHPRICE1 = "/ahprice"
SlashCmdList["NORGAHPRICE"] = function(arg)
    if arg and arg:lower():find("mode") then
        local dd = PriceDropDown()
        local nm = dd and dd.GetName and dd:GetName() or "(not found)"
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00NorgAHValue|r v" .. NORGAHVALUE_VERSION ..
            " -- dropdown: " .. nm .. ", mode: " ..
            (PerItemMode() and "per item" or "per stack"))
        return
    end
    lastLink = nil    -- force a re-fill of whatever is in the slot
    Update()
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00NorgAHValue|r: re-priced the sell slot.")
end
