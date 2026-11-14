import 'dart:math' as math;

import 'guides_selection.dart';

/// Phase 7.5.8 — editable Bezier paths and paragraph layout (pure Dart).

enum AnchorKind { corner, smooth }

class Anchor {
  Anchor(this.pos, {Pt? handleIn, Pt? handleOut, this.kind = AnchorKind.corner})
      : handleIn = handleIn ?? pos,
        handleOut = handleOut ?? pos;
  Pt pos, handleIn, handleOut; // absolute handle positions
  AnchorKind kind;

  /// Moves the out handle; smooth anchors mirror the in handle's direction
  /// (keeps its own length).
  void moveHandleOut(Pt to) {
    handleOut = to;
    if (kind == AnchorKind.smooth) {
      final inLen = handleIn.distanceTo(pos);
      final dx = pos.x - to.x, dy = pos.y - to.y;
      final l = math.sqrt(dx * dx + dy * dy);
      if (l > 1e-9) handleIn = Pt(pos.x + dx / l * inLen, pos.y + dy / l * inLen);
    }
  }

  void moveHandleIn(Pt to) {
    handleIn = to;
    if (kind == AnchorKind.smooth) {
      final outLen = handleOut.distanceTo(pos);
      final dx = pos.x - to.x, dy = pos.y - to.y;
      final l = math.sqrt(dx * dx + dy * dy);
      if (l > 1e-9) handleOut = Pt(pos.x + dx / l * outLen, pos.y + dy / l * outLen);
    }
  }

  void translate(double dx, double dy) {
    pos = Pt(pos.x + dx, pos.y + dy);
    handleIn = Pt(handleIn.x + dx, handleIn.y + dy);
    handleOut = Pt(handleOut.x + dx, handleOut.y + dy);
  }

  Map<String, Object?> toJson() => {
        'p': [pos.x, pos.y], 'i': [handleIn.x, handleIn.y], 'o': [handleOut.x, handleOut.y],
        'k': kind.name,
      };
  static Anchor fromJson(Map<String, Object?> j) {
    Pt pt(Object? v) {
      if (v is List && v.length == 2 && v[0] is num && v[1] is num) {
        return Pt((v[0] as num).toDouble(), (v[1] as num).toDouble());
      }
      throw const FormatException('bad point');
    }
    return Anchor(pt(j['p']),
        handleIn: pt(j['i']), handleOut: pt(j['o']),
        kind: AnchorKind.values.firstWhere((k) => k.name == j['k'], orElse: () => AnchorKind.corner));
  }
}

class PathStyle {
  const PathStyle({this.fill, this.stroke, this.strokeWidth = 2, this.dash = const [],
      this.round = true});
  final int? fill, stroke; // ARGB; null = none
  final double strokeWidth;
  final List<double> dash;
  final bool round;
  Map<String, Object?> toJson() =>
      {'fill': fill, 'stroke': stroke, 'w': strokeWidth, 'dash': dash, 'round': round};
  static PathStyle fromJson(Map<String, Object?> j) => PathStyle(
      fill: j['fill'] as int?, stroke: j['stroke'] as int?,
      strokeWidth: ((j['w'] as num?)?.toDouble() ?? 2).clamp(0.0, 500.0),
      dash: [for (final d in (j['dash'] as List? ?? const [])) if (d is num && d > 0) d.toDouble()],
      round: j['round'] != false);
}

class VectorPath {
  VectorPath({List<Anchor>? anchors, this.closed = false, this.style = const PathStyle()})
      : anchors = anchors ?? [];
  final List<Anchor> anchors;
  bool closed;
  PathStyle style;

  static const maxAnchors = 2000;

  bool add(Anchor a) {
    if (anchors.length >= maxAnchors) return false;
    anchors.add(a);
    return true;
  }

  void deleteAnchor(int i) {
    if (i >= 0 && i < anchors.length) anchors.removeAt(i);
  }

  /// Index of the anchor within [radius] of p, or -1.
  int hitAnchor(Pt p, double radius) {
    var best = -1;
    var bestD = radius;
    for (var i = 0; i < anchors.length; i++) {
      final d = anchors[i].pos.distanceTo(p);
      if (d <= bestD) {
        bestD = d;
        best = i;
      }
    }
    return best;
  }

  /// Splits segment [seg] (between anchor seg and seg+1) at t using de
  /// Casteljau so the curve shape is unchanged.
  void insertAnchor(int seg, double t) {
    final n = anchors.length;
    if (seg < 0 || seg >= (closed ? n : n - 1)) return;
    final a = anchors[seg], b = anchors[(seg + 1) % n];
    Pt l(Pt p, Pt q) => Pt(p.x + (q.x - p.x) * t, p.y + (q.y - p.y) * t);
    final p01 = l(a.pos, a.handleOut), p12 = l(a.handleOut, b.handleIn), p23 = l(b.handleIn, b.pos);
    final p012 = l(p01, p12), p123 = l(p12, p23);
    final mid = l(p012, p123);
    a.handleOut = p01;
    b.handleIn = p23;
    final na = Anchor(mid, handleIn: p012, handleOut: p123, kind: AnchorKind.smooth);
    anchors.insert(seg + 1, na);
  }

  List<Pt> flatten({int steps = 20}) {
    final out = <Pt>[];
    if (anchors.isEmpty) return out;
    final n = anchors.length;
    final segs = closed ? n : n - 1;
    for (var i = 0; i < segs; i++) {
      final a = anchors[i], b = anchors[(i + 1) % n];
      final pts = flattenCubic(a.pos, a.handleOut, b.handleIn, b.pos, steps: steps);
      out.addAll(out.isEmpty ? pts : pts.skip(1));
    }
    if (segs == 0) out.add(anchors.first.pos);
    return out;
  }

  double get length {
    final f = flatten();
    var s = 0.0;
    for (var i = 1; i < f.length; i++) {
      s += f[i].distanceTo(f[i - 1]);
    }
    return s;
  }

  Map<String, Object?> toJson() => {
        'anchors': [for (final a in anchors) a.toJson()],
        'closed': closed,
        'style': style.toJson(),
      };

  static VectorPath fromJson(Map<String, Object?> j) {
    final list = j['anchors'];
    if (list is! List || list.length > maxAnchors) throw const FormatException('bad anchors');
    return VectorPath(
      anchors: [for (final a in list) Anchor.fromJson(Map<String, Object?>.from(a as Map))],
      closed: j['closed'] == true,
      style: j['style'] is Map
          ? PathStyle.fromJson(Map<String, Object?>.from(j['style'] as Map))
          : const PathStyle(),
    );
  }
}

// -------------------------------------------------------------- paragraphs

enum ParaAlign { left, center, right, justify }

class ParagraphStyle {
  const ParagraphStyle({
    this.align = ParaAlign.left,
    this.firstLineIndent = 0,
    this.spaceBefore = 0,
    this.spaceAfter = 0,
    this.lineHeight = 1.2,
    this.width = 300,
  });
  final ParaAlign align;
  final double firstLineIndent, spaceBefore, spaceAfter, lineHeight, width;
}

typedef MeasureText = double Function(String s);

class ParagraphLayout {
  /// Greedy word-wrap using an injected measure function (so tests don't need
  /// a text engine). Words longer than the line are split by characters.
  /// Lines per paragraph; paragraphs separated by '\n'.
  static List<List<String>> wrap(String text, ParagraphStyle st, MeasureText measure) {
    final out = <List<String>>[];
    for (final para in text.split('\n')) {
      final lines = <String>[];
      var cur = '';
      var first = true;
      double avail() => st.width - (first ? st.firstLineIndent : 0);
      for (final word in para.split(' ')) {
        final trial = cur.isEmpty ? word : '$cur $word';
        if (measure(trial) <= avail()) {
          cur = trial;
          continue;
        }
        if (cur.isNotEmpty) {
          lines.add(cur);
          first = false;
          cur = '';
        }
        var w = word;
        while (measure(w) > avail() && w.length > 1) {
          var k = w.length - 1;
          while (k > 1 && measure(w.substring(0, k)) > avail()) {
            k--;
          }
          lines.add(w.substring(0, k));
          first = false;
          w = w.substring(k);
        }
        cur = w;
      }
      lines.add(cur);
      out.add(lines);
    }
    return out;
  }

  /// X offset of a line for alignment (justify is handled by the painter).
  static double lineOffset(ParagraphStyle st, double lineWidth, bool firstLine) {
    final indent = firstLine ? st.firstLineIndent : 0.0;
    switch (st.align) {
      case ParaAlign.left:
      case ParaAlign.justify:
        return indent;
      case ParaAlign.center:
        return (st.width - lineWidth) / 2;
      case ParaAlign.right:
        return st.width - lineWidth;
    }
  }

  static double totalHeight(List<List<String>> paras, ParagraphStyle st, double fontSize) {
    var h = 0.0;
    for (final p in paras) {
      h += st.spaceBefore + p.length * fontSize * st.lineHeight + st.spaceAfter;
    }
    return h;
  }
}
