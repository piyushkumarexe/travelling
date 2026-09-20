import 'dart:async';
import 'dart:convert';

import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Wraps Geolocator with proper permission + service-state handling.
/// All denial paths are surfaced to the UI instead of silently failing.
///
/// Also keeps the last known fix in memory + on-device cache, so screens open
/// instantly with a recent position while a fresh fix is obtained in the
/// background.
class LocationService {
  Position? _cached;
  Future<Position?>? _freshInFlight;

  Future<bool> isServiceEnabled() => Geolocator.isLocationServiceEnabled();

  Future<LocationPermission> checkPermission() => Geolocator.checkPermission();

  /// Shared location-manager surface (one service, used by every screen):
  /// fresh fix, cached/last-known fix, and a live position stream.
  Future<Position?> getCurrentLocation({Duration timeout = const Duration(seconds: 8)}) =>
      currentPosition(timeout: timeout);

  Future<Position?> getLastKnownLocation() => lastKnown();

  Stream<Position> subscribeToLocation({
    int distanceFilter = 0,
    LocationAccuracy accuracy = LocationAccuracy.best,
  }) =>
      watchPosition(distanceFilter: distanceFilter, accuracy: accuracy);

  /// Requests location permission (without opening system settings — for
  /// app-start warm-up). Returns the resulting permission.
  Future<LocationPermission> requestPermission() async {
    LocationPermission p = await Geolocator.checkPermission();
    if (p == LocationPermission.denied) {
      p = await Geolocator.requestPermission();
    }
    return p;
  }

  /// Requests location permission, opening system settings when the user
  /// has denied it (or permanently). Returns the resulting permission.
  Future<LocationPermission> ensurePermission() async {
    final bool serviceOn = await Geolocator.isLocationServiceEnabled();
    if (!serviceOn) {
      await Geolocator.openLocationSettings();
      return LocationPermission.denied;
    }
    LocationPermission p = await Geolocator.checkPermission();
    if (p == LocationPermission.denied) {
      p = await Geolocator.requestPermission();
      if (p == LocationPermission.denied) {
        p = await Geolocator.requestPermission();
      }
    }
    if (p == LocationPermission.deniedForever || p == LocationPermission.denied) {
      await Geolocator.openAppSettings();
    }
    return p;
  }

  /// The last known position (memory, then on-device cache). Instant, so
  /// screens never have to wait for a cold GPS fix.
  Future<Position?> lastKnown() async {
    if (_cached != null) return _cached;
    try {
      Position? pos = await Geolocator.getLastKnownPosition();
      if (pos != null) {
        _cached = pos;
        return pos;
      }
    } catch (_) {}
    return await _readCache();
  }

  /// Best-effort current fix. Returns instantly when a recent known fix is
  /// available; otherwise obtains one with a short timeout. Auto-requests
  /// permission when it has never been asked yet. Never fabricates coords.
  Future<Position?> currentPosition({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    // Instant: use a recent cached fix so the app never stalls on startup.
    final Position? recent = await lastKnown();
    if (recent != null &&
        DateTime.now().difference(recent.timestamp).inSeconds < 120) {
      // Refresh in the background for a more precise fix. The in-flight future
      // is shared so a screen that needs accuracy can await this same refresh
      // instead of starting a second GPS request.
      unawaited(refreshPosition(timeout: timeout));
      return recent;
    }
    return refreshPosition(timeout: timeout);
  }

  /// Obtains a fresh GPS fix, deduplicating callers during the same refresh.
  /// A recent cached fix is intentionally not returned here: this method is
  /// the explicit accuracy path used when nearby results must follow the
  /// current device position.
  ///
  /// The [timeout] is a HARD cap on the whole attempt: the old
  /// implementation accepted the parameter but never enforced it, so a cold
  /// start indoors could block Nearby for 30+ seconds while the map's blue
  /// dot sat there perfectly rendered. Callers that need a guaranteed-fast
  /// answer combine this with [bestRecentFix].
  Future<Position?> refreshPosition({
    Duration timeout = const Duration(seconds: 8),
  }) {
    final Future<Position?>? pending = _freshInFlight;
    if (pending != null) return pending;
    final Future<Position?> request = _obtainFresh(timeout: timeout)
        .timeout(timeout, onTimeout: () => null);
    _freshInFlight = request;
    return request.whenComplete(() {
      if (identical(_freshInFlight, request)) _freshInFlight = null;
    });
  }

  /// The best recent fix without waiting for GPS: the in-memory/last-known
  /// position when it is younger than [maxAge]. This is the graceful
  /// degradation path for "Nearby": the Google map already shows the user's
  /// live blue dot (Play-services fused location), so refusing to run a
  /// nearby search just because a COLD fix takes longer than the timeout
  /// made "Nearby" look broken while the map demonstrably knew the position.
  Future<Position?> bestRecentFix({
    Duration maxAge = const Duration(minutes: 15),
  }) async {
    final Position? pos = await lastKnown();
    if (pos == null) return null;
    final DateTime t = pos.timestamp;
    if (DateTime.now().difference(t).abs() > maxAge) return null;
    return pos;
  }

  /// Precision target: a fix at or better than this is accepted INSTANTLY.
  /// Coarser fixes are only used when the timeout expires — but even then
  /// the BEST (smallest reported error) fix seen is returned, never an
  /// arbitrary first emission.
  static const double _acceptableAccuracyMeters = 50;

  Future<Position?> _obtainFresh({Duration timeout = const Duration(seconds: 8)}) async {
    try {
      final bool serviceOn = await Geolocator.isLocationServiceEnabled();
      if (!serviceOn) return null;
      LocationPermission p = await Geolocator.checkPermission();
      if (p == LocationPermission.denied) {
        p = await Geolocator.requestPermission();
      }
      if (p == LocationPermission.denied ||
          p == LocationPermission.deniedForever) {
        return null;
      }
      // Accuracy-aware collection on the fused position stream:
      //   - the stream's first emission is often a coarse NETWORK fix
      //     (±100–500 m — this used to be returned blindly, which made
      //     "current location" jump around and put nearby/search results
      //     in the wrong street or even the wrong city);
      //   - a fix already within [_acceptableAccuracyMeters] is returned
      //     instantly (fast path, same behaviour as before for good GPS);
      //   - otherwise we keep listening within the HARD timeout, tracking
      //     the best (smallest error) fix seen, and return that — the GPS
      //     fix typically arrives within 2–6 s of the network fix.
      // At the deadline we return the best fix seen (even coarse — callers
      // like the SOS path label honesty via age/accuracy) or null when
      // nothing was emitted.
      final Completer<Position?> accepted = Completer<Position?>();
      Position? best;
      final StreamSubscription<Position> sub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.best,
          distanceFilter: 0,
        ),
      ).listen((Position p) {
        if (best == null || (p.accuracy > 0 && p.accuracy < best.accuracy)) {
          best = p;
        }
        if (p.accuracy <= _acceptableAccuracyMeters && !accepted.isCompleted) {
          accepted.complete(p);
        }
      }, onError: (Object _) {});

      final Position? result = await accepted.future.timeout(
        timeout,
        onTimeout: () => best,
      );
      await sub.cancel();
      if (result != null) {
        _cached = result;
        await _writeCache(result);
        return result;
      }
      // No stream emission in time — the legacy blocking tiers as a last
      // resort (bounded so the hard cap still holds).
      for (final (LocationAccuracy accuracy, int seconds, bool forceManager)
          in const <(LocationAccuracy, int, bool)>[
        (LocationAccuracy.best, 10, false),
        (LocationAccuracy.high, 10, true), // OS location manager fallback
      ]) {
        try {
          final LocationSettings settings = forceManager
              ? AndroidSettings(
                  accuracy: accuracy,
                  timeLimit: Duration(seconds: seconds),
                  forceLocationManager: true,
                )
              : LocationSettings(
                  accuracy: accuracy,
                  timeLimit: Duration(seconds: seconds),
                );
          final Position pos = await Geolocator.getCurrentPosition(
            locationSettings: settings,
          ).timeout(Duration(seconds: seconds + 2));
          _cached = pos;
          await _writeCache(pos);
          return pos;
        } catch (_) {
          // Next tier.
        }
      }
      // An explicit fresh request must not silently downgrade to a cached
      // coordinate. Callers can still use [currentPosition] for a fast
      // last-known fix, but nearby refreshes need a clear unavailable result.
      return null;
    } catch (_) {
      return null;
    }
  }

  Stream<Position> watchPosition({
    int distanceFilter = 0,
    LocationAccuracy accuracy = LocationAccuracy.best,
  }) {
    return Geolocator.getPositionStream(
      locationSettings: LocationSettings(
        accuracy: accuracy,
        distanceFilter: distanceFilter,
      ),
    ).map((Position p) {
      _cached = p;
      unawaited(_writeCache(p));
      return p;
    });
  }

  // ---- on-device cache (instant cold start) ----
  static const String _cacheKey = 'last_known_position';

  Future<Position?> _readCache() async {
    try {
      final SharedPreferences p = await SharedPreferences.getInstance();
      final String? raw = p.getString(_cacheKey);
      if (raw == null) return null;
      final Map<String, dynamic> m =
          (jsonDecode(raw) as Map).map((Object? k, Object? v) =>
              MapEntry(k.toString(), v));
      return Position.fromMap(m);
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeCache(Position pos) async {
    try {
      final SharedPreferences p = await SharedPreferences.getInstance();
      await p.setString(_cacheKey, jsonEncode(pos.toJson()));
    } catch (_) {}
  }
}
