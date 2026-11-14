import 'dart:math' as math;
import 'dart:typed_data';

import '../../animation/domain/image_codecs.dart';

/// Timelapse is built from MEANINGFUL drawing events, not from a timer or
/// from every pointer sample: a stroke that ended, a fill, a transform that
/// was committed, a layer added... Undo/redo, selection changes and view
/// changes never create frames.
enum TimelapseEvent {
  strokeEnd(true),
  fill(true),
  shapeCommit(true),
  transformCommit(true),
  filterApply(true),
  layerAdd(true),
  layerDelete(true),
  imageImport(true),
  maskEdit(true),
  undo(false),
  redo(false),
  selection(false),
  view(false);

  const TimelapseEvent(this.meaningful);
  final bool meaningful;

  /// Maps a history label from the controller to an event.
  static TimelapseEvent fromLabel(String label) {
    final l = label.toLowerCase();
    if (l.contains('stroke') || l.contains('draw') || l.contains('brush') || l.contains('erase')) return strokeEnd;
    if (l.contains('fill') || l.contains('gradient')) return fill;
    if (l.contains('shape')) return shapeCommit;
    if (l.contains('transform') || l.contains('move') || l.contains('flip') || l.contains('rotate')) return transformCommit;
    if (l.contains('filter') || l.contains('adjust')) return filterApply;
    if (l.contains('import') || l.contains('image')) return imageImport;
    if (l.contains('mask')) return maskEdit;
    if (l.contains('delete') || l.contains('remove')) return layerDelete;
    if (l.contains('layer') || l.contains('group')) return layerAdd;
    return strokeEnd;
  }
}

class TimelapseSettings {
  const TimelapseSettings({
    this.enabled = true,
    this.maxFrames = 240,
    this.maxSide = 640,
    this.minGapMs = 1500,
    this.minEventsBetween = 1,
  });
  final bool enabled;
  final int maxFrames, maxSide, minGapMs, minEventsBetween;
}

class TimelapsePlanner {
  TimelapsePlanner([this.settings = const TimelapseSettings()]) : _gap = settings.minGapMs;
  final TimelapseSettings settings;

  int _gap;
  int _lastCaptureMs = -1 << 30;
  int _pending = 0;
  int frames = 0;

  /// Call for every event. Returns true when a frame should be captured now.
  /// Events inside the minimum gap are coalesced and picked up by the next
  /// capture, so a burst of quick strokes becomes one frame.
  bool onEvent(TimelapseEvent e, int nowMs) {
    if (!settings.enabled || !e.meaningful) return false;
    _pending++;
    if (_pending < settings.minEventsBetween) return false;
    if (nowMs - _lastCaptureMs < _gap) return false;
    _lastCaptureMs = nowMs;
    _pending = 0;
    frames++;
    return true;
  }

  /// True when [frames] reached the cap and the store should thin itself.
  bool get needsThinning => frames >= settings.maxFrames;

  /// After thinning to half the frames, capture half as often.
  void noteThinned(int remaining) {
    frames = remaining;
    _gap = math.min(_gap * 2, 60000);
  }

  /// Indices to keep when thinning [count] frames to [target]: evenly spread,
  /// always including the first and the last.
  static List<int> thin(int count, int target) {
    if (target >= count) return [for (var i = 0; i < count; i++) i];
    if (target < 2) return count > 0 ? [count - 1] : const [];
    return [for (var i = 0; i < target; i++) ((i * (count - 1)) / (target - 1)).round()];
  }

  /// Frame size capped at [maxSide] on the longest side, even numbers.
  static (int, int) frameSize(int docW, int docH, int maxSide) {
    final k = math.min(1.0, maxSide / math.max(docW, docH));
    int ev(double v) => math.max(2, (v.round() ~/ 2) * 2);
    return (ev(docW * k), ev(docH * k));
  }
}

class TimelapseVideoPlan {
  const TimelapseVideoPlan({required this.frameDelayCs, required this.lastHoldCs});
  final int frameDelayCs, lastHoldCs;
}

abstract final class TimelapseExporter {
  static const maxGifBytes = 96 * 1024 * 1024;

  /// Delay per frame so the whole timelapse lasts about [targetSeconds].
  static TimelapseVideoPlan plan(int frames, {double targetSeconds = 12, double lastHoldSeconds = 1.5}) {
    if (frames < 1) return const TimelapseVideoPlan(frameDelayCs: 10, lastHoldCs: 150);
    final per = ((targetSeconds * 100) / frames).round().clamp(2, 200);
    return TimelapseVideoPlan(frameDelayCs: per, lastHoldCs: (lastHoldSeconds * 100).round());
  }

  /// Builds an animated GIF from PNG frames (all the same size) and verifies
  /// it by re-reading the file. MP4 is intentionally not offered.
  static Uint8List buildGif(List<Uint8List> pngFrames, {double targetSeconds = 12}) {
    if (pngFrames.length < 2) {
      throw const CodecException('A timelapse needs at least 2 captured steps.');
    }
    final (w, h) = PngCodec.readSize(pngFrames.first);
    final p = plan(pngFrames.length, targetSeconds: targetSeconds);
    if (w * h * pngFrames.length * 4 > 1536 * 1024 * 1024) {
      throw const CodecException('The timelapse is too large to encode on this device.');
    }
    final frames = <GifFrameData>[];
    for (var i = 0; i < pngFrames.length; i++) {
      final (fw, fh) = PngCodec.readSize(pngFrames[i]);
      if (fw != w || fh != h) throw const CodecException('Timelapse frames have different sizes.');
      frames.add(GifFrameData(PngCodec.decodeRgba(pngFrames[i]), i == pngFrames.length - 1 ? p.lastHoldCs : p.frameDelayCs));
    }
    final gif = GifCodec.encode(w, h, frames);
    final info = GifCodec.inspect(gif);
    if (info.width != w || info.height != h || info.delaysCs.length != frames.length) {
      throw const CodecException('The timelapse GIF failed verification.');
    }
    if (gif.length > maxGifBytes) throw const CodecException('The timelapse GIF is too large; use fewer frames.');
    return gif;
  }
}
