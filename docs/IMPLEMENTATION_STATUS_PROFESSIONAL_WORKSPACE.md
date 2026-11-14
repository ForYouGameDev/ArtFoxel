# Professional Creative Workspace Upgrade — implementation status

**Nothing in this change was compiled, analysed or run.** The sandbox has no Flutter/Dart SDK.
Run `dart format .`, `flutter analyze`, `flutter test` and `flutter build apk --debug` first and
fix whatever they report; expect some small API-mismatch errors.

## What was built

### Smudge engine
* `domain/smudge_planner.dart` (pure Dart, deterministic, unit tested) turns a stroke into pixel-moving ops.
* `rendering/smudge_engine.dart` moves real pixels of the layer with GPU image shaders
  (`dstOut` erase + displaced `ImageShader` patch; only the *mask* is feathered, never the artwork).
* `SketchRaster._render` renders strokes in segments so a smudge stroke sees everything painted before it;
  undo/redo rebuild works through checkpoints. Live preview via `LayerCompositor._paintLive`.
* 10 modes, each with different geometry: basic, soft, hard, finger (long drag), wet (trailing film),
  oil (3 bristle lanes), colour mixing (carries the start colour), texture (random bristle jitter),
  directional (locked direction), blend (averages both sides). Controls: strength, wetness, pickup, deposit.
* Limits: works on painted strokes only (not on imported image layers or masks); ignores alpha lock;
  samples the layer as it was at stroke start (no live feedback while the stroke is drawn); not profiled.

### Colour Studio
* `color_wheel.dart`: real HSV hue ring + SV square or SV triangle (barycentric, additive-gradient fill).
* LAB (D65) and CMYK conversions, HSV/HSL/RGB/HEX sliders, previous/current colour, FG/BG swap,
  recent colours, palettes with folders, palette import/export (existing), gradient chips,
  harmony (existing), eyedropper (existing), compact floating panel (`compact_color_panel.dart`).
* "Alpha" is the brush opacity (stroke colours are stored opaque + stroke opacity).

### Brush library (97 new presets, 100+ total)
Sketching (HB–8B, mechanical, graphite, soft/hard/rough sketch, blueprint, construction), inking
(G-pen, technical, mapping, dip, comic, smooth, rough, brush pen, calligraphy, fineliner, monoline,
variable width), painting (round/flat/filbert/dry/wet/oil/acrylic/gouache/thick/impasto), watercolor (8),
airbrush (5), smudge/blend (14), texture (13), special (star, particle, confetti, glitter, flame, smoke,
fur, hair, grass, leaves, flower, patterns, shape stamp, texture stamp), eraser/utility (5).
Each differs in engine, tip (new: triangle, leaf, flower, blade, flame), grain, dynamics, spacing,
jitter and accumulation. Not supported: user-imported texture/stamp images, true fluid oil simulation.

### Quick strip and settings
Featured (10 defaults), Recommended, Recent, Favorites, Custom; pin/unpin/move/reset (persisted in
`brush_library_v1`); previews drawn by the real engines. Brush editor: expandable sections, pressure-curve
editors (size and opacity), reset-to-defaults.

### Workspace UI (`workspace_shell.dart`, shared by both studios)
Compact top bar, floating side toolbar, collapsible bottom panel, canvas-only mode (restores exactly),
left/right-handed, Beginner/Professional, tool visibility/order, all persisted (`workspace_layout_v1`).
Nothing was removed: Beginner only hides toolbar buttons that stay reachable in menus.
Not built: a pixel **bucket fill** tool and a **text** tool (shape/gradient fills exist).

### Animation Studio parity
Each frame owns a full `SketchDocumentData` (layers, masks, shapes, all brushes incl. smudge) and its own
`SketchController` (per-frame undo/redo, kept for the 8 most recently used frames). Timeline (collapsible,
adjustable thumbnails), prev/next, playback/loop/range, FPS, onion skin settings, background colour,
duplicate/delete/reorder/hold. Old animations (v1/v2 vector strokes) open and are converted per frame on
first edit. Onion skin and reference pictures are editing overlays only and are never exported.
Exports: GIF and PNG sequence (verified). **MP4 is not available** (no verified encoder).
Limits: switching frames resets undo of evicted frames; sketch image layers inside frames increase file size.

## Files
See the git diff; new files include `smudge_planner.dart`, `smudge_engine.dart`, `builtin_brushes_extra.dart`,
`color_wheel.dart`, `compact_color_panel.dart`, `brush_quick_strip.dart`, `pressure_curve_editor.dart`,
`workspace_layout.dart`, `workspace_shell.dart`, `workspace_layout_sheet.dart`, `frame_art.dart`.

## Tests added (not run)
`smudge_planner_test`, `color_studio_math_test`, `brush_quick_strip_test`, `workspace_layout_test`, `frame_art_test`.
