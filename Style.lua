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
--
-- CALLED ONCE, AT LOAD (Core), and never again while the player is online — his
-- 2026-08-02 call: the options dropdown saves the pick and prints when it will
-- apply, so a race can never change color under you mid-key. The in-place
-- mutation still matters, because Style's own rendered strings and every
-- reference-holding caller are seeded from these tables before the first draw.
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

local function RgbHex(c)
    return string.format("%02x%02x%02x",
        math.floor(c[1] * 255 + 0.5), math.floor(c[2] * 255 + 0.5), math.floor(c[3] * 255 + 0.5))
end

-- The verdict pair pre-rendered as text (2026-08-02). Sites that color a WIDGET read
-- Style.GREEN/RED by reference and cost nothing; sites that color a TOKEN INSIDE a
-- string need hex, and those used to run string.format + three math.floor per draw —
-- at the bar's 10 Hz that is ~40-80 throwaway strings a second to rediscover a value
-- that changes when the player opens the options panel, which is to say almost never.
-- Rebuilt only by ApplyColorVision below. Callers still ask per draw: the contract
-- ("never cache the palette yourself") is exactly what makes this safe to cache HERE.
local goodHex, badHex = RgbHex(Style.GREEN), RgbHex(Style.RED)
local goodEscape, badEscape = "|cff" .. goodHex, "|cff" .. badHex

--- The palette to start a FRESH install on, taken from the game's own accessibility
--- toggle (2026-08-02, his question: "are we building things that already exist?").
---
--- `colorblindMode` is real and live in this client — EllesmereUINameplates reads it,
--- Auctionator and FriendGroups use the ENABLE_COLORBLIND_MODE global that mirrors it
--- — but it is a BOOLEAN, and what it drives is text substitution (money icons become
--- letters, an extra tooltip line) rather than any repainting. So it cannot tell us
--- WHICH deficiency, and it is no substitute for the three-way pick. It is still the
--- best first guess we have: someone who turned it on has told the game something.
---
--- Guessing deuteranopia is nearly free, because our protan and deutan palettes are
--- the SAME pair (blue / orange). Only a tritan player is guessed wrong, and they
--- have the dropdown. Used ONLY when db.colorVision is unset — never to overrule a
--- player's pick, and never to change the palette an existing install already runs.
function Style.DefaultColorVision()
    if not _G.GetCVar then return "default" end
    local ok, v = pcall(_G.GetCVar, "colorblindMode")
    if ok and (v == "1" or v == 1) then return "deuteranopia" end
    return "default"
end

function Style.ApplyColorVision(mode)
    local p = Style.COLOR_VISION[mode] or Style.COLOR_VISION.default
    for i = 1, 3 do
        Style.GREEN[i] = p.good[i]
        Style.RED[i] = p.bad[i]
    end
    goodHex, badHex = RgbHex(Style.GREEN), RgbHex(Style.RED)
    goodEscape, badEscape = "|cff" .. goodHex, "|cff" .. badHex
end

--- Verdict colors as chat-escape hex ("RRGGBB") — palette-aware, allocation-free.
function Style.GoodHex() return goodHex end
function Style.BadHex() return badHex end

--- The same pair as ready-made color escapes ("|cffRRGGBB"), for coloring one token
--- inside a line: `Style.BadEscape() .. text .. "|r"` allocates once, not three times.
function Style.GoodEscape() return goodEscape end
function Style.BadEscape() return badEscape end
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

--- The RaiderIO logo texture path, or nil (their TOC metadata — never hardcode
--- their asset path). Shared: Bar runner icons/raced badge + the Library's
--- Raider.IO owner cell (his screenshot report 2026-07-21: the banked row read
--- as just another ghost without the logo).
function Style.RaiderIOLogo()
    if not (C_AddOns and C_AddOns.GetAddOnMetadata) then return nil end
    local ok, icon = pcall(C_AddOns.GetAddOnMetadata, "RaiderIO", "IconTexture")
    return (ok and type(icon) == "string" and icon ~= "") and icon or nil
end

-- The Mythic+ chest, as an inline escape for any FontString (Fredrik 2026-07-29:
-- "chest is one of the longest words but the info is very short +#" — so the Roster
-- Panel's chest column wears the icon as its header instead).
--
-- Blizzard's own ChallengeMode end-of-run chest first; the Great Vault chest is the
-- understudy. Both are atlases OTHER live addons render today (MRT and
-- Details_MythicPlus respectively) — but a grep hit is a candidate, not proof (the
-- 2026-07 lesson: a texture picked that way shipped invisible), so each is asked
-- of C_Texture.GetAtlasInfo before use and the caller falls back to the WORD when
-- neither answers. Sized from the atlas's own aspect so the chest is never squashed.
local ATLAS_CANDIDATES = { "ChallengeMode-Chest", "gficon-chest-evergreen-greatvault-collect" }
local chestAtlas -- resolved once per session: atlas info, or false for "none exists"
function Style.ChestIcon(height)
    if chestAtlas == nil then
        chestAtlas = false
        if C_Texture and C_Texture.GetAtlasInfo then
            for _, name in ipairs(ATLAS_CANDIDATES) do
                local ok, info = pcall(C_Texture.GetAtlasInfo, name)
                if ok and type(info) == "table" and (info.width or 0) > 0 and (info.height or 0) > 0 then
                    chestAtlas = { name = name, aspect = info.width / info.height }
                    break
                end
            end
        end
    end
    if not chestAtlas then return nil end
    local h = height or 11
    return string.format("|A:%s:%d:%d|a", chestAtlas.name, h,
        math.max(1, math.floor(h * chestAtlas.aspect + 0.5)))
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

--- The house close button: quiet grey × that brightens on hover — the Ghost
--- Library's recipe, extracted so every window closes with the same X
--- (Fredrik 2026-07-21: the summary wore the default red UIPanelCloseButton).
function Style.CloseButton(parent, onClick)
    local close = CreateFrame("Button", nil, parent)
    close:SetSize(18, 18)
    close.text = close:CreateFontString(nil, "OVERLAY")
    Style.SetFont(close.text, 13)
    close.text:SetPoint("CENTER")
    close.text:SetText("×")
    close.text:SetTextColor(Style.GRAY[1], Style.GRAY[2], Style.GRAY[3])
    close:SetScript("OnEnter", function() close.text:SetTextColor(1, 1, 1) end)
    close:SetScript("OnLeave", function() close.text:SetTextColor(Style.GRAY[1], Style.GRAY[2], Style.GRAY[3]) end)
    close:SetScript("OnClick", onClick)
    return close
end

--- The house checkbox: a small bordered box with an accent fill when ticked,
--- plus a label, wearing the Library Import button's chrome. Hand-rolled on
--- purpose — Blizzard's UICheckButtonTemplate hangs its label off `$parentText`,
--- which an unnamed frame cannot resolve, and the ticked state is a filled
--- square rather than a glyph so it can never depend on the font carrying "✓".
--- `get` is re-read by :Refresh(); `set` receives the new boolean.
function Style.CheckBox(parent, label, get, set)
    local BOX, GAP = 14, 5
    local IDLE = { 0.63, 0.63, 0.66 }
    local b = CreateFrame("Button", nil, parent)
    b:SetHeight(BOX)

    local box = CreateFrame("Frame", nil, b, "BackdropTemplate")
    box:SetSize(BOX, BOX)
    box:SetPoint("LEFT")
    box:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
    box:SetBackdropColor(0.16, 0.16, 0.20, 0.9)
    box:SetBackdropBorderColor(0.29, 0.29, 0.33, 1)

    local fill = box:CreateTexture(nil, "OVERLAY")
    fill:SetTexture("Interface\\Buttons\\WHITE8x8")
    fill:SetPoint("TOPLEFT", 3, -3)
    fill:SetPoint("BOTTOMRIGHT", -3, 3)

    local text = b:CreateFontString(nil, "OVERLAY")
    Style.SetFont(text, 10)
    text:SetPoint("LEFT", box, "RIGHT", GAP, 0)
    text:SetText(label)
    text:SetTextColor(IDLE[1], IDLE[2], IDLE[3])
    b:SetWidth(BOX + GAP + text:GetStringWidth() + 2)

    function b:Refresh()
        fill:SetColorTexture(Style.GetAccent())
        fill:SetShown(get() and true or false)
    end
    b:SetScript("OnClick", function(self)
        set(not get())
        self:Refresh()
    end)
    b:SetScript("OnEnter", function()
        box:SetBackdropBorderColor(Style.GetAccent())
        text:SetTextColor(0.95, 0.95, 0.98)
    end)
    b:SetScript("OnLeave", function()
        box:SetBackdropBorderColor(0.29, 0.29, 0.33, 1)
        text:SetTextColor(IDLE[1], IDLE[2], IDLE[3])
    end)
    b:Refresh()
    return b
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
