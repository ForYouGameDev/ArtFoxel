import 'dart:collection';
import 'dart:isolate';
import 'dart:math' as math;

/// Phase 7.5.9 — performance, capability and safeguard helpers. All pure
/// Dart and deterministic so they can be unit-tested; real hardware numbers
/// are supplied by the caller (nothing here claims measured device speed).

enum DeviceTier { low, mid, high }

class DeviceCapability {
  const DeviceCapability({required this.ramMb, required this.cores, this.gpuTextureMax = 4096});
  final int ramMb, cores, gpuTextureMax;

  DeviceTier get tier {
    if (ramMb < 3000 || cores <= 4) return DeviceTier.low;
    if (ramMb < 6000 || cores <= 6) return DeviceTier.mid;
    return DeviceTier.high;
  }
}

class PerformanceProfile {
  const PerformanceProfile({
    required this.tileSize,
    required this.maxCanvasPixels,
    required this.undoBudgetBytes,
    required this.previewScale,
    required this.maxLayers,
  });
  final int tileSize, maxCanvasPixels, undoBudgetBytes, maxLayers;
  final double previewScale;

  static PerformanceProfile forDevice(DeviceCapability d) {
    switch (d.tier) {
      case DeviceTier.low:
        return PerformanceProfile(
            tileSize: 256, maxCanvasPixels: math.min(16000000, d.gpuTextureMax * 2048),
            undoBudgetBytes: 64 * 1024 * 1024, previewScale: 0.5, maxLayers: 30);
      case DeviceTier.mid:
        return PerformanceProfile(
            tileSize: 256, maxCanvasPixels: math.min(36000000, d.gpuTextureMax * 4096),
            undoBudgetBytes: 192 * 1024 * 1024, previewScale: 0.75, maxLayers: 80);
      case DeviceTier.high:
        return PerformanceProfile(
            tileSize: 512, maxCanvasPixels: math.min(100000000, d.gpuTextureMax * 8192),
            undoBudgetBytes: 512 * 1024 * 1024, previewScale: 1.0, maxLayers: 200);
    }
  }
}

class GuardResult {
  const GuardResult(this.allowed, this.messages, this.estimatedBytes);
  final bool allowed;
  final List<String> messages;
  final int estimatedBytes;
}

class CanvasGuard {
  /// Estimates RGBA8 memory: layers + undo + one composite. Refuses if the
  /// canvas exceeds the profile; warns when it is within 80 %.
  static GuardResult check(int w, int h, int layers, PerformanceProfile p,
      {int budgetBytes = 0}) {
    final msgs = <String>[];
    if (w <= 0 || h <= 0) return const GuardResult(false, ['Invalid size'], 0);
    final px = w * h;
    final bytes = px * 4 * (layers + 1) + p.undoBudgetBytes;
    var ok = true;
    if (px > p.maxCanvasPixels) {
      ok = false;
      msgs.add('Canvas of $px px exceeds this device limit (${p.maxCanvasPixels} px).');
    } else if (px > p.maxCanvasPixels * 0.8) {
      msgs.add('Large canvas: expect slower redraws and fewer layers.');
    }
    if (layers > p.maxLayers) {
      ok = false;
      msgs.add('More than ${p.maxLayers} layers is not supported on this device.');
    }
    if (budgetBytes > 0 && bytes > budgetBytes) {
      ok = false;
      msgs.add('Estimated memory ${(bytes / 1048576).round()} MB exceeds the budget.');
    }
    return GuardResult(ok, msgs, bytes);
  }
}

class TileRect {
  const TileRect(this.l, this.t, this.r, this.b);
  final int l, t, r, b; // exclusive right/bottom
  int get width => r - l;
  int get height => b - t;
  bool get isEmpty => r <= l || b <= t;
  TileRect union(TileRect o) =>
      TileRect(math.min(l, o.l), math.min(t, o.t), math.max(r, o.r), math.max(b, o.b));
}

/// Tracks dirty regions as a set of tile indices, so only changed tiles are
/// re-rendered or re-encoded.
class TileGrid {
  TileGrid(this.width, this.height, this.tileSize)
      : cols = (width / tileSize).ceil(),
        rows = (height / tileSize).ceil();
  final int width, height, tileSize, cols, rows;
  final Set<int> _dirty = {};

  int get dirtyCount => _dirty.length;
  int get totalTiles => cols * rows;
  bool get isClean => _dirty.isEmpty;

  void markRect(int l, int t, int r, int b) {
    final x0 = (l.clamp(0, width) ~/ tileSize), y0 = (t.clamp(0, height) ~/ tileSize);
    final x1 = ((r.clamp(0, width) - 1).clamp(0, width) ~/ tileSize);
    final y1 = ((b.clamp(0, height) - 1).clamp(0, height) ~/ tileSize);
    if (r <= l || b <= t) return;
    for (var y = y0; y <= y1 && y < rows; y++) {
      for (var x = x0; x <= x1 && x < cols; x++) {
        _dirty.add(y * cols + x);
      }
    }
  }

  void markAll() {
    for (var i = 0; i < totalTiles; i++) {
      _dirty.add(i);
    }
  }

  TileRect rectOf(int index) {
    final x = index % cols, y = index ~/ cols;
    return TileRect(x * tileSize, y * tileSize,
        math.min(width, (x + 1) * tileSize), math.min(height, (y + 1) * tileSize));
  }

  /// Returns the dirty tiles and clears them.
  List<TileRect> takeDirty() {
    final list = _dirty.toList()..sort();
    _dirty.clear();
    return [for (final i in list) rectOf(i)];
  }

  /// Bounding box of all dirty tiles (without clearing).
  TileRect? dirtyBounds() {
    TileRect? u;
    for (final i in _dirty) {
      final r = rectOf(i);
      u = u == null ? r : u.union(r);
    }
    return u;
  }
}

/// Batches stroke points so rendering happens once per frame, not per event.
class StrokeBatcher<T> {
  StrokeBatcher({this.maxBatch = 64});
  final int maxBatch;
  final List<T> _pending = [];
  void add(T p) => _pending.add(p);
  bool get shouldFlush => _pending.length >= maxBatch;
  List<T> flush() {
    final out = List<T>.of(_pending);
    _pending.clear();
    return out;
  }
  int get pending => _pending.length;
}

/// Byte-budgeted LRU cache (render caches, thumbnails).
class ByteLru<K> {
  ByteLru(this.budgetBytes);
  final int budgetBytes;
  final LinkedHashMap<K, (Object, int)> _m = LinkedHashMap();
  int _bytes = 0;
  int get bytes => _bytes;
  int get length => _m.length;

  T? get<T>(K k) {
    final e = _m.remove(k);
    if (e == null) return null;
    _m[k] = e;
    return e.$1 as T;
  }

  void put(K k, Object v, int size) {
    final old = _m.remove(k);
    if (old != null) _bytes -= old.$2;
    if (size > budgetBytes) return; // never cache what cannot fit
    _m[k] = (v, size);
    _bytes += size;
    while (_bytes > budgetBytes && _m.isNotEmpty) {
      final first = _m.keys.first;
      _bytes -= _m.remove(first)!.$2;
    }
  }

  void clear() {
    _m.clear();
    _bytes = 0;
  }
}

/// Undo memory budget: trims oldest entries when total size is exceeded.
class UndoBudget {
  UndoBudget(this.budgetBytes);
  final int budgetBytes;
  final List<int> _sizes = [];
  int _total = 0;
  int get total => _total;
  int get entries => _sizes.length;

  /// Records an entry; returns how many oldest entries must be dropped.
  int record(int size) {
    _sizes.add(size);
    _total += size;
    var drop = 0;
    while (_total > budgetBytes && _sizes.length > 1) {
      _total -= _sizes.removeAt(0);
      drop++;
    }
    return drop;
  }

  void pop() {
    if (_sizes.isNotEmpty) _total -= _sizes.removeLast();
  }
}

/// Frame-time profiler + adaptive preview resolution.
class FrameProfiler {
  FrameProfiler({this.window = 120, this.budgetMs = 16.7});
  final int window;
  final double budgetMs;
  final List<double> _ms = [];

  void record(double ms) {
    _ms.add(ms);
    if (_ms.length > window) _ms.removeAt(0);
  }

  int get count => _ms.length;
  double get mean => _ms.isEmpty ? 0 : _ms.reduce((a, b) => a + b) / _ms.length;
  double percentile(double p) {
    if (_ms.isEmpty) return 0;
    final s = List<double>.of(_ms)..sort();
    return s[((s.length - 1) * p).round()];
  }
  double get missRate => _ms.isEmpty ? 0 : _ms.where((m) => m > budgetMs).length / _ms.length;
}

class AdaptivePreview {
  AdaptivePreview({this.scale = 1.0, this.minScale = 0.25, this.maxScale = 1.0});
  double scale;
  final double minScale, maxScale;

  /// Lowers resolution while the pen is down and frames are slow, and
  /// recovers gradually. Full resolution is always restored on pen-up.
  double update(double frameMs, {double budgetMs = 16.7}) {
    if (frameMs > budgetMs * 1.2) {
      scale = math.max(minScale, scale * 0.85);
    } else if (frameMs < budgetMs * 0.7) {
      scale = math.min(maxScale, scale * 1.05);
    }
    return scale;
  }

  void penUp() => scale = maxScale;
}

/// Runs heavy pure-Dart work off the UI isolate. [fn] must be a closure
/// that only captures sendable data (typed lists, numbers, strings).
Future<R> runInBackground<R>(R Function() fn) => Isolate.run(fn);
