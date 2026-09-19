import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../../core/network/free_geo_client.dart';
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
  bool _liveLocationReady = false;
  bool _locationDone = false;
  bool _locationDenied = false;

  List<Place> _results = const <Place>[];
  bool _loading = false;
  bool _stale = false;
  String? _error;
  String? _providerWarning;
  bool _searchedOnce = false;
  String? _datasetKey;
  StreamSubscription<NearbyUpdate>? _updatesSub;

  /// Pagination: show the first 20 nearest results, then a "Load more" button
  /// — never an arbitrary tiny cap, and never hundreds of cards at once.
  int _shown = 20;

  Timer? _debounce;
  int _queryGeneration = 0;
  bool _initialized = false;

  bool _subscribedUpdates = false;

  @override
  void initState() {
    super.initState();
    _queryController.addListener(_onQueryChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Subscribe once: a background refresh of the shown nearby dataset
    // clears the "Showing saved nearby places" banner as soon as live
    // data lands.
    if (!_subscribedUpdates) {
      _subscribedUpdates = true;
      _updatesSub = _c.placesRepository.nearbyUpdates.listen(_onDatasetUpdate);
    }
  }

  void _onDatasetUpdate(NearbyUpdate u) {
    if (!mounted || _loading || u.key != _datasetKey) return;
    if (u.result.places.isEmpty) return;
    final List<Place> fresh = _applyCurrentView(u.result.places);
    if (fresh.isEmpty) return;
    setState(() {
      _results = fresh;
      _stale = false;
      _shown = 20;
    });
  }

  /// Re-applies the filter/ranking of whatever view is on screen
  /// (default nearby vs category chip) to a fresh dataset.
  List<Place> _applyCurrentView(List<Place> places) {
    final List<String>? cats =
        _activeCategory == null ? null : _categoryDatasetSet(_activeCategory);
    final List<Place> out = (cats == null
            ? places.toList()
            : places
                .where((Place p) =>
                    cats.any((String c) => p.category == c || p.types.contains(c)))
                .toList())
        ..sort((Place a, Place b) {
          final int ra = cats == null ? _nearbyRank(a) : 0;
          final int rb = cats == null ? _nearbyRank(b) : 0;
          if (ra != rb) return ra - rb;
          return (a.distanceMeters ?? double.infinity)
              .compareTo(b.distanceMeters ?? double.infinity);
        });
    return out;
  }

  @override
  void dispose() {
    unawaited(_updatesSub?.cancel());
    _queryController.removeListener(_onQueryChanged);
    _queryController.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _initLocation() async {
    // 1) Use the instant cached/last-known fix for map/UI readiness. Nearby
    //    data still waits for the explicit live refresh below.
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
    // 4) Wait for the live refresh before the first nearby request. A cached
    //    fix is useful for the map UI, but must not be presented as the GPS
    //    origin of a new nearby dataset.
    try {
      final Position? pos = await _c.locationService.currentPosition();
      if (!mounted || pos == null) return;
      final bool hadLocation = _position != null;
      setState(() {
        _position = pos;
        _liveLocationReady = !hadLocation;
        _locationDone = true;
        _locationDenied = false;
      });
      if (!hadLocation) {
        unawaited(_runNearbyDefault(refreshLocation: false));
      } else {
        // currentPosition may be last-known; refreshPosition below obtains a
        // live fix and starts the current mode only after that fix is ready.
        unawaited(_refreshExplorePosition());
      }
    } catch (_) {
      // The fix failed — re-check the permission so the UI distinguishes
      // "permission denied" from "GPS unavailable" instead of guessing.
      if (mounted) unawaited(_refreshLocationState());
    }
  }

  Future<Position?> _freshExplorePosition() async {
    try {
      final Position? fresh = await _c.locationService
          .refreshPosition(timeout: const Duration(seconds: 12));
      if (!mounted || fresh == null) return null;
      setState(() {
        _position = fresh;
        _liveLocationReady = true;
        _locationDone = true;
        _locationDenied = false;
      });
      return fresh;
    } catch (_) {
      return null;
    }
  }

  Future<void> _refreshExplorePosition() async {
    try {
      final Position? old = _position;
      final Position? fresh = await _freshExplorePosition();
      if (!mounted) return;
      if (fresh == null) {
        if (_scope == 'nearby' && !_searchedOnce) {
          setState(() {
            _error =
                'Could not get a fresh GPS fix. Turn on location services and retry.';
          });
        }
        return;
      }
      final bool moved = old == null ||
          GeoUtils.distanceMeters(
                LatLng(old.latitude, old.longitude),
                LatLng(fresh.latitude, fresh.longitude),
              ) >
              100;
      // The first nearby request may still be pending because the screen was
      // opened with a last-known fix. Always start it after that first live
      // refresh; later refreshes only restart the view when the user moved.
      if (_searchedOnce && !moved) return;
      // Invalidate the request that used the cached fix and immediately
      // re-run the currently visible mode around the fresh GPS point. This
      // is important when the first nearby fetch started before the GPS
      // refresh completed.
      _queryGeneration++;
      if (_activeCategory != null && _scope != 'anywhere') {
        unawaited(_runCategoryNearby(
          _activeCategory!,
          refreshLocation: false,
        ));
      } else if (_query.trim().isNotEmpty) {
        unawaited(_runSuggestions(_query));
      } else if (_scope == 'nearby') {
        unawaited(_runNearbyDefault(refreshLocation: false));
      }
    } catch (_) {
      // Keep the already usable cached fix; the UI must not regress to a
      // location error merely because the optional refresh timed out.
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
    final int generation = ++_queryGeneration;
    if (q != _query) {
      setState(() => _query = q);
    }
    _debounce?.cancel();
    if (q.isEmpty) {
      setState(() {
        _loading = false;
        _providerWarning = null;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 450), () {
      // A typed search is a brand-new query — clear stale results so the UI
      // never keeps showing a previous category's list.
      if (_results.isNotEmpty) setState(() => _results = const <Place>[]);
      _runSuggestions(q, generation: generation);
    });
  }

  /// Autocomplete suggestions while typing (MapTiler Geocoding — permitted;
  /// never public Nominatim). Shows real matching places as the user types.
  Future<void> _runSuggestions(String q, {int? generation}) async {
    final int requestGeneration = generation ?? _queryGeneration;
    setState(() {
      _loading = true;
      _stale = false;
      _error = null;
      _datasetKey = null;
      _shown = 20;
    });
    try {
      Position? pos = _position;
      if (_scope == 'nearby' && !_liveLocationReady) {
        pos = await _freshExplorePosition();
        if (!mounted || requestGeneration != _queryGeneration) return;
      }
      List<Place> places = await _c.placesRepository.suggest(
        q,
        location: pos == null
            ? null
            : LatLng(pos.latitude, pos.longitude),
      );
      // Nearby mode: keep local metro recall, but do not throw away the
      // repository's text relevance by sorting distance-only. Exact place
      // names must remain above nearby extended names; distance breaks ties.
      if (_scope == 'nearby' && pos != null && places.isNotEmpty) {
        final LatLng here = LatLng(pos.latitude, pos.longitude);
        final List<Place> within35 = places
            .where((Place p) => GeoUtils.distanceMeters(here, p.coords) <= 35000)
            .toList();
        final List<Place> filtered = within35.isNotEmpty
            ? within35
            : places
                .where((Place p) => GeoUtils.distanceMeters(here, p.coords) <= 50000)
                .toList();
        if (filtered.isNotEmpty) places = filtered;
        places = PlaceRanking.rankSuggestions(places, q, here);
      }
      if (!mounted || requestGeneration != _queryGeneration) return;
      setState(() {
        _results = places;
        _providerWarning = _c.placesRepository.backendWarning;
        _loading = false;
        _searchedOnce = true;
      });
    } catch (e) {
      if (!mounted || requestGeneration != _queryGeneration) return;
      setState(() {
        _error = placesErrorMessage(e);
        _loading = false;
        _searchedOnce = true;
      });
    }
  }

  void _setScope(String scope) {
    _debounce?.cancel();
    _queryGeneration++;
    setState(() {
      _scope = scope;
      _activeCategory = null;
      _results = const <Place>[];
      _error = null;
      _datasetKey = null;
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
      _stale = false;
      _shown = 20;
    });
    try {
      final List<Place> saved = await FavoritesStore.all();
      if (!mounted) return;
      setState(() {
        _results = saved;
        _providerWarning = null;
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
    _queryGeneration++;
    setState(() {
      _activeCategory = category;
      // Clear the previous list immediately so a slow category search never
      // leaves the old results on screen (fixes "every chip shows the same
      // list").
      _results = const <Place>[];
      _error = null;
      _datasetKey = null;
      _shown = 20;
    });
    // Category chips use an exact, category-scoped nearby dataset. This keeps
    // Shopping from reusing a generic/previous category list and lets the
    // repository use Google Nearby Search when its proxy is configured.
    // Deselecting a chip returns to the default all-categories nearby list.
    // The "Anywhere" scope still runs a wider free-provider search.
    if (category == null) {
      _runNearbyDefault();
    } else if (_scope != 'anywhere') {
      _runCategoryNearby(category);
    } else {
      _runSearch();
    }
  }

  /// Category requests are already exact and the repository normalizes every
  /// returned record to the requested semantic id. Keep this filter strict so
  /// a slow/empty Shopping request can never display the broad nearby dataset
  /// or another chip's results.
  List<String>? _categoryDatasetSet(String? category) =>
      category == null ? null : <String>[category];

  Future<void> _runCategoryNearby(
    String category, {
    bool refreshLocation = true,
  }) async {
    final int requestGeneration = _queryGeneration;
    final List<String>? cats = _categoryDatasetSet(category);
    if (cats == null) return;
    Position? pos = _position;
    if (refreshLocation || !_liveLocationReady) {
      pos = await _freshExplorePosition();
      if (!mounted || requestGeneration != _queryGeneration) return;
    }
    if (pos == null) {
      // Location failure is its own outcome — never "temporarily limited"
      // and never a silent empty list.
      setState(() {
        _error = 'Your location is currently unavailable.';
        _loading = false;
        _searchedOnce = true;
      });
      return;
    }
    setState(() {
      _loading = true;
      _stale = false;
      _error = null;
      _datasetKey = null;
      _shown = 20;
    });
    try {
      final LatLng here = LatLng(pos.latitude, pos.longitude);
      final NearbyResult dataset =
          await _c.placesRepository.nearbyCategory(
            here,
            category,
            force: true,
          );
      if (!mounted ||
          _activeCategory != category ||
          requestGeneration != _queryGeneration) {
        return;
      }
      final List<Place> filtered = dataset.places
          .where((Place p) =>
              cats.any((String c) => p.category == c || p.types.contains(c)))
          .toList()
        ..sort((Place a, Place b) => (a.distanceMeters ?? double.infinity)
            .compareTo(b.distanceMeters ?? double.infinity));
      NearbyDebug.instance.finalCount = filtered.length;
      setState(() {
        _results = filtered;
        _providerWarning = dataset.fromCache
            ? null
            : _c.placesRepository.backendWarning;
        _loading = false;
        _stale = dataset.stale;
        _datasetKey = dataset.key;
        _searchedOnce = true;
      });
    } catch (e) {
      if (!mounted ||
          _activeCategory != category ||
          requestGeneration != _queryGeneration) {
        return;
      }
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
  Future<void> _runNearbyDefault({bool refreshLocation = true}) async {
    final int requestGeneration = _queryGeneration;
    Position? pos = _position;
    if (refreshLocation || !_liveLocationReady) {
      pos = await _freshExplorePosition();
      if (!mounted || requestGeneration != _queryGeneration) return;
    }
    if (pos == null) {
      if (mounted) {
        setState(() {
          _error =
              'Could not get a fresh GPS fix. Turn on location services and retry.';
          _loading = false;
        });
      }
      return;
    }
    setState(() {
      _activeCategory = null;
      _loading = true;
      _stale = false;
      _error = null;
      _datasetKey = null;
      _shown = 20;
    });
    try {
      final LatLng here = LatLng(pos.latitude, pos.longitude);
      final NearbyResult dataset = await _c.placesRepository.nearbyAround(
        here,
        force: true,
      );
      if (!mounted || requestGeneration != _queryGeneration) return;
      // Show EVERYTHING that is actually mapped nearby (essentials —
      // hospitals, ATMs, pharmacies — included), nearest first. The old
      // tourist-only filter threw away 101 real places and left the user
      // staring at an empty screen.
      final List<Place> sorted = dataset.places
          .toList()
        ..sort((Place a, Place b) {
          // Gentle ranking: tourist-relevant places of a similar distance
          // first, then strictly nearest-first.
          final int ra = _nearbyRank(a);
          final int rb = _nearbyRank(b);
          if (ra != rb) return ra - rb;
          return (a.distanceMeters ?? double.infinity)
              .compareTo(b.distanceMeters ?? double.infinity);
        });
      NearbyDebug.instance.finalCount = sorted.length;
      setState(() {
        _results = sorted;
        _providerWarning = null;
        _loading = false;
        _stale = dataset.stale;
        _datasetKey = dataset.key;
        _searchedOnce = true;
      });
    } catch (e) {
      if (!mounted || requestGeneration != _queryGeneration) return;
      // The grouped Overpass dataset failed (rate-limited / unreachable).
      // FALLBACK: run the multi-provider text search instead (MapTiler +
      // Nominatim + Wikipedia geosearch still work when Overpass is busy),
      // so the default nearby view shows REAL places instead of an error.
      try {
        final LatLng here = LatLng(pos.latitude, pos.longitude);
        final List<Place> places = await _c.placesRepository.search(
          'tourist attractions near me',
          location: here,
          radiusMeters: 25000,
          forceFresh: true,
        );
        if (!mounted || requestGeneration != _queryGeneration) return;
        if (places.isNotEmpty) {
          NearbyDebug.instance.finalCount = places.length;
          NearbyDebug.instance.error = 'fallback: multi-provider search '
              '(${places.length} places)';
          setState(() {
            _results = places;
            _providerWarning =
                _c.placesRepository.backendWarning ??
                (places.any((Place p) => p.provider == 'curated')
                    ? 'Some results are directory records; verify details before relying on them.'
                    : null);
            _loading = false;
            _searchedOnce = true;
          });
          return;
        }
      } catch (_) {
        // Fall through to the honest error state.
      }
      setState(() {
        if (_results.isEmpty) _error = placesErrorMessage(e);
        _loading = false;
        _searchedOnce = true;
      });
    }
  }

  /// True when the free-text query itself maps to a category keyword
  /// ("hotels", "hospitals near me", ...) — those DO hit the radius-bound
  /// Overpass path, so widening rings help.
  bool _queryHasCategoryFilter(String q) {
    final String lower = q.toLowerCase();
    const List<String> keywords = <String>[
      'hotel', 'restaurant', 'food', 'cafe', 'park', 'museum',
      'attraction', 'hospital', 'police', 'pharmacy', 'atm', 'fuel',
      'petrol', 'bank', 'shopping', 'mall',
    ];
    return keywords.any(lower.contains);
  }

  /// Ranking bucket for the default nearby list: tourist-relevant categories
  /// first, then everything else — distance breaks ties inside a bucket.
  static int _nearbyRank(Place p) {
    bool touristy(Place p) {
      final String c = p.category ?? '';
      return c == 'attraction' ||
          c == 'museum' ||
          c == 'park' ||
          c == 'hotel' ||
          c == 'food' ||
          c == 'restaurant' ||
          c == 'cafe' ||
          c == 'fast_food' ||
          p.types.any(const <String>{
            'attraction', 'museum', 'park', 'hotel',
            'food', 'restaurant', 'cafe', 'fast_food',
          }.contains);
    }

    return touristy(p) ? 0 : 1;
  }

  Future<void> _runSearch({bool preserveOnEmpty = false}) async {
    final String q = _effectiveQuery();
    _queryGeneration++;
    final int requestGeneration = _queryGeneration;
    setState(() {
      _loading = true;
      _stale = false;
      _error = null;
      _datasetKey = null;
      _shown = 20;
    });
    try {
      final LatLng? here = _position == null
          ? null
          : LatLng(_position!.latitude, _position!.longitude);
      // NO fixed radius limit for category searches: they start at 25 km and
      // auto-widen (25 -> 50 -> 100 -> 250 km) until real places are found.
      // Pure text search is NOT radius-filtered by the providers (MapTiler /
      // Photon / Nominatim rank by relevance), so widening there would only
      // re-send the same request and waste a minute — a single call is used.
      final List<String>? types = _categoryTypes(_activeCategory);
      final bool hasCategoryFilters =
          types != null || _queryHasCategoryFilter(q);
      List<Place> places = await _c.placesRepository.search(
        q,
        location: here,
        radiusMeters: _scope == 'anywhere' ? 50000.0 : 25000.0,
        types: types,
      );
      // Nearby mode: keep the local metro boundary, then preserve exact and
      // prefix text matches above merely-nearby names. Distance is a tie-break.
      if (_scope == 'nearby' && here != null) {
        final List<Place> within35 = places
            .where((Place p) => GeoUtils.distanceMeters(here, p.coords) <= 35000)
            .toList();
        final List<Place> filtered = within35.isNotEmpty
            ? within35
            : places
                .where((Place p) => GeoUtils.distanceMeters(here, p.coords) <= 50000)
                .toList();
        if (filtered.isNotEmpty) places = filtered;
        places = PlaceRanking.rankSuggestions(places, q, here);
      }
      if (hasCategoryFilters && _scope != 'nearby') {
        for (final double r in const <double>[50000.0, 100000.0, 250000.0]) {
          if (places.isNotEmpty || !mounted) break;
          places = await _c.placesRepository.search(
            q,
            location: here,
            radiusMeters: r,
            types: types,
          );
        }
      }
      if (!mounted || requestGeneration != _queryGeneration) return;
      setState(() {
        // A background refresh (GPS re-run) that comes back empty must never
        // wipe out results the user is already looking at. Explicit searches
        // clear results up-front, so this only applies to that re-run.
        if (places.isEmpty && preserveOnEmpty && _results.isNotEmpty) {
          _loading = false;
          return;
        }
        _results = places;
        _providerWarning = _c.placesRepository.backendWarning;
        _loading = false;
        _searchedOnce = true;
      });
    } catch (e) {
      if (!mounted || requestGeneration != _queryGeneration) return;
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
      return ErrorState(
        message: _error!,
        onRetry: _scope == 'saved' ? _loadSaved : _runSearch,
      );
    }
    if (_providerWarning != null && _results.isEmpty) {
      return ErrorState(
        message: _providerWarning!,
        onRetry: _scope == 'saved' ? _loadSaved : _runSearch,
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
              'We searched nearby and out to 250 km — nothing in this '
              'category is mapped there yet. Try "Anywhere" for a worldwide '
              'search, or search a bigger nearby city.',
          actionLabel: 'Search anywhere',
          onAction: () => _setScope('anywhere'),
        );
      }
      if (_scope == 'nearby') {
        final bool searching = _query.trim().isNotEmpty ||
            (_activeCategory != null && _searchedOnce);
        return Column(
          children: <Widget>[
            Expanded(
              child: searching
                  ? EmptyState(
                      icon: Icons.search_off,
                      title:
                          'No matches for "${_query.trim().isNotEmpty ? _query.trim() : (kExploreCategoryLabels[_activeCategory] ?? _activeCategory!)}"',
                      message:
                          'We searched nearby, out to 250 km and across '
                          'multiple providers — nothing matched. Try a '
                          'different spelling, a better-known landmark, or '
                          '"Anywhere" for a worldwide search.',
                      actionLabel: 'Search anywhere',
                      onAction: () => _setScope('anywhere'),
                    )
                  : EmptyState(
                      icon: Icons.search_off,
                      title: 'No places found nearby',
                      message:
                          'We searched nearby and out to 250 km of your '
                          'location — nothing was mapped there yet. Try '
                          '"Anywhere" to search the whole world, or move to '
                          'a larger town.',
                      actionLabel: 'Search anywhere',
                      onAction: () => _setScope('anywhere'),
                    ),
            ),
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
    if (_stale) {
      return Column(
        children: <Widget>[
          Container(
            width: double.infinity,
            margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFFFFF3E0),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: <Widget>[
                const Icon(Icons.cloud_off, size: 16, color: Color(0xFFB26A00)),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Showing saved places — updating to live results…',
                    style:
                        TextStyle(fontSize: 12.5, color: Color(0xFFB26A00)),
                  ),
                ),
                TextButton(
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    foregroundColor: const Color(0xFFB26A00),
                  ),
                  onPressed: _loading
                      ? null
                      : () => _runNearbyDefault(),
                  child: const Text('Refresh',
                      style: TextStyle(fontWeight: FontWeight.w800)),
                ),
              ],
            ),
          ),
          Expanded(child: _resultsList()),
        ],
      );
    }
    return _resultsList();
  }

  Widget _providerNotice() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF3E0),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Icon(Icons.info_outline, size: 18, color: Color(0xFF9A5B00)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _providerWarning!,
              style: const TextStyle(fontSize: 12.5, color: Color(0xFF7A4A00)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _resultsList() {
    final bool hasNotice = _providerWarning != null;
    final int visible = _results.length < _shown ? _results.length : _shown;
    final int loadMore = _results.length > _shown ? 1 : 0;
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      itemCount: visible + loadMore + (hasNotice ? 1 : 0),
      separatorBuilder: (BuildContext context, int i) =>
          const SizedBox(height: 10),
      itemBuilder: (BuildContext context, int i) {
        if (hasNotice && i == 0) return _providerNotice();
        final int index = hasNotice ? i - 1 : i;
        if (index >= _shown) {
          return Center(
            child: OutlinedButton.icon(
              icon: const Icon(Icons.expand_more),
              label: Text('Load ${_results.length - _shown} more'),
              onPressed: () => setState(() => _shown += 20),
            ),
          );
        }
        final Place p = _results[index];
        return PlaceCard(
          place: p,
          distance: _distanceFor(p),
          onTap: () => context.push('/explore/place/${p.placeId}', extra: p),
          // One-tap "show this place's location on the map" — the map
          // section opens focused on the place with a marker and route.
          trailing: IconButton(
            icon: const Icon(Icons.map_outlined),
            tooltip: 'Show on map',
            onPressed: () => context.go(
              '/map?lat=${p.lat}&lng=${p.lng}&name=${Uri.encodeComponent(p.name)}',
            ),
          ),
        );
      },
    );
  }
}

