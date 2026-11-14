import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Edits a pressure response curve y = x^exponent. Drag the handle (at
/// x = 0.5) up for a lighter touch (more response at low pressure) or down
/// for a firmer one. Exactly the same exponent the stroke sampler applies.
class PressureCurveEditor extends StatelessWidget {
  const PressureCurveEditor({
    required this.title,
    required this.exponent,
    required this.onChanged,
    this.onChangeEnd,
    this.enabled = true,
    super.key,
  });

  static const double minExponent = 0.25;
  static const double maxExponent = 4;

  final String title;
  final double exponent;
  final ValueChanged<double> onChanged;
  final VoidCallback? onChangeEnd;
  final bool enabled;

  /// Exponent for a handle height [y] (0..1) at x = 0.5.
  static double exponentForY(double y) {
    final clamped = y.clamp(0.02, 0.98).toDouble();
    return (math.log(clamped) / math.log(0.5)).clamp(minExponent, maxExponent).toDouble();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const side = 120.0;
    void update(Offset p) {
      if (!enabled) return;
      onChanged(exponentForY(1 - p.dy / side));
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: [
        GestureDetector(
          onPanStart: (d) => update(d.localPosition),
          onPanUpdate: (d) => update(d.localPosition),
          onPanEnd: (_) => onChangeEnd?.call(),
          onTapDown: (d) => update(d.localPosition),
          onTapUp: (_) => onChangeEnd?.call(),
          child: Semantics(
            label: '$title pressure curve',
            child: CustomPaint(
              size: const Size(side, side),
              painter: _CurvePainter(
                exponent: exponent,
                line: theme.colorScheme.primary,
                grid: theme.colorScheme.outlineVariant,
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: theme.textTheme.labelLarge),
            Text('Light touch → ${(math.pow(0.25, exponent) * 100).round()}% at 25% pressure',
                style: theme.textTheme.bodySmall),
            Text('Half pressure → ${(math.pow(0.5, exponent) * 100).round()}%', style: theme.textTheme.bodySmall),
            TextButton(
              onPressed: enabled
                  ? () {
                      onChanged(1);
                      onChangeEnd?.call();
                    }
                  : null,
              child: const Text('Reset to linear'),
            ),
          ]),
        ),
      ]),
    );
  }
}

class _CurvePainter extends CustomPainter {
  _CurvePainter({required this.exponent, required this.line, required this.grid});

  final double exponent;
  final Color line;
  final Color grid;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(8)),
      Paint()..color = grid.withValues(alpha: 0.25),
    );
    final gridPaint = Paint()
      ..color = grid
      ..strokeWidth = 1;
    for (var i = 1; i < 4; i++) {
      canvas.drawLine(Offset(size.width * i / 4, 0), Offset(size.width * i / 4, size.height), gridPaint);
      canvas.drawLine(Offset(0, size.height * i / 4), Offset(size.width, size.height * i / 4), gridPaint);
    }
    final path = Path();
    for (var i = 0; i <= 40; i++) {
      final x = i / 40;
      final y = math.pow(x, exponent).toDouble();
      final p = Offset(x * size.width, (1 - y) * size.height);
      if (i == 0) {
        path.moveTo(p.dx, p.dy);
      } else {
        path.lineTo(p.dx, p.dy);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = line,
    );
    final handle = Offset(size.width / 2, (1 - math.pow(0.5, exponent).toDouble()) * size.height);
    canvas.drawCircle(handle, 8, Paint()..color = Colors.white);
    canvas.drawCircle(
      handle,
      8,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = line,
    );
  }

  @override
  bool shouldRepaint(_CurvePainter old) => old.exponent != exponent || old.line != line;
}
