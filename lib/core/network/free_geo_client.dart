import 'package:dio/dio.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../data/models/places.dart';
import '../../data/models/weather.dart';
import '../app_config.dart';
import '../utils/geo.dart';
import 'api_exception.dart';

/// Real, free (key-light) data clients used as a fallback when the Tourism
/// Cloud Functions backend is not deployed yet — so Explore, Map and Weather
/// keep working on the device:
///
///   • MapTiler Geocoding (search + reverse) — uses the MapTiler key.
///   • OSRM public router (real road routing, no key).
///   • Open-Meteo (real weather, no key).
class FreeGeoClient {
  FreeGeoClient();

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 12),
    receiveTimeout: const Duration(seconds: 25),
  ));

  String get _mtKey => AppConfig.mapTilerApiKey;

  // ---------------------------------------------------------------------
  // MapTiler geocoding
  // ---------------------------------------------------------------------

  Future<List<Place>> searchPlaces(
    String query, {
    LatLng? near,
  }) async {
    try {
      final Map<String, dynamic> qp = <String, dynamic>{
        'key': _mtKey,
        'limit': 15,
      };
      if (near != null) qp['proximity'] = '${near.longitude},${near.latitude}';
      final Response<dynamic> resp = await _dio.get<dynamic>(
        'https://api.maptiler.com/geocoding/${Uri.encodeComponent(query)}.json',
        queryParameters: qp,
      );
      return _parseGeocoding(resp.data);
    } on DioException catch (e) {
      throw _map(e, 'Could not search places right now.');
    }
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
        final Object? name = f['place_name'];
        if (name is String && name.trim().isNotEmpty) return name.trim();
      }
      return null;
    } on DioException catch (e) {
      throw _map(e, 'Could not determine your location.');
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
  // OSRM routing (real road routing, no key)
  // ---------------------------------------------------------------------

  Future<RouteInfo> route(LatLng from, LatLng to) async {
    try {
      final String url = 'https://router.project-osrm.org/route/v1/driving/'
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
    return _straightLine(from, to);
  }

  RouteInfo _straightLine(LatLng from, LatLng to) {
    final double meters = GeoUtils.distanceMeters(from, to);
    final double seconds = (meters / 1000) / 30 * 3600; // ~30 km/h urban
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
