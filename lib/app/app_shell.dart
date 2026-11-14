import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../core/theme/design_tokens.dart';
import '../core/widgets/artfoxel_components.dart';

class AppShell extends StatelessWidget {
  const AppShell({
    required this.location,
    required this.child,
    super.key,
  });

  final String location;
  final Widget child;

  static const _destinations = [
    _Destination('Home', '/home', Icons.home_outlined, Icons.home_rounded),
    _Destination(
      'Projects',
      '/projects',
      Icons.grid_view_outlined,
      Icons.grid_view_rounded,
    ),
    _Destination(
      'Create',
      '/studio/sketch',
      Icons.add_rounded,
      Icons.add_rounded,
      create: true,
    ),
    _Destination(
      'Community',
      '/community',
      Icons.people_outline_rounded,
      Icons.people_rounded,
    ),
    _Destination(
      'Profile',
      '/profile',
      Icons.person_outline_rounded,
      Icons.person_rounded,
    ),
  ];

  int get _selectedIndex {
    if (location.startsWith('/studio/')) return 2;
    if (location.startsWith('/settings')) return 4;
    final index = _destinations.indexWhere(
      (destination) =>
          location == destination.path ||
          location.startsWith('${destination.path}/'),
    );
    return index < 0 ? 0 : index;
  }

  Future<void> _navigate(BuildContext context, int index) async {
    if (index != 2) {
      context.go(_destinations[index].path);
      return;
    }
    final studio = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Choose your studio',
                style: Theme.of(context)
                    .textTheme
                    .titleLarge
                    ?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 8),
              Text(
                'Sketching and animation open in separate workspaces.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 14),
              ListTile(
                leading: const Icon(Icons.draw_rounded),
                title: const Text('Sketch Studio'),
                subtitle: const Text('Draw, paint and create artwork'),
                onTap: () => Navigator.pop(context, '/studio/sketch'),
              ),
              ListTile(
                leading: const Icon(Icons.movie_creation_rounded),
                title: const Text('Animation Studio'),
                subtitle: const Text('Open the dedicated animation workspace'),
                onTap: () => Navigator.pop(context, '/studio/animation'),
              ),
            ],
          ),
        ),
      ),
    );
    if (studio != null && context.mounted) context.go(studio);
  }

  @override
  Widget build(BuildContext context) {
    final selected = _selectedIndex;
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= 900) {
          return Scaffold(
            body: SafeArea(
              child: Row(
                children: [
                  NavigationRail(
                    minWidth: 88,
                    selectedIndex: selected,
                    onDestinationSelected: (index) => _navigate(context, index),
                    labelType: NavigationRailLabelType.all,
                    leading: const Padding(
                      padding: EdgeInsets.symmetric(vertical: 22),
                      child: ArtFoxelLogo(size: 48),
                    ),
                    destinations: [
                      for (final item in _destinations)
                        NavigationRailDestination(
                          icon: item.create
                              ? const _CreateNavIcon(selected: false)
                              : Icon(item.icon),
                          selectedIcon: item.create
                              ? const _CreateNavIcon(selected: true)
                              : Icon(item.selectedIcon),
                          label: Text(item.label),
                        ),
                    ],
                  ),
                  VerticalDivider(
                    width: 1,
                    color: Theme.of(context).colorScheme.outlineVariant,
                  ),
                  Expanded(child: child),
                ],
              ),
            ),
          );
        }
        return Scaffold(
          body: SafeArea(child: child),
          bottomNavigationBar: NavigationBar(
            selectedIndex: selected,
            labelBehavior: NavigationDestinationLabelBehavior.onlyShowSelected,
            onDestinationSelected: (index) => _navigate(context, index),
            destinations: [
              for (final item in _destinations)
                NavigationDestination(
                  icon: item.create
                      ? const _CreateNavIcon(selected: false)
                      : Icon(item.icon),
                  selectedIcon: item.create
                      ? const _CreateNavIcon(selected: true)
                      : Icon(item.selectedIcon),
                  label: item.label,
                ),
            ],
          ),
        );
      },
    );
  }
}

class _Destination {
  const _Destination(
    this.label,
    this.path,
    this.icon,
    this.selectedIcon, {
    this.create = false,
  });

  final String label;
  final String path;
  final IconData icon;
  final IconData selectedIcon;
  final bool create;
}

class _CreateNavIcon extends StatelessWidget {
  const _CreateNavIcon({required this.selected});

  final bool selected;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: ArtFoxelMotion.standard,
      width: 48,
      height: 36,
      decoration: BoxDecoration(
        gradient: ArtFoxelGradients.primary,
        borderRadius: BorderRadius.circular(ArtFoxelRadius.pill),
        boxShadow: selected
            ? [
                BoxShadow(
                  color: ArtFoxelColors.violet.withValues(alpha: .28),
                  blurRadius: 16,
                ),
              ]
            : null,
      ),
      child: const Icon(Icons.add_rounded, color: Colors.white),
    );
  }
}
