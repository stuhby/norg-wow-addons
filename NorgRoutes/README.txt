NorgRoutes
==========
Boss order and directions for every dungeon and raid on the Norg server.

INSTALL
  Copy the NorgRoutes folder into:
      World of Warcraft\Interface\AddOns\
  So you end up with:
      Interface\AddOns\NorgRoutes\NorgRoutes.toc
  Restart the client (or /reload).

USE
  It opens automatically when you enter an instance it recognises.
  /route                 toggle the window
  /route shadowfang      show a specific instance (case-insensitive, "The" optional)
  Drag to move; position is remembered.

WHAT IT SHOWS
  The bosses in encounter order, and for each one the compass direction and
  distance from the PREVIOUS boss. For example, in Wailing Caverns:
      1. Lady Anacondra          (first)
      2. Lord Cobrahn            -- SW, 204 yd
      3. Kresh                   -- NE, 129 yd

WHERE THE DATA COMES FROM
  Generated from the server's own database -- instance_encounters joined to
  actual creature spawn coordinates -- so it matches THIS server, not a wiki.
  69 instances, 492 bosses. Regenerate with:
      /mnt/user/appdata/wow-wotlk/gen-routes-addon.sh

LIMITS, STATED PLAINLY
  * Boss ORDER comes from the encounter table and is right for linear dungeons.
    Some instances branch (Maraudon, Dire Maul, Blackrock) and the listed order
    is then only a suggestion. The BEARINGS between bosses are always correct.
  * Directions are straight-line compass bearings, not pathing. A wall may be
    in the way; it tells you which way the boss is, not how to walk there.
  * This is NOT a map addon. Atlas does maps well and bundling its artwork would
    mean redistributing someone else's work -- install Atlas alongside this.
  * No live arrow. 3.3.5a cannot report your position inside classic dungeons,
    so an arrow needs a server-side component. This is the static version.
