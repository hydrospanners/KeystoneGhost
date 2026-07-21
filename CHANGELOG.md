# Changelog

All notable changes to Keystone Ghost are listed here.

## [Unreleased]

- Ghost Library: one selected row per dungeon. Pinning a ghost now clears the
  dungeon's previous pin — any key level, the Raider.IO row included — so two
  rows can no longer sit highlighted in the same dungeon looking multi-selected.
  Pins in other dungeons stay. Importing a ghost still auto-pins it, and that
  also replaces the dungeon's previous pin now (a pinned Raider.IO ghost is the
  one thing an import won't unseat, as before). Double-pins left over from
  older versions collapse the first time you pin anything in that dungeon.
- The Raider.IO ghost is now a real ghost, not a live mirror: the full replay
  (per-award forces log, boss kills with identity, deaths) is converted into a
  normal stored run the moment it is seen — skulls sit at their true spots from
  second 0:00, boss laps pair by boss (no more wrong-boss comparisons on a
  different route, the old first-run jank), and the Gap runs on the same math
  as every stored ghost. Clock honest to ±3 s (their timers exclude the death
  penalty; ours include it — converted and verified).
- The Ghost Library grows a "Raider.IO" owner: one prefilled ghost per dungeon,
  banked automatically when you enter the dungeon or start a key (their replay
  list is private, so rows appear per dungeon as you play). Pin it to race it
  on ANY key level of that dungeon — even over your own ghosts; unpinned it is
  always the LAST pick, only racing when you have no ghost of your own. Delete
  evicts the cache (the row returns next time RaiderIO serves the replay);
  Raider.IO ghosts can't be shared.
- The Raider.IO ghost also fills the last roster slot when there is room, wears
  the RaiderIO logo, and can be raced by clicking its row — automatic Overtakes
  still never target it. Switching replays in RaiderIO's own selector mid-run
  is picked up within ~5 s. If the full replay ever becomes unreadable, the old
  live mirror still races as a fallback — now with boss-identity laps too.
- Change-driven recording (the RaiderIO event-log lesson): the recorder now
  captures on the scenario-criteria events instead of a 2 s clock — every
  forces change and boss kill lands at its exact second, and timelines are
  step-shaped (flat between changes, exactly how the count actually moves),
  so the Gap inversion never credits a slope that was never played. Deaths
  and boss engages were already event-driven. A change-guarded 5 s reconcile
  keeps recording alive even if the game ever stops delivering the events.
- Stored ghosts and export strings shrink: nodes only where something
  happened, instead of ~900 fixed samples in a 30-minute run. Old ghosts
  keep racing and importing unchanged — same format, same math.
- The RaiderIO replay mirror (and its test-mode demo twin) record change-only
  step nodes too — the replay ghost's moves are no longer smeared up to 2 s.

## [0.8.1]

- Fixed: your raid target marker shows as your runner icon again. The game
  hides marker data from addons nowadays, which made the icon always fall
  back to your portrait.

## [0.8.0]

First public release.

- Race a ghost of your best Mythic+ runs: boss-kill milestones on the track,
  a live time Gap and forces Gap, and the red Sweeper pace car that shows
  when the key starts depleting.
- The Ghost Library (`/kg` or the minimap ghost): browse every stored run
  across all your characters, pin the ghost to race next key, share or
  delete per row.
- Ghost sharing: compact export strings for Discord, or shift-click a row
  into chat for one-click in-game transfer.
- Optional integrations: race the RaiderIO live replay; MDT route capture,
  shared ghosts can carry the route.
- Position and looks in Edit Mode; behavior in the AddOns options panel.
