import 'package:flutter_test/flutter_test.dart';

import 'package:yatrawise/features/toolkit/traveller_toolkit_engine.dart';

void main() {
  group('Smart Packing', () {
    test('always includes travel essentials and has no duplicate names', () {
      final List<PackingItem> list = TravellerToolkitEngine.packingList(
        days: 3,
        style: TripStyle.leisure,
        climate: Climate.mixed,
      );
      expect(list.any((PackingItem i) => i.name.contains('ID / passport')), isTrue);
      expect(list.any((PackingItem i) => i.name == 'Phone charger'), isTrue);
      expect(list.map((PackingItem i) => i.name).toSet().length, list.length);
    });

    test('duration changes quantities without producing absurd luggage', () {
      final List<PackingItem> short = TravellerToolkitEngine.packingList(
        days: 1,
        style: TripStyle.leisure,
        climate: Climate.hot,
      );
      final List<PackingItem> long = TravellerToolkitEngine.packingList(
        days: 20,
        style: TripStyle.leisure,
        climate: Climate.hot,
      );
      int qty(List<PackingItem> l, String name) =>
          l.firstWhere((PackingItem i) => i.name == name).quantity;
      expect(qty(long, 'Underwear'), greaterThan(qty(short, 'Underwear')));
      expect(qty(long, 'Underwear'), lessThanOrEqualTo(8),
          reason: 'long trips should plan laundry, not 21 pieces');
      expect(long.any((PackingItem i) => i.name.contains('Laundry')), isTrue);
    });

    test('climate and trip-style additions are specific', () {
      final List<PackingItem> coldBusiness =
          TravellerToolkitEngine.packingList(
        days: 4,
        style: TripStyle.business,
        climate: Climate.cold,
      );
      expect(coldBusiness.any((PackingItem i) => i.name == 'Warm jacket'), isTrue);
      expect(coldBusiness.any((PackingItem i) => i.name == 'Laptop & charger'),
          isTrue);
      expect(coldBusiness.any((PackingItem i) => i.name == 'Compact umbrella'),
          isFalse);
    });
  });

  group('Trip Countdown', () {
    final DateTime now = DateTime(2026, 9, 25, 10);

    test('formats multi-day and same-day countdowns', () {
      expect(
        TravellerToolkitEngine.countdown(
                now, now.add(const Duration(days: 2, hours: 5)))
            .headline,
        '2d 5h to go',
      );
      expect(
        TravellerToolkitEngine.countdown(
                now, now.add(const Duration(hours: 3, minutes: 20)))
            .headline,
        '3h 20m to go',
      );
    });

    test('passed departure never presents a positive countdown', () {
      final CountdownResult result = TravellerToolkitEngine.countdown(
          now, now.subtract(const Duration(minutes: 1)));
      expect(result.urgency, CountdownUrgency.passed);
      expect(result.headline, 'Departure time passed');
    });

    test('tasks become due as departure approaches', () {
      final List<DepartureTask> far = TravellerToolkitEngine.departureTasks(
          now, now.add(const Duration(days: 10)));
      final List<DepartureTask> near = TravellerToolkitEngine.departureTasks(
          now, now.add(const Duration(hours: 4)));
      expect(far.where((DepartureTask t) => t.dueNow), isEmpty);
      expect(near.where((DepartureTask t) => t.dueNow).length, near.length);
    });
  });

  group('Group Budget', () {
    test('allocation adds up exactly and per-person/day is correct', () {
      final BudgetSplit b = TravellerToolkitEngine.splitBudget(
          total: 30000, travellers: 2, days: 3);
      expect(b.allocated, closeTo(30000, 0.001));
      expect(b.perPerson, 15000);
      expect(b.perPersonPerDay, 5000);
      expect(b.stay, 10500);
      expect(b.emergencyBuffer, 3000);
    });

    test('invalid people/days are clamped, negative money becomes zero', () {
      final BudgetSplit b = TravellerToolkitEngine.splitBudget(
          total: -50, travellers: 0, days: 0);
      expect(b.total, 0);
      expect(b.travellers, 1);
      expect(b.days, 1);
      expect(b.perPersonPerDay, 0);
    });
  });

  group('India Phrasebook', () {
    test('searches English, roman Hindi and category', () {
      expect(TravellerToolkitEngine.searchPhrases('doctor').single.hindi,
          contains('डॉक्टर'));
      expect(TravellerToolkitEngine.searchPhrases('meter').single.category,
          'Transport');
      expect(TravellerToolkitEngine.searchPhrases('emergency').length,
          greaterThanOrEqualTo(3));
    });

    test('reported Hinglish query kya hua returns the exact useful phrase', () {
      final List<TravelPhrase> found =
          TravellerToolkitEngine.searchPhrases('kya hua');
      expect(found, isNotEmpty);
      expect(found.first.hindi, 'क्या हुआ?');
      expect(found.first.roman, 'Kya hua?');
      expect(TravellerToolkitEngine.searchPhrases('KYA, HUA?!'), isNotEmpty);
    });

    test('aliases and order-independent intent words are searchable', () {
      final List<TravelPhrase> meter =
          TravellerToolkitEngine.searchPhrases('taxi meter');
      expect(meter.any((TravelPhrase p) => p.english == 'Please use the meter'),
          isTrue);
      expect(TravellerToolkitEngine.searchPhrases('emergency doctor'),
          isNotEmpty);
    });

    test('empty search returns the complete 100+ useful set', () {
      expect(TravellerToolkitEngine.searchPhrases(''),
          TravellerToolkitEngine.phrases);
      expect(TravellerToolkitEngine.phrases.length, greaterThanOrEqualTo(100));
    });
  });

  group('Tourist safety brief', () {
    test('high-exposure answers produce concrete actions, not reassurance', () {
      final SafetyBrief brief = TravellerToolkitEngine.assessSafety(
        const SafetyInputs(
          solo: true,
          afterDark: true,
          unfamiliarArea: true,
          liveShareOn: false,
          offlineMapReady: false,
          emergencyContactReady: false,
          batteryPercent: 10,
          carryingLargeCash: true,
        ),
      );
      expect(brief.level, SafetyLevel.high);
      expect(brief.score, lessThan(40));
      expect(brief.actions.length, greaterThanOrEqualTo(5));
    });

    test('prepared answers retain an honest non-guarantee action', () {
      final SafetyBrief brief = TravellerToolkitEngine.assessSafety(
        const SafetyInputs(
          solo: false,
          afterDark: false,
          unfamiliarArea: false,
          liveShareOn: true,
          offlineMapReady: true,
          emergencyContactReady: true,
          batteryPercent: 90,
          carryingLargeCash: false,
        ),
      );
      expect(brief.level, SafetyLevel.prepared);
      expect(brief.score, 100);
      expect(brief.actions, isNotEmpty);
    });
  });

  group('Travel Converter', () {
    test('distance and weight conversions round-trip', () {
      final double miles = TravellerToolkitEngine.convert(
          10, Conversion.kmToMiles);
      final double km = TravellerToolkitEngine.convert(
          miles, Conversion.milesToKm);
      expect(km, closeTo(10, 0.000001));

      final double lb = TravellerToolkitEngine.convert(20, Conversion.kgToLb);
      expect(
        TravellerToolkitEngine.convert(lb, Conversion.lbToKg),
        closeTo(20, 0.000001),
      );
    });

    test('temperature uses offset correctly', () {
      expect(TravellerToolkitEngine.convert(0, Conversion.celsiusToFahrenheit),
          32);
      expect(
          TravellerToolkitEngine.convert(212, Conversion.fahrenheitToCelsius),
          100);
    });

    test('fuel economy conversion is reversible', () {
      final double mpg =
          TravellerToolkitEngine.convert(20, Conversion.kmplToMpg);
      expect(mpg, closeTo(47.0429, 0.001));
      expect(TravellerToolkitEngine.convert(mpg, Conversion.mpgToKmpl),
          closeTo(20, 0.000001));
    });
  });
}
