import 'dart:typed_data';

import 'package:artfoxel/features/animation/domain/image_codecs.dart';
import 'package:artfoxel/features/imaging/domain/export_model.dart';
import 'package:artfoxel/features/imaging/domain/image_sniffer.dart';
import 'package:artfoxel/features/imaging/domain/import_rules.dart';
import 'package:artfoxel/features/imaging/domain/timelapse.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _png(int w, int h, {int alpha = 255}) {
  final px = Uint8List(w * h * 4);
  for (var i = 0; i < px.length; i += 4) {
    px[i] = 200;
    px[i + 1] = 30;
    px[i + 2] = 60;
    px[i + 3] = alpha;
  }
  return PngCodec.encode(w, h, px);
}

void main() {
  test('sniffs PNG size', () {
    final i = ImageSniffer.sniff(_png(12, 7))!;
    expect((i.format, i.width, i.height), (RasterFormat.png, 12, 7));
  });

  test('import rules reject empty, huge side and non-images', () {
    expect(() => ImportRules.plan(Uint8List(0)), throwsA(isA<ImageImportException>()));
    expect(() => ImportRules.plan(Uint8List.fromList(List.filled(40, 3))), throwsA(isA<ImageImportException>()));
    expect(() => ImportRules.plan(_png(10, 10), limits: const ImportLimits(maxSide: 8)), throwsA(isA<ImageImportException>()));
  });

  test('HEIC is refused with a clear message', () {
    final heic = Uint8List.fromList([0, 0, 0, 24, ...'ftypheic'.codeUnits, ...List.filled(16, 0)]);
    expect(() => ImportRules.plan(heic), throwsA(isA<ImageImportException>().having((e) => e.message, 'm', contains('HEIC'))));
  });

  test('natural sort orders frame2 before frame10', () {
    final l = ['frame10.png', 'frame2.png', 'frame1.png']..sort(ImportRules.naturalCompare);
    expect(l, ['frame1.png', 'frame2.png', 'frame10.png']);
  });

  test('placement fit keeps aspect ratio and centres', () {
    final m = const ImagePlacement().toAffine(200, 100, 50, 50);
    expect(m.a, closeTo(2, 1e-9));
    expect(m.d, closeTo(2, 1e-9));
    expect(m.e, closeTo(50, 1e-9)); // (200-100)/2
  });

  test('crop rect pixels and cropRgba', () {
    final c = const CropRect(left: 0.5, top: 0, width: 0.5, height: 1).pixels(4, 2);
    expect(c, (2, 0, 2, 2));
    final src = Uint8List.fromList(List.generate(4 * 2 * 4, (i) => i));
    expect(cropRgba(src, 4, 2, 2, 0, 2, 2).length, 16);
    expect(() => cropRgba(src, 4, 2, 3, 0, 2, 2), throwsArgumentError);
  });

  test('export planner sizes and limits', () {
    const o = ExportOptions(width: 200);
    final s = ExportPlanner.size(100, 50, o);
    expect((s.width, s.height), (200, 100));
    expect(() => ExportPlanner.size(100, 50, const ExportOptions(width: 99999)), throwsA(isA<ExportException>()));
  });

  test('references/onion/guides are off by default', () {
    const o = ExportOptions();
    expect(o.includeReferences || o.includeOnionSkin || o.includeGuides, isFalse);
  });

  test('flattenOver removes alpha', () {
    final out = flattenOver(Uint8List.fromList([255, 0, 0, 0, 0, 255, 0, 128]), 0xFFFFFFFF);
    expect(out[3], 255);
    expect(out.sublist(0, 3), [255, 255, 255]);
    expect(out[5], greaterThan(100));
  });

  test('verifier accepts matching PNG and rejects wrong size / lost alpha', () {
    final good = _png(8, 4, alpha: 100);
    const o = ExportOptions();
    expect(ExportVerifier.verify(good, o, 8, 4).width, 8);
    expect(() => ExportVerifier.verify(good, o, 9, 4), throwsA(isA<ExportException>()));
    // An RGB (colour type 2) PNG has no alpha channel.
    final rgb = _png(8, 4);
    rgb[25] = 2;
    final crc = PngCodec.crc32(rgb, 12, 29);
    ByteData.sublistView(rgb).setUint32(29, crc);
    expect(() => ExportVerifier.verify(rgb, o, 8, 4), throwsA(isA<ExportException>()));
    expect(() => ExportVerifier.verify(good, const ExportOptions(format: ExportFormat.jpeg), 8, 4), throwsA(isA<ExportException>()));
  });

  test('timelapse: only meaningful events capture, burst coalesces', () {
    final p = TimelapsePlanner(const TimelapseSettings(minGapMs: 1000));
    expect(p.onEvent(TimelapseEvent.undo, 0), isFalse);
    expect(p.onEvent(TimelapseEvent.strokeEnd, 0), isTrue);
    expect(p.onEvent(TimelapseEvent.strokeEnd, 100), isFalse);
    expect(p.onEvent(TimelapseEvent.strokeEnd, 1200), isTrue);
  });

  test('timelapse thinning keeps first and last', () {
    final k = TimelapsePlanner.thin(100, 5);
    expect(k.first, 0);
    expect(k.last, 99);
    expect(k.length, 5);
  });

  test('timelapse GIF is built and readable', () {
    final gif = TimelapseExporter.buildGif([_png(8, 8), _png(8, 8), _png(8, 8)]);
    final i = ImageSniffer.sniff(gif)!;
    expect((i.width, i.height), (8, 8));
  });
}
