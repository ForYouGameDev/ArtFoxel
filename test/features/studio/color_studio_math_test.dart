import 'dart:ui';

import 'package:artfoxel/features/studio/domain/color_math.dart';
import 'package:artfoxel/features/studio/domain/palette.dart';
import 'package:artfoxel/features/studio/presentation/color_wheel.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('LAB round-trips and matches known values', () {
    for (final argb in [0xFF000000, 0xFFFFFFFF, 0xFFE5484D, 0xFF3E63DD, 0xFF30A46C, 0xFF808080]) {
      final (l, a, b) = ColorMath.toLab(argb);
      final back = ColorMath.fromLab(l, a, b);
      expect((ColorMath.red(back) - ColorMath.red(argb)).abs(), lessThanOrEqualTo(1));
      expect((ColorMath.green(back) - ColorMath.green(argb)).abs(), lessThanOrEqualTo(1));
      expect((ColorMath.blue(back) - ColorMath.blue(argb)).abs(), lessThanOrEqualTo(1));
    }
    expect(ColorMath.toLab(0xFFFFFFFF).$1, closeTo(100, 0.5));
    expect(ColorMath.toLab(0xFF000000).$1, closeTo(0, 0.5));
    final red = ColorMath.toLab(0xFFFF0000);
    expect(red.$1, closeTo(53.2, 0.6));
    expect(red.$2, closeTo(80.1, 1));
  });

  test('CMYK round-trips', () {
    for (final argb in [0xFF000000, 0xFFFFFFFF, 0xFFFF8800, 0xFF123456]) {
      final k = ColorMath.toCmyk(argb);
      final back = ColorMath.fromCmyk(k.$1, k.$2, k.$3, k.$4);
      expect(back, argb);
    }
    expect(ColorMath.toCmyk(0xFF000000).$4, 1);
  });

  test('mix and HSV/HSL stay consistent', () {
    expect(ColorMath.mix(0xFF000000, 0xFFFFFFFF, 0.5), 0xFF808080);
    final c = ColorMath.fromHsv(210, 0.6, 0.8);
    final hsv = ColorMath.toHsv(c);
    expect(hsv.$1, closeTo(210, 1.5));
  });

  test('wheel hit test: ring gives hue, square gives sat/val', () {
    const size = 240.0;
    // Top of the ring = hue 0, right = 90.
    final top = ColorWheel.hitTest(const Offset(120, 8), size, WheelLayout.square, 200, 0.5, 0.5,
        draggingRing: false, draggingInner: false)!;
    expect(top.$1, closeTo(0, 1));
    final right = ColorWheel.hitTest(const Offset(232, 120), size, WheelLayout.square, 0, 0.5, 0.5,
        draggingRing: false, draggingInner: false)!;
    expect(right.$1, closeTo(90, 1));
    final centre = ColorWheel.hitTest(const Offset(120, 120), size, WheelLayout.square, 40, 0, 0,
        draggingRing: false, draggingInner: false)!;
    expect(centre.$1, 40);
    expect(centre.$2, closeTo(0.5, 0.02));
    expect(centre.$3, closeTo(0.5, 0.02));
  });

  test('wheel triangle: vertices map to pure hue, white and black', () {
    const size = 240.0;
    final (h, w, k) = ColorWheel.trianglePoints(const Offset(120, 120), 120 - 26.4 - 4);
    final atHue = ColorWheel.hitTest(h, size, WheelLayout.triangle, 100, 0, 0,
        draggingRing: false, draggingInner: true)!;
    expect(atHue.$2, closeTo(1, 0.01));
    expect(atHue.$3, closeTo(1, 0.01));
    final atWhite = ColorWheel.hitTest(w, size, WheelLayout.triangle, 100, 0, 0,
        draggingRing: false, draggingInner: true)!;
    expect(atWhite.$2, closeTo(0, 0.01));
    expect(atWhite.$3, closeTo(1, 0.01));
    final atBlack = ColorWheel.hitTest(k, size, WheelLayout.triangle, 100, 0, 0,
        draggingRing: false, draggingInner: true)!;
    expect(atBlack.$3, closeTo(0, 0.01));
  });

  test('palette folder survives JSON', () {
    const p = ColorPalette(id: 'p1', name: 'Skin', colors: [0xFFFFCC99], folder: 'Faces');
    final back = ColorPalette.fromJson(p.toJson());
    expect(back.folder, 'Faces');
    final plain = ColorPalette.fromJson(const ColorPalette(id: 'p2', name: 'X', colors: []).toJson());
    expect(plain.folder, '');
  });
}
