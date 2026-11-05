import 'package:artfoxel/features/projects/data/project_repository.dart';
import 'package:artfoxel/features/projects/domain/art_project.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('an empty local store returns an empty gallery', () async {
    final repository = ProjectRepository(SharedPreferences.getInstance());

    expect(await repository.loadProjects(), isEmpty);
  });

  test('saved project metadata is restored from local preferences', () async {
    final repository = ProjectRepository(SharedPreferences.getInstance());
    final project = ArtProject(
      id: 'local-1',
      name: 'First idea',
      kind: 'Sketch',
      updatedAt: DateTime.utc(2025, 1, 2),
    );

    await repository.saveProjects([project]);

    final restored = await repository.loadProjects();
    expect(restored, hasLength(1));
    expect(restored.single.id, project.id);
    expect(restored.single.name, project.name);
    expect(restored.single.updatedAt, project.updatedAt);
  });

  test('invalid gallery data is reported instead of hidden', () async {
    await (await SharedPreferences.getInstance())
        .setString('local_projects_v1', '{invalid');
    final repository = ProjectRepository(SharedPreferences.getInstance());

    await expectLater(repository.loadProjects(), throwsFormatException);
  });
}
