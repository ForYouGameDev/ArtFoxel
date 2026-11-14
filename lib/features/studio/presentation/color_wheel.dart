import 'dart:math' as math;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../domain/color_math.dart';

enum WheelLayout { square, triangle }

/// A real HSV colour picker: a hue ring plus either a saturation/value square
/// or a saturation/value triangle. Dragging reports the exact colour under
/// the finger; nothing here is decorative.
class ColorWheel extends StatefulWidget {
  const ColorWheel({
    required this.argb,
    required this.onChanged,
    this.layout = WheelLayout.square,
    this.size = 240,
    super.key,
  });

  final int argb;
  final ValueChanged<int> onChanged;
  final WheelLayout layout;
  final double size;

  /// Maps a touch position to (hue, sat, val), or null if it is not on a
  /// control. Pure so it can be unit tested.
  static (double, double, double)? hitTest(
    Offset p,
    double size,
    WheelLayout layout,
    double hue,
    double sat,
    double val, {
    required bool draggingRing,
    required bool draggingInner,
  }) {
    final c = Offset(size / 2, size / 2);
    final d = p - c;
    final dist = d.distance;
    final outer = size / 2;
    final ringWidth = size * 0.11;
    final inner = outer - ringWidth;
    final onRing = dist >= inner - 2 && dist <= outer + 2;
    if (draggingRing || (!draggingInner && onRing)) {
      var h = math.atan2(d.dy, d.dx) * 180 / math.pi + 90;
      h = (h % 360 + 360) % 360;
      return (h, sat, val);
    }
    final r = inner - 4;
    if (layout == WheelLayout.square) {
      final half = r / math.sqrt2;
      final rect = Rect.fromCenter(center: c, width: half * 2, height: half * 2);
      final inside = rect.inflate(draggingInner ? 40 : 0).contains(p);
      if (!inside && !draggingInner) return null;
      final s = ((p.dx - rect.left) / rect.width).clamp(0.0, 1.0).toDouble();
      final v = (1 - (p.dy - rect.top) / rect.height).clamp(0.0, 1.0).toDouble();
      return (hue, s, v);
    }
    final (hv, wv, kv) = trianglePoints(c, r);
    final w = _barycentric(p, hv, wv, kv);
    final inside = w.$1 >= -0.02 && w.$2 >= -0.02 && w.$3 >= -0.02;
    if (!inside && !draggingInner) return null;
    var a = w.$1.clamp(0.0, 1.0).toDouble();
    var b = w.$2.clamp(0.0, 1.0).toDouble();
    var k = w.$3.clamp(0.0, 1.0).toDouble();
    final total = a + b + k;
    if (total > 0) {
      a /= total;
      b /= total;
      k /= total;
    }
    final v = (1 - k).clamp(0.0, 1.0).toDouble();
    final s = v <= 0 ? 0.0 : (a / v).clamp(0.0, 1.0).toDouble();
    return (hue, s, v);
  }

  /// Vertices: hue (top), white (bottom right), black (bottom left).
  static (Offset, Offset, Offset) trianglePoints(Offset c, double r) {
    Offset at(double deg) => c + Offset(math.cos(deg * math.pi / 180), math.sin(deg * math.pi / 180)) * r;
    return (at(-90), at(30), at(150));
  }

  static (double, double, double) _barycentric(Offset p, Offset a, Offset b, Offset c) {
    final v0 = b - a, v1 = c - a, v2 = p - a;
    final d00 = v0.dx * v0.dx + v0.dy * v0.dy;
    final d01 = v0.dx * v1.dx + v0.dy * v1.dy;
    final d11 = v1.dx * v1.dx + v1.dy * v1.dy;
    final d20 = v2.dx * v0.dx + v2.dy * v0.dy;
    final d21 = v2.dx * v1.dx + v2.dy * v1.dy;
    final den = d00 * d11 - d01 * d01;
    if (den == 0) return (1, 0, 0);
    final wb = (d11 * d20 - d01 * d21) / den;
    final wc = (d00 * d21 - d01 * d20) / den;
    return (1 - wb - wc, wb, wc);
  }

  @override
  State<ColorWheel> createState() => _ColorWheelState();
}

class _ColorWheelState extends State<ColorWheel> {
  bool _ring = false;
  bool _inner = false;
  late double _hue;

  @override
  void initState() {
    super.initState();
    _hue = ColorMath.toHsv(widget.argb).$1;
  }

  @override
  void didUpdateWidget(ColorWheel old) {
    super.didUpdateWidget(old);
    final (h, s, v) = ColorMath.toHsv(widget.argb);
    // Hue is undefined for greys; keep the last one so the ring does not jump.
    if (s > 0.02 && v > 0.02) _hue = h;
  }

  void _handle(Offset p, {bool start = false}) {
    final (_, s, v) = ColorMath.toHsv(widget.argb);
    final hit = ColorWheel.hitTest(
      p,
      widget.size,
      widget.layout,
      _hue,
      s,
      v,
      draggingRing: _ring,
      draggingInner: _inner,
    );
    if (hit == null) return;
    if (start) {
      final c = Offset(widget.size / 2, widget.size / 2);
      final dist = (p - c).distance;
      final inner = widget.size / 2 - widget.size * 0.11;
      _ring = dist >= inner - 2;
      _inner = !_ring;
    }
    _hue = hit.$1;
    widget.onChanged(ColorMath.fromHsv(hit.$1, hit.$2, hit.$3));
  }

  @override
  Widget build(BuildContext context) {
    final (_, s, v) = ColorMath.toHsv(widget.argb);
    return Semantics(
      label: 'Colour wheel. Drag the ring for hue and the centre for saturation and brightness.',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (d) => _handle(d.localPosition, start: true),
        onPanUpdate: (d) => _handle(d.localPosition),
        onPanEnd: (_) {
          _ring = false;
          _inner = false;
        },
        onTapDown: (d) {
          _ring = false;
          _inner = false;
          _handle(d.localPosition, start: true);
          _ring = false;
          _inner = false;
        },
        child: SizedBox(
          width: widget.size,
          height: widget.size,
          child: CustomPaint(
            painter: _WheelPainter(hue: _hue, sat: s, val: v, layout: widget.layout),
          ),
        ),
      ),
    );
  }
}

class _WheelPainter extends CustomPainter {
  _WheelPainter({required this.hue, required this.sat, required this.val, required this.layout});

  final double hue;
  final double sat;
  final double val;
  final WheelLayout layout;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final outer = size.width / 2;
    final ringWidth = size.width * 0.11;
    final mid = outer - ringWidth / 2;
    // Hue ring: a sweep gradient starting at the top.
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = ringWidth
      ..shader = SweepGradient(
        colors: [
          for (var i = 0; i <= 12; i++) Color(ColorMath.fromHsv(i * 30.0, 1, 1)),
        ],
        transform: const GradientRotation(-math.pi / 2),
      ).createShader(Rect.fromCircle(center: c, radius: mid));
    canvas.drawCircle(c, mid, ring);

    final hueColor = Color(ColorMath.fromHsv(hue, 1, 1));
    final r = outer - ringWidth - 4;
    Offset marker;
    if (layout == WheelLayout.square) {
      final half = r / math.sqrt2;
      final rect = Rect.fromCenter(center: c, width: half * 2, height: half * 2);
      canvas.drawRect(
        rect,
        Paint()
          ..shader = LinearGradient(colors: [Colors.white, hueColor]).createShader(rect),
      );
      canvas.drawRect(
        rect,
        Paint()
          ..shader = const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0x00000000), Color(0xFF000000)],
          ).createShader(rect),
      );
      marker = Offset(rect.left + rect.width * sat, rect.top + rect.height * (1 - val));
    } else {
      final (h, w, k) = ColorWheel.trianglePoints(c, r);
      final path = Path()
        ..moveTo(h.dx, h.dy)
        ..lineTo(w.dx, w.dy)
        ..lineTo(k.dx, k.dy)
        ..close();
      canvas.save();
      canvas.clipPath(path);
      canvas.saveLayer(Offset.zero & size, Paint());
      Paint grad(Offset vertex, Offset a, Offset b, Color color) {
        final mid = (a + b) / 2;
        return Paint()
          ..blendMode = BlendMode.plus
          ..shader = ui.Gradient.linear(vertex, mid, [color, const Color(0xFF000000)]);
      }

      canvas.drawPaint(grad(h, w, k, hueColor));
      canvas.drawPaint(grad(w, h, k, Colors.white));
      canvas.drawPaint(grad(k, h, w, const Color(0xFF000000)));
      canvas.restore();
      canvas.restore();
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = Colors.black26,
      );
      final a = sat * val, b = val * (1 - sat), kk = 1 - val;
      marker = Offset(
        h.dx * a + w.dx * b + k.dx * kk,
        h.dy * a + w.dy * b + k.dy * kk,
      );
    }
    _ringMarker(canvas, c, mid, hue);
    _marker(canvas, marker);
  }

  void _ringMarker(Canvas canvas, Offset c, double mid, double hue) {
    final angle = (hue - 90) * math.pi / 180;
    _marker(canvas, c + Offset(math.cos(angle), math.sin(angle)) * mid, small: true);
  }

  void _marker(Canvas canvas, Offset p, {bool small = false}) {
    final radius = small ? 7.0 : 9.0;
    canvas.drawCircle(p, radius + 1.5, Paint()..color = Colors.black54);
    canvas.drawCircle(
      p,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..color = Colors.white,
    );
  }

  @override
  bool shouldRepaint(_WheelPainter old) =>
      old.hue != hue || old.sat != sat || old.val != val || old.layout != layout;
}
