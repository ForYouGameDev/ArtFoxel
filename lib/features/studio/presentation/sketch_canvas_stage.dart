import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../../core/theme/design_tokens.dart';
import '../application/sketch_controller.dart';
import '../domain/canvas_document.dart';
import '../domain/canvas_input.dart';
import '../domain/canvas_viewport.dart';

class SketchCanvasStage extends StatefulWidget {
  const SketchCanvasStage({
    required this.document,
    this.inputSettings = const CanvasInputSettings(),
    this.onStrokeCaptured,
    this.controller,
    this.onColorSampled,
    super.key,
  });

  final CanvasDocument document;
  final CanvasInputSettings inputSettings;
  final ValueChanged<CapturedCanvasStroke>? onStrokeCaptured;

  /// When set, strokes are rendered with the brush engine and recorded in the
  /// controller. Without it the stage only captures input (Phase 2.2 mode).
  final SketchController? controller;

  /// Called with the sampled colour (or null for transparent/outside) after
  /// an eyedropper tap.
  final ValueChanged<int?>? onColorSampled;

  @override
  State<SketchCanvasStage> createState() => _SketchCanvasStageState();
}

class _SketchCanvasStageState extends State<SketchCanvasStage> {
  final _canvasKey = GlobalKey();
  CanvasViewport? _viewport;
  CanvasViewport? _gestureStart;
  Offset _startFocal = Offset.zero;
  bool _pinchManip = false;
  final Map<int, _ActiveCanvasPointer> _activePointers = {};
  final Map<int, _CanvasStrokeBuilder> _strokeBuilders = {};
  bool _multiPointerNavigation = false;
  String? _lastInputSummary;
  final Set<int> _stylusPointers = {};
  DateTime? _lastStylusAt;
  int? _eyedropperPointer;
  int? _selectionPointer;

  @override
  void didUpdateWidget(covariant SketchCanvasStage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.document != widget.document) {
      _viewport = null;
    }
    if (oldWidget.document != widget.document ||
        oldWidget.inputSettings != widget.inputSettings) {
      _gestureStart = null;
      _activePointers.clear();
      _strokeBuilders.clear();
      _multiPointerNavigation = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(color: colors.surfaceContainer),
      child: Stack(
        children: [
          Positioned.fill(
            child: CustomPaint(
              painter: _WorkspaceGridPainter(
                color: colors.outlineVariant.withValues(alpha: .32),
              ),
            ),
          ),
          Positioned.fill(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final size = constraints.biggest;
                final viewport = _viewport == null
                    ? CanvasViewport(
                        document: widget.document,
                        viewportSize: size,
                      ).fitToScreen(
                        padding: _fitPadding(size),
                      )
                    : _viewport!.withViewportSize(size);
                return Listener(
                  key: _canvasKey,
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: (event) => _handlePointerDown(event, viewport),
                  onPointerMove: (event) => _handlePointerMove(event, viewport),
                  onPointerUp: (event) => _handlePointerUp(event, viewport),
                  onPointerCancel: _handlePointerCancel,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onScaleStart: (details) {
                      _gestureStart = viewport;
                      _startFocal = details.localFocalPoint;
                      // Two fingers on the selected object pinch/twist/move
                      // that object; anywhere else they move the view.
                      final sketch = widget.controller;
                      _pinchManip = details.pointerCount >= 2 &&
                          sketch != null &&
                          sketch.tool == SketchTool.move &&
                          sketch.manipPinchBegin(viewport.screenToDocument(details.localFocalPoint));
                    },
                    onScaleUpdate: (details) {
                      final start = _gestureStart;
                      if (details.pointerCount < 2 || start == null) return;
                      final focal = details.localFocalPoint;
                      if (_pinchManip) {
                        widget.controller?.manipPinchUpdate(
                          details.scale,
                          details.rotation,
                          start.screenToDocument(focal),
                        );
                        return;
                      }
                      // Zoom and twist about where the fingers started, then
                      // follow the fingers, so two fingers pan in any
                      // direction while they pinch.
                      final zoomed = start.transformAt(
                        zoom: start.zoom * details.scale,
                        rotation: widget.inputSettings.rotationEnabled
                            ? start.rotation + details.rotation
                            : start.rotation,
                        screenFocalPoint: _startFocal,
                      );
                      setState(() {
                        _viewport = zoomed.panBy(focal - _startFocal);
                      });
                    },
                    onScaleEnd: (_) {
                      if (_pinchManip) {
                        _pinchManip = false;
                        widget.controller?.manipPinchEnd();
                      }
                      _gestureStart = null;
                    },
                    child: CustomPaint(
                      painter: _CanvasSurfacePainter(viewport, widget.controller),
                      child: const SizedBox.expand(),
                    ),
                  ),
                );
              },
            ),
          ),
          Positioned(
            top: ArtFoxelSpacing.sm,
            right: ArtFoxelSpacing.sm,
            child: Column(
              children: [
                _ViewportAction(
                  icon: Icons.fit_screen_rounded,
                  tooltip: 'Fit canvas to screen',
                  onPressed: () {
                    final viewport = _currentViewport();
                    _updateViewport(
                      viewport,
                      (viewport) => viewport.fitToScreen(
                        padding: _fitPadding(viewport.viewportSize),
                      ),
                    );
                  },
                ),
                const SizedBox(height: ArtFoxelSpacing.xs),
                _ViewportAction(
                  icon: Icons.center_focus_strong_rounded,
                  tooltip: 'Reset view',
                  onPressed: () => _updateViewport(
                    _currentViewport(),
                    (viewport) => viewport.resetView(),
                  ),
                ),
              ],
            ),
          ),
          Positioned(
            left: ArtFoxelSpacing.sm,
            bottom: ArtFoxelSpacing.sm,
            child: IgnorePointer(
              child: _CanvasChip(
                child: Text(
                  _viewport == null ? 'Fit' : '${(_viewport!.zoom * 100).round()}%',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _updateViewport(
    CanvasViewport viewport,
    CanvasViewport Function(CanvasViewport) update,
  ) {
    setState(() {
      _viewport = update(viewport);
    });
  }

  CanvasViewport _currentViewport() {
    final renderObject = _canvasKey.currentContext?.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) {
      throw StateError('Canvas viewport is not available.');
    }
    final size = renderObject.size;
    return (_viewport ??
            CanvasViewport(document: widget.document, viewportSize: size)
                .fitToScreen(padding: _fitPadding(size)))
        .withViewportSize(size);
  }

  bool get _stylusRecentlyActive {
    if (_stylusPointers.isNotEmpty) return true;
    final last = _lastStylusAt;
    return last != null &&
        DateTime.now().difference(last) < const Duration(milliseconds: 700);
  }

  static bool _isStylus(PointerDeviceKind kind) =>
      kind == PointerDeviceKind.stylus ||
      kind == PointerDeviceKind.invertedStylus;

  void _handlePointerDown(PointerDownEvent event, CanvasViewport viewport) {
    final position = _localPosition(event.position);
    if (position == null) return;
    final behavior = _behaviorFor(event);
    if (_isStylus(event.kind)) {
      _stylusPointers.add(event.pointer);
      _lastStylusAt = DateTime.now();
    }
    // Ignored pointers (palm rejection, disabled devices) leave no trace.
    if (behavior == CanvasInputBehavior.ignore) return;
    _activePointers[event.pointer] = _ActiveCanvasPointer(
      behavior: behavior,
      lastPosition: position,
    );

    if (_activePointers.length > 1) {
      _multiPointerNavigation = true;
      _strokeBuilders.clear();
      _eyedropperPointer = null;
      if (_selectionPointer != null) {
        _selectionPointer = null;
        widget.controller?.cancelShape();
      }
      widget.controller?.cancelStroke();
      return;
    }

    if (behavior == CanvasInputBehavior.draw) {
      final sample = _sampleFor(event, position, viewport);
      if (widget.controller?.tool == SketchTool.eyedropper) {
        _eyedropperPointer = event.pointer;
        return;
      }
      final sketch = widget.controller;
      if (sketch != null && (sketch.tool.isSelection ||
          sketch.tool == SketchTool.shape ||
          sketch.tool == SketchTool.move)) {
        _selectionPointer = event.pointer;
        sketch.toolPointerDown(sample.documentPosition);
        return;
      }
      _strokeBuilders[event.pointer] = _CanvasStrokeBuilder(sample);
      widget.controller?.beginStroke(sample);
    }
  }

  void _handlePointerMove(PointerMoveEvent event, CanvasViewport viewport) {
    final activePointer = _activePointers[event.pointer];
    if (activePointer == null) return;
    final position = _localPosition(event.position);
    if (position == null) return;

    if (_multiPointerNavigation) {
      activePointer.lastPosition = position;
      return;
    }

    if (_selectionPointer == event.pointer) {
      widget.controller?.toolPointerMove(
        _sampleFor(event, position, viewport).documentPosition,
      );
      activePointer.lastPosition = position;
      return;
    }
    final stroke = _strokeBuilders[event.pointer];
    if (stroke != null) {
      final sample = _sampleFor(event, position, viewport);
      stroke.add(sample);
      widget.controller?.extendStroke(sample);
    } else if (activePointer.behavior == CanvasInputBehavior.navigate) {
      final delta = position - activePointer.lastPosition;
      if (delta != Offset.zero) {
        setState(() {
          _viewport = (_viewport ?? viewport).panBy(delta);
        });
      }
    }
    activePointer.lastPosition = position;
  }

  void _handlePointerUp(PointerUpEvent event, CanvasViewport viewport) {
    _stylusPointers.remove(event.pointer);
    final activePointer = _activePointers[event.pointer];
    if (activePointer == null) return;
    final position = _localPosition(event.position);

    if (_eyedropperPointer == event.pointer) {
      _eyedropperPointer = null;
      if (!_multiPointerNavigation && position != null) {
        _sampleColor(viewport.screenToDocument(position));
      }
    }

    if (_selectionPointer == event.pointer) {
      _selectionPointer = null;
      if (_multiPointerNavigation || position == null) {
        widget.controller?.cancelShape();
      } else {
        widget.controller?.toolPointerUp(viewport.screenToDocument(position));
      }
    }

    final stroke = _strokeBuilders.remove(event.pointer);
    if (stroke != null && !_multiPointerNavigation && position != null) {
      final sample = _sampleFor(event, position, viewport);
      stroke.add(sample);
      final capturedStroke = stroke.finish(event.timeStamp);
      final capabilities = capturedStroke.capabilities;
      widget.controller?.endStroke(sample);
      widget.controller?.noteCapabilities(capabilities);
      setState(() {
        _lastInputSummary =
            '${_deviceName(capturedStroke.kind)} · ${capabilities.label}';
      });
      widget.onStrokeCaptured?.call(capturedStroke);
    }
    _activePointers.remove(event.pointer);
    if (_activePointers.isEmpty) _multiPointerNavigation = false;
  }

  void _handlePointerCancel(PointerCancelEvent event) {
    _stylusPointers.remove(event.pointer);
    _activePointers.remove(event.pointer);
    _strokeBuilders.remove(event.pointer);
    if (_eyedropperPointer == event.pointer) _eyedropperPointer = null;
    if (_selectionPointer == event.pointer) {
      _selectionPointer = null;
      widget.controller?.cancelShape();
    }
    widget.controller?.cancelStroke();
    if (_activePointers.isEmpty) _multiPointerNavigation = false;
  }

  Future<void> _sampleColor(Offset documentPoint) async {
    final controller = widget.controller;
    if (controller == null) return;
    final color = (controller.sampleReferences
            ? await controller.pickReferenceColor(documentPoint)
            : null) ??
        await controller.sampleColorAt(documentPoint);
    if (!mounted) return;
    if (color != null) controller.setColor(color);
    widget.onColorSampled?.call(color);
  }

  CanvasInputBehavior _behaviorFor(PointerDownEvent event) {
    if (event.kind == PointerDeviceKind.mouse &&
        (event.buttons & (kSecondaryMouseButton | kMiddleMouseButton)) != 0) {
      return CanvasInputBehavior.navigate;
    }
    if (event.kind == PointerDeviceKind.touch &&
        widget.inputSettings.palmRejection &&
        _stylusRecentlyActive) {
      return CanvasInputBehavior.ignore;
    }
    return widget.inputSettings.behaviorFor(event.kind);
  }

  CanvasInputSample _sampleFor(
    PointerEvent event,
    Offset screenPosition,
    CanvasViewport viewport,
  ) =>
      CanvasInputSample.fromPointerEvent(
        event: event,
        screenPosition: screenPosition,
        documentPosition: viewport.screenToDocument(screenPosition),
      );

  Offset? _localPosition(Offset globalPosition) {
    final renderObject = _canvasKey.currentContext?.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) return null;
    return renderObject.globalToLocal(globalPosition);
  }
}

class _ActiveCanvasPointer {
  _ActiveCanvasPointer({
    required this.behavior,
    required this.lastPosition,
  });

  final CanvasInputBehavior behavior;
  Offset lastPosition;
}

class _CanvasStrokeBuilder {
  _CanvasStrokeBuilder(CanvasInputSample firstSample)
      : pointerId = firstSample.pointerId,
        kind = firstSample.kind,
        startedAt = firstSample.timestamp,
        _samples = [firstSample];

  final int pointerId;
  final PointerDeviceKind kind;
  final Duration startedAt;
  final List<CanvasInputSample> _samples;

  void add(CanvasInputSample sample) => _samples.add(sample);

  CapturedCanvasStroke finish(Duration endedAt) => CapturedCanvasStroke(
        pointerId: pointerId,
        kind: kind,
        startedAt: startedAt,
        endedAt: endedAt,
        samples: _samples,
      );
}

String _deviceName(PointerDeviceKind kind) => switch (kind) {
      PointerDeviceKind.touch => 'Finger',
      PointerDeviceKind.stylus => 'Stylus',
      PointerDeviceKind.invertedStylus => 'Inverted stylus',
      PointerDeviceKind.mouse => 'Mouse',
      _ => 'Pointer',
    };

class _ViewportAction extends StatelessWidget {
  const _ViewportAction({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surface.withValues(alpha: .92),
      shape: const CircleBorder(),
      child: IconButton(
        icon: Icon(icon, size: 19),
        tooltip: tooltip,
        visualDensity: VisualDensity.compact,
        onPressed: onPressed,
      ),
    );
  }
}

class _CanvasChip extends StatelessWidget {
  const _CanvasChip({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface.withValues(alpha: .92),
        borderRadius: BorderRadius.circular(ArtFoxelRadius.pill),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
        child: child,
      ),
    );
  }
}

double _fitPadding(Size size) =>
    math.min(32.0, math.min(size.width, size.height) * .1).toDouble();

class _CanvasSurfacePainter extends CustomPainter {
  _CanvasSurfacePainter(this.viewport, this.controller)
      : super(repaint: controller?.repaint);

  final CanvasViewport viewport;
  final SketchController? controller;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.translate(
      size.width / 2 + viewport.pan.dx,
      size.height / 2 + viewport.pan.dy,
    );
    canvas.rotate(viewport.rotation);
    canvas.scale(viewport.zoom);
    canvas.translate(
      -viewport.document.width / 2,
      -viewport.document.height / 2,
    );

    final documentRect = Rect.fromLTWH(
      0,
      0,
      viewport.document.width.toDouble(),
      viewport.document.height.toDouble(),
    );
    final pagePath = Path()..addRect(documentRect);
    canvas.drawShadow(
      pagePath,
      Colors.black.withValues(alpha: .32),
      28 / viewport.zoom,
      true,
    );

    final backgroundColor = viewport.document.backgroundColor;
    if (backgroundColor == null) {
      _paintTransparencyGrid(canvas, documentRect);
    } else {
      canvas.drawRect(documentRect, Paint()..color = backgroundColor);
    }
    final sketch = controller;
    sketch?.paintUnderlay?.call(canvas);
    if (sketch != null) {
      // Artwork lives in its own layer so erasing never cuts into the page.
      canvas.saveLayer(documentRect, Paint());
      sketch.paintArtwork(canvas);
      canvas.restore();
      sketch.paintOverlay(canvas, viewport.zoom);
      sketch.paintGuides?.call(canvas);
    }
    _paintSafeBounds(canvas, viewport);
    canvas.restore();
  }

  void _paintTransparencyGrid(Canvas canvas, Rect documentRect) {
    const tileSize = 64.0;
    final light = Paint()..color = const Color(0xFFF4F4F4);
    final dark = Paint()..color = const Color(0xFFD8D8D8);
    final columns = (documentRect.width / tileSize).ceil();
    final rows = (documentRect.height / tileSize).ceil();
    for (var row = 0; row < rows; row++) {
      for (var column = 0; column < columns; column++) {
        final rect = Rect.fromLTWH(
          column * tileSize,
          row * tileSize,
          math
              .min(tileSize, documentRect.width - column * tileSize)
              .toDouble(),
          math
              .min(tileSize, documentRect.height - row * tileSize)
              .toDouble(),
        );
        canvas.drawRect(rect, (row + column).isEven ? light : dark);
      }
    }
  }

  void _paintSafeBounds(Canvas canvas, CanvasViewport viewport) {
    final bounds = viewport.document.safeBounds;
    if (bounds.left == 0 &&
        bounds.top == 0 &&
        bounds.right == viewport.document.width &&
        bounds.bottom == viewport.document.height) {
      return;
    }
    final paint = Paint()
      ..color = const Color(0xFF3478F6).withValues(alpha: .7)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1 / viewport.zoom;
    canvas.drawRect(bounds, paint);
  }

  @override
  bool shouldRepaint(covariant _CanvasSurfacePainter oldDelegate) =>
      oldDelegate.viewport != viewport || oldDelegate.controller != controller;
}

class _WorkspaceGridPainter extends CustomPainter {
  const _WorkspaceGridPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const gap = 28.0;
    final paint = Paint()
      ..color = color
      ..strokeWidth = .7;
    for (double x = 0; x < size.width; x += gap) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (double y = 0; y < size.height; y += gap) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _WorkspaceGridPainter oldDelegate) =>
      oldDelegate.color != color;
}
