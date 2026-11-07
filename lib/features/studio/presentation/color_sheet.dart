import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/theme/design_tokens.dart';
import '../application/sketch_controller.dart';
import '../application/studio_libraries.dart';
import '../domain/color_math.dart';
import '../domain/palette.dart';

Future<void> showColorSheet(BuildContext context, SketchController controller) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.8,
      maxChildSize: 0.95,
      builder: (context, scroll) => ColorStudio(controller: controller, scroll: scroll),
    ),
  );
}

enum _Model { rgb, hsv, hsl }

/// Colour Studio: RGB / HSV / HSL / HEX editing, foreground and background
/// colours, harmonies, contrast check and named palettes with import/export.
class ColorStudio extends StatefulWidget {
  const ColorStudio({required this.controller, this.scroll, super.key});
  final SketchController controller;
  final ScrollController? scroll;

  @override
  State<ColorStudio> createState() => _ColorStudioState();
}

class _ColorStudioState extends State<ColorStudio> {
  bool _editBackground = false;
  _Model _model = _Model.hsv;
  Harmony _harmony = Harmony.complementary;
  final _hex = TextEditingController();
  String? _hexError;
  List<ColorPalette> _palettes = [...BuiltInPalettes.all];
  String _paletteId = BuiltInPalettes.all.first.id;
  late final StudioLibraries _libs;

  SketchController get c => widget.controller;
  int get _current => _editBackground ? c.bgColorArgb : c.colorArgb;

  @override
  void initState() {
    super.initState();
    _libs = StudioLibraries(SharedPreferences.getInstance());
    _hex.text = ColorMath.toHex(_current, hash: false);
    _loadPalettes();
  }

  Future<void> _loadPalettes() async {
    try {
      final custom = await _libs.loadPalettes();
      if (mounted) setState(() => _palettes = [...BuiltInPalettes.all, ...custom]);
    } catch (_) {}
  }

  @override
  void dispose() {
    _hex.dispose();
    super.dispose();
  }

  void _set(int argb) {
    if (_editBackground) {
      c.setBackgroundColor(argb);
    } else {
      c.setColor(argb);
    }
    _hex.text = ColorMath.toHex(_current, hash: false);
    setState(() => _hexError = null);
  }

  void _msg(String t) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(t)));

  Widget _swatch(int argb, {double size = 36, VoidCallback? onTap, bool selected = false}) {
    final l = ColorMath.luminance(argb);
    return Semantics(
      button: true,
      label: 'Colour #${ColorMath.toHex(argb, hash: false)}',
      child: InkWell(
        onTap: onTap ?? () => _set(argb),
        customBorder: const CircleBorder(),
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: Color(argb),
            shape: BoxShape.circle,
            border: Border.all(
              color: selected ? Theme.of(context).colorScheme.primary : (l > 0.9 ? Colors.black26 : Colors.transparent),
              width: selected ? 3 : 1,
            ),
          ),
        ),
      ),
    );
  }

  Widget _slider(String label, double v, double max, ValueChanged<double> on, {Gradient? track}) {
    return Row(children: [
      SizedBox(width: 28, child: Text(label, style: Theme.of(context).textTheme.labelLarge)),
      Expanded(
        child: Semantics(
          label: '$label slider',
          child: Slider(value: v.clamp(0, max).toDouble(), max: max, onChanged: on),
        ),
      ),
      SizedBox(width: 40, child: Text(v.round().toString(), textAlign: TextAlign.end)),
    ]);
  }

  Widget _sliders() {
    final argb = _current;
    switch (_model) {
      case _Model.rgb:
        final r = ColorMath.red(argb), g = ColorMath.green(argb), b = ColorMath.blue(argb);
        return Column(children: [
          _slider('R', r.toDouble(), 255, (v) => _set(ColorMath.rgb(v.round(), g, b))),
          _slider('G', g.toDouble(), 255, (v) => _set(ColorMath.rgb(r, v.round(), b))),
          _slider('B', b.toDouble(), 255, (v) => _set(ColorMath.rgb(r, g, v.round()))),
        ]);
      case _Model.hsv:
        final h = ColorMath.toHsv(argb);
        return Column(children: [
          _slider('H', h.$1, 360, (v) => _set(ColorMath.fromHsv(v, h.$2, h.$3))),
          _slider('S', h.$2 * 100, 100, (v) => _set(ColorMath.fromHsv(h.$1, v / 100, h.$3))),
          _slider('V', h.$3 * 100, 100, (v) => _set(ColorMath.fromHsv(h.$1, h.$2, v / 100))),
        ]);
      case _Model.hsl:
        final h = ColorMath.toHsl(argb);
        return Column(children: [
          _slider('H', h.$1, 360, (v) => _set(ColorMath.fromHsl(v, h.$2, h.$3))),
          _slider('S', h.$2 * 100, 100, (v) => _set(ColorMath.fromHsl(h.$1, v / 100, h.$3))),
          _slider('L', h.$3 * 100, 100, (v) => _set(ColorMath.fromHsl(h.$1, h.$2, v / 100))),
        ]);
    }
  }

  ColorPalette get _palette =>
      _palettes.firstWhere((p) => p.id == _paletteId, orElse: () => _palettes.first);

  Future<void> _savePalettes() async {
    try {
      await _libs.savePalettes(_palettes);
    } catch (_) {
      _msg('The palette could not be saved.');
    }
  }

  Future<void> _newPalette() async {
    final name = await _ask('New palette name');
    if (name == null || name.trim().isEmpty) return;
    final id = 'pal-${DateTime.now().microsecondsSinceEpoch}';
    setState(() {
      _palettes = [..._palettes, ColorPalette(id: id, name: name.trim(), colors: [_current])];
      _paletteId = id;
    });
    await _savePalettes();
  }

  Future<void> _addToPalette() async {
    final p = _palette;
    if (p.builtIn) {
      _msg('Built-in palettes cannot be changed. Make a new palette first.');
      return;
    }
    if (p.colors.length >= ColorPalette.maxColors) {
      _msg('A palette holds at most ${ColorPalette.maxColors} colours.');
      return;
    }
    if (p.colors.contains(_current)) return;
    setState(() => _palettes = [for (final x in _palettes) x.id == p.id ? p.copyWith(colors: [...p.colors, _current]) : x]);
    await _savePalettes();
  }

  Future<void> _removeFromPalette(int color) async {
    final p = _palette;
    if (p.builtIn) return;
    setState(() => _palettes = [for (final x in _palettes) x.id == p.id ? p.copyWith(colors: [...p.colors]..remove(color)) : x]);
    await _savePalettes();
  }

  Future<void> _deletePalette() async {
    final p = _palette;
    if (p.builtIn) return;
    setState(() {
      _palettes = [for (final x in _palettes) if (x.id != p.id) x];
      _paletteId = _palettes.first.id;
    });
    await _savePalettes();
  }

  Future<String?> _ask(String title, {String initial = '', int lines = 1}) {
    final ctl = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(controller: ctl, autofocus: true, minLines: lines, maxLines: lines == 1 ? 1 : 12),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, ctl.text), child: const Text('OK')),
        ],
      ),
    );
  }

  Future<void> _export({bool gpl = false}) async {
    final p = _palette;
    final text = gpl ? PaletteCodec.exportGpl(p) : PaletteCodec.export([p]);
    await Clipboard.setData(ClipboardData(text: text));
    _msg('Palette "${p.name}" copied to the clipboard.');
  }

  Future<void> _import() async {
    final clip = await Clipboard.getData(Clipboard.kTextPlain);
    final text = await _ask('Paste palette (ARTFOXEL JSON or GIMP .gpl)', initial: clip?.text ?? '', lines: 6);
    if (text == null || text.trim().isEmpty) return;
    try {
      final imported = PaletteCodec.import(text, existingNames: [for (final p in _palettes) p.name]);
      setState(() {
        _palettes = [..._palettes, ...imported];
        _paletteId = imported.last.id;
      });
      await _savePalettes();
      _msg('Imported ${imported.length} palette(s).');
    } on PaletteException catch (e) {
      _msg(e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final fg = c.colorArgb, bg = c.bgColorArgb;
        final ratio = ColorMath.contrastRatio(fg, bg);
        final harmony = ColorMath.harmony(_current, _harmony);
        final p = _palette;
        return ListView(
          controller: widget.scroll,
          padding: const EdgeInsets.fromLTRB(ArtFoxelSpacing.md, 0, ArtFoxelSpacing.md, ArtFoxelSpacing.xl),
          children: [
            Row(children: [
              ChoiceChip(
                label: const Text('Foreground'),
                avatar: _swatch(fg, size: 20, onTap: () => setState(() => _editBackground = false)),
                selected: !_editBackground,
                onSelected: (_) => setState(() {
                  _editBackground = false;
                  _hex.text = ColorMath.toHex(fg, hash: false);
                }),
              ),
              const SizedBox(width: 8),
              ChoiceChip(
                label: const Text('Background'),
                avatar: _swatch(bg, size: 20, onTap: () => setState(() => _editBackground = true)),
                selected: _editBackground,
                onSelected: (_) => setState(() {
                  _editBackground = true;
                  _hex.text = ColorMath.toHex(bg, hash: false);
                }),
              ),
              const Spacer(),
              IconButton(tooltip: 'Swap colours', onPressed: () {
                c.swapColors();
                _hex.text = ColorMath.toHex(_current, hash: false);
              }, icon: const Icon(Icons.swap_horiz_rounded)),
              IconButton(tooltip: 'Reset to black and white', onPressed: () {
                c.resetColors();
                _hex.text = ColorMath.toHex(_current, hash: false);
              }, icon: const Icon(Icons.restart_alt_rounded)),
            ]),
            Container(
              height: 48,
              margin: const EdgeInsets.symmetric(vertical: 8),
              decoration: BoxDecoration(color: Color(_current), borderRadius: BorderRadius.circular(12)),
              alignment: Alignment.center,
              child: Text('#${ColorMath.toHex(_current, hash: false)}', style: TextStyle(color: Color(ColorMath.readableOn(_current)), fontWeight: FontWeight.w700)),
            ),
            SegmentedButton<_Model>(
              segments: const [
                ButtonSegment(value: _Model.rgb, label: Text('RGB')),
                ButtonSegment(value: _Model.hsv, label: Text('HSV')),
                ButtonSegment(value: _Model.hsl, label: Text('HSL')),
              ],
              selected: {_model},
              onSelectionChanged: (s) => setState(() => _model = s.first),
            ),
            _sliders(),
            Row(children: [
              Expanded(
                child: TextField(
                  controller: _hex,
                  maxLength: 7,
                  textCapitalization: TextCapitalization.characters,
                  decoration: InputDecoration(labelText: 'HEX (RGB or RRGGBB)', prefixText: '#', counterText: '', errorText: _hexError),
                  onChanged: (v) {
                    final parsed = ColorMath.parseHex(v);
                    if (parsed == null) {
                      setState(() => _hexError = v.isEmpty ? null : 'Not a valid colour code');
                    } else {
                      if (_editBackground) {
                        c.setBackgroundColor(parsed);
                      } else {
                        c.setColor(parsed);
                      }
                      setState(() => _hexError = null);
                    }
                  },
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filledTonal(
                tooltip: 'Eyedropper: tap the canvas',
                onPressed: () {
                  c.setTool(SketchTool.eyedropper);
                  Navigator.pop(context);
                },
                icon: const Icon(Icons.colorize),
              ),
            ]),
            const SizedBox(height: 8),
            Text('Contrast foreground / background: ${ratio.toStringAsFixed(2)}:1 · ${ColorMath.wcagGrade(fg, bg)}', style: theme.textTheme.bodySmall),
            const Divider(height: 24),
            Text('Harmonies', style: theme.textTheme.titleSmall),
            Wrap(spacing: 6, children: [
              for (final h in Harmony.values)
                ChoiceChip(label: Text(h.label), selected: _harmony == h, onSelected: (_) => setState(() => _harmony = h)),
            ]),
            const SizedBox(height: 6),
            Wrap(spacing: 8, runSpacing: 8, children: [for (final h in harmony) _swatch(h)]),
            const Divider(height: 24),
            Row(children: [
              Text('Palettes', style: theme.textTheme.titleSmall),
              const Spacer(),
              PopupMenuButton<String>(
                tooltip: 'Palette actions',
                onSelected: (v) {
                  switch (v) {
                    case 'new': _newPalette();
                    case 'add': _addToPalette();
                    case 'json': _export();
                    case 'gpl': _export(gpl: true);
                    case 'import': _import();
                    case 'delete': _deletePalette();
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'new', child: Text('New palette from current colour')),
                  PopupMenuItem(value: 'add', child: Text('Add current colour')),
                  PopupMenuItem(value: 'json', child: Text('Copy as ARTFOXEL JSON')),
                  PopupMenuItem(value: 'gpl', child: Text('Copy as GIMP .gpl')),
                  PopupMenuItem(value: 'import', child: Text('Import (paste)…')),
                  PopupMenuItem(value: 'delete', child: Text('Delete palette')),
                ],
              ),
            ]),
            Wrap(spacing: 6, children: [
              for (final pal in _palettes)
                ChoiceChip(label: Text(pal.name), selected: pal.id == _paletteId, onSelected: (_) => setState(() => _paletteId = pal.id)),
            ]),
            const SizedBox(height: 6),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final col in p.colors)
                GestureDetector(
                  onLongPress: p.builtIn ? null : () => _removeFromPalette(col),
                  child: _swatch(col, selected: col == _current),
                ),
            ]),
            if (!p.builtIn) Padding(padding: const EdgeInsets.only(top: 4), child: Text('Long-press a colour to remove it.', style: theme.textTheme.bodySmall)),
            if (c.recentColors.isNotEmpty) ...[
              const Divider(height: 24),
              Text('Recent', style: theme.textTheme.titleSmall),
              const SizedBox(height: 6),
              Wrap(spacing: 8, runSpacing: 8, children: [for (final col in c.recentColors) _swatch(col, selected: col == _current)]),
            ],
          ],
        );
      },
    );
  }
}
