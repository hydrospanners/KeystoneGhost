# Keystone Ghost

Race a ghost of your best Mythic+ runs. One glance answers two questions: **am I within
time**, and **am I within enemy-forces count** of where I should be right now?

## What you see

A race bar (optionally docked under the EllesmereUI M+ timer, styled to match):

- **The bar is the dungeon** — a straight racing road from entrance to finish. Runners
  move by *progress* (enemy forces + a segment per boss); **one finish line at the
  right edge** — whoever reaches it first had the better time. While a boss is being
  fought, a runner stands at its skull landmark, then jumps forward on the kill.
- **You race above the line, ghosts below it.** You are your raid target marker (tank
  {square}) or your portrait. The raced ghost is the round class icon in a golden ring
  (the exporter's class for imports), the RaiderIO logo for replays, or a watch for
  pace ghosts — and every other roster ghost races too, as a small runner at its own
  road position (hover its row to light it up). Finished ghosts park at the line.
- **Pace cars** run the road at exactly the chest times: the red **+1 sweeper** must
  never pass you — if it does, the key depletes. Grey +2/+3 cars are toggleable.
- The **gap zone** between you and the raced ghost glows green when you lead; behind,
  it fades grey → red as holding the ghost's pace approaches depleting the key. The
  time delta and count `%` sit stacked at the top right.
- With an MDT route selected: `pull 12 · ghost 14` at the bottom.
- **Hover anything** — skulls, cars, runners, roster rows — for details ("Ghost's 2nd
  kill — Chief Corewright at 08:37 · 42% count / You: dead at 08:07 (lap -0:30)").

Below the bar, the **ghost roster**: up to 3 ghosts racing you in parallel (the raced
one highlighted; filled by priority — imports at this level, then your runs at this
level, near levels, your alts), each with a live `now` delta and speedrun-style boss
laps (`B1 -0:12` = you killed boss 1 twelve seconds faster).

## Ghost sources (in priority order)

1. **Imported ghosts** — `/kg import`, paste a friend's export string, and their ghost
   races you on your next key of that dungeon (auto-picked — imports outrank your own
   runs; their name and route shown).
2. **Your recorded runs** — every completed key is recorded automatically (forces
   timeline, boss kills with names and count, deaths, MDT route name). One ghost slot
   per chest tier per (character, dungeon, level); racing a new highest key falls back
   to your ghost one level below. Depleted runs are recorded but never raced — the
   red +1 sweeper is the deplete pressure.
3. **RaiderIO replay** — with RaiderIO's Replay module enabled, the replay it tracks
   (guild best / your best) races you with real boss timestamps.
4. **Season best / par pace** — linear ghosts so the bar is useful from day one.

## Commands

| Command | Effect |
|---|---|
| `/kg` | help |
| `/kg test` | demo race preview (works anywhere, 10x speed; uses your real ghosts when available) |
| `/kg list` | stored ghosts for this character |
| `/kg export [level]` | share your best ghost as a copy/paste string |
| `/kg import` | paste someone's ghost and race it |
| `/kg attach` | dock below / detach from the EllesmereUI M+ timer |
| `/kg splits` | show/hide the boss-lap rows |
| `/kg hide` / `show` / `toggle` | window visibility — recording never stops |
| `/kg resetpos` | reset position |

Position and settings also live in the game's **Edit Mode** (the bar is a system there:
drag to move, click for settings).

## Dependencies

None required. Optional, detected at runtime: **EllesmereUI** (styling + docking),
**RaiderIO** (replay ghosts), **MythicDungeonTools** (route name + pull indicator).
Bundled libs: LibStub, LibSerialize, LibDeflate, LibEditMode.

## Notes

- The race metric is count-based: the delta asks "when did the ghost have at least my
  forces% AND my boss count" — never which bosses or what route. Skull positions and
  other route visuals are presentation on top; the number can't be fooled by playing
  bosses in a different order.
- A `/reload` mid-key resumes racing (the world timer rebuilds the clock), but that
  run's recording is incomplete and is not saved as a ghost.
- Boss laps pair by boss identity (encounterID) when both runs recorded it — correct
  numbers on any route; older data falls back to kill-order matching.
- Count deltas vs *linear* ghosts (season best / par) swing a lot — real routes bank
  forces unevenly. Recorded and replay ghosts give honest count deltas.
