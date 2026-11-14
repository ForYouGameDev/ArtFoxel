import 'dart:convert';

import 'package:artfoxel/features/studio/application/workspace_layout.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('beginner mode shows fewer tools but never removes any from the list', () {
    const pro = WorkspaceLayout();
    final beginner = pro.copyWith(mode: UiMode.beginner);
    expect(pro.visibleTools.length, SideTool.values.length);
    expect(beginner.visibleTools.length, lessThan(pro.visibleTools.length));
    expect(beginner.visibleTools, containsAll([SideTool.brush, SideTool.eraser, SideTool.image]));
    expect(beginner.toolOrder.length, SideTool.values.length);
  });

  test('hidden tools and order are respected', () {
    final l = const WorkspaceLayout().copyWith(
      hiddenTools: {SideTool.filters},
      toolOrder: [SideTool.eraser, ...SideTool.values.where((t) => t != SideTool.eraser)],
    );
    expect(l.visibleTools.first, SideTool.eraser);
    expect(l.visibleTools.contains(SideTool.filters), isFalse);
  });

  test('layout JSON round trip and tolerance of bad data', () {
    final l = const WorkspaceLayout().copyWith(
      mode: UiMode.beginner,
      side: ToolbarSide.right,
      showQuickStrip: false,
      hiddenTools: {SideTool.rulers},
    );
    final back = WorkspaceLayout.fromJson(jsonDecode(jsonEncode(l.toJson())));
    expect(back.mode, UiMode.beginner);
    expect(back.side, ToolbarSide.right);
    expect(back.showQuickStrip, isFalse);
    expect(back.hiddenTools, {SideTool.rulers});
    final junk = WorkspaceLayout.fromJson({'mode': 5, 'toolOrder': ['nope', 'brush', 'brush'], 'hiddenTools': 'x'});
    expect(junk.mode, UiMode.professional);
    expect(junk.toolOrder.length, SideTool.values.length);
    expect(junk.toolOrder.first, SideTool.brush);
    expect(WorkspaceLayout.fromJson(null).side, ToolbarSide.left);
  });

  test('controller persists the layout', () async {
    SharedPreferences.setMockInitialValues({});
    final c = WorkspaceLayoutController(SharedPreferences.getInstance());
    await Future<void>.delayed(Duration.zero);
    await c.update(c.state.copyWith(side: ToolbarSide.right, mode: UiMode.beginner));
    final again = WorkspaceLayoutController(SharedPreferences.getInstance());
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(again.state.side, ToolbarSide.right);
    expect(again.state.mode, UiMode.beginner);
    await again.reset();
    expect(again.state.mode, UiMode.professional);
  });
}
