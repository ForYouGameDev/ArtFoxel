import 'dart:math' as math;
import 'dart:typed_data';

/// Phase 7.5.6 — lightweight 3D reference (mannequin, primitives) and
/// procedural paper/canvas textures. Reference data is kept apart from
/// pixels and never exported unless explicitly converted by the caller.
/// No Flutter dependency; this is a pose/projection MODEL, not a renderer
/// of skinned meshes.

class V3 {
  const V3(this.x, this.y, this.z);
  final double x, y, z;
  V3 operator +(V3 o) => V3(x + o.x, y + o.y, z + o.z);
  V3 operator -(V3 o) => V3(x - o.x, y - o.y, z - o.z);
  V3 operator *(double k) => V3(x * k, y * k, z * k);
  double dot(V3 o) => x * o.x + y * o.y + z * o.z;
  double get length => math.sqrt(x * x + y * y + z * z);
  V3 normalized() {
    final l = length;
    return l < 1e-12 ? const V3(0, 0, 0) : V3(x / l, y / l, z / l);
  }
}

/// Rotation (degrees) applied as X then Y then Z.
V3 rotateDeg(V3 v, double rx, double ry, double rz) {
  final ax = rx * math.pi / 180, ay = ry * math.pi / 180, az = rz * math.pi / 180;
  var y = v.y * math.cos(ax) - v.z * math.sin(ax);
  var z = v.y * math.sin(ax) + v.z * math.cos(ax);
  var x = v.x;
  final x2 = x * math.cos(ay) + z * math.sin(ay);
  final z2 = -x * math.sin(ay) + z * math.cos(ay);
  x = x2;
  z = z2;
  final x3 = x * math.cos(az) - y * math.sin(az);
  final y3 = x * math.sin(az) + y * math.cos(az);
  return V3(x3, y3, z);
}

class Joint {
  const Joint(this.name, this.parent, this.offset,
      {this.minDeg = -180, this.maxDeg = 180});
  final String name;
  final String? parent;
  final V3 offset; // rest offset from the parent, in head units (y up)
  final double minDeg, maxDeg; // per-axis limit
}

class JointAngle {
  const JointAngle(this.x, this.y, this.z);
  final double x, y, z;
  static const zero = JointAngle(0, 0, 0);
}

class Pose {
  Pose(this.name, [Map<String, JointAngle>? angles]) : angles = {...?angles};
  final String name;
  final Map<String, JointAngle> angles;

  Map<String, Object?> toJson() => {
        'name': name,
        'angles': {for (final e in angles.entries) e.key: [e.value.x, e.value.y, e.value.z]},
      };

  static Pose fromJson(Map<String, Object?> j) {
    final out = <String, JointAngle>{};
    final a = j['angles'];
    if (a is Map) {
      for (final e in a.entries) {
        final v = e.value;
        if (v is List && v.length == 3 && v.every((n) => n is num)) {
          out['${e.key}'] = JointAngle(
              (v[0] as num).toDouble(), (v[1] as num).toDouble(), (v[2] as num).toDouble());
        }
      }
    }
    return Pose('${j['name'] ?? 'Pose'}', out);
  }
}

class Camera3D {
  const Camera3D({this.yawDeg = 0, this.pitchDeg = 0, this.distance = 12, this.fovDeg = 40});
  final double yawDeg, pitchDeg, distance, fovDeg;

  /// Projects to normalised screen coords (-1..1) with perspective.
  (double, double, double)? project(V3 p) {
    final r = rotateDeg(p, pitchDeg, yawDeg, 0);
    final z = distance - r.z;
    if (z <= 0.1) return null; // behind camera
    final f = 1 / math.tan(fovDeg * math.pi / 360);
    return (r.x * f / z, r.y * f / z, z);
  }
}

class Light3D {
  const Light3D({this.direction = const V3(-0.4, 0.8, 0.6), this.ambient = 0.25});
  final V3 direction; // direction TOWARDS the light
  final double ambient;
  double lambert(V3 normal) {
    final d = normal.normalized().dot(direction.normalized());
    return (ambient + (1 - ambient) * math.max(0, d)).clamp(0.0, 1.0);
  }
}

class Mannequin {
  Mannequin({this.heads = 7.5}) {
    pose = Pose('Standing');
  }

  /// Total height in head units (7–8.5 typical).
  double heads;
  late Pose pose;

  static const List<Joint> skeleton = [
    Joint('pelvis', null, V3(0, 3.5, 0)),
    Joint('spine', 'pelvis', V3(0, 1.0, 0), minDeg: -45, maxDeg: 45),
    Joint('chest', 'spine', V3(0, 1.0, 0), minDeg: -30, maxDeg: 30),
    Joint('neck', 'chest', V3(0, 0.8, 0), minDeg: -60, maxDeg: 60),
    Joint('head', 'neck', V3(0, 0.4, 0), minDeg: -60, maxDeg: 60),
    Joint('shoulderL', 'chest', V3(0.9, 0.6, 0)),
    Joint('elbowL', 'shoulderL', V3(0.0, -1.4, 0), minDeg: -5, maxDeg: 150),
    Joint('wristL', 'elbowL', V3(0.0, -1.2, 0), minDeg: -80, maxDeg: 80),
    Joint('handL', 'wristL', V3(0.0, -0.6, 0)),
    Joint('shoulderR', 'chest', V3(-0.9, 0.6, 0)),
    Joint('elbowR', 'shoulderR', V3(0.0, -1.4, 0), minDeg: -5, maxDeg: 150),
    Joint('wristR', 'elbowR', V3(0.0, -1.2, 0), minDeg: -80, maxDeg: 80),
    Joint('handR', 'wristR', V3(0.0, -0.6, 0)),
    Joint('hipL', 'pelvis', V3(0.5, -0.2, 0)),
    Joint('kneeL', 'hipL', V3(0.0, -1.8, 0), minDeg: -5, maxDeg: 140),
    Joint('ankleL', 'kneeL', V3(0.0, -1.7, 0), minDeg: -45, maxDeg: 45),
    Joint('footL', 'ankleL', V3(0.0, -0.1, 0.5)),
    Joint('hipR', 'pelvis', V3(-0.5, -0.2, 0)),
    Joint('kneeR', 'hipR', V3(0.0, -1.8, 0), minDeg: -5, maxDeg: 140),
    Joint('ankleR', 'kneeR', V3(0.0, -1.7, 0), minDeg: -45, maxDeg: 45),
    Joint('footR', 'ankleR', V3(0.0, -0.1, 0.5)),
  ];

  static Joint? _joint(String n) {
    for (final j in skeleton) {
      if (j.name == n) return j;
    }
    return null;
  }

  /// Sets a joint angle, clamped to the joint's limit. Returns the angle
  /// actually stored so the UI can show that a limit was hit.
  JointAngle setAngle(String joint, double x, double y, double z) {
    final j = _joint(joint);
    if (j == null) throw ArgumentError('unknown joint $joint');
    double c(double v) => v.clamp(j.minDeg, j.maxDeg).toDouble();
    final a = JointAngle(c(x), c(y), c(z));
    pose.angles[joint] = a;
    return a;
  }

  void loadPose(Pose p) {
    final fresh = Pose(p.name);
    for (final e in p.angles.entries) {
      final j = _joint(e.key);
      if (j == null) continue; // ignore unknown joints from other versions
      fresh.angles[e.key] = JointAngle(
          e.value.x.clamp(j.minDeg, j.maxDeg).toDouble(),
          e.value.y.clamp(j.minDeg, j.maxDeg).toDouble(),
          e.value.z.clamp(j.minDeg, j.maxDeg).toDouble());
    }
    pose = fresh;
  }

  /// Forward kinematics: world position of every joint (head units, y up).
  Map<String, V3> jointPositions() {
    final scale = heads / 7.5;
    final pos = <String, V3>{};
    final rot = <String, List<double>>{}; // accumulated euler (approximate chain)
    for (final j in skeleton) {
      final a = pose.angles[j.name] ?? JointAngle.zero;
      if (j.parent == null) {
        pos[j.name] = j.offset * scale;
        rot[j.name] = [a.x, a.y, a.z];
      } else {
        final pr = rot[j.parent!]!;
        final off = rotateDeg(j.offset * scale, pr[0], pr[1], pr[2]);
        pos[j.name] = pos[j.parent!]! + off;
        rot[j.name] = [pr[0] + a.x, pr[1] + a.y, pr[2] + a.z];
      }
    }
    return pos;
  }

  /// Bone segments (parent→child) for a stick/volume overlay.
  List<(V3, V3)> bones() {
    final p = jointPositions();
    return [
      for (final j in skeleton)
        if (j.parent != null) (p[j.parent!]!, p[j.name]!)
    ];
  }

  /// Segment length of each bone is preserved under pose changes.
  double boneLength(String joint) {
    final j = _joint(joint);
    if (j == null || j.parent == null) return 0;
    return (j.offset * (heads / 7.5)).length;
  }

  Map<String, Object?> toJson() => {'heads': heads, 'pose': pose.toJson()};
  static Mannequin fromJson(Map<String, Object?> j) {
    final m = Mannequin(heads: ((j['heads'] as num?)?.toDouble() ?? 7.5).clamp(4.0, 10.0));
    final p = j['pose'];
    if (p is Map) m.loadPose(Pose.fromJson(Map<String, Object?>.from(p)));
    return m;
  }
}

class PoseLibrary {
  final Map<String, Pose> _poses = {};
  static const maxPoses = 100;
  List<String> get names => _poses.keys.toList();
  bool save(Pose p) {
    if (p.name.trim().isEmpty) return false;
    if (!_poses.containsKey(p.name) && _poses.length >= maxPoses) return false;
    _poses[p.name] = Pose(p.name, p.angles);
    return true;
  }
  Pose? get(String n) => _poses[n];
  void remove(String n) => _poses.remove(n);
  List<Object?> toJson() => [for (final p in _poses.values) p.toJson()];
  static PoseLibrary fromJson(List<Object?> j) {
    final l = PoseLibrary();
    for (final e in j) {
      if (e is Map) l.save(Pose.fromJson(Map<String, Object?>.from(e)));
    }
    return l;
  }

  static Pose sitting() => Pose('Sitting', {
        'hipL': const JointAngle(90, 0, 0),
        'hipR': const JointAngle(90, 0, 0),
        'kneeL': const JointAngle(-90, 0, 0).clampX(),
        'kneeR': const JointAngle(-90, 0, 0).clampX(),
      });
  static Pose tPose() => Pose('T-pose', {
        'shoulderL': const JointAngle(0, 0, 90),
        'shoulderR': const JointAngle(0, 0, -90),
      });
}

extension on JointAngle {
  JointAngle clampX() => JointAngle(x.abs(), y, z);
}

/// Simple primitives sampled as surface points + normals for a quick shaded
/// preview. Practical for blocking out perspective; not a mesh renderer.
enum PrimitiveKind { cube, sphere, cylinder, cone }

class Primitive3D {
  Primitive3D(this.kind, {this.position = const V3(0, 0, 0), this.size = 1,
      this.rotation = const V3(0, 0, 0)});
  final PrimitiveKind kind;
  V3 position;
  double size;
  V3 rotation; // degrees

  /// Silhouette-ish wire points (edges) in world space.
  List<V3> wirePoints() {
    final s = size / 2;
    List<V3> local;
    switch (kind) {
      case PrimitiveKind.cube:
        local = [
          for (final x in [-s, s]) for (final y in [-s, s]) for (final z in [-s, s]) V3(x, y, z)
        ];
      case PrimitiveKind.sphere:
        local = [
          for (var i = 0; i < 24; i++) V3(s * math.cos(i * math.pi / 12), s * math.sin(i * math.pi / 12), 0),
          for (var i = 0; i < 24; i++) V3(0, s * math.cos(i * math.pi / 12), s * math.sin(i * math.pi / 12)),
        ];
      case PrimitiveKind.cylinder:
        local = [
          for (var i = 0; i < 24; i++) V3(s * math.cos(i * math.pi / 12), s, s * math.sin(i * math.pi / 12)),
          for (var i = 0; i < 24; i++) V3(s * math.cos(i * math.pi / 12), -s, s * math.sin(i * math.pi / 12)),
        ];
      case PrimitiveKind.cone:
        local = [
          const V3(0, 1, 0) * s,
          for (var i = 0; i < 24; i++) V3(s * math.cos(i * math.pi / 12), -s, s * math.sin(i * math.pi / 12)),
        ];
    }
    return [for (final p in local) rotateDeg(p, rotation.x, rotation.y, rotation.z) + position];
  }
}

/// Reference scene stored beside the document, NOT in the pixel layers.
class ReferenceScene {
  ReferenceScene({Mannequin? mannequin, this.camera = const Camera3D(), this.light = const Light3D()})
      : mannequin = mannequin ?? Mannequin();
  final Mannequin mannequin;
  Camera3D camera;
  Light3D light;
  final List<Primitive3D> primitives = [];
  bool visible = true;

  /// Always false: reference never goes into exports unless the user
  /// explicitly converts it to a raster layer through a separate action.
  bool get includedInExport => false;

  Map<String, Object?> toJson() => {
        'mannequin': mannequin.toJson(),
        'cam': [camera.yawDeg, camera.pitchDeg, camera.distance, camera.fovDeg],
        'visible': visible,
        'prims': [
          for (final p in primitives)
            {'k': p.kind.name, 'p': [p.position.x, p.position.y, p.position.z],
             'r': [p.rotation.x, p.rotation.y, p.rotation.z], 's': p.size}
        ],
      };
}

// ------------------------------------------------------------- textures

enum PaperKind { grain, rough, smooth, watercolor, fabric }

/// Procedural, deterministic paper/canvas height field in 0..1. Generated
/// from a seed, so nothing needs to be bundled or licensed.
class PaperTexture {
  PaperTexture(this.kind, {this.seed = 1, this.scale = 1, this.rotationDeg = 0, this.intensity = 0.5});
  final PaperKind kind;
  final int seed;
  final double scale; // 0.25 .. 8
  final double rotationDeg;
  final double intensity; // 0..1

  static double _hash(int x, int y, int seed) {
    var h = x * 374761393 + y * 668265263 + seed * 2147483647;
    h = (h ^ (h >> 13)) * 1274126177;
    h = h ^ (h >> 16);
    return (h & 0xFFFFFF) / 0xFFFFFF;
  }

  static double _valueNoise(double x, double y, int seed) {
    final x0 = x.floor(), y0 = y.floor();
    final fx = x - x0, fy = y - y0;
    final u = fx * fx * (3 - 2 * fx), v = fy * fy * (3 - 2 * fy);
    final a = _hash(x0, y0, seed), b = _hash(x0 + 1, y0, seed);
    final c = _hash(x0, y0 + 1, seed), d = _hash(x0 + 1, y0 + 1, seed);
    return a + (b - a) * u + (c - a) * v + (a - b - c + d) * u * v;
  }

  /// Height at document pixel (x,y).
  double height(double x, double y) {
    final s = scale.clamp(0.25, 8.0);
    final r = rotationDeg * math.pi / 180;
    final rx = (x * math.cos(r) - y * math.sin(r)) / s;
    final ry = (x * math.sin(r) + y * math.cos(r)) / s;
    switch (kind) {
      case PaperKind.grain:
        return _hash(rx.floor(), ry.floor(), seed);
      case PaperKind.rough:
        return 0.55 * _valueNoise(rx / 2, ry / 2, seed) +
            0.3 * _valueNoise(rx, ry, seed + 1) + 0.15 * _hash(rx.floor(), ry.floor(), seed + 2);
      case PaperKind.smooth:
        return 0.5 + 0.25 * (_valueNoise(rx / 6, ry / 6, seed) - 0.5);
      case PaperKind.watercolor:
        return 0.6 * _valueNoise(rx / 4, ry / 4, seed) + 0.4 * _valueNoise(rx / 1.5, ry / 1.5, seed + 3);
      case PaperKind.fabric:
        final wx = 0.5 + 0.5 * math.sin(rx * 1.6), wy = 0.5 + 0.5 * math.sin(ry * 1.6);
        return (0.5 * wx + 0.5 * wy) * 0.8 + 0.2 * _hash(rx.floor(), ry.floor(), seed);
    }
  }

  /// Preview-only overlay: returns a NEW buffer with the texture shading
  /// applied (original untouched). Mid-grey height = no change.
  Uint8List shade(Uint8List rgba, int w, int h) {
    if (rgba.length != w * h * 4) throw ArgumentError('size mismatch');
    final out = Uint8List.fromList(rgba);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final k = (height(x.toDouble(), y.toDouble()) - 0.5) * 2 * intensity * 0.5;
        final i = (y * w + x) * 4;
        for (var c = 0; c < 3; c++) {
          out[i + c] = (out[i + c] * (1 + k)).round().clamp(0, 255);
        }
      }
    }
    return out;
  }
}

/// Canvas texture setting kept in project metadata, not in pixels.
class CanvasTextureSetting {
  CanvasTextureSetting({this.texture, this.showInPreview = true, this.bakeOnExport = false});
  PaperTexture? texture;
  bool showInPreview;
  /// Only an explicit user choice makes the texture part of an export.
  bool bakeOnExport;
}
