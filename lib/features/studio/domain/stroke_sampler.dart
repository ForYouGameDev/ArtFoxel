import 'dart:math' as math;

import 'package:flutter/painting.dart';

import 'brush_preset.dart';
import 'stroke_model.dart';

/// One stamp of the brush tip, fully resolved (dynamics already applied).
class Dab {
  const Dab({
    required this.x,
    required this.y,
    required this.size,
    required this.alpha,
    required this.angle,
    required this.colorArgb,
  });

  final double x;
  final double y;
  final double size;
  final double alpha;
  final double angle;
  final int colorArgb;
}

double _clamp(double value, double min, double max) =>
    value < min ? min : (value > max ? max : value);

double _lerp(double a, double b, double t) => a + (b - a) * t;

/// Turns a stroke's input samples into dabs. Pure and deterministic: the same
/// stroke and brush always produce the same dabs (randomness is seeded).
///
/// Pressure, tilt and speed dynamics only react to data that exists. Pressure
/// falls back to speed (when `simulatePressure` is set) or to a constant for
/// finger-only input; tilt is ignored when the device does not report it.
abstract final class StrokeSampler {
  static const int maxDabs = 12000;

  /// Conservative area covered by a stroke, for layer bounds and caching.
  static Rect bounds(SketchStroke stroke, BrushPreset brush) {
    var minX = double.infinity;
    var minY = double.infinity;
    var maxX = -double.infinity;
    var maxY = -double.infinity;
    for (final point in stroke.points) {
      minX = math.min(minX, point.x);
      minY = math.min(minY, point.y);
      maxX = math.max(maxX, point.x);
      maxY = math.max(maxY, point.y);
    }
    final inflate = stroke.size * (2.2 + brush.scatter) + 4;
    return Rect.fromLTRB(minX, minY, maxX, maxY).inflate(inflate);
  }

  static List<Dab> dabs(SketchStroke stroke, BrushPreset brush) {
    final points = stroke.points;
    if (points.isEmpty) return const <Dab>[];
    final count = points.length;
    final random = math.Random(stroke.seed);
    final baseColor = HSLColor.fromColor(Color(stroke.colorArgb));
    final opacityScale = (brush.buildup || brush.erase) ? stroke.opacity : 1.0;
    final baseSize = stroke.size;

    final cumulative = List<double>.filled(count, 0);
    final speed = List<double>.filled(count, 0);
    for (var i = 1; i < count; i++) {
      final dx = points[i].x - points[i - 1].x;
      final dy = points[i].y - points[i - 1].y;
      final distance = math.sqrt(dx * dx + dy * dy);
      cumulative[i] = cumulative[i - 1] + distance;
      final dt = math.max(1, points[i].t - points[i - 1].t);
      speed[i] = distance / dt;
    }
    if (count > 1) speed[0] = speed[1];

    final hasPressure = points.any((point) => point.pressure != null);
    final pressure = List<double>.filled(count, 1);
    var simulated = 0.6;
    for (var i = 0; i < count; i++) {
      if (hasPressure) {
        final previous = i > 0 ? pressure[i - 1] : 1.0;
        pressure[i] = _clamp(points[i].pressure ?? previous, 0, 1);
      } else if (brush.simulatePressure) {
        final target = _clamp(1.15 - speed[i] / 1.8, 0.2, 1);
        simulated += (target - simulated) * 0.3;
        pressure[i] = simulated;
      }
    }

    final total = cumulative.last;
    final angleBase = brush.angle * math.pi / 180;

    Dab at(int segment, double t, double distance) {
      final a = points[segment];
      final b = points[math.min(segment + 1, count - 1)];
      final next = math.min(segment + 1, count - 1);
      var x = _lerp(a.x, b.x, t);
      var y = _lerp(a.y, b.y, t);
      final p = _lerp(pressure[segment], pressure[next], t);
      final v = _lerp(speed[segment], speed[next], t);
      double? tilt;
      if (a.tilt != null && b.tilt != null) {
        tilt = _lerp(a.tilt!, b.tilt!, t);
      } else {
        tilt = a.tilt ?? b.tilt;
      }
      final heading = math.atan2(b.y - a.y, b.x - a.x);

      var sizeMul = 1.0;
      var opacityMul = 1.0;
      if (brush.pressureSize > 0) {
        final shaped = math.pow(p, brush.pressureSizeCurve).toDouble();
        sizeMul *= _lerp(
          1,
          _lerp(brush.minSizeRatio, 1, shaped),
          brush.pressureSize,
        );
      }
      if (brush.pressureOpacity > 0) {
        final shaped = math.pow(p, brush.pressureOpacityCurve).toDouble();
        opacityMul *= _lerp(1, shaped, brush.pressureOpacity);
      }
      if (tilt != null && brush.tiltSize > 0) {
        sizeMul *= 1 + brush.tiltSize * _clamp(tilt / (math.pi / 2), 0, 1) * 1.5;
      }
      if (brush.speedSize != 0) {
        sizeMul *= _clamp(
          1 + brush.speedSize * _clamp(v / 2, 0, 1) * 0.5,
          0.2,
          2,
        );
      }
      final taperStart = brush.taperStart * baseSize;
      if (taperStart > 0 && distance < taperStart) {
        sizeMul *= _lerp(0.12, 1, distance / taperStart);
      }
      final taperEnd = brush.taperEnd * baseSize;
      if (taperEnd > 0 && total - distance < taperEnd) {
        sizeMul *= _lerp(0.12, 1, (total - distance) / taperEnd);
      }
      if (brush.fadeLength > 0) {
        opacityMul *= 1 - _clamp(distance / brush.fadeLength, 0, 1);
      }
      if (brush.sizeJitter > 0) {
        sizeMul *= 1 - brush.sizeJitter * random.nextDouble();
      }
      if (brush.opacityJitter > 0) {
        opacityMul *= 1 - brush.opacityJitter * random.nextDouble();
      }
      var angle = (brush.followDirection ? heading : 0.0) + angleBase;
      if (brush.angleJitter > 0) {
        angle += (random.nextDouble() * 2 - 1) * math.pi * brush.angleJitter;
      }
      if (brush.scatter > 0) {
        final radius = brush.scatter * baseSize * random.nextDouble();
        final direction = random.nextDouble() * 2 * math.pi;
        x += math.cos(direction) * radius;
        y += math.sin(direction) * radius;
      }
      var color = stroke.colorArgb;
      if (brush.hueJitter > 0) {
        final shift = (random.nextDouble() * 2 - 1) * 180 * brush.hueJitter;
        final hue = ((baseColor.hue + shift) % 360 + 360) % 360;
        color = baseColor.withHue(hue).toColor().toARGB32();
      }
      return Dab(
        x: x,
        y: y,
        size: math.max(0.3, baseSize * sizeMul),
        alpha: _clamp(stroke.flow * opacityMul * opacityScale, 0, 1),
        angle: angle,
        colorArgb: color,
      );
    }

    if (count == 1 || total <= 0) return [at(0, 0, 0)];

    var step = math.max(0.5, brush.spacing * baseSize);
    if (total / step > maxDabs) step = total / maxDabs;
    final steps = (total / step).floor();
    final result = <Dab>[];
    var segment = 0;
    for (var i = 0; i <= steps; i++) {
      final distance = math.min(i * step, total);
      while (segment < count - 2 && cumulative[segment + 1] < distance) {
        segment++;
      }
      final length = cumulative[segment + 1] - cumulative[segment];
      final t = length > 0 ? (distance - cumulative[segment]) / length : 0.0;
      result.add(at(segment, _clamp(t, 0, 1), distance));
    }
    if (total - steps * step > step * 0.35) {
      result.add(at(count - 2, 1, total));
    }
    return result;
  }
}
