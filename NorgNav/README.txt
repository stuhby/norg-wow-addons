NorgNav 2.0 -- a live pathfinding arrow for dungeons and raids
==============================================================

INSTALL
  Copy the NorgNav folder into
      World of Warcraft\Interface\AddOns\
  so that you end up with
      Interface\AddOns\NorgNav\NorgNav.toc

  Then restart the client (or /reload).


WHAT IT DOES
  Walk into any dungeon or raid and an arrow appears pointing at the next boss
  you have not killed. It advances on its own as bosses die. Nothing to set up.

  The arrow points along a REAL WALKABLE ROUTE, not at the boss. It turns
  corners, takes ramps and goes through doorways, because the server runs the
  same navmesh pathfinding its own creatures use and sends your client the next
  corner of the route three times a second.

  The distance shown is the distance you will actually WALK when the server has
  a complete route. That is often nothing like the straight line -- in Wailing
  Caverns the straight line to Skum is 462 yards and the walk is 1,466.


COMMANDS
  /nav             resume automatic routing in encounter order
  /nav next        skip the current boss (behind a door, or you want another)
  /nav <name>      route to one boss and stay on it
  /nav list        what is in here, and what is already down
  /nav off         stop
  /nav debug       show exactly what the server is sending
  /nav help        this list

  Drag the arrow panel anywhere; it remembers where you put it.


WHAT THE COLOURS AND WORDING MEAN
  White, plain distance
      A complete walkable route. The number is how far you will walk.

  Amber, "straight line from here"
      You have walked as far as walking goes. The rest needs a swim, a drop, or
      another way in. The arrow is now a direct line.

  Amber, "no walking route"
      There is no walkable path to this boss from where you stand. The arrow is
      taking you as close as it gets. This is normal and correct in a handful of
      places -- across the water in Blackfathom Deeps, between the disconnected
      wings of Scarlet Monastery, and anywhere the fight starts on a vehicle or
      a drake.

  Amber, "direct line, no map data here"
      Neither you nor the boss is standing on the navmesh. Platform fights like
      Malygos and the Lich King are permanently in this state, correctly.

  Red, "no route"
      Something unexpected. /nav debug and tell Norg.


SCRIPT-SPAWNED FINAL BOSSES
  57 of the game's 434 encounters have no creature anywhere in the world until a
  script summons them. Mutanus the Devourer -- the LAST boss of Wailing Caverns --
  is one, which is why clearing all seven listed bosses used to end with "all
  routable bosses down" while the real final fight was still ahead of you.

  Those now route to the EVENT TRIGGER instead, labelled "Start:" with a line
  explaining what happens there. For Wailing Caverns that is Naralex, which is
  exactly where Mutanus appears.

  Only encounters with a hand-verified trigger location are included. The rest
  are still left out rather than guessed at -- an arrow pointing confidently at
  nothing is worse than no arrow.

  It cannot see door state. Navmeshes model geometry, not whether a gate happens
  to be shut or needs a key, so a route can lead you to a closed door. What it
  can prove is when no walkable route exists at all, and it says so.


HOW IT KNOWS WHERE YOU ARE
  It does not, and it cannot. The 3.3.5a client will not tell an addon where you
  are standing inside a classic dungeon. The server sends you your own position
  over an addon message. You only ever receive your own coordinates.


RELATED
  NorgDungeons -- map artwork and a boss checklist. Different approach to the
  same problem; run either or both, they do not conflict.

  48 of those 57 now have a verified approach point, derived from the server's
  own instance scripts and each one checked against the navmesh. The remaining
  nine are deliberately absent rather than guessed. Three of them are impossible
  rather than unknown: the Trial of the Crusader arena floor is a destructible
  gameobject and the navmesh has no polygons there at all, so Icehowl, Jaraxxus
  and Eydis Darkbane cannot be routed to by any coordinate.
