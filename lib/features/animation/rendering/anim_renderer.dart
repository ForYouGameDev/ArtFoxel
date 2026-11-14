import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:ui';

import '../../studio/rendering/layer_compositor.dart';
import '../domain/animation_model.dart';

/// Draws animation frames. [paintFrame] is used by the editor, thumbnails
/// and every exporter; [paintOnion] is editing-only and is never called by
/// the export path (see [renderRgba]).
typedef AnimImageLookup = ui.Image? Function(String assetId);

/// Returns the compositor that draws a frame's artwork, or null when the
/// frame has none (or when the caller has nothing cached).
typedef AnimArtLookup = LayerCompositor? Function(AnimFrame frame);

abstract final class AnimRenderer {
  static void _drawImage(Canvas canvas, AnimImage im, AnimImageLookup? lookup) {
    final img = lookup?.call(im.assetId);
    if (img == null) return;
    final m = im.matrix;
    canvas.save();
    canvas.transform(Float64List.fromList([m[0], m[1], 0, 0, m[2], m[3], 0, 0, 0, 0, 1, 0, m[4], m[5], 0, 1]));
    canvas.drawImage(img, Offset.zero, Paint()..filterQuality = FilterQuality.medium..color = Color.fromRGBO(255, 255, 255, im.opacity));
    canvas.restore();
  }

  /// Background colour, background picture, persistent layers, this frame's
  /// own pictures, then strokes. References are never drawn here.
  static void paintFrame(Canvas canvas, AnimationDocument doc, AnimFrame frame, {AnimImageLookup? images, AnimArtLookup? art}) {
    paintBackdrop(canvas, doc, frame, images: images);
    paintArt(canvas, frame, art);
  }

  /// A frame's own artwork: the shared-engine compositor when there is one,
  /// otherwise legacy strokes.
  static void paintArt(Canvas canvas, AnimFrame frame, AnimArtLookup? art, {int? tint}) {
    final compositor = frame.art == null ? null : art?.call(frame);
    if (compositor == null) {
      if (frame.strokes.isNotEmpty) paintStrokes(canvas, frame, tint);
      return;
    }
    final bounds = Rect.fromLTWH(0, 0, frame.art!.width.toDouble(), frame.art!.height.toDouble());
    canvas.saveLayer(bounds, Paint());
    compositor.paint(canvas);
    if (tint != null) {
      canvas.drawRect(bounds, Paint()..color = Color(tint)..blendMode = BlendMode.srcIn);
    }
    canvas.restore();
  }

  /// Everything under the artwork: background colour and picture, persistent
  /// layers and this frame's imported pictures.
  static void paintBackdrop(Canvas canvas, AnimationDocument doc, AnimFrame frame, {AnimImageLookup? images}) {
    canvas.drawRect(Rect.fromLTWH(0, 0, doc.width.toDouble(), doc.height.toDouble()), Paint()..color = Color(doc.backgroundArgb));
    final bg = doc.backgroundImage;
    if (bg != null) _drawImage(canvas, bg, images);
    final index = doc.frames.indexOf(frame);
    for (final l in doc.layers) {
      if (index >= 0 && l.coversFrame(index)) _drawImage(canvas, l.image, images);
    }
    for (final i in frame.images) {
      _drawImage(canvas, i, images);
    }
  }

  /// Editing aid: the reference pictures, drawn faintly above the frame by
  /// the studio. Never called by the export path.
  static void paintReferences(Canvas canvas, AnimationDocument doc, AnimImageLookup? images) {
    for (final r in doc.references) {
      _drawImage(canvas, r, images);
    }
  }

  /// Strokes only; [tint] recolours everything (used for onion ghosts).
  static void paintStrokes(Canvas canvas, AnimFrame frame, int? tint) {
    canvas.saveLayer(null, Paint());
    for (final s in frame.strokes) {
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..strokeWidth = s.width
        ..isAntiAlias = true
        ..color = Color(s.colorArgb);
      if (s.erase) paint.blendMode = BlendMode.clear;
      if (s.points.length == 1) {
        canvas.drawCircle(s.points.first, s.width / 2, paint..style = PaintingStyle.fill);
        continue;
      }
      final path = Path()..moveTo(s.points.first.dx, s.points.first.dy);
      for (var i = 1; i < s.points.length - 1; i++) {
        final mid = (s.points[i] + s.points[i + 1]) / 2;
        path.quadraticBezierTo(s.points[i].dx, s.points[i].dy, mid.dx, mid.dy);
      }
      path.lineTo(s.points.last.dx, s.points.last.dy);
      canvas.drawPath(path, paint);
    }
    if (tint != null) {
      canvas.drawRect(const Rect.fromLTWH(-1e5, -1e5, 2e5, 2e5), Paint()..color = Color(tint)..blendMode = BlendMode.srcIn);
    }
    canvas.restore();
  }

  /// Ghost frames around [index]. Editing aid only.
  static void paintOnion(Canvas canvas, AnimationDocument doc, int index, OnionSkin onion, {AnimArtLookup? art}) {
    for (final (i, opacity, isBefore) in onion.ghosts(index, doc.frames.length)) {
      canvas.saveLayer(null, Paint()..color = Color.fromRGBO(255, 255, 255, opacity.clamp(0.0, 1.0)));
      paintArt(canvas, doc.frames[i], art, tint: isBefore ? onion.beforeArgb : onion.afterArgb);
      canvas.restore();
    }
  }

  /// Renders one frame. Artwork is drawn with a throw-away compositor unless
  /// [art] already has one for the frame; onion skin and references are never
  /// part of this path.
  static Future<ui.Image> renderImage(AnimationDocument doc, AnimFrame frame, {double scale = 1, AnimImageLookup? images, AnimArtLookup? art}) async {
    final w = (doc.width * scale).round().clamp(1, doc.width), h = (doc.height * scale).round().clamp(1, doc.height);
    LayerCompositor? temp;
    var lookup = art;
    if (frame.art != null && art?.call(frame) == null) {
      temp = LayerCompositor(doc: frame.art!);
      await temp.prepareAll();
      final own = temp;
      lookup = (f) => identical(f, frame) ? own : art?.call(f);
    }
    try {
      final rec = ui.PictureRecorder();
      final canvas = Canvas(rec)..scale(w / doc.width, h / doc.height);
      paintFrame(canvas, doc, frame, images: images, art: lookup);
      final pic = rec.endRecording();
      final img = await pic.toImage(w, h);
      pic.dispose();
      return img;
    } finally {
      temp?.dispose();
    }
  }

  /// Straight-alpha RGBA pixels of one frame — what exporters use. Never
  /// contains onion skin, guides or UI.
  static Future<Uint8List> renderRgba(AnimationDocument doc, AnimFrame frame, {double scale = 1, AnimImageLookup? images, AnimArtLookup? art}) async {
    final img = await renderImage(doc, frame, scale: scale, images: images, art: art);
    final data = await img.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
    img.dispose();
    if (data == null) throw const AnimationException('A frame could not be rendered.');
    return data.buffer.asUint8List();
  }

  static (int, int) scaledSize(AnimationDocument doc, double scale) =>
      ((doc.width * scale).round().clamp(1, doc.width), (doc.height * scale).round().clamp(1, doc.height));
}
