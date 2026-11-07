import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../domain/brush_preset.dart';
import '../domain/builtin_brushes.dart';

/// Everything the user keeps about brushes besides the built-ins.
class BrushLibraryData {
  const BrushLibraryData({
    this.user = const [],
    this.favorites = const {},
    this.groups = const {},
    this.quarantined = const [],
    this.skippedOnLoad = 0,
    this.recoveredFromCorruption = false,
  });

  final List<BrushPreset> user;
  final Set<String> favorites;

  /// Brush id -> group name.
  final Map<String, String> groups;

  /// Raw entries that failed validation. Kept (not deleted) so nothing the
  /// user made is silently lost.
  final List<Map<String, dynamic>> quarantined;
  final int skippedOnLoad;
  final bool recoveredFromCorruption;

  List<BrushPreset> get all => [...BuiltInBrushes.all, ...user];

  BrushPreset? byId(String id) {
    for (final preset in all) {
      if (preset.id == id) return preset;
    }
    return null;
  }

  BrushLibraryData copyWith({
    List<BrushPreset>? user,
    Set<String>? favorites,
    Map<String, String>? groups,
  }) =>
      BrushLibraryData(
        user: user ?? this.user,
        favorites: favorites ?? this.favorites,
        groups: groups ?? this.groups,
        quarantined: quarantined,
        skippedOnLoad: skippedOnLoad,
        recoveredFromCorruption: recoveredFromCorruption,
      );

  Map<String, Object?> toJson() => {
        'schema': BrushPreset.schemaVersion,
        'user': [for (final preset in user) preset.toJson()],
        'favorites': favorites.toList()..sort(),
        'groups': groups,
        'quarantined': quarantined,
      };
}

class BrushLibraryRepository {
  BrushLibraryRepository(this._preferences);

  final Future<SharedPreferences> _preferences;
  static const storageKey = 'brush_library_v1';
  static const maxQuarantined = 50;

  Future<BrushLibraryData> load() async {
    final prefs = await _preferences;
    final raw = prefs.getString(storageKey);
    if (raw == null || raw.isEmpty) return const BrushLibraryData();

    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      // Keep the unreadable text for support/recovery instead of erasing it.
      await prefs.setString('${storageKey}_corrupt', raw);
      return const BrushLibraryData(recoveredFromCorruption: true);
    }
    if (decoded is! Map<String, dynamic>) {
      await prefs.setString('${storageKey}_corrupt', raw);
      return const BrushLibraryData(recoveredFromCorruption: true);
    }

    final user = <BrushPreset>[];
    final quarantined = <Map<String, dynamic>>[];
    final seen = <String>{};
    final rawUser = decoded['user'];
    if (rawUser is List) {
      for (final entry in rawUser) {
        try {
          if (entry is! Map<String, dynamic>) {
            throw const BrushPresetException('Not a brush description.');
          }
          final preset = BrushPreset.fromJson(entry);
          if (preset.isBuiltIn || !seen.add(preset.id)) {
            throw const BrushPresetException('Duplicate or reserved id.');
          }
          user.add(preset);
        } on BrushPresetException {
          if (entry is Map<String, dynamic>) quarantined.add(entry);
        }
      }
    }
    final previouslyQuarantined = decoded['quarantined'];
    if (previouslyQuarantined is List) {
      for (final entry in previouslyQuarantined) {
        if (entry is Map<String, dynamic>) quarantined.add(entry);
      }
    }
    final favorites = <String>{
      if (decoded['favorites'] is List)
        for (final id in decoded['favorites'] as List)
          if (id is String) id,
    };
    final groups = <String, String>{
      if (decoded['groups'] is Map)
        for (final entry in (decoded['groups'] as Map).entries)
          if (entry.key is String && entry.value is String)
            entry.key as String: entry.value as String,
    };
    return BrushLibraryData(
      user: user,
      favorites: favorites,
      groups: groups,
      quarantined: quarantined.take(maxQuarantined).toList(),
      skippedOnLoad: quarantined.length,
    );
  }

  Future<void> save(BrushLibraryData data) async {
    final prefs = await _preferences;
    final saved = await prefs.setString(storageKey, jsonEncode(data.toJson()));
    if (!saved) throw StateError('Brush library could not be saved.');
  }
}
