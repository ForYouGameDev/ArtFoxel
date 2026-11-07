import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/providers.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/design_tokens.dart';
import '../../../core/widgets/artfoxel_components.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final preferenceValue = ref.watch(themePreferenceProvider);
    final preference = preferenceValue.valueOrNull ?? ThemePreference.system;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(ArtFoxelSpacing.lg),
        children: [
          Text('Appearance', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: ArtFoxelSpacing.sm),
          Card(
            child: ListTile(
              leading: const Icon(Icons.palette_outlined),
              title: const Text('Theme'),
              subtitle: const Text('Choose your preferred appearance'),
              trailing: DropdownButton<ThemePreference>(
                value: preference,
                underline: const SizedBox.shrink(),
                onChanged: (value) async {
                  if (value != null) {
                    await ref
                        .read(themePreferenceProvider.notifier)
                        .setPreference(value);
                  }
                },
                items: const [
                  DropdownMenuItem(
                    value: ThemePreference.system,
                    child: Text('System'),
                  ),
                  DropdownMenuItem(
                    value: ThemePreference.light,
                    child: Text('Light'),
                  ),
                  DropdownMenuItem(
                    value: ThemePreference.dark,
                    child: Text('Dark'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: ArtFoxelSpacing.lg),
          Text('Account', style: Theme.of(context).textTheme.titleMedium),
          Card(
            child: ListTile(
              leading: const Icon(Icons.person_outline),
              title: const Text('Profile and sign-in'),
              subtitle: const Text('Manage your account'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/profile'),
            ),
          ),
          const SizedBox(height: ArtFoxelSpacing.lg),
          Text('About', style: Theme.of(context).textTheme.titleMedium),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(ArtFoxelSpacing.sm),
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.school_outlined),
                    title: const Text('Show onboarding again'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () async {
                      await ref
                          .read(onboardingCompleteProvider.notifier)
                          .revisit();
                      if (context.mounted) context.go('/onboarding');
                    },
                  ),
                  const Divider(height: 1),
                  const Padding(
                    padding: EdgeInsets.all(ArtFoxelSpacing.md),
                    child: Row(
                      children: [
                        ArtFoxelLogo(size: 48),
                        SizedBox(width: ArtFoxelSpacing.md),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'ARTFOXEL',
                                style: TextStyle(
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: 1,
                                ),
                              ),
                              SizedBox(height: ArtFoxelSpacing.xxs),
                              Text('Create. Experiment. Inspire.'),
                              Text('By ShadowArc Games'),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (preferenceValue.hasError) ...[
            const SizedBox(height: 12),
            const Text('Your theme preference could not be saved.'),
          ],
        ],
      ),
    );
  }
}
