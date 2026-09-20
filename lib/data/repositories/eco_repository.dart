import 'package:cloud_firestore/cloud_firestore.dart';

import '../../core/utils/eco_math.dart';
import '../local/eco_local_store.dart';
import '../models/eco.dart';

/// Eco score + activities. Primary store is Firestore (synced across the
/// user's devices); when Firestore is unavailable or its rules reject the
/// request, callers fall back to [local] so measurement still works.
class EcoRepository {
  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final EcoLocalStore local = EcoLocalStore();

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

  /// Logs an activity and recomputes the score for this user. Throws
  /// [FirebaseException] when the cloud rejects the write — callers then use
  /// [localAddActivity] so nothing is lost.
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
    await _scoreRef(uid).set(EcoMath.applyActivity(current, activity).toMap());
  }

  /// On-device fallback: same score math, stored locally. Returns the
  /// updated score so the UI can refresh immediately.
  Future<EcoScore> localAddActivity(String uid, EcoActivity activity) =>
      local.addActivity(uid, activity);

  /// True when [e] means the cloud rejected the request (rules/offline) and a
  /// local fallback is the right move.
  static bool shouldFallback(Object e) {
    if (e is FirebaseException) {
      final String code = e.code.toLowerCase();
      return code.contains('permission-denied') ||
          code.contains('unavailable') ||
          code.contains('unauthenticated');
    }
    return false;
  }
}
