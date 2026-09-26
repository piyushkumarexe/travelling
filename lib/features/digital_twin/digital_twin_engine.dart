import 'package:flutter/foundation.dart';

/// Every value shown by the simulator carries an honest provenance. The UI
/// must never present an assumption as live data.
enum TwinEvidence { routed, current, providerStatic, userScenario, unavailable }

enum TwinCrowdScenario { low, normal, high }

enum TwinTravelMode { walk, car }

enum TwinAccessNeed {
  wheelchair,
  elderly,
  stroller,
  avoidStairs,
  limitedWalking,
  heavyLuggage,
}

@immutable
class TwinRouteMetric {
  const TwinRouteMetric({
    required this.mode,
    required this.distanceMeters,
    required this.durationMinutes,
    required this.approximate,
  });

  final TwinTravelMode mode;
  final double distanceMeters;
  final int durationMinutes;
  final bool approximate;
}

@immutable
class TwinSimulationInput {
  const TwinSimulationInput({
    required this.departure,
    required this.crowd,
    required this.maximumWalkingMeters,
    required this.maximumBudgetRupees,
    required this.availableMinutes,
    required this.assumedBaseQueueMinutes,
    required this.visitMinutes,
    required this.walkRoute,
    required this.carRoute,
    this.accessNeeds = const <TwinAccessNeed>{},
    this.destinationWheelchairAccess,
    this.knownStairSections,
    this.knownAccessibleEntrances,
  });

  final DateTime departure;
  final TwinCrowdScenario crowd;
  final double maximumWalkingMeters;
  final double maximumBudgetRupees;
  final int availableMinutes;

  /// Explicit user/model assumption—not a claim about current crowd.
  final int assumedBaseQueueMinutes;
  final int visitMinutes;
  final TwinRouteMetric? walkRoute;
  final TwinRouteMetric? carRoute;
  final Set<TwinAccessNeed> accessNeeds;
  final bool? destinationWheelchairAccess;
  final int? knownStairSections;
  final int? knownAccessibleEntrances;
}

@immutable
class TwinStage {
  const TwinStage({
    required this.title,
    required this.detail,
    required this.minutes,
    required this.evidence,
  });

  final String title;
  final String detail;
  final int minutes;
  final TwinEvidence evidence;
}

@immutable
class TwinScenarioOption {
  const TwinScenarioOption({
    required this.title,
    required this.mode,
    required this.totalMinutes,
    required this.walkingMeters,
    required this.estimatedCostRupees,
    required this.feasible,
    required this.reason,
  });

  final String title;
  final TwinTravelMode mode;
  final int totalMinutes;
  final double walkingMeters;
  final double estimatedCostRupees;
  final bool feasible;
  final String reason;
}

@immutable
class TwinSimulationResult {
  const TwinSimulationResult({
    required this.stages,
    required this.options,
    required this.recommended,
    required this.totalMinutes,
    required this.walkingMeters,
    required this.estimatedCostRupees,
    required this.queueMinutes,
    required this.trafficDelayMinutes,
    required this.withinTime,
    required this.withinWalking,
    required this.withinBudget,
    required this.accessibilityWarnings,
    required this.dataWarnings,
  });

  final List<TwinStage> stages;
  final List<TwinScenarioOption> options;
  final TwinScenarioOption? recommended;
  final int totalMinutes;
  final double walkingMeters;
  final double estimatedCostRupees;
  final int queueMinutes;
  final int trafficDelayMinutes;
  final bool withinTime;
  final bool withinWalking;
  final bool withinBudget;
  final List<String> accessibilityWarnings;
  final List<String> dataWarnings;

  bool get feasible => withinTime && withinWalking && withinBudget;
}

abstract final class DigitalTwinEngine {
  static TwinSimulationResult simulate(TwinSimulationInput input) {
    final bool mobilitySensitive = input.accessNeeds.any(
      <TwinAccessNeed>{
        TwinAccessNeed.wheelchair,
        TwinAccessNeed.elderly,
        TwinAccessNeed.stroller,
        TwinAccessNeed.avoidStairs,
        TwinAccessNeed.limitedWalking,
        TwinAccessNeed.heavyLuggage,
      }.contains,
    );

    final double crowdFactor = switch (input.crowd) {
      TwinCrowdScenario.low => 0.65,
      TwinCrowdScenario.normal => 1.0,
      TwinCrowdScenario.high => 1.65,
    };
    final int queueMinutes =
        (input.assumedBaseQueueMinutes * crowdFactor).round();
    final int hour = input.departure.hour;
    // This is deliberately a transparent scenario coefficient, not claimed
    // live traffic. Routing duration remains provider data.
    final double trafficFactor =
        ((hour >= 8 && hour < 11) || (hour >= 17 && hour < 20)) ? 1.20 : 1.0;

    final List<TwinScenarioOption> options = <TwinScenarioOption>[];
    void addOption(String title, TwinRouteMetric? route, double cost) {
      if (route == null) return;
      final int trafficDelay = route.mode == TwinTravelMode.car
          ? (route.durationMinutes * (trafficFactor - 1)).round()
          : 0;
      final int total = route.durationMinutes +
          trafficDelay +
          queueMinutes +
          input.visitMinutes;
      final double walking =
          route.mode == TwinTravelMode.walk ? route.distanceMeters : 0;
      final bool timeOk = total <= input.availableMinutes;
      final bool walkOk = walking <= input.maximumWalkingMeters;
      final bool budgetOk = cost <= input.maximumBudgetRupees;
      final String reason = !timeOk
          ? 'Exceeds available time by ${total - input.availableMinutes} min'
          : !walkOk
              ? 'Exceeds walking limit by ${(walking - input.maximumWalkingMeters).round()} m'
              : !budgetOk
                  ? 'Exceeds budget by ₹${(cost - input.maximumBudgetRupees).ceil()}'
                  : route.approximate
                      ? 'Fits constraints, but route geometry is approximate'
                      : 'Fits the selected constraints';
      options.add(TwinScenarioOption(
        title: title,
        mode: route.mode,
        totalMinutes: total,
        walkingMeters: walking,
        estimatedCostRupees: cost,
        feasible: timeOk && walkOk && budgetOk,
        reason: reason,
      ));
    }

    addOption('Walk-first', input.walkRoute, 0);
    final TwinRouteMetric? car = input.carRoute;
    // This is a clearly labelled budget estimate, never a live fare.
    final double carEstimate = car == null
        ? 0
        : (50 + (car.distanceMeters / 1000) * 12).ceilToDouble();
    addOption(mobilitySensitive ? 'Mobility-first' : 'Faster road option',
        car, carEstimate);

    TwinScenarioOption? recommended;
    final List<TwinScenarioOption> feasible =
        options.where((TwinScenarioOption o) => o.feasible).toList()
          ..sort((TwinScenarioOption a, TwinScenarioOption b) {
            if (mobilitySensitive) {
              final int walking = a.walkingMeters.compareTo(b.walkingMeters);
              if (walking != 0) return walking;
            }
            return a.totalMinutes.compareTo(b.totalMinutes);
          });
    if (feasible.isNotEmpty) {
      recommended = feasible.first;
    } else if (options.isNotEmpty) {
      options.sort((TwinScenarioOption a, TwinScenarioOption b) =>
          a.totalMinutes.compareTo(b.totalMinutes));
      recommended = options.first;
    }

    final TwinRouteMetric? selectedRoute = recommended == null
        ? null
        : recommended.mode == TwinTravelMode.walk
            ? input.walkRoute
            : input.carRoute;
    final int trafficDelay = selectedRoute?.mode == TwinTravelMode.car
        ? ((selectedRoute!.durationMinutes * (trafficFactor - 1)).round())
        : 0;
    final int travelMinutes = selectedRoute?.durationMinutes ?? 0;
    final double walking = recommended?.walkingMeters ?? 0;
    final double cost = recommended?.estimatedCostRupees ?? 0;
    final int total = travelMinutes +
        trafficDelay +
        queueMinutes +
        input.visitMinutes;

    final List<TwinStage> stages = <TwinStage>[
      TwinStage(
        title: 'Depart',
        detail:
            '${input.departure.hour.toString().padLeft(2, '0')}:${input.departure.minute.toString().padLeft(2, '0')} selected departure',
        minutes: 0,
        evidence: TwinEvidence.userScenario,
      ),
      if (selectedRoute != null)
        TwinStage(
          title: selectedRoute.mode == TwinTravelMode.walk
              ? 'Walk to destination'
              : 'Travel to destination',
          detail: selectedRoute.mode == TwinTravelMode.walk
              ? '${selectedRoute.distanceMeters.round()} m routed walking'
              : '${(selectedRoute.distanceMeters / 1000).toStringAsFixed(1)} km road route'
                  '${cost > 0 ? ' · ₹${cost.round()} estimated transport' : ''}',
          minutes: travelMinutes + trafficDelay,
          evidence: TwinEvidence.routed,
        ),
      TwinStage(
        title: 'Entry / queue allowance',
        detail:
            '${input.crowd.name} crowd scenario · user-adjustable assumption',
        minutes: queueMinutes,
        evidence: TwinEvidence.userScenario,
      ),
      TwinStage(
        title: 'Destination visit',
        detail: 'User-selected visit allowance',
        minutes: input.visitMinutes,
        evidence: TwinEvidence.userScenario,
      ),
    ];

    final List<String> accessWarnings = <String>[];
    if (input.accessNeeds.contains(TwinAccessNeed.wheelchair) &&
        input.destinationWheelchairAccess != true) {
      accessWarnings.add(input.destinationWheelchairAccess == false
          ? 'Provider data marks wheelchair access as unavailable.'
          : 'Wheelchair access is not verified in available destination data.');
    }
    if (input.accessNeeds.contains(TwinAccessNeed.avoidStairs) &&
        input.knownStairSections == null) {
      accessWarnings.add(
          'Stair count is unavailable; confirm the route with the venue before departure.');
    }
    if (mobilitySensitive && input.knownAccessibleEntrances == null) {
      accessWarnings.add(
          'Accessible entrance count is unavailable in current provider data.');
    }

    final List<String> dataWarnings = <String>[
      'Crowd, queue and peak-hour effects are scenario estimates—not live crowd or traffic data.',
      if (selectedRoute == null)
        'No route could be loaded.'
      else if (selectedRoute.approximate)
        'The selected route is approximate.',
      if (recommended?.mode == TwinTravelMode.car) ...<String>[
        'Transport cost is an estimate, not a live provider fare.',
        'On-site walking after the road-route endpoint is unknown and is not included in the walking total.',
      ],
    ];

    return TwinSimulationResult(
      stages: stages,
      options: options,
      recommended: recommended,
      totalMinutes: total,
      walkingMeters: walking,
      estimatedCostRupees: cost,
      queueMinutes: queueMinutes,
      trafficDelayMinutes: trafficDelay,
      withinTime: total <= input.availableMinutes,
      withinWalking: walking <= input.maximumWalkingMeters,
      withinBudget: cost <= input.maximumBudgetRupees,
      accessibilityWarnings: accessWarnings,
      dataWarnings: dataWarnings,
    );
  }
}
