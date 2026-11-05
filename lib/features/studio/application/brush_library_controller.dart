import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/diagnostics/app_log.dart';
import '../data/brush_library_repository.dart';
import '../domain/brush_codec.dart';
import '../domain/brush_preset.dart';
import '../domain/builtin_brushes.dart';

/// Brush Lab state. Every action is written to storage before it is
/// reported as done, and built-in brushes can never be edited or deleted.
class BrushLibraryController extends StateNotifier<AsyncValue<BrushLibraryData>> {
  BrushLibraryController(this._repository) : super(const AsyncValue.loading()) {
    _load();
  }

  final BrushLibraryRepository _repository;

  Future<void> _load() async {
    try {
      state = AsyncValue.data(await _repository.load());
    } catch (error, stack) {
      AppLog.error('Brush library load failed', error: error, stackTrace: stack);
      state = AsyncValue.error(error, stack);
    }
  }

  Future<void> reload() => _load();

  BrushLibraryData get _data => state.valueOrNull ?? const BrushLibraryData();

  Future<void> _commit(BrushLibraryData next) async {
    await _repository.save(next);
    state = AsyncValue.data(next);
  }

  Iterable<String> get _names => _data.all.map((preset) => preset.name);

  /// Creates a new editable brush based on [template] and returns it.
  Future<BrushPreset> createFrom(BrushPreset template, {String? name}) async {
    final wanted = BrushPreset.sanitizeName(name ?? '${template.name} copy');
    final created = template.withChanges({
      'id': BrushCodec.newUserId(),
      'name': BrushCodec.uniqueName(wanted, _names),
    });
    await _commit(_data.copyWith(user: [..._data.user, created]));
    return created;
  }

  Future<BrushPreset> createNew() =>
      createFrom(BuiltInBrushes.defaultBrush, name: 'New brush');

  Future<BrushPreset?> duplicate(String id) async {
    final source = _data.byId(id);
    if (source == null) return null;
    return createFrom(source);
  }

  /// Saves edits to a user brush. Built-in brushes are ignored.
  Future<void> upsert(BrushPreset preset) async {
    if (preset.isBuiltIn) return;
    final user = [..._data.user];
    final index = user.indexWhere((p) => p.id == preset.id);
    if (index < 0) return;
    user[index] = preset;
    await _commit(_data.copyWith(user: user));
  }

  Future<void> rename(String id, String name) async {
    final clean = BrushPreset.sanitizeName(name);
    if (clean.isEmpty) {
      throw const BrushPresetException('Brush name cannot be empty.');
    }
    final current = _data.user.where((p) => p.id == id).firstOrNull;
    if (current == null) return;
    final others = _data.all.where((p) => p.id != id).map((p) => p.name);
    final unique = BrushCodec.uniqueName(clean, others);
    await upsert(current.withChanges({'name': unique}));
  }

  Future<void> delete(String id) async {
    if (!_data.user.any((p) => p.id == id)) return;
    await _commit(
      _data.copyWith(
        user: _data.user.where((p) => p.id != id).toList(),
        favorites: {..._data.favorites}..remove(id),
        groups: {..._data.groups}..remove(id),
      ),
    );
  }

  Future<void> toggleFavorite(String id) async {
    final favorites = {..._data.favorites};
    if (!favorites.remove(id)) favorites.add(id);
    await _commit(_data.copyWith(favorites: favorites));
  }

  Future<void> setGroup(String id, String? group) async {
    final groups = {..._data.groups};
    final clean = group?.trim() ?? '';
    if (clean.isEmpty) {
      groups.remove(id);
    } else {
      groups[id] = clean.length > 32 ? clean.substring(0, 32) : clean;
    }
    await _commit(_data.copyWith(groups: groups));
  }

  /// Adds imported presets (already validated, renamed and given ids).
  Future<void> addImported(List<BrushPreset> presets) async {
    if (presets.isEmpty) return;
    await _commit(_data.copyWith(user: [..._data.user, ...presets]));
  }
}

final brushLibraryRepositoryProvider = Provider<BrushLibraryRepository>((ref) {
  return BrushLibraryRepository(SharedPreferences.getInstance());
});

final brushLibraryProvider = StateNotifierProvider<BrushLibraryController,
    AsyncValue<BrushLibraryData>>((ref) {
  return BrushLibraryController(ref.watch(brushLibraryRepositoryProvider));
});
