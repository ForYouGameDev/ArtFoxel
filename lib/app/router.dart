import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/widgets/artfoxel_components.dart';
import '../features/auth/presentation/auth_screen.dart';
import '../features/home/presentation/home_screen.dart';
import '../features/onboarding/presentation/onboarding_screen.dart';
import '../features/profile/presentation/profile_screen.dart';
import '../features/projects/presentation/projects_screen.dart';
import '../features/settings/presentation/settings_screen.dart';
import '../features/studio/presentation/brush_lab_screen.dart';
import '../features/studio/presentation/studio_screen.dart';
import 'providers.dart';
import 'app_shell.dart';

final routerProvider = Provider<GoRouter>((ref) {
  final router = GoRouter(
    initialLocation: '/home',
    redirect: (context, state) {
      if (state.uri.path == '/auth' &&
          ref.read(supabaseClientProvider)?.auth.currentSession != null) {
        return '/profile';
      }
      return null;
    },
    routes: [
      GoRoute(
        path: '/auth',
        builder: (context, state) => const AuthScreen(),
      ),
      GoRoute(
        path: '/onboarding',
        builder: (context, state) => const OnboardingScreen(),
      ),
      ShellRoute(
        builder: (context, state, child) => AppShell(
          location: state.uri.path,
          child: child,
        ),
        routes: [
          GoRoute(path: '/home', builder: (context, state) => const HomeScreen()),
          GoRoute(
            path: '/studio/sketch',
            builder: (context, state) => StudioScreen(
              kind: StudioKind.sketch,
              projectId: state.uri.queryParameters['project'],
            ),
          ),
          GoRoute(
            path: '/brush-lab',
            builder: (context, state) => const BrushLabScreen(),
          ),
          GoRoute(
            path: '/studio/animation',
            builder: (context, state) =>
                const StudioScreen(kind: StudioKind.animation),
          ),
          GoRoute(
            path: '/projects',
            builder: (context, state) => const ProjectsScreen(),
          ),
          GoRoute(
            path: '/community',
            builder: (context, state) => const CommunityUnavailableScreen(),
          ),
          GoRoute(
            path: '/profile',
            builder: (context, state) => const ProfileScreen(),
          ),
          GoRoute(
            path: '/settings',
            builder: (context, state) => const SettingsScreen(),
          ),
        ],
      ),
    ],
  );
  ref.onDispose(router.dispose);
  return router;
});

class CommunityUnavailableScreen extends StatelessWidget {
  const CommunityUnavailableScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: const EmptyState(
            icon: Icons.people_outline_rounded,
            title: 'Community is coming soon',
            message:
                'Explore and share creative work with other artists in a future release.',
          ),
        ),
      ),
    );
  }
}
