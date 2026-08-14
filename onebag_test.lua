-- Stub harness for NorgOneBag: loads the REAL addon file against a fake WoW API
-- and checks the layout maths, button plumbing and event wiring.
-- Cannot test rendering; it CAN catch nil-indexing, bad arithmetic and wrong
-- parent/ID wiring, which are the failure modes that would break in-game.

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
_G.DEFAULT_CHAT_FRAME = { AddMessage=function() end }
_G.MoneyFrame_SetType = function() end
_G.SetItemButtonTexture = function() end
_G.SetItemButtonCount = function() end
_G.SetItemButtonDesaturated = function() end
_G.ContainerFrame_UpdateCooldown = function() end
_G.GetContainerNumSlots = function(bag) return BAGSLOTS[bag] or 0 end
_G.GetContainerItemInfo = function() return "tex", 5, nil, 1, nil end
_G.SLASH_NORGONEBAG1 = nil
_G.SlashCmdList = {}

dofile("/data/NorgOneBag.lua")

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
