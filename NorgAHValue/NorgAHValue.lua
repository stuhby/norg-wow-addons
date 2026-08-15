--[[----------------------------------------------------------------------------
  NorgAHValue -- show what the Norg auction-house bot will pay for an item.

  WHY A DATA TABLE
  3.3.5a's GetItemInfo() returns 10 values and does not include sell price
  (added in 4.0), so the bid cannot be computed from the client API alone.
  DataSell.lua / DataVendor.lua are generated server-side by
  gen-ahvalue-addon.sh straight out of the world database.

  THE FORMULA, mirroring AuctionHouseBot.cpp:
      bid = SellPrice * multiplier[quality]
      if the item is sold by a vendor: bid = min(bid, vendorCost)
  The cap keys on actually appearing in npc_vendor, not on BuyPrice > 0 -- most
  items carry a BuyPrice but are not purchasable anywhere. Without the cap any
  multiplier above 4 makes "buy from vendor, sell to bot" an infinite money
  loop, which is why the server caps it too.

  Vendor price is left exactly as Blizzard draws it; this only ADDS a line.
------------------------------------------------------------------------------]]

-- The label. Kept parallel to Blizzard's own "Sell Price:" so the two rows read
-- as siblings rather than one being an addon bolt-on. Change freely.
local LABEL = "AH Value:"

-- Deliberately NOT the plain white that Blizzard's own footer rows use. This is
-- added information, not a stock tooltip field, and being visually distinct from
-- "Sell Price:" is the point -- you want to spot it without reading. Operator
-- preference, kept on purpose; do not "fix" this to match SELL_PRICE.
local LABEL_R, LABEL_G, LABEL_B = 1.0, 0.82, 0.0

--- Format copper using the game's own gold/silver/copper coin icons.
---
--- GetCoinTextureString is Blizzard's own helper (it is what the money frame
--- and the auction house use), so the icons, sizing and spacing match the rest
--- of the UI for free and stay correct if the client is reskinned. The manual
--- fallback below only runs if the API is somehow absent, and uses the same
--- coin textures directly rather than letters.
local function Money(c)
    if not c or c <= 0 then return nil end

    if GetCoinTextureString then
        return GetCoinTextureString(c)
    end

    local g = math.floor(c / 10000)
    local s = math.floor((c % 10000) / 100)
    local k = c % 100
    local GOLD   = "|TInterface\\MoneyFrame\\UI-GoldIcon:12:12:2:0|t"
    local SILVER = "|TInterface\\MoneyFrame\\UI-SilverIcon:12:12:2:0|t"
    local COPPER = "|TInterface\\MoneyFrame\\UI-CopperIcon:12:12:2:0|t"

    local out = ""
    if g > 0 then out = out .. g .. GOLD .. " " end
    if s > 0 then out = out .. s .. SILVER .. " " end
    if k > 0 or out == "" then out = out .. k .. COPPER end
    return (out:gsub("%s+$", ""))
end

--- What the bot would bid for ONE of this item. nil if it would not bid.
local function BotBid(itemID, quality)
    local sell = NorgAHValue_Sell and NorgAHValue_Sell[itemID]
    if not sell or sell <= 0 then return nil end

    local mult = (NorgAHValue_Mult and NorgAHValue_Mult[quality]) or 1
    local bid = sell * mult

    -- Never above what a player could pay a vendor for the same goods.
    local cap = NorgAHValue_VendorCost and NorgAHValue_VendorCost[itemID]
    local capped = false
    if cap and cap > 0 and bid > cap then
        bid = cap
        capped = true
    end

    return bid, capped
end

--- Stack size under the cursor. Most item buttons in 3.3.5a (bags, bank,
--- merchant, and the auction browse/bid rows) name their count fontstring
--- "<button>Count", so this covers all of them without special-casing each UI.
--- Falls back to 1, which is the honest answer for a tooltip we cannot attribute.
local function StackCount()
    local focus = GetMouseFocus()
    if not focus or not focus.GetName then return 1 end

    local name = focus:GetName()
    if not name then return 1 end

    local fs = _G[name .. "Count"]
    if fs and fs.IsShown and fs:IsShown() and fs.GetText then
        local n = tonumber(fs:GetText())
        if n and n > 1 then return n end
    end

    return 1
end

local function AddLine(tt)
    -- OnTooltipSetItem can fire more than once for the same tooltip; without
    -- this guard the line stacks up every time the tooltip refreshes.
    if tt.norgAHDone then return end

    local _, link = tt:GetItem()
    if not link then return end

    local itemID = tonumber(link:match("item:(%d+)"))
    if not itemID then return end

    local _, _, quality = GetItemInfo(link)
    if not quality then return end

    local bid, capped = BotBid(itemID, quality)
    if not bid then return end

    tt.norgAHDone = true

    local count = StackCount()

    -- Suffix carries the stack total and the cap note; the money itself is drawn
    -- by the money frame, so this is only the trailing grey annotation.
    local suffix = ""
    if count > 1 then
        suffix = suffix .. "  |cff808080(" .. Money(bid * count) .. " for " .. count .. ")|r"
    end
    if capped then
        suffix = suffix .. "  |cff808080(vendor capped)|r"
    end

    -- Drawn with SetTooltipMoney, NOT AddLine.
    --
    -- Blizzard's "Sell Price:" row is not a text line -- it is a money FRAME
    -- attached at a fixed offset by this same function. A plain AddLine can
    -- therefore never align with it: the label padding and the coin start
    -- position are both owned by the money frame's own layout. Using the same
    -- call means the two rows line up exactly, in any locale and at any UI
    -- scale, because it is literally the same rendering path.
    --
    -- The trade-off is that SetTooltipMoney owns the label colour, so the gold
    -- highlight is applied via the prefix string instead of line colour args.
    if SetTooltipMoney then
        SetTooltipMoney(tt, bid, nil, "|cffffd100" .. LABEL .. "|r", suffix)
    else
        -- Only if the API is missing; alignment will not match, but it still shows.
        tt:AddLine(LABEL .. " " .. Money(bid) .. suffix, LABEL_R, LABEL_G, LABEL_B)
    end
    tt:Show()
end

local function ClearFlag(tt) tt.norgAHDone = nil end

-- Bags, bank, merchant, and the auction house all use GameTooltip.
GameTooltip:HookScript("OnTooltipSetItem", AddLine)
GameTooltip:HookScript("OnHide", ClearFlag)

-- Shift-clicked links in chat, and the AH's own link tooltip.
if ItemRefTooltip then
    ItemRefTooltip:HookScript("OnTooltipSetItem", AddLine)
    ItemRefTooltip:HookScript("OnHide", ClearFlag)
end

-- The auction house uses a separate comparison tooltip for the selected row.
--
-- (!) NO "loaded" LINE HERE. This handler used to print one of its own on
-- ADDON_LOADED, which meant NorgAHValue alone announced itself TWICE at login.
-- The single announcement -- version and item count together -- is the
-- PLAYER_LOGIN line at the top of AutoPrice.lua. Put nothing back here.
local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:SetScript("OnEvent", function(_, _, name)
    if name ~= "Blizzard_AuctionUI" then return end
    for _, tip in ipairs({ AuctionSellItemTooltip, ItemRefTooltip }) do
        if tip and tip.HookScript then
            tip:HookScript("OnTooltipSetItem", AddLine)
            tip:HookScript("OnHide", ClearFlag)
        end
    end
end)
