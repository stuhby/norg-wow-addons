-- Stub harness for NorgQuest. Loads the real addon against a fake 3.3.5a API and
-- drives the whole server conversation, including the parts that have no visible
-- symptom until they are wrong: quest-id extraction from the link, the same-map
-- sort, arrow rotation sign, and the instance hand-off to NorgNav.

local sent, chat = {}, {}
local texcoord, shown = nil, false
local frames = {}
local fontStrings = {}
-- (!) COUNTED, NOT ONLY CAPTURED. "the arrow was rotated" and "the arrow was
-- rotated AGAIN" are different questions, and the dead zone and the text split
-- can only be checked with the second one, because their entire job is to NOT do
-- work. Overwriting a single `texcoord` cannot tell those two apart.
local rotations, textWrites = 0, 0

local function newFrame(kind, name)
    local f = { _name = name, _scripts = {}, _events = {} }
    function f:SetScript(k, v) self._scripts[k] = v end
    function f:RegisterEvent(e) self._events[e] = true end
    for _, m in ipairs({ "SetWidth", "SetHeight", "SetPoint", "ClearAllPoints", "SetMovable",
                         "EnableMouse", "RegisterForDrag", "SetFrameStrata", "SetToplevel",
                         "StartMoving", "StopMovingOrSizing", "SetAllPoints" }) do
        f[m] = function() end
    end
    function f:GetPoint() return "CENTER", nil, "CENTER", 0, 0 end
    function f:Show() shown = true end
    function f:Hide() shown = false end
    function f:IsShown() return shown end
    function f:CreateTexture()
        return { SetTexture = function() end, SetWidth = function() end,
                 SetHeight = function() end, SetPoint = function() end,
                 SetVertexColor = function(_, r, g, b) _G._arrowCol = { r, g, b } end,
                 SetTexCoord = function(_, ...) texcoord = { ... } rotations = rotations + 1 end }
    end
    function f:CreateFontString()
        local fs = { SetPoint = function() end, SetWidth = function() end,
                 SetJustifyH = function() end,
                 SetText = function(s, t) s.text = t textWrites = textWrites + 1 end }
        table.insert(fontStrings, fs)
        return fs
    end
    table.insert(frames, f)
    if name then _G[name] = f end
    return f
end

-- A small fake quest log. The client has no questId lookup in 3.3.5a, so the
-- addon has to dig the id out of the LINK -- which is exactly what this models.
--
-- (!) "Errand For Nobody" IS IN THE LOG AND IS NEVER IN A Q| BATCH, ON PURPOSE.
-- Every other entry here is one the fake server also offers, so until it was
-- added this harness could not tell "the addon routes what the SERVER listed"
-- apart from "the addon routes what the LOG says" -- the two agreed on every id.
-- See the unlisted-quest section near the bottom for what it proves. Its title
-- shares no substring with the search words the other tests use ("lazy",
-- "vile"), so no existing match can pick it up by accident.
local QLOG = {
    { header = true, title = "Durotar" },
    { id = 4641, title = "Lazy Peons" },
    { id = 806,  title = "Vile Familiars" },
    { id = 5041, title = "Sarkoth" },
    { id = 8899, title = "Errand For Nobody" },
}

_G.CreateFrame = newFrame
_G.UIParent = newFrame("Frame", "UIParent")
_G.UnitName = function() return "Dotty" end
_G.GetPlayerFacing = function() return _G.__facing or 0 end
_G.SendChatMessage = function(msg) table.insert(sent, msg) end
_G.DEFAULT_CHAT_FRAME = { AddMessage = function(_, m) table.insert(chat, m) end }
_G.SlashCmdList = {}
_G.IsInInstance = function() return _G.__inInstance or false end

-- ------------------------------------------------- a fake zone map for the client
-- 3.3.5a hands the client its own position as a pair of 0..1 fractions of the
-- CURRENT ZONE MAP (GetPlayerMapPosition), and the addon has to work out for
-- itself how many world yards one of those fractions is worth. That means the
-- harness has to answer the question the way the client does -- consistently for
-- a zone, and NOT AT ALL in the places the real client refuses to.
--
-- (!) THE HARNESS CAN DO WHAT THE GAME CANNOT: SET THE TWO POSITIONS APART. The
-- world position in a P| packet is what the SERVER believes, three times a
-- second; mapWorldX/Y is where the CLIENT is right now. Splitting them is how a
-- test reproduces a moving player, which is the entire defect.
local ZONE_TOP, ZONE_LEFT, ZONE_H, ZONE_W = 1000, 500, 2000, 2000
local mapWorldX, mapWorldY = 0, 0
local mapBlind = false        -- as in a dungeon, or the map panned to another zone
local mapZoneId = 12

_G.GetCurrentMapContinent = function() return 1 end
_G.GetCurrentMapZone = function() return mapZoneId end
_G.SetMapToCurrentZone = function() end
_G.GetPlayerMapPosition = function(unit)
    -- (!) 0,0 IS WHAT THE REAL CLIENT RETURNS WHEN IT WILL NOT ANSWER -- inside
    -- an instance, or with the world map showing somewhere else. It is not a
    -- position, and an addon that treats it as one puts the player in the corner
    -- of the zone.
    if unit ~= "player" or mapBlind then return 0, 0 end
    return (ZONE_LEFT - mapWorldY) / ZONE_W, (ZONE_TOP - mapWorldX) / ZONE_H
end
local function clientAt(x, y) mapWorldX, mapWorldY = x, y end

_G.GetNumQuestLogEntries = function() return #QLOG, #QLOG - 1 end
_G.GetQuestLogTitle = function(i)
    local e = QLOG[i]
    if not e then return nil end
    return e.title, 10, nil, nil, e.header
end
_G.GetQuestLink = function(i)
    local e = QLOG[i]
    if not e or e.header then return nil end
    return string.format("|cff808080|Hquest:%d:10|h[%s]|h|r", e.id, e.title)
end

-- (!) GetAddOnMetadata IS REAL IN 3.3.5a -- Atlas 3.x calls it at file scope, see
-- ATLAS_VERSION in atlas-src/Atlas-3/Atlas/Atlas.lua -- but plain Lua has no such
-- global, so without this stub the addon's version line is a nil call the moment
-- it loads.
-- It READS THE ACTUAL .toc rather than returning a literal: a hardcoded answer
-- would keep passing for ever while the addon printed something else, which is
-- the exact drift the version line exists to stop.
_G.GetAddOnMetadata = function(folder, field)
    if field ~= "Version" then return nil end
    local f = io.open("/data/" .. folder .. "/" .. folder .. ".toc")
    if not f then return nil end
    local v
    for line in f:lines() do v = v or line:match("^##%s*Version:%s*(.-)%s*$") end
    f:close()
    return v
end
local TOC_VERSION = _G.GetAddOnMetadata("NorgQuest", "Version")

dofile("/data/NorgQuest/NorgQuest.lua")

local pass, fail = 0, 0
local function check(name, cond, detail)
    if cond then pass = pass + 1; print("  PASS  " .. name)
    else fail = fail + 1; print("  FAIL  " .. name .. "   " .. tostring(detail)) end
end

local ev
for _, f in ipairs(frames) do
    if f._events["CHAT_MSG_ADDON"] then ev = f end
end
check("registered for addon messages", ev ~= nil)

local function fire(e, ...) ev._scripts["OnEvent"](ev, e, ...) end
-- Every FontString the addon ever made, so a test can assert on what the panel
-- actually SAYS rather than on internal state that may or may not be rendered.
local function panelText()
    local out = {}
    for _, fs in ipairs(fontStrings) do
        if fs.text then out[#out + 1] = fs.text end
    end
    return table.concat(out, " ~ ")
end

local function tick(dt) ev._scripts["OnUpdate"](ev, dt) end
local function quest(msg) fire("CHAT_MSG_ADDON", "NORGQUEST", msg) end
local function nav(msg) fire("CHAT_MSG_ADDON", "NORGNAV", msg) end
local function lastSent() return sent[#sent] end
local function sentMatching(p)
    for i = #sent, 1, -1 do if sent[i]:find(p) then return sent[i] end end
end

-- Same shape as sentMatching, over the chat sink. Plain find (4th arg true) so a
-- message containing Lua pattern magic cannot silently fail to match.
local function chatMatching(p)
    for i = #chat, 1, -1 do if chat[i]:find(p, 1, true) then return chat[i] end end
end

fire("PLAYER_LOGIN")
check("built its frame", _G.NorgQuestFrame ~= nil)
check("login banner names the version FROM THE .toc",
      TOC_VERSION and chat[1] and chat[1]:find("v" .. TOC_VERSION, 1, true), chat[1])
check("and announces itself exactly ONCE", #chat == 1, #chat)

-- ========================================================= scan is coalesced
-- (!) QUEST_LOG_UPDATE fires in bursts -- several times for one turn-in, and
-- repeatedly while the log streams in at login. One chat line per event would be
-- a flood, so the addon must collapse them into a single delayed scan.
sent = {}
fire("QUEST_LOG_UPDATE"); fire("QUEST_LOG_UPDATE"); fire("QUEST_LOG_UPDATE")
check("a burst of log updates sends nothing yet", #sent == 0, #sent .. " sent")
tick(1.5)
check("coalesces the burst into ONE scan", #sent == 1 and sent[1] == "NORGQUEST SCAN",
      #sent .. " sent, last " .. tostring(lastSent()))

-- ================================================== objectives and the sort
-- Sarkoth is nearest by raw distance but on another map; Vile Familiars is the
-- nearest thing actually reachable.
sent = {}
quest("Q|4641:g:-618:-4251:340:1|806:k:-390:-4180:120:1|5041:k:100:200:12:0")
quest("E|3")
local go = sentMatching("^NORGQUEST GO ")
check("tracks after the scan completes", go ~= nil, lastSent())
check("prefers this map over a closer number on another map",
      go == "NORGQUEST GO 806", go)

-- ============================================================ arrow rotation
-- Waypoint 30 yards due WEST (+Y) with the player facing north is to their LEFT,
-- so the arrow must turn counterclockwise (+90 degrees). A mirrored arrow still
-- looks plausible -- it stays correct dead ahead and dead behind.
local function appliedAngle()
    if not texcoord then return nil end
    local ulx, uly = texcoord[1], texcoord[2]
    local c = -((ulx - 0.5) + (uly - 0.5))
    local s =  ((ulx - 0.5) - (uly - 0.5))
    return math.deg(math.atan2(s, c))
end

_G.__facing = 0
nav("P|0.00|0.00|0.00|30.00|412|282|ok")
local a = appliedAngle()
check("arrow points LEFT for a waypoint to the west", a and math.abs(a - 90) < 1,
      tostring(a) .. " deg, expected +90")

_G.__facing = 0
nav("P|0.00|0.00|0.00|-30.00|412|282|ok")
a = appliedAngle()
check("arrow points RIGHT for a waypoint to the east", a and math.abs(a + 90) < 1,
      tostring(a) .. " deg, expected -90")

-- ======================================================= unresolvable quest
sent = {}
quest("N|806")
local go2 = sentMatching("^NORGQUEST GO ")
check("drops a quest the server cannot resolve and moves on",
      go2 ~= nil and go2 ~= "NORGQUEST GO 806", go2)

-- ================================================= instance hand-off to Nav
-- (!) One server-side router means one arrow. NorgNav owns instances, NorgQuest
-- owns the open world; without this the two would fight over the same target and
-- whichever spoke last would win, leaving the other displaying a stale name.
_G.__inInstance = true
-- (!) CLEAR `chat` TOO, not just `sent`. It was last cleared before the login
-- banner, so a bare `#chat > 0` below was satisfied by the banner and passed even
-- with this branch's only Say() deleted.
sent = {}; chat = {}
SlashCmdList["NORGQUEST"]("")
check("does not auto-track inside an instance",
      sentMatching("^NORGQUEST GO ") == nil, tostring(lastSent()))
check("says why rather than failing silently",
      chatMatching("NorgNav has the arrow") ~= nil, chat[#chat])
_G.__inInstance = false

-- ==================================================================== commands
sent = {}; chat = {}
quest("Q|4641:g:-618:-4251:340:1|806:k:-390:-4180:120:1|5041:k:100:200:12:0")
quest("E|3")

chat = {}
SlashCmdList["NORGQUEST"]("list")
local joined = table.concat(chat, " | ")
check("/quest list resolves quest TITLES from the link, not raw ids",
      joined:find("Vile Familiars", 1, true) ~= nil, joined)
check("/quest list says when something is on another continent",
      joined:find("another continent", 1, true) ~= nil, joined)

sent = {}
SlashCmdList["NORGQUEST"]("lazy")
check("/quest <text> matches on the quest title",
      lastSent() == "NORGQUEST GO 4641", tostring(lastSent()))

sent = {}
SlashCmdList["NORGQUEST"]("off")
check("/quest off hides the arrow", not shown)

-- ============================================ the three review defects
-- (!) S| frames were dropped entirely, so when the server ended the route the
-- addon never knew: tracked stayed set, OnUpdate kept re-rendering the last
-- packet, and the arrow counter-rotated against facing so it looked alive while
-- pinned to a dead bearing.
-- (!) Re-arm AUTO mode. /quest off directly above disables it, and AutoTrack
-- returns before doing anything when auto is off -- so both checks below were
-- unreachable and passed against deliberately broken code.
SlashCmdList["NORGQUEST"]("")
quest("Q|4641:g:-618:-4251:340:1")
quest("E|1")
nav("P|0.00|0.00|0.00|30.00|412|282|ok")
check("draws while subscribed", shown)
nav("S|stopped")
check("stands down when the server hands the arrow to NorgNav", not shown)

-- (!) An objective on another map used to be routed as if it were local. The
-- server now refuses and answers F|; the addon must drop it and move on rather
-- than retrying a route that can never be built.
SlashCmdList["NORGQUEST"]("")
quest("Q|806:k:-390:-4180:120:1|4641:g:-618:-4251:340:1")
quest("E|2")
sent = {}
quest("F|806|1")
local after = sentMatching("^NORGQUEST GO ")
check("drops an off-map objective and routes to another",
      after ~= nil and after ~= "NORGQUEST GO 806", tostring(after))

-- ================================================ cross-continent travel leg
-- (!) The arrow points at a zeppelin TOWER, not at the objective. Without the
-- leg line that reads as a wrong answer, so the text is the feature.
SlashCmdList["NORGQUEST"]("")
quest("Q|4641:g:-618:-4251:340:1")
quest("E|1")
chat = {}
nav("L|take Zeppelin (The Thundercaller)")
local said = table.concat(chat, " | ")
check("announces the travel leg",
      said:find("Thundercaller", 1, true) ~= nil, said)

-- ============================================================== the drop leg
-- (!) THE ROUTER IS SHARED, SO THIS ADDON GETS DROPS WITHOUT ASKING FOR THEM --
-- and that is a claim worth asserting rather than assuming. There is ONE target
-- slot on the server and two commands that fill it, and InsertDropLeg is called
-- at both entry points precisely so a quest objective reached by stepping off a
-- ledge is captioned the same way a boss route is. If it were ever called at the
-- NorgNav entry point alone, nothing would fail loudly: quest routes would just
-- quietly walk the long way round.
--
-- (!) THE TEXT IS THE HAZARD. A drop caption carries a per cent sign and
-- brackets, which are Lua pattern metacharacters, so it is the one leg that
-- would break a parser doing pattern work on a leg. Asserted verbatim.
SlashCmdList["NORGQUEST"]("")
quest("Q|4641:g:-618:-4251:340:1")
quest("E|1")
chat = {}
local DROPLEG = "at the edge, drop down to the cavern floor (costs about 24% health)"
nav("L|" .. DROPLEG)
local droppedSaid = table.concat(chat, " | ")
check("announces a drop leg verbatim, percentage and brackets included",
      droppedSaid:find(DROPLEG, 1, true) ~= nil, droppedSaid)

-- ====================================== the stream arrives on the QUEST prefix
-- (!) The server stamps the position stream with the OWNING addon s prefix, so a
-- quest route arrives as NORGQUEST, not NORGNAV. Dispatching by prefix sent it to
-- the quest parser, which drops P| -- the arrow showed and never moved.
SlashCmdList["NORGQUEST"]("")
quest("Q|4641:g:-618:-4251:340:1")
quest("E|1")
texcoord = nil
_G.__facing = 0
quest("P|0.00|0.00|0.00|30.00|412|282|ok")   -- NOTE: NORGQUEST prefix
check("accepts the position stream under its OWN prefix",
      texcoord ~= nil, "arrow never rotated -- P| was dropped")

-- ============================== committing to a spawn, not chasing the nearest
-- (!) The server answers with the spawn NEAREST THE PLAYER and creatures average
-- 8.6 spawns each, so just walking makes a different one nearest. An exact-match
-- check re-targeted every scan and the arrow swung between neighbouring mobs.
SlashCmdList["NORGQUEST"]("")
quest("Q|4641:k:-600:-4200:340:1")
quest("E|1")
sent = {}
-- a nearby spawn of the SAME mob: must NOT re-target
quest("Q|4641:k:-560:-4180:300:1")
quest("E|1")
check("does not re-target for another spawn of the same mob",
      sentMatching("^NORGQUEST GO ") == nil, tostring(lastSent()))

-- a genuinely different objective: MUST re-target
sent = {}
quest("Q|4641:t:2000:3000:900:1")
quest("E|1")
check("does re-target when the objective genuinely changes",
      sentMatching("^NORGQUEST GO ") ~= nil, tostring(lastSent()))

-- ======================================================= a decisively better pick
-- (!) COMMITMENT MUST NOT BECOME STUBBORNNESS. The commit check only ever asked
-- whether the TRACKED objective changed, so an objective at the player's feet
-- could never take over. Reported live: standing beside Deathguard Podrig in
-- Silverpine while the arrow insisted on 1,673 yards back toward Tirisfal.
SlashCmdList["NORGQUEST"]("")
quest("Q|900:k:5000:5000:1673:1")
quest("E|1")
sent = {}
-- the same far objective, plus one the player is effectively standing on
quest("Q|900:k:5000:5000:1673:1|901:k:10:10:5:1")
quest("E|1")
check("switches to an objective you are standing on",
      sentMatching("^NORGQUEST GO 901") ~= nil, tostring(lastSent()))

-- ...but a merely somewhat-closer rival must NOT steal the pick, or the arrow
-- goes back to flip-flopping between two objectives as you walk between them.
SlashCmdList["NORGQUEST"]("")
quest("Q|910:k:100:100:1000:1")
quest("E|1")
sent = {}
quest("Q|910:k:100:100:1000:1|911:k:200:200:500:1")
quest("E|1")
check("does NOT switch for a merely somewhat-closer objective",
      sentMatching("^NORGQUEST GO ") == nil, tostring(lastSent()))
-- ============================================== the panel must NAME the target
-- (!) "go to" beside an arrow pointing at open ground tells the player nothing
-- they cannot already see. The server sends G|<id>|<c|g>|<name> so the panel can
-- say WHO is there. Reported live: the arrow correctly found Sputtervalve and the
-- panel still just said "go to".
SlashCmdList["NORGQUEST"]("")
-- (!) Clear the objective list first. Q| MERGES, so objectives left over from
-- earlier tests stay in the sort -- one of them sits 5 yards away and wins,
-- and this test then asserts against a completely different quest.
SlashCmdList["NORGQUEST"]("scan")
quest("Q|6981:e:100:200:50:1")
quest("E|1")
quest("G|6981|c|Sputtervalve")
nav("P|0.00|0.00|0.00|30.00|412|282|ok")
tick(0.2)
check("panel names a creature target",
      panelText():find("talk to Sputtervalve") ~= nil, panelText())

-- a gameobject is USED, not talked to
quest("G|6981|g|The Discs of Norgannon")
nav("P|0.00|0.00|0.00|30.00|412|282|ok")
tick(0.2)
check("panel says 'use' for a gameobject",
      panelText():find("use The Discs of Norgannon") ~= nil, panelText())

-- (!) A name from the PREVIOUS quest must never caption the next one.
SlashCmdList["NORGQUEST"]("")
SlashCmdList["NORGQUEST"]("scan")
quest("Q|900:k:5000:5000:1673:1")
quest("E|1")
nav("P|0.00|0.00|0.00|30.00|412|282|ok")
tick(0.2)
check("stale target name is cleared on a new pick",
      panelText():find("Sputtervalve") == nil, panelText())

-- ======================================= an areatrigger objective has nobody in it
-- (!) "Go to this place" objectives were captioned with a RANDOM NPC. The server
-- indexes areatrigger centres BY QUEST ID and the resolver copied that id into the
-- field a creature ENTRY belongs in, so the name lookup ran against
-- creature_template with a quest id: quest 62 (The Fargodeep Mine) rendered as
-- "talk to Gug Fatcandle", 437 (The Dead Fields) as "Blackrock Renegade", 870 (The
-- Forgotten Pools) as "Protector Deni". 38 of the 61 areatrigger quests on this
-- world collide with a creature entry that way. Kind 'a' now means "a place".
SlashCmdList["NORGQUEST"]("")
SlashCmdList["NORGQUEST"]("scan")
quest("Q|62:a:-9500:-1100:300:1")
quest("E|1")
quest("G|62|a|")
nav("P|0.00|0.00|0.00|30.00|412|282|ok")
tick(0.2)
check("an areatrigger objective reads as an explore instruction",
      panelText():find("explore") ~= nil, panelText())
check("...and never invents somebody to talk to",
      panelText():find("talk to") == nil, panelText())

-- (!) SECOND LOCK. Even handed a name for an 'a' target -- an older server, or a
-- future index that fills the entry in again -- the panel must refuse to print it,
-- because a confidently wrong instruction sends the player hunting for an NPC.
quest("G|62|a|Gug Fatcandle")
nav("P|0.00|0.00|0.00|30.00|412|282|ok")
tick(0.2)
check("refuses a name sent for a place",
      panelText():find("Gug Fatcandle") == nil, panelText())

-- ============================================ an escort NPC walks; follow him
-- (!) ESCORT QUESTS POINTED BACKWARDS. The server read the static spawn row, so
-- the arrow aimed at where the NPC had been standing before he set off. It now
-- reports his live position, but that is only half the fix: the 250-yard commit
-- below was written for interchangeable spawn clusters and would hold the stale
-- answer for most of the escort. An 'e' objective is usually one named NPC rather
-- than a crowd of interchangeable ones, so a shorter commit re-routes to where he
-- has walked instead of swinging between neighbours.
--
-- (!) THIS OBJECTIVE LIST HAS TWO ENTRIES ON PURPOSE AND THE SECOND ONE IS THE
-- WHOLE TEST. With a single objective in the list, "re-route to the same quest"
-- and "re-run the pick from scratch" are the same instruction, so a one-entry
-- list cannot tell a working addon from one that abandons the escort -- which is
-- exactly why the first version of this test passed against the bug. A kill
-- objective 5 yards away is not decisively better than an escort 15 yards away
-- (see SWITCH_RATIO), so it must NOT win.
SlashCmdList["NORGQUEST"]("")
SlashCmdList["NORGQUEST"]("scan")
quest("Q|1144:e:100:100:15:1")     -- Willix the Importer, at his spawn
quest("E|1")
sent = {}
quest("Q|1144:e:200:100:15:1|2002:k:50:50:5:1")   -- 100 yd along his path
quest("E|2")
check("re-routes to the SAME escort when the NPC walks away",
      sentMatching("^NORGQUEST GO ") == "NORGQUEST GO 1144", tostring(lastSent()))

-- ...and the walk must not stop happening. A second step forward has to keep
-- producing a fresh route, or the fix would be "hold the first answer for ever",
-- which is the backwards arrow again.
sent = {}
quest("Q|1144:e:300:100:15:1|2002:k:50:50:5:1")
quest("E|2")
check("keeps following him on the next step",
      sentMatching("^NORGQUEST GO ") == "NORGQUEST GO 1144", tostring(lastSent()))

-- (!) BUT A GENUINE JUMP MUST STILL RE-PICK. If a moved objective always kept
-- the arrow, the escape hatch that fixed "standing beside Deathguard Podrig
-- while the arrow insists on 1,673 yards away" would be gone. Here the escort is
-- 1,600 yards off and a kill objective is at the player's feet: decisively
-- better on BOTH tests, so it wins even though the tracked objective also moved.
SlashCmdList["NORGQUEST"]("")
SlashCmdList["NORGQUEST"]("scan")
quest("Q|1144:e:100:100:1600:1")
quest("E|1")
sent = {}
quest("Q|1144:e:200:100:1600:1|2003:k:50:50:5:1")
quest("E|2")
check("a decisively better objective still steals a MOVED escort",
      sentMatching("^NORGQUEST GO ") == "NORGQUEST GO 2003", tostring(lastSent()))

-- ...while a kill objective must STILL commit, or the arrow goes back to swinging
-- between neighbouring spawns of the same mob as you walk.
SlashCmdList["NORGQUEST"]("")
SlashCmdList["NORGQUEST"]("scan")
quest("Q|1145:k:100:100:30:1")
quest("E|1")
sent = {}
quest("Q|1145:k:200:100:60:1")
quest("E|1")
check("still commits to a spawn cluster for a kill objective",
      sentMatching("^NORGQUEST GO ") == nil, tostring(lastSent()))

-- ============================ the arrow moves on when the escort is COMPLETE
-- (!) THIS PINS A DECISION, NOT A BUG. When the escort finishes, the objective
-- kind flips 'e' -> 't' and the pick re-runs from scratch, so a nearer objective
-- takes the arrow even though the turn-in NPC is right there. AutoTrack explains
-- why that is wanted: a completed escort cannot be failed by walking off, and a
-- turn-in you can see is the one thing a player does not need an arrow for.
-- Anyone who changes this has to change that comment too.
SlashCmdList["NORGQUEST"]("")
SlashCmdList["NORGQUEST"]("scan")
quest("Q|1144:e:100:100:15:1")
quest("E|1")
sent = {}
quest("Q|1144:t:100:100:15:1|2006:k:50:50:5:1")
quest("E|2")
check("hands the arrow on once a completed escort becomes a turn-in",
      sentMatching("^NORGQUEST GO ") == "NORGQUEST GO 2006", tostring(lastSent()))
-- ================================= a map marker: a PIN is not a REGION
-- (!) BOTH SHAPES USED TO ARRIVE AS 'p' AND BOTH READ "search this area". On this
-- world the majority of markers that actually reach the fallback are ONE point --
-- an exact coordinate -- so the panel was telling players to go and hunt around
-- over an answer the server had already given them precisely. 'm' is that pin and
-- 'p' is now only the multi-point outline.
SlashCmdList["NORGQUEST"]("")
SlashCmdList["NORGQUEST"]("scan")
quest("Q|8490:m:8282:-7216:792:1")
quest("E|1")
quest("G|8490|a||Runestone Energized")
nav("P|0.00|0.00|0.00|30.00|412|282|ok")
tick(0.2)
check("a single-point marker reads as somewhere to GO, not an area to sweep",
      panelText():find("go to") ~= nil
      and panelText():find("search this area") == nil, panelText())

-- (!) THE OTHER HALF. An outline really IS a region and must keep the old
-- wording, or this change would simply move the wrong caption onto the 'p' cases
-- instead of removing it.
SlashCmdList["NORGQUEST"]("")
SlashCmdList["NORGQUEST"]("scan")
quest("Q|9303:p:-4484:-13651:1025:1")
quest("E|1")
quest("G|9303|a||Nestlewood Owlkin inoculated")
nav("P|0.00|0.00|0.00|30.00|412|282|ok")
tick(0.2)
check("a multi-point marker still reads as an area to search",
      panelText():find("search this area") ~= nil, panelText())

-- ====================================== a marker says WHAT you are looking for
-- (!) A LOCATION WITHOUT A PURPOSE IS HALF AN INSTRUCTION. The arrow was right
-- and the player still arrived at a hillside with nothing to act on. The server
-- now sends the quest's own wording for the objective it could not place.
check("...and says what the player is looking for when they arrive",
      panelText():find("Nestlewood Owlkin inoculated") ~= nil, panelText())

-- (!) THE KIND WORD MUST SURVIVE THE TEXT. Substituting the objective text for
-- the kind would silently undo the pin/outline split above -- the caption would
-- read the same for both shapes again.
check("the objective text is APPENDED to the kind word, not swapped for it",
      panelText():find("search this area %-%- Nestlewood Owlkin inoculated") ~= nil,
      panelText())

-- ===================================== an empty objective text shifts NOTHING
-- (!) MOST QUESTS CARRY NO ObjectiveText, and a marker chosen for the quest as a
-- whole has no single objective to quote either -- so ABSENT is the common case,
-- not the edge one. The server omits the field entirely, which makes the message
-- byte-identical to the four-field form this addon has always received. If the
-- parser mis-handled that, the NAME field would absorb the difference and every
-- later field would move by one.
SlashCmdList["NORGQUEST"]("")
SlashCmdList["NORGQUEST"]("scan")
quest("Q|118:m:-9457:88:12215:1")
quest("E|1")
quest("G|118|a|")                       -- four fields, exactly as before
nav("P|0.00|0.00|0.00|30.00|412|282|ok")
tick(0.2)
check("an absent objective text leaves a clean caption",
      panelText():find("go to") ~= nil
      and panelText():find(" %-%- ") == nil, panelText())

-- The five-field form with an EMPTY fifth field must behave identically. A
-- trailing separator is the other way this arrives and must not print a dangling
-- "--" either.
SlashCmdList["NORGQUEST"]("")
SlashCmdList["NORGQUEST"]("scan")
quest("Q|119:m:-9457:88:12215:1")
quest("E|1")
quest("G|119|a||")                      -- five fields, the last one empty
nav("P|0.00|0.00|0.00|30.00|412|282|ok")
tick(0.2)
check("an EMPTY objective text field is the same as no field at all",
      panelText():find("go to") ~= nil
      and panelText():find(" %-%- ") == nil, panelText())

-- (!) THE OLD FOUR-FIELD FORM STILL HAS TO PARSE FOR A NAMED TARGET. The name
-- match was tightened from "(.*)" to "([^|]*)" so a fifth field could exist; get
-- that wrong and every creature caption in the addon breaks at once, which is a
-- far bigger blast radius than the feature being added.
SlashCmdList["NORGQUEST"]("")
SlashCmdList["NORGQUEST"]("scan")
quest("Q|6981:e:100:200:50:1")
quest("E|1")
quest("G|6981|c|Sputtervalve")
nav("P|0.00|0.00|0.00|30.00|412|282|ok")
tick(0.2)
check("a four-field G| still names a creature",
      panelText():find("talk to Sputtervalve") ~= nil, panelText())

-- ==================================== a pin is PRECISE, but still has NOBODY in it
-- (!) THE FOURTH LOCK. 'm' is exact, which makes it tempting to treat as a
-- target -- but there is no entry behind it, so any name that reaches the client
-- for one is wrong by construction. This is the Fargodeep Mine bug aimed at the
-- MAJORITY of markers rather than a corner of them.
SlashCmdList["NORGQUEST"]("")
SlashCmdList["NORGQUEST"]("scan")
quest("Q|8490:m:8282:-7216:792:1")
quest("E|1")
quest("G|8490|a|Gug Fatcandle|Runestone Energized")
nav("P|0.00|0.00|0.00|30.00|412|282|ok")
tick(0.2)
check("refuses a name sent for a single-point marker",
      panelText():find("Gug Fatcandle") == nil, panelText())
check("...while still showing what to look for there",
      panelText():find("Runestone Energized") ~= nil, panelText())

-- (!) THE CASE ABOVE IS ALREADY CAUGHT BY THE targetType == "a" CLAUSE, so it
-- does NOT exercise the kind lock at all -- a copy of this file with the 'm' half
-- of that lock deleted passes it. This is the shape that genuinely needs it, and
-- it is the one the 'p' lock was written for in the first place: the LETTER and
-- the NAME arrive from different places and can disagree.
--
-- In MANUAL mode AutoTrack returns before re-picking, so Track never runs and
-- never clears the name -- while Q| keeps refreshing the kind underneath it. A
-- creature name captured when the objective was locatable therefore survives into
-- a marker, and captioning a hand-drawn map pin with a real NPC is precisely the
-- Fargodeep Mine bug: a person who exists, nowhere near where the arrow points.
local function staleNameOverMarker(markerKind)
    SlashCmdList["NORGQUEST"]("")
    SlashCmdList["NORGQUEST"]("scan")
    quest("Q|806:k:100:100:50:1")
    quest("E|1")
    SlashCmdList["NORGQUEST"]("vile")          -- manual: AutoTrack stops re-picking
    -- (!) A NAME THAT IS NOT A SUBSTRING OF THE QUEST TITLE. The panel prints the
    -- title too, so asserting on "Vile Familiar" against quest "Vile Familiars"
    -- matches the title and fails whatever the caption says.
    quest("G|806|c|Gug Fatcandle")             -- a real creature, with a real name
    quest("Q|806:" .. markerKind .. ":100:100:50:1")   -- kind flips under it
    quest("E|1")
    nav("P|0.00|0.00|0.00|30.00|412|282|ok")
    tick(0.2)
    return panelText()
end

local mText = staleNameOverMarker("m")
check("a stale creature name never captions a single-point marker",
      mText:find("Gug Fatcandle") == nil and mText:find("go to") ~= nil, mText)

local pText = staleNameOverMarker("p")
check("...nor an outline, which is the same lock one letter over",
      pText:find("Gug Fatcandle") == nil
      and pText:find("search this area") ~= nil, pText)

-- ============================== objective text must not outlive its own quest
-- (!) SAME FAILURE AS A STALE NAME, AND IT WAS ALREADY PROVEN TO MATTER FOR ONE.
-- Text left over from the previous pick is a confident instruction about the
-- wrong objective.
SlashCmdList["NORGQUEST"]("")
SlashCmdList["NORGQUEST"]("scan")
quest("Q|9303:p:-4484:-13651:1025:1")
quest("E|1")
quest("G|9303|a||Nestlewood Owlkin inoculated")
nav("P|0.00|0.00|0.00|30.00|412|282|ok")
tick(0.2)
SlashCmdList["NORGQUEST"]("")
SlashCmdList["NORGQUEST"]("scan")
quest("Q|9678:m:8033:-7525:400:1")
quest("E|1")
nav("P|0.00|0.00|0.00|30.00|412|282|ok")
tick(0.2)
check("a stale objective text is cleared on a new pick",
      panelText():find("Nestlewood") == nil, panelText())

-- (!) AND IT IS TIED TO THE MARKER LETTER IT WAS SENT FOR. In manual mode
-- AutoTrack never re-picks, so Track never runs to clear this -- yet the Q| kind
-- keeps refreshing. A quest whose objective becomes locatable flips to 'k' while
-- the text stays behind, and captioning a named kill with a marker's text is the
-- same class of confidently-wrong instruction.
SlashCmdList["NORGQUEST"]("")
SlashCmdList["NORGQUEST"]("scan")
quest("Q|9303:p:-4484:-13651:1025:1")
quest("E|1")
quest("G|9303|a||Nestlewood Owlkin inoculated")
nav("P|0.00|0.00|0.00|30.00|412|282|ok")
tick(0.2)
quest("Q|9303:k:-4484:-13651:1025:1")   -- same quest, now locatable
nav("P|0.00|0.00|0.00|30.00|412|282|ok")
tick(0.2)
check("marker text is dropped once the objective stops being a marker",
      panelText():find("Nestlewood") == nil, panelText())

-- ================================ an unknown kind still degrades to "go to"
-- (!) THE REASON 'm' IS THE NEW LETTER AND 'p' KEPT THE OLD ONE. A copy of this
-- addon that predates a letter renders KIND_WORD[k] or "go to" -- which is
-- exactly the wording a pin wants, so the majority of markers read correctly even
-- on a client that has never heard of 'm'. This pins the fallback itself.
SlashCmdList["NORGQUEST"]("")
SlashCmdList["NORGQUEST"]("scan")
quest("Q|9999:Z:100:100:50:1")
quest("E|1")
quest("G|9999|a|")
nav("P|0.00|0.00|0.00|30.00|412|282|ok")
tick(0.2)
check("an unrecognised kind letter still renders a sensible word",
      panelText():find("go to") ~= nil, panelText())

-- ==================== value beats raw distance (the Raptor Thieves defect)
-- (!) THE LIVE FAILURE THIS PINS: a level-23 with a full quest log was routed to
-- "Raptor Thieves" -- QuestLevel 13, ~90 xp, the most outlevelled quest they had --
-- purely because it was nearest. NorgQuest ranked on distance alone and had no idea
-- what a quest was worth.
--
-- The server now sends a weight as a SEVENTH field. Weight 600 = grey.
SlashCmdList["NORGQUEST"]("")
SlashCmdList["NORGQUEST"]("scan")
sent = {}
quest("Q|869:k:100:100:100:1:600|878:k:200:200:300:1:100")
quest("E|2")
check("a grey quest does NOT win on proximity alone",
      sentMatching("NORGQUEST GO 878") ~= nil, tostring(lastSent()))

-- ...but it still wins when nothing else is remotely close, because it is real work.
SlashCmdList["NORGQUEST"]("")
SlashCmdList["NORGQUEST"]("scan")
sent = {}
quest("Q|869:k:100:100:100:1:600|878:k:200:200:5000:1:100")
quest("E|2")
check("a grey quest still wins when it is the only sane option",
      sentMatching("NORGQUEST GO 869") ~= nil, tostring(lastSent()))

-- (!) A TURN-IN IS NEVER PENALISED. A completed grey quest is ten seconds of walking
-- for its whole reward, so the server sends weight 100 for kind 't' whatever its level.
SlashCmdList["NORGQUEST"]("")
SlashCmdList["NORGQUEST"]("scan")
sent = {}
quest("Q|869:t:100:100:100:1:100|878:k:200:200:300:1:100")
quest("E|2")
check("a grey TURN-IN keeps full priority",
      sentMatching("NORGQUEST GO 869") ~= nil, tostring(lastSent()))

-- A row with no weight at all (an older server) must behave exactly as before.
SlashCmdList["NORGQUEST"]("")
SlashCmdList["NORGQUEST"]("scan")
sent = {}
quest("Q|869:k:100:100:100:1|878:k:200:200:300:1")
quest("E|2")
check("a weightless row falls back to pure distance",
      sentMatching("NORGQUEST GO 869") ~= nil, tostring(lastSent()))

-- ============================ a NorgGuide pickup is just another task
-- (!) THE POINT OF THE WHOLE FEATURE IS THAT THIS NEEDS NO SPECIAL HANDLING. A quest
-- the player does not have yet arrives as kind 'n' in the same Q| batch as real
-- objectives and is arbitrated by the same nearest-first rule. If this ever grows its
-- own branch in AutoTrack, the design has drifted and the two addons are competing
-- again rather than sharing one queue.
--
-- The caption is asserted separately because it is the ONE thing that must differ:
-- the player is being sent to an NPC whose quest is NOT in their log, and the "go to"
-- fallback would send them hunting the quest list for something that is not there.
SlashCmdList["NORGQUEST"]("")
SlashCmdList["NORGQUEST"]("scan")
quest("Q|8888:n:100:100:40:1")
quest("E|1")
quest("G|8888|a|")
nav("P|0.00|0.00|0.00|30.00|412|282|ok")
tick(0.2)
check("a pickup task is captioned 'pick up', not 'go to'",
      panelText():find("pick up") ~= nil, panelText())

-- Nearest wins across BOTH kinds. This is the arbitration the operator asked for --
-- "they should both happen automatically and they both should complement each other"
-- -- so it is pinned in both directions rather than just the flattering one.
--
-- (!) ASSERT WHAT THE ADDON ASKED TO ROUTE TO, NOT WHAT THE PANEL SAYS. The panel
-- renders the last resolved-target G| message, so with no G| in the batch it keeps
-- displaying the PREVIOUS pick and reads as a pass or a fail for reasons that have
-- nothing to do with arbitration. The outgoing GO is the actual decision.
SlashCmdList["NORGQUEST"]("")
SlashCmdList["NORGQUEST"]("scan")
sent = {}
quest("Q|8889:n:100:100:40:1|806:k:-390:-4180:900:1")
quest("E|2")
check("a near pickup outranks a distant kill",
      sentMatching("NORGQUEST GO 8889") ~= nil, tostring(lastSent()))

SlashCmdList["NORGQUEST"]("")
SlashCmdList["NORGQUEST"]("scan")
sent = {}
quest("Q|7777:n:100:100:900:1|806:k:-390:-4180:40:1")
quest("E|2")
check("a distant pickup does NOT displace a near objective",
      sentMatching("NORGQUEST GO 806") ~= nil, tostring(lastSent()))

-- ==================================== /quest list knows about both marker kinds
SlashCmdList["NORGQUEST"]("")
SlashCmdList["NORGQUEST"]("scan")
quest("Q|8490:m:8282:-7216:792:1|9303:p:-4484:-13651:1025:1")
quest("E|2")
chat = {}
SlashCmdList["NORGQUEST"]("list")
local listed = table.concat(chat, " | ")
check("/quest list distinguishes a pin from an area",
      listed:find("go to", 1, true) ~= nil
      and listed:find("search this area", 1, true) ~= nil, listed)

-- ============================== THE ARROW IS AIMED FROM THE CLIENT'S POSITION
-- (!) THE DEFECT. The bearing used to be math.atan2(wy - py, wx - px), where
-- px,py came straight out of the last P| packet -- the SERVER's idea of where
-- the player is, refreshed every 333 ms (NAV_INTERVAL_MS, norg_nav.cpp). Between
-- packets the arrow was therefore drawn from where the player HAD been up to a
-- third of a second ago: a couple of yards on foot, several on a fast mount, and
-- near the aim point that offset swings the bearing hard. The player turns to
-- follow, the next packet moves the anchor, and it swings back. That is the
-- wobble, and it gets worse with speed because the lag is a time, not a distance.
--
-- (!) THE CHECKS BELOW ARE ONE ARGUMENT IN TWO HALVES, AND THE SECOND HALF IS
-- WRITTEN THE WAY IT IS ON PURPOSE. The obvious way to test the no-map case --
-- "with the map blind the answer equals the server bearing" -- IS A TEST THAT
-- CANNOT FAIL: when the harness reports no client position there is nothing in
-- the input for any implementation to disagree about, so it passes against
-- correct and broken code alike. It was written that way first and thrown out.
-- What replaces it drives the SERVER position instead and asserts the arrow
-- follows THAT, which a frozen or ignored anchor fails, plus a direct assertion
-- that the addon reports the client position as OFF there.
mapZoneId = 40                 -- a zone this suite has not walked: a clean fit
SlashCmdList["NORGQUEST"]("")
SlashCmdList["NORGQUEST"]("scan")
quest("Q|4641:k:0:20:30:1")
quest("E|1")
_G.__facing = 0

-- Teach it the scale. Each packet is one (map coordinate, world coordinate)
-- pair; the addon fits the yards per map unit across them. Nothing is
-- extrapolated until that fit has a long enough lever arm to be worth anything,
-- which is what the LEARNING check further down is about.
for i = 0, 11 do
    local wx0, wy0 = i * 36, i * 36
    clientAt(wx0, wy0)
    nav(string.format("P|%.2f|%.2f|0.00|20.00|412|282|ok", wx0, wy0))
end

chat = {}
SlashCmdList["NORGQUEST"]("arrow")
check("learns the zone scale from the packets themselves, with no shipped table",
      (chat[#chat] or ""):find("client position: ON", 1, true) ~= nil, chat[#chat])

-- The server's last word puts the player at the origin; the player then runs ten
-- yards north before the next packet. The aim point is twenty yards west.
--   from the STALE point (0,0):  atan2(20, 0)   =  90 deg
--   from where they really are:  atan2(20, -10) = 116.6 deg
clientAt(0, 0)
nav("P|0.00|0.00|0.00|20.00|412|282|ok")
clientAt(10, 0)
tick(0.05)
local ca = appliedAngle()
check("bearing follows the CLIENT, not the position in the last server packet",
      ca and math.abs(ca - 116.57) < 1.5,
      tostring(ca) .. " deg, expected ~116.6 (90 means it is still using the stale packet)")

-- No zone map at all: a dungeon, which is NorgNav's entire world, and also the
-- world map left showing another continent. The arrow must go back to being
-- driven by the server, exactly as it was before any of this -- so the SERVER
-- position is what moves here while the client stays put, which is the mirror
-- image of the check above.
mapBlind = true
clientAt(0, 0)
nav("P|0.00|0.00|0.00|20.00|412|282|ok")
local sa1 = appliedAngle()
nav("P|10.00|0.00|0.00|20.00|412|282|ok")
local sa2 = appliedAngle()
check("with no zone map the arrow is driven by the SERVER position, as before",
      sa1 and sa2 and math.abs(sa1 - 90) < 1 and math.abs(sa2 - 116.57) < 1.5,
      tostring(sa1) .. " then " .. tostring(sa2) .. " deg, expected +90 then ~116.6")

chat = {}
SlashCmdList["NORGQUEST"]("arrow")
check("...and says so, so \"it still wobbles in here\" is answerable",
      (chat[#chat] or ""):find("client position: OFF", 1, true) ~= nil, chat[#chat])
mapBlind = false

-- (!) A 0,0 READING MUST NOT BECOME A DATA POINT. It is not a position, and one
-- of them dropped into the fit is a huge outlier at the corner of the zone --
-- which would tilt the scale for every packet afterwards. Counted through
-- /quest arrow because the fit has no other visible surface.
chat = {}
SlashCmdList["NORGQUEST"]("arrow")
local nBefore = tonumber((chat[#chat] or ""):match("samples=(%d+)"))
mapBlind = true
for _ = 1, 5 do nav("P|0.00|0.00|0.00|20.00|412|282|ok") end
mapBlind = false
chat = {}
SlashCmdList["NORGQUEST"]("arrow")
local nAfter = tonumber((chat[#chat] or ""):match("samples=(%d+)"))
check("a 0,0 map reading is refused rather than fitted as a real sample",
      nBefore and nAfter and nAfter == nBefore,
      tostring(nBefore) .. " samples -> " .. tostring(nAfter))

-- ================================================= the swing near the aim point
-- (!) THE OTHER HALF OF THE WOBBLE, AND THE HALF A DUNGEON ALSO GETS. Close to
-- the aim point the bearing stops being information: a yard sideways swings it
-- tens of degrees, so the arrow spins during the one part of the trip that needs
-- no guidance. norg_nav.cpp aims 15-40 yards ahead precisely so this only
-- happens at the END of a route -- which is why holding the last good heading
-- there costs nothing.
clientAt(0, 0)
nav("P|0.00|0.00|0.00|20.00|412|282|ok")
tick(0.05)
local farA = appliedAngle()
clientAt(0, 22)          -- two yards PAST the aim point: the true bearing flips
tick(0.05)
local nearA = appliedAngle()
check("holds the last good heading once inside the near radius",
      farA and nearA and math.abs(nearA - farA) < 1,
      tostring(farA) .. " -> " .. tostring(nearA) .. " deg (a flip to -90 means no hold)")

clientAt(0, 30)          -- ten yards past it: far enough to mean something again
tick(0.05)
local pastA = appliedAngle()
check("...and lets go again as soon as the aim point is far enough to trust",
      pastA and math.abs(pastA + 90) < 1,
      tostring(pastA) .. " deg, expected -90 (a stuck +90 means the hold never releases)")

-- (!) A HELD HEADING BELONGS TO ONE ROUTE AND MUST NOT SURVIVE INTO THE NEXT.
-- The obvious key for that is the destination -- and it is the WRONG one, which
-- is why this check exists: /quest on the quest already being tracked asks for a
-- fresh route to the SAME quest id, so a destination-keyed reset sees no change
-- at all. Standing inside the near radius at that moment, the arrow would go on
-- showing a heading measured on the previous attempt. That is a confidently
-- wrong answer rather than a missing one, so it is keyed on the ROUTE instead.
--
-- Set up inside the hold, then re-track the same quest with the aim point moved.
clientAt(0, 0)
nav("P|0.00|0.00|0.00|20.00|412|282|ok")            -- aiming west: heading +90
clientAt(0, 19)                                     -- a yard short: inside the hold
tick(0.05)
SlashCmdList["NORGQUEST"]("lazy")                   -- re-track the SAME quest 4641
quest("P|0.00|19.00|3.00|19.00|412|282|ok")         -- new aim, still inside the hold
local reA = appliedAngle()
check("a fresh route to the same quest drops the heading held from the last one",
      reA and math.abs(reA) < 1,
      tostring(reA) .. " deg, expected 0 (a stuck +90 is the previous route's heading)")

-- ============================================================== the dead zone
-- (!) A TURN TOO SMALL TO SEE MUST NOT REACH THE TEXTURE. The arrow tip is 26
-- units from the centre and moves radius * angle, so a hundredth of a radian
-- moves it a fraction of a pixel. Pushing eight texture coordinates for that is
-- pure churn at the client's frame rate.
clientAt(0, 0)
nav("P|0.00|0.00|0.00|20.00|412|282|ok")
tick(0.05)
local r0 = rotations
_G.__facing = 0.005
tick(0.05)
check("a turn too small to see does not re-push the texture",
      rotations == r0, r0 .. " -> " .. rotations .. " rotations")
_G.__facing = 0.05
tick(0.05)
check("...but one that can be seen does",
      rotations > r0, r0 .. " -> " .. rotations .. " rotations")
_G.__facing = 0

-- ========================================= the panel's words are not per-frame
-- (!) EVERY WORD ON THE PANEL COMES FROM A SERVER PACKET, THREE TIMES A SECOND;
-- the arrow has to keep up with the player turning, which is per frame. Refresh
-- used to do both together, so QuestTitles() -- a walk of the whole quest log
-- calling GetQuestLink and a pattern match per entry -- ran at the frame rate to
-- rebuild a string that could not have changed. One rebuild writes three font
-- strings; ten frames of the old code wrote thirty.
local t0 = textWrites
for _ = 1, 10 do tick(0.02) end
check("does not rewrite the panel on every frame",
      textWrites - t0 <= 3, (textWrites - t0) .. " font-string writes over 10 frames")
local t1 = textWrites
nav("P|0.00|0.00|0.00|20.00|300|282|ok")     -- the yard count changed
check("...but does rewrite it the moment a number on it moves",
      textWrites > t1, (textWrites - t1) .. " writes after the distance changed")

-- ======================================= no steering on evidence it has not got
-- (!) A FIT FROM A SHORT LEVER ARM IS NOISE WITH A SLOPE. Until the samples span
-- enough of the map the scale is not determined, and using it anyway would
-- replace a known lag with an unknown error. The gate must also RELEASE, or it
-- would be a fit that never engages -- so both states are asserted here.
mapZoneId = 41                 -- another fresh zone: a fresh, empty fit
clientAt(0, 0)
nav("P|0.00|0.00|0.00|20.00|412|282|ok")
clientAt(1, 1)
nav("P|1.00|1.00|0.00|20.00|412|282|ok")
clientAt(2, 2)
nav("P|2.00|2.00|0.00|20.00|412|282|ok")
chat = {}
SlashCmdList["NORGQUEST"]("arrow")
check("will not steer by a scale three samples of standing still could not fix",
      (chat[#chat] or ""):find("LEARNING", 1, true) ~= nil, chat[#chat])

for i = 0, 11 do
    local wx0, wy0 = i * 36, i * 36
    clientAt(wx0, wy0)
    nav(string.format("P|%.2f|%.2f|0.00|20.00|412|282|ok", wx0, wy0))
end
chat = {}
SlashCmdList["NORGQUEST"]("arrow")
check("...and does engage once the samples cover enough ground",
      (chat[#chat] or ""):find("client position: ON", 1, true) ~= nil, chat[#chat])

-- ============================= the arrow code is shared with NorgNav VERBATIM
-- (!) THE TWO ADDONS HAVE ALREADY DRIFTED APART ONCE. NorgNav 1.0 shipped a
-- mirrored bearing and NorgQuest did not, so the identical arrow was right in a
-- dungeon and wrong outdoors -- and that is invisible in a screenshot, because a
-- mirrored arrow is still correct dead ahead and dead behind. The stabiliser is
-- the same code in both files, so this asserts it byte for byte rather than
-- trusting a comment that says so.
local function sharedBlock(path)
    local f = io.open(path)
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s:match("\n%-%- >>> NORG ARROW STABILISER.-\n%-%- <<< NORG ARROW STABILISER[^\n]*\n")
end
local qBlock = sharedBlock("/data/NorgQuest/NorgQuest.lua")
local nBlock = sharedBlock("/data/NorgNav/NorgNav.lua")
check("both addons carry the arrow stabiliser",
      qBlock ~= nil and nBlock ~= nil
        and qBlock:find("local function ArrowDraw", 1, true) ~= nil
        and nBlock:find("local function ArrowFix", 1, true) ~= nil,
      "NorgQuest=" .. tostring(qBlock ~= nil) .. " NorgNav=" .. tostring(nBlock ~= nil))
check("and the two copies are byte-identical",
      qBlock ~= nil and qBlock == nBlock,
      qBlock and nBlock and (#qBlock .. " vs " .. #nBlock .. " bytes") or "one of them is missing")

-- ============================ never route a quest the server did not itself list
-- (!) THIS IS THE CLIENT-SIDE HALF OF "ONLY ANSWER FOR A QUEST THAT IS ACTUALLY
-- HELD", AND IT IS WHY THE SERVER-SIDE HOLE WAS DIAGNOSTIC-ONLY.
--
-- Measured on the live server (2026-08-17), against a bot holding NEITHER quest
-- -- both counts are 0 in
--   SELECT COUNT(*) FROM acore_characters.character_queststatus s
--   JOIN acore_characters.characters c ON c.guid=s.guid
--   WHERE c.name='Andero' AND s.quest=<id>;
-- and yet:
--   .norgquest resolve Andero 976
--     -> NQ|976|ok|t|3663|0|0|1|1|3185.5|189.4|4.8|787.1|Delgren the Purifier|
--   .norgquest resolve Andero 62
--     -> NQ|62|ok|t|240|0|0|0|0|-9465.5|74.0|56.8|0.0|Marshal Dughan|
-- The server's resolver reads a missing quest-log slot as "no kills yet" and a
-- missing quest-status entry as "the event already happened", so an unheld quest
-- falls through to its turn-in NPC and comes back looking exactly like a real
-- answer. That is now refused with NQ|<id>|unheld.
--
-- It never reached PLAYERS only because this addon can only ever name an id the
-- SERVER put in a Q| batch, and the server builds those by walking its own quest
-- log slots. The quest LOG is emphatically not that list: QuestTitles() reads
-- every entry in it, including quests the server has declined to resolve and
-- quests it has never mentioned. A title match that fell back to the log -- an
-- easy and plausible-looking change, since that is where the titles come from --
-- would ask the server to route something it never offered, and until the gate
-- above it would have obliged. So this asserts the boundary directly rather than
-- trusting the comment that describes it.
sent = {}; chat = {}
SlashCmdList["NORGQUEST"]("scan")               -- drop whatever earlier sections left
quest("Q|4641:k:0:20:30:1")                     -- the server offers exactly one quest
quest("E|1")

sent = {}; chat = {}
SlashCmdList["NORGQUEST"]("errand")             -- a title in the LOG, never in a Q|
check("will not route a quest the server never listed",
      sentMatching("^NORGQUEST GO ") == nil, tostring(lastSent()))
check("...and says so rather than failing silently",
      chatMatching("no resolvable quest matching") ~= nil, chat[#chat])

sent = {}; chat = {}
SlashCmdList["NORGQUEST"]("list")
check("the listing is the server's answer, not the quest log",
      chatMatching("Lazy Peons") ~= nil and chatMatching("Errand For Nobody") == nil,
      chat[#chat])

-- (!) A REFUSAL HAS TO LEAVE THE TABLE, NOT JUST THE ARROW. Clearing `tracked`
-- alone would leave the quest in /quest list and re-selectable by title, so the
-- player could hand it straight back to the server that had just refused it --
-- and the server would answer, because the refusal is per-request and holds no
-- state. Both halves are checked, because only the second one is load-bearing
-- and only the first one is visible on screen.
sent = {}; chat = {}
quest("N|4641")                                 -- server: I cannot resolve that one
SlashCmdList["NORGQUEST"]("list")
check("a refused quest leaves the client's list, not just the arrow",
      chatMatching("Lazy Peons") == nil and chatMatching("nothing resolved") ~= nil,
      chat[#chat])

sent = {}; chat = {}
SlashCmdList["NORGQUEST"]("lazy")
check("...so it cannot be re-tracked by title afterwards",
      sentMatching("^NORGQUEST GO ") == nil
        and chatMatching("no resolvable quest matching") ~= nil, tostring(lastSent()))

-- =================================================================== garbage
local ok = pcall(function()
    quest("Q|")
    quest("Q|nonsense")
    quest("E|")
    quest("")
    nav("P|bad")
    nav("")
    -- Truncated and over-full G| frames. The name match is now bounded, so a
    -- frame with no name field at all, or with more separators than fields, must
    -- still fall out rather than throwing inside the parser.
    quest("G|")
    quest("G|8490")
    quest("G|8490|a")
    quest("G|8490|a|||")
end)
check("survives malformed server messages", ok)

print(string.format("\n  ==== %d passed, %d failed ====", pass, fail))
os.exit(fail == 0 and 0 or 1)
