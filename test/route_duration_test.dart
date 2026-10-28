import 'package:flutter_test/flutter_test.dart';
import 'package:tourism/core/network/osrm_client.dart';

void main() {
  group('mode-aware route duration', () {
    test('159 metre walk is not reported with driving-speed ETA', () {
      final double seconds = OsrmClient.durationForMode(
        mode: 'walk',
        distanceMeters: 159,
        providerDurationSeconds: 27,
      );

      expect(seconds, closeTo(122.31, 0.1));
      expect(seconds, greaterThan(120));
    });

    test('cycling gets a realistic minimum duration', () {
      final double seconds = OsrmClient.durationForMode(
        mode: 'bike',
        distanceMeters: 4200,
        providerDurationSeconds: 300,
      );

      expect(seconds, 1000);
    });

    test('slower provider duration is preserved', () {
      final double seconds = OsrmClient.durationForMode(
        mode: 'walk',
        distanceMeters: 100,
        providerDurationSeconds: 180,
      );

      expect(seconds, 180);
    });

    test('driving duration remains provider-derived', () {
      final double seconds = OsrmClient.durationForMode(
        mode: 'car',
        distanceMeters: 159,
        providerDurationSeconds: 27,
      );

      expect(seconds, 27);
    });
  });
}
