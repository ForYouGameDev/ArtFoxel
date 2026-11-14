double _round(double value, int digits) =>
    double.parse(value.toStringAsFixed(digits));

/// One captured sample of a stroke, in document coordinates.
class StrokePoint {
  const StrokePoint({
    required this.x,
    required this.y,
    required this.t,
    this.pressure,
    this.tilt,
  });

  final double x;
  final double y;

  /// Milliseconds since the stroke started.
  final int t;

  /// Null when the input device did not report pressure.
  final double? pressure;

  /// Null when the input device did not report tilt (radians, 0..pi/2).
  final double? tilt;

  List<Object?> toJson() {
    final list = <Object?>[_round(x, 2), _round(y, 2), t];
    if (pressure != null || tilt != null) {
      list.add(pressure == null ? null : _round(pressure!, 3));
      if (tilt != null) list.add(_round(tilt!, 3));
    }
    return list;
  }

  factory StrokePoint.fromJson(Object? raw) {
    if (raw is! List || raw.length < 3 || raw.length > 5) {
      throw const FormatException('Invalid stroke point.');
    }
    double number(Object? value) {
      if (value is num && value.isFinite && value.abs() <= 1000000) {
        return value.toDouble();
      }
      throw const FormatException('Invalid stroke point value.');
    }

    double? optional(Object? value) => value == null ? null : number(value);

    final t = raw[2];
    if (t is! num || !t.isFinite || t < 0) {
      throw const FormatException('Invalid stroke point time.');
    }
    return StrokePoint(
      x: number(raw[0]),
      y: number(raw[1]),
      t: t.round(),
      pressure: raw.length > 3 ? optional(raw[3]) : null,
      tilt: raw.length > 4 ? optional(raw[4]) : null,
    );
  }
}

/// A committed (or in-progress) brush stroke. Strokes are the editable source
/// of truth; the raster image is only a cache that can always be rebuilt.
class SketchStroke {
  SketchStroke({
    required this.brushKey,
    required this.colorArgb,
    required this.size,
    required this.opacity,
    required this.flow,
    required this.seed,
    required this.points,
    this.alphaLock = false,
  });

  static const int maxPoints = 20000;

  /// Key into the document's brush table (a snapshot of the preset used).
  final String brushKey;
  final int colorArgb;

  /// Brush diameter in document pixels.
  final double size;
  final double opacity;
  final double flow;

  /// Seeds all brush randomness so replaying a stroke is deterministic.
  final int seed;
  final List<StrokePoint> points;

  /// Painted with "lock transparency": the stroke only affects pixels that
  /// already have coverage on its layer.
  final bool alphaLock;

  /// A copy with new geometry or size (used by layer transforms).
  SketchStroke copyWith({double? size, List<StrokePoint>? points}) =>
      SketchStroke(
        brushKey: brushKey,
        colorArgb: colorArgb,
        size: size ?? this.size,
        opacity: opacity,
        flow: flow,
        seed: seed,
        points: points ?? this.points,
        alphaLock: alphaLock,
      );

  Map<String, Object?> toJson() => {
        'b': brushKey,
        'c': colorArgb,
        's': _round(size, 2),
        'o': _round(opacity, 3),
        'f': _round(flow, 3),
        'seed': seed,
        if (alphaLock) 'al': 1,
        'p': [for (final point in points) point.toJson()],
      };

  factory SketchStroke.fromJson(Map<String, dynamic> json) {
    final brush = json['b'];
    final color = json['c'];
    final seed = json['seed'];
    final points = json['p'];
    double ranged(String key, double min, double max) {
      final value = json[key];
      if (value is num && value.isFinite && value >= min && value <= max) {
        return value.toDouble();
      }
      throw FormatException('Invalid stroke "$key".');
    }

    if (brush is! String || brush.isEmpty || brush.length > 128) {
      throw const FormatException('Invalid stroke brush.');
    }
    if (color is! int || color < 0 || color > 0xFFFFFFFF) {
      throw const FormatException('Invalid stroke colour.');
    }
    if (seed is! int) throw const FormatException('Invalid stroke seed.');
    if (points is! List || points.isEmpty || points.length > maxPoints) {
      throw const FormatException('Invalid stroke points.');
    }
    return SketchStroke(
      brushKey: brush,
      colorArgb: color,
      size: ranged('s', 0.1, 2000),
      opacity: ranged('o', 0, 1),
      flow: ranged('f', 0, 1),
      seed: seed,
      points: [for (final p in points) StrokePoint.fromJson(p)],
      alphaLock: json['al'] == 1,
    );
  }
}
