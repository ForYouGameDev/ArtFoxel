import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/providers.dart';
import '../../../core/theme/design_tokens.dart';
import '../../../core/widgets/artfoxel_components.dart';
import '../../../core/widgets/async_state_view.dart';
import 'dart:io';

import '../../comic/application/comic_providers.dart';
import '../../project/application/project_providers.dart';
import '../../project/domain/artfoxel_package.dart';
import 'project_actions.dart';
import '../../studio/application/new_sketch.dart';
import '../data/project_repository.dart';
import '../domain/art_project.dart';

class ProjectsScreen extends ConsumerStatefulWidget {
  const ProjectsScreen({super.key});

  @override
  ConsumerState<ProjectsScreen> createState() => _ProjectsScreenState();
}

class _ProjectsScreenState extends ConsumerState<ProjectsScreen> {
  final _searchController = TextEditingController();
  String _kindFilter = 'All';
  bool _gridView = true;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sort = ref.watch(projectSortProvider);
    final projects = ref.watch(sortedProjectsProvider);
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('My Projects'),
        actions: [
          IconButton(
            tooltip: _gridView ? 'List view' : 'Grid view',
            onPressed: () => setState(() => _gridView = !_gridView),
            icon: Icon(_gridView ? Icons.view_list_rounded : Icons.grid_view_rounded),
          ),
          PopupMenuButton<ProjectSort>(
            tooltip: 'Sort projects',
            initialValue: sort,
            onSelected: (value) =>
                ref.read(projectSortProvider.notifier).state = value,
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: ProjectSort.recentlyUpdated,
                child: Text('Recently updated'),
              ),
              PopupMenuItem(value: ProjectSort.name, child: Text('Name')),
            ],
            icon: const Icon(Icons.sort_rounded),
          ),
          PopupMenuButton<String>(
            tooltip: 'Library',
            onSelected: (v) {
              final a = ProjectActions(context, ref);
              switch (v) {
                case 'import':
                  a.importPackage();
                case 'backup':
                  a.backupAll();
                case 'restore':
                  a.restoreBackup();
              }
            },
            itemBuilder: (c) => const [
              PopupMenuItem(value: 'import', child: Text('Import project (.artfoxel)')),
              PopupMenuItem(value: 'backup', child: Text('Back up all projects')),
              PopupMenuItem(value: 'restore', child: Text('Restore from backup')),
            ],
          ),
          const SizedBox(width: ArtFoxelSpacing.xs),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 900;
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1120),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      ArtFoxelSpacing.lg,
                      ArtFoxelSpacing.xs,
                      ArtFoxelSpacing.lg,
                      ArtFoxelSpacing.md,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Your creative work, together.',
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                color: colors.onSurfaceVariant,
                              ),
                        ),
                        const SizedBox(height: ArtFoxelSpacing.md),
                        TextField(
                          controller: _searchController,
                          onChanged: (_) => setState(() {}),
                          decoration: InputDecoration(
                            hintText: 'Search projects',
                            prefixIcon: const Icon(Icons.search_rounded),
                            suffixIcon: _searchController.text.isEmpty
                                ? null
                                : IconButton(
                                    tooltip: 'Clear search',
                                    onPressed: () {
                                      _searchController.clear();
                                      setState(() {});
                                    },
                                    icon: const Icon(Icons.close_rounded),
                                  ),
                          ),
                        ),
                        const SizedBox(height: ArtFoxelSpacing.md),
                        Row(
                          children: [
                            Expanded(
                              child: SingleChildScrollView(
                                scrollDirection: Axis.horizontal,
                                child: Row(
                                  children: [
                                    for (final filter in const [
                                      'All',
                                      'Sketch',
                                      'Comic',
                                      'Animation',
                                      'Favourites',
                                    ]) ...[
                                      Padding(
                                        padding: const EdgeInsets.only(
                                          right: ArtFoxelSpacing.xs,
                                        ),
                                        child: ChoiceChip(
                                          label: Text(filter),
                                          selected: _kindFilter == filter,
                                          onSelected: (_) =>
                                              setState(() => _kindFilter = filter),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ),
                            if (wide)
                              Text(
                                sort == ProjectSort.name
                                    ? 'Sorted by name'
                                    : 'Most recent',
                                style: Theme.of(context).textTheme.labelMedium,
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: projects.when(
                      loading: () => const Center(
                        child: CircularProgressIndicator(),
                      ),
                      error: (error, stack) => AsyncStateView<List<ArtProject>>(
                        value: AsyncSnapshot.withError(
                          ConnectionState.done,
                          error,
                          stack,
                        ),
                        data: (_) => const SizedBox.shrink(),
                        onRetry: () => ref.invalidate(projectsProvider),
                      ),
                      data: (items) {
                        final filtered = items.where((project) {
                          final matchesQuery = project.name
                              .toLowerCase()
                              .contains(_searchController.text.trim().toLowerCase());
                          final matchesKind = _kindFilter == 'All' ||
                              (_kindFilter == 'Favourites'
                                  ? project.favorite
                                  : project.kind.toLowerCase() ==
                                      _kindFilter.toLowerCase());
                          return matchesQuery && matchesKind;
                        }).toList();
                        if (filtered.isEmpty) {
                          final isEmptyGallery =
                              items.isEmpty && _searchController.text.isEmpty;
                          return EmptyState(
                            icon: isEmptyGallery
                                ? Icons.folder_open_rounded
                                : Icons.search_off_rounded,
                            title: isEmptyGallery
                                ? 'Your gallery is ready'
                                : 'No matching projects',
                            message: isEmptyGallery
                                ? 'Projects saved on this device will appear here.'
                                : 'Try another search or switch the project filter.',
                            action: isEmptyGallery
                                ? Wrap(
                                    spacing: ArtFoxelSpacing.sm,
                                    runSpacing: ArtFoxelSpacing.sm,
                                    alignment: WrapAlignment.center,
                                    children: [
                                      FilledButton.icon(
                                        onPressed: () => openNewSketch(context, ref),
                                        icon: const Icon(Icons.draw_rounded),
                                        label: const Text('Open Sketch Studio'),
                                      ),
                                      OutlinedButton.icon(
                                        onPressed: () => openNewProject(
                                            context, ref,
                                            kind: 'Comic'),
                                        icon: const Icon(Icons.menu_book_rounded),
                                        label: const Text('Open Comic Studio'),
                                      ),
                                      OutlinedButton.icon(
                                        onPressed: () => openNewProject(
                                            context, ref,
                                            kind: 'Animation'),
                                        icon: const Icon(
                                            Icons.movie_creation_rounded),
                                        label:
                                            const Text('Open Animation Studio'),
                                      ),
                                    ],
                                  )
                                : null,
                          );
                        }
                        return LayoutBuilder(
                          builder: (context, gridConstraints) {
                            final columns = gridConstraints.maxWidth >= 850
                                ? 3
                                : gridConstraints.maxWidth >= 560
                                    ? 2
                                    : 1;
                            if (!_gridView || columns == 1) {
                              return ListView.separated(
                                padding: const EdgeInsets.fromLTRB(
                                  ArtFoxelSpacing.lg,
                                  0,
                                  ArtFoxelSpacing.lg,
                                  ArtFoxelSpacing.xl,
                                ),
                                itemCount: filtered.length,
                                separatorBuilder: (context, index) =>
                                    const SizedBox(height: ArtFoxelSpacing.sm),
                                itemBuilder: (context, index) => _ProjectCard(
                                  project: filtered[index],
                                  compact: true,
                                ),
                              );
                            }
                            return GridView.builder(
                              padding: const EdgeInsets.fromLTRB(
                                ArtFoxelSpacing.lg,
                                0,
                                ArtFoxelSpacing.lg,
                                ArtFoxelSpacing.xl,
                              ),
                              gridDelegate:
                                  SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: columns,
                                crossAxisSpacing: ArtFoxelSpacing.md,
                                mainAxisSpacing: ArtFoxelSpacing.md,
                                childAspectRatio: 1.48,
                              ),
                              itemCount: filtered.length,
                              itemBuilder: (context, index) => _ProjectCard(
                                project: filtered[index],
                                compact: false,
                              ),
                            );
                          },
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _ProjectCard extends ConsumerWidget {
  const _ProjectCard({required this.project, required this.compact});

  final ArtProject project;
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isAnimation = project.kind.toLowerCase().contains('animation');
    final isComic = project.kind.toLowerCase().contains('comic');
    final accent =
        isAnimation ? ArtFoxelColors.magenta : ArtFoxelColors.blue;
    final icon = isAnimation
        ? Icons.movie_creation_rounded
        : isComic
            ? Icons.menu_book_rounded
            : Icons.draw_rounded;
    final files = ref.watch(projectFilesProvider).valueOrNull;
    final thumb = files == null ? null : files.thumbnailFile(ProjectKind.fromLabel(project.kind), project.id);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => openProject(context, project),
        onLongPress: () => ProjectActions(context, ref).showMenu(project),
        child: compact
          ? ListTile(
              contentPadding: const EdgeInsets.all(ArtFoxelSpacing.sm),
              leading: _ProjectArtwork(accent: accent, icon: icon, size: 60, thumbnail: thumb, revision: project.thumbnailRevision),
              title: Text(project.name),
              subtitle: Text(
                '${project.kind} · Edited ${_shortDate(project.updatedAt)}',
              ),
              trailing: IconButton(tooltip: 'Project actions', icon: const Icon(Icons.more_vert), onPressed: () => ProjectActions(context, ref).showMenu(project)),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Stack(fit: StackFit.expand, children: [
                    _ProjectArtwork(
                      accent: accent,
                      icon: icon,
                      size: double.infinity,
                      thumbnail: thumb,
                      revision: project.thumbnailRevision,
                    ),
                    Positioned(
                      top: 0,
                      right: 0,
                      child: IconButton(tooltip: 'Project actions', icon: const Icon(Icons.more_vert), onPressed: () => ProjectActions(context, ref).showMenu(project)),
                    ),
                    if (project.favorite) const Positioned(top: 8, left: 8, child: Icon(Icons.star, color: Colors.amber)),
                  ]),
                ),
                Padding(
                  padding: const EdgeInsets.all(ArtFoxelSpacing.md),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        project.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context)
                            .textTheme
                            .titleSmall
                            ?.copyWith(fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: ArtFoxelSpacing.xxs),
                      Text(
                        '${project.kind} · Edited ${_shortDate(project.updatedAt)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
      ),
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

class _ProjectArtwork extends StatelessWidget {
  const _ProjectArtwork({
    required this.accent,
    required this.icon,
    required this.size,
    this.thumbnail,
    this.revision = 0,
  });

  final File? thumbnail;
  final int revision;
  final Color accent;
  final IconData icon;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size == double.infinity ? double.infinity : size,
      height: size == double.infinity ? double.infinity : size,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            accent.withValues(alpha: .28),
            accent.withValues(alpha: .07),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: thumbnail != null && thumbnail!.existsSync()
          ? Image.file(thumbnail!, key: ValueKey('${thumbnail!.path}#$revision'), fit: BoxFit.cover, errorBuilder: (c, e, s) => Center(child: Icon(icon, size: 30, color: accent)))
          : Center(child: Icon(icon, size: 30, color: accent)),
    );
  }
}
