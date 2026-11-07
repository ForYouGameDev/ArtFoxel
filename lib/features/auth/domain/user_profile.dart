import 'package:supabase_flutter/supabase_flutter.dart';

class UserProfile {
  const UserProfile({
    required this.email,
    required this.displayName,
    required this.username,
    required this.avatarUrl,
  });

  final String email;
  final String? displayName;
  final String? username;
  final String? avatarUrl;

  factory UserProfile.fromUser(User user) {
    final metadata = user.userMetadata ?? const <String, dynamic>{};
    return UserProfile(
      email: user.email ?? '',
      displayName: metadata['full_name'] as String? ??
          metadata['name'] as String? ??
          metadata['display_name'] as String?,
      username: metadata['username'] as String?,
      avatarUrl: metadata['avatar_url'] as String? ??
          metadata['picture'] as String?,
    );
  }
}
