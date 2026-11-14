import 'package:artfoxel/features/studio/application/sketch_controller.dart';
import 'package:artfoxel/features/studio/domain/canvas_document.dart';
import 'package:artfoxel/features/studio/domain/sketch_document_data.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  SketchController make() => SketchController(
        data: SketchDocumentData.blank(CanvasDocument(width: 400, height: 400, backgroundColor: null)),
        rasterize: false,
      );

  test('Move tool on an empty layer explains and selects nothing', () {
    final c = make();
    c.setTool(SketchTool.move);
    expect(c.manipKind, ManipKind.none);
    expect(c.manipBox, isNull);
    c.dispose();
  });

  test('leaving the Move tool clears selections', () {
    final c = make();
    c.setTool(SketchTool.move);
    c.setTool(SketchTool.draw);
    expect(c.selectedReferenceId, isNull);
    expect(c.transformSession, isNull);
    c.dispose();
  });

  test('ManipBox hit testing', () {
    const box = ManipBox([Offset(0, 0), Offset(100, 0), Offset(100, 50), Offset(0, 50)], canRotate: true, canStretch: true);
    expect(box.contains(const Offset(50, 25)), isTrue);
    expect(box.contains(const Offset(150, 25)), isFalse);
    expect(box.contains(const Offset(104, 25), slack: 6), isTrue);
    expect(box.center, const Offset(50, 25));
    expect(box.rotateHandle(40).dy, closeTo(-40, 1e-9));
  });
}
