-- Ghost storage and reference selection.
--
-- KeystoneGhostDB.runs[charKey][mapID][level] = { [tier] = run } — one slot per chest tier
-- (0 = depleted, 1..3 = +1/+2/+3), fastest run kept per slot, so max 4 ghosts per
-- (character, dungeon, level) by construction.
--
-- run = { durationSec, completedAt, level, mapID, chests, parTimeSec, deathCount,
--         snapshots = { {t, pct, bosses}, ... }, bossKills = { t1, t2, ... } }
local ADDON_NAME, NS = ...
local KG = NS.KG
local M = KG.Math
local S = KG.Scenario

local G = {}
KG.Ghosts = G

local function RunsFor(charKey, mapID, level, create)
    local db = KG.db
    if not db then return nil end
    local byChar = db.runs
    if create then
        byChar[charKey] = byChar[charKey] or {}
        byChar[charKey][mapID] = byChar[charKey][mapID] or {}
        byChar[charKey][mapID][level] = byChar[charKey][mapID][level] or {}
    end
    local byMap = byChar[charKey]
    local byLevel = byMap and byMap[mapID]
    return byLevel and byLevel[level], byLevel
end

function G:Save(run)
    local tiers = select(1, RunsFor(KG.CharacterKey(), run.mapID, run.level, true))
    G:InvalidateRoster()
    return M.InsertRun(tiers, run)
end

local function ShortName(charKey)
    return (charKey or ""):match("^([^%-]+)") or charKey or "?"
end

--- Live RaiderIO replay ghost (guild/user best, per RaiderIO's own replay settings).
--- The replay plays forward in wall-clock sync, so this reference starts with an empty
--- timeline that the recorder mirrors tick by tick (Ghosts:UpdateRioMirror); only the
--- final duration is known upfront. Requires RaiderIO with its Replay module active.
function G:BuildRioReference()
    local RIO = _G.RaiderIO
    if not RIO or not RIO.GetCurrentReplay then return nil end
    local ok, _live, rep = pcall(RIO.GetCurrentReplay)
    if not ok or type(rep) ~= "table" then return nil end
    local durMs = tonumber(rep.clear_time_ms)
    local total = tonumber(rep.dungeon_total_enemy_forces)
    if not durMs or durMs <= 0 or not total or total <= 0 then return nil end
    local dur = durMs / 1000
    return {
        kind = "rio", live = true,
        label = string.format("RaiderIO replay (%s)", M.FormatClock(dur)),
        durationSec = dur,
        rioTotal = total,
        nowPct = 0, nowBosses = 0,
        run = { durationSec = dur, snapshots = { { 0, 0, 0 } }, bossKills = {}, bossNames = {}, bossPcts = {} },
    }
end

--- Mirror the RaiderIO replay's progress into the reference's timeline (called from the
--- recorder tick). Boss kill timestamps come exact from the replay events; names resolve
--- via the journal encounter when possible.
function G:UpdateRioMirror(ref, t)
    local RIO = _G.RaiderIO
    if not RIO or not RIO.GetCurrentReplay then return end
    local ok, _live, rep = pcall(RIO.GetCurrentReplay)
    if not ok or type(rep) ~= "table" then return end
    local pct = math.min(100, (tonumber(rep.trash) or 0) / ref.rioTotal * 100)
    if type(rep.bosses) == "table" and #rep.bosses > 0 then
        ref.nBosses = #rep.bosses -- fixed road layout for course positions
    end

    local kills = {}
    if type(rep.bosses) == "table" then
        for _, b in ipairs(rep.bosses) do
            if type(b) == "table" and b.dead and tonumber(b.killed) then
                kills[#kills + 1] = { t = b.killed / 1000, jid = b.encounter and b.encounter.journal_encounter_id }
            end
        end
        table.sort(kills, function(a, b2) return a.t < b2.t end)
    end
    local run = ref.run
    for i = #run.bossKills + 1, #kills do
        run.bossKills[i] = kills[i].t
        if kills[i].jid and EJ_GetEncounterInfo then
            local okN, name = pcall(EJ_GetEncounterInfo, kills[i].jid)
            if okN and type(name) == "string" then run.bossNames[i] = name end
        end
    end
    ref.nowPct = pct
    ref.nowBosses = #run.bossKills
    local snaps = run.snapshots
    local last = snaps[#snaps]
    if not last or t - last[1] >= 2 then
        snaps[#snaps + 1] = { t, pct, ref.nowBosses }
    end
end

--- Store an imported run under its exporter's character key and auto-pick it for racing
--- at that (dungeon, level) — importing exists to compete against the sender.
function G:StoreImport(run, exporter)
    G:InvalidateRoster()
    run.importedFrom = exporter
    run.importedAt = time()
    local db = KG.db
    db.runs[exporter] = db.runs[exporter] or {}
    db.runs[exporter][run.mapID] = db.runs[exporter][run.mapID] or {}
    db.runs[exporter][run.mapID][run.level] = db.runs[exporter][run.mapID][run.level] or {}
    M.InsertRun(db.runs[exporter][run.mapID][run.level], run)
    db.pick[run.mapID .. ":" .. run.level] = { char = exporter, tier = run.chests }
    return run
end

--- Decode + validate + store an export string. Returns the stored run or nil, err.
function G:ImportString(text)
    local payload, err = KG.Codec.Decode(text)
    if not payload then return nil, err end
    local run, exporter, verr = KG.Codec.ValidatePayload(payload)
    if not run then return nil, verr end
    return G:StoreImport(run, exporter), nil
end

--- Export your best TIMED run at (mapID, level) as a share string. nil, err when none —
--- depleted runs never race, so they are never worth sharing either.
function G:ExportString(mapID, level)
    local tiers = select(1, RunsFor(KG.CharacterKey(), mapID, level, false))
    local run = tiers and M.BestRun(tiers, 1)
    if not run or not run.snapshots then return nil, "no timed ghost recorded for that dungeon/level" end
    return KG.Codec.Export(KG.Codec.BuildPayload(run, KG.CharacterKey()))
end

--- Build the ghost reference for a live run: imported ghost (auto-picked on import) →
--- own recorded run (exact level → highest below → lowest above) → RaiderIO replay →
--- season best (linear) → par (linear). Every reference carries `snapshots` so the bar
--- and delta math treat all kinds uniformly. Depleted (tier 0) runs are recorded but
--- NEVER raced (Fredrik 2026-07-19) — the +1 sweeper is the deplete pressure; a
--- pick/override UI is a later development stage (the /kg race command was dropped).
function G:BuildReference(mapID, level)
    local pick = level and KG.db.pick[mapID .. ":" .. level]

    if type(pick) == "table" and pick.char then -- imported ghost (timed only — never tier 0)
        local byMap = KG.db.runs[pick.char]
        local tiers = byMap and byMap[mapID] and byMap[mapID][level]
        local run = tiers and ((pick.tier and pick.tier >= 1 and tiers[pick.tier]) or M.BestRun(tiers, 1))
        if run and run.snapshots then
            return {
                kind = "import",
                label = string.format("%s's %s +%d (%s)", ShortName(pick.char),
                    M.TierLabel(run.chests), level, M.FormatClock(run.durationSec)),
                run = run,
                durationSec = run.durationSec,
            }
        end
    end

    local _, byLevel = RunsFor(KG.CharacterKey(), mapID, level or -1, false)
    -- Only levels holding at least one TIMED run participate in level fallback, so a
    -- level with nothing but depleted runs can't shadow a timed run one level down.
    local timedByLevel
    if byLevel then
        for lvl, tiers in pairs(byLevel) do
            if M.BestRun(tiers, 1) then
                timedByLevel = timedByLevel or {}
                timedByLevel[lvl] = tiers
            end
        end
    end
    local tiers, lvlUsed = M.PickLevel(timedByLevel, level)
    if tiers then
        local run, tier = M.BestRun(tiers, 1)
        if run and run.snapshots then
            return {
                kind = "personal",
                label = string.format("Your %s +%d (%s)", M.TierLabel(tier), lvlUsed, M.FormatClock(run.durationSec)),
                run = run,
                durationSec = run.durationSec,
                tier = tier,
                levelUsed = lvlUsed,
            }
        end
    end

    local rio = G:BuildRioReference()
    if rio then return rio end

    local best = S:GetSeasonBestSec(mapID)
    if best then
        return {
            kind = "season",
            label = "Season best (" .. M.FormatClock(best) .. ")",
            run = { snapshots = M.LinearSnapshots(best), durationSec = best },
            durationSec = best,
        }
    end

    local par = S:GetParTimeSec(mapID)
    if par then
        return {
            kind = "par",
            label = "Par pace (" .. M.FormatClock(par) .. ")",
            run = { snapshots = M.LinearSnapshots(par), durationSec = par },
            durationSec = par,
        }
    end
    return nil
end

--- Fill the ghost roster to `KeystoneGhostDB.rosterSize` rows (default 3), excluding the
--- raced ghost (the caller renders that row first). Priority chain (Fredrik 2026-07-19):
---   1. imported ghosts at this (dungeon, level)
---   2. this character's timed runs at this level
---   3. this character's timed runs one/two levels below, then above
---   4. other own characters' timed runs at this level, then ±1
--- Depleted runs never race — not as fillers either (Fredrik 2026-07-19).
--- Within equal priority, runs recorded on the SAME MDT route as the raced ghost win
--- (routeName tiebreak — the first cut at the multidimensional route problem; the full
--- route-aware priority tree is an open design question in DESIGN.md).
--- RaiderIO's replay can't be a filler row: it exists only as the live raced reference.
function G:BuildRoster(mapID, level, racedRun)
    if not level then return {} end -- key level unreadable (secret flicker): no roster, no crash
    local target = (KG.db.rosterSize or 3) - 1 -- minus the raced row
    local out, seen = {}, { [racedRun or false] = true }
    local myKey = KG.CharacterKey()
    local wantRoute = racedRun and racedRun.routeName

    local function add(run, tag)
        if #out < target and run and run.snapshots and not seen[run] then
            seen[run] = true
            out[#out + 1] = { run = run, tag = tag }
        end
    end
    --- Two passes when a route preference exists: same-route runs first.
    local function addTiers(tiers, tag, minTier)
        if type(tiers) ~= "table" then return end
        for pass = 1, wantRoute and 2 or 1 do
            for tier = KG.MAX_TIER, minTier, -1 do
                local run = tiers[tier]
                if run and (not wantRoute or (pass == 1) == (run.routeName == wantRoute)) then
                    add(run, tag)
                end
            end
        end
    end

    local db = KG.db
    for charKey, byMap in pairs(db.runs) do -- 1. imports at this level (timed only)
        local tiers = byMap[mapID] and byMap[mapID][level]
        if tiers then
            for tier = KG.MAX_TIER, 1, -1 do
                local run = tiers[tier]
                if run and run.importedFrom then add(run, ShortName(charKey)) end
            end
        end
    end

    local mine = db.runs[myKey] and db.runs[myKey][mapID]
    addTiers(mine and mine[level], nil, 1) -- 2. own timed, this level
    for _, lvl in ipairs({ level - 1, level + 1, level - 2, level + 2 }) do -- 3. own timed, near levels
        if #out >= target then break end
        addTiers(mine and mine[lvl], "+" .. lvl, 1)
    end

    for charKey, byMap in pairs(db.runs) do -- 4. own alts (non-imported foreign charKeys)
        if charKey ~= myKey and #out < target then
            local m = byMap[mapID]
            if m then
                for _, lvl in ipairs({ level, level - 1, level + 1 }) do
                    local t = m[lvl]
                    if t then
                        for tier = KG.MAX_TIER, 1, -1 do
                            local run = t[tier]
                            if run and not run.importedFrom then
                                add(run, ShortName(charKey) .. (lvl ~= level and (" +" .. lvl) or ""))
                            end
                        end
                    end
                end
            end
        end
    end

    return out
end

--- One-time data repair on login: every stored ghost recorded before the clock fixes
--- gets its timeline shifted onto the official timer and de-noised (M.RepairRun).
function G:RepairAll()
    local fixed = 0
    for _, byMap in pairs(KG.db.runs) do
        for _, byLevel in pairs(byMap) do
            for _, tiers in pairs(byLevel) do
                for _, run in pairs(tiers) do
                    if M.RepairRun(run, 10) then fixed = fixed + 1 end
                end
            end
        end
    end
    if fixed > 0 then
        G:InvalidateRoster()
        print("|cff88ccffKeystoneGhost|r: cleaned " .. fixed
            .. " stored ghost(s) — countdown offset removed, collapse noise dropped.")
    end
end

--- Cached roster (the bar draws roster runners every frame; the underlying list only
--- changes on save/import/pick). Invalidated explicitly.
local rosterCache = {}
function G:InvalidateRoster()
    rosterCache.key = nil
end

function G:GetRoster(mapID, level, racedRun)
    local key = tostring(mapID) .. ":" .. tostring(level) .. ":" .. tostring(racedRun)
    if rosterCache.key ~= key then
        rosterCache.key = key
        rosterCache.list = G:BuildRoster(mapID, level, racedRun)
    end
    return rosterCache.list
end

--- Stored ghosts for the current character, printed by /keystoneghost list.
function G:DescribeAll()
    local out = {}
    local byMap = KG.db.runs[KG.CharacterKey()]
    if not byMap then return out end
    for mapID, byLevel in pairs(byMap) do
        local name = S:GetMapName(mapID)
        for level, tiers in pairs(byLevel) do
            for tier = KG.MAX_TIER, 0, -1 do
                local run = tiers[tier]
                if run then
                    out[#out + 1] = string.format("%s +%d — %s (%s)%s",
                        name or ("map " .. mapID), level, M.TierLabel(tier),
                        M.FormatClock(run.durationSec or 0), run.legacyAPL and " [APL]" or "")
                end
            end
        end
    end
    table.sort(out)
    return out
end
