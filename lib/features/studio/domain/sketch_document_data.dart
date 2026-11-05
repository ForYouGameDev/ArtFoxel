import 'package:flutter/painting.dart';

import 'brush_preset.dart';
import 'canvas_document.dart';
import 'stroke_model.dart';

class SketchFormatException implements Exception {
  const SketchFormatException(this.message);

  final String message;

  @override
  String toString() => message;
}

class SketchLayerData {
  SketchLayerData({
    required this.id,
    required this.name,
    this.visible = true,
    this.opacity = 1,
    List<SketchStroke>? strokes,
  }) : strokes = strokes ?? <SketchStroke>[];

  final String id;
  final String name;
  final bool visible;
  final double opacity;

  /// Mutable on purpose: the controller appends and removes strokes.
  final List<SketchStroke> strokes;

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'visible': visible,
        'opacity': opacity,
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
  static const int currentVersion = 1;
  static const int maxStrokes = 20000;
  static const int maxTotalPoints = 2000000;
  static const int maxLayers = 32;

  final int width;
  final int height;
  final double dpi;

  /// ARGB colour; null means a transparent canvas.
  final int? backgroundArgb;
  final Rect safeBounds;
  final DateTime createdAt;
  DateTime updatedAt;
  final List<SketchLayerData> layers;
  final Map<String, BrushPreset> brushes;

  /// Layer that currently receives strokes (single-layer for now).
  SketchLayerData get activeLayer => layers.first;

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

  int get strokeCount =>
      layers.fold(0, (total, layer) => total + layer.strokes.length);

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
    final layers = <SketchLayerData>[];
    for (final raw in rawLayers) {
      if (raw is! Map<String, dynamic>) {
        throw const SketchFormatException('Invalid layer.');
      }
      final id = raw['id'];
      final name = raw['name'];
      final visible = raw['visible'];
      final opacity = raw['opacity'];
      final rawStrokes = raw['strokes'];
      if (id is! String ||
          name is! String ||
          visible is! bool ||
          opacity is! num ||
          rawStrokes is! List) {
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
      layers.add(
        SketchLayerData(
          id: id,
          name: name,
          visible: visible,
          opacity: opacity.toDouble().clamp(0.0, 1.0).toDouble(),
          strokes: strokes,
        ),
      );
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
