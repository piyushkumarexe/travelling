import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/services/geofence_service.dart';
import '../../../core/services/safety_engine.dart';
import '../../../core/state/app_container.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/format.dart';
import '../../../core/utils/geo.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/app_skeleton.dart';
import '../../../core/widgets/badges.dart';
import '../../../core/widgets/state_views.dart';
import '../../../data/models/emergency_event.dart';
import '../../../data/models/incident.dart';
import '../../../data/models/places.dart';
import '../../../data/models/safety_zone.dart';
import '../../../data/models/weather.dart';

/// Safety hub: geofence monitoring state, configured safety zones,
/// nearby emergency services, SOS history and weather safety notes.
class SafetyScreen extends StatefulWidget {
  const SafetyScreen({super.key});

  @override
  State<SafetyScreen> createState() => _SafetyScreenState();
}

class _SafetyScreenState extends State<SafetyScreen> {
  AppContainer get _c => AppScope.of(context);

  Position? _position;
  bool _locationDone = false;

  List<SafetyZone> _zones = const <SafetyZone>[];
  List<Incident> _incidents = const <Incident>[];
  List<EmergencyEvent> _events = const <EmergencyEvent>[];
  List<Place> _services = const <Place>[];
  bool _servicesLoading = false;
  String? _servicesError;

  WeatherCurrent? _weather;
  List<String> _weatherNotes = const <String>[];

  // Safe route state.
  final TextEditingController _routeQuery = TextEditingController();
  bool _routeLoading = false;
  String? _routeError;
  String? _routeDestName;
  RouteInfo? _routeInfo;
  SafetyAssessment? _routeAssessment;

  StreamSubscription<Position>? _posSub;
  StreamSubscription<List<SafetyZone>>? _zonesSub;
  StreamSubscription<List<Incident>>? _incidentsSub;
  StreamSubscription<List<EmergencyEvent>>? _eventsSub;

  @override
  void initState() {
    super.initState();
    _init();
  }

  void _init() {
    final String? uid = _c.authRepository.currentUser?.uid;
    if (uid != null) {
      _eventsSub = _c.emergencyRepository
          .watchMine(uid)
          .listen((List<EmergencyEvent> e) {
        if (mounted) setState(() => _events = e);
      }, onError: (Object _) {});
      _incidentsSub = _c.incidentsRepository
          .watchMine(uid)
          .listen((List<Incident> items) {
        if (mounted) setState(() => _incidents = items);
      }, onError: (Object _) {});
    }
    _zonesSub = _c.zonesRepository
        .watchAll()
        .listen((List<SafetyZone> z) {
      if (mounted) setState(() => _zones = z);
    }, onError: (Object _) {});
    _loadLocation();
  }

  /// Computes a real OSRM route to the searched destination and assesses it
  /// against configured safety zones and the user's own recent reports.
  Future<void> _checkSafeRoute() async {
    final String q = _routeQuery.text.trim();
    if (q.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a destination first.')),
      );
      return;
    }
    final Position? pos = _position;
    if (pos == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Enable location services to check a route.')),
      );
      return;
    }
    setState(() {
      _routeLoading = true;
      _routeError = null;
      _routeInfo = null;
      _routeAssessment = null;
    });
    try {
      final LatLng here = LatLng(pos.latitude, pos.longitude);
      final List<Place> results = await _c.placesRepository.search(
        q,
        location: here,
        radiusMeters: 20000,
      );
      if (results.isEmpty) {
        throw Exception('No matching place found for "$q".');
      }
      final Place dest = results.first;
      final RouteInfo route = await _c.placesRepository.route(
        here,
        LatLng(dest.lat, dest.lng),
      );
      final SafetyAssessment assessment = SafetyEngine.routeAssessment(
        polyline: route.polyline,
        zones: _zones,
        ownIncidents: _incidents,
      );
      if (!mounted) return;
      setState(() {
        _routeInfo = route;
        _routeAssessment = assessment;
        _routeDestName = dest.name;
        _routeLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _routeError = e.toString();
        _routeLoading = false;
      });
    }
  }

  Future<void> _loadLocation() async {
    try {
      final Position? pos = await _c.locationService.currentPosition();
      if (!mounted) return;
      setState(() {
        _position = pos;
        _locationDone = true;
      });
      if (pos != null) {
        unawaited(_loadServices());
        unawaited(_loadWeather());
      }
    } catch (_) {
      if (mounted) setState(() => _locationDone = true);
    }
  }

  Future<void> _loadServices() async {
    final Position? pos = _position;
    if (pos == null) return;
    setState(() {
      _servicesLoading = true;
      _servicesError = null;
    });
    try {
      final List<Place> places =
          await _c.placesRepository.emergencyNearby(
        LatLng(pos.latitude, pos.longitude),
      );
      if (!mounted) return;
      setState(() {
        _services = places;
        _servicesLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _servicesError = e.toString();
        _servicesLoading = false;
      });
    }
  }

  Future<void> _loadWeather() async {
    final Position? pos = _position;
    if (pos == null) return;
    try {
      final WeatherCurrent w =
          await _c.weatherRepository.current(LatLng(pos.latitude, pos.longitude));
      if (!mounted) return;
      setState(() {
        _weather = w;
        _weatherNotes = weatherSafetyNotes(w);
      });
    } catch (_) {
      // Weather notes are supplementary; stay silent on failure.
    }
  }

  (String, Color) _safetySummary() {
    final Position? pos = _position;
    if (pos == null) {
      return ('Location unavailable', AppTheme.warning);
    }
    final LatLng here = LatLng(pos.latitude, pos.longitude);
    final List<SafetyZone> active =
        _zones.where((SafetyZone z) => z.active).toList();
    SafetyZone? nearest;
    double? nearestDist;
    for (final SafetyZone z in active) {
      final double d = GeoUtils.distanceMeters(here, LatLng(z.lat, z.lng));
      if (nearestDist == null || d < nearestDist) {
        nearest = z;
        nearestDist = d;
      }
    }
    if (nearest == null) return ('No active safety zones', AppTheme.success);
    if (nearestDist != null && nearestDist <= nearest.radiusMeters) {
      return (
        'Inside ${nearest.name} (${nearest.riskLabel})',
        nearest.isHighRisk ? AppTheme.danger : AppTheme.warning,
      );
    }
    if (nearestDist != null && nearestDist <= 3000) {
      return (
        'Nearest zone: ${nearest.name} · '
        '${GeoUtils.formatDistance(nearestDist)}',
        nearest.isHighRisk ? AppTheme.danger : AppTheme.warning,
      );
    }
    return ('No active safety zones within 3 km', AppTheme.success);
  }

  String _geofenceStatusText() {
    final GeofenceStatus s = _c.geofenceService.status;
    return switch (s) {
      GeofenceStatus.idle => 'Off',
      GeofenceStatus.monitoring => 'Monitoring live',
      GeofenceStatus.paused => 'Paused',
      GeofenceStatus.denied => 'Location permission denied',
      GeofenceStatus.serviceOff => 'Location services disabled',
    };
  }

  IconData _serviceIcon(Place p) {
    if (p.types.contains('police_station')) return Icons.local_police;
    if (p.types.contains('fire_station')) return Icons.local_fire_department;
    return Icons.local_hospital;
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _zonesSub?.cancel();
    _incidentsSub?.cancel();
    _eventsSub?.cancel();
    _routeQuery.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Safety')),
      body: !_locationDone
          ? const LoadingView(message: 'Checking your safety context…')
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
              children: <Widget>[
                _statusCard(),
                const SizedBox(height: 12),
                _safeRouteSection(),
                const SizedBox(height: 12),
                _geofenceCard(),
                const SectionHeader(title: 'Configured safety zones'),
                _zonesSection(),
                const SectionHeader(title: 'Nearby emergency services'),
                _servicesSection(),
                const SectionHeader(title: 'Your SOS events'),
                _eventsSection(),
                if (_weatherNotes.isNotEmpty) ...<Widget>[
                  const SectionHeader(title: 'Weather safety notes'),
                  _weatherSection(),
                ],
              ],
            ),
    );
  }

  Widget _safeRouteSection() {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final SafetyAssessment? a = _routeAssessment;
    final Color accent = switch (a?.level) {
      SafetyLevel.normal => AppTheme.success,
      SafetyLevel.caution => AppTheme.warning,
      SafetyLevel.alert => AppTheme.danger,
      _ => scheme.outline,
    };
    final String emoji = switch (a?.level) {
      SafetyLevel.normal => '🟢',
      SafetyLevel.caution => '🟡',
      SafetyLevel.alert => '🔴',
      _ => '⚪',
    };
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.route, color: scheme.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Safe route',
                  style: Theme.of(context)
                      .textTheme
                      .titleSmall
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Enter a destination to get a real route and a safety check '
            'based on available zones and reports.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  controller: _routeQuery,
                  decoration: const InputDecoration(
                    hintText: 'Destination (e.g. Charminar)',
                    prefixIcon: Icon(Icons.search, size: 18),
                    isDense: true,
                  ),
                  onSubmitted: (_) => _checkSafeRoute(),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _routeLoading ? null : _checkSafeRoute,
                child: _routeLoading
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : const Text('Check'),
              ),
            ],
          ),
          if (_routeError != null) ...<Widget>[
            const SizedBox(height: 10),
            Text(
              _routeError!,
              style: TextStyle(color: AppTheme.danger, fontSize: 12.5),
            ),
          ],
          if (a != null && _routeInfo != null) ...<Widget>[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    '$emoji ${a.headline}',
                    style: const TextStyle(
                        fontWeight: FontWeight.w800, fontSize: 14),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${_routeDestName ?? 'Destination'} · '
                    '${GeoUtils.formatDistance(_routeInfo!.distanceMeters)} · '
                    '${GeoUtils.formatDuration(_routeInfo!.durationSeconds)}',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 6),
                  Text(a.detail, style: Theme.of(context).textTheme.bodySmall),
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: () {
                      final RouteInfo r = _routeInfo!;
                      final List<LatLng> pts = r.polyline;
                      final LatLng end = pts.isEmpty
                          ? const LatLng(0, 0)
                          : pts.last;
                      context.push('/map?lat=${end.latitude}&lng=${end.longitude}'
                          '&name=${Uri.encodeComponent(_routeDestName ?? 'Destination')}');
                    },
                    icon: const Icon(Icons.map, size: 16),
                    label: const Text('View route on map'),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _statusCard() {
    final (String text, Color color) = _safetySummary();
    return AppCard(
      child: Row(
        children: <Widget>[
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.shield, color: color),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'Safety status',
                  style: Theme.of(context)
                      .textTheme
                      .titleSmall
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 2),
                Text(
                  text,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _geofenceCard() {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final GeofenceStatus status = _c.geofenceService.status;
    final bool active = status == GeofenceStatus.monitoring;
    final (String text, Color color) = switch (status) {
      GeofenceStatus.monitoring => (
          'Live GPS monitoring is on. If you enter a configured high-risk zone you will get an in-app warning, an Android notification and one-tap SOS access.',
          AppTheme.success
        ),
      GeofenceStatus.idle => (
          'Geofence monitoring is off. Turn it on to get real-time zone-entry warnings.',
          scheme.onSurfaceVariant
        ),
      GeofenceStatus.paused => (
          'Monitoring is paused. Resume to keep receiving zone warnings.',
          AppTheme.warning
        ),
      GeofenceStatus.denied => (
          'Location permission was denied, so zone monitoring cannot run. Allow location access in system settings, then retry.',
          AppTheme.danger
        ),
      GeofenceStatus.serviceOff => (
          'Device location services are turned off. Enable GPS in system settings, then retry.',
          AppTheme.danger
        ),
    };
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.gps_fixed, color: color),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Zone geofencing — ${_geofenceStatusText()}',
                  style: Theme.of(context)
                      .textTheme
                      .titleSmall
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: active ? AppTheme.success : scheme.outlineVariant,
                  shape: BoxShape.circle,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(text, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              if (status == GeofenceStatus.idle ||
                  status == GeofenceStatus.denied ||
                  status == GeofenceStatus.serviceOff)
                Expanded(
                  child: FilledButton.icon(
                    icon: const Icon(Icons.notifications_active),
                    label: const Text('Enable monitoring'),
                    onPressed: () {
                      unawaited(
                          _c.geofenceService.start().catchError((Object _) {}));
                    },
                  ),
                )
              else
                active
                    ? TextButton.icon(
                        icon: const Icon(Icons.pause_circle_outline),
                        label: const Text('Pause'),
                        onPressed: _c.geofenceService.pause,
                      )
                    : TextButton.icon(
                        icon: const Icon(Icons.play_circle_outline),
                        label: const Text('Resume'),
                        onPressed: _c.geofenceService.resume,
                      ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _zonesSection() {
    final List<SafetyZone> active =
        _zones.where((SafetyZone z) => z.active).toList();
    if (_zones.isEmpty) {
      return AppCard(
        child: Text(
          'No safety zones have been configured yet. Administrators can '
          'create zones; they will appear here and on the map.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      );
    }
    return Column(
      children: <Widget>[
        for (final SafetyZone z in active)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _zoneRow(z),
          ),
      ],
    );
  }

  Widget _zoneRow(SafetyZone z) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final double? dist = _position == null
        ? null
        : GeoUtils.distanceMeters(
            LatLng(_position!.latitude, _position!.longitude),
            LatLng(z.lat, z.lng),
          );
    return AppCard(
      onTap: () => _showZoneDialog(z),
      padding: const EdgeInsets.all(12),
      child: Row(
        children: <Widget>[
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: RiskBadge.colorFor(context, z.riskLevel).withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.location_on,
                color: RiskBadge.colorFor(context, z.riskLevel)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        z.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context)
                            .textTheme
                            .titleSmall
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                    ),
                    RiskBadge(risk: z.riskLevel),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  'Radius ${GeoUtils.formatDistance(z.radiusMeters)}'
                  '${dist != null ? ' · ${GeoUtils.formatDistance(dist)} away' : ''}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                ),
              ],
            ),
          ),
          const Icon(Icons.chevron_right, color: Colors.grey),
        ],
      ),
    );
  }

  void _showZoneDialog(SafetyZone z) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Row(
          children: <Widget>[
            Expanded(
              child: Text(z.name,
                  style: const TextStyle(fontWeight: FontWeight.w800)),
            ),
            RiskBadge(risk: z.riskLevel),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'Radius: ${GeoUtils.formatDistance(z.radiusMeters)}',
              style: Theme.of(ctx).textTheme.bodyMedium,
            ),
            const SizedBox(height: 8),
            Text(
              z.description.isEmpty
                  ? 'No description provided for this zone.'
                  : z.description,
              style: Theme.of(ctx).textTheme.bodySmall,
            ),
            if (z.createdAt != null) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                'Configured ${Fmt.relative(z.createdAt!)}',
                style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
              ),
            ],
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Close'),
          ),
          FilledButton.icon(
            icon: const Icon(Icons.map),
            label: const Text('Show on map'),
            onPressed: () {
              Navigator.of(ctx).pop();
              context.push('/map?lat=${z.lat}&lng=${z.lng}&name=zone');
            },
          ),
        ],
      ),
    );
  }

  Widget _servicesSection() {
    if (_servicesLoading) return const SkeletonList(count: 2, height: 80);
    if (_servicesError != null) {
      return AppCard(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
        child: Row(
          children: <Widget>[
            Icon(Icons.cloud_off, color: Theme.of(context).colorScheme.error),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                _servicesError!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            TextButton(onPressed: _loadServices, child: const Text('Retry')),
          ],
        ),
      );
    }
    if (_services.isEmpty) {
      return AppCard(
        child: Text(
          'No nearby emergency services found. Call your local emergency '
          'number if you need help.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      );
    }
    return Column(
      children: <Widget>[
        for (final Place p in _services.take(6))
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: AppCard(
              padding: const EdgeInsets.all(10),
              child: Row(
                children: <Widget>[
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: AppTheme.danger.withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(_serviceIcon(p), color: AppTheme.danger),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          p.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context)
                              .textTheme
                              .titleSmall
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        if (p.phone != null && p.phone!.isNotEmpty)
                          Text(
                            p.phone!,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                      ],
                    ),
                  ),
                  if (p.phone != null && p.phone!.isNotEmpty)
                    IconButton(
                      tooltip: 'Call',
                      icon: const Icon(Icons.call, color: AppTheme.danger),
                      onPressed: () => _call(p.phone!),
                    ),
                  IconButton(
                    tooltip: 'Directions',
                    icon:
                        const Icon(Icons.directions, color: AppTheme.danger),
                    onPressed: () => _c.placesRepository.openInGoogleMaps(
                        p.lat, p.lng, p.name),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Future<void> _call(String phone) async {
    final Uri uri =
        Uri.parse('tel:${phone.replaceAll(RegExp(r'[^0-9+]'), '')}');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  Widget _eventsSection() {
    if (_events.isEmpty) {
      return AppCard(
        child: Text(
          'You have not activated SOS yet. It is always one tap away via the '
          'SOS button on the bottom bar.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      );
    }
    return Column(
      children: <Widget>[
        for (final EmergencyEvent e in _events.take(5))
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _eventRow(e),
          ),
      ],
    );
  }

  Widget _eventRow(EmergencyEvent e) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color color =
        e.isActive ? AppTheme.danger : scheme.onSurfaceVariant;
    return AppCard(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: <Widget>[
          Icon(Icons.sos, color: color),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Text(
                      'SOS · ${e.statusLabel}',
                      style: Theme.of(context)
                          .textTheme
                          .titleSmall
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const Spacer(),
                    Text(
                      Fmt.relative(e.createdAt),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                    ),
                  ],
                ),
                Text(
                  '${e.lat.toStringAsFixed(5)}, ${e.lng.toStringAsFixed(5)}'
                  '${e.accuracyMeters != null ? ' (±${e.accuracyMeters!.round()} m)' : ''}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          if (e.isActive)
            TextButton(
              onPressed: () async {
                try {
                  await _c.emergencyRepository.updateStatus(e.id, 'cancelled');
                } catch (_) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                          content: Text('Could not cancel the event.')),
                    );
                  }
                }
              },
              child: const Text('Cancel'),
            ),
        ],
      ),
    );
  }

  Widget _weatherSection() {
    final WeatherCurrent? w = _weather;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (w != null)
            Text(
              'Now: ${w.condition}, ${w.tempC.toStringAsFixed(0)}°C, '
              'wind ${(w.windMs * 3.6).toStringAsFixed(0)} km/h',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          const SizedBox(height: 10),
          for (final String note in _weatherNotes)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Icon(Icons.info_outline,
                      size: 16, color: AppTheme.warning),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(note,
                        style: Theme.of(context).textTheme.bodySmall),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
