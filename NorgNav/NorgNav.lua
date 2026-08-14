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

-- Server statuses. See mod-norg-nav.
--   ok       complete walkable route; the route distance is exact
--   far      walkable prefix, goal past the search horizon (should not occur --
--            the server's budget was measured to cover every route in the game)
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
local dead = {}             -- [boss entry] = true
local bySpawn = {}          -- [spawnId] = { entry, ... }; only ever g > 0
local target                -- { i, n, x, y, z, g }
local autoMode = true
local lastStatus = "ok"
local haveFix = false
local px, py, wx, wy = 0, 0, 0, 0
local routeYd, lineYd = 0, 0
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

    local total = #bosses
    if total > 0 and target.i then
        -- (!) An APPROACH entry is not the boss -- it is the place the encounter
        -- starts. Labelling it plainly would send the player looking for a mob
        -- that does not exist yet and make the arrow look wrong when they arrive
        -- to an empty room.
        nameFS:SetText(string.format("%s%s  |cff808080(%d of %d)|r",
            target.ap and "|cffffd100Start:|r " or "", target.n, target.i, total))
    else
        nameFS:SetText(target.n)
    end

    -- The approach note explains why you are being sent somewhere the boss is
    -- not, so it matters more than any routing status and takes precedence.
    if target.ap then
        hint = target.t ~= "" and target.t or "walk here to trigger the encounter"
    end

    hintFS:SetText(hint or "")
end

-- ------------------------------------------------------------------- routing

local function StopNav(silent)
    target = nil
    haveFix = false
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
    -- player, so a stream left running would go on pushing P| for a boss that is
    -- no longer on screen -- and its S|dead would be credited to THIS entry.
    if target then Send("STOP") end
    target = b
    haveFix = false

    if frame then
        arrow:Hide()
        distFS:SetText("no route")
        local total = #bosses
        if total > 0 and b.i then
            nameFS:SetText(string.format("%s  |cff808080(%d of %d)|r", b.n, b.i, total))
        else
            nameFS:SetText(b.n)
        end
        hintFS:SetText((b.t and b.t ~= "") and b.t
            or "no map data here -- stay with the group")
        frame:Show()
    end
end

local function StartNav(b)
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
    if frame then
        arrow:Show()   -- an nr=1 entry hides it, so put it back
        frame:Show()
    end
end

local function CountDead()
    local n = 0
    for _, b in ipairs(bosses) do if dead[b] then n = n + 1 end end
    return n
end

local function NextBoss()
    for _, b in ipairs(bosses) do
        if not dead[b] then return b end
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
            Say("every routable boss here is down.")
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
    target = nil
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
        px, py = tonumber(a) or 0, tonumber(b) or 0
        wx, wy = tonumber(c) or 0, tonumber(d) or 0
        routeYd, lineYd = tonumber(e) or 0, tonumber(f) or 0
        lastStatus = st
        haveFix = true
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
            -- (!) An nr=1 entry never had a subscription, so a kill report can
            -- only belong to the route it replaced. Crediting it here would mark
            -- the WRONG boss down; the 20-second ALIVE poll catches the real one.
            if target and target.nr then return end
            if target then
                dead[target] = true
                Say(target.n .. " is down.")
                TargetFinished()
            else
                AutoRoute()
            end
        elseif state == "leftmap" then
            target = nil
            haveFix = false
            if frame then frame:Hide() end
        elseif state == "started" then
            -- The acknowledgement of our OWN START. The subscription we just
            -- asked for is live, so there is nothing to undo here -- clearing
            -- would cancel every route the instant it began.
        elseif state == "stopped" then
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
        Say("loaded. Routes automatically in dungeons. /nav next to skip, /nav off, /nav help.")
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
                        Say(b.n .. " is down. |cff808080(" .. #bosses - CountDead() ..
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

    if not target or not haveFix then return end
    acc = acc + elapsed
    if acc < 0.05 then return end
    acc = 0
    Refresh()
end)

-- -------------------------------------------------------------------- command

SLASH_NORGNAV1 = "/nav"
SlashCmdList["NORGNAV"] = function(arg)
    arg = arg and arg:lower():gsub("^%s+", ""):gsub("%s+$", "") or ""

    if arg == "help" or arg == "?" then
        Say("/nav -- resume automatic routing in encounter order")
        Say("/nav next -- skip the current boss (behind a door, or you want another)")
        Say("/nav <name> -- route to one boss and stay on it")
        Say("/nav list -- what is here and what is already down")
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
        if not mapId then Send("WHERE") else AskAlive(); AutoRoute() end
        return
    end

    if arg == "next" or arg == "skip" then
        if target then
            dead[target] = true        -- treat as done for this run, without killing it
            Say("skipping " .. target.n .. ".")
            target = nil
        end
        autoMode = true
        AutoRoute()
        return
    end

    if arg == "list" then
        if #bosses == 0 then Say("nothing routable here.") return end
        for _, b in ipairs(bosses) do
            Say(string.format("  %d. %s%s%s", b.i, b.n,
                b.ap and "  |cffffd100(event start)|r" or "",
                dead[b] and "  |cff808080(down)|r" or ""))
        end
        return
    end

    if arg == "debug" then
        Say(string.format("map=%s bosses=%d status=%s fix=%s",
            tostring(mapId), #bosses, lastStatus, tostring(haveFix)))
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
