import 'dart:async';
import 'dart:typed_data';

import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/network/api_client.dart';
import '../../core/network/api_exception.dart';
import '../../core/network/free_geo_client.dart';
import '../../core/network/osrm_client.dart';
import '../../core/utils/geo.dart';
import '../local/nearby_store.dart';
import '../local/search_cache.dart';
import '../models/places.dart';

/// Places / routes / geocoding.
///
/// Primary transport is the Tourism backend (Google Places proxy, server-side
/// key). When the backend is not deployed/unreachable, everything falls back
/// to free, real providers so Explore and the map keep working on-device:
/// MapTiler geocoding (search + reverse) and the OSRM public router.
///
/// Routing is always OSRM (free, keyless) — Google Routes is not used.
class PlacesRepository {
  PlacesRepository(this._api);

  final ApiClient _api;
  final FreeGeoClient _free = FreeGeoClient();
  final OsrmClient _osrm = OsrmClient();
  final NearbyStore _nearby = NearbyStore();

  String? _backendWarning;

  /// Non-fatal diagnostic for screens that are showing real free-provider
  /// results while the configured Google Places proxy is unavailable. Keeping
  /// this explicit prevents a weak fallback list from looking like a healthy
  /// Google response.
  String? get backendWarning => _backendWarning;

  void _recordBackendSuccess() => _backendWarning = null;

  void _recordBackendFailure() {
    _backendWarning =
        'Google Places is unavailable right now; showing open-data results.';
  }

  /// Broadcast of background nearby-dataset refreshes — screens showing a
  /// stale (saved) dataset subscribe and swap in the fresh list the moment
  /// the network refresh lands.
  Stream<NearbyUpdate> get nearbyUpdates => _nearby.updates;

  List<Place> _decode(Map<String, dynamic> data) {
    final List<dynamic> raw =
        (data['places'] is List) ? data['places'] as List : <dynamic>[];
    return raw
        .whereType<Map<String, dynamic>>()
        .map(Place.fromJson)
        .toList();
  }

  // Fallback for Lucknow places and schools
  List<Place> _lucknowFallback(String query, LatLng? location) =>
      _free.lucknowFallback(query, location);

  Future<List<Place>> search(
    String query, {
    LatLng? location,
    double? radiusMeters,
    List<String>? types,
  }) async {
    final String q = query.trim();
    if (q.isEmpty) return const <Place>[];

    // Keep the verified local fallback, but never let it block the live
    // providers. Both provider families run together so a working Google
    // proxy can win even when Overpass is slow.
    final List<Place> fallback = _lucknowFallback(q, location);
    Future<List<Place>> safe(Future<List<Place>> request) async {
      try {
        return await request;
      } catch (_) {
        return const <Place>[];
      }
    }

    final List<Future<List<Place>>> requests = <Future<List<Place>>>[
      safe(_freeSearchWithCache(
        q,
        near: location,
        types: types,
        radiusMeters: radiusMeters ?? 25000,
      )),
      if (configured)
        (() async {
          try {
            final List<Place> places = await _backendSearch(
              q,
              location,
              radiusMeters,
              types,
            ).timeout(const Duration(seconds: 8));
            _recordBackendSuccess();
            return places;
          } catch (_) {
            _recordBackendFailure();
            return const <Place>[];
          }
        })(),
    ];
    final List<List<Place>> batches = await Future.wait(requests);
    final List<Place> allPlaces = <Place>[...fallback];
    for (final List<Place> batch in batches) {
      allPlaces.addAll(batch);
    }
    if (allPlaces.isEmpty) return const <Place>[];

    final Map<String, Place> merged = <String, Place>{};
    for (final Place p in allPlaces) {
      final String key =
          '${p.name.toLowerCase().trim()}|${p.lat.toStringAsFixed(4)},${p.lng.toStringAsFixed(4)}';
      final Place? old = merged[key];
      if (old == null || _isRicherSuggestion(p, old)) merged[key] = p;
    }
    List<Place> out = merged.values.toList();
    if (location != null && types != null && radiusMeters != null) {
      out = out
          .where((Place p) =>
              GeoUtils.distanceMeters(location, p.coords) <= radiusMeters)
          .toList();
    }

    // Accuracy and shortest distance first. The relevance filter removes
    // foreign/generic noise only after all real providers have been merged.
    if (location != null) {
      out = PlaceRanking.rankSuggestions(out, q, location);
      final List<Place> rel = PlaceRanking.filterRelevant(out, q, location);
      if (rel.isNotEmpty) out = rel;
    }
    return out;
  }

  /// Autocomplete suggestions while typing.
  ///
  /// The free providers are useful as a fallback, but they do not have the
  /// same local-place coverage as Google Maps. When the authenticated backend
  /// is available, run its Google Places Text Search in parallel with the free
  /// search and merge both result sets. This is what makes a query such as
  /// "new public college" return all nearby branches instead of only the two
  /// hand-known fallback records.
  Future<List<Place>> suggest(
    String query, {
    LatLng? location,
    int limit = 15,
  }) async {
    final String q = query.trim();
    if (q.isEmpty) return const <Place>[];
    final String cacheKey = SearchCache.key(
      q,
      null,
      location?.latitude,
      location?.longitude,
      0,
    );
    // Once a Google proxy is configured, always make a live request for
    // autocomplete. A cache entry may have been written before Firebase/key
    // setup (or during a transient backend outage) and must not permanently
    // beat a fresh locality-aware response.
    if (!configured || q.length < 3) {
      final List<Place>? cached = await SearchCache.read(cacheKey);
      if (cached != null && cached.isNotEmpty) {
        // Re-rank a cached response against the current GPS fix. The cache key
        // is intentionally area-bucketed, so the user's position may have
        // moved a little since the response was written.
        final List<Place> cachedRanked =
            PlaceRanking.rankSuggestions(cached, q, location);
        final List<Place> cachedRelevant =
            PlaceRanking.filterRelevant(cachedRanked, q, location);
        return (cachedRelevant.isNotEmpty ? cachedRelevant : cachedRanked)
            .take(limit)
            .toList();
      }
    }

    Future<List<Place>> safe(Future<List<Place>> request) async {
      try {
        return await request;
      } catch (_) {
        return const <Place>[];
      }
    }

    final List<Future<List<Place>>> requests = <Future<List<Place>>>[
      safe(_free.suggest(query, near: location, limit: limit)),
      // Avoid spending a backend/Places request on one- or two-letter input;
      // the free providers still provide lightweight early suggestions.
      if (configured && q.length >= 3)
        (() async {
          try {
            final List<Place> places = await _backendSuggest(q, location)
                .timeout(const Duration(seconds: 7));
            _recordBackendSuccess();
            return places;
          } catch (_) {
            _recordBackendFailure();
            return const <Place>[];
          }
        })(),
    ];
    final List<List<Place>> batches = await Future.wait(requests);
    final List<Place> all = <Place>[
      for (final List<Place> batch in batches) ...batch,
    ];

    // FreeGeoClient already contributes the local Lucknow recall list. Keep
    // this explicit fallback too, in case the free request timed out while
    // the backend was unavailable.
    if (all.isEmpty) {
      all.addAll(_lucknowFallback(q, location));
    }
    if (all.isEmpty) {
      final List<Place>? stale = await SearchCache.readStale(cacheKey);
      if (stale != null && stale.isNotEmpty) return stale.take(limit).toList();
      return const <Place>[];
    }

    final Map<String, Place> unique = <String, Place>{};
    for (final Place place in all) {
      final String key =
          '${place.name.toLowerCase().trim()}|${place.lat.toStringAsFixed(4)},${place.lng.toStringAsFixed(4)}';
      final Place? old = unique[key];
      if (old == null || _isRicherSuggestion(place, old)) {
        unique[key] = place;
      }
    }

    final List<Place> ranked = PlaceRanking.rankSuggestions(
      unique.values.toList(),
      q,
      location,
    );
    final List<Place> relevant =
        PlaceRanking.filterRelevant(ranked, q, location);
    final List<Place> result = (relevant.isNotEmpty ? relevant : ranked)
        .take(limit)
        .toList();
    // A free-only response is deliberately not cached while the backend is
    // configured. Otherwise one temporary backend outage permanently masks
    // the Google result until the cache expires.
    final bool backendWasUsed = configured && q.length >= 3;
    final bool backendReturned = batches.length > 1 && batches[1].isNotEmpty;
    if (result.isNotEmpty && (!backendWasUsed || backendReturned)) {
      unawaited(SearchCache.write(cacheKey, result));
    }
    return result;
  }

  Future<List<Place>> _backendSearch(
    String query,
    LatLng? location,
    double? radiusMeters,
    List<String>? types,
  ) async {
    final Map<String, dynamic> body = <String, dynamic>{'query': query};
    if (location != null) {
      body['location'] = <String, double>{
        'lat': location.latitude,
        'lng': location.longitude,
      };
    }
    if (radiusMeters != null) body['radiusMeters'] = radiusMeters;
    if (types != null && types.isNotEmpty) {
      final String rawType = types.first;
      final String googleType = <String, String>{
        'tourist_places': 'tourist_attraction',
        'landmark': 'tourist_attraction',
        'food': 'restaurant',
        'hotel': 'lodging',
        'shopping': 'store',
      }[rawType] ?? rawType;
      body['types'] = <String>[googleType];
    }
    final Map<String, dynamic> data = await _api.post('/placesSearch', body);
    return _decode(data);
  }

  Future<List<Place>> _backendSuggest(String query, LatLng? location) async {
    final Map<String, dynamic> body = <String, dynamic>{'query': query};
    if (location != null) {
      body['location'] = <String, double>{
        'lat': location.latitude,
        'lng': location.longitude,
      };
      // Google Text Search accepts up to 50 km and uses this as a locality
      // bias. The client-side relevance filter still keeps the user's own
      // metro area above distant same-name places.
      body['radiusMeters'] = 50000.0;
    }
    final Map<String, dynamic> data = await _api.post('/placesSearch', body);
    return _decode(data);
  }

  static bool _isRicherSuggestion(Place a, Place b) {
    int score(Place p) =>
        (p.address != null && p.address!.isNotEmpty ? 1 : 0) +
        (p.rating != null ? 1 : 0) +
        (p.photoUrls.isNotEmpty ? 1 : 0) +
        (p.primaryType != null ? 1 : 0);
    return score(a) > score(b);
  }

  /// Free-provider search with a short on-device cache so repeat searches in
  /// the same area are instant (no repeated network round-trips).
  Future<List<Place>> _freeSearchWithCache(
    String query, {
    LatLng? near,
    List<String>? types,
    double radiusMeters = 10000,
  }) async {
    final String cacheKey = SearchCache.key(
      query,
      types,
      near?.latitude,
      near?.longitude,
      radiusMeters,
    );
    final List<Place>? cached = await SearchCache.read(cacheKey);
    if (cached != null && cached.isNotEmpty) {
      // Cached lists were written by whatever ranking existed at write time.
      // Re-apply local-first ranking + relevance so a stale or old-format
      // entry can never put far-away noise above the user's own area.
      if (types == null) {
        final List<Place> ranked =
            PlaceRanking.rankSuggestions(cached, query.trim(), near);
        final List<Place> relevant =
            PlaceRanking.filterRelevant(ranked, query.trim(), near);
        if (relevant.isNotEmpty) return relevant;
        // Cached entry is entirely irrelevant now (e.g. written by an old
        // build) — fall through to a fresh network search instead.
      } else {
        final List<Place> inRadius = near == null
            ? cached
            : cached
                .where((Place p) =>
                    GeoUtils.distanceMeters(near, p.coords) <= radiusMeters)
                .toList();
        if (inRadius.isNotEmpty) return inRadius;
        // A stale category cache can contain records outside the current
        // radius after a GPS move; ignore it and ask the provider again.
      }
    }
    try {
      final List<Place> result = await _free.searchPlaces(
        query,
        near: near,
        types: types,
        radiusMeters: radiusMeters,
        filterToRadius: types != null,
      );
      if (result.isNotEmpty) {
        unawaited(SearchCache.write(cacheKey, result));
      }
      return result;
    } on ApiException catch (e) {
      // Offline / rate-limited / provider error → serve stale saved results
      // instead of surfacing a misleading failure when we have real data.
      if (e.kind == ApiErrorKind.network ||
          e.kind == ApiErrorKind.timeout ||
          e.kind == ApiErrorKind.rateLimited ||
          e.kind == ApiErrorKind.server ||
          e.kind == ApiErrorKind.parser) {
        final List<Place>? stale = await SearchCache.readStale(cacheKey);
        if (stale != null && stale.isNotEmpty) return stale;
      }
      rethrow;
    }
  }

  /// Combined nearby dataset (all essential categories) for a location,
  /// fetched once via a grouped Overpass query and cached per location
  /// bucket. This is the fast default Nearby view; exact category chips use
  /// [nearbyCategory] so their provider query and cache are category-scoped.
  /// On network/rate-limit failures a stale cached dataset is returned
  /// (flagged) instead of an error.
  Future<NearbyResult> nearbyAround(LatLng location,
      {double radiusMeters = FreeGeoClient.kNearbyRadiusMeters,
      bool force = false}) {
    return _nearby.load(
      location,
      force: force,
      variant: 'core|r:${radiusMeters.round()}',
      // Keep the first Explore skeleton bounded even if an Overpass mirror
      // accepts the request but never completes it. The UI can then use its
      // honest multi-provider fallback path.
      fetch: () => _free
          .nearbyAround(location, radiusMeters: radiusMeters)
          .timeout(const Duration(seconds: 20)),
    );
  }

  /// Category-specific nearby search. The Google Places proxy is the primary
  /// recall source when configured; the real OSM/Overpass category search runs
  /// in parallel and remains the offline/free fallback. This path is separate
  /// from the broad nearby dataset because a `shop=*` query can be much denser
  /// than hospitals, parks, or food and should never leave the chip skeleton
  /// spinning while the other categories load.
  Future<NearbyResult> nearbyCategory(
    LatLng location,
    String category, {
    double radiusMeters = FreeGeoClient.kNearbyRadiusMeters,
    bool force = false,
  }) {
    final String variant = 'category:$category|r:${radiusMeters.round()}';
    return _nearby.load(
      location,
      force: force,
      variant: variant,
      fetch: () => _fetchNearbyCategory(
        location,
        category,
        radiusMeters: radiusMeters,
      ),
    );
  }

  /// Backwards-compatible convenience for callers that only need shops.
  Future<NearbyResult> nearbyShopping(LatLng location,
      {double radiusMeters = FreeGeoClient.kNearbyRadiusMeters,
      bool force = false}) =>
      nearbyCategory(
        location,
        'shopping',
        radiusMeters: radiusMeters,
        force: force,
      );

  Future<List<Place>> _fetchNearbyCategory(
    LatLng location,
    String category, {
    required double radiusMeters,
  }) async {
    final String? freeType = _freeTypeForCategory(category);
    if (freeType == null) return const <Place>[];

    Future<List<Place>> freeRequest() async {
      try {
        // The broad shop layer is especially large; ten kilometres gives a
        // useful nearby list without asking a public mirror for an entire
        // metro's worth of stores.
        final double freeRadius = category == 'shopping'
            ? radiusMeters.clamp(1000, 10000).toDouble()
            : radiusMeters;
        return await _free.searchPlaces(
          _categoryQuery(category),
          near: location,
          types: <String>[freeType],
          radiusMeters: freeRadius,
          filterToRadius: true,
        ).timeout(const Duration(seconds: 15));
      } catch (_) {
        return const <Place>[];
      }
    }

    Future<List<Place>> backendRequest() async {
      if (!configured) return const <Place>[];
      try {
        final List<Place> places = await _backendNearby(
          location,
          _googleTypeForCategory(category),
          radiusMeters,
        ).timeout(const Duration(seconds: 8));
        _recordBackendSuccess();
        return places;
      } catch (_) {
        _recordBackendFailure();
        return const <Place>[];
      }
    }

    final List<List<Place>> batches = await Future.wait(<Future<List<Place>>>[
      freeRequest(),
      backendRequest(),
    ]);
    final Map<String, Place> merged = <String, Place>{};
    for (final List<Place> batch in batches) {
      for (final Place raw in batch) {
        final double distance = GeoUtils.distanceMeters(location, raw.coords);
        if (distance > radiusMeters) continue;
        // This request is already category-scoped. Normalize the semantic
        // category so the UI does not discard Google `tourist_attraction` /
        // `store` records while filtering for its chip label.
        final Place place = raw.copyWith(
          category: category,
          distanceMeters: raw.distanceMeters ?? distance,
        );
        final String key =
            '${place.name.toLowerCase().trim()}|${place.lat.toStringAsFixed(4)},${place.lng.toStringAsFixed(4)}';
        final Place? old = merged[key];
        if (old == null || _isRicherSuggestion(place, old)) {
          merged[key] = place;
        }
      }
    }
    final List<Place> out = merged.values.toList()
      ..sort((Place a, Place b) =>
          (a.distanceMeters ?? GeoUtils.distanceMeters(location, a.coords))
              .compareTo(b.distanceMeters ??
                  GeoUtils.distanceMeters(location, b.coords)));
    return out;
  }

  static String _categoryQuery(String category) => switch (category) {
        'tourist_attraction' => 'tourist attractions',
        'tourist_places' => 'tourist attractions',
        'landmark' => 'tourist attractions',
        'museum' => 'museums',
        'park' => 'parks',
        'hotel' => 'hotels',
        'food' => 'restaurants and cafes',
        'shopping' => 'shopping',
        _ => category,
      };

  static String? _freeTypeForCategory(String category) =>
      <String, String>{
        'tourist_attraction': 'tourist_attraction',
        'tourist_places': 'tourist_places',
        'landmark': 'landmark',
        'museum': 'museum',
        'park': 'park',
        'hotel': 'hotel',
        'food': 'food',
        'shopping': 'shopping',
      }[category];

  static String _googleTypeForCategory(String category) => switch (category) {
        'tourist_attraction' => 'tourist_attraction',
        'tourist_places' => 'tourist_attraction',
        'landmark' => 'tourist_attraction',
        'museum' => 'museum',
        'park' => 'park',
        'hotel' => 'lodging',
        'food' => 'restaurant',
        'shopping' => 'store',
        _ => 'point_of_interest',
      };

  Future<List<Place>> _backendNearby(
    LatLng location,
    String type,
    double radiusMeters,
  ) async {
    final Map<String, dynamic> data = await _api.post('/placesSearch',
        <String, dynamic>{
      'location': <String, double>{
        'lat': location.latitude,
        'lng': location.longitude,
      },
      'radiusMeters': radiusMeters,
      'types': <String>[type],
    });
    return _decode(data);
  }

  /// Validates the compiled MapTiler key with a single geocoding request.
  Future<bool> mapTilerKeyValid() => _free.mapTilerKeyValid();

  Future<Place?> details(String placeId) async {
    try {
      final Map<String, dynamic> data =
          await _api.post('/placesDetails', <String, dynamic>{
        'placeId': placeId,
      });
      final dynamic p = data['place'];
      if (p is Map<String, dynamic>) return Place.fromJson(p);
      return null;
    } on ApiException {
      // Details need the backend (ratings/photos). Return null so the UI can
      // fall back to the summary it already has.
      return null;
    }
  }

  Future<List<Place>> emergencyNearby(LatLng location,
      {double radiusMeters = 5000}) async {
    try {
      final Map<String, dynamic> data =
          await _api.post('/emergencyNearby', <String, dynamic>{
        'location': <String, double>{
          'lat': location.latitude,
          'lng': location.longitude,
        },
        'radiusMeters': radiusMeters,
      });
      return _decode(data);
    } on ApiException {
      final List<Place> all = <Place>[];
      for (final String q in <String>['hospital', 'police station', 'pharmacy']) {
        try {
          final List<Place> found = await _free.searchPlaces(q, near: location);
          for (final Place p in found) {
            if (all.length >= 20) break;
            if (!all.any((Place e) => e.placeId == p.placeId)) all.add(p);
          }
        } catch (_) {}
      }
      return all;
    }
  }

  Future<RouteInfo> route(LatLng from, LatLng to, {String mode = 'car'}) =>
      _free.route(from, to, mode: mode);

  /// Strict OSRM routing for the "Get Directions" flow: real road distance,
  /// ETA and a full GeoJSON polyline. Unlike [route], this throws
  /// [OsrmException] on failure (NoRoute / NoSegment / network / invalid
  /// coordinates) so the UI can show a specific, actionable message instead
  /// of a silent straight-line estimate.
  Future<RouteInfo> osrmRoute(LatLng from, LatLng to, {String mode = 'car'}) =>
      _osrm.route(origin: from, destination: to, mode: mode);

  Future<String?> reverseGeocode(LatLng location) async {
    try {
      final Map<String, dynamic> data =
          await _api.post('/geocodeReverse', <String, dynamic>{
        'lat': location.latitude,
        'lng': location.longitude,
      });
      final String? label = data['label'] as String?;
      if (label != null && label.trim().isNotEmpty) return label.trim();
      return null;
    } on ApiException {
      return _free.reverseGeocode(location.latitude, location.longitude);
    }
  }

  /// Fetches a Places photo through the backend proxy (keeps the Google key
  /// server-side).
  Future<Uint8List> photoBytes(String photoUrl) => _api.getBytes(photoUrl);

  /// Free Wikipedia photo + short description for a page title. Used so place
  /// details show a real picture even when the backend is offline.
  Future<(String?, String?)> wikipediaSummary(String title) =>
      _free.wikipediaSummary(title);

  /// Free Wikipedia thumbnail by free-text search (for places without a wiki
  /// URL). Returns an image URL or null.
  Future<String?> wikipediaThumbnailBySearch(String query) =>
      _free.wikipediaThumbnailBySearch(query);

  /// Opens real turn-by-turn navigation on the device: native Google Maps
  /// navigation first, then the Maps deep link, then a geo: URI.
  Future<bool> openInGoogleMaps(double lat, double lng, String? name) async {
    final Uri nav = Uri.parse('google.navigation:q=$lat,$lng');
    if (await canLaunchUrl(nav)) {
      await launchUrl(nav, mode: LaunchMode.externalApplication);
      return true;
    }
    final Uri web = Uri.parse(
        'https://www.google.com/maps/dir/?api=1&destination=$lat,$lng');
    if (await canLaunchUrl(web)) {
      await launchUrl(web, mode: LaunchMode.externalApplication);
      return true;
    }
    final String label = name ?? 'destination';
    final Uri geo = Uri.parse(
        'geo:0,0?dlat=$lat&dlng=$lng&daddr=${Uri.encodeComponent(label)}');
    if (await canLaunchUrl(geo)) {
      await launchUrl(geo, mode: LaunchMode.externalApplication);
      return true;
    }
    return false;
  }

  /// Whether the backend base URL could be built (Firebase configured).
  bool get configured => _api.baseUrl.isNotEmpty;
}

/// Convenience: a stable, user-friendly error message for places errors.
String placesErrorMessage(Object e) {
  if (e is ApiException) {
    if (e.kind == ApiErrorKind.location) {
      return 'Your location is currently unavailable.';
    }
    return e.message;
  }
  return 'Could not load places. Please try again.';
}

/// Explore category chips: Attractions, Museums, Parks, Hotels, Food,
/// Shopping, Landmarks and Tourist places — each with an explicit OSM filter
/// mapping (see FreeGeoClient._typeFilters), never just a UI label.
const List<String> kExploreCategories = <String>[
  'tourist_attraction',
  'museum',
  'park',
  'hotel',
  'food',
  'shopping',
  'landmark',
  'tourist_places',
];

const Map<String, String> kExploreCategoryLabels = <String, String>{
  'tourist_attraction': 'Attractions',
  'museum': 'Museums',
  'park': 'Parks',
  'hotel': 'Hotels',
  'food': 'Food',
  'shopping': 'Shopping',
  'landmark': 'Landmarks',
  'tourist_places': 'Tourist places',
};
