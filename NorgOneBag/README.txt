NorgOneBag
==========
All your bags in one window, using the stock 3.3.5a look and feel.

INSTALL
  Copy the NorgOneBag folder into:
      World of Warcraft\Interface\AddOns\
  So you end up with:
      Interface\AddOns\NorgOneBag\NorgOneBag.toc
  Restart the client (or /reload).

USE
  Opens wherever the normal bags would -- the bag bar, the B key, looting,
  visiting a merchant. Escape or the close button shuts it.
  /onebag  toggles it manually.
  Drag the window to move it; the position is remembered per character.

WHY IT BEHAVES LIKE THE REAL BAGS
  The item buttons are Blizzard's own ContainerFrameItemButtonTemplate, and each
  bag has a hidden holder frame whose ID is the bag number. Blizzard's handlers
  find the bag by reading that parent ID, so clicking, dragging, shift-splitting,
  right-click-to-equip, cooldowns and tooltips all run through the game's
  unmodified code rather than a reimplementation.

  That also means the AH tooltip addon (NorgAHValue) works here automatically.

NOT INCLUDED, ON PURPOSE
  No quality borders, no custom skin, no search box. Stock 3.3.5a bags have none
  of those, and the brief was to keep the default theme.

KNOWN LIMITS
  Bank bags are not merged (this covers the 5 carried bags only).
