import 'dart:io';
import 'dart:typed_data';

import '../domain/timelapse.dart';

/// Small PNG frames of one project's drawing history, kept on disk in
/// `<project>/timelapse/` as `000001.png`, `000002.png`, ... Only frames
/// captured for meaningful drawing events are stored (see [TimelapsePlanner]).
class TimelapseStore {
  TimelapseStore(this.dir);
  final Directory dir;

  static final RegExp _name = RegExp(r'^\d{6}\.png$');

  Future<List<File>> files() async {
    if (!await dir.exists()) return const [];
    final out = <File>[
      await for (final e in dir.list())
        if (e is File && _name.hasMatch(e.uri.pathSegments.last)) e,
    ];
    out.sort((a, b) => a.path.compareTo(b.path));
    return out;
  }

  Future<int> count() async => (await files()).length;

  Future<void> add(Uint8List png) async {
    await dir.create(recursive: true);
    final existing = await files();
    final next = existing.isEmpty ? 1 : int.parse(existing.last.uri.pathSegments.last.substring(0, 6)) + 1;
    final f = File('${dir.path}/${next.toString().padLeft(6, '0')}.png');
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsBytes(png, flush: true);
    await tmp.rename(f.path);
  }

  /// Keeps [target] evenly spread frames (first and last always kept) and
  /// renumbers them. Returns how many remain.
  Future<int> thin(int target) async {
    final all = await files();
    final keep = TimelapsePlanner.thin(all.length, target).toSet();
    for (var i = 0; i < all.length; i++) {
      if (!keep.contains(i)) await all[i].delete();
    }
    final left = await files();
    // Renumber through temporary names so nothing is overwritten.
    for (var i = 0; i < left.length; i++) {
      await left[i].rename('${dir.path}/t${i.toString().padLeft(6, '0')}.tmpf');
    }
    var n = 1;
    final tmp = [
      await for (final e in dir.list())
        if (e is File && e.path.endsWith('.tmpf')) e,
    ]..sort((a, b) => a.path.compareTo(b.path));
    for (final f in tmp) {
      await f.rename('${dir.path}/${(n++).toString().padLeft(6, '0')}.png');
    }
    return left.length;
  }

  Future<List<Uint8List>> readAll() async => [for (final f in await files()) await f.readAsBytes()];

  Future<void> clear() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  }
}

/// Drives a [TimelapsePlanner] and a [TimelapseStore]. [capture] renders the
/// current artwork as a small PNG (or null when it cannot).
class TimelapseRecorder {
  TimelapseRecorder(this.store, this.capture, {TimelapseSettings settings = const TimelapseSettings()})
      : planner = TimelapsePlanner(settings),
        _settings = settings;

  final TimelapseStore store;
  final Future<Uint8List?> Function(int maxSide) capture;
  final TimelapsePlanner planner;
  final TimelapseSettings _settings;
  bool _busy = false;
  bool _seeded = false;

  /// Call with each history label. Never blocks drawing: a capture already in
  /// progress simply drops the new request (the event is picked up by the next).
  void onHistoryLabel(String label) {
    final e = TimelapseEvent.fromLabel(label);
    if (!_seeded) {
      _seeded = true;
      store.count().then((c) => planner.frames = c);
    }
    if (_busy || !planner.onEvent(e, DateTime.now().millisecondsSinceEpoch)) return;
    _busy = true;
    capture(_settings.maxSide).then((png) async {
      if (png != null) await store.add(png);
      if (planner.needsThinning) {
        final left = await store.thin(_settings.maxFrames ~/ 2);
        planner.noteThinned(left);
      }
    }).catchError((_) {}).whenComplete(() => _busy = false);
  }
}
