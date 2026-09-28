-- The demo race: synthetic ghost + simulated player so the bar can be
-- inspected anywhere (/kg test, the Edit Mode preview, the first-login show).
-- EXTRACTED from Bar.lua 2026-09-10 (the 1.1 wave 2 split: the file was the
-- addon's largest and the 1.2 track features land there). State stays private;
-- Bar.lua consumes the public doors at the bottom. Comments carry their
-- original dates.
local ADDON_NAME, NS = ...
local KG = NS.KG
local M = KG.Math

local Demo = {}
KG.BarDemo = Demo

-- ── Test mode: synthetic ghost + simulated player so the bar can be inspected anywhere ──
local TEST_SPEED = 15 -- 15x (his call 2026-08-25 — "10 feels like waiting"): a ~28min
                      -- run demos in ~2min; 20x made real data look jerky, so this is
                      -- the ceiling short of that lesson
Demo.TEST_SPEED = TEST_SPEED -- Bar.lua scales the walk-speed cap by it
local test = {}

--- Prefer REAL recordings for the test race: the demo follows your FRESHEST dungeon
--- (the map whose newest run is newest overall — Developer 2026-07-20: the set you just
--- played is the set you want to look at; across characters/levels, key level is
--- irrelevant for a demo). Races the fastest, rosters up to two more. Falls back to
--- the synthetic ghost only when nothing is stored.
local function RealTestData()
    local byMap = {}
    for charKey, maps in pairs(KG.db.runs) do
        -- The Raider.IO cache is not YOUR data: a banked guild best must never
        -- masquerade as "Test: your +2 ghost" (it gets its own demo loop).
        if charKey ~= KG.RIO_CHAR then
            for mapID, byLevel in pairs(maps) do
                for _, tiers in pairs(byLevel) do
                    for _, run in pairs(tiers) do
                        if run.snapshots and #run.snapshots >= 3 and run.durationSec and run.total then
                            byMap[mapID] = byMap[mapID] or {}
                            table.insert(byMap[mapID], run)
                        end
                    end
                end
            end
        end
    end
    local best, bestAt
    for _, list in pairs(byMap) do
        local at = 0
        for _, r in ipairs(list) do at = math.max(at, r.completedAt or 0) end
        if not best or at > bestAt then best, bestAt = list, at end
    end
    if not best then return false end
    table.sort(best, function(a, b) return a.durationSec < b.durationSec end)
    test.run, test.run3, test.run2 = best[1], best[2], best[3]
    test.par = best[1].parTimeSec or 1800
    test.label = string.format("Test: your %s ghost (%s)",
        M.TierLabel(best[1].chests), M.FormatClock(best[1].durationSec))
    return true
end

--- Time-scaled copy of a run (shared by the synthetic roster fillers and the Rival;
--- never mutates the base — real DB runs pass through here in the real-data path).
local function CopyScaled(base, f, chests, importedFrom)
    local s2, k2 = {}, {}
    for i, s in ipairs(base.snapshots) do s2[i] = { s[1] * f, s[2], s[3] } end
    for i, k in ipairs(base.bossKills or {}) do k2[i] = k * f end
    -- Deaths travel too, scaled onto the copy's clock, so the demo's ghosts wear
    -- the tombstones their recording actually earned.
    local d2
    if base.deaths then
        d2 = {}
        for i, d in ipairs(base.deaths) do d2[i] = { d[1] * f, d[2] } end
    end
    return {
        snapshots = s2, bossKills = k2, deaths = d2, deathCount = d2 and #d2 or nil,
        durationSec = (base.durationSec or 0) * f,
        total = base.total, -- same units as the base: the race compares exactly
        bossNames = base.bossNames, bossCounts = base.bossCounts, level = base.level or 12,
        chests = chests, routeName = base.routeName, importedFrom = importedFrom,
        completedAt = (time and time() or 0) - 86400,
    }
end

--- One demo loop's cast, ALTERNATING scenarios per loop (Developer 2026-07-20 — the
--- test runs again and again, so every other loop is the first-run look):
---   odd loops, "real" — the fastest stored ghost raced + the manufactured Rival
---   (0.65× the raced time: outpaces the sim player, clears the real No-Switch
---   Buffer Zone, OVERTAKES about a fifth in — S10's excluded-actor case) + up to
---   two more stored ghosts in the roster.
---   even loops, "rio" — ONLY a converted-style Raider.IO ghost (first-class
---   replay, 2026-07-21: full curve from 0:00, skulls placed upfront, identity
---   laps — what a first-run user actually sees; the old loop simulated the tick
---   MIRROR, which is now the degraded fallback only, not the demo).
--- Edit Mode preview pins "real" and stays silent — positioning is not testing.
--- The sim player's own timeline as a run-shape: the demo player rides the base
--- curve at t*1.12+25, so invert that mapping. YOUR tombstones place on this —
--- without it the whole graveyard would stand at the start line.
local function SimRunOf(base)
    local ss = {}
    for i, s in ipairs(base.snapshots) do
        ss[i] = { math.max(0, (s[1] - 25) / 1.12), s[2], s[3] }
    end
    return { snapshots = ss, total = base.total }
end

--- Demo deaths for a manufactured cast member whose base recording was clean —
--- otherwise the ghost half of the Death Markers is invisible in `/kg test` for
--- anyone whose real runs went well (Developer 2026-07-22: he raced the RIO loop
--- and the only death glyphs on screen were his own). The sim player's deaths
--- were always fabricated; this is the same trick on the other side. Real
--- recordings are never touched — only CopyScaled results reach this.
--- The STALL is injected with the stone: a real recording's clock jumps on a
--- death (the penalty is baked in), so its ghost stands still at the grave. A
--- demo that drew the stone alone would show a ghost strolling through it.
local DEMO_PENALTY = 15
local function EnsureDemoDeaths(run)
    if run.deaths or not run.snapshots then return run end
    local dur = run.durationSec or 1600
    local deaths = {}
    for i, frac in ipairs({ 0.42, 0.62, 0.82 }) do
        local at = dur * frac + DEMO_PENALTY * (i - 1)
        deaths[i] = { at, i }
        for _, s in ipairs(run.snapshots) do
            if s[1] > at then s[1] = s[1] + DEMO_PENALTY end
        end
        for k, bk in ipairs(run.bossKills or {}) do
            if bk > at then run.bossKills[k] = bk + DEMO_PENALTY end
        end
    end
    run.deaths, run.deathCount = deaths, #deaths
    run.durationSec = dur + DEMO_PENALTY * #deaths
    return run
end

local function SeedTestSwitch()
    if KG.testMode or KG.introMode then -- the first-login show runs the real loop rotation
        test.loopN = (test.loopN or 0) + 1
        test.scenario = (test.loopN % 2 == 1) and "real" or "rio"
    else
        test.scenario = "real"
    end
    if test.scenario == "rio" then
        local base = test.run
        local g = EnsureDemoDeaths(CopyScaled(base, 1, base.chests))
        g.legacy, g.rioSource = "RIO", "guild best"
        g.bossIDs, g.bossJIDs = base.bossIDs, base.bossJIDs -- identity travels (by
        g.routeName = nil -- reference, like bossNames); converted runs carry no route
        test.rioRef = {
            kind = "rio",
            label = string.format("RaiderIO guild best +%d (%s)", g.level or 0,
                M.FormatClock(g.durationSec or 0)),
            durationSec = g.durationSec,
            run = g,
        }
        test.simRun = SimRunOf(base)
        test.ov = nil
        test.attached = nil
        if KG.testMode then -- the intro show runs the same loops, but quietly
            print("|cff88ccffKeystoneGhost|r: test loop: Raider.IO ghost only (the first-run look).")
        end
    else
        test.rioRef = nil
        test.simRun = SimRunOf(test.run)
        test.rival = EnsureDemoDeaths(CopyScaled(test.run, 0.65, 3))
        test.ov = KG.Overtake.New(test.run, false)
        test.attached = test.run
        if KG.testMode then
            print("|cff88ccffKeystoneGhost|r: test loop: full roster (your real ghosts when stored).")
        end
    end
    test.lastSwitch = nil
    test.start = GetTime()
end

--- /kg test re-enable: restart the scenario rotation at loop 1 and re-scan the DB
--- (a run recorded since the last toggle joins the demo).
function Demo.ResetLoop()
    for k in pairs(test) do test[k] = nil end
end

local function BuildTestData()
    if RealTestData() then
        SeedTestSwitch()
        return
    end
    local par, dur = 1800, 1620
    local TOTAL = 300 -- synthetic dungeon total (count units; 12 pulls × 25)
    local bossKills = { 420, 900, 1380 }
    local snaps = {}
    local function trashTime(t) -- forces freeze during the last 60s before each boss kill
        local tt = t
        for _, bk in ipairs(bossKills) do
            local a, b = bk - 60, bk
            if t > a then tt = tt - (math.min(t, b) - a) end
        end
        return tt
    end
    for t = 0, dur, 30 do
        local count = math.floor(math.min(TOTAL, trashTime(t) / (dur - 60 * #bossKills) * TOTAL) + 0.5)
        local bosses = 0
        for _, bk in ipairs(bossKills) do if t >= bk then bosses = bosses + 1 end end
        snaps[#snaps + 1] = { t, count, bosses }
    end
    snaps[#snaps + 1] = { dur, TOTAL, #bossKills }
    local counts = {}
    for i, bk in ipairs(bossKills) do counts[i] = M.SampleAt(snaps, bk) end
    test.run = {
        snapshots = snaps, bossKills = bossKills, durationSec = dur, total = TOTAL,
        bossNames = { "Test Boss One", "Test Boss Two", "Test Boss Three" },
        bossCounts = counts, level = 12, chests = 2,
        deaths = { { 700, 1 }, { 710, 2 } },
        routeName = "Test route",
    }
    -- Two manufactured roster fillers (time-scaled copies of the base run) so /kg test
    -- exercises the full 3-row roster: a slower own +1 and a faster "imported" +3.
    test.run2 = CopyScaled(test.run, 1.09, 1)                                -- own +1, 29:26
    test.run3 = CopyScaled(test.run, 0.926, 3, "Leegolas-TarrenMill-DRUID")  -- imported +3, 25:00
    test.par = par
    -- 12 even pulls over a 300-count dungeon for the pull indicator preview; the
    -- createdBy sample shows the class-colored creator token in the demo.
    test.route = { cumulativeForces = {}, nPulls = 12, name = "Test route",
        createdBy = { name = "Leegolas", classFile = select(2, UnitClass("player")) } }
    for i = 1, 12 do test.route.cumulativeForces[i] = 25 * i end
    SeedTestSwitch()
end

local function TestTag(run)
    return (run.importedFrom and run.importedFrom:match("^([^%-]+)")) or M.TierLabel(run.chests)
end

--- The demo raced ghost's title line (hoisted 2026-08-09: the demo Finish
--- Photo needs the same words TestState speaks).
local function TestRefLabel(raced)
    if raced == test.run then
        return test.label or "Test ghost (27:00)"
    elseif raced == test.rival then
        return "Rival ghost (" .. M.FormatClock(raced.durationSec or 0) .. ")"
    end
    local rr = KG.Ghosts:RefForRun(raced)
    return rr and rr.label or "Test ghost"
end

local function TestState()
    if not test.run then BuildTestData() end
    local elapsed = (GetTime() - test.start) * TEST_SPEED
    if elapsed > test.run.durationSec * 1.05 then
        SeedTestSwitch() -- loop wrap: fresh race, fresh Switch state
        elapsed = 0
    end
    local simT = elapsed * 1.12 + 25 -- simulated player: head start + growing lead
    local total = test.run.total or 300
    local raw = M.SampleAt(test.run.snapshots, simT) -- sim player rides the ghost's curve
    local pct = M.Frac(raw, total)
    local bosses, liveKills = 0, {}
    for _, bk in ipairs(test.run.bossKills or {}) do
        if simT >= bk then
            bosses = bosses + 1
            liveKills[bosses] = math.max(0, (bk - 25) / 1.12) -- when the sim player got there
        end
    end

    -- Simulated group deaths (Developer 2026-07-19: verify the Knockback + Death Pot in
    -- the demo): one stumble, then a pot-gathered double, then one more. Paced at
    -- fractions of the run so the rate stays ~1-3 deaths per 10 minutes whatever the
    -- base recording's length (Developer 2026-07-23: every-30s was a wipefest).
    -- The double lands as TWO ticks (0.8 sim-s apart) so the second death arrives while
    -- the first knock is animating — that's the Death Pot path, not just a big knock.
    local deaths = 0
    local simDeaths = {} -- {t, running count} — feeds the tombstone Death Markers
    local dur = test.run.durationSec or 1620
    for _, frac in ipairs({ 0.15, 0.42, 0.42 + 0.8 / dur, 0.72 }) do
        local dT = dur * frac
        if dT > elapsed then break end
        deaths = deaths + 1
        simDeaths[#simDeaths + 1] = { dT, deaths }
    end

    -- The Rabbit's always-lane previews in `/kg test` too (his 2026-09-01
    -- catch: flipping the option showed nothing in the demo — but the demo IS
    -- the no-key preview). Same doors as the live roster (Ghosts:GetRoster's
    -- rule); a demo run without a mapID or a readable par just means no lane.
    local function WithDemoRabbit(roster, mapID, level)
        if (KG.db.rabbitMode or "auto") == "always" and mapID then
            -- Level rides along since F7: a percentile Rabbit previews at the
            -- demo run's own key level (the #163 lesson — the demo IS the
            -- no-key preview, so settings must show in it).
            local rabbit = KG.Ghosts:RabbitRun(mapID, level)
            if rabbit then roster[#roster + 1] = { run = rabbit, tag = "Rabbit" } end
        end
        return roster
    end

    -- Even loops race ONLY the Raider.IO ghost (SeedTestSwitch alternates): a
    -- complete converted-style run — full curve, upfront skulls, identity laps —
    -- no Rival, no fillers, no Switch; the bar exactly as a first-run user with
    -- zero stored ghosts sees it.
    if test.scenario == "rio" and test.rioRef then
        return {
            elapsed = elapsed, pct = pct, bosses = bosses, liveKills = liveKills, par = test.par,
            liveNames = test.run.bossNames, liveCounts = test.run.bossCounts,
            raw = raw, total = total, route = test.route,
            liveRun = test.simRun, -- the sim player's own curve: the Death Markers place on it
            deathCount = deaths, deathTimeLost = deaths * 15, deaths = simDeaths,
            ref = test.rioRef,
            roster = WithDemoRabbit({ { run = test.rioRef.run, tag = "RIO" } }, test.rioRef.run.mapID, test.rioRef.run.level),
            lastSwitch = nil,
            pinned = false,
        }
    end

    -- The Raced-Ghost Switch, demo edition: the same Overtake core on the sim clock
    -- (guards run in sim-seconds — quick, but every stage shows). The Rival crosses
    -- the sim player about a fifth into the loop and takes over the race.
    local nBosses = #(test.run.bossKills or {})
    local raced = test.attached or test.run
    -- The demo cast in its STABLE roster order (raced included — the Roster Panel
    -- highlights in place, it never reorders; the base run leads so the demo
    -- starts highlighted on row 1 and the Rival's Overtake moves the mark).
    local cast = { test.run, test.rival, test.run3, test.run2 }
    local runners = {}
    for _, rn in ipairs(cast) do
        if rn and rn ~= raced then
            local course = M.CourseAt(rn, elapsed, nBosses)
            runners[#runners + 1] = { id = rn, course = course, parked = course >= 1 }
        end
    end
    local winner = test.ov and KG.Overtake.Evaluate(test.ov, elapsed,
        M.CoursePos(pct, bosses, nBosses), runners,
        { buffer = KG.Overtake.BUFFER_FRAC * M.VIS }) or nil
    if winner then
        test.attached = winner
        test.lastSwitch = { at = GetTime(), run = winner }
        raced = winner
    end

    local label = TestRefLabel(raced)
    local roster = {}
    for _, rn in ipairs(cast) do
        if rn then
            roster[#roster + 1] = { run = rn, tag = rn == test.rival and "Rival" or TestTag(rn) }
        end
    end
    return {
        elapsed = elapsed, pct = pct, bosses = bosses, liveKills = liveKills, par = test.par,
        liveNames = test.run.bossNames, liveCounts = test.run.bossCounts,
        raw = raw, total = total, route = test.route,
        liveRun = test.simRun, -- the sim player's own curve: your tombstones place on it
        deathCount = deaths, deathTimeLost = deaths * 15, deaths = simDeaths,
        ref = { kind = "test", label = label, run = raced, durationSec = raced.durationSec },
        roster = WithDemoRabbit(roster, test.run.mapID, test.run.level),
        lastSwitch = test.lastSwitch,
        pinned = test.ov ~= nil and test.ov.pinned or false,
    }
end

--- The demo's own Finish Photo (his order 2026-08-09: "the end screen needs to
--- be in the /kg test too") — a summary shaped exactly like the Recorder's,
--- from the loop's own cast, so H8+H9 show without running a key. The sim
--- player crosses when its 1.12x clock reaches the ghost's course end; the
--- loops alternate a WIN (vs the RaiderIO ghost) and a LOSS (vs the faster
--- Rival), so both photo verdicts get demoed. No share slot on purpose: the
--- demo run is not a stored ghost, and the glyph's absence is the honest state.
local function BuildTestSummary()
    local raced = (test.scenario == "rio" and test.rioRef) and test.rioRef.run
        or test.attached or test.run
    local dur = test.run.durationSec or 1620
    local finalTime = math.floor((dur - 25) / 1.12 + 0.5)
    local chests = M.TierForDuration(finalTime, test.par) or 0
    local ref = (test.scenario == "rio" and test.rioRef)
        or { kind = "test", label = TestRefLabel(raced), run = raced, durationSec = raced.durationSec }
    local pool = {}
    local function Cand(rn, tag)
        if rn and type(rn.durationSec) == "number" and rn.durationSec > 0 then
            pool[#pool + 1] = { run = rn, tag = KG.Ghosts:OwnerShortName(rn) or tag }
        end
    end
    if test.scenario == "rio" then
        Cand(test.rioRef.run, "RIO")
    else
        for _, rn in ipairs({ test.run, test.rival, test.run3, test.run2 }) do
            Cand(rn, rn == test.rival and "Rival" or TestTag(rn))
        end
    end
    local liveKills = {}
    for i, bk in ipairs(test.run.bossKills or {}) do
        liveKills[i] = math.max(0, (bk - 25) / 1.12)
    end
    local laps, lapMatch = M.LapDeltasByID(liveKills, raced.bossKills or {},
        test.run.bossIDs, raced.bossIDs)
    local stats = {
        deaths = 4, timeLost = 4 * 15, -- the sim's scripted stumbles, all landed by the wrap
        raw = (test.run.total or 300) + 7, total = test.run.total or 300,
    }
    stats.bestIdx, stats.best, stats.worstIdx, stats.worst = M.LapExtremes(laps, lapMatch, 0)
    stats.nextTier, stats.tierGap = M.NextTierGap(finalTime, test.par)
    return {
        label = ref.label,
        diff = ref.durationSec and (ref.durationSec - finalTime) or nil,
        finalTime = finalTime, chests = chests, at = GetTime(), ref = ref,
        level = test.run.level, par = test.par, mapID = test.run.mapID,
        rows = M.ClosestRuns(pool, finalTime, 2), stats = stats,
    }
end

--- The 5-second photo hold at each demo wrap ("let it stay on the end screen
--- for 5 seconds before you loop"). True while Refresh should route to
--- ShowSummary(test.summary); the hold expiring — or the photo's × — seeds
--- the next loop. Only /kg test holds: the intro show and the Edit Mode
--- preview keep their instant wrap (a frozen photo under the MOVE ME handle
--- would read as broken, and a drag wants the live bar).
local function TestPhotoHold()
    if not test.run then return false end
    if test.summary then
        if GetTime() < (test.photoUntil or 0) then return true end
        test.summary = nil
        SeedTestSwitch()
        return false
    end
    if (GetTime() - test.start) * TEST_SPEED <= (test.run.durationSec or 1620) * 1.05 then
        return false
    end
    test.summary = BuildTestSummary()
    test.photoUntil = GetTime() + 5
    return true
end

local function DismissTestPhoto()
    if test.summary then
        test.summary = nil
        SeedTestSwitch()
    end
end

--- Public doors (Bar.lua consumes these; the demo's state stays private).
Demo.State = TestState
Demo.PhotoHold = TestPhotoHold
Demo.Dismiss = DismissTestPhoto
function Demo.Summary() return test.summary end

--- Roster row click, demo edition (moved from Bar.HandleRowClick): drives the
--- demo's Overtake state so the whole switch/pin flow is clickable in /kg test.
function Demo.RowClick(run)
    if not test.ov then return end
    local raced = test.attached or test.run
    if run == raced then
        if test.ov.pinned then KG.Overtake.Unpin(test.ov) else KG.Overtake.Pin(test.ov) end
    else
        KG.Overtake.ManualSwitch(test.ov, run)
        test.attached = run
        test.lastSwitch = { at = GetTime(), run = run }
    end
end
