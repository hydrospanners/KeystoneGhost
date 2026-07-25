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
-- lets it double as the recorder of per-pull TIMES — the data a future "per-pull lap"
-- UI needs is captured on every run from now on.
--
-- TWO stamps per pull since 2026-07-25:
--   * `pullTimes[k]` — when pull k first tested COMPLETE (threshold, or the boss
--     criterion for a boss pull). A COMPLETION time. The name doesn't say so and
--     is kept anyway — it is in the wire contract, and docs/DATA-DICTIONARY.md is
--     where that meaning lives now (Fredrik's rule: a shipped name changes when we
--     break the contract on purpose, not because a better word turned up).
--   * `pullFirstForces[k]` — when forces first climbed PAST pull k-1's cumulative,
--     i.e. the first kill that can only belong to pull k.
-- Completion-to-completion lumps travel and fighting together; with both stamps the
-- split is `firstForces[k] - pullTimes[k-1]` (walking there and opening the pack)
-- and `pullTimes[k] - firstForces[k]` (killing it). Neither is a combat-log engage —
-- this addon has no engage event for trash, which is exactly why nothing here claims
-- one. Boss pulls have a real engage already: `run.bossEngages` (ENCOUNTER_START).
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

--- Pure first-forces computation: pull k has been opened once raw forces climb past
--- pull k-1's cumulative — the first award that cannot belong to an earlier pull.
--- A pull with NO forces budget of its own (a boss pull: cumulative doesn't move)
--- never gets a stamp; its engage lives in `run.bossEngages` instead. Absolute like
--- ComputeCompletion, so it is drift-free and self-heals after a /reload.
--- @return startedSet
function Track.ComputeFirstForces(cumulativeForces, raw)
    local started = {}
    local prevCumulative = 0
    for k = 1, (cumulativeForces and #cumulativeForces or 0) do
        local ck = cumulativeForces[k] or prevCumulative
        started[k] = ck > prevCumulative and raw > prevCumulative
        prevCumulative = ck
    end
    return started
end

--- Start tracking a run against `route` ({ cumulativeForces, bossPull, nPulls });
--- nil to disable. `seedPullTimes` / `seedFirstForces` (Live Run adoption after a
--- /reload) re-attach the persisted stamp tables BY REFERENCE — recording continues
--- into the same tables; already-stamped times are kept, everything else self-heals
--- from absolute forces on the first Update.
function Track:Reset(route, seedPullTimes, seedFirstForces)
    st = {
        route = route,
        bossCompleted = {},
        lastBossCount = 0,
        pending = 0,
        completed = {},
        pullTimes = seedPullTimes or {},
        pullFirstForces = seedFirstForces or {},
        currentPull = (route and route.nPulls > 0) and 1 or nil,
    }
end

--- Advance from the current snapshot. `bossCount` = total boss criteria completed so
--- far; new kills are assigned to boss pulls in ascending route order (same heuristic
--- as APL — correct for on-route play, best-effort off-route). `t` stamps first-time
--- pull completions and first-forces into their tables.
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
    local started = Track.ComputeFirstForces(route.cumulativeForces, raw)
    for k = 1, route.nPulls do
        if completed[k] and not st.pullTimes[k] and t then
            st.pullTimes[k] = t
        end
        if started[k] and not st.pullFirstForces[k] and t then
            st.pullFirstForces[k] = t
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

--- First-COMPLETION time per pull index (sparse until the run finishes the route).
--- Named `pullTimes` on the wire; see docs/DATA-DICTIONARY.md.
function Track:GetPullTimes()
    return st.pullTimes
end

--- Time the first forces landed on each pull (sparse: boss pulls and unreached
--- pulls have no entry). See the header for the travel-vs-fight split.
function Track:GetPullFirstForces()
    return st.pullFirstForces
end
