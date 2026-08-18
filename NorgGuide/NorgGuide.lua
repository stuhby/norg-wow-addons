-- NorgGuide -- the client half of the quest planner.
--
-- The operator's ask: "not just what quests are available for me, but what quests I
-- SHOULD be doing to be the most efficient/useful... I don't care about quests that
-- are low reward and are unnecessary to progress."
--
-- So this window is a SHORTLIST, not a second quest log. Ten rows, ranked by
-- consequence, and clicking one walks you to whoever gives it.
--
-- ---------------------------------------------------------------------------------
-- (!) THIS ADDON DECIDES NOTHING. Every number shown here was computed on the server
-- and arrives over the wire. That is deliberate and it is not merely tidiness:
--
--   * Eligibility is Player::CanTakeQuest -- all seventeen SatisfyQuest* checks. The
--     client cannot see prerequisite chains, exclusive groups, reputation gates or
--     the disable table at all, so any client-side filter would be a guess that
--     disagrees with what the NPC actually offers.
--   * Routing is NorgNavRoute::StartTarget, which owns the navmesh, the boat and
--     zeppelin table and the drop and lift legs. Sending the addon a coordinate and
--     letting it call NORGNAV START would be WRONG, not just duplicated: START stamps
--     the player's own map onto the target, and half these quests are on another
--     continent. See the comment on the NorgNavRoute declaration in norg_plan.cpp.
--
-- The one thing that would break this contract is adding a "sort by" or "filter" here
-- that the server does not also apply. Ask the server for a different list instead.
--
-- ---------------------------------------------------------------------------------
-- (!) ROUTABILITY IS AN EXPLICIT FIELD ON THE WIRE. IT MUST NEVER BE INFERRED FROM
-- THE MAP ID AGAIN.
--
-- Version 1.0 sent map 0 to mean "this quest has no giver standing anywhere" and this
-- file tested `r.map ~= 0`. Map 0 IS EASTERN KINGDOMS -- 1,939 quests, the single
-- largest giver map in the game -- so the sentinel collided with the most common real
-- value it could possibly have picked. Every Eastern Kingdoms quest would have
-- rendered dimmed and refused to route.
--
-- The protocol now carries a separate 0/1 `routable` column. A map id can never
-- collide with it, and a future map id cannot reintroduce the bug.

local ADDON   = "NorgGuide"
local VERSION = GetAddOnMetadata and (GetAddOnMetadata(ADDON, "Version") or "?") or "?"
local PREFIX  = "NORGPLAN"

local MAX_ROWS   = 10
local ROW_HEIGHT = 30

-- Rows as last received, and the batch currently arriving.
--
-- (!) ROWS ARE SWAPPED IN WHOLESALE AT `E`, NEVER APPENDED AS THEY ARRIVE. Two
-- /guide requests can be in flight at once -- a double keypress on a macro is enough
-- -- and there is no "begin" marker in the protocol. Accumulating straight into the
-- displayed list made the second reply CONCATENATE onto the first, so the window
-- showed twenty rows, ten of them superseded, and the freshly computed plan was the
-- half that got hidden. Buffering makes each reply atomic: last one wins, whole.
local rows     = {}
local incoming = {}

-- Whether we have an outstanding request. Guards the window against opening on a
-- message the player did not ask for -- see the sender check below.
--
-- (!) A FLAG, NOT A COUNTER, DELIBERATELY. Counting sends and decrementing on each
-- reply looks more precise and is worse: a request that never gets answered -- the
-- module missing after a rebuild, a dropped packet -- leaves permanent credit behind,
-- so a later unsolicited reply would open the window and the bug would be invisible
-- until it happened. A flag cannot drift. Two overlapping requests are still handled
-- correctly: the first reply opens the window, the second silently refreshes it,
-- which is what the player wants either way.
local awaiting = false

-- Set when the quest log changes under an open window. See the QUEST_* handlers.
local stale = false

local frame

local function Say(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99NorgGuide|r: " .. msg)
end

-- Control channel to the server module.
--
-- (!) WHISPER TO SELF, not SAY. The server swallows the line before it reaches chat,
-- but only while mod-norg-nav is loaded. If the module is ever missing, a SAY would
-- broadcast "NORGPLAN LIST 10" to everyone standing nearby. Whispering yourself means
-- the worst case is a line only you can see. Same reasoning as NorgNav and NorgQuest.
--
-- (!) The server's handler swallows on the "NORGPLAN " prefix ALONE and ignores the
-- chat type, so a SAY regression here would NOT be visible in normal play -- it would
-- surface only on the day the module is absent, broadcasting the control protocol to
-- everyone in range. guide_test.lua asserts the channel and the target for that
-- reason; do not weaken it to asserting the message text only.
local function Send(cmd)
    local me = UnitName and UnitName("player")
    if me then
        SendChatMessage(PREFIX .. " " .. cmd, "WHISPER", nil, me)
    end
end

-- ------------------------------------------------------------------ presentation

-- Colour a row by how much it unlocks, because that is the operator's stated
-- priority: a quest that gates further content outranks one that pays slightly more
-- and ends. Three bands, not a gradient -- a gradient reads as decoration, bands read
-- as a judgement. The boundaries are asserted in guide_test.lua; they are the whole
-- meaning of the colour, so moving one is a behaviour change, not a tweak.
local function UnlockColour(unlocks)
    if unlocks >= 8 then
        return "|cffff8000"          -- chain head: this opens a lot
    elseif unlocks >= 1 then
        return "|cff1eff00"          -- leads somewhere
    end
    return "|cffffffff"              -- self-contained
end

-- (!) THE SUBTITLE NAMES THE REASON, NOT THE SCORE. A bare number is unarguable-
-- looking and tells nobody why one quest beat another; the whole reason the server
-- sends the terms separately is so this line can say which one dominated. Ordered by
-- what the operator said they cared about: what it unlocks first, reward second.
local function Reason(r)
    local bits = {}
    if r.unlocks >= 1 then
        table.insert(bits, "opens " .. r.unlocks .. (r.unlocks == 1 and " quest" or " quests"))
    end
    if r.xp > 0 then
        table.insert(bits, r.xp .. " xp")
    end
    if not r.routable then
        table.insert(bits, "|cff808080no giver to walk to|r")
    end
    if table.getn(bits) == 0 then
        -- (!) GUARD THE LEVEL FALLBACK. A quest that scales to the player is stored
        -- with QuestLevel -1, and this branch is reached precisely by the rows that
        -- have no xp and no unlocks -- which live observation showed are almost all
        -- scaling quests. Printing "level -1" was the ONLY thing this fallback ever
        -- actually rendered. The server now resolves -1 before sending; this stays as
        -- the belt to that braces, because the failure is silent and looks like data
        -- corruption to a player.
        if r.qlvl and r.qlvl > 0 then
            return "level " .. r.qlvl
        end
        return "worth a look"
    end
    return table.concat(bits, ", ")
end

local function Refresh()
    if not frame then
        return
    end

    for i = 1, MAX_ROWS do
        local btn = frame.rows[i]
        local r   = rows[i]

        if not r then
            btn:Hide()
            -- (!) CLEAR THE IDENTITY, NOT JUST THE VISIBILITY. A hidden button keeps
            -- whatever quest it last held, and the rows are globally named
            -- NorgGuideRow1..10, so a `/click NorgGuideRow1` macro still fires it.
            -- The reachable case is the ordinary empty answer: `E|0` hides every row
            -- while row 1 stays stamped with a quest from the previous listing.
            -- NorgHearth clears its slot for exactly this reason.
            btn.questId  = nil
            btn.routable = nil
        else
            btn:Show()
            btn.title:SetText(UnlockColour(r.unlocks) .. r.title .. "|r")
            btn.sub:SetText("|cff808080" .. Reason(r) .. "|r")
            btn.questId  = r.questId
            btn.routable = r.routable

            -- (!) Disabling the BUTTON would also grey the text we just coloured, so
            -- routability is carried on the button and checked in the click handler
            -- instead. The row still highlights on hover, which is correct: it is a
            -- real quest, it just has nowhere to walk to.
            --
            -- (!) READ IT FROM THE PARSED ROW. Version 1.0 wrote the flag onto the
            -- BUTTON here and then tested it on the ROW -- a field ParseRow never
            -- created -- so the test was always nil and EVERY row rendered dimmed.
            -- The dim cue carried no information at all, and the test asserting
            -- "unroutable row is dimmed" passed vacuously against it.
            if r.routable then
                btn.title:SetAlpha(1.0)
            else
                btn.title:SetAlpha(0.55)
            end
        end
    end

    if table.getn(rows) == 0 then
        frame.empty:Show()
    else
        frame.empty:Hide()
    end

    if frame.hint then
        if stale then
            frame.hint:SetText("|cffff8000Your quest log changed -- /guide to re-rank.|r")
        else
            frame.hint:SetText("Click a quest to walk there. Orange opens the most.")
        end
    end
end

-- ------------------------------------------------------------------------ wire

--   P|<id>|<score>|<xp>|<unlocks>|<qlvl>|<routable>|<map>|<x>|<y>|<z>|<title>
--   E|<n>
--   G|<id>          routing started
--   X|<code>        refused
--
-- (!) THE TITLE IS THE WHOLE REMAINDER, NOT THE ELEVENTH FIELD. Ten numbers are read
-- off the front and everything after them is the title, verbatim. Splitting the line
-- into eleven fields instead would truncate at the first "|" a title ever contains --
-- and while no 3.3.5a quest title does today, this is server data that gets hand-
-- edited, so the failure would show up as a mysteriously half-named quest rather than
-- as an error. Reading the tail wholesale cannot break that way.
local function ParseRow(body)
    local fields = {}
    local rest   = body
    for _ = 1, 10 do
        local bar = string.find(rest, "|", 1, true)
        if not bar then
            return nil
        end
        table.insert(fields, string.sub(rest, 1, bar - 1))
        rest = string.sub(rest, bar + 1)
    end

    return {
        questId  = tonumber(fields[1]) or 0,
        score    = tonumber(fields[2]) or 0,
        xp       = tonumber(fields[3]) or 0,
        unlocks  = tonumber(fields[4]) or 0,
        qlvl     = tonumber(fields[5]) or 0,
        routable = (fields[6] == "1"),
        map      = tonumber(fields[7]) or 0,
        x        = tonumber(fields[8]) or 0,
        y        = tonumber(fields[9]) or 0,
        z        = tonumber(fields[10]) or 0,
        title    = rest,
    }
end

local function OnAddonMessage(message)
    local kind = string.sub(message, 1, 1)
    local body = string.sub(message, 3)

    if kind == "P" then
        local r = ParseRow(body)
        if r then
            table.insert(incoming, r)
        end
        return
    end

    if kind == "E" then
        rows     = incoming
        incoming = {}
        stale    = false
        Refresh()

        -- (!) ONLY OPEN THE WINDOW FOR A REPLY WE ASKED FOR. Anyone can send this
        -- addon a message (see the sender check in the event handler); without this,
        -- a reply arriving after the player closed the window silently reopened it.
        if awaiting then
            awaiting = false
            if frame then
                frame:Show()
            end
            if table.getn(rows) == 0 then
                Say("nothing worth recommending at your level right now.")
            end
        end
        return
    end

    if kind == "G" then
        Say("routing there -- follow the NorgNav arrow.")
        return
    end

    if kind == "X" then
        if body == "nostart" then
            Say("that one has no giver standing anywhere -- it starts from an item or an event.")
        elseif body == "noroute" then
            Say("no way to get there from here.")
        elseif body == "cooldown" then
            Say("easy -- give it a couple of seconds and ask again.")
        elseif string.sub(body, 1, 9) == "indungeon" then
            local where = string.sub(body, 11)
            if where == "" then
                Say("that giver is inside a dungeon -- walk in and they are just past the entrance.")
            else
                Say("that giver is inside " .. where .. " -- walk in and they are just past the entrance.")
            end
        else
            -- (!) NAME THE CODE. A silent no-op is the worst possible answer to "why
            -- did nothing happen", and an unrecognised code means the server is newer
            -- than the addon -- which is exactly when the player needs to be told.
            Say("the server refused that (" .. body .. ").")
        end
        return
    end
end

-- ------------------------------------------------------------------------- ui

local function BuildFrame()
    local f = CreateFrame("Frame", "NorgGuideFrame", UIParent)

    -- (!) A REAL SIZE BEFORE SetBackdrop. A backdrop on a zero-size frame does not
    -- render and does not error -- the window is simply invisible with working
    -- buttons in it. Same trap NorgHearth documents, and it cost NorgOneBag a version.
    --
    -- (!) AND NO SetSize -- it does not exist in 3.3.5a.
    f:SetWidth(340)
    f:SetHeight(96 + MAX_ROWS * ROW_HEIGHT)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:EnableMouse(true)

    -- (!) CLAMP TO THE SCREEN. StartMoving preserves the grab offset, so grabbing
    -- near the left edge and releasing at the right edge already puts a 340-wide
    -- window entirely off-screen -- and the position is saved ACCOUNT-WIDE, so one
    -- bad drag follows the player onto every character. There is no minimap button
    -- to recover with, and /guide then prints nothing at all, so the addon simply
    -- looks dead. /guide reset is the other half of this.
    f:SetClampedToScreen(true)

    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function() f:StartMoving() end)
    f:SetScript("OnDragStop", function()
        f:StopMovingOrSizing()
        local p, _, rp, x, y = f:GetPoint()
        NorgGuideDB.pos = { p = p, rp = rp, x = x, y = y }
    end)

    f:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })

    local t = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    t:SetPoint("TOP", f, "TOP", 0, -16)
    t:SetText("What to do next")

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -6, -6)

    f.empty = f:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    f.empty:SetPoint("TOP", f, "TOP", 0, -52)
    f.empty:SetWidth(290)
    f.empty:SetText("Nothing to suggest. Type /guide to ask again.")
    f.empty:Hide()

    f.rows = {}
    for i = 1, MAX_ROWS do
        local y = -42 - (i - 1) * ROW_HEIGHT

        local btn = CreateFrame("Button", "NorgGuideRow" .. i, f)
        btn:SetWidth(300)
        btn:SetHeight(ROW_HEIGHT - 2)
        btn:SetPoint("TOPLEFT", f, "TOPLEFT", 20, y)

        local hl = btn:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints(btn)
        hl:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
        hl:SetBlendMode("ADD")

        btn.title = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        btn.title:SetPoint("TOPLEFT", btn, "TOPLEFT", 0, 0)
        btn.title:SetWidth(300)
        btn.title:SetJustifyH("LEFT")

        btn.sub = btn:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        btn.sub:SetPoint("TOPLEFT", btn, "TOPLEFT", 0, -13)
        btn.sub:SetWidth(300)
        btn.sub:SetJustifyH("LEFT")

        btn:SetScript("OnClick", function(self)
            -- (!) THE LOAD-BEARING PART IS Refresh RE-STAMPING btn.questId ON EVERY
            -- REPLY, not the fact that this reads it off the clicked frame. Rows are
            -- reused -- row 3 is a different quest after every /guide -- so a Refresh
            -- that stamped the id only once would leave this firing the quest that
            -- was third in the FIRST listing while the window displayed the right
            -- name. That mutation was applied to a scratch copy and guide_test.lua
            -- catches it ("row 1 re-aims after a new listing").
            --
            -- Closing over `btn` instead of taking `self` would in fact be
            -- equivalent, because it is the same object Refresh writes to; that was
            -- also mutation-tested, and the suite does NOT distinguish the two. Said
            -- plainly because the tempting comment here -- "never capture it in the
            -- closure" -- reads like a rule the tests enforce, and they do not.
            if not self.questId or self.questId == 0 then
                return
            end
            if not self.routable then
                Say("that one starts from an item or an event -- there is nobody to walk to.")
                return
            end
            Send("GO " .. self.questId)
        end)

        btn:Hide()
        f.rows[i] = btn
    end

    f.hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    f.hint:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 20, 20)
    f.hint:SetWidth(290)
    f.hint:SetJustifyH("LEFT")
    f.hint:SetText("Click a quest to walk there. Orange opens the most.")

    -- (!) ESCAPE MUST CLOSE IT. Of the addons here that build a dismissible panel
    -- with a UIPanelCloseButton, this was the only one that did not register, so
    -- Escape opened the Game Menu on top of the guide instead of dismissing it.
    -- CloseSpecialWindows only touches shown entries, so this is side-effect free.
    if UISpecialFrames then
        tinsert(UISpecialFrames, "NorgGuideFrame")
    end

    f:Hide()
    return f
end

-- ---------------------------------------------------------------------- events

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("CHAT_MSG_ADDON")
-- (!) THE SPECIFIC QUEST EVENTS, NOT QUEST_LOG_UPDATE. The plan goes stale the moment
-- the quest log changes -- accepting the top recommendation is itself what invalidates
-- it, and the successors it just unlocked cannot appear until something re-asks. Only
-- these three are registered because QUEST_LOG_UPDATE fires in bursts for every
-- objective tick; NorgQuest documents that trap and its coalescing workaround.
ev:RegisterEvent("QUEST_ACCEPTED")
ev:RegisterEvent("QUEST_TURNED_IN")
ev:RegisterEvent("QUEST_REMOVED")

ev:SetScript("OnEvent", function(_, event, ...)
    if event == "PLAYER_LOGIN" then
        if type(NorgGuideDB) ~= "table" then
            NorgGuideDB = {}
        end
        frame = BuildFrame()

        local p = NorgGuideDB.pos
        if p then
            frame:ClearAllPoints()
            frame:SetPoint(p.p, UIParent, p.rp, p.x, p.y)
        end

        Say("v" .. VERSION .. " loaded. /guide for a ranked shortlist of what to do next.")
        return
    end

    if event == "CHAT_MSG_ADDON" then
        -- (!) THE SENDER AND THE CHANNEL ARE CHECKED, NOT JUST THE PREFIX.
        --
        -- Any player can send an addon message to any other player, and on the addon
        -- language the server skips ALL of its sanitisation -- isNasty, hyperlink
        -- validation and the fake-message check all sit inside `if (lang !=
        -- LANG_ADDON)`. The title arrives here and goes straight into SetText, so a
        -- stranger could force this window open displaying arbitrary UI escapes
        -- (textures, hyperlinks, colour codes) and a fabricated quest list.
        --
        -- The module's own reply is built with the player as BOTH sender and
        -- receiver, so requiring a self-whisper rejects everything else without
        -- rejecting anything real. Dispatching on the prefix alone is a family-wide
        -- habit here; this is the first one to stop.
        local prefix, message, channel, sender = ...
        if prefix ~= PREFIX then
            return
        end
        if channel ~= "WHISPER" or sender ~= UnitName("player") then
            return
        end
        OnAddonMessage(message)
        return
    end

    -- Any of the three quest events. The window is not re-asked automatically -- that
    -- would fight the server's per-player cooldown and could loop -- it is marked so
    -- the hint line says what happened and what to do about it.
    if frame and frame:IsShown() then
        stale = true
        Refresh()
    end
end)

SLASH_NORGGUIDE1 = "/guide"
SlashCmdList["NORGGUIDE"] = function(arg)
    arg = string.lower(arg or "")

    if arg == "close" or arg == "off" or arg == "hide" then
        if frame then frame:Hide() end
        return
    end

    if arg == "reset" then
        NorgGuideDB.pos = nil
        if frame then
            frame:ClearAllPoints()
            frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
            frame:Show()
        end
        Say("window moved back to the middle of the screen.")
        return
    end

    if arg == "help" then
        Say("/guide -- ranked shortlist of what to do next. /guide <n> for n rows. "
            .. "/guide close. /guide reset if you have dragged it off-screen.")
        return
    end

    -- (!) CAP THE REQUEST AT THE NUMBER OF ROWS THAT EXIST. The server honours up to
    -- PLAN_MAX_COUNT (40), but this window builds MAX_ROWS buttons once at login, so
    -- asking for 20 would receive 20 and display 10 -- a silent truncation that looks
    -- like the server ran out of suggestions.
    local n = tonumber(arg)
    if n and n > MAX_ROWS then
        Say("showing " .. MAX_ROWS .. " -- that is as many as this window holds.")
        n = MAX_ROWS
    end
    awaiting = true
    Send("LIST " .. (n or MAX_ROWS))
end
