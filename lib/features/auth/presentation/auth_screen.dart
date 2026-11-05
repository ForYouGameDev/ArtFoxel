import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../app/providers.dart';
import '../../../core/diagnostics/app_log.dart';
import '../../../core/widgets/artfoxel_components.dart';

class AuthScreen extends ConsumerStatefulWidget {
  const AuthScreen({super.key});

  @override
  ConsumerState<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends ConsumerState<AuthScreen> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _isSignUp = false;
  bool _busy = false;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _emailAuth() async {
    if (!_formKey.currentState!.validate()) return;
    final client = ref.read(supabaseClientProvider);
    if (client == null) return;
    setState(() => _busy = true);
    try {
      if (_isSignUp) {
        await client.auth.signUp(
          email: _email.text.trim(),
          password: _password.text,
        );
        if (mounted) {
          _showMessage('Check your email if confirmation is enabled.');
        }
      } else {
        await client.auth.signInWithPassword(
          email: _email.text.trim(),
          password: _password.text,
        );
        if (mounted) context.go('/profile');
      }
    } on AuthException catch (error, stack) {
      AppLog.error('Email authentication failed', error: error, stackTrace: stack);
      if (mounted) _showMessage('We couldn’t complete that sign-in. Please try again.');
    } catch (error, stack) {
      AppLog.error('Email authentication failed', error: error, stackTrace: stack);
      if (mounted) _showMessage('We couldn’t complete that sign-in. Please try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _googleAuth() async {
    final client = ref.read(supabaseClientProvider);
    if (client == null) return;
    setState(() => _busy = true);
    try {
      final launched = await client.auth.signInWithOAuth(
        OAuthProvider.google,
        redirectTo: 'www.shadowarcgames.artfoxel://login-callback/',
      );
      if (!launched && mounted) {
        _showMessage('Google sign-in could not be opened on this device.');
      }
    } on AuthException catch (error, stack) {
      AppLog.error('Google sign-in failed', error: error, stackTrace: stack);
      if (mounted) _showMessage('Google sign-in isn’t available. Check provider setup.');
    } catch (error, stack) {
      AppLog.error('Google sign-in failed', error: error, stackTrace: stack);
      if (mounted) _showMessage('Google sign-in isn’t available. Check provider setup.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(authStateProvider, (previous, next) {
      if (next.valueOrNull?.session != null && mounted) {
        context.go('/profile');
      }
    });
    final client = ref.watch(supabaseClientProvider);
    final googleOAuthEnabled =
        ref.watch(appConfigProvider).googleOAuthEnabled;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Your ARTFOXEL account'),
        leading: IconButton(
          tooltip: 'Back',
          onPressed: () => context.go('/profile'),
          icon: const Icon(Icons.arrow_back),
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: ListView(
            padding: const EdgeInsets.all(24),
            shrinkWrap: true,
            children: [
              const Center(child: ArtFoxelLogo(size: 72)),
              const SizedBox(height: 12),
              Text(
                'Sign in to your account',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 8),
              Text(
                'Local creative work remains available without an account.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 28),
              if (client == null) ...[
                  _AuthUnavailableCard(
                    configured: ref.watch(appConfigProvider).supabaseConfigured,
                  ),
              ] else ...[
                FilledButton.tonalIcon(
                  onPressed:
                      _busy || !googleOAuthEnabled ? null : _googleAuth,
                  icon: const Icon(Icons.g_mobiledata_rounded, size: 28),
                  label: Text(
                    googleOAuthEnabled
                        ? 'Continue with Google'
                        : 'Google sign-in not configured',
                  ),
                ),
                if (!googleOAuthEnabled) ...[
                  const SizedBox(height: 8),
                  const Text(
                    'Configure Google in Supabase before enabling this provider.',
                    textAlign: TextAlign.center,
                  ),
                ],
                const SizedBox(height: 18),
                const Row(
                  children: [
                    Expanded(child: Divider()),
                    Padding(
                      padding: EdgeInsets.symmetric(horizontal: 12),
                      child: Text('or use email'),
                    ),
                    Expanded(child: Divider()),
                  ],
                ),
                const SizedBox(height: 18),
                Form(
                  key: _formKey,
                  child: Column(
                    children: [
                      TextFormField(
                        controller: _email,
                        keyboardType: TextInputType.emailAddress,
                        autofillHints: const [AutofillHints.email],
                        decoration: const InputDecoration(labelText: 'Email'),
                        validator: (value) => value == null ||
                                !value.contains('@') ||
                                value.trim().isEmpty
                            ? 'Enter a valid email address'
                            : null,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _password,
                        obscureText: true,
                        autofillHints: _isSignUp
                            ? const [AutofillHints.newPassword]
                            : const [AutofillHints.password],
                        decoration: const InputDecoration(labelText: 'Password'),
                        validator: (value) => value == null || value.length < 6
                            ? 'Use at least 6 characters'
                            : null,
                      ),
                      const SizedBox(height: 18),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                          onPressed: _busy ? null : _emailAuth,
                          child: _busy
                              ? const SizedBox.square(
                                  dimension: 20,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : Text(_isSignUp ? 'Create account' : 'Sign in'),
                        ),
                      ),
                    ],
                  ),
                ),
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => setState(() => _isSignUp = !_isSignUp),
                  child: Text(
                    _isSignUp
                        ? 'Already have an account? Sign in'
                        : 'New here? Create an account',
                  ),
                ),
              ],
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () => context.go('/home'),
                child: const Text('Continue without an account'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AuthUnavailableCard extends StatelessWidget {
  const _AuthUnavailableCard({required this.configured});

  final bool configured;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          children: [
            const Icon(Icons.lock_outline_rounded, size: 32),
            const SizedBox(height: 10),
            Text(
              configured ? 'Sign-in is unavailable' : 'Sign-in is not configured',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              configured
                  ? 'Supabase could not be initialized. Check the project configuration and try again.'
                  : 'Add a Supabase URL and public anon key to enable email and Google sign-in.',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
