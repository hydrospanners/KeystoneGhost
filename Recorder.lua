-- Live-run recorder: samples { t, pct, bosses } every SNAPSHOT_INTERVAL during an active
-- key, timestamps boss kills the moment the boss criterion flips, records the death
-- timeline, and saves the run into the tier-slot DB on completion. Also owns the live
-- state the bar reads.
--
-- Clock: elapsed = GetTime() - startTime, with startTime continuously re-anchored to the
-- OFFICIAL keystone timer (GetWorldElapsedTime): it starts after the countdown and jumps
-- forward on deaths, so death penalties cost bar position directly — for you and, since
-- recordings share this clock, for the ghost alike. GetTime smooths between the timer's
-- whole-second updates.
--
-- /reload recovery: Resume() rebuilds the clock anchor from the world keystone timer and
-- re-picks the reference, so racing continues. The recording is marked `partial` (the
-- early timeline is missing) and is never saved as a ghost; pre-reload boss kills are
-- seeded at the resume timestamp — their lap deltas are meaningless and marked so.
local ADDON_NAME, NS = ...
local KG = NS.KG
local S = KG.Scenario

local R = {}
KG.Recorder = R

local SNAPSHOT_INTERVAL = 2
local MIN_SNAPSHOTS = 3

local rec = { active = false }
R.currentRef = nil

function R:IsActive() return rec.active end

function R:GetElapsed()
    if not rec.startTime then return nil end
    if rec.awaitingTimer then return 0 end -- countdown: parked at the start line
    return GetTime() - rec.startTime
end

--- Live progress for the bar: forces%, boss kill count.
function R:GetProgress()
    if not rec.active then return nil end
    return rec.lastPct or 0, rec.bossKills and #rec.bossKills or 0
end

function R:GetParTime() return rec.parTimeSec end

function R:GetBossKills() return rec.bossKills end

--- Live boss metadata parallel to GetBossKills(): names, forces% at each kill, and
--- encounterIDs (sparse — a kill whose ENCOUNTER_START was missed has no ID).
--- seededKills = number of leading entries whose timestamps are resume-seeded (post-
--- /reload) and therefore not real lap times.
function R:GetBossMeta() return rec.bossNames, rec.bossPcts, rec.seededKills or 0, rec.bossIDs end

--- Raw forces + scenario total from the last tick (route pull inference).
function R:GetRawForces() return rec.lastRaw or 0, rec.lastTotal or 0 end

--- Route context ({ cum, bossPull, nPulls, name }) when MDT has a matching preset selected.
function R:GetRoute() return rec.route end

--- Tracked current pull (APL model) — nil without a route.
function R:GetTrackerPull() return KG.PullTrack:GetCurrentPull() end

function R:GetDeaths() return rec.deaths end

function R:GetDeathCountLive() return rec.deathCount or 0, rec.deathTimeLost end

--- The in-progress run as a run-shaped table (for inverting YOUR timeline when racing a
--- live ghost that you are ahead of — see GhostMath.LiveDelta).
function R:GetLiveRun()
    return { snapshots = rec.snapshots, bossKills = rec.bossKills }
end

function R:GetContext() return rec.mapID, rec.level end

function R:OnKeyStart()
    R.summary = nil -- a new race replaces the last verdict
    rec.active = true
    rec.startTime = GetTime()
    -- CHALLENGE_MODE_START fires when the COUNTDOWN begins; the race must not until
    -- the official keystone timer starts ticking (OnTick anchors and clears this).
    rec.awaitingTimer = true
    rec.mapID = S:GetChallengeMapID()
    rec.level = S:GetActiveKeyLevel()
    rec.parTimeSec = rec.mapID and S:GetParTimeSec(rec.mapID) or nil
    rec.snapshots = { { 0, 0, 0 } }
    rec.bossKills = {}
    rec.bossNames = {}
    rec.bossPcts = {}
    rec.bossDone = {}
    rec.deaths = {}
    rec.lastSnap = rec.startTime
    rec.lastPct = 0
    rec.lastRaw, rec.lastTotal = 0, 0
    rec.deathCount = 0
    rec.partial = nil
    rec.seededKills = 0

    -- Optional MDT context: route name (export metadata) + cumulative pull forces (the
    -- "pull N · ghost M" indicator). Both nil without MDT / non-matching preset.
    rec.route = KG.Route:GetForChallengeMap(rec.mapID)
    rec.routeName = rec.route and rec.route.name or nil
    KG.PullTrack:Reset(rec.route)

    R.currentRef = rec.mapID and KG.Ghosts:BuildReference(rec.mapID, rec.level) or nil
end

--- Resume racing after a /reload mid-key. The world keystone timer gives true elapsed;
--- current forces/bosses seed the state so the delta math has a floor to stand on.
function R:Resume()
    if rec.active then return end
    if not S:IsChallengeActive() then return end
    local elapsed = S:GetWorldElapsedSec()
    if not elapsed or elapsed < 1 then return end

    R:OnKeyStart()
    rec.startTime = GetTime() - elapsed
    rec.awaitingTimer = nil -- resumed mid-run: the timer is provably running
    rec.partial = true
    rec.lastPct = S:GetForcesPercent()
    rec.lastRaw, rec.lastTotal = S:ReadEnemyForcesRaw()
    -- Both returns: seeding timeLost too keeps the knockback baseline honest — else
    -- the first post-reload death would knock back the run's WHOLE accumulated penalty.
    rec.deathCount, rec.deathTimeLost = S:GetDeathCount()
    rec.deathCount = rec.deathCount or 0

    -- Bosses killed before the reload: count is knowable, kill times are not. Seed their
    -- timestamps at the resume moment and remember how many are fake for the lap UI.
    for i, cs in ipairs(S:GetBossCriteriaStates()) do
        if cs.done then
            rec.bossDone[i] = true
            local k = #rec.bossKills + 1
            rec.bossKills[k] = elapsed
            rec.bossNames[k] = cs.name
        end
    end
    rec.seededKills = #rec.bossKills

    rec.snapshots = { { elapsed, rec.lastPct, #rec.bossKills } }
    print(string.format("|cff88ccffKeystoneGhost|r: resumed racing after reload at %s (this run won't be saved as a ghost).",
        KG.Math.FormatClock(elapsed)))
end

function R:Abort()
    rec = { active = false }
    R.currentRef = nil
    KG.PullTrack:Reset(nil)
end

--- ENCOUNTER_START/END: boss ENGAGE times and stable encounter IDs — the identity
--- layer (recorded since 2026-07-19; matching UI is a future design pass, see DESIGN
--- "the boss identity problem"). A failed encounter clears the pending engage.
function R:OnEncounter(event, encounterID, success)
    if not rec.active then return end
    local elapsed = R:GetElapsed()
    if not elapsed then return end
    if event == "ENCOUNTER_START" then
        rec.pendingEngage = { t = elapsed, id = tonumber(encounterID) }
    elseif event == "ENCOUNTER_END" and success ~= 1 then
        rec.pendingEngage = nil -- wipe: they'll re-pull
    end
end

function R:OnDeathCountUpdated()
    if not rec.active then return end
    local n, timeLost = S:GetDeathCount()
    if not n then return end
    if n > (rec.deathCount or 0) then
        local elapsed = R:GetElapsed()
        if elapsed then rec.deaths[#rec.deaths + 1] = { elapsed, n } end
    end
    rec.deathCount = n
    rec.deathTimeLost = timeLost
end

function R:OnTick()
    if not rec.active or not rec.startTime then return end
    if not S:IsChallengeActive() then return end
    local now = GetTime()

    -- Hold at the start line until the official timer exists (countdown running).
    if rec.awaitingTimer then
        local official = S:GetWorldElapsedSec()
        if official then
            rec.startTime = now - official
            rec.awaitingTimer = nil
        elseif now - rec.startTime > 20 then
            rec.startTime = now -- failsafe: never wait forever if the API goes missing
            rec.awaitingTimer = nil
        else
            return
        end
    end

    -- Glue our clock to the OFFICIAL keystone timer. The world timer starts after the
    -- pre-key countdown and jumps forward on deaths (the death penalty is baked into
    -- it), so re-anchoring on drift makes a death physically cost bar position — for
    -- you and, since recordings share this clock, for the ghost alike. GetTime keeps
    -- the cursor smooth between whole-second timer updates.
    local official = S:GetWorldElapsedSec()
    if official then
        local drift = (now - rec.startTime) - official
        if drift > 1.5 or drift < -1.5 then
            rec.startTime = now - official
        end
    end

    local t = now - rec.startTime
    local raw, total = S:ReadEnemyForcesRaw()
    local pct = (total > 0) and (raw / total) * 100 or 0
    -- Forces never decrease in a key: a sudden drop means the scenario is collapsing
    -- (completion teardown fires a beat before CHALLENGE_MODE_COMPLETED) or a secret
    -- flicker — keep the last good reading instead of recording garbage.
    if pct + 1 < (rec.lastPct or 0) then
        raw, total, pct = rec.lastRaw, rec.lastTotal, rec.lastPct
    end
    rec.lastRaw, rec.lastTotal, rec.lastPct = raw, total, pct

    -- Boss kills are timestamped every tick (not every snapshot) for sharp split times.
    -- Diffing per-criterion done flags (not just the count) captures which boss it was,
    -- so the kill order carries the right name and forces% even on off-order routes.
    for i, cs in ipairs(S:GetBossCriteriaStates()) do
        if cs.done and not rec.bossDone[i] then
            rec.bossDone[i] = true
            local k = #rec.bossKills + 1
            rec.bossKills[k] = t
            rec.bossNames[k] = cs.name
            rec.bossPcts[k] = rec.lastPct
            -- Attach the pending engage: identity + pull time for this kill.
            if rec.pendingEngage then
                rec.bossIDs = rec.bossIDs or {}
                rec.bossEngages = rec.bossEngages or {}
                rec.bossIDs[k] = rec.pendingEngage.id
                rec.bossEngages[k] = rec.pendingEngage.t
                rec.pendingEngage = nil
            end
        end
    end

    KG.PullTrack:Update(rec.lastRaw, #rec.bossKills, t)

    if now - rec.lastSnap >= SNAPSHOT_INTERVAL then
        rec.lastSnap = now
        rec.snapshots[#rec.snapshots + 1] = { t, rec.lastPct, #rec.bossKills }
    end

    -- Live RaiderIO replay ghost: mirror its progress; and if the key started with a
    -- linear fallback because the replay wasn't ready yet, upgrade within the first
    -- minute (RaiderIO initializes its replay after CHALLENGE_MODE_START).
    local ref = R.currentRef
    if ref and ref.live then
        KG.Ghosts:UpdateRioMirror(ref, t)
    elseif t < 60 and ref and (ref.kind == "season" or ref.kind == "par") then
        local rio = KG.Ghosts:BuildRioReference()
        if rio then R.currentRef = rio end
    end
end

function R:OnKeyEnd()
    local saved = rec
    local ref = R.currentRef
    rec = { active = false }
    R.currentRef = nil
    if not saved.snapshots or #saved.snapshots < MIN_SNAPSHOTS or not saved.mapID or not saved.startTime then
        return
    end

    local done = S:GetCompletion()
    if done and done.practiceRun then return end
    local durationSec = (done and done.timeSec) or (GetTime() - saved.startTime)
    local level = (done and done.level) or saved.level or 0
    local chests = done and done.chests
    if chests == nil then
        chests = KG.Math.TierForDuration(durationSec, saved.parTimeSec) or 0
    end

    -- Post-run verdict vs the raced ghost (its full duration is known for every kind).
    -- Shown in the bar window (Bar:ShowSummary) and echoed to chat.
    local diff = ref and ref.durationSec and (ref.durationSec - durationSec) or nil
    R.summary = {
        label = ref and ref.label or nil,
        diff = diff,
        finalTime = durationSec,
        chests = chests,
        at = GetTime(),
        ref = ref, -- Bar:ShowSummary draws the finish photo from this
    }
    if diff then
        local msg
        if diff >= 0 then
            msg = string.format("beat |cffffffff%s|r by |cff4dcc4d%s|r", ref.label or "the ghost", KG.Math.FormatClock(diff))
        else
            msg = string.format("finished |cffe65959%s|r behind |cffffffff%s|r", KG.Math.FormatClock(-diff), ref.label or "the ghost")
        end
        print("|cff88ccffKeystoneGhost|r: " .. msg .. ".")
    end

    if saved.partial then return end -- resumed after /reload: timeline incomplete, never save

    local nBosses = #saved.bossKills
    saved.snapshots[#saved.snapshots + 1] = { durationSec, 100, nBosses }

    local stored = KG.Ghosts:Save({
        clockV = 2, -- official-timer clock (post countdown-hold fix); RepairAll skips these
        durationSec = durationSec,
        completedAt = time(),
        level = level,
        mapID = saved.mapID,
        chests = chests,
        parTimeSec = saved.parTimeSec,
        deathCount = saved.deathCount,
        deaths = saved.deaths,
        routeName = saved.routeName,
        nPulls = saved.route and saved.route.nPulls or nil,
        pullTimes = saved.route and KG.PullTrack:GetPullTimes() or nil,
        snapshots = saved.snapshots,
        bossKills = saved.bossKills,
        bossNames = saved.bossNames,
        bossPcts = saved.bossPcts,
        bossIDs = saved.bossIDs,
        bossEngages = saved.bossEngages,
    })
    KG.db.lastRecorded = { mapID = saved.mapID, level = level } -- default /kg export target
    if stored then
        print(string.format("|cff88ccffKeystoneGhost|r: run saved as %s ghost (+%d, %s).",
            KG.Math.TierLabel(chests), level, KG.Math.FormatClock(durationSec)))
    end
end
