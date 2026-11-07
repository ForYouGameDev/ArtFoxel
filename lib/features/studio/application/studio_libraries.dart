import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../domain/gradient_model.dart';
import '../domain/palette.dart';
import '../filters/filter_engine.dart';

/// Small on-device libraries for the colour and filter studios. Corrupt or
/// unreadable stored data is ignored (never crashes the studio).
class StudioLibraries {
  StudioLibraries(this._prefs);
  final Future<SharedPreferences> _prefs;

  static const paletteKey = 'palette_library_v1';
  static const gradientKey = 'gradient_library_v1';
  static const filterPresetKey = 'filter_presets_v1';
  static const maxGradients = 50;
  static const maxFilterPresets = 40;

  Future<List<ColorPalette>> loadPalettes() async {
    final raw = (await _prefs).getString(paletteKey);
    if (raw == null) return const [];
    try {
      return PaletteCodec.import(raw);
    } catch (_) {
      return const [];
    }
  }

  Future<void> savePalettes(List<ColorPalette> palettes) async {
    final custom = [for (final p in palettes) if (!p.builtIn) p];
    await (await _prefs).setString(paletteKey, PaletteCodec.export(custom));
  }

  Future<Map<String, GradientData>> loadGradients() async {
    final raw = (await _prefs).getString(gradientKey);
    final out = <String, GradientData>{};
    if (raw == null) return out;
    try {
      final map = jsonDecode(raw);
      if (map is Map) {
        for (final e in map.entries.take(maxGradients)) {
          try {
            out['${e.key}'] = GradientData.fromJson(e.value);
          } on GradientException {
            continue;
          }
        }
      }
    } catch (_) {}
    return out;
  }

  Future<void> saveGradients(Map<String, GradientData> gradients) async {
    if (gradients.length > maxGradients) {
      throw StateError('Too many saved gradients (max $maxGradients).');
    }
    await (await _prefs).setString(
      gradientKey,
      jsonEncode({for (final e in gradients.entries) e.key: e.value.toJson()}),
    );
  }

  Future<List<FilterPreset>> loadFilterPresets() async {
    final raw = (await _prefs).getString(filterPresetKey);
    if (raw == null) return const [];
    final out = <FilterPreset>[];
    try {
      final list = jsonDecode(raw);
      if (list is List) {
        for (final e in list.take(maxFilterPresets)) {
          try {
            if (e is Map && e['name'] is String && e['ops'] is List) {
              out.add(FilterPreset(
                e['name'] as String,
                FilterStackCodec.decode(e['ops']),
              ));
            }
          } on FormatException {
            continue;
          }
        }
      }
    } catch (_) {}
    return out;
  }

  Future<void> saveFilterPresets(List<FilterPreset> presets) async {
    final custom = [for (final p in presets) if (!p.builtIn) p];
    if (custom.length > maxFilterPresets) {
      throw StateError('Too many saved presets (max $maxFilterPresets).');
    }
    await (await _prefs).setString(
      filterPresetKey,
      jsonEncode([for (final p in custom) p.toJson()]),
    );
  }
}
