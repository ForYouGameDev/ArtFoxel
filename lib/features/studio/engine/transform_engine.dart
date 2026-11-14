import 'dart:math' as math;
import 'dart:typed_data';

import 'fill_clone.dart';
import 'guides_selection.dart';

/// Phase 7.5.5 — pattern/array placement, seamless tiles, non-destructive
/// transforms and liquify. Pure Dart on straight-alpha RGBA8.
///
/// Honest limit: raster pixels are resampled when a transform is committed;
/// repeated commits lose detail. The non-destructive stack keeps the ORIGINAL
/// source and re-renders from it, but a committed result is ordinary pixels.

class Placement {
  const Placement(this.x, this.y, {this.rotationRad = 0, this.scale = 1});
  final double x, y, rotationRad, scale;
  @override
  String toString() => 'Placement($x,$y,r=$rotationRad,s=$scale)';
}

class PatternException implements Exception {
  PatternException(this.message);
  final String message;
  @override
  String toString() => 'PatternException: $message';
}

class PatternGenerator {
  static const maxPlacements = 20000;


  static List<Placement> grid(double w, double h, double cellW, double cellH,
      {double offsetX = 0, double offsetY = 0}) {
    if (cellW <= 0 || cellH <= 0) throw PatternException('cell size must be > 0');
    final cols = (w / cellW).ceil(), rows = (h / cellH).ceil();
    if (cols * rows > maxPlacements) throw PatternException('too many repeats');
    return [
      for (var r = 0; r < rows; r++)
        for (var c = 0; c < cols; c++)
          Placement(offsetX + c * cellW + cellW / 2, offsetY + r * cellH + cellH / 2)
    ];
  }

  /// Quilt / brick: every other row shifted by [shift] (0..1) of a cell,
  /// and optionally flipped (mirrored rotation 180°) for quilt feel.
  static List<Placement> quilt(double w, double h, double cellW, double cellH,
      {double shift = 0.5, bool alternateRotate = false}) {
    if (cellW <= 0 || cellH <= 0) throw PatternException('cell size must be > 0');
    final out = <Placement>[];
    final rows = (h / cellH).ceil() + 1;
    final cols = (w / cellW).ceil() + 2;
    if (rows * cols > maxPlacements) throw PatternException('too many repeats');
    for (var r = 0; r < rows; r++) {
      final dx = r.isOdd ? shift * cellW : 0.0;
      for (var c = -1; c < cols - 1; c++) {
        out.add(Placement(c * cellW + dx + cellW / 2, r * cellH + cellH / 2,
            rotationRad: alternateRotate && (r + c).isOdd ? math.pi : 0));
      }
    }
    return out;
  }

  /// Hexagonal packing ("geometric").
  static List<Placement> hex(double w, double h, double size) {
    if (size <= 0) throw PatternException('size must be > 0');
    final dx = size * math.sqrt(3), dy = size * 1.5;
    final out = <Placement>[];
    final rows = (h / dy).ceil() + 1, cols = (w / dx).ceil() + 1;
    if (rows * cols > maxPlacements) throw PatternException('too many repeats');
    for (var r = 0; r < rows; r++) {
      for (var c = 0; c < cols; c++) {
        out.add(Placement(c * dx + (r.isOdd ? dx / 2 : 0), r * dy));
      }
    }
    return out;
  }

  static List<Placement> radial(double cx, double cy, double radius, int count,
      {int rings = 1, bool rotateToCentre = true, double startRad = 0}) {
    if (count < 1 || rings < 1) throw PatternException('count/rings must be >= 1');
    if (count * rings > maxPlacements) throw PatternException('too many repeats');
    return [
      for (var ring = 1; ring <= rings; ring++)
        for (var i = 0; i < count; i++)
          () {
            final a = startRad + 2 * math.pi * i / count;
            final r = radius * ring / rings;
            return Placement(cx + r * math.cos(a), cy + r * math.sin(a),
                rotationRad: rotateToCentre ? a : 0);
          }()
    ];
  }

  /// Placements spaced along a polyline, oriented to the path tangent.
  static List<Placement> alongPath(List<Pt> path, double spacing) {
    if (spacing <= 0) throw PatternException('spacing must be > 0');
    final out = <Placement>[];
    if (path.length < 2) return out;
    var carry = 0.0;
    for (var i = 0; i < path.length - 1; i++) {
      final a = path[i], b = path[i + 1];
      final len = a.distanceTo(b);
      if (len < 1e-9) continue;
      final ang = math.atan2(b.y - a.y, b.x - a.x);
      var d = carry;
      while (d <= len) {
        final t = d / len;
        out.add(Placement(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, rotationRad: ang));
        if (out.length > maxPlacements) throw PatternException('too many repeats');
        d += spacing;
      }
      carry = d - len;
    }
    return out;
  }
}

/// Arrays (copies of a selection/layer): linear, radial and grid.
class ArrayGenerator {
  static List<Placement> linear(int count, double dx, double dy,
      {double rotateStepRad = 0, double scaleStep = 1}) {
    if (count < 1 || count > PatternGenerator.maxPlacements) {
      throw PatternException('bad count');
    }
    return [
      for (var i = 0; i < count; i++)
        Placement(dx * i, dy * i,
            rotationRad: rotateStepRad * i, scale: math.pow(scaleStep, i).toDouble())
    ];
  }

  /// Offsets relative to the original, copies spread around [cx],[cy].
  static List<Placement> radial(double cx, double cy, double ox, double oy, int count,
      {bool rotateCopies = true}) {
    if (count < 1 || count > PatternGenerator.maxPlacements) {
      throw PatternException('bad count');
    }
    final r = math.sqrt((ox - cx) * (ox - cx) + (oy - cy) * (oy - cy));
    final a0 = math.atan2(oy - cy, ox - cx);
    return [
      for (var i = 0; i < count; i++)
        () {
          final a = a0 + 2 * math.pi * i / count;
          return Placement(cx + r * math.cos(a) - ox, cy + r * math.sin(a) - oy,
              rotationRad: rotateCopies ? a - a0 : 0);
        }()
    ];
  }

  static List<Placement> gridArray(int cols, int rows, double dx, double dy) {
    if (cols < 1 || rows < 1 || cols * rows > PatternGenerator.maxPlacements) {
      throw PatternException('bad grid size');
    }
    return [
      for (var r = 0; r < rows; r++)
        for (var c = 0; c < cols; c++) Placement(c * dx, r * dy)
    ];
  }
}

/// Symmetry reflection of a point (mirror / radial), used for live drawing.
class Symmetry {
  const Symmetry({this.mirrorV = false, this.mirrorH = false, this.radial = 1,
      this.cx = 0, this.cy = 0});
  final bool mirrorV, mirrorH; // mirror across vertical / horizontal axis
  final int radial; // rotational copies
  final double cx, cy;

  List<Pt> expand(Pt p) {
    var base = <Pt>[p];
    if (mirrorV) base = [for (final q in base) ...[q, Pt(2 * cx - q.x, q.y)]];
    if (mirrorH) base = [for (final q in base) ...[q, Pt(q.x, 2 * cy - q.y)]];
    if (radial <= 1) return base;
    final out = <Pt>[];
    for (final q in base) {
      for (var i = 0; i < radial; i++) {
        final a = 2 * math.pi * i / radial;
        final dx = q.x - cx, dy = q.y - cy;
        out.add(Pt(cx + dx * math.cos(a) - dy * math.sin(a),
            cy + dx * math.sin(a) + dy * math.cos(a)));
      }
    }
    return out;
  }
}

class TileOps {
  /// Tiles the buffer [cols]x[rows] times (seamless-tile preview).
  static Uint8List tilePreview(Uint8List tile, int w, int h, int cols, int rows) {
    if (tile.length != w * h * 4) throw PatternException('tile size mismatch');
    if (cols < 1 || rows < 1 || w * cols * h * rows > 64000000) {
      throw PatternException('preview too large');
    }
    final ow = w * cols, oh = h * rows;
    final out = Uint8List(ow * oh * 4);
    for (var y = 0; y < oh; y++) {
      for (var x = 0; x < ow; x++) {
        final si = ((y % h) * w + (x % w)) * 4, di = (y * ow + x) * 4;
        out[di] = tile[si];
        out[di + 1] = tile[si + 1];
        out[di + 2] = tile[si + 2];
        out[di + 3] = tile[si + 3];
      }
    }
    return out;
  }

  /// Mean absolute difference between opposite edges (0 = perfectly seamless).
  static double edgeMismatch(Uint8List t, int w, int h) {
    var sum = 0.0, n = 0;
    for (var y = 0; y < h; y++) {
      for (var c = 0; c < 4; c++) {
        sum += (t[(y * w) * 4 + c] - t[(y * w + w - 1) * 4 + c]).abs();
        n++;
      }
    }
    for (var x = 0; x < w; x++) {
      for (var c = 0; c < 4; c++) {
        sum += (t[x * 4 + c] - t[((h - 1) * w + x) * 4 + c]).abs();
        n++;
      }
    }
    return n == 0 ? 0 : sum / n;
  }

  /// Makes a tile wrap by cross-fading towards the half-offset copy near the
  /// borders (classic "offset + blend"). [blendPx] is the fade width.
  static Uint8List makeSeamless(Uint8List t, int w, int h, {int? blendPx}) {
    final b = (blendPx ?? math.max(2, math.min(w, h) ~/ 4)).clamp(1, math.min(w, h) ~/ 2);
    final out = Uint8List.fromList(t);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final dEdgeX = math.min(x, w - 1 - x), dEdgeY = math.min(y, h - 1 - y);
        final d = math.min(dEdgeX, dEdgeY);
        if (d >= b) continue;
        final wgt = 1 - d / b; // 1 at edge → use offset copy fully
        final ox = (x + w ~/ 2) % w, oy = (y + h ~/ 2) % h;
        final i = (y * w + x) * 4, j = (oy * w + ox) * 4;
        for (var c = 0; c < 4; c++) {
          out[i + c] = (t[i + c] * (1 - wgt) + t[j + c] * wgt).round().clamp(0, 255);
        }
      }
    }
    return out;
  }
}

// ----------------------------------------------------- non-destructive xform

/// 2x3 affine: [a c e; b d f].
class Affine {
  const Affine(this.a, this.b, this.c, this.d, this.e, this.f);
  static const identity = Affine(1, 0, 0, 1, 0, 0);
  final double a, b, c, d, e, f;

  Affine then(Affine o) => Affine(
      o.a * a + o.c * b, o.b * a + o.d * b,
      o.a * c + o.c * d, o.b * c + o.d * d,
      o.a * e + o.c * f + o.e, o.b * e + o.d * f + o.f);

  Pt apply(Pt p) => Pt(a * p.x + c * p.y + e, b * p.x + d * p.y + f);

  double get det => a * d - b * c;

  Affine? inverse() {
    final dt = det;
    if (dt.abs() < 1e-12) return null;
    return Affine(d / dt, -b / dt, -c / dt, a / dt,
        (c * f - d * e) / dt, (b * e - a * f) / dt);
  }

  static Affine translate(double x, double y) => Affine(1, 0, 0, 1, x, y);
  static Affine scale(double sx, double sy) => Affine(sx, 0, 0, sy, 0, 0);
  static Affine rotate(double r) =>
      Affine(math.cos(r), math.sin(r), -math.sin(r), math.cos(r), 0, 0);
  static Affine skew(double ax, double ay) => Affine(1, math.tan(ay), math.tan(ax), 1, 0, 0);

  /// Transform about an anchor point (pivot).
  Affine about(Pt anchor) =>
      Affine.translate(-anchor.x, -anchor.y).then(this).then(Affine.translate(anchor.x, anchor.y));
}

/// Perspective / free distort: maps the unit-quad corners of a w×h source
/// onto four destination corners (TL, TR, BR, BL) via a homography.
class Homography {
  Homography._(this.h);
  final List<double> h; // 9 values, row-major

  static Homography? fromQuad(double w, double h, List<Pt> dst) {
    if (dst.length != 4) return null;
    final src = [Pt(0, 0), Pt(w, 0), Pt(w, h), Pt(0, h)];
    // Solve 8x8 for h11..h32 (h33 = 1).
    final A = List.generate(8, (_) => List<double>.filled(9, 0));
    for (var i = 0; i < 4; i++) {
      final x = src[i].x, y = src[i].y, u = dst[i].x, v = dst[i].y;
      A[i * 2] = [x, y, 1, 0, 0, 0, -u * x, -u * y, u];
      A[i * 2 + 1] = [0, 0, 0, x, y, 1, -v * x, -v * y, v];
    }
    for (var col = 0; col < 8; col++) {
      var piv = col;
      for (var r = col + 1; r < 8; r++) {
        if (A[r][col].abs() > A[piv][col].abs()) piv = r;
      }
      if (A[piv][col].abs() < 1e-10) return null;
      final tmp = A[col]; A[col] = A[piv]; A[piv] = tmp;
      for (var r = 0; r < 8; r++) {
        if (r == col) continue;
        final f = A[r][col] / A[col][col];
        for (var k = col; k < 9; k++) {
          A[r][k] -= f * A[col][k];
        }
      }
    }
    return Homography._([for (var i = 0; i < 8; i++) A[i][8] / A[i][i], 1.0]);
  }

  Pt map(Pt p) {
    final w = h[6] * p.x + h[7] * p.y + h[8];
    return Pt((h[0] * p.x + h[1] * p.y + h[2]) / w, (h[3] * p.x + h[4] * p.y + h[5]) / w);
  }

  Homography? inverse() {
    final m = h;
    final det = m[0] * (m[4] * m[8] - m[5] * m[7]) -
        m[1] * (m[3] * m[8] - m[5] * m[6]) +
        m[2] * (m[3] * m[7] - m[4] * m[6]);
    if (det.abs() < 1e-14) return null;
    final inv = [
      (m[4] * m[8] - m[5] * m[7]), (m[2] * m[7] - m[1] * m[8]), (m[1] * m[5] - m[2] * m[4]),
      (m[5] * m[6] - m[3] * m[8]), (m[0] * m[8] - m[2] * m[6]), (m[2] * m[3] - m[0] * m[5]),
      (m[3] * m[7] - m[4] * m[6]), (m[1] * m[6] - m[0] * m[7]), (m[0] * m[4] - m[1] * m[3]),
    ].map((v) => v / det).toList();
    return Homography._(inv);
  }
}

/// Mesh warp: a (cols+1)×(rows+1) lattice of control points. Output pixel
/// → source via bilinear interpolation across the *displaced* lattice
/// (inverse mapping solved per cell by Newton iteration).
class MeshWarp {
  MeshWarp(this.cols, this.rows, this.width, this.height)
      : points = [
          for (var r = 0; r <= rows; r++)
            for (var c = 0; c <= cols; c++)
              Pt(width * c / cols, height * r / rows)
        ];
  final int cols, rows;
  final double width, height;
  final List<Pt> points; // displaced destination lattice

  Pt rest(int c, int r) => Pt(width * c / cols, height * r / rows);
  void move(int c, int r, Pt to) => points[r * (cols + 1) + c] = to;

  bool get isIdentity {
    for (var r = 0; r <= rows; r++) {
      for (var c = 0; c <= cols; c++) {
        if (points[r * (cols + 1) + c] != rest(c, r)) return false;
      }
    }
    return true;
  }

  /// Forward map: source point → displaced position.
  Pt forward(Pt s) {
    final fx = (s.x / width * cols).clamp(0.0, cols - 1e-9);
    final fy = (s.y / height * rows).clamp(0.0, rows - 1e-9);
    final c = fx.floor(), r = fy.floor();
    final u = fx - c, v = fy - r;
    Pt p(int cc, int rr) => points[rr * (cols + 1) + cc];
    final a = p(c, r), b = p(c + 1, r), d = p(c, r + 1), e = p(c + 1, r + 1);
    return Pt(
      (1 - u) * (1 - v) * a.x + u * (1 - v) * b.x + (1 - u) * v * d.x + u * v * e.x,
      (1 - u) * (1 - v) * a.y + u * (1 - v) * b.y + (1 - u) * v * d.y + u * v * e.y,
    );
  }

  /// Inverse by Newton iteration (starts from identity guess).
  Pt inverse(Pt target) {
    var s = target;
    for (var i = 0; i < 12; i++) {
      final f = forward(s);
      final ex = f.x - target.x, ey = f.y - target.y;
      if (ex * ex + ey * ey < 1e-6) break;
      const h = 0.5;
      final fx = forward(Pt(s.x + h, s.y)), fy = forward(Pt(s.x, s.y + h));
      final j11 = (fx.x - f.x) / h, j21 = (fx.y - f.y) / h;
      final j12 = (fy.x - f.x) / h, j22 = (fy.y - f.y) / h;
      final det = j11 * j22 - j12 * j21;
      if (det.abs() < 1e-9) break;
      s = Pt(s.x - (j22 * ex - j12 * ey) / det, s.y - (-j21 * ex + j11 * ey) / det);
    }
    return s;
  }
}

typedef InverseMap = Pt Function(Pt dstPixelCentre);

class TransformRenderer {
  /// Renders [src] through an inverse mapping into a w×h output. A scale
  /// factor < 1 renders a cheap live preview at reduced resolution.
  static Uint8List render(Uint8List src, int sw, int sh, int ow, int oh, InverseMap inv,
      {double previewScale = 1}) {
    if (src.length != sw * sh * 4) throw PatternException('source size mismatch');
    final pw = math.max(1, (ow * previewScale).round());
    final ph = math.max(1, (oh * previewScale).round());
    final out = Uint8List(pw * ph * 4);
    for (var y = 0; y < ph; y++) {
      for (var x = 0; x < pw; x++) {
        final dx = (x + 0.5) / previewScale, dy = (y + 0.5) / previewScale;
        final sp = inv(Pt(dx, dy));
        final c = CloneStamp.sampleBilinear(src, sw, sh, sp.x - 0.5, sp.y - 0.5);
        final i = (y * pw + x) * 4;
        out[i] = c[0];
        out[i + 1] = c[1];
        out[i + 2] = c[2];
        out[i + 3] = c[3];
      }
    }
    return out;
  }
}

/// Non-destructive transform: keeps the untouched source + parameters.
/// Re-rendering always starts from the original, so tweaking parameters
/// never compounds resampling loss; only [commit] bakes pixels.
class TransformStack {
  TransformStack(this.source, this.width, this.height);
  final Uint8List source;
  final int width, height;
  Affine affine = Affine.identity;
  Homography? perspective; // overrides affine when set
  MeshWarp? mesh; // applied before affine
  bool committed = false;

  void setAffine(Affine a) => affine = a;

  /// Layers multiple edits: caller composes their Affines first.
  InverseMap? inverseMap() {
    if (perspective != null) {
      final inv = perspective!.inverse();
      if (inv == null) return null;
      return (p) => inv.map(p);
    }
    final ai = affine.inverse();
    if (ai == null) return null;
    final m = mesh;
    return (p) {
      var q = ai.apply(p);
      if (m != null) q = m.inverse(q);
      return q;
    };
  }

  Uint8List? preview({double scale = 0.5, int? outW, int? outH}) {
    final inv = inverseMap();
    if (inv == null) return null;
    return TransformRenderer.render(source, width, height, outW ?? width, outH ?? height, inv,
        previewScale: scale);
  }

  Uint8List? commit({int? outW, int? outH}) {
    final inv = inverseMap();
    if (inv == null) return null;
    committed = true;
    return TransformRenderer.render(source, width, height, outW ?? width, outH ?? height, inv);
  }

  /// A cumulative upscale > 1 on raster data invents no detail.
  String? qualityWarning() {
    final s = math.sqrt(affine.det.abs());
    if (s > 1.5) return 'Enlarging raster pixels ${s.toStringAsFixed(1)}× softens detail; '
        'transforms are not lossless.';
    return null;
  }
}

// --------------------------------------------------------------- liquify

enum LiquifyTool { push, expand, pinch, swirl, restore }

class LiquifyField {
  LiquifyField(this.width, this.height)
      : dx = Float32List(width * height),
        dy = Float32List(width * height);
  final int width, height;
  final Float32List dx, dy; // source-offset: out(x,y) = src(x+dx, y+dy)

  bool get isIdentity {
    for (var i = 0; i < dx.length; i++) {
      if (dx[i] != 0 || dy[i] != 0) return false;
    }
    return true;
  }

  /// One dab. [strength] 0..1. [dirX]/[dirY] used by push (unit stroke dir).
  void dab(LiquifyTool tool, double cx, double cy, double radius, double strength,
      {double dirX = 0, double dirY = 0}) {
    final x0 = (cx - radius).floor().clamp(0, width - 1);
    final x1 = (cx + radius).ceil().clamp(0, width - 1);
    final y0 = (cy - radius).floor().clamp(0, height - 1);
    final y1 = (cy + radius).ceil().clamp(0, height - 1);
    for (var y = y0; y <= y1; y++) {
      for (var x = x0; x <= x1; x++) {
        final px = x + 0.5 - cx, py = y + 0.5 - cy;
        final d = math.sqrt(px * px + py * py);
        if (d >= radius) continue;
        final t = 1 - d / radius;
        final f = t * t * (3 - 2 * t) * strength; // smoothstep falloff
        final i = y * width + x;
        switch (tool) {
          case LiquifyTool.push:
            dx[i] -= (dirX * f * radius * 0.5).toDouble();
            dy[i] -= (dirY * f * radius * 0.5).toDouble();
          case LiquifyTool.expand:
            dx[i] -= px * f * 0.5;
            dy[i] -= py * f * 0.5;
          case LiquifyTool.pinch:
            dx[i] += px * f * 0.5;
            dy[i] += py * f * 0.5;
          case LiquifyTool.swirl:
            final ang = f * 0.6;
            final rx = px * math.cos(ang) - py * math.sin(ang) - px;
            final ry = px * math.sin(ang) + py * math.cos(ang) - py;
            dx[i] += rx;
            dy[i] += ry;
          case LiquifyTool.restore:
            dx[i] *= (1 - f).toDouble();
            dy[i] *= (1 - f).toDouble();
        }
      }
    }
  }

  /// Reconstruct: relaxes the whole field towards identity by [amount] 0..1.
  void reconstruct(double amount) {
    final k = (1 - amount).clamp(0.0, 1.0);
    for (var i = 0; i < dx.length; i++) {
      dx[i] *= k;
      dy[i] *= k;
    }
  }

  Uint8List apply(Uint8List src) {
    if (src.length != width * height * 4) throw PatternException('size mismatch');
    final out = Uint8List(src.length);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final i = y * width + x;
        final c = (dx[i] == 0 && dy[i] == 0)
            ? [src[i * 4], src[i * 4 + 1], src[i * 4 + 2], src[i * 4 + 3]]
            : CloneStamp.sampleBilinear(src, width, height, x + dx[i], y + dy[i]);
        out[i * 4] = c[0];
        out[i * 4 + 1] = c[1];
        out[i * 4 + 2] = c[2];
        out[i * 4 + 3] = c[3];
      }
    }
    return out;
  }
}
