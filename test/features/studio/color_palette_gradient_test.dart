import 'package:artfoxel/features/studio/domain/color_math.dart';
import 'package:artfoxel/features/studio/domain/gradient_model.dart';
import 'package:artfoxel/features/studio/domain/palette.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ColorMath', () {
    test('HEX parsing accepts RGB and RRGGBB with optional #, rejects junk', () {
      expect(ColorMath.parseHex('#ff0000'), 0xFFFF0000);
      expect(ColorMath.parseHex('0f0'), 0xFF00FF00);
      expect(ColorMath.parseHex('12345'), isNull);
      expect(ColorMath.parseHex('GGGGGG'), isNull);
      expect(ColorMath.parseHex(''), isNull);
    });

    test('HSV and HSL round trip within one unit per channel', () {
      for (final c in [0xFF123456, 0xFFFFFFFF, 0xFF000000, 0xFFAB00CD, 0xFF808080]) {
        final hsv = ColorMath.toHsv(c);
        final a = ColorMath.fromHsv(hsv.$1, hsv.$2, hsv.$3);
        final hsl = ColorMath.toHsl(c);
        final b = ColorMath.fromHsl(hsl.$1, hsl.$2, hsl.$3);
        for (final r in [a, b]) {
          expect((ColorMath.red(r) - ColorMath.red(c)).abs(), lessThanOrEqualTo(1));
          expect((ColorMath.green(r) - ColorMath.green(c)).abs(), lessThanOrEqualTo(1));
          expect((ColorMath.blue(r) - ColorMath.blue(c)).abs(), lessThanOrEqualTo(1));
        }
      }
    });

    test('WCAG contrast: black on white is 21:1 and graded AAA', () {
      expect(ColorMath.contrastRatio(0xFF000000, 0xFFFFFFFF), closeTo(21, 0.01));
      expect(ColorMath.wcagGrade(0xFF000000, 0xFFFFFFFF), 'AAA');
      expect(ColorMath.wcagGrade(0xFF777777, 0xFF7A7A7A), 'Fail');
    });

    test('complementary harmony of red includes cyan', () {
      final h = ColorMath.harmony(0xFFFF0000, Harmony.complementary);
      expect(h.first, 0xFFFF0000);
      expect(h.contains(0xFF00FFFF), isTrue);
    });
  });

  group('Palettes', () {
    test('export then import keeps names and colours', () {
      const p = ColorPalette(id: 'a', name: 'Mine', colors: [0xFF112233, 0xFFFFFFFF]);
      final back = PaletteCodec.import(PaletteCodec.export([p]));
      expect(back.single.name, 'Mine');
      expect(back.single.colors, p.colors);
    });

    test('GIMP gpl import works and names are made unique', () {
      const gpl = 'GIMP Palette\nName: Test\n#\n255 0 0 red\n0 255 0 green\n';
      final out = PaletteCodec.import(gpl, existingNames: ['Test']);
      expect(out.single.colors, [0xFFFF0000, 0xFF00FF00]);
      expect(out.single.name.toLowerCase() == 'test', isFalse);
    });

    test('malformed or empty input is refused with a message', () {
      expect(() => PaletteCodec.import('   '), throwsA(isA<PaletteException>()));
      expect(() => PaletteCodec.import('{"format":"artfoxel-palette","schema":99,"palettes":[]}'),
          throwsA(isA<PaletteException>()));
    });
  });

  group('Gradients', () {
    GradientData two() => GradientData(stops: const [GradientStop(0, 0xFF000000), GradientStop(1, 0xFFFFFFFF)]);

    test('colorAt interpolates and clamps', () {
      final g = two();
      expect(g.colorAt(0) & 0xFFFFFF, 0);
      expect(g.colorAt(1) & 0xFFFFFF, 0xFFFFFF);
      final mid = g.colorAt(0.5);
      expect(ColorMath.red(mid), inInclusiveRange(126, 129));
    });

    test('stops are sorted and validated', () {
      final g = GradientData(stops: const [GradientStop(1, 0xFF0000FF), GradientStop(0, 0xFFFF0000)]);
      expect(g.stops.first.position, 0);
      expect(() => GradientData(stops: const [GradientStop(0, 0xFF000000)]), throwsA(isA<GradientException>()));
      expect(() => GradientData(stops: const [GradientStop(-1, 0xFF000000), GradientStop(1, 0xFF000000)]),
          throwsA(isA<GradientException>()));
    });

    test('JSON round trip keeps every setting (save/reopen)', () {
      final g = GradientData(
        kind: GradientKind.radial,
        interpolation: GradientInterpolation.smooth,
        radius: 0.8,
        stops: const [GradientStop(0, 0xFFFF0000, 0.5), GradientStop(0.4, 0xFF00FF00), GradientStop(1, 0xFF0000FF)],
      );
      final back = GradientData.fromJson(g.toJson());
      expect(back, g);
    });

    test('every preset is valid', () {
      for (final p in GradientPresets.all) {
        expect(GradientData.fromJson(p.gradient.toJson()), p.gradient);
      }
    });
  });
}
