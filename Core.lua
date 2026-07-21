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
        KG.Style.ApplyColorVision(KG.db.colorVision) -- verdict palette before first draw
        KG.Start()
        KG.EditMode:Setup()
        KG.Options:Setup()
        KG.Library:Setup() -- the minimap button (the window itself builds lazily)
        KG.Comm:Setup() -- chat-share pipe: prefix, chat filters, link clicks
    end
end)

function KG.Start()
    KG.Ghosts:MigrateDB() -- numbered schema migrations (v3 dropped pct-era runs)
    KG.Ghosts:SweepRoutes() -- drop Route Store entries orphaned since last session
    -- Prime the M+ season/affix data so GetCurrentSeason answers by key time
    -- (it returns -1 until the server responds — a documented field trap).
    if C_MythicPlus and C_MythicPlus.RequestMapInfo then pcall(C_MythicPlus.RequestMapInfo) end
    local ev = CreateFrame("Frame")
    ev:RegisterEvent("CHALLENGE_MODE_START")
    ev:RegisterEvent("CHALLENGE_MODE_COMPLETED")
    ev:RegisterEvent("CHALLENGE_MODE_RESET")
    ev:RegisterEvent("CHALLENGE_MODE_DEATH_COUNT_UPDATED")
    ev:RegisterEvent("PLAYER_ENTERING_WORLD")
    ev:RegisterUnitEvent("UNIT_PORTRAIT_UPDATE", "player")
    ev:RegisterEvent("ENCOUNTER_START")
    ev:RegisterEvent("ENCOUNTER_END")
    ev:RegisterEvent("INSPECT_READY") -- party spec backfill after a saved run
    ev:SetScript("OnEvent", function(_, event, arg1, arg2, arg3, arg4, arg5)
        if event == "INSPECT_READY" then
            KG.Recorder:OnInspectReady(arg1)
            return
        elseif event == "ENCOUNTER_START" then
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
            -- Self-close on copy (Fredrik 2026-07-20; the MDT pattern — their
            -- export editbox does exactly this on Ctrl+C keyup). The editbox is
            -- a SHARED StaticPopup frame: OnHide below clears the script so the
            -- import popup never inherits it.
            eb:SetScript("OnKeyUp", function(_, key)
                if key == "C" and IsControlKeyDown() then
                    Print("export copied.")
                    self:Hide()
                end
            end)
        end
    end,
    OnHide = function(self)
        local eb = self.editBox or self.EditBox
        if eb then eb:SetScript("OnKeyUp", nil) end
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
        local run, err, newerVersion = KG.Ghosts:ImportString(eb and eb:GetText() or "")
        if run then
            local routeNote = ""
            if run.routeHash and KG.Ghosts:RouteForHash(run.routeHash) then
                routeNote = (" · route \"%s\" included — /kg route (or click the ghost's badge) loads it into MDT")
                    :format(KG.Ghosts:RouteForHash(run.routeHash).name or "?")
            elseif run.routeName then
                routeNote = " · route: " .. run.routeName
            end
            print(string.format("|cff88ccffKeystoneGhost|r: imported %s's %s +%d ghost (%s)%s — racing it next key.",
                run.importedFrom, KG.Math.TierLabel(run.chests), run.level,
                KG.Math.FormatClock(run.durationSec), routeNote))
            KG.Library:RefreshIfShown() -- the new row (auto-pinned) appears in place
            if newerVersion then
                print(string.format("|cff88ccffKeystoneGhost|r: that string was made with v%s — you run v%s. Update if the import looks off.",
                    newerVersion, KG.VERSION))
            end
        else
            print("|cff88ccffKeystoneGhost|r: import failed — " .. (err or "unknown error"))
        end
    end,
    EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

StaticPopupDialogs["KEYSTONEGHOST_LOADROUTE"] = {
    text = "Keystone Ghost — load %s into MDT?",
    button1 = ACCEPT,
    button2 = CANCEL,
    OnAccept = function(self, data)
        local ok, err = KG.Route:LoadIntoMDT(data)
        if ok then
            Print("route handed to MDT.")
        else
            Print("route load failed — " .. (err or "unknown error"))
        end
    end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

--- Confirm-then-load for an embedded route (ghost badge click / "/kg route").
function KG.RequestRouteLoad(rd)
    if not rd then return end
    if not _G.MDT then
        Print("MDT is not loaded — the embedded route needs it.")
        return
    end
    local label = (rd.name or "route")
        .. (rd.createdBy and rd.createdBy.name and (" (by " .. rd.createdBy.name .. ")") or "")
    StaticPopup_Show("KEYSTONEGHOST_LOADROUTE", '"' .. label .. '"', nil, rd)
end

SLASH_KEYSTONEGHOST1 = "/keystoneghost"
SLASH_KEYSTONEGHOST2 = "/kg"
SlashCmdList.KEYSTONEGHOST = function(input)
    local cmd, arg = (input or ""):lower():match("^%s*(%S*)%s*(%S*)")
    if cmd == "" then
        -- Bare /kg opens the Ghost Library (Fredrik's Q1 yes, 2026-07-21 — the MDT
        -- paradigm at the entry level). The command list moved to /kg help.
        KG.Library:Toggle()
    elseif cmd == "toggle" or cmd == "hide" or cmd == "show" then
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
        if KG.testMode then KG.Bar.ResetTestLoop() end -- loop 1, fresh DB scan
        Print("test mode " .. (KG.testMode
            and "ON — demo race at 10x speed, alternating loops: full roster (your real ghosts when stored) ↔ RaiderIO replay only (the first-run look)."
            or "off."))
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
    elseif cmd == "options" or cmd == "config" then
        if not KG.Options:Open() then
            Print("options panel unavailable — Settings API not found.")
        end
    elseif cmd == "route" then
        -- The raced ghost's embedded route first (live race or Finish Photo), else
        -- the most recent import's — the receiver wants it BEFORE the key starts.
        local st = KG.Bar.GetLiveState()
        local ref = (st and st.ref) or (KG.Recorder.summary and KG.Recorder.summary.ref)
        local rd = ref and ref.run and ref.run.routeHash
            and KG.Ghosts:RouteForHash(ref.run.routeHash) or KG.Ghosts:LastImportedRoute()
        if rd then
            KG.RequestRouteLoad(rd)
        else
            Print("no embedded route found — race or import a ghost that carries one.")
        end
    elseif cmd == "sharetag" then
        -- Undocumented (dev-tier until the sharing UI's reset action lands in the
        -- Options panel — DESIGN "The Share Tag"). Reset is forward-only: receivers
        -- keep old imports grouped under the old tag.
        if arg == "reset" then
            KG.db.shareTag = nil
            Print("share tag reset — a fresh one mints on your next export.")
        else
            Print("share tag: " .. (KG.db.shareTag or "none yet (mints on your first export)")
                .. ". Reset: /kg sharetag reset")
        end
    else
        -- Prune wave 2 EXECUTED (2026-07-21, 3b close — wave 1 was 2026-07-20):
        -- the sharing trio (export/import/route) left the help — the Ghost
        -- Library covers all three (per-row share, Import button, route-cell
        -- click) plus the chat share. The commands KEEP WORKING undocumented
        -- for one release, then die. hide/show/toggle, test, list, sharetag
        -- also work undocumented (dev tier; hide/show/toggle keep-or-cut is
        -- Fredrik's call — TASKS #6).
        Print("commands:")
        print("   /kg — the Ghost Library: browse, pin, share, delete your stored ghosts")
        print("   /kg options — addon options (behavior; looks & layout live in Edit Mode)")
    end
end
