import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:artfoxel/features/animation/domain/animation_model.dart';
import 'package:artfoxel/features/project/data/project_files.dart';
import 'package:artfoxel/features/project/domain/artfoxel_package.dart';
import 'package:artfoxel/features/projects/domain/art_project.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tmp;
  late ProjectFiles files;
  late ArtProject proj;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('artfoxel_pf');
    files = ProjectFiles(tmp);
    proj = ArtProject(id: 'animation_1', name: 'Walk', kind: 'Animation', updatedAt: DateTime(2026, 11, 1));
    final d = files.dir(ProjectKind.animation, proj.id)..createSync(recursive: true);
    File('${d.path}/animation.json').writeAsStringSync(jsonEncode(AnimationDocument(width: 64, height: 64).toJson()));
    Directory('${d.path}/assets').createSync();
    File('${d.path}/assets/img1.png').writeAsBytesSync([1, 2, 3, 4]);
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test('duplicate copies files but not versions', () async {
    await files.createVersion(ProjectKind.animation, proj.id, 'v');
    final copy = await files.duplicate(proj, existingNames: ['Walk']);
    expect(copy.id, isNot(proj.id));
    expect(copy.name, isNot('Walk'));
    final d = files.dir(ProjectKind.animation, copy.id);
    expect(File('${d.path}/animation.json').existsSync(), isTrue);
    expect(File('${d.path}/assets/img1.png').existsSync(), isTrue);
    expect(Directory('${d.path}/versions').existsSync(), isFalse);
  });

  test('trash and restore', () async {
    final h = await files.moveToTrash(proj);
    expect(files.dir(ProjectKind.animation, proj.id).existsSync(), isFalse);
    await files.restoreFromTrash(h);
    expect(files.contentFile(ProjectKind.animation, proj.id).existsSync(), isTrue);
  });

  test('export then import makes a NEW project with assets', () async {
    final bytes = await files.exportPackage(proj);
    final res = await files.importPackage(bytes, existingNames: ['Walk']);
    expect(res.project.id, isNot(proj.id));
    final d = files.dir(ProjectKind.animation, res.project.id);
    expect(File('${d.path}/assets/img1.png').readAsBytesSync(), [1, 2, 3, 4]);
    expect(files.contentFile(ProjectKind.animation, proj.id).existsSync(), isTrue); // original untouched
  });

  test('importing garbage fails without creating folders', () async {
    final before = files.root(ProjectKind.animation).listSync().length;
    await expectLater(files.importPackage(Uint8List.fromList([1, 2, 3]), existingNames: const []), throwsA(isA<ProjectFileException>()));
    expect(files.root(ProjectKind.animation).listSync().length, before);
  });

  test('versions: create, list, restore, auto gap', () async {
    final v = await files.createVersion(ProjectKind.animation, proj.id, 'first');
    File(files.contentFile(ProjectKind.animation, proj.id).path).writeAsStringSync('changed');
    await files.restoreVersion(ProjectKind.animation, proj.id, v.id);
    expect(files.contentFile(ProjectKind.animation, proj.id).readAsStringSync(), contains('artfoxel-animation'));
    expect((await files.listVersions(ProjectKind.animation, proj.id)).isNotEmpty, isTrue);
    expect(await files.maybeAutoVersion(ProjectKind.animation, proj.id), isNull); // too soon
  });

  test('backup and restore as new copies', () async {
    final b = await files.createBackup([proj]);
    final r = await files.restoreBackup(b, existing: [proj]);
    expect(r.restored.length, 1);
    expect(r.restored.single.id, isNot(proj.id));
  });
}
