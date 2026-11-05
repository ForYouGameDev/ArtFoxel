import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/providers.dart';
import '../../../core/theme/design_tokens.dart';
import '../../../core/widgets/artfoxel_components.dart';

class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  int _page = 0;

  static const _pages = [
    (
      Icons.draw_rounded,
      'Sketch your ideas',
      'Start with a blank canvas and explore your own creative process.'
    ),
    (
      Icons.movie_creation_rounded,
      'Bring stories to life',
      'Animation has its own dedicated workspace, separate from sketching.'
    ),
    (
      Icons.folder_rounded,
      'Keep projects close',
      'Your project gallery starts on this device. Sign in when you want to use account features.'
    ),
  ];

  Future<void> _finish() async {
    await ref.read(onboardingCompleteProvider.notifier).complete();
    if (mounted) context.go('/home');
  }

  @override
  Widget build(BuildContext context) {
    final page = _pages[_page];
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: Padding(
                    padding: const EdgeInsets.all(ArtFoxelSpacing.lg),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const ArtFoxelLogo(
                              size: 42,
                              showWordmark: true,
                            ),
                            TextButton(
                              onPressed: _finish,
                              child: const Text('Skip'),
                            ),
                          ],
                        ),
                        const SizedBox(height: ArtFoxelSpacing.xl),
                        Container(
                          width: 132,
                          height: 132,
                          decoration: BoxDecoration(
                            gradient: ArtFoxelGradients.surfaceGlow,
                            borderRadius:
                                BorderRadius.circular(ArtFoxelRadius.lg),
                            border: Border.all(color: colors.outlineVariant),
                          ),
                          child: Icon(page.$1, size: 60, color: colors.primary),
                        ),
                        const SizedBox(height: ArtFoxelSpacing.xl),
                        Text(
                          page.$2,
                          textAlign: TextAlign.center,
                          style: Theme.of(context)
                              .textTheme
                              .headlineMedium
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          page.$3,
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodyLarge,
                        ),
                        const SizedBox(height: ArtFoxelSpacing.xl),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: List.generate(
                            _pages.length,
                            (index) => Container(
                              width: index == _page ? 24 : 8,
                              height: 8,
                              margin:
                                  const EdgeInsets.symmetric(horizontal: 4),
                              decoration: BoxDecoration(
                                color: index == _page
                                    ? colors.primary
                                    : colors.outlineVariant,
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: ArtFoxelSpacing.lg),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton(
                            onPressed: _page == _pages.length - 1
                                ? _finish
                                : () => setState(() => _page += 1),
                            child: Text(
                              _page == _pages.length - 1
                                  ? 'Get started'
                                  : 'Continue',
                            ),
                          ),
                        ),
                        TextButton(
                          onPressed: () => context.go('/settings'),
                          child: const Text(
                            'You can revisit this from Settings',
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
