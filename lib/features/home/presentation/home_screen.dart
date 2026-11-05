import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/providers.dart';
import '../../../core/theme/design_tokens.dart';
import '../../../core/widgets/artfoxel_components.dart';
import '../../../core/widgets/async_state_view.dart';
import '../../onboarding/presentation/onboarding_screen.dart';
import '../../projects/domain/art_project.dart';
import '../../studio/application/new_sketch.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final onboarding = ref.watch(onboardingCompleteProvider);
    return onboarding.when(
      loading: () => const _HomeLoading(),
      error: (error, stack) => Scaffold(
        body: AsyncStateView<bool>(
          value: AsyncSnapshot.withError(ConnectionState.done, error, stack),
          data: (_) => const SizedBox.shrink(),
          onRetry: () => ref.invalidate(onboardingCompleteProvider),
        ),
      ),
      data: (complete) =>
          complete ? const _HomeContent() : const OnboardingScreen(),
    );
  }
}

class _HomeContent extends ConsumerWidget {
  const _HomeContent();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(
            ArtFoxelSpacing.lg,
            ArtFoxelSpacing.md,
            ArtFoxelSpacing.lg,
            ArtFoxelSpacing.xl,
          ),
          sliver: SliverToBoxAdapter(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1080),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _HomeHeader(
                      onProfile: () => context.go('/profile'),
                      onSettings: () => context.push('/settings'),
                    ),
                    const SizedBox(height: ArtFoxelSpacing.lg),
                    _HeroCard(onCreate: () => openNewSketch(context, ref)),
                    const SizedBox(height: ArtFoxelSpacing.xl),
                    const SectionHeading(title: 'Choose your studio'),
                    const SizedBox(height: ArtFoxelSpacing.md),
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final isWide = constraints.maxWidth >= 640;
                        final sketch = StudioFeatureCard(
                          title: 'Sketch Studio',
                          description:
                              'Draw, paint and create amazing artwork.',
                          icon: Icons.draw_rounded,
                          gradient: ArtFoxelGradients.sketch,
                          onTap: () => openNewSketch(context, ref),
                        );
                        final animation = StudioFeatureCard(
                          title: 'Animation Studio',
                          description: 'Bring your drawings to life.',
                          icon: Icons.movie_creation_rounded,
                          gradient: ArtFoxelGradients.animation,
                          onTap: () => context.push('/studio/animation'),
                        );
                        if (!isWide) {
                          return Column(
                            children: [
                              SizedBox(height: 224, child: sketch),
                              const SizedBox(height: ArtFoxelSpacing.md),
                              SizedBox(height: 224, child: animation),
                            ],
                          );
                        }
                        return SizedBox(
                          height: 232,
                          child: Row(
                            children: [
                              Expanded(child: sketch),
                              const SizedBox(width: ArtFoxelSpacing.md),
                              Expanded(child: animation),
                            ],
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: ArtFoxelSpacing.xl),
                    const SectionHeading(title: 'Quick access'),
                    const SizedBox(height: ArtFoxelSpacing.md),
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final columns = constraints.maxWidth >= 700 ? 4 : 2;
                        return GridView.count(
                          crossAxisCount: columns,
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          mainAxisSpacing: ArtFoxelSpacing.sm,
                          crossAxisSpacing: ArtFoxelSpacing.sm,
                          childAspectRatio: columns == 4 ? 1.6 : 1.55,
                          children: [
                            _QuickActionCard(
                              icon: Icons.grid_view_rounded,
                              title: 'My projects',
                              subtitle: 'Browse your gallery',
                              onTap: () => context.push('/projects'),
                            ),
                            _QuickActionCard(
                              icon: Icons.person_outline_rounded,
                              title: 'My profile',
                              subtitle: 'Account and creator details',
                              onTap: () => context.go('/profile'),
                            ),
                            _QuickActionCard(
                              icon: Icons.tune_rounded,
                              title: 'Preferences',
                              subtitle: 'Theme and app settings',
                              onTap: () => context.push('/settings'),
                            ),
                            _QuickActionCard(
                              icon: Icons.people_outline_rounded,
                              title: 'Community',
                              subtitle: 'See what is coming soon',
                              onTap: () => context.go('/community'),
                            ),
                          ],
                        );
                      },
                    ),
                    const SizedBox(height: ArtFoxelSpacing.xl),
                    SectionHeading(
                      title: 'Recent projects',
                      actionLabel: 'See all',
                      onAction: () => context.push('/projects'),
                    ),
                    const SizedBox(height: ArtFoxelSpacing.md),
                    ref.watch(projectsProvider).when(
                          loading: () => const _ProjectPreviewLoading(),
                          error: (error, stack) => AsyncStateView<List<ArtProject>>(
                            value: AsyncSnapshot.withError(
                              ConnectionState.done,
                              error,
                              stack,
                            ),
                            data: (_) => const SizedBox.shrink(),
                            onRetry: () => ref.invalidate(projectsProvider),
                          ),
                          data: (projects) => projects.isEmpty
                              ? const _NoProjectsPreview()
                              : _RecentProjects(projects: projects.take(3).toList()),
                        ),
                    const SizedBox(height: ArtFoxelSpacing.xl),
                    Center(
                      child: Text(
                        'Create. Experiment. Inspire.',
                        style: Theme.of(context).textTheme.labelLarge?.copyWith(
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
                              letterSpacing: .5,
                            ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _HomeHeader extends StatelessWidget {
  const _HomeHeader({required this.onProfile, required this.onSettings});

  final VoidCallback onProfile;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Row(
      children: [
        const ArtFoxelLogo(size: 48, showWordmark: true),
        const Spacer(),
        IconButton(
          tooltip: 'Settings',
          onPressed: onSettings,
          icon: const Icon(Icons.settings_outlined),
        ),
        const SizedBox(width: ArtFoxelSpacing.xs),
        Semantics(
          button: true,
          label: 'Profile',
          child: InkWell(
            onTap: onProfile,
            borderRadius: BorderRadius.circular(ArtFoxelRadius.pill),
            child: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: colors.surfaceContainer,
                border: Border.all(color: colors.outlineVariant),
              ),
              child: Icon(Icons.person_outline_rounded, color: colors.primary),
            ),
          ),
        ),
      ],
    );
  }
}

class _HeroCard extends StatelessWidget {
  const _HeroCard({required this.onCreate});

  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 520;
        return Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            gradient: ArtFoxelGradients.surfaceGlow,
            borderRadius: BorderRadius.circular(ArtFoxelRadius.lg),
            border: Border.all(color: colors.outlineVariant),
          ),
          child: Stack(
            children: [
              Positioned(
                top: -60,
                right: compact ? -40 : 100,
                child: Container(
                  width: 200,
                  height: 200,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: ArtFoxelColors.violet.withValues(alpha: .1),
                  ),
                ),
              ),
              Padding(
                padding: EdgeInsets.all(compact ? 20 : 32),
                child: Row(
                  children: [
                    Expanded(
                      flex: 6,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          DecoratedBox(
                            decoration: BoxDecoration(
                              color: ArtFoxelColors.violet.withValues(alpha: .14),
                              borderRadius:
                                  BorderRadius.circular(ArtFoxelRadius.pill),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 7,
                              ),
                              child: Text(
                                'YOUR CREATIVE SPACE',
                                style: Theme.of(context)
                                    .textTheme
                                    .labelSmall
                                    ?.copyWith(
                                      color: colors.primary,
                                      fontWeight: FontWeight.w900,
                                      letterSpacing: 1.1,
                                    ),
                              ),
                            ),
                          ),
                          const SizedBox(height: ArtFoxelSpacing.md),
                          Text(
                            'Unleash your creativity',
                            style: (compact
                                    ? Theme.of(context).textTheme.headlineSmall
                                    : Theme.of(context).textTheme.headlineMedium)
                                ?.copyWith(
                                  fontWeight: FontWeight.w900,
                                  height: 1.08,
                                ),
                          ),
                          const SizedBox(height: ArtFoxelSpacing.sm),
                          Text(
                            'Your creative world starts here. Sketch, paint, design and animate your imagination.',
                            style:
                                Theme.of(context).textTheme.bodyLarge?.copyWith(
                                      color: colors.onSurfaceVariant,
                                      height: 1.45,
                                    ),
                          ),
                          const SizedBox(height: ArtFoxelSpacing.lg),
                          GradientButton(
                            label: 'New artwork',
                            icon: Icons.add_rounded,
                            onPressed: onCreate,
                          ),
                        ],
                      ),
                    ),
                    if (!compact) ...[
                      const SizedBox(width: ArtFoxelSpacing.lg),
                      Expanded(
                        flex: 4,
                        child: Center(
                          child: Image.asset(
                            'assets/branding/app_icon.png',
                            width: 220,
                            height: 220,
                            fit: BoxFit.contain,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (compact)
                Positioned(
                  top: 10,
                  right: 10,
                  child: Opacity(
                    opacity: .14,
                    child: Image.asset(
                      'assets/branding/app_icon.png',
                      width: 78,
                      height: 78,
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _QuickActionCard extends StatelessWidget {
  const _QuickActionCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(ArtFoxelRadius.md),
        child: Padding(
          padding: const EdgeInsets.all(ArtFoxelSpacing.md),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: colors.primary.withValues(alpha: .11),
                  borderRadius: BorderRadius.circular(ArtFoxelRadius.sm),
                ),
                child: Icon(icon, color: colors.primary, size: 21),
              ),
              const SizedBox(width: ArtFoxelSpacing.sm),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context)
                          .textTheme
                          .titleSmall
                          ?.copyWith(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded,
                  color: colors.onSurfaceVariant, size: 20),
            ],
          ),
        ),
      ),
    );
  }
}

class _RecentProjects extends StatelessWidget {
  const _RecentProjects({required this.projects});

  final List<ArtProject> projects;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (final project in projects) ...[
          Card(
            child: ListTile(
              leading: _ProjectTypeIcon(kind: project.kind),
              title: Text(project.name),
              subtitle: Text(
                '${project.kind} · Edited ${_shortDate(project.updatedAt)}',
              ),
            ),
          ),
          if (project != projects.last)
            const SizedBox(height: ArtFoxelSpacing.sm),
        ],
      ],
    );
  }

  String _shortDate(DateTime date) {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final local = date.toLocal();
    return '${months[local.month - 1]} ${local.day}';
  }
}

class _ProjectTypeIcon extends StatelessWidget {
  const _ProjectTypeIcon({required this.kind});

  final String kind;

  @override
  Widget build(BuildContext context) {
    final isAnimation = kind.toLowerCase().contains('animation');
    final color =
        isAnimation ? ArtFoxelColors.magenta : ArtFoxelColors.blue;
    return Container(
      width: 46,
      height: 46,
      decoration: BoxDecoration(
        color: color.withValues(alpha: .13),
        borderRadius: BorderRadius.circular(ArtFoxelRadius.sm),
      ),
      child: Icon(
        isAnimation ? Icons.movie_creation_rounded : Icons.draw_rounded,
        color: color,
      ),
    );
  }
}

class _NoProjectsPreview extends StatelessWidget {
  const _NoProjectsPreview();

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(ArtFoxelSpacing.md),
        child: Row(
          children: [
            const ArtFoxelLogo(size: 48),
            const SizedBox(width: ArtFoxelSpacing.md),
            Expanded(
              child: Text(
                'Your project gallery is ready when you are.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            Icon(Icons.auto_awesome_rounded,
                color: Theme.of(context).colorScheme.secondary),
          ],
        ),
      ),
    );
  }
}

class _ProjectPreviewLoading extends StatelessWidget {
  const _ProjectPreviewLoading();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      height: 72,
      child: Center(
        child: SizedBox.square(
          dimension: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
    );
  }
}

class _HomeLoading extends StatelessWidget {
  const _HomeLoading();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ArtFoxelLogo(size: 76),
            SizedBox(height: ArtFoxelSpacing.md),
            Text(
              'ARTFOXEL',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900),
            ),
            SizedBox(height: ArtFoxelSpacing.lg),
            SizedBox.square(
              dimension: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ],
        ),
      ),
    );
  }
}
