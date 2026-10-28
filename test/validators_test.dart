import 'package:flutter_test/flutter_test.dart';

import 'package:yatrawise/core/utils/validators.dart';

void main() {
  group('Validators.requiredText', () {
    test('rejects empty', () {
      expect(Validators.requiredText(''), isNotNull);
      expect(Validators.requiredText(null), isNotNull);
    });

    test('accepts normal text', () {
      expect(Validators.requiredText('Jaipur'), isNull);
    });

    test('respects max length', () {
      expect(Validators.requiredText('a' * 100, max: 50), isNotNull);
    });
  });

  group('Validators.description', () {
    test('requires at least 10 chars', () {
      expect(Validators.description('short'), isNotNull);
      expect(Validators.description('long enough text'), isNull);
    });

    test('rejects over 2000', () {
      expect(Validators.description('a' * 2001), isNotNull);
    });
  });

  group('Validators.phone', () {
    test('accepts international format', () {
      expect(Validators.phone('+91 98765 43210'), isNull);
      expect(Validators.phone('+1 (415) 555-0132'), isNull);
    });

    test('rejects garbage', () {
      expect(Validators.phone('hello'), isNotNull);
      expect(Validators.phone('12345'), isNotNull); // too short
    });
  });

  group('Validators lat/lng/radius', () {
    test('isLat bounds', () {
      expect(Validators.isLat(45.0), isTrue);
      expect(Validators.isLat(-91.0), isFalse);
      expect(Validators.isLat(null), isFalse);
    });

    test('isLng bounds', () {
      expect(Validators.isLng(-180.0), isTrue);
      expect(Validators.isLng(180.1), isFalse);
    });

    test('latText parses and validates', () {
      expect(Validators.latText('28.6139'), isNull);
      expect(Validators.latText('95'), isNotNull);
      expect(Validators.latText('abc'), isNotNull);
    });

    test('radiusText bounds 100..10000', () {
      expect(Validators.radiusText('500'), isNull);
      expect(Validators.radiusText('50'), isNotNull);
      expect(Validators.radiusText('99999'), isNotNull);
    });

    test('daysText bounds 1..10', () {
      expect(Validators.daysText('3'), isNull);
      expect(Validators.daysText('0'), isNotNull);
      expect(Validators.daysText('11'), isNotNull);
    });
  });
}
