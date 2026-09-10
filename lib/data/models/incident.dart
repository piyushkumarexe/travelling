import 'package:cloud_firestore/cloud_firestore.dart';

/// A user-submitted incident (photo/video stored in Firebase Storage,
/// AI analysis stored inline).

class Incident {
  Incident({
    required this.id,
    required this.uid,
    required this.reporterName,
    required this.description,
    required this.category,
    required this.severity,
    required this.status,
    required this.lat,
    required this.lng,
    required this.createdAt,
    this.summary,
    this.recommendedAction,
    this.photoUrl,
    this.videoUrl,
  });

  final String id;
  final String uid;
  final String reporterName;
  final String description;

  /// theft | fraud | assault | harassment | accident | unsafe_area |
  /// poor_infrastructure | natural_hazard | other
  final String category;

  /// low | medium | high | critical
  final String severity;

  /// reported | under_review | resolved | dismissed
  final String status;
  final double lat;
  final double lng;
  final String? summary;
  final String? recommendedAction;
  final String? photoUrl;
  final String? videoUrl;
  final DateTime createdAt;

  factory Incident.fromMap(String id, Map<String, dynamic> m) {
    final Map<String, dynamic> loc =
        (m['location'] is Map) ? m['location'] as Map<String, dynamic> : <String, dynamic>{};
    return Incident(
      id: id,
      uid: (m['uid'] as String?) ?? '',
      reporterName: (m['reporterName'] as String?) ?? 'Anonymous',
      description: (m['description'] as String?) ?? '',
      category: (m['category'] as String?) ?? 'other',
      severity: (m['severity'] as String?) ?? 'medium',
      status: (m['status'] as String?) ?? 'reported',
      lat: (loc['lat'] as num?)?.toDouble() ?? 0,
      lng: (loc['lng'] as num?)?.toDouble() ?? 0,
      summary: m['summary'] as String?,
      recommendedAction: m['recommendedAction'] as String?,
      photoUrl: m['photoUrl'] as String?,
      videoUrl: m['videoUrl'] as String?,
      createdAt: (m['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
    );
  }

  String get severityLabel => switch (severity) {
        'low' => 'Low',
        'medium' => 'Medium',
        'high' => 'High',
        _ => 'Critical',
      };

  String get statusLabel => switch (status) {
        'reported' => 'Reported',
        'under_review' => 'Under review',
        'resolved' => 'Resolved',
        _ => 'Dismissed',
      };

  String get categoryLabel {
    const Map<String, String> labels = <String, String>{
      'theft': 'Theft',
      'fraud': 'Fraud',
      'assault': 'Assault',
      'harassment': 'Harassment',
      'accident': 'Accident',
      'unsafe_area': 'Unsafe area',
      'poor_infrastructure': 'Poor infrastructure',
      'natural_hazard': 'Natural hazard',
      'other': 'Other',
    };
    return labels[category] ?? 'Other';
  }

  Map<String, dynamic> toMap() => <String, dynamic>{
        'uid': uid,
        'reporterName': reporterName,
        'description': description,
        'category': category,
        'severity': severity,
        'status': status,
        'location': <String, double>{'lat': lat, 'lng': lng},
        'summary': summary,
        'recommendedAction': recommendedAction,
        'photoUrl': photoUrl,
        'videoUrl': videoUrl,
        'createdAt': createdAt.toUtc(),
        'updatedAt': DateTime.now().toUtc(),
      };
}
