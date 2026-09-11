// Central client-side configuration for YatraWise.
//
// SECURITY NOTE: This file must never contain secret API keys. The YatraWise
// client only talks to its own Firebase Cloud Functions backend; all third
// party keys (NVIDIA, OpenWeather, Google Places/Directions/Geocoding) are
// stored server-side as environment variables and proxied by the backend.

class AppConfig {
  AppConfig._();

  /// Region where the YatraWise backend Cloud Functions are deployed.
  ///
  /// Must match the `region` setting in `functions/src/index.js` and the
  /// region used when running `firebase deploy`.
  static const String functionsRegion = 'us-central1';

  /// Base URL of the YatraWise backend, derived from the active Firebase
  /// project id (no hardcoded host needed).
  static String functionsBaseUrl(String projectId) =>
      'https://$functionsRegion-$projectId.cloudfunctions.net';

  /// Google Sign-In web OAuth client ID ("Web client" type), required on
  /// Android when the app uses `firebase_options.dart` instead of a
  /// `google-services.json`. Without it `google_sign_in` cannot produce a
  /// usable ID token and Firebase rejects the credential.
  ///
  /// This is a public client identifier (safe to commit). It comes from
  /// Firebase console → Authentication → Google → "Web SDK configuration"
  /// (or Google Cloud → Credentials → "Web client (auto-created by Google
  /// Service)") and always ends with `.apps.googleusercontent.com`.
  /// Override at build time with:
  ///   flutter build apk --dart-define=GOOGLE_WEB_CLIENT_ID=xxxx.apps.googleusercontent.com
  static const String googleWebClientId = String.fromEnvironment(
    'GOOGLE_WEB_CLIENT_ID',
    defaultValue: '216165370573-eteu1jqusr6853ps9kru5ii8raejem3l.apps.googleusercontent.com',
  );

  /// Direct NVIDIA access — fallback when the Cloud Functions backend is
  /// not deployed/reachable yet. Injected at build time:
  ///   flutter build apk --dart-define=NVIDIA_API_KEY=nvapi-...
  /// Empty by default, in which case only the backend is used.
  static const String nvidiaApiKey =
      String.fromEnvironment('NVIDIA_API_KEY', defaultValue: '');
  static const String nvidiaModel = String.fromEnvironment(
    'NVIDIA_MODEL',
    defaultValue: 'meta/llama3.1-70b-instruct',
  );
  static const String nvidiaBaseUrl = 'https://integrate.api.nvidia.com/v1';

  /// True when a direct NVIDIA key was compiled into the app.
  static bool get nvidiaDirectEnabled => nvidiaApiKey.isNotEmpty;

  /// OpenWeather units used across the app.
  static const String weatherUnits = 'metric';

  /// Maximum file sizes accepted for user uploads (bytes).
  static const int maxImageBytes = 10 * 1024 * 1024; // 10 MB
  static const int maxVideoBytes = 50 * 1024 * 1024; // 50 MB
  static const int maxAvatarBytes = 5 * 1024 * 1024; // 5 MB
}
