-- WoW Midnight (12.x) only — Keystone Ghost: race a ghost of your best Mythic+ runs.
-- Namespace + saved-variable defaults. All files share the addon-private NS vararg.
local ADDON_NAME, NS = ...

local KG = {}
NS.KG = KG

KG.ADDON_NAME = ADDON_NAME
KG.MAX_TIER = 3 -- chest tiers: 0 = depleted, 1..3 = +1/+2/+3

function KG.InitDB()
    _G.KeystoneGhostDB = _G.KeystoneGhostDB or {}
    local db = _G.KeystoneGhostDB
    if db.enabled == nil then db.enabled = true end
    if db.splits == nil then db.splits = true end
    if db.attach == nil then db.attach = "ellesmere" end -- docks only when the timer frame exists
    db.rosterSize = db.rosterSize or 3 -- ghost roster rows to aim for (raced + fillers)
    db.scale = db.scale or 1 -- bar + roster scale (Edit Mode slider)
    if db.bounce == nil then db.bounce = true end -- walk-cycle hop on your icon
    db.runs = db.runs or {}   -- [charKey][mapID][level] = { [tier] = run } (one slot per chest tier)
    db.pick = db.pick or {}   -- [mapID..":"..level] = { char, tier } auto-pick from imports
                              -- (manual tier override dropped 2026-07-19; pick UI is a later stage)
    KG.db = db
    return db
end

function KG.CharacterKey()
    local name = UnitName("player") or "?"
    local realm = GetRealmName() or "?"
    local _, class = UnitClass("player")
    return name .. "-" .. realm .. "-" .. (class or "?")
end
