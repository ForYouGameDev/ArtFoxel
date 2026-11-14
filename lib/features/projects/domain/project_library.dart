import 'art_project.dart';

enum LibrarySort { recent, oldest, nameAsc, nameDesc, largest, kind }

class LibraryQuery {
  const LibraryQuery({
    this.text = '',
    this.kind,
    this.sort = LibrarySort.recent,
    this.favoritesOnly = false,
    this.tag,
  });
  final String text;

  /// 'Sketch' | 'Comic' | 'Animation'; null = all.
  final String? kind;
  final LibrarySort sort;
  final bool favoritesOnly;
  final String? tag;

  LibraryQuery copyWith({
    String? text,
    Object? kind = _keep,
    LibrarySort? sort,
    bool? favoritesOnly,
    Object? tag = _keep,
  }) =>
      LibraryQuery(
        text: text ?? this.text,
        kind: identical(kind, _keep) ? this.kind : kind as String?,
        sort: sort ?? this.sort,
        favoritesOnly: favoritesOnly ?? this.favoritesOnly,
        tag: identical(tag, _keep) ? this.tag : tag as String?,
      );
  static const Object _keep = Object();
}

abstract final class ProjectLibrary {
  /// Filters, searches (name, kind, tags, notes; every word must match) and
  /// sorts. Pure, so the same logic is used by the screen and by tests.
  static List<ArtProject> apply(Iterable<ArtProject> all, LibraryQuery q) {
    final words = q.text.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    final out = all.where((p) {
      if (q.kind != null && !_kindMatches(p.kind, q.kind!)) return false;
      if (q.favoritesOnly && !p.favorite) return false;
      if (q.tag != null && !p.tags.map((t) => t.toLowerCase()).contains(q.tag!.toLowerCase())) {
        return false;
      }
      if (words.isEmpty) return true;
      final hay = '${p.name} ${p.kind} ${p.tags.join(' ')} ${p.notes}'.toLowerCase();
      return words.every(hay.contains);
    }).toList();
    int cmp(ArtProject a, ArtProject b) {
      switch (q.sort) {
        case LibrarySort.recent:
          return b.updatedAt.compareTo(a.updatedAt);
        case LibrarySort.oldest:
          return a.updatedAt.compareTo(b.updatedAt);
        case LibrarySort.nameAsc:
          return a.name.toLowerCase().compareTo(b.name.toLowerCase());
        case LibrarySort.nameDesc:
          return b.name.toLowerCase().compareTo(a.name.toLowerCase());
        case LibrarySort.largest:
          return (b.sizeBytes ?? 0).compareTo(a.sizeBytes ?? 0);
        case LibrarySort.kind:
          final k = a.kind.compareTo(b.kind);
          return k != 0 ? k : b.updatedAt.compareTo(a.updatedAt);
      }
    }

    out.sort((a, b) {
      // Favourites float to the top only for the default "recent" view.
      if (q.sort == LibrarySort.recent && a.favorite != b.favorite) {
        return a.favorite ? -1 : 1;
      }
      final c = cmp(a, b);
      return c != 0 ? c : a.id.compareTo(b.id);
    });
    return out;
  }

  static bool _kindMatches(String projectKind, String filter) =>
      projectKind.toLowerCase().contains(filter.toLowerCase());

  /// Trims, collapses whitespace and limits the length. Null when empty.
  static String? cleanName(String input) {
    final s = input.replaceAll(RegExp(r'[\u0000-\u001F\u007F]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    if (s.isEmpty) return null;
    return s.length > ArtProject.maxNameLength ? s.substring(0, ArtProject.maxNameLength).trimRight() : s;
  }

  /// "Name copy", "Name copy 2"... never equal to an existing name.
  static String uniqueCopyName(String base, Iterable<String> existing) {
    final names = existing.map((e) => e.toLowerCase()).toSet();
    var candidate = '$base copy';
    var n = 2;
    while (names.contains(candidate.toLowerCase())) {
      candidate = '$base copy $n';
      n++;
    }
    return cleanName(candidate) ?? candidate;
  }

  /// Name for an imported project that clashes with an existing one.
  static String uniqueName(String base, Iterable<String> existing) {
    final names = existing.map((e) => e.toLowerCase()).toSet();
    if (!names.contains(base.toLowerCase())) return base;
    var n = 2;
    while (names.contains('$base ($n)'.toLowerCase())) {
      n++;
    }
    return '$base ($n)';
  }

  static final RegExp idPattern = RegExp(r'^[A-Za-z0-9_-]{1,80}$');

  static String newId(String kindLabel, {DateTime? now}) =>
      '${kindLabel.toLowerCase()}_${(now ?? DateTime.now()).microsecondsSinceEpoch}';
}
