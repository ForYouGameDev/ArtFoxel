class AppConfig {
  const AppConfig({
    required this.supabaseUrl,
    required this.supabaseAnonKey,
    this.googleOAuthEnabled = false,
  });

  final String? supabaseUrl;
  final String? supabaseAnonKey;
  final bool googleOAuthEnabled;

  bool get supabaseConfigured {
    if (supabaseUrl == null || supabaseAnonKey == null) return false;
    final uri = Uri.tryParse(supabaseUrl!);
    return uri != null &&
        (uri.scheme == 'https' || uri.scheme == 'http') &&
        uri.host.isNotEmpty &&
        supabaseAnonKey!.isNotEmpty;
  }

  factory AppConfig.fromEnvironment() {
    const url = String.fromEnvironment('SUPABASE_URL');
    const anonKey = String.fromEnvironment('SUPABASE_ANON_KEY');
    const googleOAuthEnabled =
        bool.fromEnvironment('SUPABASE_GOOGLE_ENABLED');
    return AppConfig(
      supabaseUrl: url.isEmpty ? null : url,
      supabaseAnonKey: anonKey.isEmpty ? null : anonKey,
      googleOAuthEnabled: googleOAuthEnabled,
    );
  }
}
