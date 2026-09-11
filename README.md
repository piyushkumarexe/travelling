# YatraWise — Smart Tourism & Safety Assistant (Android)

YatraWise is a native Android app (Flutter) that combines a premium travel
experience with real safety tooling: live Google Maps, real AI assistance
(NVIDIA), real weather (OpenWeather), AI incident triage, geofenced safety
zones with Android notifications, a one-tap SOS flow, a Digital Emergency
ID with real QR verification, and an Eco Score for sustainable travel.

Everything is real and wired end-to-end — there are no demo buttons and no
fake data. All third-party secrets (NVIDIA, OpenWeather, Google Maps server
key) live only in the Firebase Cloud Functions backend; the Android app ships
with no secret API keys (the MapTiler tile key is a public, client-side key,
the same category as the Google Maps Android key).

---

## Feature overview

| Area | What it actually does |
| --- | --- |
| Home dashboard | Live location label, real weather, safety-zone status for your position, nearby tourist attractions, latest alerts, SOS button, emergency ID, report incident, AI assistant, itineraries, eco score — every card navigates to a working feature. |
| Explore | Real Google Places text search + category browsing (attractions, food, hidden gems), place detail with real photos (proxied), rating, price level, open/closed, distance from you, and "navigate" that opens real Google Maps navigation. |
| Map | MapTiler tiles via `flutter_map` (satellite by default with a streets toggle): live GPS dot with real-time follow mode, zoom/pan, place search markers, tourist attractions, safety zones (color-coded circles), emergency services, destination markers, distance + route info (real Directions API polyline when available, honestly-labelled straight-line fallback), current-location button, proper permission handling. |
| AI assistant | Real conversational AI with your current location and travel preferences as context: Cloud Functions backend first, then a direct NVIDIA key or any OpenAI-compatible provider compiled in at build time. Typing indicator, error states, suggestion chips. |
| Itinerary generator | Destination + days + interests + budget + style → real AI-generated plan (NVIDIA JSON), preview, regenerate, save to Firestore, view by day, delete. |
| Safety hub | Nearest active zone, zone list with details, geofence monitor (real background location while app runs), in-app warning + Android notification + notification history when entering a high-risk zone, nearby emergency services you can actually call (`tel:`) or get directions to. |
| SOS | Confirm dialog → real GPS fix → `emergencyEvents` document → active status UI with coordinates/accuracy → nearby emergency services with call buttons → cancel/resolve. Never claims authorities were contacted. |
| Incident reporting | Description + photo + video + location → Firebase Storage (type/size validated) → NVIDIA triage (category, severity, summary, recommended action) → Firestore + history + admin review. |
| Digital Emergency ID | Real profile record with a QR code containing **only** a 64-char verification token. Active/revoked, copy token, and a real verification screen (camera scan via `mobile_scanner` or manual paste) that checks Firestore live. |
| Eco score | GPS-tracked walk/cycle sessions (real distance accumulation) or manual logs; points/levels/badges persisted in Firestore. |
| Weather | Current conditions + 5-day forecast from OpenWeather (backend proxy) with practical safety notes and full loading/error/retry states. |
| Notifications | Per-user notification history (safety, geofence, incident, emergency, weather) with read/unread and deep-links. |
| Profile | Name, photo (Storage upload), language, emergency contact, budget/style/interests — all in Firestore — plus sign out. |
| Admin console | Role-gated in the app **and** enforced server-side by Firebase security rules: view/update all incidents, create/edit/disable safety zones, view and resolve all SOS events. |

---

## Tech stack

- **Flutter 3.32 / Dart 3.8** — Material 3, GoRouter, DI-free service container.
- **Firebase** — Authentication (Google + email/password sign-in), Cloud Firestore, Storage,
  Cloud Functions v2 (Node 20, CommonJS) as the secure API gateway.
- **MapTiler + flutter_map** — raster tiles (satellite + streets) with a
  public client key; the map widget needs no Google Maps SDK key.
- **Google** — Places/Directions/Geocoding APIs (server key, proxied) and
  turn-by-turn navigation via the installed Google Maps app.
- **OpenWeather** — current + forecast (server key, proxied).
- **NVIDIA API** — Llama 3.1 70B instruct for chat, itinerary JSON and
  incident triage (server key only).
- **GitHub Actions** — analyze + test + release APK artifact.

## Repository layout

```
android/                  # native Android project (app.roamio.tourism)
lib/
  main.dart               # entrypoint (Firebase init)
  app.dart                # MaterialApp + router wiring
  app_shell.dart          # bottom-nav shell + SOS bridge + geofence alerts
  firebase_options.dart   # YOUR Firebase config (replace the template)
  core/                   # theme, services, state, widgets, utils, network
  data/models/            # typed models + parsers
  data/repositories/      # all Firestore/API access behind one API
  features/               # one folder per feature area (screens)
functions/                # Cloud Functions (secure backend gateway)
firestore.rules           # Firestore security rules
storage.rules             # Storage security rules
firestore.indexes.json    # indexes (none required today)
firebase.json             # firebase deploy manifest
test/                     # unit + widget tests
.github/workflows/        # Build APK (runnable from the Actions UI)
```

## Collections (Firestore)

```
users/{uid}                          # { role: 'user'|'admin', displayName, email }
profiles/{uid}                       # name, photoUrl, language, contacts, prefs
safetyZones/{id}                     # name, lat, lng, radiusMeters, riskLevel, active, ...
incidents/{id}                       # uid, reporterName, description, category, severity,
                                     # status, lat, lng, summary, recommendedAction, media
emergencyEvents/{id}                 # uid, name, lat, lng, accuracyMeters, status, timestamps
digitalIds/{id}                      # uid, ownerName, token (64-hex), photoUrl, contacts, status
users/{uid}/itineraries/{id}         # destination, days, interests, budget, travelStyle, plan
users/{uid}/notifications/{id}       # title, body, type, read, payload, createdAt
ecoScores/{uid}                      # score, byMode, badges, sessions
ecoScores/{uid}/activities/{id}      # mode, distanceMeters, durationSeconds, note
rateLimits/{uid:endpoint:minute}     # backend-only (denied to clients by rules)
```

## Setup (one-time, ~30 minutes)

### 1. Prerequisites

- Flutter 3.32.x (`flutter doctor` green for Android)
- Firebase CLI (`npm i -g firebase-tools`)
- An Android device or emulator with Google Play Services
- A Firebase project (e.g. `yatrawise-prod`)

### 2. Firebase project

1. Create the project in the Firebase console.
2. **Authentication → Sign-in method**:
   - **Google**: enable it (see step 3 for the OAuth client).
   - **Email/Password**: enable it to allow email sign-up/sign-in.
3. **Project settings → Your apps → Add app (Android)** with
   package name `app.roamio.tourism`.
4. Run `flutterfire configure` (or paste the downloaded config into
   `lib/firebase_options.dart`). The committed file is a placeholder
   template — replace `REPLACE_WITH_YOUR_...` values.
5. **Firestore → Create database** (production mode, closest region).
6. **Storage → Get started** (production mode).

### 3. Google sign-in credentials

1. In the **Google Cloud console** (linked to your Firebase project):
   **APIs & Services → Credentials → Create OAuth client ID → Android**.
   - Package name: `app.roamio.tourism`
   - SHA-1 fingerprint: for local debug builds use the debug keystore
     (`keytool -list -v -keystore ~/.android/debug.keystore -alias androiddebugkey -storepass android`);
     add your release fingerprint too if you sign your own builds.
   The SHA-1 of the exact APK you install must be registered here, otherwise
   Google Sign-In fails instantly.
2. Because this app uses `firebase_options.dart` (not `google-services.json`),
   you must also provide the Google Sign-In **Web client ID** as the
   `serverClientId`:
   - Firebase console → **Project settings → Your apps → Web app** → copy the
     `Web client ID` (ends with `.apps.googleusercontent.com`), or
   - Google Cloud → **Credentials** → the "Web client (auto-created by Google
     Service)" client.
   Then either hardcode it in `lib/core/app_config.dart`
   (`googleWebClientId`) or build with:
   `flutter build apk --dart-define=GOOGLE_WEB_CLIENT_ID=xxxx.apps.googleusercontent.com`
   (in CI set the `GOOGLE_WEB_CLIENT_ID` secret).

### 4. Google Maps keys (two separate keys)

> The interactive map widget now renders with **MapTiler** tiles, so the
> Maps SDK **client key is optional** (the map shows without it). The
> `MAPTILER_API_KEY` default is already compiled in; override it with
> `--dart-define=MAPTILER_API_KEY=...` (CI secret `MAPTILER_API_KEY`).

**Client key (Android manifest):**
1. Credentials → Create API key → restrict to **Android apps** with your
   package name + SHA-1s; enable the **Maps SDK for Android**.
2. Paste it into `android/app/src/main/AndroidManifest.xml` in the
   placeholder meta-data:
   `<meta-data android:name="com.google.android.geo.API_KEY" .../>`

**Server key (backend proxy):**
1. Create a second key restricted by **IP addresses** (Cloud Functions —
   leave the IP restriction "all" and restrict by app engine/Cloud
   Functions service) or simply to the Cloud Functions service; enable
   **Places API (legacy), Geocoding API, Routes API**.
2. Set it as the `GOOGLE_MAPS_API_KEY` function environment variable
   (see step 7). It never ships in the APK.

### 5. AI keys (free) + OpenWeather

> In 2026 every keyless AI provider shut down anonymous access (Pollinations,
> Hack Club AI, DuckDuckGo AI all did), so the assistant needs ONE free key.
> All of these work as a single GitHub secret; the app auto-prefers Groq →
> NVIDIA → Gemini → generic.

1. **Groq (fastest, recommended)**: get a free key at https://console.groq.com/keys
   → set it as the `GROQ_API_KEY` GitHub secret (or build with
   `--dart-define=GROQ_API_KEY=gsk_...`). Default model
   `llama-3.3-70b-versatile`; override with `GROQ_MODEL`.
2. **Google Gemini**: get a free key at https://aistudio.google.com/apikey →
   set it as the `GEMINI_API_KEY` GitHub secret (or build with
   `--dart-define=GEMINI_API_KEY=AIza...`). Default model `gemini-2.5-flash`.
3. **NVIDIA**: create a free key (build.nvidia.com) → set it as the
   `NVIDIA_API_KEY` GitHub secret (or
   `--dart-define=NVIDIA_API_KEY=nvapi-...`; optionally override
   `NVIDIA_MODEL`).
4. **Any OpenAI-compatible provider** (OpenRouter / Mistral / …):
   `AI_API_KEY` + `AI_BASE_URL` + `AI_MODEL` GitHub secrets / dart-defines.
5. OpenWeather: create an API key → set as `OPENWEATHER_API_KEY`.

### 6. Deploy the secure backend

```bash
firebase login
firebase use <your-project-id>

# 1) define the secrets (prompts you for the value — nothing is committed)
firebase functions:secrets:set NVIDIA_API_KEY
firebase functions:secrets:set OPENWEATHER_API_KEY
firebase functions:secrets:set GOOGLE_MAPS_API_KEY

# 2) deploy functions + rules + indexes
#    (firebase.json already declares the three secrets for the function)
firebase deploy --only functions,firestore:rules,storage:rules,firestore:indexes
```

`GOOGLE_FUNCTION_REGION` defaults to `us-central1` — set it as a
regular function environment variable in the console if your functions
region differs.

### 7. Make someone an admin (optional)

In the Firestore console, set the `users/{yourUid}` document's `role`
to `admin`. The app's admin area appears on Profile → Admin area.
Normal users are blocked by the security rules even if they tamper with
the UI.

### 8. Run locally

```bash
flutter pub get
flutter run          # on a connected device / emulator
```

First launch shows a short setup guide; sign in with Google (an account
that has access to the OAuth client) or create an account with your email
and password, and you land on the dashboard.

## Building the APK

### Via GitHub Actions (recommended)

1. Push to `main` (or any PR into `main`), **or** open
   **GitHub → Actions → "Build APK" → Run workflow**.
2. Watch the two jobs: **Analyze & test** (pub get, `flutter analyze
   --fatal-warnings`, `flutter test`) and **Build release APK**
   (JDK 17 + Android SDK + `flutter build apk --release`).
3. Download the **`yatrawise-release-apk`** artifact from the job summary.

The release APK is signed with the project's *debug* keystore (the same
one CI always has). For public distribution you should create a proper
release keystore and provide it as workflow secrets — see "Signing"
below.

### Locally

```bash
flutter build apk --release
# → build/app/outputs/flutter-apk/app-release.apk
```

### Signing (optional, for store distribution)

Create a keystore, add its path/password to **Settings → Secrets** in the
repo, and switch `android/app/build.gradle` release signing config to
read from `System.getenv(...)`. The committed config intentionally
uses the debug keystore so the CI build is reproducible without secrets.

## Android permissions (and why)

| Permission | Used for |
| --- | --- |
| `ACCESS_FINE_LOCATION` / `ACCESS_COARSE_LOCATION` | Dashboard location label, distances, SOS coordinates, eco tracking, geofence entry detection. |
| `ACCESS_BACKGROUND_LOCATION` | Geofence monitoring while the app is in the background (only started by the user; status is always shown in Safety). |
| `POST_NOTIFICATIONS` (Android 13+) | Zone-entry + safety alerts. |
| `CAMERA` | Digital ID QR scanning. |
| `INTERNET` | All network traffic. |

All location/notification flows check the permission state first and
show a real error state when denied — nothing is simulated.

## Security model

- **No third-party API keys in the APK.** The app talks only to Firebase
  and to its own Cloud Functions endpoints; NVIDIA/OpenWeather/Google
  server keys live in function secrets.
- **Firestore security rules** (`firestore.rules`):
  - users can only create/update their own documents in
    `users/{uid}`, `profiles/{uid}`, `emergencyEvents` (own),
    `incidents` (own, fixed status on create), `digitalIds` (own; token
    must match `^[0-9a-f]{64}$`), itineraries & notifications & eco in
    per-user subcollections;
  - `safetyZones` are read-only for everyone, writable by admins;
  - `rateLimits` is denied to all clients (backend-only);
  - admin checks go through the `users/{uid}.role == 'admin'` document,
    so the admin area cannot be faked client-side.
- **Storage rules** (`storage.rules`): incident media limited to
  image/jpeg|png|webp or video/mp4|mov|webm|3gpp ≤ 50 MB under
  `incidents/{uid}/`; avatars image-only ≤ 5 MB under `avatars/{uid}/`;
  everything else denied.
- **Rate limiting**: every backend endpoint enforces a per-user
  per-minute quota in a Firestore transaction
  (`chat` 10, `itinerary` 5, `incidentAnalyze` 5, `weather*` 20,
  `places*` 30, `route` 20, `geocodeReverse` 20, `emergencyNearby` 10).
- **Input validation** client-side (shared `Validators`) *and*
  server-side on every endpoint (types, ranges, string lengths, enums).
- **Digital ID QR** encodes only the random 64-hex token — no personal
  data is ever in the QR payload.

## Backend endpoints (Cloud Functions, all POST unless noted)

| Path | Purpose |
| --- | --- |
| `/chat` | NVIDIA chat (location + profile context injected server-side) |
| `/itinerary` | NVIDIA JSON itinerary for destination/days/interests/budget/style |
| `/incidentAnalyze` | NVIDIA triage → category, severity, summary, recommended action |
| `/weatherCurrent` | OpenWeather current conditions |
| `/weatherForecast` | OpenWeather 5-day forecast (aggregated) |
| `/placesSearch` | Google Places (text query ± location bias, or nearby by types) |
| `/placesDetails` | Google Places details by place id |
| `/placesPhoto` | (GET) Places photo proxy |
| `/emergencyNearby` | Nearby hospital/police/fire/doctor |
| `/route` | Google Routes v2 with **server-decoded** polyline; labelled straight-line fallback on failure |
| `/geocodeReverse` | Reverse geocoding → short human label |

Every response is JSON with `kind` on errors (`validation`, `upstream`,
`rate`, `config`, `internal`) so the UI can show meaningful states.

## Manual configuration checklist (quick reference)

- [ ] `lib/firebase_options.dart` replaced with real values
- [ ] Google OAuth Android client created (`app.roamio.tourism` + SHA-1)
- [ ] Maps **client** key in `android/app/src/main/AndroidManifest.xml`
- [ ] Firestore database created; rules deployed
- [ ] Storage bucket created; rules deployed
- [ ] Functions deployed with `NVIDIA_API_KEY`, `OPENWEATHER_API_KEY`,
      `GOOGLE_MAPS_API_KEY` secrets set
- [ ] (optional) `users/{uid}.role = "admin"` for the admin console

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| Sign-in fails immediately | OAuth client missing the device's SHA-1, Web client ID (`serverClientId`) not set, or account not allowed for the client. |
| Map tiles don't load | Check your connection and the MapTiler key (default is compiled in; override with `--dart-define=MAPTILER_API_KEY=...`). |
| "Backend is missing the X configuration" | Set the function secret and redeploy functions. |
| Places search 403 | Server key not restricted/allowed properly for Places (legacy) API. |
| Geofence never fires | Background location permission must be *While using* or *All the time*; zone must be active; keep the process alive (Android battery saver off while testing). |
| SOS button says location unavailable | Enable device GPS; the app will not fabricate coordinates. |

## Honest limitations

- Geofence monitoring runs while the app is alive (foreground or
  background with location permission); it is not a separate OS-level
  geofence service.
- The release APK in CI is debug-keystore signed until you supply a
  release keystore.
- Incidents/SOS records are *stored and visible to admins* — the app
  never contacts police or emergency services on your behalf; the call
  buttons dial real local services through your phone app.
- Blockchain is intentionally **not** claimed or used; the Digital ID is
  modular so a chain-based anchoring could be added later.

## License

Proprietary — all rights reserved.
