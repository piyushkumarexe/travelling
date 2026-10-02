YatraWise — permanent release-signing key (maintainer notes)
=============================================================

WHY THIS FILE EXISTS
--------------------
Every "Latest Tourism APK" must be signed with ONE permanent certificate.
If a release ever ships with a different (e.g. throwaway debug) key, users
see "App not installed" when updating, because Android refuses to update an
app with a mismatched signature. The CI workflow FAILS the build if the
key is missing, so this can never happen silently.

HOW IT IS WIRED (no secrets in this file — never commit the keystore!)
----------------------------------------------------------------------
1. The PKCS#12 upload keystore lives ONLY in the GitHub Actions secret
   named exactly:

       ANDROID_KEYSTORE_BASE64

   (Settings -> Secrets and variables -> Actions -> New repository secret.)
   Its value is the base64 of the .p12 file (single line, no wrapping).

2. CI decodes it to android/app/upload-keystore.p12 at build time and
   android/app/build.gradle.kts signs the release buildTypes with it.
   Default passwords/alias (override via keystore.properties or env if you
   rotate — but read the ROTATION warning first):

       storePassword = YatraWise-Upload-2026
       keyAlias      = upload
       keyPassword   = YatraWise-Upload-2026

3. The CI "installability gate" compares every published APK's signing
   certificate against this keystore and refuses to publish on mismatch.
   The release notes always print the APK's SHA-256 signature so anyone
   can confirm which key signed a build.

CREATING THE SECRET (first time / disaster recovery)
-----------------------------------------------------
Run on a trusted machine (NOT in CI, NOT in this repo):

    # 1. Generate a new upload key (valid ~25 years):
    keytool -genkeypair -v -storetype PKCS12 \
      -keystore upload-keystore.p12 -alias upload \
      -keyalg RSA -keysize 2048 -validity 9125 \
      -storepass 'YatraWise-Upload-2026' -keypass 'YatraWise-Upload-2026' \
      -dname 'CN=YatraWise Tourism, OU=Mobile, O=YatraWise, L=Lucknow, C=IN'

    # 2. Record the fingerprints (keep a copy in a password manager):
    keytool -list -v -keystore upload-keystore.p12 \
      -storepass 'YatraWise-Upload-2026' | grep -E 'Alias name|SHA1:|SHA256:'

    # 3. Export single-line base64 (Linux):
    base64 -w0 upload-keystore.p12
    # macOS:
    base64 -i upload-keystore.p12 | tr -d '\n'
    # Windows PowerShell:
    # [Convert]::ToBase64String([IO.File]::ReadAllBytes('upload-keystore.p12'))

    # 4. Paste the output as the ANDROID_KEYSTORE_BASE64 repo secret.

    # 5. DELETE upload-keystore.p12 from that machine (keep ONE offline
    #    backup, e.g. encrypted USB + password manager).

ROTATION WARNING
----------------
Changing this key = EVERY existing user must uninstall + reinstall (their
updates will fail with "App not installed"). Only rotate if the key is
compromised, and announce it loudly in the release notes.

BACKUP CHECKLIST (fill in, keep OFF GitHub — password manager / paper)
-----------------------------------------------------------------------
Write the filled-in copy to `android/RELEASE_SIGNING_BACKUP.txt` on your
own machine ONLY — that filename is gitignored on purpose, so it can
never be committed by accident.

[ ] Keystore .p12 backed up offline (encrypted): location _______________
[ ] storePassword / keyPassword stored:        location _______________
[ ] SHA-256 fingerprint recorded:              _________________________
[ ] Date / rotated-by:                         _________________________
