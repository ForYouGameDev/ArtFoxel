import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import '../domain/brush_preset.dart';
import '../domain/smudge_planner.dart';
import '../domain/stroke_model.dart';

/// Paints a smudge stroke by moving real pixels of [source] (the layer as it
/// was before the stroke) with GPU image shaders. No blur filter is applied
/// to the artwork: the only feathering is on the *mask* of each patch.
abstract final class SmudgeEngine {
  /// [canvas] must already be in document coordinates and [source] must be
  /// the layer raster whose pixels are `scale` times the document size.
  static void paintOver(
    Canvas canvas,
    SketchStroke stroke,
    BrushPreset brush,
    ui.Image source,
    double scale,
  ) {
    final ops = SmudgePlanner.plan(stroke, brush);
    if (ops.isEmpty) return;
    final matrix = Matrix4.diagonal3Values(1 / scale, 1 / scale, 1).storage;
    final shader = ui.ImageShader(
      source,
      TileMode.decal,
      TileMode.decal,
      matrix,
      filterQuality: FilterQuality.medium,
    );
    final patch = Paint()..shader = shader;
    final erase = Paint()..blendMode = BlendMode.dstOut;
    for (final op in ops) {
      final sigma = op.softness * op.radius * 0.45;
      final mask = sigma > 0.3 ? MaskFilter.blur(BlurStyle.normal, sigma) : null;
      final reach = op.radius * (1 + op.softness * 0.9);
      final bounds = Rect.fromCircle(center: Offset(op.x, op.y), radius: reach + 2);
      // Make room where the moved pixels will land.
      erase
        ..color = Color.fromRGBO(0, 0, 0, op.strength)
        ..maskFilter = mask;
      canvas.drawCircle(Offset(op.x, op.y), op.radius, erase);
      // Lay the source patch down, shifted by (dst - src).
      canvas.saveLayer(bounds, Paint()..color = Color.fromRGBO(0, 0, 0, op.strength));
      canvas.save();
      canvas.translate(op.x - op.sx, op.y - op.sy);
      patch.maskFilter = mask;
      canvas.drawCircle(Offset(op.sx, op.sy), op.radius, patch);
      canvas.restore();
      canvas.restore();
      if (op.deposit > 0.01) {
        canvas.saveLayer(bounds, Paint()..blendMode = BlendMode.srcATop);
        canvas.drawCircle(
          Offset(op.x, op.y),
          op.radius,
          Paint()
            ..color = Color(op.depositColor).withValues(alpha: op.deposit * 0.5)
            ..maskFilter = mask,
        );
        canvas.restore();
      }
    }
    shader.dispose();
  }
}
