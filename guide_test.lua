-- Stub harness for NorgGuide.
--
-- Loads the REAL addon against a fake 3.3.5a API and drives the whole server
-- conversation through the same buttons and slash commands a player uses.
--
-- (!) WHAT THIS IS ACTUALLY GUARDING. Four things in this addon are wrong in a way
-- that produces no visible symptom until somebody acts on a wrong recommendation:
--
--   1. ROW REUSE. Row 3 is a different quest after every /guide. A button that
--      captured its quest id at BUILD time keeps sending the id it held during the
--      first listing while displaying the current name -- so the window is right and
--      the arrow walks you somewhere else. This is hearth_test's "SLOT vs ROW"
--      defect in a new addon, which is exactly why it is asserted first.
--   2. STALE ROWS ACROSS REPLIES. There is no "begin" marker in the wire protocol,
--      so a second listing that is SHORTER than the first must not leave the tail of
--      the first one on screen. Rows are hidden, and a hidden row still carries its
--      last quest id.
--   3. THE TITLE FIELD. It is the whole remainder of the line, not the tenth
--      field. A split that assumed eleven clean fields truncates at the first "|"
--      and shows a half-named quest rather than erroring.
--   4. UNROUTABLE ROWS. map 0 means "listed but nobody to walk to". Clicking one
--      must explain that and send NOTHING -- a GO for a quest with no giver is a
--      server round trip that can only fail.
--
-- None of the four is visible in a screenshot, so they are asserted by clicking the
-- REAL button object the addon built and reading what it actually sent.
--
-- Run from the addon root:
--     docker run --rm -v "$PWD:/data" nickblah/lua:5.1-luarocks lua /data/guide_test.lua

local sent, chat = {}, {}
local frames, byName = {}, {}

-- ------------------------------------------------------------ client API stubs
local function newRegion()
    local r = { _shown = true, text = nil, _alpha = 1 }
    function r:SetPoint() end
    function r:SetWidth() end
    function r:SetHeight() end
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
                         "SetBackdropBorderColor", "SetFrameLevel", "SetAllPoints" }) do
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
_G.SendChatMessage = function(msg) table.insert(sent, msg) end
_G.DEFAULT_CHAT_FRAME = { AddMessage = function(_, m) table.insert(chat, m) end }
_G.SlashCmdList = {}

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

local function fire(e, ...) ev._scripts["OnEvent"](ev, e, ...) end
local function msg(m) fire("CHAT_MSG_ADDON", "NORGPLAN", m) end
local function slash(a) _G.SlashCmdList["NORGGUIDE"](a) end
local function lastSent() return sent[#sent] end
local function row(i) return byName["NorgGuideRow" .. i] end
local function click(b) b._scripts["OnClick"](b) end
local function chatMatching(p)
    for i = #chat, 1, -1 do if chat[i]:find(p, 1, true) then return chat[i] end end
end

-- =============================================================== login and build
fire("PLAYER_LOGIN")
check("built its window", byName["NorgGuideFrame"] ~= nil)
check("window starts hidden", byName["NorgGuideFrame"]:IsShown() == false)
check("built 10 rows", row(10) ~= nil and row(11) == nil)
check("rows start hidden", row(1):IsShown() == false)

-- ================================================================ asking for a list
slash("")
check("asked the server for a list", lastSent() == "NORGPLAN LIST 10", lastSent())

slash("5")
check("honoured a row count", lastSent() == "NORGPLAN LIST 5", lastSent())

-- (!) A COUNT ABOVE THE ROW COUNT MUST BE CAPPED, not passed through. The server
-- honours up to 40; this window only builds 10 buttons, so an uncapped request would
-- receive 20 rows, display 10, and look like the server ran out of suggestions.
slash("20")
check("capped an over-large count", lastSent() == "NORGPLAN LIST 10", lastSent())
check("said so rather than silently trimming", chatMatching("as many as this window holds") ~= nil)

-- =========================================================== receiving a listing
slash("")
msg("P|1234|41.5|1350|6|22|1|-620.5|-4210.2|38.1|The Escape")
msg("P|5678|18.2|400|0|20|1|1200.0|300.0|10.0|Wanted: Kolkar")
msg("E|2")

check("window opened on the reply", byName["NorgGuideFrame"]:IsShown() == true)
check("row 1 shows the title", row(1).title:GetText():find("The Escape", 1, true) ~= nil,
      row(1).title:GetText())
check("row 2 shows the title", row(2).title:GetText():find("Wanted: Kolkar", 1, true) ~= nil,
      row(2).title:GetText())
check("row 3 hidden for a 2-row answer", row(3):IsShown() == false)

-- The reason line is the whole point of sending the terms separately.
check("row 1 names what it unlocks", row(1).sub:GetText():find("opens 6 quests", 1, true) ~= nil,
      row(1).sub:GetText())
check("row 1 names the xp", row(1).sub:GetText():find("1350 xp", 1, true) ~= nil,
      row(1).sub:GetText())
check("row 2 omits unlocks when it gates nothing",
      row(2).sub:GetText():find("opens", 1, true) == nil, row(2).sub:GetText())

-- ================================================================ clicking a row
click(row(1))
check("clicking row 1 routed to ITS quest", lastSent() == "NORGPLAN GO 1234", lastSent())
click(row(2))
check("clicking row 2 routed to ITS quest", lastSent() == "NORGPLAN GO 5678", lastSent())

-- (!) DEFECT 1, THE WHOLE REASON THIS FILE EXISTS. Re-list with DIFFERENT quests in
-- the same rows, then click row 1 again. A button that captured its id at build time
-- passes every assertion above and fails here.
slash("")
msg("P|9999|55.0|2000|9|24|1|10.0|20.0|30.0|Deep Ocean, Vast Sea")
msg("E|1")
click(row(1))
check("row 1 re-aims after a new listing", lastSent() == "NORGPLAN GO 9999", lastSent())

-- (!) DEFECT 2. The second listing was SHORTER. Row 2 must be hidden, and must not
-- still be clickable at its old quest.
check("row 2 hidden when the list shrank", row(2):IsShown() == false)

-- ============================================================== unroutable rows
slash("")
msg("P|4321|30.0|900|3|21|0|0.0|0.0|0.0|A Ring of Twilight")
msg("E|1")
local before = #sent
click(row(1))
check("clicking an unroutable row sends nothing", #sent == before, lastSent())
check("and explains why", chatMatching("starts from an item or an event") ~= nil)
check("unroutable row is dimmed", row(1).title:GetAlpha() < 1.0, row(1).title:GetAlpha())
check("unroutable row says so in its reason",
      row(1).sub:GetText():find("no giver to walk to", 1, true) ~= nil, row(1).sub:GetText())

-- ================================================================= title parsing
-- (!) DEFECT 3. A title containing the field separator must survive whole.
slash("")
msg("P|7|10.0|100|0|10|1|1.0|2.0|3.0|Bad|Title|Here")
msg("E|1")
check("title is the whole remainder", row(1).title:GetText():find("Bad|Title|Here", 1, true) ~= nil,
      row(1).title:GetText())

-- ==================================================================== empty answer
slash("")
msg("E|0")
check("an empty answer clears the rows", row(1):IsShown() == false)
check("and says so", chatMatching("nothing worth recommending") ~= nil)

-- ================================================================ server refusals
msg("X|nostart")
check("nostart is explained in words", chatMatching("no giver standing anywhere") ~= nil)
msg("X|noroute")
check("noroute is explained in words", chatMatching("no way to get there") ~= nil)
msg("G|1234")
check("a routing confirmation points at the arrow", chatMatching("NorgNav arrow") ~= nil)

-- ======================================================================== summary
print("")
print(string.format("NorgGuide: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
