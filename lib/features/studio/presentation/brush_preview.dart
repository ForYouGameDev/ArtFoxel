import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../domain/brush_preset.dart';
import '../domain/stroke_model.dart';
import '../rendering/brush_renderer.dart';

/// Draws a sample S-curve stroke with the real brush engine. The sample uses
/// a rising/falling pressure so pressure-sensitive brushes show their range
/// (a finger on a phone would draw them at constant pressure).
class BrushPreviewPainter extends CustomPainter {
  const BrushPreviewPainter({required this.brush, required this.color});

  final BrushPreset brush;
  final Color color;

  static SketchStroke sampleStroke(
    BrushPreset brush,
    Size size,
    Color color,
  ) {
    const steps = 48;
    final padding = math.min(size.height * 0.5, 14.0) + 6;
    final width = math.max(1.0, size.width - padding * 2);
    final points = <StrokePoint>[
      for (var i = 0; i < steps; i++)
        StrokePoint(
          x: padding + width * i / (steps - 1),
          y: size.height / 2 +
              math.sin(i / (steps - 1) * math.pi * 2) * size.height * 0.2,
          t: i * 14,
          pressure: math.sin(i / (steps - 1) * math.pi).clamp(0.05, 1.0).toDouble(),
        ),
    ];
    return SketchStroke(
      brushKey: 'preview',
      colorArgb: color.toARGB32(),
      size: math.min(brush.size, size.height * 0.45).clamp(1.5, 400.0).toDouble(),
      opacity: brush.opacity,
      flow: brush.flow,
      seed: 42,
      points: points,
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final bounds = Offset.zero & size;
    canvas.save();
    canvas.clipRect(bounds);
    canvas.saveLayer(bounds, Paint());
    if (brush.erase) {
      canvas.drawRect(bounds, Paint()..color = color.withValues(alpha: 0.55));
    }
    BrushRenderer.paintStroke(canvas, sampleStroke(brush, size, color), brush);
    canvas.restore();
    canvas.restore();
  }

  @override
  bool shouldRepaint(BrushPreviewPainter oldDelegate) =>
      oldDelegate.brush != brush || oldDelegate.color != color;
}

class BrushPreview extends StatelessWidget {
  const BrushPreview({
    super.key,
    required this.brush,
    this.width = 96,
    this.height = 44,
  });

  final BrushPreset brush;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: scheme.brightness == Brightness.dark
            ? const Color(0xFF1B2133)
            : const Color(0xFFF7F7FA),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: CustomPaint(
        painter: BrushPreviewPainter(
          brush: brush,
          color: scheme.brightness == Brightness.dark
              ? const Color(0xFFF1F3FF)
              : const Color(0xFF1B1F33),
        ),
      ),
    );
  }
}
