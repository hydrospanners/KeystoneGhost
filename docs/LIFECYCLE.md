# Key lifecycle — shared vocabulary

The names below are the project's language for the stages a Mythic+ key moves
through, from the player walking into the dungeon to the run ending. Use them in
code comments, commit messages, and discussion so "during the countdown" and
"mid-run" always mean one agreed thing (Fredrik 2026-07-28).

| Phase | What it is | Boundary in → out | In code |
|---|---|---|---|
| **Walk-In** | Standing in the dungeon before the key is live (a.k.a. *staging*). | Enter instance → Key Activation | `PLAYER_ENTERING_WORLD`; `Scenario:GetStagingMapID`; `Ghosts:CacheRioOnSight` |
| **Key Activation** | The single instant the keystone is slotted and activated. **A point in time, not a phase.** | — | `CHALLENGE_MODE_START` → `Recorder:OnKeyStart` |
| **Warm-Up** | The ~10 s countdown: gates up, official timer not started, nobody can engage (a.k.a. *the countdown*). | Key Activation → gates drop | `rec.awaitingTimer == true`; `GetWorldElapsedTime` not yet readable; `AnchorClock` returns nil |
| **Key Run** | The live timed challenge, gates down until it ends (a.k.a. *the Challenge*). | Gates drop → completion / reset / abort | `AnchorClock` returns `t >= 0`; the race is live |

## Boundaries, precisely

- **Walk-In → Key Activation.** The player slots and activates the keystone;
  `CHALLENGE_MODE_START` fires. `OnKeyStart` runs here and sets
  `rec.awaitingTimer = true`.
- **Warm-Up.** The countdown runs; the official keystone timer
  (`GetWorldElapsedTime`) does not tick yet, so `AnchorClock` holds the recorder
  "parked at the start line" and returns nil, and `OnTick` bails after its
  Warm-Up work, before any Key-Run logic. Nothing is raceable — no trash, no
  bosses, no forces movement.
- **Warm-Up → Key Run.** The gates drop, the official timer starts,
  `AnchorClock` clears `awaitingTimer` and begins returning elapsed `t` from 0.
  That is second 0 of the race.

## The RaiderIO rule (Fredrik 2026-07-28)

Acquiring the Raider.IO ghost is expensive: it reaches into RaiderIO's private
replay provider and runs `ConvertRioReplay` (~10 ms and thousands of throwaway
tables on a long replay). **That work happens only in Walk-In and Warm-Up —
never in the Key Run.** The rationale, and the crash/spike history that forced
it, is in the Recorder header and `Ghosts:BuildRioGhost`.

- **Walk-In** — `Ghosts:CacheRioOnSight` converts and banks the replay as you
  stand in the dungeon (RaiderIO populates its provider during staging). This is
  the earliest and best moment; usually the ghost is ready before the key is even
  activated.
- **Key Activation** — `OnKeyStart`'s `BuildReference` picks up whatever was
  banked, cheaply, via `BuildRioGhost`'s cached short-circuit.
- **Warm-Up** — `Recorder:AcquireRioBudgeted` backstops the above, converting a
  replay that only became readable after the key was slotted. Budgeted
  (`RIO_MAX_ACQUIRE` tries, `RIO_ACQUIRE_GAP` apart, so ~3 tries across the
  countdown) so a replay `CleanRun` rejects can't re-convert every tick even
  here.
- **Key Run** — zero RaiderIO conversion. A banked full convert races straight
  from stored data; the degraded live mirror is kept fed with a cheap summary
  read (no conversion); and if RaiderIO never answered by the time the gates
  dropped, we race the season-best / par ghost and do not try again this run. It
  self-heals on the next key from the Walk-In cache.

Deliberately dropped to honour the rule: mid-Key-Run replay switching, and
upgrading the degraded mirror to a full convert mid-Key-Run. Both cost a
conversion during the race; both are niche; both return on the next key. (A
mid-Key-Run `/reload` re-derives the reference once through `BuildReference` —
cheap when the ghost is already banked, which after a reload it almost always
is.)
