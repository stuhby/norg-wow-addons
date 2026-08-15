--[[----------------------------------------------------------------------------
  NorgNav -- a live pathfinding arrow for dungeons and raids.

  ALTERNATIVE TO NorgDungeons, not a replacement. Run either or both; they do not
  conflict. NorgDungeons shows a map and a boss checklist. This points an arrow.

  HOW IT KNOWS WHERE YOU ARE
  It does not, and it cannot. The 3.3.5a client will not tell an addon where the
  player is standing inside a classic dungeon -- GetPlayerMapPosition() is
  map-relative and those instances have no world map at all. So the SERVER sends
  your position over an addon message (mod-norg-nav). You only ever receive your
  own coordinates.

  WHY THE ARROW IS TRUSTWORTHY ROUND CORNERS
  The server does not send a bearing to the boss. It runs Detour over the same
  navmesh its own creatures walk on and sends the next CORNER of a real walkable
  route. The arrow points up the ramp and through the doorway, not through a wall
  on a different floor. It also sends the real ROUTE length, which is frequently
  nothing like the straight-line distance -- in Wailing Caverns the straight line
  to Skum is 462 yards and the walk is 1,466.

  WHAT IT WILL TELL YOU RATHER THAN GUESS
  Navmeshes model geometry, not door state, so a route can pass through a gate
  that happens to be shut. What the server CAN prove is when no walkable route
  exists at all -- across water in Blackfathom Deeps, between the disconnected
  wings of Scarlet Monastery, onto a vehicle or a drake in Ulduar and the Oculus.
  In those cases the arrow walks you as far as walking goes and then switches to
  a straight line, and says which it is doing.
------------------------------------------------------------------------------]]

local PREFIX = "NORGNAV"

-- (!) THE VERSION IS READ FROM THE .toc, NEVER COPIED INTO A CONSTANT HERE. The
-- login line is step one of the wiki's troubleshooting page, and a second copy of
-- the number drifts from the .toc in silence, and nothing in the game can then
-- tell you which of the two you are reading. "?" means the client never indexed
-- this folder, which is itself the answer to "why is nothing happening".
local ADDON   = "NorgNav"   -- FOLDER name; GetAddOnMetadata keys on that
local VERSION = GetAddOnMetadata(ADDON, "Version") or "?"

-- Server statuses. See mod-norg-nav.
--   ok       complete walkable route; the route distance is exact
--   far      walkable prefix, goal past the search horizon (should not occur:
--            the module's own sweep of the 361 boss-to-boss legs at the shipped
--            budget returned none -- see NAV_NODE_POOL in norg_nav.cpp)
--   direct   walked as far as possible; the rest is a straight line
--   blocked  no walkable route to the goal; following the best partial one
--   bearing  no navmesh under you or the goal; straight line only
--   nopath   nothing at all
local COL_OK      = { 0.95, 0.95, 0.95 }
local COL_SOFT    = { 1.00, 0.82, 0.00 }
local COL_HARD    = { 1.00, 0.35, 0.35 }

local frame, arrow, nameFS, distFS, hintFS

local mapId                 -- server-supplied; never guessed from a zone name
local bosses = {}           -- NorgNavBosses[mapId]
-- (!) KEYED BY THE BOSS ENTRY ITSELF, NOT BY ITS SPAWN ID.
--
-- g=0 is a SHARED SENTINEL, not an id: 57 of the 418 entries are
-- script-spawned encounters with no creature to death-check, and twelve
-- instances carry two or more of them (four each in Hyjal Summit, Sunwell
-- Plateau and Trial of the Crusader). Keying this table by b.g therefore made
-- dead[0] = true mark EVERY such entry in the instance down at once, and
-- permanently -- AskAlive only ever asks about g > 0, so nothing could correct
-- it for the rest of the run and those bosses were silently skipped. Wailing
-- Caverns has exactly one g=0 entry, which is why testing never saw it.
--
-- The entry table is unique per boss by construction, so it cannot collide.
--
-- (!) `dead` MEANS ONE THING ONLY: THE BOSS IS DOWN.
-- It used to carry deliberate skips as well, and the two facts have opposite
-- lifetimes -- the alive poll is entitled to CLEAR a death mark (a boss that
-- evaded and hard-reset must not be skipped for the rest of the run), so a
-- skip stored here was un-skipped by the next A|1 and the arrow dragged the
-- player straight back to the boss they had just passed on. The poll is a
-- free-running 20-second accumulator that /nav next does not reset, so the
-- un-skip landed anywhere from instantly to twenty seconds later, and
-- script-spawned bosses are never polled at all -- so the same command
-- behaved differently depending on which boss it was aimed at, with nothing
-- on screen to explain why. Skips live in their own set and only SetMap (or
-- an explicit /nav reset) clears them.
local dead = {}             -- [boss entry] = true; the server or the combat log said so
local skipped = {}          -- [boss entry] = true; the PLAYER said so, via /nav next
local bySpawn = {}          -- [spawnId] = { entry, ... }; only ever g > 0
local target                -- { i, n, x, y, z, g }

-- (!) WHAT THE SERVER IS WATCHING, WHICH IS NOT WHAT IS ON SCREEN.
--
-- S|dead carries no id -- it means "the target you are subscribed to has
-- died" -- so the client has to know which boss the SERVER thinks that is.
-- Our own auto-advance runs ahead of it: the combat log marks the kill
-- instantly and we START the next boss, while the server only notices the
-- death on its next world update and only reports it on the next nav cadence
-- (NAV_INTERVAL_MS, norg_nav.cpp). Crediting whatever was current when the
-- report landed therefore marked the NEXT boss down.
--
-- The server installs a target and answers S|started in the same breath, and
-- a session's packets are ordered, so an S|dead can only ever refer to the
-- START that was acknowledged before it. Tracking the acknowledgement makes
-- the client's idea of the subscription lag its own advance by exactly as
-- much as the server does.
--
-- (!) A QUEUE POSITION IS ONLY AS GOOD AS ITS AGE -- ONE LOST REPLY POISONS
-- EVERY LATER KILL, FOREVER, AND NO DEPTH CHECK CAN SEE IT.
--
-- A START whisper can be swallowed before mod-norg-nav ever sees it:
-- ChatHandler.cpp drops the line at !CanSpeak() and again on the GM silence
-- aura, both BEFORE the hook, so no S|started is ever generated for it. The
-- pop is FIFO, so that one orphan sits at the head of the queue and every
-- LATER acknowledgement pops it instead of the boss it really refers to --
-- permanently one out of step, which credits S|dead to the previous boss for
-- the rest of the session. Reproduced: skip a boss whose acknowledgement was
-- lost, let the bots kill the next one, and the addon announces the SKIPPED
-- boss down while the one that actually died stays unmarked.
--
-- The queue depth cannot detect that -- it oscillates between one and two and
-- never reaches any threshold. AGE can: the reply is generated synchronously
-- by the same handler that reads the whisper, so nothing should ever be
-- outstanding for longer than one round trip. An entry older than
-- ACK_TIMEOUT is one whose reply is never coming, and the OnUpdate loop
-- retires it and drops `subscribed` -- which degrades S|dead to an ALIVE
-- query (slower, never wrong) instead of to a wrong mark.
local ACK_TIMEOUT = 2.0     -- seconds an unanswered START may sit in the queue
local startQ = {}           -- { { b = entry, age = seconds }, ... }, oldest first
local subscribed            -- the entry the server has acknowledged and is death-checking
local ackLost = false       -- latched so a mute warns once, not every route
local autoMode = true
local lastStatus = "ok"
local haveFix = false
local px, py, wx, wy = 0, 0, 0, 0
local routeYd, lineYd = 0, 0
-- The current LEG instruction, e.g. "take the front lift up to the top of
-- Thunder Bluff". Empty whenever the whole trip is a plain walk.
--
-- (!) THIS EXISTS BECAUSE AN ARROW ALONE CANNOT EXPRESS A LIFT. The route to a
-- Thunder Bluff mesa is a walk to the boarding deck and then a ride, and the
-- arrow for the first half points at the deck -- which, without a caption,
-- reads as the arrow simply stopping short of where you asked to go.
local legText = ""
local saidAllDone = false   -- so the all-clear is announced once, not every poll
local whereRetry = 0
local aliveRetry = 0

-- Control channel to the server module.
--
-- (!) WHISPER TO SELF, not SAY. The server swallows the line before it reaches
-- chat, but only while mod-norg-nav is loaded. If the module is ever missing or
-- fails to load, a SAY would broadcast "NORGNAV START -100 300 -90" to everyone
-- standing nearby, three times a second. Whispering yourself means the worst case
-- is a line only you can see.
local function Send(cmd)
    local me = UnitName and UnitName("player")
    if me then
        SendChatMessage("NORGNAV " .. cmd, "WHISPER", nil, me)
    end
end

local function Say(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99NorgNav|r: " .. msg)
end

-- ---------------------------------------------------------------------- arrow

--- (!) Texture:SetRotation DOES NOT EXIST in 3.3.5a -- it arrived in 4.0.
--- Rotating has to be done by transforming the four texture corners with
--- SetTexCoord's 8-argument form. Calling SetRotation behind a nil-guard looks
--- safe and is worse than a crash: the arrow renders perfectly and simply never
--- turns, so it points north forever and you would trust it.
---
--- (!) THIS ROTATES COUNTERCLOCKWISE by the given angle. That is not obvious --
--- SetTexCoord moves the SAMPLING coordinates, so the image turns the opposite
--- way, and texture v runs downward while screen y runs up, which flips it back.
--- Two cancelling sign errors. Verified rather than assumed, by tracking where
--- the arrow tip (texture coord 0.5,0) lands: +90 degrees puts it on the quad's
--- left edge, so positive is counterclockwise.
local function RotateTexture(tex, angle)
    local c, s = math.cos(angle), math.sin(angle)
    local function rot(x, y)
        x, y = x - 0.5, y - 0.5
        return 0.5 + (x * c - y * s), 0.5 + (x * s + y * c)
    end
    local ulx, uly = rot(0, 0)
    local llx, lly = rot(0, 1)
    local urx, ury = rot(1, 0)
    local lrx, lry = rot(1, 1)
    tex:SetTexCoord(ulx, uly, llx, lly, urx, ury, lrx, lry)
end

--- (!) WORLD ANGLE IS atan2(dy, dx) -- NOT atan2(-dy, dx).
---
--- WoW world coordinates put +X to the NORTH and +Y to the WEST, and the core
--- moves things with `x += dist*cos(angle); y += dist*sin(angle)` (Object.cpp),
--- so an angle of 0 faces north and it increases toward west. GetPlayerFacing()
--- returns a value in that same convention, so the heading to a point is simply
--- atan2(dy, dx) and the arrow angle is that minus the player's facing.
---
--- Negating dy MIRRORS the arrow left-to-right. It still swings around
--- convincingly as you turn, and it is still correct when the target is directly
--- ahead or directly behind, so it looks like a working arrow that keeps sending
--- you into walls -- which is exactly how it presented before this was fixed.
local function Bearing(dx, dy)
    return math.atan2(dy, dx)
end

local function Cardinal(dx, dy)
    -- +X north, +Y west. Sixteen points is more precision than anyone needs;
    -- eight is enough to sanity-check against the minimap.
    local a = math.deg(math.atan2(dy, dx)) % 360
    local names = { "N", "NW", "W", "SW", "S", "SE", "E", "NE" }
    return names[math.floor((a + 22.5) / 45) % 8 + 1]
end

-- ------------------------------------------------------------------- display

--- The panel's title line for one entry.
---
--- (!) An APPROACH entry is not the boss -- it is the place the encounter
--- starts. Labelling it plainly would send the player looking for a mob that
--- does not exist yet and make the arrow look wrong when they arrive to an
--- empty room.
---
--- Shared by every writer of that line so they cannot drift: it is written
--- from three places now (a live repaint, the moment a route is requested, and
--- an entry that cannot be routed to at all) and two of them are states the
--- player only ever sees for a fraction of a second, so a difference between
--- them would be nearly impossible to spot on screen.
local function SetNameLabel(b)
    local total = #bosses
    if total > 0 and b.i then
        nameFS:SetText(string.format("%s%s  |cff808080(%d of %d)|r",
            b.ap and "|cffffd100Start:|r " or "", b.n, b.i, total))
    else
        nameFS:SetText(b.n)
    end
end

local function Refresh()
    if not target or not haveFix then return end

    local dx, dy = wx - px, wy - py           -- to the next corner
    local rel = Bearing(dx, dy) - (GetPlayerFacing and GetPlayerFacing() or 0)
    RotateTexture(arrow, rel)

    -- Distance: the real route when the server has a complete one, otherwise the
    -- straight line marked as an approximation. Showing a straight line as though
    -- it were the distance to walk is not a rounding error -- it is wrong by a
    -- factor of three in the worst measured case.
    local col, hint = COL_OK, nil
    if lastStatus == "ok" then
        distFS:SetText(routeYd .. " yd")
    elseif lastStatus == "far" then
        distFS:SetText("~" .. lineYd .. " yd")
        hint = "routing as far as I can see"
    elseif lastStatus == "direct" then
        distFS:SetText("~" .. lineYd .. " yd")
        col = COL_SOFT
        hint = "straight line from here -- swim, drop, or round the corner"
    elseif lastStatus == "blocked" then
        -- (!) DO NOT SAY "no walking route". It reads as "you cannot get there",
        -- which is wrong and makes people give up on a boss they can reach.
        -- What it actually means is that the last stretch is missing from the
        -- server s navmesh -- measured in Wailing Caverns, the walkable route
        -- stops 34 yards from Lord Serpentis and 52 from Verdan, both inside the
        -- same chamber. Say how far the unmapped part is and keep walking them in.
        distFS:SetText(routeYd .. " yd")
        col = COL_SOFT
        hint = "mapped path ends short -- last stretch is on you"
    elseif lastStatus == "bearing" then
        distFS:SetText("~" .. lineYd .. " yd")
        col = COL_SOFT
        hint = "direct line, no map data here"
    else
        distFS:SetText("~" .. lineYd .. " yd")
        col = COL_HARD
        hint = "no route"
    end

    arrow:SetVertexColor(col[1], col[2], col[3])

    SetNameLabel(target)

    -- The approach note explains why you are being sent somewhere the boss is
    -- not, so it matters more than any routing status and takes precedence.
    if target.ap then
        hint = target.t ~= "" and target.t or "walk here to trigger the encounter"
    end

    -- (!) A LEG OUTRANKS EVERYTHING ELSE ON THIS LINE, including the approach
    -- note. Both explain why the arrow is not pointing at the destination, but
    -- only one of them is an instruction: the approach note describes the last
    -- few yards, the leg is the thing you have to do NEXT and stops being true
    -- the moment you have done it. Showing the note instead would leave the
    -- player standing on the boarding deck reading about the boss's room.
    if legText ~= "" then
        hint = legText
    end

    hintFS:SetText(hint or "")
end

-- ------------------------------------------------------------------- routing

local function StopNav(silent)
    target = nil
    haveFix = false
    legText = ""
    Send("STOP")
    if frame then frame:Hide() end
    if not silent then Say("stopped. /nav to resume.") end
end

--- (!) SOME ENTRIES CANNOT BE ROUTED TO AT ALL, AND MUST NOT BE FAKED.
---
--- nr=1 marks an encounter fought where there is no navmesh and no usable
--- coordinate. The three Trial of the Crusader arena bosses stand on a
--- destructible gameobject floor with no polygons under it, so their entries
--- carry x=y=z=0 -- and those zeros are WORLD ORIGIN, so routing to them aimed
--- the arrow confidently at the middle of the map. That is exactly the failure
--- the README rules out: an arrow pointing confidently at nothing is worse than
--- no arrow. Show the note, and no arrow.
local function ShowUnroutable(b)
    -- Drop any live subscription first. The server keeps ONE target slot per
    -- player and this entry will never occupy it, so a stream left running would
    -- go on pushing P| for a boss that is no longer on screen.
    --
    -- Nothing would be MIS-ATTRIBUTED by leaving it: the P| handler discards
    -- packets while an nr=1 entry is up, and an S|dead is credited to
    -- `subscribed` -- still that other boss -- rather than to this entry. This
    -- is about the server not computing routes nobody is looking at.
    if target then Send("STOP") end
    target = b
    haveFix = false

    if frame then
        arrow:Hide()
        distFS:SetText("no route")
        SetNameLabel(b)
        hintFS:SetText((b.t and b.t ~= "") and b.t
            or "no map data here -- stay with the group")
        frame:Show()
    end
end

local function StartNav(b)
    -- (!) CLEAR THE LEG BEFORE THE BRANCH, not after it. A leg belongs to the
    -- route that was running, and this one is over; leaving it set would caption
    -- the NEXT route with the previous route lift instruction until the server
    -- happened to send a different one.
    legText = ""
    if b.nr then
        ShowUnroutable(b)
        return
    end
    target = b
    haveFix = false
    -- The trailing spawn id lets the SERVER notice the boss dying and tell us,
    -- which is the only thing that catches a kill we did not witness -- the bots
    -- routinely clear ahead of the player, and anything before you zoned in is
    -- invisible to the combat log entirely.
    -- Two ids, and they are NOT the same thing.
    --   g  = the spawn to DEATH-CHECK. 0 for an event trigger, which never dies.
    --   tg = the spawn to FOLLOW LIVE. Set only for triggers that walk; Naralex
    --        is a SmartAI escort with three waypoints, so his spawn coordinate is
    --        only right until the event starts and the arrow would then point at
    --        the floor he left.
    Send(string.format("START %.2f %.2f %.2f %d %d", b.x, b.y, b.z, b.g or 0, b.tg or 0))
    -- Queued, not assigned: the server has not installed this target yet, and
    -- until it says so a death report still belongs to the PREVIOUS one. The
    -- S|started acknowledgement is what moves it across -- see `subscribed`.
    table.insert(startQ, { b = b, age = 0 })
    -- (!) THIS ONLY CATCHES A FLOOD, NOT THE DRIFT THAT ACTUALLY HAPPENS.
    -- Every START gets exactly one reply, so a queue this deep means many
    -- replies in a row went missing. The realistic failure is ONE lost reply,
    -- which leaves the queue permanently ONE deep and never trips any depth
    -- threshold at all -- the age timeout in OnUpdate is what catches that, and
    -- this is just a cheap bound on a burst of /nav commands. Both give up the
    -- same way, because a MISSED death is repaired by the alive poll and a
    -- MIS-CREDITED one is not.
    if #startQ > 8 then
        startQ = {}
        subscribed = nil
    end
    if frame then
        arrow:Show()   -- an nr=1 entry hides it, so put it back
        -- (!) REPAINT THE PANEL NOW, DO NOT LEAVE THE OLD BOSS'S NUMBERS UP.
        -- Refresh only runs once a position packet has landed, so between the
        -- request and the first P| the panel kept the PREVIOUS route's name,
        -- distance and hint -- a live-looking readout for a boss we had already
        -- left. Name the new one immediately and say plainly that the distance
        -- is not known yet; the arrow is dimmed for the same reason, since it
        -- is still pointing at the old route's corner until the stream catches
        -- up. Refresh sets the colour on every repaint, so this undoes itself.
        SetNameLabel(b)
        distFS:SetText("...")
        hintFS:SetText("finding a route")
        arrow:SetVertexColor(0.5, 0.5, 0.5)
        frame:Show()
    end
end

local function CountDead()
    local n = 0
    for _, b in ipairs(bosses) do if dead[b] then n = n + 1 end end
    return n
end

-- (!) SKIPPED *AND STILL ALIVE*, because a boss can be in BOTH sets: skip one
-- and the bots kill it anyway. Counting the raw set made "%d down, %d skipped"
-- add up to MORE than the number of bosses in the instance -- the same
-- double-count CountRemaining is written the way it is to avoid, arrived at
-- from the other direction. It is also the more useful number: `dead` wins on
-- screen (/nav list prints one that is both as "(down)"), and /nav reset can
-- only really bring back a skip that is not also a corpse.
local function CountSkipped()
    local n = 0
    for _, b in ipairs(bosses) do
        if skipped[b] and not dead[b] then n = n + 1 end
    end
    return n
end

-- (!) COUNT IT, DO NOT SUBTRACT IT. A boss can be BOTH skipped and dead (skip
-- one, the bots kill it anyway), so #bosses - dead - skipped double-counts and
-- can go negative -- and this number is printed to the player as "N left".
-- With CountSkipped above excluding the dead, these three now partition the
-- instance exactly: CountDead + CountSkipped + CountRemaining == #bosses.
local function CountRemaining()
    local n = 0
    for _, b in ipairs(bosses) do
        if not dead[b] and not skipped[b] then n = n + 1 end
    end
    return n
end

local function NextBoss()
    for _, b in ipairs(bosses) do
        if not dead[b] and not skipped[b] then return b end
    end
    return nil
end

local function AutoRoute()
    if not autoMode then return end

    if #bosses == 0 then
        if frame then frame:Hide() end
        return
    end

    local b = NextBoss()
    if b then
        -- (!) COMPARE THE ENTRY, NOT ITS SPAWN ID. Two g=0 entries in the same
        -- instance compare EQUAL on b.g, so advancing from one script-spawned
        -- encounter to the next looked like "already routing there" and started
        -- nothing at all.
        if target ~= b then
            StartNav(b)
            Say("next -- " .. b.n)
        end
    else
        StopNav(true)
        -- (!) SAY THIS ONCE PER INSTANCE, NOT ONCE PER CHECK.
        -- The 20-second alive poll re-enters AutoRoute whenever there is no
        -- current target, which is permanently true once everything is dead --
        -- so an unguarded message here reprints itself forever.
        if not saidAllDone then
            saidAllDone = true
            local ns = CountSkipped()
            if ns > 0 then
                -- Say WHY there is nothing left when part of it was the player's
                -- own doing, and name the way back. "Everything is down" over a
                -- boss they deliberately walked past reads as a lost kill.
                Say(string.format("nothing left to route to -- %d down, %d skipped. /nav reset brings the skipped ones back.",
                    CountDead(), ns))
            else
                Say("every routable boss here is down.")
            end
        end
    end
end

--- The current target is finished: killed, or the server said so.
---
--- (!) MANUAL MODE HAS NOTHING TO ADVANCE TO, SO IT MUST TAKE THE PANEL DOWN.
--- /nav <name> sets autoMode = false, and AutoRoute returns immediately while
--- it is off -- so nothing hid the frame when the chosen boss died. It sat
--- there showing that boss's name over the yard count from the last packet,
--- reading as a live route to a corpse, and the server had already dropped the
--- subscription so no packet was ever coming to correct it.
local function TargetFinished()
    target = nil
    haveFix = false
    if autoMode then
        AutoRoute()
    else
        StopNav(true)
        Say("/nav to resume automatic routing in encounter order.")
    end
end

--- Returns whether a query actually went out: there is nothing to ask when no
--- entry has a death-checkable spawn, and SetMap has to know that.
local function AskAlive()
    if #bosses == 0 then return false end
    local ids = {}
    for _, b in ipairs(bosses) do
        if b.g and b.g > 0 then ids[#ids + 1] = tostring(b.g) end
    end
    if #ids == 0 then return false end
    Send("ALIVE " .. table.concat(ids, ","))
    return true
end

local function SetMap(id)
    if id == mapId then return end
    mapId = id
    bosses = (NorgNavBosses or {})[id] or {}
    dead = {}
    -- (!) THE ONLY PLACE A SKIP IS CLEARED (bar an explicit /nav reset). A skip
    -- is a decision about THIS run of THIS instance, so it has to outlive every
    -- alive poll and survive right up to the point the player leaves.
    skipped = {}
    target = nil
    -- Nothing the old map's server subscription might still report can belong to
    -- a boss on this one.
    startQ = {}
    subscribed = nil
    ackLost = false
    saidAllDone = false

    -- Spawn id -> the entries using it, so an A| reply can mark the right ones
    -- now that `dead` is keyed by the entry rather than by the id.
    bySpawn = {}
    for _, b in ipairs(bosses) do
        if b.g and b.g > 0 then
            bySpawn[b.g] = bySpawn[b.g] or {}
            table.insert(bySpawn[b.g], b)
        end
    end

    if #bosses == 0 then
        if frame then frame:Hide() end
        return
    end

    Say(string.format("%s -- %d bosses.", (NorgNavMapNames or {})[id] or ("map " .. id), #bosses))
    -- Ask which are already down BEFORE routing, so we do not send the player
    -- across the instance to a corpse and then immediately turn them round.
    --
    -- (!) BUT ROUTE ANYWAY WHEN THERE IS NOTHING TO ASK ABOUT. Routing used to
    -- be started only by the A| reply, and AskAlive sends nothing at all when no
    -- entry has a death-checkable spawn. Four instances are entirely
    -- script-spawned -- Black Morass, Old Hillsbrad, Culling of Stratholme and
    -- Trial of the Crusader -- so the addon announced the boss count and then did
    -- nothing, forever, with no error anywhere to explain it.
    if AskAlive() then
        aliveRetry = 2.0
    else
        AutoRoute()
    end
end

-- ------------------------------------------------------------- server replies

local function OnAddonMessage(msg)
    local kind = msg:match("^(%a)|") or msg:match("^(%a)$")

    if kind == "P" then
        -- P|px|py|wx|wy|routeYd|lineYd|status
        local a, b, c, d, e, f, st =
            msg:match("^P|([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)|(%a+)$")
        if not a then return end
        -- (!) An nr=1 entry has no subscription, so a P| arriving while one is on
        -- screen is a stale packet from the route it replaced. Letting it set
        -- haveFix would repaint an arrow over guidance that says there is none.
        if target and target.nr then return end
        -- (!) A P| CARRIES NO ID EITHER, so the same attribution problem S|dead
        -- has applies here -- and the answer is the same acknowledgement.
        --
        -- A START the server has not acknowledged is one it has not installed,
        -- so it is still streaming whatever it was routing to before: the reply
        -- is written by the same handler that installs the target, and the
        -- session's packets are ordered. A P| arriving now is therefore not
        -- about the boss whose name is on screen. Painting it anyway put the
        -- PREVIOUS boss's distance and routing status under the NEW boss's name
        -- after an auto-advance -- a confident number about a different boss.
        --
        -- (!) THAT REASONING COVERS A START THE SERVER RECEIVED. One swallowed
        -- on the way is never acknowledged at all, so the queue does not drain
        -- on its own and the stream would stay dark for good; the age timeout in
        -- OnUpdate is what ends that. So the blackout is bounded, but not by a
        -- flat ACK_TIMEOUT: ages only advance while frames are drawn, and every
        -- further START queued meanwhile pushes the drain out. The worst case is
        -- ACK_TIMEOUT of drawn time after the LAST unanswered START.
        if #startQ > 0 then return end
        px, py = tonumber(a) or 0, tonumber(b) or 0
        wx, wy = tonumber(c) or 0, tonumber(d) or 0
        routeYd, lineYd = tonumber(e) or 0, tonumber(f) or 0
        lastStatus = st
        haveFix = true
        Refresh()
        return
    end

    if kind == "L" then
        -- L|<text>, and a BARE "L|" is a clear, not a malformed packet.
        --
        -- (!) THE CLEAR IS THE HALF THAT MATTERS. The server only transmits this
        -- line when it changes, so the transition from "take the front lift up
        -- to the top of Thunder Bluff" back to plain walking arrives as an empty
        -- payload. Treating that as junk and returning early would leave the
        -- instruction on screen for the rest of the run, telling the player to
        -- board a lift they are already standing on top of.
        legText = msg:match("^L|(.*)$") or ""
        Refresh()
        return
    end

    if kind == "M" then
        local id = tonumber(msg:match("^M|(%d+)"))
        whereRetry = 0
        if id then SetMap(id) end
        return
    end

    if kind == "A" then
        -- A|<spawn>:<1|0|?>|...
        --
        -- (!) Only '0' marks a boss down. '?' means the creature is not loaded in
        -- the grid, which is the NORMAL answer for anything on the far side of an
        -- instance -- treating it as dead would silently skip the player past
        -- every encounter they have not walked up to yet.
        aliveRetry = 0
        -- (!) A REPLY MUST BE ABLE TO CLEAR A MARK, NOT ONLY SET ONE.
        -- The first version only ever set dead[id] = true, so any false mark --
        -- a boss that evaded and hard-reset, a mis-parsed combat log line -- was
        -- permanent for the whole instance and silently skipped an encounter.
        -- '1' is the server saying it is definitely alive, so it is safe to trust.
        -- '?' means the creature simply is not loaded in the grid, which is the
        -- normal answer for anything across the instance, so it changes nothing.
        local changed = false
        for id, state in msg:gmatch("(%d+):([10%?])") do
            for _, b in ipairs(bySpawn[tonumber(id)] or {}) do
                if state == "0" and not dead[b] then
                    dead[b] = true
                    changed = true
                elseif state == "1" and dead[b] then
                    dead[b] = nil
                    changed = true
                    saidAllDone = false
                end
            end
        end
        if changed or not target then AutoRoute() end
        return
    end

    if kind == "S" then
        -- (!) HANDLE EVERY S|<word>, NOT ONLY THE TWO WE EXPECT.
        --
        -- The server sends S|stopped to the PREVIOUS owner of the single
        -- per-player target slot whenever NorgQuest takes it, and S|badargs when
        -- it rejects a START. Both used to fall straight through this block,
        -- which left `target` and `haveFix` set with no P| stream behind them:
        -- OnUpdate went on calling Refresh() twenty times a second, so the arrow
        -- kept counter-rotating against live facing while pinned to a position
        -- that would never update again -- a dead route that looks alive. It
        -- never recovered either, because the 20-second poll only re-routes on
        -- `changed or not target` and target was still set. NorgQuest matches any
        -- word for exactly this reason.
        local state = msg:match("^S|(%a+)")
        if not state then return end

        if state == "dead" then
            -- (!) CREDIT THE BOSS THE SERVER WAS WATCHING, NOT THE ONE ON SCREEN.
            --
            -- This used to mark `target` down, which is wrong on any kill we
            -- advanced past ourselves first. The combat log advances us the
            -- instant the boss dies; the server notices on its next world update
            -- and reports on the next nav cadence (NAV_INTERVAL_MS,
            -- norg_nav.cpp), by which time `target` is the NEXT boss.
            --
            -- (!) NOTHING HERE COUNTS HOW OFTEN THAT ORDERING WINS, so do not
            -- write a frequency into this comment -- two earlier versions did
            -- and both were wrong. The ordering is what matters: when the report
            -- loses the race, the mark lands on the wrong boss.
            --
            -- It was also unrepairable: the falsely marked boss is across the
            -- instance and unloaded, so the 20-second alive poll gets '?' back
            -- and clears nothing. Reproduced in Wailing Caverns -- kill Verdan,
            -- and the addon announces Mutanus down, then "every routable boss
            -- here is down" with the final fight still ahead.
            --
            -- `subscribed` is the last START the server ACKNOWLEDGED, so it is
            -- exactly what the server was death-checking when it sent this.
            local b = subscribed
            subscribed = nil              -- the server drops the subscription with this
            if not b then
                -- Nothing acknowledged to attribute this to: an nr=1 entry (which
                -- never had a subscription of its own), or a lost acknowledgement.
                -- Marking SOMETHING would be a guess, and a wrong mark is what
                -- this whole block exists to prevent -- so ASK instead. The A|
                -- reply names every boss the server can see is dead, and the one
                -- that just died is by definition loaded.
                AskAlive()
                aliveRetry = 2.0
                return
            end

            if not dead[b] then
                dead[b] = true
                Say(b.n .. " is down. |cff808080(" .. CountRemaining() .. " left)|r")
            end
            -- Only the boss ON SCREEN finishing needs the panel dealt with. When
            -- the report is for one we already walked away from, the live route
            -- must be left strictly alone.
            if target == b then
                TargetFinished()
            elseif not target then
                AutoRoute()
            end
        elseif state == "leftmap" then
            target = nil
            haveFix = false
            subscribed = nil
            if frame then frame:Hide() end
        elseif state == "started" then
            -- The acknowledgement of our OWN START. The subscription we just
            -- asked for is live, so there is nothing to undo here -- clearing
            -- would cancel every route the instant it began.
            --
            -- It is also the ONLY moment we learn that the server has moved on to
            -- the next boss, which is what keeps S|dead attributable. FIFO
            -- because the server installs targets in the order it receives them.
            --
            -- (!) The pop can come back nil -- the age timeout may have already
            -- retired this entry, or a stale reply may outlive a map change.
            -- Leaving `subscribed` nil there is the safe answer: the next
            -- S|dead asks the server rather than crediting a guess.
            local q = table.remove(startQ, 1)
            subscribed = q and q.b
            ackLost = false   -- the channel is working again, so warn again if it stops
        elseif state == "stopped" then
            -- The server erased the target slot, so it is watching nothing on our
            -- behalf and any later S|dead cannot be ours to credit.
            subscribed = nil
            -- Either the echo of a STOP we sent -- target is already nil by then,
            -- so this does nothing -- or NorgQuest taking the slot from under us.
            --
            -- (!) An nr=1 entry has no subscription of its own; ShowUnroutable
            -- sends a STOP purely to clear the previous one, so a stopped landing
            -- while one is on screen is that echo and must NOT wipe its guidance.
            if target and not target.nr then
                target = nil
                haveFix = false
                if frame then frame:Hide() end
                -- (!) Stop auto-advancing as well. The 20-second poll re-enters
                -- AutoRoute whenever there is no target, so leaving auto on would
                -- grab the slot straight back and the two addons would fight over
                -- it for as long as both were running.
                autoMode = false
                Say("another addon took the arrow. /nav to take it back.")
            end
        else
            -- "badargs", or any word a later module adds. Nothing is streaming
            -- whatever the word meant, so an arrow left up is frozen.
            --
            -- badargs is the OTHER possible reply to a START, so it has to
            -- consume the same queue slot S|started would have -- but only that
            -- one word, because a future word is not a START reply and popping
            -- for it would put every later acknowledgement one boss out of step.
            if state == "badargs" then table.remove(startQ, 1) end
            if target then
                target = nil
                haveFix = false
                if frame then frame:Hide() end
                Say("the server would not route that (" .. state .. ").")
            end
        end
        return
    end
end

-- ---------------------------------------------------------------------- frame

local function Build()
    local f = CreateFrame("Frame", "NorgNavFrame", UIParent)
    f:SetWidth(230)
    f:SetHeight(150)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 170)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local p, _, rp, x, y = self:GetPoint()
        NorgNavDB = NorgNavDB or {}
        NorgNavDB.pos = { p, rp, x, y }
    end)

    arrow = f:CreateTexture(nil, "OVERLAY")
    arrow:SetTexture("Interface\\Minimap\\MinimapArrow")
    arrow:SetWidth(52)
    arrow:SetHeight(52)
    arrow:SetPoint("TOP", f, "TOP", 0, -4)

    -- Distance is the number you glance at mid-pull, so it gets the large font
    -- and sits directly under the arrow. Name and hint are read once.
    distFS = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    distFS:SetPoint("TOP", arrow, "BOTTOM", 0, -4)

    nameFS = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    nameFS:SetPoint("TOP", distFS, "BOTTOM", 0, -3)
    nameFS:SetWidth(220)
    nameFS:SetJustifyH("CENTER")

    hintFS = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hintFS:SetPoint("TOP", nameFS, "BOTTOM", 0, -2)
    hintFS:SetWidth(220)
    hintFS:SetJustifyH("CENTER")

    f:Hide()
    return f
end

-- --------------------------------------------------------------------- events

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("CHAT_MSG_ADDON")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:RegisterEvent("ZONE_CHANGED_NEW_AREA")
ev:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")

ev:SetScript("OnEvent", function(_, event, ...)
    if event == "PLAYER_LOGIN" then
        frame = Build()
        NorgNavDB = NorgNavDB or {}
        if NorgNavDB.pos then
            local p, rp, x, y = unpack(NorgNavDB.pos)
            frame:ClearAllPoints()
            frame:SetPoint(p, UIParent, rp, x, y)
        end
        Say("v" .. VERSION ..
            " loaded. Routes automatically in dungeons. /nav next to skip, /nav off, /nav help.")
        whereRetry = 2.0
        return
    end

    if event == "CHAT_MSG_ADDON" then
        local prefix, message = ...
        if prefix == PREFIX then OnAddonMessage(message) end
        return
    end

    if event == "COMBAT_LOG_EVENT_UNFILTERED" then
        -- (!) 3.3.5a COMBAT_LOG_EVENT_UNFILTERED argument order:
        --   1 timestamp  2 subevent  3 sourceGUID  4 sourceName
        --   5 sourceFlags 6 destGUID  7 destName    8 destFlags
        -- destName is the SEVENTH. Reading the wrong slot fails silently -- the
        -- arrow simply never advances and nothing errors.
        --
        -- (!) CHECK EVERY BOSS IN THE INSTANCE, NOT JUST THE ONE BEING ROUTED TO.
        --
        -- The first version only compared against the current target, which meant
        -- killing a boss OUT OF ORDER went completely unrecorded -- and that is the
        -- normal case, not an edge case: bots wander, groups clear whatever they
        -- walk into, and the arrow is frequently pointing at a different boss than
        -- the one you are fighting. The kill then vanished, and the arrow later
        -- routed the party back across the instance to a corpse.
        --
        -- The server's spawn-id check has the same shape and the same blind spot
        -- (it only watches t.spawnId), so this is the only thing that catches it
        -- until the periodic ALIVE refresh comes round.
        local _, sub, _, _, _, _, dstName = ...
        if (sub == "UNIT_DIED" or sub == "PARTY_KILL") and dstName then
            for _, b in ipairs(bosses) do
                if b.n == dstName and not dead[b] then
                    dead[b] = true
                    if target == b then
                        -- Same frozen-panel case as S|dead: in manual mode there
                        -- is nothing to advance to, so the panel has to come down
                        -- rather than sit on a dead boss's name and a stale count.
                        TargetFinished()
                    else
                        Say(b.n .. " is down. |cff808080(" .. CountRemaining() ..
                            " left)|r")
                    end
                    break
                end
            end
        end
        return
    end

    -- PLAYER_ENTERING_WORLD / ZONE_CHANGED_NEW_AREA.
    --
    -- (!) ALWAYS ASK THE SERVER, never infer from GetInstanceInfo(). That returns
    -- a LOCALISED display name, and for the first second or two after entering
    -- the world it returns nothing at all -- so logging in while already standing
    -- inside a dungeon silently routed nothing, which is precisely how this
    -- presented. The server knows the map id for certain.
    whereRetry = 1.5
    Send("WHERE")
end)

-- Redraw between server updates so the arrow tracks your own turning smoothly
-- rather than only three times a second when a packet lands.
local acc = 0
local aliveTick = 0
ev:SetScript("OnUpdate", function(_, elapsed)
    -- (!) POLL THE SERVER PERIODICALLY. The combat log only reports kills the
    -- player was present for, so anything downed before they zoned in, or out
    -- of range, or while they were dead, is invisible to the client forever.
    -- One small chat line every 20 seconds closes that hole and is what makes
    -- the arrow trustworthy when bots are clearing ahead of the group.
    if mapId and #bosses > 0 then
        aliveTick = aliveTick + elapsed
        if aliveTick >= 20 then
            aliveTick = 0
            AskAlive()
        end
    end

    -- Retries. Both of these are one small chat line, and both cover a real race:
    -- the addon can finish loading before the server will answer, and a reply can
    -- be lost while the world is still streaming in around a fresh login.
    if whereRetry > 0 then
        whereRetry = whereRetry - elapsed
        if whereRetry <= 0 then
            whereRetry = 3.0
            Send("WHERE")
        end
    end
    if aliveRetry > 0 then
        aliveRetry = aliveRetry - elapsed
        if aliveRetry <= 0 then
            aliveRetry = 0
            AskAlive()
        end
    end

    -- (!) RETIRE A START THAT WAS NEVER ANSWERED, OR ONE LOST REPLY MIS-CREDITS
    -- EVERY KILL FOR THE REST OF THE SESSION.
    --
    -- The reply is written by the same handler that reads the whisper, so the
    -- only way one never arrives is that the whisper never got there --
    -- ChatHandler.cpp drops the line at !CanSpeak() and on the GM silence aura
    -- before mod-norg-nav is called at all. Nothing then retires that queue
    -- entry, so it stays at the head for ever and every later acknowledgement
    -- pops the WRONG boss: S|dead credits the previous entry from then on, with
    -- nothing on screen to say so. The depth guard in StartNav cannot see it --
    -- one lost reply keeps the queue oscillating between one and two.
    --
    -- Ages only advance while frames are drawn, so a loading screen does not
    -- age anything out, and the front entry is always the oldest, so the drain
    -- can stop at the first live one. Dropping `subscribed` alongside it is the
    -- point: we no longer know what the server is watching, and an S|dead we
    -- cannot attribute must ASK (a missed death is repaired by the alive poll;
    -- a mis-credited one is not).
    if startQ[1] then
        for _, q in ipairs(startQ) do q.age = q.age + elapsed end
        local expired = false
        while startQ[1] and startQ[1].age >= ACK_TIMEOUT do
            table.remove(startQ, 1)
            expired = true
        end
        if expired then
            subscribed = nil
            AskAlive()
            aliveRetry = 2.0
            -- Once per episode, and only while something is actually on screen
            -- to be stale. A mute swallows every whisper this addon sends, so a
            -- line per route would be a wall of text about one problem -- but
            -- silence here is worse, because a stale arrow that never updates is
            -- indistinguishable from one simply pointing at a boss a long way
            -- off. With no target the panel is already down and, if NorgQuest
            -- took the slot, already explained, so a second line about a route
            -- nobody can see would only confuse.
            if target and not ackLost then
                ackLost = true
                Say("the server did not answer the last route request -- the arrow may be stale. /nav to retry.")
            end
        end
    end

    if not target or not haveFix then return end
    acc = acc + elapsed
    if acc < 0.05 then return end
    acc = 0
    Refresh()
end)

-- -------------------------------------------------------------------- command

--- (!) A COMMAND THAT ANSWERS WITH SILENCE READS AS A BROKEN ADDON.
---
--- AutoRoute is deliberately quiet whenever it has nothing to change, and the
--- all-clear is deliberately said ONCE per instance -- so once everything was
--- marked down, /nav printed absolutely nothing, every time, forever. That was
--- reported as "typing /nav does nothing at all" after a mis-credited kill, and
--- the silence is what made it impossible to tell a broken addon from a cleared
--- instance. Returns true when it has explained why there is nothing to route
--- to, and pre-arms saidAllDone so AutoRoute does not then repeat itself.
local function SayNothingToRoute()
    if #bosses == 0 then
        Say("no boss coordinates for this instance.")
        return true
    end
    if NextBoss() then
        return false
    end

    saidAllDone = true
    local ns = CountSkipped()
    if ns > 0 then
        Say(string.format("every boss here is accounted for -- %d down, %d skipped. /nav reset brings the skipped ones back.",
            CountDead(), ns))
    else
        Say(string.format("every boss here is already marked down (%d of %d). /nav reset if that looks wrong.",
            CountDead(), #bosses))
    end
    return true
end

SLASH_NORGNAV1 = "/nav"
SlashCmdList["NORGNAV"] = function(arg)
    arg = arg and arg:lower():gsub("^%s+", ""):gsub("%s+$", "") or ""

    if arg == "help" or arg == "?" then
        Say("/nav -- resume automatic routing in encounter order")
        Say("/nav next -- skip the current boss (behind a door, or you want another)")
        Say("/nav <name> -- route to one boss and stay on it")
        Say("/nav list -- what is here, what is down, and what you skipped")
        Say("/nav reset -- forget every down/skipped mark and re-check with the server")
        Say("/nav off -- stop; /nav debug -- show what the server is sending")
        return
    end

    if arg == "off" or arg == "stop" then
        autoMode = false
        StopNav()
        return
    end

    if arg == "" or arg == "auto" or arg == "on" then
        autoMode = true
        if not mapId then
            -- Before the first M| this is the whole truth, and it is a great deal
            -- more useful than nothing: the server answers within a second or two
            -- and the arrow appears on its own.
            Send("WHERE")
            Say("asking the server which instance this is...")
            return
        end

        AskAlive()
        if not SayNothingToRoute() and target == NextBoss() then
            -- AutoRoute says nothing when it is already on the right boss, and
            -- "/nav did nothing" is exactly how that reads.
            Say("already routing to " .. target.n .. ".")
        end
        AutoRoute()
        return
    end

    if arg == "reset" then
        -- The way back from any wrong mark: a skip the player has changed their
        -- mind about, or a death this addon or the server got wrong. Clears our
        -- own bookkeeping and then asks the server for the truth rather than
        -- assuming everything is alive -- the A| reply re-marks whatever really
        -- is down, so a reset in a half-cleared instance does not send anyone
        -- back to a corpse.
        dead = {}
        skipped = {}
        saidAllDone = false
        autoMode = true
        -- (!) DROP THE CURRENT TARGET TOO. Once every mark is cleared NextBoss
        -- always returns the FIRST entry in the instance, and AutoRoute only
        -- acts when the boss it picks differs from the one being routed to -- so
        -- if the arrow was already on that first entry it would leave the run
        -- exactly as it found it. Clearing `target` makes it re-request the
        -- route and name it, so the command re-routes visibly instead of only
        -- printing a line about marks the player cannot see.
        --
        -- (!) NO STOP IS SENT, and `subscribed` is deliberately left alone: the
        -- server really is still watching that boss, so an S|dead landing in
        -- between is credited correctly, and correctly re-marks a boss this
        -- command has just cleared the death mark from.
        --
        -- The server keeps ONE target slot per player, and the AutoRoute below
        -- USUALLY takes it over by STARTing the next boss. Not always: it sends
        -- nothing at all when the instance has no entries, and an nr=1 next
        -- entry sends no START either -- ShowUnroutable only sends STOP when a
        -- target is set, and this command has just cleared it. In those two
        -- cases the old subscription keeps streaming until something else takes
        -- the slot or the player leaves the map.
        target = nil
        haveFix = false
        Say("cleared every down and skipped mark here; re-checking with the server.")
        if AskAlive() then
            aliveRetry = 2.0
        end
        -- Route now rather than waiting for the reply. SetMap waits on purpose --
        -- it is crossing an instance -- but this is a standing player who just
        -- asked for something to happen, and the worst case is one "next --"
        -- line being corrected a third of a second later.
        SayNothingToRoute()   -- only reachable here when the instance has no data
        AutoRoute()
        return
    end

    if arg == "next" or arg == "skip" then
        autoMode = true
        if target then
            -- (!) SKIPPED, NOT DEAD. Both facts lived in `dead` once, and the
            -- alive poll is allowed to clear a death mark -- it has to be, or a
            -- boss that evaded stays skipped for the run -- so it un-skipped
            -- this one and dragged the player straight back to it, anywhere
            -- between instantly and twenty seconds later.
            skipped[target] = true
            Say("skipping " .. target.n .. " for this run. /nav reset brings it back.")
            target = nil
        else
            Say("nothing is being routed, so there is nothing to skip.")
        end
        SayNothingToRoute()
        AutoRoute()
        return
    end

    if arg == "list" then
        if #bosses == 0 then Say("nothing routable here.") return end
        for _, b in ipairs(bosses) do
            -- Down and skipped are shown separately on purpose: "skipped" is the
            -- player's own decision and the only one /nav reset can undo, so
            -- printing both as (down) hid the one fact they could act on.
            Say(string.format("  %d. %s%s%s%s", b.i, b.n,
                b.ap and "  |cffffd100(event start)|r" or "",
                dead[b] and "  |cff808080(down)|r" or "",
                (skipped[b] and not dead[b]) and "  |cff808080(skipped)|r" or ""))
        end
        return
    end

    if arg == "debug" then
        Say(string.format("map=%s bosses=%d status=%s fix=%s",
            tostring(mapId), #bosses, lastStatus, tostring(haveFix)))
        -- (!) PRINT WHAT THE SERVER IS WATCHING ALONGSIDE WHAT IS ON SCREEN.
        -- The two differing is normal for a moment after every kill, and a kill
        -- report is credited to the SERVER's one -- so when a boss is marked
        -- down that should not be, this line is the only place the discrepancy
        -- is visible at all.
        -- `awaiting` is the other half of it: a number that will not come back
        -- down is a reply that is never coming, which is the one failure that
        -- used to poison every later kill silently.
        Say(string.format("  on screen=%s  server is watching=%s  awaiting=%d  down=%d skipped=%d",
            target and target.n or "nothing",
            subscribed and subscribed.n or "nothing",
            #startQ, CountDead(), CountSkipped()))
        if haveFix then
            -- Cardinal direction is computed from world coordinates alone, with no
            -- facing involved, so it is a check on the COORDINATE convention that
            -- can be eyeballed against the minimap in a couple of seconds.
            Say(string.format("  you (%.0f, %.0f)  next corner (%.0f, %.0f) -- %s of you",
                px, py, wx, wy, Cardinal(wx - px, wy - py)))
            Say(string.format("  route %d yd, straight %d yd, facing %.0f deg",
                routeYd, lineYd, math.deg(GetPlayerFacing and GetPlayerFacing() or 0)))
        elseif target then
            Say("  waiting for the first position from the server (up to a second).")
        else
            Say("  nothing is being routed. /nav to start.")
        end
        return
    end

    if #bosses == 0 then
        Say("no boss coordinates for this instance.")
        return
    end

    for _, b in ipairs(bosses) do
        if b.n:lower():find(arg, 1, true) then
            -- A manual pick is an OVERRIDE: stop auto-advancing until /nav,
            -- otherwise the next boss dying would yank you off the one you chose.
            autoMode = false
            StartNav(b)
            Say("routing to " .. b.n .. " |cff808080(manual -- /nav to resume order)|r")
            return
        end
    end

    Say("no boss matching \"" .. arg .. "\". Try /nav list.")
end
