import 'package:flutter/material.dart';

import '../../../core/widgets/creator_mark.dart';
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
              ClipRRect(
                borderRadius: BorderRadius.circular(22),
                child: Image.asset(
                  'assets/branding/tourism_logo.png',
                  width: 92,
                  height: 92,
                  fit: BoxFit.cover,
                  semanticLabel: 'Tourism app logo',
                ),
              ),
              const SizedBox(height: 24),
              const Text(
                'Tourism',
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
        'app.roamio.tourism → download google-services.json (not required for '
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
        '3. Deploy the Tourism backend',
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
        'Tourism now uses an interactive OpenStreetMap, so no Android Maps API '
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
      appBar: AppBar(title: const Text('Tourism setup')),
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
          const Center(child: CreatorMark()),
        ],
      ),
    );
  }
}
