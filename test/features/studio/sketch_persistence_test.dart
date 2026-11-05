import 'dart:io';

import 'package:artfoxel/features/studio/application/sketch_controller.dart';
import 'package:artfoxel/features/studio/data/sketch_storage.dart';
import 'package:artfoxel/features/studio/domain/canvas_document.dart';
import 'package:artfoxel/features/studio/domain/canvas_input.dart';
import 'package:artfoxel/features/studio/domain/layer_blend.dart';
import 'package:artfoxel/features/studio/domain/sketch_document_data.dart';
import 'package:artfoxel/features/studio/domain/stroke_model.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';

CanvasInputSample _sample(double x, double y, int ms) => CanvasInputSample(
      pointerId: 1,
      kind: PointerDeviceKind.stylus,
      screenPosition: Offset(x, y),
      documentPosition: Offset(x, y),
      timestamp: Duration(milliseconds: ms),
      pressure: 0.5,
    );

void _draw(SketchController c) {
  c.beginStroke(_sample(10, 10, 0));
  for (var i = 1; i < 10; i++) {
    c.extendStroke(_sample(10 + i * 8.0, 10 + i * 3.0, i * 10));
  }
  c.endStroke(_sample(90, 40, 100));
}

void main() {
  late Directory dir;
  late SketchStorage storage;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('artfoxel_test');
    storage = SketchStorage(dir);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  SketchDocumentData blank() =>
      SketchDocumentData.blank(CanvasDocument.defaultPortrait);

  group('SketchDocumentData', () {
    test('JSON round trip keeps strokes', () {
      final c = SketchController(data: blank(), rasterize: false);
      _draw(c);
      final copy = SketchDocumentData.fromJson(c.data.toJson());
      expect(copy.activeLayer.strokes, hasLength(1));
      expect(copy.activeLayer.strokes.first.points.length,
          c.strokes.first.points.length);
      c.dispose();
    });

    test('newer version is rejected', () {
      final json = blank().toJson()..['formatVersion'] = 999;
      expect(() => SketchDocumentData.fromJson(json),
          throwsA(isA<SketchFormatException>()));
    });

    test('garbage is rejected', () {
      expect(() => SketchDocumentData.fromJson({'format': 'nope'}),
          throwsA(isA<SketchFormatException>()));
    });
  });

  group('SketchController', () {
    test('undo, redo and dirty tracking', () {
      final c = SketchController(data: blank(), rasterize: false);
      expect(c.canUndo, isFalse);
      _draw(c);
      expect(c.canUndo, isTrue);
      expect(c.isDirty, isTrue);
      c.undo();
      expect(c.strokes, isEmpty);
      expect(c.canRedo, isTrue);
      c.redo();
      expect(c.strokes, hasLength(1));
      _draw(c);
      expect(c.canRedo, isFalse);
      c.dispose();
    });

    test('autosave writes after the debounce', () async {
      var saves = 0;
      final c = SketchController(
        data: blank(),
        rasterize: false,
        autosaveDelay: const Duration(milliseconds: 20),
        onSave: (_) async => saves++,
      );
      _draw(c);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(saves, greaterThanOrEqualTo(1));
      expect(c.saveState, SaveState.saved);
      c.dispose();
    });

    test('failed save reports error and keeps changes', () async {
      final c = SketchController(
        data: blank(),
        rasterize: false,
        onSave: (_) async => throw const FileSystemException('disk full'),
      );
      _draw(c);
      await c.saveNow();
      expect(c.saveState, SaveState.error);
      expect(c.strokes, hasLength(1));
      c.dispose();
    });
  });

  group('SketchStorage', () {
    test('create, draw, save, close, reopen', () async {
      final c = SketchController(data: blank(), rasterize: false);
      _draw(c);
      await storage.save('p1', c.data);
      c.dispose();
      final loaded = await storage.load('p1');
      expect(loaded.document, isNotNull);
      expect(loaded.document!.activeLayer.strokes, hasLength(1));
      expect(loaded.recoveredFromCheckpoint, isFalse);
    });

    test('missing project loads as null document', () async {
      expect((await storage.load('nothing')).document, isNull);
    });

    test('checkpoint is recovered after a crash', () async {
      final c = SketchController(data: blank(), rasterize: false);
      _draw(c);
      await storage.writeCheckpoint('p2', c.data);
      c.dispose();
      final loaded = await storage.load('p2');
      expect(loaded.recoveredFromCheckpoint, isTrue);
      expect(loaded.document!.activeLayer.strokes, hasLength(1));
    });

    test('damaged main file falls back to backup', () async {
      final c = SketchController(data: blank(), rasterize: false);
      _draw(c);
      await storage.save('p3', c.data);
      _draw(c);
      await storage.save('p3', c.data); // first save becomes the backup
      c.dispose();
      File('${dir.path}/p3/sketch.json').writeAsStringSync('{ broken');
      final loaded = await storage.load('p3');
      expect(loaded.usedBackup, isTrue);
      expect(loaded.document!.activeLayer.strokes, hasLength(1));
    });

    test('layers, masks, clipping and blend modes survive save and reopen', () async {
      final c = SketchController(data: blank(), rasterize: false);
      final base = c.activeLayerId;
      _draw(c);
      c.addLayer();
      final top = c.activeLayerId;
      _draw(c);
      c.setClipToBelow(top, true);
      c.setLayerBlend(top, LayerBlend.overlay);
      c.setAlphaLock(top, true);
      await c.addMask(hideAll: true);
      // Group the base layer. (Grouping the clipped layer itself would clear its
      // clip on purpose, because a clip must not reach out of its group.)
      c.selectLayer(base);
      c.groupActive();
      await storage.save('p4', c.data);
      c.dispose();
      final loaded = (await storage.load('p4')).document!;
      final layer = loaded.layerById(top)!;
      expect(layer.clipToBelow, isTrue);
      expect(layer.blend, LayerBlend.overlay);
      expect(layer.alphaLock, isTrue);
      expect(layer.mask!.bitmap, isNotNull);
      expect(loaded.layerById(base)!.parentId, isNotNull);
      expect(loaded.layers.length, 3);
    });

    test('unsafe project ids are refused', () async {
      expect(() => storage.save('../evil', blank()), throwsA(anything));
    });
  });

  test('StrokePoint rejects invalid JSON', () {
    expect(() => StrokePoint.fromJson(const ['a', 1, 2]), throwsFormatException);
  });
}
