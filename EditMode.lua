-- Blizzard Edit Mode integration via bundled LibEditMode (namespaced build — no LibStub).
--
-- The bar registers as an Edit Mode system: drag to reposition, click for a settings
-- dialog (Enabled, Dock under EllesmereUI timer, Scale, Background opacity, Display
-- Ghost Roster + its size + one checkbox per Roster COLUMN). SIZE & POSITION since the
-- 2026-07-28 sweep — how the race DISPLAYS (bounce, pace cars, markers, palettes) lives
-- in the options panel; Options.lua's header carries the sharpened rule. The Roster's
-- own controls are the documented exception, kept together here by that same sweep:
-- it left the panel toggle and the size slider in Edit Mode, and the column checkboxes
-- (2026-07-29) belong beside them rather than in a second dialog. While in Edit Mode
-- the bar previews the synthetic test race so there is something to see and place.
-- Dragging a docked bar is interpreted as "I want it free": the drop position is saved
-- and attach mode turns off; re-docking is one checkbox.
local ADDON_NAME, NS = ...
local KG = NS.KG

local EM = {}
KG.EditMode = EM

--- One checkbox per Ghost Roster column, generated from the panel's own column
--- model (Splits.COLUMNS) so the two can never drift apart. Boss laps ride along
--- as the last entry — they are columns too, just a repeating group of them.
--- Column choices are Edit Mode's business by the architecture rule: they change
--- what is DRAWN, not how the addon behaves.
-- The panel's chest column is headed by an ICON, which says nothing in a settings
-- list — so the checkbox spells the meaning out and shows the icon after it, the
-- way Fredrik asked for it (2026-07-29): "write Chest upgraded level [icon]".
local COLUMN_LABEL = {
    chest = function() return "Column: chest upgrade level " .. (KG.Style.ChestIcon(12) or "") end,
    level = function() return "Column: key level" end,
}

local function ColumnSettings()
    local out = {}
    for _, c in ipairs(KG.Splits.COLUMNS) do
        local label = COLUMN_LABEL[c.id]
        out[#out + 1] = {
            kind = NS.LibEditMode.SettingType.Checkbox,
            name = label and label() or ("Column: " .. c.header),
            desc = c.id == "route"
                and "Show each ghost's MDT route. The widest column: switching it on makes the panel wider than the bar."
                or (c.id == "chest"
                    and "How the key finished: +1 timed, +2 and +3 for the faster thresholds, a red dash for depleted."
                    or ("Show the " .. c.header .. " column in the Ghost Roster.")),
            default = c.default,
            get = function() return KG.Splits.ColumnOn(c) end,
            set = function(_, value)
                KG.db[c.db] = value and true or false
                KG.Splits:Refresh()
            end,
        }
    end
    out[#out + 1] = {
        kind = NS.LibEditMode.SettingType.Checkbox,
        name = "Column: boss laps",
        desc = "Show the per-boss lap deltas (B1, B2, B3) against every ghost. Three columns wide, so switch it off if the panel overhangs a narrow docked timer.",
        default = true,
        get = function() return KG.db.colLaps ~= false end,
        set = function(_, value)
            KG.db.colLaps = value and true or false
            KG.Splits:Refresh()
        end,
    }
    return out
end

function EM:Setup()
    local LEM = NS.LibEditMode
    if not LEM or not LEM.AddFrame then return end

    local bar = KG.Bar.GetFrame()

    LEM:AddFrame(bar, function(frame)
        local point, _, relPoint, x, y = frame:GetPoint()
        KG.db.pos = { point = point, relPoint = relPoint, x = x, y = y }
        KG.db.placed = true -- an Edit Mode drag IS placement: the MOVE ME show stands down
        if KG.db.attach then
            KG.db.attach = nil -- a manual drag means the user wants it free-floating
            print("|cff88ccffKeystoneGhost|r: undocked from the EllesmereUI timer (dragged; re-dock in Edit Mode settings).")
        end
        KG.Bar:InvalidatePosition()
        KG.Bar:Refresh()
    end, { point = "CENTER", x = 0, y = 260 }, "Keystone Ghost")

    local settings = {
        {
            kind = LEM.SettingType.Checkbox,
            name = "Enabled",
            desc = "Show the race bar during Mythic+ keys.",
            default = true,
            get = function() return KG.db.enabled ~= false end,
            set = function(_, value)
                KG.db.enabled = value and true or false
                KG.Bar:Refresh(); KG.Splits:Refresh()
            end,
        },
        {
            kind = LEM.SettingType.Checkbox,
            name = "Dock under EllesmereUI timer",
            desc = "Anchor the bar below the EllesmereUI Mythic+ timer and match its width. Dragging the bar undocks it.",
            default = true,
            get = function() return KG.db.attach == "ellesmere" end,
            set = function(_, value)
                KG.db.attach = value and "ellesmere" or nil
                KG.Bar:InvalidatePosition()
                KG.Bar:Refresh(); KG.Splits:Refresh()
            end,
        },
        {
            kind = LEM.SettingType.Slider,
            name = "Scale",
            default = 1,
            minValue = 0.8,
            maxValue = 1.5,
            valueStep = 0.05,
            formatter = function(v) return string.format("%.0f%%", v * 100) end,
            get = function() return KG.db.scale or 1 end,
            set = function(_, value)
                KG.db.scale = value
                KG.Bar.ApplyScale()
                KG.Library:ApplyScale() -- the Library follows the same slider (2026-07-21)
            end,
        },
        {
            kind = LEM.SettingType.Slider,
            name = "Background opacity",
            default = 1,
            minValue = 0,
            maxValue = 1,
            valueStep = 0.05,
            formatter = function(v) return string.format("%.0f%%", v * 100) end,
            get = function() return KG.db.bgAlpha == nil and 1 or KG.db.bgAlpha end,
            set = function(_, value)
                KG.db.bgAlpha = value
                KG.Bar:Refresh(); KG.Splits:Refresh()
            end,
        },
        -- "Walking bounce" and "Extra pace cars (+3/+2)" lived here until the
        -- 2026-07-28 sweep — they change how the race displays, not where
        -- anything sits, so they moved to the options panel with the hat.
        {
            -- "How many Ghost Racers to show" (Fredrik 2026-07-22). Edit Mode, not
            -- the Options panel: this is literally how many runners get drawn on
            -- the track, and the architecture rule gives Edit Mode what's drawn.
            -- The Roster Panel clamps at 4 rows and Style has exactly 4 pairing
            -- colors, so 4 is the honest ceiling. 0 = no fillers: just you and the
            -- ghost you're racing (which still gets its row).
            kind = LEM.SettingType.Slider,
            name = "Ghost Roster size",
            desc = "How many ghosts race you at once. Lower it to declutter the track; 0 leaves only the ghost you are racing. Hide individual ghosts in the Ghost Library instead.",
            default = 3,
            minValue = 0,
            maxValue = 4,
            valueStep = 1,
            formatter = function(v) return string.format("%d", v) end,
            get = function() return KG.db.rosterSize or 3 end,
            set = function(_, value)
                KG.db.rosterSize = value
                KG.Ghosts:InvalidateRoster()
                KG.Bar:Refresh(); KG.Splits:Refresh()
            end,
        },
        {
            -- Renamed from "Boss lap splits" (Fredrik 2026-07-28): the toggle
            -- always governed the WHOLE roster panel, not just the lap columns —
            -- the name now says what it shows. db key stays `splits` (saved
            -- choices carry over). Two sessions renamed this the same week; his
            -- 07-28 wording won, and the laps got a column checkbox of their own.
            kind = LEM.SettingType.Checkbox,
            name = "Display Ghost Roster",
            desc = "Show the Ghost Roster panel under the bar: every ghost racing you, with its live gap and per-boss laps.",
            default = true,
            get = function() return KG.db.splits ~= false end,
            set = function(_, value)
                KG.db.splits = value and true or false
                KG.Splits:Refresh()
            end,
        },
        -- Everything else lives in Options.lua — the Blizzard AddOns panel:
        -- the behavioral options (route-share toggles etc.) AND the
        -- how-to-display ones (bounce, pace cars, death markers, marker hat,
        -- palettes, % vs count). Edit Mode is SIZE & POSITION only
        -- (architecture rule, Fredrik 2026-07-20; sharpened + swept 2026-07-28),
        -- with the Ghost Roster's own controls as the standing exception — the
        -- sweep itself left the panel toggle and size slider here, so the column
        -- checkboxes appended below join them instead of moving house alone.
    }
    for _, s in ipairs(ColumnSettings()) do settings[#settings + 1] = s end
    LEM:AddFrameSettings(bar, settings)

    LEM:RegisterCallback("enter", function()
        KG.Bar.EndIntro() -- Edit Mode takes the stage from the first-login show
        KG.editModePreview = true
        KG.Bar:Refresh()
        KG.Splits:Refresh()
    end)

    LEM:RegisterCallback("exit", function()
        KG.editModePreview = false
        KG.Bar:Refresh()
        KG.Splits:Refresh()
    end)
end
