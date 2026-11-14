import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Offset, Rect;

/// A 2D affine transform in document coordinates:
///
///     x' = a*x + c*y + e
///     y' = b*x + d*y + f
///
/// Immutable. Used for layer transforms, canvas geometry changes and image
/// layer placement, so every transform in the app shares one tested
/// implementation.
class Affine2D {
  const Affine2D(this.a, this.b, this.c, this.d, this.e, this.f);

  static const Affine2D identity = Affine2D(1, 0, 0, 1, 0, 0);

  final double a;
  final double b;
  final double c;
  final double d;
  final double e;
  final double f;

  factory Affine2D.translation(double dx, double dy) =>
      Affine2D(1, 0, 0, 1, dx, dy);

  factory Affine2D.scale(double sx, double sy) => Affine2D(sx, 0, 0, sy, 0, 0);

  factory Affine2D.rotation(double radians) {
    final cos = math.cos(radians);
    final sin = math.sin(radians);
    return Affine2D(cos, sin, -sin, cos, 0, 0);
  }

  /// Skew by angles (radians) along x and y.
  factory Affine2D.skew(double xRadians, double yRadians) =>
      Affine2D(1, math.tan(yRadians), math.tan(xRadians), 1, 0, 0);

  /// Applies [this] with [pivot] as the fixed point (scale/rotate/skew around
  /// an anchor instead of the origin).
  Affine2D aroundPivot(Offset pivot) =>
      Affine2D.translation(pivot.dx, pivot.dy) *
      this *
      Affine2D.translation(-pivot.dx, -pivot.dy);

  /// `this * other` applies [other] first, then [this].
  Affine2D operator *(Affine2D o) => Affine2D(
        a * o.a + c * o.b,
        b * o.a + d * o.b,
        a * o.c + c * o.d,
        b * o.c + d * o.d,
        a * o.e + c * o.f + e,
        b * o.e + d * o.f + f,
      );

  double get determinant => a * d - b * c;

  bool get isInvertible => determinant.abs() > 1e-12 && determinant.isFinite;

  bool get isIdentity =>
      (a - 1).abs() < 1e-9 &&
      b.abs() < 1e-9 &&
      c.abs() < 1e-9 &&
      (d - 1).abs() < 1e-9 &&
      e.abs() < 1e-9 &&
      f.abs() < 1e-9;

  /// Uniform size factor used to scale brush sizes with the geometry.
  double get scaleFactor => math.sqrt(determinant.abs());

  Affine2D? inverse() {
    if (!isInvertible) return null;
    final det = determinant;
    return Affine2D(
      d / det,
      -b / det,
      -c / det,
      a / det,
      (c * f - d * e) / det,
      (b * e - a * f) / det,
    );
  }

  Offset apply(Offset p) => Offset(a * p.dx + c * p.dy + e, b * p.dx + d * p.dy + f);

  double applyX(double x, double y) => a * x + c * y + e;
  double applyY(double x, double y) => b * x + d * y + f;

  /// Bounding box of [rect] after the transform.
  Rect mapRect(Rect rect) {
    final points = [
      apply(rect.topLeft),
      apply(rect.topRight),
      apply(rect.bottomLeft),
      apply(rect.bottomRight),
    ];
    var left = points.first.dx, right = left;
    var top = points.first.dy, bottom = top;
    for (final p in points) {
      left = math.min(left, p.dx);
      right = math.max(right, p.dx);
      top = math.min(top, p.dy);
      bottom = math.max(bottom, p.dy);
    }
    return Rect.fromLTRB(left, top, right, bottom);
  }

  /// Column-major 4x4 matrix for `Canvas.transform`.
  Float64List toMatrix4() => Float64List.fromList([
        a, b, 0, 0, //
        c, d, 0, 0, //
        0, 0, 1, 0, //
        e, f, 0, 1, //
      ]);

  List<double> toJson() => [a, b, c, d, e, f];

  static Affine2D? fromJson(Object? raw) {
    if (raw is! List || raw.length != 6) return null;
    final values = <double>[];
    for (final v in raw) {
      if (v is! num || !v.isFinite) return null;
      values.add(v.toDouble());
    }
    final m = Affine2D(values[0], values[1], values[2], values[3], values[4], values[5]);
    return m.isInvertible ? m : null;
  }

  @override
  bool operator ==(Object other) =>
      other is Affine2D &&
      other.a == a &&
      other.b == b &&
      other.c == c &&
      other.d == d &&
      other.e == e &&
      other.f == f;

  @override
  int get hashCode => Object.hash(a, b, c, d, e, f);

  @override
  String toString() => 'Affine2D($a, $b, $c, $d, $e, $f)';
}
