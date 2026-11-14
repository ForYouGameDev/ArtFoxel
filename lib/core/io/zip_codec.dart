import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Minimal ZIP reader/writer (store + deflate, no ZIP64, no encryption) so
/// `.artfoxel`, `.ora` and backup files are ordinary archives that any
/// unzip tool can open. The reader is defensive: bounds-checked, size-capped
/// and it refuses path traversal names.
class ZipException implements Exception {
  const ZipException(this.message);
  final String message;
  @override
  String toString() => message;
}

final List<int> _crcTable = () {
  final t = List<int>.filled(256, 0);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
    t[n] = c;
  }
  return t;
}();

int zipCrc32(List<int> data) {
  var c = 0xFFFFFFFF;
  for (final b in data) {
    c = _crcTable[(c ^ b) & 0xFF] ^ (c >> 8);
  }
  return c ^ 0xFFFFFFFF;
}

bool isSafeZipName(String name) {
  if (name.isEmpty || name.length > 240) return false;
  if (name.startsWith('/') || name.startsWith('\\') || name.contains('\\')) return false;
  if (name.contains('\u0000') || RegExp(r'^[A-Za-z]:').hasMatch(name)) return false;
  for (final part in name.split('/')) {
    if (part == '..' || part == '.') return false;
  }
  return true;
}

class ZipWriter {
  final BytesBuilder _out = BytesBuilder(copy: false);
  final List<_CentralEntry> _central = [];
  final Set<String> _names = {};

  /// [compress] false stores the bytes (use for PNG/JPEG which don't shrink,
  /// and for the OpenRaster `mimetype` entry which must be stored).
  void add(String name, List<int> data, {bool compress = true, DateTime? time}) {
    if (!isSafeZipName(name)) throw ZipException('Unsafe entry name "$name".');
    if (!_names.add(name)) throw ZipException('Duplicate entry "$name".');
    final bytes = data is Uint8List ? data : Uint8List.fromList(data);
    final crc = zipCrc32(bytes);
    var method = 0;
    Uint8List body = bytes;
    if (compress && bytes.length > 64) {
      final d = Uint8List.fromList(ZLibEncoder(raw: true, level: 6).convert(bytes));
      if (d.length < bytes.length) {
        method = 8;
        body = d;
      }
    }
    final nameBytes = utf8.encode(name);
    final t = time ?? DateTime.utc(2026, 1, 1);
    final dosTime = (t.hour << 11) | (t.minute << 5) | (t.second ~/ 2);
    final dosDate = (((t.year - 1980).clamp(0, 127)) << 9) | (t.month << 5) | t.day;
    final offset = _out.length;
    final h = ByteData(30)
      ..setUint32(0, 0x04034b50, Endian.little)
      ..setUint16(4, 20, Endian.little)
      ..setUint16(6, 0x0800, Endian.little) // UTF-8 names
      ..setUint16(8, method, Endian.little)
      ..setUint16(10, dosTime, Endian.little)
      ..setUint16(12, dosDate, Endian.little)
      ..setUint32(14, crc, Endian.little)
      ..setUint32(18, body.length, Endian.little)
      ..setUint32(22, bytes.length, Endian.little)
      ..setUint16(26, nameBytes.length, Endian.little)
      ..setUint16(28, 0, Endian.little);
    _out
      ..add(h.buffer.asUint8List())
      ..add(nameBytes)
      ..add(body);
    _central.add(_CentralEntry(nameBytes, method, dosTime, dosDate, crc, body.length, bytes.length, offset));
  }

  Uint8List finish() {
    final cdStart = _out.length;
    for (final e in _central) {
      final h = ByteData(46)
        ..setUint32(0, 0x02014b50, Endian.little)
        ..setUint16(4, 20, Endian.little)
        ..setUint16(6, 20, Endian.little)
        ..setUint16(8, 0x0800, Endian.little)
        ..setUint16(10, e.method, Endian.little)
        ..setUint16(12, e.time, Endian.little)
        ..setUint16(14, e.date, Endian.little)
        ..setUint32(16, e.crc, Endian.little)
        ..setUint32(20, e.compSize, Endian.little)
        ..setUint32(24, e.size, Endian.little)
        ..setUint16(28, e.name.length, Endian.little)
        ..setUint32(42, e.offset, Endian.little);
      _out
        ..add(h.buffer.asUint8List())
        ..add(e.name);
    }
    final cdSize = _out.length - cdStart;
    final end = ByteData(22)
      ..setUint32(0, 0x06054b50, Endian.little)
      ..setUint16(8, _central.length, Endian.little)
      ..setUint16(10, _central.length, Endian.little)
      ..setUint32(12, cdSize, Endian.little)
      ..setUint32(16, cdStart, Endian.little);
    _out.add(end.buffer.asUint8List());
    return _out.toBytes();
  }
}

class _CentralEntry {
  _CentralEntry(this.name, this.method, this.time, this.date, this.crc, this.compSize, this.size, this.offset);
  final List<int> name;
  final int method, time, date, crc, compSize, size, offset;
}

class ZipEntryInfo {
  const ZipEntryInfo(this.name, this.size);
  final String name;
  final int size;
}

class ZipReader {
  ZipReader._(this._bytes, this._entries);
  final Uint8List _bytes;
  final Map<String, _ReadEntry> _entries;

  static const maxEntries = 5000;
  static const maxEntryBytes = 256 * 1024 * 1024;
  static const maxTotalBytes = 1024 * 1024 * 1024;

  List<ZipEntryInfo> get entries =>
      [for (final e in _entries.values) ZipEntryInfo(e.name, e.size)];
  bool has(String name) => _entries.containsKey(name);

  static ZipReader parse(Uint8List b) {
    if (b.length < 22) throw const ZipException('File is too small to be a ZIP archive.');
    final d = ByteData.sublistView(b);
    // End of central directory: scan back (comment up to 65535 bytes).
    var eocd = -1;
    for (var i = b.length - 22; i >= 0 && i >= b.length - 22 - 65535; i--) {
      if (d.getUint32(i, Endian.little) == 0x06054b50) {
        eocd = i;
        break;
      }
    }
    if (eocd < 0) throw const ZipException('Not a ZIP archive (no directory found).');
    final count = d.getUint16(eocd + 10, Endian.little);
    final cdSize = d.getUint32(eocd + 12, Endian.little);
    final cdOff = d.getUint32(eocd + 16, Endian.little);
    if (count > maxEntries) throw const ZipException('Too many entries in archive.');
    if (cdOff + cdSize > eocd) throw const ZipException('Archive directory is damaged.');
    final entries = <String, _ReadEntry>{};
    var p = cdOff;
    var total = 0;
    for (var i = 0; i < count; i++) {
      if (p + 46 > b.length || d.getUint32(p, Endian.little) != 0x02014b50) {
        throw const ZipException('Archive directory is damaged.');
      }
      final flags = d.getUint16(p + 8, Endian.little);
      final method = d.getUint16(p + 10, Endian.little);
      final crc = d.getUint32(p + 16, Endian.little);
      final comp = d.getUint32(p + 20, Endian.little);
      final size = d.getUint32(p + 24, Endian.little);
      final nl = d.getUint16(p + 28, Endian.little);
      final el = d.getUint16(p + 30, Endian.little);
      final cl = d.getUint16(p + 32, Endian.little);
      final lho = d.getUint32(p + 42, Endian.little);
      if (p + 46 + nl > b.length) throw const ZipException('Archive directory is damaged.');
      if (flags & 1 != 0) throw const ZipException('Encrypted archives are not supported.');
      final name = utf8.decode(b.sublist(p + 46, p + 46 + nl), allowMalformed: false);
      if (!isSafeZipName(name) && !name.endsWith('/')) {
        throw ZipException('Archive contains an unsafe entry name.');
      }
      p += 46 + nl + el + cl;
      if (name.endsWith('/')) continue; // directory
      if (method != 0 && method != 8) throw const ZipException('Unsupported compression method.');
      if (size > maxEntryBytes) throw const ZipException('An entry is too large.');
      total += size;
      if (total > maxTotalBytes) throw const ZipException('Archive is too large when unpacked.');
      if (entries.containsKey(name)) throw const ZipException('Archive has duplicate entries.');
      entries[name] = _ReadEntry(name, method, crc, comp, size, lho);
    }
    return ZipReader._(b, entries);
  }

  /// Returns the entry bytes, verifying size and CRC-32.
  Uint8List read(String name) {
    final e = _entries[name];
    if (e == null) throw ZipException('Missing entry "$name".');
    final d = ByteData.sublistView(_bytes);
    final o = e.localOffset;
    if (o + 30 > _bytes.length || d.getUint32(o, Endian.little) != 0x04034b50) {
      throw ZipException('Entry "$name" is damaged.');
    }
    final nl = d.getUint16(o + 26, Endian.little), el = d.getUint16(o + 28, Endian.little);
    final start = o + 30 + nl + el;
    if (start + e.compSize > _bytes.length) throw ZipException('Entry "$name" is truncated.');
    final raw = Uint8List.sublistView(_bytes, start, start + e.compSize);
    Uint8List out;
    if (e.method == 0) {
      out = Uint8List.fromList(raw);
    } else {
      try {
        out = Uint8List.fromList(ZLibDecoder(raw: true).convert(raw));
      } on Object {
        throw ZipException('Entry "$name" is damaged.');
      }
    }
    if (out.length != e.size) throw ZipException('Entry "$name" has the wrong size.');
    if (zipCrc32(out) != e.crc) throw ZipException('Entry "$name" failed its checksum.');
    return out;
  }
}

class _ReadEntry {
  _ReadEntry(this.name, this.method, this.crc, this.compSize, this.size, this.localOffset);
  final String name;
  final int method, crc, compSize, size, localOffset;
}
