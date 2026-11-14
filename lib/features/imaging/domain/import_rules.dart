import 'dart:math' as math;
import 'dart:typed_data';

import '../../studio/domain/affine2d.dart';
import 'image_sniffer.dart';

class ImageImportException implements Exception {
  const ImageImportException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// What the app is willing to decode. Checked from the header before any
/// pixel is allocated.
class ImportLimits {
  const ImportLimits({
    this.maxFileBytes = 40 * 1024 * 1024,
    this.maxSide = 16384,
    this.maxDecodePixels = 24 * 1000 * 1000,
    this.maxAspect = 64,
  });
  final int maxFileBytes, maxSide, maxDecodePixels;
  final int maxAspect;
  static const standard = ImportLimits();
}

class ImportPlan {
  const ImportPlan({
    required this.info,
    required this.decodeWidth,
    required this.decodeHeight,
    required this.warnings,
  });
  final SniffedImage info;

  /// Size to decode at (smaller than the file when memory limits demand it).
  final int decodeWidth, decodeHeight;
  final List<String> warnings;
  bool get downscaled => decodeWidth != info.width || decodeHeight != info.height;
  int get decodedBytes => decodeWidth * decodeHeight * 4;
}

abstract final class ImportRules {
  static const pickerExtensions = ['png', 'jpg', 'jpeg', 'webp', 'gif'];

  /// Validates and plans the decode. Throws [ImageImportException] with a
  /// message that tells the user what to do.
  static ImportPlan plan(Uint8List bytes, {String? fileName, ImportLimits limits = ImportLimits.standard}) {
    if (bytes.isEmpty) throw const ImageImportException('That file is empty.');
    if (bytes.length > limits.maxFileBytes) {
      throw ImageImportException(
          'That file is ${(bytes.length / 1048576).toStringAsFixed(1)} MB. The limit is '
          '${limits.maxFileBytes ~/ 1048576} MB.');
    }
    final format = ImageSniffer.detect(bytes);
    if (format == RasterFormat.heic) {
      throw const ImageImportException(
          'HEIC photos are not supported yet. Export the photo as JPEG or PNG and import that.');
    }
    if (!format.importable) {
      throw const ImageImportException('This is not a PNG, JPEG, WebP or GIF image.');
    }
    final info = ImageSniffer.sniff(bytes);
    if (info == null || info.width < 1 || info.height < 1) {
      throw const ImageImportException('The image header is damaged, so it cannot be opened.');
    }
    if (info.width > limits.maxSide || info.height > limits.maxSide) {
      throw ImageImportException(
          'The image is ${info.width}×${info.height}. The longest side may be at most ${limits.maxSide} px.');
    }
    if (math.max(info.width, info.height) / math.min(info.width, info.height) > limits.maxAspect) {
      throw const ImageImportException('The image proportions are too extreme to import.');
    }
    final warnings = <String>[];
    if (info.animated) warnings.add('Animated images import their first frame only.');
    var w = info.width, h = info.height;
    final pixels = w * h;
    if (pixels > limits.maxDecodePixels) {
      final k = math.sqrt(limits.maxDecodePixels / pixels);
      w = math.max(1, (w * k).floor());
      h = math.max(1, (h * k).floor());
      warnings.add('Large image: imported at $w×$h to protect memory.');
    }
    return ImportPlan(info: info, decodeWidth: w, decodeHeight: h, warnings: warnings);
  }

  /// Sorts names the way a sequence should play ("frame2" before "frame10").
  static int naturalCompare(String a, String b) {
    final ra = RegExp(r'(\d+|\D+)').allMatches(a.toLowerCase()).map((m) => m[0]!).toList();
    final rb = RegExp(r'(\d+|\D+)').allMatches(b.toLowerCase()).map((m) => m[0]!).toList();
    for (var i = 0; i < math.min(ra.length, rb.length); i++) {
      final x = ra[i], y = rb[i];
      final nx = int.tryParse(x), ny = int.tryParse(y);
      final c = (nx != null && ny != null) ? nx.compareTo(ny) : x.compareTo(y);
      if (c != 0) return c;
    }
    return ra.length.compareTo(rb.length);
  }
}

enum FitMode { fit, fill, original, stretch }

/// Where an imported image sits on the canvas. Everything is in document
/// pixels; crop is normalised (0..1) in image space.
class ImagePlacement {
  const ImagePlacement({
    this.fit = FitMode.fit,
    this.dx = 0,
    this.dy = 0,
    this.scale = 1,
    this.rotationDeg = 0,
    this.crop = const CropRect(),
    this.flipH = false,
    this.flipV = false,
  });
  final FitMode fit;

  /// Offset of the image centre from the canvas centre.
  final double dx, dy;

  /// Extra scale on top of [fit].
  final double scale;
  final double rotationDeg;
  final CropRect crop;
  final bool flipH, flipV;

  ImagePlacement copyWith({
    FitMode? fit,
    double? dx,
    double? dy,
    double? scale,
    double? rotationDeg,
    CropRect? crop,
    bool? flipH,
    bool? flipV,
  }) =>
      ImagePlacement(
        fit: fit ?? this.fit,
        dx: dx ?? this.dx,
        dy: dy ?? this.dy,
        scale: (scale ?? this.scale).clamp(0.01, 50.0),
        rotationDeg: rotationDeg ?? this.rotationDeg,
        crop: crop ?? this.crop,
        flipH: flipH ?? this.flipH,
        flipV: flipV ?? this.flipV,
      );

  /// Base scale that applies [fit] to the (cropped) image.
  double baseScale(int docW, int docH, int imgW, int imgH) {
    final cw = imgW * crop.width, ch = imgH * crop.height;
    switch (fit) {
      case FitMode.fit:
        return math.min(docW / cw, docH / ch);
      case FitMode.fill:
        return math.max(docW / cw, docH / ch);
      case FitMode.original:
      case FitMode.stretch:
        return 1;
    }
  }

  /// Matrix mapping CROPPED-image pixel coordinates to document coordinates.
  /// Aspect ratio is preserved except in [FitMode.stretch].
  Affine2D toAffine(int docW, int docH, int imgW, int imgH) {
    final cw = imgW * crop.width, ch = imgH * crop.height;
    var sx = baseScale(docW, docH, imgW, imgH) * scale;
    var sy = sx;
    if (fit == FitMode.stretch) {
      sx = docW / cw * scale;
      sy = docH / ch * scale;
    }
    var m = Affine2D.translation(-cw / 2, -ch / 2);
    m = Affine2D.scale(flipH ? -sx : sx, flipV ? -sy : sy) * m;
    m = Affine2D.rotation(rotationDeg * math.pi / 180) * m;
    return Affine2D.translation(docW / 2 + dx, docH / 2 + dy) * m;
  }
}

class CropRect {
  const CropRect({this.left = 0, this.top = 0, this.width = 1, this.height = 1});
  final double left, top, width, height;
  bool get isFull => left == 0 && top == 0 && width == 1 && height == 1;

  CropRect clamped() {
    final l = left.clamp(0.0, 0.99), t = top.clamp(0.0, 0.99);
    return CropRect(
      left: l,
      top: t,
      width: width.clamp(0.01, 1.0 - l),
      height: height.clamp(0.01, 1.0 - t),
    );
  }

  /// Pixel rect (x, y, w, h) inside an image of the given size.
  (int, int, int, int) pixels(int imgW, int imgH) {
    final c = clamped();
    final x = (c.left * imgW).round().clamp(0, imgW - 1);
    final y = (c.top * imgH).round().clamp(0, imgH - 1);
    final w = (c.width * imgW).round().clamp(1, imgW - x);
    final h = (c.height * imgH).round().clamp(1, imgH - y);
    return (x, y, w, h);
  }
}

/// Crops straight RGBA bytes.
Uint8List cropRgba(Uint8List rgba, int w, int h, int x, int y, int cw, int ch) {
  if (rgba.length != w * h * 4 || x < 0 || y < 0 || cw < 1 || ch < 1 || x + cw > w || y + ch > h) {
    throw ArgumentError('Invalid crop');
  }
  final out = Uint8List(cw * ch * 4);
  for (var row = 0; row < ch; row++) {
    out.setRange(row * cw * 4, (row + 1) * cw * 4, rgba, ((y + row) * w + x) * 4);
  }
  return out;
}
