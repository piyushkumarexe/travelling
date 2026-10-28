import 'package:flutter_test/flutter_test.dart';

import 'package:yatrawise/data/models/itinerary.dart';
import 'package:yatrawise/data/models/trip_plan.dart';
import 'package:yatrawise/features/automation/travel_automation_engine.dart';

TripPlan _trip({int days = 3}) => TripPlan(
      id: 'trip-1',
      destination: 'Lucknow',
      lat: 26.8,
      lng: 80.9,
      startDate: DateTime(2026, 10, 10),
      days: days,
      budget: 'mid',
      travelStyle: 'balanced',
      transport: 'car',
      partySize: 2,
      interests: const <String>['history'],
      plan: const <ItineraryDay>[],
      createdAt: DateTime(2026, 9, 25),
    );

void main() {
  test('offers at least fifteen distinct useful automation recipes', () {
    expect(TravelAutomationEngine.definitions.length, greaterThanOrEqualTo(15));
    expect(
      TravelAutomationEngine.definitions
          .map((AutomationDefinition d) => d.kind)
          .toSet()
          .length,
      TravelAutomationEngine.definitions.length,
    );
  });

  test('packing automation is derived from the real trip date', () {
    final List<AutomationEvent> events =
        TravelAutomationEngine.eventsFor(
      kind: TravelAutomationKind.packing,
      trip: _trip(),
      now: DateTime(2026, 9, 25),
    );
    expect(events, hasLength(1));
    expect(events.single.at, DateTime(2026, 10, 8, 19));
  });

  test('hydration rhythm schedules three prompts per trip day', () {
    final List<AutomationEvent> events =
        TravelAutomationEngine.eventsFor(
      kind: TravelAutomationKind.hydration,
      trip: _trip(days: 4),
      now: DateTime(2026, 9, 25),
    );
    expect(events, hasLength(12));
    expect(events, orderedEquals(<AutomationEvent>[...events]..sort(
      (AutomationEvent a, AutomationEvent b) => a.at.compareTo(b.at),
    )));
  });

  test('past events are never presented as schedulable', () {
    final List<AutomationEvent> events =
        TravelAutomationEngine.eventsFor(
      kind: TravelAutomationKind.tripWrap,
      trip: _trip(days: 1),
      now: DateTime(2026, 10, 20),
    );
    expect(events, isEmpty);
  });
}
