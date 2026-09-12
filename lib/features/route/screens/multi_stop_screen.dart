import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' as gm;
import 'package:latlong2/latlong.dart';

import '../../../core/app_config.dart';
import '../../../core/state/app_container.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/geo.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/state_views.dart';
import '../../../data/models/places.dart';

/// Multi-stop route planner: order a set of stops into a sensible visiting
/// order and sum real OSRM legs between them.
///
/// The order is a nearest-neighbour heuristic (always start from the nearest
/// stop and repeatedly visit the nearest remaining one) — it is a sensible
/// order, not a guarantee of the mathematically shortest route.
class MultiStopScreen extends StatefulWidget {
  const MultiStopScreen({super.key});

  @override
  State<MultiStopScreen> createState() => _MultiStopScreenState();
}

class _MultiStopScreenState extends State<MultiStopScreen> {
  AppContainer get _c => AppScope.of(context);

  final TextEditingController _query = TextEditingController();
  final MapController _controller = MapController();

  Position? _position;
  bool _locationDone = false;

  List<Place> _stops = <Place>[];
  List<Place> _searchResults = const <Place>[];
  bool _searching = false;

  List<Place> _ordered = const <Place>[];
  List<RouteInfo> _legs = const <RouteInfo>[];
  List<LatLng> _combinedLine = const <LatLng>[];
  bool _planning = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _locate();
  }

  Future<void> _locate() async {
    try {
      final Position? pos = await _c.locationService.currentPosition();
      if (!mounted) return;
      setState(() {
        _position = pos;
        _locationDone = true;
      });
    } catch (_) {
      if (mounted) setState(() => _locationDone = true);
    }
  }

  Future<void> _search() async {
    final String q = _query.text.trim();
    if (q.isEmpty) return;
    setState(() {
      _searching = true;
      _searchResults = const <Place>[];
    });
    try {
      final gm.LatLng? near = _position != null
          ? gm.LatLng(_position!.latitude, _position!.longitude)
          : null;
      final List<Place> results = await _c.placesRepository.search(
        q,
        location: near,
        radiusMeters: 30000,
      );
      if (!mounted) return;
      setState(() {
        _searchResults = results;
        _searching = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _searching = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Search failed. Try again.')),
      );
    }
  }

  void _addStop(Place p) {
    if (_stops.any((Place e) => e.placeId == p.placeId)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('That stop is already in the list.')),
      );
      return;
    }
    setState(() {
      _stops = <Place>[..._stops, p];
      _searchResults = const <Place>[];
      _query.clear();
    });
  }

  void _removeStop(Place p) {
    setState(() => _stops = _stops.where((Place e) => e.placeId != p.placeId).toList());
  }

  /// Nearest-neighbour ordering from the current location.
  List<Place> _orderStops(List<Place> stops) {
    if (stops.length <= 2) return List<Place>.from(stops);
    final List<Place> remaining = List<Place>.from(stops);
    final List<Place> ordered = <Place>[];
    gm.LatLng current = _position != null
        ? gm.LatLng(_position!.latitude, _position!.longitude)
        : remaining.first.coords;
    while (remaining.isNotEmpty) {
      int best = 0;
      double bestD = double.infinity;
      for (int i = 0; i < remaining.length; i++) {
        final double d = GeoUtils.distanceMeters(current, remaining[i].coords);
        if (d < bestD) {
          bestD = d;
          best = i;
        }
      }
      final Place next = remaining.removeAt(best);
      ordered.add(next);
      current = next.coords;
    }
    return ordered;
  }

  Future<void> _plan() async {
    if (_stops.length < 2) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Add at least two stops to plan a route.')),
      );
      return;
    }
    setState(() {
      _planning = true;
      _error = null;
      _legs = const <RouteInfo>[];
      _combinedLine = const <LatLng>[];
    });
    try {
      final List<Place> ordered = _orderStops(_stops);
      gm.LatLng prev = _position != null
          ? gm.LatLng(_position!.latitude, _position!.longitude)
          : ordered.first.coords;
      final List<RouteInfo> legs = <RouteInfo>[];
      final List<LatLng> combined = <LatLng>[];
      for (final Place p in ordered) {
        final RouteInfo leg = await _c.placesRepository.route(
          gm.LatLng(prev.latitude, prev.longitude),
          gm.LatLng(p.lat, p.lng),
          mode: 'car',
        );
        legs.add(leg);
        final List<LatLng> line = leg.polyline
            .map((gm.LatLng lp) => LatLng(lp.latitude, lp.longitude))
            .toList();
        if (combined.isEmpty) {
          combined.addAll(line);
        } else {
          combined.addAll(line.skip(1));
        }
        prev = p.coords;
      }
      if (!mounted) return;
      setState(() {
        _ordered = ordered;
        _legs = legs;
        _combinedLine = combined;
        _planning = false;
      });
      _fitMap();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _planning = false;
      });
    }
  }

  void _fitMap() {
    if (_combinedLine.isEmpty) return;
    try {
      double minLat = _combinedLine.first.latitude;
      double maxLat = _combinedLine.first.latitude;
      double minLng = _combinedLine.first.longitude;
      double maxLng = _combinedLine.first.longitude;
      for (final LatLng p in _combinedLine) {
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
    } catch (_) {}
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

  double get _totalDistance =>
      _legs.fold<double>(0, (double s, RouteInfo r) => s + r.distanceMeters);

  double get _totalDuration =>
      _legs.fold<double>(0, (double s, RouteInfo r) => s + r.durationSeconds);

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Multi-stop route')),
      body: !_locationDone
          ? const LoadingView(message: 'Finding your location…')
          : ListView(
              padding: const EdgeInsets.all(16),
              children: <Widget>[
                _addStopCard(scheme),
                const SizedBox(height: 12),
                _stopsCard(scheme),
                const SizedBox(height: 12),
                _planCard(scheme),
                const SizedBox(height: 16),
              ],
            ),
    );
  }

  Widget _addStopCard(ColorScheme scheme) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('Add stops',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  controller: _query,
                  decoration: const InputDecoration(
                    hintText: 'Search a place to add…',
                    prefixIcon: Icon(Icons.search, size: 18),
                    isDense: true,
                  ),
                  onSubmitted: (_) => _search(),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _searching ? null : _search,
                child: _searching
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : const Text('Add'),
              ),
            ],
          ),
          if (_searchResults.isNotEmpty) ...<Widget>[
            const SizedBox(height: 8),
            Container(
              constraints: const BoxConstraints(maxHeight: 240),
              decoration: BoxDecoration(
                border: Border.all(color: scheme.outlineVariant),
                borderRadius: BorderRadius.circular(10),
              ),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: _searchResults.length,
                itemBuilder: (BuildContext context, int i) {
                  final Place p = _searchResults[i];
                  return ListTile(
                    dense: true,
                    leading: const Icon(Icons.place, size: 18),
                    title: Text(p.name,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    onTap: () => _addStop(p),
                  );
                },
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _stopsCard(ColorScheme scheme) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('Stops (${_stops.length})',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          if (_stops.isEmpty)
            Text('No stops yet — add at least two.',
                style: Theme.of(context).textTheme.bodySmall)
          else
            for (final Place p in _stops)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.place_outlined, size: 20),
                title: Text(p.name,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                trailing: IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () => _removeStop(p),
                ),
              ),
        ],
      ),
    );
  }

  Widget _planCard(ColorScheme scheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: _planning ? null : _plan,
            icon: _planning
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white),
                  )
                : const Icon(Icons.alt_route),
            label: Text(_planning ? 'Planning…' : 'Order & plan route'),
          ),
        ),
        if (_error != null) ...<Widget>[
          const SizedBox(height: 8),
          Text(_error!,
              style: TextStyle(color: AppTheme.danger, fontSize: 12.5)),
        ],
        if (_ordered.isNotEmpty) ...<Widget>[
          const SizedBox(height: 12),
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('Sensible order',
                    style: Theme.of(context)
                        .textTheme
                        .titleSmall
                        ?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(
                  'Nearest-neighbour order from your location — sensible, '
                  'not a guarantee of the shortest route.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 10),
                for (int i = 0; i < _ordered.length; i++) ...<Widget>[
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: <Widget>[
                        CircleAvatar(
                          radius: 12,
                          backgroundColor:
                              scheme.primary.withValues(alpha: 0.12),
                          child: Text('${i + 1}',
                              style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w800,
                                  color: scheme.primary)),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(_ordered[i].name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis),
                        ),
                        if (i < _legs.length)
                          Text(
                            '${GeoUtils.formatDistance(_legs[i].distanceMeters)}'
                            ' · '
                            '${GeoUtils.formatDuration(_legs[i].durationSeconds)}',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                      ],
                    ),
                  ),
                ],
                const Divider(height: 20),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text('Total',
                          style: const TextStyle(
                              fontWeight: FontWeight.w800)),
                    ),
                    Text(
                      '${GeoUtils.formatDistance(_totalDistance)} · '
                      '${GeoUtils.formatDuration(_totalDuration)}',
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
        if (_combinedLine.length >= 2) ...<Widget>[
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: SizedBox(
              height: 260,
              child: FlutterMap(
                mapController: _controller,
                options: MapOptions(
                  initialCenter: _combinedLine.first,
                  initialZoom: 12,
                  maxZoom: 19,
                ),
                children: <Widget>[
                  TileLayer(
                    urlTemplate: AppConfig.mapTilerTileUrl('streets-v2'),
                    userAgentPackageName: 'app.roamio.tourism',
                    retinaMode: RetinaMode.isHighDensity(context),
                    maxNativeZoom: 19,
                  ),
                  PolylineLayer(
                    polylines: <Polyline>[
                      Polyline(
                        points: _combinedLine,
                        color: scheme.primary,
                        strokeWidth: 5,
                      ),
                    ],
                  ),
                  MarkerLayer(
                    markers: <Marker>[
                      for (int i = 0; i < _ordered.length; i++)
                        Marker(
                          point: LatLng(_ordered[i].lat, _ordered[i].lng),
                          width: 30,
                          height: 30,
                          child: CircleAvatar(
                            radius: 14,
                            backgroundColor: scheme.primary,
                            child: Text('${i + 1}',
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w800)),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}
