import 'package:flutter/material.dart';

import '../domain/color_math.dart';
import '../domain/gradient_model.dart';

/// Edits a [GradientData]: linear / radial, stops (position, colour,
/// opacity), interpolation and presets. Angular / reflected / diamond types
/// are not offered because they are not implemented.
class GradientEditor extends StatefulWidget {
  const GradientEditor({required this.initial, required this.onChanged, super.key});
  final GradientData initial;
  final ValueChanged<GradientData> onChanged;

  @override
  State<GradientEditor> createState() => _GradientEditorState();
}

class _GradientEditorState extends State<GradientEditor> {
  late GradientData _g = widget.initial;
  int _selected = 0;
  String? _error;
  final _hex = TextEditingController();

  @override
  void initState() {
    super.initState();
    _hex.text = ColorMath.toHex(_g.stops.first.argb, hash: false);
  }

  @override
  void dispose() {
    _hex.dispose();
    super.dispose();
  }

  void _update(GradientData Function() build) {
    try {
      final next = build();
      setState(() {
        _g = next;
        _error = null;
        _selected = _selected.clamp(0, _g.stops.length - 1);
      });
      widget.onChanged(next);
    } on GradientException catch (e) {
      setState(() => _error = e.message);
    }
  }

  void _setStop(int i, GradientStop s) => _update(() => _g.copyWith(stops: [..._g.stops]..[i] = s));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final stop = _g.stops[_selected.clamp(0, _g.stops.length - 1)];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Container(
        height: 40,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          gradient: LinearGradient(colors: [for (var i = 0; i <= 16; i++) Color(_g.colorAt(i / 16))]),
        ),
      ),
      const SizedBox(height: 8),
      Wrap(spacing: 6, children: [
        for (final p in GradientPresets.all)
          ActionChip(label: Text(p.name), onPressed: () => _update(() => p.gradient)),
      ]),
      const SizedBox(height: 8),
      SegmentedButton<GradientKind>(
        segments: const [
          ButtonSegment(value: GradientKind.linear, label: Text('Linear')),
          ButtonSegment(value: GradientKind.radial, label: Text('Radial')),
        ],
        selected: {_g.kind},
        onSelectionChanged: (s) => _update(() => _g.copyWith(kind: s.first)),
      ),
      if (_g.kind == GradientKind.linear)
        Row(children: [
          const SizedBox(width: 64, child: Text('Angle')),
          Expanded(child: Slider(value: _g.angleDegrees.clamp(0, 360).toDouble(), max: 360, onChanged: (v) => _update(() => _g.copyWith(angleDegrees: v.roundToDouble())))),
          Text('${_g.angleDegrees.round()}°'),
        ]),
      Wrap(spacing: 6, children: [
        for (final m in GradientInterpolation.values)
          ChoiceChip(label: Text(m.name), selected: _g.interpolation == m, onSelected: (_) => _update(() => _g.copyWith(interpolation: m))),
      ]),
      const SizedBox(height: 8),
      Text('Stops', style: theme.textTheme.titleSmall),
      Wrap(spacing: 8, children: [
        for (var i = 0; i < _g.stops.length; i++)
          GestureDetector(
            onTap: () => setState(() {
              _selected = i;
              _hex.text = ColorMath.toHex(_g.stops[i].argb, hash: false);
            }),
            child: Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: Color(_g.stops[i].argb),
                shape: BoxShape.circle,
                border: Border.all(color: i == _selected ? theme.colorScheme.primary : Colors.black26, width: i == _selected ? 3 : 1),
              ),
            ),
          ),
        IconButton(
          tooltip: 'Add stop',
          onPressed: _g.stops.length >= 16
              ? null
              : () => _update(() => _g.copyWith(stops: [..._g.stops, GradientStop(0.5, _g.colorAt(0.5))])),
          icon: const Icon(Icons.add_circle_outline),
        ),
      ]),
      Row(children: [
        const SizedBox(width: 64, child: Text('Position')),
        Expanded(child: Slider(value: stop.position, onChanged: (v) => _setStop(_selected, GradientStop(v, stop.argb, stop.opacity)))),
        Text('${(stop.position * 100).round()}%'),
      ]),
      Row(children: [
        const SizedBox(width: 64, child: Text('Opacity')),
        Expanded(child: Slider(value: stop.opacity, onChanged: (v) => _setStop(_selected, GradientStop(stop.position, stop.argb, v)))),
        Text('${(stop.opacity * 100).round()}%'),
      ]),
      Row(children: [
        Expanded(
          child: TextField(
            controller: _hex,
            maxLength: 7,
            decoration: const InputDecoration(labelText: 'Stop colour HEX', prefixText: '#', counterText: ''),
            onChanged: (v) {
              final c = ColorMath.parseHex(v);
              if (c != null) _setStop(_selected, GradientStop(stop.position, c, stop.opacity));
            },
          ),
        ),
        IconButton(
          tooltip: 'Remove stop',
          onPressed: _g.stops.length <= 2 ? null : () => _update(() => _g.copyWith(stops: [..._g.stops]..removeAt(_selected))),
          icon: const Icon(Icons.delete_outline),
        ),
      ]),
      if (_error != null) Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
    ]);
  }
}
