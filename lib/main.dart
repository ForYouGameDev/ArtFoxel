import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app/artfoxel_app.dart';
import 'app/providers.dart';
import 'core/config/app_config.dart';
import 'core/diagnostics/app_log.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterError.onError = (details) {
    AppLog.error(
      'Flutter framework error',
      error: details.exception,
      stackTrace: details.stack,
    );
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    AppLog.error('Uncaught platform error', error: error, stackTrace: stack);
    return true;
  };

  final config = AppConfig.fromEnvironment();
  SupabaseClient? supabaseClient;
  if (config.supabaseConfigured) {
    try {
      await Supabase.initialize(
        url: config.supabaseUrl!,
        publishableKey: config.supabaseAnonKey!,
      );
      supabaseClient = Supabase.instance.client;
    } catch (error, stack) {
      AppLog.error('Supabase initialization failed', error: error, stackTrace: stack);
    }
  }

  runApp(
    ProviderScope(
      overrides: [supabaseClientProvider.overrideWithValue(supabaseClient)],
      child: const ArtFoxelApp(),
    ),
  );
}
