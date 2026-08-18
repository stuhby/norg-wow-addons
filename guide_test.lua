-- Stub harness for NorgGuide.
--
-- Loads the REAL addon against a fake 3.3.5a API and drives the whole server
-- conversation through the same buttons and slash commands a player uses.
--
-- (!) WHAT THIS IS ACTUALLY GUARDING. The defects below are all invisible in a
-- screenshot, and several of them shipped in 1.0 and were caught only by an audit
-- that mutation-tested this very file. Where an assertion exists because a real
-- mutation survived, it says so.
--
--   1. ROW REUSE. Row 3 is a different quest after every /guide. A Refresh that
--      stamped the quest id only once keeps firing the FIRST listing's quest while
--      displaying the current name.
--   2. STALE ROWS ACROSS REPLIES. No "begin" marker exists in the protocol, so a
--      shorter second listing must not leave the tail of the first on screen, and a
--      hidden row must not keep its quest id -- the rows are globally named
--      NorgGuideRow1..10 and a /click macro fires them.
--   3. THE TITLE FIELD is the whole remainder, not the eleventh field.
--   4. ROUTABILITY IS AN EXPLICIT WIRE FIELD. 1.0 inferred it from `map ~= 0`, and
--      map 0 is Eastern Kingdoms -- 1,939 quests. It also wrote the flag on the
--      button and read it off the row, so EVERY row rendered dimmed and the
--      "unroutable row is dimmed" assertion passed vacuously. Both directions are
--      asserted now.
--   5. A POPULATED ROW MUST BE VISIBLE. Deleting btn:Show() left the old suite
--      30/30 green. So did `if r.routable then btn:Show() end` -- the naive shape of
--      the map-0 fix, which silently drops every unroutable quest despite the addon
--      documenting the opposite as deliberate.
--   6. THE PREFIX GUARD. NorgQuest emits E|, G| and X| on the same channel this
--      addon listens on, and both ship together.
--   7. THE TRANSPORT IS A SELF-WHISPER. The server swallows on the prefix alone and
--      ignores the chat type, so a SAY regression is invisible in live play too --
--      until the module is absent and /guide broadcasts to everyone in range.
--
-- Run from the addon root:
--     docker run --rm -v "$PWD:/data" nickblah/lua:5.1-luarocks lua /data/guide_test.lua

local sent, chat = {}, {}
local frames, byName = {}, {}

-- ------------------------------------------------------------ client API stubs
local function newRegion()
    local r = { _shown = true, text = nil, _alpha = 1 }
    function r:SetPoint() end
    function r:SetWidth(w) self._width = w end
    function r:SetHeight(h) self._height = h end
    function r:GetWidth() return self._width end
    function r:GetHeight() return self._height end
    function r:SetJustifyH() end
    function r:SetTexture() end
    function r:SetTexCoord() end
    function r:SetVertexColor() end
    function r:SetBlendMode() end
    function r:SetAllPoints() end
    function r:SetAlpha(a) self._alpha = a end
    function r:GetAlpha() return self._alpha end
    function r:SetText(t) self.text = t end
    function r:GetText() return self.text end
    function r:Show() self._shown = true end
    function r:Hide() self._shown = false end
    function r:IsShown() return self._shown end
    return r
end

local function newFrame(kind, name, parent, template)
    local f = newRegion()
    f._kind, f._name, f._template, f._parent = kind, name, template, parent
    f._scripts, f._events = {}, {}
    f._shown = true
    function f:SetScript(k, v) self._scripts[k] = v end
    function f:GetScript(k) return self._scripts[k] end
    function f:RegisterEvent(e) self._events[e] = true end
    for _, m in ipairs({ "ClearAllPoints", "SetFrameStrata", "SetToplevel", "EnableMouse",
                         "SetMovable", "RegisterForDrag", "RegisterForClicks", "StartMoving",
                         "StopMovingOrSizing", "SetBackdrop", "SetBackdropColor",
                         "SetBackdropBorderColor", "SetFrameLevel", "SetAllPoints",
                         "SetClampedToScreen" }) do
        f[m] = function() end
    end
    function f:GetPoint() return "CENTER", nil, "CENTER", 0, 0 end
    function f:GetEffectiveScale() return 1 end
    function f:CreateFontString()
        local fs = newRegion()
        table.insert(frames, fs)
        return fs
    end
    function f:CreateTexture() return newRegion() end
    table.insert(frames, f)
    if name then _G[name] = f; byName[name] = f end
    return f
end

_G.CreateFrame = newFrame
_G.UIParent = newFrame("Frame", "UIParent")
_G.UnitName = function() return "Dotty" end
_G.DEFAULT_CHAT_FRAME = { AddMessage = function(_, m) table.insert(chat, m) end }
_G.SlashCmdList = {}

-- (!) BOTH OF THESE, or the addon hard-errors at the UISpecialFrames registration.
_G.UISpecialFrames = {}
_G.tinsert = table.insert

-- (!) RECORD THE CHANNEL AND THE TARGET, NOT JUST THE TEXT. Every suite in this
-- project discarded args 2-4, so `SendChatMessage(..., "SAY")` was a mutation that
-- survived everywhere. See guard 7 in the header.
_G.SendChatMessage = function(msg, chan, lang, target)
    table.insert(sent, { msg = msg, chan = chan, lang = lang, target = target })
end

-- (!) READ THE ACTUAL .toc RATHER THAN RETURNING A LITERAL. A hardcoded "1.0" here
-- would keep passing for ever while the addon printed something else -- which is the
-- exact drift the version assertion exists to stop, and NorgGuide 1.0 shipped with a
-- hardcoded VERSION constant that this stub would have caught.
local TOC = "/data/NorgGuide/NorgGuide.toc"
_G.GetAddOnMetadata = function(_, field)
    if field ~= "Version" then return nil end
    local f = io.open(TOC)
    if not f then return nil end
    local v
    for line in f:lines() do v = v or line:match("^##%s*Version:%s*(.-)%s*$") end
    f:close()
    return v
end
local TOC_VERSION = _G.GetAddOnMetadata("NorgGuide", "Version")

dofile("/data/NorgGuide/NorgGuide.lua")

-- ------------------------------------------------------------------- assertions
local pass, fail = 0, 0
local function check(name, cond, detail)
    if cond then pass = pass + 1; print("  PASS  " .. name)
    else fail = fail + 1; print("  FAIL  " .. name .. "   " .. tostring(detail)) end
end

local ev
for _, f in ipairs(frames) do
    if f._events and f._events["CHAT_MSG_ADDON"] then ev = f end
end
check("registered for addon messages", ev ~= nil)

local ME = "Dotty"
local function fire(e, ...) ev._scripts["OnEvent"](ev, e, ...) end
-- The real 4-argument CHAT_MSG_ADDON signature: prefix, message, channel, sender.
local function msg(m) fire("CHAT_MSG_ADDON", "NORGPLAN", m, "WHISPER", ME) end
local function slash(a) _G.SlashCmdList["NORGGUIDE"](a) end
local function lastSent() return sent[#sent] end
local function lastText() return sent[#sent] and sent[#sent].msg end
local function row(i) return byName["NorgGuideRow" .. i] end
local function click(b) b._scripts["OnClick"](b) end
local function chatMatching(p)
    for i = #chat, 1, -1 do if chat[i]:find(p, 1, true) then return chat[i] end end
end
-- P| row builder so fixtures stay readable. routable is the SIXTH field.
local function P(id, score, xp, unlocks, qlvl, routable, map, title)
    return string.format("P|%d|%s|%d|%d|%d|%d|%d|1.0|2.0|3.0|%s",
                         id, score, xp, unlocks, qlvl, routable, map, title)
end

-- =============================================================== login and build
fire("PLAYER_LOGIN")
check("built its window", byName["NorgGuideFrame"] ~= nil)
check("window starts hidden", byName["NorgGuideFrame"]:IsShown() == false)
check("built 10 rows", row(10) ~= nil and row(11) == nil)
check("rows start hidden", row(1):IsShown() == false)

-- The frame must have a real size BEFORE SetBackdrop, and it must match the layout
-- maths -- a "> 0" assertion would pass against any wrong constant.
local F = byName["NorgGuideFrame"]
check("frame height matches its own row layout", F:GetHeight() == 96 + 10 * 30,
      F:GetHeight())
check("frame has a real width", F:GetWidth() == 340, F:GetWidth())

check("banner reports the .toc version", chatMatching("v" .. TOC_VERSION) ~= nil,
      chat[1])

check("registered for quest-log changes",
      ev._events["QUEST_ACCEPTED"] and ev._events["QUEST_TURNED_IN"]
      and ev._events["QUEST_REMOVED"])
check("did NOT register QUEST_LOG_UPDATE (fires in bursts)",
      ev._events["QUEST_LOG_UPDATE"] == nil)
check("registered the window for Escape",
      _G.UISpecialFrames[1] == "NorgGuideFrame", _G.UISpecialFrames[1])

-- ================================================================ asking for a list
slash("")
check("asked the server for a list", lastText() == "NORGPLAN LIST 10", lastText())
check("sent it as a WHISPER", lastSent().chan == "WHISPER", lastSent().chan)
check("whispered ITSELF", lastSent().target == ME, lastSent().target)

slash("5")
check("honoured a row count", lastText() == "NORGPLAN LIST 5", lastText())
msg("E|0")   -- the server always answers; drain it so bookkeeping is realistic

-- (!) A COUNT ABOVE THE ROW COUNT MUST BE CAPPED, not passed through. The server
-- honours up to 40; this window only builds 10 buttons, so an uncapped request would
-- receive 20 rows, display 10, and look like the server ran out of suggestions.
slash("20")
check("capped an over-large count", lastText() == "NORGPLAN LIST 10", lastText())
check("said so rather than silently trimming", chatMatching("as many as this window holds") ~= nil)
msg("E|0")

-- =========================================================== receiving a listing
slash("")
msg(P(1234, "41.5", 1350, 6, 22, 1, 1, "The Escape"))
msg(P(5678, "18.2", 400, 0, 20, 1, 0, "Wanted: Kolkar"))
msg("E|2")

check("window opened on the reply", byName["NorgGuideFrame"]:IsShown() == true)
check("row 1 is VISIBLE after a listing", row(1):IsShown() == true)
check("row 2 is VISIBLE after a listing", row(2):IsShown() == true)
check("row 1 shows the title", row(1).title:GetText():find("The Escape", 1, true) ~= nil,
      row(1).title:GetText())
check("row 3 hidden for a 2-row answer", row(3):IsShown() == false)

-- (!) MAP 0 IS EASTERN KINGDOMS. Row 2 above is map 0 AND routable=1, which is the
-- single case version 1.0 got wrong for 1,939 quests. It must be fully lit.
check("a map-0 (Eastern Kingdoms) row is NOT dimmed", row(2).title:GetAlpha() == 1.0,
      row(2).title:GetAlpha())
check("a routable row is at full alpha", row(1).title:GetAlpha() == 1.0,
      row(1).title:GetAlpha())

-- The reason line is the whole point of sending the terms separately.
check("row 1 names what it unlocks", row(1).sub:GetText():find("opens 6 quests", 1, true) ~= nil,
      row(1).sub:GetText())
check("row 1 names the xp", row(1).sub:GetText():find("1350 xp", 1, true) ~= nil,
      row(1).sub:GetText())
check("row 2 omits unlocks when it gates nothing",
      row(2).sub:GetText():find("opens", 1, true) == nil, row(2).sub:GetText())

-- Colour bands AND their boundaries. Asserting only 9/6/0 would still pass if the
-- orange threshold moved from 8 to 7.
slash("")
msg(P(1, "1", 100, 8, 10, 1, 1, "Eight"))
msg(P(2, "1", 100, 7, 10, 1, 1, "Seven"))
msg(P(3, "1", 100, 1, 10, 1, 1, "One"))
msg(P(4, "1", 100, 0, 10, 1, 1, "Zero"))
msg("E|4")
check("8 unlocks is orange", string.sub(row(1).title:GetText(), 1, 10) == "|cffff8000",
      string.sub(row(1).title:GetText(), 1, 10))
check("7 unlocks is green (boundary)", string.sub(row(2).title:GetText(), 1, 10) == "|cff1eff00",
      string.sub(row(2).title:GetText(), 1, 10))
check("1 unlock is green", string.sub(row(3).title:GetText(), 1, 10) == "|cff1eff00",
      string.sub(row(3).title:GetText(), 1, 10))
check("0 unlocks is white", string.sub(row(4).title:GetText(), 1, 10) == "|cffffffff",
      string.sub(row(4).title:GetText(), 1, 10))

-- ================================================================ clicking a row
slash("")
msg(P(1234, "41.5", 1350, 6, 22, 1, 1, "The Escape"))
msg(P(5678, "18.2", 400, 0, 20, 1, 0, "Wanted: Kolkar"))
msg("E|2")
click(row(1))
check("clicking row 1 routed to ITS quest", lastText() == "NORGPLAN GO 1234", lastText())
click(row(2))
check("clicking row 2 routed to ITS quest", lastText() == "NORGPLAN GO 5678", lastText())
check("GO went out as a self-whisper too",
      lastSent().chan == "WHISPER" and lastSent().target == ME)

-- (!) Re-list with DIFFERENT quests in the same rows, then click row 1 again. A
-- Refresh that stamped the id once passes every assertion above and fails here.
slash("")
msg(P(9999, "55.0", 2000, 9, 24, 1, 1, "Deep Ocean, Vast Sea"))
msg("E|1")
click(row(1))
check("row 1 re-aims after a new listing", lastText() == "NORGPLAN GO 9999", lastText())
check("row 2 hidden when the list shrank", row(2):IsShown() == false)

-- (!) A HIDDEN ROW MUST NOT KEEP ITS QUEST. Rows are globally named, so /click
-- NorgGuideRow2 reaches this even while it is hidden.
local before = #sent
click(row(2))
check("a hidden row fires nothing", #sent == before, lastText())

-- ============================================================== unroutable rows
-- (!) CLEAR TO A KNOWN-HIDDEN STATE FIRST. Refresh only calls Hide() on the `not r`
-- branch, so a row that is merely never Shown keeps whatever visibility it had from
-- the previous listing. Without this drain, `if r.routable then btn:Show() end` -- the
-- naive shape of the map-0 fix -- passes the visibility assertion below purely on
-- leftover state, which is exactly how it survived mutation testing the first time.
slash("")
msg("E|0")
check("drained to a hidden state", row(1):IsShown() == false)

slash("")
msg(P(4321, "30.0", 900, 3, 21, 0, 0, "A Ring of Twilight"))
msg("E|1")
before = #sent
click(row(1))
check("clicking an unroutable row sends nothing", #sent == before, lastText())
check("and explains why", chatMatching("starts from an item or an event") ~= nil)
check("unroutable row is dimmed", row(1).title:GetAlpha() < 1.0, row(1).title:GetAlpha())
-- (!) LISTED, NOT HIDDEN. The addon documents this as deliberate: silently dropping
-- these would make the plan look shorter than it is. `if r.routable then btn:Show()`
-- is the naive map-0 fix and this is what catches it.
check("an unroutable row is still LISTED, not hidden", row(1):IsShown() == true)
check("unroutable row says so in its reason",
      row(1).sub:GetText():find("no giver to walk to", 1, true) ~= nil, row(1).sub:GetText())

-- ================================================================= title parsing
slash("")
msg(P(7, "10.0", 100, 0, 10, 1, 1, "Bad|Title|Here"))
msg("E|1")
check("title is the whole remainder", row(1).title:GetText():find("Bad|Title|Here", 1, true) ~= nil,
      row(1).title:GetText())

-- A malformed row must be REJECTED, not rendered as a blank clickable row. Because
-- every row comes from one server-side format string, a field-count skew makes ALL
-- rows malformed -- the correct behaviour is a loud empty list.
slash("")
msg("P|7|10.0|100|0|10|1|1")      -- too few fields
msg("E|1")
check("a short row is rejected", row(1):IsShown() == false)
check("and the list reads as empty", chatMatching("nothing worth recommending") ~= nil)

-- ============================================ scaling quests (QuestLevel -1)
slash("")
msg(P(8715, "1.0", 0, 0, -1, 1, 1, "Bladeleaf the Elder"))
msg("E|1")
check("a scaling quest never renders 'level -1'",
      row(1).sub:GetText():find("-1", 1, true) == nil, row(1).sub:GetText())

-- ==================================================================== empty answer
slash("")
msg("E|0")
check("an empty answer clears the rows", row(1):IsShown() == false)
check("and says so", chatMatching("nothing worth recommending") ~= nil)
-- The reachable /click case: row 1 was stamped by the previous listing.
before = #sent
click(row(1))
check("row 1 fires nothing after an empty answer", #sent == before, lastText())

-- ================================================================ server refusals
msg("X|nostart")
check("nostart is explained in words", chatMatching("no giver standing anywhere") ~= nil)
msg("X|noroute")
check("noroute is explained in words", chatMatching("no way to get there") ~= nil)
msg("X|cooldown")
check("cooldown is explained in words", chatMatching("couple of seconds") ~= nil)
msg("X|indungeon|Blackfathom Deeps")
check("a dungeon giver names the dungeon",
      chatMatching("inside Blackfathom Deeps") ~= nil)
-- (!) An unknown code means the server is newer than the addon -- exactly when the
-- player needs telling. A silent no-op is the worst answer to "why did nothing happen".
msg("X|WOMBAT")
check("an unknown refusal code is still reported", chatMatching("WOMBAT") ~= nil)
msg("G|1234")
check("a routing confirmation points at the arrow", chatMatching("NorgNav arrow") ~= nil)

-- ======================================================= foreign / spoofed traffic
-- NorgQuest emits E|, G| and X| on the same CHAT_MSG_WHISPER/LANG_ADDON path.
slash("")
msg(P(111, "9", 50, 0, 5, 1, 1, "Mine"))
msg("E|1")
if frame then end
byName["NorgGuideFrame"]:Hide()
fire("CHAT_MSG_ADDON", "NORGQUEST", "E|3", "WHISPER", ME)
check("a foreign prefix does not open the window",
      byName["NorgGuideFrame"]:IsShown() == false)
-- (!) ASSERT THE ROWS SURVIVE, NOT JUST THAT THE WINDOW STAYED SHUT. Removing the
-- prefix guard does NOT reopen the window (nothing was awaited) -- it silently WIPES
-- the listing, because a foreign `E|` swaps in an empty batch. Visibility alone
-- therefore cannot see this mutation; the surviving row is what proves the guard ran.
check("a foreign prefix does not wipe the listing", row(1):IsShown() == true)
check("a foreign prefix does not clear the rows",
      row(1).title:GetText():find("Mine", 1, true) ~= nil, row(1).title:GetText())
-- positive control: the same payload on our own prefix DOES act
slash("")
msg("E|0")
check("positive control: our own prefix still acts",
      byName["NorgGuideFrame"]:IsShown() == true)

-- A stranger cannot force the window open or inject rows.
--
-- (!) THE INJECTED CONTENT IS WHAT MUST BE ASSERTED. Dropping the sender check does
-- not reopen a closed window either -- the damage is that an attacker's rows REPLACE
-- the player's real plan, carrying arbitrary UI escapes straight into SetText,
-- because the server skips every sanitisation pass on the addon language.
slash("")
msg(P(111, "9", 50, 0, 5, 1, 1, "Mine"))
msg("E|1")
byName["NorgGuideFrame"]:Hide()
fire("CHAT_MSG_ADDON", "NORGPLAN", P(66, "99", 1, 0, 1, 1, 1, "|TInterface\\Icons\\x:0|t Free Gold"),
     "GUILD", "Attacker")
fire("CHAT_MSG_ADDON", "NORGPLAN", "E|1", "GUILD", "Attacker")
check("a message from another player over GUILD is ignored",
      byName["NorgGuideFrame"]:IsShown() == false)
check("GUILD traffic cannot replace the player's rows",
      row(1).title:GetText():find("Free Gold", 1, true) == nil, row(1).title:GetText())

fire("CHAT_MSG_ADDON", "NORGPLAN", P(67, "99", 1, 0, 1, 1, 1, "Spoofed whisper"),
     "WHISPER", "Attacker")
fire("CHAT_MSG_ADDON", "NORGPLAN", "E|1", "WHISPER", "Attacker")
check("a WHISPER from somebody else is ignored",
      byName["NorgGuideFrame"]:IsShown() == false)
check("another player's whisper cannot replace the rows",
      row(1).title:GetText():find("Spoofed", 1, true) == nil, row(1).title:GetText())

-- An unsolicited reply we did not ask for must not reopen a closed window.
fire("CHAT_MSG_ADDON", "NORGPLAN", "E|0", "WHISPER", ME)
check("an unrequested reply does not reopen the window",
      byName["NorgGuideFrame"]:IsShown() == false)

-- ================================================== two requests in flight at once
slash("")
slash("")
msg(P(1, "1", 100, 0, 10, 1, 1, "First batch A"))
msg(P(2, "1", 100, 0, 10, 1, 1, "First batch B"))
msg("E|2")
msg(P(3, "1", 100, 0, 10, 1, 1, "Second batch only"))
msg("E|1")
check("overlapping replies do not concatenate", row(2):IsShown() == false,
      row(2):IsShown())
check("the LAST reply wins whole",
      row(1).title:GetText():find("Second batch only", 1, true) ~= nil,
      row(1).title:GetText())

-- ==================================================== quest log changes underneath
slash("")
msg(P(1, "1", 100, 0, 10, 1, 1, "Something"))
msg("E|1")
fire("QUEST_ACCEPTED", 1)
check("an open window says the plan went stale",
      byName["NorgGuideFrame"].hint:GetText():find("quest log changed", 1, true) ~= nil,
      byName["NorgGuideFrame"].hint:GetText())
slash("")
msg(P(1, "1", 100, 0, 10, 1, 1, "Something"))
msg("E|1")
check("a fresh listing clears the stale notice",
      byName["NorgGuideFrame"].hint:GetText():find("Click a quest", 1, true) ~= nil,
      byName["NorgGuideFrame"].hint:GetText())

-- ============================================================ slash-command surface
slash("close")
check("/guide close hides the window", byName["NorgGuideFrame"]:IsShown() == false)
slash("help")
check("/guide help explains itself", chatMatching("ranked shortlist") ~= nil)
before = #sent
slash("help")
check("/guide help sends nothing to the server", #sent == before)
_G.NorgGuideDB.pos = { p = "TOPLEFT", rp = "TOPLEFT", x = -9000, y = 9000 }
slash("reset")
check("/guide reset clears the saved position", _G.NorgGuideDB.pos == nil)
check("/guide reset shows the window again", byName["NorgGuideFrame"]:IsShown() == true)

-- ======================================================================== summary
print("")
print(string.format("NorgGuide: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
