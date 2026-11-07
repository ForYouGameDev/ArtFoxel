import 'dart:ui' show Offset, Rect;

import 'package:artfoxel/features/studio/application/sketch_controller.dart';
import 'package:artfoxel/features/studio/domain/alpha_mask.dart';
import 'package:artfoxel/features/studio/domain/builtin_brushes.dart';
import 'package:artfoxel/features/studio/domain/canvas_document.dart';
import 'package:artfoxel/features/studio/domain/canvas_input.dart';
import 'package:artfoxel/features/studio/domain/doc_geometry.dart';
import 'package:artfoxel/features/studio/domain/layer_blend.dart';
import 'package:artfoxel/features/studio/domain/sketch_document_data.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';

CanvasInputSample _s(double x, double y, int ms) => CanvasInputSample(
      pointerId: 1,
      kind: PointerDeviceKind.stylus,
      screenPosition: Offset(x, y),
      documentPosition: Offset(x, y),
      timestamp: Duration(milliseconds: ms),
      pressure: 0.5,
    );

void _draw(SketchController c, {double x = 10}) {
  c.beginStroke(_s(x, 10, 0));
  for (var i = 1; i < 6; i++) {
    c.extendStroke(_s(x + i * 8.0, 10 + i * 3.0, i * 10));
  }
  c.endStroke(_s(x + 50, 30, 60));
}

SketchController _controller() => SketchController(
      data: SketchDocumentData.blank(CanvasDocument(width: 400, height: 300, backgroundColor: null)),
      rasterize: false,
    );

void main() {
  group('layer panel actions', () {
    test('add, select, rename, undo and redo', () {
      final c = _controller();
      final first = c.activeLayerId;
      c.addLayer();
      final second = c.activeLayerId;
      expect(second, isNot(first));
      expect(c.data.layers, hasLength(2));
      c.renameLayer(second, 'Sky');
      expect(c.data.layerById(second)!.name, 'Sky');
      c.undo();
      expect(c.data.layerById(second)!.name, isNot('Sky'));
      c.undo();
      expect(c.data.layers, hasLength(1));
      expect(c.activeLayerId, first);
      c.redo();
      c.redo();
      expect(c.data.layerById(second)!.name, 'Sky');
      c.dispose();
    });

    test('drawing goes to the selected layer and undo is per layer', () {
      final c = _controller();
      final bottom = c.activeLayerId;
      c.addLayer();
      final top = c.activeLayerId;
      _draw(c);
      expect(c.data.layerById(top)!.strokes, hasLength(1));
      expect(c.data.layerById(bottom)!.strokes, isEmpty);
      c.selectLayer(bottom);
      _draw(c);
      expect(c.data.layerById(bottom)!.strokes, hasLength(1));
      c.undo();
      expect(c.data.layerById(bottom)!.strokes, isEmpty);
      expect(c.data.layerById(top)!.strokes, hasLength(1));
      c.dispose();
    });

    test('delete then undo restores the same layer id and content', () {
      final c = _controller();
      c.addLayer();
      final id = c.activeLayerId;
      _draw(c);
      c.deleteLayer(id);
      expect(c.data.layerById(id), isNull);
      c.undo();
      expect(c.data.layerById(id)!.strokes, hasLength(1));
      expect(c.activeLayerId, id);
      c.dispose();
    });

    test('duplicate, group, reorder keep ids stable', () {
      final c = _controller();
      final a = c.activeLayerId;
      c.addLayer();
      final b = c.activeLayerId;
      c.nudgeLayer(b, -1);
      expect(c.data.layers.map((l) => l.id), [b, a]);
      c.duplicateLayer(a);
      expect(c.data.layers.length, 3);
      c.selectLayer(a);
      c.groupActive();
      expect(c.data.layerById(a)!.parentId, c.activeLayerId);
      c.undo();
      expect(c.data.layerById(a)!.parentId, isNull);
      c.dispose();
    });

    test('hidden, locked and group layers refuse drawing with a message', () {
      final c = _controller();
      final messages = <String>[];
      c.notices.addListener(() {
        if (c.notices.value != null) messages.add(c.notices.value!);
      });
      final id = c.activeLayerId;
      c.setLayerLocked(id, true);
      _draw(c);
      expect(c.activeLayer.strokes, isEmpty);
      c.setLayerLocked(id, false);
      c.setLayerVisible(id, false);
      _draw(c);
      expect(c.activeLayer.strokes, isEmpty);
      c.setLayerVisible(id, true);
      c.addGroup();
      _draw(c);
      expect(messages.length, 3);
      c.undo(); // add group
      c.selectLayer(id);
      _draw(c);
      expect(c.activeLayer.strokes, hasLength(1));
      c.dispose();
    });

    test('opacity drag is a single undo step; blend and visibility are undoable', () {
      final c = _controller();
      final id = c.activeLayerId;
      c.previewLayerOpacity(id, .8);
      c.previewLayerOpacity(id, .4);
      c.commitLayerOpacity(id, 1);
      expect(c.data.layerById(id)!.opacity, closeTo(.4, 1e-9));
      c.setLayerBlend(id, LayerBlend.screen);
      c.setLayerVisible(id, false);
      c.undo();
      c.undo();
      expect(c.data.layerById(id)!.blend, LayerBlend.normal);
      expect(c.data.layerById(id)!.visible, isTrue);
      expect(c.data.layerById(id)!.opacity, closeTo(.4, 1e-9));
      c.undo();
      expect(c.data.layerById(id)!.opacity, 1);
      c.dispose();
    });

    test('alpha lock marks new strokes and blocks erasing', () {
      final c = _controller();
      final id = c.activeLayerId;
      c.setAlphaLock(id, true);
      _draw(c);
      expect(c.activeLayer.strokes.single.alphaLock, isTrue);
      c.selectBrush(BuiltInBrushes.byId('builtin.eraser')!);
      _draw(c, x: 100);
      expect(c.activeLayer.strokes, hasLength(1)); // erasing refused
      c.dispose();
    });

    test('clipping needs a layer below', () {
      final c = _controller();
      final first = c.activeLayerId;
      c.setClipToBelow(first, true);
      expect(c.data.layerById(first)!.clipToBelow, isFalse);
      c.addLayer();
      final second = c.activeLayerId;
      c.setClipToBelow(second, true);
      expect(c.data.layerById(second)!.clipToBelow, isTrue);
      c.undo();
      expect(c.data.layerById(second)!.clipToBelow, isFalse);
      c.dispose();
    });
  });

  group('masks', () {
    test('add, paint on mask, toggle, invert, delete, undo', () async {
      final c = _controller();
      final id = c.activeLayerId;
      await c.addMask();
      expect(c.activeLayer.mask, isNotNull);
      expect(c.editingMask, isTrue);
      _draw(c);
      expect(c.activeLayer.strokes, isEmpty);
      expect(c.activeLayer.mask!.strokes, hasLength(1));
      // Mask strokes are grayscale.
      final color = c.activeLayer.mask!.strokes.single.colorArgb;
      expect((color >> 16) & 0xFF, color & 0xFF);
      c.setEditingMask(false);
      _draw(c, x: 100);
      expect(c.activeLayer.strokes, hasLength(1));
      c.setMaskEnabled(id, false);
      expect(c.activeLayer.mask!.enabled, isFalse);
      c.invertMask(id);
      expect(c.activeLayer.mask!.inverted, isTrue);
      c.deleteMask(id);
      expect(c.activeLayer.mask, isNull);
      c.undo();
      expect(c.activeLayer.mask, isNotNull);
      expect(c.activeLayer.mask!.inverted, isTrue);
      expect(c.activeLayer.mask!.strokes, hasLength(1));
      c.dispose();
    });

    test('hide-all mask and mask from selection', () async {
      final c = _controller();
      await c.addMask(hideAll: true);
      expect(c.activeLayer.mask!.bitmap!.isEmpty, isTrue);
      c.undo();
      expect(c.activeLayer.mask, isNull);
      c.selectTool(SketchTool.selectRect);
      c.toolPointerDown(const Offset(50, 50));
      c.toolPointerUp(const Offset(150, 100));
      expect(c.selection, isNotNull);
      await c.addMask(fromSelection: true);
      final bitmap = c.activeLayer.mask!.bitmap!;
      expect(bitmap.at(100, 75), 255);
      expect(bitmap.at(10, 10), 0);
      c.dispose();
    });

    test('mask on a group is refused; second mask is refused', () async {
      final c = _controller();
      c.addGroup();
      await c.addMask();
      expect(c.activeLayer.mask, isNull);
      c.undo();
      await c.addMask();
      await c.addMask();
      expect(c.undoLabel, 'Add mask');
      c.dispose();
    });

    test('apply mask only exists for image layers', () async {
      final c = _controller();
      await c.addMask();
      expect(c.canApplyMask(c.activeLayer), isFalse);
      c.applyMask(c.activeLayerId);
      expect(c.activeLayer.mask, isNotNull);
      c.dispose();
    });
  });

  group('selection', () {
    test('rectangle, ellipse, modes, invert, grow, feather — in document coordinates', () {
      final c = _controller();
      c.selectTool(SketchTool.selectRect);
      c.toolPointerDown(const Offset(100, 100));
      c.toolPointerMove(const Offset(150, 140));
      c.toolPointerUp(const Offset(200, 200));
      final area = c.selection!.area;
      expect(area, closeTo(100 * 100, 150)); // 400x300 doc maps 1:1 to the mask
      c.setSelectionMode(SelectionMode.add);
      c.selectTool(SketchTool.selectEllipse);
      c.toolPointerDown(const Offset(250, 100));
      c.toolPointerUp(const Offset(350, 200));
      expect(c.selection!.area, greaterThan(area + 6000));
      c.setSelectionMode(SelectionMode.subtract);
      c.selectTool(SketchTool.selectRect);
      c.toolPointerDown(const Offset(0, 0));
      c.toolPointerUp(const Offset(400, 300));
      expect(c.selection, isNull); // everything subtracted
      c.undo();
      expect(c.selection, isNotNull);
      c.dispose();
    });

    test('lasso and polygon', () {
      final c = _controller();
      c.selectTool(SketchTool.selectLasso);
      c.toolPointerDown(const Offset(10, 10));
      c.toolPointerMove(const Offset(110, 10));
      c.toolPointerMove(const Offset(110, 110));
      c.toolPointerUp(const Offset(10, 110));
      expect(c.selection!.area, closeTo(10000, 400));
      c.deselect();
      expect(c.selection, isNull);
      c.selectTool(SketchTool.selectPolygon);
      for (final p in const [Offset(200, 50), Offset(300, 50), Offset(300, 150)]) {
        c.toolPointerDown(p);
        c.toolPointerUp(p);
      }
      expect(c.hasOpenPolygon, isTrue);
      expect(c.selection, isNull);
      c.closePolygon();
      expect(c.selection!.area, closeTo(5000, 300));
      c.dispose();
    });

    test('select all, invert, expand, contract, feather', () {
      final c = _controller();
      c.selectAll();
      expect(c.selection!.isFull, isTrue);
      c.invertSelection();
      expect(c.selection, isNull);
      c.selectTool(SketchTool.selectRect);
      c.toolPointerDown(const Offset(100, 100));
      c.toolPointerUp(const Offset(200, 200));
      final base = c.selection!.area;
      c.growSelection(10);
      expect(c.selection!.area, greaterThan(base));
      c.growSelection(-10);
      expect(c.selection!.area, closeTo(base, 400));
      c.featherSelection(8);
      expect(c.selection!.data.any((v) => v > 0 && v < 255), isTrue);
      c.dispose();
    });

    test('selection state is not saved as document changes but is undoable', () {
      final c = _controller();
      c.selectAll();
      expect(c.undoLabel, 'Select all');
      c.undo();
      expect(c.selection, isNull);
      c.dispose();
    });

    test('copy needs a selection', () async {
      final c = _controller();
      final messages = <String>[];
      c.notices.addListener(() {
        if (c.notices.value != null) messages.add(c.notices.value!);
      });
      expect(await c.copySelection(), isFalse);
      c.pasteClipboard();
      expect(messages, hasLength(2));
      c.dispose();
    });

    test('selection is cleared when the canvas geometry changes', () {
      final c = _controller();
      c.selectAll();
      c.resizeCanvas(500, 400);
      expect(c.selection, isNull);
      c.undo();
      expect(c.selection, isNotNull);
      c.dispose();
    });
  });

  group('transform and canvas size', () {
    test('preview does not touch the document; cancel leaves it unchanged', () {
      final c = _controller();
      _draw(c);
      final before = c.strokes.single.points.first.x;
      expect(c.beginTransform(), isTrue);
      c.updateTransform((s) {
        s.translateX = 50;
        s.rotationDegrees = 30;
      });
      expect(c.transformPreview, isNotNull);
      expect(c.strokes.single.points.first.x, before);
      c.cancelTransform();
      expect(c.transformPreview, isNull);
      expect(c.strokes.single.points.first.x, before);
      expect(c.undoLabel, 'Stroke');
      c.dispose();
    });

    test('apply bakes geometry as one undo step', () {
      final c = _controller();
      _draw(c);
      final x0 = c.strokes.single.points.first.x;
      final size0 = c.strokes.single.size;
      c.beginTransform();
      c.updateTransform((s) {
        s.translateX = 20;
        s.scaleX = 2;
      });
      c.applyTransform();
      final moved = c.strokes.single;
      expect(moved.size, closeTo(size0 * 2, 1e-6));
      expect(moved.points.first.x, isNot(x0));
      expect(c.undoLabel, 'Transform');
      c.undo();
      expect(c.strokes.single.points.first.x, closeTo(x0, 1e-9));
      expect(c.strokes.single.size, size0);
      c.redo();
      expect(c.strokes.single.size, closeTo(size0 * 2, 1e-6));
      c.dispose();
    });

    test('flip uses the pivot; identity apply records nothing', () {
      final c = _controller();
      _draw(c);
      c.beginTransform();
      c.applyTransform();
      expect(c.undoLabel, 'Stroke');
      c.beginTransform();
      final s = c.transformSession!;
      expect(s.pivot, s.bounds.center);
      c.updateTransform((t) => t.flipH = true);
      final p = c.transformSession!.matrix.apply(c.transformSession!.pivot);
      expect(p.dx, closeTo(s.pivot.dx, 1e-9));
      c.cancelTransform();
      c.dispose();
    });

    test('empty and locked layers cannot be transformed', () {
      final c = _controller();
      expect(c.beginTransform(), isFalse);
      _draw(c);
      c.setLayerLocked(c.activeLayerId, true);
      expect(c.beginTransform(), isFalse);
      c.dispose();
    });

    test('group transform moves every child', () {
      final c = _controller();
      _draw(c);
      final child = c.activeLayerId;
      c.groupActive();
      final x0 = c.data.layerById(child)!.strokes.single.points.first.x;
      expect(c.beginTransform(), isTrue);
      c.updateTransform((s) => s.translateX = 30);
      c.applyTransform();
      expect(c.data.layerById(child)!.strokes.single.points.first.x, closeTo(x0 + 30, 1e-9));
      c.dispose();
    });

    test('crop, resize canvas and resize image are separate, undoable steps', () {
      final c = _controller();
      _draw(c);
      final x0 = c.strokes.single.points.first.x;
      final size0 = c.strokes.single.size;
      c.cropImage(const Rect.fromLTWH(10, 10, 200, 100));
      expect((c.data.width, c.data.height), (200, 100));
      expect(c.strokes.single.points.first.x, closeTo(x0 - 10, 1e-9));
      c.resizeCanvas(300, 300, anchor: CanvasAnchor.center);
      expect((c.data.width, c.data.height), (300, 300));
      c.resizeImage(600, 600);
      expect(c.strokes.single.size, closeTo(size0 * 2, 1e-6));
      c.undo();
      c.undo();
      expect((c.data.width, c.data.height), (200, 100));
      c.undo();
      expect((c.data.width, c.data.height), (400, 300));
      expect(c.strokes.single.points.first.x, closeTo(x0, 1e-9));
      c.dispose();
    });

    test('bad canvas sizes are refused with a message', () {
      final c = _controller();
      final messages = <String>[];
      c.notices.addListener(() {
        if (c.notices.value != null) messages.add(c.notices.value!);
      });
      c.resizeImage(0, 10);
      c.cropImage(const Rect.fromLTWH(1000, 1000, 10, 10));
      expect(messages, hasLength(2));
      expect((c.data.width, c.data.height), (400, 300));
      expect(c.canUndo, isFalse);
      c.dispose();
    });

    test('everything survives save and reopen after transforms', () {
      final c = _controller();
      _draw(c);
      c.addLayer();
      c.setLayerBlend(c.activeLayerId, LayerBlend.multiply);
      c.selectLayer(c.data.layers.first.id);
      c.beginTransform();
      c.updateTransform((s) => s.scaleX = 1.5);
      c.applyTransform();
      final copy = SketchDocumentData.fromJson(c.data.toJson());
      expect(copy.layers.length, 2);
      expect(copy.layers.first.strokes.single.size, closeTo(c.data.layers.first.strokes.single.size, 1e-2));
      expect(copy.layers.last.blend, LayerBlend.multiply);
      c.dispose();
    });
  });
}
