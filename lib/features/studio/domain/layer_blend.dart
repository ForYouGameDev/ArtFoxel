import 'dart:math' as math;
import 'dart:ui' show BlendMode;

/// Layer blend modes.
///
/// Only modes whose rendering is delegated to a real engine blend mode are
/// offered in the UI (every value of this enum). The Photoshop-style
/// modes that Skia has no equivalent for (Linear Burn, Vivid Light, Linear
/// Light, Pin Light, Hard Mix) are deliberately NOT exposed: emulating them
/// without a custom shader that can be verified on-device would give wrong
/// colours, and the spec says not to present those as complete.
///
/// A stored project may still contain such a name (for example from a future
/// version); it loads as [normal] and is reported via [fromName]'s fallback.
enum LayerBlend {
  normal('Normal', BlendMode.srcOver),
  multiply('Multiply', BlendMode.multiply),
  screen('Screen', BlendMode.screen),
  overlay('Overlay', BlendMode.overlay),
  darken('Darken', BlendMode.darken),
  lighten('Lighten', BlendMode.lighten),
  colorDodge('Color Dodge', BlendMode.colorDodge),
  colorBurn('Color Burn', BlendMode.colorBurn),
  linearDodge('Linear Dodge (Add)', BlendMode.plus),
  difference('Difference', BlendMode.difference),
  exclusion('Exclusion', BlendMode.exclusion),
  softLight('Soft Light', BlendMode.softLight),
  hardLight('Hard Light', BlendMode.hardLight),
  hue('Hue', BlendMode.hue),
  saturation('Saturation', BlendMode.saturation),
  color('Color', BlendMode.color),
  luminosity('Luminosity', BlendMode.luminosity);

  const LayerBlend(this.label, this.flutter);

  final String label;
  final BlendMode flutter;

  /// Photoshop modes that are intentionally unavailable (see class docs).
  static const List<String> unsupported = [
    'Linear Burn',
    'Vivid Light',
    'Linear Light',
    'Pin Light',
    'Hard Mix',
  ];

  static LayerBlend fromName(String? name) {
    for (final mode in values) {
      if (mode.name == name) return mode;
    }
    return normal;
  }
}

/// Reference implementations of the separable blend functions on straight
/// (non-premultiplied) channel values in 0..1, following the W3C
/// "Compositing and Blending Level 1" definitions. They are the specification
/// the tests check against; the renderer itself uses the engine's blend modes.
abstract final class BlendMath {
  /// `B(cb, cs)`: backdrop channel [cb], source channel [cs].
  static double channel(LayerBlend mode, double cb, double cs) {
    switch (mode) {
      case LayerBlend.normal:
        return cs;
      case LayerBlend.multiply:
        return cb * cs;
      case LayerBlend.screen:
        return cb + cs - cb * cs;
      case LayerBlend.overlay:
        return channel(LayerBlend.hardLight, cs, cb);
      case LayerBlend.darken:
        return math.min(cb, cs);
      case LayerBlend.lighten:
        return math.max(cb, cs);
      case LayerBlend.colorDodge:
        if (cb == 0) return 0;
        if (cs >= 1) return 1;
        return math.min(1, cb / (1 - cs));
      case LayerBlend.colorBurn:
        if (cb >= 1) return 1;
        if (cs <= 0) return 0;
        return 1 - math.min(1, (1 - cb) / cs);
      case LayerBlend.linearDodge:
        return math.min(1, cb + cs);
      case LayerBlend.difference:
        return (cb - cs).abs();
      case LayerBlend.exclusion:
        return cb + cs - 2 * cb * cs;
      case LayerBlend.hardLight:
        return cs <= 0.5
            ? cb * 2 * cs
            : channel(LayerBlend.screen, cb, 2 * cs - 1);
      case LayerBlend.softLight:
        if (cs <= 0.5) {
          return cb - (1 - 2 * cs) * cb * (1 - cb);
        }
        final d = cb <= 0.25
            ? ((16 * cb - 12) * cb + 4) * cb
            : math.sqrt(cb);
        return cb + (2 * cs - 1) * (d - cb);
      case LayerBlend.hue:
      case LayerBlend.saturation:
      case LayerBlend.color:
      case LayerBlend.luminosity:
        throw ArgumentError('${mode.name} is non-separable; use blendRgb.');
    }
  }

  static double _lum(List<double> c) => 0.3 * c[0] + 0.59 * c[1] + 0.11 * c[2];

  static List<double> _clipColor(List<double> c) {
    final l = _lum(c);
    final n = c.reduce(math.min);
    final x = c.reduce(math.max);
    var out = List<double>.of(c);
    if (n < 0) {
      out = [for (final v in out) l + (v - l) * l / (l - n)];
    }
    if (x > 1) {
      out = [for (final v in out) l + (v - l) * (1 - l) / (x - l)];
    }
    return out;
  }

  static List<double> _setLum(List<double> c, double l) {
    final d = l - _lum(c);
    return _clipColor([c[0] + d, c[1] + d, c[2] + d]);
  }

  static double _sat(List<double> c) => c.reduce(math.max) - c.reduce(math.min);

  static List<double> _setSat(List<double> c, double s) {
    final order = [0, 1, 2]..sort((i, j) => c[i].compareTo(c[j]));
    final minI = order[0], midI = order[1], maxI = order[2];
    final out = [0.0, 0.0, 0.0];
    if (c[maxI] > c[minI]) {
      out[midI] = (c[midI] - c[minI]) * s / (c[maxI] - c[minI]);
      out[maxI] = s;
    }
    return out;
  }

  /// Blends whole RGB triples; works for every mode in [LayerBlend].
  static List<double> blendRgb(
    LayerBlend mode,
    List<double> backdrop,
    List<double> source,
  ) {
    switch (mode) {
      case LayerBlend.hue:
        return _setLum(_setSat(source, _sat(backdrop)), _lum(backdrop));
      case LayerBlend.saturation:
        return _setLum(_setSat(backdrop, _sat(source)), _lum(backdrop));
      case LayerBlend.color:
        return _setLum(source, _lum(backdrop));
      case LayerBlend.luminosity:
        return _setLum(backdrop, _lum(source));
      default:
        return [
          for (var i = 0; i < 3; i++) channel(mode, backdrop[i], source[i]),
        ];
    }
  }

  /// Full source-over compositing with a blend mode on straight RGBA, as in
  /// the W3C spec: `co = cs*(1-ab) ... `. Returns [r, g, b, a].
  static List<double> composite(
    LayerBlend mode,
    List<double> backdrop, // r,g,b,a
    List<double> source, // r,g,b,a
  ) {
    final ab = backdrop[3];
    final sa = source[3];
    final ao = sa + ab * (1 - sa);
    if (ao <= 0) return [0, 0, 0, 0];
    final blended = blendRgb(mode, backdrop.sublist(0, 3), source.sublist(0, 3));
    final out = List<double>.filled(4, 0);
    for (var i = 0; i < 3; i++) {
      final cs = (1 - ab) * source[i] + ab * blended[i];
      out[i] = (sa * cs + (1 - sa) * ab * backdrop[i]) / ao;
    }
    out[3] = ao;
    return out;
  }
}
