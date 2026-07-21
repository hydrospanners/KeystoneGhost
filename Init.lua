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
    db.scale = db.scale or 1 -- bar + roster scale (Edit Mode slider)
    if db.bgAlpha == nil then db.bgAlpha = 1 end -- chrome opacity (backdrop/border/accent), Edit Mode slider
    if db.bounce == nil then db.bounce = true end -- walk-cycle hop on your icon
    db.runs = db.runs or {}   -- [charKey][mapID][level] = { [tier] = run } (one slot per chest tier)
    db.picks = db.picks or {} -- [pinnerCharKey][mapID] = { char, level, tier } — each
                              -- character's ONE pick per dungeon (Library pin / import
                              -- auto-pick; races any key level — per-character and
                              -- dungeon-wide since 2026-07-21, Fredrik's Library reports)
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
    if db.percentDisplay == nil then db.percentDisplay = true end -- forces readout: % by default;
                            -- unticking "Show % instead of count" flips every site to raw count
                            -- (Fredrik 2026-07-20 — an on-by-default checkbox reads naturally)
    db.minimap = db.minimap or {} -- LibDBIcon state (hide/minimapPos/lock) — Ghost Library button
                            -- db.libPos (Library window position) stays nil until first drag
    db.colorVision = db.colorVision or "default" -- verdict palette (Options dropdown, 2026-07-21)
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
