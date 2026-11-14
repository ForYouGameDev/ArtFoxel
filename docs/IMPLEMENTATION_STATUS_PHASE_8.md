# Phase 8 — Project management, image import/export, timelapse

**Nothing here was compiled, analysed or run** (no Flutter/Dart SDK in the authoring sandbox). Expect some compile errors; run `flutter pub get && flutter analyze && flutter test` first.

## 8.1 `.artfoxel` package
- `lib/core/io/{sha256,zip_codec}.dart`: own SHA-256 and ZIP (store + deflate, CRC-32, safe names, size caps).
- `lib/features/project/domain/artfoxel_package.dart`: manifest schema 2 (v1→v2 migration), SHA-256 per entry, content validated with the real document parsers, newer-schema refusal, degraded open when only optional parts (references, fonts, thumbnail, extras) are damaged. Only damaged content is fatal.
- References are stored in their own entry, never in the artwork. Import always creates a NEW project (never overwrites).

## 8.2 Library lifecycle
- `lib/features/project/data/project_files.dart`: duplicate, trash (14 days) + undo, versions (named + automatic, pruned), backup/restore of the whole library, thumbnails.
- UI: Projects screen — Comic/Favourites filters, thumbnails, card menu (rename, favourite, duplicate, save a copy, delete with Undo), import `.artfoxel`, back up / restore. Sketch Studio — Save now, Restore points, thumbnail refresh and automatic restore point after saves, existing autosave indicator and crash recovery.
- Sketch projects open in Sketch Studio, animation projects in Animation Studio, comics in Comic Studio; workspaces are not merged.

## 8.3 Sketch import
Import sheet: new layer (multiple files), replace selected image layer (keeps blend/opacity/mask), add as reference. Placement dialog: fit/fill/1:1/stretch, scale, rotation, offset, flip, crop with live outline. Home "Import Image" opens the picture as a new canvas. PNG/JPG/JPEG/WebP/GIF (first frame). **HEIC is refused with a message** (no verified decoder).

## 8.4 Animation import
Inside Animation Studio: background, animation layer, current-frame content, reference (editing overlay only, never exported), character artwork, image sequence as consecutive frames (natural name order). Images are stored as PNG files in the project's `assets/`; unused assets are pruned on save. Limits: 25 MB file, 2048 px stored side, asset/layer/frame caps.

## 8.5 Export
- PNG (transparent or flattened) via pure-Dart encoder; JPEG/WebP via the `flutter_image_compress` plugin — **unverified on device**; if the platform cannot encode, the export fails with a message (no silent format swap). Every export is re-read and checked (format, size, alpha).
- **PSD is not implemented.** Layered fallback: OpenRaster `.ora` (layers, groups, opacity, visibility, blend modes; masks and filters baked into pixels; clipping shown only by name).
- Project backup (`.artfoxel`), library backup (ZIP of packages).
- Timelapse: frames captured only for meaningful drawing events (coalesced, thinned), exported as GIF or PNG frames. **MP4 is not offered.** Audio is not supported.
- References, onion skin and guides are excluded unless the matching option is set.

## Wired vs domain-only
Wired to UI: all of the above except favourites/tags editing beyond the favourite toggle, and sort options beyond the two existing ones (the richer `LibrarySort` exists in the domain only). Comic Studio does not yet have its own import/export sheet.

## Tests added
`test/core/io`, `test/features/project`, `test/features/imaging`, `test/features/animation/animation_images_test.dart`.

## Sketch Studio usability pass (after Phase 8)
Unverified, not compiled.
- Two-finger gesture now pans in every direction while pinching (the old code kept the point under the *current* fingers fixed, so it never panned).
- New Move / Resize tool (`SketchTool.move`, `sketch_controller_manipulate.dart`): drag to move; corner handles resize (aspect kept); edge handles stretch (layers, shapes); top handle rotates (15° snap); two fingers on the selected object pinch/twist/move it. Targets: whole active layer (strokes, images, shapes), a selected shape (no rotation), a selected reference image (aspect kept). Tap to select: reference → shape → layer. Delete works for references and shapes; layers are deleted from the layer panel.
- Importing an image goes straight into Move / Resize. Dock has Move and Add image buttons; extras moved to an overflow menu. Full-screen canvas mode (app bar and dock hidden, floating undo/redo/layers/move/add-image bar); canvas frame, padding and info chips removed.
