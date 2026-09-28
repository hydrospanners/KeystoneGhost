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
        -- Verdict palette before first draw, and the ONLY time it is read (his
        -- 2026-08-02 lock). InitDB has already resolved it to a string — including the
        -- one-time seed from the game's colorblindMode toggle — so this is a plain read.
        KG.Style.ApplyColorVision(KG.db.colorVision)
        KG.Start()
        KG.EditMode:Setup()
        KG.Options:Setup()
        KG.Options.NoticeSeededPalette() -- only speaks on a fresh colorblind-mode install
        KG.Library:Setup() -- the minimap button (the window itself builds lazily)
        KG.Comm:Setup() -- chat-share pipe: prefix, chat filters, link clicks
        -- First-login placement (Developer 2026-07-28): a fresh install's bar was
        -- invisible until its first key — and his field report says Edit Mode
        -- didn't pick the frame up until the bar had drawn once. So logins stage
        -- the demo loops with a MOVE ME handle above the bar (Bar.lua:
        -- EnsureMoveMe / Bar.EndIntro) until the bar HAS BEEN PLACED — a drag
        -- (handle or Edit Mode) or the handle's close stamps db.placed, and one
        -- placement covers every character (position and DB are account-wide).
        -- A key/Edit Mode//kg test only dismisses for the session — unplaced is
        -- unplaced, the offer returns next login. Pre-0.12 installs are
        -- grandfathered as placed in InitDB via schemaVersion.
        if not KG.db.placed then
            KG.introMode = true
            KG.Bar:Refresh()
            KG.Splits:Refresh()
        end
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
    ev:RegisterEvent("SCENARIO_CRITERIA_UPDATE") -- change-driven recording: the count moved
    ev:RegisterEvent("SCENARIO_POI_UPDATE") -- companion scenario signal, same capture
    ev:RegisterEvent("INSPECT_READY") -- party spec backfill after a saved run
    ev:SetScript("OnEvent", function(_, event, arg1, arg2, arg3, arg4, arg5)
        if event == "SCENARIO_CRITERIA_UPDATE" or event == "SCENARIO_POI_UPDATE" then
            -- The event's frame is the node's timestamp. No redraw here: these
            -- burst during AoE, and the bar's own 10 Hz OnUpdate carries display.
            KG.Recorder:OnScenarioUpdate()
            return
        elseif event == "INSPECT_READY" then
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
            -- Cache-on-sight (first-class replay, 2026-07-21): RaiderIO's provider
            -- fills during STAGING — just walking into the dungeon banks the
            -- converted ghost for the Library. Their PEW-adjacent handler may run
            -- after ours, hence the one delayed retry. Self-gating outside keys.
            KG.Ghosts:CacheRioOnSight()
            C_Timer.After(5, function() KG.Ghosts:CacheRioOnSight() end)
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

-- The copy doors all go through KG.Copy now (Copy.lua, 2026-07-26) — the
-- StaticPopup copy dialog that used to live here was a single-line 280 px
-- editbox, which the ~24 kB library URL made untenable. Ctrl+C still prints and
-- closes; "Close on copy" is now a checkbox in that window.
KG.CopyPrompts = {
    EXPORT = { "Copy this ghost's export string:", "export copied." },
    LINK = { "Copy the raider.io run link:", "link copied." },
    LIBRARY = { "Paste this in your browser to open your library online:", "library link copied." },
    -- The one-way door (2026-08-19). The prompt states the whole contract —
    -- close commits, ESC backs out — because this is the only warning there
    -- is; there is no confirm dialog behind it. No copied-message: the window
    -- says it, chat does not need to say it again. The portal refuses
    -- retired-season runs (his 2026-08-21 call: current season only, an
    -- archive is a Season 3 idea), so the prompt must never send people to a
    -- browser to "keep" these — the saved link IS the backup.
    LIBRARYCLEAR = { "If you want to store the library, save this link somewhere. Closing this window then deletes last season's ghosts — ESC if not yet:" },
    MDTROUTE = { "Copy this, then paste it in MDT under Import Preset:", "route string copied. Paste it in MDT under Import Preset." },
    DIAG = { "Copy this and paste it to whoever asked for it. It lists your settings, your stored ghosts and the last 40 key starts and ends:", "diagnostics copied." },
}

--- Open the copy window for one of the CopyPrompts kinds. `onCommit` runs once
--- if the window is closed on purpose (Ctrl+C or ×), `onCancel` if ESC backs
--- out of it. Both optional; see Copy:Show.
function KG.ShowCopy(kind, text, onCommit, onCancel)
    local p = KG.CopyPrompts[kind] or KG.CopyPrompts.EXPORT
    KG.Copy:Show(p[1], text, p[2], onCommit, onCancel)
end

StaticPopupDialogs["KEYSTONEGHOST_IMPORT"] = {
    text = "Keystone Ghost: paste an export string",
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
                routeNote = (" · route \"%s\" included. The route cell in the Ghost Library hands it to MDT")
                    :format(KG.Ghosts:RouteForHash(run.routeHash).name or "?")
            elseif run.routeName then
                routeNote = " · route: " .. run.routeName
            end
            print(string.format("|cff88ccffKeystoneGhost|r: imported %s's %s +%d ghost (%s)%s. Racing it next key.",
                run.importedFrom, KG.Math.TierLabel(run.chests), run.level,
                KG.Math.FormatClock(run.durationSec), routeNote))
            KG.Library:RefreshIfShown() -- the new row (auto-pinned) appears in place
            if newerVersion then
                print(string.format("|cff88ccffKeystoneGhost|r: that string was made with v%s and you run v%s. Update if the import looks off.",
                    newerVersion, KG.VERSION))
            end
        else
            print("|cff88ccffKeystoneGhost|r: import failed: " .. (err or "unknown error"))
        end
    end,
    EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

--- Hand an embedded route to MDT (the Library route cell — the last standing
--- door): the route becomes an MDT IMPORT STRING in the copy window —
--- MDT's own "Import Preset" dialog reads it, and the paste is the consent.
--- The string needs nothing from MDT to build (native client encoding), so it
--- works even with MDT missing entirely — the receiver can install MDT later
--- or forward the string; the prompt says what to do with it. (The one-click
--- import for pre-6.2 MDT was removed 2026-08-18 — latest-only policy.)
function KG.RequestRouteLoad(rd)
    if not rd then return end
    local str, err = KG.Route.BuildMDTImportString(rd)
    if str then
        KG.ShowCopy("MDTROUTE", str)
    else
        Print("route export failed: " .. (err or "unknown error"))
    end
end

SLASH_KEYSTONEGHOST1 = "/keystoneghost"
SLASH_KEYSTONEGHOST2 = "/kg"
SlashCmdList.KEYSTONEGHOST = function(input)
    local cmd, arg = (input or ""):lower():match("^%s*(%S*)%s*(%S*)")
    if cmd == "" then
        -- Bare /kg opens the Ghost Library (Developer's Q1 yes, 2026-07-21 — the MDT
        -- paradigm at the entry level). The command list moved to /kg help.
        KG.Library:Toggle()
    elseif cmd == "test" then
        KG.Bar.EndIntro() -- the deliberate demo outranks the first-login show
        KG.testMode = not KG.testMode
        if KG.testMode then KG.Bar.ResetTestLoop() end -- loop 1, fresh DB scan
        Print("test mode " .. (KG.testMode
            and "ON. Demo run at 15x speed, alternating loops: full roster, then Raider.IO ghost only (the first-run look)."
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
    elseif cmd == "online" or cmd == "library" then
        -- The portal door (DESIGN "Library export → the portal"). The Ghost
        -- Library's own button is the discoverable one; this is the typist's.
        local url, err, n = KG.Ghosts:ExportLibraryURL()
        if url then
            KG.ShowCopy("LIBRARY", url)
            Print(string.format("%d ghost%s in the link. Paste it in your browser.", n, n == 1 and "" or "s"))
        else
            Print(err or "nothing to open online yet.")
        end
    elseif cmd == "options" or cmd == "config" then
        if not KG.Options:Open() then
            Print("options panel unavailable: Settings API not found.")
        end
    elseif cmd == "diag" then
        -- The support door (2026-09-08, Diag.lua): dev-tier like sharetag; the
        -- Options panel's Support button is the discoverable one.
        if arg == "clear" then
            KG.Diag:Clear()
            Print("race log cleared.")
        else
            KG.ShowCopy("DIAG", KG.Diag:Dump())
        end
    elseif cmd == "sharetag" then
        -- Undocumented (dev-tier until the sharing UI's reset action lands in the
        -- Options panel — DESIGN "The Share Tag"). Reset is forward-only: receivers
        -- keep old imports grouped under the old tag.
        if arg == "reset" then
            KG.db.shareTag = nil
            Print("share tag reset. A fresh one mints on your next export.")
        else
            Print("share tag: " .. (KG.db.shareTag or "none yet (mints on your first export)")
                .. ". Reset: /kg sharetag reset")
        end
    else
        -- Slash cleanup finale (2026-09-04, one release after 1.0 as promised
        -- when the trio left the help): export/import/route are DELETED — the
        -- Ghost Library covers all three (per-row share, Import button,
        -- route-cell click) plus the chat share. test, list, sharetag still
        -- work undocumented (dev tier). hide/show/toggle died 2026-08-24 with
        -- per-character hiding (the Library eye is the door).
        Print("commands:")
        print("   /kg - the Ghost Library: browse, pin, share, delete your stored ghosts")
        print("   /kg options - addon options (display + behavior; size & position live in Edit Mode)")
    end
end
