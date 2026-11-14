import 'package:artfoxel/features/studio/domain/canvas_document.dart';
import 'package:artfoxel/features/studio/domain/canvas_input.dart';
import 'package:artfoxel/features/studio/presentation/sketch_canvas_stage.dart';
import 'package:artfoxel/features/studio/presentation/studio_screen.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('sketch shows a portrait canvas without an animation timeline',
      (tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: StudioScreen(kind: StudioKind.sketch),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byTooltip('Fit canvas to screen'), findsOneWidget);
    expect(find.byTooltip('Reset view'), findsOneWidget);
    expect(find.text('Animation timeline'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('landscape transparent document is shown without a timeline',
      (tester) async {
    final document = CanvasDocument.landscape(
      backgroundColor: null,
      safeBounds: const Rect.fromLTWH(100, 80, 1848, 1376),
    );
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: StudioScreen(
            kind: StudioKind.sketch,
            canvasDocument: document,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byTooltip('Fit canvas to screen'), findsOneWidget);
    expect(find.text('Animation timeline'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('animation retains its separate timeline', (tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: StudioScreen(kind: StudioKind.animation),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Animation timeline'), findsOneWidget);
    expect(find.textContaining('2048 x 1536'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('stylus input captures a document-mapped stroke', (tester) async {
    final strokes = <CapturedCanvasStroke>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 640,
              height: 540,
              child: SketchCanvasStage(
                document: CanvasDocument.portrait(),
                onStrokeCaptured: strokes.add,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final canvasRect = tester.getRect(find.byType(SketchCanvasStage));
    final viewportRect = tester.getRect(
      find.descendant(
        of: find.byType(SketchCanvasStage),
        matching: find.byType(Listener),
      ).first,
    );
    final gesture = await tester.startGesture(
      canvasRect.center,
      kind: PointerDeviceKind.stylus,
    );
    await gesture.moveBy(const Offset(20, 15));
    await gesture.up();
    await tester.pump();

    expect(strokes, hasLength(1));
    expect(strokes.single.kind, PointerDeviceKind.stylus);
    expect(strokes.single.pointerId, greaterThan(0));
    expect(strokes.single.samples.length, greaterThanOrEqualTo(2));
    expect(
      strokes.single.samples.first.screenPosition,
      viewportRect.center - viewportRect.topLeft,
    );
    expect(
      strokes.single.samples.first.documentPosition.dx,
      inInclusiveRange(0, 1536),
    );
    expect(
      strokes.single.samples.first.documentPosition.dy,
      inInclusiveRange(0, 2048),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('finger navigation does not emit a drawing stroke', (
    tester,
  ) async {
    final strokes = <CapturedCanvasStroke>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 640,
              height: 540,
              child: SketchCanvasStage(
                document: CanvasDocument.portrait(),
                onStrokeCaptured: strokes.add,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final canvasRect = tester.getRect(find.byType(SketchCanvasStage));
    final gesture = await tester.startGesture(canvasRect.center);
    await gesture.moveBy(const Offset(28, 12));
    await gesture.up();
    await tester.pump();

    expect(strokes, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('finger drawing can be enabled in the input settings', (
    tester,
  ) async {
    final strokes = <CapturedCanvasStroke>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 640,
              height: 540,
              child: SketchCanvasStage(
                document: CanvasDocument.portrait(),
                inputSettings: const CanvasInputSettings(
                  fingerBehavior: CanvasInputBehavior.draw,
                ),
                onStrokeCaptured: strokes.add,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final canvasRect = tester.getRect(find.byType(SketchCanvasStage));
    final gesture = await tester.startGesture(canvasRect.center);
    await gesture.moveBy(const Offset(20, 10));
    await gesture.up();
    await tester.pump();

    expect(strokes, hasLength(1));
    expect(strokes.single.kind, PointerDeviceKind.touch);
    expect(tester.takeException(), isNull);
  });

  testWidgets('adding a navigation pointer cancels an active stroke', (
    tester,
  ) async {
    final strokes = <CapturedCanvasStroke>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 640,
              height: 540,
              child: SketchCanvasStage(
                document: CanvasDocument.portrait(),
                onStrokeCaptured: strokes.add,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final canvasRect = tester.getRect(find.byType(SketchCanvasStage));
    final stylus = await tester.startGesture(
      canvasRect.center,
      pointer: 1,
      kind: PointerDeviceKind.stylus,
    );
    await stylus.moveBy(const Offset(10, 5));
    final secondPointer = await tester.startGesture(
      canvasRect.center + const Offset(80, 0),
      pointer: 2,
    );
    await stylus.moveBy(const Offset(15, 10));
    await stylus.up();
    await secondPointer.up();
    await tester.pump();

    expect(strokes, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
