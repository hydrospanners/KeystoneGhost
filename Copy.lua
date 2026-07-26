-- The copy window (Fredrik 2026-07-26): ONE Style-skinned frame behind every
-- "copy this text" door — a ghost's export string, the raider.io run link, the
-- library URL. It replaces the StaticPopup copy dialog, whose editbox was
-- SINGLE-LINE and 280 px wide: passable for a ~1 kB ghost string, useless for a
-- ~24 kB library URL.
--
-- Close on copy is his order, kept as a REMEMBERED preference: Ctrl+C prints the
-- confirmation and closes, and the "Close on copy" checkbox turns that off
-- (db.closeOnCopy, default on — the old StaticPopup always closed, so on is the
-- behaviour people already have). StaticPopupDialogs has no checkbox field:
-- verified across the 94 addons in this install that declare static popups, none
-- carries one, and both MDT and DBM hand-roll a frame the moment they need one.
--
-- The scroll+editbox pair is Blizzard's InputScrollFrameTemplate, verified in
-- live 12.x use by three addons in this install (BetterBags searchcategory,
-- PremadeGroupsFilter, SenseiClassResourceBar's LibEQOL): created with a nil
-- name, the editbox reached through the `EditBox` parentKey, the char counter
-- hidden via `hideCharCount`.
local ADDON_NAME, NS = ...
local KG = NS.KG
local Style = KG.Style

local Copy = {}
KG.Copy = Copy

local WIDTH, HEIGHT = 520, 300
local PAD, TITLE_H, PROMPT_H, BOTTOM_H = 12, 30, 20, 30

local frame

local function BuildFrame()
    frame = CreateFrame("Frame", "KeystoneGhostCopy", UIParent, "BackdropTemplate")
    frame:SetSize(WIDTH, HEIGHT)
    frame:SetFrameStrata("FULLSCREEN_DIALOG") -- above the Library it is opened from
    frame:SetMovable(true)
    frame:SetClampedToScreen(true)
    frame:SetPoint("CENTER")
    Style.SkinPanel(frame)
    frame:Hide()
    table.insert(UISpecialFrames, "KeystoneGhostCopy") -- ESC closes

    local title = CreateFrame("Frame", nil, frame)
    title:SetPoint("TOPLEFT")
    title:SetPoint("TOPRIGHT")
    title:SetHeight(TITLE_H)
    title:EnableMouse(true)
    title:RegisterForDrag("LeftButton")
    title:SetScript("OnDragStart", function() frame:StartMoving() end)
    title:SetScript("OnDragStop", function() frame:StopMovingOrSizing() end)
    frame.title = title:CreateFontString(nil, "OVERLAY")
    Style.SetFont(frame.title, 13)
    frame.title:SetPoint("LEFT", PAD, 0)
    frame.title:SetText("Keystone Ghost")

    local sep = frame:CreateTexture(nil, "BORDER")
    sep:SetTexture("Interface\\Buttons\\WHITE8x8")
    sep:SetVertexColor(0.27, 0.27, 0.31, 0.5)
    sep:SetHeight(1)
    sep:SetPoint("TOPLEFT", 1, -TITLE_H)
    sep:SetPoint("TOPRIGHT", -3, -TITLE_H)

    local close = Style.CloseButton(title, function() frame:Hide() end)
    close:SetPoint("RIGHT", -8, 0)

    frame.prompt = frame:CreateFontString(nil, "OVERLAY")
    Style.SetFont(frame.prompt, 11)
    frame.prompt:SetPoint("TOPLEFT", PAD, -(TITLE_H + 4))
    frame.prompt:SetPoint("TOPRIGHT", -PAD, -(TITLE_H + 4))
    frame.prompt:SetJustifyH("LEFT")
    frame.prompt:SetTextColor(0.63, 0.63, 0.66)

    local scroll = CreateFrame("ScrollFrame", nil, frame, "InputScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", PAD, -(TITLE_H + PROMPT_H))
    scroll:SetPoint("BOTTOMRIGHT", -(PAD + 6), BOTTOM_H)
    scroll.hideCharCount = true
    if scroll.CharCount then scroll.CharCount:Hide() end

    local eb = scroll.EditBox
    eb:SetMaxLetters(0)
    eb:SetMultiLine(true)
    eb:SetAutoFocus(false)
    Style.SetFont(eb, 11)
    eb:SetScript("OnEscapePressed", function() frame:Hide() end)
    -- Ctrl+C: the MDT pattern the StaticPopup already used (WoW has no
    -- clipboard-write API — selecting the text IS the copy). Closing after is
    -- the default, and the checkbox below is the off switch.
    eb:SetScript("OnKeyUp", function(_, key)
        if key == "C" and IsControlKeyDown() then
            if frame.copiedMsg then
                print("|cff88ccffKeystoneGhost|r: " .. frame.copiedMsg)
            end
            if KG.db.closeOnCopy ~= false then frame:Hide() end
        end
    end)
    frame.editBox = eb
    -- The editbox has to be told its width; the template's scroll child does not
    -- inherit it (LibEQOL does the same, minus the scrollbar gutter).
    scroll:SetScript("OnSizeChanged", function(self)
        local w = self:GetWidth() or 0
        if w > 18 then eb:SetWidth(w - 18) end
    end)

    frame.check = Style.CheckBox(frame, "Close on copy",
        function() return KG.db.closeOnCopy ~= false end,
        function(v) KG.db.closeOnCopy = v and true or false end)
    frame.check:SetPoint("BOTTOMLEFT", PAD, (BOTTOM_H - 14) / 2)

    frame.hint = frame:CreateFontString(nil, "OVERLAY")
    Style.SetFont(frame.hint, 10)
    frame.hint:SetPoint("BOTTOMRIGHT", -PAD, (BOTTOM_H - 10) / 2)
    frame.hint:SetTextColor(0.43, 0.43, 0.47)
    frame.hint:SetText("Ctrl+C to copy")

    -- Never hold a 24 kB string in a hidden frame.
    frame:SetScript("OnHide", function() frame.editBox:SetText("") end)
end

--- Show the copy window with `text` selected and ready for Ctrl+C. `prompt` is
--- the line above the box; `copiedMsg` is printed on copy (nil prints nothing).
function Copy:Show(prompt, text, copiedMsg)
    if not frame then BuildFrame() end
    frame:SetScale(KG.db.scale or 1)
    frame.prompt:SetText(prompt or "")
    frame.copiedMsg = copiedMsg
    frame.check:Refresh()
    frame:Show()
    Style.RefreshPanel(frame)
    local eb = frame.editBox
    eb:SetText(text or "")
    eb:HighlightText()
    eb:SetFocus()
end
