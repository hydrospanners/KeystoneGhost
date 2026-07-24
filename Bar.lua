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
local WIDTH, BAR_H, TRACK_H, PAD = 360, 96, 16, 12
local frame

-- Style.GREEN / Style.RED / Splits-grey as inline escapes — for coloring single
-- tokens inside an otherwise neutral FontString.
local GREEN_HEX, RED_HEX, GRAY_HEX = "|cff4dcc4d", "|cffe65959", "|cff8c8c8c"

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
    if KG.testMode then
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
        print("|cff88ccffKeystoneGhost|r: test loop — Raider.IO ghost only (the first-run look).")
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

    local label
    if raced == test.run then
        label = test.label or "Test ghost (27:00)"
    elseif raced == test.rival then
        label = "Rival ghost (" .. M.FormatClock(raced.durationSec or 0) .. ")"
    else
        local rr = KG.Ghosts:RefForRun(raced)
        label = rr and rr.label or "Test ghost"
    end
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

--- Shared live state for the bar and the splits panel (nil when nothing to race).
--- Edit Mode preview reuses the synthetic test race so the frame has something to show.
function Bar.GetLiveState()
    if KG.testMode or KG.editModePreview then return TestState() end
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
    frame.delta:SetPoint("TOPRIGHT", -PAD - 3, -4)
    Style.SetFont(frame.delta, 13)

    -- Count delta lives directly under the time delta (one glance, both dimensions).
    frame.subDelta = frame:CreateFontString(nil, "OVERLAY")
    frame.subDelta:SetPoint("TOPRIGHT", -PAD - 3, -20)
    Style.SetFont(frame.subDelta, 10)

    frame.track = CreateFrame("Frame", nil, frame)
    frame.track:SetPoint("TOPLEFT", PAD, -38)
    frame.track:SetPoint("TOPRIGHT", -PAD, -38) -- width follows the frame (attach mode resizes it)
    frame.track:SetHeight(TRACK_H)
    local bg = frame.track:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetTexture("Interface\\Buttons\\WHITE8x8")
    local bb = Style.BAR_BG
    bg:SetVertexColor(bb[1], bb[2], bb[3], bb[4])

    -- Pace cars: moving marks that drive the road at +3 / +2 / +1 (par) pace — colors
    -- and positions applied per update. On a road there are no static time positions.
    frame.paceCars = {
        HoverTick(frame.track, Style.TICK1, 0.4),
        HoverTick(frame.track, Style.TICK1, 0.4),
        HoverTick(frame.track, Style.TICK1, 0.4),
    }
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
    Bar.RefreshPlayerIcon(true)

    -- The walk cycle ("it would be fking hilarious" — Fredrik, verbatim): a tiny hop
    -- while you're actually moving down the road. Stops when your course freezes —
    -- so you visibly STAND at a boss while fighting it. Edit Mode toggle.
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

    -- Close button for the post-run summary (hidden during a run) — the same ×
    -- the Ghost Library wears, not the default red X (Fredrik 2026-07-21).
    frame.closeBtn = Style.CloseButton(frame, function()
        KG.Recorder.summary = nil
        Bar:Refresh()
    end)
    frame.closeBtn:SetPoint("TOPRIGHT", -1, -1)
    frame.closeBtn:Hide()


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
    if KG.testMode or KG.editModePreview then
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
--- this reapplies every call — two secrets can't be diffed — so a mid-run marker
--- change lands within a tick. Portraits are often BLACK until the client fires a
--- portrait update, so Core re-calls this with force on UNIT_PORTRAIT_UPDATE and
--- zone-in; the no-marker path stays cached.
function Bar.RefreshPlayerIcon(force)
    local tex = frame and frame.playerIcon
    if not tex then return end
    local marker = KG.Scenario:GetPlayerRaidMarkerOpaque() -- opaque: possibly secret
    if marker ~= nil and tex.SetSpriteSheetCell then
        tex:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcons")
        if pcall(tex.SetSpriteSheetCell, tex, marker, 4, 4) then
            tex._kgIconKey = "marker"
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
    local capMul = (KG.testMode or KG.editModePreview) and TEST_SPEED or 1
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

    -- Finish line: scrolls in from the right during the final stretch.
    if vx(1) <= 1.001 then
        frame.finishLine:ClearAllPoints()
        frame.finishLine:SetPoint("LEFT", frame.track, "LEFT", px(1) - 1, 0)
        frame.finishLine:Show()
    else
        frame.finishLine:Hide()
    end

    -- Pace cars: linear racers that complete the road in exactly par×frac. The +1 car
    -- is the sweeper — if it passes you, the key depletes. +2/+3 cars are optional.
    if st.par and st.par > 0 and st.elapsed then
        local cars = { { 0.6, "+3" }, { 0.8, "+2" }, { 1.0, "+1" } }
        for i = 1, 3 do
            local frac, tag = cars[i][1], cars[i][2]
            local f = frame.paceCars[i]
            if tag == "+1" or KG.db.chestTicks ~= false then
                local carCourse = st.elapsed / (st.par * frac)
                local dim = pinned(carCourse) ~= 0 and 0.5 or 1 -- lurking at an edge
                f:ClearAllPoints()
                f:SetPoint("CENTER", frame.track, "LEFT", px(carCourse), 0)
                if tag == "+1" then
                    f.tex:SetVertexColor(0.9, 0.35, 0.35, 0.8 * dim) -- the sweeper
                else
                    f.tex:SetVertexColor(0.85, 0.85, 0.85, 0.45 * dim)
                end
                f.tip = {
                    tag .. " pace car",
                    "Finishes in exactly " .. M.FormatClock(st.par * frac),
                    tag == "+1" and "If it passes you, the key depletes"
                        or ("Stay ahead of it to keep the " .. tag),
                }
                f:Show()
            else
                f:Hide()
            end
        end
    else
        for i = 1, 3 do frame.paceCars[i]:Hide() end
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
    local kbSrc = (KG.testMode or KG.editModePreview) and "test" or tostring(ref)
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
                (entry.tag or M.TierLabel(run.chests)) .. " ghost — " .. M.FormatClock(run.durationSec or 0),
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
            you, gho = GREEN_HEX .. you .. "|r", RED_HEX .. gho .. "|r"
        elseif ghostPull > yourPull then
            you, gho = RED_HEX .. you .. "|r", GREEN_HEX .. gho .. "|r"
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
    else
        frame.pullText:Hide()
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
local function ApplyFreePosition()
    frame:SetSize(WIDTH, BAR_H)
    local pos = KG.db.pos
    if pos and pos.point then
        frame:SetPoint(pos.point, UIParent, pos.relPoint or pos.point, pos.x or 0, pos.y or 0)
    elseif pos and pos.x then -- legacy pre-EditMode format (center in screen coords)
        frame:SetPoint("CENTER", UIParent, "BOTTOMLEFT", pos.x, pos.y)
    else
        frame:SetPoint("CENTER", UIParent, "CENTER", 0, 260)
    end
end

local function UpdateAttachment()
    local target = KG.db.attach == "ellesmere" and _G.EllesmereUIMythicTimerStandalone or nil
    local mode = target and "ellesmere" or "free"
    if frame._attachMode == mode then return end
    frame._attachMode = mode
    frame:ClearAllPoints()
    if target then
        frame:SetPoint("TOPLEFT", target, "BOTTOMLEFT", 0, -4)
        frame:SetPoint("TOPRIGHT", target, "BOTTOMRIGHT", 0, -4)
        frame:SetHeight(BAR_H)
    else
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
    frame.delta:ClearAllPoints()
    frame.delta:SetPoint("TOPRIGHT", -22, -4) -- make room for the close button
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
    frame.pullText:Hide()
    for i = 1, #frame.runners do frame.runners[i]:Hide() end
    if frame.deathMarks then
        for i = 1, #frame.deathMarks do frame.deathMarks[i]:Hide() end
    end
    if frame.ghostMarks then
        for i = 1, #frame.ghostMarks do frame.ghostMarks[i]:Hide() end
    end
    for i = 1, 3 do frame.paceCars[i]:Hide() end
    if frame.walkAnim:IsPlaying() then frame.walkAnim:Stop() end -- parked on the podium
    if frame.dazedAnim:IsPlaying() then frame.dazedAnim:Stop() end
    if frame.ghostDazed:IsPlaying() then frame.ghostDazed:Stop() end -- both runners still for the photo
    frame._kb, frame._kbPot, frame._lastDeathCount, frame._lastTimeLost = nil, nil, nil, nil -- no knockback residue in the photo

    -- The finish photo (full-road view, no camera).
    local ref = s.ref
    if ref and ref.run then
        local W = frame.track:GetWidth() or WIDTH
        frame.finishLine:ClearAllPoints()
        frame.finishLine:SetPoint("LEFT", frame.track, "LEFT", W - 2, 0)
        frame.finishLine:Show()
        local nBosses = ref.nBosses or (ref.run.bossKills and #ref.run.bossKills) or 0
        local gCourse = math.min(1, M.CourseAt(ref.run, s.finalTime or 0, nBosses))
        local gx, ex = gCourse * W, W

        frame.playerCursor:ClearAllPoints()
        frame.playerCursor:SetPoint("LEFT", frame.track, "LEFT", ex - 2, 0)
        frame.playerHover:ClearAllPoints()
        frame.playerHover:SetPoint("BOTTOM", frame.track, "TOPLEFT", ex - 4, 1)
        frame.ghostCursor:ClearAllPoints()
        frame.ghostCursor:SetPoint("LEFT", frame.track, "LEFT", gx - 1, 0)
        frame.ghostHover:ClearAllPoints()
        frame.ghostHover:SetPoint("TOP", frame.track, "BOTTOMLEFT", gx, -1)
        ApplyGhostIcon(frame.ghostIcon, ref)

        local won = (s.diff or 0) >= 0
        local c = won and Style.GREEN or Style.RED
        frame.playerCursor:SetVertexColor(c[1], c[2], c[3], 1)
        if ex - gx >= 2 then
            local z = frame.gapZone
            z._faint:SetRGBA(c[1], c[2], c[3], 0.1)
            z._strong:SetRGBA(c[1], c[2], c[3], 0.55)
            z:SetGradient("HORIZONTAL", z._faint, z._strong)
            z:ClearAllPoints()
            z:SetPoint("TOPLEFT", frame.track, "TOPLEFT", gx, 0)
            z:SetWidth(ex - gx)
            z:Show()
        else
            frame.gapZone:Hide()
        end
        frame.playerHover.tip = { "You — finished", M.FormatClock(s.finalTime or 0) .. " · " .. M.TierLabel(s.chests) }
        frame.ghostHover.tip = { s.label or "Ghost",
            won and ("Was here when you crossed the line") or ("Finished first — " .. M.FormatClock(ref.durationSec or 0)) }
    end

    frame.closeBtn:Show()
    frame:Show()
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
    if KG.testMode or KG.editModePreview or (KG.Recorder:IsActive() and KG.Recorder.currentRef) then
        frame.closeBtn:Hide()
        frame.delta:ClearAllPoints()
        frame.delta:SetPoint("TOPRIGHT", -PAD - 3, -4)
        Bar:Update()
    elseif KG.Recorder.summary then
        Bar:ShowSummary(KG.Recorder.summary)
    else
        frame:Hide()
    end
end
