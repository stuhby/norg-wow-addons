NorgQuest 1.0 -- points you at the nearest quest objective you can actually do
==============================================================================

INSTALL
  Copy the NorgQuest folder into
      World of Warcraft\Interface\AddOns\
  so that you end up with
      Interface\AddOns\NorgQuest\NorgQuest.toc

  Then restart the client (or /reload).

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
    Where things are   read from the spawn tables the world is built from.
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
  /quest help      this list

  /nq works as a short form. Drag the panel anywhere; it remembers.


WHO OWNS THE ARROW
  NorgQuest and NorgNav share one server-side router, so only one can steer at a
  time. They divide by map rather than negotiating: NorgNav owns instances,
  NorgQuest owns the open world. Inside a dungeon NorgQuest stops tracking on its
  own and leaves NorgNav to it.


WHAT THE WORDING MEANS
  plain distance                a complete walkable route; that is how far you
                                will actually walk
  "long way"                    beyond the pathfinder's search horizon. The
                                arrow is correct and the route sharpens as you
                                close in.
  "straight line"               no walking route from where you stand -- across
                                water, or another continent
  "as close as walking gets"    there is no path all the way; heading to the
                                nearest reachable point


WHAT IT DELIBERATELY WILL NOT DO
  It does not plan a questing ORDER and it is not a levelling guide. That route
  planner is where most of QuestHelper's complexity and most of its crashes
  live. This answers one question -- where is the nearest thing I can actually
  do right now -- and answers it correctly.

  It stays silent on the remaining 12% of quests rather than guessing. Those are
  mostly quests handed in to a script-spawned NPC, or objectives that are an
  exploration trigger rather than a place.
