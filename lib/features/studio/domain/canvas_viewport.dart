import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'canvas_document.dart';

class CanvasViewport {
  const CanvasViewport({
    required this.document,
    required this.viewportSize,
    this.zoom = 1,
    this.rotation = 0,
    this.pan = Offset.zero,
  }) : assert(zoom > 0);

  static const minZoom = 0.000000001;
  static const maxZoom = 64.0;

  final CanvasDocument document;

  /// Logical viewport pixels, independent of document pixel dimensions.
  final Size viewportSize;

  /// Document-to-screen scale. A value of 1 maps one document pixel to one
  /// logical screen pixel.
  final double zoom;

  /// View rotation in radians, applied around the document center.
  final double rotation;

  /// Screen-space translation from the viewport center.
  final Offset pan;

  double get rotationDegrees => rotation * 180 / math.pi;

  Offset get _documentCenter =>
      Offset(document.width / 2, document.height / 2);

  Offset get _viewportCenter =>
      Offset(viewportSize.width / 2, viewportSize.height / 2);

  /// Maps a document point to viewport-local logical screen coordinates.
  Offset documentToScreen(Offset documentPoint) {
    final relative = documentPoint - _documentCenter;
    final scaled = _rotate(relative * zoom, rotation);
    return _viewportCenter + pan + scaled;
  }

  /// Maps viewport-local logical screen coordinates to document pixels.
  Offset screenToDocument(Offset screenPoint) {
    final relative = (screenPoint - _viewportCenter - pan) / zoom;
    return _documentCenter + _rotate(relative, -rotation);
  }

  /// Document-space bounds covered by the viewport, including areas outside
  /// the document when the canvas is panned or letterboxed.
  Rect get visibleDocumentBounds {
    final corners = <Offset>[
      screenToDocument(Offset.zero),
      screenToDocument(Offset(viewportSize.width, 0)),
      screenToDocument(Offset(viewportSize.width, viewportSize.height)),
      screenToDocument(Offset(0, viewportSize.height)),
    ];
    final xs = corners.map((point) => point.dx);
    final ys = corners.map((point) => point.dy);
    return Rect.fromLTRB(
      xs.reduce((a, b) => math.min(a, b).toDouble()),
      ys.reduce((a, b) => math.min(a, b).toDouble()),
      xs.reduce((a, b) => math.max(a, b).toDouble()),
      ys.reduce((a, b) => math.max(a, b).toDouble()),
    );
  }

  /// Normalized, document-clipped visible bounds for a navigator/minimap.
  Rect get navigatorViewport {
    final visible = visibleDocumentBounds.intersect(
      Rect.fromLTWH(
        0,
        0,
        document.width.toDouble(),
        document.height.toDouble(),
      ),
    );
    if (visible.isEmpty) return Rect.zero;
    return Rect.fromLTRB(
      visible.left / document.width,
      visible.top / document.height,
      visible.right / document.width,
      visible.bottom / document.height,
    );
  }

  CanvasViewport withViewportSize(Size size) => CanvasViewport(
        document: document,
        viewportSize: size,
        zoom: zoom,
        rotation: rotation,
        pan: pan,
      );

  CanvasViewport panBy(Offset screenDelta) => CanvasViewport(
        document: document,
        viewportSize: viewportSize,
        zoom: zoom,
        rotation: rotation,
        pan: pan + screenDelta,
      );

  CanvasViewport zoomAt(double factor, Offset screenFocalPoint) =>
      transformAt(
        zoom: zoom * factor,
        rotation: rotation,
        screenFocalPoint: screenFocalPoint,
      );

  CanvasViewport rotateAt(double radians, Offset screenFocalPoint) =>
      transformAt(
        zoom: zoom,
        rotation: rotation + radians,
        screenFocalPoint: screenFocalPoint,
      );

  /// Applies a scale/rotation while keeping the document point under the focal
  /// point stationary on screen.
  CanvasViewport transformAt({
    required double zoom,
    required double rotation,
    required Offset screenFocalPoint,
  }) {
    if (!zoom.isFinite || zoom <= 0 || !rotation.isFinite) {
      throw ArgumentError('Viewport transforms must be finite and positive.');
    }
    final nextZoom = zoom.clamp(minZoom, maxZoom).toDouble();
    final documentFocalPoint = screenToDocument(screenFocalPoint);
    final relative = _rotate(
      (documentFocalPoint - _documentCenter) * nextZoom,
      rotation,
    );
    final nextPan = screenFocalPoint - _viewportCenter - relative;
    return CanvasViewport(
      document: document,
      viewportSize: viewportSize,
      zoom: nextZoom,
      rotation: rotation,
      pan: nextPan,
    );
  }

  CanvasViewport fitToScreen({double padding = 32}) {
    if (!viewportSize.width.isFinite ||
        !viewportSize.height.isFinite ||
        viewportSize.width <= padding * 2 ||
        viewportSize.height <= padding * 2 ||
        !padding.isFinite ||
        padding < 0) {
      throw ArgumentError.value(
        viewportSize,
        'viewportSize',
        'Must have enough finite space to fit the document.',
      );
    }
    final cosine = math.cos(rotation).abs();
    final sine = math.sin(rotation).abs();
    final rotatedWidth = cosine * document.width + sine * document.height;
    final rotatedHeight = sine * document.width + cosine * document.height;
    final fittedZoom = math.min(
      (viewportSize.width - padding * 2) / rotatedWidth,
      (viewportSize.height - padding * 2) / rotatedHeight,
    );
    return CanvasViewport(
      document: document,
      viewportSize: viewportSize,
      zoom: math.min(fittedZoom, maxZoom).toDouble(),
      rotation: rotation,
      pan: Offset.zero,
    );
  }

  CanvasViewport resetView() => CanvasViewport(
        document: document,
        viewportSize: viewportSize,
      );
}

Offset _rotate(Offset point, double radians) {
  final cosine = math.cos(radians);
  final sine = math.sin(radians);
  return Offset(
    point.dx * cosine - point.dy * sine,
    point.dx * sine + point.dy * cosine,
  );
}
