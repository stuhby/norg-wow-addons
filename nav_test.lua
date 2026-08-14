-- Stub harness for NorgNav: loads the REAL addon files against a fake 3.3.5a
-- API and drives the whole server conversation through them.
--
-- It cannot test rendering. It CAN test every part that has actually broken
-- before: the arrow's rotation sign, the message parsing, the auto-advance
-- ordering, and the alive/dead bookkeeping -- none of which are visible in a
-- screenshot until they are already wrong.

local sent = {}          -- everything the addon whispered to the server
local chat = {}          -- everything it printed
local texcoord = nil     -- last SetTexCoord call
local arrowShown = nil   -- last Show/Hide on the arrow texture
local shown = false

local frames = {}
local fontstrings = {}
local function newFrame(kind, name, parent)
    local f = { _name = name, _scripts = {}, _events = {}, _w = 0, _h = 0 }
    function f:SetFrameStrata() end
    function f:SetToplevel() end
    function f:EnableMouse() end
    function f:SetMovable() end
    function f:RegisterForDrag() end
    function f:SetScript(k, v) self._scripts[k] = v end
    function f:GetScript(k) return self._scripts[k] end
    function f:RegisterEvent(e) self._events[e] = true end
    function f:SetPoint() end
    function f:ClearAllPoints() end
    function f:SetAllPoints() end
    function f:SetWidth(w) self._w = w end
    function f:SetHeight(h) self._h = h end
    function f:GetWidth() return self._w end
    function f:GetHeight() return self._h end
    function f:GetPoint() return "CENTER", nil, "CENTER", 0, 0 end
    function f:StartMoving() end
    function f:StopMovingOrSizing() end
    function f:Show() shown = true end
    function f:Hide() shown = false end
    function f:IsShown() return shown end
    function f:CreateTexture()
        return {
            SetTexture = function() end,
            SetWidth = function() end, SetHeight = function() end,
            SetPoint = function() end,
            SetVertexColor = function() end,
            SetTexCoord = function(_, ...) texcoord = { ... } end,
            -- Captured because "no arrow at all" is a real rendering state now:
            -- an nr=1 entry has no coordinate to point at, and the whole point is
            -- that it must not draw one anyway.
            Show = function() arrowShown = true end,
            Hide = function() arrowShown = false end,
        }
    end
    function f:CreateFontString()
        -- Captured so the tests can assert what the UI actually SAYS. Without
        -- this the label checks were tautologies that passed regardless.
        local fs = {
            SetPoint = function() end, SetWidth = function() end,
            SetJustifyH = function() end,
            SetText = function(self2, t) self2.text = t end,
        }
        table.insert(fontstrings, fs)
        return fs
    end
    table.insert(frames, f)
    if name then _G[name] = f end
    return f
end

_G.CreateFrame = newFrame
_G.UIParent = newFrame("Frame", "UIParent")
_G.UnitName = function() return "Dotty" end
_G.GetPlayerFacing = function() return _G.__facing or 0 end
_G.SendChatMessage = function(msg) table.insert(sent, msg) end
_G.DEFAULT_CHAT_FRAME = { AddMessage = function(_, m) table.insert(chat, m) end }
_G.SlashCmdList = {}

dofile("/data/NorgNav/Data.lua")
dofile("/data/NorgNav/NorgNav.lua")

local pass, fail = 0, 0
local function check(name, cond, detail)
    if cond then pass = pass + 1; print("  PASS  " .. name)
    else fail = fail + 1; print("  FAIL  " .. name .. "   " .. tostring(detail)) end
end

-- the addon's event frame is the one that registered CHAT_MSG_ADDON
local ev
for _, f in ipairs(frames) do
    if f._events["CHAT_MSG_ADDON"] then ev = f end
end
check("registered for addon messages", ev ~= nil)

local function fire(event, ...) ev._scripts["OnEvent"](ev, event, ...) end
local function reply(msg) fire("CHAT_MSG_ADDON", "NORGNAV", msg) end
local function tick(dt) ev._scripts["OnUpdate"](ev, dt) end
local function lastSent() return sent[#sent] end
local function sentMatching(pat)
    for i = #sent, 1, -1 do if sent[i]:find(pat) then return sent[i] end end
end

-- ====================================================================== login
fire("PLAYER_LOGIN")
check("built its frame on login", _G.NorgNavFrame ~= nil)

-- ============================================================= map discovery
sent = {}
fire("PLAYER_ENTERING_WORLD")
check("asks the server where it is, never guesses from the zone name",
      lastSent() == "NORGNAV WHERE", lastSent())

-- Silence must be retried. The addon can finish loading before the server will
-- answer, which is exactly the "logged in already inside the dungeon and nothing
-- happened" report that started this.
sent = {}
tick(2.0)
check("retries WHERE when the server does not answer",
      lastSent() == "NORGNAV WHERE", lastSent())

-- Wailing Caverns
sent = {}
reply("M|43")
check("asks which bosses are already dead before routing",
      sentMatching("^NORGNAV ALIVE ") ~= nil, lastSent())

local aliveMsg = sentMatching("^NORGNAV ALIVE ")
local _, commas = aliveMsg:gsub(",", ",")
check("alive query carries every boss spawn id", commas == 6, aliveMsg)

-- =================================================== dead bosses are skipped
-- Anacondra (27366) down, Cobrahn (27380) unknown, the rest alive.
sent = {}
reply("A|27366:0|27380:?|27368:1|87107:1|87131:1|38148:1|33974:1")
local startMsg = sentMatching("^NORGNAV START ")
check("starts routing after the alive check", startMsg ~= nil, lastSent())
check("skips the boss the server says is dead",
      startMsg and startMsg:find("-151.10", 1, true) ~= nil, startMsg)

-- (!) '?' means "not loaded in the grid", which is the NORMAL answer for anything
-- on the far side of an instance. Treating it as dead would silently skip
-- encounters the player still has to fight.
check("does NOT treat unknown as dead",
      startMsg and not startMsg:find("36.80", 1, true), startMsg)

check("passes the spawn id so the server can report the kill",
      startMsg and startMsg:match("START [%-%d%.]+ [%-%d%.]+ [%-%d%.]+ (%d+)") == "27380", startMsg)

-- ================================================== position stream parsing
_G.__facing = 0
reply("P|0.00|0.00|0.00|30.00|412|282|ok")

-- ======================================================= ARROW ROTATION SIGN
-- This is the one that silently walks you into walls. +X is north and +Y is
-- WEST, so a corner at (0, +30) with the player facing north is to their LEFT
-- and the arrow must rotate counterclockwise, +90 degrees.
--
-- Recover the applied angle from the texture coordinates. The upper-left corner
-- is mapped to (0.5 - 0.5c + 0.5s, 0.5 - 0.5s - 0.5c), so the pair solves for
-- cos and sin directly.
local function appliedAngle()
    if not texcoord then return nil end
    local ulx, uly = texcoord[1], texcoord[2]
    local c = -((ulx - 0.5) + (uly - 0.5))
    local s =  ((ulx - 0.5) - (uly - 0.5))
    return math.deg(math.atan2(s, c))
end

local a = appliedAngle()
check("arrow points LEFT for a waypoint to the west while facing north",
      a and math.abs(a - 90) < 1, tostring(a) .. " deg, expected +90")

-- Same corner, but the player has turned to face west: it is now dead ahead.
_G.__facing = math.pi / 2
reply("P|0.00|0.00|0.00|30.00|412|282|ok")
a = appliedAngle()
check("arrow points UP once you face the waypoint",
      a and math.abs(a) < 1, tostring(a) .. " deg, expected 0")

-- And a corner to the EAST while facing north must go RIGHT.
_G.__facing = 0
reply("P|0.00|0.00|0.00|-30.00|412|282|ok")
a = appliedAngle()
check("arrow points RIGHT for a waypoint to the east",
      a and math.abs(a + 90) < 1, tostring(a) .. " deg, expected -90")

-- ============================================= server reports the boss died
sent = {}
reply("S|dead")
local nextStart = sentMatching("^NORGNAV START ")
check("advances to the next boss when the server reports a kill",
      nextStart ~= nil and nextStart:find("-64.40", 1, true) ~= nil, nextStart)

-- ================================================================= commands
sent = {}; chat = {}
SlashCmdList["NORGNAV"]("list")
check("/nav list shows every boss", #chat >= 7, #chat .. " lines")

sent = {}
SlashCmdList["NORGNAV"]("skum")
local manual = sentMatching("^NORGNAV START ")
check("/nav <name> routes to that boss", manual and manual:find("-285.60", 1, true) ~= nil, manual)

sent = {}
SlashCmdList["NORGNAV"]("next")
check("/nav next moves on without needing a kill",
      sentMatching("^NORGNAV START ") ~= nil, lastSent())

-- (!) Debug must be useful in BOTH states. Before the first position packet
-- arrives there is nothing to report, and a version that printed one bare line
-- and stopped looked exactly like a broken command -- which is the opposite of
-- what a diagnostic is for.
sent = {}; chat = {}
SlashCmdList["NORGNAV"]("debug")
check("/nav debug explains itself before the first position arrives",
      #chat >= 2 and table.concat(chat, " "):find("waiting", 1, true) ~= nil,
      table.concat(chat, " | "))

_G.__facing = 0
reply("P|10.00|20.00|40.00|20.00|150|30|ok")
sent = {}; chat = {}
SlashCmdList["NORGNAV"]("debug")
local dbg = table.concat(chat, " | ")
check("/nav debug reports a cardinal direction to eyeball against the minimap",
      #chat >= 3 and dbg:find(" N of you", 1, true) ~= nil, dbg)

sent = {}
SlashCmdList["NORGNAV"]("off")
check("/nav off stops the stream", lastSent() == "NORGNAV STOP", lastSent())
check("/nav off hides the frame", not shown)

-- ============================== script-spawned finals (approach entries)
-- (!) Mutanus has NO creature row anywhere, so he was omitted entirely and a
-- cleared Wailing Caverns ended with "all bosses down" while the final fight
-- was still ahead. He is now carried as an APPROACH entry pointing at Naralex,
-- and the UI has to say that -- an unlabelled arrow to an empty room reads as
-- a broken addon.
sent = {}; chat = {}
SlashCmdList["NORGNAV"]("mutanus")
local mu = sentMatching("^NORGNAV START ")
-- (!) Assert against the DATA, not a literal coordinate. Hard-coding it failed
-- the moment the point was refined from Naralex's spawn to the verified escort
-- end -- reporting a routing bug when the routing was right and the test stale.
-- Second time this exact mistake bit; check the data, never a magic number.
local wcAp
for _, b in ipairs(NorgNavBosses[43]) do if b.ap then wcAp = b end end
check("routes to the event trigger, not the absent boss",
      wcAp and mu and mu:find(string.format("%.2f", wcAp.x), 1, true) ~= nil,
      tostring(wcAp and wcAp.x) .. "  ||  " .. tostring(mu))
check("sends spawn id 0 -- the trigger NPC must not be death-checked",
      mu and mu:match("START [%-%d%.]+ [%-%d%.]+ [%-%d%.]+ (%d+)") == "0", mu)
-- (!) The trigger WALKS. Naralex is a SmartAI escort with three waypoints, so a
-- fixed coordinate is right only until the event starts. tg tells the server to
-- follow his live position; it must be the spawn id, and it must NOT be sent as
-- the death-check id, which would mark the encounter done immediately.
-- (!) tg must be 0 here. The escort ends AT this point, so the target is already
-- correct and static. Following the trigger live would reverse the arrow the
-- moment he walks past the player.
check("does NOT live-follow the trigger",
      mu and mu:match("START [%-%d%.]+ [%-%d%.]+ [%-%d%.]+ %d+ (%d+)") == "0", mu)

_G.__facing = 0
reply("P|100.00|240.00|110.00|240.00|20|18|ok")
local labels = {}
for _, fs in ipairs(fontstrings) do if fs.text then table.insert(labels, fs.text) end end
local allText = table.concat(labels, " | ")
check("labels it as an event start, not as the boss",
      allText:find("Start:", 1, true) ~= nil, allText)
-- (!) Assert against the DATA, not a literal string. The first version hard-coded
-- the wording and failed the moment the note was corrected -- reporting a UI bug
-- when the UI was right and only the test was stale.
local wcNote
for _, b in ipairs(NorgNavBosses[43]) do if b.ap then wcNote = b.t end end
check("shows the helper text explaining why the boss is not there",
      wcNote and wcNote ~= "" and allText:find(wcNote, 1, true) ~= nil,
      tostring(wcNote) .. "  ||  " .. allText)

chat = {}
SlashCmdList["NORGNAV"]("list")
local lst = table.concat(chat, " | ")
check("/nav list marks the event start",
      lst:find("event start", 1, true) ~= nil, lst)

-- ================================================ the all-clear must not spam
-- (!) The 20-second alive poll re-enters AutoRoute whenever there is no target,
-- which is permanently true once every boss is dead -- so this message reprinted
-- itself every 20 seconds for the rest of the run.
reply("M|0")
reply("M|43")
local allDead = {}
for _, b in ipairs(NorgNavBosses[43]) do
    if b.g and b.g > 0 then table.insert(allDead, b.g .. ":0") end
end
-- mark the event-trigger entry down too, via the combat log
reply("A|" .. table.concat(allDead, "|"))
fire("COMBAT_LOG_EVENT_UNFILTERED", 0, "UNIT_DIED", 0, 0, 0, 0, "Mutanus the Devourer")
-- (!) Re-arm AUTO mode first. An earlier /nav <name> in this file left the addon
-- in manual mode, and AutoRoute returns immediately when auto is off -- so the
-- message under test was unreachable and the check passed either way.
SlashCmdList["NORGNAV"]("auto")

chat = {}
-- (!) The poll alone proves nothing -- the spam happens in the REPLY handler.
-- An earlier version of this test only ticked the clock, so no A| ever arrived,
-- AutoRoute was never re-entered, and it passed with the guard removed. Answer
-- every poll the way the server would.
for i = 1, 6 do
    tick(21)
    reply("A|" .. table.concat(allDead, "|"))
end
local allClear = 0
for _, m in ipairs(chat) do
    if m:find("routable boss here is down", 1, true) then allClear = allClear + 1 end
end
check("announces the all-clear ONCE, not on every poll", allClear <= 1,
      allClear .. " times across six polls")

-- ====================================================== leaving the instance
sent = {}
fire("PLAYER_ENTERING_WORLD")
check("asks again after zoning", lastSent() == "NORGNAV WHERE", lastSent())

-- A map with no boss data must fail quietly rather than error.
local ok = pcall(function() reply("M|0") end)
check("handles a map it has no data for", ok)

-- Malformed server lines must not throw. Nothing hostile can reach this channel,
-- but a version skew between addon and module absolutely can.
ok = pcall(function()
    reply("P|garbage")
    reply("A|")
    reply("")
    reply("Z|what")
    reply("P|0|0|0|0|0|0|")
end)
check("survives malformed server messages", ok)

-- (!) STATE LEAKS BETWEEN BLOCKS IN THIS FILE, so from here on every block
-- starts by moving to a DIFFERENT map (SetMap returns immediately when the id
-- has not changed, which silently skips the setup), sends a FULL A| list rather
-- than a partial one (A| MERGES -- it only touches the ids it names, so a short
-- list leaves earlier marks standing), and re-arms auto mode when it needs it.
local function panelText()
    local labels = {}
    for _, fs in ipairs(fontstrings) do
        if fs.text then table.insert(labels, fs.text) end
    end
    return table.concat(labels, " | ")
end
local function fmt(v) return string.format("%.2f", v) end

-- ============================ instances where NOTHING can be death-checked
-- (!) Routing used to be started ONLY by the A| reply, and AskAlive sends
-- nothing at all when no entry has a spawn id to ask about. Four instances are
-- entirely script-spawned -- Black Morass, Old Hillsbrad, Culling of Stratholme
-- and Trial of the Crusader -- so the addon announced the boss count and then
-- sat there forever with no arrow and nothing in the log to explain it.
sent = {}; chat = {}
reply("M|269")                                  -- Black Morass, 3 entries, all g=0
local bmStart = sentMatching("^NORGNAV START ")
check("routes an instance where no boss can be death-checked",
      bmStart ~= nil, table.concat(sent, " | "))
check("does not send an empty ALIVE query for one",
      sentMatching("^NORGNAV ALIVE ") == nil, table.concat(sent, " | "))
check("and routes to the first entry of it",
      bmStart and bmStart:find(fmt(NorgNavBosses[269][1].x), 1, true) ~= nil,
      tostring(bmStart))

-- ================================= g=0 is a SENTINEL, not a spawn id
-- (!) 57 of the 418 entries carry g=0 because there is no creature to
-- death-check, and twelve instances hold two or more. While `dead` was keyed by
-- b.g, marking one of them down set dead[0] and marked EVERY one of them down at
-- once -- permanently, because AskAlive only ever asks about g>0. Gundrak has
-- two: Drakkari Elemental (2nd) and Eck the Ferocious (4th).
sent = {}; chat = {}
reply("M|604")                                  -- Gundrak
reply("A|127042:0|127043:0|127044:1")           -- both real bosses ahead of Eck down
local elemental = NorgNavBosses[604][2]
local eck       = NorgNavBosses[604][4]
local gunStart  = sentMatching("^NORGNAV START ")
check("harness sanity: routing to the first script-spawned Gundrak entry",
      gunStart and gunStart:find(fmt(elemental.x), 1, true) ~= nil, tostring(gunStart))

sent = {}
fire("COMBAT_LOG_EVENT_UNFILTERED", 0, "UNIT_DIED", 0, 0, 0, 0, elemental.n)
local afterKill = sentMatching("^NORGNAV START ")
check("killing one g=0 boss does not mark the other g=0 boss down",
      afterKill and afterKill:find(fmt(eck.x), 1, true) ~= nil,
      "expected " .. fmt(eck.x) .. " (" .. eck.n .. "), got " .. tostring(afterKill))

chat = {}
SlashCmdList["NORGNAV"]("list")
local eckLine
for _, m in ipairs(chat) do
    if m:find(eck.n, 1, true) then eckLine = m end
end
check("/nav list does not show the untouched g=0 boss as down",
      eckLine ~= nil and not eckLine:find("(down)", 1, true), tostring(eckLine))

-- ================================== entries that cannot be routed to at all
-- (!) nr=1 means there is no coordinate, not that we have not found one yet: the
-- Trial of the Crusader arena floor is a destructible gameobject with no navmesh
-- under it, so those three entries are x=y=z=0. Zero is WORLD ORIGIN, so routing
-- to them pointed the arrow confidently at the middle of the map -- the exact
-- thing README.txt says is worse than no arrow.
sent = {}; chat = {}
arrowShown = nil
reply("M|649")                                  -- Trial of the Crusader
local toc = NorgNavBosses[649]
check("does not route to an entry marked unroutable",
      sentMatching("^NORGNAV START ") == nil, table.concat(sent, " | "))
check("still shows the panel for it", shown)
check("hides the arrow instead of aiming it at world origin",
      arrowShown == false, tostring(arrowShown))
local tocText = panelText()
check("names the boss it cannot route to",
      tocText:find(toc[1].n, 1, true) ~= nil, tocText)
check("shows the data's own explanation of why there is no arrow",
      toc[1].t and tocText:find(toc[1].t, 1, true) ~= nil, tocText)

-- A stale packet from the route this entry replaced must not repaint over it.
texcoord = nil
reply("P|0.00|0.00|0.00|30.00|412|282|ok")
check("ignores a position packet while showing an unroutable entry",
      texcoord == nil, "the arrow was rotated anyway")

sent = {}
for k = 1, 3 do
    fire("COMBAT_LOG_EVENT_UNFILTERED", 0, "UNIT_DIED", 0, 0, 0, 0, toc[k].n)
end
local anub = sentMatching("^NORGNAV START ")
check("advances through them and routes to the one that does have a coordinate",
      anub and anub:find(fmt(toc[4].x), 1, true) ~= nil,
      "expected " .. fmt(toc[4].x) .. " (" .. toc[4].n .. "), got " .. tostring(anub))
check("puts the arrow back for a routable boss", arrowShown == true, tostring(arrowShown))

-- ========================================= S|<word> the addon did not expect
-- (!) The server sends S|stopped to the PREVIOUS owner when NorgQuest takes the
-- single per-player target slot. That word used to fall straight through the S|
-- handler, leaving target and haveFix set with no stream behind them: OnUpdate
-- kept calling Refresh() 20x/sec, so the arrow went on counter-rotating against
-- live facing while pinned to a dead position, and the 20s poll could never
-- recover because it only re-routes when there is no target.
local ALL_ALIVE = "A|27366:1|27380:1|27368:1|87107:1|87131:1|38148:1|33974:1"
reply("M|0")
sent = {}; chat = {}
reply("M|43")                                   -- Wailing Caverns
reply(ALL_ALIVE)
_G.__facing = 0
reply("P|0.00|0.00|0.00|30.00|412|282|ok")
texcoord = nil
reply("P|0.00|0.00|0.00|-30.00|412|282|ok")
check("harness sanity: a position packet moves the arrow while routing",
      texcoord ~= nil, "nothing was rendered, so the checks below prove nothing")

-- (!) AND THE ACK OF OUR OWN START MUST NOT CANCEL IT. A blanket "any S|<word>
-- clears everything" passes the stopped check below and silently kills every
-- route the instant it begins -- the server answers S|started to every START.
reply("S|started")
texcoord = nil
reply("P|0.00|0.00|0.00|30.00|412|282|ok")
check("S|started does not cancel the route it acknowledges",
      texcoord ~= nil and shown, "texcoord=" .. tostring(texcoord ~= nil) ..
      " shown=" .. tostring(shown))

sent = {}; chat = {}
reply("S|stopped")
check("S|stopped takes the panel down", not shown)
texcoord = nil
reply("P|0.00|0.00|0.00|-30.00|412|282|ok")
check("S|stopped stops the arrow being redrawn from a dead route",
      texcoord == nil, "still rotating against live facing")
tick(0.1)
check("and OnUpdate does not redraw it either", texcoord == nil, "OnUpdate still rendering")
check("says the arrow went elsewhere rather than going quiet",
      table.concat(chat, " "):find("took the arrow", 1, true) ~= nil,
      table.concat(chat, " | "))

-- (!) It must not take the slot straight back, or the two addons fight over it.
sent = {}
for k = 1, 3 do
    tick(21)
    reply(ALL_ALIVE)
end
check("does not grab the arrow back from the other addon on the next poll",
      sentMatching("^NORGNAV START ") == nil, tostring(lastSent()))

sent = {}
SlashCmdList["NORGNAV"]("")
check("/nav takes the arrow back when the player asks",
      sentMatching("^NORGNAV START ") ~= nil, tostring(lastSent()))

-- Any other word means no stream is coming either, whatever it meant.
sent = {}; chat = {}
reply("S|badargs")
check("an unrecognised S| word also takes the panel down instead of freezing it",
      not shown)

-- ================================ a kill while a boss was picked by hand
-- (!) /nav <name> sets autoMode=false, and AutoRoute returns immediately while
-- it is off -- so nothing ever hid the frame when that boss died. It sat there
-- showing the dead boss's name over the yard count from the last packet, and the
-- server had already dropped the subscription, so nothing was coming to fix it.
sent = {}; chat = {}
SlashCmdList["NORGNAV"]("kresh")
check("harness sanity: the manual pick is actually routing",
      shown and sentMatching("^NORGNAV START ") ~= nil, tostring(lastSent()))
reply("P|0.00|0.00|0.00|30.00|412|282|ok")

sent = {}; chat = {}
reply("S|dead")
check("a kill in manual mode takes the panel down instead of freezing it",
      not shown, "the frame is still showing a dead boss")
check("and stops the server stream", lastSent() == "NORGNAV STOP", tostring(lastSent()))
check("and still reports the kill",
      table.concat(chat, " "):find("is down", 1, true) ~= nil, table.concat(chat, " | "))

-- (!) Leave the addon in AUTO. An earlier /nav <name> left this file in manual
-- mode once already and made a later check unreachable, so it passed either way.
SlashCmdList["NORGNAV"]("auto")

print(string.format("\n  ==== %d passed, %d failed ====", pass, fail))
os.exit(fail == 0 and 0 or 1)
