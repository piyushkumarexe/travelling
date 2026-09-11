// Firebase configuration template.
//
// IMPORTANT
// ---------
// This file ships with PLACEHOLDER values so the project compiles out of the
// box. It is NOT wired to a live Firebase project yet.
//
// To configure your real project (see README > "Firebase setup"):
//   1. Create a Firebase project + Android app (com.roamio.app).
//   2. Install the FlutterFire CLI:  dart pub global activate flutterfire_cli
//   3. Run:  flutterfire configure --platforms=android
//      (this rewrites this file with your real values)
//   4. Or copy the values from Firebase Console > Project settings > Your
//      apps > SDK setup and configuration into the constants below.
//
// NEVER commit real Firebase API keys or a real google-services.json.

import 'dart:io' show Platform;

import 'package:firebase_core/firebase_core.dart';

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (Platform.isAndroid) {
      return android;
    }
    throw UnsupportedError(
      'YatraWise currently only supports Android. '
      'Run `flutterfire configure --platforms=android`.',
    );
  }

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'REPLACE_WITH_FIREBASE_API_KEY',
    appId: 'REPLACE_WITH_FIREBASE_ANDROID_APP_ID',
    messagingSenderId: 'REPLACE_WITH_MESSAGING_SENDER_ID',
    projectId: 'REPLACE_WITH_FIREBASE_PROJECT_ID',
    storageBucket: 'REPLACE_WITH_FIREBASE_PROJECT_ID.appspot.com',
  );
}

/// True when [DefaultFirebaseOptions] has been filled with real values.
///
/// The app uses this to show a guided setup screen instead of failing at
/// runtime with an obscure Firebase error.
bool get firebaseIsConfigured {
  final FirebaseOptions o = DefaultFirebaseOptions.android;
  final bool clean = (String? v) =>
      v != null && v.isNotEmpty && !v.startsWith('REPLACE_');
  return clean(o.apiKey) &&
      clean(o.appId) &&
      clean(o.messagingSenderId) &&
      clean(o.projectId);
}
