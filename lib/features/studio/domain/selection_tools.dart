import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:collection';

import 'alpha_mask.dart';

/// Pixel-based selection helpers working on straight RGBA bytes (as produced
/// by `Image.toByteData(rawStraightRgba)`) at mask resolution.
abstract final class SelectionTools {
  static int _distance(Uint8List rgba, int i, int r, int g, int b, int a) {
    final dr = (rgba[i] - r).abs();
    final dg = (rgba[i + 1] - g).abs();
    final db = (rgba[i + 2] - b).abs();
    final da = (rgba[i + 3] - a).abs();
    return math.max(math.max(dr, dg), math.max(db, da));
  }

  /// Magic wand: selects pixels whose colour is within [tolerance] (0..255,
  /// per-channel maximum difference) of the pixel at ([x], [y]). With
  /// [contiguous] only the connected region (4-neighbourhood) is selected.
  static AlphaMask magicWand(
    Uint8List rgba,
    int width,
    int height,
    int x,
    int y, {
    int tolerance = 32,
    bool contiguous = true,
  }) {
    if (rgba.length != width * height * 4) {
      throw ArgumentError('Pixel buffer does not match ${width}x$height.');
    }
    final out = Uint8List(width * height);
    if (x < 0 || y < 0 || x >= width || y >= height) {
      return AlphaMask(width, height, out);
    }
    final seed = (y * width + x) * 4;
    final r = rgba[seed], g = rgba[seed + 1], b = rgba[seed + 2], a = rgba[seed + 3];
    bool matches(int pixel) => _distance(rgba, pixel * 4, r, g, b, a) <= tolerance;

    if (!contiguous) {
      for (var p = 0; p < out.length; p++) {
        if (matches(p)) out[p] = 255;
      }
      return AlphaMask(width, height, out);
    }
    final queue = Queue<int>()..add(y * width + x);
    out[y * width + x] = 255;
    while (queue.isNotEmpty) {
      final p = queue.removeFirst();
      final px = p % width, py = p ~/ width;
      void visit(int nx, int ny) {
        if (nx < 0 || ny < 0 || nx >= width || ny >= height) return;
        final n = ny * width + nx;
        if (out[n] == 0 && matches(n)) {
          out[n] = 255;
          queue.add(n);
        }
      }

      visit(px - 1, py);
      visit(px + 1, py);
      visit(px, py - 1);
      visit(px, py + 1);
    }
    return AlphaMask(width, height, out);
  }

  /// Colour range: selects every pixel similar to ([r], [g], [b]) with a soft
  /// falloff. Pixels within [tolerance] are fully selected; between
  /// [tolerance] and [tolerance] + [fuzziness] the coverage fades out.
  static AlphaMask colorRange(
    Uint8List rgba,
    int width,
    int height,
    int r,
    int g,
    int b, {
    int tolerance = 32,
    int fuzziness = 32,
  }) {
    if (rgba.length != width * height * 4) {
      throw ArgumentError('Pixel buffer does not match ${width}x$height.');
    }
    final out = Uint8List(width * height);
    for (var p = 0; p < out.length; p++) {
      final i = p * 4;
      if (rgba[i + 3] == 0) continue;
      final d = math.max(
        (rgba[i] - r).abs(),
        math.max((rgba[i + 1] - g).abs(), (rgba[i + 2] - b).abs()),
      );
      if (d <= tolerance) {
        out[p] = 255;
      } else if (fuzziness > 0 && d < tolerance + fuzziness) {
        out[p] = (255 * (1 - (d - tolerance) / fuzziness)).round();
      }
    }
    return AlphaMask(width, height, out);
  }

  /// Copies the pixels of [rgba] covered by [mask] into a new straight-RGBA
  /// buffer cropped to the mask's bounding box. Coverage becomes alpha.
  /// Returns null when the mask is empty.
  static ({Uint8List rgba, int x, int y, int width, int height})? extract(
    Uint8List rgba,
    int width,
    int height,
    AlphaMask mask,
  ) {
    if (mask.width != width || mask.height != height) {
      throw ArgumentError('Mask and pixels must have the same size.');
    }
    final box = mask.bounds();
    if (box == null) return null;
    final x0 = box.left.toInt(), y0 = box.top.toInt();
    final w = box.width.toInt(), h = box.height.toInt();
    final out = Uint8List(w * h * 4);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final src = (y0 + y) * width + (x0 + x);
        final cover = mask.data[src];
        final s = src * 4, d = (y * w + x) * 4;
        out[d] = rgba[s];
        out[d + 1] = rgba[s + 1];
        out[d + 2] = rgba[s + 2];
        out[d + 3] = (rgba[s + 3] * cover + 127) ~/ 255;
      }
    }
    return (rgba: out, x: x0, y: y0, width: w, height: h);
  }
}
