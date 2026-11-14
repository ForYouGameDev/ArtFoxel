import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/workspace_layout.dart';

Future<void> showWorkspaceLayoutSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      maxChildSize: 0.95,
      builder: (context, scroll) => _LayoutSheet(scroll: scroll),
    ),
  );
}

/// Layout, mode and toolbar customisation. Every change is saved at once and
/// applies to both Sketch and Animation Studio.
class _LayoutSheet extends ConsumerWidget {
  const _LayoutSheet({required this.scroll});
  final ScrollController scroll;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final layout = ref.watch(workspaceLayoutProvider);
    final ctl = ref.read(workspaceLayoutProvider.notifier);
    final theme = Theme.of(context);
    return ListView(
      controller: scroll,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
      children: [
        Text('Workspace layout', style: theme.textTheme.titleLarge),
        const SizedBox(height: 8),
        Text('Mode', style: theme.textTheme.titleSmall),
        SegmentedButton<UiMode>(
          segments: [for (final m in UiMode.values) ButtonSegment(value: m, label: Text(m.label))],
          selected: {layout.mode},
          onSelectionChanged: (s) => ctl.update(layout.copyWith(mode: s.first)),
        ),
        Text(
          layout.mode == UiMode.beginner
              ? 'Beginner shows the essential tools only. The rest stay available in menus.'
              : 'Professional shows every tool and brush control.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        Text('Toolbar side', style: theme.textTheme.titleSmall),
        SegmentedButton<ToolbarSide>(
          segments: const [
            ButtonSegment(value: ToolbarSide.left, label: Text('Left (right-handed)')),
            ButtonSegment(value: ToolbarSide.right, label: Text('Right (left-handed)')),
          ],
          selected: {layout.side},
          onSelectionChanged: (s) => ctl.update(layout.copyWith(side: s.first)),
        ),
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Side toolbar'),
          value: layout.showSideBar,
          onChanged: (v) => ctl.update(layout.copyWith(showSideBar: v)),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Bottom panel'),
          value: layout.showBottomPanel && !layout.bottomCollapsed,
          onChanged: (v) => ctl.update(layout.copyWith(showBottomPanel: true, bottomCollapsed: !v)),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Brush quick strip'),
          value: layout.showQuickStrip,
          onChanged: (v) => ctl.update(layout.copyWith(showQuickStrip: v)),
        ),
        const Divider(height: 24),
        Text('Side toolbar tools', style: theme.textTheme.titleSmall),
        Text('Show, hide and reorder. Hidden tools stay reachable from the menus.', style: theme.textTheme.bodySmall),
        for (var i = 0; i < layout.toolOrder.length; i++)
          _toolRow(context, layout, ctl, i),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: ctl.reset,
          icon: const Icon(Icons.restart_alt_rounded),
          label: const Text('Reset layout'),
        ),
      ],
    );
  }

  Widget _toolRow(BuildContext context, WorkspaceLayout layout, WorkspaceLayoutController ctl, int i) {
    final tool = layout.toolOrder[i];
    final hidden = layout.hiddenTools.contains(tool);
    void move(int delta) {
      final order = [...layout.toolOrder];
      final j = i + delta;
      if (j < 0 || j >= order.length) return;
      final t = order.removeAt(i);
      order.insert(j, t);
      ctl.update(layout.copyWith(toolOrder: order));
    }

    return Row(children: [
      Checkbox(
        value: !hidden,
        onChanged: (v) {
          final next = {...layout.hiddenTools};
          if (v == true) {
            next.remove(tool);
          } else {
            next.add(tool);
          }
          ctl.update(layout.copyWith(hiddenTools: next));
        },
      ),
      Expanded(child: Text(tool.label)),
      IconButton(tooltip: 'Move up', onPressed: i == 0 ? null : () => move(-1), icon: const Icon(Icons.arrow_upward_rounded)),
      IconButton(
        tooltip: 'Move down',
        onPressed: i == layout.toolOrder.length - 1 ? null : () => move(1),
        icon: const Icon(Icons.arrow_downward_rounded),
      ),
    ]);
  }
}
