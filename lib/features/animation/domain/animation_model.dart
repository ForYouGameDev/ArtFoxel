import 'dart:convert';
import 'dart:ui';

import '../../studio/domain/sketch_document_data.dart';

class AnimationException implements Exception {
  const AnimationException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// One pen/eraser stroke inside a frame. Frame content is vector strokes, so
/// it stays editable (undo, erase, redraw) until export.
class AnimStroke {
  AnimStroke({required List<Offset> points, this.colorArgb = 0xFF000000, this.width = 6, this.erase = false})
      : points = List.unmodifiable(points) {
    if (points.isEmpty) throw const AnimationException('A stroke needs at least one point.');
  }
  static const maxPoints = 20000;
  final List<Offset> points;
  final int colorArgb;
  final double width;
  final bool erase;

  Map<String, Object?> toJson() => {
        'p': [for (final o in points) ...[_r(o.dx), _r(o.dy)]],
        'c': colorArgb,
        'w': width,
        if (erase) 'e': true,
      };

  static double _r(double v) => (v * 10).roundToDouble() / 10;

  factory AnimStroke.fromJson(Object? j) {
    if (j is! Map || j['p'] is! List) throw const AnimationException('Invalid stroke.');
    final raw = j['p'] as List;
    if (raw.length.isOdd || raw.isEmpty || raw.length > maxPoints * 2) throw const AnimationException('Invalid stroke points.');
    final pts = <Offset>[];
    for (var i = 0; i < raw.length; i += 2) {
      final x = raw[i], y = raw[i + 1];
      if (x is! num || y is! num || !x.isFinite || !y.isFinite) throw const AnimationException('Invalid stroke point.');
      pts.add(Offset(x.toDouble(), y.toDouble()));
    }
    final w = j['w'];
    return AnimStroke(
      points: pts,
      colorArgb: j['c'] is int ? j['c'] as int : 0xFF000000,
      width: w is num && w.isFinite ? w.toDouble().clamp(0.5, 300).toDouble() : 6,
      erase: j['e'] == true,
    );
  }
}

/// An imported picture stored once as an asset (PNG file in the project) and
/// placed with an affine matrix [a b c d e f] (x' = a*x + c*y + e).
class AnimAsset {
  const AnimAsset({required this.id, required this.name, required this.width, required this.height});
  final String id, name;
  final int width, height;
  Map<String, Object?> toJson() => {'id': id, 'name': name, 'w': width, 'h': height};
  factory AnimAsset.fromJson(Object? j) {
    if (j is! Map || j['id'] is! String || j['w'] is! int || j['h'] is! int) {
      throw const AnimationException('Invalid image asset.');
    }
    final id = j['id'] as String;
    if (!RegExp(r'^[A-Za-z0-9_-]{1,60}$').hasMatch(id)) throw const AnimationException('Invalid image asset id.');
    final w = j['w'] as int, h = j['h'] as int;
    if (w < 1 || h < 1 || w > 8192 || h > 8192) throw const AnimationException('Invalid image asset size.');
    return AnimAsset(id: id, name: j['name'] is String ? (j['name'] as String) : 'Image', width: w, height: h);
  }
}

class AnimImage {
  AnimImage({required this.assetId, required List<double> matrix, this.opacity = 1})
      : matrix = List.unmodifiable(matrix) {
    if (matrix.length != 6 || matrix.any((v) => !v.isFinite)) {
      throw const AnimationException('Invalid image placement.');
    }
    final det = matrix[0] * matrix[3] - matrix[1] * matrix[2];
    if (det.abs() < 1e-9) throw const AnimationException('Invalid image placement.');
  }
  final String assetId;
  final List<double> matrix;
  final double opacity;

  AnimImage copyWith({List<double>? matrix, double? opacity}) =>
      AnimImage(assetId: assetId, matrix: matrix ?? this.matrix, opacity: (opacity ?? this.opacity).clamp(0.0, 1.0));

  Map<String, Object?> toJson() => {'a': assetId, 'm': matrix, 'o': opacity};
  factory AnimImage.fromJson(Object? j) {
    if (j is! Map || j['a'] is! String || j['m'] is! List || (j['m'] as List).length != 6) {
      throw const AnimationException('Invalid image placement.');
    }
    final m = [for (final v in j['m'] as List) v is num ? v.toDouble() : double.nan];
    final o = j['o'];
    return AnimImage(assetId: j['a'] as String, matrix: m, opacity: o is num ? o.toDouble().clamp(0.0, 1.0) : 1.0);
  }
}

/// An image that stays on screen over a range of frames (background art,
/// a character, a prop). Exported with the animation.
class AnimLayer {
  AnimLayer({required this.id, required this.name, required this.image, this.startFrame = 0, this.endFrame, this.visible = true, this.role = 'layer'});
  final String id, name, role; // role: layer | character
  final AnimImage image;
  final int startFrame;
  final int? endFrame; // null = until the last frame
  final bool visible;
  bool coversFrame(int index) => visible && index >= startFrame && (endFrame == null || index <= endFrame!);
  Map<String, Object?> toJson() => {
        'id': id, 'name': name, 'img': image.toJson(), 's': startFrame,
        if (endFrame != null) 'e': endFrame, 'v': visible, 'role': role,
      };
  factory AnimLayer.fromJson(Object? j) {
    if (j is! Map || j['id'] is! String) throw const AnimationException('Invalid animation layer.');
    return AnimLayer(
      id: j['id'] as String,
      name: j['name'] is String ? j['name'] as String : 'Layer',
      image: AnimImage.fromJson(j['img']),
      startFrame: j['s'] is int ? (j['s'] as int).clamp(0, 100000) : 0,
      endFrame: j['e'] is int ? j['e'] as int : null,
      visible: j['v'] != false,
      role: j['role'] == 'character' ? 'character' : 'layer',
    );
  }
}


class AnimFrame {
  AnimFrame({required this.id, List<AnimStroke>? strokes, this.hold = 1, List<AnimImage>? images, this.art})
      : strokes = strokes ?? <AnimStroke>[],
        images = images == null ? <AnimImage>[] : List.of(images);
  static const maxStrokes = 5000;
  static const maxHold = 240;

  final String id;
  /// Legacy vector strokes (animations made before the shared drawing
  /// engine). They keep rendering; the first edit moves them into [art].
  final List<AnimStroke> strokes;

  /// This frame's own artwork: a full sketch document (layers, masks, shapes,
  /// every brush including smudge) edited with the shared drawing engine.
  /// Null until the frame is first drawn on.
  SketchDocumentData? art;

  /// Pictures that belong to THIS frame only (frame-specific content).
  final List<AnimImage> images;
  static const maxImages = 24;

  /// How many ticks (1 tick = 1/fps second) this frame is shown.
  int hold;

  AnimFrame copy(String newId) => AnimFrame(
        id: newId,
        strokes: List.of(strokes),
        hold: hold,
        images: List.of(images),
        art: art == null ? null : cloneArt(art!),
      );

  /// Deep copy through the document's own serialisation, so a duplicated
  /// frame never shares stroke lists with its original.
  static SketchDocumentData cloneArt(SketchDocumentData source) =>
      SketchDocumentData.fromJson(
        jsonDecode(jsonEncode(source.toJson())) as Map<String, dynamic>,
      );

  bool get hasArt => art != null && art!.strokeCount + _shapeCount(art!) + _imageLayerCount(art!) > 0;

  static int _shapeCount(SketchDocumentData d) => d.layers.fold(0, (a, l) => a + l.shapes.length);
  static int _imageLayerCount(SketchDocumentData d) => d.layers.where((l) => l.image != null).length;

  bool get isBlank => strokes.isEmpty && images.isEmpty && !hasArt;

  Map<String, Object?> toJson() => {
        'id': id,
        'hold': hold,
        's': [for (final s in strokes) s.toJson()],
        if (images.isNotEmpty) 'im': [for (final i in images) i.toJson()],
        if (art != null) 'art': art!.toJson(),
      };

  factory AnimFrame.fromJson(Object? j) {
    if (j is! Map || j['id'] is! String || j['s'] is! List) throw const AnimationException('Invalid frame.');
    final s = j['s'] as List;
    if (s.length > maxStrokes) throw const AnimationException('A frame has too many strokes.');
    final hold = j['hold'];
    SketchDocumentData? art;
    if (j['art'] != null) {
      try {
        art = SketchDocumentData.fromJson(Map<String, dynamic>.from(j['art'] as Map));
      } on Object {
        throw const AnimationException('A frame\'s artwork is damaged.');
      }
    }
    return AnimFrame(
      art: art,
      id: j['id'] as String,
      strokes: [for (final e in s) AnimStroke.fromJson(e)],
      hold: hold is int ? hold.clamp(1, maxHold) : 1,
      images: j['im'] is List ? [for (final e in (j['im'] as List).take(maxImages)) AnimImage.fromJson(e)] : const [],
    );
  }
}

class OnionSkin {
  const OnionSkin({this.enabled = true, this.before = 2, this.after = 1, this.opacity = 0.4, this.beforeArgb = 0xFFE53935, this.afterArgb = 0xFF1E88E5});
  final bool enabled;
  final int before, after;
  final double opacity;
  final int beforeArgb, afterArgb;

  OnionSkin copyWith({bool? enabled, int? before, int? after, double? opacity}) => OnionSkin(
        enabled: enabled ?? this.enabled,
        before: before ?? this.before,
        after: after ?? this.after,
        opacity: opacity ?? this.opacity,
        beforeArgb: beforeArgb,
        afterArgb: afterArgb,
      );

  /// Neighbouring frames to ghost around [index], nearest first, each with an
  /// opacity that fades with distance. Editing aid only — exporters never
  /// call this.
  List<(int index, double opacity, bool isBefore)> ghosts(int index, int frameCount) {
    if (!enabled) return const [];
    final out = <(int, double, bool)>[];
    for (var d = 1; d <= before; d++) {
      final i = index - d;
      if (i >= 0) out.add((i, opacity / d, true));
    }
    for (var d = 1; d <= after; d++) {
      final i = index + d;
      if (i < frameCount) out.add((i, opacity / d, false));
    }
    return out;
  }
}

/// A frame-based animation. Distinct from the sketch document.
class AnimationDocument {
  AnimationDocument({
    required this.width,
    required this.height,
    this.fps = 12,
    this.backgroundArgb = 0xFFFFFFFF,
    this.loop = true,
    List<AnimFrame>? frames,
    this.name = 'Animation',
  }) : frames = frames ?? <AnimFrame>[] {
    if (width < 16 || height < 16 || width > maxSide || height > maxSide) {
      throw const AnimationException('Animation size must be between 16 and $maxSide px.');
    }
    if (fps < 1 || fps > 60) throw const AnimationException('FPS must be between 1 and 60.');
    if (this.frames.isEmpty) this.frames.add(AnimFrame(id: 'f1'));
    rangeEnd = this.frames.length - 1;
  }

  static const format = 'artfoxel-animation';
  static const version = 3; // v1 (no images) and v2 (vector strokes only) files still open
  static const maxSide = 2048;
  static const maxAssets = 200;
  static const maxLayers = 40;
  static const maxReferences = 20;
  static const maxFrames = 600;

  final int width, height;
  int fps;
  int backgroundArgb;
  bool loop;
  String name;
  final List<AnimFrame> frames;

  /// Imported pictures (pixels live in the project's `assets/` folder).
  final Map<String, AnimAsset> assets = {};

  /// Static background picture drawn under every frame (exported).
  AnimImage? backgroundImage;

  /// Pictures that persist over a range of frames (exported).
  final List<AnimLayer> layers = [];

  /// Reference pictures for the artist. NEVER rendered into exports.
  final List<AnimImage> references = [];

  /// Inclusive playback range (indices).
  int rangeStart = 0;
  late int rangeEnd;
  int _next = 2;

  String _newId() {
    while (frames.any((f) => f.id == 'f$_next')) {
      _next++;
    }
    return 'f${_next++}';
  }

  void clampRange() {
    rangeStart = rangeStart.clamp(0, frames.length - 1);
    rangeEnd = rangeEnd.clamp(rangeStart, frames.length - 1);
  }

  void setRange(int start, int end) {
    if (start > end) throw const AnimationException('The range start must not be after its end.');
    rangeStart = start.clamp(0, frames.length - 1);
    rangeEnd = end.clamp(rangeStart, frames.length - 1);
  }

  AnimFrame addFrame({int? after}) {
    if (frames.length >= maxFrames) throw const AnimationException('An animation can have at most $maxFrames frames.');
    final f = AnimFrame(id: _newId());
    final at = (after == null ? frames.length : after + 1).clamp(0, frames.length);
    frames.insert(at, f);
    if (rangeEnd >= at - 1 && rangeEnd == frames.length - 2) rangeEnd = frames.length - 1;
    clampRange();
    return f;
  }

  AnimFrame duplicateFrame(int index) {
    if (index < 0 || index >= frames.length) throw const AnimationException('No such frame.');
    if (frames.length >= maxFrames) throw const AnimationException('An animation can have at most $maxFrames frames.');
    final f = frames[index].copy(_newId());
    frames.insert(index + 1, f);
    if (rangeEnd >= index) rangeEnd++;
    clampRange();
    return f;
  }

  void deleteFrame(int index) {
    if (frames.length <= 1) throw const AnimationException('An animation needs at least one frame.');
    if (index < 0 || index >= frames.length) throw const AnimationException('No such frame.');
    frames.removeAt(index);
    if (rangeEnd >= frames.length) rangeEnd = frames.length - 1;
    clampRange();
  }

  void moveFrame(int from, int to) {
    if (from < 0 || from >= frames.length || to < 0 || to >= frames.length) throw const AnimationException('Frame position out of range.');
    frames.insert(to, frames.removeAt(from));
  }

  void setHold(int index, int hold) => frames[index].hold = hold.clamp(1, AnimFrame.maxHold);

  /// Total ticks of the whole animation (sum of holds).
  int get totalTicks => frames.fold(0, (a, f) => a + f.hold);

  int ticksInRange() {
    var t = 0;
    for (var i = rangeStart; i <= rangeEnd; i++) {
      t += frames[i].hold;
    }
    return t;
  }

  Duration get duration => Duration(microseconds: (totalTicks * 1000000 / fps).round());

  /// Index of the frame shown [elapsed] after playback starts inside the
  /// range; null when a non-looping animation has finished.
  int? frameAt(Duration elapsed) {
    final ticks = ticksInRange();
    if (ticks == 0) return null;
    var tick = (elapsed.inMicroseconds * fps / 1000000).floor();
    if (tick >= ticks) {
      if (!loop) return null;
      tick %= ticks;
    }
    var acc = 0;
    for (var i = rangeStart; i <= rangeEnd; i++) {
      acc += frames[i].hold;
      if (tick < acc) return i;
    }
    return rangeEnd;
  }

  /// Every output frame (one per tick) for fixed-rate exports.
  List<int> tickSequence({bool useRange = false}) => [
        for (var i = useRange ? rangeStart : 0; i <= (useRange ? rangeEnd : frames.length - 1); i++)
          for (var k = 0; k < frames[i].hold; k++) i,
      ];

  /// Registers an imported picture; returns its asset id.
  AnimAsset addAsset(String name, int width, int height) {
    if (assets.length >= maxAssets) throw const AnimationException('Too many imported images in this animation.');
    var n = assets.length + 1;
    while (assets.containsKey('img$n')) {
      n++;
    }
    final a = AnimAsset(id: 'img$n', name: name.length > 60 ? name.substring(0, 60) : name, width: width, height: height);
    assets[a.id] = a;
    return a;
  }

  Set<String> get usedAssetIds => {
        if (backgroundImage != null) backgroundImage!.assetId,
        for (final l in layers) l.image.assetId,
        for (final r in references) r.assetId,
        for (final f in frames)
          for (final i in f.images) i.assetId,
      };

  /// Drops assets nothing uses any more; returns the removed ids so the
  /// storage can delete their files.
  List<String> pruneAssets() {
    final used = usedAssetIds;
    final gone = [for (final id in assets.keys) if (!used.contains(id)) id];
    for (final id in gone) {
      assets.remove(id);
    }
    return gone;
  }

  Map<String, Object?> toJson() => {
        'format': format,
        'version': version,
        'name': name,
        if (assets.isNotEmpty) 'assets': [for (final a in assets.values) a.toJson()],
        if (backgroundImage != null) 'bgImg': backgroundImage!.toJson(),
        if (layers.isNotEmpty) 'layers': [for (final l in layers) l.toJson()],
        if (references.isNotEmpty) 'refs': [for (final r in references) r.toJson()],
        'w': width,
        'h': height,
        'fps': fps,
        'bg': backgroundArgb,
        'loop': loop,
        'range': [rangeStart, rangeEnd],
        'frames': [for (final f in frames) f.toJson()],
      };

  factory AnimationDocument.fromJson(Object? j) {
    if (j is! Map || j['format'] != format) throw const AnimationException('This is not an ARTFOXEL animation.');
    final v = j['version'];
    if (v is! int || v < 1) throw const AnimationException('Unreadable animation version.');
    if (v > version) throw const AnimationException('This animation was made with a newer version of ARTFOXEL.');
    final rawFrames = j['frames'];
    if (rawFrames is! List || rawFrames.isEmpty || rawFrames.length > maxFrames) throw const AnimationException('Invalid frame list.');
    final frames = [for (final f in rawFrames) AnimFrame.fromJson(f)];
    final ids = <String>{};
    for (final f in frames) {
      if (!ids.add(f.id)) throw const AnimationException('Duplicate frame id.');
    }
    int n(String k, int f) => j[k] is num && (j[k] as num).isFinite ? (j[k] as num).round() : f;
    final doc = AnimationDocument(
      width: n('w', 0),
      height: n('h', 0),
      fps: n('fps', 12),
      backgroundArgb: j['bg'] is int ? j['bg'] as int : 0xFFFFFFFF,
      loop: j['loop'] != false,
      frames: frames,
      name: j['name'] is String ? j['name'] as String : 'Animation',
    );
    if (j['assets'] is List) {
      for (final a in (j['assets'] as List).take(maxAssets)) {
        final asset = AnimAsset.fromJson(a);
        doc.assets[asset.id] = asset;
      }
    }
    if (j['bgImg'] != null) doc.backgroundImage = AnimImage.fromJson(j['bgImg']);
    if (j['layers'] is List) {
      for (final l in (j['layers'] as List).take(maxLayers)) {
        doc.layers.add(AnimLayer.fromJson(l));
      }
    }
    if (j['refs'] is List) {
      for (final r in (j['refs'] as List).take(maxReferences)) {
        doc.references.add(AnimImage.fromJson(r));
      }
    }
    // Every placed picture must point at a registered asset.
    for (final id in doc.usedAssetIds) {
      if (!doc.assets.containsKey(id)) throw const AnimationException('The animation refers to a missing image.');
    }
    final range = j['range'];
    if (range is List && range.length == 2 && range[0] is int && range[1] is int) {
      doc.rangeStart = (range[0] as int).clamp(0, frames.length - 1);
      doc.rangeEnd = (range[1] as int).clamp(doc.rangeStart, frames.length - 1);
    }
    return doc;
  }
}

/// Byte-budgeted LRU cache (for rendered frame images / thumbnails). Generic
/// so it can be tested without the Flutter engine.
class BudgetCache<K, V> {
  BudgetCache(this.maxBytes, {void Function(V value)? onEvict}) : _onEvict = onEvict;
  final int maxBytes;
  final void Function(V value)? _onEvict;
  final _items = <K, (V, int)>{};
  int _bytes = 0;

  int get bytes => _bytes;
  int get length => _items.length;

  V? get(K key) {
    final e = _items.remove(key);
    if (e == null) return null;
    _items[key] = e;
    return e.$1;
  }

  void put(K key, V value, int size) {
    final old = _items.remove(key);
    if (old != null) {
      _bytes -= old.$2;
      _onEvict?.call(old.$1);
    }
    _items[key] = (value, size);
    _bytes += size;
    while (_bytes > maxBytes && _items.length > 1) {
      final k = _items.keys.first;
      final e = _items.remove(k)!;
      _bytes -= e.$2;
      _onEvict?.call(e.$1);
    }
  }

  void remove(K key) {
    final e = _items.remove(key);
    if (e != null) {
      _bytes -= e.$2;
      _onEvict?.call(e.$1);
    }
  }

  void clear() {
    for (final e in _items.values) {
      _onEvict?.call(e.$1);
    }
    _items.clear();
    _bytes = 0;
  }
}
