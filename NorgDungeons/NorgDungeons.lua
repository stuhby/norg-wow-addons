--[[----------------------------------------------------------------------------
  NorgDungeons -- dungeon and raid maps, boss order, and live kill tracking.

  DATA PROVENANCE
  Artwork and the painted-marker legend come from Atlas. The boss list, encounter
  ORDER and the NPC names come from the Norg server's own database. Where they
  disagree the server wins, because that is what you will actually fight -- for
  example Atlas paints Lord Cobrahn as marker 2 and Lady Anacondra as 3, but the
  server's encounter order makes Anacondra boss #1.

  Marker numbers and boss numbers are DIFFERENT THINGS and both are shown:
     marker  = the number painted on the map artwork (where it is)
     boss #  = the encounter order from the server    (what to kill next)

  KILL TRACKING resets when you leave, EXCEPT where the instance is saved (raid
  lockouts). Bosses you downed in a saved raid stay dead server-side, so clearing
  them on exit would lie to you on the way back in.
------------------------------------------------------------------------------]]

local ADDON = "NorgDungeons"

local frame, mapTex, listFrame, titleFS, lines = nil, nil, nil, nil, {}
local currentKey, killed = nil, {}

local COL_BOSS   = "|cffffd100"   -- gold: an ordered boss
local COL_RARE   = "|cffa335ee"   -- purple: rare spawn
local COL_PLAIN  = "|cffcccccc"   -- grey-white: npc, quest giver, vendor
local COL_DEAD   = "|cff707070"   -- dim: already killed

local function norm(s)
    if not s then return "" end
    return (s:lower():gsub("^the%s+", ""):gsub("[^%w]", ""))
end

-- Find the atlas key for the instance we are standing in. Prefer an exact name
-- match, then fall back to the server map id -- several atlas keys can share one
-- map (Scarlet Monastery is four maps, one instance), so name is the better key
-- and map id is the safety net.
local function FindKey()
    local iname = GetInstanceInfo and GetInstanceInfo() or nil
    local target = norm(iname)

    if target ~= "" then
        for key, d in pairs(NorgDungeons or {}) do
            if norm(key) == target then return key end
        end
        for key, d in pairs(NorgDungeons or {}) do
            local n = norm(key)
            if n ~= "" and (n:find(target, 1, true) or target:find(n, 1, true)) then
                return key
            end
        end
    end
    return nil
end

local function IsSaved()
    -- Raid lockouts: bosses stay dead server-side across a leave/return.
    if not GetNumSavedInstances then return false end
    local iname = GetInstanceInfo and GetInstanceInfo() or nil
    if not iname then return false end
    for i = 1, GetNumSavedInstances() do
        local n, _, reset = GetSavedInstanceInfo(i)
        if n == iname and reset and reset > 0 then return true end
    end
    return false
end

local function Render()
    for _, fs in ipairs(lines) do fs:Hide() end
    if not currentKey then
        titleFS:SetText("Dungeons")
        mapTex:SetTexture(nil)
        return
    end

    local d = NorgDungeons[currentKey]
    titleFS:SetText(currentKey .. (d.lvl ~= "" and ("  |cff808080(" .. d.lvl .. ")|r") or ""))
    mapTex:SetTexture("Interface\\AddOns\\NorgDungeons\\Images\\" .. currentKey)

    -- (!) The longest legend is 49 entries (CoT Old Hillsbrad) = 588px, which
    -- overflowed the 460px content area and ran off the bottom of the frame with
    -- no scrollbar and no clue anything was missing. Spill into a second column
    -- once a single column would not fit.
    local ROW_H, PER_COL = 12, 34
    local twoCol = #d.e > PER_COL
    local y = -4
    for i, e in ipairs(d.e) do
        local fs = lines[i]
        if not fs then
            fs = listFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            fs:SetJustifyH("LEFT")
            lines[i] = fs
        end
        -- colIdx, NOT col -- there is already a colour variable named col below
        -- and shadowing it works only by accident of declaration order.
        local colIdx = twoCol and math.floor((i - 1) / PER_COL) or 0
        local row = twoCol and ((i - 1) % PER_COL) or (i - 1)
        y = -4 - row * ROW_H
        fs:ClearAllPoints()
        fs:SetPoint("TOPLEFT", listFrame, "TOPLEFT", 2 + colIdx * 150, y)

        local dead = killed[e.id]
        local col  = dead and COL_DEAD
                     or (e.b > 0 and COL_BOSS)
                     or (e.t == "rare" and COL_RARE)
                     or COL_PLAIN

        -- marker number is where it is on the art; boss number is the route order
        local mark = (e.m ~= "" and e.m or "-")
        local order = e.b > 0 and (" |cff00ff00[" .. e.b .. "]|r") or ""
        if dead then order = " |cff707070[done]|r" end
        local tag = (e.t ~= "" and not dead) and (" |cff808080(" .. e.t .. ")|r") or ""

        fs:SetText(string.format("%s%-3s %s|r%s%s", col, mark, e.n, order, tag))
        fs:Show()
    end
end

local function OnDeath(guid)
    -- Creature GUIDs embed the entry id in 3.3.5a: 0xF13000<entry>xxxxxx
    if not guid then return end
    local entry = tonumber(guid:sub(9, 12), 16)
    if not entry then return end
    if killed[entry] then return end
    killed[entry] = true
    Render()
end

local function Build()
    local f = CreateFrame("Frame", "NorgDungeonsFrame", UIParent)
    f:SetWidth(830)   -- room for a second legend column
    f:SetHeight(520)
    f:SetFrameStrata("HIGH")
    f:SetToplevel(true)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local p, _, rp, x, y = self:GetPoint()
        NorgDungeonsDB = NorgDungeonsDB or {}
        NorgDungeonsDB.pos = { p, rp, x, y }
    end)
    f:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = false, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })

    titleFS = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    titleFS:SetPoint("TOP", f, "TOP", 0, -14)

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -6, -6)

    -- Map on the left, legend on the right.
    mapTex = f:CreateTexture(nil, "ARTWORK")
    mapTex:SetPoint("TOPLEFT", f, "TOPLEFT", 18, -44)
    mapTex:SetWidth(460)
    mapTex:SetHeight(440)

    listFrame = CreateFrame("Frame", nil, f)
    listFrame:SetPoint("TOPLEFT", f, "TOPLEFT", 494, -44)
    listFrame:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -16, 16)

    tinsert(UISpecialFrames, "NorgDungeonsFrame")
    f:Hide()
    return f
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:RegisterEvent("ZONE_CHANGED_NEW_AREA")
ev:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")

ev:SetScript("OnEvent", function(_, event, ...)
    if event == "PLAYER_LOGIN" then
        frame = Build()
        NorgDungeonsDB = NorgDungeonsDB or {}
        if NorgDungeonsDB.pos then
            local p, rp, x, y = unpack(NorgDungeonsDB.pos)
            frame:SetPoint(p, UIParent, rp, x, y)
        else
            frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
        end
        local n = 0
        for _ in pairs(NorgDungeons or {}) do n = n + 1 end
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00NorgDungeons|r loaded: " .. n .. " maps. /dungeon to open.")
        return
    end

    if not frame then return end

    if event == "COMBAT_LOG_EVENT_UNFILTERED" then
        local _, sub, _, _, _, destGUID = ...
        if sub == "UNIT_DIED" or sub == "PARTY_KILL" then OnDeath(destGUID) end
        return
    end

    -- zoning
    local key = FindKey()
    if key ~= currentKey then
        currentKey = key
        -- Reset kills on a NEW instance, but keep them for a saved raid lockout,
        -- where the server still considers those bosses dead.
        if not IsSaved() then killed = {} end
        Render()
        if key and IsInInstance and IsInInstance() then frame:Show() end
    end
end)

SLASH_NORGDUNGEONS1 = "/dungeon"
SLASH_NORGDUNGEONS2 = "/dung"
SlashCmdList["NORGDUNGEONS"] = function(arg)
    if not frame then return end
    if arg and arg ~= "" then
        local target = norm(arg)
        for key in pairs(NorgDungeons or {}) do
            if norm(key):find(target, 1, true) then
                currentKey = key; Render(); frame:Show(); return
            end
        end
        DEFAULT_CHAT_FRAME:AddMessage("|cffff0000NorgDungeons|r: no map matching \"" .. arg .. "\"")
        return
    end
    if frame:IsShown() then frame:Hide() else
        if not currentKey then currentKey = FindKey() end
        Render(); frame:Show()
    end
end
