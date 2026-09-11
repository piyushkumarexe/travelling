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
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 16),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              const SizedBox(height: 12),
              Container(
                width: 92,
                height: 92,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: <Color>[Color(0xFF14B8A6), Color(0xFF0D9488)],
                  ),
                  borderRadius: BorderRadius.circular(28),
                  boxShadow: <BoxShadow>[
                    BoxShadow(
                      color: const Color(0xFF0D9488)
                          .withOpacity(dark ? 0.45 : 0.30),
                      blurRadius: 24,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                child: const Icon(Icons.explore, size: 48, color: Colors.white),
              ),
              const SizedBox(height: 22),
              Text(
                'Yatrawise',
                style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.5,
                    ),
              ),
              const SizedBox(height: 8),
              Text(
                'Your smart tourism & safety companion',
                style: Theme.of(context).textTheme.bodyLarge
                    ?.copyWith(color: scheme.onSurfaceVariant),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 18),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  _featureChip(
                      context, Icons.map_outlined, 'Real Google Maps'),
                  _featureChip(context, Icons.sos_outlined, 'SOS & geofencing'),
                  _featureChip(
                      context, Icons.auto_awesome_outlined, 'AI assistant'),
                ],
              ),
              const Spacer(),
              PrimaryButton(
                label: _loading ? 'Signing in…' : 'Continue with Google',
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
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }

  Widget _featureChip(BuildContext context, IconData icon, String label) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: dark ? scheme.surfaceContainerLow : Colors.white,
        borderRadius: BorderRadius.circular(999),
        border:
            Border.all(color: scheme.outlineVariant.withOpacity(0.6)),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.black.withOpacity(dark ? 0.25 : 0.05),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 15, color: scheme.primary),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
