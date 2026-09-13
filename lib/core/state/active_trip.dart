import 'package:flutter/foundation.dart';

/// App-level record of the trip currently being navigated.
///
/// Written by the Live Trip screen when navigation starts and kept alive
/// when the user switches to another tab — so the shell can show a
/// "Navigating to … · Resume" pill and navigation survives feature
/// switching (the old behaviour killed the navigation UI entirely).
/// Cleared by [end] (arrival, explicit End trip) — never by route changes.
class ActiveTripState extends ChangeNotifier {
  bool _active = false;
  double? _lat;
  double? _lng;
  String _name = '';
  DateTime? _startedAt;
  String _mode = 'car';

  bool get active => _active;
  double? get lat => _lat;
  double? get lng => _lng;
  String get name => _name;
  DateTime? get startedAt => _startedAt;
  String get mode => _mode;

  bool get hasDestination => _active && _lat != null && _lng != null;

  /// Marks a navigation as running. Idempotent for the same destination.
  void begin({
    required double lat,
    required double lng,
    required String name,
    String mode = 'car',
  }) {
    _lat = lat;
    _lng = lng;
    _name = name;
    _mode = mode;
    if (!_active) {
      _active = true;
      _startedAt = DateTime.now();
    }
    notifyListeners();
  }

  /// Clears the active navigation (arrival or explicit end).
  void end() {
    if (!_active) return;
    _active = false;
    _startedAt = null;
    notifyListeners();
  }

  /// Route used by the shell's Resume pill.
  String get route => '/trip/live?lat=$_lat&lng=$_lng'
      '&name=${Uri.encodeComponent(_name)}';
}
