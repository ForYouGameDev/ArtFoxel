import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/diagnostics/app_log.dart';
import '../domain/art_project.dart';

enum ProjectSort { recentlyUpdated, name }

class ProjectRepository {
  ProjectRepository(this._preferences);

  final Future<SharedPreferences> _preferences;
  static const _projectsKey = 'local_projects_v1';

  Future<List<ArtProject>> loadProjects() async {
    try {
      final raw = (await _preferences).getString(_projectsKey);
      if (raw == null || raw.isEmpty) return const [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        throw const FormatException('Local project gallery data is invalid.');
      }
      return decoded
          .map((item) {
            if (item is! Map<String, dynamic>) {
              throw const FormatException('Local project entry is invalid.');
            }
            return ArtProject.fromJson(item);
          })
          .toList(growable: false);
    } catch (error, stack) {
      AppLog.error('Local project gallery load failed',
          error: error, stackTrace: stack);
      rethrow;
    }
  }

  Future<void> saveProjects(List<ArtProject> projects) async {
    try {
      final encoded =
          jsonEncode(projects.map((project) => project.toJson()).toList());
      final saved = await (await _preferences).setString(_projectsKey, encoded);
      if (!saved) throw StateError('Local project metadata could not be saved.');
    } catch (error, stack) {
      AppLog.error('Local project gallery save failed',
          error: error, stackTrace: stack);
      rethrow;
    }
  }
}
