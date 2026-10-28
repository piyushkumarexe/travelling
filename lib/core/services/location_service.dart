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

  // GPS streams can emit every second. Persisting every fix opened
  // SharedPreferences and rewrote JSON for every listener, creating needless
  // flash I/O and UI-isolate work. Memory is updated immediately; disk is
  // coalesced to one latest fix per interval.
  static const Duration _cachePersistInterval = Duration(seconds: 15);
  final Future<SharedPreferences> _preferences =
      SharedPreferences.getInstance();
  Timer? _cachePersistTimer;
  Position? _pendingCachePersist;
  DateTime? _lastCachePersistedAt;

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
    if (timeout <= Duration.zero) return Future<Position?>.value(null);
    final Future<Position?>? pending = _freshInFlight;
    if (pending != null) {
      return pending.timeout(timeout, onTimeout: () => null);
    }
    final DateTime deadline = DateTime.now().add(timeout);
    final Future<Position?> request = _obtainFresh(deadline: deadline)
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

  Future<Position?> _obtainFresh({required DateTime deadline}) async {
    Duration remaining() {
      final Duration value = deadline.difference(DateTime.now());
      return value.isNegative ? Duration.zero : value;
    }
    bool expired() => remaining() <= Duration.zero;

    try {
      if (expired()) return null;
      final bool serviceOn = await Geolocator.isLocationServiceEnabled()
          .timeout(remaining(), onTimeout: () => false);
      if (!serviceOn || expired()) return null;
      LocationPermission p = await Geolocator.checkPermission()
          .timeout(remaining(), onTimeout: () => LocationPermission.denied);
      if (p == LocationPermission.denied && !expired()) {
        p = await Geolocator.requestPermission()
            .timeout(remaining(), onTimeout: () => LocationPermission.denied);
      }
      if (p == LocationPermission.denied ||
          p == LocationPermission.deniedForever ||
          expired()) {
        return null;
      }

      final Completer<Position?> accepted = Completer<Position?>();
      Position? best;
      final StreamSubscription<Position> sub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.best,
          distanceFilter: 0,
        ),
      ).listen((Position position) {
        final Position? previousBest = best;
        if (previousBest == null ||
            (position.accuracy > 0 &&
                position.accuracy < previousBest.accuracy)) {
          best = position;
        }
        if (position.accuracy <= _acceptableAccuracyMeters &&
            !accepted.isCompleted) {
          accepted.complete(position);
        }
      }, onError: (Object _) {});

      Position? result;
      if (!expired()) {
        result = await accepted.future.timeout(
          remaining(),
          onTimeout: () => best,
        );
      }
      // Do not let stream teardown or disk I/O extend the caller's deadline.
      unawaited(sub.cancel());
      if (result != null) {
        _cached = result;
        unawaited(_persistCacheNow(result));
        return result;
      }

      // Legacy fused/OS-manager tiers share the SAME deadline. They never
      // receive a fresh 10–12 second budget after the stream has timed out.
      for (final (LocationAccuracy accuracy, bool forceManager)
          in const <(LocationAccuracy, bool)>[
        (LocationAccuracy.best, false),
        (LocationAccuracy.high, true),
      ]) {
        if (expired()) break;
        final Duration left = remaining();
        const Duration tierCap = Duration(seconds: 10);
        final Duration budget = left > tierCap ? tierCap : left;
        try {
          final LocationSettings settings = forceManager
              ? AndroidSettings(
                  accuracy: accuracy,
                  timeLimit: budget,
                  forceLocationManager: true,
                )
              : LocationSettings(accuracy: accuracy, timeLimit: budget);
          final Position pos = await Geolocator.getCurrentPosition(
            locationSettings: settings,
          ).timeout(budget);
          _cached = pos;
          unawaited(_persistCacheNow(pos));
          return pos;
        } catch (_) {
          // Try the next tier only if the original deadline still has time.
        }
      }
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
      _scheduleCachePersist(p);
      return p;
    });
  }

  void _scheduleCachePersist(Position position) {
    _pendingCachePersist = position;
    final DateTime now = DateTime.now();
    final DateTime? last = _lastCachePersistedAt;
    final Duration elapsed =
        last == null ? _cachePersistInterval : now.difference(last);
    if (elapsed >= _cachePersistInterval && _cachePersistTimer == null) {
      final Position latest = _pendingCachePersist!;
      _pendingCachePersist = null;
      _lastCachePersistedAt = now;
      unawaited(_writeCache(latest));
      return;
    }
    if (_cachePersistTimer != null) return;
    final Duration delay = _cachePersistInterval - elapsed;
    _cachePersistTimer = Timer(delay, () {
      _cachePersistTimer = null;
      final Position? latest = _pendingCachePersist;
      _pendingCachePersist = null;
      if (latest == null) return;
      _lastCachePersistedAt = DateTime.now();
      unawaited(_writeCache(latest));
    });
  }

  Future<void> _persistCacheNow(Position position) async {
    _cachePersistTimer?.cancel();
    _cachePersistTimer = null;
    _pendingCachePersist = null;
    _lastCachePersistedAt = DateTime.now();
    await _writeCache(position);
  }

  // ---- on-device cache (instant cold start) ----
  static const String _cacheKey = 'last_known_position';

  Future<Position?> _readCache() async {
    try {
      final SharedPreferences p = await _preferences;
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
      final SharedPreferences p = await _preferences;
      await p.setString(_cacheKey, jsonEncode(pos.toJson()));
    } catch (_) {}
  }
}
