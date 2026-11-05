import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../domain/brush_preset.dart';
import '../domain/stroke_model.dart';
import '../domain/stroke_stabilizer.dart';
import '../rendering/brush_renderer.dart';

/// A small scratch canvas for trying a brush while editing it. It is
/// completely separate from the artwork canvas: nothing drawn here is saved,
/// and every stroke is re-rendered with the brush as currently edited.
class BrushTestCanvas extends StatefulWidget {
  const BrushTestCanvas({
    required this.brush,
    this.height = 180,
    super.key,
  });

  final BrushPreset brush;
  final double height;

  @override
  State<BrushTestCanvas> createState() => _BrushTestCanvasState();
}

class _BrushTestCanvasState extends State<BrushTestCanvas> {
  final List<List<StrokePoint>> _strokes = [];
  final List<int> _seeds = [];
  StrokeStabilizer? _stabilizer;
  int _originMs = 0;

  StrokePoint _point(PointerEvent event) {
    final usesPressure = event.kind != PointerDeviceKind.mouse &&
        event.pressureMax > event.pressureMin;
    return StrokePoint(
      x: event.localPosition.dx,
      y: event.localPosition.dy,
      t: math.max(0, event.timeStamp.inMilliseconds - _originMs),
      pressure: usesPressure ? event.pressure.clamp(0.0, 1.0).toDouble() : null,
      tilt: event.kind == PointerDeviceKind.stylus && event.tilt > 0
          ? event.tilt
          : null,
    );
  }

  void _down(PointerDownEvent event) {
    _originMs = event.timeStamp.inMilliseconds;
    _stabilizer = StrokeStabilizer(
      StabilizerConfig(
        strength: widget.brush.stabilization,
        preserveCorners: widget.brush.preserveCorners,
      ),
    );
    setState(() {
      _strokes.add([_stabilizer!.add(_point(event))]);
      _seeds.add(_strokes.length * 7919);
    });
  }

  void _move(PointerMoveEvent event) {
    final stabilizer = _stabilizer;
    if (stabilizer == null || _strokes.isEmpty) return;
    setState(() => _strokes.last.add(stabilizer.add(_point(event))));
  }

  void _up(PointerEvent event) {
    final stabilizer = _stabilizer;
    if (stabilizer != null && _strokes.isNotEmpty) {
      setState(() => _strokes.last.addAll(stabilizer.finish(_point(event))));
    }
    _stabilizer = null;
  }

  void _clear() => setState(() {
        _strokes.clear();
        _seeds.clear();
      });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    final ink = dark ? const Color(0xFFF1F3FF) : const Color(0xFF1B1F33);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: widget.height,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: dark ? const Color(0xFF1B2133) : const Color(0xFFFFFFFF),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: Listener(
            key: const ValueKey('brush-test-canvas'),
            behavior: HitTestBehavior.opaque,
            onPointerDown: _down,
            onPointerMove: _move,
            onPointerUp: _up,
            onPointerCancel: _up,
            child: CustomPaint(
              painter: _TestPainter(
                strokes: [for (final s in _strokes) List.of(s)],
                seeds: List.of(_seeds),
                brush: widget.brush,
                color: ink,
              ),
              child: const SizedBox.expand(),
            ),
          ),
        ),
        Row(
          children: [
            Expanded(
              child: Text(
                'Test canvas · nothing here is saved',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
              ),
            ),
            TextButton.icon(
              onPressed: _strokes.isEmpty ? null : _clear,
              icon: const Icon(Icons.layers_clear_outlined),
              label: const Text('Clear'),
            ),
          ],
        ),
      ],
    );
  }
}

class _TestPainter extends CustomPainter {
  const _TestPainter({
    required this.strokes,
    required this.seeds,
    required this.brush,
    required this.color,
  });

  final List<List<StrokePoint>> strokes;
  final List<int> seeds;
  final BrushPreset brush;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final bounds = Offset.zero & size;
    canvas.clipRect(bounds);
    canvas.saveLayer(bounds, Paint());
    if (brush.erase) {
      canvas.drawRect(bounds, Paint()..color = color.withValues(alpha: 0.5));
    }
    for (var i = 0; i < strokes.length; i++) {
      final stroke = SketchStroke(
        brushKey: 'test',
        colorArgb: color.toARGB32(),
        size: brush.size.clamp(1.0, size.height * 0.6).toDouble(),
        opacity: brush.opacity,
        flow: brush.flow,
        seed: seeds[i],
        points: strokes[i],
      );
      BrushRenderer.paintStroke(canvas, stroke, brush);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_TestPainter oldDelegate) => true;
}
