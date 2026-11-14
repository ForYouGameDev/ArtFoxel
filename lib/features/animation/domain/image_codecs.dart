import 'dart:io' show ZLibDecoder, ZLibEncoder;
import 'dart:typed_data';

class CodecException implements Exception {
  const CodecException(this.message);
  final String message;
  @override
  String toString() => message;
}

// ---------------------------------------------------------------------------
// PNG
// ---------------------------------------------------------------------------

abstract final class PngCodec {
  static final Uint32List _crcTable = () {
    final t = Uint32List(256);
    for (var n = 0; n < 256; n++) {
      var c = n;
      for (var k = 0; k < 8; k++) {
        c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
      }
      t[n] = c;
    }
    return t;
  }();

  static int crc32(List<int> data, [int start = 0, int? end]) {
    var c = 0xFFFFFFFF;
    for (var i = start; i < (end ?? data.length); i++) {
      c = _crcTable[(c ^ data[i]) & 0xFF] ^ (c >> 8);
    }
    return c ^ 0xFFFFFFFF;
  }

  static void _chunk(BytesBuilder out, String type, List<int> body) {
    final head = ByteData(4)..setUint32(0, body.length);
    out.add(head.buffer.asUint8List());
    final tb = [...type.codeUnits, ...body];
    out.add(tb);
    final crc = ByteData(4)..setUint32(0, crc32(tb));
    out.add(crc.buffer.asUint8List());
  }

  /// Encodes straight-alpha RGBA8 as an 8-bit RGBA PNG.
  static Uint8List encode(int width, int height, Uint8List rgba) {
    if (width <= 0 || height <= 0 || rgba.length != width * height * 4) {
      throw const CodecException('PNG input size does not match the pixel data.');
    }
    final out = BytesBuilder()..add(const [137, 80, 78, 71, 13, 10, 26, 10]);
    final ihdr = ByteData(13)
      ..setUint32(0, width)
      ..setUint32(4, height)
      ..setUint8(8, 8)
      ..setUint8(9, 6);
    _chunk(out, 'IHDR', ihdr.buffer.asUint8List());
    final raw = Uint8List(height * (width * 4 + 1));
    for (var y = 0; y < height; y++) {
      final o = y * (width * 4 + 1);
      raw[o] = 0; // filter: none
      raw.setRange(o + 1, o + 1 + width * 4, rgba, y * width * 4);
    }
    _chunk(out, 'IDAT', ZLibEncoder(level: 6).convert(raw));
    _chunk(out, 'IEND', const []);
    return out.toBytes();
  }

  /// Width/height from a PNG header, validating the signature and CRC of IHDR.
  static (int, int) readSize(Uint8List b) {
    if (b.length < 33 || !_sig(b)) throw const CodecException('Not a PNG file.');
    final d = ByteData.sublistView(b);
    if (d.getUint32(8) != 13 || String.fromCharCodes(b.sublist(12, 16)) != 'IHDR') throw const CodecException('PNG header missing.');
    if (crc32(b, 12, 29) != d.getUint32(29)) throw const CodecException('PNG header is corrupt.');
    return (d.getUint32(16), d.getUint32(20));
  }

  static bool _sig(Uint8List b) {
    const s = [137, 80, 78, 71, 13, 10, 26, 10];
    for (var i = 0; i < 8; i++) {
      if (b[i] != s[i]) return false;
    }
    return true;
  }

  /// Decodes PNGs written by [encode] (RGBA8, filter 0). Used to verify
  /// exported files.
  static Uint8List decodeRgba(Uint8List b) {
    final (w, h) = readSize(b);
    final d = ByteData.sublistView(b);
    final idat = BytesBuilder();
    var p = 8;
    while (p + 12 <= b.length) {
      final len = d.getUint32(p);
      final type = String.fromCharCodes(b.sublist(p + 4, p + 8));
      if (p + 12 + len > b.length) throw const CodecException('PNG is truncated.');
      if (crc32(b, p + 4, p + 8 + len) != d.getUint32(p + 8 + len)) throw CodecException('PNG chunk $type is corrupt.');
      if (type == 'IDAT') idat.add(b.sublist(p + 8, p + 8 + len));
      if (type == 'IEND') break;
      p += 12 + len;
    }
    final raw = Uint8List.fromList(ZLibDecoder().convert(idat.toBytes()));
    if (raw.length != h * (w * 4 + 1)) throw const CodecException('Unexpected PNG data size.');
    final out = Uint8List(w * h * 4);
    for (var y = 0; y < h; y++) {
      final o = y * (w * 4 + 1);
      if (raw[o] != 0) throw const CodecException('Only unfiltered PNG rows are supported here.');
      out.setRange(y * w * 4, (y + 1) * w * 4, raw, o + 1);
    }
    return out;
  }
}

// ---------------------------------------------------------------------------
// GIF
// ---------------------------------------------------------------------------

class GifFrameData {
  const GifFrameData(this.rgba, this.delayCs);
  final Uint8List rgba;

  /// Delay in hundredths of a second (clamped to at least 2: smaller values
  /// are treated as 10 by many viewers).
  final int delayCs;
}

class GifInfo {
  GifInfo(this.width, this.height, this.delaysCs, this.loops, this.firstFrameRgb, this.pixel0PerFrame);
  final int width, height;
  final List<int> delaysCs;
  final bool loops;

  /// RGB of the first frame, for verification.
  final Uint8List firstFrameRgb;

  /// RGB (0xRRGGBB) of the top-left pixel of every frame, in file order.
  final List<int> pixel0PerFrame;
  int get frameCount => delaysCs.length;
}

abstract final class GifCodec {
  /// Encodes opaque RGBA frames (all the same size) as an animated GIF89a
  /// with one global palette (<=256 colours, exact if the animation uses
  /// that few, otherwise median-cut). No dithering.
  static Uint8List encode(int width, int height, List<GifFrameData> frames, {bool loop = true}) {
    if (frames.isEmpty) throw const CodecException('A GIF needs at least one frame.');
    if (width <= 0 || height <= 0 || width > 65535 || height > 65535) throw const CodecException('Invalid GIF size.');
    for (final f in frames) {
      if (f.rgba.length != width * height * 4) throw const CodecException('A frame does not match the GIF size.');
    }
    final palette = buildPalette(frames.map((f) => f.rgba));
    final lookup = _Lookup(palette);
    var bits = 1;
    while ((1 << bits) < palette.length) {
      bits++;
    }
    final out = BytesBuilder()..add('GIF89a'.codeUnits);
    final lsd = ByteData(7)
      ..setUint16(0, width, Endian.little)
      ..setUint16(2, height, Endian.little)
      ..setUint8(4, 0x80 | 0x70 | (bits - 1))
      ..setUint8(5, 0)
      ..setUint8(6, 0);
    out.add(lsd.buffer.asUint8List());
    for (var i = 0; i < (1 << bits); i++) {
      if (i < palette.length) {
        out.add([(palette[i] >> 16) & 0xFF, (palette[i] >> 8) & 0xFF, palette[i] & 0xFF]);
      } else {
        out.add(const [0, 0, 0]);
      }
    }
    if (loop) out.add([0x21, 0xFF, 0x0B, ...'NETSCAPE2.0'.codeUnits, 0x03, 0x01, 0x00, 0x00, 0x00]);
    for (final f in frames) {
      final delay = f.delayCs < 2 ? 2 : (f.delayCs > 65535 ? 65535 : f.delayCs);
      out.add([0x21, 0xF9, 0x04, 0x04, delay & 0xFF, delay >> 8, 0x00, 0x00]);
      final desc = ByteData(10)
        ..setUint8(0, 0x2C)
        ..setUint16(1, 0, Endian.little)
        ..setUint16(3, 0, Endian.little)
        ..setUint16(5, width, Endian.little)
        ..setUint16(7, height, Endian.little)
        ..setUint8(9, 0);
      out.add(desc.buffer.asUint8List());
      final idx = Uint8List(width * height);
      for (var i = 0, p = 0; i < idx.length; i++, p += 4) {
        idx[i] = lookup.nearest(f.rgba[p], f.rgba[p + 1], f.rgba[p + 2]);
      }
      final minCode = bits < 2 ? 2 : bits;
      out.addByte(minCode);
      final data = _lzwEncode(idx, minCode);
      for (var p = 0; p < data.length; p += 255) {
        final n = p + 255 > data.length ? data.length - p : 255;
        out.addByte(n);
        out.add(data.sublist(p, p + n));
      }
      out.addByte(0);
    }
    out.addByte(0x3B);
    return out.toBytes();
  }

  /// Palette (as 0xRRGGBB ints). Exact when <=256 distinct colours.
  static List<int> buildPalette(Iterable<Uint8List> images) {
    final exact = <int>{};
    final hist = <int, int>{}; // 5-bit-per-channel bins -> count
    var overflow = false;
    for (final img in images) {
      for (var i = 0; i < img.length; i += 4) {
        final c = (img[i] << 16) | (img[i + 1] << 8) | img[i + 2];
        if (!overflow) {
          exact.add(c);
          if (exact.length > 256) overflow = true;
        }
        final bin = ((img[i] >> 3) << 10) | ((img[i + 1] >> 3) << 5) | (img[i + 2] >> 3);
        hist[bin] = (hist[bin] ?? 0) + 1;
      }
      if (overflow && hist.length > 30000) break;
    }
    if (!overflow) return exact.toList()..sort();
    // Median cut over the histogram bins.
    var boxes = <List<MapEntry<int, int>>>[hist.entries.toList()];
    int chan(int bin, int c) => c == 0 ? (bin >> 10) & 31 : c == 1 ? (bin >> 5) & 31 : bin & 31;
    while (boxes.length < 256) {
      var bi = -1, best = 0;
      for (var i = 0; i < boxes.length; i++) {
        if (boxes[i].length > 1 && boxes[i].length > best) {
          best = boxes[i].length;
          bi = i;
        }
      }
      if (bi < 0) break;
      final box = boxes[bi];
      var bc = 0, br = -1;
      for (var c = 0; c < 3; c++) {
        var lo = 31, hi = 0;
        for (final e in box) {
          final v = chan(e.key, c);
          if (v < lo) lo = v;
          if (v > hi) hi = v;
        }
        if (hi - lo > br) {
          br = hi - lo;
          bc = c;
        }
      }
      box.sort((a, b) => chan(a.key, bc).compareTo(chan(b.key, bc)));
      final total = box.fold<int>(0, (s, e) => s + e.value);
      var acc = 0, cut = 1;
      for (var i = 0; i < box.length; i++) {
        acc += box[i].value;
        if (acc * 2 >= total) {
          cut = (i + 1).clamp(1, box.length - 1);
          break;
        }
      }
      boxes = [...boxes]..removeAt(bi);
      boxes..add(box.sublist(0, cut))..add(box.sublist(cut));
    }
    return [
      for (final box in boxes)
        () {
          var r = 0.0, g = 0.0, b = 0.0, n = 0.0;
          for (final e in box) {
            r += chan(e.key, 0) * e.value;
            g += chan(e.key, 1) * e.value;
            b += chan(e.key, 2) * e.value;
            n += e.value;
          }
          int ch(double s) => ((s / n) * 8 + 4).round().clamp(0, 255);
          return (ch(r) << 16) | (ch(g) << 8) | ch(b);
        }()
    ];
  }

  static Uint8List _lzwEncode(Uint8List idx, int minCode) {
    final clear = 1 << minCode, eoi = clear + 1;
    final out = BytesBuilder();
    var cur = 0, curBits = 0;
    void emit(int code, int size) {
      cur |= code << curBits;
      curBits += size;
      while (curBits >= 8) {
        out.addByte(cur & 0xFF);
        cur >>= 8;
        curBits -= 8;
      }
    }

    var size = minCode + 1;
    var next = eoi + 1;
    var dict = <int, int>{};
    emit(clear, size);
    var prefix = idx[0];
    for (var i = 1; i < idx.length; i++) {
      final k = idx[i];
      final key = (prefix << 8) | k;
      final hit = dict[key];
      if (hit != null) {
        prefix = hit;
        continue;
      }
      emit(prefix, size);
      if (next < 4096) {
        dict[key] = next++;
        if (next > (1 << size) && size < 12) size++;
      } else {
        emit(clear, size);
        dict = {};
        size = minCode + 1;
        next = eoi + 1;
      }
      prefix = k;
    }
    emit(prefix, size);
    emit(eoi, size);
    if (curBits > 0) out.addByte(cur & 0xFF);
    return out.toBytes();
  }

  /// Parses a GIF produced by [encode] (single image per frame, global
  /// palette) and reports its real size, delays and first frame pixels.
  static GifInfo inspect(Uint8List b) {
    if (b.length < 14 || String.fromCharCodes(b.sublist(0, 6)) != 'GIF89a') throw const CodecException('Not a GIF89a file.');
    final d = ByteData.sublistView(b);
    final w = d.getUint16(6, Endian.little), h = d.getUint16(8, Endian.little);
    final packed = d.getUint8(10);
    var p = 13;
    final palette = <int>[];
    if ((packed & 0x80) != 0) {
      final n = 1 << ((packed & 7) + 1);
      for (var i = 0; i < n; i++) {
        palette.add((b[p] << 16) | (b[p + 1] << 8) | b[p + 2]);
        p += 3;
      }
    }
    final delays = <int>[];
    var loops = false;
    Uint8List? first;
    final pixel0 = <int>[];
    while (p < b.length) {
      final t = b[p++];
      if (t == 0x3B) break;
      if (t == 0x21) {
        final label = b[p++];
        if (label == 0xF9) {
          delays.add(d.getUint16(p + 2, Endian.little));
        } else if (label == 0xFF && String.fromCharCodes(b.sublist(p + 1, p + 12)) == 'NETSCAPE2.0') {
          loops = true;
        }
        while (b[p] != 0) {
          p += b[p] + 1;
        }
        p++;
      } else if (t == 0x2C) {
        final fw = d.getUint16(p + 4, Endian.little), fh = d.getUint16(p + 6, Endian.little);
        p += 9;
        final minCode = b[p++];
        final data = BytesBuilder();
        while (b[p] != 0) {
          data.add(b.sublist(p + 1, p + 1 + b[p]));
          p += b[p] + 1;
        }
        p++;
        final idx = _lzwDecode(data.toBytes(), minCode, fw * fh);
        pixel0.add(idx.isEmpty ? 0 : palette[idx[0]]);
        if (first == null) {
          first = Uint8List(fw * fh * 3);
          for (var i = 0; i < idx.length; i++) {
            final c = palette[idx[i]];
            first[i * 3] = (c >> 16) & 0xFF;
            first[i * 3 + 1] = (c >> 8) & 0xFF;
            first[i * 3 + 2] = c & 0xFF;
          }
        }
      } else {
        throw const CodecException('Unexpected GIF block.');
      }
    }
    if (first == null) throw const CodecException('The GIF has no frames.');
    return GifInfo(w, h, delays, loops, first, pixel0);
  }

  static Uint8List _lzwDecode(Uint8List data, int minCode, int count) {
    final clear = 1 << minCode, eoi = clear + 1;
    final out = Uint8List(count);
    var o = 0, size = minCode + 1, next = eoi + 1;
    final prefix = List<int>.filled(4096, 0), suffix = List<int>.filled(4096, 0);
    int? prev;
    var bitPos = 0;
    List<int> expand(int code) {
      final s = <int>[];
      var c = code;
      while (c >= clear + 2) {
        s.add(suffix[c]);
        c = prefix[c];
      }
      s.add(c);
      return s.reversed.toList();
    }

    while (o < count) {
      if (bitPos + size > data.length * 8) break;
      var code = 0;
      for (var i = 0; i < size; i++) {
        code |= ((data[(bitPos + i) >> 3] >> ((bitPos + i) & 7)) & 1) << i;
      }
      bitPos += size;
      if (code == clear) {
        size = minCode + 1;
        next = eoi + 1;
        prev = null;
        continue;
      }
      if (code == eoi) break;
      List<int> entry;
      if (prev == null) {
        entry = [code];
      } else if (code < next) {
        entry = expand(code);
        if (next < 4096) {
          prefix[next] = prev;
          suffix[next] = entry.first;
          next++;
        }
      } else {
        final pe = expand(prev);
        entry = [...pe, pe.first];
        if (next < 4096) {
          prefix[next] = prev;
          suffix[next] = pe.first;
          next++;
        }
      }
      for (final v in entry) {
        if (o < count) out[o++] = v;
      }
      if (next >= (1 << size) && size < 12) size++;
      prev = code;
    }
    return out;
  }
}

class _Lookup {
  _Lookup(this.palette) {
    _r = Uint8List(palette.length);
    _g = Uint8List(palette.length);
    _b = Uint8List(palette.length);
    for (var i = 0; i < palette.length; i++) {
      _r[i] = (palette[i] >> 16) & 0xFF;
      _g[i] = (palette[i] >> 8) & 0xFF;
      _b[i] = palette[i] & 0xFF;
    }
  }
  final List<int> palette;
  late final Uint8List _r, _g, _b;
  final Map<int, int> _cache = {};

  int nearest(int r, int g, int b) {
    final key = (r << 16) | (g << 8) | b;
    final c = _cache[key];
    if (c != null) return c;
    var best = 0, bd = 1 << 30;
    for (var i = 0; i < palette.length; i++) {
      final dr = _r[i] - r, dg = _g[i] - g, db = _b[i] - b;
      final d = dr * dr + dg * dg + db * db;
      if (d < bd) {
        bd = d;
        best = i;
        if (d == 0) break;
      }
    }
    return _cache[key] = best;
  }
}
