import 'dart:convert';
import 'dart:typed_data';

import 'package:artfoxel/features/animation/application/animation_image_import.dart';
import 'package:artfoxel/features/animation/domain/animation_model.dart';
import 'package:artfoxel/features/imaging/domain/import_rules.dart';
import 'package:flutter_test/flutter_test.dart';

PreparedAnimImage _p(String n) => PreparedAnimImage(n, 100, 50, Uint8List(0), const []);

void main() {
  test('v2 document round trips images, layers, references', () {
    final d = AnimationDocument(width: 200, height: 100);
    AnimationImageImport.commit(d, _p('bg'), AnimImportMode.background, frameIndex: 0);
    AnimationImageImport.commit(d, _p('hero'), AnimImportMode.character, frameIndex: 0);
    AnimationImageImport.commit(d, _p('ref'), AnimImportMode.reference, frameIndex: 0);
    AnimationImageImport.commit(d, _p('f'), AnimImportMode.frameContent, frameIndex: 0);
    final back = AnimationDocument.fromJson(jsonDecode(jsonEncode(d.toJson())));
    expect(back.assets.length, 4);
    expect(back.backgroundImage, isNotNull);
    expect(back.layers.single.role, 'character');
    expect(back.references.single.opacity, 0.5);
    expect(back.frames[0].images.length, 1);
  });

  test('v1 documents (no images) still open', () {
    final v1 = {'format': AnimationDocument.format, 'version': 1, 'w': 64, 'h': 64, 'fps': 12, 'frames': [{'id': 'f1', 'hold': 1, 's': []}]};
    expect(AnimationDocument.fromJson(v1).frames.length, 1);
  });

  test('image sequence creates consecutive frames in order', () {
    final d = AnimationDocument(width: 200, height: 100);
    AnimationImageImport.commitSequence(d, [_p('a'), _p('b'), _p('c')], afterIndex: 0);
    expect(d.frames.length, 4);
    expect(d.frames[1].images.length, 1);
    expect(d.assets.values.map((a) => a.name), ['a', 'b', 'c']);
  });

  test('sequence over the frame limit is refused without partial frames', () {
    final d = AnimationDocument(width: 200, height: 100);
    final many = [for (var i = 0; i < AnimationDocument.maxFrames; i++) _p('x$i')];
    expect(() => AnimationImageImport.commitSequence(d, many, afterIndex: 0), throwsA(isA<AnimationException>()));
    expect(d.frames.length, 1);
  });

  test('references are not part of used-by-export layers and unused assets prune', () {
    final d = AnimationDocument(width: 200, height: 100);
    AnimationImageImport.commit(d, _p('ref'), AnimImportMode.reference, frameIndex: 0);
    d.references.clear();
    expect(d.pruneAssets(), ['img1']);
  });

  test('natural sort helper', () {
    expect(AnimationImageImport.sortNatural(['f10', 'f2', 'f1'], (s) => s), ['f1', 'f2', 'f10']);
  });
}
