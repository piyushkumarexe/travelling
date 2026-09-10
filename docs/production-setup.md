# Tourism production configuration

Application code never reads third-party server secrets directly. Firebase
Functions consume server keys from Google Secret Manager; GitHub Actions only
receives encrypted repository secrets at runtime.

## GitHub Actions secrets

In **Repository settings → Secrets and variables → Actions**, create:

| Secret | Purpose |
|---|---|
| `MAPTILER_API_KEY` | Public/restricted MapTiler client token injected at APK build time |
| `ANDROID_KEYSTORE_BASE64` | Base64 of the permanent release `.jks` file |
| `ANDROID_KEYSTORE_PASSWORD` | Permanent keystore password |
| `ANDROID_KEY_ALIAS` | Permanent signing-key alias |
| `ANDROID_KEY_PASSWORD` | Permanent signing-key password |
| `FIREBASE_SERVICE_ACCOUNT_JSON` | Firebase deployment service-account JSON |
| `NVIDIA_API_KEY` | Tourism AI upstream secret |
| `OPENWEATHER_API_KEY` | Current weather and forecast upstream secret |
| `GOOGLE_MAPS_API_KEY` | Places, hotel discovery, geocoding and traffic-aware routes |

Never commit the keystore, `android/key.properties`, service-account JSON or
secret values. Keep an offline encrypted backup of the permanent keystore and
passwords. Losing the private key prevents future APK updates.

Encode the keystore without line wrapping:

```bash
base64 -w 0 tourism-upload.jks
```

On macOS:

```bash
base64 < tourism-upload.jks | tr -d '\n'
```

## Permissions required by Arena's GitHub connection

The GitHub App currently has repository-content write access but not workflow
write access. To publish `.github/workflows/build-apk.yml`, reconnect/install
the Arena GitHub App with **Workflows: Read and write** permission for this
repository. No Personal Access Token should be placed in the repository.

## Firebase deployment identity

`FIREBASE_SERVICE_ACCOUNT_JSON` must belong to project `tourism-39425`. Grant
only the deployment permissions needed by the workflow:

- Cloud Functions Admin
- Service Account User (on the Functions runtime service account)
- Secret Manager Admin
- Firebase Rules Admin
- Cloud Build Editor
- Artifact Registry Writer

The workflow writes the Actions secret values to Firebase Secret Manager and
then deploys Functions, Firestore rules and Storage rules. Client APKs never
receive NVIDIA, OpenWeather or Google server keys.

## Firebase Authentication

Enable these providers in **Firebase Console → Authentication → Sign-in
method**:

- Google
- Email/Password

Register SHA-1 and SHA-256 from the **permanent release certificate**, not a
CI debug certificate. The first permanent-key APK may require uninstalling an
older debug-signed build. Every later APK signed with the same key and a higher
version code installs as an in-place update.

## Provider restrictions

- Restrict the MapTiler token by allowed application/domain and quota where
  supported. A raster-tile client token is visible to the device by design.
- Restrict the Google server key to the Places API, Routes API and Geocoding
  API; keep it server-side.
- Configure billing/quota alerts for all upstream services.
