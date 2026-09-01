# Keystone Ghost

Race a ghost of your best Mythic+ runs. A race track styled bar shows whether you
are ahead of or behind your own best run of this dungeon and key level, in both
time and enemy forces.

Runs are recorded automatically. The next time you play that dungeon, your best
run races you as a ghost on the track: boss kill milestones, a live time gap like
+0:42, a forces gap as percent or count, and a red Sweeper pace car that marks
when the key starts depleting. The comparison runs on your recorded progress
curve, not on a linear estimate.

## Install

- [CurseForge](https://www.curseforge.com/wow/addons/keystone-ghost) is the easy way.
- Manual: grab the zip from the [latest release](../../releases/latest) and
  extract **both** folders (`KeystoneGhost` and `KeystoneGhost_MDTData`) into
  `World of Warcraft\_retail_\Interface\AddOns\`.
- Requires WoW Retail, Midnight (12.1+). No required dependencies.

## The race

The bar is the dungeon: a straight road from entrance to finish, one finish line
at the right edge. Runners move by progress (enemy forces plus a segment per
boss), so whoever reaches the line first had the better time. You race above the
line as your portrait or raid marker; ghosts race below it. The gap zone between
you and the raced ghost glows green when you lead and shades toward red when
holding the ghost's pace would deplete the key.

Pace cars drive the road at exactly the chest times. The red +1 Sweeper must
never pass you. Tombstones mark deaths, yours and the ghosts'. Hover anything
on the track for the story behind it.

Under the bar, the Ghost Roster: up to three more ghosts racing you in parallel,
each with a live gap and speedrun-style boss laps (`B1 -0:12` means you killed
the first boss twelve seconds faster). A ghost that overtakes you and holds it
becomes the raced ghost on its own; click any row to race that one instead and
pin it.

Cross the finish line and the bar hands over to the Finish Report.

## The Finish Report

Every finish opens a report window, timed or depleted: your clock against the
timer, how far the next chest was, and on timed runs a score line that
matches what raider.io will say about the run. Below that, the race you just
ran: the finish gap against the ghost you raced, a small board with the
ghosts that finished closest to your clock, and a splits table with every
boss, your time next to the ghost's, the difference in green or red. Deaths
get a count, the time they cost, and a timeline strip with a skull per death.
A new personal best at that key level says so. Timed runs celebrate with a
checkered flag and your portrait hopping beside it, and a share button posts
the fresh ghost to guild or group chat as a clickable link.

Stored ghosts keep their reports too: the magnifier on any Ghost Library row
reopens one, compared against the closest other ghost you have for that
dungeon.

## The Rabbit

The Rabbit is the opponent when nothing else is: a steady runner that
finishes safely under the timer, so a fresh alt or a dungeon you never ran
still has something to beat. It steps aside as soon as real data exists.
Options let it always run as an extra lane, or never, and its pace has three
settings from gentle to brisk. It wears an actual rabbit's face, and the
brisker the pace, the less cute the rabbit.

## The Ghost Library

The minimap ghost opens it: every stored run from all your characters, one
tab per dungeon. Sort the rows by key, result, time, or date by clicking the
column headers. Pin the ghost you want to race next key, share or delete per
row, hide the ones you never want in the roster (hiding is per character, so
your alts keep their own view), and open any ghost's report with the
magnifier. The Select many button checks any number of runs and deletes them
with one confirm. Imports and the Raider.IO ghost live here too, and Open my
library online shows the whole collection in your browser.

## Sharing

Export any ghost as a compact string for Discord, or shift-click a row into
chat so a groupmate can grab it with one click. Imported ghosts carry the
sender's name and race you on your next key of that dungeon.

Party member names stay out of exports by default. Anonymous spec labels travel
instead, and a random Share Tag groups your alts for receivers without any real
identity attached.

## Ghost sources, in priority order

1. Imported ghosts.
2. Your own recorded runs (one slot per chest tier per character, dungeon, and level).
3. The Raider.IO replay, converted into a full ghost when you enter the dungeon (optional, needs RaiderIO).
4. The season best time the game knows for you.
5. The Rabbit, so the bar is useful from day one (plain par pace if you turned the Rabbit off).

## MDT

Optional. Runs remember which route they were played on, the bar shows a live
pull indicator against your selected route, and shared ghosts can carry the
route: one click gives the receiver a ready-made MDT import string for MDT's
own Import Preset dialog. Keystone Ghost tracks the current MDT only; if your
MDT and Keystone Ghost versions ever drift apart, one chat line tells you which
side to update.

## Where things live

Everything is in the UI. The minimap ghost opens the Ghost Library; sharing,
importing, pinning, hiding and deleting are buttons in it. Behavior settings
sit in the standard AddOns options panel, and size and position live in the
game's Edit Mode, where the bar is a proper system: drag to move, click for
dock, scale, opacity, and roster settings.

Want to see the race without running a key? Type `/kg test` for a demo at
15x speed.

## Good to know

- The race metric is count-based. The delta asks when the ghost had at least
  your enemy-forces count and your boss count, never which bosses or what
  route, so it can't be fooled by playing the dungeon in a different order.
- A `/reload` or client restart mid-key resumes the race with the full recorded
  timeline, and the run still saves as a ghost.
- Boss laps pair by boss identity, so the numbers stay correct on any route.
- Depleted runs are recorded but never race automatically. Pinning one is the
  only way to race it.

Bundled libraries: LibStub, CallbackHandler, LibDataBroker, LibDBIcon,
LibSerialize, LibDeflate, LibEditMode. MIT licensed.
