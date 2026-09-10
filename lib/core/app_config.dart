/// Central client-side configuration for Tourism.
///
/// SECURITY NOTE: This file must never contain secret API keys. The Tourism
/// client only talks to its own Firebase Cloud Functions backend; all third
/// party keys (NVIDIA, OpenWeather, Google Places/Directions/Geocoding) are
/// stored server-side as environment variables and proxied by the backend.

class AppConfig {
  AppConfig._();

  /// Region where the Tourism backend Cloud Functions are deployed.
  ///
  /// Must match the `region` setting in `functions/src/index.js` and the
  /// region used when running `firebase deploy`.
  static const String functionsRegion = 'us-central1';

  /// Base URL of the Tourism backend, derived from the active Firebase
  /// project id (no hardcoded host needed).
  static String functionsBaseUrl(String projectId) =>
      'https://$functionsRegion-$projectId.cloudfunctions.net';

  /// OpenWeather units used across the app.
  static const String weatherUnits = 'metric';

  /// Maximum file sizes accepted for user uploads (bytes).
  static const int maxImageBytes = 10 * 1024 * 1024; // 10 MB
  static const int maxVideoBytes = 50 * 1024 * 1024; // 50 MB
  static const int maxAvatarBytes = 5 * 1024 * 1024; // 5 MB
}
