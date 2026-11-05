import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/diagnostics/app_log.dart';
import '../domain/canvas_input.dart';

/// Persisted drawing preferences: how each input device behaves and the
/// latency/stabilization mode.
class StudioSettings {
  const StudioSettings({
    this.input = const CanvasInputSettings(
      fingerBehavior: CanvasInputBehavior.draw,
      palmRejection: true,
    ),
    this.lowLatency = false,
  });

  final CanvasInputSettings input;
  final bool lowLatency;

  StudioSettings copyWith({CanvasInputSettings? input, bool? lowLatency}) =>
      StudioSettings(
        input: input ?? this.input,
        lowLatency: lowLatency ?? this.lowLatency,
      );

  Map<String, Object> toJson() => {
        'finger': input.fingerBehavior.name,
        'stylus': input.stylusBehavior.name,
        'mouse': input.mouseBehavior.name,
        'palmRejection': input.palmRejection,
        'rotation': input.rotationEnabled,
        'lowLatency': lowLatency,
      };

  factory StudioSettings.fromJson(Map<String, dynamic> json) {
    const fallback = StudioSettings();
    CanvasInputBehavior behavior(String key, CanvasInputBehavior def) {
      final value = json[key];
      for (final candidate in CanvasInputBehavior.values) {
        if (candidate.name == value) return candidate;
      }
      return def;
    }

    bool flag(String key, bool def) {
      final value = json[key];
      return value is bool ? value : def;
    }

    return StudioSettings(
      input: CanvasInputSettings(
        fingerBehavior: behavior('finger', fallback.input.fingerBehavior),
        stylusBehavior: behavior('stylus', fallback.input.stylusBehavior),
        mouseBehavior: behavior('mouse', fallback.input.mouseBehavior),
        palmRejection: flag('palmRejection', fallback.input.palmRejection),
        rotationEnabled: flag('rotation', fallback.input.rotationEnabled),
      ),
      lowLatency: flag('lowLatency', fallback.lowLatency),
    );
  }
}

class StudioSettingsController extends StateNotifier<StudioSettings> {
  StudioSettingsController(this._preferences) : super(const StudioSettings()) {
    _load();
  }

  final Future<SharedPreferences> _preferences;
  static const storageKey = 'studio_settings_v1';

  Future<void> _load() async {
    try {
      final raw = (await _preferences).getString(storageKey);
      if (raw == null) return;
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic> && mounted) {
        state = StudioSettings.fromJson(decoded);
      }
    } catch (error, stack) {
      AppLog.error('Studio settings load failed', error: error, stackTrace: stack);
    }
  }

  Future<void> update(StudioSettings next) async {
    state = next;
    try {
      await (await _preferences).setString(storageKey, jsonEncode(next.toJson()));
    } catch (error, stack) {
      AppLog.error('Studio settings save failed', error: error, stackTrace: stack);
    }
  }
}

final studioSettingsProvider =
    StateNotifierProvider<StudioSettingsController, StudioSettings>((ref) {
  return StudioSettingsController(SharedPreferences.getInstance());
});
