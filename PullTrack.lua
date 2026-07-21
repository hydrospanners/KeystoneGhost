-- Stateful route pull tracking — APL PullTracking's proven model, ported.
--
-- Why not just infer from forces (GhostMath.InferPull)? Two failure modes: boss pulls
-- add ~no forces (so forces alone can't tell "fighting the boss" from "boss dead, moving
-- on"), and off-route pulling makes a raw forces→pull mapping drift. The model here is
-- drift-free: completion is computed from ABSOLUTE forces vs the route's cumulative
-- table, offset by a threshold; a boss pull completes only when a boss criterion flips
-- (with a small forces-slack escape hatch so a secret/missed criterion can't stall the
-- tracker forever).
--
-- This module is deliberately WoW-API-free: the recorder feeds it raw forces, the boss
-- kill count, and the clock. That makes it fully offline-testable (tests/run.lua) and
-- lets it double as the recorder of per-pull completion TIMES — the data future
-- "per-pull lap" UI needs is captured on every run from now on.
local ADDON_NAME, NS = ...
local KG = NS.KG

local Track = {}
KG.PullTrack = Track

local DEFAULT_THRESHOLD = 0.9

local st = {}

local function Threshold()
    local t = KG.db and KG.db.pullThreshold
    if type(t) == "number" and t > 0 and t <= 1 then return t end
    return DEFAULT_THRESHOLD
end

--- Pure completion computation (ported verbatim in spirit from APL).
--- A non-boss pull k is complete when raw forces reach cumulativeForces[k] minus the
--- unfinished slack allowed by the threshold. A boss pull completes on its boss
--- criterion — or, anti-stall, once forces climb clearly past its cumulative into
--- the next pull.
--- @return completedSet, currentPull (1..nPulls, or nPulls+1 when all done)
function Track.ComputeCompletion(cumulativeForces, bossPulls, bossCompleted, raw, threshold)
    local completed = {}
    local nPulls = cumulativeForces and #cumulativeForces or 0
    local routeTotal = (nPulls > 0 and cumulativeForces[nPulls]) or 0
    local bossSlack = math.max(1, routeTotal * 0.01)
    local prevCumulative = 0
    for k = 1, nPulls do
        local ck = cumulativeForces[k] or prevCumulative
        local pullForces = ck - prevCumulative
        if bossPulls and bossPulls[k] then
            completed[k] = (bossCompleted and bossCompleted[k] == true) or (raw >= ck + bossSlack)
        else
            local need = ck - (1 - threshold) * pullForces
            completed[k] = raw >= need
        end
        prevCumulative = ck
    end
    local current = nPulls + 1
    for k = 1, nPulls do
        if not completed[k] then
            current = k
            break
        end
    end
    return completed, current
end

--- Start tracking a run against `route` ({ cumulativeForces, bossPull, nPulls });
--- nil to disable. `seedPullTimes` (Live Run adoption after a /reload) re-attaches
--- the persisted pull-time table BY REFERENCE — recording continues into the same
--- table; already-stamped completions are kept, everything else self-heals from
--- absolute forces on the first Update.
function Track:Reset(route, seedPullTimes)
    st = {
        route = route,
        bossCompleted = {},
        lastBossCount = 0,
        pending = 0,
        completed = {},
        pullTimes = seedPullTimes or {},
        currentPull = (route and route.nPulls > 0) and 1 or nil,
    }
end

--- Advance from the current snapshot. `bossCount` = total boss criteria completed so
--- far; new kills are assigned to boss pulls in ascending route order (same heuristic
--- as APL — correct for on-route play, best-effort off-route). `t` stamps first-time
--- pull completions into pullTimes.
--- @return currentPull|nil
function Track:Update(raw, bossCount, t)
    local route = st.route
    if not route then return nil end

    if bossCount > st.lastBossCount then
        st.pending = st.pending + (bossCount - st.lastBossCount)
        st.lastBossCount = bossCount
    end
    if st.pending > 0 and route.bossPull then
        for k = 1, route.nPulls do
            if st.pending <= 0 then break end
            if route.bossPull[k] and not st.bossCompleted[k] then
                st.bossCompleted[k] = true
                st.pending = st.pending - 1
            end
        end
    end

    local completed, current = Track.ComputeCompletion(
        route.cumulativeForces, route.bossPull, st.bossCompleted, raw, Threshold())
    for k = 1, route.nPulls do
        if completed[k] and not st.pullTimes[k] and t then
            st.pullTimes[k] = t
        end
    end
    st.completed = completed
    st.currentPull = current
    return current
end

--- @return currentPull|nil, nPulls|nil
function Track:GetCurrentPull()
    if not st.route then return nil end
    return st.currentPull, st.route.nPulls
end

--- First-completion time per pull index (sparse until the run finishes the route).
function Track:GetPullTimes()
    return st.pullTimes
end
