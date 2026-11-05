part of 'sketch_controller.dart';

/// Pixels copied from the canvas, ready to be pasted as an image layer.
class SelectionClipboard {
  const SelectionClipboard({required this.image, required this.placement});

  final LayerImage image;

  /// Maps the image's pixels to document coordinates (where it was copied).
  final Affine2D placement;
}

/// Selection tools and operations (Phase 4.4).
///
/// The selection is an [AlphaMask] in document space at reduced resolution
/// (at most [AlphaMask.maxSide] px on the long side). All pointer input
/// arrives in document coordinates, so selections never depend on zoom,
/// pan or rotation of the view.
extension SketchSelectionActions on SketchController {
  (int, int) get _maskSize => AlphaMask.sizeFor(data.width, data.height);
  double get _maskScaleX => _maskSize.$1 / data.width;
  double get _maskScaleY => _maskSize.$2 / data.height;

  Offset _toMask(Offset doc) => Offset(doc.dx * _maskScaleX, doc.dy * _maskScaleY);

  void setSelectionMode(SelectionMode mode) {
    selectionMode = mode;
    _notify();
  }

  void setSelectionView(SelectionView view) {
    selectionView = view;
    _rebuildOverlay();
    _notify();
  }

  void setWandTolerance(int value) {
    wandTolerance = value.clamp(0, 255);
    _notify();
  }

  void setColorRangeFuzziness(int value) {
    colorRangeFuzziness = value.clamp(0, 255);
    _notify();
  }

  void setWandContiguous(bool value) {
    wandContiguous = value;
    _notify();
  }

  void setSampleAllLayers(bool value) {
    sampleAllLayers = value;
    _notify();
  }

  void selectTool(SketchTool value) {
    if (isDrawing) cancelStroke();
    if (tool == SketchTool.selectPolygon && value != tool) _shapePoints.clear();
    tool = value;
    _shapeStart = _shapeCurrent = null;
    _notify();
    repaint.ping();
  }

  // ---- pointer input (document coordinates) ---------------------------------------

  void toolPointerDown(Offset doc) {
    if (!tool.isSelection) return;
    _shapeStart = doc;
    _shapeCurrent = doc;
    if (tool == SketchTool.selectLasso) {
      _shapePoints
        ..clear()
        ..add(doc);
    }
    repaint.ping();
  }

  void toolPointerMove(Offset doc) {
    if (_shapeStart == null) return;
    _shapeCurrent = doc;
    if (tool == SketchTool.selectLasso) _shapePoints.add(doc);
    repaint.ping();
  }

  void toolPointerUp(Offset doc) {
    final start = _shapeStart;
    if (start == null) return;
    _shapeCurrent = doc;
    switch (tool) {
      case SketchTool.selectRect:
      case SketchTool.selectEllipse:
        final rect = Rect.fromPoints(start, doc);
        if (rect.width >= 1 && rect.height >= 1) {
          final m = _toMask(rect.topLeft), n = _toMask(rect.bottomRight);
          final box = Rect.fromPoints(m, n);
          final (w, h) = _maskSize;
          _applyShape(
            tool == SketchTool.selectRect
                ? AlphaMask.rect(w, h, box)
                : AlphaMask.ellipse(w, h, box),
            tool == SketchTool.selectRect ? 'Rectangle selection' : 'Ellipse selection',
          );
        }
      case SketchTool.selectLasso:
        _shapePoints.add(doc);
        if (_shapePoints.length >= 3) _commitPolygon('Lasso selection');
        _shapePoints.clear();
      case SketchTool.selectPolygon:
        if (_shapePoints.length >= 3 && (doc - _shapePoints.first).distance < 24) {
          _commitPolygon('Polygon selection');
        } else {
          _shapePoints.add(doc);
        }
      case SketchTool.magicWand:
        unawaited(magicWandAt(doc));
      case SketchTool.colorRange:
        unawaited(colorRangeAt(doc));
      case SketchTool.draw:
      case SketchTool.eyedropper:
        break;
    }
    _shapeStart = _shapeCurrent = null;
    repaint.ping();
    _notify();
  }

  void cancelShape() {
    _shapePoints.clear();
    _shapeStart = _shapeCurrent = null;
    repaint.ping();
    _notify();
  }

  /// Finishes a polygon lasso (also done by tapping near the first vertex).
  void closePolygon() {
    if (tool == SketchTool.selectPolygon && _shapePoints.length >= 3) {
      _commitPolygon('Polygon selection');
    } else {
      _shapePoints.clear();
    }
    repaint.ping();
    _notify();
  }

  bool get hasOpenPolygon => _shapePoints.isNotEmpty && tool == SketchTool.selectPolygon;

  void _commitPolygon(String label) {
    final (w, h) = _maskSize;
    final points = [for (final p in _shapePoints) _toMask(p)];
    _shapePoints.clear();
    _applyShape(AlphaMask.polygon(w, h, points), label);
  }

  void _applyShape(AlphaMask shape, String label) {
    final current = selection;
    final AlphaMask? next;
    if (current == null) {
      next = selectionMode == SelectionMode.subtract || selectionMode == SelectionMode.intersect
          ? null
          : shape;
    } else if (selectionMode == SelectionMode.replace) {
      next = shape;
    } else {
      next = current.combine(shape, selectionMode);
    }
    _setSelection(next == null || next.isEmpty ? null : next, label);
  }

  // ---- history-aware selection state -------------------------------------------------

  void _setSelection(AlphaMask? next, String label) {
    final previous = selection;
    if (identical(previous, next)) return;
    selection = next;
    _rebuildOverlay();
    _pushEntry(_HistoryEntry(label, () {
      selection = previous;
      _rebuildOverlay();
    }, () {
      selection = next;
      _rebuildOverlay();
    }));
    repaint.ping();
    _notify();
  }

  void selectAll() {
    final (w, h) = _maskSize;
    _setSelection(AlphaMask.filled(w, h, 255), 'Select all');
  }

  void deselect() {
    if (selection == null) return;
    _setSelection(null, 'Deselect');
  }

  void invertSelection() {
    final current = selection;
    final (w, h) = _maskSize;
    final next = (current ?? AlphaMask.filled(w, h, 0)).invert();
    _setSelection(next.isEmpty ? null : next, 'Invert selection');
  }

  /// [documentPixels] > 0 grows the selection, < 0 shrinks it.
  void growSelection(double documentPixels) {
    final current = selection;
    if (current == null) return;
    final next = current.grow(documentPixels * _maskScaleX);
    _setSelection(next.isEmpty ? null : next, documentPixels >= 0 ? 'Expand selection' : 'Contract selection');
  }

  void featherSelection(double documentPixels) {
    final current = selection;
    if (current == null) return;
    _setSelection(current.feather(documentPixels * _maskScaleX), 'Feather selection');
  }

  // ---- pixel based selections ----------------------------------------------------------

  /// Straight RGBA of the canvas (or one layer) at mask resolution.
  Future<Uint8List?> _renderPixels({SketchLayerData? layer, bool background = true}) async {
    final (w, h) = _maskSize;
    try {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder)..scale(w / data.width, h / data.height);
      final page = Rect.fromLTWH(0, 0, data.width.toDouble(), data.height.toDouble());
      if (layer == null && background && data.backgroundArgb != null) {
        canvas.drawRect(page, Paint()..color = Color(data.backgroundArgb!));
      }
      canvas.saveLayer(page, Paint());
      if (layer == null) {
        compositor.paint(canvas);
      } else {
        compositor.paintAlone(canvas, layer);
      }
      canvas.restore();
      final picture = recorder.endRecording();
      final image = picture.toImageSync(w, h);
      picture.dispose();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
      image.dispose();
      return bytes == null ? null : Uint8List.sublistView(bytes);
    } catch (error, stack) {
      AppLog.error('Reading pixels failed', error: error, stackTrace: stack);
      _notice('The canvas pixels could not be read.');
      return null;
    }
  }

  Future<Uint8List?> _samplePixels() => _renderPixels(
        layer: sampleAllLayers ? null : activeLayer,
        background: sampleAllLayers,
      );

  Future<void> magicWandAt(Offset doc) async {
    final pixels = await _samplePixels();
    if (pixels == null) return;
    final (w, h) = _maskSize;
    final p = _toMask(doc);
    final shape = SelectionTools.magicWand(
      pixels, w, h, p.dx.floor(), p.dy.floor(),
      tolerance: wandTolerance,
      contiguous: wandContiguous,
    );
    _applyShape(shape, 'Magic wand');
  }

  Future<void> colorRangeAt(Offset doc) async {
    final pixels = await _samplePixels();
    if (pixels == null) return;
    final (w, h) = _maskSize;
    final p = _toMask(doc);
    final x = p.dx.floor(), y = p.dy.floor();
    if (x < 0 || y < 0 || x >= w || y >= h) return;
    final i = (y * w + x) * 4;
    final shape = SelectionTools.colorRange(
      pixels, w, h, pixels[i], pixels[i + 1], pixels[i + 2],
      tolerance: wandTolerance,
      fuzziness: colorRangeFuzziness,
    );
    _applyShape(shape, 'Color range');
  }

  // ---- copy / cut / paste / convert -------------------------------------------------------

  /// Copies the selected pixels of the active layer (or of the whole visible
  /// canvas with [merged]) to the in-app clipboard.
  Future<bool> copySelection({bool merged = false}) async {
    final sel = selection;
    if (sel == null) {
      _notice('Make a selection first.');
      return false;
    }
    final layer = activeLayer;
    if (!merged && layer.isGroup) {
      _notice('Select a layer (not a group) to copy from, or use Copy merged.');
      return false;
    }
    final pixels = await _renderPixels(layer: merged ? null : layer, background: false);
    if (pixels == null) return false;
    final (w, h) = _maskSize;
    final part = SelectionTools.extract(pixels, w, h, sel);
    if (part == null) {
      _notice('The selection is empty.');
      return false;
    }
    clipboard = SelectionClipboard(
      image: LayerImage(width: part.width, height: part.height, rgba: part.rgba),
      placement: Affine2D.translation(part.x / _maskScaleX, part.y / _maskScaleY) *
          Affine2D.scale(1 / _maskScaleX, 1 / _maskScaleY),
    );
    _notify();
    return true;
  }

  /// Copy, then hide the selected area on the active layer through its mask
  /// (non-destructive: the strokes stay, undo restores everything).
  Future<void> cutSelection() async {
    if (!await copySelection()) return;
    final layer = activeLayer;
    if (LayerOps.isEffectivelyLocked(data, layer)) {
      _notice('"${layer.name}" is locked, so it was copied but not cut.');
      return;
    }
    final sel = selection!;
    final (w, h) = _maskSize;
    final existing = layer.mask;
    AlphaMask base;
    if (existing == null) {
      base = AlphaMask.filled(w, h, 255);
    } else if (existing.strokes.isNotEmpty) {
      final baked = await _bakeMaskValues(layer);
      if (baked == null) return;
      base = baked;
    } else {
      base = existing.bitmap ?? AlphaMask.filled(w, h, 255);
    }
    if (existing != null && existing.inverted) base = base.invert();
    final result = base.combine(sel, SelectionMode.subtract);
    final fresh = LayerMaskData(bitmap: result);
    layer.mask = existing;
    await _prepareMask(layer, fresh);
    _recordStructural('Cut', () {
      activeLayer.mask = fresh;
    });
  }

  Future<void> _prepareMask(SketchLayerData layer, LayerMaskData mask) async {
    final previous = layer.mask;
    layer.mask = mask;
    await compositor.prepareAll();
    layer.mask = previous;
  }

  /// Renders mask strokes + bitmap into gray values at mask resolution.
  Future<AlphaMask?> _bakeMaskValues(SketchLayerData layer) async {
    final (w, h) = _maskSize;
    try {
      await compositor.prepareAll();
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder)..scale(w / data.width, h / data.height);
      compositor.paintMaskValue(canvas, layer);
      final picture = recorder.endRecording();
      final image = picture.toImageSync(w, h);
      picture.dispose();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
      image.dispose();
      if (bytes == null) return null;
      final out = Uint8List(w * h);
      for (var i = 0; i < out.length; i++) {
        out[i] = bytes.getUint8(i * 4);
      }
      return AlphaMask(w, h, out);
    } catch (error, stack) {
      AppLog.error('Mask baking failed', error: error, stackTrace: stack);
      _notice('The mask could not be read.');
      return null;
    }
  }

  /// Pastes the clipboard as a new image layer above the active layer, in the
  /// place it was copied from.
  void pasteClipboard() {
    final clip = clipboard;
    if (clip == null) {
      _notice('Nothing has been copied yet.');
      return;
    }
    _guard(() {
      _recordStructural('Paste', () {
        final layer = SketchLayerData(
          id: LayerOps.newId(data),
          name: LayerOps.sanitizeName('Pasted ${data.layers.where((l) => l.isImage).length + 1}'),
          kind: LayerKind.image,
          image: clip.image,
          matrix: clip.placement,
        );
        LayerOps.insert(data, layer, aboveId: activeLayerId);
        activeLayerId = layer.id;
        editingMask = false;
      });
    });
  }

  /// "Layer via copy": the selected pixels become a new image layer.
  Future<void> selectionToLayer() async {
    if (await copySelection()) pasteClipboard();
  }

  /// Selection (from the layer's mask), combined with the current selection
  /// according to the selection mode.
  Future<void> selectionFromMask() async {
    final layer = activeLayer;
    final mask = layer.mask;
    if (mask == null) {
      _notice('This layer has no mask.');
      return;
    }
    final (w, h) = _maskSize;
    AlphaMask values;
    if (mask.strokes.isEmpty) {
      values = mask.bitmap ?? AlphaMask.filled(w, h, 255);
    } else {
      final baked = await _bakeMaskValues(layer);
      if (baked == null) return;
      values = baked;
    }
    if (mask.inverted) values = values.invert();
    _applyShape(values, 'Selection from mask');
  }

  // ---- overlay -----------------------------------------------------------------------------

  void _rebuildOverlay() {
    final generation = ++_overlayGeneration;
    final sel = selection;
    if (sel == null || selectionView == SelectionView.hidden || !compositor.useRasters) {
      _selectionOverlay?.dispose();
      _selectionOverlay = null;
      return;
    }
    final w = sel.width, h = sel.height;
    final out = Uint8List(w * h * 4);
    final tint = selectionView == SelectionView.tint;
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final v = sel.data[y * w + x];
        final inside = v >= 128;
        final edge = inside &&
            (sel.at(x - 1, y) < 128 || sel.at(x + 1, y) < 128 || sel.at(x, y - 1) < 128 || sel.at(x, y + 1) < 128);
        final i = (y * w + x) * 4;
        if (edge) {
          // Static "marching ants": alternating black and white dashes.
          final dark = ((x + y) >> 2).isEven;
          out[i] = out[i + 1] = out[i + 2] = dark ? 0 : 255;
          out[i + 3] = 255;
        } else if (tint && v > 0) {
          out[i] = 52;
          out[i + 1] = 120;
          out[i + 2] = 246;
          out[i + 3] = (v * 70 / 255).round();
        }
      }
    }
    LayerCompositor.imageFromRgba(out, w, h).then((image) {
      if (image == null) return;
      if (generation != _overlayGeneration || _disposed) {
        image.dispose();
        return;
      }
      _selectionOverlay?.dispose();
      _selectionOverlay = image;
      repaint.ping();
    });
  }

  /// Selection overlay, in-progress shape and transform guides, drawn in
  /// document coordinates above the artwork.
  void paintOverlay(Canvas canvas, double zoom) {
    final page = Rect.fromLTWH(0, 0, data.width.toDouble(), data.height.toDouble());
    final overlay = _selectionOverlay;
    if (overlay != null) {
      canvas.drawImageRect(
        overlay,
        Rect.fromLTWH(0, 0, overlay.width.toDouble(), overlay.height.toDouble()),
        page,
        Paint()..filterQuality = FilterQuality.none,
      );
    }
    final start = _shapeStart, current = _shapeCurrent;
    Path? path;
    if (tool == SketchTool.selectRect && start != null && current != null) {
      path = Path()..addRect(Rect.fromPoints(start, current));
    } else if (tool == SketchTool.selectEllipse && start != null && current != null) {
      path = Path()..addOval(Rect.fromPoints(start, current));
    } else if ((tool == SketchTool.selectLasso || tool == SketchTool.selectPolygon) &&
        _shapePoints.isNotEmpty) {
      path = Path()..moveTo(_shapePoints.first.dx, _shapePoints.first.dy);
      for (final p in _shapePoints.skip(1)) {
        path.lineTo(p.dx, p.dy);
      }
      if (tool == SketchTool.selectPolygon && current != null) path.lineTo(current.dx, current.dy);
    }
    if (path != null) {
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3 / zoom
          ..color = const Color(0xFFFFFFFF),
      );
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1 / zoom
          ..color = const Color(0xFF000000),
      );
    }
    this._paintTransformGuides(canvas, zoom);
  }
}
