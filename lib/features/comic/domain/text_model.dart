import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/painting.dart' as p;

class TextException implements Exception {
  const TextException(this.message);
  final String message;
  @override
  String toString() => message;
}

enum TextAlignment { left, center, right, justify }

/// Style + content of an editable text run. Pure data: saved with the page,
/// so text stays editable after save/reopen.
class TextSpec {
  const TextSpec({
    this.text = '',
    this.family,
    this.size = 28,
    this.weight = 400,
    this.italic = false,
    this.align = TextAlignment.center,
    this.lineHeight = 1.2,
    this.letterSpacing = 0,
    this.colorArgb = 0xFF000000,
    this.outlineWidth = 0,
    this.outlineArgb = 0xFFFFFFFF,
    this.shadowDx = 0,
    this.shadowDy = 0,
    this.shadowBlur = 0,
    this.shadowArgb = 0x66000000,
    this.vertical = false,
  });

  static const maxChars = 4000;
  static const maxFamilyLength = 80;

  final String text;

  /// null = the app's default font. Only the default or fonts the user
  /// imported (with a licence acknowledgement) are ever referenced.
  final String? family;
  final double size;
  final int weight;
  final bool italic;
  final TextAlignment align;
  final double lineHeight;
  final double letterSpacing;
  final int colorArgb;
  final double outlineWidth;
  final int outlineArgb;
  final double shadowDx, shadowDy, shadowBlur;
  final int shadowArgb;

  /// Top-to-bottom columns running right-to-left (simple glyph stacking).
  final bool vertical;

  bool get hasShadow => shadowBlur > 0 || shadowDx != 0 || shadowDy != 0;

  TextSpec copyWith({
    String? text,
    Object? family = _keep,
    double? size,
    int? weight,
    bool? italic,
    TextAlignment? align,
    double? lineHeight,
    double? letterSpacing,
    int? colorArgb,
    double? outlineWidth,
    int? outlineArgb,
    double? shadowDx,
    double? shadowDy,
    double? shadowBlur,
    int? shadowArgb,
    bool? vertical,
  }) =>
      TextSpec(
        text: text ?? this.text,
        family: identical(family, _keep) ? this.family : family as String?,
        size: size ?? this.size,
        weight: weight ?? this.weight,
        italic: italic ?? this.italic,
        align: align ?? this.align,
        lineHeight: lineHeight ?? this.lineHeight,
        letterSpacing: letterSpacing ?? this.letterSpacing,
        colorArgb: colorArgb ?? this.colorArgb,
        outlineWidth: outlineWidth ?? this.outlineWidth,
        outlineArgb: outlineArgb ?? this.outlineArgb,
        shadowDx: shadowDx ?? this.shadowDx,
        shadowDy: shadowDy ?? this.shadowDy,
        shadowBlur: shadowBlur ?? this.shadowBlur,
        shadowArgb: shadowArgb ?? this.shadowArgb,
        vertical: vertical ?? this.vertical,
      );

  static const Object _keep = Object();

  Map<String, Object?> toJson() => {
        't': text,
        if (family != null) 'f': family,
        's': size,
        'w': weight,
        if (italic) 'i': true,
        'a': align.name,
        'lh': lineHeight,
        'ls': letterSpacing,
        'c': colorArgb,
        if (outlineWidth > 0) 'ow': outlineWidth,
        if (outlineWidth > 0) 'oc': outlineArgb,
        if (hasShadow) 'sh': [shadowDx, shadowDy, shadowBlur, shadowArgb],
        if (vertical) 'v': true,
      };

  static double _d(Object? v, double f, double lo, double hi) =>
      v is num && v.isFinite ? v.toDouble().clamp(lo, hi).toDouble() : f;

  factory TextSpec.fromJson(Object? json) {
    if (json is! Map) throw const TextException('Text data is not an object.');
    final t = json['t'];
    if (t is! String) throw const TextException('Text is missing.');
    if (t.length > maxChars) throw const TextException('Text is too long.');
    final f = json['f'];
    if (f != null && (f is! String || f.length > maxFamilyLength)) {
      throw const TextException('Invalid font name.');
    }
    final sh = json['sh'];
    final align = TextAlignment.values.where((a) => a.name == json['a']);
    return TextSpec(
      text: t,
      family: f as String?,
      size: _d(json['s'], 28, 4, 600),
      weight: (_d(json['w'], 400, 100, 900) / 100).round() * 100,
      italic: json['i'] == true,
      align: align.isEmpty ? TextAlignment.center : align.first,
      lineHeight: _d(json['lh'], 1.2, 0.6, 3),
      letterSpacing: _d(json['ls'], 0, -10, 60),
      colorArgb: json['c'] is int ? json['c'] as int : 0xFF000000,
      outlineWidth: _d(json['ow'], 0, 0, 40),
      outlineArgb: json['oc'] is int ? json['oc'] as int : 0xFFFFFFFF,
      shadowDx: sh is List && sh.length == 4 ? _d(sh[0], 0, -100, 100) : 0,
      shadowDy: sh is List && sh.length == 4 ? _d(sh[1], 0, -100, 100) : 0,
      shadowBlur: sh is List && sh.length == 4 ? _d(sh[2], 0, 0, 100) : 0,
      shadowArgb: sh is List && sh.length == 4 && sh[3] is int ? sh[3] as int : 0x66000000,
      vertical: json['v'] == true,
    );
  }

  @override
  bool operator ==(Object o) => o is TextSpec && o.toJson().toString() == toJson().toString();
  @override
  int get hashCode => toJson().toString().hashCode;
}

/// Lays text out for painting. Filled text + optional outline (drawn first,
/// as a stroke) + optional shadow.
abstract final class TextRenderer {
  static p.TextAlign _align(TextAlignment a) => switch (a) {
        TextAlignment.left => p.TextAlign.left,
        TextAlignment.center => p.TextAlign.center,
        TextAlignment.right => p.TextAlign.right,
        TextAlignment.justify => p.TextAlign.justify,
      };

  static p.TextStyle _style(TextSpec s, {bool outline = false, double? size}) => p.TextStyle(
        fontFamily: s.family,
        fontSize: size ?? s.size,
        fontWeight: FontWeight.values[((s.weight ~/ 100) - 1).clamp(0, 8)],
        fontStyle: s.italic ? FontStyle.italic : FontStyle.normal,
        height: s.lineHeight,
        letterSpacing: s.letterSpacing,
        color: outline ? null : Color(s.colorArgb),
        foreground: outline
            ? (Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = s.outlineWidth * 2
              ..strokeJoin = StrokeJoin.round
              ..color = Color(s.outlineArgb))
            : null,
        shadows: !outline && s.hasShadow
            ? [Shadow(color: Color(s.shadowArgb), offset: Offset(s.shadowDx, s.shadowDy), blurRadius: s.shadowBlur)]
            : null,
      );

  static p.TextPainter _painter(TextSpec s, double width, {bool outline = false, double? size}) =>
      p.TextPainter(
        text: p.TextSpan(text: s.text, style: _style(s, outline: outline, size: size)),
        textAlign: _align(s.align),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: width <= 0 ? 1 : width);

  /// Shrinks the font (never below [minSize]) until the wrapped text fits
  /// [box]; returns the size used.
  static double fitSize(TextSpec s, Size box, {double minSize = 8}) {
    var size = s.size;
    while (size > minSize) {
      final tp = _painter(s, box.width, size: size);
      if (tp.height <= box.height) break;
      size -= 1;
    }
    return size;
  }

  /// Paints [s] inside [box] (top-left [origin]), vertically centred.
  static void paint(Canvas canvas, TextSpec s, Rect box, {bool shrinkToFit = true}) {
    if (s.text.isEmpty) return;
    if (s.vertical) {
      _paintVertical(canvas, s, box);
      return;
    }
    final size = shrinkToFit ? fitSize(s, box.size) : s.size;
    final fill = _painter(s, box.width, size: size);
    final dy = box.top + (box.height - fill.height) / 2;
    final at = Offset(box.left, shrinkToFit ? dy : box.top);
    if (s.outlineWidth > 0) _painter(s, box.width, outline: true, size: size).paint(canvas, at);
    fill.paint(canvas, at);
  }

  /// Glyph positions for vertical text: columns right-to-left, characters
  /// stacked top-to-bottom. Punctuation is not rotated (documented limit).
  static List<(String, Offset)> verticalGlyphs(TextSpec s, Rect box) {
    final out = <(String, Offset)>[];
    final step = s.size * s.lineHeight;
    final colW = s.size * 1.15;
    var col = 0;
    var row = 0;
    final perCol = (box.height / step).floor().clamp(1, 1 << 20);
    for (final r in s.text.runes) {
      final ch = String.fromCharCode(r);
      if (ch == '\n') {
        col++;
        row = 0;
        continue;
      }
      if (row >= perCol) {
        col++;
        row = 0;
      }
      out.add((ch, Offset(box.right - colW * (col + 1), box.top + row * step)));
      row++;
    }
    return out;
  }

  static void _paintVertical(Canvas canvas, TextSpec s, Rect box) {
    for (final (ch, at) in verticalGlyphs(s, box)) {
      final one = s.copyWith(text: ch, vertical: false, align: TextAlignment.center);
      if (s.outlineWidth > 0) _painter(one, s.size * 1.2, outline: true).paint(canvas, at);
      _painter(one, s.size * 1.2).paint(canvas, at);
    }
  }
}

// ---------------------------------------------------------------------------
// Font import validation
// ---------------------------------------------------------------------------

class FontImportException implements Exception {
  const FontImportException(this.message);
  final String message;
  @override
  String toString() => message;
}

class FontInfo {
  const FontInfo({required this.family, required this.embeddingFlags, this.license, this.isCollection = false});
  final String family;
  final int embeddingFlags;
  final String? license;
  final bool isCollection;

  /// OS/2 fsType bit 1 = "restricted licence embedding": the font may not
  /// be embedded/shared, so ARTFOXEL refuses it.
  bool get restricted => (embeddingFlags & 0x0002) != 0;

  /// Bit 2/3: preview&print / editable embedding are allowed, 0 = installable.
  bool get noSubsetting => (embeddingFlags & 0x0100) != 0;
}

/// Validates user-supplied fonts. ARTFOXEL bundles **no** fonts; imported fonts
/// stay local to the project and require an explicit licence acknowledgement.
abstract final class FontImportValidator {
  static const maxBytes = 12 * 1024 * 1024;
  static final RegExp _family = RegExp(r'^[\p{L}\p{N} _\-\.]{1,60}$', unicode: true);

  /// Reads the sfnt header, `name` and `OS/2` tables. Throws
  /// [FontImportException] with a user-facing message when the file is
  /// unusable or may not be shared.
  static FontInfo inspect(Uint8List bytes) {
    if (bytes.length < 12) throw const FontImportException('That file is too small to be a font.');
    if (bytes.length > maxBytes) throw const FontImportException('Fonts larger than 12 MB are not supported.');
    final data = ByteData.sublistView(bytes);
    final tag = data.getUint32(0);
    if (tag == 0x774F4646 || tag == 0x774F4632) {
      throw const FontImportException('WOFF/WOFF2 fonts are not supported. Please use a .ttf or .otf file.');
    }
    final isTtc = tag == 0x74746366;
    if (!(tag == 0x00010000 || tag == 0x4F54544F || tag == 0x74727565 || isTtc)) {
      throw const FontImportException('That is not a TrueType or OpenType font.');
    }
    var base = 0;
    if (isTtc) {
      if (bytes.length < 16) throw const FontImportException('Damaged font collection.');
      base = data.getUint32(12);
      if (base + 12 > bytes.length) throw const FontImportException('Damaged font collection.');
    }
    final numTables = data.getUint16(base + 4);
    if (numTables == 0 || numTables > 128 || base + 12 + numTables * 16 > bytes.length) {
      throw const FontImportException('The font table directory is damaged.');
    }
    int? nameOff, nameLen, os2Off;
    for (var i = 0; i < numTables; i++) {
      final rec = base + 12 + i * 16;
      final t = String.fromCharCodes(bytes.sublist(rec, rec + 4));
      final off = data.getUint32(rec + 8), len = data.getUint32(rec + 12);
      if (off > bytes.length || len > bytes.length - off) {
        throw const FontImportException('The font contains an out-of-range table.');
      }
      if (t == 'name') {
        nameOff = off;
        nameLen = len;
      } else if (t == 'OS/2') {
        os2Off = off;
        if (len < 10) throw const FontImportException('The font OS/2 table is damaged.');
      }
    }
    if (nameOff == null || nameLen == null) throw const FontImportException('The font has no name table.');
    final flags = os2Off == null ? 0 : data.getUint16(os2Off + 8);
    final names = _readNames(bytes, data, nameOff, nameLen);
    final family = names[1] ?? names[16];
    if (family == null || !_family.hasMatch(family)) {
      throw const FontImportException('The font has no usable family name.');
    }
    final info = FontInfo(family: family, embeddingFlags: flags, license: names[13], isCollection: isTtc);
    if (info.restricted) {
      throw FontImportException('"$family" is marked "restricted licence": its licence does not allow embedding, so it cannot be used.');
    }
    return info;
  }

  static Map<int, String> _readNames(Uint8List bytes, ByteData data, int off, int len) {
    final out = <int, String>{};
    if (len < 6) return out;
    final count = data.getUint16(off + 2);
    final strOff = off + data.getUint16(off + 4);
    for (var i = 0; i < count && off + 6 + i * 12 + 12 <= off + len; i++) {
      final r = off + 6 + i * 12;
      final platform = data.getUint16(r), id = data.getUint16(r + 6);
      final l = data.getUint16(r + 8), o = data.getUint16(r + 10);
      if ((id != 1 && id != 13 && id != 16) || strOff + o + l > bytes.length) continue;
      String? text;
      if (platform == 3 || platform == 0) {
        final units = <int>[for (var k = 0; k + 1 < l; k += 2) data.getUint16(strOff + o + k)];
        text = String.fromCharCodes(units);
      } else if (platform == 1) {
        text = String.fromCharCodes(bytes.sublist(strOff + o, strOff + o + l));
      }
      if (text != null && text.trim().isNotEmpty) out.putIfAbsent(id, () => text!.trim());
    }
    return out;
  }

  /// Full import check: [licenceAcknowledged] must be true (the user states
  /// they have the right to use and embed this font).
  static FontInfo validate(Uint8List bytes, {required bool licenceAcknowledged}) {
    if (!licenceAcknowledged) {
      throw const FontImportException('Please confirm you have the right to use this font before importing it.');
    }
    return inspect(bytes);
  }
}

/// A font the user imported into a project.
class ImportedFont {
  const ImportedFont({required this.family, required this.fileName, required this.licenceNote, required this.acknowledged});
  final String family;
  final String fileName;
  final String licenceNote;
  final bool acknowledged;

  Map<String, Object?> toJson() => {'family': family, 'file': fileName, 'licence': licenceNote, 'ack': acknowledged};

  static ImportedFont fromJson(Object? j) {
    if (j is! Map || j['family'] is! String || j['file'] is! String) {
      throw const TextException('Bad imported font entry.');
    }
    final file = j['file'] as String;
    if (file.contains('/') || file.contains('\\') || file.contains('..')) {
      throw const TextException('Bad imported font file name.');
    }
    return ImportedFont(
      family: j['family'] as String,
      fileName: file,
      licenceNote: j['licence'] is String ? j['licence'] as String : '',
      acknowledged: j['ack'] == true,
    );
  }
}
