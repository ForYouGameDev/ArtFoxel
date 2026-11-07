part of 'sketch_controller.dart';

/// Everything needed to put the layer tree and canvas size back exactly as
/// they were. Strokes, pixel data and masks are immutable values, so a
/// snapshot only copies the lists that reference them.
class _Snapshot {
  _Snapshot(this.layers, this.width, this.height, this.safe, this.activeId,
      this.selection);

  final List<SketchLayerData> layers;
  final int width;
  final int height;
  final Rect safe;
  final String activeId;
  final AlphaMask? selection;

  static _Snapshot take(SketchController c) => _Snapshot(
        [for (final l in c.data.layers) l.copy()],
        c.data.width,
        c.data.height,
        c.data.safeBounds,
        c.activeLayerId,
        c.selection,
      );

  void restore(SketchController c, {bool invalidate = true}) {
    c.data.layers
      ..clear()
      ..addAll([for (final l in layers) l.copy()]);
    c.data.width = width;
    c.data.height = height;
    c.data.safeBounds = safe;
    c.activeLayerId = activeId;
    c.selection = selection;
    c._rebuildOverlay();
    if (invalidate) {
      c.compositor.invalidateAll();
      unawaited(c.compositor.prepareAll());
    }
  }
}

/// Layer, group and mask actions (Phase 4.1 / 4.3). Every method that changes
/// the document is one undoable step.
extension SketchLayerActions on SketchController {
  List<SketchLayerData> get topLevelLayers => LayerOps.children(data, null);

  void _meta(String label, void Function() change) {
    final before = _Snapshot.take(this);
    change();
    final after = _Snapshot.take(this);
    _pushEntry(_HistoryEntry(
      label,
      () => before.restore(this, invalidate: false),
      () => after.restore(this, invalidate: false),
    ));
    _markChanged();
  }

  void selectLayer(String id) {
    if (data.layerById(id) == null || id == activeLayerId) return;
    if (isDrawing) cancelStroke();
    if (transformSession != null) this.cancelTransform();
    activeLayerId = id;
    if (activeLayer.mask == null) editingMask = false;
    _notify();
  }

  void addLayer() {
    if (transformSession != null) this.cancelTransform();
    _guard(() {
      late SketchLayerData created;
      _recordStructural('Add layer', () {
        created = LayerOps.addPaintLayer(data, aboveId: activeLayerId);
        activeLayerId = created.id;
        editingMask = false;
      });
    });
  }

  void addGroup() {
    _guard(() {
      _recordStructural('Add group', () {
        activeLayerId = LayerOps.addGroup(data, aboveId: activeLayerId).id;
        editingMask = false;
      });
    });
  }

  /// Wraps the active layer in a new group.
  void groupActive() {
    _guard(() {
      _recordStructural('Group', () {
        activeLayerId = LayerOps.groupLayers(data, [activeLayerId]).id;
        editingMask = false;
      });
    });
  }

  void ungroup(String groupId) {
    _guard(() {
      _recordStructural('Ungroup', () {
        LayerOps.ungroup(data, groupId);
        if (data.layerById(activeLayerId) == null) {
          activeLayerId = data.layers.first.id;
        }
      });
    });
  }

  void duplicateLayer(String id) {
    _guard(() {
      _recordStructural('Duplicate layer', () {
        activeLayerId = LayerOps.duplicate(data, id).id;
        editingMask = false;
      });
    });
  }

  void deleteLayer(String id) {
    if (data.layerById(id) == null) return;
    if (transformSession != null) this.cancelTransform();
    _guard(() {
      _recordStructural('Delete layer', () {
        final next = LayerOps.delete(data, id);
        if (data.layerById(activeLayerId) == null) activeLayerId = next;
        editingMask = false;
      });
    });
  }

  void renameLayer(String id, String name) {
    _guard(() {
      final clean = LayerOps.sanitizeName(name);
      final layer = data.layerById(id);
      if (layer == null || layer.name == clean) return;
      _meta('Rename layer', () => layer.name = clean);
    });
  }

  void setLayerVisible(String id, bool visible) {
    final layer = data.layerById(id);
    if (layer == null || layer.visible == visible) return;
    _meta(visible ? 'Show layer' : 'Hide layer', () => layer.visible = visible);
  }

  void setLayerLocked(String id, bool locked) {
    final layer = data.layerById(id);
    if (layer == null || layer.locked == locked) return;
    _meta(locked ? 'Lock layer' : 'Unlock layer', () => layer.locked = locked);
  }

  /// Live slider feedback; no history entry. Finish with [commitLayerOpacity].
  void previewLayerOpacity(String id, double value) {
    final layer = data.layerById(id);
    if (layer == null) return;
    layer.opacity = value.clamp(0.0, 1.0).toDouble();
    repaint.ping();
    _notify();
  }

  /// Records one undo step for an opacity drag that started at [from].
  void commitLayerOpacity(String id, double from) {
    final layer = data.layerById(id);
    if (layer == null || (layer.opacity - from).abs() < 0.0001) return;
    final to = layer.opacity;
    _pushEntry(_HistoryEntry(
      'Layer opacity',
      () => data.layerById(id)?.opacity = from,
      () => data.layerById(id)?.opacity = to,
    ));
    _markChanged();
  }

  void setLayerBlend(String id, LayerBlend blend) {
    final layer = data.layerById(id);
    if (layer == null || layer.blend == blend) return;
    _meta('Blend mode', () => layer.blend = blend);
  }

  void setAlphaLock(String id, bool locked) {
    final layer = data.layerById(id);
    if (layer == null || layer.alphaLock == locked) return;
    if (!layer.isPaint) {
      _notice('Alpha lock only applies to paint layers.');
      return;
    }
    _meta(locked ? 'Alpha lock on' : 'Alpha lock off', () => layer.alphaLock = locked);
  }

  void setClipToBelow(String id, bool clip) {
    final layer = data.layerById(id);
    if (layer == null || layer.clipToBelow == clip) return;
    if (clip && LayerOps.children(data, layer.parentId).indexOf(layer) <= 0) {
      _notice('There is no layer below to clip to.');
      return;
    }
    _meta(clip ? 'Clip to layer below' : 'Release clipping', () => layer.clipToBelow = clip);
  }

  void toggleExpanded(String groupId) {
    final group = data.layerById(groupId);
    if (group == null || !group.isGroup) return;
    group.expanded = !group.expanded; // panel state; not an undo step
    _markChanged();
  }

  void nudgeLayer(String id, int direction) {
    final layer = data.layerById(id);
    if (layer == null) return;
    final siblings = LayerOps.children(data, layer.parentId);
    final to = siblings.indexOf(layer) + direction;
    if (to < 0 || to >= siblings.length) return;
    _guard(() => _meta('Reorder layer', () => LayerOps.nudge(data, id, direction)));
  }

  void moveLayerTo(String id, {required String? parentId, required int index}) {
    _guard(() => _meta('Move layer', () => LayerOps.moveTo(data, id, newParentId: parentId, index: index)));
  }

  // ---- masks ----------------------------------------------------------------------

  /// Adds a layer mask. [hideAll] starts fully hidden; [fromSelection] uses the
  /// current selection (selected = visible).
  Future<void> addMask({bool hideAll = false, bool fromSelection = false}) async {
    final layer = activeLayer;
    if (layer.isGroup) {
      _notice('Masks are available on paint and image layers.');
      return;
    }
    if (layer.mask != null) {
      _notice('This layer already has a mask.');
      return;
    }
    AlphaMask? bitmap;
    if (fromSelection) {
      bitmap = selection;
      if (bitmap == null || bitmap.isEmpty) {
        _notice('Make a selection first.');
        return;
      }
    } else if (hideAll) {
      bitmap = AlphaMask.forDocument(data.width, data.height);
    }
    final mask = LayerMaskData(bitmap: bitmap);
    // Create the GPU image first so the mask never shows as "reveal all".
    if (bitmap != null) {
      layer.mask = mask;
      await compositor.prepareAll();
      layer.mask = null;
    }
    _meta('Add mask', () {
      layer.mask = mask;
      editingMask = true;
    });
  }

  void setMaskEnabled(String id, bool enabled) {
    final layer = data.layerById(id);
    final mask = layer?.mask;
    if (mask == null || mask.enabled == enabled) return;
    _meta(enabled ? 'Enable mask' : 'Disable mask', () {
      mask.enabled = enabled;
      if (!enabled && id == activeLayerId) editingMask = false;
    });
  }

  void invertMask(String id) {
    final mask = data.layerById(id)?.mask;
    if (mask == null) return;
    _meta('Invert mask', () => mask.inverted = !mask.inverted);
  }

  void setEditingMask(bool editing) {
    final mask = activeLayer.mask;
    if (editing && mask == null) {
      _notice('Add a mask first.');
      return;
    }
    if (editing && !mask!.enabled) {
      mask.enabled = true; // editing a hidden effect would be confusing
    }
    editingMask = editing;
    _notify();
  }

  /// Removes the mask without applying it (the layer shows fully again).
  void deleteMask(String id) {
    final layer = data.layerById(id);
    if (layer?.mask == null) return;
    _recordStructural('Delete mask', () {
      data.layerById(id)!.mask = null;
      editingMask = false;
    });
  }

  bool canApplyMask(SketchLayerData layer) =>
      layer.isImage && layer.mask != null && layer.strokes.isEmpty && layer.mask!.strokes.isEmpty;

  /// Bakes the mask into an image layer's pixels (alpha). Undo restores the
  /// mask and the original pixels. Paint layers keep editable strokes, so
  /// their masks stay non-destructive and cannot be applied.
  void applyMask(String id) {
    final layer = data.layerById(id);
    final mask = layer?.mask;
    final image = layer?.image;
    if (layer == null || mask == null || image == null) {
      _notice('Only masks on image layers can be applied.');
      return;
    }
    if (!canApplyMask(layer)) {
      _notice('Apply mask works on image layers whose mask is a plain bitmap '
          '(no painted mask strokes).');
      return;
    }
    _recordStructural('Apply mask', () {
      final target = data.layerById(id)!;
      target.image = _bakeMask(image, target.matrix, mask, data.width, data.height);
      target.mask = null;
      editingMask = false;
    });
  }

  static LayerImage _bakeMask(
    LayerImage image,
    Affine2D matrix,
    LayerMaskData mask,
    int docWidth,
    int docHeight,
  ) {
    final bitmap = mask.bitmap;
    final out = Uint8List.fromList(image.rgba);
    for (var y = 0; y < image.height; y++) {
      for (var x = 0; x < image.width; x++) {
        final dx = matrix.applyX(x + 0.5, y + 0.5);
        final dy = matrix.applyY(x + 0.5, y + 0.5);
        var value = 255;
        if (bitmap != null) {
          final mx = (dx * bitmap.width / docWidth).floor();
          final my = (dy * bitmap.height / docHeight).floor();
          value = bitmap.at(mx, my);
        }
        if (mask.inverted) value = 255 - value;
        final i = (y * image.width + x) * 4 + 3;
        out[i] = (out[i] * value + 127) ~/ 255;
      }
    }
    return LayerImage(width: image.width, height: image.height, rgba: out);
  }
}
