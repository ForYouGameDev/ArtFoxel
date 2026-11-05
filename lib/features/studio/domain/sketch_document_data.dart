import 'dart:convert';
import 'dart:io' show gzip;
import 'dart:typed_data';

import 'package:flutter/painting.dart';

import 'affine2d.dart';
import 'alpha_mask.dart';
import 'brush_preset.dart';
import 'canvas_document.dart';
import 'layer_blend.dart';
import 'stroke_model.dart';

class SketchFormatException implements Exception {
  const SketchFormatException(this.message);

  final String message;

  @override
  String toString() => message;
}

enum LayerKind { paint, group, image }

/// Pixels of an image layer (straight RGBA). Placement in the document is the
/// owning layer's [SketchLayerData.matrix], which maps pixel coordinates to
/// document coordinates.
class LayerImage {
  LayerImage({required this.width, required this.height, required this.rgba}) {
    if (width < 1 ||
        height < 1 ||
        width > AlphaMask.maxLoadSide ||
        height > AlphaMask.maxLoadSide ||
        rgba.length != width * height * 4) {
      throw ArgumentError('Invalid layer image ${width}x$height.');
    }
  }

  final int width;
  final int height;
  final Uint8List rgba;
  String? _encoded;

  Map<String, Object?> toJson() => {
        'w': width,
        'h': height,
        'z': _encoded ??= base64Encode(gzip.encode(rgba)),
      };

  static LayerImage fromJson(Object? raw) {
    if (raw is! Map<String, dynamic>) {
      throw const FormatException('Invalid layer image.');
    }
    final w = raw['w'], h = raw['h'], z = raw['z'];
    if (w is! int || h is! int || z is! String) {
      throw const FormatException('Invalid layer image fields.');
    }
    try {
      final bytes = Uint8List.fromList(gzip.decode(base64Decode(z)));
      final image = LayerImage(width: w, height: h, rgba: bytes);
      image._encoded = z;
      return image;
    } on FormatException {
      rethrow;
    } on Object {
      throw const FormatException('Layer image data is damaged.');
    }
  }
}

/// A non-destructive layer mask. White reveals, black hides. The mask value is
/// the [bitmap] (or "all revealed" when null) overlaid with grayscale
/// [strokes], so it stays editable and is saved exactly as authored.
class LayerMaskData {
  LayerMaskData({
    this.enabled = true,
    this.inverted = false,
    this.bitmap,
    List<SketchStroke>? strokes,
  }) : strokes = strokes ?? <SketchStroke>[];

  bool enabled;
  bool inverted;

  /// Base coverage in document space at reduced resolution; null = all white.
  AlphaMask? bitmap;
  final List<SketchStroke> strokes;

  LayerMaskData copy() => LayerMaskData(
        enabled: enabled,
        inverted: inverted,
        bitmap: bitmap,
        strokes: List.of(strokes),
      );

  Map<String, Object?> toJson() => {
        'enabled': enabled,
        'inverted': inverted,
        if (bitmap != null) 'bitmap': bitmap!.toJson(),
        'strokes': [for (final stroke in strokes) stroke.toJson()],
      };
}

class SketchLayerData {
  SketchLayerData({
    required this.id,
    required this.name,
    this.kind = LayerKind.paint,
    this.parentId,
    this.visible = true,
    this.locked = false,
    this.opacity = 1,
    this.blend = LayerBlend.normal,
    this.alphaLock = false,
    this.clipToBelow = false,
    this.expanded = true,
    this.mask,
    this.image,
    this.matrix = Affine2D.identity,
    List<SketchStroke>? strokes,
  }) : strokes = strokes ?? <SketchStroke>[];

  /// Stable for the life of the layer (survives rename, reorder, regrouping).
  final String id;
  String name;
  final LayerKind kind;

  /// Id of the containing group, or null for the top level.
  String? parentId;
  bool visible;
  bool locked;
  double opacity;
  LayerBlend blend;
  bool alphaLock;

  /// Clips this layer to the opaque area of the layer directly below it.
  bool clipToBelow;

  /// Group panel state (persisted so reopening keeps the tree as left).
  bool expanded;
  LayerMaskData? mask;

  /// Pixel content of an image layer.
  LayerImage? image;

  /// Placement of [image] in the document (identity for paint layers, whose
  /// transforms are baked into stroke geometry).
  Affine2D matrix;

  /// Mutable on purpose: the controller appends and removes strokes.
  final List<SketchStroke> strokes;

  bool get isGroup => kind == LayerKind.group;
  bool get isPaint => kind == LayerKind.paint;
  bool get isImage => kind == LayerKind.image;

  /// A detached copy. Strokes, brushes and pixel data are immutable values, so
  /// sharing them is safe; the lists holding them are copied.
  SketchLayerData copy({String? id, String? name}) => SketchLayerData(
        id: id ?? this.id,
        name: name ?? this.name,
        kind: kind,
        parentId: parentId,
        visible: visible,
        locked: locked,
        opacity: opacity,
        blend: blend,
        alphaLock: alphaLock,
        clipToBelow: clipToBelow,
        expanded: expanded,
        mask: mask?.copy(),
        image: image,
        matrix: matrix,
        strokes: List.of(strokes),
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'kind': kind.name,
        if (parentId != null) 'parent': parentId,
        'visible': visible,
        if (locked) 'locked': true,
        'opacity': opacity,
        if (blend != LayerBlend.normal) 'blend': blend.name,
        if (alphaLock) 'alphaLock': true,
        if (clipToBelow) 'clip': true,
        if (isGroup && !expanded) 'expanded': false,
        if (mask != null) 'mask': mask!.toJson(),
        if (image != null) 'image': image!.toJson(),
        if (image != null) 'matrix': matrix.toJson(),
        'strokes': [for (final stroke in strokes) stroke.toJson()],
      };
}

/// The editable Sketch Studio document as stored on disk.
///
/// This is a temporary, versioned draft format. `formatVersion` and the
/// layer/brush tables are laid out so that it can be migrated into the final
/// `.artfoxel` schema later. Brushes are stored as snapshots, so projects
/// keep rendering identically even if a preset is edited or deleted.
class SketchDocumentData {
  SketchDocumentData({
    required this.width,
    required this.height,
    required this.dpi,
    required this.backgroundArgb,
    required this.safeBounds,
    required this.createdAt,
    required this.updatedAt,
    List<SketchLayerData>? layers,
    Map<String, BrushPreset>? brushes,
  })  : layers = layers ?? [SketchLayerData(id: 'layer-1', name: 'Layer 1')],
        brushes = brushes ?? <String, BrushPreset>{};

  static const String formatName = 'artfoxel-sketch-draft';
  static const int currentVersion = 2;
  static const int maxStrokes = 20000;
  static const int maxTotalPoints = 2000000;
  static const int maxLayers = 32;

  int width;
  int height;
  double dpi;

  /// ARGB colour; null means a transparent canvas.
  int? backgroundArgb;
  Rect safeBounds;
  final DateTime createdAt;
  DateTime updatedAt;
  final List<SketchLayerData> layers;
  final Map<String, BrushPreset> brushes;

  /// The first paint layer. A convenience for code that only needs "a layer";
  /// the studio tracks the selected layer itself.
  SketchLayerData get activeLayer =>
      layers.firstWhere((l) => l.isPaint, orElse: () => layers.first);

  SketchLayerData? layerById(String id) {
    for (final layer in layers) {
      if (layer.id == id) return layer;
    }
    return null;
  }

  factory SketchDocumentData.blank(CanvasDocument canvas, {DateTime? now}) {
    final time = now ?? DateTime.now();
    return SketchDocumentData(
      width: canvas.width,
      height: canvas.height,
      dpi: canvas.dpi,
      backgroundArgb: canvas.backgroundColor?.toARGB32(),
      safeBounds: canvas.safeBounds,
      createdAt: time,
      updatedAt: time,
    );
  }

  CanvasDocument toCanvasDocument() => CanvasDocument(
        width: width,
        height: height,
        dpi: dpi,
        backgroundColor: backgroundArgb == null ? null : Color(backgroundArgb!),
        safeBounds: safeBounds,
      );

  int get strokeCount => layers.fold(
        0,
        (total, layer) =>
            total + layer.strokes.length + (layer.mask?.strokes.length ?? 0),
      );

  /// Stores a snapshot of [preset] and returns the key strokes should use.
  String registerBrush(BrushPreset preset) {
    final key = '${preset.id}@${preset.renderKey}';
    brushes.putIfAbsent(key, () => preset);
    return key;
  }

  Map<String, Object?> toJson() => {
        'format': formatName,
        'formatVersion': currentVersion,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'updatedAt': updatedAt.toUtc().toIso8601String(),
        'canvas': {
          'width': width,
          'height': height,
          'dpi': dpi,
          'background': backgroundArgb,
          'safe': [
            safeBounds.left,
            safeBounds.top,
            safeBounds.right,
            safeBounds.bottom,
          ],
        },
        'brushes': {
          for (final entry in brushes.entries) entry.key: entry.value.toJson(),
        },
        'layers': [for (final layer in layers) layer.toJson()],
      };

  /// Validates and loads a stored document. Throws [SketchFormatException]
  /// for anything that cannot be trusted; callers must leave the file alone.
  factory SketchDocumentData.fromJson(Map<String, dynamic> json) {
    try {
      return _parse(_migrate(json));
    } on SketchFormatException {
      rethrow;
    } on BrushPresetException catch (error) {
      throw SketchFormatException('Invalid brush data: ${error.message}');
    } on FormatException catch (error) {
      throw SketchFormatException(error.message);
    } on TypeError {
      throw const SketchFormatException('The project data has the wrong shape.');
    }
  }

  /// Upgrades older drafts to [currentVersion]. Version 1 is the first.
  static Map<String, dynamic> _migrate(Map<String, dynamic> json) {
    if (json['format'] != formatName) {
      throw const SketchFormatException('This is not an ARTFOXEL sketch file.');
    }
    final version = json['formatVersion'];
    if (version is! int || version < 1) {
      throw const SketchFormatException('Missing project format version.');
    }
    if (version > currentVersion) {
      throw SketchFormatException(
        'This project was saved by a newer version of ARTFOXEL '
        '(format $version).',
      );
    }
    return json;
  }

  static SketchDocumentData _parse(Map<String, dynamic> json) {
    final canvas = json['canvas'];
    if (canvas is! Map<String, dynamic>) {
      throw const SketchFormatException('Missing canvas settings.');
    }
    final width = canvas['width'];
    final height = canvas['height'];
    final dpi = canvas['dpi'];
    final background = canvas['background'];
    final safe = canvas['safe'];
    if (width is! int || height is! int || width < 1 || height < 1) {
      throw const SketchFormatException('Invalid canvas size.');
    }
    if (width > 16384 || height > 16384) {
      throw const SketchFormatException('Canvas is larger than supported.');
    }
    if (dpi is! num || !dpi.isFinite || dpi <= 0 || dpi > 5000) {
      throw const SketchFormatException('Invalid canvas resolution.');
    }
    if (background != null &&
        (background is! int || background < 0 || background > 0xFFFFFFFF)) {
      throw const SketchFormatException('Invalid background colour.');
    }
    if (safe is! List || safe.length != 4 || safe.any((v) => v is! num)) {
      throw const SketchFormatException('Invalid safe bounds.');
    }
    final bounds = Rect.fromLTRB(
      (safe[0] as num).toDouble(),
      (safe[1] as num).toDouble(),
      (safe[2] as num).toDouble(),
      (safe[3] as num).toDouble(),
    );
    final created = DateTime.tryParse('${json['createdAt']}');
    final updated = DateTime.tryParse('${json['updatedAt']}');
    if (created == null || updated == null) {
      throw const SketchFormatException('Invalid project timestamps.');
    }

    final brushes = <String, BrushPreset>{};
    final rawBrushes = json['brushes'];
    if (rawBrushes is! Map<String, dynamic>) {
      throw const SketchFormatException('Missing brush table.');
    }
    for (final entry in rawBrushes.entries) {
      final value = entry.value;
      if (value is! Map<String, dynamic>) {
        throw const SketchFormatException('Invalid brush entry.');
      }
      brushes[entry.key] = BrushPreset.fromJson(value);
    }

    final rawLayers = json['layers'];
    if (rawLayers is! List || rawLayers.isEmpty || rawLayers.length > maxLayers) {
      throw const SketchFormatException('Invalid layer list.');
    }
    var totalStrokes = 0;
    var totalPoints = 0;

    List<SketchStroke> parseStrokes(Object? rawStrokes) {
      if (rawStrokes is! List) {
        throw const SketchFormatException('Invalid layer fields.');
      }
      final strokes = <SketchStroke>[];
      for (final rawStroke in rawStrokes) {
        if (rawStroke is! Map<String, dynamic>) {
          throw const SketchFormatException('Invalid stroke.');
        }
        final stroke = SketchStroke.fromJson(rawStroke);
        if (!brushes.containsKey(stroke.brushKey)) {
          throw const SketchFormatException('A stroke refers to a missing brush.');
        }
        totalStrokes++;
        totalPoints += stroke.points.length;
        if (totalStrokes > maxStrokes || totalPoints > maxTotalPoints) {
          throw const SketchFormatException('The project is too large to open.');
        }
        strokes.add(stroke);
      }
      return strokes;
    }

    final layers = <SketchLayerData>[];
    final ids = <String>{};
    for (final raw in rawLayers) {
      if (raw is! Map<String, dynamic>) {
        throw const SketchFormatException('Invalid layer.');
      }
      final id = raw['id'];
      final name = raw['name'];
      final visible = raw['visible'];
      final opacity = raw['opacity'];
      if (id is! String ||
          id.isEmpty ||
          id.length > 64 ||
          name is! String ||
          visible is! bool ||
          opacity is! num) {
        throw const SketchFormatException('Invalid layer fields.');
      }
      if (!ids.add(id)) {
        throw const SketchFormatException('Two layers share the same id.');
      }
      final kindName = raw['kind'] ?? 'paint';
      final kind = LayerKind.values.where((k) => k.name == kindName).firstOrNull;
      if (kind == null) {
        throw SketchFormatException('Unknown layer type "$kindName".');
      }
      final parent = raw['parent'];
      if (parent != null && parent is! String) {
        throw const SketchFormatException('Invalid layer parent.');
      }

      LayerMaskData? mask;
      final rawMask = raw['mask'];
      if (rawMask != null) {
        if (rawMask is! Map<String, dynamic>) {
          throw const SketchFormatException('Invalid layer mask.');
        }
        try {
          mask = LayerMaskData(
            enabled: rawMask['enabled'] != false,
            inverted: rawMask['inverted'] == true,
            bitmap: rawMask['bitmap'] == null
                ? null
                : AlphaMask.fromJson(rawMask['bitmap']),
            strokes: parseStrokes(rawMask['strokes'] ?? const []),
          );
        } on FormatException catch (error) {
          throw SketchFormatException('Invalid mask: ${error.message}');
        }
      }

      LayerImage? image;
      var matrix = Affine2D.identity;
      if (kind == LayerKind.image) {
        try {
          image = LayerImage.fromJson(raw['image']);
        } on FormatException catch (error) {
          throw SketchFormatException(error.message);
        }
        final parsed = Affine2D.fromJson(raw['matrix']);
        if (parsed == null) {
          throw const SketchFormatException('Invalid image layer placement.');
        }
        matrix = parsed;
      }

      layers.add(
        SketchLayerData(
          id: id,
          name: name,
          kind: kind,
          parentId: parent as String?,
          visible: visible,
          locked: raw['locked'] == true,
          opacity: opacity.toDouble().clamp(0.0, 1.0).toDouble(),
          blend: LayerBlend.fromName(raw['blend'] as String?),
          alphaLock: raw['alphaLock'] == true,
          clipToBelow: raw['clip'] == true,
          expanded: raw['expanded'] != false,
          mask: mask,
          image: image,
          matrix: matrix,
          strokes: parseStrokes(raw['strokes']),
        ),
      );
    }
    for (final layer in layers) {
      final parent = layer.parentId;
      if (parent == null) continue;
      final owner = layers.where((l) => l.id == parent).firstOrNull;
      if (owner == null || !owner.isGroup || parent == layer.id) {
        throw const SketchFormatException('A layer refers to a missing group.');
      }
    }
    // Reject parent cycles (a -> b -> a).
    for (final layer in layers) {
      var current = layer;
      for (var hops = 0; current.parentId != null; hops++) {
        if (hops > layers.length) {
          throw const SketchFormatException('Layer groups contain a loop.');
        }
        current = layers.firstWhere((l) => l.id == current.parentId);
      }
    }

    final document = SketchDocumentData(
      width: width,
      height: height,
      dpi: dpi.toDouble(),
      backgroundArgb: background as int?,
      safeBounds: bounds,
      createdAt: created,
      updatedAt: updated,
      layers: layers,
      brushes: brushes,
    );
    // Reuses the CanvasDocument validation (positive size, safe bounds).
    try {
      document.toCanvasDocument();
    } on ArgumentError catch (error) {
      throw SketchFormatException('Invalid canvas: ${error.message}');
    }
    return document;
  }
}
