import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import '../../../core/diagnostics/app_log.dart';
import '../domain/brush_preset.dart';

int _clampInt(int value, int min, int max) =>
    value < min ? min : (value > max ? max : value);

/// Lazily built GPU images used by brushes: the soft round tip, the speckle
/// tip and the paper grain tiles. Everything is procedural, nothing is loaded
/// from files. Creation failures are logged and the renderer falls back to
/// plain vector drawing, so a brush never crashes the canvas.
abstract final class BrushResources {
  /// Off under `flutter test` (image creation needs a real raster thread);
  /// brushes then use plain vector drawing.
  static bool imagesEnabled = !Platform.environment.containsKey('FLUTTER_TEST');

  static final Map<String, ui.Image> _tips = {};
  static final Map<String, ui.ImageShader> _grains = {};
  static final Map<String, ui.Image> _grainImages = {};

  static const int tipSize = 64;
  static const int grainSize = 128;

  /// Soft round tip: alpha 1 until [hardness], fading to 0 at the edge.
  static ui.Image? softTip(double hardness) {
    if (!imagesEnabled) return null;
    final bucket = _clampInt((hardness * 10).round(), 0, 9);
    return _tip('soft$bucket', (canvas, size) {
      final radius = size / 2;
      final edge = math.min(bucket / 10, 0.95);
      final paint = Paint()
        ..shader = ui.Gradient.radial(
          Offset(radius, radius),
          radius,
          const [Color(0xFFFFFFFF), Color(0xFFFFFFFF), Color(0x00FFFFFF)],
          <double>[0, edge, 1],
        );
      canvas.drawCircle(Offset(radius, radius), radius, paint);
    });
  }

  /// Rough speckled tip for charcoal-like brushes.
  static ui.Image? speckleTip() {
    if (!imagesEnabled) return null;
    return _tip('speckle', (canvas, size) {
      final random = math.Random(7);
      final center = size / 2;
      final paint = Paint()..isAntiAlias = true;
      for (var i = 0; i < 220; i++) {
        final angle = random.nextDouble() * 2 * math.pi;
        final distance = math.sqrt(random.nextDouble()) * (center - 3);
        paint.color = Color.fromRGBO(255, 255, 255, 0.35 + random.nextDouble() * 0.65);
        canvas.drawCircle(
          Offset(center + math.cos(angle) * distance, center + math.sin(angle) * distance),
          0.7 + random.nextDouble() * 2.2,
          paint,
        );
      }
    });
  }

  static ui.Image? _tip(String key, void Function(Canvas, double) draw) {
    final cached = _tips[key];
    if (cached != null) return cached;
    try {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      draw(canvas, tipSize.toDouble());
      final picture = recorder.endRecording();
      final image = picture.toImageSync(tipSize, tipSize);
      picture.dispose();
      _tips[key] = image;
      return image;
    } catch (error, stack) {
      AppLog.error('Brush tip creation failed', error: error, stackTrace: stack);
      imagesEnabled = false;
      return null;
    }
  }

  /// A repeating alpha-mask tile. Drawn with `BlendMode.dstIn` it multiplies
  /// the stroke by the grain, so the paper texture stays fixed to the canvas.
  static ui.ImageShader? grainShader(GrainKind kind, double strength) {
    if (!imagesEnabled || kind == GrainKind.none) return null;
    final bucket = math.max(1, (strength * 4).round());
    final key = '${kind.name}$bucket';
    final cached = _grains[key];
    if (cached != null) return cached;
    try {
      final image = _grainImage(kind, bucket / 4);
      final shader = ui.ImageShader(
        image,
        TileMode.repeated,
        TileMode.repeated,
        Float64List.fromList(const <double>[
          1, 0, 0, 0, //
          0, 1, 0, 0, //
          0, 0, 1, 0, //
          0, 0, 0, 1, //
        ]),
        filterQuality: FilterQuality.low,
      );
      _grainImages[key] = image;
      _grains[key] = shader;
      return shader;
    } catch (error, stack) {
      AppLog.error('Grain creation failed', error: error, stackTrace: stack);
      imagesEnabled = false;
      return null;
    }
  }

  static ui.Image _grainImage(GrainKind kind, double strength) {
    final random = math.Random(kind.index * 31 + 5);
    const levels = 6;
    final buckets = List.generate(levels, (_) => <double>[]);
    final step = kind == GrainKind.coarse ? 2 : 1;
    for (var y = 0; y < grainSize; y += step) {
      for (var x = 0; x < grainSize; x += step) {
        final double keep;
        if (kind == GrainKind.weave) {
          final wave = 0.5 + 0.5 * math.sin(x * 0.7) * math.sin(y * 0.7);
          keep = 1 - strength * (1 - wave) * (0.7 + 0.3 * random.nextDouble());
        } else {
          keep = 1 - strength * random.nextDouble();
        }
        final level = _clampInt((keep * (levels - 1)).round(), 0, levels - 1);
        buckets[level].addAll([x + step / 2, y + step / 2]);
      }
    }
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    for (var level = 0; level < levels; level++) {
      if (buckets[level].isEmpty) continue;
      final paint = Paint()
        ..isAntiAlias = false
        ..strokeWidth = step.toDouble()
        ..strokeCap = StrokeCap.butt
        ..color = Color.fromRGBO(0, 0, 0, level / (levels - 1));
      canvas.drawRawPoints(
        ui.PointMode.points,
        Float32List.fromList(buckets[level]),
        paint,
      );
    }
    final picture = recorder.endRecording();
    final image = picture.toImageSync(grainSize, grainSize);
    picture.dispose();
    return image;
  }
}
