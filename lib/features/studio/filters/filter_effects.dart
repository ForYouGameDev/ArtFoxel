import 'dart:math' as math;
import 'dart:typed_data';

import 'filter_core.dart';

// ---------------------------------------------------------------------------
// Premultiplied float helpers
// ---------------------------------------------------------------------------

Float32List _toPremul(FilterImage s) {
  final f = Float32List(s.width * s.height * 4);
  final d = s.rgba;
  for (var i = 0; i < d.length; i += 4) {
    final a = d[i + 3] / 255;
    f[i] = d[i] * a;
    f[i + 1] = d[i + 1] * a;
    f[i + 2] = d[i + 2] * a;
    f[i + 3] = d[i + 3].toDouble();
  }
  return f;
}

FilterImage _fromPremul(Float32List f, int w, int h) {
  final out = FilterImage(w, h);
  final o = out.rgba;
  for (var i = 0; i < f.length; i += 4) {
    final a = f[i + 3];
    if (a <= 0.5) {
      continue;
    }
    final k = 255 / a;
    o[i] = toByte(f[i] * k);
    o[i + 1] = toByte(f[i + 1] * k);
    o[i + 2] = toByte(f[i + 2] * k);
    o[i + 3] = toByte(a);
  }
  return out;
}

void _boxPass(Float32List d, int w, int h, int r, bool horizontal, FilterContext ctx) {
  if (r <= 0) return;
  final len = horizontal ? w : h;
  final lines = horizontal ? h : w;
  final stride = horizontal ? 4 : w * 4;
  final step = horizontal ? w * 4 : 4;
  final tmp = Float32List(len * 4);
  final win = 2 * r + 1;
  for (var line = 0; line < lines; line++) {
    if ((line & 63) == 0) ctx.check();
    final base = line * step;
    for (var c = 0; c < 4; c++) {
      var sum = 0.0;
      for (var k = -r; k <= r; k++) {
        sum += d[base + k.clamp(0, len - 1) * stride + c];
      }
      for (var i = 0; i < len; i++) {
        tmp[i * 4 + c] = sum / win;
        final add = d[base + (i + r + 1).clamp(0, len - 1) * stride + c];
        final sub = d[base + (i - r).clamp(0, len - 1) * stride + c];
        sum += add - sub;
      }
    }
    for (var i = 0; i < len; i++) {
      final o = base + i * stride;
      d[o] = tmp[i * 4];
      d[o + 1] = tmp[i * 4 + 1];
      d[o + 2] = tmp[i * 4 + 2];
      d[o + 3] = tmp[i * 4 + 3];
    }
  }
}

FilterImage boxBlur(FilterImage s, int r, FilterContext ctx, {int passes = 1}) {
  if (r <= 0) return s.clone();
  final f = _toPremul(s);
  for (var i = 0; i < passes; i++) {
    _boxPass(f, s.width, s.height, r, true, ctx);
    _boxPass(f, s.width, s.height, r, false, ctx);
  }
  return _fromPremul(f, s.width, s.height);
}

/// Gaussian approximated by three box passes (error well under 3%).
FilterImage gaussianBlur(FilterImage s, double radius, FilterContext ctx) {
  if (radius <= 0.01) return s.clone();
  final sigma = radius;
  final ideal = math.sqrt(12 * sigma * sigma / 3 + 1);
  var wl = ideal.floor();
  if (wl.isEven) wl--;
  final wu = wl + 2;
  final m = ((12 * sigma * sigma - 3 * wl * wl - 12 * wl - 9) / (-4 * wl - 4)).round();
  final f = _toPremul(s);
  for (var i = 0; i < 3; i++) {
    final r = ((i < m ? wl : wu) - 1) ~/ 2;
    _boxPass(f, s.width, s.height, r, true, ctx);
    _boxPass(f, s.width, s.height, r, false, ctx);
    ctx.progress((i + 1) / 3);
  }
  return _fromPremul(f, s.width, s.height);
}

/// Blends [top] over [src] per channel with [mix] on colour (alpha from src).
FilterImage _combine(FilterImage a, FilterImage b, double Function(double a, double b) f,
    {bool keepAlpha = true}) {
  final out = FilterImage(a.width, a.height);
  for (var i = 0; i < a.rgba.length; i += 4) {
    if (a.rgba[i + 3] == 0 && keepAlpha) continue;
    out.rgba[i] = toByte(f(a.rgba[i].toDouble(), b.rgba[i].toDouble()));
    out.rgba[i + 1] = toByte(f(a.rgba[i + 1].toDouble(), b.rgba[i + 1].toDouble()));
    out.rgba[i + 2] = toByte(f(a.rgba[i + 2].toDouble(), b.rgba[i + 2].toDouble()));
    out.rgba[i + 3] = a.rgba[i + 3];
  }
  return out;
}

FilterImage _gray(FilterImage s) {
  final o = FilterImage(s.width, s.height);
  for (var i = 0; i < s.rgba.length; i += 4) {
    final l = toByte(lumaOf(s.rgba[i].toDouble(), s.rgba[i + 1].toDouble(), s.rgba[i + 2].toDouble()));
    o.rgba[i] = o.rgba[i + 1] = o.rgba[i + 2] = l;
    o.rgba[i + 3] = s.rgba[i + 3];
  }
  return o;
}

/// Sobel edge magnitude 0..255 per pixel (of luma).
Uint8List edgeMap(FilterImage s, FilterContext ctx) {
  final w = s.width, h = s.height;
  final l = Float32List(w * h);
  for (var i = 0, p = 0; i < s.rgba.length; i += 4, p++) {
    l[p] = lumaOf(s.rgba[i].toDouble(), s.rgba[i + 1].toDouble(), s.rgba[i + 2].toDouble()) *
        (s.rgba[i + 3] / 255);
  }
  final e = Uint8List(w * h);
  double at(int x, int y) => l[y.clamp(0, h - 1) * w + x.clamp(0, w - 1)];
  for (var y = 0; y < h; y++) {
    if ((y & 63) == 0) ctx.check();
    for (var x = 0; x < w; x++) {
      final gx = -at(x - 1, y - 1) - 2 * at(x - 1, y) - at(x - 1, y + 1) +
          at(x + 1, y - 1) + 2 * at(x + 1, y) + at(x + 1, y + 1);
      final gy = -at(x - 1, y - 1) - 2 * at(x, y - 1) - at(x + 1, y - 1) +
          at(x - 1, y + 1) + 2 * at(x, y + 1) + at(x + 1, y + 1);
      e[y * w + x] = toByte(math.sqrt(gx * gx + gy * gy) / 4);
    }
  }
  return e;
}

FilterImage _warp(FilterImage s, FilterContext ctx,
    bool Function(double x, double y, Float64List src) map) {
  final out = FilterImage(s.width, s.height);
  final px = Float64List(4);
  final xy = Float64List(2);
  for (var y = 0; y < s.height; y++) {
    if ((y & 31) == 0) {
      ctx.check();
      ctx.progress(y / s.height);
    }
    for (var x = 0; x < s.width; x++) {
      xy[0] = x.toDouble();
      xy[1] = y.toDouble();
      final i = (y * s.width + x) * 4;
      if (!map(x.toDouble(), y.toDouble(), xy)) {
        out.rgba.setRange(i, i + 4, s.rgba, i);
        continue;
      }
      sampleBilinear(s, xy[0], xy[1], px);
      writePremul(out.rgba, i, px);
    }
  }
  return out;
}

FilterImage _directional(FilterImage s, FilterContext ctx, double dx, double dy, int taps) {
  final out = FilterImage(s.width, s.height);
  final px = Float64List(4);
  final acc = Float64List(4);
  for (var y = 0; y < s.height; y++) {
    if ((y & 31) == 0) {
      ctx.check();
      ctx.progress(y / s.height);
    }
    for (var x = 0; x < s.width; x++) {
      acc.fillRange(0, 4, 0);
      for (var t = 0; t < taps; t++) {
        final k = taps == 1 ? 0.0 : t / (taps - 1) - 0.5;
        sampleBilinear(s, x + dx * k, y + dy * k, px);
        for (var c = 0; c < 4; c++) {
          acc[c] += px[c];
        }
      }
      for (var c = 0; c < 4; c++) {
        acc[c] /= taps;
      }
      writePremul(out.rgba, (y * s.width + x) * 4, acc);
    }
  }
  return out;
}

FilterImage _rad(FilterImage s, FilterContext ctx, double cx, double cy, double amount, bool spin) {
  final out = FilterImage(s.width, s.height);
  final px = Float64List(4), acc = Float64List(4);
  const taps = 12;
  for (var y = 0; y < s.height; y++) {
    if ((y & 31) == 0) {
      ctx.check();
      ctx.progress(y / s.height);
    }
    for (var x = 0; x < s.width; x++) {
      acc.fillRange(0, 4, 0);
      final vx = x - cx, vy = y - cy;
      for (var t = 0; t < taps; t++) {
        final k = t / (taps - 1) - 0.5;
        double sx, sy;
        if (spin) {
          final a = k * amount * math.pi / 180;
          sx = cx + vx * math.cos(a) - vy * math.sin(a);
          sy = cy + vx * math.sin(a) + vy * math.cos(a);
        } else {
          final z = 1 + k * amount / 100;
          sx = cx + vx * z;
          sy = cy + vy * z;
        }
        sampleBilinear(s, sx, sy, px);
        for (var c = 0; c < 4; c++) {
          acc[c] += px[c];
        }
      }
      for (var c = 0; c < 4; c++) {
        acc[c] /= taps;
      }
      writePremul(out.rgba, (y * s.width + x) * 4, acc);
    }
  }
  return out;
}

FilterImage _blendScreen(FilterImage base, FilterImage glow, double amount) =>
    _combine(base, glow, (a, b) => 255 - (255 - a) * (255 - b * amount) / 255);

const _bayer = [
  [0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5],
];


final List<FilterSpec> effectFilters = [
  // ---- blur & sharpen ----------------------------------------------------
  FilterSpec(
    id: 'gaussian',
    label: 'Gaussian blur',
    category: FilterCategory.blur,
    params: const [FilterParam('radius', 'Radius', 0, 100, 4, digits: 1)],
    approximation: 'Three-pass box approximation of a Gaussian.',
    margin: (p) => (p['radius']! * 3).ceil() + 2,
    apply: (s, p, c) => gaussianBlur(s, p['radius']!, c),
  ),
  FilterSpec(
    id: 'box',
    label: 'Box blur',
    category: FilterCategory.blur,
    params: const [FilterParam('radius', 'Radius', 0, 100, 4)],
    margin: (p) => p['radius']!.round() + 2,
    apply: (s, p, c) => boxBlur(s, p['radius']!.round(), c),
  ),
  FilterSpec(
    id: 'motion',
    label: 'Motion / directional blur',
    category: FilterCategory.blur,
    params: const [
      FilterParam('angle', 'Angle (°)', -180, 180, 0),
      FilterParam('distance', 'Distance', 0, 200, 20),
    ],
    apply: (s, p, c) {
      final a = p['angle']! * math.pi / 180, d = p['distance']!;
      return _directional(s, c, math.cos(a) * d, math.sin(a) * d, math.max(2, d.ceil() ~/ 2 + 1).clamp(2, 64));
    },
  ),
  FilterSpec(
    id: 'radialBlur',
    label: 'Radial (spin) blur',
    category: FilterCategory.blur,
    params: const [
      FilterParam('amount', 'Angle (°)', 0, 60, 10),
      FilterParam('cx', 'Centre X %', 0, 100, 50),
      FilterParam('cy', 'Centre Y %', 0, 100, 50),
    ],
    apply: (s, p, c) => _rad(s, c, p['cx']! / 100 * s.width, p['cy']! / 100 * s.height, p['amount']!, true),
  ),
  FilterSpec(
    id: 'zoomBlur',
    label: 'Zoom blur',
    category: FilterCategory.blur,
    params: const [
      FilterParam('amount', 'Amount %', 0, 100, 20),
      FilterParam('cx', 'Centre X %', 0, 100, 50),
      FilterParam('cy', 'Centre Y %', 0, 100, 50),
    ],
    apply: (s, p, c) => _rad(s, c, p['cx']! / 100 * s.width, p['cy']! / 100 * s.height, p['amount']!, false),
  ),
  FilterSpec(
    id: 'surface',
    label: 'Surface blur',
    category: FilterCategory.blur,
    params: const [
      FilterParam('radius', 'Radius', 1, 8, 3),
      FilterParam('threshold', 'Edge threshold', 1, 100, 25),
    ],
    approximation: 'Bilateral filter on a small window (edge-preserving smoothing).',
    margin: (p) => p['radius']!.round() + 1,
    apply: (s, p, c) {
      final r = p['radius']!.round(), th = p['threshold']! * 2.55;
      final out = FilterImage(s.width, s.height);
      final d = s.rgba, o = out.rgba, w = s.width, h = s.height;
      for (var y = 0; y < h; y++) {
        if ((y & 31) == 0) {
          c.check();
          c.progress(y / h);
        }
        for (var x = 0; x < w; x++) {
          final i = (y * w + x) * 4;
          if (d[i + 3] == 0) continue;
          var sr = 0.0, sg = 0.0, sb = 0.0, sw = 0.0;
          for (var dy = -r; dy <= r; dy++) {
            for (var dx = -r; dx <= r; dx++) {
              final j = (((y + dy).clamp(0, h - 1)) * w + (x + dx).clamp(0, w - 1)) * 4;
              if (d[j + 3] == 0) continue;
              final diff = ((d[j] - d[i]).abs() + (d[j + 1] - d[i + 1]).abs() + (d[j + 2] - d[i + 2]).abs()) / 3;
              final wt = math.max(0.0, 1 - diff / th) * (1 - (dx * dx + dy * dy) / ((r + 1) * (r + 1)));
              if (wt <= 0) continue;
              sr += d[j] * wt;
              sg += d[j + 1] * wt;
              sb += d[j + 2] * wt;
              sw += wt;
            }
          }
          o[i] = toByte(sr / sw);
          o[i + 1] = toByte(sg / sw);
          o[i + 2] = toByte(sb / sw);
          o[i + 3] = d[i + 3];
        }
      }
      return out;
    },
  ),
  FilterSpec(
    id: 'sharpen',
    label: 'Sharpen',
    category: FilterCategory.blur,
    params: const [FilterParam('amount', 'Amount', 0, 200, 50)],
    margin: (p) => 2,
    apply: (s, p, c) {
      final k = p['amount']! / 100;
      final blur = gaussianBlur(s, 1, c);
      return _combine(s, blur, (a, b) => a + (a - b) * k);
    },
  ),
  FilterSpec(
    id: 'unsharp',
    label: 'Unsharp mask',
    category: FilterCategory.blur,
    params: const [
      FilterParam('radius', 'Radius', 0.5, 20, 2, digits: 1),
      FilterParam('amount', 'Amount %', 0, 500, 100),
      FilterParam('threshold', 'Threshold', 0, 255, 0),
    ],
    margin: (p) => (p['radius']! * 3).ceil() + 2,
    apply: (s, p, c) {
      final blur = gaussianBlur(s, p['radius']!, c);
      final k = p['amount']! / 100, th = p['threshold']!;
      return _combine(s, blur, (a, b) => (a - b).abs() < th ? a : a + (a - b) * k);
    },
  ),
  // ---- light effects ------------------------------------------------------
  FilterSpec(
    id: 'glow',
    label: 'Glow',
    category: FilterCategory.effect,
    params: const [
      FilterParam('radius', 'Radius', 1, 60, 12),
      FilterParam('amount', 'Strength %', 0, 100, 60),
    ],
    approximation: 'Blurred copy blended with Screen.',
    apply: (s, p, c) => _blendScreen(s, gaussianBlur(s, p['radius']!, c), p['amount']! / 100),
  ),
  FilterSpec(
    id: 'bloom',
    label: 'Bloom',
    category: FilterCategory.effect,
    params: const [
      FilterParam('threshold', 'Brightness threshold', 0, 255, 180),
      FilterParam('radius', 'Radius', 1, 60, 16),
      FilterParam('amount', 'Strength %', 0, 100, 70),
    ],
    approximation: 'Bright-pass, blur, Screen blend (no HDR).',
    apply: (s, p, c) {
      final th = p['threshold']!;
      final bright = mapPixels(s, c, (rgb, x, y) {
        final l = lumaOf(rgb[0], rgb[1], rgb[2]);
        final k = l <= th ? 0.0 : (l - th) / (255 - th + 1e-6);
        rgb[0] *= k;
        rgb[1] *= k;
        rgb[2] *= k;
        return 1;
      });
      return _blendScreen(s, gaussianBlur(bright, p['radius']!, c), p['amount']! / 100);
    },
  ),
  FilterSpec(
    id: 'dropShadow',
    label: 'Drop shadow',
    category: FilterCategory.effect,
    params: const [
      FilterParam('dx', 'Offset X', -100, 100, 8),
      FilterParam('dy', 'Offset Y', -100, 100, 8),
      FilterParam('blur', 'Blur', 0, 60, 8),
      FilterParam('opacity', 'Opacity %', 0, 100, 60),
    ],
    apply: (s, p, c) {
      final w = s.width, h = s.height;
      final sh = FilterImage(w, h);
      final dx = p['dx']!.round(), dy = p['dy']!.round();
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final sx = x - dx, sy = y - dy;
          if (sx < 0 || sy < 0 || sx >= w || sy >= h) continue;
          final a = s.rgba[(sy * w + sx) * 4 + 3];
          sh.rgba[(y * w + x) * 4 + 3] = toByte(a * p['opacity']! / 100);
        }
      }
      final soft = gaussianBlur(sh, p['blur']!, c);
      // Composite original over the (black) shadow.
      final out = FilterImage(w, h);
      for (var i = 0; i < out.rgba.length; i += 4) {
        final sa = soft.rgba[i + 3] / 255, fa = s.rgba[i + 3] / 255;
        final oa = fa + sa * (1 - fa);
        if (oa <= 0) continue;
        out.rgba[i] = toByte(s.rgba[i] * fa / oa);
        out.rgba[i + 1] = toByte(s.rgba[i + 1] * fa / oa);
        out.rgba[i + 2] = toByte(s.rgba[i + 2] * fa / oa);
        out.rgba[i + 3] = toByte(oa * 255);
      }
      return out;
    },
  ),
  FilterSpec(
    id: 'vignette',
    label: 'Vignette',
    category: FilterCategory.effect,
    params: const [
      FilterParam('amount', 'Darkness %', 0, 100, 50),
      FilterParam('size', 'Size %', 10, 100, 70),
    ],
    apply: (s, p, c) {
      final cx = s.width / 2, cy = s.height / 2;
      final maxR = math.sqrt(cx * cx + cy * cy);
      final start = p['size']! / 100;
      return mapPixels(s, c, (rgb, x, y) {
        final d = math.sqrt((x - cx) * (x - cx) + (y - cy) * (y - cy)) / maxR;
        final t = ((d - start * 0.6) / (1 - start * 0.6)).clamp(0.0, 1.0);
        final k = 1 - p['amount']! / 100 * t * t;
        rgb[0] *= k;
        rgb[1] *= k;
        rgb[2] *= k;
        return 1;
      });
    },
  ),
  // ---- artistic -----------------------------------------------------------
  FilterSpec(
    id: 'outline',
    label: 'Outline (edges)',
    category: FilterCategory.artistic,
    params: const [FilterParam('strength', 'Strength', 1, 10, 3, digits: 1)],
    apply: (s, p, c) {
      final e = edgeMap(s, c);
      final o = FilterImage(s.width, s.height);
      for (var i = 0, q = 0; i < o.rgba.length; i += 4, q++) {
        final v = toByte(255 - e[q] * p['strength']!);
        o.rgba[i] = o.rgba[i + 1] = o.rgba[i + 2] = v;
        o.rgba[i + 3] = s.rgba[i + 3];
      }
      return o;
    },
  ),
  FilterSpec(
    id: 'sketch',
    label: 'Sketch',
    category: FilterCategory.artistic,
    params: const [FilterParam('radius', 'Line softness', 1, 30, 6)],
    approximation: 'Colour-dodge of inverted blur (classic pencil-sketch trick).',
    apply: (s, p, c) {
      final g = _gray(s);
      final inv = _combine(g, g, (a, _) => 255 - a);
      final b = gaussianBlur(inv, p['radius']!, c);
      return _combine(g, b, (a, bl) => bl >= 255 ? 255 : math.min(255, a * 255 / (255 - bl)));
    },
  ),
  FilterSpec(
    id: 'pencil',
    label: 'Pencil',
    category: FilterCategory.artistic,
    params: const [
      FilterParam('radius', 'Line softness', 1, 20, 3),
      FilterParam('grain', 'Paper grain', 0, 100, 25),
    ],
    approximation: 'Sketch + procedural paper grain; not a stroke simulation.',
    apply: (s, p, c) {
      final g = _gray(s);
      final inv = _combine(g, g, (a, _) => 255 - a);
      final b = gaussianBlur(inv, p['radius']!, c);
      final sk = _combine(g, b, (a, bl) => bl >= 255 ? 255 : math.min(255, a * 255 / (255 - bl)));
      final gr = p['grain']!;
      final out = sk.clone();
      for (var y = 0; y < s.height; y++) {
        for (var x = 0; x < s.width; x++) {
          final i = (y * s.width + x) * 4;
          final n = (hashNoise(x, y, 7) - 0.5) * gr;
          for (var k = 0; k < 3; k++) {
            out.rgba[i + k] = toByte(out.rgba[i + k] + n);
          }
        }
      }
      return out;
    },
  ),
  FilterSpec(
    id: 'charcoal',
    label: 'Charcoal',
    category: FilterCategory.artistic,
    params: const [
      FilterParam('detail', 'Detail', 1, 10, 4),
      FilterParam('darkness', 'Darkness', 0, 100, 60),
    ],
    approximation: 'Edge map + tonal darkening with grain.',
    apply: (s, p, c) {
      final e = edgeMap(s, c);
      final out = FilterImage(s.width, s.height);
      for (var i = 0, q = 0; i < out.rgba.length; i += 4, q++) {
        final l = lumaOf(s.rgba[i].toDouble(), s.rgba[i + 1].toDouble(), s.rgba[i + 2].toDouble());
        final x = q % s.width, y = q ~/ s.width;
        var v = 255 - e[q] * p['detail']! - (255 - l) * p['darkness']! / 100;
        v += (hashNoise(x, y, 3) - 0.5) * 30;
        out.rgba[i] = out.rgba[i + 1] = out.rgba[i + 2] = toByte(v);
        out.rgba[i + 3] = s.rgba[i + 3];
      }
      return out;
    },
  ),
  FilterSpec(
    id: 'watercolor',
    label: 'Watercolor (approximation)',
    category: FilterCategory.artistic,
    params: const [
      FilterParam('smooth', 'Smoothing', 1, 12, 4),
      FilterParam('edges', 'Edge darkening', 0, 100, 30),
    ],
    approximation: 'Edge-preserving smoothing + colour banding + soft edges. Not a pigment/water simulation.',
    apply: (s, p, c) {
      final smooth = gaussianBlur(s, p['smooth']!, c);
      final e = edgeMap(smooth, c);
      final out = FilterImage(s.width, s.height);
      for (var i = 0, q = 0; i < out.rgba.length; i += 4, q++) {
        final dark = 1 - e[q] / 255 * p['edges']! / 100 * 3;
        for (var k = 0; k < 3; k++) {
          final band = (smooth.rgba[i + k] / 255 * 8).round() / 8 * 255;
          out.rgba[i + k] = toByte(band * dark.clamp(0.0, 1.0));
        }
        out.rgba[i + 3] = s.rgba[i + 3];
      }
      return out;
    },
  ),
  FilterSpec(
    id: 'oil',
    label: 'Oil paint (approximation)',
    category: FilterCategory.artistic,
    params: const [
      FilterParam('radius', 'Brush radius', 1, 6, 3),
      FilterParam('levels', 'Intensity levels', 4, 30, 16),
    ],
    approximation: 'Intensity-bin oil filter; no bristle or impasto simulation.',
    margin: (p) => p['radius']!.round() + 1,
    apply: (s, p, c) {
      final r = p['radius']!.round(), n = p['levels']!.round();
      final w = s.width, h = s.height;
      final out = FilterImage(w, h);
      final cnt = List<int>.filled(n, 0);
      final sr = List<double>.filled(n, 0), sg = List<double>.filled(n, 0), sb = List<double>.filled(n, 0);
      for (var y = 0; y < h; y++) {
        if ((y & 15) == 0) {
          c.check();
          c.progress(y / h);
        }
        for (var x = 0; x < w; x++) {
          final i = (y * w + x) * 4;
          if (s.rgba[i + 3] == 0) continue;
          cnt.fillRange(0, n, 0);
          sr.fillRange(0, n, 0);
          sg.fillRange(0, n, 0);
          sb.fillRange(0, n, 0);
          for (var dy = -r; dy <= r; dy++) {
            for (var dx = -r; dx <= r; dx++) {
              final j = (((y + dy).clamp(0, h - 1)) * w + (x + dx).clamp(0, w - 1)) * 4;
              final bin = (lumaOf(s.rgba[j].toDouble(), s.rgba[j + 1].toDouble(), s.rgba[j + 2].toDouble()) * (n - 1) / 255).round();
              cnt[bin]++;
              sr[bin] += s.rgba[j];
              sg[bin] += s.rgba[j + 1];
              sb[bin] += s.rgba[j + 2];
            }
          }
          var best = 0;
          for (var k = 1; k < n; k++) {
            if (cnt[k] > cnt[best]) best = k;
          }
          out.rgba[i] = toByte(sr[best] / cnt[best]);
          out.rgba[i + 1] = toByte(sg[best] / cnt[best]);
          out.rgba[i + 2] = toByte(sb[best] / cnt[best]);
          out.rgba[i + 3] = s.rgba[i + 3];
        }
      }
      return out;
    },
  ),
  FilterSpec(
    id: 'halftone',
    label: 'Halftone',
    category: FilterCategory.artistic,
    params: const [
      FilterParam('size', 'Dot spacing', 3, 40, 8),
      FilterParam('angle', 'Angle (°)', 0, 90, 45),
    ],
    apply: (s, p, c) {
      final sz = p['size']!, a = p['angle']! * math.pi / 180;
      final co = math.cos(a), si = math.sin(a);
      return mapPixels(s, c, (rgb, x, y) {
        final u = (x * co + y * si) / sz, v = (-x * si + y * co) / sz;
        final fu = u - u.floorToDouble() - 0.5, fv = v - v.floorToDouble() - 0.5;
        final dist = math.sqrt(fu * fu + fv * fv);
        final dark = 1 - lumaOf(rgb[0], rgb[1], rgb[2]) / 255;
        final r = math.sqrt(dark) * 0.7071;
        final ink = dist < r ? 0.0 : 255.0;
        rgb[0] = rgb[1] = rgb[2] = ink;
        return 1;
      });
    },
  ),
  FilterSpec(
    id: 'dither',
    label: 'Dither (ordered)',
    category: FilterCategory.artistic,
    params: const [FilterParam('levels', 'Levels per channel', 2, 8, 2)],
    apply: (s, p, c) {
      final n = p['levels']!.round();
      return mapPixels(s, c, (rgb, x, y) {
        final t = (_bayer[y & 3][x & 3] + 0.5) / 16 - 0.5;
        for (var k = 0; k < 3; k++) {
          final v = rgb[k] / 255 * (n - 1) + t;
          rgb[k] = v.round().clamp(0, n - 1) / (n - 1) * 255;
        }
        return 1;
      });
    },
  ),
  FilterSpec(
    id: 'noise',
    label: 'Noise',
    category: FilterCategory.artistic,
    params: const [
      FilterParam('amount', 'Amount', 0, 100, 20),
      FilterParam('mono', 'Monochrome (0/1)', 0, 1, 1),
      FilterParam('seed', 'Seed', 0, 999, 1),
    ],
    apply: (s, p, c) {
      final amt = p['amount']! * 2.55, seed = p['seed']!.round();
      return mapPixels(s, c, (rgb, x, y) {
        final n0 = (hashNoise(x, y, seed) - 0.5) * amt;
        for (var k = 0; k < 3; k++) {
          rgb[k] += p['mono']! >= 0.5 ? n0 : (hashNoise(x, y, seed + k + 1) - 0.5) * amt;
        }
        return 1;
      });
    },
  ),
  FilterSpec(
    id: 'grain',
    label: 'Film grain',
    category: FilterCategory.artistic,
    params: const [
      FilterParam('amount', 'Amount', 0, 100, 25),
      FilterParam('size', 'Grain size', 1, 6, 1),
    ],
    approximation: 'Luminance-weighted procedural noise, strongest in midtones.',
    apply: (s, p, c) {
      final amt = p['amount']! * 2, sz = p['size']!.round();
      return mapPixels(s, c, (rgb, x, y) {
        final l = lumaOf(rgb[0], rgb[1], rgb[2]) / 255;
        final w = 1 - (2 * l - 1) * (2 * l - 1) * 0.7;
        final n = (hashNoise(x ~/ sz, y ~/ sz, 11) - 0.5) * amt * w;
        for (var k = 0; k < 3; k++) {
          rgb[k] += n;
        }
        return 1;
      });
    },
  ),
  FilterSpec(
    id: 'pixelate',
    label: 'Pixelate',
    category: FilterCategory.artistic,
    params: const [FilterParam('size', 'Block size', 2, 128, 8)],
    apply: (s, p, c) {
      final b = p['size']!.round(), w = s.width, h = s.height;
      final out = FilterImage(w, h);
      for (var by = 0; by < h; by += b) {
        c.check();
        for (var bx = 0; bx < w; bx += b) {
          var r = 0.0, g = 0.0, bl = 0.0, a = 0.0, n = 0;
          final ye = math.min(by + b, h), xe = math.min(bx + b, w);
          for (var y = by; y < ye; y++) {
            for (var x = bx; x < xe; x++) {
              final i = (y * w + x) * 4, al = s.rgba[i + 3] / 255;
              r += s.rgba[i] * al;
              g += s.rgba[i + 1] * al;
              bl += s.rgba[i + 2] * al;
              a += al;
              n++;
            }
          }
          if (a <= 0) continue;
          final cr = toByte(r / a), cg = toByte(g / a), cb = toByte(bl / a), ca = toByte(a / n * 255);
          for (var y = by; y < ye; y++) {
            for (var x = bx; x < xe; x++) {
              final i = (y * w + x) * 4;
              out.rgba[i] = cr;
              out.rgba[i + 1] = cg;
              out.rgba[i + 2] = cb;
              out.rgba[i + 3] = ca;
            }
          }
        }
      }
      return out;
    },
  ),
  FilterSpec(
    id: 'mosaic',
    label: 'Mosaic tiles',
    category: FilterCategory.artistic,
    params: const [
      FilterParam('size', 'Tile size', 4, 128, 16),
      FilterParam('gap', 'Grout', 0, 8, 1),
    ],
    apply: (s, p, c) {
      final tile = p['size']!.round(), gap = p['gap']!.round();
      final px = FilterImage(s.width, s.height, Uint8List.fromList(s.rgba));
      final base = effectFilters.firstWhere((f) => f.id == 'pixelate').apply(px, {'size': tile.toDouble()}, c);
      for (var y = 0; y < s.height; y++) {
        for (var x = 0; x < s.width; x++) {
          if ((x % tile) < gap || (y % tile) < gap) {
            final i = (y * s.width + x) * 4;
            for (var k = 0; k < 3; k++) {
              base.rgba[i + k] = toByte(base.rgba[i + k] * 0.35);
            }
          }
        }
      }
      return base;
    },
  ),
  FilterSpec(
    id: 'texture',
    label: 'Canvas texture',
    category: FilterCategory.artistic,
    params: const [
      FilterParam('amount', 'Strength', 0, 100, 30),
      FilterParam('scale', 'Weave size', 2, 16, 4),
    ],
    approximation: 'Procedural woven pattern multiplied over the image; no external texture.',
    apply: (s, p, c) {
      final sc = p['scale']!;
      return mapPixels(s, c, (rgb, x, y) {
        final t = (math.sin(x / sc * math.pi) * math.sin(y / sc * math.pi)) * 0.5 +
            (hashNoise(x, y, 5) - 0.5) * 0.5;
        final k = 1 + t * p['amount']! / 100 * 0.5;
        rgb[0] *= k;
        rgb[1] *= k;
        rgb[2] *= k;
        return 1;
      });
    },
  ),
  FilterSpec(
    id: 'comic',
    label: 'Comic shading',
    category: FilterCategory.artistic,
    params: const [
      FilterParam('levels', 'Tone levels', 2, 8, 3),
      FilterParam('ink', 'Ink lines', 0, 10, 4),
    ],
    approximation: 'Posterized tones plus Sobel ink lines.',
    apply: (s, p, c) {
      final e = edgeMap(s, c);
      final n = p['levels']!.round();
      final out = FilterImage(s.width, s.height);
      for (var i = 0, q = 0; i < out.rgba.length; i += 4, q++) {
        final ink = e[q] * p['ink']! > 128;
        for (var k = 0; k < 3; k++) {
          out.rgba[i + k] = ink ? 0 : toByte((s.rgba[i + k] / 255 * (n - 1)).round() / (n - 1) * 255);
        }
        out.rgba[i + 3] = s.rgba[i + 3];
      }
      return out;
    },
  ),
  FilterSpec(
    id: 'crosshatch',
    label: 'Crosshatch',
    category: FilterCategory.artistic,
    params: const [FilterParam('spacing', 'Line spacing', 3, 20, 6)],
    apply: (s, p, c) {
      final sp = p['spacing']!.round();
      return mapPixels(s, c, (rgb, x, y) {
        final l = lumaOf(rgb[0], rgb[1], rgb[2]) / 255;
        var ink = false;
        if (l < 0.8 && (x + y) % sp == 0) ink = true;
        if (l < 0.55 && (x - y) % sp == 0) ink = true;
        if (l < 0.35 && y % sp == 0) ink = true;
        if (l < 0.18 && x % sp == 0) ink = true;
        rgb[0] = rgb[1] = rgb[2] = ink ? 20.0 : 245.0;
        return 1;
      });
    },
  ),
  // ---- distortions --------------------------------------------------------
  FilterSpec(
    id: 'wave',
    label: 'Wave',
    category: FilterCategory.distort,
    params: const [
      FilterParam('amplitude', 'Amplitude', 0, 100, 10),
      FilterParam('wavelength', 'Wavelength', 5, 400, 60),
    ],
    apply: (s, p, c) => _warp(s, c, (x, y, o) {
      o[0] = x + math.sin(y / p['wavelength']! * 2 * math.pi) * p['amplitude']!;
      return true;
    }),
  ),
  FilterSpec(
    id: 'ripple',
    label: 'Ripple',
    category: FilterCategory.distort,
    params: const [
      FilterParam('amplitude', 'Amplitude', 0, 60, 6),
      FilterParam('wavelength', 'Wavelength', 4, 200, 24),
    ],
    apply: (s, p, c) {
      final cx = s.width / 2, cy = s.height / 2;
      return _warp(s, c, (x, y, o) {
        final d = math.sqrt((x - cx) * (x - cx) + (y - cy) * (y - cy));
        if (d < 1e-6) return false;
        final off = math.sin(d / p['wavelength']! * 2 * math.pi) * p['amplitude']!;
        o[0] = x + (x - cx) / d * off;
        o[1] = y + (y - cy) / d * off;
        return true;
      });
    },
  ),
  FilterSpec(
    id: 'fisheye',
    label: 'Fisheye',
    category: FilterCategory.distort,
    params: const [FilterParam('strength', 'Strength', 0, 100, 50)],
    apply: (s, p, c) {
      final cx = s.width / 2, cy = s.height / 2, rad = math.min(cx, cy);
      final k = p['strength']! / 100;
      return _warp(s, c, (x, y, o) {
        final dx = x - cx, dy = y - cy, d = math.sqrt(dx * dx + dy * dy);
        if (d >= rad || d < 1e-6) return false;
        final t = d / rad;
        final f = math.pow(t, 1 + k).toDouble() * rad / d;
        o[0] = cx + dx * f;
        o[1] = cy + dy * f;
        return true;
      });
    },
  ),
  FilterSpec(
    id: 'twirl',
    label: 'Twirl',
    category: FilterCategory.distort,
    params: const [FilterParam('angle', 'Angle (°)', -720, 720, 120)],
    apply: (s, p, c) {
      final cx = s.width / 2, cy = s.height / 2, rad = math.min(cx, cy);
      return _warp(s, c, (x, y, o) {
        final dx = x - cx, dy = y - cy, d = math.sqrt(dx * dx + dy * dy);
        if (d >= rad) return false;
        final a = p['angle']! * math.pi / 180 * (1 - d / rad) * (1 - d / rad);
        o[0] = cx + dx * math.cos(a) - dy * math.sin(a);
        o[1] = cy + dx * math.sin(a) + dy * math.cos(a);
        return true;
      });
    },
  ),
  for (final bulge in [true, false])
    FilterSpec(
      id: bulge ? 'bulge' : 'pinch',
      label: bulge ? 'Bulge' : 'Pinch',
      category: FilterCategory.distort,
      params: const [FilterParam('strength', 'Strength', 0, 100, 50)],
      apply: (s, p, c) {
        final cx = s.width / 2, cy = s.height / 2, rad = math.min(cx, cy);
        final k = p['strength']! / 100 * 0.8;
        return _warp(s, c, (x, y, o) {
          final dx = x - cx, dy = y - cy, d = math.sqrt(dx * dx + dy * dy);
          if (d >= rad || d < 1e-6) return false;
          final t = d / rad;
          final f = bulge ? 1 - k * (1 - t) : 1 + k * (1 - t);
          o[0] = cx + dx * f;
          o[1] = cy + dy * f;
          return true;
        });
      },
    ),
  FilterSpec(
    id: 'perspective',
    label: 'Perspective tilt',
    category: FilterCategory.distort,
    params: const [
      FilterParam('horizontal', 'Horizontal', -50, 50, 0),
      FilterParam('vertical', 'Vertical', -50, 50, 0),
    ],
    approximation: 'Keystone-style tilt, not a full 4-corner homography.',
    apply: (s, p, c) {
      final w = s.width.toDouble(), h = s.height.toDouble();
      final hk = p['horizontal']! / 100, vk = p['vertical']! / 100;
      return _warp(s, c, (x, y, o) {
        final ny = y / h, nx = x / w;
        final sx = (nx - 0.5) / (1 + hk * (ny - 0.5)) + 0.5;
        final sy = (ny - 0.5) / (1 + vk * (nx - 0.5)) + 0.5;
        o[0] = sx * w;
        o[1] = sy * h;
        return true;
      });
    },
  ),
  FilterSpec(
    id: 'chromatic',
    label: 'Chromatic aberration',
    category: FilterCategory.distort,
    params: const [FilterParam('amount', 'Amount', 0, 30, 4, digits: 1)],
    apply: (s, p, c) {
      final cx = s.width / 2, cy = s.height / 2, k = p['amount']! / 100;
      final out = s.clone();
      final px = Float64List(4);
      for (var y = 0; y < s.height; y++) {
        if ((y & 31) == 0) c.check();
        for (var x = 0; x < s.width; x++) {
          final i = (y * s.width + x) * 4;
          sampleBilinear(s, x + (x - cx) * k, y + (y - cy) * k, px);
          out.rgba[i] = px[3] > 0 ? toByte(px[0] / px[3]) : out.rgba[i];
          sampleBilinear(s, x - (x - cx) * k, y - (y - cy) * k, px);
          out.rgba[i + 2] = px[3] > 0 ? toByte(px[2] / px[3]) : out.rgba[i + 2];
        }
      }
      return out;
    },
  ),
  FilterSpec(
    id: 'rgbSplit',
    label: 'RGB split',
    category: FilterCategory.distort,
    params: const [
      FilterParam('dx', 'Shift X', -50, 50, 6),
      FilterParam('dy', 'Shift Y', -50, 50, 0),
    ],
    apply: (s, p, c) {
      final w = s.width, h = s.height;
      final dx = p['dx']!.round(), dy = p['dy']!.round();
      final out = s.clone();
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final i = (y * w + x) * 4;
          final r = ((y - dy).clamp(0, h - 1) * w + (x - dx).clamp(0, w - 1)) * 4;
          final b = ((y + dy).clamp(0, h - 1) * w + (x + dx).clamp(0, w - 1)) * 4;
          out.rgba[i] = s.rgba[r];
          out.rgba[i + 2] = s.rgba[b + 2];
          out.rgba[i + 3] = math.max(s.rgba[i + 3], math.max(s.rgba[r + 3], s.rgba[b + 3]));
        }
      }
      return out;
    },
  ),
];
