import 'dart:math' as math;

import 'stroke_model.dart';

double _clamp(double value, double min, double max) =>
    value < min ? min : (value > max ? max : value);

class StabilizerConfig {
  const StabilizerConfig({
    this.strength = 0,
    this.lowLatency = false,
    this.preserveCorners = true,
    this.predict = false,
  });

  /// 0 = raw input, 1 = strongest smoothing.
  final double strength;

  /// Bypasses all smoothing and prediction for the lowest possible latency.
  final bool lowLatency;

  /// Keeps sharp direction changes instead of rounding them off.
  final bool preserveCorners;

  /// Draws a short, uncommitted prediction ahead of the pen tip.
  final bool predict;

  bool get smoothing => !lowLatency && strength > 0.001;
}

/// Online stroke smoothing. Each raw sample goes in, one stabilized sample
/// comes out, so strokes can be drawn while the pen is still moving.
///
/// Smoothing is an exponential filter whose weight adapts to speed (fast
/// strokes lag less) and which snaps to the raw input at sharp corners when
/// `preserveCorners` is on.
class StrokeStabilizer {
  StrokeStabilizer(this.config);

  final StabilizerConfig config;

  StrokePoint? _rawLast;
  StrokePoint? _rawPrev;
  StrokePoint? _smooth;
  StrokePoint? _smoothPrev;

  StrokePoint add(StrokePoint raw) {
    final smooth = _smooth;
    final last = _rawLast;
    if (!config.smoothing || smooth == null || last == null) {
      _rawPrev = _rawLast;
      _rawLast = raw;
      _smoothPrev = _smooth;
      _smooth = raw;
      return raw;
    }

    final dx = raw.x - last.x;
    final dy = raw.y - last.y;
    final distance = math.sqrt(dx * dx + dy * dy);
    final dt = math.max(1, raw.t - last.t);
    final speed = distance / dt;

    var weight = 1 - config.strength * 0.92;
    weight += (1 - weight) * _clamp(speed / 2.5, 0, 1) * 0.6;

    final previous = _rawPrev;
    if (config.preserveCorners && previous != null && distance > 2) {
      final px = last.x - previous.x;
      final py = last.y - previous.y;
      final previousLength = math.sqrt(px * px + py * py);
      if (previousLength > 2) {
        final cosine = (px * dx + py * dy) / (previousLength * distance);
        if (cosine < 0.42) weight = 1; // turn sharper than ~65 degrees
      }
    }

    final next = StrokePoint(
      x: smooth.x + (raw.x - smooth.x) * weight,
      y: smooth.y + (raw.y - smooth.y) * weight,
      t: raw.t,
      pressure: raw.pressure,
      tilt: raw.tilt,
    );
    _rawPrev = _rawLast;
    _rawLast = raw;
    _smoothPrev = _smooth;
    _smooth = next;
    return next;
  }

  /// Points to append when the pen lifts so the stroke ends exactly where
  /// the pen did instead of lagging behind it.
  List<StrokePoint> finish(StrokePoint rawLast) {
    final smooth = _smooth;
    if (!config.smoothing || smooth == null) return const [];
    final dx = rawLast.x - smooth.x;
    final dy = rawLast.y - smooth.y;
    if (dx * dx + dy * dy < 0.25) return const [];
    return [
      StrokePoint(
        x: smooth.x + dx * 0.5,
        y: smooth.y + dy * 0.5,
        t: math.max(smooth.t, rawLast.t - 1),
        pressure: rawLast.pressure,
        tilt: rawLast.tilt,
      ),
      rawLast,
    ];
  }

  /// A short extrapolation beyond the pen tip for live display only. It is
  /// never stored in the stroke.
  StrokePoint? predicted() {
    final smooth = _smooth;
    final previous = _smoothPrev;
    if (!config.predict || config.lowLatency || smooth == null || previous == null) {
      return null;
    }
    var dx = smooth.x - previous.x;
    var dy = smooth.y - previous.y;
    final length = math.sqrt(dx * dx + dy * dy);
    if (length < 0.01) return null;
    if (length > 24) {
      dx = dx / length * 24;
      dy = dy / length * 24;
    }
    return StrokePoint(
      x: smooth.x + dx,
      y: smooth.y + dy,
      t: smooth.t + 8,
      pressure: smooth.pressure,
      tilt: smooth.tilt,
    );
  }
}
