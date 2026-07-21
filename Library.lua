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

local WIDTH, HEIGHT = 620, 440
local PAD = 12
local TITLE_H, HEADER_H, GROUP_H, ROW_H, BOTTOM_H = 30, 18, 22, 24, 34
-- Column x-offsets inside a row. Reaction round 2026-07-21 (Fredrik): the share
-- button sits FAR LEFT, delete stays FAR RIGHT — the destructive action lives
-- alone at the opposite edge from everything you'd click routinely.
local COL = { SHARE = 0, PIN = 22, LVL = 44, TIER = 80, TIME = 134, DATE = 186, ROUTE = 232, OWNER = 404, DEL = 552 }
local OWNER_W, ROUTE_W = COL.DEL - COL.OWNER - 6, COL.OWNER - COL.ROUTE - 8

local GOLD = { 1, 0.82, 0.15 } -- the pin gold (Splits' lock tint)
local TIER_COLOR = { [3] = Style.TICK3, [2] = Style.TICK2, [1] = Style.TICK1, [0] = Style.GRAY }

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
    return string.format("Same account: %s — %d more ghost%s", who, count, count == 1 and "" or "s")
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
        tip[#tip + 1] = "KPG1 ghost code — boss times only, approximate on deathful runs"
    elseif run.legacy == "RIO" then
        tip[#tip + 1] = "Converted Raider.IO replay — real forces curve (per-award steps), clock honest to ±3 s"
    end
    if run.routeName then
        local rd = KG.Ghosts:RouteForHash(run.routeHash)
        local creator = rd and rd.createdBy and rd.createdBy.name
        tip[#tip + 1] = "Route: " .. M.StripColors(run.routeName)
            .. (creator and (" by " .. creator) or "")
            .. (rd and " — click the route to load into MDT" or "")
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
    return tip
end

-- Delete confirms via StaticPopup, naming exactly what dies (the mock's copy).
StaticPopupDialogs["KEYSTONEGHOST_DELETE"] = {
    text = "Keystone Ghost — delete %s?|nThis cannot be undone.",
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

    row.pin = CreateFrame("Button", nil, row)
    row.pin:SetSize(16, 16)
    row.pin:SetPoint("LEFT", row, "LEFT", COL.PIN, 0)
    row.pin.tex = row.pin:CreateTexture(nil, "ARTWORK")
    row.pin.tex:SetAllPoints()
    -- The Pin wears an actual map-pin (Fredrik 2026-07-21 — the lock read wrong).
    -- Atlas verified in use by installed addons; desaturated so the vertex color
    -- alone speaks: grey = pinnable, gold = pinned (the roster wears the same).
    row.pin.tex:SetAtlas("Waypoint-MapPin-Tracked")
    row.pin.tex:SetDesaturated(true)
    row.pin:SetScript("OnClick", function(self)
        local r = self.row
        KG.Ghosts:TogglePin(r.charKey, r.mapID, r.level, r.tier)
        Library:Refresh()
    end)
    row.pin:SetScript("OnEnter", function(self)
        local r = self.row
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if r.pinned then
            GameTooltip:SetText(string.format("Pinned — races when you run %s +%d.", r.groupName, r.level))
            GameTooltip:AddLine("Click to unpin (back to the automatic pick).", 0.9, 0.9, 0.9)
        else
            GameTooltip:SetText(string.format("Race this next key — pin for %s +%d.", r.groupName, r.level))
        end
        if r.tier == 0 then
            GameTooltip:AddLine("A Depleted run races only by this explicit pin — the automatic pick never chooses one.", 0.55, 0.55, 0.55, true)
        end
        GameTooltip:Show()
    end)
    row.pin:SetScript("OnLeave", function() GameTooltip:Hide() end)

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
    -- The route cell sits on top of the row: forward hover so the tooltip never dies.
    row.route:SetScript("OnEnter", function(self)
        local f = self:GetParent()
        f:GetScript("OnEnter")(f)
    end)
    row.route:SetScript("OnLeave", function(self)
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
        b:SetScript("OnEnter", function(self)
            self:SetAlpha(1)
            if self.tipText then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText(self.tipText, 0.9, 0.9, 0.9)
                GameTooltip:Show()
            end
        end)
        b:SetScript("OnLeave", function(self)
            self:SetAlpha(0.75)
            GameTooltip:Hide()
        end)
        return b
    end
    -- The share glyph is the addon's own hourglass mark (Fredrik 2026-07-21:
    -- "na use it" — no separate export icon; the art is full-color, so no
    -- vertex tint). Hover still brightens via the ActionButton alpha.
    row.share = ActionButton(COL.SHARE, "Interface\\AddOns\\KeystoneGhost\\minimap-icon.tga")
    row.share.tipText = "Share — copy this ghost's export string"
    row.share:SetScript("OnClick", function(self)
        local r = self.row
        local str, err = KG.Ghosts:ExportString(r.mapID, r.level, r.charKey, r.tier)
        if str then
            StaticPopup_Show("KEYSTONEGHOST_EXPORT", nil, nil, str)
        else
            print("|cff88ccffKeystoneGhost|r: export failed — " .. (err or "unknown error"))
        end
    end)
    row.del = ActionButton(COL.DEL, "Interface\\Buttons\\UI-GroupLoot-Pass-Up")
    row.del.tipText = "Delete this ghost"
    row.del:SetScript("OnClick", function(self)
        local r = self.row
        StaticPopup_Show("KEYSTONEGHOST_DELETE", DeleteLabel(r), nil,
            { charKey = r.charKey, mapID = r.mapID, level = r.level, tier = r.tier })
    end)

    -- Shift-click with the chat editbox open inserts the chat share link — the
    -- same gesture as the Roster Panel rows; one idiom everywhere (3b).
    row:SetScript("OnMouseUp", function(self, button)
        local r = self.row
        if button == "LeftButton" and IsShiftKeyDown() and r and KG.Comm then
            local pretty = string.format("%s +%d (%s)", r.groupName, r.level,
                M.FormatClock(r.run.durationSec or 0))
            KG.Comm.InsertShareLink(r.charKey, r.mapID, r.level, r.tier, pretty)
        end
    end)

    -- Row hover: the context tooltip (the payload-expansion payoff — spec, party,
    -- provenance, Share-Tag cluster) + a faint wash so the eye keeps its line.
    row:SetScript("OnEnter", function(self)
        self.bg:SetVertexColor(1, 1, 1, (self.row and self.row.pinned) and 0.08 or 0.03)
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
            GameTooltip:AddLine(string.format("Races when you run %s +%d",
                self.row.groupName, self.row.level), GOLD[1], GOLD[2], GOLD[3])
        end
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function(self)
        if self.row and self.row.pinned then
            self.bg:SetVertexColor(1, 1, 1, 0.05) -- back to the resting pinned wash
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
    frame:SetSize(WIDTH, HEIGHT)
    frame:SetFrameStrata("HIGH")
    frame:SetMovable(true)
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

    local close = CreateFrame("Button", nil, title)
    close:SetSize(18, 18)
    close:SetPoint("RIGHT", -8, 0)
    close.text = close:CreateFontString(nil, "OVERLAY")
    Style.SetFont(close.text, 13)
    close.text:SetPoint("CENTER")
    close.text:SetText("×")
    close.text:SetTextColor(0.55, 0.55, 0.55)
    close:SetScript("OnEnter", function() close.text:SetTextColor(1, 1, 1) end)
    close:SetScript("OnLeave", function() close.text:SetTextColor(0.55, 0.55, 0.55) end)
    close:SetScript("OnClick", function() frame:Hide() end)

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
    frame.content = CreateFrame("Frame", nil, scroll)
    frame.content:SetWidth(WIDTH - PAD * 2 - 18)
    frame.content:SetHeight(1)
    scroll:SetScrollChild(frame.content)
    frame.groupPool, frame.rowPool = {}, {}

    frame.empty = frame:CreateFontString(nil, "OVERLAY")
    Style.SetFont(frame.empty, 12)
    frame.empty:SetPoint("CENTER", 0, 10)
    frame.empty:SetTextColor(0.55, 0.55, 0.55)
    frame.empty:SetText("No ghosts stored yet — finish a Mythic+ run, or import one.")
    frame.empty:Hide()

    -- Bottom bar: the one Import door + the Share Tag disclosure.
    local bottomSep = frame:CreateTexture(nil, "BORDER")
    bottomSep:SetTexture("Interface\\Buttons\\WHITE8x8")
    bottomSep:SetVertexColor(0.27, 0.27, 0.31, 0.5)
    bottomSep:SetHeight(1)
    bottomSep:SetPoint("BOTTOMLEFT", 1, BOTTOM_H)
    bottomSep:SetPoint("BOTTOMRIGHT", -3, BOTTOM_H)

    local import = CreateFrame("Button", nil, frame, "BackdropTemplate")
    import:SetSize(110, 22)
    import:SetPoint("BOTTOMLEFT", PAD, (BOTTOM_H - 22) / 2)
    import:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
    import:SetBackdropColor(0.16, 0.16, 0.20, 0.9)
    import:SetBackdropBorderColor(0.29, 0.29, 0.33, 1)
    import.text = import:CreateFontString(nil, "OVERLAY")
    Style.SetFont(import.text, 11)
    import.text:SetPoint("CENTER")
    import.text:SetText("Import ghost…")
    import:SetScript("OnEnter", function(self) self:SetBackdropBorderColor(Style.GetAccent()) end)
    import:SetScript("OnLeave", function(self) self:SetBackdropBorderColor(0.29, 0.29, 0.33, 1) end)
    import:SetScript("OnClick", function() StaticPopup_Show("KEYSTONEGHOST_IMPORT") end)

    frame.footer = frame:CreateFontString(nil, "OVERLAY")
    Style.SetFont(frame.footer, 10)
    frame.footer:SetPoint("BOTTOMRIGHT", -PAD, (BOTTOM_H - 10) / 2)
    frame.footer:SetTextColor(0.43, 0.43, 0.47)

    frame:SetScript("OnShow", function() Library:Refresh() end)
end

--- Rebuild the visible list from the pure model. Pools grow as needed; unused
--- widgets hide. Called on show and after every pin/delete/import action.
function Library:Refresh()
    if not frame or not frame:IsShown() then return end
    local S = KG.Scenario
    local groups = M.LibraryModel(KG.db.runs, KG.db.pick, function(mapID)
        return S:GetMapName(mapID)
    end)

    local usedG, usedR, y = 0, 0, 0
    for _, g in ipairs(groups) do
        usedG = usedG + 1
        local h = AcquireGroupHeader(usedG)
        h:SetPoint("TOPLEFT", 0, -y)
        h:SetPoint("TOPRIGHT", 0, -y)
        local n = #g.rows
        h.text:SetText(string.format("%s |cff6f6f78· %d ghost%s|r", g.name, n, n == 1 and "" or "s"))
        h.text:SetTextColor(Style.GetAccent())
        h:Show()
        y = y + GROUP_H

        for _, r in ipairs(g.rows) do
            usedR = usedR + 1
            local row = AcquireRow(usedR)
            r.groupName = g.name
            row.row = r
            row.pin.row, row.route.row, row.share.row, row.del.row = r, r, r, r
            row:SetPoint("TOPLEFT", 6, -y)
            row:SetPoint("TOPRIGHT", -2, -y)

            local depleted = r.tier == 0
            local a = depleted and 0.55 or 1
            row.lvl:SetText("+" .. r.level)
            row.lvl:SetAlpha(a)
            row.tier:SetText(depleted and "Depleted" or M.TierLabel(r.tier))
            local tc = TIER_COLOR[r.tier] or Style.TEXT
            row.tier:SetTextColor(tc[1], tc[2], tc[3])
            row.time:SetText(M.FormatClock(r.run.durationSec or 0))
            row.time:SetAlpha(a)
            row.date:SetText(DateShort(r.run.completedAt))
            row.date:SetAlpha(a * 0.8)
            local routeName = r.run.routeName and M.Ellipsize(M.StripColors(r.run.routeName), 28) or "—"
            row.route.text:SetText(routeName)
            row.route.text:SetTextColor(0.63, 0.63, 0.66)
            row.route.text:SetAlpha(a)
            row.route:EnableMouse(KG.Ghosts:RouteForHash(r.run.routeHash) ~= nil)
            row.owner:SetText(OwnerText(r))
            row.owner:SetAlpha(depleted and 0.65 or 1)

            -- Depleted: still never auto-raced/rostered/exported — the share button
            -- stays hidden — but PINNING is allowed (Fredrik 2026-07-21): an
            -- explicit pin is the player's deliberate "race my depleted attempt".
            row.pin:Show()
            if r.pinned then
                row.pin.tex:SetVertexColor(GOLD[1], GOLD[2], GOLD[3])
                row.pin:SetAlpha(1)
                row.edge:Show()
                row.bg:SetVertexColor(1, 1, 1, 0.05)
                row.bg:Show()
            else
                row.pin.tex:SetVertexColor(0.4, 0.4, 0.45)
                row.pin:SetAlpha(0.8)
                row.edge:Hide()
                row.bg:Hide()
            end
            row.share:SetShown(not depleted)
            row:Show()
            y = y + ROW_H
        end
    end
    for i = usedG + 1, #frame.groupPool do frame.groupPool[i]:Hide() end
    for i = usedR + 1, #frame.rowPool do frame.rowPool[i]:Hide() end
    frame.content:SetHeight(math.max(y, 1))
    frame.empty:SetShown(usedR == 0)

    local tag = KG.db.shareTag
    frame.footer:SetText(tag
        and ("Your Share Tag: " .. tag .. " — lets receivers group your alts' exports")
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
