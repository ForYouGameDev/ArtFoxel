import 'dart:convert';
import 'dart:typed_data';

import 'package:artfoxel/core/io/sha256.dart';
import 'package:artfoxel/core/io/zip_codec.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('SHA-256 known vectors', () {
    expect(Sha256.hex(utf8.encode('abc')), 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
    expect(Sha256.hex(const []), 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
  });

  test('zip round trip, stored and deflated', () {
    final w = ZipWriter()
      ..add('a.txt', Uint8List.fromList(utf8.encode('hello hello hello hello')))
      ..add('dir/b.bin', Uint8List.fromList(List.generate(2000, (i) => i % 7)), compress: false);
    final r = ZipReader.parse(w.finish());
    expect(r.has('a.txt'), isTrue);
    expect(utf8.decode(r.read('a.txt')), 'hello hello hello hello');
    expect(r.read('dir/b.bin').length, 2000);
  });

  test('hostile names are rejected', () {
    expect(isSafeZipName('../evil'), isFalse);
    expect(isSafeZipName('/abs'), isFalse);
    expect(isSafeZipName('ok/file.json'), isTrue);
  });

  test('truncated and garbage zips throw ZipException', () {
    final good = (ZipWriter()..add('a', Uint8List.fromList([1, 2, 3]))).finish();
    expect(() => ZipReader.parse(Uint8List.sublistView(good, 0, good.length ~/ 2)), throwsA(isA<ZipException>()));
    expect(() => ZipReader.parse(Uint8List.fromList(List.filled(64, 7))), throwsA(isA<ZipException>()));
  });
}
