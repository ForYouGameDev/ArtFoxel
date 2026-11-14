import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../../core/io/zip_codec.dart';
import '../../projects/domain/art_project.dart';
import '../../projects/domain/project_library.dart';
import '../domain/artfoxel_package.dart';

class ProjectFileException implements Exception {
  const ProjectFileException(this.message);
  final String message;
  @override
  String toString() => message;
}

class TrashHandle {
  const TrashHandle(this.project, this.trashPath, this.deletedAt);
  final ArtProject project;
  final String trashPath;
  final DateTime deletedAt;
}

class VersionInfo {
  const VersionInfo(this.id, this.label, this.createdAt, this.sizeBytes, this.auto);
  final String id, label;
  final DateTime createdAt;
  final int sizeBytes;
  final bool auto;
}

/// Everything that touches project folders on disk. One folder per project:
///
/// ```
/// <base>/sketches|comics|animations/<id>/
///     sketch.json | comic.json | animation.json   (+ .bak, recovery.json)
///     references.json   (sketch)   fonts/ (comic)   thumbnail.png
///     versions/<stamp>_<label>/...   named + automatic restore points
/// <base>/.trash/<id>_<stamp>/        deleted projects, restorable for 14 days
/// ```
///
/// Studios own the document files; this class only copies, packages and
/// moves whole folders, so it can never merge sketch and animation data.
class ProjectFiles {
  ProjectFiles(this.base);
  final Directory base;

  static const trashDays = 14;
  static const maxVersions = 30;
  static const maxAutoVersions = 10;
  static const autoVersionGap = Duration(minutes: 30);
  static const maxImportBytes = 512 * 1024 * 1024;

  Directory root(ProjectKind kind) => Directory('${base.path}/${switch (kind) {
        ProjectKind.sketch => 'sketches',
        ProjectKind.comic => 'comics',
        ProjectKind.animation => 'animations',
      }}');

  Directory dir(ProjectKind kind, String id) {
    if (!ProjectLibrary.idPattern.hasMatch(id)) {
      throw ArgumentError.value(id, 'id', 'Invalid project id');
    }
    return Directory('${root(kind).path}/$id');
  }

  static String contentFileName(ProjectKind kind) => switch (kind) {
        ProjectKind.sketch => 'sketch.json',
        ProjectKind.comic => 'comic.json',
        ProjectKind.animation => 'animation.json',
      };

  File contentFile(ProjectKind kind, String id) =>
      File('${dir(kind, id).path}/${contentFileName(kind)}');
  File thumbnailFile(ProjectKind kind, String id) => File('${dir(kind, id).path}/thumbnail.png');

  Directory get trashDir => Directory('${base.path}/.trash');

  // ------------------------------------------------------------- reading

  /// Main content, falling back to the last good backup. Null when the
  /// project has never been saved.
  Future<Uint8List?> readContent(ProjectKind kind, String id) async {
    final main = contentFile(kind, id);
    for (final f in [main, File('${main.path}.bak')]) {
      if (!await f.exists()) continue;
      final bytes = await f.readAsBytes();
      try {
        ContentValidator.validate(kind, bytes);
        return bytes;
      } on PackageException {
        continue; // damaged: try the backup
      }
    }
    if (await main.exists()) {
      throw const ProjectFileException(
          'This project file could not be read. It was left untouched on your device.');
    }
    return null;
  }

  Future<Map<String, Uint8List>> _readAnimationAssets(String id) async {
    final d = Directory('${dir(ProjectKind.animation, id).path}/assets');
    final out = <String, Uint8List>{};
    if (!await d.exists()) return out;
    await for (final e in d.list()) {
      if (e is File && e.path.endsWith('.png')) {
        out['assets/${e.uri.pathSegments.last}'] = await e.readAsBytes();
      }
    }
    return out;
  }

  Future<Uint8List?> _readIfExists(File f) async => await f.exists() ? f.readAsBytes() : null;

  Future<Map<String, Uint8List>> _readFonts(String id) async {
    final d = Directory('${dir(ProjectKind.comic, id).path}/fonts');
    final out = <String, Uint8List>{};
    if (!await d.exists()) return out;
    await for (final e in d.list()) {
      if (e is File) {
        final name = e.uri.pathSegments.last;
        final lower = name.toLowerCase();
        if (lower.endsWith('.ttf') || lower.endsWith('.otf')) out[name] = await e.readAsBytes();
      }
    }
    return out;
  }

  // ------------------------------------------------------------ packages

  /// Saves the project as a `.artfoxel` package (the "Save As" / share file).
  /// [thumbnail] overrides the stored thumbnail.
  Future<Uint8List> exportPackage(ArtProject project, {Uint8List? thumbnail}) async {
    final kind = ProjectKind.fromLabel(project.kind);
    final content = await readContent(kind, project.id);
    if (content == null) {
      throw const ProjectFileException('This project has no saved drawing yet. Open it and draw something first.');
    }
    return ArtfoxelPackage.build(
      kind: kind,
      name: project.name,
      content: content,
      references: kind == ProjectKind.sketch
          ? await _readIfExists(File('${dir(kind, project.id).path}/references.json'))
          : null,
      fonts: kind == ProjectKind.comic ? await _readFonts(project.id) : const {},
      thumbnail: thumbnail ?? await _readIfExists(thumbnailFile(kind, project.id)),
      extras: kind == ProjectKind.animation ? await _readAnimationAssets(project.id) : const {},
      createdAt: project.createdAt,
    );
  }

  /// Imports a package as a NEW project (never overwrites an existing one).
  /// Returns the gallery record plus any integrity warnings.
  Future<ImportedProject> importPackage(Uint8List bytes, {required Iterable<String> existingNames}) async {
    if (bytes.length > maxImportBytes) {
      throw const ProjectFileException('That file is too large to import.');
    }
    final PackageContents pkg;
    try {
      pkg = ArtfoxelPackage.open(bytes);
    } on PackageException catch (e) {
      throw ProjectFileException(e.message);
    }
    final kind = pkg.manifest.kind;
    final id = ProjectLibrary.newId(kind.label);
    final target = dir(kind, id);
    final staging = Directory('${target.path}.importing');
    if (await staging.exists()) await staging.delete(recursive: true);
    await staging.create(recursive: true);
    try {
      await File('${staging.path}/${contentFileName(kind)}').writeAsBytes(pkg.content, flush: true);
      final refs = pkg.references;
      if (refs != null && kind == ProjectKind.sketch) {
        await File('${staging.path}/references.json').writeAsBytes(refs, flush: true);
      }
      final thumb = pkg.thumbnail;
      if (thumb != null) await File('${staging.path}/thumbnail.png').writeAsBytes(thumb, flush: true);
      if (kind == ProjectKind.comic && pkg.fonts.isNotEmpty) {
        final fd = Directory('${staging.path}/fonts');
        await fd.create();
        for (final f in pkg.fonts.entries) {
          if (!RegExp(r'^[A-Za-z0-9._-]{1,80}$').hasMatch(f.key)) continue;
          await File('${fd.path}/${f.key}').writeAsBytes(f.value, flush: true);
        }
      }
      if (kind == ProjectKind.animation) {
        final ad = Directory('${staging.path}/assets');
        for (final e in pkg.entries.entries) {
          final m = RegExp(r'^extras/assets/([A-Za-z0-9_-]{1,60})\.png$').firstMatch(e.key);
          if (m == null) continue;
          await ad.create(recursive: true);
          await File('${ad.path}/${m[1]}.png').writeAsBytes(e.value, flush: true);
        }
      }
      await root(kind).create(recursive: true);
      await staging.rename(target.path);
    } on Object {
      if (await staging.exists()) await staging.delete(recursive: true);
      rethrow;
    }
    final m = pkg.manifest;
    final now = DateTime.now();
    final project = ArtProject(
      id: id,
      name: ProjectLibrary.uniqueName(ProjectLibrary.cleanName(m.name) ?? 'Imported project', existingNames),
      kind: kind.label,
      updatedAt: now,
      createdAt: m.createdAt,
      width: m.width,
      height: m.height,
      sizeBytes: await dirSize(target),
      thumbnailRevision: 1,
    );
    return ImportedProject(project, pkg.issues, pkg.migratedFrom);
  }

  // -------------------------------------------------------- lifecycle ops

  /// Copies a project folder to a new id (recovery files and versions are not
  /// copied: the copy starts from the last clean save).
  Future<ArtProject> duplicate(ArtProject source, {required Iterable<String> existingNames}) async {
    final kind = ProjectKind.fromLabel(source.kind);
    final from = dir(kind, source.id);
    if (!await from.exists()) {
      throw const ProjectFileException('This project has nothing saved to copy yet.');
    }
    final id = ProjectLibrary.newId(kind.label);
    final to = dir(kind, id);
    await to.create(recursive: true);
    await for (final e in from.list(recursive: true)) {
      final rel = e.path.substring(from.path.length + 1);
      if (rel.startsWith('versions') || rel == 'recovery.json' || rel.endsWith('.tmp')) continue;
      if (e is Directory) {
        await Directory('${to.path}/$rel').create(recursive: true);
      } else if (e is File) {
        await Directory('${to.path}/$rel').parent.create(recursive: true);
        await e.copy('${to.path}/$rel');
      }
    }
    final now = DateTime.now();
    return source.copyWith(
      name: ProjectLibrary.uniqueCopyName(source.name, existingNames),
      updatedAt: now,
    )._withId(id, now, await dirSize(to));
  }

  /// Safe delete: the folder moves to `.trash`, so Undo can bring it back.
  Future<TrashHandle> moveToTrash(ArtProject project) async {
    final kind = ProjectKind.fromLabel(project.kind);
    final src = dir(kind, project.id);
    final now = DateTime.now();
    await trashDir.create(recursive: true);
    final dest = '${trashDir.path}/${project.id}_${now.microsecondsSinceEpoch}';
    if (await src.exists()) {
      await src.rename(dest);
    } else {
      await Directory(dest).create(recursive: true);
    }
    return TrashHandle(project, dest, now);
  }

  Future<void> restoreFromTrash(TrashHandle handle) async {
    final kind = ProjectKind.fromLabel(handle.project.kind);
    final dest = dir(kind, handle.project.id);
    if (await dest.exists()) {
      throw const ProjectFileException('A project with this id already exists.');
    }
    await root(kind).create(recursive: true);
    final src = Directory(handle.trashPath);
    if (await src.exists()) await src.rename(dest.path);
  }

  /// Permanently removes trash older than [trashDays] (call on app start).
  Future<int> purgeTrash({DateTime? now}) async {
    if (!await trashDir.exists()) return 0;
    final cutoff = (now ?? DateTime.now()).subtract(const Duration(days: trashDays));
    var n = 0;
    await for (final e in trashDir.list()) {
      if (e is! Directory) continue;
      final stamp = int.tryParse(e.path.split('_').last);
      if (stamp == null) continue;
      if (DateTime.fromMicrosecondsSinceEpoch(stamp).isBefore(cutoff)) {
        await e.delete(recursive: true);
        n++;
      }
    }
    return n;
  }

  Future<int> dirSize(Directory d) async {
    var total = 0;
    if (!await d.exists()) return 0;
    await for (final e in d.list(recursive: true, followLinks: false)) {
      if (e is File) total += await e.length();
    }
    return total;
  }

  // ---------------------------------------------------------- thumbnails

  /// Writes (atomically) a PNG preview rendered by the studio.
  Future<void> writeThumbnail(ProjectKind kind, String id, Uint8List png) async {
    await dir(kind, id).create(recursive: true);
    final f = thumbnailFile(kind, id);
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsBytes(png, flush: true);
    await tmp.rename(f.path);
  }

  // ------------------------------------------------------------ versions

  Directory _versions(ProjectKind kind, String id) => Directory('${dir(kind, id).path}/versions');

  static final RegExp _versionId = RegExp(r'^\d{10,}_(a|n)_[A-Za-z0-9-]{0,40}$');

  Future<VersionInfo> createVersion(ProjectKind kind, String id, String label, {bool auto = false}) async {
    final main = contentFile(kind, id);
    if (!await main.exists()) {
      throw const ProjectFileException('Save the project before creating a restore point.');
    }
    final safe = label.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final vid = '${stamp}_${auto ? 'a' : 'n'}_${safe.length > 40 ? safe.substring(0, 40) : safe}';
    final d = Directory('${_versions(kind, id).path}/$vid');
    await d.create(recursive: true);
    await main.copy('${d.path}/${contentFileName(kind)}');
    final refs = File('${dir(kind, id).path}/references.json');
    if (kind == ProjectKind.sketch && await refs.exists()) await refs.copy('${d.path}/references.json');
    await File('${d.path}/label.txt').writeAsString(label.length > 80 ? label.substring(0, 80) : label);
    await _prune(kind, id);
    return VersionInfo(vid, label, DateTime.fromMicrosecondsSinceEpoch(stamp), await dirSize(d), auto);
  }

  /// Creates an automatic restore point when the newest one is old enough.
  Future<VersionInfo?> maybeAutoVersion(ProjectKind kind, String id, {DateTime? now}) async {
    final list = await listVersions(kind, id);
    final t = now ?? DateTime.now();
    if (list.isNotEmpty && t.difference(list.first.createdAt) < autoVersionGap) return null;
    if (!await contentFile(kind, id).exists()) return null;
    return createVersion(kind, id, 'Automatic', auto: true);
  }

  Future<List<VersionInfo>> listVersions(ProjectKind kind, String id) async {
    final d = _versions(kind, id);
    if (!await d.exists()) return const [];
    final out = <VersionInfo>[];
    await for (final e in d.list()) {
      if (e is! Directory) continue;
      final vid = e.path.split(Platform.pathSeparator).last;
      if (!_versionId.hasMatch(vid)) continue;
      final parts = vid.split('_');
      final stamp = int.tryParse(parts.first);
      if (stamp == null) continue;
      final labelFile = File('${e.path}/label.txt');
      final label = await labelFile.exists() ? await labelFile.readAsString() : (parts.length > 2 ? parts.sublist(2).join('_') : '');
      out.add(VersionInfo(vid, label, DateTime.fromMicrosecondsSinceEpoch(stamp), await dirSize(e), parts[1] == 'a'));
    }
    out.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return out;
  }

  Future<void> _prune(ProjectKind kind, String id) async {
    final list = await listVersions(kind, id);
    final autos = list.where((v) => v.auto).toList();
    final drop = <VersionInfo>[
      if (autos.length > maxAutoVersions) ...autos.sublist(maxAutoVersions),
    ];
    final rest = list.where((v) => !drop.contains(v)).toList();
    if (rest.length > maxVersions) drop.addAll(rest.sublist(maxVersions));
    for (final v in drop) {
      final d = Directory('${_versions(kind, id).path}/${v.id}');
      if (await d.exists()) await d.delete(recursive: true);
    }
  }

  /// Restores [versionId] into the main file. The current state is saved as a
  /// new restore point first, so a restore can itself be undone.
  Future<void> restoreVersion(ProjectKind kind, String id, String versionId) async {
    if (!_versionId.hasMatch(versionId)) throw ArgumentError.value(versionId, 'versionId');
    final src = Directory('${_versions(kind, id).path}/$versionId');
    final file = File('${src.path}/${contentFileName(kind)}');
    if (!await file.exists()) throw const ProjectFileException('That restore point no longer exists.');
    final bytes = await file.readAsBytes();
    try {
      ContentValidator.validate(kind, bytes);
    } on PackageException {
      throw const ProjectFileException('That restore point is damaged and cannot be restored.');
    }
    if (await contentFile(kind, id).exists()) {
      await createVersion(kind, id, 'Before restore');
    }
    final main = contentFile(kind, id);
    final tmp = File('${main.path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    if (await main.exists()) await main.copy('${main.path}.bak');
    await tmp.rename(main.path);
    final refs = File('${src.path}/references.json');
    if (kind == ProjectKind.sketch && await refs.exists()) {
      await refs.copy('${dir(kind, id).path}/references.json');
    }
    final rec = File('${dir(kind, id).path}/recovery.json');
    if (await rec.exists()) await rec.delete(); // stale after a restore
  }

  Future<void> deleteVersion(ProjectKind kind, String id, String versionId) async {
    if (!_versionId.hasMatch(versionId)) throw ArgumentError.value(versionId, 'versionId');
    final d = Directory('${_versions(kind, id).path}/$versionId');
    if (await d.exists()) await d.delete(recursive: true);
  }

  // -------------------------------------------------------------- backup

  /// Whole-library backup: one archive holding every project as a package.
  static const backupFormat = 'artfoxel-backup';

  Future<Uint8List> createBackup(List<ArtProject> projects, {void Function(int done, int total)? onProgress}) async {
    final entries = <Map<String, Object?>>[];
    final files = <String, Uint8List>{};
    var i = 0;
    for (final p in projects) {
      i++;
      onProgress?.call(i, projects.length);
      try {
        final bytes = await exportPackage(p);
        final name = 'projects/${p.id}.artfoxel';
        files[name] = bytes;
        entries.add({'file': name, 'meta': p.toJson()});
      } on ProjectFileException {
        continue; // never saved: nothing to back up
      }
    }
    return BackupArchive.build(entries, files);
  }

  /// Restores a backup as new projects (existing ones are never overwritten).
  Future<BackupRestoreResult> restoreBackup(Uint8List bytes, {required List<ArtProject> existing}) {
    return BackupArchive.restore(this, bytes, existing);
  }
}

class ImportedProject {
  const ImportedProject(this.project, this.issues, this.migratedFrom);
  final ArtProject project;
  final List<IntegrityIssue> issues;
  final int? migratedFrom;
}

extension on ArtProject {
  ArtProject _withId(String id, DateTime now, int size) => ArtProject(
        id: id,
        name: name,
        kind: kind,
        updatedAt: now,
        createdAt: now,
        width: width,
        height: height,
        sizeBytes: size,
        thumbnailRevision: thumbnailRevision + 1,
        tags: tags,
        notes: notes,
        favorite: false,
      );
}

class BackupRestoreResult {
  const BackupRestoreResult(this.restored, this.skipped);
  final List<ArtProject> restored;
  final List<String> skipped;
}

abstract final class BackupArchive {
  static Uint8List build(List<Map<String, Object?>> entries, Map<String, Uint8List> files) =>
      _build(entries, files);

  static Future<BackupRestoreResult> restore(
      ProjectFiles files, Uint8List bytes, List<ArtProject> existing) =>
      _restore(files, bytes, existing);
}

Uint8List _build(List<Map<String, Object?>> entries, Map<String, Uint8List> files) {
  final zip = ZipWriter();
  zip.add(
    'backup.json',
    utf8.encode(jsonEncode({
      'format': ProjectFiles.backupFormat,
      'version': 1,
      'createdAt': DateTime.now().toUtc().toIso8601String(),
      'projects': entries,
    })),
  );
  for (final f in files.entries) {
    zip.add(f.key, f.value, compress: false); // packages are already compressed
  }
  return zip.finish();
}

Future<BackupRestoreResult> _restore(
    ProjectFiles files, Uint8List bytes, List<ArtProject> existing) async {
  final ZipReader zip;
  final Map<String, dynamic> manifest;
  try {
    zip = ZipReader.parse(bytes);
    final decoded = jsonDecode(utf8.decode(zip.read('backup.json')));
    if (decoded is! Map<String, dynamic> || decoded['format'] != ProjectFiles.backupFormat) {
      throw const ProjectFileException('This is not an ARTFOXEL backup file.');
    }
    final v = decoded['version'];
    if (v is! int || v > 1) {
      throw const ProjectFileException('This backup was made by a newer version of ARTFOXEL.');
    }
    manifest = decoded;
  } on ZipException catch (e) {
    throw ProjectFileException('This is not a valid backup file. ${e.message}');
  } on FormatException {
    throw const ProjectFileException('The backup index is damaged.');
  }
  final names = existing.map((e) => e.name).toList();
  final restored = <ArtProject>[];
  final skipped = <String>[];
  for (final raw in (manifest['projects'] as List? ?? const [])) {
    if (raw is! Map || raw['file'] is! String) continue;
    final file = raw['file'] as String;
    try {
      final imported = await files.importPackage(zip.read(file), existingNames: names);
      var p = imported.project;
      final meta = raw['meta'];
      if (meta is Map<String, dynamic>) {
        try {
          final m = ArtProject.fromJson(meta);
          p = p.copyWith(tags: m.tags, notes: m.notes, favorite: m.favorite);
        } on FormatException {
          // metadata is a nicety; the artwork is what matters
        }
      }
      names.add(p.name);
      restored.add(p);
    } on Object catch (e) {
      skipped.add('$file: $e');
    }
  }
  return BackupRestoreResult(restored, skipped);
}
