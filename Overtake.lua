-- The Raced-Ghost Switch core — pure logic, no WoW APIs (offline-tested, same
-- discipline as GhostMath/PullTrack). Design: docs/SWITCH-WORKSHOP.md decision record
-- (Fredrik 2026-07-19). One Overtake/hysteresis core drives BOTH the Gap attachment
-- and the full switch — consumers (Recorder, Bar, Splits) read its output.
--
-- An **Overtake** is a course-position crossing (W1): a Roster Ghost's CoursePos
-- crosses Mario's — Track geometry, the thing the player SEES. Guards (W2/W3):
--   · the **No-Switch Buffer Zone** around Mario (~10–15% of the camera viewport,
--     tuned by eye): a challenger inside it NEVER triggers, however long it sits;
--   · the **rubber band**: the challenger must stay beyond the buffer for HOLD_SEC
--     continuously — dipping back inside resets the timer; crossing back to its old
--     side discards the candidacy entirely (a fresh crossing re-arms it);
--   · the **pair cooldown**: after a switch the same pair can't swap back for
--     COOLDOWN_SEC — a third ghost is not subject to it. When the cooldown blocks a
--     challenger whose guards are met, it keeps holding and fires on expiry.
-- Boss fights are fair game (S5 reversed — no boss-stall guard). A parked ghost
-- (course pinned at 1.0 after finishing) is never an Overtake ACTOR (S10). Pinning
-- (W7/S9): a manual switch pins — autos stop until unpinned; unpinning restarts all
-- hold timers fresh (no credit for time spent pinned). Imports start pinned (S13).
local ADDON_NAME, NS = ...
local KG = NS.KG

local O = {}
KG.Overtake = O

O.HOLD_SEC = 3
O.COOLDOWN_SEC = 20
O.BUFFER_FRAC = 0.125 -- of the camera viewport (Fredrik: ~10–15%; tune by eye)

--- Fresh state, attached to `id` (the initial Raced Ghost). Ids are opaque keys —
--- in practice the run tables themselves (stable for the life of a key).
function O.New(id, pinned)
    return {
        attached = id,
        pinned = pinned or false,
        side = {},     -- [id] = -1|1 — which side of Mario the runner was last seen on
        cand = {},     -- [id] = { side, heldSince } — armed by a crossing
        cooldown = {}, -- [a][b] = expiry — pairwise swap-back block
    }
end

local function PairCooling(state, a, b, now)
    local row = a and state.cooldown[a]
    local untilT = row and row[b]
    return untilT ~= nil and now < untilT
end

local function SetPairCooldown(state, a, b, untilT)
    if not a or not b then return end
    state.cooldown[a] = state.cooldown[a] or {}
    state.cooldown[b] = state.cooldown[b] or {}
    state.cooldown[a][b] = untilT
    state.cooldown[b][a] = untilT
end

--- Manual switch (S9: clicking a non-raced Roster Panel row): immediate, and PINS —
--- automatic Overtakes stop firing until unpinned. Returns the previous attachment.
--- Other runners' candidacies survive (they crossed MARIO, not the attachment) but
--- their hold timers stay frozen while pinned.
function O.ManualSwitch(state, id)
    local old = state.attached
    state.attached = id
    state.pinned = true
    state.cand[id] = nil
    return old
end

--- Pin the current attachment in place (clicking the raced row while unpinned).
function O.Pin(state)
    state.pinned = true
end

--- Unpin (S9: clicking the currently-raced row again): autos resume with hold timers
--- starting fresh — no credit for time spent pinned. Candidates armed during the pin
--- (crossings that happened while it was on) stay armed; their clocks start now.
function O.Unpin(state)
    state.pinned = false
end

--- One evaluation tick. `runners` = array of { id, course, parked }; entries matching
--- the current attachment are side-tracked but never candidates. Returns the id
--- switched to when an Overtake fires this tick (at most one per call), else nil.
function O.Evaluate(state, now, you, runners, opts)
    local buffer = (opts and opts.buffer) or (O.BUFFER_FRAC * 0.45)
    local holdSec = (opts and opts.holdSec) or O.HOLD_SEC
    local cooldownSec = (opts and opts.cooldownSec) or O.COOLDOWN_SEC

    for _, r in ipairs(runners) do
        local id = r.id
        local s = (r.course >= you) and 1 or -1
        local prev = state.side[id]
        state.side[id] = s

        if id == state.attached or r.parked then
            state.cand[id] = nil
        else
            if prev ~= nil and s ~= prev then
                local c0 = state.cand[id]
                if c0 and c0.side ~= s then
                    state.cand[id] = nil -- crossed back to its old side: candidacy over
                else
                    state.cand[id] = { side = s } -- fresh crossing: arm on the new side
                end
            end
            local c = state.cand[id]
            if c then
                if state.pinned then
                    c.heldSince = nil -- pin freezes the clock (no credit — S9)
                elseif (r.course - you) * s > buffer then -- beyond the Buffer Zone
                    c.heldSince = c.heldSince or now
                    if now - c.heldSince >= holdSec
                        and not PairCooling(state, state.attached, id, now) then
                        local old = state.attached
                        state.attached = id
                        SetPairCooldown(state, old, id, now + cooldownSec)
                        state.cand = {} -- everyone re-arms via a fresh crossing
                        return id
                    end
                else
                    c.heldSince = nil -- inside the buffer: the rubber band resets
                end
            end
        end
    end
    return nil
end
