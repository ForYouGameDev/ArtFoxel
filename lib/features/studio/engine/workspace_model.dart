import 'dart:math' as math;

/// Phase 7.5.2 + 7.5.8 (shortcuts/notes) — workspace, toolbar, navigator.

enum Handedness { right, left }

enum PanelDock { left, right, bottom, floating }

class ToolbarItem {
  const ToolbarItem(this.toolId, {this.pinned = true, this.visible = true});
  final String toolId;
  final bool pinned, visible;
  ToolbarItem copyWith({bool? pinned, bool? visible}) =>
      ToolbarItem(toolId, pinned: pinned ?? this.pinned, visible: visible ?? this.visible);
  Map<String, Object?> toJson() => {'id': toolId, 'pin': pinned, 'vis': visible};
  static ToolbarItem fromJson(Map<String, Object?> j) => ToolbarItem(
      '${j['id']}',
      pinned: j['pin'] != false,
      visible: j['vis'] != false);
}

class PanelState {
  const PanelState(this.panelId,
      {this.dock = PanelDock.right,
      this.x = 0,
      this.y = 0,
      this.width = 280,
      this.height = 320,
      this.open = true});
  final String panelId;
  final PanelDock dock;
  final double x, y, width, height;
  final bool open;
  PanelState copyWith(
          {PanelDock? dock, double? x, double? y, double? width, double? height, bool? open}) =>
      PanelState(panelId,
          dock: dock ?? this.dock,
          x: x ?? this.x,
          y: y ?? this.y,
          width: (width ?? this.width).clamp(160.0, 800.0),
          height: (height ?? this.height).clamp(120.0, 1200.0),
          open: open ?? this.open);
  Map<String, Object?> toJson() => {
        'id': panelId, 'dock': dock.name, 'x': x, 'y': y,
        'w': width, 'h': height, 'open': open,
      };
  static PanelState fromJson(Map<String, Object?> j) => PanelState('${j['id']}',
      dock: PanelDock.values.firstWhere((d) => d.name == j['dock'],
          orElse: () => PanelDock.right),
      x: (j['x'] as num?)?.toDouble() ?? 0,
      y: (j['y'] as num?)?.toDouble() ?? 0,
      width: ((j['w'] as num?)?.toDouble() ?? 280).clamp(160.0, 800.0),
      height: ((j['h'] as num?)?.toDouble() ?? 320).clamp(120.0, 1200.0),
      open: j['open'] != false);
}

class WorkspaceLayout {
  const WorkspaceLayout({
    required this.name,
    this.toolbar = const [],
    this.quickMenu = const [],
    this.panels = const [],
    this.uiScale = 1.0,
    this.handedness = Handedness.right,
  });
  final String name;
  final List<ToolbarItem> toolbar;
  final List<String> quickMenu; // up to 8 tool ids
  final List<PanelState> panels;
  final double uiScale; // 0.75 .. 2.0
  final Handedness handedness;

  static const minScale = 0.75, maxScale = 2.0;

  WorkspaceLayout copyWith({
    String? name,
    List<ToolbarItem>? toolbar,
    List<String>? quickMenu,
    List<PanelState>? panels,
    double? uiScale,
    Handedness? handedness,
  }) =>
      WorkspaceLayout(
        name: name ?? this.name,
        toolbar: toolbar ?? this.toolbar,
        quickMenu: (quickMenu ?? this.quickMenu).take(8).toList(),
        panels: panels ?? this.panels,
        uiScale: (uiScale ?? this.uiScale).clamp(minScale, maxScale),
        handedness: handedness ?? this.handedness,
      );

  List<ToolbarItem> get visibleToolbar =>
      toolbar.where((t) => t.visible).toList();

  WorkspaceLayout reorderTool(int from, int to) {
    if (from < 0 || from >= toolbar.length) return this;
    final list = List<ToolbarItem>.of(toolbar);
    final item = list.removeAt(from);
    list.insert(to.clamp(0, list.length), item);
    return copyWith(toolbar: list);
  }

  WorkspaceLayout setTool(String id, {bool? pinned, bool? visible}) => copyWith(
      toolbar: [
        for (final t in toolbar)
          t.toolId == id ? t.copyWith(pinned: pinned, visible: visible) : t
      ]);

  WorkspaceLayout setPanel(PanelState p) {
    final list = [
      for (final e in panels) e.panelId == p.panelId ? p : e,
      if (!panels.any((e) => e.panelId == p.panelId)) p,
    ];
    return copyWith(panels: list);
  }

  /// Mirrors the layout for left-handed use: docks swap sides.
  PanelDock effectiveDock(PanelDock d) {
    if (handedness == Handedness.right) return d;
    switch (d) {
      case PanelDock.left:
        return PanelDock.right;
      case PanelDock.right:
        return PanelDock.left;
      default:
        return d;
    }
  }

  Map<String, Object?> toJson() => {
        'name': name,
        'toolbar': [for (final t in toolbar) t.toJson()],
        'quick': quickMenu,
        'panels': [for (final p in panels) p.toJson()],
        'scale': uiScale,
        'hand': handedness.name,
      };

  static WorkspaceLayout fromJson(Map<String, Object?> j) => WorkspaceLayout(
        name: '${j['name'] ?? 'Custom'}',
        toolbar: [
          for (final t in (j['toolbar'] as List? ?? const []))
            if (t is Map) ToolbarItem.fromJson(Map<String, Object?>.from(t))
        ],
        quickMenu: [for (final q in (j['quick'] as List? ?? const [])) '$q'].take(8).toList(),
        panels: [
          for (final p in (j['panels'] as List? ?? const []))
            if (p is Map) PanelState.fromJson(Map<String, Object?>.from(p))
        ],
        uiScale: ((j['scale'] as num?)?.toDouble() ?? 1).clamp(minScale, maxScale),
        handedness: Handedness.values.firstWhere((h) => h.name == j['hand'],
            orElse: () => Handedness.right),
      );
}

class WorkspacePresets {
  static const _all = [
    'brush', 'eraser', 'smudge', 'fill', 'gradient', 'shape', 'text',
    'selection', 'lasso', 'transform', 'eyedropper', 'guide', 'hand', 'zoom'
  ];

  static WorkspaceLayout _make(String name, List<String> shown, List<String> quick,
      List<String> panels,
      {double scale = 1.0}) =>
      WorkspaceLayout(
        name: name,
        toolbar: [for (final t in _all) ToolbarItem(t, visible: shown.contains(t))],
        quickMenu: quick,
        panels: [
          for (var i = 0; i < panels.length; i++)
            PanelState(panels[i], dock: i.isEven ? PanelDock.right : PanelDock.left),
        ],
        uiScale: scale,
      );

  static final Map<String, WorkspaceLayout> builtIn = {
    'Beginner': _make('Beginner',
        ['brush', 'eraser', 'fill', 'eyedropper', 'hand', 'zoom'],
        ['brush', 'eraser', 'fill'], ['layers', 'color'], scale: 1.15),
    'Sketching': _make('Sketching',
        ['brush', 'eraser', 'selection', 'transform', 'guide', 'hand', 'zoom'],
        ['brush', 'eraser', 'guide', 'transform'], ['layers', 'navigator']),
    'Painting': _make('Painting',
        ['brush', 'eraser', 'smudge', 'fill', 'gradient', 'eyedropper', 'selection', 'hand', 'zoom'],
        ['brush', 'smudge', 'eyedropper', 'eraser'], ['color', 'layers', 'brushes']),
    'Illustration': _make('Illustration', _all,
        ['brush', 'eraser', 'fill', 'selection', 'transform'], ['layers', 'color', 'navigator']),
    'Manga': _make('Manga',
        ['brush', 'eraser', 'shape', 'text', 'selection', 'guide', 'fill', 'hand', 'zoom'],
        ['brush', 'eraser', 'shape', 'text'], ['layers', 'pages']),
    'Professional': _make('Professional', _all,
        ['brush', 'eraser', 'fill', 'selection', 'transform', 'eyedropper', 'guide', 'text'],
        ['layers', 'color', 'navigator', 'brushes']),
  };

  static WorkspaceLayout? named(String n) => builtIn[n];
}

/// Navigator maths: maps the document viewport into a thumbnail.
class NavigatorMath {
  const NavigatorMath(this.docW, this.docH, this.thumbW, this.thumbH);
  final double docW, docH, thumbW, thumbH;

  double get scale => math.min(thumbW / docW, thumbH / docH);

  /// Visible document rect → thumbnail rect (l,t,w,h).
  (double, double, double, double) viewportRect({
    required double viewW,
    required double viewH,
    required double zoom,
    required double panX,
    required double panY,
  }) {
    // pan = document-space top-left of the view.
    final w = (viewW / zoom).clamp(0.0, docW);
    final h = (viewH / zoom).clamp(0.0, docH);
    final s = scale;
    return (panX * s, panY * s, w * s, h * s);
  }

  /// Thumbnail tap → document-space pan centred there.
  (double, double) panForTap(double tx, double ty,
      {required double viewW, required double viewH, required double zoom}) {
    final s = scale;
    final cx = tx / s, cy = ty / s;
    final px = (cx - viewW / zoom / 2).clamp(0.0, math.max(0.0, docW - viewW / zoom));
    final py = (cy - viewH / zoom / 2).clamp(0.0, math.max(0.0, docH - viewH / zoom));
    return (px, py);
  }

  static double fitZoom(double docW, double docH, double viewW, double viewH,
          {double margin = 0.95}) =>
      math.min(viewW / docW, viewH / docH) * margin;

  /// Pixel view is available when each document pixel covers >= 4 screen px.
  static bool pixelViewActive(double zoom, double devicePixelRatio) =>
      zoom * devicePixelRatio >= 4;
}

enum ViewAid { none, grayscale, outline, alpha }

class CanvasViewState {
  const CanvasViewState({this.flipH = false, this.flipV = false, this.aid = ViewAid.none});
  final bool flipH, flipV;
  final ViewAid aid;
  CanvasViewState toggleFlipH() => CanvasViewState(flipH: !flipH, flipV: flipV, aid: aid);
  CanvasViewState toggleFlipV() => CanvasViewState(flipH: flipH, flipV: !flipV, aid: aid);
  CanvasViewState withAid(ViewAid a) =>
      CanvasViewState(flipH: flipH, flipV: flipV, aid: a == aid ? ViewAid.none : a);

  /// Preview-only value check: Rec.709 luma of ARGB. Never touches pixels.
  static int grayscaleArgb(int argb) {
    final r = (argb >> 16) & 0xFF, g = (argb >> 8) & 0xFF, b = argb & 0xFF;
    final y = (0.2126 * r + 0.7152 * g + 0.0722 * b).round().clamp(0, 255);
    return (argb & 0xFF000000) | (y << 16) | (y << 8) | y;
  }

  /// Preview-only alpha view: opaque grey of the pixel's alpha.
  static int alphaArgb(int argb) {
    final a = (argb >> 24) & 0xFF;
    return 0xFF000000 | (a << 16) | (a << 8) | a;
  }
}

class ViewBookmark {
  const ViewBookmark(this.name, this.zoom, this.panX, this.panY, {this.rotationDeg = 0});
  final String name;
  final double zoom, panX, panY, rotationDeg;
  Map<String, Object?> toJson() =>
      {'n': name, 'z': zoom, 'x': panX, 'y': panY, 'r': rotationDeg};
  static ViewBookmark fromJson(Map<String, Object?> j) => ViewBookmark(
      '${j['n']}', (j['z'] as num?)?.toDouble() ?? 1, (j['x'] as num?)?.toDouble() ?? 0,
      (j['y'] as num?)?.toDouble() ?? 0, rotationDeg: (j['r'] as num?)?.toDouble() ?? 0);
}

class BookmarkList {
  BookmarkList([Iterable<ViewBookmark> items = const []]) : _items = List.of(items);
  final List<ViewBookmark> _items;
  static const maxItems = 50;
  List<ViewBookmark> get items => List.unmodifiable(_items);
  bool add(ViewBookmark b) {
    if (_items.length >= maxItems || b.name.trim().isEmpty) return false;
    _items.removeWhere((e) => e.name == b.name);
    _items.add(b);
    return true;
  }
  void remove(String name) => _items.removeWhere((e) => e.name == name);
  ViewBookmark? find(String name) {
    for (final b in _items) {
      if (b.name == name) return b;
    }
    return null;
  }
  List<Object?> toJson() => [for (final b in _items) b.toJson()];
  static BookmarkList fromJson(List<Object?> j) => BookmarkList([
        for (final e in j) if (e is Map) ViewBookmark.fromJson(Map<String, Object?>.from(e))
      ]);
}

// ---- 7.5.8 shortcuts, gestures, notes ------------------------------------

class ShortcutKey {
  const ShortcutKey(this.key, {this.ctrl = false, this.shift = false, this.alt = false});
  final String key; // lower-case
  final bool ctrl, shift, alt;
  String get label =>
      [if (ctrl) 'Ctrl', if (shift) 'Shift', if (alt) 'Alt', key.toUpperCase()].join('+');
  @override
  bool operator ==(Object o) =>
      o is ShortcutKey && o.key == key && o.ctrl == ctrl && o.shift == shift && o.alt == alt;
  @override
  int get hashCode => Object.hash(key, ctrl, shift, alt);
  static ShortcutKey? parse(String s) {
    final parts = s.split('+').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    if (parts.isEmpty) return null;
    var ctrl = false, shift = false, alt = false;
    for (final p in parts.take(parts.length - 1)) {
      switch (p.toLowerCase()) {
        case 'ctrl': ctrl = true;
        case 'shift': shift = true;
        case 'alt': alt = true;
        default: return null;
      }
    }
    return ShortcutKey(parts.last.toLowerCase(), ctrl: ctrl, shift: shift, alt: alt);
  }
}

class ShortcutMap {
  ShortcutMap([Map<ShortcutKey, String>? defaults]) {
    if (defaults != null) _map.addAll(defaults);
  }
  final Map<ShortcutKey, String> _map = {};

  static ShortcutMap standard() => ShortcutMap({
        const ShortcutKey('z', ctrl: true): 'undo',
        const ShortcutKey('z', ctrl: true, shift: true): 'redo',
        const ShortcutKey('b'): 'tool.brush',
        const ShortcutKey('e'): 'tool.eraser',
        const ShortcutKey('g'): 'tool.fill',
        const ShortcutKey('i'): 'tool.eyedropper',
        const ShortcutKey('v'): 'tool.transform',
        const ShortcutKey('s', ctrl: true): 'save',
      });

  String? actionFor(ShortcutKey k) => _map[k];
  ShortcutKey? keyFor(String action) {
    for (final e in _map.entries) {
      if (e.value == action) return e.key;
    }
    return null;
  }

  /// Returns the action that was displaced when [key] was already taken
  /// (so the UI can warn), or null.
  String? bind(ShortcutKey key, String action) {
    final old = _map[key];
    _map.removeWhere((_, v) => v == action);
    _map[key] = action;
    return old == action ? null : old;
  }

  void unbind(String action) => _map.removeWhere((_, v) => v == action);
  Map<String, String> toJson() => {for (final e in _map.entries) e.key.label: e.value};
  static ShortcutMap fromJson(Map<String, Object?> j) {
    final m = ShortcutMap();
    for (final e in j.entries) {
      final k = ShortcutKey.parse(e.key);
      if (k != null && e.value is String) m._map[k] = e.value as String;
    }
    return m;
  }
}

/// Temporary tool switching: hold a key → tool B, release → back to A.
class TemporaryToolSwitch {
  String current;
  String? _saved;
  TemporaryToolSwitch(this.current);
  void hold(String tool) {
    _saved ??= current;
    current = tool;
  }
  void release() {
    if (_saved != null) {
      current = _saved!;
      _saved = null;
    }
  }
  bool get active => _saved != null;
}

enum GestureAction { none, undo, redo, brushSize, brushOpacity, zoom, rotate, quickMenu, eyedropper }

class GestureMap {
  GestureMap([Map<String, GestureAction>? m])
      : _m = {
          'twoFingerTap': GestureAction.undo,
          'threeFingerTap': GestureAction.redo,
          'twoFingerPinch': GestureAction.zoom,
          'twoFingerTwist': GestureAction.rotate,
          'longPress': GestureAction.eyedropper,
          ...?m,
        };
  final Map<String, GestureAction> _m;
  GestureAction of(String gesture) => _m[gesture] ?? GestureAction.none;
  void set(String gesture, GestureAction a) => _m[gesture] = a;
  Map<String, String> toJson() => {for (final e in _m.entries) e.key: e.value.name};
  static GestureMap fromJson(Map<String, Object?> j) => GestureMap({
        for (final e in j.entries)
          e.key: GestureAction.values.firstWhere((a) => a.name == e.value,
              orElse: () => GestureAction.none)
      });

  /// Drag-based brush size/opacity: dx → size (log scale), dy → opacity.
  static double dragSize(double size, double dx, {double min = 1, double max = 500}) =>
      (size * math.pow(1.01, dx)).clamp(min, max).toDouble();
  static double dragOpacity(double opacity, double dy) =>
      (opacity - dy / 300).clamp(0.0, 1.0);
}

/// Undo history slider: maps slider 0..n to a position in the history.
class HistorySlider {
  HistorySlider(this.total, this.position);
  final int total; // number of undo steps recorded
  int position; // 0 = original, total = latest
  int clampTo(int v) => v.clamp(0, total);
  /// Number of undo (negative) / redo (positive) operations to reach [target].
  int stepsTo(int target) => clampTo(target) - position;
}

class ProjectNotes {
  static const maxChars = 20000;
  String text;
  ProjectNotes([this.text = '']);
  bool set(String v) {
    if (v.length > maxChars) return false;
    text = v;
    return true;
  }
  Map<String, Object?> toJson() => {'text': text};
  static ProjectNotes fromJson(Map<String, Object?> j) {
    final t = '${j['text'] ?? ''}';
    return ProjectNotes(t.length > maxChars ? t.substring(0, maxChars) : t);
  }
}
