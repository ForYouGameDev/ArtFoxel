import 'package:flutter/material.dart';

import '../../../core/theme/design_tokens.dart';
import '../application/sketch_controller.dart';
import '../domain/alpha_mask.dart';

Future<void> showSelectionSheet(BuildContext context, SketchController controller) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: .65,
      maxChildSize: .92,
      minChildSize: .3,
      builder: (context, scroll) => _SelectionSheet(controller: controller, scroll: scroll),
    ),
  );
}

class _SelectionSheet extends StatefulWidget {
  const _SelectionSheet({required this.controller, required this.scroll});

  final SketchController controller;
  final ScrollController scroll;

  @override
  State<_SelectionSheet> createState() => _SelectionSheetState();
}

class _SelectionSheetState extends State<_SelectionSheet> {
  double _amount = 4;

  static const _tools = <(SketchTool, String, IconData)>[
    (SketchTool.draw, 'Paint', Icons.brush_rounded),
    (SketchTool.selectRect, 'Rectangle', Icons.crop_square_rounded),
    (SketchTool.selectEllipse, 'Ellipse', Icons.circle_outlined),
    (SketchTool.selectLasso, 'Lasso', Icons.gesture_rounded),
    (SketchTool.selectPolygon, 'Polygon', Icons.pentagon_outlined),
    (SketchTool.magicWand, 'Magic wand', Icons.auto_fix_high_rounded),
    (SketchTool.colorRange, 'Color range', Icons.palette_outlined),
  ];

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final has = c.selection != null;
        final theme = Theme.of(context);
        return ListView(
          controller: widget.scroll,
          padding: const EdgeInsets.all(ArtFoxelSpacing.md),
          children: [
            Text('Selection', style: theme.textTheme.titleMedium),
            const SizedBox(height: ArtFoxelSpacing.sm),
            Wrap(
              spacing: ArtFoxelSpacing.xs,
              children: [
                for (final (tool, label, icon) in _tools)
                  ChoiceChip(
                    avatar: Icon(icon, size: 18),
                    label: Text(label),
                    selected: c.tool == tool,
                    onSelected: (_) => c.selectTool(tool),
                  ),
              ],
            ),
            const SizedBox(height: ArtFoxelSpacing.md),
            Text('When selecting', style: theme.textTheme.labelLarge),
            Wrap(
              spacing: ArtFoxelSpacing.xs,
              children: [
                for (final mode in SelectionMode.values)
                  ChoiceChip(
                    label: Text(mode.label),
                    selected: c.selectionMode == mode,
                    onSelected: (_) => c.setSelectionMode(mode),
                  ),
              ],
            ),
            if (c.tool == SketchTool.magicWand || c.tool == SketchTool.colorRange) ...[
              const SizedBox(height: ArtFoxelSpacing.sm),
              _slider('Tolerance', c.wandTolerance.toDouble(), 0, 255, (v) => c.setWandTolerance(v.round())),
              if (c.tool == SketchTool.colorRange)
                _slider('Fuzziness', c.colorRangeFuzziness.toDouble(), 0, 255,
                    (v) => c.setColorRangeFuzziness(v.round())),
              if (c.tool == SketchTool.magicWand)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Contiguous'),
                  value: c.wandContiguous,
                  onChanged: c.setWandContiguous,
                ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Sample all visible layers'),
                subtitle: const Text('Off = only the selected layer.'),
                value: c.sampleAllLayers,
                onChanged: c.setSampleAllLayers,
              ),
            ],
            if (c.tool == SketchTool.selectPolygon && c.hasOpenPolygon)
              Row(
                children: [
                  FilledButton(onPressed: c.closePolygon, child: const Text('Close polygon')),
                  const SizedBox(width: ArtFoxelSpacing.sm),
                  OutlinedButton(onPressed: c.cancelShape, child: const Text('Cancel')),
                ],
              ),
            const Divider(height: ArtFoxelSpacing.lg),
            Wrap(
              spacing: ArtFoxelSpacing.xs,
              runSpacing: ArtFoxelSpacing.xs,
              children: [
                OutlinedButton(onPressed: c.selectAll, child: const Text('Select all')),
                OutlinedButton(onPressed: has ? c.deselect : null, child: const Text('Deselect')),
                OutlinedButton(onPressed: c.invertSelection, child: const Text('Invert')),
              ],
            ),
            _slider('Amount (px)', _amount, 1, 100, (v) => setState(() => _amount = v)),
            Wrap(
              spacing: ArtFoxelSpacing.xs,
              runSpacing: ArtFoxelSpacing.xs,
              children: [
                OutlinedButton(onPressed: has ? () => c.growSelection(_amount) : null, child: const Text('Expand')),
                OutlinedButton(onPressed: has ? () => c.growSelection(-_amount) : null, child: const Text('Contract')),
                OutlinedButton(onPressed: has ? () => c.featherSelection(_amount) : null, child: const Text('Feather')),
              ],
            ),
            const Divider(height: ArtFoxelSpacing.lg),
            Wrap(
              spacing: ArtFoxelSpacing.xs,
              runSpacing: ArtFoxelSpacing.xs,
              children: [
                OutlinedButton(onPressed: has ? c.copySelection : null, child: const Text('Copy')),
                OutlinedButton(
                  onPressed: has ? () => c.copySelection(merged: true) : null,
                  child: const Text('Copy merged'),
                ),
                OutlinedButton(onPressed: has ? c.cutSelection : null, child: const Text('Cut')),
                OutlinedButton(onPressed: c.clipboard == null ? null : c.pasteClipboard, child: const Text('Paste')),
                OutlinedButton(onPressed: has ? c.selectionToLayer : null, child: const Text('To new layer')),
                OutlinedButton(
                  onPressed: has ? () => c.addMask(fromSelection: true) : null,
                  child: const Text('To layer mask'),
                ),
              ],
            ),
            const Divider(height: ArtFoxelSpacing.lg),
            Text('Show selection', style: theme.textTheme.labelLarge),
            Wrap(
              spacing: ArtFoxelSpacing.xs,
              children: [
                for (final view in SelectionView.values)
                  ChoiceChip(
                    label: Text(view.label),
                    selected: c.selectionView == view,
                    onSelected: (_) => c.setSelectionView(view),
                  ),
              ],
            ),
            const SizedBox(height: ArtFoxelSpacing.sm),
            Text(
              'Selections are stored in canvas coordinates at up to ${AlphaMask.maxSide} px, '
              'so they stay put while you zoom, pan or rotate the view. '
              'Painting is not limited to the selection yet.',
              style: theme.textTheme.bodySmall,
            ),
          ],
        );
      },
    );
  }

  Widget _slider(String label, double value, double min, double max, ValueChanged<double> onChanged) {
    return Row(
      children: [
        SizedBox(width: 96, child: Text(label)),
        Expanded(child: Slider(value: value.clamp(min, max).toDouble(), min: min, max: max, onChanged: onChanged)),
        SizedBox(width: 40, child: Text(value.round().toString(), textAlign: TextAlign.end)),
      ],
    );
  }
}
