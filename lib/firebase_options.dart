// Firebase options generated from the Android configuration registered for
// app.roamio.tourism in the tourism-39425 Firebase project.
//
// Firebase client identifiers are bundled in every Android application and
// are not server secrets. Access is protected by Firebase Auth, Security
// Rules, App Check, and API restrictions. Third-party secrets (including the
// NVIDIA key) must remain in Firebase Secret Manager.

import 'dart:io' show Platform;

import 'package:firebase_core/firebase_core.dart';

class DefaultFirebaseOptions {
  /// OAuth 2.0 web client created by Firebase Authentication. Google Sign-In
  /// uses this audience to return the ID token accepted by Firebase Auth.
  static const String googleWebClientId =
      '216165370573-eteu1jqusr6853ps9kru5ii8raejem3l.apps.googleusercontent.com';

  static FirebaseOptions get currentPlatform {
    if (Platform.isAndroid) return android;
    throw UnsupportedError('Tourism currently supports Android only.');
  }

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyCjXD5ykiMulIXcb2VrzGLA8iBMkFTCt9M',
    appId: '1:216165370573:android:fa5a4121d0e6fdfc077784',
    messagingSenderId: '216165370573',
    projectId: 'tourism-39425',
    storageBucket: 'tourism-39425.firebasestorage.app',
  );
}

/// True when the Android Firebase client is configured with real values.
bool get firebaseIsConfigured {
  final FirebaseOptions options = DefaultFirebaseOptions.android;
  return options.apiKey.isNotEmpty &&
      options.appId.isNotEmpty &&
      options.messagingSenderId.isNotEmpty &&
      options.projectId.isNotEmpty &&
      !options.apiKey.startsWith('REPLACE_');
}
