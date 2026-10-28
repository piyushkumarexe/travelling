import 'package:flutter_test/flutter_test.dart';

import 'package:yatrawise/data/models/weather.dart';

WeatherCurrent w({
  double temp = 25,
  double windMs = 5,
  int humidity = 40,
  double visibility = 10000,
}) =>
    WeatherCurrent(
      tempC: temp,
      feelsLikeC: temp + 1,
      humidityPct: humidity,
      windMs: windMs,
      windDeg: 90,
      condition: 'Clear',
      icon: '01d',
      pressureHpa: 1013,
      visibilityM: visibility,
      updatedAt: DateTime(2026, 1, 1),
    );

void main() {
  group('weatherSafetyNotes', () {
    test('comfortable default', () {
      final List<String> notes = weatherSafetyNotes(w());
      expect(notes.length, 1);
      expect(notes.first, contains('comfortable'));
    });

    test('extreme heat at 38C', () {
      expect(weatherSafetyNotes(w(temp: 38)).first, contains('Extreme heat'));
    });

    test('hot day at 32C', () {
      expect(weatherSafetyNotes(w(temp: 32)).first, contains('Hot day'));
    });

    test('freezing at 0C', () {
      expect(weatherSafetyNotes(w(temp: 0)).first, contains('Freezing'));
    });

    test('cold at 4C', () {
      expect(weatherSafetyNotes(w(temp: 4)).any((String n) =>
        n.contains('Cold day')), isTrue);
    });

    test('strong wind at 40 km/h (11.11 m/s)', () {
      expect(weatherSafetyNotes(w(windMs: 11.11)).any((String n) =>
        n.contains('Strong winds')), isTrue);
    });

    test('high heat index (hot + humid)', () {
      final List<String> notes = weatherSafetyNotes(
          w(temp: 30, humidity: 85));
      expect(notes.any((String n) => n.contains('heat index')), isTrue);
    });

    test('reduced visibility under 1000 m', () {
      expect(weatherSafetyNotes(w(visibility: 500)).any((String n) =>
        n.contains('Reduced visibility')), isTrue);
    });

    test('multiple notes stack', () {
      final List<String> notes =
          weatherSafetyNotes(w(temp: 38, windMs: 12, visibility: 400));
      expect(notes.length, greaterThanOrEqualTo(3));
    });
  });
}
