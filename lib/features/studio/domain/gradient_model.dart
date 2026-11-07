import 'dart:math' as math;
import 'dart:ui' as ui;

import 'color_math.dart';

enum GradientKind {
  linear('Linear'),
  radial('Radial');

  const GradientKind(this.label);
  final String label;
}

/// How colours blend between stops. `linear` is a straight blend in RGB,
/// `smooth` eases in and out of each stop, `steps` holds each colour until
/// the next stop (hard bands).
enum GradientInterpolation {
  linear('Linear'),
  smooth('Smooth'),
  steps('Hard steps');

  const GradientInterpolation(this.label);
  final String label;
}

class GradientException implements Exception {
  const GradientException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// One colour stop: position 0..1, opaque RGB, and its own opacity.
class GradientStop {
  const GradientStop(this.position, this.argb, [this.opacity = 1]);

  final double position;
  final int argb;
  final double opacity;

  GradientStop copyWith({double? position, int? argb, double? opacity}) =>
      GradientStop(position ?? this.position, argb ?? this.argb, opacity ?? this.opacity);

  /// Straight (non-premultiplied) ARGB with the stop opacity applied.
  int get effectiveArgb => ((opacity * 255).round().clamp(0, 255) << 24) | (argb & 0xFFFFFF);

  @override
  bool operator ==(Object other) =>
      other is GradientStop && other.position == position && other.argb == argb && other.opacity == opacity;

  @override
  int get hashCode => Object.hash(position, argb, opacity);
}

/// Editable gradient data. Linear and radial gradients are supported;
/// angular, reflected and diamond gradients are NOT implemented (deferred) and
/// are never offered or faked.
class GradientData {
  GradientData({
    this.kind = GradientKind.linear,
    required List<GradientStop> stops,
    this.interpolation = GradientInterpolation.linear,
    this.angleDegrees = 0,
    this.centerX = 0.5,
    this.centerY = 0.5,
    this.radius = 0.5,
  }) : stops = List.unmodifiable(_sorted(stops)) {
    if (this.stops.length < 2) throw const GradientException('A gradient needs at least two stops.');
    if (this.stops.length > maxStops) throw const GradientException('A gradient can have at most $maxStops stops.');
    for (final s in this.stops) {
      if (!s.position.isFinite || s.position < 0 || s.position > 1) {
        throw const GradientException('Stop positions must be between 0 and 1.');
      }
      if (!s.opacity.isFinite || s.opacity < 0 || s.opacity > 1) {
        throw const GradientException('Stop opacity must be between 0 and 1.');
      }
    }
    if (!angleDegrees.isFinite || !centerX.isFinite || !centerY.isFinite || !radius.isFinite) {
      throw const GradientException('Gradient geometry must be finite.');
    }
    if (radius <= 0 || radius > 4) throw const GradientException('Radius must be between 0 and 4.');
  }

  static const int maxStops = 16;

  final GradientKind kind;
  final List<GradientStop> stops;
  final GradientInterpolation interpolation;

  /// Direction of a linear gradient (0° = left → right, 90° = top → bottom).
  final double angleDegrees;

  /// Radial centre as a fraction of the filled bounds, and radius as a
  /// fraction of half the larger side.
  final double centerX;
  final double centerY;
  final double radius;

  static List<GradientStop> _sorted(List<GradientStop> input) =>
      List.of(input)..sort((a, b) => a.position.compareTo(b.position));

  GradientData copyWith({
    GradientKind? kind,
    List<GradientStop>? stops,
    GradientInterpolation? interpolation,
    double? angleDegrees,
    double? centerX,
    double? centerY,
    double? radius,
  }) =>
      GradientData(
        kind: kind ?? this.kind,
        stops: stops ?? this.stops,
        interpolation: interpolation ?? this.interpolation,
        angleDegrees: angleDegrees ?? this.angleDegrees,
        centerX: centerX ?? this.centerX,
        centerY: centerY ?? this.centerY,
        radius: radius ?? this.radius,
      );

  /// ARGB at position [t] (0..1) following the interpolation mode.
  int colorAt(double t) {
    final x = t.clamp(0.0, 1.0).toDouble();
    if (x <= stops.first.position) return stops.first.effectiveArgb;
    if (x >= stops.last.position) return stops.last.effectiveArgb;
    for (var i = 0; i < stops.length - 1; i++) {
      final a = stops[i], b = stops[i + 1];
      if (x >= a.position && x <= b.position) {
        if (interpolation == GradientInterpolation.steps) return a.effectiveArgb;
        var f = b.position == a.position ? 0.0 : (x - a.position) / (b.position - a.position);
        if (interpolation == GradientInterpolation.smooth) f = f * f * (3 - 2 * f);
        return _mix(a, b, f);
      }
    }
    return stops.last.effectiveArgb;
  }

  static int _mix(GradientStop a, GradientStop b, double f) {
    int ch(int shift, int ca, int cb) => (ca + (cb - ca) * f).round().clamp(0, 255);
    final aa = (a.opacity * 255), ab = (b.opacity * 255);
    final alpha = (aa + (ab - aa) * f).round().clamp(0, 255);
    return (alpha << 24) |
        (ch(16, ColorMath.red(a.argb), ColorMath.red(b.argb)) << 16) |
        (ch(8, ColorMath.green(a.argb), ColorMath.green(b.argb)) << 8) |
        ch(0, ColorMath.blue(a.argb), ColorMath.blue(b.argb));
  }

  /// Dense (colours, stops) lists for the engine gradient, which only knows
  /// linear interpolation: smooth and stepped modes are expanded into
  /// additional stops.
  (List<int>, List<double>) expanded() {
    final colors = <int>[];
    final positions = <double>[];
    void add(double p, int c) {
      colors.add(c);
      positions.add(p);
    }

    for (var i = 0; i < stops.length; i++) {
      final s = stops[i];
      if (interpolation == GradientInterpolation.steps && i > 0) {
        add(s.position, stops[i - 1].effectiveArgb);
      }
      add(s.position, s.effectiveArgb);
      if (interpolation == GradientInterpolation.smooth && i < stops.length - 1) {
        final n = stops[i + 1];
        for (var k = 1; k < 8; k++) {
          final p = s.position + (n.position - s.position) * k / 8;
          add(p, colorAt(p));
        }
      }
    }
    if (positions.first > 0) {
      colors.insert(0, colors.first);
      positions.insert(0, 0);
    }
    if (positions.last < 1) {
      colors.add(colors.last);
      positions.add(1);
    }
    return (colors, positions);
  }

  /// Engine shader covering [bounds].
  ui.Gradient toShader(ui.Rect bounds) {
    final (argbs, positions) = expanded();
    final colors = [for (final c in argbs) ui.Color(c)];
    if (kind == GradientKind.radial) {
      final center = ui.Offset(bounds.left + bounds.width * centerX, bounds.top + bounds.height * centerY);
      final r = math.max(1.0, math.max(bounds.width, bounds.height) / 2 * radius);
      return ui.Gradient.radial(center, r, colors, positions);
    }
    final a = angleDegrees * math.pi / 180;
    final dir = ui.Offset(math.cos(a), math.sin(a));
    // Project the box onto the direction so the gradient spans it exactly.
    final half = (bounds.width * dir.dx).abs() / 2 + (bounds.height * dir.dy).abs() / 2;
    final c = bounds.center;
    return ui.Gradient.linear(c - dir * half, c + dir * half, colors, positions);
  }

  Map<String, Object?> toJson() => {
        'kind': kind.name,
        'interp': interpolation.name,
        'angle': angleDegrees,
        'cx': centerX,
        'cy': centerY,
        'r': radius,
        'stops': [
          for (final s in stops) [s.position, ColorMath.toHex(s.argb), s.opacity],
        ],
      };

  static GradientData fromJson(Object? raw) {
    if (raw is! Map) throw const GradientException('A gradient must be an object.');
    final kind = GradientKind.values.where((k) => k.name == raw['kind']).firstOrNull;
    final interp = GradientInterpolation.values.where((k) => k.name == (raw['interp'] ?? 'linear')).firstOrNull;
    if (kind == null) throw GradientException('Unsupported gradient type "${raw['kind']}".');
    if (interp == null) throw GradientException('Unsupported interpolation "${raw['interp']}".');
    final rawStops = raw['stops'];
    if (rawStops is! List) throw const GradientException('A gradient needs stops.');
    double num0(Object? v, double fallback) => v == null ? fallback : (v is num ? v.toDouble() : double.nan);
    return GradientData(
      kind: kind,
      interpolation: interp,
      angleDegrees: num0(raw['angle'], 0),
      centerX: num0(raw['cx'], .5),
      centerY: num0(raw['cy'], .5),
      radius: num0(raw['r'], .5),
      stops: [
        for (final s in rawStops)
          if (s is List && s.length >= 2 && s[0] is num && s[1] is String)
            GradientStop(
              (s[0] as num).toDouble(),
              ColorMath.parseHex(s[1] as String) ?? (throw const GradientException('Invalid stop colour.')),
              s.length > 2 && s[2] is num ? (s[2] as num).toDouble() : 1,
            )
          else
            throw const GradientException('Invalid gradient stop.'),
      ],
    );
  }

  @override
  bool operator ==(Object other) =>
      other is GradientData &&
      other.kind == kind &&
      other.interpolation == interpolation &&
      other.angleDegrees == angleDegrees &&
      other.centerX == centerX &&
      other.centerY == centerY &&
      other.radius == radius &&
      _listEq(other.stops, stops);

  static bool _listEq(List<GradientStop> a, List<GradientStop> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(kind, interpolation, angleDegrees, centerX, centerY, radius, Object.hashAll(stops));
}

class GradientPreset {
  const GradientPreset(this.name, this.gradient);
  final String name;
  final GradientData gradient;
}

abstract final class GradientPresets {
  static GradientData _lin(List<int> colors, {double angle = 0}) => GradientData(
        angleDegrees: angle,
        stops: [
          for (var i = 0; i < colors.length; i++) GradientStop(i / (colors.length - 1), colors[i]),
        ],
      );

  static final List<GradientPreset> all = [
    GradientPreset('Black to white', _lin([0xFF000000, 0xFFFFFFFF])),
    GradientPreset('Sunset', _lin([0xFF2B1055, 0xFFD53369, 0xFFFFA751], angle: 90)),
    GradientPreset('Ocean', _lin([0xFF0F2027, 0xFF2C7A9B, 0xFF9EE7E0], angle: 90)),
    GradientPreset('Fire', _lin([0xFF200000, 0xFFE53900, 0xFFFFD200, 0xFFFFFFFF])),
    GradientPreset('Rainbow', _lin([0xFFE53935, 0xFFFDD835, 0xFF43A047, 0xFF1E88E5, 0xFF8E24AA])),
    GradientPreset('Pastel', _lin([0xFFFFB3BA, 0xFFFFDFBA, 0xFFBAE1FF], angle: 45)),
    GradientPreset('Steel', _lin([0xFF232526, 0xFF6C7A89, 0xFFE0E6EB], angle: 90)),
    GradientPreset(
      'Glow (radial)',
      GradientData(
        kind: GradientKind.radial,
        stops: const [GradientStop(0, 0xFFFFFFFF), GradientStop(1, 0xFF1E88E5, 0)],
      ),
    ),
  ];
}
