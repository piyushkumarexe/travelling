import 'package:flutter/material.dart';

import '../../map/screens/map_screen.dart';

/// Shown when Firebase is not configured yet (or on the splash route).
/// This is a real, actionable state — the app never pretends to work
/// without configuration.
class SetupGuideScreen extends StatelessWidget {
  const SetupGuideScreen({super.key, this.splash = false});

  final bool splash;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    if (splash) {
      // The '/' route is only reachable while the auth state is loading.
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Container(
                width: 84,
                height: 84,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: <Color>[Color(0xFF0B3954), Color(0xFF0E7C7B)],
                  ),
                  borderRadius: BorderRadius.circular(24),
                ),
                child: const Icon(Icons.explore, size: 46, color: Colors.white),
              ),
              const SizedBox(height: 24),
              const Text(
                'Roamio',
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 20),
              const CircularProgressIndicator(),
            ],
          ),
        ),
      );
    }

    final List<(String, String)> steps = <(String, String)>[
      (
        '1. Create a Firebase project',
        'Console → create project → add an Android app with package name '
        'com.roamio.app → download google-services.json (not required for '
        'this codebase, but keep it handy) and copy the web/config values.',
      ),
      (
        '2. Configure Firebase in the app',
        'Run `dart pub global activate flutterfire_cli` then '
        '`flutterfire configure --platforms=android`. This rewrites '
        'lib/firebase_options.dart with your real values. Or paste them in '
        'manually (apiKey, appId, messagingSenderId, projectId, bucket).',
      ),
      (
        '3. Deploy the Roamio backend',
        'From the functions/ folder: `firebase deploy --only functions` with '
        'NVIDIA_API_KEY, OPENWEATHER_API_KEY and GOOGLE_MAPS_API_KEY set '
        '(see .env.example). GitHub Actions secrets are not read by the '
        'deployed function; use Firebase Secret Manager.',
      ),
      (
        '4. Deploy rules',
        '`firebase deploy --only firestore:rules,storage:rules` so data is '
        'protected and admin gating works.',
      ),
      (
        '5. Map is ready',
        'Roamio now uses an interactive OpenStreetMap, so no Android Maps API '
        'key is required. Live Places and road routes use the separately '
        'deployed Firebase backend when configured.',
      ),
      (
        '6. Restart the app',
        'Hot-restart or rebuild. The login screen (real Google Sign-In) '
        'will appear.',
      ),
    ];

    return Scaffold(
      appBar: AppBar(title: const Text('Roamio setup')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: <Widget>[
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: scheme.secondaryContainer,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              children: <Widget>[
                Icon(Icons.construction, color: scheme.onSecondaryContainer),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'This build is not connected to a Firebase project yet. '
                    'Finish the steps below and restart the app.',
                    style: TextStyle(color: scheme.onSecondaryContainer),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          for (final (String title, String body) in steps)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Card(
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                  side: BorderSide(color: scheme.outlineVariant),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(title,
                          style: Theme.of(context)
                              .textTheme
                              .titleSmall
                              ?.copyWith(fontWeight: FontWeight.w700)),
                      const SizedBox(height: 6),
                      Text(body, style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ),
                ),
              ),
            ),
          const SizedBox(height: 8),
          FilledButton.icon(
            icon: const Icon(Icons.map_outlined),
            label: const Text('Open demo map now'),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const MapScreen(),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Full instructions: see README.md in the repository.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
