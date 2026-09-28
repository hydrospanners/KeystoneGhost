-- Runner identity, painted: who a run belongs to, said three ways — a texture
-- on a lane runner or roster row (ApplyRunnerIcon), an inline escape inside a
-- FontString (RunnerIconEscape), a raced-ghost badge (ApplyGhostIcon). One
-- identity language: Rabbit face ladder, Raider.IO logo, class circles, the
-- watch as the honest unknown. EXTRACTED from Bar.lua 2026-09-10 (wave 2
-- split, second cut); comments carry their original dates. Report, Splits and
-- Options enter through KG.Bar facades, this file stays their engine.
local ADDON_NAME, NS = ...
local KG = NS.KG
local Style = KG.Style

local Icons = {}
KG.BarIcons = Icons

--- The RaiderIO logo texture path, or nil — hoisted to Style.RaiderIOLogo
--- (2026-07-21) so the Library owner cell shares it; alias kept for the two
--- call sites below.
local function RaiderIOLogo()
    return Style.RaiderIOLogo()
end

-- ── The Rabbit's face (F5 look; his cute→fearsome ladder, 2026-08-25) ─────────
-- Real game icons, existence-checked at runtime (the #124 flag recipe: an asset
-- ships only behind a live check; names verified against the client's icon set
-- via Wowhead's extracted assets, 2026-08-24). The ladder scales with how hard
-- the Rabbit pushes — v1 margins use the gentle half; the percentile rabbits
-- (F7) climb the rest, his calls: p90 wears the polymorph panic, p99 the
-- Darkmoon Rabbit (the game's own Caerbannog homage). db.rabbitFace overrides.
local RABBIT_FACES = {
    spring    = "Interface\\Icons\\inv_rabbit2_spring",
    classic   = "Interface\\Icons\\inv_misc_rabbit",
    silver    = "Interface\\Icons\\inv_rabbit2_silver",
    polymorph = "Interface\\Icons\\spell_magic_polymorphrabbit",
    darkmoon  = "Interface\\Icons\\inv_rabbit2_darkmoon",
}
local FACE_LADDER = { "spring", "classic", "silver", "polymorph", "darkmoon" }
local rabbitFaceIDs -- [face] = fileID | false, resolved once per session
local function RabbitFaceID(face)
    if not rabbitFaceIDs then
        rabbitFaceIDs = {}
        local get = rawget(_G, "GetFileIDFromPath")
        for key, path in pairs(RABBIT_FACES) do
            rabbitFaceIDs[key] = get and get(path) or false
        end
    end
    return rabbitFaceIDs[face] or false
end
local function RabbitIntensity() -- 1..5 on the ladder; margins live on 1-3,
    -- the percentile paces (F7, 2026-09-10) climb the reserved half: p90 =
    -- the polymorph panic, p99 = the Darkmoon Rabbit (his calls, 2026-08-25).
    local pace = KG.db.rabbitPace
    local pct = type(pace) == "string" and tonumber(pace:match("^p(%d+)$")) or nil
    if pct then
        if pct >= 99 then return 5 end
        if pct >= 90 then return 4 end
        return 3
    end
    local m = KG.db.rabbitMargin or 0.90
    if m >= 0.945 then return 1 end
    if m >= 0.875 then return 2 end
    return 3
end
local function RabbitFace() -- fileID | nil (nil = watch), plus the face key
    local pick = KG.db.rabbitFace
    if pick and pick ~= "auto" and RABBIT_FACES[pick] then
        local id = RabbitFaceID(pick)
        if id then return id, pick end
    end
    local key = FACE_LADDER[RabbitIntensity()]
    local id = RabbitFaceID(key)
    if id then return id, key end
    id = RabbitFaceID("classic")
    if id then return id, "classic" end
    return nil
end
function Icons.RabbitFaceKey() -- the applied-face cache key (options changes repaint)
    return tostring(KG.db.rabbitFace or "auto") .. "|" .. tostring(KG.db.rabbitMargin or 0.9)
        .. "|" .. tostring(KG.db.rabbitPace or "") -- F7: a percentile pick moves the auto ladder
end
Icons.RabbitFaceID = RabbitFaceID -- (faceKey) → fileID|false; the Options
-- picker draws each entry's actual face through this door (his 2026-09-01
-- "pick which rabbit on an icon kind of way")

local ownerMemo = setmetatable({}, { __mode = "k" }) -- [run table] = charKey | false

--- The run's owner CLASS token (#146 follow-up, his Gandalfred catch): an
--- import names its exporter in importedFrom; a same-account alt's run
--- carries nothing, so ask the store who owns it — MEMOIZED per run table
--- (weak keys; council 2026-09-01: the call sites ride the 0.1s repaint,
--- and a full-store identity sweep per icon per tick is not "event-time").
--- A run's storage identity never changes while its table lives. The
--- viewer's class stays the last resort — a run stored nowhere is your own
--- live/demo recording.
local function RunnerClassToken(run)
    local ownerKey = run.importedFrom
    if not ownerKey then
        local hit = ownerMemo[run]
        if hit == nil then
            hit = KG.Ghosts:FindRunOwner(run) or false
            ownerMemo[run] = hit
        end
        ownerKey = hit or nil
    end
    return (type(ownerKey) == "string" and ownerKey:match("%-([^%-]+)$"))
        or select(2, UnitClass("player"))
end

local function ApplyRunnerIcon(tex, run)
    tex:SetAlpha(1) -- pooled texture: the Rabbit's fade must not leak to others
    if run.rabbit then -- the Rabbit's lane runner: its face, a few % faded
        local id = RabbitFace()
        if id then
            tex:SetTexture(id)
            tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            tex:SetAlpha(0.85)
            return
        end
        tex:SetTexture("Interface\\Icons\\INV_Misc_PocketWatch_01")
        tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        return
    end
    if run.legacy == "RIO" then -- the Raider.IO ghost as a roster row/runner
        local logo = RaiderIOLogo()
        if logo then
            tex:SetTexture(logo)
            tex:SetTexCoord(0, 1, 0, 1)
            return
        end
        -- logo unreadable (RaiderIO uninstalled, cached ghost racing): the watch —
        -- NEVER the player-class fallback below, that claims the run is yours
        tex:SetTexture("Interface\\Icons\\INV_Misc_PocketWatch_01")
        tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        return
    end
    local token = RunnerClassToken(run)
    local coords = token and _G.CLASS_ICON_TCOORDS and _G.CLASS_ICON_TCOORDS[token]
    if coords then
        tex:SetTexture("Interface\\TargetingFrame\\UI-Classes-Circles")
        tex:SetTexCoord(coords[1], coords[2], coords[3], coords[4])
    else
        tex:SetTexture("Interface\\Icons\\INV_Misc_PocketWatch_01")
        tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    end
end
Icons.ApplyRunnerIcon = ApplyRunnerIcon -- (tex, run) — roster rows mirror their runner

--- The runner's icon as an inline TEXTURE ESCAPE for FontStrings (his
--- 2026-09-02 ruling: the stored report's splits columns show the runner's
--- SYMBOL, not a name). Same branches as ApplyRunnerIcon — one language,
--- second output form. Always returns a renderable escape (watch fallback).
function Icons.RunnerIconEscape(run, size)
    size = size or 14
    if run.rabbit then
        local id = RabbitFace()
        if id then return "|T" .. id .. ":" .. size .. "|t" end
    elseif run.legacy == "RIO" then
        local logo = RaiderIOLogo()
        if logo then return "|T" .. logo .. ":" .. size .. "|t" end
    else
        local token = RunnerClassToken(run)
        local coords = token and _G.CLASS_ICON_TCOORDS and _G.CLASS_ICON_TCOORDS[token]
        if coords then
            return string.format(
                "|TInterface\\TargetingFrame\\UI-Classes-Circles:%d:%d:0:0:256:256:%d:%d:%d:%d|t",
                size, size, coords[1] * 256, coords[2] * 256, coords[3] * 256, coords[4] * 256)
        end
    end
    return "|TInterface\\Icons\\INV_Misc_PocketWatch_01:" .. size .. "|t"
end

--- Ghost cursor icon by reference kind: character ghosts (own / imported) show the
--- round class icon — class COLOR block as fallback when the icon coords are
--- unavailable; the RaiderIO replay wears the RaiderIO logo; pace ghosts the watch.
--- (The raid marker belongs to the PLAYER cursor — mixed up once, 2026-07-19.
--- Iteration idea on file: a faded portrait of the ghost's character.)
local function ApplyGhostIcon(iconTex, ref)
    local key = ref.kind .. "|" .. tostring(ref.run and ref.run.importedFrom or "")
    if ref.kind == "rabbit" then key = key .. "|" .. Icons.RabbitFaceKey() end
    if iconTex._kgIconKey == key then return end
    iconTex._kgIconKey = key
    iconTex:SetSize(16, 16)
    iconTex:SetAlpha(1)

    -- The Rabbit wears its face, a few % faded so YOU stay the easy read —
    -- and the ghost cursor's hover frame is built before the player's, so
    -- Mario draws on top when they overlap (his order, 2026-08-24).
    if ref.kind == "rabbit" then
        local id = RabbitFace()
        if id then
            iconTex:SetTexture(id)
            iconTex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            iconTex:SetVertexColor(1, 1, 1)
            iconTex:SetAlpha(0.85)
            return
        end
        -- no resolvable face on this client: fall through to the watch below
    end

    local classToken
    if ref.kind == "personal" or ref.kind == "test" then
        classToken = select(2, UnitClass("player"))
    elseif ref.kind == "import" and ref.run and ref.run.importedFrom then
        classToken = ref.run.importedFrom:match("%-([^%-]+)$")
    end
    -- Bright round class icon (a TINTED disc rendered muddy-dark in the field —
    -- vertex color multiplies, it can't brighten — so the icon must be bright itself).
    local coords = classToken and _G.CLASS_ICON_TCOORDS and _G.CLASS_ICON_TCOORDS[classToken]
    if coords then
        iconTex:SetTexture("Interface\\TargetingFrame\\UI-Classes-Circles")
        iconTex:SetTexCoord(coords[1], coords[2], coords[3], coords[4])
        iconTex:SetVertexColor(1, 1, 1)
        return
    end
    local color = classToken and _G.RAID_CLASS_COLORS and _G.RAID_CLASS_COLORS[classToken]
    if color then -- class-color fallback when icon coords are missing
        iconTex:SetTexture("Interface\\Buttons\\WHITE8x8")
        iconTex:SetTexCoord(0, 1, 0, 1)
        iconTex:SetVertexColor(color.r, color.g, color.b)
        iconTex:SetSize(12, 12)
        return
    end

    -- RaiderIO ghost wears the RaiderIO logo; watch as fallback for it and pace ghosts.
    if ref.kind == "rio" then
        local logo = RaiderIOLogo()
        if logo then
            iconTex:SetTexture(logo)
            iconTex:SetTexCoord(0, 1, 0, 1)
            iconTex:SetVertexColor(1, 1, 1)
            return
        end
    end
    iconTex:SetTexture("Interface\\Icons\\INV_Misc_PocketWatch_01")
    iconTex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    iconTex:SetVertexColor(1, 1, 1)
end
Icons.ApplyGhostIcon = ApplyGhostIcon -- (iconTex, ref) — the raced row mirrors the badge
