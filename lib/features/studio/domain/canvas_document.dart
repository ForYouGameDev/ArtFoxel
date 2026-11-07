import 'package:flutter/material.dart';

enum CanvasOrientation { portrait, landscape, square }

class CanvasDocument {
  static final defaultPortrait = CanvasDocument.portrait();

  CanvasDocument({
    required this.width,
    required this.height,
    this.dpi = 300,
    this.backgroundColor = const Color(0xFFFFFFFF),
    Rect? safeBounds,
  }) : safeBounds = safeBounds ??
            Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()) {
    if (width <= 0 || height <= 0) {
      throw ArgumentError('Canvas dimensions must be positive.');
    }
    if (!dpi.isFinite || dpi <= 0) {
      throw ArgumentError.value(dpi, 'dpi', 'Must be finite and positive.');
    }
    final bounds = this.safeBounds;
    if (!bounds.left.isFinite ||
        !bounds.top.isFinite ||
        !bounds.right.isFinite ||
        !bounds.bottom.isFinite ||
        bounds.left < 0 ||
        bounds.top < 0 ||
        bounds.right > width ||
        bounds.bottom > height ||
        bounds.isEmpty) {
      throw ArgumentError.value(
        bounds,
        'safeBounds',
        'Must be a non-empty rectangle inside the canvas.',
      );
    }
  }

  factory CanvasDocument.portrait({
    int width = 1536,
    int height = 2048,
    double dpi = 300,
    Color? backgroundColor = const Color(0xFFFFFFFF),
    Rect? safeBounds,
  }) =>
      CanvasDocument(
        width: width,
        height: height,
        dpi: dpi,
        backgroundColor: backgroundColor,
        safeBounds: safeBounds,
      );

  factory CanvasDocument.landscape({
    int width = 2048,
    int height = 1536,
    double dpi = 300,
    Color? backgroundColor = const Color(0xFFFFFFFF),
    Rect? safeBounds,
  }) =>
      CanvasDocument(
        width: width,
        height: height,
        dpi: dpi,
        backgroundColor: backgroundColor,
        safeBounds: safeBounds,
      );

  final int width;
  final int height;
  final double dpi;

  /// `null` represents a transparent document background.
  final Color? backgroundColor;
  final Rect safeBounds;

  @override
  bool operator ==(Object other) =>
      other is CanvasDocument &&
      other.width == width &&
      other.height == height &&
      other.dpi == dpi &&
      other.backgroundColor == backgroundColor &&
      other.safeBounds == safeBounds;

  @override
  int get hashCode => Object.hash(width, height, dpi, backgroundColor, safeBounds);

  CanvasOrientation get orientation {
    if (width == height) return CanvasOrientation.square;
    return width > height
        ? CanvasOrientation.landscape
        : CanvasOrientation.portrait;
  }
}
