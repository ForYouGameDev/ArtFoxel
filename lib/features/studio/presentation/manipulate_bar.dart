import 'package:flutter/material.dart';

import '../../../core/theme/design_tokens.dart';
import '../application/sketch_controller.dart';
import 'transform_panel.dart';

/// Compact bar shown while the Move / Resize tool is active. It stays small
/// so the canvas keeps the screen; the handles live on the canvas itself.
class ManipulateBar extends StatelessWidget {
  const ManipulateBar({required this.controller, super.key});

  final SketchController controller;

  void _sliders(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      barrierColor: Colors.black12,
      isScrollControlled: true,
      builder: (c) => TransformPanel(controller: controller),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final kind = controller.manipKind;
        final ref = kind == ManipKind.reference ? controller.references.byId(controller.selectedReferenceId!) : null;
        return Material(
          color: scheme.surfaceContainerLow,
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(ArtFoxelSpacing.sm, 4, ArtFoxelSpacing.sm, 4),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: Text(
                      '${controller.manipLabel} · drag to move · corners resize · top handle rotates · two fingers pinch it',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        FilledButton.icon(
                          onPressed: controller.manipDone,
                          icon: const Icon(Icons.check_rounded),
                          label: const Text('Done'),
                        ),
                        const SizedBox(width: 4),
                        TextButton(onPressed: controller.manipCancel, child: const Text('Cancel')),
                        if (kind == ManipKind.layer) ...[
                          IconButton(
                            tooltip: 'Flip horizontally',
                            onPressed: () => controller.manipFlipLayer(horizontal: true),
                            icon: const Icon(Icons.flip),
                          ),
                          IconButton(
                            tooltip: 'Flip vertically',
                            onPressed: () => controller.manipFlipLayer(horizontal: false),
                            icon: const RotatedBox(quarterTurns: 1, child: Icon(Icons.flip)),
                          ),
                          IconButton(
                            tooltip: 'Reset',
                            onPressed: controller.resetTransform,
                            icon: const Icon(Icons.restart_alt_rounded),
                          ),
                          IconButton(
                            tooltip: 'Exact values',
                            onPressed: () => _sliders(context),
                            icon: const Icon(Icons.tune_rounded),
                          ),
                        ],
                        if (ref != null) ...[
                          IconButton(
                            tooltip: 'Lock reference',
                            onPressed: () {
                              controller.updateReference(ref.id, (r) => r.copyWith(locked: true));
                              controller.selectReference(null);
                            },
                            icon: const Icon(Icons.lock_outline),
                          ),
                          SizedBox(
                            width: 150,
                            child: Slider(
                              value: ref.opacity.clamp(0.05, 1.0).toDouble(),
                              min: 0.05,
                              max: 1,
                              onChanged: (v) => controller.updateReference(ref.id, (r) => r.copyWith(opacity: v)),
                            ),
                          ),
                        ],
                        if (controller.manipCanDelete)
                          FilledButton.tonalIcon(
                            onPressed: controller.manipDelete,
                            style: FilledButton.styleFrom(foregroundColor: scheme.error),
                            icon: const Icon(Icons.delete_outline),
                            label: const Text('Delete'),
                          ),
                      ],
                    ),
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
