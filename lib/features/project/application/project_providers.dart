import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../data/project_files.dart';

/// All project folders live under `<documents>/artfoxel/`, the same base the
/// sketch, comic and animation storages already use.
final projectFilesProvider = FutureProvider<ProjectFiles>((ref) async {
  final documents = await getApplicationDocumentsDirectory();
  return ProjectFiles(Directory('${documents.path}/artfoxel'));
});
