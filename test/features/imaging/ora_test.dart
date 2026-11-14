import 'dart:convert';
import 'dart:typed_data';

import 'package:artfoxel/core/io/zip_codec.dart';
import 'package:artfoxel/features/imaging/domain/ora_writer.dart';
import 'package:artfoxel/features/studio/domain/layer_blend.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('ORA is a zip with mimetype first, stack.xml and layer PNGs', () {
    final png = Uint8List.fromList([137, 80, 78, 71]);
    final bytes = OraWriter.build(
      width: 10,
      height: 10,
      nodes: [OraNode.layer(name: 'Ink <&>', png: png, opacity: 0.5, visible: true, blend: LayerBlend.multiply)],
      mergedPng: png,
    );
    final z = ZipReader.parse(bytes);
    expect(z.entries.first.name, 'mimetype');
    expect(utf8.decode(z.read('mimetype')), 'image/openraster');
    final xml = utf8.decode(z.read('stack.xml'));
    expect(xml, contains('svg:multiply'));
    expect(xml, contains('Ink &lt;&amp;&gt;'));
    expect(z.has('mergedimage.png'), isTrue);
  });
}
