import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../../core/theme/design_tokens.dart';
import '../application/sketch_controller.dart';
import '../domain/reference_model.dart';

Future<void> showReferenceStudio(BuildContext context, SketchController controller) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    barrierColor: Colors.black12,
    builder: (context) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.95,
      builder: (context, scroll) => ReferencePanel(controller: controller, scroll: scroll),
    ),
  );
}

/// Reference board: images that sit beside the drawing. They are shown only
/// while editing and are never included in exports.
class ReferencePanel extends StatelessWidget {
  const ReferencePanel({required this.controller, this.scroll, super.key});
  final SketchController controller;
  final ScrollController? scroll;

  Future<void> _add(BuildContext context) async {
    try {
      final result = await FilePicker.platform.pickFiles(type: FileType.image, withData: true, allowMultiple: true);
      if (result == null) return;
      for (final f in result.files) {
        final bytes = f.bytes;
        if (bytes == null) continue;
        await controller.addReference(f.name, bytes);
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('The image picker could not be opened.')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final board = controller.references;
        final groups = board.groups;
        return ListView(
          controller: scroll,
          padding: const EdgeInsets.fromLTRB(ArtFoxelSpacing.md, 0, ArtFoxelSpacing.md, ArtFoxelSpacing.xl),
          children: [
            Row(children: [
              FilledButton.icon(onPressed: () => _add(context), icon: const Icon(Icons.add_photo_alternate_outlined), label: const Text('Add images')),
              const Spacer(),
              Text('${board.images.length}/${ReferenceImage.maxImages}', style: theme.textTheme.labelLarge),
            ]),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Show references on canvas'),
              subtitle: const Text('References are never included in exports.'),
              value: controller.showReferences,
              onChanged: controller.toggleReferences,
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Eyedropper reads references'),
              value: controller.sampleReferences,
              onChanged: (v) {
                controller.sampleReferences = v;
                controller.setTool(v ? SketchTool.eyedropper : SketchTool.draw);
              },
            ),
            if (board.images.isEmpty) const Padding(padding: EdgeInsets.all(16), child: Text('No references yet. Add photos or sketches to look at while you draw.')),
            for (final group in ['', ...groups])
              ...[
                if (board.images.any((i) => i.group == group)) ...[
                  if (group.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: Text(group, style: theme.textTheme.titleSmall)),
                  for (final r in board.images.where((i) => i.group == group)) _tile(context, r, theme),
                ],
              ],
          ],
        );
      },
    );
  }

  Widget _tile(BuildContext context, ReferenceImage r, ThemeData theme) {
    final selected = controller.selectedReferenceId == r.id;
    void upd(ReferenceImage Function(ReferenceImage) f) => controller.updateReference(r.id, f);
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: selected ? theme.colorScheme.primary : Colors.transparent, width: 2)),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(children: [
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            onTap: () {
              controller.selectReference(selected ? null : r.id);
            },
            leading: ClipRRect(borderRadius: BorderRadius.circular(6), child: Image.memory(r.bytes, width: 48, height: 48, fit: BoxFit.cover, gaplessPlayback: true, errorBuilder: (_, __, ___) => const Icon(Icons.broken_image_outlined))),
            title: Text(r.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            trailing: Wrap(children: [
              IconButton(tooltip: r.hidden ? 'Show' : 'Hide', icon: Icon(r.hidden ? Icons.visibility_off_outlined : Icons.visibility_outlined), onPressed: () => upd((x) => x.copyWith(hidden: !x.hidden))),
              IconButton(tooltip: r.locked ? 'Unlock' : 'Lock', icon: Icon(r.locked ? Icons.lock_outline : Icons.lock_open_outlined), onPressed: () => upd((x) => x.copyWith(locked: !x.locked))),
              IconButton(tooltip: 'Remove reference', icon: const Icon(Icons.delete_outline), onPressed: () => controller.removeReference(r.id)),
            ]),
          ),
          if (!r.locked && selected) ...[
            _row('Scale', r.scale, 0.05, 4, (v) => upd((x) => x.copyWith(scale: v))),
            _row('Rotate', r.rotation, -math.pi, math.pi, (v) => upd((x) => x.copyWith(rotation: v))),
            _row('Opacity', r.opacity, 0.05, 1, (v) => upd((x) => x.copyWith(opacity: v))),
            _row('Move X', r.x, -controller.data.width.toDouble(), controller.data.width.toDouble() * 1.5, (v) => upd((x) => x.copyWith(x: v))),
            _row('Move Y', r.y, -controller.data.height.toDouble(), controller.data.height.toDouble() * 1.5, (v) => upd((x) => x.copyWith(y: v))),
            TextFormField(
              initialValue: r.group,
              maxLength: 24,
              decoration: const InputDecoration(labelText: 'Board section (optional)', counterText: ''),
              onFieldSubmitted: (v) => upd((x) => x.copyWith(group: v.trim())),
            ),
          ] else if (r.locked && selected)
            const Text('Unlock this reference to move or scale it.'),
        ]),
      ),
    );
  }

  Widget _row(String label, double v, double min, double max, ValueChanged<double> on) => Row(children: [
        SizedBox(width: 64, child: Text(label)),
        Expanded(child: Slider(value: v.clamp(min, max).toDouble(), min: min, max: max, onChanged: on)),
      ]);
}
