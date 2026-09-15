import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/trip_plan.dart';

/// Device-local storage for AI-generated trip plans and the active trip.
///
/// Plans are stored in SharedPreferences keyed per user id, so the Trip
/// Planner, Home "Continue trip" card and Live Trip mode all work offline.
class TripPlanStore extends ChangeNotifier {
  TripPlanStore({SharedPreferences? prefs}) : _prefs = prefs;

  static const String _prefix = 'trip.plans.v1.';
  static const String _activePrefix = 'trip.active.v1.';

  SharedPreferences? _prefs;
  String? _uid;
  List<TripPlan> _plans = const <TripPlan>[];
  String? _activeId;
  bool _loaded = false;

  List<TripPlan> get plans => _plans;
  bool get loaded => _loaded;

  /// The trip shown on the Home "Continue trip" card and used by Live Trip
  /// mode. Falls back to the most recently created plan.
  TripPlan? get active {
    if (_activeId != null) {
      for (final TripPlan p in _plans) {
        if (p.id == _activeId) return p;
      }
    }
    if (_plans.isEmpty) return null;
    final List<TripPlan> sorted = List<TripPlan>.from(_plans)
      ..sort((TripPlan a, TripPlan b) => b.createdAt.compareTo(a.createdAt));
    return sorted.first;
  }

  String _key() => '$_prefix${_uid ?? 'anon'}';
  String _activeKey() => '$_activePrefix${_uid ?? 'anon'}';

  Future<void> loadFor(String uid) async {
    _prefs ??= await SharedPreferences.getInstance();
    _uid = uid;
    final String? raw = _prefs!.getString(_key());
    if (raw == null || raw.isEmpty) {
      _plans = const <TripPlan>[];
    } else {
      try {
        final List<dynamic> decoded = jsonDecode(raw) as List<dynamic>;
        _plans = decoded
            .map((dynamic e) => TripPlan.fromJson(e as Map<String, dynamic>))
            .toList();
      } catch (_) {
        _plans = const <TripPlan>[];
      }
    }
    _activeId = _prefs!.getString(_activeKey());
    _loaded = true;
    notifyListeners();
  }

  Future<void> add(TripPlan plan) async {
    _plans = <TripPlan>[..._plans, plan];
    _activeId = plan.id;
    _prefs ??= await SharedPreferences.getInstance();
    await _prefs!.setString(_activeKey(), plan.id);
    await _save();
  }

  Future<void> update(TripPlan plan) async {
    _plans = <TripPlan>[
      for (final TripPlan p in _plans) if (p.id == plan.id) plan else p,
    ];
    await _save();
  }

  Future<void> remove(String id) async {
    _plans = _plans.where((TripPlan p) => p.id != id).toList();
    if (_activeId == id) {
      _activeId = null;
      _prefs ??= await SharedPreferences.getInstance();
      await _prefs!.remove(_activeKey());
    }
    await _save();
  }

  Future<void> setActive(String id) async {
    _activeId = id;
    _prefs ??= await SharedPreferences.getInstance();
    await _prefs!.setString(_activeKey(), id);
    notifyListeners();
  }

  Future<void> _save() async {
    _prefs ??= await SharedPreferences.getInstance();
    await _prefs!.setString(
      _key(),
      jsonEncode(_plans.map((TripPlan p) => p.toJson()).toList()),
    );
    notifyListeners();
  }
}
