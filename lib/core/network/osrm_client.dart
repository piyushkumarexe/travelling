import 'package:dio/dio.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../data/models/places.dart';

/// A focused, keyless OSRM routing client (https://router.project-osrm.org).
///
/// Implements the public Route API exactly as specified:
///
///   GET /route/v1/{profile}/{lng},{lat};{lng},{lat}
///       ?overview=full&geometries=geojson
///
/// Coordinates are sent in **longitude,latitude** order (OSRM order) and the
/// GeoJSON `geometry.coordinates` come back as `[lng, lat]` pairs, which are
/// converted to [LatLng] here. Distance (meters) and duration (seconds) are
/// parsed from `routes[0]`. Every failure mode (no route, no segment,
/// network, invalid coordinates) maps to an [OsrmException] kind so the UI
/// can show a specific, actionable message instead of a generic error.
class OsrmClient {
  OsrmClient({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 20),
            ));

  final Dio _dio;

  static const String server = 'https://router.project-osrm.org';

  /// OSRM profile for a travel mode: walk → foot, bike → bike, else driving.
  static String profileFor(String mode) => switch (mode) {
        'walk' => 'foot',
        'bike' => 'bike',
        _ => 'driving',
      };

  static bool validLatitude(double v) => v.isFinite && v >= -90 && v <= 90;
  static bool validLongitude(double v) => v.isFinite && v >= -180 && v <= 180;

  /// Computes a real road route between [origin] and [destination].
  ///
  /// Throws [OsrmException] on failure — it never fabricates coordinates.
  Future<RouteInfo> route({
    required LatLng origin,
    required LatLng destination,
    String mode = 'car',
  }) async {
    if (!validLatitude(origin.latitude) ||
        !validLongitude(origin.longitude) ||
        !validLatitude(destination.latitude) ||
        !validLongitude(destination.longitude)) {
      throw const OsrmException(
        OsrmErrorKind.invalidCoordinates,
        'These coordinates are outside the supported area. '
        'Please choose a different destination.',
      );
    }

    final String profile = profileFor(mode);
    final String url = '$server/route/v1/$profile/'
        '${origin.longitude},${origin.latitude};'
        '${destination.longitude},${destination.latitude}'
        '?overview=full&geometries=geojson';

    final Response<dynamic> resp;
    try {
      resp = await _dio.get<dynamic>(url);
    } on DioException catch (e) {
      throw OsrmException(OsrmErrorKind.network, _networkMessage(e));
    }

    final Map<String, dynamic>? map = _asStringMap(resp.data);
    if (map == null) {
      throw const OsrmException(
        OsrmErrorKind.invalidResponse,
        'Unexpected routing response.',
      );
    }

    final String code = (map['code'] as String?) ?? '';
    switch (code) {
      case 'Ok':
        break;
      case 'NoRoute':
        throw const OsrmException(
          OsrmErrorKind.noRoute,
          'No road route exists between these two points. '
          'Try a destination that is closer to a road.',
        );
      case 'NoSegment':
        throw const OsrmException(
          OsrmErrorKind.noSegment,
          'The route is incomplete — one of the points is unreachable by road.',
        );
      default:
        throw OsrmException(OsrmErrorKind.invalidResponse, 'Routing failed: $code');
    }

    final List<dynamic>? routes =
        map['routes'] is List ? map['routes'] as List : null;
    final Map<String, dynamic>? r0 =
        (routes != null && routes.isNotEmpty) ? _asStringMap(routes.first) : null;
    if (r0 == null) {
      throw const OsrmException(
        OsrmErrorKind.invalidResponse,
        'No route data returned.',
      );
    }

    final double distance = (r0['distance'] as num?)?.toDouble() ?? 0;
    final double duration = (r0['duration'] as num?)?.toDouble() ?? 0;
    final List<LatLng> points = _parseGeometry(r0['geometry']);
    if (points.length < 2) {
      throw const OsrmException(
        OsrmErrorKind.invalidResponse,
        'The route geometry is incomplete.',
      );
    }

    return RouteInfo(
      distanceMeters: distance,
      durationSeconds: duration,
      polyline: points,
      provider: 'osrm',
    );
  }

  Map<String, dynamic>? _asStringMap(Object? value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) {
      return value.map((dynamic k, dynamic v) =>
          MapEntry<String, dynamic>(k.toString(), v));
    }
    return null;
  }

  List<LatLng> _parseGeometry(Object? geometry) {
    final List<LatLng> pts = <LatLng>[];
    final Map<String, dynamic>? geo = _asStringMap(geometry);
    final Object? coords = geo?['coordinates'];
    if (coords is! List) return pts;
    for (final dynamic c in coords) {
      if (c is List && c.length >= 2) {
        final double? lng = _num(c[0]);
        final double? lat = _num(c[1]);
        if (lng != null &&
            lat != null &&
            validLongitude(lng) &&
            validLatitude(lat)) {
          pts.add(LatLng(lat, lng));
        }
      }
    }
    return pts;
  }

  double? _num(Object? v) => v is num ? v.toDouble() : null;

  String _networkMessage(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return 'The routing server timed out. Please try again.';
      case DioExceptionType.connectionError:
        return 'No internet connection. Check your network and try again.';
      default:
        return 'Could not reach the routing server. Check your internet connection.';
    }
  }
}

enum OsrmErrorKind {
  network,
  invalidCoordinates,
  noRoute,
  noSegment,
  invalidResponse,
}

class OsrmException implements Exception {
  const OsrmException(this.kind, this.message);

  final OsrmErrorKind kind;
  final String message;

  @override
  String toString() => message;
}
