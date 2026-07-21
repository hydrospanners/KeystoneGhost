-- Pure ghost math — no WoW API dependencies (offline unit-tested via tests/run.lua).
--
-- COUNT-SPACE (v3, DESIGN "Count-space storage"): a run's timeline is `snapshots`,
-- an array of { t, count, bosses } — whole-second t ascending, count the raw integer
-- enemy-forces value in the run's OWN units (run.total = the dungeon requirement at
-- record time), bosses a monotonic integer kill count. Percent is a DERIVED display
-- value (M.Frac); the count is the scenario's source integer, so pull decisions can
-- never be poisoned by stored rounding residue. Linear pace ghosts use total = 100
-- (their "counts" are percent by construction); the RaiderIO mirror uses RaiderIO's
-- own units. Cross-total comparisons happen in fraction space; same-total
-- comparisons stay exact integers. `bossKills` is exact kill timestamps when known.
--
-- Timelines are STEP-SHAPED where the producer is change-driven (the recorder since
-- the 2026-07-21 event-log cutover, the RaiderIO paths): nodes only where the count
-- moved, flat spans re-pinned by doubled base nodes (AppendStepNode /
-- ConvertRioReplay — one encoding, every producer). Interpolation stays LINEAR
-- everywhere below, so the same math renders truth for step-shaped, legacy-cadence,
-- and linear-pace timelines alike — the step lives in the data, not in a mode flag.
--
-- The core racing primitive is GhostTimeFor: invert the ghost's timeline to find the
-- earliest time the ghost had reached the live player's current state (forces count
-- AND boss count). delta = GhostTimeFor(state) - elapsed. Positive = the ghost needed
-- longer to get where you are now = you are ahead, in seconds — the most honest racing
-- metric, and it stays meaningful while forces stall during a boss fight.
local ADDON_NAME, NS = ...
local KG = NS.KG

local M = {}
KG.Math = M

--- Percent (0..100) of a run-unit count against its total — RENDERING-only derived
--- value (the locked invariant races on counts; percent is display and cross-total
--- glue). Same integers, same division as the game's own display.
function M.Frac(count, total)
    if not total or total <= 0 then return 0 end
    return (count or 0) / total * 100
end

--- Sample a timeline at `elapsed` → count in the run's units (interpolated),
--- bosses (step function).
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

--- Append a live change-point to a step-shaped timeline (change-driven capture:
--- the recorder and the RaiderIO mirrors). Between changes the true count curve
--- is FLAT, so a count move across a gap > 1 s first re-pins the flat span with a
--- base node at the OLD count — the doubled step nodes ConvertRioReplay already
--- writes — and the inversion then answers the change's exact time instead of
--- interpolating a slope that was never played. Gaps ≤ 1 s skip the base: whole-
--- second storage can't render a sharper step anyway. No-op when nothing moved
--- (callers fire on every event burst and reconcile tick). The boss column needs
--- no doubling — SampleAt holds a[3] across each bracket, so a kill-only node
--- steps exactly at its own t.
function M.AppendStepNode(snaps, t, count, bosses)
    bosses = bosses or 0
    local last = snaps[#snaps]
    if last and last[2] == count and (last[3] or 0) == bosses then return false end
    if last and last[2] ~= count and t - last[1] > 1 then
        snaps[#snaps + 1] = { t, last[2], bosses }
    end
    snaps[#snaps + 1] = { t, count, bosses }
    return true
end

--- Earliest time the ghost reached `count` forces (linear interpolation between
--- snapshots; count in the SNAPSHOTS' own units — callers map cross-total first).
local function TimeForCount(snapshots, count)
    local n = #snapshots
    if n == 0 or count <= (snapshots[1][2] or 0) then return snapshots[1] and snapshots[1][1] or 0 end
    for i = 2, n do
        if snapshots[i][2] >= count then
            local a, b = snapshots[i - 1], snapshots[i]
            local rise = b[2] - a[2]
            local f = (rise > 0) and (count - a[2]) / rise or 0
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

--- Earliest elapsed time at which the ghost run had ≥ your forces AND ≥bosses kills.
--- `count`/`total` describe the LIVE state in ITS units: when the ghost's total
--- matches, the comparison is exact integers (the whole point of count space); when
--- totals differ (season retune, linear ghost, RaiderIO units) the target maps
--- through fraction space. Omitted totals default to 100 (percent-shaped data).
function M.GhostTimeFor(run, count, bosses, total)
    local snaps = run.snapshots or {}
    if #snaps == 0 then return 0 end
    local target = count or 0
    local rt, lt = run.total or 100, total or 100
    if rt ~= lt and lt > 0 then
        target = target / lt * rt -- cross-total: compare in fraction space
    end
    local tp = TimeForCount(snaps, target)
    local tb = TimeForBosses(run, bosses)
    return (tb > tp) and tb or tp
end

--- Time delta vs a LIVE ghost whose future is unknown (RaiderIO replays play forward in
--- wall-clock sync, so their timeline only exists up to `elapsed`). Positive = you are
--- ahead. When the ghost's current state is at or past yours, invert the ghost's partial
--- timeline as usual; when YOU are ahead, the ghost's timeline can't answer — invert your
--- own recorded live timeline instead ("when did I have the ghost's current state?").
--- ghostCount is in the ghost run's units, count/total the live state in its units;
--- the ahead/behind verdict compares fractions (equal to a count compare when the
--- totals match). liveRun must carry its own `total` for the mirrored inversion.
function M.LiveDelta(ghostRun, ghostCount, ghostBosses, liveRun, elapsed, count, bosses, total)
    local gf = M.Frac(ghostCount, ghostRun.total or 100)
    local lf = M.Frac(count, total or 100)
    if gf >= lf and (ghostBosses or 0) >= (bosses or 0) then
        return M.GhostTimeFor(ghostRun, count, bosses, total) - elapsed
    end
    return elapsed - M.GhostTimeFor(liveRun, ghostCount, ghostBosses, ghostRun.total)
end

--- Has this runner left the start state (any forces count or a boss kill)? The Gap is
--- only meaningful between two runners with actual progress: at 0/0 the inversion
--- degenerates to "time since the gates opened" (the ghost first had 0 at 0:00), so
--- callers keep the Gap DISARMED (grey 0:00) until both sides have progress. Arming on
--- one side alone would just mirror the artifact — a +elapsed flash the instant your
--- first pack dies. Live-hit 2026-07-19, +16 Pit of Saron vs the RaiderIO replay:
--- -0:26 across the opening runway, then a snap to +0:01 (SCENARIOS B9).
--- Works in any units — count or percent, > 0 is > 0.
function M.HasProgress(count, bosses)
    return (count or 0) > 0 or (bosses or 0) > 0
end

--- The resume decision (Live Run persistence — DESIGN "Open follow-ups",
--- reference-persistence shape): may the persisted live recording be ADOPTED as
--- the resumed run's real timeline, or must the resume fall back to seeding? Pure
--- decision over plain values — the caller reads the world and clears a "seed"-ed
--- stale entry. lr = the persisted `KeystoneGhostDB.liveRun`; ctx = { charKey, mapID,
--- level, elapsed (world keystone timer, s), now (server epoch, s) }.
--- Adopt requires the same character + the same key (mapID/level) + a clock that
--- proves the ACTIVE run IS the RECORDED one: the world timer may not be younger than
--- the recording's wall-clock age (a fresh timer under an old liveRun = a new run of
--- the same key; deaths while offline only push the timer AHEAD of wall age, never
--- behind — 60 s of grace covers stamp lag). A liveRun that never saw the timer
--- anchor (no startEpoch: reloaded during the countdown) is adoptable only while the
--- timer is provably young.
--- @return "adopt" | "seed"
function M.LiveRunVerdict(lr, ctx)
    if type(lr) ~= "table" or type(lr.snapshots) ~= "table" then return "seed" end
    if lr.charKey ~= ctx.charKey then return "seed" end
    if lr.mapID ~= ctx.mapID or lr.level ~= ctx.level then return "seed" end
    local epoch = tonumber(lr.startEpoch)
    if epoch then
        local age = (ctx.now or 0) - epoch
        if (ctx.elapsed or 0) - age < -60 then return "seed" end
    elseif (ctx.elapsed or 0) >= 30 then
        return "seed"
    end
    return "adopt"
end

--- Validate + deep-copy a run that arrived from outside (import strings). Returns a
--- fresh table with only known fields, sane types and bounds — nothing else may reach
--- SavedVariables. nil when the shape is unusable. v3 count-space shape: `total` is
--- REQUIRED; snapshot t and count are normalized to whole integers (the stored
--- representation — "integers for facts").
function M.CleanRun(raw)
    if type(raw) ~= "table" then return nil end
    local dur = tonumber(raw.durationSec)
    if not dur or dur <= 0 or dur > 36000 then return nil end
    local total = tonumber(raw.total)
    if not total or total < 1 or total > 100000 then return nil end
    total = math.floor(total)
    if type(raw.snapshots) ~= "table" or #raw.snapshots < 2 or #raw.snapshots > 5000 then return nil end

    -- Monotonicity is ALMOST true and never assumed (the wire-format rule): the
    -- official-timer re-anchor can step t back ~1.5 s and the recorder tolerates
    -- ≤1% count dips — small backsteps are honest data, big ones are corruption.
    local maxCount = total + math.max(1, total * 0.005)
    local dipSlack = math.max(2, total * 0.015)
    local snaps, lastT, lastC = {}, -1, 0
    for i = 1, #raw.snapshots do
        local s = raw.snapshots[i]
        local t = type(s) == "table" and tonumber(s[1])
        local c = type(s) == "table" and tonumber(s[2])
        if not t or not c then return nil end
        t = math.floor(t + 0.5)
        c = math.floor(c + 0.5)
        if t < lastT - 5 or c < 0 or c > maxCount or c < lastC - dipSlack then return nil end
        lastT, lastC = t, c
        snaps[i] = { t, c, tonumber(s[3]) }
    end

    local out = {
        clockV = tonumber(raw.clockV),
        total = total,
        durationSec = dur,
        completedAt = tonumber(raw.completedAt),
        week = tonumber(raw.week), -- reset-week boundary epoch (categorization seed)
        level = tonumber(raw.level),
        mapID = tonumber(raw.mapID),
        parTimeSec = tonumber(raw.parTimeSec),
        deathCount = tonumber(raw.deathCount),
        routeName = type(raw.routeName) == "string" and raw.routeName:sub(1, 60) or nil,
        routeHash = tonumber(raw.routeHash), -- Route Store reference (content hash)
        legacy = type(raw.legacy) == "string" and raw.legacy:sub(1, 12) or nil,
                 -- legacy-grade marker ("KPG1": bosses-only, saturated count)
        -- Raider.IO ghost identity (first-class replay, 2026-07-21): the resolved
        -- source word ("guild best"…) and their keystone_run_id — cache identity +
        -- the mid-run replay-switch check. Survive the gate on any run but are
        -- display-only / rio-scoped: spoofing them via an import earns no privilege.
        rioSource = type(raw.rioSource) == "string" and raw.rioSource:sub(1, 20) or nil,
        rioRunId = tonumber(raw.rioRunId),
        snapshots = snaps,
    }
    local chests = tonumber(raw.chests) or 0
    out.chests = math.max(0, math.min(KG.MAX_TIER, math.floor(chests)))

    if type(raw.bossKills) == "table" and #raw.bossKills <= 20 then
        local kills, names, counts, ids, jids, engs = {}, {}, {}, {}, {}, {}
        for i = 1, #raw.bossKills do
            local t = tonumber(raw.bossKills[i])
            if not t or t < 0 or t > dur + 60 then return nil end
            kills[i] = t
            local nm = type(raw.bossNames) == "table" and raw.bossNames[i]
            names[i] = type(nm) == "string" and nm:sub(1, 80) or nil
            local bc = type(raw.bossCounts) == "table" and tonumber(raw.bossCounts[i])
            counts[i] = bc and math.floor(bc + 0.5) or nil
            ids[i] = type(raw.bossIDs) == "table" and tonumber(raw.bossIDs[i]) or nil
            jids[i] = type(raw.bossJIDs) == "table" and tonumber(raw.bossJIDs[i]) or nil
            local eng = type(raw.bossEngages) == "table" and tonumber(raw.bossEngages[i])
            engs[i] = (eng and eng >= 0 and eng <= dur + 60) and eng or nil
        end
        out.bossKills, out.bossNames, out.bossCounts = kills, names, counts
        out.bossIDs, out.bossJIDs, out.bossEngages = ids, jids, engs
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

    -- Payload expansion (additive context, DESIGN "Payload expansion"): exporter
    -- block, season, affixes, party roster. All optional — absence is fine, junk
    -- is dropped field-by-field, never a reason to sink the run.
    out.season = tonumber(raw.season)
    if type(raw.affixes) == "table" then
        local af = {}
        for i = 1, math.min(#raw.affixes, 5) do
            local id = tonumber(raw.affixes[i])
            if id and id > 0 then af[#af + 1] = math.floor(id) end
        end
        if #af > 0 then out.affixes = af end
    end
    if type(raw.player) == "table" then
        local p = raw.player
        local cp = {
            spec = tonumber(p.spec),
            role = type(p.role) == "string" and p.role:sub(1, 10) or nil,
            guild = type(p.guild) == "string" and p.guild:sub(1, 48) or nil,
            level = tonumber(p.level),
            ilvl = tonumber(p.ilvl),
            rating = tonumber(p.rating),
            talents = type(p.talents) == "string" and p.talents:sub(1, 400) or nil,
        }
        if next(cp) then out.player = cp end
    end
    if type(raw.party) == "table" then
        local party = {}
        for i = 1, math.min(#raw.party, 4) do
            local m = raw.party[i]
            -- Nameless members are legal: party names are export-OPT-IN (default
            -- off), so anonymized members arrive as class/role/spec/rating only.
            if type(m) == "table" and (type(m.name) == "string" or type(m.class) == "string") then
                party[#party + 1] = {
                    name = type(m.name) == "string" and m.name:sub(1, 60) or nil,
                    class = type(m.class) == "string" and m.class:sub(1, 20):upper() or nil,
                    role = type(m.role) == "string" and m.role:sub(1, 10) or nil,
                    spec = tonumber(m.spec),
                    rating = tonumber(m.rating),
                }
            end
        end
        if #party > 0 then out.party = party end
    end
    return out
end

--- ── Party display / anonymization ────────────────────────────────────────────

--- Community short names per specID (IDs verified against BigWigs'
--- LibSpecialization, TOC 120100 — includes Devourer, the third DH spec).
--- Fredrik's list honored where he named one (Retri, RShaman, RDruid, Devoker,
--- Aug, Demo, Devour, Fire, Frost, Arcane, ProtWarrior, ProtPala).
M.SPEC_SHORT = {
    [250] = "Blood", [251] = "FrostDK", [252] = "Unholy",              -- Death Knight
    [577] = "Havoc", [581] = "Veng", [1480] = "Devour",                -- Demon Hunter
    [102] = "Boomy", [103] = "Feral", [104] = "Guardian", [105] = "RDruid", -- Druid
    [1467] = "Devoker", [1468] = "Pres", [1473] = "Aug",               -- Evoker
    [253] = "BM", [254] = "MM", [255] = "Surv",                        -- Hunter
    [62] = "Arcane", [63] = "Fire", [64] = "Frost",                    -- Mage
    [268] = "Brew", [269] = "WW", [270] = "MW",                        -- Monk
    [65] = "HPala", [66] = "ProtPala", [70] = "Retri",                 -- Paladin
    [256] = "Disc", [257] = "HPriest", [258] = "Shadow",               -- Priest
    [259] = "Assa", [260] = "Outlaw", [261] = "Sub",                   -- Rogue
    [262] = "Ele", [263] = "Enh", [264] = "RShaman",                   -- Shaman
    [265] = "Affli", [266] = "Demo", [267] = "Destro",                 -- Warlock
    [71] = "Arms", [72] = "Fury", [73] = "ProtWarrior",                -- Warrior
}

-- Spec unknown: role+class pins it exactly for every tank and most healers
-- (priest healers and post-Midnight DH damagers stay ambiguous → class level).
local ROLE_CLASS_SHORT = {
    TANK = { WARRIOR = "ProtWarrior", PALADIN = "ProtPala", DEATHKNIGHT = "Blood",
        DEMONHUNTER = "Veng", DRUID = "Guardian", MONK = "Brew" },
    HEALER = { PALADIN = "HPala", DRUID = "RDruid", SHAMAN = "RShaman",
        MONK = "MW", EVOKER = "Pres" },
}
local CLASS_SHORT = {
    DEATHKNIGHT = "DK", DEMONHUNTER = "DH", WARLOCK = "Lock", WARRIOR = "Warrior",
    PALADIN = "Pala", HUNTER = "Hunter", ROGUE = "Rogue", PRIEST = "Priest",
    SHAMAN = "Shaman", MAGE = "Mage", DRUID = "Druid", MONK = "Monk", EVOKER = "Evoker",
}

--- Display label for a party member table {spec?, class?, role?}: spec short
--- name when the spec is known, else the role+class pin, else the class.
--- Derived at DISPLAY time — labels never travel on the wire.
function M.PartyMemberLabel(m)
    if type(m) ~= "table" then return "?" end
    local s = m.spec and M.SPEC_SHORT[m.spec]
    if s then return s end
    local byRole = m.role and ROLE_CLASS_SHORT[m.role]
    local rc = byRole and m.class and byRole[m.class]
    if rc then return rc end
    return (m.class and CLASS_SHORT[m.class]) or m.class or "?"
end

--- Export-side party anonymization (party names are OFF by default — Fredrik
--- 2026-07-20): a fresh copy carrying class/role/spec/rating only. Receivers
--- render members via PartyMemberLabel; the stored run is never mutated.
function M.AnonymizeParty(party)
    if type(party) ~= "table" then return nil end
    local out = {}
    for i, m in ipairs(party) do
        out[i] = { class = m.class, role = m.role, spec = m.spec, rating = m.rating }
    end
    return out
end

--- Which route pull raw forces puts you on: first k where raw < cumulativeForces[k];
--- past the final entry → #cumulativeForces + 1 ("route complete on paper"). Same
--- inference as APL's PullTracking. Boss-only pulls add no forces, so consecutive
--- equal entries collapse to the earliest — good enough for a position indicator.
function M.InferPull(rawForces, cumulativeForces)
    if type(cumulativeForces) ~= "table" or #cumulativeForces == 0 then return nil end
    for k = 1, #cumulativeForces do
        if rawForces < cumulativeForces[k] then return k end
    end
    return #cumulativeForces + 1
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
M.VIS = 0.45 -- camera viewport in course units (shared: Bar rendering + Overtake buffer)

function M.CoursePos(pct, bosses, nBosses)
    nBosses = nBosses or 0
    local total = 100 + nBosses * M.BOSS_UNITS
    local p = (pct or 0) + (bosses or 0) * M.BOSS_UNITS
    if p < 0 then p = 0 elseif p > total then p = total end
    return p / total
end

--- A runner's road position at `elapsed`, replayed from a recorded timeline.
--- Course space renders in percent — derived here from the run's own count/total.
function M.CourseAt(run, elapsed, nBosses)
    local count, bosses = M.SampleAt(run.snapshots or {}, elapsed)
    return M.CoursePos(M.Frac(count, run.total or 100), bosses, nBosses)
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
--- Percent-shaped by construction: pair with run.total = 100.
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

--- "+0:42" / "-1:07" (sign always shown; seconds delta rounded).
function M.FormatDelta(sec)
    local sign = sec >= 0 and "+" or "-"
    local s = math.floor(math.abs(sec) + 0.5)
    return string.format("%s%d:%02d", sign, math.floor(s / 60), s % 60)
end

--- Forces readout, level form (the count display toggle — DESIGN "Count display
--- toggle — the Phase 2 proposal", default COUNT per Fredrik 2026-07-20): one
--- number, two languages. countMode with a usable total → "228/413" (the raw count
--- against ITS OWN total — a ghost site passes the ghost's total, a live site
--- yours). Anything else → percent with `decimals` digits — the fallback IS
--- percent, so every site can call this unconditionally.
function M.FormatForcesLevel(count, total, countMode, decimals)
    if countMode and total and total > 0 then
        return string.format("%d/%d", math.floor((count or 0) + 0.5), total)
    end
    return string.format("%." .. (decimals or 1) .. "f%%", M.Frac(count, total))
end

--- Forces readout, Count Gap form: the signed forces delta vs the Raced Ghost.
--- Percent mode: "+3.4%" (negative values carry their own minus, matching the
--- pre-toggle rendering exactly). countMode with a usable total: the percent-point
--- diff converts through fraction space into YOUR dungeon's units — "+14" — so a
--- cross-total ghost never compares apples to oranges (the Gap always speaks your
--- units; the proposal's cross-total rule).
function M.FormatForcesDelta(pctDiff, total, countMode)
    if countMode and total and total > 0 then
        local n = pctDiff * total / 100
        n = (n >= 0) and math.floor(n + 0.5) or -math.floor(-n + 0.5)
        return string.format("%+d", n)
    end
    return string.format("%s%.1f%%", pctDiff >= 0 and "+" or "", pctDiff)
end

function M.FormatClock(sec)
    local s = math.floor((sec or 0) + 0.5)
    return string.format("%d:%02d", math.floor(s / 60), s % 60)
end

--- Strip WoW color escapes (|cAARRGGBB … |r) from player-typed text. Route names in
--- the wild can carry embedded codes; Ellipsize is byte-based and would slice an
--- escape mid-sequence, so names get stripped BEFORE ellipsizing — coloring in the
--- Pull Indicator is ours to apply (the creator token), never inherited from data.
function M.StripColors(s)
    if type(s) ~= "string" then return s end
    return (s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
end

--- UTF-8-safe ellipsis: `s` unchanged while within `maxBytes`, else the longest
--- whole-character prefix + "…" — never cuts inside a multi-byte char (route names
--- are player-typed text). Used for the Pull Indicator's route-name prefix.
function M.Ellipsize(s, maxBytes)
    if type(s) ~= "string" or #s <= maxBytes then return s end
    local cut = maxBytes
    while cut > 0 do
        local b = s:byte(cut + 1)
        if not b or b < 0x80 or b >= 0xC0 then break end -- next byte starts a new char
        cut = cut - 1
    end
    return s:sub(1, cut) .. "…"
end

--- Ghost Library model (pure — DESIGN "The Ghost Library", approved 2026-07-21):
--- flatten runs[charKey][mapID][level][tier] into display-ready dungeon groups.
--- `nameFor(mapID)` resolves dungeon names (injected — WoW APIs stay out of this
--- file); groups sort by resolved name, "map N" fallback. Within a group:
--- raceable rows first (level desc, tier desc, faster first), Depleted (tier 0)
--- sink to the bottom — the top of every group stays scannable for ghosts that
--- can actually race. `pick` = the VIEWING character's EFFECTIVE dungeon-keyed
--- pick table (Ghosts:EffectivePicks — own picks over the account-wide import
--- auto-picks): the one row matching pick[mapID] — char + level + tier;
--- Raider.IO rows match on char alone — is flagged `pinned`. One selected row
--- per dungeon, per character (Fredrik 2026-07-21).
function M.LibraryModel(runs, pick, nameFor)
    local groups, byMap = {}, {}
    for charKey, maps in pairs(runs or {}) do
        for mapID, byLevel in pairs(maps) do
            for level, tiers in pairs(byLevel) do
                for tier, run in pairs(tiers) do
                    if type(run) == "table" then
                        local g = byMap[mapID]
                        if not g then
                            local name = nameFor and nameFor(mapID) or nil
                            g = { mapID = mapID, name = name or ("map " .. tostring(mapID)), rows = {} }
                            byMap[mapID] = g
                            groups[#groups + 1] = g
                        end
                        local pinned
                        local p = pick and pick[mapID]
                        if charKey == KG.RIO_CHAR then
                            pinned = (type(p) == "table" and p.char == KG.RIO_CHAR) or false
                        else
                            pinned = (type(p) == "table" and p.char == charKey
                                and p.level == level and p.tier == tier) or false
                        end
                        g.rows[#g.rows + 1] = {
                            charKey = charKey, mapID = mapID, level = level, tier = tier, run = run,
                            pinned = pinned,
                        }
                    end
                end
            end
        end
    end
    table.sort(groups, function(a, b) return a.name < b.name end)
    for _, g in ipairs(groups) do
        table.sort(g.rows, function(a, b)
            local aDep, bDep = a.tier == 0, b.tier == 0
            if aDep ~= bDep then return bDep end -- Depleted sink to the group bottom
            if a.level ~= b.level then return a.level > b.level end
            if a.tier ~= b.tier then return a.tier > b.tier end
            local at, bt = a.run.durationSec or 0, b.run.durationSec or 0
            if at ~= bt then return at < bt end -- full tie: faster run first
            return tostring(a.charKey) < tostring(b.charKey) -- deterministic order
        end)
    end
    return groups
end

--- ── Raider.IO replay conversion (TASKS #13; forensics: docs/RAIDERIO-DATA.md) ──

--- ISO-8601 UTC ("2026-07-20T14:57:49Z") → unix epoch, pure integer math
--- (days-from-civil). WoW Lua has no os.time; verified against the forensics
--- specimen (→ 1784559469).
function M.IsoToEpoch(iso)
    local y, mo, d, h, mi, s = tostring(iso or ""):match("^(%d+)%-(%d+)%-(%d+)T(%d+):(%d+):(%d+)Z$")
    if not y then return nil end
    y, mo, d = tonumber(y), tonumber(mo), tonumber(d)
    h, mi, s = tonumber(h), tonumber(mi), tonumber(s)
    local yy = (mo <= 2) and (y - 1) or y
    local era = math.floor(yy / 400)
    local yoe = yy - era * 400
    local doy = math.floor((153 * (mo + ((mo > 2) and -3 or 9)) + 2) / 5) + d - 1
    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
    return (era * 146097 + doe - 719468) * 86400 + h * 3600 + mi * 60 + s
end

--- Convert a Raider.IO replay entry (their ns.REPLAYS shape, format_version 2)
--- into a CleanRun-ready raw run. PURE — the caller resolves mapID (their
--- dungeon.id is RIO-space), par/tier, storage identity, and provenance label.
--- Full field forensics + cross-validation: docs/RAIDERIO-DATA.md (2026-07-21;
--- the specimen replay IS a run KeystoneGhost also recorded — converted boss
--- kills land on the recording's exact seconds).
---
--- Timebase: RIO event timers EXCLUDE the death penalty; our official-timer
--- axis INCLUDES it — every event time shifts by penalty(level) × deaths BEFORE
--- it (their own table: 15 s at level ≥ 12, 5 s at ≥ 4). Verified ±0.6 s
--- post-death; a ~3 s pre-death residual is documented → honest accuracy ±3 s.
--- Forces: their deltas are raw awards (overkill retained — the specimen sums
--- 601 on a 585 dungeon), so the cumulative count CLAMPS at total. Between
--- awards the true curve is FLAT — snapshots carry doubled step nodes so the
--- inversion never interpolates across an award gap (a smoothed gap would be
--- a curve that lies).
--- Event tuple (their UnpackReplayEvent): { timer_ms, type, ... } with type
--- 1 = PLAYER_DEATH (+n), 2 = ENEMY_FORCES (+delta),
--- 3 = ENCOUNTER_START (ordinal0, pulls, combat, killed),
--- 4 = ENCOUNTER_END (same; killed=true is the kill).
function M.ConvertRioReplay(replay, opts)
    if type(replay) ~= "table" or type(replay.events) ~= "table" then
        return nil, "not a replay table"
    end
    local level = tonumber(replay.mythic_level)
    local durMs = tonumber(replay.clear_time_ms)
    local total = replay.dungeon and tonumber(replay.dungeon.total_enemy_forces)
    local mapID = opts and tonumber(opts.mapID)
    if not level or level < 2 or not durMs or durMs <= 0 or not total or total < 1 then
        return nil, "replay is missing level/time/forces"
    end
    if not mapID then return nil, "caller must resolve mapID" end
    -- ≤4000 events can emit up to ~2× step nodes, past CleanRun's 5000-snapshot
    -- cap — a pathological replay converts then cleans to nil and the caller
    -- falls back to the live mirror. Graceful by construction, so no tighter gate.
    if #replay.events == 0 or #replay.events > 4000 then return nil, "unusable event count" end

    local penalty = (level >= 12 and 15) or (level >= 4 and 5) or 0
    local events = {}
    for i, ev in ipairs(replay.events) do
        if type(ev) ~= "table" or not tonumber(ev[1]) or not tonumber(ev[2]) then
            return nil, "malformed event"
        end
        events[i] = ev
    end
    table.sort(events, function(a, b) return a[1] < b[1] end)

    local encounters = {}
    if type(replay.encounters) == "table" then
        for _, e in ipairs(replay.encounters) do
            if type(e) == "table" and tonumber(e.ordinal) then
                encounters[tonumber(e.ordinal)] = e
            end
        end
    end

    local snaps = { { 0, 0, 0 } }
    local kills, ids, jids, counts, engages = {}, {}, {}, {}, {}
    local lastEngage = {} -- per ordinal: latest (re-)engage — wipes re-start fights
    local deaths, deathList = 0, {}
    local cum, bosses = 0, 0

    local function shifted(ms) return ms / 1000 + deaths * penalty end
    local function node(t, c, b) snaps[#snaps + 1] = { t, c, b } end

    for _, ev in ipairs(events) do
        local tMs, kind = ev[1], ev[2]
        local t = math.floor(shifted(tMs) + 0.5)
        if kind == 2 then
            local d = tonumber(ev[3]) or 0
            local newCum = math.min(total, cum + math.max(0, d))
            if newCum ~= cum then
                node(t, cum, bosses) -- the step's base: flat until THIS award
                node(t, newCum, bosses)
                cum = newCum
            end
        elseif kind == 1 then
            -- Per-event cap + total bail: a garbage delta must not spin the loop —
            -- CleanRun would reject >300 deaths anyway, so converting on is waste.
            local n = math.min(40, math.max(1, tonumber(ev[3]) or 1))
            for _ = 1, n do
                deaths = deaths + 1
                deathList[#deathList + 1] = { t, deaths }
            end
            if deaths > 300 then return nil, "implausible death count" end
        elseif kind == 3 then
            local ord = tonumber(ev[3])
            if ord then lastEngage[ord] = t end
        elseif kind == 4 then
            local ord = tonumber(ev[3])
            if ord and ev[6] == true then -- killed
                bosses = bosses + 1
                kills[bosses] = t
                counts[bosses] = cum
                engages[bosses] = lastEngage[ord]
                local enc = encounters[ord]
                ids[bosses] = enc and tonumber(enc.encounter_id) or nil
                jids[bosses] = enc and tonumber(enc.journal_encounter_id) or nil
                node(t, cum, bosses)
            end
        end
    end

    local durationSec = durMs / 1000
    local lastT = snaps[#snaps][1]
    local finalT = math.max(math.ceil(durationSec), lastT)
    if finalT > lastT then node(finalT, cum, bosses) end

    local raw = {
        legacy = "RIO",
        mapID = mapID,
        level = level,
        durationSec = durationSec,
        total = total,
        completedAt = M.IsoToEpoch(replay.date),
        parTimeSec = opts and tonumber(opts.parTimeSec) or nil,
        snapshots = snaps,
        bossKills = kills,
        bossIDs = ids,
        bossJIDs = jids,
        bossCounts = counts,
        bossEngages = engages,
        deathCount = deaths > 0 and deaths or nil,
        deaths = #deathList > 0 and deathList or nil,
    }
    if type(replay.affixes) == "table" then
        local af = {}
        for _, a in ipairs(replay.affixes) do
            local id = type(a) == "table" and tonumber(a.id)
            if id then af[#af + 1] = id end
        end
        if #af > 0 then raw.affixes = af end
    end
    return raw
end
