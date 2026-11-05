import 'package:flutter/material.dart';

import '../../../core/theme/design_tokens.dart';
import '../application/sketch_controller.dart';
import '../domain/doc_geometry.dart';

enum CanvasSizeOperation {
  cropImage('Crop image', 'Keeps a rectangle of the artwork. The canvas becomes that rectangle.'),
  resizeCanvas('Resize canvas', 'Changes the canvas size. The artwork keeps its size and sits at the anchor.'),
  resizeImage('Resize image', 'Scales the canvas and all artwork together.');

  const CanvasSizeOperation(this.label, this.help);
  final String label;
  final String help;
}

Future<void> showCanvasSizeDialog(BuildContext context, SketchController controller) {
  return showDialog<void>(
    context: context,
    builder: (context) => _CanvasSizeDialog(controller: controller),
  );
}

class _CanvasSizeDialog extends StatefulWidget {
  const _CanvasSizeDialog({required this.controller});

  final SketchController controller;

  @override
  State<_CanvasSizeDialog> createState() => _CanvasSizeDialogState();
}

class _CanvasSizeDialogState extends State<_CanvasSizeDialog> {
  var _op = CanvasSizeOperation.resizeCanvas;
  var _anchor = CanvasAnchor.center;
  var _discard = false;
  late final TextEditingController _w, _h, _x, _y;
  String? _error;

  @override
  void initState() {
    super.initState();
    final d = widget.controller.data;
    _w = TextEditingController(text: '${d.width}');
    _h = TextEditingController(text: '${d.height}');
    _x = TextEditingController(text: '0');
    _y = TextEditingController(text: '0');
  }

  @override
  void dispose() {
    for (final c in [_w, _h, _x, _y]) {
      c.dispose();
    }
    super.dispose();
  }

  void _apply() {
    final w = int.tryParse(_w.text.trim());
    final h = int.tryParse(_h.text.trim());
    final x = int.tryParse(_x.text.trim()) ?? 0;
    final y = int.tryParse(_y.text.trim()) ?? 0;
    if (w == null || h == null || w < 1 || h < 1 || w > DocGeometry.maxCanvasSide || h > DocGeometry.maxCanvasSide) {
      setState(() => _error = 'Enter sizes from 1 to ${DocGeometry.maxCanvasSide} px.');
      return;
    }
    final c = widget.controller;
    switch (_op) {
      case CanvasSizeOperation.cropImage:
        c.cropImage(Rect.fromLTWH(x.toDouble(), y.toDouble(), w.toDouble(), h.toDouble()), discardOutside: _discard);
      case CanvasSizeOperation.resizeCanvas:
        c.resizeCanvas(w, h, anchor: _anchor, discardOutside: _discard);
      case CanvasSizeOperation.resizeImage:
        c.resizeImage(w, h);
    }
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.controller.data;
    return AlertDialog(
      title: const Text('Canvas size'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Current: ${d.width} × ${d.height} px'),
            const SizedBox(height: ArtFoxelSpacing.sm),
            Wrap(
              spacing: ArtFoxelSpacing.xs,
              children: [
                for (final op in CanvasSizeOperation.values)
                  ChoiceChip(
                    label: Text(op.label),
                    selected: _op == op,
                    onSelected: (_) => setState(() => _op = op),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(_op.help, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: ArtFoxelSpacing.sm),
            Row(
              children: [
                Expanded(child: TextField(controller: _w, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Width'))),
                const SizedBox(width: ArtFoxelSpacing.sm),
                Expanded(child: TextField(controller: _h, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Height'))),
              ],
            ),
            if (_op == CanvasSizeOperation.cropImage)
              Row(
                children: [
                  Expanded(child: TextField(controller: _x, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Left'))),
                  const SizedBox(width: ArtFoxelSpacing.sm),
                  Expanded(child: TextField(controller: _y, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Top'))),
                ],
              ),
            if (_op == CanvasSizeOperation.resizeCanvas) ...[
              const SizedBox(height: ArtFoxelSpacing.sm),
              const Text('Anchor'),
              Wrap(
                spacing: 4,
                children: [
                  for (final a in CanvasAnchor.values)
                    ChoiceChip(
                      label: Text(a.name),
                      selected: _anchor == a,
                      onSelected: (_) => setState(() => _anchor = a),
                    ),
                ],
              ),
            ],
            if (_op != CanvasSizeOperation.resizeImage)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Discard strokes outside the canvas'),
                subtitle: const Text('Off keeps them stored (they return if you enlarge the canvas).'),
                value: _discard,
                onChanged: (v) => setState(() => _discard = v),
              ),
            if (_error != null)
              Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            const SizedBox(height: 4),
            Text('You can undo this. Selections are cleared.', style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _apply, child: Text(_op.label)),
      ],
    );
  }
}
