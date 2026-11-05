import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import '../../../core/diagnostics/app_log.dart';
import '../domain/brush_preset.dart';
import '../domain/stroke_model.dart';
import 'brush_renderer.dart';

typedef BrushResolver = BrushPreset? Function(String key);

/// Caches committed strokes as one GPU image so the canvas does not replay
/// every stroke on each frame. The stroke list stays the source of truth: the
/// image is rebuilt from strokes on undo, using periodic checkpoints so undo
/// does not replay the whole history.
///
/// Limits (documented, not hidden): one full-canvas image (capped to
/// [maxRasterSide] pixels on the long side) rather than a tile grid. If image
/// creation fails the raster degrades to replaying strokes directly.
class SketchRaster {
  SketchRaster({
    required this.width,
    required this.height,
    required this.resolve,
  }) : scale = math.min(1.0, maxRasterSide / math.max(width, height));

  static const double maxRasterSide = 4096;
  static const int checkpointEvery = 10;
  static const int maxCheckpoints = 6;

  final int width;
  final int height;
  final double scale;
  final BrushResolver resolve;

  /// True once image creation failed; strokes are then replayed per frame.
  bool degraded = false;

  ui.Image? _base;
  final Map<int, ui.Image> _checkpoints = {};
  final Paint _imagePaint = Paint()..filterQuality = FilterQuality.medium;

  Rect get _documentRect =>
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble());

  /// Paints the committed artwork in document coordinates.
  void paintCommitted(Canvas canvas, List<SketchStroke> strokes) {
    if (degraded) {
      for (final stroke in strokes) {
        _paintStroke(canvas, stroke);
      }
      return;
    }
    final base = _base;
    if (base == null) return;
    canvas.drawImageRect(
      base,
      Rect.fromLTWH(0, 0, base.width.toDouble(), base.height.toDouble()),
      _documentRect,
      _imagePaint,
    );
  }

  /// Adds the last stroke of [strokes] to the cached image.
  void commit(List<SketchStroke> strokes) {
    if (degraded || strokes.isEmpty) return;
    try {
      final next = _render(_base, [strokes.last]);
      _base?.dispose();
      _base = next;
      if (strokes.length % checkpointEvery == 0) {
        _storeCheckpoint(strokes.length, next);
      }
    } catch (error, stack) {
      _degrade(error, stack);
    }
  }

  /// Rebuilds the cached image after strokes were removed (undo) or the
  /// whole stroke list was replaced.
  void rebuild(List<SketchStroke> strokes) {
    if (degraded) return;
    try {
      final count = strokes.length;
      for (final key in _checkpoints.keys.where((k) => k > count).toList()) {
        _checkpoints.remove(key)?.dispose();
      }
      _base?.dispose();
      _base = null;
      if (count == 0) return;
      var best = 0;
      for (final key in _checkpoints.keys) {
        if (key > best) best = key;
      }
      final image = _render(
        best == 0 ? null : _checkpoints[best],
        strokes.sublist(best),
      );
      _base = image;
      if (count % checkpointEvery == 0 && !_checkpoints.containsKey(count)) {
        _storeCheckpoint(count, image);
      }
    } catch (error, stack) {
      _degrade(error, stack);
    }
  }

  void _storeCheckpoint(int count, ui.Image image) {
    _checkpoints[count] = image.clone();
    while (_checkpoints.length > maxCheckpoints) {
      final oldest = _checkpoints.keys.reduce(math.min);
      _checkpoints.remove(oldest)?.dispose();
    }
  }

  ui.Image _render(ui.Image? start, List<SketchStroke> strokes) {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)..scale(scale);
    if (start != null) {
      canvas.drawImageRect(
        start,
        Rect.fromLTWH(0, 0, start.width.toDouble(), start.height.toDouble()),
        _documentRect,
        Paint(),
      );
    }
    for (final stroke in strokes) {
      _paintStroke(canvas, stroke);
    }
    final picture = recorder.endRecording();
    final image = picture.toImageSync(
      (width * scale).ceil(),
      (height * scale).ceil(),
    );
    picture.dispose();
    return image;
  }

  void _paintStroke(Canvas canvas, SketchStroke stroke) {
    final brush = resolve(stroke.brushKey);
    if (brush == null) return;
    BrushRenderer.paintStroke(canvas, stroke, brush);
  }

  void _degrade(Object error, StackTrace stack) {
    AppLog.error('Raster cache disabled', error: error, stackTrace: stack);
    degraded = true;
    dispose();
  }

  void dispose() {
    _base?.dispose();
    _base = null;
    for (final image in _checkpoints.values) {
      image.dispose();
    }
    _checkpoints.clear();
  }
}
