import 'package:cloud_firestore/cloud_firestore.dart';

import '../../core/utils/eco_math.dart';
import '../models/eco.dart';

class EcoRepository {
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  DocumentReference<Map<String, dynamic>> _scoreRef(String uid) =>
      _db.collection('ecoScores').doc(uid);

  Stream<EcoScore?> watchScore(String uid) => _scoreRef(uid).snapshots().map(
        (DocumentSnapshot<Map<String, dynamic>> d) =>
            d.exists ? EcoScore.fromMap(uid, d.data()) : null,
      );

  Stream<List<EcoActivity>> watchActivities(String uid) => _db
      .collection('ecoScores')
      .doc(uid)
      .collection('activities')
      .orderBy('createdAt', descending: true)
      .limit(100)
      .snapshots()
      .map((QuerySnapshot<Map<String, dynamic>> s) => s.docs
          .map((d) => EcoActivity.fromMap(d.id, d.data()))
          .toList());

  /// Logs an activity and atomically-ish recomputes the score for this user
  /// (single user writes their own score doc — last write wins is fine here).
  Future<void> addActivity(
    String uid,
    EcoActivity activity,
  ) async {
    await _db
        .collection('ecoScores')
        .doc(uid)
        .collection('activities')
        .add(<String, dynamic>{
          'uid': uid,
          'mode': activity.mode,
          'distanceMeters': activity.distanceMeters,
          'durationSeconds': activity.durationSeconds,
          'note': activity.note,
          'createdAt': activity.createdAt.toUtc(),
        });

    final DocumentSnapshot<Map<String, dynamic>> snap =
        await _scoreRef(uid).get();
    final EcoScore current =
        EcoScore.fromMap(uid, snap.exists ? snap.data() : null);
    final EcoScore updated = _apply(current, activity);
    await _scoreRef(uid).set(updated.toMap());
  }

  EcoScore _apply(EcoScore s, EcoActivity a) {
    final int score = s.score + EcoMath.activityPoints(a.mode, a.distanceMeters);
    final Map<String, double> byMode = Map<String, double>.from(s.byMode)
      ..update(
        a.mode,
        (double v) => v + a.distanceMeters,
        ifAbsent: () => a.distanceMeters,
      );
    final int sessions = s.sessions + 1;
    final List<String> badges = EcoMath.badgesFor(
      walkKm: (byMode['walk'] ?? 0) / 1000,
      cycleKm: (byMode['cycle'] ?? 0) / 1000,
      transitKm: (byMode['transit'] ?? 0) / 1000,
      score: score,
      sessions: sessions,
    );
    return EcoScore(
      uid: s.uid,
      score: score,
      byMode: byMode,
      badges: badges,
      sessions: sessions,
      updatedAt: DateTime.now(),
    );
  }
}
