class ArtProject {
  const ArtProject({
    required this.id,
    required this.name,
    required this.kind,
    required this.updatedAt,
  });

  final String id;
  final String name;
  final String kind;
  final DateTime updatedAt;

  factory ArtProject.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final name = json['name'];
    final kind = json['kind'];
    final updatedAt = json['updatedAt'];
    if (id is! String ||
        name is! String ||
        kind is! String ||
        updatedAt is! String) {
      throw const FormatException('Invalid local project metadata.');
    }
    return ArtProject(
      id: id,
      name: name,
      kind: kind,
      updatedAt: DateTime.parse(updatedAt),
    );
  }

  Map<String, Object> toJson() => {
        'id': id,
        'name': name,
        'kind': kind,
        'updatedAt': updatedAt.toIso8601String(),
      };
}
