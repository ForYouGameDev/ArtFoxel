import 'dart:math' as math;
import 'dart:typed_data';

import 'image_sniffer.dart';

enum ExportFormat {
  png(RasterFormat.png),
  jpeg(RasterFormat.jpeg),
  webp(RasterFormat.webp);

  const ExportFormat(this.raster);
  final RasterFormat raster;
  String get label => raster.label;
  String get extension => raster.extension;
  String get mime => raster.mime;

  /// JPEG cannot hold transparency; WebP can, PNG can.
  bool get supportsAlpha => this != jpeg;
  bool get lossy => this != png;
}

class ExportException implements Exception {
  const ExportException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Options of one static export. References, onion skin and drawing aids
/// (rulers, grids, symmetry guides, selection overlays) are NOT part of the
/// artwork and are only drawn when the matching flag is set explicitly.
class ExportOptions {
  const ExportOptions({
    this.format = ExportFormat.png,
    this.width,
    this.height,
    this.quality = 90,
    this.transparent = true,
    this.backgroundArgb = 0xFFFFFFFF,
    this.includeReferences = false,
    this.includeOnionSkin = false,
    this.includeGuides = false,
  });

  final ExportFormat format;

  /// Null = document size. Give one to keep the aspect ratio; both to
  /// override it (then the artwork is scaled, never cropped or stretched
  /// silently — see [ExportPlanner.size]).
  final int? width, height;
  final int quality; // 1..100, ignored for PNG
  final bool transparent;
  final int backgroundArgb;
  final bool includeReferences, includeOnionSkin, includeGuides;

  ExportOptions copyWith({
    ExportFormat? format,
    Object? width = _keep,
    Object? height = _keep,
    int? quality,
    bool? transparent,
    int? backgroundArgb,
    bool? includeReferences,
    bool? includeOnionSkin,
    bool? includeGuides,
  }) =>
      ExportOptions(
        format: format ?? this.format,
        width: identical(width, _keep) ? this.width : width as int?,
        height: identical(height, _keep) ? this.height : height as int?,
        quality: (quality ?? this.quality).clamp(1, 100),
        transparent: transparent ?? this.transparent,
        backgroundArgb: backgroundArgb ?? this.backgroundArgb,
        includeReferences: includeReferences ?? this.includeReferences,
        includeOnionSkin: includeOnionSkin ?? this.includeOnionSkin,
        includeGuides: includeGuides ?? this.includeGuides,
      );
  static const Object _keep = Object();

  /// Whether the output keeps an alpha channel.
  bool get keepsAlpha => transparent && format.supportsAlpha;
}

class ExportSize {
  const ExportSize(this.width, this.height, this.scale);
  final int width, height;
  final double scale;
  int get pixels => width * height;
}

abstract final class ExportPlanner {
  static const maxSide = 16384;
  static const maxPixels = 64 * 1000 * 1000;

  static ExportSize size(int docW, int docH, ExportOptions o) {
    if (docW < 1 || docH < 1) throw const ExportException('The canvas has no size.');
    int w, h;
    if (o.width != null && o.height != null) {
      w = o.width!;
      h = o.height!;
    } else if (o.width != null) {
      w = o.width!;
      h = (o.width! * docH / docW).round();
    } else if (o.height != null) {
      h = o.height!;
      w = (o.height! * docW / docH).round();
    } else {
      w = docW;
      h = docH;
    }
    if (w < 1 || h < 1) throw const ExportException('Export size must be at least 1 px.');
    if (w > maxSide || h > maxSide) {
      throw ExportException('Export size may be at most $maxSide px per side.');
    }
    if (w * h > maxPixels) {
      throw const ExportException('That export is too large for this device (over 64 megapixels).');
    }
    return ExportSize(w, h, w / docW);
  }

  /// Rough peak memory of rendering + encoding (RGBA + working copy).
  static int estimatedBytes(ExportSize s) => s.pixels * 4 * 3;

  static String fileName(String projectName, ExportFormat f, {DateTime? now, int? index}) {
    final base = projectName
        .replaceAll(RegExp(r'[^A-Za-z0-9._ -]+'), '')
        .trim()
        .replaceAll(RegExp(r'\s+'), '_');
    final stamp = (now ?? DateTime.now());
    final d = '${stamp.year}${stamp.month.toString().padLeft(2, '0')}${stamp.day.toString().padLeft(2, '0')}';
    final n = base.isEmpty ? 'artfoxel' : (base.length > 48 ? base.substring(0, 48) : base);
    return '${n}_$d${index == null ? '' : '_$index'}.${f.extension}';
  }
}

/// Composites straight RGBA over an opaque background (needed for JPEG and
/// for "not transparent" exports). Returns a new buffer with alpha = 255.
Uint8List flattenOver(Uint8List rgba, int backgroundArgb) {
  final br = (backgroundArgb >> 16) & 0xFF, bg = (backgroundArgb >> 8) & 0xFF, bb = backgroundArgb & 0xFF;
  final out = Uint8List(rgba.length);
  for (var i = 0; i < rgba.length; i += 4) {
    final a = rgba[i + 3];
    if (a == 255) {
      out[i] = rgba[i];
      out[i + 1] = rgba[i + 1];
      out[i + 2] = rgba[i + 2];
    } else if (a == 0) {
      out[i] = br;
      out[i + 1] = bg;
      out[i + 2] = bb;
    } else {
      final k = a / 255;
      out[i] = (rgba[i] * k + br * (1 - k)).round();
      out[i + 1] = (rgba[i + 1] * k + bg * (1 - k)).round();
      out[i + 2] = (rgba[i + 2] * k + bb * (1 - k)).round();
    }
    out[i + 3] = 255;
  }
  return out;
}

class VerifiedExport {
  const VerifiedExport(this.format, this.width, this.height, this.bytes, this.hasAlpha);
  final RasterFormat format;
  final int width, height, bytes;
  final bool? hasAlpha;
}

abstract final class ExportVerifier {
  /// Re-reads the written file's header and checks it matches what was asked
  /// for. Throws [ExportException] when it does not, so a broken export is
  /// reported instead of silently handed to the user.
  static VerifiedExport verify(Uint8List bytes, ExportOptions o, int expectedW, int expectedH) {
    if (bytes.isEmpty) throw const ExportException('The export produced an empty file.');
    final info = ImageSniffer.sniff(bytes);
    if (info == null || info.format != o.format.raster) {
      throw ExportException('The ${o.format.label} export did not produce a valid ${o.format.label} file.');
    }
    if (info.width != expectedW || info.height != expectedH) {
      throw ExportException(
          'The exported size is ${info.width}×${info.height}, expected $expectedW×$expectedH.');
    }
    if (o.format == ExportFormat.png && o.transparent && info.hasAlpha != true) {
      throw const ExportException('The transparent PNG lost its alpha channel.');
    }
    if (o.format == ExportFormat.jpeg && info.hasAlpha == true) {
      throw const ExportException('A JPEG cannot contain transparency.');
    }
    return VerifiedExport(info.format, info.width, info.height, bytes.length, info.hasAlpha);
  }

  /// Percentage of pixels that differ by more than [tolerance] — used by
  /// tests/diagnostics to prove an overlay was (not) drawn.
  static double differenceRatio(Uint8List a, Uint8List b, {int tolerance = 2}) {
    if (a.length != b.length) throw const ExportException('Buffers differ in size.');
    var diff = 0;
    for (var i = 0; i < a.length; i += 4) {
      final d = math.max(
          (a[i] - b[i]).abs(), math.max((a[i + 1] - b[i + 1]).abs(), math.max((a[i + 2] - b[i + 2]).abs(), (a[i + 3] - b[i + 3]).abs())));
      if (d > tolerance) diff++;
    }
    return diff / (a.length / 4);
  }
}
