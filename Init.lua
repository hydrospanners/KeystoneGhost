-- WoW Midnight (12.x) only — Keystone Ghost: race a ghost of your best Mythic+ runs.
-- Namespace + saved-variable defaults. All files share the addon-private NS vararg.
local ADDON_NAME, NS = ...

local KG = {}
NS.KG = KG

KG.ADDON_NAME = ADDON_NAME
KG.MAX_TIER = 3 -- chest tiers: 0 = depleted, 1..3 = +1/+2/+3
KG.RIO_CHAR = "Raider.IO" -- pseudo-charKey for cached converted replays (first-class
                          -- replay, 2026-07-21). Dashless BY DESIGN: real charKeys are
                          -- always Name-Realm-CLASS, so this can never collide, and
                          -- ShortName/ParseCharKey pass it through whole as a neutral
                          -- display name. The import codec refuses it as an exporter.

-- Addon version from the TOC; "dev" outside the client (offline test harness).
KG.VERSION = (function()
    local get = _G.C_AddOns and _G.C_AddOns.GetAddOnMetadata
    if get then
        local ok, v = pcall(get, ADDON_NAME, "Version")
        if ok and type(v) == "string" and v ~= "" then return v end
    end
    return "dev"
end)()

function KG.InitDB()
    _G.KeystoneGhostDB = _G.KeystoneGhostDB or {}
    local db = _G.KeystoneGhostDB
    if db.enabled == nil then db.enabled = true end
    if db.splits == nil then db.splits = true end
    if db.attach == nil then db.attach = "ellesmere" end -- docks only when the timer frame exists
    db.rosterSize = db.rosterSize or 3 -- ghost roster rows to aim for (raced + fillers)
    -- Ghost Roster columns, each an Edit Mode checkbox (Fredrik 2026-07-29:
    -- `x name key chest route time now B(n)`). Route is OFF by default — it is the
    -- wide one, and switching it on makes the panel wider than the bar.
    if db.colName == nil then db.colName = true end
    if db.colKey == nil then db.colKey = true end
    if db.colChest == nil then db.colChest = true end
    if db.colTime == nil then db.colTime = true end
    if db.colNow == nil then db.colNow = true end
    if db.colRoute == nil then db.colRoute = false end
    if db.colLaps == nil then db.colLaps = true end
    db.scale = db.scale or 1 -- bar + roster scale (Edit Mode slider)
    if db.bgAlpha == nil then db.bgAlpha = 1 end -- chrome opacity (backdrop/border/accent), Edit Mode slider
    if db.bounce == nil then db.bounce = true end -- walk-cycle hop on your icon
    if db.markerHat == nil then db.markerHat = false end -- easter egg (2026-07-28): the face
                            -- stays your portrait; a raid marker perches tiny above it
                            -- instead of replacing it (Options panel "Raid marker as a hat")
    -- Pace car visibility, one key per car (Fredrik 2026-07-28: "+1 +2 +3" boxes;
    -- the sweeper is hideable too). chestTicks was the old single "+3/+2" switch —
    -- an explicit OFF carries over to the two cars it used to govern, then retires.
    if db.chestTicks == false then
        if db.paceCar2 == nil then db.paceCar2 = false end
        if db.paceCar3 == nil then db.paceCar3 = false end
    end
    db.chestTicks = nil -- retired 2026-07-28: split into paceCar1/2/3
    if db.paceCar1 == nil then db.paceCar1 = true end
    if db.paceCar2 == nil then db.paceCar2 = true end
    if db.paceCar3 == nil then db.paceCar3 = true end
    db.runs = db.runs or {}   -- [charKey][mapID][level] = { [tier] = run } (one slot per chest tier)
    db.picks = db.picks or {} -- [pinnerCharKey][mapID] = { char, level, tier } — each
                              -- character's ONE pick per dungeon (Library pin; races any
                              -- key level — per-character and dungeon-wide since
                              -- 2026-07-21, Fredrik's Library reports)
    db.importPick = nil -- retired the same day it appeared (2026-07-21): the import PIN
                              -- is local to the importing character (round 4) — the
                              -- import DATA was always global via db.runs
    db.pick = nil -- retired 2026-07-21: the account-global [map..":"..level] store —
                  -- per-level keys don't map onto the per-character dungeon-wide
                  -- model, so old pins reset once (re-pin from the Library)
    db.routes = db.routes or {} -- Route Store: [contentHash] = captured route (dossier §7);
                                -- runs reference via run.routeHash; GC'd by Ghosts:SweepRoutes
    for _, rd in pairs(db.routes) do -- one-time field renames (2026-07-20)
        if rd.cum and not rd.cumulativeForces then rd.cumulativeForces, rd.cum = rd.cum, nil end
        -- capturedAt → storedAt: the stamp marks when the STORE ENTRY was written
        -- (run save), not when the content was frozen (key start) — renamed for truth.
        if rd.capturedAt and not rd.storedAt then rd.storedAt, rd.capturedAt = rd.capturedAt, nil end
    end
    if db.shareRouteName == nil then db.shareRouteName = true end -- export: route name + creator
    if db.shareRouteData == nil then db.shareRouteData = true end -- export: embedded route (click-to-load)
    if db.sharePartyNames == nil then db.sharePartyNames = false end -- export: party names — OPT-IN
                            -- (privacy default, Fredrik 2026-07-20; off = spec labels only)
    if db.closeOnCopy == nil then db.closeOnCopy = true end -- copy window: Ctrl+C closes it
                            -- (Fredrik 2026-07-26). Default ON because the StaticPopup it
                            -- replaced always closed — the checkbox is the opt-out, not a new habit.
    if db.percentDisplay == nil then db.percentDisplay = true end -- forces readout: % by default;
                            -- unticking "Show % instead of count" flips every site to raw count
                            -- (Fredrik 2026-07-20 — an on-by-default checkbox reads naturally)
    db.minimap = db.minimap or {} -- LibDBIcon state (hide/minimapPos/lock) — Ghost Library button
                            -- db.libPos (Library window position) stays nil until first drag
    -- First-login placement (Fredrik 2026-07-28): the MOVE ME show returns at
    -- login on EVERY character until the bar has actually been PLACED — a drag
    -- (the MOVE ME handle or Edit Mode) or the handle's deliberate close,
    -- whichever comes first (his tie-to-placement call, superseding the same-
    -- day shown-once draft). The DB is account-wide and so is the bar position:
    -- one placement settles every character. Installs that predate the field
    -- placed their bar long ago — schemaVersion (stamped by MigrateDB on every
    -- install's first login) marks them placed. InitDB runs at ADDON_LOADED,
    -- BEFORE Start()'s MigrateDB, which is what makes this order-proof.
    if db.placed == nil and db.schemaVersion ~= nil then db.placed = true end
    db.introShown = nil -- retired same-day draft key (shown-once; never shipped)
    db.colorVision = db.colorVision or "default" -- verdict palette (Options dropdown, 2026-07-21)
    db.deathMarkers = db.deathMarkers or "all" -- tombstones: "none" | "yours" | "all"
                            -- (Options dropdown, 2026-07-22). DISPLAY-ONLY: a ghost's pace
                            -- never depends on this — its recorded clock already carries
                            -- the penalty — so flipping it mid-run just redraws.
                            -- db.rosterSort stays nil until a header is clicked (Splits)
    db.countDisplay = nil -- stale key from the same-day default-count hour (never shipped)
    KG.db = db
    return db
end

function KG.CharacterKey()
    local name = UnitName("player") or "?"
    local realm = GetRealmName() or "?"
    local _, class = UnitClass("player")
    return name .. "-" .. realm .. "-" .. (class or "?")
end
