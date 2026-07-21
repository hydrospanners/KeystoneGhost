# Changelog

All notable changes to Keystone Ghost are listed here.

## [Unreleased]

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
