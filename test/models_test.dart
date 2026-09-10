import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import 'package:roamio/data/models/digital_id.dart';
import 'package:roamio/data/models/places.dart';
import 'package:roamio/data/models/weather.dart';

void main() {
  group('DigitalId token', () {
    test('generateToken produces 64 hex chars', () {
      final String t = DigitalId.generateToken();
      expect(t.length, 64);
      expect(DigitalId.isValidTokenShape(t), isTrue);
    });

    test('tokens are unique', () {
      expect(DigitalId.generateToken(), isNot(DigitalId.generateToken()));
    });

    test('isValidTokenShape rejects bad shapes', () {
      expect(DigitalId.isValidTokenShape('abc'), isFalse);
      expect(DigitalId.isValidTokenShape('Z' * 64), isFalse);
      expect(DigitalId.isValidTokenShape('a' * 63), isFalse);
      expect(DigitalId.isValidTokenShape(''), isFalse);
    });
  });

  group('Place classification', () {
    test('tourist attraction', () {
      final Place p = Place(
          placeId: 'x', name: 'Taj', lat: 0, lng: 0,
          types: const <String>['tourist_attraction', 'point_of_interest']);
      expect(p.isTourist, isTrue);
      expect(p.isFood, isFalse);
    });

    test('restaurant is food, not tourist', () {
      final Place p = Place(placeId: 'x', name: 'R', lat: 0, lng: 0,
          types: const <String>['restaurant']);
      expect(p.isFood, isTrue);
      expect(p.isTourist, isFalse);
    });

    test('hospital is emergency', () {
      final Place p = Place(placeId: 'x', name: 'H', lat: 0, lng: 0,
          types: const <String>['hospital', 'point_of_interest']);
      expect(p.isEmergency, isTrue);
    });
  });

  group('RouteInfo.fromJson', () {
    test('decodes point list and provider', () {
      final RouteInfo r = RouteInfo.fromJson(<String, dynamic>{
        'distanceMeters': 1200,
        'durationSeconds': 300,
        'polyline': <Map<String, dynamic>>[
          <String, dynamic>{'lat': 1.0, 'lng': 2.0},
          <String, dynamic>{'lat': 1.1, 'lng': 2.1},
        ],
        'provider': 'google',
      });
      expect(r.polyline.length, 2);
      expect(r.polyline.first, LatLng(1.0, 2.0));
      expect(r.isApproximate, isFalse);
    });

    test('fallback provider flagged approximate', () {
      final RouteInfo r = RouteInfo.fromJson(<String, dynamic>{
        'distanceMeters': 500,
        'durationSeconds': 60,
        'polyline': <Map<String, dynamic>>[],
        'provider': 'fallback',
      });
      expect(r.isApproximate, isTrue);
      expect(r.polyline, isEmpty);
    });
  });

  group('WeatherCurrent.fromJson', () {
    test('parses a backend payload', () {
      final WeatherCurrent c = WeatherCurrent.fromJson(<String, dynamic>{
        'tempC': 31.2,
        'feelsLikeC': 33.0,
        'humidityPct': 60,
        'windMs': 3.5,
        'windDeg': 240,
        'condition': 'Light rain',
        'icon': '10d',
        'pressureHpa': 1005,
        'visibilityM': 8000,
        'updatedAt': '2026-09-10T10:00:00.000Z',
      });
      expect(c.tempC, 31.2);
      expect(c.icon, '10d');
      expect(c.updatedAt, isNotNull);
    });
  });
}
