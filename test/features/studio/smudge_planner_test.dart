import 'package:artfoxel/features/studio/domain/brush_preset.dart';
import 'package:artfoxel/features/studio/domain/builtin_brushes.dart';
import 'package:artfoxel/features/studio/domain/smudge_planner.dart';
import 'package:artfoxel/features/studio/domain/stroke_model.dart';
import 'package:flutter_test/flutter_test.dart';

BrushPreset _smudge(SmudgeMode mode, {double strength = 0.6}) => BrushPreset(
      id: 'test.smudge',
      name: 'Test',
      category: BrushCategory.smudge,
      engine: BrushEngineKind.smudge,
      size: 30,
      spacing: 0.1,
      smudgeMode: mode,
      smudgeStrength: strength,
    );

SketchStroke _stroke(BrushPreset brush, {bool curved = false}) => SketchStroke(
      brushKey: brush.id,
      colorArgb: 0xFF3366FF,
      size: brush.size,
      opacity: 1,
      flow: 1,
      seed: 7,
      points: [
        for (var i = 0; i <= 40; i++)
          StrokePoint(
            x: 20 + i * 5.0,
            y: curved ? 60 + (i - 20) * (i - 20) * 0.1 : 60,
            t: i * 8,
          ),
      ],
    );

void main() {
  test('planning is deterministic', () {
    final brush = _smudge(SmudgeMode.texture);
    final a = SmudgePlanner.plan(_stroke(brush), brush);
    final b = SmudgePlanner.plan(_stroke(brush), brush);
    expect(a.length, b.length);
    for (var i = 0; i < a.length; i++) {
      expect(a[i].sx, b[i].sx);
      expect(a[i].sy, b[i].sy);
    }
  });

  test('every mode produces ops that move pixels (source != destination)', () {
    for (final mode in SmudgeMode.values) {
      final brush = _smudge(mode);
      final ops = SmudgePlanner.plan(_stroke(brush), brush);
      expect(ops, isNotEmpty, reason: mode.name);
      final moved = ops.any((o) => (o.sx - o.x).abs() + (o.sy - o.y).abs() > 0.5);
      expect(moved, isTrue, reason: mode.name);
      expect(ops.length, lessThanOrEqualTo(SmudgePlanner.maxOps * 3));
    }
  });

  test('modes differ in geometry, not only in a number', () {
    final signatures = <String>{};
    for (final mode in SmudgeMode.values) {
      final brush = _smudge(mode);
      final ops = SmudgePlanner.plan(_stroke(brush, curved: true), brush);
      signatures.add('${ops.length}/${ops[ops.length ~/ 2].radius.toStringAsFixed(2)}/'
          '${ops[ops.length ~/ 2].softness.toStringAsFixed(2)}/'
          '${(ops[ops.length ~/ 2].sx - ops[ops.length ~/ 2].x).toStringAsFixed(1)}');
    }
    expect(signatures.length, SmudgeMode.values.length);
  });

  test('oil uses several lanes, blend averages both sides', () {
    final oil = _smudge(SmudgeMode.oil);
    final basic = _smudge(SmudgeMode.basic);
    expect(SmudgePlanner.plan(_stroke(oil), oil).length,
        greaterThan(SmudgePlanner.plan(_stroke(basic), basic).length * 2));
    final blend = _smudge(SmudgeMode.blend);
    final ops = SmudgePlanner.plan(_stroke(blend), blend);
    // Sources sit beside the stroke (different y), not behind it.
    expect(ops.any((o) => (o.sy - o.y).abs() > 3), isTrue);
  });

  test('directional keeps its source direction on a curved path', () {
    final brush = _smudge(SmudgeMode.directional);
    final ops = SmudgePlanner.plan(_stroke(brush, curved: true), brush);
    final offsets = ops.map((o) => (o.x - o.sx, o.y - o.sy)).toList();
    for (final o in offsets) {
      expect((o.$1 - offsets.first.$1).abs(), lessThan(0.01));
      expect((o.$2 - offsets.first.$2).abs(), lessThan(0.01));
    }
  });

  test('zero-length and single-point strokes plan nothing', () {
    final brush = _smudge(SmudgeMode.basic);
    final one = SketchStroke(
      brushKey: 'x',
      colorArgb: 0xFF000000,
      size: 20,
      opacity: 1,
      flow: 1,
      seed: 1,
      points: [const StrokePoint(x: 5, y: 5, t: 0)],
    );
    expect(SmudgePlanner.plan(one, brush), isEmpty);
  });

  test('deposit only appears when the brush deposits colour', () {
    final none = _smudge(SmudgeMode.basic);
    expect(SmudgePlanner.plan(_stroke(none), none).every((o) => o.deposit == 0), isTrue);
    final dep = BrushPreset(
      id: 'test.dep',
      name: 'Dep',
      category: BrushCategory.smudge,
      engine: BrushEngineKind.smudge,
      deposit: 0.6,
    );
    expect(SmudgePlanner.plan(_stroke(dep), dep).any((o) => o.deposit > 0), isTrue);
  });

  test('smudge presets survive JSON and the library has all 10 modes', () {
    final brush = _smudge(SmudgeMode.oil, strength: 0.8);
    final back = BrushPreset.fromJson(brush.toJson());
    expect(back.smudgeMode, SmudgeMode.oil);
    expect(back.smudgeStrength, 0.8);
    final modes = BuiltInBrushes.all
        .where((b) => b.engine == BrushEngineKind.smudge)
        .map((b) => b.smudgeMode)
        .toSet();
    expect(modes, SmudgeMode.values.toSet());
  });

  test('library is large, unique and valid', () {
    final all = BuiltInBrushes.all;
    expect(all.length, greaterThanOrEqualTo(100));
    expect(all.map((b) => b.id).toSet().length, all.length);
    expect(all.map((b) => b.name).toSet().length, all.length);
    for (final b in all) {
      expect(() => BrushPreset.fromJson(b.toJson()), returnsNormally, reason: b.name);
    }
  });
}
