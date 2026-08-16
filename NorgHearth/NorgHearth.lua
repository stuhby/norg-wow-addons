--[[----------------------------------------------------------------------------
  NorgHearth -- keep several hearthstone destinations and pick between them.

  /hs              open the window
  /hs save         remember where you are bound right now, named after the place
  /hs save <name>  the same, under a name you choose instead
  /hs use <n>      make saved bind <n> the live one
  /hs del <n>      forget saved bind <n>
  /hs list         print the list to chat

  ------------------------------------------------------------------------------
  HOW IT WORKS, because it is not what people assume.

  Nothing here touches the hearthstone. You bind at an innkeeper exactly as
  normal; SAVE copies the bind the SERVER already holds, naming it after the
  place that bind sits in unless you insist on a name of your own; USE asks
  the server to move your bind back to a saved one. The stone stays the ordinary
  stone -- same cast bar, same cooldown -- because it IS the ordinary stone, and
  this only ever changes where it points.

  That is also why there is no "bind to here" command: Save() in norg_home.cpp
  copies the homebind the core already holds (m_homebind*) and takes no
  coordinates from the client.

  (!) THE SLOT NUMBER IS NOT THE ROW NUMBER. Slots are reused after a delete, so
  a list can read 1, 3, 4 -- and row 2 is then slot 3. Every button carries the
  slot it was rendered with, never its position, or deleting one entry silently
  re-aims the buttons below it at their neighbours.

  (!) WHICH BIND IS LIVE IS THE SERVER'S ANSWER, AND THAT INCLUDES THE ANSWER
  "none of them". You can be bound at an inn you never saved, and the server
  says so by flagging every row 0. See the E| handler for what happens when
  that is treated as "nothing to update" instead of as an answer.

  (!) AND THAT ANSWER GOES STALE WHILE YOU LOOK AT IT. Binding at an innkeeper
  raises no event this addon registers, so an open window re-asks on a timer --
  see the OnUpdate note in Build for why polling, of all things, is the honest
  answer here.

  (!) A NEWLY COPIED ADDON IS INVISIBLE UNTIL A FULL CLIENT RESTART. 3.3.5a scans
  the AddOns folder at LAUNCH only; /reload will not find it. Rule that out
  before hunting for a bug behind "/hs did nothing".
------------------------------------------------------------------------------]]

-- (!) THE VERSION IS READ FROM THE .toc, NEVER COPIED INTO A CONSTANT HERE. The
-- login line below is step one of the wiki's troubleshooting page, and a second
-- copy of the number drifts from the .toc in silence, and nothing in the game can
-- then tell you which of the two you are reading. "?" means the client never
-- indexed this folder, which is itself the answer to "why is nothing happening".
local ADDON    = "NorgHearth"    -- FOLDER name; GetAddOnMetadata keys on that
local VERSION  = GetAddOnMetadata(ADDON, "Version") or "?"
local PREFIX   = "NORGHOME"      -- server module channel; the addon is NorgHearth
local MAX_ROWS = 8               -- must match MAX_BINDS in norg_home.cpp
local MAX_NAME = 24              -- must match the varchar(24) name column
local REFRESH_EVERY = 5          -- seconds between re-asks while the window is OPEN

local frame, rows, emptyFS
local sinceRefresh = 0 -- seconds the open window has gone without re-asking
local BuildMinimapButton   -- defined below; see the note at its definition
local binds   = {}     -- rendered list: { {slot, area, name}, ... } in slot order
local pending          -- rows arriving between H| batches; nil when not listing
local pendingCurrent   -- slot flagged live WITHIN that arriving list; nil = none
local current          -- slot the server says is the LIVE bind
local wantPrint        -- /hs list is waiting for the answer; see PrintList

-- (!) THE LOOKUP IS WRITTEN "REFUSAL[c] or <fallback>" (see the X| handler), AND
-- THE FALLBACK IS LOAD-BEARING. The server can grow a new refusal code long
-- before this addon is redistributed, and a missing entry must still say
-- something -- an unexplained silent no-op is the worst possible answer to
-- "why will it not save".
local REFUSAL = {
    NONAME   = "give it a name first  --  /hs save <name>",
    LONGNAME = "that name is too long (" .. MAX_NAME .. " characters at most).",
    -- (!) Worded for AUTO-NAMING -- the player usually never typed a name, so
    -- "that name is taken" would be baffling. But do not say "that PLACE", which
    -- an earlier wording did and which is wrong in both directions: DUPNAME is
    -- keyed on the NAME, so two different inns whose areas share a name collide
    -- (Caris Sunlance and Jarin Dawnglow both derive "Argent Tournament Ground"),
    -- and two binds at ONE inn under two typed names are both accepted.
    DUPNAME  = "you already have a bind saved under that name.",
    FULL     = "you already have " .. MAX_ROWS .. " saved binds -- delete one first.",
    NOSLOT   = "you have no saved bind with that number.",
    BADMAP   = "that bind is not usable any more -- bind at an innkeeper again.",
}

local function Say(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff69ccf0NorgHearth|r: " .. msg)
end

-- Control channel. The same whisper-to-self trick NorgNav and NorgQuest use: the
-- server module swallows the line before it reaches chat, so the worst case if
-- the module is missing is a line only you can see rather than public spam.
local function Send(cmd)
    local me = UnitName and UnitName("player")
    if me then SendChatMessage(PREFIX .. " " .. cmd, "WHISPER", nil, me) end
end

local function RequestList()
    -- (!) DROP ANY HALF-ARRIVED LIST FIRST. Batches accumulate until E| closes
    -- them, so a list that was interrupted -- by a zone change, a disconnect, or
    -- simply asking again -- would otherwise merge into the next one and show
    -- every entry twice. The half-arrived list's live-bind flag goes with it, or
    -- the abandoned list gets a vote in what the next one marks.
    pending, pendingCurrent = nil, nil
    -- EVERY re-ask restarts the open window's clock, not just the timed one. A
    -- list fetched because the window opened, or because a save landed, is as
    -- fresh as one the timer asked for, and following it a moment later with a
    -- second LIST is noise.
    sinceRefresh = 0
    Send("LIST")
end

--- Ask first, then show, so the request is already in flight when the window
--- appears. It does NOT make the window fresh: the rows on screen are still the
--- previous answer until the E| for this one lands (see the emptyFS note in
--- Build for the other half of that gap). Both ways in -- the slash toggle and
--- the minimap button -- go through here, so the ask cannot be wired to one and
--- forgotten on the other.
local function OpenWindow()
    if not frame then return end
    RequestList()
    frame:Show()
end

--- (!) STRIP THE FRAMING CHARACTERS HERE, BEFORE SENDING.
--- The server strips them too, and that is the check that counts -- but if only
--- the server stripped them, a name typed with a "|" in it would come back
--- spelled differently from what was typed, which reads as the addon mangling
--- it. Same alphabet as the server: printable ASCII, no "|" and no ":".
local function CleanName(s)
    if not s then return "" end
    s = s:gsub("[^ -~]", ""):gsub("[|:]", "")
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    return s
end

--- (!) PRINTS WHEN THE ANSWER ARRIVES, NOT WHEN THE COMMAND IS TYPED.
--- The list lives on the server. Printing whatever happened to be cached at the
--- moment /hs list was typed means a player who has not opened the window this
--- session is told "nothing saved yet" while holding eight binds -- and the real
--- answer then lands silently a moment later with nothing to show it. If the
--- server module is missing nothing prints at all, which is correct: the command
--- itself surfaces in chat as a whisper to yourself, and that IS the diagnosis.
local function PrintList()
    if #binds == 0 then
        Say("nothing saved yet -- bind at an innkeeper, then /hs and click Save.")
        return
    end
    for _, b in ipairs(binds) do
        Say(string.format("  %d. %s%s", b.slot, b.name,
            b.slot == current and "  |cff40ff40(current)|r" or ""))
    end
end

local function NameOfSlot(slot)
    for _, b in ipairs(binds) do
        if b.slot == slot then return b.name end
    end
end

-- ----------------------------------------------------------------------- render

local function Render()
    if not frame then return end

    for i = 1, MAX_ROWS do
        local r = rows[i]
        local b = binds[i]
        if b then
            -- (!) The button remembers the SLOT, not the row. See the header.
            r.slot = b.slot
            r.use:SetText((b.slot == current and "|cff40ff40>|r " or "") .. b.name)
            r.use:Show()
            r.del:Show()
        else
            -- (!) CLEAR THE SLOT, do not merely hide. Hiding is not enough on its
            -- own: a stale slot left on the button is a live wrong answer the
            -- moment the row is shown again for a different bind.
            r.slot = nil
            r.use:Hide()
            r.del:Hide()
        end
    end

    if #binds == 0 then emptyFS:Show() else emptyFS:Hide() end
end

-- ---------------------------------------------------------------------- actions

local function UseSlot(slot)
    if not slot then return end
    Send("USE " .. slot)
end

local function DelSlot(slot)
    if not slot then return end
    Send("DEL " .. slot)
end

local function SaveNamed(raw)
    local name = CleanName(raw)

    -- (!) AN EMPTY NAME IS NOW A REQUEST, NOT AN ERROR. Sending a bare SAVE
    -- asks the server to name the bind after the city it sits in. Refusing it
    -- here -- as this used to -- means the Save button silently sends nothing,
    -- which looks exactly like a dead button.
    if name == "" then
        Send("SAVE")
        return
    end
    if #name > MAX_NAME then
        -- Refuse rather than truncate: a silently shortened name is a bind that
        -- is not called what you called it. The server agrees for a name the
        -- player CHOSE, which is the only kind that reaches here -- it truncates
        -- only the names it derives itself (Save() in norg_home.cpp).
        Say(REFUSAL.LONGNAME)
        return
    end
    Send("SAVE " .. name)
end

-- ---------------------------------------------------------------- server replies

local function OnMessage(msg)
    local kind = msg:match("^(%a)|") or msg:match("^(%a)$")

    if kind == "H" then
        -- H|<slot>:<area>:<cur>:<name>|<slot>:...  -- one or more batches.
        pending = pending or {}
        for rec in msg:sub(3):gmatch("[^|]+") do
            -- The name is LAST and is the only free-text field, so ".*" can take
            -- the rest of the record including spaces without a delimiter fight.
            local slot, area, cur, name = rec:match("^(%d+):(%d+):([01]):(.*)$")
            if slot then
                slot = tonumber(slot)
                pending[#pending + 1] = { slot = slot, area = tonumber(area), name = name }
                -- (!) PARK IT, DO NOT APPLY IT. Writing straight to `current` here
                -- publishes half a list -- and, worse, cannot express "no row is
                -- live", because that answer is the ABSENCE of a flag rather than
                -- any record. E| below is what commits it.
                if cur == "1" then pendingCurrent = slot end
            end
        end
        return
    end

    if kind == "E" then
        -- (!) E| IS WHAT COMMITS THE LIST, INCLUDING E|0. Without treating the
        -- zero case as "the server says you have none", an empty answer would be
        -- indistinguishable from a reply that never arrived and the window would
        -- sit on stale rows forever.
        --
        -- (!) ASSIGN THE MARKER, NEVER MERGE IT. The server computes <cur> per row
        -- and an all-zero list is a real answer: you are bound at an inn you have
        -- not saved. An earlier cut only ever SET current -- it cleared it solely
        -- on E|0 -- so the arrow and "(current)" stayed beside whichever bind was
        -- live LAST. The intended flow is the worst case: bind at a new inn, open
        -- /hs to save it, and the panel spends that whole moment pointing at your
        -- PREVIOUS bind. Being a session variable it was honest after a fresh
        -- login, which is how it went unnoticed.
        binds = pending or {}
        current = pendingCurrent
        pending, pendingCurrent = nil, nil
        Render()
        if wantPrint then
            wantPrint = false
            PrintList()
        end
        return
    end

    local slot, _, name = msg:match("^A|(%d+)|(%d+)|(.*)$")
    if slot then
        Say("saved |cffffffff" .. name .. "|r.")
        RequestList()      -- the server assigns the slot, so re-read rather than guess
        return
    end

    slot = msg:match("^B|(%d+)|%d+$")
    if slot then
        slot = tonumber(slot)
        current = slot
        -- (!) FALL BACK TO THE NUMBER. "/hs use 2" typed before the list has ever
        -- been fetched is legal and works, and the addon simply does not know the
        -- name yet -- saying "bind 2" is right, saying "nil" is not.
        Say("hearthstone now set to |cffffffff" .. (NameOfSlot(slot) or ("bind " .. slot)) .. "|r.")
        Render()
        return
    end

    slot = msg:match("^R|(%d+)$")
    if slot then
        slot = tonumber(slot)
        local gone = NameOfSlot(slot) or ("bind " .. slot)
        for i = #binds, 1, -1 do
            if binds[i].slot == slot then table.remove(binds, i) end
        end
        if current == slot then current = nil end
        Say("forgot |cffffffff" .. gone .. "|r.")
        Render()
        return
    end

    local code = msg:match("^X|(%u+)$")
    if code then
        Say(REFUSAL[code] or ("refused (" .. code .. ")."))
        return
    end
end

-- ------------------------------------------------------------------------ frame

local function Build()
    local f = CreateFrame("Frame", "NorgHearthFrame", UIParent)
    -- (!) A REAL SIZE BEFORE SetBackdrop. A backdrop on a zero-size frame does
    -- not render at all -- the edge insets exceed the frame and there is nothing
    -- left to draw. This cost NorgOneBag a whole version.
    f:SetWidth(250)
    -- (!) THE HEIGHT IS DERIVED FROM THE LAYOUT, NOT GUESSED. 44 above the first
    -- row and 26 per row (both repeated in the row loop below), then the bottom
    -- strip read upwards from the Save button: 16 of padding, the 24 tall button,
    -- 10 of gap, room for a wrapped hint (42), 10 = 146. Move anything in the
    -- strip and move this with it, or the hint wraps out through the backdrop.
    f:SetHeight(146 + MAX_ROWS * 26)
    f:SetFrameStrata("HIGH")
    f:SetToplevel(true)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local p, _, rp, x, y = self:GetPoint()
        NorgHearthDB = NorgHearthDB or {}
        NorgHearthDB.pos = { p, rp, x, y }
    end)

    -- (!) THE OPEN WINDOW RE-ASKS ON A TIMER, BECAUSE NOTHING TELLS IT TO.
    -- Leave /hs open, walk to an innkeeper and bind: the server's answer has
    -- changed and this panel heard nothing, so it keeps the green arrow beside
    -- your PREVIOUS bind -- the same lie the E| handler exists to stop, arriving
    -- through a second door. Every other fetch waits on the player doing
    -- something -- opening the window, typing /hs list, or saving -- and none of
    -- those happen while they are away at the innkeeper.
    --
    -- No event was found to hang this on, which is why it is a timer:
    --   * CONFIRM_BINDER is the innkeeper's PROMPT ("make this your home?"),
    --     not the bind. Reasoning: it comes with the dialog, so it arrives
    --     before there is anything new to read and arrives whether you then
    --     accept or decline -- refreshing on it re-reads the OLD bind.
    --   * The bind actually landing reaches the client as SMSG_BINDPOINTUPDATE
    --     (norg_home.cpp sends one itself on USE, for the world map's home
    --     marker). Nothing turns that packet into an event this addon can
    --     register; HEARTHSTONE_BOUND is a later-client name and was not
    --     confirmed for this one.
    --     (!) DO NOT "FIX" THAT BY REGISTERING A LIKELY-LOOKING NAME. An event
    --     this client does not know never fires, silently, and the panel would
    --     then look repaired while going stale exactly as before. If a client
    --     is ever VERIFIED to raise one, register it AND keep this timer: the
    --     timer is what covers everything nobody thought of.
    --   * The SERVER cannot push it either. norg_home.cpp's header records that
    --     the core has no PlayerScript hook for homebind (only
    --     OnPlayerBindToInstance, which is instance saves), so the module never
    --     learns you rebound; it can only answer a LIST it was asked for.
    --
    -- So: poll, and only while the window is up. OnUpdate does not run on a
    -- hidden frame, so "only while open" costs nothing to enforce -- the IsShown
    -- check below is belt-and-braces for one case only, a later change that
    -- reparents or reuses this frame, and it is what lets the harness prove a
    -- closed window sends nothing. A timed self-whisper is not a new risk here:
    -- NorgQuest sends SCAN from its own OnUpdate on a RESCAN_SECS timer, gated
    -- on what is tracked rather than on anything being visible.
    -- (!) DO NOT SHORTEN THIS TO THE LENGTH OF A ROUND TRIP: a re-ask DISCARDS
    -- any half-arrived batch (see RequestList), so a period near the reply time
    -- would keep cancelling the answer it is waiting for. And on a server with
    -- no module the whisper is not swallowed, so an open window drips one
    -- visible line to yourself every REFRESH_EVERY seconds -- the same diagnosis
    -- the very first /hs already gave you, just repeated.
    f:SetScript("OnUpdate", function(self, elapsed)
        if not self:IsShown() then return end
        sinceRefresh = sinceRefresh + (elapsed or 0)
        if sinceRefresh >= REFRESH_EVERY then
            RequestList()          -- resets sinceRefresh; every re-ask does
        end
    end)

    f:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = false, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })

    local t = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    t:SetPoint("TOP", f, "TOP", 0, -16)
    t:SetText("Hearthstones")

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -6, -6)

    -- (!) STATE HERE, INSTRUCTION AT THE BOTTOM -- SAY IT IN ONE PLACE. This
    -- line sits near the top and hintFS at the foot of the window, and on a
    -- first run both are on screen telling the player to bind at an innkeeper
    -- and press Save. (An earlier cut was worse: they CONTRADICTED each other,
    -- this one asking for a typed name that the button no longer wanted.) The
    -- hint stays on screen and explains the naming too, so it keeps the sentence;
    -- this one is left saying only the thing the hint has no business repeating,
    -- that there is nothing in the list.
    -- (!) IT IS NOT A LOADING INDICATOR, and does not pretend to be one. It is
    -- drawn when the window is built and Render is what hides it, so on the
    -- first open of a session -- before any answer has arrived -- it says
    -- "nothing saved yet" about a list it has not seen. Afterwards it tracks the
    -- last answer that DID arrive rather than the one in flight, which is the
    -- same one-round-trip lag the rows have and not a standing lie. If that gap
    -- ever needs covering, hide this until the first E| rather than teaching the
    -- hint to say it as well.
    emptyFS = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    emptyFS:SetPoint("TOP", f, "TOP", 0, -52)
    emptyFS:SetWidth(210)
    emptyFS:SetJustifyH("CENTER")
    emptyFS:SetText("Nothing saved yet.")

    rows = {}
    for i = 1, MAX_ROWS do
        local y = -44 - (i - 1) * 26

        -- Named so a player can bind one to a macro, and so the test harness can
        -- click the REAL button rather than a re-implementation of it.
        local use = CreateFrame("Button", "NorgHearthRow" .. i, f, "UIPanelButtonTemplate")
        use:SetWidth(184)
        use:SetHeight(22)
        use:SetPoint("TOPLEFT", f, "TOPLEFT", 16, y)

        local del = CreateFrame("Button", "NorgHearthDel" .. i, f, "UIPanelButtonTemplate")
        del:SetWidth(22)
        del:SetHeight(22)
        del:SetPoint("TOPRIGHT", f, "TOPRIGHT", -16, y)
        del:SetText("X")

        local r = { use = use, del = del }
        use:SetScript("OnClick", function() UseSlot(r.slot) end)
        del:SetScript("OnClick", function() DelSlot(r.slot) end)
        use:Hide()
        del:Hide()
        rows[i] = r
    end

    -- ------------------------------------------------------------ bottom strip
    -- (!) ONE SAVE CONTROL, AND NO NAME BOX AT ALL. The server names a bind after
    -- the place its homebind sits in, rolling a subzone up to its zone -- an inn
    -- in Valley of Strength saves as "Orgrimmar" (PlaceName in norg_home.cpp) --
    -- so there is nothing here for the player to type. An earlier cut shipped
    -- still building the widgets that flow replaced, stacked over this button:
    --   NorgHearthName        a hidden EditBox, never given a SetPoint and
    --                         Hide()n at creation, so it could not take a
    --                         keystroke. Dead, and nothing read it.
    --   NorgHearthNameBox +   a visible box and a second small Save that read
    --   NorgHearthSaveButton  it and sent SAVE <whatever you typed>. That pair
    --                         WORKED -- it was the mouse route to a name of
    --                         your own.
    -- They sat over this button without stopping it working, so nothing
    -- MISBEHAVED and the pile survived review looking merely half-finished.
    --
    -- (!) SO THE REMOVAL WAS NOT FREE, whatever the "costs nothing" note that
    -- used to sit here claimed. What went with the pair is typing a name IN THE
    -- WINDOW. What did not: the slash handler parses its own argument and never
    -- read either box, so /hs save <name> still passes a chosen name through and
    -- the server still prefers it over the derived one -- see Save() in
    -- norg_home.cpp, where the name is derived only when the client sent none.
    -- The trade was deliberate: asking somebody to invent a label for the inn
    -- they just walked into is busywork whenever the city name is what they
    -- wanted anyway. It is still a trade, so restore the pair if the typed name
    -- ever turns out to be the common case -- do not restore it by accident.
    local save = CreateFrame("Button", "NorgHearthSave", f, "UIPanelButtonTemplate")
    save:SetWidth(200)
    save:SetHeight(24)
    save:SetPoint("BOTTOM", f, "BOTTOM", 0, 16)
    save:SetText("Save current location")
    save:SetScript("OnClick", function()
        -- Bare SAVE: the server derives the name from where you are bound.
        SaveNamed("")
    end)

    local hintFS = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hintFS:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 20, 50)
    hintFS:SetWidth(210)
    hintFS:SetJustifyH("LEFT")
    hintFS:SetText("Bind at an innkeeper, then click Save -- it is named after the city.")

    tinsert(UISpecialFrames, "NorgHearthFrame")   -- Escape closes it, like stock frames
    f:Hide()
    return f
end

-- ----------------------------------------------------------------------- events

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("CHAT_MSG_ADDON")

ev:SetScript("OnEvent", function(_, event, ...)
    if event == "PLAYER_LOGIN" then
        frame = Build()
        BuildMinimapButton()
        NorgHearthDB = NorgHearthDB or {}
        if NorgHearthDB.pos then
            local p, rp, x, y = unpack(NorgHearthDB.pos)
            frame:ClearAllPoints()
            frame:SetPoint(p, UIParent, rp, x, y)
        else
            frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
        end
        -- (!) NO LIST REQUEST AT LOGIN, deliberately. The window fetches when it
        -- opens, so the only thing an extra login request would buy is a warm
        -- name table for a "/hs use 2" typed blind -- which already has a
        -- fallback. One fewer chat line during the login storm is worth more.
        Say("v" .. VERSION .. " loaded. /hs for your saved hearthstones.")
        return
    end

    if event == "CHAT_MSG_ADDON" then
        local prefix, message = ...
        if prefix ~= PREFIX then return end
        OnMessage(message)
    end
end)

-- ---------------------------------------------------------------------- command

-- (!) A MINIMAP BUTTON, because "type /hs" is not a user interface. Position is
-- an angle around the minimap, kept in NorgHearthDB so it survives a reload and
-- can be dragged clear of whatever else is already clustered there. The .toc
-- declares that as "## SavedVariables", so the angle -- and the window position
-- saved next to it -- is shared by every character on the account.
function BuildMinimapButton()
    if NorgHearthMinimapButton then return end

    local b = CreateFrame("Button", "NorgHearthMinimapButton", Minimap)
    b:SetWidth(31)
    b:SetHeight(31)
    b:SetFrameStrata("MEDIUM")
    b:SetFrameLevel(8)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:RegisterForDrag("LeftButton")
    b:SetMovable(true)

    local icon = b:CreateTexture(nil, "BACKGROUND")
    -- The hearthstone's own icon, so it needs no explaining.
    icon:SetTexture("Interface\\Icons\\INV_Misc_Rune_01")
    icon:SetWidth(20)
    icon:SetHeight(20)
    icon:SetPoint("CENTER", b, "CENTER", 0, 1)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    local ring = b:CreateTexture(nil, "OVERLAY")
    ring:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    ring:SetWidth(53)
    ring:SetHeight(53)
    ring:SetPoint("TOPLEFT", b, "TOPLEFT", 0, 0)

    local function Place(angle)
        -- 80 puts the button out on the minimap ring rather than inside the map
        -- itself, where it would sit over the terrain and the blips.
        b:SetPoint("CENTER", Minimap, "CENTER",
                   80 * cos(angle), 80 * sin(angle))
    end

    NorgHearthDB = NorgHearthDB or {}
    Place(NorgHearthDB.minimapAngle or 200)

    b:SetScript("OnDragStart", function(self) self:SetScript("OnUpdate", function()
        local mx, my = Minimap:GetCenter()
        local cx, cy = GetCursorPosition()
        local sc = UIParent:GetEffectiveScale()
        cx, cy = cx / sc, cy / sc
        local angle = math.deg(math.atan2(cy - my, cx - mx))
        NorgHearthDB.minimapAngle = angle
        Place(angle)
    end) end)
    b:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)

    b:SetScript("OnClick", function()
        -- (!) KEEP THE ASSIGNMENT. `Build()` alone builds a second window and
        -- leaves the upvalue nil, so the very next line indexes nil. It never
        -- fires today -- PLAYER_LOGIN builds the frame before this button
        -- exists -- but a nil-guard that crashes when it triggers is worse than
        -- none at all.
        if not frame then frame = Build() end
        if frame:IsShown() then frame:Hide() else OpenWindow() end
    end)

    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("NorgHearth")
        GameTooltip:AddLine("Click to pick a hearthstone destination.", 1, 1, 1)
        GameTooltip:AddLine("Drag to move this button.", 0.6, 0.6, 0.6)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

SLASH_NORGHEARTH1 = "/hs"
SLASH_NORGHEARTH2 = "/norghearth"
SlashCmdList["NORGHEARTH"] = function(arg)
    arg = arg or ""
    -- (!) LOWER-CASE THE VERB ONLY. The tail is free text -- a name the player
    -- chose -- so lower-casing the whole line, which is the usual shape of a
    -- slash handler, would quietly rename "Dalaran" to "dalaran" on the way to
    -- the server.
    local cmd, rest = arg:match("^%s*(%S*)%s*(.-)%s*$")
    cmd = (cmd or ""):lower()

    if cmd == "help" or cmd == "?" then
        Say("/hs -- open the window;  /hs save [name] -- remember your current bind")
        Say("/hs use <n> / /hs del <n> -- switch to, or forget, a saved bind;  /hs list")
        Say("Binds come from innkeepers only: bind as normal, then save it here.")
        return
    end

    if cmd == "save" then SaveNamed(rest) return end
    if cmd == "use"  then UseSlot(tonumber(rest)) return end
    if cmd == "del"  then DelSlot(tonumber(rest)) return end

    if cmd == "list" then
        wantPrint = true
        RequestList()
        return
    end

    if not frame then return end
    if frame:IsShown() then
        frame:Hide()
    else
        OpenWindow()
    end
end

-- Exposed for the test harness (addon/hearth_test.lua). Reading state is fine;
-- the tests drive the addon through the same buttons and slash command a player
-- uses, so these exist to CHECK what happened, not to make it happen.
NorgHearth_Binds   = function() return binds end
NorgHearth_Current = function() return current end
