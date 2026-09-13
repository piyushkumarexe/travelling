// Firebase configuration for Tourism.
//
// Project: tourism-39425 (project number 216165370573)
// Android app: app.roamio.tourism
// Values taken from the project's google-services.json. These are public
// client identifiers (same as any FlutterFire-generated file) — access is
// still enforced by Firebase Auth, Firestore/Storage rules and the
// package-name + SHA restrictions configured in the Firebase console.
//
// If you ever re-register the Android app, run:
//   dart pub global activate flutterfire_cli
//   flutterfire configure --platforms=android
// (this rewrites this file with the new values).

import 'dart:io' show Platform;

import 'package:firebase_core/firebase_core.dart';

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (Platform.isAndroid) {
      return android;
    }
    throw UnsupportedError(
      'Tourism currently only supports Android. '
      'Run `flutterfire configure --platforms=android`.',
    );
  }

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyCjXD5ykiMulIXcb2VrzGLA8iBMkFTCt9M',
    appId: '1:216165370573:android:fa5a4121d0e6fdfc077784',
    messagingSenderId: '216165370573',
    projectId: 'tourism-39425',
    storageBucket: 'tourism-39425.firebasestorage.app',
  );
}

/// True when [DefaultFirebaseOptions] has been filled with real values.
///
/// The app uses this to show a guided setup screen instead of failing at
/// runtime with an obscure Firebase error.
bool get firebaseIsConfigured {
  final FirebaseOptions o = DefaultFirebaseOptions.android;
  bool clean(String? v) =>
      v != null && v.isNotEmpty && !v.startsWith('REPLACE_');
  return clean(o.apiKey) &&
      clean(o.appId) &&
      clean(o.messagingSenderId) &&
      clean(o.projectId);
}
