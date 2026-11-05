import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/design_tokens.dart';
import '../application/sketch_controller.dart';
import '../application/studio_settings.dart';
import '../domain/canvas_input.dart';

Future<void> showStudioSettingsSheet(
  BuildContext context,
  SketchController controller,
) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => _StudioSettingsSheet(controller: controller),
  );
}

class _StudioSettingsSheet extends ConsumerWidget {
  const _StudioSettingsSheet({required this.controller});

  final SketchController controller;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(studioSettingsProvider);
    final notifier = ref.read(studioSettingsProvider.notifier);

    Widget behaviorPicker(
      String label,
      CanvasInputBehavior value,
      CanvasInputSettings Function(CanvasInputBehavior) apply,
    ) {
      return Padding(
        padding: const EdgeInsets.only(bottom: ArtFoxelSpacing.sm),
        child: Row(
          children: [
            SizedBox(width: 72, child: Text(label)),
            Expanded(
              child: SegmentedButton<CanvasInputBehavior>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(
                    value: CanvasInputBehavior.draw,
                    label: Text('Draw'),
                  ),
                  ButtonSegment(
                    value: CanvasInputBehavior.navigate,
                    label: Text('Pan'),
                  ),
                  ButtonSegment(
                    value: CanvasInputBehavior.ignore,
                    label: Text('Off'),
                  ),
                ],
                selected: {value},
                onSelectionChanged: (selection) => notifier.update(
                  settings.copyWith(input: apply(selection.first)),
                ),
              ),
            ),
          ],
        ),
      );
    }

    return SafeArea(
      child: ListenableBuilder(
        listenable: controller,
        builder: (context, _) => SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(
            ArtFoxelSpacing.lg,
            0,
            ArtFoxelSpacing.lg,
            ArtFoxelSpacing.lg,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Brush', style: Theme.of(context).textTheme.titleMedium),
              _slider(
                'Flow ${(controller.flow * 100).round()}%',
                controller.flow,
                0.02,
                1,
                controller.setFlow,
              ),
              _slider(
                'Stabilization ${(controller.stabilization * 100).round()}%',
                controller.stabilization,
                0,
                1,
                controller.lowLatency ? null : controller.setStabilization,
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Low-latency mode'),
                subtitle: const Text(
                  'Turns smoothing and prediction off for the fastest response.',
                ),
                value: settings.lowLatency,
                onChanged: (value) {
                  controller.setLowLatency(value);
                  notifier.update(settings.copyWith(lowLatency: value));
                },
              ),
              const Divider(),
              Text(
                'Canvas gestures',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: ArtFoxelSpacing.sm),
              behaviorPicker(
                'Finger',
                settings.input.fingerBehavior,
                (value) => settings.input.copyWith(fingerBehavior: value),
              ),
              behaviorPicker(
                'Stylus',
                settings.input.stylusBehavior,
                (value) => settings.input.copyWith(stylusBehavior: value),
              ),
              behaviorPicker(
                'Mouse',
                settings.input.mouseBehavior,
                (value) => settings.input.copyWith(mouseBehavior: value),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Palm rejection'),
                subtitle: const Text(
                  'Ignore touches while a stylus is in use.',
                ),
                value: settings.input.palmRejection,
                onChanged: (value) => notifier.update(
                  settings.copyWith(
                    input: settings.input.copyWith(palmRejection: value),
                  ),
                ),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Two-finger rotation'),
                value: settings.input.rotationEnabled,
                onChanged: (value) => notifier.update(
                  settings.copyWith(
                    input: settings.input.copyWith(rotationEnabled: value),
                  ),
                ),
              ),
              const Divider(),
              Text(
                'Detected input',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: ArtFoxelSpacing.xs),
              Text(
                controller.observedCapabilities.label == 'position only'
                    ? 'Nothing detected yet. Draw a stroke to see whether your '
                        'device reports pressure or tilt.'
                    : 'Reported so far: ${controller.observedCapabilities.label}.',
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _slider(
    String label,
    double value,
    double min,
    double max,
    ValueChanged<double>? onChanged,
  ) {
    return Row(
      children: [
        SizedBox(width: 150, child: Text(label)),
        Expanded(
          child: Slider(
            value: value.clamp(min, max).toDouble(),
            min: min,
            max: max,
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }
}
