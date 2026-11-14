import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/providers.dart';
import '../../../core/diagnostics/app_log.dart';
import '../../imaging/domain/import_rules.dart';
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
  final kind = project.kind.toLowerCase();
  if (kind.contains('animation')) {
    context.push('/studio/animation?project=${project.id}');
  } else if (kind.contains('comic') || kind.contains('manga')) {
    context.push('/studio/comic?project=${project.id}');
  } else {
    context.push('/studio/sketch?project=${project.id}');
  }
}


/// An image waiting to be placed on the canvas of a brand-new project.
class PendingImageImport {
  const PendingImageImport(this.bytes, this.name, this.canvasWidth, this.canvasHeight);
  final Uint8List bytes;
  final String name;
  final int canvasWidth, canvasHeight;
}

final pendingImageImportProvider = StateProvider<PendingImageImport?>((ref) => null);

/// Home "Import Image": pick a picture, create a sketch project whose canvas
/// matches it (longest side capped at 4096) and open it in Sketch Studio.
Future<void> openImageAsNewCanvas(BuildContext context, WidgetRef ref) async {
  void say(String m) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(m)));
    }
  }

  try {
    final r = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ImportRules.pickerExtensions, withData: true);
    final f = r?.files.firstOrNull;
    if (f == null) return;
    final bytes = f.bytes;
    if (bytes == null) {
      say('That file could not be read.');
      return;
    }
    final plan = ImportRules.plan(bytes, fileName: f.name);
    final k = math.min(1.0, 4096 / math.max(plan.info.width, plan.info.height));
    final w = math.max(16, (plan.info.width * k).round());
    final h = math.max(16, (plan.info.height * k).round());
    ref.read(pendingImageImportProvider.notifier).state = PendingImageImport(bytes, f.name, w, h);
    if (!context.mounted) return;
    await openNewSketch(context, ref);
  } on ImageImportException catch (e) {
    say(e.message);
  } catch (_) {
    say('The image could not be opened.');
  }
}
