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
  {square}) or your portrait. The raced ghost is the round class icon riding the
  accent cursor (the exporter's class for imports), the RaiderIO logo for replays, or
  a watch for pace ghosts — and every other roster ghost races too, as a small faded
  runner in its own lane at its own road position (hover its row to light it up).
  Finished ghosts park at the line.
- **The race changes hands.** A roster ghost that overtakes you and holds it
  (clear of the buffer zone around your icon for 3 s) becomes the raced ghost — no
  banner: a short crossfade, a glow on its roster row, and every number re-baselines
  at once. Click any roster row to race that ghost instead (this **pins** it —
  automatic switches stop until you click the raced row again to unpin). Imported
  ghosts start pinned, so racing the sender stays deliberate.
- **Pace cars** run the road at exactly the chest times: the red **+1 sweeper** must
  never pass you — if it does, the key depletes. Grey +2/+3 cars are toggleable.
- The **gap zone** between you and the raced ghost glows green when you lead; behind,
  it fades grey → red as holding the ghost's pace approaches depleting the key. The
  time delta and count `%` sit stacked at the top right.
- With an MDT route selected, the bottom line reads `<route name> by <creator> ·
  Pull #12 vs Ghost #14` — the creator in their class color, exactly like MDT's own
  route list; whoever is a pull ahead wears green, the trailer red; on the same
  pull the line stays neutral.
- **Tombstones** mark deaths. Yours stand where you died and stay there. A ghost's
  stand on its lane ahead of it, showing where that run lost 15 seconds, and clear
  away as the ghost reaches them (it wobbles when it does). Set it to off, your
  deaths only, or everyone's in the options panel.
- **Hover anything** — skulls, cars, runners, roster rows — for details ("Ghost's 2nd
  kill — Chief Corewright at 08:37 · 42% count / You: dead at 08:07 (lap -0:30)").

Below the bar, the **ghost roster**: up to 3 ghosts racing you in parallel (the raced
one highlighted; filled by priority — imports at this level, then your runs at this
level, near levels, your alts, the Raider.IO ghost last), each with a live `now`
delta and speedrun-style boss
laps (`B1 -0:12` = you killed boss 1 twelve seconds faster). Rows are clickable
(switch/pin); a gold lock on the raced row means it's pinned.

## Ghost sources (in priority order)

1. **Imported ghosts** — `/kg import`, paste a friend's export string, and their ghost
   races you on your next key of that dungeon (auto-picked — imports outrank your own
   runs; their name and route shown). **Export strings carry the sender's MDT route**
   (as it was when the run was recorded — routes mutate, so it's captured at key
   start): `/kg route` or clicking the ghost's badge loads it straight into your MDT
   after a confirm. Both parts are optional for the sender — the addon options panel
   (`/kg options`) has "Export: route name" and "Export: route data" toggles.
2. **Your recorded runs** — every completed key is recorded automatically (forces
   timeline, boss kills with names and count, deaths, the MDT route — name, creator,
   and pull data, deduplicated by content). One ghost slot per chest tier per
   (character, dungeon, level); racing a new highest key falls back to your ghost one
   level below. Depleted runs are recorded but never raced — the red +1 sweeper is
   the deplete pressure.
3. **The Raider.IO ghost** — with RaiderIO's Replay module active, the replay it
   tracks (guild best / your best) is converted into a full ghost the moment you
   enter the dungeon — real forces curve, boss kills with identity, deaths — and
   stored under a "Raider.IO" owner in the Ghost Library (one per dungeon, banked
   as you play; refreshed whenever RaiderIO serves a newer replay). Unpinned it is
   always the LAST pick — it races only when you have no ghost of your own. **Pin
   it in the Library and it races ANY key level of that dungeon**, even over your
   own ghosts. Not shareable; delete evicts the cache (the row returns on next
   sight). If the full replay can't be read, a live tick-mirror races as fallback.
4. **Season best / par pace** — linear ghosts so the bar is useful from day one.

## Commands

| Command | Effect |
|---|---|
| `/kg` | help |
| `/kg options` | addon options (behavior; looks & layout live in Edit Mode) |
| `/kg export [level]` | share your best ghost as a copy/paste string |
| `/kg import` | paste someone's ghost and race it |
| `/kg route` | load the raced/imported ghost's embedded MDT route (also: click the ghost's badge) |

Everything visual lives in the game's **Edit Mode** (the bar is a system there: drag to
move, click for settings — enable/dock/scale/opacity/splits and more). The bar is
clamped to the screen, so a stale saved position can never strand it off-screen.

## Dependencies

None required. Optional, detected at runtime: **EllesmereUI** (styling + docking),
**RaiderIO** (the Raider.IO ghost), **MythicDungeonTools** (route name + pull
indicator).
Bundled libs: LibStub, LibSerialize, LibDeflate, LibEditMode.

## Notes

- The race metric is count-based: the delta asks "when did the ghost have at least my
  enemy-forces count AND my boss count" — never which bosses or what route. Skull
  positions and other route visuals are presentation on top; the number can't be
  fooled by playing bosses in a different order. Runs store the raw integer count
  (percent is derived for display), so pull decisions can't be skewed by rounding.
- The numbers read as percent by default — forces gap `+3.4%`, tooltips `55.2%`.
  Prefer the raw count (`+14`, `228/413`) because mid-key you think in pull sizes?
  Untick "Show % instead of count" in the options panel; the race math is identical
  either way.
- Export strings are format v2 (compact count-space streams, ~10× smaller than the
  pre-0.5.0 format). Strings made before 0.5.0 can't be imported — ask the sender to
  re-export; runs recorded before 0.5.0 were retired with the format.
- A `/reload` (or full client restart) mid-key resumes racing with the run's real
  recorded timeline — the in-progress recording is persisted, so the run can still be
  saved as a ghost. Only a hard crash loses the recording: racing then resumes on the
  world timer alone and that partial run is not saved.
- Boss laps pair by boss identity (encounterID) when both runs recorded it — correct
  numbers on any route; older data falls back to kill-order matching.
- Count deltas vs *linear* ghosts (season best / par) swing a lot — real routes bank
  forces unevenly. Recorded and replay ghosts give honest count deltas.
- Automatic switches are guarded against ping-pong: a challenger inside the buffer
  zone around your icon never triggers, the hold must be 3 s continuous, and the same
  pair can't swap back within 20 s. Automatic switches never target the Raider.IO
  ghost — clicking its roster row races it deliberately (and pins).
