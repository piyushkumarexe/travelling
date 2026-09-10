import 'package:geolocator/geolocator.dart';

/// Wraps Geolocator with proper permission + service-state handling.
/// All denial paths are surfaced to the UI instead of silently failing.

class LocationService {
  Future<bool> isServiceEnabled() => Geolocator.isLocationServiceEnabled();

  Future<LocationPermission> checkPermission() => Geolocator.checkPermission();

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

  /// Best-effort current fix; returns null when unavailable (UI decides how
  /// to present that — no fake coordinates are ever fabricated).
  Future<Position?> currentPosition({
    Duration timeout = const Duration(seconds: 4),
  }) async {
    try {
      final bool serviceOn = await Geolocator.isLocationServiceEnabled();
      if (!serviceOn) return null;
      final LocationPermission p = await Geolocator.checkPermission();
      if (p == LocationPermission.denied ||
          p == LocationPermission.deniedForever) {
        return null;
      }

      // A cached GPS fix makes the dashboard and map available immediately.
      // Refresh briefly in the background path when no cached fix exists.
      final Position? cached = await Geolocator.getLastKnownPosition();
      if (cached != null &&
          DateTime.now().difference(cached.timestamp).abs() <
              const Duration(minutes: 10)) {
        return cached;
      }
      return await Geolocator.getCurrentPosition(
        locationSettings: LocationSettings(
          accuracy: LocationAccuracy.medium,
          timeLimit: timeout,
        ),
      ).timeout(timeout);
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
    );
  }
}
