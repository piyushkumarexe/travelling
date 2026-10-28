# Tourism release signing

The application ID remains `app.roamio.tourism` for installed-app and Firebase
compatibility. Release signing is independent of that identifier.

## Safety properties

- Debug APKs use the normal local debug certificate and need no release secrets.
- Release packaging fails explicitly unless a complete upload-key configuration
  exists. It never silently falls back to a debug certificate.
- No keystore, password, or private provider key is stored in this repository.
- CI builds signed releases only for protected `main` pushes/manual runs using
  the `production` GitHub environment. Development branches and pull requests
  build unsigned-source debug APKs only; they cannot publish a signed release.
- CI uploads artifacts only after build and signature checks succeed. It does
  not create or update GitHub Releases and does not deploy Firebase resources.

## Protected CI configuration

Create a GitHub Actions environment named **production** and protect it with
the repository's required-review/branch policies. Add these environment
secrets:

| Secret | Value |
| --- | --- |
| `ANDROID_KEYSTORE_BASE64` | Single-line base64 of the existing upload keystore |
| `ANDROID_KEYSTORE_PASSWORD` | Keystore password |
| `ANDROID_KEY_ALIAS` | Existing key alias |
| `ANDROID_KEY_PASSWORD` | Private-key password |

Use the existing certificate whenever possible. Changing the certificate can
prevent installed-app updates and can require Google/Firebase console changes.
Do not generate a replacement merely because a password is missing; recover
the password and encrypted backup through the project's normal secret process.

CI validates that the alias can be read, then compares every APK's SHA-256
signer digest with the configured keystore before uploading `tourism-*` files.

## Local release build

Keep secrets outside Git in `android/keystore.properties` (already ignored):

```properties
storeFile=/absolute/path/to/existing-upload-keystore.p12
storePassword=RECOVER_FROM_PASSWORD_MANAGER
keyAlias=EXISTING_ALIAS
keyPassword=RECOVER_FROM_PASSWORD_MANAGER
```

Alternatively set `ANDROID_KEYSTORE_FILE`, `ANDROID_KEYSTORE_PASSWORD`,
`ANDROID_KEY_ALIAS`, and `ANDROID_KEY_PASSWORD` in the shell environment.
Never paste the values into source, tickets, workflow logs, or chat.

## Creating a key only for a genuinely new app

For a new app with no installed users, generate a key on a trusted machine and
store unique passwords in a password manager. Do not use example passwords in
a real keystore:

```sh
keytool -genkeypair -v -storetype PKCS12 \
  -keystore /secure/path/upload-keystore.p12 -alias NEW_ALIAS \
  -keyalg RSA -keysize 3072 -validity 9125 \
  -dname 'CN=Tourism, OU=Mobile, O=Tourism, C=IN'
base64 -w0 /secure/path/upload-keystore.p12
```

Keep an encrypted offline backup and record the certificate fingerprints.
Rotating an established app's signing identity is a migration, not routine
maintenance; plan installed-app updates and console verification before doing
it.
