import 'package:cloud_firestore/cloud_firestore.dart';

/// A configured safety zone (admin-managed). Users only read these.
library;

class SafetyZone {
  SafetyZone({
    required this.id,
    required this.name,
    required this.lat,
    required this.lng,
    required this.radiusMeters,
    required this.riskLevel,
    required this.description,
    required this.active,
    this.createdByName,
    this.createdAt,
  });

  final String id;
  final String name;
  final double lat;
  final double lng;
  final double radiusMeters;

  /// low | medium | high | critical
  final String riskLevel;
  final String description;
  final bool active;
  final String? createdByName;
  final DateTime? createdAt;

  factory SafetyZone.fromMap(String id, Map<String, dynamic> m) => SafetyZone(
        id: id,
        name: (m['name'] as String?) ?? 'Unnamed zone',
        lat: (m['lat'] as num?)?.toDouble() ?? 0,
        lng: (m['lng'] as num?)?.toDouble() ?? 0,
        radiusMeters: (m['radiusMeters'] as num?)?.toDouble() ?? 500,
        riskLevel: (m['riskLevel'] as String?) ?? 'medium',
        description: (m['description'] as String?) ?? '',
        active: (m['active'] as bool?) ?? true,
        createdByName: m['createdByName'] as String?,
        createdAt: (m['createdAt'] as Timestamp?)?.toDate(),
      );

  String get riskLabel => switch (riskLevel) {
        'low' => 'Low risk',
        'medium' => 'Medium risk',
        'high' => 'High risk',
        _ => 'Critical risk',
      };

  bool get isHighRisk => riskLevel == 'high' || riskLevel == 'critical';

  Map<String, dynamic> toMap() => <String, dynamic>{
        'name': name,
        'lat': lat,
        'lng': lng,
        'radiusMeters': radiusMeters,
        'riskLevel': riskLevel,
        'description': description,
        'active': active,
        'createdByName': createdByName,
        'updatedAt': Timestamp.now(),
      };
}
