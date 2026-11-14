/// Gallery metadata for one local project. The artwork itself lives in the
/// project folder; this record only carries what the library needs to list,
/// sort, search and filter without opening files.
class ArtProject {
  const ArtProject({
    required this.id,
    required this.name,
    required this.kind,
    required this.updatedAt,
    this.createdAt,
    this.width,
    this.height,
    this.sizeBytes,
    this.thumbnailRevision = 0,
    this.tags = const [],
    this.notes = '',
    this.favorite = false,
  });

  static const maxNameLength = 80;

  final String id;
  final String name;
  final String kind;
  final DateTime updatedAt;

  // Optional metadata (older gallery entries simply lack it).
  final DateTime? createdAt;
  final int? width, height;
  final int? sizeBytes;

  /// Bumped whenever `thumbnail.png` is rewritten so image caches refresh.
  final int thumbnailRevision;
  final List<String> tags;
  final String notes;
  final bool favorite;

  ArtProject copyWith({
    String? name,
    DateTime? updatedAt,
    int? width,
    int? height,
    int? sizeBytes,
    int? thumbnailRevision,
    List<String>? tags,
    String? notes,
    bool? favorite,
  }) =>
      ArtProject(
        id: id,
        name: name ?? this.name,
        kind: kind,
        updatedAt: updatedAt ?? this.updatedAt,
        createdAt: createdAt,
        width: width ?? this.width,
        height: height ?? this.height,
        sizeBytes: sizeBytes ?? this.sizeBytes,
        thumbnailRevision: thumbnailRevision ?? this.thumbnailRevision,
        tags: tags ?? this.tags,
        notes: notes ?? this.notes,
        favorite: favorite ?? this.favorite,
      );

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
    int? i(String k) => json[k] is num ? (json[k] as num).toInt() : null;
    final created = json['createdAt'];
    return ArtProject(
      id: id,
      name: name,
      kind: kind,
      updatedAt: DateTime.parse(updatedAt),
      createdAt: created is String ? DateTime.tryParse(created) : null,
      width: i('width'),
      height: i('height'),
      sizeBytes: i('sizeBytes'),
      thumbnailRevision: i('thumbRev') ?? 0,
      tags: [
        for (final t in (json['tags'] as List? ?? const []))
          if (t is String && t.trim().isNotEmpty) t.trim(),
      ],
      notes: json['notes'] is String ? json['notes'] as String : '',
      favorite: json['favorite'] == true,
    );
  }

  Map<String, Object> toJson() => {
        'id': id,
        'name': name,
        'kind': kind,
        'updatedAt': updatedAt.toIso8601String(),
        if (createdAt != null) 'createdAt': createdAt!.toIso8601String(),
        if (width != null) 'width': width!,
        if (height != null) 'height': height!,
        if (sizeBytes != null) 'sizeBytes': sizeBytes!,
        if (thumbnailRevision != 0) 'thumbRev': thumbnailRevision,
        if (tags.isNotEmpty) 'tags': tags,
        if (notes.isNotEmpty) 'notes': notes,
        if (favorite) 'favorite': true,
      };
}
