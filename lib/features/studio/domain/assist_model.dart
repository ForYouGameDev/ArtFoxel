import 'dart:math' as math;
import 'dart:ui';

/// Drawing aids (rulers, grids, guides, symmetry). These are *assist data*:
/// they are stored in the project but never part of the artwork or exports
/// unless [AssistEngine.rulerAsPoints] is used to convert a ruler to strokes.
class AssistException implements Exception {
  const AssistException(this.message);
  final String message;
  @override
  String toString() => message;
}

enum GridKind { none, square, isometric }

enum RulerKind { none, line, circle, ellipse, parallel, polygon, perspective }

enum SymmetryKind { none, vertical, horizontal, both, radial, mirror, kaleidoscope }

extension GridKindLabel on GridKind {
  String get label => switch (this) {
        GridKind.none => 'Off',
        GridKind.square => 'Square',
        GridKind.isometric => 'Isometric',
      };
}

extension RulerKindLabel on RulerKind {
  String get label => switch (this) {
        RulerKind.none => 'Off',
        RulerKind.line => 'Straight line',
        RulerKind.circle => 'Circle',
        RulerKind.ellipse => 'Ellipse',
        RulerKind.parallel => 'Parallel lines',
        RulerKind.polygon => 'Polygon',
        RulerKind.perspective => 'Perspective',
      };
}

extension SymmetryKindLabel on SymmetryKind {
  String get label => switch (this) {
        SymmetryKind.none => 'Off',
        SymmetryKind.vertical => 'Vertical mirror',
        SymmetryKind.horizontal => 'Horizontal mirror',
        SymmetryKind.both => 'Both axes',
        SymmetryKind.radial => 'Radial',
        SymmetryKind.mirror => 'Radial + mirror',
        SymmetryKind.kaleidoscope => 'Kaleidoscope',
      };
}

T _enum<T extends Enum>(List<T> values, Object? name, T fallback) {
  for (final v in values) {
    if (v.name == name) return v;
  }
  return fallback;
}

double _num(Object? v, double fallback, {double? min, double? max}) {
  var d = v is num ? v.toDouble() : fallback;
  if (!d.isFinite) d = fallback;
  if (min != null && d < min) d = min;
  if (max != null && d > max) d = max;
  return d;
}

/// A single ruler. Geometry is in document pixels.
class RulerData {
  const RulerData({
    this.kind = RulerKind.none,
    this.a = const Offset(200, 200),
    this.b = const Offset(600, 200),
    this.sides = 5,
    this.spacing = 60,
    this.snapStrength = 24,
  });

  final RulerKind kind;

  /// Line: start. Circle/ellipse/polygon: centre. Perspective: vanishing point.
  final Offset a;

  /// Line: end. Circle: point on rim. Ellipse: corner of the bounding box
  /// relative to [a] (radii are |b-a|). Polygon: first vertex.
  final Offset b;
  final int sides;
  final double spacing;
  final double snapStrength;

  bool get active => kind != RulerKind.none;

  RulerData copyWith({
    RulerKind? kind,
    Offset? a,
    Offset? b,
    int? sides,
    double? spacing,
    double? snapStrength,
  }) =>
      RulerData(
        kind: kind ?? this.kind,
        a: a ?? this.a,
        b: b ?? this.b,
        sides: sides ?? this.sides,
        spacing: spacing ?? this.spacing,
        snapStrength: snapStrength ?? this.snapStrength,
      );

  Map<String, Object?> toJson() => {
        'k': kind.name,
        'a': [a.dx, a.dy],
        'b': [b.dx, b.dy],
        'n': sides,
        'sp': spacing,
        'ss': snapStrength,
      };

  static Offset _pt(Object? v, Offset fallback) {
    if (v is List && v.length == 2 && v[0] is num && v[1] is num) {
      final x = (v[0] as num).toDouble(), y = (v[1] as num).toDouble();
      if (x.isFinite && y.isFinite) return Offset(x, y);
    }
    return fallback;
  }

  factory RulerData.fromJson(Object? json) {
    if (json is! Map) return const RulerData();
    return RulerData(
      kind: _enum(RulerKind.values, json['k'], RulerKind.none),
      a: _pt(json['a'], const Offset(200, 200)),
      b: _pt(json['b'], const Offset(600, 200)),
      sides: _num(json['n'], 5, min: 3, max: 24).round(),
      spacing: _num(json['sp'], 60, min: 4, max: 2000),
      snapStrength: _num(json['ss'], 24, min: 2, max: 200),
    );
  }

  @override
  bool operator ==(Object o) =>
      o is RulerData &&
      o.kind == kind &&
      o.a == a &&
      o.b == b &&
      o.sides == sides &&
      o.spacing == spacing &&
      o.snapStrength == snapStrength;

  @override
  int get hashCode => Object.hash(kind, a, b, sides, spacing, snapStrength);
}

class GuideLine {
  const GuideLine({required this.vertical, required this.position});
  final bool vertical;
  final double position;
  Map<String, Object?> toJson() => {'v': vertical, 'p': position};
}

/// The full set of drawing aids for one sketch.
class AssistData {
  const AssistData({
    this.grid = GridKind.none,
    this.gridSize = 64,
    this.snapToGrid = false,
    this.guides = const [],
    this.snapToGuides = true,
    this.ruler = const RulerData(),
    this.horizonY,
    this.vanishingPoints = const [],
    this.symmetry = SymmetryKind.none,
    this.symmetryAxes = 6,
    this.symmetryCenter,
    this.visible = true,
  });

  static const maxGuides = 40;
  static const maxVanishingPoints = 3;

  final GridKind grid;
  final double gridSize;
  final bool snapToGrid;
  final List<GuideLine> guides;
  final bool snapToGuides;
  final RulerData ruler;

  /// Horizon line y (document px) or null.
  final double? horizonY;
  final List<Offset> vanishingPoints;
  final SymmetryKind symmetry;
  final int symmetryAxes;

  /// Null = canvas centre.
  final Offset? symmetryCenter;
  final bool visible;

  bool get isDefault =>
      grid == GridKind.none &&
      guides.isEmpty &&
      !ruler.active &&
      horizonY == null &&
      vanishingPoints.isEmpty &&
      symmetry == SymmetryKind.none;

  AssistData copyWith({
    GridKind? grid,
    double? gridSize,
    bool? snapToGrid,
    List<GuideLine>? guides,
    bool? snapToGuides,
    RulerData? ruler,
    Object? horizonY = _keep,
    List<Offset>? vanishingPoints,
    SymmetryKind? symmetry,
    int? symmetryAxes,
    Object? symmetryCenter = _keep,
    bool? visible,
  }) =>
      AssistData(
        grid: grid ?? this.grid,
        gridSize: gridSize ?? this.gridSize,
        snapToGrid: snapToGrid ?? this.snapToGrid,
        guides: guides ?? this.guides,
        snapToGuides: snapToGuides ?? this.snapToGuides,
        ruler: ruler ?? this.ruler,
        horizonY: identical(horizonY, _keep) ? this.horizonY : horizonY as double?,
        vanishingPoints: vanishingPoints ?? this.vanishingPoints,
        symmetry: symmetry ?? this.symmetry,
        symmetryAxes: symmetryAxes ?? this.symmetryAxes,
        symmetryCenter: identical(symmetryCenter, _keep)
            ? this.symmetryCenter
            : symmetryCenter as Offset?,
        visible: visible ?? this.visible,
      );

  static const Object _keep = Object();

  Map<String, Object?> toJson() => {
        'grid': grid.name,
        'gs': gridSize,
        'sg': snapToGrid,
        'guides': [for (final g in guides) g.toJson()],
        'sgu': snapToGuides,
        'ruler': ruler.toJson(),
        if (horizonY != null) 'hz': horizonY,
        'vps': [
          for (final p in vanishingPoints) [p.dx, p.dy]
        ],
        'sym': symmetry.name,
        'symN': symmetryAxes,
        if (symmetryCenter != null)
          'symC': [symmetryCenter!.dx, symmetryCenter!.dy],
        'vis': visible,
      };

  /// Lenient: malformed data falls back to defaults rather than failing the
  /// whole sketch load.
  factory AssistData.fromJson(Object? json) {
    if (json is! Map) return const AssistData();
    final guides = <GuideLine>[];
    final rawGuides = json['guides'];
    if (rawGuides is List) {
      for (final g in rawGuides.take(maxGuides)) {
        if (g is Map && g['p'] is num && (g['p'] as num).isFinite) {
          guides.add(GuideLine(
              vertical: g['v'] == true, position: (g['p'] as num).toDouble()));
        }
      }
    }
    final vps = <Offset>[];
    final rawVps = json['vps'];
    if (rawVps is List) {
      for (final p in rawVps.take(maxVanishingPoints)) {
        final o = RulerData._pt(p, const Offset(double.nan, double.nan));
        if (o.dx.isFinite) vps.add(o);
      }
    }
    final hz = json['hz'];
    final symC = json['symC'];
    return AssistData(
      grid: _enum(GridKind.values, json['grid'], GridKind.none),
      gridSize: _num(json['gs'], 64, min: 4, max: 1024),
      snapToGrid: json['sg'] == true,
      guides: guides,
      snapToGuides: json['sgu'] != false,
      ruler: RulerData.fromJson(json['ruler']),
      horizonY: hz is num && hz.isFinite ? hz.toDouble() : null,
      vanishingPoints: vps,
      symmetry: _enum(SymmetryKind.values, json['sym'], SymmetryKind.none),
      symmetryAxes: _num(json['symN'], 6, min: 2, max: 32).round(),
      symmetryCenter: symC == null
          ? null
          : RulerData._pt(symC, const Offset(double.nan, double.nan)).dx.isFinite
              ? RulerData._pt(symC, Offset.zero)
              : null,
      visible: json['vis'] != false,
    );
  }

  @override
  bool operator ==(Object o) =>
      o is AssistData && _jsonEq(toJson(), o.toJson());

  @override
  int get hashCode => toJson().toString().hashCode;

  static bool _jsonEq(Object? a, Object? b) => a.toString() == b.toString();
}

/// Pure geometry for the aids.
abstract final class AssistEngine {
  /// Snaps [p] to the nearest grid intersection when within [tolerance].
  static Offset snapGrid(Offset p, GridKind kind, double size, double tolerance) {
    switch (kind) {
      case GridKind.none:
        return p;
      case GridKind.square:
        final s = Offset((p.dx / size).round() * size, (p.dy / size).round() * size);
        return (s - p).distance <= tolerance ? s : p;
      case GridKind.isometric:
        // Isometric lattice: rows spaced size*sqrt(3)/2, alternate rows offset.
        final rowH = size * math.sqrt(3) / 2;
        final row = (p.dy / rowH).round();
        final off = row.isOdd ? size / 2 : 0.0;
        final col = ((p.dx - off) / size).round();
        final s = Offset(col * size + off, row * rowH);
        return (s - p).distance <= tolerance ? s : p;
    }
  }

  static Offset snapGuides(Offset p, List<GuideLine> guides, double tolerance) {
    var x = p.dx, y = p.dy;
    var bestX = tolerance + 1, bestY = tolerance + 1;
    for (final g in guides) {
      if (g.vertical) {
        final d = (p.dx - g.position).abs();
        if (d <= tolerance && d < bestX) {
          bestX = d;
          x = g.position;
        }
      } else {
        final d = (p.dy - g.position).abs();
        if (d <= tolerance && d < bestY) {
          bestY = d;
          y = g.position;
        }
      }
    }
    return Offset(x, y);
  }

  /// Closest point to [p] on the segment/infinite line through [a],[b].
  static Offset nearestOnLine(Offset p, Offset a, Offset b, {bool infinite = true}) {
    final d = b - a;
    final len2 = d.dx * d.dx + d.dy * d.dy;
    if (len2 < 1e-9) return a;
    var t = ((p - a).dx * d.dx + (p - a).dy * d.dy) / len2;
    if (!infinite) t = t.clamp(0.0, 1.0);
    return a + d * t;
  }

  /// Polygon vertices for a polygon ruler.
  static List<Offset> polygonVertices(RulerData r) {
    final radius = (r.b - r.a).distance;
    final start = math.atan2(r.b.dy - r.a.dy, r.b.dx - r.a.dx);
    return [
      for (var i = 0; i < r.sides; i++)
        r.a +
            Offset(math.cos(start + 2 * math.pi * i / r.sides),
                    math.sin(start + 2 * math.pi * i / r.sides)) *
                radius,
    ];
  }

  /// Nearest point to [p] on the ruler's guide path, or null when the ruler
  /// is off or the point is farther than [RulerData.snapStrength].
  static Offset? snapToRuler(Offset p, RulerData r, {Offset? strokeStart}) {
    if (!r.active) return null;
    Offset? best;
    switch (r.kind) {
      case RulerKind.none:
        return null;
      case RulerKind.line:
        best = nearestOnLine(p, r.a, r.b);
      case RulerKind.circle:
        final rad = (r.b - r.a).distance;
        final v = p - r.a;
        if (v.distance < 1e-9 || rad < 1e-9) return null;
        best = r.a + v / v.distance * rad;
      case RulerKind.ellipse:
        final rx = (r.b.dx - r.a.dx).abs(), ry = (r.b.dy - r.a.dy).abs();
        if (rx < 1e-6 || ry < 1e-6) return null;
        final v = p - r.a;
        final k = math.sqrt(v.dx * v.dx / (rx * rx) + v.dy * v.dy / (ry * ry));
        if (k < 1e-9) return null;
        // Radial projection (not the exact nearest point; good enough for
        // assisting a hand-drawn stroke).
        best = r.a + v / k;
      case RulerKind.parallel:
        final dir = r.b - r.a;
        final len = dir.distance;
        if (len < 1e-9) return null;
        final n = Offset(-dir.dy, dir.dx) / len;
        final dist = (p - r.a).dx * n.dx + (p - r.a).dy * n.dy;
        final k = (dist / r.spacing).round();
        best = nearestOnLine(p, r.a + n * (k * r.spacing), r.b + n * (k * r.spacing));
      case RulerKind.polygon:
        final v = polygonVertices(r);
        double bd = double.infinity;
        for (var i = 0; i < v.length; i++) {
          final c = nearestOnLine(p, v[i], v[(i + 1) % v.length], infinite: false);
          final d = (c - p).distance;
          if (d < bd) {
            bd = d;
            best = c;
          }
        }
      case RulerKind.perspective:
        // Lines radiate from the vanishing point [a]; when a stroke has a
        // start, lock to the ray through the VP and the start point.
        final anchor = strokeStart ?? p;
        final dir = anchor - r.a;
        if (dir.distance < 1e-6) return null;
        best = nearestOnLine(p, r.a, anchor);
    }
    if (best == null) return null;
    return (best - p).distance <= r.snapStrength ? best : null;
  }

  /// Converts one input point through all active aids, in a fixed order:
  /// ruler first, then guides, then grid.
  static Offset constrain(Offset p, AssistData a, {Offset? strokeStart}) {
    var q = p;
    final r = snapToRuler(q, a.ruler, strokeStart: strokeStart);
    if (r != null) return r;
    if (a.snapToGuides && a.guides.isNotEmpty) {
      q = snapGuides(q, a.guides, 12);
    }
    if (a.snapToGrid && a.grid != GridKind.none) {
      q = snapGrid(q, a.grid, a.gridSize, a.gridSize / 2);
    }
    return q;
  }

  /// Affine maps (as 2x3 [a,b,c,d,tx,ty] where x' = a*x + c*y + tx) that, applied
  /// to a stroke, produce the additional symmetric copies. The identity copy is
  /// not included.
  static List<List<double>> symmetryTransforms(
      AssistData a, Size canvas) {
    final c = a.symmetryCenter ?? Offset(canvas.width / 2, canvas.height / 2);
    List<double> reflectX() => [-1, 0, 0, 1, 2 * c.dx, 0];
    List<double> reflectY() => [1, 0, 0, -1, 0, 2 * c.dy];
    List<double> rot(double ang, {bool mirror = false}) {
      final co = math.cos(ang), si = math.sin(ang);
      final m = mirror ? -1.0 : 1.0;
      // p' = R*(M*(p-c)) + c, with M = diag(m,1)
      final a0 = co * m, b0 = si * m, c0 = -si, d0 = co;
      return [
        a0, b0, c0, d0,
        c.dx - (a0 * c.dx + c0 * c.dy),
        c.dy - (b0 * c.dx + d0 * c.dy),
      ];
    }

    final n = a.symmetryAxes;
    switch (a.symmetry) {
      case SymmetryKind.none:
        return const [];
      case SymmetryKind.vertical:
        return [reflectX()];
      case SymmetryKind.horizontal:
        return [reflectY()];
      case SymmetryKind.both:
        return [reflectX(), reflectY(), rot(math.pi)];
      case SymmetryKind.radial:
        return [for (var i = 1; i < n; i++) rot(2 * math.pi * i / n)];
      case SymmetryKind.mirror:
      case SymmetryKind.kaleidoscope:
        return [
          for (var i = 0; i < n; i++) ...[
            if (i > 0) rot(2 * math.pi * i / n),
            rot(2 * math.pi * i / n, mirror: true),
          ]
        ];
    }
  }

  static Offset applyTransform(List<double> m, Offset p) =>
      Offset(m[0] * p.dx + m[2] * p.dy + m[4], m[1] * p.dx + m[3] * p.dy + m[5]);

  /// Whether a transform flips handedness (affects directional brush tips).
  static bool flips(List<double> m) => m[0] * m[3] - m[1] * m[2] < 0;

  /// Converts the ruler into polyline points so the user can *explicitly*
  /// turn it into artwork. Rulers are never baked in implicitly.
  static List<Offset> rulerAsPoints(RulerData r, {int segments = 96}) {
    switch (r.kind) {
      case RulerKind.none:
        return const [];
      case RulerKind.line:
      case RulerKind.parallel:
        return [r.a, r.b];
      case RulerKind.perspective:
        return [r.a, r.b];
      case RulerKind.circle:
        final rad = (r.b - r.a).distance;
        return [
          for (var i = 0; i <= segments; i++)
            r.a + Offset(math.cos(2 * math.pi * i / segments), math.sin(2 * math.pi * i / segments)) * rad
        ];
      case RulerKind.ellipse:
        final rx = (r.b.dx - r.a.dx).abs(), ry = (r.b.dy - r.a.dy).abs();
        return [
          for (var i = 0; i <= segments; i++)
            r.a + Offset(math.cos(2 * math.pi * i / segments) * rx, math.sin(2 * math.pi * i / segments) * ry)
        ];
      case RulerKind.polygon:
        final v = polygonVertices(r);
        return [...v, v.first];
    }
  }
}
