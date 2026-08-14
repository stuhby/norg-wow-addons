NorgAHValue
===========
Adds an "AH Value:" line to item tooltips showing what the Norg auction-house
bot will pay for an item.
Blizzard's own "Sell Price" line is left untouched -- this only adds.

INSTALL
  Copy the NorgAHValue folder into:
      World of Warcraft\Interface\AddOns\
  So you end up with:
      Interface\AddOns\NorgAHValue\NorgAHValue.toc
  Restart the client (or /reload). You should see a green load message.

WHERE IT SHOWS
  Bags, bank, merchant windows, auction-house listings, and shift-clicked
  chat links. Per-item value, with the stack total in parentheses.

WHAT THE NUMBER MEANS
      bid = sell price x multiplier for that item's quality
      if the item is sold by a vendor: bid = min(bid, vendor cost)
  The vendor cap is why an item you can buy from a vendor never shows a
  profitable number -- the bot will not pay above retail.

  Current multipliers: poor 1x, common 3x, uncommon 5x, rare 12x, epic 15x,
  legendary 20x, artifact 22x (of the item's VENDOR SELL price, not buy price).

IF THE NUMBERS LOOK WRONG
  The multipliers are baked into Config.lua at generation time. If the server's
  buyer multipliers change, regenerate on the server with:
      /mnt/user/appdata/wow-wotlk/gen-ahvalue-addon.sh
  and redistribute. Item prices themselves are static game data and never
  need regenerating.

AUTO-PRICING THE SELL TAB (v1.1)
================================
  Drop an item into the Auctions sell slot and the Starting Price and Buyout
  fill in automatically at the most the Norg AH bot will actually pay, with the
  deposit and house cut worked out underneath.

  That price is a CEILING, not a suggestion. One copper over it and the bot
  will not buy, which on a bot-driven economy usually means the auction just
  expires and you lose the deposit.

  It only fills the fields when the ITEM changes, so if you type your own price
  it will not fight you. /ahprice re-fills the current slot.

  Fees: every auction on this server goes to the NEUTRAL auction house
  (AllowTwoSide.Interaction.Auction is on), which is normally 15%% cut and 5x
  the deposit. Norg scales both back to the usual faction rates in
  worldserver.conf, so it is 5%% cut and the normal deposit. If those config
  values ever change, the constants at the top of AutoPrice.lua must change too.
