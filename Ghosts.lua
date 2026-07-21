-- Ghost storage and reference selection.
--
-- KeystoneGhostDB.runs[charKey][mapID][level] = { [tier] = run } — one slot per chest tier
-- (0 = depleted, 1..3 = +1/+2/+3), fastest run kept per slot, so max 4 ghosts per
-- (character, dungeon, level) by construction.
--
-- run = { total, durationSec, completedAt, level, mapID, chests, parTimeSec, deathCount,
--         snapshots = { {t, count, bosses}, ... }, bossKills = { t1, t2, ... } }
-- Count-space (v3): snapshots carry the raw integer forces count in the run's own
-- units (run.total); linear pace ghosts are percent-shaped with total = 100; the
-- RaiderIO mirror runs in RaiderIO's own units with their total.
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

-- ── Route Store (route dossier §7): one entry per unique route CONTENT ─────────
-- db.routes[hash] = the route as captured at that run's key start; runs reference
-- via run.routeHash. Renames are display-only (same hash upserts the newest name).

function G:StoreRoute(rd)
    if type(rd) ~= "table" or not rd.hash or type(rd.pulls) ~= "table" then return end
    KG.db.routes[rd.hash] = {
        hash = rd.hash,
        name = rd.name,
        createdBy = rd.createdBy,
        cumulativeForces = rd.cumulativeForces, -- frozen at capture: receivers may
        bossPull = rd.bossPull,                 -- lack MDT; counts drift across patches
        nPulls = rd.nPulls,
        pulls = rd.pulls,
        uid = rd.uid,
        dungeonIdx = rd.dungeonIdx,
        sublevel = rd.sublevel,
        week = rd.week,
        difficulty = rd.difficulty,
        -- NAMED FOR WHAT IT IS (Fredrik 2026-07-20, reading his own export's
        -- timestamps): this stamps when the Route Store ENTRY is written — at
        -- run save / import time — NOT when the route content was frozen (that
        -- happens at key start, ~the run's length earlier). The old name
        -- `capturedAt` misled exactly that way. Legacy key accepted on import.
        storedAt = rd.storedAt or (S and S.ServerNow and S:ServerNow()) or 0,
    }
    G:SweepRoutes()
end

function G:RouteForHash(hash)
    return hash and KG.db.routes and KG.db.routes[hash] or nil
end

--- The most recently imported ghost's Route Store entry (/kg route outside a key —
--- the receiver wants the route BEFORE stepping into the dungeon).
function G:LastImportedRoute()
    local li = KG.db.lastImported
    if not li then return nil end
    local byMap = KG.db.runs[li.char]
    local tiers = byMap and byMap[li.mapID] and byMap[li.mapID][li.level]
    if not tiers then return nil end
    for tier = KG.MAX_TIER, 0, -1 do
        local run = tiers[tier]
        if run and run.routeHash then
            local rd = G:RouteForHash(run.routeHash)
            if rd then return rd end
        end
    end
    return nil
end

--- GC: tier-slot eviction can orphan a stored route — drop entries no run references.
function G:SweepRoutes()
    local routes = KG.db.routes
    if not routes or not next(routes) then return end
    local used = {}
    for _, byMap in pairs(KG.db.runs) do
        for _, byLevel in pairs(byMap) do
            for _, tiers in pairs(byLevel) do
                for _, run in pairs(tiers) do
                    if run.routeHash then used[run.routeHash] = true end
                end
            end
        end
    end
    for h in pairs(routes) do
        if not used[h] then routes[h] = nil end
    end
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
        nowCount = 0, nowBosses = 0,
        -- The mirror runs in RaiderIO's OWN count units (rep.trash against their
        -- total); cross-total math maps it against the live scenario units (±1 on
        -- season retunes — cosmetic, fraction space absorbs it).
        run = { durationSec = dur, total = total, snapshots = { { 0, 0, 0 } },
            bossKills = {}, bossNames = {}, bossCounts = {}, bossIDs = {}, bossJIDs = {} },
    }
end

--- Mirror the RaiderIO replay's progress into the reference's timeline (called from the
--- recorder tick). Boss kill timestamps come exact from the replay events (RaiderIO
--- flips dead/killed PROGRESSIVELY as the replay plays — verified in their core.lua,
--- ApplyBossInfoToSummary); names resolve via the journal encounter when possible.
---
--- The mirror is only trustworthy for the span we actually WATCHED. When the ref is
--- built late (the first-minute upgrade path, or the self-healing resume after a
--- /reload), RaiderIO fast-forwards its summary to the current timer and hands us
--- kills from before our first sample — their COUNT at kill time is unknown to us,
--- and interpolating the fabricated 0→now span put skulls at even-spaced wrong
--- positions (Fredrik's Live Test 1 field report). So: bossCounts[i] is stamped
--- with the exact count only for kills that land while we watch; pre-mirror kills
--- keep a nil count (the Bar hides those skulls rather than guessing — the kill
--- itself stays in bossKills, the Gap's boss constraint is untouched), and a late
--- first sample REPLACES the {0,0,0} seed so no fabricated span exists at all.
function G:UpdateRioMirror(ref, t)
    local RIO = _G.RaiderIO
    if not RIO or not RIO.GetCurrentReplay then return end
    local ok, _live, rep = pcall(RIO.GetCurrentReplay)
    if not ok or type(rep) ~= "table" then return end
    local count = math.min(ref.rioTotal, tonumber(rep.trash) or 0)
    if type(rep.bosses) == "table" and #rep.bosses > 0 then
        ref.nBosses = #rep.bosses -- fixed road layout for course positions
    end

    local kills = {}
    if type(rep.bosses) == "table" then
        for _, b in ipairs(rep.bosses) do
            if type(b) == "table" and b.dead and tonumber(b.killed) then
                kills[#kills + 1] = { t = b.killed / 1000,
                    id = b.encounter and tonumber(b.encounter.encounter_id),
                    jid = b.encounter and b.encounter.journal_encounter_id }
            end
        end
        table.sort(kills, function(a, b2) return a.t < b2.t end)
    end
    local run = ref.run
    if not ref.mirrorFrom then
        ref.mirrorFrom = t -- the honest span starts at our first real sample
        if t > 5 then
            run.snapshots = { { t, count, #kills } } -- late init: drop the 0,0 seed
        end
    end
    for i = #run.bossKills + 1, #kills do
        run.bossKills[i] = kills[i].t
        if kills[i].t >= ref.mirrorFrom then
            run.bossCounts[i] = count -- landed on our watch: count is exact
        end
        -- Identity stamps (first-class replay, 2026-07-21): the summary carries the
        -- encounter ids, so even the degraded mirror pairs laps/tooltips by BOSS
        -- (LapDeltasByID) instead of the kill-order fallback that compared
        -- different bosses on off-order routes — the original first-run complaint.
        run.bossIDs[i] = kills[i].id
        run.bossJIDs[i] = tonumber(kills[i].jid)
        if kills[i].jid and EJ_GetEncounterInfo then
            local okN, name = pcall(EJ_GetEncounterInfo, kills[i].jid)
            if okN and type(name) == "string" then run.bossNames[i] = name end
        end
    end
    ref.nowCount = count
    ref.nowBosses = #run.bossKills
    -- Change-only mirror nodes (the 2026-07-21 event-log cutover): the replay's
    -- count is step-shaped by construction, so clock-cadence appends recorded
    -- flats and smeared each step up to 2 s. AppendStepNode no-ops between
    -- changes and lands steps at the tick that watched them (≤ 0.5 s).
    M.AppendStepNode(run.snapshots, t, count, ref.nowBosses)
end

-- ── The first-class Raider.IO ghost (2026-07-21, superseding mirror-first) ────
--
-- RaiderIO holds the ENTIRE decoded replay in memory — full ms event log, boss
-- encounter ids, deaths — behind a named global frame; only their per-tick summary
-- is public API. Reaching the full object turns the replay into a normal stored
-- ghost (ConvertRioReplay): full skulls from 0:00, identity laps, plain inversion
-- math, Library citizenship. CACHE-ON-SIGHT because their full replay LIST is
-- private: whenever the provider's pick is visible (staging, key start, Library
-- refresh) it is converted and stored under KG.RIO_CHAR — one ghost per dungeon,
-- the newest replay replacing the old. The tick mirror above stays as the
-- degraded fallback (their internals are not API; every hop is feature-detected).

--- The full Replay object from RaiderIO's replay frame provider, or nil.
--- Chain verified against their core.lua (2026-07-21): CreateFrame named
--- "<addon>_ReplayFrame", GetReplayDataProvider/GetReplay are pure getters, the
--- provider is populated during STAGING (before the key) and auto-swapped per map.
local function GetProviderReplay()
    local frame = _G.RaiderIO_ReplayFrame
    if type(frame) ~= "table" or type(frame.GetReplayDataProvider) ~= "function" then return nil end
    local okP, provider = pcall(frame.GetReplayDataProvider, frame)
    if not okP or type(provider) ~= "table" or type(provider.GetReplay) ~= "function" then return nil end
    local okR, replay = pcall(provider.GetReplay, provider)
    if not okR or type(replay) ~= "table" then return nil end
    if replay.format_version ~= 2 then return nil end -- the forensics-verified shape only
    return replay
end

--- Their sources[] → one display word; nil on anything unrecognized (the label
--- then says "replay" — never a guessed claim about provenance).
local RIO_SOURCE_WORDS = {
    guild_best_replay = "guild best",
    user_best_replay = "your best",
    user_recent_replay = "recent run",
    team_best_replay = "team best",
    watched_replay = "watched",
}
local function RioSourceWord(sources)
    if type(sources) ~= "table" then return nil end
    for _, s in ipairs(sources) do
        if RIO_SOURCE_WORDS[s] then return RIO_SOURCE_WORDS[s] end
    end
    return nil
end

local function RioLabel(run)
    return string.format("RaiderIO %s +%d (%s)", run.rioSource or "replay",
        run.level or 0, M.FormatClock(run.durationSec or 0))
end

--- Store/replace the one Raider.IO ghost for its dungeon. DIRECT write, not
--- InsertRun: the provider's pick is authoritative — a new replay replaces the old
--- across levels and even when slower (InsertRun's faster-incumbent rule would
--- wrongly block it). Same-replay short-circuit returns the EXISTING stored table:
--- table identity is load-bearing (Splits dedupe, Overtake state, runner
--- smoothing all key on the run table). The ":rio" pin key is level-independent,
--- so replacement never touches a pin.
function G:StoreRioGhost(run)
    local db = KG.db
    local byMap = db.runs[KG.RIO_CHAR]
    if byMap and byMap[run.mapID] then
        for _, tiers in pairs(byMap[run.mapID]) do
            for _, old in pairs(tiers) do
                -- Same replay → the SAME table. keystone_run_id when present; an
                -- id-less replay (off-spec but cheap to survive) dedupes on the
                -- (level, duration, date) triple — without this, every sight would
                -- mint a new table and the raced-ghost identity check would
                -- crossfade-rebuild the race every provider peek.
                if (old.rioRunId and old.rioRunId == run.rioRunId)
                    or (not old.rioRunId and not run.rioRunId
                        and old.level == run.level
                        and old.durationSec == run.durationSec
                        and old.completedAt == run.completedAt) then
                    return old
                end
            end
        end
    end
    db.runs[KG.RIO_CHAR] = db.runs[KG.RIO_CHAR] or {}
    db.runs[KG.RIO_CHAR][run.mapID] = { [run.level] = { [run.chests] = run } }
    G:InvalidateRoster()
    return run
end

--- The cached Raider.IO ghost for a dungeon (any level — one exists by
--- construction). Scans tier 0 too: an overtime replay is honestly Depleted and
--- still races here — never-race-depleted governs the OWN-run chain, not the
--- replay RaiderIO chose to track (so no M.BestRun, which skips tier 0).
function G:GetStoredRioRun(mapID)
    local byMap = KG.db.runs[KG.RIO_CHAR]
    local byLevel = byMap and byMap[mapID]
    if not byLevel then return nil end
    local best
    for _, tiers in pairs(byLevel) do
        for _, run in pairs(tiers) do
            if not best or (run.completedAt or 0) > (best.completedAt or 0) then best = run end
        end
    end
    return best
end

--- Convert + store the provider's current replay for mapID; returns the STORED
--- run or nil. Chests derive from par exactly like ImportKPG1 (tier 0 allowed —
--- an overtime replay is what RaiderIO tracks, racing it stays legal).
function G:BuildRioGhost(mapID)
    if not mapID then return nil end
    local replay = GetProviderReplay()
    if not replay then return nil end
    local raw = M.ConvertRioReplay(replay, { mapID = mapID, parTimeSec = S:GetParTimeSec(mapID) })
    if not raw then return nil end
    if raw.parTimeSec then
        raw.chests = M.TierForDuration(raw.durationSec, raw.parTimeSec)
    else
        raw.chests = 1 -- unknown par: assume timed (the ImportKPG1 convention)
    end
    raw.rioSource = RioSourceWord(replay.sources)
    raw.rioRunId = tonumber(replay.keystone_run_id)
    local run = M.CleanRun(raw)
    if not run then return nil end
    return G:StoreRioGhost(run)
end

--- The rio reference, full-first: fresh convert → stored cache (RaiderIO absent
--- or unreadable — the ghost still races from SavedVariables) → the live mirror
--- (full object unreachable but the summary API alive). No `live` flag on the
--- converted shapes: every bar/splits site then takes the normal stored-ghost
--- paths, which is the entire point.
function G:BuildRioRef(mapID, pinned)
    local run = G:BuildRioGhost(mapID) or G:GetStoredRioRun(mapID)
    if run then
        return {
            kind = "rio", startPinned = pinned or nil,
            label = RioLabel(run),
            run = run, durationSec = run.durationSec,
        }
    end
    local mirror = G:BuildRioReference()
    if mirror and pinned then mirror.startPinned = true end
    return mirror
end

--- Cache-on-sight door (staging PEW, Library refresh): gated on the challenge
--- map being readable — there is no public RIO-dungeon-id → challenge-mapID
--- mapping, and a guessed mapID would poison the store. Worst case the Library
--- row appears at key start instead; correctness is never at risk. The Library
--- refresh only fires when the stored table actually CHANGED — Refresh itself
--- calls this, so an unconditional refresh would recurse.
function G:CacheRioOnSight()
    local mapID = S:GetChallengeMapID()
    if not mapID then return end
    local prev = G:GetStoredRioRun(mapID)
    local run = G:BuildRioGhost(mapID)
    if run and run ~= prev and KG.Library and KG.Library.RefreshIfShown then
        KG.Library:RefreshIfShown()
    end
end

--- Display name for a ghost run's i-th boss kill — the ID dictionary at work
--- (AGENTS "IDs in the data, dictionaries at display"): the Encounter Journal's
--- LOCALIZED name when the run carries a journal ID (`bossJIDs`, recorded since
--- TASKS #11 — an import shows THIS client's locale, not the exporter's), else the
--- stored criteria-scraped name (a missed engage has no ID — the documented
--- ID-plus-fallback pair). Journal answers are session-cached; a jid the journal
--- can't answer caches as false and falls back forever.
local jidNameCache = {}
function G:BossDisplayName(run, i)
    local jid = run and run.bossJIDs and run.bossJIDs[i]
    if jid then
        local name = jidNameCache[jid]
        if name == nil and EJ_GetEncounterInfo then
            local ok, n = pcall(EJ_GetEncounterInfo, jid)
            name = (ok and type(n) == "string" and n ~= "") and n or false
            jidNameCache[jid] = name
        end
        if name then return name end
    end
    return run and run.bossNames and run.bossNames[i] or nil
end

--- The account's Share Tag (DESIGN "The Share Tag"): a random pseudonymous marker
--- so receivers can group ghosts imported from one person's alts — the battletag
--- benefit with zero real-world identity. Minted LAZILY on first export (a player
--- who never shares never has one): KG- + 16 hex chars, entropy mixed from server
--- time, GetTime fraction, math.random, and the player GUID — uniqueness is the
--- only requirement, derivability from identity the only sin. Account-wide by
--- construction (the SavedVariables file already is). Reset = forward-only mint.
function G:GetOrMintShareTag()
    local db = KG.db
    if type(db.shareTag) == "string" and db.shareTag:match("^KG%-%x+$") then
        return db.shareTag
    end
    local seed = tostring(S:ServerNow()) .. tostring((GetTime and GetTime() or 0) % 1)
    if UnitGUID then
        local ok, g = pcall(UnitGUID, "player")
        if ok and type(g) == "string" then seed = seed .. g end
    end
    local acc, hex = 5381, {}
    for i = 1, #seed do acc = (acc * 33 + seed:byte(i)) % 4294967296 end
    for i = 1, 16 do
        acc = (acc * 33 + math.random(0, 255)) % 4294967296
        hex[i] = string.format("%x", acc % 16)
    end
    db.shareTag = "KG-" .. table.concat(hex)
    return db.shareTag
end

--- One selected row per dungeon (Fredrik's 2026-07-21 bug report: pinning a
--- second level of the same dungeon left BOTH rows lit): sweep every pick the
--- dungeon holds before a new one lands. Level picks and the `:rio` key all
--- share the `mapID .. ":"` prefix. `keepRio` spares the rio pin — import
--- auto-picks never clear that deliberate act, only another deliberate pin does.
local function ClearDungeonPicks(pick, mapID, keepRio)
    local prefix = mapID .. ":"
    for k in pairs(pick) do
        if k:sub(1, #prefix) == prefix and not (keepRio and k == prefix .. "rio") then
            pick[k] = nil
        end
    end
end

--- Store an imported run under its exporter's character key and auto-pick it for racing
--- at that (dungeon, level) — importing exists to compete against the sender. The
--- auto-pick claims the dungeon's one selection (any previous level pick sweeps;
--- the rio pin alone survives, see ClearDungeonPicks). `route` (optional,
--- already sanitized) lands in the Route Store; the run's routeHash is
--- forced to OUR recomputed hash, never the sender's claim. `shareTag` (already
--- sanitized by the codec) is stamped for the future Data-view's alt grouping.
function G:StoreImport(run, exporter, route, shareTag)
    G:InvalidateRoster()
    run.importedFrom = exporter
    run.importedAt = S:ServerNow() -- server epoch, like every stored timestamp
    run.shareTag = shareTag
    if route and route.hash then
        run.routeHash = route.hash
        G:StoreRoute(route)
    end
    local db = KG.db
    db.runs[exporter] = db.runs[exporter] or {}
    db.runs[exporter][run.mapID] = db.runs[exporter][run.mapID] or {}
    db.runs[exporter][run.mapID][run.level] = db.runs[exporter][run.mapID][run.level] or {}
    M.InsertRun(db.runs[exporter][run.mapID][run.level], run)
    ClearDungeonPicks(db.pick, run.mapID, true) -- keepRio: the auto-pick is not a deliberate act
    db.pick[run.mapID .. ":" .. run.level] = { char = exporter, tier = run.chests }
    db.lastImported = { char = exporter, mapID = run.mapID, level = run.level }
    G:SweepRoutes() -- InsertRun may have rejected the run: don't keep an orphan route
    return run
end

--- Delete one stored run (Ghost Library row action). Clears a pick pointing at
--- exactly this run, prunes emptied tables so iteration stays clean, and GCs
--- Route Store entries the deletion orphaned. Returns true when something died.
function G:DeleteRun(charKey, mapID, level, tier)
    local db = KG.db
    local byMap = db.runs[charKey]
    local byLevel = byMap and byMap[mapID]
    local tiers = byLevel and byLevel[level]
    if not tiers or not tiers[tier] then return false end
    tiers[tier] = nil
    if not next(tiers) then byLevel[level] = nil end
    if byLevel and not next(byLevel) then byMap[mapID] = nil end
    if byMap and not next(byMap) then db.runs[charKey] = nil end
    local pk = mapID .. ":" .. level
    local p = db.pick[pk]
    if type(p) == "table" and p.char == charKey and (p.tier == nil or p.tier == tier) then
        db.pick[pk] = nil
    end
    if charKey == KG.RIO_CHAR then
        -- Deleting the Raider.IO row is cache eviction (it resurrects on next
        -- sight — honest cache semantics); its dungeon-wide pin must not dangle
        -- and silently resurrect a race with it.
        db.pick[mapID .. ":rio"] = nil
    end
    G:InvalidateRoster()
    G:SweepRoutes()
    return true
end

--- Toggle the Library pin for a run: pin = that exact run races when a matching
--- (dungeon, level) key starts (one pin per DUNGEON since the 2026-07-21 bug
--- report — pinning ANY other row of the dungeon moves the selection there, so
--- two rows can never sit lit together); unpin = back to the automatic chain.
--- Depleted runs CAN pin (Fredrik 2026-07-21, loosening the 2026-07-19 rule):
--- the automatic chain still never picks one, but an explicit pin is the
--- player's deliberate override — "beat my depleted attempt properly" is a
--- real race. Returns the new pinned state.
--- The Raider.IO row pins DUNGEON-WIDE (Fredrik 2026-07-21: "unless I pin it"):
--- one level-independent key, `mapID .. ":rio"` — the ghost races ANY key level
--- of that dungeon, even over own/imported ghosts. Deliberate pins sweep each
--- other in BOTH directions (the newer deliberate act wins); import auto-picks
--- do NOT touch the rio pin. A pre-fix DB may still hold several picks in one
--- dungeon — the first pin in that dungeon collapses them (self-healing).
function G:TogglePin(charKey, mapID, level, tier)
    local db = KG.db
    if charKey == KG.RIO_CHAR then
        local rk = mapID .. ":rio"
        if db.pick[rk] then
            db.pick[rk] = nil
            return false
        end
        ClearDungeonPicks(db.pick, mapID)
        db.pick[rk] = { char = charKey }
        return true
    end
    if not tier then return false end
    local pk = mapID .. ":" .. level
    local p = db.pick[pk]
    if type(p) == "table" and p.char == charKey and p.tier == tier then
        db.pick[pk] = nil
        return false
    end
    ClearDungeonPicks(db.pick, mapID) -- rio included: a deliberate normal pin outranks it
    db.pick[pk] = { char = charKey, tier = tier }
    return true
end

--- Decode + validate + store an export string. Returns the stored run (plus, third,
--- the exporter's addon version when it is newer than ours) or nil, err.
--- One paste box, two formats (3b, approved design): a KPG1 ghost code is sniffed
--- silently and lands through the same CleanRun gate + StoreImport pipeline —
--- the dialog copy stays neutral either way.
function G:ImportString(text)
    if type(text) == "string" and text:match("^%s*KPG1:") then
        return G:ImportKPG1(text)
    end
    local payload, err = KG.Codec.Decode(text)
    if not payload then return nil, err end
    local run, exporter, verr, kgv, route, shareTag = KG.Codec.ValidatePayload(payload)
    if not run then return nil, verr end
    local newer = KG.Codec.NewerVersion(kgv, KG.VERSION) and kgv or nil
    return G:StoreImport(run, exporter, route, shareTag), nil, newer
end

--- KPG1 ghost code → legacy-grade bosses-only ghost (Codec.DecodeKPG1 has the
--- format notes). Tier derives from the official par when the client can answer
--- (static map data — works anywhere); unknown par assumes timed +1 (people
--- share PBs). Same sanitation gate and storage as every import.
function G:ImportKPG1(text)
    local raw, exporter = KG.Codec.DecodeKPG1(text)
    if not raw then return nil, exporter or "unreadable KPG1 code" end
    local par = S:GetParTimeSec(raw.mapID)
    if par then
        raw.parTimeSec = par
        raw.chests = M.TierForDuration(raw.durationSec, par)
    else
        raw.chests = 1
    end
    local run = M.CleanRun(raw)
    if not run then return nil, "corrupt KPG1 code" end
    return G:StoreImport(run, exporter)
end

--- Export a TIMED run at (mapID, level) as a share string — by default the current
--- character's best; the Ghost Library shares any specific row via (charKey, tier).
--- nil, err when none — depleted runs never race, so they are never worth sharing
--- either (tier 0 is rejected). Re-sharing an import exports under YOUR name (the
--- exporter field is chain-of-custody); the run's own player/party context travels
--- unchanged.
--- The two share toggles (Fredrik 2026-07-20, the wrong-route pitfall — a stale DPS
--- selection can be captured): "route data" embeds the Route Store entry for
--- click-to-load; "route name" off strips name AND creator everywhere (anonymous
--- route). The stored run is never mutated — name-off exports a shallow copy.
function G:ExportString(mapID, level, charKey, tier)
    local tiers = select(1, RunsFor(charKey or KG.CharacterKey(), mapID, level, false))
    local run = tiers and ((tier and tier >= 1 and tiers[tier]) or M.BestRun(tiers, 1))
    if not run or not run.snapshots then return nil, "no timed ghost recorded for that dungeon/level" end
    if run.legacy == "RIO" then
        -- The one choke point every share door funnels through (Library button,
        -- shift-clicks, /kg export, Comm answers): a guild best is not yours to
        -- re-export under your name, and the cache re-serves it live anyway.
        return nil, "Raider.IO ghosts can't be shared"
    end
    local db = KG.db
    local shareName = db.shareRouteName ~= false
    local route = db.shareRouteData ~= false and run.routeHash
        and db.routes and db.routes[run.routeHash] or nil
    if not shareName then
        if route then
            local rc = {}
            for k, v in pairs(route) do rc[k] = v end
            rc.name, rc.createdBy = nil, nil
            route = rc
        end
        if run.routeName then
            local copy = {}
            for k, v in pairs(run) do copy[k] = v end
            copy.routeName = nil
            run = copy
        end
    end
    -- Party names are export-OPT-IN (default OFF — Fredrik 2026-07-20): the
    -- anonymized copy keeps class/role/spec/rating so receivers still see
    -- "RShaman 3433"-grade context via GhostMath.PartyMemberLabel. Stored data
    -- never mutated.
    if not db.sharePartyNames and run.party then
        local copy = {}
        for k, v in pairs(run) do copy[k] = v end
        copy.party = M.AnonymizeParty(run.party)
        run = copy
    end
    return KG.Codec.Export(KG.Codec.BuildPayload(run, KG.CharacterKey(), KG.VERSION, route,
        G:GetOrMintShareTag()))
end

--- Build the ghost reference for a live run: pinned ghost (Library pin / import
--- auto-pick) → dungeon-wide Raider.IO pin → own recorded run (exact level →
--- highest below → lowest above) → Raider.IO ghost (fresh convert → stored cache
--- → live mirror) → season best (linear) → par (linear). Every reference carries
--- `snapshots` so the bar and delta math treat all kinds uniformly. Depleted
--- (tier 0) runs are recorded but NEVER raced (Fredrik 2026-07-19) — the +1
--- sweeper is the deplete pressure. A pinned reference races PINNED
--- (`startPinned` — auto-Overtakes blocked until unpinned in-race), the Ghost
--- Library's "races when you run <dungeon> +<level>" contract. Precedence when
--- pins coexist: the map:level pick wins at its level (specific beats general),
--- the rio pin everywhere else.
function G:BuildReference(mapID, level)
    local pick = level and KG.db.pick[mapID .. ":" .. level]

    if type(pick) == "table" and pick.char then -- pinned ghost (a tier-0 PIN is legal:
        -- the Library's deliberate-override loosening, 2026-07-21 — only the
        -- automatic fallbacks below stay timed-only)
        if pick.char == KG.RIO_CHAR then -- unreachable by construction (rio pins
            -- live on the :rio key), but a hand-edited SavedVariables must not
            -- dress the Raider.IO ghost as an import
            local rioRef = G:BuildRioRef(mapID, true)
            if rioRef then return rioRef end
        end
        local byMap = KG.db.runs[pick.char]
        local tiers = byMap and byMap[mapID] and byMap[mapID][level]
        local run = tiers and ((pick.tier and tiers[pick.tier]) or M.BestRun(tiers, 1))
        if run and run.snapshots then
            if pick.char == KG.CharacterKey() and not run.importedFrom then
                return { -- a Library-pinned own run reads as yours, not as an import
                    kind = "personal", startPinned = true,
                    label = string.format("Your %s +%d (%s)", M.TierLabel(run.chests),
                        level, M.FormatClock(run.durationSec)),
                    run = run, durationSec = run.durationSec,
                    tier = run.chests, levelUsed = level,
                }
            end
            return { -- an import, or a pinned alt run (possessive label either way)
                kind = "import", startPinned = true,
                label = string.format("%s's %s +%d (%s)", ShortName(pick.char),
                    M.TierLabel(run.chests), level, M.FormatClock(run.durationSec)),
                run = run,
                durationSec = run.durationSec,
            }
        end
    end

    -- The dungeon-wide Raider.IO pin (Fredrik 2026-07-21): races ANY level of this
    -- dungeon, even over own ghosts — that is what pinning it MEANS. Falls through
    -- silently on total failure, same as a missing pinned run above.
    if KG.db.pick[mapID .. ":rio"] then
        local rioRef = G:BuildRioRef(mapID, true)
        if rioRef then return rioRef end
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

    local rio = G:BuildRioRef(mapID)
    if rio then return rio end

    local best = S:GetSeasonBestSec(mapID)
    if best then
        return {
            kind = "season",
            label = "Season best (" .. M.FormatClock(best) .. ")",
            run = { snapshots = M.LinearSnapshots(best), durationSec = best, total = 100 },
            durationSec = best,
        }
    end

    local par = S:GetParTimeSec(mapID)
    if par then
        return {
            kind = "par",
            label = "Par pace (" .. M.FormatClock(par) .. ")",
            run = { snapshots = M.LinearSnapshots(par), durationSec = par, total = 100 },
            durationSec = par,
        }
    end
    return nil
end

--- Reference wrapper for a Roster Ghost that takes over as the Raced Ghost (the
--- Raced-Ghost Switch — auto Overtake or a Roster Panel row click). Same shape and
--- label conventions as BuildReference, so every downstream consumer (bar, splits,
--- finish photo, knockback baseline) treats a switched-onto ghost identically.
function G:RefForRun(run)
    if not run or not run.snapshots then return nil end
    if run.legacy == "RIO" then
        -- Manual switch-to IS allowed (S12 kept 2026-07-21: autos never target the
        -- Raider.IO ghost, a deliberate row click races it) — and the ref must
        -- read as the replay, not as "Your +26" or an import.
        return { kind = "rio", label = RioLabel(run), run = run, durationSec = run.durationSec }
    end
    local lvl = run.level and (" +" .. run.level) or ""
    if run.importedFrom then
        return {
            kind = "import",
            label = string.format("%s's %s%s (%s)", ShortName(run.importedFrom),
                M.TierLabel(run.chests), lvl, M.FormatClock(run.durationSec or 0)),
            run = run, durationSec = run.durationSec,
        }
    end
    return {
        kind = "personal",
        label = string.format("Your %s%s (%s)", M.TierLabel(run.chests), lvl,
            M.FormatClock(run.durationSec or 0)),
        run = run, durationSec = run.durationSec,
    }
end

--- Fill the ghost roster to `KeystoneGhostDB.rosterSize` rows (default 3) in a
--- STABLE priority order that does NOT depend on which ghost is raced (Fredrik
--- 2026-07-20, Live Test 1: a switch or pin must never reorder the rows — the
--- highlight moves, the list stays; the raced ghost is simply one of the rows).
--- Priority chain (Fredrik 2026-07-19; 5 added 2026-07-21):
---   1. imported ghosts at this (dungeon, level)
---   2. this character's timed runs at this level
---   3. this character's timed runs one/two levels below, then above
---   4. other own characters' timed runs at this level, then ±1
---   5. the Raider.IO ghost — always last ("RaiderIO is always last prio",
---      Fredrik 2026-07-21), tier 0 included (the replay RaiderIO chose to track
---      is its own representation; never-race-depleted governs the OWN chain)
--- Depleted runs never race — not as fillers either (Fredrik 2026-07-19).
--- Within equal priority, runs recorded on `wantRoute` — YOUR selected MDT route
--- this key, which is stable for the whole run unlike the raced ghost — win the
--- tie (routeName tiebreak; the full route-aware priority tree stays an open
--- design question in DESIGN.md).
--- (The LIVE-MIRROR rio ref still can't be a roster row — no stored run; the
--- Roster Panel prepends it while raced. The converted ghost is a normal row.)
function G:BuildRoster(mapID, level, wantRoute)
    if not level then return {} end -- key level unreadable (secret flicker): no roster, no crash
    local target = KG.db.rosterSize or 3
    local out, seen = {}, {}
    local myKey = KG.CharacterKey()

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
        local tiers = charKey ~= KG.RIO_CHAR and byMap[mapID] and byMap[mapID][level]
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
        if charKey ~= myKey and charKey ~= KG.RIO_CHAR and #out < target then
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

    if #out < target then -- 5. the Raider.IO ghost, always last (tier 0 included)
        local rio = G:GetStoredRioRun(mapID)
        if rio then add(rio, "RIO") end
    end

    return out
end

--- Numbered idempotent schema migrations, run once per login (the error catcher
--- was rejected; the numbered-migration discipline stays).
--- db.schemaVersion is stamped after the highest step; installs from before the
--- field existed count as version 2 (the pct-float era).
-- Standing note for future steps: a run-shape migration must also handle
-- `db.liveRun` (the persisted in-progress recording) — nil-ing it is always
-- valid (one mid-update reload loses its resume; the seed tier catches it).
local MIGRATIONS = {
    {
        version = 3, -- count-space cutover (DESIGN "Count-space storage", 2026-07-20):
        -- pct-era runs (no run.total) are DROPPED, not converted — "we can trash old
        -- data… that's ok until we release". One honest chat line reports the toll.
        -- Also catches legacyAPL imports (percent-shaped by definition).
        run = function(db)
            local dropped = 0
            for _, byMap in pairs(db.runs) do
                for _, byLevel in pairs(byMap) do
                    for _, tiers in pairs(byLevel) do
                        for tier, run in pairs(tiers) do
                            if type(run) ~= "table" or not run.total then
                                tiers[tier] = nil
                                dropped = dropped + 1
                            end
                        end
                    end
                end
            end
            if dropped > 0 then
                print(string.format("|cff88ccffKeystoneGhost|r: dropped %d ghost(s) from the old"
                    .. " percent format — the count-space era starts fresh (re-record in play).", dropped))
            end
        end,
    },
}

function G:MigrateDB()
    local db = KG.db
    local current = db.schemaVersion or 2
    for _, step in ipairs(MIGRATIONS) do
        if current < step.version then
            step.run(db)
            current = step.version
        end
    end
    if db.schemaVersion ~= current then
        db.schemaVersion = current
        G:InvalidateRoster()
        G:SweepRoutes() -- dropped runs may have orphaned Route Store entries
    end
end

--- Identity-resolve a run table back to its storage address (chat-share needs
--- the (charKey, mapID, level, tier) export addressing; roster rows carry only
--- the run reference). Linear over a small library; nil for non-stored runs
--- (the live RaiderIO mirror, test ghosts).
function G:FindRunOwner(run)
    if type(run) ~= "table" then return nil end
    for charKey, byMap in pairs(KG.db.runs) do
        for mapID, byLevel in pairs(byMap) do
            for level, tiers in pairs(byLevel) do
                for tier, r in pairs(tiers) do
                    if r == run then return charKey, mapID, level, tier end
                end
            end
        end
    end
    return nil
end

--- Cached roster (the bar draws roster runners every frame; the underlying list only
--- changes on save/import/pick — NOT on a switch, which is the point of the stable
--- order). Invalidated explicitly.
local rosterCache = {}
function G:InvalidateRoster()
    rosterCache.key = nil
end

function G:GetRoster(mapID, level, wantRoute)
    local key = tostring(mapID) .. ":" .. tostring(level) .. ":" .. tostring(wantRoute)
    if rosterCache.key ~= key then
        rosterCache.key = key
        rosterCache.list = G:BuildRoster(mapID, level, wantRoute)
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
                    out[#out + 1] = string.format("%s +%d — %s (%s)",
                        name or ("map " .. mapID), level, M.TierLabel(tier),
                        M.FormatClock(run.durationSec or 0))
                end
            end
        end
    end
    table.sort(out)
    return out
end
