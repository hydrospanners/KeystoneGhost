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
    local MDT = _G.MDT
    if not MDT or type(MDT.GetDB) ~= "function" or not challengeMapID then return nil end
    local ok, mdtDb = pcall(MDT.GetDB, MDT)
    if not ok or type(mdtDb) ~= "table" then return nil end

    local dIdx = DungeonIdxForChallengeMap(MDT, challengeMapID)
    if not dIdx then return nil end

    local presetIdx = type(mdtDb.currentPreset) == "table" and tonumber(mdtDb.currentPreset[dIdx]) or nil
    local byDungeon = type(mdtDb.presets) == "table" and mdtDb.presets[dIdx] or nil
    local preset = presetIdx and type(byDungeon) == "table" and byDungeon[presetIdx] or nil
    if type(preset) ~= "table" then return nil end
    local pulls = type(preset.value) == "table" and preset.value.pulls or nil
    if type(pulls) ~= "table" or #pulls == 0 then return nil end

    local cumulativeForces, bossPull = {}, {}
    local okAll = pcall(function()
        for i = 1, #pulls do
            cumulativeForces[i] = CumulativeForces(MDT, dIdx, pulls, i)
            if PullHasBoss(MDT, dIdx, pulls[i]) then bossPull[i] = true end
        end
    end)
    if not okAll or #cumulativeForces == 0 then return nil end

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
            local classFile
            if type(MDT.GetClassFileByIndex) == "function" then
                local okC, cf = pcall(MDT.GetClassFileByIndex, MDT, cb.classIdx)
                classFile = (okC and type(cf) == "string") and cf or nil
            end
            out.createdBy = {
                name = cb.name:sub(1, 48),
                realm = type(cb.realm) == "string" and cb.realm:sub(1, 48) or nil,
                classIdx = tonumber(cb.classIdx),
                classFile = classFile, -- resolved NOW so receivers color it without MDT
            }
        end
    end)
    if not out.hash then out.pulls = nil end -- store nothing unidentifiable

    return out
end

-- ── Click-to-load: hand a stored route back to MDT ────────────────────────────

--- Rebuild an importable MDT preset from a Route Store entry. Pulls are deep-copied
--- AGAIN — MDT stores imported presets by reference and mutates them on edit; our
--- Route Store must never be MDT's working copy.
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

--- Load a Route Store entry into MDT — the exact chain MDT's own live-session
--- receive uses (Modules/Transmission.lua): ValidateImportPreset → ImportPreset;
--- ShowInterface first so the import is visible immediately (ImportPreset self-
--- defers until MDT's frames exist). Everything pcall-guarded: MDT stays an
--- optional dependency. @return ok, err
function Route:LoadIntoMDT(rd)
    local MDT = _G.MDT
    if type(MDT) ~= "table" then return false, "MDT is not loaded" end
    if type(rd) ~= "table" or type(rd.pulls) ~= "table" then return false, "no route data on this ghost" end
    if type(MDT.ValidateImportPreset) ~= "function" or type(MDT.ImportPreset) ~= "function" then
        return false, "this MDT version has no import API"
    end
    local preset = Route.BuildMDTPreset(rd)
    local okV, valid = pcall(MDT.ValidateImportPreset, MDT, preset)
    if not okV or not valid then
        return false, "MDT rejected the route (recorded on a different MDT version?)"
    end
    if type(MDT.ShowInterface) == "function" then pcall(MDT.ShowInterface, MDT, true) end
    local okI = pcall(MDT.ImportPreset, MDT, preset, false)
    if not okI then return false, "MDT import errored" end
    return true
end
