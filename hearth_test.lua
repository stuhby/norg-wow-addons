-- Stub harness for NorgHearth.
--
-- Loads the REAL addon against a fake 3.3.5a API and drives the whole server
-- conversation through the same buttons and slash commands a player uses.
--
-- (!) WHAT THIS IS ACTUALLY GUARDING. Three things in this addon are wrong in a
-- way that produces no visible symptom until it costs somebody something:
--
--   1. SLOT vs ROW. Slots are reused after a delete, so a list can read 1, 3, 4
--      and row 2 is then slot 3. A button that remembers its POSITION instead of
--      its slot re-aims at its neighbour the moment anything is deleted -- and
--      the window still looks perfectly correct while doing it.
--   2. STALE ROWS. When the list shrinks, a row that is merely hidden still
--      carries the slot it last held. Show it again for a different bind and it
--      fires the old one.
--   3. A STALE PANEL. Which bind is live lives on the SERVER, and no event this
--      addon registers fires when you bind at an innkeeper. A window left open
--      while you walk over and bind therefore keeps drawing the green arrow beside
--      your PREVIOUS bind -- correct-looking, and wrong about the one thing
--      this addon exists to tell you.
--
-- None of the three is visible in a screenshot, so they are asserted here by
-- clicking the REAL button object the addon built, driving its REAL OnUpdate,
-- and reading what it actually sent.

local sent, chat = {}, {}
local frames, byName = {}, {}

-- ------------------------------------------------------------ client API stubs
local function newRegion()
    local r = { _shown = true, text = nil }
    function r:SetPoint() end
    function r:SetWidth() end
    function r:SetHeight() end
    function r:SetJustifyH() end
    -- Texture regions: the minimap button sets an icon and a ring border.
    function r:SetTexture() end
    function r:SetTexCoord() end
    function r:SetVertexColor() end
    function r:SetAllPoints() end
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
                         "SetMovable", "RegisterForDrag", "StartMoving", "StopMovingOrSizing",
                         "SetBackdrop", "SetBackdropColor", "SetBackdropBorderColor",
                         "SetAutoFocus", "SetMaxLetters", "ClearFocus", "SetAllPoints" }) do
        f[m] = function() end
    end
    function f:GetPoint() return "CENTER", nil, "CENTER", 0, 0 end
    -- (!) The minimap button calls these. A stub frame that is missing ONE of
    -- them throws at load and every test after it never runs -- which reads as
    -- "the addon is broken" rather than "the harness is incomplete".
    function f:SetFrameLevel() end
    function f:GetFrameLevel() return 5 end
    function f:SetFrameStrata() end
    function f:SetToplevel() end
    function f:EnableMouse() end
    function f:SetMovable() end
    function f:RegisterForDrag() end
    function f:RegisterForClicks() end
    function f:StartMoving() end
    function f:StopMovingOrSizing() end
    function f:SetBackdrop() end
    function f:SetBackdropColor() end
    function f:SetBackdropBorderColor() end
    function f:GetCenter() return 400, 300 end
    function f:SetAutoFocus() end
    function f:SetMaxLetters() end
    function f:ClearFocus() end
    function f:SetText(t) self._text = t end
    function f:GetText() return self._text or "" end
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
_G.UISpecialFrames = {}
_G.tinsert = table.insert
_G.UnitName = function() return "Dotty" end
_G.SendChatMessage = function(msg) table.insert(sent, msg) end
_G.DEFAULT_CHAT_FRAME = { AddMessage = function(_, m) table.insert(chat, m) end }
_G.SlashCmdList = {}
-- (!) WoW's global cos/sin take DEGREES, unlike math.cos/math.sin. The addon
-- uses the WoW ones to place the button on the minimap ring; Lua has no such
-- globals, so without these the position silently becomes nil.
_G.cos = function(d) return math.cos(math.rad(d)) end
_G.sin = function(d) return math.sin(math.rad(d)) end
_G.Minimap = newFrame("Frame", "Minimap")
_G.GetCursorPosition = function() return 500, 400 end
_G.GameTooltip = { SetOwner = function() end, AddLine = function() end,
                   Show = function() end, Hide = function() end }

local ADDON = os.getenv("NORGHEARTH_PATH") or "/data/NorgHearth/NorgHearth.lua"

-- (!) GetAddOnMetadata IS REAL IN 3.3.5a -- the vendored Atlas 3.x calls it at
-- file scope to set ATLAS_VERSION (atlas-src/Atlas-3/Atlas/Atlas.lua) -- but
-- plain Lua has no such global, so without this stub the addon's version line
-- is a nil call the moment it loads.
--
-- (!) IT READS THE ACTUAL .toc RATHER THAN RETURNING A LITERAL. A hardcoded "1.0"
-- here would keep passing for ever while the addon printed something else, which
-- is the exact drift this whole change exists to stop -- the test would then be
-- asserting nothing but its own opinion.
local TOC = ADDON:gsub("%.lua$", ".toc")
_G.GetAddOnMetadata = function(_, field)
    if field ~= "Version" then return nil end
    local f = io.open(TOC)
    if not f then return nil end
    local v
    for line in f:lines() do v = v or line:match("^##%s*Version:%s*(.-)%s*$") end
    f:close()
    return v
end
local TOC_VERSION = _G.GetAddOnMetadata("NorgHearth", "Version")

-- (!) A SETTABLE STUB, because PollBind's entire job is reacting to this string
-- CHANGING. It starts nil on purpose: that is genuinely what the client returns
-- early in a login, and the addon has to survive it without burning its baseline
-- on a blank (see the empty-answer note in PollBind).
local bindPlace = nil
_G.GetBindLocation = function() return bindPlace end

dofile(ADDON)

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
local function msg(m) fire("CHAT_MSG_ADDON", "NORGHOME", m) end
local function slash(a) _G.SlashCmdList["NORGHEARTH"](a) end
local function lastSent() return sent[#sent] end
local function lastChat() return chat[#chat] end
local function chatMatching(p)
    for i = #chat, 1, -1 do if chat[i]:find(p, 1, true) then return chat[i] end end
end
local function row(i) return byName["NorgHearthRow" .. i] end
local function del(i) return byName["NorgHearthDel" .. i] end
local function click(b) b._scripts["OnClick"](b) end

-- =============================================================== login and build
fire("PLAYER_LOGIN")
check("built its window", byName["NorgHearthFrame"] ~= nil)
check("built 8 row buttons", row(1) ~= nil and row(8) ~= nil and row(9) == nil)
check("the .toc carries a Version field at all", TOC_VERSION ~= nil, TOC_VERSION)
check("login banner names the version FROM THE .toc",
      TOC_VERSION and chatMatching("v" .. TOC_VERSION) ~= nil, lastChat())
-- The operator loads eight of these; two lines each is login spam.
check("and announces itself exactly ONCE", #chat == 1, #chat)
check("window starts hidden", byName["NorgHearthFrame"]:IsShown() == false)
check("rows start hidden", row(1):IsShown() == false)

-- ================================================== opening asks the server
sent = {}
slash("")
check("/hs shows the window", byName["NorgHearthFrame"]:IsShown() == true)
check("/hs asks the server for the list", lastSent() == "NORGHOME LIST", lastSent())

-- ============================================ a list renders, spaces and all
-- Slots 1, 3, 4 on purpose: slot 2 was deleted at some point, which is exactly
-- the case where a row-indexed button starts lying.
msg("H|1:1519:0:Stormwind|3:4395:1:Dalaran Inn|4:1637:0:Orgrimmar")
msg("E|3")
check("rendered three rows", row(1):IsShown() and row(2):IsShown() and row(3):IsShown())
check("row 4 stayed hidden", row(4):IsShown() == false)
check("a name with a space survived intact",
      row(2):GetText():find("Dalaran Inn", 1, true) ~= nil, row(2):GetText())
check("the live bind is marked and the others are not",
      row(2):GetText():find("cff40ff40", 1, true) ~= nil
      and row(1):GetText():find("cff40ff40", 1, true) == nil,
      row(1):GetText() .. " / " .. row(2):GetText())

-- ============================================ THE ONE THAT MATTERS: slot vs row
sent = {}
click(row(2))
check("clicking row 2 sends the SLOT (3), not the row number",
      lastSent() == "NORGHOME USE 3", lastSent())
sent = {}
click(del(3))
check("delete on row 3 sends slot 4", lastSent() == "NORGHOME DEL 4", lastSent())

-- ==================================================== batched lists accumulate
sent = {}
slash("")   -- close
slash("")   -- open again -> LIST
msg("H|1:1519:0:One|2:1519:0:Two")
msg("H|3:1519:0:Three")
msg("E|3")
check("two H batches make three rows, not two",
      row(3):IsShown() and row(3):GetText():find("Three", 1, true) ~= nil,
      row(3):GetText())

-- ===================== a half-arrived list is discarded, not merged into the next
slash("")                        -- close
slash("")                        -- open -> LIST, discards pending
msg("H|1:1519:0:One")            -- first batch of a list that never finishes
slash("")                        -- close
slash("")                        -- open -> LIST again
msg("H|1:1519:0:One")
msg("E|1")
check("an interrupted list does not double up",
      row(1):IsShown() and row(2):IsShown() == false,
      "row2 shown=" .. tostring(row(2):IsShown()))

-- ================================================ a shrinking list clears rows
-- (!) The rows below the new end are hidden -- but if they merely hide and keep
-- their old slot, they are a live wrong answer waiting to be shown again.
sent = {}
click(row(2))
check("a row left over from a longer list sends nothing", #sent == 0,
      "sent " .. tostring(lastSent()))

-- ================================================================ the empty state
msg("E|0")
check("E|0 clears every row", row(1):IsShown() == false)
sent = {}
click(row(1))
check("cleared rows are inert too", #sent == 0, tostring(lastSent()))

-- ============================================ saving happens by itself, no click
-- (!) ASSERT EVERY REPLACED WIDGET IS ABSENT, not merely that the live path works.
-- An earlier cut shipped still building the pair the auto-naming replaced -- a
-- dead hidden EditBox (NorgHearthName), a visible name box (NorgHearthNameBox)
-- and a second Save button (NorgHearthSaveButton) -- sitting over the real button
-- without stopping it working. Nothing MISBEHAVED, which is precisely why only an
-- absence check keeps them gone. The Save button itself is now on that list: the
-- watcher below replaced it, and a button left behind would be a control that
-- duplicates something already automatic.
check("no Save button is built any more",
      byName["NorgHearthSave"] == nil, tostring(byName["NorgHearthSave"]))
check("no name box is built at all",
      byName["NorgHearthName"] == nil and byName["NorgHearthNameBox"] == nil,
      tostring(byName["NorgHearthName"]) .. " / " .. tostring(byName["NorgHearthNameBox"]))
check("...and no second Save button drawn across the first",
      byName["NorgHearthSaveButton"] == nil, tostring(byName["NorgHearthSaveButton"]))

-- ---------------------------------------------------------------- the bind watcher
-- (!) DRIVE THE ADDON'S REAL OnUpdate ON ITS REAL EVENT FRAME. This is the same
-- frame that carries CHAT_MSG_ADDON, and that is deliberate in the addon: the
-- WINDOW's OnUpdate only ticks while it is shown, and auto-save has to work for
-- somebody who never opens the window at all. If this ever ends up on the window,
-- these tests keep passing while the feature silently stops working when closed.
local watch = ev._scripts["OnUpdate"]
check("the event frame carries an OnUpdate for the bind watcher", watch ~= nil)
local function poll(seconds) if watch then watch(ev, seconds or 3) end end

-- A nil answer must not count as a place, or the baseline is burned on a blank and
-- the very next real value looks like a change -- saving on every login.
sent = {}; bindPlace = nil
poll()
check("a nil bind location sends nothing", #sent == 0, tostring(lastSent()))
bindPlace = ""
poll()
check("an empty bind location sends nothing too", #sent == 0, tostring(lastSent()))

-- First real value is the BASELINE. Recording it must be silent.
sent = {}; bindPlace = "Undercity"
poll()
check("the first real bind location is only a baseline, and sends nothing",
      #sent == 0, tostring(lastSent()))

-- Unchanged means nothing to do, however many ticks pass.
sent = {}
poll(); poll(); poll()
check("an unchanged bind location keeps sending nothing",
      #sent == 0, tostring(lastSent()))

-- (!) AND NOW THE ACTUAL FEATURE: a CHANGE sends a bare SAVE. Bare, because the
-- server derives the name from the area the homebind sits in. If this ever starts
-- sending a name, the auto-naming is silently dead.
sent = {}; chat = {}; bindPlace = "Orgrimmar"
poll()
check("binding somewhere new sends a bare SAVE",
      lastSent() == "NORGHOME SAVE", tostring(lastSent()))
check("...and does not scold the player about a missing name",
      chatMatching("give it a name") == nil, tostring(lastChat()))

-- (!) ONCE, NOT EVERY TICK. Without the addon writing the new place back before
-- sending, this would re-send twice a second forever -- and because the server
-- answers HAVEIT silently, the flood would be completely invisible in game.
sent = {}
poll(); poll(); poll()
check("the same new location is not sent again on later ticks",
      #sent == 0, tostring(lastSent()))

-- The reply names the slot and says it was not asked for, so the line makes sense
-- to somebody who pressed nothing.
chat = {}
msg("A|3|1637|Orgrimmar")
check("an automatic save says so and names the slot",
      chatMatching("slot 3") ~= nil, tostring(lastChat()))

-- (!) HAVEIT IS SILENT. It is the ordinary answer to re-binding at an inn already
-- saved, so it must produce NO chat at all -- not even the unknown-code fallback.
chat = {}; bindPlace = "Thunder Bluff"; poll()
msg("X|HAVEIT")
check("HAVEIT produces no chat line at all", #chat == 0, tostring(lastChat()))

-- (!) FULL MUST STILL REACH THE PLAYER, and must say the bind was NOT kept. This is
-- the operator's stated choice: refuse and let a human pick what to give up.
chat = {}; bindPlace = "Ironforge"; poll()
msg("X|FULL")
check("FULL explains the bind was not saved", chatMatching("could not save") ~= nil,
      tostring(lastChat()))
check("...and points at the X to free a slot", chatMatching("remove one with its X") ~= nil,
      tostring(lastChat()))

-- A chosen name still travels -- through the slash command, the only route left.
sent = {}
slash("save The Filthy Animal")
check("/hs save passes a chosen name through verbatim",
      lastSent() == "NORGHOME SAVE The Filthy Animal", lastSent())

-- (!) "|" and ":" frame the messages both ways. They have to be gone BEFORE the
-- line is sent, or the SAVE command itself is what breaks -- not merely the reply.
sent = {}
slash("save Dal|ar:an")
check("framing characters are stripped before sending",
      lastSent() == "NORGHOME SAVE Dalaran", lastSent())

-- (!) CONTRACT REVERSED DELIBERATELY. A blank name used to be an error; it now
-- means "name it after wherever I am bound", which the SERVER resolves from the
-- area (an inn in Valley of Strength becomes Orgrimmar). Refusing it locally is
-- what made the Save button send nothing at all.
sent = {}; chat = {}
slash("save    ")
check("a blank name sends a bare SAVE for the server to name",
      lastSent() == "NORGHOME SAVE", tostring(lastSent()))
check("...and does not scold the player about it",
      chatMatching("give it a name") == nil, lastChat())

sent = {}; chat = {}
slash("save " .. string.rep("x", 25))
check("an over-long name is refused locally", #sent == 0, tostring(lastSent()))
check("...and says so rather than truncating",
      chatMatching("too long") ~= nil, lastChat())

sent = {}
slash("save " .. string.rep("x", 24))
check("exactly 24 characters is allowed",
      lastSent() == "NORGHOME SAVE " .. string.rep("x", 24), lastSent())

-- (!) The usual shape of a slash handler lower-cases the whole argument. This
-- one must not: the tail is a name the player chose.
sent = {}
slash("SAVE Dalaran Inn")
check("the verb is case-insensitive but the name keeps its case",
      lastSent() == "NORGHOME SAVE Dalaran Inn", lastSent())

-- ================================================================ server replies
sent = {}; chat = {}
msg("A|2|4395|Dalaran Inn")
check("a save confirmation names the bind",
      chatMatching("Dalaran Inn") ~= nil, lastChat())
check("...and re-reads the list, because the server picks the slot",
      lastSent() == "NORGHOME LIST", lastSent())

msg("H|1:1519:1:Stormwind|2:4395:0:Dalaran Inn")
msg("E|2")
chat = {}
msg("B|2|4395")
check("a switch confirmation uses the NAME the addon already knows",
      chatMatching("Dalaran Inn") ~= nil, lastChat())
check("the green marker moved to the new bind",
      row(2):GetText():find("cff40ff40", 1, true) ~= nil
      and row(1):GetText():find("cff40ff40", 1, true) == nil,
      row(1):GetText() .. " / " .. row(2):GetText())

-- (!) "/hs use 7" before any list has been fetched is legal. The addon does not
-- know the name yet and must say the number, not "nil".
chat = {}
msg("B|7|1637")
check("an unknown slot falls back to its number", chatMatching("bind 7") ~= nil, lastChat())
check("...and does not print nil", (lastChat() or ""):find("nil", 1, true) == nil, lastChat())

-- R| removes the row without another round trip.
msg("H|1:1519:0:Stormwind|2:4395:0:Dalaran Inn")
msg("E|2")
sent = {}; chat = {}
msg("R|1")
check("R removes the row locally", row(1):GetText():find("Dalaran Inn", 1, true) ~= nil,
      row(1):GetText())
check("...without asking for the list again", #sent == 0, tostring(lastSent()))
check("...and says what it forgot", chatMatching("Stormwind") ~= nil, lastChat())

-- ============================== THE MARKER MUST BE CLEARED, NOT ONLY EVER SET
-- (!) Bind at an inn you have NOT saved and the server answers correctly: every
-- row flagged 0. An earlier cut only ever SET current -- it cleared it solely on
-- the empty E|0 -- so the arrow and "(current)" stayed beside whichever bind was
-- live LAST. The intended flow is the worst case for it: you bind, you open /hs
-- to save the new place, and for exactly that window the panel points at your
-- PREVIOUS bind. Being a session variable it was honest after a fresh login,
-- which is how a feature whose only job is saying where the stone goes came to
-- lie about it.
chat = {}
slash("list")
msg("H|1:1519:1:Stormwind|2:4395:0:Dalaran Inn")
msg("E|2")
check("positive control: the server's flag does set the marker",
      NorgHearth_Current() == 1
      and row(1):GetText():find("cff40ff40", 1, true) ~= nil,
      tostring(NorgHearth_Current()))

chat = {}
slash("list")
msg("H|1:1519:0:Stormwind|2:4395:0:Dalaran Inn")
msg("E|2")
check("a list where no row is current clears the marker",
      NorgHearth_Current() == nil, tostring(NorgHearth_Current()))
check("...and no row is drawn with the arrow",
      row(1):GetText():find("cff40ff40", 1, true) == nil
      and row(2):GetText():find("cff40ff40", 1, true) == nil,
      row(1):GetText() .. " / " .. row(2):GetText())
check("...and /hs list does not claim one is current either",
      chatMatching("(current)") == nil, table.concat(chat, " ~ "))

-- (!) CLEARING ALONE IS NOT THE FIX: a list flagging a DIFFERENT slot has to
-- WIN over the one held from the previous list, not be merged with it. A
-- marker that only ever clears is just the same bug pointing at nothing.
chat = {}
slash("list")
msg("H|1:1519:0:Stormwind|2:4395:1:Dalaran Inn")
msg("E|2")
check("a later list moves the marker to the row the server flags",
      NorgHearth_Current() == 2
      and row(2):GetText():find("cff40ff40", 1, true) ~= nil
      and row(1):GetText():find("cff40ff40", 1, true) == nil,
      tostring(NorgHearth_Current()))

-- (!) AND A HALF-ARRIVED LIST MUST NOT GET A VOTE. Batches accumulate until E|
-- commits them; an abandoned list that had flagged a row would otherwise carry
-- its marker into whatever the next answer says.
chat = {}
slash("list")
msg("H|1:1519:1:Stormwind")     -- first batch of a list that never finishes
slash("list")                   -- ask again -- the pending list is discarded
msg("H|1:1519:0:Stormwind|2:4395:0:Dalaran Inn")
msg("E|2")
check("a discarded list does not carry its marker into the next one",
      NorgHearth_Current() == nil, tostring(NorgHearth_Current()))

-- ================= THE SAME LIE THROUGH THE SECOND DOOR: STALE WHILE OPEN
-- (!) Clearing the marker when the answer says "none" only helps if an answer
-- ARRIVES. Leave the window open, walk to an innkeeper and bind: no event this
-- addon registers tells it the bind moved, and every other fetch waits on the
-- player doing something -- opening the window, /hs list, saving -- so the
-- arrow sat beside the previous bind for as long as the window stayed up. The
-- fix is a re-ask on a timer while the window is shown, driven here through the
-- addon's REAL OnUpdate.
local hearthFrame = byName["NorgHearthFrame"]
local tick = hearthFrame._scripts["OnUpdate"]
check("the window carries an OnUpdate to re-ask on", tick ~= nil)

if hearthFrame:IsShown() then slash("") end     -- start from closed, whatever ran above
slash("")                                       -- open -> LIST
msg("H|1:1519:1:Stormwind|2:4395:0:Dalaran Inn")
msg("E|2")
check("positive control: it opens showing the bind the server flags",
      NorgHearth_Current() == 1, tostring(NorgHearth_Current()))

sent = {}
tick(hearthFrame, 2)
check("a couple of seconds passing does not re-ask", #sent == 0, tostring(lastSent()))
tick(hearthFrame, 4)                            -- 6s in total, past the period
check("an open window re-asks the server by itself",
      lastSent() == "NORGHOME LIST", tostring(lastSent()))

-- ...and here is the bind made at an inn that is not on the list: every row 0.
msg("H|1:1519:0:Stormwind|2:4395:0:Dalaran Inn")
msg("E|2")
check("...and the fresh answer clears an arrow that went stale in place",
      NorgHearth_Current() == nil
      and row(1):GetText():find("cff40ff40", 1, true) == nil,
      tostring(NorgHearth_Current()))

-- A PERIOD, NOT A BURST: the clock restarts on every re-ask, including the ones
-- the addon makes for its own reasons (see RequestList).
sent = {}
tick(hearthFrame, 4)
check("the clock restarts after a re-ask", #sent == 0, tostring(lastSent()))
tick(hearthFrame, 2)
check("...and then it asks again", lastSent() == "NORGHOME LIST", tostring(lastSent()))

-- (!) A CLOSED WINDOW MUST BE SILENT. In game OnUpdate does not run on a hidden
-- frame at all, so this asserts the addon does not lean on that alone -- and it
-- is the check that fails if anyone moves the timer onto a permanent frame.
slash("")                                       -- close
sent = {}
tick(hearthFrame, 60)
check("a closed window sends nothing at all", #sent == 0, tostring(lastSent()))
slash("")                                       -- leave it open, as the blocks below found it

-- ===================================================================== refusals
chat = {}
msg("X|FULL")
-- (!) THE WORDING MOVED WITH THE FEATURE, and this assertion moved with it rather
-- than being deleted. It used to require "delete one first", which was fine while a
-- human pressed Save and could read the refusal as advice. Now the save is
-- automatic, so the message has to say the bind was NOT KEPT -- advice for next time
-- is exactly the wrong reading when an inn you just bound at went unsaved.
check("a known refusal is explained in words",
      chatMatching("could not save") ~= nil, lastChat())
chat = {}
msg("X|DUPNAME")
-- (!) THIS ASSERTION USED TO BE INVERTED, AND IT PINNED A FALSEHOOD. It required
-- the message to blame the PLACE and forbade the word "name", on the reasoning
-- that binds are auto-named so a collision must be the same inn. That premise is
-- measurably wrong: DUPNAME is keyed on the NAME, and two different innkeepers
-- whose areas share a name collide -- Caris Sunlance and Jarin Dawnglow both sit
-- in "Argent Tournament Grounds" and both derive the same 24-byte label. It is
-- wrong the other way too: two binds at ONE inn under two typed names are BOTH
-- accepted, because nothing checks position. So the message must name the name.
check("DUPNAME is explained", chatMatching("already have a bind saved") ~= nil, lastChat())
check("DUPNAME blames the name, which is what it is keyed on",
      chatMatching("that name") ~= nil, lastChat())

-- (!) AND THE README MUST QUOTE IT WORD FOR WORD. Its troubleshooting section
-- tells the player what they will see on screen; a PARAPHRASE there ("Already
-- saved that place", which is what it used to say) is worse than no quote at
-- all, because somebody searching the page for the line they are looking at
-- finds nothing and concludes the doc describes a different addon. Compared
-- against the addon's own REFUSAL table, so rewording the message fails here
-- rather than in a player's face. Whitespace is flattened first: the README
-- wraps its columns, and a quote that spans a line break is still a quote.
local function fileText(p)
    local f = io.open(p)
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end
local srcText    = fileText(ADDON)
local readmeText = fileText((ADDON:gsub("NorgHearth%.lua$", "README.txt")))
local dupWords   = srcText and srcText:match('DUPNAME%s*=%s*"([^"]*)"')
check("the addon's DUPNAME wording is readable from source", dupWords ~= nil, tostring(dupWords))
check("the README is next to the addon", readmeText ~= nil, tostring(readmeText and #readmeText))
check("...and quotes the DUPNAME refusal word for word",
      readmeText ~= nil and dupWords ~= nil
      and readmeText:gsub("%s+", " "):find(dupWords, 1, true) ~= nil,
      tostring(dupWords))

-- (!) The server can grow a refusal code long before this addon is redistributed.
-- An unknown one must still say something -- a silent no-op is the worst answer
-- to "why will it not save".
chat = {}
msg("X|WOMBAT")
check("an unknown refusal still reports, and names the code",
      chatMatching("WOMBAT") ~= nil, lastChat())

-- ======================================================= junk and other channels
-- (!) A COMPLETE list on the wrong channel, H| AND E|. An H| alone proves
-- nothing: batches only land in the rendered list when E| commits them, so a
-- prefix check that had been deleted would still show zero binds here and the
-- test would pass against broken code. Asserted with a positive control right
-- after it, so "unchanged" cannot be vacuously true.
chat = {}; sent = {}
msg("H|5:1519:0:Mine")
msg("E|1")
local mine = row(1):GetText()
fire("CHAT_MSG_ADDON", "NORGQUEST", "H|1:1:0:NotOurs")
fire("CHAT_MSG_ADDON", "NORGQUEST", "E|1")
check("another addon's channel is ignored, list and all",
      #NorgHearth_Binds() == 1 and row(1):GetText() == mine,
      #NorgHearth_Binds() .. " binds, row1=" .. tostring(row(1):GetText()))
msg("H|6:1519:0:Ours")
msg("E|1")
check("...positive control: the SAME payload on our channel does land",
      row(1):GetText():find("Ours", 1, true) ~= nil, row(1):GetText())

msg("H|totally not a record")
msg("E|1")
check("a malformed record is dropped rather than rendered",
      #NorgHearth_Binds() == 0 and row(1):IsShown() == false,
      #NorgHearth_Binds() .. " binds")

-- ================================================================= slash plumbing
-- (!) /hs list MUST PRINT THE ANSWER, NOT THE CACHE. The list lives on the
-- server. A player who has not opened the window this session has an empty cache,
-- so printing at the moment the command is typed tells them "nothing saved yet"
-- while they are holding eight binds -- and the real answer then arrives with
-- nothing to show it.
sent = {}; chat = {}
msg("E|0")                                  -- cache is genuinely empty
slash("list")
check("/hs list asks the server", lastSent() == "NORGHOME LIST", lastSent())
check("...and prints nothing until the answer lands", #chat == 0,
      "printed " .. #chat .. " line(s) early: " .. tostring(lastChat()))
msg("H|2:1519:1:Stormwind|5:4395:0:Dalaran Inn")
msg("E|2")
check("...then prints the fresh list",
      chatMatching("Stormwind") ~= nil and chatMatching("Dalaran Inn") ~= nil,
      table.concat(chat, " ~ "))
check("...marking the current one", chatMatching("(current)") ~= nil,
      table.concat(chat, " ~ "))

-- ...and it is a one-shot: an unrelated later list must not print itself.
chat = {}
slash("")   -- close
slash("")   -- open -> LIST, no print wanted
msg("H|2:1519:1:Stormwind")
msg("E|1")
check("opening the window does not spam the list to chat", #chat == 0,
      table.concat(chat, " ~ "))

chat = {}
slash("list")
msg("E|0")
check("an empty answer says so rather than staying silent",
      chatMatching("nothing saved yet") ~= nil, tostring(lastChat()))

sent = {}
slash("use 4")
check("/hs use sends USE", lastSent() == "NORGHOME USE 4", lastSent())
sent = {}
slash("del 4")
check("/hs del sends DEL", lastSent() == "NORGHOME DEL 4", lastSent())
sent = {}
slash("use banana")
check("/hs use with a non-number sends nothing", #sent == 0, tostring(lastSent()))
chat = {}
slash("help")
check("/hs help explains the innkeeper rule",
      chatMatching("innkeeper") ~= nil, lastChat())

-- UI_TESTS_MARKER ======================= the UI must work without typing
-- (!) A window you can only drive by typing at it is a chat command wearing a
-- window. These assert the MOUSE path: open from the minimap, save from the
-- button.
check("minimap button exists after login", _G.NorgHearthMinimapButton ~= nil)
check("minimap button has a click handler",
      _G.NorgHearthMinimapButton and _G.NorgHearthMinimapButton._scripts["OnClick"] ~= nil)
-- (!) THE BOTTOM STRIP IS ONE CONTROL. Asserted through _G as well as byName
-- because a stray widget is only ever found by looking for it: the addon works
-- perfectly with three dead ones stacked underneath, which is how an earlier
-- cut was built.
check("the bottom strip has no buttons at all -- saving is automatic",
      _G.NorgHearthSave == nil and _G.NorgHearthName == nil
      and _G.NorgHearthNameBox == nil and _G.NorgHearthSaveButton == nil,
      tostring(_G.NorgHearthSave) .. " / " .. tostring(_G.NorgHearthSaveButton))

-- (!) AND THE INSTRUCTION IS PRINTED ONCE. The empty-list line sits near the
-- top and the hint sits at the foot, and on a first run BOTH are on screen: an
-- earlier cut had them contradicting each other (one asking for a typed name
-- the button no longer wanted), and merely agreeing is not the fix -- two
-- labels teaching the same step is how they drifted apart in the first place.
-- Counted over the window's own FontStrings, which is where a third copy would
-- appear. The buttons keep their text in _text, so only labels are counted.
local instructions = {}
for _, r in ipairs(frames) do
    if type(r.text) == "string" and r.text:find("innkeeper", 1, true) then
        instructions[#instructions + 1] = r.text
    end
end
check("the window teaches the innkeeper step exactly once", #instructions == 1,
      #instructions .. ": " .. table.concat(instructions, " ~ "))
-- (!) AND IT MUST NOT TELL ANYONE TO PRESS ANYTHING. There is no button to press,
-- so a label still naming one is a live wrong instruction -- the exact failure the
-- "exactly once" count above was written to catch in its earlier form.
check("...and it does not instruct a click that no longer exists",
      instructions[1] ~= nil and instructions[1]:find("click", 1, true) == nil,
      tostring(instructions[1]))

-- (!) THE WATCHER SENDS A BARE SAVE. The server names the bind after the area it
-- sits in, so the client must NOT invent or require a name. If this ever starts
-- sending one, the auto-naming is silently dead. Driven through the real OnUpdate
-- rather than a button, because the button is gone.
sent = {}; bindPlace = "Darnassus"; poll()
local savedMsg
for _, m in ipairs(sent) do if m:find("SAVE") then savedMsg = m end end
check("the watcher sends a SAVE on a new bind", savedMsg ~= nil, tostring(savedMsg))
check("the watcher sends NO name -- the server derives it",
      savedMsg ~= nil and savedMsg:match("SAVE%s*$") ~= nil,
      tostring(savedMsg))

-- ...but an explicitly typed name still goes through, for /hs save Bank alt
sent = {}
slash("save Bank alt")
local named
for _, m in ipairs(sent) do if m:find("SAVE") then named = m end end
check("/hs save <name> still passes the name through",
      named ~= nil and named:find("Bank alt") ~= nil, tostring(named))

print(string.format("\n  ==== %d passed, %d failed ====", pass, fail))
os.exit(fail == 0 and 0 or 1)
