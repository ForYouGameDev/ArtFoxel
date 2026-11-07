import 'dart:convert';

import 'color_math.dart';

class PaletteException implements Exception {
  const PaletteException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// A named list of colours.
class ColorPalette {
  const ColorPalette({
    required this.id,
    required this.name,
    required this.colors,
    this.builtIn = false,
  });

  static const int maxColors = 128;
  static const int maxNameLength = 40;

  final String id;
  final String name;
  final List<int> colors;
  final bool builtIn;

  ColorPalette copyWith({String? name, List<int>? colors}) => ColorPalette(
        id: id,
        name: name ?? this.name,
        colors: colors ?? this.colors,
        builtIn: builtIn,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'colors': [for (final c in colors) ColorMath.toHex(c)],
      };

  static ColorPalette fromJson(Object? raw, {bool builtIn = false}) {
    if (raw is! Map) throw const PaletteException('A palette must be an object.');
    final id = raw['id'], name = raw['name'], colors = raw['colors'];
    if (id is! String || id.isEmpty || id.length > 64) {
      throw const PaletteException('A palette needs an id.');
    }
    if (name is! String || name.trim().isEmpty) {
      throw const PaletteException('A palette needs a name.');
    }
    if (colors is! List || colors.length > maxColors) {
      throw const PaletteException('A palette can hold at most $maxColors colours.');
    }
    return ColorPalette(
      id: id,
      name: name.trim().length > maxNameLength ? name.trim().substring(0, maxNameLength) : name.trim(),
      colors: [
        for (final c in colors)
          ColorMath.parseHex(c is String ? c : '') ??
              (throw PaletteException('"$c" is not a valid HEX colour.')),
      ],
      builtIn: builtIn,
    );
  }
}

abstract final class BuiltInPalettes {
  static const all = <ColorPalette>[
    ColorPalette(id: 'builtin.basic', name: 'Basic', builtIn: true, colors: [
      0xFF111111, 0xFF5A5A5A, 0xFFFFFFFF, 0xFFE53935, 0xFFFB8C00, 0xFFFDD835,
      0xFF43A047, 0xFF00ACC1, 0xFF1E88E5, 0xFF5E35B1, 0xFFD81B60, 0xFF8D6E63,
    ]),
    ColorPalette(id: 'builtin.skin', name: 'Skin tones', builtIn: true, colors: [
      0xFFFFE0D0, 0xFFF5CBA7, 0xFFE0AC69, 0xFFC68642, 0xFF8D5524, 0xFF5C3A21, 0xFF3B2219,
    ]),
    ColorPalette(id: 'builtin.pastel', name: 'Pastel', builtIn: true, colors: [
      0xFFFFB3BA, 0xFFFFDFBA, 0xFFFFFFBA, 0xFFBAFFC9, 0xFFBAE1FF, 0xFFD5BAFF,
    ]),
    ColorPalette(id: 'builtin.earth', name: 'Earth', builtIn: true, colors: [
      0xFF3E2C1C, 0xFF6B4F2A, 0xFF8A7650, 0xFFB5A27A, 0xFF5E6B3A, 0xFF2F3E2C,
    ]),
    ColorPalette(id: 'builtin.gray', name: 'Grayscale', builtIn: true, colors: [
      0xFF000000, 0xFF222222, 0xFF444444, 0xFF666666, 0xFF888888, 0xFFAAAAAA, 0xFFCCCCCC, 0xFFFFFFFF,
    ]),
  ];
}

/// Palette import/export. Palettes are data only (colour lists); nothing is
/// executed and no external references are followed.
abstract final class PaletteCodec {
  static const String format = 'artfoxel-palette';
  static const int schema = 1;
  static const int maxBytes = 128 * 1024;
  static const int maxPalettes = 50;

  static String export(List<ColorPalette> palettes) => const JsonEncoder.withIndent('  ').convert({
        'format': format,
        'schema': schema,
        'palettes': [for (final p in palettes) p.toJson()],
      });

  /// GIMP `.gpl` text for one palette.
  static String exportGpl(ColorPalette p) {
    final b = StringBuffer('GIMP Palette\nName: ${p.name}\nColumns: 8\n#\n');
    for (final c in p.colors) {
      b.writeln('${ColorMath.red(c).toString().padLeft(3)} '
          '${ColorMath.green(c).toString().padLeft(3)} '
          '${ColorMath.blue(c).toString().padLeft(3)}\t${ColorMath.toHex(c)}');
    }
    return b.toString();
  }

  /// Imports ARTFOXEL JSON, a bare JSON palette, or GIMP `.gpl` text. New ids
  /// are assigned by the caller; names are made unique against
  /// [existingNames].
  static List<ColorPalette> import(String text, {Iterable<String> existingNames = const []}) {
    if (utf8.encode(text).length > maxBytes) {
      throw const PaletteException('That palette file is too large (limit 128 KB).');
    }
    final trimmed = text.trim();
    if (trimmed.isEmpty) throw const PaletteException('There is nothing to import.');
    final names = {for (final n in existingNames) n.toLowerCase()};
    final out = <ColorPalette>[];
    ColorPalette take(ColorPalette p, int n) {
      var name = p.name, i = 2;
      while (names.contains(name.toLowerCase())) {
        name = '${p.name} ($i)';
        i++;
      }
      names.add(name.toLowerCase());
      return ColorPalette(id: 'user.${DateTime.now().microsecondsSinceEpoch}.$n', name: name, colors: p.colors);
    }

    if (trimmed.startsWith('GIMP Palette')) {
      out.add(take(_parseGpl(trimmed), 0));
      return out;
    }
    Object? decoded;
    try {
      decoded = jsonDecode(trimmed);
    } on FormatException {
      throw const PaletteException('That is not a palette file (expected JSON or GIMP .gpl).');
    }
    if (decoded is! Map) throw const PaletteException('That is not a palette file.');
    if (decoded.containsKey('format') && decoded['format'] != format) {
      throw const PaletteException('That file is not an ARTFOXEL palette.');
    }
    final schemaValue = decoded['schema'];
    if (schemaValue is int && schemaValue > schema) {
      throw const PaletteException('That palette was made by a newer version of ARTFOXEL.');
    }
    final list = decoded['palettes'] ?? [decoded];
    if (list is! List || list.isEmpty || list.length > maxPalettes) {
      throw const PaletteException('The file contains no usable palettes.');
    }
    for (var i = 0; i < list.length; i++) {
      final raw = list[i];
      if (raw is Map && raw['id'] == null) {
        raw['id'] = 'import.$i';
      }
      out.add(take(ColorPalette.fromJson(raw), i));
    }
    return out;
  }

  static ColorPalette _parseGpl(String text) {
    var name = 'Imported palette';
    final colors = <int>[];
    for (final line in const LineSplitter().convert(text).skip(1)) {
      final l = line.trim();
      if (l.isEmpty || l.startsWith('#')) continue;
      if (l.startsWith('Name:')) {
        name = l.substring(5).trim();
        continue;
      }
      if (l.startsWith('Columns:')) continue;
      final m = RegExp(r'^(\d{1,3})\s+(\d{1,3})\s+(\d{1,3})').firstMatch(l);
      if (m == null) throw PaletteException('Unreadable palette line: "$l".');
      final r = int.parse(m.group(1)!), g = int.parse(m.group(2)!), b = int.parse(m.group(3)!);
      if (r > 255 || g > 255 || b > 255) throw PaletteException('Colour out of range: "$l".');
      colors.add(ColorMath.rgb(r, g, b));
      if (colors.length > ColorPalette.maxColors) {
        throw const PaletteException('That palette has too many colours (limit 128).');
      }
    }
    if (colors.isEmpty) throw const PaletteException('The palette has no colours.');
    return ColorPalette(id: 'gpl', name: name.isEmpty ? 'Imported palette' : name, colors: colors);
  }
}
