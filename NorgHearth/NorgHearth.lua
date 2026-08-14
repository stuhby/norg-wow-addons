--[[----------------------------------------------------------------------------
  NorgHearth -- keep several hearthstone destinations and pick between them.

  /hs              open the window
  /hs save <name>  remember where you are bound right now, under that name
  /hs use <n>      make saved bind <n> the live one
  /hs del <n>      forget saved bind <n>
  /hs list         print the list to chat

  ------------------------------------------------------------------------------
  HOW IT WORKS, because it is not what people assume.

  Nothing here touches the hearthstone. You bind at an innkeeper exactly as
  normal; SAVE copies the bind the SERVER already holds, under a name; USE asks
  the server to move your bind back to a saved one. The stone stays the ordinary
  stone -- same cast bar, same 30 minute cooldown -- because it IS the ordinary
  stone, and this only ever changes where it points.

  That is also why there is no "bind to here" command: the only way a bind gets
  into this list is by having been made at an innkeeper in the first place.

  (!) THE SLOT NUMBER IS NOT THE ROW NUMBER. Slots are reused after a delete, so
  a list can read 1, 3, 4 -- and row 2 is then slot 3. Every button carries the
  slot it was rendered with, never its position, or deleting one entry silently
  re-aims the buttons below it at their neighbours.

  (!) A NEWLY COPIED ADDON IS INVISIBLE UNTIL A FULL CLIENT RESTART. 3.3.5a scans
  the AddOns folder at LAUNCH only; /reload will not find it. "/hs did nothing"
  is nearly always this rather than a bug.
------------------------------------------------------------------------------]]

local VERSION  = "1.0"
local PREFIX   = "NORGHOME"      -- server module channel; the addon is NorgHearth
local MAX_ROWS = 8               -- must match MAX_BINDS in norg_home.cpp
local MAX_NAME = 24              -- must match the varchar(24) name column

local frame, rows, nameBox, emptyFS
local BuildMinimapButton   -- defined below; see the note at its definition
local binds   = {}     -- rendered list: { {slot, area, name}, ... } in slot order
local pending          -- rows arriving between H| batches; nil when not listing
local current          -- slot the server says is the LIVE bind
local wantPrint        -- /hs list is waiting for the answer; see PrintList

-- (!) EVERY LOOKUP IS WRITTEN "REFUSAL[c] or <fallback>", AND THE FALLBACK IS
-- LOAD-BEARING. The server can grow a new refusal code long before this addon is
-- redistributed, and a missing entry must still say something -- an unexplained
-- silent no-op is the worst possible answer to "why will it not save".
local REFUSAL = {
    NONAME   = "give it a name first  --  /hs save <name>",
    LONGNAME = "that name is too long (" .. MAX_NAME .. " characters at most).",
    -- (!) Worded for AUTO-NAMING. Binds are named after the place now, so a
    -- collision means you already saved this location -- the player never typed
    -- a name, and telling them one is taken would be baffling.
    DUPNAME  = "you already have a bind saved for that place.",
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
    -- every entry twice.
    pending = nil
    Send("LIST")
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
        Say("nothing saved yet -- bind at an innkeeper, then /hs save <name>.")
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
            -- (!) CLEAR THE SLOT, do not merely hide. A hidden button cannot be
            -- clicked in game, but a stale slot left on it is a live wrong answer
            -- the moment the row is shown again for a different bind.
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
        -- Refuse rather than truncate, exactly as the server does: a silently
        -- shortened name is a bind that is not called what you called it.
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
                if cur == "1" then current = slot end
            end
        end
        return
    end

    if kind == "E" then
        -- (!) E| IS WHAT COMMITS THE LIST, INCLUDING E|0. Without treating the
        -- zero case as "the server says you have none", an empty answer would be
        -- indistinguishable from a reply that never arrived and the window would
        -- sit on stale rows forever.
        local n = tonumber(msg:match("^E|(%d+)")) or 0
        binds = pending or {}
        pending = nil
        if n == 0 then current = nil end
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
    f:SetHeight(186 + MAX_ROWS * 26)
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

    emptyFS = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    emptyFS:SetPoint("TOP", f, "TOP", 0, -52)
    emptyFS:SetWidth(210)
    emptyFS:SetJustifyH("CENTER")
    emptyFS:SetText("Nothing saved yet. Bind at an innkeeper, then type a name below and Save.")

    rows = {}
    -- (!) NO TYPING REQUIRED. Everything here was reachable only through
    -- /hs save <name>, which is a chat command wearing a window. The name box
    -- and Save button below make the whole feature usable with the mouse; the
    -- slash commands stay as an alias, not as the interface.
    -- (!) NO NAME TO TYPE. The server names a bind after the CITY it sits in --
    -- an inn in Valley of Strength saves as "Orgrimmar" -- so the box that used
    -- to be here was asking the player to invent a label for a place they had
    -- just walked to. One button, no keyboard. The EditBox stays but hidden, so
    -- /hs save <name> can still push a chosen name down the same path.
    local box = CreateFrame("EditBox", "NorgHearthName", f, "InputBoxTemplate")
    box:SetAutoFocus(false)
    box:SetMaxLetters(24)
    box:Hide()

    local save = CreateFrame("Button", "NorgHearthSave", f, "UIPanelButtonTemplate")
    save:SetWidth(200)
    save:SetHeight(24)
    save:SetPoint("BOTTOM", f, "BOTTOM", 0, 18)
    save:SetText("Save current location")

    local hintFS = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hintFS:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 20, 42)
    hintFS:SetWidth(214)
    hintFS:SetJustifyH("LEFT")
    hintFS:SetText("Bind at an innkeeper, then click Save -- it is named after the city.")

    local function DoSave()
        -- Bare SAVE: the server derives the name from where you are bound.
        SaveNamed("")
    end
    save:SetScript("OnClick", DoSave)
    -- Enter saves too; Escape gets you out without the box eating the key.
    box:SetScript("OnEnterPressed", DoSave)
    box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

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

    nameBox = CreateFrame("EditBox", "NorgHearthNameBox", f, "InputBoxTemplate")
    nameBox:SetWidth(140)
    nameBox:SetHeight(20)
    nameBox:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 22, 22)
    nameBox:SetAutoFocus(false)
    nameBox:SetMaxLetters(MAX_NAME)

    local save = CreateFrame("Button", "NorgHearthSaveButton", f, "UIPanelButtonTemplate")
    save:SetWidth(70)
    save:SetHeight(22)
    save:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -16, 20)
    save:SetText("Save")

    local function SaveFromBox()
        SaveNamed(nameBox:GetText())
        nameBox:SetText("")
        nameBox:ClearFocus()
    end
    save:SetScript("OnClick", SaveFromBox)
    nameBox:SetScript("OnEnterPressed", SaveFromBox)
    nameBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

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
-- an angle around the minimap, saved per character, so it survives a reload and
-- does not fight whatever else is already clustered there.
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
        -- 80 is the minimap radius plus the button's own half-width; the button
        -- sits ON the ring rather than inside it, which is where every other
        -- addon puts theirs.
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
        if not frame then Build() end
        if frame:IsShown() then frame:Hide() else RequestList() frame:Show() end
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
    -- (!) LOWER-CASE THE VERB ONLY. Lower-casing the whole line -- which is what
    -- every other Norg addon does, because none of them carry free text -- would
    -- quietly rename "Dalaran" to "dalaran" on the way to the server.
    local cmd, rest = arg:match("^%s*(%S*)%s*(.-)%s*$")
    cmd = (cmd or ""):lower()

    if cmd == "help" or cmd == "?" then
        Say("/hs -- open the window;  /hs save <name> -- remember your current bind")
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
        RequestList()
        frame:Show()
    end
end

-- Exposed for the test harness (addon/hearth_test.lua). Reading state is fine;
-- the tests drive the addon through the same buttons and slash command a player
-- uses, so these exist to CHECK what happened, not to make it happen.
NorgHearth_Binds   = function() return binds end
NorgHearth_Current = function() return current end
