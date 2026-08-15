--[[----------------------------------------------------------------------------
  NorgRoutes -- boss order and directions for every dungeon and raid.

  Data is GENERATED from the Norg server database (instance_encounters joined to
  creature spawns), not hand authored, so it matches this server exactly. See
  gen-routes-addon.sh.

  DELIBERATELY NOT A MAP ADDON. Atlas already does dungeon maps well, and
  bundling its artwork would mean redistributing someone else's work. If Atlas is
  installed this addon says so and leaves the map side to it; what it adds is the
  boss ORDER and the bearing/distance between bosses, which Atlas does not have.

  WHY NOT AN ARROW: 3.3.5a's GetPlayerMapPosition() is map-relative, and classic
  dungeons have no world map at all -- inside Wailing Caverns the client cannot
  tell an addon where you are. A live arrow needs the SERVER to push coordinates
  over an addon channel, which is a much larger build. This is the static version.
------------------------------------------------------------------------------]]

local ADDON = "NorgRoutes"

-- (!) THE VERSION IS READ FROM THE .toc, NEVER COPIED INTO A CONSTANT HERE. The
-- login line is step one of the wiki's troubleshooting page, and a second copy of
-- the number drifts from the .toc in silence, and nothing in the game can then
-- tell you which of the two you are reading. "?" means the client never indexed
-- this folder, which is itself the answer to "why is nothing happening".
local VERSION = GetAddOnMetadata(ADDON, "Version") or "?"

local frame, content, lines = nil, nil, {}
local currentMap = nil

-- Normalise for matching: GetInstanceInfo() returns e.g. "Wailing Caverns" while
-- the generated names come from areatrigger_teleport and may differ in case,
-- spacing or a leading "The".
local function norm(s)
    if not s then return "" end
    s = s:lower():gsub("^the%s+", ""):gsub("[^%w]", "")
    return s
end

local function FindMapByName(name)
    local target = norm(name)
    if target == "" then return nil end
    for mapId, data in pairs(NorgRoutes or {}) do
        if norm(data.name) == target then return mapId end
    end
    -- fall back to a containment match ("Wailing Caverns" vs "Wailing Caverns D1")
    for mapId, data in pairs(NorgRoutes or {}) do
        local n = norm(data.name)
        if n ~= "" and (n:find(target, 1, true) or target:find(n, 1, true)) then
            return mapId
        end
    end
    return nil
end

local function ClearLines()
    for _, fs in ipairs(lines) do fs:Hide() end
end

local function Render(mapId)
    ClearLines()
    currentMap = mapId

    local data = NorgRoutes and NorgRoutes[mapId]
    if not data then
        frame.title:SetText("Routes")
        return
    end

    frame.title:SetText(data.name)

    local y = -8
    for i, b in ipairs(data.bosses) do
        local fs = lines[i]
        if not fs then
            fs = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            fs:SetJustifyH("LEFT")
            lines[i] = fs
        end
        fs:ClearAllPoints()
        fs:SetPoint("TOPLEFT", content, "TOPLEFT", 4, y)

        local text
        if b.d == "" or b.y == 0 then
            -- First boss: no previous point to take a bearing from.
            text = string.format("|cffffd100%d.|r %s  |cff808080(first)|r", i, b.n)
        else
            text = string.format("|cffffd100%d.|r %s  |cff808080-- %s, %d yd|r", i, b.n, b.d, b.y)
        end
        fs:SetText(text)
        fs:Show()
        y = y - 16
    end

    frame:SetHeight(math.max(120, 70 + #data.bosses * 16))
end

local function AutoDetect()
    local name = GetInstanceInfo and GetInstanceInfo() or nil
    if not name or name == "" then name = GetRealZoneText and GetRealZoneText() or nil end

    local mapId = FindMapByName(name)
    if mapId then
        Render(mapId)
        return true
    end

    ClearLines()
    frame.title:SetText("Routes")
    local fs = lines[1]
    if not fs then
        fs = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        fs:SetJustifyH("LEFT")
        lines[1] = fs
    end
    fs:ClearAllPoints()
    fs:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -8)
    fs:SetText("|cff808080No route for \"" .. tostring(name) .. "\".\nUse /route <name> to pick one.|r")
    fs:Show()
    frame:SetHeight(140)
    return false
end

local function Build()
    local f = CreateFrame("Frame", "NorgRoutesFrame", UIParent)
    f:SetWidth(300)
    f:SetHeight(200)
    f:SetFrameStrata("HIGH")
    f:SetToplevel(true)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local p, _, rp, x, y = self:GetPoint()
        NorgRoutesDB = NorgRoutesDB or {}
        NorgRoutesDB.pos = { p, rp, x, y }
    end)
    f:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = false, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })

    local t = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    t:SetPoint("TOP", f, "TOP", 0, -14)
    f.title = t

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -6, -6)

    content = CreateFrame("Frame", nil, f)
    content:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -40)
    content:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -14, 14)

    tinsert(UISpecialFrames, "NorgRoutesFrame")
    f:Hide()
    return f
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:RegisterEvent("ZONE_CHANGED_NEW_AREA")

ev:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
        frame = Build()
        NorgRoutesDB = NorgRoutesDB or {}
        if NorgRoutesDB.pos then
            local p, rp, x, y = unpack(NorgRoutesDB.pos)
            frame:SetPoint(p, UIParent, rp, x, y)
        else
            frame:SetPoint("CENTER", UIParent, "CENTER", -250, 0)
        end

        local n = 0
        for _ in pairs(NorgRoutes or {}) do n = n + 1 end
        local msg = "|cff00ff00NorgRoutes|r v" .. VERSION ..
            " loaded: " .. n .. " instances. /route to open."
        if IsAddOnLoaded and IsAddOnLoaded("Atlas") then
            msg = msg .. " |cff808080(Atlas detected)|r"
        end
        DEFAULT_CHAT_FRAME:AddMessage(msg)

    elseif frame then
        -- Entering an instance: refresh, and pop the window if we know the place.
        if AutoDetect() and IsInInstance and IsInInstance() then
            frame:Show()
        end
    end
end)

SLASH_NORGROUTES1 = "/route"
SlashCmdList["NORGROUTES"] = function(arg)
    if not frame then return end

    if arg and arg ~= "" then
        local mapId = FindMapByName(arg)
        if mapId then
            Render(mapId)
            frame:Show()
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cffff0000NorgRoutes|r: no instance matching \"" .. arg .. "\"")
        end
        return
    end

    if frame:IsShown() then
        frame:Hide()
    else
        AutoDetect()
        frame:Show()
    end
end
