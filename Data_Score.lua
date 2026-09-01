-- Data_Score.lua — the season's run-score base values (the Finish Report's
-- score line; F6). GENERATED — do not hand-edit. Regenerate per season with:
--   node Interface/Tools/WoWTools/scripts/keystone-ghost-pace-data.cjs --score
--
-- Derived 2026-08-24 from Raider.IO's public, documented run-review endpoint
-- (clearTimeMs == the timer returns exactly the base; dungeon-independence
-- cross-checked against Kings' Rest). Timed runs only — the overtime decay is
-- deliberately unmodeled. `roster` fingerprints the season; consumers hide
-- the score line on mismatch rather than render stale values.
local ADDON_NAME, NS = ...
local KG = NS.KG

KG.SCORE_BASE = {
    season = "Midnight Season 2",
    sampledAt = "2026-08-24",
    roster = { 249, 250, 399, 584, 585, 586, 587, 588 },
    perLevelAbove = 15, -- verified: base(+20) + 19×15 == the level-39 datum
    maxSampled = 20,
    values = {
        [2] = 155, [3] = 170, [4] = 185, [5] = 215, [6] = 230,
        [7] = 260, [8] = 275, [9] = 290, [10] = 320, [11] = 335,
        [12] = 365, [13] = 380, [14] = 395, [15] = 410, [16] = 425,
        [17] = 440, [18] = 455, [19] = 470, [20] = 485,
    },
}
