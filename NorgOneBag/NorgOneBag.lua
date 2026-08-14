--[[----------------------------------------------------------------------------
  NorgOneBag -- all bags in one window, using the stock 3.3.5a look.

  DESIGN NOTE (the important bit)
  Item buttons inherit ContainerFrameItemButtonTemplate and each bag gets its own
  invisible holder frame whose frame ID is the bag number. That is deliberate:
  Blizzard's own handlers (ContainerFrameItemButton_OnClick, _OnEnter, split,
  drag, cooldown) all resolve the bag via self:GetParent():GetID(). Parenting the
  buttons correctly means every interaction runs through Blizzard's unmodified
  code -- clicks, shift-split, right-click-to-equip, tooltips, the lot -- instead
  of a reimplementation that would drift from stock behaviour.

  No quality borders and no custom textures: 3.3.5a's real bags do not have them,
  and the brief was to keep the stock theme.
------------------------------------------------------------------------------]]

local ADDON     = "NorgOneBag"
local COLS      = 12      -- items per row
local BTN_SIZE  = 39      -- 37px stock button + 2px gap (spacing, not button size)
local PAD       = 10
local TOP_PAD   = 32      -- room for the title bar
local BOTTOM    = 34      -- room for the money frame

local NUM_BAGS  = 5       -- backpack (0) + 4 equipped bags

-- Background texture and tint.
--
-- (!) This is deliberately a constant because it needed guess-and-check against
-- a live client, and different 3.3.5a builds ship slightly different art. If the
-- panel looks wrong, swap BG_TEXTURE for one of the alternatives below and
-- /reload -- no other change is needed.
--
--   Interface\\FrameGeneral\\UI-Background-Rock     textured stone (default)
--   Interface\\FrameGeneral\\UI-Background-Marble   textured, lighter
--   Interface\\Tooltips\\UI-Tooltip-Background      FLAT fill, tint only, no texture
--   Interface\\DialogFrame\\UI-DialogBox-Background parchment (did not render here)
--
-- BG_COLOR tints whatever texture is chosen. Alpha 1.0 is fully opaque; lower it
-- if you want the world showing through.
local BG_TEXTURE = "Interface\\FrameGeneral\\UI-Background-Rock"
local BG_COLOR   = { 0.35, 0.24, 0.14, 1.0 }   -- warm bag brown, opaque

local frame, holders, buttons = nil, {}, {}

-- ---------------------------------------------------------------- main frame
local function CreateMainFrame()
    local f = CreateFrame("Frame", "NorgOneBagFrame", UIParent)
    f:SetFrameStrata("HIGH")
    f:SetToplevel(true)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local p, _, rp, x, y = self:GetPoint()
        NorgOneBagDB = NorgOneBagDB or {}
        NorgOneBagDB.pos = { p, rp, x, y }
    end)

    -- (!) Give the frame a real size BEFORE SetBackdrop. A backdrop applied to a
    -- zero-size frame does not render -- the edge insets exceed the frame and
    -- there is nothing left to draw. Layout() resizes it properly straight after,
    -- but the backdrop has to have something to attach to first. This is why the
    -- background was missing in v1.0.
    f:SetWidth(400)
    f:SetHeight(300)
    -- (!) DO NOT use Interface\\ContainerFrame\\UI-BackpackBackground here.
    --
    -- That texture is not a neutral fill -- it is COMPOSED artwork with bag-slot
    -- frames, dividers and a gold bar painted into the pixels, drawn for one
    -- specific bag layout. This window changes shape with which bags you carry,
    -- so there is no correct way to scale it: stretched, the slot frames smear;
    -- tiled, they repeat. Both were tried in game and both looked broken.
    --
    -- Instead EMULATE the look: a neutral parchment that tiles seamlessly at any
    -- size, the standard dialog border, and let each item button draw its own
    -- stock slot art (ContainerFrameItemButtonTemplate already does that). The
    -- bag appearance comes from the SLOTS, not from the panel behind them.
    -- (!) UI-DialogBox-Background did not render here either -- twice, tiled and
    -- stretched. Rather than keep guessing at texture paths, use one that is
    -- guaranteed present in every 3.3.5a client (the tooltip fill, used by every
    -- tooltip in the game) and TINT it to bag-brown with SetBackdropColor. That
    -- makes the background independent of any single artwork file existing.
    f:SetBackdrop({
        bgFile   = BG_TEXTURE,
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 64, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    -- Bag-brown, near-opaque. Without this the tooltip fill is plain white.
    f:SetBackdropColor(BG_COLOR[1], BG_COLOR[2], BG_COLOR[3], BG_COLOR[4])
    f:SetBackdropBorderColor(1, 1, 1, 1)


    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", f, "TOP", 0, -14)
    title:SetText("Bags")
    f.title = title

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -6, -6)

    -- Blizzard's own money display, so the number and icons match the backpack.
    local money = CreateFrame("Frame", "NorgOneBagMoneyFrame", f, "SmallMoneyFrameTemplate")
    money:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 12)
    MoneyFrame_SetType(money, "PLAYER")

    tinsert(UISpecialFrames, "NorgOneBagFrame")   -- Escape closes it, like stock frames
    f:Hide()
    return f
end

-- ------------------------------------------------------------------- layout
local function Layout()
    local total = 0
    for bag = 0, NUM_BAGS - 1 do
        total = total + (GetContainerNumSlots(bag) or 0)
    end
    if total == 0 then total = 1 end

    local rows = math.ceil(total / COLS)
    frame:SetWidth(COLS * BTN_SIZE + PAD * 2 + 4)
    frame:SetHeight(rows * BTN_SIZE + TOP_PAD + BOTTOM + PAD)

    local i = 0
    for bag = 0, NUM_BAGS - 1 do
        local slots = GetContainerNumSlots(bag) or 0
        for slot = 1, slots do
            local b = buttons[bag] and buttons[bag][slot]
            if b then
                local col = i % COLS
                local row = math.floor(i / COLS)
                b:ClearAllPoints()
                b:SetPoint("TOPLEFT", frame, "TOPLEFT",
                           PAD + col * BTN_SIZE + 2, -(TOP_PAD + row * BTN_SIZE))
                b:Show()
                i = i + 1
            end
        end
        -- hide buttons for slots that no longer exist (bag was swapped smaller)
        if buttons[bag] then
            for slot = slots + 1, #buttons[bag] do
                buttons[bag][slot]:Hide()
            end
        end
    end
end

-- ------------------------------------------------------------ button plumbing
local function EnsureButtons()
    for bag = 0, NUM_BAGS - 1 do
        if not holders[bag] then
            -- The holder's ID IS the bag number; Blizzard's handlers read it.
            local h = CreateFrame("Frame", "NorgOneBagHolder" .. bag, frame)
            h:SetID(bag)
            h:SetAllPoints(frame)
            holders[bag] = h
            buttons[bag] = {}
        end

        local slots = GetContainerNumSlots(bag) or 0
        for slot = 1, slots do
            if not buttons[bag][slot] then
                local name = "NorgOneBagItem" .. bag .. "_" .. slot
                local b = CreateFrame("Button", name, holders[bag], "ContainerFrameItemButtonTemplate")
                b:SetID(slot)
                -- Deliberately NOT resized. ContainerFrameItemButtonTemplate is
                -- 37x37 with artwork cut to match; scaling it makes the border
                -- and highlight blur. BTN_SIZE below is spacing, not size.
                -- (Also: SetSize() does not exist in 3.3.5a -- it arrived in 4.0.)
                buttons[bag][slot] = b
            end
        end
    end
end

local function UpdateSlot(bag, slot)
    local b = buttons[bag] and buttons[bag][slot]
    if not b then return end

    local texture, count, locked, quality, readable = GetContainerItemInfo(bag, slot)

    SetItemButtonTexture(b, texture)
    SetItemButtonCount(b, count)
    SetItemButtonDesaturated(b, locked)

    -- Stock cooldown swirl, drawn by Blizzard's own helper.
    if ContainerFrame_UpdateCooldown then
        ContainerFrame_UpdateCooldown(bag, b)
    end

    b.readable = readable
    b:Show()
end

local function UpdateAll()
    if not frame or not frame:IsShown() then return end
    EnsureButtons()
    for bag = 0, NUM_BAGS - 1 do
        for slot = 1, (GetContainerNumSlots(bag) or 0) do
            UpdateSlot(bag, slot)
        end
    end
    Layout()
end

-- --------------------------------------------------------------- open / close
local function Open()
    if not frame then return end
    EnsureButtons()
    frame:Show()
    UpdateAll()
end

local function Close()
    if frame then frame:Hide() end
end

local function Toggle()
    if frame and frame:IsShown() then Close() else Open() end
end

-- ---------------------------------------------------------------- event wiring
local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("BAG_UPDATE")
ev:RegisterEvent("ITEM_LOCK_CHANGED")
ev:RegisterEvent("BAG_UPDATE_COOLDOWN")
ev:RegisterEvent("PLAYERBANKSLOTS_CHANGED")

ev:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
        frame = CreateMainFrame()

        NorgOneBagDB = NorgOneBagDB or {}
        if NorgOneBagDB.pos then
            local p, rp, x, y = unpack(NorgOneBagDB.pos)
            frame:SetPoint(p, UIParent, rp, x, y)
        else
            frame:SetPoint("CENTER", UIParent, "CENTER", 200, 0)
        end

        -- Replace the stock bag entry points so every route -- the bag bar, the
        -- 'B' key, and the loot/merchant auto-open -- lands on this window.
        -- These are plain globals in 3.3.5a, not protected, so overriding is safe.
        ToggleBackpack  = Toggle
        OpenBackpack    = Open
        CloseBackpack   = Close
        ToggleBag       = function() Toggle() end
        OpenAllBags     = Open
        CloseAllBags    = Close
        ToggleAllBags   = Toggle

        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00NorgOneBag|r loaded. /onebag to toggle.")
    else
        UpdateAll()
    end
end)

SLASH_NORGONEBAG1 = "/onebag"
SlashCmdList["NORGONEBAG"] = Toggle
