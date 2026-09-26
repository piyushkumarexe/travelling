import 'package:flutter_test/flutter_test.dart';
import 'package:yatrawise/features/digital_twin/digital_twin_engine.dart';

TwinSimulationInput input({
  TwinCrowdScenario crowd = TwinCrowdScenario.normal,
  DateTime? departure,
  double maxWalking = 2000,
  double budget = 1000,
  int available = 240,
  Set<TwinAccessNeed> access = const <TwinAccessNeed>{},
  bool? wheelchair,
}) =>
    TwinSimulationInput(
      departure: departure ?? DateTime(2026, 9, 26, 7, 30),
      crowd: crowd,
      maximumWalkingMeters: maxWalking,
      maximumBudgetRupees: budget,
      availableMinutes: available,
      assumedBaseQueueMinutes: 20,
      visitMinutes: 90,
      walkRoute: const TwinRouteMetric(
        mode: TwinTravelMode.walk,
        distanceMeters: 1800,
        durationMinutes: 25,
        approximate: false,
      ),
      carRoute: const TwinRouteMetric(
        mode: TwinTravelMode.car,
        distanceMeters: 5000,
        durationMinutes: 18,
        approximate: false,
      ),
      accessNeeds: access,
      destinationWheelchairAccess: wheelchair,
    );

void main() {
  test('high crowd scenario changes queue and total without claiming live data', () {
    final TwinSimulationResult low =
        DigitalTwinEngine.simulate(input(crowd: TwinCrowdScenario.low));
    final TwinSimulationResult high =
        DigitalTwinEngine.simulate(input(crowd: TwinCrowdScenario.high));

    expect(high.queueMinutes, greaterThan(low.queueMinutes));
    expect(high.totalMinutes, greaterThan(low.totalMinutes));
    expect(high.dataWarnings.join(' '), contains('scenario estimates'));
  });

  test('limited walking selects the road option when it fits', () {
    final TwinSimulationResult result = DigitalTwinEngine.simulate(input(
      maxWalking: 700,
      access: const <TwinAccessNeed>{TwinAccessNeed.limitedWalking},
    ));

    expect(result.recommended?.mode, TwinTravelMode.car);
    expect(result.walkingMeters, 0);
    expect(result.withinWalking, isTrue);
  });

  test('a zero budget rejects estimated car cost and preserves free walk', () {
    final TwinSimulationResult result =
        DigitalTwinEngine.simulate(input(budget: 0));

    expect(result.recommended?.mode, TwinTravelMode.walk);
    expect(result.recommended?.estimatedCostRupees, 0);
    expect(result.withinBudget, isTrue);
  });

  test('peak departure adds explicit scenario traffic delay only to car route', () {
    final TwinSimulationResult offPeak = DigitalTwinEngine.simulate(input(
      maxWalking: 500,
      departure: DateTime(2026, 9, 26, 7),
    ));
    final TwinSimulationResult peak = DigitalTwinEngine.simulate(input(
      maxWalking: 500,
      departure: DateTime(2026, 9, 26, 9),
    ));

    expect(offPeak.trafficDelayMinutes, 0);
    expect(peak.trafficDelayMinutes, greaterThan(0));
    expect(peak.totalMinutes, greaterThan(offPeak.totalMinutes));
  });

  test('unknown accessibility data is surfaced rather than invented', () {
    final TwinSimulationResult result = DigitalTwinEngine.simulate(input(
      access: const <TwinAccessNeed>{
        TwinAccessNeed.wheelchair,
        TwinAccessNeed.avoidStairs,
      },
    ));

    final String warnings = result.accessibilityWarnings.join(' ');
    expect(warnings, contains('not verified'));
    expect(warnings, contains('Stair count is unavailable'));
    expect(warnings, contains('entrance count is unavailable'));
  });

  test('time constraint marks an unrealistic visit infeasible', () {
    final TwinSimulationResult result =
        DigitalTwinEngine.simulate(input(available: 60));

    expect(result.withinTime, isFalse);
    expect(result.feasible, isFalse);
    expect(result.options.every((TwinScenarioOption o) => !o.feasible), isTrue);
  });
}
