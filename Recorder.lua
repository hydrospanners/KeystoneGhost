-- Live-run recorder: samples { t, count, bosses } every SNAPSHOT_INTERVAL during an
-- active key — the raw integer enemy-forces COUNT, count-space storage (DESIGN
-- "Count-space storage"): the count is the scenario's source value, percent is
-- derived at render time. Timestamps boss kills the moment the boss criterion flips,
-- records the death timeline, and saves the run into the tier-slot DB on completion
-- (whole-second quantization happens ONCE, at save — live RAM keeps full-precision
-- GetTime floats so the smooth-Mario clock is untouched; integers for facts, floats
-- for rendering). Also owns the live state the bar reads.
--
-- Clock: elapsed = GetTime() - startTime, with startTime continuously re-anchored to the
-- OFFICIAL keystone timer (GetWorldElapsedTime): it starts after the countdown and jumps
-- forward on deaths, so death penalties cost bar position directly — for you and, since
-- recordings share this clock, for the ghost alike. GetTime smooths between the timer's
-- whole-second updates.
--
-- /reload + client-restart recovery (Live Run persistence, reference-persistence
-- "Adopt" #1): the live `rec` IS `KeystoneGhostDB.liveRun` for the run's duration, so
-- every SavedVariables flush (reload/logout) carries the full recording. Resume()
-- ADOPTS it back — real pre-reload timeline, run stays save-eligible — when the pure
-- verdict (GhostMath.LiveRunVerdict: same char + same key + the wall-clock epoch
-- proves same run) allows. Otherwise it falls back to SEEDING: clock from the world
-- keystone timer, current forces/bosses as a floor, recording marked `partial` and
-- never saved, pre-reload kills seeded at the resume timestamp. A hard crash never
-- wrote the liveRun, so it lands in the seed tier by construction.
local ADDON_NAME, NS = ...
local KG = NS.KG
local S = KG.Scenario

local R = {}
KG.Recorder = R

local SNAPSHOT_INTERVAL = 2
local MIN_SNAPSHOTS = 3

local rec = { active = false }
-- The Raced-Ghost Switch core lives OUTSIDE rec: it holds references to run tables
-- from the ghost DB, and rec is persisted wholesale as KeystoneGhostDB.liveRun —
-- serializing those references would dump entire runs into the liveRun slot.
local overtake = nil
R.currentRef = nil

function R:IsActive() return rec.active end

function R:GetElapsed()
    if not rec.startTime then return nil end
    if rec.awaitingTimer then return 0 end -- countdown: parked at the start line
    return GetTime() - rec.startTime
end

--- Live progress for the bar: forces% (derived — display value), boss kill count.
function R:GetProgress()
    if not rec.active then return nil end
    return rec.lastPct or 0, rec.bossKills and #rec.bossKills or 0
end

function R:GetParTime() return rec.parTimeSec end

function R:GetBossKills() return rec.bossKills end

--- Live boss metadata parallel to GetBossKills(): names, forces COUNT at each kill,
--- and encounterIDs (sparse — a kill whose ENCOUNTER_START was missed has no ID).
--- seededKills = number of leading entries whose timestamps are resume-seeded (post-
--- /reload) and therefore not real lap times.
function R:GetBossMeta() return rec.bossNames, rec.bossCounts, rec.seededKills or 0, rec.bossIDs end

--- Raw forces + scenario total from the last tick (route pull inference).
function R:GetRawForces() return rec.lastRaw or 0, rec.lastTotal or 0 end

--- Route context ({ cumulativeForces, bossPull, nPulls, name, capture fields })
--- when MDT has a matching preset selected.
function R:GetRoute() return rec.route end

--- Tracked current pull (APL model) — nil without a route.
function R:GetTrackerPull() return KG.PullTrack:GetCurrentPull() end

function R:GetDeaths() return rec.deaths end

function R:GetDeathCountLive() return rec.deathCount or 0, rec.deathTimeLost end

--- The in-progress run as a run-shaped table (for inverting YOUR timeline when racing a
--- live ghost that you are ahead of — see GhostMath.LiveDelta). Carries the live total
--- so cross-unit inversions can map through fraction space.
function R:GetLiveRun()
    return { snapshots = rec.snapshots, bossKills = rec.bossKills, total = rec.lastTotal }
end

function R:GetContext() return rec.mapID, rec.level end

function R:OnKeyStart()
    -- Safeguard (Fredrik 2026-07-20, Live Test 1): a forgotten /kg test must never
    -- shadow a REAL key. Recording always ran underneath test mode (it is
    -- event-driven and ignores the display), but the bar would have kept showing
    -- the demo race — wrong info at the worst moment. Real key = test mode off,
    -- with a chat note so the change of picture is explained.
    if KG.testMode then
        KG.testMode = false
        print("|cff88ccffKeystoneGhost|r: test mode off — a real key is starting.")
    end
    R:AbandonPartySpecSweep() -- a new key outranks last run's spec backfill
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
    rec.bossCounts = {}
    rec.bossDone = {}
    rec.deaths = {}
    rec.lastSnap = rec.startTime
    rec.lastPct = 0
    rec.lastRaw, rec.lastTotal = 0, 0
    rec.deathCount = 0
    rec.partial = nil
    rec.seededKills = 0

    -- Payload-expansion context (DESIGN "Payload expansion"): captured AT RUN TIME —
    -- spec/guild/level change later; history must not rewrite. Party ratings are
    -- captured at key END instead (at-completion values).
    rec.player = S:GetPlayerContext()
    rec.season = S:GetSeasonID()
    rec.affixes = S:GetAffixIDs()

    -- Optional MDT context: route name (export metadata) + cumulative pull forces (the
    -- Pull Indicator). Both nil without MDT / non-matching preset.
    rec.route = KG.Route:GetForChallengeMap(rec.mapID)
    rec.routeName = rec.route and rec.route.name or nil
    KG.PullTrack:Reset(rec.route)
    rec.pullTimes = KG.PullTrack:GetPullTimes() -- by reference: pull laps persist too

    -- Live Run persistence: rec ITSELF is the SavedVariables slot from here to run
    -- end — every reload/logout flush carries the recording as it stands, and
    -- Resume() can adopt it back. charKey + startEpoch (stamped at the timer anchor
    -- in OnTick) are what LiveRunVerdict validates against.
    rec.charKey = KG.CharacterKey()
    KG.db.liveRun = rec

    R.currentRef = rec.mapID and KG.Ghosts:BuildReference(rec.mapID, rec.level) or nil

    -- The Raced-Ghost Switch core (docs/SWITCH-WORKSHOP.md): one Overtake state per
    -- run, attached to the initial pick. Imports start PINNED (S13) — competing
    -- against the sender stays deliberate until the player unpins — and so does any
    -- Library-pinned reference (startPinned): "races when you run X" holds until
    -- the player says otherwise.
    R.lastSwitch = nil
    overtake = R.currentRef
        and KG.Overtake.New(R.currentRef.run,
            R.currentRef.kind == "import" or R.currentRef.startPinned == true) or nil
end

--- Resume racing after a /reload or client restart mid-key. Two tiers (SCENARIOS D1):
--- ADOPT the persisted Live Run — the real pre-reload timeline continues, the run
--- stays save-eligible — or fall back to SEEDING: the world keystone timer gives true
--- elapsed, current forces/bosses seed a floor for the delta math, the recording is
--- `partial` and never saved.
function R:Resume()
    if rec.active then return end
    if not S:IsChallengeActive() then return end
    local elapsed = S:GetWorldElapsedSec()
    if not elapsed or elapsed < 1 then return end
    local mapID = S:GetChallengeMapID()
    if not mapID then return end -- scenario still loading: the 0.5 s ticker retries

    local lr = KG.db.liveRun
    if KG.Math.LiveRunVerdict(lr, {
        charKey = KG.CharacterKey(), mapID = mapID, level = S:GetActiveKeyLevel(),
        elapsed = elapsed, now = S:ServerNow(),
    }) == "adopt" then
        R:AdoptLiveRun(lr, elapsed)
        return
    end
    KG.db.liveRun = nil -- provably not this run (or unusable): the stale slot dies

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

    rec.snapshots = { { elapsed, rec.lastRaw, #rec.bossKills } }
    print(string.format("|cff88ccffKeystoneGhost|r: resumed racing after reload at %s (this run won't be saved as a ghost).",
        KG.Math.FormatClock(elapsed)))
end

--- ADOPT tier: rewire the persisted recording as the live one. The tables come back
--- by reference — the same tables `KG.db.liveRun` points at, so mutation keeps
--- persisting — and only the session-local machinery (clock anchor, reference,
--- Overtake, PullTrack) is rebuilt around them. Whatever happened during the gap is
--- folded in at the resume moment (the moment we LEARNED of it, not the moment it
--- happened): gap boss kills timestamp on the first tick's criteria diff, gap deaths
--- here, gap forces on the next snapshot — the curve interpolates across the hole.
function R:AdoptLiveRun(lr, elapsed)
    R:AbandonPartySpecSweep()
    R.summary = nil
    rec = lr
    rec.active = true
    local now = GetTime()
    rec.startTime = now - elapsed
    rec.awaitingTimer = nil
    rec.startEpoch = S:ServerNow() - elapsed -- re-stamp: exact again after the gap
    rec.lastSnap = now
    rec.pendingEngage = nil -- a mid-fight reload: that engage may have resolved unseen

    -- Deaths during the gap arrive count-only; fold them into one timeline entry.
    local n, timeLost = S:GetDeathCount()
    if n then
        if n > (rec.deathCount or 0) then
            rec.deaths[#rec.deaths + 1] = { elapsed, n }
        end
        rec.deathCount, rec.deathTimeLost = n, timeLost
    end

    KG.PullTrack:Reset(rec.route, rec.pullTimes)
    R.currentRef = KG.Ghosts:BuildReference(rec.mapID, rec.level)
    R.lastSwitch = nil
    overtake = R.currentRef
        and KG.Overtake.New(R.currentRef.run,
            R.currentRef.kind == "import" or R.currentRef.startPinned == true) or nil

    if rec.partial then
        print(string.format("|cff88ccffKeystoneGhost|r: resumed racing after reload at %s (timeline restored; the run was already partial and won't be saved).",
            KG.Math.FormatClock(elapsed)))
    else
        print(string.format("|cff88ccffKeystoneGhost|r: resumed racing after reload at %s — full timeline restored, the run can still be saved as a ghost.",
            KG.Math.FormatClock(elapsed)))
    end
end

function R:Abort()
    rec = { active = false }
    overtake = nil
    KG.db.liveRun = nil -- the run is over (reset / left the instance): nothing to resume
    R.currentRef = nil
    R.lastSwitch = nil
    KG.PullTrack:Reset(nil)
end

--- Swap the Raced Ghost onto `run` (auto Overtake or manual row click). The ref swap
--- IS the re-baseline: title, Gap, Count Gap, Gap Zone, milestones, laps, and the
--- knockback baseline all re-derive from currentRef on the next refresh — one event,
--- same tick, nothing to desync (S7/S8). lastSwitch drives the presentation layer
--- (badge/milestone crossfade in Bar, row glow in Splits).
function R:SetRacedRun(run)
    local ref = KG.Ghosts:RefForRun(run)
    if not ref then return end
    R.currentRef = ref
    R.lastSwitch = { at = GetTime(), run = run }
end

--- Evaluate Overtakes among the visible Roster Ghosts (course space, the geometry the
--- player SEES — W1). At most one switch per tick.
function R:EvaluateSwitch(t)
    local ref = R.currentRef
    if not ref or not overtake or not ref.run then return end
    local roster = rec.mapID and KG.Ghosts:GetRoster(rec.mapID, rec.level, rec.routeName)
    if not roster or #roster == 0 then return end
    local M = KG.Math
    local nBosses = ref.nBosses or (ref.run.bossKills and #ref.run.bossKills) or 0
    local you = M.CoursePos(rec.lastPct, rec.bossKills and #rec.bossKills or 0, nBosses)
    local runners = {}
    for _, e in ipairs(roster) do
        if e.run ~= ref.run and e.run.snapshots then
            local course = M.CourseAt(e.run, t, nBosses)
            runners[#runners + 1] = { id = e.run, course = course, parked = course >= 1 }
        end
    end
    local winner = KG.Overtake.Evaluate(overtake, t, you, runners,
        { buffer = KG.Overtake.BUFFER_FRAC * M.VIS })
    if winner then R:SetRacedRun(winner) end
end

--- Roster Panel row click (S9): a non-raced row switches AND pins; the raced row
--- toggles the pin. Returns what happened for the caller's refresh.
function R:HandleRowClick(run)
    if not rec.active or not overtake or not R.currentRef then return nil end
    local ov = overtake
    if run == R.currentRef.run then
        if ov.pinned then KG.Overtake.Unpin(ov) else KG.Overtake.Pin(ov) end
        return ov.pinned and "pinned" or "unpinned"
    end
    KG.Overtake.ManualSwitch(ov, run)
    R:SetRacedRun(run)
    return "switched"
end

function R:IsPinned()
    return overtake ~= nil and overtake.pinned or false
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
    -- Anchoring also stamps startEpoch — the wall clock at the timer's zero, the Live
    -- Run's proof of identity across a client restart (LiveRunVerdict).
    if rec.awaitingTimer then
        local official = S:GetWorldElapsedSec()
        if official then
            rec.startTime = now - official
            rec.startEpoch = S:ServerNow() - official
            rec.awaitingTimer = nil
        elseif now - rec.startTime > 20 then
            rec.startTime = now -- failsafe: never wait forever if the API goes missing
            rec.startEpoch = S:ServerNow()
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
            -- Re-stamp the epoch with the anchor: death penalties move the timer's
            -- zero back in wall-clock terms, and the Live Run's age must track it.
            rec.startEpoch = S:ServerNow() - official
        end
    end

    local t = now - rec.startTime
    local raw, total = S:ReadEnemyForcesRaw()
    -- Forces never decrease in a key: a sudden drop (> 1% of the total) means the
    -- scenario is collapsing (completion teardown fires a beat before
    -- CHALLENGE_MODE_COMPLETED) or a secret flicker — keep the last good reading
    -- instead of recording garbage. Count-space equivalent of the old pct+1 guard.
    if raw + math.max(1, total * 0.01) < (rec.lastRaw or 0) then
        raw, total = rec.lastRaw, rec.lastTotal
    end
    rec.lastRaw, rec.lastTotal = raw, total
    rec.lastPct = (total > 0) and (raw / total) * 100 or 0 -- derived display value

    -- Boss kills are timestamped every tick (not every snapshot) for sharp split times.
    -- Diffing per-criterion done flags (not just the count) captures which boss it was,
    -- so the kill order carries the right name and count even on off-order routes.
    for i, cs in ipairs(S:GetBossCriteriaStates()) do
        if cs.done and not rec.bossDone[i] then
            rec.bossDone[i] = true
            local k = #rec.bossKills + 1
            rec.bossKills[k] = t
            rec.bossNames[k] = cs.name
            rec.bossCounts[k] = rec.lastRaw
            -- Attach the pending engage: identity + pull time for this kill.
            if rec.pendingEngage then
                rec.bossIDs = rec.bossIDs or {}
                rec.bossEngages = rec.bossEngages or {}
                rec.bossIDs[k] = rec.pendingEngage.id
                rec.bossEngages[k] = rec.pendingEngage.t
                -- Journal identity too (TASKS #11): resolvable only HERE, inside the
                -- instance — importers then display THEIR locale's boss name. nil
                -- stays nil; the criteria-scraped name is the standing fallback.
                local jid = S:GetJournalEncounterID(rec.pendingEngage.id)
                if jid then
                    rec.bossJIDs = rec.bossJIDs or {}
                    rec.bossJIDs[k] = jid
                end
                rec.pendingEngage = nil
            end
        end
    end

    KG.PullTrack:Update(rec.lastRaw, #rec.bossKills, t)

    if now - rec.lastSnap >= SNAPSHOT_INTERVAL then
        rec.lastSnap = now
        rec.snapshots[#rec.snapshots + 1] = { t, rec.lastRaw, #rec.bossKills }
    end

    -- Live RaiderIO replay ghost: mirror its progress; and if the key started with a
    -- linear fallback because the replay wasn't ready yet, upgrade within the first
    -- minute (RaiderIO initializes its replay after CHALLENGE_MODE_START).
    local ref = R.currentRef
    if ref and ref.live then
        KG.Ghosts:UpdateRioMirror(ref, t)
    elseif t < 60 and ref and (ref.kind == "season" or ref.kind == "par") then
        local rio = KG.Ghosts:BuildRioReference()
        if rio then
            R.currentRef = rio
            -- Upgrading to the replay re-seats the Overtake core too (the replay can
            -- be switched AWAY from, never TO — S12's standing constraint).
            overtake = KG.Overtake.New(rio.run, false)
        end
    end

    R:EvaluateSwitch(t)
end

function R:OnKeyEnd()
    local saved = rec
    local ref = R.currentRef
    rec = { active = false }
    overtake = nil
    KG.db.liveRun = nil -- run over: detach the resume slot (saved stays usable locally)
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

    local total = saved.lastTotal or 0
    if total <= 0 then return end -- forces never readable this run: nothing raceable to keep

    -- Whole-second quantization happens HERE, once (integers for facts, floats for
    -- rendering — DESIGN "Count-space storage"): live RAM ran on GetTime floats, the
    -- stored representation is whole-second t + integer count. The snapshot boss
    -- column is rebuilt from the QUANTIZED kill times with the codec's own `<=` rule,
    -- so a stored run and its export string round-trip bit-identically.
    local function rnd(x) return math.floor((x or 0) + 0.5) end
    local nBosses = #saved.bossKills
    local kills = {}
    for i = 1, nBosses do kills[i] = rnd(saved.bossKills[i]) end
    local engages
    for i, eng in pairs(saved.bossEngages or {}) do -- sparse: a kill can lack its engage
        engages = engages or {}
        engages[i] = rnd(eng)
    end
    local snaps = {}
    for i = 1, #saved.snapshots do
        local s = saved.snapshots[i]
        local t, c = rnd(s[1]), rnd(s[2])
        local k = 0
        for j = 1, nBosses do
            if kills[j] <= t then k = k + 1 end
        end
        snaps[i] = { t, c, k }
    end
    -- The closer: parked AT the finish — full count, every boss, official duration
    -- (clamped so quantization can never step it behind the last live sample).
    local closerT = math.max(rnd(durationSec), snaps[#snaps] and snaps[#snaps][1] or 0)
    snaps[#snaps + 1] = { closerT, total, nBosses }
    for _, d in ipairs(saved.deaths or {}) do d[1] = rnd(d[1]) end
    local bossCounts = {}
    for i = 1, nBosses do bossCounts[i] = rnd(saved.bossCounts[i] or 0) end
    local pullTimes = saved.route and KG.PullTrack:GetPullTimes() or nil
    if pullTimes then
        for k, v in pairs(pullTimes) do pullTimes[k] = rnd(v) end
    end

    local stored = KG.Ghosts:Save({
        clockV = 2, -- official-timer clock (post countdown-hold fix)
        total = total, -- the dungeon's forces requirement at record time (count units)
        durationSec = durationSec,
        completedAt = S:ServerNow(), -- server epoch: client clocks lie
        week = S:WeekEndEpoch(), -- reset-week identity ("reset best" seed, 2026-07-21)
        player = saved.player, -- exporter context, captured at key start
        season = saved.season,
        affixes = saved.affixes,
        party = S:GetPartyContext(), -- ratings at completion
        level = level,
        mapID = saved.mapID,
        chests = chests,
        parTimeSec = saved.parTimeSec,
        deathCount = saved.deathCount,
        deaths = saved.deaths,
        routeName = saved.routeName,
        routeHash = saved.route and saved.route.hash or nil, -- Route Store reference
        nPulls = saved.route and saved.route.nPulls or nil,
        pullTimes = pullTimes,
        snapshots = snaps,
        bossKills = kills,
        bossNames = saved.bossNames,
        bossCounts = bossCounts,
        bossIDs = saved.bossIDs,
        bossJIDs = saved.bossJIDs,
        bossEngages = engages,
    })
    KG.db.lastRecorded = { mapID = saved.mapID, level = level } -- default /kg export target
    if stored and saved.route and saved.route.hash and saved.route.pulls then
        KG.Ghosts:StoreRoute(saved.route) -- the run's route as it was AT KEY START
    end
    if stored then
        print(string.format("|cff88ccffKeystoneGhost|r: run saved as %s ghost (+%d, %s).",
            KG.Math.TierLabel(chests), level, KG.Math.FormatClock(durationSec)))
        R:StartPartySpecSweep()
    end
end

--- ── Party spec backfill (best-effort) ────────────────────────────────────────
-- Others' spec needs an inspect round-trip — flaky MID-key, but at key END
-- everyone is out of combat and still grouped for the loot moment, so a short
-- sweep usually lands all four (DESIGN "Payload expansion"; wanted for the
-- anonymous spec labels — "RShaman", "Aug" — on exports with party names off).
-- One NotifyInspect at a time (the client cancels overlapping requests);
-- INSPECT_READY stamps the specID onto the just-saved run's party entry,
-- matched by name. 2 s per member; a new key or /reload abandons the sweep.
-- Purely additive: a member who left or never answers keeps spec = nil and
-- displays via the role+class fallback.

local sweep -- { run, queue = { {unit, name}, ... }, current }

local function SweepNext()
    if not sweep then return end
    sweep.current = nil
    local entry = table.remove(sweep.queue, 1)
    if not entry then
        sweep = nil
        return
    end
    local okE, exists = pcall(UnitExists, entry.unit)
    local okN, name = pcall(GetUnitName, entry.unit, true)
    if okE and exists == true and okN and name == entry.name
        and S:RequestInspect(entry.unit) then
        sweep.current = entry
        C_Timer.After(2, function() -- no INSPECT_READY within 2 s: move on
            if sweep and sweep.current == entry then SweepNext() end
        end)
    else
        SweepNext() -- member gone or renamed slot: skip
    end
end

function R:StartPartySpecSweep()
    -- The saved run is the one Save() just stored; find it via lastRecorded.
    sweep = nil
    local lr = KG.db.lastRecorded
    if not lr then return end
    local tiers = KG.db.runs[KG.CharacterKey()]
    tiers = tiers and tiers[lr.mapID] and tiers[lr.mapID][lr.level]
    local saved
    for _, r2 in pairs(tiers or {}) do
        if r2.party and (not saved or (r2.completedAt or 0) > (saved.completedAt or 0)) then
            saved = r2
        end
    end
    if not saved then return end
    local queue = {}
    for i = 1, 4 do
        local unit = "party" .. i
        local okN, name = pcall(GetUnitName, unit, true)
        if okN and type(name) == "string" then
            for _, m in ipairs(saved.party) do
                if m.name == name and not m.spec then
                    queue[#queue + 1] = { unit = unit, name = name }
                end
            end
        end
    end
    if #queue == 0 then return end
    sweep = { run = saved, queue = queue }
    SweepNext()
end

function R:AbandonPartySpecSweep()
    sweep = nil
end

--- INSPECT_READY(guid) from Core: stamp the spec onto the saved run's member.
function R:OnInspectReady(guid)
    if not sweep or not sweep.current then return end
    local entry = sweep.current
    local okG, unitGuid = pcall(UnitGUID, entry.unit)
    if not okG or unitGuid ~= guid then return end -- someone else's inspect
    local spec = S:GetInspectSpecID(entry.unit)
    if spec then
        for _, m in ipairs(sweep.run.party) do
            if m.name == entry.name then m.spec = spec end
        end
    end
    SweepNext()
end
