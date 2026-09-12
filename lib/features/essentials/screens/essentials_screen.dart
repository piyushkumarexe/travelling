import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../../core/state/app_container.dart';
import '../../../core/utils/geo.dart';
import '../../../core/widgets/place_card.dart';
import '../../../core/widgets/state_views.dart';
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
  const _Category(this.label, this.icon, this.query, this.types);
  final String label;
  final IconData icon;
  final String query;
  final List<String>? types;
}

class _EssentialsScreenState extends State<EssentialsScreen> {
  AppContainer get _c => AppScope.of(context);

  static const List<_Category> _categories = <_Category>[
    _Category('Hospital', Icons.local_hospital, 'hospital', <String>['hospital']),
    _Category('Police', Icons.local_police, 'police', <String>['police']),
    _Category('Pharmacy', Icons.local_pharmacy, 'pharmacy', <String>['pharmacy']),
    _Category('ATM', Icons.local_atm, 'atm', <String>['atm']),
    _Category('Fuel', Icons.local_gas_station, 'fuel', <String>['fuel']),
    _Category('Food', Icons.restaurant, 'food', <String>['food']),
    _Category('Hotel', Icons.hotel, 'hotel', <String>['hotel']),
    _Category('Transit', Icons.directions_bus, 'transit', <String>['transit']),
    _Category('Attractions', Icons.attractions, 'attractions',
        <String>['tourist_attraction']),
    _Category('Museums', Icons.museum, 'museums', <String>['museum']),
    _Category('Parks', Icons.park, 'parks', <String>['park']),
    _Category('Shopping', Icons.shopping_bag, 'shopping', <String>['shopping']),
  ];

  Position? _position;
  bool _locationDone = false;
  _Category? _selected;
  List<Place> _results = const <Place>[];
  bool _loading = false;
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
      _results = const <Place>[];
    });
    try {
      final List<Place> places = await _c.placesRepository.search(
        c.query,
        location: LatLng(pos.latitude, pos.longitude),
        radiusMeters: 10000,
        types: c.types,
      );
      if (!mounted) return;
      setState(() {
        _results = places;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  String _distance(Place p) {
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
      appBar: AppBar(title: const Text('Nearby essentials')),
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
      final String label = _selected!.label.toLowerCase();
      return EmptyState(
        icon: Icons.search_off,
        title: 'No $label found nearby',
        message:
            'No $label results within 10 km. Try a different category or '
            'move to a larger town.',
        actionLabel: 'Retry',
        onAction: () => _search(_selected!),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      itemCount: _results.length,
      itemBuilder: (BuildContext context, int i) {
        final Place p = _results[i];
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
