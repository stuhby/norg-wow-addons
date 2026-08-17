-- !NorgBugs -- a minimal Lua error catcher for WoW 3.3.5a (Interface 30300).
--
-- WHY THIS EXISTS: none of the Norg client addons had ever run in a real game client, so an
-- error in any of them failed SILENTLY -- the addon simply did nothing and looked "broken"
-- rather than reporting why. BugSack's maintained builds target Classic/retail, so instead of
-- chasing a back-port this does the one job actually needed: catch errors, keep them across a
-- relog, and show them in a box you can SELECT AND COPY so the text can be pasted back verbatim.
--
-- (!) THE FOLDER NAME STARTS WITH "!" ON PURPOSE. WoW loads addon folders in listing order and
-- "!" sorts ahead of letters, so this installs its error handler BEFORE the other Norg addons
-- load and therefore catches their LOAD-TIME errors too. Rename the folder and you silently
-- lose every error raised during startup -- which is exactly when an untested addon fails.
-- (This is the same reason the well-known !BugGrabber uses the prefix.)
--
-- 3.3.5a API notes, learned the hard way elsewhere in this project:
--   * there is no Frame:SetSize() in this client -- SetWidth/SetHeight only
--   * FontString has no SetScript
--   * SetBackdrop is a plain frame method here (no BackdropTemplate, that is retail)

local MAX_KEPT      = 60   -- cap the list; SavedVariables is rewritten wholesale on logout
local CHAT_THROTTLE = 3    -- seconds between chat nudges, so a loop cannot spam the frame

-- Errors can arrive BEFORE this addon's SavedVariables table exists, which is precisely the
-- startup window we care most about. Buffer them here and flush once the DB is real.
local pending = {}
local db      = nil

local lastNudge  = 0
local inHandler  = false   -- recursion guard: an error raised inside the handler must not loop
local totalSeen  = 0

local frame, editBox, Refresh

local function Now()
    -- date() is available in this client; GetTime() is a monotonic float since login.
    return date("%H:%M:%S")
end

local function Nudge()
    local t = GetTime()
    if t - lastNudge < CHAT_THROTTLE then return end
    lastNudge = t
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage(
            "|cffff4040NorgBugs:|r caught a Lua error (" .. totalSeen ..
            " this session) -- type |cffffff00/bugs|r to read and copy it.")
    end
end

-- Store one error, de-duplicated on its message text. A single broken OnUpdate can fire
-- thousands of times a minute; keeping a count instead of a row each is the difference between
-- a readable list and an unusable one.
local function Record(rawMsg)
    local msg   = tostring(rawMsg or "unknown error")
    local stack = debugstack(4, 8, 2) or "(no stack)"
    local store = db or pending

    totalSeen = totalSeen + 1

    for i = 1, #store do
        if store[i].msg == msg then
            store[i].count = store[i].count + 1
            store[i].last  = Now()
            if Refresh and frame and frame:IsShown() then Refresh() end
            Nudge()
            return
        end
    end

    table.insert(store, 1, {
        msg   = msg,
        stack = stack,
        count = 1,
        first = Now(),
        last  = Now(),
    })
    while #store > MAX_KEPT do table.remove(store) end

    if Refresh and frame and frame:IsShown() then Refresh() end
    Nudge()
end

-- The handler itself must never be able to break error reporting, so the body is pcall'd. If
-- even that fails there is nothing useful left to do but stay silent rather than recurse.
local function Handler(msg)
    if inHandler then return end
    inHandler = true
    pcall(Record, msg)
    inHandler = false
end

seterrorhandler(Handler)

----------------------------------------------------------------------------------------------
-- UI
----------------------------------------------------------------------------------------------

local function BuildFrame()
    if frame then return frame end

    local f = CreateFrame("Frame", "NorgBugsFrame", UIParent)
    f:SetWidth(720)
    f:SetHeight(460)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile     = true, tileSize = 32, edgeSize = 32,
        insets   = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)

    -- Lets Escape close the window. Works in 3.3.5a and costs nothing.
    table.insert(UISpecialFrames, "NorgBugsFrame")

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -17)
    title:SetText("NorgBugs")

    local hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("TOP", title, "BOTTOM", 0, -3)
    hint:SetText("Click in the text, Ctrl+A then Ctrl+C to copy everything")

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -7, -7)

    local scroll = CreateFrame("ScrollFrame", "NorgBugsScroll", f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 20, -62)
    scroll:SetPoint("BOTTOMRIGHT", -40, 48)

    local eb = CreateFrame("EditBox", nil, scroll)
    eb:SetMultiLine(true)
    eb:SetAutoFocus(false)
    eb:SetFontObject(ChatFontNormal)
    eb:SetWidth(640)
    eb:SetHeight(1)            -- grows to fit its text once SetText runs
    eb:SetScript("OnEscapePressed", function() f:Hide() end)
    scroll:SetScrollChild(eb)
    editBox = eb

    local clear = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    clear:SetWidth(100)
    clear:SetHeight(22)
    clear:SetPoint("BOTTOMRIGHT", -22, 18)
    clear:SetText("Clear")
    clear:SetScript("OnClick", function()
        if db then wipe(db) end
        wipe(pending)
        totalSeen = 0
        Refresh()
    end)

    frame = f
    return f
end

Refresh = function()
    if not editBox then return end
    local store = db or pending
    local out   = {}

    if #store == 0 then
        out[1] = "No Lua errors recorded.\n\nThat is the result we want -- it means every loaded"
              .. " addon initialised and ran without raising."
    else
        table.insert(out, "|cffffff00" .. #store .. "|r distinct error(s) recorded."
                       .. " Newest first.\n")
        for i = 1, #store do
            local e = store[i]
            table.insert(out, ("[%d] %s%s\n%s\n%s\n"):format(
                i,
                e.msg,
                e.count > 1 and ("   (x" .. e.count .. ", first " .. (e.first or "?")
                                 .. ", last " .. (e.last or "?") .. ")") or
                                ("   (" .. (e.first or "?") .. ")"),
                "----- stack -----",
                e.stack or "(no stack)"))
        end
    end

    editBox:SetText(table.concat(out, "\n"))
    editBox:SetCursorPosition(0)
end

----------------------------------------------------------------------------------------------
-- Wiring
----------------------------------------------------------------------------------------------

local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:SetScript("OnEvent", function(_, _, name)
    if name ~= "!NorgBugs" then return end

    NorgBugsDB = NorgBugsDB or {}
    db = NorgBugsDB

    -- Flush anything caught before the DB existed, preserving newest-first order.
    for i = #pending, 1, -1 do
        table.insert(db, 1, pending[i])
    end
    wipe(pending)
    while #db > MAX_KEPT do table.remove(db) end

    if #db > 0 and DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage(
            "|cffff4040NorgBugs:|r " .. #db .. " error(s) carried over from a previous session"
            .. " -- |cffffff00/bugs|r to read them.")
    end

    loader:UnregisterEvent("ADDON_LOADED")
end)

SLASH_NORGBUGS1 = "/bugs"
SLASH_NORGBUGS2 = "/norgbugs"
SlashCmdList["NORGBUGS"] = function(arg)
    arg = (arg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")

    if arg == "clear" then
        if db then wipe(db) end
        wipe(pending)
        totalSeen = 0
        if frame and frame:IsShown() then Refresh() end
        DEFAULT_CHAT_FRAME:AddMessage("|cff40ff40NorgBugs:|r cleared.")
        return
    end

    if arg == "test" then
        -- Deliberately raise one, to prove the catcher is actually installed. Without this
        -- there is no way to distinguish "no errors" from "the catcher never hooked".
        local ok, err = pcall(function() error("NorgBugs self-test -- this error is intentional") end)
        if not ok then Handler(err) end
        DEFAULT_CHAT_FRAME:AddMessage("|cff40ff40NorgBugs:|r self-test raised; /bugs should show it.")
        return
    end

    BuildFrame()
    Refresh()
    if frame:IsShown() then frame:Hide() else frame:Show() end
end
