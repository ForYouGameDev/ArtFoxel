import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/design_tokens.dart';
import '../../../core/widgets/artfoxel_components.dart';
import '../application/brush_library_controller.dart';
import '../data/brush_library_repository.dart';
import '../domain/brush_codec.dart';
import '../domain/brush_preset.dart';
import 'brush_editor.dart';
import 'brush_preview.dart';

/// Brush Lab: browse, create, edit, import and export brushes.
class BrushLabScreen extends ConsumerStatefulWidget {
  const BrushLabScreen({super.key});

  @override
  ConsumerState<BrushLabScreen> createState() => _BrushLabScreenState();
}

class _BrushLabScreenState extends ConsumerState<BrushLabScreen> {
  static const double _wideBreakpoint = 900;

  final _search = TextEditingController();
  BrushCategory? _category;
  bool _favoritesOnly = false;
  String? _selectedId;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  List<BrushPreset> _filtered(BrushLibraryData data) {
    final query = _search.text.trim().toLowerCase();
    return [
      for (final preset in data.all)
        if ((_category == null || preset.category == _category) &&
            (!_favoritesOnly || data.favorites.contains(preset.id)) &&
            (query.isEmpty ||
                preset.name.toLowerCase().contains(query) ||
                (data.groups[preset.id] ?? '').toLowerCase().contains(query)))
          preset,
    ];
  }

  void _open(String id, bool wide) {
    if (wide) {
      setState(() => _selectedId = id);
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => Scaffold(
          appBar: AppBar(title: const Text('Edit brush')),
          body: BrushEditor(key: ValueKey(id), brushId: id),
        ),
      ),
    );
  }

  Future<void> _create(bool wide) async {
    try {
      final preset =
          await ref.read(brushLibraryProvider.notifier).createNew();
      if (mounted) _open(preset.id, wide);
    } catch (_) {
      _message('The brush could not be created.');
    }
  }

  Future<void> _duplicate(BrushPreset preset, bool wide) async {
    final copy =
        await ref.read(brushLibraryProvider.notifier).duplicate(preset.id);
    if (copy != null && mounted) _open(copy.id, wide);
  }

  Future<void> _delete(BrushPreset preset) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete brush?'),
        content: Text('"${preset.name}" will be removed from your library. '
            'Strokes already drawn with it keep their look.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(brushLibraryProvider.notifier).delete(preset.id);
    if (_selectedId == preset.id) setState(() => _selectedId = null);
  }

  Future<void> _export(List<BrushPreset> presets, String label) async {
    if (presets.isEmpty) {
      _message('There are no custom brushes to export yet.');
      return;
    }
    final text = BrushCodec.exportPresets(presets, name: 'ARTFOXEL brushes');
    await Clipboard.setData(ClipboardData(text: text));
    _message('$label copied to the clipboard as JSON. Paste it into a file '
        'to share or back it up.');
  }

  Future<void> _import() async {
    final controller = TextEditingController();
    final library = ref.read(brushLibraryProvider).valueOrNull;
    final names = library?.all.map((p) => p.name).toList() ?? const <String>[];
    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Import brushes'),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Paste brush JSON exported from ARTFOXEL. Brushes '
                  'are data only; nothing is run and no files are read.'),
              const SizedBox(height: ArtFoxelSpacing.sm),
              TextField(
                controller: controller,
                minLines: 6,
                maxLines: 10,
                decoration:
                    const InputDecoration(hintText: '{"format":"artfoxel-brush-set", …}'),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () async {
                    final data = await Clipboard.getData(Clipboard.kTextPlain);
                    if (data?.text != null) controller.text = data!.text!;
                  },
                  icon: const Icon(Icons.content_paste_rounded),
                  label: const Text('Paste from clipboard'),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Import'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (text == null || text.trim().isEmpty) return;
    try {
      final result = BrushCodec.import(text, existingNames: names);
      await ref.read(brushLibraryProvider.notifier).addImported(result.presets);
      if (!mounted) return;
      final buffer = StringBuffer(
        'Imported ${result.presets.length} brush'
        '${result.presets.length == 1 ? '' : 'es'}.',
      );
      if (result.renamed > 0) buffer.write(' ${result.renamed} renamed.');
      if (result.migrated > 0) {
        buffer.write(' ${result.migrated} upgraded from an older format.');
      }
      if (result.errors.isNotEmpty) {
        buffer.write(' ${result.errors.length} skipped.');
      }
      _message(buffer.toString());
      if (result.errors.isNotEmpty) {
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Some brushes were skipped'),
            content: SingleChildScrollView(
              child: Text(result.errors.join('\n\n')),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }
    } on BrushImportException catch (error) {
      _message(error.message);
    } catch (_) {
      _message('That text could not be imported.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final library = ref.watch(brushLibraryProvider);
    final wide = MediaQuery.sizeOf(context).width >= _wideBreakpoint;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Brush Lab'),
        actions: [
          IconButton(
            tooltip: 'Import brushes',
            onPressed: _import,
            icon: const Icon(Icons.file_download_outlined),
          ),
          PopupMenuButton<String>(
            tooltip: 'Export',
            icon: const Icon(Icons.ios_share_rounded),
            onSelected: (value) {
              final data = library.valueOrNull;
              if (data == null) return;
              if (value == 'all') {
                _export(data.user, 'All custom brushes');
              } else if (_selectedId != null) {
                final preset = data.byId(_selectedId!);
                if (preset != null && !preset.isBuiltIn) {
                  _export([preset], '"${preset.name}"');
                } else {
                  _message('Select one of your own brushes to export it.');
                }
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'all', child: Text('Export all custom brushes')),
              PopupMenuItem(value: 'one', child: Text('Export selected brush')),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _create(wide),
        icon: const Icon(Icons.add_rounded),
        label: const Text('New brush'),
      ),
      body: library.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stack) => EmptyState(
          icon: Icons.error_outline_rounded,
          title: 'Brushes could not be loaded',
          message: '$error',
          action: FilledButton(
            onPressed: () => ref.read(brushLibraryProvider.notifier).reload(),
            child: const Text('Try again'),
          ),
        ),
        data: (data) {
          final list = _buildList(data, wide);
          if (!wide) return list;
          return Row(
            children: [
              SizedBox(width: 380, child: list),
              const VerticalDivider(width: 1),
              Expanded(
                child: _selectedId == null
                    ? const Center(child: Text('Select a brush to edit or test it.'))
                    : BrushEditor(
                        key: ValueKey(_selectedId),
                        brushId: _selectedId!,
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildList(BrushLibraryData data, bool wide) {
    final items = _filtered(data);
    return Column(
      children: [
        if (data.recoveredFromCorruption || data.skippedOnLoad > 0)
          MaterialBanner(
            content: Text(
              data.recoveredFromCorruption
                  ? 'Your brush library was damaged. A copy of the damaged '
                      'data was kept and the library was restored.'
                  : '${data.skippedOnLoad} saved brush'
                      '${data.skippedOnLoad == 1 ? ' was' : 'es were'} '
                      'invalid and set aside (not deleted).',
            ),
            actions: const [SizedBox.shrink()],
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
              ArtFoxelSpacing.md, ArtFoxelSpacing.sm, ArtFoxelSpacing.md, 0),
          child: TextField(
            controller: _search,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search_rounded),
              hintText: 'Search brushes or groups',
            ),
          ),
        ),
        SizedBox(
          height: 52,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(
                horizontal: ArtFoxelSpacing.md, vertical: ArtFoxelSpacing.xs),
            children: [
              FilterChip(
                label: const Text('Favorites'),
                selected: _favoritesOnly,
                onSelected: (v) => setState(() => _favoritesOnly = v),
              ),
              for (final category in BrushCategory.values)
                Padding(
                  padding: const EdgeInsets.only(left: ArtFoxelSpacing.xs),
                  child: FilterChip(
                    label: Text(category.label),
                    selected: _category == category,
                    onSelected: (v) =>
                        setState(() => _category = v ? category : null),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: items.isEmpty
              ? const EmptyState(
                  icon: Icons.brush_outlined,
                  title: 'No brushes match',
                  message: 'Try another search or clear the filters.',
                )
              : ListView.builder(
                  padding: const EdgeInsets.only(bottom: 88),
                  itemCount: items.length,
                  itemBuilder: (context, index) =>
                      _tile(items[index], data, wide),
                ),
        ),
      ],
    );
  }

  Widget _tile(BrushPreset preset, BrushLibraryData data, bool wide) {
    final favorite = data.favorites.contains(preset.id);
    final group = data.groups[preset.id];
    return ListTile(
      selected: wide && _selectedId == preset.id,
      leading: BrushPreview(brush: preset, width: 72, height: 36),
      title: Text(preset.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text([
        preset.category.label,
        if (preset.isBuiltIn) 'Built-in',
        if (group != null) group,
      ].join(' · ')),
      onTap: () => _open(preset.id, wide),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: favorite ? 'Remove favorite' : 'Add favorite',
            onPressed: () =>
                ref.read(brushLibraryProvider.notifier).toggleFavorite(preset.id),
            icon: Icon(favorite ? Icons.star_rounded : Icons.star_border_rounded),
          ),
          PopupMenuButton<String>(
            onSelected: (value) {
              switch (value) {
                case 'duplicate':
                  _duplicate(preset, wide);
                case 'group':
                  _editGroup(preset, group);
                case 'delete':
                  _delete(preset);
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(value: 'duplicate', child: Text('Duplicate')),
              const PopupMenuItem(value: 'group', child: Text('Set group…')),
              if (!preset.isBuiltIn)
                const PopupMenuItem(value: 'delete', child: Text('Delete')),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _editGroup(BrushPreset preset, String? current) async {
    final controller = TextEditingController(text: current ?? '');
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Brush group'),
        content: TextField(
          controller: controller,
          maxLength: 32,
          decoration: const InputDecoration(hintText: 'e.g. Inking (empty = none)'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value == null) return;
    await ref.read(brushLibraryProvider.notifier).setGroup(preset.id, value);
  }
}
