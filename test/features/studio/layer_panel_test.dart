import 'package:artfoxel/features/studio/application/sketch_controller.dart';
import 'package:artfoxel/features/studio/domain/canvas_document.dart';
import 'package:artfoxel/features/studio/domain/layer_blend.dart';
import 'package:artfoxel/features/studio/domain/sketch_document_data.dart';
import 'package:artfoxel/features/studio/presentation/layer_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late SketchController controller;
  late ScrollController scroll;

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: LayerPanel(controller: controller, scroll: scroll)),
      ),
    );
  }

  setUp(() {
    scroll = ScrollController();
    controller = SketchController(
      data: SketchDocumentData.blank(CanvasDocument(width: 400, height: 300, backgroundColor: null)),
      rasterize: false,
    );
  });

  tearDown(() {
    scroll.dispose();
    controller.dispose();
  });

  testWidgets('shows layers, adds one and selects it', (tester) async {
    await pump(tester);
    expect(find.byKey(const ValueKey('layer-row-layer-1')), findsOneWidget);
    await tester.tap(find.byTooltip('Add layer'));
    await tester.pump();
    expect(find.byKey(const ValueKey('layer-row-layer-2')), findsOneWidget);
    expect(controller.activeLayerId, 'layer-2');
    await tester.tap(find.byKey(const ValueKey('layer-row-layer-1')));
    await tester.pump();
    expect(controller.activeLayerId, 'layer-1');
  });

  testWidgets('visibility and lock toggles update the document', (tester) async {
    await pump(tester);
    await tester.tap(find.byTooltip('Hide').first);
    await tester.pump();
    expect(controller.data.layers.first.visible, isFalse);
    await tester.tap(find.byTooltip('Lock').first);
    await tester.pump();
    expect(controller.data.layers.first.locked, isTrue);
    controller.undo();
    await tester.pump();
    expect(controller.data.layers.first.locked, isFalse);
  });

  testWidgets('groups show nested layers and can collapse', (tester) async {
    await pump(tester);
    await tester.tap(find.byTooltip('Group selected layer'));
    await tester.pump();
    expect(find.byKey(const ValueKey('layer-row-layer-1')), findsOneWidget);
    await tester.tap(find.byTooltip('Collapse'));
    await tester.pump();
    expect(find.byKey(const ValueKey('layer-row-layer-1')), findsNothing);
    await tester.tap(find.byTooltip('Expand'));
    await tester.pump();
    expect(find.byKey(const ValueKey('layer-row-layer-1')), findsOneWidget);
  });

  testWidgets('blend mode list contains only supported modes', (tester) async {
    await pump(tester);
    await tester.tap(find.byType(DropdownButton<LayerBlend>));
    await tester.pumpAndSettle();
    expect(find.text('Multiply').last, findsOneWidget);
    expect(find.text('Linear Burn'), findsNothing);
    expect(find.text('Hard Mix'), findsNothing);
    await tester.tap(find.text('Multiply').last);
    await tester.pumpAndSettle();
    expect(controller.data.layers.first.blend, LayerBlend.multiply);
  });
}
