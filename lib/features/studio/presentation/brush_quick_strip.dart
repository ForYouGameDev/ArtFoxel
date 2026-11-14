import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/brush_library_controller.dart';
import '../application/sketch_controller.dart';
import '../data/brush_library_repository.dart';
import '../domain/brush_preset.dart';
import 'brush_preview.dart';

enum QuickTab {
  featured('Featured'),
  recommended('Recommended'),
  recent('Recent'),
  favorites('Favorites'),
  custom('Custom');

  const QuickTab(this.label);
  final String label;
}

/// Horizontally scrolling brush shortcuts. Previews are drawn by the real
/// brush engines. Slots in Featured can be pinned, unpinned and reordered;
/// the layout is saved with the brush library.
class BrushQuickStrip extends ConsumerStatefulWidget {
  const BrushQuickStrip({
    required this.controller,
    this.onOpenLibrary,
    this.compact = false,
    super.key,
  });

  final SketchController controller;
  final VoidCallback? onOpenLibrary;
  final bool compact;

  @override
  ConsumerState<BrushQuickStrip> createState() => _BrushQuickStripState();
}

class _BrushQuickStripState extends ConsumerState<BrushQuickStrip> {
  QuickTab _tab = QuickTab.featured;
  String? _lastRecorded;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onController);
  }

  @override
  void didUpdateWidget(BrushQuickStrip old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_onController);
      widget.controller.addListener(_onController);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onController);
    super.dispose();
  }

  void _onController() {
    final id = widget.controller.brush.id;
    if (id == _lastRecorded) return;
    _lastRecorded = id;
    // Never write to storage from inside a notification.
    Future.microtask(() {
      if (mounted) ref.read(brushLibraryProvider.notifier).noteUsed(id);
    });
  }

  List<BrushPreset> _list(BrushLibraryData data) => switch (_tab) {
        QuickTab.featured => data.pinnedBrushes,
        QuickTab.recommended => data.recommendedBrushes,
        QuickTab.recent => data.recentBrushes,
        QuickTab.favorites => data.favoriteBrushes,
        QuickTab.custom => data.user,
      };

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(brushLibraryProvider).valueOrNull ?? const BrushLibraryData();
    final items = _list(data);
    final selected = widget.controller.brush.id;
    final theme = Theme.of(context);
    final h = widget.compact ? 40.0 : 52.0;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      SizedBox(
        height: 34,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          children: [
            for (final tab in QuickTab.values)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ChoiceChip(
                  visualDensity: VisualDensity.compact,
                  label: Text(tab.label, style: const TextStyle(fontSize: 12)),
                  selected: _tab == tab,
                  onSelected: (_) => setState(() => _tab = tab),
                ),
              ),
            if (widget.onOpenLibrary != null)
              ActionChip(
                visualDensity: VisualDensity.compact,
                avatar: const Icon(Icons.grid_view_rounded, size: 16),
                label: const Text('All brushes', style: TextStyle(fontSize: 12)),
                onPressed: widget.onOpenLibrary,
              ),
          ],
        ),
      ),
      SizedBox(
        height: h + 22,
        child: items.isEmpty
            ? Center(
                child: Text(
                  switch (_tab) {
                    QuickTab.favorites => 'Long-press a brush and choose "Add to favorites".',
                    QuickTab.recent => 'Brushes you use appear here.',
                    QuickTab.custom => 'Brushes you make in Brush Lab appear here.',
                    _ => 'Nothing here yet.',
                  },
                  style: theme.textTheme.bodySmall,
                ),
              )
            : ListView.builder(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                itemCount: items.length,
                itemBuilder: (context, i) {
                  final brush = items[i];
                  final isSel = brush.id == selected;
                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: GestureDetector(
                      onLongPress: () => _menuWithActions(context, brush, data),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () {
                          widget.controller.selectBrush(brush);
                          setState(() {});
                        },
                        child: Container(
                          padding: const EdgeInsets.all(2),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: isSel ? theme.colorScheme.primary : Colors.transparent,
                              width: 2,
                            ),
                          ),
                          child: Column(mainAxisSize: MainAxisSize.min, children: [
                            RepaintBoundary(child: BrushPreview(brush: brush, width: 84, height: h - 8)),
                            SizedBox(
                              width: 84,
                              child: Text(
                                brush.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.center,
                                style: const TextStyle(fontSize: 11),
                              ),
                            ),
                          ]),
                        ),
                      ),
                    ),
                  );
                },
              ),
      ),
    ]);
  }

  Future<void> _menuWithActions(BuildContext context, BrushPreset brush, BrushLibraryData data) async {
    final pinned = (data.pinned ?? BrushLibraryData.defaultPinned).contains(brush.id);
    final fav = data.favorites.contains(brush.id);
    final lib = ref.read(brushLibraryProvider.notifier);
    Future<void> run(Future<void> Function() action) async {
      Navigator.of(context).pop();
      try {
        await action();
      } on BrushPresetException catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
        }
      }
    }

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(title: Text(brush.name), subtitle: Text('${brush.category.label} · ${brush.engine.label}')),
          ListTile(
            leading: Icon(pinned ? Icons.push_pin_outlined : Icons.push_pin),
            title: Text(pinned ? 'Unpin from quick strip' : 'Pin to quick strip'),
            onTap: () => run(() => pinned ? lib.unpin(brush.id) : lib.pin(brush.id)),
          ),
          if (pinned) ...[
            ListTile(leading: const Icon(Icons.arrow_back), title: const Text('Move left'), onTap: () => run(() => lib.movePinned(brush.id, -1))),
            ListTile(leading: const Icon(Icons.arrow_forward), title: const Text('Move right'), onTap: () => run(() => lib.movePinned(brush.id, 1))),
          ],
          ListTile(
            leading: Icon(fav ? Icons.star : Icons.star_border),
            title: Text(fav ? 'Remove favorite' : 'Add to favorites'),
            onTap: () => run(() => lib.toggleFavorite(brush.id)),
          ),
          ListTile(
            leading: const Icon(Icons.restart_alt),
            title: const Text('Reset quick strip to featured'),
            onTap: () => run(lib.resetPinned),
          ),
        ]),
      ),
    );
  }
}
