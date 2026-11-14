import 'dart:typed_data';

/// Phase 7.5.7 — project checkpoints, separate from undo.
/// Snapshots are sets of named byte blobs (layer pixels, metadata) split
/// into fixed chunks and de-duplicated by content, so a checkpoint after a
/// small edit only stores the chunks that changed.

class CheckpointException implements Exception {
  CheckpointException(this.message);
  final String message;
  @override
  String toString() => 'CheckpointException: $message';
}

class ChunkStore {
  ChunkStore({this.chunkSize = 64 * 1024});
  final int chunkSize;
  final Map<int, List<_Chunk>> _byHash = {};
  int _nextId = 1;
  final Map<int, _Chunk> _byId = {};

  int get storedBytes => _byId.values.fold(0, (a, c) => a + c.bytes.length);
  int get chunkCount => _byId.length;

  static int _fnv(Uint8List b) {
    var h = 0x811c9dc5;
    for (final v in b) {
      h ^= v;
      h = (h * 0x01000193) & 0xFFFFFFFF;
    }
    return h;
  }

  /// Stores [bytes] (copy) or reuses an identical chunk. Hash collisions are
  /// resolved by comparing bytes, so a collision can never alias data.
  int put(Uint8List bytes) {
    final h = _fnv(bytes);
    final bucket = _byHash.putIfAbsent(h, () => []);
    for (final c in bucket) {
      if (_equal(c.bytes, bytes)) {
        c.refs++;
        return c.id;
      }
    }
    final c = _Chunk(_nextId++, Uint8List.fromList(bytes))..refs = 1;
    bucket.add(c);
    _byId[c.id] = c;
    return c.id;
  }

  Uint8List get(int id) {
    final c = _byId[id];
    if (c == null) throw CheckpointException('missing chunk $id');
    return c.bytes;
  }

  void retain(int id) => _byId[id]?.refs++;

  void release(int id) {
    final c = _byId[id];
    if (c == null) return;
    c.refs--;
    if (c.refs <= 0) {
      _byId.remove(id);
      _byHash.forEach((_, l) => l.remove(c));
    }
  }

  static bool _equal(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

class _Chunk {
  _Chunk(this.id, this.bytes);
  final int id;
  final Uint8List bytes;
  int refs = 0;
}

class SnapshotBlob {
  SnapshotBlob(this.length, this.chunkIds);
  final int length;
  final List<int> chunkIds;
}

class Checkpoint {
  Checkpoint({
    required this.id,
    required this.name,
    required this.auto,
    required this.createdAt,
    required this.blobs,
    this.note = '',
    this.preview,
  });
  final int id;
  String name;
  final bool auto;
  final DateTime createdAt;
  final Map<String, SnapshotBlob> blobs;
  String note;
  final Uint8List? preview; // small PNG thumbnail supplied by the caller
}

class CheckpointDiff {
  CheckpointDiff(this.added, this.removed, this.changed, this.unchanged, this.changedChunks);
  final List<String> added, removed, changed, unchanged;
  final int changedChunks;
  bool get identical => added.isEmpty && removed.isEmpty && changed.isEmpty;
}

class CheckpointManager {
  CheckpointManager({
    ChunkStore? store,
    this.maxAuto = 10,
    this.maxTotal = 100,
    this.autoInterval = const Duration(minutes: 10),
    this.byteBudget = 512 * 1024 * 1024,
  }) : store = store ?? ChunkStore();

  final ChunkStore store;
  final int maxAuto, maxTotal;
  final Duration autoInterval;
  final int byteBudget;
  final List<Checkpoint> _list = [];
  int _nextId = 1;

  List<Checkpoint> get all => List.unmodifiable(_list);

  Checkpoint create(Map<String, Uint8List> data,
      {required String name, bool auto = false, String note = '', Uint8List? preview, DateTime? now}) {
    if (_list.where((c) => !c.auto).length >= maxTotal && !auto) {
      throw CheckpointException('checkpoint limit reached ($maxTotal)');
    }
    final blobs = <String, SnapshotBlob>{};
    for (final e in data.entries) {
      final ids = <int>[];
      for (var o = 0; o < e.value.length; o += store.chunkSize) {
        final end = (o + store.chunkSize).clamp(0, e.value.length);
        ids.add(store.put(Uint8List.sublistView(e.value, o, end)));
      }
      blobs[e.key] = SnapshotBlob(e.value.length, ids);
    }
    final cp = Checkpoint(
        id: _nextId++, name: name, auto: auto, createdAt: now ?? DateTime.now(),
        blobs: blobs, note: note, preview: preview);
    _list.add(cp);
    if (auto) _trimAuto();
    _enforceBudget();
    return cp;
  }

  /// Auto checkpoint policy: only when [autoInterval] passed and something
  /// changed since the newest checkpoint.
  bool shouldAuto(DateTime now, {required bool dirty}) {
    if (!dirty) return false;
    if (_list.isEmpty) return true;
    return now.difference(_list.last.createdAt) >= autoInterval;
  }

  void _trimAuto() {
    final autos = _list.where((c) => c.auto).toList();
    while (autos.length > maxAuto) {
      remove(autos.removeAt(0).id);
    }
  }

  /// Drops the oldest automatic checkpoints first if over budget.
  void _enforceBudget() {
    while (store.storedBytes > byteBudget) {
      Checkpoint? victim;
      for (final c in _list) {
        if (c.auto) {
          victim = c;
          break;
        }
      }
      if (victim == null) break;
      remove(victim.id);
    }
  }

  Checkpoint? byId(int id) {
    for (final c in _list) {
      if (c.id == id) return c;
    }
    return null;
  }

  void remove(int id) {
    final c = byId(id);
    if (c == null) return;
    for (final b in c.blobs.values) {
      for (final cid in b.chunkIds) {
        store.release(cid);
      }
    }
    _list.remove(c);
  }

  /// Rebuilds the exact bytes. Restoring never touches undo history.
  Map<String, Uint8List> restore(int id) {
    final c = byId(id);
    if (c == null) throw CheckpointException('no such checkpoint');
    final out = <String, Uint8List>{};
    for (final e in c.blobs.entries) {
      final b = Uint8List(e.value.length);
      var o = 0;
      for (final cid in e.value.chunkIds) {
        final chunk = store.get(cid);
        b.setRange(o, o + chunk.length, chunk);
        o += chunk.length;
      }
      if (o != e.value.length) throw CheckpointException('corrupt snapshot ${e.key}');
      out[e.key] = b;
    }
    return out;
  }

  /// Duplicates by sharing chunks (no byte copy).
  Checkpoint duplicate(int id, {String? name}) {
    final c = byId(id);
    if (c == null) throw CheckpointException('no such checkpoint');
    for (final b in c.blobs.values) {
      for (final cid in b.chunkIds) {
        store.retain(cid);
      }
    }
    final d = Checkpoint(
        id: _nextId++, name: name ?? '${c.name} copy', auto: false,
        createdAt: DateTime.now(),
        blobs: {for (final e in c.blobs.entries) e.key: SnapshotBlob(e.value.length, [...e.value.chunkIds])},
        note: c.note, preview: c.preview);
    _list.add(d);
    return d;
  }

  CheckpointDiff compare(int a, int b) {
    final x = byId(a), y = byId(b);
    if (x == null || y == null) throw CheckpointException('no such checkpoint');
    final added = <String>[], removed = <String>[], changed = <String>[], same = <String>[];
    var chunks = 0;
    for (final k in y.blobs.keys) {
      if (!x.blobs.containsKey(k)) added.add(k);
    }
    for (final k in x.blobs.keys) {
      final yb = y.blobs[k];
      if (yb == null) {
        removed.add(k);
        continue;
      }
      final xb = x.blobs[k]!;
      final n = xb.chunkIds.length > yb.chunkIds.length ? xb.chunkIds.length : yb.chunkIds.length;
      var diff = 0;
      for (var i = 0; i < n; i++) {
        final xi = i < xb.chunkIds.length ? xb.chunkIds[i] : -1;
        final yi = i < yb.chunkIds.length ? yb.chunkIds[i] : -2;
        if (xi != yi) diff++;
      }
      if (diff == 0 && xb.length == yb.length) {
        same.add(k);
      } else {
        changed.add(k);
        chunks += diff;
      }
    }
    return CheckpointDiff(added, removed, changed, same, chunks);
  }
}
