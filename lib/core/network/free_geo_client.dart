import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../data/models/places.dart';
import '../../data/models/weather.dart';
import '../app_config.dart';
import '../utils/geo.dart';
import 'api_exception.dart';
import 'nearby_debug.dart';
import 'osrm_client.dart';

/// Real, free (key-light) data clients used as a fallback when the Tourism
/// Cloud Functions backend is not deployed yet — so Explore, Map, Weather and
/// the Payment Guardian keep working on the device:
///
///   • MapTiler Geocoding (search + reverse) — uses the MapTiler key.
///   • Nominatim Geocoding (keyless) — second search fallback.
///   • Overpass API (keyless OpenStreetMap POIs) — first choice for
///     category searches ("hotels near me", hospitals, ATMs…).
///   • OSRM public router (real road routing, no key) — driving, walking
///     and cycling profiles.
///   • Open-Meteo (real weather, no key).
class FreeGeoClient {
  FreeGeoClient();

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 8),
    receiveTimeout: const Duration(seconds: 15),
    headers: <String, String>{
      // Overpass mirrors (kumi.systems, private.coffee, …) require a
      // descriptive User-Agent per their usage policy; without one they may
      // reject or aggressively rate-limit requests.
      'User-Agent': 'TourismApp/1.0 (Android travel & safety assistant)',
    },
  ));

  final Dio _nominatim = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 8),
    receiveTimeout: const Duration(seconds: 15),
    headers: <String, String>{
      // Nominatim requires a descriptive User-Agent (usage policy).
      'User-Agent': 'TourismApp/1.0 (Android travel & safety assistant)',
    },
  ));

  String get _mtKey => AppConfig.mapTilerApiKey;

  /// Default radius (metres) for the grouped nearby / essentials dataset.
  /// Covers a whole metro area (not just the old 10 km) while staying inside
  /// Overpass's fair-use envelope; results are re-sorted nearest-first.
  static const double kNearbyRadiusMeters = 25000;

  /// Nominatim rate-limit guard: public Nominatim allows at most 1 req/sec.
  /// Shared per process so debounced typing can never exceed it.
  static DateTime? _lastNominatimAt;

  /// Overpass is a shared public service: throttle every request so several
  /// screens mounting at once can never fire a burst of duplicate queries.
  /// This (plus the cache) is the actual fix for the frequent 429
  /// "Nearby search is temporarily limited" errors.
  static DateTime? _lastOverpassAt;
  static const Duration _overpassMinGap = Duration(milliseconds: 350);

  /// Public Overpass instances, in preference order. Multiple mirrors spread
  /// load so a single "too busy" server can never kill the nearby feature —
  /// verified reachable and returning valid OSM JSON as of 2026-09-13.
  static const List<String> _overpassHosts = <String>[
    'https://overpass-api.de/api/interpreter',
    'https://overpass.kumi.systems/api/interpreter',
    'https://overpass.private.coffee/api/interpreter',
  ];

  /// Per-host rate-limit cooldown (host → earliest allowed retry time). When
  /// a mirror returns 429 it tells us exactly when its slot opens again; we
  /// honour that hint and route around the busy mirror instead of hammering
  /// it or flat-waiting globally.
  static final Map<String, DateTime> _overpassCooldown =
      <String, DateTime>{};

  /// Round-robin cursor so concurrent requests (the two grouped nearby
  /// queries) START on different mirrors instead of piling onto one host.
  static int _overpassRoundRobin = 0;

  /// In-flight dedup: identical Overpass query → one shared Future, so
  /// concurrent components never send the same request twice.
  static final Map<String, Future<_ProviderResult>> _overpassInFlight =
      <String, Future<_ProviderResult>>{};

  /// Monotonic request counter for the `[places] overpass req#N` dev logs —
  /// lets a tester count real network hits (to prove cache hits don't refire
  /// the provider). Reset on process restart.
  static int _overpassRequestCount = 0;

  /// Category keyword → Overpass tag filters. Overpass gives far better
  /// "nearby hotels / hospitals / ATMs" results than free geocoding.
  static const Map<String, List<(String, String)>> _categoryFilters =
      <String, List<(String, String)>>{
    'hotel': <(String, String)>[('tourism', 'hotel|hostel|guest_house|motel')],
    'hostel': <(String, String)>[('tourism', 'hostel')],
    'restaurant': <(String, String)>[('amenity', 'restaurant')],
    'food': <(String, String)>[('amenity', 'restaurant|fast_food|cafe')],
    'cafe': <(String, String)>[('amenity', 'cafe')],
    'fast_food': <(String, String)>[('amenity', 'fast_food')],
    'park': <(String, String)>[('leisure', 'park')],
    'museum': <(String, String)>[('tourism', 'museum')],
    'attraction': <(String, String)>[('tourism', 'attraction')],
    'tourist': <(String, String)>[('tourism', 'attraction')],
    'hospital': <(String, String)>[('amenity', 'hospital|clinic')],
    'police': <(String, String)>[('amenity', 'police')],
    'fire': <(String, String)>[('amenity', 'fire_station')],
    'pharmacy': <(String, String)>[('amenity', 'pharmacy')],
    'mall': <(String, String)>[('shop', 'mall')],
    'shopping': <(String, String)>[('shop', 'mall')],
    'atm': <(String, String)>[('amenity', 'atm')],
    'fuel': <(String, String)>[('amenity', 'fuel')],
    'petrol': <(String, String)>[('amenity', 'fuel')],
    'bank': <(String, String)>[('amenity', 'bank')],
    'bus': <(String, String)>[
      ('amenity', 'bus_station'),
      ('railway', 'station'),
    ],
    'transit': <(String, String)>[
      ('amenity', 'bus_station'),
      ('railway', 'station'),
      ('amenity', 'ferry_terminal'),
      ('highway', 'bus_stop'),
      ('public_transport', 'platform'),
      ('public_transport', 'stop_position'),
    ],
    'station': <(String, String)>[
      ('amenity', 'bus_station'),
      ('railway', 'station'),
    ],
    'landmark': <(String, String)>[
      ('tourism', 'attraction|viewpoint|monument|memorial'),
      ('historic', 'castle|monument|memorial|fort|ruins|archaeological_site|tower|manor'),
    ],
    'temple': <(String, String)>[('amenity', 'place_of_worship')],
    'mosque': <(String, String)>[('amenity', 'place_of_worship')],
    'church': <(String, String)>[('amenity', 'place_of_worship')],
    'zoo': <(String, String)>[('tourism', 'zoo')],
  };

  /// Maps Google-style type ids to category filters.
  static const Map<String, List<(String, String)>> _typeFilters =
      <String, List<(String, String)>>{
    'hospital': <(String, String)>[('amenity', 'hospital|clinic')],
    'police': <(String, String)>[('amenity', 'police')],
    'police_station': <(String, String)>[('amenity', 'police')],
    'fire_station': <(String, String)>[('amenity', 'fire_station')],
    'pharmacy': <(String, String)>[('amenity', 'pharmacy')],
    'cafe': <(String, String)>[('amenity', 'cafe')],
    'restaurant': <(String, String)>[('amenity', 'restaurant')],
    'food': <(String, String)>[('amenity', 'restaurant|fast_food|cafe')],
    'fast_food': <(String, String)>[('amenity', 'fast_food')],
    'hotel': <(String, String)>[('tourism', 'hotel|hostel|guest_house|motel')],
    'park': <(String, String)>[('leisure', 'park')],
    'museum': <(String, String)>[('tourism', 'museum')],
    'transit': <(String, String)>[
      ('amenity', 'bus_station'),
      ('railway', 'station'),
      ('amenity', 'ferry_terminal'),
      ('highway', 'bus_stop'),
      ('public_transport', 'platform'),
      ('public_transport', 'stop_position'),
    ],
    'fuel': <(String, String)>[('amenity', 'fuel')],
    'tourist_attraction': <(String, String)>[
      ('tourism', 'attraction|museum|gallery|viewpoint|zoo|theme_park|aquarium'),
      ('historic', '.*'),
      ('natural', '.*'),
      ('leisure', 'park|garden|nature_reserve'),
      ('amenity', 'place_of_worship'),
    ],
    'tourist_places': <(String, String)>[
      ('tourism', 'attraction|museum|gallery|viewpoint|zoo|theme_park|aquarium'),
      ('historic', '.*'),
      ('natural', '.*'),
      ('leisure', 'park|garden|nature_reserve'),
      ('amenity', 'place_of_worship'),
    ],
    'landmark': <(String, String)>[
      ('tourism', 'attraction|viewpoint|monument|memorial'),
      ('historic', '.*'),
    ],
    'shopping_mall': <(String, String)>[('shop', 'mall')],
    'shopping': <(String, String)>[('shop', '.*')],
    'atm': <(String, String)>[('amenity', 'atm')],
  };

  // ---------------------------------------------------------------------
  // Search: Overpass (categories) → MapTiler → Nominatim
  // ---------------------------------------------------------------------

  Future<List<Place>> searchPlaces(
    String query, {
    LatLng? near,
    List<String>? types,
    double radiusMeters = kNearbyRadiusMeters,
    bool filterToRadius = false,
  }) async {
    final String q = query.trim();
    final List<(String, String)>? filters = _filtersFor(q, types);

    // A requested category/type we have no mapping for is an unsupported
    // category — an honest, distinct outcome, never "nothing found".
    if (types != null && filters == null) {
      throw const ApiException(
        ApiErrorKind.validation,
        'This category is not supported yet.',
        retryable: false,
      );
    }

    // Bulk category / nearby-POI search (Nearby Essentials, Explore category
    // chips, map layers): Overpass is the primary bulk engine. MapTiler
    // geocoding is reserved for text/place search (types == null) and is NOT
    // used here — text-geocoding a generic keyword like "hospital" returns a
    // handful of name matches, not a 10 km radius sweep.
    if (types != null) {
      if (near == null) {
        throw const ApiException(
          ApiErrorKind.location,
          'Your location is needed to search nearby places.',
          retryable: false,
        );
      }
      return _nearbyPois(
        filters!,
        near,
        radiusMeters,
        attraction: _isAttractionQuery(q, types),
      );
    }

    // Free-text search: run every provider IN PARALLEL and MERGE. A
    // sparse/failed Overpass response never hides what MapTiler/Photon/
    // Nominatim found, and vice-versa.
    final bool attraction = _isAttractionQuery(q, types);
    final List<_ProviderResult> results = await Future.wait(<Future<_ProviderResult>>[
      if (filters != null && near != null)
        _guard('overpass', () => _overpass(filters, near, radiusMeters))
      else
        Future<_ProviderResult>.value(_ProviderResult.skipped('overpass')),
      if (attraction && near != null)
        _guard('wikipedia', () => _wikipediaNearby(near, radiusMeters))
      else
        Future<_ProviderResult>.value(_ProviderResult.skipped('wikipedia')),
      if (AppConfig.mapTilerConfigured)
        _guard('maptiler', () => _maptilerSearch(q, near))
      else
        Future<_ProviderResult>.value(_ProviderResult.skipped('maptiler')),
      _guard('photon', () => _photonSearch(q, near)),
      _guard('nominatim', () => _nominatimSearch(q, near)),
    ]);

    List<Place> out = _mergeAndDedup(results);
    if (near != null) {
      out.sort((Place a, Place b) => GeoUtils.distanceMeters(near, a.coords)
          .compareTo(GeoUtils.distanceMeters(near, b.coords)));
      if (filterToRadius && radiusMeters > 0) {
        out = out
            .where((Place p) =>
                GeoUtils.distanceMeters(near, p.coords) <= radiusMeters + 20)
            .toList();
      }
    }
    debugPrint('[places] query="$q" providers='
        '${results.map((_ProviderResult r) => '${r.provider}:${r.raw}/${r.parsed}').join(', ')} '
        'final=${out.length}');
    if (out.isNotEmpty) return out;

    // Nothing returned — classify the failure honestly instead of silently
    // returning [] (which would masquerade as "no places found").
    final bool anyResponded = results.any((_ProviderResult r) => r.responded);
    final Set<ApiErrorKind> errs = <ApiErrorKind>{
      for (final _ProviderResult r in results)
        if (r.error != null) r.error!,
    };
    if (!anyResponded) {
      if (errs.contains(ApiErrorKind.rateLimited)) {
        throw const ApiException(ApiErrorKind.rateLimited,
            'Nearby search is temporarily limited. Try again shortly.');
      }
      if (errs.contains(ApiErrorKind.unauthorized) &&
          !errs.contains(ApiErrorKind.network)) {
        throw const ApiException(ApiErrorKind.unauthorized,
            'The place/map service key was rejected. Please check the key and rebuild the app.',
            retryable: false);
      }
      if (errs.contains(ApiErrorKind.network) ||
          errs.contains(ApiErrorKind.timeout)) {
        throw const ApiException(ApiErrorKind.network,
            'Unable to load nearby places. Check your internet connection.');
      }
      throw const ApiException(ApiErrorKind.server,
          'Search is temporarily unreachable. Check your internet '
          'connection and try again.');
    }
    return const <Place>[]; // Providers responded, genuinely zero results.
  }

  /// Bulk nearby-POI search for a category (types != null).
  ///
  /// Overpass is the primary engine (real OSM POIs). Wikipedia GeoSearch
  /// supplements attraction categories only. Raw POIs are parsed, then
  /// deduplicated, filtered to the exact radius and sorted nearest→farthest.
  /// A provider / network / rate-limit failure throws a typed error; only a
  /// genuine "providers responded with nothing" returns an empty list.
  Future<List<Place>> _nearbyPois(
    List<(String, String)> filters,
    LatLng near,
    double radiusMeters, {
    bool attraction = false,
  }) async {
    final List<_ProviderResult> results =
        await Future.wait(<Future<_ProviderResult>>[
      _guard('overpass', () => _overpass(filters, near, radiusMeters)),
      if (attraction)
        _guard('wikipedia', () => _wikipediaNearby(near, radiusMeters))
      else
        Future<_ProviderResult>.value(_ProviderResult.skipped('wikipedia')),
    ]);

    // 3) parse (already done by the provider) → dedup → 4) actual distance
    //    from the user → 5) drop anything beyond the radius → 6) nearest
    //    first.
    final double radius = radiusMeters <= 0 ? kNearbyRadiusMeters : radiusMeters;
    final List<Place> out = _mergeAndDedup(results)
        .where((Place p) => GeoUtils.distanceMeters(near, p.coords) <= radius)
        .toList()
      ..sort((Place a, Place b) => GeoUtils.distanceMeters(near, a.coords)
          .compareTo(GeoUtils.distanceMeters(near, b.coords)));

    debugPrint('[places] nearby providers='
        '${results.map((_ProviderResult r) => '${r.provider}:${r.raw}/${r.parsed}').join(', ')} '
        'radius=${radius.round()}m final=${out.length}');
    if (out.isNotEmpty) return out;

    // Nothing within the radius — classify the failure honestly instead of
    // returning [] for every error.
    final bool anyResponded = results.any((_ProviderResult r) => r.responded);
    final Set<ApiErrorKind> errs = <ApiErrorKind>{
      for (final _ProviderResult r in results)
        if (r.error != null) r.error!,
    };
    if (!anyResponded) {
      if (errs.contains(ApiErrorKind.rateLimited)) {
        throw const ApiException(ApiErrorKind.rateLimited,
            'Nearby search is temporarily limited. Try again shortly.');
      }
      if (errs.contains(ApiErrorKind.network) ||
          errs.contains(ApiErrorKind.timeout)) {
        throw const ApiException(ApiErrorKind.network,
            'Unable to load nearby places. Check your internet connection.');
      }
      throw const ApiException(ApiErrorKind.server,
          'Nearby search is temporarily unavailable. Please try again.');
    }
    return const <Place>[]; // Genuinely zero results within the radius.
  }

  /// Autocomplete suggestions while typing. MapTiler Geocoding (which
  /// permits autocomplete) + Photon (OSM POI autocomplete — much stronger
  /// for SMALL local places like shops, guest houses, chaurahas that MapTiler
  /// does not know). Results are merged and ranked LOCALITY-FIRST: the
  /// user's own city/region before other cities, states and countries, and
  /// within the same area, exact → prefix → substring matches first.
  /// Public Nominatim is never used here (it forbids autocomplete).
  Future<List<Place>> suggest(String query, {LatLng? near, int limit = 8}) async {
    final String q = query.trim();
    if (q.isEmpty) return const <Place>[];

    final List<_ProviderResult> results =
        await Future.wait(<Future<_ProviderResult>>[
      if (AppConfig.mapTilerConfigured)
        _guard('maptiler-suggest', () => _maptilerSearch(q, near,
            limit: near != null ? limit.clamp(8, 10).toInt() : limit))
      else
        Future<_ProviderResult>.value(_ProviderResult.skipped('maptiler')),
      _guard('photon-suggest', () => _photonSearch(q, near)),
    ]);

    List<Place> merged = _mergeAndDedup(results);
    if (merged.isEmpty) {
      // Nothing from the geocoders — keyword fallback (category queries like
      // "atm", "railway station") against the local Overpass dataset.
      final List<(String, String)>? filters = _filtersFor(q, null);
      if (filters != null && near != null) {
        final _ProviderResult r = await _overpass(filters, near, 10000);
        if (r.places.isNotEmpty) {
          return _rankByDistance(r.places, near).take(limit).toList();
        }
      }
    } else {
      return _rankSuggestions(merged, q, near).take(limit).toList();
    }

    // Nothing responded at all — surface the honest error (same wording as
    // the full search) instead of pretending "no results".
    final bool anyResponded = results.any((_ProviderResult r) => r.responded);
    final Set<ApiErrorKind> errs = <ApiErrorKind>{
      for (final _ProviderResult r in results)
        if (r.error != null) r.error!,
    };
    if (!anyResponded) {
      if (errs.contains(ApiErrorKind.rateLimited)) {
        throw const ApiException(ApiErrorKind.rateLimited,
            'Search is temporarily limited. Try again shortly.');
      }
      if (errs.contains(ApiErrorKind.unauthorized)) {
        throw const ApiException(ApiErrorKind.unauthorized,
            'The place search key was rejected. Please check the key and rebuild the app.',
            retryable: false);
      }
      if (errs.contains(ApiErrorKind.network) ||
          errs.contains(ApiErrorKind.timeout)) {
        throw const ApiException(ApiErrorKind.network,
            'Search is temporarily unreachable. Check your internet '
            'connection and try again.');
      }
      throw const ApiException(ApiErrorKind.server,
          'Search is temporarily unreachable. Check your internet '
          'connection and try again.');
    }
    return const <Place>[];
  }

  /// Suggestion ranking: LOCALITY FIRST (own area ≤25 km → ≤100 km → ≤500 km
  /// → everywhere else), and within the same area, match quality: exact name
  /// → starts-with → word-boundary → substring. So typing while sitting in
  /// Zamania/Varanasi surfaces the local match before a same-named place in
  /// another state or country.
  List<Place> _rankSuggestions(List<Place> places, String q, LatLng? near) {
    int matchScore(Place p) {
      final String n = p.name.toLowerCase();
      final String t = q.toLowerCase();
      if (n == t) return 0;
      if (n.startsWith(t)) return 1;
      final Pattern boundary = RegExp('\\b${RegExp.escape(t)}');
      if (n.containsMatch(boundary)) return 2;
      if (n.contains(t)) return 3;
      return 4;
    }

    int distanceBucket(Place p) {
      if (near == null) return 1;
      final double d = GeoUtils.distanceMeters(near, p.coords);
      if (d <= 25000) return 0; // own city / tehsil area
      if (d <= 100000) return 1; // own region
      if (d <= 500000) return 2; // own state-ish
      return 3; // other state / country
    }

    final List<Place> out = List<Place>.from(places)
      ..sort((Place a, Place b) {
        final int bucket = distanceBucket(a) - distanceBucket(b);
        if (bucket != 0) return bucket;
        final int match = matchScore(a) - matchScore(b);
        if (match != 0) return match;
        if (near != null) {
          return GeoUtils.distanceMeters(near, a.coords)
              .compareTo(GeoUtils.distanceMeters(near, b.coords));
        }
        return 0;
      });
    return out;
  }

  /// Re-orders candidates nearest-first relative to [near] (when known), so a
  /// location search always suggests the closest match first.
  List<Place> _rankByDistance(List<Place> places, LatLng? near) {
    if (near == null) return places;
    final List<Place> out = List<Place>.from(places)
      ..sort((Place a, Place b) => GeoUtils.distanceMeters(near, a.coords)
          .compareTo(GeoUtils.distanceMeters(near, b.coords)));
    return out;
  }

  /// Runs [fn] and normalises every failure mode into a [_ProviderResult]
  /// (success/empty/network/rate-limit/unauthorized/server), logging a
  /// sanitized diagnostic line per provider (never the API key).
  Future<_ProviderResult> _guard(
    String provider,
    Future<_ProviderResult> Function() fn,
  ) async {
    final Stopwatch sw = Stopwatch()..start();
    try {
      final _ProviderResult r = await fn();
      sw.stop();
      debugPrint('[places] $provider raw=${r.raw} parsed=${r.parsed} '
          'responded=${r.responded} err=${r.error?.name ?? '-'} '
          '${sw.elapsedMilliseconds}ms');
      return r;
    } on DioException catch (e) {
      sw.stop();
      final ApiErrorKind k = _kindOf(e);
      debugPrint('[places] $provider HTTP ${e.response?.statusCode} '
          'err=${k.name} ${sw.elapsedMilliseconds}ms');
      return _ProviderResult(
          provider: provider, places: const <Place>[], responded: false, error: k, raw: 0);
    } on ApiException catch (e) {
      sw.stop();
      debugPrint('[places] $provider err=${e.kind.name} ${sw.elapsedMilliseconds}ms');
      return _ProviderResult(
          provider: provider, places: const <Place>[], responded: false, error: e.kind, raw: 0);
    } catch (e) {
      sw.stop();
      debugPrint('[places] $provider unexpected=${e.runtimeType} ${sw.elapsedMilliseconds}ms');
      return _ProviderResult(
          provider: provider, places: const <Place>[], responded: false, error: ApiErrorKind.server, raw: 0);
    }
  }

  /// Maps a Dio exception to a typed error kind.
  ApiErrorKind _kindOf(DioException e) {
    final int? code = e.response?.statusCode;
    if (code == 401 || code == 403) return ApiErrorKind.unauthorized;
    if (code == 429) return ApiErrorKind.rateLimited;
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return ApiErrorKind.timeout;
      case DioExceptionType.connectionError:
        return ApiErrorKind.network;
      default:
        return ApiErrorKind.server;
    }
  }

  /// Merges provider results and deduplicates by normalized name + rounded
  /// coordinates (a small geographic tolerance), keeping the richest record.
  List<Place> _mergeAndDedup(List<_ProviderResult> results) {
    final Map<String, Place> byKey = <String, Place>{};
    for (final _ProviderResult r in results) {
      for (final Place p in r.places) {
        final String key = _dedupKey(p);
        final Place? existing = byKey[key];
        if (existing == null || _isRicher(p, existing)) byKey[key] = p;
      }
    }
    return byKey.values.toList();
  }

  static String _dedupKey(Place p) {
    final String name = p.name.trim().toLowerCase();
    final String coord = '${p.lat.toStringAsFixed(4)},${p.lng.toStringAsFixed(4)}';
    return '$name|$coord';
  }

  static bool _isRicher(Place a, Place b) {
    int score(Place p) =>
        (p.address != null && p.address!.isNotEmpty ? 1 : 0) +
        (p.phone != null && p.phone!.isNotEmpty ? 1 : 0) +
        (p.website != null && p.website!.isNotEmpty ? 1 : 0) +
        (p.rating != null ? 1 : 0) +
        (p.photoUrls.isNotEmpty ? 1 : 0);
    return score(a) > score(b);
  }

  List<(String, String)>? _filtersFor(String query, List<String>? types) {
    if (types != null) {
      for (final String t in types) {
        final List<(String, String)>? f = _typeFilters[t];
        if (f != null) return f;
      }
    }
    final String q = query
        .toLowerCase()
        .replaceAll('near me', ' ')
        .replaceAll('near here', ' ')
        .replaceAll('nearby', ' ')
        .trim();
    if (q.isEmpty) return null;
    // Broad attraction-style queries (the Explore default "nearby") map to the
    // full tourism/historic/natural filter, not just `tourism=attraction`.
    if (q.contains('attraction') ||
        q.contains('tourist') ||
        q.contains('sightsee') ||
        q.contains('landmark') ||
        q.contains('hidden') ||
        q.contains('gem') ||
        q.contains('things to do') ||
        q.contains('places to visit')) {
      return _attractionFilters;
    }
    for (final MapEntry<String, List<(String, String)>> e
        in _categoryFilters.entries) {
      if (q.contains(e.key)) return e.value;
    }
    return null;
  }

  /// Broad "attractions" filter: tourism attractions + historic sites +
  /// natural places (`historic=*` + `natural=*`), matching the Explore
  /// "Attractions / Tourist places" category mapping.
  static const List<(String, String)> _attractionFilters =
      <(String, String)>[
    ('tourism', 'attraction|museum|gallery|viewpoint|zoo|theme_park|aquarium'),
    ('historic', '.*'),
    ('natural', '.*'),
    ('leisure', 'park|garden|nature_reserve'),
    ('amenity', 'place_of_worship'),
  ];

  bool _isAttractionQuery(String q, List<String>? types) {
    if (types != null) {
      return types.contains('tourist_attraction') ||
          types.contains('tourist_places') ||
          types.contains('landmark');
    }
    final String s = q
        .toLowerCase()
        .replaceAll('near me', ' ')
        .replaceAll('near here', ' ')
        .replaceAll('nearby', ' ')
        .trim();
    return s.contains('attraction') ||
        s.contains('famous') ||
        s.contains('things to do') ||
        s.contains('hidden') ||
        s.contains('gem') ||
        s.contains('tourist') ||
        s.contains('landmark') ||
        s.contains('sightsee') ||
        s.contains('places to visit');
  }

  /// Wikipedia GeoSearch: real encyclopaedia articles with coordinates near
  /// the user — the best free "famous places near me" source for towns where
  /// OSM tourism data is thin. Returns 0–20 results.
  Future<_ProviderResult> _wikipediaNearby(LatLng near, double radiusMeters) async {
    final int radius =
        (radiusMeters <= 0 ? 5000 : radiusMeters).round().clamp(10, 10000).toInt();
    // ONE combined request: geosearch (coordinates) + categories, so we can
    // keep only real sightseeing topics (a village, college or medical
    // university has no tourism category) without a second round-trip.
    final Response<dynamic> resp = await _dio.get<dynamic>(
      'https://en.wikipedia.org/w/api.php',
      queryParameters: <String, dynamic>{
        'action': 'query',
        'generator': 'geosearch',
        'ggscoord': '${near.latitude}|${near.longitude}',
        'ggsradius': radius,
        'ggslimit': 40,
        'prop': 'coordinates|categories',
        'cllimit': 'max',
        'format': 'json',
      },
    );
    final Object? data = resp.data;
    if (data is! Map) {
      return _ProviderResult(
          provider: 'wikipedia', places: const <Place>[], responded: true, error: null, raw: 0);
    }
    final Object? query = data['query'];
    if (query is! Map || query['pages'] is! Map) {
      return _ProviderResult(
          provider: 'wikipedia', places: const <Place>[], responded: true, error: null, raw: 0);
    }
    final List<Map> pages = (query['pages'] as Map).values
        .whereType<Map>()
        .toList()
      ..sort((Map a, Map b) {
        final int ai = (a['index'] as num?)?.toInt() ?? 0;
        final int bi = (b['index'] as num?)?.toInt() ?? 0;
        return ai.compareTo(bi);
      });
    final List<Place> out = <Place>[];
    for (final Map page in pages) {
      final String title = (page['title'] as String?) ?? '';
      if (title.isEmpty || _isNonTouristTitle(title.toLowerCase())) continue;
      // Keep only pages that belong to a tourism category.
      final Object? cats = page['categories'];
      bool tourism = false;
      if (cats is List) {
        for (final dynamic c in cats) {
          if (c is Map && _isTourismCategory((c['title'] as String?) ?? '')) {
            tourism = true;
            break;
          }
        }
      }
      if (!tourism) continue;
      final Object? coords = page['coordinates'];
      double? lat;
      double? lon;
      if (coords is List && coords.isNotEmpty && coords.first is Map) {
        lat = ((coords.first as Map)['lat'] as num?)?.toDouble();
        lon = ((coords.first as Map)['lon'] as num?)?.toDouble();
      }
      if (lat == null || lon == null) continue;
      final double dist =
          GeoUtils.distanceMetersLL(near.latitude, near.longitude, lat, lon);
      out.add(Place(
        placeId: 'wiki-${page['pageid'] ?? title.hashCode}',
        name: title,
        lat: lat,
        lng: lon,
        address: 'Wikipedia · ${_distLabel(dist)}',
        primaryType: 'tourist_attraction',
        types: const <String>['tourist_attraction', 'point_of_interest'],
        website:
            'https://en.wikipedia.org/wiki/${Uri.encodeComponent(title.replaceAll(' ', '_'))}',
      ));
    }
    return _ProviderResult(
      provider: 'wikipedia',
      places: out,
      responded: true,
      error: null,
      raw: pages.length,
    );
  }

  static bool _isNonTouristTitle(String t) {
    return t.contains('constituency') ||
        t.contains('lok sabha') ||
        t.contains('vidhan sabha') ||
        t.contains('assembly') ||
        t.contains('district') ||
        t.contains('division') ||
        t.contains('subdivision') ||
        t.contains('tehsil') ||
        t.contains('block (') ||
        t.contains('village') ||
        t.contains('census') ||
        t.contains('university') ||
        t.contains('college') ||
        t.contains('school') ||
        t.contains('institute') ||
        t.contains('institution') ||
        t.contains('hospital') ||
        t.contains('medical') ||
        t.contains('railway station') ||
        t.contains('railway line') ||
        t.contains('station') ||
        t.contains('airport') ||
        t.contains('police') ||
        t.contains('court') ||
        t.contains('prison') ||
        t.contains('post office');
  }

  static bool _isTourismCategory(String cat) {
    final String c = cat.toLowerCase();
    const List<String> keywords = <String>[
      'tourist attraction',
      'temple',
      'mosque',
      'church',
      'gurudwara',
      'dargah',
      'shrine',
      'monastery',
      'museum',
      'fort',
      'palace',
      'monument',
      'memorial',
      'mausoleum',
      'tomb',
      'lake',
      'waterfall',
      'park',
      'garden',
      'zoo',
      'cave',
      'stupa',
      'archaeological',
      'heritage',
      'sanctuary',
      'national park',
      'ghat',
      'dam',
      'beach',
      'island',
      'hill station',
      'viewpoint',
    ];
    return keywords.any((String k) => c.contains(k));
  }

  static String _distLabel(double meters) {
    if (meters < 1000) return '${meters.round()} m away';
    return '${(meters / 1000).toStringAsFixed(1)} km away';
  }

  /// Wikipedia REST summary for a page title → (thumbnail URL, description).
  /// Gives real photos + a short intro for famous places, entirely free.
  Future<(String?, String?)> wikipediaSummary(String title) async {
    try {
      final Response<dynamic> resp = await _dio.get<dynamic>(
        'https://en.wikipedia.org/api/rest_v1/page/summary/'
        '${Uri.encodeComponent(title.replaceAll(' ', '_'))}',
      );
      final Object? data = resp.data;
      if (data is! Map) return (null, null);
      String? image;
      final Object? thumb = data['thumbnail'];
      if (thumb is Map && thumb['source'] is String) {
        image = thumb['source'] as String;
      }
      String? extract = data['extract'] as String?;
      if (extract != null && extract.length > 400) {
        extract = '${extract.substring(0, 400)}…';
      }
      return (image, extract);
    } catch (_) {
      return (null, null);
    }
  }

  /// Finds a thumbnail image by searching Wikipedia for [query] — used for
  /// places that don't already carry a Wikipedia URL (hotels, landmarks…).
  Future<String?> wikipediaThumbnailBySearch(String query) async {
    try {
      final Response<dynamic> resp = await _dio.get<dynamic>(
        'https://en.wikipedia.org/w/api.php',
        queryParameters: <String, dynamic>{
          'action': 'query',
          'generator': 'search',
          'gsrsearch': query,
          'gsrlimit': 3,
          'prop': 'pageimages',
          'piprop': 'thumbnail',
          'pithumbsize': 800,
          'format': 'json',
          'redirects': 1,
        },
      );
      final Object? data = resp.data;
      if (data is! Map) return null;
      final Object? queryObj = data['query'];
      if (queryObj is! Map || queryObj['pages'] is! Map) return null;
      for (final dynamic page in (queryObj['pages'] as Map).values) {
        if (page is! Map) continue;
        final Object? thumb = page['thumbnail'];
        if (thumb is Map && thumb['source'] is String) {
          return thumb['source'] as String;
        }
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// One-request check of the compiled MapTiler key (geocoding endpoint).
  /// Returns false only when MapTiler explicitly rejects the key (401/403 or
  /// an "Invalid key" payload). A network failure is rethrown so callers do
  /// not mistake "offline" for "bad key".
  Future<bool> mapTilerKeyValid() async {
    if (!AppConfig.mapTilerConfigured) return false;
    try {
      final Response<dynamic> resp = await _dio.get<dynamic>(
        'https://api.maptiler.com/geocoding/${Uri.encodeComponent('museum')}.json',
        queryParameters: <String, dynamic>{'key': _mtKey, 'limit': 1},
      );
      final Object? data = resp.data;
      if (data is Map && data['features'] is List) return true;
      if (data is String && data.toLowerCase().contains('invalid key')) {
        return false;
      }
      return false;
    } on DioException catch (e) {
      final int? code = e.response?.statusCode;
      if (code == 401 || code == 403) return false;
      rethrow;
    }
  }

  /// MapTiler geocoding. NOTE: the API only accepts `limit` values 1–10 —
  /// anything higher returns 400 and the whole search used to "fail"
  /// silently (tiles kept working, search never returned anything).
  Future<_ProviderResult> _maptilerSearch(String q, LatLng? near,
      {int limit = 10}) async {
    final Map<String, dynamic> qp = <String, dynamic>{
      'key': _mtKey,
      'limit': limit.clamp(1, 10).toInt(),
    };
    if (near != null) qp['proximity'] = '${near.longitude},${near.latitude}';
    final Response<dynamic> resp = await _dio.get<dynamic>(
      'https://api.maptiler.com/geocoding/${Uri.encodeComponent(q)}.json',
      queryParameters: qp,
    );
    final Object? data = resp.data;
    // MapTiler sometimes returns 200 with an "Invalid key" body — treat it
    // as an explicit rejection so it never masquerades as "no results".
    if (data is String && data.toLowerCase().contains('invalid key')) {
      throw const ApiException(ApiErrorKind.unauthorized,
          'The place search key was rejected.', retryable: false);
    }
    final List<dynamic> feats = _features(data);
    return _ProviderResult(
      provider: 'maptiler',
      places: _parseGeocoding(data),
      responded: true,
      error: null,
      raw: feats.length,
    );
  }

  /// Photon (photon.komoot.io) — free, keyless OpenStreetMap geocoder.
  /// Excellent at partial/locality queries like "transport nagar" and an
  /// independent third provider so text search never depends on a single
  /// service being reachable.
  Future<_ProviderResult> _photonSearch(String q, LatLng? near) async {
    final Map<String, dynamic> qp = <String, dynamic>{
      'q': q,
      'limit': 15,
      'lang': 'en',
    };
    if (near != null) {
      qp['lat'] = near.latitude;
      qp['lon'] = near.longitude;
      // Bias radius: street-level weighting so local POIs outrank distant
      // same-named places in the provider's own ranking too.
      qp['zoom'] = 16;
    }
    final Response<dynamic> resp = await _dio
        .get<dynamic>('https://photon.komoot.io/api/', queryParameters: qp);
    final Object? data = resp.data;
    final List<dynamic> feats = _features(data);
    final List<Place> out = <Place>[];
    for (final dynamic f in feats) {
      if (f is! Map) continue;
      final Map<dynamic, dynamic> geo =
          (f['geometry'] as Map?) ?? const <dynamic, dynamic>{};
      final List<dynamic>? coords = geo['coordinates'] as List<dynamic>?;
      if (coords == null || coords.length < 2) continue;
      final double? lon = (coords[0] as num?)?.toDouble();
      final double? lat = (coords[1] as num?)?.toDouble();
      if (lat == null || lon == null) continue;
      final Map<dynamic, dynamic> props =
          (f['properties'] as Map?) ?? const <dynamic, dynamic>{};
      final String name = ((props['name'] as String?) ?? '').trim();
      if (name.isEmpty) continue;
      final String type = (props['osm_value'] as String?) ?? '';
      final String city = ((props['city'] as String?) ??
              (props['county'] as String?) ??
              (props['state'] as String?) ??
              '')
          .trim();
      out.add(Place(
        placeId: 'ph-${f['type'] ?? 'p'}-$lat,$lon',
        name: name,
        lat: lat,
        lng: lon,
        address: city.isEmpty ? null : city,
        primaryType: type.isEmpty ? 'poi' : type,
        types: const <String>['point_of_interest'],
        provider: 'photon',
      ));
    }
    return _ProviderResult(
      provider: 'photon',
      places: out,
      responded: true,
      error: null,
      raw: feats.length,
    );
  }

  Future<_ProviderResult> _nominatimSearch(String q, LatLng? near) async {
    // Respect Nominatim's 1 request/second usage policy.
    final DateTime now = DateTime.now();
    final DateTime? last = _lastNominatimAt;
    if (last != null) {
      final int waitMs = 1000 - now.difference(last).inMilliseconds;
      if (waitMs > 0) {
        await Future<void>.delayed(Duration(milliseconds: waitMs));
      }
    }
    _lastNominatimAt = DateTime.now();

    final Map<String, dynamic> qp = <String, dynamic>{
      'q': q,
      'format': 'jsonv2',
      'limit': 25,
      'addressdetails': 0,
      'countrycodes': 'in',
    };
    if (near != null) {
      // Latitude-aware box (~0.5°) only biases ranking; results are still
      // distance-sorted and radius-filtered after parsing.
      final double d = 0.5;
      qp['viewbox'] = '${near.longitude - d},${near.latitude + d},'
          '${near.longitude + d},${near.latitude - d}';
      qp['bounded'] = 0;
    }
    final Response<dynamic> resp =
        await _nominatim.get<dynamic>('https://nominatim.openstreetmap.org/search',
            queryParameters: qp);
    final Object? data = resp.data;
    final List<dynamic> raw = data is List ? data : const <dynamic>[];
    final List<Place> out = <Place>[];
    for (final dynamic item in raw) {
      if (item is! Map) continue;
      final double? lat = (item['lat'] as num?)?.toDouble();
      final double? lon = (item['lon'] as num?)?.toDouble();
      if (lat == null || lon == null) continue;
      final String display = (item['display_name'] as String?) ?? '';
      final String name =
          (item['name'] as String?)?.isNotEmpty == true
              ? item['name'] as String
              : display.split(',').first.trim();
      out.add(Place(
        placeId: 'nom-${item['osm_id'] ?? '$lat,$lon'}',
        name: name.isEmpty ? 'Place' : name,
        lat: lat,
        lng: lon,
        address: display,
        primaryType: 'poi',
      ));
    }
    return _ProviderResult(
      provider: 'nominatim',
      places: out,
      responded: true,
      error: null,
      raw: raw.length,
    );
  }

  // ---------------------------------------------------------------------
  // Overpass POI search (keyless, real OSM data)
  // ---------------------------------------------------------------------

  Future<_ProviderResult> _overpass(
    List<(String, String)> filters,
    LatLng near,
    double radiusMeters,
  ) async {
    final bool hotelFilter =
        filters.any((f) => f.$2.contains('hotel'));
    final int radius =
        (radiusMeters <= 0 ? kNearbyRadiusMeters : radiusMeters).round();
    final StringBuffer b = StringBuffer('[out:json][timeout:15];(');
    for (final (String key, String regex) in filters) {
      final String clause =
          '["$key"~"$regex"](around:$radius,${near.latitude},${near.longitude})';
      b.write('node$clause;way$clause;');
    }
    b.write(');out center 80;');

    final String query = b.toString();

    // In-flight dedup: one shared request for identical queries.
    final Future<_ProviderResult>? pending = _overpassInFlight[query];
    if (pending != null) return pending;

    final Future<_ProviderResult> run = _overpassRun(query, hotelFilter);
    _overpassInFlight[query] = run;
    try {
      return await run;
    } finally {
      if (identical(_overpassInFlight[query], run)) {
        unawaited(_overpassInFlight.remove(query));
      }
    }
  }

  Future<_ProviderResult> _overpassRun(String query, bool hotelFilter) async {
    final List<dynamic> elements = await _overpassElements(query);
    final List<Place> out = <Place>[];
    for (final dynamic e in elements) {
      if (e is! Map) continue;
      final (double?, double?) coords = _coordsOf(e);
      if (coords.$1 == null || coords.$2 == null) continue;
      final Object? tags = e['tags'];
      String name = '';
      String phone = '';
      String website = '';
      String address = '';
      if (tags is Map) {
        name = _tagOf(tags, 'name');
        phone = _tagOf(tags, 'phone') + _tagOf(tags, 'contact:phone');
        if (phone.isEmpty) phone = _tagOf(tags, 'contact:mobile');
        website = _tagOf(tags, 'website');
        if (website.isEmpty) website = _tagOf(tags, 'contact:website');
        final String street = _tagOf(tags, 'addr:street');
        final String city = _tagOf(tags, 'addr:city');
        address = <String>[street, city].where((String s) => s.isNotEmpty).join(', ');
      }
      if (name.trim().isEmpty) continue;
      if (hotelFilter && !_looksLikeHotel(name)) continue;
      out.add(Place(
        placeId:
            'osm-${e['type'] ?? 'node'}-${e['id'] ?? '${coords.$1},${coords.$2}'}',
        name: name,
        lat: coords.$1!,
        lng: coords.$2!,
        address: address.isEmpty ? null : address,
        phone: phone.isEmpty ? null : phone,
        website: website.isEmpty ? null : website,
        primaryType: 'poi',
        types: const <String>['point_of_interest'],
        provider: 'overpass',
      ));
    }
    return _ProviderResult(
      provider: 'overpass',
      places: out,
      responded: true,
      error: null,
      raw: elements.length,
    );
  }

  /// Single Overpass request runner shared by the per-category search and the
  /// grouped nearby fetch. Throttles to [_overpassMinGap], rotates across
  /// multiple public mirrors, honours each mirror's own 429 retry hint via a
  /// per-host cooldown (so a busy server is skipped, not hammered), and
  /// classifies network/server/parser failures as distinct typed errors — so
  /// callers never collapse a provider failure into "no results".
  Future<List<dynamic>> _overpassElements(String query) async {
    final DateTime? last = _lastOverpassAt;
    if (last != null) {
      final int waitMs = _overpassMinGap.inMilliseconds -
          DateTime.now().difference(last).inMilliseconds;
      if (waitMs > 0) {
        await Future<void>.delayed(Duration(milliseconds: waitMs));
      }
    }
    _lastOverpassAt = DateTime.now();
    _overpassRequestCount++;
    final int reqNo = _overpassRequestCount;
    NearbyDebug.instance.requestCount = reqNo;
    NearbyDebug.instance.phase = 'requesting';

    // Pure round-robin start: concurrent requests (the two grouped nearby
    // queries) always begin on DIFFERENT mirrors, so one host never receives
    // two simultaneous requests (Overpass fair-use is ~2 concurrent slots,
    // and a mirror that 429s is then skipped via its per-host cooldown).
    final int n = _overpassHosts.length;
    final int start = _overpassRoundRobin++ % n;
    final List<String> ordered = <String>[
      for (int i = 0; i < n; i++) _overpassHosts[(start + i) % n],
    ];

    bool responded = false;
    bool serverError = false;
    bool got429 = false;
    DateTime? soonestCooldown;
    int tried = 0;
    for (final String host in ordered) {
      final DateTime? until = _overpassCooldown[host];
      if (until != null && DateTime.now().isBefore(until)) {
        // This mirror is still in its own cooldown — skip it, keep the
        // others fully usable. Track the soonest expiry so that when ALL
        // mirrors are cooling down we can wait it out (max 8 s) instead of
        // instantly failing the whole search.
        if (soonestCooldown == null || until.isBefore(soonestCooldown)) {
          soonestCooldown = until;
        }
        continue;
      }
      tried++;
      final Stopwatch sw = Stopwatch()..start();
      NearbyDebug.instance.host = host;
      try {
        final Response<dynamic> resp = await _dio.get<dynamic>(
          host,
          queryParameters: <String, dynamic>{'data': query},
          // Big grouped queries can genuinely take 15-20 s on busy mirrors —
          // allow 18 s so slow-but-working mirrors are not cut off, while
          // dead ones still fail fast enough to try the next mirror.
          options: Options(
            receiveTimeout: const Duration(seconds: 18),
            sendTimeout: const Duration(seconds: 12),
          ),
        );
        sw.stop();
        responded = true;
        NearbyDebug.instance.httpStatus = resp.statusCode;
        final Object? data = resp.data;
        if (data is! Map || data['elements'] is! List) {
          // Non-JSON (gateway error page) — try the next host.
          debugPrint('[places] overpass req#$reqNo $host ${resp.statusCode} '
              'unusable-body ${sw.elapsedMilliseconds}ms');
          NearbyDebug.instance.phase = 'unusable-body';
          continue;
        }
        _overpassCooldown.remove(host);
        final List<dynamic> elements = data['elements'] as List;
        NearbyDebug.instance.rawCount = elements.length;
        NearbyDebug.instance.phase = 'ok';
        debugPrint('[places] overpass req#$reqNo $host ${resp.statusCode} '
            '${elements.length} elements ${sw.elapsedMilliseconds}ms');
        return elements;
      } on DioException catch (e) {
        sw.stop();
        final int? code = e.response?.statusCode;
        NearbyDebug.instance.httpStatus = code;
        if (code == 429) {
          // Rate limited on THIS mirror: honour its retry hint and move on to
          // the next mirror instead of piling more requests onto it.
          got429 = true;
          responded = true;
          final Duration wait = _overpassRetryDelay(e.response);
          _overpassCooldown[host] = DateTime.now().add(wait);
          NearbyDebug.instance.phase = '429';
          NearbyDebug.instance.error =
              '429 (rate limited, cooldown ${wait.inSeconds}s)';
          debugPrint('[places] overpass req#$reqNo $host 429 '
              '${sw.elapsedMilliseconds}ms — cooldown ${wait.inSeconds}s, '
              'trying next mirror');
          continue;
        }
        NearbyDebug.instance.phase = 'error:${code ?? e.type.name}';
        debugPrint('[places] overpass req#$reqNo $host ${code ?? e.type.name} '
            '${sw.elapsedMilliseconds}ms');
        if (e.response != null) {
          responded = true;
          if ((e.response!.statusCode ?? 0) >= 500) serverError = true;
        }
      } catch (e) {
        sw.stop();
        NearbyDebug.instance.phase = 'exception:${e.runtimeType}';
        // Try the next host.
      }
    }
    // Every mirror was skipped due to its cooldown and none responded:
    // wait out the soonest cooldown (bounded to 8 s) and retry ONCE — much
    // better than telling the user the service is down when a mirror is
    // about to free up.
    if (tried == 0 && !responded && soonestCooldown != null) {
      final int waitMs =
          soonestCooldown.difference(DateTime.now()).inMilliseconds;
      if (waitMs > 0 && waitMs <= 8000) {
        NearbyDebug.instance.phase =
            'cooldown-wait:${(waitMs / 1000).round()}s';
        await Future<void>.delayed(Duration(milliseconds: waitMs + 50));
        return _overpassElements(query);
      }
    }
    if (got429) {
      NearbyDebug.instance.phase = 'rateLimited';
      NearbyDebug.instance.error = '429 (rate limited)';
      throw const ApiException(ApiErrorKind.rateLimited,
          'Nearby search is temporarily limited. Try again shortly.');
    }
    if (serverError) {
      NearbyDebug.instance.phase = 'serverError';
      NearbyDebug.instance.error = '5xx server error';
      throw const ApiException(ApiErrorKind.server,
          'The nearby data service is unavailable. Please try again shortly.');
    }
    if (responded) {
      NearbyDebug.instance.phase = 'parserError';
      NearbyDebug.instance.error = 'unreadable response';
      throw const ApiException(ApiErrorKind.parser,
          'The nearby data service returned an unreadable response.');
    }
    NearbyDebug.instance.phase = 'networkError';
    NearbyDebug.instance.error = 'unreachable';
    throw const ApiException(
        ApiErrorKind.network, 'Overpass is unreachable right now.');
  }

  /// Decodes a mirror's 429 response into a polite wait: prefer the server's
  /// own hint (Retry-After header, "Slot available again at …" body, or
  /// kumi's "rate_limited: N" body), falling back to a short default only
  /// when no hint is present.
  static Duration _overpassRetryDelay(Response<dynamic>? resp) {
    if (resp != null) {
      final String? retryAfter = resp.headers.value('retry-after');
      if (retryAfter != null) {
        final int? secs = int.tryParse(retryAfter.trim());
        if (secs != null && secs > 0) {
          return Duration(seconds: secs.clamp(1, 120).toInt());
        }
      }
      String body = '';
      final Object? data = resp.data;
      if (data is String) {
        body = data;
      } else if (data is Map) {
        body = data.toString();
      }
      // overpass-api.de overload: "Slot available again at <ISO8601>".
      final Match? slot = RegExp(r'Slot available again at (.+?)(\s|$)')
          .firstMatch(body);
      if (slot != null) {
        final DateTime? t = DateTime.tryParse(slot.group(1)!.trim());
        if (t != null) {
          final int secs = t.difference(DateTime.now().toUtc()).inSeconds;
          if (secs > 0) return Duration(seconds: secs.clamp(1, 120).toInt());
        }
      }
      // kumi.systems: "rate_limited: 2" (per-second) vs "rate_limited: 10000"
      // (per-day) — a small N is a brief throttle, a large N is the daily cap.
      final Match? rl = RegExp(r'rate_limited:\s*(\d+)').firstMatch(body);
      if (rl != null) {
        final int? n = int.tryParse(rl.group(1)!);
        if (n != null) {
          if (n <= 5) return const Duration(seconds: 2);
          return const Duration(minutes: 30);
        }
      }
    }
    return const Duration(seconds: 12);
  }

  /// Canonical OSM-derived nearby categories and their tag predicates.
  ///
  /// UI categories (Hotels / Hospitals / …) map to these. 'food' is a roll-up
  /// of restaurant|fast_food|cafe and is derived at classification time, so it
  /// has no tag clause of its own. 'shopping' matches any `shop` key (the
  /// value is null = key-existence), per the `shop=*` spec.
  static const Map<String, List<(String, String?)>> _nearbyCategoryTags =
      <String, List<(String, String?)>>{
    'hospital': <(String, String?)>[('amenity', 'hospital'), ('amenity', 'clinic')],
    'police': <(String, String?)>[('amenity', 'police')],
    'pharmacy': <(String, String?)>[('amenity', 'pharmacy')],
    'atm': <(String, String?)>[('amenity', 'atm')],
    'fuel': <(String, String?)>[('amenity', 'fuel')],
    'restaurant': <(String, String?)>[('amenity', 'restaurant')],
    'cafe': <(String, String?)>[('amenity', 'cafe')],
    'fast_food': <(String, String?)>[('amenity', 'fast_food')],
    'hotel': <(String, String?)>[
      ('tourism', 'hotel'),
      ('tourism', 'hostel'),
      ('tourism', 'guest_house'),
      ('tourism', 'motel'),
    ],
    'park': <(String, String?)>[('leisure', 'park')],
    'museum': <(String, String?)>[('tourism', 'museum')],
    'attraction': <(String, String?)>[
      ('tourism', 'attraction'),
      ('tourism', 'gallery'),
      ('tourism', 'viewpoint'),
      ('tourism', 'zoo'),
      ('tourism', 'theme_park'),
      ('tourism', 'aquarium'),
      ('historic', 'monument'),
      ('historic', 'memorial'),
      ('historic', 'castle'),
      ('historic', 'fort'),
      ('historic', 'ruins'),
      ('historic', 'archaeological_site'),
      ('amenity', 'place_of_worship'),
    ],
    'shopping': <(String, String?)>[('shop', null)],
    'transit': <(String, String?)>[
      ('highway', 'bus_stop'),
      ('public_transport', 'platform'),
      ('public_transport', 'stop_position'),
      ('railway', 'station'),
      ('railway', 'halt'),
      ('amenity', 'bus_station'),
      ('amenity', 'ferry_terminal'),
    ],
  };

  /// Semantic `Place.types` aliases per dataset category, so existing UI
  /// helpers (PlaceCard icons/colours, isFood/isTourist/isEmergency) keep
  /// working unchanged.
  static const Map<String, List<String>> _categorySemanticTypes =
      <String, List<String>>{
    'hospital': <String>['hospital'],
    'police': <String>['police_station'],
    'pharmacy': <String>['pharmacy'],
    'atm': <String>['atm'],
    'fuel': <String>['fuel'],
    'restaurant': <String>['restaurant', 'food'],
    'cafe': <String>['cafe', 'food'],
    'fast_food': <String>['fast_food', 'food'],
    'hotel': <String>['hotel', 'lodging'],
    'park': <String>['park'],
    'museum': <String>['museum'],
    'attraction': <String>['tourist_attraction'],
    'shopping': <String>['store', 'shopping'],
    'transit': <String>['transit_station'],
  };

  /// The nearby area is fetched as TWO lighter parallel Overpass queries
  /// instead of one huge all-category query. The public Overpass servers
  /// frequently drop one big query as "too busy"; two smaller requests are
  /// each much more likely to succeed, and a single failure still returns
  /// the other half's real results (failures are isolated, never faked).
  static const List<String> _essentialNearbyCats = <String>[
    'hospital', 'police', 'pharmacy', 'atm', 'fuel', 'transit',
  ];
  static const List<String> _touristNearbyCats = <String>[
    'restaurant', 'cafe', 'fast_food', 'hotel', 'park', 'museum', 'attraction',
  ];

  /// Combined nearby dataset (essential + tourist categories) parsed,
  /// deduplicated, filtered to the exact radius and sorted nearest first.
  /// Callers cache the result and then filter it locally by category, so
  /// switching categories never triggers another network request.
  Future<List<Place>> nearbyAround(
    LatLng near, {
    double radiusMeters = kNearbyRadiusMeters,
    bool includeShopping = false,
  }) async {
    NearbyDebug.instance.reset(
      phase: 'requesting',
      location:
          '${near.latitude.toStringAsFixed(5)},${near.longitude.toStringAsFixed(5)}',
    );
    final List<String> tourist = <String>[
      ..._touristNearbyCats,
      if (includeShopping) 'shopping',
    ];

    final List<(List<Place>?, Object?)> parts =
        await Future.wait<(List<Place>?, Object?)>(<Future<(List<Place>?, Object?)>>[
      _nearbyCategoriesSafe(near, radiusMeters, _essentialNearbyCats),
      _nearbyCategoriesSafe(near, radiusMeters, tourist),
    ]);

    Object? firstError;
    final Map<String, Place> dedup = <String, Place>{};
    int ok = 0;
    int failed = 0;
    for (final (List<Place>?, Object?) part in parts) {
      final List<Place>? places = part.$1;
      if (places == null) {
        failed++;
        firstError ??= part.$2;
        continue;
      }
      ok++;
      for (final Place p in places) {
        final String key = _dedupKey(p);
        final Place? existing = dedup[key];
        if (existing == null || _isRicher(p, existing)) dedup[key] = p;
      }
    }

    if (ok == 0) {
      // Both queries failed — surface the real, typed error (never a fake
      // empty list masquerading as "no places").
      NearbyDebug.instance.phase = 'failed';
      if (firstError != null) throw firstError;
      throw const ApiException(
          ApiErrorKind.network, 'Overpass is unreachable right now.');
    }

    final List<Place> out = dedup.values.toList()
      ..sort((Place a, Place b) =>
          (a.distanceMeters ?? 0).compareTo(b.distanceMeters ?? 0));
    NearbyDebug.instance.okQueries = ok;
    NearbyDebug.instance.failQueries = failed;
    NearbyDebug.instance.parsedCount = out.length;
    if (failed > 0) {
      NearbyDebug.instance.error = 'partial: $failed of ${ok + failed} '
          'provider queries failed';
    }
    debugPrint('[places] nearbyAround ok=$ok failed=$failed '
        'final=${out.length}');
    return out;
  }

  Future<(List<Place>?, Object?)> _nearbyCategoriesSafe(
    LatLng near,
    double radiusMeters,
    List<String> categories,
  ) async {
    try {
      final List<Place> places = await _nearbyCategories(
        near,
        radiusMeters: radiusMeters,
        categories: categories,
        recordDebug: false,
      );
      return (places, null);
    } catch (e) {
      return (null, e);
    }
  }

  /// Shops only (`shop=*`) — kept as a separate on-demand query so the dense
  /// shop layer never crowds essential POIs out of the grouped query.
  Future<List<Place>> nearbyShopping(LatLng near,
          {double radiusMeters = kNearbyRadiusMeters}) =>
      _nearbyCategories(
        near,
        radiusMeters: radiusMeters,
        categories: const <String>['shopping'],
      );

  Future<List<Place>> _nearbyCategories(
    LatLng near, {
    required double radiusMeters,
    List<String>? categories,
    bool recordDebug = true,
  }) async {
    final double radius = radiusMeters <= 0 ? kNearbyRadiusMeters : radiusMeters;
    if (recordDebug) {
      NearbyDebug.instance.reset(
        phase: 'building-query',
        location:
            '${near.latitude.toStringAsFixed(5)},${near.longitude.toStringAsFixed(5)}',
      );
    }
    // NOTE: the output limit is deliberately high and quadtile-ordered.
    // Overpass fills `out` in statement order, so a small cap (the old
    // `out center 400`) silently truncated the LATER categories (hotel/park/
    // museum/attraction/transit) to zero in dense areas while the early ones
    // (hospital/clinic/police…) filled the cap. `qt 5000` keeps the whole
    // 10 km dataset for dense cities and drops only the far quadtiles in
    // pathological megacity cases; the client re-sorts by distance anyway.
    final StringBuffer b = StringBuffer('[out:json][timeout:15];(');
    for (final MapEntry<String, List<(String, String?)>> entry
        in _nearbyCategoryTags.entries) {
      if (categories != null && !categories.contains(entry.key)) continue;
      for (final (String key, String? value) in entry.value) {
        final String sel = value == null ? '["$key"]' : '["$key"="$value"]';
        b.write('node$sel(around:${radius.round()},${near.latitude},${near.longitude});');
        b.write('way$sel(around:${radius.round()},${near.latitude},${near.longitude});');
      }
    }
    b.write(');out center qt 5000;');

    final List<dynamic> elements = await _overpassElements(b.toString());
    final Map<String, Place> dedup = <String, Place>{};
    for (final dynamic e in elements) {
      if (e is! Map) continue;
      final (double?, double?) coords = _coordsOf(e);
      if (coords.$1 == null || coords.$2 == null) continue;
      final Object? tagsObj = e['tags'];
      if (tagsObj is! Map) continue;
      final String name = _tagOf(tagsObj, 'name');
      if (name.trim().isEmpty) continue;

      final List<String> cats = _categoriesOf(tagsObj);
      if (cats.isEmpty) continue;
      if (cats.contains('hotel') && !_looksLikeHotel(name)) continue;

      final double dist = GeoUtils.distanceMetersLL(
          near.latitude, near.longitude, coords.$1!, coords.$2!);
      if (dist > radius) continue;

      final Set<String> types = <String>{'point_of_interest'};
      for (final String c in cats) {
        types.addAll(_categorySemanticTypes[c] ?? const <String>[]);
      }
      final String primary =
          cats.contains('food') || cats.length <= 1
              ? cats.first
              : cats.firstWhere((String c) => c != 'food');
      final Place p = Place(
        placeId:
            'osm-${e['type'] ?? 'node'}-${e['id'] ?? '${coords.$1},${coords.$2}'}',
        name: name,
        lat: coords.$1!,
        lng: coords.$2!,
        address: _addressOf(tagsObj),
        phone: _phoneOf(tagsObj),
        website: _websiteOf(tagsObj),
        primaryType: primary,
        category: primary,
        provider: 'overpass',
        distanceMeters: dist,
        types: types.toList(),
      );
      final String key = _dedupKey(p);
      final Place? existing = dedup[key];
      if (existing == null || _isRicher(p, existing)) dedup[key] = p;
    }
    final List<Place> out = dedup.values.toList()
      ..sort((Place a, Place b) =>
          (a.distanceMeters ?? 0).compareTo(b.distanceMeters ?? 0));
    if (recordDebug) NearbyDebug.instance.parsedCount = out.length;
    debugPrint('[places] nearbyCategories radius=${radius.round()}m '
        'raw=${elements.length} final=${out.length}');
    return out;
  }

  /// Maps an OSM element's tags to the dataset categories it belongs to.
  static List<String> _categoriesOf(Map tags) {
    final List<String> out = <String>[];
    for (final MapEntry<String, List<(String, String?)>> entry
        in _nearbyCategoryTags.entries) {
      for (final (String key, String? value) in entry.value) {
        final Object? tv = tags[key];
        if (tv == null) continue;
        if (value == null || tv.toString() == value) {
          out.add(entry.key);
          break;
        }
      }
    }
    // 'food' roll-up for the restaurant/café/fast-food family.
    if (out.any((String c) =>
        c == 'restaurant' || c == 'cafe' || c == 'fast_food')) {
      out.insert(0, 'food');
    }
    return out;
  }

  static String _phoneOf(Map tags) {
    final String phone = _tagOf(tags, 'phone') + _tagOf(tags, 'contact:phone');
    if (phone.isNotEmpty) return phone;
    return _tagOf(tags, 'contact:mobile');
  }

  static String _websiteOf(Map tags) {
    final String website = _tagOf(tags, 'website');
    if (website.isNotEmpty) return website;
    return _tagOf(tags, 'contact:website');
  }

  static String _addressOf(Map tags) {
    final String street = _tagOf(tags, 'addr:street');
    final String housenumber = _tagOf(tags, 'addr:housenumber');
    final String city = _tagOf(tags, 'addr:city');
    final List<String> line = <String>[
      [housenumber, street].where((String s) => s.isNotEmpty).join(' '),
      city,
    ].where((String s) => s.isNotEmpty).toList();
    return line.join(', ');
  }

  /// Overpass returns nodes with `lat`/`lon` but ways with `center` — read
  /// both so building-shaped POIs (hotels, museums) are never dropped.
  static (double?, double?) _coordsOf(Map e) {
    double? lat = (e['lat'] as num?)?.toDouble();
    double? lon = (e['lon'] as num?)?.toDouble();
    if (lat == null || lon == null) {
      final Object? c = e['center'];
      if (c is Map) {
        lat = (c['lat'] as num?)?.toDouble();
        lon = (c['lon'] as num?)?.toDouble();
      }
    }
    return (lat, lon);
  }

  static String _tagOf(Map tags, String key) =>
      tags[key] is String ? tags[key] as String : '';

  /// Filters OSM entries that are tagged `tourism=hotel` but are really
  /// marriage/banquet halls — they look fake in a "hotels" list.
  /// NOTE: only clear banquet-hall terms are excluded. Words like "lawn",
  /// "function" or "party" are common in genuine Indian hotel names
  /// (e.g. "Shivam Hotel & Lawn"), so they must NOT be filtered.
  static bool _looksLikeHotel(String name) {
    final String n = name.toLowerCase();
    return !(n.contains('marriage') ||
        n.contains('banquet') ||
        n.contains('wedding') ||
        n.contains('mandap'));
  }

  Future<String?> reverseGeocode(double lat, double lng) async {
    try {
      final Response<dynamic> resp = await _dio.get<dynamic>(
        'https://api.maptiler.com/geocoding/$lng,$lat.json',
        queryParameters: <String, dynamic>{'key': _mtKey, 'limit': 1},
      );
      final List<dynamic> feats = _features(resp.data);
      if (feats.isEmpty) return null;
      final dynamic f = feats.first;
      if (f is Map) {
        final String? label = _mapTilerReverseLabel(f);
        if (label != null && label.trim().isNotEmpty) return label.trim();
      }
      return null;
    } on DioException {
      // Nominatim reverse as a keyless fallback.
      try {
        final Response<dynamic> resp = await _nominatim.get<dynamic>(
          'https://nominatim.openstreetmap.org/reverse',
          queryParameters: <String, dynamic>{
            'lat': lat,
            'lon': lng,
            'format': 'jsonv2',
          },
        );
        final Object? data = resp.data;
        if (data is Map) {
          final String? label = _nominatimReverseLabel(data);
          if (label != null && label.trim().isNotEmpty) return label.trim();
        }
      } catch (_) {}
      throw ApiException(
          ApiErrorKind.server, 'Could not determine your location.');
    }
  }

  /// Builds a "City, State, Country" label from a MapTiler feature's context
  /// (rural coordinates reverse-geocode to a road, which is useless as a
  /// "you are here" label — so we prefer the admin-area context entries).
  static String? _mapTilerReverseLabel(Map f) {
    final Object? ctx = f['context'];
    String? city;
    String? state;
    String? country;
    if (ctx is List) {
      for (final dynamic c in ctx) {
        if (c is! Map) continue;
        final String kind = (c['kind'] as String?) ?? '';
        final String text = (c['text'] as String?) ?? '';
        if (text.isEmpty) continue;
        final String id = (c['id'] as String?) ?? '';
        if (kind == 'country' && country == null) {
          country = text;
        } else if (kind == 'admin_area') {
          if (id.startsWith('region.') && state == null) {
            state = text;
          } else if ((id.startsWith('county.') || id.startsWith('subregion.')) &&
              city == null) {
            city = text;
          }
        }
      }
    }
    final List<String> parts = <String>[
      if (city != null) city,
      if (state != null) state,
      if (country != null) country,
    ];
    if (parts.isNotEmpty) return parts.join(', ');
    final String placeName = (f['place_name'] as String?) ?? '';
    return placeName.trim().isEmpty ? null : placeName;
  }

  static String? _nominatimReverseLabel(Map data) {
    final Object? address = data['address'];
    if (address is! Map) {
      final String? display = data['display_name'] as String?;
      return display;
    }
    String? city = (address['city'] ?? address['town'] ?? address['village'] ??
        address['county'] ?? address['state_district']) as String?;
    final String? state = address['state'] as String?;
    final String? country = address['country'] as String?;
    final List<String> parts = <String>[
      if (city != null && city.isNotEmpty) city,
      if (state != null && state.isNotEmpty) state,
      if (country != null && country.isNotEmpty) country,
    ];
    if (parts.isNotEmpty) return parts.join(', ');
    final String? display = data['display_name'] as String?;
    return display;
  }

  List<dynamic> _features(Object? data) {
    if (data is Map && data['features'] is List) {
      return data['features'] as List;
    }
    return const <dynamic>[];
  }

  List<Place> _parseGeocoding(Object? data) {
    final List<Place> out = <Place>[];
    for (final dynamic f in _features(data)) {
      if (f is! Map) continue;
      final Object? center = f['center'];
      if (center is! List || center.length < 2) continue;
      final double lng = (center[0] as num).toDouble();
      final double lat = (center[1] as num).toDouble();
      final String placeName = (f['place_name'] as String?) ?? '';
      final Object? props = f['properties'];
      String name = '';
      if (props is Map && props['name'] is String) name = props['name'] as String;
      if (name.trim().isEmpty && placeName.isNotEmpty) {
        name = placeName.split(',').first.trim();
      }
      if (name.trim().isEmpty) name = 'Place';
      final List<String> placeType = (f['place_type'] is List)
          ? (f['place_type'] as List).whereType<String>().toList()
          : <String>[];
      out.add(Place(
        placeId: (f['id'] as String?) ?? '$lat,$lng',
        name: name,
        lat: lat,
        lng: lng,
        address: placeName,
        primaryType: placeType.isNotEmpty ? placeType.first : 'poi',
        types: placeType,
      ));
    }
    return out;
  }

  // ---------------------------------------------------------------------
  // OSRM routing (real road routing, no key) — driving / walking / cycling
  // ---------------------------------------------------------------------

  final OsrmClient _osrm = OsrmClient();

  /// Real road route from the free OSRM router. When OSRM is unreachable or
  /// cannot route (no road coverage, etc.) this falls back to an honest
  /// straight-line estimate clearly labelled as approximate, so the map keeps
  /// working everywhere.
  Future<RouteInfo> route(LatLng from, LatLng to, {String mode = 'car'}) async {
    try {
      return await _osrm.route(origin: from, destination: to, mode: mode);
    } on OsrmException {
      return _straightLine(from, to, mode: mode);
    }
  }

  RouteInfo _straightLine(LatLng from, LatLng to, {String mode = 'car'}) {
    final double meters = GeoUtils.distanceMeters(from, to);
    // Rough urban speeds by mode, so ETAs stay plausible.
    final double kmh = switch (mode) {
      'walk' => 4.5,
      'bike' => 12,
      _ => 30,
    };
    final double seconds = (meters / 1000) / kmh * 3600;
    return RouteInfo(
      distanceMeters: meters,
      durationSeconds: seconds,
      polyline: <LatLng>[from, to],
      provider: 'fallback',
    );
  }

  // ---------------------------------------------------------------------
  // Open-Meteo weather (real, no key)
  // ---------------------------------------------------------------------

  Future<WeatherCurrent> weather(double lat, double lng) async {
    try {
      final Response<dynamic> resp = await _dio.get<dynamic>(
        'https://api.open-meteo.com/v1/forecast',
        queryParameters: <String, dynamic>{
          'latitude': lat,
          'longitude': lng,
          'current':
              'temperature_2m,relative_humidity_2m,apparent_temperature,'
                  'weather_code,wind_speed_10m,wind_direction_10m,'
                  'surface_pressure,visibility',
          'timezone': 'auto',
        },
      );
      final Map<dynamic, dynamic> data = resp.data as Map<dynamic, dynamic>;
      final Map<dynamic, dynamic> c =
          (data['current'] as Map?)?.cast<dynamic, dynamic>() ??
              <dynamic, dynamic>{};
      final int code = (c['weather_code'] as num?)?.toInt() ?? 0;
      final (String condition, String icon) = _wmo(code);
      return WeatherCurrent(
        tempC: (c['temperature_2m'] as num?)?.toDouble() ?? 0,
        feelsLikeC:
            (c['apparent_temperature'] as num?)?.toDouble() ?? 0,
        humidityPct: (c['relative_humidity_2m'] as num?)?.toInt() ?? 0,
        windMs: (c['wind_speed_10m'] as num?)?.toDouble() ?? 0,
        windDeg: (c['wind_direction_10m'] as num?)?.toDouble() ?? 0,
        condition: condition,
        icon: icon,
        pressureHpa: (c['surface_pressure'] as num?)?.toInt() ?? 0,
        visibilityM: (c['visibility'] as num?)?.toDouble() ?? 10000,
        updatedAt: DateTime.now(),
      );
    } on DioException catch (e) {
      throw _map(e, 'Could not load weather right now.');
    }
  }

  Future<List<ForecastDay>> forecast(double lat, double lng) async {
    try {
      final Response<dynamic> resp = await _dio.get<dynamic>(
        'https://api.open-meteo.com/v1/forecast',
        queryParameters: <String, dynamic>{
          'latitude': lat,
          'longitude': lng,
          'daily': 'weather_code,temperature_2m_max,temperature_2m_min,'
              'precipitation_probability_max',
          'timezone': 'auto',
          'forecast_days': 7,
        },
      );
      final Map<dynamic, dynamic> data = resp.data as Map<dynamic, dynamic>;
      final Map<dynamic, dynamic> daily =
          (data['daily'] as Map?)?.cast<dynamic, dynamic>() ??
              <dynamic, dynamic>{};
      final List<dynamic> time = daily['time'] is List ? daily['time'] as List : const <dynamic>[];
      final List<dynamic> codeList =
          daily['weather_code'] is List ? daily['weather_code'] as List : const <dynamic>[];
      final List<dynamic> maxList = daily['temperature_2m_max'] is List
          ? daily['temperature_2m_max'] as List
          : const <dynamic>[];
      final List<dynamic> minList = daily['temperature_2m_min'] is List
          ? daily['temperature_2m_min'] as List
          : const <dynamic>[];
      final List<dynamic> rainList =
          daily['precipitation_probability_max'] is List
              ? daily['precipitation_probability_max'] as List
              : const <dynamic>[];
      final List<ForecastDay> out = <ForecastDay>[];
      for (int i = 0; i < time.length; i++) {
        final int code = (codeList.length > i ? codeList[i] as num? : null)?.toInt() ?? 0;
        final (String condition, String icon) = _wmo(code);
        out.add(ForecastDay(
          date: DateTime.tryParse(time[i].toString()) ?? DateTime.now(),
          tempMaxC: (maxList.length > i ? maxList[i] as num? : null)?.toDouble() ?? 0,
          tempMinC: (minList.length > i ? minList[i] as num? : null)?.toDouble() ?? 0,
          condition: condition,
          icon: icon,
          precipChancePct:
              (rainList.length > i ? rainList[i] as num? : null)?.toInt() ?? 0,
        ));
      }
      return out;
    } on DioException catch (e) {
      throw _map(e, 'Could not load the forecast right now.');
    }
  }

  /// WMO weather code → (condition, OpenWeather-style icon code).
  (String, String) _wmo(int code) => switch (code) {
        0 => ('Clear sky', '01d'),
        1 => ('Mainly clear', '01d'),
        2 => ('Partly cloudy', '02d'),
        3 => ('Overcast', '04d'),
        45 || 48 => ('Fog', '50d'),
        51 || 53 || 55 || 56 || 57 => ('Drizzle', '09d'),
        61 || 63 || 65 || 66 || 67 => ('Rain', '10d'),
        71 || 73 || 75 || 77 => ('Snow', '13d'),
        80 || 81 || 82 => ('Rain showers', '09d'),
        85 || 86 => ('Snow showers', '13d'),
        95 || 96 || 99 => ('Thunderstorm', '11d'),
        _ => ('Unknown', '01d'),
      };

  ApiException _map(DioException e, String fallback) {
    final int? code = e.response?.statusCode;
    if (code == 401 || code == 403) {
      return ApiException(
        ApiErrorKind.unauthorized,
        'The map data key was rejected. Please check the key and rebuild.',
        statusCode: code,
        retryable: false,
      );
    }
    if (code == 429) {
      return ApiException(
        ApiErrorKind.rateLimited,
        'Too many map/weather requests — please wait a moment and retry.',
        statusCode: code,
      );
    }
    if (e.type == DioExceptionType.connectionError ||
        e.type == DioExceptionType.connectionTimeout) {
      return ApiException(ApiErrorKind.network,
          'No internet connection. Check your connection and try again.');
    }
    return ApiException(ApiErrorKind.server, fallback, statusCode: code);
  }
}

/// Normalised outcome for one place provider, used to merge results across
/// providers and to classify failures honestly (network / rate-limit /
/// unauthorized / server / empty) instead of collapsing everything to [].
class _ProviderResult {
  const _ProviderResult({
    required this.provider,
    required this.places,
    required this.responded,
    required this.error,
    required this.raw,
  });

  final String provider;
  final List<Place> places;

  /// True when the provider returned an HTTP response (even zero results).
  final bool responded;

  /// Error kind when the request failed; null on success.
  final ApiErrorKind? error;

  /// Raw feature/element count returned by the provider (before filtering).
  final int raw;

  int get parsed => places.length;

  _ProviderResult.skipped(String provider)
      : this(
          provider: provider,
          places: const <Place>[],
          responded: false,
          error: null,
          raw: 0,
        );
}
