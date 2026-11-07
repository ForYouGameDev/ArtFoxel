part of 'sketch_controller.dart';

/// Shape tool state (Phase 5.4). Shapes are stored as editable geometry on
/// the layer ([SketchLayerData.shapes]) until [rasterizeShapes] is used.
class ShapeToolSettings {
  ShapeKind kind = ShapeKind.rectangle;
  int sides = 5;
  double cornerRadius = 24;
  double innerRatio = 0.45;
  double sweepDegrees = 270;
  double strokeWidth = 4;
  bool stroke = true;
  bool fill = false;

  /// When set, new closed shapes are filled with this gradient instead of the
  /// background colour.
  GradientData? gradient;

  /// Try to replace rough freehand drawing with a clean shape when sure.
  bool recognize = false;
}

extension SketchShapeActions on SketchController {
  List<ShapeData> get shapes => activeLayer.shapes;

  ShapeData? get selectedShape {
    final i = selectedShapeIndex;
    final list = activeLayer.shapes;
    return i != null && i >= 0 && i < list.length ? list[i] : null;
  }

  void setShapeKind(ShapeKind kind) {
    _finishPolylineSilently();
    shapeTool.kind = kind;
    tool = SketchTool.shape;
    _notify();
  }

  void notifyShapeSettings() {
    // Applies the tool's fill/stroke/geometry options to the selected shape.
    final s = selectedShape;
    if (s != null) {
      _replaceSelected(s.copyWith(
        sides: shapeTool.sides,
        cornerRadius: shapeTool.cornerRadius,
        innerRatio: shapeTool.innerRatio,
        sweepDegrees: shapeTool.sweepDegrees,
        strokeWidth: shapeTool.strokeWidth,
        strokeArgb: shapeTool.stroke ? colorArgb : null,
        fillArgb: s.kind.closed && shapeTool.fill && shapeTool.gradient == null ? bgColorArgb : null,
        fillGradient: s.kind.closed && shapeTool.fill ? shapeTool.gradient : null,
      ), 'Edit shape');
    }
    _notify();
  }

  ShapeData _make(ShapeKind kind, List<Offset> pts) => ShapeData(
        kind: kind,
        points: pts,
        sides: shapeTool.sides,
        cornerRadius: shapeTool.cornerRadius,
        innerRatio: shapeTool.innerRatio,
        sweepDegrees: shapeTool.sweepDegrees,
        strokeArgb: shapeTool.stroke || !(kind.closed && shapeTool.fill) ? colorArgb : null,
        strokeWidth: shapeTool.strokeWidth,
        fillArgb: kind.closed && shapeTool.fill && shapeTool.gradient == null ? bgColorArgb : null,
        fillGradient: kind.closed && shapeTool.fill ? shapeTool.gradient : null,
      );

  bool _canEditShapes() {
    final layer = activeLayer;
    if (!layer.isPaint || editingMask) {
      _notice('Shapes can only be added to a paint layer.');
      return false;
    }
    return _canPaint();
  }

  // ---- pointer routing (called from toolPointerDown/Move/Up) ----------------

  void _shapeDown(Offset p) {
    if (!_canEditShapes()) return;
    const zoomSlack = 24.0;
    // Handle of the selected shape?
    final sel = selectedShape;
    if (sel != null) {
      final h = sel.nearestPoint(p, radius: zoomSlack);
      if (h != null) {
        _shapeBefore = _Snapshot.take(this);
        _dragHandle = h;
        return;
      }
    }
    // Hit an existing shape? Select and move it.
    final list = activeLayer.shapes;
    for (var i = list.length - 1; i >= 0; i--) {
      if (list[i].hits(p)) {
        selectedShapeIndex = i;
        _shapeBefore = _Snapshot.take(this);
        _dragHandle = -1; // whole shape
        _dragLast = p;
        _notify();
        repaint.ping();
        return;
      }
    }
    selectedShapeIndex = null;
    _dragHandle = null;
    _draftStart = p;
    _draftEnd = p;
    repaint.ping();
    _notify();
  }

  void _shapeMove(Offset p) {
    final handle = _dragHandle;
    if (handle != null && selectedShapeIndex != null) {
      final layer = activeLayer;
      final i = selectedShapeIndex!;
      if (i >= layer.shapes.length) return;
      final constrained = AssistEngine.constrain(p, data.assist);
      try {
        if (handle >= 0) {
          layer.shapes[i] = layer.shapes[i].movePoint(handle, constrained);
        } else {
          final d = p - (_dragLast ?? p);
          layer.shapes[i] = layer.shapes[i].translate(d);
          _dragLast = p;
        }
      } on ShapeException {
        return;
      }
      repaint.ping();
      return;
    }
    if (_draftStart != null) {
      _draftEnd = AssistEngine.constrain(p, data.assist);
      repaint.ping();
    }
  }

  void _shapeUp(Offset p) {
    final handle = _dragHandle;
    if (handle != null) {
      final before = _shapeBefore;
      _dragHandle = null;
      _dragLast = null;
      _shapeBefore = null;
      if (before != null) {
        final after = _Snapshot.take(this);
        _pushEntry(_HistoryEntry(
          handle >= 0 ? 'Edit shape point' : 'Move shape',
          () => before.restore(this, invalidate: false),
          () => after.restore(this, invalidate: false),
        ));
        _markChanged();
      }
      repaint.ping();
      return;
    }
    final start = _draftStart;
    if (start == null) return;
    final end = AssistEngine.constrain(p, data.assist);
    _draftStart = _draftEnd = null;
    final kind = shapeTool.kind;
    final moved = (end - start).distance;
    if (kind == ShapeKind.polyline) {
      if (moved < 8) {
        _polyPoints.add(end);
      } else {
        if (_polyPoints.isEmpty) _polyPoints.add(start);
        _polyPoints.add(end);
      }
      repaint.ping();
      _notify();
      return;
    }
    if (moved < 4) {
      repaint.ping();
      return;
    }
    ShapeData shape;
    switch (kind) {
      case ShapeKind.bezier:
        final mid = (start + end) / 2;
        final n = Offset(-(end - start).dy, (end - start).dx) * 0.3;
        shape = _make(kind, [start, mid + n, end]);
      case ShapeKind.cubic:
        final d = end - start;
        final n = Offset(-d.dy, d.dx) * 0.3;
        shape = _make(kind, [start, start + d * 0.33 + n, start + d * 0.66 - n, end]);
      default:
        shape = _make(kind, [start, end]);
    }
    _addShape(shape, 'Add ${kind.label.toLowerCase()}');
  }

  void _addShape(ShapeData shape, String label) {
    _recordStructural(label, () {
      final layer = activeLayer;
      layer.shapes.add(shape);
      selectedShapeIndex = layer.shapes.length - 1;
    });
  }

  /// Commits a polyline started by tapping points.
  bool finishPolyline() {
    if (_polyPoints.length < 2) {
      _notice('Tap at least two points for a polyline.');
      return false;
    }
    final pts = List<Offset>.of(_polyPoints);
    _polyPoints.clear();
    _addShape(_make(ShapeKind.polyline, pts), 'Add polyline');
    return true;
  }

  void _finishPolylineSilently() {
    if (_polyPoints.length >= 2) {
      finishPolyline();
    } else {
      _polyPoints.clear();
    }
  }

  void cancelShapeDraft() {
    _draftStart = _draftEnd = null;
    _dragHandle = null;
    _dragLast = null;
    _shapeBefore = null;
    _polyPoints.clear();
    repaint.ping();
  }

  // ---- editing ------------------------------------------------------------------

  void _replaceSelected(ShapeData next, String label) {
    final i = selectedShapeIndex;
    if (i == null) return;
    _recordStructural(label, () {
      final list = activeLayer.shapes;
      if (i < list.length) list[i] = next;
    });
  }

  void deleteSelectedShape() {
    final i = selectedShapeIndex;
    if (i == null || i >= activeLayer.shapes.length) return;
    _recordStructural('Delete shape', () {
      activeLayer.shapes.removeAt(i);
      selectedShapeIndex = null;
    });
  }

  void selectShape(int? index) {
    selectedShapeIndex = index;
    repaint.ping();
    _notify();
  }

  /// Replaces a roughly hand-drawn closed/straight stroke by a clean shape,
  /// only when [ShapeRecognizer] is confident. Returns the recognized shape.
  ShapeData? recognizeLastStroke() {
    final layer = activeLayer;
    if (layer.strokes.isEmpty) return null;
    final stroke = layer.strokes.last;
    final shape = ShapeRecognizer.recognize(
      [for (final p in stroke.points) Offset(p.x, p.y)],
      strokeArgb: stroke.colorArgb,
      strokeWidth: stroke.size,
    );
    if (shape == null) {
      _notice('No clear shape found, so the stroke was left as drawn.');
      return null;
    }
    _recordStructural('Recognize shape', () {
      layer.strokes.remove(stroke);
      layer.shapes.add(shape);
      selectedShapeIndex = layer.shapes.length - 1;
      compositor.invalidate(layer.id);
    });
    return shape;
  }

  /// Bakes the active layer's shapes into pixels on a new image layer above
  /// it and removes the editable shapes. Undo restores the shapes.
  Future<bool> rasterizeShapes() async {
    final layer = activeLayer;
    if (layer.shapes.isEmpty) {
      _notice('This layer has no shapes to rasterize.');
      return false;
    }
    var scale = 1.0;
    final longest = math.max(data.width, data.height);
    if (longest > 4096) scale = 4096 / longest;
    final w = math.max(1, (data.width * scale).round());
    final h = math.max(1, (data.height * scale).round());
    try {
      final rec = ui.PictureRecorder();
      final canvas = Canvas(rec)..scale(w / data.width, h / data.height);
      for (final s in layer.shapes) {
        s.paintTo(canvas);
      }
      final pic = rec.endRecording();
      final img = await pic.toImage(w, h);
      pic.dispose();
      final bytes = await img.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
      img.dispose();
      if (bytes == null) return false;
      final pixels = Uint8List.fromList(bytes.buffer.asUint8List());
      _guard(() {
        _recordStructural('Rasterize shapes', () {
          final target = data.layerById(layer.id);
          if (target == null) return;
          final raster = SketchLayerData(
            id: LayerOps.newId(data),
            name: LayerOps.sanitizeName('${layer.name} shapes'),
            kind: LayerKind.image,
            image: LayerImage(width: w, height: h, rgba: pixels),
            matrix: Affine2D.scale(data.width / w, data.height / h),
          );
          target.shapes.clear();
          LayerOps.insert(data, raster, aboveId: target.id);
          activeLayerId = raster.id;
          selectedShapeIndex = null;
        });
      });
      return true;
    } catch (error, stack) {
      AppLog.error('Rasterizing shapes failed', error: error, stackTrace: stack);
      _notice('The shapes could not be rasterized.');
      return false;
    }
  }

  // ---- overlay ----------------------------------------------------------------------

  void _paintShapeOverlay(Canvas canvas, double zoom) {
    final px = 1 / zoom;
    final start = _draftStart, end = _draftEnd;
    if (tool == SketchTool.shape && start != null && end != null) {
      final kind = shapeTool.kind;
      if (kind != ShapeKind.polyline && kind != ShapeKind.bezier && kind != ShapeKind.cubic) {
        try {
          _make(kind, [start, end]).paintTo(canvas);
        } on ShapeException {
          // Not drawable yet.
        }
      } else {
        canvas.drawLine(start, end, Paint()..strokeWidth = shapeTool.strokeWidth..color = Color(colorArgb));
      }
    }
    if (_polyPoints.isNotEmpty) {
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(px, shapeTool.strokeWidth)
        ..color = Color(colorArgb);
      final path = Path()..moveTo(_polyPoints.first.dx, _polyPoints.first.dy);
      for (final p in _polyPoints.skip(1)) {
        path.lineTo(p.dx, p.dy);
      }
      canvas.drawPath(path, paint);
      for (final p in _polyPoints) {
        canvas.drawCircle(p, 4 * px, Paint()..color = const Color(0xFF3377FF));
      }
    }
    final sel = tool == SketchTool.shape ? selectedShape : null;
    if (sel != null) {
      canvas.drawRect(sel.bounds.inflate(4 * px),
          Paint()..style = PaintingStyle.stroke..strokeWidth = px..color = const Color(0xFF3377FF));
      for (final p in sel.points) {
        canvas.drawCircle(p, 7 * px, Paint()..color = const Color(0xFFFFFFFF));
        canvas.drawCircle(p, 7 * px,
            Paint()..style = PaintingStyle.stroke..strokeWidth = 2 * px..color = const Color(0xFF3377FF));
      }
    }
  }
}
