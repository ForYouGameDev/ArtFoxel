import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../../../core/diagnostics/app_log.dart';
import '../../imaging/data/image_decoder.dart';
import '../../imaging/domain/export_model.dart';
import '../../imaging/domain/import_rules.dart';
import '../../imaging/domain/ora_writer.dart';
import '../domain/affine2d.dart';
import '../domain/alpha_mask.dart';
import '../domain/assist_model.dart';
import '../domain/color_math.dart';
import '../domain/gradient_model.dart';
import '../domain/reference_model.dart';
import '../domain/shape_model.dart';
import '../filters/filter_engine.dart';
import '../domain/brush_preset.dart';
import '../domain/builtin_brushes.dart';
import '../domain/canvas_input.dart';
import '../domain/doc_geometry.dart';
import '../domain/layer_blend.dart';
import '../domain/layer_ops.dart';
import '../domain/selection_tools.dart';
import '../domain/sketch_document_data.dart';
import '../domain/stroke_model.dart';
import '../domain/stroke_stabilizer.dart';
import '../rendering/layer_compositor.dart';

part 'sketch_controller_assist.dart';
part 'sketch_controller_export.dart';
part 'sketch_controller_manipulate.dart';
part 'sketch_controller_filters.dart';
part 'sketch_controller_layers.dart';
part 'sketch_controller_shapes.dart';
part 'sketch_controller_references.dart';
part 'sketch_controller_selection.dart';
part 'sketch_controller_transform.dart';

enum SketchTool {
  draw,
  eyedropper,
  shape,
  move,
  selectRect,
  selectEllipse,
  selectLasso,
  selectPolygon,
  magicWand,
  colorRange;

  bool get isSelection => index >= SketchTool.selectRect.index;
}

/// How the selection is drawn on the canvas.
enum SelectionView {
  outline('Outline'),
  tint('Outline + tint'),
  hidden('Hidden');

  const SelectionView(this.label);
  final String label;
}

/// One undoable step. Closures keep the controller's history independent of
/// what kind of change it was.
class _HistoryEntry {
  _HistoryEntry(this.label, this.undo, this.redo);
  final String label;
  final void Function() undo;
  final void Function() redo;
}

enum SaveState { saved, dirty, saving, error }

/// Lets the canvas repaint on every pointer move without rebuilding the
/// toolbars (which listen to the controller itself).
class RepaintSignal extends ChangeNotifier {
  void ping() => notifyListeners();
}

typedef DocumentWriter = Future<void> Function(SketchDocumentData document);

/// Owns the editable Sketch Studio state: strokes, tool settings, undo/redo,
/// dirty tracking, autosave and the crash-recovery checkpoint.
class SketchController extends ChangeNotifier {
  SketchController({
    required this.data,
    BrushPreset? brush,
    this.onSave,
    this.onCheckpoint,
    this.autosaveDelay = const Duration(seconds: 8),
    this.checkpointDelay = const Duration(milliseconds: 1500),
    bool rasterize = true,
    bool startDirty = false,
  })  : brush = brush ?? BuiltInBrushes.defaultBrush,
        saveState = startDirty ? SaveState.dirty : SaveState.saved {
    size = this.brush.size;
    opacity = this.brush.opacity;
    flow = this.brush.flow;
    stabilization = this.brush.stabilization;
    compositor = LayerCompositor(
      doc: data,
      useRasters: rasterize,
      onImageReady: repaint.ping,
    );
    final firstPaint = data.layers.where((l) => l.isPaint).firstOrNull;
    activeLayerId = (firstPaint ?? data.layers.last).id;
    if (startDirty) _scheduleAutosave();
  }

  final SketchDocumentData data;
  final DocumentWriter? onSave;
  final DocumentWriter? onCheckpoint;
  final Duration autosaveDelay;
  final Duration checkpointDelay;

  /// Draws the layer tree; owns the raster caches. In tests (rasterize off)
  /// it replays strokes instead.
  late final LayerCompositor compositor;
  final RepaintSignal repaint = RepaintSignal();

  /// The selected layer or group. Panel selection, not document data.
  late String activeLayerId;

  /// True while painting goes to the active layer's mask instead of its pixels.
  bool editingMask = false;

  /// Short messages for the screen to show (locked layer, alpha lock, ...).
  final ValueNotifier<String?> notices = ValueNotifier(null);

  BrushPreset brush;
  int colorArgb = 0xFF111111;

  /// Background colour of the pair (swap with X in the colour studio). Used
  /// as the second colour for gradients and shape fills.
  int bgColorArgb = 0xFFFFFFFF;
  double size = 12;
  double opacity = 1;
  double flow = 1;
  double stabilization = 0.2;
  bool lowLatency = false;
  SketchTool tool = SketchTool.draw;
  SaveState saveState;
  Object? saveError;
  final List<int> recentColors = [];
  CanvasInputCapabilities observedCapabilities =
      const CanvasInputCapabilities();

  static const int maxHistory = 200;
  final List<_HistoryEntry> _undoStack = [];
  final List<_HistoryEntry> _redoStack = [];

  // Selection (document-space coverage at reduced resolution).
  AlphaMask? selection;
  SelectionMode selectionMode = SelectionMode.replace;
  SelectionView selectionView = SelectionView.tint;
  int wandTolerance = 32;
  int colorRangeFuzziness = 32;
  bool wandContiguous = true;
  bool sampleAllLayers = true;
  ui.Image? _selectionOverlay;
  int _overlayGeneration = 0;
  SelectionClipboard? clipboard;
  Offset? _shapeStart;
  Offset? _shapeCurrent;
  final List<Offset> _shapePoints = [];

  // Reference Studio (see sketch_controller_references.dart).
  ReferenceBoard references = const ReferenceBoard();
  bool showReferences = true;

  /// When true the eyedropper reads reference images first.
  bool sampleReferences = false;
  String? selectedReferenceId;
  Future<void> Function(ReferenceBoard board)? onReferencesChanged;

  /// Hooks for hosts that draw extra context around the artwork (the
  /// Animation Studio draws the frame backdrop and onion skin under it and
  /// reference pictures above it). Editing aids only: never part of exports.
  void Function(Canvas canvas)? paintUnderlay;
  void Function(Canvas canvas)? paintGuides;

  /// Counts every recorded change; lets hosts notice edits cheaply.
  int get revision => _revision;

  /// Copies the user's current tool state (brush, colours, sizes, tool,
  /// selection and shape settings) from [other], so switching to another
  /// document of the same studio feels like nothing changed.
  void adoptToolState(SketchController other) {
    brush = other.brush;
    colorArgb = other.colorArgb;
    bgColorArgb = other.bgColorArgb;
    size = other.size;
    opacity = other.opacity;
    flow = other.flow;
    stabilization = other.stabilization;
    lowLatency = other.lowLatency;
    tool = other.tool == SketchTool.move ? SketchTool.draw : other.tool;
    recentColors
      ..clear()
      ..addAll(other.recentColors);
    selectionMode = other.selectionMode;
    selectionView = other.selectionView;
    wandTolerance = other.wandTolerance;
    colorRangeFuzziness = other.colorRangeFuzziness;
    wandContiguous = other.wandContiguous;
    sampleAllLayers = other.sampleAllLayers;
    final s = shapeTool, o = other.shapeTool;
    s.kind = o.kind;
    s.sides = o.sides;
    s.cornerRadius = o.cornerRadius;
    s.innerRatio = o.innerRatio;
    s.sweepDegrees = o.sweepDegrees;
    s.strokeWidth = o.strokeWidth;
    s.stroke = o.stroke;
    s.fill = o.fill;
    s.gradient = o.gradient;
    s.recognize = o.recognize;
    _notify();
  }

  /// Called with the history label of every recorded edit (used by the
  /// timelapse recorder). Never called for undo/redo.
  void Function(String label)? onHistoryEvent;
  final Map<String, ui.Image> _refImages = {};
  final Map<String, Uint8List> _refPixels = {};

  // Filter editor (see sketch_controller_filters.dart).
  FilterSession? filterSession;
  final ValueNotifier<double?> filterProgress = ValueNotifier(null);
  final FilterHistory filterHistory = FilterHistory();

  // Shape tool (see sketch_controller_shapes.dart).
  final ShapeToolSettings shapeTool = ShapeToolSettings();
  int? selectedShapeIndex;
  Offset? _draftStart;
  Offset? _draftEnd;
  int? _dragHandle;
  Offset? _dragLast;
  _Snapshot? _shapeBefore;
  final List<Offset> _polyPoints = [];

  // Transform session (see sketch_controller_transform.dart).
  TransformSession? transformSession;

  // Move / Resize tool (see sketch_controller_manipulate.dart).
  _ManipDrag? _manipDrag;
  Offset? _manipDownDoc;
  bool _manipMoved = false;
  double _viewZoom = 1;

  Timer? _autosaveTimer;
  Timer? _checkpointTimer;
  bool _saving = false;
  bool _disposed = false;
  int _revision = 0;

  // Live stroke state.
  StrokeStabilizer? _stabilizer;
  List<StrokePoint>? _live;
  int _originMs = 0;
  int _seed = 0;
  StrokePoint? _predicted;

  SketchLayerData get activeLayer =>
      data.layerById(activeLayerId) ?? data.layers.first;

  /// Strokes of the layer being painted (its mask strokes while editing the mask).
  List<SketchStroke> get strokes =>
      editingMask && activeLayer.mask != null ? activeLayer.mask!.strokes : activeLayer.strokes;

  bool get canUndo => _undoStack.isNotEmpty;
  bool get canRedo => _redoStack.isNotEmpty;
  String? get undoLabel => _undoStack.isEmpty ? null : _undoStack.last.label;
  bool get isDrawing => _live != null;
  bool get isDirty =>
      saveState == SaveState.dirty || saveState == SaveState.error;

  // ---- tool settings ------------------------------------------------------

  void selectBrush(BrushPreset preset) {
    brush = preset;
    size = preset.size;
    opacity = preset.opacity;
    flow = preset.flow;
    stabilization = preset.stabilization;
    tool = SketchTool.draw;
    _notify();
  }

  /// Changes settings of the active brush for this session (for example the
  /// smudge strength slider). The saved preset in the library is untouched;
  /// strokes snapshot the exact values they were drawn with.
  void tweakBrush(Map<String, Object?> changes) {
    try {
      brush = brush.withChanges(changes);
    } on BrushPresetException {
      return;
    }
    _notify();
  }

  void setSize(double value) {
    size = value.clamp(1.0, 1000.0).toDouble();
    _notify();
  }

  void setOpacity(double value) {
    opacity = value.clamp(0.0, 1.0).toDouble();
    _notify();
  }

  void setFlow(double value) {
    flow = value.clamp(0.02, 1.0).toDouble();
    _notify();
  }

  void setStabilization(double value) {
    stabilization = value.clamp(0.0, 1.0).toDouble();
    _notify();
  }

  void setLowLatency(bool value) {
    lowLatency = value;
    _notify();
  }

  void setColor(int argb) {
    colorArgb = 0xFF000000 | (argb & 0xFFFFFF);
    tool = SketchTool.draw;
    _notify();
  }

  void setTool(SketchTool value) {
    if (isDrawing) cancelStroke();
    final was = tool;
    if (was == SketchTool.move && value != SketchTool.move) _manipLeave();
    tool = value;
    if (value == SketchTool.move && was != SketchTool.move) _manipEnter();
    _notify();
  }

  void noteCapabilities(CanvasInputCapabilities seen) {
    final merged = CanvasInputCapabilities(
      pressure: observedCapabilities.pressure || seen.pressure,
      tilt: observedCapabilities.tilt || seen.tilt,
      orientation: observedCapabilities.orientation || seen.orientation,
    );
    if (merged.pressure != observedCapabilities.pressure ||
        merged.tilt != observedCapabilities.tilt ||
        merged.orientation != observedCapabilities.orientation) {
      observedCapabilities = merged;
      _notify();
    }
  }

  // ---- stroke capture -----------------------------------------------------

  StrokePoint _toPoint(CanvasInputSample sample) {
    final live = _live;
    final start = live == null || live.isEmpty ? null : Offset(live.first.x, live.first.y);
    final p = AssistEngine.constrain(sample.documentPosition, data.assist, strokeStart: start);
    return StrokePoint(
        x: p.dx,
        y: p.dy,
        t: math.max(0, sample.timestamp.inMilliseconds - _originMs),
        pressure: sample.pressure,
        tilt: sample.tilt,
      );
  }

  void beginStroke(CanvasInputSample sample) {
    if (tool != SketchTool.draw) return;
    if (!_canPaint()) return;
    if (brush.engine == BrushEngineKind.smudge) {
      final target = activeLayer;
      if (editingMask && target.mask != null) {
        _notice('Smudge works on layer pixels, not on masks.');
        return;
      }
      if (target.displayImage != null) {
        _notice('Smudge moves painted strokes. Use it on a paint layer '
            '(imported images are not smudged).');
        return;
      }
      if (target.strokes.isEmpty) {
        _notice('Nothing to smudge here: paint on this layer first.');
        return;
      }
    }
    cancelStroke();
    _originMs = sample.timestamp.inMilliseconds;
    _seed = math.Random().nextInt(0x7FFFFFFF);
    _stabilizer = StrokeStabilizer(
      StabilizerConfig(
        strength: stabilization,
        lowLatency: lowLatency,
        preserveCorners: brush.preserveCorners,
        predict: brush.predict,
      ),
    );
    _live = [_stabilizer!.add(_toPoint(sample))];
    _predicted = null;
    repaint.ping();
    _notify();
  }

  void extendStroke(CanvasInputSample sample) {
    final live = _live;
    final stabilizer = _stabilizer;
    if (live == null || stabilizer == null) return;
    if (live.length >= SketchStroke.maxPoints - 4) return;
    live.add(stabilizer.add(_toPoint(sample)));
    _predicted = stabilizer.predicted();
    repaint.ping();
  }

  void endStroke(CanvasInputSample sample) {
    final live = _live;
    final stabilizer = _stabilizer;
    if (live == null || stabilizer == null) return;
    final raw = _toPoint(sample);
    final tail = stabilizer.finish(raw);
    if (tail.isNotEmpty) {
      live.addAll(tail);
    } else {
      final last = live.last;
      final dx = raw.x - last.x;
      final dy = raw.y - last.y;
      if (dx * dx + dy * dy > 0.01) live.add(raw);
    }
    _live = null;
    _stabilizer = null;
    _predicted = null;

    final layer = activeLayer;
    final onMask = editingMask && layer.mask != null;
    final stroke = SketchStroke(
      brushKey: data.registerBrush(brush),
      colorArgb: onMask ? _maskGray(colorArgb) : colorArgb,
      size: size,
      opacity: opacity,
      flow: flow,
      seed: _seed,
      points: List<StrokePoint>.of(live),
      alphaLock: layer.alphaLock && !onMask && !brush.erase,
    );
    final target = onMask ? layer.mask!.strokes : layer.strokes;
    // Symmetry: mirrored copies are committed together with the stroke, so
    // one undo removes all of them.
    final batch = <SketchStroke>[stroke, ..._symmetricCopies(stroke)];
    target.addAll(batch);
    compositor.commit(layer, mask: onMask);
    _pushEntry(
      _HistoryEntry(
        onMask ? 'Mask stroke' : (batch.length > 1 ? 'Symmetric stroke' : 'Stroke'),
        () {
          final owner = data.layerById(layer.id);
          final list = onMask ? owner?.mask?.strokes : owner?.strokes;
          if (list != null) list.removeWhere(batch.contains);
          compositor.invalidate(layer.id, mask: onMask);
        },
        () {
          final owner = data.layerById(layer.id);
          final list = onMask ? owner?.mask?.strokes : owner?.strokes;
          list?.addAll(batch);
          compositor.invalidate(layer.id, mask: onMask);
        },
      ),
    );
    recentColors
      ..remove(colorArgb)
      ..insert(0, colorArgb);
    if (recentColors.length > 12) recentColors.removeLast();
    _markChanged();
  }

  /// Drops the in-progress stroke without committing it (for example when a
  /// second finger starts a pinch).
  void cancelStroke() {
    if (_live == null) return;
    _live = null;
    _stabilizer = null;
    _predicted = null;
    repaint.ping();
    _notify();
  }

  // ---- undo / redo ----------------------------------------------------------

  void undo() {
    if (isDrawing) cancelStroke();
    if (transformSession != null) this.cancelTransform();
    if (_undoStack.isEmpty) return;
    final entry = _undoStack.removeLast();
    entry.undo();
    _redoStack.add(entry);
    _afterHistoryJump();
  }

  void redo() {
    if (isDrawing) cancelStroke();
    if (transformSession != null) this.cancelTransform();
    if (_redoStack.isEmpty) return;
    final entry = _redoStack.removeLast();
    entry.redo();
    _undoStack.add(entry);
    _afterHistoryJump();
  }

  void _afterHistoryJump() {
    if (data.layerById(activeLayerId) == null) {
      activeLayerId = data.layers.firstWhere((l) => l.isPaint, orElse: () => data.layers.last).id;
    }
    if (editingMask && activeLayer.mask == null) editingMask = false;
    _markChanged();
  }

  void _pushEntry(_HistoryEntry entry) {
    _undoStack.add(entry);
    if (_undoStack.length > maxHistory) _undoStack.removeAt(0);
    _redoStack.clear();
    onHistoryEvent?.call(entry.label);
  }

  /// Runs [change] on the document and records it as one undoable step by
  /// snapshotting the layer list (strokes and pixels are shared, not copied).
  void _recordStructural(String label, void Function() change) {
    final before = _Snapshot.take(this);
    change();
    final after = _Snapshot.take(this);
    _pushEntry(_HistoryEntry(label, () => before.restore(this), () => after.restore(this)));
    compositor.invalidateAll();
    unawaited(compositor.prepareAll());
    _markChanged();
  }

  bool _canPaint() {
    final layer = activeLayer;
    String? problem;
    if (layer.isGroup) {
      problem = 'Select a paint layer to draw on (groups hold other layers).';
    } else if (layer.isImage && !editingMask) {
      problem = 'Image layers cannot be painted on. Add a paint layer above it.';
    } else if (LayerOps.isEffectivelyLocked(data, layer)) {
      problem = '"${layer.name}" is locked.';
    } else if (!LayerOps.isEffectivelyVisible(data, layer)) {
      problem = '"${layer.name}" is hidden. Show it to draw on it.';
    } else if (layer.alphaLock && brush.erase && !editingMask) {
      problem = 'Alpha lock is on, so this layer cannot be erased.';
    }
    if (problem != null) {
      _notice(problem);
      return false;
    }
    return true;
  }

  bool _guard(void Function() body) {
    try {
      body();
      return true;
    } on LayerOpException catch (error) {
      _notice(error.message);
      return false;
    }
  }

  void _notice(String message) {
    // Re-notify even when the same text repeats.
    notices.value = null;
    notices.value = message;
  }

  static int _maskGray(int argb) {
    final r = (argb >> 16) & 0xFF, g = (argb >> 8) & 0xFF, b = argb & 0xFF;
    final lum = (0.2126 * r + 0.7152 * g + 0.0722 * b).round().clamp(0, 255);
    return 0xFF000000 | (lum << 16) | (lum << 8) | lum;
  }

  // ---- painting -------------------------------------------------------------

  /// The stroke being drawn right now, including a short uncommitted
  /// prediction ahead of the pen when the brush enables it.
  SketchStroke? get liveStroke {
    final live = _live;
    if (live == null) return null;
    final predicted = _predicted;
    final onMask = editingMask && activeLayer.mask != null;
    return SketchStroke(
      brushKey: 'live',
      colorArgb: onMask ? _maskGray(colorArgb) : colorArgb,
      size: size,
      opacity: opacity,
      flow: flow,
      seed: _seed,
      points: predicted == null ? live : [...live, predicted],
    );
  }

  /// Paints all visible layers plus the live stroke in document coordinates.
  /// Call inside a layer so erasing never touches the page.
  void paintArtwork(Canvas canvas) {
    final stroke = liveStroke;
    compositor.paint(
      canvas,
      live: stroke == null
          ? null
          : LiveStroke(
              layerId: activeLayer.id,
              stroke: stroke,
              brush: brush,
              onMask: editingMask && activeLayer.mask != null,
            ),
      preview: this.transformPreview,
    );
  }

  /// Reads the visible colour (artwork over background) at a document point.
  /// Returns null outside the canvas or on a fully transparent pixel.
  Future<int?> sampleColorAt(Offset documentPoint) async {
    final x = documentPoint.dx.floor();
    final y = documentPoint.dy.floor();
    if (x < 0 || y < 0 || x >= data.width || y >= data.height) return null;
    try {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder)..translate(-x.toDouble(), -y.toDouble());
      final page = Rect.fromLTWH(
        0,
        0,
        data.width.toDouble(),
        data.height.toDouble(),
      );
      final background = data.backgroundArgb;
      if (background != null) {
        canvas.drawRect(page, Paint()..color = Color(background));
      }
      canvas.saveLayer(page, Paint());
      paintArtwork(canvas);
      canvas.restore();
      final picture = recorder.endRecording();
      final image = picture.toImageSync(1, 1);
      picture.dispose();
      final bytes = await image.toByteData(
        format: ui.ImageByteFormat.rawStraightRgba,
      );
      image.dispose();
      if (bytes == null || bytes.getUint8(3) == 0) return null;
      return 0xFF000000 |
          (bytes.getUint8(0) << 16) |
          (bytes.getUint8(1) << 8) |
          bytes.getUint8(2);
    } catch (error, stack) {
      AppLog.error('Colour sampling failed', error: error, stackTrace: stack);
      return null;
    }
  }

  // ---- saving ---------------------------------------------------------------

  void _markChanged() {
    _revision++;
    data.updatedAt = DateTime.now();
    if (saveState != SaveState.saving) saveState = SaveState.dirty;
    _scheduleAutosave();
    _scheduleCheckpoint();
    repaint.ping();
    _notify();
  }

  void _scheduleAutosave() {
    if (onSave == null) return;
    _autosaveTimer?.cancel();
    _autosaveTimer = Timer(autosaveDelay, () => unawaited(saveNow()));
  }

  void _scheduleCheckpoint() {
    if (onCheckpoint == null) return;
    _checkpointTimer?.cancel();
    _checkpointTimer = Timer(checkpointDelay, () => unawaited(_checkpoint()));
  }

  Future<void> _checkpoint() async {
    final write = onCheckpoint;
    if (write == null || _saving || _disposed) return;
    try {
      await write(data);
    } catch (error, stack) {
      // A failed checkpoint is not user-visible; the autosave still runs.
      AppLog.error('Checkpoint failed', error: error, stackTrace: stack);
    }
  }

  /// Saves now (also used before leaving the screen or when the app is
  /// backgrounded). Safe to call repeatedly.
  Future<void> saveNow() async {
    final write = onSave;
    if (write == null || _disposed) return;
    if (_saving) return;
    if (saveState == SaveState.saved) return;
    _autosaveTimer?.cancel();
    _checkpointTimer?.cancel();
    _saving = true;
    final revision = _revision;
    saveState = SaveState.saving;
    saveError = null;
    _notify();
    try {
      await write(data);
      saveState = _revision == revision ? SaveState.saved : SaveState.dirty;
    } catch (error, stack) {
      AppLog.error('Autosave failed', error: error, stackTrace: stack);
      saveError = error;
      saveState = SaveState.error;
    } finally {
      _saving = false;
    }
    if (_disposed) return;
    _notify();
    if (saveState == SaveState.dirty) _scheduleAutosave();
    if (saveState == SaveState.error) {
      // Retry later instead of giving up; the checkpoint still protects work.
      _autosaveTimer?.cancel();
      _autosaveTimer = Timer(
        autosaveDelay * 2,
        () => unawaited(saveNow()),
      );
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _autosaveTimer?.cancel();
    _checkpointTimer?.cancel();
    compositor.dispose();
    _selectionOverlay?.dispose();
    for (final i in _refImages.values) {
      i.dispose();
    }
    filterSession?.job?.cancel();
    filterSession?.debounce?.cancel();
    filterProgress.dispose();
    notices.dispose();
    repaint.dispose();
    super.dispose();
  }
}
