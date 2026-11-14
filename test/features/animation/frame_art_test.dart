import 'dart:convert';
import 'dart:ui';

import 'package:artfoxel/features/animation/application/frame_art.dart';
import 'package:artfoxel/features/animation/domain/animation_model.dart';
import 'package:flutter_test/flutter_test.dart';

AnimationDocument _doc() => AnimationDocument(width: 320, height: 180);

AnimFrame _legacyFrame() => AnimFrame(id: 'f1', strokes: [
      AnimStroke(points: const [Offset(10, 10), Offset(60, 40), Offset(90, 20)], colorArgb: 0xFFE53935, width: 8),
      AnimStroke(points: const [Offset(20, 20), Offset(50, 25)], width: 12, erase: true),
    ]);

void main() {
  test('legacy strokes move into the frame artwork once', () {
    final doc = _doc();
    final frame = _legacyFrame();
    expect(FrameArt.isLegacy(frame), isTrue);
    final art = FrameArt.ensure(doc, frame);
    expect(frame.strokes, isEmpty);
    expect(art.layers.first.strokes.length, 2);
    expect(art.layers.first.strokes.first.colorArgb, 0xFFE53935);
    expect(art.layers.first.strokes.first.size, 8);
    expect(art.width, 320);
    expect(art.backgroundArgb, isNull);
    // Erasing stroke uses an erasing brush.
    final eraserKey = art.layers.first.strokes.last.brushKey;
    expect(art.brushes[eraserKey]!.erase, isTrue);
    // Idempotent.
    expect(identical(FrameArt.ensure(doc, frame), art), isTrue);
    expect(art.layers.first.strokes.length, 2);
  });

  test('artwork survives save and load', () {
    final doc = _doc();
    FrameArt.ensure(doc, doc.frames.first..strokes.add(AnimStroke(points: const [Offset(1, 1), Offset(5, 5)])));
    final json = jsonDecode(jsonEncode(doc.toJson()));
    final back = AnimationDocument.fromJson(json);
    expect(back.frames.first.art, isNotNull);
    expect(back.frames.first.art!.layers.first.strokes.length, 1);
    expect(back.frames.first.hasArt, isTrue);
    expect(back.toJson()['version'], 3);
  });

  test('version 2 animations (vector strokes only) still open and render input', () {
    final v2 = {
      'format': AnimationDocument.format,
      'version': 2,
      'w': 64,
      'h': 64,
      'fps': 12,
      'frames': [
        {
          'id': 'f1',
          'hold': 2,
          's': [
            {'p': [1, 1, 20, 20], 'c': 0xFF000000, 'w': 5}
          ]
        }
      ],
    };
    final doc = AnimationDocument.fromJson(v2);
    expect(doc.frames.first.strokes.length, 1);
    expect(doc.frames.first.art, isNull);
    expect(doc.frames.first.isBlank, isFalse);
  });

  test('duplicating a frame deep-copies its artwork', () {
    final doc = _doc();
    final first = doc.frames.first;
    FrameArt.ensure(doc, first..strokes.add(AnimStroke(points: const [Offset(1, 1), Offset(9, 9)])));
    final copy = doc.duplicateFrame(0);
    expect(identical(copy.art, first.art), isFalse);
    copy.art!.layers.first.strokes.clear();
    expect(first.art!.layers.first.strokes.length, 1);
  });

  test('a damaged artwork block is rejected instead of crashing', () {
    final bad = {
      'format': AnimationDocument.format,
      'version': 3,
      'w': 64,
      'h': 64,
      'fps': 12,
      'frames': [
        {'id': 'f1', 'hold': 1, 's': [], 'art': {'format': 'nope'}}
      ],
    };
    expect(() => AnimationDocument.fromJson(bad), throwsA(isA<AnimationException>()));
  });

  test('blank artwork does not count as content', () {
    final doc = _doc();
    FrameArt.ensure(doc, doc.frames.first);
    expect(doc.frames.first.isBlank, isTrue);
  });
}
