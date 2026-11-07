import 'dart:math' as math;
import 'dart:ui' show BlendMode, Offset, Rect;

import 'package:artfoxel/features/studio/domain/affine2d.dart';
import 'package:artfoxel/features/studio/domain/layer_blend.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('blend reference math (W3C compositing spec)', () {
    double b(LayerBlend m, double cb, double cs) => BlendMath.channel(m, cb, cs);

    test('multiply / screen / darken / lighten / difference / exclusion', () {
      expect(b(LayerBlend.multiply, .5, .5), closeTo(.25, 1e-9));
      expect(b(LayerBlend.screen, .5, .5), closeTo(.75, 1e-9));
      expect(b(LayerBlend.darken, .3, .7), .3);
      expect(b(LayerBlend.lighten, .3, .7), .7);
      expect(b(LayerBlend.difference, .2, .9), closeTo(.7, 1e-9));
      expect(b(LayerBlend.exclusion, .5, .5), closeTo(.5, 1e-9));
      expect(b(LayerBlend.linearDodge, .7, .6), 1);
    });

    test('overlay is hard light with the layers swapped', () {
      for (final cb in [0.1, 0.4, 0.8]) {
        for (final cs in [0.2, 0.5, 0.9]) {
          expect(b(LayerBlend.overlay, cb, cs), closeTo(b(LayerBlend.hardLight, cs, cb), 1e-12));
        }
      }
      expect(b(LayerBlend.overlay, .25, .8), closeTo(1 - 2 * (1 - .25) * (1 - .8), 1e-9));
    });

    test('colour dodge and burn edge cases', () {
      expect(b(LayerBlend.colorDodge, 0, .5), 0);
      expect(b(LayerBlend.colorDodge, .5, 1), 1);
      expect(b(LayerBlend.colorDodge, .25, .5), closeTo(.5, 1e-9));
      expect(b(LayerBlend.colorBurn, 1, .5), 1);
      expect(b(LayerBlend.colorBurn, .5, 0), 0);
      expect(b(LayerBlend.colorBurn, .75, .5), closeTo(.5, 1e-9));
    });

    test('hard light and soft light', () {
      expect(b(LayerBlend.hardLight, .5, .25), closeTo(.25, 1e-9));
      expect(b(LayerBlend.hardLight, .5, .75), closeTo(.75, 1e-9));
      // A 50% grey source leaves the backdrop unchanged.
      for (final cb in [0.1, 0.3, 0.6, 0.9]) {
        expect(b(LayerBlend.softLight, cb, .5), closeTo(cb, 1e-9));
      }
      expect(b(LayerBlend.softLight, .5, 1), closeTo(.5 + (math.sqrt(.5) - .5), 1e-9));
    });

    test('non-separable modes: luminosity, colour, hue, saturation', () {
      const backdrop = [0.8, 0.2, 0.2];
      const source = [0.1, 0.4, 0.9];
      double lum(List<double> c) => .3 * c[0] + .59 * c[1] + .11 * c[2];
      final luminosity = BlendMath.blendRgb(LayerBlend.luminosity, backdrop, source);
      expect(lum(luminosity), closeTo(lum(source), 1e-6));
      final color = BlendMath.blendRgb(LayerBlend.color, backdrop, source);
      expect(lum(color), closeTo(lum(backdrop), 1e-6));
      final hue = BlendMath.blendRgb(LayerBlend.hue, backdrop, source);
      expect(lum(hue), closeTo(lum(backdrop), 1e-6));
      final sat = BlendMath.blendRgb(LayerBlend.saturation, backdrop, source);
      expect(lum(sat), closeTo(lum(backdrop), 1e-6));
      // Grey source has no saturation, so Saturation blend desaturates.
      final grey = BlendMath.blendRgb(LayerBlend.saturation, backdrop, const [.5, .5, .5]);
      expect(grey.reduce(math.max) - grey.reduce(math.min), closeTo(0, 1e-9));
      for (final v in [...luminosity, ...color, ...hue, ...sat]) {
        expect(v, inInclusiveRange(-1e-9, 1 + 1e-9));
      }
    });

    test('compositing with alpha', () {
      // Opaque normal source replaces the backdrop.
      final replace = BlendMath.composite(LayerBlend.normal, [1, 0, 0, 1], [0, 0, 1, 1]);
      expect(replace, [0, 0, 1, 1]);
      // 50% source over opaque backdrop mixes.
      final mix = BlendMath.composite(LayerBlend.normal, [1, 0, 0, 1], [0, 0, 1, .5]);
      expect(mix[0], closeTo(.5, 1e-9));
      expect(mix[2], closeTo(.5, 1e-9));
      expect(mix[3], 1);
      // Over a transparent backdrop every mode yields the source colour.
      for (final mode in LayerBlend.values) {
        final out = BlendMath.composite(mode, [0, 0, 0, 0], [.2, .4, .6, .8]);
        expect(out[0], closeTo(.2, 1e-9), reason: mode.name);
        expect(out[3], closeTo(.8, 1e-9), reason: mode.name);
      }
      // Multiply of opaque layers.
      final m = BlendMath.composite(LayerBlend.multiply, [.5, .5, .5, 1], [.5, .5, .5, 1]);
      expect(m[0], closeTo(.25, 1e-9));
    });
  });

  group('LayerBlend', () {
    test('exposes only modes that map to a real engine blend mode', () {
      expect(LayerBlend.values.length, 17);
      for (final mode in LayerBlend.values) {
        expect(LayerBlend.unsupported.map((e) => e.toLowerCase().replaceAll(' ', '')), isNot(contains(mode.name.toLowerCase())));
      }
      expect(LayerBlend.multiply.flutter, BlendMode.multiply);
      expect(LayerBlend.linearDodge.flutter, BlendMode.plus);
      expect(LayerBlend.luminosity.flutter, BlendMode.luminosity);
      expect(LayerBlend.normal.flutter, BlendMode.srcOver);
    });

    test('unknown names fall back to normal', () {
      expect(LayerBlend.fromName('linearBurn'), LayerBlend.normal);
      expect(LayerBlend.fromName(null), LayerBlend.normal);
      expect(LayerBlend.fromName('overlay'), LayerBlend.overlay);
      expect(LayerBlend.unsupported, containsAll(['Linear Burn', 'Vivid Light', 'Hard Mix']));
    });
  });

  group('Affine2D', () {
    test('identity, translation, scale, rotation', () {
      expect(Affine2D.identity.isIdentity, isTrue);
      expect(Affine2D.translation(3, 4).apply(const Offset(1, 1)), const Offset(4, 5));
      expect(Affine2D.scale(2, 3).apply(const Offset(1, 1)), const Offset(2, 3));
      final r = Affine2D.rotation(math.pi / 2).apply(const Offset(1, 0));
      expect(r.dx, closeTo(0, 1e-9));
      expect(r.dy, closeTo(1, 1e-9));
    });

    test('composition applies the right-hand transform first', () {
      final m = Affine2D.translation(10, 0) * Affine2D.scale(2, 2);
      expect(m.apply(const Offset(1, 1)), const Offset(12, 2));
    });

    test('inverse round trips and singular matrices are refused', () {
      final m = Affine2D.translation(5, -3) * Affine2D.rotation(.7) * Affine2D.scale(2, 1.5);
      final back = m.inverse()!.apply(m.apply(const Offset(7, 9)));
      expect(back.dx, closeTo(7, 1e-9));
      expect(back.dy, closeTo(9, 1e-9));
      expect(const Affine2D(1, 1, 1, 1, 0, 0).inverse(), isNull);
    });

    test('pivot stays fixed', () {
      final m = Affine2D.rotation(1.1).aroundPivot(const Offset(50, 60));
      final p = m.apply(const Offset(50, 60));
      expect(p.dx, closeTo(50, 1e-9));
      expect(p.dy, closeTo(60, 1e-9));
      final s = Affine2D.scale(2, 2).aroundPivot(const Offset(10, 10)).apply(const Offset(20, 20));
      expect(s, const Offset(30, 30));
    });

    test('flip, skew, mapRect, JSON', () {
      expect(Affine2D.scale(-1, 1).apply(const Offset(3, 2)), const Offset(-3, 2));
      expect(Affine2D.skew(math.pi / 4, 0).apply(const Offset(0, 2)).dx, closeTo(2, 1e-9));
      expect(Affine2D.scale(2, 2).mapRect(const Rect.fromLTWH(1, 1, 2, 3)), const Rect.fromLTWH(2, 2, 4, 6));
      final m = Affine2D.translation(1, 2) * Affine2D.scale(2, 3);
      expect(Affine2D.fromJson(m.toJson()), m);
      expect(Affine2D.fromJson([1, 2, 3]), isNull);
      expect(Affine2D.fromJson([1, 1, 1, 1, 0, 0]), isNull);
      expect(Affine2D.fromJson(['a', 0, 0, 1, 0, 0]), isNull);
    });
  });
}
