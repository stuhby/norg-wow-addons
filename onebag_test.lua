-- Stub harness for NorgOneBag: loads the REAL addon file against a fake WoW API
-- and checks the layout maths, button plumbing and event wiring.
-- Cannot test rendering; it CAN catch nil-indexing, bad arithmetic and wrong
-- parent/ID wiring, each of which would break the frame in-game.

local created, points, shown = {}, {}, {}
local BAGSLOTS = { [0]=16, [1]=16, [2]=12, [3]=0, [4]=0 }   -- backpack + two bags

local function newFrame(kind, name, parent, template)
    local f = {
        _kind=kind, _name=name, _parent=parent, _template=template,
        _id=nil, _w=0, _h=0, _shown=false, _scripts={}, _events={},
    }
    function f:SetFrameStrata() end
    function f:SetToplevel() end
    function f:EnableMouse() end
    function f:SetMovable() end
    function f:RegisterForDrag() end
    function f:SetScript(k,v) self._scripts[k]=v end
    function f:GetScript(k) return self._scripts[k] end
    function f:SetBackdrop() end
    function f:SetBackdropColor() end
    function f:SetBackdropBorderColor() end
    function f:CreateFontString() return { SetPoint=function() end, SetText=function() end } end
    function f:SetPoint(...) points[self._name or tostring(self)] = {...} end
    function f:ClearAllPoints() end
    function f:SetAllPoints() end
    function f:SetWidth(w) self._w=w end
    function f:SetHeight(h) self._h=h end
    function f:GetWidth() return self._w end
    function f:GetHeight() return self._h end
    function f:SetID(i) self._id=i end
    function f:GetID() return self._id end
    function f:GetParent() return self._parent end
    function f:Show() self._shown=true; shown[self._name or ""]=true end
    function f:Hide() self._shown=false; shown[self._name or ""]=false end
    function f:IsShown() return self._shown end
    function f:GetPoint() return "CENTER", nil, "CENTER", 0, 0 end
    function f:StartMoving() end
    function f:StopMovingOrSizing() end
    function f:RegisterEvent(e) self._events[e]=true end
    table.insert(created, f)
    if name then _G[name] = f end
    return f
end

_G.CreateFrame = newFrame
_G.UIParent = newFrame("Frame","UIParent")
_G.UISpecialFrames = {}
_G.tinsert = table.insert
_G.DEFAULT_CHAT_FRAME = { msgs={}, AddMessage=function(s,m) table.insert(s.msgs,m) end }
_G.MoneyFrame_SetType = function() end
_G.SetItemButtonTexture = function() end
_G.SetItemButtonCount = function() end
_G.SetItemButtonDesaturated = function() end
_G.ContainerFrame_UpdateCooldown = function() end
_G.GetContainerNumSlots = function(bag) return BAGSLOTS[bag] or 0 end
_G.GetContainerItemInfo = function() return "tex", 5, nil, 1, nil end
_G.SLASH_NORGONEBAG1 = nil
_G.SlashCmdList = {}

-- (!) THE RULE: EVERY dofile PATH IS ADDON-QUALIFIED, "/data/<AddOn>/<file>.lua".
-- Every suite in this project is run from the addon ROOT with -v "$PWD:/data", so
-- /data IS that root and an addon's own files only exist one folder down. An
-- unqualified "/data/NorgOneBag.lua" resolves ONLY when this single addon folder is
-- mounted on its own -- which passes in isolation and then dies as a BROKEN TEST
-- in a run-everything loop, so the suite quietly ships unverified. The rule holds
-- for every suite here and for any new one; never drop the folder segment, and do
-- not restate it as a count of how many suites currently comply.
-- (!) GetAddOnMetadata IS REAL IN 3.3.5a -- Atlas 3.x calls it at file scope to
-- set ATLAS_VERSION (atlas-src/Atlas-3/Atlas/Atlas.lua) -- but plain Lua has no
-- such global, so without this stub the addon's version line is a nil call the
-- moment it loads.
-- It READS THE ACTUAL .toc rather than returning a literal: a hardcoded answer
-- would keep passing for ever while the addon printed something else, which is
-- the exact drift the version line exists to stop.
_G.GetAddOnMetadata = function(folder, field)
    if field ~= "Version" then return nil end
    local f = io.open("/data/" .. folder .. "/" .. folder .. ".toc")
    if not f then return nil end
    local v
    for line in f:lines() do v = v or line:match("^##%s*Version:%s*(.-)%s*$") end
    f:close()
    return v
end
local TOC_VERSION = _G.GetAddOnMetadata("NorgOneBag", "Version")

dofile("/data/NorgOneBag/NorgOneBag.lua")

local pass, fail = 0, 0
local function check(name, cond, detail)
    if cond then pass=pass+1; print("  PASS  "..name)
    else fail=fail+1; print("  FAIL  "..name.."  "..tostring(detail)) end
end

-- fire PLAYER_LOGIN on the event frame the addon created
local ev
for _,f in ipairs(created) do
    if f._events and f._events["BAG_UPDATE"] then ev = f end
end
check("registered BAG_UPDATE handler", ev ~= nil)
ev._scripts["OnEvent"](ev, "PLAYER_LOGIN")

check("login banner names the version FROM THE .toc",
      TOC_VERSION and DEFAULT_CHAT_FRAME.msgs[1]
      and DEFAULT_CHAT_FRAME.msgs[1]:find("v"..TOC_VERSION, 1, true), DEFAULT_CHAT_FRAME.msgs[1])
check("and announces itself exactly ONCE", #DEFAULT_CHAT_FRAME.msgs == 1, #DEFAULT_CHAT_FRAME.msgs)

check("main frame created", _G.NorgOneBagFrame ~= nil)
check("Escape-close registered", #_G.UISpecialFrames == 1 and _G.UISpecialFrames[1]=="NorgOneBagFrame")
check("stock bag entry points overridden",
      type(_G.ToggleBackpack)=="function" and type(_G.OpenAllBags)=="function")

-- open it, which builds buttons and lays out
_G.OpenAllBags()
check("frame shown after OpenAllBags", _G.NorgOneBagFrame:IsShown())

-- holders must carry the BAG id (this is what Blizzard's handlers read)
local holderOK = true
for bag=0,4 do
    local h = _G["NorgOneBagHolder"..bag]
    if not h or h:GetID() ~= bag then holderOK=false end
end
check("each holder frame's ID == its bag number", holderOK)

-- one button per real slot, each with slot ID and correct parent
local total, btnOK = 0, true
for bag=0,4 do
    for slot=1,BAGSLOTS[bag] do
        local b = _G["NorgOneBagItem"..bag.."_"..slot]
        if not b then btnOK=false
        elseif b:GetID() ~= slot then btnOK=false
        elseif b:GetParent():GetID() ~= bag then btnOK=false
        else total = total + 1 end
    end
end
check("buttons created for all 44 slots", total == 44, "got "..total)
check("every button has correct slot ID and bag parent", btnOK)

-- layout maths: 44 slots over 12 cols = 4 rows
local rows = math.ceil(44/12)
local expectW = 12*39 + 10*2 + 4
local expectH = rows*39 + 32 + 34 + 10
check("frame width matches column maths", _G.NorgOneBagFrame:GetWidth()==expectW,
      _G.NorgOneBagFrame:GetWidth().." vs "..expectW)
check("frame height matches row maths", _G.NorgOneBagFrame:GetHeight()==expectH,
      _G.NorgOneBagFrame:GetHeight().." vs "..expectH)

-- a bag update must not error
local ok = pcall(function() ev._scripts["OnEvent"](ev, "BAG_UPDATE") end)
check("BAG_UPDATE refresh runs clean", ok)

-- shrinking a bag must hide the orphaned buttons, not error
BAGSLOTS[2] = 4
ok = pcall(function() ev._scripts["OnEvent"](ev, "BAG_UPDATE") end)
check("handles a bag being swapped smaller", ok and shown["NorgOneBagItem2_12"]==false)

-- toggle closes
_G.ToggleBackpack()
check("toggle closes the frame", not _G.NorgOneBagFrame:IsShown())

print(string.format("\n  ==== %d passed, %d failed ====", pass, fail))
os.exit(fail==0 and 0 or 1)
