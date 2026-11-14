import 'dart:convert';
import 'dart:typed_data';

import '../../../core/io/sha256.dart';
import '../../../core/io/zip_codec.dart';
import '../../animation/domain/animation_model.dart';
import '../../comic/domain/comic_model.dart';
import '../../studio/domain/sketch_document_data.dart';

/// The final `.artfoxel` project package (Phase 8.1).
///
/// A package is an ordinary ZIP archive:
///
/// ```
/// manifest.json                 format, schema version, kind, canvas summary,
///                               SHA-256 + size + role of every other entry
/// content/sketch.json           (kind = sketch)    the layered document
/// content/comic.json            (kind = comic)     pages, panels, elements
/// content/animation.json        (kind = animation) frames and timeline
/// references/references.json    reference board — NEVER part of artwork export
/// fonts/<name>.ttf|otf          imported comic fonts (user supplied)
/// thumbnail.png                 preview (optional)
/// extras/<name>                 any other validated asset
/// ```
///
/// Rules: the content entry must pass integrity checks and parse with the
/// matching domain parser; optional entries (references, fonts, thumbnail)
/// may be damaged without blocking the artwork — the reader reports them as
/// warnings and opens the project without them.
class PackageException implements Exception {
  const PackageException(this.message, {this.corrupt = false, this.newer = false});
  final String message;

  /// The archive or its main content failed an integrity check.
  final bool corrupt;

  /// The file was written by a newer ARTFOXEL.
  final bool newer;
  @override
  String toString() => message;
}

enum ProjectKind {
  sketch,
  comic,
  animation;

  String get contentPath => 'content/$name.json';

  static ProjectKind? parse(Object? v) {
    for (final k in values) {
      if (k.name == v) return k;
    }
    return null;
  }

  /// Gallery label used by [ArtProject.kind].
  String get label => switch (this) {
        ProjectKind.sketch => 'Sketch',
        ProjectKind.comic => 'Comic',
        ProjectKind.animation => 'Animation',
      };

  static ProjectKind fromLabel(String label) {
    final l = label.toLowerCase();
    if (l.contains('animation')) return ProjectKind.animation;
    if (l.contains('comic') || l.contains('manga')) return ProjectKind.comic;
    return ProjectKind.sketch;
  }
}

class ManifestEntry {
  const ManifestEntry(this.path, this.sha256, this.size, this.role);
  final String path, sha256, role;
  final int size;
}

class PackageManifest {
  const PackageManifest({
    required this.schema,
    required this.kind,
    required this.name,
    required this.createdAt,
    required this.updatedAt,
    required this.appVersion,
    required this.entries,
    this.width,
    this.height,
    this.dpi,
    this.background,
    this.summary = const {},
  });

  static const format = 'artfoxel-project';
  static const currentSchema = 2;

  final int schema;
  final ProjectKind kind;
  final String name, appVersion;
  final DateTime createdAt, updatedAt;
  final int? width, height, background;
  final double? dpi;
  final Map<String, Object?> summary;
  final Map<String, ManifestEntry> entries;

  Map<String, Object?> toJson() => {
        'format': format,
        'schema': schema,
        'app': 'ARTFOXEL',
        'appVersion': appVersion,
        'kind': kind.name,
        'name': name,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'updatedAt': updatedAt.toUtc().toIso8601String(),
        'canvas': {
          if (width != null) 'width': width,
          if (height != null) 'height': height,
          if (dpi != null) 'dpi': dpi,
          'background': background,
        },
        'summary': summary,
        'entries': {
          for (final e in entries.values)
            e.path: {'sha256': e.sha256, 'size': e.size, 'role': e.role},
        },
      };
}

enum IssueKind { missing, hashMismatch, sizeMismatch, unreadable, unexpected }

class IntegrityIssue {
  const IntegrityIssue(this.path, this.kind, this.role, {this.fatal = false});
  final String path, role;
  final IssueKind kind;
  final bool fatal;
  String get text => '$path: ${kind.name}';
}

class PackageContents {
  PackageContents({
    required this.manifest,
    required this.content,
    required this.entries,
    required this.issues,
    required this.migratedFrom,
  });
  final PackageManifest manifest;

  /// Bytes of `content/<kind>.json` (always verified).
  final Uint8List content;

  /// Every other verified entry (damaged optional entries are omitted).
  final Map<String, Uint8List> entries;
  final List<IntegrityIssue> issues;

  /// Schema version the file was written with, when migrated on open.
  final int? migratedFrom;

  bool get degraded => issues.isNotEmpty;
  Uint8List? get references => entries['references/references.json'];
  Uint8List? get thumbnail => entries['thumbnail.png'];
  Map<String, Uint8List> get fonts => {
        for (final e in entries.entries)
          if (e.key.startsWith('fonts/')) e.key.substring(6): e.value,
      };
}

abstract final class ArtfoxelPackage {
  static const maxContentBytes = 200 * 1024 * 1024;
  static const extension = 'artfoxel';
  static const appVersion = '0.8.0';

  static String role(String path) {
    if (path.startsWith('content/')) return 'content';
    if (path.startsWith('references/')) return 'references';
    if (path.startsWith('fonts/')) return 'font';
    if (path == 'thumbnail.png') return 'thumbnail';
    return 'extra';
  }

  /// Builds a package. [content] must be the JSON of the document of [kind];
  /// it is validated with the real domain parser first so a package can never
  /// be written from a document this app cannot read back.
  static Uint8List build({
    required ProjectKind kind,
    required String name,
    required Uint8List content,
    Uint8List? references,
    Map<String, Uint8List> fonts = const {},
    Uint8List? thumbnail,
    Map<String, Uint8List> extras = const {},
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    final info = ContentValidator.validate(kind, content);
    final files = <String, Uint8List>{
      kind.contentPath: content,
      if (references != null) 'references/references.json': references,
      for (final f in fonts.entries) 'fonts/${f.key}': f.value,
      if (thumbnail != null) 'thumbnail.png': thumbnail,
      for (final e in extras.entries) 'extras/${e.key}': e.value,
    };
    final entries = <String, ManifestEntry>{
      for (final f in files.entries)
        f.key: ManifestEntry(f.key, Sha256.hex(f.value), f.value.length, role(f.key)),
    };
    final now = DateTime.now();
    final manifest = PackageManifest(
      schema: PackageManifest.currentSchema,
      kind: kind,
      name: name,
      createdAt: createdAt ?? info.createdAt ?? now,
      updatedAt: updatedAt ?? info.updatedAt ?? now,
      appVersion: appVersion,
      width: info.width,
      height: info.height,
      dpi: info.dpi,
      background: info.background,
      summary: info.summary,
      entries: entries,
    );
    final zip = ZipWriter();
    zip.add('manifest.json', utf8.encode(jsonEncode(manifest.toJson())));
    for (final f in files.entries) {
      final already = f.key.endsWith('.png') || f.key.startsWith('fonts/');
      zip.add(f.key, f.value, compress: !already);
    }
    return zip.finish();
  }

  /// Reads, migrates and verifies a package. Throws [PackageException] when
  /// the file is not a usable project; returns warnings in
  /// [PackageContents.issues] when only optional parts are damaged.
  static PackageContents open(Uint8List bytes) {
    final ZipReader zip;
    try {
      zip = ZipReader.parse(bytes);
    } on ZipException catch (e) {
      throw PackageException('This is not a valid .artfoxel file. ${e.message}', corrupt: true);
    }
    if (!zip.has('manifest.json')) {
      throw const PackageException('This file has no project manifest.', corrupt: true);
    }
    Map<String, dynamic> raw;
    try {
      final decoded = jsonDecode(utf8.decode(zip.read('manifest.json')));
      if (decoded is! Map<String, dynamic>) throw const FormatException('not an object');
      raw = decoded;
    } on ZipException catch (e) {
      throw PackageException('The project manifest is damaged. ${e.message}', corrupt: true);
    } on FormatException {
      throw const PackageException('The project manifest is damaged.', corrupt: true);
    }
    if (raw['format'] != PackageManifest.format) {
      throw const PackageException('This is not an ARTFOXEL project file.');
    }
    final fromSchema = _schemaOf(raw);
    final manifest = PackageMigrator.migrate(raw);
    final kind = ProjectKind.parse(manifest['kind'])!;
    final entriesJson = manifest['entries'] as Map<String, dynamic>;

    final issues = <IntegrityIssue>[];
    final verified = <String, Uint8List>{};
    Uint8List? content;
    for (final e in entriesJson.entries) {
      final path = e.key;
      final meta = e.value as Map<String, dynamic>;
      final r = role(path);
      final fatal = path == kind.contentPath;
      if (!isSafeZipName(path)) {
        throw const PackageException('The manifest lists an unsafe file name.', corrupt: true);
      }
      if (!zip.has(path)) {
        issues.add(IntegrityIssue(path, IssueKind.missing, r, fatal: fatal));
        continue;
      }
      Uint8List data;
      try {
        data = zip.read(path);
      } on ZipException {
        issues.add(IntegrityIssue(path, IssueKind.unreadable, r, fatal: fatal));
        continue;
      }
      final size = meta['size'];
      final hash = meta['sha256'];
      if (size is int && size != data.length) {
        issues.add(IntegrityIssue(path, IssueKind.sizeMismatch, r, fatal: fatal));
        continue;
      }
      // Schema-1 files carry no hashes; they were never verified before.
      if (hash is String && hash != Sha256.hex(data)) {
        issues.add(IntegrityIssue(path, IssueKind.hashMismatch, r, fatal: fatal));
        continue;
      }
      if (fatal) {
        content = data;
      } else {
        verified[path] = data;
      }
    }
    for (final z in zip.entries) {
      if (z.name != 'manifest.json' && !entriesJson.containsKey(z.name)) {
        issues.add(IntegrityIssue(z.name, IssueKind.unexpected, role(z.name)));
      }
    }
    final fatalIssue = issues.where((i) => i.fatal).firstOrNull;
    if (fatalIssue != null || content == null) {
      throw PackageException(
        'The project data is damaged (${fatalIssue?.text ?? 'content missing'}). '
        'The file was not modified.',
        corrupt: true,
      );
    }
    // The content must parse with the real document parser.
    try {
      ContentValidator.validate(kind, content);
    } on PackageException {
      rethrow;
    }
    final manifestObj = PackageMigrator.toManifest(manifest, kind);
    return PackageContents(
      manifest: manifestObj,
      content: content,
      entries: verified,
      // Unexpected extras are ignored (never loaded) but reported.
      issues: issues,
      migratedFrom: fromSchema < PackageManifest.currentSchema ? fromSchema : null,
    );
  }

  static int _schemaOf(Map<String, dynamic> m) {
    final v = m['schema'] ?? m['version'];
    if (v is! int || v < 1) {
      throw const PackageException('The project has no readable version.', corrupt: true);
    }
    return v;
  }
}

/// Schema migrations of the manifest. Each step is pure and idempotent; a file
/// is never rewritten on disk by opening it — the caller saves explicitly.
abstract final class PackageMigrator {
  static Map<String, dynamic> migrate(Map<String, dynamic> input) {
    var m = Map<String, dynamic>.from(input);
    var v = (m['schema'] ?? m['version']) as int? ?? 0;
    if (v > PackageManifest.currentSchema) {
      throw PackageException(
        'This project was saved by a newer version of ARTFOXEL (schema $v). '
        'Please update the app to open it.',
        newer: true,
      );
    }
    while (v < PackageManifest.currentSchema) {
      switch (v) {
        case 1:
          m = _v1ToV2(m);
        default:
          throw PackageException('Unsupported project schema $v.');
      }
      v = m['schema'] as int;
    }
    if (ProjectKind.parse(m['kind']) == null) {
      throw const PackageException('The project type is unknown.', corrupt: true);
    }
    if (m['entries'] is! Map) {
      throw const PackageException('The project manifest lists no files.', corrupt: true);
    }
    return m;
  }

  /// v1 used `version`/`type`/`files` (a flat list of names, no hashes).
  static Map<String, dynamic> _v1ToV2(Map<String, dynamic> m) {
    final type = m['type'] ?? m['kind'];
    final files = m['files'] ?? m['entries'];
    final entries = <String, dynamic>{};
    if (files is List) {
      for (final f in files) {
        if (f is String) entries[f] = {'role': ArtfoxelPackage.role(f)};
      }
    } else if (files is Map) {
      for (final e in files.entries) {
        entries['${e.key}'] = {'role': ArtfoxelPackage.role('${e.key}')};
      }
    }
    return {
      ...m,
      'schema': 2,
      'kind': type,
      'entries': entries,
    }
      ..remove('version')
      ..remove('type')
      ..remove('files');
  }

  static PackageManifest toManifest(Map<String, dynamic> m, ProjectKind kind) {
    DateTime t(Object? v) => DateTime.tryParse('$v') ?? DateTime.fromMillisecondsSinceEpoch(0);
    final canvas = m['canvas'] is Map ? m['canvas'] as Map : const {};
    final entries = <String, ManifestEntry>{};
    for (final e in (m['entries'] as Map).entries) {
      final v = e.value is Map ? e.value as Map : const {};
      entries['${e.key}'] = ManifestEntry('${e.key}', '${v['sha256'] ?? ''}',
          (v['size'] as num?)?.toInt() ?? 0, '${v['role'] ?? ArtfoxelPackage.role('${e.key}')}');
    }
    return PackageManifest(
      schema: PackageManifest.currentSchema,
      kind: kind,
      name: '${m['name'] ?? 'Untitled'}',
      createdAt: t(m['createdAt']),
      updatedAt: t(m['updatedAt']),
      appVersion: '${m['appVersion'] ?? ''}',
      width: (canvas['width'] as num?)?.toInt(),
      height: (canvas['height'] as num?)?.toInt(),
      dpi: (canvas['dpi'] as num?)?.toDouble(),
      background: (canvas['background'] as num?)?.toInt(),
      summary: m['summary'] is Map ? Map<String, Object?>.from(m['summary'] as Map) : const {},
      entries: entries,
    );
  }
}

class ContentInfo {
  const ContentInfo({
    this.width,
    this.height,
    this.dpi,
    this.background,
    this.createdAt,
    this.updatedAt,
    this.summary = const {},
  });
  final int? width, height, background;
  final double? dpi;
  final DateTime? createdAt, updatedAt;
  final Map<String, Object?> summary;
}

/// Parses content with the real document parsers, so a bad file is rejected
/// with a readable message instead of failing later inside a studio.
abstract final class ContentValidator {
  static ContentInfo validate(ProjectKind kind, Uint8List bytes) {
    if (bytes.length > ArtfoxelPackage.maxContentBytes) {
      throw const PackageException('The project is too large to open.');
    }
    Object? json;
    try {
      json = jsonDecode(utf8.decode(bytes));
    } on FormatException {
      throw const PackageException('The project content is not valid JSON.', corrupt: true);
    }
    try {
      switch (kind) {
        case ProjectKind.sketch:
          if (json is! Map<String, dynamic>) throw const FormatException('not an object');
          final d = SketchDocumentData.fromJson(json);
          return ContentInfo(
            width: d.width,
            height: d.height,
            dpi: d.dpi,
            background: d.backgroundArgb,
            createdAt: d.createdAt,
            updatedAt: d.updatedAt,
            summary: {'layers': d.layers.length, 'strokes': d.strokeCount},
          );
        case ProjectKind.comic:
          final d = ComicDocument.fromJson(json);
          return ContentInfo(
            width: d.spec.widthPx,
            height: d.spec.heightPx,
            dpi: d.spec.dpi.toDouble(),
            summary: {'pages': d.pages.length},
          );
        case ProjectKind.animation:
          final d = AnimationDocument.fromJson(json);
          return ContentInfo(
            width: d.width,
            height: d.height,
            background: d.backgroundArgb,
            summary: {'frames': d.frames.length, 'fps': d.fps},
          );
      }
    } on PackageException {
      rethrow;
    } on SketchFormatException catch (e) {
      throw PackageException('The project content is not readable: ${e.message}', corrupt: true);
    } on ComicException catch (e) {
      throw PackageException('The project content is not readable: ${e.message}', corrupt: true);
    } on AnimationException catch (e) {
      throw PackageException('The project content is not readable: ${e.message}', corrupt: true);
    } on FormatException {
      throw const PackageException('The project content is not readable.', corrupt: true);
    }
  }
}
