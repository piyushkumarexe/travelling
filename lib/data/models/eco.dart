import 'package:cloud_firestore/cloud_firestore.dart';

/// Eco score + logged eco-friendly travel activities.

class EcoScore {
  EcoScore({
    required this.uid,
    this.score = 0,
    this.byMode = const <String, double>{},
    this.badges = const <String>[],
    this.sessions = 0,
    this.updatedAt,
  });

  final String uid;
  final int score;
  final Map<String, double> byMode;
  final List<String> badges;
  final int sessions;
  final DateTime? updatedAt;

  double get walkKm => (byMode['walk'] ?? 0) / 1000;
  double get cycleKm => (byMode['cycle'] ?? 0) / 1000;
  double get transitKm => (byMode['transit'] ?? 0) / 1000;

  factory EcoScore.fromMap(String uid, Map<String, dynamic>? m) {
    final Map<String, dynamic> d = m ?? <String, dynamic>{};
    return EcoScore(
      uid: uid,
      score: (d['score'] as num?)?.toInt() ?? 0,
      byMode: (d['byMode'] is Map)
          ? (d['byMode'] as Map).map(
              (Object? k, Object? v) => MapEntry(k.toString(), (v as num?)?.toDouble() ?? 0),
            )
          : <String, double>{},
      badges: (d['badges'] is List)
          ? (d['badges'] as List).whereType<String>().toList()
          : <String>[],
      sessions: (d['sessions'] as num?)?.toInt() ?? 0,
      updatedAt: (d['updatedAt'] as Timestamp?)?.toDate(),
    );
  }

  Map<String, dynamic> toMap() => <String, dynamic>{
        'uid': uid,
        'score': score,
        'byMode': byMode,
        'badges': badges,
        'sessions': sessions,
        'updatedAt': updatedAt?.toUtc() ?? DateTime.now().toUtc(),
      };
}

class EcoActivity {
  EcoActivity({
    required this.id,
    required this.uid,
    required this.mode,
    required this.distanceMeters,
    required this.durationSeconds,
    required this.createdAt,
    this.note,
  });

  final String id;
  final String uid;

  /// walk | cycle | transit
  final String mode;
  final double distanceMeters;
  final double durationSeconds;
  final String? note;
  final DateTime createdAt;

  factory EcoActivity.fromMap(String id, Map<String, dynamic> m) => EcoActivity(
        id: id,
        uid: (m['uid'] as String?) ?? '',
        mode: (m['mode'] as String?) ?? 'walk',
        distanceMeters: (m['distanceMeters'] as num?)?.toDouble() ?? 0,
        durationSeconds: (m['durationSeconds'] as num?)?.toDouble() ?? 0,
        note: m['note'] as String?,
        createdAt: (m['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      );
}
