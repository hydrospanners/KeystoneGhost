-- The ghost roster — one row per ghost racing you, in fixed COLUMNS with a dim header
-- (ghost | time | now | B1..B4) so differences scan vertically (Fredrik 2026-07-19).
--
-- Docks under the race bar, skinned to match. The RACED row reads as active by the
-- row highlight (accent wash + edge bar) and its full-bright icon; non-raced rows'
-- icons fade, wearing MDT-palette pairing plates matching their track runners (the
-- pairing golds — roster plate, then the badge's ring — retired 2026-07-20; only
-- the pin lock glyph stays gold). Conventions: `now` matches the bar (positive =
-- ahead, green); boss laps are speedrun-style (negative = you killed it faster,
-- green). Color is the invariant.
local ADDON_NAME, NS = ...
local KG = NS.KG
local M = KG.Math
local Style = KG.Style

local Splits = {}
KG.Splits = Splits

-- Row FRAMES built. The Edit Mode roster-size slider still caps at 4 ghosts; the
-- extra frames exist because rows never leave mid-key (2026-07-29) — a full roster
-- plus a switch onto a ghost outside it needs somewhere to draw.
local MAX_ROWS = 6
local MAX_LAPS = 4     -- column frames built (window shows at most LAP_WINDOW of them)
local LAP_WINDOW = 3   -- visible boss columns (Fredrik 2026-07-21: window slides on kills)
local PAD = 12
local ROW_H = 14
local HEADER_H = 11
local frame

-- ── The columns (Fredrik 2026-07-29: `x name key chest time now B(n)`) ───────
--
-- The old `ghost` column carried three different facts by turns — a character
-- name, a chest tier (`+2`), and on near-level fillers a key level (`+11`) — so
-- two of them read as the same thing and none of them answered "is this ghost
-- worth chasing". One fact per column now, each switchable in Edit Mode, and the
-- x-offsets are COMPUTED from whichever are on rather than hardcoded.
--
-- Widths are for font size 10. The default set (everything but `route`) measures
-- 358 px against the bar's 360, so the panel keeps its docked width; switching
-- `route` on pushes past that and the panel grows wider than the bar rather than
-- squeezing the boss columns.
local COLUMNS = { -- his order, 2026-07-29: name · key · chest · route · time · now · B(n)
    { id = "name",  header = "name",  w = 44, db = "colName",  default = true },
    { id = "level", header = "key",   w = 24, db = "colKey",   default = true },
    -- `chest` wears the M+ chest ICON as its header when the client has one, and
    -- shrinks to 22 for it — the word is five characters to say what `+2` says in
    -- two (Fredrik 2026-07-29). Build() swaps both in; the width here is the
    -- word-fallback one.
    { id = "chest", header = "chest", w = 34, db = "colChest", default = true },
    { id = "route", header = "route", w = 84, db = "colRoute", default = false },
    { id = "time",  header = "time",  w = 34, db = "colTime",  default = true, sort = "time" },
    { id = "now",   header = "now",   w = 36, db = "colNow",   default = true, sort = "now" },
}
Splits.COLUMNS = COLUMNS -- EditMode builds one checkbox per entry
local ICON_W = 18 -- the runner icon's slot, ahead of the first column
local COL_GAP = 2
local LAP_W = 40
local PIN_W = 14  -- right gutter the pin glyph sits in

local GRAY = "|cff8c8c8c"

--- Is this column switched on? (`colLaps` follows the same rule, defaulting on.)
local function ColumnOn(col)
    local v = KG.db[col.db]
    if v == nil then return col.default end
    return v and true or false
end
Splits.ColumnOn = ColumnOn

--- x-offsets for the switched-on columns, plus the width the panel needs.
---
--- TWO CONTRACTS, by dock state (Fredrik 2026-07-29):
---   * **Free-floating** (`availW` nil) — the panel lays out every switched-on
---     column and the BAR follows its width, so the stack stays one window however
---     many columns you pick.
---   * **Docked** under the EllesmereUI timer (`availW` = that width) — the timer's
---     width is law. Columns are placed left to right while they fit and the rest
---     simply do not show: "if it is anchored to ellesmere then we just fix width
---     and ghost roster has a bunch of columns that doesn't show." The stop is
---     hard, not clever — the first column that will not fit ends the row, rather
---     than a narrower one behind it jumping the queue and scrambling the order.
--- Cached on the resulting signature; this runs on every refresh tick.
local layoutCache
local function Layout(availW)
    local laps = KG.db.colLaps ~= false
    local sig = (laps and "L" or "-") .. (availW and math.floor(availW) or "free")
    local x, cols = ICON_W, {}
    local spilled = false
    for _, c in ipairs(COLUMNS) do
        local on = ColumnOn(c)
        if on and availW and PAD + x + c.w + COL_GAP + PIN_W + PAD > availW then
            spilled = true -- and everything after it goes too
        end
        sig = sig .. (on and (spilled and "x" or "1") or "0")
        if on and not spilled then
            cols[#cols + 1] = { col = c, x = x }
            x = x + c.w + COL_GAP
        end
    end
    -- The FULL lap window is reserved whether or not the bosses are dead yet: a
    -- panel that changed width on your first kill would be worse than a gap. Docked,
    -- only the boss columns that fit are reserved at all.
    local lapSlots = 0
    if laps and not spilled then
        lapSlots = LAP_WINDOW
        if availW then
            lapSlots = math.max(0, math.min(LAP_WINDOW,
                math.floor((availW - (PAD + x + PIN_W + PAD)) / LAP_W)))
        end
    end
    sig = sig .. lapSlots
    if layoutCache and layoutCache.sig == sig then return layoutCache end
    layoutCache = { sig = sig, cols = cols, laps = laps, lapSlots = lapSlots, lapX = x,
        width = PAD + x + lapSlots * LAP_W + PIN_W + PAD }
    return layoutCache
end

--- Swap the chest column's header word for the client's M+ chest icon, and shrink
--- the column to suit (34 → 22: `+2` needs far less room than the word did). The
--- word and the wider slot stay when the client has no chest atlas to give, so the
--- header is never a blank cell. Called once from Build; safe to call again.
function Splits.ResolveChestHeader()
    for _, c in ipairs(COLUMNS) do
        if c.id == "chest" and c.header == "chest" then
            local icon = KG.Style and KG.Style.ChestIcon and KG.Style.ChestIcon(10)
            if icon then
                c.header, c.w = icon, 22
                layoutCache = nil -- widths moved: the cached offsets are stale
            end
        end
    end
end

--- The width every switched-on column needs, unconstrained — what the free-floating
--- BAR sizes itself to (Bar.FreeWidth), and what the offline suite measures.
function Splits.LayoutWidth() return Layout().width end

--- Which columns survive in `availW` (the docked case), as a list of ids — exposed
--- for the offline suite and for answering "what am I losing at this width".
function Splits.ColumnsFitting(availW)
    local out = {}
    for _, p in ipairs(Layout(availW).cols) do out[#out + 1] = p.col.id end
    return out
end

--- How many boss columns `availW` leaves room for (0 when it leaves none).
function Splits.LapSlotsFor(availW) return Layout(availW).lapSlots end

--- Verdict-colored delta (palette-aware — color vision setting swaps the pair).
local function ColorDelta(sec, goodWhenPositive)
    local good = goodWhenPositive and sec >= 0 or (not goodWhenPositive and sec <= 0)
    return (good and Style.GoodEscape() or Style.BadEscape()) .. M.FormatDelta(sec) .. "|r"
end

--- Neutral delta for NON-ACTIVE rows (Fredrik 2026-07-21: "too many colors
--- that draw attention" — only the raced row speaks verdict red/green).
local function PlainDelta(sec)
    return M.FormatDelta(sec)
end

-- ── Row order: ONE source for the Roster Panel AND the track's runner lanes ──
--
-- Base order = the stable priority chain (RIO lead while raced → roster →
-- fallback raced row). Fredrik 2026-07-21: clicking the time/now headers
-- re-sorts DELIBERATELY (the 2026-07-20 stability rule bans the SYSTEM
-- reordering rows, not the player); the track runners' vertical lanes follow
-- this same order, so a sort re-lanes the icons too. Pairing colors stay
-- keyed to the ghost's BASE roster position — sorting moves rows, never
-- recolors a ghost. "now" sorts on a SNAPSHOT taken at click time (a live
-- re-sort every tick would make the rows dance); "time" is static data.
local nowRankCache -- { roster = <st.roster ref>, desc = bool, bump = n, rank = {[run]=i} }
local sortBump = 0

local function NowValue(run, st)
    return M.GhostTimeFor(run, st.raw, st.bosses, st.total) - st.elapsed
end

local function EnsureNowRanks(rows, st, desc)
    local c = nowRankCache
    if c and c.roster == st.roster and c.desc == desc and c.bump == sortBump then return c.rank end
    local order = {}
    for i, e in ipairs(rows) do order[#order + 1] = { run = e.run, v = NowValue(e.run, st), i = i } end
    table.sort(order, function(a, b)
        if a.v ~= b.v then
            if desc then return a.v > b.v end
            return a.v < b.v
        end
        return a.i < b.i
    end)
    local rank = {}
    for i, o in ipairs(order) do rank[o.run] = i end
    nowRankCache = { roster = st.roster, desc = desc, bump = sortBump, rank = rank }
    return rank
end

--- The display row list (shared with Bar.lua's runner lanes). Each entry:
--- { run, tag, colorIdx (base pairing position), live (RIO lead) }.
---
--- Rows only ever ARRIVE during a key (Fredrik 2026-07-29: "don't remove rows from
--- the ghost roster after a key has started"). A ghost that is not a roster member
--- used to be drawn only while it was RACED — so switching away from the Raider.IO
--- ghost, which is priority 5 and often crowded out, deleted the very row you would
--- click to switch back. Every row drawn is remembered by the Recorder and re-offered
--- here for the rest of the key, carrying its original tag and pairing color.
function Splits.BuildDisplayRows(st)
    local ref = st.ref
    local racedRun = ref and ref.run
    local rows = {}
    local seen = {}
    local function Add(entry)
        if entry.run and not seen[entry.run] then
            seen[entry.run] = true
            rows[#rows + 1] = entry
        end
    end
    local lead
    if racedRun and ref.live then
        lead = { run = racedRun, tag = "RIO", live = true }
        seen[racedRun] = true -- inserted at the front once the sort is done
    end
    for idx, entry in ipairs(st.roster or {}) do
        -- While the live MIRROR leads (degraded path), the stored Raider.IO row
        -- would be a second "RIO" line — possibly a different replay. One RIO
        -- identity on screen at a time; the stored row returns when the mirror
        -- leaves. Display-only, so the stable-order rule is untouched.
        if not (lead and entry.run.legacy == "RIO") then
            Add({ run = entry.run, tag = entry.tag, colorIdx = idx })
        end
    end
    for _, entry in ipairs(st.shown or {}) do -- rows this key has already drawn
        -- The rule stops the SYSTEM from taking a row away; the player still can.
        -- Hiding a ghost in the Library (the eye) is exactly that, so a hidden run
        -- leaves even though it was on screen a moment ago.
        if not entry.run.hidden and not (lead and entry.run.legacy == "RIO") then
            Add({ run = entry.run, tag = entry.tag, colorIdx = entry.colorIdx })
        end
    end
    if racedRun and not ref.live then -- a switch onto a ghost no list offered yet
        -- Tag chain hoisted to M.RunTag (2026-08-07, the End Screen shares it).
        -- A pace car has no chests, and TierLabel called it "?" — which is
        -- what a player with no ghosts and no Raider.IO saw on row 1; hence
        -- the kind steps before the tier fallback.
        Add({ run = racedRun, tag = M.RunTag(racedRun, ref.kind) })
    end
    if lead then KG.Recorder:NoteShownRow(lead) end
    for _, e in ipairs(rows) do KG.Recorder:NoteShownRow(e) end

    local sort = KG.db.rosterSort
    if sort and sort.col == "time" then
        local baseIdx = {}
        for i, e in ipairs(rows) do baseIdx[e] = i end
        table.sort(rows, function(a, b)
            local av, bv = a.run.durationSec or 0, b.run.durationSec or 0
            if av ~= bv then
                if sort.desc then return av > bv end
                return av < bv
            end
            return baseIdx[a] < baseIdx[b]
        end)
    elseif sort and sort.col == "now" then
        local rank = EnsureNowRanks(rows, st, sort.desc)
        local baseIdx = {}
        for i, e in ipairs(rows) do baseIdx[e] = i end
        table.sort(rows, function(a, b)
            local ar, br = rank[a.run], rank[b.run]
            if ar and br and ar ~= br then return ar < br end
            if ar and not br then return true end
            if br and not ar then return false end
            return baseIdx[a] < baseIdx[b]
        end)
    end

    -- The live RIO ghost leads the list regardless of sort (it is the raced
    -- reference, never a sortable roster member).
    if lead then table.insert(rows, 1, lead) end
    return rows
end

--- Header click: sort by col (repeat click flips direction), "ghost" resets.
function Splits.SetSort(col)
    local cur = KG.db.rosterSort
    if not col then
        KG.db.rosterSort = nil
    elseif cur and cur.col == col then
        KG.db.rosterSort = { col = col, desc = not cur.desc }
    else
        -- First click defaults: time = fastest first (asc); now = biggest lead first (desc).
        KG.db.rosterSort = { col = col, desc = (col == "now") }
    end
    sortBump = sortBump + 1
    Splits:Refresh()
    KG.Bar:Refresh()
end

local function Col(parent, x, w, size)
    local fs = parent:CreateFontString(nil, "OVERLAY")
    fs:SetPoint("LEFT", x, 0)
    fs:SetWidth(w)
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(false)
    Style.SetFont(fs, size or 10)
    fs:SetTextColor(Style.TEXT[1], Style.TEXT[2], Style.TEXT[3])
    return fs
end

local function Build()
    frame = CreateFrame("Frame", "KeystoneGhostSplits", UIParent, "BackdropTemplate")
    Style.SkinPanel(frame)

    -- Header row: dim column labels, so data rows carry no repeated text.
    frame.header = CreateFrame("Frame", nil, frame)
    frame.header:SetPoint("TOPLEFT", PAD, -4)
    frame.header:SetPoint("TOPRIGHT", -PAD, -4)
    frame.header:SetHeight(HEADER_H)
    -- Every column's widget exists from the start; the layout pass decides which
    -- ones are placed and shown. Cheaper than building on toggle, and it keeps
    -- Edit Mode's checkboxes instant.
    Splits.ResolveChestHeader()
    frame.hCells = {}
    for _, c in ipairs(COLUMNS) do
        local fs = Col(frame.header, 0, c.w, 9)
        fs:SetText(c.header)
        fs:SetAlpha(0.55)
        frame.hCells[c.id] = fs
    end
    frame.hLaps = {}
    for i = 1, MAX_LAPS do
        frame.hLaps[i] = Col(frame.header, 0, LAP_W - 2, 9)
        frame.hLaps[i]:SetText("B" .. i)
        frame.hLaps[i]:SetAlpha(0.55)
    end

    -- Sortable headers (Fredrik 2026-07-21): click time/now to sort the rows
    -- (and the track lanes with them); click ghost to restore the priority
    -- order. NO tooltips ("too cluttering", same day) — the only hover cue is
    -- Ellesmere's own sort-header recipe (BlizzardSkin SortHeaderBar): a solid
    -- white HIGHLIGHT-layer wash at 10%, drawn by the engine only while
    -- hovered. The active header wears accent + ^/v (state, not hover).
    local function HeaderButton(col)
        local b = CreateFrame("Button", nil, frame.header)
        b:SetSize(col.w, HEADER_H)
        b:SetScript("OnClick", function() Splits.SetSort(col.sort) end)
        local hov = b:CreateTexture(nil, "HIGHLIGHT")
        hov:SetTexture("Interface\\Buttons\\WHITE8x8")
        hov:SetVertexColor(1, 1, 1, 0.1)
        hov:SetAllPoints(b)
        return b
    end
    -- `name` has no sort of its own: clicking it restores the priority order (it
    -- inherits what the old `ghost` header did).
    frame.hButtons = {}
    for _, c in ipairs(COLUMNS) do
        if c.sort or c.id == "name" then frame.hButtons[c.id] = HeaderButton(c) end
    end

    frame.rows = {}
    for i = 1, MAX_ROWS do
        local row = Style.Hover(frame, 10, ROW_H)
        local y = -4 - HEADER_H - (i - 1) * ROW_H
        row:SetPoint("TOPLEFT", PAD, y)
        row:SetPoint("TOPRIGHT", -PAD, y)

        -- Runner icon + ROUND pairing plate, mirrored from the track (Fredrik
        -- 2026-07-20, Live Test 1: square frames read as clutter — round or no
        -- color). Tinted circle texture; the round class icon leaves it as a ring.
        row.iconBorder = row:CreateTexture(nil, "ARTWORK")
        row.iconBorder:SetSize(14, 14)
        row.iconBorder:SetPoint("LEFT", 0, 0)
        row.iconBorder:SetTexture("Interface\\CHARACTERFRAME\\TempPortraitAlphaMaskSmall")
        row.icon = row:CreateTexture(nil, "OVERLAY")
        row.icon:SetSize(10, 10)
        row.icon:SetPoint("LEFT", 2, 0)

        row.cells = {}
        for _, c in ipairs(COLUMNS) do row.cells[c.id] = Col(row, 0, c.w) end
        row.cLaps = {}
        for j = 1, MAX_LAPS do
            row.cLaps[j] = Col(row, 0, LAP_W - 2)
        end

        -- Raced-row highlight: accent edge bar + faint wash.
        row.marker = row:CreateTexture(nil, "OVERLAY")
        row.marker:SetTexture("Interface\\Buttons\\WHITE8x8")
        row.marker:SetSize(2, ROW_H - 3)
        row.marker:SetPoint("LEFT", row, "LEFT", -7, 0)
        row.marker:Hide()
        row.bg = row:CreateTexture(nil, "BACKGROUND")
        row.bg:SetTexture("Interface\\Buttons\\WHITE8x8")
        row.bg:SetPoint("TOPLEFT", -9, 1)
        row.bg:SetPoint("BOTTOMRIGHT", 4, 1)
        row.bg:Hide()

        -- Hovering a row lights its runner on the bar.
        row.onEnterExtra = function(self) KG.Bar.SetPreviewRun(self.runRef) end
        row.onLeaveExtra = function() KG.Bar.SetPreviewRun(nil) end

        -- Row click = the Raced-Ghost Switch (S9): a non-raced row races this ghost
        -- and pins it; the raced row toggles the pin. Shift-click with the chat
        -- editbox open inserts the chat share link instead (3b — same gesture as
        -- the Ghost Library rows); without an editbox it falls through to the
        -- normal click, and non-stored runs (the live RaiderIO mirror) always do.
        row:SetScript("OnMouseUp", function(self, button)
            if button ~= "LeftButton" then return end
            if IsShiftKeyDown() and KG.Comm then
                local ck, mid, lvl, tier = KG.Ghosts:FindRunOwner(self.runRef)
                if ck == KG.RIO_CHAR then ck = nil end -- not shareable: fall through to the race click
                if ck then
                    local name = KG.Scenario:GetMapName(mid) or ("map " .. mid)
                    local pretty = string.format("%s +%d (%s)", name, lvl,
                        M.FormatClock(self.runRef.durationSec or 0))
                    if KG.Comm.InsertShareLink(ck, mid, lvl, tier, pretty) then return end
                end
            end
            KG.Bar.HandleRowClick(self.runRef)
        end)
        -- Pin glyph, shown on the raced row while pinned: auto-switches are off.
        -- A map-pin, not a lock (Fredrik 2026-07-21 — the lock read wrong); the
        -- Ghost Library rows wear the same atlas, desaturated so the gold speaks.
        row.pin = row:CreateTexture(nil, "OVERLAY")
        row.pin:SetSize(12, 12)
        row.pin:SetPoint("RIGHT", row, "RIGHT", 2, 0)
        row.pin:SetAtlas("Waypoint-MapPin-Tracked")
        row.pin:SetDesaturated(true)
        row.pin:SetVertexColor(1, 0.82, 0.15)
        row.pin:Hide()
        frame.rows[i] = row
    end
    frame:Hide()
end

--- The row's ghost in a sentence: the `name` cell reads "you", a title does not.
function Splits.RowTitle(tag)
    return tag == "you" and "Your" or (tag or "?")
end

--- Tooltip lines describing where a ghost came from.
local function RowTip(run, tag)
    local dateFn = date or os.date
    local tip = { Splits.RowTitle(tag) .. " ghost — " .. M.FormatClock(run.durationSec or 0) }
    if run.legacy == "RIO" then
        tip[#tip + 1] = "Converted Raider.IO " .. (run.rioSource or "replay")
    end
    if run.level then tip[#tip + 1] = string.format("Key level: +%d · %s", run.level, M.TierLabel(run.chests)) end
    if run.completedAt and dateFn then
        local okD, d = pcall(dateFn, "%Y-%m-%d", run.completedAt)
        if okD and type(d) == "string" then tip[#tip + 1] = "Recorded: " .. d end
    end
    if run.routeName then tip[#tip + 1] = "Route: " .. run.routeName end
    if run.importedFrom then tip[#tip + 1] = "From: " .. run.importedFrom end
    if run.deathCount and run.deathCount > 0 then tip[#tip + 1] = "Deaths: " .. run.deathCount end
    return tip
end

function Splits:Refresh()
    if not frame then Build() end
    if KG.db.splits == false or (KG.db.enabled == false and not KG.editModePreview) then
        frame:Hide(); return
    end

    local st = KG.Bar.GetLiveState()
    local bar = KG.Bar.GetFrame()
    if not st or not bar or not bar:IsShown() then frame:Hide(); return end

    Style.RefreshPanel(frame)
    local accentHex = Style.AccentHex()
    local ref = st.ref
    local racedRun = ref and ref.run
    local n = 0

    -- Column layout: place whatever is switched on, hide the rest, and re-anchor
    -- only when the on/off set actually changed. Docked, the timer's width is the
    -- budget and the columns are fitted to it; free, the bar follows the columns.
    local barW = bar:GetWidth() or 0
    local docked = KG.Bar.IsDocked and KG.Bar.IsDocked()
    local L = Layout(docked and barW > 0 and barW or nil)
    if frame.layoutSig ~= L.sig then
        frame.layoutSig = L.sig
        local function Place(region, x)
            region:ClearAllPoints()
            region:SetPoint("LEFT", x, 0)
            region:Show()
        end
        local placed = {}
        for _, p in ipairs(L.cols) do
            placed[p.col.id] = true
            Place(frame.hCells[p.col.id], p.x)
            local b = frame.hButtons[p.col.id]
            if b then
                b:ClearAllPoints()
                b:SetPoint("LEFT", frame.header, "LEFT", p.x, 0)
                b:Show()
            end
            for _, row in ipairs(frame.rows) do Place(row.cells[p.col.id], p.x) end
        end
        for _, c in ipairs(COLUMNS) do
            if not placed[c.id] then
                frame.hCells[c.id]:Hide()
                if frame.hButtons[c.id] then frame.hButtons[c.id]:Hide() end
                for _, row in ipairs(frame.rows) do row.cells[c.id]:Hide() end
            end
        end
        for j = 1, MAX_LAPS do
            local x = L.lapX + (j - 1) * LAP_W
            Place(frame.hLaps[j], x) -- shown/hidden per kill count below
            for _, row in ipairs(frame.rows) do Place(row.cLaps[j], x) end
        end
    end

    -- Sort indicators: the active header wears accent + a direction mark.
    local sort = KG.db.rosterSort
    local function HeaderText(id, base, col)
        local fs = frame.hCells[id]
        if sort and sort.col == col then
            fs:SetText("|cff" .. accentHex .. base .. (sort.desc and " v" or " ^") .. "|r")
        else
            fs:SetText(base)
        end
    end
    HeaderText("time", "time", "time")
    HeaderText("now", "now", "now")

    -- Boss-column WINDOW (Fredrik 2026-07-21): at most LAP_WINDOW columns. The
    -- window slides on YOUR kills — after your 2nd kill B1 leaves (kill 2 is
    -- the reference running at 3), after the 3rd B2 leaves, etc. maxB = most
    -- bosses any displayed ghost has.
    local maxB = racedRun and #(racedRun.bossKills or {}) or 0
    if st.roster then
        for _, e in ipairs(st.roster) do
            maxB = math.max(maxB, #(e.run.bossKills or {}))
        end
    end
    local winStart = math.min(math.max(1, (st.bosses or 0) - 1), math.max(1, maxB - LAP_WINDOW + 1))
    local nLapCols = math.min(L.lapSlots, maxB - winStart + 1)
    if maxB == 0 or not L.laps then nLapCols = 0 end
    for i = 1, MAX_LAPS do
        if i <= nLapCols then
            frame.hLaps[i]:SetText("B" .. (winStart + i - 1))
            frame.hLaps[i]:Show()
        else
            frame.hLaps[i]:Hide()
        end
    end

    local aR, aG, aB = Style.GetAccent()
    local function SetRow(run, tag, isRaced, colorIdx)
        n = n + 1
        local row = frame.rows[n]
        row.runRef = run
        row.tip = RowTip(run, tag)

        local cell = row.cells
        -- name: WHOSE ghost this is and nothing else — your own runs read "you",
        -- an alt or a sender reads their character name, the replay reads RIO.
        -- Ellipsized rather than clipped: a long name should say it was cut.
        cell.name:SetText("|cff" .. accentHex .. M.Ellipsize(tag, 8) .. "|r")
        -- key: plain when it matches the key you are IN, grey when it does not —
        -- the one thing that says whether this ghost's time is worth chasing
        -- (Fredrik 2026-07-29). Pace cars (season best / par) carry no level.
        if run.level then
            local off = st.level and run.level ~= st.level
            cell.level:SetText((off and GRAY or "") .. "+" .. run.level .. (off and "|r" or ""))
        else
            cell.level:SetText(GRAY .. "—|r")
        end
        -- chest: the run's RESULT — the upgrade level, or a RED dash when the key
        -- depleted (his call 2026-07-29; the Library still spells "Depleted" out,
        -- but a 22 px column under a chest icon says it in one character, and the
        -- COLOR is what separates it from the grey dash meaning "no chests to report",
        -- which is what a pace car shows). BadHex, so color-vision modes swap it.
        if run.chests then
            cell.chest:SetText(run.chests > 0 and M.TierLabel(run.chests)
                or (Style.BadEscape() .. "—|r"))
        else
            cell.chest:SetText(GRAY .. "—|r")
        end
        -- route: "n/a" on a replay (it cannot carry one) reads differently from
        -- "—" for a run recorded without one — the Ghost Library's distinction.
        local routeName = run.routeName and M.Ellipsize(M.StripColors(run.routeName), 13)
            or (run.legacy == "RIO" and "n/a" or "—")
        cell.route:SetText(GRAY .. routeName .. "|r")
        cell.time:SetText(M.FormatClock(run.durationSec or 0))
        -- Per-row Gap arming (SCENARIOS B9): each ghost's `now` stays a grey 0:00
        -- until both YOU and THAT ghost have progress — same rule as the bar's Gap.
        -- Live state goes in as (count, total): exact integers same-total, fraction
        -- space cross-total — the same math the bar's Gap runs on.
        local now, armed
        if isRaced and ref and ref.live then
            now = M.LiveDelta(run, ref.nowCount or 0, ref.nowBosses or 0,
                st.liveRun or { snapshots = {} }, st.elapsed, st.raw, st.bosses, st.total)
            armed = M.HasProgress(st.raw, st.bosses)
                and M.HasProgress(ref.nowCount, ref.nowBosses)
        else
            now = M.GhostTimeFor(run, st.raw, st.bosses, st.total) - st.elapsed
            armed = M.HasProgress(st.raw, st.bosses)
                and M.HasProgress(M.SampleAt(run.snapshots or {}, st.elapsed))
        end
        -- Verdict colors belong to the ACTIVE row alone (Fredrik 2026-07-21:
        -- "too many colors that draw attention"); non-raced rows read neutral.
        if armed then
            cell.now:SetText(isRaced and ColorDelta(now, true) or PlainDelta(now))
        else
            cell.now:SetText(GRAY .. "0:00|r")
        end
        -- Identity-matched laps (SCENARIOS C2): the visible window's column j is
        -- boss winStart+j-1 — this ghost's kill of that ordinal, paired with
        -- YOUR kill of the same encounterID; order fallback sans IDs. Kills
        -- seeded at /reload resume have fake timestamps — never shown as laps
        -- (same rule the bar's skull tooltips follow).
        local laps, lapMatch = M.LapDeltasByID(st.liveKills or {}, run.bossKills or {},
            st.liveIDs, run.bossIDs)
        for j = 1, MAX_LAPS do
            if j <= nLapCols then
                local bi = winStart + j - 1
                local kills = run.bossKills or {}
                local seeded = lapMatch[bi] and st.seededKills and lapMatch[bi] <= st.seededKills
                local txt
                if not seeded and laps[bi] then
                    txt = isRaced and ColorDelta(laps[bi], false) or PlainDelta(laps[bi])
                else
                    txt = kills[bi] and (GRAY .. "—|r") or ""
                end
                row.cLaps[j]:SetText(txt)
                row.cLaps[j]:Show()
            else
                row.cLaps[j]:Hide()
            end
        end

        row.marker:SetVertexColor(aR, aG, aB, 0.95)
        row.marker:SetShown(isRaced)
        -- Switch presentation (S7, "don't announce — just show"): the highlight
        -- ARRIVING is the announcement — a brief glow decay after a switch, no banner.
        -- Base wash carries the active mark alone since the gold plate left (0.08 was
        -- tuned as a secondary cue and vanished without it).
        local glowA = 0.14
        if isRaced and st.lastSwitch then
            local age = GetTime() - st.lastSwitch.at
            if age < 1.2 then glowA = glowA + 0.3 * (1 - age / 1.2) end
        end
        row.bg:SetVertexColor(aR, aG, aB, glowA)
        row.bg:SetShown(isRaced)
        row.pin:SetShown(isRaced and st.pinned or false)
        row.tip[#row.tip + 1] = isRaced
            and (st.pinned and "Pinned — click to unpin (auto-switches resume)"
                or "Click to pin (blocks auto-switches)")
            or "Click to race this ghost (pins it)"
        if isRaced then
            -- Active = the accent-highlighted row with a plate-less icon (the
            -- marker + wash carry the mark; pairing plates belong to fillers).
            KG.Bar.ApplyRefIconTo(row.icon, ref)
            row.icon:SetSize(10, 10) -- the applier sizes for the track badge; re-pin
            row.iconBorder:Hide() -- filler rows reuse this plate; the raced row wears none
            row:SetAlpha(1)
        else
            KG.Bar.ApplyRunnerIconTo(row.icon, run)
            -- Pairing color keyed to the ghost's BASE roster position — matches
            -- its track runner; neither a switch NOR a header sort recolors it.
            local c = Style.PULL_COLORS[((colorIdx or n) - 1) % #Style.PULL_COLORS + 1]
            row.iconBorder:SetVertexColor(c[1], c[2], c[3])
            row.iconBorder:Show()
            row.icon:SetAlpha(1)
            row.iconBorder:SetAlpha(1)
            -- Light whole-row fade on non-active rows (Fredrik 2026-07-21,
            -- superseding the Live-Test-1 "no roster fade": ~15% back-seat so
            -- the raced row owns the attention).
            row:SetAlpha(0.85)
        end
        row:Show()
    end

    -- ONE row order for the panel AND the track lanes (BuildDisplayRows):
    -- stable priority chain by default; the time/now headers re-sort it on
    -- the player's explicit click (the system itself still never reorders).
    for _, entry in ipairs(Splits.BuildDisplayRows(st)) do
        if n >= MAX_ROWS then break end
        SetRow(entry.run, entry.tag or "you", entry.run == racedRun, entry.colorIdx)
    end
    if n == 0 then frame:Hide(); return end
    for i = n + 1, MAX_ROWS do frame.rows[i]:Hide() end

    frame:ClearAllPoints()
    frame:SetPoint("TOPLEFT", bar, "BOTTOMLEFT", 0, -4)
    -- The panel always ends where the bar ends. Docked that is the timer's width
    -- and Layout has already dropped whatever did not fit; free, the bar has
    -- widened to the columns (Bar.FreeWidth), so the two agree either way. An
    -- explicit width rather than a second anchor, re-set every refresh so a resize
    -- of the docked timer carries immediately.
    frame:SetWidth(barW > 0 and barW or L.width)
    frame:SetHeight(8 + HEADER_H + n * ROW_H)
    frame:Show()
end
