import 'package:flutter_test/flutter_test.dart';

import 'package:yatrawise/data/models/itinerary.dart';
import 'package:yatrawise/features/intelligence/engine/engine_models.dart';
import 'package:yatrawise/features/intelligence/engine/trip_intelligence_engine.dart';

ItineraryItem _it(String time, String title, {String cost = ''}) =>
    ItineraryItem(time: time, title: title, cost: cost);

List<ItineraryDay> _plan() => <ItineraryDay>[
      ItineraryDay(day: 1, title: 'Arrival', items: <ItineraryItem>[
        _it('09:00', 'Railway station arrival'),
        _it('10:00', 'Bara Imambara'),
        _it('10:15', 'Hussainabad Clock Tower'), // tight 15-min transfer
        _it('13:00', 'Lunch at local cafe', cost: '₹400'),
        _it('17:00', 'Gomti Riverfront walk'),
      ]),
      ItineraryDay(day: 2, title: 'Museums', items: <ItineraryItem>[
        _it('09:30', 'State Museum'),
        _it('12:00', 'Residency ruins'),
        _it('16:00', 'Hazratganj shopping', cost: '₹1,500'),
      ]),
    ];

void main() {
  group('parsing (real saved strings only)', () {
    test('time parsing and formatting', () {
      expect(TripIntelligenceEngine.timeToMin('09:30'), 570);
      expect(TripIntelligenceEngine.timeToMin('9.05'), 545);
      expect(TripIntelligenceEngine.timeToMin('gibberish'), isNull);
      expect(TripIntelligenceEngine.timeToMin('25:00'), isNull);
      expect(TripIntelligenceEngine.minToTime(570), '09:30');
    });
    test('cost parsing — unknown stays unknown', () {
      expect(TripIntelligenceEngine.costInr('₹1,500'), 1500);
      expect(TripIntelligenceEngine.costInr('INR 400'), 400);
      expect(TripIntelligenceEngine.costInr('free entry'), isNull);
      expect(TripIntelligenceEngine.costInr('about 200 rupees'), 200);
    });
  });

  group('2) robustness score (measurable factors, 0–100)', () {
    test('tight transfers lower the score and are named', () {
      final RobustnessReport r =
          TripIntelligenceEngine.robustness(_plan());
      expect(r.score, lessThan(80));
      final RobustnessFactor tight = r.factors
          .firstWhere((RobustnessFactor f) => f.name == 'Tight connections');
      expect(tight.impact, lessThan(0));
      expect(tight.detail, contains('10:00→10:15'));
    });
    test('a relaxed plan scores higher than a packed one', () {
      final List<ItineraryDay> relaxed = <ItineraryDay>[
        ItineraryDay(day: 1, title: 'Easy', items: <ItineraryItem>[
          _it('09:00', 'Park'),
          _it('13:00', 'Museum'),
          _it('18:00', 'Dinner'),
        ]),
      ];
      final RobustnessReport a = TripIntelligenceEngine.robustness(relaxed);
      final RobustnessReport b = TripIntelligenceEngine.robustness(_plan());
      expect(a.score, greaterThanOrEqualTo(b.score));
      expect(a.score, inInclusiveRange(0, 100));
    });
  });

  group('1) what-if simulator runs on a COPY', () {
    test('train delay slides the day and drops late stops, original intact',
        () {
      final List<ItineraryDay> before = _plan();
      final SimulationResult r = TripIntelligenceEngine.simulate(
          before,
          const ScenarioSpec(
              type: ScenarioType.trainDelay, delayMinutes: 120));
      // Original untouched.
      expect(before.first.items[1].time, '10:00');
      // Simulated day slid by 2h; last stop pushed past 23:30 gets dropped
      // or slid — never silently kept at the old time.
      final int newFirst =
          TripIntelligenceEngine.timeToMin(r.days.first.items.first.time)!;
      expect(newFirst, 11 * 60);
      expect(r.dropped.any((String d) => d.contains('no longer fit') ||
          d.contains('too late')) || r.conflicts.isNotEmpty, isTrue);
    });

    test('reduced time window drops out-of-window stops', () {
      final SimulationResult r = TripIntelligenceEngine.simulate(
          _plan(),
          const ScenarioSpec(
              type: ScenarioType.reducedTime, availableMinutesPerDay: 180));
      expect(r.dropped, isNotEmpty);
      expect(r.days.first.items.length, lessThan(5));
    });

    test('reduced budget drops costliest parsed stops only', () {
      final SimulationResult r = TripIntelligenceEngine.simulate(
          _plan(),
          const ScenarioSpec(
              type: ScenarioType.reducedBudget, budgetPct: 40));
      // ₹400 + ₹1500 = 1900; 40% cap = 760 → ₹1500 shopping must go.
      expect(r.dropped.join(' '), contains('Hazratganj'));
      expect(TripIntelligenceEngine.planCost(r.days), lessThanOrEqualTo(760));
    });

    test('removed stop closes the gap honestly', () {
      final SimulationResult r = TripIntelligenceEngine.simulate(
          _plan(),
          const ScenarioSpec(
              type: ScenarioType.removedStop,
              removeDayIndex: 0,
              removeItemIndex: 1));
      expect(r.dropped.join(' '), contains('Bara Imambara'));
      expect(
          r.days.first.items.any((ItineraryItem i) =>
              i.title == 'Bara Imambara'), isFalse);
    });
  });

  group('4) dependency graph + propagation', () {
    test('sequential chain and downstream impact', () {
      final DependencyGraph g = TripIntelligenceEngine.dependencyGraph(_plan());
      expect(g.nodes.length, 8);
      expect(g.edges.length, 6); // 5+3 items → 4+2 sequential edges
      final int imambara =
          g.nodes.indexWhere((DependencyNode n) => n.label == 'Bara Imambara');
      final List<int> affected = g.affectedBy(imambara, 45);
      expect(affected.length, 3); // clock tower, lunch, riverfront
      expect(g.nodes[affected.first].label, 'Hussainabad Clock Tower');
    });
  });

  group('14) contradiction detector', () {
    test('impossible sequence is CRITICAL with actual values', () {
      final List<ItineraryDay> bad = <ItineraryDay>[
        ItineraryDay(day: 1, title: 'x', items: <ItineraryItem>[
          _it('12:00', 'Museum'),
          _it('10:00', 'Backwards stop'),
          _it('10:05', 'Right after'),
        ]),
      ];
      final List<Contradiction> c = TripIntelligenceEngine.contradictions(bad);
      expect(c.any((Contradiction x) =>
          x.severity == Severity.critical &&
          x.title == 'Impossible sequence'), isTrue);
      expect(c.any((Contradiction x) =>
          x.severity == Severity.warning && x.title == 'Tight transfer'),
          isTrue);
    });
    test('duplicate stops are flagged', () {
      final List<ItineraryDay> dup = <ItineraryDay>[
        ItineraryDay(day: 1, title: 'x', items: <ItineraryItem>[
          _it('09:00', 'Park'),
          _it('11:00', 'Park'),
        ]),
      ];
      expect(
          TripIntelligenceEngine.contradictions(dup).any(
              (Contradiction c) => c.title == 'Duplicate stop'), isTrue);
    });
  });

  group('11) last safe decision point', () {
    test('safe / risky / infeasible with real arithmetic', () {
      final (int dl, String s1) = TripIntelligenceEngine.lastSafeDeparture(
          legMinutes: 40,
          bufferMinutes: 15,
          arrivalDeadlineMin: 18 * 60,
          plannedDepartureMin: 16 * 60);
      expect(dl, 16 * 60 + 5); // 1080 - 55
      expect(s1, startsWith('Risky')); // 5 min slack < 15

      final (_, String s2) = TripIntelligenceEngine.lastSafeDeparture(
          legMinutes: 40,
          bufferMinutes: 15,
          arrivalDeadlineMin: 18 * 60,
          plannedDepartureMin: 17 * 60);
      expect(s2, startsWith('No longer feasible'));

      final (_, String s3) = TripIntelligenceEngine.lastSafeDeparture(
          legMinutes: 40,
          bufferMinutes: 15,
          arrivalDeadlineMin: 18 * 60,
          plannedDepartureMin: 15 * 60);
      expect(s3, startsWith('Safe'));

      final (_, String s4) = TripIntelligenceEngine.lastSafeDeparture(
          legMinutes: null,
          bufferMinutes: 15,
          arrivalDeadlineMin: 18 * 60,
          plannedDepartureMin: 15 * 60);
      expect(s4, contains('unknown'));
    });
  });

  group('10) constraint solver', () {
    test('must-visit kept, avoid dropped, violation reported when both',
        () {
      final SolverResult r = TripIntelligenceEngine.solveConstraints(
          _plan(),
          const ConstraintSet(
              mustVisit: <String>['Imambara'], avoid: <String>['Imambara']));
      expect(r.violations.join(' '), contains('both must-visit and avoid'));
    });
    test('feasible solve respects avoid + items/day', () {
      final SolverResult r = TripIntelligenceEngine.solveConstraints(
          _plan(),
          const ConstraintSet(avoid: <String>['shopping'], maxItemsPerDay: 4));
      expect(r.feasible, isTrue);
      expect(r.days.first.items.length, lessThanOrEqualTo(4));
      expect(r.days.any((ItineraryDay d) =>
          d.items.any((ItineraryItem i) =>
              i.title.contains('Hazratganj'))), isFalse);
    });
    test('impossible budget identifies the conflicting constraint', () {
      final SolverResult r = TripIntelligenceEngine.solveConstraints(
          _plan(), const ConstraintSet(budgetCapInr: 100));
      expect(r.feasible, isFalse);
      expect(r.violations.join(' '), contains('cap'));
    });
  });

  group('12) trade-off sliders actually change the plan', () {
    test('relaxed profile keeps fewer stops than packed profile', () {
      final SolverResult relaxed = TripIntelligenceEngine.optimize(
          _plan(),
          const TradeOffProfile(relaxedVsPacked: 10),
          const ConstraintSet());
      final SolverResult packed = TripIntelligenceEngine.optimize(
          _plan(),
          const TradeOffProfile(relaxedVsPacked: 95, travelVsDestinations: 95),
          const ConstraintSet());
      final int relaxedCount = relaxed.days
          .fold<int>(0, (int a, ItineraryDay d) => a + d.items.length);
      final int packedCount = packed.days
          .fold<int>(0, (int a, ItineraryDay d) => a + d.items.length);
      expect(packedCount, greaterThanOrEqualTo(relaxedCount));
      expect(relaxedCount, lessThan(8)); // original 8 → trimmed
    });
  });

  group('13) group conflict resolver', () {
    test('maximises satisfied preferences and reports compromises', () {
      final GroupResult r = TripIntelligenceEngine.resolveGroup(
          _plan(),
          const <GroupMemberPref>[
            GroupMemberPref(name: 'A',
                liked: <String>['Imambara', 'Museum'],
                disliked: <String>['shopping']),
            GroupMemberPref(name: 'B',
                liked: <String>['shopping', 'Riverfront'],
                disliked: <String>[]),
          ]);
      expect(r.satisfaction, inInclusiveRange(0, 100));
      expect(r.compromises.join(' '), contains('Hazratganj'));
      // 'Lunch' is liked by nobody and disliked by nobody → untouched.
      expect(
          r.days.first.items.any((ItineraryItem i) =>
              i.title.contains('Lunch')), isTrue);
    });
  });

  group('6) why not — never invents', () {
    test('time-based reasons with real numbers', () {
      final List<WhyNotReason> r = TripIntelligenceEngine.whyNot(
        placeName: 'Distant Fort',
        legMinutes: 150,
        remainingMinutes: 120,
        dayEndMin: 21 * 60,
        nowMin: 20 * 60,
      );
      expect(r.any((WhyNotReason x) => x.reason == 'Not enough time'),
          isTrue);
      expect(r.any((WhyNotReason x) => x.reason == 'After your day ends'),
          isTrue);
    });
    test('unknown route → explicit unknown, not a guess', () {
      final List<WhyNotReason> r = TripIntelligenceEngine.whyNot(
          placeName: 'X',
          legMinutes: null,
          remainingMinutes: 300,
          dayEndMin: 21 * 60,
          nowMin: 12 * 60);
      expect(r.first.reason, 'Route unknown');
    });
  });

  group('8) time-to-enjoyment distinguishes known vs unknown', () {
    test('labels OSRM legs as known, visit duration as unknown', () {
      expect(TripIntelligenceEngine.timeToEnjoyment(35),
          contains('Travel 35 min (OSRM)'));
      expect(TripIntelligenceEngine.timeToEnjoyment(null),
          contains('unknown'));
    });
  });

  group('3) decision replay store', () {
    test('round-trips real records', () {
      final DecisionRecord r = DecisionRecord(
          id: 'd1',
          type: DecisionType.scenarioApplied,
          title: 'Train delay applied',
          detail: 'Day 1 shifted by 60 min',
          at: DateTime(2026, 9, 14, 9));
      final Map<String, dynamic> m = r.toMap();
      final DecisionRecord back = DecisionRecord.fromMap(m);
      expect(back.type, DecisionType.scenarioApplied);
      expect(back.title, 'Train delay applied');
      expect(back.at, r.at);
    });
  });
}
