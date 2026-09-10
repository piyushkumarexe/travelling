import 'package:flutter/material.dart';

import '../../../core/state/app_container.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/creator_mark.dart';
import '../../../data/repositories/auth_repository.dart'
    show AuthException;
import '../../map/screens/map_screen.dart';

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
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              ClipRRect(
                borderRadius: BorderRadius.circular(24),
                child: Image.asset(
                  'assets/branding/tourism_logo.png',
                  width: 104,
                  height: 104,
                  fit: BoxFit.cover,
                  semanticLabel: 'Tourism app logo',
                ),
              ),
              const SizedBox(height: 24),
              Text(
                'Tourism',
                style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
              ),
              const SizedBox(height: 8),
              Text(
                'Your smart tourism & safety companion',
                style: Theme.of(context).textTheme.bodyLarge
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 12),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  _featureChip(Icons.map, 'OpenStreetMap'),
                  _featureChip(Icons.sos, 'SOS & geofencing'),
                  _featureChip(Icons.auto_awesome, 'AI assistant'),
                ],
              ),
              const Spacer(),
              PrimaryButton(
                label: _loading ? 'Signing in…' : 'Continue with Google',
                icon: _loading ? null : Icons.account_circle,
                loading: _loading,
                onPressed: _signIn,
              ),
              const SizedBox(height: 10),
              PrimaryButton(
                label: 'Explore demo map',
                icon: Icons.map_outlined,
                outlined: true,
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const MapScreen(),
                  ),
                ),
              ),
              const SizedBox(height: 24),
              Text(
                'Sign in to save itineraries, incidents, your digital '
                'emergency ID and eco progress. Your data is private — '
                'only you (and authorized administrators for safety '
                'features) can access it.',
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
                textAlign: TextAlign.center,
              ),
              const CreatorMark(padding: EdgeInsets.only(top: 16)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _featureChip(IconData icon, String label) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: scheme.primaryContainer.withOpacity(0.5),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 14, color: scheme.primary),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
