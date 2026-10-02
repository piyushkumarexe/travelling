import 'dart:convert';

import 'package:flutter/foundation.dart';

/// TRAVEL AUTOPILOT — data model.
///
/// Everything here is derived from REAL inputs (GPS location, real nearby
/// places, OSRM routes, wall-clock time). Nothing is invented: when a value
/// (price, opening hours) is unknown the model carries an explicit
/// "unavailable" marker instead of a guess.

/// High-level interests the traveler can pick. Each maps onto the REAL
/// dataset categories used by the existing nearby-places system.
enum AutopilotInterest {
  eat('Eat', '🍽️'),
  stay('Hotels & stays', '🏨'),
  explore('Explore', '🏛️'),
  shopping('Shopping', '🛍️'),
  relax('Relax', '🌳'),
  entertainment('Entertainment', '🎭'),
  sightseeing('Sightseeing', '📸'),
  historical('Historical places', '🕌'),
  family('Family', '👨‍👩‍👧'),
  work('Work', '💼'),
  roadtrip('Road trip', '🚗'),
  other('Something else', '🎯');

  const AutopilotInterest(this.label, this.emoji);
  final String label;
  final String emoji;

  static AutopilotInterest? tryOf(String name) => AutopilotInterest.values
      .where((AutopilotInterest i) => i.name == name)
      .firstOrNull;
}

/// Companion/group mode (explicitly selected by the user — no assumptions).
enum AutopilotGroup { solo, family, friends }

/// Travel mode — only modes the existing OSRM integration supports.
enum AutopilotMode { drive, bike, walk }

/// Status of one stop in the autopilot journey.
enum AutopilotStopStatus { proposed, accepted, visited, skipped, removed }

/// Typed failures so the UI never lies about what went wrong.
enum AutopilotErrorKind {
  noResults,
  networkError,
  rateLimited,
  locationUnavailable,
  invalidData,
}

/// What the traveler asked for. Only `availableMinutes` is REQUIRED.
@immutable
class AutopilotBrief {
  const AutopilotBrief({
    this.interests = const <AutopilotInterest>{},
    this.availableMinutes,
    this.budgetRs,
    this.maxTravelMinutes,
    this.mode = AutopilotMode.drive,
    this.group = AutopilotGroup.solo,
    this.endName,
    this.endLat,
    this.endLng,
    this.freeText,
  });

  final Set<AutopilotInterest> interests;
  final int? availableMinutes;
  final int? budgetRs;
  final int? maxTravelMinutes;
  final AutopilotMode mode;
  final AutopilotGroup group;
  final String? endName;
  final double? endLat;
  final double? endLng;
  final String? freeText;

  bool get isEmpty =>
      interests.isEmpty &&
      availableMinutes == null &&
      budgetRs == null &&
      maxTravelMinutes == null &&
      freeText == null &&
      endName == null;

  AutopilotBrief copyWith({
    Set<AutopilotInterest>? interests,
    int? availableMinutes,
    int? budgetRs,
    int? maxTravelMinutes,
    AutopilotMode? mode,
    AutopilotGroup? group,
    String? endName,
    double? endLat,
    double? endLng,
    String? freeText,
  }) {
    return AutopilotBrief(
      interests: interests ?? this.interests,
      availableMinutes: availableMinutes ?? this.availableMinutes,
      budgetRs: budgetRs ?? this.budgetRs,
      maxTravelMinutes: maxTravelMinutes ?? this.maxTravelMinutes,
      mode: mode ?? this.mode,
      group: group ?? this.group,
      endName: endName ?? this.endName,
      endLat: endLat ?? this.endLat,
      endLng: endLng ?? this.endLng,
      freeText: freeText ?? this.freeText,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'interests': interests.map((AutopilotInterest i) => i.name).toList(),
        'availableMinutes': availableMinutes,
        'budgetRs': budgetRs,
        'maxTravelMinutes': maxTravelMinutes,
        'mode': mode.name,
        'group': group.name,
        'endName': endName,
        'endLat': endLat,
        'endLng': endLng,
        'freeText': freeText,
      };

  static AutopilotBrief fromJson(Map<String, dynamic> m) => AutopilotBrief(
        interests: ((m['interests'] as List?) ?? const <dynamic>[])
            .whereType<String>()
            .map((String n) => AutopilotInterest.tryOf(n))
            .whereType<AutopilotInterest>()
            .toSet(),
        availableMinutes: (m['availableMinutes'] as num?)?.toInt(),
        budgetRs: (m['budgetRs'] as num?)?.toInt(),
        maxTravelMinutes: (m['maxTravelMinutes'] as num?)?.toInt(),
        mode: AutopilotMode.values
                .where((AutopilotMode v) => v.name == m['mode'])
                .firstOrNull ??
            AutopilotMode.drive,
        group: AutopilotGroup.values
                .where((AutopilotGroup v) => v.name == m['group'])
                .firstOrNull ??
            AutopilotGroup.solo,
        endName: m['endName'] as String?,
        endLat: (m['endLat'] as num?)?.toDouble(),
        endLng: (m['endLng'] as num?)?.toDouble(),
        freeText: m['freeText'] as String?,
      );

  String encode() => jsonEncode(toJson());

  static AutopilotBrief decode(String raw) =>
      AutopilotBrief.fromJson((jsonDecode(raw) as Map).cast<String, dynamic>());
}

/// One stop of the journey (a REAL place; light snapshot for persistence).
@immutable
class AutopilotStop {
  const AutopilotStop({
    required this.id,
    required this.name,
    required this.lat,
    required this.lng,
    required this.category,
    required this.status,
    this.visitMinutes = 30,
    this.travelMinutes,
    this.distanceMeters,
    this.arrivedAt,
    this.reason,
  });

  final String id;
  final String name;
  final double lat;
  final double lng;
  final String category;
  final AutopilotStopStatus status;
  final int visitMinutes;

  /// Estimated/real travel time from the previous point, in minutes.
  final int? travelMinutes;
  final double? distanceMeters;
  final DateTime? arrivedAt;
  final String? reason;

  AutopilotStop copyWith({
    AutopilotStopStatus? status,
    int? travelMinutes,
    double? distanceMeters,
    DateTime? arrivedAt,
    String? reason,
  }) {
    return AutopilotStop(
      id: id,
      name: name,
      lat: lat,
      lng: lng,
      category: category,
      status: status ?? this.status,
      visitMinutes: visitMinutes,
      travelMinutes: travelMinutes ?? this.travelMinutes,
      distanceMeters: distanceMeters ?? this.distanceMeters,
      arrivedAt: arrivedAt ?? this.arrivedAt,
      reason: reason ?? this.reason,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'lat': lat,
        'lng': lng,
        'category': category,
        'status': status.name,
        'visitMinutes': visitMinutes,
        'travelMinutes': travelMinutes,
        'distanceMeters': distanceMeters,
        'arrivedAt': arrivedAt?.millisecondsSinceEpoch,
        'reason': reason,
      };

  static AutopilotStop fromJson(Map<String, dynamic> m) => AutopilotStop(
        id: (m['id'] as String?) ?? '',
        name: (m['name'] as String?) ?? '',
        lat: (m['lat'] as num?)?.toDouble() ?? 0,
        lng: (m['lng'] as num?)?.toDouble() ?? 0,
        category: (m['category'] as String?) ?? '',
        status: AutopilotStopStatus.values
                .where((AutopilotStopStatus v) => v.name == m['status'])
                .firstOrNull ??
            AutopilotStopStatus.proposed,
        visitMinutes: (m['visitMinutes'] as num?)?.toInt() ?? 30,
        travelMinutes: (m['travelMinutes'] as num?)?.toInt(),
        distanceMeters: (m['distanceMeters'] as num?)?.toDouble(),
        arrivedAt: m['arrivedAt'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch((m['arrivedAt'] as num).toInt()),
        reason: m['reason'] as String?,
      );
}

/// A ranked "what you can do now" recommendation with honest reasons.
@immutable
class AutopilotSuggestion {
  const AutopilotSuggestion({
    required this.placeId,
    required this.name,
    required this.lat,
    required this.lng,
    required this.category,
    required this.score,
    required this.reasons,
    required this.travelMinutes,
    required this.distanceMeters,
    required this.estimated,
    required this.visitMinutes,
    this.openUntil,
    this.openingHoursKnown = false,
    this.feeLikely = false,
  });

  final String placeId;
  final String name;
  final double lat;
  final double lng;
  final String category;

  /// 0..100 practical score (distance, time fit, hours, interests).
  final double score;
  final List<String> reasons;

  /// Real OSRM minutes when available, otherwise a distance-based estimate
  /// ([estimated] == true — always shown with "~").
  final int travelMinutes;
  final double distanceMeters;
  final bool estimated;
  final int visitMinutes;

  /// When the place closes TODAY (local) when known from OSM opening_hours.
  final DateTime? openUntil;
  final bool openingHoursKnown;

  /// OSM `fee=yes` — the app knows a fee EXISTS but never the price.
  final bool feeLikely;

  AutopilotStop toStop(AutopilotStopStatus status) => AutopilotStop(
        id: placeId,
        name: name,
        lat: lat,
        lng: lng,
        category: category,
        status: status,
        visitMinutes: visitMinutes,
        travelMinutes: travelMinutes,
        distanceMeters: distanceMeters,
      );
}

/// The running autopilot journey. Restored from disk on app restart.
@immutable
class AutopilotSession {
  const AutopilotSession({
    required this.id,
    required this.brief,
    required this.startedAt,
    required this.endsAt,
    required this.stops,
    this.originName = 'Current location',
    this.originLat,
    this.originLng,
  });

  final String id;
  final AutopilotBrief brief;
  final DateTime startedAt;
  final DateTime endsAt;
  final List<AutopilotStop> stops;
  final String originName;
  final double? originLat;
  final double? originLng;

  Duration leftFrom(DateTime now) =>
      endsAt.isAfter(now) ? endsAt.difference(now) : Duration.zero;

  List<AutopilotStop> stopsWithStatus(AutopilotStopStatus s) =>
      stops.where((AutopilotStop st) => st.status == s).toList();

  bool get hasActiveStop =>
      stops.any((AutopilotStop st) => st.status == AutopilotStopStatus.accepted);

  AutopilotStop? get currentStop => stops
      .where((AutopilotStop st) => st.status == AutopilotStopStatus.accepted)
      .firstOrNull;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'brief': brief.toJson(),
        'startedAt': startedAt.millisecondsSinceEpoch,
        'endsAt': endsAt.millisecondsSinceEpoch,
        'stops': stops.map((AutopilotStop s) => s.toJson()).toList(),
        'originName': originName,
        'originLat': originLat,
        'originLng': originLng,
      };

  static AutopilotSession fromJson(Map<String, dynamic> m) => AutopilotSession(
        id: (m['id'] as String?) ?? '',
        brief: AutopilotBrief.fromJson(
            ((m['brief'] as Map?) ?? const <String, dynamic>{})
                .cast<String, dynamic>()),
        startedAt: DateTime.fromMillisecondsSinceEpoch(
            ((m['startedAt'] as num?) ?? 0).toInt()),
        endsAt: DateTime.fromMillisecondsSinceEpoch(
            ((m['endsAt'] as num?) ?? 0).toInt()),
        stops: ((m['stops'] as List?) ?? const <dynamic>[])
            .whereType<Map>()
            .map((Map s) => AutopilotStop.fromJson(s.cast<String, dynamic>()))
            .toList(),
        originName: (m['originName'] as String?) ?? 'Current location',
        originLat: (m['originLat'] as num?)?.toDouble(),
        originLng: (m['originLng'] as num?)?.toDouble(),
      );

  String encode() => jsonEncode(toJson());

  static AutopilotSession decode(String raw) => AutopilotSession.fromJson(
      (jsonDecode(raw) as Map).cast<String, dynamic>());
}
