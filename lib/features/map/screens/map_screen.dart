import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart' as osm;
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' as google;
import 'package:latlong2/latlong.dart' as ll;
import 'package:url_launcher/url_launcher.dart';

import '../../../core/app_config.dart';
import '../../../core/state/app_container.dart';
import '../../../core/utils/geo.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/badges.dart';
import '../../../core/widgets/state_views.dart';
import '../../../data/models/places.dart';
import '../../../data/models/safety_zone.dart';

/// Interactive location-aware map with MapTiler satellite and OSM street
/// layers. Live place search and traffic-aware road routes use the secured
/// Firebase backend; the MapTiler public client token is injected at build
/// time rather than committed to source.
class MapScreen extends StatefulWidget {
  const MapScreen({
    super.key,
    this.initialLat,
    this.initialLng,
    this.initialName,
  });

  final double? initialLat;
  final double? initialLng;
  final String? initialName;

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  static const ll.LatLng _lucknow = ll.LatLng(26.8467, 80.9462);

  static final List<Place> _demoPlaces = <Place>[
    Place(
      placeId: 'demo-bara-imambara',
      name: 'Bara Imambara',
      lat: 26.8694,
      lng: 80.9126,
      address: 'Husainabad, Lucknow',
      rating: 4.5,
      primaryType: 'tourist_attraction',
      types: const <String>['tourist_attraction'],
    ),
    Place(
      placeId: 'demo-residency',
      name: 'The Residency',
      lat: 26.8606,
      lng: 80.9230,
      address: 'Mahatma Gandhi Marg, Lucknow',
      rating: 4.4,
      primaryType: 'tourist_attraction',
      types: const <String>['tourist_attraction', 'museum'],
    ),
    Place(
      placeId: 'demo-ambedkar-park',
      name: 'Dr. Ambedkar Memorial Park',
      lat: 26.8485,
      lng: 80.9874,
      address: 'Gomti Nagar, Lucknow',
      rating: 4.4,
      primaryType: 'park',
      types: const <String>['park', 'tourist_attraction'],
    ),
    Place(
      placeId: 'demo-rumi-darwaza',
      name: 'Rumi Darwaza',
      lat: 26.8678,
      lng: 80.9135,
      address: 'Husainabad Road, Lucknow',
      rating: 4.5,
      primaryType: 'tourist_attraction',
      types: const <String>['tourist_attraction'],
    ),
    Place(
      placeId: 'demo-janeshwar-park',
      name: 'Janeshwar Mishra Park',
      lat: 26.8489,
      lng: 81.0107,
      address: 'Gomti Nagar Extension, Lucknow',
      rating: 4.5,
      primaryType: 'park',
      types: const <String>['park'],
    ),
  ];

  AppContainer get _c => AppScope.of(context);

  final osm.MapController _mapController = osm.MapController();
  final TextEditingController _searchController = TextEditingController();
  Timer? _searchDebounce;
  StreamSubscription<List<SafetyZone>>? _zonesSub;

  bool _ready = false;
  bool _satellite = AppConfig.mapTilerKey.isNotEmpty;
  bool _searching = false;
  bool _permissionDenied = false;
  String? _message;
  Position? _position;
  Place? _selected;
  RouteInfo? _route;
  List<Place> _places = List<Place>.of(_demoPlaces);
  List<SafetyZone> _zones = const <SafetyZone>[];
  ll.LatLng _initialCenter = _lucknow;
  double _initialZoom = 12.5;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
    if (_c.firebaseReady) {
      _zonesSub = _c.zonesRepository.watchAll().listen(
        (List<SafetyZone> zones) {
          if (mounted) setState(() => _zones = zones);
        },
        onError: (Object _) {},
      );
    }
    _prepareMap();
  }

  Future<void> _prepareMap() async {
    final double? lat = widget.initialLat;
    final double? lng = widget.initialLng;
    if (lat != null && lng != null) {
      _initialCenter = ll.LatLng(lat, lng);
      _initialZoom = 15;
      _selected = Place(
        placeId: 'initial-destination',
        name: widget.initialName ?? 'Destination',
        lat: lat,
        lng: lng,
      );
    }
    try {
      final LocationPermission permission =
          await _c.locationService.ensurePermission();
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        _permissionDenied = true;
      } else {
        final Position? position =
            await _c.locationService.currentPosition();
        if (position != null) {
          _position = position;
          if (lat == null || lng == null) {
            _initialCenter = ll.LatLng(position.latitude, position.longitude);
            _initialZoom = 14;
          }
        }
      }
    } catch (_) {
      // Lucknow remains a useful default when GPS is unavailable.
    }
    if (mounted) setState(() => _ready = true);
  }

  void _onSearchChanged() {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 500), _search);
  }

  Future<void> _search() async {
    final String query = _searchController.text.trim();
    if (query.isEmpty) {
      setState(() {
        _places = List<Place>.of(_demoPlaces);
        _message = null;
      });
      return;
    }

    final String lower = query.toLowerCase();
    final List<Place> local = _demoPlaces
        .where((Place place) =>
            place.name.toLowerCase().contains(lower) ||
            (place.address?.toLowerCase().contains(lower) ?? false) ||
            place.types.any((String type) => type.contains(lower)))
        .toList();

    setState(() {
      _searching = true;
      _message = null;
    });

    if (_c.backendConfigured) {
      try {
        final Position? p = _position;
        final List<Place> live = await _c.placesRepository.search(
          query,
          location: p == null
              ? google.LatLng(_lucknow.latitude, _lucknow.longitude)
              : google.LatLng(p.latitude, p.longitude),
          radiusMeters: 15000,
        );
        if (!mounted) return;
        setState(() {
          _places = live.isEmpty ? local : live;
          _searching = false;
          _message = live.isEmpty ? 'No live result; showing demo matches.' : null;
        });
        return;
      } catch (_) {
        // Gracefully keep the key-free demo useful if Places isn't configured.
      }
    }

    if (!mounted) return;
    setState(() {
      _places = local;
      _searching = false;
      _message = local.isEmpty
          ? 'No demo place matched. Deploy the Places backend for live search.'
          : 'Showing built-in Lucknow demo places.';
    });
  }

  void _showCategory(String type) {
    _searchController.clear();
    setState(() {
      _places = _demoPlaces
          .where((Place place) => place.types.contains(type))
          .toList();
      _message = 'Demo category · live search is available from the search box.';
    });
  }

  void _select(Place place) {
    setState(() {
      _selected = place;
      _route = null;
    });
    _mapController.move(ll.LatLng(place.lat, place.lng), 15);
  }

  Future<void> _routeToSelected() async {
    final Place? destination = _selected;
    if (destination == null) return;
    final Position? current = _position;
    if (current == null) {
      setState(() {
        _route = RouteInfo(
          distanceMeters: 0,
          durationSeconds: 0,
          polyline: <google.LatLng>[
            google.LatLng(_lucknow.latitude, _lucknow.longitude),
            destination.coords,
          ],
          provider: 'fallback',
        );
      });
      return;
    }

    try {
      final RouteInfo route = await _c.placesRepository.route(
        google.LatLng(current.latitude, current.longitude),
        destination.coords,
      );
      if (mounted) setState(() => _route = route);
    } catch (_) {
      final google.LatLng from =
          google.LatLng(current.latitude, current.longitude);
      final double distance =
          GeoUtils.distanceMeters(from, destination.coords);
      if (mounted) {
        setState(() {
          _route = RouteInfo(
            distanceMeters: distance,
            durationSeconds: distance / 1.3,
            polyline: <google.LatLng>[from, destination.coords],
            provider: 'fallback',
          );
        });
      }
    }
  }

  Future<void> _recenter() async {
    final Position? p = _position;
    _mapController.move(
      p == null ? _lucknow : ll.LatLng(p.latitude, p.longitude),
      p == null ? 12.5 : 15,
    );
  }

  List<osm.Marker> _markers() {
    final List<osm.Marker> markers = _places
        .map(
          (Place place) => osm.Marker(
            point: ll.LatLng(place.lat, place.lng),
            width: 46,
            height: 52,
            child: GestureDetector(
              onTap: () => _select(place),
              child: Tooltip(
                message: place.name,
                child: Icon(
                  place.types.contains('park') ? Icons.park : Icons.location_on,
                  size: 42,
                  color: _selected?.placeId == place.placeId
                      ? Colors.deepOrange
                      : const Color(0xFF0E7C7B),
                ),
              ),
            ),
          ),
        )
        .toList();
    final Position? p = _position;
    if (p != null) {
      markers.add(
        osm.Marker(
          point: ll.LatLng(p.latitude, p.longitude),
          width: 28,
          height: 28,
          child: Container(
            decoration: BoxDecoration(
              color: Colors.blue,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 3),
              boxShadow: const <BoxShadow>[
                BoxShadow(color: Colors.black26, blurRadius: 5),
              ],
            ),
          ),
        ),
      );
    }
    return markers;
  }

  List<osm.CircleMarker> _zoneCircles() => _zones
      .where((SafetyZone zone) => zone.active)
      .map((SafetyZone zone) {
        final Color color = RiskBadge.colorFor(context, zone.riskLevel);
        return osm.CircleMarker(
          point: ll.LatLng(zone.lat, zone.lng),
          radius: zone.radiusMeters,
          useRadiusInMeter: true,
          color: color.withOpacity(0.18),
          borderColor: color,
          borderStrokeWidth: 2,
        );
      })
      .toList();

  List<osm.Polyline> _routeLines() {
    final RouteInfo? route = _route;
    if (route == null || route.polyline.length < 2) return const <osm.Polyline>[];
    return <osm.Polyline>[
      osm.Polyline(
        points: route.polyline
            .map((google.LatLng p) => ll.LatLng(p.latitude, p.longitude))
            .toList(),
        strokeWidth: 5,
        color: Theme.of(context).colorScheme.primary,
      ),
    ];
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    _zonesSub?.cancel();
    _mapController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return const Scaffold(body: LoadingView(message: 'Preparing map…'));
    }
    return Scaffold(
      body: Stack(
        children: <Widget>[
          osm.FlutterMap(
            mapController: _mapController,
            options: osm.MapOptions(
              initialCenter: _initialCenter,
              initialZoom: _initialZoom,
              minZoom: 3,
              maxZoom: 19,
              onTap: (_, __) => setState(() => _selected = null),
            ),
            children: <Widget>[
              osm.TileLayer(
                urlTemplate: _satellite
                    ? 'https://api.maptiler.com/maps/satellite/{z}/{x}/{y}.jpg?key=${AppConfig.mapTilerKey}'
                    : 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'app.roamio.tourism',
                maxNativeZoom: _satellite ? 20 : 19,
              ),
              osm.CircleLayer(circles: _zoneCircles()),
              osm.PolylineLayer(polylines: _routeLines()),
              osm.MarkerLayer(markers: _markers()),
              osm.RichAttributionWidget(
                attributions: <osm.SourceAttribution>[
                  if (_satellite)
                    osm.TextSourceAttribution(
                      'MapTiler',
                      onTap: () => launchUrl(
                        Uri.parse('https://www.maptiler.com/copyright/'),
                        mode: LaunchMode.externalApplication,
                      ),
                    ),
                  osm.TextSourceAttribution(
                    'OpenStreetMap contributors',
                    onTap: () => launchUrl(
                      Uri.parse('https://www.openstreetmap.org/copyright'),
                      mode: LaunchMode.externalApplication,
                    ),
                  ),
                ],
              ),
            ],
          ),
          _searchPanel(),
          if (_permissionDenied) _locationBanner(),
          if (_selected != null) _placeCard(_selected!),
          if (AppConfig.mapTilerKey.isNotEmpty)
            Positioned(
              right: 16,
              top: MediaQuery.paddingOf(context).top + 118,
              child: FloatingActionButton.small(
                heroTag: 'map-layer',
                tooltip: _satellite ? 'Use street map' : 'Use satellite map',
                onPressed: () => setState(() => _satellite = !_satellite),
                child:
                    Icon(_satellite ? Icons.map_outlined : Icons.satellite_alt),
              ),
            ),
          Positioned(
            right: 16,
            bottom: _selected == null ? 32 : 220,
            child: FloatingActionButton.small(
              tooltip: _position == null ? 'Show Lucknow' : 'My location',
              onPressed: _recenter,
              child: const Icon(Icons.my_location),
            ),
          ),
        ],
      ),
    );
  }

  Widget _searchPanel() {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Material(
              elevation: 4,
              borderRadius: BorderRadius.circular(16),
              color: scheme.surface,
              child: TextField(
                controller: _searchController,
                decoration: InputDecoration(
                  hintText: 'Search a place…',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _searching
                      ? const Padding(
                          padding: EdgeInsets.all(14),
                          child: SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      : null,
                  border: InputBorder.none,
                ),
                onSubmitted: (_) => _search(),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 36,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: <Widget>[
                  ActionChip(
                    avatar: const Icon(Icons.attractions, size: 18),
                    label: const Text('Attractions'),
                    onPressed: () => _showCategory('tourist_attraction'),
                  ),
                  const SizedBox(width: 8),
                  ActionChip(
                    avatar: const Icon(Icons.park, size: 18),
                    label: const Text('Parks'),
                    onPressed: () => _showCategory('park'),
                  ),
                  const SizedBox(width: 8),
                  ActionChip(
                    avatar: const Icon(Icons.refresh, size: 18),
                    label: const Text('All demo places'),
                    onPressed: () {
                      _searchController.clear();
                      setState(() => _places = List<Place>.of(_demoPlaces));
                    },
                  ),
                ],
              ),
            ),
            if (_message != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Material(
                  color: scheme.surface.withOpacity(0.92),
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(_message!, style: themeTextSmall(context)),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _locationBanner() => Positioned(
        top: 154,
        left: 12,
        right: 12,
        child: Material(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(12),
          elevation: 3,
          child: const Padding(
            padding: EdgeInsets.all(10),
            child: Text(
              'Location permission is off — showing the Lucknow demo map.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );

  Widget _placeCard(Place place) {
    final Position? current = _position;
    final double? distance = current == null
        ? null
        : GeoUtils.distanceMeters(
            google.LatLng(current.latitude, current.longitude),
            place.coords,
          );
    return Positioned(
      left: 12,
      right: 12,
      bottom: 16,
      child: Card(
        elevation: 8,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      place.name,
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontWeight: FontWeight.w800),
                    ),
                  ),
                  IconButton(
                    onPressed: () => setState(() => _selected = null),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              if (place.address != null) Text(place.address!),
              if (distance != null)
                Text('Distance: ${GeoUtils.formatDistance(distance)}'),
              if (_route != null)
                Text(
                  _route!.isApproximate
                      ? 'Approximate straight-line route'
                      : 'Live traffic-aware road route',
                  style: themeTextSmall(context),
                ),
              const SizedBox(height: 12),
              Row(
                children: <Widget>[
                  Expanded(
                    child: PrimaryButton(
                      label: 'Show route',
                      icon: Icons.route,
                      onPressed: _routeToSelected,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: PrimaryButton(
                      label: 'Navigate',
                      icon: Icons.navigation,
                      outlined: true,
                      onPressed: () => _c.placesRepository.openInGoogleMaps(
                        place.lat,
                        place.lng,
                        place.name,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

TextStyle? themeTextSmall(BuildContext context) =>
    Theme.of(context).textTheme.bodySmall;
