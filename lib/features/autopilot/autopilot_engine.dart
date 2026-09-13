import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../core/utils/geo.dart';
import '../../data/models/places.dart';
import 'autopilot_models.dart';
import 'opening_hours.dart';

/// TRAVEL AUTOPILOT — the "what next?" engine.
///
/// Pure, testable logic. Recommendations come ONLY from real data:
/// real places (the existing nearby dataset), real distances (haversine) or
/// real OSRM route times, real wall-clock time, and OSM opening hours when
/// present. When data is missing the engine says so ("Opening hours
/// unavailable", "Price unavailable") instead of inventing values.

/// Result of ranking: practical options + things excluded for a REAL
/// reason (closing too soon / doesn't fit remaining time / too far).
@immutable
class AutopilotRanking {
  const AutopilotRanking(this.practical, this.notPractical);
  final List<AutopilotSuggestion> practical;
  final List<(AutopilotSuggestion, String)> notPractical;
}

/// One stop of a generated ⚡ AUTO PLAN sequence.
@immutable
class AutopilotPlanStep {
  const AutopilotPlanStep(this.suggestion, this.travelMinutes);
  final AutopilotSuggestion suggestion;
  final int travelMinutes;
}

/// A generated multi-stop plan with an honest total and fit verdict.
@immutable
class AutopilotPlan {
  const AutopilotPlan(this.steps, this.totalMinutes, this.fits);
  final List<AutopilotPlanStep> steps;
  final int totalMinutes;
  final bool fits;
}

/// 🛟 Recovery outcome when the traveler is running behind schedule.
@immutable
class AutopilotRecovery {
  const AutopilotRecovery(this.keep, this.drop);
  final List<AutopilotStop> keep;
  final List<(AutopilotStop, String)> drop;
}

class AutopilotEngine {
  AutopilotEngine._();

  /// Dataset categories per interest — real tags already fetched by the
  /// existing nearby system (amenity=restaurant, tourism=museum, …).
  static const Map<AutopilotInterest, List<String>> interestCategories =
      <AutopilotInterest, List<String>>{
    AutopilotInterest.eat: <String>['food', 'restaurant', 'cafe', 'fast_food'],
    AutopilotInterest.explore: <String>['attraction', 'museum'],
    AutopilotInterest.shopping: <String>['shopping'],
    AutopilotInterest.relax: <String>['park'],
    AutopilotInterest.entertainment: <String>['attraction'],
    AutopilotInterest.sightseeing: <String>['attraction', 'museum'],
    AutopilotInterest.historical: <String>['museum', 'attraction'],
    AutopilotInterest.family: <String>['park', 'attraction', 'museum'],
    AutopilotInterest.work: <String>['cafe', 'restaurant'],
    AutopilotInterest.roadtrip: <String>['fuel', 'food', 'attraction'],
    // 'other' → no category filter (everything nearby is a candidate).
  };

  /// Sensible on-site duration per dataset category (minutes).
  static const Map<String, int> visitMinutes = <String, int>{
    'restaurant': 45,
    'cafe': 30,
    'fast_food': 25,
    'food': 45,
    'museum': 60,
    'park': 40,
    'attraction': 60,
    'shopping': 50,
    'hotel': 15,
    'transit': 10,
    'fuel': 10,
    'atm': 5,
    'pharmacy': 10,
    'hospital': 30,
    'police': 10,
  };

  static int defaultVisitMinutes(String? category) =>
      visitMinutes[category ?? ''] ?? 30;

  /// Road-distance factor for straight-line estimates (always shown "~").
  static const double roadFactor = 1.35;

  /// Average urban speeds (km/h) per mode.
  static double speedKmh(AutopilotMode m) => switch (m) {
        AutopilotMode.drive => 26,
        AutopilotMode.bike => 16,
        AutopilotMode.walk => 4.6,
      };

  /// Distance-based travel estimate in whole minutes (shown with "~").
  static int estimateTravelMinutes(double meters, AutopilotMode mode) {
    final double km = meters * roadFactor / 1000;
    return math.max(1, (km / speedKmh(mode) * 60).round());
  }

  /// ----------------------------------------------
  /// Natural-language brief parsing (deterministic — no fake AI).
  /// ----------------------------------------------
  static AutopilotBrief parseBrief(String input, {AutopilotBrief? base}) {
    final String t = input.toLowerCase();
    AutopilotBrief out = base ?? const AutopilotBrief();

    // Max travel FIRST: "not more than 20 minutes" must never be counted
    // as available time — mask it out before parsing the duration.
    final RegExp maxRe = RegExp(
        r'(?:not\s*more\s*than|within|under)\s*(\d+)\s*(?:minute|min|km)');
    String work = t;
    final RegExpMatch? xm0 = maxRe.firstMatch(work);
    if (xm0 != null) {
      out = out.copyWith(maxTravelMinutes: int.parse(xm0.group(1)!));
      work = work.replaceRange(xm0.start, xm0.end, ' ');
    }

    // Time: "2 hours", "3h", "30 minutes", "1 hour 30 minutes".
    final RegExp hoursRe = RegExp(r'(\d+(?:\.\d+)?)\s*(?:hours|hour|hrs|hr|h)\b');
    final RegExp minsRe = RegExp(r'(\d+)\s*(?:minutes|minute|mins|min)\b');
    final RegExpMatch? hm = hoursRe.firstMatch(work);
    final RegExpMatch? mm = minsRe.firstMatch(work);
    int? minutes;
    if (hm != null) {
      minutes = (double.parse(hm.group(1)!) * 60).round();
    }
    if (mm != null) {
      final int m = int.parse(mm.group(1)!);
      minutes = minutes == null ? m : minutes + m; // "1 hour 30 minutes"
    }
    if (minutes == null && RegExp(r'half\s*day').hasMatch(t)) minutes = 240;
    if (minutes == null && RegExp(r'all\s*day').hasMatch(t)) minutes = 600;
    if (minutes != null && minutes > 0) {
      out = out.copyWith(availableMinutes: minutes);
    }

    // Budget: "₹1000", "rs 500", "budget of 800".
    final RegExp budgetRe =
        RegExp(r'(?:₹|rs\.?\s*|rupees?\s*|budget\s*(?:of|is)?\s*)(\d+)');
    final RegExpMatch? bm = budgetRe.firstMatch(work);
    if (bm != null) {
      out = out.copyWith(budgetRs: int.parse(bm.group(1)!));
    }

    // Interests + group + mode.
    final Set<AutopilotInterest> found = <AutopilotInterest>{...out.interests};
    bool re(RegExp r) => r.hasMatch(work);
    if (re(RegExp(
        r'eat|food|lunch|dinner|breakfast|khana|restaurant|street food'))) {
      found.add(AutopilotInterest.eat);
    }
    if (re(RegExp(r'histor|fort|museum|palace|heritage|monument'))) {
      found.add(AutopilotInterest.historical);
    }
    if (re(RegExp(r'shop|market|mall|bazaar|bazar'))) {
      found.add(AutopilotInterest.shopping);
    }
    if (re(RegExp(r'relax|peaceful|calm|chill|nature|park|garden'))) {
      found.add(AutopilotInterest.relax);
    }
    if (re(RegExp(r'explore|sightsee|tourist|see places'))) {
      found.add(AutopilotInterest.explore);
    }
    if (re(RegExp(r'family|kids|children'))) {
      found.add(AutopilotInterest.family);
      out = out.copyWith(group: AutopilotGroup.family);
    }
    if (re(RegExp(r'friends|group of'))) {
      out = out.copyWith(group: AutopilotGroup.friends);
    }
    if (re(RegExp(r'\bsolo\b|\balone\b'))) {
      out = out.copyWith(group: AutopilotGroup.solo);
    }
    if (re(RegExp(r'photo'))) found.add(AutopilotInterest.sightseeing);
    if (re(RegExp(r'work|laptop'))) found.add(AutopilotInterest.work);
    if (re(RegExp(r'road\s*trip'))) found.add(AutopilotInterest.roadtrip);
    if (re(RegExp(r'\bwalk(ing)?\b'))) out = out.copyWith(mode: AutopilotMode.walk);
    if (found.isNotEmpty) out = out.copyWith(interests: found);
    return out.copyWith(freeText: input.trim());
  }

  /// ----------------------------------------------
  /// Candidate filtering over the (already-cached, real) nearby dataset —
  /// no new network requests per interest chip. Deduplicated by
  /// name+location; essential services are not "destinations".
  /// ----------------------------------------------
  static List<Place> candidatesFor(
    List<Place> dataset,
    AutopilotBrief brief, {
    double excludeLat = -999,
    double excludeLng = -999,
  }) {
    final Set<String>? wanted = brief.interests.isEmpty
        ? null
        : <String>{
            for (final AutopilotInterest i in brief.interests)
              ...(interestCategories[i] ?? const <String>[]),
          };
    final Map<String, Place> seen = <String, Place>{};
    for (final Place p in dataset) {
      if (p.name.trim().isEmpty) continue;
      if (wanted != null &&
          wanted.isNotEmpty &&
          !(wanted.contains(p.category) ||
              p.types.any((String t) => wanted.contains(t)))) {
        continue;
      }
      const Set<String> skip = <String>{'atm', 'police', 'hospital', 'pharmacy'};
      if (p.category != null && skip.contains(p.category)) continue;
      if (excludeLat > -900 &&
          (p.lat - excludeLat).abs() < 1e-4 &&
          (p.lng - excludeLng).abs() < 1e-4) {
        continue;
      }
      final String key = _dedupKey(p);
      final Place? existing = seen[key];
      if (existing == null ||
          (p.distanceMeters ?? 1e9) < (existing.distanceMeters ?? 1e9)) {
        seen[key] = p;
      }
    }
    return seen.values.toList();
  }

  static String _dedupKey(Place p) {
    final String name = p.name.toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    return '$name|${p.lat.toStringAsFixed(4)}|${p.lng.toStringAsFixed(4)}';
  }

  /// ----------------------------------------------
  /// Ranking: "what you can do NOW".
  ///
  /// [realTravelMinutes] carries REAL OSRM table times keyed by placeId
  /// when the route request succeeded (missing → distance estimate, always
  /// displayed with "~").
  /// ----------------------------------------------
  static AutopilotRanking rankPlaces({
    required List<Place> candidates,
    required AutopilotBrief brief,
    required LatLng here,
    required DateTime now,
    required int minutesLeft,
    Map<String, int> realTravelMinutes = const <String, int>{},
    Map<String, int> learnedInterest = const <String, int>{},
    int limit = 24,
  }) {
    final int? maxTravel = brief.maxTravelMinutes;
    final List<AutopilotSuggestion> ok = <AutopilotSuggestion>[];
    final List<(AutopilotSuggestion, String)> rejected =
        <(AutopilotSuggestion, String)>[];

    for (final Place p in candidates) {
      final double dist = p.distanceMeters ??
          GeoUtils.distanceMeters(here, LatLng(p.lat, p.lng));
      final bool realKnown = realTravelMinutes.containsKey(p.placeId);
      final int travelMin = realKnown
          ? realTravelMinutes[p.placeId]!
          : estimateTravelMinutes(dist, brief.mode);
      final int visit = defaultVisitMinutes(p.category);
      final String cat = p.category ?? '';

      // Interest weight (selected interests first, then session learning).
      int interestHits = 0;
      for (final AutopilotInterest i in brief.interests) {
        if ((interestCategories[i] ?? const <String>[]).contains(cat)) {
          interestHits += 2;
        }
      }
      interestHits += math.min(6, learnedInterest[cat] ?? 0);

      final OpeningHours? oh =
          parseOpeningHours(p.metadata['opening_hours'] as String?);
      final bool hoursKnown = oh != null && oh.appliesTo(now);
      final DateTime? openUntil = hoursKnown ? oh.closesAt(now) : null;
      final int minutesToClose =
          openUntil == null ? -1 : openUntil.difference(now).inMinutes;
      final bool closesTooSoon =
          minutesToClose >= 0 && minutesToClose < travelMin + math.min(visit, 20);
      final bool visitFits = hoursKnown &&
          minutesToClose >= 0 &&
          travelMin + visit <= minutesToClose;

      // Time budget: travel + visit + buffer must fit what's left.
      final bool fitsTime = travelMin + visit + 10 <= minutesLeft;
      final bool withinTravelCap = maxTravel == null || travelMin <= maxTravel;

      double score = 0;
      score += 30 * (1 - math.min(dist, 25000) / 25000); // proximity
      if (fitsTime) score += 20; // time fit
      if (visitFits) {
        score += 15; // confirmed open long enough
      } else if (!hoursKnown) {
        score += 6; // unknown hours — mildly unsure, never assumed open
      }
      score += switch (interestHits) {
        0 => 0,
        1 => 8,
        2 => 18,
        _ => 24,
      };
      if (brief.group == AutopilotGroup.family &&
          (cat == 'park' || cat == 'attraction' || cat == 'museum')) {
        score += 6;
      }
      if (realKnown) score += 4; // real route data is more trustworthy

      final List<String> reasons = <String>[
        '${GeoUtils.formatDistance(dist)} away (~$travelMin min ${_modeWord(brief.mode)})',
        if (visitFits && openUntil != null)
          'Open until ${_hhmm(openUntil)} — enough time to visit'
        else if (hoursKnown && openUntil != null)
          'Closes at ${_hhmm(openUntil)}'
        else
          'Opening hours unavailable',
        if (interestHits >= 2 && brief.interests.isNotEmpty)
          'Matches your ${brief.interests.map((AutopilotInterest i) => i.label).join(' + ')} interest',
        if (fitsTime)
          'Fits your ${_durLabel(minutesLeft)} remaining'
        else
          'Needs ~${travelMin + visit + 10} min — more than your ${_durLabel(minutesLeft)} left',
      ];

      final AutopilotSuggestion s = AutopilotSuggestion(
        placeId: p.placeId,
        name: p.name,
        lat: p.lat,
        lng: p.lng,
        category: cat,
        score: score,
        reasons: reasons,
        travelMinutes: travelMin,
        distanceMeters: dist,
        estimated: !realKnown,
        visitMinutes: visit,
        openUntil: openUntil,
        openingHoursKnown: hoursKnown,
        feeLikely: (p.metadata['fee'] as String?) == 'yes',
      );

      if (closesTooSoon) {
        rejected.add((
          s,
          'Estimated arrival is ${_hhmm(now.add(Duration(minutes: travelMin)))} '
          'and the place closes at ${_hhmm(openUntil!)}'
        ));
      } else if (!fitsTime) {
        rejected.add((s, 'Does not fit your ${_durLabel(minutesLeft)} left'));
      } else if (!withinTravelCap) {
        rejected.add((s, 'Farther than your $maxTravel min travel limit'));
      } else {
        ok.add(s);
      }
    }
    ok.sort((AutopilotSuggestion a, AutopilotSuggestion b) =>
        b.score.compareTo(a.score));
    return AutopilotRanking(ok.take(limit).toList(), rejected);
  }

  /// ----------------------------------------------
  /// ⚡ AUTO PLAN: a practical sequence that fits the available time.
  /// Greedy best-next selection consuming travel + visit + buffer, minus
  /// the return-to-end-destination travel when one is set.
  /// ----------------------------------------------
  static AutopilotPlan buildAutoPlan({
    required List<AutopilotSuggestion> ranked,
    required int minutesLeft,
    int bufferMinutes = 10,
    int? returnMinutes,
  }) {
    final int budget = math.max(
        0, minutesLeft - (returnMinutes ?? 0) - (returnMinutes != null ? bufferMinutes : 0));
    final List<AutopilotPlanStep> used = <AutopilotPlanStep>[];
    final Set<String> taken = <String>{};
    int consumed = 0;
    bool changed = true;
    while (changed) {
      changed = false;
      AutopilotSuggestion? best;
      int bestScore = -1;
      for (final AutopilotSuggestion s in ranked) {
        if (taken.contains(s.placeId)) continue;
        final int cost = s.travelMinutes + s.visitMinutes + bufferMinutes;
        if (consumed + cost > budget) continue;
        final int value = s.score.round();
        if (value > bestScore) {
          bestScore = value;
          best = s;
        }
      }
      if (best != null) {
        taken.add(best.placeId);
        used.add(AutopilotPlanStep(best, best.travelMinutes));
        consumed += best.travelMinutes + best.visitMinutes + bufferMinutes;
        changed = true;
      }
    }
    return AutopilotPlan(used, consumed, used.isNotEmpty);
  }

  /// ----------------------------------------------
  /// 🛟 TRIP RECOVERY: running late → drop tail stops until the plan fits.
  /// ----------------------------------------------
  static AutopilotRecovery recoverPlan({
    required List<AutopilotStop> pending,
    required int minutesLeft,
    int bufferMinutes = 10,
  }) {
    final List<AutopilotStop> keep = <AutopilotStop>[];
    final List<(AutopilotStop, String)> drop = <(AutopilotStop, String)>[];
    int used = 0;
    for (final AutopilotStop s in pending) {
      final int cost = (s.travelMinutes ?? 0) + s.visitMinutes + bufferMinutes;
      if (used + cost <= minutesLeft) {
        keep.add(s);
        used += cost;
      } else {
        drop.add((
          s,
          'Would leave insufficient time — needs ~$cost min of your '
          '${_durLabel(math.max(0, minutesLeft - used))} remaining'
        ));
      }
    }
    return AutopilotRecovery(keep, drop);
  }

  /// ----------------------------------------------
  /// Budget (honest): only transport gets a distance-based ESTIMATE; entry
  /// and food prices are NEVER invented.
  /// ----------------------------------------------
  static int transportEstimateRs(double meters, AutopilotMode mode) {
    final double km = meters * roadFactor / 1000;
    final double perKm = switch (mode) {
      AutopilotMode.drive => 14, // blended auto/cab estimate
      AutopilotMode.bike => 6,
      AutopilotMode.walk => 0,
    };
    return (km * perKm).round();
  }

  static String formatClock(DateTime t) => _hhmm(t);

  static String formatDurationLabel(int minutes) => _durLabel(minutes);

  static String _hhmm(DateTime t) {
    final int h = t.hour % 12 == 0 ? 12 : t.hour % 12;
    final String m = t.minute.toString().padLeft(2, '0');
    final String ap = t.hour >= 12 ? 'PM' : 'AM';
    return '$h:$m $ap';
  }

  static String _durLabel(int minutes) {
    if (minutes < 60) return '${minutes}m';
    final int h = minutes ~/ 60;
    final int m = minutes % 60;
    return m == 0 ? '${h}h' : '${h}h ${m}m';
  }

  static String _modeWord(AutopilotMode m) => switch (m) {
        AutopilotMode.drive => 'drive',
        AutopilotMode.bike => 'ride',
        AutopilotMode.walk => 'walk',
      };
}
