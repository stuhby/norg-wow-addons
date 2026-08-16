NorgQuest 1.13 -- points you at the nearest quest objective you can actually do
==============================================================================

INSTALL
  Copy the NorgQuest folder into
      World of Warcraft\Interface\AddOns\
  so that you end up with
      Interface\AddOns\NorgQuest\NorgQuest.toc

  Then FULLY RESTART the client. A new addon FOLDER is invisible to a 3.3.5a
  client until it starts up again -- /reload will not find it, and the addon
  simply will not appear in the list. /reload is fine for later updates that
  only change files already there.

  NorgNav is not required, but the two are designed to sit side by side.


WHY THIS INSTEAD OF QuestHelper
  QuestHelper is a client addon, so everything it knows it had to be told in
  advance: a shipped database of where things are, your progress guessed from
  quest log text, and no visibility into your bags at all. All three of the
  familiar annoyances follow from that -- it points at objectives you already
  finished, at ones you cannot start, and straight through hills.

  Here the SERVER answers, and it is not guessing:

    Your progress      read from your real quest-log counters and your bags
                       (including the bank), so a finished objective is never
                       offered.
    Where things are   read from the spawn tables the world is built from --
                       and for an escort or event NPC who is loaded nearby,
                       from where he is standing RIGHT NOW rather than from
                       where he spawned.
    How to get there   a real navmesh route, the same one the server's own
                       creatures walk, so the arrow goes round the hill and
                       into the cave mouth instead of through them.

  Measured against this server's quest database: 8,339 of 9,464 quests (88%)
  resolve to a real position.


COMMANDS
  /quest           track the nearest objective you can actually do
  /quest list      everything resolvable, nearest first
  /quest <text>    track the quest whose title matches
  /quest scan      ask the server again
  /quest off       stop
  /quest why       print what is being tracked and why
  /quest arrow     whether the arrow is aimed from YOUR position or the server's
  /quest help      this list

  /nq works as a short form. Drag the panel anywhere; it remembers.


WHERE THE ARROW IS AIMED FROM
  The server sends you your own position three times a second, which means it
  is up to a third of a second old -- a couple of yards on foot, several on a
  fast mount. Drawing the bearing from that point is what used to make the
  arrow wobble, and why it wobbled harder the faster you moved.

  It now takes your position from the client instead, and uses the server only
  for where to GO. It works that out for itself from the packets as you walk,
  so there is no table of zones to go stale and nothing to configure; until it
  has enough to be sure it simply behaves as it did before. /quest arrow says
  which of the two is in use.

  Two things it does everywhere, including where the client has no position to
  give: the arrow stops swinging as you arrive on the point it is aiming at,
  and it no longer redraws for turns too small to see.


WHO OWNS THE ARROW
  NorgQuest and NorgNav share one server-side router, so only one can steer at a
  time. They divide by map rather than negotiating: NorgNav owns instances,
  NorgQuest owns the open world. Inside a dungeon NorgQuest stops tracking on its
  own and leaves NorgNav to it.


WHAT THE WORDING MEANS
  Distance and route
    plain distance              a complete walkable route; that is how far you
                                will actually walk
    "long way"                  beyond the pathfinder's search horizon. The
                                arrow is correct and the route sharpens as you
                                close in.
    "straight line"             no walking route from where you stand -- across
                                water, or another continent
    "as close as walking gets"  there is no path all the way; heading to the
                                nearest reachable point

  The objective, in brackets after the quest name
    "kill X" / "loot from X"    a creature, named because the server knows which
                                one it sent you to
    "use X"                     a gameobject -- a chest, a lever, a bonfire
    "talk to X"                 an event step: a gossip option, a hand-in, or the
                                NPC whose escort you have to start
    "turn in to X"              everything is done; this is the hand-in
    "explore"                   a PLACE, not a person. There is nothing standing
                                there to interact with -- walk into it and the
                                objective completes on its own. No name is shown
                                because there is nobody to name.
    "go to"                     the server could not find the thing itself, so it
                                is sending you to the exact spot Blizzard's own
                                quest marker names. Nobody is standing there, so
                                there is no name -- but it IS one point, not a
                                region, so walk to it rather than sweeping around.
    "search this area"          the same map marker, but drawn as a REGION rather
                                than a single point. The arrow aims at the nearest
                                corner of it; expect to look around once you get
                                there. This is the vaguest answer the addon gives.

    Either of the last two may be followed by "-- <text>", which is the quest's
    own wording for the objective the server could not place. It is what you are
    looking for when you arrive. Many quests do not carry one, and then nothing
    is shown after the kind.


WHAT IT DELIBERATELY WILL NOT DO
  It does not plan a questing ORDER and it is not a levelling guide. That route
  planner is where most of QuestHelper's complexity and most of its crashes
  live. This answers one question -- where is the nearest thing I can actually
  do right now -- and answers it correctly.


WHERE IT CAN STILL BE WRONG -- READ THIS BEFORE TRUSTING AN ARROW
  Earlier versions of this file claimed the addon "stays silent rather than
  guessing" on the quests it cannot place. That was never true of the code, and
  believing it turns a wrong arrow into a wrong ANSWER, so here is what actually
  happens.

  It is silent only when it can find NOTHING AT ALL for a quest. That quest then
  vanishes from /quest and /quest list entirely -- if a quest you expected is
  missing, that is why, and it is not a bug you can see from the client. (One
  rarer case looks the same: an objective that IS placed but sits on a continent
  with no boat or zeppelin route from where you stand is dropped when you try to
  track it, so it can disappear from the list at the moment you pick it.)

  Otherwise it always offers its best available answer, and its LAST RESORT is to
  name the person who takes the quest in. So when the real next step is something
  the server cannot locate -- a scripted sequence, a spell that completes the
  quest, an escort whose NPC is not loaded near you -- you will be pointed at the
  TURN-IN NPC rather than at the objective. The arrow is honest about where that
  NPC is; it is not a promise that he will accept the quest yet.

  Two shapes to recognise:

    Escort quests   Before you start one, the arrow points at the NPC you have to
                    speak to -- correct. While the escort is running it follows
                    him live, but only while he is loaded near you and only if he
                    is an ordinary world spawn. For a SUMMONED escort it falls
                    back to the spawn row instead, which is where he set off from
                    and therefore behind you; and if his entry has no spawn row at
                    all, back to the turn-in NPC.
    Script quests   "Watch this happen", "cast this on that", quests finished by
                    a cutscene. If the trigger is not in a table the server can
                    read, you get the turn-in NPC instead, with no warning that
                    the answer changed kind.

  /quest why prints what the client currently believes -- what it is tracking,
  which kind, how far, and the next few candidates. That is the right thing to
  paste into a bug report, because "the arrow points somewhere wrong" cannot be
  checked from chat alone.
