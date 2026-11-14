import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../domain/import_rules.dart';

/// Pixels of a rendered/decoded image (straight RGBA).
class RasterPixels {
  const RasterPixels(this.width, this.height, this.rgba);
  final int width, height;
  final Uint8List rgba;
}

/// Decodes an image for import after validating it with [ImportRules].
/// Never decodes larger than [maxDecodeSide] (image layers are limited to 8192).
Future<(RasterPixels, ImportPlan)> decodeImageBytes(
  Uint8List bytes, {
  String? fileName,
  int maxDecodeSide = 8192,
  ImportLimits limits = ImportLimits.standard,
}) async {
  final plan = ImportRules.plan(bytes, fileName: fileName, limits: limits);
  var w = plan.decodeWidth, h = plan.decodeHeight;
  if (math.max(w, h) > maxDecodeSide) {
    final k = maxDecodeSide / math.max(w, h);
    w = math.max(1, (w * k).floor());
    h = math.max(1, (h * k).floor());
  }
  final resize = w != plan.info.width || h != plan.info.height;
  ui.Codec? codec;
  ui.Image? image;
  try {
    codec = await ui.instantiateImageCodec(
      bytes,
      targetWidth: resize ? w : null,
      targetHeight: resize ? h : null,
    );
    final frame = await codec.getNextFrame();
    image = frame.image;
    final data = await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
    if (data == null) throw const ImageImportException('The image could not be decoded.');
    return (
      RasterPixels(image.width, image.height, data.buffer.asUint8List()),
      ImportPlan(
        info: plan.info,
        decodeWidth: image.width,
        decodeHeight: image.height,
        warnings: [
          ...plan.warnings,
          if (resize && !plan.downscaled) 'Imported at ${image.width}×${image.height} (layer size limit).',
        ],
      ),
    );
  } on ImageImportException {
    rethrow;
  } on Object {
    throw const ImageImportException(
        'This image could not be decoded. It may be damaged or use an unsupported variant.');
  } finally {
    image?.dispose();
    codec?.dispose();
  }
}

