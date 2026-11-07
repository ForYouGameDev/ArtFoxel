import 'dart:async';
import 'dart:isolate';

import 'filter_adjust.dart';
import 'filter_core.dart';
import 'filter_effects.dart';

export 'filter_core.dart';

/// Catalogue of every filter the app really implements.
///
/// Deliberately absent (documented in the status doc): lens flare, angular /
/// reflected gradients, GPU adjustment layers that affect everything beneath.
abstract final class FilterRegistry {
  static final List<FilterSpec> all = [...adjustFilters, ...effectFilters];
  static final Map<String, FilterSpec> _byId = {for (final f in all) f.id: f};

  static FilterSpec? byId(String id) => _byId[id];

  static List<FilterSpec> inCategory(FilterCategory c) =>
      [for (final f in all) if (f.category == c) f];

  static FilterOp defaultOp(String id) {
    final spec = _byId[id];
    if (spec == null) throw ArgumentError('Unknown filter "$id".');
    return FilterOp(id, spec.defaults());
  }
}

/// Runs filters synchronously (used inside isolates and in tests).
abstract final class FilterEngine {
  /// Applies one op. Large images are processed in horizontal bands when the
  /// filter is local (declares a margin), which bounds scratch memory.
  static FilterImage applyOp(FilterImage src, FilterOp op, [FilterContext? ctx]) {
    ctx ??= FilterContext();
    FilterBudget.check(src.width, src.height);
    final spec = FilterRegistry.byId(op.id);
    if (spec == null) throw ArgumentError('Unknown filter "${op.id}".');
    final p = spec.normalize(op.params);
    final marginFn = spec.margin;
    if (marginFn != null && src.width * src.height > FilterBudget.tilePixels) {
      return _banded(src, spec, p, marginFn(p), ctx);
    }
    return spec.apply(src, p, ctx);
  }

  static FilterImage _banded(
      FilterImage src, FilterSpec spec, Map<String, double> p, int margin, FilterContext ctx) {
    final out = FilterImage(src.width, src.height);
    final bandRows = (FilterBudget.tilePixels ~/ src.width).clamp(32, src.height);
    for (var y = 0; y < src.height; y += bandRows) {
      ctx.check();
      final y1 = (y + bandRows).clamp(0, src.height);
      final a = (y - margin).clamp(0, src.height);
      final b = (y1 + margin).clamp(0, src.height);
      final band = src.rows(a, b);
      final res = spec.apply(band, p, FilterContext(isCancelled: ctx.isCancelled));
      final from = (y - a) * src.width * 4;
      final to = from + (y1 - y) * src.width * 4;
      out.rgba.setRange(y * src.width * 4, y1 * src.width * 4, res.rgba, from);
      ctx.progress(y1 / src.height);
      // `to` kept for clarity of the copied span.
      assert(to - from == (y1 - y) * src.width * 4);
    }
    return out;
  }

  /// Applies every enabled op in order. The input is never modified.
  static FilterImage applyStack(FilterImage src, List<FilterOp> ops, [FilterContext? ctx]) {
    ctx ??= FilterContext();
    final active = [for (final o in ops) if (o.enabled) o];
    var cur = src;
    for (var i = 0; i < active.length; i++) {
      cur = applyOp(
        cur,
        active[i],
        FilterContext(
          isCancelled: ctx.isCancelled,
          onProgress: (f) => ctx!.progress((i + f) / active.length),
        ),
      );
    }
    return identical(cur, src) ? src.clone() : cur;
  }

  /// Nearest-neighbour-free box downscale for fast previews.
  static FilterImage downscale(FilterImage src, int maxSide) {
    final longest = src.width > src.height ? src.width : src.height;
    if (longest <= maxSide) return src;
    final k = maxSide / longest;
    final w = (src.width * k).round().clamp(1, maxSide);
    final h = (src.height * k).round().clamp(1, maxSide);
    final out = FilterImage(w, h);
    for (var y = 0; y < h; y++) {
      final sy0 = (y / k).floor(), sy1 = ((y + 1) / k).ceil().clamp(sy0 + 1, src.height);
      for (var x = 0; x < w; x++) {
        final sx0 = (x / k).floor(), sx1 = ((x + 1) / k).ceil().clamp(sx0 + 1, src.width);
        var r = 0.0, g = 0.0, b = 0.0, a = 0.0;
        var n = 0;
        for (var yy = sy0; yy < sy1; yy++) {
          for (var xx = sx0; xx < sx1; xx++) {
            final i = (yy * src.width + xx) * 4;
            final al = src.rgba[i + 3] / 255;
            r += src.rgba[i] * al;
            g += src.rgba[i + 1] * al;
            b += src.rgba[i + 2] * al;
            a += al;
            n++;
          }
        }
        final o = (y * w + x) * 4;
        if (a > 0) {
          out.rgba[o] = toByte(r / a);
          out.rgba[o + 1] = toByte(g / a);
          out.rgba[o + 2] = toByte(b / a);
          out.rgba[o + 3] = toByte(a / n * 255);
        }
      }
    }
    return out;
  }
}

// ---------------------------------------------------------------------------
// Background runner
// ---------------------------------------------------------------------------

class _Job {
  _Job(this.send, this.w, this.h, this.data, this.ops);
  final SendPort send;
  final int w, h;
  final TransferableTypedData data;
  final List<Map<String, Object?>> ops;
}

void _entry(_Job job) {
  try {
    final src = FilterImage(job.w, job.h, job.data.materialize().asUint8List());
    final ops = [
      for (final o in job.ops)
        FilterOp.fromJson(o, FilterRegistry.byId),
    ];
    final out = FilterEngine.applyStack(
      src,
      ops,
      FilterContext(onProgress: (f) => job.send.send(f)),
    );
    job.send.send(TransferableTypedData.fromList([out.rgba]));
  } catch (e) {
    job.send.send('error:$e');
  }
}

/// A running background filter job. [cancel] kills the worker isolate.
class FilterJob {
  FilterJob._(this._isolate, this._port, this._completer, this.progress);
  final Isolate _isolate;
  final ReceivePort _port;
  final Completer<FilterImage> _completer;
  final StreamController<double> progress;

  Future<FilterImage> get result => _completer.future;
  bool get isDone => _completer.isCompleted;

  void cancel() {
    if (_completer.isCompleted) return;
    _isolate.kill(priority: Isolate.immediate);
    _port.close();
    progress.close();
    _completer.completeError(const FilterCancelled());
  }
}

abstract final class FilterRunner {
  /// Starts [ops] on [src] in a separate isolate. Progress is 0..1.
  static Future<FilterJob> start(FilterImage src, List<FilterOp> ops) async {
    FilterBudget.check(src.width, src.height);
    final port = ReceivePort();
    final completer = Completer<FilterImage>();
    final progress = StreamController<double>.broadcast();
    final isolate = await Isolate.spawn(
      _entry,
      _Job(port.sendPort, src.width, src.height,
          TransferableTypedData.fromList([src.rgba]), [for (final o in ops) o.toJson()]),
    );
    final job = FilterJob._(isolate, port, completer, progress);
    port.listen((m) {
      if (m is double) {
        if (!progress.isClosed) progress.add(m);
      } else if (m is TransferableTypedData) {
        if (!completer.isCompleted) {
          completer.complete(FilterImage(src.width, src.height, m.materialize().asUint8List()));
        }
        port.close();
        progress.close();
        isolate.kill();
      } else if (m is String) {
        if (!completer.isCompleted) completer.completeError(StateError(m));
        port.close();
        progress.close();
        isolate.kill();
      }
    });
    return job;
  }
}

// ---------------------------------------------------------------------------
// Presets & history
// ---------------------------------------------------------------------------

abstract final class FilterPresets {
  static List<FilterOp> _ops(List<(String, Map<String, double>)> l) =>
      [for (final e in l) FilterOp(e.$1, FilterRegistry.byId(e.$1)!.normalize(e.$2))];

  static final List<FilterPreset> builtIn = [
    FilterPreset('Warm vintage', _ops([
      ('temperature', {'amount': 35}),
      ('contrast', {'amount': -10}),
      ('vignette', {'amount': 35}),
      ('grain', {'amount': 20}),
    ]), builtIn: true),
    FilterPreset('Cool fade', _ops([
      ('temperature', {'amount': -30}),
      ('saturation', {'amount': -20}),
      ('brightness', {'amount': 8}),
    ]), builtIn: true),
    FilterPreset('Punchy', _ops([
      ('contrast', {'amount': 25}),
      ('vibrance', {'amount': 35}),
      ('unsharp', {'radius': 2, 'amount': 80}),
    ]), builtIn: true),
    FilterPreset('Noir', _ops([
      ('grayscale', {}),
      ('contrast', {'amount': 35}),
      ('vignette', {'amount': 55}),
    ]), builtIn: true),
    FilterPreset('Comic book', _ops([
      ('saturation', {'amount': 20}),
      ('comic', {'levels': 4, 'ink': 5}),
    ]), builtIn: true),
    FilterPreset('Dreamy glow', _ops([
      ('glow', {'radius': 14, 'amount': 55}),
      ('saturation', {'amount': 10}),
    ]), builtIn: true),
  ];
}

/// Session-only record of what was applied, newest last (capped).
class FilterHistory {
  FilterHistory({this.max = 50});
  final int max;
  final List<String> _entries = [];
  List<String> get entries => List.unmodifiable(_entries);

  void add(String label) {
    _entries.add(label);
    if (_entries.length > max) _entries.removeAt(0);
  }

  void clear() => _entries.clear();
}

/// Converts a stack to / from JSON for persistence on a layer.
abstract final class FilterStackCodec {
  static List<Map<String, Object?>> encode(List<FilterOp> ops) =>
      [for (final o in ops) o.toJson()];

  static List<FilterOp> decode(Object? json) {
    if (json == null) return const [];
    if (json is! List) throw const FormatException('Filter stack must be a list.');
    if (json.length > 64) throw const FormatException('Too many filters.');
    return [for (final e in json) FilterOp.fromJson(e, FilterRegistry.byId)];
  }
}
