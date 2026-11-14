import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../domain/comic_model.dart';

/// Stores `<root>/<projectId>/comic.json` (atomic write, one backup) plus an
/// `export/` folder and imported fonts in `fonts/`.
class ComicStorage {
  ComicStorage(this.root);
  final Directory root;
  static final RegExp _id = RegExp(r'^[A-Za-z0-9_-]{1,80}$');

  Directory dir(String projectId) {
    if (!_id.hasMatch(projectId)) throw ArgumentError.value(projectId, 'projectId');
    return Directory('${root.path}/$projectId');
  }

  File _main(String id) => File('${dir(id).path}/comic.json');

  Future<void> save(String projectId, ComicDocument doc) async {
    final d = dir(projectId);
    await d.create(recursive: true);
    final text = jsonEncode(doc.toJson());
    final tmp = File('${_main(projectId).path}.tmp');
    await tmp.writeAsString(text, flush: true);
    final main = _main(projectId);
    if (await main.exists()) await main.copy('${main.path}.bak');
    await tmp.rename(main.path);
  }

  /// Null when the project has no comic yet. A damaged main file falls back
  /// to the backup; if both are unreadable a [ComicException] is thrown.
  Future<ComicDocument?> load(String projectId) async {
    final main = _main(projectId);
    if (!await main.exists()) return null;
    try {
      return ComicDocument.fromJson(jsonDecode(await main.readAsString()));
    } on Object {
      final bak = File('${main.path}.bak');
      if (await bak.exists()) {
        try {
          return ComicDocument.fromJson(jsonDecode(await bak.readAsString()));
        } on Object {
          // fall through
        }
      }
      throw const ComicException('The comic file is damaged and no backup could be read.');
    }
  }

  Future<File> writeExport(String projectId, String fileName, Uint8List bytes) async {
    if (fileName.contains('/') || fileName.contains('\\') || fileName.contains('..')) {
      throw ArgumentError.value(fileName, 'fileName');
    }
    final d = Directory('${dir(projectId).path}/export');
    await d.create(recursive: true);
    final f = File('${d.path}/$fileName');
    await f.writeAsBytes(bytes, flush: true);
    return f;
  }

  Future<File> writeFont(String projectId, String fileName, Uint8List bytes) async {
    if (!RegExp(r'^[A-Za-z0-9_.-]{1,80}$').hasMatch(fileName) || fileName.contains('..')) {
      throw ArgumentError.value(fileName, 'fileName');
    }
    final d = Directory('${dir(projectId).path}/fonts');
    await d.create(recursive: true);
    final f = File('${d.path}/$fileName');
    await f.writeAsBytes(bytes, flush: true);
    return f;
  }

  Future<Uint8List?> readFont(String projectId, String fileName) async {
    final f = File('${dir(projectId).path}/fonts/$fileName');
    return await f.exists() ? f.readAsBytes() : null;
  }
}
