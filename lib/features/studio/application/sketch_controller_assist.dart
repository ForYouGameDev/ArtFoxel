part of 'sketch_controller.dart';

/// Colour pair and drawing aids (Phase 5.1 / 5.3).
extension SketchAssistActions on SketchController {
  // ---- colours --------------------------------------------------------------

  void setBackgroundColor(int argb) {
    bgColorArgb = 0xFF000000 | (argb & 0xFFFFFF);
    _notify();
  }

  void swapColors() {
    final fg = colorArgb;
    colorArgb = bgColorArgb;
    bgColorArgb = fg;
    _notify();
  }

  void resetColors() {
    colorArgb = 0xFF000000;
    bgColorArgb = 0xFFFFFFFF;
    _notify();
  }

  // ---- drawing aids ---------------------------------------------------------

  /// Replaces the assist settings. One undoable step; rulers, grids, guides
  /// and symmetry are saved with the project but never exported.
  void setAssist(AssistData next, {String label = 'Drawing aids'}) {
    final before = data.assist;
    if (before == next) return;
    data.assist = next;
    _pushEntry(_HistoryEntry(
      label,
      () {
        data.assist = before;
        repaint.ping();
      },
      () {
        data.assist = next;
        repaint.ping();
      },
    ));
    repaint.ping();
    _markChanged();
  }

  /// Mirrored/rotated copies of [stroke] for the active symmetry mode.
  List<SketchStroke> _symmetricCopies(SketchStroke stroke) {
    final a = data.assist;
    if (a.symmetry == SymmetryKind.none) return const [];
    final maps = AssistEngine.symmetryTransforms(
      a,
      Size(data.width.toDouble(), data.height.toDouble()),
    );
    final copies = <SketchStroke>[];
    var budget = SketchStroke.maxPoints;
    for (final m in maps) {
      if (stroke.points.length > budget) break;
      budget -= stroke.points.length;
      copies.add(stroke.copyWith(points: [
        for (final p in stroke.points)
          () {
            final o = AssistEngine.applyTransform(m, Offset(p.x, p.y));
            return StrokePoint(x: o.dx, y: o.dy, t: p.t, pressure: p.pressure, tilt: p.tilt);
          }(),
      ]));
    }
    return copies;
  }

  /// Draws the symmetric copies of the in-progress stroke as thin guides.
  void _paintSymmetryPreview(Canvas canvas) {
    final live = _live;
    final a = data.assist;
    if (live == null || live.length < 2 || a.symmetry == SymmetryKind.none) return;
    final maps = AssistEngine.symmetryTransforms(
        a, Size(data.width.toDouble(), data.height.toDouble()));
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1, size * 0.5)
      ..strokeCap = StrokeCap.round
      ..color = Color(colorArgb).withValues(alpha: 0.55);
    for (final m in maps) {
      final path = Path();
      for (var i = 0; i < live.length; i++) {
        final o = AssistEngine.applyTransform(m, Offset(live[i].x, live[i].y));
        i == 0 ? path.moveTo(o.dx, o.dy) : path.lineTo(o.dx, o.dy);
      }
      canvas.drawPath(path, paint);
    }
  }

  /// Explicitly turns the current ruler into a stroke on the active layer.
  /// Returns false (with a notice) if it cannot be drawn.
  bool bakeRulerAsArtwork() {
    final pts = AssistEngine.rulerAsPoints(data.assist.ruler);
    if (pts.length < 2) {
      notices.value = 'Turn on a ruler first.';
      return false;
    }
    if (!_canPaint()) return false;
    final layer = activeLayer;
    final stroke = SketchStroke(
      brushKey: data.registerBrush(brush),
      colorArgb: colorArgb,
      size: size,
      opacity: opacity,
      flow: flow,
      seed: 1,
      points: [
        for (var i = 0; i < pts.length; i++)
          StrokePoint(x: pts[i].dx, y: pts[i].dy, t: i * 8, pressure: 0.7),
      ],
    );
    layer.strokes.add(stroke);
    compositor.commit(layer);
    _pushEntry(_HistoryEntry('Ruler to artwork', () {
      data.layerById(layer.id)?.strokes.remove(stroke);
      compositor.invalidate(layer.id);
    }, () {
      data.layerById(layer.id)?.strokes.add(stroke);
      compositor.invalidate(layer.id);
    }));
    _markChanged();
    return true;
  }

  // ---- overlay ------------------------------------------------------------------

  /// Grid, guides, ruler, horizon and vanishing points, drawn above the art
  /// in document space. Never part of any export.
  void _paintAssistOverlay(Canvas canvas, double zoom) {
    _paintSymmetryPreview(canvas);
    final a = data.assist;
    if (!a.visible) return;
    final w = data.width.toDouble(), h = data.height.toDouble();
    final px = 1 / zoom;
    final thin = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = px
      ..color = const Color(0x553377FF);
    if (a.grid == GridKind.square) {
      final path = Path();
      for (var x = a.gridSize; x < w; x += a.gridSize) {
        path..moveTo(x, 0)..lineTo(x, h);
      }
      for (var y = a.gridSize; y < h; y += a.gridSize) {
        path..moveTo(0, y)..lineTo(w, y);
      }
      canvas.drawPath(path, thin);
    } else if (a.grid == GridKind.isometric) {
      final path = Path();
      final rowH = a.gridSize * math.sqrt(3) / 2;
      for (var y = 0.0; y <= h; y += rowH) {
        path..moveTo(0, y)..lineTo(w, y);
      }
      // 30° diagonals both ways.
      final slope = math.tan(math.pi / 6);
      for (var x = -h / slope; x < w + h / slope; x += a.gridSize) {
        path..moveTo(x, 0)..lineTo(x + h / slope, h);
        path..moveTo(x, 0)..lineTo(x - h / slope, h);
      }
      canvas.drawPath(path, thin);
    }
    final guide = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = px * 1.5
      ..color = const Color(0xAAFF3366);
    for (final g in a.guides) {
      g.vertical
          ? canvas.drawLine(Offset(g.position, 0), Offset(g.position, h), guide)
          : canvas.drawLine(Offset(0, g.position), Offset(w, g.position), guide);
    }
    if (a.horizonY != null) {
      canvas.drawLine(Offset(0, a.horizonY!), Offset(w, a.horizonY!),
          Paint()..color = const Color(0xCC00AA55)..strokeWidth = px * 2);
    }
    for (final vp in a.vanishingPoints) {
      canvas.drawCircle(vp, 6 * px, Paint()..color = const Color(0xFF00AA55));
      for (var i = 0; i < 12; i++) {
        final ang = i * math.pi / 6;
        canvas.drawLine(
            vp,
            vp + Offset(math.cos(ang), math.sin(ang)) * math.max(w, h) * 2,
            Paint()..color = const Color(0x2200AA55)..strokeWidth = px);
      }
    }
    final ruler = a.ruler;
    if (ruler.active) {
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = px * 2
        ..color = const Color(0xCCFF9900);
      if (ruler.kind == RulerKind.line) {
        // Extend to the canvas edges so it reads as a ruler.
        final d = (ruler.b - ruler.a);
        if (d.distance > 0) {
          final u = d / d.distance * math.max(w, h) * 2;
          canvas.drawLine(ruler.a - u, ruler.a + u, paint);
        }
      } else if (ruler.kind == RulerKind.parallel) {
        final d = ruler.b - ruler.a;
        if (d.distance > 0) {
          final u = d / d.distance * math.max(w, h) * 2;
          final n = Offset(-d.dy, d.dx) / d.distance;
          for (var k = -20; k <= 20; k++) {
            final o = ruler.a + n * (k * ruler.spacing);
            canvas.drawLine(o - u, o + u, paint..color = const Color(0x88FF9900));
          }
        }
      } else if (ruler.kind == RulerKind.perspective) {
        for (var i = 0; i < 24; i++) {
          final ang = i * math.pi / 12;
          canvas.drawLine(
              ruler.a,
              ruler.a + Offset(math.cos(ang), math.sin(ang)) * math.max(w, h) * 2,
              paint..color = const Color(0x55FF9900));
        }
      } else {
        final pts = AssistEngine.rulerAsPoints(ruler);
        if (pts.length > 1) {
          final path = Path()..moveTo(pts.first.dx, pts.first.dy);
          for (final p in pts.skip(1)) {
            path.lineTo(p.dx, p.dy);
          }
          canvas.drawPath(path, paint);
        }
      }
      canvas.drawCircle(ruler.a, 5 * px, Paint()..color = const Color(0xFFFF9900));
      canvas.drawCircle(ruler.b, 5 * px, Paint()..color = const Color(0xFFFF9900));
    }
    if (a.symmetry != SymmetryKind.none) {
      final c = a.symmetryCenter ?? Offset(w / 2, h / 2);
      final sym = Paint()..strokeWidth = px..color = const Color(0x88AA33FF);
      switch (a.symmetry) {
        case SymmetryKind.vertical:
          canvas.drawLine(Offset(c.dx, 0), Offset(c.dx, h), sym);
        case SymmetryKind.horizontal:
          canvas.drawLine(Offset(0, c.dy), Offset(w, c.dy), sym);
        case SymmetryKind.both:
          canvas.drawLine(Offset(c.dx, 0), Offset(c.dx, h), sym);
          canvas.drawLine(Offset(0, c.dy), Offset(w, c.dy), sym);
        default:
          for (var i = 0; i < a.symmetryAxes; i++) {
            final ang = math.pi * i / a.symmetryAxes;
            final u = Offset(math.cos(ang), math.sin(ang)) * math.max(w, h);
            canvas.drawLine(c - u, c + u, sym);
          }
      }
    }
  }
}
