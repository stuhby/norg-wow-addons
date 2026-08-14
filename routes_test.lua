-- Functional test: loads the REAL addon against a stubbed WoW API and checks
-- instance matching, rendering and the slash command.
local created = {}
local INSTANCE_NAME = "Wailing Caverns"
local function newFrame(kind, name, parent)
    local f = { _name=name, _events={}, _scripts={}, _shown=false, _h=0 }
    for _, m in ipairs({"SetWidth","SetHeight","SetFrameStrata","SetToplevel","EnableMouse",
                        "SetMovable","RegisterForDrag","SetBackdrop","SetPoint","ClearAllPoints",
                        "SetAllPoints","SetJustifyH","StartMoving","StopMovingOrSizing"}) do
        f[m] = function() end
    end
    f.SetHeight = function(self,h) self._h=h end
    f.GetHeight = function(self) return self._h end
    f.SetScript = function(self,k,v) self._scripts[k]=v end
    f.RegisterEvent = function(self,e) self._events[e]=true end
    f.Show = function(self) self._shown=true end
    f.Hide = function(self) self._shown=false end
    f.IsShown = function(self) return self._shown end
    f.GetPoint = function() return "CENTER",nil,"CENTER",0,0 end
    f.CreateFontString = function()
        local fs={_text=""}
        fs.SetPoint=function() end; fs.ClearAllPoints=function() end
        fs.SetJustifyH=function() end; fs.SetText=function(s,t) s._text=t end
        fs.GetText=function(s) return s._text end
        fs.Show=function() end; fs.Hide=function() end
        return fs
    end
    table.insert(created, f)
    if name then _G[name]=f end
    return f
end
_G.CreateFrame=newFrame
_G.UIParent=newFrame("Frame","UIParent")
_G.UISpecialFrames={}
_G.tinsert=table.insert
_G.DEFAULT_CHAT_FRAME={ msgs={}, AddMessage=function(s,m) table.insert(s.msgs,m) end }
_G.GetInstanceInfo=function() return INSTANCE_NAME end
_G.GetRealZoneText=function() return INSTANCE_NAME end
_G.IsInInstance=function() return true end
_G.IsAddOnLoaded=function() return false end
_G.SlashCmdList={}

dofile("/data/Data.lua")
dofile("/data/NorgRoutes.lua")

local pass,fail=0,0
local function check(n,c,d) if c then pass=pass+1;print("  PASS  "..n) else fail=fail+1;print("  FAIL  "..n.."  "..tostring(d)) end end

local ev
for _,f in ipairs(created) do if f._events["PLAYER_LOGIN"] then ev=f end end
check("event frame registered", ev~=nil)
ev._scripts["OnEvent"](ev,"PLAYER_LOGIN")
check("frame built", _G.NorgRoutesFrame~=nil)
check("load message mentions instance count",
      #DEFAULT_CHAT_FRAME.msgs>0 and DEFAULT_CHAT_FRAME.msgs[1]:find("69"), DEFAULT_CHAT_FRAME.msgs[1])

-- entering the instance should auto-detect and show
ev._scripts["OnEvent"](ev,"ZONE_CHANGED_NEW_AREA")
check("auto-detected and shown in instance", _G.NorgRoutesFrame:IsShown())
check("title set to the instance", _G.NorgRoutesFrame.title:GetText()=="Wailing Caverns",
      _G.NorgRoutesFrame.title:GetText())
check("height scaled to 7 bosses", _G.NorgRoutesFrame:GetHeight()==70+7*16, _G.NorgRoutesFrame:GetHeight())

-- unknown instance must not error
INSTANCE_NAME="Some Unknown Place"
local ok=pcall(function() ev._scripts["OnEvent"](ev,"ZONE_CHANGED_NEW_AREA") end)
check("unknown instance handled gracefully", ok)

-- manual selection by name
local ok2=pcall(function() SlashCmdList["NORGROUTES"]("Shadowfang Keep") end)
check("/route <name> works", ok2 and _G.NorgRoutesFrame.title:GetText()=="Shadowfang Keep",
      _G.NorgRoutesFrame.title:GetText())

-- 'The' prefix and case insensitivity
local ok3=pcall(function() SlashCmdList["NORGROUTES"]("deadmines") end)
check("fuzzy match ignores case/'The'", ok3 and _G.NorgRoutesFrame.title:GetText()~="Shadowfang Keep",
      _G.NorgRoutesFrame.title:GetText())

-- bad name must warn, not error
local before=#DEFAULT_CHAT_FRAME.msgs
local ok4=pcall(function() SlashCmdList["NORGROUTES"]("Nonexistent Dungeon") end)
check("bad name warns instead of erroring", ok4 and #DEFAULT_CHAT_FRAME.msgs>before)

print(string.format("\n  ==== %d passed, %d failed ====",pass,fail))
os.exit(fail==0 and 0 or 1)
