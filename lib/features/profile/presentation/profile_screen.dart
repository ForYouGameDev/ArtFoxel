import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../app/providers.dart';
import '../../../core/diagnostics/app_log.dart';
import '../../../core/theme/design_tokens.dart';
import '../../../core/widgets/artfoxel_components.dart';
import '../../auth/domain/user_profile.dart';

class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  Future<void> _signOut(BuildContext context, WidgetRef ref) async {
    final client = ref.read(supabaseClientProvider);
    if (client == null) return;
    try {
      await client.auth.signOut();
      if (context.mounted) context.go('/home');
    } on AuthException catch (error, stack) {
      AppLog.error('Sign-out failed', error: error, stackTrace: stack);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not sign out. Please try again.')),
        );
      }
    } catch (error, stack) {
      AppLog.error('Sign-out failed', error: error, stackTrace: stack);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not sign out. Please try again.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final client = ref.watch(supabaseClientProvider);
    final user = client?.auth.currentUser;
    if (user == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Profile')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 88,
                    height: 88,
                    decoration: BoxDecoration(
                      gradient: ArtFoxelGradients.primary,
                      borderRadius:
                          BorderRadius.circular(ArtFoxelRadius.lg),
                    ),
                    padding: const EdgeInsets.all(3),
                    child: CircleAvatar(
                      backgroundColor: Theme.of(context).colorScheme.surface,
                      child: Icon(
                        Icons.person_outline_rounded,
                        size: 40,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text('Your creative space',
                      style: Theme.of(context).textTheme.headlineSmall),
                  const SizedBox(height: 8),
                  const Text(
                    'You’re using ARTFOXEL without signing in. Your local workspace is available on this device.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 18),
                  FilledButton(
                    onPressed: client == null ? null : () => context.push('/auth'),
                    child: const Text('Sign in or create account'),
                  ),
                  if (client == null) ...[
                    const SizedBox(height: 8),
                    const Text('Account sign-in will be available when configured.'),
                  ],
                ],
              ),
            ),
          ),
        ),
      );
    }

    final profile = UserProfile.fromUser(user);
    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: ListView(
        padding: const EdgeInsets.all(ArtFoxelSpacing.lg),
        children: [
          const SizedBox(height: ArtFoxelSpacing.md),
          Center(
            child: CircleAvatar(
              radius: 44,
              foregroundImage: profile.avatarUrl == null
                  ? null
                  : NetworkImage(profile.avatarUrl!),
              child: const Icon(Icons.person_outline_rounded, size: 44),
            ),
          ),
          const SizedBox(height: ArtFoxelSpacing.lg),
          Center(
            child: Text(
              profile.displayName ?? 'ARTFOXEL creator',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
          ),
          if (profile.username != null)
            Center(child: Text('@${profile.username}')),
          const SizedBox(height: ArtFoxelSpacing.lg),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.mail_outline),
                  title: const Text('Email'),
                  subtitle: Text(profile.email.isEmpty ? 'Not provided' : profile.email),
                ),
                const Divider(height: 1),
                const ListTile(
                  leading: Icon(Icons.person_outline),
                  title: Text('Username'),
                  subtitle: Text('Profile details are managed by your sign-in provider.'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(ArtFoxelSpacing.md),
              child: Row(
                children: [
                  const ArtFoxelLogo(size: 42),
                  const SizedBox(width: ArtFoxelSpacing.md),
                  Expanded(
                    child: Text(
                      'Create. Experiment. Inspire.',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: ArtFoxelSpacing.md),
          OutlinedButton.icon(
            onPressed: () => _signOut(context, ref),
            icon: const Icon(Icons.logout),
            label: const Text('Sign out'),
          ),
        ],
      ),
    );
  }
}
