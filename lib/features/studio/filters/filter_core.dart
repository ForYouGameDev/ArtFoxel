import 'dart:math' as math;
import 'dart:typed_data';

/// Straight-alpha RGBA8 pixel buffer used by the pure-Dart filter engine.
class FilterImage {
  FilterImage(this.width, this.height, [Uint8List? data])
      : rgba = data ?? Uint8List(width * height * 4) {
    if (width <= 0 || height <= 0) {
      throw ArgumentError('Image must have a positive size.');
    }
    if (rgba.length != width * height * 4) {
      throw ArgumentError('Pixel buffer does not match ${width}x$height.');
    }
  }

  final int width;
  final int height;
  final Uint8List rgba;

  FilterImage clone() => FilterImage(width, height, Uint8List.fromList(rgba));

  /// Copies rows [y0, y1) into a new image.
  FilterImage rows(int y0, int y1) => FilterImage(
      width, y1 - y0, Uint8List.sublistView(rgba, y0 * width * 4, y1 * width * 4).sublist(0));
}

class FilterCancelled implements Exception {
  const FilterCancelled();
  @override
  String toString() => 'Filter cancelled.';
}

class FilterBudgetException implements Exception {
  const FilterBudgetException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Memory/time limits for filter processing.
abstract final class FilterBudget {
  /// Largest image (in pixels) the engine will process (~64 MB of RGBA).
  static const maxPixels = 4096 * 4096;

  /// Images above this are processed in horizontal bands when a filter
  /// supports it (blurs, sharpen), keeping float scratch memory bounded.
  static const tilePixels = 2 * 1024 * 1024;

  static void check(int w, int h) {
    if (w * h > maxPixels) {
      throw FilterBudgetException(
          'This image is too large to filter (${w}x$h). Reduce it to at most '
          '$maxPixels pixels (about 4096 x 4096).');
    }
  }
}

/// Progress + cancellation hooks passed to filter implementations.
class FilterContext {
  FilterContext({this.onProgress, this.isCancelled});
  final void Function(double fraction)? onProgress;
  final bool Function()? isCancelled;

  void check() {
    if (isCancelled?.call() ?? false) throw const FilterCancelled();
  }

  void progress(double f) => onProgress?.call(f.clamp(0.0, 1.0).toDouble());
}

class FilterParam {
  const FilterParam(this.key, this.label, this.min, this.max, this.def,
      {this.digits = 0});
  final String key;
  final String label;
  final double min, max, def;
  final int digits;
}

enum FilterCategory { adjust, color, blur, effect, artistic, distort }

extension FilterCategoryLabel on FilterCategory {
  String get label => switch (this) {
        FilterCategory.adjust => 'Adjustments',
        FilterCategory.color => 'Color',
        FilterCategory.blur => 'Blur & sharpen',
        FilterCategory.effect => 'Light effects',
        FilterCategory.artistic => 'Artistic',
        FilterCategory.distort => 'Distort',
      };
}

typedef FilterFn = FilterImage Function(
    FilterImage src, Map<String, double> p, FilterContext ctx);

class FilterSpec {
  const FilterSpec({
    required this.id,
    required this.label,
    required this.category,
    required this.params,
    required this.apply,
    this.approximation,
    this.margin,
  });

  final String id;
  final String label;
  final FilterCategory category;
  final List<FilterParam> params;
  final FilterFn apply;

  /// Non-null when this is only an approximation of the named effect; shown
  /// to the user so a simple stand-in is never presented as the real thing.
  final String? approximation;

  /// When non-null the filter is purely local and can be processed in bands;
  /// the function returns the overlap (in px) needed for given parameters.
  final int Function(Map<String, double> p)? margin;

  Map<String, double> defaults() => {for (final p in params) p.key: p.def};

  /// Fills missing keys with defaults and clamps everything into range.
  Map<String, double> normalize(Map<String, double> input) => {
        for (final p in params)
          p.key: _clean(input[p.key], p),
      };

  static double _clean(double? v, FilterParam p) {
    if (v == null || !v.isFinite) return p.def;
    return v.clamp(p.min, p.max).toDouble();
  }
}

/// One entry of a non-destructive filter stack.
class FilterOp {
  const FilterOp(this.id, this.params, {this.enabled = true});
  final String id;
  final Map<String, double> params;
  final bool enabled;

  FilterOp copyWith({Map<String, double>? params, bool? enabled}) =>
      FilterOp(id, params ?? this.params, enabled: enabled ?? this.enabled);

  Map<String, Object?> toJson() => {
        'id': id,
        'p': params,
        if (!enabled) 'off': true,
      };

  /// Unknown ids are rejected so a file from a newer app is not silently
  /// "reopened" with a missing effect.
  static FilterOp fromJson(Object? json, FilterSpec? Function(String) lookup) {
    if (json is! Map || json['id'] is! String) {
      throw const FormatException('Bad filter entry.');
    }
    final id = json['id'] as String;
    final spec = lookup(id);
    if (spec == null) throw FormatException('Unknown filter "$id".');
    final raw = json['p'];
    final p = <String, double>{};
    if (raw is Map) {
      for (final e in raw.entries) {
        if (e.key is String && e.value is num) {
          p[e.key as String] = (e.value as num).toDouble();
        }
      }
    }
    return FilterOp(id, spec.normalize(p), enabled: json['off'] != true);
  }
}

class FilterPreset {
  const FilterPreset(this.name, this.ops, {this.builtIn = false});
  final String name;
  final List<FilterOp> ops;
  final bool builtIn;

  Map<String, Object?> toJson() => {
        'name': name,
        'ops': [for (final o in ops) o.toJson()],
      };
}

// ---------------------------------------------------------------------------
// Shared pixel helpers
// ---------------------------------------------------------------------------

double clamp255(double v) => v < 0 ? 0 : (v > 255 ? 255 : v);

int toByte(double v) => v <= 0 ? 0 : (v >= 255 ? 255 : (v + 0.5).floor());

double lumaOf(double r, double g, double b) => 0.2126 * r + 0.7152 * g + 0.0722 * b;

/// Applies [f] to every pixel's colour. [f] receives and writes r,g,b in
/// 0..255 via the 3-element scratch list and may return a new alpha scale
/// (1 = keep). Alpha is preserved unless the filter explicitly scales it.
FilterImage mapPixels(
  FilterImage src,
  FilterContext ctx,
  double Function(Float64List rgb, int x, int y) f,
) {
  final out = FilterImage(src.width, src.height);
  final s = src.rgba, o = out.rgba;
  final rgb = Float64List(3);
  var i = 0;
  for (var y = 0; y < src.height; y++) {
    if ((y & 63) == 0) {
      ctx.check();
      ctx.progress(y / src.height);
    }
    for (var x = 0; x < src.width; x++, i += 4) {
      final a = s[i + 3];
      if (a == 0) {
        // Fully transparent pixels stay transparent (colour is irrelevant).
        o[i] = s[i];
        o[i + 1] = s[i + 1];
        o[i + 2] = s[i + 2];
        continue;
      }
      rgb[0] = s[i].toDouble();
      rgb[1] = s[i + 1].toDouble();
      rgb[2] = s[i + 2].toDouble();
      final k = f(rgb, x, y);
      o[i] = toByte(rgb[0]);
      o[i + 1] = toByte(rgb[1]);
      o[i + 2] = toByte(rgb[2]);
      o[i + 3] = k == 1 ? a : toByte(a * k);
    }
  }
  return out;
}

/// Same as [mapPixels] but builds the output from a 256-entry LUT per channel.
FilterImage applyLut(FilterImage src, FilterContext ctx, Uint8List r,
    Uint8List g, Uint8List b) {
  final out = FilterImage(src.width, src.height);
  final s = src.rgba, o = out.rgba;
  for (var i = 0; i < s.length; i += 4) {
    o[i] = r[s[i]];
    o[i + 1] = g[s[i + 1]];
    o[i + 2] = b[s[i + 2]];
    o[i + 3] = s[i + 3];
  }
  return out;
}

/// RGB (0..255) -> HSL (h 0..360, s,l 0..1).
void rgbToHsl(double r, double g, double b, Float64List out) {
  r /= 255;
  g /= 255;
  b /= 255;
  final mx = math.max(r, math.max(g, b)), mn = math.min(r, math.min(g, b));
  final l = (mx + mn) / 2;
  var h = 0.0, s = 0.0;
  final d = mx - mn;
  if (d > 1e-9) {
    s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn);
    if (mx == r) {
      h = ((g - b) / d) % 6;
    } else if (mx == g) {
      h = (b - r) / d + 2;
    } else {
      h = (r - g) / d + 4;
    }
    h *= 60;
    if (h < 0) h += 360;
  }
  out[0] = h;
  out[1] = s;
  out[2] = l;
}

double _hue2rgb(double p, double q, double t) {
  if (t < 0) t += 1;
  if (t > 1) t -= 1;
  if (t < 1 / 6) return p + (q - p) * 6 * t;
  if (t < 1 / 2) return q;
  if (t < 2 / 3) return p + (q - p) * (2 / 3 - t) * 6;
  return p;
}

/// HSL -> RGB 0..255 written into [out].
void hslToRgb(double h, double s, double l, Float64List out) {
  h = ((h % 360) + 360) % 360 / 360;
  s = s.clamp(0.0, 1.0).toDouble();
  l = l.clamp(0.0, 1.0).toDouble();
  if (s < 1e-9) {
    out[0] = out[1] = out[2] = l * 255;
    return;
  }
  final q = l < 0.5 ? l * (1 + s) : l + s - l * s;
  final p = 2 * l - q;
  out[0] = _hue2rgb(p, q, h + 1 / 3) * 255;
  out[1] = _hue2rgb(p, q, h) * 255;
  out[2] = _hue2rgb(p, q, h - 1 / 3) * 255;
}

/// Bilinear sample of a straight-alpha image into premultiplied floats.
/// Coordinates outside the image clamp to the edge.
void sampleBilinear(FilterImage img, double x, double y, Float64List out) {
  final w = img.width, h = img.height;
  x = x.clamp(0.0, w - 1.0).toDouble();
  y = y.clamp(0.0, h - 1.0).toDouble();
  final x0 = x.floor(), y0 = y.floor();
  final x1 = math.min(x0 + 1, w - 1), y1 = math.min(y0 + 1, h - 1);
  final fx = x - x0, fy = y - y0;
  final d = img.rgba;
  out[0] = out[1] = out[2] = out[3] = 0;
  void acc(int px, int py, double wgt) {
    final i = (py * w + px) * 4;
    final a = d[i + 3] / 255;
    out[0] += d[i] * a * wgt;
    out[1] += d[i + 1] * a * wgt;
    out[2] += d[i + 2] * a * wgt;
    out[3] += a * wgt;
  }

  acc(x0, y0, (1 - fx) * (1 - fy));
  acc(x1, y0, fx * (1 - fy));
  acc(x0, y1, (1 - fx) * fy);
  acc(x1, y1, fx * fy);
}

void writePremul(Uint8List o, int i, Float64List px) {
  final a = px[3];
  if (a <= 1e-6) {
    o[i] = o[i + 1] = o[i + 2] = o[i + 3] = 0;
    return;
  }
  o[i] = toByte(px[0] / a);
  o[i + 1] = toByte(px[1] / a);
  o[i + 2] = toByte(px[2] / a);
  o[i + 3] = toByte(a * 255);
}

/// Deterministic hash noise in [0,1) (so results are repeatable).
double hashNoise(int x, int y, int seed) {
  var h = x * 374761393 + y * 668265263 + seed * 2147483647;
  h = (h ^ (h >> 13)) * 1274126177;
  h = h ^ (h >> 16);
  return (h & 0xFFFFFF) / 0x1000000;
}
