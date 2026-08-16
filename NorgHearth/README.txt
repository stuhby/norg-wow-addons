NorgHearth 1.0 -- keep several hearthstone destinations and pick between them
=============================================================================

INSTALL
  Copy the NorgHearth folder into
      World of Warcraft\Interface\AddOns\
  so that you end up with
      Interface\AddOns\NorgHearth\NorgHearth.toc

  Then RESTART the client. 3.3.5a only scans the AddOns folder at launch, so a
  freshly copied addon is invisible to /reload -- rule that out before treating
  "/hs does nothing" as a bug.

  Needs the Norg server module. It does nothing on any other server.


HOW TO USE IT
  1. Bind at an innkeeper exactly as you always have.
  2. /hs, then press Save. There is nothing to type -- the entry is named after
     the place you are bound, so an inn in the Valley of Strength saves as
     "Orgrimmar".
  3. Repeat somewhere else -- up to 8 of them.
  4. /hs and click an entry to point your hearthstone there.
  5. Use the stone normally.

  The one marked green is where the stone currently takes you.


COMMANDS
  /hs              open or close the window
  /hs save         remember your current bind, named after the place
  /hs save <name>  the same, under a name you choose instead
  /hs use <n>      switch to saved bind <n>
  /hs del <n>      forget saved bind <n>
  /hs list         print the list to chat
  /hs help         this list

  /norghearth works as a long form. Drag the window anywhere; it remembers.


WHAT IT IS NOT
  It is not a teleport. Nothing here can create a bind -- SAVE copies the one
  the server already holds for you, which you get by binding at an innkeeper as
  always. There is deliberately no command that takes coordinates.

  It does not touch the hearthstone itself. No cast is intercepted, no cooldown
  is altered and no cooldown is shared: the stone keeps its ordinary cast bar
  and its ordinary cooldown, because it is the ordinary stone. All this does is
  move where the server thinks your bind is, which is the same thing an
  innkeeper does.

  Astral Recall and the other ways of being sent "home" read the same bind, so
  they follow it too.

  (!) SO DOES BEING SENT HOME BY THE SERVER. The bind is not only where the
  hearthstone goes: it is also where you are put down when the Dungeon Finder
  returns you, when a battleground or Wintergrasp ejects you, and if you ever
  fall out of the world. That is not new behaviour and it is not a bug -- it is
  what an innkeeper bind has always meant -- but it does mean switching your
  bind changes all of those too, not just the stone.


THINGS THAT LOOK LIKE BUGS AND ARE NOT
  A save is refused          the words on screen are "NorgHearth: you already
                             have a bind saved under that name." Entries are
                             named after where you are bound, so a save is
                             refused when a bind of that name is already on the
                             list -- usually because that city already is, but
                             not always: a handful of inns sit in places that
                             share a name, so two genuinely different innkeepers
                             can want the same entry. Give the second one a name
                             of your own with /hs save <name>. The entry you have
                             still points where it did: nothing is lost by the
                             refusal and nothing is overwritten. Names given
                             with /hs save <name> collide the same way, and are
                             compared case-insensitively, so Dalaran and dalaran
                             are the same name.
  "Nothing is green"         you are bound somewhere you have not saved yet.
                             Press Save to add it. The green mark reads the
                             server's live bind rather than the last thing you
                             clicked, so no mark genuinely means none of these.
                             The window re-reads that every few seconds while it
                             is open, so you can leave it up, bind at the
                             innkeeper and watch the mark move on its own.
  "My name lost a character" only ordinary keyboard characters are kept. "|" and
                             ":" separate fields in the messages the addon and
                             server exchange, so they are removed.
  "Nothing happens at all"   if you are muted you cannot use it -- the commands
                             travel as a chat line to yourself, and the server
                             drops chat from a muted player before this module
                             ever sees it.
