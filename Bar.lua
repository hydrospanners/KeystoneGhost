-- The race bar — the addon's one at-a-glance visual.
--
-- THE ROAD (v4, DESIGN "The road-race track"): the track is the DUNGEON in course
-- space — road length = 100 forces-units + nBosses × BOSS_UNITS; a runner's position
-- is its progress (GhostMath.CoursePos), one shared finish line at the right edge.
-- Seen through the Mario camera (GhostMath.Camera): YOU sit at the ¼ anchor while
-- the road scrolls toward you; the camera hits the wall at both ends. On the road:
--   · milestone skulls where the RACED ghost made its i-th kill — anonymous ghost
--     history (fade by your kill COUNT), never a claim about which boss is next
--   · pace cars driving at +3/+2/+1 pace; the red +1 sweeper = deplete pressure
--   · roster runners (small, below the line) — every stored rival races visibly
--   · the gap zone between you and the raced ghost — green ahead, grey→red behind
--     by depletion danger; the numeric delta comes from timeline inversion
--     (GhostTimeFor: earliest time the ghost had ≥ your forces% AND boss count)
--   · death knockback: penalty-scaled, debounced, icon-local (cosmetic only)
-- Positioning is Edit Mode territory (EditMode.lua): the frame is not mouse-draggable
-- outside of it. Attach mode instead docks the bar under the EllesmereUI M+ timer.
local ADDON_NAME, NS = ...
local KG = NS.KG
local M = KG.Math
local Style = KG.Style

local Bar = {}
KG.Bar = Bar

-- Design grammar (DESIGN.md "Design language"): current/"my" marks above the track,
-- ghost-owned marks on the track's bottom edge and below it (flowing toward the ghost
-- roster panel underneath), full track height reserved for Relationship (cursor lines,
-- gap zone) and course-wide elements (pace cars, finish line).
local WIDTH, BAR_H, TRACK_H, PAD = 360, 115, 16, 12
-- MARIO'S OWN LANE (Fredrik 2026-07-27, option C1 — alternatives in
-- docs/UNTESTED.md's decision log): his icon stands in the 18 px band directly
-- above the track, and the Count Gap used to be printed in that same band, which
-- is why a raid marker sat on the numbers. The track drops to 57 (frame grew 96 →
-- 115) so the band belongs to him alone; the readouts keep their frame-top
-- positions, which is what NUM_TOP_Y / NUM_SUB_Y hold — PlaceNumbers anchors from
-- the track, so they are converted, never hardcoded twice.
local TRACK_Y, NUM_TOP_Y, NUM_SUB_Y = 57, 4, 20
local frame

-- Pull-indicator overflow (his screenshots 2026-08-09: a long route name walked
-- out of the window). Measured per refresh — GetStringWidth vs the frame's inner
-- width — and when the one-liner does not fit, the pull half drops to its own
-- row and the bar GROWS that row. State + setter forward-declared: the Update
-- hot path decides, the position code (defined later) applies.
local PULL_LINE_H = 13
local pullWrapped = false
local SetPullWrap

-- Out-of-bounds hatching, bundled rather than borrowed (32x32, tileable, 45°): the
-- road behind the Sweeper wears it in the Sweeper's red. (A grey run-off wall wore it
-- too for a day; that is gone, this is not.)
local HATCH = "Interface\\AddOns\\KeystoneGhost\\sweeper-stripes.tga"
local HATCH_TILE = 32
local SWEPT_WAKE = 0.13 -- the sweeper's red wake, as a fraction of the track (~44 px)

-- Style.GREEN / Style.RED / Splits-grey as inline escapes — for coloring single
-- tokens inside an otherwise neutral FontString. The verdict pair is built PER
-- CALL: these were frozen literals of the DEFAULT pair (`4dcc4d`/`e65959`), so the
-- Pull Indicator went on speaking red/green after the color-vision setting had
-- swapped every other verdict on screen (2026-07-29 sweep). The grey is not a
-- verdict and stays fixed.
local GreenHex, RedHex = Style.GoodEscape, Style.BadEscape
local GRAY_HEX = "|cff8c8c8c"

-- ── Test mode: synthetic ghost + simulated player so the bar can be inspected anywhere ──
local TEST_SPEED = 10 -- 10x: a ~28min run demos in ~3min; 20x made real data look jerky
local test = {}

--- Prefer REAL recordings for the test race: the demo follows your FRESHEST dungeon
--- (the map whose newest run is newest overall — Fredrik 2026-07-20: the set you just
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

--- One demo loop's cast, ALTERNATING scenarios per loop (Fredrik 2026-07-20 — the
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
--- anyone whose real runs went well (Fredrik 2026-07-22: he raced the RIO loop
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
            print("|cff88ccffKeystoneGhost|r: test loop — Raider.IO ghost only (the first-run look).")
        end
    else
        test.rioRef = nil
        test.simRun = SimRunOf(test.run)
        test.rival = EnsureDemoDeaths(CopyScaled(test.run, 0.65, 3))
        test.ov = KG.Overtake.New(test.run, false)
        test.attached = test.run
        if KG.testMode then
            print("|cff88ccffKeystoneGhost|r: test loop — full roster (your real ghosts when stored).")
        end
    end
    test.lastSwitch = nil
    test.start = GetTime()
end

--- /kg test re-enable: restart the scenario rotation at loop 1 and re-scan the DB
--- (a run recorded since the last toggle joins the demo).
function Bar.ResetTestLoop()
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
    test.run3 = CopyScaled(test.run, 0.926, 3, "Boonkerz-TarrenMill-DRUID")  -- imported +3, 25:00
    test.par = par
    -- 12 even pulls over a 300-count dungeon for the pull indicator preview; the
    -- createdBy sample shows the class-colored creator token in the demo.
    test.route = { cumulativeForces = {}, nPulls = 12, name = "Test route",
        createdBy = { name = "Boonkerz", classFile = select(2, UnitClass("player")) } }
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

    -- Simulated group deaths (Fredrik 2026-07-19: verify the Knockback + Death Pot in
    -- the demo): one stumble, then a pot-gathered double, then one more. Paced at
    -- fractions of the run so the rate stays ~1-3 deaths per 10 minutes whatever the
    -- base recording's length (Fredrik 2026-07-23: every-30s was a wipefest).
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
            roster = { { run = test.rioRef.run, tag = "RIO" } },
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
        roster = roster,
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
        level = test.run.level, par = test.par,
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

--- Shared live state for the bar and the splits panel (nil when nothing to race).
--- Edit Mode preview reuses the synthetic test race so the frame has something to show.
function Bar.GetLiveState()
    if KG.testMode or KG.editModePreview or KG.introMode then
        -- The demo photo hold fences the whole demo race (council 2026-08-09):
        -- while the hold stands, TestState must not run — its own wrap check
        -- would reseed the loop mid-hold (double seeds, the rio loop skipped,
        -- two chat lines per wrap) and the roster panel would draw the NEXT
        -- loop over the End Screen's slot. Nil here hides the roster for the
        -- hold, which is the design contract anyway (the two windows replace
        -- each other). Edit Mode preview outranks the hold: opening it
        -- dismisses the photo and hands the preview the live demo bar.
        if test.summary then
            if KG.editModePreview then DismissTestPhoto() else return nil end
        end
        return TestState()
    end
    local R = KG.Recorder
    if not R:IsActive() or not R.currentRef then return nil end
    local elapsed = R:GetElapsed()
    local pct, bosses = R:GetProgress()
    if not elapsed then return nil end
    local liveNames, liveCounts, seededKills, liveIDs = R:GetBossMeta()
    local raw, total = R:GetRawForces()
    local mapID, level = R:GetContext()
    local route = R:GetRoute()
    return {
        elapsed = elapsed, pct = pct, bosses = bosses, liveKills = R:GetBossKills(),
        liveNames = liveNames, liveCounts = liveCounts, seededKills = seededKills, liveIDs = liveIDs,
        liveRun = R:GetLiveRun(), raw = raw, total = total, route = route,
        deaths = R:GetDeaths(), -- {t, running deaths} — the tombstone Death Markers
        trackerPull = R:GetTrackerPull(),
        -- Stable roster: keyed to YOUR route, never to the raced ghost — a switch
        -- moves the highlight, not the rows (Fredrik 2026-07-20).
        roster = mapID and KG.Ghosts:GetRoster(mapID, level, route and route.name) or nil,
        -- Rows drawn earlier this key: they keep their place even after the roster
        -- stops offering them (Fredrik 2026-07-29 — nothing leaves mid-key).
        shown = R:ShownRows(), level = level,
        deathCount = R:GetDeathCountLive(), deathTimeLost = select(2, R:GetDeathCountLive()),
        par = R:GetParTime(), ref = R.currentRef,
        lastSwitch = R.lastSwitch, pinned = R:IsPinned(),
    }
end
local LiveState = Bar.GetLiveState

-- ── Frame construction ─────────────────────────────────────────────────────────
local function Tick(parent, color, w, a)
    local t = parent:CreateTexture(nil, "ARTWORK")
    t:SetTexture("Interface\\Buttons\\WHITE8x8")
    t:SetVertexColor(color[1], color[2], color[3], a or 0.9)
    t:SetSize(w or 2, TRACK_H)
    return t
end

local Hover = Style.Hover

local function HoverTick(parent, color, a)
    local f = Hover(parent, 10, TRACK_H + 6)
    f.tex = f:CreateTexture(nil, "ARTWORK")
    f.tex:SetTexture("Interface\\Buttons\\WHITE8x8")
    f.tex:SetVertexColor(color[1], color[2], color[3], a or 0.9)
    f.tex:SetSize(2, TRACK_H)
    f.tex:SetPoint("CENTER")
    return f
end

local function Build()
    frame = CreateFrame("Frame", "KeystoneGhostBar", UIParent, "BackdropTemplate")
    frame:SetSize(WIDTH, BAR_H)
    frame:SetPoint("CENTER", UIParent, "CENTER", 0, 260)
    frame:SetMovable(true)      -- moved via Edit Mode (EditMode.lua), not free drag
    frame:EnableMouse(false)
    frame:SetClampedToScreen(true)
    Style.SkinPanel(frame)

    frame.refLabel = frame:CreateFontString(nil, "OVERLAY")
    frame.refLabel:SetPoint("TOPLEFT", PAD, -6)
    frame.refLabel:SetWordWrap(false)
    Style.SetFont(frame.refLabel, 10)
    frame.refLabel:SetTextColor(Style.TEXT[1], Style.TEXT[2], Style.TEXT[3])

    frame.delta = frame:CreateFontString(nil, "OVERLAY")
    frame.delta:SetPoint("TOPRIGHT", -PAD - 3, -NUM_TOP_Y)
    Style.SetFont(frame.delta, 13)

    -- Count delta lives directly under the time delta (one glance, both dimensions).
    frame.subDelta = frame:CreateFontString(nil, "OVERLAY")
    frame.subDelta:SetPoint("TOPRIGHT", -PAD - 3, -NUM_SUB_Y)
    Style.SetFont(frame.subDelta, 10)

    frame.track = CreateFrame("Frame", nil, frame)
    frame.track:SetPoint("TOPLEFT", PAD, -TRACK_Y)
    frame.track:SetPoint("TOPRIGHT", -PAD, -TRACK_Y) -- width follows the frame (attach mode resizes it)
    frame.track:SetHeight(TRACK_H)
    local bg = frame.track:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetTexture("Interface\\Buttons\\WHITE8x8")
    local bb = Style.BAR_BG
    bg:SetVertexColor(bb[1], bb[2], bb[3], bb[4])

    -- Pace cars: moving marks that drive the road at +3 / +2 / +1 (par) pace — colors
    -- and positions applied per update. On a road there are no static time positions.
    -- Each carries its tag inside the track: three identical hairlines told you
    -- nothing about which was which ("I can't tell what they are" — Fredrik 2026-07-26).
    frame.paceCars = {
        HoverTick(frame.track, Style.TICK1, 0.4),
        HoverTick(frame.track, Style.TICK1, 0.4),
        HoverTick(frame.track, Style.TICK1, 0.4),
    }
    for _, car in ipairs(frame.paceCars) do
        car.label = car:CreateFontString(nil, "OVERLAY")
        Style.SetFont(car.label, 9)
        -- Placed per update: normally "+1 |", to the LEFT of the hairline (Fredrik
        -- 2026-07-26 — on the line it was unreadable), flipping to the right only
        -- when the car is pinned at the left edge and there is no room.
    end

    -- THE SWEPT ROAD (Fredrik 2026-07-26, and the only survivor of the run-off wall
    -- it was built alongside — "leave the striped area after the last pace car"): a
    -- diagonal hatch in the Sweeper's own red, on the road BEHIND the +1 car — the
    -- ground it has just taken, fading out backwards.
    --
    -- A WAKE, not a fill: filling everything left of the sweeper was the first build
    -- and by the end of a dungeon it painted more than half the track red on a run
    -- that was three minutes AHEAD, competing with the gap zone for the same alarm.
    -- It also said nothing the car's own position doesn't — your course only ever
    -- increases, so swept road behind you can't be re-entered. Bounded, it reads as
    -- the sweeper eating the road. Under the gap zone in draw order: the verdict
    -- color stays the loudest thing on the track.
    --
    -- The art is a BUNDLED 32x32 TGA, not a guessed Blizzard atlas — our own file
    -- cannot turn out to be invisible on a live client, and the track has no other
    -- diagonal art to borrow. Tiled via REPEAT wrap + texcoords at 1:1 pixel scale,
    -- so the stripes hold 45° whatever width the bar is docked at.
    frame.sweptZone = frame.track:CreateTexture(nil, "BACKGROUND", nil, 3)
    frame.sweptZone:SetTexture(HATCH, "REPEAT", "REPEAT")
    -- The wake's red is the VERDICT red, not a literal copy of it: the Gap Zone's
    -- angry-sweeper ramp already derived from Style.RED, so a hardcoded wake meant
    -- the two reds parted company the moment the color-vision setting changed
    -- (2026-07-29 sweep). ApplyGradient re-tints it when the palette moves.
    frame.sweptZone:SetGradient("HORIZONTAL",
        CreateColor(Style.RED[1], Style.RED[2], Style.RED[3], 0.12),
        CreateColor(Style.RED[1], Style.RED[2], Style.RED[3], 0.9))
    frame.sweptZone:Hide()
    frame.bossTicks = {}
    frame.runners = {} -- roster ghosts drawn as small racers below the line

    -- The finish line: scrolls in from the right when the camera reaches the wall.
    frame.finishLine = Tick(frame.track, { 1, 1, 1 }, 3, 0.9)
    frame.finishLine:Hide()

    -- Zone between the two cursors: its width is your lead/deficit and its color the
    -- verdict — the single fastest thing to read on the whole bar. One translucent
    -- gradient area, faint at the ghost's side and strongest at YOURS (SetGradient +
    -- CreateColor, verified against EllesmereUI's own usage; WHITE8x8 base so it can't
    -- fail to render like the tiled stripe texture did).
    frame.gapZone = frame.track:CreateTexture(nil, "BORDER")
    frame.gapZone:SetTexture("Interface\\Buttons\\WHITE8x8")
    frame.gapZone:SetHeight(TRACK_H)
    frame.gapZone._faint = CreateColor(0, 0, 0, 0.1)
    frame.gapZone._strong = CreateColor(0, 0, 0, 0.55)

    frame.ghostCursor = Tick(frame.track, { Style.GetAccent() }, 2, 0.95)
    frame.ghostHover = Hover(frame.track, 24, 24)
    -- Round class icon: "whose ghost is this" at a glance (RaiderIO logo for replays,
    -- pocket watch for pace ghosts). The gold ring retired 2026-07-20: it paired with
    -- the roster's gold plate, and with that gone it indicated nothing — the badge
    -- reads by position (on the accent cursor), size, and full brightness.
    frame.ghostIcon = frame.ghostHover:CreateTexture(nil, "OVERLAY")
    frame.ghostIcon:SetSize(16, 16)
    frame.ghostIcon:SetPoint("CENTER")
    frame.ghostIcon:SetTexture("Interface\\Icons\\INV_Misc_PocketWatch_01")
    frame.ghostIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    -- The ghost's own Dazed (Fredrik 2026-07-22, with the tombstones): when the
    -- raced ghost reaches one of its deaths it wobbles, exactly like Mario does.
    -- The wobble is the READABLE half of a ghost death — the costly half already
    -- happens for free, because a recorded timeline stalls for the penalty (the
    -- official clock jumps, so the recording carries it). No knockback for the
    -- ghost: it never moved backwards down the road, it stood still, and paying
    -- the same second twice would be a lie. Same recipe as frame.dazedAnim.
    local gDazed = frame.ghostIcon:CreateAnimationGroup()
    gDazed:SetLooping("REPEAT")
    local g1 = gDazed:CreateAnimation("Rotation")
    g1:SetDegrees(6); g1:SetDuration(0.12); g1:SetOrder(1); g1:SetSmoothing("IN_OUT")
    local g2 = gDazed:CreateAnimation("Rotation")
    g2:SetDegrees(-12); g2:SetDuration(0.24); g2:SetOrder(2); g2:SetSmoothing("IN_OUT")
    local g3 = gDazed:CreateAnimation("Rotation")
    g3:SetDegrees(6); g3:SetDuration(0.12); g3:SetOrder(3); g3:SetSmoothing("IN_OUT")
    frame.ghostDazed = gDazed

    -- Click the badge: load the raced ghost's embedded route into MDT (confirm
    -- popup; silent when the ghost carries none — the tooltip says when it does).
    frame.ghostHover:SetScript("OnMouseUp", function(_, button)
        if button == "LeftButton" then Bar.TryLoadRacedRoute() end
    end)

    frame.playerCursor = Tick(frame.track, Style.GREEN, 2, 1)
    frame.playerHover = Hover(frame.track, 20, 18)
    frame.playerIcon = frame.playerHover:CreateTexture(nil, "OVERLAY")
    frame.playerIcon:SetSize(16, 16)
    frame.playerIcon:SetPoint("CENTER")
    -- THE MARKER HAT (easter egg, Fredrik 2026-07-28; Options panel "Raid marker as
    -- a hat" — panel, not Edit Mode: it changes what the icon WEARS, not layout):
    -- with the option on, the face keeps the portrait and a carried raid
    -- target marker perches up here instead — 8 px, overlapping the head's top edge
    -- like a crown. Deliberately NOT animated with the walk cycle (the hop moves
    -- only the icon texture; anchors don't follow animations), so the head bounces
    -- under a floating hat — upgrade the hat to hopping only if that reads wrong in
    -- the field. Painted/hidden by RefreshPlayerIcon, which owns every marker rule.
    frame.markerHat = frame.playerHover:CreateTexture(nil, "OVERLAY", nil, 1)
    frame.markerHat:SetSize(8, 8)
    frame.markerHat:SetPoint("BOTTOM", frame.playerIcon, "TOP", 0, -2)
    frame.markerHat:Hide()
    Bar.RefreshPlayerIcon(true)

    -- The walk cycle ("it would be fking hilarious" — Fredrik, verbatim): a tiny hop
    -- while you're actually moving down the road. Stops when your course freezes —
    -- so you visibly STAND at a boss while fighting it. Options-panel toggle
    -- (swept from Edit Mode 2026-07-28 — display, not layout).
    local walk = frame.playerIcon:CreateAnimationGroup()
    walk:SetLooping("REPEAT")
    local hop = walk:CreateAnimation("Translation")
    hop:SetOffset(0, 2.5); hop:SetDuration(0.16); hop:SetOrder(1); hop:SetSmoothing("OUT")
    local land = walk:CreateAnimation("Translation")
    land:SetOffset(0, -2.5); land:SetDuration(0.16); land:SetOrder(2); land:SetSmoothing("IN")
    frame.walkAnim = walk

    -- Dazed (DESIGN follow-up): while the icon recovers from a death Knockback it
    -- wobbles — the death-penalty period reads on the character itself, not just as
    -- lost ground. Net rotation per loop is zero, so stopping never leaves a tilt.
    -- SLIGHT by order (Fredrik field verdict 2026-07-20 evening): recovery walks
    -- the icon back while dazed, so hop + rotation play together — at ±18° that
    -- read as "walking does half-rotations". The walk itself never rotates; the
    -- wobble stays death-only and subtle.
    local dazed = frame.playerIcon:CreateAnimationGroup()
    dazed:SetLooping("REPEAT")
    local r1 = dazed:CreateAnimation("Rotation")
    r1:SetDegrees(6); r1:SetDuration(0.12); r1:SetOrder(1); r1:SetSmoothing("IN_OUT")
    local r2 = dazed:CreateAnimation("Rotation")
    r2:SetDegrees(-12); r2:SetDuration(0.24); r2:SetOrder(2); r2:SetSmoothing("IN_OUT")
    local r3 = dazed:CreateAnimation("Rotation")
    r3:SetDegrees(6); r3:SetDuration(0.12); r3:SetOrder(3); r3:SetSmoothing("IN_OUT")
    frame.dazedAnim = dazed

    -- No elapsed clock: every M+ timer addon shows it; internally elapsed stays the
    -- recorder's backbone. Bottom row is the pull indicator only.
    frame.pullText = frame:CreateFontString(nil, "OVERLAY")
    frame.pullText:SetPoint("BOTTOM", 0, 6)
    Style.SetFont(frame.pullText, 10)
    -- The overflow row (2026-08-09): when the route line is too wide, the
    -- "Pull #n vs Ghost #n" half moves down here and the frame adds the row.
    frame.pullText2 = frame:CreateFontString(nil, "OVERLAY")
    frame.pullText2:SetPoint("BOTTOM", 0, 6)
    Style.SetFont(frame.pullText2, 10)
    frame.pullText2:Hide()

    -- Close button for the post-run summary (hidden during a run) — the same ×
    -- the Ghost Library wears, not the default red X (Fredrik 2026-07-21).
    frame.closeBtn = Style.CloseButton(frame, function()
        if test.summary then
            -- The demo photo's ×: skip to the next loop ONLY. A real run's
            -- pending summary survives underneath (council 2026-08-09: this
            -- handler used to nil it unconditionally, and the demo hold was
            -- the first time test mode ever showed the button).
            DismissTestPhoto()
        else
            KG.Recorder.summary = nil
        end
        Bar:Refresh()
    end)
    frame.closeBtn:SetPoint("TOPRIGHT", -1, -1)
    frame.closeBtn:Hide()

    -- The Finish Stats + celebration (his order 2026-08-09, "mario-esque"):
    -- while a photo is up the TRACK hides whole — cursors, gap zone, skulls
    -- and the ghost badge ride with it — and this board stands in the road's
    -- band: stat lines on the left, a checkered finish flag with a hopping
    -- portrait on the right. One container, so the photo path shows and
    -- hides it in one move. The flag is DRAWN from WHITE8x8 squares — no
    -- atlas to trust, nothing new to bundle, it cannot not-render (the
    -- eye-icon lesson).
    frame.photoBoard = CreateFrame("Frame", nil, frame)
    frame.photoBoard:SetPoint("TOPLEFT", 0, -38)
    frame.photoBoard:SetPoint("BOTTOMRIGHT")
    frame.statLines = {}
    for i = 1, 4 do
        local fs = frame.photoBoard:CreateFontString(nil, "OVERLAY")
        fs:SetPoint("TOPLEFT", PAD, -4 - (i - 1) * 17)
        fs:SetJustifyH("LEFT")
        fs:SetWordWrap(false)
        Style.SetFont(fs, 10)
        fs:SetTextColor(Style.TEXT[1], Style.TEXT[2], Style.TEXT[3])
        frame.statLines[i] = fs
    end
    -- The flag, planted where the road's finish line stood. His question
    -- 2026-08-09: "isn't there an existing finish flag?" — there is: the
    -- skyriding races' checkered flag, atlas `worldquest-icon-race`, and
    -- Blizzard's own LIVE quest log draws it (QuestUtils.lua, the map's race
    -- icon), which is render-proof by their code, not grep-faith by ours.
    -- Still behind the runtime check (the eye-icon rule): resolves → the
    -- game's flag; a future patch renames it → the drawn pole-and-checker
    -- stands again. Either way a flag renders.
    local flag = CreateFrame("Frame", nil, frame.photoBoard)
    flag:SetSize(30, 48)
    flag:SetPoint("BOTTOMRIGHT", -PAD - 4, 6)
    if C_Texture and C_Texture.GetAtlasInfo
        and select(1, pcall(C_Texture.GetAtlasInfo, "worldquest-icon-race"))
        and C_Texture.GetAtlasInfo("worldquest-icon-race") then
        local cloth = flag:CreateTexture(nil, "ARTWORK")
        cloth:SetAtlas("worldquest-icon-race")
        cloth:SetSize(30, 30)
        -- Bottom-anchored on his 2026-08-10 call: top-anchored in the 48 px
        -- frame the flag floated 16 px above the hopping head; now both stand
        -- on the same baseline (the head's rest pose — the hop leaves it).
        cloth:SetPoint("BOTTOM", 0, 0)
    else
        local pole = flag:CreateTexture(nil, "ARTWORK")
        pole:SetTexture("Interface\\Buttons\\WHITE8x8")
        pole:SetVertexColor(0.75, 0.75, 0.78, 1)
        pole:SetSize(2, 46)
        pole:SetPoint("BOTTOMLEFT", 0, 0)
        for r = 0, 5 do
            for c = 0, 7 do
                local sq = flag:CreateTexture(nil, "OVERLAY")
                sq:SetTexture("Interface\\Buttons\\WHITE8x8")
                sq:SetSize(3, 3)
                sq:SetPoint("TOPLEFT", 3 + c * 3, -1 - r * 3)
                if (r + c) % 2 == 0 then
                    sq:SetVertexColor(0.10, 0.10, 0.12, 1)
                else
                    sq:SetVertexColor(0.92, 0.92, 0.94, 1)
                end
            end
        end
    end
    frame.flag = flag
    -- Mario on the podium: a second portrait beside the flag. Timed key = the
    -- victory hop (the walk-cycle recipe, taller and with a landing beat);
    -- Depleted = the Dazed wobble instead, flagless — he showed up, the timer
    -- won. Painted and started once per summary (gated on s.at in ShowSummary).
    frame.cheer = frame.photoBoard:CreateTexture(nil, "OVERLAY")
    frame.cheer:SetSize(20, 20)
    frame.cheer:SetPoint("BOTTOMRIGHT", flag, "BOTTOMLEFT", -10, 0)
    local jump = frame.cheer:CreateAnimationGroup()
    jump:SetLooping("REPEAT")
    local up = jump:CreateAnimation("Translation")
    up:SetOffset(0, 7); up:SetDuration(0.22); up:SetOrder(1); up:SetSmoothing("OUT")
    local down = jump:CreateAnimation("Translation")
    down:SetOffset(0, -7); down:SetDuration(0.2); down:SetOrder(2); down:SetSmoothing("IN")
    local rest = jump:CreateAnimation("Translation")
    rest:SetOffset(0, 0); rest:SetDuration(0.35); rest:SetOrder(3)
    frame.cheerJump = jump
    local sulk = frame.cheer:CreateAnimationGroup()
    sulk:SetLooping("REPEAT")
    local s1 = sulk:CreateAnimation("Rotation")
    s1:SetDegrees(6); s1:SetDuration(0.12); s1:SetOrder(1); s1:SetSmoothing("IN_OUT")
    local s2 = sulk:CreateAnimation("Rotation")
    s2:SetDegrees(-12); s2:SetDuration(0.24); s2:SetOrder(2); s2:SetSmoothing("IN_OUT")
    local s3 = sulk:CreateAnimation("Rotation")
    s3:SetDegrees(6); s3:SetDuration(0.12); s3:SetOrder(3); s3:SetSmoothing("IN_OUT")
    frame.cheerSulk = sulk
    frame.photoBoard:Hide()

    -- The End Screen (Fredrik 2026-08-07, growing his 2026-08-06 share shelf):
    -- the panel hanging under the photo in the Roster Panel's slot — the
    -- roster's live state is nil while a photo is up, so the two windows
    -- replace each other. Content, top to bottom: the total-time header with
    -- its margin against the timer, up to three frozen roster-style rows
    -- (you + the two ghosts that finished closest to your clock — the
    -- Recorder snapshots them into summary.rows), and the share row, which
    -- names its channel on the face ("Guild"/"Group" next to the glyph).
    -- Widgets built once here; ShowSummary paints and sizes per pass.
    frame.endPanel = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    frame.endPanel:SetPoint("TOPLEFT", frame, "BOTTOMLEFT", 0, -4)
    frame.endPanel:SetPoint("TOPRIGHT", frame, "BOTTOMRIGHT", 0, -4)
    frame.endPanel:SetHeight(32)
    Style.SkinPanel(frame.endPanel)

    frame.endHeader = frame.endPanel:CreateFontString(nil, "OVERLAY")
    frame.endHeader:SetPoint("TOPLEFT", PAD, -7)
    frame.endHeader:SetWordWrap(false)
    Style.SetFont(frame.endHeader, 11)
    frame.endHeader:SetTextColor(Style.TEXT[1], Style.TEXT[2], Style.TEXT[3])

    -- The result rows: the Roster Panel's column grammar (icon · name · key ·
    -- chest · time) plus a final "vs you" delta in the roster's sign language
    -- (positive = you finished ahead). Fixed x-offsets — five columns fit any
    -- width the bar itself can reach, so no spill logic down here.
    local function EndCol(parent, x, w)
        local fs = parent:CreateFontString(nil, "OVERLAY")
        fs:SetPoint("LEFT", x, 0)
        fs:SetWidth(w)
        fs:SetJustifyH("LEFT")
        fs:SetWordWrap(false)
        Style.SetFont(fs, 10)
        fs:SetTextColor(Style.TEXT[1], Style.TEXT[2], Style.TEXT[3])
        return fs
    end
    frame.endRows = {}
    for i = 1, 3 do
        local row = CreateFrame("Frame", nil, frame.endPanel)
        local y = -(24 + (i - 1) * 15)
        row:SetPoint("TOPLEFT", PAD, y)
        row:SetPoint("TOPRIGHT", -PAD, y)
        row:SetHeight(15)
        row.icon = row:CreateTexture(nil, "OVERLAY")
        row.icon:SetSize(12, 12)
        row.icon:SetPoint("LEFT", 1, 0)
        row.name = EndCol(row, 18, 48)
        row.level = EndCol(row, 66, 26)
        row.chest = EndCol(row, 92, 30)
        row.time = EndCol(row, 122, 40)
        row.vs = EndCol(row, 162, 48)
        frame.endRows[i] = row
    end

    -- The share glyph (Fredrik 2026-08-06; onto YOUR row 2026-08-08): the
    -- Library's arrow-out-of-tray at the right edge of the board's "you" row —
    -- the row it sits on IS the run it shares. No face label (his call: a
    -- word doesn't fit a 15 px row line); the tooltip names the channel.
    -- Shown only when the photo's run is shareable (summary.share) and the
    -- option is on; the click speaks the chat-share marker into the configured
    -- channel. The 2 s guard turns a double-click into one chat line, not two.
    -- Anchored to the you-row per paint — the sort decides which row that is.
    frame.shareBtn = CreateFrame("Button", nil, frame.endPanel)
    frame.shareBtn:SetSize(16, 16)
    frame.shareBtn.tex = frame.shareBtn:CreateTexture(nil, "ARTWORK")
    frame.shareBtn.tex:SetSize(14, 14)
    frame.shareBtn.tex:SetPoint("CENTER")
    frame.shareBtn.tex:SetTexture("Interface\\AddOns\\KeystoneGhost\\share-icon.tga")
    frame.shareBtn:SetAlpha(0.75)
    frame.shareBtn:SetScript("OnEnter", function(self)
        self:SetAlpha(1)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(self.tipText, 0.9, 0.9, 0.9)
        GameTooltip:Show()
    end)
    frame.shareBtn:SetScript("OnLeave", function(self)
        self:SetAlpha(0.75)
        GameTooltip:Hide()
    end)
    frame.shareBtn:SetScript("OnClick", function(self)
        local sh = KG.Recorder.summary and KG.Recorder.summary.share
        if not sh or not KG.Comm then return end
        if GetTime() - (self.lastSend or 0) < 2 then return end
        if KG.Comm.SendShare(KG.CharacterKey(), sh.mapID, sh.level, sh.tier, sh.pretty) then
            self.lastSend = GetTime()
        end
    end)
    frame.endPanel:Hide()


    Bar.ApplyScale()
    frame.elapsedThrottle = 0
    frame:SetScript("OnUpdate", function(f, dt)
        f.elapsedThrottle = f.elapsedThrottle + dt
        if f.elapsedThrottle < 0.1 then return end
        f.elapsedThrottle = 0
        Bar:Refresh() -- routes to Update or the post-run summary as appropriate
    end)
    frame:Hide()
end

--- Roster runners: each non-raced roster ghost drawn as a small racer on the road,
--- wearing its roster pairing ring (Style.PULL_COLORS by roster order).
local function Runner(i, colorIdx)
    local f = frame.runners[i]
    if not f then
        f = Hover(frame.track, 16, 16)
        -- ROUND pairing plate (Fredrik 2026-07-20, Live Test 1: square frames read
        -- as clutter — "make them a round border or remove the color"). A tinted
        -- circle texture (the Details-proven TempPortraitAlphaMaskSmall trick);
        -- the round class icon on top leaves it visible as a ~2 px ring.
        f.border = f:CreateTexture(nil, "ARTWORK")
        f.border:SetSize(16, 16)
        f.border:SetPoint("CENTER")
        f.border:SetTexture("Interface\\CHARACTERFRAME\\TempPortraitAlphaMaskSmall")
        f.tex = f:CreateTexture(nil, "OVERLAY")
        f.tex:SetSize(12, 12)
        f.tex:SetPoint("CENTER")
        frame.runners[i] = f
    end
    -- Pairing color keyed to the ghost's STABLE roster position (colorIdx), not
    -- the lane ordinal: a Raced-Ghost Switch must never recolor the survivors.
    local c = Style.PULL_COLORS[((colorIdx or i) - 1) % #Style.PULL_COLORS + 1]
    f.border:SetVertexColor(c[1], c[2], c[3])
    return f
end

--- The RaiderIO logo texture path, or nil — hoisted to Style.RaiderIOLogo
--- (2026-07-21) so the Library owner cell shares it; alias kept for the two
--- call sites below.
local function RaiderIOLogo()
    return Style.RaiderIOLogo()
end

local function ApplyRunnerIcon(tex, run)
    if run.legacy == "RIO" then -- the Raider.IO ghost as a roster row/runner
        local logo = RaiderIOLogo()
        if logo then
            tex:SetTexture(logo)
            tex:SetTexCoord(0, 1, 0, 1)
            return
        end
        -- logo unreadable (RaiderIO uninstalled, cached ghost racing): the watch —
        -- NEVER the player-class fallback below, that claims the run is yours
        tex:SetTexture("Interface\\Icons\\INV_Misc_PocketWatch_01")
        tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        return
    end
    local token = (run.importedFrom and run.importedFrom:match("%-([^%-]+)$"))
        or select(2, UnitClass("player"))
    local coords = token and _G.CLASS_ICON_TCOORDS and _G.CLASS_ICON_TCOORDS[token]
    if coords then
        tex:SetTexture("Interface\\TargetingFrame\\UI-Classes-Circles")
        tex:SetTexCoord(coords[1], coords[2], coords[3], coords[4])
    else
        tex:SetTexture("Interface\\Icons\\INV_Misc_PocketWatch_01")
        tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    end
end
Bar.ApplyRunnerIconTo = ApplyRunnerIcon -- (tex, run) — roster rows mirror their runner

--- Ghost cursor icon by reference kind: character ghosts (own / imported) show the
--- round class icon — class COLOR block as fallback when the icon coords are
--- unavailable; the RaiderIO replay wears the RaiderIO logo; pace ghosts the watch.
--- (The raid marker belongs to the PLAYER cursor — mixed up once, 2026-07-19.
--- Iteration idea on file: a faded portrait of the ghost's character.)
local function ApplyGhostIcon(iconTex, ref)
    local key = ref.kind .. "|" .. tostring(ref.run and ref.run.importedFrom or "")
    if iconTex._kgIconKey == key then return end
    iconTex._kgIconKey = key
    iconTex:SetSize(16, 16)

    local classToken
    if ref.kind == "personal" or ref.kind == "test" then
        classToken = select(2, UnitClass("player"))
    elseif ref.kind == "import" and ref.run and ref.run.importedFrom then
        classToken = ref.run.importedFrom:match("%-([^%-]+)$")
    end
    -- Bright round class icon (a TINTED disc rendered muddy-dark in the field —
    -- vertex color multiplies, it can't brighten — so the icon must be bright itself).
    local coords = classToken and _G.CLASS_ICON_TCOORDS and _G.CLASS_ICON_TCOORDS[classToken]
    if coords then
        iconTex:SetTexture("Interface\\TargetingFrame\\UI-Classes-Circles")
        iconTex:SetTexCoord(coords[1], coords[2], coords[3], coords[4])
        iconTex:SetVertexColor(1, 1, 1)
        return
    end
    local color = classToken and _G.RAID_CLASS_COLORS and _G.RAID_CLASS_COLORS[classToken]
    if color then -- class-color fallback when icon coords are missing
        iconTex:SetTexture("Interface\\Buttons\\WHITE8x8")
        iconTex:SetTexCoord(0, 1, 0, 1)
        iconTex:SetVertexColor(color.r, color.g, color.b)
        iconTex:SetSize(12, 12)
        return
    end

    -- RaiderIO ghost wears the RaiderIO logo; watch as fallback for it and pace ghosts.
    if ref.kind == "rio" then
        local logo = RaiderIOLogo()
        if logo then
            iconTex:SetTexture(logo)
            iconTex:SetTexCoord(0, 1, 0, 1)
            iconTex:SetVertexColor(1, 1, 1)
            return
        end
    end
    iconTex:SetTexture("Interface\\Icons\\INV_Misc_PocketWatch_01")
    iconTex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    iconTex:SetVertexColor(1, 1, 1)
end
Bar.ApplyRefIconTo = ApplyGhostIcon -- (iconTex, ref) — the raced row mirrors the badge

--- Roster-hover preview target (Splits sets/clears this).
function Bar.SetPreviewRun(run)
    Bar._previewRun = run
end

--- Roster Panel row click → the Raced-Ghost Switch (S9): a non-raced row switches
--- AND pins; the raced row toggles the pin. Test mode drives the demo's Overtake
--- state so the whole flow is clickable in /kg test; live clicks go to the Recorder.
function Bar.HandleRowClick(run)
    if not run then return end
    if KG.testMode or KG.editModePreview or KG.introMode then
        if not test.ov then return end
        local raced = test.attached or test.run
        if run == raced then
            if test.ov.pinned then KG.Overtake.Unpin(test.ov) else KG.Overtake.Pin(test.ov) end
        else
            KG.Overtake.ManualSwitch(test.ov, run)
            test.attached = run
            test.lastSwitch = { at = GetTime(), run = run }
        end
    else
        KG.Recorder:HandleRowClick(run)
    end
    Bar:Refresh()
    KG.Splits:Refresh()
end

--- The badge click ("WHAT IF you could click that and it would be the route?!" —
--- Fredrik 2026-07-20): resolve the raced ghost's Route Store entry (live race or
--- Finish Photo) and hand it to the confirm-then-load flow. No-op without one.
function Bar.TryLoadRacedRoute()
    local st = LiveState()
    local ref = (st and st.ref) or (KG.Recorder.summary and KG.Recorder.summary.ref)
    local rd = ref and ref.run and ref.run.routeHash
        and KG.Ghosts:RouteForHash(ref.run.routeHash) or nil
    if rd then KG.RequestRouteLoad(rd) end
end

--- (Re)apply the player cursor icon: your raid target marker when you carry one (the
--- tank's {square} etc. — it's how you already identify yourself on screen), else your
--- portrait. The marker index is usually a Midnight SECRET, so it is never read here:
--- it goes straight into the C-side sprite-sheet cell pick on the 4x4 marker sheet,
--- which accepts secrets (the EXBoss/BliZzi-proven recipe; the old readNum guard
--- turned every secret into nil and the icon stayed portrait forever). While marked
--- the sheet must be reapplied blind — two secrets can't be diffed — but on a 0.5 s
--- CLOCK, not every 0.1 s bar update (the CPU pass, 2026-07-28): a mid-run marker
--- CHANGE still lands within a tick, GAINING a marker repaints instantly (the cached
--- key was "portrait"), and the C-side texture+cell work drops from 10/s to 2/s.
--- Portraits are often BLACK until the client fires a portrait update, so Core
--- re-calls this with force on UNIT_PORTRAIT_UPDATE and zone-in (force also skips
--- the throttle); the no-marker path stays cached.
function Bar.RefreshPlayerIcon(force)
    local tex = frame and frame.playerIcon
    if not tex then return end
    local marker = KG.Scenario:GetPlayerRaidMarkerOpaque() -- opaque: possibly secret
    -- MARKER HAT mode (easter egg, 2026-07-28): the marker is CONSUMED here — painted
    -- onto the 8 px hat with the same blind cell-pick on the same 0.5 s clock (only
    -- the VALUE is secret; presence nil-tests fine) — so the face path below never
    -- sees it and stays the cached portrait. Performance-neutral vs the full-face
    -- marker: the identical repaint budget lands on a smaller texture, and the face
    -- never flips paint paths at all.
    local hat = frame.markerHat
    if KG.db.markerHat and hat then
        if marker ~= nil and hat.SetSpriteSheetCell then
            local now = GetTime()
            if force or not hat:IsShown() or now - (hat._kgAt or 0) >= 0.5 then
                hat:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcons")
                if pcall(hat.SetSpriteSheetCell, hat, marker, 4, 4) then
                    hat._kgAt = now
                    hat:Show()
                else
                    hat:Hide() -- cell-pick refused (API drift): never wear a garbage tile
                end
            end
        else
            hat:Hide() -- unmarked: bare head
        end
        marker = nil
    elseif hat and hat:IsShown() then
        hat:Hide() -- option turned off: the marker moves back onto the face below
    end
    if marker ~= nil and tex.SetSpriteSheetCell then
        local now = GetTime()
        if not force and tex._kgIconKey == "marker"
            and now - (tex._kgMarkerAt or 0) < 0.5 then
            return -- still wearing a marker, repainted < 0.5 s ago: skip this update
        end
        tex:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcons")
        if pcall(tex.SetSpriteSheetCell, tex, marker, 4, 4) then
            tex._kgIconKey = "marker"
            tex._kgMarkerAt = now
            return
        end
        force = true -- the sheet just splatted over the icon: repaint the portrait
    end
    if not force and tex._kgIconKey == "portrait" then return end
    tex._kgIconKey = "portrait"
    if not pcall(SetPortraitTexture, tex, "player") then
        tex:SetTexture("Interface\\Icons\\Achievement_PVP_A_01")
    end
    tex:SetTexCoord(0, 1, 0, 1)
end

--- Bar + roster scale (Edit Mode slider).
function Bar.ApplyScale()
    local s = KG.db.scale or 1
    if frame then frame:SetScale(s) end
    local splits = _G.KeystoneGhostSplits
    if splits then splits:SetScale(s) end
end

--- END MODE, RETIRED (Fredrik 2026-07-28). The delta + Count Gap block used to
--- YIELD — slide left for as long as Mario's icon overlapped it — because the block
--- and his icon shared the 18 px band above the track. Option C1 (2026-07-27) ended
--- that overlap by giving him the band alone: his icon tops out 19 px above the
--- track, the Count Gap starts at 37. Nothing up there can collide any more. But the
--- yield's overlap test was pure-x and never learned that, so it kept shoving the
--- numbers aside every time he neared the finish — the scrapped behaviour still
--- running on top of the change that replaced it ("now it does both"). So: the block
--- stands at home, always. The one real neighbour left is the Finish Photo's close
--- button (18 px, frame top-right; the live bar hides it), and the photo asks for
--- that much room with `reserveClose`. No easing — the position no longer moves.
local CLOSE_W = 18
local function PlaceNumbers(reserveClose)
    local W = frame.track:GetWidth() or WIDTH
    local rightEdge = W - 3 - (reserveClose and CLOSE_W or 0)
    frame.delta:ClearAllPoints()
    frame.delta:SetPoint("TOPRIGHT", frame.track, "TOPLEFT", rightEdge, TRACK_Y - NUM_TOP_Y)
    frame.subDelta:ClearAllPoints()
    frame.subDelta:SetPoint("TOPRIGHT", frame.track, "TOPLEFT", rightEdge, TRACK_Y - NUM_SUB_Y)
end

local function BossTick(i)
    local f = frame.bossTicks[i]
    if not f then
        f = Hover(frame.track, 16, TRACK_H + 6)
        f.tex = f:CreateTexture(nil, "OVERLAY")
        f.tex:SetSize(12, 12)
        -- skull hugs the track's lower half (ghost zone per the design grammar)
        f.tex:SetPoint("BOTTOM", 0, 2)
        f.tex:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcon_8") -- skull
        frame.bossTicks[i] = f
    end
    return f
end

-- ── Update ─────────────────────────────────────────────────────────────────────
function Bar:Update()
    local st = LiveState()
    if not st then frame:Hide(); return end

    frame.track:Show() -- the photo (H9) hides the road; every live path re-opens it
    Style.RefreshPanel(frame)
    local ref = st.ref
    local W = frame.track:GetWidth() or WIDTH
    -- Forces readout mode (the count display toggle): percent is the default
    -- ("Show % instead of count" ON); unticking flips every site to raw count.
    -- Display-only — every value below stays count-native regardless.
    local countMode = KG.db.percentDisplay == false
    -- Raced-Ghost Switch presentation (S7): for ~0.4 s after a switch the ghost-owned
    -- marks (cursor, badge, milestone skulls) fade IN — the change reads as watched,
    -- not glitched. The numbers need no handling: title, Gap, Count Gap, and Zone all
    -- re-derive from the new ref in this same tick (S8).
    local swAge = st.lastSwitch and (GetTime() - st.lastSwitch.at) or nil
    local swMul = (swAge and swAge < 0.4) and (0.15 + 0.85 * swAge / 0.4) or 1
    -- THE ROAD, seen through the Mario camera: YOU sit at the ¼ anchor while the
    -- dungeon scrolls toward you; near the finish the camera stops and you drive the
    -- last stretch to the line. Everything off-window pins to the edges (future bosses
    -- stack in one pile at the right and detach into view as you approach).
    local nBosses = ref.nBosses or (ref.run.bossKills and #ref.run.bossKills) or 0
    -- Course motion: each boss owns a STRETCH of road (it owns a stretch of the run's
    -- time); the kill unlocks it. Movement is speed-capped, so a runner walks BRISKLY
    -- THROUGH the boss's stretch after winning (~1s) instead of teleporting past it —
    -- Fredrik's model verbatim: stop, fight, move on. Trash pace never hits the cap.
    -- Snaps on big discontinuities (new run / ref change) and on backwards resets.
    -- Walk-speed cap is in ROAD seconds: test mode compresses time, so scale it up
    -- there or every motion saturates the cap into stutter (2026-07-19 field report).
    local capMul = (KG.testMode or KG.editModePreview or KG.introMode) and TEST_SPEED or 1
    local function ease(cur, target)
        if cur == nil or math.abs(cur - target) > 0.25 or target < cur - 0.02 then
            return target
        end
        local step = (target - cur) * 0.35
        local cap = 0.006 * capMul -- walk speed: ≈6% of the road per (road-)second
        if step > cap then step = cap end
        return cur + step
    end
    local youCourse = ease(frame._smYou, M.CoursePos(st.pct, st.bosses, nBosses))
    frame._smYou = youCourse
    local VIS = M.VIS -- 0.45: zoomed out a notch from 0.35 (Fredrik: calmer motion per pixel)
    local camLo = M.Camera(youCourse, VIS, 0.25)
    local vx = function(course) return ((course or 0) - camLo) / VIS end
    local px = function(course) return math.max(0, math.min(1, vx(course))) * W end
    local pinned = function(course)
        local v = vx(course)
        return (v < 0 and -1) or (v > 1 and 1) or 0
    end
    -- Finish line: scrolls in from the right during the final stretch, and the camera
    -- stops with it. (Its arrival used to double as END MODE, the cue for the numbers
    -- to step aside for a parking Mario; that yield is retired — see PlaceNumbers.)
    local endMode = vx(1) <= 1.001
    if endMode then
        frame.finishLine:ClearAllPoints()
        frame.finishLine:SetPoint("LEFT", frame.track, "LEFT", px(1) - 1, 0)
        frame.finishLine:Show()
    else
        frame.finishLine:Hide()
    end

    -- Pace cars: linear racers that complete the road in exactly par×frac. The +1 car
    -- is the sweeper — if it passes you, the key depletes. +2/+3 cars are optional.
    if st.par and st.par > 0 and st.elapsed then
        -- One visibility key per car (Fredrik 2026-07-28, superseding the single
        -- "+3/+2" toggle): the +1 sweeper is hideable too — its swept-road wake
        -- goes with it below; the gap zone's depletion warning is untouched.
        local cars = { { 0.6, "+3", "paceCar3" }, { 0.8, "+2", "paceCar2" }, { 1.0, "+1", "paceCar1" } }
        -- Tags are drawn SWEEPER FIRST (i = 3 → 1, which is also left → right): early
        -- in a run all three cars are bunched at the start line, and when they overlap
        -- the one whose identity matters is the +1.
        local tagged = {}
        for i = 3, 1, -1 do
            local frac, tag, carKey = cars[i][1], cars[i][2], cars[i][3]
            local f = frame.paceCars[i]
            if KG.db[carKey] ~= false then
                local carCourse = st.elapsed / (st.par * frac)
                local dim = pinned(carCourse) ~= 0 and 0.5 or 1 -- lurking at an edge
                local cx = px(carCourse)
                f:ClearAllPoints()
                f:SetPoint("CENTER", frame.track, "LEFT", cx, 0)
                local cr, cg, cb, ca
                if tag == "+1" then
                    cr, cg, cb, ca = Style.RED[1], Style.RED[2], Style.RED[3], 0.8 -- the sweeper
                    -- The swept road: red hatch on the ground it has just taken.
                    local z = frame.sweptZone
                    -- Re-tint only when the palette actually moved: SetGradient
                    -- bakes the colors in, so a color-vision change mid-session
                    -- would otherwise leave the wake on the old red forever.
                    if z._paletteR ~= cr or z._paletteG ~= cg or z._paletteB ~= cb then
                        z._paletteR, z._paletteG, z._paletteB = cr, cg, cb
                        z:SetGradient("HORIZONTAL", CreateColor(cr, cg, cb, 0.12),
                            CreateColor(cr, cg, cb, 0.9))
                    end
                    local wake = math.min(cx, W * SWEPT_WAKE)
                    if wake > 2 then
                        z:ClearAllPoints()
                        z:SetPoint("TOPLEFT", frame.track, "TOPLEFT", cx - wake, 0)
                        z:SetPoint("BOTTOMLEFT", frame.track, "BOTTOMLEFT", cx - wake, 0)
                        z:SetWidth(wake)
                        -- Texcoords in TRACK space, so the stripes stand still and the
                        -- wake slides over them instead of dragging them along.
                        z:SetTexCoord((cx - wake) / HATCH_TILE, cx / HATCH_TILE,
                            0, TRACK_H / HATCH_TILE)
                        z:Show()
                    else
                        z:Hide()
                    end
                else
                    cr, cg, cb, ca = 0.85, 0.85, 0.85, 0.45
                end
                f.tex:SetVertexColor(cr, cg, cb, ca * dim)
                -- The tag stands "+1 |" — directly LEFT of the hairline, in the car's
                -- own color. It flips to the right side only when the car is against
                -- the track's left edge, where there is nothing to the left of it.
                -- Suppressed when a neighbour's tag already stands within 15 px: two
                -- tags on one spot are less readable than one.
                local clear = true
                for _, tx in ipairs(tagged) do
                    if math.abs(cx - tx) < 15 then clear = false break end
                end
                f.label:ClearAllPoints()
                if cx < 18 then
                    f.label:SetPoint("TOPLEFT", f, "TOP", 3, -3)
                else
                    f.label:SetPoint("TOPRIGHT", f, "TOP", -3, -3)
                end
                f.label:SetText(tag)
                f.label:SetTextColor(cr, cg, cb)
                f.label:SetAlpha(math.min(1, ca + 0.2) * dim)
                f.label:SetShown(clear)
                if clear then tagged[#tagged + 1] = cx end
                f.tip = {
                    tag .. " pace car",
                    "Finishes in exactly " .. M.FormatClock(st.par * frac),
                    tag == "+1" and "If it passes you, the key depletes"
                        or ("Stay ahead of it to keep the " .. tag),
                }
                f:Show()
            else
                f:Hide()
                if tag == "+1" then frame.sweptZone:Hide() end -- the wake is the sweeper's
            end
        end
    else
        for i = 1, 3 do frame.paceCars[i]:Hide() end
        frame.sweptZone:Hide() -- no par, no sweeper, no swept road
    end

    -- Boss names: prefer the ghost's own recording; the live recorder's names cover
    -- legacy ghosts (same dungeon, same criteria) once the bosses die this run.
    local ORDINAL = { "1st", "2nd", "3rd" }
    local function Ordinal(n) return ORDINAL[n] or (n .. "th") end
    local kills = ref.run and ref.run.bossKills or nil
    local nKills = kills and #kills or 0
    local names = (ref.run and ref.run.bossNames) or st.liveNames or {}
    local ghostCounts = (ref.run and ref.run.bossCounts) or {}
    local gTotal = (ref.run and ref.run.total) or 100 -- ghost's own count units
    -- Identity pairing (SCENARIOS C2): ghost column i ↔ YOUR kill of the same
    -- encounterID — feeds the laps and the tooltip "You:" lines ONLY. Skull fade is
    -- count-based (milestone semantics, decision D1); kill-order fallback where IDs
    -- are missing (legacy/seeded data).
    local laps, lapMatch = M.LapDeltasByID(st.liveKills or {}, kills or {},
        st.liveIDs, ref.run and ref.run.bossIDs)
    -- Where the skulls actually stand this frame — the Death Markers below shelf
    -- their tombstones up out of these (never sideways: X carries the truth).
    local bossX = {}
    for i = 1, nKills do
        local f = BossTick(i)
        f:ClearAllPoints()
        -- Boss = a fixed landmark on the road: the course position where the ghost
        -- stood while fighting it (its count at the kill + the segments already won).
        -- HONEST PLACEMENT ONLY (Fredrik's Live Test 1 field report — evenly spread
        -- phantom skulls vs a RaiderIO replay): the live mirror only knows counts
        -- for the span we actually watched. A kill outside that span has no known
        -- count — its skull is hidden rather than guessed (the kill itself stays in
        -- bossKills, so the Gap's boss constraint is untouched). Recorded ghosts
        -- always carry their full curve and are unaffected.
        local atCount = ghostCounts[i]
        if not atCount then
            if ref.live then
                local snaps = ref.run.snapshots
                local lastT = snaps[#snaps] and snaps[#snaps][1] or 0
                if kills[i] >= (ref.mirrorFrom or 0) and kills[i] <= lastT then
                    atCount = M.SampleAt(snaps, kills[i])
                end
            else
                atCount = M.SampleAt(ref.run.snapshots, kills[i])
            end
        end
        local atPct = atCount and M.Frac(atCount, gTotal)
        local bossCourse = atPct and M.CoursePos(atPct, i - 1, nBosses)
        local pin = bossCourse and pinned(bossCourse) or -1
        if pin == -1 then
            f:Hide() -- scrolled off behind the camera (or count unknown): not drawn
        else
            if pin == 1 then
                -- Queued at the edge: future milestones STACK in one pile at the wall
                -- (Fredrik 2026-07-20 — the 7 px fan read as clutter); each detaches to
                -- its own road position as it scrolls into the camera window.
                f:SetPoint("CENTER", frame.track, "LEFT", W - 5, 0)
            else
                f:SetPoint("CENTER", frame.track, "LEFT", px(bossCourse), 0)
                bossX[#bossX + 1] = px(bossCourse)
            end
            -- In the pile the NEXT milestone sits on top, so the stack's hover
            -- tooltip describes the kill you'll reach first, not the last one.
            f:SetFrameLevel(frame.track:GetFrameLevel() + 1 + (pin == 1 and (nKills - i) or 0))
            f:SetAlpha((pin == 1 and 0.6 or 1) * swMul)
        end
        -- Milestone semantics (DESIGN "Decisions in force", 2026-07-19): the skull
        -- claims "the ghost's i-th kill happened here" — a fact about the ghost's
        -- recording, true whatever order YOU kill bosses in. The name is shown as
        -- ghost history, never as a promise about your next boss.
        local when = M.FormatClock(kills[i])
            .. (ghostCounts[i] and (" · " .. M.FormatForcesLevel(ghostCounts[i], gTotal, countMode, 0) .. " count") or "")
        -- Journal-first name (localized on THIS client when the ghost carries a
        -- journal ID); the stored scrape via names[] is the fallback.
        local nm = (ref.run and KG.Ghosts:BossDisplayName(ref.run, i)) or names[i]
        local tip = {
            string.format("Ghost's %s kill", Ordinal(i)),
            (nm and (nm .. " at ") or "At ") .. when,
        }
        local j = lapMatch[i] -- YOUR kill of the SAME boss (encounterID; order fallback)
        local lk = j and st.liveKills and st.liveKills[j]
        if lk and st.seededKills and j <= st.seededKills then
            tip[#tip + 1] = "You: killed before your reload (no lap time)"
        elseif lk then
            local lc = st.liveCounts and st.liveCounts[j]
            tip[#tip + 1] = string.format("You: dead at %s%s  (lap %s)", M.FormatClock(lk),
                lc and (" · " .. M.FormatForcesLevel(lc, st.total, countMode, 0) .. " count") or "", M.FormatDelta(laps[i]))
        end
        f.tip = tip
        -- Milestones fade by COUNT: your 2nd kill puts the ghost's 2nd-kill milestone
        -- behind you, whichever boss it was. (Identity lives in the splits laps and
        -- the tooltip's "You:" line — never in the road's geometry.)
        local done = (st.bosses or 0) >= i
        f.tex:SetDesaturated(done)
        f.tex:SetAlpha(done and 0.6 or 1) -- 0.4 read as "icons missing" in the field
        if pin ~= -1 then f:Show() end
    end
    for i = nKills + 1, #frame.bossTicks do frame.bossTicks[i]:Hide() end

    local aR, aG, aB = Style.GetAccent()
    local ghostCourse
    if ref.live then
        ghostCourse = M.CoursePos(M.Frac(ref.nowCount, gTotal), ref.nowBosses or 0, nBosses)
    else
        ghostCourse = M.CourseAt(ref.run, st.elapsed, nBosses)
    end
    ghostCourse = ease(frame._smGhost, ghostCourse)
    frame._smGhost = ghostCourse
    local gx = px(ghostCourse)
    local gPin = pinned(ghostCourse) -- ghost beyond the camera: pinned at an edge, dimmed
    frame.ghostCursor:SetVertexColor(aR, aG, aB, (gPin == 0 and 0.95 or 0.4) * swMul)
    frame.ghostCursor:ClearAllPoints()
    frame.ghostCursor:SetPoint("LEFT", frame.track, "LEFT", gx - 1, 0)
    ApplyGhostIcon(frame.ghostIcon, ref)
    Bar.RefreshPlayerIcon() -- cheap; catches mid-run raid-marker changes
    frame.ghostHover:SetAlpha((gPin == 0 and 1 or 0.6) * swMul)
    frame.ghostHover:ClearAllPoints()
    frame.ghostHover:SetPoint("TOP", frame.track, "BOTTOMLEFT", gx, -1) -- ghost zone: below the track

    -- Ghost "now" state (in the GHOST's own count units): shared by the Gap (arming +
    -- inversion), the Count Gap, and the hover tooltips further down.
    local ghostCountNow = ref.live and (ref.nowCount or 0) or M.SampleAt(ref.run.snapshots, st.elapsed)
    local ghostPctNow = M.Frac(ghostCountNow, gTotal) -- derived display value
    local ghostBossesNow = 0
    for i = 1, nKills do
        if kills[i] <= st.elapsed then ghostBossesNow = ghostBossesNow + 1 end
    end
    -- The Gap arms at first blood (SCENARIOS B9): until BOTH runners have progress,
    -- the inversion reads "time since the gates opened" — not a real deficit.
    local gapArmed = M.HasProgress(st.raw, st.bosses) and M.HasProgress(ghostCountNow, ghostBossesNow)

    -- Your road position is simply your progress; the SECONDS delta (for the text and
    -- zone color) still comes from timeline inversion — two views of the same race.
    -- The live state goes in as (count, total): same-total ghosts compare exact
    -- integers, cross-total (linear/RaiderIO/season-retune) maps through fractions.
    local eq
    if ref.live then
        -- Live ghost (RaiderIO replay): its future is unknown, so use the bidirectional
        -- delta — invert whichever timeline (the ghost's mirror or your own) can answer.
        eq = st.elapsed + M.LiveDelta(ref.run, ref.nowCount or 0, ref.nowBosses or 0,
            st.liveRun or { snapshots = {} }, st.elapsed, st.raw, st.bosses, st.total)
    else
        eq = M.GhostTimeFor(ref.run, st.raw, st.bosses, st.total)
    end
    local ex = px(youCourse) -- normally parked at the camera anchor

    -- Death knockback ("OMG we have to do this" — Fredrik 2026-07-19), PENALTY-SCALED
    -- (his correction, superseding the first-draft 1/3 rule): each death throws the
    -- icon back the ROAD DISTANCE its penalty costs at sweeper pace (timeLost/par of
    -- the road) — a 15 s death is a stumble, a wipe chain reads catastrophic, same
    -- currency as everything else on the track; a floor keeps single deaths visible.
    -- Purely cosmetic and icon-local: the CAMERA stays keyed to your logical course,
    -- so ghosts, milestones, and pace cars never move because of this — their death
    -- lurch is the timer jump itself (the honest penalty), eased by the walk cap.
    -- While the knock recovers the gap is briefly exaggerated (impact frames), then
    -- settles to the honest picture. Clamped to ex: never off the track's left edge.
    -- Baselines are per display-source: a test-mode flip, a new reference (new run),
    -- or the frame having been hidden across a run must never read as fresh deaths
    -- (phantom mega-knock). On a source change the baselines just re-seed.
    local kbSrc = (KG.testMode or KG.editModePreview or KG.introMode) and "test" or tostring(ref)
    if frame._kbSrc ~= kbSrc then
        frame._kbSrc = kbSrc
        frame._kb, frame._kbPot = nil, nil
        frame._lastDeathCount, frame._lastTimeLost = nil, nil
    end
    local deathsNow = st.deathCount or 0
    local lostNow = st.deathTimeLost or 0
    if deathsNow < (frame._lastDeathCount or 0) then -- new run
        frame._kb, frame._kbPot, frame._lastTimeLost = nil, nil, nil
    end
    if frame._lastDeathCount and deathsNow > frame._lastDeathCount then
        local n = deathsNow - frame._lastDeathCount
        local lostDelta = (lostNow > (frame._lastTimeLost or 0))
            and (lostNow - (frame._lastTimeLost or 0)) or (15 * n) -- timer unreadable: assume 15 s each
        -- Debounce (Fredrik 2026-07-19): deaths during an active knock don't restart
        -- the animation — they gather in a pot, and the NEXT knock fires with the
        -- accumulated penalty once the icon has stood back up. Death-feeding a pull
        -- becomes knock → recover → BIGGER knock, never a seizure.
        local pot = frame._kbPot or { n = 0, lost = 0 }
        pot.n, pot.lost = pot.n + n, pot.lost + lostDelta
        frame._kbPot = pot
    end
    frame._lastDeathCount, frame._lastTimeLost = deathsNow, lostNow
    if frame._kbPot and not frame._kb then -- stood up (or first death): fire the pot
        local pot = frame._kbPot
        frame._kbPot = nil
        local kbPix = (st.par and st.par > 0) and ((pot.lost / st.par) / VIS * W) or 0
        frame._kb = math.min(ex, math.max(8 * pot.n, kbPix))
    end
    local kb = frame._kb or 0
    if kb > 2 then
        frame._kb = kb * 0.93 -- ease back toward the anchor (~2-3 s)
        frame._lastMoveT = GetTime() -- keep the walk cycle running while recovering
    else
        frame._kb = nil -- fully stood up; a waiting pot fires next tick
    end
    -- Dazed while knocked: wobble runs exactly as long as the recovery does.
    if frame._kb and not frame.dazedAnim:IsPlaying() then
        frame.dazedAnim:Play()
    elseif not frame._kb and frame.dazedAnim:IsPlaying() then
        frame.dazedAnim:Stop()
    end
    local exV = ex - (frame._kb or 0) -- visual position; ex stays the logical anchor

    -- Walk while moving, stand at bosses (course frozen while forces stall). Note:
    -- trash is often pulled ONTO a boss — count keeps rising mid-fight and the icon
    -- keeps walking; standing still only happens when count actually stalls.
    if youCourse ~= frame._lastCourse then
        frame._lastCourse = youCourse
        frame._lastMoveT = GetTime()
    end
    local walking = KG.db.bounce ~= false and (GetTime() - (frame._lastMoveT or 0)) < 1.5
    if walking and not frame.walkAnim:IsPlaying() then
        frame.walkAnim:Play()
    elseif not walking and frame.walkAnim:IsPlaying() then
        frame.walkAnim:Stop()
    end
    frame.playerCursor:ClearAllPoints()
    frame.playerCursor:SetPoint("LEFT", frame.track, "LEFT", exV - 1, 0)
    frame.playerHover:ClearAllPoints()
    frame.playerHover:SetPoint("BOTTOM", frame.track, "TOPLEFT", exV, 1) -- my zone: above the track

    local delta = eq - st.elapsed
    local good, bad = Style.GREEN, Style.RED
    -- Disarmed: grey unsigned 0:00 — "race not measurable yet", never a phantom deficit.
    local dc = gapArmed and ((delta >= 0) and good or bad) or Style.GRAY
    frame.delta:SetText(gapArmed and M.FormatDelta(delta) or "0:00")
    frame.delta:SetTextColor(dc[1], dc[2], dc[3])
    frame.playerCursor:SetVertexColor(dc[1], dc[2], dc[3], 1)

    local lo, hi = math.min(gx, exV), math.max(gx, exV)
    local bw = hi - lo
    if gapArmed and bw >= 1 then
        local br, bg2, bb
        local pulse = 0
        if delta >= 0 then
            br, bg2, bb = good[1], good[2], good[3]
        else
            -- Behind: red-tinted from the FIRST second behind, ramping to the
            -- full bad color by Depletion Danger (Fredrik 2026-07-21 "increase
            -- anger!" — the old grey→red lerp read almost grey at low severity;
            -- now a 25% red floor + an eased ramp). Derived from Style.RED so
            -- the color-vision setting carries into the zone too.
            local sev = M.BehindSeverity(delta, ref.durationSec, st.par)
            if sev then
                local anger = 0.25 + 0.75 * sev ^ 0.7
                local base = 0.55
                br = base + (bad[1] - base) * anger
                bg2 = base + (bad[2] - base) * anger
                bb = base + (bad[3] - base) * anger
                -- Angry Sweeper red (DESIGN follow-up): near-certain depletion is the
                -- SWEEPER's territory, and its red must read angrier than any other
                -- red on the track — hotter, more saturated, and slowly pulsing.
                if sev > 0.75 then
                    local anger = (sev - 0.75) / 0.25
                    br = br + (1 - br) * anger
                    bg2 = bg2 * (1 - 0.55 * anger)
                    bb = bb * (1 - 0.55 * anger)
                    pulse = anger * (0.12 + 0.10 * math.sin(GetTime() * 4))
                end
            else
                br, bg2, bb = bad[1], bad[2], bad[3]
            end
        end
        local z = frame.gapZone
        z._faint:SetRGBA(br, bg2, bb, 0.1 + pulse * 0.5)
        z._strong:SetRGBA(br, bg2, bb, 0.55 + pulse)
        if exV >= gx then -- you're to the right: gradient builds toward you
            z:SetGradient("HORIZONTAL", z._faint, z._strong)
        else
            z:SetGradient("HORIZONTAL", z._strong, z._faint)
        end
        z:ClearAllPoints()
        z:SetPoint("TOPLEFT", frame.track, "TOPLEFT", lo, 0)
        z:SetWidth(bw)
        z:Show()
    else
        frame.gapZone:Hide()
    end

    -- Roster runners: every other roster ghost races visibly at its own road position,
    -- small and dimmed below the line; hovering its roster row lights it up.
    -- LANES = the Roster Panel's row order, one for one (Fredrik 2026-07-21: the
    -- Y order looked random — it was counting non-raced runners, so a mid-list
    -- raced ghost shifted everyone below it). The raced row's lane stays empty
    -- (its ghost rides the badge cursor above the line); a header sort in the
    -- panel re-lanes the runners identically. Pairing colors stay keyed to the
    -- ghost's BASE roster position — a sort moves lanes, never recolors.
    local nr = 0
    local runnerLanes = {} -- {run, y} per drawn lane — the Death Markers below ride these
    local displayRows = KG.Splits and KG.Splits.BuildDisplayRows and KG.Splits.BuildDisplayRows(st) or {}
    for laneIdx, entry in ipairs(displayRows) do
        local run = entry.run
        if run ~= ref.run and run.snapshots then
            nr = nr + 1
            local f = Runner(nr, entry.colorIdx or laneIdx)
            f:ClearAllPoints()
            -- Smoothing is keyed to the ghost, not the slot: a roster reorder
            -- (e.g. after a Switch) must not slide one ghost's icon from another
            -- ghost's old position.
            if f._smKey ~= run then f._smKey, f._sm = run, nil end
            local rCourse = ease(f._sm, M.CourseAt(run, st.elapsed, nBosses))
            f._sm = rCourse
            local laneY = -3 - (laneIdx - 1) * 5
            f:SetPoint("TOP", frame.track, "BOTTOMLEFT", px(rCourse), laneY)
            runnerLanes[#runnerLanes + 1] = { run = run, y = laneY }
            ApplyRunnerIcon(f.tex, run)
            local lit = Bar._previewRun == run
            f:SetAlpha(lit and 1 or (pinned(rCourse) ~= 0 and 0.3 or 0.55))
            f.tip = {
                KG.Splits.RowTitle(entry.tag) .. " ghost — " .. M.FormatClock(run.durationSec or 0),
                run.importedFrom and ("From: " .. run.importedFrom) or "One of your runs",
            }
            f:Show()
        end
    end
    for i = nr + 1, #frame.runners do frame.runners[i]:Hide() end

    -- ── Death Markers ─────────────────────────────────────────────────────────
    -- Tombstones returned 2026-07-21 by field order (reversing the 2026-07-19
    -- removal); 2026-07-22 gave them a home, a companion, and a setting.
    --
    -- YOURS are HISTORY: they stand in the BOSS LANE on your own track — a death
    -- is road furniture in your run, the same kind of landmark as a milestone —
    -- and they stay put. A clash never moves the stone sideways: X is the
    -- truth-carrying axis here, and a moved stone would lie about where you
    -- died. It takes another SLOT instead, and the slots go BOTH ways around the
    -- lane — 0, +4, -4, +8, -8 (Fredrik's field report on the first build: the
    -- old one-way +6 ladder climbed straight out of the lane). A 5-death wipe
    -- now spreads across 16 px around the line instead of towering 30 px above
    -- it. A stone landing on a skull starts one slot up: bosses you have passed
    -- are faded, so a small offset is all it takes to keep both readable.
    --
    -- A GHOST'S are the opposite kind of thing: a TELEGRAPH. They ride that
    -- ghost's own lane, mark where its recorded run stopped to pay the death
    -- penalty, and vanish the moment it reaches them — ahead of the ghost they
    -- warn you a stumble is coming, behind it they are only clutter.
    --
    -- The setting ([Off / yours / everyone's], Options panel) is DISPLAY-ONLY by
    -- design: no ghost's pace depends on it. A recorded timeline already carries
    -- the penalty (Recorder's AnchorClock rides the official timer, which jumps
    -- on a death), so the ghost stalls at its own graves whatever is drawn —
    -- flipping the setting mid-run redraws and nothing else.
    local deathMode = KG.db.deathMarkers or "all"
    local STONE_W, STONE_H = 9, 12
    -- Cluster slots, around the lane rather than up from it (his field report).
    local SLOTS = { 0, 4, -4, 8, -8 }
    -- ONE recipe for every tombstone on the track (his second field note: the
    -- ghost's read as a different icon). Same atlas, same 9x12 box, ONE size —
    -- "I liked Mario's ratio, use that everywhere" (2026-07-22); the ⅔ runner
    -- stone that shipped in the fix an hour earlier is gone with the squashed
    -- 7x9 that caused it. Only alpha says whose stone it is. Scale is kept as a
    -- knob purely because lanes sit 5 px apart: if runner stones read as mush
    -- when three ghosts all died, this is where they shrink.
    local function Stone(pool, i, scale, alpha)
        local mark = pool[i]
        if not mark then
            mark = Hover(frame.track, STONE_W, STONE_H)
            mark.tex = mark:CreateTexture(nil, "ARTWORK")
            mark.tex:SetAllPoints()
            mark.tex:SetAtlas("poi-graveyard-neutral")
            pool[i] = mark
        end
        mark:SetSize(STONE_W * scale, STONE_H * scale)
        mark.tex:SetAlpha(alpha)
        mark:ClearAllPoints()
        return mark
    end

    frame.deathMarks = frame.deathMarks or {}
    local nd = 0
    if deathMode ~= "none" and st.deaths then
        local placed = {} -- stones already standing this frame: {x, slot}
        for i = 1, #st.deaths do
            local d = st.deaths[i]
            local dt = d and d[1]
            if dt and dt <= st.elapsed then
                local course = M.CourseAt(st.liveRun or { snapshots = {} }, dt, nBosses)
                if pinned(course) == 0 then
                    local x = px(course)
                    -- A stone on a skull starts one slot off it; then take the
                    -- first slot no neighbour is standing in. Past the last slot
                    -- they share it — by then "a lot died here" is the message.
                    local from = 1
                    for _, bx in ipairs(bossX) do
                        if math.abs(x - bx) < 10 then from = 2 break end
                    end
                    local slot = #SLOTS
                    for k = from, #SLOTS do
                        local free = true
                        for _, p in ipairs(placed) do
                            if p.slot == k and math.abs(x - p.x) < 7 then free = false break end
                        end
                        if free then slot = k break end
                    end
                    placed[#placed + 1] = { x = x, slot = slot }
                    nd = nd + 1
                    local mark = Stone(frame.deathMarks, nd, 1, 0.75)
                    -- Bottom-anchored on the skulls' own baseline (BossTick pins
                    -- its skull at BOTTOM +2), so slot 1 shares the boss lane.
                    mark:SetPoint("BOTTOM", frame.track, "BOTTOMLEFT", x, 2 + SLOTS[slot])
                    mark:SetFrameLevel(frame.track:GetFrameLevel() + 2 + slot)
                    mark.tip = { string.format("Death #%d — %s", i, M.FormatClock(dt)) }
                    mark:Show()
                end
            end
        end
    end
    for i = nd + 1, #frame.deathMarks do frame.deathMarks[i]:Hide() end

    -- The ghosts' stones: the same stone, dimmer, on the lane its owner rides.
    -- Only the ones still AHEAD of that ghost are drawn.
    frame.ghostMarks = frame.ghostMarks or {}
    local ng = 0
    local function GhostStones(run, laneY, scale, alpha)
        if deathMode ~= "all" or not (run and run.deaths) then return end
        for i = 1, #run.deaths do
            local dt = run.deaths[i] and run.deaths[i][1]
            if dt and dt > st.elapsed and ng < 60 then
                local course = M.CourseAt(run, dt, nBosses)
                if pinned(course) == 0 then
                    ng = ng + 1
                    local mark = Stone(frame.ghostMarks, ng, scale, alpha)
                    mark:SetPoint("TOP", frame.track, "BOTTOMLEFT", px(course), laneY)
                    mark.tip = {
                        string.format("Ghost's death #%d — %s", i, M.FormatClock(dt)),
                        "It stops here to pay the penalty",
                    }
                    mark:Show()
                end
            end
        end
    end
    -- The raced ghost rides the badge lane; its stones sit on it (and clear as it
    -- arrives, so the badge never has to share the spot for long).
    if not ref.live then GhostStones(ref.run, -1, 1, 0.6) end
    for laneIdx, entry in ipairs(runnerLanes) do
        GhostStones(entry.run, -3 - (laneIdx - 1) * 5, 1, 0.45)
    end
    for i = ng + 1, #frame.ghostMarks do frame.ghostMarks[i]:Hide() end

    -- The raced ghost's Dazed: it wobbles as it reaches one of its own deaths.
    -- The window is in ROAD seconds like the walk cap — test mode compresses
    -- time, so an unscaled 2.5 s would flash past in a quarter of a second.
    -- Gated with the ghosts' stones, not merely "not off": someone who asked for
    -- their own deaths only shouldn't be told about the ghost's either. Mario's
    -- own Knockback is untouched by the setting — it is his run, not a marker.
    local wobble = false
    if deathMode == "all" and not ref.live and ref.run and ref.run.deaths then
        for i = 1, #ref.run.deaths do
            local dt = ref.run.deaths[i][1]
            if dt and st.elapsed >= dt and st.elapsed < dt + 2.5 * capMul then
                wobble = true
                break
            end
        end
    end
    if wobble and not frame.ghostDazed:IsPlaying() then
        frame.ghostDazed:Play()
    elseif not wobble and frame.ghostDazed:IsPlaying() then
        frame.ghostDazed:Stop()
    end

    local cd = st.pct - ghostPctNow
    local cc = (cd >= 0) and good or bad
    -- The Count Gap: fraction-space diff, rendered in the chosen readout ("+14" in
    -- count mode — converted into YOUR total's units, so cross-total ghosts stay
    -- honest; "+3.4%" in percent mode). Verdict color keys off the sign either way.
    frame.subDelta:SetText(M.FormatForcesDelta(cd, st.total, countMode))
    frame.subDelta:SetTextColor(cc[1], cc[2], cc[3])

    frame.refLabel:SetText("vs " .. (ref.label or "?"))
    -- Both texts are set: the numbers can take their place — a fixed one, since
    -- Mario has his own lane and never reaches up into theirs.
    PlaceNumbers()

    -- Pull position (needs an MDT route matching this dungeon): you vs the ghost. Your
    -- side uses the stateful tracker (boss criteria + thresholds — APL's model); the
    -- forces inference is only the test-mode/fallback path. The ghost side stays
    -- forces-inferred (a recording has no live criteria).
    -- Route mismatch, hash-based (names lie — dossier §4): the Raced Ghost ran a
    -- DIFFERENT route than your selected one, so its pull token is a projection
    -- onto YOUR yardstick. Footnote asterisk on the token; the ghost tooltip
    -- explains. Needs both hashes (your capture + a post-pipeline ghost).
    local routeMismatch = (st.route and st.route.hash and ref.run and ref.run.routeHash
        and ref.run.routeHash ~= st.route.hash) or false

    local yourPull = st.trackerPull
        or (st.route and st.total > 0 and M.InferPull(st.raw, st.route.cumulativeForces)) or nil
    if yourPull then
        -- Ghost count mapped into the LIVE dungeon's units (the route's cumulative
        -- forces are live units): same total = the exact integer — the old
        -- pct-reconstruction boundary hazard (111.9999 vs 112) is gone by design.
        local ghostRaw = (st.total > 0 and gTotal ~= st.total)
            and (ghostCountNow / gTotal * st.total) or ghostCountNow
        local ghostPull = M.InferPull(ghostRaw, st.route.cumulativeForces) or yourPull
        -- Copy (Fredrik 2026-07-20): the Route's name leads (ellipsized in Lua — the
        -- numbers must never be what gets cut), body stays neutral; ONLY the two pull
        -- tokens carry a verdict — leader green, trailer red, tied = all neutral (a
        -- whole sentence flipping color read as an alarm, not a status).
        local you = string.format("Pull #%d", yourPull)
        local gho = string.format("Ghost #%d", ghostPull)
        if yourPull > ghostPull then
            you, gho = GreenHex() .. you .. "|r", RedHex() .. gho .. "|r"
        elseif ghostPull > yourPull then
            you, gho = RedHex() .. you .. "|r", GreenHex() .. gho .. "|r"
        end
        -- Route metadata (Fredrik 2026-07-20: "use the full meta data"): the name is
        -- stripped of any embedded color codes BEFORE the byte-based ellipsis, then
        -- MDT's createdBy renders as the class-colored creator — same look as MDT's
        -- own dropdown (classFile was resolved at capture, so this works without MDT).
        local prefix = ""
        local name = st.route and st.route.name
        if name then
            prefix = M.Ellipsize(M.StripColors(name), 24)
            local cb = st.route.createdBy
            if cb and cb.name then
                local col = cb.classFile and _G.RAID_CLASS_COLORS and _G.RAID_CLASS_COLORS[cb.classFile]
                prefix = prefix .. " by " .. ((col and col.colorStr)
                    and ("|c" .. col.colorStr .. cb.name .. "|r") or cb.name)
            end
            prefix = prefix .. " · "
        end
        if routeMismatch then gho = gho .. GRAY_HEX .. "*|r" end
        frame.pullText:SetText(prefix .. you .. " vs " .. gho)
        frame.pullText:SetTextColor(Style.TEXT[1], Style.TEXT[2], Style.TEXT[3])
        frame.pullText:Show()
        -- Overflow (his fix 2026-08-09): measured, not guessed. When the
        -- rendered one-liner is wider than the frame's inner width, the pull
        -- half gets its own row and SetPullWrap grows the bar by that row —
        -- with the track pinned in place (the anchor math eats the shift).
        -- Only a route prefix can overflow; the bare pull line always fits.
        local wrap = prefix ~= ""
            and frame.pullText:GetStringWidth() > ((frame:GetWidth() or WIDTH) - 2 * PAD)
        if wrap then
            frame.pullText:SetText((prefix:gsub(" · $", "")))
            frame.pullText2:SetText(you .. " vs " .. gho)
            frame.pullText2:SetTextColor(Style.TEXT[1], Style.TEXT[2], Style.TEXT[3])
            frame.pullText2:Show()
        else
            frame.pullText2:Hide()
        end
        SetPullWrap(wrap)
    else
        frame.pullText:Hide()
        SetPullWrap(false)
    end

    frame.ghostHover.tip = {
        ref.label or "Ghost",
        string.format("Now at %s: %s count · %d/%d bosses",
            M.FormatClock(st.elapsed),
            M.FormatForcesLevel(ghostCountNow, gTotal, countMode, 1), ghostBossesNow, nKills),
    }
    if ref.kind == "rio" and ref.run and ref.run.legacy == "RIO" then
        table.insert(frame.ghostHover.tip,
            "Converted Raider.IO " .. (ref.run.rioSource or "replay") .. " — clock honest to ±3 s")
    end
    if ref.run and ref.run.routeName then
        local line = "Route: " .. ref.run.routeName
        local rd = ref.run.routeHash and KG.Ghosts:RouteForHash(ref.run.routeHash)
        local cb = rd and rd.createdBy
        if cb and cb.name then
            line = line .. " (by " .. cb.name .. (cb.realm and ("-" .. cb.realm) or "") .. ")"
        end
        table.insert(frame.ghostHover.tip, line)
        if routeMismatch then
            table.insert(frame.ghostHover.tip,
                "Different route than your MDT pick — its pull # (*) projects onto yours")
        end
        if rd and rd.pulls and _G.MDT then
            table.insert(frame.ghostHover.tip, "Click: load this route into MDT")
        end
    end
    if ref.run and ref.run.importedFrom then
        table.insert(frame.ghostHover.tip, "From: " .. ref.run.importedFrom)
    end
    frame.playerHover.tip = {
        "You",
        string.format("%s · %s count · %d boss%s dead", M.FormatClock(st.elapsed),
            M.FormatForcesLevel(st.raw, st.total, countMode, 1),
            st.bosses, st.bosses == 1 and "" or "es"),
        gapArmed and (M.FormatDelta(delta) .. " vs ghost")
            or "Gap arms when both sides have count",
    }
    if (st.deathCount or 0) > 0 then
        local lost = st.deathTimeLost and st.deathTimeLost > 0
            and (" (-" .. M.FormatClock(st.deathTimeLost) .. " on the timer)") or ""
        table.insert(frame.playerHover.tip, string.format("Deaths: %d%s", st.deathCount, lost))
    end
    frame:Show()
    if swAge and swAge < 1.5 then
        KG.Splits:Refresh() -- switch row-glow animates smoother than the 0.5 s ticker
    end
end

--- Dock below the EllesmereUI Mythic+ Timer standalone frame when attach mode is on and
--- that frame exists (it is created lazily by EllesmereUIMythicTimer, hence re-checked on
--- every refresh, not just at login). Width follows the timer so the stack reads as one UI.
--- When free, the position belongs to Edit Mode (saved as point/relPoint/x/y in db.pos).
--- Free-floating, the BAR follows the ROSTER (Fredrik 2026-07-29): switch on enough
--- columns and the panel needs more than 360, so the bar widens to match instead of
--- letting the panel hang off its corner — the two read as one window. Docked is the
--- other contract entirely: there the timer's width is law, the bar never moves, and
--- the panel drops the columns that do not fit (Splits.Layout).
--- Never narrower than the design width, and never widened for a panel that is
--- switched off.
local function FreeWidth()
    if KG.db.splits == false then return WIDTH end
    local need = KG.Splits and KG.Splits.LayoutWidth and KG.Splits.LayoutWidth() or 0
    return need > WIDTH and need or WIDTH
end

--- Is the bar currently docked under the EllesmereUI timer? (Splits asks: docked
--- means fit the columns to the width; free means the bar will follow them.)
function Bar.IsDocked()
    return frame ~= nil and frame._attachMode == "ellesmere"
end

local function ApplyFreePosition()
    local extra = pullWrapped and PULL_LINE_H or 0
    frame:SetSize(FreeWidth(), BAR_H + extra)
    -- The wrap row must appear BELOW the bar: the track's screen position is
    -- sacred mid-run. A TOP-ish saved anchor grows downward on its own; a
    -- CENTER anchor would lift the track by half the row and BOTTOM by all of
    -- it, so the offset eats exactly that shift. Applied at SetPoint time and
    -- never written back to db.pos — Edit Mode drags happen in the preview,
    -- whose demo route line is short, so a drag never saves while wrapped.
    local function dy(point)
        if extra == 0 or point:find("TOP") then return 0 end
        if point:find("BOTTOM") then return -extra end
        return -extra / 2
    end
    local pos = KG.db.pos
    if pos and pos.point then
        frame:SetPoint(pos.point, UIParent, pos.relPoint or pos.point,
            pos.x or 0, (pos.y or 0) + dy(pos.point))
    elseif pos and pos.x then -- legacy pre-EditMode format (center in screen coords)
        frame:SetPoint("CENTER", UIParent, "BOTTOMLEFT", pos.x, pos.y + dy("CENTER"))
    else
        frame:SetPoint("CENTER", UIParent, "CENTER", 0, 260 + dy("CENTER"))
    end
end

local function UpdateAttachment()
    local target = KG.db.attach == "ellesmere" and _G.EllesmereUIMythicTimerStandalone or nil
    local mode = target and "ellesmere" or "free"
    if frame._attachMode == mode then
        -- Free-floating, the roster's column set can change under us (an Edit Mode
        -- checkbox) without the dock state changing at all — so the width is kept
        -- in step every refresh, not just when the anchoring flips.
        if mode == "free" then
            local w = FreeWidth()
            if math.abs((frame:GetWidth() or 0) - w) > 0.5 then frame:SetWidth(w) end
        end
        return
    end
    frame._attachMode = mode
    frame:ClearAllPoints()
    if target then
        frame:SetPoint("TOPLEFT", target, "BOTTOMLEFT", 0, -4)
        frame:SetPoint("TOPRIGHT", target, "BOTTOMRIGHT", 0, -4)
        frame:SetHeight(BAR_H + (pullWrapped and PULL_LINE_H or 0))
    else
        ApplyFreePosition()
    end
end

--- Enter/leave the two-line pull mode (forward-declared with the state at the
--- top of the file — the Update hot path calls this, the position code above
--- does the applying). Docked, the TOP anchors make the growth downward for
--- free; floating, ApplyFreePosition's anchor math pins the track.
SetPullWrap = function(wrap)
    wrap = wrap and true or false
    if pullWrapped == wrap or not frame then return end
    pullWrapped = wrap
    frame.pullText:ClearAllPoints()
    frame.pullText:SetPoint("BOTTOM", 0, wrap and (6 + PULL_LINE_H) or 6)
    if not wrap then frame.pullText2:Hide() end
    if frame._attachMode == "ellesmere" then
        frame:SetHeight(BAR_H + (wrap and PULL_LINE_H or 0))
    elseif frame._attachMode then -- free; nil = pre-first-attach, height lands there
        frame:ClearAllPoints()
        ApplyFreePosition()
    end
end

--- Force re-evaluation of docking/position on the next refresh (Edit Mode callbacks).
function Bar:InvalidatePosition()
    if frame then frame._attachMode = nil end
end

--- Anchor for the splits panel: below whatever the bar currently is.
function Bar.GetFrame()
    if not frame then Build() end
    return frame
end

--- Post-run verdict shown in the bar window itself (chat line is just an echo): the
--- FINISH PHOTO, drawn deliberately. The last live frame can be garbage — Blizzard
--- clears the scenario criteria a beat before CHALLENGE_MODE_COMPLETED, so the final
--- tick may show forces collapsed to 0 (Fredrik's timed-MC report: he won by 6:53 but
--- the frozen track showed him far behind in red). Instead: YOU parked at the finish
--- line, the ghost at the road position it had when you crossed, green victory zone
--- between. Sticks around until the X is clicked or a new key starts.
function Bar:ShowSummary(s)
    Style.RefreshPanel(frame)
    frame.refLabel:SetText("vs " .. (s.label or "—"))
    if s.diff then
        local c = (s.diff >= 0) and Style.GREEN or Style.RED
        frame.delta:SetText(M.FormatDelta(s.diff))
        frame.delta:SetTextColor(c[1], c[2], c[3])
    else
        frame.delta:SetText("")
    end
    local aR, aG, aB = Style.GetAccent()
    frame.subDelta:SetText(M.FormatClock(s.finalTime or 0) .. " · " .. M.TierLabel(s.chests))
    frame.subDelta:SetTextColor(aR, aG, aB)
    -- The photo is the one place the close button shows, and this readout is the
    -- widest in the addon ("13:04 · +3") — so it asks for the corner to be left free.
    PlaceNumbers(true)
    frame.pullText:Hide()
    SetPullWrap(false) -- the photo never wraps: the board needs the frame at BAR_H
    for i = 1, #frame.runners do frame.runners[i]:Hide() end
    if frame.deathMarks then
        for i = 1, #frame.deathMarks do frame.deathMarks[i]:Hide() end
    end
    if frame.ghostMarks then
        for i = 1, #frame.ghostMarks do frame.ghostMarks[i]:Hide() end
    end
    for i = 1, 3 do frame.paceCars[i]:Hide() end
    frame.sweptZone:Hide() -- the race is over; nothing is chasing you in the photo
    if frame.walkAnim:IsPlaying() then frame.walkAnim:Stop() end -- parked on the podium
    if frame.dazedAnim:IsPlaying() then frame.dazedAnim:Stop() end
    if frame.ghostDazed:IsPlaying() then frame.ghostDazed:Stop() end -- both runners still for the photo
    frame._kb, frame._kbPot, frame._lastDeathCount, frame._lastTimeLost = nil, nil, nil, nil -- no knockback residue in the photo

    -- H9 (his order 2026-08-09): the road stands down for the photo. The
    -- track hides WHOLE — cursors, gap zone, skulls and the ghost badge are
    -- its children and ride along (the badge's route-load click goes with it;
    -- /kg route stays the post-run door) — and the Finish Stats band stands
    -- where it ran: the numbers the race was actually about, next to the
    -- checkered flag. (The full-road photo this replaces lived here from H5;
    -- Update() re-shows the track for the next run.)
    frame.track:Hide()
    local st = s.stats or {}
    local L = {}
    -- deaths — a clean run wears the verdict green; a count stays neutral.
    if (st.deaths or 0) == 0 then
        L[#L + 1] = GRAY_HEX .. "deaths|r   " .. GreenHex() .. "none — deathless|r"
    else
        L[#L + 1] = GRAY_HEX .. "deaths|r   " .. st.deaths
            .. ((st.timeLost and st.timeLost > 0)
                and (GRAY_HEX .. "  ·  |r" .. M.FormatClock(st.timeLost) .. GRAY_HEX .. " lost|r") or "")
    end
    -- forces — the finish reading plus the overkill, in the player's chosen
    -- readout (the percentDisplay option every other site follows).
    if st.raw and st.total and st.total > 0 then
        local shown = KG.db.percentDisplay ~= false
            and string.format("%.1f%%", st.raw / st.total * 100)
            or (st.raw .. "/" .. st.total)
        local over = st.raw - st.total
        L[#L + 1] = GRAY_HEX .. "forces|r   " .. shown
            .. (over > 0 and (GRAY_HEX .. "  ·  +" .. over .. " extra|r") or "")
    end
    -- boss laps vs the raced ghost — best and worst, speedrun-signed
    -- (negative = you killed it faster), the roster lap columns' own colors.
    -- The LABEL says "bosses" (his 2026-08-09 call: "laps" is racing jargon
    -- with no meaning in the game's own language); "lap" stays the internal
    -- term everywhere the player can't see.
    if st.bestIdx then
        local function Lap(i, d)
            return "B" .. i .. " " .. (d <= 0 and GreenHex() or RedHex()) .. M.FormatDelta(d) .. "|r"
        end
        local txt = GRAY_HEX .. "bosses|r   " .. Lap(st.bestIdx, st.best)
        if st.worstIdx and st.worstIdx ~= st.bestIdx then
            txt = txt .. GRAY_HEX .. "  ·  |r" .. Lap(st.worstIdx, st.worst)
        end
        L[#L + 1] = txt .. GRAY_HEX .. "  vs the ghost|r"
    end
    -- the chest that got away — or, on a +3, the room to spare inside it.
    if st.nextTier and st.tierGap and st.tierGap > 0 then
        L[#L + 1] = GRAY_HEX .. "next chest|r   " .. M.TierLabel(st.nextTier)
            .. GRAY_HEX .. " was |r" .. M.FormatClock(st.tierGap) .. GRAY_HEX .. " away|r"
    elseif not st.nextTier and st.tierGap then
        L[#L + 1] = GRAY_HEX .. "cushion|r   " .. M.FormatClock(st.tierGap)
            .. GRAY_HEX .. " inside the +3 cutoff|r"
    end
    for i = 1, 4 do
        frame.statLines[i]:SetText(L[i] or "")
    end
    -- The celebration paints once per summary (s.at gates it): repainting the
    -- portrait and restarting an AnimationGroup every 0.1 s pass would stutter.
    if frame.photoBoard._for ~= s.at then
        frame.photoBoard._for = s.at
        if not pcall(SetPortraitTexture, frame.cheer, "player") then
            frame.cheer:SetTexture("Interface\\Icons\\Achievement_PVP_A_01")
        end
        frame.cheer:SetTexCoord(0, 1, 0, 1)
        local timedRun = (s.chests or 0) >= 1
        frame.flag:SetShown(timedRun)
        if frame.cheerJump:IsPlaying() then frame.cheerJump:Stop() end
        if frame.cheerSulk:IsPlaying() then frame.cheerSulk:Stop() end
        if timedRun then frame.cheerJump:Play() else frame.cheerSulk:Play() end
    end
    frame.photoBoard:Show()

    -- ── The End Screen (his sketch 2026-08-07) ────────────────────────────────
    -- Painted per pass like the rest of the photo, so option flips (share
    -- checkbox, channel, accent) land on an already-open board. Shows with
    -- EVERY photo, Depleted included — only the share row stays stored-timed-
    -- gated. Rows sort fastest first; your fresh run is the anchor row: your
    -- portrait, "you", and an empty "vs" cell (the photo's headline already
    -- carries your verdict). A ghost of your own is tagged "you" on the live
    -- roster — here every ghost wears its RECORDING CHARACTER's name, the
    -- Ghost Library way (his 2026-08-08 rule: his own old run says "Boonkd").
    -- The Recorder resolves the names into summary.rows; the "ghost" arm
    -- below is only the failsafe for an own-run tag that arrived unresolved —
    -- better an anonymous ghost than a second "you".
    Style.RefreshPanel(frame.endPanel)
    local margin = s.par and s.par > 0 and (s.par - (s.finalTime or 0)) or nil
    if margin then
        local good = margin >= 0
        frame.endHeader:SetText(M.FormatClock(s.finalTime or 0) .. "  ·  "
            .. (good and GreenHex() or RedHex()) .. M.FormatClock(math.abs(margin))
            .. (good and " under the timer|r" or " over the timer|r"))
    else
        frame.endHeader:SetText(M.FormatClock(s.finalTime or 0))
    end

    local accentHex = Style.AccentHex()
    local list = {}
    for _, e in ipairs(s.rows or {}) do
        if e.run then
            list[#list + 1] = { tag = e.tag, dur = e.run.durationSec or 0,
                level = e.run.level, chests = e.run.chests, run = e.run }
        end
    end
    list[#list + 1] = { you = true, dur = s.finalTime or 0, level = s.level, chests = s.chests }
    table.sort(list, function(a, b) return a.dur < b.dur end)
    -- Icon paints gate on s.at like the cheer portrait below (council
    -- 2026-08-09: they ran ungated at 10 Hz on a static board, against this
    -- file's own _kgIconKey standard). Texts stay per-pass — they are the
    -- option-reactive part.
    local repaintIcons = frame.endPanel._for ~= s.at
    frame.endPanel._for = s.at
    local youRow
    for i = 1, 3 do
        local row, e = frame.endRows[i], list[i]
        if e then
            if e.you then
                youRow = row
                if repaintIcons then
                    if not pcall(SetPortraitTexture, row.icon, "player") then
                        row.icon:SetTexture("Interface\\Icons\\Achievement_PVP_A_01")
                    end
                    row.icon:SetTexCoord(0, 1, 0, 1)
                end
            elseif repaintIcons then
                ApplyRunnerIcon(row.icon, e.run)
            end
            local name = e.you and "you" or (e.tag == "you" and "ghost" or (e.tag or "?"))
            row.name:SetText("|cff" .. accentHex .. M.Ellipsize(name, 8) .. "|r")
            if e.level then
                local off = s.level and e.level ~= s.level
                row.level:SetText((off and GRAY_HEX or "") .. "+" .. e.level .. (off and "|r" or ""))
            else
                row.level:SetText(GRAY_HEX .. "—|r")
            end
            if e.chests then
                row.chest:SetText(e.chests > 0 and M.TierLabel(e.chests) or (RedHex() .. "—|r"))
            else
                row.chest:SetText(GRAY_HEX .. "—|r")
            end
            row.time:SetText(M.FormatClock(e.dur))
            -- "vs you" in the roster's sign language: positive = you finished
            -- ahead of this ghost. Neutral grey — the verdict color budget
            -- belongs to the header and the photo (the roster's own rule).
            row.vs:SetText(e.you and "" or (GRAY_HEX .. M.FormatDelta(e.dur - (s.finalTime or 0)) .. "|r"))
            row:Show()
        else
            row:Hide()
        end
    end
    local n = math.min(#list, 3)

    -- The share glyph, on YOUR row's right edge (his 2026-08-08 order — the
    -- row it sits on is the run it shares, and the board ends at its last
    -- row): only a stored, timed run carries one (summary.share), and the
    -- checkbox can veto it. No face label; the tooltip names the channel.
    local sh = s.share
    if sh and youRow and KG.db.photoShare ~= false and KG.Comm then
        frame.shareBtn.tex:SetVertexColor(Style.GetAccent())
        frame.shareBtn:ClearAllPoints()
        frame.shareBtn:SetPoint("RIGHT", youRow, "RIGHT", 0, 0)
        frame.shareBtn.tipText = "Share — send this ghost to "
            .. (KG.db.photoShareChannel == "group" and "your group" or "guild chat")
        frame.shareBtn:Show()
    else
        frame.shareBtn:Hide()
    end
    frame.endPanel:SetHeight(24 + n * 15 + 5)
    frame.endPanel:Show()

    frame.closeBtn:Show()
    frame:Show()
end

-- ── Login placement: the MOVE ME show (Fredrik 2026-07-28) ───────────────────
-- A fresh install's bar was invisible until its first key, and Edit Mode didn't
-- pick the frame up until the bar had drawn once (his field report) — a catch-22
-- for brand-new users. So logins stage the bar running the demo loops (the
-- /kg test rotation, chat-quiet) with a drag handle above it, UNTIL the bar has
-- been PLACED: dragging the handle, dragging in Edit Mode, or closing the handle
-- ("I'm happy where it is" — dock users never need a drag) all stamp db.placed,
-- and one placement covers every character. A key starting (fresh, or ADOPTED
-- on a reconnect mid-run — both recorder doors kill the show), Edit Mode
-- opening, or /kg test only ends the show for the session — unplaced means the
-- offer returns next login, on any character. Combat hides the whole show
-- (Refresh's stand-down below) and it returns when the fight ends: an
-- unrequested tutorial never sits over live play.
local function EnsureMoveMe()
    if frame.moveMe then return frame.moveMe end
    local m = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    m:SetPoint("BOTTOMLEFT", frame, "TOPLEFT", 0, 4)
    m:SetPoint("BOTTOMRIGHT", frame, "TOPRIGHT", 0, 4)
    m:SetHeight(24)
    Style.SkinPanel(m)
    m:EnableMouse(true)
    m:RegisterForDrag("LeftButton")
    m.text = m:CreateFontString(nil, "OVERLAY")
    Style.SetFont(m.text, 11)
    m.text:SetPoint("CENTER", -8, 0)
    m.text:SetTextColor(Style.GetAccent())
    m.text:SetText("Keystone Ghost — drag me into place, then close me")
    -- Dragging moves the BAR (the strip rides it); same save + undock rules as
    -- an Edit Mode drag, minus the chat note — this IS the placement tutorial.
    m:SetScript("OnDragStart", function() frame:StartMoving() end)
    m:SetScript("OnDragStop", function()
        frame:StopMovingOrSizing()
        local point, _, relPoint, x, y = frame:GetPoint()
        KG.db.pos = { point = point, relPoint = relPoint, x = x, y = y }
        KG.db.attach = nil -- dragged free: the Edit Mode drag rule
        KG.db.placed = true -- PLACED: the show stands down for good (all characters)
        Bar:InvalidatePosition()
        Bar:Refresh()
    end)
    local close = Style.CloseButton(m, function()
        KG.db.placed = true -- deliberate close = "keep it right here": that IS placement
        Bar.EndIntro()
    end)
    close:SetPoint("RIGHT", -4, 0)
    frame.moveMe = m
    return m
end

--- End the first-login show (close ×, a real key, Edit Mode, /kg test). Safe to
--- call any time — no-ops unless the intro is running.
function Bar.EndIntro()
    if not KG.introMode then return end
    KG.introMode = nil
    Bar.ResetTestLoop() -- drop the demo cast; a later /kg test reseeds fresh
    if frame and frame.moveMe then frame.moveMe:Hide() end
    Bar:Refresh()
    KG.Splits:Refresh()
end

function Bar:Refresh()
    if not frame then Build() end
    UpdateAttachment()
    if KG.db.enabled == false and not KG.editModePreview then frame:Hide(); return end
    -- Raid stand-down (M+-only for now, Fredrik 2026-07-22): inside a raid
    -- instance nothing draws — a left-on /kg test demo and an undismissed
    -- Finish Photo included. Edit Mode preview keeps the same exemption as
    -- the enabled toggle above (placement is a config surface, not a race).
    -- Recording never ran in raids (every recorder path is C_ChallengeMode-
    -- gated); this stands the DISPLAY down. Splits follows via bar:IsShown().
    if KG.Scenario:InRaidInstance() and not KG.editModePreview then frame:Hide(); return end
    -- The MOVE ME handle rides above the bar during the placement show only
    -- (a child frame: it hides with the bar wherever the bar hides).
    if KG.introMode then
        -- Combat stand-down (Fredrik 2026-07-28: placement "must not disrupt
        -- play if it appears mid combat"): a reconnect can land an unplaced
        -- install straight into a fight, and the show persists until placed —
        -- a demo race and a mouse-blocking strip have no business over live
        -- combat. The 0.5 s ticker keeps calling Refresh, so the show returns
        -- within a tick of combat dropping; placement state is untouched.
        if InCombatLockdown() then frame:Hide(); return end
        EnsureMoveMe():Show()
    elseif frame.moveMe and frame.moveMe:IsShown() then
        frame.moveMe:Hide()
    end
    if KG.testMode and not KG.editModePreview and TestPhotoHold() then
        -- The demo's 5 s photo hold (his order 2026-08-09): the loop's own
        -- End Screen, drawn by the one real ShowSummary — same photo, same
        -- board, no share glyph (nothing stored to stream).
        Bar:ShowSummary(test.summary)
    elseif KG.testMode or KG.editModePreview or KG.introMode
        or (KG.Recorder:IsActive() and KG.Recorder.currentRef) then
        frame.closeBtn:Hide() -- the number block places itself (PlaceNumbers)
        frame.endPanel:Hide() -- the End Screen is the photo's alone
        frame.photoBoard:Hide() -- so are the Finish Stats and the flag…
        if frame.cheerJump:IsPlaying() then frame.cheerJump:Stop() end
        if frame.cheerSulk:IsPlaying() then frame.cheerSulk:Stop() end
        frame.photoBoard._for = nil -- …and a re-shown photo repaints/replays
        Bar:Update()
    elseif KG.Recorder.summary then
        Bar:ShowSummary(KG.Recorder.summary)
    else
        frame:Hide()
    end
end
