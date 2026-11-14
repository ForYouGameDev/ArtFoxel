import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/theme/design_tokens.dart';
import '../application/sketch_controller.dart';
import '../application/studio_libraries.dart';
import '../domain/gradient_model.dart';
import '../domain/shape_model.dart';
import 'gradient_editor.dart';

Future<void> showShapeSheet(BuildContext context, SketchController controller) {
  controller.setTool(SketchTool.shape);
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    barrierColor: Colors.black12,
    builder: (context) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.5,
      maxChildSize: 0.95,
      builder: (context, scroll) => ShapePanel(controller: controller, scroll: scroll),
    ),
  );
}

/// Shape tool options. Drag on the canvas to draw; tap a shape to select it
/// and drag its round handles to edit it. Shapes remain editable geometry
/// until "Rasterize".
class ShapePanel extends StatefulWidget {
  const ShapePanel({required this.controller, this.scroll, super.key});
  final SketchController controller;
  final ScrollController? scroll;

  @override
  State<ShapePanel> createState() => _ShapePanelState();
}

class _ShapePanelState extends State<ShapePanel> {
  late final StudioLibraries _libs = StudioLibraries(SharedPreferences.getInstance());
  Map<String, GradientData> _saved = {};
  bool _editGradient = false;

  SketchController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    _libs.loadGradients().then((g) {
      if (mounted) setState(() => _saved = g);
    });
  }

  Widget _slider(String label, double v, double min, double max, ValueChanged<double> on, {bool int = false}) {
    return Row(children: [
      SizedBox(width: 96, child: Text(label)),
      Expanded(child: Slider(value: v.clamp(min, max).toDouble(), min: min, max: max, onChanged: (x) {
        on(int ? x.roundToDouble() : x);
        c.notifyShapeSettings();
      })),
      SizedBox(width: 40, child: Text(v.round().toString(), textAlign: TextAlign.end)),
    ]);
  }

  Future<void> _saveGradient() async {
    final g = c.shapeTool.gradient;
    if (g == null) return;
    final next = {..._saved, 'Custom ${_saved.length + 1}': g};
    try {
      await _libs.saveGradients(next);
      setState(() => _saved = next);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([c, c.repaint]),
      builder: (context, _) {
        final t = c.shapeTool;
        final sel = c.selectedShape;
        final kind = t.kind;
        return ListView(
          controller: widget.scroll,
          padding: const EdgeInsets.fromLTRB(ArtFoxelSpacing.md, 0, ArtFoxelSpacing.md, ArtFoxelSpacing.xl),
          children: [
            Wrap(spacing: 6, children: [
              for (final k in ShapeKind.values)
                ChoiceChip(label: Text(k.label), selected: kind == k, onSelected: (_) => c.setShapeKind(k)),
            ]),
            if (kind == ShapeKind.polyline)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(children: [
                  Expanded(child: Text('Tap points on the canvas, then finish.', style: theme.textTheme.bodySmall)),
                  FilledButton.tonal(onPressed: c.finishPolyline, child: const Text('Finish polyline')),
                ]),
              ),
            if (kind == ShapeKind.bezier || kind == ShapeKind.cubic)
              Text('Drag to place the curve, then move its control handles.', style: theme.textTheme.bodySmall),
            const SizedBox(height: 6),
            _slider('Line width', t.strokeWidth, 0, 60, (v) => t.strokeWidth = v),
            SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Outline (foreground colour)'), value: t.stroke, onChanged: (v) {
              t.stroke = v;
              c.notifyShapeSettings();
            }),
            if (kind.closed)
              SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Fill'), subtitle: Text(t.gradient == null ? 'Background colour' : 'Gradient'), value: t.fill, onChanged: (v) {
                t.fill = v;
                c.notifyShapeSettings();
              }),
            if (kind == ShapeKind.roundedRect) _slider('Corner radius', t.cornerRadius, 0, 200, (v) => t.cornerRadius = v),
            if (kind == ShapeKind.polygon || kind == ShapeKind.star) _slider('Sides / points', t.sides.toDouble(), 3, 24, (v) => t.sides = v.round(), int: true),
            if (kind == ShapeKind.star) _slider('Inner radius %', t.innerRatio * 100, 10, 90, (v) => t.innerRatio = v / 100),
            if (kind == ShapeKind.arc) _slider('Sweep °', t.sweepDegrees, -360, 360, (v) => t.sweepDegrees = v),
            if (kind.closed) ...[
              const Divider(),
              Row(children: [
                Text('Gradient fill', style: theme.textTheme.titleSmall),
                const Spacer(),
                TextButton(onPressed: t.gradient == null ? null : () {
                  t.gradient = null;
                  setState(() => _editGradient = false);
                  c.notifyShapeSettings();
                }, child: const Text('Use solid')),
                TextButton(
                  onPressed: () {
                    t.gradient ??= GradientPresets.all.first.gradient;
                    t.fill = true;
                    setState(() => _editGradient = !_editGradient);
                    c.notifyShapeSettings();
                  },
                  child: Text(_editGradient ? 'Hide editor' : 'Edit gradient'),
                ),
              ]),
              if (_editGradient && t.gradient != null)
                GradientEditor(
                  initial: t.gradient!,
                  onChanged: (g) {
                    t.gradient = g;
                    c.notifyShapeSettings();
                  },
                ),
              if (_editGradient)
                Wrap(spacing: 6, children: [
                  ActionChip(label: const Text('Save to my gradients'), onPressed: _saveGradient),
                  for (final e in _saved.entries)
                    ActionChip(label: Text(e.key), onPressed: () {
                      t.gradient = e.value;
                      t.fill = true;
                      setState(() {});
                      c.notifyShapeSettings();
                    }),
                ]),
              Text('Linear and radial gradients only. Angular, reflected and diamond are not implemented.', style: theme.textTheme.bodySmall),
            ],
            const Divider(),
            Wrap(spacing: 6, runSpacing: 6, children: [
              FilledButton.tonalIcon(
                onPressed: sel == null ? null : c.deleteSelectedShape,
                icon: const Icon(Icons.delete_outline),
                label: const Text('Delete selected'),
              ),
              OutlinedButton.icon(
                onPressed: c.activeLayer.shapes.isEmpty ? null : () => c.rasterizeShapes(),
                icon: const Icon(Icons.grid_on),
                label: const Text('Rasterize layer shapes'),
              ),
              OutlinedButton.icon(
                onPressed: () {
                  c.setTool(SketchTool.draw);
                  c.recognizeLastStroke();
                },
                icon: const Icon(Icons.auto_fix_high),
                label: const Text('Clean up last stroke'),
              ),
            ]),
            Text('"Clean up" only changes a stroke into a line, circle, rectangle or triangle when the match is clear.', style: theme.textTheme.bodySmall),
            if (sel != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text('Selected: ${sel.kind.label} · ${sel.points.length} handles', style: theme.textTheme.labelLarge)),
          ],
        );
      },
    );
  }
}
