import 'dart:math' as math;
import 'dart:typed_data';

import '../domain/gradient_model.dart';
import 'filter_core.dart';

double _lin(double v) => math.pow(v / 255, 2.2).toDouble();
double _unlin(double v) => 255 * math.pow(v.clamp(0.0, 1.0), 1 / 2.2).toDouble();

Uint8List _lut(double Function(double v) f) {
  final l = Uint8List(256);
  for (var i = 0; i < 256; i++) {
    l[i] = toByte(f(i.toDouble()));
  }
  return l;
}

FilterImage _lutAll(FilterImage s, FilterContext c, double Function(double) f) {
  final l = _lut(f);
  return applyLut(s, c, l, l, l);
}

/// Smooth 0..1 weights of shadows / mids / highlights for a luma in 0..1.
double _shadowW(double l) => math.pow(1 - l, 2).toDouble();
double _highW(double l) => l * l;

/// Monotone-ish curve through 5 control values (at x = 0, .25, .5, .75, 1),
/// each given 0..255. Uses Catmull-Rom then clamps to 0..255.
Uint8List curveLut(List<double> ys) {
  final out = Uint8List(256);
  for (var i = 0; i < 256; i++) {
    final t = i / 255 * 4;
    final seg = math.min(3, t.floor());
    final u = t - seg;
    double p(int k) => ys[k.clamp(0, 4)];
    final p0 = p(seg - 1), p1 = p(seg), p2 = p(seg + 1), p3 = p(seg + 2);
    final v = 0.5 *
        ((2 * p1) +
            (-p0 + p2) * u +
            (2 * p0 - 5 * p1 + 4 * p2 - p3) * u * u +
            (-p0 + 3 * p1 - 3 * p2 + p3) * u * u * u);
    out[i] = toByte(v);
  }
  return out;
}

final List<FilterSpec> adjustFilters = [
  FilterSpec(
    id: 'brightness',
    label: 'Brightness',
    category: FilterCategory.adjust,
    params: const [FilterParam('amount', 'Amount', -100, 100, 0)],
    apply: (s, p, c) => _lutAll(s, c, (v) => v + p['amount']! * 2.55),
  ),
  FilterSpec(
    id: 'contrast',
    label: 'Contrast',
    category: FilterCategory.adjust,
    params: const [FilterParam('amount', 'Amount', -100, 100, 0)],
    apply: (s, p, c) {
      final k = p['amount']! * 2.55;
      final f = (259 * (k + 255)) / (255 * (259 - k));
      return _lutAll(s, c, (v) => f * (v - 128) + 128);
    },
  ),
  FilterSpec(
    id: 'exposure',
    label: 'Exposure',
    category: FilterCategory.adjust,
    params: const [FilterParam('stops', 'Stops (EV)', -3, 3, 0, digits: 2)],
    apply: (s, p, c) {
      final m = math.pow(2, p['stops']!).toDouble();
      return _lutAll(s, c, (v) => _unlin(_lin(v) * m));
    },
  ),
  FilterSpec(
    id: 'gamma',
    label: 'Gamma',
    category: FilterCategory.adjust,
    params: const [FilterParam('gamma', 'Gamma', 0.2, 5, 1, digits: 2)],
    apply: (s, p, c) {
      final g = p['gamma']!;
      return _lutAll(s, c, (v) => 255 * math.pow(v / 255, 1 / g).toDouble());
    },
  ),
  FilterSpec(
    id: 'saturation',
    label: 'Saturation',
    category: FilterCategory.adjust,
    params: const [FilterParam('amount', 'Amount', -100, 100, 0)],
    apply: (s, p, c) {
      final k = 1 + p['amount']! / 100;
      return mapPixels(s, c, (rgb, x, y) {
        final l = lumaOf(rgb[0], rgb[1], rgb[2]);
        for (var i = 0; i < 3; i++) {
          rgb[i] = l + (rgb[i] - l) * k;
        }
        return 1;
      });
    },
  ),
  FilterSpec(
    id: 'vibrance',
    label: 'Vibrance',
    category: FilterCategory.adjust,
    params: const [FilterParam('amount', 'Amount', -100, 100, 0)],
    apply: (s, p, c) {
      final amt = p['amount']! / 100;
      return mapPixels(s, c, (rgb, x, y) {
        final mx = math.max(rgb[0], math.max(rgb[1], rgb[2]));
        final mn = math.min(rgb[0], math.min(rgb[1], rgb[2]));
        final sat = mx == 0 ? 0.0 : (mx - mn) / mx;
        // Muted colours move more than already-vivid ones.
        final k = 1 + amt * (1 - sat);
        final l = lumaOf(rgb[0], rgb[1], rgb[2]);
        for (var i = 0; i < 3; i++) {
          rgb[i] = l + (rgb[i] - l) * k;
        }
        return 1;
      });
    },
  ),
  FilterSpec(
    id: 'hue',
    label: 'Hue',
    category: FilterCategory.adjust,
    params: const [FilterParam('degrees', 'Rotate (°)', -180, 180, 0)],
    apply: (s, p, c) {
      final d = p['degrees']!;
      final hsl = Float64List(3);
      return mapPixels(s, c, (rgb, x, y) {
        rgbToHsl(rgb[0], rgb[1], rgb[2], hsl);
        hslToRgb(hsl[0] + d, hsl[1], hsl[2], rgb);
        return 1;
      });
    },
  ),
  FilterSpec(
    id: 'temperature',
    label: 'Temperature',
    category: FilterCategory.adjust,
    params: const [FilterParam('amount', 'Cool ← → Warm', -100, 100, 0)],
    apply: (s, p, c) {
      final k = p['amount']! * 0.4;
      return mapPixels(s, c, (rgb, x, y) {
        rgb[0] += k;
        rgb[2] -= k;
        return 1;
      });
    },
  ),
  FilterSpec(
    id: 'tint',
    label: 'Tint',
    category: FilterCategory.adjust,
    params: const [FilterParam('amount', 'Green ← → Magenta', -100, 100, 0)],
    apply: (s, p, c) {
      final k = p['amount']! * 0.4;
      return mapPixels(s, c, (rgb, x, y) {
        rgb[1] -= k;
        return 1;
      });
    },
  ),
  FilterSpec(
    id: 'tonal',
    label: 'Highlights / Shadows / Whites / Blacks',
    category: FilterCategory.adjust,
    params: const [
      FilterParam('highlights', 'Highlights', -100, 100, 0),
      FilterParam('shadows', 'Shadows', -100, 100, 0),
      FilterParam('whites', 'Whites', -100, 100, 0),
      FilterParam('blacks', 'Blacks', -100, 100, 0),
    ],
    apply: (s, p, c) {
      final hi = p['highlights']! * 0.6,
          sh = p['shadows']! * 0.6,
          wh = p['whites']! * 0.6,
          bl = p['blacks']! * 0.6;
      return mapPixels(s, c, (rgb, x, y) {
        final l = lumaOf(rgb[0], rgb[1], rgb[2]) / 255;
        final d = hi * _highW(l) * (1 - l) * 4 * 0.5 +
            sh * _shadowW(l) * l * 4 * 0.5 +
            wh * math.pow(l, 4) +
            bl * math.pow(1 - l, 4);
        for (var i = 0; i < 3; i++) {
          rgb[i] += d;
        }
        return 1;
      });
    },
  ),
  FilterSpec(
    id: 'opacity',
    label: 'Opacity',
    category: FilterCategory.adjust,
    params: const [FilterParam('percent', 'Opacity %', 0, 100, 100)],
    apply: (s, p, c) {
      final k = p['percent']! / 100;
      return mapPixels(s, c, (rgb, x, y) => k);
    },
  ),
  // ---- Colour correction -------------------------------------------------
  FilterSpec(
    id: 'levels',
    label: 'Levels',
    category: FilterCategory.color,
    params: const [
      FilterParam('inBlack', 'Input black', 0, 254, 0),
      FilterParam('inWhite', 'Input white', 1, 255, 255),
      FilterParam('gamma', 'Midtone gamma', 0.1, 4, 1, digits: 2),
      FilterParam('outBlack', 'Output black', 0, 254, 0),
      FilterParam('outWhite', 'Output white', 1, 255, 255),
    ],
    apply: (s, p, c) {
      final ib = p['inBlack']!, iw = math.max(p['inWhite']!, ib + 1);
      final g = p['gamma']!, ob = p['outBlack']!, ow = p['outWhite']!;
      return _lutAll(s, c, (v) {
        final t = ((v - ib) / (iw - ib)).clamp(0.0, 1.0);
        return ob + math.pow(t, 1 / g).toDouble() * (ow - ob);
      });
    },
  ),
  FilterSpec(
    id: 'curves',
    label: 'Tone curve',
    category: FilterCategory.color,
    params: const [
      FilterParam('p0', 'Black point', 0, 255, 0),
      FilterParam('p1', 'Shadows', 0, 255, 64),
      FilterParam('p2', 'Midtones', 0, 255, 128),
      FilterParam('p3', 'Highlights', 0, 255, 192),
      FilterParam('p4', 'White point', 0, 255, 255),
    ],
    apply: (s, p, c) {
      final l = curveLut([for (var i = 0; i < 5; i++) p['p$i']!]);
      return applyLut(s, c, l, l, l);
    },
  ),
  FilterSpec(
    id: 'colorBalance',
    label: 'Color balance',
    category: FilterCategory.color,
    params: const [
      FilterParam('cyanRed', 'Cyan ← → Red', -100, 100, 0),
      FilterParam('magentaGreen', 'Magenta ← → Green', -100, 100, 0),
      FilterParam('yellowBlue', 'Yellow ← → Blue', -100, 100, 0),
      FilterParam('shadows', 'Shadows weight', 0, 100, 33),
      FilterParam('mids', 'Midtones weight', 0, 100, 34),
      FilterParam('highs', 'Highlights weight', 0, 100, 33),
    ],
    apply: (s, p, c) {
      final dr = p['cyanRed']! * 0.5,
          dg = p['magentaGreen']! * 0.5,
          db = p['yellowBlue']! * 0.5;
      final ws = p['shadows']! / 100, wm = p['mids']! / 100, wh = p['highs']! / 100;
      return mapPixels(s, c, (rgb, x, y) {
        final l = lumaOf(rgb[0], rgb[1], rgb[2]) / 255;
        final w = ws * _shadowW(l) + wm * (1 - (2 * l - 1) * (2 * l - 1)) + wh * _highW(l);
        rgb[0] += dr * w;
        rgb[1] += dg * w;
        rgb[2] += db * w;
        return 1;
      });
    },
  ),
  FilterSpec(
    id: 'gradientMap',
    label: 'Gradient map',
    category: FilterCategory.color,
    params: [
      FilterParam('preset', 'Preset', 0, (GradientPresets.all.length - 1).toDouble(), 0),
    ],
    apply: (s, p, c) {
      final g = GradientPresets.all[p['preset']!.round()].gradient;
      final lut = [for (var i = 0; i < 256; i++) g.colorAt(i / 255)];
      return mapPixels(s, c, (rgb, x, y) {
        final l = lumaOf(rgb[0], rgb[1], rgb[2]).round().clamp(0, 255);
        final col = lut[l];
        rgb[0] = ((col >> 16) & 0xFF).toDouble();
        rgb[1] = ((col >> 8) & 0xFF).toDouble();
        rgb[2] = (col & 0xFF).toDouble();
        return 1;
      });
    },
  ),
  FilterSpec(
    id: 'colorize',
    label: 'Colorize',
    category: FilterCategory.color,
    params: const [
      FilterParam('hue', 'Hue', 0, 360, 200),
      FilterParam('sat', 'Saturation', 0, 100, 50),
      FilterParam('light', 'Lightness', -100, 100, 0),
    ],
    apply: (s, p, c) {
      final out = Float64List(3);
      return mapPixels(s, c, (rgb, x, y) {
        var l = lumaOf(rgb[0], rgb[1], rgb[2]) / 255;
        l = (l + p['light']! / 200).clamp(0.0, 1.0).toDouble();
        hslToRgb(p['hue']!, p['sat']! / 100, l, out);
        rgb[0] = out[0];
        rgb[1] = out[1];
        rgb[2] = out[2];
        return 1;
      });
    },
  ),
  FilterSpec(
    id: 'posterize',
    label: 'Posterize',
    category: FilterCategory.color,
    params: const [FilterParam('levels', 'Levels', 2, 32, 4)],
    apply: (s, p, c) {
      final n = p['levels']!.round();
      return _lutAll(s, c, (v) => (v / 255 * (n - 1)).round() / (n - 1) * 255);
    },
  ),
  FilterSpec(
    id: 'threshold',
    label: 'Threshold',
    category: FilterCategory.color,
    params: const [FilterParam('level', 'Level', 0, 255, 128)],
    apply: (s, p, c) {
      final t = p['level']!;
      return mapPixels(s, c, (rgb, x, y) {
        final v = lumaOf(rgb[0], rgb[1], rgb[2]) >= t ? 255.0 : 0.0;
        rgb[0] = rgb[1] = rgb[2] = v;
        return 1;
      });
    },
  ),
  FilterSpec(
    id: 'grayscale',
    label: 'Grayscale',
    category: FilterCategory.color,
    params: const [],
    apply: (s, p, c) => mapPixels(s, c, (rgb, x, y) {
      final l = lumaOf(rgb[0], rgb[1], rgb[2]);
      rgb[0] = rgb[1] = rgb[2] = l;
      return 1;
    }),
  ),
  FilterSpec(
    id: 'blackWhite',
    label: 'Black & white (mixer)',
    category: FilterCategory.color,
    params: const [
      FilterParam('red', 'Reds', -100, 200, 30),
      FilterParam('green', 'Greens', -100, 200, 59),
      FilterParam('blue', 'Blues', -100, 200, 11),
    ],
    apply: (s, p, c) {
      final total = p['red']! + p['green']! + p['blue']!;
      final norm = total.abs() < 1 ? 1.0 : total / 100;
      final wr = p['red']! / 100 / norm, wg = p['green']! / 100 / norm, wb = p['blue']! / 100 / norm;
      return mapPixels(s, c, (rgb, x, y) {
        final v = rgb[0] * wr + rgb[1] * wg + rgb[2] * wb;
        rgb[0] = rgb[1] = rgb[2] = v;
        return 1;
      });
    },
  ),
  FilterSpec(
    id: 'replaceColor',
    label: 'Replace color',
    category: FilterCategory.color,
    params: const [
      FilterParam('fromHue', 'Target hue', 0, 360, 0),
      FilterParam('tolerance', 'Tolerance (°)', 1, 180, 30),
      FilterParam('hueShift', 'Hue shift', -180, 180, 120),
      FilterParam('satShift', 'Saturation shift', -100, 100, 0),
      FilterParam('lightShift', 'Lightness shift', -100, 100, 0),
    ],
    apply: (s, p, c) {
      final hsl = Float64List(3);
      final tol = p['tolerance']!;
      return mapPixels(s, c, (rgb, x, y) {
        rgbToHsl(rgb[0], rgb[1], rgb[2], hsl);
        if (hsl[1] < 0.05) return 1; // greys have no meaningful hue
        var d = (hsl[0] - p['fromHue']!).abs();
        if (d > 180) d = 360 - d;
        if (d > tol) return 1;
        final w = 1 - d / tol; // soft edge
        hslToRgb(
          hsl[0] + p['hueShift']! * w,
          hsl[1] + p['satShift']! / 100 * w,
          hsl[2] + p['lightShift']! / 200 * w,
          rgb,
        );
        return 1;
      });
    },
  ),
];
