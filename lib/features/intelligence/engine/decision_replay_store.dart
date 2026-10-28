// 🧠 Travel Decision Replay — append-only, device-local record of REAL
// in-app decisions (scenario applied, constraints applied, recovery applied,
// stop skipped from a plan). Nothing is fabricated or back-filled; the store
// only ever contains entries the user's own actions created.

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

enum DecisionType {
  scenarioApplied('Scenario applied'),
  constraintsApplied('Constraints applied'),
  recoveryApplied('Recovery applied'),
  tripEdited('Trip edited'),
  stopSkipped('Stop skipped');

  const DecisionType(this.label);
  final String label;
}

class DecisionRecord {
  const DecisionRecord({
    required this.id,
    required this.type,
    required this.title,
    required this.detail,
    required this.at,
    this.tripId,
  });

  final String id;
  final DecisionType type;
  final String title;
  final String detail;
  final DateTime at;
  final String? tripId;

  Map<String, dynamic> toMap() => <String, dynamic>{
        'id': id,
        'type': type.name,
        'title': title,
        'detail': detail,
        'at': at.millisecondsSinceEpoch,
        'tripId': tripId,
      };

  static DecisionRecord fromMap(Map<String, dynamic> m) => DecisionRecord(
        id: (m['id'] as String?) ?? '',
        type: DecisionType.values
            .where((DecisionType t) => t.name == (m['type'] as String?))
            .firstOrNull ?? DecisionType.tripEdited,
        title: (m['title'] as String?) ?? '',
        detail: (m['detail'] as String?) ?? '',
        at: DateTime.fromMillisecondsSinceEpoch(
            (m['at'] as num?)?.toInt() ?? 0),
        tripId: m['tripId'] as String?,
      );
}

class DecisionReplayStore {
  static const String _key = 'travel.decision.replay.v1';
  static const int _max = 100;

  List<DecisionRecord> _cache = const <DecisionRecord>[];
  bool _loaded = false;

  List<DecisionRecord> get records => _cache;
  bool get loaded => _loaded;

  Future<void> load() async {
    if (_loaded) return;
    try {
      final SharedPreferences p = await SharedPreferences.getInstance();
      final String? raw = p.getString(_key);
      if (raw != null && raw.isNotEmpty) {
        final List<dynamic> list = jsonDecode(raw) as List<dynamic>;
        _cache = list
            .whereType<Map<String, dynamic>>()
            .map(DecisionRecord.fromMap)
            .toList();
      }
    } catch (_) {
      _cache = const <DecisionRecord>[];
    }
    _loaded = true;
  }

  Future<void> add({
    required DecisionType type,
    required String title,
    required String detail,
    String? tripId,
  }) async {
    final DecisionRecord r = DecisionRecord(
      id: 'd${DateTime.now().millisecondsSinceEpoch}',
      type: type,
      title: title,
      detail: detail,
      at: DateTime.now(),
      tripId: tripId,
    );
    _cache = <DecisionRecord>[r, ..._cache];
    if (_cache.length > _max) _cache = _cache.sublist(0, _max);
    await _persist();
  }

  Future<void> clear() async {
    _cache = const <DecisionRecord>[];
    await _persist();
  }

  Future<void> _persist() async {
    try {
      final SharedPreferences p = await SharedPreferences.getInstance();
      await p.setString(
          _key, jsonEncode(_cache.map((DecisionRecord r) => r.toMap()).toList()));
    } catch (_) {
      // Local-only data; losing persistence must never crash the app.
    }
  }
}
