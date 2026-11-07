import 'dart:convert';
import 'dart:io' show gzip;
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Offset, Rect;

import 'affine2d.dart';

/// How a new selection combines with the existing one.
enum SelectionMode {
  replace('Replace'),
  add('Add'),
  subtract('Subtract'),
  intersect('Intersect');

  const SelectionMode(this.label);
  final String label;
}

/// An 8-bit coverage mask (0 = nothing, 255 = fully inside).
///
/// Used for selections and for bitmap layer masks. It is stored at its own
/// pixel size ([width] x [height]) which maps onto the document rectangle, so
/// large canvases can use a reduced-resolution mask. Instances are treated as
/// immutable: every operation returns a new mask, which lets the encoded form
/// be cached for saving.
class AlphaMask {
  AlphaMask(this.width, this.height, [Uint8List? data])
      : data = data ?? Uint8List(width * height) {
    if (width < 1 || height < 1 || this.data.length != width * height) {
      throw ArgumentError('Invalid mask size ${width}x$height.');
    }
  }

  /// Largest side used when a mask is created for a document.
  static const int maxSide = 2048;

  /// Largest side accepted when loading a project.
  static const int maxLoadSide = 8192;

  final int width;
  final int height;
  final Uint8List data;

  String? _encoded;

  /// Resolution for a document of [docWidth] x [docHeight].
  static (int, int) sizeFor(int docWidth, int docHeight) {
    final scale = math.min(1.0, maxSide / math.max(docWidth, docHeight));
    return (
      math.max(1, (docWidth * scale).round()),
      math.max(1, (docHeight * scale).round()),
    );
  }

  factory AlphaMask.filled(int width, int height, int value) =>
      AlphaMask(width, height, Uint8List(width * height)..fillRange(0, width * height, value));

  factory AlphaMask.forDocument(int docWidth, int docHeight, {int value = 0}) {
    final (w, h) = sizeFor(docWidth, docHeight);
    return AlphaMask.filled(w, h, value);
  }

  // ---- queries ---------------------------------------------------------------

  bool get isEmpty {
    for (final v in data) {
      if (v != 0) return false;
    }
    return true;
  }

  bool get isFull {
    for (final v in data) {
      if (v != 255) return false;
    }
    return true;
  }

  int at(int x, int y) {
    if (x < 0 || y < 0 || x >= width || y >= height) return 0;
    return data[y * width + x];
  }

  /// Bounding box (in mask pixels) of pixels with coverage >= [threshold],
  /// or null when there are none.
  Rect? bounds({int threshold = 1}) {
    var minX = width, minY = height, maxX = -1, maxY = -1;
    for (var y = 0; y < height; y++) {
      final row = y * width;
      for (var x = 0; x < width; x++) {
        if (data[row + x] >= threshold) {
          if (x < minX) minX = x;
          if (x > maxX) maxX = x;
          if (y < minY) minY = y;
          if (y > maxY) maxY = y;
        }
      }
    }
    if (maxX < 0) return null;
    return Rect.fromLTRB(
      minX.toDouble(),
      minY.toDouble(),
      (maxX + 1).toDouble(),
      (maxY + 1).toDouble(),
    );
  }

  /// Sum of coverage as a pixel count (0..width*height).
  double get area {
    var sum = 0;
    for (final v in data) {
      sum += v;
    }
    return sum / 255;
  }

  // ---- shapes ----------------------------------------------------------------

  /// Fills a polygon given in mask pixel coordinates (even-odd), antialiased
  /// with 4 sub-scanlines and exact horizontal coverage.
  factory AlphaMask.polygon(int width, int height, List<Offset> points) {
    final out = Float32List(width * height);
    if (points.length >= 3) {
      const sub = 4;
      final n = points.length;
      var minY = points.first.dy, maxY = points.first.dy;
      for (final p in points) {
        minY = math.min(minY, p.dy);
        maxY = math.max(maxY, p.dy);
      }
      final startRow = math.max(0, minY.floor());
      final endRow = math.min(height - 1, maxY.ceil());
      final crossings = <double>[];
      for (var row = startRow; row <= endRow; row++) {
        for (var s = 0; s < sub; s++) {
          final y = row + (s + 0.5) / sub;
          crossings.clear();
          for (var i = 0; i < n; i++) {
            final a = points[i];
            final b = points[(i + 1) % n];
            if ((a.dy <= y && b.dy > y) || (b.dy <= y && a.dy > y)) {
              crossings.add(a.dx + (y - a.dy) / (b.dy - a.dy) * (b.dx - a.dx));
            }
          }
          crossings.sort();
          for (var i = 0; i + 1 < crossings.length; i += 2) {
            final x0 = math.max(0.0, crossings[i]);
            final x1 = math.min(width.toDouble(), crossings[i + 1]);
            if (x1 <= x0) continue;
            final first = x0.floor();
            final last = math.min(width - 1, (x1 - 1e-9).floor());
            for (var x = first; x <= last; x++) {
              final cover = math.min(x + 1.0, x1) - math.max(x.toDouble(), x0);
              out[row * width + x] += cover / sub;
            }
          }
        }
      }
    }
    final bytes = Uint8List(width * height);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = (out[i] * 255).round().clamp(0, 255);
    }
    return AlphaMask(width, height, bytes);
  }

  factory AlphaMask.rect(int width, int height, Rect rect) =>
      AlphaMask.polygon(width, height, [
        rect.topLeft,
        rect.topRight,
        rect.bottomRight,
        rect.bottomLeft,
      ]);

  factory AlphaMask.ellipse(int width, int height, Rect rect) {
    final steps = math.max(48, ((rect.width + rect.height) * math.pi / 4).ceil());
    final cx = rect.center.dx, cy = rect.center.dy;
    final rx = rect.width / 2, ry = rect.height / 2;
    return AlphaMask.polygon(width, height, [
      for (var i = 0; i < steps; i++)
        Offset(
          cx + rx * math.cos(2 * math.pi * i / steps),
          cy + ry * math.sin(2 * math.pi * i / steps),
        ),
    ]);
  }

  // ---- combining ---------------------------------------------------------------

  AlphaMask invert() {
    final out = Uint8List(data.length);
    for (var i = 0; i < out.length; i++) {
      out[i] = 255 - data[i];
    }
    return AlphaMask(width, height, out);
  }

  /// Combines [other] (same size) into this mask.
  AlphaMask combine(AlphaMask other, SelectionMode mode) {
    if (mode == SelectionMode.replace) return other;
    if (other.width != width || other.height != height) {
      throw ArgumentError('Masks must have the same size.');
    }
    final out = Uint8List(data.length);
    for (var i = 0; i < out.length; i++) {
      final a = data[i], b = other.data[i];
      switch (mode) {
        case SelectionMode.add:
          out[i] = a + b - (a * b + 127) ~/ 255;
        case SelectionMode.subtract:
          out[i] = a - (a * b + 127) ~/ 255;
        case SelectionMode.intersect:
          out[i] = (a * b + 127) ~/ 255;
        case SelectionMode.replace:
          out[i] = b;
      }
    }
    return AlphaMask(width, height, out);
  }

  // ---- morphology and softening ---------------------------------------------------

  static const double _far = 1e20;

  /// Exact Euclidean distance transform (Felzenszwalb & Huttenlocher) from
  /// every pixel to the nearest pixel where [isSource] is true.
  static Float64List _distanceSquared(int w, int h, bool Function(int) isSource) {
    final grid = Float64List(w * h);
    for (var i = 0; i < grid.length; i++) {
      grid[i] = isSource(i) ? 0 : _far;
    }
    final maxLen = math.max(w, h);
    final f = Float64List(maxLen);
    final d = Float64List(maxLen);
    final v = Int32List(maxLen);
    final z = Float64List(maxLen + 1);

    void pass(int length, int Function(int) index) {
      for (var q = 0; q < length; q++) {
        f[q] = grid[index(q)];
      }
      var k = 0;
      v[0] = 0;
      z[0] = -_far;
      z[1] = _far;
      for (var q = 1; q < length; q++) {
        double s;
        while (true) {
          final p = v[k];
          s = ((f[q] + q * q) - (f[p] + p * p)) / (2.0 * q - 2.0 * p);
          if (s <= z[k] && k > 0) {
            k--;
          } else {
            break;
          }
        }
        if (s <= z[k]) {
          v[k] = q;
          z[k] = -_far;
          z[k + 1] = _far;
        } else {
          k++;
          v[k] = q;
          z[k] = s;
          z[k + 1] = _far;
        }
      }
      k = 0;
      for (var q = 0; q < length; q++) {
        while (z[k + 1] < q) {
          k++;
        }
        final dq = q - v[k];
        d[q] = dq * dq + f[v[k]];
      }
      for (var q = 0; q < length; q++) {
        grid[index(q)] = d[q];
      }
    }

    for (var x = 0; x < w; x++) {
      pass(h, (y) => y * w + x);
    }
    for (var y = 0; y < h; y++) {
      pass(w, (x) => y * w + x);
    }
    return grid;
  }

  /// Grows the selection by [radius] mask pixels (negative shrinks it).
  AlphaMask grow(double radius) {
    if (radius == 0) return this;
    final r2 = radius.abs() * radius.abs();
    final out = Uint8List(data.length);
    if (radius > 0) {
      final dist = _distanceSquared(width, height, (i) => data[i] >= 128);
      for (var i = 0; i < out.length; i++) {
        out[i] = dist[i] <= r2 ? 255 : data[i];
      }
    } else {
      final dist = _distanceSquared(width, height, (i) => data[i] < 128);
      for (var i = 0; i < out.length; i++) {
        out[i] = dist[i] <= r2 ? 0 : data[i];
      }
    }
    return AlphaMask(width, height, out);
  }

  /// Softens the edge with three box blurs (approximates a Gaussian whose
  /// standard deviation is about [radius] / 2).
  AlphaMask feather(double radius) {
    if (radius < 0.5) return this;
    final sigma = radius / 2;
    final boxRadius = math.max(1, (math.sqrt(12 * sigma * sigma / 3 + 1) - 1) ~/ 2);
    var current = Float64List.fromList([for (final v in data) v.toDouble()]);
    var other = Float64List(current.length);
    for (var i = 0; i < 3; i++) {
      _boxBlur(current, other, width, height, boxRadius, horizontal: true);
      _boxBlur(other, current, width, height, boxRadius, horizontal: false);
    }
    return AlphaMask(
      width,
      height,
      Uint8List.fromList([for (final v in current) v.round().clamp(0, 255)]),
    );
  }

  static void _boxBlur(
    Float64List src,
    Float64List dst,
    int w,
    int h,
    int r, {
    required bool horizontal,
  }) {
    final lines = horizontal ? h : w;
    final length = horizontal ? w : h;
    final window = 2 * r + 1;
    for (var line = 0; line < lines; line++) {
      int idx(int i) => horizontal ? line * w + i : i * w + line;
      var sum = 0.0;
      for (var i = -r; i <= r; i++) {
        sum += src[idx(i.clamp(0, length - 1))];
      }
      for (var i = 0; i < length; i++) {
        dst[idx(i)] = sum / window;
        sum += src[idx(math.min(length - 1, i + r + 1))] -
            src[idx(math.max(0, i - r))];
      }
    }
  }

  // ---- resampling -------------------------------------------------------------------

  /// Resamples this mask (which covers a [fromWidth] x [fromHeight] document)
  /// onto a new [toWidth] x [toHeight] pixel grid covering a document that is
  /// related to the old one by [transform] (old document coordinates -> new).
  /// Pixels that map outside the old mask get [outside] (0 for selections;
  /// layer masks pass their own fill so new canvas area is handled sanely).
  AlphaMask resampled({
    required double fromWidth,
    required double fromHeight,
    required double toWidth,
    required double toHeight,
    required int pixelWidth,
    required int pixelHeight,
    required Affine2D transform,
    int outside = 0,
  }) {
    final inverse = transform.inverse();
    final out = Uint8List(pixelWidth * pixelHeight);
    if (inverse == null) return AlphaMask(pixelWidth, pixelHeight, out);
    final sx = fromWidth / width;
    final sy = fromHeight / height;
    for (var y = 0; y < pixelHeight; y++) {
      final docY = (y + 0.5) * toHeight / pixelHeight;
      for (var x = 0; x < pixelWidth; x++) {
        final docX = (x + 0.5) * toWidth / pixelWidth;
        final ox = inverse.applyX(docX, docY);
        final oy = inverse.applyY(docX, docY);
        if (ox < 0 || oy < 0 || ox >= fromWidth || oy >= fromHeight) {
          out[y * pixelWidth + x] = outside;
          continue;
        }
        final fx = ox / sx - 0.5;
        final fy = oy / sy - 0.5;
        final x0 = fx.floor(), y0 = fy.floor();
        final tx = fx - x0, ty = fy - y0;
        double s(int px, int py) =>
            at(px.clamp(0, width - 1), py.clamp(0, height - 1)).toDouble();
        final top = s(x0, y0) * (1 - tx) + s(x0 + 1, y0) * tx;
        final bottom = s(x0, y0 + 1) * (1 - tx) + s(x0 + 1, y0 + 1) * tx;
        out[y * pixelWidth + x] = (top * (1 - ty) + bottom * ty).round().clamp(0, 255);
      }
    }
    return AlphaMask(pixelWidth, pixelHeight, out);
  }

  // ---- serialization ------------------------------------------------------------------

  Map<String, Object?> toJson() => {
        'w': width,
        'h': height,
        'z': _encoded ??= base64Encode(gzip.encode(data)),
      };

  static AlphaMask fromJson(Object? raw) {
    if (raw is! Map<String, dynamic>) {
      throw const FormatException('Invalid mask.');
    }
    final w = raw['w'], h = raw['h'], z = raw['z'];
    if (w is! int || h is! int || w < 1 || h < 1 || w > maxLoadSide || h > maxLoadSide) {
      throw const FormatException('Invalid mask size.');
    }
    if (z is! String) throw const FormatException('Invalid mask data.');
    final Uint8List bytes;
    try {
      bytes = Uint8List.fromList(gzip.decode(base64Decode(z)));
    } on Object {
      throw const FormatException('Mask data is damaged.');
    }
    if (bytes.length != w * h) throw const FormatException('Mask data has the wrong size.');
    final mask = AlphaMask(w, h, bytes);
    mask._encoded = z;
    return mask;
  }
}
