import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';

import '../../../app/providers.dart';
import '../../../core/diagnostics/app_log.dart';
import '../../projects/domain/art_project.dart';
import '../data/comic_storage.dart';

final comicStorageProvider = FutureProvider<ComicStorage>((ref) async {
  final documents = await getApplicationDocumentsDirectory();
  return ComicStorage(Directory('${documents.path}/artfoxel/comics'));
});

/// Creates a gallery entry of [kind] ('Comic' or 'Animation') and opens its
/// studio. Falls back to an unsaved scratch project if the gallery cannot be
/// written.
Future<void> openNewProject(BuildContext context, WidgetRef ref, {required String kind}) async {
  final repository = ref.read(projectRepositoryProvider);
  String? id;
  try {
    final projects = await repository.loadProjects();
    final now = DateTime.now();
    final number = projects.where((p) => p.kind == kind).length + 1;
    id = '${kind.toLowerCase()}_${now.microsecondsSinceEpoch}';
    await repository.saveProjects([
      ArtProject(id: id, name: 'Untitled ${kind.toLowerCase()} $number', kind: kind, updatedAt: now),
      ...projects,
    ]);
    ref.invalidate(projectsProvider);
  } catch (error, stack) {
    AppLog.error('Could not create $kind project', error: error, stackTrace: stack);
    id = null;
  }
  if (!context.mounted) return;
  final route = kind == 'Comic' ? '/studio/comic' : '/studio/animation';
  context.push(id == null ? route : '$route?project=$id');
}
