'use strict';

const admin = require('firebase-admin');
const {onRequest} = require('firebase-functions/v2/https');
const {defineSecret} = require('firebase-functions/params');

const {HttpError, requiredEnv, makeHandler, requireUid, fetchJson} = require('./lib/http');
const v = require('./lib/validation');
const {chatComplete, chatJson} = require('./lib/ai');
const {createRateLimiter} = require('./lib/rate_limit');
const {deleteAccount} = require('./lib/account');

admin.initializeApp();

const REGION = process.env.FUNCTION_REGION || 'us-central1';
const NVIDIA_API_KEY = defineSecret('NVIDIA_API_KEY');
const OPENWEATHER_API_KEY = defineSecret('OPENWEATHER_API_KEY');
const GOOGLE_MAPS_API_KEY = defineSecret('GOOGLE_MAPS_API_KEY');
const getUid = requireUid(admin);
const rateLimit = createRateLimiter(admin);
const PLACES_URL = 'https://maps.googleapis.com/maps/api/place';
const OWM_URL = 'https://api.openweathermap.org/data/2.5';
const CATEGORIES = ['harassment', 'theft', 'assault', 'accident', 'unsafe_area', 'medical', 'lost', 'fraud', 'other'];
const SEVERITIES = ['low', 'medium', 'high', 'critical'];

function endpoint(name, handler, options = {}) {
  return onRequest({
    region: REGION,
    timeoutSeconds: options.timeoutSeconds || 30,
    memory: options.memory || '256MiB',
    secrets: options.secrets || [],
  }, makeHandler(name, handler, {methods: options.methods}));
}

async function authenticated(req, bucket) {
  const uid = await getUid(req);
  await rateLimit(uid, bucket);
  return uid;
}

function googleKey() {
  return requiredEnv('GOOGLE_MAPS_API_KEY');
}

function weatherKey() {
  return requiredEnv('OPENWEATHER_API_KEY');
}

function haversineMeters(lat1, lng1, lat2, lng2) {
  const rad = Math.PI / 180;
  const dLat = (lat2 - lat1) * rad;
  const dLng = (lng2 - lng1) * rad;
  const a = Math.sin(dLat / 2) ** 2 +
    Math.cos(lat1 * rad) * Math.cos(lat2 * rad) * Math.sin(dLng / 2) ** 2;
  return 6371000 * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

function decodePolyline(encoded, maxPoints = 250) {
  const points = [];
  let index = 0;
  let lat = 0;
  let lng = 0;
  while (index < encoded.length && points.length < maxPoints) {
    for (const target of ['lat', 'lng']) {
      let shift = 0;
      let result = 0;
      let byte;
      do {
        if (index >= encoded.length) return points;
        byte = encoded.charCodeAt(index++) - 63;
        result |= (byte & 0x1f) << shift;
        shift += 5;
      } while (byte >= 0x20 && shift < 30);
      const delta = (result & 1) ? ~(result >> 1) : (result >> 1);
      if (target === 'lat') lat += delta;
      else lng += delta;
    }
    points.push({lat: lat / 1e5, lng: lng / 1e5});
  }
  return points;
}

/* ---------------------------------- AI --------------------------------- */

exports.chat = endpoint('chat', async (req, res, body) => {
  await authenticated(req, 'chat');
  const messages = v.chatMessages(body.messages);
  const locationLabel = v.optionalText(body.locationLabel, 'locationLabel', 200);
  const profileContext = v.optionalText(body.profileContext, 'profileContext', 400);
  let system = 'You are Tourism, a travel and personal-safety assistant. ' +
    'Give practical, location-aware advice in under 250 words. Never invent precise ' +
    'facts or claim that authorities/emergency services were contacted. Say when ' +
    'information needs verification. For immediate danger, advise local emergency services.';
  if (locationLabel) system += ` Traveller location context: ${locationLabel}.`;
  if (profileContext) system += ` Traveller preferences: ${profileContext}.`;
  const reply = await chatComplete([{role: 'system', content: system}, ...messages], {maxTokens: 700});
  res.status(200).json({reply});
}, {secrets: [NVIDIA_API_KEY], timeoutSeconds: 60, memory: '512MiB'});

exports.itinerary = endpoint('itinerary', async (req, res, body) => {
  await authenticated(req, 'itinerary');
  const destination = v.text(body.destination, 'destination', 120, {min: 2});
  const days = v.integer(body.days, 'days', 1, 10);
  const interests = v.stringList(body.interests, 'interests', 10, 60, {required: false});
  const budget = v.oneOf(body.budget, 'budget', ['low', 'mid', 'high', 'budget', 'moderate', 'luxury']);
  const travelStyle = v.text(body.travelStyle, 'travelStyle', 40, {min: 2});
  const prompt = `Create a realistic ${days}-day travel itinerary for ${destination}. ` +
    `Interests: ${interests.length ? interests.join(', ') : 'general sightseeing'}. ` +
    `Budget: ${budget}. Pace: ${travelStyle}. Use real attractions but do not invent ` +
    'opening hours, prices or bookings. Return ONLY JSON with schema ' +
    '{"plan":[{"day":1,"title":"...","items":[{"time":"HH:MM","title":"...",' +
    '"description":"1-2 sentences","cost":"unknown or approximate"}]}]}. ' +
    `Include 3-6 items for each of ${days} days. No markdown or extra keys.`;
  const parsed = await chatJson([
    {role: 'system', content: 'You are a meticulous travel planner that outputs strict JSON only.'},
    {role: 'user', content: prompt},
  ], {maxTokens: 3000, temperature: 0.2});
  const rawPlan = Array.isArray(parsed.plan) ? parsed.plan : [];
  const plan = [];
  for (const day of rawPlan.slice(0, days)) {
    if (!day || !Array.isArray(day.items)) continue;
    const items = day.items.slice(0, 8).map((item) => ({
      time: typeof item?.time === 'string' ? item.time.trim().slice(0, 8) : '',
      title: typeof item?.title === 'string' ? item.title.trim().slice(0, 140) : '',
      description: typeof item?.description === 'string' ? item.description.trim().slice(0, 400) : '',
      cost: typeof item?.cost === 'string' ? item.cost.trim().slice(0, 60) : '',
    })).filter((item) => item.title);
    if (!items.length) continue;
    plan.push({
      day: plan.length + 1,
      title: typeof day.title === 'string' ? day.title.trim().slice(0, 120) : `Day ${plan.length + 1}`,
      items,
    });
  }
  if (plan.length !== days) {
    throw new HttpError(502, 'The AI returned an incomplete itinerary. Please regenerate.', 'incomplete_ai_response');
  }
  res.status(200).json({plan});
}, {secrets: [NVIDIA_API_KEY], timeoutSeconds: 90, memory: '512MiB'});

exports.incidentAnalyze = endpoint('incidentAnalyze', async (req, res, body) => {
  await authenticated(req, 'incidentAnalyze');
  const description = v.text(body.description, 'description', 2000, {min: 10});
  const locationLabel = v.optionalText(body.locationLabel, 'locationLabel', 200);
  const hasPhoto = body.hasPhoto === undefined ? false : v.bool(body.hasPhoto, 'hasPhoto');
  const hasVideo = body.hasVideo === undefined ? false : v.bool(body.hasVideo, 'hasVideo');
  const prompt = 'Triaging a traveller incident report. Description: """' + description + '""" ' +
    (locationLabel ? `Location context: ${locationLabel}. ` : '') +
    `Evidence attached: ${[hasPhoto ? 'photo' : null, hasVideo ? 'video' : null].filter(Boolean).join(' + ') || 'none'}. ` +
    'Return ONLY JSON with category, severity, summary and recommendedAction. ' +
    `category must be one of ${CATEGORIES.join('|')}; severity one of ${SEVERITIES.join('|')}. ` +
    'Be neutral and factual. Never claim authorities or emergency services were notified.';
  const parsed = await chatJson([
    {role: 'system', content: 'You output strict JSON only.'},
    {role: 'user', content: prompt},
  ], {maxTokens: 600, temperature: 0.1});
  const category = CATEGORIES.includes(parsed.category) ? parsed.category : 'other';
  const severity = SEVERITIES.includes(parsed.severity) ? parsed.severity : 'medium';
  const summary = typeof parsed.summary === 'string' ? parsed.summary.trim().slice(0, 500) : '';
  const recommendedAction = typeof parsed.recommendedAction === 'string' ? parsed.recommendedAction.trim().slice(0, 500) : '';
  if (!summary || !recommendedAction) {
    throw new HttpError(502, 'The AI triage response was incomplete. Please retry.', 'incomplete_ai_response');
  }
  res.status(200).json({category, severity, summary, recommendedAction});
}, {secrets: [NVIDIA_API_KEY], timeoutSeconds: 60, memory: '512MiB'});

/* -------------------------------- Weather ------------------------------- */

function weatherConditionLabel(value) {
  const description = typeof value?.description === 'string' ? value.description : 'Unknown';
  return description.charAt(0).toUpperCase() + description.slice(1);
}

async function weatherRequest(path, lat, lng) {
  const data = await fetchJson(`${OWM_URL}/${path}?lat=${lat}&lon=${lng}&units=metric&appid=${encodeURIComponent(weatherKey())}`);
  if (String(data.cod) !== '200') {
    throw new HttpError(502, 'No weather data is available for this location.', 'upstream_error');
  }
  return data;
}

exports.weatherCurrent = endpoint('weatherCurrent', async (req, res, body) => {
  await authenticated(req, 'weatherCurrent');
  const {lat, lng} = v.coordinates(body);
  const data = await weatherRequest('weather', lat, lng);
  if (!data.main || !Array.isArray(data.weather) || !data.weather.length) {
    throw new HttpError(502, 'The weather response was incomplete.', 'upstream_error');
  }
  res.status(200).json({current: {
    tempC: data.main.temp,
    feelsLikeC: data.main.feels_like,
    humidityPct: data.main.humidity,
    windMs: data.wind?.speed || 0,
    windDeg: data.wind?.deg || 0,
    condition: weatherConditionLabel(data.weather[0]),
    icon: data.weather[0]?.icon || '01d',
    pressureHpa: data.main.pressure,
    visibilityM: data.visibility || 0,
    updatedAt: new Date((data.dt || Date.now() / 1000) * 1000).toISOString(),
  }});
}, {secrets: [OPENWEATHER_API_KEY]});

exports.weatherForecast = endpoint('weatherForecast', async (req, res, body) => {
  await authenticated(req, 'weatherForecast');
  const {lat, lng} = v.coordinates(body);
  const data = await weatherRequest('forecast', lat, lng);
  if (!Array.isArray(data.list) || !data.list.length) {
    throw new HttpError(502, 'No forecast data is available for this location.', 'upstream_error');
  }
  const byDay = new Map();
  for (const item of data.list.slice(0, 40)) {
    const key = String(item.dt_txt || '').slice(0, 10);
    if (!key || !item.main) continue;
    const current = byDay.get(key) || {
      date: `${key}T12:00:00.000Z`,
      tempMaxC: -Infinity,
      tempMinC: Infinity,
      condition: weatherConditionLabel(item.weather?.[0]),
      icon: item.weather?.[0]?.icon || '01d',
      precipChancePct: 0,
    };
    current.tempMaxC = Math.max(current.tempMaxC, item.main.temp_max ?? item.main.temp);
    current.tempMinC = Math.min(current.tempMinC, item.main.temp_min ?? item.main.temp);
    current.precipChancePct = Math.max(current.precipChancePct, Math.round((item.pop || 0) * 100));
    byDay.set(key, current);
  }
  res.status(200).json({days: Array.from(byDay.values()).slice(0, 5)});
}, {secrets: [OPENWEATHER_API_KEY]});

/* ------------------------------ Google Places --------------------------- */

function functionBaseUrl(req) {
  const project = process.env.GOOGLE_CLOUD_PROJECT || process.env.GCLOUD_PROJECT || '';
  if (project) return `https://${REGION}-${project}.cloudfunctions.net`;
  const host = req.headers.host || '';
  if (/^(localhost|127\.0\.0\.1)(:\d+)?$/.test(host)) return `http://${host}`;
  throw new HttpError(500, 'The backend URL is not configured.', 'configuration_error');
}

function mapPlace(raw, base) {
  const location = raw?.geometry?.location;
  const lat = typeof location?.lat === 'function' ? location.lat() : location?.lat;
  const lng = typeof location?.lng === 'function' ? location.lng() : location?.lng;
  if (!Number.isFinite(lat) || !Number.isFinite(lng)) return null;
  const photos = Array.isArray(raw.photos) ? raw.photos.slice(0, 3).map((photo) => {
    const reference = photo.photo_reference || photo.photoReference || '';
    return reference ? `${base}/placesPhoto?photoreference=${encodeURIComponent(reference)}&maxwidth=1200` : null;
  }).filter(Boolean) : [];
  const hours = raw.opening_hours || raw.open_hours;
  return {
    placeId: raw.place_id || raw.placeId || '',
    name: typeof raw.name === 'string' ? raw.name.slice(0, 200) : 'Unknown place',
    lat,
    lng,
    address: raw.formatted_address || raw.vicinity || raw.formattedAddress || null,
    rating: typeof raw.rating === 'number' ? raw.rating : null,
    userRatingCount: typeof raw.user_ratings_total === 'number' ? raw.user_ratings_total : null,
    primaryType: Array.isArray(raw.types) && raw.types.length ? raw.types[0] : null,
    types: Array.isArray(raw.types) ? raw.types.filter((type) => typeof type === 'string').slice(0, 10) : [],
    photoUrls: photos,
    phone: raw.formatted_phone_number || raw.international_phone_number || raw.formattedPhoneNumber || null,
    website: raw.website || null,
    priceLevel: typeof raw.price_level === 'number' ? raw.price_level : null,
    openNow: typeof hours?.open_now === 'boolean' ? hours.open_now : null,
    provider: 'google',
  };
}

async function googlePlacesSearch(body, req) {
  const query = v.optionalText(body.query, 'query', 120);
  const hasLocation = body.location && typeof body.location === 'object' && !Array.isArray(body.location);
  const lat = hasLocation ? v.finiteNumber(body.location.lat, 'location.lat', -90, 90) : null;
  const lng = hasLocation ? v.finiteNumber(body.location.lng, 'location.lng', -180, 180) : null;
  const types = v.stringList(body.types, 'types', 3, 50, {required: false})
    .map((type) => {
      if (!/^[a-z_]+$/.test(type)) throw new HttpError(400, 'types contains an unsupported value.', 'invalid_argument');
      return type;
    });
  const radius = body.radiusMeters === undefined ? (hasLocation ? 25000 : null) :
    v.integer(body.radiusMeters, 'radiusMeters', 100, 50000);
  if (!query && !(hasLocation && types.length)) {
    throw new HttpError(400, 'Provide a query, or location and types.', 'invalid_argument');
  }
  const params = [];
  if (query) {
    params.push(`query=${encodeURIComponent(query)}`);
    if (hasLocation) {
      params.push(`location=${lat.toFixed(6)},${lng.toFixed(6)}`, `radius=${radius}`);
      if (types.length === 1) params.push(`type=${types[0]}`);
    }
  } else {
    params.push(`location=${lat.toFixed(6)},${lng.toFixed(6)}`, `radius=${radius}`, `type=${types[0]}`);
    if (types.length > 1) params.push(`keyword=${encodeURIComponent(types.slice(1).join(' '))}`);
  }
  const path = query ? 'textsearch' : 'nearbysearch';
  const data = await fetchJson(`${PLACES_URL}/${path}/json?${params.join('&')}&key=${encodeURIComponent(googleKey())}`);
  if (data.status === 'ZERO_RESULTS') return [];
  if (data.status !== 'OK' || !Array.isArray(data.results)) {
    throw new HttpError(502, 'Places search is temporarily unavailable.', 'upstream_error');
  }
  let places = data.results.slice(0, 30).map((place) => mapPlace(place, functionBaseUrl(req))).filter(Boolean);
  if (hasLocation) {
    places = places.map((place) => ({place, distance: haversineMeters(lat, lng, place.lat, place.lng)}))
      .sort((a, b) => a.distance - b.distance).map((entry) => entry.place);
  }
  return places.slice(0, 20);
}

exports.placesSearch = endpoint('placesSearch', async (req, res, body) => {
  await authenticated(req, 'placesSearch');
  res.status(200).json({places: await googlePlacesSearch(body, req)});
}, {secrets: [GOOGLE_MAPS_API_KEY]});

exports.placesDetails = endpoint('placesDetails', async (req, res, body) => {
  await authenticated(req, 'placesDetails');
  const placeId = v.text(body.placeId, 'placeId', 200);
  const data = await fetchJson(`${PLACES_URL}/details/json?place_id=${encodeURIComponent(placeId)}` +
    '&fields=name,formatted_address,geometry,rating,user_ratings_total,types,photos,formatted_phone_number,international_phone_number,website,price_level,opening_hours' +
    `&key=${encodeURIComponent(googleKey())}`);
  const place = data.status === 'OK' ? mapPlace(data.result, functionBaseUrl(req)) : null;
  if (!place) throw new HttpError(404, 'Place details were not found.', 'place_not_found');
  res.status(200).json({place});
}, {secrets: [GOOGLE_MAPS_API_KEY]});

exports.placesPhoto = endpoint('placesPhoto', async (req, res) => {
  await authenticated(req, 'placesPhoto');
  const reference = v.text(req.query?.photoreference, 'photoreference', 300);
  const maxwidth = req.query?.maxwidth === undefined ? 1200 : v.integer(Number(req.query.maxwidth), 'maxwidth', 1, 1600);
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 20000);
  try {
    const response = await fetch(`${PLACES_URL}/photo?photoreference=${encodeURIComponent(reference)}&maxwidth=${maxwidth}&key=${encodeURIComponent(googleKey())}`, {signal: controller.signal});
    const contentType = response.headers.get('content-type') || '';
    const declaredLength = Number(response.headers.get('content-length') || 0);
    if (!response.ok || !contentType.startsWith('image/') || declaredLength > 8 * 1024 * 1024) {
      throw new HttpError(502, 'The place photo is unavailable.', 'upstream_error');
    }
    const bytes = Buffer.from(await response.arrayBuffer());
    if (!bytes.length || bytes.length > 8 * 1024 * 1024) {
      throw new HttpError(502, 'The place photo was empty or too large.', 'upstream_error');
    }
    res.status(200).set({'Content-Type': contentType, 'Cache-Control': 'private, max-age=86400'}).send(bytes);
  } catch (error) {
    if (error instanceof HttpError) throw error;
    throw new HttpError(502, 'The place photo is unavailable.', 'upstream_error');
  } finally {
    clearTimeout(timer);
  }
}, {secrets: [GOOGLE_MAPS_API_KEY], methods: ['GET', 'POST']});

exports.emergencyNearby = endpoint('emergencyNearby', async (req, res, body) => {
  await authenticated(req, 'emergencyNearby');
  if (!body.location || typeof body.location !== 'object') {
    throw new HttpError(400, 'location is required.', 'invalid_argument');
  }
  const location = v.coordinates(body.location);
  const radius = body.radiusMeters === undefined ? 5000 : v.integer(body.radiusMeters, 'radiusMeters', 100, 20000);
  const types = ['hospital', 'police', 'fire_station'];
  const results = await Promise.allSettled(types.map((type) => googlePlacesSearch({location, radiusMeters: radius, types: [type]}, req)));
  const seen = new Set();
  let places = [];
  for (const result of results) {
    if (result.status !== 'fulfilled') continue;
    for (const place of result.value) {
      const id = place.placeId || `${place.lat},${place.lng}`;
      if (!seen.has(id)) {
        seen.add(id);
        places.push(place);
      }
    }
  }
  if (results.every((result) => result.status === 'rejected')) {
    throw new HttpError(502, 'Emergency-place search is temporarily unavailable.', 'upstream_error');
  }
  places = places.map((place) => ({place, distance: haversineMeters(location.lat, location.lng, place.lat, place.lng)}))
    .sort((a, b) => a.distance - b.distance).slice(0, 20).map((entry) => entry.place);
  res.status(200).json({places, partial: results.some((result) => result.status === 'rejected')});
}, {secrets: [GOOGLE_MAPS_API_KEY], timeoutSeconds: 45});

/* ------------------------------ Route/geocode --------------------------- */

async function googleRoute(origin, destination) {
  const data = await fetchJson('https://routes.googleapis.com/directions/v2:computeRoutes', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'x-goog-api-key': googleKey(),
      'X-Goog-FieldMask': 'routes.duration,routes.distanceMeters,routes.polyline.encodedPolyline',
    },
    body: JSON.stringify({
      origin: {location: {latLng: {latitude: origin.lat, longitude: origin.lng}}},
      destination: {location: {latLng: {latitude: destination.lat, longitude: destination.lng}}},
      travelMode: 'DRIVE',
      routingPreference: 'ROUTING_PREFERENCE_UNSPECIFIED',
      polylineEncoding: 'ENCODED_POLYLINE',
      computeAlternativeRoutes: false,
    }),
  });
  const route = Array.isArray(data.routes) ? data.routes[0] : null;
  const polyline = decodePolyline(route?.polyline?.encodedPolyline || '');
  if (!route || !polyline.length) throw new HttpError(502, 'No road route was returned.', 'upstream_error');
  return {
    distanceMeters: Number(route.distanceMeters) || 0,
    durationSeconds: Number.parseFloat(route.duration) || 0,
    polyline,
    provider: 'google',
  };
}

exports.route = endpoint('route', async (req, res, body) => {
  await authenticated(req, 'route');
  if (!body.origin || !body.destination) throw new HttpError(400, 'origin and destination are required.', 'invalid_argument');
  const origin = v.coordinates(body.origin);
  const destination = v.coordinates(body.destination);
  try {
    res.status(200).json(await googleRoute(origin, destination));
    return;
  } catch (error) {
    if (!(error instanceof HttpError) || !error.code.startsWith('upstream')) throw error;
  }
  const meters = haversineMeters(origin.lat, origin.lng, destination.lat, destination.lng) * 1.3;
  res.status(200).json({
    distanceMeters: Math.round(meters),
    durationSeconds: Math.round(meters / (30000 / 3600)),
    polyline: [origin, destination],
    provider: 'fallback',
    estimated: true,
  });
}, {secrets: [GOOGLE_MAPS_API_KEY]});

function buildLabel(components) {
  if (!Array.isArray(components)) return null;
  const find = (types) => components.find((component) => Array.isArray(component.types) && component.types.some((type) => types.includes(type)));
  const parts = [];
  const route = find(['route', 'neighborhood', 'sublocality_level_3']);
  const number = find(['street_number']);
  const locality = find(['locality']);
  const area = find(['administrative_area_level_1']);
  if (number && route) parts.push(`${route.short_name} ${number.short_name}`);
  else if (route) parts.push(route.short_name);
  if (locality) parts.push(locality.short_name);
  if (!parts.length && area) parts.push(area.short_name);
  return parts.filter(Boolean).join(', ').slice(0, 160) || null;
}

exports.geocodeReverse = endpoint('geocodeReverse', async (req, res, body) => {
  await authenticated(req, 'geocodeReverse');
  const {lat, lng} = v.coordinates(body);
  try {
    const data = await fetchJson(`https://maps.googleapis.com/maps/api/geocode/json?latlng=${lat},${lng}&key=${encodeURIComponent(googleKey())}`);
    const first = Array.isArray(data.results) ? data.results[0] : null;
    res.status(200).json({label: first ? buildLabel(first.address_components) : null});
  } catch (error) {
    if (!(error instanceof HttpError) || !error.code.startsWith('upstream')) throw error;
    res.status(200).json({label: null});
  }
}, {secrets: [GOOGLE_MAPS_API_KEY]});

/* ----------------------------- Account cleanup -------------------------- */

exports.deleteAccount = endpoint('deleteAccount', async (req, res) => {
  const uid = await authenticated(req, 'deleteAccount');
  const summary = await deleteAccount(admin, uid);
  res.status(200).json({deleted: true, ...summary});
}, {timeoutSeconds: 120, memory: '512MiB'});
