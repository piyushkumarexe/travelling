import 'package:flutter/material.dart';

import '../../../core/state/app_container.dart';
import '../../../core/widgets/app_button.dart';
import '../../data/repositories/auth_repository.dart'
    show AuthException;

/// Real Google Sign-In screen (Firebase Authentication under the hood).
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  bool _loading = false;

  AppContainer get _c => AppScope.of(context);

  Future<void> _signIn() async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      await _c.authRepository.signInWithGoogle();
      if (!mounted) return;
      // AuthState reacts to the auth stream; the router redirects to /home.
    } on AuthException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Google sign-in failed. Please try again.')),
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding:
                const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(28),
                    boxShadow: <BoxShadow>[
                      BoxShadow(
                        color: Colors.black
                            .withOpacity(dark ? 0.35 : 0.10),
                        blurRadius: 28,
                        offset: const Offset(0, 12),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(28),
                    child: Image.asset(
                      'assets/images/yatrawise-logo.jpg',
                      fit: BoxFit.cover,
                    ),
                  ),
                ),
                const SizedBox(height: 28),
                PrimaryButton(
                  label:
                      _loading ? 'Signing in…' : 'Continue with Google',
                  icon: _loading ? null : Icons.account_circle,
                  loading: _loading,
                  onPressed: _signIn,
                ),
                const SizedBox(height: 20),
                Text(
                  'Sign in to save itineraries, incidents, your digital '
                  'emergency ID and eco progress. Your data is private — '
                  'only you (and authorized administrators for safety '
                  'features) can access it.',
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
