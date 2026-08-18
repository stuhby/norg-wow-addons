--[[----------------------------------------------------------------------------
  NorgQuest -- points you at the nearest quest objective you can actually do.

  WHY THIS EXISTS RATHER THAN QuestHelper
  QuestHelper is a client addon, so everything it knows it had to be told in
  advance: a shipped database of where things are, your progress inferred from
  quest log text, and no visibility into your bags at all. That is where its
  three familiar annoyances come from -- pointing at an objective you already
  finished, pointing at one you cannot start, and pointing through a hill.

  Here the SERVER answers instead, and it is not guessing:
    * progress comes from your actual quest-log counters and bag contents, so a
      finished objective is not offered at all
    * positions come from the spawn tables the world is built from
    * the arrow follows a real navmesh route, so it goes round the hill and into
      the cave mouth rather than through them

  (!) WHO OWNS THE ARROW
  NorgQuest and NorgNav share one server-side router, so only one of them can be
  steering at a time. They divide by MAP rather than by negotiating: NorgNav owns
  instances (it has boss data for those and only those), NorgQuest owns the open
  world. Inside an instance NorgQuest will not auto-track, though /quest still
  works if you ask for it -- at which point you have deliberately taken the wheel
  and NorgNav's arrow goes stale until you leave or /quest off.
------------------------------------------------------------------------------]]

local QPREFIX = "NORGQUEST"    -- our own control channel
local NPREFIX = "NORGNAV"      -- the shared position stream we listen to

-- (!) THE VERSION IS READ FROM THE .toc, NEVER COPIED INTO A CONSTANT HERE. The
-- login line is step one of the wiki's troubleshooting page, and a second copy of
-- the number drifts from the .toc in silence, and nothing in the game can then
-- tell you which of the two you are reading. "?" means the client never indexed
-- this folder, which is itself the answer to "why is nothing happening".
local ADDON   = "NorgQuest"    -- FOLDER name; GetAddOnMetadata keys on that
local VERSION = GetAddOnMetadata(ADDON, "Version") or "?"

local COL_OK   = { 0.95, 0.95, 0.95 }
local COL_SOFT = { 1.00, 0.82, 0.00 }
local COL_HARD = { 1.00, 0.35, 0.35 }

-- (!) EVERY LOOKUP OF THIS TABLE IS WRITTEN "KIND_WORD[k] or 'go to'", AND THAT
-- FALLBACK IS LOAD-BEARING. The server adds objective kinds ahead of the addon
-- being redistributed, so an unrecognised letter has to render as a sensible
-- word rather than blank out the objective name. 'e' below is spelled the same
-- as the fallback on purpose: a player still running the previous copy of this
-- addon sees exactly what an updated one does.
local KIND_WORD = {
    t = "turn in",
    k = "kill",
    g = "use",
    i = "collect",
    -- (!) 'n' IS A QUEST YOU DO NOT HAVE YET -- supplied by NorgGuide's ranking and
    -- arbitrated here as an ordinary task, on distance, exactly like everything else
    -- in this table. The caption has to make that obvious: the player is being sent
    -- to an NPC whose quest is NOT in their log, and the "go to" fallback would leave
    -- them hunting the quest list for something that is not there. See KIND_PICKUP in
    -- norg_quest.cpp for why it is its own letter rather than reusing 'e'.
    n = "pick up",
    e = "go to",     -- event: somebody to talk to, or something to watch happen
    -- (!) 'a' IS A PLACE AND HAS NOBODY IN IT. The server used to send these as
    -- 'e' carrying a "name" it had looked up from the QUEST id, so The Fargodeep
    -- Mine came out as "talk to Gug Fatcandle" -- a real NPC, nowhere near the
    -- mine. The arrow was always right; only the caption lied, which is worse
    -- than saying nothing because the player goes looking for the NPC.
    a = "explore",
    -- (!) 'v' EXISTS SO THE PANEL STOPS SAYING "kill" ABOUT A SHOPKEEPER. The
    -- server resolves a vendor through the ordinary creature spawn index, so a
    -- bought item and a dropped one arrive here looking identical apart from
    -- this letter -- without it the quest reads "collect Rugged Leather" beside
    -- an arrow pointing at a trade goods merchant.
    v = "buy",
    -- (!) 'p' IS AN OUTLINE ON THE MAP, NOT A TARGET, AND THE WORDING IS THE
    -- POINT. It is one of the server's two last resorts: Blizzard's own quest
    -- marker, used only when nothing in the world could be resolved. It has no
    -- entry, nobody stands in it, and this shape of it is a region the designer
    -- sketched -- so it must never read as an instruction to reach an exact spot.
    -- "search this area" is what the server actually knows. Anything that names
    -- somebody here is wrong by construction: see the second lock in Refresh.
    p = "search this area",
    -- (!) 'm' IS THE SAME KIND OF MARKER DRAWN AS A SINGLE POINT, AND IT IS THE
    -- COMMON ONE. The server used to send both shapes as 'p', so a marker that
    -- was one exact coordinate told the player to go and hunt around -- an
    -- instruction to wander over an answer they had already been given.
    --
    -- Spelled the same as the fallback ON PURPOSE, exactly like 'e': an addon
    -- that predates this letter renders KIND_WORD[k] or "go to" and therefore
    -- already says the right thing. That is why the SERVER kept 'p' for the
    -- outline and gave the new letter to the point, rather than the reverse.
    --
    -- (!) IT IS PRECISE, NOT POPULATED. There is still nobody standing there and
    -- still no entry to name, so 'm' needs every anti-naming lock 'p' has. Miss
    -- one and the Fargodeep Mine caption comes back for most markers.
    m = "go to",
}

local frame, arrow, nameFS, distFS, hintFS

local objectives = {}     -- [questId] = { kind, x, y, dist, sameMap }
-- [questId] = true once we have told the player that quest does not exist on
-- this server. Deliberately NOT cleared by a rescan -- see the X| handler.
local reportedUnknown = {}
local tracked             -- questId we asked the server to route to
-- (!) Declared local. Without these two lines they become GLOBALS, which works
-- in Lua and quietly pollutes the shared namespace every addon sees.
local trackedKind, trackedX, trackedY   -- the objective we committed to

-- How far an objective must move before it counts as a DIFFERENT one rather
-- than another spawn of the same mob. Generous, because spawn clusters are
-- large and swapping targets mid-walk is far worse than walking to a slightly
-- further member of the group you were already heading for.
local RETARGET_YARDS = 250
-- (!) AN ESCORT NPC WALKS, SO COMMITTING TO HIM FOR 250 YARDS POINTS BEHIND YOU.
-- The number above exists because a kill target has 8.6 spawns on average and the
-- server always answers with the nearest, so simply walking makes a different one
-- nearest and an exact-match check would swing the arrow between neighbours.
--
-- An event objective ('e') is USUALLY one named NPC rather than a crowd of
-- interchangeable ones, and that is the whole argument for a tighter number here.
-- Usually, not always -- a few event quests do name a creature with more than one
-- spawn row, so this is a difference of degree, not a guarantee. It does not have
-- to be a guarantee: the server reports where the NPC IS rather than where he
-- spawned, so for an escort the answer moves because HE moved, and re-routing to
-- his new position is the correct response rather than churn.
--
-- Escort paths run several hundred yards, so holding the first answer for 250 of
-- them reproduces the exact complaint the live lookup was added to fix. 40 yards
-- is inside "you can see him", so the arrow refreshes while he is still in sight.
--
-- (!) A RE-ROUTE TRIGGERED BY THIS NUMBER MUST STAY ON THE SAME QUEST. Shortening
-- the commit without that is worse than not shortening it at all -- see the
-- broken-commit block in AutoTrack.
local EVENT_RETARGET_YARDS = 40
-- A rival objective must be this many times closer AND this many yards closer
-- before it is allowed to steal a committed pick. See AutoTrack.
-- (!) OBJECTIVE DISTANCES GO STALE AS YOU WALK, AND EVERY DECISION USES THEM.
-- Scans used to fire only on login, a quest-log change and ZONE_CHANGED_NEW_AREA.
-- None of those happen while crossing a zone on foot, so AutoTrack kept choosing
-- from distances measured wherever the last scan happened -- reported live:
-- standing ON an objective while the panel read 4,000 yards, because the numbers
-- were taken back at the zeppelin tower. A zeppelin makes this much worse than a
-- flight path, since UnitOnTaxi() is FALSE aboard a transport, so the
-- arrival-rescan added for taxis never fires for one.
-- A scan is one addon message; every few seconds is nothing next to being wrong.
local RESCAN_SECS      = 6
local SWITCH_RATIO     = 4
local SWITCH_MIN_YARDS = 400
local legText                -- e.g. "take Zeppelin (The Thundercaller)"
local targetName             -- WHO or WHAT is at the objective, from the server
local targetType             -- "c" creature, "g" gameobject, "a" a place (no name)
-- (!) WHAT the player is looking for when they arrive, in the quest's own words,
-- sent only for a map marker. A marker gives a place and nothing else, so without
-- this the panel can say "go to" beside an arrow and still leave the player
-- standing on a hillside wondering what they came for. Declared here with the
-- others because a bare assignment in OnQuestMessage would make it a GLOBAL.
--
-- (!) IT IS PER-QUEST STATE AND MUST BE CLEARED THE MOMENT THE PICK CHANGES --
-- see Track. Text left over from the previous quest is the same failure as a name
-- left over from it: a confident instruction about the wrong objective.
local targetObjective
local subscribed = false     -- is the server actually streaming to us now
local autoMode = true
local scanAt = 0
local haveFix, lastStatus = false, "ok"
local px, py, wx, wy, routeYd, lineYd = 0, 0, 0, 0, 0, 0
-- (!) COUNTS ROUTES, NOT DESTINATIONS, AND THAT IS THE POINT. ArrowDraw keys its
-- near-target hold on this, and /quest on the quest ALREADY tracked has to count
-- as a new route: keyed on the quest id it would read as no change at all, and a
-- heading held from the previous attempt would carry into this one.
--
-- (!) DECLARED HERE, NOT BESIDE Track. A local declared BELOW Refresh is not an
-- upvalue of it -- Refresh would read a nil GLOBAL of the same name, forever, and
-- the reset would silently never fire while every test still passed.
local routeGen = 0

-- Control channel. Same whisper-to-self trick NorgNav uses: the server swallows
-- the line before it reaches chat, so the worst case if the module is missing is
-- a line only you can see, rather than spamming everyone nearby.
local function Send(cmd)
    local me = UnitName and UnitName("player")
    if me then SendChatMessage("NORGQUEST " .. cmd, "WHISPER", nil, me) end
end

local function Say(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cffffcc33NorgQuest|r: " .. msg)
end

-- (!) THE CLIENT HAS NO DIRECT questId->log-entry LOOKUP IN 3.3.5a.
-- GetQuestLogTitle() returns a title and flags but no id -- that only arrived in
-- later expansions. The id has to be dug out of the quest LINK, which encodes it
-- as |Hquest:<id>:<level>|h[Title]|h. Everything the server sends is keyed by
-- quest id, so without this the whole display would read "Quest #1234".
local function QuestTitles()
    local byId = {}
    if not GetNumQuestLogEntries or not GetQuestLink then return byId end

    local n = GetNumQuestLogEntries()
    for i = 1, n do
        local title, _, _, _, isHeader = GetQuestLogTitle(i)
        if not isHeader then
            local link = GetQuestLink(i)
            local id = link and tonumber(link:match("|Hquest:(%d+):"))
            if id then byId[id] = title end
        end
    end
    return byId
end

local function InInstanceNavCovers()
    -- NorgNav only has data for instance maps, so the presence of an entry is
    -- exactly the question "is NorgNav steering here?". Reading its table
    -- directly is fine -- it is a plain global and NorgQuest works without it.
    if not IsInInstance or not IsInInstance() then return false end
    return true
end

-- --------------------------------------------------------------------- arrow

--- Rotates COUNTERCLOCKWISE by the given angle. Texture:SetRotation does not
--- exist in 3.3.5a (it arrived in 4.0), so this transforms the four texture
--- corners instead. The direction is not obvious -- SetTexCoord moves the
--- SAMPLING coordinates so the image turns the opposite way, and texture v runs
--- downward while screen y runs up, which flips it back. Same implementation as
--- NorgNav, where it was verified rather than assumed.
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

-- >>> NORG ARROW STABILISER -- BYTE-IDENTICAL IN NorgQuest AND NorgNav --------
--
-- (!) THE TWO COPIES MUST STAY THE SAME, AND BOTH SUITES CHECK IT. quest_test
-- and nav_test each read BOTH addon files and fail if this block differs by one
-- byte, because arrow code drifting apart between the two is a mistake this
-- project has already made: NorgNav 1.0 shipped a mirrored bearing and NorgQuest
-- did not, so the identical arrow was right in a dungeon and wrong outdoors.
-- Edit one copy, paste the whole block over the other, run both suites.
--
-- (!) IT MUST SIT BELOW RotateTexture IN BOTH FILES -- it calls it as an upvalue.
--
-- WHAT IT IS FOR. The server streams the player's position three times a second
-- (NAV_INTERVAL_MS, norg_nav.cpp) and the bearing used to be drawn from that
-- point. Between packets the arrow was therefore aimed from where the player had
-- been up to a third of a second earlier, so the faster they moved the further
-- back the anchor sat -- the arrow over-corrected, the player turned to follow
-- it, and the next packet swung it back. That is the wobble, and it is worse the
-- faster you go because the anchor's lag is a time, not a distance.
-- norg_nav.cpp already pushes its aim point out to 15-40 yards
-- (NAV_LOOKAHEAD_MIN/MAX) to blunt exactly this, with the reason spelled out in
-- its own comment; that is a mitigation of this defect from the server end.
--
-- The client always knows where it is. 3.3.5a has no UnitPosition(), but
-- GetPlayerMapPosition("player") gives the position on the CURRENT ZONE MAP as
-- a pair of 0..1 fractions, and the number of world yards per map unit is a
-- constant for a given map.
--
-- (!) THERE IS NO ZONE-BOUNDS TABLE HERE AND NONE IS NEEDED. The world-to-map
-- conversion behind the route line on the world map is done SERVER-side
-- (Map2ZoneCoordinates in norg_nav.cpp); only already-normalised numbers ever
-- reach the client, so there was no client-side conversion to reuse. Rather than
-- ship a table of every zone's extent, the scale is LEARNED: each position
-- packet is one (map coordinate, world coordinate) pair, and a running
-- least-squares fit over those pairs IS the yards per map unit. Learned beats
-- shipped here -- no data file to go stale, no map it does not know about, and
-- it is self-checking, because until the fit is good enough nothing changes.
--
-- (!) ONLY THE SLOPE IS USED, AND ONLY AS A DELTA FROM THE LAST SERVER FIX. The
-- estimate is "where the server last said we were, plus how far the map says we
-- have moved since that packet". Nothing is ever extrapolated further than one
-- packet, so a scale error is multiplied by a couple of yards rather than by the
-- width of a zone, and the intercept -- the part a mis-learned fit would get
-- most wrong -- is never used at all. The worst case is the OLD behaviour, not a
-- new kind of wrong.
--
-- (!) INSIDE AN INSTANCE THIS IS INERT, AND THAT IS NorgNav's HALF OF THE STORY.
-- 3.3.5a has no dungeon maps, so GetPlayerMapPosition answers 0,0 in every
-- instance NorgNav covers: no sample is taken, the fit never becomes ready, and
-- the server position is used exactly as before. Nothing below is instance-aware
-- -- the same code engages where the client has a usable map and stays out of
-- the way where it does not, which is why it can be shared verbatim. What
-- NorgNav does get in full is the other half, the near-target hold and the dead
-- zone, and those are what stop the texture twitching.

-- Below this many yards from the aim point the bearing stops carrying
-- information: walking a yard sideways swings it tens of degrees, so it spins
-- while the player is doing the one part of the trip that needs no guidance.
-- The server aims 15-40 yards ahead along the route, so the aim point can only
-- come this close in the last few yards of a trip -- holding the last good
-- heading there costs nothing during normal travel. No hysteresis band is needed
-- around it: the two branches agree at the boundary, so chattering across it
-- cannot be seen.
local ARROW_NEAR_YD = 5

-- Do not push the texture for a turn too small to see. The tip sits half the
-- arrow's width from its centre -- 26 of the 52 units -- and it travels
-- radius * angle, so at this angle it moves well under one screen pixel at any
-- resolution the game runs at. Nothing suppressed here could have been seen.
local ARROW_DEAD_RAD = 0.01

-- A step bigger than this is not movement. One packet is a third of a second and
-- the fastest sustained speed in 3.3.5a, a 310% flying mount, covers about ten
-- yards in that time. Anything past this means the frame of reference changed
-- underneath us -- a zone crossing, or the world map panned to somewhere else --
-- so it is used both to refuse an extrapolation and to spot a fit whose
-- predictions have stopped landing near the server's own answer.
local ARROW_MAX_JUMP_YD = 40

-- How much evidence the fit needs before it is allowed to steer. The sample
-- count alone is not enough: a player standing still contributes samples that
-- add no information, and a slope drawn from a short lever arm is dominated by
-- the noise in it. The spread -- the standard deviation of the map coordinate
-- the samples cover -- is what actually determines the slope, so that is what is
-- gated on, and being in map units it means the same fraction of any zone.
local ARROW_FIT_MIN_N      = 8
local ARROW_FIT_MIN_SPREAD = 0.008

-- How many position packets between attempts to put the world map back onto the
-- player's own zone. At three packets a second this is a few seconds, which is
-- unnoticeable and still far more often than anyone re-opens the map.
local ARROW_MAP_RETRY = 9

local arrowFits = {}      -- map key -> { x = fit, y = fit }, kept so re-entering
                          -- a zone already walked does not re-learn it
local arrowFit            -- the pair belonging to arrowKey
local arrowKey            -- which map the fit and the anchor below belong to
local arrowKX, arrowKY    -- cached slopes, refreshed once per packet not per frame
local arrowSX, arrowSY    -- the last position the server sent
local arrowMX, arrowMY    -- the map position read at that same instant, or nil
local arrowHeld           -- world bearing held while inside ARROW_NEAR_YD
local arrowDrawn          -- the angle actually pushed to the texture last time
local arrowTarget         -- which route we were drawing, so a new one snaps
local arrowMiss = 0       -- consecutive packets the fit failed to predict
local arrowRetry = 0

local function ArrowNewFit()
    return { n = 0, x0 = nil, y0 = nil, sx = 0, sy = 0, sxx = 0, sxy = 0 }
end

--- One (map coordinate, world coordinate) pair.
---
--- (!) ACCUMULATED RELATIVE TO THE FIRST PAIR. Map coordinates sit around 0.5
--- and world coordinates run to five figures, so summing them raw and taking the
--- variance as mean-of-squares minus square-of-mean throws away most of the
--- precision in exactly the small quantity the slope depends on. Offsetting by
--- the first sample keeps both terms small and leaves the slope identical.
local function ArrowFitAdd(f, x, y)
    if not f.x0 then f.x0, f.y0 = x, y end
    x, y = x - f.x0, y - f.y0
    f.n = f.n + 1
    f.sx, f.sy = f.sx + x, f.sy + y
    f.sxx, f.sxy = f.sxx + x * x, f.sxy + x * y
end

--- World yards per unit of map coordinate, or nil while that is not yet worth
--- trusting.
---
--- (!) THE SIGN COMES OUT OF THE DATA. Both world axes run backwards against the
--- map axes in 3.3.5a, but nothing here assumes that: the fit reports whatever
--- relationship the samples actually show, so a map laid out some other way
--- would simply produce the other sign and still be right.
local function ArrowFitSlope(f)
    if f.n < ARROW_FIT_MIN_N then return nil end
    local mean = f.sx / f.n
    local var = f.sxx / f.n - mean * mean
    if var <= 0 or math.sqrt(var) < ARROW_FIT_MIN_SPREAD then return nil end
    return (f.sxy / f.n - mean * (f.sy / f.n)) / var
end

--- (!) 0,0 MEANS "NOT ON THE MAP BEING DISPLAYED", NOT THE TOP-LEFT CORNER.
--- GetPlayerMapPosition answers relative to whatever the world map is currently
--- showing, so it returns 0,0 inside an instance and whenever the map has been
--- panned to another zone. Taking that literally would place the player in the
--- corner of the zone and send the arrow somewhere absurd, so it is refused --
--- and the server's position, which is never wrong, is what gets used instead.
local function ArrowMapPos()
    if not GetPlayerMapPosition then return nil end
    local x, y = GetPlayerMapPosition("player")
    if not x or not y then return nil end
    if x <= 0 and y <= 0 then return nil end
    return x, y
end

--- Which map the numbers above are relative to. A scale learned in one zone
--- means nothing in the next, so this is what keeps them apart.
local function ArrowMapKey()
    local c = GetCurrentMapContinent and GetCurrentMapContinent() or 0
    local z = GetCurrentMapZone and GetCurrentMapZone() or 0
    return tostring(c) .. ":" .. tostring(z)
end

--- The world map does not follow the player around by itself: open it, pan to
--- another continent, close it, and GetPlayerMapPosition answers 0,0 from then
--- on for as long as it stays closed. SetMapToCurrentZone puts it back.
---
--- (!) ONLY EVER WHILE THE MAP IS HIDDEN. Doing it with the map open would yank
--- the view out from under whoever is reading it. It is also skipped inside an
--- instance, where there is no zone map to set and it could only spin.
local function ArrowRecoverMap()
    if arrowRetry > 0 then arrowRetry = arrowRetry - 1 return end
    arrowRetry = ARROW_MAP_RETRY
    if not SetMapToCurrentZone then return end
    if IsInInstance and IsInInstance() then return end
    if WorldMapFrame and WorldMapFrame.IsShown and WorldMapFrame:IsShown() then return end
    SetMapToCurrentZone()
end

--- How far the map says the player has moved since the last server fix, in world
--- yards. nil while there is no anchor, or no scale trusted enough to convert
--- with.
---
--- (!) DELIBERATELY UNCAPPED. The two callers apply ARROW_MAX_JUMP_YD themselves
--- and they need it for opposite reasons: the draw path refuses an impossible
--- step, while the health check has to SEE the impossible step to know the fit
--- has gone bad. Folding the cap in here would hide a broken fit behind a nil and
--- leave it in place for good, silently steering by the server position with
--- nothing anywhere to say why.
local function ArrowDrift(mx, my)
    if not arrowMX or not arrowKX or not arrowKY then return nil end
    return (my - arrowMY) * arrowKX, (mx - arrowMX) * arrowKY
end

--- A fresh position from the server: the anchor the arrow is drawn from, and one
--- more sample for the scale.
local function ArrowFix(sx, sy)
    local key = ArrowMapKey()
    if key ~= arrowKey then
        arrowKey = key
        arrowFit = arrowFits[key]
        if not arrowFit then
            arrowFit = { x = ArrowNewFit(), y = ArrowNewFit() }
            arrowFits[key] = arrowFit
        end
        -- The old anchor was measured against a different map, so it is not a
        -- reference for anything any more.
        arrowMX, arrowMY = nil, nil
        arrowMiss = 0
    end

    local mx, my = ArrowMapPos()

    -- (!) CHECK THE FIT AGAINST THE SERVER BEFORE TRUSTING IT FURTHER. If the
    -- scale is right, where we said the player would be has to land near where
    -- the server now says they are. Missing by more than a step could ever be
    -- means the fit no longer describes the map we are reading, and steering by
    -- it would be confidently wrong -- so it is dropped and learned again.
    --
    -- (!) TWO IN A ROW, NOT ONE. A single miss is also what a dropped packet, a
    -- lag spike or a hearthstone looks like, and none of those say anything
    -- about the scale; throwing a good fit away every time the network hiccups
    -- would keep the arrow permanently degraded on a poor connection.
    if mx and arrowMX then
        local dx, dy = ArrowDrift(mx, my)
        if dx then
            local ex, ey = arrowSX + dx - sx, arrowSY + dy - sy
            if ex * ex + ey * ey > ARROW_MAX_JUMP_YD * ARROW_MAX_JUMP_YD then
                arrowMiss = arrowMiss + 1
                if arrowMiss >= 2 then
                    arrowFit = { x = ArrowNewFit(), y = ArrowNewFit() }
                    arrowFits[key] = arrowFit
                    arrowMiss = 0
                end
            else
                arrowMiss = 0
            end
        end
    end

    if mx then
        -- World X against map Y and world Y against map X: the map's vertical
        -- axis is the world's north-south one and its horizontal axis the
        -- world's east-west one.
        ArrowFitAdd(arrowFit.x, my, sx)
        ArrowFitAdd(arrowFit.y, mx, sy)
    else
        ArrowRecoverMap()
    end

    arrowKX = ArrowFitSlope(arrowFit.x)
    arrowKY = ArrowFitSlope(arrowFit.y)
    arrowSX, arrowSY = sx, sy
    arrowMX, arrowMY = mx, my
end

--- Signed shortest way round from b to a, in (-pi, pi].
local function ArrowAngleDelta(a, b)
    local d = (a - b) % (2 * math.pi)
    if d > math.pi then d = d - 2 * math.pi end
    return d
end

--- Best available player position: the client's own where it can be had, the
--- server's otherwise.
local function ArrowWhere()
    local mx, my = ArrowMapPos()
    if mx then
        local dx, dy = ArrowDrift(mx, my)
        if dx and dx * dx + dy * dy <= ARROW_MAX_JUMP_YD * ARROW_MAX_JUMP_YD then
            return arrowSX + dx, arrowSY + dy
        end
    end
    return arrowSX, arrowSY
end

--- Aim the texture at (wx, wy). Safe to call every frame: the whole cost is a
--- map read, an atan2 and two comparisons unless the drawn angle really moved.
---
--- (!) `id` MUST CHANGE ON EVERY NEW ROUTE, NOT MERELY ON A NEW DESTINATION.
--- The near-target hold below belongs to the route it was measured on, and both
--- addons can be asked to route to the SAME place again -- /quest on the quest
--- already tracked, /nav on the boss already showing. Keyed on the destination
--- those read as "no change", so a heading held from the previous attempt would
--- carry over; keyed on the route it cannot. Both callers therefore pass a
--- counter bumped where the route is requested, not the target itself.
-- (!) ARROW COLOUR IS ARROW STATE, NOT TEXT STATE, AND IT IS AN UPVALUE FOR A
-- REASON. Refresh was split into a per-frame ArrowDraw and a change-gated
-- RefreshText, and the colour was left inside RefreshText -- so StartNav's dimmed
-- placeholder survived on any route where no text happened to change, showing a
-- dead grey arrow on a live route. RefreshText decides the colour; ArrowDraw
-- applies it every frame. Do NOT read `col` here: it is a local of RefreshText,
-- and referencing it from ArrowDraw silently reads a nil global and does nothing.
local arrowCol = COL_OK

local function ArrowDraw(tex, wx, wy, id)
    if not tex then return end

    -- (!) COLOUR FIRST, BEFORE EVERY EARLY RETURN BELOW. It does not depend on
    -- position or on the arrow having turned, and both guards below fire in the
    -- exact case this exists for: waiting for a route means no position fix yet,
    -- and the dead zone skips the redraw once the bearing settles. Applied after
    -- either, StartNav's grey placeholder stays up on a live route.
    tex:SetVertexColor(arrowCol[1], arrowCol[2], arrowCol[3])
    if id ~= arrowTarget then
        arrowTarget = id
        arrowHeld = nil
        arrowDrawn = nil
    end

    local ex, ey = ArrowWhere()
    -- Nothing has ever arrived, so there is nothing to point from. Callers gate
    -- on their own fix flag as well; this is the belt to that pair of braces,
    -- because a nil here would throw once per frame for the rest of the session.
    if not ex then return end

    local dx, dy = wx - ex, wy - ey
    local world
    if dx * dx + dy * dy > ARROW_NEAR_YD * ARROW_NEAR_YD or not arrowHeld then
        world = math.atan2(dy, dx)
        arrowHeld = world
    else
        world = arrowHeld
    end

    -- (!) THE FACING IS SUBTRACTED AFTER THE HOLD, NEVER FOLDED INTO IT. What is
    -- held near the target is the WORLD heading; the player's own facing is read
    -- fresh every frame, so turning on the spot still swings the arrow instantly
    -- even while the heading it is drawn from is being held steady.
    local rel = world - (GetPlayerFacing and GetPlayerFacing() or 0)
    if arrowDrawn and math.abs(ArrowAngleDelta(rel, arrowDrawn)) < ARROW_DEAD_RAD then
        return
    end
    arrowDrawn = rel
    RotateTexture(tex, rel)


end

--- One line for the diagnostic commands. Whether the client position is in use
--- is invisible on screen -- a stale arrow and a live one look identical until
--- you move -- so it has to be printable.
local function ArrowStatus()
    local mx = ArrowMapPos()
    local n = arrowFit and arrowFit.x.n or 0
    if not mx then
        return string.format("client position: OFF (no map position here)  map=%s samples=%d",
            tostring(arrowKey), n)
    end
    if not arrowKX or not arrowKY then
        return string.format("client position: LEARNING  map=%s samples=%d",
            tostring(arrowKey), n)
    end
    return string.format("client position: ON  map=%s samples=%d  scale %.0f / %.0f yd per map unit",
        tostring(arrowKey), n, arrowKX, arrowKY)
end
-- <<< NORG ARROW STABILISER ---------------------------------------------------

--- (!) HAS THE PANEL'S TEXT ACTUALLY CHANGED?
---
--- (!) THE ARROW IS REDRAWN EVERY FRAME AND THE WORDS ARE NOT, AND THAT SPLIT IS
--- THE POINT. The arrow has to keep up with the player turning, which is a frame
--- by frame thing; every word on the panel comes from a server packet, which
--- arrives three times a second. Rebuilding the caption in between re-ran
--- QuestTitles() -- a walk of the whole quest log calling GetQuestLink and a
--- pattern match on every entry -- at the client's frame rate, for a string that
--- could not have changed. Comparing the inputs instead is nine comparisons and
--- no allocation, so a player standing still with a settled route now does no
--- text work at all.
---
--- (!) THE QUEST TITLE IS NOT IN THE LIST, AND IT CANNOT BE. It is looked up
--- from the log, which is EMPTY for the first moment after login -- so the first
--- render says "Quest #4641" and no input below would ever change to correct it.
--- QUEST_LOG_UPDATE clears txTracked instead, which forces one rebuild.
local txTracked, txKind, txName, txType, txObj, txRoute, txLine, txStatus, txLeg

local function TextChanged()
    local o = objectives[tracked]
    local kind = o and o.kind or nil
    if tracked == txTracked and kind == txKind and targetName == txName
       and targetType == txType and targetObjective == txObj
       and routeYd == txRoute and lineYd == txLine
       and lastStatus == txStatus and legText == txLeg then
        return false
    end
    txTracked, txKind, txName, txType, txObj =
        tracked, kind, targetName, targetType, targetObjective
    txRoute, txLine, txStatus, txLeg = routeYd, lineYd, lastStatus, legText
    return true
end

--- (!) World angle is atan2(dy, dx). +X is NORTH and +Y is WEST, and the server
--- moves things with x += cos(angle), y += sin(angle), so 0 faces north and it
--- increases toward west -- the same convention GetPlayerFacing() reports in.
--- Negating dy mirrors the arrow left-to-right, which still looks like a working
--- arrow because it stays correct dead ahead and dead behind. That exact bug
--- shipped in NorgNav 1.0 and presented as a pathing fault.
---
--- (!) THE BEARING IS NO LONGER TAKEN FROM px, py. Those are the SERVER's idea of
--- where the player is, three times a second; ArrowDraw asks the stabiliser
--- above for the client's own position and falls back to px, py when it has
--- nothing better. See the block header for why that is the whole fix.
local function RefreshText()
    local col, hint = COL_OK, nil
    if lastStatus == "ok" then
        distFS:SetText(routeYd .. " yd")
    elseif lastStatus == "far" then
        distFS:SetText("~" .. lineYd .. " yd")
        hint = "long way -- the route sharpens as you close in"
    elseif lastStatus == "direct" or lastStatus == "bearing" then
        distFS:SetText("~" .. lineYd .. " yd")
        col = COL_SOFT
        hint = "straight line -- no walking route from here"
    elseif lastStatus == "blocked" then
        distFS:SetText(routeYd .. " yd")
        col = COL_SOFT
        hint = "heading as close as walking gets"
    else
        distFS:SetText("~" .. lineYd .. " yd")
        col = COL_HARD
        hint = "no route"
    end

    local o = objectives[tracked]
    local titles = QuestTitles()
    local title = titles[tracked] or ("Quest #" .. tracked)
    if o then
        -- (!) NAME THE TARGET WHEN WE KNOW IT. "go to" beside an arrow pointing at
        -- open ground tells the player nothing they cannot already see; "talk to
        -- Sputtervalve" tells them what to do when they arrive. Fall back to the
        -- bare kind word whenever the server sent no name, which is normal for an
        -- objective that is a PLACE rather than a thing (an area to explore).
        local what = KIND_WORD[o.kind] or "go to"
        -- (!) NEVER NAME ANYBODY ON A PLACE. targetType "a" means the destination
        -- is a PLACE -- an areatrigger, or the server's map-marker fallback --
        -- and there is nothing standing there to talk to, so any name that
        -- reaches us for one is wrong by construction. The server already sends
        -- an empty name for these; this is the second lock, because the failure
        -- mode is a confidently wrong instruction rather than a blank.
        --
        -- (!) THE kind == "p" HALF IS A THIRD LOCK AND IS NOT REDUNDANT. It
        -- catches the case where the letter and the name arrive from different
        -- places: targetName survives from whatever was tracked a moment ago if
        -- a G| for the new quest has not landed yet, and a map marker captioned
        -- with the last objective's NPC is exactly the Fargodeep Mine bug in a
        -- new disguise -- a real person, nowhere near where the arrow points.
        --
        -- (!) "m" MUST BE LISTED BESIDE "p" HERE. It is the same map marker drawn
        -- as one point instead of several -- exact, but still with nobody in it --
        -- and it is the MAJORITY of markers, so omitting it would not be a corner
        -- case: it would re-open the Fargodeep caption for most of them.
        if targetName and targetType ~= "a" and o.kind ~= "p" and o.kind ~= "m" then
            if targetType == "g" then
                what = "use " .. targetName
            elseif o.kind == "k" then
                what = "kill " .. targetName
            elseif o.kind == "t" then
                what = "turn in to " .. targetName
            elseif o.kind == "i" then
                what = "loot from " .. targetName
            elseif o.kind == "v" then
                what = "buy from " .. targetName
            else
                what = "talk to " .. targetName
            end
        end
        -- (!) A PLACE WITHOUT A PURPOSE IS HALF AN INSTRUCTION. "go to" beside an
        -- arrow is the same complaint as "go to" beside a name-less NPC: the
        -- player knows where and not what. The server sends the objective's own
        -- wording for a marker, so say it.
        --
        -- (!) APPENDED, NEVER SUBSTITUTED. The kind word is what CHANGE ONE is
        -- for -- it is the only thing that distinguishes a spot to walk to from a
        -- region to sweep -- so dropping it in favour of the text would undo the
        -- other half of this feature. It is also normal for there to be no text
        -- at all (most quests carry none, and a marker chosen for the quest as a
        -- whole has no single objective to quote), and the caption must read
        -- correctly in that case without a dangling separator.
        --
        -- (!) GATED ON THE MARKER KINDS, NOT PRINTED WHENEVER IT IS SET. The text
        -- describes the objective the SERVER could not place, and it arrives once
        -- per route while the Q| kind is refreshed every few seconds -- so in
        -- manual mode, where AutoTrack does not re-pick and Track therefore never
        -- runs to clear it, a quest whose objective becomes locatable flips to
        -- 'k' or 'i' while this string stays behind. Tying it to the letter it was
        -- sent for means it can only ever caption what it was written about.
        if targetObjective and (o.kind == "m" or o.kind == "p") then
            what = what .. " -- " .. targetObjective
        end
        nameFS:SetText(string.format("%s |cff808080(%s)|r", title, what))
    else
        nameFS:SetText(title)
    end
    -- The leg matters more than the routing status: it explains why the arrow is
    -- pointing at a dock rather than at your objective.
    if legText then hint = legText end

    arrowCol = col

    hintFS:SetText(hint or "")
end

--- Everything the panel does in one call. The arrow half runs on every frame;
--- the text half only when one of the things it prints has moved.
local function Refresh()
    if not tracked or not haveFix then return end
    ArrowDraw(arrow, wx, wy, routeGen)
    if TextChanged() then RefreshText() end
end

-- ------------------------------------------------------------------- routing

local function Sorted()
    local list = {}
    for id, o in pairs(objectives) do
        list[#list + 1] = { id = id, o = o }
    end
    -- Anything on this map beats anything that is not, whatever the numbers say:
    -- coordinates are per-map, so an objective in Northrend can score as twelve
    -- yards away from a player standing in Elwynn Forest.
    table.sort(list, function(a, b)
        if a.o.sameMap ~= b.o.sameMap then return a.o.sameMap end
        -- (!) SORT ON THE WEIGHTED DISTANCE, NOT THE TRUE ONE. This single line is
        -- what stopped a level-23 being routed to a 90xp grey simply because it was
        -- nearest. A quest the character has outlevelled is treated as several times
        -- further away than it is; a turn-in, or anything that gates further content,
        -- keeps its true distance. See NorgPlanQuestWeight on the server.
        return (a.o.sortDist or a.o.dist) < (b.o.sortDist or b.o.dist)
    end)
    return list
end

local function Track(questId)
    routeGen = routeGen + 1
    tracked = questId
    subscribed = true
    legText = nil
    -- (!) Clear the old name immediately. Holding it until the next G| arrives
    -- would caption the new objective with the previous quest's target, which is
    -- worse than saying nothing -- a confidently wrong name gets acted on.
    targetName = nil
    targetType = nil
    -- Same reason, same instant: the objective TEXT is per-quest too, and holding
    -- it would caption the new objective with what the last one was looking for.
    targetObjective = nil
    local o = objectives[questId]
    trackedKind = o and o.kind or nil
    trackedX = o and o.x or nil
    trackedY = o and o.y or nil
    haveFix = false
    Send("GO " .. questId)
    if frame then frame:Show() end
end

local function OnTaxi()
    return UnitOnTaxi and UnitOnTaxi("player") and true or false
end

local function AutoTrack()
    if not autoMode then return end
    if InInstanceNavCovers() then
        if frame then frame:Hide() end
        return
    end

    -- (!) NEVER RE-PICK WHILE ON A TAXI. This caused a real flight loop.
    --
    -- The server answers each objective with the spawn NEAREST THE PLAYER, so
    -- over a 1,600-yard flight the tracked objective's coordinates move much
    -- further than RETARGET_YARDS. That defeats the commit check below;
    -- AutoTrack then re-picks whatever is nearest the aircraft's CURRENT
    -- position, and if that is an objective back at the departure end the
    -- route says "fly to where you just came from". Landing there makes the
    -- original objective nearest again, so it sends you straight back: a
    -- stable two-node cycle that charges a fare each way.
    -- Reported live: Undercity -> The Sepulcher -> Undercity -> ...
    --
    -- Nothing chosen mid-flight is actionable anyway -- you cannot walk until
    -- you land, and the choice would be based on a point in the air the
    -- player never stands on. Decide once, on arrival, from where they are.
    if OnTaxi() then return end

    local list = Sorted()
    if #list == 0 then
        if frame then frame:Hide() end
        return
    end

    -- Only switch when the current pick is gone OR the objective for that quest
    -- has actually MOVED. Re-picking on every scan would make the arrow flip
    -- between two objectives that trade places as you walk.
    --
    -- (!) "quest still in the log" is NOT the same as "route still correct".
    -- The destination is snapshotted at GO time, so finishing an objective left
    -- the label updating to the turn-in while the arrow and yard count still
    -- described the walk to the mobs you had just finished killing.
    -- (!) COMMIT TO THE SPAWN WE PICKED. The server answers with the spawn
    -- NEAREST TO THE PLAYER, and creatures average 8.6 spawns each on the open
    -- world maps (one has 3,125). So simply walking makes a different spawn the
    -- nearest, the objective coordinates change, and an exact-match check treats
    -- that as a new objective and re-targets -- the arrow swings between
    -- neighbouring mobs of the same type instead of taking you to one of them.
    --
    -- Only a genuinely different objective is worth switching QUEST for: the
    -- KIND changing (kill -> turn in, say), or another quest becoming decisively
    -- better. A position that has moved is NOT one of those -- it means the
    -- thing we are already chasing has walked, so the answer is a fresh route to
    -- the same quest. See the broken-commit block below; conflating the two is
    -- what let the arrow abandon an escort mid-path.
    --
    -- (!) SO WHEN AN ESCORT COMPLETES, THE ARROW IS HANDED AWAY -- DECIDED, NOT
    -- OVERLOOKED. The kind flips 'e' -> 't', sameObjective goes false, the pick
    -- re-runs from scratch, and a nearer objective for some other quest wins even
    -- though the turn-in NPC is standing a few yards away. Left exactly as it is,
    -- for two reasons. A COMPLETED escort cannot be failed by walking off, unlike
    -- one in progress -- that is the whole hazard the broken-commit block below
    -- exists for, and it does not apply once credit is paid. And the promise this
    -- addon makes is "the nearest objective you can actually do": a turn-in you
    -- can already see is the one case a player does not need an arrow for. Holding
    -- the quest for an extra scan means adding a SECOND commitment rule, keyed on a
    -- kind change and a distance -- more commitment, which is the direction the
    -- stubbornness fault below came from, bought for something already in sight.
    if tracked and objectives[tracked] and subscribed then
        local o = objectives[tracked]
        local moved = trackedX and
            math.sqrt((o.x - trackedX) ^ 2 + (o.y - trackedY) ^ 2) or 1e9

        -- (!) COMMITMENT MUST NOT BECOME STUBBORNNESS.
        --
        -- The check below holds the current pick unless that objective moved or
        -- changed kind. It has no opinion about OTHER objectives, so an objective
        -- you are literally standing on can never take over: reported live,
        -- standing beside Deathguard Podrig in Silverpine while the arrow insisted
        -- on 1,673 yards back toward Tirisfal.
        --
        -- So allow an override, but only for a candidate that is not arguably
        -- better -- decisively better. Both tests must pass:
        --   * at least SWITCH_RATIO times closer, and
        --   * at least SWITCH_MIN_YARDS closer in absolute terms.
        -- The ratio stops two mid-distance objectives trading places as you walk
        -- between them; the absolute floor stops churn when both are already near.
        -- This cannot oscillate: once the near one is picked, the far one would
        -- have to become several times closer than something at your feet.
        local top = list[1]
        -- (!) AN OFF-MAP PICK MUST ALWAYS YIELD TO A SAME-MAP ONE.
        -- The ratio test below compares distances, which is only meaningful when
        -- both objectives are on the player's map -- coordinates are per-map, so a
        -- Kalimdor objective can score as twelve yards from Elwynn. But requiring
        -- the two to AGREE on sameMap (as this did) blocked the one case that
        -- matters most: you have just crossed to a new continent, the objective you
        -- were tracking is now off-map, and a real one is in front of you. The
        -- arrow kept pointing back at the zeppelin. Sorted() already ranks same-map
        -- first, so if the top candidate is on our map and the tracked one is not,
        -- that is a strict improvement and needs no distance comparison at all.
        local jump = false
        if top and top.id ~= tracked then
            if top.o.sameMap and not o.sameMap then
                jump = true
            elseif o.sameMap == top.o.sameMap then
                -- The commit check uses the SAME weighted number the sort used, or a
                -- grey quest could win the sort and then be held by a commit measured
                -- on a distance nothing else agreed with.
                jump = (o.sortDist or o.dist) > (top.o.sortDist or top.o.dist) * SWITCH_RATIO
                    and (o.sortDist or o.dist) - (top.o.sortDist or top.o.dist) > SWITCH_MIN_YARDS
            end
        end

        -- See EVENT_RETARGET_YARDS: a moving named NPC must not be committed to
        -- the way an interchangeable spawn cluster is.
        --
        -- (!) 'a' IS LEFT ON THE WIDE NUMBER ON PURPOSE, BUT NOT BECAUSE IT CANNOT
        -- MOVE. This used to read "an areatrigger never moves, so it can never
        -- trip either limit", and that is false. An individual trigger is fixed,
        -- but 8 of the 61 quests in areatrigger_involvedrelation on this world
        -- carry MORE THAN ONE, and the server answers with whichever is nearest
        -- the player -- so the reported position CAN change between scans, and by
        -- a long way. That is precisely the interchangeable-cluster shape
        -- RETARGET_YARDS was written for: any one of the triggers completes the
        -- objective, so swapping between them mid-walk is pure churn. Wide is
        -- right here for the same reason it is right for a kill objective, not
        -- because the case never arises.
        local commitYards = (o.kind == "e") and EVENT_RETARGET_YARDS or RETARGET_YARDS
        local sameObjective = (o.kind == trackedKind)
        if sameObjective and moved < commitYards and not jump then return end

        -- (!) A BROKEN COMMIT IS NOT AN INVITATION TO RE-PICK, AND TREATING IT AS
        -- ONE CAN FAIL AN ESCORT QUEST.
        --
        -- The commit above breaks for two quite different reasons, and they need
        -- opposite answers:
        --   the objective we are tracking MOVED   -> keep the quest, refresh the
        --                                            route to where it is now
        --   a rival became decisively better      -> re-run the pick (`jump`)
        -- Falling through to the pick in BOTH cases is what shortening the commit
        -- for 'e' actually bought: every EVENT_RETARGET_YARDS the escort walked,
        -- the arrow was handed back to whatever happened to be nearest. Measured:
        -- escort 1144 at 15 yd, a kill objective at 5 yd, escort moved 100 yd --
        -- the addon emitted "GO 2002" and abandoned Willix.
        --
        -- That is not a cosmetic regression. SmartAI drops an escort once the
        -- player is more than SMART_ESCORT_MAX_PLAYER_DIST (60) yards away, so
        -- following that arrow FAILS THE QUEST OUTRIGHT -- strictly worse than
        -- the backwards arrow the live position was added to fix.
        --
        -- `jump` deliberately still wins: it is the escape hatch that stops the
        -- arrow insisting on 1,673 yards away while you stand on an objective,
        -- and it needs both a ratio AND an absolute margin, so a rival that only
        -- looks better cannot trigger it.
        if sameObjective and not jump then
            Track(tracked)
            return
        end
    end
    Track(list[1].id)
end

local function Stop()
    tracked = nil
    haveFix = false
    if frame then frame:Hide() end
end

-- ------------------------------------------------------------ server replies

local function OnQuestMessage(msg)
    local kind = msg:match("^(%a)|")

    if kind == "Q" then
        -- Q|<id>:<kind>:<x>:<y>:<dist>:<sameMap>|... (several per message)
        -- (!) THE WEIGHT IS OPTIONAL IN THE PATTERN, ON PURPOSE. The server appends a
        -- seventh field, but a server that predates it must still parse -- and this is
        -- the addon that ships publicly, so it can meet an older module. `:?(%d*)`
        -- captures an empty string in that case and the fallback below reads 100.
        for id, k, x, y, d, same, w in
            msg:gmatch("(%d+):(%a):(%-?%d+):(%-?%d+):(%d+):([01]):?(%d*)") do
            local weight = tonumber(w) or 100
            if weight < 100 then weight = 100 end
            objectives[tonumber(id)] = {
                kind = k,
                x = tonumber(x), y = tonumber(y),
                dist = tonumber(d),
                sameMap = (same == "1"),
                -- (!) TWO DISTANCES, DELIBERATELY. `dist` is the truth and is what gets
                -- DISPLAYED; `sortDist` is what the arrow ARBITRATES on. Weighting the
                -- displayed number instead would have made /quest list report a grey
                -- quest as four times further away than it is.
                weight = weight,
                sortDist = tonumber(d) * weight / 100,
            }
        end
        return
    end

    if kind == "E" then
        AutoTrack()
        return
    end

    if kind == "F" then
        -- Server refused: the objective is on another map. Drop it so AutoTrack
        -- moves on rather than retrying a route that can never be built.
        local id = tonumber(msg:match("^F|(%d+)"))
        if id then
            objectives[id] = nil
            if tracked == id then tracked = nil; subscribed = false end
        end
        AutoTrack()
        return
    end

    -- G|<questId>|<c|g|a>|<name>[|<objective text>] -- the server routed us, and
    -- says what is there. The type letter is NOT the objective kind: 'c'
    -- creature, 'g' gameobject, 'a' a PLACE, which carries an empty name because
    -- there is nobody standing in it (see KIND_WORD and the second lock in
    -- Refresh). 'a' was added to the server and to the declaration at the top of
    -- this file but not to this line, which is how a reader ends up believing an
    -- areatrigger target is impossible.
    --
    -- (!) THE NAME IS MATCHED AS "([^|]*)", NOT "(.*)", AND THAT IS THE WHOLE
    -- PARSER CHANGE. The old pattern was greedy to the end of the line, so the
    -- moment a fifth field existed it would have been swallowed into the name --
    -- and since a marker sends an EMPTY name, the name would have become the
    -- objective text with a leading pipe, i.e. a caption. The server strips '|'
    -- from both fields, so a bounded match is exact rather than merely careful.
    --
    -- (!) THE FIFTH FIELD IS OPTIONAL AND ITS ABSENCE IS THE COMMON CASE. "|?"
    -- makes one pattern read BOTH the four-field form this addon has always
    -- received and the five-field one, so nothing has to know which server it is
    -- talking to. An absent field yields "", which is the same nil-out as an
    -- empty one -- there is no third state to get wrong.
    if kind == "G" then
        local id, typ, nm, obj = msg:match("^G|(%d+)|(%a)|([^|]*)|?(.*)$")
        if id and tonumber(id) == tracked then
            targetType = typ
            targetName = (nm and nm ~= "") and nm or nil
            targetObjective = (obj and obj ~= "") and obj or nil
        end
        return
    end

    -- X|<id>|<id>|... -- these quests are in your log but not in this server's
    -- quest_template, so there is no objective, no ender and no map marker to
    -- point at. Nothing else in this protocol can express that: a missing quest
    -- simply never appeared in Q|, which is indistinguishable from the addon
    -- being broken.
    --
    -- (!) SAID ONCE PER ID, NOT ONCE PER SCAN. A scan runs every few seconds and
    -- this fact can never change while the player is logged in, so without the
    -- seen table it would be a chat line every RESCAN_SECS forever.
    if kind == "X" then
        for id in msg:gmatch("(%d+)") do
            id = tonumber(id)
            if id and not reportedUnknown[id] then
                reportedUnknown[id] = true
                Say("quest #" .. id .. " is in your log but not on this server -- "
                    .. "nothing to point at. Abandon it if it bothers you.")
            end
        end
        return
    end

    if kind == "N" then
        -- Server could not resolve the one we asked for. Drop it so AutoTrack
        -- moves on instead of retrying the same dead end forever.
        local id = tonumber(msg:match("^N|(%d+)"))
        if id then
            objectives[id] = nil
            if tracked == id then tracked = nil end
        end
        AutoTrack()
        return
    end
end

local function OnNavMessage(msg)
    -- (!) HANDLE S| FRAMES. They were silently dropped, so when the server ended
    -- the route -- zoning out, or NorgNav taking the slot -- this addon never
    -- found out. `tracked` stayed set, OnUpdate kept re-rendering the last packet,
    -- and the arrow counter-rotated against the player s facing so it looked
    -- completely alive while pinned to a dead bearing.
    -- (!) A LEG line. The arrow alone would just point at a zeppelin tower with no
    -- explanation, which reads as a wrong answer when your objective is on another
    -- continent. Say what the tower is FOR.
    -- (!) An EMPTY L| is a CLEAR, and it matters. The server only used to send a
    -- leg when it had one, so when a plan stopped involving a flight or boat the
    -- old label just stayed on screen forever -- "Fly to Sepulcher" while standing
    -- in Sepulcher. Match .* here, not .+, so the empty form is handled.
    if msg == "L|" then
        legText = nil
        return
    end

    local leg = msg:match("^L|(.+)")
    if leg then
        legText = leg
        Say(leg .. " |cff808080(then it re-routes from the far side)|r")
        return
    end

    local state = msg:match("^S|(%a+)")
    if state then
        tracked = nil
        haveFix = false
        subscribed = false
        legText = nil
        if frame then frame:Hide() end
        if state == "stopped" then
            Say("NorgNav took over the arrow. /quest when you leave the dungeon.")
        end
        return
    end

    if not tracked then return end

    local a, b, c, d, e, f, st =
        msg:match("^P|([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)|(%a+)$")
    if not a then return end

    px, py = tonumber(a) or 0, tonumber(b) or 0
    wx, wy = tonumber(c) or 0, tonumber(d) or 0
    routeYd, lineYd = tonumber(e) or 0, tonumber(f) or 0
    lastStatus = st
    haveFix = true
    -- The stabiliser needs the raw server position AND the moment it arrived --
    -- pairing it with the map coordinate read right now is the whole calibration.
    ArrowFix(px, py)
    Refresh()
end

-- ---------------------------------------------------------------------- frame

local function Build()
    local f = CreateFrame("Frame", "NorgQuestFrame", UIParent)
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
        NorgQuestDB = NorgQuestDB or {}
        NorgQuestDB.pos = { p, rp, x, y }
    end)

    arrow = f:CreateTexture(nil, "OVERLAY")
    arrow:SetTexture("Interface\\Minimap\\MinimapArrow")
    arrow:SetWidth(52)
    arrow:SetHeight(52)
    arrow:SetPoint("TOP", f, "TOP", 0, -4)

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
ev:RegisterEvent("QUEST_LOG_UPDATE")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:RegisterEvent("ZONE_CHANGED_NEW_AREA")

ev:SetScript("OnEvent", function(_, event, ...)
    if event == "PLAYER_LOGIN" then
        frame = Build()
        NorgQuestDB = NorgQuestDB or {}
        if NorgQuestDB.pos then
            local p, rp, x, y = unpack(NorgQuestDB.pos)
            frame:ClearAllPoints()
            frame:SetPoint(p, UIParent, rp, x, y)
        end
        Say("v" .. VERSION .. " loaded. Tracks the nearest doable objective. /quest for commands.")
        scanAt = 3.0
        return
    end

    if event == "CHAT_MSG_ADDON" then
        local prefix, message = ...
        -- (!) DISPATCH ON MESSAGE KIND, NOT ON PREFIX.
        --
        -- The server now stamps the position stream with the prefix of whichever
        -- addon OWNS the route, so a quest route arrives as NORGQUEST. Routing by
        -- prefix therefore handed P| to the quest parser, which knows only Q/E/F/N
        -- and dropped it -- the frame appeared on track and then never updated,
        -- because haveFix stayed false forever. Symptom: an arrow that shows but
        -- points at nothing.
        --
        -- Kind is unambiguous across both channels, so switch on that and accept
        -- either prefix. This also means the two can never drift apart again.
        if prefix ~= QPREFIX and prefix ~= NPREFIX then return end

        local kind = message:match("^(%a)|") or message:match("^(%a)$")
        -- W| is the map line; it has its own module and its own redraw.
        if kind == "W" then
            if NorgQuest_OnMapChunk then NorgQuest_OnMapChunk(message) end
            return
        end

        if kind == "P" or kind == "L" or kind == "S" then
            OnNavMessage(message)
        else
            OnQuestMessage(message)
        end
        return
    end

    -- (!) QUEST_LOG_UPDATE FIRES IN BURSTS -- several times for one turn-in, and
    -- repeatedly while the log streams in at login. Rescanning on each one would
    -- send a chat line per event. Coalesce into a single delayed scan instead.
    scanAt = 1.0
    -- (!) AND FORCE ONE CAPTION REBUILD. The quest TITLE is read from the log, so
    -- the render that happens before the log has streamed in says "Quest #4641";
    -- nothing TextChanged() watches would ever differ afterwards, so without this
    -- the panel would carry that number until the tracked quest changed.
    txTracked = nil
end)

local wasOnTaxi = false
local rescanIn = 3

ev:SetScript("OnUpdate", function(_, elapsed)
    -- (!) RE-SCAN ON LANDING. Every distance in the objective list was
    -- measured from the departure end, so acting on it after a flight would
    -- route from a place the player left minutes ago. A zone change usually
    -- covers this, but a flight that lands in the SAME zone fires no such
    -- event -- and that is exactly the case this whole guard exists for.
    local onTaxi = OnTaxi()
    if wasOnTaxi and not onTaxi then
        objectives = {}
        scanAt = 0.5
    end
    wasOnTaxi = onTaxi

    -- Keep the objective list fresh; see RESCAN_SECS.
    rescanIn = rescanIn - elapsed
    if rescanIn <= 0 then
        rescanIn = RESCAN_SECS
        if subscribed or tracked then
            Send("SCAN")
        end
    end

    if scanAt > 0 then
        scanAt = scanAt - elapsed
        if scanAt <= 0 then
            scanAt = 0
            objectives = {}
            Send("SCAN")
        end
    end

    if not tracked or not haveFix then return end
    Refresh()
end)

-- -------------------------------------------------------------------- command

SLASH_NORGQUEST1 = "/quest"
SLASH_NORGQUEST2 = "/nq"
SlashCmdList["NORGQUEST"] = function(arg)
    arg = arg and arg:lower():gsub("^%s+", ""):gsub("%s+$", "") or ""

    if arg == "help" or arg == "?" then
        Say("/quest -- track the nearest objective you can actually do")
        Say("/quest list -- everything the server could resolve, nearest first")
        Say("/quest <text> -- track the quest whose title matches")
        Say("/quest off -- stop; /quest scan -- ask the server again")
        Say("/quest why -- print what the addon is tracking and why")
        Say("/quest arrow -- is the arrow using your own position or the server's")
        return
    end

    if arg == "arrow" then
        -- (!) THIS STATE IS INVISIBLE ON SCREEN. An arrow drawn from the client's
        -- own position and one drawn from a third-of-a-second-old server position
        -- look identical in a screenshot -- the difference only shows while you
        -- are moving, which is exactly when nobody can read a chat line. So it has
        -- to be printable, or "the arrow still wobbles" cannot be told apart from
        -- "the client position never engaged here".
        Say(ArrowStatus())
        return
    end

    if arg == "off" or arg == "stop" then
        autoMode = false
        Stop()
        Say("off. /quest to resume.")
        return
    end

    if arg == "why" then
        -- Diagnostic. "The arrow points somewhere wrong" is unfalsifiable from
        -- chat alone; this prints what the client actually believes so a report
        -- can be checked instead of guessed at.
        local list = Sorted()
        Say("tracked=" .. tostring(tracked) ..
            " kind=" .. tostring(trackedKind) ..
            " leg=" .. tostring(legText) ..
            " onTaxi=" .. tostring(OnTaxi()))
        if tracked and objectives[tracked] then
            local o = objectives[tracked]
            Say(string.format("  tracked obj: dist=%d sameMap=%s at %d,%d",
                o.dist, tostring(o.sameMap), o.x, o.y))
        end
        for i = 1, math.min(5, #list) do
            local e = list[i]
            Say(string.format("  %d. quest %d %s dist=%d sameMap=%s%s",
                i, e.id, e.o.kind, e.o.dist, tostring(e.o.sameMap),
                e.id == tracked and "  <== TRACKED" or ""))
        end
        return
    end

    if arg == "scan" then
        objectives = {}
        Send("SCAN")
        Say("rescanning.")
        return
    end

    if arg == "" or arg == "auto" or arg == "on" then
        autoMode = true
        tracked = nil
        AutoTrack()
        -- (!) SAY THE TRUE REASON. Inside a dungeon AutoTrack returns early because
        -- NorgNav owns the arrow, so `tracked` is nil for a reason that has nothing
        -- to do with resolution -- and "/quest scan to retry" sends the player to
        -- re-run a scan that cannot help. The nav-took-over line elsewhere only
        -- fires while NorgNav is stopped, so this branch is the one a player in an
        -- instance actually reaches.
        if not tracked then
            if InInstanceNavCovers() then
                Say("NorgNav has the arrow in here. /quest again once you are outside.")
            else
                Say("nothing resolvable right now. /quest scan to retry.")
            end
        end
        return
    end

    if arg == "mapdebug" then
        -- Bisects "no line on the map": does the CLIENT hold points, and does it
        -- think it may draw them? If there are no points the server is not sending
        -- usable ones; if there are points but nothing renders, it is the zone
        -- match or the overlay.
        local n = NorgQuest_MapPointCount and NorgQuest_MapPointCount() or -1
        Say("map points held: " .. n)
        if n > 0 and NorgQuest_MapFirstPoint then
            local z, x, y = NorgQuest_MapFirstPoint()
            Say(string.format("  first point: zone %s at %.3f, %.3f", tostring(z), x, y))
        end
        Say("  map open: " .. tostring(WorldMapFrame and WorldMapFrame:IsShown()))
        Say("  GetCurrentMapZone(): " .. tostring(GetCurrentMapZone and GetCurrentMapZone()))
        Say("  overlay built: " .. tostring(NorgQuest_MapOverlayExists and NorgQuest_MapOverlayExists()))
        if NorgQuest_RedrawMapLine then NorgQuest_RedrawMapLine() end
        Say("  dots shown after redraw: " .. tostring(NorgQuest_MapDotsShown and NorgQuest_MapDotsShown()))
        return
    end

    if arg == "list" then
        local titles = QuestTitles()
        local list = Sorted()
        if #list == 0 then Say("nothing resolved. /quest scan to retry.") return end
        for i = 1, math.min(#list, 12) do
            local e = list[i]
            Say(string.format("  %s |cff808080(%s, %s)|r",
                titles[e.id] or ("Quest #" .. e.id),
                KIND_WORD[e.o.kind] or "go to",
                e.o.sameMap and (e.o.dist .. " yd") or "another continent"))
        end
        return
    end

    local titles = QuestTitles()
    for id in pairs(objectives) do
        local t = titles[id]
        if t and t:lower():find(arg, 1, true) then
            autoMode = false
            Track(id)
            Say("tracking " .. t .. " |cff808080(manual -- /quest to resume)|r")
            return
        end
    end

    Say("no resolvable quest matching \"" .. arg .. "\". Try /quest list.")
end
