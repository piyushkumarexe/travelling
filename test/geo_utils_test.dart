import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import 'package:roamio/core/utils/geo.dart';

void main() {
  group('GeoUtils.distanceMeters', () {
    test('zero distance for identical points', () {
      final LatLng a = LatLng(28.6139, 77.2090);
      expect(GeoUtils.distanceMeters(a, a), 0);
    });

    test('known ~1 km segment (equator-ish)', () {
      // ~0.008993 deg longitude at 0 lat ≈ 1000 m
      final LatLng a = LatLng(0, 0);
      final LatLng b = LatLng(0, 0.008993);
      final double d = GeoUtils.distanceMeters(a, b);
      expect(d, greaterThan(950));
      expect(d, lessThan(1050));
    });

    test('Delhi–Jaipur straight-line distance is roughly 235 km', () {
      final LatLng delhi = LatLng(28.6139, 77.2090);
      final LatLng jaipur = LatLng(26.9124, 75.7873);
      final double d = GeoUtils.distanceMeters(delhi, jaipur);
      // GeoUtils calculates great-circle distance, not the longer road route.
      expect(d, greaterThan(230000));
      expect(d, lessThan(240000));
    });
  });

  group('GeoUtils.isInsideCircle', () {
    test('point at center is inside', () {
      final LatLng c = LatLng(28.6139, 77.2090);
      expect(GeoUtils.isInsideCircle(c, c, 1000), isTrue);
    });

    test('point 2 km away is outside a 1 km radius', () {
      final LatLng c = LatLng(0, 0);
      final LatLng p = LatLng(0, 0.018); // ~2 km
      expect(GeoUtils.isInsideCircle(p, c, 1000), isFalse);
    });
  });

  group('GeoUtils.formatDistance', () {
    test('meters below 1000', () {
      expect(GeoUtils.formatDistance(250), contains('250'));
    });

    test('kilometers above 1000', () {
      expect(GeoUtils.formatDistance(1500), contains('1.5'));
    });
  });

  group('GeoUtils.formatDuration', () {
    test('minutes for small values', () {
      expect(GeoUtils.formatDuration(90), isNotNull);
    });

    test('hours for long values', () {
      expect(GeoUtils.formatDuration(7200), contains('2'));
    });
  });
}
