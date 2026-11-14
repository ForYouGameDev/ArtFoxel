import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/design_tokens.dart';
import '../application/brush_library_controller.dart';
import '../domain/brush_preset.dart';
import 'brush_test_canvas.dart';
import 'pressure_curve_editor.dart';

/// Edits one brush with a live test canvas. Every change is written to the
/// library as soon as it is made; "Reset" returns to how the brush looked
/// when the editor was opened. Built-in brushes are shown read-only.
class BrushEditor extends ConsumerStatefulWidget {
  const BrushEditor({required this.brushId, super.key});

  final String brushId;

  @override
  ConsumerState<BrushEditor> createState() => _BrushEditorState();
}

class _BrushEditorState extends ConsumerState<BrushEditor> {
  BrushPreset? _saved;
  BrushPreset? _working;
  late final TextEditingController _name;

  @override
  void initState() {
    super.initState();
    final preset =
        ref.read(brushLibraryProvider).valueOrNull?.byId(widget.brushId);
    _saved = preset;
    _working = preset;
    _name = TextEditingController(text: preset?.name ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  void _apply(Map<String, Object?> changes, {bool persist = true}) {
    final current = _working;
    if (current == null || current.isBuiltIn) return;
    try {
      final next = current.withChanges(changes);
      setState(() => _working = next);
      if (persist) _persist(next);
    } on BrushPresetException catch (error) {
      _message(error.message);
    }
  }

  Future<void> _persist(BrushPreset preset) async {
    try {
      await ref.read(brushLibraryProvider.notifier).upsert(preset);
    } catch (_) {
      _message('The brush could not be saved. Please try again.');
    }
  }

  Future<void> _rename(String value) async {
    final current = _working;
    if (current == null || current.isBuiltIn) return;
    try {
      await ref.read(brushLibraryProvider.notifier).rename(current.id, value);
      final updated = ref
          .read(brushLibraryProvider)
          .valueOrNull
          ?.byId(current.id);
      if (updated != null && mounted) {
        setState(() => _working = updated);
        _name.text = updated.name;
      }
    } on BrushPresetException catch (error) {
      _message(error.message);
    }
  }

  void _reset() {
    final saved = _saved;
    if (saved == null) return;
    setState(() => _working = saved);
    _name.text = saved.name;
    _persist(saved);
  }

  /// Every numeric/boolean setting back to the engine defaults, keeping the
  /// brush's identity (id, name, category, engine, tip and smudge mode).
  void _resetToDefaults() {
    final current = _working;
    if (current == null || current.isBuiltIn) return;
    final base = BrushPreset.fromJson({
      'id': current.id,
      'name': current.name,
      'category': current.category.name,
      'engine': current.engine.name,
      'tip': current.tip.name,
      'smudgeMode': current.smudgeMode.name,
    }).toJson();
    final changes = <String, Object?>{
      for (final param in BrushParams.all) param.key: base[param.key],
      'grain': base['grain'],
      'followDirection': base['followDirection'],
      'buildup': base['buildup'],
      'simulatePressure': base['simulatePressure'],
    };
    _apply(changes);
  }

  Widget _choices<T extends Enum>(
    String label,
    T value,
    List<T> values,
    String Function(T) text,
    String key,
    bool editable,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: ArtFoxelSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 4),
          Wrap(
            spacing: ArtFoxelSpacing.xs,
            children: [
              for (final option in values)
                ChoiceChip(
                  label: Text(text(option)),
                  selected: option == value,
                  onSelected:
                      editable ? (_) => _apply({key: option.name}) : null,
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _switch(
    String title,
    bool value,
    String key,
    bool editable, {
    String? subtitle,
  }) {
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(title),
      subtitle: subtitle == null ? null : Text(subtitle),
      value: value,
      onChanged: editable ? (v) => _apply({key: v}) : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    // Re-read in case the library finished loading after this editor opened.
    final working = _working ??
        ref.watch(brushLibraryProvider).valueOrNull?.byId(widget.brushId);
    if (working == null) {
      return const Center(child: Text('This brush no longer exists.'));
    }
    final editable = !working.isBuiltIn;
    final stamp = working.engine == BrushEngineKind.stamp;
    final stampLike = working.engine != BrushEngineKind.line;
    final theme = Theme.of(context);

    final children = <Widget>[
      BrushTestCanvas(brush: working),
      const SizedBox(height: ArtFoxelSpacing.md),
      if (!editable)
        Container(
          padding: const EdgeInsets.all(ArtFoxelSpacing.sm),
          margin: const EdgeInsets.only(bottom: ArtFoxelSpacing.md),
          decoration: BoxDecoration(
            color: theme.colorScheme.secondaryContainer,
            borderRadius: BorderRadius.circular(12),
          ),
          child: const Text(
            'Built-in brushes cannot be changed. Duplicate it from the list '
            'to make your own editable copy. You can still test it here.',
          ),
        ),
      TextField(
        controller: _name,
        enabled: editable,
        maxLength: BrushPreset.maxNameLength,
        onSubmitted: _rename,
        decoration: const InputDecoration(labelText: 'Name', counterText: ''),
      ),
      const SizedBox(height: ArtFoxelSpacing.sm),
      _choices<BrushCategory>(
        'Category',
        working.category,
        BrushCategory.values,
        (v) => v.label,
        'category',
        editable,
      ),
      _choices<BrushEngineKind>(
        'Engine',
        working.engine,
        BrushEngineKind.values,
        (v) => v.label,
        'engine',
        editable,
      ),
      if (stamp)
        _choices<TipShape>(
          'Tip shape',
          working.tip,
          TipShape.values,
          (v) => v.label,
          'tip',
          editable,
        ),
      if (working.engine == BrushEngineKind.smudge)
        _choices<SmudgeMode>(
          'Smudge mode',
          working.smudgeMode,
          SmudgeMode.values,
          (v) => v.label,
          'smudgeMode',
          editable,
        ),
      if (!working.erase && working.engine != BrushEngineKind.smudge)
        _choices<GrainKind>(
          'Grain',
          working.grain,
          GrainKind.values,
          (v) => v.label,
          'grain',
          editable,
        ),
      _switch('Eraser', working.erase, 'erase', editable,
          subtitle: 'Removes paint instead of adding it.'),
      if (stamp)
        _switch('Tip follows stroke direction', working.followDirection,
            'followDirection', editable),
      if (stamp)
        _switch('Build up paint', working.buildup, 'buildup', editable,
            subtitle: 'Overlaps get darker (airbrush style).'),
      if (stampLike)
        _switch('Simulate pressure from speed', working.simulatePressure,
            'simulatePressure', editable,
            subtitle: 'Used only when the device reports no pressure.'),
      _switch('Keep sharp corners', working.preserveCorners,
          'preserveCorners', editable,
          subtitle: 'Stabilization will not round off sharp turns.'),
      _switch('Predict pen position', working.predict, 'predict', editable,
          subtitle: 'Shows a short preview ahead of the pen tip.'),
    ];

    // Settings are grouped into expandable sections; the basics start open.
    final grouped = <String, List<Widget>>{};
    for (final param in BrushParams.all) {
      if (!param.visibleFor(working)) continue;
      final value = (working.toJson()[param.key] as num).toDouble();
      grouped.putIfAbsent(param.group, () => []).add(
        Row(
          children: [
            Expanded(
              flex: 5,
              child: Text(param.label, style: theme.textTheme.bodyMedium),
            ),
            Expanded(
              flex: 6,
              child: Slider(
                value: value.clamp(param.min, param.max).toDouble(),
                min: param.min,
                max: param.max,
                onChanged: editable
                    ? (v) => _apply({param.key: v}, persist: false)
                    : null,
                onChangeEnd: editable ? (_) => _persist(_working!) : null,
              ),
            ),
            SizedBox(
              width: 44,
              child: Text(
                value.toStringAsFixed(param.fractionDigits),
                textAlign: TextAlign.end,
                style: theme.textTheme.labelMedium,
              ),
            ),
          ],
        ),
      );
    }
    if (stampLike) {
      grouped.putIfAbsent('Dynamics', () => []).insertAll(0, [
        PressureCurveEditor(
          title: 'Pressure → size curve',
          exponent: working.pressureSizeCurve,
          enabled: editable,
          onChanged: (v) => _apply({'pressureSizeCurve': v}, persist: false),
          onChangeEnd: () => _persist(_working!),
        ),
        PressureCurveEditor(
          title: 'Pressure → opacity curve',
          exponent: working.pressureOpacityCurve,
          enabled: editable,
          onChanged: (v) => _apply({'pressureOpacityCurve': v}, persist: false),
          onChangeEnd: () => _persist(_working!),
        ),
      ]);
    }
    const openGroups = {'Basics', 'Smudge', 'Shape'};
    for (final entry in grouped.entries) {
      children.add(
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          initiallyExpanded: openGroups.contains(entry.key),
          title: Text(entry.key, style: theme.textTheme.titleSmall),
          children: entry.value,
        ),
      );
    }

    children
      ..add(const SizedBox(height: ArtFoxelSpacing.md))
      ..add(
        OutlinedButton.icon(
          onPressed: editable && working != _saved ? _reset : null,
          icon: const Icon(Icons.restart_alt_rounded),
          label: const Text('Reset to how it was when opened'),
        ),
      )
      ..add(const SizedBox(height: ArtFoxelSpacing.xs))
      ..add(
        OutlinedButton.icon(
          onPressed: editable ? _resetToDefaults : null,
          icon: const Icon(Icons.layers_clear_rounded),
          label: const Text('Reset all settings to defaults'),
        ),
      )
      ..add(const SizedBox(height: ArtFoxelSpacing.xl));

    return ListView(
      padding: const EdgeInsets.all(ArtFoxelSpacing.md),
      children: children,
    );
  }
}
