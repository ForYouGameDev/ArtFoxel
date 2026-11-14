import 'dart:ui';

import '../../studio/domain/builtin_brushes.dart';
import '../../studio/domain/canvas_document.dart';
import '../../studio/domain/sketch_document_data.dart';
import '../../studio/domain/stroke_model.dart';
import '../domain/animation_model.dart';

/// Gives frames their shared-engine artwork document.
abstract final class FrameArt {
  /// Makes sure [frame] has an artwork document sized like the animation.
  /// Legacy vector strokes are converted once (same colour, width and
  /// erasing) and removed from the frame, so nothing is drawn twice.
  static SketchDocumentData ensure(AnimationDocument doc, AnimFrame frame) {
    final existing = frame.art;
    if (existing != null) return existing;
    final art = SketchDocumentData.blank(
      CanvasDocument(width: doc.width, height: doc.height, backgroundColor: null),
    );
    final pen = BuiltInBrushes.byId('builtin.monoline') ?? BuiltInBrushes.defaultBrush;
    final eraser = BuiltInBrushes.byId('builtin.vector_style_eraser') ?? BuiltInBrushes.byId('builtin.eraser')!;
    final layer = art.layers.first;
    var seed = 1;
    for (final s in frame.strokes) {
      final brush = s.erase ? eraser : pen;
      layer.strokes.add(SketchStroke(
        brushKey: art.registerBrush(brush),
        colorArgb: s.colorArgb,
        size: s.width,
        opacity: 1,
        flow: 1,
        seed: seed++,
        points: [
          for (var i = 0; i < s.points.length; i++)
            StrokePoint(x: s.points[i].dx, y: s.points[i].dy, t: i * 8),
        ],
      ));
    }
    frame.strokes.clear();
    frame.art = art;
    return art;
  }

  /// True when [frame] still shows only legacy strokes (no art yet).
  static bool isLegacy(AnimFrame frame) => frame.art == null && frame.strokes.isNotEmpty;

  /// Smallest size helper for thumbnails of the artwork.
  static Rect bounds(AnimationDocument doc) => Rect.fromLTWH(0, 0, doc.width.toDouble(), doc.height.toDouble());
}
