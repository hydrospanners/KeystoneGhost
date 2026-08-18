-- KeystoneGhost_MDTData — demand-loaded bridge to Mythic Dungeon Tools' data.
--
-- This module exists to stay compatible with MDT's new split architecture
-- (6.2+, core + LoadOnDemand UI, addon table file-local). Latest-only by
-- policy: it tracks the current MDT, never old versions.
--
-- MDT 6.2 split in two and made its addon table file-local: the tables
-- Route.lua reads (dungeonEnemies, dungeonList, mapInfo) no longer live on any
-- global, and the public MythicDungeonToolsAPI cannot stand in for them — its
-- GetEnemyForces takes an npc id that only the private enemy table could
-- resolve, and a route's pulls reference enemies by index, not npc id.
--
-- MDT's own UI half is built on cross-folder TOC includes (its whole .toc is
-- `..\MythicDungeonTools\...` lines), and this module borrows exactly that
-- mechanism: the .toc line after this file loads MDT's static dungeon files —
-- pure declarative table assignments — from the USER'S OWN INSTALL into this
-- addon's namespace. Nothing of MDT's is bundled in our zip, nothing of MDT's
-- runtime is touched, and the data can never go stale against the installed
-- MDT because it IS the installed MDT's files.
--
-- This module is LoadOnDemand and `## Dependencies: MythicDungeonTools`, so
-- Route.lua's single C_AddOns.LoadAddOn call doubles as the "is MDT installed
-- and enabled" check: missing or disabled MDT fails the load cleanly and every
-- route feature degrades to the MDT-absent behaviour it has always had.
--
-- The seeded fields below are the union of what MDT's dungeon files write into
-- (the shipping precedent for this exact pattern is
-- MythicDungeonTools_NextPullTracker's adapter). L is a self-index metatable:
-- the files resolve display names through it and identity is all we need.
--
-- MAINTENANCE: the include path names MDT's per-expansion data folder
-- ("Midnight"). When MDT rotates it for the next expansion, update the .toc
-- line — until then this module loads empty and Route.lua treats that as
-- MDT-absent, silently and safely.
local _, D = ...

D.AddonName = "MythicDungeonTools"
D.BackdropColor = { 0.058823399245739, 0.058823399245739, 0.058823399245739, 0.9 }
D.L = setmetatable({}, { __index = function(_, key) return key end })

D.dungeonEnemies = {}
D.dungeonList = {}
D.dungeonMaps = {}
D.dungeonSubLevels = {}
D.dungeonTotalCount = {}
D.mapInfo = {}
D.mapPOIs = {}
D.mapPOIsFilter = {}
D.scaleMultiplier = {}
D.zoneIdToDungeonIdx = {}
D.dungeonSelectionToIndex = {}
D.seasonList = {}

-- The one global handle Route.lua reads after its LoadAddOn call succeeds.
KeystoneGhost_MDTData = D
