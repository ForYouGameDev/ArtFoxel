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
    this.pinned,
    this.recent = const [],
    this.quarantined = const [],
    this.skippedOnLoad = 0,
    this.recoveredFromCorruption = false,
  });

  final List<BrushPreset> user;
  final Set<String> favorites;

  /// Brush id -> group name.
  final Map<String, String> groups;

  /// Ordered quick-access slots. Null means the user never customised them,
  /// so the featured defaults are shown.
  final List<String>? pinned;

  /// Most recently used brush ids, newest first.
  final List<String> recent;

  static const int maxPinned = 24;
  static const int maxRecent = 14;

  /// The ten featured brushes shown until the user customises the strip.
  static const List<String> defaultPinned = [
    'builtin.hb_pencil',
    'builtin.6b_pencil',
    'builtin.g_pen',
    'builtin.technical_pen',
    'builtin.soft_airbrush',
    'builtin.hard_round',
    'builtin.watercolor',
    'builtin.oil_paint',
    'builtin.basic_smudge',
    'builtin.charcoal',
  ];

  /// Hand-picked suggestions for the Recommended tab.
  static const List<String> recommended = [
    'builtin.2b_pencil',
    'builtin.ink_pen',
    'builtin.dip_pen',
    'builtin.brush_pen',
    'builtin.soft_round',
    'builtin.flat_brush',
    'builtin.gouache',
    'builtin.soft_watercolor',
    'builtin.pastel',
    'builtin.soft_blender',
    'builtin.colour_mixer',
    'builtin.hard_eraser',
  ];

  List<BrushPreset> _resolve(Iterable<String> ids) => [
        for (final id in ids)
          if (byId(id) != null) byId(id)!,
      ];

  /// Quick-access slots, skipping brushes that no longer exist.
  List<BrushPreset> get pinnedBrushes => _resolve(pinned ?? defaultPinned);
  List<BrushPreset> get recentBrushes => _resolve(recent);
  List<BrushPreset> get recommendedBrushes => _resolve(recommended);
  List<BrushPreset> get favoriteBrushes => _resolve(favorites);

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
    List<String>? pinned,
    bool resetPinned = false,
    List<String>? recent,
  }) =>
      BrushLibraryData(
        user: user ?? this.user,
        favorites: favorites ?? this.favorites,
        groups: groups ?? this.groups,
        pinned: resetPinned ? null : (pinned ?? this.pinned),
        recent: recent ?? this.recent,
        quarantined: quarantined,
        skippedOnLoad: skippedOnLoad,
        recoveredFromCorruption: recoveredFromCorruption,
      );

  Map<String, Object?> toJson() => {
        'schema': BrushPreset.schemaVersion,
        'user': [for (final preset in user) preset.toJson()],
        'favorites': favorites.toList()..sort(),
        'groups': groups,
        if (pinned != null) 'pinned': pinned,
        'recent': recent,
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
    List<String>? ids(Object? raw, int max) => raw is List
        ? [
            for (final id in raw)
              if (id is String && id.length <= 64) id,
          ].take(max).toList()
        : null;
    return BrushLibraryData(
      user: user,
      favorites: favorites,
      groups: groups,
      pinned: ids(decoded['pinned'], BrushLibraryData.maxPinned),
      recent: ids(decoded['recent'], BrushLibraryData.maxRecent) ?? const [],
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
