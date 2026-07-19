-- EllesmereUI-matched styling, with graceful fallbacks when EllesmereUI is absent.
--
-- The recipe is lifted from EllesmereUIMythicTimer's standalone frame (read, not
-- modified — it is third-party): WHITE8x8 backdrop (0.05, 0.04, 0.08, 0.85), 1px border
-- (0.15, 0.15, 0.15, 0.6), a 2px accent strip down the right edge, Expressway-style font
-- via EllesmereUI's font registry, bar backgrounds (0.12, 0.12, 0.12, 0.9), accent bar
-- fills, and the +3 / +2 tick colors (0.4,1,0.4) / (0.3,0.8,1). Accent and font are
-- resolved live so user reskins of EllesmereUI carry over automatically.
local ADDON_NAME, NS = ...
local KG = NS.KG

local Style = {}
KG.Style = Style

local FALLBACK_FONT = "Fonts\\FRIZQT__.TTF"
local FALLBACK_ACCENT = { 0.05, 0.83, 0.62 } -- Ellesmere green

Style.GREEN = { 0.3, 0.8, 0.3 }   -- Ellesmere "completed" green
Style.RED = { 0.9, 0.35, 0.35 }
Style.TEXT = { 0.9, 0.9, 0.9 }    -- Ellesmere objective text color
Style.BAR_BG = { 0.12, 0.12, 0.12, 0.9 }
Style.TICK3 = { 0.4, 1, 0.4 }     -- +3 threshold tick
Style.TICK2 = { 0.3, 0.8, 1 }     -- +2 threshold tick
Style.TICK1 = { 0.9, 0.9, 0.9 }   -- par (+1) tick — the bar end in Ellesmere's own timer

-- Roster pairing colors: exact entries from MDT's rainbow pull palette (indices 5, 7,
-- 10, 3) — hues Fredrik's eyes already know as "distinct pulls" — skipping its greens
-- (our verdict color) and near-teals (our accent). Ring color n pairs runner n on the
-- track with roster row n; the raced ghost pairs via the GOLD ring instead.
Style.PULL_COLORS = {
    { 0.2446, 0.2446, 1 },   -- MDT blue
    { 1, 0.2446, 1 },        -- MDT magenta
    { 1, 0.60971, 0.2446 },  -- MDT orange
    { 0.2446, 1, 1 },        -- MDT cyan (4th, if rosterSize is ever raised)
}

function Style.GetAccent()
    local E = _G.EllesmereUI
    if E and E.ResolveActiveAccent then
        local ok, r, g, b = pcall(E.ResolveActiveAccent)
        if ok and type(r) == "number" then return r, g, b end
    end
    return FALLBACK_ACCENT[1], FALLBACK_ACCENT[2], FALLBACK_ACCENT[3]
end

function Style.AccentHex()
    local r, g, b = Style.GetAccent()
    return string.format("%02x%02x%02x", math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5))
end

local function FontPath()
    local E = _G.EllesmereUI
    if E and E.GetFontPath then
        local ok, p = pcall(E.GetFontPath, "mythicTimer")
        if ok and type(p) == "string" then return p end
    end
    if E and type(E.EXPRESSWAY) == "string" then return E.EXPRESSWAY end
    return FALLBACK_FONT
end

local function FontFlags()
    local E = _G.EllesmereUI
    if E and E.GetFontOutlineFlag then
        local ok, f = pcall(E.GetFontOutlineFlag, "mythicTimer")
        if ok and type(f) == "string" then return f end
    end
    return "OUTLINE"
end

--- Apply the Ellesmere timer font (path + outline) at `size`; falls back to FRIZQT if
--- the resolved font fails to load.
function Style.SetFont(fs, size)
    fs:SetFont(FontPath(), size, FontFlags())
    if not fs:GetFont() then fs:SetFont(FALLBACK_FONT, size, FontFlags()) end
    local E = _G.EllesmereUI
    local shadow = E and E.GetFontUseShadow and select(2, pcall(E.GetFontUseShadow, "mythicTimer"))
    if shadow then
        fs:SetShadowColor(0, 0, 0, 0.9); fs:SetShadowOffset(1, -1)
    else
        fs:SetShadowColor(0, 0, 0, 0); fs:SetShadowOffset(0, 0)
    end
end

--- Small mouse-enabled frame that shows a GameTooltip from its `tip` table (line 1 is
--- the title). Kept tiny so only the indicator itself blocks clicks, not what's under it.
function Style.Hover(parent, w, h)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(w, h)
    f:EnableMouse(true)
    f:SetScript("OnEnter", function(self)
        if self.onEnterExtra then self.onEnterExtra(self) end
        if not self.tip or #self.tip == 0 then return end
        -- Standard Blizzard tooltip position (screen corner / wherever the user's
        -- tooltip addon puts it) — anchoring at the indicator covered the bar itself.
        if GameTooltip_SetDefaultAnchor then
            GameTooltip_SetDefaultAnchor(GameTooltip, self)
        else
            GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
        end
        GameTooltip:SetText(self.tip[1])
        for i = 2, #self.tip do GameTooltip:AddLine(self.tip[i], 0.9, 0.9, 0.9) end
        GameTooltip:Show()
    end)
    f:SetScript("OnLeave", function(self)
        if self.onLeaveExtra then self.onLeaveExtra(self) end
        GameTooltip:Hide()
    end)
    return f
end

--- Ellesmere panel skin: dark backdrop, hairline border, accent strip on the right.
function Style.SkinPanel(frame)
    frame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    frame:SetBackdropColor(0.05, 0.04, 0.08, 0.85)
    frame:SetBackdropBorderColor(0.15, 0.15, 0.15, 0.6)
    if not frame._kgAccent then
        frame._kgAccent = frame:CreateTexture(nil, "BORDER")
        frame._kgAccent:SetWidth(2)
        frame._kgAccent:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -1, -1)
        frame._kgAccent:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -1, 1)
    end
    frame._kgAccent:SetColorTexture(Style.GetAccent())
    frame._kgAccent:SetAlpha(0.9)
end

--- Re-tint live-resolved pieces (accent strip); call from periodic refreshes so accent
--- changes in EllesmereUI's options apply without a /reload.
function Style.RefreshPanel(frame)
    if frame._kgAccent then
        frame._kgAccent:SetColorTexture(Style.GetAccent())
        frame._kgAccent:SetAlpha(0.9)
    end
end
