import 'dart:math' as math;
import 'dart:ui';

import 'comic_elements.dart';
import 'text_model.dart';

export 'comic_elements.dart';
export 'text_model.dart';

/// Physical page set-up. Everything is stored in **pixels at [dpi]**; the
/// trim box is the finished page, [bleedPx] extends outward on every side,
/// and [marginPx] is the safe area inside the trim box.
class ComicPageSpec {
  const ComicPageSpec({
    required this.widthPx,
    required this.heightPx,
    this.dpi = 300,
    this.marginPx = 90,
    this.bleedPx = 38,
    this.name = 'Custom',
  });

  static const maxSidePx = 12000;
  static const minSidePx = 200;

  final int widthPx, heightPx;
  final int dpi;
  final int marginPx;
  final int bleedPx;
  final String name;

  /// Size from millimetres at [dpi].
  factory ComicPageSpec.fromMm(double wMm, double hMm,
          {int dpi = 300, double marginMm = 10, double bleedMm = 3, String name = 'Custom'}) =>
      ComicPageSpec(
        widthPx: (wMm / 25.4 * dpi).round(),
        heightPx: (hMm / 25.4 * dpi).round(),
        dpi: dpi,
        marginPx: (marginMm / 25.4 * dpi).round(),
        bleedPx: (bleedMm / 25.4 * dpi).round(),
        name: name,
      );

  static ComicPageSpec b5Manga({int dpi = 300}) => ComicPageSpec.fromMm(182, 257, dpi: dpi, name: 'B5 manga');
  static ComicPageSpec a4({int dpi = 300}) => ComicPageSpec.fromMm(210, 297, dpi: dpi, name: 'A4');
  static ComicPageSpec usComic({int dpi = 300}) =>
      ComicPageSpec.fromMm(168.3, 260.4, dpi: dpi, name: 'US comic (6.625×10.25 in)');
  static ComicPageSpec webtoon() => const ComicPageSpec(
      widthPx: 800, heightPx: 1280, dpi: 72, marginPx: 20, bleedPx: 0, name: 'Webtoon panel');

  List<String> validate() {
    final e = <String>[];
    if (widthPx < minSidePx || heightPx < minSidePx) e.add('The page is too small (minimum $minSidePx px per side).');
    if (widthPx + 2 * bleedPx > maxSidePx || heightPx + 2 * bleedPx > maxSidePx) {
      e.add('The page including bleed may not exceed $maxSidePx px per side.');
    }
    if (dpi < 72 || dpi > 1200) e.add('DPI must be between 72 and 1200.');
    if (marginPx < 0 || marginPx * 2 >= math.min(widthPx, heightPx)) e.add('The margin is too large for this page.');
    if (bleedPx < 0 || bleedPx > 400) e.add('Bleed must be between 0 and 400 px.');
    return e;
  }

  /// Full canvas including bleed. Origin (0,0) is the top-left of the bleed.
  Size get canvasSize => Size((widthPx + 2 * bleedPx).toDouble(), (heightPx + 2 * bleedPx).toDouble());
  Rect get bleedRect => Offset.zero & canvasSize;
  Rect get trimRect => Rect.fromLTWH(bleedPx.toDouble(), bleedPx.toDouble(), widthPx.toDouble(), heightPx.toDouble());
  Rect get safeRect => trimRect.deflate(marginPx.toDouble());

  double get widthInches => widthPx / dpi;
  double get heightInches => heightPx / dpi;

  Map<String, Object?> toJson() => {'w': widthPx, 'h': heightPx, 'dpi': dpi, 'm': marginPx, 'b': bleedPx, 'name': name};

  factory ComicPageSpec.fromJson(Object? j) {
    if (j is! Map) throw const ComicException('Page set-up is missing.');
    int n(String k, int f) => j[k] is num && (j[k] as num).isFinite ? (j[k] as num).round() : f;
    final spec = ComicPageSpec(
      widthPx: n('w', 0),
      heightPx: n('h', 0),
      dpi: n('dpi', 300),
      marginPx: n('m', 0),
      bleedPx: n('b', 0),
      name: j['name'] is String ? j['name'] as String : 'Custom',
    );
    final errors = spec.validate();
    if (errors.isNotEmpty) throw ComicException(errors.first);
    return spec;
  }

  @override
  bool operator ==(Object o) => o is ComicPageSpec && o.toJson().toString() == toJson().toString();
  @override
  int get hashCode => toJson().toString().hashCode;
}

/// A panel is an editable polygon (4 corners by default, so slanted panels
/// work). Content elements assigned to it are clipped to the polygon.
class Panel {
  Panel({
    required this.id,
    required List<Offset> corners,
    this.borderWidth = 4,
    this.borderArgb = 0xFF000000,
    this.fillArgb = 0x00FFFFFF,
    this.clipContent = true,
  }) : corners = List.unmodifiable(corners) {
    if (corners.length < 3 || corners.length > 12) {
      throw const ComicException('A panel needs 3 to 12 corners.');
    }
    for (final c in corners) {
      if (!c.dx.isFinite || !c.dy.isFinite) throw const ComicException('Panel corners must be finite.');
    }
  }

  final String id;
  final List<Offset> corners;
  final double borderWidth;
  final int borderArgb;
  final int fillArgb;
  final bool clipContent;

  factory Panel.rect(String id, Rect r, {double borderWidth = 4}) => Panel(
        id: id,
        corners: [r.topLeft, r.topRight, r.bottomRight, r.bottomLeft],
        borderWidth: borderWidth,
      );

  Path get path => Path()..addPolygon(corners, true);
  Rect get bounds => path.getBounds();

  bool contains(Offset p) => path.contains(p);

  Panel copyWith({List<Offset>? corners, double? borderWidth, int? borderArgb, int? fillArgb, bool? clipContent}) => Panel(
        id: id,
        corners: corners ?? this.corners,
        borderWidth: borderWidth ?? this.borderWidth,
        borderArgb: borderArgb ?? this.borderArgb,
        fillArgb: fillArgb ?? this.fillArgb,
        clipContent: clipContent ?? this.clipContent,
      );

  Panel moveCorner(int index, Offset to) {
    if (index < 0 || index >= corners.length) throw const ComicException('No such panel corner.');
    return copyWith(corners: [...corners]..[index] = to);
  }

  Panel translate(Offset d) => copyWith(corners: [for (final c in corners) c + d]);

  Map<String, Object?> toJson() => {
        'id': id,
        'pts': [for (final c in corners) [c.dx, c.dy]],
        'bw': borderWidth,
        'bc': borderArgb,
        if (fillArgb != 0x00FFFFFF) 'fill': fillArgb,
        if (!clipContent) 'clip': false,
      };

  factory Panel.fromJson(Object? j) {
    if (j is! Map || j['id'] is! String || j['pts'] is! List) throw const ComicException('Invalid panel.');
    final pts = <Offset>[];
    for (final p in (j['pts'] as List).take(13)) {
      if (p is List && p.length == 2 && p[0] is num && p[1] is num) {
        pts.add(Offset((p[0] as num).toDouble(), (p[1] as num).toDouble()));
      } else {
        throw const ComicException('Invalid panel corner.');
      }
    }
    return Panel(
      id: j['id'] as String,
      corners: pts,
      borderWidth: j['bw'] is num ? (j['bw'] as num).toDouble().clamp(0, 60).toDouble() : 4,
      borderArgb: j['bc'] is int ? j['bc'] as int : 0xFF000000,
      fillArgb: j['fill'] is int ? j['fill'] as int : 0x00FFFFFF,
      clipContent: j['clip'] != false,
    );
  }
}

/// A named layout, defined on the unit square, applied to a page area.
class PanelTemplate {
  const PanelTemplate(this.id, this.name, this.cells);
  final String id;
  final String name;

  /// Each cell is a rectangle in unit coordinates (l, t, r, b).
  final List<(double, double, double, double)> cells;

  /// Creates panels inside [area] separated by [gutter] px. Right-to-left
  /// reading (manga) mirrors the cell order so numbering starts top-right.
  List<Panel> instantiate(Rect area, {double gutter = 24, bool rightToLeft = true, String idPrefix = 'p'}) {
    final out = <Panel>[];
    final cells = [...this.cells];
    if (rightToLeft) {
      cells.sort((a, b) {
        final rowA = (a.$2 * 1000).round(), rowB = (b.$2 * 1000).round();
        return rowA != rowB ? rowA.compareTo(rowB) : b.$1.compareTo(a.$1);
      });
    }
    for (var i = 0; i < cells.length; i++) {
      final c = cells[i];
      final r = Rect.fromLTRB(
        area.left + c.$1 * area.width + (c.$1 > 0 ? gutter / 2 : 0),
        area.top + c.$2 * area.height + (c.$2 > 0 ? gutter / 2 : 0),
        area.left + c.$3 * area.width - (c.$3 < 1 ? gutter / 2 : 0),
        area.top + c.$4 * area.height - (c.$4 < 1 ? gutter / 2 : 0),
      );
      out.add(Panel.rect('$idPrefix${i + 1}', r));
    }
    return out;
  }

  static const _third = 1 / 3, _half = 0.5;
  static const List<PanelTemplate> builtIn = [
    PanelTemplate('full', 'Full page', [(0, 0, 1, 1)]),
    PanelTemplate('two-rows', 'Two rows', [(0, 0, 1, _half), (0, _half, 1, 1)]),
    PanelTemplate('three-rows', 'Three rows', [(0, 0, 1, _third), (0, _third, 1, 2 * _third), (0, 2 * _third, 1, 1)]),
    PanelTemplate('grid-2x2', '2 × 2 grid', [(0, 0, _half, _half), (_half, 0, 1, _half), (0, _half, _half, 1), (_half, _half, 1, 1)]),
    PanelTemplate('grid-2x3', '2 × 3 grid', [
      (0, 0, _half, _third), (_half, 0, 1, _third),
      (0, _third, _half, 2 * _third), (_half, _third, 1, 2 * _third),
      (0, 2 * _third, _half, 1), (_half, 2 * _third, 1, 1),
    ]),
    PanelTemplate('manga-classic', 'Manga classic', [
      (0, 0, 1, 0.3), (0, 0.3, 0.55, 0.65), (0.55, 0.3, 1, 0.65), (0, 0.65, 0.4, 1), (0.4, 0.65, 1, 1),
    ]),
    PanelTemplate('hero-top', 'Hero + strip', [(0, 0, 1, 0.6), (0, 0.6, _third, 1), (_third, 0.6, 2 * _third, 1), (2 * _third, 0.6, 1, 1)]),
  ];

  static PanelTemplate? byId(String id) {
    for (final t in builtIn) {
      if (t.id == id) return t;
    }
    return null;
  }
}

/// Splits a rectangular panel into two along an axis. Used to build custom
/// layouts one cut at a time.
abstract final class PanelOps {
  static (Panel, Panel) split(Panel panel, {required bool vertical, double ratio = 0.5, double gutter = 24, required String newId}) {
    final b = panel.bounds;
    final r = ratio.clamp(0.1, 0.9).toDouble();
    if (vertical) {
      final x = b.left + b.width * r;
      return (
        Panel.rect(panel.id, Rect.fromLTRB(b.left, b.top, x - gutter / 2, b.bottom), borderWidth: panel.borderWidth),
        Panel.rect(newId, Rect.fromLTRB(x + gutter / 2, b.top, b.right, b.bottom), borderWidth: panel.borderWidth),
      );
    }
    final y = b.top + b.height * r;
    return (
      Panel.rect(panel.id, Rect.fromLTRB(b.left, b.top, b.right, y - gutter / 2), borderWidth: panel.borderWidth),
      Panel.rect(newId, Rect.fromLTRB(b.left, y + gutter / 2, b.right, b.bottom), borderWidth: panel.borderWidth),
    );
  }

  /// Fraction of [a] that overlaps [b]'s bounding box (rough check used to
  /// warn about overlapping panels).
  static double overlap(Panel a, Panel b) {
    final i = a.bounds.intersect(b.bounds);
    if (i.width <= 0 || i.height <= 0) return 0;
    return i.width * i.height / (a.bounds.width * a.bounds.height);
  }
}

class ComicPage {
  ComicPage({
    required this.id,
    List<Panel>? panels,
    List<ComicElement>? elements,
    this.name = '',
    this.spec,
  })  : panels = panels ?? <Panel>[],
        elements = elements ?? <ComicElement>[];

  final String id;
  final String name;

  /// Optional per-page override (e.g. a double-page spread); null = use the
  /// document's spec.
  final ComicPageSpec? spec;
  final List<Panel> panels;
  final List<ComicElement> elements;

  static const maxPanels = 40;
  static const maxElements = 500;

  Panel? panelById(String id) {
    for (final p in panels) {
      if (p.id == id) return p;
    }
    return null;
  }

  ComicElement? elementById(String id) {
    for (final e in elements) {
      if (e.id == id) return e;
    }
    return null;
  }

  String nextPanelId() {
    var n = panels.length + 1;
    while (panels.any((p) => p.id == 'p$n')) {
      n++;
    }
    return 'p$n';
  }

  String nextElementId() {
    var n = elements.length + 1;
    while (elements.any((e) => e.id == 'e$n')) {
      n++;
    }
    return 'e$n';
  }

  ComicPage copy({String? id}) => ComicPage(
        id: id ?? this.id,
        name: name,
        spec: spec,
        panels: List.of(panels),
        elements: List.of(elements),
      );

  /// Which panel a point falls in (topmost first), or null.
  Panel? panelAt(Offset p) {
    for (final panel in panels.reversed) {
      if (panel.contains(p)) return panel;
    }
    return null;
  }

  Map<String, Object?> toJson() => {
        'id': id,
        if (name.isNotEmpty) 'name': name,
        if (spec != null) 'spec': spec!.toJson(),
        'panels': [for (final p in panels) p.toJson()],
        'elements': [for (final e in elements) e.toJson()],
      };

  factory ComicPage.fromJson(Object? j) {
    if (j is! Map || j['id'] is! String) throw const ComicException('Invalid page.');
    final rawPanels = j['panels'], rawEls = j['elements'];
    if (rawPanels is! List || rawEls is! List) throw const ComicException('Page content is missing.');
    if (rawPanels.length > maxPanels || rawEls.length > maxElements) {
      throw const ComicException('Page has too many panels or elements.');
    }
    final panels = [for (final p in rawPanels) Panel.fromJson(p)];
    final ids = <String>{};
    for (final p in panels) {
      if (!ids.add(p.id)) throw const ComicException('Duplicate panel id.');
    }
    final elements = [for (final e in rawEls) ComicElement.fromJson(e)];
    final eids = <String>{};
    for (final e in elements) {
      if (!eids.add(e.id)) throw const ComicException('Duplicate element id.');
      if (e.panelId != null && !ids.contains(e.panelId)) {
        throw const ComicException('An element refers to a panel that does not exist.');
      }
    }
    return ComicPage(
      id: j['id'] as String,
      name: j['name'] is String ? j['name'] as String : '',
      spec: j['spec'] == null ? null : ComicPageSpec.fromJson(j['spec']),
      panels: panels,
      elements: elements,
    );
  }
}

enum ReadingDirection { rightToLeft, leftToRight, vertical }

/// A multi-page comic/manga project. Deliberately a different type from the
/// single-canvas sketch document.
class ComicDocument {
  ComicDocument({
    required this.title,
    required this.spec,
    List<ComicPage>? pages,
    this.direction = ReadingDirection.rightToLeft,
    List<ImportedFont>? fonts,
  })  : pages = pages ?? <ComicPage>[],
        fonts = fonts ?? <ImportedFont>[] {
    final errors = spec.validate();
    if (errors.isNotEmpty) throw ComicException(errors.first);
  }

  static const format = 'artfoxel-comic';
  static const version = 1;
  static const maxPages = 400;

  String title;
  ComicPageSpec spec;
  ReadingDirection direction;
  final List<ComicPage> pages;
  final List<ImportedFont> fonts;
  int _nextPageNo = 1;

  factory ComicDocument.create({
    required String title,
    ComicPageSpec? spec,
    ReadingDirection direction = ReadingDirection.rightToLeft,
    PanelTemplate? template,
    int pages = 1,
  }) {
    final doc = ComicDocument(title: title, spec: spec ?? ComicPageSpec.b5Manga(), direction: direction);
    for (var i = 0; i < pages; i++) {
      doc.addPage(template: template);
    }
    return doc;
  }

  ComicPageSpec specFor(ComicPage p) => p.spec ?? spec;

  ComicPage addPage({PanelTemplate? template, int? at}) {
    if (pages.length >= maxPages) throw const ComicException('A comic can have at most $maxPages pages.');
    var n = _nextPageNo;
    while (pages.any((p) => p.id == 'page-$n')) {
      n++;
    }
    _nextPageNo = n + 1;
    final page = ComicPage(id: 'page-$n');
    if (template != null) {
      page.panels.addAll(template.instantiate(spec.safeRect, rightToLeft: direction == ReadingDirection.rightToLeft));
    }
    pages.insert((at ?? pages.length).clamp(0, pages.length), page);
    return page;
  }

  ComicPage duplicatePage(String id) {
    final i = pages.indexWhere((p) => p.id == id);
    if (i < 0) throw const ComicException('No such page.');
    if (pages.length >= maxPages) throw const ComicException('A comic can have at most $maxPages pages.');
    var n = _nextPageNo;
    while (pages.any((p) => p.id == 'page-$n')) {
      n++;
    }
    _nextPageNo = n + 1;
    final copy = pages[i].copy(id: 'page-$n');
    pages.insert(i + 1, copy);
    return copy;
  }

  void removePage(String id) {
    if (pages.length <= 1) throw const ComicException('A comic needs at least one page.');
    pages.removeWhere((p) => p.id == id);
  }

  void movePage(int from, int to) {
    if (from < 0 || from >= pages.length || to < 0 || to >= pages.length) throw const ComicException('Page position out of range.');
    pages.insert(to, pages.removeAt(from));
  }

  Map<String, Object?> toJson() => {
        'format': format,
        'version': version,
        'title': title,
        'spec': spec.toJson(),
        'dir': direction.name,
        'pages': [for (final p in pages) p.toJson()],
        if (fonts.isNotEmpty) 'fonts': [for (final f in fonts) f.toJson()],
      };

  factory ComicDocument.fromJson(Object? j) {
    if (j is! Map || j['format'] != format) throw const ComicException('This is not an ARTFOXEL comic file.');
    final v = j['version'];
    if (v is! int || v < 1) throw const ComicException('Unreadable comic version.');
    if (v > version) throw const ComicException('This comic was made with a newer version of ARTFOXEL.');
    final rawPages = j['pages'];
    if (rawPages is! List || rawPages.isEmpty) throw const ComicException('The comic has no pages.');
    if (rawPages.length > maxPages) throw const ComicException('Too many pages.');
    final dir = ReadingDirection.values.where((d) => d.name == j['dir']);
    final doc = ComicDocument(
      title: j['title'] is String ? j['title'] as String : 'Untitled',
      spec: ComicPageSpec.fromJson(j['spec']),
      direction: dir.isEmpty ? ReadingDirection.rightToLeft : dir.first,
      fonts: [if (j['fonts'] is List) for (final f in j['fonts'] as List) ImportedFont.fromJson(f)],
    );
    final ids = <String>{};
    for (final p in rawPages) {
      final page = ComicPage.fromJson(p);
      if (!ids.add(page.id)) throw const ComicException('Duplicate page id.');
      doc.pages.add(page);
    }
    return doc;
  }
}
