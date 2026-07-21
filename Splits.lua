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
local MAX_LAPS = 4
local PAD = 12
local ROW_H = 14
local HEADER_H = 11
local frame

-- Column x-offsets within a row (icon occupies 0..14).
local COL_TAG, COL_DUR, COL_NOW, COL_LAP0, LAP_W = 18, 70, 106, 146, 41

local GREEN, RED, GRAY = "|cff4dcc4d", "|cffe65959", "|cff8c8c8c"

local function ColorDelta(sec, goodWhenPositive)
    local good = goodWhenPositive and sec >= 0 or (not goodWhenPositive and sec <= 0)
    return (good and GREEN or RED) .. M.FormatDelta(sec) .. "|r"
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

    -- Lap columns shown = most bosses any displayed ghost has (cap MAX_LAPS).
    local nLapCols = racedRun and math.min(MAX_LAPS, #(racedRun.bossKills or {})) or 0
    if st.roster then
        for _, e in ipairs(st.roster) do
            nLapCols = math.max(nLapCols, math.min(MAX_LAPS, #(e.run.bossKills or {})))
        end
    end
    for i = 1, MAX_LAPS do frame.hLaps[i]:SetShown(i <= nLapCols) end

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
        row.cNow:SetText(armed and ColorDelta(now, true) or (GRAY .. "0:00|r"))
        -- Identity-matched laps (SCENARIOS C2): column j is this ghost's j-th kill,
        -- paired with YOUR kill of the same encounterID; order fallback sans IDs.
        -- Kills seeded at /reload resume have fake timestamps — never shown as laps
        -- (same rule the bar's skull tooltips follow).
        local laps, lapMatch = M.LapDeltasByID(st.liveKills or {}, run.bossKills or {},
            st.liveIDs, run.bossIDs)
        for j = 1, MAX_LAPS do
            if j <= nLapCols then
                local kills = run.bossKills or {}
                local seeded = lapMatch[j] and st.seededKills and lapMatch[j] <= st.seededKills
                row.cLaps[j]:SetText((not seeded and laps[j]) and ColorDelta(laps[j], false)
                    or (kills[j] and (GRAY .. "—|r") or ""))
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
            row.icon:SetAlpha(1)
        else
            KG.Bar.ApplyRunnerIconTo(row.icon, run)
            -- Pairing color keyed to the ghost's STABLE roster position — matches
            -- its track runner, and a switch never recolors the survivors.
            local c = Style.PULL_COLORS[((colorIdx or n) - 1) % #Style.PULL_COLORS + 1]
            row.iconBorder:SetVertexColor(c[1], c[2], c[3])
            row.iconBorder:Show()
            -- NO fade in the roster (Fredrik 2026-07-20, Live Test 1): the dim
            -- belongs to the TRACK runners — there it makes rivals easy to
            -- dismiss mid-race; in the roster every row reads at full strength.
            row.icon:SetAlpha(1)
            row.iconBorder:SetAlpha(1)
        end
        row:Show()
    end

    -- STABLE order (Fredrik 2026-07-20, Live Test 1): the roster list never
    -- reorders on a switch or pin — the highlight moves to the raced row in
    -- place. The live RaiderIO ghost is not a roster member (live-only), so it
    -- leads the list while raced; a raced ghost that somehow fell off the
    -- roster cap still gets a row at the end rather than vanishing.
    local rows = {}
    if racedRun and ref.live then
        rows[#rows + 1] = { run = racedRun, tag = "RIO" }
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
    for _, entry in ipairs(rows) do
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
