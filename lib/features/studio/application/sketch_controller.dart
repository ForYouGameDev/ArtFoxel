import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../../../core/diagnostics/app_log.dart';
import '../domain/brush_preset.dart';
import '../domain/builtin_brushes.dart';
import '../domain/canvas_input.dart';
import '../domain/sketch_document_data.dart';
import '../domain/stroke_model.dart';
import '../domain/stroke_stabilizer.dart';
import '../rendering/brush_renderer.dart';
import '../rendering/sketch_raster.dart';

enum SketchTool { draw, eyedropper }

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
    if (rasterize) {
      raster = SketchRaster(
        width: data.width,
        height: data.height,
        resolve: (key) => data.brushes[key],
      );
      raster!.rebuild(data.activeLayer.strokes);
    }
    if (startDirty) _scheduleAutosave();
  }

  final SketchDocumentData data;
  final DocumentWriter? onSave;
  final DocumentWriter? onCheckpoint;
  final Duration autosaveDelay;
  final Duration checkpointDelay;

  /// Null when rasterizing is disabled (tests); strokes are then replayed.
  SketchRaster? raster;
  final RepaintSignal repaint = RepaintSignal();

  BrushPreset brush;
  int colorArgb = 0xFF111111;
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

  final List<SketchStroke> _redo = [];
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

  List<SketchStroke> get strokes => data.activeLayer.strokes;
  bool get canUndo => strokes.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;
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
    tool = value;
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

  StrokePoint _toPoint(CanvasInputSample sample) => StrokePoint(
        x: sample.documentPosition.dx,
        y: sample.documentPosition.dy,
        t: math.max(0, sample.timestamp.inMilliseconds - _originMs),
        pressure: sample.pressure,
        tilt: sample.tilt,
      );

  void beginStroke(CanvasInputSample sample) {
    if (tool != SketchTool.draw) return;
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

    final stroke = SketchStroke(
      brushKey: data.registerBrush(brush),
      colorArgb: colorArgb,
      size: size,
      opacity: opacity,
      flow: flow,
      seed: _seed,
      points: List<StrokePoint>.of(live),
    );
    strokes.add(stroke);
    _redo.clear();
    raster?.commit(strokes);
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
    if (strokes.isEmpty) return;
    _redo.add(strokes.removeLast());
    raster?.rebuild(strokes);
    _markChanged();
  }

  void redo() {
    if (isDrawing) cancelStroke();
    if (_redo.isEmpty) return;
    strokes.add(_redo.removeLast());
    raster?.commit(strokes);
    _markChanged();
  }

  // ---- painting -------------------------------------------------------------

  /// The stroke being drawn right now, including a short uncommitted
  /// prediction ahead of the pen when the brush enables it.
  SketchStroke? get liveStroke {
    final live = _live;
    if (live == null) return null;
    final predicted = _predicted;
    return SketchStroke(
      brushKey: 'live',
      colorArgb: colorArgb,
      size: size,
      opacity: opacity,
      flow: flow,
      seed: _seed,
      points: predicted == null ? live : [...live, predicted],
    );
  }

  /// Paints all artwork (committed strokes plus the live stroke) in document
  /// coordinates. Call inside a layer so erasing never touches the page.
  void paintArtwork(Canvas canvas) {
    final r = raster;
    if (r != null) {
      r.paintCommitted(canvas, strokes);
    } else {
      for (final stroke in strokes) {
        final preset = data.brushes[stroke.brushKey];
        if (preset != null) BrushRenderer.paintStroke(canvas, stroke, preset);
      }
    }
    final live = liveStroke;
    if (live != null) BrushRenderer.paintStroke(canvas, live, brush);
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
    raster?.dispose();
    repaint.dispose();
    super.dispose();
  }
}
