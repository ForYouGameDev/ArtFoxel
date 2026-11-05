import 'package:artfoxel/features/projects/domain/art_project.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('project metadata round trips through its JSON shape', () {
    final project = ArtProject(
      id: 'local-1',
      name: 'First idea',
      kind: 'Sketch',
      updatedAt: DateTime.utc(2025, 1, 2, 3, 4),
    );

    expect(ArtProject.fromJson(project.toJson()).id, project.id);
    expect(ArtProject.fromJson(project.toJson()).name, project.name);
    expect(ArtProject.fromJson(project.toJson()).kind, project.kind);
    expect(
      ArtProject.fromJson(project.toJson()).updatedAt,
      project.updatedAt,
    );
  });

  test('invalid project metadata fails instead of appearing as an empty item',
      () {
    expect(
      () => ArtProject.fromJson(const {'id': 'missing-fields'}),
      throwsFormatException,
    );
  });
}
