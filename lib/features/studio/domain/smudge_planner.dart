import 'dart:math' as math;

import 'brush_preset.dart';
import 'stroke_model.dart';
import 'stroke_sampler.dart';

/// One pixel-moving step: copy the circle around ([sx],[sy]) onto the circle
/// around ([x],[y]). Coordinates are document pixels.
class SmudgeOp {
  const SmudgeOp({
    required this.x,
    required this.y,
    required this.sx,
    required this.sy,
    required this.radius,
    required this.strength,
    required this.softness,
    this.deposit = 0,
    this.depositColor = 0,
  });

  final double x;
  final double y;
  final double sx;
  final double sy;
  final double radius;

  /// 0..1: how much of the destination is replaced by the source patch.
  final double strength;

  /// 0 = hard circle edge, 1 = fully feathered.
  final double softness;

  /// 0..1 alpha of brush colour laid on top of the moved pixels.
  final double deposit;
  final int depositColor;
}

class _Spec {
  const _Spec({
    this.radiusMul = 1,
    this.lag = 0.8,
    this.softness = 0.4,
    this.strength = 1,
    this.lanes = 1,
    this.trail = false,
    this.jitter = 0,
    this.fixedDirection = false,
    this.neighbours = false,
    this.minPickup = 0,
  });

  final double radiusMul;

  /// Distance (in radii) the paint is dragged behind the brush.
  final double lag;
  final double softness;
  final double strength;
  final int lanes;
  final bool trail;
  final double jitter;
  final bool fixedDirection;
  final bool neighbours;
  final double minPickup;
}

const Map<SmudgeMode, _Spec> _specs = {
  SmudgeMode.basic: _Spec(lag: 0.8, softness: 0.35),
  SmudgeMode.soft: _Spec(radiusMul: 1.15, lag: 0.7, softness: 0.95, strength: 0.8),
  SmudgeMode.hard: _Spec(lag: 0.9, softness: 0),
  SmudgeMode.finger: _Spec(radiusMul: 0.8, lag: 1.7, softness: 0.5),
  SmudgeMode.wet: _Spec(radiusMul: 1.1, lag: 1.3, softness: 0.85, strength: 0.85, trail: true),
  SmudgeMode.oil: _Spec(lag: 1.1, softness: 0.15, strength: 0.9, lanes: 3),
  SmudgeMode.colorMixing: _Spec(lag: 0.9, softness: 0.6, minPickup: 0.5),
  SmudgeMode.texture: _Spec(lag: 0.9, softness: 0.1, lanes: 2, jitter: 0.5),
  SmudgeMode.directional: _Spec(lag: 1.4, softness: 0.3, fixedDirection: true),
  SmudgeMode.blend: _Spec(lag: 0, softness: 0.8, strength: 0.7, neighbours: true),
};

/// Turns a smudge stroke into pixel-moving operations. Pure and deterministic
/// (seeded), so replaying a stroke after undo gives the identical result.
///
/// Every mode changes *geometry*: where pixels are picked up, how many
/// parallel lanes drag, how far they travel, whether the direction is locked
/// or the neighbourhood is averaged. None of them is a blur.
abstract final class SmudgePlanner {
  static const int maxOps = 1400;

  static List<SmudgeOp> plan(SketchStroke stroke, BrushPreset brush) {
    final dabs = StrokeSampler.dabs(stroke, brush);
    if (dabs.length < 2) return const <SmudgeOp>[];
    final spec = _specs[brush.smudgeMode] ?? _specs[SmudgeMode.basic]!;
    final random = math.Random(stroke.seed ^ 0x5bd1e995);
    final n = dabs.length;

    final cumulative = List<double>.filled(n, 0);
    for (var i = 1; i < n; i++) {
      cumulative[i] = cumulative[i - 1] +
          math.sqrt(math.pow(dabs[i].x - dabs[i - 1].x, 2) +
              math.pow(dabs[i].y - dabs[i - 1].y, 2));
    }

    // Locked direction: where the first few dabs head.
    final probe = math.min(n - 1, 5);
    var fdx = dabs[probe].x - dabs[0].x;
    var fdy = dabs[probe].y - dabs[0].y;
    var fl = math.sqrt(fdx * fdx + fdy * fdy);
    if (fl < 1e-6) {
      fdx = 1;
      fdy = 0;
      fl = 1;
    }
    fdx /= fl;
    fdy /= fl;

    final pickup = math.max(brush.pickup, spec.minPickup);
    final stride = math.max(1, (n * spec.lanes / maxOps).ceil());
    final boost = math.min(1.6, 1 + (stride - 1) * 0.12);
    final ops = <SmudgeOp>[];

    for (var i = 1; i < n; i += stride) {
      final d = dabs[i];
      final back = dabs[math.max(0, i - 3)];
      var hx = d.x - back.x;
      var hy = d.y - back.y;
      final hl = math.sqrt(hx * hx + hy * hy);
      if (hl < 1e-6) continue;
      hx /= hl;
      hy /= hl;
      if (spec.fixedDirection) {
        hx = fdx;
        hy = fdy;
      }
      final px = -hy; // perpendicular
      final py = hx;
      final radius = math.max(0.75, d.size / 2 * spec.radiusMul);
      final strength = (brush.smudgeStrength * spec.strength * d.alpha * boost)
          .clamp(0.0, 1.0)
          .toDouble();
      if (strength <= 0.005) continue;

      // Source point: along the path `lag` behind, or straight behind the
      // locked direction.
      final wet = 0.5 + 1.5 * brush.wetness;
      final lagDist = math.min(spec.lag * radius * wet, cumulative[i]);
      double sx;
      double sy;
      if (spec.fixedDirection) {
        sx = d.x - hx * spec.lag * radius * wet;
        sy = d.y - hy * spec.lag * radius * wet;
      } else {
        final p = _pointAt(dabs, cumulative, cumulative[i] - lagDist);
        sx = p.$1;
        sy = p.$2;
      }
      if (pickup > 0) {
        // Carry colour from where the stroke began; fades with distance.
        final carry = pickup * math.exp(-cumulative[i] / (radius * 14));
        sx += (dabs[0].x - sx) * carry;
        sy += (dabs[0].y - sy) * carry;
      }
      final deposit = brush.deposit * d.alpha;

      if (spec.neighbours) {
        // Average with both sides of the stroke instead of dragging.
        for (final side in const [-1.0, 1.0]) {
          ops.add(SmudgeOp(
            x: d.x,
            y: d.y,
            sx: d.x + px * side * radius * 0.7,
            sy: d.y + py * side * radius * 0.7,
            radius: radius,
            strength: strength * 0.5,
            softness: spec.softness,
            deposit: side < 0 ? deposit : 0,
            depositColor: stroke.colorArgb,
          ));
        }
        continue;
      }

      final lanes = spec.lanes;
      for (var lane = 0; lane < lanes; lane++) {
        final offset = lanes == 1 ? 0.0 : (lane - (lanes - 1) / 2) * radius * 0.62;
        var jx = 0.0;
        var jy = 0.0;
        if (spec.jitter > 0) {
          jx = (random.nextDouble() - 0.5) * 2 * spec.jitter * radius;
          jy = (random.nextDouble() - 0.5) * 2 * spec.jitter * radius;
        }
        final laneRadius = lanes == 1 ? radius : radius * 0.62;
        final laneStrength = lanes == 1
            ? strength
            : (strength * (0.75 + 0.25 * random.nextDouble())).clamp(0.0, 1.0).toDouble();
        ops.add(SmudgeOp(
          x: d.x + px * offset,
          y: d.y + py * offset,
          sx: sx + px * offset + jx,
          sy: sy + py * offset + jy,
          radius: laneRadius,
          strength: laneStrength,
          softness: spec.softness,
          deposit: lane == 0 ? deposit : 0,
          depositColor: stroke.colorArgb,
        ));
      }
      if (spec.trail) {
        // Wet paint leaves a faint, wider film dragged further back.
        final p = _pointAt(dabs, cumulative, math.max(0, cumulative[i] - lagDist * 2));
        ops.add(SmudgeOp(
          x: d.x,
          y: d.y,
          sx: p.$1,
          sy: p.$2,
          radius: radius * 1.25,
          strength: strength * 0.35,
          softness: 1,
        ));
      }
    }
    return ops;
  }

  /// Bounds of everything a stroke touches (for tests and clipping).
  static (double, double, double, double) bounds(List<SmudgeOp> ops) {
    var l = double.infinity, t = double.infinity;
    var r = -double.infinity, b = -double.infinity;
    for (final o in ops) {
      l = math.min(l, math.min(o.x, o.sx) - o.radius);
      t = math.min(t, math.min(o.y, o.sy) - o.radius);
      r = math.max(r, math.max(o.x, o.sx) + o.radius);
      b = math.max(b, math.max(o.y, o.sy) + o.radius);
    }
    return (l, t, r, b);
  }

  static (double, double) _pointAt(List<Dab> dabs, List<double> cum, double s) {
    if (s <= 0) return (dabs.first.x, dabs.first.y);
    var lo = 0;
    var hi = cum.length - 1;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (cum[mid] < s) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    if (lo == 0) return (dabs.first.x, dabs.first.y);
    final span = cum[lo] - cum[lo - 1];
    final t = span <= 1e-9 ? 0.0 : (s - cum[lo - 1]) / span;
    return (
      dabs[lo - 1].x + (dabs[lo].x - dabs[lo - 1].x) * t,
      dabs[lo - 1].y + (dabs[lo].y - dabs[lo - 1].y) * t,
    );
  }
}
