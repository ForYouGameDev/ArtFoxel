import 'dart:math' as math;

import 'package:artfoxel/features/studio/domain/canvas_document.dart';
import 'package:artfoxel/features/studio/domain/canvas_viewport.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CanvasDocument', () {
    test('supports portrait, landscape, square, and transparent documents', () {
      final portrait = CanvasDocument.portrait();
      final landscape = CanvasDocument.landscape(backgroundColor: null);
      final square = CanvasDocument(width: 100, height: 100);

      expect(portrait.orientation, CanvasOrientation.portrait);
      expect(landscape.orientation, CanvasOrientation.landscape);
      expect(landscape.backgroundColor, isNull);
      expect(square.orientation, CanvasOrientation.square);
      expect(portrait.dpi, 300);
    });

    test('rejects invalid dimensions, DPI, and safe bounds', () {
      expect(
        () => CanvasDocument(width: 0, height: 100),
        throwsArgumentError,
      );
      expect(
        () => CanvasDocument(width: 100, height: 100, dpi: double.infinity),
        throwsArgumentError,
      );
      expect(
        () => CanvasDocument(
          width: 100,
          height: 100,
          safeBounds: const Rect.fromLTWH(90, 90, 20, 20),
        ),
        throwsArgumentError,
      );
    });
  });

  group('CanvasViewport', () {
    final document = CanvasDocument(
      width: 1200,
      height: 800,
      safeBounds: const Rect.fromLTWH(80, 60, 1040, 680),
    );
    const viewportSize = Size(900, 700);

    test('maps document and screen coordinates through pan, zoom, and rotation',
        () {
      final viewport = CanvasViewport(
        document: document,
        viewportSize: viewportSize,
        zoom: 1.7,
        rotation: math.pi / 5,
        pan: const Offset(45, -28),
      );
      const source = Offset(410, 350);

      final screenPoint = viewport.documentToScreen(source);
      final mappedBack = viewport.screenToDocument(screenPoint);

      expect(mappedBack.dx, closeTo(source.dx, 1e-9));
      expect(mappedBack.dy, closeTo(source.dy, 1e-9));
    });

    test('keeps the focal document point fixed while zooming and rotating', () {
      final initial = CanvasViewport(
        document: document,
        viewportSize: viewportSize,
        zoom: .8,
        pan: const Offset(30, 12),
      );
      const focalPoint = Offset(240, 310);
      final focalDocumentPoint = initial.screenToDocument(focalPoint);

      final changed = initial.transformAt(
        zoom: 1.6,
        rotation: math.pi / 3,
        screenFocalPoint: focalPoint,
      );

      final mappedFocalPoint = changed.documentToScreen(focalDocumentPoint);
      expect(mappedFocalPoint.dx, closeTo(focalPoint.dx, 1e-9));
      expect(mappedFocalPoint.dy, closeTo(focalPoint.dy, 1e-9));
      expect(changed.zoom, 1.6);
      expect(changed.rotation, closeTo(math.pi / 3, 1e-9));
    });

    test('fits rotated portrait or landscape bounds and centers the document',
        () {
      final viewport = CanvasViewport(
        document: document,
        viewportSize: viewportSize,
        rotation: math.pi / 2,
        pan: const Offset(50, -20),
      ).fitToScreen(padding: 20);
      final corners = [
        Offset.zero,
        Offset(document.width.toDouble(), 0),
        Offset(document.width.toDouble(), document.height.toDouble()),
        Offset(0, document.height.toDouble()),
      ].map(viewport.documentToScreen);

      expect(viewport.pan, Offset.zero);
      for (final corner in corners) {
        expect(corner.dx, greaterThanOrEqualTo(19.99));
        expect(corner.dx, lessThanOrEqualTo(viewportSize.width - 19.99));
        expect(corner.dy, greaterThanOrEqualTo(19.99));
        expect(corner.dy, lessThanOrEqualTo(viewportSize.height - 19.99));
      }
      final navigatorBounds = viewport.navigatorViewport;
      expect(navigatorBounds.left, greaterThanOrEqualTo(0));
      expect(navigatorBounds.top, greaterThanOrEqualTo(0));
      expect(navigatorBounds.right, lessThanOrEqualTo(1));
      expect(navigatorBounds.bottom, lessThanOrEqualTo(1));
    });

    test('pans, clamps zoom, exposes navigator bounds, and resets view', () {
      final initial = CanvasViewport(
        document: document,
        viewportSize: viewportSize,
      );
      final panned = initial.panBy(const Offset(20, 30));
      final zoomed = panned.zoomAt(1000, const Offset(100, 100));
      final reset = zoomed.resetView();

      expect(panned.pan, const Offset(20, 30));
      expect(zoomed.zoom, CanvasViewport.maxZoom);
      expect(panned.navigatorViewport, isNot(initial.navigatorViewport));
      expect(reset.zoom, 1);
      expect(reset.rotation, 0);
      expect(reset.pan, Offset.zero);
    });
  });
}
