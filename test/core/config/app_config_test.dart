import 'package:artfoxel/core/config/app_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Supabase is disabled when configuration is absent', () {
    const config = AppConfig(supabaseUrl: null, supabaseAnonKey: null);
    expect(config.supabaseConfigured, isFalse);
    expect(config.googleOAuthEnabled, isFalse);
  });

  test('Supabase requires a URL and public key', () {
    const missingKey = AppConfig(
      supabaseUrl: 'https://project.supabase.co',
      supabaseAnonKey: null,
    );
    const missingUrl = AppConfig(
      supabaseUrl: null,
      supabaseAnonKey: 'public-key',
    );
    expect(missingKey.supabaseConfigured, isFalse);
    expect(missingUrl.supabaseConfigured, isFalse);
  });

  test('Supabase accepts complete URL and public key configuration', () {
    const config = AppConfig(
      supabaseUrl: 'https://project.supabase.co',
      supabaseAnonKey: 'public-key',
    );
    expect(config.supabaseConfigured, isTrue);
  });

  test('Supabase rejects URLs without an HTTP scheme and host', () {
    const config = AppConfig(
      supabaseUrl: 'file:///local/project',
      supabaseAnonKey: 'public-key',
    );
    expect(config.supabaseConfigured, isFalse);
  });
}
