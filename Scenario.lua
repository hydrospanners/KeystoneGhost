-- WoW Midnight (12.x) only — secret-safe scenario / challenge-mode reads.
-- Same guarded-read approach as AutoPullLabeler's Scenario module: every field from
-- C_ScenarioInfo can intermittently be a secret value on 12.0.5+, so all reads go through
-- a canaccessvalue gate and the enemy-forces total is cached per challenge map so the
-- forces% path survives transient secret flickers.
local ADDON_NAME, NS = ...
local KG = NS.KG

local S = {}
KG.Scenario = S

local canRead = _G.canaccessvalue or function(v)
    if v == nil then return true end
    local ok, isSecret = pcall(issecretvalue, v)
    if not ok then return false end
    return not isSecret
end

local function readBool(v)
    if not canRead(v) then return nil end
    if v == true or v == false then return v end
    return nil
end

local function readNum(v)
    if not canRead(v) or type(v) ~= "number" then return nil end
    return v
end

local totalCache = {}

local function FindEnemyForcesCriteria()
    local okStep, stepInfo = pcall(C_ScenarioInfo.GetScenarioStepInfo)
    if not okStep or not stepInfo then return nil end
    local n = readNum(stepInfo.numCriteria)
    if not n then return nil end
    for i = 1, n do
        local okCrit, cInfo = pcall(C_ScenarioInfo.GetCriteriaInfo, i)
        if okCrit and cInfo and readBool(cInfo.isWeightedProgress) then
            return cInfo
        end
    end
    return nil
end

--- @return number rawCount, number total (0,0 when unreadable)
function S:ReadEnemyForcesRaw()
    local cInfo = FindEnemyForcesCriteria()
    local total = cInfo and readNum(cInfo.totalQuantity)
    if total and total <= 0 then total = nil end
    local key = self:GetChallengeMapID() or "generic"
    if total then totalCache[key] = total else total = totalCache[key] end
    if not total or total <= 0 then return 0, 0 end
    if not cInfo then return 0, total end

    local qStr = cInfo.quantityString
    if canRead(qStr) and type(qStr) == "string" then
        local raw = tonumber(qStr:match("(%d+)"))
        if raw then return raw, total end
    end
    local qty = readNum(cInfo.quantity)
    if qty then return qty, total end
    return 0, total
end

function S:GetForcesPercent()
    local raw, total = self:ReadEnemyForcesRaw()
    if total > 0 then return (raw / total) * 100 end
    return 0
end

--- Strip the "... defeated" boilerplate from a boss criterion description.
local function BossName(desc)
    if not canRead(desc) or type(desc) ~= "string" then return nil end
    desc = desc:gsub("[Dd]efeated", "")
    desc = desc:match("^%s*(.-)%s*$")
    return desc ~= "" and desc or nil
end

--- Non-weighted criteria = bosses, without needing unit identity. Returns a compact,
--- criteria-ordered array of { done = bool, name = string|nil }; the order is stable for
--- a given dungeon, so the recorder diffs `done` flags against it to timestamp kills.
function S:GetBossCriteriaStates()
    local out = {}
    local okStep, stepInfo = pcall(C_ScenarioInfo.GetScenarioStepInfo)
    if not okStep or not stepInfo then return out end
    local n = readNum(stepInfo.numCriteria)
    if not n then return out end
    for i = 1, n do
        local okCrit, cInfo = pcall(C_ScenarioInfo.GetCriteriaInfo, i)
        if okCrit and cInfo and readBool(cInfo.isWeightedProgress) == false then
            out[#out + 1] = {
                done = readBool(cInfo.completed) == true,
                name = BossName(cInfo.description),
            }
        end
    end
    return out
end

function S:GetChallengeMapID()
    local ok, id = pcall(C_ChallengeMode.GetActiveChallengeMapID)
    if not ok then return nil end
    id = readNum(id)
    if id and id > 0 then return id end
    return nil
end

function S:IsChallengeActive()
    local ok, active = pcall(C_ChallengeMode.IsChallengeModeActive)
    if ok then
        local b = readBool(active)
        if b ~= nil then return b end
    end
    return self:GetChallengeMapID() ~= nil
end

function S:GetActiveKeyLevel()
    if not C_ChallengeMode.GetActiveKeystoneInfo then return nil end
    local ok, level = pcall(C_ChallengeMode.GetActiveKeystoneInfo)
    if not ok then return nil end
    level = readNum(level)
    if level and level > 0 then return level end
    return nil
end

function S:GetParTimeSec(mapID)
    if not mapID or not C_ChallengeMode.GetMapUIInfo then return nil end
    local ok, _name, _id, timeLimit = pcall(C_ChallengeMode.GetMapUIInfo, mapID)
    if not ok then return nil end
    timeLimit = readNum(timeLimit)
    if timeLimit and timeLimit > 0 then return timeLimit end
    return nil
end

--- Guarded dungeon name for a challenge map (nil when unreadable).
function S:GetMapName(mapID)
    if not mapID or not C_ChallengeMode.GetMapUIInfo then return nil end
    local ok, name = pcall(C_ChallengeMode.GetMapUIInfo, mapID)
    if not ok or not canRead(name) or type(name) ~= "string" then return nil end
    return name
end

function S:GetSeasonBestSec(mapID)
    if not mapID or not C_MythicPlus or not C_MythicPlus.GetSeasonBestForMap then return nil end
    local ok, info = pcall(C_MythicPlus.GetSeasonBestForMap, mapID)
    if not ok or type(info) ~= "table" then return nil end
    local dur = readNum(info.durationSec)
    if dur and dur > 0 then return dur end
    return nil
end

--- Seconds on the world keystone timer (survives /reload, unlike our GetTime anchor).
--- Can be a secret on 12.0.5+ — guarded like everything else.
function S:GetWorldElapsedSec()
    if not GetWorldElapsedTime then return nil end
    local ok, _, elapsed = pcall(GetWorldElapsedTime, 1)
    if not ok then return nil end
    elapsed = readNum(elapsed)
    if elapsed and elapsed > 0 then return elapsed end
    return nil
end

--- Raid target marker on the player (1..8), or nil. In instances GetRaidTargetIndex can
--- return a SECRET number — type() still says "number" but any comparison throws. This
--- burned us live (Bar.lua once did the compare inline); readNum's canaccessvalue gate
--- is the only safe path.
function S:GetPlayerRaidMarker()
    if not GetRaidTargetIndex then return nil end
    local ok, idx = pcall(GetRaidTargetIndex, "player")
    if not ok then return nil end
    idx = readNum(idx)
    if idx and idx >= 1 and idx <= 8 then return idx end
    return nil
end

--- The weekly-reset boundary epoch this moment belongs to — the run's reset-week
--- identity (Fredrik 2026-07-21, "reset best / overall best" seed; DESIGN
--- post-1.0 expansions — the capture lands early because old runs never gain
--- fields). Two runs share a week ⟺ equal stamps. API verified this session
--- (wow-api-verify: wiki 9.0.1→12.1 active + AlterEgo TOC 120007 usage).
function S:WeekEndEpoch()
    if not (C_DateAndTime and C_DateAndTime.GetSecondsUntilWeeklyReset) then return nil end
    local ok, secs = pcall(C_DateAndTime.GetSecondsUntilWeeklyReset)
    if not ok then return nil end
    secs = readNum(secs)
    if not secs or secs < 0 then return nil end
    return S:ServerNow() + secs
end

--- Server-clock epoch for all stored timestamps (client clocks lie; the realm is
--- already in the data — DESIGN "Payload expansion"). Client-clock fallback only
--- when the API is somehow absent (offline harness).
function S:ServerNow()
    if GetServerTime then
        local ok, t = pcall(GetServerTime)
        if ok then
            t = readNum(t)
            if t and t > 0 then return t end
        end
    end
    return time and time() or 0
end

--- Exporter context captured at KEY START (payload expansion — spec/guild/level
--- change later; history must not rewrite). Every field best-effort: unreadable
--- simply means absent. APIs verified 2026-07-20 (Blizzard docs live + BigWigs/
--- Details usage, TOC 120100).
function S:GetPlayerContext()
    local out = {}
    local okS, specIdx = pcall(GetSpecialization)
    if okS and type(specIdx) == "number" then
        local okI, specID = pcall(GetSpecializationInfo, specIdx)
        if okI then out.spec = readNum(specID) end
    end
    local okR, role = pcall(UnitGroupRolesAssigned, "player")
    if okR and canRead(role) and type(role) == "string" and role ~= "NONE" then out.role = role end
    local okG, guild = pcall(GetGuildInfo, "player")
    if okG and canRead(guild) and type(guild) == "string" then out.guild = guild:sub(1, 48) end
    local okL, lvl = pcall(UnitLevel, "player")
    if okL then out.level = readNum(lvl) end
    local okIl, _, equipped = pcall(GetAverageItemLevel)
    if okIl then -- equipped ilvl: what was actually worn in the key
        local e = readNum(equipped)
        if e and e > 0 then out.ilvl = math.floor(e * 10 + 0.5) / 10 end
    end
    if C_PlayerInfo and C_PlayerInfo.GetPlayerMythicPlusRatingSummary then
        local okRt, sum = pcall(C_PlayerInfo.GetPlayerMythicPlusRatingSummary, "player")
        if okRt and type(sum) == "table" then out.rating = readNum(sum.currentSeasonScore) end
    end
    if C_ClassTalents and C_ClassTalents.GetActiveConfigID and C_Traits and C_Traits.GenerateImportString then
        local okT, cfg = pcall(C_ClassTalents.GetActiveConfigID)
        if okT and type(cfg) == "number" then
            local okStr, str = pcall(C_Traits.GenerateImportString, cfg)
            if okStr and type(str) == "string" and #str > 0 and #str <= 400 then out.talents = str end
        end
    end
    return next(out) and out or nil
end

--- Current M+ season ID; nil while uninitialized (the API answers -1 early — the
--- documented trap; KG.Start primes RequestMapInfo so it resolves before a key).
function S:GetSeasonID()
    if not C_MythicPlus or not C_MythicPlus.GetCurrentSeason then return nil end
    local ok, id = pcall(C_MythicPlus.GetCurrentSeason)
    id = ok and readNum(id) or nil
    if id and id > 0 then return id end
    return nil
end

--- This week's affix IDs ({id, id, ...}); nil when the affix data isn't loaded.
function S:GetAffixIDs()
    if not C_MythicPlus or not C_MythicPlus.GetCurrentAffixes then return nil end
    local ok, affixes = pcall(C_MythicPlus.GetCurrentAffixes)
    if not ok or type(affixes) ~= "table" then return nil end
    local out = {}
    for i = 1, math.min(#affixes, 5) do
        local a = affixes[i]
        local id = type(a) == "table" and readNum(a.id) or nil
        if id then out[#out + 1] = id end
    end
    return #out > 0 and out or nil
end

--- Party roster context — called at KEY END so the ratings are at-completion
--- (the BigWigs-proven call works on party units). Name-realm, class,
--- role, M+ rating; others' spec needs inspect round-trips (flaky mid-key) and
--- others' ilvl is inspect-only — both skipped by decision. Deaths stay
--- anonymous {t, count}: roster names are context, never blame data.
function S:GetPartyContext()
    local out = {}
    for i = 1, 4 do
        local unit = "party" .. i
        local okE, exists = pcall(UnitExists, unit)
        if okE and exists == true then
            local m = {}
            local okN, name = pcall(GetUnitName, unit, true)
            if okN and canRead(name) and type(name) == "string" then m.name = name:sub(1, 60) end
            local okC, _, classFile = pcall(UnitClass, unit)
            if okC and canRead(classFile) and type(classFile) == "string" then m.class = classFile end
            local okR, role = pcall(UnitGroupRolesAssigned, unit)
            if okR and canRead(role) and type(role) == "string" and role ~= "NONE" then m.role = role end
            if C_PlayerInfo and C_PlayerInfo.GetPlayerMythicPlusRatingSummary then
                local okRt, sum = pcall(C_PlayerInfo.GetPlayerMythicPlusRatingSummary, unit)
                if okRt and type(sum) == "table" then m.rating = readNum(sum.currentSeasonScore) end
            end
            if m.name then out[#out + 1] = m end
        end
    end
    return #out > 0 and out or nil
end

--- Inspected specID for a unit after its INSPECT_READY fired (0/garbage → nil).
--- Usage shape verified against live Details (core/inspect.lua: NotifyInspect →
--- INSPECT_READY(guid) → GetInspectSpecialization(unit)).
function S:GetInspectSpecID(unit)
    if not GetInspectSpecialization then return nil end
    local ok, spec = pcall(GetInspectSpecialization, unit)
    if not ok then return nil end
    spec = readNum(spec)
    if spec and spec > 0 then return spec end
    return nil
end

--- Fire-and-forget inspect request; true when the request went out.
function S:RequestInspect(unit)
    if not NotifyInspect then return false end
    return (pcall(NotifyInspect, unit))
end

--- @return count|nil, timeLostSec|nil (the death penalty already baked into the timer)
function S:GetDeathCount()
    if not C_ChallengeMode.GetDeathCount then return nil end
    local ok, count, timeLost = pcall(C_ChallengeMode.GetDeathCount)
    if not ok then return nil end
    return readNum(count), readNum(timeLost)
end

--- Table-return completion API (current in 12.x; used by WarpDeplete/RaiderIO/Details).
--- @return { timeSec, onTime, level, mapID, chests, practiceRun } or nil
function S:GetCompletion()
    if not C_ChallengeMode.GetChallengeCompletionInfo then return nil end
    local ok, info = pcall(C_ChallengeMode.GetChallengeCompletionInfo)
    if not ok or type(info) ~= "table" then return nil end
    local timeMs = readNum(info.time)
    local onTime = readBool(info.onTime)
    local upgrades = readNum(info.keystoneUpgradeLevels)
    -- onTime unreadable (secret flicker) → chests stays nil so the recorder's
    -- duration-vs-par fallback engages, instead of mislabeling a timed PB as depleted
    -- (which would make it unraceable forever under the never-race-depleted rule).
    local chests
    if onTime ~= nil then
        chests = (onTime and upgrades and upgrades > 0) and math.min(upgrades, KG.MAX_TIER) or (onTime and 1 or 0)
    end
    return {
        timeSec = timeMs and timeMs / 1000 or nil,
        onTime = onTime,
        level = readNum(info.level),
        mapID = readNum(info.mapChallengeModeID),
        chests = chests,
        practiceRun = readBool(info.practiceRun) == true,
    }
end

--- Journal encounter ID for a dungeon encounterID (the ENCOUNTER_START ids we store
--- as bossIDs) — resolvable only while INSIDE the instance, from its Encounter
--- Journal listing. Verified 12.x chain (wow-api-verify 2026-07-20):
--- C_Map.GetBestMapForUnit → C_EncounterJournal.GetInstanceForGameMap →
--- EJ_GetEncounterInfoByIndex, whose 7th return is the dungeon encounterID (8.2+).
--- EJ_GetEncounterInfoByIndex needs EJ_SelectInstance once per session (documented
--- quirk) — called politely, never while the Encounter Journal window is open so a
--- browsing player's selection is never yanked. nil on any gap: the stored
--- criteria-scraped name remains the display fallback by design.
function S:GetJournalEncounterID(dungeonEncounterID)
    if type(dungeonEncounterID) ~= "number" then return nil end
    if not (C_Map and C_Map.GetBestMapForUnit and C_EncounterJournal
        and C_EncounterJournal.GetInstanceForGameMap and EJ_GetEncounterInfoByIndex) then
        return nil
    end
    local okM, uiMap = pcall(C_Map.GetBestMapForUnit, "player")
    if not okM or type(uiMap) ~= "number" then return nil end
    local okI, jInst = pcall(C_EncounterJournal.GetInstanceForGameMap, uiMap)
    if not okI or type(jInst) ~= "number" or jInst <= 0 then return nil end
    if EJ_SelectInstance and not (_G.EncounterJournal and _G.EncounterJournal:IsShown()) then
        pcall(EJ_SelectInstance, jInst)
    end
    for i = 1, 20 do
        local ok, name, _, jid, _, _, _, dungeonID = pcall(EJ_GetEncounterInfoByIndex, i, jInst)
        if not ok or not name then break end
        if type(dungeonID) == "number" and dungeonID == dungeonEncounterID
            and type(jid) == "number" then
            return jid
        end
    end
    return nil
end
