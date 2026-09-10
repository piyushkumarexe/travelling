import 'dart:math' as math;

import 'package:google_maps_flutter/google_maps_flutter.dart';

/// Pure geometry helpers (unit-testable, no platform code).
library;

class GeoUtils {
  GeoUtils._();

  static const double earthRadiusM = 6371000;

  /// Haversine distance between two coordinates in meters.
  static double distanceMeters(LatLng a, LatLng b) =>
      distanceMetersLL(a.latitude, a.longitude, b.latitude, b.longitude);

  static double distanceMetersLL(
    double lat1,
    double lng1,
    double lat2,
    double lng2,
  ) {
    final double dLat = _rad(lat2 - lat1);
    final double dLng = _rad(lng2 - lng1);
    final double s = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_rad(lat1)) *
            math.cos(_rad(lat2)) *
            math.sin(dLng / 2) *
            math.sin(dLng / 2);
    return 2 * earthRadiusM * math.asin(math.min(1.0, math.sqrt(s)));
  }

  static bool isInsideCircle(
    LatLng point,
    LatLng center,
    double radiusMeters,
  ) =>
      distanceMeters(point, center) <= radiusMeters;

  static double _rad(double deg) => deg * math.pi / 180.0;

  static String formatDistance(double meters) {
    if (meters.isNaN) return '—';
    if (meters < 1000) return '${meters.round()} m';
    final double km = meters / 1000;
    if (km < 10) return '${km.toStringAsFixed(1)} km';
    return '${km.round()} km';
  }

  static String formatDuration(double seconds) {
    if (seconds.isNaN || seconds <= 0) return '—';
    final int s = seconds.round();
    final int h = s ~/ 3600;
    final int m = (s % 3600) ~/ 60;
    if (h > 0) return '${h}h ${m}m';
    if (m > 0) return '${m} min';
    return '${s} s';
  }
}
