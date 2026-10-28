import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../utils/geo.dart';
import 'location_service.dart';

/// Live GPS-based eco session (e.g. a walk). Distance is accumulated from
/// real location fixes while the app is running.
class EcoSession {
  EcoSession({required this.startedAt, required this.mode});

  final DateTime startedAt;
  final String mode; // walk | cycle
  double distanceMeters = 0;
  double? lastAccuracyMeters;
  Position? _last;
  bool get hasFixes => _last != null;

  void feed(Position p) {
    // Ignore clearly-bad fixes so the distance stays meaningful. Many
    // devices report accuracy 0 (unknown) for early fixes — accept those.
    if (p.accuracy > 100) return;
    final Position? last = _last;
    if (last != null) {
      distanceMeters += GeoUtils.distanceMeters(
        LatLng(last.latitude, last.longitude),
        LatLng(p.latitude, p.longitude),
      );
    }
    _last = p;
    lastAccuracyMeters = p.accuracy <= 0 ? null : p.accuracy;
  }

  Duration get duration => DateTime.now().difference(startedAt);
}

class EcoTrackerService extends ChangeNotifier {
  EcoTrackerService({required LocationService locationService})
      : _locationService = locationService;

  final LocationService _locationService;
  EcoSession? _session;
  StreamSubscription<Position>? _sub;

  EcoSession? get session => _session;
  bool get isTracking => _session != null;

  /// Starts a live GPS session. Returns false (and starts nothing) when
  /// location permission was denied.
  Future<bool> start({required String mode}) async {
    if (_session != null) return true;
    final LocationPermission p = await _locationService.ensurePermission();
    if (p == LocationPermission.denied || p == LocationPermission.deniedForever) {
      return false; // UI shows the denial state.
    }
    _session = EcoSession(startedAt: DateTime.now(), mode: mode);
    _sub = _locationService
        .watchPosition(distanceFilter: 2, accuracy: LocationAccuracy.high)
        .listen(_onFix);
    notifyListeners();
    return true;
  }

  void _onFix(Position p) {
    _session?.feed(p);
    notifyListeners();
  }

  /// Stops tracking and returns the completed session (null when nothing
  /// was tracked).
  Future<EcoSession?> stop() async {
    await _sub?.cancel();
    _sub = null;
    final EcoSession? s = _session;
    _session = null;
    notifyListeners();
    return s;
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
