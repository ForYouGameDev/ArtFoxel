import 'package:flutter/material.dart';

import '../../../core/theme/design_tokens.dart';
import '../application/sketch_controller.dart';

const List<int> _palette = [
  0xFF111111,
  0xFF5A5A5A,
  0xFFFFFFFF,
  0xFFE53935,
  0xFFFB8C00,
  0xFFFDD835,
  0xFF43A047,
  0xFF00ACC1,
  0xFF1E88E5,
  0xFF5E35B1,
  0xFFD81B60,
  0xFF8D6E63,
];

String _hex(int argb) =>
    (argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase();

Future<void> showColorSheet(BuildContext context, SketchController controller) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => _ColorSheet(controller: controller),
  );
}

class _ColorSheet extends StatefulWidget {
  const _ColorSheet({required this.controller});

  final SketchController controller;

  @override
  State<_ColorSheet> createState() => _ColorSheetState();
}

class _ColorSheetState extends State<_ColorSheet> {
  late HSVColor _hsv;
  late final TextEditingController _hexController;

  @override
  void initState() {
    super.initState();
    final argb = widget.controller.colorArgb;
    _hsv = HSVColor.fromColor(Color(argb));
    _hexController = TextEditingController(text: _hex(argb));
  }

  @override
  void dispose() {
    _hexController.dispose();
    super.dispose();
  }

  void _apply(HSVColor hsv, {bool updateHex = true}) {
    setState(() => _hsv = hsv);
    final argb = hsv.toColor().toARGB32();
    widget.controller.setColor(argb);
    if (updateHex) _hexController.text = _hex(argb);
  }

  void _setArgb(int argb) => _apply(HSVColor.fromColor(Color(argb)));

  void _onHex(String value) {
    if (value.length != 6) return;
    final parsed = int.tryParse(value, radix: 16);
    if (parsed == null) return;
    _apply(HSVColor.fromColor(Color(0xFF000000 | parsed)), updateHex: false);
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final color = _hsv.toColor();
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          ArtFoxelSpacing.lg,
          0,
          ArtFoxelSpacing.lg,
          ArtFoxelSpacing.lg + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: Theme.of(context).colorScheme.outline,
                      ),
                    ),
                  ),
                  const SizedBox(width: ArtFoxelSpacing.md),
                  SizedBox(
                    width: 120,
                    child: TextField(
                      controller: _hexController,
                      maxLength: 6,
                      onChanged: _onHex,
                      decoration: const InputDecoration(
                        labelText: 'Hex',
                        prefixText: '#',
                        counterText: '',
                      ),
                    ),
                  ),
                  const Spacer(),
                  FilledButton.tonalIcon(
                    onPressed: () {
                      controller.setTool(SketchTool.eyedropper);
                      Navigator.of(context).pop();
                    },
                    icon: const Icon(Icons.colorize_rounded),
                    label: const Text('Eyedropper'),
                  ),
                ],
              ),
              const SizedBox(height: ArtFoxelSpacing.md),
              _labeledSlider(
                'Hue',
                _hsv.hue,
                0,
                360,
                (v) => _apply(_hsv.withHue(v)),
              ),
              _labeledSlider(
                'Saturation',
                _hsv.saturation,
                0,
                1,
                (v) => _apply(_hsv.withSaturation(v)),
              ),
              _labeledSlider(
                'Brightness',
                _hsv.value,
                0,
                1,
                (v) => _apply(_hsv.withValue(v)),
              ),
              if (controller.recentColors.isNotEmpty) ...[
                const SizedBox(height: ArtFoxelSpacing.sm),
                Text('Recent', style: Theme.of(context).textTheme.labelLarge),
                const SizedBox(height: ArtFoxelSpacing.xs),
                _swatches(controller.recentColors),
              ],
              const SizedBox(height: ArtFoxelSpacing.sm),
              Text('Palette', style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: ArtFoxelSpacing.xs),
              _swatches(_palette),
            ],
          ),
        ),
      ),
    );
  }

  Widget _labeledSlider(
    String label,
    double value,
    double min,
    double max,
    ValueChanged<double> onChanged,
  ) {
    return Row(
      children: [
        SizedBox(width: 90, child: Text(label)),
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

  Widget _swatches(List<int> colors) {
    return Wrap(
      spacing: ArtFoxelSpacing.xs,
      runSpacing: ArtFoxelSpacing.xs,
      children: [
        for (final argb in colors)
          Semantics(
            button: true,
            label: 'Colour #${_hex(argb)}',
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: () => _setArgb(argb),
              child: Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: Color(argb),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Theme.of(context).colorScheme.outline,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
