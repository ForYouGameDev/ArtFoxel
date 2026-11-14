import 'dart:math' as math;
import 'dart:typed_data';

import 'guides_selection.dart';

/// Phase 7.5.4 — fill, clone stamp and texture sampling on straight-alpha
/// RGBA8 buffers (pure Dart; callers run it in an isolate for big canvases).

enum FillSource { currentLayer, referenceLayer, allVisible }

class FillOptions {
  const FillOptions({
    this.tolerance = 16,
    this.contiguous = true,
    this.gapClose = 0,
    this.antiAlias = true,
    this.colorRange = false,
    this.maxPixels = 40000000,
  });
  final int tolerance; // 0..255, max channel distance
  final bool contiguous;
  final int gapClose; // px, closes gaps up to ~this wide
  final bool antiAlias;
  final bool colorRange; // select all matching pixels, ignores contiguity
  final int maxPixels; // safeguard against absurd canvases
}

class FillException implements Exception {
  FillException(this.message);
  final String message;
  @override
  String toString() => 'FillException: $message';
}

class BucketFill {
  /// Returns the fill coverage mask for a click at (sx,sy) on [sample].
  /// [sample] is the buffer chosen by [FillSource] (the caller supplies the
  /// current layer, reference layer or flattened composite).
  static SelectionMask compute(Uint8List sample, int w, int h, int sx, int sy,
      [FillOptions o = const FillOptions()]) {
    if (sample.length != w * h * 4) throw FillException('buffer size mismatch');
    if (w * h > o.maxPixels) throw FillException('canvas too large for fill');
    if (sx < 0 || sy < 0 || sx >= w || sy >= h) return SelectionMask(w, h);

    final seed = _px(sample, (sy * w + sx) * 4);
    final match = Uint8List(w * h); // 1 = pixel similar to seed
    for (var i = 0; i < w * h; i++) {
      match[i] = _dist(sample, i * 4, seed) <= o.tolerance ? 1 : 0;
    }

    Uint8List region;
    if (o.colorRange) {
      region = match;
    } else {
      var passable = match;
      var r = 0;
      if (o.gapClose > 0) {
        // Barrier = non-matching pixels. Dilate barriers so a gap of up to
        // gapClose px is sealed, fill, then grow the result back.
        r = (o.gapClose / 2).ceil();
        passable = _erode(match, w, h, r);
        if (passable[sy * w + sx] == 0) passable = match; // seed on a thin area
      }
      region = _flood(passable, w, h, sx, sy);
      if (r > 0 && passable != match) {
        region = _dilateWithin(region, match, w, h, r);
      }
    }

    final m = SelectionMask(w, h);
    for (var i = 0; i < region.length; i++) {
      if (region[i] != 0) m.data[i] = 255;
    }
    if (o.antiAlias) _softenEdge(m);
    return m;
  }

  static List<int> _px(Uint8List b, int i) => [b[i], b[i + 1], b[i + 2], b[i + 3]];

  static int _dist(Uint8List b, int i, List<int> s) {
    // Fully transparent pixels all match each other regardless of RGB.
    if (b[i + 3] == 0 && s[3] == 0) return 0;
    var d = (b[i + 3] - s[3]).abs();
    final dr = (b[i] - s[0]).abs(), dg = (b[i + 1] - s[1]).abs(), db = (b[i + 2] - s[2]).abs();
    d = math.max(d, math.max(dr, math.max(dg, db)));
    return d;
  }

  static Uint8List _flood(Uint8List pass, int w, int h, int sx, int sy) {
    final out = Uint8List(w * h);
    if (pass[sy * w + sx] == 0) return out;
    // Scanline stack fill: no recursion, bounded stack.
    final stack = <int>[sy * w + sx];
    while (stack.isNotEmpty) {
      final p = stack.removeLast();
      var x = p % w;
      final y = p ~/ w;
      if (out[p] != 0 || pass[p] == 0) continue;
      var l = x;
      while (l > 0 && pass[y * w + l - 1] != 0 && out[y * w + l - 1] == 0) {
        l--;
      }
      var r = x;
      while (r < w - 1 && pass[y * w + r + 1] != 0 && out[y * w + r + 1] == 0) {
        r++;
      }
      for (x = l; x <= r; x++) {
        out[y * w + x] = 1;
      }
      for (final ny in [y - 1, y + 1]) {
        if (ny < 0 || ny >= h) continue;
        var inRun = false;
        for (x = l; x <= r; x++) {
          final ok = pass[ny * w + x] != 0 && out[ny * w + x] == 0;
          if (ok && !inRun) {
            stack.add(ny * w + x);
            inRun = true;
          } else if (!ok) {
            inRun = false;
          }
        }
      }
    }
    return out;
  }

  // Separable min/max filters on 0/1 maps.
  static Uint8List _erode(Uint8List m, int w, int h, int r) => _morph(m, w, h, r, true);

  static Uint8List _morph(Uint8List m, int w, int h, int r, bool erode) {
    var tmp = Uint8List(m.length), out = Uint8List(m.length);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        var v = erode ? 1 : 0;
        for (var k = -r; k <= r; k++) {
          final xx = x + k;
          final n = xx < 0 || xx >= w ? (erode ? 1 : 0) : m[y * w + xx];
          if (erode ? n == 0 : n != 0) {
            v = erode ? 0 : 1;
            break;
          }
        }
        tmp[y * w + x] = v;
      }
    }
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        var v = erode ? 1 : 0;
        for (var k = -r; k <= r; k++) {
          final yy = y + k;
          final n = yy < 0 || yy >= h ? (erode ? 1 : 0) : tmp[yy * w + x];
          if (erode ? n == 0 : n != 0) {
            v = erode ? 0 : 1;
            break;
          }
        }
        out[y * w + x] = v;
      }
    }
    return out;
  }

  static Uint8List _dilateWithin(Uint8List region, Uint8List limit, int w, int h, int r) {
    final d = _morph(region, w, h, r, false);
    for (var i = 0; i < d.length; i++) {
      if (limit[i] == 0) d[i] = 0;
    }
    return d;
  }

  static void _softenEdge(SelectionMask m) {
    final w = m.width, h = m.height;
    final copy = Uint8List.fromList(m.data);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final i = y * w + x;
        if (copy[i] == 0) continue;
        var edge = false;
        for (final (dx, dy) in const [(1, 0), (-1, 0), (0, 1), (0, -1)]) {
          final nx = x + dx, ny = y + dy;
          if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
          if (copy[ny * w + nx] == 0) {
            edge = true;
            break;
          }
        }
        if (edge) m.data[i] = 170;
      }
    }
  }
}

/// Paint source: colour at a pixel (ARGB int, straight alpha).
typedef PixelSource = int Function(int x, int y);

class FillPaint {
  static PixelSource solid(int argb) => (x, y) => argb;

  static PixelSource linearGradient(Pt a, Pt b, List<(double, int)> stops) {
    if (stops.length < 2) throw FillException('gradient needs 2+ stops');
    final dx = b.x - a.x, dy = b.y - a.y;
    final l2 = math.max(1e-9, dx * dx + dy * dy);
    return (x, y) {
      final t = (((x + 0.5 - a.x) * dx + (y + 0.5 - a.y) * dy) / l2).clamp(0.0, 1.0);
      return _lerpStops(stops, t);
    };
  }

  static PixelSource radialGradient(Pt c, double r, List<(double, int)> stops) {
    if (stops.length < 2) throw FillException('gradient needs 2+ stops');
    return (x, y) {
      final d = math.sqrt((x + 0.5 - c.x) * (x + 0.5 - c.x) + (y + 0.5 - c.y) * (y + 0.5 - c.y));
      return _lerpStops(stops, (d / math.max(1e-9, r)).clamp(0.0, 1.0));
    };
  }

  /// Repeating pattern from a tile (straight-alpha RGBA), with offset.
  static PixelSource pattern(Uint8List tile, int tw, int th, {int ox = 0, int oy = 0}) {
    if (tile.length != tw * th * 4 || tw <= 0 || th <= 0) {
      throw FillException('bad pattern tile');
    }
    return (x, y) {
      final tx = ((x - ox) % tw + tw) % tw, ty = ((y - oy) % th + th) % th;
      final i = (ty * tw + tx) * 4;
      return (tile[i + 3] << 24) | (tile[i] << 16) | (tile[i + 1] << 8) | tile[i + 2];
    };
  }

  static int _lerpStops(List<(double, int)> stops, double t) {
    final s = List.of(stops)..sort((a, b) => a.$1.compareTo(b.$1));
    if (t <= s.first.$1) return s.first.$2;
    if (t >= s.last.$1) return s.last.$2;
    for (var i = 0; i < s.length - 1; i++) {
      if (t <= s[i + 1].$1) {
        final span = s[i + 1].$1 - s[i].$1;
        final k = span <= 0 ? 0.0 : (t - s[i].$1) / span;
        return _mix(s[i].$2, s[i + 1].$2, k);
      }
    }
    return s.last.$2;
  }

  static int _mix(int a, int b, double k) {
    int ch(int sh) => (((a >> sh) & 0xFF) + (((b >> sh) & 0xFF) - ((a >> sh) & 0xFF)) * k)
        .round()
        .clamp(0, 255);
    return (ch(24) << 24) | (ch(16) << 16) | (ch(8) << 8) | ch(0);
  }

  /// Composites [src] through [mask] (× [opacity]) onto straight-alpha RGBA.
  /// Uses source-over with correct straight-alpha maths.
  static void apply(Uint8List dst, int w, int h, SelectionMask mask, PixelSource src,
      {double opacity = 1}) {
    if (dst.length != w * h * 4 || mask.width != w || mask.height != h) {
      throw FillException('size mismatch');
    }
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final m = mask.data[y * w + x];
        if (m == 0) continue;
        final c = src(x, y);
        final sa = ((c >> 24) & 0xFF) / 255 * (m / 255) * opacity;
        if (sa <= 0) continue;
        final i = (y * w + x) * 4;
        final da = dst[i + 3] / 255;
        final oa = sa + da * (1 - sa);
        if (oa <= 0) continue;
        double mixc(int s, int d) => (s * sa + d * da * (1 - sa)) / oa;
        dst[i] = mixc((c >> 16) & 0xFF, dst[i]).round().clamp(0, 255);
        dst[i + 1] = mixc((c >> 8) & 0xFF, dst[i + 1]).round().clamp(0, 255);
        dst[i + 2] = mixc(c & 0xFF, dst[i + 2]).round().clamp(0, 255);
        dst[i + 3] = (oa * 255).round().clamp(0, 255);
      }
    }
  }
}

/// Clone stamp. [srcAnchor] is the Alt-clicked source point; [dstAnchor] the
/// first stamp point. Aligned mode keeps the offset for later strokes;
/// non-aligned resets to the source on every stroke start.
class CloneStamp {
  CloneStamp({
    required this.srcAnchor,
    this.aligned = true,
    this.rotationRad = 0,
    this.scale = 1,
    this.sampleMerged = false,
  });
  Pt srcAnchor;
  Pt? _dstAnchor;
  final bool aligned;
  final double rotationRad, scale;
  final bool sampleMerged; // true: caller supplies the flattened composite

  void beginStroke(Pt dst) {
    if (!aligned || _dstAnchor == null) _dstAnchor = dst;
  }

  /// Source position for a destination pixel centre.
  Pt sourceFor(double x, double y) {
    final d = _dstAnchor ?? Pt(x, y);
    final dx = x - d.x, dy = y - d.y;
    final c = math.cos(-rotationRad), s = math.sin(-rotationRad);
    final inv = 1 / (scale <= 0 ? 1 : scale);
    return Pt(srcAnchor.x + (dx * c - dy * s) * inv, srcAnchor.y + (dx * s + dy * c) * inv);
  }

  /// Stamps one round dab. [src] and [dst] are straight-alpha RGBA with the
  /// same size. [src] may equal [dst] only if a copy is passed (the caller
  /// snapshots at stroke start), otherwise cloned pixels re-clone themselves.
  void stamp(Uint8List src, Uint8List dst, int w, int h, double cx, double cy, double radius,
      {double hardness = 0.7, double opacity = 1, SelectionMask? clip}) {
    final x0 = (cx - radius).floor().clamp(0, w - 1);
    final x1 = (cx + radius).ceil().clamp(0, w - 1);
    final y0 = (cy - radius).floor().clamp(0, h - 1);
    final y1 = (cy + radius).ceil().clamp(0, h - 1);
    for (var y = y0; y <= y1; y++) {
      for (var x = x0; x <= x1; x++) {
        final d = math.sqrt((x + 0.5 - cx) * (x + 0.5 - cx) + (y + 0.5 - cy) * (y + 0.5 - cy));
        if (d > radius) continue;
        final inner = radius * hardness;
        var a = d <= inner ? 1.0 : 1 - (d - inner) / math.max(1e-6, radius - inner);
        a *= opacity;
        if (clip != null) a *= clip.data[y * w + x] / 255;
        if (a <= 0) continue;
        final sp = sourceFor(x + 0.5, y + 0.5);
        final c = sampleBilinear(src, w, h, sp.x - 0.5, sp.y - 0.5);
        if (c[3] == 0) continue;
        final sa = c[3] / 255 * a;
        final i = (y * w + x) * 4;
        final da = dst[i + 3] / 255;
        final oa = sa + da * (1 - sa);
        for (var k = 0; k < 3; k++) {
          dst[i + k] = ((c[k] * sa + dst[i + k] * da * (1 - sa)) / oa).round().clamp(0, 255);
        }
        dst[i + 3] = (oa * 255).round().clamp(0, 255);
      }
    }
  }

  /// Bilinear sample with premultiplied interpolation (no dark fringes).
  static List<int> sampleBilinear(Uint8List b, int w, int h, double x, double y) {
    if (x < -1 || y < -1 || x > w || y > h) return const [0, 0, 0, 0];
    final x0 = x.floor(), y0 = y.floor();
    final fx = x - x0, fy = y - y0;
    double r = 0, g = 0, bl = 0, a = 0;
    for (var j = 0; j < 2; j++) {
      for (var i = 0; i < 2; i++) {
        final px = x0 + i, py = y0 + j;
        final wgt = (i == 0 ? 1 - fx : fx) * (j == 0 ? 1 - fy : fy);
        if (px < 0 || py < 0 || px >= w || py >= h) continue;
        final k = (py * w + px) * 4;
        final al = b[k + 3] / 255;
        r += b[k] * al * wgt;
        g += b[k + 1] * al * wgt;
        bl += b[k + 2] * al * wgt;
        a += al * wgt;
      }
    }
    if (a <= 1e-6) return const [0, 0, 0, 0];
    return [
      (r / a).round().clamp(0, 255),
      (g / a).round().clamp(0, 255),
      (bl / a).round().clamp(0, 255),
      (a * 255).round().clamp(0, 255),
    ];
  }
}
