import 'dart:math' as math;
import 'dart:ui' show Offset, Rect;

import 'affine2d.dart';
import 'alpha_mask.dart';
import 'sketch_document_data.dart';
import 'stroke_model.dart';

/// Where a smaller or larger canvas keeps the existing artwork.
enum CanvasAnchor {
  topLeft(0, 0),
  topCenter(.5, 0),
  topRight(1, 0),
  centerLeft(0, .5),
  center(.5, .5),
  centerRight(1, .5),
  bottomLeft(0, 1),
  bottomCenter(.5, 1),
  bottomRight(1, 1);

  const CanvasAnchor(this.fx, this.fy);
  final double fx;
  final double fy;

  Offset pointIn(Rect rect) =>
      Offset(rect.left + rect.width * fx, rect.top + rect.height * fy);
}

/// Geometry changes that act on the stroke data (and bitmaps) of a document.
///
/// Paint layers keep their editable strokes: a transform rewrites point
/// coordinates and brush sizes, it never flattens to pixels. Image layers keep
/// their pixels and only change placement. Layer bitmaps masks are resampled.
///
/// The three canvas operations are different things and kept separate:
///  * [cropImage]      – keeps a rectangle of the artwork; canvas becomes that size.
///  * [resizeCanvas]   – changes the canvas size around an anchor; artwork keeps its size.
///  * [resizeImage]    – scales the canvas *and* the artwork together.
abstract final class DocGeometry {
  static const int maxCanvasSide = 8192;

  static SketchStroke transformStroke(SketchStroke stroke, Affine2D m) {
    double clampCoord(double v) => v.clamp(-1000000.0, 1000000.0).toDouble();
    return stroke.copyWith(
      size: (stroke.size * m.scaleFactor).clamp(0.1, 2000.0).toDouble(),
      points: [
        for (final p in stroke.points)
          StrokePoint(
            x: clampCoord(m.applyX(p.x, p.y)),
            y: clampCoord(m.applyY(p.x, p.y)),
            t: p.t,
            pressure: p.pressure,
            tilt: p.tilt,
          ),
      ],
    );
  }

  /// Applies [m] to one layer's content and mask. Groups are not handled
  /// here; use [transformLayers] to cover a group's children.
  static void transformLayer(SketchDocumentData doc, SketchLayerData layer, Affine2D m) {
    if (layer.isImage) {
      layer.matrix = m * layer.matrix;
    } else if (layer.isPaint) {
      final moved = [for (final s in layer.strokes) transformStroke(s, m)];
      layer.strokes
        ..clear()
        ..addAll(moved);
    }
    final mask = layer.mask;
    if (mask != null) {
      final moved = [for (final s in mask.strokes) transformStroke(s, m)];
      mask.strokes
        ..clear()
        ..addAll(moved);
      final bitmap = mask.bitmap;
      if (bitmap != null) {
        mask.bitmap = bitmap.resampled(
          fromWidth: doc.width.toDouble(),
          fromHeight: doc.height.toDouble(),
          toWidth: doc.width.toDouble(),
          toHeight: doc.height.toDouble(),
          pixelWidth: bitmap.width,
          pixelHeight: bitmap.height,
          transform: m,
          // Outside the old bitmap the mask reveals (white), like a fresh mask.
          outside: 255,
        );
      }
    }
  }

  static void transformLayers(
    SketchDocumentData doc,
    Iterable<SketchLayerData> layers,
    Affine2D m,
  ) {
    for (final layer in layers) {
      transformLayer(doc, layer, m);
    }
  }

  static Rect? strokeBounds(SketchStroke stroke) {
    if (stroke.points.isEmpty) return null;
    var minX = double.infinity, minY = double.infinity;
    var maxX = -double.infinity, maxY = -double.infinity;
    for (final p in stroke.points) {
      minX = math.min(minX, p.x);
      maxX = math.max(maxX, p.x);
      minY = math.min(minY, p.y);
      maxY = math.max(maxY, p.y);
    }
    final pad = stroke.size / 2 * 1.5;
    return Rect.fromLTRB(minX - pad, minY - pad, maxX + pad, maxY + pad);
  }

  /// Bounds of everything a layer draws, or null when it is empty.
  static Rect? contentBounds(SketchLayerData layer) {
    Rect? out;
    void add(Rect? r) => out = r == null ? out : (out == null ? r : out!.expandToInclude(r));
    for (final s in layer.strokes) {
      add(strokeBounds(s));
    }
    final image = layer.image;
    if (image != null) {
      add(layer.matrix.mapRect(Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble())));
    }
    return out;
  }

  static void _checkSize(int width, int height) {
    if (width < 1 || height < 1 || width > maxCanvasSide || height > maxCanvasSide) {
      throw ArgumentError('The canvas must be between 1 and $maxCanvasSide pixels per side.');
    }
  }

  /// Re-fits every layer bitmap mask to the (new) document size.
  static void _remapMasks(
    SketchDocumentData doc,
    int oldW,
    int oldH,
    Affine2D oldToNew,
  ) {
    final (mw, mh) = AlphaMask.sizeFor(doc.width, doc.height);
    for (final layer in doc.layers) {
      final bitmap = layer.mask?.bitmap;
      if (bitmap == null) continue;
      layer.mask!.bitmap = bitmap.resampled(
        fromWidth: oldW.toDouble(),
        fromHeight: oldH.toDouble(),
        toWidth: doc.width.toDouble(),
        toHeight: doc.height.toDouble(),
        pixelWidth: mw,
        pixelHeight: mh,
        transform: oldToNew,
        outside: 255,
      );
    }
  }

  /// Applies [m] to every layer and gives the document its new size.
  static void _applyToAll(
    SketchDocumentData doc,
    Affine2D m,
    int newWidth,
    int newHeight, {
    required bool discardOutside,
  }) {
    _checkSize(newWidth, newHeight);
    final oldW = doc.width, oldH = doc.height;
    for (final layer in doc.layers) {
      if (layer.isGroup) continue;
      // Bitmap masks are resampled afterwards against the new canvas.
      final bitmap = layer.mask?.bitmap;
      layer.mask?.bitmap = null;
      transformLayer(doc, layer, m);
      layer.mask?.bitmap = bitmap;
    }
    doc.width = newWidth;
    doc.height = newHeight;
    final mapped = m.mapRect(doc.safeBounds);
    final canvas = Rect.fromLTWH(0, 0, newWidth.toDouble(), newHeight.toDouble());
    final safe = mapped.intersect(canvas);
    doc.safeBounds = safe.isEmpty || safe.width <= 0 || safe.height <= 0 ? canvas : safe;
    _remapMasks(doc, oldW, oldH, m);
    if (discardOutside) {
      for (final layer in doc.layers) {
        layer.strokes.removeWhere((s) {
          final b = strokeBounds(s);
          return b != null && !b.overlaps(canvas);
        });
        layer.mask?.strokes.removeWhere((s) {
          final b = strokeBounds(s);
          return b != null && !b.overlaps(canvas);
        });
      }
    }
  }

  /// Crop image: the canvas becomes [rect] (document pixels, integer-aligned);
  /// artwork keeps its scale and is shifted. With [discardOutside] strokes that
  /// end up entirely outside are removed; otherwise they stay stored (and
  /// reappear if the canvas is later enlarged).
  static void cropImage(
    SketchDocumentData doc,
    Rect rect, {
    bool discardOutside = false,
  }) {
    final left = rect.left.round(), top = rect.top.round();
    final width = rect.width.round(), height = rect.height.round();
    _applyToAll(
      doc,
      Affine2D.translation(-left.toDouble(), -top.toDouble()),
      width,
      height,
      discardOutside: discardOutside,
    );
  }

  /// Resize canvas: new size, artwork keeps its size and sits at [anchor].
  static void resizeCanvas(
    SketchDocumentData doc,
    int width,
    int height, {
    CanvasAnchor anchor = CanvasAnchor.center,
    bool discardOutside = false,
  }) {
    _checkSize(width, height);
    final dx = (width - doc.width) * anchor.fx;
    final dy = (height - doc.height) * anchor.fy;
    _applyToAll(
      doc,
      Affine2D.translation(dx.roundToDouble(), dy.roundToDouble()),
      width,
      height,
      discardOutside: discardOutside,
    );
  }

  /// Resize image: canvas and artwork are scaled together.
  static void resizeImage(SketchDocumentData doc, int width, int height) {
    _checkSize(width, height);
    _applyToAll(
      doc,
      Affine2D.scale(width / doc.width, height / doc.height),
      width,
      height,
      discardOutside: false,
    );
  }
}
