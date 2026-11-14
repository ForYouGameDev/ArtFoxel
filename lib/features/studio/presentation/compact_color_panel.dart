import 'package:flutter/material.dart';

import '../application/sketch_controller.dart';
import '../domain/color_math.dart';
import 'color_sheet.dart';
import 'color_wheel.dart';

/// Small floating colour panel: wheel, FG/BG chips, swap, recent colours and
/// an Expand button that opens the full Color Studio. It edits the same
/// controller colours as the studio, so both always agree.
class CompactColorPanel extends StatelessWidget {
  const CompactColorPanel({required this.controller, this.onClose, super.key});

  final SketchController controller;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final theme = Theme.of(context);
    return Material(
      elevation: 6,
      borderRadius: BorderRadius.circular(16),
      color: theme.colorScheme.surface.withValues(alpha: 0.96),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: ListenableBuilder(
          listenable: c,
          builder: (context, _) {
            return Column(mainAxisSize: MainAxisSize.min, children: [
              Row(children: [
                _chip(context, c.colorArgb, 'Foreground'),
                const SizedBox(width: 6),
                _chip(context, c.bgColorArgb, 'Background', onTap: () {
                  c.swapColors();
                }),
                const Spacer(),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Swap colours',
                  onPressed: c.swapColors,
                  icon: const Icon(Icons.swap_horiz_rounded, size: 20),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Eyedropper',
                  onPressed: () => c.setTool(SketchTool.eyedropper),
                  icon: const Icon(Icons.colorize, size: 20),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Open Color Studio',
                  onPressed: () => showColorSheet(context, c),
                  icon: const Icon(Icons.open_in_full_rounded, size: 20),
                ),
                if (onClose != null)
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: 'Close',
                    onPressed: onClose,
                    icon: const Icon(Icons.close_rounded, size: 20),
                  ),
              ]),
              ColorWheel(argb: c.colorArgb, size: 170, onChanged: c.setColor),
              SizedBox(
                height: 28,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    for (final col in c.recentColors)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: GestureDetector(
                          onTap: () => c.setColor(col),
                          child: Container(
                            width: 26,
                            height: 26,
                            decoration: BoxDecoration(
                              color: Color(col),
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.black26),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              Row(children: [
                const Text('A', style: TextStyle(fontSize: 12)),
                Expanded(
                  child: Slider(value: c.opacity.clamp(0.0, 1.0).toDouble(), onChanged: c.setOpacity),
                ),
                Text('#${ColorMath.toHex(c.colorArgb, hash: false)}', style: theme.textTheme.bodySmall),
              ]),
            ]);
          },
        ),
      ),
    );
  }

  Widget _chip(BuildContext context, int argb, String label, {VoidCallback? onTap}) {
    return Semantics(
      label: label,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: Color(argb),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Theme.of(context).colorScheme.outline),
          ),
        ),
      ),
    );
  }
}
