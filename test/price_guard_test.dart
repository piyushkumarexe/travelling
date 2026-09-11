import 'package:flutter_test/flutter_test.dart';
import 'package:yatrawise/core/utils/price_guard.dart';

void main() {
  group('PriceGuard taxi/auto (distance-based)', () {
    test('₹800 for 5 km taxi is potentially high (spec example)', () {
      final PriceCheckResult r = PriceGuard.check(
        category: PriceCategory.taxi,
        amount: 800,
        distanceKm: 5,
      );
      expect(r.verdict, PriceVerdict.potentiallyHigh);
      expect(r.referenceText, contains('Reference range'));
    });

    test('a typical 5 km taxi fare is normal', () {
      final PriceCheckResult r = PriceGuard.check(
        category: PriceCategory.taxi,
        amount: 140,
        distanceKm: 5,
      );
      expect(r.verdict, PriceVerdict.normal);
    });

    test('taxi without distance asks for more info', () {
      final PriceCheckResult r = PriceGuard.check(
        category: PriceCategory.taxi,
        amount: 800,
      );
      expect(r.verdict, PriceVerdict.needsMoreInfo);
    });

    test('auto without distance asks for more info', () {
      final PriceCheckResult r = PriceGuard.check(
        category: PriceCategory.auto,
        amount: 100,
      );
      expect(r.verdict, PriceVerdict.needsMoreInfo);
    });
  });

  group('PriceGuard flat-reference categories', () {
    test('₹300 restaurant is normal', () {
      final PriceCheckResult r = PriceGuard.check(
        category: PriceCategory.restaurant,
        amount: 300,
      );
      expect(r.verdict, PriceVerdict.normal);
    });

    test('₹3000 restaurant is potentially high', () {
      final PriceCheckResult r = PriceGuard.check(
        category: PriceCategory.restaurant,
        amount: 3000,
      );
      expect(r.verdict, PriceVerdict.potentiallyHigh);
    });

    test('shopping has no standard reference', () {
      final PriceCheckResult r = PriceGuard.check(
        category: PriceCategory.shopping,
        amount: 5000,
      );
      expect(r.verdict, PriceVerdict.needsMoreInfo);
    });

    test('negative amount is treated as unusually low, never crashes', () {
      final PriceCheckResult r = PriceGuard.check(
        category: PriceCategory.hotel,
        amount: -10,
      );
      expect(r.verdict, PriceVerdict.low);
    });
  });
}
