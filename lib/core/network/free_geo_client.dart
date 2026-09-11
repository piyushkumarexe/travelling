import 'package:dio/dio.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../data/models/places.dart';
import '../../data/models/weather.dart';
import '../app_config.dart';
import '../utils/geo.dart';
import 'api_exception.dart';

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
    connectTimeout: const Duration(seconds: 12),
    receiveTimeout: const Duration(seconds: 25),
  ));

  final Dio _nominatim = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 12),
    receiveTimeout: const Duration(seconds: 25),
    headers: <String, String>{
      // Nominatim requires a descriptive User-Agent (usage policy).
      'User-Agent': 'TourismApp/1.0 (Android travel & safety assistant)',
    },
  ));

  String get _mtKey => AppConfig.mapTilerApiKey;

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
    'temple': <(String, String)>[('amenity', 'place_of_worship')],
    'mosque': <(String, String)>[('amenity', 'place_of_worship')],
    'church': <(String, String)>[('amenity', 'place_of_worship')],
    'zoo': <(String, String)>[('tourism', 'zoo')],
  };

  /// Maps Google-style type ids to category filters.
  static const Map<String, List<(String, String)>> _typeFilters =
      <String, List<(String, String)>>{
    'hospital': <(String, String)>[('amenity', 'hospital|clinic')],
    'police_station': <(String, String)>[('amenity', 'police')],
    'fire_station': <(String, String)>[('amenity', 'fire_station')],
    'pharmacy': <(String, String)>[('amenity', 'pharmacy')],
    'cafe': <(String, String)>[('amenity', 'cafe')],
    'restaurant': <(String, String)>[('amenity', 'restaurant')],
    'hotel': <(String, String)>[('tourism', 'hotel|hostel|guest_house|motel')],
    'park': <(String, String)>[('leisure', 'park')],
    'museum': <(String, String)>[('tourism', 'museum')],
    'tourist_attraction': <(String, String)>[('tourism', 'attraction')],
    'shopping_mall': <(String, String)>[('shop', 'mall')],
    'atm': <(String, String)>[('amenity', 'atm')],
  };

  // ---------------------------------------------------------------------
  // Search: Overpass (categories) → MapTiler → Nominatim
  // ---------------------------------------------------------------------

  Future<List<Place>> searchPlaces(
    String query, {
    LatLng? near,
    List<String>? types,
    double radiusMeters = 5000,
  }) async {
    final String q = query.trim();
    final List<(String, String)>? filters = _filtersFor(q, types);

    // Category searches get Overpass POIs first — by far the best free
    // "hotels / hospitals / ATMs near me" results.
    if (filters != null && near != null) {
      try {
        final List<Place> pois = await _overpass(filters, near, radiusMeters);
        if (pois.isNotEmpty) return pois;
      } catch (_) {
        // Fall through to geocoding.
      }
    }

    // "Famous places near me" in data-sparse towns: Wikipedia geosearch has
    // real articles with coordinates where OSM has almost no POIs.
    if (_isAttractionQuery(q, types) && near != null) {
      try {
        final List<Place> wiki = await _wikipediaNearby(near, radiusMeters);
        if (wiki.isNotEmpty) return wiki;
      } catch (_) {
        // Fall through to geocoding.
      }
    }

    try {
      final List<Place> r = await _maptilerSearch(q, near);
      if (r.isNotEmpty) return r;
    } catch (_) {
      // Fall through.
    }

    try {
      final List<Place> r = await _nominatimSearch(q, near);
      if (r.isNotEmpty) return r;
    } catch (_) {
      // Fall through.
    }

    // A category with no geocoding match still deserves Overpass results.
    if (filters != null && near != null) {
      try {
        return await _overpass(filters, near, radiusMeters);
      } catch (_) {}
    }

    throw ApiException(
        ApiErrorKind.server, 'Could not search places right now.');
  }

  List<(String, String)>? _filtersFor(String query, List<String>? types) {
    if (types != null) {
      for (final String t in types) {
        final List<(String, String)>? f = _typeFilters[t];
        if (f != null) return f;
      }
    }
    final String q = query.toLowerCase();
    for (final MapEntry<String, List<(String, String)>> e
        in _categoryFilters.entries) {
      if (q.contains(e.key)) return e.value;
    }
    // "Hidden gems / things to do nearby" style queries → local attractions.
    if (q.contains('hidden') ||
        q.contains('gem') ||
        q.contains('things to do') ||
        q.contains('near me')) {
      return const <(String, String)>[('tourism', 'attraction')];
    }
    return null;
  }

  bool _isAttractionQuery(String q, List<String>? types) {
    if (types != null) return types.contains('tourist_attraction');
    final String s = q.toLowerCase();
    return s.contains('attraction') ||
        s.contains('famous') ||
        s.contains('things to do') ||
        s.contains('near me') ||
        s.contains('hidden') ||
        s.contains('gem') ||
        s.contains('tourist') ||
        s.contains('landmark') ||
        s.contains('sightsee');
  }

  /// Wikipedia GeoSearch: real encyclopaedia articles with coordinates near
  /// the user — the best free "famous places near me" source for towns where
  /// OSM tourism data is thin. Returns 0–20 results.
  Future<List<Place>> _wikipediaNearby(LatLng near, double radiusMeters) async {
    final int radius =
        (radiusMeters <= 0 ? 5000 : radiusMeters).round().clamp(10, 10000).toInt();
    final Response<dynamic> resp = await _dio.get<dynamic>(
      'https://en.wikipedia.org/w/api.php',
      queryParameters: <String, dynamic>{
        'action': 'query',
        'list': 'geosearch',
        'gscoord': '${near.latitude}|${near.longitude}',
        'gsradius': radius,
        'gslimit': 20,
        'format': 'json',
      },
    );
    final Object? data = resp.data;
    if (data is! Map) return const <Place>[];
    final Object? query = data['query'];
    if (query is! Map || query['geosearch'] is! List) return const <Place>[];
    final List<Place> out = <Place>[];
    for (final dynamic e in query['geosearch'] as List) {
      if (e is! Map) continue;
      final double? lat = (e['lat'] as num?)?.toDouble();
      final double? lon = (e['lon'] as num?)?.toDouble();
      final String title = (e['title'] as String?) ?? '';
      final int pageid = (e['pageid'] as num?)?.toInt() ?? 0;
      if (lat == null || lon == null || title.isEmpty) continue;
      // Drop clearly non-tourist administrative entries.
      final String t = title.toLowerCase();
      if (t.contains('constituency') ||
          t.contains('lok sabha') ||
          t.contains('vidhan sabha') ||
          t.contains(' district') ||
          t.contains('assembly')) {
        continue;
      }
      final double dist = (e['dist'] as num?)?.toDouble() ?? 0;
      out.add(Place(
        placeId: 'wiki-$pageid',
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
    return out;
  }

  static String _distLabel(double meters) {
    if (meters < 1000) return '${meters.round()} m away';
    return '${(meters / 1000).toStringAsFixed(1)} km away';
  }

  Future<List<Place>> _maptilerSearch(String q, LatLng? near) async {
    final Map<String, dynamic> qp = <String, dynamic>{
      'key': _mtKey,
      'limit': 15,
    };
    if (near != null) qp['proximity'] = '${near.longitude},${near.latitude}';
    final Response<dynamic> resp = await _dio.get<dynamic>(
      'https://api.maptiler.com/geocoding/${Uri.encodeComponent(q)}.json',
      queryParameters: qp,
    );
    return _parseGeocoding(resp.data);
  }

  Future<List<Place>> _nominatimSearch(String q, LatLng? near) async {
    final Map<String, dynamic> qp = <String, dynamic>{
      'q': q,
      'format': 'jsonv2',
      'limit': 15,
      'addressdetails': 0,
      'countrycodes': 'in',
    };
    if (near != null) {
      final double d = 0.5; // ~55 km box — generous for tourist searches.
      qp['viewbox'] = '${near.longitude - d},${near.latitude + d},'
          '${near.longitude + d},${near.latitude - d}';
      qp['bounded'] = 0;
    }
    final Response<dynamic> resp =
        await _nominatim.get<dynamic>('https://nominatim.openstreetmap.org/search',
            queryParameters: qp);
    final Object? data = resp.data;
    if (data is! List) return const <Place>[];
    final List<Place> out = <Place>[];
    for (final dynamic item in data) {
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
    return out;
  }

  // ---------------------------------------------------------------------
  // Overpass POI search (keyless, real OSM data)
  // ---------------------------------------------------------------------

  Future<List<Place>> _overpass(
    List<(String, String)> filters,
    LatLng near,
    double radiusMeters,
  ) async {
    final int radius = (radiusMeters <= 0 ? 5000 : radiusMeters).round();
    final StringBuffer b = StringBuffer('[out:json][timeout:20];(');
    for (final (String key, String regex) in filters) {
      final String clause =
          '["$key"~"$regex"](around:$radius,${near.latitude},${near.longitude})';
      b.write('node$clause;way$clause;');
    }
    b.write(');out center 40;');

    final List<Place> out = <Place>[];
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
        if (data is! Map || data['elements'] is! List) continue;
        for (final dynamic e in data['elements'] as List) {
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
        if (out.isNotEmpty) return out;
      } catch (_) {
        // Try the next host.
      }
    }
    return out;
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

  /// Best-rated hotels nearby (4–5★) with their star rating and distance.
  /// Overpass gives the real stars tag; price is estimated on-device since no
  /// free live-price source exists.
  Future<List<Place>> luxuryHotels(LatLng near, {int radiusMeters = 8000}) async {
    final int radius = radiusMeters <= 0 ? 8000 : radiusMeters;
    final List<Place> out = <Place>[];
    // Query 5★ then 4★ so 5★ results always come first.
    for (final int stars in const <int>[5, 4]) {
      final String query =
          '[out:json][timeout:20];('
          'node["tourism"="hotel"]["stars"="$stars"]'
          '(around:$radius,${near.latitude},${near.longitude});'
          'way["tourism"="hotel"]["stars"="$stars"]'
          '(around:$radius,${near.latitude},${near.longitude});'
          ');out center 40;';
      try {
        for (final String host in const <String>[
          'https://overpass-api.de/api/interpreter',
          'https://overpass.kumi.systems/api/interpreter',
        ]) {
          final Response<dynamic> resp = await _dio.get<dynamic>(
            host,
            queryParameters: <String, dynamic>{'data': query},
          );
          final Object? data = resp.data;
          if (data is! Map || data['elements'] is! List) continue;
          for (final dynamic e in data['elements'] as List) {
            if (e is! Map) continue;
            final (double?, double?) coords = _coordsOf(e);
            if (coords.$1 == null || coords.$2 == null) continue;
            final Object? tags = e['tags'];
            String name = '';
            if (tags is Map) name = _tagOf(tags, 'name');
            if (name.trim().isEmpty) continue;
            out.add(_hotelPlace(e, tags, coords.$1!, coords.$2!, stars.toDouble()));
          }
          break;
        }
      } catch (_) {}
    }
    // Small towns rarely tag stars — fall back to any real hotel so the
    // "hotels with prices" feature still returns places to book.
    if (out.isEmpty) {
      final String query =
          '[out:json][timeout:20];('
          'node[\"tourism\"~\"hotel|guest_house|hostel|motel\"]'
          '(around:$radius,${near.latitude},${near.longitude});'
          'way[\"tourism\"~\"hotel|guest_house|hostel|motel\"]'
          '(around:$radius,${near.latitude},${near.longitude});'
          ');out center 40;';
      try {
        for (final String host in const <String>[
          'https://overpass-api.de/api/interpreter',
          'https://overpass.kumi.systems/api/interpreter',
        ]) {
          final Response<dynamic> resp = await _dio.get<dynamic>(
            host,
            queryParameters: <String, dynamic>{'data': query},
          );
          final Object? data = resp.data;
          if (data is! Map || data['elements'] is! List) continue;
          for (final dynamic e in data['elements'] as List) {
            if (e is! Map) continue;
            final (double?, double?) coords = _coordsOf(e);
            if (coords.$1 == null || coords.$2 == null) continue;
            final Object? tags = e['tags'];
            String name = '';
            if (tags is Map) name = _tagOf(tags, 'name');
            if (name.trim().isEmpty) continue;
            out.add(_hotelPlace(e, tags, coords.$1!, coords.$2!, null));
          }
          break;
        }
      } catch (_) {}
    }
    // Sort by stars desc, then distance.
    out.sort((Place a, Place b) {
      final int cmp = ((b.rating ?? 0) - (a.rating ?? 0)).round();
      if (cmp != 0) return cmp;
      return GeoUtils.distanceMeters(near, a.coords)
          .compareTo(GeoUtils.distanceMeters(near, b.coords));
    });
    return out;
  }

  /// Builds a hotel [Place] from an Overpass element, keeping the real
  /// phone/website/address so the UI can offer booking actions.
  Place _hotelPlace(
      Map e, Object? tags, double lat, double lng, double? stars) {
    String phone = '';
    String website = '';
    String address = '';
    if (tags is Map) {
      phone = _tagOf(tags, 'phone') + _tagOf(tags, 'contact:phone');
      if (phone.isEmpty) phone = _tagOf(tags, 'contact:mobile');
      website = _tagOf(tags, 'website');
      if (website.isEmpty) website = _tagOf(tags, 'contact:website');
      final String street = _tagOf(tags, 'addr:street');
      final String city = _tagOf(tags, 'addr:city');
      address =
          <String>[street, city].where((String s) => s.isNotEmpty).join(', ');
    }
    return Place(
      placeId: 'osm-hotel-${e['id'] ?? '$lat,$lng'}',
      name: nameOf(tags),
      lat: lat,
      lng: lng,
      address: address.isEmpty ? null : address,
      phone: phone.isEmpty ? null : phone,
      website: website.isEmpty ? null : website,
      rating: stars,
      primaryType: 'hotel',
      types: const <String>['hotel', 'lodging'],
    );
  }

  static String nameOf(Object? tags) =>
      tags is Map ? _tagOf(tags, 'name') : '';

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
        final Object? name = f['place_name'];
        if (name is String && name.trim().isNotEmpty) return name.trim();
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
        if (data is Map && data['display_name'] is String) {
          return data['display_name'] as String;
        }
      } catch (_) {}
      throw ApiException(
          ApiErrorKind.server, 'Could not determine your location.');
    }
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

  /// OSRM profile for a travel mode: walk→foot, bike→bike, car/auto→driving.
  static String osrmProfile(String mode) => switch (mode) {
        'walk' => 'foot',
        'bike' => 'bike',
        _ => 'driving',
      };

  Future<RouteInfo> route(LatLng from, LatLng to, {String mode = 'car'}) async {
    final String profile = osrmProfile(mode);
    try {
      final String url = 'https://router.project-osrm.org/route/v1/$profile/'
          '${from.longitude},${from.latitude};'
          '${to.longitude},${to.latitude}'
          '?overview=full&geometries=geojson';
      final Response<dynamic> resp = await _dio.get<dynamic>(url);
      final Object? data = resp.data;
      if (data is Map && data['code'] == 'Ok' && data['routes'] is List) {
        final List<dynamic> routes = data['routes'] as List;
        if (routes.isNotEmpty && routes[0] is Map) {
          final Map<dynamic, dynamic> r0 =
              routes[0] as Map<dynamic, dynamic>;
          final double dist = (r0['distance'] as num?)?.toDouble() ?? 0;
          final double dur = (r0['duration'] as num?)?.toDouble() ?? 0;
          final Object? geo = r0['geometry'];
          final List<LatLng> pts = <LatLng>[];
          if (geo is Map && geo['coordinates'] is List) {
            for (final dynamic c in geo['coordinates'] as List) {
              if (c is List && c.length >= 2) {
                pts.add(LatLng(
                  (c[1] as num).toDouble(),
                  (c[0] as num).toDouble(),
                ));
              }
            }
          }
          if (pts.length >= 2 && dist > 0) {
            return RouteInfo(
              distanceMeters: dist,
              durationSeconds: dur,
              polyline: pts,
              provider: 'osrm',
            );
          }
        }
      }
    } on DioException {
      // Fall through to the honest straight-line estimate.
    }
    return _straightLine(from, to, mode: mode);
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
