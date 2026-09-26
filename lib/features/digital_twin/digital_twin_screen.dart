import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' as gm;
import 'package:latlong2/latlong.dart' as ll;

import '../../core/app_config.dart';
import '../../core/state/app_container.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/geo.dart';
import '../../core/widgets/app_card.dart';
import '../../data/local/nearby_store.dart';
import '../../data/models/places.dart';
import '../../data/models/weather.dart';
import 'digital_twin_engine.dart';

/// Progressive destination digital twin:
/// level 1 works with routes, constraints and an honest timeline; current
/// weather/provider POIs enrich it when available; the existing map supplies
/// 2D/2.5D/3D visualization without pretending unavailable geometry exists.
class DigitalTwinScreen extends StatefulWidget {
  const DigitalTwinScreen({super.key, required this.destination});

  final Place destination;

  @override
  State<DigitalTwinScreen> createState() => _DigitalTwinScreenState();
}

class _DigitalTwinScreenState extends State<DigitalTwinScreen> {
  AppContainer get _c => AppScope.of(context);

  bool _bound = false;
  bool _loading = true;
  String? _error;
  Place? _origin;
  Position? _devicePosition;
  RouteInfo? _walkRoute;
  RouteInfo? _carRoute;
  WeatherCurrent? _weather;
  List<Place> _facilities = const <Place>[];
  bool _nearbySaved = false;

  TwinCrowdScenario _crowd = TwinCrowdScenario.normal;
  final Set<TwinAccessNeed> _access = <TwinAccessNeed>{};
  double _departureHour = 8;
  double _maxWalking = 1500;
  double _budget = 1000;
  double _availableHours = 4;
  double _queueBaseline = 15;
  double _visitMinutes = 90;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_bound) return;
    _bound = true;
    unawaited(_load());
  }

  gm.LatLng? get _originCoords {
    final Place? origin = _origin;
    if (origin != null) return origin.coords;
    final Position? position = _devicePosition;
    if (position == null) return null;
    return gm.LatLng(position.latitude, position.longitude);
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      _devicePosition = await _c.locationService.currentPosition();
      await _loadDestinationData();
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'The simulator could not load route data. You can retry or select a different starting point.';
        });
      }
    }
  }

  Future<void> _loadDestinationData() async {
    final gm.LatLng? from = _originCoords;
    final gm.LatLng to = widget.destination.coords;

    Future<RouteInfo?> route(String mode) async {
      if (from == null) return null;
      try {
        return await _c.placesRepository.route(from, to, mode: mode);
      } catch (_) {
        return null;
      }
    }

    Future<WeatherCurrent?> weather() async {
      try {
        return await _c.weatherRepository.current(to);
      } catch (_) {
        return null;
      }
    }

    Future<NearbyResult?> nearby() async {
      try {
        return await _c.placesRepository.nearbyAround(to,
            radiusMeters: 2500);
      } catch (_) {
        return null;
      }
    }

    final List<dynamic> values = await Future.wait<dynamic>(<Future<dynamic>>[
      route('walk'),
      route('car'),
      weather(),
      nearby(),
    ]);
    if (!mounted) return;
    final NearbyResult? nearbyResult = values[3] as NearbyResult?;
    setState(() {
      _walkRoute = values[0] as RouteInfo?;
      _carRoute = values[1] as RouteInfo?;
      _weather = values[2] as WeatherCurrent?;
      _facilities = _usefulFacilities(nearbyResult?.places ?? const <Place>[]);
      _nearbySaved = nearbyResult?.fromCache ?? false;
      _loading = false;
      _error = from == null
          ? 'Current location is unavailable. Select a starting place to calculate routes.'
          : null;
    });
  }

  List<Place> _usefulFacilities(List<Place> places) {
    const Set<String> categories = <String>{
      'toilets',
      'toilet',
      'restaurant',
      'cafe',
      'hospital',
      'pharmacy',
      'police',
      'parking',
      'transit',
      'bus',
      'station',
      'atm',
    };
    final List<Place> result = places.where((Place p) {
      final String haystack = <String>[
        p.category ?? '',
        p.primaryType ?? '',
        ...p.types,
        p.name,
      ].join(' ').toLowerCase();
      return categories.any(haystack.contains);
    }).toList()
      ..sort((Place a, Place b) =>
          (a.distanceMeters ?? double.infinity)
              .compareTo(b.distanceMeters ?? double.infinity));
    return result.take(12).toList(growable: false);
  }

  TwinRouteMetric? _metric(RouteInfo? route, TwinTravelMode mode) {
    if (route == null) return null;
    return TwinRouteMetric(
      mode: mode,
      distanceMeters: route.distanceMeters,
      durationMinutes: (route.durationSeconds / 60).ceil(),
      approximate: route.isApproximate,
    );
  }

  bool? get _wheelchairAccess {
    final Object? raw = widget.destination.metadata['wheelchair'];
    if (raw == true || raw?.toString().toLowerCase() == 'yes') return true;
    if (raw == false || raw?.toString().toLowerCase() == 'no') return false;
    return null;
  }

  int? _metadataInt(String key) =>
      int.tryParse(widget.destination.metadata[key]?.toString() ?? '');

  TwinSimulationResult get _simulation {
    final DateTime now = DateTime.now();
    final DateTime departure = DateTime(
      now.year,
      now.month,
      now.day,
      _departureHour.floor(),
      ((_departureHour % 1) * 60).round(),
    );
    return DigitalTwinEngine.simulate(TwinSimulationInput(
      departure: departure,
      crowd: _crowd,
      maximumWalkingMeters: _maxWalking,
      maximumBudgetRupees: _budget,
      availableMinutes: (_availableHours * 60).round(),
      assumedBaseQueueMinutes: _queueBaseline.round(),
      visitMinutes: _visitMinutes.round(),
      walkRoute: _metric(_walkRoute, TwinTravelMode.walk),
      carRoute: _metric(_carRoute, TwinTravelMode.car),
      accessNeeds: _access,
      destinationWheelchairAccess: _wheelchairAccess,
      knownStairSections: _metadataInt('stair_sections'),
      knownAccessibleEntrances: _metadataInt('accessible_entrances'),
    ));
  }

  Future<void> _chooseOrigin() async {
    final TextEditingController controller = TextEditingController();
    List<Place> results = const <Place>[];
    bool searching = false;
    int generation = 0;
    final Place? selected = await showDialog<Place>(
      context: context,
      builder: (BuildContext dialogContext) => StatefulBuilder(
        builder: (BuildContext context, StateSetter setDialogState) =>
            AlertDialog(
          title: const Text('Select starting point'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                TextField(
                  controller: controller,
                  autofocus: true,
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    hintText: 'Hotel, station or address',
                  ),
                  onSubmitted: (String query) async {
                    final String q = query.trim();
                    if (q.length < 2) return;
                    final int request = ++generation;
                    setDialogState(() => searching = true);
                    final List<Place> found = await _c.placesRepository.search(
                      q,
                      location: widget.destination.coords,
                      biasToUserLocation: true,
                    );
                    if (!dialogContext.mounted || request != generation) return;
                    setDialogState(() {
                      searching = false;
                      results = found.take(8).toList(growable: false);
                    });
                  },
                ),
                if (searching)
                  const Padding(
                    padding: EdgeInsets.all(18),
                    child: CircularProgressIndicator(),
                  )
                else
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: results.length,
                      itemBuilder: (BuildContext context, int index) {
                        final Place place = results[index];
                        return ListTile(
                          leading: const Icon(Icons.place_outlined),
                          title: Text(place.name),
                          subtitle: Text(place.contextLine.isEmpty
                              ? (place.address ?? 'Location result')
                              : place.contextLine.substring(3)),
                          onTap: () => Navigator.pop(dialogContext, place),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    if (selected == null || !mounted) return;
    setState(() {
      _origin = selected;
      _loading = true;
      _error = null;
    });
    await _loadDestinationData();
  }

  @override
  Widget build(BuildContext context) {
    final TwinSimulationResult simulation = _simulation;
    return Scaffold(
      appBar: AppBar(title: const Text('Digital Twin Simulator')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _loadDestinationData,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 110),
                children: <Widget>[
                  _hero(simulation),
                  const SizedBox(height: 12),
                  if (_error != null) _notice(_error!, error: true),
                  _dataStatus(),
                  const SizedBox(height: 12),
                  _map(simulation),
                  const SizedBox(height: 16),
                  _controls(),
                  const SizedBox(height: 16),
                  _decision(simulation),
                  const SizedBox(height: 16),
                  _timeline(simulation),
                  const SizedBox(height: 16),
                  _accessibility(simulation),
                  const SizedBox(height: 16),
                  _facilitiesCard(),
                  const SizedBox(height: 16),
                  _warnings(simulation),
                ],
              ),
            ),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.all(12),
        child: Row(
          children: <Widget>[
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.threed_rotation),
                label: const Text('Open 2D / 3D map'),
                // /map is a stateful shell branch. `push` can stack a second
                // shell above the simulator while leaving that branch without
                // an active page on some Android builds (white body + bottom
                // bar). `go` performs the intended branch switch atomically.
                onPressed: () => context.go(
                  '/map?lat=${widget.destination.lat}&lng=${widget.destination.lng}&name=${Uri.encodeComponent(widget.destination.name)}',
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton.icon(
                icon: const Icon(Icons.navigation),
                label: const Text('Start navigation'),
                onPressed: simulation.recommended == null
                    ? null
                    : () => context.push(
                          '/trip/live?lat=${widget.destination.lat}&lng=${widget.destination.lng}&name=${Uri.encodeComponent(widget.destination.name)}',
                        ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _hero(TwinSimulationResult simulation) {
    final Color color = simulation.feasible ? AppTheme.success : AppTheme.warning;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(widget.destination.name,
              style: Theme.of(context).textTheme.headlineSmall),
          if (widget.destination.address != null) ...<Widget>[
            const SizedBox(height: 4),
            Text(widget.destination.address!),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              _metricChip(Icons.schedule, GeoUtils.formatDuration(simulation.totalMinutes * 60.0)),
              _metricChip(
                Icons.directions_walk,
                simulation.recommended?.mode == TwinTravelMode.car
                    ? 'On-site walking unknown'
                    : '${simulation.walkingMeters.round()} m routed walking',
              ),
              _metricChip(Icons.currency_rupee,
                  '${simulation.estimatedCostRupees.round()} estimated'),
              Chip(
                avatar: Icon(simulation.feasible ? Icons.check_circle : Icons.warning,
                    size: 18, color: color),
                label: Text(simulation.feasible
                    ? 'Fits selected limits'
                    : 'One or more limits exceeded'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              const Icon(Icons.trip_origin, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(_origin?.name ??
                    (_devicePosition == null ? 'Starting point needed' : 'My current location')),
              ),
              TextButton(onPressed: _chooseOrigin, child: const Text('Change')),
            ],
          ),
        ],
      ),
    );
  }

  Widget _dataStatus() => AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Row(children: <Widget>[
              Icon(Icons.fact_check_outlined),
              SizedBox(width: 8),
              Text('Data status', style: TextStyle(fontWeight: FontWeight.w800)),
            ]),
            const SizedBox(height: 10),
            _statusRow('Routes', _walkRoute != null || _carRoute != null,
                'OSRM/provider route geometry'),
            _statusRow('Weather', _weather != null,
                _weather == null ? 'Unavailable' : 'Current provider reading'),
            _statusRow('Facilities', _facilities.isNotEmpty,
                _facilities.isEmpty ? 'No provider records found' : '${_facilities.length} nearby provider records${_nearbySaved ? ' · saved data' : ''}'),
            _statusRow('Live crowd / queue', false,
                'Unavailable · scenario assumptions are shown separately'),
            _statusRow('Verified stairs / entrances',
                _metadataInt('stair_sections') != null || _metadataInt('accessible_entrances') != null,
                'Only shown when provider metadata contains it'),
          ],
        ),
      );

  Widget _statusRow(String name, bool available, String detail) => Padding(
        padding: const EdgeInsets.only(bottom: 7),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(available ? Icons.check_circle : Icons.info_outline,
                size: 17,
                color: available ? AppTheme.success : AppTheme.warning),
            const SizedBox(width: 8),
            Expanded(child: Text('$name — $detail')),
          ],
        ),
      );

  Widget _map(TwinSimulationResult simulation) {
    final gm.LatLng? from = _originCoords;
    final RouteInfo? chosen = simulation.recommended?.mode == TwinTravelMode.walk
        ? _walkRoute
        : _carRoute;
    final List<ll.LatLng> points = (chosen?.polyline ?? const <gm.LatLng>[])
        .map((gm.LatLng p) => ll.LatLng(p.latitude, p.longitude))
        .toList(growable: false);
    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: SizedBox(
        height: 260,
        child: RepaintBoundary(
          child: FlutterMap(
            options: MapOptions(
              initialCenter: ll.LatLng(widget.destination.lat, widget.destination.lng),
              initialZoom: 14,
            ),
            children: <Widget>[
              TileLayer(
                urlTemplate: AppConfig.mapTilerConfigured
                    ? AppConfig.mapTilerTileUrl('streets-v2')
                    : AppConfig.fallbackTileUrl,
                fallbackUrl: AppConfig.fallbackTileUrl,
                userAgentPackageName: 'app.roamio.tourism',
              ),
              if (points.length >= 2)
                PolylineLayer(polylines: <Polyline>[
                  Polyline(points: points, strokeWidth: 5, color: AppTheme.brandStart),
                ]),
              MarkerLayer(markers: <Marker>[
                if (from != null)
                  Marker(
                    point: ll.LatLng(from.latitude, from.longitude),
                    width: 36,
                    height: 36,
                    child: const Icon(Icons.trip_origin, color: AppTheme.success),
                  ),
                Marker(
                  point: ll.LatLng(widget.destination.lat, widget.destination.lng),
                  width: 42,
                  height: 42,
                  child: const Icon(Icons.location_on, color: AppTheme.danger, size: 38),
                ),
                for (final Place p in _facilities.take(8))
                  Marker(
                    point: ll.LatLng(p.lat, p.lng),
                    width: 30,
                    height: 30,
                    child: Tooltip(
                      message: p.name,
                      child: GestureDetector(
                        onTap: () => ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(p.name)),
                        ),
                        child: const Icon(Icons.add_location_alt,
                            color: Color(0xFF0F766E), size: 24),
                      ),
                    ),
                  ),
              ]),
              RichAttributionWidget(
                showFlutterMapAttribution: false,
                attributions: <SourceAttribution>[
                  TextSourceAttribution('© OpenStreetMap contributors'),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _controls() => AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('What-if controls', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 6),
            const Text('Changes recalculate locally and instantly. Crowd and queue are explicit scenarios, not live claims.'),
            _slider('Departure', _departureHour, 6, 20,
                (double v) => setState(() => _departureHour = v),
                value: '${_departureHour.floor().toString().padLeft(2, '0')}:${(((_departureHour % 1) * 60).round()).toString().padLeft(2, '0')}'),
            SegmentedButton<TwinCrowdScenario>(
              segments: const <ButtonSegment<TwinCrowdScenario>>[
                ButtonSegment(value: TwinCrowdScenario.low, label: Text('Low')),
                ButtonSegment(value: TwinCrowdScenario.normal, label: Text('Normal')),
                ButtonSegment(value: TwinCrowdScenario.high, label: Text('High')),
              ],
              selected: <TwinCrowdScenario>{_crowd},
              onSelectionChanged: (Set<TwinCrowdScenario> s) =>
                  setState(() => _crowd = s.first),
            ),
            _slider('Base queue assumption', _queueBaseline, 0, 90,
                (double v) => setState(() => _queueBaseline = v),
                value: '${_queueBaseline.round()} min'),
            _slider('Maximum walking', _maxWalking, 100, 5000,
                (double v) => setState(() => _maxWalking = v),
                value: '${_maxWalking.round()} m'),
            _slider('Maximum budget', _budget, 0, 5000,
                (double v) => setState(() => _budget = v),
                value: '₹${_budget.round()}'),
            _slider('Available time', _availableHours, 1, 10,
                (double v) => setState(() => _availableHours = v),
                value: '${_availableHours.toStringAsFixed(1)} h'),
            _slider('Visit allowance', _visitMinutes, 30, 240,
                (double v) => setState(() => _visitMinutes = v),
                value: '${_visitMinutes.round()} min'),
            const SizedBox(height: 8),
            const Text('Accessibility needs', style: TextStyle(fontWeight: FontWeight.w800)),
            Wrap(
              spacing: 7,
              children: TwinAccessNeed.values.map((TwinAccessNeed need) =>
                FilterChip(
                  label: Text(_accessLabel(need)),
                  selected: _access.contains(need),
                  onSelected: (bool selected) => setState(() {
                    selected ? _access.add(need) : _access.remove(need);
                    if (need == TwinAccessNeed.limitedWalking && selected) {
                      _maxWalking = _maxWalking.clamp(100, 700);
                    }
                  }),
                )).toList(growable: false),
            ),
          ],
        ),
      );

  Widget _slider(String label, double current, double min, double max,
          ValueChanged<double> onChanged,
          {required String value}) =>
      Column(children: <Widget>[
        const SizedBox(height: 12),
        Row(children: <Widget>[
          Expanded(child: Text(label, style: const TextStyle(fontWeight: FontWeight.w700))),
          Text(value),
        ]),
        Slider(
          value: current.clamp(min, max),
          min: min,
          max: max,
          divisions: 40,
          onChanged: onChanged,
        ),
      ]);

  Widget _decision(TwinSimulationResult simulation) => AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('Decision options', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 10),
            for (final TwinScenarioOption option in simulation.options)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(option.mode == TwinTravelMode.walk
                    ? Icons.directions_walk
                    : Icons.directions_car),
                title: Text(option.title,
                    style: const TextStyle(fontWeight: FontWeight.w800)),
                subtitle: Text('${GeoUtils.formatDuration(option.totalMinutes * 60.0)} · ${option.walkingMeters.round()} m walking · ₹${option.estimatedCostRupees.round()} estimated\n${option.reason}'),
                trailing: Icon(option.feasible ? Icons.check_circle : Icons.warning,
                    color: option.feasible ? AppTheme.success : AppTheme.warning),
              ),
          ],
        ),
      );

  Widget _timeline(TwinSimulationResult simulation) => AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('Predicted visit timeline', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            for (int i = 0; i < simulation.stages.length; i++) ...<Widget>[
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                Column(children: <Widget>[
                  CircleAvatar(radius: 15, child: Text('${i + 1}')),
                  if (i < simulation.stages.length - 1)
                    Container(width: 2, height: 42, color: Theme.of(context).colorScheme.outlineVariant),
                ]),
                const SizedBox(width: 12),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                  Text(simulation.stages[i].title, style: const TextStyle(fontWeight: FontWeight.w800)),
                  Text('${simulation.stages[i].detail}${simulation.stages[i].minutes > 0 ? ' · ${simulation.stages[i].minutes} min' : ''}'),
                  Text(_evidenceLabel(simulation.stages[i].evidence),
                      style: Theme.of(context).textTheme.bodySmall),
                ])),
              ]),
            ],
          ],
        ),
      );

  Widget _accessibility(TwinSimulationResult simulation) => AppCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          Text('Accessibility check', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(_wheelchairAccess == true
              ? 'Provider metadata: wheelchair access marked yes.'
              : _wheelchairAccess == false
                  ? 'Provider metadata: wheelchair access marked no.'
                  : 'Wheelchair access is not present in available provider metadata.'),
          const SizedBox(height: 6),
          Text('Stair sections: ${_metadataInt('stair_sections')?.toString() ?? 'not available'}'),
          Text('Accessible entrances: ${_metadataInt('accessible_entrances')?.toString() ?? 'not available'}'),
          for (final String warning in simulation.accessibilityWarnings)
            Padding(padding: const EdgeInsets.only(top: 7), child: Text('⚠ $warning')),
        ]),
      );

  Widget _facilitiesCard() => AppCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          Text('Nearby facilities', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          if (_facilities.isEmpty)
            const Text('No facility records were returned. This does not prove that facilities are absent.')
          else
            for (final Place facility in _facilities)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.place_outlined),
                title: Text(facility.name),
                subtitle: Text('${facility.category ?? facility.primaryType ?? 'facility'}${facility.distanceMeters == null ? '' : ' · ${GeoUtils.formatDistance(facility.distanceMeters!)}'}'),
              ),
        ]),
      );

  Widget _warnings(TwinSimulationResult simulation) => AppCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          const Row(children: <Widget>[
            Icon(Icons.verified_user_outlined), SizedBox(width: 8),
            Text('Honesty & limitations', style: TextStyle(fontWeight: FontWeight.w800)),
          ]),
          const SizedBox(height: 8),
          for (final String warning in simulation.dataWarnings)
            Padding(padding: const EdgeInsets.only(bottom: 6), child: Text('• $warning')),
          const Text('The 3D view uses available map/building data and is not claimed to be an exact replica.'),
        ]),
      );

  Widget _notice(String text, {bool error = false}) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: error
                ? Theme.of(context).colorScheme.errorContainer
                : Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(text),
        ),
      );

  Widget _metricChip(IconData icon, String text) => Chip(
        avatar: Icon(icon, size: 17),
        label: Text(text),
      );

  String _accessLabel(TwinAccessNeed need) => switch (need) {
        TwinAccessNeed.wheelchair => 'Wheelchair',
        TwinAccessNeed.elderly => 'Elderly',
        TwinAccessNeed.stroller => 'Stroller',
        TwinAccessNeed.avoidStairs => 'Avoid stairs',
        TwinAccessNeed.limitedWalking => 'Limited walking',
        TwinAccessNeed.heavyLuggage => 'Heavy luggage',
      };

  String _evidenceLabel(TwinEvidence evidence) => switch (evidence) {
        TwinEvidence.routed => 'Provider route data',
        TwinEvidence.current => 'Current provider data',
        TwinEvidence.providerStatic => 'Provider static metadata',
        TwinEvidence.userScenario => 'Scenario assumption',
        TwinEvidence.unavailable => 'Unavailable',
      };
}
