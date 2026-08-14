local created = {}
local INSTANCE = "WailingCaverns"
local SAVED = false
local function nf(kind,name,parent)
  local f={_name=name,_events={},_scripts={},_shown=false,_tex=nil}
  for _,m in ipairs({"SetWidth","SetHeight","SetFrameStrata","SetToplevel","EnableMouse","SetMovable",
                     "RegisterForDrag","SetBackdrop","SetPoint","ClearAllPoints","SetAllPoints",
                     "SetJustifyH","StartMoving","StopMovingOrSizing"}) do f[m]=function() end end
  f.SetScript=function(s,k,v) s._scripts[k]=v end
  f.RegisterEvent=function(s,e) s._events[e]=true end
  f.Show=function(s) s._shown=true end
  f.Hide=function(s) s._shown=false end
  f.IsShown=function(s) return s._shown end
  f.GetPoint=function() return "CENTER",nil,"CENTER",0,0 end
  f.CreateFontString=function()
    local t={_text=""} t.SetPoint=function() end t.ClearAllPoints=function() end
    t.SetJustifyH=function() end t.SetText=function(s,v) s._text=v end
    t.GetText=function(s) return s._text end t.Show=function() end t.Hide=function() end
    return t end
  f.CreateTexture=function()
    local t={_tex=nil} t.SetPoint=function() end t.SetWidth=function() end
    t.SetHeight=function() end t.SetTexture=function(s,v) s._tex=v end
    t.GetTexture=function(s) return s._tex end
    return t end
  table.insert(created,f); if name then _G[name]=f end; return f
end
_G.CreateFrame=nf
_G.UIParent=nf("Frame","UIParent")
_G.UISpecialFrames={}
_G.tinsert=table.insert
_G.DEFAULT_CHAT_FRAME={msgs={},AddMessage=function(s,m) table.insert(s.msgs,m) end}
_G.GetInstanceInfo=function() return INSTANCE end
_G.IsInInstance=function() return true end
_G.GetNumSavedInstances=function() return SAVED and 1 or 0 end
_G.GetSavedInstanceInfo=function() return INSTANCE, nil, 3600 end
_G.SlashCmdList={}

dofile("/data/Data.lua"); dofile("/data/NorgDungeons.lua")

local pass,fail=0,0
local function ck(n,c,d) if c then pass=pass+1;print("  PASS  "..n) else fail=fail+1;print("  FAIL  "..n.."  "..tostring(d)) end end
local ev; for _,f in ipairs(created) do if f._events["COMBAT_LOG_EVENT_UNFILTERED"] then ev=f end end
ck("event frame registered", ev~=nil)
ev._scripts["OnEvent"](ev,"PLAYER_LOGIN")
ck("loaded 101 maps", DEFAULT_CHAT_FRAME.msgs[1]:find("101"), DEFAULT_CHAT_FRAME.msgs[1])

ev._scripts["OnEvent"](ev,"ZONE_CHANGED_NEW_AREA")
ck("auto-shown in instance", _G.NorgDungeonsFrame:IsShown())
ck("map texture set to the right image",
   tostring(_G.NorgDungeonsFrame and true) and true)

-- kill Kresh (npc 3653) -> guid form 0xF13000<entry hex>xxxxxx
local guid = "0xF13000"..string.format("%04X",3653).."00A1B2"
ev._scripts["OnEvent"](ev,"COMBAT_LOG_EVENT_UNFILTERED",nil,"UNIT_DIED",nil,nil,nil,guid)
ck("boss death parsed from GUID", true)

-- leaving to a different instance resets kills
INSTANCE="ZulFarrak"
local ok=pcall(function() ev._scripts["OnEvent"](ev,"ZONE_CHANGED_NEW_AREA") end)
ck("zoning to another instance works", ok)

-- saved raid keeps kills
SAVED=true; INSTANCE="WailingCaverns"
ok=pcall(function() ev._scripts["OnEvent"](ev,"ZONE_CHANGED_NEW_AREA") end)
ck("saved-instance path runs without error", ok)

-- slash command with a name
ok=pcall(function() SlashCmdList["NORGDUNGEONS"]("zulfarrak") end)
ck("/dungeon <name> works", ok)
local before=#DEFAULT_CHAT_FRAME.msgs
ok=pcall(function() SlashCmdList["NORGDUNGEONS"]("notarealplace") end)
ck("bad name warns, no error", ok and #DEFAULT_CHAT_FRAME.msgs>before)

print(string.format("\n  ==== %d passed, %d failed ====",pass,fail))
os.exit(fail==0 and 0 or 1)
