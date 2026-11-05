import 'dart:convert';

import 'package:artfoxel/features/studio/domain/brush_codec.dart';
import 'package:artfoxel/features/studio/domain/brush_preset.dart';
import 'package:artfoxel/features/studio/domain/builtin_brushes.dart';
import 'package:artfoxel/features/studio/domain/stroke_model.dart';
import 'package:artfoxel/features/studio/domain/stroke_sampler.dart';
import 'package:artfoxel/features/studio/domain/stroke_stabilizer.dart';
import 'package:flutter_test/flutter_test.dart';

SketchStroke _line(BrushPreset brush, {double? pressure, int seed = 1}) =>
    SketchStroke(
      brushKey: brush.id,
      colorArgb: 0xFF000000,
      size: brush.size,
      opacity: 1,
      flow: 1,
      seed: seed,
      points: [
        for (var i = 0; i <= 40; i++)
          StrokePoint(x: i * 5.0, y: 20, t: i * 8, pressure: pressure),
      ],
    );

void main() {
  group('built-in brushes', () {
    test('there are at least 11 valid, distinct brushes', () {
      final all = BuiltInBrushes.all;
      expect(all.length, greaterThanOrEqualTo(11));
      expect(all.map((b) => b.id).toSet().length, all.length);
      expect(all.map((b) => b.name).toSet().length, all.length);
      for (final brush in all) {
        expect(brush.isBuiltIn, isTrue);
        expect(BrushPreset.fromJson(brush.toJson()), brush);
      }
      expect(BuiltInBrushes.byId(BuiltInBrushes.defaultId), isNotNull);
    });

    test('categories cover drawing, ink, painting, airbrush and texture', () {
      final categories = BuiltInBrushes.all.map((b) => b.category).toSet();
      expect(
        categories,
        containsAll([
          BrushCategory.drawing,
          BrushCategory.ink,
          BrushCategory.painting,
          BrushCategory.airbrush,
          BrushCategory.texture,
        ]),
      );
    });
  });

  group('preset validation', () {
    test('out-of-range values are rejected', () {
      final json = BuiltInBrushes.defaultBrush.toJson()..['size'] = 99999;
      expect(() => BrushPreset.fromJson(json), throwsA(isA<BrushPresetException>()));
    });

    test('unknown keys are ignored', () {
      final json = BuiltInBrushes.defaultBrush.toJson()..['mystery'] = 1;
      expect(BrushPreset.fromJson(json), BuiltInBrushes.defaultBrush);
    });

    test('withChanges validates', () {
      final brush = BuiltInBrushes.defaultBrush;
      expect(brush.withChanges({'size': 20}).size, 20);
      expect(() => brush.withChanges({'opacity': 5}),
          throwsA(isA<BrushPresetException>()));
    });
  });

  group('codec', () {
    final custom = BuiltInBrushes.defaultBrush
        .withChanges({'id': 'user.a.1', 'name': 'Mine'});

    test('round trip', () {
      final text = BrushCodec.exportPresets([custom]);
      final result = BrushCodec.import(text);
      expect(result.errors, isEmpty);
      expect(result.presets, hasLength(1));
      expect(result.presets.first.name, 'Mine');
      expect(result.presets.first.id, isNot(custom.id));
    });

    test('duplicate names are made unique', () {
      final result = BrushCodec.import(
        BrushCodec.exportPresets([custom]),
        existingNames: ['Mine'],
      );
      expect(result.presets.first.name, 'Mine (2)');
      expect(result.renamed, 1);
    });

    test('too large, not JSON and wrong format are refused', () {
      expect(() => BrushCodec.import('x' * (BrushCodec.maxBytes + 1)),
          throwsA(isA<BrushImportException>()));
      expect(() => BrushCodec.import('not json'),
          throwsA(isA<BrushImportException>()));
      expect(() => BrushCodec.import('[1,2]'),
          throwsA(isA<BrushImportException>()));
    });

    test('newer schema is refused', () {
      final map = jsonDecode(BrushCodec.exportPresets([custom])) as Map;
      map['schema'] = BrushPreset.schemaVersion + 1;
      expect(() => BrushCodec.import(jsonEncode(map)),
          throwsA(isA<BrushImportException>()));
    });

    test('external references are rejected per brush', () {
      final map = jsonDecode(BrushCodec.exportPresets([custom])) as Map;
      (map['presets'] as List).first['url'] = 'https://example.com/tip.png';
      final result = BrushCodec.import(jsonEncode(map));
      expect(result.presets, isEmpty);
      expect(result.errors, hasLength(1));
    });

    test('invalid brush does not block valid ones', () {
      final map = jsonDecode(BrushCodec.exportPresets([custom])) as Map;
      final bad = Map<String, dynamic>.from(custom.toJson())..['size'] = -4;
      (map['presets'] as List).add(bad);
      final result = BrushCodec.import(jsonEncode(map));
      expect(result.presets, hasLength(1));
      expect(result.errors, hasLength(1));
    });
  });

  group('stroke sampler', () {
    final pencil = BuiltInBrushes.defaultBrush;

    test('is deterministic for the same seed', () {
      final a = StrokeSampler.dabs(_line(pencil), pencil);
      final b = StrokeSampler.dabs(_line(pencil), pencil);
      expect(a.length, b.length);
      expect(a.first.x, b.first.x);
      expect(a.last.size, b.last.size);
    });

    test('produces dabs along the stroke and respects spacing', () {
      final dabs = StrokeSampler.dabs(_line(pencil), pencil);
      expect(dabs, isNotEmpty);
      expect(dabs.length, lessThanOrEqualTo(StrokeSampler.maxDabs));
    });

    test('different brushes produce different results', () {
      final ink = BuiltInBrushes.byId('builtin.ink_pen')!;
      final a = StrokeSampler.dabs(_line(pencil), pencil);
      final b = StrokeSampler.dabs(_line(ink), ink);
      expect(a.length == b.length && a.first.size == b.first.size, isFalse);
    });

    test('works without pressure (finger/mouse fallback)', () {
      final dabs = StrokeSampler.dabs(_line(pencil, pressure: null), pencil);
      expect(dabs.every((d) => d.size.isFinite && d.size > 0), isTrue);
    });
  });

  group('stabilizer', () {
    List<StrokePoint> noisy() => [
          for (var i = 0; i < 60; i++)
            StrokePoint(x: i * 4.0, y: 50 + (i.isEven ? 6 : -6), t: i * 8),
        ];

    double wobble(List<StrokePoint> points) {
      var sum = 0.0;
      for (var i = 1; i < points.length; i++) {
        sum += (points[i].y - points[i - 1].y).abs();
      }
      return sum;
    }

    test('smoothing reduces jitter', () {
      final stabilizer = StrokeStabilizer(const StabilizerConfig(strength: 0.8));
      final out = [for (final p in noisy()) stabilizer.add(p)];
      expect(wobble(out), lessThan(wobble(noisy())));
    });

    test('low latency returns raw input unchanged', () {
      final stabilizer = StrokeStabilizer(
        const StabilizerConfig(strength: 0.9, lowLatency: true),
      );
      for (final p in noisy()) {
        final out = stabilizer.add(p);
        expect(out.x, p.x);
        expect(out.y, p.y);
      }
    });

    test('zero strength is raw', () {
      final stabilizer = StrokeStabilizer(const StabilizerConfig());
      final p = noisy()[3];
      expect(stabilizer.add(noisy()[0]).y, noisy()[0].y);
      expect(stabilizer.add(p).y, p.y);
    });
  });
}
