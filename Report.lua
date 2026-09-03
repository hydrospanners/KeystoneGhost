-- Report.lua — the Finish Report (F6, built 2026-08-25 on his approved mockup
-- docs/MOCKUP-FINISH-REPORT.html and the W0/W3 rulings, 2026-08-24):
--
--   · Its OWN floating window — the race bar CLOSES when it opens, never grows.
--     Dragged by the title strip; position sticks (db.reportPos); Edit Mode's
--     scale slider rides along (db.scale); ESC closes (UISpecialFrames).
--   · Opens on EVERY finish, depletes included (his call — the chest-math line
--     hits hardest right after a deplete). /kg test keeps the bar's photo
--     instead: the gallery retake (#98-101) still shoots that look, and a
--     window popping every demo loop would read wrong.
--   · The celebration MOVES here, it does not die (his ask, guaranteed in
--     TASKS F6): the drawn checkered flag + the hopping portrait live in the
--     hero band. Deplete: no flag, no hop.
--   · Reopenable from the Ghost Library via the magnifier on any stored row
--     (reduced sections: a stored ghost has no opponent to report against).
--
-- Sections, top down: hero (clock + tier + verdict + score + flag) · vs the
-- raced ghost (finish gap + the closest-ghost board rows) · splits (every
-- matched boss, YOUR clock vs the ghost's — the photo's two-lap band retired
-- for this) · the run (deaths + timeline strip, forces, chest math) · the
-- personal-best line (F4's mark). Score shows for TIMED runs only, and only
-- while Data_Score.lua's season fingerprint matches the live roster.
local ADDON_NAME, NS = ...
local KG = NS.KG
local M = KG.Math

local Report = {}
KG.Report = Report

local WIDTH, PAD = 380, 12
local TITLE_H = 20
local DIM = { 0.55, 0.55, 0.58 }
local WHITE = { 0.85, 0.85, 0.88 }

local frame -- built lazily
local mode -- "live" | "stored"
local liveSummary -- the R.summary this window currently owns (live mode)

-- ── the score gate ────────────────────────────────────────────────────────────
-- Data_Score.lua stamps the season's dungeon roster at sampling time; a new
-- season retunes the values, so a roster mismatch hides the score line rather
-- than render stale numbers. Resolved once per session.
local scoreOK
local function ScoreTable()
    if scoreOK == nil then
        local base = KG.SCORE_BASE
        if not base then
            scoreOK = false
            return nil
        end
        local ok, ids = pcall(function()
            return KG.Scenario and KG.Scenario.GetSeasonMapIDs and KG.Scenario:GetSeasonMapIDs()
        end)
        if not ok then ids = nil end
        -- An UNREADABLE roster stays undecided (council 2026-08-25): the season
        -- map table fills asynchronously after login, and latching false on an
        -- early Library-opened report would hide the score all session. Only a
        -- genuinely readable roster settles the verdict, either way.
        if type(ids) ~= "table" or #ids == 0 then return nil end
        if #ids ~= #base.roster then
            scoreOK = false
            return nil
        end
        local live = {}
        for i = 1, #ids do live[i] = ids[i] end
        table.sort(live)
        scoreOK = true
        for i = 1, #live do
            if live[i] ~= base.roster[i] then scoreOK = false break end
        end
    end
    return scoreOK and KG.SCORE_BASE or nil
end

-- ── widget pools ──────────────────────────────────────────────────────────────
local lines -- plain full-width font strings
local rows -- 4-column table rows { left, mine, ref, delta }
local seps -- 1px separators
local stones -- death-strip tombstones (the addon's one death mark)

local function Line(i)
    local fs = lines[i]
    if not fs then
        fs = frame:CreateFontString(nil, "OVERLAY")
        fs:SetPoint("LEFT", frame, "LEFT", PAD, 0)
        fs:SetJustifyH("LEFT")
        fs:SetWordWrap(false)
        lines[i] = fs
    end
    fs:Show()
    return fs
end

local function Row(i)
    local r = rows[i]
    if not r then
        r = {}
        r.left = frame:CreateFontString(nil, "OVERLAY")
        r.left:SetJustifyH("LEFT"); r.left:SetWordWrap(false)
        KG.Style.SetFont(r.left, 10)
        r.mine = frame:CreateFontString(nil, "OVERLAY")
        r.mine:SetJustifyH("RIGHT"); r.mine:SetWordWrap(false)
        KG.Style.SetFont(r.mine, 10)
        r.ref = frame:CreateFontString(nil, "OVERLAY")
        r.ref:SetJustifyH("RIGHT"); r.ref:SetWordWrap(false)
        KG.Style.SetFont(r.ref, 10)
        r.delta = frame:CreateFontString(nil, "OVERLAY")
        r.delta:SetJustifyH("RIGHT"); r.delta:SetWordWrap(false)
        KG.Style.SetFont(r.delta, 10)
        rows[i] = r
    end
    r.left:Show(); r.mine:Show(); r.ref:Show(); r.delta:Show()
    return r
end

local function PlaceRow(r, y)
    r.left:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, y)
    r.mine:SetPoint("TOPRIGHT", frame, "TOPLEFT", 190, y)
    r.ref:SetPoint("TOPRIGHT", frame, "TOPLEFT", 275, y)
    r.delta:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -PAD, y)
end

local function Sep(i, y)
    local t = seps[i]
    if not t then
        t = frame:CreateTexture(nil, "ARTWORK")
        t:SetTexture("Interface\\Buttons\\WHITE8x8")
        t:SetVertexColor(0.16, 0.16, 0.20, 0.8)
        t:SetHeight(1)
        seps[i] = t
    end
    t:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, y)
    t:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -PAD, y)
    t:Show()
    return t
end

local function HideFrom(pool, n)
    for i = n + 1, #pool do
        local w = pool[i]
        if w.left then w.left:Hide(); w.mine:Hide(); w.ref:Hide(); w.delta:Hide()
        else w:Hide() end
    end
end

-- ── construction ──────────────────────────────────────────────────────────────
local function Build()
    if frame then return frame end
    local Style = KG.Style
    frame = CreateFrame("Frame", "KeystoneGhostReport", UIParent, "BackdropTemplate")
    frame:SetSize(WIDTH, 300)
    frame:SetFrameStrata("HIGH")
    frame:SetMovable(true)
    frame:SetClampedToScreen(true)
    Style.SkinPanel(frame)
    frame:Hide()
    table.insert(UISpecialFrames, "KeystoneGhostReport") -- ESC closes

    local pos = KG.db.reportPos
    if pos and pos.point then
        frame:SetPoint(pos.point, UIParent, pos.point, pos.x or 0, pos.y or 0)
    else
        frame:SetPoint("CENTER")
    end

    -- The whole window drags (#150, his ask): any grab that no interactive
    -- child swallows moves it — Share/Close/× are Buttons above the frame and
    -- keep their own clicks, FontStrings never take the mouse. The title strip
    -- keeps its own identical handlers; its grip dashes stay the visual hint.
    local function StartDrag() frame:StartMoving() end
    local function StopDrag()
        frame:StopMovingOrSizing()
        local point, _, _, x, y = frame:GetPoint()
        KG.db.reportPos = { point = point, x = x, y = y }
    end
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", StartDrag)
    frame:SetScript("OnDragStop", StopDrag)
    local title = CreateFrame("Frame", nil, frame)
    title:SetPoint("TOPLEFT")
    title:SetPoint("TOPRIGHT")
    title:SetHeight(TITLE_H)
    title:EnableMouse(true)
    title:RegisterForDrag("LeftButton")
    title:SetScript("OnDragStart", StartDrag)
    title:SetScript("OnDragStop", StopDrag)
    frame.titleText = title:CreateFontString(nil, "OVERLAY")
    frame.titleText:SetPoint("LEFT", PAD, 0)
    Style.SetFont(frame.titleText, 10)
    frame.titleText:SetTextColor(0.63, 0.63, 0.66)
    frame.dateText = title:CreateFontString(nil, "OVERLAY")
    frame.dateText:SetPoint("RIGHT", -32, 0)
    Style.SetFont(frame.dateText, 10)
    frame.dateText:SetTextColor(DIM[1], DIM[2], DIM[3])
    for i = 1, 3 do
        local dash = title:CreateTexture(nil, "OVERLAY")
        dash:SetTexture("Interface\\Buttons\\WHITE8x8")
        dash:SetVertexColor(0.29, 0.26, 0.34, 0.9)
        dash:SetSize(6, 2)
        dash:SetPoint("TOP", title, "TOP", (i - 2) * 9, -5)
    end
    -- The × rides the title strip exactly like the Library's (#149: the
    -- Style.CloseButton contract is caller-anchors, and this caller forgot).
    local close = Style.CloseButton(title, function() frame:Hide() end)
    close:SetPoint("RIGHT", -8, 0)

    -- Hero: the clock, the verdict line, the score block, the celebration.
    frame.heroTime = frame:CreateFontString(nil, "OVERLAY")
    frame.heroTime:SetPoint("TOPLEFT", PAD, -(TITLE_H + 6))
    Style.SetFont(frame.heroTime, 22)
    frame.heroSub = frame:CreateFontString(nil, "OVERLAY")
    frame.heroSub:SetPoint("TOPLEFT", PAD, -(TITLE_H + 34))
    Style.SetFont(frame.heroSub, 10)
    frame.scoreText = frame:CreateFontString(nil, "OVERLAY")
    frame.scoreText:SetPoint("TOPRIGHT", -76, -(TITLE_H + 8))
    frame.scoreText:SetJustifyH("RIGHT")
    Style.SetFont(frame.scoreText, 10)
    frame.scoreText:SetTextColor(0.91, 0.76, 0.48)

    -- The flag + the hopper. The flag comes from the ONE painter every window
    -- shares (Style.BuildFlag — the game's skyriding flag behind the runtime
    -- atlas check, drawn checker fallback; his #147 catch: this file had
    -- re-drawn its own and it was ugly).
    local fin = CreateFrame("Frame", nil, frame)
    fin:SetSize(56, 50)
    fin:SetPoint("TOPRIGHT", -PAD, -(TITLE_H + 4))
    frame.fin = fin
    frame.flag = Style.BuildFlag(fin, 28)
    frame.flag:SetPoint("BOTTOMRIGHT", 0, 0)
    frame.hopper = fin:CreateTexture(nil, "OVERLAY")
    frame.hopper:SetSize(22, 22)
    frame.hopper:SetPoint("BOTTOMLEFT", 2, 2)
    frame.hop = frame.hopper:CreateAnimationGroup()
    frame.hop:SetLooping("REPEAT")
    local up = frame.hop:CreateAnimation("Translation")
    up:SetOffset(0, 7); up:SetDuration(0.28); up:SetOrder(1); up:SetSmoothing("OUT")
    local down = frame.hop:CreateAnimation("Translation")
    down:SetOffset(0, -7); down:SetDuration(0.24); down:SetOrder(2); down:SetSmoothing("IN")

    -- The death strip: the run's clock as a bar, one mark per death.
    frame.deathStrip = frame:CreateTexture(nil, "ARTWORK")
    frame.deathStrip:SetTexture("Interface\\Buttons\\WHITE8x8")
    frame.deathStrip:SetVertexColor(0.85, 0.85, 0.88, 0.08)
    frame.deathStrip:SetHeight(10)

    -- Share (timed + stored runs only, the photo's rule) and Close.
    local function MiniButton(label, onClick)
        local b = CreateFrame("Button", nil, frame, "BackdropTemplate")
        b:SetHeight(20)
        b:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
        b:SetBackdropColor(0.16, 0.16, 0.20, 0.9)
        b:SetBackdropBorderColor(0.29, 0.29, 0.33, 1)
        b.text = b:CreateFontString(nil, "OVERLAY")
        b.text:SetPoint("CENTER")
        KG.Style.SetFont(b.text, 10)
        b.text:SetText(label)
        b:SetWidth(b.text:GetStringWidth() + 24)
        b:SetScript("OnEnter", function(self) self:SetBackdropBorderColor(KG.Style.GetAccent()) end)
        b:SetScript("OnLeave", function(self) self:SetBackdropBorderColor(0.29, 0.29, 0.33, 1) end)
        b:SetScript("OnClick", onClick)
        return b
    end
    -- The action row (his 2026-08-30 order): the Library row's doors,
    -- reachable from the report itself — share to the configured channel,
    -- copy the export string, delete. All three key off frame.addr, the
    -- run's storage address, set by whichever door opened the report.
    frame.shareBtn = MiniButton("Share", function(self)
        local a = frame.addr
        if not a or not KG.Comm then return end
        if GetTime() - (self.lastSend or 0) < 2 then return end
        if KG.Comm.SendShare(a.charKey, a.mapID, a.level, a.tier, a.pretty) then
            self.lastSend = GetTime()
        end
    end)
    local aR, aG, aB = Style.GetAccent()
    frame.shareBtn.text:SetTextColor(aR, aG, aB)
    frame.copyBtn = MiniButton("Copy string", function()
        local a = frame.addr
        if not a then return end
        local str, err = KG.Ghosts:ExportString(a.mapID, a.level, a.charKey, a.tier)
        if str then
            KG.ShowCopy("EXPORT", str)
        else
            print("|cff88ccffKeystoneGhost|r: export failed: " .. (err or "unknown error"))
        end
    end)
    frame.copyBtn.text:SetTextColor(WHITE[1], WHITE[2], WHITE[3])
    frame.delBtn = MiniButton("Delete", function()
        local a = frame.addr
        if not a then return end
        StaticPopup_Show("KEYSTONEGHOST_DELETE", a.pretty or "this ghost", nil,
            { charKey = a.charKey, mapID = a.mapID, level = a.level, tier = a.tier })
    end)
    frame.delBtn.text:SetTextColor(WHITE[1], WHITE[2], WHITE[3])
    frame.closeBtn2 = MiniButton("Close", function() frame:Hide() end)
    frame.closeBtn2.text:SetTextColor(WHITE[1], WHITE[2], WHITE[3])

    -- Closing IS the cleanup, however it happens (×, Close, ESC): a live
    -- report hands the summary back cleared so the bar's tick doesn't reopen
    -- it, and the bar returns to its normal life on the next Refresh.
    frame:SetScript("OnHide", function()
        if mode == "live" and liveSummary and KG.Recorder.summary == liveSummary then
            KG.Recorder.summary = nil
        end
        liveSummary = nil
        mode = nil
        frame.addr = nil
        if KG.Bar then KG.Bar:Refresh() end
    end)

    lines, rows, seps, stones = {}, {}, {}, {}
    Report.ApplyScale()
    return frame
end

function Report.ApplyScale()
    if frame then frame:SetScale(KG.db.scale or 1) end
end

-- ── the paint ─────────────────────────────────────────────────────────────────
-- One pass lays every section with a y cursor and sizes the window to fit.
-- `d` is the normalized input; live and stored showings build it differently.
local function Paint(d)
    local Style = KG.Style
    Style.RefreshPanel(frame)
    local aR, aG, aB = Style.GetAccent()
    local good, bad = Style.GREEN, Style.RED
    local timed = (d.chests or 0) >= 1

    frame.titleText:SetText(d.title or "")
    frame.dateText:SetText(d.date or "")

    -- hero
    frame.heroTime:SetText(M.FormatClock(d.finalTime or 0) .. " |cff"
        .. (timed and Style.GoodHex() or Style.BadHex()) .. M.TierLabel(d.chests) .. "|r")
    frame.heroTime:SetTextColor(WHITE[1], WHITE[2], WHITE[3])
    local sub
    if d.par and d.finalTime then
        local diff = d.par - d.finalTime
        if diff >= 0 then
            sub = string.format("|cff%stimer beaten by %s|r", Style.GoodHex(), M.FormatClock(diff))
        else
            sub = string.format("|cff%s%s over the timer|r", Style.BadHex(), M.FormatClock(-diff))
        end
        if timed and d.stats and d.stats.nextTier and d.stats.tierGap then
            sub = sub .. string.format(" |cff8c8c8c· +%d was %s away|r",
                d.stats.nextTier, M.FormatClock(d.stats.tierGap))
        elseif timed and d.stats and d.stats.tierGap and not d.stats.nextTier then
            sub = sub .. string.format(" |cff8c8c8c· +3 held by %s|r", M.FormatClock(d.stats.tierGap))
        end
    end
    frame.heroSub:SetText(sub or "")

    local base = ScoreTable()
    local total, baseVal, bonus
    if base then total, baseVal, bonus = M.ScoreForRun(d.level, d.finalTime, d.par, base) end
    if total then
        -- Pre-rounded half up (M.Round1): bare %.1f banker's-rounds 332.25 to
        -- 332.2 where raider.io's page says 332.3 (#147, his catch).
        frame.scoreText:SetText(string.format("score |cffe8c37a%.1f|r\n|cff8c8c8c%d base · +%.1f speed|r",
            M.Round1(total), baseVal, M.Round1(bonus)))
    else
        frame.scoreText:SetText("")
    end

    -- the celebration: flag + hop for a timed run; a deplete stands down whole
    frame.flag:SetShown(timed)
    -- The hopper wears the RUN's face, not the viewer's (#146, his catch: the
    -- Paladin's portrait on the Monk's stored run). Live mode keeps the
    -- portrait — it IS you; a stored run resolves through the one runner-icon
    -- door the roster already trusts (RIO logo / class circle / watch).
    if mode == "stored" and d.run then
        KG.Bar.ApplyRunnerIconTo(frame.hopper, d.run)
    else
        frame.hopper:SetTexCoord(0, 1, 0, 1) -- a stored view may have left class coords
        -- pcall'd like every portrait read in Bar.lua (council 2026-08-25): a
        -- secret-poisoned unit read must cost the portrait, never the report.
        if not pcall(SetPortraitTexture, frame.hopper, "player") then
            frame.hopper:SetTexture("Interface\\Icons\\Achievement_PVP_A_01")
        end
    end
    if timed then
        if not frame.hop:IsPlaying() then frame.hop:Play() end
    else
        if frame.hop:IsPlaying() then frame.hop:Stop() end
    end

    local y = -(TITLE_H + 58)
    local li, ri, si, ki = 0, 0, 0, 0
    local function nextLine(size, colorTriple)
        li = li + 1
        local fs = Line(li)
        Style.SetFont(fs, size or 10)
        fs:ClearAllPoints()
        fs:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, y)
        local c = colorTriple or WHITE
        fs:SetTextColor(c[1], c[2], c[3])
        return fs
    end
    local function section(text)
        si = si + 1
        Sep(si, y)
        y = y - 7
        local fs = nextLine(9, DIM)
        fs:SetText(text)
        y = y - 16
    end

    -- vs the raced ghost + the board (live only; a stored ghost has no opponent)
    if d.refLabel then
        section("VS " .. d.refLabel:upper())
        if d.diff then
            local fs = nextLine(10)
            fs:SetText(string.format("finish  |cff%s%s|r",
                d.diff >= 0 and Style.GoodHex() or Style.BadHex(), M.FormatDelta(d.diff)))
            fs:SetTextColor(WHITE[1], WHITE[2], WHITE[3])
            y = y - 15
        end
        if d.board and #d.board > 0 then
            for _, e in ipairs(d.board) do
                ri = ri + 1
                local r = Row(ri)
                r.left:ClearAllPoints(); r.mine:ClearAllPoints()
                r.ref:ClearAllPoints(); r.delta:ClearAllPoints()
                PlaceRow(r, y)
                local me = e.you
                -- The subject of a stored report is not always "you" (an alt's
                -- or the Raider.IO row's ghost): its own tag wears the accent.
                local tagText = me and "you" or e.tag or "?"
                if me or e.subject then
                    tagText = "|cff" .. Style.AccentHex() .. tagText .. "|r"
                end
                r.left:SetText(tagText)
                r.left:SetTextColor(WHITE[1], WHITE[2], WHITE[3])
                -- Synthetic rows (Rabbit / season best / par pace) carry no
                -- chests or level: a plain dim mark, never "depleted" — the
                -- photo board's own guard, restored (council 2026-09-01).
                r.mine:SetText(e.chests and string.format("%s%s", M.TierLabel(e.chests),
                    e.level and (" +" .. e.level) or "") or "—")
                r.mine:SetTextColor(DIM[1], DIM[2], DIM[3])
                r.ref:SetText(M.FormatClock(e.durationSec or 0))
                r.ref:SetTextColor(WHITE[1], WHITE[2], WHITE[3])
                if e.delta and not me then
                    r.delta:SetText(M.FormatDelta(e.delta))
                    r.delta:SetTextColor(DIM[1], DIM[2], DIM[3])
                else
                    r.delta:SetText("")
                end
                y = y - 15
            end
        end
        y = y - 4
    end

    -- splits: every matched boss, cumulative clocks (the photo's two-lap band
    -- retired for this — his screenshot report, TASKS F6)
    if d.splits and #d.splits > 0 then
        section("SPLITS")
        ri = ri + 1
        local head = Row(ri)
        head.left:ClearAllPoints(); head.mine:ClearAllPoints()
        head.ref:ClearAllPoints(); head.delta:ClearAllPoints()
        PlaceRow(head, y)
        -- Stored views head the columns with the runners' SYMBOLS (his
        -- 2026-09-02 call — the RIO logo, a class circle, the Rabbit's
        -- face; the words "you"/"ghost" stay for a live finish, where they
        -- are true).
        head.left:SetText("boss")
        if mode == "stored" and d.run then
            head.mine:SetText(KG.Bar.RunnerIconEscape(d.run, 14))
            head.ref:SetText(d.refRun and KG.Bar.RunnerIconEscape(d.refRun, 14) or "ghost")
        else
            head.mine:SetText("you")
            head.ref:SetText("ghost")
        end
        head.delta:SetText("Δ")
        head.left:SetTextColor(DIM[1], DIM[2], DIM[3])
        head.mine:SetTextColor(DIM[1], DIM[2], DIM[3])
        head.ref:SetTextColor(DIM[1], DIM[2], DIM[3])
        head.delta:SetTextColor(DIM[1], DIM[2], DIM[3])
        y = y - 14
        for _, row in ipairs(d.splits) do
            ri = ri + 1
            local r = Row(ri)
            r.left:ClearAllPoints(); r.mine:ClearAllPoints()
            r.ref:ClearAllPoints(); r.delta:ClearAllPoints()
            PlaceRow(r, y)
            r.left:SetText(row.label)
            r.left:SetTextColor(DIM[1], DIM[2], DIM[3])
            r.mine:SetText(M.FormatClock(row.mine))
            r.mine:SetTextColor(WHITE[1], WHITE[2], WHITE[3])
            r.ref:SetText(row.ref and M.FormatClock(row.ref) or "—")
            r.ref:SetTextColor(WHITE[1], WHITE[2], WHITE[3])
            if row.delta then
                local c = row.delta <= 0 and good or bad
                r.delta:SetText(M.FormatDelta(row.delta))
                r.delta:SetTextColor(c[1], c[2], c[3])
            else
                r.delta:SetText("")
                r.delta:SetTextColor(DIM[1], DIM[2], DIM[3])
            end
            y = y - 14
        end
        y = y - 4
    end

    -- the run: deaths (+ strip), forces, and the PB line
    section("THE RUN")
    local dl = nextLine(10)
    local deathBits = tostring(d.deathCount or 0)
    if d.timeLost and d.timeLost > 0 then
        deathBits = deathBits .. " |cff8c8c8c·|r " .. M.FormatClock(d.timeLost) .. " |cff8c8c8clost|r"
    end
    dl:SetText("deaths  " .. deathBits)
    y = y - 15
    if d.deaths and #d.deaths > 0 and d.finalTime and d.finalTime > 0 then
        frame.deathStrip:ClearAllPoints()
        frame.deathStrip:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, y)
        frame.deathStrip:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -PAD, y)
        frame.deathStrip:Show()
        local w = WIDTH - 2 * PAD
        for i = 1, #d.deaths do
            ki = ki + 1
            local dot = stones[ki]
            if not dot then
                -- The addon's death mark is the TOMBSTONE (his one-language
                -- catch 2026-08-30: on the track a skull means "the raced
                -- ghost killed its i-th boss here" — the strip briefly wore
                -- skulls after #148 and said the wrong word). Same atlas as
                -- the track's stones, same 9x12 shape, render-proven live.
                dot = frame:CreateTexture(nil, "OVERLAY")
                dot:SetAtlas("poi-graveyard-neutral")
                dot:SetSize(9, 12)
                dot:SetAlpha(0.85) -- stacked stones read denser, one alone still reads full
                stones[ki] = dot
            end
            local t = d.deaths[i][1] or 0
            -- Clustered deaths stagger across two lanes (his ask 2026-08-30):
            -- alternating by death order, so back-to-back deaths take opposite
            -- lanes deterministically and a blob becomes countable stones.
            local lane = (i % 2 == 0) and -2 or 2
            dot:ClearAllPoints()
            dot:SetPoint("TOPLEFT", frame, "TOPLEFT",
                PAD + math.max(0, math.min(1, t / d.finalTime)) * (w - 10), y + lane)
            dot:Show()
        end
        y = y - 16
    else
        frame.deathStrip:Hide()
    end
    if d.raw and d.total and d.total > 0 then
        local fl = nextLine(10)
        local pct = d.raw / d.total * 100
        fl:SetText(string.format("forces  %.1f%%%s", pct,
            d.raw > d.total and string.format(" |cff8c8c8c· +%d extra|r", d.raw - d.total) or ""))
        y = y - 15
    end
    if d.pbLine then
        local pl = nextLine(10)
        if d.pbLine.isNewBest then
            pl:SetText(string.format("|cff%sNEW PERSONAL BEST at +%d|r", Style.GoodHex(), d.level or 0))
        else
            pl:SetText(string.format("your best +%d here  %s |cff8c8c8c· this run|r %s",
                d.level or 0, M.FormatClock(d.pbLine.pb), M.FormatDelta((d.finalTime or 0) - d.pbLine.pb)))
        end
        y = y - 15
    end

    -- buttons: the action row (share / copy string / delete) + Close on the
    -- right edge, away from Delete. Mirrors (the Raider.IO row) keep only
    -- Close — the row rule; depleted runs share nothing but may die.
    y = y - 6
    si = si + 1
    Sep(si, y)
    y = y - 8
    local a = frame.addr
    local canAct = (a and not a.rio) or false
    -- The "Share button after a timed key" option governs THIS button too
    -- (council 2026-09-01: the photo path it used to gate retired for real
    -- finishes, and the option's own tooltip names the Finish Report).
    local canShare = canAct and (d.chests or 0) >= 1 and KG.Comm ~= nil
        and KG.db.photoShare ~= false
    if canShare and KG.Comm.ResolveShareChannel then
        -- The button names its destination (his ask: "share to [selected
        -- channel]") through the same resolver the send itself uses.
        local chatType = KG.Comm.ResolveShareChannel(KG.db.photoShareChannel,
            IsInGuild(), IsInGroup(LE_PARTY_CATEGORY_INSTANCE), IsInRaid(), IsInGroup())
        local WORD = { GUILD = "Guild", PARTY = "Party", RAID = "Raid", INSTANCE_CHAT = "Instance" }
        frame.shareBtn.text:SetText(chatType and WORD[chatType]
            and ("Share to " .. WORD[chatType]) or "Share")
        frame.shareBtn:SetWidth(frame.shareBtn.text:GetStringWidth() + 24)
    end
    frame.shareBtn:SetShown(canShare)
    frame.copyBtn:SetShown(canShare) -- same fence as the Library row's share
    frame.delBtn:SetShown(canAct)
    local prev
    for _, b in ipairs({ frame.shareBtn, frame.copyBtn, frame.delBtn }) do
        b:ClearAllPoints()
        if b:IsShown() then
            if prev then
                b:SetPoint("TOPLEFT", prev, "TOPRIGHT", 8, 0)
            else
                b:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, y)
            end
            prev = b
        end
    end
    frame.closeBtn2:ClearAllPoints()
    frame.closeBtn2:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -PAD, y)
    y = y - 26

    HideFrom(lines, li)
    for i = ri + 1, #rows do
        local r = rows[i]
        r.left:Hide(); r.mine:Hide(); r.ref:Hide(); r.delta:Hide()
    end
    HideFrom(seps, si)
    HideFrom(stones, ki)
    frame:SetHeight(-y + 6)
end

-- ── the two doors ─────────────────────────────────────────────────────────────

--- The live finish (Bar's tick routes here once per summary; the bar hides).
function Report:ShowLive(s)
    Build()
    mode = "live"
    liveSummary = s
    local S = KG.Scenario
    local name = (s.mapID and S:GetMapName(s.mapID)) or "the dungeon"
    -- The action row's addressing: only when THIS run's save landed
    -- (s.stored) may the address arm — RunAt alone returns the SLOT
    -- OCCUPANT, and after a slower repeat that is the older faster run:
    -- share/copy would stream the incumbent under the fresh clock's label
    -- and Delete would kill a stored PB the window never showed (council
    -- 2026-09-01, four lenses; the photo path's stored-gate comment in
    -- Recorder.lua names this exact hazard). With s.stored true the
    -- occupant IS this run.
    local ck = KG.CharacterKey()
    frame.addr = (s.stored and s.mapID and s.level and KG.Ghosts:RunAt(ck, s.mapID, s.level, s.chests)) and {
        charKey = ck, mapID = s.mapID, level = s.level, tier = s.chests, rio = false,
        pretty = string.format("%s +%d (%s)", name, s.level or 0, M.FormatClock(s.finalTime or 0)),
    } or nil
    local d = {
        title = string.format("%s +%d", name, s.level or 0),
        date = date("%d %b, %H:%M"),
        finalTime = s.finalTime, chests = s.chests, level = s.level, par = s.par,
        stats = s.stats,
        deathCount = s.stats and s.stats.deaths, timeLost = s.stats and s.stats.timeLost,
        deaths = s.deaths,
        raw = s.stats and s.stats.raw, total = s.stats and s.stats.total,
        refLabel = s.label, diff = s.diff,
    }
    -- the board: the closest-ghost rows + you, fastest first (the photo
    -- board's exact content, moved home)
    if s.rows then
        local board = { { you = true, durationSec = s.finalTime, chests = s.chests, level = s.level } }
        for _, e in ipairs(s.rows) do
            board[#board + 1] = {
                tag = e.tag, durationSec = e.run.durationSec,
                chests = e.run.chests, level = e.run.level,
                delta = e.run.durationSec - (s.finalTime or 0),
            }
        end
        table.sort(board, function(a, b) return (a.durationSec or 0) < (b.durationSec or 0) end)
        d.board = board
    end
    -- splits vs the raced ghost (honest only: a resumed run's seeded stamps lie)
    if s.ref and s.ref.run and s.bossKills and s.ref.run.bossKills and not s.partial then
        local raw = M.SplitRows(s.bossKills, s.ref.run.bossKills, s.bossIDs, s.ref.run.bossIDs)
        local splits = {}
        for _, r in ipairs(raw) do
            local seeded = s.seededKills and r.idx <= s.seededKills
            if not seeded then
                splits[#splits + 1] = { label = "B" .. r.idx, mine = r.mine, ref = r.ref, delta = r.delta }
            end
        end
        if s.finalTime and s.ref.durationSec then
            splits[#splits + 1] = { label = "finish", mine = s.finalTime,
                ref = s.ref.durationSec, delta = s.finalTime - s.ref.durationSec }
        end
        if #splits > 0 then d.splits = splits end
    end
    -- The PB line. NEW is claimed only when the save actually landed (council
    -- 2026-08-25): a partial resume or unreadable-forces finish never saves, so
    -- its faster clock must read as a comparison, not as the record — the store
    -- still holds the old best and would contradict the headline next run.
    if s.mapID and s.level then
        local byMap = KG.db.runs[KG.CharacterKey()]
        local tiers = byMap and byMap[s.mapID] and byMap[s.mapID][s.level]
        d.pbLine = M.PBLine(tiers, s.finalTime, s.chests)
        if d.pbLine and d.pbLine.isNewBest and not s.stored then
            d.pbLine.isNewBest = false
        end
    end
    Paint(d)
    frame:Show()
end

--- A stored ghost's report (the Library's magnifier): the FULL section set,
--- same as the finish window (his 2026-08-28 revision of the launch cut's
--- reduced view — "I was expecting it to be the same"). A stored run does not
--- remember which ghost it raced, so the vs/board re-race it against the
--- store as it stands today: opponent = the closest other ghost of this
--- dungeon by time, board = the live board's closest-either-side rule over
--- the same pool. Only Share stays off — the row's share button is that door.
function Report:ShowStored(charKey, mapID, level, tier)
    local run = KG.Ghosts:RunAt(charKey, mapID, level, tier)
    if not run then return end
    Build()
    mode = "stored"
    liveSummary = nil
    local S = KG.Scenario
    local owner = KG.Ghosts.OwnerShortName and KG.Ghosts:OwnerShortName(run) or nil
    local name = S:GetMapName(mapID) or "the dungeon"
    frame.addr = {
        charKey = charKey, mapID = mapID, level = level, tier = tier,
        rio = charKey == KG.RIO_CHAR,
        pretty = string.format("%s +%d (%s)", name, level or 0, M.FormatClock(run.durationSec or 0)),
    }
    local myTiers = KG.db.runs[charKey] and KG.db.runs[charKey][mapID]
        and KG.db.runs[charKey][mapID][level]
    -- A stored run self-matches PBLine whenever it IS the front of its level
    -- (the store's normal state) — "NEW PERSONAL BEST" is a live-finish claim
    -- and would be false, twice over, on an alt's or Raider.IO's row (council
    -- 2026-08-25). When the run is the front there is nothing to compare, so
    -- the stored view shows no PB line at all; a run beaten by a sibling tier
    -- keeps the honest comparison arm.
    local pl = M.PBLine(myTiers, run.durationSec, run.chests)
    if pl and pl.isNewBest then pl = nil end
    local d = {
        run = run, -- the hopper resolves ITS face from this (#146)
        title = string.format("%s%s +%d", owner and (owner .. "'s ") or "", name, level or 0),
        date = run.completedAt and date("%d %b %Y", run.completedAt) or "",
        finalTime = run.durationSec, chests = run.chests, level = level,
        par = run.parTimeSec,
        stats = { nextTier = select(1, M.NextTierGap(run.durationSec, run.parTimeSec)),
                  tierGap = select(2, M.NextTierGap(run.durationSec, run.parTimeSec)) },
        deathCount = run.deathCount,
        deaths = run.deaths,
        pbLine = pl,
    }
    -- forces from the run's own curve: the last snapshot's cumulative count
    local snaps = run.snapshots
    local lastCum = type(snaps) == "table" and snaps[#snaps] and snaps[#snaps][2]
    if type(lastCum) == "number" and type(run.total) == "number" then
        d.raw, d.total = lastCum, run.total
    end
    -- The pool: every OTHER stored ghost of this dungeon, any character, any
    -- level — the cross-level cast the Library lists, minus depleted rows
    -- (tier 0 never races, the live language's rule). Hidden ghosts stay in:
    -- hides are per-character racing preferences, and this is history. Tags
    -- come from the storage key (first name; the Raider.IO pseudo-character
    -- reads "RIO", the live board's word for it).
    local pool = {}
    if run.durationSec then
        for ck, byMap in pairs(KG.db.runs) do
            local byLevel = byMap[mapID]
            if byLevel then
                for _, tiers in pairs(byLevel) do
                    for t, r in pairs(tiers) do
                        if r ~= run and t ~= 0 and type(r.durationSec) == "number" then
                            pool[#pool + 1] = { run = r, ck = ck,
                                tag = ck == KG.RIO_CHAR and "RIO" or ck:match("^([^%-]+)") or "?" }
                        end
                    end
                end
            end
        end
    end
    -- The vs opponent = exactly what a live key here would race (his
    -- 2026-09-02 ruling, replacing the closest-by-time cut): the one
    -- reference chain — pin, own best, Raider.IO, season best, the Rabbit,
    -- par (Ghosts:BuildReference, hides honored). Viewing the very run the
    -- chain resolves to leaves nothing to compare: no vs section at all,
    -- which is the honest answer.
    local ref = KG.Ghosts.BuildReference and KG.Ghosts:BuildReference(mapID, level) or nil
    if ref and ref.run ~= run then
        d.refLabel = ref.label
        d.refRun = ref.run -- the ghost column's symbol resolves from this
        d.diff = (ref.durationSec or 0) - (run.durationSec or 0)
        -- splits vs the same opponent (the live recipe; stored stamps are
        -- honest by construction — resume-seeding never reaches the store).
        -- Synthetic references (season best / Rabbit / par) carry no boss
        -- kills, so the section stays away and only the finish gap speaks.
        if run.bossKills and ref.run and ref.run.bossKills then
            local raw = M.SplitRows(run.bossKills, ref.run.bossKills, run.bossIDs, ref.run.bossIDs)
            local splits = {}
            for _, r in ipairs(raw) do
                splits[#splits + 1] = { label = "B" .. r.idx, mine = r.mine, ref = r.ref, delta = r.delta }
            end
            if run.durationSec and ref.durationSec then
                splits[#splits + 1] = { label = "finish", mine = run.durationSec,
                    ref = ref.durationSec, delta = run.durationSec - ref.durationSec }
            end
            if #splits > 0 then d.splits = splits end
        end
    end
    if #pool > 0 then
        -- the board: the subject + the two ghosts closest to its clock either
        -- side, fastest first — the live board's exact rule over this pool
        table.sort(pool, function(a, b) return a.run.durationSec < b.run.durationSec end)
        local faster, slower
        for _, e in ipairs(pool) do
            if e.run.durationSec <= run.durationSec then faster = e else slower = slower or e end
        end
        local isMine = charKey == KG.CharacterKey()
        -- The subject's display name, shared by the board row AND the splits
        -- header (his 2026-09-01 question on the RIO row's report: the
        -- splits column said "you" for a run that was not his — live-mode
        -- wording leaking into stored views). Nil = it really is you.
        d.subjectTag = not isMine
            and (owner or (charKey == KG.RIO_CHAR and "RIO") or "?") or nil
        local board = { {
            you = isMine, subject = true,
            tag = d.subjectTag or "you",
            durationSec = run.durationSec, chests = run.chests, level = level,
        } }
        local function addRow(e)
            if not e then return end
            board[#board + 1] = { tag = e.tag, durationSec = e.run.durationSec,
                chests = e.run.chests, level = e.run.level,
                delta = e.run.durationSec - run.durationSec }
        end
        addRow(faster); addRow(slower)
        table.sort(board, function(a, b) return (a.durationSec or 0) < (b.durationSec or 0) end)
        d.board = board
    end
    Paint(d)
    frame:Show()
end

--- A new race must never run under a lingering report (Bar's live tick calls
--- this): only the LIVE report yields — a Library-opened one is deliberate
--- reading and stays.
function Report:HideLive()
    if frame and frame:IsShown() and mode == "live" then frame:Hide() end
end

--- Close the report whatever mode it is in — the delete door's cleanup (a
--- report whose run just died must not keep standing on it).
function Report:Hide()
    if frame then frame:Hide() end
end

--- EVERY delete path calls this with the dying run's storage address; the
--- report closes only when it is showing exactly that run (council
--- 2026-09-01: a row-× or batch delete used to leave the report standing on
--- a dead address — its Share minted a slot nobody could answer and its
--- Delete silently no-opped).
function Report:OnRunDeleted(charKey, mapID, level, tier)
    local a = frame and frame.addr
    if a and frame:IsShown() and a.charKey == charKey and a.mapID == mapID
        and a.level == level and a.tier == tier then
        frame:Hide()
    end
end
