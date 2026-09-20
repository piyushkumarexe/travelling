/* YatraWise secure backend — all third-party secrets stay server-side.
 * Each endpoint is a v2 onRequest export; the export name is the URL path. */
'use strict';

const { onRequest } = require('firebase-functions/v2/https');
const admin = require('firebase-admin');

admin.initializeApp();

const REGION = process.env.GOOGLE_FUNCTION_REGION || 'us-central1';
const NVIDIA_URL = 'https://integrate.api.nvidia.com/v1/chat/completions';
const OWM_URL = 'https://api.openweathermap.org/data/2.5';
const PLACES_URL = 'https://maps.googleapis.com/maps/api/place';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'POST, GET, OPTIONS',
  'Access-Control-Allow-Headers':
    'content-type, authorization, x-firebase-token, x-goog-api-key',
};

class HttpError extends Error {
  constructor(status, message, kind) {
    super(message);
    this.status = status;
    this.kind = kind || 'upstream';
  }
}

const MAX_BODY = 100 * 1024;

function readJsonBody(req) {
  return new Promise((resolve, reject) => {
    let raw = '';
    let size = 0;
    req.on('data', (chunk) => {
      size += chunk.length;
      if (size > MAX_BODY) {
        reject(new HttpError(413, 'Request body too large.', 'validation'));
        req.destroy();
        return;
      }
      raw += chunk;
    });
    req.on('end', () => {
      if (!raw) return resolve({});
      try {
        resolve(JSON.parse(raw));
      } catch (_) {
        reject(new HttpError(400, 'Invalid JSON body.', 'validation'));
      }
    });
    req.on('error', (e) => reject(e));
  });
}

async function getUid(req) {
  const header = (req.headers.authorization || '').replace(/^Bearer\s+/i, '');
  if (!header) return null;
  try {
    const decoded = await admin.auth().verifyIdToken(header);
    return decoded.uid;
  } catch (_) {
    return null;
  }
}

const LIMITS = {
  chat: 10,
  itinerary: 5,
  incidentAnalyze: 5,
  weatherCurrent: 20,
  weatherForecast: 20,
  placesSearch: 30,
  placesDetails: 30,
  placesPhoto: 30,
  emergencyNearby: 10,
  route: 20,
  geocodeReverse: 20,
};

/** Per-uid, per-endpoint, per-minute rate limit (Firestore-backed). */
async function rateLimit(uid, endpoint, req) {
  const limit = LIMITS[endpoint];
  if (!limit) return;
  // An unauthenticated caller is NOT automatically a flood. The old code threw
  // 429 for every request without a verified uid, and the photo proxy is
  // fetched through a plain GET (an <img> cannot send an Authorization
  // header), so every place photo failed with "too many requests" on every
  // device. Anonymous traffic gets a tighter, IP-keyed bucket instead.
  const key = uid
    ? uid
    : `ip:${String((req && (req.ip || (req.headers && req['x-forwarded-for']))) || 'anon').split(',')[0].trim()}`;
  const bucketLimit = uid ? limit : Math.max(3, Math.round(limit / 3));
  const minute = Math.floor(Date.now() / 60000);
  const ref = admin
    .firestore()
    .collection('rateLimits')
    .doc(`${key}:${endpoint}:${minute}`);
  await admin.firestore().runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    const count = (snap.exists ? snap.data().count : 0) + 1;
    if (count > bucketLimit) {
      throw new HttpError(
        429,
        'Rate limit exceeded for this action. Please wait a minute and try again.',
        'rate',
      );
    }
    if (snap.exists) {
      tx.update(ref, { count });
    } else {
      tx.set(ref, { count, expiresAt: admin.firestore.FieldValue.serverTimestamp() });
    }
  });
}

function requireFiniteNumber(value, field, min, max) {
  const n = typeof value === 'string' ? parseFloat(value) : value;
  if (typeof n !== 'number' || !Number.isFinite(n) || n < min || n > max) {
    throw new HttpError(400, `Invalid value for "${field}".`, 'validation');
  }
  return n;
}

function requireText(value, field, min, max) {
  const s = typeof value === 'string' ? value.trim() : '';
  if (s.length < min || s.length > max) {
    throw new HttpError(400, `Invalid or missing "${field}".`, 'validation');
  }
  return s;
}

function haversineMeters(lat1, lng1, lat2, lng2) {
  const R = 6371000;
  const toRad = (d) => (d * Math.PI) / 180;
  const dLat = toRad(lat2 - lat1);
  const dLng = toRad(lng2 - lng1);
  const a =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(a));
}

/** Google encoded polyline -> [{lat,lng}...] (decoded server-side so the
 * client never has to decode polylines). Downsamples to `maxPoints`. */
function decodePolyline(encoded, maxPoints) {
  const points = [];
  let index = 0;
  let lat = 0;
  let lng = 0;
  while (index < encoded.length) {
    let shift = 0;
    let result = 0;
    let byte;
    do {
      byte = encoded.charCodeAt(index++) - 63;
      result |= (byte & 0x1f) << shift;
      shift += 5;
    } while (byte >= 0x20);
    const dLat = result & 1 ? ~(result >> 1) : result >> 1;
    shift = 0;
    result = 0;
    do {
      byte = encoded.charCodeAt(index++) - 63;
      result |= (byte & 0x1f) << shift;
      shift += 5;
    } while (byte >= 0x20);
    const dLng = result & 1 ? ~(result >> 1) : result >> 1;
    lat += dLat;
    lng += dLng;
    points.push({ lat: lat / 1e5, lng: lng / 1e5 });
  }
  if (maxPoints && points.length > maxPoints) {
    const step = (points.length - 1) / (maxPoints - 1);
    const out = [];
    for (let i = 0; i < maxPoints; i++) {
      out.push(points[Math.round(i * step)]);
    }
    return out;
  }
  return points;
}

/** Runs an endpoint handler with uniform CORS + error mapping. */
function makeHandler(fn) {
  return async (req, res) => {
    res.set(CORS);
    if (req.method === 'OPTIONS') {
      res.status(204).end();
      return;
    }
    try {
      await fn(req, res);
    } catch (e) {
      if (e instanceof HttpError) {
        res.status(e.status).json({ error: e.message, kind: e.kind });
      } else {
        console.error('[yatrawise] unexpected error:', e);
        res.status(500).json({
          error: 'Internal server error.',
          kind: 'internal',
        });
      }
    }
  };
}

function env(name) {
  const v = process.env[name];
  if (!v) {
    throw new HttpError(
      500,
      `Backend is missing the ${name} configuration. Ask your admin.`,
      'config',
    );
  }
  return v;
}

function googleKey() {
  return env('GOOGLE_MAPS_API_KEY');
}

async function fetchJson(url, opts) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 25000);
  try {
    const resp = await fetch(url, { ...opts, signal: controller.signal });
    const text = await resp.text();
    let data;
    try {
      data = JSON.parse(text);
    } catch (_) {
      throw new HttpError(502, 'Upstream service returned an invalid response.', 'upstream');
    }
    if (!resp.ok) {
      if (resp.status === 401 || resp.status === 403) {
        throw new HttpError(
          502,
          `Upstream rejected the request (${resp.status}). Check backend key configuration.`,
          'upstream',
        );
      }
      const detail = (data && (data.error && data.error.message)) || data.status || '';
      throw new HttpError(
        502,
        `Upstream request failed: ${String(detail).slice(0, 160) || resp.status}`,
        'upstream',
      );
    }
    return data;
  } catch (e) {
    if (e instanceof HttpError) throw e;
    if (e.name === 'AbortError') {
      throw new HttpError(504, 'Upstream request timed out.', 'upstream');
    }
    throw new HttpError(502, 'Could not reach the upstream service.', 'upstream');
  } finally {
    clearTimeout(timer);
  }
}

/* ------------------------------ NVIDIA AI ------------------------------ */

async function nvidiaChat(messages, { jsonMode = false, maxTokens = 1200 } = {}) {
  const key = env('NVIDIA_API_KEY');
  const data = await fetchJson(NVIDIA_URL, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${key}`,
    },
    body: JSON.stringify({
      model: process.env.NVIDIA_MODEL || 'meta/llama3.1-70b-instruct',
      messages,
      temperature: 0.6,
      top_p: 0.9,
      max_tokens: maxTokens,
      ...(jsonMode ? { response_format: { type: 'json_object' } } : {}),
    }),
  });
  const content =
    data && data.choices && data.choices[0] && data.choices[0].message
      ? data.choices[0].message.content
      : null;
  if (!content || !String(content).trim()) {
    throw new HttpError(502, 'The AI model returned an empty response.', 'upstream');
  }
  return String(content);
}

function parseJsonLoose(text) {
  let t = String(text).trim();
  // Strip markdown fences if the model added them despite json mode.
  if (t.startsWith('```')) {
    t = t.replace(/^```[a-zA-Z]*\s*/, '').replace(/```\s*$/, '');
  }
  const start = t.indexOf('{');
  const end = t.lastIndexOf('}');
  if (start >= 0 && end > start) t = t.slice(start, end + 1);
  return JSON.parse(t);
}

/* --------------------------- shared validators ------------------------- */

const CATEGORIES = [
  'theft',
  'fraud',
  'assault',
  'harassment',
  'accident',
  'unsafe_area',
  'poor_infrastructure',
  'natural_hazard',
  'other',
];
const SEVERITIES = ['low', 'medium', 'high', 'critical'];

function pickEnum(obj, field, allowed, fallback) {
  const v = typeof obj[field] === 'string' ? obj[field].trim().toLowerCase() : '';
  return allowed.includes(v) ? v : fallback;
}

function pickString(obj, field, max) {
  const v = typeof obj[field] === 'string' ? obj[field].trim() : '';
  return v.slice(0, max);
}

/* -------------------------------- /chat -------------------------------- */

exports.chat = onRequest(
  {
    region: REGION,
    runtimeOptions: { timeoutSeconds: 60, memory: 512 },
  },
  makeHandler(async (req, res) => {
    if (req.method !== 'POST') throw new HttpError(405, 'Method not allowed.', 'validation');
    const uid = await getUid(req);
    await rateLimit(uid, 'chat', req);
    const body = await readJsonBody(req);

    const messages = Array.isArray(body.messages) ? body.messages : null;
    if (!messages || messages.length === 0 || messages.length > 40) {
      throw new HttpError(400, 'Provide 1-40 chat messages.', 'validation');
    }
    const clean = [];
    for (const m of messages) {
      const role = m && (m.role === 'user' || m.role === 'assistant') ? m.role : null;
      const content = m && typeof m.content === 'string' ? m.content.trim() : '';
      if (!role || content.length < 1 || content.length > 2000) {
        throw new HttpError(400, 'Each message needs role user/assistant and 1-2000 chars.', 'validation');
      }
      clean.push({ role, content });
    }
    if (!clean.some((m) => m.role === 'user')) {
      throw new HttpError(400, 'At least one user message is required.', 'validation');
    }

    let system =
      'You are YatraWise, a smart tourism and personal-safety assistant. ' +
      'Answer travel questions (attractions, food, transport, itineraries, local tips) ' +
      'with practical, current, location-aware advice. Keep replies under 250 words, ' +
      'friendly and specific. If safety is at stake, advise calling local emergency services. ' +
      'Never invent precise facts you are unsure of; say what is typical and suggest verifying. ';
    if (typeof body.locationLabel === 'string' && body.locationLabel.trim()) {
      system += `The traveler is currently in: ${body.locationLabel.slice(0, 200)}. `;
    }
    if (typeof body.profileContext === 'string' && body.profileContext.trim()) {
      system += `Traveler preferences: ${body.profileContext.slice(0, 400)}. `;
    }

    const reply = await nvidiaChat([
      { role: 'system', content: system },
      ...clean,
    ]);
    res.status(200).json({ reply: reply.trim() });
  }),
);

/* ------------------------------- /itinerary ---------------------------- */

exports.itinerary = onRequest(
  {
    region: REGION,
    runtimeOptions: { timeoutSeconds: 90, memory: 512 },
  },
  makeHandler(async (req, res) => {
    if (req.method !== 'POST') throw new HttpError(405, 'Method not allowed.', 'validation');
    const uid = await getUid(req);
    await rateLimit(uid, 'itinerary', req);
    const body = await readJsonBody(req);

    const destination = requireText(body.destination, 'destination', 2, 120);
    const days =
      typeof body.days === 'number' && Number.isInteger(body.days) ? body.days : parseInt(body.days, 10);
    if (!Number.isInteger(days) || days < 1 || days > 10) {
      throw new HttpError(400, 'days must be an integer between 1 and 10.', 'validation');
    }
    const interests = Array.isArray(body.interests)
      ? body.interests.filter((i) => typeof i === 'string').slice(0, 10).map((i) => i.trim()).filter(Boolean)
      : [];
    const budget = requireText(body.budget, 'budget', 2, 40);
    const style = requireText(body.travelStyle, 'travelStyle', 2, 40);

    const prompt =
      `Create a realistic ${days}-day travel itinerary for ${destination}. ` +
      `Traveler interests: ${interests.length ? interests.join(', ') : 'general sightseeing'}. ` +
      `Budget level: ${budget}. Pace: ${style}. ` +
      `Respond with ONLY JSON matching exactly this schema: ` +
      '{"plan":[{"day":1,"items":[{"time":"HH:MM","title":"...","description":"1-2 sentences","cost":"e.g. free, $15, ~₹500"}]}]}. ' +
      `Include 3-6 items per day with times, covering ${destination}'s real attractions, ` +
      'food and transport. No markdown, no extra keys.';

    const raw = await nvidiaChat(
      [
        { role: 'system', content: 'You are a meticulous travel planner that outputs strict JSON only.' },
        { role: 'user', content: prompt },
      ],
      { jsonMode: true, maxTokens: 2400 },
    );

    let parsed;
    try {
      parsed = parseJsonLoose(raw);
    } catch (_) {
      throw new HttpError(502, 'The AI returned a malformed itinerary. Please regenerate.', 'upstream');
    }
    const rawPlan = Array.isArray(parsed.plan) ? parsed.plan : [];
    const plan = [];
    for (const d of rawPlan.slice(0, 10)) {
      if (!d || !Array.isArray(d.items)) continue;
      const items = d.items.slice(0, 10).map((it) => ({
        time: pickString(it, 'time', 8) || '',
        title: pickString(it, 'title', 140),
        description: pickString(it, 'description', 400),
        cost: pickString(it, 'cost', 60),
      }));
      if (items.length === 0) continue;
      plan.push({
        day: Number.isFinite(parseInt(d.day, 10)) ? parseInt(d.day, 10) : plan.length + 1,
        items,
      });
    }
    if (plan.length === 0) {
      throw new HttpError(502, 'The AI returned an empty itinerary. Please regenerate.', 'upstream');
    }
    res.status(200).json({ plan });
  }),
);

/* ---------------------------- /incidentAnalyze -------------------------- */

exports.incidentAnalyze = onRequest(
  {
    region: REGION,
    runtimeOptions: { timeoutSeconds: 60, memory: 512 },
  },
  makeHandler(async (req, res) => {
    if (req.method !== 'POST') throw new HttpError(405, 'Method not allowed.', 'validation');
    const uid = await getUid(req);
    await rateLimit(uid, 'incidentAnalyze', req);
    const body = await readJsonBody(req);

    const description = requireText(body.description, 'description', 10, 2000);
    const locationLabel =
      typeof body.locationLabel === 'string' && body.locationLabel.trim()
        ? body.locationLabel.trim().slice(0, 200)
        : null;
    const hasPhoto = body.hasPhoto === true;
    const hasVideo = body.hasVideo === true;

    const prompt =
      `You are a security analyst triaging a traveler's incident report. ` +
      `Description: """${description}""" ` +
      (locationLabel ? `Location: ${locationLabel}. ` : '') +
      `Attached evidence: ${[hasPhoto ? 'photo' : null, hasVideo ? 'video' : null].filter(Boolean).join(' + ') || 'none'}. ` +
      'Respond with ONLY JSON: ' +
      '{"category":"one of ' +
      CATEGORIES.join('|') +
      '","severity":"one of ' +
      SEVERITIES.join('|') +
      '","summary":"1-2 sentence neutral summary","recommendedAction":"1-2 concrete safety actions for the traveler"}. ' +
      'Do not claim authorities were notified. Be factual.';

    const raw = await nvidiaChat(
      [
        { role: 'system', content: 'You output strict JSON only.' },
        { role: 'user', content: prompt },
      ],
      { jsonMode: true, maxTokens: 600 },
    );
    let parsed;
    try {
      parsed = parseJsonLoose(raw);
    } catch (_) {
      throw new HttpError(502, 'The AI triage failed. Please retry.', 'upstream');
    }
    res.status(200).json({
      category: pickEnum(parsed, 'category', CATEGORIES, 'other'),
      severity: pickEnum(parsed, 'severity', SEVERITIES, 'medium'),
      summary: pickString(parsed, 'summary', 500),
      recommendedAction: pickString(parsed, 'recommendedAction', 500),
    });
  }),
);

/* ------------------------------- OpenWeather ---------------------------- */

function ownKey() {
  return env('OPENWEATHER_API_KEY');
}

function weatherConditionLabel(d) {
  const desc = typeof d.description === 'string' ? d.description : 'Unknown';
  return desc.charAt(0).toUpperCase() + desc.slice(1);
}

exports.weatherCurrent = onRequest(
  { region: REGION, runtimeOptions: { timeoutSeconds: 30, memory: 256 } },
  makeHandler(async (req, res) => {
    if (req.method !== 'POST') throw new HttpError(405, 'Method not allowed.', 'validation');
    const uid = await getUid(req);
    await rateLimit(uid, 'weatherCurrent', req);
    const body = await readJsonBody(req);
    const lat = requireFiniteNumber(body.lat, 'lat', -90, 90);
    const lng = requireFiniteNumber(body.lng, 'lng', -180, 180);

    const d = await fetchJson(
      `${OWM_URL}/weather?lat=${lat}&lon=${lng}&units=metric&appid=${ownKey()}`,
    );
    if (d.cod !== 200 || !d.main || !Array.isArray(d.weather) || d.weather.length === 0) {
      throw new HttpError(502, `No weather data for this location (${d.message || d.cod || 'unknown'}).`, 'upstream');
    }
    res.status(200).json({
      current: {
        tempC: d.main.temp,
        feelsLikeC: d.main.feels_like,
        humidityPct: d.main.humidity,
        windMs: (d.wind && d.wind.speed) || 0,
        windDeg: (d.wind && d.wind.deg) || 0,
        condition: weatherConditionLabel(d.weather[0]),
        icon: (d.weather[0] && d.weather[0].icon) || '01d',
        pressureHpa: d.main.pressure,
        visibilityM: d.visibility || 0,
        updatedAt: new Date((d.dt || Date.now() / 1000) * 1000).toISOString(),
      },
    });
  }),
);

exports.weatherForecast = onRequest(
  { region: REGION, runtimeOptions: { timeoutSeconds: 30, memory: 256 } },
  makeHandler(async (req, res) => {
    if (req.method !== 'POST') throw new HttpError(405, 'Method not allowed.', 'validation');
    const uid = await getUid(req);
    await rateLimit(uid, 'weatherForecast', req);
    const body = await readJsonBody(req);
    const lat = requireFiniteNumber(body.lat, 'lat', -90, 90);
    const lng = requireFiniteNumber(body.lng, 'lng', -180, 180);

    const d = await fetchJson(
      `${OWM_URL}/forecast?lat=${lat}&lon=${lng}&units=metric&appid=${ownKey()}`,
    );
    if (d.cod !== 200 || !Array.isArray(d.list) || d.list.length === 0) {
      throw new HttpError(502, 'No forecast data for this location.', 'upstream');
    }
    const byDay = new Map();
    for (const item of d.list) {
      const key = String(item.dt_txt || '').slice(0, 10);
      if (!key) continue;
      const cur = byDay.get(key) || {
        date: `${key}T12:00:00.000Z`,
        tempMaxC: -Infinity,
        tempMinC: Infinity,
        condition: weatherConditionLabel(item.weather && item.weather[0] ? item.weather[0] : {}),
        icon: (item.weather && item.weather[0] && item.weather[0].icon) || '01d',
        precipChancePct: 0,
      };
      cur.tempMaxC = Math.max(cur.tempMaxC, item.main && item.main.temp_max !== undefined ? item.main.temp_max : item.main.temp);
      cur.tempMinC = Math.min(cur.tempMinC, item.main && item.main.temp_min !== undefined ? item.main.temp_min : item.main.temp);
      cur.precipChancePct = Math.max(cur.precipChancePct, Math.round((item.pop || 0) * 100));
      byDay.set(key, cur);
    }
    const days = Array.from(byDay.values()).slice(0, 5).map((x) => ({
      date: x.date,
      tempMaxC: x.tempMaxC,
      tempMinC: x.tempMinC,
      condition: x.condition,
      icon: x.icon,
      precipChancePct: x.precipChancePct,
    }));
    res.status(200).json({ days });
  }),
);

/* -------------------------- Google Places (legacy) ---------------------- */

function functionBaseUrl(req) {
  const host = req && req.headers && req.headers.host;
  // A 2nd-gen HTTP function (onRequest) is served at
  //   https://REGION-PROJECT.cloudfunctions.net/<name>
  // `/functions/v2/<name>` is the *callable* prefix — appending it here made
  // every generated photo URL 404, so place photos could never load.
  if (host) return `https://${host}`;
  const project =
    process.env.GOOGLE_CLOUD_PROJECT || process.env.GCLOUD_PROJECT || '';
  if (project) return `https://${REGION}-${project}.cloudfunctions.net`;
  throw new HttpError(
    500,
    'Backend cannot determine its function URL (missing project context).',
    'config',
  );
}

function mapPlace(r, base) {
  if (!r || typeof r !== 'object') return null;
  const loc = r.geometry && r.geometry.location ? r.geometry.location : null;
  if (!loc) return null;
  // Google legacy APIs return lat/lng as numbers, but sometimes as {lat,lng}
  const lat = typeof loc.lat === 'function' ? loc.lat() : loc.lat;
  const lng = typeof loc.lng === 'function' ? loc.lng() : loc.lng;
  if (!Number.isFinite(lat) || !Number.isFinite(lng)) return null;
  const photos = Array.isArray(r.photos)
    ? r.photos.slice(0, 3).map((p) =>
        `${base}/placesPhoto?photoreference=${encodeURIComponent(p.photo_reference || p.photoReference || '')}&maxwidth=1200`)
    : [];
  const openHours = r.opening_hours || r.open_hours || null;
  return {
    placeId: r.place_id || r.placeId || '',
    name: r.name || 'Unknown place',
    lat: lat,
    lng: lng,
    address: r.formatted_address || r.vicinity || r.formattedAddress || null,
    rating: typeof r.rating === 'number' ? r.rating : null,
    userRatingCount: typeof r.user_ratings_total === 'number' ? r.user_ratings_total : (typeof r.user_ratings_total === 'number' ? r.user_ratings_total : null),
    primaryType: Array.isArray(r.types) && r.types.length ? r.types[0] : null,
    types: Array.isArray(r.types) ? r.types.slice(0, 10) : [],
    photoUrls: photos,
    phone: r.formatted_phone_number || r.international_phone_number || r.formattedPhoneNumber || null,
    website: r.website || null,
    priceLevel: typeof r.price_level === 'number' ? r.price_level : null,
    openNow:
      typeof r.open_now === 'boolean'
        ? r.open_now
        : openHours && typeof openHours.open_now === 'boolean'
          ? openHours.open_now
          : null,
    provider: 'google',
  };
}

/**
 * Improved Places search:
 * - Uses Text Search when query is present (returns up to 20 results, biased by location)
 * - Uses Nearby Search when only types + location are present
 * - Always sorts by distance from user when location is available
 * - Fixes old bug where findplacefromtext returned candidates but code read results
 */
async function googlePlacesSearch(body, req) {
  const key = googleKey();
  const query =
    body.query && String(body.query).trim()
      ? String(body.query).trim().slice(0, 120)
      : '';
  const hasLoc =
    body.location &&
    Number.isFinite(body.location.lat) &&
    Number.isFinite(body.location.lng);
  const lat = hasLoc ? body.location.lat : null;
  const lng = hasLoc ? body.location.lng : null;
  const radius =
    body.radiusMeters && Number.isFinite(body.radiusMeters)
      ? Math.min(Math.max(Math.round(body.radiusMeters), 100), 50000)
      : hasLoc ? 25000 : null; // default 25km when location present
  const hasTypes = Array.isArray(body.types) && body.types.length > 0;
  const base = functionBaseUrl(req || {});

  let url;

  if (query) {
    // TEXT SEARCH - best for free-form queries like "TS Mishra University", "transport nagar"
    const params = [`query=${encodeURIComponent(query)}`];
    if (hasLoc) {
      params.push(`location=${lat.toFixed(6)},${lng.toFixed(6)}`);
      if (radius) params.push(`radius=${radius}`);
    }
    // If types are also provided, add as type filter for better relevance
    if (hasTypes && body.types.length === 1) {
      params.push(`type=${encodeURIComponent(body.types[0])}`);
    }
    url = `${PLACES_URL}/textsearch/json?${params.join('&')}`;
  } else if (hasLoc && hasTypes) {
    // NEARBY SEARCH - for category browsing without query
    const params = [
      `location=${lat.toFixed(6)},${lng.toFixed(6)}`,
      `radius=${radius || 10000}`,
    ];
    // Places API nearbysearch supports single type; use first as type, rest as keyword
    if (body.types.length >= 1) {
      params.push(`type=${encodeURIComponent(body.types[0])}`);
    }
    if (body.types.length > 1) {
      params.push(`keyword=${encodeURIComponent(body.types.slice(1).join(' '))}`);
    }
    url = `${PLACES_URL}/nearbysearch/json?${params.join('&')}`;
  } else {
    throw new HttpError(400, 'Provide a query (or location + types).', 'validation');
  }

  url += `&key=${encodeURIComponent(key)}`;
  const d = await fetchJson(url);

  if (d.status === 'ZERO_RESULTS') return [];
  if (d.status !== 'OK' && d.status !== 'ZERO_RESULTS') {
    throw new HttpError(
      502,
      `Places search failed: ${d.status}${d.error_message ? ' — ' + d.error_message : ''}`.slice(0, 200),
      'upstream'
    );
  }

  // Textsearch returns results, nearbysearch returns results, findplace returned candidates (legacy)
  let rawResults = [];
  if (Array.isArray(d.results)) rawResults = d.results;
  else if (Array.isArray(d.candidates)) rawResults = d.candidates; // backward compat
  else rawResults = [];

  let mapped = rawResults
    .slice(0, 30)
    .map((r) => mapPlace(r, base))
    .filter(Boolean);

  // Sort by distance if we have user location - CRITICAL FIX for "far locations" bug
  if (hasLoc && mapped.length > 1) {
    mapped = mapped
      .map((p) => ({
        ...p,
        _dist: haversineMeters(lat, lng, p.lat, p.lng),
      }))
      .sort((a, b) => a._dist - b._dist)
      .map((p) => {
        const { _dist, ...rest } = p;
        return rest;
      });
  }

  // Limit to 20 after sorting
  return mapped.slice(0, 20);
}

exports.placesSearch = onRequest(
  { region: REGION, runtimeOptions: { timeoutSeconds: 30, memory: 256 } },
  makeHandler(async (req, res) => {
    if (req.method !== 'POST') throw new HttpError(405, 'Method not allowed.', 'validation');
    const uid = await getUid(req);
    await rateLimit(uid, 'placesSearch', req);
    const body = await readJsonBody(req);
    if (!body.query && !(body.location && Array.isArray(body.types))) {
      throw new HttpError(400, 'Provide a query (or location + types).', 'validation');
    }
    const places = await googlePlacesSearch(body, req);
    res.status(200).json({ places });
  }),
);

exports.placesDetails = onRequest(
  { region: REGION, runtimeOptions: { timeoutSeconds: 30, memory: 256 } },
  makeHandler(async (req, res) => {
    if (req.method !== 'POST') throw new HttpError(405, 'Method not allowed.', 'validation');
    const uid = await getUid(req);
    await rateLimit(uid, 'placesDetails', req);
    const body = await readJsonBody(req);
    const placeId = requireText(body.placeId, 'placeId', 1, 200);
    const key = googleKey();
    const d = await fetchJson(
      `${PLACES_URL}/details/json?place_id=${encodeURIComponent(placeId)}` +
        `&fields=name,formatted_address,geometry,rating,user_ratings_total,types,photos,formatted_phone_number,international_phone_number,website,price_level,open_hours,status&key=${encodeURIComponent(key)}`,
    );
    if (d.status !== 'OK' || !d.result) {
      throw new HttpError(404, `Place not found (${d.status || 'unknown'}).`, 'upstream');
    }
    res.status(200).json({ place: mapPlace(d.result, functionBaseUrl(req)) });
  }),
);

exports.placesPhoto = onRequest(
  { region: REGION, runtimeOptions: { timeoutSeconds: 30, memory: 256 } },
  makeHandler(async (req, res) => {
    if (req.method !== 'GET' && req.method !== 'POST') {
      throw new HttpError(405, 'Method not allowed.', 'validation');
    }
    const uid = await getUid(req);
    await rateLimit(uid, 'placesPhoto', req);
    const ref = requireText(req.query && req.query.photoreference, 'photoreference', 1, 300);
    const maxwidth = Math.min(
      Math.max(parseInt(req.query && req.query.maxwidth, 10) || 1200, 1),
      1600,
    );
    const key = googleKey();
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 20000);
    try {
      const resp = await fetch(
        `${PLACES_URL}/photo?photoreference=${encodeURIComponent(ref)}&maxwidth=${maxwidth}&key=${encodeURIComponent(key)}`,
        { signal: controller.signal },
      );
      if (!resp.ok) {
        throw new HttpError(502, 'Could not fetch the place photo.', 'upstream');
      }
      const bytes = Buffer.from(await resp.arrayBuffer());
      res
        .status(200)
        .set({ 'Content-Type': resp.headers.get('content-type') || 'image/jpeg', 'Cache-Control': 'public, max-age=86400' })
        .send(bytes);
    } catch (e) {
      if (e instanceof HttpError) throw e;
      throw new HttpError(502, 'Could not fetch the place photo.', 'upstream');
    } finally {
      clearTimeout(timer);
    }
  }),
);

exports.emergencyNearby = onRequest(
  { region: REGION, runtimeOptions: { timeoutSeconds: 30, memory: 256 } },
  makeHandler(async (req, res) => {
    if (req.method !== 'POST') throw new HttpError(405, 'Method not allowed.', 'validation');
    const uid = await getUid(req);
    await rateLimit(uid, 'emergencyNearby', req);
    const body = await readJsonBody(req);
    if (!body.location || typeof body.location.lat !== 'number' || typeof body.location.lng !== 'number') {
      throw new HttpError(400, 'location {lat,lng} is required.', 'validation');
    }
    const radius =
      body.radiusMeters && Number.isFinite(body.radiusMeters)
        ? Math.min(Math.max(Math.round(body.radiusMeters), 100), 20000)
        : 5000;
    const loc = { lat: body.location.lat, lng: body.location.lng };
    
    // Search each emergency type separately and merge - ensures we get hospitals, police, fire all nearby
    const types = ['hospital', 'police_station', 'fire_station'];
    let allPlaces = [];
    const seenIds = new Set();
    
    for (const t of types) {
      try {
        const places = await googlePlacesSearch({
          location: loc,
          radiusMeters: radius,
          types: [t],
        }, req);
        for (const p of places) {
          if (p.placeId && !seenIds.has(p.placeId)) {
            seenIds.add(p.placeId);
            allPlaces.push(p);
          } else if (!p.placeId) {
            allPlaces.push(p);
          }
        }
      } catch (e) {
        // Continue with other types if one fails
        console.warn(`[emergencyNearby] failed for type ${t}:`, e.message);
      }
    }
    
    // Sort merged results by distance
    allPlaces = allPlaces
      .map((p) => ({
        ...p,
        _dist: haversineMeters(loc.lat, loc.lng, p.lat, p.lng),
      }))
      .sort((a, b) => a._dist - b._dist)
      .map((p) => {
        const { _dist, ...rest } = p;
        return rest;
      })
      .slice(0, 20);
    
    res.status(200).json({ places: allPlaces });
  }),
);

/* -------------------------------- /route ------------------------------- */

// Routes API (v2). The previous version of this function POSTed to
// `directions.googleapis.com/v2/routes:computeRoutes` with the field list in
// the BODY — that host/path does not exist and the mask is only accepted in
// the X-Goog-FieldMask header, so every call failed and the client silently
// fell back to straight-line/OSRM geometry.
const ROUTES_URL = 'https://routes.googleapis.com/directions/v2:computeRoutes';
const ROUTES_FIELD_MASK =
  'routes.duration,routes.distanceMeters,routes.polyline.encodedPolyline,routes.legs.distanceMeters,routes.legs.duration';

async function googleRoute(origin, destination) {
  const key = googleKey();
  const data = await fetchJson(ROUTES_URL, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'x-goog-api-key': key,
      'X-Goog-FieldMask': ROUTES_FIELD_MASK,
    },
    body: JSON.stringify({
      origin: { location: { latLng: { latitude: origin.lat, longitude: origin.lng } } },
      destination: { location: { latLng: { latitude: destination.lat, longitude: destination.lng } } },
      // Routes API spellings: travelMode is DRIVE (not DRIVING) and the only
      // valid trafficModel values are TRAFFIC_UNAWARE / TRAFFIC_LOW_LATENCY.
      travelMode: 'DRIVE',
      // trafficModel belongs to routingPreference; routeModifiers only takes
      // avoidTolls/avoidHighways/avoidFerries. polylineEncoding is top-level.
      routingPreference: { trafficModel: 'TRAFFIC_UNAWARE' },
      polylineEncoding: 'COMPRESSED_MIME',
      computeAlternativeRoutes: false,
    }),
  });
  const routes = Array.isArray(data.routes) ? data.routes : [];
  if (routes.length === 0) {
    throw new HttpError(502, 'Directions API returned no routes.', 'upstream');
  }
  const r = routes[0];
  const polyline = decodePolyline(
    r.polyline && typeof r.polyline.encodedPolyline === 'string'
      ? r.polyline.encodedPolyline
      : '',
    250,
  );
  if (polyline.length === 0) {
    throw new HttpError(502, 'Directions API returned no route geometry.', 'upstream');
  }
  return {
    distanceMeters: parseFloat(r.distanceMeters) || 0,
    durationSeconds: parseFloat((r.duration || '').replace('s', '')) || 0,
    polyline,
    provider: 'google',
  };
}

exports.route = onRequest(
  { region: REGION, runtimeOptions: { timeoutSeconds: 30, memory: 256 } },
  makeHandler(async (req, res) => {
    if (req.method !== 'POST') throw new HttpError(405, 'Method not allowed.', 'validation');
    const uid = await getUid(req);
    await rateLimit(uid, 'route', req);
    const body = await readJsonBody(req);
    const lat1 = requireFiniteNumber(
      body.origin && body.origin.lat, 'origin.lat', -90, 90);
    const lng1 = requireFiniteNumber(
      body.origin && body.origin.lng, 'origin.lng', -180, 180);
    const lat2 = requireFiniteNumber(
      body.destination && body.destination.lat, 'destination.lat', -90, 90);
    const lng2 = requireFiniteNumber(
      body.destination && body.destination.lng, 'destination.lng', -180, 180);

    try {
      const route = await googleRoute(
        { lat: lat1, lng: lng1 },
        { lat: lat2, lng: lng2 },
      );
      res.status(200).json(route);
      return;
    } catch (e) {
      if (!(e instanceof HttpError) || e.kind !== 'upstream') throw e;
      // Honest fallback: straight-line distance + average driving speed.
    }
    const meters = haversineMeters(lat1, lng1, lat2, lng2) * 1.3; // road factor
    res.status(200).json({
      distanceMeters: Math.round(meters),
      durationSeconds: Math.round(meters / (30000 / 3600)), // 30 km/h
      polyline: [
        { lat: lat1, lng: lng1 },
        { lat: lat2, lng: lng2 },
      ],
      provider: 'fallback',
    });
  }),
);

/* ----------------------------- /geocodeReverse -------------------------- */

function buildLabel(components) {
  if (!Array.isArray(components)) return null;
  const find = (types) =>
    components.find((c) => Array.isArray(c.types) && c.types.some((t) => types.includes(t)));
  const parts = [];
  const route = find(['route', 'neighborhood', 'sublocality_level_3']);
  const street = find(['street']);
  const number = find(['street_number']);
  const locality = find(['locality']);
  const area = find(['administrative_area_level_1']);
  if (number && street) {
    parts.push(`${street.short_name} ${number.short_name}`);
  } else if (street) {
    parts.push(street.short_name);
  } else if (route) {
    parts.push(route.short_name);
  }
  if (locality) parts.push(locality.short_name);
  if (parts.length === 0 && area) parts.push(area.short_name);
  const label = parts.join(', ');
  return label.length > 0 ? label.slice(0, 160) : null;
}

exports.geocodeReverse = onRequest(
  { region: REGION, runtimeOptions: { timeoutSeconds: 30, memory: 256 } },
  makeHandler(async (req, res) => {
    if (req.method !== 'POST') throw new HttpError(405, 'Method not allowed.', 'validation');
    const uid = await getUid(req);
    await rateLimit(uid, 'geocodeReverse', req);
    const body = await readJsonBody(req);
    const lat = requireFiniteNumber(body.lat, 'lat', -90, 90);
    const lng = requireFiniteNumber(body.lng, 'lng', -180, 180);
    const key = googleKey();
    let data;
    try {
      data = await fetchJson(
        `${'https://maps.googleapis.com/maps/api/geocode/json?latlng='}${lat},${lng}&key=${encodeURIComponent(key)}`,
      );
    } catch (e) {
      res.status(200).json({ label: null });
      return;
    }
    const first = Array.isArray(data.results) ? data.results[0] : null;
    const label = first ? buildLabel(first.address_components) : null;
    res.status(200).json({ label: label || null });
  }),
);
