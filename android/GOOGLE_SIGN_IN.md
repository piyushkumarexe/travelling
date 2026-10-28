# Google Sign-In without changing the signing key

Google error 10 is an Android OAuth configuration error. It is not fixed by
rotating a keystore, changing a SHA fingerprint, changing the application ID,
or weakening Firebase Authentication.

Tourism keeps these compatibility-sensitive values unchanged:

- application ID: `app.roamio.tourism`;
- Firebase project: `tourism-39425`;
- the existing upload/debug signing keys and their certificates;
- the existing Firebase web client ID from the same project.

## Register the existing certificate

An administrator with access to the existing Firebase/Google Cloud project
must perform these console steps:

1. Determine the SHA-1 of the **existing certificate used by the exact APK
   being installed**. For a CI debug artifact, read the included
   `GOOGLE_SIGN_IN.txt`; no keystore password is needed. For another existing
   APK, use Android SDK `apksigner verify --print-certs path/to/app.apk`.
2. In Firebase Console, open project `tourism-39425` and its existing Android
   app `app.roamio.tourism`. Add that existing SHA-1 under the app's certificate
   fingerprints. Add the existing SHA-256 as well when the project uses
   features that require it. Do not create a replacement Android app or key.
3. In Google Cloud Console, open **APIs & Services → Credentials** for the same
   project. Verify that the Android OAuth client contains package name
   `app.roamio.tourism` and the same existing SHA-1. Firebase normally creates
   this client when the fingerprint is registered.
4. Keep **Authentication → Sign-in method → Google** enabled and publish the
   OAuth consent screen as appropriate for the app's testing/production state.
5. Reinstall the same APK and retry Google Sign-In. Changing the signing key or
   generating a new fingerprint is neither required nor recommended.

CI debug certificates can differ between fresh runners. Consequently, a
fingerprint registered for one debug artifact may not authorize another debug
artifact. For repeatable testing, use an existing consistently signed build
whose certificate is already registered, or register the exact fingerprint
included with each CI artifact. Protected release signing remains unchanged
and continues to use only the configured existing upload key.

This repository cannot verify console registration or a physical-device Google
sign-in by itself. Until those checks are performed, error 10 remains a manual
configuration item rather than a claimed code fix.
