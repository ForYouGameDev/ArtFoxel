import 'package:flutter/foundation.dart';

enum BrushCategory {
  drawing('Drawing'),
  ink('Ink'),
  painting('Painting'),
  watercolor('Watercolor'),
  airbrush('Airbrush'),
  smudge('Smudge / Blend'),
  texture('Texture'),
  pattern('Pattern'),
  stamp('Stamp'),
  particle('Particle'),
  utility('Eraser / Utility');

  const BrushCategory(this.label);
  final String label;
}

/// Which rendering engine draws the stroke.
enum BrushEngineKind {
  /// Repeated tip stamps along the path (pencil, ink, soft/hard, airbrush…).
  stamp('Stamp'),

  /// Constant-width crisp path (technical pens, mechanical pencil).
  line('Line'),

  /// Layered soft washes with a darker wet edge.
  watercolor('Watercolor'),

  /// Moves existing pixels of the active layer along the stroke instead of
  /// adding paint (see smudge_planner.dart).
  smudge('Smudge');

  const BrushEngineKind(this.label);
  final String label;
}

/// How a smudge brush moves pixels. Each mode changes the geometry of what
/// is picked up and where it is put down, not just a strength number.
enum SmudgeMode {
  basic('Basic smudge'),
  soft('Soft smudge'),
  hard('Hard smudge'),
  finger('Finger smudge'),
  wet('Wet smudge'),
  oil('Oil paint smudge'),
  colorMixing('Color mixing smudge'),
  texture('Texture smudge'),
  directional('Directional smudge'),
  blend('Blend smudge');

  const SmudgeMode(this.label);
  final String label;
}

enum TipShape {
  round('Round'),
  square('Square'),
  diamond('Diamond'),
  star('Star'),
  speckle('Speckle'),
  triangle('Triangle'),
  leaf('Leaf'),
  flower('Flower'),
  blade('Grass blade'),
  flame('Flame');

  const TipShape(this.label);
  final String label;
}

/// Procedural paper grain. Only built-in grains exist: presets can never
/// reference external texture files.
enum GrainKind {
  none('None'),
  fine('Fine paper'),
  coarse('Coarse paper'),
  weave('Canvas weave');

  const GrainKind(this.label);
  final String label;
}

class BrushPresetException implements Exception {
  const BrushPresetException(this.message);

  final String message;

  @override
  String toString() => message;
}

bool _stampOnly(BrushPreset b) => b.engine == BrushEngineKind.stamp;
bool _roundStampTip(BrushPreset b) =>
    b.engine == BrushEngineKind.watercolor ||
    (b.engine == BrushEngineKind.stamp && b.tip == TipShape.round);
bool _stampLike(BrushPreset b) => b.engine != BrushEngineKind.line;
bool _watercolorOnly(BrushPreset b) => b.engine == BrushEngineKind.watercolor;
bool _hasGrain(BrushPreset b) => b.grain != GrainKind.none && !b.erase;
bool _smudgeOnly(BrushPreset b) => b.engine == BrushEngineKind.smudge;
bool _always(BrushPreset b) => true;

/// Describes one numeric parameter: its valid range and when the Brush Lab
/// should show it. A parameter is only shown for engines that really use it.
class BrushParam {
  const BrushParam(
    this.key,
    this.label,
    this.min,
    this.max, {
    this.group = 'Shape',
    this.visibleFor = _always,
    this.fractionDigits = 2,
  });

  final String key;
  final String label;
  final double min;
  final double max;
  final String group;
  final bool Function(BrushPreset) visibleFor;
  final int fractionDigits;
}

abstract final class BrushParams {
  static const List<BrushParam> all = [
    BrushParam('size', 'Default size (px)', 1, 1000,
        group: 'Basics', fractionDigits: 0),
    BrushParam('opacity', 'Default opacity', 0, 1, group: 'Basics'),
    BrushParam('flow', 'Flow', 0.02, 1, group: 'Basics'),
    BrushParam('spacing', 'Spacing', 0.02, 3,
        group: 'Shape', visibleFor: _stampLike),
    BrushParam('hardness', 'Edge hardness', 0, 1,
        group: 'Shape', visibleFor: _roundStampTip),
    BrushParam('roundness', 'Tip roundness', 0.05, 1,
        group: 'Shape', visibleFor: _stampOnly),
    BrushParam('angle', 'Tip angle (deg)', 0, 360,
        group: 'Shape', visibleFor: _stampOnly, fractionDigits: 0),
    BrushParam('scatter', 'Scatter', 0, 3,
        group: 'Scatter & jitter', visibleFor: _stampLike),
    BrushParam('sizeJitter', 'Size jitter', 0, 1,
        group: 'Scatter & jitter', visibleFor: _stampLike),
    BrushParam('opacityJitter', 'Opacity jitter', 0, 1,
        group: 'Scatter & jitter', visibleFor: _stampLike),
    BrushParam('hueJitter', 'Colour jitter', 0, 1,
        group: 'Scatter & jitter', visibleFor: _stampLike),
    BrushParam('angleJitter', 'Angle jitter', 0, 1,
        group: 'Scatter & jitter', visibleFor: _stampOnly),
    BrushParam('grainStrength', 'Grain strength', 0, 1,
        group: 'Texture', visibleFor: _hasGrain),
    BrushParam('pressureSize', 'Pressure → size', 0, 1,
        group: 'Dynamics', visibleFor: _stampLike),
    BrushParam('pressureSizeCurve', 'Pressure size curve', 0.25, 4,
        group: 'Dynamics', visibleFor: _stampLike),
    BrushParam('minSizeRatio', 'Size at light pressure', 0.02, 1,
        group: 'Dynamics', visibleFor: _stampLike),
    BrushParam('pressureOpacity', 'Pressure → opacity', 0, 1,
        group: 'Dynamics', visibleFor: _stampLike),
    BrushParam('pressureOpacityCurve', 'Pressure opacity curve', 0.25, 4,
        group: 'Dynamics', visibleFor: _stampLike),
    BrushParam('tiltSize', 'Tilt → size (stylus)', 0, 1,
        group: 'Dynamics', visibleFor: _stampLike),
    BrushParam('speedSize', 'Speed → size', -1, 1,
        group: 'Dynamics', visibleFor: _stampLike),
    BrushParam('taperStart', 'Start taper (× size)', 0, 20,
        group: 'Stroke', visibleFor: _stampLike, fractionDigits: 1),
    BrushParam('taperEnd', 'End taper (× size)', 0, 20,
        group: 'Stroke', visibleFor: _stampLike, fractionDigits: 1),
    BrushParam('fadeLength', 'Fade-out length (px)', 0, 5000,
        group: 'Stroke', visibleFor: _stampLike, fractionDigits: 0),
    BrushParam('wetEdge', 'Wet edge', 0, 1,
        group: 'Watercolor', visibleFor: _watercolorOnly),
    BrushParam('bleed', 'Bleed', 0, 1,
        group: 'Watercolor', visibleFor: _watercolorOnly),
    BrushParam('smudgeStrength', 'Smudge strength', 0.02, 1,
        group: 'Smudge', visibleFor: _smudgeOnly),
    BrushParam('wetness', 'Wetness (how far paint drags)', 0, 1,
        group: 'Smudge', visibleFor: _smudgeOnly),
    BrushParam('pickup', 'Colour pickup (carry start colour)', 0, 1,
        group: 'Smudge', visibleFor: _smudgeOnly),
    BrushParam('deposit', 'Colour deposition (brush colour)', 0, 1,
        group: 'Smudge', visibleFor: _smudgeOnly),
    BrushParam('stabilization', 'Default stabilization', 0, 1,
        group: 'Stabilization'),
  ];

  static BrushParam of(String key) =>
      all.firstWhere((param) => param.key == key);
}

/// Versioned, data-only brush description. Presets contain numbers, booleans
/// and enum names only: importing one can never run code or load files.
@immutable
class BrushPreset {
  const BrushPreset({
    required this.id,
    required this.name,
    required this.category,
    required this.engine,
    this.erase = false,
    this.tip = TipShape.round,
    this.hardness = 1,
    this.roundness = 1,
    this.angle = 0,
    this.followDirection = false,
    this.size = 12,
    this.minSizeRatio = 0.3,
    this.opacity = 1,
    this.flow = 1,
    this.spacing = 0.12,
    this.buildup = false,
    this.scatter = 0,
    this.sizeJitter = 0,
    this.opacityJitter = 0,
    this.hueJitter = 0,
    this.angleJitter = 0,
    this.grain = GrainKind.none,
    this.grainStrength = 0.5,
    this.pressureSize = 0,
    this.pressureSizeCurve = 1,
    this.pressureOpacity = 0,
    this.pressureOpacityCurve = 1,
    this.tiltSize = 0,
    this.speedSize = 0,
    this.simulatePressure = false,
    this.taperStart = 0,
    this.taperEnd = 0,
    this.fadeLength = 0,
    this.wetEdge = 0.5,
    this.bleed = 0.5,
    this.stabilization = 0.2,
    this.smudgeMode = SmudgeMode.basic,
    this.smudgeStrength = 0.5,
    this.wetness = 0.3,
    this.pickup = 0,
    this.deposit = 0,
    this.preserveCorners = true,
    this.predict = false,
  });

  static const int schemaVersion = 1;
  static const int maxNameLength = 48;
  static final RegExp _idPattern = RegExp(r'^[A-Za-z0-9._-]{1,64}$');
  static const String builtInPrefix = 'builtin.';

  static const BrushPreset _defaults = BrushPreset(
    id: 'defaults',
    name: 'Defaults',
    category: BrushCategory.drawing,
    engine: BrushEngineKind.stamp,
  );

  final String id;
  final String name;
  final BrushCategory category;
  final BrushEngineKind engine;

  /// Erases existing paint instead of adding paint.
  final bool erase;
  final TipShape tip;
  final double hardness;
  final double roundness;
  final double angle;

  /// Rotates the tip to follow the stroke direction.
  final bool followDirection;
  final double size;
  final double minSizeRatio;
  final double opacity;
  final double flow;
  final double spacing;

  /// When true, overlapping dabs accumulate (airbrush). When false the whole
  /// stroke is capped at the stroke opacity.
  final bool buildup;
  final double scatter;
  final double sizeJitter;
  final double opacityJitter;
  final double hueJitter;
  final double angleJitter;
  final GrainKind grain;
  final double grainStrength;
  final double pressureSize;
  final double pressureSizeCurve;
  final double pressureOpacity;
  final double pressureOpacityCurve;
  final double tiltSize;
  final double speedSize;

  /// Derives pressure from drawing speed when the device reports none.
  final bool simulatePressure;
  final double taperStart;
  final double taperEnd;
  final double fadeLength;
  final double wetEdge;
  final double bleed;
  final double stabilization;
  final SmudgeMode smudgeMode;
  final double smudgeStrength;
  final double wetness;
  final double pickup;
  final double deposit;
  final bool preserveCorners;
  final bool predict;

  bool get isBuiltIn => id.startsWith(builtInPrefix);

  /// A stable fingerprint of everything that affects rendering (not the id or
  /// name). Used to snapshot the exact brush a stroke was drawn with.
  String get renderKey {
    final json = toJson()
      ..remove('id')
      ..remove('name')
      ..remove('schema');
    var hash = 0x811C9DC5;
    for (final unit in json.toString().codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  /// Returns a validated copy with the given JSON-level changes applied.
  BrushPreset withChanges(Map<String, Object?> changes) =>
      BrushPreset.fromJson({...toJson(), ...changes});

  Map<String, dynamic> toJson() => <String, dynamic>{
        'schema': schemaVersion,
        'id': id,
        'name': name,
        'category': category.name,
        'engine': engine.name,
        'erase': erase,
        'tip': tip.name,
        'hardness': hardness,
        'roundness': roundness,
        'angle': angle,
        'followDirection': followDirection,
        'size': size,
        'minSizeRatio': minSizeRatio,
        'opacity': opacity,
        'flow': flow,
        'spacing': spacing,
        'buildup': buildup,
        'scatter': scatter,
        'sizeJitter': sizeJitter,
        'opacityJitter': opacityJitter,
        'hueJitter': hueJitter,
        'angleJitter': angleJitter,
        'grain': grain.name,
        'grainStrength': grainStrength,
        'pressureSize': pressureSize,
        'pressureSizeCurve': pressureSizeCurve,
        'pressureOpacity': pressureOpacity,
        'pressureOpacityCurve': pressureOpacityCurve,
        'tiltSize': tiltSize,
        'speedSize': speedSize,
        'simulatePressure': simulatePressure,
        'taperStart': taperStart,
        'taperEnd': taperEnd,
        'fadeLength': fadeLength,
        'wetEdge': wetEdge,
        'bleed': bleed,
        'stabilization': stabilization,
        'smudgeMode': smudgeMode.name,
        'smudgeStrength': smudgeStrength,
        'wetness': wetness,
        'pickup': pickup,
        'deposit': deposit,
        'preserveCorners': preserveCorners,
        'predict': predict,
      };

  /// Strictly validates [json]. Missing optional fields fall back to safe
  /// defaults; present-but-invalid fields throw [BrushPresetException].
  /// Unknown keys are ignored.
  factory BrushPreset.fromJson(Map<String, dynamic> json) {
    final version = json['schema'];
    if (version != null && version is! int) {
      throw const BrushPresetException('"schema" must be a whole number.');
    }
    if (version is int && version > schemaVersion) {
      throw BrushPresetException(
        'This brush was made by a newer version of ARTFOXEL '
        '(schema $version).',
      );
    }

    double number(String key, double fallback) {
      final value = json[key];
      if (value == null) return fallback;
      final param = BrushParams.of(key);
      if (value is! num || !value.isFinite) {
        throw BrushPresetException('"$key" must be a number.');
      }
      if (value < param.min || value > param.max) {
        throw BrushPresetException(
          '"$key" must be between ${param.min} and ${param.max}.',
        );
      }
      return value.toDouble();
    }

    bool flag(String key, bool fallback) {
      final value = json[key];
      if (value == null) return fallback;
      if (value is! bool) throw BrushPresetException('"$key" must be true or false.');
      return value;
    }

    T choice<T extends Enum>(String key, List<T> values, T fallback) {
      final value = json[key];
      if (value == null) return fallback;
      if (value is! String) throw BrushPresetException('"$key" must be text.');
      for (final candidate in values) {
        if (candidate.name == value) return candidate;
      }
      throw BrushPresetException('"$key" has an unknown value "$value".');
    }

    final id = json['id'];
    if (id is! String || !_idPattern.hasMatch(id)) {
      throw const BrushPresetException(
        'Brush "id" must be 1-64 letters, digits, dots, dashes or underscores.',
      );
    }
    final rawName = json['name'];
    if (rawName is! String) {
      throw const BrushPresetException('Brush "name" is required.');
    }
    final name = sanitizeName(rawName);
    if (name.isEmpty) {
      throw const BrushPresetException('Brush "name" cannot be empty.');
    }

    const d = _defaults;
    return BrushPreset(
      id: id,
      name: name,
      category: choice('category', BrushCategory.values, d.category),
      engine: choice('engine', BrushEngineKind.values, d.engine),
      erase: flag('erase', d.erase),
      tip: choice('tip', TipShape.values, d.tip),
      hardness: number('hardness', d.hardness),
      roundness: number('roundness', d.roundness),
      angle: number('angle', d.angle),
      followDirection: flag('followDirection', d.followDirection),
      size: number('size', d.size),
      minSizeRatio: number('minSizeRatio', d.minSizeRatio),
      opacity: number('opacity', d.opacity),
      flow: number('flow', d.flow),
      spacing: number('spacing', d.spacing),
      buildup: flag('buildup', d.buildup),
      scatter: number('scatter', d.scatter),
      sizeJitter: number('sizeJitter', d.sizeJitter),
      opacityJitter: number('opacityJitter', d.opacityJitter),
      hueJitter: number('hueJitter', d.hueJitter),
      angleJitter: number('angleJitter', d.angleJitter),
      grain: choice('grain', GrainKind.values, d.grain),
      grainStrength: number('grainStrength', d.grainStrength),
      pressureSize: number('pressureSize', d.pressureSize),
      pressureSizeCurve: number('pressureSizeCurve', d.pressureSizeCurve),
      pressureOpacity: number('pressureOpacity', d.pressureOpacity),
      pressureOpacityCurve:
          number('pressureOpacityCurve', d.pressureOpacityCurve),
      tiltSize: number('tiltSize', d.tiltSize),
      speedSize: number('speedSize', d.speedSize),
      simulatePressure: flag('simulatePressure', d.simulatePressure),
      taperStart: number('taperStart', d.taperStart),
      taperEnd: number('taperEnd', d.taperEnd),
      fadeLength: number('fadeLength', d.fadeLength),
      wetEdge: number('wetEdge', d.wetEdge),
      bleed: number('bleed', d.bleed),
      stabilization: number('stabilization', d.stabilization),
      smudgeMode: choice('smudgeMode', SmudgeMode.values, d.smudgeMode),
      smudgeStrength: number('smudgeStrength', d.smudgeStrength),
      wetness: number('wetness', d.wetness),
      pickup: number('pickup', d.pickup),
      deposit: number('deposit', d.deposit),
      preserveCorners: flag('preserveCorners', d.preserveCorners),
      predict: flag('predict', d.predict),
    );
  }

  /// Removes control characters and clamps the length.
  static String sanitizeName(String raw) {
    final cleaned = raw.replaceAll(RegExp(r'[\u0000-\u001F\u007F]'), '').trim();
    return cleaned.length > maxNameLength
        ? cleaned.substring(0, maxNameLength).trim()
        : cleaned;
  }

  @override
  bool operator ==(Object other) =>
      other is BrushPreset &&
      other.id == id &&
      other.name == name &&
      mapEquals(other.toJson(), toJson());

  @override
  int get hashCode => Object.hash(id, name, renderKey);
}
