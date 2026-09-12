import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../../core/state/app_container.dart';
import '../../../core/utils/geo.dart';
import '../../../core/widgets/place_card.dart';
import '../../../core/widgets/state_views.dart';
import '../../../data/models/places.dart';

/// Nearby essentials: real, on-demand search for hospitals, police,
/// pharmacies, ATMs, fuel, food, hotels, transit and attractions around the
/// user's current location. Every result can be opened for details and
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
    _Category('Food', Icons.restaurant, 'restaurant', <String>['restaurant']),
    _Category('Hotel', Icons.hotel, 'hotel', <String>['hotel']),
    _Category('Transit', Icons.directions_bus, 'bus station', null),
    _Category('Attractions', Icons.attractions, 'attractions',
        <String>['tourist_attraction']),
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
      if (mounted) setState(() => _locationDone = true);
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
        radiusMeters: 8000,
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
        title: 'Nothing found',
        message:
            'No ${_selected!.label.toLowerCase()} results near you. '
            'Try a different category or a wider area.',
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
