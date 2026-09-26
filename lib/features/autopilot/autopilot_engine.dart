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
    AutopilotInterest.eat: <String>[
      'food', 'restaurant', 'cafe', 'fast_food', 'bakery', 'food_court'
    ],
    AutopilotInterest.stay: <String>[
      'hotel', 'lodging', 'hostel', 'guest_house', 'motel', 'resort'
    ],
    AutopilotInterest.explore: <String>[
      'attraction', 'tourist_attraction', 'museum', 'viewpoint',
      'place_of_worship', 'historical_landmark', 'monument', 'fort', 'palace',
      'zoo', 'amusement_park', 'water_park'
    ],
    AutopilotInterest.shopping: <String>[
      'shopping', 'shopping_mall', 'market', 'marketplace', 'store'
    ],
    AutopilotInterest.relax: <String>[
      'park', 'garden', 'viewpoint', 'nature_reserve'
    ],
    AutopilotInterest.entertainment: <String>[
      'attraction', 'tourist_attraction', 'cinema', 'theatre',
      'amusement_park', 'zoo'
    ],
    AutopilotInterest.sightseeing: <String>[
      'attraction', 'tourist_attraction', 'museum', 'viewpoint',
      'place_of_worship', 'historical_landmark', 'monument'
    ],
    AutopilotInterest.historical: <String>[
      'museum', 'attraction', 'tourist_attraction', 'historical_landmark',
      'monument', 'fort', 'palace', 'archaeological_site', 'place_of_worship',
      'hindu_temple', 'mosque', 'church', 'gurudwara'
    ],
    AutopilotInterest.family: <String>[
      'park', 'garden', 'attraction', 'tourist_attraction', 'museum', 'zoo',
      'amusement_park', 'aquarium'
    ],
    AutopilotInterest.work: <String>[
      'cafe', 'restaurant', 'library', 'coworking_space'
    ],
    AutopilotInterest.roadtrip: <String>[
      'fuel', 'food', 'restaurant', 'attraction', 'tourist_attraction',
      'viewpoint'
    ],
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
  /// Destination extraction from free text ("I want to explore Ayodhya").
  /// ----------------------------------------------
  static final Set<String> _destinationStopwords = <String>{
    // pronouns / auxiliaries
    'i', 'we', 'my', 'me', 'mine', 'you', 'your', 'is', 'are', 'was', 'be',
    'want', 'wanted', 'would', 'will', 'like', 'likes', 'love', 'going',
    'go', 'get', 'got', 'find', 'show', 'recommend', 'suggest', 'plan',
    'planning', 'make', 'makes', 'need',
    // prepositions / articles / conjunctions
    'for', 'in', 'at', 'near', 'around', 'to', 'the', 'a', 'an', 'of',
    'and', 'or', 'with', 'from', 'by', 'about', 'some', 'something', 'else',
    // activity words (parseBrief already turns these into interests/modes)
    'explore', 'exploring', 'visit', 'visiting', 'see', 'seeing',
    'sightseeing', 'sightsee', 'travel', 'travelling', 'traveling',
    'eat', 'eating', 'food', 'restaurant', 'restaurants', 'hotel', 'hotels',
    'stay', 'stays', 'shopping', 'shop', 'relax', 'relaxing', 'chill',
    'entertainment', 'historical', 'history', 'family', 'friends',
    'friend', 'solo', 'alone', 'work', 'working', 'laptop', 'road', 'trip',
    'biking', 'cycling', 'bike', 'driving', 'drive', 'walking', 'walk',
    'cycle', 'cyclo',
    // time / budget words
    'hours', 'hour', 'hrs', 'hr', 'minutes', 'minute', 'mins', 'min',
    'day', 'days', 'morning', 'afternoon', 'evening', 'night', 'today',
    'tomorrow', 'budget', 'rupees', 'rupee', 'rs', 'cost', 'cheap',
    'expensive', 'km', 'kilometer', 'kilometers',
    // generic place words
    'places', 'place', 'spots', 'spot', 'somewhere', 'anywhere', 'here',
    'there', 'things', 'thing', 'attractions', 'attraction', 'tour', 'tours',
    'sight', 'sights', 'park', 'parks', 'water', 'theme', 'amusement',
    'cinema', 'movie', 'movies', 'theatre', 'zoo', 'museum', 'museums',
    // common Hindi/Hinglish fillers ("main Ayodhya jaana chahta hoon")
    'main', 'maine', 'hain', 'hai', 'jaana', 'jaane', 'jaau', 'jaun', 'ja',
    'chahta', 'chahata', 'chahati', 'chahti', 'hoon', 'ho', 'karna', 'karo',
    'kare', 'chahiye', 'thoda', 'thodi', 'ke', 'ka', 'ki', 'ko', 'se',
    'mein', 'par', 'liye', 'kuch', 'kisi', 'aur', 'yahan', 'wahan',
    'dekha', 'dekhe', 'dikhao', 'lejaao',
  };

  /// The place-name candidate inside a free-text request, or null when the
  /// text names no place. Strips stopwords / interest words / pure numbers
  /// so "I want to explore Ayodhya in 2 hours with friends" → "ayodhya".
  /// The SERVICE geocodes the result — the engine never invents coordinates.
  ///
  /// Generic fragments ("old city", "some market") are NOT candidates: at
  /// least one kept token must be long enough to be a real place name,
  /// otherwise a geocode could redirect the whole session somewhere random.
  static String? destinationCandidate(String freeText) {
    final List<String> tokens = freeText
        .toLowerCase()
        .split(RegExp(r'[^a-z0-9\u0900-\u097F]+'))
        .where((String t) => t.isNotEmpty)
        .toList();
    final List<String> kept = <String>[];
    for (final String t in tokens) {
      if (RegExp(r'^\d+$').hasMatch(t)) continue; // pure number = a duration
      if (t.length < 3) continue;
      if (_destinationStopwords.contains(t)) continue;
      kept.add(t);
    }
    if (kept.isEmpty) return null;
    if (!kept.any((String t) => t.length >= 5)) return null;
    return kept.join(' ');
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
    if (re(RegExp(r'hotel|hostel|resort|guest\s*house|lodg|\bstay\b'))) {
      found.add(AutopilotInterest.stay);
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
    if (re(RegExp(r'explore|sightsee|tourist|see places|famous|ghumna|ghumne'))) {
      found.add(AutopilotInterest.explore);
    }
    if (re(RegExp(
        r'water\s*park|amusement|theme\s*park|cinema|movie|theatre|entertainment|fun'))) {
      found.add(AutopilotInterest.entertainment);
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
      const Set<String> skip = <String>{
        'atm', 'police', 'police_station', 'hospital', 'pharmacy',
        'fire_station', 'fuel', 'gas_station', 'bank', 'post_office',
      };
      if ((p.category != null && skip.contains(p.category)) ||
          (p.primaryType != null && skip.contains(p.primaryType)) ||
          p.types.any(skip.contains)) {
        continue;
      }
      if (excludeLat > -900 &&
          (p.lat - excludeLat).abs() < 1e-4 &&
          (p.lng - excludeLng).abs() < 1e-4) {
        continue;
      }
      final String name = _normalizedName(p.name);
      String? key;
      for (final MapEntry<String, Place> entry in seen.entries) {
        if (!entry.key.startsWith('$name|')) continue;
        if (GeoUtils.distanceMeters(entry.value.coords, p.coords) <= 500) {
          key = entry.key;
          break;
        }
      }
      key ??= '$name|${p.lat.toStringAsFixed(3)}|${p.lng.toStringAsFixed(3)}';
      final Place? existing = seen[key];
      if (existing == null ||
          (p.distanceMeters ?? 1e9) < (existing.distanceMeters ?? 1e9)) {
        seen[key] = p;
      }
    }
    return seen.values.toList();
  }

  static String _normalizedName(String value) => value
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9\u0900-\u097F]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  /// ----------------------------------------------
  /// Ranking: "what you can do NOW".
  ///
  /// [realTravelMinutes] carries REAL OSRM table times keyed by placeId
  /// when the route request succeeded (missing → distance estimate, always
  /// displayed with "~").
  /// ----------------------------------------------
  /// [originLabel] replaces the plain "away" in the distance reason when the
  /// ranking base is NOT the traveller's nose (e.g. exploring a destination
  /// city from a distance: "4.9 km from Ayodhya").
  static AutopilotRanking rankPlaces({
    required List<Place> candidates,
    required AutopilotBrief brief,
    required LatLng here,
    required DateTime now,
    required int minutesLeft,
    Map<String, int> realTravelMinutes = const <String, int>{},
    Map<String, int> learnedInterest = const <String, int>{},
    String? originLabel,
    int limit = 24,
  }) {
    final int? maxTravel = brief.maxTravelMinutes;
    // Words the traveller typed are a stronger signal than old/default chips.
    // "explore Kanpur" must put attractions above a nearby restaurant even
    // if Eat was also left selected from an earlier choice.
    final Set<AutopilotInterest> textPriorities =
        (brief.freeText ?? '').trim().isEmpty
            ? const <AutopilotInterest>{}
            : parseBrief(brief.freeText!).interests;
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
        final List<String> categories =
            interestCategories[i] ?? const <String>[];
        final bool matches = categories.contains(cat) ||
            p.types.any(categories.contains) ||
            (p.primaryType != null && categories.contains(p.primaryType));
        if (matches) {
          interestHits += textPriorities.contains(i) ? 5 : 2;
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
        >= 5 => 42,
        _ => 28,
      };
      // Provider popularity is optional, but when available it helps put a
      // city's established sights ahead of obscure generic POIs. Never invent
      // a rating: absent values add nothing.
      if (p.rating != null) {
        score += p.rating!.clamp(0, 5).toDouble() * 2;
      }
      if (p.userRatingCount != null && p.userRatingCount! > 0) {
        score += math
            .min(10.0, math.log(p.userRatingCount! + 1) / math.ln10 * 3)
            .toDouble();
      }
      if (brief.group == AutopilotGroup.family &&
          (cat == 'park' || cat == 'attraction' || cat == 'museum')) {
        score += 6;
      }
      if (realKnown) score += 4; // real route data is more trustworthy

      final List<String> reasons = <String>[
        '${GeoUtils.formatDistance(dist)} ${originLabel ?? 'away'} '
            '(~$travelMin min ${_modeWord(brief.mode)})',
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
    return AutopilotRanking(diversify(ok.take(limit).toList()), rejected);
  }

  /// Light category diversity for the visible top of the list.
  ///
  /// In places where one tag dominates the OSM data (a temple town where
  /// nearly every "attraction" is a temple or mosque) a pure score sort
  /// shows one monotone card stack. In the first [topN] slots at most [cap]
  /// entries per category are allowed; capped entries are NOT discarded —
  /// they slide down in score order and the rest of the list keeps its
  /// original ranking. When the area genuinely has only one category the
  /// output is identical to a plain sort (honest, no invented variety).
  static List<AutopilotSuggestion> diversify(
    List<AutopilotSuggestion> ranked, {
    int topN = 9,
    int cap = 3,
  }) {
    if (ranked.length <= cap) return ranked;
    final Map<String, int> counts = <String, int>{};
    final List<AutopilotSuggestion> head = <AutopilotSuggestion>[];
    final List<AutopilotSuggestion> tail = <AutopilotSuggestion>[];
    for (final AutopilotSuggestion s in ranked) {
      if (head.length < topN) {
        final String cat = s.category.isEmpty ? '_' : s.category;
        final int c = counts[cat] ?? 0;
        if (c < cap) {
          counts[cat] = c + 1;
          head.add(s);
          continue;
        }
      }
      tail.add(s);
    }
    return <AutopilotSuggestion>[...head, ...tail];
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
