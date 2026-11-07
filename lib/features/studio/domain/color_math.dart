import 'dart:math' as math;

/// Colour harmonies offered by Color Studio.
enum Harmony {
  complementary('Complementary'),
  analogous('Analogous'),
  triadic('Triadic'),
  tetradic('Tetradic'),
  splitComplementary('Split complementary'),
  monochromatic('Monochromatic');

  const Harmony(this.label);
  final String label;
}

/// Pure colour conversions and validation. Colours are ARGB ints; RGB
/// channels are 0..255, hue 0..360, saturation/value/lightness 0..1.
abstract final class ColorMath {
  static int rgb(int r, int g, int b) =>
      0xFF000000 | (r.clamp(0, 255) << 16) | (g.clamp(0, 255) << 8) | b.clamp(0, 255);

  static int red(int argb) => (argb >> 16) & 0xFF;
  static int green(int argb) => (argb >> 8) & 0xFF;
  static int blue(int argb) => argb & 0xFF;

  // ---- HSV / HSL -----------------------------------------------------------------

  static (double, double, double) toHsv(int argb) {
    final r = red(argb) / 255, g = green(argb) / 255, b = blue(argb) / 255;
    final maxC = math.max(r, math.max(g, b)), minC = math.min(r, math.min(g, b));
    final d = maxC - minC;
    return (_hue(r, g, b, maxC, d), maxC == 0 ? 0 : d / maxC, maxC);
  }

  static int fromHsv(double h, double s, double v) {
    final hh = ((h % 360) + 360) % 360;
    final ss = s.clamp(0.0, 1.0).toDouble(), vv = v.clamp(0.0, 1.0).toDouble();
    final c = vv * ss;
    final x = c * (1 - (((hh / 60) % 2) - 1).abs());
    final m = vv - c;
    final (r, g, b) = switch (hh ~/ 60) {
      0 => (c, x, 0.0),
      1 => (x, c, 0.0),
      2 => (0.0, c, x),
      3 => (0.0, x, c),
      4 => (x, 0.0, c),
      _ => (c, 0.0, x),
    };
    return rgb(((r + m) * 255).round(), ((g + m) * 255).round(), ((b + m) * 255).round());
  }

  static (double, double, double) toHsl(int argb) {
    final r = red(argb) / 255, g = green(argb) / 255, b = blue(argb) / 255;
    final maxC = math.max(r, math.max(g, b)), minC = math.min(r, math.min(g, b));
    final d = maxC - minC;
    final l = (maxC + minC) / 2;
    final s = d == 0 ? 0.0 : d / (1 - (2 * l - 1).abs());
    return (_hue(r, g, b, maxC, d), s.clamp(0.0, 1.0).toDouble(), l);
  }

  static int fromHsl(double h, double s, double l) {
    final ss = s.clamp(0.0, 1.0).toDouble(), ll = l.clamp(0.0, 1.0).toDouble();
    final v = ll + ss * math.min(ll, 1 - ll);
    return fromHsv(h, v == 0 ? 0 : 2 * (1 - ll / v), v);
  }

  static double _hue(double r, double g, double b, double maxC, double d) {
    if (d == 0) return 0;
    double h;
    if (maxC == r) {
      h = ((g - b) / d) % 6;
    } else if (maxC == g) {
      h = (b - r) / d + 2;
    } else {
      h = (r - g) / d + 4;
    }
    return ((h * 60) + 360) % 360;
  }

  // ---- HEX ------------------------------------------------------------------------

  /// Parses `RGB`, `RRGGBB` (optionally prefixed with `#`). Returns null for
  /// anything else, so callers can show an error instead of guessing.
  static int? parseHex(String input) {
    var text = input.trim();
    if (text.startsWith('#')) text = text.substring(1);
    if (!RegExp(r'^[0-9a-fA-F]+$').hasMatch(text)) return null;
    if (text.length == 3) {
      text = text.split('').map((c) => '$c$c').join();
    }
    if (text.length != 6) return null;
    return 0xFF000000 | int.parse(text, radix: 16);
  }

  static String toHex(int argb, {bool hash = true}) =>
      '${hash ? '#' : ''}${(argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

  /// Whole-number channel text → value in [0, max], or null when invalid.
  static int? parseChannel(String input, {int max = 255}) {
    final text = input.trim();
    if (!RegExp(r'^\d{1,4}$').hasMatch(text)) return null;
    final value = int.parse(text);
    return value > max ? null : value;
  }

  // ---- accessibility ---------------------------------------------------------------

  /// WCAG 2.x relative luminance.
  static double luminance(int argb) {
    double lin(int c) {
      final v = c / 255;
      return v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
    }

    return 0.2126 * lin(red(argb)) + 0.7152 * lin(green(argb)) + 0.0722 * lin(blue(argb));
  }

  static double contrastRatio(int a, int b) {
    final la = luminance(a), lb = luminance(b);
    return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
  }

  /// Black or white, whichever reads better on [background].
  static int readableOn(int background) =>
      contrastRatio(background, 0xFF000000) >= contrastRatio(background, 0xFFFFFFFF)
          ? 0xFF000000
          : 0xFFFFFFFF;

  /// "AAA", "AA", "AA large" or "Fail" for [a] against [b].
  static String wcagGrade(int a, int b) {
    final r = contrastRatio(a, b);
    if (r >= 7) return 'AAA';
    if (r >= 4.5) return 'AA';
    if (r >= 3) return 'AA large';
    return 'Fail';
  }

  // ---- harmony ----------------------------------------------------------------------

  /// Colours harmonious with [base] (the base itself is first).
  static List<int> harmony(int base, Harmony kind) {
    final (h, s, v) = toHsv(base);
    int rot(double deg) => fromHsv(h + deg, s, v);
    switch (kind) {
      case Harmony.complementary:
        return [base, rot(180)];
      case Harmony.analogous:
        return [rot(-30), base, rot(30)];
      case Harmony.triadic:
        return [base, rot(120), rot(240)];
      case Harmony.tetradic:
        return [base, rot(90), rot(180), rot(270)];
      case Harmony.splitComplementary:
        return [base, rot(150), rot(210)];
      case Harmony.monochromatic:
        return [for (final f in const [0.45, 0.65, 0.85, 1.0]) fromHsv(h, s, v * f)];
    }
  }
}
