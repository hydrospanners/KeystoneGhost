-- Diagnostics (2026-09-08): a support door for "why does my race look like
-- this?" questions asked from a stream, a screenshot, or a Discord message.
--
-- Two halves. The RACE LOG is automatic: every key start, resume and end
-- appends one line to `KeystoneGhostDB.diag.log` — which ghost was raced and
-- why, what the roster held, what the library knew about that dungeon, and
-- whether the finished run landed in the store or why it did not. Chat lines
-- scroll away during a 30-minute key; SavedVariables survive the logout, so
-- the answer is still there a week later. The log keeps the last MAX_ENTRIES.
--
-- The DUMP (`/kg diag`, or the Support button in Options) puts the environment,
-- the settings, the whole library inventory and the race log into the copy
-- window as one text: select all, Ctrl+C, paste to whoever asked. Nothing
-- leaves the machine on its own. Character names and import senders are in it
-- (they are the library), a Share Tag is not.
local ADDON_NAME, NS = ...
local KG = NS.KG
local M = KG.Math

local Diag = {}
KG.Diag = Diag

local MAX_ENTRIES = 40

local function Store()
    local db = KG.db
    if not db then return nil end
    db.diag = db.diag or {}
    db.diag.log = db.diag.log or {}
    return db.diag
end

local function Stamp()
    return date("%Y-%m-%d %H:%M")
end

local function Clock(sec)
    return M.FormatClock(sec or 0)
end

local function MapName(mapID)
    local S = KG.Scenario
    return (S and S.GetMapName and S:GetMapName(mapID)) or ("map " .. tostring(mapID))
end

local function YesNo(v) return v and "yes" or "no" end

--- Append one stamped line. Silent when the DB is not up yet (nothing to
--- persist into).
function Diag:Log(text)
    local d = Store()
    if not d then return end
    local log = d.log
    log[#log + 1] = Stamp() .. "  " .. text
    while #log > MAX_ENTRIES do table.remove(log, 1) end
end

function Diag:Clear()
    local d = Store()
    if d then d.log = {} end
end

-- ── Describers ───────────────────────────────────────────────────────────────

--- One stored run as "+16/+1 27:10 [hidden] [import from X]".
local function RunWord(run, level, tier, hiddenSet)
    local s = string.format("+%s/%s %s", tostring(level), M.TierLabel(tier), Clock(run.durationSec))
    if hiddenSet and hiddenSet[run] then s = s .. " [hidden]" end
    if run.importedFrom then s = s .. " [import from " .. tostring(run.importedFrom) .. "]" end
    if run.legacy == "RIO" then s = s .. " [rio " .. tostring(run.rioSource or "replay") .. "]" end
    return s
end

--- The library's holdings for ONE dungeon, one line per character key. Also
--- returns how many of this character's own runs there are timed (raceable)
--- versus depleted, which is the number that decides the whole race look.
local function DescribeMapLibrary(mapID, indent)
    local lines = {}
    local db = KG.db
    local me = KG.CharacterKey()
    local hiddenSet = KG.Ghosts.HiddenRunSet and KG.Ghosts:HiddenRunSet() or nil
    local ownTimed, ownDepleted = 0, 0
    local chars = {}
    for charKey in pairs(db.runs or {}) do chars[#chars + 1] = charKey end
    table.sort(chars)
    for _, charKey in ipairs(chars) do
        local byLevel = db.runs[charKey][mapID]
        if byLevel then
            local words = {}
            local levels = {}
            for level in pairs(byLevel) do levels[#levels + 1] = level end
            table.sort(levels, function(a, b) return tostring(a) < tostring(b) end)
            for _, level in ipairs(levels) do
                local tiers = byLevel[level]
                for tier = KG.MAX_TIER, 0, -1 do
                    local run = tiers[tier]
                    if type(run) == "table" then
                        words[#words + 1] = RunWord(run, level, tier, hiddenSet)
                        if charKey == me and not run.importedFrom then
                            if tier >= 1 then ownTimed = ownTimed + 1 else ownDepleted = ownDepleted + 1 end
                        end
                    end
                end
            end
            if #words > 0 then
                local who = charKey == KG.RIO_CHAR and "Raider.IO" or (charKey == me and (charKey .. " (you)") or charKey)
                lines[#lines + 1] = indent .. who .. ": " .. table.concat(words, " · ")
            end
        end
    end
    if #lines == 0 then lines[1] = indent .. "(nothing stored for this dungeon)" end
    return lines, ownTimed, ownDepleted
end

local function DescribeRef(ref)
    if not ref then return "none (bar idle)" end
    local s = tostring(ref.kind) .. ' "' .. tostring(ref.label) .. '"'
    if ref.startPinned then s = s .. " [pinned]" end
    if ref.live then s = s .. " [live mirror]" end
    return s
end

local function DescribeRoster(mapID, level, routeName)
    local ok, roster = pcall(function() return KG.Ghosts:GetRoster(mapID, level, routeName) end)
    if not ok then return "roster error: " .. tostring(roster) end
    if not roster or #roster == 0 then return "(empty)" end
    local words = {}
    for _, e in ipairs(roster) do
        local run = e.run
        if run.rabbit then
            words[#words + 1] = "Rabbit " .. Clock(run.durationSec)
        else
            words[#words + 1] = string.format("%s +%s/%s %s", tostring(e.tag),
                tostring(run.level or "?"), M.TierLabel(run.chests), Clock(run.durationSec))
        end
    end
    return table.concat(words, " | ")
end

-- ── The race log hooks (Recorder calls these) ────────────────────────────────

--- Key start or resume: the raced ghost, the roster, and what the library held
--- for this dungeon at that moment.
function Diag:LogRaceStart(rec, ref, why)
    if not rec or not rec.mapID then
        self:Log(string.format("%s · dungeon unreadable (mapID nil, level %s)", why, tostring(rec and rec.level)))
        return
    end
    local S = KG.Scenario
    local libLines, ownTimed, ownDepleted = DescribeMapLibrary(rec.mapID, "")
    local best = S and S.GetSeasonBestSec and S:GetSeasonBestSec(rec.mapID)
    local par = S and S.GetParTimeSec and S:GetParTimeSec(rec.mapID)
    self:Log(string.format("%s %s +%s · raced: %s · roster: %s · your timed runs here: %d, depleted: %d · season best %s · par %s · library: %s",
        why, MapName(rec.mapID), tostring(rec.level), DescribeRef(ref),
        DescribeRoster(rec.mapID, rec.level, rec.routeName), ownTimed, ownDepleted,
        best and Clock(best) or "none", par and Clock(par) or "?",
        table.concat(libLines, " ; ")))
end

--- Key end: the result and whether it was stored. `stored` is true (landed),
--- false (a slower repeat at the same tier), or nil with `reason` saying why
--- the save never ran.
function Diag:LogKeyEnd(saved, level, chests, durationSec, stored, reason)
    local where = saved and saved.mapID and MapName(saved.mapID) or "unknown dungeon"
    local verdict
    if reason then
        verdict = "NOT saved: " .. reason
    elseif stored then
        verdict = "saved as " .. M.TierLabel(chests) .. " ghost"
    else
        verdict = "not saved: a faster " .. M.TierLabel(chests) .. " ghost already stored at this level"
    end
    self:Log(string.format("end %s +%s · %s %s · deaths %d · %s", where, tostring(level),
        M.TierLabel(chests), durationSec and Clock(durationSec) or "?",
        (saved and saved.deathCount) or 0, verdict))
end

-- ── The dump ─────────────────────────────────────────────────────────────────

local function AddonWord(name)
    local C = rawget(_G, "C_AddOns")
    if not (type(C) == "table" and type(C.GetAddOnMetadata) == "function") then return name .. "=?" end
    local ok, ver = pcall(C.GetAddOnMetadata, name, "Version")
    if not ok or not ver then return name .. "=absent" end
    local state = ""
    if type(C.IsAddOnLoaded) == "function" then
        local okL, loaded = pcall(C.IsAddOnLoaded, name)
        state = okL and (loaded and " loaded" or " NOT loaded") or ""
    end
    return name .. "=" .. tostring(ver) .. state
end

function Diag:Dump()
    local L = {}
    local function add(s) L[#L + 1] = s end
    local db = KG.db
    local S = KG.Scenario
    local ver, build, _, toc = "?", "?", nil, "?"
    if type(GetBuildInfo) == "function" then ver, build, _, toc = GetBuildInfo() end

    add(string.format("Keystone Ghost diagnostics · addon %s · WoW %s (build %s, toc %s) · %s",
        tostring(KG.VERSION), tostring(ver), tostring(build), tostring(toc), Stamp()))
    add("character: " .. KG.CharacterKey())
    add("addons: " .. table.concat({
        AddonWord("RaiderIO"), AddonWord("MythicDungeonTools"),
        AddonWord("EllesmereUI"), AddonWord("EllesmereUIMythicTimer"),
    }, " · "))
    local RIO = rawget(_G, "RaiderIO")
    add(string.format("raider.io api: global=%s GetCurrentReplay=%s",
        YesNo(type(RIO) == "table"), YesNo(type(RIO) == "table" and type(RIO.GetCurrentReplay) == "function")))

    local Icons = KG.BarIcons
    local faceWords = {}
    for _, key in ipairs({ "spring", "classic", "silver", "polymorph", "darkmoon" }) do
        local id = Icons and Icons.RabbitFaceID and Icons.RabbitFaceID(key)
        faceWords[#faceWords + 1] = key .. "=" .. (id and tostring(id) or "missing")
    end
    add(string.format("icons: GetFileIDFromPath=%s · rabbit faces %s · RaiderIO logo=%s · class icon coords=%s",
        YesNo(type(rawget(_G, "GetFileIDFromPath")) == "function"), table.concat(faceWords, " "),
        YesNo(KG.Style and KG.Style.RaiderIOLogo and KG.Style.RaiderIOLogo()),
        YesNo(type(rawget(_G, "CLASS_ICON_TCOORDS")) == "table")))

    add(string.format("settings: rosterSize=%s rabbitMode=%s rabbitMargin=%s rabbitFace=%s deathMarkers=%s colorVision=%s scale=%s placed=%s schemaVersion=%s",
        tostring(db.rosterSize or 3), tostring(db.rabbitMode or "auto"), tostring(db.rabbitMargin or 0.90),
        tostring(db.rabbitFace or "auto"), tostring(db.deathMarkers), tostring(db.colorVision),
        tostring(db.scale or 1), YesNo(db.placed), tostring(db.schemaVersion)))

    local picks = KG.Ghosts.MyPicks and KG.Ghosts:MyPicks() or nil
    local pinWords = {}
    if type(picks) == "table" then
        for mapID, p in pairs(picks) do
            if type(p) == "table" then
                pinWords[#pinWords + 1] = string.format("%s → %s +%s/%s", MapName(mapID),
                    tostring(p.char), tostring(p.level), p.tier and M.TierLabel(p.tier) or "best")
            end
        end
    end
    table.sort(pinWords)
    add("pins: " .. (#pinWords > 0 and table.concat(pinWords, " · ") or "none"))

    local lr = db.liveRun
    add("live run slot: " .. (type(lr) == "table" and lr.mapID
        and string.format("%s +%s by %s (%d snapshots)", MapName(lr.mapID), tostring(lr.level),
            tostring(lr.charKey), lr.snapshots and #lr.snapshots or 0)
        or "empty"))

    local current = {}
    if S and S.GetSeasonMapIDs then
        for _, id in ipairs(S:GetSeasonMapIDs() or {}) do current[id] = true end
    end
    local mapIDs, seen, total = {}, {}, 0
    for _, byMap in pairs(db.runs or {}) do
        for mapID, byLevel in pairs(byMap) do
            if not seen[mapID] then seen[mapID] = true; mapIDs[#mapIDs + 1] = mapID end
            for _, tiers in pairs(byLevel) do
                for _, run in pairs(tiers) do if type(run) == "table" then total = total + 1 end end
            end
        end
    end
    table.sort(mapIDs, function(a, b) return MapName(a) < MapName(b) end)
    add(string.format("library: %d ghost%s across %d dungeon%s", total, total == 1 and "" or "s",
        #mapIDs, #mapIDs == 1 and "" or "s"))
    for _, mapID in ipairs(mapIDs) do
        add(string.format("  %s (%s)%s", MapName(mapID), tostring(mapID),
            next(current) and not current[mapID] and " [not in this season]" or ""))
        local lines = DescribeMapLibrary(mapID, "    ")
        for _, l in ipairs(lines) do add(l) end
    end

    local d = Store()
    local log = d and d.log or {}
    add(string.format("race log (%d entr%s, newest last, keeps the last %d):", #log, #log == 1 and "y" or "ies", MAX_ENTRIES))
    if #log == 0 then add("  (no keys recorded since this version was installed)") end
    for _, line in ipairs(log) do add("  " .. line) end

    return table.concat(L, "\n")
end
