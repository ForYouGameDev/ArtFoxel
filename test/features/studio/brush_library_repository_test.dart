import 'dart:convert';

import 'package:artfoxel/features/studio/data/brush_library_repository.dart';
import 'package:artfoxel/features/studio/domain/builtin_brushes.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  BrushLibraryRepository repo() =>
      BrushLibraryRepository(SharedPreferences.getInstance());

  test('empty store loads the built-ins only', () async {
    SharedPreferences.setMockInitialValues({});
    final data = await repo().load();
    expect(data.user, isEmpty);
    expect(data.all.length, BuiltInBrushes.all.length);
  });

  test('user brushes and favorites persist', () async {
    SharedPreferences.setMockInitialValues({});
    final custom = BuiltInBrushes.defaultBrush
        .withChanges({'id': 'user.t.1', 'name': 'Custom'});
    await repo().save(BrushLibraryData(user: [custom], favorites: {'user.t.1'}));
    final data = await repo().load();
    expect(data.user.single.name, 'Custom');
    expect(data.favorites, contains('user.t.1'));
  });

  test('invalid entries are quarantined, not deleted', () async {
    final bad = BuiltInBrushes.defaultBrush.toJson()
      ..['id'] = 'user.bad.1'
      ..['size'] = -1;
    SharedPreferences.setMockInitialValues({
      'brush_library_v1': jsonEncode({
        'schema': 1,
        'user': [bad],
        'favorites': <String>[],
        'groups': <String, String>{},
        'quarantined': <Object>[],
      }),
    });
    final data = await repo().load();
    expect(data.user, isEmpty);
    expect(data.skippedOnLoad, 1);
    expect(data.quarantined, hasLength(1));
  });

  test('a corrupt blob does not crash and is preserved', () async {
    SharedPreferences.setMockInitialValues({'brush_library_v1': '{not json'});
    final data = await repo().load();
    expect(data.recoveredFromCorruption, isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('brush_library_v1_corrupt'), '{not json');
  });
}
