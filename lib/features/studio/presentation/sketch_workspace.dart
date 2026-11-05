import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/providers.dart';
import '../../../core/diagnostics/app_log.dart';
import '../../../core/theme/design_tokens.dart';
import '../../../core/widgets/artfoxel_components.dart';
import '../../../core/widgets/unsaved_work_guard.dart';
import '../../projects/data/project_repository.dart';
import '../../projects/domain/art_project.dart';
import '../application/sketch_controller.dart';
import '../application/sketch_providers.dart';
import '../application/studio_settings.dart';
import '../data/sketch_storage.dart';
import '../domain/canvas_document.dart';
import '../domain/sketch_document_data.dart';
import 'sketch_canvas_stage.dart';
import 'sketch_tool_dock.dart';
import 'studio_settings_sheet.dart';

/// The Sketch Studio screen: canvas, tools, undo/redo and save state.
///
/// With a [projectId] the drawing is loaded from and autosaved to local
/// storage (with crash recovery). Without one it is an unsaved scratch canvas.
class SketchWorkspace extends ConsumerStatefulWidget {
  const SketchWorkspace({this.projectId, this.canvasDocument, super.key});

  final String? projectId;
  final CanvasDocument? canvasDocument;

  @override
  ConsumerState<SketchWorkspace> createState() => _SketchWorkspaceState();
}

class _SketchWorkspaceState extends ConsumerState<SketchWorkspace>
    with WidgetsBindingObserver {
  SketchController? _controller;
  Object? _loadError;
  bool _loading = false;
  ProjectRepository? _projects;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _projects = ref.read(projectRepositoryProvider);
    if (widget.projectId == null) {
      _controller = _buildController(
        SketchDocumentData.blank(
          widget.canvasDocument ?? CanvasDocument.defaultPortrait,
        ),
      );
    } else {
      unawaited(_load());
    }
  }

  SketchController _buildController(
    SketchDocumentData document, {
    SketchStorage? storage,
    bool startDirty = false,
  }) {
    final projectId = widget.projectId;
    final controller = SketchController(
      data: document,
      startDirty: startDirty,
      onSave: storage == null || projectId == null
          ? null
          : (doc) async {
              await storage.save(projectId, doc);
              await _touchProject(projectId, doc.updatedAt);
            },
      onCheckpoint: storage == null || projectId == null
          ? null
          : (doc) => storage.writeCheckpoint(projectId, doc),
    );
    final settings = ref.read(studioSettingsProvider);
    controller.lowLatency = settings.lowLatency;
    return controller;
  }

  Future<void> _touchProject(String projectId, DateTime time) async {
    try {
      final repository = _projects;
      if (repository == null) return;
      final projects = await repository.loadProjects();
      await repository.saveProjects([
        for (final project in projects)
          project.id == projectId
              ? ArtProject(
                  id: project.id,
                  name: project.name,
                  kind: project.kind,
                  updatedAt: time,
                )
              : project,
      ]);
      if (mounted) ref.invalidate(projectsProvider);
    } catch (error, stack) {
      // The drawing itself was saved; only the gallery timestamp failed.
      AppLog.error('Project timestamp update failed',
          error: error, stackTrace: stack);
    }
  }

  Future<void> _load() async {
    final projectId = widget.projectId!;
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final storage = await ref.read(sketchStorageProvider.future);
      final result = await storage.load(projectId);
      if (!mounted) return;
      final document = result.document ??
          SketchDocumentData.blank(
            widget.canvasDocument ?? CanvasDocument.defaultPortrait,
          );
      final controller = _buildController(
        document,
        storage: storage,
        // New projects are written immediately; recovered ones must be
        // saved again to become the clean copy.
        startDirty: result.document == null || result.recoveredFromCheckpoint,
      );
      setState(() {
        _controller = controller;
        _loading = false;
      });
      if (result.recoveredFromCheckpoint) {
        _snack('Recovered your unsaved work from the last session.');
      } else if (result.usedBackup) {
        _snack('The latest save was damaged, so the previous save was opened.');
      }
    } catch (error, stack) {
      AppLog.error('Sketch load failed', error: error, stackTrace: stack);
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = error;
      });
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      unawaited(_controller?.saveNow());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    final controller = _controller;
    if (controller != null) {
      // Flush the last edits before the controller goes away.
      unawaited(controller.saveNow().whenComplete(controller.dispose));
    }
    super.dispose();
  }

  Future<void> _leave() async {
    await _controller?.saveNow();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<StudioSettings>(studioSettingsProvider, (previous, next) {
      _controller?.setLowLatency(next.lowLatency);
    });
    final controller = _controller;

    if (controller == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Sketch Studio')),
        body: _loadError != null
            ? EmptyState(
                icon: Icons.error_outline_rounded,
                title: 'This project could not be opened',
                message: '$_loadError',
                action: FilledButton(
                  onPressed: _load,
                  child: const Text('Try again'),
                ),
              )
            : const Center(child: CircularProgressIndicator()),
      );
    }
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final persisted = widget.projectId != null;
    final settings = ref.watch(studioSettingsProvider);

    final scaffold = Scaffold(
      appBar: AppBar(
        title: const Text('Sketch Studio'),
        actions: [
          if (persisted) _SaveIndicator(controller: controller),
          ListenableBuilder(
            listenable: controller,
            builder: (context, _) => Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: 'Undo',
                  onPressed: controller.canUndo ? controller.undo : null,
                  icon: const Icon(Icons.undo_rounded),
                ),
                IconButton(
                  tooltip: 'Redo',
                  onPressed: controller.canRedo ? controller.redo : null,
                  icon: const Icon(Icons.redo_rounded),
                ),
              ],
            ),
          ),
          PopupMenuButton<String>(
            tooltip: 'More',
            onSelected: (value) {
              switch (value) {
                case 'lab':
                  context.push('/brush-lab');
                case 'settings':
                  showStudioSettingsSheet(context, controller);
                case 'save':
                  unawaited(controller.saveNow());
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(value: 'lab', child: Text('Brush Lab')),
              const PopupMenuItem(
                value: 'settings',
                child: Text('Brush & gesture settings'),
              ),
              if (persisted)
                const PopupMenuItem(value: 'save', child: Text('Save now')),
            ],
          ),
        ],
      ),
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  ArtFoxelSpacing.sm,
                  ArtFoxelSpacing.xs,
                  ArtFoxelSpacing.sm,
                  ArtFoxelSpacing.xs,
                ),
                child: SketchCanvasStage(
                  document: controller.data.toCanvasDocument(),
                  inputSettings: settings.input,
                  controller: controller,
                  onColorSampled: (color) {
                    if (color == null) {
                      _snack('Nothing to pick there (transparent or outside).');
                    }
                  },
                ),
              ),
            ),
            SketchToolDock(controller: controller),
          ],
        ),
      ),
    );

    if (persisted) {
      // Saves before leaving instead of asking to discard.
      return PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, result) {
          if (!didPop) unawaited(_leave());
        },
        child: scaffold,
      );
    }
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => UnsavedWorkGuard(
        hasUnsavedChanges: controller.strokes.isNotEmpty,
        child: scaffold,
      ),
    );
  }
}

class _SaveIndicator extends StatelessWidget {
  const _SaveIndicator({required this.controller});

  final SketchController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final scheme = Theme.of(context).colorScheme;
        final (icon, label, color) = switch (controller.saveState) {
          SaveState.saved => (
              Icons.cloud_done_outlined,
              'Saved',
              scheme.onSurfaceVariant
            ),
          SaveState.dirty => (
              Icons.edit_outlined,
              'Unsaved',
              scheme.onSurfaceVariant
            ),
          SaveState.saving => (
              Icons.sync_rounded,
              'Saving…',
              scheme.onSurfaceVariant
            ),
          SaveState.error => (
              Icons.error_outline_rounded,
              'Save failed · retrying',
              scheme.error
            ),
        };
        return Tooltip(
          message: label,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 18, color: color),
                const SizedBox(width: 4),
                Text(
                  label,
                  key: const ValueKey('save-state'),
                  style: Theme.of(context)
                      .textTheme
                      .labelSmall
                      ?.copyWith(color: color),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
