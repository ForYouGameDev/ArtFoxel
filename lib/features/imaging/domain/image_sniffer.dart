import 'dart:typed_data';

enum RasterFormat {
  png('PNG', 'image/png', 'png'),
  jpeg('JPEG', 'image/jpeg', 'jpg'),
  webp('WebP', 'image/webp', 'webp'),
  gif('GIF', 'image/gif', 'gif'),
  heic('HEIC', 'image/heic', 'heic'),
  unknown('Unknown', 'application/octet-stream', 'bin');

  const RasterFormat(this.label, this.mime, this.extension);
  final String label, mime, extension;

  /// Formats ARTFOXEL can decode for import. HEIC is deliberately absent:
  /// there is no decoder we can verify on every supported device.
  bool get importable => this == png || this == jpeg || this == webp || this == gif;
}

class SniffedImage {
  const SniffedImage(this.format, this.width, this.height, {this.hasAlpha, this.animated = false});
  final RasterFormat format;
  final int width, height;

  /// Null when the header does not say.
  final bool? hasAlpha;
  final bool animated;
}

/// Reads format and dimensions from the file header only — nothing is
/// decoded, so a hostile "decompression bomb" is rejected before it costs
/// memory.
abstract final class ImageSniffer {
  static RasterFormat detect(Uint8List b) {
    if (b.length >= 8 &&
        b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47 &&
        b[4] == 0x0D && b[5] == 0x0A && b[6] == 0x1A && b[7] == 0x0A) {
      return RasterFormat.png;
    }
    if (b.length >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) return RasterFormat.jpeg;
    if (b.length >= 12 && _s(b, 0, 4) == 'RIFF' && _s(b, 8, 4) == 'WEBP') return RasterFormat.webp;
    if (b.length >= 6 && (_s(b, 0, 6) == 'GIF87a' || _s(b, 0, 6) == 'GIF89a')) return RasterFormat.gif;
    if (b.length >= 12 && _s(b, 4, 4) == 'ftyp') {
      final brand = _s(b, 8, 4);
      if (const {'heic', 'heix', 'hevc', 'hevx', 'mif1', 'msf1', 'heim', 'heis'}.contains(brand)) {
        return RasterFormat.heic;
      }
    }
    return RasterFormat.unknown;
  }

  /// Returns null when the header is truncated or inconsistent.
  static SniffedImage? sniff(Uint8List b) {
    switch (detect(b)) {
      case RasterFormat.png:
        return _png(b);
      case RasterFormat.jpeg:
        return _jpeg(b);
      case RasterFormat.webp:
        return _webp(b);
      case RasterFormat.gif:
        if (b.length < 10) return null;
        final d = ByteData.sublistView(b);
        return SniffedImage(RasterFormat.gif, d.getUint16(6, Endian.little), d.getUint16(8, Endian.little),
            hasAlpha: true, animated: _gifFrames(b) > 1);
      case RasterFormat.heic:
        return const SniffedImage(RasterFormat.heic, 0, 0);
      case RasterFormat.unknown:
        return null;
    }
  }

  static String _s(Uint8List b, int o, int n) => String.fromCharCodes(b.sublist(o, o + n));

  static SniffedImage? _png(Uint8List b) {
    if (b.length < 33 || _s(b, 12, 4) != 'IHDR') return null;
    final d = ByteData.sublistView(b);
    final colorType = b[25];
    var alpha = colorType == 4 || colorType == 6;
    if (!alpha) {
      // tRNS chunk also gives transparency to palette/gray/RGB images.
      var p = 8;
      while (p + 12 <= b.length) {
        final len = d.getUint32(p);
        final type = _s(b, p + 4, 4);
        if (type == 'tRNS') {
          alpha = true;
          break;
        }
        if (type == 'IDAT' || type == 'IEND') break;
        p += 12 + len;
      }
    }
    final animated = _hasChunk(b, 'acTL');
    return SniffedImage(RasterFormat.png, d.getUint32(16), d.getUint32(20), hasAlpha: alpha, animated: animated);
  }

  static bool _hasChunk(Uint8List b, String name) {
    final d = ByteData.sublistView(b);
    var p = 8;
    while (p + 12 <= b.length) {
      final len = d.getUint32(p);
      final type = _s(b, p + 4, 4);
      if (type == name) return true;
      if (type == 'IDAT' || type == 'IEND') return false;
      p += 12 + len;
    }
    return false;
  }

  static SniffedImage? _jpeg(Uint8List b) {
    final d = ByteData.sublistView(b);
    var p = 2;
    while (p + 4 <= b.length) {
      if (b[p] != 0xFF) {
        p++;
        continue;
      }
      final marker = b[p + 1];
      if (marker == 0xFF) {
        p++;
        continue;
      }
      if (marker == 0xD8 || (marker >= 0xD0 && marker <= 0xD7) || marker == 0x01) {
        p += 2;
        continue;
      }
      if (marker == 0xD9 || marker == 0xDA) return null; // no frame header found
      final len = d.getUint16(p + 2);
      if (len < 2) return null;
      final isSof = marker >= 0xC0 && marker <= 0xCF && marker != 0xC4 && marker != 0xC8 && marker != 0xCC;
      if (isSof) {
        if (p + 9 > b.length) return null;
        return SniffedImage(RasterFormat.jpeg, d.getUint16(p + 7), d.getUint16(p + 5), hasAlpha: false);
      }
      p += 2 + len;
    }
    return null;
  }

  static SniffedImage? _webp(Uint8List b) {
    if (b.length < 30) return null;
    final d = ByteData.sublistView(b);
    final fourcc = _s(b, 12, 4);
    if (fourcc == 'VP8X') {
      final flags = b[20];
      final w = 1 + (b[24] | (b[25] << 8) | (b[26] << 16));
      final h = 1 + (b[27] | (b[28] << 8) | (b[29] << 16));
      return SniffedImage(RasterFormat.webp, w, h, hasAlpha: flags & 0x10 != 0, animated: flags & 0x02 != 0);
    }
    if (fourcc == 'VP8 ') {
      if (b[23] != 0x9D || b[24] != 0x01 || b[25] != 0x2A) return null;
      return SniffedImage(RasterFormat.webp, d.getUint16(26, Endian.little) & 0x3FFF,
          d.getUint16(28, Endian.little) & 0x3FFF, hasAlpha: false);
    }
    if (fourcc == 'VP8L') {
      if (b[20] != 0x2F) return null;
      final bits = d.getUint32(21, Endian.little);
      return SniffedImage(RasterFormat.webp, (bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1,
          hasAlpha: (bits >> 28) & 1 == 1);
    }
    return null;
  }

  static int _gifFrames(Uint8List b) {
    // Count image descriptors by walking blocks (bounded).
    if (b.length < 13) return 0;
    var p = 13;
    final packed = b[10];
    if (packed & 0x80 != 0) p += 3 * (1 << ((packed & 7) + 1));
    var frames = 0;
    while (p < b.length && frames < 2) {
      final t = b[p];
      if (t == 0x2C) {
        frames++;
        if (p + 10 > b.length) break;
        final lp = b[p + 9];
        p += 10;
        if (lp & 0x80 != 0) p += 3 * (1 << ((lp & 7) + 1));
        p++; // LZW min code size
        while (p < b.length && b[p] != 0) {
          p += b[p] + 1;
        }
        p++;
      } else if (t == 0x21) {
        p += 2;
        while (p < b.length && b[p] != 0) {
          p += b[p] + 1;
        }
        p++;
      } else {
        break;
      }
    }
    return frames;
  }
}
