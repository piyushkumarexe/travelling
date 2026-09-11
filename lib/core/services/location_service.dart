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

  Future<bool> isServiceEnabled() => Geolocator.isLocationServiceEnabled();

  Future<LocationPermission> checkPermission() => Geolocator.checkPermission();

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
      // Refresh in the background for a more precise fix.
      unawaited(_obtainFresh());
      return recent;
    }
    return _obtainFresh(timeout: timeout);
  }

  Future<Position?> _obtainFresh({Duration timeout = const Duration(seconds: 8)}) async {
    try {
      final bool serviceOn = await Geolocator.isLocationServiceEnabled();
      if (!serviceOn) return await lastKnown();
      LocationPermission p = await Geolocator.checkPermission();
      if (p == LocationPermission.denied) {
        p = await Geolocator.requestPermission();
      }
      if (p == LocationPermission.denied ||
          p == LocationPermission.deniedForever) {
        return await lastKnown();
      }
      // Try progressively more tolerant settings — a cold GPS can take longer
      // than a single best-accuracy attempt allows.
      for (final (LocationAccuracy accuracy, int seconds, bool forceManager)
          in const <(LocationAccuracy, int, bool)>[
        (LocationAccuracy.best, 10, false),
        (LocationAccuracy.high, 12, false),
        (LocationAccuracy.medium, 15, false),
        (LocationAccuracy.high, 20, true), // OS location manager fallback
      ]) {
        try {
          final Position pos = await Geolocator.getCurrentPosition(
            locationSettings: LocationSettings(
              accuracy: accuracy,
              timeLimit: Duration(seconds: seconds),
              forceLocationManager: forceManager,
            ),
          ).timeout(Duration(seconds: seconds + 2));
          _cached = pos;
          await _writeCache(pos);
          return pos;
        } catch (_) {
          // Next tier.
        }
      }
      return await lastKnown();
    } catch (_) {
      return await lastKnown();
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
