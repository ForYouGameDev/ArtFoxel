import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Offset, Size;

import 'package:artfoxel/features/studio/domain/assist_model.dart';
import 'package:artfoxel/features/studio/domain/reference_model.dart';
import 'package:artfoxel/features/studio/domain/shape_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Snapping', () {
    test('square grid snaps within tolerance only', () {
      expect(AssistEngine.snapGrid(const Offset(66, 61), GridKind.square, 64, 10), const Offset(64, 64));
      expect(AssistEngine.snapGrid(const Offset(90, 90), GridKind.square, 64, 10), const Offset(90, 90));
    });

    test('guides snap per axis', () {
      final p = AssistEngine.snapGuides(const Offset(103, 55), const [GuideLine(vertical: true, position: 100)], 8);
      expect(p, const Offset(100, 55));
    });

    test('line ruler projects onto the line', () {
      final r = const RulerData(kind: RulerKind.line, a: Offset(0, 0), b: Offset(100, 0), snapStrength: 20);
      expect(AssistEngine.snapToRuler(const Offset(50, 8), r), const Offset(50, 0));
      expect(AssistEngine.snapToRuler(const Offset(50, 80), r), isNull);
    });

    test('circle ruler projects onto the rim', () {
      final r = const RulerData(kind: RulerKind.circle, a: Offset(0, 0), b: Offset(100, 0), snapStrength: 30);
      final p = AssistEngine.snapToRuler(const Offset(90, 0), r)!;
      expect(p.distance, closeTo(100, 1e-6));
    });

    test('parallel ruler snaps to the nearest spaced line', () {
      final r = const RulerData(kind: RulerKind.parallel, a: Offset(0, 0), b: Offset(100, 0), spacing: 50, snapStrength: 20);
      final p = AssistEngine.snapToRuler(const Offset(30, 46), r)!;
      expect(p.dy.abs(), closeTo(50, 1e-6));
    });

    test('rulers off means constrain changes nothing', () {
      expect(AssistEngine.constrain(const Offset(12.3, 4.5), const AssistData()), const Offset(12.3, 4.5));
    });
  });

  group('Symmetry', () {
    test('vertical mirror reflects about the centre', () {
      final m = AssistEngine.symmetryTransforms(const AssistData(symmetry: SymmetryKind.vertical), const Size(200, 100));
      expect(m, hasLength(1));
      final p = AssistEngine.applyTransform(m.single, const Offset(30, 10));
      expect(p.dx, closeTo(170, 1e-9));
      expect(p.dy, closeTo(10, 1e-9));
      expect(AssistEngine.flips(m.single), isTrue);
    });

    test('radial with 4 axes gives 3 rotated copies about the centre', () {
      final m = AssistEngine.symmetryTransforms(
          const AssistData(symmetry: SymmetryKind.radial, symmetryAxes: 4), const Size(200, 200));
      expect(m, hasLength(3));
      final p = AssistEngine.applyTransform(m.first, const Offset(150, 100));
      expect(p.dx, closeTo(100, 1e-6));
      expect(p.dy, closeTo(150, 1e-6));
    });

    test('kaleidoscope with 3 axes makes 5 copies', () {
      final m = AssistEngine.symmetryTransforms(
          const AssistData(symmetry: SymmetryKind.kaleidoscope, symmetryAxes: 3), const Size(100, 100));
      expect(m, hasLength(5));
    });
  });

  group('Assist persistence', () {
    test('round trip keeps everything', () {
      const a = AssistData(
        grid: GridKind.isometric,
        gridSize: 40,
        snapToGrid: true,
        guides: [GuideLine(vertical: true, position: 12)],
        ruler: RulerData(kind: RulerKind.polygon, sides: 7),
        horizonY: 300,
        vanishingPoints: [Offset(10, 300)],
        symmetry: SymmetryKind.radial,
        symmetryAxes: 8,
      );
      expect(AssistData.fromJson(a.toJson()), a);
    });

    test('garbage falls back to defaults instead of failing', () {
      final a = AssistData.fromJson({'grid': 'nope', 'gs': 'x', 'guides': 5, 'sym': 42});
      expect(a.grid, GridKind.none);
      expect(a.isDefault, isTrue);
    });

    test('rulers are never exported implicitly: only rulerAsPoints makes geometry', () {
      expect(AssistEngine.rulerAsPoints(const RulerData()), isEmpty);
      expect(AssistEngine.rulerAsPoints(const RulerData(kind: RulerKind.circle)).length, greaterThan(10));
    });
  });

  group('Shapes', () {
    test('each kind builds a path with sensible bounds', () {
      final r = ShapeData(kind: ShapeKind.rectangle, points: const [Offset(10, 10), Offset(60, 40)], strokeArgb: null);
      expect(r.bounds.width, 50);
      final c = ShapeData(kind: ShapeKind.circle, points: const [Offset(50, 50), Offset(80, 50)], strokeArgb: null);
      expect(c.bounds.width, closeTo(60, 0.5));
      final s = ShapeData(kind: ShapeKind.star, points: const [Offset(0, 0), Offset(50, 0)], sides: 5, strokeArgb: null);
      expect(s.buildPath().getBounds().width, greaterThan(40));
      final b = ShapeData(kind: ShapeKind.cubic, points: const [Offset(0, 0), Offset(10, 50), Offset(60, 50), Offset(70, 0)]);
      expect(b.buildPath().computeMetrics().first.length, greaterThan(70));
    });

    test('wrong point counts and non-finite points are rejected', () {
      expect(() => ShapeData(kind: ShapeKind.line, points: const [Offset(0, 0)]), throwsA(isA<ShapeException>()));
      expect(() => ShapeData(kind: ShapeKind.line, points: const [Offset(0, 0), Offset(double.nan, 1)]),
          throwsA(isA<ShapeException>()));
    });

    test('handles stay editable: moving a point keeps the kind and other points', () {
      final s = ShapeData(kind: ShapeKind.bezier, points: const [Offset(0, 0), Offset(50, 50), Offset(100, 0)]);
      final moved = s.movePoint(1, const Offset(50, 90));
      expect(moved.kind, ShapeKind.bezier);
      expect(moved.points[1], const Offset(50, 90));
      expect(moved.points[0], s.points[0]);
      expect(s.nearestPoint(const Offset(52, 48)), 1);
    });

    test('hit testing: filled interior and outline', () {
      final s = ShapeData(kind: ShapeKind.rectangle, points: const [Offset(0, 0), Offset(100, 100)], fillArgb: 0xFFFF0000);
      expect(s.hits(const Offset(50, 50)), isTrue);
      expect(s.hits(const Offset(300, 300)), isFalse);
    });

    test('JSON round trip', () {
      final s = ShapeData(kind: ShapeKind.polygon, points: const [Offset(5, 5), Offset(40, 5)], sides: 6, fillArgb: 0xFF00FF00, strokeWidth: 3);
      final back = ShapeData.fromJson(s.toJson());
      expect(back.kind, s.kind);
      expect(back.sides, 6);
      expect(back.points, s.points);
      expect(back.fillArgb, 0xFF00FF00);
      expect(() => ShapeData.fromJson({'k': 'blob', 'pts': []}), throwsA(isA<ShapeException>()));
    });
  });

  group('ShapeRecognizer', () {
    List<Offset> circle() => [for (var i = 0; i <= 40; i++) Offset(100 + 50 * math.cos(i / 40 * 2 * math.pi), 100 + 50 * math.sin(i / 40 * 2 * math.pi))];

    test('recognises a clean circle, a line and a rectangle', () {
      expect(ShapeRecognizer.recognize(circle())?.kind, ShapeKind.circle);
      final line = [for (var i = 0; i <= 20; i++) Offset(i * 10.0, i * 5.0 + (i.isEven ? 1 : -1))];
      expect(ShapeRecognizer.recognize(line)?.kind, ShapeKind.line);
      final rect = <Offset>[];
      for (var i = 0; i < 10; i++) {
        rect.add(Offset(i * 10.0, 0));
      }
      for (var i = 0; i < 10; i++) {
        rect.add(Offset(90, i * 8.0));
      }
      for (var i = 0; i < 10; i++) {
        rect.add(Offset(90 - i * 10.0, 72));
      }
      for (var i = 0; i <= 10; i++) {
        rect.add(Offset(0, 72 - i * 7.2));
      }
      expect(ShapeRecognizer.recognize(rect)?.kind, ShapeKind.rectangle);
    });

    test('a scribble or tiny stroke is left alone', () {
      final scribble = [for (var i = 0; i < 60; i++) Offset(i * 3.0, 40 * math.sin(i * 0.9))];
      expect(ShapeRecognizer.recognize(scribble), isNull);
      expect(ShapeRecognizer.recognize([const Offset(0, 0), const Offset(1, 1)]), isNull);
    });
  });

  group('References', () {
    ReferenceImage ref(String id) => ReferenceImage(id: id, name: id, bytes: Uint8List.fromList([1, 2, 3]));

    test('board add / update / remove are independent per image', () {
      var b = const ReferenceBoard().add(ref('a')).add(ref('b'));
      b = b.update('a', (r) => r.copyWith(x: 50, scale: 2, rotation: 1, locked: true, hidden: true));
      expect(b.byId('a')!.x, 50);
      expect(b.byId('b')!.x, 0);
      expect(b.visible.map((r) => r.id), ['b']);
      expect(b.remove('a').images.length, 1);
    });

    test('limits are enforced', () {
      var b = const ReferenceBoard();
      for (var i = 0; i < ReferenceImage.maxImages; i++) {
        b = b.add(ref('r$i'));
      }
      expect(() => b.add(ref('x')), throwsA(isA<ReferenceException>()));
      expect(() => const ReferenceBoard().add(ReferenceImage(id: 'big', name: 'big', bytes: Uint8List(ReferenceImage.maxBytes + 1))),
          throwsA(isA<ReferenceException>()));
    });

    test('meta round trip clamps hostile values', () {
      final back = ReferenceImage.fromMeta({'id': 'q', 'name': 'n', 's': 9999, 'o': -3, 'x': double.nan}, Uint8List.fromList([1]));
      expect(back.scale, lessThanOrEqualTo(50));
      expect(back.opacity, greaterThanOrEqualTo(0.05));
      expect(back.x, 0);
    });

    test('exports exclude references and assists by default', () {
      expect(ExportPlan.standard.includeReferences, isFalse);
      expect(ExportPlan.standard.includeAssists, isFalse);
    });
  });
}
