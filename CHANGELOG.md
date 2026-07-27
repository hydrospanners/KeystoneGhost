# Changelog

All notable changes to Keystone Ghost are listed here.

## [0.12.0] - 2026-07-28

- New option, "Raid marker as a hat", in the options panel: your runner stays
  your portrait, and a raid target marker on you perches as a tiny hat above
  your head instead of replacing your face.
- Settings sweep: "Walking bounce" and the pace car toggles moved from Edit
  Mode to the options panel. The rule they follow now: Edit Mode carries size
  and position — where things sit and how big; how the race displays lives in
  the options panel. Your saved choices carry over unchanged.
- First login after installing, the bar introduces itself: it appears running
  the demo loops with a "drag me into place" handle above it. Drag it where
  you want it, close the handle, done — the handle never shows again, and
  Edit Mode owns placement from then on. Fixes the fresh-install catch-22
  where Edit Mode didn't pick the bar up until it had been shown once — and
  nothing showed it before your first key.
- Every pace car has its own checkbox now — "Show pace cars": +1, +2, +3 in
  the options panel. The +1 sweeper can be hidden too; its red wake goes with
  it, and the gap zone still warns about depletion. An old "Extra pace cars"
  off-setting carries over to the +2/+3 boxes.
- The Edit Mode toggle "Boss lap splits" is now "Display Ghost Roster" — it
  always governed the whole roster panel, not just the lap columns.
- "Reset Share Tag" now shows your current tag and asks for confirmation
  first — a reset permanently splits how receivers group your earlier and
  later shares.
- All the heavy Raider.IO work now happens while you walk in and during the
  key countdown — never while the timer runs. The addon asks RaiderIO for its
  replay a few times before the gates drop; if it hasn't answered by then, it
  stops asking for the rest of that run and races your season best instead
  (the replay banks again on your next key). Before, a replay the addon
  couldn't accept made it retry every half-second through the whole opening
  minute — a stutter in the first pulls, and another addon's internals poked
  ~120 times a key.
- Two niceties left with that, on purpose: flipping RaiderIO's replay dropdown
  mid-run no longer swaps the ghost mid-run, and the fallback live mirror no
  longer upgrades to the full replay mid-run. Both return on your next key.
- The race math takes a shortcut: timeline sampling narrows straight in on the
  right recorded step instead of walking every step from the start. Same
  answers — verified against the old math on 160,000 checks — at a fraction of
  the work, biggest on long Raider.IO replays.
- Wearing a raid target marker repaints your icon twice a second instead of
  ten times. A marker's value is one of Midnight's secrets, so it can't be
  compared — only repainted; now it repaints on a clock.

## [0.11.0] - 2026-07-26

- A dungeon with no MDT route raced against the wrong one. MDT gives every
  dungeon you have opened an empty starter route, and the addon took that for a
  real one — so whatever name was sitting in that slot rode along on the bar with
  nothing behind it, and every pull read as already done. An empty route is no
  route now, and a route filed under another dungeon is refused.
- `/kg route` no longer hands MDT a route from a different dungeon while you are
  standing in one. Outside a dungeon it still offers your last import.
- The bar is a little taller so your icon has its own lane above the road. It
  used to share that band with the count number, which is why standing at the
  end of the road covered it — with a raid marker on your head, completely.
  Should the numbers and the icon still meet (big text, small bar), the numbers
  slide out of the way and glide back when you move on.
- The pace cars are labelled +3, +2 and +1, just left of each line. Three
  identical hairlines told you nothing about which one was about to pass you.
- The +1 car drags a red hatched trail behind it — the road it has taken.
- New button in the Ghost Library: "Open my library online". It copies a link
  that loads every ghost you have stored into your browser. Ghosts you have
  opened before won't duplicate — only the new ones fill in. The page it points
  at isn't built yet, so the link goes nowhere for now.
- The copy popup is a real window now. Same selected-text-and-Ctrl+C, but the
  box fits more than one line, and there's a "Close on copy" tickbox if you'd
  rather it stayed open. Ghost strings and raider.io links both use it.

## [0.10.3] - 2026-07-25

- The account region never actually reached a saved run. It was read at the
  start of every key and then lost on the way to storage, so every ghost and
  every share string since 0.9.1 has it empty. New runs carry it. The old ones
  can't be fixed after the fact.
- Runs with an MDT route now record when each pull's first mob died, next to
  when the pull was finished. Nothing to see in game yet. It's there so the gap
  between two pulls can be split into the walk and the fight.

## [0.10.2] - 2026-07-24

- Empty Ghost Library groups no longer each print the "no ghosts yet" tip.
  Only the first empty dungeon shows it.
- The `/kg test` demo stages fewer deaths across the run, so the demo is a
  stumble again instead of a wipe.

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
