import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/design_tokens.dart';
import '../application/brush_library_controller.dart';
import '../application/sketch_controller.dart';
import '../domain/brush_preset.dart';
import '../domain/builtin_brushes.dart';
import 'brush_preview.dart';
import 'brush_quick_strip.dart';

Future<void> showBrushPicker(
  BuildContext context,
  SketchController controller,
) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.95,
      minChildSize: 0.4,
      builder: (context, scrollController) => _BrushPickerSheet(
        controller: controller,
        scrollController: scrollController,
      ),
    ),
  );
}

class _BrushPickerSheet extends ConsumerStatefulWidget {
  const _BrushPickerSheet({
    required this.controller,
    required this.scrollController,
  });

  final SketchController controller;
  final ScrollController scrollController;

  @override
  ConsumerState<_BrushPickerSheet> createState() => _BrushPickerSheetState();
}

class _BrushPickerSheetState extends ConsumerState<_BrushPickerSheet> {
  BrushCategory? _category;
  bool _favoritesOnly = false;

  @override
  Widget build(BuildContext context) {
    final library = ref.watch(brushLibraryProvider).valueOrNull;
    final all = library?.all ?? BuiltInBrushes.all;
    final favorites = library?.favorites ?? const <String>{};
    final shown = all.where((brush) {
      if (_favoritesOnly && !favorites.contains(brush.id)) return false;
      return _category == null || brush.category == _category;
    }).toList();
    final selected = widget.controller.brush;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: ArtFoxelSpacing.lg),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Brushes',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              TextButton.icon(
                onPressed: () {
                  Navigator.of(context).pop();
                  context.push('/brush-lab');
                },
                icon: const Icon(Icons.science_outlined),
                label: const Text('Brush Lab'),
              ),
            ],
          ),
        ),
        BrushQuickStrip(controller: widget.controller, compact: true),
        const Divider(height: 1),
        SizedBox(
          height: 48,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: ArtFoxelSpacing.lg),
            children: [
              _chip('All', _category == null && !_favoritesOnly, () {
                setState(() {
                  _category = null;
                  _favoritesOnly = false;
                });
              }),
              _chip('Favorites', _favoritesOnly, () {
                setState(() {
                  _favoritesOnly = !_favoritesOnly;
                  _category = null;
                });
              }),
              for (final category in BrushCategory.values)
                _chip(category.label, _category == category, () {
                  setState(() {
                    _category = category;
                    _favoritesOnly = false;
                  });
                }),
            ],
          ),
        ),
        Expanded(
          child: shown.isEmpty
              ? const Center(child: Text('No brushes match this filter.'))
              : ListView.builder(
                  controller: widget.scrollController,
                  padding: const EdgeInsets.all(ArtFoxelSpacing.md),
                  itemCount: shown.length,
                  itemBuilder: (context, index) {
                    final brush = shown[index];
                    return Card(
                      margin: const EdgeInsets.only(bottom: ArtFoxelSpacing.xs),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                        side: BorderSide(
                          color: brush.id == selected.id
                              ? Theme.of(context).colorScheme.primary
                              : Colors.transparent,
                          width: 2,
                        ),
                      ),
                      child: ListTile(
                        leading: BrushPreview(brush: brush),
                        title: Text(brush.name),
                        subtitle: Text(
                          '${brush.category.label} · ${brush.engine.label}',
                        ),
                        trailing: favorites.contains(brush.id)
                            ? const Icon(Icons.star_rounded)
                            : null,
                        onTap: () {
                          widget.controller.selectBrush(brush);
                          Navigator.of(context).pop();
                        },
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _chip(String label, bool selected, VoidCallback onTap) => Padding(
        padding: const EdgeInsets.only(right: ArtFoxelSpacing.xs),
        child: ChoiceChip(
          label: Text(label),
          selected: selected,
          onSelected: (_) => onTap(),
        ),
      );
}
