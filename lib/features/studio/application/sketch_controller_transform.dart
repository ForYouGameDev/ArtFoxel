part of 'sketch_controller.dart';

/// Parameters of a transform being adjusted. Nothing in the document changes
/// until [SketchTransformActions.applyTransform]; cancelling discards it, so
/// the source content stays untouched and recoverable.
class TransformSession {
  TransformSession({
    required this.layerIds,
    required this.bounds,
    this.anchor = CanvasAnchor.center,
  });

  /// Layers that move together (a group's paint/image descendants).
  final Set<String> layerIds;

  /// Bounds of the content in document coordinates (pivot reference).
  final Rect bounds;
  CanvasAnchor anchor;

  double translateX = 0;
  double translateY = 0;
  double scaleX = 1;
  double scaleY = 1;
  bool uniform = true;
  double rotationDegrees = 0;
  double skewXDegrees = 0;
  double skewYDegrees = 0;
  bool flipH = false;
  bool flipV = false;

  Offset get pivot => anchor.pointIn(bounds);

  /// scale/flip, then skew, then rotate around the pivot, then translate.
  Affine2D get matrix {
    final sx = scaleX * (flipH ? -1 : 1);
    final sy = scaleY * (flipV ? -1 : 1);
    final inner = Affine2D.rotation(rotationDegrees * math.pi / 180) *
        Affine2D.skew(skewXDegrees * math.pi / 180, skewYDegrees * math.pi / 180) *
        Affine2D.scale(sx, sy);
    return Affine2D.translation(translateX, translateY) * inner.aroundPivot(pivot);
  }

  bool get isIdentity => matrix.isIdentity;
}

/// Move / scale / rotate / flip / skew (free transform) for layers and groups,
/// and the three distinct canvas operations (Phase 4.5).
extension SketchTransformActions on SketchController {
  TransformPreview? get transformPreview {
    final session = transformSession;
    if (session == null) return null;
    return TransformPreview(layerIds: session.layerIds, matrix: session.matrix);
  }

  /// Starts a transform of the active layer (or group).
  bool beginTransform() {
    final layer = activeLayer;
    if (LayerOps.isEffectivelyLocked(data, layer)) {
      _notice('"${layer.name}" is locked.');
      return false;
    }
    final targets = <SketchLayerData>[
      if (layer.isGroup) ...LayerOps.descendants(data, layer.id).where((l) => !l.isGroup) else layer,
    ];
    Rect? bounds;
    for (final t in targets) {
      final b = DocGeometry.contentBounds(t);
      if (b != null) bounds = bounds == null ? b : bounds.expandToInclude(b);
    }
    if (bounds == null) {
      _notice('This layer is empty, so there is nothing to transform.');
      return false;
    }
    if (isDrawing) cancelStroke();
    transformSession = TransformSession(
      layerIds: {for (final t in targets) t.id},
      bounds: bounds,
    );
    repaint.ping();
    _notify();
    return true;
  }

  /// Changes session values; the canvas shows the result as a live preview.
  void updateTransform(void Function(TransformSession session) change) {
    final session = transformSession;
    if (session == null) return;
    change(session);
    if (session.uniform) session.scaleY = session.scaleX;
    session.scaleX = session.scaleX.clamp(0.05, 20.0).toDouble();
    session.scaleY = session.scaleY.clamp(0.05, 20.0).toDouble();
    session.skewXDegrees = session.skewXDegrees.clamp(-80.0, 80.0).toDouble();
    session.skewYDegrees = session.skewYDegrees.clamp(-80.0, 80.0).toDouble();
    repaint.ping();
    _notify();
  }

  void resetTransform() {
    final session = transformSession;
    if (session == null) return;
    updateTransform((s) {
      s.translateX = s.translateY = s.skewXDegrees = s.skewYDegrees = s.rotationDegrees = 0;
      s.scaleX = s.scaleY = 1;
      s.flipH = s.flipV = false;
    });
  }

  void cancelTransform() {
    if (transformSession == null) return;
    transformSession = null;
    repaint.ping();
    _notify();
  }

  /// Bakes the transform into the layers' stroke geometry (image layers keep
  /// their pixels and change placement). One undo step.
  void applyTransform() {
    final session = transformSession;
    if (session == null) return;
    final matrix = session.matrix;
    transformSession = null;
    if (matrix.isIdentity || !matrix.isInvertible) {
      repaint.ping();
      _notify();
      return;
    }
    _recordStructural('Transform', () {
      for (final id in session.layerIds) {
        final layer = data.layerById(id);
        if (layer != null) DocGeometry.transformLayer(data, layer, matrix);
      }
    });
  }

  void _paintTransformGuides(Canvas canvas, double zoom) {
    final session = transformSession;
    if (session == null) return;
    final m = session.matrix;
    final b = session.bounds;
    final corners = [b.topLeft, b.topRight, b.bottomRight, b.bottomLeft].map(m.apply).toList();
    final path = Path()..addPolygon(corners, true);
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
        ..color = const Color(0xFF3478F6),
    );
    final pivot = m.apply(session.pivot);
    canvas.drawCircle(pivot, 6 / zoom, Paint()..color = const Color(0xFFFFFFFF));
    canvas.drawCircle(
      pivot,
      4 / zoom,
      Paint()
        ..color = const Color(0xFFE5484D),
    );
  }

  // ---- canvas size operations ---------------------------------------------------------

  void _geometry(String label, void Function() change) {
    if (transformSession != null) cancelTransform();
    if (isDrawing) cancelStroke();
    try {
      _recordStructural(label, () {
        change();
        selection = null; // selections are tied to the old canvas size
        this._rebuildOverlay();
      });
    } on ArgumentError catch (error) {
      _notice('${error.message}');
    }
  }

  /// Crop image: keep [rect] (document pixels); the canvas becomes that size.
  void cropImage(Rect rect, {bool discardOutside = false}) {
    final canvas = Rect.fromLTWH(0, 0, data.width.toDouble(), data.height.toDouble());
    final clipped = rect.intersect(canvas);
    if (clipped.width < 1 || clipped.height < 1) {
      _notice('The crop area must overlap the canvas.');
      return;
    }
    _geometry('Crop image', () => DocGeometry.cropImage(data, clipped, discardOutside: discardOutside));
  }

  /// Resize canvas: new canvas size; artwork keeps its size, placed by [anchor].
  void resizeCanvas(int width, int height, {CanvasAnchor anchor = CanvasAnchor.center, bool discardOutside = false}) {
    _geometry(
      'Resize canvas',
      () => DocGeometry.resizeCanvas(data, width, height, anchor: anchor, discardOutside: discardOutside),
    );
  }

  /// Resize image: canvas and artwork scale together.
  void resizeImage(int width, int height) {
    _geometry('Resize image', () => DocGeometry.resizeImage(data, width, height));
  }
}
