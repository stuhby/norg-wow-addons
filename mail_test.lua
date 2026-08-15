-- Stub harness for NorgMail.
--
-- (!) The interesting behaviour is not "does it take things" but "does it take
-- them when the indices move underneath it". Taking an attachment removes it
-- server-side and the inbox is re-sent, so a mail that was index 4 becomes index
-- 3. An addon that loops over 1..n while mutating that range silently skips mail
-- and never reports it. This models a MUTATING inbox and asserts nothing is lost.

local inbox            -- list of { sender, money, cod, items = {names...} }
local bagFree = 20
local taken = { items = {}, money = 0 }

-- ------------------------------------------------------------ client API stubs
local frames = {}
local function newFrame(_, name)
    local f = { _scripts = {}, _events = {} }
    function f:RegisterEvent(e) self._events[e] = true end
    function f:SetScript(k, v) self._scripts[k] = v end
    function f:GetScript(k) return self._scripts[k] end
    function f:SetWidth() end
    function f:SetHeight() end
    function f:SetText() end
    function f:SetPoint() end
    function f:Show() end
    function f:Hide() end
    function f:IsShown() return true end
    table.insert(frames, f)
    if name then _G[name] = f end
    return f
end
_G.CreateFrame = newFrame
_G.MailFrame = newFrame("Frame", "MailFrame")
_G.ATTACHMENTS_MAX_RECEIVE = 16
_G.DEFAULT_CHAT_FRAME = { msgs = {},
    AddMessage = function(s, m) _G._lastMsg = m; table.insert(s.msgs, m) end }
_G.SlashCmdList = {}

_G.GetContainerNumFreeSlots = function(bag)
    if bag == 0 then return bagFree, 0 end
    return 0, 0
end

_G.GetInboxNumItems = function() return #inbox end

-- (!) RETURN ALL THIRTEEN VALUES. The real API returns packageIcon,
-- stationeryIcon, sender, subject, money, CODAmount, daysLeft, itemCount,
-- wasRead, wasReturned, textCreated, canReply, isGM. A stub that returns only
-- the first eight cannot catch a miscounted destructure in the addon -- and a
-- miscount there reads the SUBJECT as the C.O.D. amount, which disables the
-- one guard in this addon that costs real gold when it fails.
_G.GetInboxHeaderInfo = function(i)
    local m = inbox[i]
    if not m then return end
    return "pkg", "stat", m.sender, m.subject or "subj", m.money or 0, m.cod or 0,
           30, #(m.items or {}), m.wasRead, nil, nil, 1, m.isGM
end

_G.MiniMapMailFrame = newFrame("Frame", "MiniMapMailFrame")
_G._iconShown = true
_G.MiniMapMailFrame.Hide = function() _G._iconShown = false end

--- Requesting the body is what marks a mail read, which is the whole mechanism
--- behind the stuck notification.
_G.GetInboxText = function(i)
    local m = inbox[i]
    if m then m.wasRead = 1 end
    return "body", nil, nil
end

_G.GetInboxItem = function(i, a)
    local m = inbox[i]
    if not m or not m.items then return nil end
    return m.items[a]
end

--- (!) The whole point: taking mutates the inbox and can REMOVE a mail entirely,
--- shifting everything after it down by one.
_G.TakeInboxItem = function(i, a)
    local m = inbox[i]
    if not m or not m.items or not m.items[a] then return end
    table.insert(taken.items, m.items[a])
    table.remove(m.items, a)
    bagFree = bagFree - 1
    -- (!) Only a mail with NO BODY TEXT is auto-deleted once empty. Every
    -- auction-house mail has text, so it stays in the inbox -- and stays UNREAD,
    -- which is what keeps the minimap notification lit. A harness that deletes
    -- every emptied mail can never reproduce that.
    if #m.items == 0 and (m.money or 0) == 0 and not m.hasText then table.remove(inbox, i) end
end

_G.TakeInboxMoney = function(i)
    local m = inbox[i]
    if not m then return end
    taken.money = taken.money + (m.money or 0)
    m.money = 0
    if #(m.items or {}) == 0 and not m.hasText then table.remove(inbox, i) end
end

-- (!) GetAddOnMetadata IS REAL IN 3.3.5a -- Atlas 3.x calls it at file scope, see
-- atlas-src/Atlas-3/Atlas/Atlas.lua:39 -- but plain Lua has no such global, so
-- without this stub the addon's version line is a nil call the moment it loads.
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
local TOC_VERSION = _G.GetAddOnMetadata("NorgMail", "Version")

dofile("/data/NorgMail/NorgMail.lua")

local pass, fail = 0, 0
local function check(name, cond, detail)
    if cond then pass = pass + 1; print("  PASS  " .. name)
    else fail = fail + 1; print("  FAIL  " .. name .. "   " .. tostring(detail)) end
end

-- ============================================================ the login banner
-- The version line is the wiki's first troubleshooting step, so it is asserted
-- like any other behaviour rather than assumed.
local loginFrame
for _, f in ipairs(frames) do
    if f._events and f._events["PLAYER_LOGIN"] then loginFrame = f end
end
check("registered PLAYER_LOGIN", loginFrame ~= nil)
loginFrame._scripts["OnEvent"](loginFrame, "PLAYER_LOGIN")
check("login banner names the version FROM THE .toc",
      TOC_VERSION and _G._lastMsg and _G._lastMsg:find("v" .. TOC_VERSION, 1, true), _G._lastMsg)
check("and announces itself exactly ONCE",
      #DEFAULT_CHAT_FRAME.msgs == 1, #DEFAULT_CHAT_FRAME.msgs)

--- Run to completion, with a bound so a wedged addon fails the test instead of
--- hanging the suite.
local function runToEnd()
    NorgMail_Start(false)
    for _ = 1, 500 do
        if not NorgMail_IsRunning() then break end
        NorgMail_Step()
    end
end

-- ===================================================== takes everything it should
inbox = {
    { sender = "A", money = 0,    items = { "Sword", "Shield" } },
    { sender = "B", money = 5000, items = {} },
    { sender = "C", money = 0,    items = { "Potion" } },
}
taken = { items = {}, money = 0 }; bagFree = 20
runToEnd()
check("took every attachment across shifting indices", #taken.items == 3,
      #taken.items .. " items: " .. table.concat(taken.items, ","))
check("took the money mail", taken.money == 5000, taken.money)
check("inbox is empty afterwards", #inbox == 0, #inbox .. " left")

-- ============================================================ C.O.D. is skipped
inbox = {
    { sender = "A", money = 0, cod = 1000, items = { "Expensive" } },
    { sender = "B", money = 0, items = { "Free" } },
}
taken = { items = {}, money = 0 }; bagFree = 20
runToEnd()
check("did NOT take the C.O.D. attachment",
      #taken.items == 1 and taken.items[1] == "Free",
      table.concat(taken.items, ","))
check("C.O.D. mail left in the inbox", #inbox == 1 and inbox[1].cod == 1000, #inbox)

-- ================================================================ GM mail is skipped
inbox = {
    { sender = "GM", money = 0, isGM = 1, items = { "Restored" } },
    { sender = "B",  money = 0, items = { "Ordinary" } },
}
taken = { items = {}, money = 0 }; bagFree = 20
runToEnd()
check("did NOT take the GM mail attachment",
      #taken.items == 1 and taken.items[1] == "Ordinary", table.concat(taken.items, ","))

-- (!) A mail whose SUBJECT is long must not be mistaken for a C.O.D. -- that is
-- exactly what a miscounted destructure does, and it silently pays real gold.
inbox = {
    { sender = "A", subject = "A rather long subject line", money = 0, cod = 0, items = { "Safe" } },
}
taken = { items = {}, money = 0 }; bagFree = 20
runToEnd()
check("a long subject is not read as a C.O.D. amount",
      #taken.items == 1, "took " .. #taken.items)
-- ========================================================== stops when bags full
inbox = {
    { sender = "A", money = 0, items = { "One", "Two", "Three" } },
}
taken = { items = {}, money = 0 }; bagFree = 1
runToEnd()
check("stopped when bags filled rather than looping", #taken.items == 1,
      #taken.items .. " taken with 1 free slot")
check("run ended cleanly", NorgMail_IsRunning() == false)

-- ============================================================ money-only mode
inbox = {
    { sender = "A", money = 700, items = { "Keepme" } },
}
taken = { items = {}, money = 0 }; bagFree = 20
NorgMail_Start(true)
for _ = 1, 500 do
    if not NorgMail_IsRunning() then break end
    NorgMail_Step()
end
check("money-only took the money", taken.money == 700, taken.money)
check("money-only left the attachment", #taken.items == 0 and inbox[1] and #inbox[1].items == 1,
      #taken.items .. " items taken")

-- ========================================= the minimap notification must clear
-- (!) Taking attachments does NOT mark mail read, and every auction-house mail
-- has body text so it survives being emptied. Reported live: "all my mail is
-- opened and I still see the notification".
inbox = {
    { sender = "AH", money = 0, items = { "Sold" }, hasText = true },  -- survives emptying
    { sender = "AH", money = 300, items = {}, hasText = true },        -- survives emptying
}
taken = { items = {}, money = 0 }; bagFree = 20; _G._iconShown = true
runToEnd()
local unreadLeft = 0
for i = 1, #inbox do if not inbox[i].wasRead then unreadLeft = unreadLeft + 1 end end
check("nothing is left unread after a run", unreadLeft == 0, unreadLeft .. " unread")
check("minimap mail icon was hidden", _G._iconShown == false, "icon still shown")

-- ...but it must NOT hide the icon while genuinely unread mail remains, or a
-- C.O.D. you deliberately skipped becomes invisible.
inbox = {
    { sender = "X", money = 0, cod = 500, items = { "Pricey" } },   -- skipped, stays unread
}
taken = { items = {}, money = 0 }; bagFree = 20; _G._iconShown = true
runToEnd()
-- (!) NO `or` CLAUSE HERE. This read `_iconShown == true or inbox[1].wasRead ~= nil`,
-- and the second operand was true on every run, so the check passed while the icon
-- was in fact being hidden -- the exact failure the comment above forbids. Assert
-- BOTH halves separately so neither can cover for the other.
check("icon left alone when unread mail remains",
      _G._iconShown == true,
      "icon hidden with unread mail present")
check("a skipped C.O.D. mail is still flagged unread",
      not inbox[1].wasRead,
      "skipped C.O.D. mail was marked read, so nothing points at it any more")
-- ============================ pending mail: the icon must SURVIVE an empty inbox
-- (!) Auction mail is delivered on a delay. The icon lights while the mail is
-- still on its way and the inbox is genuinely empty -- clearing it then destroys
-- the only notice that something is coming. Reported live.
inbox = {}
taken = { items = {}, money = 0 }; bagFree = 20; _G._iconShown = true
runToEnd()
check("minimap icon left alone when the inbox is empty",
      _G._iconShown == true, "icon was hidden with mail still pending")

-- ===================== already-read mail that we empty must clear the icon
-- (!) Reported live: opened the auction mail by hand (so it was already read),
-- left the items, hit Take All -- and the notification stayed lit. The inbox ends
-- up empty, which the pending-mail guard treats as "nothing to see". What tells
-- the two apart is that this run actually took something.
inbox = {
    { sender = "AH", money = 0, wasRead = 1, items = { "Potion" } },
}
taken = { items = {}, money = 0 }; bagFree = 20; _G._iconShown = true
runToEnd()
check("took the item from already-read mail", #taken.items == 1, #taken.items)
check("icon cleared after emptying an already-read mail",
      _G._iconShown == false, "icon still lit")

-- ================================================================ empty mailbox
inbox = {}
taken = { items = {}, money = 0 }; bagFree = 20
runToEnd()
check("empty mailbox finishes without error", NorgMail_IsRunning() == false and #taken.items == 0)

print(string.format("\n  ==== %d passed, %d failed ====", pass, fail))
os.exit(fail == 0 and 0 or 1)
