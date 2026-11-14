import 'dart:math' as math;

/// Phase 7.5.1 — input pipeline. Pure Dart, no Flutter dependency.

class PenSample {
  const PenSample(this.x, this.y, {this.pressure = 1, this.tMs = 0});
  final double x, y, pressure;
  final double tMs;
  PenSample copyWith({double? x, double? y, double? pressure}) => PenSample(
      x ?? this.x, y ?? this.y,
      pressure: pressure ?? this.pressure, tMs: tMs);
}

enum StabilizerMode { off, realtime, constant, speedDependent, fastStroke }

class StabilizerSettings {
  const StabilizerSettings({
    this.mode = StabilizerMode.off,
    this.strength = 0.5,
    this.window = 6,
    this.lazyRadius = 0,
    this.postSmoothing = 0,
    this.prediction = false,
    this.preserveCornersDeg = 50,
    this.taperStart = 0,
    this.taperEnd = 0,
  });
  final StabilizerMode mode;
  final double strength; // 0..1
  final int window; // constant-mode window
  final double lazyRadius; // px, 0 = off
  final double postSmoothing; // 0..1, applied after the stroke
  final bool prediction;
  final double preserveCornersDeg; // turn angle above which a corner is kept
  final double taperStart, taperEnd; // px of arc length

  StabilizerSettings copyWith({
    StabilizerMode? mode,
    double? strength,
    int? window,
    double? lazyRadius,
    double? postSmoothing,
    bool? prediction,
    double? preserveCornersDeg,
    double? taperStart,
    double? taperEnd,
  }) =>
      StabilizerSettings(
        mode: mode ?? this.mode,
        strength: (strength ?? this.strength).clamp(0.0, 1.0),
        window: (window ?? this.window).clamp(1, 64),
        lazyRadius: math.max(0, lazyRadius ?? this.lazyRadius),
        postSmoothing: (postSmoothing ?? this.postSmoothing).clamp(0.0, 1.0),
        prediction: prediction ?? this.prediction,
        preserveCornersDeg: preserveCornersDeg ?? this.preserveCornersDeg,
        taperStart: math.max(0, taperStart ?? this.taperStart),
        taperEnd: math.max(0, taperEnd ?? this.taperEnd),
      );

  Map<String, Object?> toJson() => {
        'mode': mode.name,
        'strength': strength,
        'window': window,
        'lazy': lazyRadius,
        'post': postSmoothing,
        'predict': prediction,
        'corner': preserveCornersDeg,
        'tapS': taperStart,
        'tapE': taperEnd,
      };

  factory StabilizerSettings.fromJson(Map<String, Object?> j) {
    final mode = StabilizerMode.values.firstWhere(
        (m) => m.name == j['mode'],
        orElse: () => StabilizerMode.off);
    double d(String k, double f) => (j[k] is num) ? (j[k] as num).toDouble() : f;
    return const StabilizerSettings().copyWith(
      mode: mode,
      strength: d('strength', 0.5),
      window: d('window', 6).round(),
      lazyRadius: d('lazy', 0),
      postSmoothing: d('post', 0),
      prediction: j['predict'] == true,
      preserveCornersDeg: d('corner', 50),
      taperStart: d('tapS', 0),
      taperEnd: d('tapE', 0),
    );
  }
}

double turnAngleDeg(PenSample a, PenSample b, PenSample c) {
  final v1x = b.x - a.x, v1y = b.y - a.y;
  final v2x = c.x - b.x, v2y = c.y - b.y;
  final l1 = math.sqrt(v1x * v1x + v1y * v1y);
  final l2 = math.sqrt(v2x * v2x + v2y * v2y);
  if (l1 < 1e-9 || l2 < 1e-9) return 0;
  final cos = ((v1x * v2x + v1y * v2y) / (l1 * l2)).clamp(-1.0, 1.0);
  return math.acos(cos) * 180 / math.pi;
}

/// Online stabilizer: one raw sample in, one stabilised sample out.
class LiveStabilizer {
  LiveStabilizer(this.settings);
  final StabilizerSettings settings;
  final List<PenSample> _raw = [];
  PenSample? _out;
  PenSample? _lazy;

  void reset() {
    _raw.clear();
    _out = null;
    _lazy = null;
  }

  PenSample add(PenSample s) {
    _raw.add(s);
    if (_raw.length > 128) _raw.removeAt(0);
    var p = s;
    if (settings.lazyRadius > 0) p = _lazyStep(p);
    p = _smooth(p);
    _out = p;
    return p;
  }

  /// Lazy guide: the pen tip only moves when the pointer leaves the radius,
  /// and is then pulled so the pointer stays exactly [lazyRadius] away.
  PenSample _lazyStep(PenSample p) {
    final cur = _lazy;
    if (cur == null) return _lazy = p;
    final dx = p.x - cur.x, dy = p.y - cur.y;
    final d = math.sqrt(dx * dx + dy * dy);
    if (d <= settings.lazyRadius) {
      return _lazy = cur.copyWith(pressure: p.pressure);
    }
    final k = (d - settings.lazyRadius) / d;
    return _lazy = PenSample(cur.x + dx * k, cur.y + dy * k,
        pressure: p.pressure, tMs: p.tMs);
  }

  PenSample _smooth(PenSample p) {
    final prev = _out;
    if (settings.mode == StabilizerMode.off || prev == null) return p;

    // Corner preservation: keep sharp turns crisp.
    if (_raw.length >= 3 && settings.preserveCornersDeg < 180) {
      final a = _raw[_raw.length - 3], b = _raw[_raw.length - 2];
      if (turnAngleDeg(a, b, p) >= settings.preserveCornersDeg) return p;
    }
    final dt = math.max(1.0, p.tMs - prev.tMs);
    final dx = p.x - prev.x, dy = p.y - prev.y;
    final speed = math.sqrt(dx * dx + dy * dy) / dt; // px/ms
    double alpha; // weight of the NEW sample (1 = raw)
    switch (settings.mode) {
      case StabilizerMode.off:
        alpha = 1;
      case StabilizerMode.realtime:
        alpha = 1 - settings.strength * 0.9;
      case StabilizerMode.constant:
        final n = math.min(settings.window, _raw.length);
        var sx = 0.0, sy = 0.0, sp = 0.0;
        for (var i = _raw.length - n; i < _raw.length; i++) {
          sx += _raw[i].x;
          sy += _raw[i].y;
          sp += _raw[i].pressure;
        }
        return PenSample(sx / n, sy / n,
            pressure: sp / n, tMs: p.tMs);
      case StabilizerMode.speedDependent:
        // slow = heavy smoothing, fast = light.
        final f = (speed / 2.0).clamp(0.0, 1.0);
        alpha = (1 - settings.strength * 0.9) + f * settings.strength * 0.9;
      case StabilizerMode.fastStroke:
        // Smooth only fast strokes (flicks), keep slow detail raw.
        final f = (speed / 2.0).clamp(0.0, 1.0);
        alpha = 1 - settings.strength * 0.9 * f;
    }
    alpha = alpha.clamp(0.05, 1.0);
    return PenSample(prev.x + dx * alpha, prev.y + dy * alpha,
        pressure: prev.pressure + (p.pressure - prev.pressure) * alpha,
        tMs: p.tMs);
  }

  /// Short uncommitted look-ahead. Never mutates stroke data; returns null
  /// when prediction is off or there is too little history. Length is capped
  /// so a wrong guess is only a few pixels.
  PenSample? predict({double maxPx = 6, double horizonMs = 16}) {
    if (!settings.prediction || _raw.length < 3) return null;
    final a = _raw[_raw.length - 2], b = _raw.last;
    final dt = b.tMs - a.tMs;
    if (dt <= 0) return null;
    var vx = (b.x - a.x) / dt, vy = (b.y - a.y) / dt;
    var dx = vx * horizonMs, dy = vy * horizonMs;
    final len = math.sqrt(dx * dx + dy * dy);
    if (len < 0.01) return null;
    if (len > maxPx) {
      dx *= maxPx / len;
      dy *= maxPx / len;
    }
    // Don't predict through a corner.
    if (_raw.length >= 3 &&
        turnAngleDeg(_raw[_raw.length - 3], a, b) >= settings.preserveCornersDeg) {
      return null;
    }
    return PenSample(b.x + dx, b.y + dy, pressure: b.pressure, tMs: b.tMs + horizonMs);
  }
}

/// Post-stroke smoothing (Chaikin-like relaxation) keeping endpoints and
/// corners above [cornerDeg].
List<PenSample> smoothStroke(List<PenSample> pts,
    {double amount = 0.5, int passes = 2, double cornerDeg = 50}) {
  if (pts.length < 3 || amount <= 0) return List.of(pts);
  var cur = List<PenSample>.of(pts);
  for (var pass = 0; pass < passes; pass++) {
    final next = <PenSample>[cur.first];
    for (var i = 1; i < cur.length - 1; i++) {
      final a = cur[i - 1], b = cur[i], c = cur[i + 1];
      if (turnAngleDeg(a, b, c) >= cornerDeg) {
        next.add(b);
        continue;
      }
      final mx = (a.x + c.x) / 2, my = (a.y + c.y) / 2;
      next.add(PenSample(b.x + (mx - b.x) * amount, b.y + (my - b.y) * amount,
          pressure: b.pressure + ((a.pressure + c.pressure) / 2 - b.pressure) * amount,
          tMs: b.tMs));
    }
    next.add(cur.last);
    cur = next;
  }
  return cur;
}

/// Multiplies pressure by a start/end taper over arc length.
List<PenSample> applyTaper(List<PenSample> pts,
    {double startPx = 0, double endPx = 0}) {
  if (pts.length < 2 || (startPx <= 0 && endPx <= 0)) return List.of(pts);
  final cum = <double>[0];
  for (var i = 1; i < pts.length; i++) {
    final dx = pts[i].x - pts[i - 1].x, dy = pts[i].y - pts[i - 1].y;
    cum.add(cum.last + math.sqrt(dx * dx + dy * dy));
  }
  final total = cum.last;
  return [
    for (var i = 0; i < pts.length; i++)
      pts[i].copyWith(
          pressure: pts[i].pressure *
              (startPx > 0 ? (cum[i] / startPx).clamp(0.0, 1.0) : 1.0) *
              (endPx > 0 ? ((total - cum[i]) / endPx).clamp(0.0, 1.0) : 1.0)),
  ];
}

enum InputDevice { finger, stylus, mouse }

class DeviceCapabilities {
  const DeviceCapabilities({
    this.pressure = false,
    this.tilt = false,
    this.orientation = false,
    this.barrelButton = false,
    this.eraserEnd = false,
    this.palmRejection = false,
  });
  final bool pressure, tilt, orientation, barrelButton, eraserEnd, palmRejection;
}

/// Per-device mapping. Pressure curve is a gamma; unsupported inputs are
/// reported by [warnings] instead of silently doing nothing.
class InputMapping {
  const InputMapping({
    this.device = InputDevice.stylus,
    this.pressureGamma = 1.0,
    this.minPressure = 0.0,
    this.usePressure = true,
    this.useTilt = false,
    this.barrelAction = 'none',
    this.eraserEndErases = true,
    this.rejectFingerWhileStylus = true,
  });
  final InputDevice device;
  final double pressureGamma, minPressure;
  final bool usePressure, useTilt, eraserEndErases, rejectFingerWhileStylus;
  final String barrelAction; // none | eraser | picker | undo

  double mapPressure(double raw, DeviceCapabilities caps) {
    if (!usePressure || !caps.pressure) return 1;
    final g = math.pow(raw.clamp(0.0, 1.0), pressureGamma).toDouble();
    return minPressure + (1 - minPressure) * g;
  }

  List<String> warnings(DeviceCapabilities caps) => [
        if (usePressure && !caps.pressure) 'Pressure not reported by this device',
        if (useTilt && !caps.tilt) 'Tilt not reported by this device',
        if (barrelAction != 'none' && !caps.barrelButton)
          'No barrel button available',
        if (eraserEndErases && !caps.eraserEnd) 'No eraser end available',
      ];

  /// Palm rejection: ignore touch while a stylus is active, and ignore very
  /// large touch contacts. Only applies if the platform reports it.
  bool acceptTouch({required bool stylusActive, double contactRadius = 0}) {
    if (!rejectFingerWhileStylus) return true;
    if (stylusActive) return false;
    return contactRadius < 30;
  }
}

/// Measures input→render latency from timestamps supplied by the caller
/// (event time vs frame-presented time). Keeps a rolling window.
class LatencyMeter {
  LatencyMeter({this.window = 120});
  final int window;
  final List<double> _ms = [];

  void record(double eventMs, double presentedMs) {
    final d = presentedMs - eventMs;
    if (d < 0 || d > 5000) return; // discard clock glitches
    _ms.add(d);
    if (_ms.length > window) _ms.removeAt(0);
  }

  int get count => _ms.length;
  double get mean => _ms.isEmpty ? 0 : _ms.reduce((a, b) => a + b) / _ms.length;
  double get p95 {
    if (_ms.isEmpty) return 0;
    final s = List<double>.of(_ms)..sort();
    return s[((s.length - 1) * 0.95).round()];
  }

  /// Settings to use when latency is a priority: no smoothing/lazy/post,
  /// keep only the clamped prediction.
  static StabilizerSettings lowLatency(StabilizerSettings s) => s.copyWith(
      mode: StabilizerMode.off, lazyRadius: 0, postSmoothing: 0, prediction: true);
}

/// Per-brush stabiliser defaults.
class BrushInputDefaults {
  final Map<String, StabilizerSettings> _byBrush = {};
  StabilizerSettings forBrush(String id) =>
      _byBrush[id] ?? const StabilizerSettings();
  void set(String id, StabilizerSettings s) => _byBrush[id] = s;
  Map<String, Object?> toJson() =>
      {for (final e in _byBrush.entries) e.key: e.value.toJson()};
  static BrushInputDefaults fromJson(Map<String, Object?> j) {
    final r = BrushInputDefaults();
    for (final e in j.entries) {
      if (e.value is Map) {
        r._byBrush[e.key] =
            StabilizerSettings.fromJson(Map<String, Object?>.from(e.value as Map));
      }
    }
    return r;
  }
}
