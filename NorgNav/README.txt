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
  /nav list        what is in here, what is down, and what you skipped
  /nav reset       forget every down/skipped mark and re-check with the server
  /nav off         stop
  /nav debug       show exactly what the server is sending
  /nav help        this list

  A boss you skip with /nav next stays skipped until you leave the instance or
  type /nav reset. It is listed as (skipped) rather than (down), because the
  two are different things and only one of them is your decision.

  Drag the arrow panel anywhere; it remembers where you put it.


WHAT THE COLOURS AND WORDING MEAN
  White, plain distance
      A complete walkable route. The number is how far you will walk.

  Amber, "straight line from here"
      You have walked as far as walking goes. The rest needs a swim, a drop, or
      another way in. The arrow is now a direct line.

  Amber, "mapped path ends short -- last stretch is on you"
      The server's map of walkable ground runs out before it reaches the boss.
      KEEP WALKING: this is usually a short gap inside the same room -- measured
      in Wailing Caverns, it ends 34 yards from Lord Serpentis and 52 from
      Verdan. It does NOT mean you cannot get there. It also covers the genuinely
      separated cases -- across the water in Blackfathom Deeps, between the
      disconnected wings of Scarlet Monastery, and anywhere the fight starts on a
      vehicle or a drake.

      (This entry used to be listed here as "no walking route", which is a string
      the addon has never printed and a meaning it deliberately avoids -- people
      read it as "you cannot get there" and gave up on bosses they could reach.)

  "take the front lift up to the top of Thunder Bluff" (or any other leg)
      The route needs something that is not walking, and the arrow is pointing at
      the thing you have to use rather than at the destination. Lifts are the case
      you will meet: a lift is a moving platform, so it is not part of the
      server's map of walkable ground, and the places one serves -- the Thunder
      Bluff mesas, for instance -- have no walking route to them at all.

      Walk to the arrow, ride it, and the line clears and the route carries on by
      itself. The distance shown while the line is up is the real walking distance
      to the boarding point, not to the boss.

  Grey arrow, "..." and "finding a route"
      The route has been requested and the server has not answered yet. The boss
      name is already the new one; the distance is deliberately blank rather than
      showing the previous boss's number, which would be a confident figure about
      somewhere you are no longer going.

      It clears the moment the server answers. If the request went missing
      entirely the addon gives the answer up for lost a couple of seconds later,
      says once that it got no answer, and falls back to asking which bosses are
      down. It says that once per silence, not once per route -- so if you ask
      for several routes while something is swallowing them, you get one line,
      not one each.

  Amber, "direct line, no map data here"
      Neither you nor the boss is standing on the navmesh. Platform fights like
      Malygos and the Lich King are permanently in this state, correctly.

  Red, "no route"
      Something unexpected. /nav debug and tell Norg.


SCRIPT-SPAWNED FINAL BOSSES
  57 of the 418 encounters this addon carries have no creature anywhere in the
  world until a script summons them. Mutanus the Devourer -- the LAST boss of
  Wailing Caverns -- is one, which is why clearing all seven listed bosses used
  to end with "all routable bosses down" while the real final fight was still
  ahead of you.

  Those now route to the EVENT TRIGGER instead, labelled "Start:" with a line
  explaining what happens there. For Wailing Caverns that is Naralex, which is
  exactly where Mutanus appears.

  54 of the 57 carry such a point. The other three are impossible rather than
  unknown: the Trial of the Crusader arena floor is a destructible gameobject
  and the navmesh has no polygons there at all, so Icehowl, Lord Jaraxxus and
  Eydis Darkbane cannot be routed to by any coordinate. Those three are listed
  with a note and no arrow rather than aimed at a guess -- an arrow pointing
  confidently at nothing is worse than no arrow. An encounter whose trigger
  location has not been verified by hand is not carried at all.

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
