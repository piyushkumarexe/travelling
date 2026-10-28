// Central client-side configuration for Tourism.
//
// SECURITY NOTE: This file must never contain secret API keys. The Tourism
// client only talks to its own Firebase Cloud Functions backend; all third
// party keys (NVIDIA, OpenWeather, Google Places/Directions/Geocoding) are
// stored server-side as environment variables and proxied by the backend.

class AppConfig {
  AppConfig._();

  /// Human-readable app version, shown on the login screen so users can
  /// confirm they are running the latest build. Keep in sync with pubspec.
  static const String appVersion = '1.0.35';

  /// Region where the Tourism backend Cloud Functions are deployed.
  ///
  /// Must match the region the functions were deployed to (see
  /// `scripts/deploy-backend.sh`) — `firebase deploy --only functions`
  /// defaults to this region.
  static const String functionsRegion = 'us-central1';

  /// Base URL of the Tourism backend, derived from the active Firebase
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

  /// OpenWeather units used across the app.
  static const String weatherUnits = 'metric';

  /// MapTiler API key for tiles + geocoding. Supplied at build time ONLY —
  /// never committed to source (this default is intentionally empty):
  ///   flutter build apk --dart-define=MAPTILER_API_KEY=...
  /// In CI the same value comes from the MAPTILER_API_KEY repository secret
  /// (see .github/workflows/build-apk.yml). When no key is compiled in, the
  /// map uses keyless OpenStreetMap tiles instead, so it can never show an
  /// "Invalid key" error or a blank screen.
  static const String mapTilerApiKey = String.fromEnvironment(
    'MAPTILER_API_KEY',
    defaultValue: '',
  );

  /// True when a MapTiler key was compiled into this build.
  static bool get mapTilerConfigured => mapTilerApiKey.isNotEmpty;

  /// Sanitized runtime diagnostic: never includes key material or length.
  static String debugMapConfig() =>
      'MapTiler configured=$mapTilerConfigured';

  /// Raster tile URL template for [style], matching MapTiler's official
  /// TileJSON: `satellite` and `hybrid` serve JPEG tiles, everything else
  /// (streets-v2, …) serves PNG. `{r}` becomes `@2x` on high-DPI screens so
  /// tiles stay sharp. Only used when [mapTilerConfigured] is true.
  static String mapTilerTileUrl(String style) {
    final String ext = (style == 'satellite' || style == 'hybrid')
        ? 'jpg'
        : 'png';
    return 'https://api.maptiler.com/maps/$style/{z}/{x}/{y}{r}.$ext?key=$mapTilerApiKey';
  }

  /// The primary tile URL for the given [style]: MapTiler when a key is
  /// compiled in, otherwise keyless OpenStreetMap tiles. In keyless mode the
  /// map never makes a MapTiler request, so it never shows "Invalid key".
  static String tileUrlTemplate(String style) =>
      mapTilerConfigured ? mapTilerTileUrl(style) : fallbackTileUrl;

  /// Secondary (fallback) tile URL. Only used when a MapTiler key is compiled
  /// in — a bad/expired key still shows real OSM streets instead of a blank
  /// map. Null in keyless mode because the primary is already keyless.
  static String? get tileFallbackUrl =>
      mapTilerConfigured ? fallbackTileUrl : null;

  /// MapTiler hosted STYLE JSON for vector rendering (MapLibre GL 3D nav):
  /// `https://api.maptiler.com/maps/{style}/style.json?key=…`. Returns null
  /// in keyless mode — the 3D navigation view needs vector styles, so the
  /// app falls back to the 2D map when no key is compiled in.
  static String? styleJsonUrl(String style) => mapTilerConfigured
      ? 'https://api.maptiler.com/maps/$style/style.json?key=$mapTilerApiKey'
      : null;

  /// MapTiler v3 vector TileJSON (contains the `building` source-layer with
  /// render_height) used for the 3D building extrusions in the nav view.
  static String? get vectorTilesJsonUrl => mapTilerConfigured
      ? 'https://api.maptiler.com/tiles/v3/tiles.json?key=$mapTilerApiKey'
      : null;

  /// Optional high-detail building overlay. MapTiler's dedicated Buildings
  /// tileset is compatible with Planet v4 and provides building-part
  /// footprints plus facade_color, roof_color, roof_shape, height, and
  /// height_min. The 3D map keeps Planet v3 above as a graceful fallback when
  /// an account does not have access to this newer tileset.
  static String? get detailedBuildingsTilesJsonUrl => mapTilerConfigured
      ? 'https://api.maptiler.com/tiles/buildings/tiles.json?key=$mapTilerApiKey'
      : null;

  /// Keyless OpenStreetMap tile source (real streets/labels, no API key).
  /// Used as the primary source in keyless mode and as the fallback when a
  /// MapTiler key is compiled in.
  static const String fallbackTileUrl =
      'https://tile.openstreetmap.org/{z}/{x}/{y}.png';

  /// Maximum file sizes accepted for user uploads (bytes).
  static const int maxImageBytes = 10 * 1024 * 1024; // 10 MB
  static const int maxVideoBytes = 50 * 1024 * 1024; // 50 MB
  static const int maxAvatarBytes = 5 * 1024 * 1024; // 5 MB
}
