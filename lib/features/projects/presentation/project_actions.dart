import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../core/diagnostics/app_log.dart';
import '../../project/application/project_providers.dart';
import '../../project/data/project_files.dart';
import '../../project/domain/artfoxel_package.dart';
import '../domain/art_project.dart';
import '../domain/project_library.dart';

/// Library actions on project records and folders. Each action reports its
/// outcome in a SnackBar and never leaves the gallery list and the folders
/// disagreeing: the folder is changed first, the list second.
class ProjectActions {
  ProjectActions(this.context, this.ref);
  final BuildContext context;
  final WidgetRef ref;

  void _snack(String m, {SnackBarAction? action}) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(m), action: action, duration: Duration(seconds: action == null ? 4 : 8)));
  }

  Future<List<ArtProject>> _all() => ref.read(projectRepositoryProvider).loadProjects();
  Future<void> _save(List<ArtProject> l) async {
    await ref.read(projectRepositoryProvider).saveProjects(l);
    ref.invalidate(projectsProvider);
  }

  Future<ProjectFiles> _files() => ref.read(projectFilesProvider.future);

  Future<void> rename(ArtProject p) async {
    final ctl = TextEditingController(text: p.name);
    final name = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Rename project'),
        content: TextField(controller: ctl, autofocus: true, maxLength: ArtProject.maxNameLength, decoration: const InputDecoration(hintText: 'Project name')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, ctl.text), child: const Text('Rename')),
        ],
      ),
    );
    ctl.dispose();
    if (name == null) return;
    final clean = ProjectLibrary.cleanName(name);
    if (clean == null) {
      _snack('Please enter a name.');
      return;
    }
    try {
      final all = await _all();
      final unique = ProjectLibrary.uniqueName(clean, [for (final x in all) if (x.id != p.id) x.name]);
      await _save([for (final x in all) x.id == p.id ? x.copyWith(name: unique, updatedAt: DateTime.now()) : x]);
    } catch (e, s) {
      AppLog.error('Rename failed', error: e, stackTrace: s);
      _snack('The project could not be renamed.');
    }
  }

  Future<void> toggleFavorite(ArtProject p) async {
    try {
      final all = await _all();
      await _save([for (final x in all) x.id == p.id ? x.copyWith(favorite: !x.favorite) : x]);
    } catch (_) {
      _snack('Could not update the favourite.');
    }
  }

  Future<void> duplicate(ArtProject p) async {
    try {
      final files = await _files();
      final all = await _all();
      final copy = await files.duplicate(p, existingNames: [for (final x in all) x.name]);
      await _save([copy, ...all]);
      _snack('Duplicated as “${copy.name}”.');
    } on ProjectFileException catch (e) {
      _snack(e.message);
    } catch (e, s) {
      AppLog.error('Duplicate failed', error: e, stackTrace: s);
      _snack('The project could not be duplicated.');
    }
  }

  /// Moves to the trash folder (kept 14 days) with an Undo action.
  Future<void> delete(ArtProject p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Delete “${p.name}”?'),
        content: const Text('It moves to the trash and can be restored right now with Undo, or within 14 days from a backup of the trash folder.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final files = await _files();
      final handle = await files.moveToTrash(p);
      final all = await _all();
      await _save([for (final x in all) if (x.id != p.id) x]);
      _snack('Deleted “${p.name}”.', action: SnackBarAction(label: 'Undo', onPressed: () async {
        try {
          await files.restoreFromTrash(handle);
          final now = await _all();
          await _save([p, ...now.where((x) => x.id != p.id)]);
        } catch (_) {
          _snack('Could not restore the project.');
        }
      }));
    } catch (e, s) {
      AppLog.error('Delete failed', error: e, stackTrace: s);
      _snack('The project could not be deleted.');
    }
  }

  /// Save As: writes a `.artfoxel` package to a place the user chooses.
  Future<void> exportPackage(ArtProject p) async {
    try {
      final files = await _files();
      final bytes = await files.exportPackage(p);
      final safe = p.name.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');
      final path = await FilePicker.platform.saveFile(dialogTitle: 'Save project copy', fileName: '$safe.artfoxel', bytes: bytes);
      if (path != null) _snack('Saved a checked project package (${(bytes.length / 1024).toStringAsFixed(0)} KB).');
    } on ProjectFileException catch (e) {
      _snack(e.message);
    } catch (e, s) {
      AppLog.error('Package export failed', error: e, stackTrace: s);
      _snack('The project package could not be written.');
    }
  }

  Future<void> importPackage() async {
    try {
      final r = await FilePicker.platform.pickFiles(type: FileType.any, withData: true);
      final bytes = r?.files.firstOrNull?.bytes;
      if (bytes == null) return;
      final files = await _files();
      final all = await _all();
      final result = await files.importPackage(bytes, existingNames: [for (final x in all) x.name]);
      await _save([result.project, ...all]);
      final warn = result.issues.isEmpty ? '' : ' ${result.issues.length} optional part(s) were damaged and skipped.';
      final mig = result.migratedFrom == null ? '' : ' Upgraded from format v${result.migratedFrom}.';
      _snack('Imported “${result.project.name}” as a new project.$warn$mig');
    } on ProjectFileException catch (e) {
      _snack(e.message);
    } catch (e, s) {
      AppLog.error('Package import failed', error: e, stackTrace: s);
      _snack('That file could not be imported.');
    }
  }

  Future<void> backupAll() async {
    try {
      final files = await _files();
      final all = await _all();
      if (all.isEmpty) {
        _snack('There is nothing to back up yet.');
        return;
      }
      _snack('Creating backup of ${all.length} project(s)…');
      final bytes = await files.createBackup(all);
      final stamp = DateTime.now().toIso8601String().substring(0, 10);
      final path = await FilePicker.platform.saveFile(dialogTitle: 'Save backup', fileName: 'artfoxel_backup_$stamp.zip', bytes: bytes);
      if (path != null) _snack('Backup saved (${(bytes.length / 1048576).toStringAsFixed(1)} MB).');
    } catch (e, s) {
      AppLog.error('Backup failed', error: e, stackTrace: s);
      _snack('The backup could not be created.');
    }
  }

  Future<void> restoreBackup() async {
    try {
      final r = await FilePicker.platform.pickFiles(type: FileType.any, withData: true);
      final Uint8List? bytes = r?.files.firstOrNull?.bytes;
      if (bytes == null) return;
      final files = await _files();
      final all = await _all();
      final res = await files.restoreBackup(bytes, existing: all);
      await _save([...res.restored, ...all]);
      _snack('Restored ${res.restored.length} project(s) as new copies.${res.skipped.isEmpty ? '' : ' ${res.skipped.length} skipped (damaged).'}');
    } on ProjectFileException catch (e) {
      _snack(e.message);
    } catch (e, s) {
      AppLog.error('Restore failed', error: e, stackTrace: s);
      _snack('That backup could not be restored.');
    }
  }

  void showMenu(ArtProject p) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(title: Text(p.name, style: const TextStyle(fontWeight: FontWeight.bold)), subtitle: Text(_meta(p))),
          ListTile(leading: const Icon(Icons.drive_file_rename_outline), title: const Text('Rename'), onTap: () { Navigator.pop(c); rename(p); }),
          ListTile(leading: Icon(p.favorite ? Icons.star : Icons.star_border), title: Text(p.favorite ? 'Remove from favourites' : 'Add to favourites'), onTap: () { Navigator.pop(c); toggleFavorite(p); }),
          ListTile(leading: const Icon(Icons.copy), title: const Text('Duplicate'), onTap: () { Navigator.pop(c); duplicate(p); }),
          ListTile(leading: const Icon(Icons.save_alt), title: const Text('Save a copy (.artfoxel)'), onTap: () { Navigator.pop(c); exportPackage(p); }),
          ListTile(leading: const Icon(Icons.delete_outline), title: const Text('Delete'), onTap: () { Navigator.pop(c); delete(p); }),
        ]),
      ),
    );
  }

  static String _meta(ArtProject p) {
    final parts = <String>[p.kind];
    if (p.width != null && p.height != null) parts.add('${p.width}×${p.height}');
    if (p.sizeBytes != null) parts.add('${(p.sizeBytes! / 1048576).toStringAsFixed(1)} MB');
    return parts.join(' · ');
  }
}

/// Kind of a record as a [ProjectKind] (used by callers that open studios).
ProjectKind kindOf(ArtProject p) => ProjectKind.fromLabel(p.kind);
