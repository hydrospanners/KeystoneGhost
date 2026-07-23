# Changelog

All notable changes to Keystone Ghost are listed here.

## [0.10.0] - 2026-07-23

- Ghosts now show their deaths. A tombstone stands on the ghost's own lane
  where its run lost time, and clears away as the ghost reaches it. A stone
  ahead of a rival is where that run is about to stumble. The ghost you're
  racing wobbles when it gets there.
- Your own tombstones moved up onto the track, into the same lane as the boss
  skulls, and never sit on top of one. Several deaths in the same spot stack
  into a small pile.
- New setting, "Death markers", in the options panel: off, your deaths only,
  or your deaths and the ghosts'. It only changes what gets drawn. No ghost
  runs differently because of it.
- You can now hide a ghost. Click the eye on its row in the Ghost Library and
  it stops racing you: no roster row, no automatic pick. The row stays in the
  Library, dimmed, so clicking the eye again brings it back. Pinning a hidden
  ghost un-hides it, which is why pinned rows have no eye. Hiding is yours
  alone. It never travels in a shared ghost.
- New Edit Mode slider, "Ghost Roster size": how many ghosts race you at once,
  0 to 4. Set it to 0 to leave just you and the one ghost you're racing.
- The addon now shows nothing inside raid instances. A left-on `/kg test` demo
  or an undismissed run summary no longer follows you in there. Everything
  Mythic+ works exactly as before.

## [0.9.2] - 2026-07-22

- Marked compatible with 12.1 alongside 12.0.7. Support for 12.0.5 is dropped.

## [0.9.1] - 2026-07-22

- Runs now record the account region ("EU", "US", …) alongside the rest of the
  run context. Nothing changes in game: it exists so a shared ghost can be
  turned into Raider.IO and Warcraft Logs profile links, which are region-first
  and previously had no source for that field. The region travels with the run,
  so re-sharing an imported ghost keeps the original party's region.

## [0.9.0] - 2026-07-21

- Ghost Library pins reworked: one selected row per dungeon, per character.
  A pin now races its dungeon at ANY key level — race your +12 ghost in a
  +20 — the way the Raider.IO row already worked. Pinning another row moves
  the selection there, clicking the pinned row unpins it, and two rows can no
  longer sit highlighted in one dungeon. Pins also stopped following the
  ghost's owner around: pinning your main's run while on an alt pins it for
  the alt only. Importing a ghost pins it on the character you imported
  with — over whatever that character had pinned, the Raider.IO ghost
  included — so it races your next key. The ghost itself shows in every
  character's Library; the others just don't have it pinned until they pin
  it. Pins from older versions reset once on this update — re-pin from the
  Library.
- Ghost Library: the Route cell brightens on hover when a route can be
  clicked to load into MDT, so clickable reads as clickable. The row's own
  hover wash and the share/delete buttons' cues are unchanged.
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
- Change-driven recording: the recorder now
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
- The X that closes the post-run summary now matches the Ghost Library's
  close button instead of the default red one.
- The Ghost Library lists every dungeon of the season, not just the ones you
  have ghosts for. Empty dungeons say so and tell you how to get one — run
  the dungeon, import a ghost, or (with RaiderIO) just walk in and its replay
  is banked for you.
- The Raider.IO library row shows its pedigree: the RaiderIO logo sits where
  share lives on your own rows, the owner cell names the replay set
  ("Raider.IO · Guild best"), route reads n/a (replays can't carry one), and
  clicking the logo opens a copy window with the raider.io run link. No
  delete on that row — it's a live mirror of RaiderIO's pick, it would just
  come straight back. The window grew a bit wider for the longer names.

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
