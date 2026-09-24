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

  /// Set by [search] when the place the traveller named could not be found and
  /// the list below is actually the nearest places of that KIND. The UI shows
  /// it verbatim, so a substitution can never pass for an exact match.
  String? get lastSearchNote => _lastSearchNote;
  String? _lastSearchNote;

  /// The first word of [q] that describes a category of place (college,
  /// hospital, temple, …) rather than a name.
  String? _categoryWordIn(String q) {
    for (final String raw in q.toLowerCase().split(RegExp(r'[^a-z0-9]+'))) {
      if (raw.length < 3) continue;
      if (_free.isCategoryQuery(raw)) return raw;
    }
    return null;
  }

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

  /// [biasToUserLocation] decides whether the traveller's position is allowed
  /// to influence *which* places qualify. Explore turns it off for "Anywhere":
  /// searching beaches from Lucknow must still be able to return Goa. The
  /// position is then used only to sort and label results by distance — never
  /// as a search bias for the backend or a radius filter.
  Future<List<Place>> search(
    String query, {
    LatLng? location,
    double? radiusMeters,
    List<String>? types,
    bool forceFresh = false,
    bool biasToUserLocation = true,
    bool includeCategoryFallback = false,
  }) async {
    final String q = query.trim();
    // Cleared on every entry: a note left over from an earlier query must
    // never describe the rows of this one.
    _lastSearchNote = null;
    if (q.isEmpty) return const <Place>[];
    final double? biasRadius = biasToUserLocation ? radiusMeters : null;

    // Keep the verified local fallback for the (rare) case where every live
    // provider fails, but never mix it into live results — directory records
    // used to pollute accurate provider matches (reported: wrong places
    // shown above the real one).
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
        radiusMeters: biasRadius ?? 0.0,
        forceFresh: forceFresh,
      )),
      if (configured)
        (() async {
          try {
            final List<Place> places = await _backendSearch(
              q,
              biasToUserLocation ? location : null,
              biasRadius,
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
    final List<Place> allPlaces = <Place>[];
    for (final List<Place> batch in batches) {
      allPlaces.addAll(batch);
    }
    if (allPlaces.isEmpty) {
      // Every live provider failed — only now serve the verified local
      // fallback (it is marked `curated` so the UI can label it honestly).
      final List<Place> fallback = _lucknowFallback(q, location);
      if (fallback.isEmpty) return const <Place>[];
      final List<Place> rankedFallback =
          PlaceRanking.rankSuggestions(fallback, q, location);
      return rankedFallback;
    }

    final Map<String, Place> merged = <String, Place>{};
    for (final Place p in allPlaces) {
      final String key =
          '${p.name.toLowerCase().trim()}|${p.lat.toStringAsFixed(4)},${p.lng.toStringAsFixed(4)}';
      final Place? old = merged[key];
      if (old == null || _isRicherSuggestion(p, old)) merged[key] = p;
    }
    List<Place> out = merged.values.toList();
    if (out.isEmpty &&
        types != null &&
        types.isNotEmpty &&
        location != null) {
      // Category sweep (map chips: hospitals, parks, police…) came back
      // empty from Overpass and the backend proxy — fall back to the
      // keyless Photon reverse search so a busy Overpass mirror can never
      // blank out a category.
      final Set<String> datasetCats = <String>{};
      for (final String t in types) {
        datasetCats.addAll(_datasetCategoriesFor(t) ?? const <String>{});
      }
      if (datasetCats.isNotEmpty && biasToUserLocation) {
        try {
          final double radius =
              radiusMeters ?? FreeGeoClient.kNearbyRadiusMeters;
          final List<Place> photonPlaces = await _free
              .photonNearby(
                location,
                radiusMeters: radius,
                categories: datasetCats,
              )
              .timeout(const Duration(seconds: 10));
          for (final Place raw in photonPlaces) {
            final double distance =
                GeoUtils.distanceMeters(location, raw.coords);
            if (distance > radius) continue;
            final Place place = raw.copyWith(
              category: types.first,
              distanceMeters: raw.distanceMeters ?? distance,
            );
            out.add(place);
          }
        } catch (_) {
          // Photon also unavailable — an honest empty result.
        }
      }
    }
    // A CATEGORY search is radius-bound: results from another state are noise,
    // not "far away answers". A named-place search ("taj mahal") is NOT — the
    // real monument is 300 km away and the traveller still wants it.
    final bool categoryQuery = (types != null && types.isNotEmpty) ||
        _free.isCategoryQuery(q, types);
    if (location != null && categoryQuery && biasRadius != null) {
      final double cap = biasRadius;
      final List<Place> inside = out
          .where((Place p) => GeoUtils.distanceMeters(location, p.coords) <= cap)
          .toList();
      if (inside.isNotEmpty) out = inside;
    }

    // Accuracy and shortest distance first. The relevance filter removes
    // foreign/generic noise only after all real providers have been merged.
    if (location != null) {
      out = PlaceRanking.rankSuggestions(out, q, location);
      out = PlaceRanking.filterRelevant(out, q, location);
      // NOTE: an EMPTY relevance result is itself the honest answer. The old
      // `if (rel.isNotEmpty) out = rel;` fell back to the unfiltered list, so
      // a Lucknow search for "new public college" ended up showing "New Delhi"
      // and "Noida" — geocoder noise that had just been identified as
      // irrelevant was served right back to the user.
    }
    if (out.isEmpty && includeCategoryFallback && location != null) {
      // Nothing near the traveller carries the name they typed. The worst
      // answer is a city 400 km away; the second worst is a blank screen.
      // When the query names a KIND of place (school / college / hospital /
      // temple …), give them the real ones nearby and say plainly that this
      // is a category list, not their exact match.
      final String? category = _categoryWordIn(q);
      if (category != null) {
        final double r =
            radiusMeters ?? FreeGeoClient.kNearbyRadiusMeters;
        final List<Place> nearby = await _freeSearchWithCache(
          category,
          near: location,
          types: null,
          radiusMeters: r,
        );
        if (nearby.isNotEmpty) {
          _lastSearchNote = 'No place named “$q” was found within '
              '${(r / 1000).round()} km — these are $category places near you.';
          out = PlaceRanking.rankSuggestions(nearby, category, location);
        }
      }
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
    // Same rule as search(): never restore results the relevance filter has
    // already rejected as "different place entirely". Without a known GPS
    // position there is nothing to be relevant TO, so text ranking stands.
    final List<Place> usable = relevant.isNotEmpty
        ? relevant
        : (location == null
            ? ranked
            : ranked
                .where((Place p) =>
                    GeoUtils.distanceMeters(location, p.coords) <= 35000)
                .toList());
    final List<Place> result = usable.take(limit).toList();
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
    if (a.provider != 'curated' && b.provider == 'curated') return true;
    if (a.provider == 'curated' && b.provider != 'curated') return false;
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
    bool forceFresh = false,
  }) async {
    final String cacheKey = SearchCache.key(
      query,
      types,
      near?.latitude,
      near?.longitude,
      radiusMeters,
    );
    if (!forceFresh) {
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
      // for ordinary searches. A forced nearby fallback must stay live-only.
      if (!forceFresh &&
          (e.kind == ApiErrorKind.network ||
              e.kind == ApiErrorKind.timeout ||
              e.kind == ApiErrorKind.rateLimited ||
              e.kind == ApiErrorKind.server ||
              e.kind == ApiErrorKind.parser)) {
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
      {double radiusMeters = FreeGeoClient.kGroupedNearbyRadiusMeters,
      bool force = false}) {
    return _nearby.load(
      location,
      force: force,
      variant: 'core|r:${radiusMeters.round()}',
      // Keep the first Explore skeleton bounded even if an Overpass mirror
      // accepts the request but never completes it. The UI can then use its
      // honest multi-provider fallback path.
      // Empty result at the default radius → one widening retry (Overpass
      // groups + Photon both re-run at 25 km) so sparse-OSM areas never see
      // a bare "No places found nearby".
      fetch: () async {
        // The aggregate deadline has to sit ABOVE the per-provider budget
        // inside FreeGeoClient (22 s for an Overpass sweep). Bounding the
        // group at 20 s cancelled the whole dataset the moment one mirror
        // used its full allowance — including the Photon results that had
        // already arrived, which is how a partially working set of providers
        // ended up as a hard "providers are unavailable" error on screen.
        List<Place> places = await _free
            .nearbyAround(location, radiusMeters: radiusMeters)
            .timeout(const Duration(seconds: 26));
        if (places.isEmpty && radiusMeters < 25000) {
          places = await _free
              .nearbyAround(location, radiusMeters: 25000)
              .timeout(const Duration(seconds: 26));
        }
        return places;
      },
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
    bool freeFailed = false;
    bool backendFailed = false;

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
        ).timeout(const Duration(seconds: 24));
      } catch (_) {
        freeFailed = true;
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
        backendFailed = true;
        _recordBackendFailure();
        return const <Place>[];
      }
    }

    // Photon reverse runs IN PARALLEL with Overpass and the backend proxy:
    // a busy Overpass mirror ("server is probably too busy" — chronic on
    // the public instances) no longer blanks out or delays a category; the
    // fastest family that answers fills the list.
    Future<List<Place>> photonRequest() async {
      final Set<String>? datasetCats = _datasetCategoriesFor(category);
      if (datasetCats == null || datasetCats.isEmpty) {
        return const <Place>[];
      }
      try {
        return await _free
            .photonNearby(
              location,
              radiusMeters: radiusMeters,
              categories: datasetCats,
            )
            .timeout(const Duration(seconds: 10));
      } catch (_) {
        return const <Place>[];
      }
    }

    final List<List<Place>> batches = await Future.wait(<Future<List<Place>>>[
      freeRequest(),
      backendRequest(),
      photonRequest(),
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
    if (merged.isEmpty && freeFailed && (backendFailed || !configured)) {
      throw const ApiException(
        ApiErrorKind.network,
        'Nearby place providers are unavailable right now. Please retry.',
      );
    }
    final List<Place> out = merged.values.toList()
      ..sort((Place a, Place b) =>
          (a.distanceMeters ?? GeoUtils.distanceMeters(location, a.coords))
              .compareTo(b.distanceMeters ??
                  GeoUtils.distanceMeters(location, b.coords)));
    return out;
  }

  /// Semantic UI category / type id → FreeGeoClient dataset categories for
  /// the Photon reverse fallback.
  static Set<String>? _datasetCategoriesFor(String category) =>
      <String, Set<String>>{
        'food': const <String>{'restaurant', 'cafe', 'fast_food'},
        'restaurant': const <String>{'restaurant'},
        'cafe': const <String>{'cafe'},
        'fast_food': const <String>{'fast_food'},
        'tourist_attraction': const <String>{'attraction'},
        'tourist_places': const <String>{'attraction'},
        'landmark': const <String>{'attraction'},
        'shopping': const <String>{'shopping'},
        'hotel': const <String>{'hotel'},
        'museum': const <String>{'museum'},
        'park': const <String>{'park'},
        'hospital': const <String>{'hospital'},
        'police': const <String>{'police'},
        'police_station': const <String>{'police'},
        'fire_station': const <String>{'fire_station'},
        'pharmacy': const <String>{'pharmacy'},
        'atm': const <String>{'atm'},
        'fuel': const <String>{'fuel'},
        'gas_station': const <String>{'fuel'},
        'transit': const <String>{'transit'},
        'transit_station': const <String>{'transit'},
      }[category];

  static String _categoryQuery(String category) => switch (category) {
        'tourist_attraction' => 'tourist attractions',
        'tourist_places' => 'tourist attractions',
        'landmark' => 'tourist attractions',
        'museum' => 'museums',
        'park' => 'parks',
        'hotel' => 'hotels',
        'food' => 'restaurants and cafes',
        'hospital' => 'hospitals',
        'police' => 'police stations',
        'pharmacy' => 'pharmacies',
        'atm' => 'ATMs',
        'fuel' => 'fuel stations',
        'transit' => 'transit stations',
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
        'hospital': 'hospital',
        'police': 'police',
        'pharmacy': 'pharmacy',
        'atm': 'atm',
        'fuel': 'fuel',
        'transit': 'transit',
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
        'hospital' => 'hospital',
        'police' => 'police',
        'pharmacy' => 'pharmacy',
        'atm' => 'atm',
        'fuel' => 'gas_station',
        'transit' => 'transit_station',
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

  /// Full street/locality address for cross-app ride handoff. Do not replace
  /// this with [reverseGeocode]: that method deliberately returns a short city
  /// label for weather/home privacy, which provider destination search cannot
  /// locate precisely.
  Future<String?> reverseGeocodeAddress(LatLng location) async {
    final String? full = await _free
        .reverseGeocodeAddress(location.latitude, location.longitude);
    if (full != null && full.trim().isNotEmpty) return full.trim();
    return reverseGeocode(location);
  }

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

  /// Free Wikipedia photo + short description for a verified page title.
  /// Used so place details show a real picture even when the backend is
  /// offline.
  Future<(String?, String?)> wikipediaSummary(String title) =>
      _free.wikipediaSummary(title);

  /// Free Wikipedia thumbnail by exact title and nearby coordinates. It
  /// returns null rather than guessing when the search result is another place.
  Future<String?> wikipediaThumbnailBySearch(
    String query, {
    LatLng? near,
  }) =>
      _free.wikipediaThumbnailBySearch(query, near: near);

  /// Real photo for an OSM `wikidata=Q…` reference: the entity's own P18
  /// image from Wikimedia Commons. Belongs to this exact place by
  /// construction — the safest free image source there is.
  Future<String?> wikidataImage(String qid) => _free.wikidataImage(qid);

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
    // ApiException messages are already user-facing and actionable (e.g.
    // "Turn on location (GPS) to find 'school' near you." for location
    // errors) — show them verbatim.
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
