import 'package:flutter/gestures.dart';

enum CanvasInputBehavior { draw, navigate, ignore }

class CanvasInputSettings {
  const CanvasInputSettings({
    this.fingerBehavior = CanvasInputBehavior.navigate,
    this.stylusBehavior = CanvasInputBehavior.draw,
    this.mouseBehavior = CanvasInputBehavior.draw,
    this.palmRejection = false,
    this.rotationEnabled = true,
  });

  final CanvasInputBehavior fingerBehavior;
  final CanvasInputBehavior stylusBehavior;
  final CanvasInputBehavior mouseBehavior;

  /// Ignores touches while a stylus is in use (and briefly afterwards) so a
  /// resting palm does not leave marks or move the canvas.
  final bool palmRejection;

  /// Allows two-finger rotation of the canvas.
  final bool rotationEnabled;

  CanvasInputSettings copyWith({
    CanvasInputBehavior? fingerBehavior,
    CanvasInputBehavior? stylusBehavior,
    CanvasInputBehavior? mouseBehavior,
    bool? palmRejection,
    bool? rotationEnabled,
  }) =>
      CanvasInputSettings(
        fingerBehavior: fingerBehavior ?? this.fingerBehavior,
        stylusBehavior: stylusBehavior ?? this.stylusBehavior,
        mouseBehavior: mouseBehavior ?? this.mouseBehavior,
        palmRejection: palmRejection ?? this.palmRejection,
        rotationEnabled: rotationEnabled ?? this.rotationEnabled,
      );

  @override
  bool operator ==(Object other) =>
      other is CanvasInputSettings &&
      other.fingerBehavior == fingerBehavior &&
      other.stylusBehavior == stylusBehavior &&
      other.mouseBehavior == mouseBehavior &&
      other.palmRejection == palmRejection &&
      other.rotationEnabled == rotationEnabled;

  @override
  int get hashCode => Object.hash(
        fingerBehavior,
        stylusBehavior,
        mouseBehavior,
        palmRejection,
        rotationEnabled,
      );

  CanvasInputBehavior behaviorFor(PointerDeviceKind kind) => switch (kind) {
        PointerDeviceKind.touch => fingerBehavior,
        PointerDeviceKind.stylus || PointerDeviceKind.invertedStylus =>
          stylusBehavior,
        PointerDeviceKind.mouse => mouseBehavior,
        _ => CanvasInputBehavior.ignore,
      };
}

class CanvasInputCapabilities {
  const CanvasInputCapabilities({
    this.pressure = false,
    this.tilt = false,
    this.orientation = false,
  });

  final bool pressure;
  final bool tilt;
  final bool orientation;

  String get label {
    final available = <String>[
      if (pressure) 'pressure',
      if (tilt) 'tilt',
      if (orientation) 'orientation',
    ];
    return available.isEmpty ? 'position only' : available.join(', ');
  }
}

class CanvasInputSample {
  const CanvasInputSample({
    required this.pointerId,
    required this.kind,
    required this.screenPosition,
    required this.documentPosition,
    required this.timestamp,
    this.pressure,
    this.tilt,
    this.orientation,
  });

  factory CanvasInputSample.fromPointerEvent({
    required PointerEvent event,
    required Offset screenPosition,
    required Offset documentPosition,
  }) {
    final supportsPressure = event.kind != PointerDeviceKind.mouse &&
        event.pressureMin.isFinite &&
        event.pressureMax.isFinite &&
        event.pressureMax > event.pressureMin;
    final isStylus = event.kind == PointerDeviceKind.stylus ||
        event.kind == PointerDeviceKind.invertedStylus;
    return CanvasInputSample(
      pointerId: event.pointer,
      kind: event.kind,
      screenPosition: screenPosition,
      documentPosition: documentPosition,
      timestamp: event.timeStamp,
      pressure: supportsPressure && event.pressure.isFinite
          ? event.pressure
          : null,
      tilt: isStylus && event.tilt.isFinite && event.tilt != 0
          ? event.tilt
          : null,
      orientation:
          isStylus && event.orientation.isFinite && event.orientation != 0
              ? event.orientation
              : null,
    );
  }

  final int pointerId;
  final PointerDeviceKind kind;

  /// Viewport-local logical pixels, not document pixels.
  final Offset screenPosition;

  /// Document-space pixels after applying the current viewport transform.
  final Offset documentPosition;
  final Duration timestamp;

  /// Null when pressure is not reported by the active pointer device.
  final double? pressure;

  /// Null when stylus tilt is not reported by the active pointer device.
  final double? tilt;

  /// Null when stylus orientation is not reported by the active pointer device.
  final double? orientation;

  CanvasInputCapabilities get capabilities => CanvasInputCapabilities(
        pressure: pressure != null,
        tilt: tilt != null,
        orientation: orientation != null,
      );
}

class CapturedCanvasStroke {
  CapturedCanvasStroke({
    required this.pointerId,
    required this.kind,
    required this.startedAt,
    required this.endedAt,
    required List<CanvasInputSample> samples,
  }) : samples = List.unmodifiable(samples);

  final int pointerId;
  final PointerDeviceKind kind;
  final Duration startedAt;
  final Duration endedAt;
  final List<CanvasInputSample> samples;

  CanvasInputCapabilities get capabilities => CanvasInputCapabilities(
        pressure: samples.any((sample) => sample.pressure != null),
        tilt: samples.any((sample) => sample.tilt != null),
        orientation: samples.any((sample) => sample.orientation != null),
      );
}
