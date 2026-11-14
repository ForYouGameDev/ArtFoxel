import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Offset, Rect;

import 'package:artfoxel/features/studio/domain/affine2d.dart';
import 'package:artfoxel/features/studio/domain/alpha_mask.dart';
import 'package:artfoxel/features/studio/domain/selection_tools.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _image(int w, int h, List<int> Function(int x, int y) pixel) {
  final out = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      out.setAll((y * w + x) * 4, pixel(x, y));
    }
  }
  return out;
}

void main() {
  group('AlphaMask shapes', () {
    test('rectangle covers exactly its area, including fractional edges', () {
      final m = AlphaMask.rect(20, 20, const Rect.fromLTWH(5, 5, 10, 8));
      expect(m.area, closeTo(80, 0.5));
      expect(m.at(10, 8), 255);
      expect(m.at(2, 2), 0);
      final half = AlphaMask.rect(10, 10, const Rect.fromLTWH(2.5, 2, 4, 4));
      expect(half.at(2, 3), closeTo(128, 3));
    });

    test('ellipse area approximates pi*a*b', () {
      final m = AlphaMask.ellipse(100, 100, const Rect.fromLTWH(10, 20, 60, 40));
      expect(m.area, closeTo(math.pi * 30 * 20, 25));
      expect(m.at(40, 40), 255);
      expect(m.at(11, 21), 0);
    });

    test('polygon handles triangles and degenerate input', () {
      final tri = AlphaMask.polygon(20, 20, const [Offset(0, 0), Offset(20, 0), Offset(0, 20)]);
      expect(tri.area, closeTo(200, 6));
      expect(AlphaMask.polygon(10, 10, const [Offset(1, 1), Offset(5, 5)]).isEmpty, isTrue);
    });

    test('shapes partly outside are clipped, not crashing', () {
      final m = AlphaMask.rect(10, 10, const Rect.fromLTWH(-5, -5, 10, 10));
      expect(m.area, closeTo(25, 0.5));
    });
  });

  group('AlphaMask operations', () {
    final a = AlphaMask.rect(20, 10, const Rect.fromLTWH(0, 0, 12, 10));
    final b = AlphaMask.rect(20, 10, const Rect.fromLTWH(8, 0, 12, 10));

    test('add, subtract, intersect, replace', () {
      expect(a.combine(b, SelectionMode.add).area, closeTo(200, 1));
      expect(a.combine(b, SelectionMode.subtract).area, closeTo(80, 1));
      expect(a.combine(b, SelectionMode.intersect).area, closeTo(40, 1));
      expect(a.combine(b, SelectionMode.replace), b);
      expect(() => a.combine(AlphaMask(5, 5), SelectionMode.add), throwsArgumentError);
    });

    test('invert twice restores', () {
      expect(a.invert().invert().data, a.data);
      expect(a.invert().area, closeTo(200 - a.area, 1e-6));
    });

    test('expand and contract', () {
      final square = AlphaMask.rect(40, 40, const Rect.fromLTWH(15, 15, 10, 10));
      final bigger = square.grow(3);
      expect(bigger.at(13, 20), 255);
      expect(bigger.at(11, 20), 0);
      expect(bigger.area, greaterThan(square.area));
      final smaller = square.grow(-2);
      expect(smaller.at(16, 20), 0);
      expect(smaller.at(20, 20), 255);
      expect(smaller.area, lessThan(square.area));
      expect(square.grow(0), same(square));
    });

    test('contracting past the size empties the mask', () {
      final square = AlphaMask.rect(40, 40, const Rect.fromLTWH(15, 15, 6, 6));
      expect(square.grow(-10).isEmpty, isTrue);
    });

    test('feather softens edges and roughly preserves area', () {
      final square = AlphaMask.rect(60, 60, const Rect.fromLTWH(20, 20, 20, 20));
      final soft = square.feather(6);
      final edge = soft.at(20, 30);
      expect(edge, inInclusiveRange(30, 225));
      expect(soft.at(30, 30), 255);
      expect(soft.area, closeTo(square.area, 15));
      expect(square.feather(0), same(square));
    });

    test('bounds', () {
      final m = AlphaMask.rect(20, 20, const Rect.fromLTWH(4, 6, 5, 3));
      expect(m.bounds(), const Rect.fromLTWH(4, 6, 5, 3));
      expect(AlphaMask(5, 5).bounds(), isNull);
    });

    test('resample translates in document space', () {
      final m = AlphaMask.rect(20, 20, const Rect.fromLTWH(2, 2, 4, 4));
      final moved = m.resampled(
        fromWidth: 20,
        fromHeight: 20,
        toWidth: 20,
        toHeight: 20,
        pixelWidth: 20,
        pixelHeight: 20,
        transform: Affine2D.translation(5, 3),
      );
      expect(moved.at(8, 6), 255);
      expect(moved.at(3, 3), 0);
      expect(moved.area, closeTo(16, 1));
    });

    test('JSON round trip and validation', () {
      final restored = AlphaMask.fromJson(a.toJson());
      expect(restored.data, a.data);
      expect(() => AlphaMask.fromJson({'w': 2, 'h': 2, 'z': 'AAAA'}), throwsFormatException);
      expect(() => AlphaMask.fromJson({'w': -1, 'h': 2, 'z': ''}), throwsFormatException);
      expect(() => AlphaMask.fromJson('x'), throwsFormatException);
    });

    test('sizeFor caps the long side', () {
      expect(AlphaMask.sizeFor(1000, 500), (1000, 500));
      final (w, h) = AlphaMask.sizeFor(4096, 2048);
      expect(w, AlphaMask.maxSide);
      expect(h, 1024);
    });
  });

  group('SelectionTools', () {
    // Left half red, right half blue, one red pixel isolated in blue.
    final pixels = _image(10, 4, (x, y) {
      if (x == 7 && y == 1) return [250, 0, 0, 255];
      return x < 5 ? [255, 0, 0, 255] : [0, 0, 255, 255];
    });

    test('magic wand contiguous selects only the connected area', () {
      final m = SelectionTools.magicWand(pixels, 10, 4, 0, 0, tolerance: 20);
      expect(m.at(0, 0), 255);
      expect(m.at(4, 3), 255);
      expect(m.at(7, 1), 0); // red but not connected
      expect(m.at(6, 1), 0);
    });

    test('non-contiguous mode includes similar pixels elsewhere', () {
      final m = SelectionTools.magicWand(pixels, 10, 4, 0, 0, tolerance: 20, contiguous: false);
      expect(m.at(7, 1), 255);
    });

    test('tolerance widens the match', () {
      final strict = SelectionTools.magicWand(pixels, 10, 4, 0, 0, tolerance: 0);
      final wide = SelectionTools.magicWand(pixels, 10, 4, 0, 0, tolerance: 255);
      expect(strict.area, 20);
      expect(wide.area, 40);
    });

    test('wand outside the image or with a bad buffer', () {
      expect(SelectionTools.magicWand(pixels, 10, 4, -1, 0).isEmpty, isTrue);
      expect(() => SelectionTools.magicWand(Uint8List(3), 10, 4, 0, 0), throwsArgumentError);
    });

    test('colour range with fuzziness', () {
      final grad = _image(5, 1, (x, y) => [x * 20, 0, 0, 255]);
      final m = SelectionTools.colorRange(grad, 5, 1, 0, 0, 0, tolerance: 20, fuzziness: 40);
      expect(m.at(0, 0), 255);
      expect(m.at(1, 0), 255);
      expect(m.at(2, 0), closeTo(128, 1));
      expect(m.at(4, 0), 0);
    });

    test('colour range ignores fully transparent pixels', () {
      final px = _image(2, 1, (x, y) => x == 0 ? [0, 0, 0, 0] : [0, 0, 0, 255]);
      final m = SelectionTools.colorRange(px, 2, 1, 0, 0, 0);
      expect(m.at(0, 0), 0);
      expect(m.at(1, 0), 255);
    });

    test('extract crops to the mask and uses coverage as alpha', () {
      final mask = AlphaMask.rect(10, 4, const Rect.fromLTWH(2, 1, 3, 2));
      final part = SelectionTools.extract(pixels, 10, 4, mask)!;
      expect((part.x, part.y, part.width, part.height), (2, 1, 3, 2));
      expect(part.rgba[0], 255);
      expect(part.rgba[3], 255);
      expect(SelectionTools.extract(pixels, 10, 4, AlphaMask(10, 4)), isNull);
    });
  });
}
