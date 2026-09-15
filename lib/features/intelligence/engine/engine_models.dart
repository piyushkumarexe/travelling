// 🧠 Travel Intelligence Engine — models.
//
// Everything here operates on the EXISTING saved trip data (TripPlan /
// ItineraryDay / ItineraryItem) plus real inputs (OSRM legs, parsed costs).
// No prices, ratings, hours or durations are ever invented — unknown values
// stay null/unknown and are displayed as such.

import '../../../data/models/itinerary.dart';

/// What-if scenario kinds supported by the simulator.
enum ScenarioType {
  trainDelay('Train delay'),
  flightDelay('Flight delay'),
  attractionClosure('Attraction closed'),
  transportUnavailable('Transport unavailable'),
  reducedTime('Less time available'),
  reducedBudget('Reduced budget'),
  delayedCheckIn('Delayed hotel check-in'),
  removedStop('Remove a stop'),
  custom('Custom delay');

  const ScenarioType(this.label);
  final String label;
}

/// One what-if scenario. All fields optional depending on [type].
class ScenarioSpec {
  const ScenarioSpec({
    required this.type,
    this.delayMinutes = 60,
    this.dayIndex = 0,
    this.removeDayIndex,
    this.removeItemIndex,
    this.availableMinutesPerDay,
    this.budgetPct = 100,
    this.newStartMin,
  });

  final ScenarioType type;
  final int delayMinutes;
  final int dayIndex;
  final int? removeDayIndex;
  final int? removeItemIndex;

  /// For reducedTime: the shorter daily window in minutes (e.g. 360 = 6 h).
  final int? availableMinutesPerDay;

  /// For reducedBudget: percentage of the original budget (50–150).
  final int budgetPct;

  /// For delayedCheckIn: the later start of the day, minutes from midnight.
  final int? newStartMin;
}

/// Result of applying a scenario to a COPY of the plan.
class SimulationResult {
  const SimulationResult({
    required this.days,
    required this.summary,
    this.dropped = const <String>[],
    this.conflicts = const <String>[],
  });

  final List<ItineraryDay> days;
  final String summary;
  final List<String> dropped;
  final List<String> conflicts;

  bool get changed => dropped.isNotEmpty || conflicts.isNotEmpty;
}

// ---------------- robustness ----------------

/// One measurable robustness factor and its contribution.
class RobustnessFactor {
  const RobustnessFactor(
      this.name, this.impact, this.detail, this.suggestion);
  final String name;
  final int impact; // negative reduces the score, positive adds slack credit
  final String detail;
  final String? suggestion;
}

class RobustnessReport {
  const RobustnessReport({
    required this.score,
    required this.factors,
  });

  final int score; // 0–100
  final List<RobustnessFactor> factors;

  String get band => score >= 80
      ? 'Robust'
      : score >= 60
          ? 'Okay'
          : score >= 40
              ? 'Fragile'
              : 'Very fragile';
}

// ---------------- dependency graph ----------------

class DependencyNode {
  const DependencyNode({
    required this.dayIndex,
    required this.itemIndex,
    required this.label,
    required this.startMin,
  });
  final int dayIndex;
  final int itemIndex;
  final String label;
  final int? startMin;
}

class DependencyGraph {
  const DependencyGraph({required this.nodes, required this.edges});

  /// Ordered as day → item sequence.
  final List<DependencyNode> nodes;

  /// Edges (from, to): sequential chains + same-time co-dependencies.
  final List<(int, int)> edges;

  /// Node indices affected when [nodeIndex] slips by [delayMinutes] —
  /// the whole downstream chain of its day (time is sequential).
  List<int> affectedBy(int nodeIndex, int delayMinutes,
      {int maxDelayTolerance = 30}) {
    if (delayMinutes <= 0) return const <int>[];
    final List<int> out = <int>[];
    final DependencyNode start = nodes[nodeIndex];
    for (int i = nodeIndex + 1; i < nodes.length; i++) {
      final DependencyNode n = nodes[i];
      if (n.dayIndex != start.dayIndex) continue;
      out.add(i);
    }
    return out;
  }
}

// ---------------- constraints / trade-off ----------------

class ConstraintSet {
  const ConstraintSet({
    this.mustVisit = const <String>[],
    this.avoid = const <String>[],
    this.maxMinutesPerDay,
    this.budgetCapInr,
    this.maxItemsPerDay,
  });

  /// Titles (case-insensitive contains) that MUST remain in the plan.
  final List<String> mustVisit;
  final List<String> avoid;
  final int? maxMinutesPerDay;
  final int? budgetCapInr; // only compared against PARSEABLE item costs
  final int? maxItemsPerDay;
}

class SolverResult {
  const SolverResult({
    required this.days,
    required this.kept,
    required this.dropped,
    required this.violations,
  });

  final List<ItineraryDay> days;
  final List<String> kept;
  final List<String> dropped;

  /// Human explanations of which constraints conflict — empty when feasible.
  final List<String> violations;

  bool get feasible => violations.isEmpty;
}

/// Real optimization weights from the trade-off sliders (0–100 each).
class TradeOffProfile {
  const TradeOffProfile({
    this.timeVsExperience = 50, // 0 = max time efficiency, 100 = experience
    this.budgetPref = 50, // 0 = lowest spend, 100 = higher budget ok
    this.travelVsDestinations = 50, // 0 = min travel, 100 = more stops
    this.relaxedVsPacked = 50, // 0 = relaxed, 100 = packed
  });

  final int timeVsExperience;
  final int budgetPref;
  final int travelVsDestinations;
  final int relaxedVsPacked;

  int get targetItemsPerDay => (2 + (relaxedVsPacked / 100.0) * 4).round();
}

// ---------------- contradictions ----------------

enum Severity { critical, warning, info }

class Contradiction {
  const Contradiction(this.severity, this.title, this.detail);
  final Severity severity;
  final String title;
  final String detail;
}

// ---------------- group preferences ----------------

class GroupMemberPref {
  const GroupMemberPref({
    required this.name,
    this.liked = const <String>[],
    this.disliked = const <String>[],
  });
  final String name;
  final List<String> liked; // keyword matches against item titles
  final List<String> disliked;
}

class GroupResult {
  const GroupResult({
    required this.days,
    required this.kept,
    required this.dropped,
    required this.satisfaction,
    required this.compromises,
  });
  final List<ItineraryDay> days;
  final List<String> kept;
  final List<String> dropped;
  final int satisfaction; // 0–100 overall satisfied-preference share
  final List<String> compromises;
}

// ---------------- why not ----------------

class WhyNotReason {
  const WhyNotReason(this.reason, this.detail);
  final String reason;
  final String detail;
}
