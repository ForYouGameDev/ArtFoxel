import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import '../domain/brush_preset.dart';
import '../domain/stroke_model.dart';
import '../domain/stroke_sampler.dart';
import 'brush_resources.dart';

/// Draws one stroke with one brush. Engines are interchangeable: a preset
/// selects its engine by [BrushEngineKind], so new engines can be added
/// without touching the canvas, raster or document code.
abstract class BrushEngine {
  const BrushEngine();

  /// Paints [stroke] in document coordinates.
  void paint(Canvas canvas, SketchStroke stroke, BrushPreset brush);
}

class _NoopEngine extends BrushEngine {
  const _NoopEngine();
  @override
  void paint(Canvas canvas, SketchStroke stroke, BrushPreset brush) {}
}

abstract final class BrushRenderer {
  static void paintStroke(
    Canvas canvas,
    SketchStroke stroke,
    BrushPreset brush,
  ) {
    if (stroke.points.isEmpty) return;
    _engineFor(brush).paint(canvas, stroke, brush);
  }

  static BrushEngine _engineFor(BrushPreset brush) {
    if (brush.erase && brush.engine == BrushEngineKind.watercolor) {
      return const StampEngine();
    }
    return switch (brush.engine) {
      BrushEngineKind.stamp => const StampEngine(),
      BrushEngineKind.line => const LineEngine(),
      BrushEngineKind.watercolor => const WatercolorEngine(),
      // Smudge needs the pixels under the stroke; the raster and compositor
      // call SmudgeEngine directly. Replaying one without a base draws nothing.
      BrushEngineKind.smudge => const _NoopEngine(),
    };
  }
}

/// Runs [body] inside an offscreen layer when the brush needs one: to cap the
/// whole stroke at its opacity (so overlaps do not darken) and to apply paper
/// grain. Erasers draw straight onto the artwork layer.
void _withStrokeLayer(
  Canvas canvas,
  SketchStroke stroke,
  BrushPreset brush,
  void Function() body, {
  bool force = false,
  bool? buildup,
}) {
  final accumulate = buildup ?? brush.buildup;
  final grain = brush.erase
      ? null
      : BrushResources.grainShader(brush.grain, brush.grainStrength);
  final needsLayer = !brush.erase && (force || !accumulate || grain != null);
  if (!needsLayer) {
    body();
    return;
  }
  final bounds = StrokeSampler.bounds(stroke, brush);
  final opacity = accumulate ? 1.0 : stroke.opacity;
  canvas.saveLayer(bounds, Paint()..color = Color.fromRGBO(0, 0, 0, opacity));
  body();
  if (grain != null) {
    canvas.drawRect(
      bounds,
      Paint()
        ..shader = grain
        ..blendMode = BlendMode.dstIn,
    );
  }
  canvas.restore();
}

final Path _unitDiamond = Path()
  ..moveTo(0, -0.5)
  ..lineTo(0.5, 0)
  ..lineTo(0, 0.5)
  ..lineTo(-0.5, 0)
  ..close();

final Path _unitTriangle = Path()
  ..moveTo(0, -0.5)
  ..lineTo(0.5, 0.5)
  ..lineTo(-0.5, 0.5)
  ..close();

final Path _unitLeaf = Path()
  ..moveTo(0, -0.5)
  ..quadraticBezierTo(0.62, -0.1, 0, 0.5)
  ..quadraticBezierTo(-0.62, -0.1, 0, -0.5)
  ..close();

final Path _unitBlade = Path()
  ..moveTo(0, -0.5)
  ..quadraticBezierTo(0.18, 0.05, 0.12, 0.5)
  ..lineTo(-0.12, 0.5)
  ..quadraticBezierTo(-0.18, 0.05, 0, -0.5)
  ..close();

final Path _unitFlame = Path()
  ..moveTo(0, -0.5)
  ..cubicTo(0.18, -0.2, 0.5, 0.05, 0.3, 0.32)
  ..quadraticBezierTo(0.15, 0.55, 0, 0.5)
  ..quadraticBezierTo(-0.15, 0.55, -0.3, 0.32)
  ..cubicTo(-0.5, 0.05, -0.12, -0.15, 0, -0.5)
  ..close();

final Path _unitFlower = () {
  final path = Path();
  for (var i = 0; i < 5; i++) {
    final angle = -math.pi / 2 + i * 2 * math.pi / 5;
    path.addOval(Rect.fromCenter(
      center: Offset(math.cos(angle) * 0.24, math.sin(angle) * 0.24),
      width: 0.3,
      height: 0.3,
    ));
  }
  return path;
}();

final Path _unitStar = () {
  final path = Path();
  for (var i = 0; i < 10; i++) {
    final radius = i.isEven ? 0.5 : 0.21;
    final angle = -math.pi / 2 + i * math.pi / 5;
    final x = math.cos(angle) * radius;
    final y = math.sin(angle) * radius;
    if (i == 0) {
      path.moveTo(x, y);
    } else {
      path.lineTo(x, y);
    }
  }
  return path..close();
}();

/// Stamps [dabs] using the brush tip. Shared by the stamp and watercolor
/// engines.
void _stampDabs(
  Canvas canvas,
  List<Dab> dabs,
  BrushPreset brush, {
  TipShape? tip,
  double alphaScale = 1,
  double sizeScale = 1,
}) {
  final shape = tip ?? brush.tip;
  final soft = shape == TipShape.round && brush.hardness < 0.97;
  ui.Image? image;
  if (soft) {
    image = BrushResources.softTip(brush.hardness);
  } else if (shape == TipShape.speckle) {
    image = BrushResources.speckleTip();
  }
  final source = image == null
      ? Rect.zero
      : Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble());
  final paint = Paint()..isAntiAlias = true;
  if (brush.erase) paint.blendMode = BlendMode.dstOut;

  for (final dab in dabs) {
    final alpha = dab.alpha * alphaScale;
    if (alpha <= 0.002) continue;
    final color = brush.erase
        ? const Color(0xFF000000).withValues(alpha: alpha)
        : Color(dab.colorArgb).withValues(alpha: alpha);
    final width = dab.size * sizeScale;
    final height = width * brush.roundness;

    canvas.save();
    canvas.translate(dab.x, dab.y);
    if (dab.angle != 0) canvas.rotate(dab.angle);
    if (image != null) {
      paint.colorFilter = ColorFilter.mode(color, BlendMode.srcIn);
      canvas.drawImageRect(
        image,
        source,
        Rect.fromCenter(center: Offset.zero, width: width, height: height),
        paint,
      );
    } else {
      paint
        ..colorFilter = null
        ..color = color;
      switch (shape) {
        case TipShape.square:
          canvas.drawRect(
            Rect.fromCenter(center: Offset.zero, width: width, height: height),
            paint,
          );
        case TipShape.diamond:
          canvas.scale(width, height);
          canvas.drawPath(_unitDiamond, paint);
        case TipShape.star:
          canvas.scale(width, height);
          canvas.drawPath(_unitStar, paint);
        case TipShape.triangle:
          canvas.scale(width, height);
          canvas.drawPath(_unitTriangle, paint);
        case TipShape.leaf:
          canvas.scale(width, height);
          canvas.drawPath(_unitLeaf, paint);
        case TipShape.flower:
          canvas.scale(width, height);
          canvas.drawPath(_unitFlower, paint);
        case TipShape.blade:
          canvas.scale(width, height);
          canvas.drawPath(_unitBlade, paint);
        case TipShape.flame:
          canvas.scale(width, height);
          canvas.drawPath(_unitFlame, paint);
        case TipShape.round:
        case TipShape.speckle:
          // Soft tips need an image; without one, blur a plain oval.
          paint.maskFilter = soft
              ? MaskFilter.blur(
                  BlurStyle.normal,
                  math.max(0.5, width * 0.22 * (1 - brush.hardness)),
                )
              : null;
          canvas.drawOval(
            Rect.fromCenter(center: Offset.zero, width: width, height: height),
            paint,
          );
          paint.maskFilter = null;
      }
    }
    canvas.restore();
  }
}

Path _smoothPath(List<StrokePoint> points) {
  final path = Path()..moveTo(points.first.x, points.first.y);
  if (points.length == 2) {
    path.lineTo(points[1].x, points[1].y);
    return path;
  }
  for (var i = 1; i < points.length - 1; i++) {
    path.quadraticBezierTo(
      points[i].x,
      points[i].y,
      (points[i].x + points[i + 1].x) / 2,
      (points[i].y + points[i + 1].y) / 2,
    );
  }
  path.lineTo(points.last.x, points.last.y);
  return path;
}

/// Repeated tip stamps: pencils, inks, markers, soft/hard brushes, airbrush,
/// charcoal, chalk, pattern, stamp and particle brushes.
class StampEngine extends BrushEngine {
  const StampEngine();

  @override
  void paint(Canvas canvas, SketchStroke stroke, BrushPreset brush) {
    final dabs = StrokeSampler.dabs(stroke, brush);
    _withStrokeLayer(canvas, stroke, brush, () {
      _stampDabs(canvas, dabs, brush);
    });
  }
}

/// A crisp constant-width path: technical pen and mechanical pencil.
class LineEngine extends BrushEngine {
  const LineEngine();

  @override
  void paint(Canvas canvas, SketchStroke stroke, BrushPreset brush) {
    final points = stroke.points;
    final paint = Paint()
      ..isAntiAlias = true
      ..strokeWidth = stroke.size
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    if (brush.erase) {
      paint
        ..blendMode = BlendMode.dstOut
        ..color = const Color(0xFF000000)
            .withValues(alpha: stroke.flow * stroke.opacity);
    } else {
      paint.color = Color(stroke.colorArgb).withValues(alpha: stroke.flow);
    }
    // Layer opacity is the stroke opacity; line brushes never accumulate.
    _withStrokeLayer(canvas, stroke, brush, () {
      if (points.length == 1) {
        paint.style = PaintingStyle.fill;
        canvas.drawCircle(
          Offset(points.first.x, points.first.y),
          stroke.size / 2,
          paint,
        );
      } else {
        paint.style = PaintingStyle.stroke;
        canvas.drawPath(_smoothPath(points), paint);
      }
    }, buildup: false);
  }
}

/// Basic watercolor approximation: soft translucent washes, a second offset
/// pass that bleeds past the stroke, and a darker wet edge.
class WatercolorEngine extends BrushEngine {
  const WatercolorEngine();

  @override
  void paint(Canvas canvas, SketchStroke stroke, BrushPreset brush) {
    final dabs = StrokeSampler.dabs(stroke, brush);
    final points = stroke.points;
    _withStrokeLayer(canvas, stroke, brush, () {
      if (brush.wetEdge > 0 && points.length > 1) {
        final path = _smoothPath(points);
        final blur = stroke.size * 0.03 * (0.3 + brush.bleed);
        final rim = Paint()
          ..isAntiAlias = true
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..strokeWidth = stroke.size * 0.9
          ..color = Color(stroke.colorArgb)
              .withValues(alpha: brush.wetEdge * 0.5 * stroke.flow);
        final inner = Paint()
          ..isAntiAlias = true
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..strokeWidth = stroke.size * 0.9 * 0.78
          ..blendMode = BlendMode.dstOut
          ..color = const Color(0xFF000000)
              .withValues(alpha: brush.wetEdge * 0.45 * stroke.flow);
        if (blur > 0.5) {
          rim.maskFilter = MaskFilter.blur(BlurStyle.normal, blur);
          inner.maskFilter = MaskFilter.blur(BlurStyle.normal, blur);
        }
        canvas.drawPath(path, rim);
        canvas.drawPath(path, inner);
      }
      _stampDabs(canvas, dabs, brush, tip: TipShape.round, alphaScale: 0.32);
      if (brush.bleed > 0) {
        final random = math.Random(stroke.seed ^ 0x5bd1e995);
        final reach = brush.bleed * stroke.size * 0.18;
        final shifted = [
          for (final dab in dabs)
            Dab(
              x: dab.x + (random.nextDouble() * 2 - 1) * reach,
              y: dab.y + (random.nextDouble() * 2 - 1) * reach,
              size: dab.size,
              alpha: dab.alpha,
              angle: dab.angle,
              colorArgb: dab.colorArgb,
            ),
        ];
        _stampDabs(
          canvas,
          shifted,
          brush,
          tip: TipShape.round,
          alphaScale: 0.18,
          sizeScale: 1 + brush.bleed * 0.25,
        );
      }
    }, force: true);
  }
}
