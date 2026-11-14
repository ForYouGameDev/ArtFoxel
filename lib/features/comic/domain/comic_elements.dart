import 'dart:math' as math;
import 'dart:ui';

import 'text_model.dart';

class ComicException implements Exception {
  const ComicException(this.message);
  final String message;
  @override
  String toString() => message;
}

double _d(Object? v, double f, double lo, double hi) =>
    v is num && v.isFinite ? v.toDouble().clamp(lo, hi).toDouble() : f;

Offset _pt(Object? v, [Offset f = Offset.zero]) {
  if (v is List && v.length == 2 && v[0] is num && v[1] is num) {
    final x = (v[0] as num).toDouble(), y = (v[1] as num).toDouble();
    if (x.isFinite && y.isFinite) return Offset(x, y);
  }
  return f;
}

Rect _rect(Object? v, Rect f) {
  if (v is List && v.length == 4 && v.every((e) => e is num && e.isFinite)) {
    final n = [for (final e in v) (e as num).toDouble()];
    if (n[2] > 0 && n[3] > 0) return Rect.fromLTWH(n[0], n[1], n[2], n[3]);
  }
  return f;
}

List<double> _r(Rect r) => [r.left, r.top, r.width, r.height];

/// Base of everything placed on a comic page above the panels. Every element
/// can be clipped to one panel ([panelId]) and is edited through its
/// parameters, never flattened.
abstract class ComicElement {
  const ComicElement({required this.id, this.panelId, this.opacity = 1, this.hidden = false});
  final String id;
  final String? panelId;
  final double opacity;
  final bool hidden;

  String get kind;
  Rect get bounds;
  ComicElement copyBase({String? id, Object? panelId, double? opacity, bool? hidden});
  Map<String, Object?> toJson();

  Map<String, Object?> base() => {
        'id': id,
        'kind': kind,
        if (panelId != null) 'panel': panelId,
        if (opacity != 1) 'o': opacity,
        if (hidden) 'hid': true,
      };

  static const Object keep = Object();

  static ComicElement fromJson(Object? j) {
    if (j is! Map || j['id'] is! String || j['kind'] is! String) {
      throw const ComicException('Invalid page element.');
    }
    return switch (j['kind']) {
      'tone' => ScreentoneElement.fromJson(j),
      'lines' => SpeedLinesElement.fromJson(j),
      'bubble' => BubbleElement.fromJson(j),
      'text' => TextBoxElement.fromJson(j),
      final k => throw ComicException('Unknown element kind "$k".'),
    };
  }
}

// ---------------------------------------------------------------------------
// Screentones
// ---------------------------------------------------------------------------

enum TonePattern { dots, lines, crosshatch, checker, gradientDots }

extension TonePatternLabel on TonePattern {
  String get label => switch (this) {
        TonePattern.dots => 'Dots',
        TonePattern.lines => 'Lines (hatching)',
        TonePattern.crosshatch => 'Cross-hatch',
        TonePattern.checker => 'Checker',
        TonePattern.gradientDots => 'Gradient dots',
      };
}

/// A tone laid over [area]. [density] is 0..1 ink coverage; [spacing] is the
/// pitch between dots/lines in page pixels. Rendered as vectors at any
/// resolution, so preview and export are identical.
class ScreentoneElement extends ComicElement {
  const ScreentoneElement({
    required super.id,
    required this.area,
    super.panelId,
    super.opacity,
    super.hidden,
    this.pattern = TonePattern.dots,
    this.spacing = 14,
    this.density = 0.35,
    this.angleDegrees = 45,
    this.colorArgb = 0xFF000000,
    this.gradientAngle = 90,
  });

  static const minSpacing = 3.0;
  static const maxMarks = 250000;

  final Rect area;
  final TonePattern pattern;
  final double spacing;
  final double density;
  final double angleDegrees;
  final int colorArgb;
  final double gradientAngle;

  @override
  String get kind => 'tone';
  @override
  Rect get bounds => area;

  ScreentoneElement copyWith({
    Rect? area,
    TonePattern? pattern,
    double? spacing,
    double? density,
    double? angleDegrees,
    int? colorArgb,
    double? gradientAngle,
    double? opacity,
  }) =>
      ScreentoneElement(
        id: id,
        area: area ?? this.area,
        panelId: panelId,
        opacity: opacity ?? this.opacity,
        hidden: hidden,
        pattern: pattern ?? this.pattern,
        spacing: spacing ?? this.spacing,
        density: density ?? this.density,
        angleDegrees: angleDegrees ?? this.angleDegrees,
        colorArgb: colorArgb ?? this.colorArgb,
        gradientAngle: gradientAngle ?? this.gradientAngle,
      );

  @override
  ComicElement copyBase({String? id, Object? panelId = ComicElement.keep, double? opacity, bool? hidden}) =>
      ScreentoneElement(
        id: id ?? this.id,
        area: area,
        panelId: identical(panelId, ComicElement.keep) ? this.panelId : panelId as String?,
        opacity: opacity ?? this.opacity,
        hidden: hidden ?? this.hidden,
        pattern: pattern,
        spacing: spacing,
        density: density,
        angleDegrees: angleDegrees,
        colorArgb: colorArgb,
        gradientAngle: gradientAngle,
      );

  /// Number of marks that would be drawn (used to refuse runaway settings).
  int estimatedMarks() {
    final diag = math.sqrt(area.width * area.width + area.height * area.height);
    final n = diag / spacing;
    return (pattern == TonePattern.lines ? n : n * n).ceil();
  }

  /// Builds the tone as a vector path clipped by the caller to [area].
  Path buildPath() {
    final path = Path();
    final sp = math.max(minSpacing, spacing);
    if (estimatedMarks() > maxMarks) return path;
    final c = area.center;
    final diag = math.sqrt(area.width * area.width + area.height * area.height);
    final half = diag / 2 + sp;
    final a = angleDegrees * math.pi / 180;
    final ux = Offset(math.cos(a), math.sin(a));
    final uy = Offset(-math.sin(a), math.cos(a));
    final cov = density.clamp(0.0, 1.0);
    switch (pattern) {
      case TonePattern.dots:
      case TonePattern.gradientDots:
        final gradDir = Offset(math.cos(gradientAngle * math.pi / 180), math.sin(gradientAngle * math.pi / 180));
        final rows = (half / sp).ceil();
        for (var i = -rows; i <= rows; i++) {
          for (var j = -rows; j <= rows; j++) {
            // Offset every second row so dots form a staggered screen.
            final p = c + ux * ((j + (i.isOdd ? 0.5 : 0)) * sp) + uy * (i * sp);
            if (!area.inflate(sp).contains(p)) continue;
            var k = cov;
            if (pattern == TonePattern.gradientDots) {
              final t = ((p - area.topLeft).dx * gradDir.dx + (p - area.topLeft).dy * gradDir.dy) /
                  (area.width * gradDir.dx.abs() + area.height * gradDir.dy.abs() + 1e-9);
              k = cov * t.clamp(0.0, 1.0);
            }
            // Dot area fraction = cov: pi r^2 = cov * sp^2 (staggered cell).
            final r = math.sqrt(k * sp * sp / math.pi);
            if (r > 0.2) path.addOval(Rect.fromCircle(center: p, radius: r));
          }
        }
      case TonePattern.lines:
        _lines(path, c, ux, uy, half, sp, cov);
      case TonePattern.crosshatch:
        _lines(path, c, ux, uy, half, sp, cov);
        _lines(path, c, uy, ux, half, sp, cov);
      case TonePattern.checker:
        final n = (half / sp).ceil();
        for (var i = -n; i <= n; i++) {
          for (var j = -n; j <= n; j++) {
            if ((i + j).isOdd) continue;
            final p = c + ux * (j * sp) + uy * (i * sp);
            if (!area.inflate(sp).contains(p)) continue;
            final s = sp * math.sqrt(cov.clamp(0.0, 1.0) * 2);
            path.addPolygon([
              p + ux * (-s / 2) + uy * (-s / 2),
              p + ux * (s / 2) + uy * (-s / 2),
              p + ux * (s / 2) + uy * (s / 2),
              p + ux * (-s / 2) + uy * (s / 2),
            ], true);
          }
        }
    }
    return path;
  }

  void _lines(Path path, Offset c, Offset ux, Offset uy, double half, double sp, double cov) {
    final w = sp * cov;
    if (w < 0.2) return;
    final n = (half / sp).ceil();
    for (var i = -n; i <= n; i++) {
      final o = c + uy * (i * sp);
      path.addPolygon([o - ux * half + uy * (-w / 2), o + ux * half + uy * (-w / 2), o + ux * half + uy * (w / 2), o - ux * half + uy * (w / 2)], true);
    }
  }

  @override
  Map<String, Object?> toJson() => {
        ...base(),
        'area': _r(area),
        'pat': pattern.name,
        'sp': spacing,
        'den': density,
        'ang': angleDegrees,
        'col': colorArgb,
        'gang': gradientAngle,
      };

  factory ScreentoneElement.fromJson(Map j) {
    final pat = TonePattern.values.where((p) => p.name == j['pat']);
    return ScreentoneElement(
      id: j['id'] as String,
      area: _rect(j['area'], const Rect.fromLTWH(0, 0, 100, 100)),
      panelId: j['panel'] as String?,
      opacity: _d(j['o'], 1, 0, 1),
      hidden: j['hid'] == true,
      pattern: pat.isEmpty ? TonePattern.dots : pat.first,
      spacing: _d(j['sp'], 14, ScreentoneElement.minSpacing, 200),
      density: _d(j['den'], 0.35, 0, 1),
      angleDegrees: _d(j['ang'], 45, -360, 360),
      colorArgb: j['col'] is int ? j['col'] as int : 0xFF000000,
      gradientAngle: _d(j['gang'], 90, -360, 360),
    );
  }
}

// ---------------------------------------------------------------------------
// Speed / focus lines
// ---------------------------------------------------------------------------

enum SpeedLineMode { focus, parallel }

class SpeedLinesElement extends ComicElement {
  const SpeedLinesElement({
    required super.id,
    required this.area,
    super.panelId,
    super.opacity,
    super.hidden,
    this.mode = SpeedLineMode.focus,
    this.center,
    this.count = 90,
    this.innerRadius = 0.25,
    this.maxWidth = 6,
    this.lengthJitter = 0.3,
    this.angleDegrees = 0,
    this.seed = 1,
    this.colorArgb = 0xFF000000,
  });

  final Rect area;
  final SpeedLineMode mode;

  /// Focus point (page coordinates); defaults to the area centre.
  final Offset? center;
  final int count;

  /// Radius of the empty centre, as a fraction of the area's half-diagonal.
  final double innerRadius;
  final double maxWidth;
  final double lengthJitter;
  final double angleDegrees;
  final int seed;
  final int colorArgb;

  @override
  String get kind => 'lines';
  @override
  Rect get bounds => area;

  SpeedLinesElement copyWith({
    Rect? area,
    SpeedLineMode? mode,
    Object? center = ComicElement.keep,
    int? count,
    double? innerRadius,
    double? maxWidth,
    double? lengthJitter,
    double? angleDegrees,
    int? seed,
    int? colorArgb,
  }) =>
      SpeedLinesElement(
        id: id,
        area: area ?? this.area,
        panelId: panelId,
        opacity: opacity,
        hidden: hidden,
        mode: mode ?? this.mode,
        center: identical(center, ComicElement.keep) ? this.center : center as Offset?,
        count: count ?? this.count,
        innerRadius: innerRadius ?? this.innerRadius,
        maxWidth: maxWidth ?? this.maxWidth,
        lengthJitter: lengthJitter ?? this.lengthJitter,
        angleDegrees: angleDegrees ?? this.angleDegrees,
        seed: seed ?? this.seed,
        colorArgb: colorArgb ?? this.colorArgb,
      );

  @override
  ComicElement copyBase({String? id, Object? panelId = ComicElement.keep, double? opacity, bool? hidden}) =>
      SpeedLinesElement(
        id: id ?? this.id,
        area: area,
        panelId: identical(panelId, ComicElement.keep) ? this.panelId : panelId as String?,
        opacity: opacity ?? this.opacity,
        hidden: hidden ?? this.hidden,
        mode: mode,
        center: center,
        count: count,
        innerRadius: innerRadius,
        maxWidth: maxWidth,
        lengthJitter: lengthJitter,
        angleDegrees: angleDegrees,
        seed: seed,
        colorArgb: colorArgb,
      );

  /// One filled spike per line (a thin triangle whose point faces outward /
  /// along the motion). Deterministic for a given [seed].
  Path buildPath() {
    final path = Path();
    final rnd = math.Random(seed);
    final c = center ?? area.center;
    final reach = math.sqrt(area.width * area.width + area.height * area.height);
    if (mode == SpeedLineMode.focus) {
      final inner = reach / 2 * innerRadius;
      for (var i = 0; i < count; i++) {
        final a = (i + rnd.nextDouble() * 0.8) / count * 2 * math.pi;
        final dir = Offset(math.cos(a), math.sin(a));
        final perp = Offset(-dir.dy, dir.dx);
        final start = inner * (1 + rnd.nextDouble() * lengthJitter);
        final w = maxWidth * (0.3 + 0.7 * rnd.nextDouble());
        path.addPolygon([c + dir * start + perp * (w / 2), c + dir * reach, c + dir * start - perp * (w / 2)], true);
      }
    } else {
      final a = angleDegrees * math.pi / 180;
      final dir = Offset(math.cos(a), math.sin(a));
      final perp = Offset(-dir.dy, dir.dx);
      final span = reach;
      for (var i = 0; i < count; i++) {
        final off = ((i + rnd.nextDouble() * 0.8) / count - 0.5) * span;
        final len = reach * (1 - lengthJitter * rnd.nextDouble());
        final w = maxWidth * (0.3 + 0.7 * rnd.nextDouble());
        final mid = area.center + perp * off;
        final tail = mid - dir * (len / 2);
        final head = mid + dir * (len / 2);
        path.addPolygon([tail + perp * (w / 2), head, tail - perp * (w / 2)], true);
      }
    }
    return path;
  }

  @override
  Map<String, Object?> toJson() => {
        ...base(),
        'area': _r(area),
        'mode': mode.name,
        if (center != null) 'ctr': [center!.dx, center!.dy],
        'n': count,
        'in': innerRadius,
        'w': maxWidth,
        'lj': lengthJitter,
        'ang': angleDegrees,
        'seed': seed,
        'col': colorArgb,
      };

  factory SpeedLinesElement.fromJson(Map j) {
    final m = SpeedLineMode.values.where((p) => p.name == j['mode']);
    return SpeedLinesElement(
      id: j['id'] as String,
      area: _rect(j['area'], const Rect.fromLTWH(0, 0, 100, 100)),
      panelId: j['panel'] as String?,
      opacity: _d(j['o'], 1, 0, 1),
      hidden: j['hid'] == true,
      mode: m.isEmpty ? SpeedLineMode.focus : m.first,
      center: j['ctr'] == null ? null : _pt(j['ctr']),
      count: _d(j['n'], 90, 4, 600).round(),
      innerRadius: _d(j['in'], 0.25, 0, 0.95),
      maxWidth: _d(j['w'], 6, 0.5, 60),
      lengthJitter: _d(j['lj'], 0.3, 0, 0.9),
      angleDegrees: _d(j['ang'], 0, -360, 360),
      seed: _d(j['seed'], 1, 0, 1e9).round(),
      colorArgb: j['col'] is int ? j['col'] as int : 0xFF000000,
    );
  }
}

// ---------------------------------------------------------------------------
// Speech bubbles & narration boxes
// ---------------------------------------------------------------------------

enum BubbleShape { oval, roundedRect, cloud, burst, whisper, narration }

extension BubbleShapeLabel on BubbleShape {
  String get label => switch (this) {
        BubbleShape.oval => 'Speech',
        BubbleShape.roundedRect => 'Rounded box',
        BubbleShape.cloud => 'Thought (cloud)',
        BubbleShape.burst => 'Shout (burst)',
        BubbleShape.whisper => 'Whisper (dashed)',
        BubbleShape.narration => 'Narration box',
      };
}

class BubbleElement extends ComicElement {
  const BubbleElement({
    required super.id,
    required this.rect,
    super.panelId,
    super.opacity,
    super.hidden,
    this.shape = BubbleShape.oval,
    this.tailTip,
    this.tailWidth = 36,
    this.fillArgb = 0xFFFFFFFF,
    this.strokeArgb = 0xFF000000,
    this.strokeWidth = 3,
    this.cornerRadius = 20,
    this.burstPoints = 12,
    this.text = const TextSpec(text: ''),
    this.padding = 14,
  });

  final Rect rect;
  final BubbleShape shape;

  /// Where the tail points; null = no tail (narration boxes never have one).
  final Offset? tailTip;
  final double tailWidth;
  final int fillArgb;
  final int? strokeArgb;
  final double strokeWidth;
  final double cornerRadius;
  final int burstPoints;
  final TextSpec text;
  final double padding;

  @override
  String get kind => 'bubble';
  @override
  Rect get bounds => tailTip == null ? rect : rect.expandToInclude(Rect.fromCircle(center: tailTip!, radius: 1));

  /// Area available to text (inset, and narrower for ovals so text stays inside).
  Rect get textRect {
    final inset = shape == BubbleShape.oval || shape == BubbleShape.whisper || shape == BubbleShape.cloud
        ? Offset(rect.width * 0.14, rect.height * 0.14)
        : shape == BubbleShape.burst
            ? Offset(rect.width * 0.2, rect.height * 0.2)
            : Offset.zero;
    return Rect.fromLTRB(rect.left + inset.dx + padding, rect.top + inset.dy + padding,
        rect.right - inset.dx - padding, rect.bottom - inset.dy - padding);
  }

  BubbleElement copyWith({
    Rect? rect,
    BubbleShape? shape,
    Object? tailTip = ComicElement.keep,
    double? tailWidth,
    int? fillArgb,
    Object? strokeArgb = ComicElement.keep,
    double? strokeWidth,
    double? cornerRadius,
    int? burstPoints,
    TextSpec? text,
    double? padding,
  }) =>
      BubbleElement(
        id: id,
        rect: rect ?? this.rect,
        panelId: panelId,
        opacity: opacity,
        hidden: hidden,
        shape: shape ?? this.shape,
        tailTip: identical(tailTip, ComicElement.keep) ? this.tailTip : tailTip as Offset?,
        tailWidth: tailWidth ?? this.tailWidth,
        fillArgb: fillArgb ?? this.fillArgb,
        strokeArgb: identical(strokeArgb, ComicElement.keep) ? this.strokeArgb : strokeArgb as int?,
        strokeWidth: strokeWidth ?? this.strokeWidth,
        cornerRadius: cornerRadius ?? this.cornerRadius,
        burstPoints: burstPoints ?? this.burstPoints,
        text: text ?? this.text,
        padding: padding ?? this.padding,
      );

  @override
  ComicElement copyBase({String? id, Object? panelId = ComicElement.keep, double? opacity, bool? hidden}) =>
      BubbleElement(
        id: id ?? this.id,
        rect: rect,
        panelId: identical(panelId, ComicElement.keep) ? this.panelId : panelId as String?,
        opacity: opacity ?? this.opacity,
        hidden: hidden ?? this.hidden,
        shape: shape,
        tailTip: tailTip,
        tailWidth: tailWidth,
        fillArgb: fillArgb,
        strokeArgb: strokeArgb,
        strokeWidth: strokeWidth,
        cornerRadius: cornerRadius,
        burstPoints: burstPoints,
        text: text,
        padding: padding,
      );

  Path _body() {
    switch (shape) {
      case BubbleShape.oval:
      case BubbleShape.whisper:
        return Path()..addOval(rect);
      case BubbleShape.roundedRect:
        return Path()..addRRect(RRect.fromRectAndRadius(rect, Radius.circular(cornerRadius)));
      case BubbleShape.narration:
        return Path()..addRect(rect);
      case BubbleShape.cloud:
        // A ring of overlapping circles around an inner oval.
        final path = Path()..addOval(rect.deflate(math.min(rect.width, rect.height) * 0.08));
        const n = 12;
        final rx = rect.width * 0.42, ry = rect.height * 0.42;
        final r = math.min(rect.width, rect.height) * 0.14;
        for (var i = 0; i < n; i++) {
          final a = i / n * 2 * math.pi;
          path.addOval(Rect.fromCircle(center: rect.center + Offset(math.cos(a) * rx, math.sin(a) * ry), radius: r));
        }
        return path;
      case BubbleShape.burst:
        final n = burstPoints.clamp(5, 40);
        final path = Path();
        for (var i = 0; i < n * 2; i++) {
          final a = i / (n * 2) * 2 * math.pi - math.pi / 2;
          final k = i.isEven ? 1.0 : 0.72;
          final p = rect.center + Offset(math.cos(a) * rect.width / 2 * k, math.sin(a) * rect.height / 2 * k);
          i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
        }
        return path..close();
    }
  }

  /// Body plus tail merged into one outline, so the tail has no seam.
  /// Thought bubbles get a trail of small circles instead of a pointed tail.
  Path buildPath() {
    final body = _body();
    final tip = tailTip;
    if (tip == null || shape == BubbleShape.narration) return body;
    if (shape == BubbleShape.cloud) {
      final out = Path()..addPath(body, Offset.zero);
      final from = rect.center;
      final dir = tip - from;
      if (dir.distance > 1) {
        for (var i = 1; i <= 3; i++) {
          final t = 0.45 + i * 0.18;
          final r = math.max(3.0, math.min(rect.width, rect.height) * 0.07 * (1 - i * 0.22));
          out.addOval(Rect.fromCircle(center: from + dir * t, radius: r));
        }
      }
      return out;
    }
    // Triangular tail from the body edge nearest the tip.
    final centre = rect.center;
    final dir = tip - centre;
    if (dir.distance < 1) return body;
    final unit = dir / dir.distance;
    final perp = Offset(-unit.dy, unit.dx);
    final base = centre + unit * (math.min(rect.width, rect.height) * 0.35);
    final tail = Path()
      ..moveTo(base.dx + perp.dx * tailWidth / 2, base.dy + perp.dy * tailWidth / 2)
      ..lineTo(tip.dx, tip.dy)
      ..lineTo(base.dx - perp.dx * tailWidth / 2, base.dy - perp.dy * tailWidth / 2)
      ..close();
    return Path.combine(PathOperation.union, body, tail);
  }

  bool get dashed => shape == BubbleShape.whisper;

  @override
  Map<String, Object?> toJson() => {
        ...base(),
        'rect': _r(rect),
        'shape': shape.name,
        if (tailTip != null) 'tail': [tailTip!.dx, tailTip!.dy],
        'tw': tailWidth,
        'fill': fillArgb,
        if (strokeArgb != null) 'stroke': strokeArgb,
        'sw': strokeWidth,
        'cr': cornerRadius,
        'bp': burstPoints,
        'text': text.toJson(),
        'pad': padding,
      };

  factory BubbleElement.fromJson(Map j) {
    final s = BubbleShape.values.where((p) => p.name == j['shape']);
    return BubbleElement(
      id: j['id'] as String,
      rect: _rect(j['rect'], const Rect.fromLTWH(0, 0, 200, 120)),
      panelId: j['panel'] as String?,
      opacity: _d(j['o'], 1, 0, 1),
      hidden: j['hid'] == true,
      shape: s.isEmpty ? BubbleShape.oval : s.first,
      tailTip: j['tail'] == null ? null : _pt(j['tail']),
      tailWidth: _d(j['tw'], 36, 4, 300),
      fillArgb: j['fill'] is int ? j['fill'] as int : 0xFFFFFFFF,
      strokeArgb: j['stroke'] is int ? j['stroke'] as int : null,
      strokeWidth: _d(j['sw'], 3, 0, 40),
      cornerRadius: _d(j['cr'], 20, 0, 400),
      burstPoints: _d(j['bp'], 12, 5, 40).round(),
      text: j['text'] == null ? const TextSpec() : TextSpec.fromJson(j['text']),
      padding: _d(j['pad'], 14, 0, 200),
    );
  }
}

/// Free text box (titles, sound effects, captions without a bubble).
class TextBoxElement extends ComicElement {
  const TextBoxElement({
    required super.id,
    required this.rect,
    required this.text,
    super.panelId,
    super.opacity,
    super.hidden,
    this.rotationDegrees = 0,
  });
  final Rect rect;
  final TextSpec text;
  final double rotationDegrees;

  @override
  String get kind => 'text';
  @override
  Rect get bounds => rect;

  TextBoxElement copyWith({Rect? rect, TextSpec? text, double? rotationDegrees}) => TextBoxElement(
        id: id,
        rect: rect ?? this.rect,
        text: text ?? this.text,
        panelId: panelId,
        opacity: opacity,
        hidden: hidden,
        rotationDegrees: rotationDegrees ?? this.rotationDegrees,
      );

  @override
  ComicElement copyBase({String? id, Object? panelId = ComicElement.keep, double? opacity, bool? hidden}) =>
      TextBoxElement(
        id: id ?? this.id,
        rect: rect,
        text: text,
        panelId: identical(panelId, ComicElement.keep) ? this.panelId : panelId as String?,
        opacity: opacity ?? this.opacity,
        hidden: hidden ?? this.hidden,
        rotationDegrees: rotationDegrees,
      );

  @override
  Map<String, Object?> toJson() => {...base(), 'rect': _r(rect), 'text': text.toJson(), if (rotationDegrees != 0) 'rot': rotationDegrees};

  factory TextBoxElement.fromJson(Map j) => TextBoxElement(
        id: j['id'] as String,
        rect: _rect(j['rect'], const Rect.fromLTWH(0, 0, 200, 80)),
        text: TextSpec.fromJson(j['text']),
        panelId: j['panel'] as String?,
        opacity: _d(j['o'], 1, 0, 1),
        hidden: j['hid'] == true,
        rotationDegrees: _d(j['rot'], 0, -360, 360),
      );
}
