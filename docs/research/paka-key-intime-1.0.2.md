# Dissection: "Paka Key InTime – Mythic+ Forecast" v1.0.2

Research notes for KeystoneGhost. Analysis of a third-party addon, written in our own
words — the addon's license is **All Rights Reserved (© 2026 Pakapuka)**, so nothing
below may be copied into KeystoneGhost as code; concepts and facts only. Do not vendor
its files into this repo.

## Provenance

| | |
|---|---|
| CurseForge project | 1634009, `paka-key-intime-mythic-forecast` |
| Author | Pakapuka (solo; German-speaking — comments in source are German, UI is EN/DE) |
| First published | 2026-08-01 (one day before this analysis; 18 total downloads) |
| Analyzed file | `PakaKeySave_1.0.2.zip`, file id 8554334, 35 741 bytes, WoW 12.0.7 |
| Internal folder | `PakaKeySave` (public rename to "Paka Key InTime" happened in 1.0.2) |
| Dependencies | none required; optional MDT (detection only) |
| Source | no public repo found; CurseForge zip only (obtained via CI fetch, kept out of git) |

One-line: a **forecast dashboard** — it predicts final completion time, end reserve, and
an in-time probability from a hand-tuned prior model blended with live run telemetry.
It does not store or race timelines; it is not a ghost racer.

## Architecture

~100 KB of Lua across 15 files, no libraries (no Ace, no LibStub). Single addon-table
namespace (`PKS`) threaded through every file via the addon vararg. Load order per TOC:
`Data → Core → Localization → Themes → Model → MDT → Telemetry → Recorder →
ChallengeMode → Prediction → Finalization → Simulation → Macros → UI → Events`.

Data flow, once per second (plus event nudges):

```
Events.lua (1 s OnUpdate tick + scenario/challenge events)
  → ChallengeMode.lua RefreshLive()
      reads: IsLiveKey, GetElapsed, GetCriteria, GetDeaths      (guarded API reads)
      pulls: Telemetry snapshot (trash/boss/idle second counters)
      pulls: Model.GetPredictionProfile (priors ⊕ learned averages)
  → Prediction.lua BuildPrediction()                            (pure-ish math)
  → PKS:SetState() → UI.lua UpdateUI()                          (single state table)
  → Recorder.lua RecordRunSample()                              (10 s diagnostic samples)
```

State is one flat `PKS.state` table; every UI element re-renders from it on any change.
Modes: `IDLE → LIVE → FINALIZING → COMPLETE` (+ `TEST` simulation).

## How it senses the run (ChallengeMode.lua)

- **Active-key detection** is a 5-source OR-ladder: `C_PartyInfo.IsChallengeModeActive`,
  `C_ChallengeMode.IsChallengeModeActive`, an active challenge mapID, its own
  `CHALLENGE_MODE_START` flag, and finally instance-difficulty (8/23) + a readable
  keystone level. Each source is secret-guarded; the winning source name is kept for
  diagnostics.
- **Clock**: scans `GetWorldElapsedTimers` for the challenge-mode timer type; falls back
  to `C_ChallengeMode.GetStartTime` (with an ms-vs-s heuristic) and then to a local
  `GetTime` anchor. On the fallbacks it *adds the death penalty manually* (comment notes
  Blizzard's world timer already includes it — correct, and the same reason our
  Recorder re-anchors to `GetWorldElapsedTime`). Monotonic guard: a reading more than
  3 s below the previous one is discarded.
- **Enemy forces**: enumerates scenario criteria, scores each candidate
  (weighted-progress flag +100, description contains "enemy forces"/German equivalents
  +50, readable quantity +10) and takes the best. The percentage is then chosen by
  priority: completed → 100; **weighted → `criteriaInfo.quantity` used directly as a
  percent** (their comment: Blizzard's own M+ bar does exactly this); then a
  `quantityString` percent parse; then quantity; then quantity/total; then step
  `weightedProgress`. A monotonic hold rejects drops > 0.5 %.
- **Bosses**: every non-weighted criterion with a completion flag / total of 1 / any
  description counts as a boss; `bossesDone` counts completed ones. No encounterID, no
  identity — a pure count.
- **Completion**: `C_ChallengeMode.GetChallengeCompletionInfo`, with an ms-vs-s
  heuristic on `info.time`, secret-guarded `onTime`/`practiceRun`.

### Comparison with our reads

Same Midnight secret-value discipline as ours (their `issecretvalue` + pcall gates ≈ our
`canaccessvalue` gates in Scenario.lua) — convergent evolution, everyone on 12.x ends up
here. Two real differences:

1. **Granularity.** They consume the *integer percent* Blizzard feeds the default
   tracker bar. We store the raw integer count and derive percent for display. Their
   model therefore quantizes trash progress to 1 % steps and can't see sub-percent
   pulls; our count-space math can.
2. **Identity.** Their bosses are anonymous counters; our recorder keeps encounterIDs,
   which is what makes boss-lap pairing on any route possible. Nothing in their data
   model could support a lap comparison.

## The forecast model (Prediction.lua — the heart)

`remaining = remainingTrash + remainingBoss + remainingTravel`, each component
independently estimated as **blend(prior estimate, live extrapolation, gated weight)**:

- **Priors** (Model.lua): per-dungeon bootstrap profiles ship in Data.lua — official
  timer, `totalRatio` (typical clear time ÷ timer), `bossShare`, `travelShare`,
  hand-set confidence. Matched by *localized dungeon name aliases* (EN + DE only).
  A key-level bucket multiplier scales the expected total (2–5: ×0.88 … 20+: ×1.18).
  Expected total is clamped to [0.55, 1.08] × timer.
- **Learning** (Model.lua): per `(mapID, key-bucket)` running averages of total time,
  trash-combat, boss-combat, travel seconds and per-boss average, stored in
  SavedVariables. Blend weight ramps with run count: `clamp(runs/8, 0.15, 0.72)` — so
  the prior never fully disappears. Runs only qualify if ≥ 300 s elapsed, telemetry
  coverage ≥ 70 %, not late-started, and the completion was exact (not approximate).
- **Live trash**: `estimatedTotalTrashCombat = trashCombatSeconds / trashFraction`
  (linear rate extrapolation), clamped to [0.65, 1.45] × prior, gated behind ≥ 15 %
  trash, ≥ 60 s trash combat, ≥ 2 completed pulls, ≥ 50 % coverage. Live weight caps
  at 0.76.
- **Live boss**: expected per-boss seconds = blend(prior average ⊕ learned average,
  observed kill average), weight ∝ (kills/total) × coverage, cap 0.78. Mid-encounter it
  credits the current fight: `max(5, avg − encounterElapsed) + rest × avg`.
- **Live travel**: "structural progress" = 0.65 × trashFrac + 0.35 × bossFrac; idle
  seconds extrapolated the same way, clamps [0.55, 1.50] × prior, weight cap 0.55.
- **End-game hard rules**: at 100 % trash the trash term is zeroed; on the last boss
  travel is zeroed too; everything zero when all objectives are done.
- **Uncertainty**: `timer × (0.12 × (1 − progress) + 0.025)`, shrunk by up to 45 % as
  learned runs accumulate, +75 s if late start, + up to ~66 s for poor coverage,
  clamped to [25 s, 260 s].
- **In-time probability**: logistic squash of the reserve —
  `100 / (1 + e^(−reserve / max(25, 0.55 × uncertainty)))`, clamped 1–99 %.
- **Status**: SAFE needs chance ≥ 75 % *and* reserve ≥ 60 s; FAIL needs chance ≤ 20 %
  *and* even the optimistic bound (reserve + uncertainty) negative; else CLOSE.
  Softer thresholds during the first 90 s. A 5 s hysteresis (`StabilizeStatus`)
  suppresses flicker between colors.

## Telemetry (Telemetry.lua)

The run is segmented into **trash-combat / boss-combat / idle** with second precision,
driven entirely by `PLAYER_REGEN_DISABLED/ENABLED` and `ENCOUNTER_START/END` — the
player's own combat state as a proxy for the group's. Completed trash pulls are counted
(regen-enabled while not in a boss). Boss kill durations accumulate from ENCOUNTER_END
success; wipes accrue separately. `coverage = trackedSeconds / elapsed` is the model's
trust knob and the learning gate. Nothing is persisted mid-run: a `/reload` restarts
telemetry (flagged late-start), which silently disqualifies the run from learning.

## Lifecycle guards (Finalization.lua)

Their 1.0.0 changelog says the model flickered after the final boss; the fix is a
two-signal **finalization freeze**:

1. Some clients expose all-criteria-complete for a single update → finalize.
2. Otherwise detect the *criteria collapse*: trash was complete, the final boss was
   next, and criteria vanished or regressed → finalize before the model can see a
   bogus "100 % trash / 0 bosses" sample.

During FINALIZING the forecast fields are nil'd and the UI shows a frozen state; then
`GetChallengeCompletionInfo` is polled on a 0.05/0.15/0.35/0.75/1.5/3.0 s ladder, with
an approximate fallback built from the last live state (approximate results are shown
but never learned from). This mirrors the problem our Recorder solves with guarded
absolute reads + the liveRun freeze, but their trigger is *inference from criteria
deltas* rather than reading through the flicker.

## The rest, briefly

- **Recorder.lua** is a *diagnostic flight recorder*, not a run store: every ≥ 10 s it
  snapshots the model's own outputs (≤ 400 samples), saved as `db.lastRun`; `/pks trace`
  prints 12 evenly-spaced samples — a post-mortem of "what did the model believe when."
- **Simulation.lua**: 4 canned scenarios (safe/close/fail/last-boss) with a sine wobble,
  for showcasing the UI outside a key.
- **Macros.lua**: creates/updates three macros ("PKS Green/Yellow/Red") that post a
  fixed English forecast line with a raid-target icon to a chosen group channel.
  Manual click only; explicitly no automated chat.
- **MDT.lua**: pure presence detection (installed / loaded / has any saved preset) by
  reading `MythicDungeonToolsDB`; feeds a status label only. No route data used.
- **UI.lua**: one 352 × 516 px DIALOG-strata panel — status word, in-time %, reserve
  and total forecast in 25 pt, a chance bar, four stat tiles (time left / trash % /
  bosses / deaths), component breakdown line, cause + recommendation text, and
  TEST/SCENE/LIVE buttons. Class-colored themes (Themes.lua derives a whole palette
  from one class color). No Edit Mode, no minimap button; a floating "PKS" launcher
  button instead.
- **Localization.lua**: EN/DE string tables for everything.

## Defects and fragilities noticed (as of 1.0.2)

1. **Unclamped text-percent fallback.** The `quantityString` parse path accepts any
   number before a "%" and does not clamp. On clients where that string carries the
   *raw forces count* with a "%" suffix (the long-standing M+ quirk that is exactly why
   addons parse it for the raw count), a value like "228%" becomes 228 → trashFraction
   clamps to 1.0 → the model thinks trash is finished, and the monotonic hold then pins
   it there for the rest of the run. Reachable when the weighted `quantity` read fails
   (e.g. secret flicker) while the string stays readable.
2. **Name-matched priors.** Dungeon profiles match localized names in EN/DE only; any
   other client locale silently gets the generic profile (learning still works — it
   keys by mapID). Alias matching also uses plain substring `find`, so a name that
   embeds another dungeon's alias would mis-profile.
3. **Hardcoded 4-boss fallback** when criteria are unreadable (`max(4, kills)`), so
   3- or 5-boss dungeons skew the boss term whenever criteria drop out.
4. **No mid-run persistence.** `/reload` or a crash resets telemetry and the live
   cache; the run survives visually (world timer) but is excluded from learning, and
   all live-blend gates start from zero coverage. Our liveRun adopt/seed design is
   strictly stronger here.
5. **Learning is an all-history running average** — no recency weighting; a group/meta
   change months later still drags the average. Cap of 0.72 on learned weight means the
   hand-tuned prior never fully yields either.
6. **Speculative dungeon table.** The prior table ships guesses for a next season pool
   ("Folgepool-Fallbacks" — Altar of Fangs, Murder Row, Den of Nalorakk, Blinding
   Vale, Voidscar Arena, King's Rest, Temple of Sethraliss, Ruby Life Pools) with
   invented ratios at low confidence.
7. **Probability is uncalibrated.** The logistic scale comes from the heuristic
   uncertainty, not from any measured error distribution; the 1–99 % clamp concedes as
   much. Fine as a traffic light; not a real probability.

None of this is unreasonable for a two-day-old solo addon — the secret-guarding, the
fallback ladders, and the finalization freeze are genuinely careful work. The model is
honest heuristics, transparently labeled ("Profile/Live/Runs(n)" source line in the UI).

## What KeystoneGhost can learn (concepts only)

1. **A single in-time number is a different product than a race, and users may want
   both.** Their headline is "IN-TIME 87 %". Our bar answers "am I ahead of the ghost";
   their panel answers "will this key time". We already hold strictly better data for
   that question: full count-space timelines of finished runs. An *empirical* deplete
   risk (where did runs that stood at this count/time at this level end up?) would beat
   their hand-tuned logistic without inheriting any of their prior machinery. Candidate
   surface: a small percent readout near the +1 sweeper, GhostMath-pure and unit-tested.
2. **Trash/boss/travel decomposition is cheap and explains gaps.** REGEN/ENCOUNTER
   segmentation is ~100 lines and event-driven, and it would let tooltips say *where*
   a delta came from ("−0:40, of which ~0:25 extra downtime"). It composes naturally
   with PullTrack's pull records.
3. **A model/diagnostic trace is a great support tool.** Their 12-sample `/pks trace`
   post-mortem of the addon's own beliefs is the kind of thing that turns "the bar felt
   wrong" bug reports into data. We already persist recordings; a `/kg trace`-style
   digest of the last run's racing decisions (raced ghost, switches, deltas at
   checkpoints) would be nearly free.
4. **Status hysteresis as a UX pattern.** Their 5 s color hold is the same idea as our
   overtake anti-ping-pong; if the gap-zone color or severity tint ever reads as
   flickery, a short hold is the fix.
5. **Manual pace-callout macros** ({rt} icon + one line to /i) are a charming,
   zero-risk social feature; an optional "/kg call" that whispers the current verdict
   to the group would rhyme with our export/import culture.

## Competitive read

Different niches with one overlapping headline question. They: prior+rate *forecast*,
one dungeon-agnostic panel, no timeline storage, no sharing, no route awareness, EN/DE.
Us: empirical *racing* against real recorded/imported/replay timelines, count-space
math, sharing, RaiderIO and MDT integration, Edit Mode native. The forecast idea is
worth absorbing (see above) — the implementation is not something we'd want, and its
license forbids reuse anyway. As of analysis day it has 18 downloads; not a market
threat, but the *category* (probability forecasting) is validated demand worth owning
with better data.
