NorgHearth 1.0 -- keep several hearthstone destinations and pick between them
=============================================================================

INSTALL
  Copy the NorgHearth folder into
      World of Warcraft\Interface\AddOns\
  so that you end up with
      Interface\AddOns\NorgHearth\NorgHearth.toc

  Then RESTART the client. 3.3.5a only scans the AddOns folder at launch, so a
  freshly copied addon is invisible to /reload -- "/hs does nothing" is nearly
  always this rather than a bug.

  Needs the Norg server module. It does nothing on any other server.


HOW TO USE IT
  1. Bind at an innkeeper exactly as you always have.
  2. /hs, type a name in the box, press Save.
  3. Repeat somewhere else -- up to 8 of them.
  4. /hs and click an entry to point your hearthstone there.
  5. Use the stone normally.

  The one marked green is where the stone currently takes you.


COMMANDS
  /hs              open or close the window
  /hs save <name>  remember your current bind under that name
  /hs use <n>      switch to saved bind <n>
  /hs del <n>      forget saved bind <n>
  /hs list         print the list to chat
  /hs help         this list

  /norghearth works as a long form. Drag the window anywhere; it remembers.


WHAT IT IS NOT
  It is not a teleport. Nothing here can create a bind -- SAVE only copies the
  one the server already holds for you, and the only way to get one of those is
  to bind at an innkeeper through normal play. There is deliberately no command
  that takes coordinates.

  It does not touch the hearthstone itself. No cast is intercepted, no cooldown
  is altered and no cooldown is shared: the stone keeps its ordinary cast bar
  and its ordinary 30 minutes, because it is the ordinary stone. All this does
  is move where the server thinks your bind is, which is the same thing an
  innkeeper does.

  Astral Recall and every other spell that teleports you "home" reads the same
  bind, so they all follow it.

  (!) SO DOES BEING SENT HOME BY THE SERVER. The bind is not only where the
  hearthstone goes: it is also where you are put down when the Dungeon Finder
  returns you, when a battleground or Wintergrasp ejects you, and if you ever
  fall out of the world. That is not new behaviour and it is not a bug -- it is
  what an innkeeper bind has always meant -- but it does mean switching your
  bind changes all of those too, not just the stone.


THINGS THAT LOOK LIKE BUGS AND ARE NOT
  "It says DUPNAME"          names are compared case-insensitively, so Dalaran
                             and dalaran are the same name. Rename or delete the
                             old one.
  "My name lost a character" only ordinary keyboard characters are kept. "|" and
                             ":" separate fields in the messages the addon and
                             server exchange, so they are removed.
  "Nothing happens at all"   if you are muted you cannot use it -- the commands
                             travel as a chat line to yourself, and the server
                             drops chat from a muted player before this module
                             ever sees it.
