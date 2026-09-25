# Tourism

## Smart Travel, Safety and Automation Assistant for Android

**Tourism** is a Flutter-based Android application designed to help travellers plan, automate, navigate, monitor, and manage a journey from one place. It combines trip planning, live navigation, travel safety, expense control, booking hand-offs, document storage, nearby discovery, AI assistance, and real notification automations without pretending that unavailable data is live or verified.

> **Current application version:** `1.0.24+25`
> **Android requirement:** Android 7.0 or later (`minSdk 24`)
> **Application ID:** `app.roamio.tourism`
> **Status:** Active development

---

## Table of contents

1. [Application idea](#application-idea)
2. [Problem statement](#problem-statement)
3. [Proposed solution](#proposed-solution)
4. [Objectives](#objectives)
5. [Target users](#target-users)
6. [Application content and user journey](#application-content-and-user-journey)
7. [Major features](#major-features)
8. [Travel Automation Center](#travel-automation-center)
9. [Technical approach](#technical-approach)
10. [Architecture and repository structure](#architecture-and-repository-structure)
11. [Security, privacy and responsible design](#security-privacy-and-responsible-design)
12. [Feasibility](#feasibility)
13. [Viability](#viability)
14. [Impact and benefits](#impact-and-benefits)
15. [Research basis](#research-basis)
16. [References](#references)
17. [Setup and development](#setup-and-development)
18. [Build and testing](#build-and-testing)
19. [Important instructions](#important-instructions)
20. [Known limitations](#known-limitations)
21. [Future scope](#future-scope)
22. [License](#license)

---

## Application idea

Travellers normally use separate applications for maps, weather, bookings, expenses, documents, emergency contacts, nearby services, and itinerary planning. Important actions are therefore scattered across multiple screens and are often remembered too late.

Tourism follows a **journey lifecycle** approach:

```text
Discover → Plan → Prepare → Travel → Stay safe → Track → Review
```

The central idea is to build a trustworthy travel companion that turns an itinerary into practical actions. Instead of only displaying information, Tourism can remind the traveller to check documents, verify bookings, review weather, prepare a vehicle, monitor expenses, hydrate, perform a safety check-in, back up important media, and close the trip properly.

The product follows three core principles:

1. **Use real data when it is available.**
2. **Label estimates and limitations honestly.**
3. **Require user consent before automation, tracking, or communication.**

---

## Problem statement

A traveller may face several preventable problems:

- Important documents or booking references are difficult to find at departure time.
- A trip plan may not account for realistic travel time, delays, opening hours, or budget.
- Safety information and emergency actions may be hidden across different applications.
- Expenses are recorded late or not recorded at all.
- Travellers forget pre-trip checks, hydration, check-in requirements, return timing, or backups.
- Booking comparison tools may show unverified or fabricated prices when official partner data is unavailable.
- Safety products may imply that police, providers, or contacts were notified when no such confirmation exists.
- Weak network coverage can make cloud-only travel tools unreliable.

Tourism addresses these issues through a unified, permission-aware and failure-aware Android experience.

---

## Proposed solution

Tourism provides:

- A single travel dashboard for the active journey.
- Real GPS-based maps, search, routes, nearby discovery and navigation.
- Trip planning and itinerary generation.
- A Travel Automation Center with individually controlled notification agents.
- SOS, emergency ID, safety zones, nearby emergency services and location-sharing tools.
- Booking provider hand-offs that keep booking and payment in official provider systems.
- A private document and booking vault.
- Expense, budget and vehicle-cost tools.
- Weather, essentials, eco activity and travel intelligence modules.
- AI assistance through configured providers, with deterministic fallbacks where appropriate.
- Honest loading, permission, offline, unavailable-data and error states.

Tourism is not intended to replace emergency services, official booking providers, government advisories, medical professionals, or human judgement. It is a decision-support and travel-organization application.

---

## Objectives

### Primary objectives

- Reduce repetitive travel preparation work.
- Improve access to trip-critical information.
- Encourage timely and safer travel decisions.
- Reduce missed documents, untracked spending and forgotten checks.
- Keep travellers informed without enabling surprise automation.
- Provide one consistent interface across the complete journey lifecycle.

### Engineering objectives

- Keep third-party secrets out of the APK wherever server-side proxying is supported.
- Separate UI, state, repositories, domain engines and platform services.
- Use owner-scoped Firebase data rules.
- Preserve useful offline and cache-first behavior.
- Avoid invented prices, confirmations, coordinates, opening hours, battery levels, or safety claims.
- Validate every release through static analysis, tests and signed-APK verification.

---

## Target users

Tourism is useful for:

- Solo travellers who want preparation and safety support.
- Families managing bookings, documents and shared plans.
- Road-trip users tracking fuel, service readiness and trip expenses.
- Students and budget travellers monitoring daily spending.
- Domestic and international tourists storing travel references.
- Travellers visiting unfamiliar places who need nearby essentials and emergency services.
- Users who prefer reminders and guided workflows over manual travel checklists.

---

## Application content and user journey

### 1. Onboarding and authentication

Users can sign in through configured Firebase Authentication methods. Profile preferences, emergency contacts and travel settings are associated with the authenticated account.

### 2. Home dashboard

The home screen acts as the journey command center. It surfaces the current location, weather, active trip, nearby places, safety state, quick actions, Travel Automation, Travel Autopilot, Booking Hub, Expense Guard, document vault and other tools.

### 3. Discovery and planning

Users can explore places, search by category, inspect place details, generate or edit an itinerary, and save a trip. The active trip then becomes the shared context for automation, expenses, documents, intelligence and navigation.

### 4. Preparation

Before departure, users can review documents, bookings, weather, packing, vehicle readiness and provider information. Automation agents can schedule these checks from the actual trip date.

### 5. During the journey

The traveller can use live maps, route guidance, nearby essentials, daily itinerary prompts, expense logging, budget status, safety check-ins, emergency tools and context-aware recommendations.

### 6. Trip closure

After the journey, Tourism can remind the user to finish expenses, retain useful booking references, review documents, and clean up journey records.

---

## Major features

### Travel planning and intelligence

- Create and save multi-day trips.
- AI-assisted itinerary generation using configured providers.
- Deterministic robustness analysis and contradiction detection.
- What-if simulation for delay, closure, reduced budget and reduced time.
- Constraint solving for must-visit places, maximum daily load and deadlines.
- Auto-recovery for a delayed itinerary.
- Decision replay for changes the user actually applies.
- Group preference conflict resolution.
- Honest handling of unknown travel or visit duration.

### Travel Autopilot

- Works with current location and available time, even without a full itinerary.
- Ranks nearby options using distance, route time, opening data when available and user interests.
- Creates a practical multi-stop plan for the available window.
- Supports arrival detection, breaks, re-planning and trip recovery.
- Persists the current session locally per user.
- Labels unknown prices instead of inventing them.

### Maps, search and navigation

- Live GPS position with permission handling.
- MapTiler and OpenStreetMap-based map rendering.
- Locality-first place ranking and canonical coordinate selection.
- Nearby attraction and essential-service discovery.
- OSRM route distance and ETA where available.
- Route polyline, destination markers and multi-stop routing.
- 2D map and MapLibre-powered 3D navigation mode.
- Heading-up follow camera and speed-aware trip display.
- Clear fallback labeling when only straight-line information is available.

### Safety and emergency support

- Safety zones and location-aware risk display.
- Nearby hospital, police, fire and medical service discovery.
- One-tap SOS workflow with actual device coordinates.
- Emergency events with active and resolved states.
- Emergency-contact SMS and WhatsApp hand-off where supported.
- Opt-in offline emergency SMS through Android `SmsManager`.
- Live-location sharing with visible status and stop control.
- Power-off last-known-location fallback with explicit limitations.
- No claim that authorities were contacted unless an external system confirms it.

### Digital Emergency ID

- Private emergency profile associated with a random verification token.
- QR code contains the verification token, not raw personal details.
- Camera scan and manual verification paths.
- Active and revoked states.
- Public verification is token-addressed and collection listing is denied.

### Incident reporting

- Description, location, image and video support.
- Media type and size validation.
- Configured AI-based category and severity assistance.
- Firestore history and admin review.
- Human-readable error states when upload or analysis fails.

### Weather

- Current conditions and forecast through the configured weather backend.
- Practical travel guidance and retry states.
- Weather information is treated as advisory and may change rapidly.

### Travel Booking Hub

- Ride, flight, train, bus, hotel, car-rental and activity categories.
- Official provider app/site hand-off.
- Pickup and destination forwarding where a provider publicly supports it.
- Booking and payment remain with the official provider.
- No fake live fares, seat inventory, ratings or confirmations.
- Provider references can be saved manually after returning to Tourism.

### Travel Document and Booking Vault

- Passport, visa, ID, ticket, hotel, insurance and other travel-document types.
- PDF and supported-image uploads.
- Trip linking without duplicating trip data.
- Search and upcoming-booking timeline.
- Expiry states computed from the real current date.
- Expiry reminders through local notifications.
- Owner-only Firestore and Firebase Storage access rules.
- No pretend OCR: users verify and enter document details themselves.

### Travel Expense Guard

- Fast expense entry with optional receipt, merchant, notes and trip link.
- Offline-first cache and idempotent synchronization queue.
- Per-currency totals; unsupported currency conversion is never invented.
- Daily budget thresholds and deterministic spending insights.
- Search, filters, sorting, edit and delete.
- Equal or custom expense splitting with sum validation.
- Sync status reflects the real persistence result.

### Budget and wallet

- Trip budget setup.
- Expense recording and editing.
- Remaining-budget views based on entered data.
- Local trip-level spending support.

### Vehicle tools

- Fuel fill-up records.
- Mileage and cost tracking.
- Service reminders.
- Trip fuel estimation based on user-provided vehicle inputs.
- Pre-trip vehicle-readiness automation.

### Nearby essentials

- Locate useful services such as pharmacies, hospitals, ATMs, fuel and food.
- Uses real location and mapped place data where available.
- Provides distance/context rather than guaranteeing inventory or service availability.

### Eco activity

- Walk and cycle session tracking.
- Distance-based points and badges.
- Firestore persistence for the user’s activity history.
- No blockchain claims or artificial environmental measurements.

### Payment Guardian

- Helps users check payment context and provider hand-offs.
- Encourages verification before leaving the trusted provider flow.
- Does not request or store banking passwords, card PINs or OTPs.

### Notifications and administration

- Per-user notification history and read state.
- Local Android safety and automation notifications.
- Role-gated admin tools for incidents, safety zones and SOS records.
- Server-side rules enforce authorization independently of UI visibility.

---

## Travel Automation Center

The Travel Automation Center contains **15 real, opt-in notification automations**. Schedules are generated from the active trip’s actual start date and duration.

| Phase | Automation | Purpose |
| --- | --- | --- |
| Before trip | Smart packing trigger | Starts a packing check two evenings before departure. |
| Before trip | Document readiness | Prompts a passport, ID, ticket, insurance and vault review. |
| Before trip | Booking confirmation audit | Reminds the user to verify official confirmations and references. |
| Before trip | Weather re-check | Schedules a final weather review before travel. |
| Before trip | Vehicle readiness | Prompts fuel/charge, tyre, licence and emergency-kit checks. |
| Before trip | Departure morning brief | Surfaces route, weather, booking and document checks. |
| During trip | Daily itinerary brief | Provides a planning prompt on each trip morning. |
| During trip | Stay check-in assistant | Prompts hotel address, accepted ID and confirmation readiness. |
| During trip | Nearby essentials check | Reminds the user to identify nearby pharmacy, water, ATM and transport. |
| During trip | Hydration rhythm | Schedules three lightweight hydration prompts per trip day. |
| During trip | Daily budget pulse | Prompts an evening expense and budget review. |
| During trip | Daylight return guard | Prompts a return-route, battery and safety check before evening. |
| During trip | Night safety check-in | Reminds the traveller to verify SOS contact and safe-route readiness. |
| During trip | Photo and document backup | Prompts backup of important trip media and receipts. |
| After trip | Trip closure assistant | Prompts final expenses, references and document cleanup. |

### Automation rules

- Every automation is **off until the user enables it**.
- Tourism requests notification permission through Android.
- An automation is marked enabled only if at least one notification was accepted for scheduling.
- Missing active trip, permission denial and “no future event” are separate outcomes.
- Past notification times are not scheduled.
- Repeating recipes are limited to the first 14 trip days to avoid excessive notification creation.
- Enabled recipes and accepted schedule timestamps are stored per user.
- Disabling a recipe cancels its scheduled notifications.
- Automations are reminders and decision support; they do not silently book, pay, contact providers, or send personal data.

---

## Technical approach

### Frontend

- **Flutter and Dart** for a single Android application codebase.
- **Material 3** with Tourism’s Aurora visual system.
- **GoRouter** for declarative navigation and deep-link-ready routes.
- A lightweight application container for shared services and repositories.
- Feature-oriented folders to keep domain responsibilities separated.

### Backend and persistence

- **Firebase Authentication** for user identity.
- **Cloud Firestore** for profiles, trips, incidents, expenses, bookings and user records.
- **Firebase Storage** for controlled user media and documents.
- **Cloud Functions** as a secure gateway for configured AI, weather and Google service integrations.
- **SharedPreferences** for suitable device-local state such as automation choices and active local sessions.

### Maps and location

- `geolocator` for permission-aware device position.
- `flutter_map`, MapTiler and OpenStreetMap sources for 2D mapping.
- `maplibre_gl` for supported 3D map presentation.
- OSRM and configured route services for road distance, ETA and geometry.
- Haversine distance only where a straight-line calculation is explicitly appropriate.

### Notifications and automation

- `flutter_local_notifications` for Android notification channels and scheduled reminders.
- `timezone` for local-time scheduling.
- A pure automation engine converts trip facts into future events.
- A separate service handles permission, scheduling, cancellation and persistence.
- The UI displays service results rather than assuming that scheduling succeeded.

### AI strategy

Configured AI providers can support conversation, itinerary generation and incident categorization. Provider keys may be supplied through secure backend configuration or build-time configuration where explicitly supported.

Deterministic logic is preferred for:

- Budget arithmetic.
- Date and expiry calculations.
- Route and distance constraints.
- Automation schedules.
- Expense totals.
- Feasibility checks.
- Rule-based ranking and fallback behavior.

This separation reduces hallucination risk and makes important calculations testable.

### Reliability and performance

- Cache-first loading where stale-but-useful information is safer than a blank screen.
- Bounded Firestore listeners.
- Parallel independent requests.
- Request deduplication where applicable.
- Stable identifiers for retryable writes.
- Explicit loading, empty, offline, permission-denied and failed states.
- No blocking network work on the UI thread.

---

## Architecture and repository structure

```text
android/                    Native Android configuration and integrations
assets/images/              Application images and brand assets
functions/                  Firebase Cloud Functions backend
lib/
  main.dart                 Application entry point
  app.dart                  Root application and routing integration
  app_shell.dart            Main navigation shell and global trip/safety UI
  core/                     Theme, configuration, services, state and utilities
  data/models/              Typed application models
  data/repositories/        Firestore and remote-data boundaries
  features/                 Feature-oriented UI and domain modules
    automation/             Travel Automation engine, service and screen
    autopilot/              Location/time-based journey recommendations
    booking/                Official booking-provider hand-offs
    expenses/               Offline-first expense tracking
    intelligence/           Trip analysis and decision tools
    safety/                 Safety zones, SOS and emergency functions
    vault/                  Travel documents and booking records
    ...                     Maps, weather, profile, vehicle, wallet and more
scripts/                    Deployment and maintenance helpers
test/                       Unit and widget tests
.github/workflows/          Verify and release APK workflows
firestore.rules             Firestore authorization and validation
storage.rules               Firebase Storage authorization and limits
firebase.json               Firebase deployment manifest
```

### Data design

Important records are scoped either by user ownership or by a controlled public/admin role. Representative paths include:

```text
users/{uid}
profiles/{uid}
users/{uid}/itineraries/{tripId}
users/{uid}/travelDocuments/{documentId}
users/{uid}/expenses/{expenseId}
users/{uid}/bookingRefs/{referenceId}
users/{uid}/notifications/{notificationId}
safetyZones/{zoneId}
incidents/{incidentId}
emergencyEvents/{eventId}
digitalIds/{id}
digitalIdPublic/{verificationToken}
ecoScores/{uid}
```

The security rules in this repository are the source of truth for access—not the screen visibility alone.

---

## Security, privacy and responsible design

### Security controls

- Firebase rules validate ownership and permitted field changes.
- Admin checks are enforced server-side.
- Storage paths restrict owner, content type and file size.
- Backend endpoints validate types, ranges and string lengths.
- Rate limiting protects configured proxy endpoints.
- Release builds use a permanent signing key in CI.
- CI checks analysis, tests, APK signing, package metadata and installability.

### Privacy controls

- Permission is requested before protected device capabilities are used.
- Automation is opt-in per recipe.
- Live location sharing remains visible and can be stopped.
- Digital Emergency ID QR codes contain a verification token rather than raw personal data.
- Document content, OTPs, card PINs and banking passwords must not be logged.
- Expense currencies are not converted without a real exchange-rate source.
- Device battery status must come from the device, never a hardcoded or manually selected percentage.

### Honest-product rules

Tourism must never:

- Fabricate coordinates, fares, booking status, availability, ratings or confirmations.
- Present an estimate as a live provider price.
- Claim that police, emergency services or a contact were notified without confirmation.
- Claim continuous background monitoring when the operating system or app lifecycle does not provide it.
- Claim OCR, danger detection, unfamiliar-area awareness or automatic authority dispatch when those capabilities are not actually implemented.
- Silently enable all travel automations.

---

## Feasibility

### Technical feasibility

The application is technically feasible because its main capabilities use mature Android and Flutter interfaces:

- GPS and permissions are provided by Android and accessed through established Flutter plugins.
- Local reminders are implemented with Android notification scheduling.
- Authentication, structured cloud storage and media storage are supported by Firebase.
- Map rendering and routing use documented mapping and routing technologies.
- Provider hand-offs rely on public app links or official websites rather than private scraping.
- Pure Dart engines make itinerary checks and automation scheduling testable without the UI.

The project already has CI workflows that run analysis, tests and signed release builds, reducing release risk.

### Operational feasibility

A small team can operate Tourism because:

- Flutter reduces duplicate platform code.
- Firebase provides managed authentication and data infrastructure.
- Feature modules can be developed and tested independently.
- Secrets are configured centrally.
- APK production is automated through GitHub Actions.

Operational work is still required for API quotas, Firebase billing, provider policy changes, security-rule deployment, monitoring and support.

### Economic feasibility

A prototype or small deployment can use free or low-cost service tiers. Cost increases with:

- Map and place requests.
- Cloud Function invocations.
- Firestore reads and writes.
- Media and document storage.
- AI inference usage.
- Weather API usage.

Cost controls should include endpoint quotas, caching, rate limits, bounded listeners, compressed media and provider-specific usage monitoring.

### Legal and policy feasibility

The product remains more viable when it:

- Uses public provider hand-offs instead of scraping.
- Respects map attribution requirements.
- Obtains explicit location and notification consent.
- Publishes a privacy policy before public production use.
- Avoids claiming to be an emergency-response service.
- Reviews local data-protection, telecom, payment and travel regulations before commercial deployment.

---

## Viability

### User viability

Tourism offers value by consolidating repetitive travel tasks. Its strongest differentiator is not a single map or chatbot; it is the connection between a real trip and useful actions across preparation, movement, safety, budget and closure.

### Product viability

Potential product directions include:

- Free personal travel organizer.
- Premium offline packs and advanced automation.
- Family or group journey coordination.
- White-label tools for hotels, colleges, tour operators or corporate travel teams.
- Partner integrations using official APIs and transparent referral models.
- Optional paid cloud storage tiers.

Core safety functions should remain accessible and should not be designed around manipulative urgency.

### Business viability

Possible revenue models:

- Freemium subscription for advanced planning and automation.
- Official affiliate partnerships for booking hand-offs.
- Business subscriptions for managed group travel.
- Optional premium AI quota.
- Privacy-respecting sponsored listings, clearly labeled as sponsored.

A production business model must not sell sensitive location, emergency, document or identity data.

### Sustainability of the implementation

- Modular features reduce maintenance coupling.
- Provider adapters isolate external hand-off changes.
- Backend proxies can change upstream services without redesigning every screen.
- Tests protect deterministic engines and critical calculations.
- Explicit limitations reduce support issues caused by misleading promises.

---

## Impact and benefits

### Traveller benefits

- Fewer forgotten pre-trip tasks.
- Faster access to documents and references.
- Better awareness of daily spending.
- More realistic itinerary decisions.
- Easier discovery of nearby services.
- Clearer emergency actions and contact options.
- Reduced context switching between unrelated applications.
- Better trip closure and record organization.

### Safety benefits

- Emergency information is easier to reach.
- Location age and accuracy can be communicated honestly.
- Return, battery and check-in reminders encourage preventive action.
- Official limitations reduce false confidence.
- Token-based emergency identity verification limits unnecessary data exposure.

### Social and environmental benefits

- Accessibility for budget-conscious and first-time travellers.
- Walk/cycle activity tracking can encourage lower-impact local movement.
- Better planning may reduce unnecessary detours and repeated trips.
- Nearby discovery can help travellers find local businesses and services.

### Engineering and educational benefits

The project demonstrates:

- Flutter application architecture.
- Firebase authorization and secure media paths.
- Mobile permission design.
- Real-time location and mapping.
- Offline-first synchronization.
- Deterministic decision engines.
- Responsible AI boundaries.
- Automated Android release validation.

---

## Research basis

Tourism’s design is informed by established travel-risk, mobile-security, accessibility and sustainable-tourism guidance.

### 1. Travel preparation and risk reduction

Government and international travel guidance consistently recommends reviewing destination information, documents, insurance, local conditions and emergency contacts before departure. Tourism translates those recurring preparation tasks into user-controlled trip reminders.

### 2. Timely, actionable notifications

A notification is useful when it is relevant, expected and actionable. The automation design therefore uses the selected trip’s dates, avoids past events, limits repetitive schedules and keeps every recipe individually controlled.

### 3. Privacy by design

Location, identity documents and emergency contacts are sensitive. Tourism applies data minimization, owner-scoped access, visible sharing state and permission-aware behavior. QR verification uses a random token instead of embedding raw identity information.

### 4. Human-centered automation

Automation should support decisions rather than conceal them. Tourism schedules reminders but does not silently purchase tickets, make payments, upload private media, contact authorities, or enable all agents. Critical actions remain under user control.

### 5. Responsible AI

AI output is not treated as an authoritative source for emergency response, price, route feasibility or financial arithmetic. Deterministic calculations and official providers are used for facts that require verification, while AI is used for assistance where configured.

### 6. Sustainable travel

Sustainable tourism guidance emphasizes informed visitor behavior, respect for local environments and efficient resource use. Tourism’s eco activity and practical routing tools support awareness, while avoiding unsupported claims about exact carbon savings.

---

## References

The following official or primary sources are useful for the project’s design and implementation:

1. **UN Tourism — Sustainable Development**
   https://www.unwto.org/sustainable-development

2. **World Health Organization — International travel and health**
   https://www.who.int/health-topics/travel-and-health

3. **Government of India, Ministry of Tourism**
   https://tourism.gov.in/

4. **National Disaster Management Authority, India**
   https://ndma.gov.in/

5. **CERT-In — Cybersecurity guidance and advisories**
   https://www.cert-in.org.in/

6. **OWASP Mobile Application Security**
   https://mas.owasp.org/

7. **Android Developers — Permissions**
   https://developer.android.com/guide/topics/permissions/overview

8. **Android Developers — Notifications**
   https://developer.android.com/develop/ui/views/notifications

9. **Android Developers — Location**
   https://developer.android.com/develop/sensors-and-location/location

10. **Flutter documentation**
    https://docs.flutter.dev/

11. **Firebase documentation**
    https://firebase.google.com/docs

12. **Cloud Firestore Security Rules**
    https://firebase.google.com/docs/firestore/security/get-started

13. **OpenStreetMap copyright and attribution**
    https://www.openstreetmap.org/copyright

14. **OSRM API documentation**
    https://project-osrm.org/docs/v5.24.0/api/

15. **MapLibre documentation**
    https://maplibre.org/maplibre-gl-js/docs/

16. **Google Maps Platform documentation**
    https://developers.google.com/maps/documentation

17. **OpenWeather API documentation**
    https://openweathermap.org/api

18. **NIST Privacy Framework**
    https://www.nist.gov/privacy-framework

19. **W3C Web Content Accessibility Guidelines**
    https://www.w3.org/WAI/standards-guidelines/wcag/

20. **Uber developer deep-link documentation**
    https://developer.uber.com/docs/riders/ride-requests/tutorials/deep-links/introduction

> References provide design and implementation guidance. They do not imply endorsement of Tourism by any listed organization.

---

## Setup and development

### Prerequisites

- Flutter stable compatible with the repository SDK constraint.
- Dart SDK `>=3.5.0 <5.0.0`.
- Android Studio and Android SDK.
- JDK 21 for the CI-compatible Android build environment.
- Firebase CLI for backend and rules deployment.
- An Android 7.0+ device or emulator.
- A Firebase project.

### Install dependencies

```bash
flutter pub get
```

### Firebase configuration

1. Create or select a Firebase project.
2. Add an Android application with package name `app.roamio.tourism`.
3. Enable the required authentication methods.
4. Create Firestore and Firebase Storage.
5. Configure `lib/firebase_options.dart` with the correct project values.
6. Register the signing certificate SHA-1/SHA-256 values required by Google Sign-In.
7. Configure the Google web client ID where required.
8. Deploy Firestore and Storage rules.

Useful scripts:

```bash
bash scripts/deploy-rules.sh
bash scripts/deploy-backend.sh
```

### Service configuration

Depending on the features being deployed, configure supported credentials as Firebase secrets, CI secrets or approved build-time definitions:

- AI provider credentials.
- OpenWeather key.
- Google server API key.
- MapTiler key.
- Google Sign-In web client ID.

**Never commit real secrets to source control.**

### Run locally

```bash
flutter run
```

### Useful quality commands

```bash
flutter analyze
flutter test
```

---

## Build and testing

### Local release build

```bash
flutter build apk --release --split-per-abi
flutter build apk --release
```

Generated files are normally placed under:

```text
build/app/outputs/flutter-apk/
```

### GitHub Actions

The repository contains:

- `.github/workflows/verify.yml` — dependency install, static analysis, tests and rules checks.
- `.github/workflows/build-apk.yml` — verification, signed release build, APK inspection and artifact preparation.

The release pipeline verifies APK signing and Android package metadata. Public release publication is intentionally controlled by workflow conditions; feature branches must not overwrite the public rolling release.

### APK selection

- `arm64-v8a`: most modern Android phones.
- `armeabi-v7a`: older 32-bit phones.
- `x86_64`: compatible emulators or uncommon x86 devices.
- `universal`: larger fallback APK containing multiple architectures.

An APK is an installable package. Do not extract it as if it were a normal ZIP archive.

---

## Important instructions

### For developers

1. Keep the user-visible brand name **Tourism**.
2. Do not commit API keys, service credentials, signing files, passwords, OTPs or personal records.
3. Do not weaken Firestore or Storage rules to solve a UI error.
4. Run `flutter analyze` and `flutter test` before release.
5. Test permission denied, GPS disabled, no network, expired trip and missing-data states.
6. Preserve canonical place coordinates after a user selects a search result.
7. Use official provider APIs or links; do not scrape private interfaces.
8. Label deterministic ride or travel prices as estimates unless an official live API supplies the fare.
9. Keep totals separated by currency unless a real exchange-rate service is configured.
10. Do not add manual or hardcoded device battery percentages.
11. Avoid logging coordinates, document numbers, contact numbers, booking references or tokens.
12. Update tests when changing scheduling, date, budget, route or security logic.

### For administrators

1. Deploy the repository’s Firestore and Storage rules before testing protected features.
2. Configure an admin role only for trusted accounts.
3. Restrict service keys by API, application, service account or infrastructure where supported.
4. Monitor Firebase, map, weather and AI quotas.
5. Review incident and emergency data according to a documented retention policy.
6. Publish privacy, consent, support and data-deletion information before production distribution.
7. Keep the Android release signing key secure and backed up.

### For testers and users

1. Grant only the permissions needed for the feature you choose to use.
2. Verify booking price, availability, status and payment in the official provider application or website.
3. Confirm emergency contacts and phone numbers before relying on SMS features.
4. Do not rely on Tourism as the only source during an emergency.
5. Use the local emergency number and official authorities when immediate help is required.
6. Treat route, weather, place, opening-hour and safety information as changeable.
7. Keep important original identity and travel documents available where legally required.
8. Automation agents send reminders; they do not complete the underlying task for you.
9. A “scheduled” automation depends on Android permission and operating-system delivery behavior.
10. Power-off, low-signal and background behavior varies by manufacturer and cannot be guaranteed.

### Before a production release

- [ ] Correct Firebase project configuration is installed.
- [ ] Authentication and OAuth fingerprints are verified.
- [ ] Firestore and Storage rules are deployed and tested.
- [ ] Required backend secrets are configured.
- [ ] API restrictions and quotas are reviewed.
- [ ] Privacy policy and terms are published.
- [ ] Support and account/data deletion processes are documented.
- [ ] Notification, location, SMS, camera and media permissions are tested.
- [ ] Analyze and all tests pass.
- [ ] Release APK is signed with the permanent certificate.
- [ ] APK is installed and smoke-tested on a real Android device.
- [ ] Safety wording and emergency limitations are reviewed.

---

## Known limitations

- Tourism cannot guarantee emergency-message delivery, GPS availability, mobile network coverage or authority response.
- Android background execution and notification timing can vary by manufacturer, battery optimization and permission state.
- Weather, routes, place details and opening hours depend on external data sources and may be delayed or incomplete.
- Provider prices and availability are not live unless an official partner API is configured.
- Some provider apps do not expose public deep links for every field, so a user may need to re-enter information.
- The app does not silently send WhatsApp messages; WhatsApp requires user action in its supported hand-off flow.
- Uploaded travel documents are not automatically verified as authentic.
- OCR is not claimed where it is not implemented.
- Safety-zone awareness is informational and cannot guarantee that an area is safe or unsafe.
- Eco tracking does not claim an exact carbon reduction without a verified methodology and input data.

---

## Future scope

Potential future improvements include:

- Official airline, rail, bus, hotel and ride partner APIs.
- Verified live fare and availability comparison.
- Encrypted offline travel-document access with device authentication.
- End-to-end family trip coordination and consent controls.
- Wear OS safety companion.
- More offline maps and emergency content.
- Accessibility audits and additional language support.
- User-configurable automation timing and dependencies.
- Calendar integration with explicit consent.
- Verified exchange rates and travel-budget forecasting.
- Privacy-preserving analytics and crash diagnostics.
- Formal security review and penetration testing.

Every future feature should continue to follow Tourism’s core rule: **do not present a capability, action, or data source as real until it is genuinely connected and verifiable.**

---

## License

Proprietary — all rights reserved.

Third-party packages, map data, APIs and services remain subject to their respective licenses, terms, attribution requirements and acceptable-use policies.
