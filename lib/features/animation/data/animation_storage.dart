import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../domain/animation_model.dart';

/// `<root>/<projectId>/animation.json` (atomic write + backup) and an
/// `export/` folder.
class AnimationStorage {
  AnimationStorage(this.root);
  final Directory root;
  static final RegExp _id = RegExp(r'^[A-Za-z0-9_-]{1,80}$');

  Directory dir(String id) {
    if (!_id.hasMatch(id)) throw ArgumentError.value(id, 'projectId');
    return Directory('${root.path}/$id');
  }

  File _main(String id) => File('${dir(id).path}/animation.json');

  Future<void> save(String id, AnimationDocument doc) async {
    await dir(id).create(recursive: true);
    final tmp = File('${_main(id).path}.tmp');
    await tmp.writeAsString(jsonEncode(doc.toJson()), flush: true);
    final main = _main(id);
    if (await main.exists()) await main.copy('${main.path}.bak');
    await tmp.rename(main.path);
  }

  Future<AnimationDocument?> load(String id) async {
    final main = _main(id);
    if (!await main.exists()) return null;
    for (final f in [main, File('${main.path}.bak')]) {
      try {
        if (await f.exists()) return AnimationDocument.fromJson(jsonDecode(await f.readAsString()));
      } on Object {
        continue;
      }
    }
    throw const AnimationException('The animation file is damaged and no backup could be read.');
  }

  Future<Directory> exportDir(String id, String sub) async {
    if (!RegExp(r'^[A-Za-z0-9_-]{1,60}$').hasMatch(sub)) throw ArgumentError.value(sub, 'sub');
    final d = Directory('${dir(id).path}/export/$sub');
    await d.create(recursive: true);
    return d;
  }

  Future<File> writeFile(Directory d, String name, Uint8List bytes) async {
    if (!RegExp(r'^[A-Za-z0-9_.-]{1,80}$').hasMatch(name) || name.contains('..')) throw ArgumentError.value(name, 'name');
    final f = File('${d.path}/$name');
    await f.writeAsBytes(bytes, flush: true);
    return f;
  }

  // ---- imported picture assets (PNG files; never inside animation.json) ----

  static final RegExp _assetId = RegExp(r'^[A-Za-z0-9_-]{1,60}$');

  File _asset(String projectId, String assetId) {
    if (!_assetId.hasMatch(assetId)) throw ArgumentError.value(assetId, 'assetId');
    return File('${dir(projectId).path}/assets/$assetId.png');
  }

  Future<void> writeAsset(String projectId, String assetId, Uint8List png) async {
    final f = _asset(projectId, assetId);
    await f.parent.create(recursive: true);
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsBytes(png, flush: true);
    await tmp.rename(f.path);
  }

  Future<Uint8List?> readAsset(String projectId, String assetId) async {
    final f = _asset(projectId, assetId);
    return await f.exists() ? f.readAsBytes() : null;
  }

  Future<void> deleteAssets(String projectId, Iterable<String> ids) async {
    for (final id in ids) {
      final f = _asset(projectId, id);
      if (await f.exists()) await f.delete();
    }
  }
}
