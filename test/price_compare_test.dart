import 'package:flutter_test/flutter_test.dart';

import 'package:yatrawise/features/booking/booking_models.dart';
import 'package:yatrawise/features/booking/price_compare.dart';

/// Locks the behaviour the "one tap price comparison" promise rests on:
/// deterministic numbers, honest confidence, cheapest-first ordering and a
/// trip budget that actually adds up.
BookingQuery rideQuery() => const BookingQuery(
      fromName: 'Hazratganj',
      fromLat: 26.85,
      fromLng: 80.94,
      toName: 'Charbagh',
      toLat: 26.83,
      toLng: 80.92,
      serviceType: 'cab',
    );

BookingQuery cityQuery() => const BookingQuery(
      fromName: 'Lucknow',
      toName: 'Varanasi',
      date: '2026-10-20',
      passengers: 2,
    );

void main() {
  group('PriceCompare — rides', () {
    test('every ride platform is quoted, cheapest first', () {
      final List<PlatformQuote> q = PriceCompare.forRide(
        providers: BookingProviders.forCategory(BookingCategory.ride),
        query: rideQuery(),
        distanceKm: 8.4,
        minutes: 24,
      );
      expect(q.length, 3);
      expect(q.map((PlatformQuote e) => e.providerId).toSet(),
          <String>{'uber', 'ola', 'rapido'});
      for (final PlatformQuote e in q) {
        expect(e.hasPrice, isTrue, reason: 'a known distance must be priced');
        expect(e.confidence, PriceConfidence.high);
      }
      // The comparison is only useful if it is sorted by price.
      for (int i = 1; i < q.length; i++) {
        expect(q[i - 1].mid, lessThanOrEqualTo(q[i].mid));
      }
    });

    test('the model is deterministic and the basis shows the arithmetic', () {
      final List<PlatformQuote> a = PriceCompare.forRide(
        providers: <BookingProvider>[BookingProviders.ola],
        query: rideQuery(),
        distanceKm: 10,
        minutes: 30,
      );
      final List<PlatformQuote> b = PriceCompare.forRide(
        providers: <BookingProvider>[BookingProviders.ola],
        query: rideQuery(),
        distanceKm: 10,
        minutes: 30,
      );
      expect(a.single.low, b.single.low);
      expect(a.single.high, b.single.high);
      expect(a.single.basis, contains('10.0 km'));
      expect(a.single.basis, contains('₹19/km'));
    });

    test('a short hop is never quoted below the minimum fare', () {
      final List<PlatformQuote> q = PriceCompare.forRide(
        providers: <BookingProvider>[BookingProviders.ola],
        query: rideQuery(),
        distanceKm: 0.2,
        minutes: 1,
      );
      expect(q.single.low, greaterThanOrEqualTo(110),
          reason: 'the ₹130 cab minimum must survive the -15% low band');
    });

    test('reported 2.1 km auto case has a realistic wide planning range', () {
      final PlatformQuote q = PriceCompare.forRide(
        providers: <BookingProvider>[BookingProviders.ola],
        query: rideQuery(),
        distanceKm: 2.1,
        minutes: 5,
        vehicle: 'auto',
        pricedAt: DateTime(2026, 9, 24, 21, 53),
      ).single;
      expect(q.low, greaterThanOrEqualTo(75),
          reason: 'must not repeat the screenshot\'s unrealistic ₹50 floor');
      expect(q.high, greaterThanOrEqualTo(120),
          reason: 'range must leave room for demand/pickup/platform pricing');
      expect(q.confidence.label, 'Route-based range');
    });

    test('learned actual fares calibrate that provider only', () {
      final List<PlatformQuote> base = PriceCompare.forRide(
        providers: const <BookingProvider>[
          BookingProviders.ola,
          BookingProviders.uber,
        ],
        query: rideQuery(),
        distanceKm: 5,
        minutes: 15,
        vehicle: 'auto',
        pricedAt: DateTime(2026, 9, 24, 14),
      );
      final List<PlatformQuote> learned = PriceCompare.forRide(
        providers: const <BookingProvider>[
          BookingProviders.ola,
          BookingProviders.uber,
        ],
        query: rideQuery(),
        distanceKm: 5,
        minutes: 15,
        vehicle: 'auto',
        learnedFactors: const <String, double>{'ola': 1.5},
        pricedAt: DateTime(2026, 9, 24, 14),
      );
      int mid(List<PlatformQuote> q, String id) =>
          q.firstWhere((PlatformQuote e) => e.providerId == id).mid;
      expect(mid(learned, 'ola'), greaterThan(mid(base, 'ola')));
      expect(mid(learned, 'uber'), mid(base, 'uber'));
    });

    test('without a distance every platform still appears, unpriced', () {
      final List<PlatformQuote> q = PriceCompare.forRide(
        providers: BookingProviders.forCategory(BookingCategory.ride),
        query: rideQuery(),
      );
      expect(q.length, 3);
      for (final PlatformQuote e in q) {
        expect(e.hasPrice, isFalse,
            reason: 'no distance may never be turned into a fake number');
        expect(e.confidence, PriceConfidence.unknown);
        expect(e.link, isNotNull,
            reason: 'the traveller still needs the way to the live fare');
      }
    });
  });

  group('PriceCompare — inter-city', () {
    test('train fare scales with distance and passengers', () {
      final int twoPax = PriceCompare.forTravel(
        category: BookingCategory.train,
        providers: BookingProviders.forCategory(BookingCategory.train),
        query: cityQuery(),
        pax: 2,
        date: DateTime.now().add(const Duration(days: 10)),
        distanceKm: 300,
        trainClass: '3A',
      ).single.mid;
      final int onePax = PriceCompare.forTravel(
        category: BookingCategory.train,
        providers: BookingProviders.forCategory(BookingCategory.train),
        query: cityQuery(),
        pax: 1,
        date: DateTime.now().add(const Duration(days: 10)),
        distanceKm: 300,
        trainClass: '3A',
      ).single.mid;
      expect(twoPax, greaterThan(onePax * 1.8));
    });

    test('a flight booked tomorrow costs more than one booked 60 days out',
        () {
      final int tomorrow = PriceCompare.forTravel(
        category: BookingCategory.flight,
        providers: BookingProviders.forCategory(BookingCategory.flight),
        query: cityQuery(),
        pax: 1,
        date: DateTime.now().add(const Duration(days: 1)),
        distanceKm: 700,
      ).first.mid;
      final int later = PriceCompare.forTravel(
        category: BookingCategory.flight,
        providers: BookingProviders.forCategory(BookingCategory.flight),
        query: cityQuery(),
        pax: 1,
        date: DateTime.now().add(const Duration(days: 60)),
        distanceKm: 700,
      ).first.mid;
      expect(tomorrow, greaterThan(later));
    });

    test('hotel estimate multiplies by nights, flights do not claim accuracy',
        () {
      final List<PlatformQuote> one = PriceCompare.forTravel(
        category: BookingCategory.hotel,
        providers: BookingProviders.forCategory(BookingCategory.hotel),
        query: cityQuery(),
        pax: 2,
        date: DateTime.now().add(const Duration(days: 5)),
        distanceKm: 300,
        nights: 1,
        hotelTier: 'standard',
      );
      final List<PlatformQuote> four = PriceCompare.forTravel(
        category: BookingCategory.hotel,
        providers: BookingProviders.forCategory(BookingCategory.hotel),
        query: cityQuery(),
        pax: 2,
        date: DateTime.now().add(const Duration(days: 5)),
        distanceKm: 300,
        nights: 4,
        hotelTier: 'standard',
      );
      expect(four.single.low,
          greaterThan((one.single.low ?? 0) * 3));
      // A stay price depends on the property, so it must never be sold as a
      // precise number.
      expect(one.single.confidence, PriceConfidence.low);
    });

    test('unknown distance never fabricates a fare', () {
      final List<PlatformQuote> q = PriceCompare.forTravel(
        category: BookingCategory.bus,
        providers: BookingProviders.forCategory(BookingCategory.bus),
        query: cityQuery(),
        pax: 1,
        date: DateTime.now().add(const Duration(days: 3)),
      );
      expect(q.single.hasPrice, isFalse);
      expect(q.single.confidence, PriceConfidence.unknown);
    });
  });

  group('PriceCompare — trip budget (travel agent)', () {
    test('every component is inside the total and the total adds up', () {
      final TripEstimate t = PriceCompare.trip(
        category: BookingCategory.train,
        days: 3,
        pax: 2,
        distanceKm: 300,
        hotelTier: 'standard',
        trainClass: '3A',
      );
      expect(t.totalLow,
          t.travelLow + t.stayLow + t.foodLow + t.localLow + t.activitiesLow);
      expect(t.totalHigh, greaterThan(t.totalLow));
      expect(t.stayLow, greaterThan(0));
      // Two travellers share one room, three nights.
      expect(t.stayLow, 2600 * 1 * 3);
      expect(t.foodLow, 400 * 2 * 3);
    });

    test('a longer trip costs more than a shorter one, deterministically',
        () {
      final TripEstimate short = PriceCompare.trip(
        category: BookingCategory.bus,
        days: 1,
        pax: 1,
        distanceKm: 200,
      );
      final TripEstimate long = PriceCompare.trip(
        category: BookingCategory.bus,
        days: 5,
        pax: 1,
        distanceKm: 200,
      );
      expect(long.totalLow, greaterThan(short.totalLow));
      expect(long.perDayLow, lessThanOrEqualTo(long.perDayHigh));
    });
  });
}
