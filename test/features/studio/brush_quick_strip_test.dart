import 'package:artfoxel/features/studio/application/brush_library_controller.dart';
import 'package:artfoxel/features/studio/data/brush_library_repository.dart';
import 'package:artfoxel/features/studio/domain/builtin_brushes.dart';
import 'package:artfoxel/features/studio/presentation/pressure_curve_editor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<BrushLibraryController> _controller() async {
  final c = BrushLibraryController(
    BrushLibraryRepository(SharedPreferences.getInstance()),
  );
  await c.reload();
  return c;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('default featured slots all exist and are the ten requested', () {
    const data = BrushLibraryData();
    expect(BrushLibraryData.defaultPinned.length, 10);
    expect(data.pinnedBrushes.length, 10);
    expect(data.recommendedBrushes.length, BrushLibraryData.recommended.length);
    expect(data.pinnedBrushes.first.name, 'HB pencil');
  });

  test('pin, unpin, reorder and reset persist across reloads', () async {
    final c = await _controller();
    await c.unpin('builtin.charcoal');
    await c.pin('builtin.pastel');
    await c.movePinned('builtin.pastel', -2);
    var data = (await _controller()).state.value!;
    final ids = data.pinnedBrushes.map((b) => b.id).toList();
    expect(ids.contains('builtin.charcoal'), isFalse);
    expect(ids.indexOf('builtin.pastel'), ids.length - 3);
    await (await _controller()).resetPinned();
    data = (await _controller()).state.value!;
    expect(data.pinned, isNull);
    expect(data.pinnedBrushes.length, 10);
  });

  test('recent keeps newest first without duplicates and caps its size', () async {
    final c = await _controller();
    for (final b in BuiltInBrushes.all.take(20)) {
      await c.noteUsed(b.id);
    }
    await c.noteUsed(BuiltInBrushes.all.first.id);
    final data = (await _controller()).state.value!;
    expect(data.recent.first, BuiltInBrushes.all.first.id);
    expect(data.recent.length, BrushLibraryData.maxRecent);
    expect(data.recent.toSet().length, data.recent.length);
  });

  test('pinned list is capped', () async {
    final c = await _controller();
    var added = 0;
    Object? error;
    for (final b in BuiltInBrushes.all) {
      try {
        await c.pin(b.id);
        added++;
      } catch (e) {
        error = e;
        break;
      }
    }
    expect(error, isNotNull);
    expect((await _controller()).state.value!.pinned!.length, BrushLibraryData.maxPinned);
    expect(added, greaterThan(0));
  });

  test('pressure curve handle maps to the exponent the sampler uses', () {
    expect(PressureCurveEditor.exponentForY(0.5), closeTo(1, 1e-9));
    expect(PressureCurveEditor.exponentForY(0.25), closeTo(2, 1e-9));
    expect(PressureCurveEditor.exponentForY(0.9), lessThan(1));
    expect(PressureCurveEditor.exponentForY(0.001), PressureCurveEditor.maxExponent);
  });
}
