import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../../core/state/app_container.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/geo.dart';
import '../../../core/utils/hotel_estimates.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/app_skeleton.dart';
import '../../../core/widgets/place_card.dart';
import '../../../core/widgets/state_views.dart';
import '../../../data/models/places.dart';
import '../../../data/repositories/places_repository.dart'
    show kExploreCategories, kExploreCategoryLabels, kHiddenGemsQueries;

/// Explore: real Google Places search (attractions, hidden gems, food,
/// nearby) with distance from current location and map actions.
class ExploreScreen extends StatefulWidget {
  const ExploreScreen({super.key});

  @override
  State<ExploreScreen> createState() => _ExploreScreenState();
}

class _ExploreScreenState extends State<ExploreScreen> {
  AppContainer get _c => AppScope.of(context);

  final TextEditingController _queryController = TextEditingController();
  String _query = '';
  String? _activeCategory;
  String _scope = 'nearby'; // nearby | anywhere | hidden

  Position? _position;
  bool _locationDone = false;

  List<Place> _results = const <Place>[];
  bool _loading = false;
  String? _error;
  bool _searchedOnce = false;

  Timer? _debounce;
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    _queryController.addListener(_onQueryChanged);
  }

  Future<void> _initLocation() async {
    // Search first with whatever (cached) location we already have, so the
    // screen never sits on a spinner waiting for a cold GPS fix. A fresh fix
    // then re-runs the nearby search in the background.
    if (!_searchedOnce) _runDefaultSearch();
    try {
      final Position? pos = await _c.locationService.currentPosition();
      if (!mounted) return;
      final bool hadLocation = _position != null;
      setState(() {
        _position = pos;
        _locationDone = true;
      });
      // A real fix just landed after the first search ran without one.
      if (!hadLocation && pos != null) unawaited(_runSearch());
    } catch (_) {
      if (mounted) setState(() => _locationDone = true);
      if (!_searchedOnce) _runDefaultSearch();
    }
  }

  /// Prompts for location permission (and re-runs the search) — used when the
  /// user lands on Explore with location unavailable.
  Future<void> _enableLocation() async {
    final LocationPermission p = await _c.locationService.ensurePermission();
    if (p == LocationPermission.denied ||
        p == LocationPermission.deniedForever) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text(
                  'Location permission is needed to show places near you.')),
        );
      }
      return;
    }
    await _initLocation();
  }

  void _onQueryChanged() {
    final String q = _queryController.text.trim();
    if (q != _query) {
      setState(() => _query = q);
    }
    _debounce?.cancel();
    if (q.isEmpty) return;
    _debounce = Timer(const Duration(milliseconds: 550), () => _runSearch());
  }

  void _setScope(String scope) {
    _debounce?.cancel();
    setState(() {
      _scope = scope;
      _activeCategory = null;
    });
    if (scope == 'hidden') {
      _queryController.text = kHiddenGemsQueries.first;
    }
    _runSearch();
  }

  void _setCategory(String? category) {
    _debounce?.cancel();
    setState(() => _activeCategory = category);
    _runSearch();
  }

  String _effectiveQuery() {
    if (_query.isNotEmpty) return _query;
    if (_activeCategory != null) return _activeCategory!;
    return 'tourist attractions near me';
  }

  /// Google Places type ids for a category, so both the backend and the free
  /// fallback (Overpass) return the right kind of place (hotels, museums…).
  List<String>? _categoryTypes(String? category) => switch (category) {
        'tourist_attraction' => const <String>['tourist_attraction'],
        'restaurant' => const <String>['restaurant'],
        'cafe' => const <String>['cafe'],
        'park' => const <String>['park'],
        'museum' => const <String>['museum'],
        'hotel' => const <String>['hotel'],
        'shopping_mall' => const <String>['shopping_mall'],
        _ => null,
      };

  void _runDefaultSearch() {
    _searchedOnce = true;
    _runSearch();
  }

  Future<void> _runSearch() async {
    final String q = _effectiveQuery();
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    // Special "5★ hotels" mode: real OSM hotel data + on-device price estimate.
    if (_activeCategory == 'luxury_hotels') {
      try {
        final Position? pos = _position;
        if (pos == null) {
          setState(() {
            _loading = false;
            _error = 'Enable location to find 5★ hotels near you.';
          });
          return;
        }
        final List<Place> hotels = await _c.placesRepository.luxuryHotels(
          LatLng(pos.latitude, pos.longitude),
        );
        if (!mounted) return;
        setState(() {
          _results = hotels;
          _loading = false;
          _searchedOnce = true;
        });
        return;
      } catch (e) {
        if (!mounted) return;
        setState(() {
          _error = e.toString();
          _loading = false;
          _searchedOnce = true;
        });
        return;
      }
    }
    try {
      final List<Place> places = await _c.placesRepository.search(
        q,
        location: _position == null
            ? null
            : LatLng(_position!.latitude, _position!.longitude),
        radiusMeters: _scope == 'nearby' ? 8000.0 : null,
        types: _categoryTypes(_activeCategory),
      );
      if (!mounted) return;
      setState(() {
        _results = places;
        _loading = false;
        _searchedOnce = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
        _searchedOnce = true;
      });
    }
  }

  String? _distanceFor(Place place) {
    final Position? pos = _position;
    if (pos == null) return null;
    final double d = GeoUtils.distanceMeters(
      LatLng(pos.latitude, pos.longitude),
      place.coords,
    );
    return GeoUtils.formatDistance(d);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _queryController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_initialized) {
      _initialized = true;
      _initLocation();
    }
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Explore')),
      body: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: _queryController,
                    decoration: InputDecoration(
                      hintText: 'Search destinations, places, food…',
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: _query.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.clear),
                              onPressed: () {
                                _queryController.clear();
                                _debounce?.cancel();
                                setState(() => _query = '');
                              },
                            ),
                    ),
                    onSubmitted: (String _) => _runSearch(),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: <Widget>[
                _scopeChip('Nearby', _scope == 'nearby', () => _setScope('nearby')),
                const SizedBox(width: 8),
                _scopeChip('Anywhere', _scope == 'anywhere', () => _setScope('anywhere')),
                const SizedBox(width: 8),
                _scopeChip('Hidden gems', _scope == 'hidden', () => _setScope('hidden')),
                const SizedBox(width: 16),
                ChoiceChip(
                  label: const Text('⭐ 5★ Hotels'),
                  selected: _activeCategory == 'luxury_hotels',
                  onSelected: (bool _) => _setCategory(
                      _activeCategory == 'luxury_hotels' ? null : 'luxury_hotels'),
                ),
                const SizedBox(width: 8),
                for (final String cat in kExploreCategories) ...<Widget>[
                  ChoiceChip(
                    label: Text(kExploreCategoryLabels[cat] ?? cat),
                    selected: _activeCategory == cat,
                    onSelected: (bool _) =>
                        _setCategory(_activeCategory == cat ? null : cat),
                  ),
                  const SizedBox(width: 8),
                ],
              ],
            ),
          ),
          Expanded(
            child: _buildResults(scheme),
          ),
        ],
      ),
    );
  }

  Widget _scopeChip(String label, bool selected, VoidCallback onTap) {
    return FilterChip(
      label: Text(label),
      selected: selected,
      onSelected: (bool _) => onTap(),
    );
  }

  Widget _buildResults(ColorScheme scheme) {
    if (_loading && _results.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: SkeletonList(count: 5, height: 110),
      );
    }
    if (_error != null && _results.isEmpty) {
      return ErrorState(message: _error!, onRetry: _runSearch);
    }
    if (!_searchedOnce && !_locationDone) {
      return const LoadingView(message: 'Finding your location…');
    }
    if (_locationDone && _position == null && _scope == 'nearby') {
      return EmptyState(
        icon: Icons.location_off,
        title: 'Location not available',
        message:
            'Enable location to see attractions, food and hotels near you.',
        actionLabel: 'Enable location',
        onAction: _enableLocation,
      );
    }
    if (_results.isEmpty) {
      return EmptyState(
        icon: Icons.search,
        title: 'No places found',
        message: 'Try a different search, or pick a category above.',
        actionLabel: 'Search attractions',
        onAction: () {
          _queryController.text = 'tourist attractions';
          _runSearch();
        },
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      itemCount: _results.length,
      separatorBuilder: (BuildContext context, int i) =>
          const SizedBox(height: 10),
      itemBuilder: (BuildContext context, int i) {
        final Place p = _results[i];
        if (_activeCategory == 'luxury_hotels') {
          return _LuxuryHotelCard(
            place: p,
            distance: _distanceFor(p),
            onTap: () => context.push('/explore/place/${p.placeId}', extra: p),
          );
        }
        return PlaceCard(
          place: p,
          distance: _distanceFor(p),
          onTap: () => context.push('/explore/place/${p.placeId}', extra: p),
        );
      },
    );
  }
}

/// Hotel card with star rating + estimated nightly price range.
class _LuxuryHotelCard extends StatelessWidget {
  const _LuxuryHotelCard({
    required this.place,
    required this.onTap,
    this.distance,
  });

  final Place place;
  final VoidCallback onTap;
  final String? distance;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final int stars = (place.rating ?? 0).round();
    return AppCard(
      onTap: onTap,
      padding: const EdgeInsets.all(14),
      child: Row(
        children: <Widget>[
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: AppTheme.warning.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Icon(Icons.hotel, color: AppTheme.warning),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  place.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context)
                      .textTheme
                      .titleSmall
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Row(
                  children: <Widget>[
                    Text(
                      '${'★' * stars}${'☆' * (5 - stars)}',
                      style: const TextStyle(
                          color: AppTheme.warning, fontSize: 14),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '$stars-star',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  HotelEstimates.rangeLabel(stars),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.primary,
                        fontWeight: FontWeight.w700,
                      ),
                ),
              ],
            ),
          ),
          if (distance != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: scheme.primaryContainer.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                distance!,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
