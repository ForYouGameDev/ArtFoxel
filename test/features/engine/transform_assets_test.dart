import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:artfoxel/features/studio/engine/asset_exchange.dart';
import 'package:artfoxel/features/studio/engine/checkpoints.dart';
import 'package:artfoxel/features/studio/engine/color_management.dart';
import 'package:artfoxel/features/studio/engine/guides_selection.dart';
import 'package:artfoxel/features/studio/engine/performance.dart';
import 'package:artfoxel/features/studio/engine/reference_3d.dart';
import 'package:artfoxel/features/studio/engine/transform_engine.dart';
import 'package:artfoxel/features/studio/engine/vector_paths.dart';

Uint8List _rgba(int w, int h, int Function(int x, int y) f) {
  final u = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final c = f(x, y), i = (y * w + x) * 4;
      u[i] = (c >> 16) & 255;
      u[i + 1] = (c >> 8) & 255;
      u[i + 2] = c & 255;
      u[i + 3] = (c >> 24) & 255;
    }
  }
  return u;
}

Map<String, Object?> _item({String kind = 'palette', Map<String, Object?>? data, String license = 'CC0-1.0', String? source}) => {
      'kind': kind, 'name': 'N', 'author': 'A', 'license': license,
      if (source != null) 'source': source,
      'data': data ?? {'colors': [0xFF000000, 0xFFFFFFFF]},
    };

String _pkg(List<Map<String, Object?>> items, {int version = 1}) =>
    jsonEncode({'format': 'artfoxel-assets', 'version': version, 'items': items});

void main() {
  group('patterns and arrays', () {
    test('grid / quilt / hex / radial / path counts', () {
      expect(PatternGenerator.grid(100, 100, 25, 25).length, 16);
      expect(PatternGenerator.quilt(100, 100, 25, 25).length, greaterThan(16));
      expect(PatternGenerator.hex(100, 100, 10), isNotEmpty);
      expect(PatternGenerator.radial(0, 0, 50, 6, rings: 2).length, 12);
      final p = PatternGenerator.alongPath(const [Pt(0, 0), Pt(100, 0)], 10);
      expect(p.length, 11);
      expect(p[3].x, closeTo(30, 1e-9));
    });
    test('runaway repeat counts are refused', () {
      expect(() => PatternGenerator.grid(100000, 100000, 1, 1), throwsA(isA<PatternException>()));
      expect(() => PatternGenerator.grid(10, 10, 0, 1), throwsA(isA<PatternException>()));
      expect(() => ArrayGenerator.linear(0, 1, 1), throwsA(isA<PatternException>()));
    });
    test('linear, radial and grid arrays', () {
      final l = ArrayGenerator.linear(4, 10, 0, scaleStep: 2);
      expect(l[3].x, 30);
      expect(l[3].scale, 8);
      final r = ArrayGenerator.radial(0, 0, 10, 0, 4);
      expect(r[2].x, closeTo(-20, 1e-9));
      expect(ArrayGenerator.gridArray(3, 2, 5, 5).length, 6);
    });
    test('symmetry expansion', () {
      expect(const Symmetry(mirrorV: true, cx: 50).expand(const Pt(10, 5)).last.x, 90);
      expect(const Symmetry(mirrorV: true, mirrorH: true, cx: 50, cy: 50).expand(const Pt(10, 10)).length, 4);
      expect(const Symmetry(radial: 4).expand(const Pt(10, 0)).length, 4);
    });
  });

  group('tiles', () {
    test('tile preview size and content', () {
      final t = _rgba(2, 2, (x, y) => 0xFF000000 | (x + y * 2) * 10);
      final p = TileOps.tilePreview(t, 2, 2, 3, 2);
      expect(p.length, 6 * 4 * 4);
      expect(p.sublist(0, 4), p.sublist(2 * 4, 2 * 4 + 4));
    });
    test('makeSeamless lowers edge mismatch', () {
      final t = _rgba(32, 32, (x, y) => 0xFF000000 | ((x * 8) << 16));
      final before = TileOps.edgeMismatch(t, 32, 32);
      final after = TileOps.edgeMismatch(TileOps.makeSeamless(t, 32, 32), 32, 32);
      expect(before, greaterThan(20));
      expect(after, lessThan(before));
    });
  });

  group('transforms', () {
    test('affine inverse round trip and anchor rotation', () {
      final a = Affine.rotate(0.7).then(Affine.translate(5, 3)).then(Affine.scale(2, 3));
      final inv = a.inverse()!;
      final p = inv.apply(a.apply(const Pt(4, 9)));
      expect(p.x, closeTo(4, 1e-9));
      expect(p.y, closeTo(9, 1e-9));
      final r = Affine.rotate(math.pi).about(const Pt(10, 10)).apply(const Pt(20, 10));
      expect(r.x, closeTo(0, 1e-9));
      expect(const Affine(0, 0, 0, 0, 0, 0).inverse(), isNull);
    });
    test('homography maps corners and inverts', () {
      final h = Homography.fromQuad(100, 50, const [Pt(10, 10), Pt(120, 0), Pt(110, 70), Pt(0, 60)])!;
      final tr = h.map(const Pt(100, 0));
      expect(tr.x, closeTo(120, 1e-6));
      expect(tr.y, closeTo(0, 1e-6));
      final back = h.inverse()!.map(h.map(const Pt(40, 20)));
      expect(back.x, closeTo(40, 1e-6));
      expect(back.y, closeTo(20, 1e-6));
      expect(Homography.fromQuad(10, 10, const [Pt(0, 0), Pt(1, 1), Pt(2, 2), Pt(3, 3)]), isNull);
    });
    test('mesh warp identity and inverse', () {
      final m = MeshWarp(2, 2, 100, 100);
      expect(m.isIdentity, isTrue);
      m.move(1, 1, const Pt(60, 60));
      expect(m.isIdentity, isFalse);
      final dst = m.forward(const Pt(30, 30));
      final back = m.inverse(dst);
      expect(back.x, closeTo(30, 0.01));
      expect(back.y, closeTo(30, 0.01));
    });
    test('non-destructive: identity preview equals source; commit flags; warning', () {
      final src = _rgba(8, 8, (x, y) => 0xFF000000 | (x * 30) << 16 | (y * 30) << 8);
      final t = TransformStack(src, 8, 8);
      expect(t.commit(), src);
      expect(t.committed, isTrue);
      t.setAffine(Affine.scale(3, 3));
      expect(t.qualityWarning(), isNotNull);
      expect(t.preview(scale: 0.5)!.length, 4 * 4 * 4);
      t.setAffine(const Affine(0, 0, 0, 0, 0, 0));
      expect(t.commit(), isNull);
    });
    test('translation moves pixels', () {
      final src = _rgba(8, 1, (x, y) => x == 2 ? 0xFFFF0000 : 0x00000000);
      final t = TransformStack(src, 8, 1)..setAffine(Affine.translate(3, 0));
      final out = t.commit()!;
      expect(out[(5) * 4], 255);
      expect(out[(5) * 4 + 3], 255);
      expect(out[(2) * 4 + 3], 0);
    });
  });

  group('liquify', () {
    test('identity field leaves pixels untouched', () {
      final src = _rgba(6, 6, (x, y) => 0xFF000000 | x * 40);
      expect(LiquifyField(6, 6).apply(src), src);
    });
    test('push moves content along the stroke and restore/reconstruct undo it', () {
      final src = _rgba(40, 1, (x, y) => x == 20 ? 0xFFFFFFFF : 0xFF000000);
      final f = LiquifyField(40, 1);
      f.dab(LiquifyTool.push, 20, 0.5, 8, 1, dirX: 1);
      final out = f.apply(src);
      // bright pixel now lies to the right of 20
      var maxI = 0, maxV = -1;
      for (var x = 0; x < 40; x++) {
        if (out[x * 4] > maxV) {
          maxV = out[x * 4];
          maxI = x;
        }
      }
      expect(maxI, greaterThan(20));
      f.reconstruct(1);
      expect(f.isIdentity, isTrue);
      expect(f.apply(src), src);
    });
    test('expand/pinch/swirl/restore change field', () {
      for (final t in [LiquifyTool.expand, LiquifyTool.pinch, LiquifyTool.swirl]) {
        final f = LiquifyField(30, 30)..dab(t, 15, 15, 10, 1);
        expect(f.isIdentity, isFalse, reason: t.name);
        for (var k = 0; k < 6; k++) {
          f.dab(LiquifyTool.restore, 15, 15, 10, 1);
        }
        var mx = 0.0;
        for (var i = 0; i < f.dx.length; i++) {
          mx = math.max(mx, f.dx[i].abs() + f.dy[i].abs());
        }
        expect(mx, lessThan(0.5), reason: t.name);
      }
    });
  });

  group('3D reference', () {
    test('bone lengths are preserved by posing', () {
      final m = Mannequin();
      final before = m.bones().map((b) => (b.$1 - b.$2).length).toList();
      m.setAngle('elbowL', 90, 0, 0);
      m.setAngle('kneeR', 60, 0, 0);
      m.setAngle('chest', 20, 10, 0);
      final after = m.bones().map((b) => (b.$1 - b.$2).length).toList();
      for (var i = 0; i < before.length; i++) {
        expect(after[i], closeTo(before[i], 1e-9));
      }
    });
    test('joint limits clamp and unknown joint throws', () {
      final m = Mannequin();
      expect(m.setAngle('elbowL', 400, 0, 0).x, 150);
      expect(() => m.setAngle('tail', 0, 0, 0), throwsArgumentError);
    });
    test('pose save/load and JSON', () {
      final lib = PoseLibrary()..save(PoseLibrary.tPose());
      final back = PoseLibrary.fromJson(jsonDecode(jsonEncode(lib.toJson())));
      final m = Mannequin()..loadPose(back.get('T-pose')!);
      expect(m.pose.angles['shoulderL']!.z, 90);
      final m2 = Mannequin.fromJson(jsonDecode(jsonEncode(m.toJson())));
      expect(m2.pose.angles['shoulderR']!.z, -90);
    });
    test('camera projection and light', () {
      const cam = Camera3D();
      final p = cam.project(const V3(0, 0, 0))!;
      expect(p.$1, closeTo(0, 1e-9));
      expect(cam.project(const V3(0, 0, 100)), isNull); // behind the camera
      expect(const Light3D().lambert(const V3(-0.4, 0.8, 0.6)), closeTo(1, 1e-9));
      expect(const Light3D().lambert(const V3(0.4, -0.8, -0.6)), closeTo(0.25, 1e-9));
    });
    test('reference is never part of exports', () {
      expect(ReferenceScene().includedInExport, isFalse);
      expect(CanvasTextureSetting().bakeOnExport, isFalse);
      expect(Primitive3D(PrimitiveKind.cube).wirePoints().length, 8);
    });
  });

  group('paper texture', () {
    test('deterministic and in range for every kind', () {
      for (final k in PaperKind.values) {
        final a = PaperTexture(k, seed: 5), b = PaperTexture(k, seed: 5);
        for (var i = 0; i < 50; i++) {
          final v = a.height(i * 1.7, i * 0.9);
          expect(v, inInclusiveRange(0.0, 1.0), reason: k.name);
          expect(v, b.height(i * 1.7, i * 0.9));
        }
      }
    });
    test('shade does not mutate the source and intensity 0 is a no-op', () {
      final src = _rgba(8, 8, (x, y) => 0xFF808080);
      final copy = Uint8List.fromList(src);
      final shaded = PaperTexture(PaperKind.rough, intensity: 1).shade(src, 8, 8);
      expect(src, copy);
      expect(shaded, isNot(copy));
      expect(PaperTexture(PaperKind.rough, intensity: 0).shade(src, 8, 8), copy);
    });
  });

  group('asset exchange', () {
    test('valid package parses; warnings for non-commercial', () {
      final r = AssetPackage.parse(_pkg([_item(license: 'CC-BY-NC-4.0', source: 'https://example.com/x')]));
      expect(r.items.single.kind, AssetKind.palette);
      expect(r.warnings, isNotEmpty);
    });
    test('export then parse round trip, export refuses missing author/licence', () {
      final item = AssetItem(kind: AssetKind.palette, name: 'P', author: 'Me', license: 'own-work',
          payload: {'colors': [1, 2, 3]});
      expect(AssetPackage.parse(AssetPackage.export([item])).items.single.name, 'P');
      expect(() => AssetPackage.export([AssetItem(kind: AssetKind.palette, name: 'P', author: ' ', license: 'MIT', payload: {})]),
          throwsA(isA<AssetException>()));
      expect(() => AssetPackage.export([AssetItem(kind: AssetKind.palette, name: 'P', author: 'x', license: 'weird', payload: {})]),
          throwsA(isA<AssetException>()));
    });
    test('hostile or malformed packages are rejected', () {
      void bad(String s) => expect(() => AssetPackage.parse(s), throwsA(isA<AssetException>()));
      bad('not json');
      bad('[]');
      bad(jsonEncode({'format': 'other', 'version': 1, 'items': []}));
      bad(_pkg([], version: 2));
      bad(_pkg([_item(kind: 'plugin')]));
      bad(_pkg([_item(data: {'colors': [1], 'script': 'alert(1)'})]));
      bad(_pkg([_item(data: {'colors': [1], 'nested': {'Eval': 'x'}})]));
      bad(_pkg([_item(source: 'javascript:alert(1)')]));
      bad(_pkg([_item(source: 'ftp://x.y/z')]));
      bad(_pkg([_item(license: 'stolen')]));
      bad(_pkg([_item(data: {'colors': []})]));
      bad(_pkg([_item(kind: 'texture', data: {'png': base64Encode([1, 2, 3, 4, 5, 6, 7, 8, 9])})]));
      bad(_pkg([_item(kind: 'texture', data: {'png': '!!!'})]));
      bad(_pkg([_item(kind: 'gradient', data: {'stops': [{'pos': 2, 'color': 1}, {'pos': 0, 'color': 2}]})]));
      bad(jsonEncode({'format': 'artfoxel-assets', 'version': 1, 'items': [for (var i = 0; i < 201; i++) _item()]}));
    });
    test('png magic accepted', () {
      final png = base64Encode([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0]);
      expect(AssetPackage.parse(_pkg([_item(kind: 'stamp', data: {'png': png})])).items, hasLength(1));
    });
    test('brush set and gradient payloads', () {
      expect(AssetPackage.parse(_pkg([_item(kind: 'brushSet', data: {'brushes': [{'name': 'x', 'dynamics': {}}]})])).items, hasLength(1));
      expect(AssetPackage.parse(_pkg([_item(kind: 'gradient', data: {'stops': [{'pos': 0, 'color': 1}, {'pos': 1, 'color': 2}]})])).items, hasLength(1));
    });
    test('report queue validates reason', () {
      final q = ReportQueue();
      final it = AssetItem(kind: AssetKind.palette, name: 'P', author: 'A', license: 'MIT', payload: {});
      q.add(it, 'copyright');
      expect(q.pending.length, 1);
      expect(() => q.add(it, 'meh'), throwsA(isA<AssetException>()));
    });
  });

  group('brush dynamics', () {
    test('clamping and JSON', () {
      final d = BrushDynamics.fromJson({'spacing': 99, 'flow': -3, 'tex': 'x' * 100});
      expect(d.spacing, 2);
      expect(d.flow, 0);
      expect(d.textureId, isNull);
      expect(BrushDynamics.fromJson(jsonDecode(jsonEncode(d.toJson()))).spacing, 2);
    });
    test('dabs follow spacing and are deterministic', () {
      const d = BrushDynamics(spacing: 0.5, scatter: 0.2, rotationJitterDeg: 20);
      final a = d.dabsAlong(const [(0, 0), (100, 0)], 10, seed: 3);
      final b = d.dabsAlong(const [(0, 0), (100, 0)], 10, seed: 3);
      expect(a.length, 21);
      expect(a.map((e) => e.x), b.map((e) => e.x));
      expect(const BrushDynamics(spacing: 0.5).dabsAlong(const [(0, 0), (100, 0)], 10).length, 21);
    });
  });

  group('checkpoints', () {
    Uint8List bytes(int n, int v) => Uint8List(n)..fillRange(0, n, v);
    test('restore returns exact bytes, independent of later edits', () {
      final m = CheckpointManager(store: ChunkStore(chunkSize: 16));
      final data = {'layer1': Uint8List.fromList(List.generate(100, (i) => i)), 'meta': bytes(5, 9)};
      final c = m.create(data, name: 'first');
      data['layer1']![0] = 77;
      final r = m.restore(c.id);
      expect(r['layer1']![0], 0);
      expect(r['layer1']!.length, 100);
      expect(r['meta'], bytes(5, 9));
    });
    test('small edits share chunks (efficient)', () {
      final m = CheckpointManager(store: ChunkStore(chunkSize: 64));
      final base = Uint8List.fromList(List.generate(64 * 100, (i) => (i ~/ 64) % 256));
      final a = m.create({'l': base}, name: 'a');
      final stored1 = m.store.storedBytes;
      final edited = Uint8List.fromList(base)..[10] = 255;
      final b = m.create({'l': edited}, name: 'b');
      expect(m.store.storedBytes - stored1, lessThanOrEqualTo(64));
      final diff = m.compare(a.id, b.id);
      expect(diff.changed, ['l']);
      expect(diff.changedChunks, 1);
      expect(m.compare(a.id, a.id).identical, isTrue);
    });
    test('compare added/removed layers', () {
      final m = CheckpointManager();
      final a = m.create({'x': bytes(4, 1)}, name: 'a');
      final b = m.create({'y': bytes(4, 1)}, name: 'b');
      final d = m.compare(a.id, b.id);
      expect(d.added, ['y']);
      expect(d.removed, ['x']);
    });
    test('duplicate shares chunks and survives deleting the original', () {
      final m = CheckpointManager(store: ChunkStore(chunkSize: 8));
      final a = m.create({'l': bytes(40, 3)}, name: 'a');
      final n = m.store.chunkCount;
      final d = m.duplicate(a.id);
      expect(m.store.chunkCount, n);
      m.remove(a.id);
      expect(m.restore(d.id)['l'], bytes(40, 3));
      m.remove(d.id);
      expect(m.store.chunkCount, 0);
    });
    test('auto checkpoints are trimmed, named ones kept; policy', () {
      final m = CheckpointManager(maxAuto: 2);
      final keep = m.create({'l': bytes(4, 0)}, name: 'keep');
      for (var i = 0; i < 5; i++) {
        m.create({'l': bytes(4, i + 1)}, name: 'auto$i', auto: true);
      }
      expect(m.all.where((c) => c.auto).length, 2);
      expect(m.byId(keep.id), isNotNull);
      final t0 = DateTime(2026, 1, 1, 12);
      final mm = CheckpointManager();
      mm.create({'l': bytes(1, 1)}, name: 'a', now: t0);
      expect(mm.shouldAuto(t0.add(const Duration(minutes: 5)), dirty: true), isFalse);
      expect(mm.shouldAuto(t0.add(const Duration(minutes: 11)), dirty: true), isTrue);
      expect(mm.shouldAuto(t0.add(const Duration(minutes: 11)), dirty: false), isFalse);
    });
    test('unknown ids throw', () {
      expect(() => CheckpointManager().restore(5), throwsA(isA<CheckpointException>()));
    });
  });

  group('colour management', () {
    test('LAB round trip and known values', () {
      for (final c in [0xFF000000, 0xFFFFFFFF, 0xFFFF0000, 0xFF3366CC, 0xFF80FF40]) {
        final back = ColorManagement.fromLab(ColorManagement.toLab(c));
        expect(ColorManagement.deltaE(c, back), lessThan(1.0), reason: c.toRadixString(16));
      }
      expect(ColorManagement.toLab(0xFFFFFFFF).l, closeTo(100, 0.2));
      expect(ColorManagement.toLab(0xFF000000).l, closeTo(0, 0.2));
      expect(ColorManagement.toLab(0xFFFF0000).l, closeTo(53.2, 0.5));
    });
    test('LCH round trip', () {
      final (l, c, h) = ColorManagement.toLch(0xFF3366CC);
      expect(ColorManagement.deltaE(0xFF3366CC, ColorManagement.fromLch(l, c, h)), lessThan(1));
    });
    test('naive CMYK round trip is exact for 8-bit values it can represent', () {
      expect(ColorManagement.toCmykNaive(0xFF000000).k, 1);
      final c = ColorManagement.toCmykNaive(0xFFFF8000);
      expect(ColorManagement.fromCmykNaive(c), 0xFFFF8000);
    });
    test('P3 white is sRGB white; saturated P3 green is out of gamut', () {
      final (w, outW) = ColorManagement.p3ToSrgb(1, 1, 1);
      expect(w & 0xFFFFFF, 0xFFFFFF);
      expect(outW, isFalse);
      final (_, outG) = ColorManagement.p3ToSrgb(0, 1, 0);
      expect(outG, isTrue);
    });
    test('honest capability flags', () {
      expect(ColorManagement.softProofAvailable, isFalse);
      expect(ColorManagement.iccApplied, isFalse);
    });
    test('ICC header validation', () {
      Uint8List profile({String sig = 'acsp', int? size}) {
        final b = ByteData(132 + 12 + 16);
        b.setUint32(0, size ?? b.lengthInBytes);
        b.setUint8(8, 4);
        for (final (i, c) in 'mntr'.codeUnits.indexed) {
          b.setUint8(12 + i, c);
        }
        for (final (i, c) in 'RGB '.codeUnits.indexed) {
          b.setUint8(16 + i, c);
        }
        for (final (i, c) in 'XYZ '.codeUnits.indexed) {
          b.setUint8(20 + i, c);
        }
        for (final (i, c) in sig.codeUnits.indexed) {
          b.setUint8(36 + i, c);
        }
        b.setUint32(128, 1);
        for (final (i, c) in 'desc'.codeUnits.indexed) {
          b.setUint8(132 + i, c);
        }
        b.setUint32(132 + 4, 144);
        b.setUint32(132 + 8, 16);
        for (final (i, c) in 'desc'.codeUnits.indexed) {
          b.setUint8(144 + i, c);
        }
        b.setUint32(144 + 8, 3);
        b.setUint8(144 + 12, 0x41);
        b.setUint8(144 + 13, 0x42);
        return b.buffer.asUint8List();
      }

      final h = IccInspector.inspect(profile());
      expect(h.colourSpace, 'RGB');
      expect(h.profileClass, 'mntr');
      expect(h.description, 'AB');
      expect(() => IccInspector.inspect(profile(sig: 'nope')), throwsA(isA<IccException>()));
      expect(() => IccInspector.inspect(profile(size: 5)), throwsA(isA<IccException>()));
      expect(() => IccInspector.inspect(Uint8List(10)), throwsA(isA<IccException>()));
    });
  });

  group('vector paths and paragraphs', () {
    test('smooth anchor handles stay collinear', () {
      final a = Anchor(const Pt(0, 0), handleIn: const Pt(-10, 0), handleOut: const Pt(10, 0), kind: AnchorKind.smooth);
      a.moveHandleOut(const Pt(0, 10));
      expect(a.handleIn.x, closeTo(0, 1e-9));
      expect(a.handleIn.y, closeTo(-10, 1e-9));
    });
    test('insertAnchor keeps the curve shape', () {
      final p = VectorPath(anchors: [
        Anchor(const Pt(0, 0), handleOut: const Pt(0, 20)),
        Anchor(const Pt(40, 0), handleIn: const Pt(40, 20)),
      ]);
      final before = p.flatten(steps: 40);
      p.insertAnchor(0, 0.5);
      expect(p.anchors.length, 3);
      final mid = p.anchors[1].pos;
      final onCurve = before.map((q) => q.distanceTo(mid)).reduce(math.min);
      expect(onCurve, lessThan(0.5));
      final after = p.flatten(steps: 20);
      expect(after.first, before.first);
      expect(after.last.x, closeTo(before.last.x, 1e-9));
    });
    test('hit test, closed path, anchor cap, JSON', () {
      final p = VectorPath(closed: true, style: const PathStyle(fill: 0xFFFF0000, stroke: 0xFF000000, dash: [4, 2]));
      for (final pt in const [Pt(0, 0), Pt(10, 0), Pt(10, 10)]) {
        p.add(Anchor(pt));
      }
      expect(p.hitAnchor(const Pt(10.5, 0.5), 2), 1);
      expect(p.hitAnchor(const Pt(50, 50), 2), -1);
      expect(p.length, closeTo(10 + 10 + math.sqrt(200), 1e-6));
      final back = VectorPath.fromJson(jsonDecode(jsonEncode(p.toJson())));
      expect(back.closed, isTrue);
      expect(back.style.dash, [4, 2]);
      expect(back.anchors.length, 3);
      for (var i = 0; i < VectorPath.maxAnchors; i++) {
        p.add(Anchor(const Pt(0, 0)));
      }
      expect(p.add(Anchor(const Pt(0, 0))), isFalse);
      expect(() => VectorPath.fromJson({'anchors': [{'p': 'x'}]}), throwsA(anything));
    });
    test('wrap, alignment, long word and height', () {
      double m(String s) => s.length * 10.0;
      const st = ParagraphStyle(width: 100, lineHeight: 1.5, spaceAfter: 4);
      final lines = ParagraphLayout.wrap('aaa bbb ccc ddd\nxx', st, m);
      expect(lines[0], ['aaa bbb', 'ccc ddd']);
      expect(lines[1], ['xx']);
      final long = ParagraphLayout.wrap('abcdefghijklmnopqrstuvwxyz', st, m);
      expect(long[0].every((l) => l.length <= 10), isTrue);
      expect(long[0].join(), 'abcdefghijklmnopqrstuvwxyz');
      expect(ParagraphLayout.lineOffset(const ParagraphStyle(align: ParaAlign.center, width: 100), 40, false), 30);
      expect(ParagraphLayout.lineOffset(const ParagraphStyle(align: ParaAlign.right, width: 100), 40, false), 60);
      expect(ParagraphLayout.lineOffset(const ParagraphStyle(firstLineIndent: 12), 40, true), 12);
      expect(ParagraphLayout.totalHeight(lines, st, 10), 3 * 15 + 2 * 4);
    });
  });

  group('performance', () {
    test('tiers and profiles', () {
      expect(const DeviceCapability(ramMb: 2000, cores: 4).tier, DeviceTier.low);
      expect(const DeviceCapability(ramMb: 4000, cores: 8).tier, DeviceTier.mid);
      expect(const DeviceCapability(ramMb: 12000, cores: 8).tier, DeviceTier.high);
      final lo = PerformanceProfile.forDevice(const DeviceCapability(ramMb: 2000, cores: 4));
      final hi = PerformanceProfile.forDevice(const DeviceCapability(ramMb: 12000, cores: 8, gpuTextureMax: 16384));
      expect(hi.maxCanvasPixels, greaterThan(lo.maxCanvasPixels));
      expect(hi.undoBudgetBytes, greaterThan(lo.undoBudgetBytes));
    });
    test('canvas guard refuses and warns', () {
      final lo = PerformanceProfile.forDevice(const DeviceCapability(ramMb: 2000, cores: 4));
      expect(CanvasGuard.check(8000, 8000, 5, lo).allowed, isFalse);
      expect(CanvasGuard.check(2000, 2000, 5, lo).allowed, isTrue);
      expect(CanvasGuard.check(2000, 2000, 500, lo).allowed, isFalse);
      expect(CanvasGuard.check(0, 10, 1, lo).allowed, isFalse);
      expect(CanvasGuard.check(2000, 2000, 5, lo, budgetBytes: 1000).allowed, isFalse);
    });
    test('tile grid dirty tracking', () {
      final g = TileGrid(1000, 600, 256);
      expect((g.cols, g.rows), (4, 3));
      g.markRect(10, 10, 20, 20);
      expect(g.dirtyCount, 1);
      g.markRect(250, 250, 270, 270); // straddles 4 tiles
      expect(g.dirtyCount, 4); // tile (0,0) was already dirty
      final tiles = g.takeDirty();
      expect(tiles.length, 4);
      expect(g.isClean, isTrue);
      g.markRect(990, 590, 5000, 5000); // clipped to last tile
      final last = g.takeDirty().single;
      expect((last.r, last.b), (1000, 600));
      g.markRect(5, 5, 5, 9); // empty
      expect(g.isClean, isTrue);
    });
    test('batcher, LRU, undo budget', () {
      final b = StrokeBatcher<int>(maxBatch: 3)..add(1)..add(2);
      expect(b.shouldFlush, isFalse);
      b.add(3);
      expect(b.shouldFlush, isTrue);
      expect(b.flush(), [1, 2, 3]);
      expect(b.pending, 0);
      final c = ByteLru<int>(10)..put(1, 'a', 4)..put(2, 'b', 4);
      expect(c.get<String>(1), 'a');
      c.put(3, 'c', 4);
      expect(c.get<String>(2), isNull);
      c.put(4, 'huge', 99);
      expect(c.get<String>(4), isNull);
      final u = UndoBudget(100);
      expect(u.record(60), 0);
      expect(u.record(60), 1);
      expect(u.total, 60);
      expect(u.record(500), 1); // single huge entry is kept, older dropped
      expect(u.entries, 1);
    });
    test('profiler and adaptive preview', () {
      final p = FrameProfiler();
      for (var i = 1; i <= 100; i++) {
        p.record(i.toDouble());
      }
      expect(p.percentile(0.5), closeTo(50, 1.1));
      expect(p.missRate, closeTo(0.84, 0.005));
      final a = AdaptivePreview();
      for (var i = 0; i < 20; i++) {
        a.update(40);
      }
      expect(a.scale, 0.25);
      for (var i = 0; i < 100; i++) {
        a.update(5);
      }
      expect(a.scale, 1.0);
      a.update(40);
      a.penUp();
      expect(a.scale, 1.0);
    });
    test('background runner returns results', () async {
      expect(await runInBackground(() => List.generate(1000, (i) => i).fold<int>(0, (a, b) => a + b)), 499500);
    });
  });

  test('large-canvas fill + selection operations stay linear', () {
    final sw = Stopwatch()..start();
    final m = SelectionMask(1000, 1000)..data.fillRange(0, 1000000, 255);
    expect(m.invert().isEmpty, isTrue);
    expect(sw.elapsedMilliseconds, lessThan(5000));
  });
}
