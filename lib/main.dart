import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'core/state/app_container.dart';
import 'firebase_options.dart';

/// Keeps the last UI crash locally so a screenshot of the error page is
/// enough to diagnose it — nothing leaves the device.
Future<void> _persistUiError(String text) async {
  try {
    final SharedPreferences p = await SharedPreferences.getInstance();
    await p.setString('last_ui_error',
        '${DateTime.now().toIso8601String()}\n$text');
  } catch (_) {}
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations(<DeviceOrientation>[
    DeviceOrientation.portraitUp,
  ]);

  // RELEASE SAFETY NET: Flutter's default ErrorWidget renders NOTHING in
  // release builds — any build-time exception becomes a featureless WHITE
  // screen with no way forward (reported: Trip Planner from Travel
  // Intelligence). From now on a build error shows a real page saying what
  // to do — the user is never stuck on a blank screen again — AND the exact
  // exception is shown on-screen (and kept in local prefs) so a screenshot
  // is enough to diagnose the crash precisely.
  ErrorWidget.builder = (FlutterErrorDetails details) {
    FlutterError.presentError(details); // still logged for debugging
    final String errorText = (details.exception.toString());
    final String short = errorText.length > 600
        ? errorText.substring(0, 600)
        : errorText;
    unawaited(_persistUiError(short));
    return Material(
      color: const Color(0xFFF8FAFC),
      child: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const Icon(Icons.report_problem,
                    size: 44, color: Color(0xFFD97706)),
                const SizedBox(height: 12),
                const Text(
                  'Something went wrong on this screen',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 6),
                const Text(
                  'The rest of the app still works. Go back and try again — '
                  'if it keeps happening, reopen the app.',
                  style: TextStyle(fontSize: 13, color: Colors.black54),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                ElevatedButton.icon(
                  onPressed: () => SystemNavigator.pop(),
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('Close and reopen the app'),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  height: 110,
                  child: SingleChildScrollView(
                    child: SelectableText(
                      'Error details (send this screenshot):\n$short',
                      style: const TextStyle(
                          fontSize: 11, color: Colors.black45),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  };

  bool firebaseReady = false;
  FirebaseApp? app;
  if (firebaseIsConfigured) {
    try {
      app = await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );
      firebaseReady = true;
    } catch (e) {
      // Firebase exists but failed to initialize (bad key, offline first
      // start, ...). The app still opens in a guided setup state so the user
      // can fix the configuration.
      debugPrint('Tourism: Firebase init failed: $e');
      app = null;
    }
  }

  final AppContainer container = AppContainer(
    firebaseReady: firebaseReady,
    app: app,
  );

  // Local device settings (e.g. auto-read AI replies) — independent of
  // Firebase, so they load even when Firebase/Cloud Functions are absent.
  unawaited(container.settings.load());

  if (firebaseReady) {
    // Best effort: create notification channels + ask for permission.
    await container.notificationService.init();
    container.authState.start();
  }

  // Warm up location permission up-front so Explore "nearby", the map and
  // the AI assistant can auto-detect the user's location immediately.
  unawaited(container.locationService.requestPermission());

  runApp(TourismApp(container: container));
}
