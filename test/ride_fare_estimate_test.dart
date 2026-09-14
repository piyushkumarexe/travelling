import 'package:flutter_test/flutter_test.dart';

import 'package:yatrawise/features/booking/booking_models.dart';

void main() {
  group('RideFareEstimates (public rate cards, deterministic)', () {
    test('short trip inside the included 1.5 km returns just the base band',
        () {
      final RideFareEstimate e = RideFareEstimates.estimate(
          providerId: 'rapido', serviceType: 'bike', km: 1.2)!;
      expect(e.low, 15);
      expect(e.high, 20);
    });

    test('bike scales with published per-km bands', () {
      // 8.5 km → 7 chargeable km: Rapido ₹6–9/km → low 15+42=57, high 20+63=83.
      final RideFareEstimate e = RideFareEstimates.estimate(
          providerId: 'rapido', serviceType: 'bike', km: 8.5)!;
      expect(e.low, 57);
      expect(e.high, 83);
    });

    test('auto uses the comparison band (₹25–30 + ₹9–14/km)', () {
      final RideFareEstimate e = RideFareEstimates.estimate(
          providerId: 'ola', serviceType: 'auto', km: 6)!;
      // 4.5 chargeable km → low 25 + ceil(40.5)=66, high 30 + ceil(63)=93.
      expect(e.low, 66);
      expect(e.high, 93);
    });

    test('cab uses government-approved rates as the upper band', () {
      final RideFareEstimate e = RideFareEstimates.estimate(
          providerId: 'uber', serviceType: 'cab', km: 10)!;
      // 8.5 chargeable km → low 37 + ceil(119)=156, high 45 + ceil(212.5)=258.
      expect(e.low, 156);
      expect(e.high, 258);
    });

    test('unknown service type → null (UI shows "Price unavailable")', () {
      expect(
        RideFareEstimates.estimate(
            providerId: 'uber', serviceType: 'spaceship', km: 5),
        isNull,
      );
    });

    test('bands are monotonic in distance and low ≤ high', () {
      for (final String type in <String>['bike', 'auto', 'cab']) {
        RideFareEstimate? prev;
        for (final double km in <double>[1, 3, 8, 20, 45]) {
          final RideFareEstimate e = RideFareEstimates.estimate(
              providerId: 'uber', serviceType: type, km: km)!;
          expect(e.low <= e.high, isTrue);
          if (prev != null) {
            expect(e.low >= prev.low, isTrue);
            expect(e.high >= prev.high, isTrue);
          }
          prev = e;
        }
      }
    });
  });

  group('Provider deep links (native schemes)', () {
    test('uber:// carries the same setPickup params as the universal link',
        () {
      final BookingQuery q = BookingQuery(
        fromName: 'Pickup',
        fromLat: 12.9716,
        fromLng: 77.5946,
        toName: 'Drop',
        toLat: 12.9352,
        toLng: 77.6245,
      );
      final String scheme = BookingProviders.uber.appDeepLinkBuilder!(q);
      expect(scheme.startsWith('uber://?action=setPickup'), isTrue);
      expect(scheme.contains('pickup[latitude]=12.971600'), isTrue);
      expect(scheme.contains('dropoff[longitude]=77.624500'), isTrue);

      final String web = BookingProviders.uber.webLinkBuilder!(q);
      expect(web.startsWith('https://m.uber.com/ul/?action=setPickup'), isTrue);
    });

    test('ola app scheme is the documented olacabs://app/launch endpoint',
        () {
      final BookingQuery q = BookingQuery(fromName: 'Pickup');
      expect(BookingProviders.ola.appDeepLinkBuilder!(q),
          'olacabs://app/launch');
      // The web flow still carries the coordinates.
      final BookingQuery q2 = BookingQuery(
        fromName: 'Pickup',
        fromLat: 12.9716,
        fromLng: 77.5946,
        toName: 'Drop',
        toLat: 12.9352,
        toLng: 77.6245,
      );
      final String web = BookingProviders.ola.webLinkBuilder!(q2);
      expect(web.startsWith('https://book.olacabs.com/?lat=12.971600'), isTrue);
      expect(web.contains('drop_lat=12.935200'), isTrue);
    });

    test('only providers with verified param-carrying schemes claim prefill',
        () {
      expect(BookingProviders.uber.appSchemePrefillsLocation, isTrue);
      expect(BookingProviders.ola.appSchemePrefillsLocation, isFalse);
      expect(BookingProviders.rapido.appSchemePrefillsLocation, isFalse);
    });
  });
}
