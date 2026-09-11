import 'package:firebase_core/firebase_core.dart' show FirebaseApp;
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
      debugPrint('Yatrawise: Firebase init failed: $e');
      app = null;
    }
  }

  final AppContainer container = AppContainer(
    firebaseReady: firebaseReady,
    app: app,
  );

  if (firebaseReady) {
    // Best effort: create notification channels + ask for permission.
    await container.notificationService.init();
    container.authState.start();
  }

  runApp(YatrawiseApp(container: container));
}
