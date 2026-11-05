import 'dart:typed_data';
import 'dart:ui' show Offset, Rect;

import 'package:artfoxel/features/studio/domain/affine2d.dart';
import 'package:artfoxel/features/studio/domain/alpha_mask.dart';
import 'package:artfoxel/features/studio/domain/builtin_brushes.dart';
import 'package:artfoxel/features/studio/domain/canvas_document.dart';
import 'package:artfoxel/features/studio/domain/doc_geometry.dart';
import 'package:artfoxel/features/studio/domain/layer_blend.dart';
import 'package:artfoxel/features/studio/domain/layer_ops.dart';
import 'package:artfoxel/features/studio/domain/sketch_document_data.dart';
import 'package:artfoxel/features/studio/domain/stroke_model.dart';
import 'package:flutter_test/flutter_test.dart';

SketchStroke _stroke(SketchDocumentData doc, {double x = 10, double y = 20, double size = 8, bool lock = false}) =>
    SketchStroke(
      brushKey: doc.registerBrush(BuiltInBrushes.defaultBrush),
      colorArgb: 0xFF112233,
      size: size,
      opacity: 1,
      flow: 1,
      seed: 3,
      alphaLock: lock,
      points: [
        StrokePoint(x: x, y: y, t: 0),
        StrokePoint(x: x + 40, y: y + 10, t: 10),
      ],
    );

SketchDocumentData _doc() =>
    SketchDocumentData.blank(CanvasDocument(width: 400, height: 300, backgroundColor: null));

List<String> _names(SketchDocumentData d) => [for (final l in d.layers) l.name];

void main() {
  group('LayerOps', () {
    test('ids are stable, unique and never reused', () {
      final d = _doc();
      final a = LayerOps.addPaintLayer(d);
      final b = LayerOps.addPaintLayer(d);
      expect({d.layers[0].id, a.id, b.id}.length, 3);
      LayerOps.delete(d, a.id);
      final c = LayerOps.addPaintLayer(d);
      expect(c.id, isNot(a.id)); // highest id wins, so no reuse of a's id slot
      expect(c.id, isNot(b.id));
    });

    test('new layers are inserted above the reference layer', () {
      final d = _doc();
      final base = d.layers.first;
      final top = LayerOps.addPaintLayer(d);
      final mid = LayerOps.addPaintLayer(d, aboveId: base.id);
      expect([for (final l in d.layers) l.id], [base.id, mid.id, top.id]);
    });

    test('rename sanitising and duplicate names', () {
      expect(LayerOps.sanitizeName('  Sky\u0000 '), 'Sky');
      expect(() => LayerOps.sanitizeName('   '), throwsA(isA<LayerOpException>()));
      expect(LayerOps.sanitizeName('x' * 100).length, 40);
      final d = _doc();
      final copy = LayerOps.duplicate(d, d.layers.first.id);
      expect(copy.name, 'Layer 1 copy');
      expect(LayerOps.duplicate(d, d.layers.first.id).name, 'Layer 1 copy 2');
    });

    test('duplicate copies content independently', () {
      final d = _doc();
      d.layers.first.strokes.add(_stroke(d));
      final copy = LayerOps.duplicate(d, d.layers.first.id);
      expect(copy.strokes, hasLength(1));
      copy.strokes.clear();
      expect(d.layers.first.strokes, hasLength(1));
      expect(d.layers[1].id, copy.id); // directly above the original
    });

    test('nudge reorders among siblings and reports the ends', () {
      final d = _doc();
      final a = d.layers.first;
      final b = LayerOps.addPaintLayer(d);
      expect(LayerOps.nudge(d, a.id, 1), isTrue);
      expect([for (final l in d.layers) l.id], [b.id, a.id]);
      expect(LayerOps.nudge(d, a.id, 1), isFalse);
      expect(LayerOps.nudge(d, b.id, -1), isFalse);
    });

    test('grouping, ungrouping and nested deletion', () {
      final d = _doc();
      final a = d.layers.first;
      final b = LayerOps.addPaintLayer(d);
      final c = LayerOps.addPaintLayer(d);
      final group = LayerOps.groupLayers(d, [b.id]);
      expect(b.parentId, group.id);
      expect(LayerOps.children(d, null).map((l) => l.id), [a.id, group.id, c.id]);
      expect(LayerOps.depthOf(d, b), 1);
      LayerOps.ungroup(d, group.id);
      expect(b.parentId, isNull);
      expect(d.layers.any((l) => l.isGroup), isFalse);
      expect([for (final l in d.layers) l.id], [a.id, b.id, c.id]);

      final g2 = LayerOps.groupLayers(d, [b.id, c.id]);
      expect(LayerOps.descendants(d, g2.id).length, 2);
      LayerOps.delete(d, g2.id);
      expect([for (final l in d.layers) l.id], [a.id]);
    });

    test('grouping across different parents is refused', () {
      final d = _doc();
      final a = d.layers.first;
      final b = LayerOps.addPaintLayer(d);
      final g = LayerOps.groupLayers(d, [b.id]);
      expect(() => LayerOps.groupLayers(d, [a.id, b.id]), throwsA(isA<LayerOpException>()));
      expect(g.isGroup, isTrue);
    });

    test('moveTo changes parent and refuses cycles', () {
      final d = _doc();
      final a = d.layers.first;
      final g = LayerOps.addGroup(d);
      final inner = LayerOps.addGroup(d);
      LayerOps.moveTo(d, inner.id, newParentId: g.id, index: 0);
      LayerOps.moveTo(d, a.id, newParentId: inner.id, index: 0);
      expect(LayerOps.depthOf(d, a), 2);
      expect(() => LayerOps.moveTo(d, g.id, newParentId: inner.id, index: 0), throwsA(isA<LayerOpException>()));
      expect(() => LayerOps.moveTo(d, a.id, newParentId: a.id, index: 0), throwsA(isA<LayerOpException>()));
      // Flat storage still lists groups before their children.
      expect(d.layers.indexOf(g) < d.layers.indexOf(inner), isTrue);
      expect(d.layers.indexOf(inner) < d.layers.indexOf(a), isTrue);
    });

    test('deleting the last paint layer leaves a blank one', () {
      final d = _doc();
      final next = LayerOps.delete(d, d.layers.first.id);
      expect(d.layers, hasLength(1));
      expect(d.layers.first.id, next);
      expect(d.layers.first.isPaint, isTrue);
    });

    test('layer limit is enforced', () {
      final d = _doc();
      while (d.layers.length < SketchDocumentData.maxLayers) {
        LayerOps.addPaintLayer(d);
      }
      expect(() => LayerOps.addPaintLayer(d), throwsA(isA<LayerOpException>()));
    });

    test('effective visibility and lock follow ancestors', () {
      final d = _doc();
      final a = d.layers.first;
      final g = LayerOps.addGroup(d);
      LayerOps.moveTo(d, a.id, newParentId: g.id, index: 0);
      g.visible = false;
      g.locked = true;
      expect(LayerOps.isEffectivelyVisible(d, a), isFalse);
      expect(LayerOps.isEffectivelyLocked(d, a), isTrue);
      expect(LayerOps.hasClipBase(d, a), isFalse);
    });
  });

  group('serialization', () {
    SketchDocumentData rich() {
      final d = _doc();
      final base = d.layers.first
        ..name = 'Base'
        ..opacity = .6
        ..blend = LayerBlend.multiply
        ..locked = true;
      base.strokes.add(_stroke(d, lock: true));
      final clipped = LayerOps.addPaintLayer(d)
        ..clipToBelow = true
        ..alphaLock = true
        ..visible = false
        ..blend = LayerBlend.softLight;
      clipped.mask = LayerMaskData(
        inverted: true,
        enabled: false,
        bitmap: AlphaMask.rect(20, 15, const Rect.fromLTWH(2, 2, 8, 8)),
        strokes: [_stroke(d, x: 5)],
      );
      final g = LayerOps.addGroup(d)..expanded = false;
      final pasted = SketchLayerData(
        id: LayerOps.newId(d),
        name: 'Pasted',
        kind: LayerKind.image,
        image: LayerImage(width: 2, height: 2, rgba: Uint8List.fromList(List.generate(16, (i) => i * 10))),
        matrix: Affine2D.translation(30, 40) * Affine2D.scale(3, 3),
      );
      LayerOps.insert(d, pasted);
      LayerOps.moveTo(d, pasted.id, newParentId: g.id, index: 0);
      return d;
    }

    test('round trip preserves layers, masks, clipping, blend, groups, images', () {
      final original = rich();
      final copy = SketchDocumentData.fromJson(original.toJson());
      expect(copy.layers.length, original.layers.length);
      for (var i = 0; i < original.layers.length; i++) {
        final a = original.layers[i], b = copy.layers[i];
        expect(b.id, a.id);
        expect(b.name, a.name);
        expect(b.kind, a.kind);
        expect(b.parentId, a.parentId);
        expect(b.visible, a.visible);
        expect(b.locked, a.locked);
        expect(b.opacity, closeTo(a.opacity, 1e-9));
        expect(b.blend, a.blend);
        expect(b.alphaLock, a.alphaLock);
        expect(b.clipToBelow, a.clipToBelow);
        expect(b.expanded, a.expanded);
        expect(b.strokes.length, a.strokes.length);
        expect(b.mask == null, a.mask == null);
        expect(b.matrix, a.matrix);
      }
      expect(copy.layers.first.strokes.first.alphaLock, isTrue);
      final mask = copy.layers[1].mask!;
      expect(mask.inverted, isTrue);
      expect(mask.enabled, isFalse);
      expect(mask.bitmap!.data, original.layers[1].mask!.bitmap!.data);
      expect(mask.strokes, hasLength(1));
      final image = copy.layers.firstWhere((l) => l.isImage).image!;
      expect(image.rgba, orderedEquals(List.generate(16, (i) => i * 10)));
      // Stable across a second round trip.
      expect(SketchDocumentData.fromJson(copy.toJson()).toJson().toString(), copy.toJson().toString());
    });

    test('version 1 projects still open with default layer settings', () {
      final d = _doc();
      d.layers.first.strokes.add(_stroke(d));
      final json = d.toJson();
      json['formatVersion'] = 1;
      for (final layer in json['layers']! as List) {
        (layer as Map)
          ..remove('kind')
          ..remove('blend');
      }
      final loaded = SketchDocumentData.fromJson(json);
      expect(loaded.layers.first.kind, LayerKind.paint);
      expect(loaded.layers.first.blend, LayerBlend.normal);
      expect(loaded.layers.first.strokes, hasLength(1));
    });

    test('unknown blend names load as normal (never crash)', () {
      final json = rich().toJson();
      ((json['layers']! as List).first as Map)['blend'] = 'vividLight';
      expect(SketchDocumentData.fromJson(json).layers.first.blend, LayerBlend.normal);
    });

    test('invalid structure is rejected with a clear error', () {
      Map<String, Object?> fresh() => rich().toJson();
      List layers(Map<String, Object?> j) => j['layers']! as List;

      var j = fresh();
      (layers(j)[1] as Map)['id'] = (layers(j)[0] as Map)['id'];
      expect(() => SketchDocumentData.fromJson(j), throwsA(isA<SketchFormatException>()));

      j = fresh();
      (layers(j)[0] as Map)['parent'] = 'missing';
      expect(() => SketchDocumentData.fromJson(j), throwsA(isA<SketchFormatException>()));

      j = fresh();
      (layers(j)[0] as Map)['parent'] = (layers(j)[0] as Map)['id'];
      expect(() => SketchDocumentData.fromJson(j), throwsA(isA<SketchFormatException>()));

      j = fresh();
      (layers(j)[0] as Map)['kind'] = 'hologram';
      expect(() => SketchDocumentData.fromJson(j), throwsA(isA<SketchFormatException>()));

      j = fresh();
      final maskLayer = layers(j).firstWhere((l) => (l as Map)['mask'] != null) as Map;
      ((maskLayer['mask'] as Map)['bitmap'] as Map)['z'] = 'bm90IGd6aXA=';
      expect(() => SketchDocumentData.fromJson(j), throwsA(isA<SketchFormatException>()));

      j = fresh();
      final imageLayer = layers(j).firstWhere((l) => (l as Map)['kind'] == 'image') as Map;
      imageLayer['matrix'] = [0, 0, 0, 0, 0, 0];
      expect(() => SketchDocumentData.fromJson(j), throwsA(isA<SketchFormatException>()));
    });

    test('two group parents referring to each other are rejected', () {
      final d = _doc();
      final g1 = LayerOps.addGroup(d);
      final g2 = LayerOps.addGroup(d);
      final json = d.toJson();
      final layers = json['layers']! as List;
      (layers.firstWhere((l) => (l as Map)['id'] == g1.id) as Map)['parent'] = g2.id;
      (layers.firstWhere((l) => (l as Map)['id'] == g2.id) as Map)['parent'] = g1.id;
      expect(() => SketchDocumentData.fromJson(json), throwsA(isA<SketchFormatException>()));
    });
  });

  group('DocGeometry', () {
    test('transform moves points and scales brush size; stays editable', () {
      final d = _doc();
      final layer = d.layers.first..strokes.add(_stroke(d, x: 10, y: 20, size: 8));
      DocGeometry.transformLayer(d, layer, Affine2D.translation(5, 5) * Affine2D.scale(2, 2));
      final s = layer.strokes.single;
      expect(s.points.first.x, closeTo(25, 1e-9));
      expect(s.points.first.y, closeTo(45, 1e-9));
      expect(s.size, closeTo(16, 1e-9));
      expect(s.brushKey, isNotEmpty);
    });

    test('image layers keep pixels and change placement only', () {
      final d = _doc();
      final img = LayerImage(width: 2, height: 2, rgba: Uint8List(16));
      final layer = SketchLayerData(id: 'layer-9', name: 'i', kind: LayerKind.image, image: img);
      d.layers.add(layer);
      DocGeometry.transformLayer(d, layer, Affine2D.scale(2, 2));
      expect(identical(layer.image, img), isTrue);
      expect(layer.matrix, Affine2D.scale(2, 2));
    });

    test('flip twice returns the original points', () {
      final d = _doc();
      final layer = d.layers.first..strokes.add(_stroke(d, x: 30, y: 40));
      final flip = Affine2D.scale(-1, 1).aroundPivot(const Offset(200, 150));
      DocGeometry.transformLayer(d, layer, flip);
      expect(layer.strokes.single.points.first.x, closeTo(370, 1e-9));
      DocGeometry.transformLayer(d, layer, flip);
      expect(layer.strokes.single.points.first.x, closeTo(30, 1e-9));
    });

    test('crop image shifts artwork and sets the new size', () {
      final d = _doc();
      d.layers.first.strokes.add(_stroke(d, x: 100, y: 100));
      DocGeometry.cropImage(d, const Rect.fromLTWH(50, 60, 200, 100));
      expect((d.width, d.height), (200, 100));
      expect(d.layers.first.strokes.single.points.first.x, closeTo(50, 1e-9));
      expect(d.layers.first.strokes.single.points.first.y, closeTo(40, 1e-9));
      expect(d.layers.first.strokes.single.size, 8);
      expect(d.safeBounds, const Rect.fromLTWH(0, 0, 200, 100));
    });

    test('crop can keep or discard strokes that fall outside', () {
      SketchDocumentData make() {
        final d = _doc();
        d.layers.first.strokes
          ..add(_stroke(d, x: 10, y: 10))
          ..add(_stroke(d, x: 300, y: 250));
        return d;
      }

      final keep = make();
      DocGeometry.cropImage(keep, const Rect.fromLTWH(0, 0, 100, 100));
      expect(keep.layers.first.strokes, hasLength(2));
      final drop = make();
      DocGeometry.cropImage(drop, const Rect.fromLTWH(0, 0, 100, 100), discardOutside: true);
      expect(drop.layers.first.strokes, hasLength(1));
    });

    test('resize canvas keeps artwork size and honours the anchor', () {
      final d = _doc();
      d.layers.first.strokes.add(_stroke(d, x: 10, y: 10));
      DocGeometry.resizeCanvas(d, 500, 400, anchor: CanvasAnchor.bottomRight);
      expect((d.width, d.height), (500, 400));
      expect(d.layers.first.strokes.single.points.first.x, closeTo(110, 1e-9));
      expect(d.layers.first.strokes.single.points.first.y, closeTo(110, 1e-9));
      expect(d.layers.first.strokes.single.size, 8);
      DocGeometry.resizeCanvas(d, 100, 100, anchor: CanvasAnchor.topLeft);
      expect(d.layers.first.strokes.single.points.first.x, closeTo(110, 1e-9)); // kept, now outside
    });

    test('resize image scales canvas and artwork together', () {
      final d = _doc();
      d.layers.first.strokes.add(_stroke(d, x: 10, y: 20, size: 8));
      DocGeometry.resizeImage(d, 800, 600);
      expect((d.width, d.height), (800, 600));
      final s = d.layers.first.strokes.single;
      expect(s.points.first.x, closeTo(20, 1e-9));
      expect(s.points.first.y, closeTo(40, 1e-9));
      expect(s.size, closeTo(16, 1e-9));
    });

    test('geometry resamples bitmap masks to the new canvas', () {
      final d = _doc();
      final (mw, mh) = AlphaMask.sizeFor(d.width, d.height);
      d.layers.first.mask = LayerMaskData(bitmap: AlphaMask.filled(mw, mh, 128));
      DocGeometry.resizeImage(d, 800, 600);
      final m = d.layers.first.mask!.bitmap!;
      expect((m.width, m.height), (800, 600));
      expect(m.at(400, 300), 128);
    });

    test('invalid sizes are rejected without modifying the document', () {
      final d = _doc();
      expect(() => DocGeometry.resizeImage(d, 0, 10), throwsArgumentError);
      expect(() => DocGeometry.resizeCanvas(d, 99999, 10), throwsArgumentError);
      expect((d.width, d.height), (400, 300));
    });
  });
}
