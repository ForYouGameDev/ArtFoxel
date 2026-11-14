import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/theme/design_tokens.dart';
import '../application/sketch_controller.dart';
import '../application/studio_libraries.dart';
import '../filters/filter_engine.dart';

/// Opens the filter editor on the active layer. Changes are previewed live
/// on the canvas; nothing is kept until Apply, and Cancel restores the layer.
Future<void> showFilterStudio(BuildContext context, SketchController controller) async {
  final ok = await controller.beginFilterSession();
  if (!ok || !context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    isDismissible: false,
    enableDrag: false,
    barrierColor: Colors.transparent,
    builder: (context) => FilterPanel(controller: controller),
  );
  // Closed some other way (back button): never leave a half-open session.
  controller.cancelFilterSession();
}

class FilterPanel extends StatefulWidget {
  const FilterPanel({required this.controller, super.key});
  final SketchController controller;

  @override
  State<FilterPanel> createState() => _FilterPanelState();
}

class _FilterPanelState extends State<FilterPanel> {
  late final StudioLibraries _libs = StudioLibraries(SharedPreferences.getInstance());
  List<FilterPreset> _user = [];

  SketchController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    _libs.loadFilterPresets().then((p) {
      if (mounted) setState(() => _user = p);
    });
  }

  void _msg(String t) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(t)));

  Future<void> _addFilter() async {
    final id = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        builder: (context, scroll) => ListView(
          controller: scroll,
          children: [
            for (final cat in FilterCategory.values) ...[
              Padding(padding: const EdgeInsets.fromLTRB(16, 12, 16, 4), child: Text(cat.label, style: Theme.of(context).textTheme.titleSmall)),
              for (final f in FilterRegistry.inCategory(cat))
                ListTile(
                  dense: true,
                  title: Text(f.label),
                  subtitle: f.approximation == null ? null : Text('Approximation: ${f.approximation}'),
                  onTap: () => Navigator.pop(context, f.id),
                ),
            ],
          ],
        ),
      ),
    );
    if (id != null) c.addFilter(id);
  }

  Future<void> _savePreset() async {
    final s = c.filterSession;
    if (s == null || s.ops.isEmpty) return;
    final ctl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Save filter preset'),
        content: TextField(controller: ctl, autofocus: true, maxLength: 40, decoration: const InputDecoration(labelText: 'Name')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, ctl.text.trim()), child: const Text('Save')),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    final next = [..._user.where((p) => p.name != name), FilterPreset(name, List.of(s.ops))];
    try {
      await _libs.saveFilterPresets(next);
      setState(() => _user = next);
    } catch (e) {
      _msg('$e');
    }
  }

  Widget _opCard(BuildContext context, int i, FilterOp op) {
    final spec = FilterRegistry.byId(op.id)!;
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Switch(value: op.enabled, onChanged: (_) => c.toggleFilter(i)),
            Expanded(child: Text(spec.label, style: theme.textTheme.titleSmall)),
            IconButton(tooltip: 'Move up', icon: const Icon(Icons.arrow_upward, size: 20), onPressed: i == 0 ? null : () => c.moveFilter(i, -1)),
            IconButton(tooltip: 'Move down', icon: const Icon(Icons.arrow_downward, size: 20), onPressed: () => c.moveFilter(i, 1)),
            IconButton(tooltip: 'Reset values', icon: const Icon(Icons.restart_alt, size: 20), onPressed: () => c.resetFilterParams(i)),
            IconButton(tooltip: 'Remove', icon: const Icon(Icons.close, size: 20), onPressed: () => c.removeFilter(i)),
          ]),
          if (spec.approximation != null)
            Padding(
              padding: const EdgeInsets.only(left: 8, bottom: 4),
              child: Text('Approximation: ${spec.approximation}', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.tertiary)),
            ),
          if (op.enabled)
            for (final p in spec.params)
              Row(children: [
                SizedBox(width: 110, child: Text(p.label, style: theme.textTheme.bodySmall)),
                Expanded(
                  child: Slider(
                    value: (op.params[p.key] ?? p.def).clamp(p.min, p.max).toDouble(),
                    min: p.min,
                    max: p.max,
                    onChanged: (v) => c.setFilterParam(i, p.key, v),
                  ),
                ),
                SizedBox(width: 48, child: Text((op.params[p.key] ?? p.def).toStringAsFixed(p.digits), textAlign: TextAlign.end, style: theme.textTheme.labelSmall)),
              ]),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final height = MediaQuery.of(context).size.height;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final s = c.filterSession;
        if (s == null) return const SizedBox(height: 1);
        final presets = [...FilterPresets.builtIn, ..._user];
        return SizedBox(
          height: height * 0.5,
          child: Material(
            child: Column(children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(children: [
                  TextButton(
                    onPressed: () {
                      c.cancelFilterSession();
                      Navigator.pop(context);
                    },
                    child: const Text('Cancel'),
                  ),
                  const Spacer(),
                  Tooltip(
                    message: 'Hold to compare with the original',
                    child: FilterChip(
                      label: const Text('Before'),
                      selected: s.showOriginal,
                      onSelected: c.setShowOriginal,
                    ),
                  ),
                  const SizedBox(width: 8),
                  PopupMenuButton<bool>(
                    tooltip: 'Apply options',
                    onSelected: (destructive) async {
                      final done = await c.commitFilterSession(destructive: destructive);
                      if (done && context.mounted) Navigator.pop(context);
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: false, child: Text('Apply (keep editable)')),
                      PopupMenuItem(value: true, child: Text('Apply permanently (replaces pixels)')),
                    ],
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      child: Text('Apply ▾', style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.primary, fontWeight: FontWeight.w800)),
                    ),
                  ),
                ]),
              ),
              ValueListenableBuilder<double?>(
                valueListenable: c.filterProgress,
                builder: (context, v, _) => v == null ? const SizedBox(height: 4) : LinearProgressIndicator(value: v, minHeight: 4),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(ArtFoxelSpacing.md, 4, ArtFoxelSpacing.md, ArtFoxelSpacing.xl),
                  children: [
                    Row(children: [
                      FilledButton.tonalIcon(onPressed: _addFilter, icon: const Icon(Icons.add), label: const Text('Add filter')),
                      const SizedBox(width: 8),
                      OutlinedButton(onPressed: s.ops.isEmpty ? null : _savePreset, child: const Text('Save preset')),
                      const Spacer(),
                      Text('${s.ops.length}/64', style: theme.textTheme.labelSmall),
                    ]),
                    SizedBox(
                      height: 44,
                      child: ListView(scrollDirection: Axis.horizontal, children: [
                        for (final p in presets)
                          Padding(
                            padding: const EdgeInsets.only(right: 6, top: 6),
                            child: ActionChip(label: Text(p.name), onPressed: () => c.applyFilterPreset(p)),
                          ),
                      ]),
                    ),
                    if (s.ops.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Text('No filters yet. Add one or pick a preset. The original pixels stay untouched until you apply permanently.')),
                    for (var i = 0; i < s.ops.length; i++) _opCard(context, i, s.ops[i]),
                    if (c.filterHistory.entries.isNotEmpty) ...[
                      const Divider(),
                      Text('Filter history (this session)', style: theme.textTheme.titleSmall),
                      for (final e in c.filterHistory.entries.reversed.take(8)) Text('• $e', style: theme.textTheme.bodySmall),
                    ],
                  ],
                ),
              ),
            ]),
          ),
        );
      },
    );
  }
}
