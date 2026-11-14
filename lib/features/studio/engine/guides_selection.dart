import 'dart:math' as math;
import 'dart:typed_data';

/// Phase 7.5.3 — guides, perspective grids and selection masks (pure Dart).

class Pt {
  const Pt(this.x, this.y);
  final double x, y;
  double distanceTo(Pt o) => math.sqrt((x - o.x) * (x - o.x) + (y - o.y) * (y - o.y));
  @override
  bool operator ==(Object o) => o is Pt && o.x == x && o.y == y;
  @override
  int get hashCode => Object.hash(x, y);
  @override
  String toString() => 'Pt($x,$y)';
}

// ---------------------------------------------------------------- snapping

/// Closest point to [p] on the infinite line through a→b.
Pt snapToLine(Pt p, Pt a, Pt b) {
  final dx = b.x - a.x, dy = b.y - a.y;
  final l2 = dx * dx + dy * dy;
  if (l2 < 1e-12) return a;
  final t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / l2;
  return Pt(a.x + dx * t, a.y + dy * t);
}

/// Parallel guide: line through [origin] with the direction of a→b.
Pt snapToParallel(Pt p, Pt origin, Pt a, Pt b) =>
    snapToLine(p, origin, Pt(origin.x + (b.x - a.x), origin.y + (b.y - a.y)));

/// Perpendicular guide: line through [origin] perpendicular to a→b.
Pt snapToPerpendicular(Pt p, Pt origin, Pt a, Pt b) =>
    snapToLine(p, origin, Pt(origin.x - (b.y - a.y), origin.y + (b.x - a.x)));

Pt snapToCircle(Pt p, Pt c, double r) {
  final d = p.distanceTo(c);
  if (d < 1e-9) return Pt(c.x + r, c.y);
  return Pt(c.x + (p.x - c.x) * r / d, c.y + (p.y - c.y) * r / d);
}

/// Ellipse with radii rx, ry rotated by [rot] radians. Uses an iterative
/// nearest-point search (accurate to ~0.01 px for typical sizes).
Pt snapToEllipse(Pt p, Pt c, double rx, double ry, {double rot = 0}) {
  final cs = math.cos(-rot), sn = math.sin(-rot);
  final lx = (p.x - c.x) * cs - (p.y - c.y) * sn;
  final ly = (p.x - c.x) * sn + (p.y - c.y) * cs;
  var best = 0.0, bestD = double.infinity;
  const n = 360;
  for (var i = 0; i < n; i++) {
    final t = 2 * math.pi * i / n;
    final d = _d2(lx, ly, rx * math.cos(t), ry * math.sin(t));
    if (d < bestD) {
      bestD = d;
      best = t;
    }
  }
  var lo = best - 2 * math.pi / n, hi = best + 2 * math.pi / n;
  for (var i = 0; i < 30; i++) {
    final m1 = lo + (hi - lo) / 3, m2 = hi - (hi - lo) / 3;
    final d1 = _d2(lx, ly, rx * math.cos(m1), ry * math.sin(m1));
    final d2 = _d2(lx, ly, rx * math.cos(m2), ry * math.sin(m2));
    if (d1 < d2) {
      hi = m2;
    } else {
      lo = m1;
    }
  }
  final t = (lo + hi) / 2;
  final ex = rx * math.cos(t), ey = ry * math.sin(t);
  final c2 = math.cos(rot), s2 = math.sin(rot);
  return Pt(c.x + ex * c2 - ey * s2, c.y + ex * s2 + ey * c2);
}

double _d2(double ax, double ay, double bx, double by) =>
    (ax - bx) * (ax - bx) + (ay - by) * (ay - by);

/// Circular arc from [startRad] sweeping [sweepRad]. Snaps to the circle
/// then clamps the angle to the arc range (nearest end if outside).
Pt snapToArc(Pt p, Pt c, double r, double startRad, double sweepRad) {
  var a = math.atan2(p.y - c.y, p.x - c.x);
  var rel = (a - startRad) % (2 * math.pi);
  if (rel < 0) rel += 2 * math.pi;
  final sweep = sweepRad.abs();
  final dir = sweepRad >= 0 ? 1.0 : -1.0;
  if (dir < 0) {
    rel = (2 * math.pi - rel) % (2 * math.pi);
  }
  if (rel > sweep) {
    // pick the nearer end
    final toEnd = rel - sweep, toStart = 2 * math.pi - rel;
    rel = toEnd < toStart ? sweep : 0;
  }
  final ang = startRad + dir * rel;
  return Pt(c.x + r * math.cos(ang), c.y + r * math.sin(ang));
}

/// Cubic Bezier flattening, used by the Bezier-pen guide and selection.
List<Pt> flattenCubic(Pt a, Pt b, Pt c, Pt d, {int steps = 24}) => [
      for (var i = 0; i <= steps; i++)
        () {
          final t = i / steps, u = 1 - t;
          return Pt(
            u * u * u * a.x + 3 * u * u * t * b.x + 3 * u * t * t * c.x + t * t * t * d.x,
            u * u * u * a.y + 3 * u * u * t * b.y + 3 * u * t * t * c.y + t * t * t * d.y,
          );
        }()
    ];

/// Snap to the closest point on a polyline (Bezier pen / polygon guide).
Pt snapToPolyline(Pt p, List<Pt> pts, {bool closed = false}) {
  if (pts.isEmpty) return p;
  if (pts.length == 1) return pts.first;
  Pt best = pts.first;
  var bestD = double.infinity;
  final n = closed ? pts.length : pts.length - 1;
  for (var i = 0; i < n; i++) {
    final a = pts[i], b = pts[(i + 1) % pts.length];
    final dx = b.x - a.x, dy = b.y - a.y;
    final l2 = dx * dx + dy * dy;
    final t = l2 < 1e-12 ? 0.0 : (((p.x - a.x) * dx + (p.y - a.y) * dy) / l2).clamp(0.0, 1.0);
    final q = Pt(a.x + dx * t, a.y + dy * t);
    final d = q.distanceTo(p);
    if (d < bestD) {
      bestD = d;
      best = q;
    }
  }
  return best;
}

/// Hatching guide: parallel lines at [angleRad] separated by [spacing],
/// clipped to the rect (0,0)-(w,h). Returns segments as [a,b] pairs.
List<(Pt, Pt)> hatchingLines(double w, double h, double angleRad, double spacing) {
  if (spacing < 1) spacing = 1;
  final dir = Pt(math.cos(angleRad), math.sin(angleRad));
  final nrm = Pt(-dir.y, dir.x);
  final diag = math.sqrt(w * w + h * h);
  final cx = w / 2, cy = h / 2;
  final out = <(Pt, Pt)>[];
  final count = (diag / spacing).ceil();
  for (var i = -count; i <= count; i++) {
    final ox = cx + nrm.x * i * spacing, oy = cy + nrm.y * i * spacing;
    final s = _clipLine(Pt(ox - dir.x * diag, oy - dir.y * diag),
        Pt(ox + dir.x * diag, oy + dir.y * diag), w, h);
    if (s != null) out.add(s);
  }
  return out;
}

(Pt, Pt)? _clipLine(Pt a, Pt b, double w, double h) {
  // Liang–Barsky
  var t0 = 0.0, t1 = 1.0;
  final dx = b.x - a.x, dy = b.y - a.y;
  bool clip(double p, double q) {
    if (p == 0) return q >= 0;
    final r = q / p;
    if (p < 0) {
      if (r > t1) return false;
      if (r > t0) t0 = r;
    } else {
      if (r < t0) return false;
      if (r < t1) t1 = r;
    }
    return true;
  }
  if (clip(-dx, a.x) && clip(dx, w - a.x) && clip(-dy, a.y) && clip(dy, h - a.y)) {
    return (Pt(a.x + t0 * dx, a.y + t0 * dy), Pt(a.x + t1 * dx, a.y + t1 * dy));
  }
  return null;
}

// -------------------------------------------------------------- perspective

enum GridKind { onePoint, twoPoint, threePoint, isometric, curvilinear }

/// Perspective grid with editable vanishing points and horizon.
class PerspectiveGrid {
  PerspectiveGrid({
    required this.kind,
    required this.width,
    required this.height,
    double? horizonY,
    List<Pt>? vanishing,
    this.density = 12,
  })  : horizonY = horizonY ?? height / 2,
        vanishing = vanishing ?? _defaults(kind, width, height, horizonY ?? height / 2);

  GridKind kind;
  final double width, height;
  double horizonY;
  final List<Pt> vanishing;
  int density;

  static List<Pt> _defaults(GridKind k, double w, double h, double hy) {
    switch (k) {
      case GridKind.onePoint:
        return [Pt(w / 2, hy)];
      case GridKind.twoPoint:
        return [Pt(-w * 0.5, hy), Pt(w * 1.5, hy)];
      case GridKind.threePoint:
        return [Pt(-w * 0.5, hy), Pt(w * 1.5, hy), Pt(w / 2, hy + h * 3)];
      case GridKind.isometric:
        return const []; // directions are fixed angles
      case GridKind.curvilinear:
        return [Pt(w / 2, hy)];
    }
  }

  /// Moving a horizon-bound point keeps it on the horizon; the 3rd point of
  /// a three-point grid is free (vertical VP).
  void moveVanishing(int index, Pt to) {
    if (index < 0 || index >= vanishing.length) return;
    final free = kind == GridKind.threePoint && index == 2;
    vanishing[index] = free ? to : Pt(to.x, horizonY);
  }

  void setHorizon(double y) {
    horizonY = y;
    for (var i = 0; i < vanishing.length; i++) {
      final free = kind == GridKind.threePoint && i == 2;
      if (!free) vanishing[i] = Pt(vanishing[i].x, y);
    }
  }

  /// Guide directions available for snapping at a given point, as unit vectors.
  List<Pt> directionsAt(Pt p) {
    if (kind == GridKind.isometric) {
      final r = [90.0, 30.0, 150.0].map((d) => d * math.pi / 180);
      return [for (final a in r) Pt(math.cos(a), math.sin(a))];
    }
    final out = <Pt>[];
    for (final v in vanishing) {
      final dx = v.x - p.x, dy = v.y - p.y;
      final l = math.sqrt(dx * dx + dy * dy);
      if (l > 1e-6) out.add(Pt(dx / l, dy / l));
    }
    if (kind == GridKind.onePoint || kind == GridKind.twoPoint) {
      out.add(const Pt(0, 1)); // verticals stay vertical
    }
    return out;
  }

  /// Snaps [p] (current pen position) to the guide line through [origin]
  /// (stroke start) whose direction is nearest to the pen's direction.
  Pt snap(Pt origin, Pt p) {
    if (kind == GridKind.curvilinear) {
      final c = vanishing.first;
      final d = p.distanceTo(c);
      final dOrigin = origin.distanceTo(c);
      // Near-radial strokes snap to the radius, otherwise to the circle.
      final rad = snapToLine(p, c, origin);
      final cir = snapToCircle(p, c, dOrigin);
      return rad.distanceTo(p) <= cir.distanceTo(p) && d > 1e-6 ? rad : cir;
    }
    final dirs = directionsAt(origin);
    if (dirs.isEmpty) return p;
    final mx = p.x - origin.x, my = p.y - origin.y;
    final ml = math.sqrt(mx * mx + my * my);
    if (ml < 1e-6) return origin;
    Pt best = dirs.first;
    var bestDot = -1.0;
    for (final d in dirs) {
      final dot = ((mx * d.x + my * d.y) / ml).abs();
      if (dot > bestDot) {
        bestDot = dot;
        best = d;
      }
    }
    return snapToLine(p, origin, Pt(origin.x + best.x, origin.y + best.y));
  }

  /// Visible grid lines (segments), count limited for rendering cost.
  List<(Pt, Pt)> lines() {
    final out = <(Pt, Pt)>[];
    final n = density.clamp(2, 60);
    if (kind == GridKind.isometric) {
      final step = width / n;
      for (final deg in [30.0, 150.0, 90.0]) {
        final lns = hatchingLines(width, height, deg * math.pi / 180, step);
        out.addAll(lns);
      }
      return out;
    }
    if (kind == GridKind.curvilinear) {
      final c = vanishing.first;
      final maxR = math.sqrt(width * width + height * height);
      for (var i = 1; i <= n; i++) {
        final r = maxR * i / n;
        const seg = 48;
        for (var k = 0; k < seg; k++) {
          final a0 = 2 * math.pi * k / seg, a1 = 2 * math.pi * (k + 1) / seg;
          out.add((Pt(c.x + r * math.cos(a0), c.y + r * math.sin(a0)),
              Pt(c.x + r * math.cos(a1), c.y + r * math.sin(a1))));
        }
      }
      for (var k = 0; k < n * 2; k++) {
        final a = math.pi * k / n;
        out.add((Pt(c.x - maxR * math.cos(a), c.y - maxR * math.sin(a)),
            Pt(c.x + maxR * math.cos(a), c.y + maxR * math.sin(a))));
      }
      return out;
    }
    for (final v in vanishing) {
      for (var i = 0; i < n; i++) {
        final t = (i + 0.5) / n;
        // fan of lines from the VP through points on the canvas border
        out.add((v, Pt(width * t, 0)));
        out.add((v, Pt(width * t, height)));
        out.add((v, Pt(0, height * t)));
        out.add((v, Pt(width, height * t)));
      }
    }
    out.add((Pt(0, horizonY), Pt(width, horizonY)));
    return out;
  }

  Map<String, Object?> toJson() => {
        'kind': kind.name,
        'w': width,
        'h': height,
        'hy': horizonY,
        'vp': [for (final v in vanishing) [v.x, v.y]],
        'density': density,
      };

  static PerspectiveGrid fromJson(Map<String, Object?> j) {
    final kind = GridKind.values.firstWhere((k) => k.name == j['kind'],
        orElse: () => GridKind.onePoint);
    final w = (j['w'] as num?)?.toDouble() ?? 1000;
    final h = (j['h'] as num?)?.toDouble() ?? 1000;
    final vps = <Pt>[
      for (final e in (j['vp'] as List? ?? const []))
        if (e is List && e.length == 2) Pt((e[0] as num).toDouble(), (e[1] as num).toDouble())
    ];
    return PerspectiveGrid(
      kind: kind,
      width: w,
      height: h,
      horizonY: (j['hy'] as num?)?.toDouble(),
      vanishing: vps.isEmpty ? null : vps,
      density: (j['density'] as num?)?.toInt() ?? 12,
    );
  }
}

// ---------------------------------------------------------------- selection

enum SelectionOp { replace, add, subtract, intersect }

/// 8-bit selection mask (0 = outside, 255 = fully selected).
class SelectionMask {
  SelectionMask(this.width, this.height, [Uint8List? data])
      : data = data ?? Uint8List(width * height);
  final int width, height;
  final Uint8List data;

  bool get isEmpty {
    for (final v in data) {
      if (v != 0) return false;
    }
    return true;
  }

  int get selectedCount {
    var n = 0;
    for (final v in data) {
      if (v != 0) n++;
    }
    return n;
  }

  SelectionMask clone() => SelectionMask(width, height, Uint8List.fromList(data));

  int at(int x, int y) =>
      x < 0 || y < 0 || x >= width || y >= height ? 0 : data[y * width + x];

  /// Combine [other] into this mask using [op].
  SelectionMask combine(SelectionMask other, SelectionOp op) {
    if (other.width != width || other.height != height) {
      throw ArgumentError('mask size mismatch');
    }
    final r = SelectionMask(width, height);
    for (var i = 0; i < data.length; i++) {
      final a = data[i], b = other.data[i];
      r.data[i] = switch (op) {
        SelectionOp.replace => b,
        SelectionOp.add => math.max(a, b),
        SelectionOp.subtract => a * (255 - b) ~/ 255,
        SelectionOp.intersect => math.min(a, b),
      };
    }
    return r;
  }

  SelectionMask invert() {
    final r = SelectionMask(width, height);
    for (var i = 0; i < data.length; i++) {
      r.data[i] = 255 - data[i];
    }
    return r;
  }

  /// Feather = separable box blur (radius px), repeated 2x ≈ gaussian.
  SelectionMask feather(int radius) {
    if (radius <= 0) return clone();
    var m = this;
    for (var pass = 0; pass < 2; pass++) {
      m = m._boxBlur(radius);
    }
    return m;
  }

  SelectionMask _boxBlur(int r) {
    final tmp = Uint8List(data.length);
    final out = Uint8List(data.length);
    for (var y = 0; y < height; y++) {
      var sum = 0;
      final row = y * width;
      for (var x = -r; x <= r; x++) {
        sum += data[row + x.clamp(0, width - 1)];
      }
      for (var x = 0; x < width; x++) {
        tmp[row + x] = sum ~/ (2 * r + 1);
        sum += data[row + (x + r + 1).clamp(0, width - 1)] -
            data[row + (x - r).clamp(0, width - 1)];
      }
    }
    for (var x = 0; x < width; x++) {
      var sum = 0;
      for (var y = -r; y <= r; y++) {
        sum += tmp[y.clamp(0, height - 1) * width + x];
      }
      for (var y = 0; y < height; y++) {
        out[y * width + x] = sum ~/ (2 * r + 1);
        sum += tmp[(y + r + 1).clamp(0, height - 1) * width + x] -
            tmp[(y - r).clamp(0, height - 1) * width + x];
      }
    }
    return SelectionMask(width, height, out);
  }

  /// Smooth = feather then re-threshold at 50 %, which rounds jagged edges.
  SelectionMask smooth(int radius) {
    final f = feather(radius);
    final r = SelectionMask(width, height);
    for (var i = 0; i < data.length; i++) {
      r.data[i] = f.data[i] >= 128 ? 255 : 0;
    }
    return r;
  }

  /// Grow (+) / shrink (−) by [px] using a square structuring element.
  SelectionMask grow(int px) {
    if (px == 0) return clone();
    final grow = px > 0;
    var cur = this;
    for (var i = 0; i < px.abs(); i++) {
      final next = SelectionMask(width, height);
      for (var y = 0; y < height; y++) {
        for (var x = 0; x < width; x++) {
          var v = grow ? 0 : 255;
          for (var dy = -1; dy <= 1; dy++) {
            for (var dx = -1; dx <= 1; dx++) {
              final n = cur.at(x + dx, y + dy);
              v = grow ? math.max(v, n) : math.min(v, n);
            }
          }
          next.data[y * width + x] = v;
        }
      }
      cur = next;
    }
    return cur;
  }

  /// Border: a ring of [px] width around the selection edge.
  SelectionMask border(int px) {
    final outer = grow(px), inner = grow(-px);
    return outer.combine(inner, SelectionOp.subtract);
  }

  /// Selection → layer mask (identical alpha values).
  Uint8List toLayerMask() => Uint8List.fromList(data);

  static SelectionMask fromLayerMask(int w, int h, Uint8List mask) {
    if (mask.length != w * h) throw ArgumentError('mask size mismatch');
    return SelectionMask(w, h, Uint8List.fromList(mask));
  }

  /// Run-length encoding for saving selections cheaply.
  Map<String, Object?> toJson() {
    final runs = <int>[];
    var i = 0;
    while (i < data.length) {
      final v = data[i];
      var j = i;
      while (j < data.length && data[j] == v) {
        j++;
      }
      runs..add(v)..add(j - i);
      i = j;
    }
    return {'w': width, 'h': height, 'rle': runs};
  }

  static SelectionMask fromJson(Map<String, Object?> j) {
    final w = (j['w'] as num).toInt(), h = (j['h'] as num).toInt();
    if (w <= 0 || h <= 0 || w * h > 100000000) {
      throw const FormatException('bad selection size');
    }
    final m = SelectionMask(w, h);
    final runs = (j['rle'] as List).cast<num>();
    var pos = 0;
    for (var i = 0; i + 1 < runs.length; i += 2) {
      final v = runs[i].toInt().clamp(0, 255), n = runs[i + 1].toInt();
      if (n < 0 || pos + n > m.data.length) {
        throw const FormatException('bad selection runs');
      }
      m.data.fillRange(pos, pos + n, v);
      pos += n;
    }
    if (pos != m.data.length) throw const FormatException('selection truncated');
    return m;
  }
}

/// Selection builders.
class SelectionBuilders {
  /// Polygon (already flattened, e.g. from Bezier segments) → mask,
  /// even-odd scanline with 4× vertical / horizontal-coverage antialiasing.
  static SelectionMask fromPolygon(int w, int h, List<Pt> poly) {
    final m = SelectionMask(w, h);
    if (poly.length < 3) return m;
    const sub = 4;
    final acc = Uint16List(w);
    for (var y = 0; y < h; y++) {
      acc.fillRange(0, w, 0);
      for (var s = 0; s < sub; s++) {
        final sy = y + (s + 0.5) / sub;
        final xs = <double>[];
        for (var i = 0; i < poly.length; i++) {
          final a = poly[i], b = poly[(i + 1) % poly.length];
          if ((a.y <= sy && b.y > sy) || (b.y <= sy && a.y > sy)) {
            xs.add(a.x + (sy - a.y) / (b.y - a.y) * (b.x - a.x));
          }
        }
        xs.sort();
        for (var k = 0; k + 1 < xs.length; k += 2) {
          final x0 = xs[k], x1 = xs[k + 1];
          final i0 = x0.floor().clamp(0, w), i1 = x1.ceil().clamp(0, w);
          for (var x = i0; x < i1; x++) {
            final cov = (math.min(x1, x + 1.0) - math.max(x0, x.toDouble())).clamp(0.0, 1.0);
            acc[x] += (cov * 255 / sub).round();
          }
        }
      }
      for (var x = 0; x < w; x++) {
        m.data[y * w + x] = acc[x].clamp(0, 255);
      }
    }
    return m;
  }

  static SelectionMask fromBezierPath(int w, int h, List<(Pt, Pt, Pt, Pt)> segments) {
    final pts = <Pt>[];
    for (final s in segments) {
      final f = flattenCubic(s.$1, s.$2, s.$3, s.$4);
      pts.addAll(pts.isEmpty ? f : f.skip(1));
    }
    return fromPolygon(w, h, pts);
  }

  /// Brush selection: soft round dab at (cx,cy), [hardness] 0..1.
  static void brushDab(SelectionMask m, double cx, double cy, double radius,
      {double hardness = 1, bool erase = false}) {
    final x0 = (cx - radius).floor().clamp(0, m.width - 1);
    final x1 = (cx + radius).ceil().clamp(0, m.width - 1);
    final y0 = (cy - radius).floor().clamp(0, m.height - 1);
    final y1 = (cy + radius).ceil().clamp(0, m.height - 1);
    for (var y = y0; y <= y1; y++) {
      for (var x = x0; x <= x1; x++) {
        final d = math.sqrt((x + 0.5 - cx) * (x + 0.5 - cx) + (y + 0.5 - cy) * (y + 0.5 - cy));
        if (d > radius) continue;
        final inner = radius * hardness;
        final a = d <= inner ? 1.0 : 1 - (d - inner) / math.max(1e-6, radius - inner);
        final v = (a * 255).round();
        final i = y * m.width + x;
        m.data[i] = erase ? m.data[i] * (255 - v) ~/ 255 : math.max(m.data[i], v);
      }
    }
  }

  /// Transparency selection from straight-alpha RGBA bytes.
  /// [opaque] = select non-transparent pixels, else select transparent ones.
  static SelectionMask fromAlpha(int w, int h, Uint8List rgba,
      {int threshold = 1, bool opaque = true}) {
    if (rgba.length != w * h * 4) throw ArgumentError('rgba size mismatch');
    final m = SelectionMask(w, h);
    for (var i = 0; i < w * h; i++) {
      final a = rgba[i * 4 + 3];
      m.data[i] = (a >= threshold) == opaque ? (opaque ? a : 255 - a) : 0;
    }
    return m;
  }
}

/// Named saved selections ("channels").
class SavedSelections {
  final Map<String, SelectionMask> _m = {};
  static const maxCount = 16;
  List<String> get names => _m.keys.toList();
  bool save(String name, SelectionMask mask) {
    if (name.trim().isEmpty) return false;
    if (!_m.containsKey(name) && _m.length >= maxCount) return false;
    _m[name] = mask.clone();
    return true;
  }
  SelectionMask? load(String name) => _m[name]?.clone();
  void delete(String name) => _m.remove(name);
}
