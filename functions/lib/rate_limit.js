'use strict';

const {HttpError} = require('./http');

const MINUTE_LIMITS = {
  chat: 12,
  itinerary: 6,
  incidentAnalyze: 12,
  weatherCurrent: 60,
  weatherForecast: 60,
  placesSearch: 60,
  placesDetails: 60,
  placesPhoto: 180,
  emergencyNearby: 30,
  route: 40,
  geocodeReverse: 40,
  deleteAccount: 5,
};

const DAILY_LIMITS = {
  chat: 100,
  itinerary: 25,
  incidentAnalyze: 40,
  placesPhoto: 1500,
  directions: 500,
  geocode: 500,
  deleteAccount: 10,
};

function createRateLimiter(admin) {
  const db = admin.firestore();
  return async (uid, bucket) => {
    const now = Date.now();
    const minute = Math.floor(now / 60000);
    const day = new Date(now).toISOString().slice(0, 10);
    const perMinute = MINUTE_LIMITS[bucket] || 120;
    const perDay = DAILY_LIMITS[bucket] || 5000;
    const minuteRef = db.collection('rateLimits').doc(`${uid}_${bucket}_${minute}`);
    const dayRef = db.collection('rateLimits').doc(`${uid}_${bucket}_${day}`);
    try {
      await db.runTransaction(async (transaction) => {
        const [minuteSnap, daySnap] = await Promise.all([
          transaction.get(minuteRef),
          transaction.get(dayRef),
        ]);
        const minuteCount = minuteSnap.exists ? Number(minuteSnap.data().count || 0) : 0;
        const dayCount = daySnap.exists ? Number(daySnap.data().count || 0) : 0;
        if (minuteCount >= perMinute || dayCount >= perDay) {
          throw new HttpError(
            429,
            'Too many requests. Please wait and try again.',
            'rate_limited',
          );
        }
        const metadata = {
          uid,
          bucket,
          count: (minuteCount || 0) + 1,
          expiresAt: admin.firestore.Timestamp.fromMillis((minute + 2) * 60000),
        };
        transaction.set(minuteRef, metadata);
        transaction.set(dayRef, {
          uid,
          bucket,
          count: dayCount + 1,
          expiresAt: admin.firestore.Timestamp.fromMillis(now + 26 * 3600000),
        });
      });
    } catch (error) {
      if (error instanceof HttpError) throw error;
      // Fail closed for expensive provider endpoints; silently allowing an
      // unavailable limiter would remove abuse and cost controls.
      throw new HttpError(503, 'Usage limits are temporarily unavailable. Please try again.', 'rate_limit_unavailable');
    }
  };
}

module.exports = {createRateLimiter, MINUTE_LIMITS, DAILY_LIMITS};
