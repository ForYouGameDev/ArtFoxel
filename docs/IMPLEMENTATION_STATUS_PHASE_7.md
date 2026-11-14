# Phase 7 / 7.5 — implementation status

**Nothing here has been compiled, analysed or run.** The authoring sandbox had no Flutter/Dart SDK.
Run `flutter pub get && flutter analyze && flutter test` first and expect to fix small errors.

## Phase 7 (UI-wired)
| Item | Where | Status |
|---|---|---|
| 7.1 Comic document (pages, DPI, bleed/margins, panels, templates) | `lib/features/comic/domain/comic_model.dart`, `presentation/comic_studio_screen.dart` | Model + screen written, separate from sketch docs, route `/studio/comic` |
| 7.2 Screentone, speed lines, bubbles, narration | `comic_elements.dart`, `rendering/comic_painter.dart` | Same painter for preview and PNG export (guides preview-only) |
| 7.3 Text boxes + font import | `text_model.dart` | Fonts are validated (sfnt parse, restricted `fsType` refused, WOFF refused, licence acknowledgement) and stored per project; **no fonts bundled**; curved text **not implemented**; vertical text is simple glyph stacking |
| 7.4 Animation Studio | `lib/features/animation/*`, route `/studio/animation` | Separate workspace; Sketch Studio never opens it |
| 7.5 Playback/export | `animation_exporter.dart`, `image_codecs.dart` | GIF + PNG sequence written by our own encoders and re-read to verify size/delays/loop/order. **MP4 and audio reference are NOT offered** (no verified encoder/package). Onion skin is never exported |

## Phase 7.5 (engine modules, `lib/features/studio/engine/`)
These are **pure-Dart, unit-tested (on paper) domain modules. They are NOT yet wired into Sketch Studio UI.**
| Chunk | File | Notes |
|---|---|---|
| 7.5.1 | `input_engine.dart` | modes: realtime/constant/speed-dependent/fast-stroke, lazy guide, post smoothing, clamped prediction, corner preservation, taper, finger/stylus mappings with capability warnings, latency meter. Real latency numbers need on-device event/present timestamps |
| 7.5.2 + shortcuts/notes | `workspace_model.dart` | toolbar pin/order/hide, dockable panel state, UI scale, left-handed mirror, 6 presets, navigator maths, bookmarks, view aids, shortcuts, gestures, history slider, notes |
| 7.5.3 | `guides_selection.dart` | line/parallel/perpendicular/circle/ellipse/arc/polyline/hatching snapping; 1/2/3-point, isometric, curvilinear grids; selection masks (polygon/Bezier/brush/alpha), add/subtract/intersect, feather/smooth/grow/border, save/load, layer-mask conversion |
| 7.5.4 | `fill_clone.dart` | bucket fill (tolerance, contiguous, colour range, gap closing, anti-alias), gradient/pattern/solid paint, clone stamp (aligned, rotation, scale, merged source supplied by caller) |
| 7.5.5 | `transform_engine.dart` | pattern/array placement, symmetry, seamless tiles, affine/homography/mesh transforms from untouched source, liquify field (push/expand/pinch/swirl/restore/reconstruct). Raster transforms are **not lossless**; a warning is exposed |
| 7.5.6 | `reference_3d.dart` | mannequin FK pose model with joint limits, camera, light, primitives, saved poses; procedural paper textures. Reference data is never exported unless explicitly converted. **No mesh renderer** |
| 7.5.7 | `asset_exchange.dart`, `checkpoints.dart` | brush dynamics model; data-only asset packages (strict schema, whitelisted licences, no code keys, PNG magic check); local report queue (nothing is sent); chunk-deduplicated checkpoints, separate from undo |
| 7.5.8 | `color_management.dart`, `vector_paths.dart` | LAB/LCH/naive CMYK/Display P3; ICC header validation only. **No ICC conversion and no soft proof** (`ColorManagement.softProofAvailable == false`). Editable Bezier paths, paragraph wrapping |
| 7.5.9 | `performance.dart` | device tiers, profiles, canvas guard, dirty tile grid, stroke batching, byte LRU, undo budget, frame profiler, adaptive preview, isolate helper |

## Known gaps
- 7.5.x modules need integration into `SketchController`/UI; the persistence of workspace, checkpoints and assets to disk is not wired.
- Dual-brush, wetness and paint-mixing are parameters only; the brush engine does not render them yet.
- CMYK is the naive formula. Hash-based paper textures are deterministic on native only.
- Push to GitHub failed with 403 (no write access from the sandbox). Apply the zip or grant access.
