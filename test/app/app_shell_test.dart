import 'package:artfoxel/app/artfoxel_app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets(
    'first launch presents scrollable onboarding without layout errors',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(const ProviderScope(child: ArtFoxelApp()));
      await tester.pumpAndSettle();

      expect(find.text('Sketch your ideas'), findsOneWidget);
      expect(find.text('Skip'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('bottom navigation opens the local project gallery', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'onboarding_complete': true});
    await tester.pumpWidget(const ProviderScope(child: ArtFoxelApp()));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.grid_view_outlined));
    await tester.pumpAndSettle();

    expect(find.text('My Projects'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
