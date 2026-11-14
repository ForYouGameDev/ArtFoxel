import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/config/app_config.dart';
import '../core/diagnostics/app_log.dart';
import '../core/theme/app_theme.dart';
import '../features/projects/data/project_repository.dart';
import '../features/projects/domain/art_project.dart';
import '../features/settings/data/preferences_repository.dart';

final appConfigProvider = Provider<AppConfig>((ref) {
  return AppConfig.fromEnvironment();
});

final supabaseClientProvider = Provider<SupabaseClient?>((ref) {
  final config = ref.watch(appConfigProvider);
  if (!config.supabaseConfigured) return null;
  try {
    return Supabase.instance.client;
  } on StateError {
    return null;
  }
});

final authStateProvider = StreamProvider<AuthState?>((ref) {
  final client = ref.watch(supabaseClientProvider);
  if (client == null) return const Stream<AuthState?>.empty();
  return client.auth.onAuthStateChange.map((event) => event);
});

final preferencesRepositoryProvider = Provider<PreferencesRepository>((ref) {
  return PreferencesRepository(SharedPreferences.getInstance());
});

final themePreferenceProvider =
    StateNotifierProvider<ThemePreferenceController, AsyncValue<ThemePreference>>(
  (ref) => ThemePreferenceController(ref.watch(preferencesRepositoryProvider)),
);

final onboardingCompleteProvider =
    StateNotifierProvider<OnboardingController, AsyncValue<bool>>(
  (ref) => OnboardingController(ref.watch(preferencesRepositoryProvider)),
);

final projectRepositoryProvider = Provider<ProjectRepository>((ref) {
  return ProjectRepository(SharedPreferences.getInstance());
});

final projectsProvider = FutureProvider<List<ArtProject>>((ref) {
  return ref.watch(projectRepositoryProvider).loadProjects();
});

final projectSortProvider =
    StateProvider<ProjectSort>((ref) => ProjectSort.recentlyUpdated);

final sortedProjectsProvider = Provider<AsyncValue<List<ArtProject>>>((ref) {
  final projects = ref.watch(projectsProvider);
  final sort = ref.watch(projectSortProvider);
  return projects.whenData((items) {
    final sorted = [...items];
    sorted.sort((a, b) => sort == ProjectSort.name
        ? a.name.toLowerCase().compareTo(b.name.toLowerCase())
        : b.updatedAt.compareTo(a.updatedAt));
    return sorted;
  });
});

class ThemePreferenceController
    extends StateNotifier<AsyncValue<ThemePreference>> {
  ThemePreferenceController(this._repository)
      : super(const AsyncValue.loading()) {
    _load();
  }

  final PreferencesRepository _repository;

  Future<void> _load() async {
    try {
      final preference = await _repository.loadTheme();
      if (state.isLoading) state = AsyncValue.data(preference);
    } catch (error, stack) {
      AppLog.error('Theme preference load failed', error: error, stackTrace: stack);
      state = AsyncValue.error(error, stack);
    }
  }

  Future<void> setPreference(ThemePreference preference) async {
    state = AsyncValue.data(preference);
    try {
      await _repository.saveTheme(preference);
    } catch (error, stack) {
      AppLog.error('Theme preference save failed', error: error, stackTrace: stack);
      state = AsyncValue.error(error, stack);
    }
  }
}

class OnboardingController extends StateNotifier<AsyncValue<bool>> {
  OnboardingController(this._repository) : super(const AsyncValue.loading()) {
    _load();
  }

  final PreferencesRepository _repository;

  Future<void> _load() async {
    try {
      state = AsyncValue.data(await _repository.loadOnboardingComplete());
    } catch (error, stack) {
      AppLog.error('Onboarding preference load failed',
          error: error, stackTrace: stack);
      state = AsyncValue.error(error, stack);
    }
  }

  Future<void> complete() async {
    state = const AsyncValue.data(true);
    try {
      await _repository.saveOnboardingComplete(true);
    } catch (error, stack) {
      AppLog.error('Onboarding preference save failed',
          error: error, stackTrace: stack);
      state = AsyncValue.error(error, stack);
    }
  }

  Future<void> revisit() async {
    state = const AsyncValue.data(false);
    try {
      await _repository.saveOnboardingComplete(false);
    } catch (error, stack) {
      AppLog.error('Onboarding preference reset failed',
          error: error, stackTrace: stack);
      state = AsyncValue.error(error, stack);
    }
  }
}
