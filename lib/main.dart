import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app.dart';
import 'core/state/app_container.dart';
import 'firebase_options.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations(<DeviceOrientation>[
    DeviceOrientation.portraitUp,
  ]);

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
