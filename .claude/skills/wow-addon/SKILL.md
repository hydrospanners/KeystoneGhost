---
name: wow-addon
description: Battle-tested architecture and safety rules for building World of Warcraft addons, distilled from KeystoneGhost development. Use this whenever Fredrik starts, scaffolds, or plans a new WoW addon, and for any addon architecture decision in an existing one — where a setting belongs (Edit Mode vs options panel), first-run/placement UX, integrating with another addon (RaiderIO, MDT, EllesmereUI, ElvUI…), Midnight secret values, addon CPU/GC/freeze/crash concerns, SavedVariables design, TOC files, or CurseForge packaging and releases. Trigger on mentions of "WoW addon", "new addon", "TOC", "SavedVariables", "Edit Mode integration", "addon options", "addon crash/freeze", "CurseForge", or Lua work destined for Interface/AddOns — even when the question doesn't name this skill.
---

# WoW Addon Development

Rules earned in production (KeystoneGhost, 2026). The governing sentence: a
player's game must never stutter, freeze, or crash because of an addon —
"causing crashes is not acceptable" (Fredrik). Every rule below serves it.
Reference implementation: github.com/hydrospanners/KeystoneGhost — its module
headers carry worked examples and the decision history behind each rule.

## The load budget: quiet phases pay for everything

Define the content's lifecycle phases FIRST and write them into a doc the whole
project shares (KeystoneGhost: docs/LIFECYCLE.md — Walk-In → Key Activation →
Warm-Up → Key Run). Then place the work:

- Heavy work (data conversion, third-party reach-ins, cache building) runs ONLY
  in quiet phases: login, zone-in/staging, countdowns — moments when a CPU
  spike is free because nothing is at stake.
- The live phase (combat, a running key) gets zero conversions and strictly
  bounded per-tick work. Not ready when the gates dropped? Run without it and
  self-heal at the next quiet phase. A missing feature beats a stutter; a
  stutter beats a crash.

## Third-party integrations: budgeted, then silent

Another addon's internals are weather, not API — absent, half-loaded, or
reshaped by any patch:

- Feature-detect every hop in the chain, pcall every call, type-check every
  shape before use. Never index blind.
- BUDGET the attempts: N tries, spaced seconds apart, in a quiet phase — then
  stop asking for the rest of the session/run. An unbudgeted retry loop against
  a missing provider re-ran a heavy conversion every half-second through
  KeystoneGhost's opening pulls; the cap (3 tries, 3 s apart) removed both the
  spike and the crash surface.
- Cache conversions behind a cheap identity check (an id field, or a
  header-field triple) so repeat calls short-circuit instead of re-converting.

## Secrets (Midnight 12.x)

Values from scenario/unit APIs can be SECRET: comparing or indexing them
throws.

- Gate every read through canaccessvalue/issecretvalue wrappers (readNum /
  readBool helpers).
- Presence is nil-testable even when the value isn't — branch on nil, never on
  the value.
- A secret may be fed UNTOUCHED into a C-side render sink (e.g.
  Texture:SetSpriteSheetCell on a sprite sheet) — never into Lua logic. Two
  secrets can't be diffed, so repainting must be blind — put it on a clock
  (0.5 s), never on every frame.

## Performance floors

- Pool every widget. Frames, textures, and fontstrings are never
  garbage-collected: acquire by index, hide the surplus, create only inside
  Build()-style constructors.
- Per-frame work must be bounded by a constant, not by data size — caps plus
  "hide the rest" beat completeness.
- Searching time-series data: binary-search to a SAFE START (target minus a
  slack covering the known wobble), then finish with the plain first-match
  linear scan. Real recorded data is almost sorted; never assume sorted.
- Record change-driven, not clock-driven: events append nodes only when state
  actually moved (coalesce same-frame bursts), with a slow reconcile heartbeat
  as the failsafe for dropped events.
- SavedVariables persistence is free: assign the live table by reference into
  the SV slot. The client serializes only at logout/reload — addons cannot
  touch disk mid-play, so never "optimize" saving and never fear it mid-combat.

## First-run & placement UX

An addon whose UI only appears in its live context cannot be placed before it
matters — and Edit Mode registration alone is not discoverability if the frame
has never drawn.

- Stage the UI at login with demo data and a "drag me into place" handle until
  it HAS BEEN PLACED.
- "Placed" is a goal state, account-wide (one placement covers all
  characters): a handle drag, an Edit Mode drag, or a deliberate close ("keep
  it right here" — dock users never need to drag) all stamp it. Session events
  (real content starting, Edit Mode opening, a test mode) dismiss WITHOUT
  stamping — the offer returns next login, on any character.
- Interrupt-safe by construction: logins happen mid-combat and mid-instance
  (reconnects). Stand the show down during combat and return when it ends; an
  unrequested tutorial never sits over live play.
- Demo data needs a stage manager: every door into REAL data must explicitly
  evict demo mode (in KeystoneGhost, both recorder entry points — fresh key
  AND mid-run adoption after a reconnect — kill the show). Precedence bugs
  here are silent and paint fake data over a live game.
- When adding a first-run flow to a shipping addon, grandfather existing
  installs: any prior-login marker (a schema version) counts as already
  placed.

## Settings architecture

- Edit Mode: SIZE & POSITION only — where frames sit, how big, their chrome
  and footprint (dock, scale, opacity, row counts, panel on/off).
- Options panel (Settings API): HOW things display (palettes, readout
  language, what icons wear, which marks draw) plus everything behavioral
  (sharing, data handling). Accessibility settings always live here.
- Verified 12.x Settings shapes: RegisterVerticalLayoutCategory +
  RegisterProxySetting + CreateCheckbox / CreateDropdown; buttons via
  CreateSettingsButtonInitializer and section headers via
  CreateSettingsListSectionHeaderInitializer through SettingsPanel:GetLayout.
  Guard every one so an API-less patch costs widgets, never the panel.
- Destructive settings actions go behind a StaticPopup confirm that NAMES what
  is being destroyed and spells out the cost in the player's terms.

## Data discipline

- Integers for facts, floats for rendering; quantize once, at save time.
- EVERYTHING from the wire passes one sanitization gate — whitelist fields,
  type-check, cap string lengths and array sizes — before touching
  SavedVariables. Unknown fields never survive an import.
- Schema changes are numbered idempotent migrations, run once per login; every
  migration must also consider in-flight state slots (a persisted live
  recording), where nil-ing is always a legal answer.
- Keep pure logic in WoW-API-free modules: syntax-check with `luac5.1 -p`
  (WoW is Lua 5.1 — no `//`, no goto-era idioms) and test offline. The bug
  that survives five releases is the one only reachable in-game.

## Release

- Package with the BigWigs packager on tag push; `.pkgmeta` keeps repo/meta
  files (docs, tests, .claude, logos, changelog) out of the addon zip; ship a
  manual changelog in user voice, honest about anything dropped and why.
- The TOC version bump, changelog entry, and any grandfathering land on the
  release branch; tags come from the publish pipeline after merge, never from
  the feature branch.
