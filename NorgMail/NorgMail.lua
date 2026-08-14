--[[----------------------------------------------------------------------------
  NorgMail -- empty the mailbox from one button.

  /mail        empty it now
  /mail money  take only the money, leave attachments
  /mail auto   toggle emptying automatically on open (default OFF)
  /mail stop   abort a run

  A "Take All" button also sits on the inbox.

  ------------------------------------------------------------------------------
  (!) FOUR THINGS THAT MAKE THIS HARDER THAN IT LOOKS. Three were learned the
  expensive way here; the fourth from reading Postal, which has had ten years of
  bug reports that this addon has not.

  1. THE BUTTON BELONGS ON InboxFrame, NOT MailFrame. MailFrame is the outer
     window; the inbox is a child of it. Parenting to MailFrame puts the button
     somewhere that is not the inbox -- and anchoring to a frame that is not ready
     throws, which at file scope takes the slash commands down with it and makes
     the whole addon look like it was never installed.

  2. THE INBOX IS EMPTY WHEN MAIL_SHOW FIRES. The client asks the server for the
     list and it arrives a moment later, so the first scan legitimately sees zero
     mail. Treating that as "nothing to take" is what makes an auto-opener look
     dead: it runs, finds nothing and stops, every time, before the mail arrives.

  3. WALK THE INBOX BACKWARDS. Taking an attachment removes it server-side and the
     list is re-sent, so indices shift. Going from the last mail down to the first
     means every index still ahead of us is untouched by a removal behind us.

  4. WAIT FOR THE MAILBOX TO ACTUALLY CHANGE, NOT FOR A TIMER. A fixed delay is a
     guess: too short and takes are rejected against a stale index and items are
     silently left behind; too long and a full mailbox takes a minute. Counting
     the attachments and gold STILL IN the inbox gives a real signal -- when that
     total changes, the previous take landed. The timer is only a fallback for a
     take the server refused outright, not the primary clock.

  C.O.D. mail is always skipped: taking it PAYS it, with no confirmation. GM mail
  is skipped too -- it is there for a reason and should be read.
------------------------------------------------------------------------------]]

local TICK           = 0.15   -- how often we look, not how fast we take
local CHANGE_TIMEOUT = 2.0    -- see note 4
local INBOX_GRACE    = 3.0    -- see note 2
local MAX_ACTIONS    = 250

-- (!) BUTTON-ONLY BY DEFAULT. Emptying the mailbox the instant it opens takes the
-- decision away from you -- there is no chance to look at what arrived, and a
-- C.O.D. or a mail you wanted to read is gone from view before you see it.
-- /mail auto turns automatic emptying on for a session if you want it.
local running, moneyOnly, autoRun = false, false, false
local mailIndex, attachIndex = 0, 0
local waiting, waitTime, waitAttach, waitGold = false, 0, 0, 0
local graceTime, actions = 0, 0
local seeded = false
local tookItems, tookMoney, skippedCOD, skippedGM, skippedFull = 0, 0, 0, 0, 0

local ATTACH_MAX = ATTACHMENTS_MAX_RECEIVE or 16

local Start

local function Say(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00NorgMail|r: " .. msg)
end

--- Ordinary bag slots only. A profession bag reports free slots it will not
--- accept arbitrary mail into, so counting those makes us take an item the
--- client then has nowhere to put.
local function FreeBagSlots()
    local free = 0
    for bag = 0, 4 do
        local slots, bagType = GetContainerNumFreeSlots(bag)
        if slots and (not bagType or bagType == 0) then
            free = free + slots
        end
    end
    return free
end

--- Everything still sitting in the inbox. See note 4: a change here is the only
--- trustworthy evidence that the previous take actually happened.
local function CountRemaining()
    local attach, gold = 0, 0
    for i = 1, GetInboxNumItems() do
        local money, _, _, items = select(5, GetInboxHeaderInfo(i))
        attach = attach + (items or 0)
        gold = gold + (money or 0)
    end
    return attach, gold
end

--- (!) THE MINIMAP ICON TRACKS UNREAD MAIL, NOT FULL MAIL.
---
--- Taking an attachment does not mark anything read. A mail with no body text
--- is deleted once it is empty, so it disappears and all is well -- but every
--- auction-house mail HAS body text, so it survives being emptied and stays
--- unread. The result is an inbox you have just emptied and a notification that
--- will not go away.
---
--- Reading the body is what marks it read, so ask for the body of anything still
--- flagged unread (field 9, wasRead). Then, if nothing unread remains, hide the
--- icon -- the client will not re-evaluate it on its own until the next mail
--- arrives.
local function MarkAllRead()
    local n = GetInboxNumItems()
    local unread = 0
    for i = 1, n do
        if not select(9, GetInboxHeaderInfo(i)) then
            if GetInboxText then GetInboxText(i) end
            unread = unread + 1
        end
    end

    -- Re-check rather than assuming the reads landed: GetInboxText is a request,
    -- and a mail the server refuses to hand over stays unread.
    local stillUnread = 0
    for i = 1, GetInboxNumItems() do
        if not select(9, GetInboxHeaderInfo(i)) then stillUnread = stillUnread + 1 end
    end

    -- (!) AN EMPTY INBOX IS NOT THE SAME AS "NOTHING UNREAD".
    -- Auction-house mail is delivered on a delay: the icon lights up while the
    -- mail is still PENDING and the inbox is genuinely empty. Hiding the icon then
    -- destroys the only notice that something is coming, and nothing re-lights it
    -- until the NEXT mail arrives. So only clear the icon when we can see mail and
    -- have confirmed all of it is read -- never off an empty list.
    -- (Postal has this same flaw: its loop over an empty inbox falls straight
    -- through to Hide().)
    -- (!) TWO WAYS TO HAVE AN EMPTY INBOX, AND THEY NEED OPPOSITE ANSWERS.
    --   nothing arrived yet  -> mail is PENDING, keep the icon (it is the only
    --                           notice you have, and nothing re-lights it)
    --   we just emptied it   -> clear the icon, there is genuinely nothing left
    -- They are indistinguishable from the inbox alone. What separates them is
    -- whether THIS run took anything. Guarding on visible mail alone left the
    -- icon lit after a successful run that emptied the mailbox -- reported live
    -- after taking auction mail that had already been read by hand.
    local tookSomething = (tookItems + tookMoney) > 0
    if MiniMapMailFrame and stillUnread == 0 and (n > 0 or tookSomething) then
        MiniMapMailFrame:Hide()
    end
    return unread, stillUnread
end

local function Finish(why)
    running = false
    MarkAllRead()
    local bits = {}
    if tookItems > 0 then bits[#bits + 1] = tookItems .. " item" .. (tookItems == 1 and "" or "s") end
    if tookMoney > 0 then bits[#bits + 1] = tookMoney .. " money mail" .. (tookMoney == 1 and "" or "s") end
    Say((#bits > 0 and ("took " .. table.concat(bits, " and ")) or "nothing to take") ..
        (why and (" -- " .. why) or "."))
    if skippedCOD > 0 then
        Say("|cffff8080skipped " .. skippedCOD .. " C.O.D. mail|r -- taking those pays them.")
    end
    if skippedGM > 0 then
        Say("|cffff8080skipped " .. skippedGM .. " GM mail|r -- read those yourself.")
    end
    if skippedFull > 0 then
        Say("|cffff8080bags full|r -- make room and run /mail again.")
    end
    if NorgMailButton then NorgMailButton:SetText("Take All") end
end

local function Step()
    if not running then return end

    -- note 2
    if GetInboxNumItems() == 0 then
        if graceTime < INBOX_GRACE then
            graceTime = graceTime + TICK
            return
        end
        Finish(nil)
        return
    end

    -- (!) "NOT STARTED" AND "FINISHED" MUST NOT BE THE SAME STATE.
    -- Seeding on mailIndex == 0 means the moment the walk decrements PAST the
    -- first mail it re-seeds to the end and starts again -- forever, whenever any
    -- mail is left behind. /mail money hits this every time by design, since it
    -- leaves every attachment where it is. The run never ends, `running` stays
    -- true, and every later /mail answers "already running".
    if not seeded then
        seeded = true
        mailIndex = GetInboxNumItems()   -- note 3: start at the end
        attachIndex = ATTACH_MAX
    end

    -- note 4
    if waiting then
        local attach, gold = CountRemaining()
        if attach ~= waitAttach or gold ~= waitGold then
            waiting = false
        else
            waitTime = waitTime + TICK
            if waitTime < CHANGE_TIMEOUT then return end
            -- Nothing changed in time, so that take was refused. Step past it
            -- rather than retrying an index the server will not accept.
            waiting = false
            attachIndex = attachIndex - 1
            if attachIndex < 1 then
                mailIndex = mailIndex - 1
                attachIndex = ATTACH_MAX
            end
        end
    end

    if mailIndex < 1 then
        Finish(nil)
        return
    end

    if actions >= MAX_ACTIONS then
        Finish("safety limit reached; run it again")
        return
    end

    -- (!) POSITIONS, NOT GUESSES. GetInboxHeaderInfo returns thirteen values:
    -- 1 packageIcon, 2 stationeryIcon, 3 sender, 4 subject, 5 money, 6 CODAmount,
    -- 7 daysLeft, 8 itemCount, 9 wasRead, 10 wasReturned, 11 textCreated,
    -- 12 canReply, 13 isGM. Miscounting the placeholders reads the SUBJECT as the
    -- C.O.D. amount, which silently disables the C.O.D. guard -- the one thing in
    -- here that costs real gold if it is wrong.
    local _, _, _, _, money, cod, _, itemCount, _, _, _, _, isGM =
        GetInboxHeaderInfo(mailIndex)

    if (cod and cod > 0) or isGM then
        if isGM then skippedGM = skippedGM + 1 else skippedCOD = skippedCOD + 1 end
        mailIndex = mailIndex - 1
        attachIndex = ATTACH_MAX
        return
    end

    if money and money > 0 then
        waitAttach, waitGold = CountRemaining()
        TakeInboxMoney(mailIndex)
        tookMoney = tookMoney + 1
        actions = actions + 1
        waiting, waitTime = true, 0
        return
    end

    if not moneyOnly and itemCount and itemCount > 0 then
        while attachIndex >= 1 and not GetInboxItem(mailIndex, attachIndex) do
            attachIndex = attachIndex - 1
        end

        if attachIndex >= 1 then
            if FreeBagSlots() < 1 then
                skippedFull = skippedFull + 1
                Finish("bags are full")
                return
            end
            waitAttach, waitGold = CountRemaining()
            TakeInboxItem(mailIndex, attachIndex)
            tookItems = tookItems + 1
            actions = actions + 1
            waiting, waitTime = true, 0
            return
        end
    end

    mailIndex = mailIndex - 1
    attachIndex = ATTACH_MAX
end

local f = CreateFrame("Frame", "NorgMailFrame")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("MAIL_SHOW")
f:RegisterEvent("MAIL_CLOSED")

-- note 1: built lazily, parented to the INBOX.
local function EnsureButton()
    if NorgMailButton or not InboxFrame then return end
    local b = CreateFrame("Button", "NorgMailButton", InboxFrame, "UIPanelButtonTemplate")
    b:SetWidth(120)
    b:SetHeight(25)
    b:SetText("Take All")
    -- (!) These are Postal s coordinates, not guesses. The inbox art has a gap
    -- below the last mail row that LOOKS like the right place and is not -- 15
    -- pixels high leaves the button floating between the last item and the frame
    -- edge. Ten years of Postal bug reports settled where this belongs.
    b:SetPoint("CENTER", InboxFrame, "TOP", -22, -410)
    -- Without the frame-level bump the button renders behind the inbox artwork.
    b:SetFrameLevel(b:GetFrameLevel() + 1)
    b:SetScript("OnClick", function() Start(false) end)
end

f:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
        -- "/mail did nothing" is ambiguous between a broken addon and one the
        -- client never loaded -- and 3.3.5a only scans the AddOns folder at
        -- LAUNCH, so a freshly copied addon is invisible until a full restart.
        Say("loaded. Use the Take All button on the inbox, or /mail. /mail auto for automatic.")
        return
    end

    if event == "MAIL_SHOW" then
        EnsureButton()
        if autoRun and not running then Start(false) end
        return
    end

    if event == "MAIL_CLOSED" and running then
        Finish("mailbox closed")
    end
end)

f:SetScript("OnUpdate", function()
    if running then Step() end
end)

function Start(onlyMoney)
    if running then
        Say("already running -- /mail stop to abort.")
        return
    end
    if not MailFrame or not MailFrame:IsShown() then
        Say("open a mailbox first.")
        return
    end
    running, moneyOnly = true, onlyMoney and true or false
    mailIndex, attachIndex = 0, 0
    waiting, waitTime, graceTime, actions = false, 0, 0, 0
    seeded = false
    tookItems, tookMoney, skippedCOD, skippedGM, skippedFull = 0, 0, 0, 0, 0
    if NorgMailButton then NorgMailButton:SetText("Working") end
    Say(onlyMoney and "taking money only..." or "emptying the mailbox...")
end

NorgMail_Start = Start
NorgMail_Step = Step
NorgMail_IsRunning = function() return running end
NorgMail_MarkAllRead = MarkAllRead
NorgMail_Stats = function() return tookItems, tookMoney, skippedCOD, skippedGM, skippedFull end

SLASH_NORGMAIL1 = "/mail"
SLASH_NORGMAIL2 = "/norgmail"
SlashCmdList["NORGMAIL"] = function(arg)
    arg = arg and arg:lower():gsub("^%s+", ""):gsub("%s+$", "") or ""
    if arg == "stop" then
        if running then Finish("stopped") else Say("not running.") end
        return
    end
    if arg == "auto" then
        autoRun = not autoRun
        Say(autoRun and "will empty the mailbox when you open it."
                     or "automatic emptying OFF -- use /mail or the button.")
        return
    end
    if arg == "money" then Start(true) return end
    if arg == "help" or arg == "?" then
        Say("/mail -- empty it;  /mail money -- money only;  /mail auto -- toggle auto;  /mail stop")
        Say("C.O.D. and GM mail are always skipped.")
        return
    end
    Start(false)
end
