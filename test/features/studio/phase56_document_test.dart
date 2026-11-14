import 'dart:typed_data';
import 'dart:convert';
import 'dart:ui' show Offset;

import 'package:artfoxel/features/studio/domain/assist_model.dart';
import 'package:artfoxel/features/studio/domain/canvas_document.dart';
import 'package:artfoxel/features/studio/domain/gradient_model.dart';
import 'package:artfoxel/features/studio/domain/shape_model.dart';
import 'package:artfoxel/features/studio/domain/sketch_document_data.dart';
import 'package:artfoxel/features/studio/filters/filter_engine.dart';
import 'package:flutter_test/flutter_test.dart';

SketchDocumentData _doc() => SketchDocumentData.blank(CanvasDocument.defaultPortrait);

Map<String, dynamic> _roundTrip(SketchDocumentData d) =>
    jsonDecode(jsonEncode(d.toJson())) as Map<String, dynamic>;

void main() {
  test('shapes, gradient fills, assists and filter stacks survive save and reopen', () {
    final d = _doc();
    d.layers.first.shapes.add(ShapeData(
      kind: ShapeKind.roundedRect,
      points: const [Offset(10, 10), Offset(200, 120)],
      cornerRadius: 30,
      fillGradient: GradientData(stops: const [GradientStop(0, 0xFFFF0000), GradientStop(1, 0xFF0000FF)]),
    ));
    d.assist = const AssistData(grid: GridKind.square, symmetry: SymmetryKind.vertical, horizonY: 400);
    final img = SketchLayerData(
      id: 'layer-9',
      name: 'Photo',
      kind: LayerKind.image,
      image: LayerImage(width: 2, height: 2, rgba: Uint8List.fromList(List.filled(16, 200))),
      filters: [FilterRegistry.defaultOp('gaussian').copyWith(params: {'radius': 6})],
    );
    d.layers.add(img);

    final back = SketchDocumentData.fromJson(_roundTrip(d));
    expect(back.layers.first.shapes.single.kind, ShapeKind.roundedRect);
    expect(back.layers.first.shapes.single.fillGradient, isNotNull);
    expect(back.assist.grid, GridKind.square);
    expect(back.assist.symmetry, SymmetryKind.vertical);
    final restored = back.layerById('layer-9')!;
    expect(restored.filters.single.params['radius'], 6);
    expect(restored.processed, isNull); // cache is rebuilt, never saved
    expect(restored.image!.rgba.every((b) => b == 200), isTrue); // original untouched
  });

  test('a default project writes no assist, shape or filter keys', () {
    final json = _roundTrip(_doc());
    expect(json.containsKey('assist'), isFalse);
    expect((json['layers'] as List).first.containsKey('shapes'), isFalse);
    expect((json['layers'] as List).first.containsKey('filters'), isFalse);
  });

  test('older projects without the new keys still open', () {
    final json = _roundTrip(_doc());
    final back = SketchDocumentData.fromJson(json);
    expect(back.assist.isDefault, isTrue);
    expect(back.layers.first.shapes, isEmpty);
  });

  test('corrupt shape or filter data is refused, not half-loaded', () {
    final json = _roundTrip(_doc());
    ((json['layers'] as List).first as Map)['shapes'] = [
      {'k': 'blob', 'pts': []}
    ];
    expect(() => SketchDocumentData.fromJson(json), throwsA(isA<SketchFormatException>()));
    final json2 = _roundTrip(_doc());
    ((json2['layers'] as List).first as Map)['filters'] = [
      {'id': 'nope', 'p': {}}
    ];
    expect(() => SketchDocumentData.fromJson(json2), throwsA(isA<SketchFormatException>()));
  });

  test('copy() keeps shapes, filters and cached results (history snapshots)', () {
    final layer = SketchLayerData(id: 'layer-5', name: 'x');
    layer.shapes.add(ShapeData(kind: ShapeKind.line, points: const [Offset(0, 0), Offset(5, 5)]));
    layer.filters.add(FilterRegistry.defaultOp('hue'));
    final c = layer.copy();
    expect(c.shapes.length, 1);
    expect(c.filters.length, 1);
    c.shapes.clear();
    expect(layer.shapes.length, 1); // lists are independent
  });
}
