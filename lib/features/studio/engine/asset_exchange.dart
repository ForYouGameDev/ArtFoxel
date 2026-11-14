import 'dart:convert';
import 'dart:math' as math;

/// Phase 7.5.7 — brush dynamics + safe asset import/export/sharing.
/// Assets are DATA ONLY: a strict whitelist schema, size limits, no code.

class AssetException implements Exception {
  AssetException(this.message);
  final String message;
  @override
  String toString() => 'AssetException: $message';
}

// ------------------------------------------------------- brush dynamics

class BrushDynamics {
  const BrushDynamics({
    this.spacing = 0.15,
    this.tipRotationDeg = 0,
    this.rotationJitterDeg = 0,
    this.sizeJitter = 0,
    this.scatter = 0,
    this.flow = 1,
    this.wetness = 0,
    this.paintMix = 0,
    this.edgeDarkening = 0,
    this.textureId,
    this.textureDepth = 0,
    this.dualBrushId,
    this.dualBlend = 0.5,
  });
  final double spacing; // fraction of diameter, 0.01..2
  final double tipRotationDeg, rotationJitterDeg;
  final double sizeJitter, scatter; // 0..1
  final double flow; // 0..1
  final double wetness; // 0..1 how far colours bleed/blend
  final double paintMix; // 0..1 pick-up of canvas colour
  final double edgeDarkening; // 0..1 watercolour edge effect
  final String? textureId;
  final double textureDepth; // 0..1
  final String? dualBrushId; // secondary tip; engine support required
  final double dualBlend;

  BrushDynamics clamped() => BrushDynamics(
        spacing: spacing.clamp(0.01, 2.0),
        tipRotationDeg: tipRotationDeg % 360,
        rotationJitterDeg: rotationJitterDeg.clamp(0.0, 180.0),
        sizeJitter: sizeJitter.clamp(0.0, 1.0),
        scatter: scatter.clamp(0.0, 1.0),
        flow: flow.clamp(0.0, 1.0),
        wetness: wetness.clamp(0.0, 1.0),
        paintMix: paintMix.clamp(0.0, 1.0),
        edgeDarkening: edgeDarkening.clamp(0.0, 1.0),
        textureId: textureId,
        textureDepth: textureDepth.clamp(0.0, 1.0),
        dualBrushId: dualBrushId,
        dualBlend: dualBlend.clamp(0.0, 1.0),
      );

  Map<String, Object?> toJson() => {
        'spacing': spacing, 'rot': tipRotationDeg, 'rotJ': rotationJitterDeg,
        'sizeJ': sizeJitter, 'scatter': scatter, 'flow': flow, 'wet': wetness,
        'mix': paintMix, 'edge': edgeDarkening, 'tex': textureId,
        'texD': textureDepth, 'dual': dualBrushId, 'dualB': dualBlend,
      };

  static BrushDynamics fromJson(Map<String, Object?> j) {
    double d(String k, double f) => (j[k] is num) ? (j[k] as num).toDouble() : f;
    String? s(String k) => j[k] is String && (j[k] as String).length <= 64 ? j[k] as String : null;
    return BrushDynamics(
      spacing: d('spacing', 0.15), tipRotationDeg: d('rot', 0), rotationJitterDeg: d('rotJ', 0),
      sizeJitter: d('sizeJ', 0), scatter: d('scatter', 0), flow: d('flow', 1),
      wetness: d('wet', 0), paintMix: d('mix', 0), edgeDarkening: d('edge', 0),
      textureId: s('tex'), textureDepth: d('texD', 0), dualBrushId: s('dual'),
      dualBlend: d('dualB', 0.5),
    ).clamped();
  }

  /// Dab positions along a polyline honouring spacing and scatter. Seeded, so
  /// the same stroke always produces the same dabs (replayable, testable).
  List<Dab> dabsAlong(List<(double, double)> pts, double diameter, {int seed = 7}) {
    final rnd = math.Random(seed);
    final dabs = <Dab>[];
    final step = math.max(0.5, diameter * spacing.clamp(0.01, 2.0));
    var carry = 0.0;
    for (var i = 0; i < pts.length - 1; i++) {
      final a = pts[i], b = pts[i + 1];
      final dx = b.$1 - a.$1, dy = b.$2 - a.$2;
      final len = math.sqrt(dx * dx + dy * dy);
      if (len < 1e-9) continue;
      var d = carry;
      while (d <= len) {
        final t = d / len;
        final jx = scatter > 0 ? (rnd.nextDouble() - 0.5) * 2 * scatter * diameter : 0.0;
        final jy = scatter > 0 ? (rnd.nextDouble() - 0.5) * 2 * scatter * diameter : 0.0;
        dabs.add(Dab(
          a.$1 + dx * t + jx,
          a.$2 + dy * t + jy,
          diameter * (1 - sizeJitter * rnd.nextDouble()),
          tipRotationDeg + (rationalJitter(rnd) * rotationJitterDeg),
        ));
        d += step;
        if (dabs.length > 200000) return dabs;
      }
      carry = d - len;
    }
    return dabs;
  }

  static double rationalJitter(math.Random r) => r.nextDouble() * 2 - 1;
}

class Dab {
  const Dab(this.x, this.y, this.diameter, this.rotationDeg);
  final double x, y, diameter, rotationDeg;
}

// ------------------------------------------------------------ exchange

enum AssetKind { brushSet, texture, pattern, stamp, gradient, palette }

class AssetItem {
  AssetItem({
    required this.kind,
    required this.name,
    required this.author,
    required this.license,
    required this.payload,
    this.sourceUrl,
    this.attribution,
  });
  final AssetKind kind;
  final String name, author, license;
  final String? sourceUrl, attribution;
  final Map<String, Object?> payload;

  Map<String, Object?> toJson() => {
        'kind': kind.name, 'name': name, 'author': author, 'license': license,
        if (sourceUrl != null) 'source': sourceUrl,
        if (attribution != null) 'attribution': attribution,
        'data': payload,
      };
}

class AssetPackage {
  static const format = 'artfoxel-assets';
  static const version = 1;
  static const maxItems = 200;
  static const maxBytes = 8 * 1024 * 1024;
  static const maxImageBytes = 2 * 1024 * 1024;

  static const _forbiddenKeys = {
    'script', 'scripts', 'code', 'eval', 'exec', 'command', 'cmd', 'shell',
    'onload', 'onerror', 'javascript', 'expression', 'macro',
  };

  static const _allowedLicenses = {
    'CC0-1.0', 'CC-BY-4.0', 'CC-BY-SA-4.0', 'CC-BY-NC-4.0', 'MIT', 'Apache-2.0',
    'own-work', 'permission-granted',
  };

  static String export(List<AssetItem> items) {
    if (items.length > maxItems) throw AssetException('too many items');
    for (final i in items) {
      if (i.author.trim().isEmpty) throw AssetException('"${i.name}" needs an author');
      if (!_allowedLicenses.contains(i.license)) {
        throw AssetException('"${i.name}" needs a known licence');
      }
    }
    return jsonEncode({
      'format': format,
      'version': version,
      'items': [for (final i in items) i.toJson()],
    });
  }

  /// Parses and validates. Never executes or evaluates anything; unknown
  /// kinds, forbidden keys, bad URLs, oversized data and missing
  /// attribution all produce an [AssetException] (or a warning for the
  /// attribution fields that are optional).
  static AssetImport parse(String text) {
    if (text.length > maxBytes) throw AssetException('file too large');
    Object? root;
    try {
      root = jsonDecode(text);
    } on FormatException {
      throw AssetException('not valid JSON');
    }
    if (root is! Map) throw AssetException('root must be an object');
    if (root['format'] != format) throw AssetException('not an ArtFoxel asset package');
    final v = root['version'];
    if (v is! int || v < 1 || v > version) {
      throw AssetException('unsupported version $v');
    }
    final list = root['items'];
    if (list is! List) throw AssetException('items missing');
    if (list.length > maxItems) throw AssetException('too many items');

    final items = <AssetItem>[];
    final warnings = <String>[];
    for (var i = 0; i < list.length; i++) {
      final e = list[i];
      if (e is! Map) throw AssetException('item $i is not an object');
      _scanKeys(e, 0);
      final kind = AssetKind.values.where((k) => k.name == e['kind']);
      if (kind.isEmpty) throw AssetException('item $i: unknown kind ${e['kind']}');
      final name = _str(e['name'], 80, 'item $i name');
      final author = _str(e['author'], 80, 'item $i author');
      final license = _str(e['license'], 40, 'item $i license');
      if (!_allowedLicenses.contains(license)) {
        throw AssetException('item $i ($name): unknown licence "$license"');
      }
      final src = e['source'];
      String? url;
      if (src != null) {
        url = _str(src, 300, 'item $i source');
        final u = Uri.tryParse(url);
        if (u == null || !(u.scheme == 'http' || u.scheme == 'https') || u.host.isEmpty) {
          throw AssetException('item $i: source must be an http(s) URL');
        }
      }
      if (license == 'CC-BY-NC-4.0') warnings.add('$name is non-commercial only');
      final data = e['data'];
      if (data is! Map) throw AssetException('item $i: data missing');
      _validatePayload(kind.first, Map<String, Object?>.from(data), i);
      items.add(AssetItem(
        kind: kind.first, name: name, author: author, license: license,
        sourceUrl: url,
        attribution: e['attribution'] is String ? _str(e['attribution'], 200, 'attribution') : null,
        payload: Map<String, Object?>.from(data),
      ));
    }
    return AssetImport(items, warnings);
  }

  static String _str(Object? v, int max, String what) {
    if (v is! String || v.trim().isEmpty) throw AssetException('$what missing');
    if (v.length > max) throw AssetException('$what too long');
    if (RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F]').hasMatch(v)) {
      throw AssetException('$what has control characters');
    }
    return v;
  }

  static void _scanKeys(Object? o, int depth) {
    if (depth > 12) throw AssetException('nesting too deep');
    if (o is Map) {
      for (final e in o.entries) {
        if (_forbiddenKeys.contains('${e.key}'.toLowerCase())) {
          throw AssetException('forbidden key "${e.key}" (assets are data only)');
        }
        _scanKeys(e.value, depth + 1);
      }
    } else if (o is List) {
      for (final v in o) {
        _scanKeys(v, depth + 1);
      }
    }
  }

  static void _validatePayload(AssetKind k, Map<String, Object?> d, int i) {
    switch (k) {
      case AssetKind.brushSet:
        final brushes = d['brushes'];
        if (brushes is! List || brushes.isEmpty || brushes.length > 100) {
          throw AssetException('item $i: brushes must be a list of 1..100');
        }
        for (final b in brushes) {
          if (b is! Map || b['name'] is! String) {
            throw AssetException('item $i: bad brush entry');
          }
          final dyn = b['dynamics'];
          if (dyn != null && dyn is! Map) throw AssetException('item $i: bad dynamics');
        }
      case AssetKind.texture:
      case AssetKind.stamp:
      case AssetKind.pattern:
        final png = d['png'];
        if (png is! String) throw AssetException('item $i: png (base64) missing');
        final bytes = _decodeB64(png, i);
        if (bytes.length > maxImageBytes) throw AssetException('item $i: image too large');
        const magic = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
        if (bytes.length < 8 || !List.generate(8, (x) => bytes[x] == magic[x]).every((b) => b)) {
          throw AssetException('item $i: not a PNG');
        }
      case AssetKind.gradient:
        final stops = d['stops'];
        if (stops is! List || stops.length < 2 || stops.length > 32) {
          throw AssetException('item $i: gradient needs 2..32 stops');
        }
        for (final s in stops) {
          if (s is! Map || s['pos'] is! num || s['color'] is! int) {
            throw AssetException('item $i: bad gradient stop');
          }
          final p = (s['pos'] as num).toDouble();
          if (p < 0 || p > 1) throw AssetException('item $i: stop out of range');
        }
      case AssetKind.palette:
        final cols = d['colors'];
        if (cols is! List || cols.isEmpty || cols.length > 256 || !cols.every((c) => c is int)) {
          throw AssetException('item $i: palette needs 1..256 integer colours');
        }
    }
  }

  static List<int> _decodeB64(String s, int i) {
    try {
      return base64Decode(s);
    } on FormatException {
      throw AssetException('item $i: bad base64');
    }
  }
}

class AssetImport {
  AssetImport(this.items, this.warnings);
  final List<AssetItem> items;
  final List<String> warnings;
}

/// Local report queue for shared assets that look wrong or infringing.
/// Nothing is sent from here — the app decides how reports are delivered.
class AssetReport {
  AssetReport(this.assetName, this.author, this.reason, this.createdAt);
  final String assetName, author, reason;
  final DateTime createdAt;
  Map<String, Object?> toJson() => {
        'asset': assetName, 'author': author, 'reason': reason,
        'at': createdAt.toIso8601String(),
      };
}

class ReportQueue {
  final List<AssetReport> _q = [];
  static const reasons = {'copyright', 'malicious', 'inappropriate', 'wrong-license', 'other'};
  AssetReport add(AssetItem item, String reason, {DateTime? now}) {
    if (!reasons.contains(reason)) throw AssetException('unknown reason');
    final r = AssetReport(item.name, item.author, reason, now ?? DateTime.now());
    _q.add(r);
    return r;
  }
  List<AssetReport> get pending => List.unmodifiable(_q);
}
