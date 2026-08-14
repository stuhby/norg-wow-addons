--[[----------------------------------------------------------------------------
  NorgQuest -- drawing the route on the world map.

  The server sends the committed navmesh route, simplified to about thirty points
  and converted to zone-relative coordinates, as W| chunks. This draws it.

  (!) WHY DOTS AND NOT LINES
  3.3.5a has no Texture:SetRotation -- it arrived in 4.0 -- so a straight segment
  at an arbitrary angle cannot be drawn as a stretched texture. The eight-argument
  SetTexCoord CAN rotate, which is how the arrow works, but a rotated square is
  not a line: you would also need to scale it along one axis, and the corner
  transform does not give you that cleanly. Interpolating small dots along each
  segment is what every map addon of this era does, and it reads better anyway at
  map scale because it stays legible when the line doubles back.

  (!) THE MAP IS TWO-DIMENSIONAL. A route that climbs or descends projects onto
  the same place, so the line crosses itself on multi-level terrain. There is no
  fix for that -- the map has no third dimension to draw into. What CAN be done is
  making the crossing readable rather than confusing: the dots fade from dim to
  bright along the route, so where the line overlaps you can still tell which way
  you are meant to be going.

  (!) COORDINATES ARE PER-ZONE. Each point carries its own zone id, because a
  route crosses zone boundaries and drawing a Barrens point on the Durotar map
  would smear the line across the border instead of stopping at it. Only points
  belonging to the zone currently on screen are drawn.
------------------------------------------------------------------------------]]

local DOT_SPACING   = 0.012   -- fraction of map width between dots
local DOT_SIZE      = 5
local MAX_DOTS      = 220     -- hard ceiling; a huge route must not spawn textures forever

local overlay, dots, points, pending = nil, {}, {}, {}
local shownZone

-- (!) Parent to WorldMapButton, not WorldMapFrame. This is the pattern
-- QuestHelper uses and it is the one that actually clips and scales with the map
-- artwork; anchoring to the outer frame leaves markers floating over the border
-- when the map is resized.
-- (!) NO SCROLLFRAME. This is why the line never appeared.
--
-- The container used to be a ScrollFrame's SCROLL CHILD. A scroll child is
-- positioned by the scroll frame rather than by its own anchors, so
-- SetAllPoints() gives it NO DIMENSIONS -- GetWidth() returns 0. Redraw()
-- then hit its own `if not w or w <= 0 then HideFrom(1) return end` guard and
-- returned before placing a single dot. Every other part of the chain worked,
-- which is what made this so hard to see: the server built the route, sent the
-- chunks, the client parsed them and stored the points, and then silently drew
-- nothing.
--
-- (!) THE TEST SUITE COULD NOT CATCH IT. The stub frame returns a hard-coded
-- GetWidth() of 1000, so the guard never fired under test and eleven map-line
-- tests passed against code that could not draw in the real client. A stub that
-- always answers successfully cannot detect a sizing bug -- see the assertion
-- added to mapline_test.lua, which checks the STRUCTURE instead.
--
-- A ScrollFrame bought nothing here: there is nothing to scroll. Parent the
-- frame straight to WorldMapButton, which DOES have a size, and SetAllPoints()
-- then means what it looks like it means.
local function EnsureOverlay()
    if overlay then return overlay end
    if not WorldMapButton then return nil end

    overlay = CreateFrame("Frame", nil, WorldMapButton)
    overlay:SetAllPoints(WorldMapButton)
    overlay:SetFrameLevel(WorldMapButton:GetFrameLevel() + 1)
    overlay:SetFrameStrata("FULLSCREEN")
    return overlay
end

local function GetDot(i)
    if dots[i] then return dots[i] end
    local o = EnsureOverlay()
    if not o then return nil end

    local t = o:CreateTexture(nil, "OVERLAY")
    -- A plain white square, tinted per dot. Guaranteed present in every client,
    -- unlike most art paths -- which have bitten this project twice already.
    t:SetTexture("Interface\\Buttons\\WHITE8X8")
    t:SetWidth(DOT_SIZE)
    t:SetHeight(DOT_SIZE)
    dots[i] = t
    return t
end

local function HideFrom(n)
    for i = n, #dots do
        if dots[i] then dots[i]:Hide() end
    end
end

--- Which zone is the map showing? 3.3.5a gives no direct zone id for the map, so
--- this is best-effort: the addon trusts the zone of the route's FIRST point,
--- which is where the player is, and hides the line whenever the map has been
--- panned to a different continent. Panning to another zone on the same continent
--- is not detectable here and will simply show nothing, which is the safe failure.
local function CurrentlyShowingPlayerZone()
    if not GetCurrentMapZone then return true end
    return GetCurrentMapZone() ~= 0   -- 0 means a continent-wide view
end

local function Redraw()
    local o = EnsureOverlay()
    if not o then return end

    if not WorldMapFrame or not WorldMapFrame:IsShown() or #points < 2
       or not CurrentlyShowingPlayerZone() then
        HideFrom(1)
        return
    end

    local w, h = o:GetWidth(), o:GetHeight()
    if not w or w <= 0 then HideFrom(1) return end

    -- Only the zone the route starts in; see the header note on per-zone coords.
    local zone = points[1].zone
    local n = 0

    for i = 2, #points do
        local a, b = points[i - 1], points[i]
        if a.zone == zone and b.zone == zone then
            local dx, dy = b.x - a.x, b.y - a.y
            local len = math.sqrt(dx * dx + dy * dy)
            local steps = math.max(1, math.floor(len / DOT_SPACING))

            for s = 0, steps do
                if n >= MAX_DOTS then break end
                local t = s / steps
                local px, py = a.x + dx * t, a.y + dy * t

                n = n + 1
                local dot = GetDot(n)
                if dot then
                    dot:ClearAllPoints()
                    -- Map coords run 0-1 left-to-right and top-to-bottom, so y is
                    -- negated against a TOPLEFT anchor.
                    dot:SetPoint("CENTER", o, "TOPLEFT", px * w, -py * h)
                    -- Fade along the route so an overlapping line stays readable.
                    local f = 0.35 + 0.65 * (i / #points)
                    dot:SetVertexColor(1.0, 0.82 * f, 0.0, 0.55 + 0.35 * f)
                    dot:Show()
                end
            end
        end
    end

    HideFrom(n + 1)
end

--- W|<seq>|<total>|<zone>:<x10>:<y10>|...
--- Coordinates arrive as tenths of a percent, so 0-1000; divide to 0-1.
local function OnMapChunk(msg)
    local seq, total, body = msg:match("^W|(%d+)|(%d+)|?(.*)$")
    if not seq then return end
    seq, total = tonumber(seq), tonumber(total)

    if total == 0 then
        points = {}
        pending = {}
        Redraw()
        return
    end

    if seq == 1 then pending = {} end

    for zone, x, y in body:gmatch("(%d+):(%-?%d+):(%-?%d+)") do
        pending[#pending + 1] = {
            zone = tonumber(zone),
            x = tonumber(x) / 1000,
            y = tonumber(y) / 1000,
        }
    end

    -- (!) Only swap in the new route once the LAST chunk lands. Redrawing per
    -- chunk would show a route that visibly grows a piece at a time, and a
    -- dropped final chunk would leave a line that stops in the middle of nowhere
    -- looking like a pathfinding failure.
    if seq == total then
        points = pending
        pending = {}
        Redraw()
    end
end

-- Introspection for /quest mapdebug. Kept deliberately: "no line on the map" has
-- no visible failure mode, so without these the only way to diagnose it is to
-- guess, and every guess costs a round trip through the game.
function NorgQuest_MapPointCount() return #points end
function NorgQuest_MapFirstPoint()
    local p = points[1]
    if not p then return nil, 0, 0 end
    return p.zone, p.x, p.y
end
function NorgQuest_MapOverlayExists() return overlay ~= nil end
function NorgQuest_MapDotsShown()
    local n = 0
    for _, d in ipairs(dots) do if d.IsShown and d:IsShown() then n = n + 1 end end
    return n
end

NorgQuest_OnMapChunk = OnMapChunk
NorgQuest_RedrawMapLine = Redraw

local ev = CreateFrame("Frame")
ev:RegisterEvent("WORLD_MAP_UPDATE")
ev:RegisterEvent("ZONE_CHANGED_NEW_AREA")
ev:SetScript("OnEvent", Redraw)
