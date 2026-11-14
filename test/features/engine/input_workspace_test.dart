import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:artfoxel/features/studio/engine/input_engine.dart';
import 'package:artfoxel/features/studio/engine/workspace_model.dart';

List<PenSample> _zig() => [
      for (var i = 0; i < 40; i++) PenSample(i * 3.0, (i.isEven ? 4.0 : -4.0), tMs: i * 8.0),
    ];

double _wiggle(List<PenSample> p) {
  var s = 0.0;
  for (var i = 1; i < p.length; i++) {
    s += (p[i].y - p[i - 1].y).abs();
  }
  return s;
}

void main() {
  group('stabilizer', () {
    for (final mode in [StabilizerMode.realtime, StabilizerMode.constant, StabilizerMode.speedDependent]) {
      test('${mode.name} reduces jitter', () {
        final s = LiveStabilizer(StabilizerSettings(mode: mode, strength: 0.8, window: 8, preserveCornersDeg: 179));
        final out = [for (final p in _zig()) s.add(p)];
        expect(_wiggle(out), lessThan(_wiggle(_zig()) * 0.6));
      });
    }
    test('off passes input through unchanged', () {
      final s = LiveStabilizer(const StabilizerSettings());
      for (final p in _zig()) {
        final o = s.add(p);
        expect((o.x, o.y), (p.x, p.y));
      }
    });
    test('corner is preserved', () {
      final s = LiveStabilizer(const StabilizerSettings(mode: StabilizerMode.realtime, strength: 0.9, preserveCornersDeg: 60));
      s.add(const PenSample(0, 0, tMs: 0));
      s.add(const PenSample(20, 0, tMs: 8));
      final o = s.add(const PenSample(20, 20, tMs: 16)); // 90° turn
      expect((o.x, o.y), (20, 20));
    });
    test('lazy guide keeps the pointer exactly radius away once exceeded', () {
      final s = LiveStabilizer(const StabilizerSettings(lazyRadius: 10));
      s.add(const PenSample(0, 0));
      expect(s.add(const PenSample(5, 0)).x, 0); // inside radius: no movement
      final o = s.add(const PenSample(30, 0));
      expect(o.x, closeTo(20, 1e-9));
    });
    test('prediction is capped and absent when off', () {
      final off = LiveStabilizer(const StabilizerSettings());
      for (final p in _line()) off.add(p);
      expect(off.predict(), isNull);
      final on = LiveStabilizer(const StabilizerSettings(prediction: true));
      for (final p in _line()) on.add(p);
      final q = on.predict(maxPx: 6)!;
      expect(q.x - _line().last.x, lessThanOrEqualTo(6.0001));
    });
    test('post smoothing keeps endpoints and corners', () {
      final pts = [const PenSample(0, 0), const PenSample(10, 5), const PenSample(20, 0),
          const PenSample(20, 30), const PenSample(25, 28)];
      final sm = smoothStroke(pts, amount: 0.8, cornerDeg: 60);
      expect((sm.first.x, sm.first.y), (0, 0));
      expect((sm.last.x, sm.last.y), (25, 28));
      expect(sm.length, pts.length);
    });
    test('taper scales pressure at both ends', () {
      final pts = [for (var i = 0; i <= 10; i++) PenSample(i * 10.0, 0)];
      final t = applyTaper(pts, startPx: 30, endPx: 30);
      expect(t.first.pressure, 0);
      expect(t.last.pressure, 0);
      expect(t[5].pressure, 1);
      expect(t[1].pressure, closeTo(1 / 3, 1e-9));
    });
    test('settings JSON round trip', () {
      const s = StabilizerSettings(mode: StabilizerMode.fastStroke, strength: 0.3, lazyRadius: 12, prediction: true);
      final b = StabilizerSettings.fromJson(jsonDecode(jsonEncode(s.toJson())));
      expect(b.mode, StabilizerMode.fastStroke);
      expect(b.lazyRadius, 12);
      expect(b.prediction, isTrue);
    });
  });

  group('input mapping and latency', () {
    test('pressure is ignored when device has none, and warned', () {
      const m = InputMapping();
      expect(m.mapPressure(0.2, const DeviceCapabilities()), 1);
      expect(m.warnings(const DeviceCapabilities()), isNotEmpty);
      expect(m.mapPressure(0.5, const DeviceCapabilities(pressure: true)), 0.5);
    });
    test('palm rejection', () {
      const m = InputMapping();
      expect(m.acceptTouch(stylusActive: true), isFalse);
      expect(m.acceptTouch(stylusActive: false, contactRadius: 50), isFalse);
      expect(m.acceptTouch(stylusActive: false, contactRadius: 5), isTrue);
    });
    test('latency meter stats and glitch rejection', () {
      final l = LatencyMeter();
      for (var i = 1; i <= 100; i++) {
        l.record(0, i.toDouble());
      }
      l.record(10, 5); // negative ignored
      expect(l.count, 100);
      expect(l.mean, closeTo(50.5, 1e-9));
      expect(l.p95, closeTo(95, 1.1));
      final low = LatencyMeter.lowLatency(const StabilizerSettings(mode: StabilizerMode.realtime, lazyRadius: 5));
      expect(low.mode, StabilizerMode.off);
      expect(low.lazyRadius, 0);
    });
    test('per-brush defaults round trip', () {
      final d = BrushInputDefaults()..set('ink', const StabilizerSettings(mode: StabilizerMode.realtime, strength: 0.9));
      final b = BrushInputDefaults.fromJson(jsonDecode(jsonEncode(d.toJson())));
      expect(b.forBrush('ink').strength, 0.9);
      expect(b.forBrush('other').mode, StabilizerMode.off);
    });
  });

  group('workspace', () {
    test('all six presets exist and are valid', () {
      for (final n in ['Beginner', 'Sketching', 'Painting', 'Illustration', 'Manga', 'Professional']) {
        final w = WorkspacePresets.named(n)!;
        expect(w.visibleToolbar, isNotEmpty);
        expect(w.quickMenu.length, lessThanOrEqualTo(8));
      }
    });
    test('toolbar reorder/pin/hide and JSON', () {
      var w = WorkspacePresets.named('Professional')!;
      final first = w.toolbar.first.toolId;
      w = w.reorderTool(0, 3).setTool('brush', pinned: false, visible: false);
      expect(w.toolbar.first.toolId, isNot(first));
      expect(w.visibleToolbar.any((t) => t.toolId == 'brush'), isFalse);
      final b = WorkspaceLayout.fromJson(jsonDecode(jsonEncode(w.toJson())));
      expect(b.toolbar.map((t) => t.toolId), w.toolbar.map((t) => t.toolId));
      expect(b.uiScale, w.uiScale);
    });
    test('ui scale clamps and left-handed mirrors docks', () {
      final w = WorkspacePresets.named('Sketching')!.copyWith(uiScale: 9, handedness: Handedness.left);
      expect(w.uiScale, 2.0);
      expect(w.effectiveDock(PanelDock.left), PanelDock.right);
      expect(w.effectiveDock(PanelDock.bottom), PanelDock.bottom);
    });
    test('panel size clamps', () {
      final p = const PanelState('x').copyWith(width: 5);
      expect(p.width, 160);
    });
  });

  group('navigator and view', () {
    const n = NavigatorMath(2000, 1000, 200, 200);
    test('scale and viewport rect', () {
      expect(n.scale, closeTo(0.1, 1e-12));
      final r = n.viewportRect(viewW: 500, viewH: 500, zoom: 1, panX: 100, panY: 50);
      expect([r.$1, r.$2, r.$3, r.$4], everyElement(isA<double>()));
      expect(r.$1, closeTo(10, 1e-9));
      expect(r.$2, closeTo(5, 1e-9));
      expect(r.$3, closeTo(50, 1e-9));
      expect(r.$4, closeTo(50, 1e-9));
    });
    test('tap centres the view and clamps', () {
      final (x, y) = n.panForTap(100, 50, viewW: 500, viewH: 500, zoom: 1);
      expect(x, closeTo(750, 1e-9));
      expect(y, closeTo(250, 1e-9));
      final (x2, y2) = n.panForTap(0, 0, viewW: 500, viewH: 500, zoom: 1);
      expect((x2, y2), (0.0, 0.0));
    });
    test('fit zoom and pixel view threshold', () {
      expect(NavigatorMath.fitZoom(2000, 1000, 1000, 1000, margin: 1), 0.5);
      expect(NavigatorMath.pixelViewActive(2, 2), isTrue);
      expect(NavigatorMath.pixelViewActive(1, 2), isFalse);
    });
    test('flip and aid toggles, value check maths', () {
      var v = const CanvasViewState().toggleFlipH();
      expect(v.flipH, isTrue);
      v = v.withAid(ViewAid.grayscale);
      expect(v.aid, ViewAid.grayscale);
      expect(v.withAid(ViewAid.grayscale).aid, ViewAid.none);
      expect(CanvasViewState.grayscaleArgb(0xFFFFFFFF), 0xFFFFFFFF);
      expect(CanvasViewState.grayscaleArgb(0xFF000000), 0xFF000000);
      expect(CanvasViewState.alphaArgb(0x80123456) & 0xFF, 0x80);
    });
    test('bookmarks', () {
      final b = BookmarkList()..add(const ViewBookmark('eye', 4, 10, 20));
      b.add(const ViewBookmark('eye', 8, 1, 1)); // replaces
      expect(b.items.length, 1);
      expect(b.find('eye')!.zoom, 8);
      expect(b.add(const ViewBookmark(' ', 1, 0, 0)), isFalse);
      final back = BookmarkList.fromJson(jsonDecode(jsonEncode(b.toJson())));
      expect(back.find('eye')!.panX, 1);
    });
  });

  group('shortcuts, gestures, history, notes', () {
    test('shortcut parse/label and conflict reporting', () {
      final k = ShortcutKey.parse('Ctrl+Shift+Z')!;
      expect(k.label, 'Ctrl+Shift+Z');
      expect(ShortcutKey.parse('Foo+Z'), isNull);
      final m = ShortcutMap.standard();
      expect(m.actionFor(k), 'redo');
      final displaced = m.bind(const ShortcutKey('b'), 'tool.fill');
      expect(displaced, 'tool.brush');
      expect(m.keyFor('tool.fill'), const ShortcutKey('b'));
      final back = ShortcutMap.fromJson(jsonDecode(jsonEncode(m.toJson())));
      expect(back.actionFor(const ShortcutKey('b')), 'tool.fill');
    });
    test('temporary tool switching', () {
      final t = TemporaryToolSwitch('brush')..hold('eyedropper');
      expect(t.current, 'eyedropper');
      t.hold('hand');
      t.release();
      expect(t.current, 'brush');
      expect(t.active, isFalse);
    });
    test('gestures and drags', () {
      final g = GestureMap();
      expect(g.of('twoFingerTap'), GestureAction.undo);
      g.set('twoFingerTap', GestureAction.quickMenu);
      expect(GestureMap.fromJson(jsonDecode(jsonEncode(g.toJson()))).of('twoFingerTap'), GestureAction.quickMenu);
      expect(GestureMap.dragSize(10, 100), greaterThan(10));
      expect(GestureMap.dragSize(1, -1000), 1);
      expect(GestureMap.dragOpacity(0.5, -300), 1.0);
    });
    test('history slider steps', () {
      final h = HistorySlider(20, 15);
      expect(h.stepsTo(10), -5);
      expect(h.stepsTo(99), 5);
    });
    test('notes limit', () {
      final n = ProjectNotes();
      expect(n.set('a' * 20001), isFalse);
      expect(n.set('hello'), isTrue);
      expect(ProjectNotes.fromJson(n.toJson()).text, 'hello');
    });
  });
}

List<PenSample> _line() => [for (var i = 0; i < 10; i++) PenSample(i * 4.0, 0, tMs: i * 8.0)];
