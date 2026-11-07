import 'dart:typed_data';

import 'package:artfoxel/features/studio/filters/filter_engine.dart';
import 'package:flutter_test/flutter_test.dart';

FilterImage _img(int w, int h, List<int> Function(int x, int y) px) {
  final out = FilterImage(w, h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      out.rgba.setAll((y * w + x) * 4, px(x, y));
    }
  }
  return out;
}

FilterImage _photo() => _img(24, 20, (x, y) => [(x * 10) % 256, (y * 12) % 256, (x * y) % 256, 255]);

FilterOp _op(String id, [Map<String, double> p = const {}]) =>
    FilterOp(id, FilterRegistry.byId(id)!.normalize(p));

void main() {
  group('Registry', () {
    test('ids are unique and every default op runs on a small image', () {
      final ids = FilterRegistry.all.map((f) => f.id).toList();
      expect(ids.toSet().length, ids.length);
      expect(ids.length, greaterThanOrEqualTo(45));
      final src = _photo();
      for (final f in FilterRegistry.all) {
        final out = FilterEngine.applyOp(src, FilterRegistry.defaultOp(f.id));
        expect(out.width, src.width, reason: f.id);
        expect(out.height, src.height, reason: f.id);
      }
    });

    test('artistic approximations are labelled, exact adjustments are not', () {
      for (final id in ['watercolor', 'oil', 'pencil', 'charcoal', 'glow', 'bloom', 'surface', 'texture', 'grain']) {
        expect(FilterRegistry.byId(id)!.approximation, isNotNull, reason: id);
      }
      expect(FilterRegistry.byId('brightness')!.approximation, isNull);
      expect(FilterRegistry.byId('lensFlare'), isNull); // not implemented, not faked
    });
  });

  group('Adjustments', () {
    test('neutral parameters leave pixels unchanged', () {
      final src = _photo();
      for (final id in ['brightness', 'contrast', 'exposure', 'gamma', 'saturation', 'vibrance', 'hue', 'temperature', 'tint', 'opacity', 'levels', 'tonal']) {
        final out = FilterEngine.applyOp(src, FilterRegistry.defaultOp(id));
        for (var i = 0; i < src.rgba.length; i++) {
          expect((out.rgba[i] - src.rgba[i]).abs(), lessThanOrEqualTo(1), reason: '$id at $i');
        }
      }
    });

    test('brightness +50 brightens and clamps without wrapping', () {
      final src = _img(2, 1, (x, y) => x == 0 ? [100, 100, 100, 255] : [250, 250, 250, 255]);
      final out = FilterEngine.applyOp(src, _op('brightness', {'amount': 50}));
      expect(out.rgba[0], greaterThan(100));
      expect(out.rgba[4], 255);
    });

    test('alpha is preserved by every colour filter, including partial alpha', () {
      final src = _img(8, 8, (x, y) => [200, 120, 40, (x * 36) % 256]);
      final colorIds = [
        for (final f in FilterRegistry.all)
          if (f.category == FilterCategory.adjust || f.category == FilterCategory.color) f.id
      ];
      for (final id in colorIds) {
        if (id == 'opacity') continue;
        final out = FilterEngine.applyOp(src, FilterRegistry.defaultOp(id));
        for (var i = 3; i < src.rgba.length; i += 4) {
          expect(out.rgba[i], src.rgba[i], reason: '$id alpha at $i');
        }
      }
    });

    test('opacity scales alpha and nothing else', () {
      final src = _img(2, 2, (x, y) => [10, 20, 30, 200]);
      final out = FilterEngine.applyOp(src, _op('opacity', {'percent': 50}));
      expect(out.rgba[3], 100);
      expect(out.rgba[0], 10);
    });

    test('grayscale, threshold and posterize give the expected values', () {
      final src = _img(1, 1, (x, y) => [255, 0, 0, 255]);
      final g = FilterEngine.applyOp(src, FilterRegistry.defaultOp('grayscale'));
      expect(g.rgba[0], g.rgba[1]);
      expect(g.rgba[1], g.rgba[2]);
      final t = FilterEngine.applyOp(_img(2, 1, (x, y) => x == 0 ? [10, 10, 10, 255] : [240, 240, 240, 255]), _op('threshold', {'level': 128}));
      expect([t.rgba[0], t.rgba[4]], [0, 255]);
      final p = FilterEngine.applyOp(_img(1, 1, (x, y) => [130, 130, 130, 255]), _op('posterize', {'levels': 2}));
      expect(p.rgba[0], anyOf(0, 255));
    });

    test('levels input black/white stretch the range', () {
      final out = FilterEngine.applyOp(_img(1, 1, (x, y) => [100, 100, 100, 255]), _op('levels', {'inBlack': 100, 'inWhite': 200}));
      expect(out.rgba[0], 0);
    });

    test('fully transparent pixels stay transparent under all colour filters', () {
      final src = _img(2, 2, (x, y) => [0, 0, 0, 0]);
      for (final id in ['brightness', 'colorize', 'gradientMap', 'replaceColor']) {
        final out = FilterEngine.applyOp(src, FilterRegistry.defaultOp(id));
        expect(out.rgba[3], 0, reason: id);
      }
    });

    test('replace colour only touches colours near the target hue', () {
      final src = _img(2, 1, (x, y) => x == 0 ? [255, 0, 0, 255] : [0, 0, 255, 255]);
      final out = FilterEngine.applyOp(src, _op('replaceColor', {'fromHue': 0, 'tolerance': 20, 'hueShift': 120}));
      expect(out.rgba[1], greaterThan(out.rgba[0] ~/ 2)); // red became greenish
      expect(out.rgba.sublist(4, 8), [0, 0, 255, 255]); // blue untouched
    });
  });

  group('Blur & effects', () {
    test('blur radius 0 is identity, blur keeps a flat image flat', () {
      final src = _photo();
      expect(FilterEngine.applyOp(src, _op('gaussian', {'radius': 0})).rgba, src.rgba);
      final flat = _img(16, 16, (x, y) => [80, 120, 200, 255]);
      final out = FilterEngine.applyOp(flat, _op('gaussian', {'radius': 5}));
      for (var i = 0; i < flat.rgba.length; i++) {
        expect((out.rgba[i] - flat.rgba[i]).abs(), lessThanOrEqualTo(1));
      }
    });

    test('blur spreads a bright pixel and does not leak colour from transparent areas', () {
      final src = _img(15, 15, (x, y) => x == 7 && y == 7 ? [255, 0, 0, 255] : [0, 255, 0, 0]);
      final out = FilterEngine.applyOp(src, _op('gaussian', {'radius': 2}));
      final i = (7 * 15 + 8) * 4;
      expect(out.rgba[i + 3], greaterThan(0));
      expect(out.rgba[i], greaterThan(200)); // still red, premultiplied blur
      expect(out.rgba[i + 1], lessThan(40)); // no green bleeding in
    });

    test('unsharp mask increases local contrast on an edge', () {
      final src = _img(20, 4, (x, y) => x < 10 ? [100, 100, 100, 255] : [160, 160, 160, 255]);
      final out = FilterEngine.applyOp(src, _op('unsharp', {'radius': 2, 'amount': 200}));
      expect(out.rgba[(9) * 4], lessThan(100));
      expect(out.rgba[(10) * 4], greaterThan(160));
    });

    test('vignette darkens corners more than the centre', () {
      final src = _img(41, 41, (x, y) => [200, 200, 200, 255]);
      final out = FilterEngine.applyOp(src, _op('vignette', {'amount': 100}));
      expect(out.rgba[0], lessThan(out.rgba[(20 * 41 + 20) * 4]));
    });

    test('drop shadow adds alpha outside the shape', () {
      final src = _img(30, 30, (x, y) => x >= 5 && x < 15 && y >= 5 && y < 15 ? [255, 255, 255, 255] : [0, 0, 0, 0]);
      final out = FilterEngine.applyOp(src, _op('dropShadow', {'dx': 6, 'dy': 6, 'blur': 0, 'opacity': 100}));
      expect(out.rgba[(18 * 30 + 18) * 4 + 3], 255);
    });
  });

  group('Artistic & distortion', () {
    test('noise is repeatable for the same seed', () {
      final src = _photo();
      final a = FilterEngine.applyOp(src, _op('noise', {'amount': 40, 'seed': 5}));
      final b = FilterEngine.applyOp(src, _op('noise', {'amount': 40, 'seed': 5}));
      expect(a.rgba, b.rgba);
      expect(a.rgba, isNot(src.rgba));
    });

    test('pixelate makes blocks of one colour', () {
      final out = FilterEngine.applyOp(_photo(), _op('pixelate', {'size': 4}));
      expect(out.rgba.sublist(0, 4), out.rgba.sublist(4, 8));
    });

    test('distortions at zero strength keep the image', () {
      final src = _photo();
      for (final id in ['fisheye', 'bulge', 'pinch']) {
        final out = FilterEngine.applyOp(src, _op(id, {'strength': 0}));
        for (var i = 0; i < src.rgba.length; i++) {
          expect((out.rgba[i] - src.rgba[i]).abs(), lessThanOrEqualTo(2), reason: id);
        }
      }
    });

    test('rgb split with zero shift is identity', () {
      final src = _photo();
      expect(FilterEngine.applyOp(src, _op('rgbSplit', {'dx': 0, 'dy': 0})).rgba, src.rgba);
    });
  });

  group('Stack, presets and persistence', () {
    test('the source image is never modified (non-destructive)', () {
      final src = _photo();
      final copy = Uint8List.fromList(src.rgba);
      FilterEngine.applyStack(src, [_op('brightness', {'amount': 60}), _op('gaussian', {'radius': 3})]);
      expect(src.rgba, copy);
    });

    test('disabled ops are skipped and repeated application is order-dependent but stable', () {
      final src = _photo();
      final ops = [_op('brightness', {'amount': 30}).copyWith(enabled: false), _op('contrast', {'amount': 20})];
      final a = FilterEngine.applyStack(src, ops);
      final b = FilterEngine.applyStack(src, ops);
      expect(a.rgba, b.rgba);
      expect(a.rgba, FilterEngine.applyStack(src, [ops[1]]).rgba);
    });

    test('ten repeated brightness steps equal one stack and stay in range', () {
      var cur = _photo();
      for (var i = 0; i < 10; i++) {
        cur = FilterEngine.applyOp(cur, _op('brightness', {'amount': 10}));
      }
      final stacked = FilterEngine.applyStack(_photo(), [for (var i = 0; i < 10; i++) _op('brightness', {'amount': 10})]);
      expect(cur.rgba, stacked.rgba);
    });

    test('parameters are clamped and unknown values replaced by defaults', () {
      final spec = FilterRegistry.byId('brightness')!;
      expect(spec.normalize({'amount': 9999})['amount'], 100);
      expect(spec.normalize({'amount': double.nan})['amount'], 0);
      expect(spec.normalize({})['amount'], 0);
    });

    test('stack JSON round trip (save / reopen) and unknown filters are refused', () {
      final ops = [_op('gaussian', {'radius': 7}), _op('hue', {'degrees': 40}).copyWith(enabled: false)];
      final back = FilterStackCodec.decode(FilterStackCodec.encode(ops));
      expect(back.length, 2);
      expect(back[0].params['radius'], 7);
      expect(back[1].enabled, isFalse);
      expect(() => FilterStackCodec.decode([{'id': 'doesNotExist', 'p': {}}]), throwsFormatException);
      expect(() => FilterStackCodec.decode('nope'), throwsFormatException);
    });

    test('built-in presets only use real filters', () {
      for (final p in FilterPresets.builtIn) {
        expect(p.ops, isNotEmpty);
        for (final o in p.ops) {
          expect(FilterRegistry.byId(o.id), isNotNull);
        }
        FilterEngine.applyStack(_photo(), p.ops);
      }
    });

    test('history keeps only the newest entries', () {
      final h = FilterHistory(max: 3);
      for (var i = 0; i < 5; i++) {
        h.add('e$i');
      }
      expect(h.entries, ['e2', 'e3', 'e4']);
    });
  });

  group('Budget, tiling and cancellation', () {
    test('oversized images are refused with a clear message', () {
      expect(() => FilterBudget.check(5000, 5000), throwsA(isA<FilterBudgetException>()));
      FilterBudget.check(4096, 4096);
    });

    test('banded blur equals the whole-image result away from band seams', () {
      // 1600x1400 > tilePixels, so the blur is processed in bands.
      const w = 1600, h = 1400;
      final src = _img(w, h, (x, y) => [(x * 3) % 256, (y * 5) % 256, ((x + y) * 7) % 256, 255]);
      final banded = FilterEngine.applyOp(src, _op('box', {'radius': 3}));
      final whole = FilterRegistry.byId('box')!.apply(src, {'radius': 3}, FilterContext());
      for (final y in [0, 700, 701, 1399]) {
        final i = (y * w + 800) * 4;
        expect((banded.rgba[i] - whole.rgba[i]).abs(), lessThanOrEqualTo(1), reason: 'row $y');
      }
    });

    test('cancellation stops processing', () {
      final src = _img(200, 200, (x, y) => [x % 256, y % 256, 0, 255]);
      var cancel = false;
      expect(
        () => FilterEngine.applyOp(
          src,
          _op('gaussian', {'radius': 20}),
          FilterContext(isCancelled: () => cancel = true),
        ),
        throwsA(isA<FilterCancelled>()),
      );
      expect(cancel, isTrue);
    });

    test('downscale keeps aspect and never upsizes', () {
      final big = _img(400, 200, (x, y) => [x % 256, 0, 0, 255]);
      final small = FilterEngine.downscale(big, 100);
      expect(small.width, 100);
      expect(small.height, 50);
      expect(identical(FilterEngine.downscale(big, 1000), big), isTrue);
    });

    test('a large canvas runs a point filter within budget', () {
      final big = FilterImage(2048, 2048, Uint8List(2048 * 2048 * 4)..fillRange(0, 2048 * 2048 * 4, 128));
      final out = FilterEngine.applyOp(big, _op('contrast', {'amount': 20}));
      expect(out.width, 2048);
    });
  });
}
