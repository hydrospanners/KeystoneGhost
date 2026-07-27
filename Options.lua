-- Blizzard AddOns options panel (ESC → Options → AddOns → Keystone Ghost).
--
-- Architecture rule (Fredrik 2026-07-20; sharpened 2026-07-28 when the marker
-- hat was misfiled in Edit Mode for an hour, then applied in the same-day
-- settings sweep): Edit Mode owns SIZE & POSITION — where frames sit, how big,
-- their chrome and footprint (dock, scale, opacity, roster rows, the splits
-- panel). HOW the race displays — readout language, palettes, whose deaths,
-- which pace cars, what your icon wears and how it moves — is an Options
-- matter and lives here, alongside everything BEHAVIORAL (sharing, data
-- handling, future setup). The sweep moved "Walking bounce" and "Extra pace
-- cars (+3/+2)" here accordingly. No minimap button: this panel plus /kg are
-- the entry points until the Data-view UI era.
--
-- Settings API shape verified against live 12.x users in this install
-- (ArchonTooltip/Settings.lua, BliZzi_Interrupts/UI/Config.lua):
-- RegisterVerticalLayoutCategory + RegisterProxySetting(category, variable,
-- VarType, name, default, get, set) + CreateCheckbox + RegisterAddOnCategory;
-- OpenToCategory takes category.ID.
local ADDON_NAME, NS = ...
local KG = NS.KG

local Options = {}
KG.Options = Options

local function AddCheckbox(category, variable, name, tooltip, default, get, set)
    local setting = Settings.RegisterProxySetting(category, variable,
        Settings.VarType.Boolean, name, default, get, set)
    Settings.CreateCheckbox(category, setting, tooltip)
end

-- Panel buttons via CreateSettingsButtonInitializer + the category layout (shape
-- verified against a live 12.x user in this install: BugSack/config.lua,
-- InitializeSettings). Guarded so a patch removing the API costs the buttons,
-- never the panel.
local function AddButton(category, name, buttonText, onClick, tooltip)
    if not (CreateSettingsButtonInitializer and SettingsPanel and SettingsPanel.GetLayout) then return end
    local ok, layout = pcall(SettingsPanel.GetLayout, SettingsPanel, category)
    if not ok or not layout or not layout.AddInitializer then return end
    layout:AddInitializer(CreateSettingsButtonInitializer(name, buttonText, onClick, tooltip, true))
end

-- Section header, same guarded layout door (the "Show pace cars" cluster).
-- Missing API = the checkboxes stand headerless; nothing else is lost.
local function AddHeader(category, name)
    if not (CreateSettingsListSectionHeaderInitializer and SettingsPanel and SettingsPanel.GetLayout) then return end
    local ok, layout = pcall(SettingsPanel.GetLayout, SettingsPanel, category)
    if not ok or not layout or not layout.AddInitializer then return end
    layout:AddInitializer(CreateSettingsListSectionHeaderInitializer(name))
end

function Options:Setup()
    if not (Settings and Settings.RegisterVerticalLayoutCategory
        and Settings.RegisterProxySetting and Settings.CreateCheckbox
        and Settings.RegisterAddOnCategory) then
        return -- no panel this patch: /kg commands still cover everything
    end

    local category = Settings.RegisterVerticalLayoutCategory("Keystone Ghost")
    self.category = category

    -- The Ghost Library door (approved design 2026-07-21): the panel's first row.
    AddButton(category, "Ghost Library", "Open Ghost Library",
        function() KG.Library:Toggle() end,
        "Browse, pin, share and delete every stored ghost — all your characters plus imports. Also on the minimap button and bare /kg.")

    -- The two route-share toggles (the wrong-route pitfall: what's captured is
    -- your SELECTED route at key start, which a DPS with a stale MDT selection
    -- may not want broadcast). Defaults both ON — confirmed by Fredrik
    -- 2026-07-20 (1.0 planning session).
    AddCheckbox(category, "KEYSTONEGHOST_SHARE_ROUTE_NAME",
        "Export: route name",
        "Ghost export strings carry the MDT route's name and creator. Off = anonymously-routed ghosts.",
        true,
        function() return KG.db.shareRouteName ~= false end,
        function(value) KG.db.shareRouteName = value and true or false end)

    AddCheckbox(category, "KEYSTONEGHOST_SHARE_ROUTE_DATA",
        "Export: route data",
        "Embed the actual MDT route (as it was when the run was recorded) so the receiver can load it into MDT with one click. About half a KB per string.",
        true,
        function() return KG.db.shareRouteData ~= false end,
        function(value) KG.db.shareRouteData = value and true or false end)

    -- Party names are OPT-IN (Fredrik 2026-07-20): default exports carry the
    -- party as anonymous spec/class/role/rating (shown as "RShaman", "Aug", …).
    AddCheckbox(category, "KEYSTONEGHOST_SHARE_PARTY_NAMES",
        "Export: party member names",
        "Ghost export strings name your party members next to their class, spec, role and M+ rating. Off = members stay anonymous (their spec and rating still travel, e.g. RShaman 3433).",
        false,
        function() return KG.db.sharePartyNames == true end,
        function(value) KG.db.sharePartyNames = value and true or false end)

    -- Color vision (Fredrik 2026-07-21): the verdict red/green pair swaps for
    -- the three most common color-vision deficiencies. Dropdown shape verified
    -- against a live 12.x user in this install (BugSack: CreateControlTextContainer
    -- + CreateDropdown over a proxy setting). The whole UI follows instantly —
    -- every verdict site reads Style.GREEN/RED by reference.
    if Settings.CreateDropdown and Settings.CreateControlTextContainer then
        local CV_ORDER = { "default", "protanopia", "deuteranopia", "tritanopia" }
        local CV_LABEL = {
            default = "Default (red / green)",
            protanopia = "Protanopia (red-weak): orange / blue",
            deuteranopia = "Deuteranopia (green-weak): orange / blue",
            tritanopia = "Tritanopia (blue-yellow): red / teal",
        }
        local function GetColorVisionOptions()
            local container = Settings.CreateControlTextContainer()
            for i, key in ipairs(CV_ORDER) do container:Add(i, CV_LABEL[key]) end
            return container:GetData()
        end
        local cvSetting = Settings.RegisterProxySetting(category, "KEYSTONEGHOST_COLOR_VISION",
            Settings.VarType.Number, "Color vision", 1,
            function()
                for i, key in ipairs(CV_ORDER) do
                    if key == (KG.db.colorVision or "default") then return i end
                end
                return 1
            end,
            function(value)
                KG.db.colorVision = CV_ORDER[value] or "default"
                KG.Style.ApplyColorVision(KG.db.colorVision)
                KG.Bar:Refresh()
                KG.Splits:Refresh()
            end)
        Settings.CreateDropdown(category, cvSetting, GetColorVisionOptions,
            "Swap the ahead/behind verdict colors for common color-vision deficiencies. Applies everywhere a red/green verdict shows — the Gap, the zone, roster deltas.")
    end

    -- Death markers (Fredrik 2026-07-22). Panel, not Edit Mode, by his call and
    -- the default rule (DESIGN "Settings architecture"): this picks WHOSE deaths
    -- are drawn — scope, not pixels. Same dropdown shape as Color vision above.
    -- Display-only: the ghosts' pace is untouched by it (their recorded clock
    -- already carries the death penalty), so a mid-run change just redraws.
    if Settings.CreateDropdown and Settings.CreateControlTextContainer then
        local DM_ORDER = { "none", "yours", "all" }
        local DM_LABEL = {
            none = "Off",
            yours = "Your deaths only",
            all = "Your deaths and the ghosts'",
        }
        local function GetDeathMarkerOptions()
            local container = Settings.CreateControlTextContainer()
            for i, key in ipairs(DM_ORDER) do container:Add(i, DM_LABEL[key]) end
            return container:GetData()
        end
        local dmSetting = Settings.RegisterProxySetting(category, "KEYSTONEGHOST_DEATH_MARKERS",
            Settings.VarType.Number, "Death markers", 3,
            function()
                for i, key in ipairs(DM_ORDER) do
                    if key == (KG.db.deathMarkers or "all") then return i end
                end
                return 3
            end,
            function(value)
                KG.db.deathMarkers = DM_ORDER[value] or "all"
                KG.Bar:Refresh()
            end)
        Settings.CreateDropdown(category, dmSetting, GetDeathMarkerOptions,
            "Tombstones on the track. Yours stand where you died and stay. A ghost's stand on its own lane ahead of it and disappear as it reaches them — that's where its run lost time to the death penalty.")
    end

    -- The marker hat (easter egg, Fredrik 2026-07-28). PANEL, not Edit Mode — it
    -- spent an hour there first; his correction sharpened the architecture rule in
    -- this file's header: this changes what your icon WEARS, not where anything
    -- sits. Death markers' exact shape: how-to-display belongs here.
    AddCheckbox(category, "KEYSTONEGHOST_MARKER_HAT",
        "Raid marker as a hat",
        "Your runner stays your portrait, and a raid target marker on you perches as a tiny hat above your head instead of replacing your face.",
        false,
        function() return KG.db.markerHat == true end,
        function(value)
            KG.db.markerHat = value and true or false
            KG.Bar.RefreshPlayerIcon(true) -- swap face/hat immediately, mid-run too
        end)

    -- Swept in from Edit Mode (2026-07-28, with the hat): both change how the
    -- race DISPLAYS, not where anything sits. The db keys and defaults are
    -- unchanged, so existing choices carry over untouched.
    AddCheckbox(category, "KEYSTONEGHOST_BOUNCE",
        "Walking bounce",
        "Your icon does a little walk-cycle hop while moving — and stands still while you fight a boss.",
        true,
        function() return KG.db.bounce ~= false end,
        function(value) KG.db.bounce = value and true or false end)

    -- One box per car (Fredrik 2026-07-28, superseding the single "+3/+2"
    -- toggle from earlier the same day): the +1 sweeper is hideable too — its
    -- hatched wake goes with it; the gap zone's depletion warning stays.
    AddHeader(category, "Show pace cars")
    local function PaceCarBox(key, name, tooltip)
        AddCheckbox(category, "KEYSTONEGHOST_" .. key:upper(), name, tooltip, true,
            function() return KG.db[key] ~= false end,
            function(value)
                KG.db[key] = value and true or false
                KG.Bar:Refresh()
            end)
    end
    PaceCarBox("paceCar1", "+1 sweeper",
        "The red sweeper drives at exactly the par time — if it passes you, the key depletes. Hiding it hides its hatched wake too; the gap zone still warns about depletion.")
    PaceCarBox("paceCar2", "+2 pace car", "Drives at exactly the +2 time. Stay ahead of it to keep the +2.")
    PaceCarBox("paceCar3", "+3 pace car", "Drives at exactly the +3 time. Stay ahead of it to keep the +3.")

    -- Forces readout (the count display toggle — Fredrik's own idea, 2026-07-20):
    -- checkbox ON = percent, the default (an on-by-default box asserts the norm);
    -- unticking switches every site to the raw count. Display-only — the race math
    -- is count-native either way.
    AddCheckbox(category, "KEYSTONEGHOST_PERCENT_DISPLAY",
        "Show % instead of count",
        "Show enemy forces as percent — gap +3.4%, tooltips 55.2%. Untick to read the raw count instead (gap +14, tooltips 228/413). The race itself is identical; this only changes how the numbers read.",
        true,
        function() return KG.db.percentDisplay ~= false end,
        function(value) KG.db.percentDisplay = value and true or false end)

    -- Share Tag reset (DESIGN "The Share Tag" escape hatch — panel home per the
    -- settings-architecture rule; /kg sharetag stays as the undocumented dev door).
    -- Behind a CONFIRM since 2026-07-28 (Fredrik: "are you really sure?" — the
    -- split in receivers' grouping is permanent), and the row NAMES your current
    -- tag: the label reads it at panel build, the popup reads it live at click.
    StaticPopupDialogs["KEYSTONEGHOST_RESET_SHARETAG"] = {
        text = "Keystone Ghost — really reset your Share Tag?|n|nCurrent tag: %s|n|nReceivers use this tag to group ghosts from you and your alts. After a reset, everything you share carries a NEW tag — friends' existing imports keep the old one, so your earlier and later shares stop clustering together, permanently. Sharing itself keeps working.",
        button1 = "Reset it",
        button2 = CANCEL,
        OnAccept = function()
            KG.db.shareTag = nil
            print("|cff88ccffKeystoneGhost|r: share tag reset — a fresh one mints on your next export.")
            KG.Library:RefreshIfShown()
        end,
        timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
    }
    AddButton(category,
        "Share Tag: " .. (KG.db.shareTag or "none yet — mints on your first export"),
        "Reset Share Tag…",
        function()
            if not KG.db.shareTag then
                print("|cff88ccffKeystoneGhost|r: no share tag yet — one mints on your first export.")
                return
            end
            StaticPopup_Show("KEYSTONEGHOST_RESET_SHARETAG", KG.db.shareTag)
        end,
        "Your Share Tag pseudonymously groups your and your alts' exports for receivers (also shown in the Ghost Library footer). Resetting asks for confirmation first — it permanently splits how receivers group your shares.")

    Settings.RegisterAddOnCategory(category)
end

--- Open the panel (/kg options). Returns false when the API is unavailable.
function Options:Open()
    if self.category and Settings and Settings.OpenToCategory then
        Settings.OpenToCategory(self.category.ID)
        return true
    end
    return false
end
