import 'package:cloud_firestore/cloud_firestore.dart';

/// An SOS emergency event created when the user activates SOS.

class EmergencyEvent {
  EmergencyEvent({
    required this.id,
    required this.uid,
    required this.name,
    required this.lat,
    required this.lng,
    required this.status,
    required this.createdAt,
    this.accuracyMeters,
    this.resolvedAt,
  });

  final String id;
  final String uid;
  final String name;
  final double lat;
  final double lng;

  /// active | cancelled | resolved
  final String status;
  final double? accuracyMeters;
  final DateTime createdAt;
  final DateTime? resolvedAt;

  factory EmergencyEvent.fromMap(String id, Map<String, dynamic> m) {
    final Map<String, dynamic> loc =
        (m['location'] is Map) ? m['location'] as Map<String, dynamic> : <String, dynamic>{};
    return EmergencyEvent(
      id: id,
      uid: (m['uid'] as String?) ?? '',
      name: (m['name'] as String?) ?? 'Unknown',
      lat: (loc['lat'] as num?)?.toDouble() ?? 0,
      lng: (loc['lng'] as num?)?.toDouble() ?? 0,
      status: (m['status'] as String?) ?? 'active',
      accuracyMeters: (loc['accuracy'] as num?)?.toDouble(),
      createdAt: (m['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      resolvedAt: (m['resolvedAt'] as Timestamp?)?.toDate(),
    );
  }

  bool get isActive => status == 'active';

  String get statusLabel => switch (status) {
        'active' => 'ACTIVE',
        'cancelled' => 'Cancelled',
        _ => 'Resolved',
      };
}
