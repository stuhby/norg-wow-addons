-- Stub harness for NorgQuest's map line.
--
-- (!) Every 3.3.5a mistake I have made in this project has been a CLIENT API one
-- -- Texture:SetRotation, SetSize, FontString:SetScript -- and each was caught
-- only after shipping. So this drives the real module against a fake map and
-- asserts on what it actually placed.

local created = { frames = {}, textures = {} }
local shownMap = true
local mapZone = 1     -- 0 means a continent-wide view

local function newTexture()
    local t = { _shown = false, _point = nil, _colour = nil, _w = 0, _h = 0 }
    function t:SetTexture(p) self._tex = p end
    function t:SetWidth(w) self._w = w end
    function t:SetHeight(h) self._h = h end
    function t:ClearAllPoints() self._point = nil end
    function t:SetPoint(...) self._point = { ... } end
    function t:SetVertexColor(r, g, b, a) self._colour = { r, g, b, a } end
    function t:Show() self._shown = true end
    function t:Hide() self._shown = false end
    table.insert(created.textures, t)
    return t
end

local function newFrame(kind, name, parent)
    local f = { _kind = kind, _scripts = {}, _events = {}, _children = {} }
    function f:SetFrameLevel() end
    function f:GetFrameLevel() return 5 end
    function f:SetAllPoints() end
    function f:SetFrameStrata() end
    function f:SetScrollChild(c) self._child = c end
    function f:SetScript(k, v) self._scripts[k] = v end
    function f:RegisterEvent(e) self._events[e] = true end
    function f:GetWidth() return 1000 end
    function f:GetHeight() return 666 end
    function f:IsShown() return shownMap end
    function f:CreateTexture() return newTexture() end
    table.insert(created.frames, f)
    return f
end

_G.CreateFrame = newFrame
_G.WorldMapButton = newFrame("Frame", "WorldMapButton")
_G.WorldMapFrame = newFrame("Frame", "WorldMapFrame")
_G.GetCurrentMapZone = function() return mapZone end

dofile("/data/NorgQuest/MapLine.lua")

local pass, fail = 0, 0
local function check(name, cond, detail)
    if cond then pass = pass + 1; print("  PASS  " .. name)
    else fail = fail + 1; print("  FAIL  " .. name .. "   " .. tostring(detail)) end
end

local function shownDots()
    local n = 0
    for _, t in ipairs(created.textures) do if t._shown then n = n + 1 end end
    return n
end

check("module exposed its entry points",
      type(NorgQuest_OnMapChunk) == "function" and type(NorgQuest_RedrawMapLine) == "function")

-- ============================================================ a two-chunk route
-- Zone 1, a right-angle bend: the dots must follow BOTH legs, not the diagonal.
NorgQuest_OnMapChunk("W|1|2|1:100:100|1:100:500")
check("draws nothing until the LAST chunk arrives", shownDots() == 0,
      shownDots() .. " dots after chunk 1 of 2")

NorgQuest_OnMapChunk("W|2|2|1:600:500")
local n = shownDots()
check("draws the route once complete", n > 0, n .. " dots")

-- (!) The bend must be real. If the module drew a straight line from first to
-- last point, every dot would sit on that diagonal.
local offDiagonal = 0
for _, t in ipairs(created.textures) do
    if t._shown and t._point then
        local x, y = t._point[4], -t._point[5]
        -- the straight line from (0.1,0.1) to (0.6,0.5), in pixels
        local t01 = (x / 1000 - 0.1) / 0.5
        local ly = (0.1 + 0.4 * t01) * 666
        if math.abs(y - ly) > 8 then offDiagonal = offDiagonal + 1 end
    end
end
check("follows the actual bend rather than a straight line",
      offDiagonal > 0, offDiagonal .. " dots off the direct diagonal")

-- ================================================== points in a different zone
-- Coordinates are per-zone, so a point from another zone must NOT be drawn on
-- this map -- it would smear the line across the border.
local before = shownDots()
NorgQuest_OnMapChunk("W|1|1|1:100:100|1:200:200|47:900:900")
check("ignores points belonging to another zone", shownDots() < before + 40,
      shownDots() .. " dots")

-- ================================================== continent view hides it
mapZone = 0
NorgQuest_RedrawMapLine()
check("hides the line on the continent-wide view", shownDots() == 0, shownDots() .. " dots")
mapZone = 1

-- ====================================================== map closed hides it
shownMap = false
NorgQuest_RedrawMapLine()
check("draws nothing while the map is closed", shownDots() == 0, shownDots() .. " dots")
shownMap = true

-- ============================================================== clear command
NorgQuest_OnMapChunk("W|1|1|1:100:100|1:400:400")
check("redraws after being re-sent", shownDots() > 0, shownDots())
NorgQuest_OnMapChunk("W|0|0")
check("W|0|0 clears the line", shownDots() == 0, shownDots() .. " dots")

-- ==================================================================== garbage
local ok = pcall(function()
    NorgQuest_OnMapChunk("W|")
    NorgQuest_OnMapChunk("W|1|1|")
    NorgQuest_OnMapChunk("W|1|1|garbage")
    NorgQuest_OnMapChunk("")
end)
check("survives malformed chunks", ok)

-- (!) Texture count must not grow without bound on repeated routes, or a long
-- session leaks a frame per dot per redraw.
local texBefore = #created.textures
for i = 1, 20 do NorgQuest_OnMapChunk("W|1|1|1:100:100|1:900:900") end
check("reuses textures instead of creating one per redraw",
      #created.textures - texBefore < 50,
      (#created.textures - texBefore) .. " new textures over 20 redraws")

-- (!) STRUCTURAL ASSERTION, because a behavioural one is impossible here.
-- The container must NOT be a ScrollFrame scroll child: such a child takes no
-- size from SetAllPoints(), so GetWidth() is 0 in the real client and Redraw
-- returns before drawing. The stub above reports a width of 1000 no matter
-- what, so no amount of dot-counting can detect that -- this checks the shape.
local scrollFrames = 0
for _, fr in ipairs(created.frames) do
    if fr._kind == "ScrollFrame" then scrollFrames = scrollFrames + 1 end
end
check("container is not a ScrollFrame scroll child", scrollFrames == 0,
      scrollFrames .. " ScrollFrame(s) created")

print(string.format("\n  ==== %d passed, %d failed ====", pass, fail))
os.exit(fail == 0 and 0 or 1)
