import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../data/models/safety_zone.dart';
import '../../data/repositories/notifications_repository.dart';
import '../../data/repositories/zones_repository.dart';
import '../utils/geo.dart';
import 'location_service.dart';
import 'notification_service.dart';

/// A real geofence breach: the device GPS position entered a configured
/// safety zone circle.
class GeofenceAlert {
  GeofenceAlert({required this.zone, required this.position, required this.at});
  final SafetyZone zone;
  final Position position;
  final DateTime at;
}

enum GeofenceStatus {
  idle,
  monitoring,
  paused,
  denied,
  serviceOff,
}

/// Client-side geofence engine.
///
/// It streams the device's real GPS position (foreground; on Android 14+
/// the user may grant temporary background access) and evaluates it against
/// the active safety zones from Firestore. On entry it raises an in-app
/// alert event, a real Android notification, and persists an in-app
/// notification record. Re-arming is per-zone so a single position fix does
/// not spam.
class GeofenceService extends ChangeNotifier {
  GeofenceService({
    required ZonesRepository zonesRepository,
    required LocationService locationService,
    required NotificationService notificationService,
    required NotificationsRepository notificationsRepository,
    required String Function() currentUid,
  })  : _zonesRepository = zonesRepository,
        _locationService = locationService,
        _notificationService = notificationService,
        _notificationsRepository = notificationsRepository,
        _currentUid = currentUid;

  final ZonesRepository _zonesRepository;
  final LocationService _locationService;
  final NotificationService _notificationService;
  final NotificationsRepository _notificationsRepository;
  final String Function() _currentUid;

  GeofenceStatus _status = GeofenceStatus.idle;
  GeofenceStatus get status => _status;

  List<SafetyZone> _zones = const <SafetyZone>[];
  List<SafetyZone> get zones => _zones;

  final StreamController<GeofenceAlert> _alerts =
      StreamController<GeofenceAlert>.broadcast();
  Stream<GeofenceAlert> get alerts => _alerts.stream;

  StreamSubscription<Position>? _positionSub;
  StreamSubscription<List<SafetyZone>>? _zonesSub;
  final Map<String, DateTime> _lastWarned = <String, DateTime>{};
  int _notificationId = 1;

  static const Duration reArmDelay = Duration(minutes: 10);

  Future<void> start() async {
    if (_status == GeofenceStatus.monitoring) return;

    final bool serviceOn = await _locationService.isServiceEnabled();
    if (!serviceOn) {
      _set(GeofenceStatus.serviceOff);
      return;
    }

    LocationPermission p = await _locationService.checkPermission();
    if (p == LocationPermission.denied) {
      p = await Geolocator.requestPermission();
      if (p == LocationPermission.denied) p = await Geolocator.requestPermission();
    }
    if (p == LocationPermission.deniedForever || p == LocationPermission.denied) {
      await Geolocator.openAppSettings();
      _set(GeofenceStatus.denied);
      return;
    }

    _zonesSub ??= _zonesRepository.watchAll().listen((List<SafetyZone> zs) {
      _zones = zs;
    });
    _zones = await _zonesRepository.getAll();

    _positionSub ??= _locationService
        .watchPosition(distanceFilter: 20)
        .listen(_onPosition, onError: (Object e) {
      debugPrint('GeofenceService position stream error: $e');
    });

    _set(GeofenceStatus.monitoring);
  }

  /// Re-runs the permission + start flow (used from the "enable" button
  /// after a denial).
  Future<void> enable() => start();

  Future<void> stop() async {
    await _positionSub?.cancel();
    _positionSub = null;
    _set(GeofenceStatus.idle);
  }

  void pause() {
    if (_status == GeofenceStatus.monitoring) _set(GeofenceStatus.paused);
  }

  void resume() {
    if (_status == GeofenceStatus.paused) _set(GeofenceStatus.monitoring);
  }

  void _onPosition(Position p) {
    if (_status != GeofenceStatus.monitoring) return;
    final LatLng here = LatLng(p.latitude, p.longitude);
    for (final SafetyZone zone in _zones) {
      if (!zone.active) continue;
      if (!GeoUtils.isInsideCircle(here, LatLng(zone.lat, zone.lng), zone.radiusMeters)) {
        continue;
      }
      final DateTime? last = _lastWarned[zone.id];
      final DateTime now = DateTime.now();
      if (last != null && now.difference(last) < reArmDelay) continue;
      _lastWarned[zone.id] = now;
      _fire(zone, p);
    }
  }

  void _fire(SafetyZone zone, Position p) {
    final DateTime now = DateTime.now();
    _alerts.add(GeofenceAlert(zone: zone, position: p, at: now));

    final String title =
        '⚠️ ${zone.riskLabel} zone: ${zone.name}';
    _notificationService.show(
      id: _notificationId++ * 1000 + now.millisecondsSinceEpoch % 1000,
      title: title,
      body: zone.description.isEmpty
          ? 'You entered a configured safety zone.'
          : zone.description,
      channel: 'geofence',
      payload: 'zone:${zone.id}',
      important: zone.isHighRisk,
    );

    final String? uid = _safeUid();
    if (uid != null) {
      unawaited(_notificationsRepository
          .add(
            uid: uid,
            title: title,
            body: zone.description.isEmpty
                ? 'You entered a configured safety zone.'
                : zone.description,
            type: 'geofence',
            payload: <String, dynamic>{
              'zoneId': zone.id,
              'lat': p.latitude,
              'lng': p.longitude,
            },
          )
          .catchError((Object e) {
        debugPrint('Geofence notification record failed: $e');
        return '';
      }));
    }
  }

  String? _safeUid() {
    try {
      return _currentUid();
    } catch (_) {
      return null;
    }
  }

  void _set(GeofenceStatus s) {
    if (s == _status) return;
    _status = s;
    notifyListeners();
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    _zonesSub?.cancel();
    _alerts.close();
    super.dispose();
  }
}
