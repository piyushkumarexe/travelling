import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../../core/network/api_exception.dart';
import '../../../core/state/app_container.dart';
import '../../../core/utils/geo.dart';
import '../../../core/widgets/place_card.dart';
import '../../../core/widgets/state_views.dart';
import '../../../data/local/nearby_store.dart';
import '../../../data/models/places.dart';

/// Nearby essentials: on-demand nearby-POI search around the user's real GPS
/// location, with OpenStreetMap Overpass as the primary bulk engine and a
/// strict 10,000 m radius. Categories: Hospital, Police, Pharmacy, ATM, Fuel,
/// Food, Hotel, Transit, Attractions, Museums, Parks and Shopping — each with
/// its proper OSM tag mapping. Results are parsed, deduplicated, filtered to
/// the radius and sorted nearest-first; every result opens for details and
/// OSRM-based directions.
class EssentialsScreen extends StatefulWidget {
  const EssentialsScreen({super.key});

  @override
  State<EssentialsScreen> createState() => _EssentialsScreenState();
}

class _Category {
  const _Category(this.label, this.icon, this.categories);
  final String label;
  final IconData icon;

  /// Dataset categories to filter the combined nearby dataset by. Fetching
  /// happens ONCE per location bucket; switching chips filters locally.
  final List<String> categories;
}

class _EssentialsScreenState extends State<EssentialsScreen> {
  AppContainer get _c => AppScope.of(context);

  static const List<_Category> _categories = <_Category>[
    _Category('Hospital', Icons.local_hospital, <String>['hospital']),
    _Category('Police', Icons.local_police, <String>['police']),
    _Category('Pharmacy', Icons.local_pharmacy, <String>['pharmacy']),
    _Category('ATM', Icons.local_atm, <String>['atm']),
    _Category('Fuel', Icons.local_gas_station, <String>['fuel']),
    _Category('Food', Icons.restaurant,
        <String>['food', 'restaurant', 'cafe', 'fast_food']),
    _Category('Hotel', Icons.hotel, <String>['hotel']),
    _Category('Transit', Icons.directions_bus, <String>['transit']),
    _Category('Attractions', Icons.attractions, <String>['attraction']),
    _Category('Museums', Icons.museum, <String>['museum']),
    _Category('Parks', Icons.park, <String>['park']),
    _Category('Shopping', Icons.shopping_bag, <String>['shopping']),
  ];

  Position? _position;
  bool _locationDone = false;
  _Category? _selected;
  List<Place> _results = const <Place>[];
  bool _loading = false;
  String? _error;
  bool _stale = false;

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
      if (mounted) {
        setState(() {
          _position = null;
          _locationDone = true;
        });
      }
    }
  }

  /// User-initiated retry: re-request permission (opening settings if it was
  /// denied/permanently denied) and re-obtain the fix. Never fabricates a
  /// coordinate — [currentPosition] returns null when nothing is available.
  Future<void> _retryLocation() async {
    try {
      final LocationPermission perm =
          await _c.locationService.ensurePermission();
      if (!mounted) return;
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        setState(() {
          _position = null;
          _locationDone = true;
        });
        return;
      }
    } catch (_) {}
    try {
      final Position? pos = await _c.locationService.currentPosition();
      if (!mounted) return;
      setState(() {
        _position = pos;
        _locationDone = true;
      });
    } catch (_) {
      if (mounted) setState(() => _position = null);
    }
  }

  Future<void> _search(_Category c) async {
    final Position? pos = _position;
    if (pos == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Enable location services to search nearby.')),
      );
      return;
    }
    setState(() {
      _selected = c;
      _loading = true;
      _error = null;
      _stale = false;
      _results = const <Place>[];
    });
    try {
      final NearbyResult dataset = await _loadDataset(c);
      if (!mounted) return;
      final List<Place> filtered = dataset.places
          .where((Place p) => _matches(p, c.categories))
          .toList()
        ..sort((Place a, Place b) => (a.distanceMeters ?? double.infinity)
            .compareTo(b.distanceMeters ?? double.infinity));
      setState(() {
        _results = filtered;
        _loading = false;
        _stale = dataset.stale;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = _friendlyError(e);
        _loading = false;
      });
    }
  }

  Future<NearbyResult> _loadDataset(_Category c) {
    final Position pos = _position!;
    final LatLng here = LatLng(pos.latitude, pos.longitude);
    if (c.label == 'Shopping') {
      return _c.placesRepository.nearbyShopping(here);
    }
    return _c.placesRepository.nearbyAround(here);
  }

  /// Explicit Refresh: bypass the cache and force a fresh Overpass fetch.
  Future<void> _refresh() async {
    final _Category? c = _selected;
    if (c == null) return;
    final Position? pos = _position;
    if (pos == null) return;
    setState(() {
      _loading = true;
      _error = null;
      _stale = false;
    });
    try {
      final LatLng here = LatLng(pos.latitude, pos.longitude);
      final NearbyResult dataset = c.label == 'Shopping'
          ? await _c.placesRepository.nearbyShopping(here, force: true)
          : await _c.placesRepository.nearbyAround(here, force: true);
      if (!mounted) return;
      final List<Place> filtered = dataset.places
          .where((Place p) => _matches(p, c.categories))
          .toList()
        ..sort((Place a, Place b) => (a.distanceMeters ?? double.infinity)
            .compareTo(b.distanceMeters ?? double.infinity));
      setState(() {
        _results = filtered;
        _loading = false;
        _stale = dataset.stale;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = _friendlyError(e);
        _loading = false;
      });
    }
  }

  bool _matches(Place p, List<String> categories) {
    return categories
        .any((String c) => p.category == c || p.types.contains(c));
  }

  String _friendlyError(Object e) {
    if (e is ApiException) {
      return switch (e.kind) {
        ApiErrorKind.network ||
        ApiErrorKind.timeout =>
          "You're offline. Check your connection and retry.",
        ApiErrorKind.rateLimited =>
          'Nearby places are temporarily unavailable. Try again shortly.',
        ApiErrorKind.server ||
        ApiErrorKind.upstream ||
        ApiErrorKind.parser =>
          'The nearby places service is unavailable right now. Please retry.',
        ApiErrorKind.unauthorized =>
          'The map/place service key was rejected. Please check the key and rebuild the app.',
        ApiErrorKind.location =>
          'Your location is currently unavailable.',
        _ => e.message,
      };
    }
    return 'Could not load nearby places. Please try again.';
  }

  String _distance(Place p) {
    if (p.distanceMeters != null) {
      return GeoUtils.formatDistance(p.distanceMeters!);
    }
    final Position? pos = _position;
    if (pos == null) return '';
    return GeoUtils.formatDistance(
      GeoUtils.distanceMeters(
        LatLng(pos.latitude, pos.longitude),
        p.coords,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Nearby essentials'),
        actions: <Widget>[
          if (_selected != null && _position != null)
            IconButton(
              tooltip: 'Refresh nearby results',
              icon: const Icon(Icons.refresh),
              onPressed: _loading ? null : () => _refresh(),
            ),
        ],
      ),
      body: !_locationDone
          ? const LoadingView(message: 'Finding your location…')
          : Column(
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: <Widget>[
                      for (final _Category c in _categories)
                        ChoiceChip(
                          avatar: Icon(c.icon, size: 16),
                          label: Text(c.label),
                          selected: _selected?.label == c.label,
                          onSelected: (_) => _search(c),
                        ),
                    ],
                  ),
                ),
                Expanded(child: _body()),
              ],
            ),
    );
  }

  Widget _body() {
    if (_selected == null) {
      // Distinguish "no location" from the plain empty prompt (requirement:
      // no-location / network / API-failure / zero-results must not blur).
      if (_position == null) {
        return ErrorState(
          message:
              "Your location isn't available yet. Turn on location services "
              'and allow location permission, then try again.',
          retryLabel: 'Enable location',
          onRetry: _retryLocation,
        );
      }
      return const EmptyState(
        icon: Icons.location_searching,
        title: 'What do you need nearby?',
        message:
            'Pick a category to search real places around your location. '
            'Results show distance, and each place opens for directions.',
      );
    }
    if (_loading) {
      return const LoadingView(message: 'Searching nearby…');
    }
    if (_error != null) {
      return ErrorState(
        message: _error!,
        onRetry: () => _search(_selected!),
      );
    }
    if (_results.isEmpty) {
      return EmptyState(
        icon: Icons.search_off,
        title: 'No nearby places found within 10 km.',
        message:
            'No ${_selected!.label.toLowerCase()} is mapped within 10 km of '
            'your location. Try another category or a larger town.',
        actionLabel: 'Retry',
        onAction: () => _refresh(),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      itemCount: _results.length + (_stale ? 1 : 0),
      itemBuilder: (BuildContext context, int i) {
        if (_stale && i == 0) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFFFFF3E0),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Row(
                children: <Widget>[
                  Icon(Icons.cloud_off, size: 16, color: Color(0xFFB26A00)),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Offline — showing saved nearby places.',
                      style: TextStyle(
                          fontSize: 12.5, color: Color(0xFFB26A00)),
                    ),
                  ),
                ],
              ),
            ),
          );
        }
        final Place p = _results[_stale ? i - 1 : i];
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: PlaceCard(
            place: p,
            distance: _distance(p),
            onTap: () => context.push('/explore/place/${p.placeId}', extra: p),
          ),
        );
      },
    );
  }
}
