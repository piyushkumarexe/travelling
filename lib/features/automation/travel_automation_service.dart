import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/services/notification_service.dart';
import '../../data/local/trip_plan_store.dart';
import '../../data/models/trip_plan.dart';
import 'travel_automation_engine.dart';

enum AutomationEnableResult { enabled, noTrip, noFutureEvents, permissionDenied }

class TravelAutomationService extends ChangeNotifier {
  TravelAutomationService({
    required NotificationService notifications,
    required TripPlanStore trips,
  })  : _notifications = notifications,
        _trips = trips;

  final NotificationService _notifications;
  final TripPlanStore _trips;

  String? _uid;
  Set<TravelAutomationKind> _enabled = <TravelAutomationKind>{};
  final Map<TravelAutomationKind, List<DateTime>> _times =
      <TravelAutomationKind, List<DateTime>>{};
  bool _busy = false;

  bool get busy => _busy;
  Set<TravelAutomationKind> get enabled =>
      Set<TravelAutomationKind>.unmodifiable(_enabled);
  bool isEnabled(TravelAutomationKind kind) => _enabled.contains(kind);
  List<DateTime> timesFor(TravelAutomationKind kind) =>
      List<DateTime>.unmodifiable(_times[kind] ?? const <DateTime>[]);

  String get _key => 'travel.automation.v1.${_uid ?? 'anon'}';

  Future<void> load(String uid) async {
    if (_uid != null && _uid != uid) {
      for (final TravelAutomationKind kind
          in List<TravelAutomationKind>.from(_enabled)) {
        await _cancelKind(kind);
      }
      _enabled.clear();
      _times.clear();
    }
    _uid = uid;
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? raw = prefs.getString(_key);
      if (raw != null) {
        final Map<String, dynamic> decoded =
            jsonDecode(raw) as Map<String, dynamic>;
        _enabled = (decoded['enabled'] as List<dynamic>? ?? const <dynamic>[])
            .whereType<String>()
            .map(_kindByName)
            .whereType<TravelAutomationKind>()
            .toSet();
        final Map<String, dynamic> rawTimes =
            (decoded['times'] as Map<String, dynamic>?) ??
                <String, dynamic>{};
        _times.clear();
        for (final MapEntry<String, dynamic> entry in rawTimes.entries) {
          final TravelAutomationKind? kind = _kindByName(entry.key);
          if (kind == null || entry.value is! List) continue;
          _times[kind] = (entry.value as List<dynamic>)
              .whereType<String>()
              .map(DateTime.tryParse)
              .whereType<DateTime>()
              .toList();
        }
      }
    } catch (_) {
      _enabled = <TravelAutomationKind>{};
      _times.clear();
    }
    notifyListeners();
  }

  Future<AutomationEnableResult> enable(TravelAutomationKind kind) async {
    if (_busy) return AutomationEnableResult.noFutureEvents;
    final TripPlan? trip = _trips.active;
    if (trip == null) return AutomationEnableResult.noTrip;
    final List<AutomationEvent> events = TravelAutomationEngine.eventsFor(
      kind: kind,
      trip: trip,
      now: DateTime.now(),
    );
    if (events.isEmpty) return AutomationEnableResult.noFutureEvents;
    _busy = true;
    notifyListeners();
    try {
      if (!await _notifications.ensurePermission()) {
        return AutomationEnableResult.permissionDenied;
      }
      await _cancelKind(kind);
      final List<DateTime> scheduled = <DateTime>[];
      for (int i = 0; i < events.length; i++) {
        final AutomationEvent event = events[i];
        final bool ok = await _notifications.schedule(
          id: _notificationId(kind, i),
          title: event.title,
          body: event.body,
          at: event.at,
          channel: kind == TravelAutomationKind.safetyCheckIn ||
                  kind == TravelAutomationKind.returnBeforeDark
              ? 'safety'
              : 'general',
          payload: '/automation',
        );
        if (ok) scheduled.add(event.at);
      }
      if (scheduled.isEmpty) return AutomationEnableResult.noFutureEvents;
      _enabled.add(kind);
      _times[kind] = scheduled;
      await _save();
      return AutomationEnableResult.enabled;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> disable(TravelAutomationKind kind) async {
    _busy = true;
    notifyListeners();
    try {
      await _cancelKind(kind);
      _enabled.remove(kind);
      _times.remove(kind);
      await _save();
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> _cancelKind(TravelAutomationKind kind) async {
    final int count = _times[kind]?.length ?? 0;
    for (int i = 0; i < count; i++) {
      await _notifications.cancelScheduled(_notificationId(kind, i));
    }
  }

  int _notificationId(TravelAutomationKind kind, int eventIndex) =>
      710000 + kind.index * 100 + eventIndex;

  Future<void> _save() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key,
      jsonEncode(<String, dynamic>{
        'enabled': _enabled.map((TravelAutomationKind k) => k.name).toList(),
        'times': <String, dynamic>{
          for (final MapEntry<TravelAutomationKind, List<DateTime>> e
              in _times.entries)
            e.key.name:
                e.value.map((DateTime d) => d.toIso8601String()).toList(),
        },
      }),
    );
  }

  static TravelAutomationKind? _kindByName(String name) {
    for (final TravelAutomationKind kind in TravelAutomationKind.values) {
      if (kind.name == name) return kind;
    }
    return null;
  }
}
