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

Style.GREEN = { 0.3, 0.8, 0.3 }   -- the VERDICT "good" color (mutated in place by ApplyColorVision)
Style.RED = { 0.9, 0.35, 0.35 }   -- the VERDICT "bad" color (same)
Style.GRAY = { 0.55, 0.55, 0.55 } -- disarmed/neutral (matches Splits' pending grey)

-- Color-vision palettes (Fredrik 2026-07-21: "make it work if you have the
-- most common color-blindness type"). The verdict pair swaps wholesale; every
-- verdict site reads Style.GREEN/RED by TABLE REFERENCE each refresh, so
-- ApplyColorVision mutates the two tables in place and the whole UI follows.
-- Pairs: red-green deficiencies (protan/deutan) get the standard blue/orange
-- accessible pair; tritan (blue-yellow) keeps red but pairs it with teal.
-- Identity colors (chest ticks, pairing plates, accent) are NOT verdicts and
-- stay untouched.
Style.COLOR_VISION = {
    default      = { good = { 0.3, 0.8, 0.3 },  bad = { 0.9, 0.35, 0.35 } },
    protanopia   = { good = { 0.35, 0.55, 1 },  bad = { 1, 0.62, 0.1 } },
    deuteranopia = { good = { 0.35, 0.55, 1 },  bad = { 1, 0.62, 0.1 } },
    tritanopia   = { good = { 0.1, 0.8, 0.75 }, bad = { 0.95, 0.3, 0.4 } },
}

function Style.ApplyColorVision(mode)
    local p = Style.COLOR_VISION[mode] or Style.COLOR_VISION.default
    for i = 1, 3 do
        Style.GREEN[i] = p.good[i]
        Style.RED[i] = p.bad[i]
    end
end

local function RgbHex(c)
    return string.format("%02x%02x%02x",
        math.floor(c[1] * 255 + 0.5), math.floor(c[2] * 255 + 0.5), math.floor(c[3] * 255 + 0.5))
end

--- Verdict colors as chat-escape hex (recomputed per call — palette-aware).
function Style.GoodHex() return RgbHex(Style.GREEN) end
function Style.BadHex() return RgbHex(Style.RED) end
Style.TEXT = { 0.9, 0.9, 0.9 }    -- Ellesmere objective text color
Style.BAR_BG = { 0.12, 0.12, 0.12, 0.9 }
Style.TICK3 = { 0.4, 1, 0.4 }     -- +3 threshold tick
Style.TICK2 = { 0.3, 0.8, 1 }     -- +2 threshold tick
Style.TICK1 = { 0.9, 0.9, 0.9 }   -- par (+1) tick — the bar end in Ellesmere's own timer

-- Roster pairing colors: exact entries from MDT's rainbow pull palette (indices 5, 7,
-- 10, 3) — hues Fredrik's eyes already know as "distinct pulls" — skipping its greens
-- (our verdict color) and near-teals (our accent). Ring color n pairs runner n on the
-- track with roster row n; the raced ghost pairs via the row highlight + full-bright
-- icon (the pairing golds — roster plate, then badge ring — retired 2026-07-20;
-- only the pin lock glyph stays gold).
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

-- Panel chrome recipe (single source — SkinPanel applies, RefreshPanel re-applies).
local PANEL_BG = { 0.05, 0.04, 0.08, 0.85 }
local PANEL_BORDER = { 0.15, 0.15, 0.15, 0.6 }
local ACCENT_ALPHA = 0.9

--- Chrome opacity multiplier (Edit Mode "Background opacity" slider). Fades the
--- backdrop, border, and accent strip ONLY — race content on top stays fully visible
--- at any setting (Fredrik 2026-07-20; the 3-state chrome control stays deferred).
local function ChromeAlpha()
    local a = KG.db and KG.db.bgAlpha
    if type(a) ~= "number" then return 1 end
    return math.max(0, math.min(1, a))
end

local function ApplyChrome(frame)
    local a = ChromeAlpha()
    frame:SetBackdropColor(PANEL_BG[1], PANEL_BG[2], PANEL_BG[3], PANEL_BG[4] * a)
    frame:SetBackdropBorderColor(PANEL_BORDER[1], PANEL_BORDER[2], PANEL_BORDER[3], PANEL_BORDER[4] * a)
    if frame._kgAccent then
        frame._kgAccent:SetColorTexture(Style.GetAccent())
        frame._kgAccent:SetAlpha(ACCENT_ALPHA * a)
    end
end

--- Ellesmere panel skin: dark backdrop, hairline border, accent strip on the right.
function Style.SkinPanel(frame)
    frame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    if not frame._kgAccent then
        frame._kgAccent = frame:CreateTexture(nil, "BORDER")
        frame._kgAccent:SetWidth(2)
        frame._kgAccent:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -1, -1)
        frame._kgAccent:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -1, 1)
    end
    ApplyChrome(frame)
end

--- Re-apply live-resolved pieces (accent tint, chrome opacity); called from periodic
--- refreshes so EllesmereUI accent changes and the opacity slider apply without /reload.
function Style.RefreshPanel(frame)
    if frame.SetBackdropColor and frame._kgAccent then ApplyChrome(frame) end
end
