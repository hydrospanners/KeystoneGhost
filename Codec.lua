-- Export/import strings — WeakAuras-style: serialize → deflate → printable encoding,
-- prefixed "!KG1". The payload carries the full run (count-space timeline, boss kills
-- with names and counts, route data) plus exporter identity, so an imported ghost
-- races with the same fidelity as a locally recorded one.
--
-- Format generation v=2 (the count-space cutover, DESIGN "Count-space storage +
-- !KG2 codec"): the heavy per-sample arrays travel as zigzag-varint delta STREAMS
-- (byte-string fields inside the LibSerialize payload) — quantize → delta → zigzag
-- varint, deflate unchanged behind. The snapshot boss column is not stored; it is
-- derived from bossKills at decode. "!KG2" names the format GENERATION — the outer
-- prefix stays !KG1 (reserved for a ground-up redesign per the versioning policy).
--
-- Uses bundled LibSerialize + LibDeflate via LibStub. Every imported run passes through
-- GhostMath.CleanRun before touching SavedVariables — unknown fields never survive.
local ADDON_NAME, NS = ...
local KG = NS.KG
local M = KG.Math

local Codec = {}
KG.Codec = Codec

local PREFIX = "!KG1"

-- The import gate (DESIGN "Wire format: versioning policy"): payload format
-- GENERATIONS this build decodes. Additive fields never add an entry; breaking
-- changes add the new generation (and may keep the old through a grace window).
-- Dropping a generation is a two-step deliberate act: delete its entry here AND
-- its golden fixture in tests/test_codec.lua — the suite fails until both move.
-- v1 (pct-float snapshots) was DROPPED pre-release with the count-space cutover
-- (Fredrik: "we can trash old data… that's ok until we release").
Codec.SUPPORTED_FORMATS = { [2] = true }

local function MaxSupportedFormat()
    local max = 0
    for v in pairs(Codec.SUPPORTED_FORMATS) do
        if v > max then max = v end
    end
    return max
end

-- ── Stream packing primitives (lifted from tests/test_v3pack.lua, which now tests
-- THIS copy). Lua 5.1-clean: no //, no math.type — the in-game client is 5.1-era.
--  * unsigned LEB128 varint: 7 bits per byte, high bit = continuation.
--  * zigzag maps signed→unsigned (0,-1,1,-2,2 → 0,1,2,3,4): REQUIRED because the
--    official-timer re-anchor can step t BACK ~1.5 s and the forces guard tolerates
--    ≤1% count dips — monotonicity is almost-true, never assumed.
--  * values are whole numbers (whole-second t, integer count); a defensive round
--    happens at pack time so a stray float can never corrupt a stream.
local PACK = {}
Codec.Pack = PACK

function PACK.zigzag(v)
    if v >= 0 then return v * 2 end
    return -v * 2 - 1
end

function PACK.unzigzag(v)
    if v % 2 == 0 then return v / 2 end
    return -((v + 1) / 2)
end

--- Append unsigned varint `v` to the table of byte-chars `out`.
function PACK.putVarint(out, v)
    assert(v >= 0, "varint is unsigned — zigzag first")
    repeat
        local b = v % 128
        v = math.floor(v / 128)
        if v > 0 then b = b + 128 end
        out[#out + 1] = string.char(b)
    until v == 0
end

--- Read one unsigned varint from byte-string `s` at `pos` → value, nextPos.
function PACK.getVarint(s, pos)
    local v, mult, b = 0, 1, nil
    repeat
        b = s:byte(pos)
        if not b then return nil end -- truncated stream: caller rejects
        pos = pos + 1
        v = v + (b % 128) * mult
        mult = mult * 128
    until b < 128
    return v, pos
end

local function round(x) return math.floor((x or 0) + 0.5) end

--- Snapshots {{t, count, bosses}, ...} → byte string of (dT,dCount) pairs.
--- The boss column is intentionally dropped (derived on decode).
function PACK.packSnapshots(snaps)
    local out = {}
    PACK.putVarint(out, #snaps)
    local pt, pc = 0, 0
    for i = 1, #snaps do
        local t, c = round(snaps[i][1]), round(snaps[i][2])
        PACK.putVarint(out, PACK.zigzag(t - pt))
        PACK.putVarint(out, PACK.zigzag(c - pc))
        pt, pc = t, c
    end
    return table.concat(out)
end

--- Byte string + bossKills → snapshots {{t, count, bosses}, ...} or nil,err.
function PACK.unpackSnapshots(str, bossKills)
    local n, pos = PACK.getVarint(str, 1)
    if not n then return nil, "truncated" end
    local snaps, t, c, d = {}, 0, 0, nil
    for i = 1, n do
        d, pos = PACK.getVarint(str, pos)
        if not d then return nil, "truncated" end
        t = t + PACK.unzigzag(d)
        d, pos = PACK.getVarint(str, pos)
        if not d then return nil, "truncated" end
        c = c + PACK.unzigzag(d)
        local k = 0
        if bossKills then
            for j = 1, #bossKills do
                if bossKills[j] <= t then k = k + 1 end
            end
        end
        snaps[i] = { t, c, k }
    end
    return snaps
end

--- Plain numeric list → zigzag-delta varint byte string (nil for empty/nil).
function PACK.packList(list)
    if not list or #list == 0 then return nil end
    local out, prev = {}, 0
    PACK.putVarint(out, #list)
    for i = 1, #list do
        local v = round(list[i])
        PACK.putVarint(out, PACK.zigzag(v - prev))
        prev = v
    end
    return table.concat(out)
end

function PACK.unpackList(str)
    if not str then return nil end
    local n, pos = PACK.getVarint(str, 1)
    if not n then return nil, "truncated" end
    local list, prev, d = {}, 0, nil
    for i = 1, n do
        d, pos = PACK.getVarint(str, pos)
        if not d then return nil, "truncated" end
        prev = prev + PACK.unzigzag(d)
        list[i] = prev
    end
    return list
end

--- Deaths {{t, runningCount}, ...} → byte string (nil for empty/nil).
function PACK.packDeaths(deaths)
    if not deaths or #deaths == 0 then return nil end
    local out, pt, pn = {}, 0, 0
    PACK.putVarint(out, #deaths)
    for i = 1, #deaths do
        local t, n = round(deaths[i][1]), round(deaths[i][2])
        PACK.putVarint(out, PACK.zigzag(t - pt))
        PACK.putVarint(out, PACK.zigzag(n - pn))
        pt, pn = t, n
    end
    return table.concat(out)
end

function PACK.unpackDeaths(str)
    if not str then return nil end
    local n, pos = PACK.getVarint(str, 1)
    if not n then return nil, "truncated" end
    local deaths, t, c, d = {}, 0, 0, nil
    for i = 1, n do
        d, pos = PACK.getVarint(str, pos)
        if not d then return nil, "truncated" end
        t = t + PACK.unzigzag(d)
        d, pos = PACK.getVarint(str, pos)
        if not d then return nil, "truncated" end
        c = c + PACK.unzigzag(d)
        deaths[i] = { t, c }
    end
    return deaths
end

-- ── Wire-run shaping ───────────────────────────────────────────────────────────

-- Arrays that travel as streams instead of plain tables. Sparse tables
-- (bossEngages, pullTimes) and string arrays (bossNames) stay plain — LibSerialize
-- handles them fine and streams can't carry holes.
local STREAMED = { snapshots = true, bossKills = true, bossCounts = true, deaths = true }

--- Run table → wire shape: scalar fields as-is, heavy arrays as packed streams.
local function PackRun(run)
    local out = {}
    for k, v in pairs(run) do
        if not STREAMED[k] then out[k] = v end
    end
    out.snapshotStream = PACK.packSnapshots(run.snapshots or {})
    out.bossKillStream = PACK.packList(run.bossKills)
    out.bossCountStream = PACK.packList(run.bossCounts)
    out.deathStream = PACK.packDeaths(run.deaths)
    return out
end

--- Wire shape → run table (streams unpacked; boss column derived from bossKills).
--- nil when any present stream is corrupt — a truncated timeline never half-imports.
local function UnpackRun(w)
    if type(w) ~= "table" then return nil end
    local out = {}
    for k, v in pairs(w) do
        if k ~= "snapshotStream" and k ~= "bossKillStream"
            and k ~= "bossCountStream" and k ~= "deathStream" then
            out[k] = v
        end
    end
    if w.bossKillStream ~= nil then
        if type(w.bossKillStream) ~= "string" then return nil end
        out.bossKills = PACK.unpackList(w.bossKillStream)
        if not out.bossKills then return nil end
    end
    if type(w.snapshotStream) ~= "string" then return nil end
    out.snapshots = PACK.unpackSnapshots(w.snapshotStream, out.bossKills)
    if not out.snapshots then return nil end
    if w.bossCountStream ~= nil then
        if type(w.bossCountStream) ~= "string" then return nil end
        out.bossCounts = PACK.unpackList(w.bossCountStream)
        if not out.bossCounts then return nil end
    end
    if w.deathStream ~= nil then
        if type(w.deathStream) ~= "string" then return nil end
        out.deaths = PACK.unpackDeaths(w.deathStream)
        if not out.deaths then return nil end
    end
    return out
end

--- Share Tag sanitation (DESIGN "The Share Tag"): `KG-` + hex, cap 24 chars —
--- anything else silently drops. Pseudonymous account grouping, never identity.
local function CleanShareTag(v)
    if type(v) == "string" and #v <= 24 and v:match("^KG%-%x+$") then return v end
    return nil
end
Codec.CleanShareTag = CleanShareTag

-- ── Encode / decode ────────────────────────────────────────────────────────────

local function Libs()
    local stub = _G.LibStub
    if not stub then return nil end
    return stub:GetLibrary("LibSerialize", true), stub:GetLibrary("LibDeflate", true)
end

--- @return string|nil, string|nil errorMessage
function Codec.Export(payload)
    local LS, LD = Libs()
    if not LS or not LD then return nil, "LibSerialize/LibDeflate unavailable" end
    local ok, serialized = pcall(LS.Serialize, LS, payload)
    if not ok then return nil, "serialize failed" end
    local compressed = LD:CompressDeflate(serialized, { level = 9 })
    return PREFIX .. LD:EncodeForPrint(compressed)
end

--- @return table|nil payload, string|nil errorMessage
function Codec.Decode(str)
    local LS, LD = Libs()
    if not LS or not LD then return nil, "LibSerialize/LibDeflate unavailable" end
    if type(str) ~= "string" then return nil, "not a string" end
    str = str:gsub("%s+", "")
    if str:sub(1, #PREFIX) ~= PREFIX then return nil, "not a KeystoneGhost export string" end
    local decoded = LD:DecodeForPrint(str:sub(#PREFIX + 1))
    if not decoded then return nil, "corrupt encoding" end
    local decompressed = LD:DecompressDeflate(decoded)
    if not decompressed then return nil, "corrupt compression" end
    local ok, payload = LS:Deserialize(decompressed)
    if not ok or type(payload) ~= "table" then return nil, "corrupt payload" end
    return payload
end

--- Build the export payload for one run. `version` (KG.VERSION) rides along so an
--- importer can tell the string came from a newer KeystoneGhost than its own —
--- version skew only matters when strings cross clients (Fredrik 2026-07-20; the
--- addon-comms version gossip was rejected as not worth the plumbing). `route`
--- (optional) is the run's Route Store entry; `shareTag` the exporter's account
--- marker (envelope-level identity metadata, beside exporter/kgv).
function Codec.BuildPayload(run, exporter, version, route, shareTag)
    local S = KG.Scenario
    return {
        v = 2,
        kgv = version,
        exporter = exporter,
        exportedAt = (S and S.ServerNow and S:ServerNow()) or (time and time() or 0),
        shareTag = shareTag,
        run = PackRun(run),
        route = route,
    }
end

--- Validate a decoded payload → clean run, exporter name, nil, exporter's addon
--- version, sanitized route data (nil when absent or malformed — a bad route never
--- sinks the ghost import), sanitized shareTag — or nil, nil, error.
function Codec.ValidatePayload(payload)
    if type(payload) ~= "table" then return nil, nil, "unsupported version" end
    local v = tonumber(payload.v)
    if not v or not Codec.SUPPORTED_FORMATS[v] then
        if v and v > MaxSupportedFormat() then
            return nil, nil, string.format(
                "made by a newer KeystoneGhost (format v%d; this version reads up to v%d) — update to import it",
                v, MaxSupportedFormat())
        end
        return nil, nil, string.format(
            "unsupported format (%s) — ask the sender to re-export with a current KeystoneGhost",
            tostring(payload.v))
    end
    local exporter = type(payload.exporter) == "string" and payload.exporter:sub(1, 60) or "Unknown"
    local kgv = type(payload.kgv) == "string" and payload.kgv:sub(1, 20) or nil
    local run = M.CleanRun(UnpackRun(payload.run))
    if not run then return nil, nil, "invalid run data" end
    if not run.mapID or not run.level then return nil, nil, "missing dungeon/level" end
    local route = payload.route and KG.Route and KG.Route.CleanRouteData
        and KG.Route.CleanRouteData(payload.route) or nil
    return run, exporter, nil, kgv, route, CleanShareTag(payload.shareTag)
end

--- True when dotted-numeric version `a` is newer than `b`. Anything unparseable is
--- never newer — "dev" builds and legacy strings stay quiet.
function Codec.NewerVersion(a, b)
    if type(a) ~= "string" or type(b) ~= "string" then return false end
    local function parts(s)
        local out = {}
        for n in s:gmatch("%d+") do out[#out + 1] = tonumber(n) end
        return out
    end
    local pa, pb = parts(a), parts(b)
    if #pa == 0 or #pb == 0 then return false end
    for i = 1, math.max(#pa, #pb) do
        local x, y = pa[i] or 0, pb[i] or 0
        if x ~= y then return x > y end
    end
    return false
end

-- ── KPG1 ghost codes (competing addon's share format — silent import door) ────
--
-- Approved 3b scope (DESIGN "Sharing"): the import dialog stays neutral and this
-- path never announces a brand in-game; the CurseForge description carries any
-- credit line (its wording rides the TASKS #8 outcome). Format, as observable
-- from shared code strings: "KPG1:" + plain Base64 (no compression, no checksum;
-- their decoder strips non-base64 characters, so ours does too), payload
-- `~`-joined: mapID ~ level ~ pb ~ dungeonName ~ label ~ cpBlob, where pb is
-- "%.1f" official (penalty-inclusive) seconds, label is the exporter's character
-- name, and cpBlob is `^`-joined "bossName#time" checkpoints in kill order on a
-- penalty-FREE clock (approximate vs our official clock on deathful runs).
-- No encounterIDs, no forces, no deaths travel — so the import is an honest
-- BOSSES-ONLY ghost: the snapshot count column is SATURATED (= total) from t=0,
-- which makes the forces constraint degenerate to always-satisfied in
-- GhostTimeFor — the boss constraint alone drives the race (the exact mirror of
-- legacyAPL's forces-only). Their format validates nothing; we validate
-- everything (structure here, caps/monotonicity again in CleanRun — the gate).

local B64 = {}
do
    local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    for i = 1, 64 do B64[alphabet:sub(i, i)] = i - 1 end
end

--- Plain Base64 → byte string; non-alphabet characters are stripped first
--- (mirror of the emitting addon's own tolerance). nil on empty/impossible input.
local function DecodeBase64(s)
    if type(s) ~= "string" then return nil end
    local clean = s:gsub("[^A-Za-z0-9+/]", "")
    if #clean < 2 then return nil end
    local out, acc, bits = {}, 0, 0
    for i = 1, #clean do
        acc = acc * 64 + B64[clean:sub(i, i)]
        bits = bits + 6
        if bits >= 8 then
            bits = bits - 8
            local byte = math.floor(acc / (2 ^ bits))
            acc = acc - byte * (2 ^ bits)
            out[#out + 1] = string.char(byte)
        end
    end
    return table.concat(out)
end

--- Decode a KPG1 ghost code → CleanRun-ready raw run table + exporter name, or
--- nil, err. Pure (offline-tested); the caller resolves tier/par and runs the
--- CleanRun gate. The returned run carries `legacy = "KPG1"` so displays can
--- badge the grade (boss times only, approximate on deaths).
function Codec.DecodeKPG1(text)
    if type(text) ~= "string" then return nil, "not a string" end
    local body = text:match("^%s*KPG1:%s*(.+)$")
    if not body then return nil, "not a KPG1 code" end
    local payload = DecodeBase64(body)
    if not payload or #payload < 8 then return nil, "unreadable KPG1 code" end

    local mapID, level, pb, _dungeonName, label, cpBlob =
        payload:match("^([^~]*)~([^~]*)~([^~]*)~([^~]*)~([^~]*)~(.*)$")
    if not mapID then return nil, "malformed KPG1 payload" end
    mapID, level, pb = tonumber(mapID), tonumber(level), tonumber(pb)
    if not mapID or mapID < 1 or mapID > 100000 or mapID ~= math.floor(mapID) then
        return nil, "bad dungeon id in KPG1 code"
    end
    if not level or level < 2 or level > 99 or level ~= math.floor(level) then
        return nil, "bad key level in KPG1 code"
    end
    if not pb or pb < 60 or pb > 36000 then return nil, "bad time in KPG1 code" end

    local kills, names, lastT = {}, {}, -1
    if cpBlob and cpBlob ~= "" then
        for entry in (cpBlob .. "^"):gmatch("([^%^]+)%^") do
            local name, t = entry:match("^(.*)#([%d%.]+)$")
            t = tonumber(t)
            if not name or name == "" or not t then return nil, "bad checkpoint in KPG1 code" end
            if t < lastT then return nil, "checkpoints out of order in KPG1 code" end
            if #kills >= 20 then return nil, "too many checkpoints in KPG1 code" end
            lastT = t
            -- Whole seconds at rest (the v3 integers-for-facts rule): their "%.1f"
            -- decimals are pseudo-precision on an already-approximate clock.
            kills[#kills + 1] = math.floor(t + 0.5)
            names[#kills] = name:sub(1, 80)
        end
    end

    -- The saturated-count staircase: {0,total,0} → one node per kill → the finish.
    local TOTAL = 100
    local snaps = { { 0, TOTAL, 0 } }
    for i = 1, #kills do
        snaps[#snaps + 1] = { kills[i], TOTAL, i }
    end
    snaps[#snaps + 1] = { math.max(math.ceil(pb), math.ceil(lastT)), TOTAL, #kills }

    local exporter = (label and label ~= "") and label:sub(1, 48) or "Unknown"
    return {
        legacy = "KPG1",
        mapID = mapID,
        level = level,
        durationSec = pb,
        total = TOTAL,
        snapshots = snaps,
        bossKills = kills,
        bossNames = names,
    }, exporter
end
