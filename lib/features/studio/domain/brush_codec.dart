import 'dart:convert';

import 'brush_preset.dart';

/// The whole file cannot be imported (too large, not JSON, wrong format,
/// newer version). Problems with single brushes are reported in
/// [BrushImportResult.errors] instead.
class BrushImportException implements Exception {
  const BrushImportException(this.message);

  final String message;

  @override
  String toString() => message;
}

class BrushImportResult {
  const BrushImportResult({
    required this.presets,
    required this.errors,
    required this.migrated,
    required this.renamed,
  });

  /// Valid presets, already given fresh ids and unique names.
  final List<BrushPreset> presets;

  /// One readable message per brush that was rejected.
  final List<String> errors;

  /// Presets upgraded from an older schema.
  final int migrated;

  /// Presets whose names were changed to avoid duplicates.
  final int renamed;
}

/// Reads and writes brush presets and brush sets as JSON.
///
/// Import is data-only by design: unknown keys are ignored, nothing is
/// evaluated, and files, URLs or external textures are rejected, so an
/// imported brush can never execute code or read other files.
abstract final class BrushCodec {
  static const String formatName = 'artfoxel-brush-set';
  static const int maxBytes = 512 * 1024;
  static const int maxPresets = 200;

  /// Keys that would reference something outside the preset itself.
  static const Set<String> _externalKeys = {
    'texture',
    'textureRef',
    'texturePath',
    'tipImage',
    'image',
    'url',
    'uri',
    'path',
    'file',
    'script',
    'code',
    'shader',
  };

  static int _counter = 0;

  static String exportPresets(
    List<BrushPreset> presets, {
    String name = 'ARTFOXEL brushes',
  }) {
    return const JsonEncoder.withIndent('  ').convert({
      'format': formatName,
      'schema': BrushPreset.schemaVersion,
      'name': name,
      'presets': [for (final preset in presets) preset.toJson()],
    });
  }

  static String exportPreset(BrushPreset preset) =>
      exportPresets([preset], name: preset.name);

  /// Case-insensitive unique name: "Pen", "Pen (2)", "Pen (3)"…
  static String uniqueName(String name, Iterable<String> existing) {
    final taken = {for (final value in existing) value.toLowerCase()};
    if (!taken.contains(name.toLowerCase())) return name;
    for (var i = 2;; i++) {
      final suffix = ' ($i)';
      final base = name.length + suffix.length > BrushPreset.maxNameLength
          ? name.substring(0, BrushPreset.maxNameLength - suffix.length).trim()
          : name;
      final candidate = '$base$suffix';
      if (!taken.contains(candidate.toLowerCase())) return candidate;
    }
  }

  /// Creates an id that is valid, unique enough for local use, and never
  /// collides with a built-in brush.
  static String newUserId() {
    _counter++;
    final stamp = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    return 'user.$stamp.$_counter';
  }

  static BrushImportResult import(
    String text, {
    Iterable<String> existingNames = const [],
  }) {
    if (utf8.encode(text).length > maxBytes) {
      throw const BrushImportException(
        'This file is larger than ${maxBytes ~/ 1024} KB, which is the '
        'limit for brush files.',
      );
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      throw const BrushImportException(
        'This is not a valid brush file (the JSON could not be read).',
      );
    }
    if (decoded is! Map<String, dynamic>) {
      throw const BrushImportException(
        'This is not an ARTFOXEL brush file.',
      );
    }

    final List<Object?> rawPresets;
    if (decoded['format'] == formatName) {
      final schema = decoded['schema'];
      if (schema is! int || schema < 0) {
        throw const BrushImportException('The brush set has no valid version.');
      }
      if (schema > BrushPreset.schemaVersion) {
        throw BrushImportException(
          'This brush set was made by a newer version of ARTFOXEL '
          '(schema $schema). Update the app to import it.',
        );
      }
      final list = decoded['presets'];
      if (list is! List) {
        throw const BrushImportException('The brush set contains no brushes.');
      }
      if (list.length > maxPresets) {
        throw const BrushImportException(
          'The brush set has more than $maxPresets brushes.',
        );
      }
      rawPresets = List<Object?>.of(list);
    } else if (decoded.containsKey('name')) {
      rawPresets = [decoded]; // a single bare preset
    } else {
      throw const BrushImportException('This is not an ARTFOXEL brush file.');
    }

    final names = <String>[...existingNames];
    final presets = <BrushPreset>[];
    final errors = <String>[];
    var migrated = 0;
    var renamed = 0;

    for (var i = 0; i < rawPresets.length; i++) {
      final raw = rawPresets[i];
      final label = raw is Map && raw['name'] is String
          ? 'Brush ${i + 1} (${raw['name']})'
          : 'Brush ${i + 1}';
      if (raw is! Map<String, dynamic>) {
        errors.add('$label: not a brush description.');
        continue;
      }
      final external = raw.keys.where(_externalKeys.contains).toList();
      if (external.isNotEmpty) {
        errors.add(
          '$label: references external content (${external.join(', ')}), '
          'which brushes cannot use.',
        );
        continue;
      }
      try {
        var map = Map<String, dynamic>.of(raw);
        final schema = map['schema'];
        if (schema == null || schema == 0) {
          map = _migrateV0(map);
          migrated++;
        }
        map['id'] = newUserId();
        final parsed = BrushPreset.fromJson(map);
        final name = uniqueName(parsed.name, names);
        if (name != parsed.name) renamed++;
        names.add(name);
        presets.add(name == parsed.name ? parsed : parsed.withChanges({'name': name}));
      } on BrushPresetException catch (error) {
        errors.add('$label: ${error.message}');
      }
    }
    return BrushImportResult(
      presets: presets,
      errors: errors,
      migrated: migrated,
      renamed: renamed,
    );
  }

  /// Schema 0 was the flat pre-release layout: a name and a few basic
  /// numbers, with a free-text `type`. Everything else takes safe defaults.
  static Map<String, dynamic> _migrateV0(Map<String, dynamic> old) {
    const keep = ['name', 'size', 'opacity', 'hardness', 'spacing', 'flow'];
    final migrated = <String, dynamic>{'schema': BrushPreset.schemaVersion};
    for (final key in keep) {
      if (old.containsKey(key)) migrated[key] = old[key];
    }
    final type = (old['category'] ?? old['type'])?.toString().toLowerCase();
    migrated['category'] = BrushCategory.values
            .where((category) => category.name == type)
            .map((category) => category.name)
            .firstOrNull ??
        BrushCategory.drawing.name;
    migrated['engine'] = BrushEngineKind.stamp.name;
    return migrated;
  }
}
