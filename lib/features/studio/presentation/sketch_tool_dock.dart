import 'package:flutter/material.dart';

import '../../../core/theme/design_tokens.dart';
import '../application/sketch_controller.dart';
import '../domain/builtin_brushes.dart';
import '../domain/shape_model.dart';
import 'brush_picker_sheet.dart';
import 'brush_preview.dart';
import 'assist_sheet.dart';
import 'color_sheet.dart';
import 'filter_studio.dart';
import 'reference_studio.dart';
import 'shape_sheet.dart';
import 'studio_settings_sheet.dart';

/// Bottom tool dock: colour, brush, eraser, eyedropper, settings and the
/// size/opacity sliders, with a line that always states the active tool.
class SketchToolDock extends StatefulWidget {
  const SketchToolDock({required this.controller, super.key});

  final SketchController controller;

  @override
  State<SketchToolDock> createState() => _SketchToolDockState();
}

class _SketchToolDockState extends State<SketchToolDock> {
  /// Brush to return to when the quick eraser toggle is switched off.
  var _brushBeforeEraser = BuiltInBrushes.defaultBrush;

  void _toggleEraser() {
    final controller = widget.controller;
    if (controller.brush.erase) {
      controller.selectBrush(_brushBeforeEraser);
    } else {
      _brushBeforeEraser = controller.brush;
      controller.selectBrush(BuiltInBrushes.byId('builtin.eraser')!);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final controller = widget.controller;
        final brush = controller.brush;
        final picking = controller.tool == SketchTool.eyedropper;
        final layer = controller.activeLayer;
        final target = controller.editingMask
            ? 'Mask of "${layer.name}"'
            : '"${layer.name}"';
        final status = controller.tool == SketchTool.shape
            ? 'Shape tool · ${controller.shapeTool.kind.label} · drag to draw, tap a shape to edit'
            : controller.tool.isSelection
            ? 'Selection tool · ${controller.tool.name} · ${controller.selectionMode.label}'
            : picking
            ? 'Eyedropper · tap the canvas to pick a colour'
            : '$target · ${brush.name} · ${controller.size.round()} px · '
                '${(controller.opacity * 100).round()}%'
                '${controller.lowLatency ? ' · low latency' : ''}';

        return Material(
          color: scheme.surfaceContainerLow,
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                ArtFoxelSpacing.sm,
                ArtFoxelSpacing.xs,
                ArtFoxelSpacing.sm,
                ArtFoxelSpacing.xs,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(left: 4, bottom: 4),
                    child: Text(
                      status,
                      key: const ValueKey('active-tool-status'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                            color: picking ? scheme.primary : null,
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                  ),
                  Row(
                    children: [
                      Tooltip(
                        message: 'Colour',
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: () => showColorSheet(context, controller),
                          child: Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              color: Color(controller.colorArgb),
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: scheme.outline,
                                width: 2,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: ArtFoxelSpacing.xs),
                      Expanded(
                        child: Tooltip(
                          message: 'Choose brush',
                          child: InkWell(
                            borderRadius: BorderRadius.circular(12),
                            onTap: () => showBrushPicker(context, controller),
                            child: Padding(
                              padding: const EdgeInsets.all(4),
                              child: Row(
                                children: [
                                  BrushPreview(
                                    brush: brush,
                                    width: 72,
                                    height: 36,
                                  ),
                                  const SizedBox(width: ArtFoxelSpacing.xs),
                                  Expanded(
                                    child: Text(
                                      brush.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  const Icon(Icons.expand_less_rounded),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                      IconButton.filledTonal(
                        tooltip: 'Eraser',
                        isSelected: brush.erase && !picking,
                        onPressed: _toggleEraser,
                        icon: const Icon(Icons.cleaning_services_outlined),
                        selectedIcon: const Icon(Icons.cleaning_services),
                      ),
                      IconButton.filledTonal(
                        tooltip: 'Eyedropper',
                        isSelected: picking,
                        onPressed: () => controller.setTool(
                          picking ? SketchTool.draw : SketchTool.eyedropper,
                        ),
                        icon: const Icon(Icons.colorize_outlined),
                        selectedIcon: const Icon(Icons.colorize),
                      ),
                      PopupMenuButton<String>(
                        tooltip: 'Shapes, aids, references and filters',
                        icon: const Icon(Icons.auto_awesome_mosaic_outlined),
                        onSelected: (v) {
                          switch (v) {
                            case 'shapes':
                              showShapeSheet(context, controller);
                            case 'assist':
                              showAssistSheet(context, controller);
                            case 'refs':
                              showReferenceStudio(context, controller);
                            case 'filters':
                              showFilterStudio(context, controller);
                          }
                        },
                        itemBuilder: (_) => const [
                          PopupMenuItem(value: 'shapes', child: Text('Shapes')),
                          PopupMenuItem(value: 'assist', child: Text('Rulers, grids and symmetry')),
                          PopupMenuItem(value: 'refs', child: Text('Reference images')),
                          PopupMenuItem(value: 'filters', child: Text('Filters and adjustments')),
                        ],
                      ),
                      IconButton(
                        tooltip: 'Brush and gesture settings',
                        onPressed: () =>
                            showStudioSettingsSheet(context, controller),
                        icon: const Icon(Icons.tune_rounded),
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: _LabeledSlider(
                          label: 'Size',
                          value: controller.size,
                          min: 1,
                          max: 300,
                          onChanged: controller.setSize,
                        ),
                      ),
                      Expanded(
                        child: _LabeledSlider(
                          label: 'Opacity',
                          value: controller.opacity,
                          min: 0.02,
                          max: 1,
                          onChanged: controller.setOpacity,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _LabeledSlider extends StatelessWidget {
  const _LabeledSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4),
          child: Text(label, style: Theme.of(context).textTheme.labelSmall),
        ),
        Expanded(
          child: Slider(
            value: value.clamp(min, max).toDouble(),
            min: min,
            max: max,
            semanticFormatterCallback: (v) => '$label ${v.toStringAsFixed(2)}',
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }
}
