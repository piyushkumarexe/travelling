import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../data/models/places.dart';
import '../../data/models/weather.dart';
import '../app_config.dart';
import '../utils/geo.dart';
import 'api_exception.dart';
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

  /// Nominatim rate-limit guard: public Nominatim allows at most 1 req/sec.
  /// Shared per process so debounced typing can never exceed it.
  static DateTime? _lastNominatimAt;

  /// Category keyword → Overpass tag filters. Overpass gives far better
  /// "nearby hotels / hospitals / ATMs" results than free geocoding.
  static const Map<String, List<(String, String)>> _categoryFilters =
      <String, List<(String, String)>>{
    'hotel': <(String, String)>[('tourism', 'hotel|hostel|guest_house|motel')],
    'hostel': <(String, String)>[('tourism', 'hostel')],
    'restaurant': <(String, String)>[('amenity', 'restaurant')],
    'food': <(String, String)>[('amenity', 'restaurant|fast_food|cafe')],
    'cafe': <(String, String)>[('amenity', 'cafe')],
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
    'hotel': <(String, String)>[('tourism', 'hotel|hostel|guest_house|motel')],
    'park': <(String, String)>[('leisure', 'park')],
    'museum': <(String, String)>[('tourism', 'museum')],
    'transit': <(String, String)>[
      ('amenity', 'bus_station'),
      ('railway', 'station'),
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
    double radiusMeters = 10000,
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

    // Run every provider IN PARALLEL and MERGE. A sparse/failed Overpass
    // response never hides what MapTiler/Nominatim found, and vice-versa.
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
          'Search service temporarily unavailable. Please try again.');
    }
    return const <Place>[]; // Providers responded, genuinely zero results.
  }

  /// Autocomplete suggestions while typing. Uses MapTiler Geocoding (which
  /// permits autocomplete) — never public Nominatim, which forbids it. When
  /// no MapTiler key is compiled in, it falls back to a single Overpass
  /// category query for recognised keywords only.
  Future<List<Place>> suggest(String query, {LatLng? near, int limit = 8}) async {
    final String q = query.trim();
    if (q.isEmpty) return const <Place>[];
    if (AppConfig.mapTilerConfigured) {
      try {
        final _ProviderResult r = await _maptilerSearch(q, near, limit: limit);
        if (r.places.isNotEmpty) return r.places;
      } on DioException catch (e) {
        final ApiErrorKind k = _kindOf(e);
        if (k == ApiErrorKind.rateLimited) {
          throw const ApiException(ApiErrorKind.rateLimited,
              'Search is temporarily limited. Try again shortly.');
        }
        if (k == ApiErrorKind.unauthorized) {
          throw const ApiException(ApiErrorKind.unauthorized,
              'The place search key was rejected. Please check the key and rebuild the app.',
              retryable: false);
        }
        // Network/server → fall through to the Overpass keyword fallback.
      }
    }
    final List<(String, String)>? filters = _filtersFor(q, null);
    if (filters != null && near != null) {
      final _ProviderResult r = await _overpass(filters, near, 10000);
      if (r.places.isNotEmpty) return r.places.take(limit).toList();
    }
    return const <Place>[];
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

  Future<_ProviderResult> _maptilerSearch(String q, LatLng? near,
      {int limit = 25}) async {
    final Map<String, dynamic> qp = <String, dynamic>{
      'key': _mtKey,
      'limit': limit,
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
    final int radius = (radiusMeters <= 0 ? 10000 : radiusMeters).round();
    final StringBuffer b = StringBuffer('[out:json][timeout:20];(');
    for (final (String key, String regex) in filters) {
      final String clause =
          '["$key"~"$regex"](around:$radius,${near.latitude},${near.longitude})';
      b.write('node$clause;way$clause;');
    }
    b.write(');out center 80;');

    for (final String host in const <String>[
      'https://overpass-api.de/api/interpreter',
      'https://overpass.kumi.systems/api/interpreter',
    ]) {
      try {
        final Response<dynamic> resp = await _dio.get<dynamic>(
          host,
          queryParameters: <String, dynamic>{'data': b.toString()},
        );
        final Object? data = resp.data;
        if (resp.statusCode == 429) {
          // Let the caller classify this as rate-limited.
          throw DioException(
            requestOptions: resp.requestOptions,
            response: resp,
            type: DioExceptionType.badResponse,
          );
        }
        if (data is! Map || data['elements'] is! List) {
          // Non-JSON (gateway error page) — try the next host.
          continue;
        }
        final List<dynamic> elements = data['elements'] as List;
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
          ));
        }
        return _ProviderResult(
          provider: 'overpass',
          places: out,
          responded: true,
          error: null,
          raw: elements.length,
        );
      } on DioException catch (e) {
        // A 429 (rate limit) is a real, distinct outcome — let the caller
        // classify it instead of masking it as "try the next host".
        if (e.response?.statusCode == 429) rethrow;
      } catch (_) {
        // Try the next host.
      }
    }
    throw const ApiException(
        ApiErrorKind.network, 'Overpass is unreachable right now.');
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
  static bool _looksLikeHotel(String name) {
    final String n = name.toLowerCase();
    return !(n.contains('marriage') ||
        n.contains('banquet') ||
        n.contains('wedding') ||
        n.contains('mandap') ||
        n.contains('function') ||
        n.contains('lawn') ||
        n.contains('party'));
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
