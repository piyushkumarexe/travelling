# Tourism Backend Setup — Firebase Cloud Functions

> **Ek line me:** backend deploy hone ke baad app ko **Google ka asli data** milega —
> real hotels + ratings + photos + price level, directions, weather, aur AI sab
> server se. Abhi backend deploy nahi hai isliye app free fallback (Wikipedia/OSM)
> chala raha hai jo gaon-gaon ke naam dikha deta hai.

Ye repo already backend ke liye **poora ready** hai. Bas 4 cheezein karni hain:

1. Firebase project ko **Blaze (pay-as-you-go) plan** pe karo  ← sabse zaroori
2. **Firestore database** banao
3. **3 API keys** banao (Google Maps, OpenWeather, NVIDIA)
4. **Ek command** chalao → `bash scripts/deploy-backend.sh`

Project id: **`tourism-39425`** (already repo me set hai).

---

## Step 0 — Zaroori cheezein

- **Google account** jispe Firebase project `tourism-39425` ka access ho
  (jo account aapne app banane me use kiya tha).
- **PC/laptop** jisme Node.js ho (https://nodejs.org — LTS version install karo).
  Node hai to hi aage badho. Check: `node --version`

---

## Step 1 — Blaze plan (billing) ✅ MUST

Cloud Functions v2 + Secret Manager **free Spark plan pe nahi chalte**.
Blaze pe upgrade karna padega (bill tabhi aayega jab free limits cross ho — normal use me ₹0 hi rahega).

1. https://console.firebase.google.com → project **tourism-39425** kholo
2. Bottom-left ⚙️ gear → **Usage and billing**
3. **Modify plan** → **Blaze (Pay as you go)** select karo → Continue
4. Ek Google Cloud billing account link karo (card maangega, sirf verification ke liye — free limits me charge nahi hota)

> Bina Blaze ke `firebase deploy` fail hoga ("requires billing" error).

---

## Step 2 — Firestore database banao ✅ MUST

App ka **rate limiter** aur saara data (profile, SOS, eco, notifications)
Firestore me jata hai. Database na ho to functions 500 error denge.

1. Console → left menu **Build → Firestore Database**
2. **Create database** → **Production mode** → Next
3. Location: **asia-south1 (Mumbai)** choose karo (India ke liye fastest)
4. **Enable**

---

## Step 3 — 3 API keys banao

### (a) Google Maps API key — sabse important

1. https://console.cloud.google.com → upar project selector me **tourism-39425**
   (ya jo GCP project is Firebase se linked hai) select karo
2. **APIs & Services → Library** → ye 3 APIs **Enable** karo:
   - **Places API** (legacy wala)
   - **Geocoding API**
   - **Routes API**
3. **APIs & Services → Credentials → Create credentials → API key**
4. Naye key pe click karke **Restrict key**:
   - **API restrictions** → Restrict key → sirf ye 3 APIs select: `Places API`, `Geocoding API`, `Routes API`
   - **Application restrictions** → None (server key) — cloud functions ki IP dynamic hoti hai isliye IP restriction mat lagao
5. Key **copy** karo (yaad rakhna, Step 4 me paste karni hai)

### (b) OpenWeather API key (weather)

1. https://openweathermap.org/api → sign up (free)
2. Profile → **API keys** → key copy karo
3. Free plan me 1-2 ghante me activate hoti hai — turant chale to badi baat, warna thoda wait

### (c) NVIDIA API key (AI assistant) — optional, recommended

1. https://build.nvidia.com → sign in → account settings → **Get API key**
2. `nvapi-...` wali key copy karo (free tier hai)

> Note: AI abhi bhi chal raha hai (app me Groq/Gemini key compile hai), isliye
> ye optional hai. Par backend me daal do to sab ek jagah consolidated ho jayega.

---

## Step 4 — Deploy karo

### Tarika A — Ek command (recommended)

```bash
bash scripts/deploy-backend.sh
```

Ye script khud: npm install → login (browser khulega) → project select →
3 secrets puchhega (paste karo) → deploy.

### Tarika B — Manual (agar script nahi chal rahi)

```bash
# 1. login (browser me apna Google account)
npx firebase-tools login

# 2. project select
npx firebase-tools use tourism-39425

# 3. secrets (har ek ke baad key paste karo)
npx firebase-tools functions:secrets:set GOOGLE_MAPS_API_KEY
npx firebase-tools functions:secrets:set OPENWEATHER_API_KEY
npx firebase-tools functions:secrets:set NVIDIA_API_KEY

# 4. deploy (functions + firestore rules + storage rules)
npx firebase-tools deploy --project tourism-39425
```

---

## Step 5 — Verify karo (deploy success check)

Browser me ye URL kholo (POST nahi, sirf kholo):

```
https://us-central1-tourism-39425.cloudfunctions.net/placesSearch
```

- ❌ **"Page not found" / 404** → deploy nahi hua (abhi bhi wahi purana state)
- ✅ **"Method not allowed"** ya **"Provide a query"** jaise JSON error → **backend LIVE hai!**

Ab app ko **band karke dobara kholo** (ya 45 second wait karo — app ko
backend-up pata lagne me itna lagta hai). Explore ab Google ka real data
dikhayega: real hotel names, ⭐ ratings, photos, price level (₹₹₹), open-now,
directions — sab.

> APK **dubara banane ki zaroorat nahi** — backend URL pehle se app me hai.

---

## Troubleshooting

| Problem | Fix |
|---|---|
| `firebase deploy` → "requires billing / Billing account not configured" | Step 1 (Blaze) karo |
| Functions me 500 "Backend is missing the GOOGLE_MAPS_API_KEY" | Secret set nahi hua — Step 4 dubara, phir redeploy |
| Places "REQUEST_DENIED" | Google key me **Places API** enable nahi / API restriction galat — Step 3(a) |
| Directions "API_KEY_HTTP_REFERER_RESTRICTION" | Key pe application restriction laga hai — remove it (None) |
| App Explore ab bhi Wikipedia/gaon dikha raha | App restart karo; backend-down cache 45s ka hota hai |
| Weather "Invalid API key" | OpenWeather key 1-2 ghante baad activate hoti hai, ya galat paste hui |
| SOS/Digital ID/profile save nahi hota | Firestore database nahi bana — Step 2 |
| Avatar upload fail | Firebase **Storage** enable karo (console → Build → Storage → Get started) |
| Cost ka darr | Free limits: Cloud Functions 2M invocations/month, Firestore 50K reads/day — normal use me ₹0 |

---

## Keys kahaan se mile (summary)

| Secret | Kahan se | Free? |
|---|---|---|
| `GOOGLE_MAPS_API_KEY` | console.cloud.google.com (Places + Geocoding + Routes) | Free credits/month |
| `OPENWEATHER_API_KEY` | openweathermap.org/api | Free tier |
| `NVIDIA_API_KEY` | build.nvidia.com | Free tier |

Secrets kabhi bhi repo me commit mat karna — ye Google Secret Manager me
store hote hain (script se), app me nahi jaate.
