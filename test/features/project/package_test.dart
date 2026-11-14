import 'dart:convert';
import 'dart:typed_data';

import 'package:artfoxel/core/io/zip_codec.dart';
import 'package:artfoxel/features/animation/domain/animation_model.dart';
import 'package:artfoxel/features/project/domain/artfoxel_package.dart';
import 'package:artfoxel/features/projects/domain/art_project.dart';
import 'package:artfoxel/features/projects/domain/project_library.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _anim() => Uint8List.fromList(utf8.encode(jsonEncode(AnimationDocument(width: 64, height: 64).toJson())));

void main() {
  test('build/open round trip keeps content and thumbnail', () {
    final bytes = ArtfoxelPackage.build(kind: ProjectKind.animation, name: 'Walk', content: _anim(), thumbnail: Uint8List.fromList([1, 2, 3]));
    final p = ArtfoxelPackage.open(bytes);
    expect(p.manifest.kind, ProjectKind.animation);
    expect(p.content, _anim());
    expect(p.thumbnail, [1, 2, 3]);
    expect(p.degraded, isFalse);
  });

  test('invalid content is refused at build time', () {
    expect(() => ArtfoxelPackage.build(kind: ProjectKind.animation, name: 'x', content: Uint8List.fromList(utf8.encode('{}'))), throwsA(isA<PackageException>()));
  });

  test('not a zip is reported as corrupt', () {
    expect(() => ArtfoxelPackage.open(Uint8List.fromList([1, 2, 3, 4])), throwsA(isA<PackageException>().having((e) => e.corrupt, 'corrupt', true)));
  });

  test('damaged optional thumbnail degrades but opens', () {
    final bytes = ArtfoxelPackage.build(kind: ProjectKind.animation, name: 'W', content: _anim(), thumbnail: Uint8List.fromList(List.filled(40, 9)));
    // Rebuild the zip with a tampered thumbnail but the original manifest.
    final r = ZipReader.parse(bytes);
    final w = ZipWriter();
    for (final e in r.entries) {
      w.add(e.name, e.name == 'thumbnail.png' ? Uint8List.fromList(List.filled(40, 1)) : r.read(e.name));
    }
    final p = ArtfoxelPackage.open(w.finish());
    expect(p.degraded, isTrue);
    expect(p.thumbnail, isNull);
    expect(p.content, _anim());
  });

  test('damaged content is fatal', () {
    final bytes = ArtfoxelPackage.build(kind: ProjectKind.animation, name: 'W', content: _anim());
    final r = ZipReader.parse(bytes);
    final w = ZipWriter();
    for (final e in r.entries) {
      w.add(e.name, e.name.startsWith('content/') ? Uint8List.fromList(utf8.encode('{"x":1}')) : r.read(e.name));
    }
    expect(() => ArtfoxelPackage.open(w.finish()), throwsA(isA<PackageException>()));
  });

  test('newer schema is refused with update message', () {
    expect(() => PackageMigrator.migrate({'schema': 99, 'kind': 'sketch'}), throwsA(isA<PackageException>().having((e) => e.newer, 'newer', true)));
  });

  group('ProjectLibrary', () {
    final now = DateTime(2026, 11, 1);
    final items = [
      ArtProject(id: 'a', name: 'Zebra', kind: 'Sketch', updatedAt: now),
      ArtProject(id: 'b', name: 'apple', kind: 'Animation', updatedAt: now.add(const Duration(days: 1)), favorite: true),
      ArtProject(id: 'c', name: 'Mango comic', kind: 'Comic', updatedAt: now.add(const Duration(days: 2))),
    ];
    test('search and kind filter', () {
      expect(ProjectLibrary.apply(items, const LibraryQuery(text: 'mango')).map((e) => e.id), ['c']);
      expect(ProjectLibrary.apply(items, const LibraryQuery(kind: 'Animation')).map((e) => e.id), ['b']);
    });
    test('sort by name ignores case', () {
      expect(ProjectLibrary.apply(items, const LibraryQuery(sort: LibrarySort.nameAsc)).map((e) => e.id), ['b', 'c', 'a']);
    });
    test('unique names', () {
      expect(ProjectLibrary.uniqueName('Zebra', ['Zebra']), isNot('Zebra'));
      expect(ProjectLibrary.cleanName('   '), isNull);
    });
  });
}
