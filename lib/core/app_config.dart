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
  static const String appVersion = '1.0.8';

  /// Region where the Tourism backend Cloud Functions are deployed.
  ///
  /// Must match the `region` setting in `functions/src/index.js` and the
  /// region used when running `firebase deploy`.
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

  /// Direct NVIDIA access — fallback when the Cloud Functions backend is
  /// not deployed/reachable yet. Injected at build time:
  ///   flutter build apk --dart-define=NVIDIA_API_KEY=nvapi-...
  /// Empty by default, in which case only the backend is used.
  static const String nvidiaApiKey =
      String.fromEnvironment('NVIDIA_API_KEY', defaultValue: '');
  static const String nvidiaModel = String.fromEnvironment(
    'NVIDIA_MODEL',
    defaultValue: 'nvidia/nemotron-3.5-lightning-30b-a3b',
  );
  static const String nvidiaBaseUrl = 'https://integrate.api.nvidia.com/v1';

  /// True when a direct NVIDIA key was compiled into the app.
  static bool get nvidiaDirectEnabled => nvidiaApiKey.isNotEmpty;

  /// Groq — very fast LPU inference (OpenAI-compatible), responses in ~1s.
  /// Preferred transport when a key is compiled in. Build with:
  ///   flutter build apk --dart-define=GROQ_API_KEY=gsk_...
  /// Free key: https://console.groq.com/keys
  static const String groqApiKey =
      String.fromEnvironment('GROQ_API_KEY', defaultValue: '');
  static const String groqModel = String.fromEnvironment(
    'GROQ_MODEL',
    defaultValue: 'openai/gpt-oss-120b',
  );
  static const String groqBaseUrl = 'https://api.groq.com/openai/v1';

  /// Google Gemini — easiest free option (Google account, no credit card).
  /// Uses Gemini's OpenAI-compatible endpoint so the app only needs ONE
  /// build-time value:
  ///   flutter build apk --dart-define=GEMINI_API_KEY=AIza...
  /// Free key: https://aistudio.google.com/apikey
  static const String geminiApiKey =
      String.fromEnvironment('GEMINI_API_KEY', defaultValue: '');
  static const String geminiModel = String.fromEnvironment(
    'GEMINI_MODEL',
    defaultValue: 'gemini-2.5-flash',
  );
  static const String geminiBaseUrl =
      'https://generativelanguage.googleapis.com/v1beta/openai';

  /// Generic OpenAI-compatible AI provider — used when NO NVIDIA/Gemini key
  /// is set. Lets the app talk to any provider (Groq, OpenRouter, Hack Club
  /// AI, Mistral, …) that exposes `/chat/completions`. Build with:
  ///   flutter build apk \
  ///     --dart-define=AI_API_KEY=... \
  ///     --dart-define=AI_BASE_URL=https://api.example.com/v1 \
  ///     --dart-define=AI_MODEL=some/model
  static const String aiApiKey =
      String.fromEnvironment('AI_API_KEY', defaultValue: '');
  static const String aiBaseUrl =
      String.fromEnvironment('AI_BASE_URL', defaultValue: '');
  static const String aiModel = String.fromEnvironment(
    'AI_MODEL',
    defaultValue: 'meta-llama/llama-3.1-8b-instruct',
  );

  /// True when any direct AI transport (Groq, NVIDIA, Gemini or generic) is
  /// compiled in.
  static bool get aiDirectEnabled =>
      groqApiKey.isNotEmpty ||
      nvidiaApiKey.isNotEmpty ||
      geminiApiKey.isNotEmpty ||
      (aiApiKey.isNotEmpty && aiBaseUrl.isNotEmpty);

  /// Resolved direct-AI settings: prefer Groq, then NVIDIA, then Gemini,
  /// then the generic OpenAI-compatible provider.
  static String get aiResolvedBaseUrl {
    if (groqApiKey.isNotEmpty) return groqBaseUrl;
    if (nvidiaApiKey.isNotEmpty) return nvidiaBaseUrl;
    if (geminiApiKey.isNotEmpty) return geminiBaseUrl;
    return aiBaseUrl;
  }

  static String get aiResolvedApiKey {
    if (groqApiKey.isNotEmpty) return groqApiKey;
    if (nvidiaApiKey.isNotEmpty) return nvidiaApiKey;
    if (geminiApiKey.isNotEmpty) return geminiApiKey;
    return aiApiKey;
  }

  static String get aiResolvedModel {
    if (groqApiKey.isNotEmpty) return groqModel;
    if (nvidiaApiKey.isNotEmpty) return nvidiaModel;
    if (geminiApiKey.isNotEmpty) return geminiModel;
    return aiModel;
  }

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

  /// Sanitized runtime diagnostic — never logs the key itself, only whether
  /// it is present, its length and its first 4 characters.
  static String debugMapConfig() {
    final String key = mapTilerApiKey;
    final String prefix = key.length >= 4
        ? key.substring(0, 4)
        : (key.isEmpty ? '<empty>' : key);
    return 'MapTiler configured=$mapTilerConfigured, '
        'keyLength=${key.length}, keyPrefix=$prefix';
  }

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
