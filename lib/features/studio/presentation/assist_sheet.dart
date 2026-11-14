import 'package:flutter/material.dart';

import '../../../core/theme/design_tokens.dart';
import '../application/sketch_controller.dart';
import '../domain/assist_model.dart';

Future<void> showAssistSheet(BuildContext context, SketchController controller) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.95,
      builder: (context, scroll) => AssistPanel(controller: controller, scroll: scroll),
    ),
  );
}

/// Rulers, grids, guides, perspective helpers and symmetry. These help while
/// drawing and are saved with the project, but are never part of exports.
class AssistPanel extends StatelessWidget {
  const AssistPanel({required this.controller, this.scroll, super.key});
  final SketchController controller;
  final ScrollController? scroll;

  Widget _sliderRow(BuildContext context, String label, double value, double min, double max, ValueChanged<double> on) {
    return Row(children: [
      SizedBox(width: 92, child: Text(label, style: Theme.of(context).textTheme.bodyMedium)),
      Expanded(child: Slider(value: value.clamp(min, max).toDouble(), min: min, max: max, onChanged: on)),
      SizedBox(width: 44, child: Text(value.round().toString(), textAlign: TextAlign.end)),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([controller, controller.repaint]),
      builder: (context, _) {
        final a = controller.data.assist;
        final w = controller.data.width.toDouble(), h = controller.data.height.toDouble();
        void set(AssistData n) => controller.setAssist(n);
        final r = a.ruler;
        return ListView(
          controller: scroll,
          padding: const EdgeInsets.fromLTRB(ArtFoxelSpacing.md, 0, ArtFoxelSpacing.md, ArtFoxelSpacing.xl),
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Show drawing aids'),
              subtitle: const Text('Aids are never included in exported artwork.'),
              value: a.visible,
              onChanged: (v) => set(a.copyWith(visible: v)),
            ),
            Text('Grid', style: theme.textTheme.titleSmall),
            Wrap(spacing: 6, children: [
              for (final k in GridKind.values)
                ChoiceChip(label: Text(k.label), selected: a.grid == k, onSelected: (_) => set(a.copyWith(grid: k))),
            ]),
            _sliderRow(context, 'Grid size', a.gridSize, 8, 256, (v) => set(a.copyWith(gridSize: v.roundToDouble()))),
            SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Snap to grid'), value: a.snapToGrid, onChanged: (v) => set(a.copyWith(snapToGrid: v))),
            const Divider(),
            Text('Guides', style: theme.textTheme.titleSmall),
            Wrap(spacing: 6, children: [
              ActionChip(
                label: const Text('+ Vertical (centre)'),
                onPressed: a.guides.length >= AssistData.maxGuides ? null : () => set(a.copyWith(guides: [...a.guides, GuideLine(vertical: true, position: w / 2)])),
              ),
              ActionChip(
                label: const Text('+ Horizontal (centre)'),
                onPressed: a.guides.length >= AssistData.maxGuides ? null : () => set(a.copyWith(guides: [...a.guides, GuideLine(vertical: false, position: h / 2)])),
              ),
              ActionChip(label: const Text('Clear guides'), onPressed: a.guides.isEmpty ? null : () => set(a.copyWith(guides: const []))),
            ]),
            for (var i = 0; i < a.guides.length; i++)
              Row(children: [
                Text(a.guides[i].vertical ? 'V' : 'H'),
                Expanded(
                  child: Slider(
                    value: a.guides[i].position.clamp(0, a.guides[i].vertical ? w : h).toDouble(),
                    max: a.guides[i].vertical ? w : h,
                    onChanged: (v) => set(a.copyWith(guides: [...a.guides]..[i] = GuideLine(vertical: a.guides[i].vertical, position: v.roundToDouble()))),
                  ),
                ),
                IconButton(tooltip: 'Remove guide', icon: const Icon(Icons.close), onPressed: () => set(a.copyWith(guides: [...a.guides]..removeAt(i)))),
              ]),
            SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Snap to guides'), value: a.snapToGuides, onChanged: (v) => set(a.copyWith(snapToGuides: v))),
            const Divider(),
            Text('Ruler', style: theme.textTheme.titleSmall),
            Wrap(spacing: 6, children: [
              for (final k in RulerKind.values)
                ChoiceChip(
                  label: Text(k.label),
                  selected: r.kind == k,
                  onSelected: (_) => set(a.copyWith(
                    ruler: r.copyWith(
                      kind: k,
                      a: k == RulerKind.line || k == RulerKind.parallel ? Offset(w * 0.2, h * 0.5) : Offset(w / 2, h / 2),
                      b: k == RulerKind.line || k == RulerKind.parallel ? Offset(w * 0.8, h * 0.5) : Offset(w * 0.75, h / 2),
                    ),
                  )),
                ),
            ]),
            if (r.active) ...[
              _sliderRow(context, 'Point A x', r.a.dx, 0, w, (v) => set(a.copyWith(ruler: r.copyWith(a: Offset(v, r.a.dy))))),
              _sliderRow(context, 'Point A y', r.a.dy, 0, h, (v) => set(a.copyWith(ruler: r.copyWith(a: Offset(r.a.dx, v))))),
              _sliderRow(context, 'Point B x', r.b.dx, 0, w, (v) => set(a.copyWith(ruler: r.copyWith(b: Offset(v, r.b.dy))))),
              _sliderRow(context, 'Point B y', r.b.dy, 0, h, (v) => set(a.copyWith(ruler: r.copyWith(b: Offset(r.b.dx, v))))),
              _sliderRow(context, 'Snap range', r.snapStrength, 4, 120, (v) => set(a.copyWith(ruler: r.copyWith(snapStrength: v)))),
              if (r.kind == RulerKind.polygon) _sliderRow(context, 'Sides', r.sides.toDouble(), 3, 12, (v) => set(a.copyWith(ruler: r.copyWith(sides: v.round())))),
              if (r.kind == RulerKind.parallel) _sliderRow(context, 'Spacing', r.spacing, 8, 400, (v) => set(a.copyWith(ruler: r.copyWith(spacing: v)))),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: () => controller.bakeRulerAsArtwork(),
                  icon: const Icon(Icons.draw_outlined),
                  label: const Text('Turn ruler into artwork'),
                ),
              ),
              Text('Strokes snap to the ruler while drawing. Only this button puts the ruler into your drawing.', style: theme.textTheme.bodySmall),
            ],
            const Divider(),
            Text('Perspective', style: theme.textTheme.titleSmall),
            Wrap(spacing: 6, children: [
              ActionChip(
                label: Text(a.horizonY == null ? '+ Horizon line' : 'Remove horizon'),
                onPressed: () => set(a.copyWith(horizonY: a.horizonY == null ? h / 2 : null)),
              ),
              ActionChip(
                label: const Text('+ Vanishing point'),
                onPressed: a.vanishingPoints.length >= AssistData.maxVanishingPoints
                    ? null
                    : () => set(a.copyWith(vanishingPoints: [...a.vanishingPoints, Offset(w * (0.25 + 0.25 * a.vanishingPoints.length), a.horizonY ?? h / 2)])),
              ),
              ActionChip(label: const Text('Clear points'), onPressed: a.vanishingPoints.isEmpty ? null : () => set(a.copyWith(vanishingPoints: const []))),
            ]),
            if (a.horizonY != null) _sliderRow(context, 'Horizon y', a.horizonY!, 0, h, (v) => set(a.copyWith(horizonY: v.roundToDouble()))),
            for (var i = 0; i < a.vanishingPoints.length; i++)
              _sliderRow(context, 'VP ${i + 1} x', a.vanishingPoints[i].dx, -w, w * 2, (v) => set(a.copyWith(vanishingPoints: [...a.vanishingPoints]..[i] = Offset(v, a.vanishingPoints[i].dy)))),
            const Divider(),
            Text('Symmetry', style: theme.textTheme.titleSmall),
            Wrap(spacing: 6, children: [
              for (final k in SymmetryKind.values)
                ChoiceChip(label: Text(k.label), selected: a.symmetry == k, onSelected: (_) => set(a.copyWith(symmetry: k))),
            ]),
            if (a.symmetry == SymmetryKind.radial || a.symmetry == SymmetryKind.mirror || a.symmetry == SymmetryKind.kaleidoscope)
              _sliderRow(context, 'Axes', a.symmetryAxes.toDouble(), 2, 16, (v) => set(a.copyWith(symmetryAxes: v.round()))),
            if (a.symmetry != SymmetryKind.none)
              Text('Each stroke is drawn as one undoable step together with its mirrored copies.', style: theme.textTheme.bodySmall),
          ],
        );
      },
    );
  }
}
