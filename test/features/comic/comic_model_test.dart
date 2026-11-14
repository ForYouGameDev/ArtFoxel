import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:artfoxel/features/comic/domain/comic_model.dart';

Uint8List _font({int fsType = 0, String family = 'TestFont'}) {
  final units = <int>[for (final c in family.codeUnits) ...[0, c]];
  final b = BytesBuilder();
  final head = ByteData(12 + 32);
  head.setUint32(0, 0x00010000);
  head.setUint16(4, 2);
  // OS/2 table record
  var r = 12;
  for (final (i, c) in 'OS/2'.codeUnits.indexed) {
    head.setUint8(r + i, c);
  }
  head.setUint32(r + 8, 44);
  head.setUint32(r + 12, 12);
  r = 28;
  for (final (i, c) in 'name'.codeUnits.indexed) {
    head.setUint8(r + i, c);
  }
  head.setUint32(r + 8, 56);
  head.setUint32(r + 12, 18 + units.length);
  b.add(head.buffer.asUint8List());
  final os2 = ByteData(12)..setUint16(8, fsType);
  b.add(os2.buffer.asUint8List());
  final name = ByteData(18)
    ..setUint16(0, 0)
    ..setUint16(2, 1)
    ..setUint16(4, 18)
    ..setUint16(6, 3)
    ..setUint16(8, 1)
    ..setUint16(10, 0x409)
    ..setUint16(12, 1)
    ..setUint16(14, units.length)
    ..setUint16(16, 0);
  b.add(name.buffer.asUint8List());
  b.add(units);
  return b.toBytes();
}

void main() {
  group('page spec', () {
    test('presets validate', () {
      expect(ComicPageSpec.b5Manga().validate(), isEmpty);
      expect(ComicPageSpec.webtoon().validate(), isEmpty);
    });
    test('bad specs are reported', () {
      expect(const ComicPageSpec(widthPx: 10, heightPx: 10).validate(), isNotEmpty);
      expect(const ComicPageSpec(widthPx: 1000, heightPx: 1000, dpi: 10).validate(), isNotEmpty);
      expect(const ComicPageSpec(widthPx: 1000, heightPx: 1000, marginPx: 600).validate(), isNotEmpty);
    });
  });

  group('panels', () {
    test('every template instantiates inside the area', () {
      const area = Rect.fromLTWH(0, 0, 1000, 1400);
      for (final t in PanelTemplate.builtIn) {
        final ps = t.instantiate(area);
        expect(ps, isNotEmpty, reason: t.id);
        for (final p in ps) {
          for (final c in p.corners) {
            expect(area.inflate(1).contains(c), isTrue, reason: '${t.id} ${p.id}');
          }
        }
      }
    });
    test('panel needs 3..12 corners', () {
      expect(() => Panel(id: 'a', corners: const [Offset.zero, Offset(1, 0)]), throwsA(isA<ComicException>()));
    });
    test('moveCorner and JSON round trip', () {
      final p = Panel(id: 'a', corners: const [Offset(0, 0), Offset(100, 0), Offset(100, 100), Offset(0, 100)]);
      final m = p.moveCorner(2, const Offset(120, 130));
      expect(m.corners[2], const Offset(120, 130));
      expect(Panel.fromJson(jsonDecode(jsonEncode(m.toJson()))).corners, m.corners);
      expect(() => p.moveCorner(9, Offset.zero), throwsA(isA<ComicException>()));
    });
  });

  group('document', () {
    test('create, JSON round trip, page ops', () {
      final doc = ComicDocument.create(title: 'T', pages: 3, template: PanelTemplate.builtIn.first);
      expect(doc.pages.length, 3);
      doc.duplicatePage(doc.pages.first.id);
      expect(doc.pages.length, 4);
      doc.movePage(0, 3);
      doc.removePage(doc.pages.last.id);
      final back = ComicDocument.fromJson(jsonDecode(jsonEncode(doc.toJson())));
      expect(back.pages.length, doc.pages.length);
      expect(back.pages.map((p) => p.id), doc.pages.map((p) => p.id));
      expect(back.direction, doc.direction);
    });
    test('cannot remove last page', () {
      final doc = ComicDocument.create(title: 'T');
      expect(() => doc.removePage(doc.pages.first.id), throwsA(isA<ComicException>()));
    });
    test('rejects other formats and newer versions', () {
      expect(() => ComicDocument.fromJson({'format': 'nope'}), throwsA(isA<ComicException>()));
      final j = ComicDocument.create(title: 'T').toJson()..['version'] = 99;
      expect(() => ComicDocument.fromJson(j), throwsA(isA<ComicException>()));
    });
  });

  group('text spec', () {
    test('JSON round trip keeps everything editable', () {
      const t = TextSpec(text: 'Hello', family: 'Foo', size: 33, weight: 700, italic: true, letterSpacing: 2,
          outlineWidth: 3, shadowDx: 2, shadowDy: 2, vertical: true);
      final back = TextSpec.fromJson(jsonDecode(jsonEncode(t.toJson())));
      expect(back, t);
    });
  });

  group('font import validation', () {
    test('valid synthetic font passes only with acknowledgement', () {
      final f = _font();
      final info = FontImportValidator.validate(f, licenceAcknowledged: true);
      expect(info.family, 'TestFont');
      expect(() => FontImportValidator.validate(f, licenceAcknowledged: false),
          throwsA(isA<FontImportException>()));
    });
    test('restricted fsType is refused', () {
      expect(() => FontImportValidator.validate(_font(fsType: 0x0002), licenceAcknowledged: true),
          throwsA(isA<FontImportException>()));
    });
    test('WOFF, garbage and tiny files are refused', () {
      final woff = Uint8List(64)..buffer.asByteData().setUint32(0, 0x774F4646);
      expect(() => FontImportValidator.inspect(woff), throwsA(isA<FontImportException>()));
      expect(() => FontImportValidator.inspect(Uint8List(4)), throwsA(isA<FontImportException>()));
      expect(() => FontImportValidator.inspect(Uint8List(64)), throwsA(isA<FontImportException>()));
    });
    test('out-of-range table is refused', () {
      final f = _font();
      ByteData.sublistView(f).setUint32(12 + 12, 9999); // OS/2 length
      expect(() => FontImportValidator.inspect(f), throwsA(isA<FontImportException>()));
    });
  });
}
