import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import 'package:yatrawise/data/models/places.dart';
import 'package:yatrawise/features/autopilot/autopilot_engine.dart';
import 'package:yatrawise/features/autopilot/autopilot_models.dart';
import 'package:yatrawise/features/autopilot/autopilot_service.dart';

Place _p(
  String id,
  String name,
  String category,
  double km,
  Map<String, dynamic> meta,
) {
  return Place(
    placeId: id,
    name: name,
    lat: 25.7 + km * 0.009,
    lng: 82.6,
    category: category,
    primaryType: category,
    distanceMeters: km * 1000,
    metadata: meta,
  );
}

void main() {
  final LatLng here = LatLng(25.7, 82.6);
  final DateTime now = DateTime(2026, 9, 13, 17, 30); // Sunday 5:30 PM

  test('TEST 1: works with NO itinerary — only time', () {
    final List<Place> dataset = <Place>[
      _p('1', 'Garden Cafe', 'cafe', 1.2, <String, dynamic>{}),
      _p('2', 'City Museum', 'museum', 3.0, <String, dynamic>{}),
    ];
    final List<Place> candidates = AutopilotEngine.candidatesFor(
        dataset, const AutopilotBrief(availableMinutes: 120));
    expect(candidates.length, 2);
  });

  test('TEST 2: only "Food" → real food recommendations only', () {
    final List<Place> dataset = <Place>[
      _p('1', 'Garden Cafe', 'cafe', 1.2, <String, dynamic>{}),
      _p('2', 'City Museum', 'museum', 3.0, <String, dynamic>{}),
      _p('3', 'Spice Kitchen', 'restaurant', 2.2, <String, dynamic>{}),
    ];
    final List<Place> candidates = AutopilotEngine.candidatesFor(
        dataset, const AutopilotBrief(interests: <AutopilotInterest>{
      AutopilotInterest.eat,
    }));
    expect(candidates.map((Place p) => p.category).toSet(),
        <String>{'cafe', 'restaurant'});
  });

  test('explicit Generate creates a clean session and a fresh deadline', () {
    final DateTime generatedAt = DateTime(2026, 9, 25, 8);
    final AutopilotSession fresh =
        AutopilotService.freshSessionForGenerate(
      const AutopilotBrief(availableMinutes: 590),
      generatedAt,
      id: 'fresh',
    );
    expect(fresh.id, 'fresh');
    expect(fresh.stops, isEmpty);
    expect(fresh.endsAt, generatedAt.add(const Duration(minutes: 590)));
  });

  test('provider taxonomy variants remain valid tourist candidates', () {
    final List<Place> dataset = <Place>[
      _p('1', 'Riverside Temple', 'hindu_temple', 1.0, <String, dynamic>{}),
      _p('2', 'Old Fort', 'historical_landmark', 1.5, <String, dynamic>{}),
      _p('3', 'City Icon', 'tourist_attraction', 2.0, <String, dynamic>{}),
    ];
    final List<Place> historical = AutopilotEngine.candidatesFor(
      dataset,
      const AutopilotBrief(
          interests: <AutopilotInterest>{AutopilotInterest.historical}),
    );
    expect(historical.map((Place p) => p.placeId).toSet(),
        <String>{'1', '2', '3'});
  });

  test('Explore never substitutes emergency services or restaurants', () {
    final List<Place> dataset = <Place>[
      _p('1', 'City Fire Station', 'fire_station', 1, <String, dynamic>{}),
      _p('2', 'Nearest Restaurant', 'restaurant', 0.5, <String, dynamic>{}),
      _p('mosque', 'Generic Nearby Masjid', 'place_of_worship', 0.2,
          <String, dynamic>{}),
      _p('3', 'Famous Fort', 'tourist_attraction', 4, <String, dynamic>{}),
    ];
    final List<Place> candidates = AutopilotEngine.candidatesFor(
      dataset,
      const AutopilotBrief(
          interests: <AutopilotInterest>{AutopilotInterest.explore}),
    );
    expect(candidates.map((Place p) => p.name).toList(), <String>['Famous Fort']);
  });

  test('same nearby station from two providers is shown once', () {
    final List<Place> candidates = AutopilotEngine.candidatesFor(
      <Place>[
        Place(
          placeId: 'a',
          name: 'Ayodhya Junction',
          lat: 26.7950,
          lng: 82.2000,
          category: 'attraction',
        ),
        Place(
          placeId: 'b',
          name: 'Ayodhya  Junction',
          lat: 26.7951,
          lng: 82.2001,
          category: 'attraction',
        ),
      ],
      const AutopilotBrief(
          interests: <AutopilotInterest>{AutopilotInterest.explore}),
    );
    expect(candidates, hasLength(1));
  });

  test('typed Explore intent outranks a closer stale Eat selection', () {
    final List<Place> candidates = <Place>[
      _p('food', 'Nearby Food', 'restaurant', 0.5, <String, dynamic>{}),
      _p('sight', 'Famous Museum', 'museum', 4, <String, dynamic>{}),
    ];
    final AutopilotRanking ranking = AutopilotEngine.rankPlaces(
      candidates: candidates,
      brief: const AutopilotBrief(
        interests: <AutopilotInterest>{
          AutopilotInterest.eat,
          AutopilotInterest.explore,
        },
        freeText: 'I want to explore Kanpur',
      ),
      here: here,
      now: now,
      minutesLeft: 600,
    );
    expect(ranking.practical.first.name, 'Famous Museum');
  });

  test('TEST 3: "2 hours" — everything shown fits, the rest is rejected '
      'with a real reason', () {
    final List<Place> dataset = <Place>[
      _p('1', 'Nearby Cafe', 'cafe', 1.0, <String, dynamic>{}), // ~4 min + 30
      _p('2', 'Far Museum', 'museum', 18.0, <String, dynamic>{}), // too big
    ];
    final List<Place> candidates =
        AutopilotEngine.candidatesFor(dataset, const AutopilotBrief());
    final AutopilotRanking r = AutopilotEngine.rankPlaces(
      candidates: candidates,
      brief: const AutopilotBrief(availableMinutes: 120),
      here: here,
      now: now,
      minutesLeft: 120,
    );
    expect(
        r.practical.map((AutopilotSuggestion s) => s.placeId).toSet(), <String>{'1'});
    expect(r.notPractical.length, 1);
    expect(r.notPractical.first.$2, contains('Does not fit'));
  });

  test('TEST 7: closes before realistic arrival → NOT recommended normally',
      () {
    final List<Place> dataset = <Place>[
      // Spec example: arrival ~5:50 PM (20 min travel) but closes 6:00 PM.
      _p('1', 'Soon-Closing Market', 'shopping', 6.5,
          <String, dynamic>{'opening_hours': 'Mo-Su 10:00-18:00'}),
      // Open long enough.
      _p('2', 'Late Cafe', 'cafe', 2.0,
          <String, dynamic>{'opening_hours': 'Mo-Su 09:00-23:00'}),
    ];
    final AutopilotRanking r = AutopilotEngine.rankPlaces(
      candidates: dataset,
      brief: const AutopilotBrief(),
      here: here,
      now: now,
      minutesLeft: 240,
    );
    expect(
        r.practical.map((AutopilotSuggestion s) => s.placeId).toSet(),
        <String>{'2'});
    expect(r.notPractical.first.$1.placeId, '1');
    expect(r.notPractical.first.$2, contains('closes at 6:00 PM'));
  });

  test('Opening hours unknown → shown as unavailable, never assumed open', () {
    final List<Place> dataset = <Place>[
      _p('1', 'Mystery Dhaba', 'restaurant', 2.0, <String, dynamic>{}),
    ];
    final AutopilotRanking r = AutopilotEngine.rankPlaces(
      candidates: dataset,
      brief: const AutopilotBrief(),
      here: here,
      now: now,
      minutesLeft: 240,
    );
    expect(r.practical.first.openingHoursKnown, isFalse);
    expect(r.practical.first.reasons.join(' '), contains('Opening hours unavailable'));
  });

  test('TEST 6/17: dedup + no essential services as destinations', () {
    final List<Place> dataset = <Place>[
      _p('1', 'City ATM', 'atm', 0.5, <String, dynamic>{}),
      _p('2', 'Police Station', 'police', 0.8, <String, dynamic>{}),
      _p('3', 'Chowk Cafe', 'cafe', 1.1, <String, dynamic>{}),
      _p('4', 'Chowk  Cafe', 'cafe', 1.1, <String, dynamic>{}), // dup
    ];
    final List<Place> candidates =
        AutopilotEngine.candidatesFor(dataset, const AutopilotBrief());
    // Essentials dropped; the two Chowk Cafe records deduped to one.
    expect(candidates.length, 1);
    expect(candidates.first.category, 'cafe');
  });

  test('parseBrief: time, interests, budget, max-travel, family', () {
    final AutopilotBrief b = AutopilotEngine.parseBrief(
        'I have 3 hours and want to see historical places with my family, '
        'budget of 500, not more than 20 minutes away');
    expect(b.availableMinutes, 180);
    expect(b.interests, contains(AutopilotInterest.historical));
    expect(b.interests, contains(AutopilotInterest.family));
    expect(b.group, AutopilotGroup.family);
    expect(b.budgetRs, 500);
    expect(b.maxTravelMinutes, 20);
  });

  test('parseBrief: "1 hour 30 minutes" combines', () {
    final AutopilotBrief b = AutopilotEngine.parseBrief('I have 1 hour 30 minutes');
    expect(b.availableMinutes, 90);
  });

  test('⚡ AUTO PLAN: never exceeds the available time', () {
    final List<Place> dataset = <Place>[
      _p('1', 'Museum', 'museum', 2.0, <String, dynamic>{}),
      _p('2', 'Restaurant', 'restaurant', 3.0, <String, dynamic>{}),
      _p('3', 'Park', 'park', 1.5, <String, dynamic>{}),
      _p('4', 'Market', 'shopping', 8.0, <String, dynamic>{}),
    ];
    final AutopilotRanking r = AutopilotEngine.rankPlaces(
      candidates: dataset,
      brief: const AutopilotBrief(),
      here: here,
      now: now,
      minutesLeft: 120,
    );
    final AutopilotPlan plan = AutopilotEngine.buildAutoPlan(
      ranked: r.practical,
      minutesLeft: 120,
    );
    expect(plan.fits, isTrue);
    expect(plan.totalMinutes <= 120, isTrue);
    expect(plan.steps, isNotEmpty);
  });

  test('🛟 Recovery: running late drops TAIL stops with real reasons', () {
    final List<AutopilotStop> pending = <AutopilotStop>[
      const AutopilotStop(
          id: 'a', name: 'Museum', lat: 25.7, lng: 82.6,
          category: 'museum', status: AutopilotStopStatus.proposed,
          visitMinutes: 60, travelMinutes: 8),
      const AutopilotStop(
          id: 'b', name: 'Restaurant', lat: 25.71, lng: 82.6,
          category: 'restaurant', status: AutopilotStopStatus.proposed,
          visitMinutes: 45, travelMinutes: 10),
      const AutopilotStop(
          id: 'c', name: 'Park', lat: 25.72, lng: 82.6,
          category: 'park', status: AutopilotStopStatus.proposed,
          visitMinutes: 40, travelMinutes: 12),
    ];
    final AutopilotRecovery rec = AutopilotEngine.recoverPlan(
      pending: pending,
      minutesLeft: 110, // fits Museum(78) + Restaurant(65)? no → drop tail
    );
    // Museum (8+60+10=78) fits; Restaurant (10+45+10=65) would need 143 — drop.
    expect(rec.keep.map((AutopilotStop s) => s.id).toList(), <String>['a']);
    expect(rec.drop.map(((AutopilotStop, String) d) => d.$1.id).toList(),
        <String>['b', 'c']);
  });

  test('Budget honesty: transport is an estimate, entry/food never invented',
      () {
    final int est = AutopilotEngine.transportEstimateRs(5000, AutopilotMode.drive);
    expect(est > 0, isTrue);
    expect(
        AutopilotEngine.transportEstimateRs(5000, AutopilotMode.walk), 0);
  });

  test('DESTINATION: free text names the place it wants to explore', () {
    expect(AutopilotEngine.destinationCandidate('I want to explore ayodhya'),
        'ayodhya');
    expect(
        AutopilotEngine.destinationCandidate(
            'I want to explore Ayodhya in 2 hours with friends'),
        'ayodhya');
    expect(
        AutopilotEngine.destinationCandidate('2 hours in lucknow old city'),
        'lucknow old city');
    // No place named → null (local nearby mode).
    expect(AutopilotEngine.destinationCandidate('I want to eat food'), isNull);
    expect(AutopilotEngine.destinationCandidate('find hotels in Kanpur'), 'kanpur');
    expect(
      AutopilotEngine.parseBrief('water park and hotel in Kanpur').interests,
      containsAll(<AutopilotInterest>[
        AutopilotInterest.entertainment,
        AutopilotInterest.stay,
      ]),
    );
    expect(AutopilotEngine.destinationCandidate('explore'), isNull);
    // Hindi fillers are stripped, the place name survives.
    expect(
        AutopilotEngine.destinationCandidate('main ayodhya jaana chahta hoon'),
        'ayodhya');
  });

  test('DESTINATION: bundled geocode keeps explicit city planning offline', () {
    final ({String name, double lat, double lng})? ayodhya =
        AutopilotService.bundledDestination('Ayodhya, Uttar Pradesh');
    expect(ayodhya, isNotNull);
    expect(ayodhya!.name, 'Ayodhya');
    expect(ayodhya.lat, closeTo(26.7922, 0.0001));
    expect(ayodhya.lng, closeTo(82.1998, 0.0001));

    final ({String name, double lat, double lng})? mumbai =
        AutopilotService.bundledDestination('mumbai');
    expect(mumbai?.name, 'Mumbai');
    expect(AutopilotService.bundledDestination('an unknown hamlet'), isNull);
    final List<Place> fallback =
        AutopilotService.bundledDestinationPlaces('Ayodhya');
    expect(fallback.map((Place p) => p.name), contains('Hanuman Garhi'));
    expect(fallback.every((Place p) => p.provider == 'bundled_directory'),
        isTrue);
    final List<Place> kanpur =
        AutopilotService.bundledDestinationPlaces('Kanpur');
    expect(kanpur.map((Place p) => p.name),
        contains('Blue World Theme Park'));
    expect(kanpur.map((Place p) => p.name), contains('Moti Jheel'));
    final List<Place> mumbai =
        AutopilotService.bundledDestinationPlaces('Mumbai');
    expect(mumbai.map((Place p) => p.name), contains('Gateway of India'));
    expect(mumbai.map((Place p) => p.name), contains('Marine Drive'));
  });

  test('DESTINATION: failed explicit lookup cannot become nearby mode', () {
    const AutopilotBrief requested =
        AutopilotBrief(freeText: 'I want to explore an unknown hamlet');
    expect(
      AutopilotService.hasUnresolvedExplicitDestination(requested, requested),
      isTrue,
    );
    expect(
      AutopilotService.hasUnresolvedExplicitDestination(
        requested,
        requested.copyWith(
          endName: 'Unknown Hamlet',
          endLat: 20.1,
          endLng: 70.2,
        ),
      ),
      isFalse,
    );
    const AutopilotBrief local = AutopilotBrief(freeText: 'I want good food');
    expect(
      AutopilotService.hasUnresolvedExplicitDestination(local, local),
      isFalse,
    );
  });

  test('originLabel: remote planning says "from <destination>"', () {
    final List<Place> dataset = <Place>[
      _p('1', 'Garden Cafe', 'cafe', 1.2, <String, dynamic>{}),
    ];
    final AutopilotRanking r = AutopilotEngine.rankPlaces(
      candidates: dataset,
      brief: const AutopilotBrief(),
      here: here,
      now: now,
      minutesLeft: 240,
      originLabel: 'from Ayodhya',
    );
    expect(r.practical.first.reasons.first, contains('from Ayodhya'));
    // No label → legacy wording.
    final AutopilotRanking r2 = AutopilotEngine.rankPlaces(
      candidates: dataset,
      brief: const AutopilotBrief(),
      here: here,
      now: now,
      minutesLeft: 240,
    );
    expect(r2.practical.first.reasons.first, contains('away'));
  });

  test('DIVERSITY: a temple town\'s top list is not one monotone category',
      () {
    AutopilotSuggestion s(String id, String cat, double score) =>
        AutopilotSuggestion(
          placeId: id,
          name: id,
          lat: 25.7,
          lng: 82.6,
          category: cat,
          score: score,
          reasons: const <String>[],
          travelMinutes: 5,
          distanceMeters: 1000,
          estimated: true,
          visitMinutes: 30,
        );
    final List<AutopilotSuggestion> ranked = <AutopilotSuggestion>[
      s('t1', 'attraction', 90),
      s('t2', 'attraction', 89),
      s('t3', 'attraction', 88),
      s('t4', 'attraction', 87),
      s('t5', 'attraction', 86),
      s('c1', 'cafe', 85),
      s('p1', 'park', 84),
      s('t6', 'attraction', 83),
    ];
    final List<AutopilotSuggestion> out = AutopilotEngine.diversify(ranked);
    // Nothing is lost.
    expect(out.length, ranked.length);
    // The capped category slides down; nothing is re-ordered arbitrarily.
    expect(
        out.map((AutopilotSuggestion x) => x.placeId).toList(),
        <String>['t1', 't2', 't3', 'c1', 'p1', 't4', 't5', 't6']);
    // Small lists pass through untouched.
    expect(AutopilotEngine.diversify(ranked.take(3).toList()).length, 3);
  });
}
