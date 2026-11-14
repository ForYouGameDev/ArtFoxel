import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../../core/diagnostics/app_log.dart';
import '../../studio/application/sketch_controller.dart';
import '../../studio/application/workspace_layout.dart';
import '../../studio/domain/color_math.dart';
import '../../studio/presentation/sketch_canvas_stage.dart';
import '../../studio/presentation/workspace_shell.dart';
import '../../studio/rendering/layer_compositor.dart';
import '../application/animation_image_import.dart';
import '../application/frame_art.dart';
import '../data/animation_storage.dart';
import '../domain/animation_model.dart';
import '../rendering/anim_renderer.dart';
import '../rendering/animation_exporter.dart';

/// Dedicated Animation Studio (its own route; Sketch Studio never opens it).
/// Every frame owns a full sketch document and is edited with the SAME
/// drawing engine as Sketch Studio (all brushes, smudge, colour studio,
/// layers and masks, selection, shapes, filters, symmetry and rulers). On top
/// of that it adds the timeline. Playback and exports render real frames,
/// never a slideshow of one image.
class AnimationStudioScreen extends ConsumerStatefulWidget {
  const AnimationStudioScreen({this.projectId, super.key});
  final String? projectId;

  @override
  ConsumerState<AnimationStudioScreen> createState() => _AnimationStudioScreenState();
}

class _AnimationStudioScreenState extends ConsumerState<AnimationStudioScreen> with SingleTickerProviderStateMixin {
  AnimationDocument _doc = AnimationDocument(width: 960, height: 540);
  AnimationStorage? _storage;
  int _index = 0;
  OnionSkin _onion = const OnionSkin();
  bool _dirty = false;
  bool _loading = true;
  String? _error;

  // One drawing controller per recently used frame (each keeps its own
  // undo/redo). Frames without a controller draw through a cached compositor.
  static const int _maxControllers = 8;
  static const int _maxExtraCompositors = 10;
  final Map<String, SketchController> _ctl = {};
  final Map<String, LayerCompositor> _extra = {};
  SketchController? _active;
  final RepaintSignal _repaint = RepaintSignal();
  Timer? _refresh;
  Timer? _autosave;

  // Timeline panel
  bool _timelineOpen = true;
  double _thumbHeight = 84;

  // Playback
  late final Ticker _ticker = createTicker(_onTick);
  bool _playing = false;
  bool _rangeOnly = false;
  int? _playFrame;

  // Thumbnails (byte-budgeted).
  final BudgetCache<String, ui.Image> _thumbs = BudgetCache(24 * 1024 * 1024, onEvict: (i) => i.dispose());
  final Set<String> _rendering = {};
  final Map<String, int> _versions = {};

  // Imported pictures: decoded for drawing; PNG bytes wait here until saved.
  final Map<String, ui.Image> _images = {};
  final Map<String, Uint8List> _pendingAssets = {};
  bool _showRefs = true;
  int _imageRev = 0;
  ui.Image? _lookup(String id) => _images[id];

  AnimFrame get _frame => _doc.frames[_index];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      _storage = AnimationStorage(Directory('${docs.path}/artfoxel/animations'));
      if (widget.projectId != null) {
        final d = await _storage!.load(widget.projectId!);
        if (d != null) _doc = d;
        await _loadImages();
      }
      _active = _controllerFor(_doc.frames[0]);
    } on AnimationException catch (e) {
      _error = e.message;
    } catch (error, stack) {
      AppLog.error('Opening animation failed', error: error, stackTrace: stack);
      _error = 'The animation could not be opened.';
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<ui.Image> _decodePng(Uint8List png) async {
    final codec = await ui.instantiateImageCodec(png);
    try {
      return (await codec.getNextFrame()).image;
    } finally {
      codec.dispose();
    }
  }

  /// Loads the stored pictures. A missing or damaged asset is skipped (the
  /// picture simply does not draw) and reported once.
  Future<void> _loadImages() async {
    final id = widget.projectId;
    if (_storage == null || id == null) return;
    var bad = 0;
    for (final a in _doc.assets.values) {
      try {
        final bytes = await _storage!.readAsset(id, a.id);
        if (bytes == null) {
          bad++;
          continue;
        }
        _images[a.id] = await _decodePng(bytes);
      } catch (_) {
        bad++;
      }
    }
    if (bad > 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _msg('$bad imported picture(s) could not be loaded and are not shown.'));
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _refresh?.cancel();
    _autosave?.cancel();
    for (final c in _ctl.values) {
      c.dispose();
    }
    for (final c in _extra.values) {
      c.dispose();
    }
    _thumbs.clear();
    for (final i in _images.values) {
      i.dispose();
    }
    super.dispose();
  }

  void _msg(String t) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(t)));
  }

  void _touch(AnimFrame f) {
    _versions[f.id] = (_versions[f.id] ?? 0) + 1;
    _dirty = true;
    _scheduleAutosave();
  }

  void _edit(void Function() change) {
    try {
      setState(() {
        change();
        _dirty = true;
      });
      _scheduleAutosave();
    } on AnimationException catch (e) {
      _msg(e.message);
    }
  }

  // ---- per-frame drawing controllers ---------------------------------------------

  LayerCompositor? _artLookup(AnimFrame f) {
    if (f.art == null) return null;
    final c = _ctl[f.id];
    if (c != null) return c.compositor;
    var comp = _extra.remove(f.id);
    if (comp == null) {
      comp = LayerCompositor(doc: f.art!, onImageReady: _repaint.ping);
      unawaited(comp.prepareAll());
    }
    _extra[f.id] = comp;
    while (_extra.length > _maxExtraCompositors) {
      _extra.remove(_extra.keys.first)?.dispose();
    }
    return comp;
  }

  void _paintUnderlay(Canvas canvas, AnimFrame frame) {
    AnimRenderer.paintBackdrop(canvas, _doc, frame, images: _lookup);
    if (!_playing && _onion.enabled) {
      AnimRenderer.paintOnion(canvas, _doc, _doc.frames.indexOf(frame), _onion, art: _artLookup);
    }
  }

  SketchController _controllerFor(AnimFrame frame, {SketchController? adopt}) {
    var c = _ctl.remove(frame.id);
    if (c == null) {
      _extra.remove(frame.id)?.dispose();
      final art = FrameArt.ensure(_doc, frame);
      final created = SketchController(data: art);
      created.paintUnderlay = (canvas) => _paintUnderlay(canvas, frame);
      created.paintGuides = (canvas) {
        if (_showRefs && !_playing) AnimRenderer.paintReferences(canvas, _doc, _lookup);
      };
      var seen = created.revision;
      created.addListener(() {
        if (created.revision != seen) {
          seen = created.revision;
          _onFrameEdited(frame);
        }
      });
      created.notices.addListener(() {
        final m = created.notices.value;
        if (m != null) _msg(m);
      });
      unawaited(created.compositor.prepareAll());
      c = created;
    }
    if (adopt != null && !identical(adopt, c)) c.adoptToolState(adopt);
    _ctl[frame.id] = c;
    while (_ctl.length > _maxControllers) {
      final victim = _ctl.keys.firstWhere((k) => !identical(_ctl[k], c) && !identical(_ctl[k], _active), orElse: () => '');
      if (victim.isEmpty) break;
      _ctl.remove(victim)?.dispose();
    }
    return c;
  }

  void _dropController(String frameId) {
    final c = _ctl.remove(frameId);
    if (identical(c, _active)) _active = null;
    c?.dispose();
    _extra.remove(frameId)?.dispose();
  }

  void _onFrameEdited(AnimFrame frame) {
    _versions[frame.id] = (_versions[frame.id] ?? 0) + 1;
    _dirty = true;
    _scheduleAutosave();
    _refresh?.cancel();
    _refresh = Timer(const Duration(milliseconds: 400), () {
      if (mounted) setState(() {});
    });
  }

  void _scheduleAutosave() {
    if (widget.projectId == null || _storage == null) return;
    _autosave?.cancel();
    _autosave = Timer(const Duration(seconds: 12), () {
      if (mounted && _dirty && !_playing) unawaited(_save(silent: true));
    });
  }

  void _select(int i) {
    if (_playing || _doc.frames.isEmpty) return;
    final target = i.clamp(0, _doc.frames.length - 1);
    final prev = _active;
    prev?.cancelStroke();
    setState(() {
      _index = target;
      _active = _controllerFor(_doc.frames[target], adopt: prev);
    });
  }

  /// Re-selects the current frame after the frame list changed.
  void _reselect(int index) {
    final prev = _active;
    _index = index.clamp(0, _doc.frames.length - 1);
    _active = _controllerFor(_doc.frames[_index], adopt: prev);
  }

  // ---- playback --------------------------------------------------------------------

  void _togglePlay() {
    if (_playing) {
      _ticker.stop();
      setState(() {
        _playing = false;
        if (_playFrame != null) _index = _playFrame!;
        _playFrame = null;
        _active = _controllerFor(_doc.frames[_index], adopt: _active);
      });
      return;
    }
    _active?.cancelStroke();
    _doc.clampRange();
    setState(() {
      _playing = true;
      _playFrame = _rangeOnly ? _doc.rangeStart : _index;
    });
    _ticker.start();
  }

  void _onTick(Duration elapsed) {
    final saved = (_doc.rangeStart, _doc.rangeEnd);
    if (!_rangeOnly) _doc.setRange(0, _doc.frames.length - 1);
    final f = _doc.frameAt(elapsed);
    if (!_rangeOnly) _doc.setRange(saved.$1, saved.$2);
    if (f == null) {
      _ticker.stop();
      setState(() {
        _playing = false;
        _playFrame = null;
      });
      return;
    }
    if (f != _playFrame) setState(() => _playFrame = f);
  }

  // ---- thumbnails ---------------------------------------------------------------------

  String _key(AnimFrame f) => '${f.id}:${_versions[f.id] ?? 0}:${f.strokes.length}:${f.images.length}:$_imageRev:${_doc.backgroundArgb}';

  ui.Image? _thumb(AnimFrame f) {
    final k = _key(f);
    final img = _thumbs.get(k);
    if (img != null) return img;
    if (_rendering.add(k)) {
      AnimRenderer.renderImage(_doc, f, scale: 160 / _doc.width, images: _lookup, art: (f) => _ctl[f.id]?.compositor).then((i) {
        _rendering.remove(k);
        if (!mounted) {
          i.dispose();
          return;
        }
        _thumbs.put(k, i, i.width * i.height * 4);
        setState(() {});
      }, onError: (_) => _rendering.remove(k));
    }
    return null;
  }

  // ---- save / export --------------------------------------------------------------------

  Future<void> _save({bool silent = false}) async {
    final id = widget.projectId;
    if (_storage == null || id == null) {
      if (!silent) _msg('This animation is not linked to a project, so it cannot be saved.');
      return;
    }
    try {
      for (final e in _pendingAssets.entries.toList()) {
        await _storage!.writeAsset(id, e.key, e.value);
        _pendingAssets.remove(e.key);
      }
      final gone = _doc.pruneAssets();
      await _storage!.save(id, _doc);
      await _storage!.deleteAssets(id, gone);
      for (final g in gone) {
        _images.remove(g)?.dispose();
        _pendingAssets.remove(g);
      }
      if (mounted) setState(() => _dirty = false);
      if (!silent) _msg('Saved.');
    } catch (error, stack) {
      AppLog.error('Saving animation failed', error: error, stackTrace: stack);
      if (!silent) _msg('Saving failed. Your frames are still open here.');
    }
  }

  Future<void> _export(String kind) async {
    final id = widget.projectId;
    if (_storage == null || id == null) {
      _msg('Save the animation as a project first.');
      return;
    }
    _msg('Exporting…');
    try {
      final stamp = DateTime.now().millisecondsSinceEpoch;
      if (kind == 'gif') {
        final (bytes, report) = await AnimationExporter.exportGif(_doc, useRange: _rangeOnly, images: _lookup);
        final d = await _storage!.exportDir(id, 'gif_$stamp');
        final f = await _storage!.writeFile(d, 'animation.gif', bytes);
        _msg('GIF ${report.width}×${report.height}, ${report.frames} frames, checked OK. ${report.note ?? ''}\n${f.path}');
      } else {
        final d = await _storage!.exportDir(id, 'png_$stamp');
        final report = await AnimationExporter.exportPngSequence(_doc, (n, b) => _storage!.writeFile(d, n, b).then((_) {}), useRange: _rangeOnly, images: _lookup);
        _msg('${report.frames} PNG frames ${report.width}×${report.height} written, checked OK.\n${d.path}');
      }
    } on AnimationException catch (e) {
      _msg(e.message);
    } catch (error, stack) {
      AppLog.error('Animation export failed', error: error, stackTrace: stack);
      _msg('The export failed. No partial file was kept as verified.');
    }
  }

  void _exportSheet() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(leading: const Icon(Icons.gif_box_outlined), title: const Text('Animated GIF'), subtitle: const Text('256 colours, timing rounded to 1/100 s'), onTap: () {
            Navigator.pop(c);
            _export('gif');
          }),
          ListTile(leading: const Icon(Icons.photo_library_outlined), title: const Text('PNG sequence'), subtitle: const Text('One PNG per tick + timing.json'), onTap: () {
            Navigator.pop(c);
            _export('png');
          }),
          const ListTile(enabled: false, leading: Icon(Icons.movie_outlined), title: Text('MP4 video'), subtitle: Text('Not available: no verified encoder on this build.')),
          const ListTile(enabled: false, leading: Icon(Icons.audiotrack_outlined), title: Text('Audio reference track'), subtitle: Text('Not available yet.')),
          const Padding(padding: EdgeInsets.all(12), child: Text('Onion skin and guides are never included in exports.')),
        ]),
      ),
    );
  }

  // ---- image import -------------------------------------------------------------------

  void _importSheet() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (c) => SafeArea(
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Padding(padding: EdgeInsets.fromLTRB(16, 0, 16, 8), child: Text('Import image (stays inside Animation Studio)', style: TextStyle(fontWeight: FontWeight.bold))),
            for (final m in AnimImportMode.values)
              ListTile(
                title: Text(m.label),
                subtitle: Text(m.description),
                onTap: () {
                  Navigator.pop(c);
                  _import(m);
                },
              ),
            SwitchListTile(
              title: const Text('Show reference images'),
              subtitle: const Text('Editing overlay only. Never exported.'),
              value: _showRefs,
              onChanged: (v) {
                setState(() => _showRefs = v);
                Navigator.pop(c);
              },
            ),
            if (_doc.references.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: Text('Remove all ${_doc.references.length} reference image(s)'),
                onTap: () {
                  Navigator.pop(c);
                  _edit(_doc.references.clear);
                },
              ),
            const Padding(padding: EdgeInsets.all(12), child: Text('PNG, JPG, WebP and GIF (first frame). HEIC is not supported.')),
          ]),
        ),
      ),
    );
  }

  Future<void> _import(AnimImportMode mode) async {
    if (_playing) _togglePlay();
    try {
      final r = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['png', 'jpg', 'jpeg', 'webp', 'gif'],
        withData: true,
        allowMultiple: mode == AnimImportMode.sequence,
      );
      if (r == null || r.files.isEmpty) return;
      final files = mode == AnimImportMode.sequence
          ? AnimationImageImport.sortNatural(r.files, (f) => f.name)
          : [r.files.first];
      _msg('Importing ${files.length} image(s)…');
      final prepared = <PreparedAnimImage>[];
      final errors = <String>[];
      for (final f in files) {
        final bytes = f.bytes;
        if (bytes == null) {
          errors.add('${f.name}: could not be read.');
          continue;
        }
        try {
          prepared.add(await AnimationImageImport.prepare(bytes, f.name));
        } catch (e) {
          errors.add('${f.name}: $e');
        }
      }
      if (prepared.isEmpty) {
        _msg(errors.isEmpty ? 'Nothing to import.' : errors.first);
        return;
      }
      final ids = <String>[];
      var newIndex = _index;
      if (mode == AnimImportMode.sequence) {
        ids.addAll(AnimationImageImport.commitSequence(_doc, prepared, afterIndex: _index));
        newIndex = _index + 1;
      } else {
        ids.add(AnimationImageImport.commit(_doc, prepared.first, mode, frameIndex: _index));
      }
      for (var i = 0; i < ids.length; i++) {
        _pendingAssets[ids[i]] = prepared[i].png;
        _images[ids[i]] = await _decodePng(prepared[i].png);
      }
      if (!mounted) return;
      setState(() {
        _index = newIndex;
        _imageRev++;
        _dirty = true;
      });
      final warn = [...errors, for (final p in prepared) ...p.warnings];
      final extra = warn.isEmpty ? '' : '\n${warn.take(2).join('\n')}';
      _msg('Imported ${ids.length} image(s) as ${mode.label.toLowerCase()}.$extra');
    } on AnimationException catch (e) {
      _msg(e.message);
    } catch (error, stack) {
      AppLog.error('Animation image import failed', error: error, stackTrace: stack);
      _msg('The image picker or import failed.');
    }
  }


  // ---- background / onion / frame actions --------------------------------------------------

  Future<void> _backgroundDialog() async {
    final controller = TextEditingController(text: ColorMath.toHex(_doc.backgroundArgb, hash: false));
    const swatches = [0xFFFFFFFF, 0xFFFFF8E7, 0xFFF2F2F2, 0xFF9E9E9E, 0xFF212121, 0xFF000000, 0xFFBFE3FF, 0xFFFFD6E0];
    final chosen = await showDialog<int>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Animation background'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final s in swatches)
              GestureDetector(
                onTap: () => Navigator.pop(c, s),
                child: CircleAvatar(radius: 16, backgroundColor: Color(s)),
              ),
          ]),
          const SizedBox(height: 12),
          TextField(controller: controller, decoration: const InputDecoration(labelText: 'Hex colour', prefixText: '#')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              final v = ColorMath.parseHex(controller.text);
              Navigator.pop(c, v == null ? null : (v | 0xFF000000));
            },
            child: const Text('Apply'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (chosen == null) return;
    setState(() {
      _doc.backgroundArgb = chosen;
      _imageRev++;
      _dirty = true;
    });
    _active?.repaint.ping();
    _scheduleAutosave();
  }

  void _onionSheet() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (c) => StatefulBuilder(
        builder: (c, setSheet) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              SwitchListTile(
                title: const Text('Onion skin'),
                subtitle: const Text('Ghost frames while drawing. Never exported.'),
                value: _onion.enabled,
                onChanged: (v) {
                  setState(() => _onion = _onion.copyWith(enabled: v));
                  setSheet(() {});
                  _active?.repaint.ping();
                },
              ),
              _sheetSlider('Frames before', _onion.before.toDouble(), 0, 4, (v) => _onion = _onion.copyWith(before: v.round()), setSheet, divisions: 4),
              _sheetSlider('Frames after', _onion.after.toDouble(), 0, 4, (v) => _onion = _onion.copyWith(after: v.round()), setSheet, divisions: 4),
              _sheetSlider('Strength', _onion.opacity, 0.1, 0.8, (v) => _onion = _onion.copyWith(opacity: v), setSheet),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _sheetSlider(String label, double value, double min, double max, void Function(double) apply, StateSetter setSheet, {int? divisions}) {
    return Row(children: [
      SizedBox(width: 110, child: Text(label)),
      Expanded(
        child: Slider(
          value: value.clamp(min, max).toDouble(),
          min: min,
          max: max,
          divisions: divisions,
          onChanged: (v) {
            setState(() => apply(v));
            setSheet(() {});
            _active?.repaint.ping();
          },
        ),
      ),
    ]);
  }

  Future<void> _clearFrame() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Clear this frame?'),
        content: const Text('All drawing on every layer of this frame is removed. This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Clear')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final f = _frame;
    final prev = _active;
    setState(() {
      _dropController(f.id);
      f.strokes.clear();
      f.art = null;
      _touch(f);
      _active = _controllerFor(f, adopt: prev);
    });
  }

  void _newFrame() => _edit(() {
        final f = _doc.addFrame(after: _index);
        _reselect(_doc.frames.indexOf(f));
      });

  void _duplicateFrame() => _edit(() {
        _doc.duplicateFrame(_index);
        _reselect(_index + 1);
      });

  void _deleteFrame() => _edit(() {
        final id = _frame.id;
        _doc.deleteFrame(_index);
        _dropController(id);
        _reselect(_index.clamp(0, _doc.frames.length - 1));
      });

  // ---- UI ---------------------------------------------------------------------------------

  Widget _timeline() {
    final scheme = Theme.of(context).colorScheme;
    final showing = _playing ? (_playFrame ?? _index) : _index;
    final header = SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        children: [
          IconButton(
            tooltip: _timelineOpen ? 'Collapse timeline' : 'Expand timeline',
            onPressed: () => setState(() => _timelineOpen = !_timelineOpen),
            icon: Icon(_timelineOpen ? Icons.expand_more_rounded : Icons.expand_less_rounded),
          ),
          IconButton.filled(tooltip: _playing ? 'Pause' : 'Play', onPressed: _togglePlay, icon: Icon(_playing ? Icons.pause : Icons.play_arrow)),
          IconButton(tooltip: 'Previous frame', onPressed: _playing || _index == 0 ? null : () => _select(_index - 1), icon: const Icon(Icons.skip_previous_rounded)),
          Center(child: Text('${showing + 1}/${_doc.frames.length}', style: const TextStyle(fontWeight: FontWeight.w700))),
          IconButton(tooltip: 'Next frame', onPressed: _playing || _index >= _doc.frames.length - 1 ? null : () => _select(_index + 1), icon: const Icon(Icons.skip_next_rounded)),
          IconButton(tooltip: 'Loop', isSelected: _doc.loop, onPressed: () => _edit(() => _doc.loop = !_doc.loop), icon: const Icon(Icons.repeat), selectedIcon: const Icon(Icons.repeat_on)),
          IconButton(tooltip: 'Onion skin settings', isSelected: _onion.enabled, onPressed: _onionSheet, icon: const Icon(Icons.layers_outlined), selectedIcon: const Icon(Icons.layers)),
          Padding(padding: const EdgeInsets.symmetric(horizontal: 4), child: FilterChip(label: const Text('Range'), selected: _rangeOnly, onSelected: (v) => setState(() => _rangeOnly = v))),
          const Center(child: Text('FPS')),
          SizedBox(width: 120, child: Slider(value: _doc.fps.toDouble(), min: 1, max: 30, divisions: 29, label: '${_doc.fps}', onChanged: (v) => _edit(() => _doc.fps = v.round()))),
          Center(child: Text('${_doc.fps}')),
          IconButton(tooltip: 'Background colour', onPressed: _backgroundDialog, icon: const Icon(Icons.format_color_fill_rounded)),
        ],
      ),
    );
    return Material(
      color: scheme.surfaceContainer,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        header,
        if (_timelineOpen) ...[
          if (_rangeOnly)
            RangeSlider(
              values: RangeValues(_doc.rangeStart.toDouble(), _doc.rangeEnd.toDouble()),
              min: 0,
              max: (_doc.frames.length - 1).toDouble().clamp(1, 1e9),
              divisions: (_doc.frames.length - 1).clamp(1, 1000),
              labels: RangeLabels('${_doc.rangeStart + 1}', '${_doc.rangeEnd + 1}'),
              onChanged: _doc.frames.length < 2 ? null : (v) => _edit(() => _doc.setRange(v.start.round(), v.end.round())),
            ),
          SizedBox(
            height: _thumbHeight + 28,
            child: ReorderableListView.builder(
              scrollDirection: Axis.horizontal,
              buildDefaultDragHandles: true,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              itemCount: _doc.frames.length,
              onReorder: (from, to) => _edit(() {
                final target = to > from ? to - 1 : to;
                _doc.moveFrame(from, target);
                _reselect(target);
              }),
              itemBuilder: (context, i) {
                final f = _doc.frames[i];
                final selected = i == _index;
                final inRange = i >= _doc.rangeStart && i <= _doc.rangeEnd;
                return GestureDetector(
                  key: ValueKey(f.id),
                  onTap: () => _select(i),
                  child: Container(
                    width: _thumbHeight * _doc.width / _doc.height + 8,
                    margin: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      border: Border.all(color: selected ? scheme.primary : (_rangeOnly && inRange ? Colors.orange : Colors.black26), width: selected ? 3 : 1),
                      borderRadius: BorderRadius.circular(8),
                      color: Colors.white,
                    ),
                    child: Column(children: [
                      Expanded(child: ClipRRect(borderRadius: BorderRadius.circular(6), child: SizedBox.expand(child: CustomPaint(painter: _ThumbPainter(_thumb(f), _doc.width / _doc.height))))),
                      Text('${i + 1} · ×${f.hold}', style: Theme.of(context).textTheme.labelSmall),
                    ]),
                  ),
                );
              },
            ),
          ),
          SizedBox(
            height: 44,
            child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 8), children: [
              ActionChip(avatar: const Icon(Icons.add, size: 18), label: const Text('New'), onPressed: _playing ? null : _newFrame),
              const SizedBox(width: 6),
              ActionChip(avatar: const Icon(Icons.copy, size: 18), label: const Text('Duplicate'), onPressed: _playing ? null : _duplicateFrame),
              const SizedBox(width: 6),
              ActionChip(avatar: const Icon(Icons.delete_outline, size: 18), label: const Text('Delete'), onPressed: _playing ? null : _deleteFrame),
              const SizedBox(width: 6),
              ActionChip(label: const Text('Hold −'), onPressed: () => _edit(() => _doc.setHold(_index, _frame.hold - 1))),
              const SizedBox(width: 6),
              ActionChip(label: Text('Hold ${_frame.hold}'), onPressed: null),
              const SizedBox(width: 6),
              ActionChip(label: const Text('Hold +'), onPressed: () => _edit(() => _doc.setHold(_index, _frame.hold + 1))),
              const SizedBox(width: 6),
              ActionChip(label: const Text('Clear frame'), onPressed: _playing ? null : _clearFrame),
              const SizedBox(width: 12),
              const Center(child: Icon(Icons.photo_size_select_large_outlined, size: 18)),
              SizedBox(width: 120, child: Slider(value: _thumbHeight, min: 52, max: 150, onChanged: (v) => setState(() => _thumbHeight = v))),
            ]),
          ),
        ],
      ]),
    );
  }

  Widget _canvas() {
    final active = _active;
    if (_playing) {
      final frame = _doc.frames[(_playFrame ?? _index).clamp(0, _doc.frames.length - 1)];
      return ColoredBox(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: Center(
          child: AspectRatio(
            aspectRatio: _doc.width / _doc.height,
            child: CustomPaint(painter: _PlaybackPainter(_doc, frame, _lookup, _artLookup, _repaint)),
          ),
        ),
      );
    }
    if (active == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: active,
      builder: (context, _) => SketchCanvasStage(
        document: active.data.toCanvasDocument(),
        controller: active,
        onColorSampled: (color) {
          if (color == null) _msg('Nothing to pick there (transparent or outside).');
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    if (_error != null) return Scaffold(appBar: AppBar(title: const Text('Animation Studio')), body: Center(child: Text(_error!)));
    final active = _active;
    if (active == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final nav = Navigator.of(context);
        final r = await showDialog<bool>(
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
        if (r != null) nav.pop();
      },
      child: WorkspaceShell(
        controller: active,
        title: 'Animation Studio',
        onBack: () => Navigator.of(context).maybePop(),
        saveIndicator: Tooltip(
          message: _dirty ? 'Unsaved changes' : 'Saved',
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Icon(_dirty ? Icons.cloud_upload_outlined : Icons.cloud_done_outlined, size: 20),
          ),
        ),
        timeline: _timeline(),
        canvas: _canvas(),
        onAddImage: _importSheet,
        toolOverrides: {SideTool.references: _importSheet},
        topActions: [
          IconButton(tooltip: 'Export', onPressed: _exportSheet, icon: const Icon(Icons.ios_share)),
          IconButton(tooltip: 'Save', onPressed: _save, icon: Icon(_dirty ? Icons.save : Icons.save_outlined)),
        ],
        menuItems: const [
          ShellMenuItem('import', 'Import image…'),
          ShellMenuItem('background', 'Background colour…'),
          ShellMenuItem('onion', 'Onion skin…'),
          ShellMenuItem('export', 'Export…'),
          ShellMenuItem('save', 'Save now'),
        ],
        onMenu: (v) {
          switch (v) {
            case 'import':
              _importSheet();
            case 'background':
              _backgroundDialog();
            case 'onion':
              _onionSheet();
            case 'export':
              _exportSheet();
            case 'save':
              _save();
          }
        },
      ),
    );
  }
}

class _PlaybackPainter extends CustomPainter {
  _PlaybackPainter(this.doc, this.frame, this.images, this.art, Listenable repaint) : super(repaint: repaint);
  final AnimationDocument doc;
  final AnimFrame frame;
  final AnimImageLookup images;
  final AnimArtLookup art;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / doc.width, size.height / doc.height);
    canvas.clipRect(Rect.fromLTWH(0, 0, doc.width.toDouble(), doc.height.toDouble()));
    AnimRenderer.paintFrame(canvas, doc, frame, images: images, art: art);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _PlaybackPainter old) => old.frame != frame || old.doc != doc;
}

class _ThumbPainter extends CustomPainter {
  _ThumbPainter(this.image, this.aspect);
  final ui.Image? image;
  final double aspect;

  @override
  void paint(Canvas canvas, Size size) {
    final img = image;
    if (img == null) {
      canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFFEEEEEE));
      return;
    }
    canvas.drawImageRect(img, Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()), Offset.zero & size, Paint()..filterQuality = FilterQuality.medium);
  }

  @override
  bool shouldRepaint(covariant _ThumbPainter old) => old.image != image;
}
