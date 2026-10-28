# Tourism APK install guide (Hindi + English)

## 1. Sahi APK aur source chunein

Signed production APKs are produced only by a successful **Verify and build
Tourism APKs → Build protected signed release APKs** job on protected `main`.
Open that workflow run in GitHub, scroll to **Artifacts**, and download
`tourism-signed-release-apks`. Development-branch `tourism-debug-apk` artifacts
are for testing, not production updates.

GitHub wraps an artifact in one ZIP. Extract that ZIP **once**; inside are raw
`.apk` files and `SHA256SUMS.txt`. The APK itself must not be extracted.

| File | Device |
| --- | --- |
| `tourism-arm64-v8a.apk` | Most phones made in 2017 or later; try this first |
| `tourism-armeabi-v7a.apk` | Older 32-bit phones only |
| `tourism-x86_64.apk` | Compatible emulators / uncommon x86 devices |
| `tourism-universal.apk` | Larger fallback for all supported architectures |

Requirements start at **Android 6.0 (API 23)**. A dependency's merged manifest
can raise the effective minimum, so check the APK/workflow metadata for the
specific build.

## 2. Update bina data delete kiye

**Pehle uninstall mat karein.** Uninstalling can delete Tourism's offline
records, settings, cached documents and other app-local data.

1. Use the same artifact type as the previous install (for example, arm64 to
   arm64) and an equal/newer version.
2. Confirm the APK came from the expected repository/workflow and compare its
   SHA-256 with `SHA256SUMS.txt` where possible.
3. Tap the `.apk`, allow **Install unknown apps** only for the browser/file
   manager you trust, then choose **Install**/**Update**.
4. If Android reports a signature mismatch, stop. Do not delete data or install
   an unknown replacement. Contact the maintainer; an uninstall is a last
   resort only after an explicit backup/migration decision.

Split APKs can have different version codes. Repeatedly switching between
split and universal packages can look like a downgrade. Staying on one file
type avoids that problem.

## 3. Error-wise fixes

### “Could not extract file”

You downloaded a GitHub **artifact ZIP**, not a raw APK. Extract that ZIP once,
then tap the extracted `.apk`. Do not open the APK itself in ZArchiver or
another archive tool.

### “There was a problem parsing the package”

- Download again over reliable Wi-Fi and confirm the file size/hash.
- Check that the phone meets this build's Android/API requirement.
- Use arm64 on a typical phone; use universal if the device architecture is
  uncertain.
- Do not install a partially downloaded or renamed archive as an APK.

### “App not installed”

- Check available storage and whether the new version code is older.
- Use the same APK architecture/type as the previous install.
- A signing-certificate mismatch requires maintainer guidance. Uninstalling
  different/old signed builds can erase local data; it is not the default fix.

### Play Protect / managed-device warning

Only proceed when the repository, workflow run, signer and hash are expected.
A work-profile or device-admin policy may require your IT administrator.
Tourism is not distributed through this workflow as a Play Store listing.

## 4. Report karein

Send the maintainer:

1. The exact error screenshot.
2. Phone model and Android version.
3. APK filename and SHA-256.
4. GitHub workflow-run URL and whether this was a new install or an update.

Never send passwords, Firebase tokens, private documents, SOS contact numbers,
or signing credentials with the report.
