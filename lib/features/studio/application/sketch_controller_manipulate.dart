part of 'sketch_controller.dart';

/// What the Move / Resize tool is currently holding.
enum ManipKind { none, layer, reference, shape }

/// The oriented box drawn around the selected object, in document space.
/// Corners run top-left, top-right, bottom-right, bottom-left.
class ManipBox {
  const ManipBox(this.corners, {required this.canRotate, required this.canStretch});
  final List<Offset> corners;
  final bool canRotate;

  /// Edge handles that stretch along one axis (off for references, which keep
  /// their aspect ratio).
  final bool canStretch;

  Offset get center => (corners[0] + corners[2]) / 2;
  Offset edgeMid(int i) => (corners[i] + corners[(i + 1) % 4]) / 2;

  Offset rotateHandle(double distance) {
    final top = edgeMid(0);
    final out = top - center;
    final len = out.distance;
    return len < 1e-9 ? top : top + out / len * distance;
  }

  bool contains(Offset p, {double slack = 0}) {
    var allPos = true, allNeg = true;
    for (var i = 0; i < 4; i++) {
      final a = corners[i], b = corners[(i + 1) % 4];
      final cross = (b.dx - a.dx) * (p.dy - a.dy) - (b.dy - a.dy) * (p.dx - a.dx);
      final len = (b - a).distance;
      final d = len < 1e-9 ? 0.0 : cross / len;
      if (d < -slack) allPos = false;
      if (d > slack) allNeg = false;
    }
    return allPos || allNeg;
  }
}

enum _ManipHandle { body, rotate, corner, edge }

class _ManipDrag {
  _ManipDrag({
    required this.handle,
    required this.index,
    required this.startPointer,
    required this.box,
    required this.kind,
    this.startManual = Affine2D.identity,
    this.startRef,
    this.startPoints,
  });
  final _ManipHandle handle;
  final int index;
  final Offset startPointer;
  final ManipBox box;
  final ManipKind kind;
  final Affine2D startManual;
  final ReferenceImage? startRef;
  final List<Offset>? startPoints;
  _Snapshot? snapshot;
}

/// Direct manipulation: drag to move, corner handles to resize, edge handles
/// to stretch, a handle to rotate, and two fingers on the object to pinch,
/// twist and move it. Works on the active layer (all its strokes, images and
/// shapes), a selected shape, or a selected reference image.
extension SketchManipulateActions on SketchController {
  static const double _handlePx = 26; // finger-sized hit radius, screen px
  static const double _rotateOffsetPx = 46;

  ManipKind get manipKind {
    if (tool != SketchTool.move) return ManipKind.none;
    if (selectedReferenceId != null && references.byId(selectedReferenceId!) != null) {
      return ManipKind.reference;
    }
    if (this.selectedShape != null && activeLayer.isPaint) return ManipKind.shape;
    if (transformSession != null) return ManipKind.layer;
    return ManipKind.none;
  }

  /// Short description of what is selected, for the action bar.
  String get manipLabel => switch (manipKind) {
        ManipKind.layer => 'Layer: ${activeLayer.name}',
        ManipKind.reference => 'Reference: ${references.byId(selectedReferenceId!)?.name ?? ''}',
        ManipKind.shape => 'Shape: ${this.selectedShape!.kind.label}',
        ManipKind.none => 'Tap something to select it',
      };

  ManipBox? get manipBox {
    switch (manipKind) {
      case ManipKind.layer:
        final s = transformSession!;
        final m = s.matrix;
        final b = s.bounds;
        return ManipBox([b.topLeft, b.topRight, b.bottomRight, b.bottomLeft].map(m.apply).toList(),
            canRotate: true, canStretch: true);
      case ManipKind.reference:
        final r = references.byId(selectedReferenceId!);
        final size = this.referenceSize(selectedReferenceId!);
        if (r == null || size == null) return null;
        final m = this._refMatrix(r, size);
        final b = Offset.zero & size;
        return ManipBox([b.topLeft, b.topRight, b.bottomRight, b.bottomLeft].map(m.apply).toList(),
            canRotate: true, canStretch: false);
      case ManipKind.shape:
        final b = this.selectedShape!.bounds.inflate(math.max(2, this.selectedShape!.strokeWidth / 2));
        return ManipBox([b.topLeft, b.topRight, b.bottomRight, b.bottomLeft],
            canRotate: false, canStretch: true);
      case ManipKind.none:
        return null;
    }
  }

  // ---- entering / leaving the tool ------------------------------------------------

  void _manipEnter() {
    _manipDrag = null;
    if (selectedReferenceId != null && references.byId(selectedReferenceId!) != null) return;
    selectedReferenceId = null;
    if (this.selectedShape != null && activeLayer.isPaint) return;
    selectedShapeIndex = null;
    if (transformSession == null) this.beginTransform(); // notices if the layer is empty
  }

  /// Leaving the tool commits what was done to the layer.
  void _manipLeave() {
    _manipDrag = null;
    if (transformSession != null) this.applyTransform();
    selectedReferenceId = null;
    selectedShapeIndex = null;
  }

  /// "Done" in the action bar.
  void manipDone() => setTool(SketchTool.draw);

  /// "Cancel": drops an unapplied layer transform, then leaves the tool.
  void manipCancel() {
    _manipDrag = null;
    if (transformSession != null) this.cancelTransform();
    setTool(SketchTool.draw);
  }

  // ---- hit testing ------------------------------------------------------------------

  _ManipDrag? _manipHit(Offset p) {
    final box = manipBox;
    if (box == null) return null;
    final z = _viewZoom;
    final hit = _handlePx / z;
    final kind = manipKind;
    _ManipDrag make(_ManipHandle h, int i) => _ManipDrag(
          handle: h,
          index: i,
          startPointer: p,
          box: box,
          kind: kind,
          startManual: transformSession?.manual ?? Affine2D.identity,
          startRef: kind == ManipKind.reference ? references.byId(selectedReferenceId!) : null,
          startPoints: kind == ManipKind.shape ? List<Offset>.of(this.selectedShape!.points) : null,
        );
    if (box.canRotate && (p - box.rotateHandle(_rotateOffsetPx / z)).distance <= hit) {
      return make(_ManipHandle.rotate, 0);
    }
    var best = -1;
    var bestD = hit;
    for (var i = 0; i < 4; i++) {
      final d = (p - box.corners[i]).distance;
      if (d <= bestD) {
        bestD = d;
        best = i;
      }
    }
    if (best >= 0) return make(_ManipHandle.corner, best);
    if (box.canStretch) {
      for (var i = 0; i < 4; i++) {
        final d = (p - box.edgeMid(i)).distance;
        if (d <= bestD) {
          bestD = d;
          best = i;
        }
      }
      if (best >= 0) return make(_ManipHandle.edge, best);
    }
    if (box.contains(p, slack: 6 / z)) return make(_ManipHandle.body, 0);
    return null;
  }

  // ---- pointer routing (from toolPointer*) -------------------------------------

  void _manipDown(Offset p) {
    _manipDownDoc = p;
    _manipMoved = false;
    _manipDrag = _manipHit(p);
    if (_manipDrag != null) _manipBeginDrag(_manipDrag!);
  }

  void _manipMove(Offset p) {
    final down = _manipDownDoc;
    if (down != null && (p - down).distance * _viewZoom > 8) _manipMoved = true;
    final d = _manipDrag;
    if (d == null || !_manipMoved) return;
    _manipApply(d, _deltaFor(d, p));
  }

  void _manipUp(Offset p) {
    final d = _manipDrag;
    _manipDrag = null;
    final moved = _manipMoved;
    _manipDownDoc = null;
    _manipMoved = false;
    if (d != null && moved) {
      _manipFinish(d);
      return;
    }
    if (d != null) {
      _manipRestore(d); // a tap on a handle must not nudge anything
      if (d.handle != _ManipHandle.body) return;
    }
    manipTap(p);
  }

  /// A second finger or a system cancel: put everything back as it was.
  void manipCancelDrag() {
    final d = _manipDrag;
    _manipDrag = null;
    _manipDownDoc = null;
    _manipMoved = false;
    if (d != null) _manipRestore(d);
  }

  Affine2D _deltaFor(_ManipDrag d, Offset p) {
    final box = d.box;
    switch (d.handle) {
      case _ManipHandle.body:
        return Affine2D.translation(p.dx - d.startPointer.dx, p.dy - d.startPointer.dy);
      case _ManipHandle.rotate:
        final c = box.center;
        final a0 = math.atan2(d.startPointer.dy - c.dy, d.startPointer.dx - c.dx);
        final a1 = math.atan2(p.dy - c.dy, p.dx - c.dx);
        var delta = a1 - a0;
        // Gentle snap to 15 degree steps.
        final step = math.pi / 12;
        final snapped = (delta / step).round() * step;
        if ((delta - snapped).abs() < 0.05) delta = snapped;
        return Affine2D.rotation(delta).aroundPivot(c);
      case _ManipHandle.corner:
        final o = box.corners[(d.index + 2) % 4];
        final d0 = (d.startPointer - o).distance;
        if (d0 < 1e-6) return Affine2D.identity;
        final s = ((p - o).distance / d0).clamp(0.05, 40.0).toDouble();
        return Affine2D.scale(s, s).aroundPivot(o);
      case _ManipHandle.edge:
        final o = (box.corners[(d.index + 2) % 4] + box.corners[(d.index + 3) % 4]) / 2;
        final axis = box.edgeMid(d.index) - o;
        final len = axis.distance;
        if (len < 1e-6) return Affine2D.identity;
        final n = axis / len;
        final d0 = (d.startPointer - o).dx * n.dx + (d.startPointer - o).dy * n.dy;
        if (d0.abs() < 1e-6) return Affine2D.identity;
        final d1 = (p - o).dx * n.dx + (p - o).dy * n.dy;
        final s = (d1 / d0).clamp(0.05, 40.0).toDouble();
        final k = s - 1;
        final stretch = Affine2D(1 + k * n.dx * n.dx, k * n.dx * n.dy, k * n.dx * n.dy, 1 + k * n.dy * n.dy, 0, 0);
        return stretch.aroundPivot(o);
    }
  }

  // ---- two-finger pinch on the object -----------------------------------------------

  Offset? _pinchStart;

  /// Starts a pinch when both fingers are on the selected object.
  bool manipPinchBegin(Offset focalDoc) {
    final box = manipBox;
    if (tool != SketchTool.move || box == null || !box.contains(focalDoc, slack: 24 / _viewZoom)) return false;
    manipCancelDrag();
    _pinchStart = focalDoc;
    final kind = manipKind;
    _manipDrag = _ManipDrag(
      handle: _ManipHandle.body,
      index: 0,
      startPointer: focalDoc,
      box: box,
      kind: kind,
      startManual: transformSession?.manual ?? Affine2D.identity,
      startRef: kind == ManipKind.reference ? references.byId(selectedReferenceId!) : null,
      startPoints: kind == ManipKind.shape ? List<Offset>.of(this.selectedShape!.points) : null,
    );
    _manipBeginDrag(_manipDrag!);
    return true;
  }

  void manipPinchUpdate(double scale, double rotation, Offset currentFocalDoc) {
    final d = _manipDrag, s = _pinchStart;
    if (d == null || s == null) return;
    final k = scale.clamp(0.05, 40.0).toDouble();
    final r = d.box.canRotate ? rotation : 0.0;
    final delta = Affine2D.translation(currentFocalDoc.dx, currentFocalDoc.dy) *
        Affine2D.rotation(r) *
        Affine2D.scale(k, k) *
        Affine2D.translation(-s.dx, -s.dy);
    _manipApply(d, delta);
  }

  void manipPinchEnd() {
    final d = _manipDrag;
    _manipDrag = null;
    _pinchStart = null;
    if (d != null) _manipFinish(d);
  }

  // ---- applying a change ---------------------------------------------------------------

  void _manipBeginDrag(_ManipDrag d) {
    if (d.kind == ManipKind.shape) d.snapshot = _Snapshot.take(this);
  }

  void _manipApply(_ManipDrag d, Affine2D delta) {
    switch (d.kind) {
      case ManipKind.layer:
        final s = transformSession;
        if (s == null) return;
        s.manual = delta * d.startManual;
      case ManipKind.reference:
        final start = d.startRef;
        final size = start == null ? null : this.referenceSize(start.id);
        if (start == null || size == null) return;
        final m = delta * this._refMatrix(start, size);
        final scale = math.sqrt(m.a * m.a + m.b * m.b).clamp(0.02, 20.0).toDouble();
        final rot = math.atan2(m.b, m.a);
        final center = m.apply(Offset(size.width / 2, size.height / 2));
        references = references.update(
          start.id,
          (r) => r.copyWith(
            scale: scale,
            rotation: rot,
            x: center.dx - size.width * scale / 2,
            y: center.dy - size.height * scale / 2,
          ),
        );
      case ManipKind.shape:
        final i = selectedShapeIndex, pts = d.startPoints;
        if (i == null || pts == null || i >= activeLayer.shapes.length) return;
        try {
          activeLayer.shapes[i] = activeLayer.shapes[i].copyWith(points: [for (final p in pts) delta.apply(p)]);
        } on ShapeException {
          return;
        }
      case ManipKind.none:
        return;
    }
    repaint.ping();
  }

  void _manipRestore(_ManipDrag d) => _manipApply(d, Affine2D.identity);

  void _manipFinish(_ManipDrag d) {
    switch (d.kind) {
      case ManipKind.reference:
        // Saved once, when the finger lifts, not on every move.
        unawaited(this.setReferences(references));
      case ManipKind.shape:
        final before = d.snapshot;
        if (before != null) {
          final after = _Snapshot.take(this);
          _pushEntry(_HistoryEntry(
            'Move / resize shape',
            () => before.restore(this, invalidate: false),
            () => after.restore(this, invalidate: false),
          ));
          _markChanged();
        }
      case ManipKind.layer:
      case ManipKind.none:
        break;
    }
    repaint.ping();
    _notify();
  }

  // ---- selection by tapping ----------------------------------------------------------

  /// Tap with the Move tool: topmost reference, else a shape on the active
  /// layer, else the whole active layer.
  void manipTap(Offset p) {
    final z = _viewZoom;
    if (showReferences) {
      for (final r in references.visible.toList().reversed) {
        if (r.locked) continue;
        final size = this.referenceSize(r.id);
        if (size == null) continue;
        final inv = this._refMatrix(r, size).inverse();
        if (inv == null) continue;
        final x = inv.applyX(p.dx, p.dy), y = inv.applyY(p.dx, p.dy);
        if (x >= 0 && y >= 0 && x <= size.width && y <= size.height) {
          if (transformSession != null) this.cancelTransform();
          selectedShapeIndex = null;
          selectedReferenceId = r.id;
          repaint.ping();
          _notify();
          return;
        }
      }
    }
    if (activeLayer.isPaint) {
      final list = activeLayer.shapes;
      for (var i = list.length - 1; i >= 0; i--) {
        if (list[i].hits(p, tolerance: 14 / z)) {
          if (transformSession != null) this.cancelTransform();
          selectedReferenceId = null;
          selectedShapeIndex = i;
          repaint.ping();
          _notify();
          return;
        }
      }
    }
    // Empty space: select the whole layer.
    final hadSomethingElse = selectedReferenceId != null || selectedShapeIndex != null;
    selectedReferenceId = null;
    selectedShapeIndex = null;
    if (transformSession == null) {
      this.beginTransform();
    } else if (hadSomethingElse) {
      repaint.ping();
      _notify();
    }
  }

  /// Delete the selected reference or shape.
  void manipDelete() {
    switch (manipKind) {
      case ManipKind.reference:
        unawaited(this.removeReference(selectedReferenceId!));
      case ManipKind.shape:
        this.deleteSelectedShape();
      case ManipKind.layer:
      case ManipKind.none:
        break;
    }
  }

  bool get manipCanDelete => manipKind == ManipKind.reference || manipKind == ManipKind.shape;

  void manipFlipLayer({required bool horizontal}) {
    if (manipKind != ManipKind.layer) return;
    this.updateTransform((t) {
      if (horizontal) {
        t.flipH = !t.flipH;
      } else {
        t.flipV = !t.flipV;
      }
    });
  }

  // ---- drawing the handles ------------------------------------------------------------

  void _paintManip(Canvas canvas, double zoom) {
    _viewZoom = zoom;
    final box = manipBox;
    if (box == null) return;
    final px = 1 / zoom;
    final path = Path()..addPolygon(box.corners, true);
    canvas.drawPath(path, Paint()..style = PaintingStyle.stroke..strokeWidth = 3 * px..color = const Color(0xFFFFFFFF));
    canvas.drawPath(path, Paint()..style = PaintingStyle.stroke..strokeWidth = 1.5 * px..color = const Color(0xFF3478F6));
    void dot(Offset c, double r, {bool square = false}) {
      final fill = Paint()..color = const Color(0xFFFFFFFF);
      final line = Paint()..style = PaintingStyle.stroke..strokeWidth = 2 * px..color = const Color(0xFF3478F6);
      if (square) {
        final rect = Rect.fromCenter(center: c, width: r * 2, height: r * 2);
        canvas.drawRect(rect, fill);
        canvas.drawRect(rect, line);
      } else {
        canvas.drawCircle(c, r, fill);
        canvas.drawCircle(c, r, line);
      }
    }

    for (final c in box.corners) {
      dot(c, 10 * px);
    }
    if (box.canStretch) {
      for (var i = 0; i < 4; i++) {
        dot(box.edgeMid(i), 7 * px, square: true);
      }
    }
    if (box.canRotate) {
      final h = box.rotateHandle(_rotateOffsetPx * px);
      canvas.drawLine(box.edgeMid(0), h, Paint()..strokeWidth = 1.5 * px..color = const Color(0xFF3478F6));
      dot(h, 11 * px);
      canvas.drawArc(Rect.fromCircle(center: h, radius: 5 * px), -2.6, 4.2, false,
          Paint()..style = PaintingStyle.stroke..strokeWidth = 1.5 * px..color = const Color(0xFF3478F6));
    }
  }
}
