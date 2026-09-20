import 'package:flutter_test/flutter_test.dart';

import 'package:yatrawise/features/booking/booking_models.dart';

void main() {
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
