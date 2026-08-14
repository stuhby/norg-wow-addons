-- Stub harness for NorgHearth.
--
-- Loads the REAL addon against a fake 3.3.5a API and drives the whole server
-- conversation through the same buttons and slash commands a player uses.
--
-- (!) WHAT THIS IS ACTUALLY GUARDING. Two things in this addon are wrong in a
-- way that produces no visible symptom until it costs somebody something:
--
--   1. SLOT vs ROW. Slots are reused after a delete, so a list can read 1, 3, 4
--      and row 2 is then slot 3. A button that remembers its POSITION instead of
--      its slot re-aims at its neighbour the moment anything is deleted -- and
--      the window still looks perfectly correct while doing it.
--   2. STALE ROWS. When the list shrinks, a row that is merely hidden still
--      carries the slot it last held. Show it again for a different bind and it
--      fires the old one.
--
-- Neither is visible in a screenshot, so both are asserted here by clicking the
-- REAL button object the addon built and reading what it actually sent.

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
check("login banner names the version",
      chatMatching("v1.0") ~= nil, lastChat())
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

-- =========================================================== saving from the box
local box  = byName["NorgHearthNameBox"]
local save = byName["NorgHearthSaveButton"]
sent = {}
box:SetText("The Filthy Animal")
click(save)
check("Save sends the typed name verbatim",
      lastSent() == "NORGHOME SAVE The Filthy Animal", lastSent())
check("Save empties the box afterwards", box:GetText() == "", box:GetText())

-- (!) "|" and ":" frame the messages both ways. They have to be gone BEFORE the
-- line is sent, or the SAVE command itself is what breaks -- not merely the reply.
sent = {}
box:SetText("Dal|ar:an")
click(save)
check("framing characters are stripped before sending",
      lastSent() == "NORGHOME SAVE Dalaran", lastSent())

sent = {}; chat = {}
box:SetText("   ")
click(save)
-- (!) CONTRACT REVERSED DELIBERATELY. A blank name used to be an error; it now
-- means "name it after wherever I am bound", which the SERVER resolves from the
-- area (an inn in Valley of Strength becomes Orgrimmar). Refusing it locally is
-- what made the Save button send nothing at all.
check("a blank name sends a bare SAVE for the server to name",
      lastSent() == "NORGHOME SAVE", tostring(lastSent()))
check("...and does not scold the player about it",
      chatMatching("give it a name") == nil, lastChat())

-- The box caps length in the real client, so the over-length path is only
-- reachable from the slash command -- which is exactly why it is tested there.
sent = {}; chat = {}
slash("save " .. string.rep("x", 25))
check("an over-long name is refused locally", #sent == 0, tostring(lastSent()))
check("...and says so rather than truncating",
      chatMatching("too long") ~= nil, lastChat())

sent = {}
slash("save " .. string.rep("x", 24))
check("exactly 24 characters is allowed",
      lastSent() == "NORGHOME SAVE " .. string.rep("x", 24), lastSent())

-- (!) Every other Norg addon lower-cases its whole argument. This one must not:
-- the tail is a name the player chose.
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

-- ===================================================================== refusals
chat = {}
msg("X|FULL")
check("a known refusal is explained in words",
      chatMatching("delete one first") ~= nil, lastChat())
chat = {}
msg("X|DUPNAME")
-- (!) Assert it does NOT blame the NAME. Binds are auto-named now, so "that name
-- is taken" describes something the player never did. This is the whole reason
-- the wording changed; a test on the old phrase would have passed forever.
check("DUPNAME is explained", chatMatching("already have a bind saved") ~= nil, lastChat())
check("DUPNAME blames the place, not a name", chatMatching("that name") == nil, lastChat())

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
-- (!) Everything was reachable only via /hs save <name> -- a chat command
-- wearing a window. These assert the MOUSE path.
check("minimap button exists after login", _G.NorgHearthMinimapButton ~= nil)
check("minimap button has a click handler",
      _G.NorgHearthMinimapButton and _G.NorgHearthMinimapButton._scripts["OnClick"] ~= nil)
check("a name box exists", _G.NorgHearthName ~= nil)
check("a Save button exists", _G.NorgHearthSave ~= nil)

-- (!) THE BUTTON SENDS A BARE SAVE. The server names the bind after the city
-- it sits in, so the client must NOT invent or require a name. If this ever
-- starts sending one again, the auto-naming is silently dead.
sent = {}
if _G.NorgHearthSave then _G.NorgHearthSave._scripts["OnClick"]() end
local savedMsg
for _, m in ipairs(sent) do if m:find("SAVE") then savedMsg = m end end
check("Save button sends a SAVE", savedMsg ~= nil, tostring(savedMsg))
check("Save button sends NO name -- the server derives it",
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
