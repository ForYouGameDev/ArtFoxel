import 'dart:typed_data';

import '../../studio/application/sketch_controller.dart';
import '../data/raster_encoder.dart';
import '../domain/export_model.dart';

class ExportResult {
  const ExportResult(this.bytes, this.verified, this.fileName);
  final Uint8List bytes;
  final VerifiedExport verified;
  final String fileName;

  String get summary =>
      '${verified.format.label} ${verified.width}×${verified.height}, ${(bytes.length / 1024).toStringAsFixed(0)} KB, checked OK';
}

/// Renders the artwork, encodes it and re-reads the result before handing it
/// to the user. A file that fails verification is never returned.
abstract final class ExportService {
  static Future<ExportResult> exportSketch(SketchController c, ExportOptions o, String projectName) async {
    final size = ExportPlanner.size(c.data.width, c.data.height, o);
    final pixels = await c.renderArtwork(o);
    final bytes = await RasterEncoder.encode(pixels, o);
    final verified = ExportVerifier.verify(bytes, o, size.width, size.height);
    return ExportResult(bytes, verified, ExportPlanner.fileName(projectName, o.format));
  }
}
