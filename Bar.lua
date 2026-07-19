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

-- ── Test mode: synthetic ghost + simulated player so the bar can be inspected anywhere ──
local TEST_SPEED = 10 -- 10x: a ~28min run demos in ~3min; 20x made real data look jerky
local test = {}

--- Prefer REAL recordings for the test race: if any dungeon has 3+ stored ghosts
--- (across characters/levels — key level is irrelevant for a demo), race the fastest
--- and roster the next two. Falls back to the synthetic ghost otherwise.
local function RealTestData()
    local byMap = {}
    for _, maps in pairs(KG.db.runs) do
        for mapID, byLevel in pairs(maps) do
            for _, tiers in pairs(byLevel) do
                for _, run in pairs(tiers) do
                    if run.snapshots and #run.snapshots >= 3 and run.durationSec then
                        byMap[mapID] = byMap[mapID] or {}
                        table.insert(byMap[mapID], run)
                    end
                end
            end
        end
    end
    local best
    for _, list in pairs(byMap) do
        if #list >= 3 and (not best or #list > #best) then best = list end
    end
    if not best then return false end
    table.sort(best, function(a, b) return a.durationSec < b.durationSec end)
    test.run, test.run3, test.run2 = best[1], best[2], best[3]
    test.par = best[1].parTimeSec or 1800
    test.label = string.format("Test: your %s ghost (%s)",
        M.TierLabel(best[1].chests), M.FormatClock(best[1].durationSec))
    return true
end

local function BuildTestData()
    if RealTestData() then
        test.start = GetTime()
        return
    end
    local par, dur = 1800, 1620
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
        local pct = math.min(100, trashTime(t) / (dur - 60 * #bossKills) * 100)
        local bosses = 0
        for _, bk in ipairs(bossKills) do if t >= bk then bosses = bosses + 1 end end
        snaps[#snaps + 1] = { t, pct, bosses }
    end
    snaps[#snaps + 1] = { dur, 100, #bossKills }
    local pcts = {}
    for i, bk in ipairs(bossKills) do pcts[i] = M.SampleAt(snaps, bk) end
    test.run = {
        snapshots = snaps, bossKills = bossKills, durationSec = dur,
        bossNames = { "Test Boss One", "Test Boss Two", "Test Boss Three" },
        bossPcts = pcts, level = 12, chests = 2,
        deaths = { { 700, 1 }, { 710, 2 } },
        routeName = "Test route",
    }
    -- Two manufactured roster fillers (time-scaled copies of the base run) so /kg test
    -- exercises the full 3-row roster: a slower own +1 and a faster "imported" +3.
    local function ScaledRun(f, chests, importedFrom)
        local s2, k2 = {}, {}
        for i, s in ipairs(snaps) do s2[i] = { s[1] * f, s[2], s[3] } end
        for i, k in ipairs(bossKills) do k2[i] = k * f end
        return {
            snapshots = s2, bossKills = k2, durationSec = dur * f,
            bossNames = test.run.bossNames, bossPcts = pcts, level = 12,
            chests = chests, routeName = "Test route", importedFrom = importedFrom,
            completedAt = (time and time() or 0) - 86400,
        }
    end
    test.run2 = ScaledRun(1.09, 1)                                -- own +1, 29:26
    test.run3 = ScaledRun(0.926, 3, "Boonkerz-TarrenMill-DRUID")  -- imported +3, 25:00
    test.par = par
    test.start = GetTime()
    -- 12 even pulls over a 300-count dungeon for the pull indicator preview.
    test.route = { cum = {}, nPulls = 12, name = "Test route" }
    for i = 1, 12 do test.route.cum[i] = 25 * i end
end

local function TestTag(run)
    return (run.importedFrom and run.importedFrom:match("^([^%-]+)")) or M.TierLabel(run.chests)
end

local function TestState()
    if not test.run then BuildTestData() end
    local elapsed = (GetTime() - test.start) * TEST_SPEED
    if elapsed > test.run.durationSec * 1.05 then test.start = GetTime(); elapsed = 0 end
    local simT = elapsed * 1.12 + 25 -- simulated player: head start + growing lead
    local pct = M.SampleAt(test.run.snapshots, simT)
    local bosses, liveKills = 0, {}
    for _, bk in ipairs(test.run.bossKills or {}) do
        if simT >= bk then
            bosses = bosses + 1
            liveKills[bosses] = math.max(0, (bk - 25) / 1.12) -- when the sim player got there
        end
    end
    local roster = {}
    if test.run3 then roster[#roster + 1] = { run = test.run3, tag = TestTag(test.run3) } end
    if test.run2 then roster[#roster + 1] = { run = test.run2, tag = TestTag(test.run2) } end
    -- Simulated group deaths (Fredrik 2026-07-19: verify the Knockback + Death Pot in
    -- the demo): one death, then two in a row, then one — repeating every ~30
    -- sim-seconds, so both the single stumble and the pot-gathered double show.
    -- Doubles land as TWO ticks (0.8 sim-s apart) so the second death arrives while
    -- the first knock is animating — that's the Death Pot path, not just a big knock.
    local deaths, dT, dDouble = 0, 45, false
    while dT <= elapsed do
        deaths = deaths + 1
        if dDouble and dT + 0.8 <= elapsed then deaths = deaths + 1 end
        dDouble = not dDouble
        dT = dT + 30
    end
    return {
        elapsed = elapsed, pct = pct, bosses = bosses, liveKills = liveKills, par = test.par,
        liveNames = test.run.bossNames, livePcts = test.run.bossPcts,
        raw = pct * 3, total = 300, route = test.route,
        deathCount = deaths, deathTimeLost = deaths * 15,
        ref = { kind = "test", label = test.label or "Test ghost (27:00)",
            run = test.run, durationSec = test.run.durationSec },
        roster = roster,
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
    local liveNames, livePcts, seededKills, liveIDs = R:GetBossMeta()
    local raw, total = R:GetRawForces()
    local mapID, level = R:GetContext()
    return {
        elapsed = elapsed, pct = pct, bosses = bosses, liveKills = R:GetBossKills(),
        liveNames = liveNames, livePcts = livePcts, seededKills = seededKills, liveIDs = liveIDs,
        liveRun = R:GetLiveRun(), raw = raw, total = total, route = R:GetRoute(),
        trackerPull = R:GetTrackerPull(),
        roster = mapID and KG.Ghosts:GetRoster(mapID, level, R.currentRef and R.currentRef.run) or nil,
        deathCount = R:GetDeathCountLive(), deathTimeLost = select(2, R:GetDeathCountLive()),
        par = R:GetParTime(), ref = R.currentRef,
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
    -- Golden ring + round class icon: "whose ghost is this" at a glance. Non-character
    -- ghosts show the RaiderIO logo (replay) or the pocket watch (pace), no ring.
    frame.ghostRing = frame.ghostHover:CreateTexture(nil, "ARTWORK")
    frame.ghostRing:SetSize(22, 22)
    frame.ghostRing:SetPoint("CENTER")
    frame.ghostRing:SetTexture("Interface\\COMMON\\Indicator-Gray")
    frame.ghostRing:SetVertexColor(1, 0.82, 0.15)
    frame.ghostIcon = frame.ghostHover:CreateTexture(nil, "OVERLAY")
    frame.ghostIcon:SetSize(16, 16)
    frame.ghostIcon:SetPoint("CENTER")
    frame.ghostIcon:SetTexture("Interface\\Icons\\INV_Misc_PocketWatch_01")
    frame.ghostIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

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

    -- No elapsed clock: every M+ timer addon shows it; internally elapsed stays the
    -- recorder's backbone. Bottom row is the pull indicator only.
    frame.pullText = frame:CreateFontString(nil, "OVERLAY")
    frame.pullText:SetPoint("BOTTOM", 0, 6)
    Style.SetFont(frame.pullText, 10)

    -- Close button for the post-run summary (default UI element, hidden during a run).
    frame.closeBtn = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    frame.closeBtn:SetSize(18, 18)
    frame.closeBtn:SetPoint("TOPRIGHT", -1, -1)
    frame.closeBtn:SetScript("OnClick", function()
        KG.Recorder.summary = nil
        Bar:Refresh()
    end)
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
local function Runner(i)
    local f = frame.runners[i]
    if not f then
        f = Hover(frame.track, 16, 16)
        -- Full-bright WHITE8x8 plate: tinting a dark sphere made rings invisible.
        f.border = f:CreateTexture(nil, "ARTWORK")
        f.border:SetSize(16, 16)
        f.border:SetPoint("CENTER")
        f.border:SetTexture("Interface\\Buttons\\WHITE8x8")
        f.tex = f:CreateTexture(nil, "OVERLAY")
        f.tex:SetSize(12, 12)
        f.tex:SetPoint("CENTER")
        frame.runners[i] = f
    end
    local c = Style.PULL_COLORS[(i - 1) % #Style.PULL_COLORS + 1]
    f.border:SetVertexColor(c[1], c[2], c[3])
    return f
end

local function ApplyRunnerIcon(tex, run)
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
--- round class icon in the golden ring — class COLOR block as fallback when the icon
--- coords are unavailable; the RaiderIO replay wears the RaiderIO logo; pace ghosts the
--- watch. (The raid marker belongs to the PLAYER cursor — mixed up once, 2026-07-19.
--- Iteration idea on file: a faded portrait of the ghost's character.)
local function ApplyGhostIcon(iconTex, ringTex, ref)
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
    -- Bright round class icon in the gold ring (the tinted Indicator-Gray disc rendered
    -- muddy-dark in the field — vertex color multiplies, it can't brighten).
    local coords = classToken and _G.CLASS_ICON_TCOORDS and _G.CLASS_ICON_TCOORDS[classToken]
    if coords then
        iconTex:SetTexture("Interface\\TargetingFrame\\UI-Classes-Circles")
        iconTex:SetTexCoord(coords[1], coords[2], coords[3], coords[4])
        iconTex:SetVertexColor(1, 1, 1)
        ringTex:Show()
        return
    end
    local color = classToken and _G.RAID_CLASS_COLORS and _G.RAID_CLASS_COLORS[classToken]
    if color then -- class-color fallback when icon coords are missing
        iconTex:SetTexture("Interface\\Buttons\\WHITE8x8")
        iconTex:SetTexCoord(0, 1, 0, 1)
        iconTex:SetVertexColor(color.r, color.g, color.b)
        iconTex:SetSize(12, 12)
        ringTex:Show()
        return
    end

    -- RaiderIO replay ghost wears the RaiderIO logo (pulled from their TOC metadata so
    -- we never hardcode their asset path); watch as fallback for it and pace ghosts.
    if ref.kind == "rio" and C_AddOns and C_AddOns.GetAddOnMetadata then
        local ok, icon = pcall(C_AddOns.GetAddOnMetadata, "RaiderIO", "IconTexture")
        if ok and type(icon) == "string" and icon ~= "" then
            iconTex:SetTexture(icon)
            iconTex:SetTexCoord(0, 1, 0, 1)
            iconTex:SetVertexColor(1, 1, 1)
            ringTex:Hide()
            return
        end
    end
    iconTex:SetTexture("Interface\\Icons\\INV_Misc_PocketWatch_01")
    iconTex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    iconTex:SetVertexColor(1, 1, 1)
    ringTex:Hide()
end
Bar.ApplyRefIconTo = ApplyGhostIcon -- (iconTex, ringTex, ref) — the raced row mirrors the badge

--- Roster-hover preview target (Splits sets/clears this).
function Bar.SetPreviewRun(run)
    Bar._previewRun = run
end

--- (Re)apply the player cursor icon: your raid target marker when you carry one (the
--- tank's {square} etc. — it's how you already identify yourself on screen), else your
--- portrait. Portraits are often BLACK until the client fires a portrait update, so
--- Core re-calls this on UNIT_PORTRAIT_UPDATE and zone-in; Update calls the cached path
--- so a mid-run marker change applies within a tick.
function Bar.RefreshPlayerIcon(force)
    local tex = frame and frame.playerIcon
    if not tex then return end
    local marker = KG.Scenario:GetPlayerRaidMarker() -- guarded: secret in instances
    local key = tostring(marker)
    if not force and tex._kgIconKey == key then return end
    tex._kgIconKey = key
    if marker then
        tex:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcon_" .. marker)
    elseif not pcall(SetPortraitTexture, tex, "player") then
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
    -- THE ROAD, seen through the Mario camera: YOU sit at the ¼ anchor while the
    -- dungeon scrolls toward you; near the finish the camera stops and you drive the
    -- last stretch to the line. Everything off-window pins to the edges (future bosses
    -- queue at the right and detach into view as you approach).
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
    local VIS = 0.45 -- zoomed out a notch from 0.35 (Fredrik: calmer motion per pixel)
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
    local ghostPcts = (ref.run and ref.run.bossPcts) or {}
    -- Identity pairing (SCENARIOS C2): ghost column i ↔ YOUR kill of the same
    -- encounterID — feeds the laps and the tooltip "You:" lines ONLY. Skull fade is
    -- count-based (milestone semantics, decision D1); kill-order fallback where IDs
    -- are missing (legacy/seeded data).
    local laps, lapMatch = M.LapDeltasByID(st.liveKills or {}, kills or {},
        st.liveIDs, ref.run and ref.run.bossIDs)
    local rightStack = 0 -- future bosses queue at the camera's right edge
    for i = 1, nKills do
        local f = BossTick(i)
        f:ClearAllPoints()
        -- Boss = a fixed landmark on the road: the course position where the ghost
        -- stood while fighting it (its forces% at the kill + the segments already won).
        local atPct = ghostPcts[i] or M.SampleAt(ref.run.snapshots, kills[i])
        local bossCourse = M.CoursePos(atPct, i - 1, nBosses)
        local pin = pinned(bossCourse)
        if pin == -1 then
            f:Hide() -- scrolled off behind the camera: done content
        elseif pin == 1 then
            -- queued at the edge; detaches into view as you approach
            f:SetPoint("CENTER", frame.track, "LEFT", W - 5 - rightStack * 7, 0)
            rightStack = rightStack + 1
        else
            f:SetPoint("CENTER", frame.track, "LEFT", px(bossCourse), 0)
        end
        if pin ~= -1 then f:SetAlpha(pin == 1 and 0.6 or 1) end
        -- Milestone semantics (DESIGN "Decisions in force", 2026-07-19): the skull
        -- claims "the ghost's i-th kill happened here" — a fact about the ghost's
        -- recording, true whatever order YOU kill bosses in. The name is shown as
        -- ghost history, never as a promise about your next boss.
        local when = M.FormatClock(kills[i])
            .. (ghostPcts[i] and string.format(" · %.0f%% count", ghostPcts[i]) or "")
        local tip = {
            string.format("Ghost's %s kill", Ordinal(i)),
            (names[i] and (names[i] .. " at ") or "At ") .. when,
        }
        local j = lapMatch[i] -- YOUR kill of the SAME boss (encounterID; order fallback)
        local lk = j and st.liveKills and st.liveKills[j]
        if lk and st.seededKills and j <= st.seededKills then
            tip[#tip + 1] = "You: killed before your reload (no lap time)"
        elseif lk then
            local lp = st.livePcts and st.livePcts[j]
            tip[#tip + 1] = string.format("You: dead at %s%s  (lap %s)", M.FormatClock(lk),
                lp and string.format(" · %.0f%% count", lp) or "", M.FormatDelta(laps[i]))
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

    -- No death marks on the track (Fredrik 2026-07-19): a death's cost shows as
    -- losing ground to the ghost / getting red-zoned by the sweeper — nothing else.
    -- Death data is still recorded, exported, and shown in the player tooltip.

    local aR, aG, aB = Style.GetAccent()
    local ghostCourse
    if ref.live then
        ghostCourse = M.CoursePos(ref.nowPct or 0, ref.nowBosses or 0, nBosses)
    else
        ghostCourse = M.CourseAt(ref.run, st.elapsed, nBosses)
    end
    ghostCourse = ease(frame._smGhost, ghostCourse)
    frame._smGhost = ghostCourse
    local gx = px(ghostCourse)
    local gPin = pinned(ghostCourse) -- ghost beyond the camera: pinned at an edge, dimmed
    frame.ghostCursor:SetVertexColor(aR, aG, aB, gPin == 0 and 0.95 or 0.4)
    frame.ghostCursor:ClearAllPoints()
    frame.ghostCursor:SetPoint("LEFT", frame.track, "LEFT", gx - 1, 0)
    ApplyGhostIcon(frame.ghostIcon, frame.ghostRing, ref)
    Bar.RefreshPlayerIcon() -- cached; catches mid-run raid-marker changes
    frame.ghostHover:SetAlpha(gPin == 0 and 1 or 0.6)
    frame.ghostHover:ClearAllPoints()
    frame.ghostHover:SetPoint("TOP", frame.track, "BOTTOMLEFT", gx, -1) -- ghost zone: below the track

    -- Your road position is simply your progress; the SECONDS delta (for the text and
    -- zone color) still comes from timeline inversion — two views of the same race.
    local eq
    if ref.live then
        -- Live ghost (RaiderIO replay): its future is unknown, so use the bidirectional
        -- delta — invert whichever timeline (the ghost's mirror or your own) can answer.
        eq = st.elapsed + M.LiveDelta(ref.run, ref.nowPct or 0, ref.nowBosses or 0,
            st.liveRun or { snapshots = {} }, st.elapsed, st.pct, st.bosses)
    else
        eq = M.GhostTimeFor(ref.run, st.pct, st.bosses)
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
    local dc = (delta >= 0) and good or bad
    frame.delta:SetText(M.FormatDelta(delta))
    frame.delta:SetTextColor(dc[1], dc[2], dc[3])
    frame.playerCursor:SetVertexColor(dc[1], dc[2], dc[3], 1)

    local lo, hi = math.min(gx, exV), math.max(gx, exV)
    local bw = hi - lo
    if bw >= 1 then
        local br, bg2, bb
        if delta >= 0 then
            br, bg2, bb = good[1], good[2], good[3]
        else
            -- Behind: grey → red by how close ghost-pace projection is to depleting.
            local sev = M.BehindSeverity(delta, ref.durationSec, st.par)
            if sev then
                br, bg2, bb = 0.6 + 0.32 * sev, 0.6 - 0.28 * sev, 0.6 - 0.28 * sev
            else
                br, bg2, bb = bad[1], bad[2], bad[3]
            end
        end
        local z = frame.gapZone
        z._faint:SetRGBA(br, bg2, bb, 0.1)
        z._strong:SetRGBA(br, bg2, bb, 0.55)
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
    local nr = 0
    if st.roster then
        for _, entry in ipairs(st.roster) do
            local run = entry.run
            if run ~= ref.run and run.snapshots then
                nr = nr + 1
                local f = Runner(nr)
                f:ClearAllPoints()
                local rCourse = ease(f._sm, M.CourseAt(run, st.elapsed, nBosses))
                f._sm = rCourse
                f:SetPoint("TOP", frame.track, "BOTTOMLEFT", px(rCourse), -3)
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
    end
    for i = nr + 1, #frame.runners do frame.runners[i]:Hide() end

    local ghostPctNow = ref.live and (ref.nowPct or 0) or M.SampleAt(ref.run.snapshots, st.elapsed)
    local cd = st.pct - ghostPctNow
    local cc = (cd >= 0) and good or bad
    frame.subDelta:SetFormattedText("%s%.1f%%", cd >= 0 and "+" or "", cd)
    frame.subDelta:SetTextColor(cc[1], cc[2], cc[3])

    frame.refLabel:SetText("vs " .. (ref.label or "?"))

    -- Pull position (needs an MDT route matching this dungeon): you vs the ghost. Your
    -- side uses the stateful tracker (boss criteria + thresholds — APL's model); the
    -- forces inference is only the test-mode/fallback path. The ghost side stays
    -- forces-inferred (a recording has no live criteria).
    local yourPull = st.trackerPull
        or (st.route and st.total > 0 and M.InferPull(st.raw, st.route.cum)) or nil
    if yourPull then
        local ghostRaw = ghostPctNow / 100 * st.total
        local ghostPull = M.InferPull(ghostRaw, st.route.cum) or yourPull
        local pc = (yourPull >= ghostPull) and good or bad
        frame.pullText:SetFormattedText("pull %d · ghost %d", yourPull, ghostPull)
        frame.pullText:SetTextColor(pc[1], pc[2], pc[3])
        frame.pullText:Show()
    else
        frame.pullText:Hide()
    end

    local ghostBossesNow = 0
    for i = 1, nKills do
        if kills[i] <= st.elapsed then ghostBossesNow = ghostBossesNow + 1 end
    end
    frame.ghostHover.tip = {
        ref.label or "Ghost",
        string.format("Now at %s: %.1f%% count · %d/%d bosses",
            M.FormatClock(st.elapsed), ghostPctNow, ghostBossesNow, nKills),
    }
    if ref.run and ref.run.routeName then
        table.insert(frame.ghostHover.tip, "Route: " .. ref.run.routeName)
    end
    if ref.run and ref.run.importedFrom then
        table.insert(frame.ghostHover.tip, "From: " .. ref.run.importedFrom)
    end
    frame.playerHover.tip = {
        "You",
        string.format("%s · %.1f%% count · %d boss%s dead", M.FormatClock(st.elapsed),
            st.pct, st.bosses, st.bosses == 1 and "" or "es"),
        M.FormatDelta(delta) .. " vs ghost",
    }
    if (st.deathCount or 0) > 0 then
        local lost = st.deathTimeLost and st.deathTimeLost > 0
            and (" (-" .. M.FormatClock(st.deathTimeLost) .. " on the timer)") or ""
        table.insert(frame.playerHover.tip, string.format("Deaths: %d%s", st.deathCount, lost))
    end
    frame:Show()
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
    for i = 1, 3 do frame.paceCars[i]:Hide() end
    if frame.walkAnim:IsPlaying() then frame.walkAnim:Stop() end -- parked on the podium
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
        ApplyGhostIcon(frame.ghostIcon, frame.ghostRing, ref)

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

function Bar:ResetPosition()
    KG.db.pos = nil
    Bar:InvalidatePosition()
    Bar:Refresh()
end
