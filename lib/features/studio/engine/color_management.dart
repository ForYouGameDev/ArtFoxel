import 'dart:math' as math;
import 'dart:typed_data';

/// Phase 7.5.8 — colour models and profile handling.
///
/// What is real: sRGB ↔ linear ↔ XYZ(D65) ↔ CIELAB/LCH, Display P3 ↔ sRGB
/// matrices with gamut check, HEX/RGB/HSV/HSL (see color_math.dart).
/// What is NOT: CMYK here is the naive device-independent formula (NOT an
/// ICC conversion), ICC profiles are only header-validated and never applied
/// to pixels, and soft proofing is not implemented ([softProofAvailable]).

enum ColorSpaceId { srgb, displayP3 }

class Lab {
  const Lab(this.l, this.a, this.b);
  final double l, a, b;
}

class Cmyk {
  const Cmyk(this.c, this.m, this.y, this.k);
  final double c, m, y, k;
}

class ColorManagement {
  static const softProofAvailable = false;
  static const iccApplied = false;

  static double toLinear(double v) =>
      v <= 0.04045 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  static double fromLinear(double v) =>
      v <= 0.0031308 ? v * 12.92 : 1.055 * math.pow(v, 1 / 2.4).toDouble() - 0.055;

  // sRGB(D65) linear → XYZ
  static (double, double, double) srgbToXyz(int argb) {
    final r = toLinear(((argb >> 16) & 0xFF) / 255);
    final g = toLinear(((argb >> 8) & 0xFF) / 255);
    final b = toLinear((argb & 0xFF) / 255);
    return (
      0.4124564 * r + 0.3575761 * g + 0.1804375 * b,
      0.2126729 * r + 0.7151522 * g + 0.0721750 * b,
      0.0193339 * r + 0.1191920 * g + 0.9503041 * b,
    );
  }

  static int xyzToSrgb(double x, double y, double z, {int alpha = 255}) {
    final r = 3.2404542 * x - 1.5371385 * y - 0.4985314 * z;
    final g = -0.9692660 * x + 1.8760108 * y + 0.0415560 * z;
    final b = 0.0556434 * x - 0.2040259 * y + 1.0572252 * z;
    int c(double v) => (fromLinear(v.clamp(0.0, 1.0)) * 255).round().clamp(0, 255);
    return (alpha << 24) | (c(r) << 16) | (c(g) << 8) | c(b);
  }

  static const _xn = 0.95047, _yn = 1.0, _zn = 1.08883;
  static double _f(double t) =>
      t > 216 / 24389 ? math.pow(t, 1 / 3).toDouble() : (24389 / 27 * t + 16) / 116;
  static double _finv(double t) {
    final t3 = t * t * t;
    return t3 > 216 / 24389 ? t3 : (116 * t - 16) / (24389 / 27);
  }

  static Lab toLab(int argb) {
    final (x, y, z) = srgbToXyz(argb);
    final fx = _f(x / _xn), fy = _f(y / _yn), fz = _f(z / _zn);
    return Lab(116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz));
  }

  static int fromLab(Lab c, {int alpha = 255}) {
    final fy = (c.l + 16) / 116;
    final fx = fy + c.a / 500, fz = fy - c.b / 200;
    return xyzToSrgb(_xn * _finv(fx), _yn * _finv(fy), _zn * _finv(fz), alpha: alpha);
  }

  /// CIE76 ΔE — good enough for "is this noticeably different".
  static double deltaE(int a, int b) {
    final x = toLab(a), y = toLab(b);
    return math.sqrt(math.pow(x.l - y.l, 2) + math.pow(x.a - y.a, 2) + math.pow(x.b - y.b, 2));
  }

  static (double, double, double) toLch(int argb) {
    final l = toLab(argb);
    var h = math.atan2(l.b, l.a) * 180 / math.pi;
    if (h < 0) h += 360;
    return (l.l, math.sqrt(l.a * l.a + l.b * l.b), h);
  }

  static int fromLch(double l, double c, double h) =>
      fromLab(Lab(l, c * math.cos(h * math.pi / 180), c * math.sin(h * math.pi / 180)));

  /// Naive CMYK (no black generation curve, no ink limits, no ICC).
  static Cmyk toCmykNaive(int argb) {
    final r = ((argb >> 16) & 0xFF) / 255, g = ((argb >> 8) & 0xFF) / 255, b = (argb & 0xFF) / 255;
    final double k = 1.0 - math.max(r, math.max(g, b));
    if (k >= 1) return const Cmyk(0, 0, 0, 1);
    return Cmyk((1 - r - k) / (1 - k), (1 - g - k) / (1 - k), (1 - b - k) / (1 - k), k);
  }

  static int fromCmykNaive(Cmyk c) {
    int ch(double v, double k) => (255 * (1 - v) * (1 - k)).round().clamp(0, 255);
    return 0xFF000000 | (ch(c.c, c.k) << 16) | (ch(c.m, c.k) << 8) | ch(c.y, c.k);
  }

  // Display P3 (D65) linear → XYZ
  static const _p3ToXyz = [
    0.4865709, 0.2656677, 0.1982173,
    0.2289746, 0.6917385, 0.0792869,
    0.0000000, 0.0451134, 1.0439444,
  ];

  /// P3 components (0..1, P3 transfer = sRGB curve) → sRGB. [outOfGamut] is
  /// true when the colour cannot be represented in sRGB and was clipped.
  static (int, bool) p3ToSrgb(double r, double g, double b) {
    final lr = toLinear(r), lg = toLinear(g), lb = toLinear(b);
    final x = _p3ToXyz[0] * lr + _p3ToXyz[1] * lg + _p3ToXyz[2] * lb;
    final y = _p3ToXyz[3] * lr + _p3ToXyz[4] * lg + _p3ToXyz[5] * lb;
    final z = _p3ToXyz[6] * lr + _p3ToXyz[7] * lg + _p3ToXyz[8] * lb;
    final sr = 3.2404542 * x - 1.5371385 * y - 0.4985314 * z;
    final sg = -0.9692660 * x + 1.8760108 * y + 0.0415560 * z;
    final sb = 0.0556434 * x - 0.2040259 * y + 1.0572252 * z;
    const e = 1e-3; // matrix rounding tolerance
    final out = sr < -e || sr > 1 + e || sg < -e || sg > 1 + e || sb < -e || sb > 1 + e;
    return (xyzToSrgb(x, y, z), out);
  }
}

class IccHeader {
  IccHeader(this.size, this.version, this.profileClass, this.colourSpace, this.pcs, this.description);
  final int size;
  final String version, profileClass, colourSpace, pcs;
  final String? description;
}

class IccException implements Exception {
  IccException(this.message);
  final String message;
  @override
  String toString() => 'IccException: $message';
}

class IccInspector {
  static const maxBytes = 8 * 1024 * 1024;

  /// Validates the 128-byte ICC header and reads the 'desc' tag when
  /// present. Does not interpret curves/LUTs, so it cannot convert pixels.
  static IccHeader inspect(Uint8List b) {
    if (b.length < 132) throw IccException('too small for an ICC profile');
    if (b.length > maxBytes) throw IccException('profile too large');
    final bd = ByteData.sublistView(b);
    final size = bd.getUint32(0);
    if (size != b.length) throw IccException('declared size does not match file size');
    String tag(int o) => String.fromCharCodes(b.sublist(o, o + 4));
    if (tag(36) != 'acsp') throw IccException('missing acsp signature');
    final major = b[8], minor = b[9] >> 4;
    final cls = tag(12), cs = tag(16).trim(), pcs = tag(20).trim();
    const classes = {'scnr', 'mntr', 'prtr', 'link', 'spac', 'abst', 'nmcl'};
    if (!classes.contains(cls)) throw IccException('unknown profile class "$cls"');
    final count = bd.getUint32(128);
    if (count > 200 || 132 + count * 12 > b.length) throw IccException('bad tag table');
    String? desc;
    for (var i = 0; i < count; i++) {
      final o = 132 + i * 12;
      if (tag(o) != 'desc') continue;
      final off = bd.getUint32(o + 4), len = bd.getUint32(o + 8);
      if (off + len > b.length || len < 12) throw IccException('tag out of bounds');
      final type = tag(off);
      if (type == 'desc' && len >= 12) {
        final n = bd.getUint32(off + 8);
        if (n > 0 && off + 12 + n <= b.length) {
          desc = String.fromCharCodes(b.sublist(off + 12, off + 12 + n - 1));
        }
      } else if (type == 'mluc' && len >= 28) {
        final strLen = bd.getUint32(off + 20), strOff = bd.getUint32(off + 24);
        if (strOff + strLen <= len && off + strOff + strLen <= b.length) {
          final units = <int>[];
          for (var k = 0; k + 1 < strLen; k += 2) {
            units.add(bd.getUint16(off + strOff + k));
          }
          desc = String.fromCharCodes(units);
        }
      }
    }
    return IccHeader(size, '$major.$minor', cls, cs, pcs, desc);
  }
}

/// Per-document colour settings (metadata; pixels stay sRGB RGBA8).
class DocumentColorSettings {
  const DocumentColorSettings({this.workingSpace = ColorSpaceId.srgb, this.iccName});
  final ColorSpaceId workingSpace;
  final String? iccName; // informational only
  Map<String, Object?> toJson() => {'space': workingSpace.name, 'icc': iccName};
  static DocumentColorSettings fromJson(Map<String, Object?> j) => DocumentColorSettings(
      workingSpace: ColorSpaceId.values.firstWhere((s) => s.name == j['space'],
          orElse: () => ColorSpaceId.srgb),
      iccName: j['icc'] is String ? j['icc'] as String : null);
}
