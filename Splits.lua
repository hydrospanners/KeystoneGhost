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

local MAX_ROWS = 4
local MAX_LAPS = 4     -- column frames built (window shows at most LAP_WINDOW of them)
local LAP_WINDOW = 3   -- visible boss columns (Fredrik 2026-07-21: window slides on kills)
local PAD = 12
local ROW_H = 14
local HEADER_H = 11
local frame

-- Column x-offsets within a row (icon occupies 0..14).
local COL_TAG, COL_DUR, COL_NOW, COL_LAP0, LAP_W = 18, 70, 106, 146, 41

local GRAY = "|cff8c8c8c"

--- Verdict-colored delta (palette-aware — color vision setting swaps the pair).
local function ColorDelta(sec, goodWhenPositive)
    local good = goodWhenPositive and sec >= 0 or (not goodWhenPositive and sec <= 0)
    return "|cff" .. (good and Style.GoodHex() or Style.BadHex()) .. M.FormatDelta(sec) .. "|r"
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
function Splits.BuildDisplayRows(st)
    local ref = st.ref
    local racedRun = ref and ref.run
    local rows = {}
    local lead
    if racedRun and ref.live then
        lead = { run = racedRun, tag = "RIO", live = true }
    end
    for idx, entry in ipairs(st.roster or {}) do
        rows[#rows + 1] = { run = entry.run, tag = entry.tag, colorIdx = idx }
    end
    if racedRun and not ref.live then
        local present = false
        for _, e in ipairs(rows) do
            if e.run == racedRun then present = true break end
        end
        if not present then
            rows[#rows + 1] = { run = racedRun,
                tag = (racedRun.importedFrom and (racedRun.importedFrom:match("^([^%-]+)") or "import"))
                    or M.TierLabel(racedRun.chests) }
        end
    end

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
    frame.hTag = Col(frame.header, COL_TAG, 48, 9)
    frame.hTag:SetText("ghost")
    frame.hDur = Col(frame.header, COL_DUR, 34, 9)
    frame.hDur:SetText("time")
    frame.hNow = Col(frame.header, COL_NOW, 38, 9)
    frame.hNow:SetText("now")
    frame.hLaps = {}
    for i = 1, MAX_LAPS do
        frame.hLaps[i] = Col(frame.header, COL_LAP0 + (i - 1) * LAP_W, LAP_W - 2, 9)
        frame.hLaps[i]:SetText("B" .. i)
    end
    for _, h in ipairs({ frame.hTag, frame.hDur, frame.hNow }) do h:SetAlpha(0.55) end
    for _, h in ipairs(frame.hLaps) do h:SetAlpha(0.55) end

    -- Sortable headers (Fredrik 2026-07-21): click time/now to sort the rows
    -- (and the track lanes with them); click ghost to restore the priority
    -- order. Small buttons over the labels; the active one wears accent + ^/v.
    local function HeaderButton(fs, col, tipText)
        local b = CreateFrame("Button", nil, frame.header)
        b:SetPoint("LEFT", frame.header, "LEFT", fs:GetPoint(1) and select(4, fs:GetPoint(1)) or 0, 0)
        b:SetSize(fs:GetWidth(), HEADER_H)
        b:SetScript("OnClick", function() Splits.SetSort(col) end)
        b:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOPLEFT")
            GameTooltip:SetText(tipText, 0.9, 0.9, 0.9)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
        return b
    end
    HeaderButton(frame.hTag, nil, "Click: restore the normal roster order")
    HeaderButton(frame.hDur, "time", "Sort by ghost time (click again to flip)")
    HeaderButton(frame.hNow, "now", "Sort by current gap — the order freezes as of this click")

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

        row.cTag = Col(row, COL_TAG, 48)
        row.cDur = Col(row, COL_DUR, 34)
        row.cNow = Col(row, COL_NOW, 38)
        row.cLaps = {}
        for j = 1, MAX_LAPS do
            row.cLaps[j] = Col(row, COL_LAP0 + (j - 1) * LAP_W, LAP_W - 2)
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

--- Tooltip lines describing where a ghost came from.
local function RowTip(run, tag)
    local dateFn = date or os.date
    local tip = { tag .. " ghost — " .. M.FormatClock(run.durationSec or 0) }
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

    -- Sort indicators: the active header wears accent + a direction mark.
    local sort = KG.db.rosterSort
    local function HeaderText(fs, base, col)
        if sort and sort.col == col then
            fs:SetText("|cff" .. accentHex .. base .. (sort.desc and " v" or " ^") .. "|r")
        else
            fs:SetText(base)
        end
    end
    HeaderText(frame.hDur, "time", "time")
    HeaderText(frame.hNow, "now", "now")

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
    local nLapCols = math.min(LAP_WINDOW, maxB - winStart + 1)
    if maxB == 0 then nLapCols = 0 end
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

        row.cTag:SetText("|cff" .. accentHex .. tag .. "|r")
        row.cDur:SetText(M.FormatClock(run.durationSec or 0))
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
            row.cNow:SetText(isRaced and ColorDelta(now, true) or PlainDelta(now))
        else
            row.cNow:SetText(GRAY .. "0:00|r")
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
        SetRow(entry.run, entry.tag or M.TierLabel(entry.run.chests),
            entry.run == racedRun, entry.colorIdx)
    end
    if n == 0 then frame:Hide(); return end
    for i = n + 1, MAX_ROWS do frame.rows[i]:Hide() end

    frame:ClearAllPoints()
    frame:SetPoint("TOPLEFT", bar, "BOTTOMLEFT", 0, -4)
    frame:SetPoint("TOPRIGHT", bar, "BOTTOMRIGHT", 0, -4)
    frame:SetHeight(8 + HEADER_H + n * ROW_H)
    frame:Show()
end
