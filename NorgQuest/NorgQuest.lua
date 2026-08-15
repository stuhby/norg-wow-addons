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

--- (!) World angle is atan2(dy, dx). +X is NORTH and +Y is WEST, and the server
--- moves things with x += cos(angle), y += sin(angle), so 0 faces north and it
--- increases toward west -- the same convention GetPlayerFacing() reports in.
--- Negating dy mirrors the arrow left-to-right, which still looks like a working
--- arrow because it stays correct dead ahead and dead behind. That exact bug
--- shipped in NorgNav 1.0 and presented as a pathing fault.
local function Refresh()
    if not tracked or not haveFix then return end

    local rel = math.atan2(wy - py, wx - px) - (GetPlayerFacing and GetPlayerFacing() or 0)
    RotateTexture(arrow, rel)

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

    arrow:SetVertexColor(col[1], col[2], col[3])

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

    hintFS:SetText(hint or "")
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
        return a.o.dist < b.o.dist
    end)
    return list
end

local function Track(questId)
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
                jump = o.dist > top.o.dist * SWITCH_RATIO
                    and o.dist - top.o.dist > SWITCH_MIN_YARDS
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
        for id, k, x, y, d, same in msg:gmatch("(%d+):(%a):(%-?%d+):(%-?%d+):(%d+):([01])") do
            objectives[tonumber(id)] = {
                kind = k,
                x = tonumber(x), y = tonumber(y),
                dist = tonumber(d),
                sameMap = (same == "1"),
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
