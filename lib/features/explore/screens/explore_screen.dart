import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../../core/network/nearby_debug.dart';
import '../../../core/services/favorites_store.dart';
import '../../../core/state/app_container.dart';
import '../../../core/utils/geo.dart';
import '../../../core/widgets/app_skeleton.dart';
import '../../../core/widgets/place_card.dart';
import '../../../core/widgets/state_views.dart';
import '../../../data/local/nearby_store.dart';
import '../../../data/models/places.dart';
import '../../../data/repositories/places_repository.dart'
    show kExploreCategories, kExploreCategoryLabels, placesErrorMessage;

/// Explore: real nearby search over OpenStreetMap/Overpass + MapTiler +
/// Wikipedia (attractions, hidden gems, food, nearby) with distance from the
/// device's current GPS location and map actions.
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
  bool _locationDenied = false;

  List<Place> _results = const <Place>[];
  bool _loading = false;
  String? _error;
  bool _searchedOnce = false;

  /// Pagination: show the first 20 nearest results, then a "Load more" button
  /// — never an arbitrary tiny cap, and never hundreds of cards at once.
  int _shown = 20;

  Timer? _debounce;
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    _queryController.addListener(_onQueryChanged);
  }

  Future<void> _initLocation() async {
    // 1) Use the instant cached/last-known fix so the first search is already
    //    a real "nearby" search (no flicker, no global fallback noise).
    try {
      final Position? cached = await _c.locationService.lastKnown();
      if (mounted && cached != null) {
        setState(() {
          _position = cached;
          _locationDone = true;
        });
      }
    } catch (_) {}
    // 2) Record the permission state up-front so the UI can distinguish
    //    "permission denied" from "GPS unavailable".
    try {
      final LocationPermission perm =
          await _c.locationService.checkPermission();
      if (mounted) {
        setState(() {
          _locationDenied = perm == LocationPermission.denied ||
              perm == LocationPermission.deniedForever;
        });
      }
    } catch (_) {}
    // 3) Never run a "nearby" search without a real location — a global
    //    search would return unrelated far-away results.
    if (_position != null && !_searchedOnce) {
      unawaited(_runNearbyDefault());
    }
    // 4) Refresh the fix (prompting for permission if needed); re-run nearby
    //    only when we had no location at all, so a successful search is never
    //    wiped out.
    try {
      final Position? pos = await _c.locationService.currentPosition();
      if (!mounted || pos == null) return;
      final bool hadLocation = _position != null;
      setState(() {
        _position = pos;
        _locationDone = true;
        _locationDenied = false;
      });
      if (!hadLocation) unawaited(_runNearbyDefault());
    } catch (_) {
      // The fix failed — re-check the permission so the UI distinguishes
      // "permission denied" from "GPS unavailable" instead of guessing.
      if (mounted) unawaited(_refreshLocationState());
    }
  }

  /// Re-reads the permission and marks location resolution done, so the body
  /// can show the right state (permission vs GPS) after a failed fix.
  Future<void> _refreshLocationState() async {
    try {
      final LocationPermission perm =
          await _c.locationService.checkPermission();
      if (!mounted) return;
      setState(() {
        _locationDenied = perm == LocationPermission.denied ||
            perm == LocationPermission.deniedForever;
        _locationDone = true;
      });
    } catch (_) {
      if (mounted) setState(() => _locationDone = true);
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
    _debounce = Timer(const Duration(milliseconds: 450), () {
      // A typed search is a brand-new query — clear stale results so the UI
      // never keeps showing a previous category's list.
      if (_results.isNotEmpty) setState(() => _results = const <Place>[]);
      _runSuggestions(q);
    });
  }

  /// Autocomplete suggestions while typing (MapTiler Geocoding — permitted;
  /// never public Nominatim). Shows real matching places as the user types.
  Future<void> _runSuggestions(String q) async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
      _shown = 20;
    });
    try {
      final Position? pos = _position;
      final List<Place> places = await _c.placesRepository.suggest(
        q,
        location: pos == null
            ? null
            : LatLng(pos.latitude, pos.longitude),
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
        _error = placesErrorMessage(e);
        _loading = false;
        _searchedOnce = true;
      });
    }
  }

  void _setScope(String scope) {
    _debounce?.cancel();
    setState(() {
      _scope = scope;
      _activeCategory = null;
      _results = const <Place>[];
      _error = null;
      _shown = 20;
    });
    if (scope == 'saved') {
      unawaited(_loadSaved());
      return;
    }
    if (scope == 'nearby') {
      // "Nearby" is the cached, grouped, fast path — never the slow free-text
      // multi-provider search.
      _runNearbyDefault();
    } else {
      _runSearch();
    }
  }

  Future<void> _loadSaved() async {
    setState(() {
      _loading = true;
      _shown = 20;
    });
    try {
      final List<Place> saved = await FavoritesStore.all();
      if (!mounted) return;
      setState(() {
        _results = saved;
        _loading = false;
        _error = null;
        _searchedOnce = true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  void _setCategory(String? category) {
    _debounce?.cancel();
    setState(() {
      _activeCategory = category;
      // Clear the previous list immediately so a slow category search never
      // leaves the old results on screen (fixes "every chip shows the same
      // list").
      _results = const <Place>[];
      _error = null;
      _shown = 20;
    });
    // Category chips fetch the combined nearby dataset ONCE and filter it
    // locally (no new Overpass request per chip). Deselecting a chip returns
    // to the default all-categories nearby list. The "Anywhere" scope still
    // runs a wider free-provider search.
    if (category == null) {
      _runNearbyDefault();
    } else if (_scope != 'anywhere') {
      _runCategoryNearby(category);
    } else {
      _runSearch();
    }
  }

  /// Dataset categories a Explore chip maps to (see
  /// FreeGeoClient._nearbyCategoryTags). "Attractions" is the broad
  /// tourism/historic/natural set; "Food" is the restaurant/café/fast-food
  /// roll-up.
  List<String>? _categoryDatasetSet(String? category) => switch (category) {
        'tourist_attraction' => const <String>['attraction', 'museum', 'park'],
        'museum' => const <String>['museum'],
        'park' => const <String>['park'],
        'hotel' => const <String>['hotel'],
        'food' => const <String>['food', 'restaurant', 'cafe', 'fast_food'],
        'shopping' => const <String>['shopping'],
        'landmark' => const <String>['attraction'],
        'tourist_places' => const <String>['attraction', 'museum', 'park'],
        _ => null,
      };

  Future<void> _runCategoryNearby(String category) async {
    final List<String>? cats = _categoryDatasetSet(category);
    if (cats == null || _loading) return;
    final Position? pos = _position;
    if (pos == null) {
      // Location failure is its own outcome — never "temporarily limited"
      // and never a silent empty list.
      setState(() {
        _error = 'Your location is currently unavailable.';
        _searchedOnce = true;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
      _shown = 20;
    });
    try {
      final LatLng here = LatLng(pos.latitude, pos.longitude);
      final NearbyResult dataset = category == 'shopping'
          ? await _c.placesRepository.nearbyShopping(here)
          : await _c.placesRepository.nearbyAround(here);
      if (!mounted) return;
      final List<Place> filtered = dataset.places
          .where((Place p) =>
              cats.any((String c) => p.category == c || p.types.contains(c)))
          .toList()
        ..sort((Place a, Place b) => (a.distanceMeters ?? double.infinity)
            .compareTo(b.distanceMeters ?? double.infinity));
      NearbyDebug.instance.finalCount = filtered.length;
      setState(() {
        _results = filtered;
        _loading = false;
        _searchedOnce = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        if (_results.isEmpty) _error = placesErrorMessage(e);
        _loading = false;
        _searchedOnce = true;
      });
    }
  }

  String _effectiveQuery() {
    if (_query.isNotEmpty) return _query;
    if (_activeCategory != null) {
      // Use the human label ("Cafés", "Hotels", "Parks"…) so free providers
      // search the right kind of place instead of reusing the default
      // attraction query for every category.
      return kExploreCategoryLabels[_activeCategory] ?? _activeCategory!;
    }
    return 'tourist attractions near me';
  }

  /// Type id for a category, mapped to real OSM/provider filters by
  /// FreeGeoClient._typeFilters (hotels, food, museums, parks, shops…).
  List<String>? _categoryTypes(String? category) => switch (category) {
        'tourist_attraction' => const <String>['tourist_attraction'],
        'museum' => const <String>['museum'],
        'park' => const <String>['park'],
        'hotel' => const <String>['hotel'],
        'food' => const <String>['food'],
        'shopping' => const <String>['shopping'],
        'landmark' => const <String>['landmark'],
        'tourist_places' => const <String>['tourist_places'],
        _ => null,
      };

  /// The DEFAULT "Nearby" view: load the combined nearby dataset (every
  /// category — hotels, museums, parks, food, shopping, transit…) in ONE
  /// cached Overpass request and show it nearest-first. This is what makes
  /// Explore "auto-detect nearby places" on open, instead of a slow
  /// free-text multi-provider search.
  Future<void> _runNearbyDefault() async {
    final Position? pos = _position;
    if (pos == null || _loading) return;
    setState(() {
      _activeCategory = null;
      _loading = true;
      _error = null;
      _shown = 20;
    });
    try {
      final LatLng here = LatLng(pos.latitude, pos.longitude);
      final NearbyResult dataset = await _c.placesRepository.nearbyAround(here);
      if (!mounted) return;
      const Set<String> tourist = <String>{
        'attraction', 'museum', 'park', 'hotel',
        'food', 'restaurant', 'cafe', 'fast_food',
      };
      final List<Place> sorted = dataset.places
          .where((Place p) =>
              tourist.contains(p.category) ||
              p.types.any(tourist.contains))
          .toList()
        ..sort((Place a, Place b) => (a.distanceMeters ?? double.infinity)
            .compareTo(b.distanceMeters ?? double.infinity));
      NearbyDebug.instance.finalCount = sorted.length;
      setState(() {
        _results = sorted;
        _loading = false;
        _searchedOnce = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        if (_results.isEmpty) _error = placesErrorMessage(e);
        _loading = false;
        _searchedOnce = true;
      });
    }
  }

  Future<void> _runSearch({bool preserveOnEmpty = false}) async {
    final String q = _effectiveQuery();
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
      _shown = 20;
    });
    try {
      final List<Place> places = await _c.placesRepository.search(
        q,
        location: _position == null
            ? null
            : LatLng(_position!.latitude, _position!.longitude),
        radiusMeters: switch (_scope) {
          'nearby' => 10000.0,
          'hidden' => 10000.0,
          'anywhere' => 30000.0,
          _ => null,
        },
        types: _categoryTypes(_activeCategory),
      );
      if (!mounted) return;
      setState(() {
        // A background refresh (GPS re-run) that comes back empty must never
        // wipe out results the user is already looking at. Explicit searches
        // clear results up-front, so this only applies to that re-run.
        if (places.isEmpty && preserveOnEmpty && _results.isNotEmpty) {
          _loading = false;
          return;
        }
        _results = places;
        _loading = false;
        _searchedOnce = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        if (_results.isEmpty) _error = placesErrorMessage(e);
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
                const SizedBox(width: 8),
                _scopeChip('Saved', _scope == 'saved', () => _setScope('saved')),
                const SizedBox(width: 16),
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

  /// TEMPORARY dev diagnostic — shows the last nearby (Overpass) request's
  /// real result so provider-vs-app failures can be told apart on-device.
  Widget _nearbyDebugPanel() {
    final NearbyDebug d = NearbyDebug.instance;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF101418),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        'Nearby debug (req #${d.requestCount})\n'
        'HTTP: ${d.httpStatus ?? '-'}\n'
        'Raw: ${d.rawCount ?? '-'}\n'
        'Parsed: ${d.parsedCount ?? '-'}\n'
        'Final: ${d.finalCount ?? '-'}\n'
        'host: ${d.host ?? '-'}\n'
        'error: ${d.error ?? d.phase}',
        style: const TextStyle(
          color: Color(0xFF9FE8A0),
          fontSize: 11,
          fontFamily: 'monospace',
          height: 1.4,
        ),
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
    // While the first GPS fix is still arriving, stay on an honest loading
    // state instead of flashing a search error (the first search runs with
    // no location yet and only re-runs once the fix lands).
    if (!_locationDone && _position == null && _scope == 'nearby') {
      return const LoadingView(message: 'Finding your location…');
    }
    if (_locationDone && _position == null && _scope == 'nearby') {
      if (_locationDenied) {
        return EmptyState(
          icon: Icons.location_off,
          title: 'Location permission required',
          message: 'Location permission is required to discover nearby places.',
          actionLabel: 'Enable location',
          onAction: _enableLocation,
        );
      }
      return ErrorState(
        message: 'Could not get your location. Check that GPS is enabled and '
            'try again.',
        retryLabel: 'Retry',
        onRetry: _enableLocation,
      );
    }
    if (_error != null && _results.isEmpty) {
      // TEMPORARY dev diagnostic (remove once nearby flow is verified on a
      // physical device): shows the real runtime Overpass result below the
      // error so provider-vs-app failures can be told apart at a glance.
      return Column(
        children: <Widget>[
          Expanded(
            child: ErrorState(
              message: _error!,
              onRetry: _scope == 'saved' ? _loadSaved : _runSearch,
            ),
          ),
          _nearbyDebugPanel(),
        ],
      );
    }
    if (_results.isEmpty) {
      if (_scope == 'saved') {
        return EmptyState(
          icon: Icons.bookmark_border,
          title: 'No saved places yet',
          message:
              'Tap the bookmark icon on any place to save it here for quick '
              'access — even offline.',
          actionLabel: 'Explore nearby',
          onAction: () => _setScope('nearby'),
        );
      }
      // Category-specific empty state — honest about a sparse small town
      // instead of silently reusing another category's list.
      if (_activeCategory != null) {
        final String label =
            kExploreCategoryLabels[_activeCategory] ?? _activeCategory!;
        return EmptyState(
          icon: Icons.search_off,
          title: 'No ${label.toLowerCase()} found near you',
          message:
              'Nothing in this category is mapped within 10 km yet. Try '
              'widening to "Anywhere", or search a bigger nearby city.',
          actionLabel: 'Search anywhere',
          onAction: () => _setScope('anywhere'),
        );
      }
      if (_scope == 'nearby') {
        return Column(
          children: <Widget>[
            Expanded(
              child: EmptyState(
                icon: Icons.search_off,
                title: 'No nearby places found within 10 km.',
                message:
                    'Nothing is mapped within 10 km of your location yet. Try '
                    'switching to "Anywhere", or move to a larger town.',
                actionLabel: 'Search anywhere',
                onAction: () => _setScope('anywhere'),
              ),
            ),
            _nearbyDebugPanel(),
          ],
        );
      }
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
      itemCount: (_results.length < _shown ? _results.length : _shown) +
          (_results.length > _shown ? 1 : 0),
      separatorBuilder: (BuildContext context, int i) =>
          const SizedBox(height: 10),
      itemBuilder: (BuildContext context, int i) {
        if (i >= _shown) {
          return Center(
            child: OutlinedButton.icon(
              icon: const Icon(Icons.expand_more),
              label: Text('Load ${_results.length - _shown} more'),
              onPressed: () => setState(() => _shown += 20),
            ),
          );
        }
        final Place p = _results[i];
        return PlaceCard(
          place: p,
          distance: _distanceFor(p),
          onTap: () => context.push('/explore/place/${p.placeId}', extra: p),
        );
      },
    );
  }
}

