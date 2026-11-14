import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';

import '../../animation/domain/image_codecs.dart';
import '../domain/export_model.dart';
import 'image_decoder.dart';

/// Encodes rendered pixels. PNG is produced by the pure-Dart [PngCodec]
/// (in a background isolate), so it works on every platform. JPEG and WebP
/// come from the platform encoder in `flutter_image_compress`; if the
/// platform cannot produce them the export fails with a clear message and
/// is never silently replaced by another format.
abstract final class RasterEncoder {
  static Future<Uint8List> encode(RasterPixels p, ExportOptions o) async {
    switch (o.format) {
      case ExportFormat.png:
        return compute(_pngJob, (p.width, p.height, p.rgba));
      case ExportFormat.jpeg:
      case ExportFormat.webp:
        final src = await compute(_pngJob, (p.width, p.height, p.rgba));
        try {
          final out = await FlutterImageCompress.compressWithList(
            src,
            // The plugin only scales DOWN to these limits, so the exact pixel
            // size is kept.
            minWidth: p.width,
            minHeight: p.height,
            quality: o.quality.clamp(1, 100),
            format: o.format == ExportFormat.jpeg ? CompressFormat.jpeg : CompressFormat.webp,
            keepExif: false,
            autoCorrectionAngle: false,
          );
          return out;
        } catch (_) {
          throw ExportException('${o.format.label} export is not available on this device. Use PNG instead.');
        }
    }
  }
}

Uint8List _pngJob((int, int, Uint8List) a) => PngCodec.encode(a.$1, a.$2, a.$3);
