import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/sketch_controller.dart';
import '../application/workspace_layout.dart';
import '../domain/brush_preset.dart';
import '../domain/builtin_brushes.dart';
import 'assist_sheet.dart';
import 'brush_picker_sheet.dart';
import 'brush_preview.dart';
import 'brush_quick_strip.dart';
import 'color_sheet.dart';
import 'compact_color_panel.dart';
import 'filter_studio.dart';
import 'layer_panel.dart';
import 'manipulate_bar.dart';
import 'reference_studio.dart';
import 'selection_sheet.dart';
import 'shape_sheet.dart';
import 'sketch_io_sheets.dart';
import 'workspace_layout_sheet.dart';

class ShellMenuItem {
  const ShellMenuItem(this.value, this.label);
  final String value;
  final String label;
}

/// The drawing workspace used by both Sketch Studio and Animation Studio:
/// a compact top bar, a floating side toolbar, and a collapsible bottom panel
/// around a canvas that gets every remaining pixel. The studios stay separate;
/// the Animation Studio adds its timeline through [timeline].
class WorkspaceShell extends ConsumerStatefulWidget {
  const WorkspaceShell({
    required this.controller,
    required this.canvas,
    required this.title,
    required this.onBack,
    this.saveIndicator,
    this.timeline,
    this.menuItems = const [],
    this.onMenu,
    this.onAddImage,
    this.topActions = const [],
    this.toolOverrides = const {},
    super.key,
  });

  final SketchController controller;
  final Widget canvas;
  final String title;
  final VoidCallback onBack;
  final Widget? saveIndicator;

  /// Animation-only strip shown at the bottom (frames, playback, onion skin).
  final Widget? timeline;

  /// Studio-specific entries in the "more" menu.
  final List<ShellMenuItem> menuItems;
  final ValueChanged<String>? onMenu;

  /// Replaces the default "import as layer" action (Animation imports frames).
  final VoidCallback? onAddImage;

  /// Extra buttons placed in the top bar (e.g. Animation: export).
  final List<Widget> topActions;

  /// Replaces what a side-toolbar tool does (Animation: references use its
  /// own reference-image pipeline).
  final Map<SideTool, VoidCallback> toolOverrides;

  @override
  ConsumerState<WorkspaceShell> createState() => _WorkspaceShellState();
}

class _WorkspaceShellState extends ConsumerState<WorkspaceShell> {
  bool _canvasOnly = false;
  bool _colorPanel = false;
  BrushPreset _brushBeforeEraser = BuiltInBrushes.defaultBrush;

  SketchController get c => widget.controller;

  @override
  void dispose() {
    if (_canvasOnly) SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  /// Canvas-only mode hides every panel; leaving it restores the layout
  /// exactly because nothing in the saved layout was changed.
  void _setCanvasOnly(bool on) {
    setState(() {
      _canvasOnly = on;
      if (on) _colorPanel = false;
    });
    SystemChrome.setEnabledSystemUIMode(on ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge);
  }

  void _update(WorkspaceLayout next) => ref.read(workspaceLayoutProvider.notifier).update(next);

  void _toggleEraser() {
    if (c.brush.erase) {
      c.selectBrush(_brushBeforeEraser);
    } else {
      _brushBeforeEraser = c.brush;
      c.selectBrush(BuiltInBrushes.byId('builtin.eraser')!);
    }
  }

  void _addImage() {
    final custom = widget.onAddImage;
    if (custom != null) {
      custom();
    } else {
      showSketchImportSheet(context, c);
    }
  }

  @override
  Widget build(BuildContext context) {
    final layout = ref.watch(workspaceLayoutProvider);
    final scheme = Theme.of(context).colorScheme;
    final sideLeft = layout.side == ToolbarSide.left;

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Stack(children: [
          Column(children: [
            if (!_canvasOnly) _topBar(context, layout),
            Expanded(child: Stack(children: [
              Positioned.fill(child: widget.canvas),
              if (!_canvasOnly && layout.showSideBar)
                Positioned(
                  top: 8,
                  bottom: 8,
                  left: sideLeft ? 6 : null,
                  right: sideLeft ? null : 6,
                  child: Align(
                    alignment: sideLeft ? Alignment.topLeft : Alignment.topRight,
                    child: _sideBar(context, layout),
                  ),
                ),
              if (!_canvasOnly && !layout.showSideBar)
                Positioned(
                  top: 8,
                  left: sideLeft ? 6 : null,
                  right: sideLeft ? null : 6,
                  child: _pill(
                    scheme,
                    IconButton(
                      tooltip: 'Show tools',
                      onPressed: () => _update(layout.copyWith(showSideBar: true)),
                      icon: const Icon(Icons.construction_rounded),
                    ),
                  ),
                ),
              if (_canvasOnly)
                Positioned(
                  top: 8,
                  left: sideLeft ? 6 : null,
                  right: sideLeft ? null : 6,
                  child: _canvasOnlyBar(scheme),
                ),
              if (_colorPanel && !_canvasOnly)
                Positioned(
                  top: 8,
                  left: sideLeft ? null : 62,
                  right: sideLeft ? 8 : null,
                  width: 230,
                  child: CompactColorPanel(
                    controller: c,
                    onClose: () => setState(() => _colorPanel = false),
                  ),
                ),
            ])),
            if (!_canvasOnly) _bottomPanel(context, layout),
          ]),
        ]),
      ),
    );
  }

  // ---- small helpers ---------------------------------------------------------------

  Widget _pill(ColorScheme scheme, Widget child) => Material(
        color: scheme.surface.withValues(alpha: .92),
        elevation: 2,
        borderRadius: BorderRadius.circular(24),
        child: child,
      );

  Widget _canvasOnlyBar(ColorScheme scheme) => ListenableBuilder(
        listenable: c,
        builder: (context, _) => _pill(
          scheme,
          Row(mainAxisSize: MainAxisSize.min, children: [
            IconButton(
              tooltip: 'Show tools (exit canvas-only)',
              onPressed: () => _setCanvasOnly(false),
              icon: const Icon(Icons.fullscreen_exit_rounded),
            ),
            IconButton(tooltip: 'Undo', onPressed: c.canUndo ? c.undo : null, icon: const Icon(Icons.undo_rounded)),
            IconButton(tooltip: 'Redo', onPressed: c.canRedo ? c.redo : null, icon: const Icon(Icons.redo_rounded)),
          ]),
        ),
      );

  // ---- top bar -----------------------------------------------------------------------

  Widget _topBar(BuildContext context, WorkspaceLayout layout) {
    final scheme = Theme.of(context).colorScheme;
    final pro = layout.mode == UiMode.professional;
    return Material(
      color: scheme.surfaceContainerLow,
      child: SizedBox(
        height: 48,
        child: ListenableBuilder(
          listenable: c,
          builder: (context, _) {
            final brush = c.brush;
            return SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: ConstrainedBox(
                constraints: BoxConstraints(minWidth: MediaQuery.sizeOf(context).width),
                child: Row(children: [
                  IconButton(tooltip: 'Back', onPressed: widget.onBack, icon: const Icon(Icons.arrow_back_rounded)),
                  IconButton(tooltip: 'Undo', onPressed: c.canUndo ? c.undo : null, icon: const Icon(Icons.undo_rounded)),
                  IconButton(tooltip: 'Redo', onPressed: c.canRedo ? c.redo : null, icon: const Icon(Icons.redo_rounded)),
                  if (widget.saveIndicator != null) widget.saveIndicator!,
                  const SizedBox(width: 6),
                  InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: () => showBrushPicker(context, c),
                    child: Tooltip(
                      message: 'Current brush: ${brush.name}',
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        RepaintBoundary(child: BrushPreview(brush: brush, width: 56, height: 30)),
                        if (pro)
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 84),
                            child: Padding(
                              padding: const EdgeInsets.only(left: 6),
                              child: Text(brush.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
                            ),
                          ),
                      ]),
                    ),
                  ),
                  _valueChip('Size', '${c.size.round()} px', c.size, 1, 300, c.setSize),
                  _valueChip('Opacity', '${(c.opacity * 100).round()}%', c.opacity, 0.02, 1, c.setOpacity),
                  Tooltip(
                    message: 'Colour',
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: () => setState(() => _colorPanel = !_colorPanel),
                      onLongPress: () => showColorSheet(context, c),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        child: Container(
                          width: 30,
                          height: 30,
                          decoration: BoxDecoration(
                            color: Color(c.colorArgb),
                            shape: BoxShape.circle,
                            border: Border.all(color: scheme.outline, width: 2),
                          ),
                        ),
                      ),
                    ),
                  ),
                  ...widget.topActions,
                  IconButton(tooltip: 'Layers', onPressed: () => showLayerPanel(context, c), icon: const Icon(Icons.layers_outlined)),
                  IconButton(
                    tooltip: 'Canvas only (hide all panels)',
                    onPressed: () => _setCanvasOnly(true),
                    icon: const Icon(Icons.fullscreen_rounded),
                  ),
                  PopupMenuButton<String>(
                    tooltip: 'More',
                    onSelected: (v) {
                      if (v == '_layout') {
                        showWorkspaceLayoutSheet(context);
                      } else {
                        widget.onMenu?.call(v);
                      }
                    },
                    itemBuilder: (_) => [
                      for (final item in widget.menuItems) PopupMenuItem(value: item.value, child: Text(item.label)),
                      const PopupMenuDivider(),
                      const PopupMenuItem(value: '_layout', child: Text('Workspace layout…')),
                    ],
                  ),
                ]),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _valueChip(String label, String text, double value, double min, double max, ValueChanged<double> onChanged) {
    return PopupMenuButton<void>(
      tooltip: label,
      padding: EdgeInsets.zero,
      itemBuilder: (_) => [
        PopupMenuItem<void>(
          enabled: false,
          child: ListenableBuilder(
            listenable: c,
            builder: (context, _) {
              final v = label == 'Size' ? c.size : c.opacity;
              return SizedBox(
                width: 240,
                child: Row(children: [
                  Text(label),
                  Expanded(child: Slider(value: v.clamp(min, max).toDouble(), min: min, max: max, onChanged: onChanged)),
                ]),
              );
            },
          ),
        ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
          ),
          child: Text(text, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
        ),
      ),
    );
  }

  // ---- side toolbar --------------------------------------------------------------------

  bool _selected(SideTool tool) {
    final b = c.brush;
    return switch (tool) {
      SideTool.brush => c.tool == SketchTool.draw && !b.erase && b.engine != BrushEngineKind.smudge,
      SideTool.pencil => c.tool == SketchTool.draw && b.id == 'builtin.hb_pencil',
      SideTool.eraser => c.tool == SketchTool.draw && b.erase,
      SideTool.smudge => c.tool == SketchTool.draw && b.engine == BrushEngineKind.smudge,
      SideTool.selection => c.tool.isSelection,
      SideTool.shapes => c.tool == SketchTool.shape,
      SideTool.eyedropper => c.tool == SketchTool.eyedropper,
      SideTool.move => c.tool == SketchTool.move,
      _ => false,
    };
  }

  IconData _icon(SideTool tool) => switch (tool) {
        SideTool.brush => Icons.brush_rounded,
        SideTool.pencil => Icons.edit_rounded,
        SideTool.eraser => Icons.cleaning_services_outlined,
        SideTool.smudge => Icons.fingerprint_rounded,
        SideTool.selection => Icons.highlight_alt_rounded,
        SideTool.shapes => Icons.category_outlined,
        SideTool.eyedropper => Icons.colorize,
        SideTool.move => Icons.open_with_rounded,
        SideTool.image => Icons.add_photo_alternate_outlined,
        SideTool.rulers => Icons.straighten_rounded,
        SideTool.references => Icons.collections_outlined,
        SideTool.filters => Icons.tune_rounded,
      };

  void _tap(SideTool tool) {
    final override = widget.toolOverrides[tool];
    if (override != null) {
      override();
      return;
    }
    switch (tool) {
      case SideTool.brush:
        if (_selected(tool)) {
          showBrushPicker(context, c);
        } else {
          final last = c.brush.erase || c.brush.engine == BrushEngineKind.smudge
              ? BuiltInBrushes.byId('builtin.hard_round') ?? BuiltInBrushes.defaultBrush
              : c.brush;
          c.selectBrush(last);
        }
      case SideTool.pencil:
        c.selectBrush(BuiltInBrushes.byId('builtin.hb_pencil') ?? BuiltInBrushes.defaultBrush);
      case SideTool.eraser:
        _toggleEraser();
      case SideTool.smudge:
        c.selectBrush(BuiltInBrushes.byId('builtin.basic_smudge') ?? BuiltInBrushes.defaultBrush);
      case SideTool.shapes:
        showShapeSheet(context, c);
      case SideTool.eyedropper:
        c.setTool(c.tool == SketchTool.eyedropper ? SketchTool.draw : SketchTool.eyedropper);
      case SideTool.move:
        c.setTool(c.tool == SketchTool.move ? SketchTool.draw : SketchTool.move);
      case SideTool.image:
        _addImage();
      case SideTool.rulers:
        showAssistSheet(context, c);
      case SideTool.references:
        showReferenceStudio(context, c);
      case SideTool.filters:
        showFilterStudio(context, c);
      case SideTool.selection:
        showSelectionSheet(context, c);
    }
  }

  Widget _sideBar(BuildContext context, WorkspaceLayout layout) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final tools = layout.visibleTools;
        return Material(
          color: scheme.surface.withValues(alpha: .93),
          elevation: 3,
          borderRadius: BorderRadius.circular(22),
          child: SizedBox(
            width: 46,
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(vertical: 4),
              children: [
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Hide tools',
                  onPressed: () => _update(layout.copyWith(showSideBar: false)),
                  icon: Icon(layout.side == ToolbarSide.left ? Icons.chevron_left_rounded : Icons.chevron_right_rounded),
                ),
                for (final tool in tools)
                  tool == SideTool.selection
                      ? _selectionButton(scheme)
                      : IconButton(
                          visualDensity: VisualDensity.compact,
                          tooltip: tool.label,
                          isSelected: _selected(tool),
                          style: _selected(tool)
                              ? IconButton.styleFrom(backgroundColor: scheme.primaryContainer, foregroundColor: scheme.onPrimaryContainer)
                              : null,
                          onPressed: () => _tap(tool),
                          icon: Icon(_icon(tool)),
                        ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _selectionButton(ColorScheme scheme) {
    return PopupMenuButton<Object>(
      tooltip: 'Selection',
      onSelected: (v) {
        if (v is SketchTool) {
          c.selectTool(v);
        } else {
          showSelectionSheet(context, c);
        }
      },
      itemBuilder: (_) => const [
        PopupMenuItem(value: SketchTool.selectRect, child: Text('Rectangle')),
        PopupMenuItem(value: SketchTool.selectEllipse, child: Text('Ellipse')),
        PopupMenuItem(value: SketchTool.selectLasso, child: Text('Lasso')),
        PopupMenuItem(value: SketchTool.selectPolygon, child: Text('Polygon')),
        PopupMenuItem(value: SketchTool.magicWand, child: Text('Magic wand')),
        PopupMenuItem(value: SketchTool.colorRange, child: Text('Colour range')),
        PopupMenuDivider(),
        PopupMenuItem(value: 'options', child: Text('Selection options…')),
      ],
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: c.tool.isSelection ? scheme.primaryContainer : null,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Icon(_icon(SideTool.selection), size: 24),
      ),
    );
  }

  // ---- bottom panel -----------------------------------------------------------------------

  Widget _bottomPanel(BuildContext context, WorkspaceLayout layout) {
    final scheme = Theme.of(context).colorScheme;
    final maxH = MediaQuery.sizeOf(context).height * 0.42;
    return Material(
      color: scheme.surfaceContainerLow,
      child: SafeArea(
        top: false,
        child: ListenableBuilder(
          listenable: c,
          builder: (context, _) {
            if (c.tool == SketchTool.move) {
              return ManipulateBar(controller: c);
            }
            final collapsed = layout.bottomCollapsed || !layout.showBottomPanel;
            return Column(mainAxisSize: MainAxisSize.min, children: [
              if (c.tool != SketchTool.draw || c.editingMask)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      _status(),
                      key: const ValueKey('active-tool-status'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
              InkWell(
                onTap: () => _update(layout.copyWith(bottomCollapsed: !collapsed, showBottomPanel: true)),
                child: SizedBox(
                  height: 22,
                  child: Center(
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(collapsed ? Icons.keyboard_arrow_up_rounded : Icons.keyboard_arrow_down_rounded, size: 20),
                      if (collapsed) Text(c.brush.name, style: const TextStyle(fontSize: 11)),
                    ]),
                  ),
                ),
              ),
              if (!collapsed)
                ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: maxH),
                  child: SingleChildScrollView(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      if (layout.showQuickStrip)
                        BrushQuickStrip(
                          controller: c,
                          compact: true,
                          onOpenLibrary: () => showBrushPicker(context, c),
                        ),
                      _contextControls(layout),
                    ]),
                  ),
                ),
              if (widget.timeline != null) widget.timeline!,
            ]);
          },
        ),
      ),
    );
  }

  String _status() {
    final layer = c.activeLayer;
    if (c.editingMask) return 'Mask of "${layer.name}"';
    if (c.tool == SketchTool.shape) {
      return 'Shape tool · drag to draw, tap a shape to edit';
    }
    if (c.tool.isSelection) {
      return 'Selection tool · ${c.tool.name} · ${c.selectionMode.label}';
    }
    if (c.tool == SketchTool.eyedropper) {
      return 'Eyedropper · tap the canvas to pick a colour';
    }
    return '"${layer.name}" · ${c.brush.name}';
  }

  Widget _slider(String label, double v, double min, double max, ValueChanged<double> on, {String? text}) {
    return SizedBox(
      height: 32,
      child: Row(children: [
        SizedBox(width: 64, child: Padding(padding: const EdgeInsets.only(left: 12), child: Text(label, style: const TextStyle(fontSize: 11)))),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(trackHeight: 3, thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8)),
            child: Slider(value: v.clamp(min, max).toDouble(), min: min, max: max, onChanged: on),
          ),
        ),
        SizedBox(width: 44, child: Text(text ?? v.toStringAsFixed(2), style: const TextStyle(fontSize: 11), textAlign: TextAlign.end)),
        const SizedBox(width: 8),
      ]),
    );
  }

  /// Controls that belong to the active brush. Smudge brushes get their own
  /// strength/wetness/pickup/deposit sliders and the mode chooser.
  Widget _contextControls(WorkspaceLayout layout) {
    final pro = layout.mode == UiMode.professional;
    final b = c.brush;
    final smudge = b.engine == BrushEngineKind.smudge;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      _slider('Size', c.size, 1, 300, c.setSize, text: '${c.size.round()}'),
      _slider('Opacity', c.opacity, 0.02, 1, c.setOpacity, text: '${(c.opacity * 100).round()}%'),
      if (smudge) ...[
        _slider('Strength', b.smudgeStrength, 0.02, 1, (v) => c.tweakBrush({'smudgeStrength': v})),
        if (pro) ...[
          _slider('Wetness', b.wetness, 0, 1, (v) => c.tweakBrush({'wetness': v})),
          _slider('Pickup', b.pickup, 0, 1, (v) => c.tweakBrush({'pickup': v})),
          _slider('Deposit', b.deposit, 0, 1, (v) => c.tweakBrush({'deposit': v})),
          SizedBox(
            height: 40,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              children: [
                for (final mode in SmudgeMode.values)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      visualDensity: VisualDensity.compact,
                      label: Text(mode.label, style: const TextStyle(fontSize: 11)),
                      selected: b.smudgeMode == mode,
                      onSelected: (_) => c.tweakBrush({'smudgeMode': mode.name}),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ],
      if (pro && !smudge) ...[
        _slider('Flow', c.flow, 0.02, 1, c.setFlow),
        _slider('Stabilize', c.stabilization, 0, 1, c.setStabilization),
      ],
    ]);
  }
}
