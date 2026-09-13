import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' as gm;
import 'package:latlong2/latlong.dart';

import '../../../core/app_config.dart';
import '../../../core/services/safety_engine.dart';
import '../../../core/state/app_container.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/geo.dart';
import '../../../core/utils/sos_messages.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/live_share_banner.dart';
import '../../../core/widgets/live_share_prompt.dart';
import '../../../core/widgets/state_views.dart';
import '../../../data/models/incident.dart';
import '../../../data/models/places.dart';
import '../../../data/models/safety_zone.dart';
import '../../../data/models/trip_plan.dart';

/// Live Trip mode: tracks the traveler in real time toward a destination,
/// showing remaining distance, ETA, the route on a map and a live safety
/// status. If the traveler deviates from the route it recalculates after a
/// short debounce (no continuous high-frequency route calls).
class LiveTripScreen extends StatefulWidget {
  const LiveTripScreen({
    super.key,
    this.destinationLat,
    this.destinationLng,
    this.destinationName,
  });

  final double? destinationLat;
  final double? destinationLng;
  final String? destinationName;

  @override
  State<LiveTripScreen> createState() => _LiveTripScreenState();
}

class _LiveTripScreenState extends State<LiveTripScreen> {
  AppContainer get _c => AppScope.of(context);

  static const double _offRouteMeters = 150;
  static const Duration _recalcDebounce = Duration(seconds: 8);

  final MapController _controller = MapController();

  LatLng? _destination;
  String _destinationName = 'Destination';
  bool _ready = false;
  String? _setupError;

  Position? _position;
  RouteInfo? _route;
  List<LatLng> _routeLine = const <LatLng>[];
  bool _routeLoading = false;
  bool _offRoute = false;
  Timer? _recalcTimer;

  List<SafetyZone> _zones = const <SafetyZone>[];
  List<Incident> _incidents = const <Incident>[];
  SafetyAssessment _safety = const SafetyAssessment(
    level: SafetyLevel.limited,
    headline: 'Safety data limited',
    detail: 'Checking safety data…',
  );

  StreamSubscription<Position>? _posSub;
  StreamSubscription<List<SafetyZone>>? _zonesSub;
  StreamSubscription<List<Incident>>? _incidentsSub;

  @override
  void initState() {
    super.initState();
    _setup();
  }

  Future<void> _setup() async {
    // Explicit destination wins; otherwise use the saved active trip.
    double? lat = widget.destinationLat;
    double? lng = widget.destinationLng;
    String? name = widget.destinationName;
    if ((lat == null || lng == null) && !_hasExplicitDestination) {
      final String? uid = _c.authRepository.currentUser?.uid;
      if (uid != null) {
        await _c.tripPlanStore.loadFor(uid);
        final TripPlan? active = _c.tripPlanStore.active;
        if (active != null && active.hasCoordinates) {
          lat = active.lat;
          lng = active.lng;
          name = active.destination;
        }
      }
    }
    if (!mounted) return;
    if (lat == null || lng == null) {
      setState(() {
        _ready = true;
        _setupError =
            'No destination set. Save a trip in the Trip Planner or open '
            'Live Trip from a place or the map.';
      });
      return;
    }
    setState(() {
      _destination = LatLng(lat!, lng!);
      _destinationName = name ?? 'Destination';
    });
    _subscribeData();
    await _getRoute();
    _startWatch();
    if (mounted) {
      setState(() => _ready = true);
      // Navigation is live — ask (in English, once per trip) whether the SOS
      // contact should receive the traveler's live location for this trip.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _maybeAskLiveShare();
      });
    }
  }

  /// Ensures the live-share prompt appears at most once per trip.
  bool _sharePromptShown = false;

  Future<void> _maybeAskLiveShare({bool force = false}) async {
    if (!mounted || !_ready) return;
    if (_sharePromptShown && !force) return;
    _sharePromptShown = true;
    final LiveShareStartResult share = await showLiveSharePrompt(
      context,
      destinationName: _destinationName,
    );
    if (!mounted) return;
    showLiveShareFeedback(context, share,
        smsEnabled: _c.liveLocationShare.smsEnabled);
  }

  /// One-tap "current location" SMS to the SOS contact (works even when the
  /// continuous share is off).
  Future<void> _sendManualSms() async {
    final Position? pos =
        _position ?? await _c.locationService.currentPosition();
    if (!mounted) return;
    if (pos == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Could not get your location. Enable GPS and retry.')));
      return;
    }
    final bool granted = await _c.smsService.ensureSendSmsPermission();
    final String text = SosMessages.buildLiveShareText(
      travelerName: _c.authRepository.currentUser?.displayName ?? 'Traveler',
      position: pos,
      destinationName: _destinationName,
    );
    final bool ok = granted
        ? await _c.smsService.sendSms(_c.liveLocationShare.sosContactPhone, text)
        : await _c.smsService.openSmsComposer(
            _c.liveLocationShare.sosContactPhone, text);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(ok
            ? 'Location SMS sent to your SOS contact.'
            : 'SMS could not be sent. Grant the SMS permission and retry.')));
  }

  /// One-tap WhatsApp update (WhatsApp itself must send it — this opens the
  /// chat with the location message pre-filled and you press send).
  Future<void> _sendManualWhatsApp() async {
    final Position? pos =
        _position ?? await _c.locationService.currentPosition();
    if (!mounted) return;
    if (pos == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Could not get your location. Enable GPS and retry.')));
      return;
    }
    final bool ok = await _c.smsService.openWhatsApp(
      _c.liveLocationShare.sosContactPhone,
      SosMessages.buildLiveShareText(
        travelerName: _c.authRepository.currentUser?.displayName ?? 'Traveler',
        position: pos,
        destinationName: _destinationName,
      ),
    );
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('WhatsApp is not available on this device.')));
    }
  }

  bool get _hasExplicitDestination =>
      widget.destinationLat != null && widget.destinationLng != null;

  void _subscribeData() {
    final String? uid = _c.authRepository.currentUser?.uid;
    _zonesSub = _c.zonesRepository
        .watchAll()
        .listen((List<SafetyZone> z) {
      if (mounted) setState(() => _zones = z);
    }, onError: (Object _) {});
    if (uid != null) {
      _incidentsSub = _c.incidentsRepository
          .watchMine(uid)
          .listen((List<Incident> items) {
        if (mounted) setState(() => _incidents = items);
      }, onError: (Object _) {});
    }
  }

  void _startWatch() {
    if (_posSub != null) return;
    _posSub = _c.locationService
        .watchPosition(distanceFilter: 10)
        .listen((Position p) {
      if (!mounted) return;
      setState(() {
        _position = p;
        _safety = SafetyEngine.locationStatus(
          point: gm.LatLng(p.latitude, p.longitude),
          zones: _zones,
          ownIncidents: _incidents,
        );
      });
      _checkDeviation();
    }, onError: (Object _) {});
  }

  Future<void> _getRoute() async {
    final LatLng? dest = _destination;
    final Position? pos = _position;
    if (dest == null) return;
    LatLng origin;
    if (pos != null) {
      origin = LatLng(pos.latitude, pos.longitude);
    } else {
      try {
        final Position? current = await _c.locationService.currentPosition();
        if (current == null) {
          throw Exception('Enable GPS to start live navigation.');
        }
        origin = LatLng(current.latitude, current.longitude);
        if (mounted) setState(() => _position = current);
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(e.toString())),
          );
        }
        return;
      }
    }
    setState(() => _routeLoading = true);
    try {
      final RouteInfo r = await _c.placesRepository.route(
        gm.LatLng(origin.latitude, origin.longitude),
        gm.LatLng(dest.latitude, dest.longitude),
        mode: 'car',
      );
      if (!mounted) return;
      setState(() {
        _route = r;
        _routeLine = r.polyline
            .map((gm.LatLng p) => LatLng(p.latitude, p.longitude))
            .toList();
        _routeLoading = false;
        _offRoute = false;
      });
      _fitRoute();
    } catch (e) {
      if (!mounted) return;
      setState(() => _routeLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not get a route: $e')),
      );
    }
  }

  void _fitRoute() {
    if (_routeLine.length < 2) return;
    try {
      final List<LatLng> pts = <LatLng>[
        ..._routeLine,
        if (_position != null)
          LatLng(_position!.latitude, _position!.longitude),
      ];
      double minLat = pts.first.latitude;
      double maxLat = pts.first.latitude;
      double minLng = pts.first.longitude;
      double maxLng = pts.first.longitude;
      for (final LatLng p in pts) {
        minLat = math.min(minLat, p.latitude);
        maxLat = math.max(maxLat, p.latitude);
        minLng = math.min(minLng, p.longitude);
        maxLng = math.max(maxLng, p.longitude);
      }
      final LatLng center =
          LatLng((minLat + maxLat) / 2, (minLng + maxLng) / 2);
      final double span =
          math.max((maxLat - minLat).abs(), (maxLng - minLng).abs());
      _controller.move(center, _zoomForSpan(span));
    } catch (_) {
      // Map not attached yet.
    }
  }

  double _zoomForSpan(double span) {
    if (span > 20) return 4;
    if (span > 8) return 5;
    if (span > 4) return 6;
    if (span > 2) return 7;
    if (span > 1) return 8;
    if (span > 0.5) return 9;
    if (span > 0.2) return 10;
    if (span > 0.1) return 11;
    if (span > 0.05) return 12;
    return 13;
  }

  /// Minimal on-device deviation check: how far is the current position from
  /// the nearest point on the route line? Debounced recalc, not a live loop.
  void _checkDeviation() {
    final Position? p = _position;
    if (p == null || _routeLine.length < 2) return;
    final LatLng here = LatLng(p.latitude, p.longitude);
    double minD = double.infinity;
    for (final LatLng pt in _routeLine) {
      final double d = GeoUtils.distanceMetersLL(
        here.latitude, here.longitude, pt.latitude, pt.longitude);
      if (d < minD) minD = d;
    }
    if (minD > _offRouteMeters) {
      if (!_offRoute) setState(() => _offRoute = true);
      _recalcTimer ??= Timer(_recalcDebounce, () {
        _recalcTimer = null;
        unawaited(_getRoute());
      });
    } else {
      if (_offRoute) setState(() => _offRoute = false);
      _recalcTimer?.cancel();
      _recalcTimer = null;
    }
  }

  double get _speedKmh {
    final Position? p = _position;
    if (p == null || p.speed <= 0) return 0;
    return p.speed * 3.6;
  }

  @override
  void dispose() {
    _recalcTimer?.cancel();
    _posSub?.cancel();
    _zonesSub?.cancel();
    _incidentsSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Live trip')),
      body: !_ready
          ? const LoadingView(message: 'Starting live trip…')
          : _setupError != null
              ? ErrorState(message: _setupError!)
              : Stack(
                  children: <Widget>[
                    if (_destination != null) _map(),
                    // Live location sharing status + Stop (when active).
                    const LiveShareBanner(margin: EdgeInsets.all(12)),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: _infoCard(),
                    ),
                  ],
                ),
    );
  }

  Widget _map() {
    final Color primary = Theme.of(context).colorScheme.primary;
    return FlutterMap(
      mapController: _controller,
      options: MapOptions(
        initialCenter: _destination!,
        initialZoom: 13,
        maxZoom: 19,
      ),
      children: <Widget>[
        TileLayer(
          urlTemplate: AppConfig.tileUrlTemplate('streets-v2'),
          fallbackUrl: AppConfig.tileFallbackUrl,
          userAgentPackageName: 'app.roamio.tourism',
          retinaMode: RetinaMode.isHighDensity(context),
          maxNativeZoom: 19,
        ),
        PolylineLayer(
          polylines: <Polyline>[
            if (_routeLine.length >= 2)
              Polyline(
                points: _routeLine,
                color: primary,
                strokeWidth: 5,
              ),
          ],
        ),
        MarkerLayer(
          markers: <Marker>[
            if (_destination != null)
              Marker(
                point: _destination!,
                width: 40,
                height: 40,
                child: const Icon(Icons.location_pin,
                    color: Color(0xFFDC2626), size: 40),
              ),
            if (_position != null)
              Marker(
                point: LatLng(_position!.latitude, _position!.longitude),
                width: 20,
                height: 20,
                child: Container(
                  decoration: BoxDecoration(
                    color: primary,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 3),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }

  Widget _infoCard() {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final RouteInfo? r = _route;
    final Color accent = switch (_safety.level) {
      SafetyLevel.normal => AppTheme.success,
      SafetyLevel.caution => AppTheme.warning,
      SafetyLevel.alert => AppTheme.danger,
      SafetyLevel.limited => scheme.outline,
    };
    return Padding(
      padding: const EdgeInsets.all(12),
      child: AppCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.navigation, color: scheme.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  _destinationName,
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.w800),
                ),
              ),
              if (_offRoute)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppTheme.warning.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text('Off route',
                      style: TextStyle(
                          color: AppTheme.warning,
                          fontSize: 11,
                          fontWeight: FontWeight.w700)),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              Expanded(
                child: _stat('Remaining', r == null
                    ? '—'
                    : GeoUtils.formatDistance(r.distanceMeters)),
              ),
              Expanded(
                child: _stat(
                    'ETA', r == null ? '—' : GeoUtils.formatDuration(r.durationSeconds)),
              ),
              Expanded(
                child: _stat('Speed', '${_speedKmh.round()} km/h'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: <Widget>[
                Icon(Icons.shield, color: accent, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${_safety.headline} — ${_safety.detail}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              Expanded(
                child: OutlinedButton.icon(
                  onPressed:
                      _routeLoading ? null : () => unawaited(_getRoute()),
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('Recalculate'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => unawaited(_maybeAskLiveShare(force: true)),
                  icon: const Icon(Icons.share_location, size: 16),
                  label: const Text('Share location'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // Manual one-tap updates to the SOS contact while navigating.
          Row(
            children: <Widget>[
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _c.liveLocationShare.hasContact
                      ? () => unawaited(_sendManualSms())
                      : null,
                  icon: const Icon(Icons.sms, size: 16),
                  label: const Text('Send SMS now'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _c.liveLocationShare.hasContact
                      ? () => unawaited(_sendManualWhatsApp())
                      : null,
                  icon: const Icon(Icons.chat, size: 16),
                  label: const Text('WhatsApp'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Live tracking runs while this screen is open. Android limits '
            'background location updates, so tracking pauses when the app '
            'is fully closed.',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant, fontSize: 11),
          ),
        ],
      ),
      ),
    );
  }

  Widget _stat(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(label,
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(fontSize: 11)),
        const SizedBox(height: 2),
        Text(value,
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
      ],
    );
  }
}
