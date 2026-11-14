import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:artfoxel/features/studio/engine/guides_selection.dart';
import 'package:artfoxel/features/studio/engine/fill_clone.dart';

Uint8List _img(int w, int h, int Function(int x, int y) f) {
  final u = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final c = f(x, y);
      final i = (y * w + x) * 4;
      u[i] = (c >> 16) & 255;
      u[i + 1] = (c >> 8) & 255;
      u[i + 2] = c & 255;
      u[i + 3] = (c >> 24) & 255;
    }
  }
  return u;
}

const _white = 0xFFFFFFFF, _black = 0xFF000000;

void main() {
  group('guide snapping', () {
    test('line / parallel / perpendicular', () {
      expect(snapToLine(const Pt(5, 3), const Pt(0, 0), const Pt(10, 0)), const Pt(5, 0));
      final par = snapToParallel(const Pt(5, 7), const Pt(0, 5), const Pt(0, 0), const Pt(10, 0));
      expect(par.y, closeTo(5, 1e-9));
      final per = snapToPerpendicular(const Pt(7, 3), const Pt(2, 0), const Pt(0, 0), const Pt(10, 0));
      expect(per.x, closeTo(2, 1e-9));
    });
    test('circle, ellipse, arc', () {
      expect(snapToCircle(const Pt(20, 0), const Pt(0, 0), 10).x, closeTo(10, 1e-9));
      final e = snapToEllipse(const Pt(30, 0), const Pt(0, 0), 20, 10);
      expect(e.x, closeTo(20, 0.05));
      expect(e.y.abs(), lessThan(0.05));
      // Arc covers the top half only (0 → pi sweeping through +y in screen coords)
      final a = snapToArc(const Pt(0, 50), const Pt(0, 0), 10, 0, math.pi);
      expect(a.y, closeTo(10, 1e-6));
      final outside = snapToArc(const Pt(0, -50), const Pt(0, 0), 10, 0, math.pi);
      expect(outside.y.abs(), lessThan(1e-6)); // clamps to an endpoint
    });
    test('bezier flatten endpoints and polyline snap', () {
      final pts = flattenCubic(const Pt(0, 0), const Pt(0, 10), const Pt(10, 10), const Pt(10, 0));
      expect(pts.first, const Pt(0, 0));
      expect(pts.last.x, closeTo(10, 1e-9));
      final s = snapToPolyline(const Pt(5, 5), const [Pt(0, 0), Pt(10, 0)]);
      expect(s, const Pt(5, 0));
      final closed = snapToPolyline(const Pt(5, 5), const [Pt(0, 0), Pt(10, 0), Pt(10, 10)], closed: true);
      expect(closed.distanceTo(const Pt(5, 5)), closeTo(0, 1e-9));
    });
    test('hatching lines stay inside the rect', () {
      final l = hatchingLines(100, 50, math.pi / 4, 10);
      expect(l, isNotEmpty);
      for (final (a, b) in l) {
        for (final p in [a, b]) {
          expect(p.x, inInclusiveRange(-1e-6, 100 + 1e-6));
          expect(p.y, inInclusiveRange(-1e-6, 50 + 1e-6));
        }
      }
    });
  });

  group('perspective', () {
    test('one-point: strokes snap toward the VP', () {
      final g = PerspectiveGrid(kind: GridKind.onePoint, width: 1000, height: 1000);
      final o = const Pt(100, 100);
      final p = g.snap(o, const Pt(300, 310)); // roughly toward VP (500,500)
      final vp = g.vanishing.first;
      final cross = ((p.x - o.x) * (vp.y - o.y) - (p.y - o.y) * (vp.x - o.x)).abs();
      expect(cross, lessThan(1e-6));
    });
    test('two/three point defaults and horizon edit', () {
      final g = PerspectiveGrid(kind: GridKind.threePoint, width: 1000, height: 800);
      expect(g.vanishing.length, 3);
      g.setHorizon(200);
      expect(g.vanishing[0].y, 200);
      expect(g.vanishing[2].y, isNot(200)); // third VP is free
      g.moveVanishing(0, const Pt(-300, 999));
      expect(g.vanishing[0].y, 200); // stays on horizon
    });
    test('isometric directions are 30/150/90', () {
      final g = PerspectiveGrid(kind: GridKind.isometric, width: 100, height: 100);
      final d = g.directionsAt(const Pt(0, 0));
      expect(d.length, 3);
      final s = g.snap(const Pt(0, 0), const Pt(10, 0.5));
      expect((s.y / s.x).abs(), closeTo(math.tan(30 * math.pi / 180), 1e-6));
    });
    test('curvilinear and lines generation, JSON', () {
      final c = PerspectiveGrid(kind: GridKind.curvilinear, width: 400, height: 400);
      expect(c.lines(), isNotEmpty);
      final back = PerspectiveGrid.fromJson(jsonDecode(jsonEncode(c.toJson())));
      expect(back.kind, GridKind.curvilinear);
      expect(back.vanishing.first, c.vanishing.first);
    });
  });

  group('selection masks', () {
    SelectionMask rect(int w, int h, int x0, int y0, int x1, int y1) {
      final m = SelectionMask(w, h);
      for (var y = y0; y < y1; y++) {
        for (var x = x0; x < x1; x++) {
          m.data[y * w + x] = 255;
        }
      }
      return m;
    }

    test('add / subtract / intersect / invert', () {
      final a = rect(10, 10, 0, 0, 6, 10), b = rect(10, 10, 4, 0, 10, 10);
      expect(a.combine(b, SelectionOp.add).selectedCount, 100);
      expect(a.combine(b, SelectionOp.subtract).selectedCount, 40);
      expect(a.combine(b, SelectionOp.intersect).selectedCount, 20);
      expect(a.invert().selectedCount, 40);
      expect(a.combine(b, SelectionOp.replace).selectedCount, 60);
    });
    test('size mismatch throws', () {
      expect(() => SelectionMask(2, 2).combine(SelectionMask(3, 3), SelectionOp.add), throwsArgumentError);
    });
    test('grow, shrink, border, smooth, feather', () {
      final m = rect(20, 20, 8, 8, 12, 12);
      expect(m.grow(1).selectedCount, 36);
      expect(m.grow(-1).selectedCount, 4);
      expect(m.border(1).selectedCount, greaterThan(0));
      expect(m.border(1).at(10, 10), 0);
      final f = m.feather(2);
      expect(f.at(10, 10), greaterThan(0));
      expect(f.at(10, 10), lessThan(256));
      expect(f.selectedCount, greaterThan(m.selectedCount));
      expect(m.smooth(1).selectedCount, lessThanOrEqualTo(m.selectedCount));
    });
    test('polygon rasterisation area matches', () {
      final m = SelectionBuilders.fromPolygon(20, 20, const [Pt(2, 2), Pt(12, 2), Pt(12, 12), Pt(2, 12)]);
      expect(m.selectedCount, 100);
      final tri = SelectionBuilders.fromPolygon(40, 40, const [Pt(0, 0), Pt(30, 0), Pt(0, 30)]);
      var sum = 0;
      for (final v in tri.data) {
        sum += v;
      }
      expect(sum / 255, closeTo(450, 8));
    });
    test('bezier path selection', () {
      final m = SelectionBuilders.fromBezierPath(40, 40, const [
        (Pt(5, 5), Pt(5, 5), Pt(35, 5), Pt(35, 5)),
        (Pt(35, 5), Pt(35, 35), Pt(35, 35), Pt(35, 35)),
        (Pt(35, 35), Pt(5, 35), Pt(5, 35), Pt(5, 5)),
      ]);
      expect(m.at(20, 20), greaterThan(0));
      expect(m.at(1, 1), 0);
    });
    test('brush dab add and erase', () {
      final m = SelectionMask(20, 20);
      SelectionBuilders.brushDab(m, 10, 10, 5);
      expect(m.at(10, 10), 255);
      expect(m.at(0, 0), 0);
      SelectionBuilders.brushDab(m, 10, 10, 5, erase: true);
      expect(m.isEmpty, isTrue);
    });
    test('transparency selection', () {
      final px = _img(4, 1, (x, y) => x < 2 ? 0x00000000 : _black);
      expect(SelectionBuilders.fromAlpha(4, 1, px).selectedCount, 2);
      expect(SelectionBuilders.fromAlpha(4, 1, px, opaque: false).selectedCount, 2);
      expect(() => SelectionBuilders.fromAlpha(4, 4, px), throwsArgumentError);
    });
    test('save/load, layer mask, JSON RLE', () {
      final m = rect(16, 16, 3, 3, 9, 9);
      final s = SavedSelections();
      expect(s.save('a', m), isTrue);
      m.data[0] = 7; // original changed after saving
      expect(s.load('a')!.data[0], 0);
      final j = SelectionMask.fromJson(jsonDecode(jsonEncode(m.toJson())));
      expect(j.data, m.data);
      expect(SelectionMask.fromLayerMask(16, 16, m.toLayerMask()).data, m.data);
      expect(() => SelectionMask.fromJson({'w': 2, 'h': 2, 'rle': [0, 3]}), throwsFormatException);
    });
  });

  group('bucket fill', () {
    test('fills enclosed region only', () {
      final px = _img(20, 20, (x, y) => (x == 10 ? _black : _white));
      final m = BucketFill.compute(px, 20, 20, 2, 5, const FillOptions(antiAlias: false));
      expect(m.selectedCount, 10 * 20);
      expect(m.at(10, 5), 0);
      expect(m.at(15, 5), 0);
    });
    test('tolerance includes near colours', () {
      final px = _img(10, 1, (x, y) => x < 5 ? 0xFF808080 : 0xFF8A8A8A);
      expect(BucketFill.compute(px, 10, 1, 0, 0, const FillOptions(tolerance: 0, antiAlias: false)).selectedCount, 5);
      expect(BucketFill.compute(px, 10, 1, 0, 0, const FillOptions(tolerance: 20, antiAlias: false)).selectedCount, 10);
    });
    test('gap closing stops leaks through a small gap', () {
      // vertical wall at x=10 with a 2px gap at y=9..10
      final px = _img(24, 20, (x, y) => (x == 10 && y != 9 && y != 10) ? _black : _white);
      final leak = BucketFill.compute(px, 24, 20, 2, 2, const FillOptions(antiAlias: false));
      expect(leak.at(20, 2), 255, reason: 'without gap closing the fill leaks');
      final closed = BucketFill.compute(px, 24, 20, 2, 2, const FillOptions(gapClose: 4, antiAlias: false));
      expect(closed.at(20, 2), 0, reason: 'gap closing keeps it contained');
      expect(closed.at(2, 2), 255);
    });
    test('colour range (non-contiguous) picks every match', () {
      final px = _img(10, 1, (x, y) => x % 2 == 0 ? _white : _black);
      expect(BucketFill.compute(px, 10, 1, 0, 0, const FillOptions(contiguous: false, colorRange: true, antiAlias: false)).selectedCount, 5);
      expect(BucketFill.compute(px, 10, 1, 0, 0, const FillOptions(antiAlias: false)).selectedCount, 1);
    });
    test('transparent pixels all match regardless of RGB', () {
      final px = _img(4, 1, (x, y) => x == 0 ? 0x00FF0000 : 0x0000FF00);
      expect(BucketFill.compute(px, 4, 1, 0, 0, const FillOptions(tolerance: 0, antiAlias: false)).selectedCount, 4);
    });
    test('edge/out-of-range clicks and size safeguards', () {
      final px = _img(5, 5, (x, y) => _white);
      expect(BucketFill.compute(px, 5, 5, -1, 0).isEmpty, isTrue);
      expect(BucketFill.compute(px, 5, 5, 4, 4, const FillOptions(antiAlias: false)).selectedCount, 25);
      expect(() => BucketFill.compute(px, 5, 5, 0, 0, const FillOptions(maxPixels: 10)), throwsA(isA<FillException>()));
      expect(() => BucketFill.compute(Uint8List(3), 5, 5, 0, 0), throwsA(isA<FillException>()));
    });
    test('large region fills without recursion problems', () {
      const n = 600;
      final px = Uint8List(n * n * 4)..fillRange(0, n * n * 4, 255);
      final m = BucketFill.compute(px, n, n, 300, 300, const FillOptions(antiAlias: false));
      expect(m.selectedCount, n * n);
    });
    test('anti-alias softens only the fill boundary', () {
      final px = _img(10, 10, (x, y) => x < 5 ? _white : _black);
      final m = BucketFill.compute(px, 10, 10, 0, 0);
      expect(m.at(4, 5), 170);
      expect(m.at(1, 5), 255);
    });
  });

  group('fill paint and clone', () {
    test('solid apply honours mask and opacity', () {
      final dst = Uint8List(4 * 4)..fillRange(0, 16, 0);
      final m = SelectionMask(4, 1)..data[1] = 255;
      FillPaint.apply(dst, 4, 1, m, FillPaint.solid(0xFFFF0000), opacity: 0.5);
      expect(dst[3], 0);
      expect(dst[4], 255);
      expect(dst[7], closeTo(128, 1));
    });
    test('gradient and pattern sources', () {
      final g = FillPaint.linearGradient(const Pt(0, 0), const Pt(10, 0), const [(0.0, _black), (1.0, _white)]);
      expect(g(0, 0) & 0xFF, lessThan(20));
      expect(g(9, 0) & 0xFF, greaterThan(230));
      expect(() => FillPaint.linearGradient(const Pt(0, 0), const Pt(1, 0), const [(0.0, _black)]), throwsA(isA<FillException>()));
      final tile = _img(2, 2, (x, y) => (x + y).isEven ? _black : _white);
      final p = FillPaint.pattern(tile, 2, 2);
      expect(p(0, 0), _black);
      expect(p(1, 0), _white);
      expect(p(2, 0), _black);
      expect(p(-1, 0), _white);
    });
    test('clone stamp copies source texture at the aligned offset', () {
      const w = 40, h = 20;
      // left half red, right half blue
      final src = _img(w, h, (x, y) => x < 20 ? 0xFFFF0000 : 0xFF0000FF);
      final dst = Uint8List(w * h * 4);
      final cs = CloneStamp(srcAnchor: const Pt(30, 10)); // sample the blue side
      cs.beginStroke(const Pt(5, 10));
      cs.stamp(src, dst, w, h, 5.5, 10.5, 3, hardness: 1);
      final i = (10 * w + 5) * 4;
      expect(dst[i + 2], 255);
      expect(dst[i], 0);
      expect(dst[i + 3], 255);
    });
    test('aligned keeps offset across strokes; non-aligned resets', () {
      final a = CloneStamp(srcAnchor: const Pt(30, 30))..beginStroke(const Pt(5, 5));
      a.beginStroke(const Pt(50, 50)); // aligned: offset from the first stroke is kept
      expect(a.sourceFor(50, 50).x, closeTo(75, 1e-9));
      final b = CloneStamp(srcAnchor: const Pt(30, 30), aligned: false)..beginStroke(const Pt(5, 5));
      b.beginStroke(const Pt(50, 50));
      expect(b.sourceFor(50, 50).x, closeTo(30, 1e-9));
      expect(b.sourceFor(55, 50).x, closeTo(35, 1e-9));
    });
    test('rotation and scale transform the sampling vector', () {
      final c = CloneStamp(srcAnchor: const Pt(0, 0), rotationRad: math.pi / 2, scale: 2)..beginStroke(const Pt(0, 0));
      final s = c.sourceFor(10, 0);
      expect(s.x, closeTo(0, 1e-9));
      expect(s.y, closeTo(-5, 1e-9));
    });
    test('bilinear sampling has no dark fringe on transparent edges', () {
      final px = _img(2, 1, (x, y) => x == 0 ? 0xFFFF0000 : 0x00000000);
      final c = CloneStamp.sampleBilinear(px, 2, 1, 0.5, 0);
      expect(c[0], 255);
      expect(c[3], closeTo(128, 1));
    });
  });
}
