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
