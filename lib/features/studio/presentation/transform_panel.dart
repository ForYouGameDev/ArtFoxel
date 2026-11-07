import 'package:flutter/material.dart';

import '../../../core/theme/design_tokens.dart';
import '../application/sketch_controller.dart';
import '../domain/doc_geometry.dart';

/// Shown in place of the tool dock while a transform is being adjusted.
/// Everything is a live preview until Apply; Cancel leaves the layer exactly
/// as it was.
class TransformPanel extends StatelessWidget {
  const TransformPanel({required this.controller, super.key});

  final SketchController controller;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final s = controller.transformSession;
        if (s == null) return const SizedBox.shrink();
        Widget slider(String label, double value, double min, double max, void Function(TransformSession, double) set,
            {String suffix = ''}) {
          return Row(
            children: [
              SizedBox(width: 84, child: Text(label, style: Theme.of(context).textTheme.labelMedium)),
              Expanded(
                child: Slider(
                  value: value.clamp(min, max).toDouble(),
                  min: min,
                  max: max,
                  onChanged: (v) => controller.updateTransform((session) => set(session, v)),
                ),
              ),
              SizedBox(width: 56, child: Text('${value.toStringAsFixed(value.abs() < 10 ? 2 : 0)}$suffix', textAlign: TextAlign.end)),
            ],
          );
        }

        final w = controller.data.width.toDouble(), h = controller.data.height.toDouble();
        return Material(
          color: scheme.surfaceContainerLow,
          child: SafeArea(
            top: false,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * .45),
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.all(ArtFoxelSpacing.sm),
                children: [
                  Row(
                    children: [
                      Text('Transform', style: Theme.of(context).textTheme.titleSmall),
                      const Spacer(),
                      TextButton(onPressed: controller.resetTransform, child: const Text('Reset')),
                      TextButton(onPressed: controller.cancelTransform, child: const Text('Cancel')),
                      FilledButton(onPressed: controller.applyTransform, child: const Text('Apply')),
                    ],
                  ),
                  slider('Move X', s.translateX, -w, w, (t, v) => t.translateX = v, suffix: ' px'),
                  slider('Move Y', s.translateY, -h, h, (t, v) => t.translateY = v, suffix: ' px'),
                  slider('Scale X', s.scaleX, 0.05, 4, (t, v) => t.scaleX = v),
                  if (!s.uniform) slider('Scale Y', s.scaleY, 0.05, 4, (t, v) => t.scaleY = v),
                  slider('Rotate', s.rotationDegrees, -180, 180, (t, v) => t.rotationDegrees = v, suffix: '°'),
                  slider('Skew X', s.skewXDegrees, -80, 80, (t, v) => t.skewXDegrees = v, suffix: '°'),
                  slider('Skew Y', s.skewYDegrees, -80, 80, (t, v) => t.skewYDegrees = v, suffix: '°'),
                  Wrap(
                    spacing: ArtFoxelSpacing.xs,
                    children: [
                      FilterChip(
                        label: const Text('Uniform scale'),
                        selected: s.uniform,
                        onSelected: (v) => controller.updateTransform((t) => t.uniform = v),
                      ),
                      FilterChip(
                        label: const Text('Flip horizontal'),
                        selected: s.flipH,
                        onSelected: (v) => controller.updateTransform((t) => t.flipH = v),
                      ),
                      FilterChip(
                        label: const Text('Flip vertical'),
                        selected: s.flipV,
                        onSelected: (v) => controller.updateTransform((t) => t.flipV = v),
                      ),
                    ],
                  ),
                  const SizedBox(height: ArtFoxelSpacing.xs),
                  Text('Pivot (anchor)', style: Theme.of(context).textTheme.labelMedium),
                  Wrap(
                    spacing: 4,
                    children: [
                      for (final a in CanvasAnchor.values)
                        ChoiceChip(
                          label: Text(_anchorLabel(a)),
                          selected: s.anchor == a,
                          onSelected: (_) => controller.updateTransform((t) => t.anchor = a),
                        ),
                    ],
                  ),
                  Text(
                    'Brush sizes scale with the transform. Strokes stay editable; nothing is flattened. '
                    'Cancel discards the preview.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  static String _anchorLabel(CanvasAnchor a) => switch (a) {
        CanvasAnchor.topLeft => '↖',
        CanvasAnchor.topCenter => '↑',
        CanvasAnchor.topRight => '↗',
        CanvasAnchor.centerLeft => '←',
        CanvasAnchor.center => '●',
        CanvasAnchor.centerRight => '→',
        CanvasAnchor.bottomLeft => '↙',
        CanvasAnchor.bottomCenter => '↓',
        CanvasAnchor.bottomRight => '↘',
      };
}
