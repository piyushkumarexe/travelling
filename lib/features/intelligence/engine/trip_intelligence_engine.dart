// 🧠 Travel Intelligence Engine — deterministic logic over the EXISTING
// saved trip plan (ItineraryDay/ItineraryItem). Every function is pure so it
// can run on a temporary copy (what-if) without touching the real trip, and
// every unknown (costs that don't parse, missing durations) stays unknown —
// nothing is fabricated.

import '../../../data/models/itinerary.dart';
import 'engine_models.dart';

class TripIntelligenceEngine {
  TripIntelligenceEngine._();

  // ---------------- parsing helpers ----------------

  /// "09:30" → 570. Returns null when the time string is unusable.
  static int? timeToMin(String time) {
    final RegExp m = RegExp(r'^(\d{1,2})[:.](\d{2})$');
    final RegExpMatch? match = m.firstMatch(time.trim());
    if (match == null) return null;
    final int h = int.parse(match.group(1)!);
    final int min = int.parse(match.group(2)!);
    if (h > 23 || min > 59) return null;
    return h * 60 + min;
  }

  static String minToTime(int minutes) {
    final int m = minutes.clamp(0, 24 * 60 - 1);
    return '${(m ~/ 60).toString().padLeft(2, '0')}:${(m % 60).toString().padLeft(2, '0')}';
  }

  /// Parses an INR amount from a cost string like "₹500" / "INR 1200 per
  /// person". Returns null when no number is present — never a guess.
  static int? costInr(String cost) {
    final RegExp r = RegExp(r'(?:₹|rs\.?|inr)\s*([0-9][0-9,]*)',
        caseSensitive: false);
    final RegExpMatch? match = r.firstMatch(cost.toLowerCase());
    if (match == null) return null;
    return int.tryParse(match.group(1)!.replaceAll(',', ''));
  }

  /// Total PARSEABLE cost of the plan (unknown costs are not invented).
  static int? planCost(List<ItineraryDay> days) {
    int total = 0;
    bool any = false;
    for (final ItineraryDay d in days) {
      for (final ItineraryItem i in d.items) {
        final int? c = costInr(i.cost);
        if (c != null) {
          total += c;
          any = true;
        }
      }
    }
    return any ? total : null;
  }

  static ItineraryDay _cloneDay(ItineraryDay d) => ItineraryDay(
        day: d.day,
        title: d.title,
        items: d.items
            .map((ItineraryItem i) => ItineraryItem(
                  time: i.time,
                  title: i.title,
                  description: i.description,
                  cost: i.cost,
                ))
            .toList(),
      );

  static List<ItineraryDay> clonePlan(List<ItineraryDay> plan) =>
      plan.map(_cloneDay).toList();

  // ---------------- 1) what-if simulator ----------------

  /// Applies [spec] to a COPY of [plan]. The original is never touched;
  /// the caller decides whether to Apply.
  static SimulationResult simulate(List<ItineraryDay> plan, ScenarioSpec spec) {
    final List<ItineraryDay> days = clonePlan(plan);
    final List<String> dropped = <String>[];
    final List<String> conflicts = <String>[];

    switch (spec.type) {
      case ScenarioType.trainDelay:
      case ScenarioType.flightDelay:
      case ScenarioType.attractionClosure:
      case ScenarioType.transportUnavailable:
      case ScenarioType.custom:
      case ScenarioType.delayedCheckIn:
        _shiftDay(days, spec.dayIndex, spec.delayMinutes, dropped, conflicts,
            lateStart: spec.type == ScenarioType.delayedCheckIn);
        break;
      case ScenarioType.reducedTime:
        _shrinkWindow(days, spec.availableMinutesPerDay ?? 360, dropped);
        break;
      case ScenarioType.reducedBudget:
        _cutBudget(days, spec.budgetPct, dropped);
        break;
      case ScenarioType.removedStop:
        final int di = spec.removeDayIndex ?? 0;
        final int ii = spec.removeItemIndex ?? 0;
        if (di < days.length && ii < days[di].items.length) {
          final ItineraryItem removed = days[di].items.removeAt(ii);
          dropped.add('Day ${di + 1}: ${removed.title} (removed by scenario)');
          _closeGaps(days[di]);
        }
        break;
    }
    final String summary = <String>[
      '${spec.type.label}: ',
      if (dropped.isEmpty && conflicts.isEmpty)
        'everything still fits — no changes needed.'
      else ...<String>[
        if (dropped.isNotEmpty) '${dropped.length} stop(s) no longer fit.',
        if (conflicts.isNotEmpty)
          '${conflicts.length} timing conflict(s) created.',
      ],
    ].join();
    return SimulationResult(
        days: days, summary: summary, dropped: dropped, conflicts: conflicts);
  }

  /// Shifts one day's schedule by [delayMinutes] and reflows the rest.
  static void _shiftDay(List<ItineraryDay> days, int dayIndex, int delayMinutes,
      List<String> dropped, List<String> conflicts,
      {bool lateStart = false}) {
    if (dayIndex >= days.length || delayMinutes == 0) return;
    final ItineraryDay day = days[dayIndex];
    if (day.items.isEmpty) return;
    final int shift = delayMinutes;
    int prev = -1;
    for (int i = 0; i < day.items.length; i++) {
      final ItineraryItem it = day.items[i];
      final int? original = timeToMin(it.time);
      int t = (original ?? 0) + shift;
      if (prev >= 0 && t < prev) t = prev; // never overlap
      if (t >= 23 * 60 + 30 && i > 0) {
        dropped.add('Day ${dayIndex + 1}: ${it.title} — pushed to '
            '${minToTime(t)}, too late to keep.');
        day.items.removeAt(i);
        i--;
        continue;
      }
      if (t < prev && i > 0) {
        conflicts.add(
            'Day ${dayIndex + 1}: ${it.title} would overlap the previous '
            'stop (starts ${minToTime(t)}, previous needs until '
            '${minToTime(prev)}).');
        t = prev;
      }
      day.items[i] = ItineraryItem(
          time: minToTime(t),
          title: it.title,
          description: it.description,
          cost: it.cost);
      prev = t + 30; // minimum sensible spacing when reflowing
    }
    if (lateStart) {
      conflicts.add('Day ${dayIndex + 1}: starts ${minToTime(
          (timeToMin(days[dayIndex].items.first.time) ?? 480))} — later '
          'than planned.');
    }
  }

  static void _shrinkWindow(
      List<ItineraryDay> days, int windowMinutes, List<String> dropped) {
    for (int d = 0; d < days.length; d++) {
      final ItineraryDay day = days[d];
      if (day.items.isEmpty) continue;
      final int start = timeToMin(day.items.first.time) ?? 480;
      final int end = start + windowMinutes;
      for (int i = day.items.length - 1; i >= 0; i--) {
        final int t = timeToMin(day.items[i].time) ?? start;
        if (t >= end) {
          dropped.add(
              'Day ${d + 1}: ${day.items[i].title} — outside the shortened '
              'day window.');
          day.items.removeAt(i);
        }
      }
    }
  }

  static void _cutBudget(
      List<ItineraryDay> days, int budgetPct, List<String> dropped) {
    // Drop the costliest PARSEABLE items until the total fits the reduced
    // budget. Items without parseable costs are never touched or invented.
    final int? original = planCost(days);
    if (original == null) return;
    final int cap = original * budgetPct ~/ 100;
    while ((planCost(days) ?? 0) > cap) {
      int? bestCost;
      int bestD = -1;
      int bestI = -1;
      for (int d = 0; d < days.length; d++) {
        for (int i = 0; i < days[d].items.length; i++) {
          final int? c = costInr(days[d].items[i].cost);
          if (c != null && (bestCost == null || c > bestCost)) {
            bestCost = c;
            bestD = d;
            bestI = i;
          }
        }
      }
      if (bestI < 0) break;
      dropped.add(
          'Day ${bestD + 1}: ${days[bestD].items[bestI].title} — dropped '
          '(₹$bestCost) to fit the reduced budget.');
      days[bestD].items.removeAt(bestI);
    }
  }

  static void _closeGaps(ItineraryDay day) {
    int? prev;
    for (int i = 0; i < day.items.length; i++) {
      final int? t = timeToMin(day.items[i].time);
      if (t == null) continue;
      if (prev != null && t < prev) {
        day.items[i] = ItineraryItem(
            time: minToTime(prev),
            title: day.items[i].title,
            description: day.items[i].description,
            cost: day.items[i].cost);
        prev = prev + 30;
      } else {
        prev = t;
      }
    }
  }

  // ---------------- 2) robustness score ----------------

  static RobustnessReport robustness(List<ItineraryDay> plan,
      {String budgetBand = 'mid'}) {
    final List<RobustnessFactor> factors = <RobustnessFactor>[];
    int score = 100;

    int tight = 0;
    int overlaps = 0;
    int totalGaps = 0;
    int gapDays = 0;
    final List<String> tightNames = <String>[];

    for (final ItineraryDay d in plan) {
      final List<int> times = <int>[
        for (final ItineraryItem i in d.items)
          if (timeToMin(i.time) case final int t) t,
      ]..sort();
      if (times.length > 6) {
        factors.add(RobustnessFactor(
            'Overloaded day ${d.day}',
            -8,
            'Day ${d.day} packs ${times.length} stops — one delay cascades '
                'through all of them.',
            'Move a stop to another day or drop one.'));
      }
      for (int i = 1; i < times.length; i++) {
        final int gap = times[i] - times[i - 1];
        totalGaps += gap;
        gapDays++;
        if (gap < 20) {
          tight++;
          if (tightNames.length < 3) {
            tightNames.add('${minToTime(times[i - 1])}→${minToTime(times[i])}');
          }
          if (gap <= 0) overlaps++;
        }
      }
    }
    final int? cost = planCost(plan);
    final int budgetCap = switch (budgetBand) {
      'budget' => 1200,
      'luxury' => 5000,
      _ => 2500,
    };
    if (cost != null && cost > budgetCap * plan.length) {
      factors.add(RobustnessFactor(
          'Budget over committed plan cost',
          -10,
          'Parseable item costs total ₹$cost for ${plan.length} day(s), above '
              'the ${budgetBandBandLabel(budgetBand)} planning band '
              '(₹$budgetCap/day). Items without a parseable cost are not '
              'counted.',
          'Trim or swap the costliest stops.'));
      score -= 10;
    }
    if (tight > 0) {
      final int penalty = (tight * 5).clamp(0, 30);
      factors.add(RobustnessFactor(
          'Tight connections',
          -penalty,
          '$tight transfer gap(s) under 20 minutes'
              '${tightNames.isEmpty ? '' : ' (${tightNames.join(', ')})'}.'
              '${overlaps > 0 ? ' $overlaps overlap(s).' : ''}',
          'Add 30+ minutes between stops.'));
      score -= penalty;
    }
    if (gapDays > 0) {
      final int avg = totalGaps ~/ gapDays;
      if (avg >= 45) {
        factors.add(RobustnessFactor('Healthy buffers', 0,
            'Average $avg min between stops — delays absorb well.', null));
      } else {
        final int penalty = ((45 - avg) ~/ 5).clamp(0, 15);
        factors.add(RobustnessFactor(
            'Thin average buffer',
            -penalty,
            'Average $avg min between stops.',
            'Aim for 45+ min between stops.'));
        score -= penalty;
      }
    }
    if (plan.isNotEmpty && factors.isEmpty) {
      factors.add(const RobustnessFactor(
          'No structural risks found',
          0,
          'Schedule spacing and stops look reasonable.',
          null));
    }
    return RobustnessReport(
        score: score.clamp(0, 100), factors: factors);
  }

  static String budgetBandBandLabel(String band) => switch (band) {
        'budget' => 'budget',
        'luxury' => 'luxury',
        _ => 'mid-range',
      };

  // ---------------- 4) dependency graph ----------------

  static DependencyGraph dependencyGraph(List<ItineraryDay> plan) {
    final List<DependencyNode> nodes = <DependencyNode>[];
    final List<(int, int)> edges = <(int, int)>[];
    for (int d = 0; d < plan.length; d++) {
      int? last;
      for (int i = 0; i < plan[d].items.length; i++) {
        final ItineraryItem it = plan[d].items[i];
        nodes.add(DependencyNode(
            dayIndex: d,
            itemIndex: i,
            label: it.title,
            startMin: timeToMin(it.time)));
        final int here = nodes.length - 1;
        if (last != null) edges.add((last, here));
        last = here;
      }
    }
    return DependencyGraph(nodes: nodes, edges: edges);
  }

  // ---------------- 14) contradiction detector ----------------

  static List<Contradiction> contradictions(List<ItineraryDay> plan) {
    final List<Contradiction> out = <Contradiction>[];
    for (final ItineraryDay d in plan) {
      int? prev;
      String prevTitle = '';
      final Set<String> seen = <String>{};
      for (final ItineraryItem it in d.items) {
        if (seen.contains(it.title.toLowerCase().trim())) {
          out.add(Contradiction(Severity.warning, 'Duplicate stop',
              'Day ${d.day}: "${it.title}" appears more than once.'));
        }
        seen.add(it.title.toLowerCase().trim());
        final int? t = timeToMin(it.time);
        if (t == null) {
          out.add(Contradiction(Severity.info, 'Unset time',
              'Day ${d.day}: "${it.title}" has no usable time.'));
          continue;
        }
        if (prev != null && t < prev) {
          out.add(Contradiction(
              Severity.critical,
              'Impossible sequence',
              'Day ${d.day}: "${it.title}" at ${minToTime(t)} is BEFORE the '
                  'previous stop "$prevTitle" at ${minToTime(prev)}.'));
        } else if (prev != null && t - prev < 15) {
          out.add(Contradiction(
              Severity.warning,
              'Tight transfer',
              'Day ${d.day}: only ${t - prev} min between "$prevTitle" and '
                  '"${it.title}".'));
        }
        if (t >= 23 * 60) {
          out.add(Contradiction(Severity.info, 'Late-night stop',
              'Day ${d.day}: "${it.title}" starts at ${minToTime(t)}.'));
        }
        prev = t;
        prevTitle = it.title;
      }
    }
    return out;
  }

  // ---------------- 11) last safe decision point ----------------

  /// Latest departure time (minutes) to reach a fixed [arrivalDeadlineMin]
  /// after [legMinutes] of travel with [bufferMinutes] of safety.
  /// Classification against the planned [departureMin].
  static (int, String) lastSafeDeparture({
    required int? legMinutes,
    required int bufferMinutes,
    required int arrivalDeadlineMin,
    required int plannedDepartureMin,
  }) {
    if (legMinutes == null) {
      return (
        plannedDepartureMin,
        'Route unavailable — travel time unknown, no safe-departure '
            'calculation possible.'
      );
    }
    final int deadline = arrivalDeadlineMin - legMinutes - bufferMinutes;
    final int slack = plannedDepartureMin - deadline;
    final String state = slack >= 15
        ? 'Safe'
        : slack >= 0
            ? 'Risky'
            : 'No longer feasible';
    return (
      deadline,
      '$state — leave by ${minToTime(deadline.clamp(0, 24 * 60 - 1))} '
          '($legMinutes min route + $bufferMinutes min buffer).'
    );
  }

  // ---------------- 10) constraint solver ----------------

  static SolverResult solveConstraints(
      List<ItineraryDay> plan, ConstraintSet c) {
    final List<ItineraryDay> days = clonePlan(plan);
    final List<String> kept = <String>[];
    final List<String> dropped = <String>[];
    final List<String> violations = <String>[];

    for (int d = 0; d < days.length; d++) {
      final ItineraryDay day = days[d];
      for (int i = day.items.length - 1; i >= 0; i--) {
        final ItineraryItem it = day.items[i];
        final String low = it.title.toLowerCase();
        if (c.avoid.any((String a) => low.contains(a.toLowerCase()))) {
          if (c.mustVisit.any((String m) => low.contains(m.toLowerCase()))) {
            violations.add(
                '"${it.title}" is both must-visit and on the avoid list.');
            continue;
          }
          dropped.add('Day ${d + 1}: ${it.title} (avoided)');
          day.items.removeAt(i);
          continue;
        }
        if (c.maxItemsPerDay != null) {
          final int before = day.items.length;
          if (before > c.maxItemsPerDay!) {
            // Trim from the END, never the must-visits.
            final int excess = before - c.maxItemsPerDay!;
            if (i >= day.items.length - excess &&
                !c.mustVisit.any((String m) => low.contains(m.toLowerCase()))) {
              dropped.add('Day ${d + 1}: ${it.title} (over the stops/day '
                  'limit)');
              day.items.removeAt(i);
            }
          }
        }
      }
      if (c.maxMinutesPerDay != null && day.items.length >= 2) {
        final int first = timeToMin(day.items.first.time) ?? 480;
        final int lastT =
            timeToMin(day.items.last.time) ?? first + c.maxMinutesPerDay!;
        if (lastT - first > c.maxMinutesPerDay!) {
          violations.add(
              'Day ${d + 1} spans ${lastT - first} min — above your '
              '${c.maxMinutesPerDay} min/day limit. Drop or move a stop.');
        }
      }
      kept.addAll(day.items.map((ItineraryItem i) => 'Day ${d + 1}: ${i.title}'));
    }
    final int? cost = planCost(days);
    if (c.budgetCapInr != null && cost != null && cost > c.budgetCapInr!) {
      violations.add(
          'Parseable plan cost ₹$cost exceeds your ₹${c.budgetCapInr} cap. '
          'Either raise the cap or drop paid stops (unparseable costs are '
          'not counted).');
    }
    for (final String m in c.mustVisit) {
      final bool present = days.any((ItineraryDay d) => d.items
          .any((ItineraryItem i) => i.title.toLowerCase().contains(m)));
      if (!present) {
        violations.add('Must-visit "$m" is not in any saved day.');
      }
    }
    return SolverResult(
        days: days, kept: kept, dropped: dropped, violations: violations);
  }

  // ---------------- 12) trade-off optimizer ----------------

  static SolverResult optimize(
      List<ItineraryDay> plan, TradeOffProfile t, ConstraintSet c) {
    final ConstraintSet tuned = ConstraintSet(
      mustVisit: c.mustVisit,
      avoid: c.avoid,
      budgetCapInr: c.budgetCapInr,
      // Sliders really change the output: packedness → stops/day; budget
      // preference scales any explicit cap.
      maxItemsPerDay:
          t.travelVsDestinations >= 60 && t.relaxedVsPacked >= 60
              ? 6
              : t.targetItemsPerDay,
      maxMinutesPerDay: c.maxMinutesPerDay ??
          (t.relaxedVsPacked < 35 ? 480 : 660),
    );
    final SolverResult r = solveConstraints(plan, tuned);
    // Budget preference tightens the cap when the user leans low-spend.
    if (t.budgetPref < 40) {
      final int? cost = planCost(r.days);
      final int cap = (planCost(plan) ?? cost ?? 0) * (t.budgetPref) ~/ 100;
      if (cost != null && cost > cap) {
        final SolverResult tighter =
            solveConstraints(plan, ConstraintSet(
          mustVisit: tuned.mustVisit,
          avoid: tuned.avoid,
          maxItemsPerDay: tuned.maxItemsPerDay,
          maxMinutesPerDay: tuned.maxMinutesPerDay,
          budgetCapInr: cap,
        ));
        return SolverResult(
            days: tighter.days,
            kept: tighter.kept,
            dropped: tighter.dropped,
            violations: r.violations.isEmpty
                ? tighter.violations
                : r.violations);
      }
    }
    return r;
  }

  // ---------------- 13) group conflict resolver ----------------

  static GroupResult resolveGroup(
      List<ItineraryDay> plan, List<GroupMemberPref> members) {
    final List<ItineraryDay> days = clonePlan(plan);
    final List<String> dropped = <String>[];
    final List<String> compromises = <String>[];
    int satisfied = 0;
    int total = 0;

    for (final ItineraryDay d in days) {
      for (int i = d.items.length - 1; i >= 0; i--) {
        final String low = d.items[i].title.toLowerCase();
        int likes = 0;
        int dislikes = 0;
        for (final GroupMemberPref m in members) {
          if (m.disliked.any((String k) => low.contains(k.toLowerCase()))) {
            dislikes++;
          }
          if (m.liked.any((String k) => low.contains(k.toLowerCase()))) {
            likes++;
          }
        }
        total += likes + dislikes;
        satisfied += likes;
        if (likes == 0 && dislikes > 0 && members.length > 1) {
          dropped.add('Day ${d.day + 1}: ${d.items[i].title} — nobody '
              'selected it and $dislikes member(s) dislike it.');
          d.items.removeAt(i);
        } else if (dislikes > 0 && likes > 0) {
          compromises.add('"${d.items[i].title}" kept: $likes like(s) vs '
              '$dislikes dislike(s) — compromise.');
        }
      }
    }
    final int pct = total == 0 ? 100 : (satisfied * 100 ~/ total);
    return GroupResult(
        days: days,
        kept: <String>[for (final d in days) ...d.items.map((i) => i.title)],
        dropped: dropped,
        satisfaction: pct.clamp(0, 100),
        compromises: compromises);
  }

  // ---------------- 6) why not this place ----------------

  static List<WhyNotReason> whyNot({
    required String placeName,
    int? legMinutes,
    int? remainingMinutes,
    required int dayEndMin,
    required int nowMin,
    List<Contradiction> existing = const <Contradiction>[],
    int? costInrValue,
    int? budgetLeft,
    List<String> avoid = const <String>[],
  }) {
    final List<WhyNotReason> out = <WhyNotReason>[];
    if (legMinutes == null) {
      out.add(const WhyNotReason('Route unknown',
          'No route could be calculated right now — travel time cannot be '
          'verified.'));
    } else if (remainingMinutes != null) {
      if (legMinutes > remainingMinutes) {
        out.add(WhyNotReason(
            'Not enough time',
            'The route takes $legMinutes min but only $remainingMinutes min '
                'remain today.'));
      } else if (legMinutes * 2 > remainingMinutes) {
        out.add(WhyNotReason('Excessive detour',
            'Travel there and back is ${legMinutes * 2} min of your '
                '$remainingMinutes remaining minutes.'));
      }
    }
    final int arrival = nowMin + (legMinutes ?? 0);
    if (arrival > dayEndMin) {
      out.add(WhyNotReason('After your day ends',
          'You would arrive around ${minToTime(arrival)}, after your day '
              'ends at ${minToTime(dayEndMin)}.'));
    }
    if (costInrValue != null && budgetLeft != null && costInrValue > budgetLeft) {
      out.add(WhyNotReason('Over budget',
          'It costs ₹$costInrValue but only ₹$budgetLeft is left in your '
              'plan budget.'));
    }
    for (final String a in avoid) {
      if (placeName.toLowerCase().contains(a.toLowerCase())) {
        out.add(WhyNotReason(
            'Your own constraint', 'Matches your avoid-list entry "$a".'));
      }
    }
    if (out.isEmpty) {
      out.add(const WhyNotReason('Nothing against it',
          'No time, distance, budget or constraint problems found with the '
              'data available.'));
    }
    return out;
  }

  // ---------------- 8) time-to-enjoyment ----------------

  /// Travel time is real (OSRM). Visit duration is NOT known from any data
  /// source we have — reported as unknown instead of invented.
  static String timeToEnjoyment(int? legMinutes) {
    if (legMinutes == null) {
      return 'Travel time unknown (route unavailable) · visit duration '
          'unknown';
    }
    return 'Travel $legMinutes min (OSRM) · visit duration unknown';
  }
}
