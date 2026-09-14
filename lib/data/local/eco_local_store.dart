import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../core/utils/eco_math.dart';
import '../models/eco.dart';

/// On-device eco score + activities store.
///
/// Used automatically when Firestore is unavailable or its security rules
/// reject the request, so Eco Score still measures and logs even without a
/// working cloud connection. Data is kept per signed-in user (uid).
class EcoLocalStore {
  static const String _scoreKeyPrefix = 'eco_score_';
  static const String _activitiesKeyPrefix = 'eco_activities_';

  String _scoreKey(String uid) => '$_scoreKeyPrefix$uid';
  String _activitiesKey(String uid) => '$_activitiesKeyPrefix$uid';

  Future<SharedPreferences> get _prefs => SharedPreferences.getInstance();

  Future<EcoScore?> readScore(String uid) async {
    final SharedPreferences p = await _prefs;
    final String? raw = p.getString(_scoreKey(uid));
    if (raw == null) return null;
    try {
      final Map<String, dynamic> m =
          (jsonDecode(raw) as Map).map((Object? k, Object? v) =>
              MapEntry(k.toString(), v));
      return EcoScore.fromMap(uid, m);
    } catch (_) {
      return null;
    }
  }

  Future<List<EcoActivity>> readActivities(String uid) async {
    final SharedPreferences p = await _prefs;
    final String? raw = p.getString(_activitiesKey(uid));
    if (raw == null) return const <EcoActivity>[];
    try {
      final List<dynamic> list = jsonDecode(raw) as List;
      return list
          .whereType<Map>()
          .map((Map m) => EcoActivity.fromMap(
                '${m['id'] ?? ''}',
                m.map((Object? k, Object? v) => MapEntry(k.toString(), v)),
              ))
          .toList();
    } catch (_) {
      return const <EcoActivity>[];
    }
  }

  /// Adds an activity locally and recomputes the score with the same math as
  /// the cloud store. Returns the updated score.
  Future<EcoScore> addActivity(String uid, EcoActivity activity) async {
    final SharedPreferences p = await _prefs;
    final EcoScore current = await readScore(uid) ?? EcoScore(uid: uid);
    final List<EcoActivity> activities = await readActivities(uid);

    final EcoActivity stored = EcoActivity(
      id: '${DateTime.now().millisecondsSinceEpoch}',
      uid: activity.uid,
      mode: activity.mode,
      distanceMeters: activity.distanceMeters,
      durationSeconds: activity.durationSeconds,
      note: activity.note,
      createdAt: activity.createdAt,
    );
    activities.insert(0, stored);
    final EcoScore updated = EcoMath.applyActivity(current, stored);

    await p.setString(
      _activitiesKey(uid),
      jsonEncode(
        activities.take(100).map((EcoActivity a) => a.toMap()).toList(),
      ),
    );
    await p.setString(_scoreKey(uid), jsonEncode(updated.toMap()));
    return updated;
  }
}
