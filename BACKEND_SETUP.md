# Tourism backend setup (Firebase)

The Flutter client calls authenticated Tourism Cloud Functions. NVIDIA,
OpenWeather, and Google server credentials are **backend-only**; Groq/Gemini/
generic provider fallback keys are not compiled into the APK.

The repository's configured Firebase project is `tourism-39425` and the default
function region is `us-central1`. Preserve those values for the existing app.
Deploy only with explicit project-owner authorization and after reviewing the
rules, functions, quotas, and data-migration plan.

## Prerequisites

- Node.js **24** (the declared Functions runtime) and npm.
- Firebase CLI access to the intended project.
- A Firebase project with Authentication, Firestore, and Storage enabled.
- Billing/quota configuration required by the selected Cloud Functions and
  Secret Manager features. Costs depend on usage; no zero-cost outcome is
  guaranteed. Configure budgets and alerts.
- Android/application configuration remains `app.roamio.tourism`.

## 1. Install and verify locally

```bash
cd functions
npm ci
npm run check
npm test
npm audit --audit-level=moderate
```

For Firestore/Storage behavior tests, use a local emulator project rather than
production data:

```bash
# From the repository root, with Java 21 installed:
functions/node_modules/.bin/firebase emulators:exec \
  --only firestore,storage --project demo-tourism \
  'cd functions && npm run test:rules'
```

The GitHub workflow runs these checks on Node 24 + JDK 21.

## 2. Configure backend secrets

Restrict each server key to only the required APIs and set provider quotas.
Dynamic server egress IPs mean an IP allowlist may not be practical; do not
substitute an Android-restricted client key for a server key.

```bash
npx firebase-tools functions:secrets:set GOOGLE_MAPS_API_KEY \
  --project tourism-39425
npx firebase-tools functions:secrets:set OPENWEATHER_API_KEY \
  --project tourism-39425
npx firebase-tools functions:secrets:set NVIDIA_API_KEY \
  --project tourism-39425
```

Expected server APIs include Places, Geocoding, and Routes as used by the
corresponding functions. `NVIDIA_API_KEY` is required for AI endpoints; when it
is absent, those endpoints return a safe “not configured” error rather than
using an embedded client key.

## 3. Review migration and security rules

Review `firestore.rules`, `storage.rules`, and `functions/test/rules.test.js`.
The policies are owner-scoped/default-deny, including Digital ID public token
verification, saved places, expenses/budgets, journey operations, incidents,
emergency events, and vault records.

Important Storage migration limitation: existing `firebasestorage.googleapis.com`
download URLs contain bearer tokens. Deploying owner rules does **not** revoke
tokens already issued. New app uploads store object paths and use authenticated
SDK reads, but an administrator must revoke/rotate legacy download tokens and
test old records before relying on the migration. Do not delete old records or
URLs until an owner-compatible migration is verified.

## 4. Authorized deployment

After tests and an explicit production-change approval, deploy only the intended
resources:

```bash
# Functions, including authenticated /deleteAccount:
npx firebase-tools deploy --only functions --project tourism-39425

# Rules and indexes, after emulator tests and migration review:
npx firebase-tools deploy \
  --only firestore:rules,firestore:indexes,storage \
  --project tourism-39425
```

`scripts/deploy-backend.sh` is an optional interactive maintainer helper; it is
not run by CI. Never run deployment scripts against an unintended project.

## 5. Verify without exposing credentials

A browser GET to a POST-only function can confirm only that a route exists
(`405 Method not allowed`); it does not prove authentication or provider health.
Use the signed-in app or an authorized test client with a valid, short-lived
Firebase ID token. Confirm:

- unauthenticated and cross-user requests are denied;
- AI/weather/place calls succeed only with configured server secrets;
- Digital ID public verification exposes only the minimal public record and
  revoked IDs fail verification;
- new Storage uploads work without generating public download URLs;
- account deletion removes owned data and is confirmed by the backend before
  the client reports success;
- logs contain no Authorization headers, provider responses, document contents,
  SOS phone numbers, or private keys.

Do not paste real ID tokens or provider keys into tickets, documentation, shell
history, or chat. If any provider key was previously embedded in source/APKs or
shared publicly, rotate it at the provider and review usage; removing it from a
new commit does not revoke the old credential.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| `401 unauthenticated` | Signed-in user, valid unexpired Firebase ID token, non-revoked session |
| `403`/Firestore permission denied | Deployed rules match the reviewed repository rules; document ownership and schema are correct |
| `503 ..._not_configured` | Required backend secret is attached to that function and the function was redeployed |
| Google `REQUEST_DENIED` | Required APIs, key restrictions, billing, and quota |
| AI unavailable | NVIDIA secret/model availability and upstream quota; no client fallback key is supported |
| Storage read denied | New object path and owner rules; legacy bearer token may still require separate revocation |
| Account deletion unconfirmed | Functions deployment, network, backend logs by safe request ID; retry/admin review rather than claiming success |
