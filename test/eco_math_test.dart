import 'package:flutter_test/flutter_test.dart';

import 'package:yatrawise/core/utils/eco_math.dart';

void main() {
  group('EcoMath.activityPoints', () {
    test('walking earns 12 pts/km + 2 bonus', () {
      expect(EcoMath.activityPoints('walk', 1000), 14);
    });

    test('cycling earns 9 pts/km + 2 bonus', () {
      expect(EcoMath.activityPoints('cycle', 1000), 11);
    });

    test('transit earns 6 pts/km + 2 bonus', () {
      expect(EcoMath.activityPoints('transit', 1000), 8);
    });

    test('zero distance earns zero', () {
      expect(EcoMath.activityPoints('walk', 0), 0);
    });

    test('rounds to nearest integer', () {
      expect(EcoMath.activityPoints('walk', 500), 8); // 6 + 2
    });
  });

  group('EcoMath levels', () {
    test('0 → Trail Starter', () {
      expect(EcoMath.levelFor(0), 'Trail Starter');
    });

    test('100 → Green Traveler', () {
      expect(EcoMath.levelFor(100), 'Green Traveler');
    });

    test('500 → Carbon Champion (max)', () {
      expect(EcoMath.levelFor(500), 'Carbon Champion');
      expect(EcoMath.levelFor(99999), 'Carbon Champion');
    });

    test('progress is clamped to 0..1', () {
      expect(EcoMath.levelProgress(0), 0.0);
      expect(EcoMath.levelProgress(500), 1.0);
      expect(EcoMath.levelProgress(175), closeTo(0.5, 0.001));
    });
  });

  group('EcoMath.badgesFor', () {
    test('no activity → no badges', () {
      expect(
        EcoMath.badgesFor(
            walkKm: 0, cycleKm: 0, transitKm: 0, score: 0, sessions: 0),
        isEmpty,
      );
    });

    test('1 km walk + first session unlocks two badges', () {
      final List<String> b = EcoMath.badgesFor(
          walkKm: 1.2, cycleKm: 0, transitKm: 0, score: 20, sessions: 1);
      expect(b, contains('first-steps'));
      expect(b, contains('walk-1'));
      expect(b, isNot(contains('walk-10')));
    });

    test('all badges unlock at top thresholds', () {
      final List<String> b = EcoMath.badgesFor(
          walkKm: 12, cycleKm: 30, transitKm: 25, score: 600, sessions: 50);
      expect(b.length, EcoMath.badges.length);
    });
  });

  group('EcoMath.modeLabel', () {
    test('known modes', () {
      expect(EcoMath.modeLabel('walk'), 'Walking');
      expect(EcoMath.modeLabel('cycle'), 'Cycling');
      expect(EcoMath.modeLabel('transit'), 'Public transport');
    });
  });
}
