NorgDungeons
============
Dungeon and raid maps with boss order and live kill tracking. Self-contained --
Atlas is NOT required.

INSTALL
  Copy the NorgDungeons folder into:
      World of Warcraft\Interface\AddOns\
  Restart the client (or /reload).

USE
  Opens automatically when you enter an instance.
  /dungeon              toggle
  /dungeon zulfarrak    show a specific map
  Drag to move; position is remembered.

READING IT
  The map is on the left, the legend on the right. Two different numbers:
      the plain number  = the marker painted on the map artwork (WHERE it is)
      the green [N]     = the boss order from the server        (WHAT to kill next)
  They often disagree, and that is correct. In Wailing Caverns the artwork paints
  Lord Cobrahn as 2 and Lady Anacondra as 3, but the server's encounter order
  makes Anacondra boss [1].

  Colours: gold = ordered boss, purple = rare spawn, grey = npc/vendor/quest,
  dimmed = already killed this run.

KILL TRACKING
  Bosses grey out as you kill them. Cleared when you enter a different instance,
  EXCEPT for saved raid lockouts -- those bosses stay dead server-side, so
  clearing them would lie to you on the way back in.

DATA
  Artwork and the marker legend come from Atlas. The boss list, encounter order
  and NPC names come from the Norg server database, and the server wins wherever
  they disagree. 101 maps, 922 entries, 409 ordered bosses.
  Regenerate with: /mnt/user/appdata/wow-wotlk/gen-dungeon-addon.sh

KNOWN GAPS, STATED PLAINLY
  * 14 maps have no ordered bosses -- mostly entrance maps (no bosses inside)
    plus Trial of the Champion and the Ulduar sub-map, where the server has no
    instance_encounters rows. Artwork and legend still work.
  * No live arrow. The client cannot report your position inside classic
    dungeons, so an arrow needs a server-side component.
