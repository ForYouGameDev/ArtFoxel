import 'package:flutter/material.dart';

import '../../../core/theme/design_tokens.dart';
import '../../../core/widgets/unsaved_work_guard.dart';
import '../domain/canvas_document.dart';
import 'sketch_canvas_stage.dart';
import 'sketch_workspace.dart';

enum StudioKind { sketch, animation }

class StudioScreen extends StatelessWidget {
  const StudioScreen({
    required this.kind,
    this.canvasDocument,
    this.projectId,
    super.key,
  });

  final StudioKind kind;
  final CanvasDocument? canvasDocument;

  /// Sketch project to open (loaded from and autosaved to local storage).
  /// When null the sketch is an unsaved scratch canvas.
  final String? projectId;

  @override
  Widget build(BuildContext context) {
    if (kind == StudioKind.sketch) {
      return SketchWorkspace(
        projectId: projectId,
        canvasDocument: canvasDocument,
      );
    }
    final isSketch = kind == StudioKind.sketch;
    final title = isSketch ? 'Sketch Studio' : 'Animation Studio';
    final subtitle = isSketch
        ? 'A static-art canvas with a navigable document viewport.'
        : 'A dedicated animation workspace for the animation tools phase.';
    final icon = isSketch ? Icons.draw_rounded : Icons.movie_creation_rounded;
    final accent = isSketch ? ArtFoxelColors.blue : ArtFoxelColors.magenta;

    return UnsavedWorkGuard(
      hasUnsavedChanges: false,
      child: Scaffold(
        appBar: AppBar(
          title: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: .14),
                  borderRadius: BorderRadius.circular(ArtFoxelRadius.sm),
                ),
                child: Icon(icon, size: 20, color: accent),
              ),
              const SizedBox(width: ArtFoxelSpacing.sm),
              Text(title),
            ],
          ),
        ),
        body: SafeArea(
          top: false,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= 900;
              return Padding(
                padding: EdgeInsets.fromLTRB(
                  wide ? ArtFoxelSpacing.xl : ArtFoxelSpacing.md,
                  ArtFoxelSpacing.sm,
                  wide ? ArtFoxelSpacing.xl : ArtFoxelSpacing.md,
                  ArtFoxelSpacing.md,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (wide) ...[
                      Text(
                        subtitle,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
                            ),
                      ),
                      const SizedBox(height: ArtFoxelSpacing.md),
                    ],
                    Expanded(
                      child: isSketch
                          ? SketchCanvasStage(
                              document: canvasDocument ??
                                  CanvasDocument.defaultPortrait,
                            )
                          : _CanvasStage(
                              title: title,
                              subtitle: subtitle,
                              icon: icon,
                              accent: accent,
                              isWide: wide,
                            ),
                    ),
                    if (!isSketch) ...[
                      const SizedBox(height: ArtFoxelSpacing.md),
                      _AnimationTimeline(accent: accent),
                    ],
                    if (!wide && !isSketch) ...[
                      const SizedBox(height: ArtFoxelSpacing.xs),
                      Center(
                        child: Text(
                          'Animation workspace · Sketch remains separate',
                          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                color:
                                    Theme.of(context).colorScheme.onSurfaceVariant,
                              ),
                        ),
                      ),
                    ],
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _CanvasStage extends StatelessWidget {
  const _CanvasStage({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.accent,
    required this.isWide,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final Color accent;
  final bool isWide;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: colors.surfaceContainer,
        borderRadius: BorderRadius.circular(ArtFoxelRadius.md),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Stack(
        children: [
          Positioned.fill(
            child: CustomPaint(
              painter: _WorkspaceGridPainter(
                color: colors.outlineVariant.withValues(alpha: .32),
              ),
            ),
          ),
          Center(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final canvasWidth =
                    constraints.maxWidth < 520
                        ? constraints.maxWidth * .72
                        : 340.0;
                final canvasHeight = constraints.maxHeight * .74;
                return ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: canvasWidth.clamp(180.0, 520.0).toDouble(),
                    maxHeight: canvasHeight.clamp(180.0, 620.0).toDouble(),
                  ),
                  child: AspectRatio(
                    aspectRatio: isWide ? 1.15 : .76,
                    child: Container(
                      decoration: BoxDecoration(
                        color: Theme.of(context).brightness == Brightness.dark
                            ? const Color(0xFF202638)
                            : const Color(0xFFFFFFFF),
                        borderRadius:
                            BorderRadius.circular(ArtFoxelRadius.sm),
                        border: Border.all(
                          color: colors.outlineVariant.withValues(alpha: .7),
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: .12),
                            blurRadius: 28,
                            offset: const Offset(0, 12),
                          ),
                        ],
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Container(
                            width: 54,
                            height: 54,
                            decoration: BoxDecoration(
                              color: accent.withValues(alpha: .12),
                              borderRadius:
                                  BorderRadius.circular(ArtFoxelRadius.md),
                            ),
                            child: Icon(icon, color: accent, size: 26),
                          ),
                          const SizedBox(height: ArtFoxelSpacing.md),
                          Text(
                            title,
                            textAlign: TextAlign.center,
                            style: Theme.of(context)
                                .textTheme
                                .titleMedium
                                ?.copyWith(fontWeight: FontWeight.w800),
                          ),
                          const SizedBox(height: ArtFoxelSpacing.xs),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 20),
                            child: Text(
                              subtitle,
                              textAlign: TextAlign.center,
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(
                                    color: colors.onSurfaceVariant,
                                    height: 1.4,
                                  ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          Positioned(
            left: ArtFoxelSpacing.md,
            top: ArtFoxelSpacing.md,
            child: _StudioBadge(accent: accent),
          ),
        ],
      ),
    );
  }
}

class _StudioBadge extends StatelessWidget {
  const _StudioBadge({required this.accent});

  final Color accent;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(ArtFoxelRadius.pill),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
            ),
            const SizedBox(width: ArtFoxelSpacing.xs),
            Text(
              'WORKSPACE FOUNDATION',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                    letterSpacing: .6,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AnimationTimeline extends StatelessWidget {
  const _AnimationTimeline({required this.accent});

  final Color accent;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(ArtFoxelSpacing.md),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(ArtFoxelRadius.md),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Row(
        children: [
          Icon(Icons.view_timeline_outlined, color: accent),
          const SizedBox(width: ArtFoxelSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Animation timeline',
                  style: Theme.of(context)
                      .textTheme
                      .titleSmall
                      ?.copyWith(fontWeight: FontWeight.w800),
                ),
                Text(
                  'Frame tools will be available in a future release.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                ),
              ],
            ),
          ),
          Icon(Icons.lock_outline_rounded,
              size: 18, color: colors.onSurfaceVariant),
        ],
      ),
    );
  }
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
