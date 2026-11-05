import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/theme/design_tokens.dart';
import '../application/sketch_controller.dart';
import '../domain/layer_blend.dart';
import '../domain/layer_ops.dart';
import '../domain/sketch_document_data.dart';

Future<void> showLayerPanel(BuildContext context, SketchController controller) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: .7,
      maxChildSize: .95,
      minChildSize: .35,
      builder: (context, scroll) => LayerPanel(controller: controller, scroll: scroll),
    ),
  );
}

/// Small preview of one layer (or group), drawn straight from the document
/// through the compositor. It never flattens or copies the artwork.
class LayerThumb extends StatelessWidget {
  const LayerThumb({required this.controller, required this.layer, this.size = 44, super.key});

  final SketchController controller;
  final SketchLayerData layer;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: scheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: CustomPaint(painter: _ThumbPainter(controller, layer)),
    );
  }
}

class _ThumbPainter extends CustomPainter {
  _ThumbPainter(this.controller, this.layer);

  final SketchController controller;
  final SketchLayerData layer;

  @override
  void paint(Canvas canvas, Size size) {
    final doc = controller.data;
    final scale = math.min(size.width / doc.width, size.height / doc.height);
    final dx = (size.width - doc.width * scale) / 2;
    final dy = (size.height - doc.height * scale) / 2;
    final page = Rect.fromLTWH(dx, dy, doc.width * scale, doc.height * scale);
    // Checkerboard shows transparency.
    final light = Paint()..color = const Color(0xFFF2F2F2);
    final dark = Paint()..color = const Color(0xFFD6D6D6);
    const cells = 4;
    for (var y = 0; y < cells; y++) {
      for (var x = 0; x < cells; x++) {
        canvas.drawRect(
          Rect.fromLTWH(
            page.left + x * page.width / cells,
            page.top + y * page.height / cells,
            page.width / cells,
            page.height / cells,
          ),
          (x + y).isEven ? light : dark,
        );
      }
    }
    canvas.save();
    canvas.clipRect(page);
    canvas.translate(dx, dy);
    canvas.scale(scale);
    canvas.saveLayer(null, Paint());
    controller.compositor.paintAlone(canvas, layer);
    canvas.restore();
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _ThumbPainter oldDelegate) => true;
}

class LayerPanel extends StatelessWidget {
  const LayerPanel({required this.controller, required this.scroll, super.key});

  final SketchController controller;
  final ScrollController scroll;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final rows = <Widget>[];
        void walk(String? parent) {
          // Top of the stack first.
          for (final layer in LayerOps.children(controller.data, parent).reversed) {
            rows.add(_LayerRow(controller: controller, layer: layer));
            if (layer.isGroup && layer.expanded) walk(layer.id);
          }
        }

        walk(null);
        final active = controller.activeLayer;
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: ArtFoxelSpacing.md),
              child: Row(
                children: [
                  Text('Layers', style: Theme.of(context).textTheme.titleMedium),
                  const Spacer(),
                  IconButton(
                    tooltip: 'Add layer',
                    onPressed: controller.addLayer,
                    icon: const Icon(Icons.add_box_outlined),
                  ),
                  IconButton(
                    tooltip: 'Add group',
                    onPressed: controller.addGroup,
                    icon: const Icon(Icons.create_new_folder_outlined),
                  ),
                  IconButton(
                    tooltip: 'Group selected layer',
                    onPressed: controller.groupActive,
                    icon: const Icon(Icons.folder_copy_outlined),
                  ),
                  IconButton(
                    tooltip: 'Duplicate',
                    onPressed: () => controller.duplicateLayer(active.id),
                    icon: const Icon(Icons.copy_rounded),
                  ),
                  IconButton(
                    tooltip: 'Move up',
                    onPressed: () => controller.nudgeLayer(active.id, 1),
                    icon: const Icon(Icons.arrow_upward_rounded),
                  ),
                  IconButton(
                    tooltip: 'Move down',
                    onPressed: () => controller.nudgeLayer(active.id, -1),
                    icon: const Icon(Icons.arrow_downward_rounded),
                  ),
                  IconButton(
                    tooltip: 'Delete',
                    onPressed: () => _confirmDelete(context, active),
                    icon: const Icon(Icons.delete_outline_rounded),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                controller: scroll,
                children: [
                  ...rows,
                  const Divider(),
                  _LayerProperties(controller: controller, layer: active),
                  const SizedBox(height: ArtFoxelSpacing.xl),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _confirmDelete(BuildContext context, SketchLayerData layer) async {
    final count = layer.isGroup ? LayerOps.descendants(controller.data, layer.id).length : 0;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete "${layer.name}"?'),
        content: Text(count > 0
            ? 'The group and the $count layer${count == 1 ? '' : 's'} inside it will be removed. You can undo this.'
            : 'You can undo this.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok == true) controller.deleteLayer(layer.id);
  }
}

class _LayerRow extends StatelessWidget {
  const _LayerRow({required this.controller, required this.layer});

  final SketchController controller;
  final SketchLayerData layer;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final selected = controller.activeLayerId == layer.id;
    final depth = LayerOps.depthOf(controller.data, layer);
    final hiddenByParent = !LayerOps.isEffectivelyVisible(controller.data, layer);
    final subtitle = <String>[
      if (layer.isImage) 'Image',
      if (layer.blend != LayerBlend.normal) layer.blend.label,
      if (layer.opacity < 1) '${(layer.opacity * 100).round()}%',
      if (layer.alphaLock) 'Alpha lock',
      if (layer.clipToBelow) 'Clipped',
    ].join(' · ');
    return Material(
      color: selected ? scheme.primaryContainer.withValues(alpha: .5) : Colors.transparent,
      child: InkWell(
        key: ValueKey('layer-row-${layer.id}'),
        onTap: () => controller.selectLayer(layer.id),
        child: Padding(
          padding: EdgeInsets.fromLTRB(ArtFoxelSpacing.sm + depth * 18, 4, ArtFoxelSpacing.sm, 4),
          child: Row(
            children: [
              if (layer.isGroup)
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: layer.expanded ? 'Collapse' : 'Expand',
                  onPressed: () => controller.toggleExpanded(layer.id),
                  icon: Icon(layer.expanded ? Icons.expand_more_rounded : Icons.chevron_right_rounded),
                )
              else if (layer.clipToBelow)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8),
                  child: Icon(Icons.subdirectory_arrow_right_rounded, size: 18),
                )
              else
                const SizedBox(width: 8),
              Opacity(
                opacity: layer.visible && !hiddenByParent ? 1 : .35,
                child: layer.isGroup
                    ? const SizedBox(width: 44, height: 44, child: Icon(Icons.folder_rounded))
                    : LayerThumb(controller: controller, layer: layer),
              ),
              const SizedBox(width: ArtFoxelSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      layer.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                          ),
                    ),
                    if (subtitle.isNotEmpty)
                      Text(subtitle, style: Theme.of(context).textTheme.labelSmall),
                  ],
                ),
              ),
              if (layer.mask != null)
                Tooltip(
                  message: layer.mask!.enabled ? 'Has a mask' : 'Mask disabled',
                  child: Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Icon(
                      Icons.vignette_outlined,
                      size: 18,
                      color: layer.mask!.enabled ? scheme.primary : scheme.outline,
                    ),
                  ),
                ),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: layer.locked ? 'Unlock' : 'Lock',
                onPressed: () => controller.setLayerLocked(layer.id, !layer.locked),
                icon: Icon(layer.locked ? Icons.lock_rounded : Icons.lock_open_rounded, size: 20),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: layer.visible ? 'Hide' : 'Show',
                onPressed: () => controller.setLayerVisible(layer.id, !layer.visible),
                icon: Icon(layer.visible ? Icons.visibility_rounded : Icons.visibility_off_rounded, size: 20),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LayerProperties extends StatefulWidget {
  const _LayerProperties({required this.controller, required this.layer});

  final SketchController controller;
  final SketchLayerData layer;

  @override
  State<_LayerProperties> createState() => _LayerPropertiesState();
}

class _LayerPropertiesState extends State<_LayerProperties> {
  double? _opacityStart;

  Future<void> _rename() async {
    final controller = TextEditingController(text: widget.layer.name);
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename layer'),
        content: TextField(controller: controller, autofocus: true, maxLength: 40),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('Rename')),
        ],
      ),
    );
    controller.dispose();
    if (value != null) widget.controller.renameLayer(widget.layer.id, value);
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final layer = widget.layer;
    final theme = Theme.of(context);
    final mask = layer.mask;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: ArtFoxelSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(layer.name, style: theme.textTheme.titleSmall)),
              TextButton.icon(
                onPressed: _rename,
                icon: const Icon(Icons.edit_outlined, size: 18),
                label: const Text('Rename'),
              ),
            ],
          ),
          Row(
            children: [
              const SizedBox(width: 70, child: Text('Opacity')),
              Expanded(
                child: Slider(
                  value: layer.opacity,
                  onChangeStart: (_) => _opacityStart = layer.opacity,
                  onChanged: (v) => c.previewLayerOpacity(layer.id, v),
                  onChangeEnd: (_) {
                    final from = _opacityStart;
                    _opacityStart = null;
                    if (from != null) c.commitLayerOpacity(layer.id, from);
                  },
                ),
              ),
              SizedBox(width: 40, child: Text('${(layer.opacity * 100).round()}%', textAlign: TextAlign.end)),
            ],
          ),
          Row(
            children: [
              const SizedBox(width: 70, child: Text('Blend')),
              Expanded(
                child: DropdownButton<LayerBlend>(
                  isExpanded: true,
                  value: layer.blend,
                  items: [
                    for (final mode in LayerBlend.values)
                      DropdownMenuItem(value: mode, child: Text(mode.label)),
                  ],
                  onChanged: (mode) {
                    if (mode != null) c.setLayerBlend(layer.id, mode);
                  },
                ),
              ),
            ],
          ),
          Text(
            'Not offered: ${LayerBlend.unsupported.join(', ')} (no verified rendering path yet).',
            style: theme.textTheme.bodySmall,
          ),
          if (layer.isPaint)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Alpha lock'),
              subtitle: const Text('Paint only where the layer already has pixels.'),
              value: layer.alphaLock,
              onChanged: (v) => c.setAlphaLock(layer.id, v),
            ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Clip to layer below'),
            value: layer.clipToBelow,
            onChanged: (v) => c.setClipToBelow(layer.id, v),
          ),
          const Divider(),
          Text('Mask', style: theme.textTheme.titleSmall),
          if (layer.isGroup)
            const Text('Masks are available on paint and image layers.')
          else if (mask == null)
            Wrap(
              spacing: ArtFoxelSpacing.xs,
              children: [
                OutlinedButton(onPressed: () => c.addMask(), child: const Text('Add mask (show all)')),
                OutlinedButton(onPressed: () => c.addMask(hideAll: true), child: const Text('Hide all')),
                OutlinedButton(
                  onPressed: c.selection == null ? null : () => c.addMask(fromSelection: true),
                  child: const Text('From selection'),
                ),
              ],
            )
          else ...[
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Mask enabled'),
              value: mask.enabled,
              onChanged: (v) => c.setMaskEnabled(layer.id, v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Paint on mask'),
              subtitle: const Text('White reveals, black hides. The mask follows your colour\'s brightness.'),
              value: c.editingMask,
              onChanged: c.setEditingMask,
            ),
            Wrap(
              spacing: ArtFoxelSpacing.xs,
              children: [
                OutlinedButton(onPressed: () => c.invertMask(layer.id), child: const Text('Invert')),
                OutlinedButton(onPressed: c.selectionFromMask, child: const Text('To selection')),
                OutlinedButton(
                  onPressed: c.canApplyMask(layer) ? () => c.applyMask(layer.id) : null,
                  child: const Text('Apply'),
                ),
                OutlinedButton(onPressed: () => c.deleteMask(layer.id), child: const Text('Delete mask')),
              ],
            ),
            if (!layer.isImage)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Apply is only available for image layers. Paint layers keep their editable strokes, so their masks stay non-destructive.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
          ],
        ],
      ),
    );
  }
}
