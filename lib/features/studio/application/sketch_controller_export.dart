part of 'sketch_controller.dart';

/// Phase 8: image import, flat export, per-layer export and thumbnails.
extension SketchExportActions on SketchController {
  // ----------------------------------------------------------------- import

  LayerImage _layerImageFrom(RasterPixels p, CropRect crop) {
    if (crop.isFull) return LayerImage(width: p.width, height: p.height, rgba: p.rgba);
    final (x, y, cw, ch) = crop.pixels(p.width, p.height);
    return LayerImage(width: cw, height: ch, rgba: cropRgba(p.rgba, p.width, p.height, x, y, cw, ch));
  }

  Affine2D _importMatrix(ImportPlan plan, LayerImage img, ImagePlacement placement) {
    // Placement is computed against the ORIGINAL file size, then mapped from
    // decoded pixels (possibly downscaled) back to it.
    final cropped = placement.crop.clamped();
    final origW = (plan.info.width * cropped.width).round().clamp(1, 1 << 20);
    final origH = (plan.info.height * cropped.height).round().clamp(1, 1 << 20);
    final m = placement.copyWith(crop: const CropRect()).toAffine(data.width, data.height, origW, origH);
    return m * Affine2D.scale(origW / img.width, origH / img.height);
  }

  /// Imports [bytes] as a new image layer above the active layer, keeping the
  /// aspect ratio. Returns false (with a notice) on failure.
  Future<bool> importImageAsLayer(
    Uint8List bytes,
    String name, {
    ImagePlacement placement = const ImagePlacement(),
  }) async {
    try {
      final (pixels, plan) = await decodeImageBytes(bytes, fileName: name);
      final img = _layerImageFrom(pixels, placement.crop);
      final matrix = _importMatrix(plan, img, placement);
      var ok = false;
      _guard(() {
        _recordStructural('Import image', () {
          final layer = SketchLayerData(
            id: LayerOps.newId(data),
            name: LayerOps.sanitizeName(name.replaceAll(RegExp(r'\.[A-Za-z0-9]{2,5}$'), '')),
            kind: LayerKind.image,
            image: img,
            matrix: matrix,
          );
          LayerOps.insert(data, layer, aboveId: activeLayerId);
          activeLayerId = layer.id;
          editingMask = false;
        });
        ok = true;
      });
      for (final w in plan.warnings) {
        _notice(w);
      }
      return ok;
    } on ImageImportException catch (e) {
      _notice(e.message);
      return false;
    }
  }

  /// Replaces the pixels of the selected image layer, keeping its name,
  /// blend mode, opacity, mask and position slot in the stack.
  Future<bool> replaceImageLayer(
    String layerId,
    Uint8List bytes,
    String name, {
    ImagePlacement placement = const ImagePlacement(),
  }) async {
    final layer = data.layerById(layerId);
    if (layer == null || !layer.isImage) {
      _notice('Select an image layer to replace.');
      return false;
    }
    try {
      final (pixels, plan) = await decodeImageBytes(bytes, fileName: name);
      final img = _layerImageFrom(pixels, placement.crop);
      final matrix = _importMatrix(plan, img, placement);
      _guard(() {
        _recordStructural('Replace image', () {
          final target = data.layerById(layerId)!;
          target.image = img;
          target.matrix = matrix;
          target.processed = null; // filters re-run on the new pixels
          target.processedSig = null;
        });
      });
      unawaited(rebuildFilterCaches());
      for (final w in plan.warnings) {
        _notice(w);
      }
      return true;
    } on ImageImportException catch (e) {
      _notice(e.message);
      return false;
    }
  }

  /// Adds the image to the reference board only. It is NOT part of the
  /// artwork or of any export unless the user converts it to a layer.
  Future<bool> importImageAsReference(Uint8List bytes, String name) async {
    try {
      ImportRules.plan(bytes, fileName: name);
    } on ImageImportException catch (e) {
      _notice(e.message);
      return false;
    }
    return addReference(name, bytes);
  }

  // ----------------------------------------------------------------- export

  Future<ui.Image> _renderImage(ExportOptions o, ExportSize size) async {
    await compositor.prepareAll();
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec);
    canvas.scale(size.width / data.width, size.height / data.height);
    final opaque = !o.keepsAlpha;
    if (opaque) {
      canvas.drawRect(
        Rect.fromLTWH(0, 0, data.width.toDouble(), data.height.toDouble()),
        Paint()..color = Color(o.backgroundArgb | 0xFF000000),
      );
    }
    if (o.includeReferences) {
      final saved = showReferences;
      showReferences = true;
      final sel = selectedReferenceId;
      selectedReferenceId = null; // no selection frame in the export
      _paintReferences(canvas);
      selectedReferenceId = sel;
      showReferences = saved;
    }
    // Artwork only: no live stroke, rulers, grids, symmetry or selection.
    compositor.paint(canvas);
    final pic = rec.endRecording();
    try {
      return await pic.toImage(size.width, size.height);
    } finally {
      pic.dispose();
    }
  }

  /// Renders the flattened artwork at the requested size.
  Future<RasterPixels> renderArtwork(ExportOptions o) async {
    final size = ExportPlanner.size(data.width, data.height, o);
    final image = await _renderImage(o, size);
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
      if (bytes == null) throw const ExportException('The artwork could not be rendered.');
      var rgba = bytes.buffer.asUint8List();
      if (!o.keepsAlpha) rgba = flattenOver(rgba, o.backgroundArgb);
      return RasterPixels(image.width, image.height, rgba);
    } finally {
      image.dispose();
    }
  }

  /// Small PNG preview for the project library.
  Future<Uint8List?> renderThumbnailPng({int maxSide = 320}) async {
    final k = math.min(1.0, maxSide / math.max(data.width, data.height));
    final w = math.max(1, (data.width * k).round());
    final o = ExportOptions(width: w, transparent: false, backgroundArgb: data.backgroundArgb ?? 0xFFFFFFFF);
    final size = ExportPlanner.size(data.width, data.height, o);
    final image = await _renderImage(o, size);
    try {
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      return png?.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  }

  /// One PNG per layer for the OpenRaster fallback. Masks and filters are
  /// baked into the pixels; see [OraWriter] for what is not preserved.
  Future<List<OraNode>> renderLayerNodes() async {
    await compositor.prepareAll();
    Future<Uint8List> layerPng(SketchLayerData layer) async {
      final rec = ui.PictureRecorder();
      final canvas = Canvas(rec);
      compositor.paintAlone(canvas, layer);
      final pic = rec.endRecording();
      final image = await pic.toImage(data.width, data.height);
      pic.dispose();
      try {
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        return png!.buffer.asUint8List();
      } finally {
        image.dispose();
      }
    }

    Future<List<OraNode>> build(String? parent) async {
      final out = <OraNode>[];
      for (final layer in LayerOps.children(data, parent).reversed) {
        final name = layer.clipToBelow ? '${layer.name} (clipped)' : layer.name;
        if (layer.isGroup) {
          out.add(OraNode.group(
            name: name,
            children: await build(layer.id),
            opacity: layer.opacity,
            visible: layer.visible,
            blend: layer.blend,
          ));
        } else {
          out.add(OraNode.layer(
            name: name,
            png: await layerPng(layer),
            opacity: layer.opacity,
            visible: layer.visible,
            blend: layer.blend,
          ));
        }
      }
      return out;
    }

    return build(null);
  }
}
