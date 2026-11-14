import 'dart:typed_data';

/// Reference images are *not* artwork. They live in their own per-project
/// store and are excluded from every export by [ExportPlan] unless the user
/// explicitly opts in.
class ReferenceException implements Exception {
  const ReferenceException(this.message);
  final String message;
  @override
  String toString() => message;
}

class ReferenceImage {
  const ReferenceImage({
    required this.id,
    required this.name,
    required this.bytes,
    this.x = 0,
    this.y = 0,
    this.scale = 1,
    this.rotation = 0,
    this.opacity = 1,
    this.locked = false,
    this.hidden = false,
    this.group = '',
  });

  static const maxBytes = 8 * 1024 * 1024;
  static const maxImages = 24;

  final String id;
  final String name;
  final Uint8List bytes;
  final double x, y, scale, rotation, opacity;
  final bool locked, hidden;

  /// Free-form board section ("Poses", "Colors"...); empty = ungrouped.
  final String group;

  ReferenceImage copyWith({
    String? name,
    double? x,
    double? y,
    double? scale,
    double? rotation,
    double? opacity,
    bool? locked,
    bool? hidden,
    String? group,
  }) =>
      ReferenceImage(
        id: id,
        name: name ?? this.name,
        bytes: bytes,
        x: x ?? this.x,
        y: y ?? this.y,
        scale: scale ?? this.scale,
        rotation: rotation ?? this.rotation,
        opacity: (opacity ?? this.opacity).clamp(0.05, 1.0).toDouble(),
        locked: locked ?? this.locked,
        hidden: hidden ?? this.hidden,
        group: group ?? this.group,
      );

  Map<String, Object?> toMeta() => {
        'id': id,
        'name': name,
        'x': x,
        'y': y,
        's': scale,
        'r': rotation,
        'o': opacity,
        'lk': locked,
        'hd': hidden,
        'g': group,
      };

  static double _d(Object? v, double f, double lo, double hi) =>
      v is num && v.isFinite ? v.toDouble().clamp(lo, hi).toDouble() : f;

  factory ReferenceImage.fromMeta(Map meta, Uint8List bytes) {
    final id = meta['id'];
    if (id is! String || id.isEmpty) throw const ReferenceException('Bad reference id.');
    if (bytes.isEmpty || bytes.length > maxBytes) {
      throw const ReferenceException('Reference image has an invalid size.');
    }
    return ReferenceImage(
      id: id,
      name: meta['name'] is String ? meta['name'] as String : 'Reference',
      bytes: bytes,
      x: _d(meta['x'], 0, -1e6, 1e6),
      y: _d(meta['y'], 0, -1e6, 1e6),
      scale: _d(meta['s'], 1, 0.02, 50),
      rotation: _d(meta['r'], 0, -7, 7),
      opacity: _d(meta['o'], 1, 0.05, 1),
      locked: meta['lk'] == true,
      hidden: meta['hd'] == true,
      group: meta['g'] is String ? meta['g'] as String : '',
    );
  }
}

/// The set of references for one project. Immutable-style helpers.
class ReferenceBoard {
  const ReferenceBoard([this.images = const []]);
  final List<ReferenceImage> images;

  ReferenceBoard add(ReferenceImage image) {
    if (images.length >= ReferenceImage.maxImages) {
      throw const ReferenceException('Too many reference images (max 24).');
    }
    if (image.bytes.length > ReferenceImage.maxBytes) {
      throw const ReferenceException('That image is too large (max 8 MB).');
    }
    return ReferenceBoard([...images, image]);
  }

  ReferenceBoard update(String id, ReferenceImage Function(ReferenceImage) f) =>
      ReferenceBoard([for (final i in images) i.id == id ? f(i) : i]);

  ReferenceBoard remove(String id) =>
      ReferenceBoard([for (final i in images) if (i.id != id) i]);

  ReferenceImage? byId(String id) {
    for (final i in images) {
      if (i.id == id) return i;
    }
    return null;
  }

  Iterable<ReferenceImage> get visible => images.where((i) => !i.hidden);

  List<String> get groups =>
      {for (final i in images) if (i.group.isNotEmpty) i.group}.toList()..sort();

  String nextId() {
    var n = images.length + 1;
    while (images.any((i) => i.id == 'ref-$n')) {
      n++;
    }
    return 'ref-$n';
  }
}

/// What goes into an export. References and assist data (grids, guides,
/// rulers, symmetry axes) are never included unless explicitly requested.
class ExportPlan {
  const ExportPlan({this.includeReferences = false, this.includeAssists = false});
  final bool includeReferences;
  final bool includeAssists;

  /// The default plan used by every exporter.
  static const standard = ExportPlan();
}
