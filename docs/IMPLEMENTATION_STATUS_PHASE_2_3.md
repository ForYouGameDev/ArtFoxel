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

---

# Phase 5 and Phase 6 status

**Read this first:** none of this code has been compiled, analysed (`flutter analyze`) or run
(`flutter test`) — the authoring environment had no Flutter/Dart SDK. Expect a round of compile
fixes. The tests were written together with the code but have never been executed.

## Phase 5

### 5.1 Colour Studio (`presentation/color_sheet.dart`, `domain/color_math.dart`, `domain/palette.dart`)
* RGB / HSV / HSL sliders, HEX field with validation (RGB or RRGGBB, optional `#`), eyedropper,
  foreground **and** background colour (swap / reset), recent colours, WCAG contrast of FG vs BG.
* Harmony suggestions: complementary, analogous, triadic, tetradic, split-complementary, monochromatic.
* Named palettes (built-ins + your own, stored in SharedPreferences `palette_library_v1`).
  Import/export is **copy/paste** of ARTFOXEL JSON or GIMP `.gpl` (no file dialog yet).
* One colour pair (`SketchController.colorArgb` / `bgColorArgb`) feeds brushes, shape outline (FG),
  shape fill (BG) and gradient stops.
* Not done: text tool colour (there is no text tool yet), alpha in the colour picker, colour wheel.

### 5.2 Gradients (`domain/gradient_model.dart`, `presentation/gradient_editor.dart`)
* Linear and radial, 2–16 stops with position/colour/opacity, linear/smooth/steps interpolation,
  8 presets, own gradients saved in `gradient_library_v1`.
* Gradients are editable on **shapes** (fill) and are saved in the project. Gradient map (Phase 6)
  uses the presets.
* **Deferred, not faked:** angular, reflected and diamond gradients; gradient fill of arbitrary
  paint layers / selections (only shape fills).

### 5.3 Rulers, grids, guides, symmetry (`domain/assist_model.dart`, `application/sketch_controller_assist.dart`, `presentation/assist_sheet.dart`)
* Rulers: line, circle, ellipse, parallel lines, polygon, perspective (rays from a point).
  Strokes snap to the ruler; “Turn ruler into artwork” is the only way a ruler becomes pixels.
* Square and isometric grids with snap, guides with snap, horizon line, up to 3 vanishing points.
* Symmetry: vertical, horizontal, both, radial, radial+mirror, kaleidoscope. A stroke and all its
  copies are one undo step. The live stroke shows thin preview lines for the copies.
* Stored in the project under the optional `assist` key; never exported.
* Limits: ruler/VP positions are set with sliders (no on-canvas dragging of ruler handles); the
  ellipse ruler uses radial projection (approximate); perspective ruler locks to the ray through
  the stroke start; copies of directional brush tips are mirrored by geometry only.

### 5.4 Shapes (`domain/shape_model.dart`, `application/sketch_controller_shapes.dart`, `presentation/shape_sheet.dart`)
* Line, rectangle, rounded rectangle, circle, ellipse, polygon, star, arc, polyline, quadratic and
  cubic Bézier. Fill (solid/gradient), stroke width/colour, round **handles** to edit points,
  drag a shape to move it. Stored as geometry on the paint layer (`layer.shapes`), saved in the
  project, rendered above the layer's strokes. “Rasterize layer shapes” bakes them into a new image layer.
* Smart recognition: “Clean up last stroke” converts a freehand stroke only if it is clearly a line,
  circle, axis-aligned rectangle or triangle; otherwise nothing changes.
* Not done: shapes are not affected by layer transforms/selection masks as geometry (a layer
  transform bakes only strokes — move shapes separately), no ellipse rotation, no snapping of
  handles to other shapes, shapes cannot be reordered.

### 5.5 Reference Studio (`domain/reference_model.dart`, `application/sketch_controller_references.dart`, `presentation/reference_studio.dart`)
* Up to 24 images (8 MB each) added with `file_picker` (new dependency, version not verified — run
  `flutter pub get`). Hide, lock, remove, scale, rotate, opacity, move (sliders), board sections.
* Stored in a separate `references.json` next to the sketch; never in `sketch.json`; drawn only in the
  editing overlay. `ExportPlan.standard` excludes references and assists (tested); there is no
  exporter yet — it must use `ExportPlan`.
* Colour picking: toggle “Eyedropper reads references”.
* Not done: dragging/pinching a reference directly on the canvas, bulk organising/boards beyond sections.

## Phase 6

### Engine (`lib/features/studio/filters/`)
Pure-Dart RGBA engine, ~48 filters: brightness, contrast, exposure, gamma, saturation, vibrance, hue,
temperature, tint, highlights/shadows/whites/blacks, opacity, levels, tone curve (5 points), colour
balance, gradient map (presets), colorize, posterize, threshold, grayscale, B&W mixer, replace colour,
Gaussian/box/motion(directional)/radial/zoom/surface blur, sharpen, unsharp mask, glow, bloom, drop
shadow, vignette, outline, sketch, pencil, charcoal, watercolor, oil, halftone, dither, noise, grain,
pixelate, mosaic, canvas texture, comic, crosshatch, wave, ripple, fisheye, twirl, bulge, pinch,
perspective tilt, chromatic aberration, RGB split.
* **Labelled approximations** (shown in the UI): Gaussian (3 box passes), surface (bilateral window),
  glow/bloom (blur + screen), pencil, charcoal, watercolor, oil, texture, grain, comic, perspective.
* **Not implemented:** lens flare (omitted rather than faked), real motion-vector “surface” blur on
  GPU, curves with arbitrary points, per-channel curves, HDR.
* Alpha is preserved by colour filters (tested); blurs work on premultiplied data.

### Non-destructive stack, preview, apply (`application/sketch_controller_filters.dart`, `presentation/filter_studio.dart`)
* The stack lives on **image layers** (`layer.filters`); the original pixels stay in `layer.image`.
  Paint layers are first converted to an image layer (the paint layer is kept, hidden; undoable).
* Live preview runs on a ≤1024 px copy in a background isolate; Apply runs full resolution in an
  isolate with progress and cancel. “Apply (keep editable)” stores the stack; “Apply permanently”
  replaces the pixels (undoable). Cancel restores everything. Before/after toggle, per-filter
  enable/reorder/reset/remove, presets (6 built-in + your own in `filter_presets_v1`), session history.
* Memory: images above 4096×4096 px are refused with a message; local filters on images above ~2 MP
  run in horizontal bands (tested against the whole-image result). Distortion/vignette/radial filters
  are not banded.
* “Adjustment layers” are implemented as a filter stack on an image layer. They do **not** act on the
  layers below them (that would need a GPU compositing pass) — documented limitation.
* On open, cached results are rebuilt in the background; the project file stores only the stack.

### Tests added
`color_palette_gradient_test.dart`, `assist_shape_reference_test.dart`, `filters_test.dart`,
`phase56_document_test.dart` (round trips, snapping, symmetry, recognition, alpha, budgets, banding,
cancellation, repeated adjustments, save/reopen).
