# Tourism — Smart Tourism & Safety Assistant (Android)

Tourism is a native Android app (Flutter) that combines a premium travel
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
   `openai/gpt-oss-120b`; override with `GROQ_MODEL`.
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

> **Quick start:** `bash scripts/deploy-backend.sh` — one command that logs you
> in, sets the three secrets and deploys functions + Firestore rules + Storage
> rules. Full Hindi/Hinglish step-by-step (including the **Blaze plan** and
> **Firestore database** requirements): see [`BACKEND_SETUP.md`](BACKEND_SETUP.md).

**Two things that are easy to miss:**
1. The project must be on the **Blaze (pay-as-you-go)** plan — v2 functions with
   secrets don't run on the free Spark plan.
2. A **Firestore database** must exist (console → Build → Firestore → Create
   database) — the rate limiter and app data depend on it.

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
| Notifications: `[cloud_firestore/permission-denied]` | The deployed Firestore rules predate `users/{uid}/notifications` (and the live-location update rule). Run **`bash scripts/deploy-rules.sh`** once from the repo root, then reopen the app — no reinstall needed. |

## Safety messaging (SOS, Power-Off, Live Location)

- **SOS activation** auto-sends an SMS with the traveler's coordinates and a
  Google Maps link to the saved SOS contact (SEND_SMS runtime permission is
  requested on first use), plus WhatsApp (`wa.me`) and manual SMS share
  buttons in the active-SOS sheet.
- **Power-Off Safety Location**: when Android broadcasts `ACTION_SHUTDOWN`,
  `PowerOffReceiver` queues that same SMS first (SMS works on the cellular
  network even with mobile data off — the only realistic channel during
  shutdown) and then writes the event to Firestore. The message states how
  old the last fix is; a fresh GPS fix after power-off is impossible.
- **Live location sharing**: started from the English prompt shown when
  in-app navigation begins ("Do you want to share your live location with
  your SOS contact?"). While active: SMS with fresh coordinates + map link
  immediately and every 5 minutes, cloud position refresh every 45 s
  (`emergencyEvents`, owner can update only whitelisted live fields while
  the event stays `active`), an ongoing notification, and a red on-map
  banner with Stop. It is deliberately in-process — closing the app stops
  the share; there is no hidden background tracking.
- SMS is delivered by the **Messages/SMS app** (not WhatsApp — WhatsApp has
  no keyless programmatic send). The WhatsApp buttons open a chat with the
  location message pre-filled; you press send. If the red share banner shows
  "SMS permission off", tap **Enable SMS** — the first message goes out
  immediately after granting.
- **Why WhatsApp cannot be "fully automatic"**: WhatsApp deliberately does
  not allow any third-party app to send messages silently (no official API
  without a business account + template approval, and unofficial hacks get
  numbers banned). So: with internet ON the share now **auto-opens your
  WhatsApp chat with the location message already typed** — one tap on send
  delivers it; with internet OFF the automatic SMS still reaches the contact
  with zero taps. There is also a chat icon on the red banner to re-open the
  WhatsApp chat with a fresh location any time.
- **Navigation survives tab switches**: the trip keeps running when you
  browse other features; a "Navigating to … · Resume" pill (top-left on
  every screen) jumps straight back. The trip ends automatically on arrival
  (or via **End trip**).
- **Google-style navigation camera**: the map follows you at street-level
  zoom and rotates so your travel direction stays up (both toggleable from
  the round buttons on the map), with a vehicle marker (car/bike/auto per
  your profile) rotated to your GPS heading. **Navigation uses the
  satellite/imagery map style (with roads + labels) by default** — the
  layers button switches back to the street map. The trip card starts as a
  slim collapsed bar (destination · remaining · ETA · speed) so the map
  stays fully visible; tap it to expand details and buttons. True 3D
  buildings/perspective are not possible with the map engine used
  (flutter_map renders flat raster tiles) — this follow-cam + rotating
  vehicle + satellite view is the closest equivalent.
- **Search suggestions are locality-first**: while typing, the app ranks
  your own city/area first (≤25 km → ≤100 km → ≤500 km → everywhere else),
  and within the same area exact name matches → prefix → substring. It now
  also merges Photon (OpenStreetMap POI autocomplete), so small local
  places (shops, guest houses, chaurahas) that global geocoders don't know
  actually show up instead of far-away same-named places in other states
  or countries.

## Travel Document & Booking Vault (🗂️)

One secure, private place for every travel document and booking — works for domestic and international travellers.

- **Where**: Home → "Travel Document & Booking Vault" card → `/vault`.
- **What you can store**: Passport, Visa, ID Proof, Flight / Train / Bus tickets, Hotel bookings, Cab/Car rental, Activity tickets, Travel Insurance, Other. Upload a PDF/JPG/PNG (images auto-compressed by the picker) or enter details manually — only the title is required; every other field is optional because document types differ.
- **Booking-specific fields** (all optional & editable): flights (airline, flight number, PNR, airports, departure/arrival date-time, terminal, seat), hotels (hotel name, booking ID, check-in/out, address, contact), trains/buses (operator, PNR/booking ID, origin/destination, departure/arrival, seat/coach), activities (provider, booking ID, venue, date-time, location).
- **Main screen**: upcoming bookings timeline (real saved dates only), documents expiring soon, recent entries, trips with documents, search (title / PNR / booking ID / airline / hotel / trip name), filter by type and by trip.
- **Trip linking**: documents reference the existing Trip Planner `tripId` — no trip data is duplicated.
- **Expiry reminders**: computed from the real current date (Expired / Expires today / Expires in X days / Valid) plus local notifications at 90 / 30 / 7 / 1 days before expiry through the existing `NotificationService` (only for documents that have an expiry date; reminders self-heal on every app start).
- **Storage**: metadata in Firestore `users/{uid}/travelDocuments/{documentId}` (owner-only rules), files in Firebase Storage `users/{uid}/travelDocuments/{documentId}/file` (owner-only, PDF/image only, 10 MB cap). Firestore never stores the file itself. Old files are deleted/replaced in place — no orphans. Uploads show progress, can be cancelled and retried to the same path (stable IDs — retries can't duplicate).
- **Privacy**: no document contents, numbers, PNRs or file URLs are logged or sent to analytics; files are never public.
- **OCR**: this project has no OCR capability, so nothing pretends to read documents — entry is manual and verified by you.
- **Packages added**: `file_picker` (PDF picking), `timezone` (reminder scheduling; already a transitive dependency of flutter_local_notifications). Manifest: `RECEIVE_BOOT_COMPLETED` added so scheduled reminders re-register after reboot.

## Travel Booking Hub (🧳)

Home card "Travel Booking Hub — Book rides, flights, trains, buses, hotels
and activities." (route `/booking`).

- One hub, seven categories (Ride, Flight, Train, Bus, Hotel/Stay, Car
  Rental, Activities). Tourism starts the booking — the booking and payment
  always happen in the provider's official app/site. No fares, seats,
  availability, ratings or confirmations are ever shown here.
- **Rides**: real GPS pickup (current-location button), MapTiler
  destination search + map-pin selection, recent locations (clearable),
  OSRM route preview (real distance/ETA). Bike/Auto/Cab selection, then
  **verified official hand-off only**:
  - **Uber** — official universal deep link (developer.uber.com documented
    `m.uber.com/ul/?action=setPickup…`) with pickup + drop coordinates;
    opens the Uber app when installed, else Uber mobile web.
  - **Ola** — official out-of-app flow (developers.olacabs.com documented
    `book.olacabs.com/?lat=…&lng=…&drop_lat=…&drop_lng=…`).
  - **Rapido** — Bike/Auto/Cab selected in Tourism, then the official app
    (com.rapido.passenger) is launched directly; Play Store page if not
    installed. Rapido has no public deep link, so locations are NOT
    prefilled — stated plainly, never faked.
- **Trains**: official IRCTC Rail Connect app (cris.org.in.prs.ima) launch +
  irctc.co.in fallback. **Flights**: MakeMyTrip's own public search URL
  (route/date/pax/class filled) + Goibibo official site. **Buses**: redBus
  official site. **Hotels**: Booking.com searchresults.html with official
  parameters (ss/checkin/checkout/group_adults/no_rooms). **Car rental**:
  Zoomcar official site. **Activities**: Headout/Klook official sites.
  Providers with unverified links are NOT included — nothing invented.
- Provider architecture: `BookingProvider` registry (id, category, verified
  deep link / app package / official web URL, handoff format, note) +
  `BookingApi` interface ready for a future official partner integration —
  no UI rewrite needed. No private APIs, scraping, OTP reading or credential
  storage — payments stay in the provider's secure flow.
- After returning, Tourism offers **Save booking**: the user enters the
  reference/PNR and status themselves (default "saved", never "confirmed").
  Saved to Firestore `users/{uid}/bookingRefs` (owner-only rules) and shown
  in "My saved bookings", linked to the active trip when one exists.
- Honest launch results: opened app / opened official web / app not
  installed (Play page opened) / link invalid / network error — never a
  fake success.
- Build tag `TRAVEL-BOOKING-HUB-2026-09-13-01` shown on the hub and ride
  screens temporarily for install verification. Deploy rules via
  `bash scripts/deploy-rules.sh` to enable saving booking references.

## Travel Expense Guard (💰)

Home card "Travel Expense Guard — Track every rupee of your trip."
(route `/expenses`).

- **Fast manual entry**: amount + category is enough; merchant, date/time,
  currency (INR/USD/EUR/GBP/AED/…), linked trip, payment method, notes,
  location (attached automatically ONLY if location permission was already
  granted) are optional. No OCR engine exists in the project, so receipts
  are stored as photos and the amount stays exactly what the user types —
  no pretend-scanning.
- **Database**: Firestore `users/{uid}/expenses/{id}` (owner-only rules,
  `userId` field must equal the authenticated UID, amount/category/currency
  validated). Receipts are compressed at pick time (max 1600 px, q80) and
  uploaded to Storage `receipts/{uid}/{expenseId}.jpg` — Firestore keeps
  only the download URL, never the binary. Delete removes the record and
  best-effort deletes the receipt file.
- **Offline-first**: every save/update/delete hits the local cache + an
  idempotent op queue first (stable client-generated ids; replayed in
  order). UI states are honest: "saved locally" / "Syncing…" / "Synced".
  Nothing is ever reported as synced when the write failed; "Sync now"
  retries.
- **Dashboard**: local-cache-first load, then live Firestore refresh via a
  single bounded listener (recent 200). Totals are shown PER CURRENCY —
  never mixed (no conversion service exists, so no rates are invented).
  Today's spend, category breakdown bars, deterministic insights ("You
  spent ₹1,240 today", "Food is your highest expense category").
- **Budgets**: optional daily budget stored in
  `users/{uid}/expenseData/budget`; remaining + % used are computed from
  real expenses, with 80% (warning) and 100%+ (over) states shown in-app.
- **History**: search, filters (trip, category, date range, payment
  method) and 4-way sort; details screen with edit/delete and split
  settlements.
- **Splits**: an expense can be shared (equal or custom amounts) saved
  INSIDE the expense document; the split must sum to the amount (±1 paise)
  before saving. "You paid / others owe you / you owe" comes only from
  saved split data — no payment collection.
- Deploy the rules after pulling: `bash scripts/deploy-rules.sh` (adds the
  `users/{uid}/expenses`, `users/{uid}/expenseData` Firestore blocks and
  the `receipts/{uid}` Storage block — nothing existing is weakened).
- Build tag `TRAVEL-EXPENSE-GUARD-2026-09-13-01` is shown temporarily at
  the bottom of the dashboard for install verification.

## Travel Autopilot (🧭)

A zero-itinerary trip engine on the Home screen: **"Tell us what you want to
do. We'll help you figure out what to do next."**

- Works with only **current location + available time** (30 min / 1 / 2 / 4 h /
  all day / custom). Interests (Eat, Explore, Shopping, Relax, Historical,
  Family, …), budget, travel mode, max-travel-time and an end destination are
  all OPTIONAL. A free-text box parses things like *"I have 3 hours and want
  to see historical places, budget of 500"* (deterministic parser — no fake AI).
- **WHAT SHOULD I DO NOW?** skips every question and ranks the real cached
  nearby dataset (the same Overpass/MapTiler system as Explore) with a
  practical score: distance, real OSRM road time (one `/table` request),
  OSM opening hours when mapped, remaining time fit, and session interests.
- Every recommendation shows **understandable reasons** ("1.4 km away
  (~6 min drive)", "Open until 9:00 PM — enough time to visit",
  "Opening hours unavailable") and impractical places (arrival after closing,
  doesn't fit remaining time) are listed separately with the exact reason.
- **TAKE ME THERE** opens the existing OSRM navigation; arrival (≤80 m
  geofence) triggers "✅ You've arrived — SHOW NEXT / STAY HERE / END".
- ⚡ **AUTO PLAN** builds a multi-stop sequence that fits the available time
  (🟢/🔴 verdict), with START THIS PLAN / REGENERATE / CHANGE.
- 🛟 **FIX MY TRIP** recovers a late schedule by dropping tail stops with
  real calculated reasons; 😴 **BREAK** finds nearby cafés/parks and banks a
  30-minute break; **CHANGE PLAN** re-picks interests without touching
  completed stops; **STOP AUTOPILOT** is always one tap away.
- Budget mode is honest: transport is a labelled distance-based estimate;
  entry/food show **"price unavailable"** — prices are never invented.
- The session (stops, time, brief, learned interests) persists in
  SharedPreferences per user and **survives app restarts** until the time
  window ends. Interest learning uses only in-app choices and has
  **Reset preferences**.
- Developer-only simulation controls (simulated arrival/delay/skip/time) are
  hidden in release builds — unlock with 7 taps on the screen title.

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
