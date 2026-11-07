import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import '../../../core/diagnostics/app_log.dart';
import '../domain/affine2d.dart';
import '../domain/alpha_mask.dart';
import '../domain/brush_preset.dart';
import '../domain/layer_ops.dart';
import '../domain/sketch_document_data.dart';
import '../domain/stroke_model.dart';
import 'brush_renderer.dart';
import 'sketch_raster.dart';

/// A temporary transform shown while the user is adjusting a layer. The
/// stored strokes are untouched until the transform is confirmed.
class TransformPreview {
  const TransformPreview({required this.layerIds, required this.matrix});

  final Set<String> layerIds;
  final Affine2D matrix;
}

/// The stroke currently being drawn (not yet part of the document).
class LiveStroke {
  const LiveStroke({
    required this.layerId,
    required this.stroke,
    required this.brush,
    required this.onMask,
  });

  final String layerId;
  final SketchStroke stroke;
  final BrushPreset brush;
  final bool onMask;
}

// Luminance (Rec. 709) of the mask image becomes the alpha used by dstIn.
const List<double> _lumToAlpha = [
  0, 0, 0, 0, 0, //
  0, 0, 0, 0, 0, //
  0, 0, 0, 0, 0, //
  0.2126, 0.7152, 0.0722, 0, 0, //
];
const List<double> _lumToAlphaInverted = [
  0, 0, 0, 0, 0, //
  0, 0, 0, 0, 0, //
  0, 0, 0, 0, 0, //
  -0.2126, -0.7152, -0.0722, 0, 255, //
];

/// Draws the layer tree. It owns the per-layer raster caches and GPU images
/// but no document state: everything it draws comes from the
/// [SketchDocumentData], so UI state (selection, panel expansion) never
/// affects rendering and the project is never flattened by ordinary edits.
class LayerCompositor {
  LayerCompositor({
    required this.doc,
    this.useRasters = true,
    this.onImageReady,
  });

  final SketchDocumentData doc;

  /// False in unit tests: layers replay their strokes instead of caching GPU
  /// images, and no images are created.
  final bool useRasters;

  /// Called when an asynchronously created image became available.
  final VoidCallback? onImageReady;

  final Map<String, SketchRaster> _content = {};
  final Map<String, SketchRaster> _maskStrokes = {};
  final Map<Object, ui.Image> _images = {};
  final Set<Object> _pending = {};

  Rect get _docRect => Rect.fromLTWH(0, 0, doc.width.toDouble(), doc.height.toDouble());

  // ---- cache maintenance --------------------------------------------------------

  SketchRaster? _rasterFor(
    Map<String, SketchRaster> cache,
    String id,
    List<SketchStroke> strokes,
  ) {
    if (!useRasters) return null;
    var raster = cache[id];
    if (raster == null) {
      raster = SketchRaster(
        width: doc.width,
        height: doc.height,
        resolve: (key) => doc.brushes[key],
      )..rebuild(strokes);
      cache[id] = raster;
    }
    return raster;
  }

  /// A stroke was appended to a layer (or its mask).
  void commit(SketchLayerData layer, {bool mask = false}) {
    final strokes = mask ? layer.mask!.strokes : layer.strokes;
    final cache = mask ? _maskStrokes : _content;
    final raster = cache[layer.id];
    if (raster == null) {
      _rasterFor(cache, layer.id, strokes); // builds from all strokes
    } else {
      raster.commit(strokes);
    }
  }

  /// Strokes of one layer (or its mask) changed in other ways (undo, edits).
  void invalidate(String layerId, {bool mask = false}) {
    (mask ? _maskStrokes : _content).remove(layerId)?.dispose();
  }

  /// Drops every cache (geometry change, history jump). Rebuilt lazily.
  void invalidateAll() {
    for (final r in _content.values) {
      r.dispose();
    }
    for (final r in _maskStrokes.values) {
      r.dispose();
    }
    _content.clear();
    _maskStrokes.clear();
  }

  void dispose() {
    invalidateAll();
    for (final image in _images.values) {
      image.dispose();
    }
    _images.clear();
  }

  // ---- async images ---------------------------------------------------------------

  /// Creates the GPU images needed to draw [doc]: bitmap masks and image
  /// layers. Call after loading and after any operation that adds new ones.
  Future<void> prepareAll() async {
    if (!useRasters) return;
    for (final layer in doc.layers) {
      final bitmap = layer.mask?.bitmap;
      if (bitmap != null) await _ensure(bitmap, () => _maskHideBytes(bitmap), bitmap.width, bitmap.height);
      final image = layer.displayImage;
      if (image != null) await _ensure(image, () => image.rgba, image.width, image.height);
    }
  }

  Future<void> _ensure(
    Object key,
    Uint8List Function() bytes,
    int width,
    int height,
  ) async {
    if (!useRasters || _images.containsKey(key)) return;
    final completer = Completer<ui.Image?>();
    try {
      ui.decodeImageFromPixels(
        bytes(),
        width,
        height,
        ui.PixelFormat.rgba8888,
        completer.complete,
      );
      final image = await completer.future;
      if (image != null) _images[key] = image;
    } catch (error, stack) {
      AppLog.error('Image creation failed', error: error, stackTrace: stack);
    }
  }

  /// Image of "how much is hidden" (black, alpha = 255 - value) so drawing it
  /// over white leaves a gray equal to the mask value.
  static Uint8List _maskHideBytes(AlphaMask mask) {
    final out = Uint8List(mask.width * mask.height * 4);
    for (var i = 0; i < mask.data.length; i++) {
      out[i * 4 + 3] = 255 - mask.data[i];
    }
    return out;
  }

  ui.Image? _imageOrRequest(Object key, Uint8List Function() bytes, int w, int h) {
    final image = _images[key];
    if (image != null || !useRasters) return image;
    if (_pending.add(key)) {
      _ensure(key, bytes, w, h).whenComplete(() {
        _pending.remove(key);
        onImageReady?.call();
      });
    }
    return null;
  }

  /// Makes a displayable image from an arbitrary RGBA buffer (selection
  /// overlays). The caller owns and disposes it.
  static Future<ui.Image?> imageFromRgba(Uint8List rgba, int width, int height) {
    final completer = Completer<ui.Image?>();
    try {
      ui.decodeImageFromPixels(rgba, width, height, ui.PixelFormat.rgba8888, completer.complete);
    } catch (error, stack) {
      AppLog.error('Overlay image failed', error: error, stackTrace: stack);
      completer.complete(null);
    }
    return completer.future;
  }

  // ---- painting ----------------------------------------------------------------------

  /// Paints the whole visible layer tree in document coordinates.
  void paint(
    Canvas canvas, {
    LiveStroke? live,
    TransformPreview? preview,
  }) {
    _paintChildren(canvas, null, live, preview);
  }

  /// Paints one layer (or group) alone, for thumbnails.
  void paintAlone(Canvas canvas, SketchLayerData layer) {
    _paintContent(canvas, layer, null, null);
  }

  void _paintChildren(
    Canvas canvas,
    String? parentId,
    LiveStroke? live,
    TransformPreview? preview,
  ) {
    final siblings = LayerOps.children(doc, parentId);
    var i = 0;
    while (i < siblings.length) {
      final base = siblings[i++];
      final clipped = <SketchLayerData>[];
      while (i < siblings.length && siblings[i].clipToBelow) {
        clipped.add(siblings[i++]);
      }
      if (!base.visible) continue;
      final visibleClipped = [for (final c in clipped) if (c.visible) c];
      if (visibleClipped.isEmpty) {
        _paintNode(canvas, base, live, preview);
        continue;
      }
      canvas.saveLayer(null, _compositePaint(base));
      _paintContent(canvas, base, live, preview);
      for (final c in visibleClipped) {
        canvas.saveLayer(null, _compositePaint(c));
        canvas.saveLayer(null, Paint());
        _paintContent(canvas, c, live, preview);
        // Keep only what overlaps the base layer's own coverage.
        canvas.saveLayer(null, Paint()..blendMode = ui.BlendMode.dstIn);
        _paintContent(canvas, base, live, preview);
        canvas.restore();
        canvas.restore();
        canvas.restore();
      }
      canvas.restore();
    }
  }

  Paint _compositePaint(SketchLayerData layer) => Paint()
    ..blendMode = layer.blend.flutter
    ..color = Color.fromRGBO(0, 0, 0, layer.opacity.clamp(0.0, 1.0).toDouble());

  void _paintNode(
    Canvas canvas,
    SketchLayerData layer,
    LiveStroke? live,
    TransformPreview? preview,
  ) {
    final plain = layer.blend.flutter == ui.BlendMode.srcOver &&
        layer.opacity >= 1 &&
        !_needsIsolation(layer, live);
    if (plain) {
      _paintContent(canvas, layer, live, preview);
      return;
    }
    canvas.saveLayer(null, _compositePaint(layer));
    _paintContent(canvas, layer, live, preview);
    canvas.restore();
  }

  bool _hasActiveMask(SketchLayerData layer) =>
      layer.mask != null && layer.mask!.enabled;

  bool _needsIsolation(SketchLayerData layer, LiveStroke? live) =>
      _hasActiveMask(layer) || (live != null && live.layerId == layer.id) || layer.isGroup;

  /// The layer's own pixels (mask applied), without its blend mode/opacity.
  void _paintContent(
    Canvas canvas,
    SketchLayerData layer,
    LiveStroke? live,
    TransformPreview? preview,
  ) {
    final transform = preview != null && preview.layerIds.contains(layer.id)
        ? preview.matrix
        : null;
    final masked = _hasActiveMask(layer);
    final liveHere = live != null && live.layerId == layer.id ? live : null;
    final isolate = masked || liveHere != null;

    if (transform != null) {
      canvas.save();
      canvas.transform(transform.toMatrix4());
    }
    if (layer.isGroup) {
      _paintChildren(canvas, layer.id, live, preview);
    } else {
      if (isolate) canvas.saveLayer(null, Paint());
      _paintPixels(canvas, layer, liveHere);
      if (masked) _paintMask(canvas, layer, liveHere);
      if (isolate) canvas.restore();
    }
    if (transform != null) canvas.restore();
  }

  void _paintPixels(Canvas canvas, SketchLayerData layer, LiveStroke? live) {
    final image = layer.displayImage;
    if (image != null) {
      final ui.Image? ready = _imageOrRequest(image, () => image.rgba, image.width, image.height);
      if (ready != null) {
        canvas.save();
        canvas.transform(layer.matrix.toMatrix4());
        final base = layer.image;
        if (base != null && !identical(base, image)) {
          // A preview/processed image may have a different resolution.
          canvas.scale(base.width / image.width, base.height / image.height);
        }
        canvas.drawImage(ready, Offset.zero, Paint()..filterQuality = FilterQuality.medium);
        canvas.restore();
      }
    }
    if (layer.strokes.isNotEmpty) {
      final raster = _rasterFor(_content, layer.id, layer.strokes);
      if (raster != null) {
        raster.paintCommitted(canvas, layer.strokes);
      } else {
        for (final stroke in layer.strokes) {
          _replay(canvas, stroke);
        }
      }
    }
    for (final shape in layer.shapes) {
      shape.paintTo(canvas);
    }
    if (live != null && !live.onMask) {
      _paintLive(canvas, live, layer.alphaLock);
    }
  }

  void _replay(Canvas canvas, SketchStroke stroke) {
    final brush = doc.brushes[stroke.brushKey];
    if (brush == null) return;
    if (stroke.alphaLock) {
      canvas.saveLayer(null, Paint()..blendMode = ui.BlendMode.srcATop);
      BrushRenderer.paintStroke(canvas, stroke, brush);
      canvas.restore();
    } else {
      BrushRenderer.paintStroke(canvas, stroke, brush);
    }
  }

  void _paintLive(Canvas canvas, LiveStroke live, bool alphaLock) {
    if (alphaLock && !live.brush.erase) {
      canvas.saveLayer(null, Paint()..blendMode = ui.BlendMode.srcATop);
      BrushRenderer.paintStroke(canvas, live.stroke, live.brush);
      canvas.restore();
    } else {
      BrushRenderer.paintStroke(canvas, live.stroke, live.brush);
    }
  }

  /// Multiplies the current layer by the mask (white shows, black hides).
  void _paintMask(Canvas canvas, SketchLayerData layer, LiveStroke? live) {
    final mask = layer.mask!;
    canvas.saveLayer(
      null,
      Paint()
        ..blendMode = ui.BlendMode.dstIn
        ..colorFilter = ColorFilter.matrix(mask.inverted ? _lumToAlphaInverted : _lumToAlpha),
    );
    paintMaskValue(canvas, layer, live);
    canvas.restore();
  }

  /// Draws the mask as a gray image (white = shown, black = hidden), without
  /// the invert flag. Used for display and for baking mask strokes into a
  /// bitmap.
  void paintMaskValue(Canvas canvas, SketchLayerData layer, [LiveStroke? live]) {
    final mask = layer.mask!;
    canvas.drawRect(_docRect, Paint()..color = const Color(0xFFFFFFFF));
    final bitmap = mask.bitmap;
    if (bitmap != null) {
      final image = _imageOrRequest(bitmap, () => _maskHideBytes(bitmap), bitmap.width, bitmap.height);
      if (image != null) {
        canvas.drawImageRect(
          image,
          Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
          _docRect,
          Paint()..filterQuality = FilterQuality.medium,
        );
      }
    }
    // Strokes are composed on their own so an eraser stroke removes mask
    // paint (revealing the bitmap/white below) instead of cutting a hole.
    canvas.saveLayer(null, Paint());
    if (mask.strokes.isNotEmpty) {
      final raster = _rasterFor(_maskStrokes, layer.id, mask.strokes);
      if (raster != null) {
        raster.paintCommitted(canvas, mask.strokes);
      } else {
        for (final stroke in mask.strokes) {
          _replay(canvas, stroke);
        }
      }
    }
    if (live != null && live.onMask) {
      BrushRenderer.paintStroke(canvas, live.stroke, live.brush);
    }
    canvas.restore();
  }
}
