-- Optional MDT route context — cumulative forces per pull for the Pull Indicator
-- ("<Route> · Pull #N vs Ghost #M"). Ported from AutoPullLabeler's RouteMath (same
-- author/workspace):
-- MDT pull tables reference enemy clones; summing each included clone's `count` gives the
-- cumulative raw forces after every pull, in the same units as the scenario's raw count.
--
-- MDT stays an OPTIONAL dependency: everything here returns nil when MDT is absent, the
-- selected preset doesn't match the active dungeon, or any structure looks unexpected.
local ADDON_NAME, NS = ...
local KG = NS.KG

local Route = {}
KG.Route = Route

local function CumulativeForces(MDT, dungeonIdx, pulls, upToPull)
    local enemies = MDT.dungeonEnemies and MDT.dungeonEnemies[dungeonIdx]
    if not enemies then return 0 end
    local sum = 0
    for pullIdx = 1, math.min(upToPull, #pulls) do
        local pull = pulls[pullIdx]
        if type(pull) == "table" then
            for enemyIdx, clones in pairs(pull) do
                local ei = tonumber(enemyIdx)
                local enemy = ei and enemies[ei]
                if enemy and enemy.clones and type(clones) == "table" then
                    for _, cloneIdx in pairs(clones) do
                        if enemy.clones[cloneIdx] then
                            sum = sum + (enemy.count or 0)
                        end
                    end
                end
            end
        end
    end
    return sum
end

local function PullHasBoss(MDT, dungeonIdx, pull)
    local enemies = MDT.dungeonEnemies and MDT.dungeonEnemies[dungeonIdx]
    if not enemies or type(pull) ~= "table" then return false end
    for enemyIdx in pairs(pull) do
        local ei = tonumber(enemyIdx)
        local e = ei and enemies[ei]
        if e and e.isBoss then return true end
    end
    return false
end

local function DungeonIdxForChallengeMap(MDT, challengeMapID)
    for idx in pairs(MDT.dungeonList or {}) do
        local info = MDT.mapInfo and MDT.mapInfo[idx]
        if info and info.mapID == challengeMapID then return idx end
    end
    return nil
end

--- Route context for the active key, or nil. Called once at key start (recorder caches
--- the result — MDT table walks are not per-tick work).
---
-- ── Route capture: normalization, content hash, sanitizer ─────────────────────

local function Deflate()
    local stub = _G.LibStub
    return stub and stub.GetLibrary and stub:GetLibrary("LibDeflate", true) or nil
end

--- Normalized deep copy of an MDT pulls table: pull ORDER preserved (it IS the
--- route), enemy keys numeric, clone lists dense+sorted numbers (clone sets have no
--- order). The pull's color string survives — display data, deliberately NOT part
--- of the content hash (recoloring is not a route change).
local function CopyPulls(pulls)
    local out = {}
    for i = 1, #pulls do
        local src, dst = pulls[i], {}
        if type(src) == "table" then
            for k, v in pairs(src) do
                local ek = tonumber(k)
                if ek and type(v) == "table" then
                    local clones = {}
                    for _, c in pairs(v) do
                        local cn = tonumber(c)
                        if cn then clones[#clones + 1] = cn end
                    end
                    table.sort(clones)
                    dst[math.floor(ek)] = clones
                elseif k == "color" and type(v) == "string" then
                    dst.color = v:sub(1, 20)
                end
            end
        end
        out[i] = dst
    end
    return out
end

--- Content hash = the route's IDENTITY (Fredrik 2026-07-20: names stay stable while
--- pull planning mutates, so name equality proves nothing — in either direction).
--- Canonical walk (pull order, sorted enemy keys, sorted clones, structure ONLY)
--- then Adler32 via bundled LibDeflate — stable across clients whatever table
--- iteration order produced the input. Expects NORMALIZED pulls (CopyPulls /
--- CleanRouteData output). nil when LibDeflate is unavailable.
function Route.HashPulls(pulls)
    local LD = Deflate()
    if not LD or type(pulls) ~= "table" then return nil end
    local parts = {}
    for i = 1, #pulls do
        local pull = type(pulls[i]) == "table" and pulls[i] or {}
        local keys = {}
        for k, v in pairs(pull) do
            if type(k) == "number" and type(v) == "table" then keys[#keys + 1] = k end
        end
        table.sort(keys)
        parts[#parts + 1] = "|" .. i
        for _, ek in ipairs(keys) do
            local clones = {}
            for _, c in pairs(pull[ek]) do
                if type(c) == "number" then clones[#clones + 1] = c end
            end
            table.sort(clones)
            parts[#parts + 1] = ";" .. ek .. ":" .. table.concat(clones, ",")
        end
    end
    local ok, sum = pcall(LD.Adler32, LD, table.concat(parts))
    return ok and type(sum) == "number" and sum or nil
end

--- Field-by-field sanitizer for an imported route payload (CleanRun-grade: nothing
--- unknown survives to SavedVariables). The content hash is RECOMPUTED from the
--- sanitized pulls — a sender's claimed hash is never trusted. nil on bad shape.
function Route.CleanRouteData(raw)
    if type(raw) ~= "table" or type(raw.pulls) ~= "table" then return nil end
    local n = #raw.pulls
    if n < 1 or n > 500 then return nil end
    local pulls = {}
    for i = 1, n do
        local src = raw.pulls[i]
        if type(src) ~= "table" then return nil end
        local dst, enemies = {}, 0
        for k, v in pairs(src) do
            local ek = tonumber(k)
            if ek and type(v) == "table" then
                enemies = enemies + 1
                if enemies > 300 then return nil end
                local clones = {}
                for _, c in pairs(v) do
                    local cn = tonumber(c)
                    if cn then
                        clones[#clones + 1] = cn
                        if #clones > 500 then return nil end
                    end
                end
                table.sort(clones)
                dst[math.floor(ek)] = clones
            elseif k == "color" and type(v) == "string" then
                dst.color = v:sub(1, 20)
            end
        end
        pulls[i] = dst
    end
    local hash = Route.HashPulls(pulls)
    if not hash then return nil end

    local out = {
        pulls = pulls,
        hash = hash,
        nPulls = n,
        name = type(raw.name) == "string" and raw.name:sub(1, 60) or nil,
        uid = type(raw.uid) == "string" and raw.uid:sub(1, 40) or nil,
        dungeonIdx = tonumber(raw.dungeonIdx),
        sublevel = tonumber(raw.sublevel) or 1,
        week = tonumber(raw.week),
        difficulty = tonumber(raw.difficulty),
        -- storedAt = when the sender's Route Store entry was WRITTEN (run save /
        -- import), not when the content was frozen at key start. `capturedAt` is
        -- the pre-rename wire key (2026-07-20) — strings from 0.5.0 carry it.
        storedAt = tonumber(raw.storedAt) or tonumber(raw.capturedAt),
    }
    -- "cum" is the pre-rename payload key (2026-07-20, same night — no strings in
    -- the wild should carry it, but accepting it costs one `or`).
    local rawCumulative = raw.cumulativeForces or raw.cum
    if type(rawCumulative) == "table" and #rawCumulative == n then
        local cumulativeForces, last, valid = {}, -1, true
        for i = 1, n do
            local c = tonumber(rawCumulative[i])
            if not c or c < last then valid = false break end
            cumulativeForces[i] = c
            last = c
        end
        if valid then out.cumulativeForces = cumulativeForces end
    end
    if type(raw.bossPull) == "table" then
        local bp = {}
        for k, v in pairs(raw.bossPull) do
            local ki = tonumber(k)
            if ki and ki >= 1 and ki <= n and v then bp[math.floor(ki)] = true end
        end
        out.bossPull = bp
    end
    local cb = raw.createdBy
    if type(cb) == "table" and type(cb.name) == "string" then
        out.createdBy = {
            name = cb.name:sub(1, 48),
            realm = type(cb.realm) == "string" and cb.realm:sub(1, 48) or nil,
            classIdx = tonumber(cb.classIdx),
            classFile = type(cb.classFile) == "string" and cb.classFile:sub(1, 20):upper() or nil,
        }
    end
    return out
end

-- ── MDT resolution (6.2+, latest-only) ────────────────────────────────────────
--
-- LATEST-ONLY POLICY (Fredrik 2026-08-18): this build targets the current MDT
-- (MDT_BUILT_FOR below) and carries no backwards compatibility — nobody plays
-- on an old MDT; addons refresh with the client. When either side moves, one
-- chat line points at the likely fix (see MaybeWarnDrift); crash safety stays
-- (everything nil-guards), elaborate error messaging deliberately doesn't.
--
-- MDT 6.2 split in two and made the addon table file-local: no global carries
-- the data tables, the public MythicDungeonToolsAPI cannot price pulls (its
-- GetEnemyForces takes an npc id that only the private enemy table could
-- resolve, and pulls reference enemies by index), and the route database only
-- exists once the LoadOnDemand UI half has loaded. So the resolver assembles
-- an MDT-shaped table from pieces that are demand-loaded at the route read and
-- never touched while idle:
--
--   dungeonEnemies/dungeonList/mapInfo — the KeystoneGhost_MDTData module
--     (LoadOnDemand, `Dependencies: MythicDungeonTools`), whose .toc loads
--     MDT's own static dungeon files from the user's install into its
--     namespace — the same cross-folder include MDT's UI half is built on.
--     Nothing is bundled and nothing can go stale against the installed MDT.
--     Its Dependencies line makes our single LoadAddOn call double as the
--     "MDT installed and enabled" check.
--   GetDB — MythicDungeonToolsDB.global (the UI half's SavedVariables) after
--     C_AddOns.LoadAddOn("MythicDungeonTools_UI"). The public API:GetDB() is
--     kept as a fallback only: it returns a pre-UI bootstrap table that goes
--     stale the moment the real database initializes (the NextPullTracker
--     addon documents the same behaviour).
--
-- LoadAddOn is synchronous — when it returns true, the loaded addon's tables
-- exist — so there is no event to wait on and nothing polls. Everything here
-- is read-only and pcall-guarded; every failure returns nil, which callers
-- already treat as "MDT absent": the degradation this module always promised.

local modernMDT -- session cache, set only on a fully successful resolve

--- The MDT version this build is written and verified against. Bump it as part
--- of re-verifying the touchpoints after an MDT minor/major update (AGENTS.md
--- "External addon interfaces"). Patch drift is deliberately silent: MDT
--- patches are data fixes, and our data reads their live files, so it cannot
--- go stale.
local MDT_BUILT_FOR = "6.2.4"

--- Pure comparator (offline-tested): "older" | "newer" when MAJOR.MINOR
--- differs, nil when in sync or unparseable.
function Route.MDTVersionDrift(installed, builtFor)
    local iM, im = tostring(installed or ""):match("^v?(%d+)%.(%d+)")
    local bM, bm = tostring(builtFor or ""):match("^v?(%d+)%.(%d+)")
    if not (iM and bM) then return nil end
    iM, im, bM, bm = tonumber(iM), tonumber(im), tonumber(bM), tonumber(bm)
    if iM == bM and im == bm then return nil end
    if iM < bM or (iM == bM and im < bm) then return "older" end
    return "newer"
end

-- One line, once per session, only when a route feature actually engages —
-- and BEFORE the data load, so a future MDT that moves its folders (empty
-- tables, silent nil) still gets its drift explained.
local warnedDrift
local function MaybeWarnDrift()
    if warnedDrift then return end
    warnedDrift = true
    local C = rawget(_G, "C_AddOns")
    if not (type(C) == "table" and type(C.GetAddOnMetadata) == "function") then return end
    -- Only for an ENABLED MDT. Metadata reads fine for disabled addons, and
    -- telling someone who turned MDT off to update it is advice about a
    -- feature they opted out of (council catch, 2026-08-18). Disabled stays
    -- silent, like everything else on the nil path.
    if type(C.GetAddOnEnableState) == "function" then
        local okE, state = pcall(C.GetAddOnEnableState, "MythicDungeonTools")
        if okE and state == 0 then return end
    end
    local ok, ver = pcall(C.GetAddOnMetadata, "MythicDungeonTools", "Version")
    local drift = ok and Route.MDTVersionDrift(ver, MDT_BUILT_FOR) or nil
    if drift == "older" then
        print(("|cff88ccffKeystoneGhost|r: your MDT (%s) is older than this build expects (%s). Update MDT if route features misbehave."):format(ver, MDT_BUILT_FOR))
    elseif drift == "newer" then
        print(("|cff88ccffKeystoneGhost|r: your MDT (%s) is newer than this build knows (%s). If route features misbehave, check for a Keystone Ghost update."):format(ver, MDT_BUILT_FOR))
    end
end

local function DemandLoad(name)
    local C = rawget(_G, "C_AddOns")
    if type(C) ~= "table" or type(C.LoadAddOn) ~= "function" then return false end
    local ok, loaded = pcall(C.LoadAddOn, name)
    return ok and loaded == true
end

local function ModernRouteDB()
    local sv = rawget(_G, "MythicDungeonToolsDB")
    if type(sv) == "table" and type(sv.global) == "table" then return sv.global end
    local api = rawget(_G, "MythicDungeonToolsAPI")
    if type(api) == "table" and type(api.GetDB) == "function" then
        local ok, db = pcall(api.GetDB, api)
        if ok and type(db) == "table" then return db end
    end
    return nil
end

--- The table every MDT reader below consumes, or nil. Safe to call repeatedly;
--- only the first successful resolve does any loading. In combat it returns
--- nil rather than demand-loading (the next read retries — route reads happen
--- at walk-in/key start, out of combat).
function Route.ResolveMDT()
    if modernMDT then return modernMDT end
    local icl = rawget(_G, "InCombatLockdown")
    if type(icl) == "function" and icl() then return nil end
    MaybeWarnDrift()
    if not DemandLoad("KeystoneGhost_MDTData") then return nil end
    local data = rawget(_G, "KeystoneGhost_MDTData")
    if type(data) ~= "table" or type(data.dungeonEnemies) ~= "table"
        or next(data.dungeonEnemies) == nil then
        -- Module loaded but empty: MDT rotated its per-expansion data folder
        -- (see the module's maintenance note). Treated as MDT-absent.
        return nil
    end
    DemandLoad("MythicDungeonTools_UI") -- best effort; ModernRouteDB has its own fallback
    modernMDT = {
        dungeonEnemies = data.dungeonEnemies,
        dungeonList = data.dungeonList,
        mapInfo = data.mapInfo,
        GetDB = ModernRouteDB,
    }
    return modernMDT
end

--- Test hook (and belt for a mid-session MDT install): forget the composite so
--- the next ResolveMDT rebuilds it.
function Route._ResetResolvedMDT()
    modernMDT = nil
end

--- Zero-interaction route pick (Fredrik, 2026-07-19): the preset last SELECTED in
--- MDT's dropdown for the ACTIVE dungeon. MDT remembers that selection per dungeon
--- (db.currentPreset[dungeonIdx] = index into db.presets[dungeonIdx]), so this works
--- even when MDT's window sits on a different dungeon — no link button, no prompt
--- (APL's link-a-route button is the design this replaces). This also fixes a shape
--- bug: currentPreset[dIdx] is a numeric INDEX, not the preset table — the old code
--- indexed the number and hard-errored inside OnKeyStart whenever MDT was open on
--- the matching dungeon (why the pull indicator was never seen live).
---
--- Since 2026-07-20 the return also carries the FULL capture for the Route Store
--- (deep-copied pulls + content hash + createdBy + rebuild metadata) — taken at KEY
--- START, the only moment the data is provably this run's route (presets mutate in
--- place under stable names). Capture failing never breaks the Pull Indicator.
--- Returns nil, or a table: cumulativeForces, bossPull, nPulls, name — plus, when
--- capture succeeded: hash, pulls, createdBy, uid, dungeonIdx, sublevel, week,
--- difficulty.
function Route:GetForChallengeMap(challengeMapID)
    local MDT = Route.ResolveMDT()
    if not MDT or type(MDT.GetDB) ~= "function" or not challengeMapID then return nil end
    local ok, mdtDb = pcall(MDT.GetDB, MDT)
    if not ok or type(mdtDb) ~= "table" then return nil end

    local dIdx = DungeonIdxForChallengeMap(MDT, challengeMapID)
    if not dIdx then return nil end

    local presetIdx = type(mdtDb.currentPreset) == "table" and tonumber(mdtDb.currentPreset[dIdx]) or nil
    local byDungeon = type(mdtDb.presets) == "table" and mdtDb.presets[dIdx] or nil
    local preset = presetIdx and type(byDungeon) == "table" and byDungeon[presetIdx] or nil
    if type(preset) ~= "table" then return nil end
    local value = type(preset.value) == "table" and preset.value or nil
    local pulls = value and value.pulls or nil
    if type(pulls) ~= "table" or #pulls == 0 then return nil end
    -- A preset names the dungeon it was drawn for, and that name outranks the list it
    -- sits in: a preset filed under the wrong dungeon (import from another MDT
    -- version, a preset list that drifted) must never become this key's route.
    local presetDungeon = value and tonumber(value.currentDungeonIdx)
    if presetDungeon and presetDungeon ~= dIdx then return nil end

    local cumulativeForces, bossPull = {}, {}
    local okAll = pcall(function()
        for i = 1, #pulls do
            cumulativeForces[i] = CumulativeForces(MDT, dIdx, pulls, i)
            if PullHasBoss(MDT, dIdx, pulls[i]) then bossPull[i] = true end
        end
    end)
    if not okAll or #cumulativeForces == 0 then return nil end
    -- "No route" never reaches us as an absence: MDT hands every dungeon you have
    -- ever OPENED a Default preset and guarantees it holds at least one pull, empty
    -- or not (UpdateToDungeon). A preset with no enemies in it has nothing to track,
    -- so it is not a route — without this the Pull Indicator raced a zero-forces
    -- table and every pull read as already done.
    if (cumulativeForces[#cumulativeForces] or 0) <= 0 then return nil end

    local name = preset.text
    local out = {
        cumulativeForces = cumulativeForces,
        bossPull = bossPull,
        nPulls = #pulls,
        name = type(name) == "string" and name:sub(1, 60) or nil,
    }

    pcall(function()
        out.pulls = CopyPulls(pulls)
        out.hash = Route.HashPulls(out.pulls)
        out.uid = type(preset.uid) == "string" and preset.uid:sub(1, 40) or nil
        out.dungeonIdx = dIdx
        out.sublevel = tonumber(preset.value.currentSublevel) or 1
        out.week = tonumber(preset.value.week)
        out.difficulty = tonumber(preset.value.difficulty)
        local cb = preset.createdBy or preset.value.createdBy
        if type(cb) == "table" and type(cb.name) == "string" then
            -- classFile stays nil on capture since MDT 6.2 (GetClassFileByIndex
            -- was legacy-global API; latest-only policy dropped that era).
            -- CleanRouteData still accepts classFile from older wire strings.
            out.createdBy = {
                name = cb.name:sub(1, 48),
                realm = type(cb.realm) == "string" and cb.realm:sub(1, 48) or nil,
                classIdx = tonumber(cb.classIdx),
            }
        end
    end)
    if not out.hash then out.pulls = nil end -- store nothing unidentifiable

    return out
end

-- ── Click-to-load: the ghost's route as an MDT import string ──────────────────

--- Rebuild an importable MDT preset from a Route Store entry — the table the
--- import string serializes, in the exact shape MDT's import validation
--- expects. Pulls are deep-copied AGAIN — MDT stores imported presets by
--- reference and mutates them on edit; our Route Store must never be MDT's
--- working copy.
function Route.BuildMDTPreset(rd)
    return {
        text = rd.name or "KeystoneGhost route",
        uid = rd.uid,
        createdBy = rd.createdBy and rd.createdBy.name and {
            name = rd.createdBy.name,
            realm = rd.createdBy.realm,
            classIdx = rd.createdBy.classIdx,
        } or nil,
        value = {
            currentDungeonIdx = rd.dungeonIdx,
            currentPull = 1,
            currentSublevel = rd.sublevel or 1,
            week = rd.week,
            difficulty = rd.difficulty,
            pulls = CopyPulls(rd.pulls),
        },
    }
end

--- The stored route as an MDT IMPORT STRING — THE delivery door: the exact
--- format MDT's "Import Preset" dialog reads, `"!~MDT2~" .. base64(deflate(
--- cbor))` (their Modules/Transmission.lua), built entirely from the native
--- 12.x C_EncodingUtil client API — nothing bundled, nothing of MDT's
--- touched, and the user's paste into MDT's own dialog is the consent.
--- Needs nothing from MDT to build, so it works with MDT absent too (the
--- string can be forwarded). @return str | nil, err
function Route.BuildMDTImportString(rd)
    if type(rd) ~= "table" or type(rd.pulls) ~= "table" then
        return nil, "no route data on this ghost"
    end
    local CE = rawget(_G, "C_EncodingUtil")
    local enum = rawget(_G, "Enum")
    local method = type(enum) == "table" and type(enum.CompressionMethod) == "table"
        and enum.CompressionMethod.Deflate or nil
    if not (type(CE) == "table" and CE.SerializeCBOR and CE.CompressString
        and CE.EncodeBase64 and method ~= nil) then
        return nil, "this client can't encode MDT strings"
    end
    local ok, str = pcall(function()
        local serialized = CE.SerializeCBOR(Route.BuildMDTPreset(rd))
        local compressed = CE.CompressString(serialized, method)
        return "!~MDT2~" .. CE.EncodeBase64(compressed)
    end)
    if not ok or type(str) ~= "string" or str == "" then
        return nil, "encoding failed"
    end
    return str
end

-- (The legacy one-click import chain — ValidateImportPreset → ImportPreset on
-- `_G.MDT` — was removed 2026-08-18 with the latest-only policy: no user keeps
-- an old MDT. Git history has the implementation if it is ever wanted back.)
