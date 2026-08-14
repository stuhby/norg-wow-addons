-- Stub harness for NorgQuest. Loads the real addon against a fake 3.3.5a API and
-- drives the whole server conversation, including the parts that have no visible
-- symptom until they are wrong: quest-id extraction from the link, the same-map
-- sort, arrow rotation sign, and the instance hand-off to NorgNav.

local sent, chat = {}, {}
local texcoord, shown = nil, false
local frames = {}
local fontStrings = {}

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
                 SetVertexColor = function() end,
                 SetTexCoord = function(_, ...) texcoord = { ... } end }
    end
    function f:CreateFontString()
        local fs = { SetPoint = function() end, SetWidth = function() end,
                 SetJustifyH = function() end,
                 SetText = function(s, t) s.text = t end }
        table.insert(fontStrings, fs)
        return fs
    end
    table.insert(frames, f)
    if name then _G[name] = f end
    return f
end

-- A small fake quest log. The client has no questId lookup in 3.3.5a, so the
-- addon has to dig the id out of the LINK -- which is exactly what this models.
local QLOG = {
    { header = true, title = "Durotar" },
    { id = 4641, title = "Lazy Peons" },
    { id = 806,  title = "Vile Familiars" },
    { id = 5041, title = "Sarkoth" },
}

_G.CreateFrame = newFrame
_G.UIParent = newFrame("Frame", "UIParent")
_G.UnitName = function() return "Dotty" end
_G.GetPlayerFacing = function() return _G.__facing or 0 end
_G.SendChatMessage = function(msg) table.insert(sent, msg) end
_G.DEFAULT_CHAT_FRAME = { AddMessage = function(_, m) table.insert(chat, m) end }
_G.SlashCmdList = {}
_G.IsInInstance = function() return _G.__inInstance or false end
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

fire("PLAYER_LOGIN")
check("built its frame", _G.NorgQuestFrame ~= nil)

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
sent = {}
SlashCmdList["NORGQUEST"]("")
check("does not auto-track inside an instance",
      sentMatching("^NORGQUEST GO ") == nil, tostring(lastSent()))
check("says why rather than failing silently",
      #chat > 0)
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
-- =================================================================== garbage
local ok = pcall(function()
    quest("Q|")
    quest("Q|nonsense")
    quest("E|")
    quest("")
    nav("P|bad")
    nav("")
end)
check("survives malformed server messages", ok)

print(string.format("\n  ==== %d passed, %d failed ====", pass, fail))
os.exit(fail == 0 and 0 or 1)
