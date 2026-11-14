import 'dart:convert';
import 'dart:typed_data';

import '../domain/animation_model.dart';
import '../domain/image_codecs.dart';
import 'anim_renderer.dart';

class ExportReport {
  const ExportReport({required this.files, required this.width, required this.height, required this.frames, required this.verified, this.note});
  final List<String> files;
  final int width, height, frames;
  final bool verified;
  final String? note;
}

/// Real frame-based exports. MP4 is intentionally absent: no platform
/// encoder has been verified in this project, so it is not offered.
abstract final class AnimationExporter {
  /// RAM budget for holding every GIF frame while the shared palette is built.
  static const maxGifBytes = 192 * 1024 * 1024;

  /// Scale (<=1) needed to keep all GIF frames inside [maxGifBytes].
  static double gifScale(AnimationDocument doc) {
    final bytes = doc.frames.length * doc.width * doc.height * 4;
    if (bytes <= maxGifBytes) return 1;
    return (maxGifBytes / bytes).clamp(0.1, 1.0).toDouble() * 0.98;
  }

  /// Encodes a GIF with one image per animation frame, delays from each
  /// frame's hold, then re-reads the bytes and checks size, frame count,
  /// frame order and timing before returning.
  static Future<(Uint8List, ExportReport)> exportGif(AnimationDocument doc, {bool useRange = false, double? scale, AnimImageLookup? images}) async {
    final s = scale ?? gifScale(doc);
    final (w, h) = AnimRenderer.scaledSize(doc, s);
    final from = useRange ? doc.rangeStart : 0, to = useRange ? doc.rangeEnd : doc.frames.length - 1;
    final frames = <GifFrameData>[];
    var cum = 0;
    for (var i = from; i <= to; i++) {
      final f = doc.frames[i];
      final rgba = await AnimRenderer.renderRgba(doc, f, scale: s, images: images);
      final before = (cum * 100 / doc.fps).round();
      cum += f.hold;
      final after = (cum * 100 / doc.fps).round();
      frames.add(GifFrameData(rgba, after - before));
    }
    final bytes = GifCodec.encode(w, h, frames, loop: doc.loop);
    final info = GifCodec.inspect(bytes);
    final ok = info.width == w && info.height == h && info.frameCount == frames.length &&
        [for (var i = 0; i < frames.length; i++) frames[i].delayCs < 2 ? 2 : frames[i].delayCs].toString() == info.delaysCs.toString() &&
        info.loops == doc.loop;
    if (!ok) throw const AnimationException('The GIF failed its own check (size, frame count or timing differ). It was not saved.');
    return (
      bytes,
      ExportReport(
        files: const ['animation.gif'],
        width: w,
        height: h,
        frames: frames.length,
        verified: true,
        note: s < 1 ? 'Scaled to ${(s * 100).round()}% to stay within the memory budget.' : 'GIF delays are in 1/100 s, so timing is rounded.',
      ),
    );
  }

  /// PNG sequence at the animation's frame rate: held frames are repeated
  /// so playback timing is preserved. [write] stores one file; each PNG is
  /// re-read to verify its size. Also writes `timing.json`.
  static Future<ExportReport> exportPngSequence(
    AnimationDocument doc,
    Future<void> Function(String fileName, Uint8List bytes) write, {
    bool useRange = false,
    AnimImageLookup? images,
  }) async {
    final ticks = doc.tickSequence(useRange: useRange);
    final names = <String>[];
    final cache = <int, Uint8List>{};
    for (var n = 0; n < ticks.length; n++) {
      final idx = ticks[n];
      final png = cache.putIfAbsent(idx, () => Uint8List(0));
      Uint8List data = png;
      if (png.isEmpty) {
        final rgba = await AnimRenderer.renderRgba(doc, doc.frames[idx], images: images);
        data = PngCodec.encode(doc.width, doc.height, rgba);
        // Keep only the most recent PNG cached (held frames repeat back to back).
        cache
          ..clear()
          ..[idx] = data;
      }
      final (w, h) = PngCodec.readSize(data);
      if (w != doc.width || h != doc.height) throw const AnimationException('A PNG frame has the wrong size. Export stopped.');
      final name = 'frame_${(n + 1).toString().padLeft(4, '0')}.png';
      await write(name, data);
      names.add(name);
    }
    final timing = jsonEncode({'fps': doc.fps, 'width': doc.width, 'height': doc.height, 'frames': names.length, 'sourceFrames': ticks});
    await write('timing.json', Uint8List.fromList(utf8.encode(timing)));
    return ExportReport(files: [...names, 'timing.json'], width: doc.width, height: doc.height, frames: names.length, verified: true);
  }
}
