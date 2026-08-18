-- The Ghost Library (DESIGN "The Ghost Library", approved 2026-07-21): the
-- management window — every stored run across all characters plus imports in one
-- dungeon-grouped list; browse, Pin ("race this next key"), share, delete. The
-- MDT paradigm end to end: this window is chrome around the EXISTING popups and
-- storage — import stays the paste StaticPopup, share stays the copy StaticPopup.
-- Row model is pure (GhostMath.LibraryModel, offline-tested); this file is only
-- the frame, the row widgets, and the wiring.
--
-- Entry points: bare /kg (Core), the minimap button (LibDBIcon, bottom of this
-- file), Options panel note. ESC closes (UISpecialFrames); the title bar drags
-- (position in db.libPos — a management dialog, deliberately NOT an Edit Mode
-- frame: Edit Mode owns HUD placement only).
local ADDON_NAME, NS = ...
local KG = NS.KG
local M = KG.Math
local Style = KG.Style

local Library = {}
KG.Library = Library

-- 690 wide since 2026-07-21 (was 620): the Raider.IO owner cell carries the
-- set word ("Raider.IO · Guild best") — static bump, his sanctioned fallback
-- to dynamic sizing, and imports with realm names breathe too.
local WIDTH, HEIGHT = 690, 440
local MIN_H = 240 -- resize floor: chrome + a handful of rows stays a usable window
local PAD = 12
local TITLE_H, HEADER_H, GROUP_H, ROW_H, BOTTOM_H = 30, 18, 22, 24, 34
-- Column x-offsets inside a row. Reaction round 2026-07-21 (Fredrik): the share
-- button sits FAR LEFT, delete stays FAR RIGHT — the destructive action lives
-- alone at the opposite edge from everything you'd click routinely. The eye
-- (2026-07-22) sits a clear 36 px inside delete: same right-hand action cluster,
-- but delete keeps the edge to itself.
local COL = { SHARE = 0, LVL = 26, TIER = 62, TIME = 116, DATE = 168, ROUTE = 214, OWNER = 400,
    EYE = 586, DEL = 622 }
local OWNER_W, ROUTE_W = COL.EYE - COL.OWNER - 6, COL.OWNER - COL.ROUTE - 8

local GOLD = { 1, 0.82, 0.15 } -- the pin gold (Splits' lock tint)
local TIER_COLOR = { [3] = Style.TICK3, [2] = Style.TICK2, [1] = Style.TICK1, [0] = Style.GRAY }
local ROUTE_GRAY = { 0.63, 0.63, 0.66 } -- the route cell at rest; hover brightens (clickable cue)

-- The hide toggle's art, bundled like share-icon.tga (64x64 32-bit uncompressed
-- TGA, white silhouette + alpha, so the vertex tint colors it). OWN art on
-- purpose: the first cut used the Blizzard atlas `transmog-icon-hidden` —
-- grep-evidenced in a live addon, which proved someone had WRITTEN the name, not
-- that it still resolves in 12.x. It didn't: Fredrik's screenshot showed an empty
-- frame (2026-07-22). A bundled file cannot silently evaporate, and depending on
-- another addon's eye art (Plater, BetterBags both ship one) would only move the
-- blank-icon failure to "that addon isn't installed".
local EYE_ICON = "Interface\\AddOns\\KeystoneGhost\\eye-icon.tga"
local EYE_OFF_ICON = "Interface\\AddOns\\KeystoneGhost\\eye-off-icon.tga"

local frame -- the window; built lazily on first toggle

local function DateShort(epoch)
    local dateFn = date or os.date
    if not epoch or not dateFn then return "" end
    local ok, s = pcall(dateFn, "%b %d", epoch)
    return ok and s or ""
end

--- charKey "Name-Realm-CLASS" → name, realm, classToken (any part may miss).
local function ParseCharKey(charKey)
    local name, realm, class = tostring(charKey or ""):match("^([^%-]+)%-([^%-]+)%-(.+)$")
    if not name then name = tostring(charKey or "?") end
    return name, realm, class
end

local function ClassColorHex(classToken)
    local c = classToken and _G.RAID_CLASS_COLORS and _G.RAID_CLASS_COLORS[classToken]
    if c and c.colorStr then return c.colorStr end -- "ffRRGGBB"
    if c then return string.format("ff%02x%02x%02x", c.r * 255, c.g * 255, c.b * 255) end
    return "ffe6e6e6"
end

--- The owner cell: class-colored short name; "(you)" on the current character;
--- imports wear a dim in-arrow mark + Name-Realm (the sender identity).
local function OwnerText(row)
    if row.charKey == KG.RIO_CHAR then
        -- Name · set word (his metadata order 2026-07-21): the one honest extra
        -- a replay carries — no Who exists for replays (their guild-best party
        -- lives in a timeline-less file), and When is the WHEN column's job.
        local src = row.run.rioSource
        return "Raider.IO" .. (src and (" · " .. src:sub(1, 1):upper() .. src:sub(2)) or "")
    end
    local name, realm, class = ParseCharKey(row.charKey)
    local hex = ClassColorHex(class)
    if row.run.importedFrom then
        local shown = realm and (name .. "-" .. realm) or name
        return "|TInterface\\ChatFrame\\ChatFrameExpandArrow:9|t|c" .. hex .. shown .. "|r"
    end
    local you = (row.charKey == KG.CharacterKey()) and " |cff8c8c8c(you)|r" or ""
    return "|c" .. hex .. name .. "|r" .. you
end

--- Same-account cluster among OTHER imports (Share Tag — viewing aid only, the
--- roster stays competitive by decision): distinct other sender names + a count.
local function ClusterLine(run)
    if not run.shareTag or not run.importedFrom then return nil end
    local names, count = {}, 0
    for charKey, byMap in pairs(KG.db.runs) do
        for _, byLevel in pairs(byMap) do
            for _, tiers in pairs(byLevel) do
                for _, other in pairs(tiers) do
                    if other ~= run and other.shareTag == run.shareTag then
                        count = count + 1
                        local name = ParseCharKey(charKey)
                        if name ~= ParseCharKey(run.importedFrom) then names[name] = true end
                    end
                end
            end
        end
    end
    if count == 0 then return nil end
    local list = {}
    for n in pairs(names) do list[#list + 1] = n end
    table.sort(list)
    local who = (#list > 0) and table.concat(list, ", ") or "this sender"
    return string.format("Same account: %s (%d more ghost%s)", who, count, count == 1 and "" or "s")
end

local function RowTip(row)
    local run, tip = row.run, {}
    tip[1] = string.format("%s +%d · %s", row.groupName, row.level, M.TierLabel(row.tier))
    local dur = M.FormatClock(run.durationSec or 0)
    if run.parTimeSec then
        local diff = (run.durationSec or 0) - run.parTimeSec
        dur = string.format("%s (par %s · %s)", dur, M.FormatClock(run.parTimeSec), M.FormatDelta(diff))
    end
    if run.deathCount then dur = dur .. string.format(" · %d death%s", run.deathCount, run.deathCount == 1 and "" or "s") end
    tip[#tip + 1] = dur
    if run.legacy == "KPG1" then
        -- Legacy-grade badge (no brand in-game — the neutral format name only).
        tip[#tip + 1] = "KPG1 ghost code: boss times only, approximate on deathful runs"
    elseif run.legacy == "RIO" then
        -- The set word (their sources[] → "guild best"…) joins the Library tip
        -- too (his metadata question 2026-07-21) — Splits/Bar already carry it.
        tip[#tip + 1] = "Converted Raider.IO replay" .. (run.rioSource and (" · " .. run.rioSource) or "")
            .. ". Real forces curve (per-award steps), clock honest to ±3 s"
    end
    if run.routeName then
        local rd = KG.Ghosts:RouteForHash(run.routeHash)
        local creator = rd and rd.createdBy and rd.createdBy.name
        tip[#tip + 1] = "Route: " .. M.StripColors(run.routeName)
            .. (creator and (" by " .. creator) or "")
            .. (rd and ". Click the route to copy it for MDT" or "")
    end
    if run.completedAt then tip[#tip + 1] = "Recorded " .. DateShort(run.completedAt) end
    local p = run.player
    if type(p) == "table" then
        local _, _, class = ParseCharKey(row.charKey)
        local label = M.PartyMemberLabel({ spec = p.spec, class = class, role = p.role })
        local bits = { label }
        if p.ilvl then bits[#bits + 1] = string.format("ilvl %d", p.ilvl) end
        if p.rating then bits[#bits + 1] = string.format("rating %d", p.rating) end
        tip[#tip + 1] = table.concat(bits, " · ")
    end
    if type(run.party) == "table" and #run.party > 0 then
        local bits = {}
        for _, m in ipairs(run.party) do
            local label = m.name or M.PartyMemberLabel(m)
            bits[#bits + 1] = m.rating and (label .. " " .. m.rating) or label
        end
        tip[#tip + 1] = "Party: " .. table.concat(bits, " · ")
    end
    if run.importedFrom then
        local name, realm = ParseCharKey(run.importedFrom)
        tip[#tip + 1] = string.format("Imported from %s%s%s", name, realm and ("-" .. realm) or "",
            run.importedAt and (" · " .. DateShort(run.importedAt)) or "")
        local cluster = ClusterLine(run)
        if cluster then tip[#tip + 1] = cluster end
    end
    if row.hidden then
        tip[#tip + 1] = "Hidden: parked out of the Ghost Roster and the automatic pick"
    end
    -- Every pin is DUNGEON-WIDE and per character (Fredrik 2026-07-21: "you
    -- might want to race against your +12 in a +20") — one copy for all rows.
    if row.pinned then
        tip[#tip + 1] = "Click: unpin (back to the automatic pick)"
    else
        tip[#tip + 1] = string.format("Click to pin. Races when you run %s (any key level%s)",
            row.groupName,
            row.hidden and "; this un-hides it"
                or (row.tier == 0 and "; a Depleted run races only by this pin" or ""))
    end
    return tip
end

-- Delete confirms via StaticPopup, naming exactly what dies (the mock's copy).
StaticPopupDialogs["KEYSTONEGHOST_DELETE"] = {
    text = "Keystone Ghost: delete %s?|nThis cannot be undone.",
    button1 = ACCEPT,
    button2 = CANCEL,
    OnAccept = function(self, data)
        if KG.Ghosts:DeleteRun(data.charKey, data.mapID, data.level, data.tier) then
            print("|cff88ccffKeystoneGhost|r: ghost deleted.")
            Library:RefreshIfShown()
        end
    end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

local function DeleteLabel(row)
    local who
    if row.run.importedFrom then
        who = ParseCharKey(row.run.importedFrom) .. "'s"
    elseif row.charKey == KG.CharacterKey() then
        who = "your"
    else
        who = ParseCharKey(row.charKey) .. "'s"
    end
    return string.format("%s %s +%d (%s, %s)", who, row.groupName, row.level,
        M.TierLabel(row.tier), M.FormatClock(row.run.durationSec or 0))
end

-- ── widget pools ──────────────────────────────────────────────────────────────

local function AcquireGroupHeader(i)
    local h = frame.groupPool[i]
    if h then return h end
    h = CreateFrame("Frame", nil, frame.content)
    h:SetHeight(GROUP_H)
    h.text = h:CreateFontString(nil, "OVERLAY")
    Style.SetFont(h.text, 11)
    h.text:SetPoint("BOTTOMLEFT", 0, 3)
    h.text:SetTextColor(Style.GetAccent())
    frame.groupPool[i] = h
    return h
end

--- One muted line under an empty dungeon's header — the honest empty state
--- (season-roster listing, 2026-07-21): says HOW a ghost appears here instead
--- of the dungeon silently missing from the list.
-- (The per-group hint pool that lived here retired 2026-08-02: there is one empty
-- state now and it belongs to the window, so a pool of them had nothing to hold.)

local function AcquireRow(i)
    local row = frame.rowPool[i]
    if row then return row end
    row = CreateFrame("Frame", nil, frame.content)
    row:SetHeight(ROW_H)
    row:EnableMouse(true)

    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetTexture("Interface\\Buttons\\WHITE8x8")
    row.bg:SetAllPoints()
    row.bg:Hide()
    row.edge = row:CreateTexture(nil, "BORDER") -- pinned accent edge, Splits' marker idiom
    row.edge:SetTexture("Interface\\Buttons\\WHITE8x8")
    row.edge:SetSize(2, ROW_H - 4)
    row.edge:SetPoint("LEFT", row, "LEFT", -6, 0)
    row.edge:Hide()

    local function Col(x, w, size)
        local fs = row:CreateFontString(nil, "OVERLAY")
        Style.SetFont(fs, size or 12)
        fs:SetPoint("LEFT", row, "LEFT", x, 0)
        fs:SetWidth(w)
        fs:SetJustifyH("LEFT")
        fs:SetWordWrap(false)
        return fs
    end

    row.lvl = Col(COL.LVL, COL.TIER - COL.LVL - 2)
    row.tier = Col(COL.TIER, COL.TIME - COL.TIER - 2, 11)
    row.time = Col(COL.TIME, COL.DATE - COL.TIME - 2)
    row.date = Col(COL.DATE, COL.ROUTE - COL.DATE - 2, 11)

    row.route = CreateFrame("Button", nil, row) -- clickable when a stored route exists
    row.route:SetSize(ROUTE_W, ROW_H)
    row.route:SetPoint("LEFT", row, "LEFT", COL.ROUTE, 0)
    row.route.text = row.route:CreateFontString(nil, "OVERLAY")
    Style.SetFont(row.route.text, 11)
    row.route.text:SetPoint("LEFT")
    row.route.text:SetWidth(ROUTE_W)
    row.route.text:SetJustifyH("LEFT")
    row.route.text:SetWordWrap(false)
    row.route:SetScript("OnClick", function(self)
        local rd = KG.Ghosts:RouteForHash(self.row.run.routeHash)
        if rd then KG.RequestRouteLoad(rd) end
    end)
    -- The route cell sits on top of the row: forward hover so the tooltip never
    -- dies — and brighten the route name itself (the close ×'s hover idiom), so
    -- a loadable route reads as clickable. Only a real route enables mouse on
    -- this cell, so the cue can't lie; the row's own wash stays untouched
    -- (Fredrik 2026-07-21: cue the buttons, don't change the row hover).
    row.route:SetScript("OnEnter", function(self)
        self.text:SetTextColor(0.95, 0.95, 0.98)
        local f = self:GetParent()
        f:GetScript("OnEnter")(f)
    end)
    row.route:SetScript("OnLeave", function(self)
        self.text:SetTextColor(ROUTE_GRAY[1], ROUTE_GRAY[2], ROUTE_GRAY[3])
        local f = self:GetParent()
        f:GetScript("OnLeave")(f)
    end)

    row.owner = Col(COL.OWNER, OWNER_W, 11)

    local function ActionButton(x, texture)
        local b = CreateFrame("Button", nil, row)
        b:SetSize(16, 16)
        b:SetPoint("LEFT", row, "LEFT", x, 0)
        b.tex = b:CreateTexture(nil, "ARTWORK")
        b.tex:SetAllPoints()
        b.tex:SetTexture(texture)
        b:SetAlpha(0.75)
        -- `restAlpha` lets a stateful button (the eye) carry its own resting
        -- brightness without the hover pair stomping it back to the shared 0.75.
        b:SetScript("OnEnter", function(self)
            self:SetAlpha(1)
            if self.tipText then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText(self.tipText, 0.9, 0.9, 0.9)
                GameTooltip:Show()
            end
        end)
        b:SetScript("OnLeave", function(self)
            self:SetAlpha(self.restAlpha or 0.75)
            GameTooltip:Hide()
        end)
        return b
    end
    -- The share glyph: Fredrik's own arrow-out-of-tray (2026-07-21 upload,
    -- superseding the brief hourglass stand-in) — a white silhouette with
    -- luminance-alpha, so the accent vertex tint colors it and hover
    -- brightens via the ActionButton alpha.
    row.share = ActionButton(COL.SHARE, "Interface\\AddOns\\KeystoneGhost\\share-icon.tga")
    -- The Raider.IO mark in the share slot doubles as the LINK DOOR (his
    -- 2026-07-21 order "clicking it should open the RaiderIO URL in a copy
    -- window"): the logo, click → copy popup with the raider.io run page.
    -- Texture + tooltip set per refresh; a cached ghost without a stored URL
    -- keeps the logo but makes no click claim and the click does nothing.
    row.rioMark = ActionButton(COL.SHARE, nil)
    row.rioMark:SetScript("OnClick", function(self)
        local url = self.row and self.row.run and self.row.run.rioUrl
        if url then
            KG.ShowCopy("LINK", url)
        else
            -- Honest no-op (his silent-click report 2026-07-21): ghosts banked
            -- before the link update carry no URL until a re-sight backfills it.
            print("|cff88ccffKeystoneGhost|r: no raider.io link stored for this ghost yet"
                .. ". Enter its dungeon with RaiderIO loaded and it fills in.")
        end
    end)
    row.share.tex:SetVertexColor(Style.GetAccent())
    row.share.tipText = "Share: copy this ghost's export string"
    row.share:SetScript("OnClick", function(self)
        local r = self.row
        local str, err = KG.Ghosts:ExportString(r.mapID, r.level, r.charKey, r.tier)
        if str then
            KG.ShowCopy("EXPORT", str)
        else
            print("|cff88ccffKeystoneGhost|r: export failed: " .. (err or "unknown error"))
        end
    end)
    -- The eye = HIDE, the reversible cousin of delete (Fredrik 2026-07-22: "be
    -- able to hide Ghost Racers from the Ghost Roster… they need to be able to be
    -- unhidden somewhere. Maybe in the Library?"). The glyph shows the CURRENT
    -- state, the universal convention: open eye = racing, slashed eye = parked.
    -- The row it sits on stays listed either way — this IS the un-hide door, so
    -- the ghost must never disappear from view.
    row.eye = ActionButton(COL.EYE, EYE_ICON)
    row.eye:SetScript("OnClick", function(self)
        local r = self.row
        KG.Ghosts:ToggleHidden(r.charKey, r.mapID, r.level, r.tier)
        Library:Refresh()
    end)

    row.del = ActionButton(COL.DEL, "Interface\\Buttons\\UI-GroupLoot-Pass-Up")
    row.del.tipText = "Delete this ghost"
    row.del:SetScript("OnClick", function(self)
        local r = self.row
        StaticPopup_Show("KEYSTONEGHOST_DELETE", DeleteLabel(r), nil,
            { charKey = r.charKey, mapID = r.mapID, level = r.level, tier = r.tier })
    end)

    -- Click ANYWHERE on the row = pin/unpin for its (dungeon, level) — the
    -- roster's own row-click language (Fredrik 2026-07-21; the pin glyph
    -- column retired the same day). The share/delete/route buttons sit above
    -- the row and keep their own clicks. Shift-click still inserts the chat
    -- share link (same gesture as the Roster Panel rows).
    row:SetScript("OnMouseUp", function(self, button)
        local r = self.row
        if button ~= "LeftButton" or not r then return end
        if IsShiftKeyDown() and KG.Comm then
            if r.charKey == KG.RIO_CHAR then
                print("|cff88ccffKeystoneGhost|r: Raider.IO ghosts can't be shared.")
                return
            end
            local pretty = string.format("%s +%d (%s)", r.groupName, r.level,
                M.FormatClock(r.run.durationSec or 0))
            KG.Comm.InsertShareLink(r.charKey, r.mapID, r.level, r.tier, pretty)
            return
        end
        KG.Ghosts:TogglePin(r.charKey, r.mapID, r.level, r.tier)
        Library:Refresh()
    end)

    -- Row hover: the context tooltip (the payload-expansion payoff — spec, party,
    -- provenance, Share-Tag cluster) + a faint wash so the eye keeps its line.
    row:SetScript("OnEnter", function(self)
        if self.row and self.row.pinned then
            local pr, pg, pb = Style.GetAccent()
            self.bg:SetVertexColor(pr, pg, pb, 0.2) -- pinned: the accent wash brightens
        else
            self.bg:SetVertexColor(1, 1, 1, 0.03)
        end
        self.bg:Show()
        local tip = RowTip(self.row)
        if GameTooltip_SetDefaultAnchor then
            GameTooltip_SetDefaultAnchor(GameTooltip, self)
        else
            GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
        end
        GameTooltip:SetText(tip[1])
        for i = 2, #tip do GameTooltip:AddLine(tip[i], 0.9, 0.9, 0.9) end
        if self.row.pinned then
            GameTooltip:AddLine(string.format("Races when you run %s (any key level)",
                self.row.groupName), GOLD[1], GOLD[2], GOLD[3])
        end
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function(self)
        if self.row and self.row.pinned then
            local pr, pg, pb = Style.GetAccent()
            self.bg:SetVertexColor(pr, pg, pb, 0.14) -- back to the resting accent wash
        else
            self.bg:Hide()
        end
        GameTooltip:Hide()
    end)

    frame.rowPool[i] = row
    return row
end

-- ── the window ────────────────────────────────────────────────────────────────

local function BuildFrame()
    frame = CreateFrame("Frame", "KeystoneGhostLibrary", UIParent, "BackdropTemplate")
    frame:SetSize(WIDTH, KG.db.libH or HEIGHT)
    frame:SetFrameStrata("HIGH")
    frame:SetMovable(true)
    -- Vertically resizable (his ask 2026-07-30); width stays the column
    -- contract's — the row cells sit on fixed x-offsets, so a wider window
    -- would only buy dead space. Bounds pin the width to enforce that.
    frame:SetResizable(true)
    frame:SetResizeBounds(WIDTH, MIN_H, WIDTH, 2000)
    frame:SetClampedToScreen(true)
    Style.SkinPanel(frame)
    frame:Hide()
    table.insert(UISpecialFrames, "KeystoneGhostLibrary") -- ESC closes

    local pos = KG.db.libPos
    if pos and pos.point then
        frame:SetPoint(pos.point, UIParent, pos.point, pos.x or 0, pos.y or 0)
    else
        frame:SetPoint("CENTER")
    end

    -- Title row: drag handle + close.
    local title = CreateFrame("Frame", nil, frame)
    title:SetPoint("TOPLEFT")
    title:SetPoint("TOPRIGHT")
    title:SetHeight(TITLE_H)
    title:EnableMouse(true)
    title:RegisterForDrag("LeftButton")
    title:SetScript("OnDragStart", function() frame:StartMoving() end)
    title:SetScript("OnDragStop", function()
        frame:StopMovingOrSizing()
        local point, _, _, x, y = frame:GetPoint()
        KG.db.libPos = { point = point, x = x, y = y }
    end)
    frame.title = title:CreateFontString(nil, "OVERLAY")
    Style.SetFont(frame.title, 13)
    frame.title:SetPoint("LEFT", PAD, 0)
    frame.title:SetText("Ghost Library")
    local sep = frame:CreateTexture(nil, "BORDER")
    sep:SetTexture("Interface\\Buttons\\WHITE8x8")
    sep:SetVertexColor(0.27, 0.27, 0.31, 0.5)
    sep:SetHeight(1)
    sep:SetPoint("TOPLEFT", 1, -TITLE_H)
    sep:SetPoint("TOPRIGHT", -3, -TITLE_H)

    local close = Style.CloseButton(title, function() frame:Hide() end)
    close:SetPoint("RIGHT", -8, 0)

    -- Column header (the Roster Panel idiom: fixed columns, dim caps).
    local header = CreateFrame("Frame", nil, frame)
    header:SetPoint("TOPLEFT", PAD, -TITLE_H)
    header:SetPoint("TOPRIGHT", -PAD, -TITLE_H)
    header:SetHeight(HEADER_H)
    local function H(x, text)
        local fs = header:CreateFontString(nil, "OVERLAY")
        Style.SetFont(fs, 9)
        fs:SetPoint("LEFT", header, "LEFT", x, 0)
        fs:SetText(text:upper())
        fs:SetAlpha(0.55)
        return fs
    end
    -- +6: rows sit inset 6 px inside the scroll content — labels align above them.
    H(COL.LVL + 6, "Key"); H(COL.TIER + 6, "Result"); H(COL.TIME + 6, "Time"); H(COL.DATE + 6, "When")
    H(COL.ROUTE + 6, "Route"); H(COL.OWNER + 6, "Ghost of")

    -- Scrolling list.
    local scroll = CreateFrame("ScrollFrame", "KeystoneGhostLibraryScroll", frame, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", PAD, -(TITLE_H + HEADER_H))
    scroll:SetPoint("BOTTOMRIGHT", -(PAD + 18), BOTTOM_H) -- 18: scrollbar gutter
    frame.scroll = scroll -- kept: Refresh parks it on the dungeon you are standing in
    frame.content = CreateFrame("Frame", nil, scroll)
    frame.content:SetWidth(WIDTH - PAD * 2 - 18)
    frame.content:SetHeight(1)
    scroll:SetScrollChild(frame.content)
    frame.groupPool, frame.rowPool = {}, {}

    -- The empty state lives IN the list, after the last dungeon — it is the last
    -- thing you read, not a watermark. Centering it on the window (the old anchor)
    -- would drop it behind the season roster's own eight rows; anchoring it to the
    -- scroll frame's top would land it on the first one. Position is set per refresh,
    -- where the running y is known.
    frame.empty = frame.content:CreateFontString(nil, "OVERLAY")
    Style.SetFont(frame.empty, 12)
    frame.empty:SetWidth(WIDTH - PAD * 2 - 30)
    frame.empty:SetJustifyH("LEFT")
    frame.empty:SetTextColor(0.55, 0.55, 0.55)
    frame.empty:Hide()

    -- Bottom bar: the one Import door + the Share Tag disclosure.
    local bottomSep = frame:CreateTexture(nil, "BORDER")
    bottomSep:SetTexture("Interface\\Buttons\\WHITE8x8")
    bottomSep:SetVertexColor(0.27, 0.27, 0.31, 0.5)
    bottomSep:SetHeight(1)
    bottomSep:SetPoint("BOTTOMLEFT", 1, BOTTOM_H)
    bottomSep:SetPoint("BOTTOMRIGHT", -3, BOTTOM_H)

    local function BarButton(width, label, tip, onClick)
        local b = CreateFrame("Button", nil, frame, "BackdropTemplate")
        b:SetSize(width, 22)
        b:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
        b:SetBackdropColor(0.16, 0.16, 0.20, 0.9)
        b:SetBackdropBorderColor(0.29, 0.29, 0.33, 1)
        b.text = b:CreateFontString(nil, "OVERLAY")
        Style.SetFont(b.text, 11)
        b.text:SetPoint("CENTER")
        b.text:SetText(label)
        b:SetScript("OnEnter", function(self)
            self:SetBackdropBorderColor(Style.GetAccent())
            if tip then
                GameTooltip:SetOwner(self, "ANCHOR_TOP")
                GameTooltip:SetText(tip[1])
                for i = 2, #tip do GameTooltip:AddLine(tip[i], 0.9, 0.9, 0.9, true) end
                GameTooltip:Show()
            end
        end)
        b:SetScript("OnLeave", function(self)
            self:SetBackdropBorderColor(0.29, 0.29, 0.33, 1)
            GameTooltip:Hide()
        end)
        b:SetScript("OnClick", onClick)
        return b
    end

    local import = BarButton(110, "Import ghost…", nil,
        function() StaticPopup_Show("KEYSTONEGHOST_IMPORT") end)
    import:SetPoint("BOTTOMLEFT", PAD, (BOTTOM_H - 22) / 2)

    -- The portal door (his flow, 2026-07-26: "click Open my library online,
    -- click a button, get a potentially huge URL that I paste into the browser").
    -- Whole library only — one dungeon at a time exists in Ghosts:CollectLibrary
    -- but has no button yet (DESIGN: deferred, not forgotten).
    local online = BarButton(150, "Open my library online",
        { "Open my library online",
            "Copies a link that loads every stored ghost in your browser. Paste it in the address bar.",
            "Runs you have opened before are not duplicated. New ones fill in." },
        function()
            local url, err, n = KG.Ghosts:ExportLibraryURL()
            if url then
                KG.ShowCopy("LIBRARY", url)
                print(string.format("|cff88ccffKeystoneGhost|r: %d ghost%s in the link.",
                    n, n == 1 and "" or "s"))
            else
                print("|cff88ccffKeystoneGhost|r: " .. (err or "nothing to open online yet."))
            end
        end)
    online:SetPoint("LEFT", import, "RIGHT", 8, 0)

    frame.footer = frame:CreateFontString(nil, "OVERLAY")
    Style.SetFont(frame.footer, 10)
    frame.footer:SetPoint("BOTTOMRIGHT", -(PAD + 14), (BOTTOM_H - 10) / 2) -- +14: the grip owns the corner
    frame.footer:SetTextColor(0.43, 0.43, 0.47)

    -- Resize grip (his ask 2026-07-30), AutoPullLabeler's Map recipe verbatim —
    -- the grabber art is a file path proven on HIS screen in that addon, not a
    -- grep candidate. Width is pinned by the resize bounds, so the corner drag
    -- only ever moves the bottom edge.
    local grip = CreateFrame("Button", nil, frame)
    grip:SetSize(16, 16)
    grip:SetPoint("BOTTOMRIGHT", -2, 2)
    grip:SetFrameLevel((frame:GetFrameLevel() or 0) + 10)
    local gtex = grip:CreateTexture(nil, "OVERLAY")
    gtex:SetAllPoints()
    gtex:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    gtex:SetAlpha(0.6)
    grip:SetScript("OnEnter", function() gtex:SetAlpha(1) end)
    grip:SetScript("OnLeave", function() gtex:SetAlpha(0.6) end)
    grip:SetScript("OnMouseDown", function() frame:StartSizing("BOTTOMRIGHT") end)
    grip:SetScript("OnMouseUp", function()
        frame:StopMovingOrSizing()
        KG.db.libH = math.floor(frame:GetHeight() + 0.5)
        -- Sizing re-derives the anchor; book the position too, or the next
        -- session opens where a pre-resize drag left it.
        local point, _, _, x, y = frame:GetPoint()
        KG.db.libPos = { point = point, x = x, y = y }
    end)

    -- OPENING the window is what parks it on your current dungeon — not every
    -- Refresh. A pin, a delete or an import must never yank the list out from
    -- under someone who has scrolled somewhere else (Fredrik 2026-07-29).
    frame:SetScript("OnShow", function()
        Library.scrollToCurrent = true
        Library:Refresh()
    end)
end

--- Rebuild the visible list from the pure model. Pools grow as needed; unused
--- widgets hide. Called on show and after every pin/delete/import action.
function Library:Refresh()
    if not frame or not frame:IsShown() then return end
    -- Opportunistic cache-on-sight: browsing the Library inside a dungeon banks
    -- the current replay. Self-gating outside; only re-refreshes on real change.
    KG.Ghosts:CacheRioOnSight()
    local S = KG.Scenario
    -- Season roster seeds a group per dungeon (bug report 2026-07-21: dungeons
    -- without data were invisible); unreadable roster → nil → data-only, as before.
    local groups = M.LibraryModel(KG.db.runs, KG.Ghosts:MyPicks(), function(mapID)
        return S:GetMapName(mapID)
    end, S:GetSeasonMapIDs())
    -- The empty state, shown once under the list when NOTHING is stored anywhere.
    -- The headers already say "no ghosts yet" per dungeon, so this line spends its
    -- words on what to DO about it instead of repeating the news.
    local emptyText = type(_G.RaiderIO) == "table"
        and "Nothing stored yet. Run a key, or walk into a dungeon with Raider.IO loaded and its replay lands here."
        or "Nothing stored yet. Run a key, or import a ghost from a friend."
    -- Tail for an EMPTY dungeon's header, only with Raider.IO loaded. "when you walk
    -- in" rather than "on arrival" (his 2026-08-02 read: arrival where?) — the player
    -- is told the action that fills the row, in the words they would use for it.
    local rioTail = type(_G.RaiderIO) == "table" and ", Raider.IO adds one when you walk in" or ""

    local usedG, usedR, y = 0, 0, 0
    local groupY = {} -- [mapID] = pixel offset of that dungeon's header
    for _, g in ipairs(groups) do
        usedG = usedG + 1
        if g.mapID then groupY[g.mapID] = y end
        local h = AcquireGroupHeader(usedG)
        h:SetPoint("TOPLEFT", 0, -y)
        h:SetPoint("TOPRIGHT", 0, -y)
        local n, nHidden = #g.rows, 0
        for _, r in ipairs(g.rows) do
            if r.hidden then nHidden = nHidden + 1 end
        end
        -- The key's own deadline next to the dungeon name (his ask 2026-07-30):
        -- a 30:53 row reads as "over the timer" without doing the arithmetic.
        -- Unreadable par → the segment simply isn't there.
        local par = g.mapID and S:GetParTimeSec(g.mapID)
        local parSeg = par and (M.FormatClock(par) .. " · ") or ""
        -- An empty dungeon says where its first ghost comes from (his ask 2026-08-02).
        -- NOT "a Raider.IO ghost will always be available", which we cannot promise:
        -- it needs their addon loaded AND a replay to exist for that dungeon. So the
        -- tail only appears when Raider.IO is actually loaded, and it describes what
        -- happens rather than guaranteeing a result.
        h.text:SetText(n == 0
            and string.format("%s |cff6f6f78· %sno ghosts yet%s|r", g.name, parSeg, rioTail)
            or string.format("%s |cff6f6f78· %s%d ghost%s%s|r", g.name, parSeg, n,
                n == 1 and "" or "s", nHidden > 0 and (", " .. nHidden .. " hidden") or ""))
        h.text:SetTextColor(Style.GetAccent())
        h:Show()
        y = y + GROUP_H

        -- No per-group hint. It was one line under the FIRST empty dungeon (the
        -- 2026-07-23 cure for a fresh install printing eight identical ones), and
        -- his clean-install screenshot showed what that actually reads as: advice
        -- about the window, hanging off Algeth'ar Academy as though it were about
        -- Algeth'ar Academy. It belongs to the empty STATE, below, once.

        for _, r in ipairs(g.rows) do
            usedR = usedR + 1
            local row = AcquireRow(usedR)
            r.groupName = g.name
            row.row = r
            row.route.row, row.share.row, row.del.row, row.rioMark.row = r, r, r, r
            row.eye.row = r
            row:SetPoint("TOPLEFT", 6, -y)
            row:SetPoint("TOPRIGHT", -2, -y)

            local depleted = r.tier == 0
            -- Hidden rows read like Depleted ones — dimmed, because both mean
            -- "not racing". The Result column and the lit eye tell them apart.
            local a = (depleted or r.hidden) and 0.55 or 1
            row.lvl:SetText("+" .. r.level)
            row.lvl:SetAlpha(a)
            row.tier:SetText(depleted and "Depleted" or M.TierLabel(r.tier))
            local tc = TIER_COLOR[r.tier] or Style.TEXT
            row.tier:SetTextColor(tc[1], tc[2], tc[3])
            row.tier:SetAlpha(a)
            row.time:SetText(M.FormatClock(r.run.durationSec or 0))
            row.time:SetAlpha(a)
            row.date:SetText(DateShort(r.run.completedAt))
            row.date:SetAlpha(a * 0.8)
            -- "n/a" on Raider.IO rows (his call 2026-07-21): a replay CANNOT
            -- carry a route, while a plain "—" just reads as absent data.
            local routeName = r.run.routeName and M.Ellipsize(M.StripColors(r.run.routeName), 28)
                or (r.charKey == KG.RIO_CHAR and "n/a" or "—")
            row.route.text:SetText(routeName)
            row.route.text:SetTextColor(ROUTE_GRAY[1], ROUTE_GRAY[2], ROUTE_GRAY[3])
            row.route.text:SetAlpha(a)
            row.route:EnableMouse(KG.Ghosts:RouteForHash(r.run.routeHash) ~= nil)
            row.owner:SetText(OwnerText(r))
            row.owner:SetAlpha((depleted or r.hidden) and 0.65 or 1)

            -- Depleted: still never auto-raced/rostered/exported — the share button
            -- stays hidden — but PINNING is allowed (Fredrik 2026-07-21): an
            -- explicit pin is the player's deliberate "race my depleted attempt".
            -- Pinned = the Roster Panel's raced-row language (his order, same
            -- day — the pin glyph column retired): accent edge bar + accent wash.
            if r.pinned then
                local pr, pg, pb = Style.GetAccent()
                row.edge:SetVertexColor(pr, pg, pb, 0.95)
                row.edge:Show()
                row.bg:SetVertexColor(pr, pg, pb, 0.14)
                row.bg:Show()
            else
                row.edge:Hide()
                row.bg:Hide()
            end
            -- Raider.IO rows (his round, 2026-07-21): the logo fills the share
            -- slot (share = not yours to re-export, the codec refuses anyway),
            -- and DELETE is gone too — the cache re-banked on the very next
            -- refresh inside the dungeon, so the X was a lie ("you probably
            -- cant delete it"). The row is a mirror; mirrors have no buttons.
            local isRio = r.charKey == KG.RIO_CHAR
            row.share:SetShown(not depleted and not isRio)
            row.del:SetShown(not isRio)
            -- The eye is the ONE control a Raider.IO row gets besides the link:
            -- delete was removed as a lie (the cache re-banks on next sight), but
            -- hiding is honest — it survives the re-bank (Ghosts:StoreRioGhost).
            -- A pinned row wears no eye at all (Fredrik: "the pinned one cannot
            -- be x:ed so it shouldn't have one") — un-hiding via pin is the rule,
            -- so pinned-and-hidden is a state that cannot exist.
            row.eye:SetShown(not r.pinned)
            row.eye.tex:SetTexture(r.hidden and EYE_OFF_ICON or EYE_ICON)
            if r.hidden then
                row.eye.tex:SetVertexColor(Style.GetAccent())
                row.eye.restAlpha = 0.95
                row.eye.tipText = "Hidden: click to let it race again"
            else
                row.eye.tex:SetVertexColor(0.55, 0.55, 0.58)
                row.eye.restAlpha = 0.5
                row.eye.tipText = "Hide: keep this ghost out of the Ghost Roster"
            end
            row.eye:SetAlpha(row.eye.restAlpha)
            local rioLogo = isRio and Style.RaiderIOLogo() or nil
            if rioLogo then row.rioMark.tex:SetTexture(rioLogo) end
            row.rioMark.tipText = (isRio and r.run.rioUrl)
                and "Copy the raider.io run link" or nil
            row.rioMark:SetShown(rioLogo ~= nil)
            row:Show()
            y = y + ROW_H
        end
    end
    for i = usedG + 1, #frame.groupPool do frame.groupPool[i]:Hide() end
    for i = usedR + 1, #frame.rowPool do frame.rowPool[i]:Hide() end

    -- The empty state is for a BLANK WINDOW only — no dungeons listed at all, which
    -- happens when the season roster is unreadable and nothing is stored. A library
    -- that lists dungeons needs no line: every header already ends in "no ghosts
    -- yet", and saying it again in a sentence is the news twice (his call
    -- 2026-08-02, looking at a clean install: "I don't think we need that hint now
    -- that we have the message"). The 2026-07-23 per-group hint died with it.
    if usedG == 0 then
        frame.empty:SetText(emptyText)
        frame.empty:ClearAllPoints()
        frame.empty:SetPoint("TOPLEFT", frame.content, "TOPLEFT", 6, -(y + 10))
        frame.empty:Show()
        y = y + 10 + ROW_H
    else
        frame.empty:Hide()
    end
    frame.content:SetHeight(math.max(y, 1))
    -- Open it standing in a dungeon and it opens ON that dungeon (Fredrik
    -- 2026-07-29): eight groups deep, the one you are in is the one you want.
    -- GetStagingMapID answers before the key starts too. The clamp is arithmetic
    -- rather than GetVerticalScrollRange, which is still stale on the frame the
    -- content height changed.
    if Library.scrollToCurrent then
        Library.scrollToCurrent = nil
        local mapID = S:GetStagingMapID()
        local at = mapID and groupY[mapID]
        if at and frame.scroll then
            -- The viewport height by construction, in case the frame has not been
            -- measured yet on the very first open.
            local viewH = frame.scroll:GetHeight() or 0
            if viewH <= 0 then
                viewH = (frame:GetHeight() or HEIGHT) - TITLE_H - HEADER_H - BOTTOM_H
            end
            local maxScroll = math.max(0, math.max(y, 1) - viewH)
            frame.scroll:SetVerticalScroll(math.max(0, math.min(at, maxScroll)))
        end
    end
    local tag = KG.db.shareTag
    frame.footer:SetText(tag
        and ("Your Share Tag: " .. tag .. " (lets receivers group your alts' exports)")
        or "")
    Style.RefreshPanel(frame)
end

function Library:RefreshIfShown()
    if frame and frame:IsShown() then Library:Refresh() end
end

--- The Edit Mode "Scale" slider (db.scale) covers the whole addon UI — Bar,
--- Roster Panel, and this window (Fredrik 2026-07-21 asked for a UI scale
--- control; it already existed for the HUD, the Library now follows live).
function Library:ApplyScale()
    if frame then frame:SetScale(KG.db.scale or 1) end
end

function Library:Toggle()
    if not frame then BuildFrame() end
    Library:ApplyScale()
    if frame:IsShown() then frame:Hide() else frame:Show() end
end

-- ── minimap button (Fredrik 2026-07-21: full button, upgraded from the proposed
-- compartment-only entry; LibDBIcon also registers the Addon Compartment entry) ──
--
-- THE ICON SWAP, EXECUTED (Fredrik 2026-07-21, his own art): the runed
-- hourglass with ghosts — a 128x128 32-bit uncompressed TGA converted from
-- his 2048px original (frame border cropped so no square edge shows in the
-- round button). The TOC's ## IconTexture wears the same file, so the addon
-- list and the minimap match. To iterate the art: overwrite minimap-icon.tga
-- (power-of-two square) — nothing else changes.
local MINIMAP_ICON = "Interface\\AddOns\\KeystoneGhost\\minimap-icon.tga"

local function SetupMinimapButton()
    local LDB = LibStub and LibStub("LibDataBroker-1.1", true)
    local DBIcon = LibStub and LibStub("LibDBIcon-1.0", true)
    if not LDB or not DBIcon then return end -- bundled; miss means a packaging bug
    local dataobj = LDB:NewDataObject("KeystoneGhost", {
        type = "launcher",
        icon = MINIMAP_ICON,
        OnClick = function(_, button)
            if button == "RightButton" then
                KG.Options:Open()
            else
                Library:Toggle()
            end
        end,
        OnTooltipShow = function(tt)
            tt:AddLine("Keystone Ghost")
            tt:AddLine("Click: Ghost Library", 0.9, 0.9, 0.9)
            tt:AddLine("Right-click: options", 0.9, 0.9, 0.9)
        end,
    })
    KG.db.minimap = KG.db.minimap or {}
    DBIcon:Register("KeystoneGhost", dataobj, KG.db.minimap)
end

function Library:Setup()
    SetupMinimapButton()
end
