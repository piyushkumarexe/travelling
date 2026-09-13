import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../../core/network/api_exception.dart';
import '../../../core/services/safety_engine.dart';
import '../../../core/state/app_container.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/format.dart';
import '../../../core/utils/geo.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/app_skeleton.dart';
import '../../../core/widgets/place_card.dart';
import '../../../core/widgets/sos_sheet.dart';
import '../../../core/widgets/state_views.dart';
import '../../../data/models/incident.dart';
import '../../../data/models/notification.dart';
import '../../../data/models/places.dart';
import '../../../data/models/profile.dart';
import '../../../data/models/safety_zone.dart';
import '../../../data/models/trip_plan.dart';
import '../../../data/models/weather.dart';

/// Premium dashboard: location, weather, safety status, SOS, quick actions,
/// nearby attractions and active alerts. Every card navigates to a real
/// working feature.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  AppContainer get _c => AppScope.of(context);

  Position? _position;
  bool _locationDone = false;
  String? _locationLabel;

  WeatherCurrent? _weather;
  bool _weatherLoading = false;
  String? _weatherError;

  List<Place> _attractions = const <Place>[];
  bool _attrLoading = false;
  String? _attrError;

  List<AppNotification> _alerts = const <AppNotification>[];
  List<SafetyZone> _zones = const <SafetyZone>[];
  List<Incident> _ownIncidents = const <Incident>[];
  SafetyAssessment _safety = const SafetyAssessment(
    level: SafetyLevel.limited,
    headline: 'Checking safety…',
    detail: 'Loading available safety data for your area.',
  );

  Profile? _profile;

  TripPlan? _activeTrip;
  RouteInfo? _tripRoute;
  bool _tripRouteLoading = false;

  StreamSubscription<Position>? _posSub;
  StreamSubscription<List<AppNotification>>? _notifSub;
  StreamSubscription<List<SafetyZone>>? _zonesSub;
  StreamSubscription<List<Incident>>? _incidentsSub;
  StreamSubscription<Profile?>? _profileSub;

  @override
  void initState() {
    super.initState();
    _init();
  }

  void _init() {
    final String? uid = _c.authRepository.currentUser?.uid;
    if (uid != null) {
      _notifSub = _c.notificationsRepository
          .watchMine(uid)
          .listen((List<AppNotification> items) {
        final List<AppNotification> unread = items
            .where((AppNotification n) =>
                !n.read &&
                const <String>[
                  'safety_alert',
                  'geofence',
                  'emergency',
                  'incident',
                ].contains(n.type))
            .toList();
        if (mounted) setState(() => _alerts = unread);
      }, onError: (Object _) {});
      _profileSub = _c.profileRepository
          .watch(uid)
          .listen((Profile? p) {
        if (mounted) setState(() => _profile = p);
      }, onError: (Object _) {});
      _incidentsSub = _c.incidentsRepository
          .watchMine(uid)
          .listen((List<Incident> items) {
        if (mounted) {
          setState(() => _ownIncidents = items);
          _updateSafety();
        }
      }, onError: (Object _) {});
      unawaited(_loadActiveTrip(uid));
    }
    _zonesSub = _c.zonesRepository
        .watchAll()
        .listen((List<SafetyZone> z) {
      if (mounted) {
        setState(() => _zones = z);
        _updateSafety();
      }
    }, onError: (Object _) {});

    _loadLocation();
  }

  /// Loads the saved active trip and computes a one-shot route (distance +
  /// ETA) for the "Continue trip" card. Uses the OSRM fallback — no backend
  /// required — and never invents a route when no trip/position is set.
  Future<void> _loadActiveTrip(String uid) async {
    await _c.tripPlanStore.loadFor(uid);
    if (!mounted) return;
    setState(() => _activeTrip = _c.tripPlanStore.active);
    final TripPlan? trip = _activeTrip;
    final Position? pos = _position;
    if (trip == null || !trip.hasCoordinates || pos == null) return;
    unawaited(_loadTripRoute());
  }

  Future<void> _loadTripRoute() async {
    final TripPlan? trip = _activeTrip;
    final Position? pos = _position;
    if (trip == null || !trip.hasCoordinates || pos == null) return;
    if (_tripRoute != null || _tripRouteLoading) return;
    setState(() => _tripRouteLoading = true);
    try {
      final RouteInfo r = await _c.placesRepository.route(
        LatLng(pos.latitude, pos.longitude),
        LatLng(trip.lat, trip.lng),
      );
      if (!mounted) return;
      setState(() {
        _tripRoute = r;
        _tripRouteLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _tripRouteLoading = false);
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
      if (pos == null) {
        _safety = const SafetyAssessment(
          level: SafetyLevel.limited,
          headline: 'Safety data limited',
          detail: 'Location unavailable — enable location services to check safety.',
        );
        if (mounted) setState(() {});
        return;
      }
      final LatLng p = LatLng(pos.latitude, pos.longitude);
      _updateSafety();
      unawaited(_loadTripRoute());
      unawaited(_c.placesRepository
          .reverseGeocode(p)
          .then((String? label) {
        if (mounted && label != null) {
          setState(() => _locationLabel = label);
        }
      }).catchError((Object _) {}));
      unawaited(_loadWeather());
      unawaited(_loadAttractions());
    } catch (_) {
      if (mounted) {
        setState(() => _locationDone = true);
      }
    }
  }

  Future<void> _loadWeather() async {
    final Position? pos = _position;
    if (pos == null) return;
    if (mounted) {
      setState(() {
        _weatherLoading = true;
        _weatherError = null;
      });
    }
    try {
      final WeatherCurrent w =
          await _c.weatherRepository.current(LatLng(pos.latitude, pos.longitude));
      if (!mounted) return;
      setState(() {
        _weather = w;
        _weatherLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _weatherError = _friendly(e);
        _weatherLoading = false;
      });
    }
  }

  Future<void> _loadAttractions() async {
    final Position? pos = _position;
    if (pos == null) return;
    if (mounted) {
      setState(() {
        _attrLoading = true;
        _attrError = null;
      });
    }
    try {
      final List<Place> places = await _c.placesRepository.search(
        'tourist attractions',
        location: LatLng(pos.latitude, pos.longitude),
        radiusMeters: 10000,
      );
      if (!mounted) return;
      setState(() {
        _attractions = places.length > 5 ? places.sublist(0, 5) : places;
        _attrLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _attrError = _friendly(e);
        _attrLoading = false;
      });
    }
  }

  String _friendly(Object e) =>
      e is ApiException ? e.message : 'Could not load data. Please try again.';

  void _updateSafety() {
    final Position? pos = _position;
    if (pos == null) return;
    final SafetyAssessment a = SafetyEngine.locationStatus(
      point: LatLng(pos.latitude, pos.longitude),
      zones: _zones,
      ownIncidents: _ownIncidents,
    );
    if (mounted) setState(() => _safety = a);
  }

  String get _greetingName {
    final String? name =
        (_profile?.name.isNotEmpty ?? false) ? _profile!.name : null;
    final String? user = _c.authRepository.currentUser?.displayName;
    final String source = (name != null) ? name : (user ?? 'traveler');
    return source.split(RegExp(r'\s+')).first;
  }

  static IconData _weatherIcon(String code) {
    if (code.startsWith('09') || code.startsWith('10')) return Icons.grain;
    if (code.startsWith('11')) return Icons.thunderstorm;
    if (code.startsWith('13')) return Icons.ac_unit;
    if (code.startsWith('50')) return Icons.foggy;
    if (code.startsWith('02')) return Icons.cloud_circle;
    if (code.startsWith('03') || code.startsWith('04')) return Icons.cloud;
    if (code.endsWith('n')) return Icons.dark_mode;
    return Icons.wb_sunny;
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _notifSub?.cancel();
    _zonesSub?.cancel();
    _incidentsSub?.cancel();
    _profileSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'Hello, $_greetingName',
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
            ),
            Text(
              _locationDone
                  ? (_locationLabel ?? 'Location unavailable')
                  : 'Getting your location…',
              style: Theme.of(context).textTheme.bodySmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
        // Space reserved for the profile avatar shown by the app shell.
        actions: const <Widget>[SizedBox(width: 52)],
      ),
      body: !_locationDone
          ? const LoadingView(message: 'Preparing your dashboard…')
          : RefreshIndicator(
              onRefresh: _loadLocation,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
                children: <Widget>[
                  _weatherCard(),
                  const SizedBox(height: 12),
                  _safetyCard(),
                  const SizedBox(height: 12),
                  if (_activeTrip != null) ...<Widget>[
                    _continueTripCard(),
                    const SizedBox(height: 12),
                  ],
                  _sosCard(),
                  const SectionHeader(title: 'Quick actions'),
                  _quickActions(),
                  SectionHeader(
                    title: 'Nearby attractions',
                    actionLabel: 'See all',
                    onAction: () => context.push('/explore'),
                  ),
                  _attractionsRow(),
                  if (_alerts.isNotEmpty) ...<Widget>[
                    const SectionHeader(title: 'Active alerts'),
                    for (final AppNotification a in _alerts.take(3))
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _alertRow(a),
                      ),
                  ],
                ],
              ),
            ),
    );
  }

  Widget _weatherCard() {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    if (_weatherLoading) {
      return const SkeletonRow(height: 92);
    }
    if (_weatherError != null) {
      return AppCard(
        child: Row(
          children: <Widget>[
            Icon(Icons.cloud_off, color: scheme.error),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                _weatherError!,
                style: Theme.of(context).textTheme.bodySmall,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            TextButton(onPressed: _loadWeather, child: const Text('Retry')),
          ],
        ),
      );
    }
    final WeatherCurrent? w = _weather;
    if (w == null) {
      return AppCard(
        onTap: _loadLocation,
        child: Row(
          children: <Widget>[
            Icon(Icons.my_location, color: scheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Enable location to see weather here.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            const Icon(Icons.chevron_right),
          ],
        ),
      );
    }
    return AppCard(
      onTap: () => context.push('/weather'),
      child: Row(
        children: <Widget>[
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: scheme.primary.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(16),
            ),
            child:
                Icon(_weatherIcon(w.icon), size: 30, color: scheme.primary),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '${w.tempC.toStringAsFixed(0)}°C',
                  style: Theme.of(context)
                      .textTheme
                      .headlineSmall
                      ?.copyWith(fontWeight: FontWeight.w800),
                ),
                Text(
                  w.condition,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              Text(
                '💧 ${w.humidityPct}%',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 4),
              Text(
                '💨 ${(w.windMs * 3.6).toStringAsFixed(0)} km/h',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
          const SizedBox(width: 8),
          const Icon(Icons.chevron_right, color: Colors.grey),
        ],
      ),
    );
  }

  /// "Continue trip" smart card: destination, remaining distance + ETA (from
  /// a real OSRM route) and day progress, with a one-tap jump into Live Trip
  /// mode. Shown only when a saved trip has coordinates.
  Widget _continueTripCard() {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TripPlan trip = _activeTrip!;
    final int totalDays = trip.days <= 0 ? 1 : trip.days;
    final int elapsedDays = DateTime.now()
        .difference(trip.startDate)
        .inDays
        .clamp(0, totalDays);
    final double progress = elapsedDays / totalDays;
    return AppCard(
      onTap: () => context.push(
        '/trip/live?lat=${trip.lat}&lng=${trip.lng}'
        '&name=${Uri.encodeComponent(trip.destination)}',
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.map, color: scheme.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Continue trip · ${trip.destination}',
                  style: Theme.of(context)
                      .textTheme
                      .titleSmall
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              Icon(Icons.navigation, color: scheme.primary, size: 20),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              Expanded(
                child: _tripStat(
                    'Distance',
                    _tripRoute == null
                        ? (_tripRouteLoading ? '…' : '—')
                        : GeoUtils.formatDistance(_tripRoute!.distanceMeters)),
              ),
              Expanded(
                child: _tripStat(
                    'ETA',
                    _tripRoute == null
                        ? (_tripRouteLoading ? '…' : '—')
                        : GeoUtils.formatDuration(_tripRoute!.durationSeconds)),
              ),
              Expanded(
                child: _tripStat(
                    'Day', '${elapsedDays + 1} of $totalDays'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: progress.clamp(0.0, 1.0),
              minHeight: 8,
              backgroundColor: scheme.surfaceContainerHighest,
              color: scheme.primary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _tripStat(String label, String value) {
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

  Widget _safetyCard() {
    final Color accent = switch (_safety.level) {
      SafetyLevel.normal => AppTheme.success,
      SafetyLevel.caution => AppTheme.warning,
      SafetyLevel.alert => AppTheme.danger,
      SafetyLevel.limited => Theme.of(context).colorScheme.outline,
    };
    final String emoji = switch (_safety.level) {
      SafetyLevel.normal => '🟢',
      SafetyLevel.caution => '🟡',
      SafetyLevel.alert => '🔴',
      SafetyLevel.limited => '⚪',
    };
    return AppCard(
      onTap: () => context.push('/safety'),
      child: Row(
        children: <Widget>[
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.shield, color: accent),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '$emoji ${_safety.headline}',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
                const SizedBox(height: 2),
                Text(
                  _safety.detail,
                  style: Theme.of(context).textTheme.bodySmall,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const Icon(Icons.chevron_right, color: Colors.grey),
        ],
      ),
    );
  }

  Widget _sosCard() {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.danger.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(AppTheme.cardRadius),
        border: Border.all(color: AppTheme.danger.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: AppTheme.danger.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child:
                    const Icon(Icons.call, color: AppTheme.danger, size: 26),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'Emergency? Tap SOS',
                      style: TextStyle(
                        color: scheme.onSurface,
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Text(
                      'Records your location, alerts you & shows emergency services',
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              Material(
                color: AppTheme.danger,
                borderRadius: BorderRadius.circular(12),
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => showSOSSheet(context),
                  child: const Padding(
                    padding: EdgeInsets.symmetric(
                        horizontal: 16, vertical: 10),
                    child: Text(
                      'SOS',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              _sosTextButton(Icons.campaign, 'Report incident',
                  () => context.push('/incidents/report')),
              const SizedBox(width: 16),
              _sosTextButton(Icons.qr_code_2, 'Emergency ID',
                  () => context.push('/digital-id')),
            ],
          ),
        ],
      ),
    );
  }

  Widget _sosTextButton(IconData icon, String label, VoidCallback onTap) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Expanded(
      child: OutlinedButton.icon(
        onPressed: onTap,
        style: OutlinedButton.styleFrom(
          foregroundColor: scheme.onSurface,
          side: BorderSide(color: scheme.outlineVariant),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.symmetric(vertical: 10),
        ),
        icon: Icon(icon, size: 16),
        label: Flexible(
          child: Text(label,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600)),
        ),
      ),
    );
  }

  Widget _quickActions() {
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      childAspectRatio: 1.9,
      children: <Widget>[
        _actionTile('AI Assistant', Icons.auto_awesome, '/assistant'),
        _actionTile('Price check', Icons.price_check, '/guardian'),
        _actionTile('Explore', Icons.explore, '/explore'),
        _actionTile('Map & routes', Icons.map, '/map'),
        _actionTile('Report incident', Icons.campaign, '/incidents/report'),
        _actionTile('Eco Score', Icons.eco, '/eco'),
        _actionTile('Emergency ID', Icons.qr_code_2, '/digital-id'),
        _actionTile('Weather', Icons.wb_sunny, '/weather'),
        _actionTile('Nearby essentials', Icons.local_hospital, '/essentials'),
        _actionTile('Budget & wallet', Icons.account_balance_wallet,
            '/wallet'),
        _actionTile('Trip planner', Icons.event_note, '/planner'),
        _actionTile('Multi-stop route', Icons.alt_route, '/route/multi'),
      ],
    );
  }

  Widget _actionTile(String label, IconData icon, String route) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return AppCard(
      onTap: () => context.push(route),
      padding: const EdgeInsets.all(12),
      child: Row(
        children: <Widget>[
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: scheme.primary.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: scheme.primary, size: 20),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _attractionsRow() {
    if (_attrLoading) {
      return SizedBox(
        height: 104,
        child: Row(
          children: <Widget>[
            const Expanded(child: SkeletonCard(height: 104)),
            const SizedBox(width: 12),
            Expanded(child: SkeletonCard(height: 104)),
          ],
        ),
      );
    }
    if (_attrError != null) {
      return AppCard(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
        child: Row(
          children: <Widget>[
            Icon(Icons.cloud_off, color: Theme.of(context).colorScheme.error),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                _attrError!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            TextButton(onPressed: _loadAttractions, child: const Text('Retry')),
          ],
        ),
      );
    }
    if (_attractions.isEmpty) {
      return AppCard(
        child: Text(
          'No attractions found nearby right now. Try Explore to search a wider area.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      );
    }
    return SizedBox(
      height: 104,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: _attractions.length,
        separatorBuilder: (BuildContext context, int index) =>
            const SizedBox(width: 12),
        itemBuilder: (BuildContext context, int i) => _MiniPlaceCard(
              place: _attractions[i],
              onTap: () => context.push(
                  '/explore/place/${_attractions[i].placeId}',
                  extra: _attractions[i]),
            ),
      ),
    );
  }

  Widget _alertRow(AppNotification a) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final IconData icon = switch (a.type) {
      'emergency' => Icons.sos,
      'geofence' => Icons.gps_not_fixed,
      'incident' => Icons.campaign,
      _ => Icons.shield,
    };
    final Color color =
        a.type == 'emergency' ? AppTheme.danger : AppTheme.warning;
    return AppCard(
      onTap: () => context.push('/notifications'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: <Widget>[
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: color, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  a.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
                Text(
                  Fmt.relative(a.createdAt),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                ),
              ],
            ),
          ),
          Container(
            width: 8,
            height: 8,
            decoration: const BoxDecoration(
              color: AppTheme.danger,
              shape: BoxShape.circle,
            ),
          ),
        ],
      ),
    );
  }
}

/// Compact horizontal-strip place card.
class _MiniPlaceCard extends StatelessWidget {
  const _MiniPlaceCard({required this.place, required this.onTap});

  final Place place;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color accent = PlaceCard.colorFor(context, place);
    return AppCard(
      onTap: onTap,
      padding: const EdgeInsets.all(12),
      child: SizedBox(
        width: 190,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(PlaceCard.iconFor(place), color: accent),
            ),
            const Spacer(),
            Text(
              place.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
            Text(
              place.rating != null
                  ? '★ ${place.rating!.toStringAsFixed(1)}'
                  : (place.primaryType ?? '').replaceAll('_', ' '),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}
