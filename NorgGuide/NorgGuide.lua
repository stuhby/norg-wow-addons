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
-- (!) A ROW WITH map 0 IS LISTED BUT NOT ROUTABLE, and that is a real state, not an
-- error -- item-started and event-started quests have no giver standing anywhere.
-- They are shown greyed with the click disabled rather than hidden, because silently
-- dropping them would make the plan look shorter than it is for no visible reason.

local ADDON   = "NorgGuide"
local VERSION = "1.0"
local PREFIX  = "NORGPLAN"

local MAX_ROWS   = 10
local ROW_HEIGHT = 30

-- Rows as last received. Rebuilt wholesale on every reply; never merged, because a
-- merge would leave a stale quest on screen after it stopped being eligible.
local rows    = {}
local pending = false
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
-- as a judgement.
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
    if r.map == 0 then
        table.insert(bits, "|cff808080no giver to walk to|r")
    end
    if table.getn(bits) == 0 then
        return "level " .. r.qlvl
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
        else
            btn:Show()
            btn.title:SetText(UnlockColour(r.unlocks) .. r.title .. "|r")
            btn.sub:SetText("|cff808080" .. Reason(r) .. "|r")
            btn.questId = r.questId
            btn.routable = (r.map ~= 0)

            -- (!) Disabling the BUTTON would also grey the text we just coloured, so
            -- routability is carried on the button and checked in the click handler
            -- instead. The row still highlights on hover, which is correct: it is a
            -- real quest, it just has nowhere to walk to.
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
end

-- ------------------------------------------------------------------------ wire

--   P|<id>|<score>|<xp>|<unlocks>|<qlvl>|<map>|<x>|<y>|<z>|<title>
--   E|<n>
--   G|<id>          routing started
--   X|<code>        refused
--
-- (!) THE TITLE IS THE WHOLE REMAINDER, NOT THE TENTH FIELD. Nine numbers are read
-- off the front and everything after them is the title, verbatim. Splitting the line
-- into eleven fields instead would truncate at the first "|" a title ever contains --
-- and while no 3.3.5a quest title does today, this is server data that gets hand-
-- edited, so the failure would show up as a mysteriously half-named quest rather than
-- as an error. Reading the tail wholesale cannot break that way.
local function ParseRow(body)
    local fields = {}
    local rest   = body
    for _ = 1, 9 do
        local bar = string.find(rest, "|", 1, true)
        if not bar then
            return nil
        end
        table.insert(fields, string.sub(rest, 1, bar - 1))
        rest = string.sub(rest, bar + 1)
    end

    return {
        questId = tonumber(fields[1]) or 0,
        score   = tonumber(fields[2]) or 0,
        xp      = tonumber(fields[3]) or 0,
        unlocks = tonumber(fields[4]) or 0,
        qlvl    = tonumber(fields[5]) or 0,
        map     = tonumber(fields[6]) or 0,
        x       = tonumber(fields[7]) or 0,
        y       = tonumber(fields[8]) or 0,
        z       = tonumber(fields[9]) or 0,
        title   = rest,
    }
end

local function OnAddonMessage(message)
    local kind = string.sub(message, 1, 1)
    local body = string.sub(message, 3)

    if kind == "P" then
        -- (!) THE FIRST ROW OF A REPLY CLEARS THE LAST ONE. There is no "begin"
        -- marker in the protocol, so `pending` is what distinguishes the first row of
        -- a new answer from a continuation. Without it a second /guide would append
        -- to the first and show twenty rows, ten of them stale.
        if pending then
            rows = {}
            pending = false
        end
        local r = ParseRow(body)
        if r then
            table.insert(rows, r)
        end
        return
    end

    if kind == "E" then
        -- An empty answer still clears: pending survives when zero rows arrived.
        if pending then
            rows = {}
            pending = false
        end
        Refresh()
        if frame then
            frame:Show()
        end
        if table.getn(rows) == 0 then
            Say("nothing worth recommending at your level right now.")
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
        else
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
    -- buttons in it. Same trap NorgHearth documents.
    --
    -- (!) AND NO SetSize -- it does not exist in 3.3.5a.
    f:SetWidth(340)
    f:SetHeight(96 + MAX_ROWS * ROW_HEIGHT)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:EnableMouse(true)
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

    local hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 20, 20)
    hint:SetWidth(290)
    hint:SetJustifyH("LEFT")
    hint:SetText("Click a quest to walk there. Orange opens the most.")

    f:Hide()
    return f
end

-- ---------------------------------------------------------------------- events

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("CHAT_MSG_ADDON")

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

        Say(VERSION .. " loaded. /guide for a ranked shortlist of what to do next.")
        return
    end

    if event == "CHAT_MSG_ADDON" then
        local prefix, message = ...
        if prefix == PREFIX then
            OnAddonMessage(message)
        end
        return
    end
end)

SLASH_NORGGUIDE1 = "/guide"
SlashCmdList["NORGGUIDE"] = function(arg)
    arg = string.lower(arg or "")

    if arg == "close" or arg == "off" or arg == "hide" then
        if frame then frame:Hide() end
        return
    end

    if arg == "help" then
        Say("/guide -- ranked shortlist of what to do next. /guide <n> for n rows. /guide close.")
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
    pending = true
    Send("LIST " .. (n or MAX_ROWS))
end
