import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme/app_theme.dart';
import 'providers.dart';
import 'router.dart';

class ArtFoxelApp extends ConsumerWidget {
  const ArtFoxelApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themePreference = ref.watch(themePreferenceProvider);
    final preference = themePreference.valueOrNull ?? ThemePreference.system;
    return MaterialApp.router(
      title: 'ARTFOXEL',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: switch (preference) {
        ThemePreference.system => ThemeMode.system,
        ThemePreference.light => ThemeMode.light,
        ThemePreference.dark => ThemeMode.dark,
      },
      routerConfig: ref.watch(routerProvider),
    );
  }
}
