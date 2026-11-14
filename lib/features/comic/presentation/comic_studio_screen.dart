import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/diagnostics/app_log.dart';
import '../application/comic_providers.dart';
import '../data/comic_storage.dart';
import '../domain/comic_model.dart';
import '../rendering/comic_painter.dart';

/// Comic / manga editor: pages, panel layouts, screentones, speed lines,
/// bubbles and text. Separate from Sketch Studio.
class ComicStudioScreen extends ConsumerStatefulWidget {
  const ComicStudioScreen({this.projectId, super.key});
  final String? projectId;

  @override
  ConsumerState<ComicStudioScreen> createState() => _ComicStudioScreenState();
}

class _ComicStudioScreenState extends ConsumerState<ComicStudioScreen> {
  ComicDocument _doc = ComicDocument.create(title: 'Untitled comic', template: PanelTemplate.byId('manga-classic'));
  ComicStorage? _storage;
  int _pageIndex = 0;
  String? _panelId;
  String? _elementId;
  int? _dragCorner;
  bool _loading = true;
  bool _dirty = false;
  bool _guides = true;
  String? _error;

  ComicPage get _page => _doc.pages[_pageIndex.clamp(0, _doc.pages.length - 1)];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final storage = await ref.read(comicStorageProvider.future);
      _storage = storage;
      if (widget.projectId != null) {
        final doc = await storage.load(widget.projectId!);
        if (doc != null) _doc = doc;
      }
      await _loadFonts();
    } on ComicException catch (e) {
      _error = e.message;
    } catch (error, stack) {
      AppLog.error('Opening comic failed', error: error, stackTrace: stack);
      _error = 'The comic could not be opened.';
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _loadFonts() async {
    final id = widget.projectId;
    if (id == null) return;
    for (final f in _doc.fonts) {
      final bytes = await _storage!.readFont(id, f.fileName);
      if (bytes == null) continue;
      try {
        // Re-validate on every open: never trust a file just because it is on disk.
        FontImportValidator.validate(bytes, licenceAcknowledged: f.acknowledged);
        final loader = FontLoader(f.family)..addFont(Future.value(ByteData.sublistView(bytes)));
        await loader.load();
      } on FontImportException catch (e) {
        _msg('Font "${f.family}" skipped: ${e.message}');
      }
    }
  }

  void _msg(String t) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(t)));
  }

  void _edit(void Function() change) {
    try {
      setState(() {
        change();
        _dirty = true;
      });
    } on ComicException catch (e) {
      _msg(e.message);
    }
  }

  Future<void> _save() async {
    final id = widget.projectId;
    if (_storage == null || id == null) {
      _msg('This comic is not linked to a project, so it cannot be saved.');
      return;
    }
    try {
      await _storage!.save(id, _doc);
      if (mounted) setState(() => _dirty = false);
      _msg('Saved.');
    } catch (error, stack) {
      AppLog.error('Saving comic failed', error: error, stackTrace: stack);
      _msg('Saving failed. Your changes are still open here.');
    }
  }

  Future<void> _exportPage() async {
    final id = widget.projectId;
    if (_storage == null || id == null) {
      _msg('Save the comic as a project first.');
      return;
    }
    try {
      final spec = _doc.specFor(_page);
      final bytes = await ComicPainter.renderPng(_doc, _page, scale: spec.dpi > 150 ? 1 : 1);
      final f = await _storage!.writeExport(id, '${_page.id}.png', bytes);
      _msg('Exported ${spec.widthPx}×${spec.heightPx} px PNG (no guides): ${f.path}');
    } catch (error, stack) {
      AppLog.error('Exporting page failed', error: error, stackTrace: stack);
      _msg('The page could not be exported.');
    }
  }

  // ---- hit testing & dragging --------------------------------------------------

  Offset _toPage(Offset local, Size box) {
    final spec = _doc.specFor(_page);
    final s = spec.canvasSize.width / box.width;
    return local * s;
  }

  void _tap(Offset p) {
    final els = _page.elements.reversed.where((e) => !e.hidden && e.bounds.inflate(8).contains(p));
    setState(() {
      if (els.isNotEmpty) {
        _elementId = els.first.id;
        _panelId = els.first.panelId;
      } else {
        _elementId = null;
        _panelId = _page.panelAt(p)?.id;
      }
    });
  }

  void _panStart(Offset p) {
    final panel = _panelId == null ? null : _page.panelById(_panelId!);
    _dragCorner = null;
    if (panel != null && _elementId == null) {
      for (var i = 0; i < panel.corners.length; i++) {
        if ((panel.corners[i] - p).distance < 40) {
          _dragCorner = i;
          return;
        }
      }
    }
  }

  void _panUpdate(Offset p, Offset delta) {
    final panel = _panelId == null ? null : _page.panelById(_panelId!);
    if (_elementId != null) {
      final e = _page.elementById(_elementId!);
      if (e == null) return;
      _edit(() => _replaceElement(_translateElement(e, delta)));
    } else if (panel != null && _dragCorner != null) {
      _edit(() => _replacePanel(panel.moveCorner(_dragCorner!, p)));
    } else if (panel != null) {
      _edit(() => _replacePanel(panel.translate(delta)));
    }
  }

  ComicElement _translateElement(ComicElement e, Offset d) => switch (e) {
        ScreentoneElement() => e.copyWith(area: e.area.shift(d)),
        SpeedLinesElement() => e.copyWith(area: e.area.shift(d), center: e.center == null ? null : e.center! + d),
        BubbleElement() => e.copyWith(rect: e.rect.shift(d), tailTip: e.tailTip == null ? null : e.tailTip! + d),
        TextBoxElement() => e.copyWith(rect: e.rect.shift(d)),
        _ => e,
      };

  void _replaceElement(ComicElement e) {
    final i = _page.elements.indexWhere((x) => x.id == e.id);
    if (i >= 0) _page.elements[i] = e;
  }

  void _replacePanel(Panel p) {
    final i = _page.panels.indexWhere((x) => x.id == p.id);
    if (i >= 0) _page.panels[i] = p;
  }

  // ---- adding things --------------------------------------------------------------

  Rect get _targetArea {
    final panel = _panelId == null ? null : _page.panelById(_panelId!);
    return panel?.bounds ?? _doc.specFor(_page).safeRect;
  }

  void _add(String what) {
    if (_page.elements.length >= ComicPage.maxElements) {
      _msg('This page has too many elements.');
      return;
    }
    final id = _page.nextElementId();
    final area = _targetArea;
    final c = area.center;
    final box = Rect.fromCenter(center: c, width: area.width * 0.5, height: area.height * 0.25);
    final ComicElement el = switch (what) {
      'tone' => ScreentoneElement(id: id, area: area, panelId: _panelId),
      'lines' => SpeedLinesElement(id: id, area: area, panelId: _panelId),
      'bubble' => BubbleElement(
          id: id,
          rect: box,
          shape: BubbleShape.oval,
          tailTip: box.bottomCenter + Offset(0, box.height * 0.5),
          text: const TextSpec(text: 'Text'),
        ),
      'narration' => BubbleElement(id: id, rect: Rect.fromLTWH(area.left + 12, area.top + 12, area.width * 0.6, 90), shape: BubbleShape.narration, text: const TextSpec(text: 'Narration', align: TextAlignment.left)),
      _ => TextBoxElement(id: id, rect: box, text: const TextSpec(text: 'Text', size: 48, weight: 800)),
    };
    _edit(() {
      _page.elements.add(el);
      _elementId = id;
    });
  }

  // ---- inspector ---------------------------------------------------------------------

  Widget _slider(String label, double v, double min, double max, ValueChanged<double> on) => Row(children: [
        SizedBox(width: 96, child: Text(label)),
        Expanded(child: Slider(value: v.clamp(min, max).toDouble(), min: min, max: max, onChanged: on)),
        SizedBox(width: 44, child: Text(v.toStringAsFixed(v.abs() < 10 ? 1 : 0), textAlign: TextAlign.end)),
      ]);

  List<Widget> _textFields(TextSpec t, void Function(TextSpec) on) => [
        TextFormField(
          key: ValueKey('text-$_elementId'),
          initialValue: t.text,
          maxLines: 3,
          maxLength: TextSpec.maxChars,
          decoration: const InputDecoration(labelText: 'Text'),
          onChanged: (v) => on(t.copyWith(text: v)),
        ),
        Wrap(spacing: 6, children: [
          for (final a in TextAlignment.values) ChoiceChip(label: Text(a.name), selected: t.align == a, onSelected: (_) => on(t.copyWith(align: a))),
        ]),
        DropdownButton<String?>(
          value: _doc.fonts.any((f) => f.family == t.family) ? t.family : null,
          hint: const Text('Default font'),
          items: [
            const DropdownMenuItem(value: null, child: Text('Default font')),
            for (final f in _doc.fonts) DropdownMenuItem(value: f.family, child: Text(f.family)),
          ],
          onChanged: (v) => on(t.copyWith(family: v)),
        ),
        _slider('Size', t.size, 8, 200, (v) => on(t.copyWith(size: v.roundToDouble()))),
        _slider('Weight', t.weight.toDouble(), 100, 900, (v) => on(t.copyWith(weight: (v / 100).round() * 100))),
        _slider('Line height', t.lineHeight, 0.8, 2.5, (v) => on(t.copyWith(lineHeight: v))),
        _slider('Letter space', t.letterSpacing, -2, 20, (v) => on(t.copyWith(letterSpacing: v))),
        _slider('Outline', t.outlineWidth, 0, 12, (v) => on(t.copyWith(outlineWidth: v))),
        _slider('Shadow blur', t.shadowBlur, 0, 20, (v) => on(t.copyWith(shadowBlur: v, shadowDx: v > 0 ? 3 : 0, shadowDy: v > 0 ? 3 : 0))),
        SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Vertical text'), value: t.vertical, onChanged: (v) => on(t.copyWith(vertical: v))),
        SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Italic'), value: t.italic, onChanged: (v) => on(t.copyWith(italic: v))),
      ];

  Widget _inspector() {
    final e = _elementId == null ? null : _page.elementById(_elementId!);
    final panel = _panelId == null ? null : _page.panelById(_panelId!);
    final children = <Widget>[];
    void upd(ComicElement n) => _edit(() => _replaceElement(n));
    if (e is ScreentoneElement) {
      children.addAll([
        Wrap(spacing: 6, children: [for (final p in TonePattern.values) ChoiceChip(label: Text(p.label), selected: e.pattern == p, onSelected: (_) => upd(e.copyWith(pattern: p)))]),
        _slider('Spacing', e.spacing, ScreentoneElement.minSpacing, 60, (v) => upd(e.copyWith(spacing: v))),
        _slider('Density', e.density, 0, 1, (v) => upd(e.copyWith(density: v))),
        _slider('Angle', e.angleDegrees, -90, 90, (v) => upd(e.copyWith(angleDegrees: v))),
        if (e.estimatedMarks() > ScreentoneElement.maxMarks) const Text('Too many marks: increase the spacing.', style: TextStyle(color: Colors.red)),
      ]);
    } else if (e is SpeedLinesElement) {
      children.addAll([
        Wrap(spacing: 6, children: [for (final m in SpeedLineMode.values) ChoiceChip(label: Text(m.name), selected: e.mode == m, onSelected: (_) => upd(e.copyWith(mode: m)))]),
        _slider('Lines', e.count.toDouble(), 8, 300, (v) => upd(e.copyWith(count: v.round()))),
        _slider('Empty centre', e.innerRadius, 0, 0.9, (v) => upd(e.copyWith(innerRadius: v))),
        _slider('Thickness', e.maxWidth, 1, 30, (v) => upd(e.copyWith(maxWidth: v))),
        _slider('Direction', e.angleDegrees, -180, 180, (v) => upd(e.copyWith(angleDegrees: v))),
        _slider('Seed', e.seed.toDouble(), 1, 200, (v) => upd(e.copyWith(seed: v.round()))),
      ]);
    } else if (e is BubbleElement) {
      children.addAll([
        Wrap(spacing: 6, children: [for (final s in BubbleShape.values) ChoiceChip(label: Text(s.label), selected: e.shape == s, onSelected: (_) => upd(e.copyWith(shape: s)))]),
        SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Tail'), value: e.tailTip != null && e.shape != BubbleShape.narration, onChanged: e.shape == BubbleShape.narration ? null : (v) => upd(e.copyWith(tailTip: v ? e.rect.bottomCenter + Offset(0, e.rect.height * 0.5) : null))),
        _slider('Tail width', e.tailWidth, 8, 120, (v) => upd(e.copyWith(tailWidth: v))),
        _slider('Outline', e.strokeWidth, 0, 14, (v) => upd(e.copyWith(strokeWidth: v))),
        _slider('Width', e.rect.width, 60, 900, (v) => upd(e.copyWith(rect: Rect.fromLTWH(e.rect.left, e.rect.top, v, e.rect.height)))),
        _slider('Height', e.rect.height, 40, 700, (v) => upd(e.copyWith(rect: Rect.fromLTWH(e.rect.left, e.rect.top, e.rect.width, v)))),
        ..._textFields(e.text, (t) => upd(e.copyWith(text: t))),
      ]);
    } else if (e is TextBoxElement) {
      children.addAll([
        _slider('Rotation', e.rotationDegrees, -180, 180, (v) => upd(e.copyWith(rotationDegrees: v))),
        ..._textFields(e.text, (t) => upd(e.copyWith(text: t))),
      ]);
    } else if (panel != null) {
      children.addAll([
        _slider('Border', panel.borderWidth, 0, 24, (v) => _edit(() => _replacePanel(panel.copyWith(borderWidth: v)))),
        SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Clip content to panel'), value: panel.clipContent, onChanged: (v) => _edit(() => _replacePanel(panel.copyWith(clipContent: v)))),
        Wrap(spacing: 6, children: [
          ActionChip(label: const Text('Split ↔'), onPressed: () => _edit(() {
                final (a, b) = PanelOps.split(panel, vertical: true, newId: _page.nextPanelId());
                _replacePanel(a);
                _page.panels.add(b);
              })),
          ActionChip(label: const Text('Split ↕'), onPressed: () => _edit(() {
                final (a, b) = PanelOps.split(panel, vertical: false, newId: _page.nextPanelId());
                _replacePanel(a);
                _page.panels.add(b);
              })),
          ActionChip(label: const Text('Delete panel'), onPressed: () => _edit(() {
                _page.elements.removeWhere((x) => x.panelId == panel.id);
                _page.panels.removeWhere((x) => x.id == panel.id);
                _panelId = null;
              })),
        ]),
        const Text('Drag a corner handle to reshape the panel; drag inside to move it.'),
      ]);
    } else {
      children.add(const Padding(padding: EdgeInsets.all(8), child: Text('Tap a panel or element to edit it.')));
    }
    if (e != null) {
      children.add(Wrap(spacing: 6, children: [
        ActionChip(label: const Text('Delete element'), onPressed: () => _edit(() {
              _page.elements.removeWhere((x) => x.id == e.id);
              _elementId = null;
            })),
        ActionChip(label: const Text('Bring to front'), onPressed: () => _edit(() {
              _page.elements.removeWhere((x) => x.id == e.id);
              _page.elements.add(e);
            })),
        if (panel != null) ActionChip(label: const Text('Unclip'), onPressed: () => upd(e.copyBase(panelId: null))),
      ]));
    }
    return ListView(padding: const EdgeInsets.all(12), children: children);
  }

  Future<void> _importFont() async {
    final id = widget.projectId;
    if (_storage == null || id == null) {
      _msg('Save the comic as a project first.');
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Import a font'),
        content: const Text('ARTFOXEL includes no fonts. Only import a font you have the right to use and embed in your comic. Fonts whose licence forbids embedding are rejected.\n\nDo you confirm you have this right?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('I have the right')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final r = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['ttf', 'otf'], withData: true);
      final f = r?.files.single;
      final bytes = f?.bytes;
      if (f == null || bytes == null) return;
      final info = FontImportValidator.validate(bytes, licenceAcknowledged: true);
      final safeName = '${info.family.replaceAll(RegExp(r'[^A-Za-z0-9]'), '_')}.${f.extension == 'otf' ? 'otf' : 'ttf'}';
      await _storage!.writeFont(id, safeName, bytes);
      final loader = FontLoader(info.family)..addFont(Future.value(ByteData.sublistView(bytes)));
      await loader.load();
      _edit(() {
        _doc.fonts.removeWhere((x) => x.family == info.family);
        _doc.fonts.add(ImportedFont(family: info.family, fileName: safeName, licenceNote: info.license ?? '', acknowledged: true));
      });
      _msg('Font "${info.family}" imported.');
    } on FontImportException catch (e) {
      _msg(e.message);
    } catch (error, stack) {
      AppLog.error('Font import failed', error: error, stackTrace: stack);
      _msg('The font could not be imported.');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    if (_error != null) return Scaffold(appBar: AppBar(title: const Text('Comic Studio')), body: Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!))));
    final spec = _doc.specFor(_page);
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final nav = Navigator.of(context);
        final leave = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: const Text('Unsaved changes'),
            content: const Text('Save before leaving?'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Discard')),
              FilledButton(onPressed: () async {
                await _save();
                if (c.mounted) Navigator.pop(c, true);
              }, child: const Text('Save')),
            ],
          ),
        );
        if (leave != null) nav.pop();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text('${_doc.title} · page ${_pageIndex + 1}/${_doc.pages.length}'),
          actions: [
            IconButton(tooltip: _guides ? 'Hide guides' : 'Show guides', onPressed: () => setState(() => _guides = !_guides), icon: Icon(_guides ? Icons.grid_on : Icons.grid_off)),
            IconButton(tooltip: 'Import font', onPressed: _importFont, icon: const Icon(Icons.font_download_outlined)),
            IconButton(tooltip: 'Export page as PNG', onPressed: _exportPage, icon: const Icon(Icons.ios_share)),
            IconButton(tooltip: 'Save', onPressed: _save, icon: Icon(_dirty ? Icons.save : Icons.save_outlined)),
          ],
        ),
        body: Column(children: [
          SizedBox(
            height: 48,
            child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 8), children: [
              for (var i = 0; i < _doc.pages.length; i++)
                Padding(padding: const EdgeInsets.all(4), child: ChoiceChip(label: Text('${i + 1}'), selected: i == _pageIndex, onSelected: (_) => setState(() {
                      _pageIndex = i;
                      _panelId = null;
                      _elementId = null;
                    }))),
              IconButton(tooltip: 'Add page', icon: const Icon(Icons.add), onPressed: () => _edit(() {
                    _doc.addPage(template: PanelTemplate.byId('grid-2x2'));
                    _pageIndex = _doc.pages.length - 1;
                  })),
              IconButton(tooltip: 'Duplicate page', icon: const Icon(Icons.copy), onPressed: () => _edit(() {
                    _doc.duplicatePage(_page.id);
                    _pageIndex++;
                  })),
              IconButton(tooltip: 'Delete page', icon: const Icon(Icons.delete_outline), onPressed: () => _edit(() {
                    _doc.removePage(_page.id);
                    _pageIndex = _pageIndex.clamp(0, _doc.pages.length - 1);
                  })),
              IconButton(tooltip: 'Move page earlier', icon: const Icon(Icons.arrow_back), onPressed: _pageIndex == 0 ? null : () => _edit(() {
                    _doc.movePage(_pageIndex, _pageIndex - 1);
                    _pageIndex--;
                  })),
              IconButton(tooltip: 'Move page later', icon: const Icon(Icons.arrow_forward), onPressed: _pageIndex >= _doc.pages.length - 1 ? null : () => _edit(() {
                    _doc.movePage(_pageIndex, _pageIndex + 1);
                    _pageIndex++;
                  })),
              PopupMenuButton<PanelTemplate>(
                tooltip: 'Apply a panel layout to this page',
                icon: const Icon(Icons.dashboard_customize_outlined),
                onSelected: (t) => _edit(() {
                  _page.panels
                    ..clear()
                    ..addAll(t.instantiate(spec.safeRect, rightToLeft: _doc.direction == ReadingDirection.rightToLeft));
                  _page.elements.removeWhere((e) => e.panelId != null);
                  _panelId = null;
                }),
                itemBuilder: (_) => [for (final t in PanelTemplate.builtIn) PopupMenuItem(value: t, child: Text(t.name))],
              ),
            ]),
          ),
          Expanded(
            flex: 3,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: AspectRatio(
                  aspectRatio: spec.canvasSize.width / spec.canvasSize.height,
                  child: LayoutBuilder(builder: (context, box) {
                    final size = Size(box.maxWidth, box.maxHeight);
                    return GestureDetector(
                      onTapUp: (d) => _tap(_toPage(d.localPosition, size)),
                      onPanStart: (d) => _panStart(_toPage(d.localPosition, size)),
                      onPanUpdate: (d) => _panUpdate(_toPage(d.localPosition, size), d.delta * (spec.canvasSize.width / size.width)),
                      child: Container(
                        decoration: BoxDecoration(boxShadow: const [BoxShadow(blurRadius: 8, color: Colors.black26)], color: Colors.white),
                        child: CustomPaint(size: size, painter: ComicPagePreviewPainter(_doc, _page, showGuides: _guides, selectedPanelId: _panelId)),
                      ),
                    );
                  }),
                ),
              ),
            ),
          ),
          SizedBox(
            height: 44,
            child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 8), children: [
              for (final (key, label) in const [('tone', 'Screentone'), ('lines', 'Speed lines'), ('bubble', 'Bubble'), ('narration', 'Narration'), ('text', 'Text')])
                Padding(padding: const EdgeInsets.all(4), child: ActionChip(label: Text(label), onPressed: () => _add(key))),
            ]),
          ),
          Expanded(flex: 2, child: _inspector()),
        ]),
      ),
    );
  }
}
