-- Event wiring, ticker, and slash commands.
local ADDON_NAME, NS = ...
local KG = NS.KG

local function Print(msg) print("|cff88ccffKeystoneGhost|r: " .. msg) end

local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:RegisterEvent("PLAYER_LOGIN")
loader:SetScript("OnEvent", function(self, event, addonName)
    if event == "ADDON_LOADED" then
        if addonName ~= ADDON_NAME then return end
        KG.InitDB()
        self:UnregisterEvent("ADDON_LOADED")
    elseif event == "PLAYER_LOGIN" then
        self:UnregisterEvent("PLAYER_LOGIN")
        KG.Start()
        KG.EditMode:Setup()
    end
end)

function KG.Start()
    KG.Ghosts:RepairAll() -- one-time cleanup of pre-clock-fix recordings
    local ev = CreateFrame("Frame")
    ev:RegisterEvent("CHALLENGE_MODE_START")
    ev:RegisterEvent("CHALLENGE_MODE_COMPLETED")
    ev:RegisterEvent("CHALLENGE_MODE_RESET")
    ev:RegisterEvent("CHALLENGE_MODE_DEATH_COUNT_UPDATED")
    ev:RegisterEvent("PLAYER_ENTERING_WORLD")
    ev:RegisterUnitEvent("UNIT_PORTRAIT_UPDATE", "player")
    ev:RegisterEvent("ENCOUNTER_START")
    ev:RegisterEvent("ENCOUNTER_END")
    ev:SetScript("OnEvent", function(_, event, arg1, arg2, arg3, arg4, arg5)
        if event == "ENCOUNTER_START" then
            KG.Recorder:OnEncounter(event, arg1)
            return
        elseif event == "ENCOUNTER_END" then
            KG.Recorder:OnEncounter(event, arg1, arg5) -- arg5 = success
            return
        elseif event == "CHALLENGE_MODE_START" then
            KG.Recorder:OnKeyStart()
        elseif event == "CHALLENGE_MODE_COMPLETED" then
            KG.Recorder:OnKeyEnd()
        elseif event == "CHALLENGE_MODE_RESET" then
            KG.Recorder:Abort()
        elseif event == "CHALLENGE_MODE_DEATH_COUNT_UPDATED" then
            KG.Recorder:OnDeathCountUpdated()
        elseif event == "UNIT_PORTRAIT_UPDATE" then
            KG.Bar.RefreshPlayerIcon(true)
        elseif event == "PLAYER_ENTERING_WORLD" then
            KG.Bar.RefreshPlayerIcon(true)
            if KG.Recorder:IsActive() and not KG.Scenario:IsChallengeActive() then
                -- Left the instance with no active challenge: drop stale state.
                KG.Recorder:Abort()
            elseif not KG.Recorder:IsActive() and KG.Scenario:IsChallengeActive() then
                -- Logged/reloaded into a running key: rebuild the clock and keep racing.
                KG.Recorder:Resume()
            end
        end
        KG.Bar:Refresh()
        KG.Splits:Refresh()
    end)

    C_Timer.NewTicker(0.5, function()
        -- Self-healing resume: the world timer may not be readable yet at
        -- PLAYER_ENTERING_WORLD; keep trying while a challenge is active untracked.
        if not KG.Recorder:IsActive() and KG.Scenario:IsChallengeActive() then
            KG.Recorder:Resume()
        end
        KG.Recorder:OnTick()
        KG.Bar:Refresh()
        KG.Splits:Refresh()
    end)
end

StaticPopupDialogs["KEYSTONEGHOST_EXPORT"] = {
    text = "Keystone Ghost — copy the export string:",
    button1 = CLOSE,
    hasEditBox = true,
    editBoxWidth = 280,
    OnShow = function(self, data)
        local eb = self.editBox or self.EditBox
        if eb then
            eb:SetMaxLetters(0)
            eb:SetText(data or "")
            eb:HighlightText()
            eb:SetFocus()
        end
    end,
    EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

StaticPopupDialogs["KEYSTONEGHOST_IMPORT"] = {
    text = "Keystone Ghost — paste an export string:",
    button1 = ACCEPT,
    button2 = CANCEL,
    hasEditBox = true,
    editBoxWidth = 280,
    OnShow = function(self)
        local eb = self.editBox or self.EditBox
        if eb then eb:SetMaxLetters(0); eb:SetFocus() end
    end,
    OnAccept = function(self)
        local eb = self.editBox or self.EditBox
        local run, err = KG.Ghosts:ImportString(eb and eb:GetText() or "")
        if run then
            print(string.format("|cff88ccffKeystoneGhost|r: imported %s's %s +%d ghost (%s)%s — racing it next key.",
                run.importedFrom, KG.Math.TierLabel(run.chests), run.level,
                KG.Math.FormatClock(run.durationSec),
                run.routeName and (" · route: " .. run.routeName) or ""))
        else
            print("|cff88ccffKeystoneGhost|r: import failed — " .. (err or "unknown error"))
        end
    end,
    EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

SLASH_KEYSTONEGHOST1 = "/keystoneghost"
SLASH_KEYSTONEGHOST2 = "/kg"
SlashCmdList.KEYSTONEGHOST = function(input)
    local cmd, arg = (input or ""):lower():match("^%s*(%S*)%s*(%S*)")
    if cmd == "toggle" or cmd == "hide" or cmd == "show" then
        if cmd == "toggle" then
            KG.db.enabled = KG.db.enabled == false
        else
            KG.db.enabled = (cmd == "show")
        end
        -- The window toggle NEVER stops recording (Fredrik: "never stop recording") —
        -- runs keep being captured as future ghosts; only the display hides.
        Print(KG.db.enabled and "shown." or "hidden (recording continues).")
        KG.Bar:Refresh()
        KG.Splits:Refresh()
    elseif cmd == "test" then
        KG.testMode = not KG.testMode
        Print("test mode " .. (KG.testMode and "ON — demo race at 10x speed (uses your real ghosts when available)." or "off."))
        KG.Bar:Refresh()
    elseif cmd == "list" then
        local lines = KG.Ghosts:DescribeAll()
        if #lines == 0 then
            Print("no ghosts stored for this character yet.")
        else
            Print("stored ghosts:")
            for _, l in ipairs(lines) do print("   " .. l) end
        end
    elseif cmd == "export" then
        local mapID = KG.Scenario:GetChallengeMapID()
        local level = tonumber(arg) or KG.Scenario:GetActiveKeyLevel()
        if not mapID and KG.db.lastRecorded then
            mapID = KG.db.lastRecorded.mapID
            level = tonumber(arg) or KG.db.lastRecorded.level
        end
        if not mapID or not level then
            Print("nothing to export — be in a key, or finish a run first (/kg export [level]).")
        else
            local str, err = KG.Ghosts:ExportString(mapID, level)
            if str then
                StaticPopup_Show("KEYSTONEGHOST_EXPORT", nil, nil, str)
            else
                Print("export failed — " .. (err or "unknown error"))
            end
        end
    elseif cmd == "import" then
        StaticPopup_Show("KEYSTONEGHOST_IMPORT")
    elseif cmd == "attach" then
        KG.db.attach = KG.db.attach and nil or "ellesmere"
        Print(KG.db.attach
            and "docking below the EllesmereUI M+ timer (when its frame exists)."
            or "detached — bar is free-floating and draggable.")
        KG.Bar:Refresh()
        KG.Splits:Refresh()
    elseif cmd == "splits" then
        KG.db.splits = KG.db.splits == false
        Print("boss lap splits " .. (KG.db.splits and "shown." or "hidden."))
        KG.Splits:Refresh()
    elseif cmd == "resetpos" then
        KG.Bar:ResetPosition()
        Print("bar position reset. (Reposition via the game's Edit Mode.)")
    else
        Print("commands:")
        print("   /kg hide, /kg show, /kg toggle — window visibility (recording never stops)")
        print("   /kg test — demo race preview (works anywhere)")
        print("   /kg list — stored ghosts for this character")
        print("   /kg export [level] — share your best ghost as a copy/paste string")
        print("   /kg import — paste someone's ghost and race it")
        print("   /kg attach — dock below / detach from the EllesmereUI M+ timer")
        print("   /kg splits — show/hide the boss lap rows")
        print("   /kg resetpos — reset bar position")
    end
end
