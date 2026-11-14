import 'dart:math' as math;
import 'dart:ui';

import 'gradient_model.dart';

class ShapeException implements Exception {
  const ShapeException(this.message);
  final String message;
  @override
  String toString() => message;
}

enum ShapeKind {
  line,
  rectangle,
  roundedRect,
  circle,
  ellipse,
  polygon,
  star,
  arc,
  polyline,
  bezier, // quadratic: start, control, end
  cubic, // cubic: start, c1, c2, end
}

extension ShapeKindInfo on ShapeKind {
  String get label => switch (this) {
        ShapeKind.line => 'Line',
        ShapeKind.rectangle => 'Rectangle',
        ShapeKind.roundedRect => 'Rounded rectangle',
        ShapeKind.circle => 'Circle',
        ShapeKind.ellipse => 'Ellipse',
        ShapeKind.polygon => 'Polygon',
        ShapeKind.star => 'Star',
        ShapeKind.arc => 'Arc',
        ShapeKind.polyline => 'Polyline',
        ShapeKind.bezier => 'Bezier (quadratic)',
        ShapeKind.cubic => 'Cubic Bezier',
      };

  /// Shapes that enclose an area and can therefore be filled.
  bool get closed => switch (this) {
        ShapeKind.rectangle ||
        ShapeKind.roundedRect ||
        ShapeKind.circle ||
        ShapeKind.ellipse ||
        ShapeKind.polygon ||
        ShapeKind.star =>
          true,
        _ => false,
      };

  /// Fixed number of control points, or null if variable.
  int? get fixedPoints => switch (this) {
        ShapeKind.line ||
        ShapeKind.rectangle ||
        ShapeKind.roundedRect ||
        ShapeKind.circle ||
        ShapeKind.ellipse ||
        ShapeKind.polygon ||
        ShapeKind.star =>
          2,
        ShapeKind.arc => 2,
        ShapeKind.bezier => 3,
        ShapeKind.cubic => 4,
        ShapeKind.polyline => null,
      };
}

/// An editable vector shape: a kind plus control points in layer space.
/// Rasterization only happens when the shape layer is rasterized or exported.
class ShapeData {
  ShapeData({
    required this.kind,
    required List<Offset> points,
    this.sides = 5,
    this.cornerRadius = 24,
    this.innerRatio = 0.45,
    this.sweepDegrees = 270,
    this.fillArgb,
    this.fillGradient,
    this.strokeArgb = 0xFF000000,
    this.strokeWidth = 4,
  }) : points = List.unmodifiable(points) {
    final fixed = kind.fixedPoints;
    if (fixed != null && points.length != fixed) {
      throw ShapeException('${kind.label} needs $fixed points.');
    }
    if (kind == ShapeKind.polyline && points.length < 2) {
      throw const ShapeException('A polyline needs at least 2 points.');
    }
    if (points.length > maxPoints) {
      throw const ShapeException('Too many points.');
    }
    for (final p in points) {
      if (!p.dx.isFinite || !p.dy.isFinite) {
        throw const ShapeException('Shape points must be finite.');
      }
    }
  }

  static const maxPoints = 512;

  final ShapeKind kind;
  final List<Offset> points;
  final int sides;
  final double cornerRadius;
  final double innerRatio;
  final double sweepDegrees;
  final int? fillArgb;
  final GradientData? fillGradient;
  final int? strokeArgb;
  final double strokeWidth;

  bool get hasFill => kind.closed && (fillArgb != null || fillGradient != null);

  ShapeData copyWith({
    List<Offset>? points,
    int? sides,
    double? cornerRadius,
    double? innerRatio,
    double? sweepDegrees,
    Object? fillArgb = _keep,
    Object? fillGradient = _keep,
    Object? strokeArgb = _keep,
    double? strokeWidth,
  }) =>
      ShapeData(
        kind: kind,
        points: points ?? this.points,
        sides: sides ?? this.sides,
        cornerRadius: cornerRadius ?? this.cornerRadius,
        innerRatio: innerRatio ?? this.innerRatio,
        sweepDegrees: sweepDegrees ?? this.sweepDegrees,
        fillArgb: identical(fillArgb, _keep) ? this.fillArgb : fillArgb as int?,
        fillGradient: identical(fillGradient, _keep)
            ? this.fillGradient
            : fillGradient as GradientData?,
        strokeArgb:
            identical(strokeArgb, _keep) ? this.strokeArgb : strokeArgb as int?,
        strokeWidth: strokeWidth ?? this.strokeWidth,
      );

  static const Object _keep = Object();

  Rect get bounds {
    final p = buildPath();
    final b = p.getBounds();
    return b.inflate(strokeArgb == null ? 0 : strokeWidth / 2);
  }

  Rect get _box => Rect.fromPoints(points[0], points[1]);

  /// Builds the geometry as a [Path].
  Path buildPath() {
    final path = Path();
    switch (kind) {
      case ShapeKind.line:
        path
          ..moveTo(points[0].dx, points[0].dy)
          ..lineTo(points[1].dx, points[1].dy);
      case ShapeKind.rectangle:
        path.addRect(_box);
      case ShapeKind.roundedRect:
        final r = math.min(cornerRadius, math.min(_box.width, _box.height) / 2);
        path.addRRect(RRect.fromRectAndRadius(_box, Radius.circular(math.max(0, r))));
      case ShapeKind.ellipse:
        path.addOval(_box);
      case ShapeKind.circle:
        final r = (points[1] - points[0]).distance;
        path.addOval(Rect.fromCircle(center: points[0], radius: r));
      case ShapeKind.polygon:
        _addRegular(path, sides, 1);
      case ShapeKind.star:
        _addRegular(path, sides, innerRatio, star: true);
      case ShapeKind.arc:
        final r = (points[1] - points[0]).distance;
        final start = math.atan2(points[1].dy - points[0].dy, points[1].dx - points[0].dx);
        path.addArc(Rect.fromCircle(center: points[0], radius: r), start,
            sweepDegrees * math.pi / 180);
      case ShapeKind.polyline:
        path.moveTo(points.first.dx, points.first.dy);
        for (final p in points.skip(1)) {
          path.lineTo(p.dx, p.dy);
        }
      case ShapeKind.bezier:
        path
          ..moveTo(points[0].dx, points[0].dy)
          ..quadraticBezierTo(points[1].dx, points[1].dy, points[2].dx, points[2].dy);
      case ShapeKind.cubic:
        path
          ..moveTo(points[0].dx, points[0].dy)
          ..cubicTo(points[1].dx, points[1].dy, points[2].dx, points[2].dy,
              points[3].dx, points[3].dy);
    }
    return path;
  }

  void _addRegular(Path path, int n, double inner, {bool star = false}) {
    final c = points[0];
    final radius = (points[1] - c).distance;
    final start = math.atan2(points[1].dy - c.dy, points[1].dx - c.dx);
    final count = star ? n * 2 : n;
    for (var i = 0; i < count; i++) {
      final r = star && i.isOdd ? radius * inner : radius;
      final a = start + 2 * math.pi * i / count;
      final p = Offset(c.dx + math.cos(a) * r, c.dy + math.sin(a) * r);
      i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
    }
    path.close();
  }

  /// Draws this shape onto [canvas].
  void paintTo(Canvas canvas) {
    final path = buildPath();
    if (hasFill) {
      final paint = Paint()..style = PaintingStyle.fill..isAntiAlias = true;
      if (fillGradient != null) {
        paint.shader = fillGradient!.toShader(path.getBounds());
      } else {
        paint.color = Color(fillArgb!);
      }
      canvas.drawPath(path, paint);
    }
    if (strokeArgb != null && strokeWidth > 0) {
      canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = strokeWidth
            ..strokeJoin = StrokeJoin.round
            ..strokeCap = StrokeCap.round
            ..color = Color(strokeArgb!)
            ..isAntiAlias = true);
    }
  }

  /// Hit test with [tolerance] px slack.
  bool hits(Offset p, {double tolerance = 10}) {
    final path = buildPath();
    if (hasFill && path.contains(p)) return true;
    final slack = tolerance + strokeWidth / 2;
    var best = double.infinity;
    for (final seg in flattened()) {
      best = math.min(best, _distSeg(p, seg.$1, seg.$2));
    }
    return best <= slack;
  }

  /// Flattened outline as segments (used for hit-testing and tests).
  List<(Offset, Offset)> flattened() {
    final out = <(Offset, Offset)>[];
    for (final m in buildPath().computeMetrics()) {
      final n = math.max(2, (m.length / 8).ceil());
      Offset? prev;
      for (var i = 0; i <= n; i++) {
        final t = m.getTangentForOffset(m.length * i / n);
        if (t == null) continue;
        if (prev != null) out.add((prev, t.position));
        prev = t.position;
      }
    }
    return out;
  }

  /// Index of the control point within [radius] of [p], or null.
  int? nearestPoint(Offset p, {double radius = 24}) {
    int? best;
    var bd = radius;
    for (var i = 0; i < points.length; i++) {
      final d = (points[i] - p).distance;
      if (d <= bd) {
        bd = d;
        best = i;
      }
    }
    return best;
  }

  ShapeData movePoint(int index, Offset to) {
    if (index < 0 || index >= points.length) {
      throw const ShapeException('No such handle.');
    }
    final next = [...points]..[index] = to;
    return copyWith(points: next);
  }

  ShapeData translate(Offset d) =>
      copyWith(points: [for (final p in points) p + d]);

  ShapeData insertPoint(int at, Offset p) {
    if (kind != ShapeKind.polyline) {
      throw const ShapeException('Only polylines can gain points.');
    }
    return copyWith(points: [...points]..insert(at.clamp(0, points.length), p));
  }

  ShapeData removePoint(int i) {
    if (kind != ShapeKind.polyline || points.length <= 2) {
      throw const ShapeException('A polyline needs at least 2 points.');
    }
    return copyWith(points: [...points]..removeAt(i));
  }

  Map<String, Object?> toJson() => {
        'k': kind.name,
        'pts': [
          for (final p in points) [p.dx, p.dy]
        ],
        'n': sides,
        'cr': cornerRadius,
        'ir': innerRatio,
        'sw': sweepDegrees,
        if (fillArgb != null) 'fill': fillArgb,
        if (fillGradient != null) 'grad': fillGradient!.toJson(),
        if (strokeArgb != null) 'stroke': strokeArgb,
        'w': strokeWidth,
      };

  factory ShapeData.fromJson(Object? json) {
    if (json is! Map) throw const ShapeException('Shape is not an object.');
    final kind = ShapeKind.values.where((k) => k.name == json['k']);
    if (kind.isEmpty) throw const ShapeException('Unknown shape kind.');
    final raw = json['pts'];
    if (raw is! List) throw const ShapeException('Shape has no points.');
    final pts = <Offset>[];
    for (final p in raw.take(ShapeData.maxPoints + 1)) {
      if (p is List && p.length == 2 && p[0] is num && p[1] is num) {
        pts.add(Offset((p[0] as num).toDouble(), (p[1] as num).toDouble()));
      } else {
        throw const ShapeException('Bad shape point.');
      }
    }
    double d(String k, double f, double lo, double hi) {
      final v = json[k];
      return v is num && v.isFinite ? v.toDouble().clamp(lo, hi) : f;
    }

    return ShapeData(
      kind: kind.first,
      points: pts,
      sides: d('n', 5, 3, 24).round(),
      cornerRadius: d('cr', 24, 0, 4096),
      innerRatio: d('ir', 0.45, 0.05, 0.95),
      sweepDegrees: d('sw', 270, -360, 360),
      fillArgb: json['fill'] is int ? json['fill'] as int : null,
      fillGradient: json['grad'] == null ? null : GradientData.fromJson(json['grad']),
      strokeArgb: json['stroke'] is int ? json['stroke'] as int : null,
      strokeWidth: d('w', 4, 0, 512),
    );
  }
}

double _distSeg(Offset p, Offset a, Offset b) {
  final d = b - a;
  final l2 = d.dx * d.dx + d.dy * d.dy;
  if (l2 < 1e-9) return (p - a).distance;
  final t = (((p - a).dx * d.dx + (p - a).dy * d.dy) / l2).clamp(0.0, 1.0);
  return (p - (a + d * t)).distance;
}

/// Heuristic shape recognition from a freehand stroke. Deliberately
/// conservative: returns null unless the fit is clearly good, so a sloppy
/// squiggle is never "corrected" into something unintended.
abstract final class ShapeRecognizer {
  static ShapeData? recognize(List<Offset> pts,
      {int? strokeArgb, double strokeWidth = 4}) {
    if (pts.length < 8) return null;
    final bounds = _bounds(pts);
    final diag = bounds.size.shortestSide == 0
        ? bounds.size.longestSide
        : math.sqrt(bounds.width * bounds.width + bounds.height * bounds.height);
    if (diag < 24) return null;
    final length = _pathLength(pts);
    final gap = (pts.first - pts.last).distance;
    final closed = gap < length * 0.18;

    if (!closed) {
      // Straight line: max deviation from the chord is tiny.
      final dev = pts.map((p) => _distSeg(p, pts.first, pts.last)).reduce(math.max);
      if (dev < diag * 0.04) {
        return ShapeData(
            kind: ShapeKind.line,
            points: [pts.first, pts.last],
            strokeArgb: strokeArgb,
            strokeWidth: strokeWidth);
      }
      return null;
    }

    // Circle / ellipse: radial variance around the centroid.
    final c = Offset(pts.map((p) => p.dx).reduce((a, b) => a + b) / pts.length,
        pts.map((p) => p.dy).reduce((a, b) => a + b) / pts.length);
    final radii = pts.map((p) => (p - c).distance).toList();
    final mean = radii.reduce((a, b) => a + b) / radii.length;
    final variance =
        radii.map((r) => (r - mean) * (r - mean)).reduce((a, b) => a + b) / radii.length;
    if (mean > 1 && math.sqrt(variance) / mean < 0.08) {
      return ShapeData(
          kind: ShapeKind.circle,
          points: [c, c + Offset(mean, 0)],
          strokeArgb: strokeArgb,
          strokeWidth: strokeWidth);
    }

    // Polygons via Douglas-Peucker.
    final simp = _douglasPeucker(pts, diag * 0.06);
    final corners = [...simp];
    if (corners.length > 1 && (corners.first - corners.last).distance < diag * 0.12) {
      corners.removeLast();
    }
    if (corners.length == 4) {
      final xs = corners.map((p) => p.dx), ys = corners.map((p) => p.dy);
      final box = Rect.fromLTRB(xs.reduce(math.min), ys.reduce(math.min),
          xs.reduce(math.max), ys.reduce(math.max));
      // Corners must sit near the box corners (axis-aligned rectangle).
      final tol = diag * 0.12;
      final boxCorners = [box.topLeft, box.topRight, box.bottomRight, box.bottomLeft];
      final ok = boxCorners.every((bc) => corners.any((p) => (p - bc).distance < tol));
      if (ok) {
        return ShapeData(
            kind: ShapeKind.rectangle,
            points: [box.topLeft, box.bottomRight],
            strokeArgb: strokeArgb,
            strokeWidth: strokeWidth);
      }
    }
    if (corners.length == 3) {
      return ShapeData(
          kind: ShapeKind.polyline,
          points: [...corners, corners.first],
          strokeArgb: strokeArgb,
          strokeWidth: strokeWidth);
    }
    return null;
  }

  static Rect _bounds(List<Offset> pts) {
    var l = pts.first.dx, r = l, t = pts.first.dy, b = t;
    for (final p in pts) {
      l = math.min(l, p.dx);
      r = math.max(r, p.dx);
      t = math.min(t, p.dy);
      b = math.max(b, p.dy);
    }
    return Rect.fromLTRB(l, t, r, b);
  }

  static double _pathLength(List<Offset> pts) {
    var s = 0.0;
    for (var i = 1; i < pts.length; i++) {
      s += (pts[i] - pts[i - 1]).distance;
    }
    return s;
  }

  static List<Offset> _douglasPeucker(List<Offset> pts, double eps) {
    if (pts.length < 3) return [...pts];
    var maxD = 0.0, idx = 0;
    for (var i = 1; i < pts.length - 1; i++) {
      final d = _distSeg(pts[i], pts.first, pts.last);
      if (d > maxD) {
        maxD = d;
        idx = i;
      }
    }
    if (maxD > eps) {
      final l = _douglasPeucker(pts.sublist(0, idx + 1), eps);
      final r = _douglasPeucker(pts.sublist(idx), eps);
      return [...l.sublist(0, l.length - 1), ...r];
    }
    return [pts.first, pts.last];
  }
}
