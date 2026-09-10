import 'package:geolocator/geolocator.dart';

/// Wraps Geolocator with proper permission + service-state handling.
/// All denial paths are surfaced to the UI instead of silently failing.
library;

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
    Duration timeout = const Duration(seconds: 15),
  }) async {
    try {
      final bool serviceOn = await Geolocator.isLocationServiceEnabled();
      if (!serviceOn) return null;
      final LocationPermission p = await Geolocator.checkPermission();
      if (p == LocationPermission.denied ||
          p == LocationPermission.deniedForever) {
        return null;
      }
      return await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.best,
          timeLimit: Duration(seconds: 15),
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
