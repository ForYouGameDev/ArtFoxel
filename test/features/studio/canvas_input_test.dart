import 'package:artfoxel/features/studio/domain/canvas_input.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('input behavior defaults to stylus/mouse drawing and finger navigation',
      () {
    const defaults = CanvasInputSettings();
    expect(
      defaults.behaviorFor(PointerDeviceKind.touch),
      CanvasInputBehavior.navigate,
    );
    expect(
      defaults.behaviorFor(PointerDeviceKind.stylus),
      CanvasInputBehavior.draw,
    );
    expect(
      defaults.behaviorFor(PointerDeviceKind.mouse),
      CanvasInputBehavior.draw,
    );
    expect(
      defaults.behaviorFor(PointerDeviceKind.unknown),
      CanvasInputBehavior.ignore,
    );

    const drawingWithFinger = CanvasInputSettings(
      fingerBehavior: CanvasInputBehavior.draw,
      stylusBehavior: CanvasInputBehavior.ignore,
    );
    expect(
      drawingWithFinger.behaviorFor(PointerDeviceKind.touch),
      CanvasInputBehavior.draw,
    );
    expect(
      drawingWithFinger.behaviorFor(PointerDeviceKind.stylus),
      CanvasInputBehavior.ignore,
    );
  });

  test('capability labels include only data actually captured', () {
    const positionOnly = CanvasInputCapabilities();
    const stylusData = CanvasInputCapabilities(
      pressure: true,
      tilt: true,
      orientation: true,
    );

    expect(positionOnly.label, 'position only');
    expect(stylusData.label, 'pressure, tilt, orientation');
  });

  test('pointer samples retain only capabilities reported by the device', () {
    final mouseSample = CanvasInputSample.fromPointerEvent(
      event: const PointerDownEvent(
        pointer: 3,
        kind: PointerDeviceKind.mouse,
        position: Offset(12, 18),
        timeStamp: Duration(milliseconds: 4),
        pressure: 1,
        pressureMin: 0,
        pressureMax: 1,
      ),
      screenPosition: const Offset(12, 18),
      documentPosition: const Offset(120, 180),
    );
    final stylusSample = CanvasInputSample.fromPointerEvent(
      event: const PointerDownEvent(
        pointer: 9,
        kind: PointerDeviceKind.stylus,
        position: Offset(20, 25),
        timeStamp: Duration(milliseconds: 8),
        pressure: .6,
        pressureMin: 0,
        pressureMax: 1,
        tilt: .4,
        orientation: .7,
      ),
      screenPosition: const Offset(20, 25),
      documentPosition: const Offset(200, 250),
    );

    expect(mouseSample.pointerId, 3);
    expect(mouseSample.timestamp, const Duration(milliseconds: 4));
    expect(mouseSample.pressure, isNull);
    expect(mouseSample.tilt, isNull);
    expect(mouseSample.orientation, isNull);
    expect(stylusSample.pointerId, 9);
    expect(stylusSample.pressure, .6);
    expect(stylusSample.tilt, .4);
    expect(stylusSample.orientation, .7);
    expect(stylusSample.capabilities.label, 'pressure, tilt, orientation');
  });
}
