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

---

# Phase 4 — Layers, masks, selection, transforms

**Same warning as above: written without a Flutter SDK; nothing here has been
compiled, analyzed or run.** Pure-Dart logic (blend math, masks, selection
algorithms, layer operations, geometry, serialization, controller history) has
unit tests written for it; the GPU compositing path has no automated test.

## 4.1 Layer model and panel
- Layers and groups (flat storage with `parentId`, groups listed before their
  children), stable never-reused ids (`layer-N`), create / rename / duplicate
  (groups deep-copied with new ids) / delete / reorder / move into groups,
  visibility, lock (groups cascade), opacity, thumbnails (drawn live through
  the compositor, no flattening), layer selection, collapsible groups.
- Rendering (`LayerCompositor`) is separate from UI state; ordinary edits never
  flatten the project. Max 32 layers+groups (memory: one GPU raster per layer).
- Undo history is now a per-session stack (limit 200). After reopening a
  project the saved strokes are no longer individually undoable (previously
  undo popped strokes of the loaded file).
- Not done: drag-and-drop reordering in the panel (use the up/down buttons),
  multi-select, merge down / flatten.

## 4.2 Blend modes
- Exposed (17, all delegated to the engine's blend modes): Normal, Multiply,
  Screen, Overlay, Darken, Lighten, Color Dodge, Color Burn, Linear Dodge
  (= `BlendMode.plus`), Difference, Exclusion, Soft Light, Hard Light, Hue,
  Saturation, Color, Luminosity.
- **Deliberately not exposed:** Linear Burn, Vivid Light, Linear Light, Pin
  Light, Hard Mix — Skia has no equivalent and an emulation could not be
  verified here. Stored files naming them load as Normal.
- `BlendMath` holds W3C reference formulas, tested against hand-computed
  values. This verifies the *specification*, not Skia/Impeller's output: the
  on-device result must still be compared by eye / golden test.
- Groups are isolated (composited as a unit); there is no pass-through mode.

## 4.3 Alpha lock, clipping, masks
- Alpha lock: strokes carry an `alphaLock` flag and are drawn with `srcATop`;
  erasing is refused on locked layers. Clip to layer below (per sibling run;
  clipped layers use their own blend/opacity but are confined to the base's
  alpha). Layer masks = optional bitmap (reduced-res, gzip+base64) + grayscale
  strokes; enable/disable, invert, paint on mask, add (show all / hide all /
  from selection), mask → selection, delete.
- **Apply mask works only for image layers** (pixel alpha is baked). Paint
  layers keep editable strokes, so their masks stay non-destructive; "apply"
  would require rasterizing, which is not implemented. Undo restores a
  deleted/applied mask.
- Eraser strokes on a mask appear when the stroke ends (not live).

## 4.4 Selection
- Rectangle, ellipse, freehand lasso, polygon lasso (tap points, tap near the
  first one or "Close polygon"), magic wand (tolerance, contiguous, sample all
  layers or active layer), colour range (tolerance + fuzziness). Replace / add /
  subtract / intersect, select all, deselect, invert, expand, contract,
  feather, copy, copy merged, cut, paste, selection → new layer, selection →
  mask, mask → selection, outline / tint / hidden display.
- Selection is an 8-bit mask in document coordinates at ≤ 2048 px (scaled for
  larger canvases), independent of zoom/pan/rotation. It is cleared when the
  canvas size changes (it is not resampled).
- Cut = copy + hide the area through the layer's mask (non-destructive).
- Pasted / "to layer" content is an **image layer** (pixels captured at
  selection resolution, ≤ 2048 px long side — lower quality than the document
  on very large canvases). Image layers cannot be painted on.
- **Painting is not clipped to the selection yet** (strokes ignore it).
- The in-app clipboard is not the system clipboard.

## 4.5 Transform and crop
- Move / scale (uniform or not) / rotate / flip / skew with a 9-point pivot,
  live preview, Apply / Cancel / Reset, one undo step. Works on a layer or a
  whole group. The source is untouched until Apply.
- Paint layers: transform is baked into stroke point coordinates and brush
  sizes (still editable strokes; tip shapes are not skewed/rotated, only their
  path and size). Image layers: pixels untouched, placement matrix changes.
  Bitmap masks are resampled (bilinear).
- Controls are numeric sliders; there are **no on-canvas drag handles** yet.
  "Transform selection" is done by Selection → To new layer, then Transform.
- Crop image / Resize canvas (anchor) / Resize image are three separate
  operations with a dialog, each one undo step. Strokes outside a shrunken
  canvas are kept unless "discard" is ticked.
- Project format is now version 2 (v1 files open with default layer settings).

## Tests added in Phase 4
`blend_and_math_test.dart`, `selection_mask_test.dart`,
`layers_document_test.dart` (ops, serialization, migration, geometry),
`layers_controller_test.dart` (history, masks, selection, transform, canvas
size), `layer_panel_test.dart` (widget), plus a layers round-trip in
`sketch_persistence_test.dart`. Magic-wand/colour-range/copy/cut/paste
*pixel reads* and all GPU rendering paths are untested.
