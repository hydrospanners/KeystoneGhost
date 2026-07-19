-- Optional MDT route context — cumulative forces per pull for the "pull N · ghost M"
-- position indicator. Ported from AutoPullLabeler's RouteMath (same author/workspace):
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
--- Zero-interaction route pick (Fredrik, 2026-07-19): the preset last SELECTED in
--- MDT's dropdown for the ACTIVE dungeon. MDT remembers that selection per dungeon
--- (db.currentPreset[dungeonIdx] = index into db.presets[dungeonIdx]), so this works
--- even when MDT's window sits on a different dungeon — no link button, no prompt
--- (APL's link-a-route button is the design this replaces). This also fixes a shape
--- bug: currentPreset[dIdx] is a numeric INDEX, not the preset table — the old code
--- indexed the number and hard-errored inside OnKeyStart whenever MDT was open on
--- the matching dungeon (why the pull indicator was never seen live).
--- @return { cum = number[], nPulls = number, name = string|nil } | nil
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

    local cum, bossPull = {}, {}
    local okAll = pcall(function()
        for i = 1, #pulls do
            cum[i] = CumulativeForces(MDT, dIdx, pulls, i)
            if PullHasBoss(MDT, dIdx, pulls[i]) then bossPull[i] = true end
        end
    end)
    if not okAll or #cum == 0 then return nil end

    local name = preset.text
    return {
        cum = cum,
        bossPull = bossPull,
        nPulls = #pulls,
        name = type(name) == "string" and name:sub(1, 60) or nil,
    }
end
