import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/diagnostics/app_log.dart';

/// Beginner keeps only the essentials in reach; Professional shows every tool
/// and every control. Nothing is removed in either mode: hidden tools stay in
/// the menus.
enum UiMode {
  beginner('Beginner'),
  professional('Professional');

  const UiMode(this.label);
  final String label;
}

enum ToolbarSide {
  left('Left'),
  right('Right');

  const ToolbarSide(this.label);
  final String label;
}

/// Tools that can sit in the floating side toolbar.
enum SideTool {
  brush('Brush', beginner: true),
  pencil('Pencil', beginner: true),
  eraser('Eraser', beginner: true),
  smudge('Smudge', beginner: false),
  selection('Selection', beginner: false),
  shapes('Shapes and fills', beginner: false),
  eyedropper('Eyedropper', beginner: true),
  move('Move / resize', beginner: true),
  image('Add image', beginner: true),
  rulers('Rulers and symmetry', beginner: false),
  references('References', beginner: false),
  filters('Filters', beginner: false);

  const SideTool(this.label, {required this.beginner});
  final String label;
  final bool beginner;
}

/// Persisted workspace layout, shared by Sketch and Animation Studio.
class WorkspaceLayout {
  const WorkspaceLayout({
    this.mode = UiMode.professional,
    this.side = ToolbarSide.left,
    this.showSideBar = true,
    this.showBottomPanel = true,
    this.showQuickStrip = true,
    this.bottomCollapsed = false,
    this.toolOrder = _defaultOrder,
    this.hiddenTools = const {},
  });

  static const List<SideTool> _defaultOrder = SideTool.values;

  final UiMode mode;

  /// Which screen edge the floating toolbar hugs. Right-handed artists
  /// normally keep it on the left.
  final ToolbarSide side;
  final bool showSideBar;
  final bool showBottomPanel;
  final bool showQuickStrip;
  final bool bottomCollapsed;
  final List<SideTool> toolOrder;
  final Set<SideTool> hiddenTools;

  /// Tools shown in the side toolbar for the current mode and settings.
  List<SideTool> get visibleTools => [
        for (final tool in toolOrder)
          if (!hiddenTools.contains(tool) &&
              (mode == UiMode.professional || tool.beginner))
            tool,
      ];

  WorkspaceLayout copyWith({
    UiMode? mode,
    ToolbarSide? side,
    bool? showSideBar,
    bool? showBottomPanel,
    bool? showQuickStrip,
    bool? bottomCollapsed,
    List<SideTool>? toolOrder,
    Set<SideTool>? hiddenTools,
  }) =>
      WorkspaceLayout(
        mode: mode ?? this.mode,
        side: side ?? this.side,
        showSideBar: showSideBar ?? this.showSideBar,
        showBottomPanel: showBottomPanel ?? this.showBottomPanel,
        showQuickStrip: showQuickStrip ?? this.showQuickStrip,
        bottomCollapsed: bottomCollapsed ?? this.bottomCollapsed,
        toolOrder: toolOrder ?? this.toolOrder,
        hiddenTools: hiddenTools ?? this.hiddenTools,
      );

  Map<String, Object> toJson() => {
        'mode': mode.name,
        'side': side.name,
        'showSideBar': showSideBar,
        'showBottomPanel': showBottomPanel,
        'showQuickStrip': showQuickStrip,
        'bottomCollapsed': bottomCollapsed,
        'toolOrder': [for (final t in toolOrder) t.name],
        'hiddenTools': [for (final t in hiddenTools) t.name],
      };

  /// Tolerant: unknown or malformed values fall back to defaults, and tools
  /// added in later versions are appended so they never disappear.
  factory WorkspaceLayout.fromJson(Object? raw) {
    if (raw is! Map) return const WorkspaceLayout();
    T pick<T extends Enum>(List<T> values, Object? name, T fallback) {
      for (final v in values) {
        if (v.name == name) return v;
      }
      return fallback;
    }

    bool flag(String key, bool fallback) {
      final v = raw[key];
      return v is bool ? v : fallback;
    }

    List<SideTool> tools(Object? list) {
      if (list is! List) return const [];
      return [
        for (final name in list)
          for (final t in SideTool.values)
            if (t.name == name) t,
      ];
    }

    final order = <SideTool>[];
    for (final t in tools(raw['toolOrder'])) {
      if (!order.contains(t)) order.add(t);
    }
    for (final t in SideTool.values) {
      if (!order.contains(t)) order.add(t);
    }
    return WorkspaceLayout(
      mode: pick(UiMode.values, raw['mode'], UiMode.professional),
      side: pick(ToolbarSide.values, raw['side'], ToolbarSide.left),
      showSideBar: flag('showSideBar', true),
      showBottomPanel: flag('showBottomPanel', true),
      showQuickStrip: flag('showQuickStrip', true),
      bottomCollapsed: flag('bottomCollapsed', false),
      toolOrder: order,
      hiddenTools: tools(raw['hiddenTools']).toSet(),
    );
  }
}

class WorkspaceLayoutController extends StateNotifier<WorkspaceLayout> {
  WorkspaceLayoutController(this._preferences) : super(const WorkspaceLayout()) {
    _load();
  }

  final Future<SharedPreferences> _preferences;
  static const storageKey = 'workspace_layout_v1';

  Future<void> _load() async {
    try {
      final raw = (await _preferences).getString(storageKey);
      if (raw == null) return;
      final next = WorkspaceLayout.fromJson(jsonDecode(raw));
      if (mounted) state = next;
    } catch (error, stack) {
      AppLog.error('Workspace layout load failed', error: error, stackTrace: stack);
    }
  }

  Future<void> update(WorkspaceLayout next) async {
    state = next;
    try {
      await (await _preferences).setString(storageKey, jsonEncode(next.toJson()));
    } catch (error, stack) {
      AppLog.error('Workspace layout save failed', error: error, stackTrace: stack);
    }
  }

  Future<void> reset() => update(const WorkspaceLayout());
}

final workspaceLayoutProvider =
    StateNotifierProvider<WorkspaceLayoutController, WorkspaceLayout>((ref) {
  return WorkspaceLayoutController(SharedPreferences.getInstance());
});
