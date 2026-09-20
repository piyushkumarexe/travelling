# APK Install Guide & Troubleshooting (Hindi + English)

> Har release APK ko CI me `apksigner` + `aapt` (Android ka apna parser) +
> `zipalign` se verify karke hi publish kiya jaata hai. Isliye agar install
> fail ho raha hai to wajah 99% phone-side hai (adhuri download, purani
> install, ya setting) — neeche wala checklist follow karein.

## 1. Kaunsi file download karein? (Which file?)

Releases → **`apk-latest`** ("Latest Tourism APK") me ye files hoti hain:

| File | Kiske liye |
| --- | --- |
| `yatrawise-arm64-v8a.apk` | ✅ **Sabse common — 2017 ke baad ke lagbhag sabhi phones.** Pehle YEHI try karein (~50 MB). |
| `yatrawise-armeabi-v7a.apk` | Sirf bahut puraane 32-bit phones ke liye. |
| `yatrawise-x86_64.apk` | Emulator / rare x86 devices ke liye. |
| `yatrawise-universal.apk` | Fallback — har device par chalti hai, lekin sabse badi file (~120 MB). |
| `SHA256SUMS.txt` | Download verify karne ke hash. |

**Hamesha update ke liye WAHI file dobara download karein** jo pehli baar ki
thi. File badalne par Android use "downgrade" samajh kar "App not
installed" bol deta hai (har file ka versionCode alag hota hai) — ek
apvaad: **universal → split** (jaise universal → arm64) bina uninstall ke
upgrade ho jaata hai. Baaki har switch me pehle purana app uninstall
karein, phir nayi file fresh install karein.

Requirements: **Android 7.0+** (minSdk 24) aur ~300 MB free space.

## 2. Install kaise karein (steps)

1. Phone me purana "Tourism" app ho to use **uninstall** kar dein
   (Settings → Apps → Tourism → Uninstall). Ek baar ka kaam hai.
2. **WiFi par** sahi APK download karein (mobile data par badi file
   beech me toot jaati hai).
3. File manager me APK par tap karein.
4. **"Install unknown apps" → Allow** karein (browser/file-manager ke liye).
5. **Install** dabayein.

## 3. Error-wise fix

### "There was a problem parsing the package" (Parse error)

Matlab aam taur par: **file adhuri/corrupt download hui hai.** APK server
par sahi hai (CI gate se verified), phone tak poori nahi pahunchi.

1. File **delete** karke **WiFi par dobara download** karein.
2. Download poori hui ya nahi — **size match** karein: release notes me har
   file ka size likha hota hai.
3. Pakka verify karna ho to **SHA-256** match karein: Play Store se koi
   "Hash Checker" app lein, APK ka SHA-256 nikaal kar release ke
   `SHA256SUMS.txt` se milayein. Ek character bhi alag = dobara download.
4. Browser badal kar dekhein (Chrome → Firefox).
5. Phone ka Android version **7.0 ya upar** hona chahiye
   (Settings → About phone). Android 6.x par ye APK install nahi hogi
   (Flutter ki minSdk 24 hai) — us case me naya Android phone chahiye.

### "App not installed" (bina wajah)

1. **Purana version uninstall** karke fresh install karein — sabse common fix.
   (Puraane debug-signed build ke upar naya permanent-key build install
   nahi hota.)
2. Wahi APK file use karein jo pehle install thi (arm64 ↔ universal
   adla-badli me behtar hai uninstall + fresh install; sirf
   universal → split bina uninstall ke chalta hai).
3. Free space banayein (kam se kam 500 MB free).
4. Phone **restart** karke dobara try karein.

### "Blocked by Play Protect" / "Unknown apps"

1. Install ke waqt **"Install anyway"** chunein (ye hamari apni signed
   release hai, Play Store listing nahi hai isliye warning aati hai).
2. Ya: Settings → Security → **Install unknown apps** → apne browser ko Allow.
3. Work-profile / company-managed phone ho to IT policy rok sakti hai —
   personal profile me try karein.

### Download hi complete nahi hota

1. **arm64 wali chhoti APK** (~50 MB) use karein, universal (~120 MB) nahi.
2. WiFi par karein, battery-saver / data-saver off rakhein.
3. GitHub release page se seedha download karein
   (`.../releases/download/apk-latest/yatrawise-arm64-v8a.apk`),
   WhatsApp/Drive forward ki hui file par bharosa na karein.

## 4. Ab bhi na ho? (Report karein)

Maintainer ko ye 4 cheezein bhejein — bina inke diagnose nahi ho sakta:

1. Exact error message ka **screenshot**.
2. Kaunsi **file** download ki (poora naam) + uska **size** (bytes me).
3. Phone ka **Android version** (Settings → About phone).
4. Kya phone me Tourism **pehle se installed** hai/thi?

> English summary: every APK is verified installable in CI before publish.
> A parse error almost always means a truncated download — re-download on
> WiFi and compare size/SHA-256 with the release notes. "App not installed"
> over an old copy means a signature change or file switch — uninstall the
> old app once, then install fresh. Android 7.0+ required.
