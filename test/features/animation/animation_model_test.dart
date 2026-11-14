import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:artfoxel/features/animation/domain/animation_model.dart';
import 'package:artfoxel/features/animation/domain/image_codecs.dart';

Uint8List _solid(int w, int h, int r, int g, int b, [int a = 255]) {
  final u = Uint8List(w * h * 4);
  for (var i = 0; i < w * h; i++) {
    u[i * 4] = r;
    u[i * 4 + 1] = g;
    u[i * 4 + 2] = b;
    u[i * 4 + 3] = a;
  }
  return u;
}

void main() {
  group('animation model', () {
    AnimationDocument doc3() {
      final d = AnimationDocument(width: 64, height: 64, fps: 10);
      d.addFrame();
      d.addFrame();
      return d;
    }

    test('frame ops keep ids unique', () {
      final d = doc3();
      d.duplicateFrame(0);
      d.moveFrame(0, 3);
      d.deleteFrame(1);
      expect(d.frames.map((f) => f.id).toSet().length, d.frames.length);
    });
    test('frameAt honours fps, hold, loop and range', () {
      final d = doc3();
      d.setHold(1, 2); // ticks: f0, f1, f1, f2
      expect(d.totalTicks, 4);
      Duration t(int tick) => Duration(milliseconds: tick * 100 + 1);
      expect([for (var i = 0; i < 4; i++) d.frameAt(t(i))], [0, 1, 1, 2]);
      expect(d.frameAt(t(4)), 0); // loops
      d.loop = false;
      expect(d.frameAt(t(4)), isNull);
      d.loop = true;
      d.setRange(1, 2);
      expect(d.frameAt(t(0)), 1);
      expect(d.frameAt(t(3)), 2);
    });
    test('tickSequence repeats held frames', () {
      final d = doc3();
      d.setHold(0, 3);
      expect(d.tickSequence(), [0, 0, 0, 1, 2]);
    });
    test('JSON round trip preserves strokes and holds', () {
      final d = doc3();
      d.frames[1].strokes.add(AnimStroke(points: const [Offset(1, 2), Offset(10, 20)], colorArgb: 0xFFFF0000, width: 8));
      d.setHold(2, 4);
      final back = AnimationDocument.fromJson(jsonDecode(jsonEncode(d.toJson())));
      expect(back.frames.length, 3);
      expect(back.frames[1].strokes.single.points.length, 2);
      expect(back.frames[2].hold, 4);
      expect(back.fps, 10);
    });
    test('invalid settings rejected', () {
      expect(() => AnimationDocument(width: 4, height: 4), throwsA(isA<AnimationException>()));
      expect(() => AnimationDocument(width: 64, height: 64, fps: 0), throwsA(isA<AnimationException>()));
    });
    test('onion ghosts never include the current frame', () {
      const o = OnionSkin();
      final g = o.ghosts(2, 5);
      expect(g.any((e) => e.$1 == 2), isFalse);
      expect(g.every((e) => e.$1 >= 0 && e.$1 < 5), isTrue);
    });
    test('BudgetCache evicts least recently used within budget', () {
      final c = BudgetCache<int, String>(10);
      c.put(1, 'a', 4);
      c.put(2, 'b', 4);
      c.get(1);
      c.put(3, 'c', 4);
      expect(c.get(2), isNull);
      expect(c.get(1), 'a');
    });
  });

  group('codecs', () {
    test('PNG round trip', () {
      final px = Uint8List.fromList([for (var i = 0; i < 4 * 3 * 4; i++) (i * 7) % 256]);
      final png = PngCodec.encode(4, 3, px);
      expect(PngCodec.readSize(png), (4, 3));
      expect(PngCodec.decodeRgba(png), px);
    });
    test('PNG corruption is detected', () {
      final png = PngCodec.encode(2, 2, _solid(2, 2, 1, 2, 3));
      png[png.length - 20] ^= 0xFF;
      expect(() => PngCodec.decodeRgba(png), throwsA(isA<CodecException>()));
    });
    test('GIF: size, delays, loop flag, order', () {
      final frames = [
        GifFrameData(_solid(8, 6, 255, 0, 0), 10),
        GifFrameData(_solid(8, 6, 0, 255, 0), 20),
        GifFrameData(_solid(8, 6, 0, 0, 255), 5),
      ];
      final gif = GifCodec.encode(8, 6, frames, loop: true);
      final info = GifCodec.inspect(gif);
      expect((info.width, info.height), (8, 6));
      expect(info.delaysCs, [10, 20, 5]);
      expect(info.loops, isTrue);
      expect(info.pixel0PerFrame.toSet().length, 3, reason: 'frames are distinct and ordered');
      expect(info.pixel0PerFrame[0], isNot(info.pixel0PerFrame[1]));
    });
    test('GIF: non-looping flag and minimum delay', () {
      final gif = GifCodec.encode(8, 8, [GifFrameData(_solid(8, 8, 9, 9, 9), 0)], loop: false);
      final info = GifCodec.inspect(gif);
      expect(info.loops, isFalse);
      expect(info.delaysCs.single, 2);
    });
    test('GIF with more than 256 colours still encodes', () {
      final w = 32, h = 32;
      final px = Uint8List(w * h * 4);
      for (var i = 0; i < w * h; i++) {
        px[i * 4] = (i * 5) % 256;
        px[i * 4 + 1] = (i * 11) % 256;
        px[i * 4 + 2] = (i * 17) % 256;
        px[i * 4 + 3] = 255;
      }
      final info = GifCodec.inspect(GifCodec.encode(w, h, [GifFrameData(px, 10)]));
      expect((info.width, info.height), (32, 32));
    });
    test('GIF size mismatch refused', () {
      expect(() => GifCodec.encode(8, 8, [GifFrameData(Uint8List(10), 5)]), throwsA(isA<CodecException>()));
    });
  });
}
