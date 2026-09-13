import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../data/models/incident.dart';
import '../../data/models/safety_zone.dart';
import '../utils/geo.dart';

/// Safety assessment levels shown across the app.
///
/// • normal  — data exists and nothing concerning is near
/// • caution — flagged area / recent report nearby
/// • alert   — critical-risk area / multiple recent reports nearby
/// • limited — not enough local data to assess (never fabricate safety)
enum SafetyLevel { normal, caution, alert, limited }

/// A safety verdict with honest, clearly-labelled wording. Every conclusion
/// is "based on available reports/zones" — never a claim that an area is
/// officially safe or dangerous.
class SafetyAssessment {
  const SafetyAssessment({
    required this.level,
    required this.headline,
    required this.detail,
  });

  final SafetyLevel level;
  final String headline;
  final String detail;

  bool get hasData => level != SafetyLevel.limited;
}

/// Pure, deterministic safety logic over real data (admin-verified safety
/// zones and the user's own incident reports). No network, no fabrication.
class SafetyEngine {
  SafetyEngine._();

  static const double zoneBufferM = 500;
  static const double incidentRadiusM = 2000;

  /// Status for a single location.
  static SafetyAssessment locationStatus({
    required LatLng point,
    required List<SafetyZone> zones,
    required List<Incident> ownIncidents,
    Duration recentWindow = const Duration(days: 7),
  }) {
    final List<SafetyZone> active = zones.where((SafetyZone z) => z.active).toList();
    final DateTime cutoff = DateTime.now().subtract(recentWindow);

    SafetyZone? critical;
    SafetyZone? high;
    bool nearHighIncident = false;

    for (final SafetyZone z in active) {
      final double d =
          GeoUtils.distanceMeters(point, LatLng(z.lat, z.lng));
      if (d > z.radiusMeters + zoneBufferM) continue;
      if (z.riskLevel == 'critical') {
        critical ??= z;
      } else if (z.riskLevel == 'high') {
        high ??= z;
      }
    }
    for (final Incident i in ownIncidents) {
      if (i.createdAt.isBefore(cutoff)) continue;
      if (i.severity != 'high' && i.severity != 'critical') continue;
      if (GeoUtils.distanceMeters(point, LatLng(i.lat, i.lng)) <=
          incidentRadiusM) {
        nearHighIncident = true;
        break;
      }
    }

    if (critical != null) {
      return SafetyAssessment(
        level: SafetyLevel.alert,
        headline: 'Critical-risk area nearby',
        detail:
            '${critical.name} (critical risk) is close by. Based on available safety data.',
      );
    }
    if (high != null || nearHighIncident) {
      return const SafetyAssessment(
        level: SafetyLevel.caution,
        headline: 'Caution: risk area or recent report nearby',
        detail: 'Based on available reports — stay alert and prefer well-lit routes.',
      );
    }
    if (active.isEmpty && ownIncidents.isEmpty) {
      return const SafetyAssessment(
        level: SafetyLevel.limited,
        headline: 'Safety data limited',
        detail: 'Not enough local safety data to assess this area yet.',
      );
    }
    return const SafetyAssessment(
      level: SafetyLevel.normal,
      headline: 'Safety data looks normal',
      detail: 'No active safety zones or recent reports near you. Based on available data.',
    );
  }

  /// Assesses a route polyline against safety zones and the user's own
  /// recent reports. Returns the worst level touched by the route.
  static SafetyAssessment routeAssessment({
    required List<LatLng> polyline,
    required List<SafetyZone> zones,
    required List<Incident> ownIncidents,
    Duration recentWindow = const Duration(days: 7),
  }) {
    if (polyline.length < 2) {
      return const SafetyAssessment(
        level: SafetyLevel.limited,
        headline: 'Safety data limited',
        detail: 'Route geometry is unavailable.',
      );
    }
    final List<SafetyZone> active = zones.where((SafetyZone z) => z.active).toList();
    final DateTime cutoff = DateTime.now().subtract(recentWindow);
    final List<LatLng> sample = _sample(polyline, 200);

    int worstRank = 0; // 1 low, 2 medium, 3 high, 4 critical
    SafetyZone? worstZone;
    for (final SafetyZone z in active) {
      final int rank = _rank(z.riskLevel);
      if (rank <= worstRank) continue;
      final bool touches = sample.any((LatLng p) =>
          GeoUtils.distanceMeters(p, LatLng(z.lat, z.lng)) <=
          z.radiusMeters + zoneBufferM);
      if (touches) {
        worstRank = rank;
        worstZone = z;
      }
    }

    bool nearHighIncident = false;
    for (final Incident i in ownIncidents) {
      if (i.createdAt.isBefore(cutoff)) continue;
      if (i.severity != 'high' && i.severity != 'critical') continue;
      final bool near = sample.any((LatLng p) =>
          GeoUtils.distanceMeters(p, LatLng(i.lat, i.lng)) <=
          incidentRadiusM);
      if (near) {
        nearHighIncident = true;
        break;
      }
    }

    if (worstRank >= 4) {
      return SafetyAssessment(
        level: SafetyLevel.alert,
        headline: 'Route crosses a critical-risk area',
        detail:
            '${worstZone?.name ?? 'A critical-risk area'} lies on this route. Based on available safety data.',
      );
    }
    if (worstRank == 3 || nearHighIncident) {
      return const SafetyAssessment(
        level: SafetyLevel.caution,
        headline: 'Moderate-risk area or recent report ahead',
        detail: 'This route passes near a flagged area. Based on available reports.',
      );
    }
    if (active.isEmpty && ownIncidents.isEmpty) {
      return const SafetyAssessment(
        level: SafetyLevel.limited,
        headline: 'Safety data limited',
        detail: 'Not enough data to assess this route. Recommended based on available safety data.',
      );
    }
    return const SafetyAssessment(
      level: SafetyLevel.normal,
      headline: 'Recommended route',
      detail: 'No flagged areas or recent reports along this route. Recommended based on available safety data.',
    );
  }

  static List<LatLng> _sample(List<LatLng> pts, int max) {
    if (pts.length <= max) return pts;
    final List<LatLng> out = <LatLng>[];
    final double step = (pts.length - 1) / (max - 1);
    for (int i = 0; i < max; i++) {
      out.add(pts[(i * step).round()]);
    }
    return out;
  }

  static int _rank(String riskLevel) => switch (riskLevel) {
        'low' => 1,
        'medium' => 2,
        'high' => 3,
        'critical' => 4,
        _ => 0,
      };
}
