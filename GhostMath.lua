-- Pure ghost math — no WoW API dependencies (offline unit-tested via tests/run.lua).
--
-- A run's timeline is `snapshots`: an array of { t, pct, bosses } with ascending t,
-- pct 0..100 monotonic, bosses a monotonic integer count (may be nil on legacy
-- APL-imported timelines). `bossKills` is an array of boss-kill timestamps when known.
--
-- The core racing primitive is GhostTimeFor: invert the ghost's timeline to find the
-- earliest time the ghost had reached the live player's current state (forces% AND boss
-- count). delta = GhostTimeFor(state) - elapsed. Positive = the ghost needed longer to get
-- where you are now = you are ahead, in seconds — the most honest racing metric, and it
-- stays meaningful while forces stall during a boss fight.
local ADDON_NAME, NS = ...
local KG = NS.KG

local M = {}
KG.Math = M

--- Sample a timeline at `elapsed` → pct (interpolated), bosses (step function).
function M.SampleAt(snapshots, elapsed)
    local n = snapshots and #snapshots or 0
    if n == 0 then return 0, 0 end
    if elapsed <= snapshots[1][1] then return snapshots[1][2], snapshots[1][3] or 0 end
    if elapsed >= snapshots[n][1] then return snapshots[n][2], snapshots[n][3] or 0 end
    for i = 1, n - 1 do
        local a, b = snapshots[i], snapshots[i + 1]
        if elapsed >= a[1] and elapsed <= b[1] then
            local span = b[1] - a[1]
            local f = (span > 0) and (elapsed - a[1]) / span or 0
            return a[2] + (b[2] - a[2]) * f, a[3] or 0
        end
    end
    return snapshots[n][2], snapshots[n][3] or 0
end

--- Earliest time the ghost reached `pct` forces (linear interpolation between snapshots).
local function TimeForPct(snapshots, pct)
    local n = #snapshots
    if n == 0 or pct <= (snapshots[1][2] or 0) then return snapshots[1] and snapshots[1][1] or 0 end
    for i = 2, n do
        if snapshots[i][2] >= pct then
            local a, b = snapshots[i - 1], snapshots[i]
            local rise = b[2] - a[2]
            local f = (rise > 0) and (pct - a[2]) / rise or 0
            return a[1] + (b[1] - a[1]) * f
        end
    end
    return snapshots[n][1] -- ghost never reached it: clamp to its full duration
end

--- Earliest time the ghost had killed `bosses` bosses. Prefers exact bossKills timestamps;
--- falls back to snapshot boss counts; 0 when the run has no boss data (legacy timelines).
local function TimeForBosses(run, bosses)
    if not bosses or bosses <= 0 then return 0 end
    if run.bossKills and #run.bossKills > 0 then
        local k = run.bossKills
        if bosses <= #k then return k[bosses] end
        return run.durationSec or k[#k]
    end
    local snaps = run.snapshots or {}
    for i = 1, #snaps do
        if (snaps[i][3] or -1) >= bosses then return snaps[i][1] end
    end
    if snaps[1] and snaps[1][3] ~= nil then return run.durationSec or snaps[#snaps][1] end
    return 0 -- no boss data at all: constraint is unenforceable, race on forces only
end

--- Earliest elapsed time at which the ghost run had ≥pct forces AND ≥bosses boss kills.
function M.GhostTimeFor(run, pct, bosses)
    local snaps = run.snapshots or {}
    if #snaps == 0 then return 0 end
    local tp = TimeForPct(snaps, pct or 0)
    local tb = TimeForBosses(run, bosses)
    return (tb > tp) and tb or tp
end

--- Time delta vs a LIVE ghost whose future is unknown (RaiderIO replays play forward in
--- wall-clock sync, so their timeline only exists up to `elapsed`). Positive = you are
--- ahead. When the ghost's current state is at or past yours, invert the ghost's partial
--- timeline as usual; when YOU are ahead, the ghost's timeline can't answer — invert your
--- own recorded live timeline instead ("when did I have the ghost's current state?").
function M.LiveDelta(ghostRun, ghostPct, ghostBosses, liveRun, elapsed, pct, bosses)
    if ghostPct >= (pct or 0) and (ghostBosses or 0) >= (bosses or 0) then
        return M.GhostTimeFor(ghostRun, pct, bosses) - elapsed
    end
    return elapsed - M.GhostTimeFor(liveRun, ghostPct, ghostBosses)
end

--- Validate + deep-copy a run that arrived from outside (import strings). Returns a
--- fresh table with only known fields, sane types and bounds — nothing else may reach
--- SavedVariables. nil when the shape is unusable.
function M.CleanRun(raw)
    if type(raw) ~= "table" then return nil end
    local dur = tonumber(raw.durationSec)
    if not dur or dur <= 0 or dur > 36000 then return nil end
    if type(raw.snapshots) ~= "table" or #raw.snapshots < 2 or #raw.snapshots > 5000 then return nil end

    local snaps, lastT = {}, -1
    for i = 1, #raw.snapshots do
        local s = raw.snapshots[i]
        local t = type(s) == "table" and tonumber(s[1])
        local p = type(s) == "table" and tonumber(s[2])
        if not t or not p or t < lastT or p < 0 or p > 100.5 then return nil end
        lastT = t
        snaps[i] = { t, p, tonumber(s[3]) }
    end

    local out = {
        clockV = tonumber(raw.clockV), -- absent on pre-fix exports → RepairAll fixes them
        durationSec = dur,
        completedAt = tonumber(raw.completedAt),
        level = tonumber(raw.level),
        mapID = tonumber(raw.mapID),
        parTimeSec = tonumber(raw.parTimeSec),
        deathCount = tonumber(raw.deathCount),
        routeName = type(raw.routeName) == "string" and raw.routeName:sub(1, 60) or nil,
        snapshots = snaps,
    }
    local chests = tonumber(raw.chests) or 0
    out.chests = math.max(0, math.min(KG.MAX_TIER, math.floor(chests)))

    if type(raw.bossKills) == "table" and #raw.bossKills <= 20 then
        local kills, names, pcts, ids, engs = {}, {}, {}, {}, {}
        for i = 1, #raw.bossKills do
            local t = tonumber(raw.bossKills[i])
            if not t or t < 0 or t > dur + 60 then return nil end
            kills[i] = t
            local nm = type(raw.bossNames) == "table" and raw.bossNames[i]
            names[i] = type(nm) == "string" and nm:sub(1, 80) or nil
            local bp = type(raw.bossPcts) == "table" and tonumber(raw.bossPcts[i])
            pcts[i] = bp
            ids[i] = type(raw.bossIDs) == "table" and tonumber(raw.bossIDs[i]) or nil
            local eng = type(raw.bossEngages) == "table" and tonumber(raw.bossEngages[i])
            engs[i] = (eng and eng >= 0 and eng <= dur + 60) and eng or nil
        end
        out.bossKills, out.bossNames, out.bossPcts = kills, names, pcts
        out.bossIDs, out.bossEngages = ids, engs
    end

    local nPulls = tonumber(raw.nPulls)
    if nPulls and nPulls >= 1 and nPulls <= 500 then
        out.nPulls = math.floor(nPulls)
        if type(raw.pullTimes) == "table" then
            local pt = {}
            for k, v in pairs(raw.pullTimes) do
                local ki, vt = tonumber(k), tonumber(v)
                if ki and vt and ki >= 1 and ki <= out.nPulls and vt >= 0 and vt <= dur + 60 then
                    pt[math.floor(ki)] = vt
                end
            end
            out.pullTimes = pt
        end
    end

    if type(raw.deaths) == "table" and #raw.deaths <= 300 then
        local deaths = {}
        for i = 1, #raw.deaths do
            local d = raw.deaths[i]
            local t = type(d) == "table" and tonumber(d[1])
            local n = type(d) == "table" and tonumber(d[2])
            if not t or not n or t < 0 or t > dur + 60 then return nil end
            deaths[i] = { t, n }
        end
        out.deaths = deaths
    end
    return out
end

--- Which route pull raw forces puts you on: first k where raw < cumForces[k]; past the
--- final cumulative → #cum + 1 ("route complete on paper"). Same inference as APL's
--- PullTracking. Boss-only pulls add no forces, so consecutive equal entries collapse to
--- the earliest — good enough for a position indicator.
function M.InferPull(rawForces, cumForces)
    if type(cumForces) ~= "table" or #cumForces == 0 then return nil end
    for k = 1, #cumForces do
        if rawForces < cumForces[k] then return k end
    end
    return #cumForces + 1
end

--- How dangerous is being behind? 0 = barely behind, 1 = holding the ghost's pace from
--- here would DEPLETE the key. No storage needed: your projected finish at ghost-pace is
--- ghostDur - delta, and it crosses par exactly when -delta reaches (par - ghostDur).
--- nil when ahead or when par/duration are unknown (caller falls back to plain red).
function M.BehindSeverity(delta, ghostDur, par)
    if not delta or delta >= 0 then return nil end
    if not ghostDur or not par or par <= 0 then return nil end
    local margin = par - ghostDur
    if margin <= 0 then return 1 end -- ghost itself was over par: any deficit depletes
    local sev = -delta / margin
    if sev < 0 then return 0 elseif sev > 1 then return 1 end
    return sev
end

--- ── The road (course space) ──────────────────────────────────────────────────
--- The bar is the dungeon: a straight road from start to finish (Fredrik's model).
--- Road length = 100 forces-units + nBosses × BOSS_UNITS; a runner's position is
--- forces% + kills×BOSS_UNITS, normalized to 0..1. While a boss is being fought the
--- runner STANDS at the boss landmark (forces stall), then jumps a boss-segment on the
--- kill — racing reality, no interpolation tricks. One finish line: the right edge.
M.BOSS_UNITS = 8

function M.CoursePos(pct, bosses, nBosses)
    nBosses = nBosses or 0
    local total = 100 + nBosses * M.BOSS_UNITS
    local p = (pct or 0) + (bosses or 0) * M.BOSS_UNITS
    if p < 0 then p = 0 elseif p > total then p = total end
    return p / total
end

--- A runner's road position at `elapsed`, replayed from a recorded timeline.
function M.CourseAt(run, elapsed, nBosses)
    local pct, bosses = M.SampleAt(run.snapshots or {}, elapsed)
    return M.CoursePos(pct, bosses, nBosses)
end

--- The Mario camera (Fredrik's model): YOU sit stationary at `anchor` of the window
--- while the road scrolls toward you — except at the road's ends, where the camera
--- hits the wall: at the start you walk in from the left edge, near the finish the
--- camera stops and you travel the final stretch to the line. Returns the window's
--- low edge in course space; the window spans [lo, lo + vis].
function M.Camera(youCourse, vis, anchor)
    vis = vis or 0.35
    anchor = anchor or 0.25
    local lo = (youCourse or 0) - anchor * vis
    if lo > 1 - vis then lo = 1 - vis end
    if lo < 0 then lo = 0 end
    return lo
end

--- Synthetic constant-pace timeline (par-time / season-best fallback ghosts).
function M.LinearSnapshots(durationSec)
    if not durationSec or durationSec <= 0 then return { { 0, 0 } } end
    return { { 0, 0 }, { durationSec, 100 } }
end

--- Chest tier from run duration vs par: +3 ≤ 60% par, +2 ≤ 80% par, +1 ≤ par, else 0.
function M.TierForDuration(durationSec, parTimeSec)
    if not durationSec or not parTimeSec or parTimeSec <= 0 then return nil end
    if durationSec <= parTimeSec * 0.6 then return 3 end
    if durationSec <= parTimeSec * 0.8 then return 2 end
    if durationSec <= parTimeSec then return 1 end
    return 0
end

local TIER_LABEL = { [0] = "depleted", [1] = "+1", [2] = "+2", [3] = "+3" }
function M.TierLabel(tier) return TIER_LABEL[tier or -1] or "?" end

--- Store `run` in the per-(char,map,level) tier table: one slot per chest tier (0..3),
--- keeping the fastest run in each slot. Max 4 ghosts per level by construction.
--- @return true when the run was stored (new slot or faster than the incumbent)
function M.InsertRun(tiers, run)
    local tier = run.chests or 0
    local cur = tiers[tier]
    if not cur or not cur.durationSec or (run.durationSec and run.durationSec < cur.durationSec) then
        tiers[tier] = run
        return true
    end
    return false
end

--- Fastest ghost in a tier table. Within one (map, level), a faster time always means an
--- equal-or-higher tier, so scanning tiers top-down finds the fastest run. Pass
--- minTier = 1 to skip depleted runs (recorded but never raced — Fredrik 2026-07-19).
function M.BestRun(tiers, minTier)
    if type(tiers) ~= "table" then return nil end
    for tier = KG.MAX_TIER, minTier or 0, -1 do
        if tiers[tier] then return tiers[tier], tier end
    end
    return nil
end

--- Pick the reference tier table for (level): exact level → highest level below →
--- lowest level above (byLevel = { [level] = tiers }).
--- @return tiers, levelUsed
function M.PickLevel(byLevel, level)
    if type(byLevel) ~= "table" then return nil end
    if level and byLevel[level] then return byLevel[level], level end
    local below, above
    for lvl in pairs(byLevel) do
        if level and lvl < level then
            if not below or lvl > below then below = lvl end
        elseif level and lvl > level then
            if not above or lvl < above then above = lvl end
        end
    end
    if below then return byLevel[below], below end
    if above then return byLevel[above], above end
    -- level unknown: fall back to the highest recorded level
    local hi
    for lvl in pairs(byLevel) do
        if not hi or lvl > hi then hi = lvl end
    end
    if hi then return byLevel[hi], hi end
    return nil
end

--- Per-boss lap deltas, speedrun-style: delta[i] = liveKills[i] - ghostKills[i]
--- (negative = you killed boss i faster than the ghost). nil entries where either side
--- has no kill yet / no data — callers render those as pending.
function M.LapDeltas(liveKills, ghostKills)
    local out = {}
    if type(liveKills) ~= "table" or type(ghostKills) ~= "table" then return out end
    for i = 1, #ghostKills do
        if liveKills[i] then out[i] = liveKills[i] - ghostKills[i] end
    end
    return out
end

--- Identity-aware lap deltas (SCENARIOS C2): column i is the ghost's i-th kill; your
--- matching kill is found by encounterID (`bossIDs`, recorded since 2026-07-19), so an
--- off-order route still compares the SAME boss. Kill-order fallback only where a slot
--- is genuinely un-identifiable: the ghost kill has no ID, you have no IDs at all, or
--- your i-th kill lacks one. When your i-th kill IS identified as a different boss,
--- the column stays pending instead of lying.
--- @return deltas, matched — matched[i] = your kill index paired with ghost column i,
---   so callers (lap cells, skull fade, skull tooltips) all agree on the pairing.
function M.LapDeltasByID(liveKills, ghostKills, liveIDs, ghostIDs)
    local out, matched = {}, {}
    if type(liveKills) ~= "table" or type(ghostKills) ~= "table" then return out, matched end
    local haveLiveIDs = type(liveIDs) == "table" and next(liveIDs) ~= nil
    local claimed = {}
    for i = 1, #ghostKills do -- pass 1: pair by encounterID
        local gid = type(ghostIDs) == "table" and ghostIDs[i] or nil
        if gid and haveLiveIDs then
            for k = 1, #liveKills do
                if liveIDs[k] == gid then
                    matched[i] = k
                    claimed[k] = true
                    break
                end
            end
        end
    end
    for i = 1, #ghostKills do -- pass 2: kill-order fallback for un-identifiable slots
        if not matched[i] then
            local gid = type(ghostIDs) == "table" and ghostIDs[i] or nil
            -- Blocked when your i-th kill IS identified as some other boss; and a live
            -- kill already ID-claimed by another column can't be credited twice.
            local blocked = gid and haveLiveIDs and liveIDs[i] ~= nil
            if liveKills[i] and not blocked and not claimed[i] then
                matched[i] = i
                claimed[i] = true
            end
        end
    end
    for i = 1, #ghostKills do
        if matched[i] then out[i] = liveKills[matched[i]] - ghostKills[i] end
    end
    return out, matched
end

--- One-time repair for runs recorded before the 2026-07-19 clock fixes: their clocks
--- started at the COUNTDOWN (≈10s before the official timer) and could ingest
--- scenario-collapse zeros near the end. Shifts the whole timeline onto the official
--- clock (±1s is acceptable — Fredrik), drops non-monotonic forces dips, collapses the
--- countdown prefix, and re-pins the 100% closer to the official duration. Idempotent
--- via run.clockV; returns true when the run was modified.
function M.RepairRun(run, shift)
    if type(run) ~= "table" or run.clockV then return false end
    run.clockV = 2
    shift = shift or 10
    local function sh(t) return math.max(0, (t or 0) - shift) end

    local snaps, maxPct, maxB = {}, 0, 0
    for _, s in ipairs(run.snapshots or {}) do
        local pct = s[2] or 0
        if pct + 0.5 >= maxPct then -- anything lower is a collapse dip: drop it
            if pct > maxPct then maxPct = pct end
            local b = s[3]
            if b and b > maxB then maxB = b end
            snaps[#snaps + 1] = { sh(s[1]), maxPct, b and maxB or nil }
        end
    end
    while #snaps >= 2 and snaps[1][1] == 0 and snaps[2][1] == 0 do
        table.remove(snaps, 1) -- countdown prefix flattens to one starting point
    end
    -- The 100% closer was appended with the OFFICIAL duration on the old shifted
    -- clock; pin it back to durationSec so the tail stays aligned.
    if run.durationSec and #snaps > 0 and snaps[#snaps][2] >= 99.5 then
        snaps[#snaps][1] = run.durationSec
    end
    run.snapshots = snaps

    if run.bossKills then
        for i, t in ipairs(run.bossKills) do run.bossKills[i] = sh(t) end
    end
    if run.deaths then
        for _, d in ipairs(run.deaths) do d[1] = sh(d[1]) end
    end
    if run.pullTimes then
        for k, t in pairs(run.pullTimes) do run.pullTimes[k] = sh(t) end
    end
    return true
end

--- "+0:42" / "-1:07" (sign always shown; seconds delta rounded).
function M.FormatDelta(sec)
    local sign = sec >= 0 and "+" or "-"
    local s = math.floor(math.abs(sec) + 0.5)
    return string.format("%s%d:%02d", sign, math.floor(s / 60), s % 60)
end

function M.FormatClock(sec)
    local s = math.floor((sec or 0) + 0.5)
    return string.format("%d:%02d", math.floor(s / 60), s % 60)
end
