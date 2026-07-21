-- Blizzard Edit Mode integration via bundled LibEditMode (namespaced build — no LibStub).
--
-- The bar registers as an Edit Mode system: drag to reposition, click for a settings
-- dialog (Enabled, Dock under EllesmereUI timer, Scale, Background opacity, Walking
-- bounce, Extra pace cars +3/+2, Boss lap splits). While in Edit Mode
-- the bar previews the synthetic test race so there is something to see and place.
-- Dragging a docked bar is interpreted as "I want it free": the drop position is saved
-- and attach mode turns off; re-docking is one checkbox.
local ADDON_NAME, NS = ...
local KG = NS.KG

local EM = {}
KG.EditMode = EM

function EM:Setup()
    local LEM = NS.LibEditMode
    if not LEM or not LEM.AddFrame then return end

    local bar = KG.Bar.GetFrame()

    LEM:AddFrame(bar, function(frame)
        local point, _, relPoint, x, y = frame:GetPoint()
        KG.db.pos = { point = point, relPoint = relPoint, x = x, y = y }
        if KG.db.attach then
            KG.db.attach = nil -- a manual drag means the user wants it free-floating
            print("|cff88ccffKeystoneGhost|r: undocked from the EllesmereUI timer (dragged; re-dock in Edit Mode settings).")
        end
        KG.Bar:InvalidatePosition()
        KG.Bar:Refresh()
    end, { point = "CENTER", x = 0, y = 260 }, "Keystone Ghost")

    LEM:AddFrameSettings(bar, {
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
        {
            kind = LEM.SettingType.Checkbox,
            name = "Walking bounce",
            desc = "Your icon does a little walk-cycle hop while moving — and stands still while you fight a boss.",
            default = true,
            get = function() return KG.db.bounce ~= false end,
            set = function(_, value)
                KG.db.bounce = value and true or false
            end,
        },
        {
            kind = LEM.SettingType.Checkbox,
            name = "Extra pace cars (+3/+2)",
            desc = "Show the +3 and +2 pace cars on the road. The +1 sweeper (key-depletion pace) always runs.",
            default = true,
            get = function() return KG.db.chestTicks ~= false end,
            set = function(_, value)
                KG.db.chestTicks = value and true or false
                KG.Bar:Refresh()
            end,
        },
        {
            kind = LEM.SettingType.Checkbox,
            name = "Boss lap splits",
            desc = "Show per-boss lap deltas against every stored ghost below the bar.",
            default = true,
            get = function() return KG.db.splits ~= false end,
            set = function(_, value)
                KG.db.splits = value and true or false
                KG.Splits:Refresh()
            end,
        },
        -- Behavioral options (route-share toggles etc.) live in Options.lua —
        -- the Blizzard AddOns panel. Edit Mode is visual/layout ONLY
        -- (architecture rule, Fredrik 2026-07-20).
    })

    LEM:RegisterCallback("enter", function()
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
