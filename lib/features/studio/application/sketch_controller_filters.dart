part of 'sketch_controller.dart';

/// An open filter editing session on one image layer (Phase 6.1 / 6.5).
class FilterSession {
  FilterSession(this.layerId, this.ops, this.savedProcessed, this.savedSig);
  final String layerId;
  List<FilterOp> ops;
  final LayerImage? savedProcessed;
  final String? savedSig;
  FilterJob? job;
  bool showOriginal = false;
  Timer? debounce;
  int generation = 0;
}

extension SketchFilterActions on SketchController {
  static const previewSide = 1024;

  FilterImage _asFilterImage(LayerImage i) => FilterImage(i.width, i.height, i.rgba);

  /// Opens the filter editor for the active layer. Paint layers are first
  /// converted to an image layer (the paint layer is kept, hidden).
  Future<bool> beginFilterSession() async {
    if (filterSession != null) return true;
    var layer = activeLayer;
    if (layer.isGroup) {
      _notice('Select a layer (not a group) to filter.');
      return false;
    }
    if (layer.isPaint) {
      if (!await convertToFilterLayer()) return false;
      layer = activeLayer;
    }
    if (!layer.isImage || layer.image == null) return false;
    if (LayerOps.isEffectivelyLocked(data, layer)) {
      _notice('"${layer.name}" is locked.');
      return false;
    }
    filterSession = FilterSession(layer.id, List.of(layer.filters), layer.processed, layer.processedSig);
    _notify();
    _schedulePreview(immediate: true);
    return true;
  }

  /// Renders a paint layer's pixels into a new image layer above it so it
  /// can be filtered. The original paint layer stays (hidden, undoable).
  Future<bool> convertToFilterLayer() async {
    final layer = activeLayer;
    var scale = 1.0;
    final longest = math.max(data.width, data.height);
    if (longest > 4096) scale = 4096 / longest;
    final w = math.max(1, (data.width * scale).round());
    final h = math.max(1, (data.height * scale).round());
    try {
      final rec = ui.PictureRecorder();
      final canvas = Canvas(rec)..scale(w / data.width, h / data.height);
      canvas.saveLayer(null, Paint());
      compositor.paintAlone(canvas, layer);
      canvas.restore();
      final pic = rec.endRecording();
      final img = await pic.toImage(w, h);
      pic.dispose();
      final bytes = await img.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
      img.dispose();
      if (bytes == null) return false;
      final pixels = Uint8List.fromList(bytes.buffer.asUint8List());
      _guard(() {
        _recordStructural('Convert to filter layer', () {
          final src = data.layerById(layer.id);
          if (src == null) return;
          final image = SketchLayerData(
            id: LayerOps.newId(data),
            name: LayerOps.sanitizeName('${layer.name} (filtered)'),
            kind: LayerKind.image,
            image: LayerImage(width: w, height: h, rgba: pixels),
            matrix: Affine2D.scale(data.width / w, data.height / h),
            opacity: src.opacity,
            blend: src.blend,
          );
          src.visible = false;
          LayerOps.insert(data, image, aboveId: src.id);
          activeLayerId = image.id;
        });
      });
      return true;
    } catch (error, stack) {
      AppLog.error('Converting layer failed', error: error, stackTrace: stack);
      _notice('This layer could not be prepared for filtering.');
      return false;
    }
  }

  void setFilterOps(List<FilterOp> ops) {
    final s = filterSession;
    if (s == null) return;
    if (ops.length > 64) {
      _notice('A layer can hold at most 64 filters.');
      return;
    }
    s.ops = List.of(ops);
    _notify();
    _schedulePreview();
  }

  void addFilter(String id) {
    final s = filterSession;
    if (s == null) return;
    setFilterOps([...s.ops, FilterRegistry.defaultOp(id)]);
  }

  void setFilterParam(int index, String key, double value) {
    final s = filterSession;
    if (s == null || index < 0 || index >= s.ops.length) return;
    final op = s.ops[index];
    final spec = FilterRegistry.byId(op.id)!;
    final next = spec.normalize({...op.params, key: value});
    setFilterOps([...s.ops]..[index] = op.copyWith(params: next));
  }

  void resetFilterParams(int index) {
    final s = filterSession;
    if (s == null || index < 0 || index >= s.ops.length) return;
    setFilterOps([...s.ops]..[index] = FilterRegistry.defaultOp(s.ops[index].id));
  }

  void toggleFilter(int index) {
    final s = filterSession;
    if (s == null || index < 0 || index >= s.ops.length) return;
    setFilterOps([...s.ops]..[index] = s.ops[index].copyWith(enabled: !s.ops[index].enabled));
  }

  void removeFilter(int index) {
    final s = filterSession;
    if (s == null || index < 0 || index >= s.ops.length) return;
    setFilterOps([...s.ops]..removeAt(index));
  }

  void moveFilter(int index, int delta) {
    final s = filterSession;
    if (s == null) return;
    final to = index + delta;
    if (index < 0 || index >= s.ops.length || to < 0 || to >= s.ops.length) return;
    final list = [...s.ops];
    list.insert(to, list.removeAt(index));
    setFilterOps(list);
  }

  void applyFilterPreset(FilterPreset preset, {bool replace = true}) {
    final s = filterSession;
    if (s == null) return;
    setFilterOps(replace ? List.of(preset.ops) : [...s.ops, ...preset.ops]);
  }

  /// Before/after: temporarily shows the unfiltered pixels.
  void setShowOriginal(bool value) {
    final s = filterSession;
    if (s == null) return;
    s.showOriginal = value;
    final layer = data.layerById(s.layerId);
    if (layer == null) return;
    if (value) {
      layer.processed = null;
    } else {
      _schedulePreview(immediate: true);
    }
    compositor.invalidateAll();
    repaint.ping();
    _notify();
  }

  void _schedulePreview({bool immediate = false}) {
    final s = filterSession;
    if (s == null) return;
    s.debounce?.cancel();
    s.job?.cancel();
    final gen = ++s.generation;
    s.debounce = Timer(immediate ? Duration.zero : const Duration(milliseconds: 180), () {
      unawaited(_runPreview(s, gen));
    });
  }

  Future<void> _runPreview(FilterSession s, int gen) async {
    final layer = data.layerById(s.layerId);
    final image = layer?.image;
    if (layer == null || image == null || s.showOriginal) return;
    final active = [for (final o in s.ops) if (o.enabled) o];
    if (active.isEmpty) {
      layer.processed = null;
      layer.processedSig = null;
      repaint.ping();
      return;
    }
    try {
      final small = FilterEngine.downscale(_asFilterImage(image), SketchFilterActions.previewSide);
      final job = await FilterRunner.start(small, active);
      if (gen != s.generation) {
        job.cancel();
        return;
      }
      s.job = job;
      filterProgress.value = 0;
      job.progress.stream.listen((f) => filterProgress.value = f);
      final out = await job.result;
      if (gen != s.generation || filterSession != s) return;
      layer.processed = LayerImage(width: out.width, height: out.height, rgba: out.rgba);
      layer.processedSig = 'preview';
      filterProgress.value = null;
      await compositor.prepareAll();
      repaint.ping();
    } on FilterCancelled {
      // Superseded by a newer preview.
    } on FilterBudgetException catch (e) {
      _notice(e.message);
    } catch (error, stack) {
      AppLog.error('Filter preview failed', error: error, stackTrace: stack);
      filterProgress.value = null;
      _notice('The filter preview failed.');
    }
  }

  /// Leaves the editor without changing anything (no history entry).
  void cancelFilterSession() {
    final s = filterSession;
    if (s == null) return;
    s.debounce?.cancel();
    s.job?.cancel();
    s.generation++;
    final layer = data.layerById(s.layerId);
    if (layer != null) {
      layer.processed = s.savedProcessed;
      layer.processedSig = s.savedSig;
    }
    filterSession = null;
    filterProgress.value = null;
    compositor.invalidateAll();
    repaint.ping();
    _notify();
  }

  /// Runs the stack at full resolution and keeps it as the layer's editable
  /// stack. With [destructive] the result replaces the original pixels and
  /// the stack is cleared (the only way originals are lost; undo restores).
  Future<bool> commitFilterSession({bool destructive = false}) async {
    final s = filterSession;
    if (s == null) return false;
    s.debounce?.cancel();
    s.job?.cancel();
    s.generation++;
    final layer = data.layerById(s.layerId);
    final image = layer?.image;
    if (layer == null || image == null) return false;
    final active = [for (final o in s.ops) if (o.enabled) o];
    FilterImage? result;
    if (active.isNotEmpty) {
      try {
        filterProgress.value = 0;
        final job = await FilterRunner.start(_asFilterImage(image), active);
        s.job = job;
        job.progress.stream.listen((f) => filterProgress.value = f);
        result = await job.result;
      } on FilterCancelled {
        filterProgress.value = null;
        return false;
      } on FilterBudgetException catch (e) {
        filterProgress.value = null;
        _notice(e.message);
        return false;
      } catch (error, stack) {
        AppLog.error('Filter apply failed', error: error, stackTrace: stack);
        filterProgress.value = null;
        _notice('The filters could not be applied.');
        return false;
      }
    }
    filterProgress.value = null;
    if (filterSession != s) return false;
    // Put the layer back to its saved state, then record one undoable change.
    layer.processed = s.savedProcessed;
    layer.processedSig = s.savedSig;
    filterSession = null;
    final label = active.isEmpty
        ? 'Clear filters'
        : destructive
            ? 'Apply filters (permanent)'
            : 'Filters: ${active.map((o) => FilterRegistry.byId(o.id)?.label ?? o.id).join(', ')}';
    _recordStructural(label, () {
      final target = data.layerById(s.layerId);
      if (target == null) return;
      if (result == null) {
        target.filters.clear();
        target.processed = null;
        target.processedSig = null;
      } else if (destructive) {
        target.filters.clear();
        target.processed = null;
        target.processedSig = null;
        _replaceImage(target, LayerImage(width: result.width, height: result.height, rgba: result.rgba));
      } else {
        target.filters
          ..clear()
          ..addAll(s.ops);
        target.processed = LayerImage(width: result.width, height: result.height, rgba: result.rgba);
        target.processedSig = target.filterSig;
      }
    });
    filterHistory.add(label);
    _notify();
    return true;
  }

  void _replaceImage(SketchLayerData layer, LayerImage image) {
    final index = data.layers.indexWhere((l) => l.id == layer.id);
    if (index < 0) return;
    final old = data.layers[index];
    data.layers[index] = SketchLayerData(
      id: old.id,
      name: old.name,
      kind: old.kind,
      parentId: old.parentId,
      visible: old.visible,
      locked: old.locked,
      opacity: old.opacity,
      blend: old.blend,
      alphaLock: old.alphaLock,
      clipToBelow: old.clipToBelow,
      expanded: old.expanded,
      mask: old.mask,
      image: image,
      matrix: old.matrix,
    );
  }

  /// Rebuilds cached results for layers whose stacks were loaded from disk.
  Future<void> rebuildFilterCaches() async {
    for (final layer in List.of(data.layers)) {
      if (!layer.isImage || layer.filters.isEmpty || layer.processed != null) continue;
      final image = layer.image;
      if (image == null) continue;
      try {
        final job = await FilterRunner.start(
            _asFilterImage(image), [for (final o in layer.filters) if (o.enabled) o]);
        final out = await job.result;
        layer.processed = LayerImage(width: out.width, height: out.height, rgba: out.rgba);
        layer.processedSig = layer.filterSig;
      } catch (error, stack) {
        AppLog.error('Rebuilding filters failed', error: error, stackTrace: stack);
        _notice('Some filter results could not be rebuilt for "${layer.name}".');
      }
    }
    await compositor.prepareAll();
    repaint.ping();
  }
}
