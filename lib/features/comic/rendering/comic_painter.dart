import 'dart:typed_data';
import 'dart:ui';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter/rendering.dart';

import '../domain/comic_model.dart';

/// Draws comic pages. The same code paints the on-screen preview and the
/// exported image; only [showGuides] differs (guides are never exported).
abstract final class ComicPainter {
  static void paintPage(
    Canvas canvas,
    ComicDocument doc,
    ComicPage page, {
    bool showGuides = false,
    bool paper = true,
  }) {
    final spec = doc.specFor(page);
    if (paper) canvas.drawRect(spec.bleedRect, Paint()..color = const Color(0xFFFFFFFF));

    // Panel fills first, then content, then borders on top.
    for (final panel in page.panels) {
      if ((panel.fillArgb >> 24) != 0) {
        canvas.drawPath(panel.path, Paint()..color = Color(panel.fillArgb));
      }
    }
    for (final el in page.elements) {
      if (el.hidden) continue;
      final panel = el.panelId == null ? null : page.panelById(el.panelId!);
      final clip = panel != null && panel.clipContent;
      canvas.saveLayer(null, Paint()..color = Color.fromRGBO(255, 255, 255, el.opacity));
      if (clip) canvas.clipPath(panel.path, doAntiAlias: true);
      paintElement(canvas, el);
      canvas.restore();
    }
    for (final panel in page.panels) {
      if (panel.borderWidth > 0) {
        canvas.drawPath(
          panel.path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = panel.borderWidth
            ..strokeJoin = StrokeJoin.miter
            ..color = Color(panel.borderArgb),
        );
      }
    }
    if (showGuides) paintGuides(canvas, spec);
  }

  static void paintElement(Canvas canvas, ComicElement el) {
    switch (el) {
      case ScreentoneElement():
        canvas.save();
        canvas.clipRect(el.area);
        canvas.drawPath(el.buildPath(), Paint()..color = Color(el.colorArgb)..isAntiAlias = true);
        canvas.restore();
      case SpeedLinesElement():
        canvas.save();
        canvas.clipRect(el.area);
        canvas.drawPath(el.buildPath(), Paint()..color = Color(el.colorArgb)..isAntiAlias = true);
        canvas.restore();
      case BubbleElement():
        _bubble(canvas, el);
      case TextBoxElement():
        canvas.save();
        if (el.rotationDegrees != 0) {
          canvas.translate(el.rect.center.dx, el.rect.center.dy);
          canvas.rotate(el.rotationDegrees * 3.141592653589793 / 180);
          canvas.translate(-el.rect.center.dx, -el.rect.center.dy);
        }
        TextRenderer.paint(canvas, el.text, el.rect);
        canvas.restore();
      default:
        break;
    }
  }

  static void _bubble(Canvas canvas, BubbleElement b) {
    final path = b.buildPath();
    canvas.drawPath(path, Paint()..color = Color(b.fillArgb)..isAntiAlias = true);
    if (b.strokeArgb != null && b.strokeWidth > 0) {
      final stroke = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = b.strokeWidth
        ..strokeJoin = StrokeJoin.round
        ..color = Color(b.strokeArgb!)
        ..isAntiAlias = true;
      if (b.dashed) {
        _dashed(canvas, path, stroke, b.strokeWidth * 3, b.strokeWidth * 2);
      } else {
        canvas.drawPath(path, stroke);
      }
    }
    TextRenderer.paint(canvas, b.text, b.textRect);
  }

  static void _dashed(Canvas canvas, Path path, Paint paint, double dash, double gap) {
    for (final m in path.computeMetrics()) {
      var d = 0.0;
      while (d < m.length) {
        canvas.drawPath(m.extractPath(d, (d + dash).clamp(0, m.length).toDouble()), paint);
        d += dash + gap;
      }
    }
  }

  /// Trim, bleed and safe-area guides (editing only).
  static void paintGuides(Canvas canvas, ComicPageSpec spec) {
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawRect(spec.bleedRect.deflate(1), p..color = const Color(0xAAFF3366));
    canvas.drawRect(spec.trimRect, p..color = const Color(0xAA3377FF));
    canvas.drawRect(spec.safeRect, p..color = const Color(0xAA22AA66));
  }

  /// Renders [page] to PNG bytes. [includeBleed] false crops to the trim box.
  /// Guides are never drawn.
  static Future<Uint8List> renderPng(ComicDocument doc, ComicPage page,
      {double scale = 1, bool includeBleed = false}) async {
    final spec = doc.specFor(page);
    final area = includeBleed ? spec.bleedRect : spec.trimRect;
    final w = (area.width * scale).round().clamp(1, 16384), h = (area.height * scale).round().clamp(1, 16384);
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec)
      ..scale(w / area.width, h / area.height)
      ..translate(-area.left, -area.top);
    paintPage(canvas, doc, page);
    final pic = rec.endRecording();
    final img = await pic.toImage(w, h);
    pic.dispose();
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    img.dispose();
    if (data == null) throw const ComicException('The page could not be rendered.');
    return data.buffer.asUint8List();
  }
}

/// Widget-side painter for the editor preview.
class ComicPagePreviewPainter extends CustomPainter {
  ComicPagePreviewPainter(this.doc, this.page, {this.showGuides = true, this.selectedPanelId});
  final ComicDocument doc;
  final ComicPage page;
  final bool showGuides;
  final String? selectedPanelId;

  @override
  void paint(Canvas canvas, Size size) {
    final spec = doc.specFor(page);
    final s = size.width / spec.canvasSize.width;
    canvas.save();
    canvas.scale(s);
    ComicPainter.paintPage(canvas, doc, page, showGuides: showGuides);
    final sel = selectedPanelId == null ? null : page.panelById(selectedPanelId!);
    if (sel != null) {
      canvas.drawPath(sel.path, Paint()..style = PaintingStyle.stroke..strokeWidth = 6 / s * 0.5..color = const Color(0xFF3377FF));
      for (final c in sel.corners) {
        canvas.drawCircle(c, 10, Paint()..color = const Color(0xFFFFFFFF));
        canvas.drawCircle(c, 10, Paint()..style = PaintingStyle.stroke..strokeWidth = 3..color = const Color(0xFF3377FF));
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant ComicPagePreviewPainter old) => true;
}
