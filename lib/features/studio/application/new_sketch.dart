import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/providers.dart';
import '../../../core/diagnostics/app_log.dart';
import '../../projects/domain/art_project.dart';

/// Creates a gallery entry for a new sketch and opens it in Sketch Studio.
/// The drawing itself is written by the studio on first autosave.
Future<void> openNewSketch(BuildContext context, WidgetRef ref) async {
  final repository = ref.read(projectRepositoryProvider);
  String? id;
  try {
    final projects = await repository.loadProjects();
    final now = DateTime.now();
    final number =
        projects.where((p) => p.kind.toLowerCase() == 'sketch').length + 1;
    id = 'sketch_${now.microsecondsSinceEpoch}';
    await repository.saveProjects([
      ArtProject(
        id: id,
        name: 'Untitled sketch $number',
        kind: 'Sketch',
        updatedAt: now,
      ),
      ...projects,
    ]);
    ref.invalidate(projectsProvider);
  } catch (error, stack) {
    AppLog.error('Could not create sketch project',
        error: error, stackTrace: stack);
    id = null; // fall back to an unsaved scratch canvas
  }
  if (!context.mounted) return;
  context.push(id == null ? '/studio/sketch' : '/studio/sketch?project=$id');
}

/// Opens an existing gallery project in the matching studio.
void openProject(BuildContext context, ArtProject project) {
  if (project.kind.toLowerCase().contains('animation')) {
    context.push('/studio/animation');
  } else {
    context.push('/studio/sketch?project=${project.id}');
  }
}
