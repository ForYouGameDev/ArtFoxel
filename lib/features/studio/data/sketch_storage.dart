import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../domain/reference_model.dart';
import '../domain/sketch_document_data.dart';

class SketchStorageException implements Exception {
  const SketchStorageException(this.message);

  final String message;

  @override
  String toString() => message;
}

class SketchLoadResult {
  const SketchLoadResult({
    this.document,
    this.recoveredFromCheckpoint = false,
    this.usedBackup = false,
  });

  /// Null when the project has no stored drawing yet (a brand new project).
  final SketchDocumentData? document;

  /// The previous session ended without a clean save; the document comes
  /// from the crash-recovery checkpoint and should be saved again.
  final bool recoveredFromCheckpoint;

  /// The main file was unreadable, so the last good backup was opened.
  final bool usedBackup;
}

String _encodeJson(Map<String, Object?> map) => jsonEncode(map);

Map<String, dynamic> _decodeJson(String text) {
  final decoded = jsonDecode(text);
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('Project file is not a JSON object.');
  }
  return decoded;
}

/// Stores each Sketch Studio document as `<root>/<projectId>/`:
///
/// * `sketch.json`        the last clean save
/// * `sketch.json.bak`    the previous clean save (used if the main file is damaged)
/// * `recovery.json`      crash-recovery checkpoint, removed by every clean save
///
/// Every write goes to a temporary file first and is then renamed, so a crash
/// can never leave a half-written project. JSON encoding/decoding runs in a
/// background isolate so the UI thread is not blocked.
class SketchStorage {
  SketchStorage(this.root);

  final Directory root;

  static final RegExp _idPattern = RegExp(r'^[A-Za-z0-9_-]{1,80}$');

  Directory _directory(String projectId) {
    if (!_idPattern.hasMatch(projectId)) {
      throw ArgumentError.value(projectId, 'projectId', 'Invalid project id');
    }
    return Directory('${root.path}/$projectId');
  }

  File _main(String id) => File('${_directory(id).path}/sketch.json');
  File _backup(String id) => File('${_directory(id).path}/sketch.json.bak');
  File _recovery(String id) => File('${_directory(id).path}/recovery.json');

  Future<SketchLoadResult> load(String projectId) async {
    final recovery = _recovery(projectId);
    if (await recovery.exists()) {
      final recovered = await _tryRead(recovery);
      if (recovered != null) {
        return SketchLoadResult(
          document: recovered,
          recoveredFromCheckpoint: true,
        );
      }
      // An unreadable checkpoint is discarded; the last clean save wins.
      await _deleteQuietly(recovery);
    }

    final main = _main(projectId);
    final mainExists = await main.exists();
    if (mainExists) {
      final document = await _tryRead(main);
      if (document != null) return SketchLoadResult(document: document);
    }
    final backup = _backup(projectId);
    if (await backup.exists()) {
      final document = await _tryRead(backup);
      if (document != null) {
        return SketchLoadResult(document: document, usedBackup: true);
      }
    }
    if (mainExists) {
      throw const SketchStorageException(
        'This project file could not be read. It was left untouched on '
        'your device.',
      );
    }
    return const SketchLoadResult();
  }

  /// Clean save: replaces the main file, keeps the previous one as a backup
  /// and clears the recovery checkpoint.
  Future<void> save(String projectId, SketchDocumentData document) async {
    final json = await _encode(document);
    final directory = _directory(projectId);
    await directory.create(recursive: true);
    final main = _main(projectId);
    final temp = File('${main.path}.tmp');
    await temp.writeAsString(json, flush: true);
    if (await main.exists()) {
      await main.copy(_backup(projectId).path);
    }
    await temp.rename(main.path);
    await _deleteQuietly(_recovery(projectId));
  }

  /// Writes the crash-recovery checkpoint (not a clean save).
  Future<void> writeCheckpoint(
    String projectId,
    SketchDocumentData document,
  ) async {
    final json = await _encode(document);
    final directory = _directory(projectId);
    await directory.create(recursive: true);
    final target = _recovery(projectId);
    final temp = File('${target.path}.tmp');
    await temp.writeAsString(json, flush: true);
    await temp.rename(target.path);
  }

  Future<bool> hasCheckpoint(String projectId) => _recovery(projectId).exists();

  Future<void> delete(String projectId) async {
    final directory = _directory(projectId);
    if (await directory.exists()) await directory.delete(recursive: true);
  }

  Future<String> _encode(SketchDocumentData document) {
    // The map is built synchronously, so later edits cannot change it while
    // the isolate encodes it.
    final map = document.toJson();
    return compute(_encodeJson, map);
  }

  Future<SketchDocumentData?> _tryRead(File file) async {
    try {
      final text = await file.readAsString();
      final map = await compute(_decodeJson, text);
      return SketchDocumentData.fromJson(map);
    } on SketchFormatException {
      return null;
    } on FormatException {
      return null;
    } on FileSystemException {
      return null;
    }
  }

  // ---- reference board (separate file: never part of the artwork) ---------

  File _references(String id) => File('${_directory(id).path}/references.json');

  /// Reads the project's reference images. A damaged file yields an empty
  /// board (references are never worth blocking the artwork over).
  Future<ReferenceBoard> loadReferences(String projectId) async {
    final file = _references(projectId);
    try {
      if (!await file.exists()) return const ReferenceBoard();
      final map = jsonDecode(await file.readAsString());
      if (map is! Map || map['images'] is! List) return const ReferenceBoard();
      final out = <ReferenceImage>[];
      for (final e in (map['images'] as List).take(ReferenceImage.maxImages)) {
        if (e is Map && e['data'] is String) {
          try {
            out.add(ReferenceImage.fromMeta(e, base64Decode(e['data'] as String)));
          } on ReferenceException {
            continue;
          } on FormatException {
            continue;
          }
        }
      }
      return ReferenceBoard(out);
    } on FileSystemException {
      return const ReferenceBoard();
    } on FormatException {
      return const ReferenceBoard();
    }
  }

  Future<void> saveReferences(String projectId, ReferenceBoard board) async {
    final dir = _directory(projectId);
    await dir.create(recursive: true);
    final text = jsonEncode({
      'version': 1,
      'images': [
        for (final i in board.images) {...i.toMeta(), 'data': base64Encode(i.bytes)},
      ],
    });
    final tmp = File('${_references(projectId).path}.tmp');
    await tmp.writeAsString(text, flush: true);
    await tmp.rename(_references(projectId).path);
  }

  Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // Leaving a stale file is harmless; the next save removes it.
    }
  }
}
