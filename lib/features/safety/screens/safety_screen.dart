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
import '../../../data/models/profile.dart';
import '../../../data/models/safety_zone.dart';
import '../../../data/models/weather.dart';
import '../../../data/repositories/places_repository.dart' show placesErrorMessage;

/// Safety hub: geofence monitoring state, configured safety zones,
/// nearby emergency services, SOS history and weather safety notes.
class SafetyScreen extends StatefulWidget {
  const SafetyScreen({super.key, this.openSosContact = false});

  /// When true, auto-open the "Add SOS Contact" editor once the profile is
  /// available (used by Settings → Power-Off Safety Location navigation).
  final bool openSosContact;

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
  StreamSubscription<Profile?>? _profileSub;
  Profile? _profile;
  bool _contactSaving = false;

  @override
  void initState() {
    super.initState();
    // Reflect live geofence status (the service is also started from the app
    // shell on sign-in), so the card and buttons update without a manual
    // rebuild.
    _c.geofenceService.addListener(_onGeofenceChanged);
    // SOS contact is device-local (SettingsService) — rebuild whenever it
    // changes so Add/Edit/Remove reflects immediately without Firestore.
    _c.settings.addListener(_onSettingsChanged);
    _init();
    if (widget.openSosContact) {
      // Direct route from Settings → "Add SOS Contact" works with or without
      // a signed-in profile (local storage is the source of truth).
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showContactEditor();
      });
    }
  }

  void _onSettingsChanged() {
    if (mounted) setState(() {});
  }

  void _onGeofenceChanged() {
    if (mounted) setState(() {});
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
      // Firestore profile is a best-effort mirror of the SOS contact. Seed
      // local storage from it when a signed-in profile has a contact and the
      // device has none yet (migration for existing accounts).
      _profileSub = _c.profileRepository
          .watch(uid)
          .listen((Profile? p) {
        if (!mounted) return;
        setState(() => _profile = p);
        final String phone = (p?.emergencyContactPhone ?? '').trim();
        if (phone.isNotEmpty && !_c.settings.hasSosContact) {
          _c.settings.setSosContact(
            (p?.emergencyContactName ?? '').trim(),
            phone,
          );
        }
        // If the contact is removed while Power-Off Safety Location is on,
        // disable it automatically and explain why.
        if (_c.settings.powerOffSafety && phone.isEmpty) {
          _c.settings.setPowerOffSafety(false);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text(
                    'Power-Off Safety Location was turned off because an SOS '
                    'contact is required.')),
          );
        }
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
      // Friendly, actionable text — never a raw Exception/ApiException dump.
      String msg = placesErrorMessage(e);
      if (msg.contains('unreachable') || msg.contains('temporarily')) {
        msg = 'Could not reach the search service. Check your internet '
            'connection and try again.';
      }
      setState(() {
        _routeError = msg;
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

  /// Starts zone monitoring and reports the real outcome to the user — never
  /// silently claims success. The card itself reacts to [GeofenceService]
  /// status changes via the listener registered in [initState].
  Future<void> _enableMonitoring() async {
    try {
      await _c.geofenceService.start();
    } catch (e) {
      // start() maps every failure to a status + reason; this is a last-resort
      // guard for a truly unexpected exception.
      debugPrint('SafetyScreen enable monitoring unexpected error: $e');
    }
    if (!mounted) return;
    final GeofenceService g = _c.geofenceService;
    final String message = switch (g.status) {
      GeofenceStatus.monitoring => 'Zone geofencing is now on.',
      GeofenceStatus.denied =>
        'Location permission is required for monitoring. Enable it in Settings and retry.',
      GeofenceStatus.serviceOff =>
        'Device location (GPS) is turned off. Enable it in Settings and retry.',
      GeofenceStatus.error =>
        g.lastError ?? 'Monitoring could not start. Please try again.',
      _ => 'Monitoring could not start. Please try again.',
    };
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  String _geofenceStatusText() {
    final GeofenceStatus s = _c.geofenceService.status;
    return switch (s) {
      GeofenceStatus.idle => 'Off',
      GeofenceStatus.starting => 'Starting…',
      GeofenceStatus.monitoring => 'On',
      GeofenceStatus.paused => 'Paused',
      GeofenceStatus.denied => 'Location permission required',
      GeofenceStatus.serviceOff => 'Location services disabled',
      GeofenceStatus.error => 'Could not start',
    };
  }

  IconData _serviceIcon(Place p) {
    if (p.types.contains('police_station')) return Icons.local_police;
    if (p.types.contains('fire_station')) return Icons.local_fire_department;
    return Icons.local_hospital;
  }

  @override
  void dispose() {
    _c.geofenceService.removeListener(_onGeofenceChanged);
    _c.settings.removeListener(_onSettingsChanged);
    _posSub?.cancel();
    _zonesSub?.cancel();
    _incidentsSub?.cancel();
    _eventsSub?.cancel();
    _profileSub?.cancel();
    _routeQuery.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Safety')),
      body: Column(
        children: <Widget>[
          // SOS contact management is always reachable — never a dead end,
          // even while the rest of the safety context is still loading.
          _sosContactSection(),
          Expanded(
            child: !_locationDone
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
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------
  // SOS contact (single source of truth: profiles/{uid}.emergencyContact*)
  // ---------------------------------------------------------------------

  Widget _sosContactSection() {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final String name = _c.settings.sosContactName.trim();
    final String phone = _c.settings.sosContactPhone.trim();
    final bool hasContact = name.isNotEmpty || phone.isNotEmpty;

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.6)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.contact_emergency, size: 20, color: scheme.primary),
              const SizedBox(width: 8),
              Text(
                'SOS Contact',
                style: Theme.of(context)
                    .textTheme
                    .titleSmall
                    ?.copyWith(fontWeight: FontWeight.w800),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (!hasContact) ...<Widget>[
            const Text('No SOS contact added.'),
            const SizedBox(height: 10),
            FilledButton.icon(
              icon: const Icon(Icons.person_add_alt),
              label: const Text('Add SOS Contact'),
              onPressed: _contactSaving ? null : _showContactEditor,
            ),
          ] else ...<Widget>[
            Text(
              name.isEmpty ? '(no name)' : name,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            if (phone.isNotEmpty)
              Text(phone, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 10),
            Row(
              children: <Widget>[
                OutlinedButton.icon(
                  icon: const Icon(Icons.edit, size: 16),
                  label: const Text('Edit'),
                  onPressed: _contactSaving ? null : _showContactEditor,
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  icon: const Icon(Icons.delete_outline, size: 16),
                  label: const Text('Remove'),
                  style: OutlinedButton.styleFrom(
                      foregroundColor: AppTheme.danger),
                  onPressed: _contactSaving ? null : _removeContact,
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _showContactEditor() async {
    final Profile? p = _profile;
    final (String, String)? saved = await showDialog<(String, String)>(
      context: context,
      builder: (BuildContext ctx) => _ContactEditorDialog(
        name: _c.settings.sosContactName.isEmpty
            ? (p?.emergencyContactName ?? '')
            : _c.settings.sosContactName,
        phone: _c.settings.sosContactPhone.isEmpty
            ? (p?.emergencyContactPhone ?? '')
            : _c.settings.sosContactPhone,
      ),
    );
    if (saved == null || !mounted) return;
    setState(() => _contactSaving = true);
    try {
      final String name = saved.$1.trim();
      final String phone = saved.$2.trim();
      // Local save is the source of truth — instant, offline-safe, and never
      // blocked by Firestore rules or auth state.
      await _c.settings.setSosContact(name, phone);
      // Keep the native Power-Off receiver payload in sync: when the feature
      // is on, the shutdown receiver reads the mirrored phone/name — a stale
      // (or empty) mirror is exactly how power-off shares used to go nowhere.
      if (_c.settings.powerOffSafety) {
        String? token;
        try {
          token = await _c.authRepository.currentUser?.getIdToken();
        } catch (_) {
          token = null;
        }
        final String? projectId = _c.app?.options.projectId;
        await _c.settings.syncPowerOffSafetyPayload(
          sosPhone: phone,
          sosName: name,
          projectId: projectId ?? '',
          idToken: token,
        );
        // Also make sure the SEND_SMS permission is in place — it is the
        // channel that actually works during shutdown.
        await _c.smsService.ensureSendSmsPermission();
      }
      // Best-effort mirror to Firestore profiles/{uid} (cross-device sync).
      // A permission/network failure here must NEVER fail the save.
      final String? uid = _c.authRepository.currentUser?.uid;
      if (uid != null) {
        unawaited(_c.profileRepository
            .setEmergencyContact(uid, name: name, phone: phone)
            .catchError((Object _) {}));
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('SOS contact saved.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save SOS contact: $e')),
      );
    } finally {
      if (mounted) setState(() => _contactSaving = false);
    }
  }

  Future<void> _removeContact() async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('Remove SOS contact?'),
        content: const Text(
            'Your SOS contact will be removed and Power-Off Safety Location '
            'will be turned off (it requires a contact).'),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Remove')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _contactSaving = true);
    try {
      await _c.settings.clearSosContact();
      // Auto-disable the safety feature — it requires a contact.
      await _c.settings.setPowerOffSafety(false);
      // Best-effort Firestore mirror clear (never blocks the local remove).
      final String? uid = _c.authRepository.currentUser?.uid;
      if (uid != null) {
        unawaited(_c.profileRepository
            .clearEmergencyContact(uid)
            .catchError((Object _) {}));
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text(
                'SOS contact removed. Power-Off Safety Location is now off.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not remove SOS contact: $e')),
      );
    } finally {
      if (mounted) setState(() => _contactSaving = false);
    }
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
      GeofenceStatus.starting => (
          'Starting monitoring…',
          scheme.onSurfaceVariant
        ),
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
      GeofenceStatus.error => (
          _c.geofenceService.lastError ??
              'Monitoring could not start. Check your connection and retry.',
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
                  status == GeofenceStatus.serviceOff ||
                  status == GeofenceStatus.error ||
                  status == GeofenceStatus.starting)
                Expanded(
                  child: FilledButton.icon(
                    icon: const Icon(Icons.notifications_active),
                    label: Text(status == GeofenceStatus.starting
                        ? 'Starting…'
                        : 'Enable monitoring'),
                    onPressed: status == GeofenceStatus.starting
                        ? null
                        : _enableMonitoring,
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

/// Add/Edit dialog for the single SOS contact (name + phone). Validates the
/// phone number locally; returns (name, phone) or pops null on cancel.
class _ContactEditorDialog extends StatefulWidget {
  const _ContactEditorDialog({required this.name, required this.phone});

  final String name;
  final String phone;

  @override
  State<_ContactEditorDialog> createState() => _ContactEditorDialogState();
}

class _ContactEditorDialogState extends State<_ContactEditorDialog> {
  late final TextEditingController _name =
      TextEditingController(text: widget.name);
  late final TextEditingController _phone =
      TextEditingController(text: widget.phone);
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    super.dispose();
  }

  static final RegExp _phoneOk = RegExp(r'^\+?[0-9][0-9\s\-()]{6,18}$');

  void _save() {
    final String name = _name.text.trim();
    final String phone = _phone.text.trim();
    if (phone.isEmpty) {
      setState(() => _error = 'Enter a phone number.');
      return;
    }
    if (!_phoneOk.hasMatch(phone)) {
      setState(() => _error = 'Enter a valid phone number (digits only).');
      return;
    }
    Navigator.of(context).pop((name, phone));
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('SOS Contact'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            TextField(
              controller: _name,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Contact name',
                hintText: 'e.g. Priya (optional)',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _phone,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                labelText: 'Phone number',
                hintText: '+91 98765 43210',
              ),
            ),
            if (_error != null) ...<Widget>[
              const SizedBox(height: 10),
              Text(_error!, style: TextStyle(color: scheme.error)),
            ],
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel')),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}
