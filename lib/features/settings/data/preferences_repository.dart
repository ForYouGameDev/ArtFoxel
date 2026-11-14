import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/theme/app_theme.dart';

class PreferencesRepository {
  PreferencesRepository(this._preferences);

  final Future<SharedPreferences> _preferences;
  static const _themeKey = 'theme_preference';
  static const _onboardingKey = 'onboarding_complete';

  Future<ThemePreference> loadTheme() async {
    final value = (await _preferences).getString(_themeKey);
    return ThemePreference.values.firstWhere(
      (item) => item.name == value,
      orElse: () => ThemePreference.system,
    );
  }

  Future<void> saveTheme(ThemePreference preference) async {
    final saved =
        await (await _preferences).setString(_themeKey, preference.name);
    if (!saved) throw StateError('Theme preference could not be saved.');
  }

  Future<bool> loadOnboardingComplete() async {
    return (await _preferences).getBool(_onboardingKey) ?? false;
  }

  Future<void> saveOnboardingComplete(bool complete) async {
    final saved =
        await (await _preferences).setBool(_onboardingKey, complete);
    if (!saved) throw StateError('Onboarding preference could not be saved.');
  }
}
