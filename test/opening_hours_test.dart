import 'package:flutter_test/flutter_test.dart';

import 'package:yatrawise/features/autopilot/opening_hours.dart';

void main() {
  group('parseOpeningHours (honest: unknown → null)', () {
    test('24/7 always open', () {
      final OpeningHours? oh = parseOpeningHours('24/7');
      expect(oh, isNotNull);
      expect(oh!.alwaysOpen, isTrue);
    });

    test('Mo-Su single daily range', () {
      final OpeningHours? oh = parseOpeningHours('Mo-Su 09:00-21:00');
      expect(oh, isNotNull);
      // 2026-09-13 is a Sunday (weekday 7).
      final DateTime t = DateTime(2026, 9, 13, 17, 30);
      expect(oh!.appliesTo(t), isTrue);
      expect(oh.closesAt(t), DateTime(2026, 9, 13, 21, 0));
    });

    test('Mo-Fr / Sa-Su split rules', () {
      final OpeningHours? oh = parseOpeningHours(
          'Mo-Fr 10:00-20:00; Sa-Su 11:00-22:00');
      expect(oh, isNotNull);
      // 2026-09-14 is a Monday.
      final DateTime mon = DateTime(2026, 9, 14, 12);
      // 2026-09-13 is a Sunday.
      final DateTime sun = DateTime(2026, 9, 13, 12);
      expect(oh!.closesAt(mon), DateTime(2026, 9, 14, 20, 0));
      expect(oh.closesAt(sun), DateTime(2026, 9, 13, 22, 0));
    });

    test('comma day list and double range', () {
      final OpeningHours? oh =
          parseOpeningHours('Sa,Su 09:00-13:00,16:00-21:00');
      expect(oh, isNotNull);
      final DateTime sun = DateTime(2026, 9, 13, 12);
      expect(oh!.closesAt(sun), DateTime(2026, 9, 13, 21, 0));
      final DateTime mon = DateTime(2026, 9, 14, 12);
      expect(oh.appliesTo(mon), isFalse); // no rules for Monday
    });

    test('unsupported syntax → null (never assume open)', () {
      expect(parseOpeningHours('Mo-Su sunrise-sunset'), isNull);
      expect(parseOpeningHours('PH off'), isNull);
      expect(parseOpeningHours(''), isNull);
      expect(parseOpeningHours(null), isNull);
    });
  });
}
