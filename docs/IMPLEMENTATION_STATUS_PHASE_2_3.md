# ARTFOXEL — Phase 2 & 3 implementation status

**Read this first:** none of this code has been compiled, analyzed or run.
It was written in an environment with no Flutter/Dart SDK and no network
access to pub/Gradle. Run `flutter pub get && flutter analyze && flutter test`
(or the repo's GitHub Actions workflow) and fix whatever the analyzer reports
before trusting any item below. "Implemented" means "code written", not
"verified on a device".

## Phase 2 — Drawing engine
| Chunk | What exists | Not done / limits |
|---|---|---|
| 2.1 Canvas viewport | Pre-existing viewport; rotation toggle added | — |
| 2.2 Input | Finger/stylus/mouse behaviors, palm rejection (setting), capability detection (pressure/tilt only if reported) | Palm rejection is heuristic, needs real-device tuning |
| 2.3 Brush engine | Stroke-based model (strokes are the source of truth), deterministic seeded dabs, stamp/line/watercolor engines, 15 built-in brushes, eraser, procedural grain | Single full-canvas raster capped at 4096 px (no tiles); live stroke re-rendered fully each frame (O(n)) |
| 2.4 Stabilizer | Online EMA stabilizer, speed-adaptive, corner preservation, prediction, low-latency bypass | Raw (unstabilized) points are not stored |
| 2.5 Persistence | Atomic save (tmp+rename), `.bak`, crash-recovery checkpoint, autosave, lifecycle flush, project gallery integration | Single layer in UI; no PNG export |

## Phase 3 — Brush Lab
Brush preset schema v1 (data-only JSON, validated ranges), library with
favorites/groups, create/duplicate/rename/delete, live test canvas,
import/export with size cap, schema-version check, external-reference
rejection, duplicate-name handling and v0→v1 migration, quarantine of
invalid saved brushes.
Limits: import/export is via clipboard paste (no file-picker package added);
built-in brushes are read-only (duplicate to edit).

## Known gaps from Phase 1 (not touched here)
New Canvas screen (new sketches use 1536×2048 portrait), Beginner/Pro mode
and profile editing should be re-checked against the Phase 1 list.

## Tests added
`test/features/studio/brush_system_test.dart`,
`sketch_persistence_test.dart`, `brush_library_repository_test.dart`;
`sketch_canvas_stage_test.dart` now wraps screens in `ProviderScope`.
