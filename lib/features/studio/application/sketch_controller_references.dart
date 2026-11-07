part of 'sketch_controller.dart';

/// Reference Studio state (Phase 5.5). References live beside the artwork,
/// are painted only in the editing overlay and are never part of an export
/// (see [ExportPlan]).
extension SketchReferenceActions on SketchController {
  Future<void> setReferences(ReferenceBoard board, {bool persist = true}) async {
    references = board;
    final keep = {for (final i in board.images) i.id};
    for (final id in _refImages.keys.where((k) => !keep.contains(k)).toList()) {
      _refImages.remove(id)?.dispose();
      _refPixels.remove(id);
    }
    for (final img in board.images) {
      if (_refImages.containsKey(img.id)) continue;
      try {
        final codec = await ui.instantiateImageCodec(img.bytes);
        final frame = await codec.getNextFrame();
        _refImages[img.id] = frame.image;
        codec.dispose();
      } catch (error, stack) {
        AppLog.error('Reference decode failed', error: error, stackTrace: stack);
        _notice('"${img.name}" could not be read as an image.');
      }
    }
    repaint.ping();
    _notify();
    if (persist) {
      try {
        await onReferencesChanged?.call(board);
      } catch (error, stack) {
        AppLog.error('Saving references failed', error: error, stackTrace: stack);
        _notice('The reference board could not be saved.');
      }
    }
  }

  /// Adds an image (already-read bytes) centred in the canvas, scaled to
  /// fit about half of it.
  Future<bool> addReference(String name, Uint8List bytes) async {
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final w = frame.image.width.toDouble(), h = frame.image.height.toDouble();
      frame.image.dispose();
      codec.dispose();
      final fit = math.min(data.width * 0.5 / w, data.height * 0.5 / h);
      final image = ReferenceImage(
        id: references.nextId(),
        name: name.length > 60 ? name.substring(0, 60) : name,
        bytes: bytes,
        x: data.width / 2 - w * fit / 2,
        y: data.height / 2 - h * fit / 2,
        scale: fit,
      );
      await setReferences(references.add(image));
      selectedReferenceId = image.id;
      showReferences = true;
      _notify();
      return true;
    } on ReferenceException catch (e) {
      _notice(e.message);
      return false;
    } catch (_) {
      _notice('That file is not an image ARTFOXEL can read.');
      return false;
    }
  }

  Future<void> updateReference(String id, ReferenceImage Function(ReferenceImage) f) =>
      setReferences(references.update(id, f));

  Future<void> removeReference(String id) async {
    if (selectedReferenceId == id) selectedReferenceId = null;
    await setReferences(references.remove(id));
  }

  void selectReference(String? id) {
    selectedReferenceId = id;
    repaint.ping();
    _notify();
  }

  void toggleReferences(bool value) {
    showReferences = value;
    repaint.ping();
    _notify();
  }

  Size? referenceSize(String id) {
    final img = _refImages[id];
    return img == null ? null : Size(img.width.toDouble(), img.height.toDouble());
  }

  /// Maps reference pixels to document space (scale, rotate about the
  /// centre, then translate).
  Affine2D _refMatrix(ReferenceImage r, Size s) {
    final cx = s.width * r.scale / 2, cy = s.height * r.scale / 2;
    return Affine2D.translation(r.x + cx, r.y + cy) *
        Affine2D.rotation(r.rotation) *
        Affine2D.translation(-cx, -cy) *
        Affine2D.scale(r.scale, r.scale);
  }

  /// Reads the colour under [doc] from the topmost visible reference, or null.
  Future<int?> pickReferenceColor(Offset doc) async {
    final list = references.visible.toList().reversed;
    for (final r in list) {
      final img = _refImages[r.id];
      if (img == null) continue;
      final size = Size(img.width.toDouble(), img.height.toDouble());
      final inv = _refMatrix(r, size).inverse();
      if (inv == null) continue;
      final x = inv.applyX(doc.dx, doc.dy).floor(), y = inv.applyY(doc.dx, doc.dy).floor();
      if (x < 0 || y < 0 || x >= img.width || y >= img.height) continue;
      var px = _refPixels[r.id];
      if (px == null) {
        final bytes = await img.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
        if (bytes == null) continue;
        px = bytes.buffer.asUint8List();
        _refPixels[r.id] = px;
      }
      final i = (y * img.width + x) * 4;
      if (px[i + 3] < 8) continue;
      return 0xFF000000 | (px[i] << 16) | (px[i + 1] << 8) | px[i + 2];
    }
    return null;
  }

  Future<bool> pickColorFromReference(Offset doc) async {
    final c = await pickReferenceColor(doc);
    if (c == null) return false;
    setColor(c);
    return true;
  }

  void _paintReferences(Canvas canvas) {
    if (!showReferences) return;
    for (final r in references.visible) {
      final img = _refImages[r.id];
      if (img == null) continue;
      final size = Size(img.width.toDouble(), img.height.toDouble());
      canvas.save();
      canvas.transform(_refMatrix(r, size).toMatrix4());
      canvas.drawImage(img, Offset.zero,
          Paint()..filterQuality = FilterQuality.medium..color = Color.fromRGBO(255, 255, 255, r.opacity));
      if (r.id == selectedReferenceId) {
        canvas.drawRect(Offset.zero & size,
            Paint()..style = PaintingStyle.stroke..strokeWidth = 2 / r.scale..color = const Color(0xFF3377FF));
      }
      canvas.restore();
    }
  }
}
