local created = {}
local textures, fontstrings = {}, {}
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
  -- (!) Fontstrings and textures are RECORDED, not discarded. They are the only
  -- window onto Render(): the addon keeps mapTex, titleFS and the legend lines in
  -- file-locals, so what the addon actually DREW is unreachable unless the stub
  -- keeps every object it handed out. Throwing them away is what left the map and
  -- boss-kill assertions with nothing to look at, and both degenerated into
  -- constants -- see the two checks further down.
  f.CreateFontString=function(s)
    local t={_text="",_owner=s,_shown=false} t.SetPoint=function() end t.ClearAllPoints=function() end
    t.SetJustifyH=function() end t.SetText=function(s2,v) s2._text=v end
    t.GetText=function(s2) return s2._text end
    t.Show=function(s2) s2._shown=true end t.Hide=function(s2) s2._shown=false end
    t.IsShown=function(s2) return s2._shown end
    table.insert(fontstrings,t)
    return t end
  f.CreateTexture=function(s)
    local t={_tex=nil,_owner=s} t.SetPoint=function() end t.SetWidth=function() end
    t.SetHeight=function() end t.SetTexture=function(s2,v) s2._tex=v end
    t.GetTexture=function(s2) return s2._tex end
    table.insert(textures,t)
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

-- (!) THE RULE: EVERY dofile PATH IS ADDON-QUALIFIED, "/data/<AddOn>/<file>.lua".
-- Every suite in this project is run from the addon ROOT with -v "$PWD:/data", so
-- /data IS that root and an addon's own files only exist one folder down. An
-- unqualified "/data/Data.lua" resolves ONLY when this single addon folder is
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
local TOC_VERSION = _G.GetAddOnMetadata("NorgDungeons", "Version")

dofile("/data/NorgDungeons/Data.lua"); dofile("/data/NorgDungeons/NorgDungeons.lua")

local pass,fail=0,0
local function ck(n,c,d) if c then pass=pass+1;print("  PASS  "..n) else fail=fail+1;print("  FAIL  "..n.."  "..tostring(d)) end end
local function summary() print(string.format("\n  ==== %d passed, %d failed ====",pass,fail)) end

local ev; for _,f in ipairs(created) do if f._events["COMBAT_LOG_EVENT_UNFILTERED"] then ev=f end end
ck("event frame registered", ev~=nil)
-- (!) EVERY LATER CHECK DRIVES ev, so a missing event frame has to stop here with
-- a printed summary rather than aborting on a nil index. A run-everything loop
-- greps the ==== line; a suite that dies mid-file still exits 1 but reports NOTHING,
-- which reads as tooling breakage instead of the source regression it really is.
if not ev then summary(); os.exit(1) end

ev._scripts["OnEvent"](ev,"PLAYER_LOGIN")
local banner = DEFAULT_CHAT_FRAME.msgs[1]
ck("loaded 101 maps", banner and banner:find("101"), banner)
ck("login banner names the version FROM THE .toc",
   TOC_VERSION and banner and banner:find("v"..TOC_VERSION, 1, true), banner)
ck("and announces itself exactly ONCE", #DEFAULT_CHAT_FRAME.msgs==1, #DEFAULT_CHAT_FRAME.msgs)

ev._scripts["OnEvent"](ev,"ZONE_CHANGED_NEW_AREA")
-- (!) NIL-GUARDED. Indexing _G.NorgDungeonsFrame bare turns a real Build()/Show()
-- regression into "attempt to index field 'NorgDungeonsFrame' (a nil value)" --
-- the suite aborts with no FAIL line and no ==== summary, so the one thing that
-- would name the broken behaviour is exactly what gets lost.
local dframe = _G.NorgDungeonsFrame
ck("auto-shown in instance", dframe~=nil and dframe:IsShown(), tostring(dframe))

-- (!) THIS ASSERTION USED TO READ `tostring(frame and true) and true`, which is a
-- CONSTANT TRUE: tostring() can never return nil or false, so it printed PASS no
-- matter what Render() put in the texture -- including nothing at all. Assert the
-- real path. The expected string is spelled out as a LITERAL rather than rebuilt
-- from currentKey, so the test cannot agree with the code by construction: a wrong
-- key, a renamed Images folder or a missing SetTexture all fail here.
ck("exactly one texture created (the map)", #textures==1, #textures)
local mapTex = textures[1]
ck("map texture set to the right image",
   mapTex~=nil and mapTex:GetTexture()=="Interface\\AddOns\\NorgDungeons\\Images\\WailingCaverns",
   mapTex and tostring(mapTex:GetTexture()) or "no texture was ever created")

-- Kresh is entry 3653, marker 4, boss #3 of Wailing Caverns (NorgDungeons/Data.lua).
local COL_DEAD = "|cff707070"
local function lineFor(name)
  for _,fs in ipairs(fontstrings) do
    local t = fs:GetText()
    if t and t:find(name,1,true) then return t end
  end
end
local function doneCount()
  local n=0
  for _,fs in ipairs(fontstrings) do
    local t = fs:GetText()
    if fs:IsShown() and t and t:find("[done]",1,true) then n=n+1 end
  end
  return n
end

local kreshBefore = lineFor("Kresh")
ck("Kresh's legend line is drawn on entering the instance", kreshBefore~=nil, kreshBefore)
ck("and nothing is marked done before any kill", doneCount()==0, doneCount())

-- kill Kresh (npc 3653) -> guid form 0xF13000<entry hex>xxxxxx
local guid = "0xF13000"..string.format("%04X",3653).."00A1B2"
ev._scripts["OnEvent"](ev,"COMBAT_LOG_EVENT_UNFILTERED",nil,"UNIT_DIED",nil,nil,nil,guid)
-- (!) THIS ASSERTION USED TO BE THE LITERAL `true`. The only observable proof that
-- OnDeath() pulled entry 3653 out of the GUID is that Render() redraws that one
-- legend line dimmed and tagged [done] -- so assert THAT. Breaking the sub(9,12)
-- window, the base-16 tonumber or the killed[] lookup all land here.
local kreshAfter = lineFor("Kresh")
ck("boss death parsed from GUID -- Kresh's line is redrawn as done",
   kreshAfter~=nil and kreshAfter:find("[done]",1,true)~=nil
   and kreshAfter:find(COL_DEAD,1,true)~=nil, kreshAfter)
ck("and no other boss is marked down with it", doneCount()==1, doneCount())

-- (!) THE TWO HALVES OF THE KILL-TRACKING CONTRACT, and each is only provable by
-- COMING BACK. Checking the kill list while standing in the OTHER instance proves
-- nothing either way -- ZulFarrak's legend does not contain entry 3653, so it
-- renders zero [done] lines whether killed{} was cleared or not. Both checks below
-- therefore zone out and back, and read Wailing Caverns' own legend.
local function zone() return pcall(function() ev._scripts["OnEvent"](ev,"ZONE_CHANGED_NEW_AREA") end) end

-- half one: leaving an UNSAVED instance clears the kills
INSTANCE="ZulFarrak"
local ok=zone()
ck("zoning to another instance works", ok)
INSTANCE="WailingCaverns"
ok=zone()
ck("returning to an UNSAVED instance has cleared the kills", ok and doneCount()==0, doneCount())

-- half two: a saved lockout keeps them, because the server still holds them dead
SAVED=true
ev._scripts["OnEvent"](ev,"COMBAT_LOG_EVENT_UNFILTERED",nil,"UNIT_DIED",nil,nil,nil,guid)
ck("kill registered again inside the saved instance", doneCount()==1, doneCount())
INSTANCE="ZulFarrak"; zone()
INSTANCE="WailingCaverns"; ok=zone()
ck("saved-instance path runs without error", ok)
ck("and a saved lockout keeps Kresh marked down across leave and return",
   doneCount()==1 and (lineFor("Kresh") or ""):find("[done]",1,true)~=nil, lineFor("Kresh"))

-- slash command with a name
ok=pcall(function() SlashCmdList["NORGDUNGEONS"]("zulfarrak") end)
ck("/dungeon <name> works", ok)
local before=#DEFAULT_CHAT_FRAME.msgs
ok=pcall(function() SlashCmdList["NORGDUNGEONS"]("notarealplace") end)
ck("bad name warns, no error", ok and #DEFAULT_CHAT_FRAME.msgs>before)

summary()
os.exit(fail==0 and 0 or 1)
